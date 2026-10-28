import AVFoundation
import XCTest
@testable import OpenSuperWhisper

/// The opt-in Settings switch through to what the recognizer hears. A
/// scripted engine stands in for AVAudioEngine, so nothing opens the
/// microphone or plays sound. It proves the configuration, format handling,
/// and lifecycle, not acoustic suppression: Apple's voice processing only runs
/// on real audio hardware.
final class BackgroundAudioReductionTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let reference = root.appendingPathComponent("jfk.wav")
    private static let tinyModel = root.appendingPathComponent("ggml-tiny.en.bin")

    private let queue = DispatchQueue(label: "BackgroundAudioReductionTests")
    private var directory: URL!
    private var originalPreference: Any?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-voice-capture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        originalPreference = UserDefaults.standard.object(forKey: "reduceBackgroundAudio")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        if let originalPreference {
            UserDefaults.standard.set(originalPreference, forKey: "reduceBackgroundAudio")
        } else {
            UserDefaults.standard.removeObject(forKey: "reduceBackgroundAudio")
        }
        super.tearDown()
    }

    // MARK: Switch and configuration

    func testOffByDefaultSoEveryRecordingKeepsTodaysMicrophone() {
        UserDefaults.standard.removeObject(forKey: "reduceBackgroundAudio")
        XCTAssertFalse(AppPreferences.shared.reduceBackgroundAudio)
        XCTAssertEqual(MicrophoneCaptureConfiguration.forNextRecording(.dictation), .standard)
        XCTAssertEqual(MicrophoneCaptureConfiguration.forNextRecording(.meeting), .standard)
        XCTAssertNil(UserDefaults.standard.object(forKey: "reduceBackgroundAudio"), "Reading the default stores nothing")
    }

    @MainActor
    func testSettingsSwitchIsSavedAndTheNextDictationAsksForVoiceProcessing() {
        UserDefaults.standard.removeObject(forKey: "reduceBackgroundAudio")
        let model = SettingsViewModel(credentials: StoredCredentialStatus(bedrock: { false }, cleanup: { _ in false }))
        XCTAssertFalse(model.reduceBackgroundAudio)

        model.reduceBackgroundAudio = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: "reduceBackgroundAudio") as? Bool, true)
        XCTAssertEqual(MicrophoneCaptureConfiguration.forNextRecording(.dictation), .voiceProcessing)
        XCTAssertEqual(MicrophoneCaptureConfiguration.forNextRecording(.meeting), .standard,
                       "Echo cancellation would remove people on a call who come through the speakers")
        XCTAssertTrue(SettingsViewModel(credentials: StoredCredentialStatus(bedrock: { false }, cleanup: { _ in false })).reduceBackgroundAudio,
                      "Reopening Settings shows the saved choice")

        model.reduceBackgroundAudio = false
        XCTAssertEqual(MicrophoneCaptureConfiguration.forNextRecording(.dictation), .standard)
    }

    func testVoiceProcessingIsOnBeforeTheTapAndTheEngineStart() throws {
        let engine = ScriptedEngine(
            before: try format(44_100, channels: 2),
            after: try format(48_000, channels: 3)
        )
        let capture = try makeCapture(engines: [engine])
        try queue.sync { try capture.start() }

        XCTAssertEqual(engine.events, ["enableVoiceProcessing", "inputFormat 48000 3", "installTap 48000 3", "start"],
                       "The tap uses the format voice processing produces, read after enabling it")
        _ = queue.sync { capture.finish() }
        XCTAssertEqual(engine.events.suffix(2), ["removeTap", "stop"])
    }

    // MARK: Recognizer input and output

    /// Speech arrives the way voice processing hands it over (48 kHz, three
    /// channels) and leaves as the 16 kHz mono 16-bit WAV the recognizers read.
    func testCapturedSpeechReachesTheRecognizerAsTheSameWords() async throws {
        let model = try fixture(Self.tinyModel)
        let speech = try samples(of: try fixture(Self.reference), at: 48_000)
        let tone = (0..<speech.count).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let url = try record([speech, tone, tone], format: try format(48_000, channels: 3))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(Double(file.length) / 16_000, 11, accuracy: 0.02, "No audio is lost or padded")

        // Only the processed first channel is kept: the speech arrives at its
        // level, and the tone on the others never reaches the recognizer.
        let captured = try samples(of: url, at: 16_000)
        let baseline = try samples(of: Self.reference, at: 16_000)
        XCTAssertEqual(rms(captured), rms(baseline), accuracy: rms(baseline) * 0.05, "The speech itself, not silence")
        let sine = (0..<16_000).map { 0.25 * Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        XCTAssertEqual(amplitude(of: 440, in: sine, sampleRate: 16_000), 0.25, accuracy: 0.01, "The measure finds a tone that is there")
        XCTAssertLessThan(amplitude(of: 440, in: captured, sampleRate: 16_000), amplitude(of: 440, in: baseline, sampleRate: 16_000) + 0.005)

        let whisper = WhisperEngine()
        try whisper.load(modelPath: model.path)
        let direct = try await whisper.transcribeAudio(url: Self.reference, settings: OpenSuperWhisper.Settings())
        let throughCapture = try await whisper.transcribeAudio(url: url, settings: OpenSuperWhisper.Settings())
        print("VOICE_CAPTURE_TRANSCRIPT direct=\(direct) captured=\(throughCapture)")
        XCTAssertTrue(words(throughCapture).contains("ask not what your country can do for you"), throughCapture)
        XCTAssertEqual(words(throughCapture), words(direct), "Same words as the reference recording read directly")
    }

    /// Background-only input: the capture adds nothing the recognizer turns into words.
    func testQuietBackgroundAloneProducesNoWords() async throws {
        let model = try fixture(Self.tinyModel)
        var seed: UInt32 = 0x1234_5678
        let noise = (0..<(48_000 * 3)).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.04
        }
        let url = try record([noise], format: try format(48_000, channels: 1))
        XCTAssertEqual(Double(try AVAudioFile(forReading: url).length) / 16_000, 3, accuracy: 0.02)
        XCTAssertGreaterThan(rms(try samples(of: url, at: 16_000)), 0.005, "The noise reached the file, so an empty transcript means something")

        let whisper = WhisperEngine()
        try whisper.load(modelPath: model.path)
        let text = try await whisper.transcribeAudio(url: url, settings: OpenSuperWhisper.Settings())
        XCTAssertEqual(text, "", "Silence-level noise stays empty, so the dictation is discarded")
    }

    // MARK: Unsupported setups

    func testUnsupportedVoiceProcessingStopsCleanlyAndSaysWhy() throws {
        let engine = ScriptedEngine(before: try format(48_000, channels: 1), after: try format(48_000, channels: 1))
        engine.voiceProcessingError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10876)
        let url = directory.appendingPathComponent("unsupported.wav")
        let capture = try VoiceProcessedCapture(url: url, queue: queue) { engine }

        XCTAssertThrowsError(try queue.sync { try capture.start() }) { error in
            let reason = VoiceProcessedCapture.reason(for: error)
            XCTAssertTrue(reason.contains("-10876"), reason)
            let notice = BackgroundAudioReductionStatus.unavailable(reason).notice
            XCTAssertEqual(notice?.title, "Last recording used the microphone as is")
            XCTAssertTrue(notice?.detail.contains(reason) == true)
        }
        XCTAssertFalse(engine.events.contains("start"))
        XCTAssertEqual(engine.events.suffix(2), ["removeTap", "stop"], "Nothing keeps running")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "The standard recorder gets a clean path")
    }

    /// Without microphone access the input reports 0 Hz and no channels;
    /// installing a tap with that format raises an exception.
    func testEmptyInputFormatNeverInstallsATap() throws {
        var empty = AudioStreamBasicDescription()
        let engine = ScriptedEngine(before: try format(48_000, channels: 1), after: try XCTUnwrap(AVAudioFormat(streamDescription: &empty)))
        let capture = try makeCapture(engines: [engine])

        XCTAssertThrowsError(try queue.sync { try capture.start() }) { error in
            XCTAssertEqual(error as? VoiceProcessedCapture.Failure, .unavailable("The microphone reported no audio format."))
        }
        XCTAssertFalse(engine.events.contains { $0.hasPrefix("installTap") || $0 == "start" })
    }

    func testSuccessAndNotStartedShowNoNotice() {
        XCTAssertNil(BackgroundAudioReductionStatus.active.notice)
        XCTAssertNil(BackgroundAudioReductionStatus.notUsed.notice)
        XCTAssertEqual(BackgroundAudioReductionStatus.stopped("The device changed.").notice?.detail,
                       "The device changed. The audio recorded until then was kept.")
    }

    // MARK: Device changes

    func testDeviceChangeRestartsWithTheNewFormatIntoTheSameRecording() throws {
        let first = ScriptedEngine(before: try format(48_000, channels: 1), after: try format(48_000, channels: 1))
        let second = ScriptedEngine(before: try format(44_100, channels: 2), after: try format(44_100, channels: 2))
        let capture = try makeCapture(engines: [first, second])
        try queue.sync { try capture.start() }
        try first.deliver(seconds: 1)

        first.changeHardware()
        queue.sync {}
        XCTAssertEqual(first.events.suffix(2), ["removeTap", "stop"])
        XCTAssertEqual(second.events, ["enableVoiceProcessing", "inputFormat 44100 2", "installTap 44100 2", "start"])

        try first.deliverLate(seconds: 0.5)
        try second.deliver(seconds: 1)
        let duration = queue.sync { capture.finish() }
        XCTAssertEqual(duration, 2, accuracy: 0.02, "Both devices' audio, without the late buffer from the old format")
    }

    func testConfigurationChangeWhileStillRunningIsIgnored() throws {
        let engine = ScriptedEngine(before: try format(48_000, channels: 1), after: try format(48_000, channels: 1))
        var made = 0
        let capture = try VoiceProcessedCapture(url: directory.appendingPathComponent("running.wav"), queue: queue) {
            made += 1
            return engine
        }
        try queue.sync { try capture.start() }
        engine.onConfigurationChange?()
        queue.sync {}
        XCTAssertEqual(made, 1)
        XCTAssertEqual(engine.events.last, "start")
        _ = queue.sync { capture.finish() }
    }

    func testFailedRestartKeepsTheAudioSoFarAndSaysSo() throws {
        let first = ScriptedEngine(before: try format(48_000, channels: 1), after: try format(48_000, channels: 1))
        let second = ScriptedEngine(before: try format(48_000, channels: 1), after: try format(48_000, channels: 1))
        second.startError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
        let url = directory.appendingPathComponent("interrupted.wav")
        let capture = try VoiceProcessedCapture(url: url, queue: queue, makeEngine: sequence([first, second]))
        var stopped: [String] = []
        capture.onStopped = { stopped.append($0) }
        try queue.sync { try capture.start() }
        try first.deliver(seconds: 1)

        first.changeHardware()
        queue.sync {}
        XCTAssertEqual(stopped, ["The audio device changed during the last recording and voice processing couldn’t restart."])
        XCTAssertEqual(second.events.suffix(2), ["removeTap", "stop"])

        let duration = queue.sync { capture.finish() }
        XCTAssertEqual(duration, 1, accuracy: 0.02)
        XCTAssertEqual(Double(try AVAudioFile(forReading: url).length) / 16_000, 1, accuracy: 0.02)
    }

    func testRestartsAreBoundedWhenDevicesKeepChanging() throws {
        let engines = try (0...VoiceProcessedCapture.maximumRestarts).map { _ in
            ScriptedEngine(before: try format(48_000, channels: 1), after: try format(48_000, channels: 1))
        }
        let capture = try VoiceProcessedCapture(url: directory.appendingPathComponent("bounded.wav"), queue: queue, makeEngine: sequence(engines))
        var stopped: [String] = []
        capture.onStopped = { stopped.append($0) }
        try queue.sync { try capture.start() }
        for engine in engines {
            engine.changeHardware()
            queue.sync {}
        }
        XCTAssertEqual(stopped, ["The audio devices kept changing during the last recording."])
        XCTAssertTrue(engines.allSatisfy { $0.events.contains("start") })
        _ = queue.sync { capture.finish() }
    }

    // MARK: Helpers

    private func makeCapture(engines: [ScriptedEngine]) throws -> VoiceProcessedCapture {
        try VoiceProcessedCapture(url: directory.appendingPathComponent("\(UUID()).wav"), queue: queue, makeEngine: sequence(engines))
    }

    private func sequence(_ engines: [ScriptedEngine]) -> () -> VoiceCaptureEngine {
        var remaining = engines
        return { remaining.removeFirst() }
    }

    /// Delivers per-channel samples in tap-sized buffers and returns the file.
    private func record(_ channels: [[Float]], format: AVAudioFormat) throws -> URL {
        let engine = ScriptedEngine(before: format, after: format)
        let url = directory.appendingPathComponent("\(UUID()).wav")
        let capture = try VoiceProcessedCapture(url: url, queue: queue) { engine }
        try queue.sync { try capture.start() }
        let total = channels[0].count
        var offset = 0
        while offset < total {
            let count = min(4_800, total - offset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for (index, channel) in channels.enumerated() {
                channel.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![index].update(from: source.baseAddress! + offset, count: count)
                }
            }
            engine.deliver(buffer)
            offset += count
        }
        _ = queue.sync { capture.finish() }
        return url
    }

    private func format(_ sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    private func fixture(_ url: URL) throws -> URL {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is not in the repository root")
        return url
    }

    /// Mono Float32 samples of a file's first channel at the given rate.
    private func samples(of url: URL, at sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: source.format, to: target))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * sampleRate / source.format.sampleRate) + 1024))
        var consumed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1)))
    }

    /// Goertzel estimate of a sine's amplitude at one frequency.
    private func amplitude(of frequency: Double, in samples: [Float], sampleRate: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var previous = 0.0, beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return 2 * sqrt(max(power, 0)) / Double(samples.count)
    }

    private func words(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Records what the capture asks of AVAudioEngine and delivers buffers the
/// way its tap would.
private final class ScriptedEngine: VoiceCaptureEngine {
    private let before: AVAudioFormat
    private let after: AVAudioFormat
    private var voiceProcessing = false
    private var tap: ((AVAudioPCMBuffer) -> Void)?
    private var lateTap: ((AVAudioPCMBuffer) -> Void)?
    var events: [String] = []
    var voiceProcessingError: Error?
    var startError: Error?
    var isRunning = false
    var onConfigurationChange: (() -> Void)?

    init(before: AVAudioFormat, after: AVAudioFormat) {
        self.before = before
        self.after = after
    }

    func enableVoiceProcessing() throws {
        events.append("enableVoiceProcessing")
        if let voiceProcessingError { throw voiceProcessingError }
        voiceProcessing = true
    }

    var inputFormat: AVAudioFormat {
        let format = voiceProcessing ? after : before
        events.append("inputFormat \(Int(format.sampleRate)) \(format.channelCount)")
        return format
    }

    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void) {
        events.append("installTap \(Int(format.sampleRate)) \(format.channelCount)")
        tap = block
        lateTap = block
    }

    func removeTap() {
        events.append("removeTap")
        tap = nil
    }

    func start() throws {
        events.append("start")
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        events.append("stop")
        isRunning = false
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        tap?(buffer)
    }

    /// Seconds of a quiet tone in the post-voice-processing format.
    func deliver(seconds: Double) throws {
        tap?(try makeBuffer(seconds: seconds))
    }

    /// A buffer the old tap hands over after a restart already happened.
    func deliverLate(seconds: Double) throws {
        lateTap?(try makeBuffer(seconds: seconds))
    }

    func changeHardware() {
        isRunning = false
        onConfigurationChange?()
    }

    private func makeBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(after.sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: after, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(after.channelCount) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = 0.1 * Float(sin(2 * Double.pi * 220 * Double(frame) / after.sampleRate))
            }
        }
        return buffer
    }
}
