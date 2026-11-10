import AVFoundation
import Combine
import Foundation
import SwiftUI
import AppKit
import CoreAudio

/// Reserves one recorder session across the synchronous start call and its work queue.
/// Only the recorder's own engine failure takes the current session unscoped.
final class AudioRecordingSessionGate {
    private let lock = NSLock()
    private var sessionID: UUID?

    func reserve(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sessionID == nil else { return false }
        sessionID = id
        return true
    }

    func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionID == id
    }

    /// Consumes ownership atomically; a rejected or stale owner cannot stop a newer session.
    func take(ifMatching id: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = sessionID, id == nil || id == current else { return false }
        sessionID = nil
        return true
    }
}

/// Counts the captures reading the shared microphone input, stop tails
/// included, so overlapping recordings open it once and restore it once.
struct SharedInputLease: Equatable {
    private(set) var holders = 0

    /// The next capture is the first, so it chooses the system input.
    var opensInput: Bool { holders == 0 }

    mutating func acquire() {
        holders += 1
    }

    /// Returns true when the last capture left, so the input is restored.
    mutating func release() -> Bool {
        holders = max(0, holders - 1)
        return holders == 0
    }
}

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    @Published var isConnecting = false
    /// Sends, on the main queue, the session whose capture stopped on its own
    /// before its owner stopped it. The owner ends it through its usual stop,
    /// which keeps the audio recorded until then.
    let captureStopped = PassthroughSubject<UUID, Never>()
    
    /// Short commands such as “yes”, “stop”, or a single name are valid
    /// dictations. Blank-audio suppression remains the authority for silence.
    static let minimumRecordingDuration: TimeInterval = 0.35
    static let temporaryFileMaxAge: TimeInterval = 24 * 60 * 60
    /// Extra audio captured after a stop request, so the tail of the last word
    /// (released together with the hotkey) is not clipped.
    static let stopTailDuration: TimeInterval = 0.25

    /// Sessions can overlap while the previous recording captures its final
    /// word. Wall-clock seconds are not unique enough for either audio path.
    static func recordingFileName(id: UUID = UUID()) -> String {
        "\(id.uuidString).wav"
    }
    
    // Serializes all recording state mutations (start/stop/cancel/connection monitoring)
    // so a stop arriving right after a start can never overtake it.
    private let workQueue = DispatchQueue(label: "com.opensuperwhisper.audiorecorder")
    private let sessionGate = AudioRecordingSessionGate()
    /// A meeting records in its own lane beside dictation, so the shortcut
    /// keeps working for the whole meeting.
    private let meetingGate = AudioRecordingSessionGate()

    /// The open dictation: AVAudioRecorder, or the voice-processed engine.
    private var capture: RecordingCapture?
    /// The open meeting, always the microphone as is.
    private var meetingCapture: AVAudioRecorder?
    private var meetingRecordingURL: URL?
    private var inputLease = SharedInputLease()
    private var sharedInputChannelCount = 1
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?
    private var connectionCheckTimer: DispatchSourceTimer?
    private var levelTimer: DispatchSourceTimer?
    private var recordingDeviceID: AudioDeviceID?
    private var previousDefaultInputDeviceID: AudioDeviceID?

    // MARK: - Singleton Instance

    static let shared = AudioRecorder()
    
    static var temporaryRecordingsDirectory: URL {
        // The app is not sandboxed, so its temporary folder is shared with the
        // test host; tests keep their own.
        FileManager.default.temporaryDirectory.appendingPathComponent(
            OpenSuperWhisperApp.isRunningTests ? "WorkFlowTestTempRecordings" : "temp_recordings"
        )
    }
    
    override private init() {
        temporaryDirectory = Self.temporaryRecordingsDirectory
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        setup()
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = microphoneChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        updateCanRecordStatus()
        
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
    }
    
    private func updateCanRecordStatus() {
        canRecord = MicrophoneService.shared.getActiveMicrophone() != nil
    }
    
    private func createTemporaryDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create temporary recordings directory.")
        }
    }
    
    /// Removes stale temporary recordings except those History still uses.
    static func sweepTemporaryRecordings(in directory: URL, olderThan maxAge: TimeInterval, keeping referencedPaths: Set<String>) {
        cleanupOldTemporaryFiles(in: directory, olderThan: maxAge, keeping: referencedPaths)
    }

    /// Runs the sweep on the recorder's queue once History has said which
    /// temporary recordings it still uses.
    func sweepTemporaryRecordings(keeping referencedPaths: Set<String>) {
        workQueue.async { [temporaryDirectory] in
            Self.sweepTemporaryRecordings(in: temporaryDirectory, olderThan: Self.temporaryFileMaxAge, keeping: referencedPaths)
        }
    }

    static func cleanupOldTemporaryFiles(in directory: URL, olderThan maxAge: TimeInterval, keeping referencedPaths: Set<String> = []) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        
        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files where !referencedPaths.contains(file.standardizedFileURL.path) {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
    
    // Loaded once: decoding the mp3 from disk takes ~15 ms on the main thread,
    // which drops frames of the indicator appear animation on every hotkey press.
    private static let cachedNotificationSound: NSSound? = {
        guard let soundURL = Bundle.main.url(forResource: "notification", withExtension: "mp3"),
              let sound = NSSound(contentsOf: soundURL, byReference: false) else {
            print("Failed to load notification sound file")
            return nil
        }
        sound.volume = 0.3
        return sound
    }()
    
    private func playNotificationSound() {
        guard let sound = Self.cachedNotificationSound else {
            NSSound.beep()
            return
        }
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
        notificationSound = sound
    }
    
    /// `started` receives, on the main queue, the file the recording is being
    /// written to once the capture has begun.
    ///
    /// A dictation and a meeting can record at the same time: each purpose has
    /// its own session, and both read the same microphone.
    @discardableResult
    func startRecording(
        sessionID: UUID,
        purpose: RecordingPurpose = .dictation,
        completion: ((String?) -> Void)? = nil,
        started: ((URL) -> Void)? = nil
    ) -> Bool {
        let gate = gate(for: purpose)
        guard gate.reserve(sessionID) else { return false }

        // Everything below costs CoreAudio HAL round-trips (device queries,
        // AudioQueue start for the notification sound) — 20-35 ms that used to
        // block the main thread right when the indicator appear animation
        // starts, so the whole start sequence runs on the work queue.
        let playSound = AppPreferences.shared.playSoundOnRecordStart
        let configuration = MicrophoneCaptureConfiguration.forNextRecording(purpose)
        workQueue.async {
            guard let activeMic = MicrophoneService.shared.getActiveMicrophone() else {
                print("Cannot start recording - no audio input available")
                _ = gate.take(ifMatching: sessionID)
                DispatchQueue.main.async {
                    completion?("The selected microphone is no longer available.")
                }
                return
            }

            if playSound {
                self.playNotificationSound()
            }

            let failure: String?
            let recordingURL: URL?
            switch purpose {
            case .meeting:
                failure = self.performMeetingStart(activeMic: activeMic, sessionID: sessionID)
                recordingURL = failure == nil ? self.meetingRecordingURL : nil
            case .dictation:
                let requiresConnection = MicrophoneService.shared.isActiveMicrophoneRequiresConnection()
                self.updateRecordingState(isRecording: false, isConnecting: requiresConnection)
                failure = self.performStart(activeMic: activeMic, configuration: configuration, monitorConnection: requiresConnection, sessionID: sessionID)
                recordingURL = failure == nil ? self.currentRecordingURL : nil
            }
            DispatchQueue.main.async {
                completion?(failure)
                if let recordingURL {
                    started?(recordingURL)
                }
            }
        }
        return true
    }

    private func gate(for purpose: RecordingPurpose) -> AudioRecordingSessionGate {
        purpose == .meeting ? meetingGate : sessionGate
    }

    private func performStart(activeMic: MicrophoneService.AudioDevice, configuration: MicrophoneCaptureConfiguration, monitorConnection: Bool, sessionID: UUID) -> String? {
        let fileURL = temporaryDirectory.appendingPathComponent(Self.recordingFileName())
        currentRecordingURL = fileURL

        print("Starting audio recording.")
        let channelCount = prepareSharedInput(for: activeMic)

        // Voice processing would take the call out of what the microphone
        // hears, and it ducks the call's audio, so a dictation during a
        // meeting records the microphone as is, like the meeting does.
        var configuration = configuration
        if configuration == .voiceProcessing, meetingCapture != nil {
            configuration = .standard
            Self.publishBackgroundAudioReduction(.offDuringMeeting)
        }

        // If voice processing can't start, this recording uses the
        // microphone as is and Settings says so.
        if configuration == .voiceProcessing, startVoiceProcessedCapture(at: fileURL, monitorConnection: monitorConnection, sessionID: sessionID) {
            print("Recording started with voice processing")
            return nil
        }

        do {
            let audioRecorder = try makeStandardRecorder(at: fileURL, channelCount: channelCount)
            guard audioRecorder.record() == true else {
                print("Failed to start recording: AVAudioRecorder declined the request")
                currentRecordingURL = nil
                try? FileManager.default.removeItem(at: fileURL)
                releaseSharedInputIfUnused()
                _ = sessionGate.take(ifMatching: sessionID)
                updateRecordingState(isRecording: false, isConnecting: false)
                return "The microphone declined the recording request."
            }
            // The capture has begun. A no-op unless a dictation press is timed.
            PerfSignpost.end(.triggerToMicLive)
            capture = audioRecorder
            inputLease.acquire()
            refreshLevelMetering()
            if monitorConnection {
                startConnectionMonitoring()
            } else {
                updateRecordingState(isRecording: true, isConnecting: false)
            }
            print("Recording started successfully")
            return nil
        } catch {
            print("Failed to start recording.")
            currentRecordingURL = nil
            releaseSharedInputIfUnused()
            _ = sessionGate.take(ifMatching: sessionID)
            updateRecordingState(isRecording: false, isConnecting: false)
            return error.localizedDescription
        }
    }

    /// A meeting records the microphone as is, so people on a call who come
    /// through the speakers stay in it. It never drives the dictation UI.
    private func performMeetingStart(activeMic: MicrophoneService.AudioDevice, sessionID: UUID) -> String? {
        let fileURL = temporaryDirectory.appendingPathComponent(Self.recordingFileName())
        print("Starting meeting recording.")
        let channelCount = prepareSharedInput(for: activeMic)
        do {
            let audioRecorder = try makeStandardRecorder(at: fileURL, channelCount: channelCount)
            guard audioRecorder.record() == true else {
                print("Failed to start meeting recording: AVAudioRecorder declined the request")
                try? FileManager.default.removeItem(at: fileURL)
                releaseSharedInputIfUnused()
                _ = meetingGate.take(ifMatching: sessionID)
                return "The microphone declined the recording request."
            }
            meetingCapture = audioRecorder
            meetingRecordingURL = fileURL
            inputLease.acquire()
            refreshLevelMetering()
            return nil
        } catch {
            print("Failed to start meeting recording.")
            releaseSharedInputIfUnused()
            _ = meetingGate.take(ifMatching: sessionID)
            return error.localizedDescription
        }
    }

    private func makeStandardRecorder(at fileURL: URL, channelCount: Int) throws -> AVAudioRecorder {
        // 16-bit integer PCM: half the disk/IO of Float32 with no quality loss
        // for speech recognition (whisper consumes 16 kHz mono anyway).
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder.delegate = self
        // Metering drives the record control's live level.
        audioRecorder.isMeteringEnabled = true
        return audioRecorder
    }

    /// Starts the voice-processed engine; false leaves nothing running.
    private func startVoiceProcessedCapture(at fileURL: URL, monitorConnection: Bool, sessionID: UUID) -> Bool {
        do {
            let voiceCapture = try VoiceProcessedCapture(url: fileURL, queue: workQueue) {
                AVAudioEngineVoiceCapture()
            }
            voiceCapture.onStopped = { [weak self, weak voiceCapture] reason in
                Self.publishBackgroundAudioReduction(.stopped(reason))
                guard let self, let voiceCapture, voiceCapture === self.capture,
                      self.sessionGate.isCurrent(sessionID) else { return }
                self.stopConnectionMonitoring()
                // A meeting still recording keeps the meter on its level.
                if self.meetingCapture == nil {
                    self.stopLevelMetering()
                }
                self.updateRecordingState(isRecording: false, isConnecting: false)
                DispatchQueue.main.async {
                    self.captureStopped.send(sessionID)
                }
            }
            try voiceCapture.start()
            PerfSignpost.end(.triggerToMicLive)
            capture = voiceCapture
            inputLease.acquire()
            refreshLevelMetering()
            Self.publishBackgroundAudioReduction(.active)
            if monitorConnection {
                startConnectionMonitoring()
            } else {
                updateRecordingState(isRecording: true, isConnecting: false)
            }
            return true
        } catch {
            print("Voice processing could not start; recording the microphone as is.")
            try? FileManager.default.removeItem(at: fileURL)
            Self.publishBackgroundAudioReduction(.unavailable(VoiceProcessedCapture.reason(for: error)))
            return false
        }
    }

    private static func publishBackgroundAudioReduction(_ status: BackgroundAudioReductionStatus) {
        DispatchQueue.main.async {
            BackgroundAudioReductionMonitor.shared.status = status
        }
    }

    func ownsRecordingSession(_ sessionID: UUID) -> Bool {
        sessionGate.isCurrent(sessionID) || meetingGate.isCurrent(sessionID)
    }

    func stopRecording(sessionID: UUID) async -> URL? {
        await withCheckedContinuation { continuation in
            workQueue.async {
                if self.meetingGate.take(ifMatching: sessionID) {
                    self.stopMeeting(resuming: continuation)
                    return
                }
                guard self.sessionGate.take(ifMatching: sessionID) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let capture = self.capture, let url = self.currentRecordingURL else {
                    continuation.resume(returning: self.performStop(discard: false))
                    return
                }

                // Detach the session immediately (UI state, connection monitoring),
                // then keep capturing a short tail before actually stopping, so the
                // end of the last word released together with the hotkey survives.
                self.capture = nil
                self.currentRecordingURL = nil
                self.stopConnectionMonitoring()
                self.refreshLevelMetering()
                self.updateRecordingState(isRecording: false, isConnecting: false)

                self.workQueue.asyncAfter(deadline: .now() + Self.stopTailDuration) {
                    let recordedDuration = capture.finish()
                    // A recording that started during the tail, or a meeting
                    // still running, keeps the shared input open.
                    self.closeSharedInput()
                    continuation.resume(returning: Self.keptRecording(at: url, duration: recordedDuration))
                }
            }
        }
    }

    /// Keeps the meeting recording a short tail too, then hands back its file.
    private func stopMeeting(resuming continuation: CheckedContinuation<URL?, Never>) {
        guard let recorder = meetingCapture, let url = meetingRecordingURL else {
            meetingCapture = nil
            meetingRecordingURL = nil
            continuation.resume(returning: nil)
            return
        }
        meetingCapture = nil
        meetingRecordingURL = nil
        refreshLevelMetering()
        workQueue.asyncAfter(deadline: .now() + Self.stopTailDuration) {
            let recordedDuration = recorder.finish()
            self.closeSharedInput()
            continuation.resume(returning: Self.keptRecording(at: url, duration: recordedDuration))
        }
    }

    private static func keptRecording(at url: URL, duration: TimeInterval) -> URL? {
        guard duration >= minimumRecordingDuration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    func cancelRecording(sessionID: UUID) {
        workQueue.sync {
            if meetingGate.take(ifMatching: sessionID) {
                discardMeeting()
                return
            }
            guard sessionGate.take(ifMatching: sessionID) else { return }
            _ = performStop(discard: true)
        }
    }

    private func discardMeeting() {
        guard let recorder = meetingCapture else { return }
        meetingCapture = nil
        _ = recorder.finish()
        if let url = meetingRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        meetingRecordingURL = nil
        closeSharedInput()
        refreshLevelMetering()
    }

    private func performStop(discard: Bool) -> URL? {
        let openCapture = capture
        capture = nil
        let recordedDuration = openCapture?.finish() ?? 0
        if openCapture != nil {
            closeSharedInput()
        }
        stopConnectionMonitoring()
        refreshLevelMetering()
        updateRecordingState(isRecording: false, isConnecting: false)

        guard let url = currentRecordingURL else { return nil }
        currentRecordingURL = nil

        if discard || recordedDuration < Self.minimumRecordingDuration {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    // MARK: - Shared input

    /// The first open capture makes the selected microphone the system input;
    /// later ones read that same input, so a dictation during a meeting never
    /// moves the meeting, or a call that follows the system input, to another
    /// microphone. Returns the channel count to record.
    private func prepareSharedInput(for device: MicrophoneService.AudioDevice) -> Int {
        guard inputLease.opensInput else { return sharedInputChannelCount }
        #if os(macOS)
        switchSystemDefaultInput(to: device)
        sharedInputChannelCount = MicrophoneService.shared.getInputChannelCount(for: device)
        print("Recording with \(sharedInputChannelCount) input channel(s).")
        #endif
        return sharedInputChannelCount
    }

    /// One capture stopped reading the shared input; the last one restores it.
    private func closeSharedInput() {
        if inputLease.release() {
            restoreSystemDefaultInputIfNeeded()
        }
    }

    /// A capture that failed to start never held the input; if nothing else
    /// does, put back the input it chose.
    private func releaseSharedInputIfUnused() {
        guard inputLease.opensInput else { return }
        restoreSystemDefaultInputIfNeeded()
    }

    #if os(macOS)
    private func switchSystemDefaultInput(to device: MicrophoneService.AudioDevice) {
        guard let targetID = MicrophoneService.shared.getCoreAudioDeviceID(for: device) else { return }
        recordingDeviceID = targetID

        let currentDefault = MicrophoneService.shared.getCurrentSystemDefaultInputDevice()
        guard currentDefault != targetID else { return }

        if MicrophoneService.shared.setSystemDefaultInputDevice(targetID) {
            previousDefaultInputDeviceID = currentDefault
            print("Set the selected microphone as the system default input.")
        }
    }

    private func restoreSystemDefaultInputIfNeeded() {
        guard let previous = previousDefaultInputDeviceID else { return }
        previousDefaultInputDeviceID = nil

        // Restore only if the default is still the device we set,
        // so a manual change made by the user during recording is kept.
        if MicrophoneService.shared.getCurrentSystemDefaultInputDevice() == recordingDeviceID {
            _ = MicrophoneService.shared.setSystemDefaultInputDevice(previous)
        }
    }
    #else
    private func switchSystemDefaultInput(to device: MicrophoneService.AudioDevice) {}
    private func restoreSystemDefaultInputIfNeeded() {}
    #endif

    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws {

        let directory = finalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }

    /// Moves a finished recording into History. If that fails, audio still at
    /// its temporary path stays there; nil means no audio is left.
    func keepTemporaryRecording(_ tempURL: URL, at finalURL: URL) -> URL? {
        do {
            try moveTemporaryRecording(from: tempURL, to: finalURL)
            return finalURL
        } catch {
            print("Could not move the recording into History.")
            return FileManager.default.fileExists(atPath: tempURL.path) ? tempURL : nil
        }
    }
    
    func playRecording(url: URL) {
        // Stop current playback if any
        stopPlaying()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            currentlyPlayingURL = url
        } catch {
            print("Failed to play recording.")
            isPlaying = false
            currentlyPlayingURL = nil
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentlyPlayingURL = nil
    }
    
    private func updateRecordingState(isRecording: Bool, isConnecting: Bool) {
        DispatchQueue.main.async {
            self.isRecording = isRecording
            self.isConnecting = isConnecting
        }
    }
    
    private func startConnectionMonitoring() {
        stopConnectionMonitoring()
        
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        let initialFileSize: Int64 = 4096
        var growthCount = 0
        
        timer.setEventHandler { [weak self] in
            guard let self = self, let capture = self.capture, let url = self.currentRecordingURL else { return }
            
            let totalGrowth: Int64
            if let voiceCapture = capture as? VoiceProcessedCapture {
                // 16-bit mono at 16 kHz, the same bytes the file grows by.
                totalGrowth = Int64(voiceCapture.recordedDuration * SpeechFileWriter.sampleRate) * 2
            } else {
                let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                totalGrowth = currentFileSize - initialFileSize
            }
            
            if totalGrowth > 8000 {
                growthCount += 1
            }
            
            if growthCount >= 2 {
                self.stopConnectionMonitoring()
                self.updateRecordingState(isRecording: true, isConnecting: false)
            }
        }
        connectionCheckTimer = timer
        timer.resume()
    }
    
    private func stopConnectionMonitoring() {
        connectionCheckTimer?.cancel()
        connectionCheckTimer = nil
    }

    /// Keeps the level meter running while any capture is open.
    private func refreshLevelMetering() {
        if capture == nil, meetingCapture == nil {
            stopLevelMetering()
        } else if levelTimer == nil {
            startLevelMetering()
        }
    }

    /// Reads the open capture's loudness 20 times a second on the work queue,
    /// the only queue that touches the capture. A dictation's level shows
    /// over a meeting's, since that is what the speaker is watching.
    private func startLevelMetering() {
        stopLevelMetering()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self, let capture: RecordingCapture = self.capture ?? self.meetingCapture else { return }
            let level = capture.currentLevel()
            DispatchQueue.main.async {
                InputLevelMeter.shared.push(level)
            }
        }
        levelTimer = timer
        timer.resume()
    }

    private func stopLevelMetering() {
        guard let timer = levelTimer else { return }
        timer.cancel()
        levelTimer = nil
        DispatchQueue.main.async {
            InputLevelMeter.shared.reset()
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        workQueue.async {
            if recorder === self.meetingCapture {
                _ = self.meetingGate.take(ifMatching: nil)
                self.discardMeeting()
                return
            }
            guard recorder === self.capture else { return }
            _ = self.sessionGate.take(ifMatching: nil)
            _ = self.performStop(discard: true)
        }
    }
}

/// One open recording from either capture path.
protocol RecordingCapture: AnyObject {
    /// Stops capturing and returns how long the recording is.
    func finish() -> TimeInterval
    /// How loud the microphone is right now, 0...1.
    func currentLevel() -> CGFloat
}

extension AVAudioRecorder: RecordingCapture {
    func finish() -> TimeInterval {
        let recordedDuration = currentTime
        stop()
        return recordedDuration
    }

    func currentLevel() -> CGFloat {
        guard isMeteringEnabled, isRecording else { return 0 }
        updateMeters()
        return InputLevelMeter.normalized(decibels: averagePower(forChannel: 0))
    }
}

extension VoiceProcessedCapture: RecordingCapture {}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
