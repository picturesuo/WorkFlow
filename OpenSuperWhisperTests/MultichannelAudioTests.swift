import AVFoundation
import FluidAudio
import XCTest
@testable import OpenSuperWhisper

/// What the recognizers hear from a recording with more than one channel.
///
/// The recordings are written with `AVAudioFile` in the recorder's own
/// settings, with the repository's `jfk.wav` as the voice, so nothing opens a
/// microphone. They prove which channels reach the recognizers and at what
/// level, not how a real multi-input device sounds or what `AVAudioRecorder`
/// itself writes for one.
final class SpeechAudioReaderTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let reference = root.appendingPathComponent("jfk.wav")

    private var directory: URL!
    private var voice: [Float] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-multichannel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        voice = try Self.voiceSamples()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The 16 kHz one-channel samples of `jfk.wav`.
    static func voiceSamples() throws -> [Float] {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: reference.path), "jfk.wav is not in the repository root")
        return try AudioConverter().resampleAudioFile(reference)
    }

    /// What the recorder asks `AVAudioRecorder` for, with `channels` inputs.
    static func recorderSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
    }

    /// Writes one channel of samples per entry of `channels` and returns the file.
    static func write(_ channels: [[Float]], to url: URL, settings: [String: Any]? = nil) throws -> URL {
        let file = try AVAudioFile(forWriting: url, settings: settings ?? recorderSettings(channels: channels.count))
        let frames = channels.map(\.count).max() ?? 0
        guard frames > 0 else { return url }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (index, samples) in channels.enumerated() {
            for frame in 0..<frames {
                data[index][frame] = frame < samples.count ? samples[frame] : 0
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func recording(_ channels: [[Float]], named name: String = "recording", settings: [String: Any]? = nil) throws -> URL {
        try Self.write(channels, to: directory.appendingPathComponent("\(name)-\(UUID().uuidString).wav"), settings: settings)
    }

    private var silence: [Float] { [Float](repeating: 0, count: voice.count) }

    private func tone(_ amplitude: Float, frequency: Float = 440) -> [Float] {
        (0..<voice.count).map { amplitude * sinf(2 * .pi * frequency * Float($0) / 16_000) }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// How alike two signals are, -1...1, over their common length.
    static func correlation(_ first: [Float], _ second: [Float]) -> Float {
        let count = min(first.count, second.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0, a: Float = 0, b: Float = 0
        for index in 0..<count {
            dot += first[index] * second[index]
            a += first[index] * first[index]
            b += second[index] * second[index]
        }
        return a > 0 && b > 0 ? dot / (a.squareRoot() * b.squareRoot()) : 0
    }

    /// The samples Parakeet is given for a recording up to the segmented
    /// limit: the engine's own two steps.
    private func parakeetSamples(_ url: URL) throws -> [Float] {
        let source = try SpeechAudioReader.monoSource(for: url)
        defer { source.discard() }
        return try AudioConverter().resampleAudioFile(source.url)
    }

    private func whisperSamples(_ url: URL) async throws -> [Float] {
        let samples = try await WhisperEngine().convertAudioToPCM(fileURL: url)
        return try XCTUnwrap(samples)
    }

    private func assertHearsTheVoice(_ samples: [Float], level: Float = 1, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let voiceRMS = Self.rms(voice)
        XCTAssertEqual(Self.rms(samples) / voiceRMS, level, accuracy: 0.03, "Level: \(message)", file: file, line: line)
        XCTAssertGreaterThan(Self.correlation(samples, voice), 0.98, "Signal: \(message)", file: file, line: line)
    }

    // MARK: - One channel is untouched

    func testAOneChannelRecordingIsReadAsItIs() throws {
        let source = try SpeechAudioReader.monoSource(for: Self.reference)
        XCTAssertEqual(source.url, Self.reference)
        XCTAssertFalse(source.isTemporary)
        source.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.reference.path), "Discarding never removes the recording itself")
        XCTAssertEqual(try parakeetSamples(Self.reference), voice, "Sample for sample what Parakeet read before")
    }

    // MARK: - A voice on any input

    func testAVoiceOnAnyInputOfAMultiInputMicrophoneReachesBothRecognizersAtItsOwnLevel() async throws {
        for channelCount in [2, 3, 4, 8, 16] {
            for input in Set([0, channelCount / 2, channelCount - 1]).sorted() {
                var channels = [[Float]](repeating: silence, count: channelCount)
                channels[input] = voice
                let url = try recording(channels)
                let name = "input \(input + 1) of \(channelCount)"
                assertHearsTheVoice(try parakeetSamples(url), "Parakeet, \(name)")
                assertHearsTheVoice(try await whisperSamples(url), "Whisper, \(name)")
            }
        }
    }

    func testTheSameVoiceOnEveryChannelKeepsItsLevel() async throws {
        for channelCount in [2, 3, 6] {
            let url = try recording([[Float]](repeating: voice, count: channelCount))
            assertHearsTheVoice(try parakeetSamples(url), "Parakeet, \(channelCount) channels")
            assertHearsTheVoice(try await whisperSamples(url), "Whisper, \(channelCount) channels")
        }
    }

    func testIdleInputsWithHissDoNotLowerTheVoice() async throws {
        // An eight-input interface: one microphone, and hiss 50 dB under it
        // on the other seven.
        var channels = (0..<8).map { tone(0.0005, frequency: 300 + Float($0) * 91) }
        channels[5] = voice
        let url = try recording(channels)
        assertHearsTheVoice(try parakeetSamples(url), "Parakeet")
        assertHearsTheVoice(try await whisperSamples(url), "Whisper")
    }

    func testAQuieterSecondSourceIsStillHeard() throws {
        // A microphone and, 20 dB under it, a tone standing in for people on
        // a call who arrive on another channel.
        let other = tone(Self.rms(voice) * 0.1 * Float(2).squareRoot(), frequency: 700)
        let samples = try parakeetSamples(try recording([voice, other]))
        let expected = zip(voice, other).map { ($0 + $1) / 2 }
        XCTAssertGreaterThan(Self.correlation(samples, expected), 0.99, "Both channels are in the mix")
        XCTAssertGreaterThan(Self.correlation(samples, other), 0.05, "The quieter channel was not dropped")
    }

    // MARK: - Layouts and cancellation

    func testTwoChannelsThatCancelAreNotSilence() async throws {
        let url = try recording([voice, voice.map { -$0 }])
        assertHearsTheVoice(try parakeetSamples(url), "Parakeet")
        assertHearsTheVoice(try await whisperSamples(url), "Whisper")
    }

    func testASurroundFileWithTheVoiceOffCenterIsHeard() async throws {
        // 5.1 in the order L R C LFE Ls Rs, with the voice on front left only.
        var settings = Self.recorderSettings(channels: 6)
        settings[AVSampleRateKey] = 48_000.0
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        // The voice at 48 kHz, each sample held three times: enough for a
        // level check, which is all this needs.
        let upsampled = voice.flatMap { [$0, $0, $0] }
        var channels = [[Float]](repeating: [Float](repeating: 0, count: upsampled.count), count: 6)
        channels[0] = upsampled
        let url = try Self.write(channels, to: directory.appendingPathComponent("surround.wav"), settings: settings)
        XCTAssertNotNil(try AVAudioFile(forReading: url).processingFormat.channelLayout, "The file carries its layout")

        let voiceRMS = Self.rms(voice)
        let parakeet = try parakeetSamples(url)
        let whisper = try await whisperSamples(url)
        XCTAssertEqual(Self.rms(parakeet) / voiceRMS, 1, accuracy: 0.1, "Parakeet")
        XCTAssertEqual(Self.rms(whisper) / voiceRMS, 1, accuracy: 0.1, "Whisper")
    }

    func testACompressedStereoFileWithTheVoiceOnTheRightIsHeard() async throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 64_000
        ]
        let url = try Self.write([silence, voice], to: directory.appendingPathComponent("stereo.m4a"), settings: settings)
        let voiceRMS = Self.rms(voice)
        let parakeet = try parakeetSamples(url)
        let whisper = try await whisperSamples(url)
        XCTAssertEqual(Self.rms(parakeet) / voiceRMS, 1, accuracy: 0.15, "Parakeet")
        XCTAssertEqual(Self.rms(whisper) / voiceRMS, 1, accuracy: 0.15, "Whisper")
    }

    // MARK: - Nothing to hear

    func testSilenceOnEveryChannelStaysSilence() throws {
        let samples = try parakeetSamples(try recording([silence, silence, silence]))
        XCTAssertLessThanOrEqual(abs(samples.count - voice.count), 2)
        XCTAssertEqual(Self.rms(samples), 0)
    }

    func testAMultichannelFileWithNoAudioIsLeftAlone() throws {
        let url = try recording([[], [], []])
        let source = try SpeechAudioReader.monoSource(for: url)
        XCTAssertEqual(source.url, url)
        XCTAssertFalse(source.isTemporary)
    }

    // MARK: - The temporary mix

    func testTheTemporaryMixIsOneChannelAtTheSameRateAndIsRemoved() throws {
        let url = try recording([silence, voice, silence])
        let source = try SpeechAudioReader.monoSource(for: url)
        XCTAssertTrue(source.isTemporary)
        XCTAssertNotEqual(source.url, url)
        XCTAssertFalse(source.url.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path),
                       "Never in the folder launch recovery adopts recordings from")
        do {
            let mix = try AVAudioFile(forReading: source.url)
            XCTAssertEqual(mix.processingFormat.channelCount, 1)
            XCTAssertEqual(mix.processingFormat.sampleRate, 16_000)
            XCTAssertEqual(mix.length, AVAudioFramePosition(voice.count))
        }
        source.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The recording itself stays")
    }

    func testMeasurementSeesEachChannelAndTheirSum() throws {
        let measurement = try SpeechAudioReader.measure(try recording([voice, silence, voice.map { -$0 }]))
        XCTAssertEqual(measurement.frames, voice.count)
        XCTAssertEqual(measurement.channelEnergy.count, 3)
        XCTAssertEqual(measurement.channelEnergy[0], measurement.channelEnergy[2], accuracy: measurement.channelEnergy[0] * 0.001)
        XCTAssertEqual(measurement.channelEnergy[1], 0)
        XCTAssertLessThan(measurement.sumEnergy, measurement.channelEnergy[0] * 0.001, "Opposite channels cancel in the sum")
    }
}

