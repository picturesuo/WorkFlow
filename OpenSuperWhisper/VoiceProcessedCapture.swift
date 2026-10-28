import AVFoundation
import Foundation

/// Who a recording is for. Only dictation hears just the speaker; a meeting
/// keeps everyone, including people on a call who come through the speakers.
enum RecordingPurpose {
    case dictation
    case meeting
}

/// How the next recording opens the microphone.
enum MicrophoneCaptureConfiguration: Equatable {
    /// The microphone as is, recorded by AVAudioRecorder.
    case standard
    /// Apple voice processing on an AVAudioEngine input: it takes audio this
    /// Mac plays out of what the microphone hears and suppresses noise.
    case voiceProcessing

    static func forNextRecording(_ purpose: RecordingPurpose, preferences: AppPreferences = .shared) -> Self {
        purpose == .dictation && preferences.reduceBackgroundAudio ? .voiceProcessing : .standard
    }
}

/// What the latest voice-processed recording actually did, so Settings never
/// suggests processing that did not run.
enum BackgroundAudioReductionStatus: Equatable {
    case notUsed
    case active
    /// It could not start, so that recording used the microphone as is.
    case unavailable(String)
    /// It stopped partway; the audio up to then was kept.
    case stopped(String)

    var notice: (title: String, detail: String)? {
        switch self {
        case .notUsed, .active:
            nil
        case .unavailable(let reason):
            ("Last recording used the microphone as is", "Background audio reduction couldn’t start. \(reason)")
        case .stopped(let reason):
            ("Background audio reduction stopped early", "\(reason) The audio recorded until then was kept.")
        }
    }
}

@MainActor
final class BackgroundAudioReductionMonitor: ObservableObject {
    static let shared = BackgroundAudioReductionMonitor()
    @Published var status: BackgroundAudioReductionStatus = .notUsed
}

/// The parts of AVAudioEngine a voice-processed recording uses, so tests can
/// drive it without opening a microphone.
protocol VoiceCaptureEngine: AnyObject {
    /// Switches the input to voice processing; the engine must be stopped.
    func enableVoiceProcessing() throws
    /// What the input delivers, read after voice processing is on.
    var inputFormat: AVAudioFormat { get }
    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void)
    func removeTap()
    func start() throws
    func stop()
    var isRunning: Bool { get }
    /// Called, on any thread, after the hardware changed under the engine.
    var onConfigurationChange: (() -> Void)? { get set }
}

final class AVAudioEngineVoiceCapture: VoiceCaptureEngine {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func enableVoiceProcessing() throws {
        let input = engine.inputNode
        if !input.isVoiceProcessingEnabled {
            try input.setVoiceProcessingEnabled(true)
        }
        // Voice processing ducks every other app for voice chat by default;
        // the least ducking macOS allows keeps the user's music playing.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        // Voice processing runs input and output together. The mixer gives
        // the output side a source; WorkFlow plays nothing through it.
        _ = engine.mainMixerNode
    }

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            block(buffer)
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    var isRunning: Bool {
        engine.isRunning
    }
}

/// Converts what the engine delivers to the recognizers' 16 kHz mono and
/// writes the same 16-bit WAV the standard recorder does, across restarts.
final class SpeechFileWriter {
    static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var recordedDuration: TimeInterval {
        lock.withLock { Double(framesWritten) / Self.sampleRate }
    }

    /// Starts converting from a new input format, keeping what is written.
    func begin(from format: AVAudioFormat) throws {
        try lock.withLock {
            drainConverter()
            guard let file, let converter = AVAudioConverter(from: format, to: file.processingFormat) else {
                throw VoiceProcessedCapture.Failure.unavailable("WorkFlow can’t convert this microphone’s audio.")
            }
            // Voice processing delivers the processed voice on the first
            // channel; mixing in the others could bring back what it removed.
            // Without a map, a discrete multichannel input converts to silence.
            converter.channelMap = [0]
            self.converter = converter
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            // A late buffer from before a restart has the old format.
            guard let file, let converter, buffer.format == converter.inputFormat else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status != .error {
                write(output)
            }
        }
    }

