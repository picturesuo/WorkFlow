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
    
    private let hardware: RecordingHardware
    /// How long a stopped recording keeps capturing; see `stopTailDuration`.
    private let stopTail: TimeInterval
    /// The open recording: the standard capture, or the voice-processed engine.
    private var capture: RecordingCapture?
    /// The session `capture` belongs to.
    private var captureSessionID: UUID?
    /// The session already told that its capture stopped on its own.
    private var endedSessionID: UUID?
    /// Captures still writing: the open one and any finishing its stop tail.
    private var openCaptureCount = 0
    private var playback: RecordingPlayback?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var observers: [NSObjectProtocol] = []
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
    
    /// The app's one recorder uses the Mac's real devices. Tests pass
    /// scripted hardware and their own folder, so the whole lifecycle runs
    /// without opening a microphone or playing a sound.
    init(
        hardware: RecordingHardware = LiveRecordingHardware(),
        temporaryDirectory: URL = AudioRecorder.temporaryRecordingsDirectory,
        stopTail: TimeInterval = AudioRecorder.stopTailDuration
    ) {
        self.hardware = hardware
        self.temporaryDirectory = temporaryDirectory
        self.stopTail = stopTail
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        setup()
    }
    
    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        updateCanRecordStatus()
        
        for name in [Notification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected, .microphoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateCanRecordStatus()
            })
        }
    }
    
    private func updateCanRecordStatus() {
        canRecord = hardware.activeMicrophone() != nil
    }

    /// Whether a microphone is available right now, asked of the hardware.
    var hasActiveMicrophone: Bool {
        hardware.activeMicrophone() != nil
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
    
    /// `started` receives, on the main queue, the file the recording is being
    /// written to once the capture has begun. Called on the main thread.
    @discardableResult
    func startRecording(
        sessionID: UUID,
        purpose: RecordingPurpose = .dictation,
        completion: ((String?) -> Void)? = nil,
        started: ((URL) -> Void)? = nil
    ) -> Bool {
        guard sessionGate.reserve(sessionID) else { return false }
        // A History recording still playing through the speakers would be
        // recorded by the microphone and transcribed as if it were spoken.
        stopPlaying()

        // Everything below costs CoreAudio HAL round-trips (device queries,
        // AudioQueue start for the notification sound) — 20-35 ms that used to
        // block the main thread right when the indicator appear animation
        // starts, so the whole start sequence runs on the work queue.
        let playSound = AppPreferences.shared.playSoundOnRecordStart
        let configuration = MicrophoneCaptureConfiguration.forNextRecording(purpose)
        workQueue.async {
            // Cancelled before the microphone was asked for: nothing to open.
            guard self.sessionGate.isCurrent(sessionID) else { return }
            guard let activeMic = self.hardware.activeMicrophone() else {
                print("Cannot start recording - no audio input available")
                _ = self.sessionGate.take(ifMatching: sessionID)
                DispatchQueue.main.async {
                    completion?("The selected microphone is no longer available.")
                }
                return
            }
            
            if playSound {
                self.hardware.playStartSound()
            }
            
            let requiresConnection = self.hardware.activeMicrophoneRequiresConnection()
            self.updateRecordingState(isRecording: false, isConnecting: requiresConnection)
            let failure = self.performStart(activeMic: activeMic, configuration: configuration, monitorConnection: requiresConnection, sessionID: sessionID)
            let recordingURL = failure == nil ? self.currentRecordingURL : nil
            DispatchQueue.main.async {
                completion?(failure)
                if let recordingURL {
                    started?(recordingURL)
                }
            }
        }
        return true
    }
    
    private func performStart(activeMic: MicrophoneService.AudioDevice?, configuration: MicrophoneCaptureConfiguration, monitorConnection: Bool, sessionID: UUID) -> String? {
        let fileURL = temporaryDirectory.appendingPathComponent(Self.recordingFileName())
        currentRecordingURL = fileURL
        
        print("Starting audio recording.")
        
        var channelCount = 1
        #if os(macOS)
        if let activeMic = activeMic {
            switchSystemDefaultInput(to: activeMic)
            channelCount = hardware.inputChannelCount(for: activeMic)
            print("Recording with \(channelCount) input channel(s).")
        }
        #endif

        // If voice processing can't start, this recording uses the
        // microphone as is and Settings says so.
        if configuration == .voiceProcessing, startVoiceProcessedCapture(at: fileURL, monitorConnection: monitorConnection, sessionID: sessionID) {
            print("Recording started with voice processing")
            return nil
        }
        
        do {
            let standardCapture = try hardware.startStandardCapture(at: fileURL, channels: channelCount) { [weak self] in
                self?.workQueue.async { self?.captureEnded(sessionID: sessionID) }
            }
            // The capture has begun. A no-op unless a dictation press is timed.
            PerfSignpost.end(.triggerToMicLive)
            open(standardCapture, sessionID: sessionID)
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
            try? FileManager.default.removeItem(at: fileURL)
            restoreSystemDefaultInputWhenIdle()
            _ = sessionGate.take(ifMatching: sessionID)
            updateRecordingState(isRecording: false, isConnecting: false)
            return (error as? StandardCaptureError)?.message ?? error.localizedDescription
        }
    }

    /// Makes `capture` the open recording of `sessionID`.
    private func open(_ capture: RecordingCapture, sessionID: UUID) {
        self.capture = capture
        captureSessionID = sessionID
        openCaptureCount += 1
        startLevelMetering()
    }

    /// The open capture stopped on its own: the device went away, the
    /// recorder failed, or voice processing could not restart. The session
    /// stays with its owner, who is told once and ends it through its usual
    /// stop, which keeps the audio recorded until then. Runs on the work queue.
    private func captureEnded(sessionID: UUID) {
        guard captureSessionID == sessionID, capture != nil, endedSessionID != sessionID,
              sessionGate.isCurrent(sessionID) else { return }
        endedSessionID = sessionID
        stopConnectionMonitoring()
        stopLevelMetering()
        updateRecordingState(isRecording: false, isConnecting: false)
        DispatchQueue.main.async {
            self.captureStopped.send(sessionID)
        }
    }
    
    /// Starts the voice-processed engine; false leaves nothing running.
    private func startVoiceProcessedCapture(at fileURL: URL, monitorConnection: Bool, sessionID: UUID) -> Bool {
        do {
            let voiceCapture = try VoiceProcessedCapture(url: fileURL, queue: workQueue) { [hardware] in
                hardware.makeVoiceEngine()
            }
            voiceCapture.onStopped = { [weak self] reason in
                Self.publishBackgroundAudioReduction(.stopped(reason))
                self?.captureEnded(sessionID: sessionID)
            }
            try voiceCapture.start()
            PerfSignpost.end(.triggerToMicLive)
            open(voiceCapture, sessionID: sessionID)
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
        sessionGate.isCurrent(sessionID)
    }

    func stopRecording(sessionID: UUID) async -> URL? {
        await withCheckedContinuation { continuation in
            stopRecording(sessionID: sessionID) { continuation.resume(returning: $0) }
        }
    }

    /// Stops the session and hands `completion`, on the recorder's queue,
    /// the recording if it is long enough to use.
    private func stopRecording(sessionID: UUID, completion: @escaping (URL?) -> Void) {
        workQueue.async {
            guard self.sessionGate.take(ifMatching: sessionID) else {
                completion(nil)
                return
            }
            guard let capture = self.capture, let url = self.currentRecordingURL else {
                completion(self.performStop(discard: false))
                return
            }
            
            // Detach the session immediately (UI state, connection monitoring),
            // then keep capturing a short tail before actually stopping, so the
            // end of the last word released together with the hotkey survives.
            self.capture = nil
            self.captureSessionID = nil
            self.currentRecordingURL = nil
            self.stopConnectionMonitoring()
            self.stopLevelMetering()
            self.updateRecordingState(isRecording: false, isConnecting: false)
            
            self.workQueue.asyncAfter(deadline: .now() + self.stopTail) {
                let recordedDuration = capture.finish()
                // A new recording may have started during the tail window,
                // or still be finishing its own; the system input goes
                // back once nothing records any more.
                self.closedCapture()
                
                if recordedDuration < Self.minimumRecordingDuration {
                    try? FileManager.default.removeItem(at: url)
                    completion(nil)
                } else {
                    completion(url)
                }
            }
        }
    }
    
    /// Ends the session at once and discards its audio. The capture is
    /// closed on the recorder's queue, so the caller, usually the main
    /// thread, never waits behind a microphone that is still opening.
    func cancelRecording(sessionID: UUID) {
        guard sessionGate.take(ifMatching: sessionID) else { return }
        workQueue.async {
            // A start that failed left nothing of this session to close.
            guard self.captureSessionID == sessionID else { return }
            _ = self.performStop(discard: true)
        }
    }
    
    private func performStop(discard: Bool) -> URL? {
        let recordedDuration = capture?.finish() ?? 0
        let closed = capture != nil
        capture = nil
        captureSessionID = nil
        stopConnectionMonitoring()
        stopLevelMetering()
        if closed {
            closedCapture()
        } else {
            restoreSystemDefaultInputWhenIdle()
        }
        updateRecordingState(isRecording: false, isConnecting: false)
        
        guard let url = currentRecordingURL else { return nil }
        currentRecordingURL = nil
        
        if discard || recordedDuration < Self.minimumRecordingDuration {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// One capture finished writing. The system input goes back only when
    /// none is left, so it never changes under a recording's stop tail.
    private func closedCapture() {
        openCaptureCount = max(openCaptureCount - 1, 0)
        restoreSystemDefaultInputWhenIdle()
    }

    private func restoreSystemDefaultInputWhenIdle() {
        if openCaptureCount == 0 {
            restoreSystemDefaultInputIfNeeded()
        }
    }

    #if os(macOS)
    private func switchSystemDefaultInput(to device: MicrophoneService.AudioDevice) {
        guard let targetID = hardware.deviceID(for: device) else { return }
        recordingDeviceID = targetID
        
        let currentDefault = hardware.defaultInputDevice()
        guard currentDefault != targetID else { return }
        
        if hardware.setDefaultInputDevice(targetID) {
            // The first switch of overlapping recordings holds the input to
            // go back to; a later one finds it already switched.
            if previousDefaultInputDeviceID == nil {
                previousDefaultInputDeviceID = currentDefault
            }
            print("Set the selected microphone as the system default input.")
        }
    }
    
    private func restoreSystemDefaultInputIfNeeded() {
        guard let previous = previousDefaultInputDeviceID else { return }
        previousDefaultInputDeviceID = nil
        
        // Restore only if the default is still the device we set,
        // so a manual change made by the user during recording is kept.
        if hardware.defaultInputDevice() == recordingDeviceID {
            _ = hardware.setDefaultInputDevice(previous)
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
            playback = try hardware.startPlayback(of: url) { [weak self] in
                // Only the playback that finished clears the state.
                guard let self, self.currentlyPlayingURL == url else { return }
                self.playback = nil
                self.isPlaying = false
                self.currentlyPlayingURL = nil
            }
            isPlaying = true
            currentlyPlayingURL = url
        } catch {
            print("Failed to play recording.")
            isPlaying = false
            currentlyPlayingURL = nil
        }
    }
    
    func stopPlaying() {
        playback?.stop()
        playback = nil
        if isPlaying { isPlaying = false }
        if currentlyPlayingURL != nil { currentlyPlayingURL = nil }
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

    /// Reads the open capture's loudness 20 times a second on the work queue,
    /// the only queue that touches the capture.
    private func startLevelMetering() {
        stopLevelMetering()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self, let capture = self.capture else { return }
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

/// One open recording from either capture path.
protocol RecordingCapture: AnyObject {
    /// Stops capturing and returns how long the recording is.
    func finish() -> TimeInterval
    /// How loud the microphone is right now, 0...1.
    func currentLevel() -> CGFloat
}

extension VoiceProcessedCapture: RecordingCapture {}