/// The same recordings through the real Parakeet model, when it is cached.
final class MultichannelRecognitionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-multichannel-asr-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testCachedParakeetV3HearsAVoiceOnAnyInput() async throws {
        let modelDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDirectory.path), "The cached Parakeet v3 model is required")
        let voice = try SpeechAudioReaderTests.voiceSamples()
        let silence = [Float](repeating: 0, count: voice.count)

        let prefs = AppPreferences.shared
        let originalVersion = prefs.fluidAudioModelVersion
        let originalLanguage = prefs.whisperLanguage
        defer {
            prefs.fluidAudioModelVersion = originalVersion
            prefs.whisperLanguage = originalLanguage
        }
        prefs.fluidAudioModelVersion = "v3"
        prefs.whisperLanguage = "en"

        let engine = FluidAudioEngine()
        try await engine.initialize()
        let recordings: [(name: String, channels: [[Float]])] = [
            ("the second input of two", [silence, voice]),
            ("the third input of three", [silence, silence, voice]),
            ("the first input of eight", [voice] + [[Float]](repeating: silence, count: 7)),
            ("two channels that cancel", [voice, voice.map { -$0 }]),
        ]
        for recording in recordings {
            let url = try SpeechAudioReaderTests.write(
                recording.channels, to: directory.appendingPathComponent("\(UUID().uuidString).wav")
            )
            let text = try await engine.transcribeAudio(url: url, settings: Settings()).lowercased()
            XCTAssertTrue(text.contains("country"), "\(recording.name): \(text)")
            XCTAssertTrue(text.contains("do for you"), "\(recording.name): \(text)")
        }
    }
}
