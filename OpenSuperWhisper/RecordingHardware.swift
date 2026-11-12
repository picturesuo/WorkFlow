import AppKit
import AVFoundation
import CoreAudio
import DictationCore
import Foundation

/// The Mac's audio hardware as the recorder uses it. The app passes the real
/// devices; tests script them, so the recorder's whole lifecycle (start,
/// stop, cancel, a capture that dies on its own, overlapping recordings) runs
/// without opening a microphone or playing a sound.
protocol RecordingHardware: AnyObject {
    /// The microphone the next recording uses, if one is available.
    func activeMicrophone() -> MicrophoneService.AudioDevice?
    /// Whether that microphone delivers audio only once it has connected,
    /// as Bluetooth and Continuity microphones do.
    func activeMicrophoneRequiresConnection() -> Bool
    func inputChannelCount(for device: MicrophoneService.AudioDevice) -> Int
    func deviceID(for device: MicrophoneService.AudioDevice) -> AudioDeviceID?
    func defaultInputDevice() -> AudioDeviceID?
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool
    func playStartSound()
    /// Opens the microphone as it is and starts recording to `url`.
    /// `onEnded` is called, on any thread, if the capture stops on its own.
    func startStandardCapture(at url: URL, channels: Int, onEnded: @escaping () -> Void) throws -> RecordingCapture
    func makeVoiceEngine() -> VoiceCaptureEngine
    /// Starts playing a saved recording. `onFinished` is called on the main
    /// thread when it has played to its end.
    func startPlayback(of url: URL, onFinished: @escaping () -> Void) throws -> RecordingPlayback
}

/// A saved recording that is playing.
protocol RecordingPlayback: AnyObject {
    func stop()
}

/// Why the standard capture could not start; `message` is shown to the user.
enum StandardCaptureError: Error, Equatable {
    case declined

    var message: String {
        switch self {
        case .declined: "The microphone declined the recording request."
        }
    }
}

final class LiveRecordingHardware: RecordingHardware {
    private let microphones: MicrophoneService

    init(microphones: MicrophoneService = .shared) {
        self.microphones = microphones
    }

    func activeMicrophone() -> MicrophoneService.AudioDevice? {
        microphones.getActiveMicrophone()
    }

    func activeMicrophoneRequiresConnection() -> Bool {
        microphones.isActiveMicrophoneRequiresConnection()
    }

    func inputChannelCount(for device: MicrophoneService.AudioDevice) -> Int {
        microphones.getInputChannelCount(for: device)
    }

    func deviceID(for device: MicrophoneService.AudioDevice) -> AudioDeviceID? {
        microphones.getCoreAudioDeviceID(for: device)
    }

    func defaultInputDevice() -> AudioDeviceID? {
        microphones.getCurrentSystemDefaultInputDevice()
    }

    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        microphones.setSystemDefaultInputDevice(deviceID)
    }

    // Loaded once: decoding the mp3 from disk takes ~15 ms on the main thread,
    // which drops frames of the indicator appear animation on every hotkey press.
    private static let startSound: NSSound? = {
        guard let soundURL = Bundle.main.url(forResource: "notification", withExtension: "mp3"),
              let sound = NSSound(contentsOf: soundURL, byReference: false) else {
            print("Failed to load notification sound file")
            return nil
        }
        sound.volume = 0.3
        return sound
    }()

    func playStartSound() {
        guard let sound = Self.startSound else {
            NSSound.beep()
            return
        }
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
    }

    func startStandardCapture(at url: URL, channels: Int, onEnded: @escaping () -> Void) throws -> RecordingCapture {
        try StandardCapture(url: url, channels: channels, onEnded: onEnded)
    }

    func makeVoiceEngine() -> VoiceCaptureEngine {
        AVAudioEngineVoiceCapture()
    }

    func startPlayback(of url: URL, onFinished: @escaping () -> Void) throws -> RecordingPlayback {
        try LivePlayback(url: url, onFinished: onFinished)
    }
}

/// The microphone as it is, recorded by AVAudioRecorder.
final class StandardCapture: NSObject, RecordingCapture, AVAudioRecorderDelegate {
    private let recorder: AVAudioRecorder
    private let url: URL
    private let onEnded: () -> Void
    private let lock = NSLock()
    private var endedOnItsOwn = false

    init(url: URL, channels: Int, onEnded: @escaping () -> Void) throws {
        // 16-bit integer PCM: half the disk/IO of Float32 with no quality loss
        // for speech recognition (whisper consumes 16 kHz mono anyway).
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        self.url = url
        self.onEnded = onEnded
        super.init()
        recorder.delegate = self
        // Metering drives the record control's live level.
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            print("Failed to start recording: AVAudioRecorder declined the request")
            throw StandardCaptureError.declined
        }
    }

    func finish() -> TimeInterval {
        let ended = lock.withLock { endedOnItsOwn }
        let recordedDuration = recorder.currentTime
        recorder.stop()
        // A recorder that already stopped reports no time; the audio it
        // wrote until then is what is on disk.
        return ended ? max(recordedDuration, Self.salvagedDuration(of: url)) : recordedDuration
    }

    func currentLevel() -> CGFloat {
        guard recorder.isMeteringEnabled, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        return InputLevelMeter.normalized(decibels: recorder.averagePower(forChannel: 0))
    }

    /// How much audio a capture that stopped on its own left in `url`. A
    /// recorder that never closed its file leaves every sample behind a
    /// header that declares none; that header is finished in place, exactly
    /// as launch recovery finishes one, so the audio can be read.
    static func salvagedDuration(of url: URL) -> TimeInterval {
        let readable = RecordingRecovery.audioDuration(of: url) ?? 0
        guard readable < AudioRecorder.minimumRecordingDuration,
              let layout = RecordingRecovery.unfinishedLayout(of: url),
              layout.duration >= AudioRecorder.minimumRecordingDuration
        else { return readable }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return RecordingRecovery.repairHeader(of: url, layout, modified: modified) ? layout.duration : readable
    }

    private func ended() {
        let first = lock.withLock {
            defer { endedOnItsOwn = true }
            return !endedOnItsOwn
        }
        if first { onEnded() }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        ended()
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        ended()
    }
}

/// A saved recording played through the Mac's output.
final class LivePlayback: NSObject, RecordingPlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private let onFinished: () -> Void

    init(url: URL, onFinished: @escaping () -> Void) throws {
        player = try AVAudioPlayer(contentsOf: url)
        self.onFinished = onFinished
        super.init()
        player.delegate = self
        player.play()
    }

    func stop() {
        player.stop()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished()
    }
}
