import AVFoundation
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
    
    /// The open recording: AVAudioRecorder, or the voice-processed engine.
    private var capture: RecordingCapture?
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?
    private var connectionCheckTimer: DispatchSourceTimer?
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
    
    @discardableResult
    func startRecording(sessionID: UUID, purpose: RecordingPurpose = .dictation, completion: ((String?) -> Void)? = nil) -> Bool {
        guard sessionGate.reserve(sessionID) else { return false }

        // Everything below costs CoreAudio HAL round-trips (device queries,
        // AudioQueue start for the notification sound) — 20-35 ms that used to
        // block the main thread right when the indicator appear animation
        // starts, so the whole start sequence runs on the work queue.
        let playSound = AppPreferences.shared.playSoundOnRecordStart
        let configuration = MicrophoneCaptureConfiguration.forNextRecording(purpose)
        workQueue.async {
            guard let activeMic = MicrophoneService.shared.getActiveMicrophone() else {
                print("Cannot start recording - no audio input available")
                _ = self.sessionGate.take(ifMatching: sessionID)
                DispatchQueue.main.async {
                    completion?("The selected microphone is no longer available.")
                }
                return
            }
            
            if playSound {
                self.playNotificationSound()
            }
            
            let requiresConnection = MicrophoneService.shared.isActiveMicrophoneRequiresConnection()
            self.updateRecordingState(isRecording: false, isConnecting: requiresConnection)
            let failure = self.performStart(activeMic: activeMic, configuration: configuration, monitorConnection: requiresConnection, sessionID: sessionID)
            DispatchQueue.main.async {
                completion?(failure)
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
            channelCount = MicrophoneService.shared.getInputChannelCount(for: activeMic)
            print("Recording with \(channelCount) input channel(s).")
        }
        #endif

        // If voice processing can't start, this recording uses the
        // microphone as is and Settings says so.
        if configuration == .voiceProcessing, startVoiceProcessedCapture(at: fileURL, monitorConnection: monitorConnection) {
            print("Recording started with voice processing")
            return nil
        }
        
        // 16-bit integer PCM: half the disk/IO of Float32 with no quality loss
        // for speech recognition (whisper consumes 16 kHz mono anyway).
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        
        do {
            let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder.delegate = self
            audioRecorder.isMeteringEnabled = monitorConnection
            guard audioRecorder.record() == true else {
                print("Failed to start recording: AVAudioRecorder declined the request")
                currentRecordingURL = nil
                try? FileManager.default.removeItem(at: fileURL)
                restoreSystemDefaultInputIfNeeded()
                _ = sessionGate.take(ifMatching: sessionID)
                updateRecordingState(isRecording: false, isConnecting: false)
                return "The microphone declined the recording request."
            }
            capture = audioRecorder
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
            restoreSystemDefaultInputIfNeeded()
            _ = sessionGate.take(ifMatching: sessionID)
            updateRecordingState(isRecording: false, isConnecting: false)
            return error.localizedDescription
        }
    }
    
    /// Starts the voice-processed engine; false leaves nothing running.
    private func startVoiceProcessedCapture(at fileURL: URL, monitorConnection: Bool) -> Bool {
        do {
            let voiceCapture = try VoiceProcessedCapture(url: fileURL, queue: workQueue) {
                AVAudioEngineVoiceCapture()
            }
            voiceCapture.onStopped = { reason in
                Self.publishBackgroundAudioReduction(.stopped(reason))
            }
            try voiceCapture.start()
            capture = voiceCapture
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
            workQueue.async {
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
                self.updateRecordingState(isRecording: false, isConnecting: false)
                
                self.workQueue.asyncAfter(deadline: .now() + Self.stopTailDuration) {
                    let recordedDuration = capture.finish()
                    // A new recording may have started during the tail window;
                    // it will restore the system input itself when it stops.
                    if self.capture == nil {
                        self.restoreSystemDefaultInputIfNeeded()
                    }
                    
                    if recordedDuration < Self.minimumRecordingDuration {
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: url)
                    }
                }
            }
        }
    }
    
    func cancelRecording(sessionID: UUID) {
        workQueue.sync {
            guard sessionGate.take(ifMatching: sessionID) else { return }
            _ = performStop(discard: true)
        }
    }
    
    private func performStop(discard: Bool) -> URL? {
        let recordedDuration = capture?.finish() ?? 0
        capture = nil
        stopConnectionMonitoring()
        restoreSystemDefaultInputIfNeeded()
        updateRecordingState(isRecording: false, isConnecting: false)
        
        guard let url = currentRecordingURL else { return nil }
        currentRecordingURL = nil
        
        if discard || recordedDuration < Self.minimumRecordingDuration {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
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
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        workQueue.async {
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
}

extension AVAudioRecorder: RecordingCapture {
    func finish() -> TimeInterval {
        let recordedDuration = currentTime
        stop()
        return recordedDuration
    }
}

extension VoiceProcessedCapture: RecordingCapture {}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