    /// Closes the file and returns the recorded duration.
    func finish() -> TimeInterval {
        lock.withLock {
            drainConverter()
            file = nil
            return Double(framesWritten) / Self.sampleRate
        }
    }

    func discard() {
        lock.withLock {
            converter = nil
            file = nil
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Flushes the resampler, whose latency otherwise drops the last few
    /// milliseconds. Callers hold the lock.
    private func drainConverter() {
        guard let converter, let file else { return }
        self.converter = nil
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return }
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            var error: NSError?
            output.frameLength = 0
            status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, output.frameLength > 0 else { break }
            write(output)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let file else { return }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            print("Failed to write voice-processed audio.")
        }
    }
}

/// Records one dictation through Apple voice processing. Every call runs on
/// the recorder's work queue; only the tap writes from the engine's thread.
final class VoiceProcessedCapture {
    enum Failure: Error, Equatable {
        case unavailable(String)
    }

    /// Bounds restarts when a device keeps changing during one recording.
    static let maximumRestarts = 3

    private let queue: DispatchQueue
    private let makeEngine: () -> VoiceCaptureEngine
    private let writer: SpeechFileWriter
    private var engine: VoiceCaptureEngine?
    private var restarts = 0
    /// Called on the work queue when the engine stopped and couldn't restart.
    var onStopped: ((String) -> Void)?

    init(url: URL, queue: DispatchQueue, makeEngine: @escaping () -> VoiceCaptureEngine) throws {
        self.queue = queue
        self.makeEngine = makeEngine
        writer = try SpeechFileWriter(url: url)
    }

    var recordedDuration: TimeInterval {
        writer.recordedDuration
    }

    /// Voice processing is switched on before the engine starts, and the tap
    /// uses the format it produces. On failure nothing keeps running and the
    /// file is removed.
    func start() throws {
        do {
            try startEngine()
        } catch {
            writer.discard()
            throw error
        }
    }

    /// Stops capturing, closes the file, and returns the recorded duration.
    func finish() -> TimeInterval {
        if let engine {
            tearDown(engine)
        }
        engine = nil
        return writer.finish()
    }

    static func reason(for error: Error) -> String {
        if case Failure.unavailable(let reason) = error {
            return reason
        }
        return "macOS couldn’t turn on voice processing for this microphone and output (error \((error as NSError).code))."
    }

    private func startEngine() throws {
        let engine = makeEngine()
        do {
            try engine.enableVoiceProcessing()
            let format = engine.inputFormat
            // Installing a tap with an empty format raises an exception.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw Failure.unavailable("The microphone reported no audio format.")
            }
            try writer.begin(from: format)
            engine.installTap(format: format) { [writer] buffer in
                writer.append(buffer)
            }
            engine.onConfigurationChange = { [weak self, weak engine] in
                self?.queue.async {
                    guard let self, let engine, engine === self.engine else { return }
                    self.handleConfigurationChange(of: engine)
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            tearDown(engine)
            throw error
        }
    }

    /// The engine stops itself when the hardware changes, for example when
    /// AirPods connect. Restart it with the new format into the same file.
    private func handleConfigurationChange(of engine: VoiceCaptureEngine) {
        guard !engine.isRunning else { return }
        tearDown(engine)
        self.engine = nil
        guard restarts < Self.maximumRestarts else {
            onStopped?("The audio devices kept changing during the last recording.")
            return
        }
        restarts += 1
        do {
            try startEngine()
        } catch {
            onStopped?("The audio device changed during the last recording and voice processing couldn’t restart.")
        }
    }

    private func tearDown(_ engine: VoiceCaptureEngine) {
        engine.onConfigurationChange = nil
        engine.removeTap()
        engine.stop()
    }
}
