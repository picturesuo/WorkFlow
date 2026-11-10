import AVFoundation
import XCTest
@testable import OpenSuperWhisper

/// Pieces, live following, and the fallbacks of recognizing a dictation while
/// it is recorded. A scripted recognizer stands in for Parakeet and files are
/// written with AVAudioFile, the recorder's own file writer; no microphone,
/// model, or playback is used.
final class SpeechSegmenterTests: XCTestCase {
    private let rate = SpeechSegmenter.sampleRate

    /// Speech-like 300 Hz bursts with silence at the given second marks.
    private func speech(seconds: Double, silences: [ClosedRange<Double>] = []) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            let time = Double(index) / Double(rate)
            if silences.contains(where: { $0.contains(time) }) { return 0 }
            return Float(0.3 * sin(2 * .pi * 300 * time))
        }
    }

    private func pieces(_ samples: [Float], chunk: Int? = nil) -> [Range<Int>] {
        var segmenter = SpeechSegmenter()
        var pieces: [Range<Int>] = []
        if let chunk {
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + chunk)
                pieces += segmenter.append(samples[offset..<end])
                offset = end
            }
        } else {
            pieces += segmenter.append(samples)
        }
        if let last = segmenter.finish() { pieces.append(last) }
        return pieces
    }

    func testRecordingThatFitsOneWindowIsOnePieceAsBefore() {
        let samples = speech(seconds: 14.8)
        XCTAssertEqual(pieces(samples), [0..<samples.count])
        XCTAssertEqual(pieces(speech(seconds: 0.4)).count, 1)
    }

    func testPiecesCoverTheRecordingWithoutGapsAndFitTheWindow() {
        let samples = speech(seconds: 95, silences: [20.0...20.4, 41.0...41.3, 70.0...70.2])
        let result = pieces(samples)
        XCTAssertGreaterThan(result.count, 6)
        XCTAssertEqual(result.first?.lowerBound, 0)
        XCTAssertEqual(result.last?.upperBound, samples.count)
        for (previous, next) in zip(result, result.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound, "Pieces neither overlap nor leave a gap")
        }
        for piece in result {
            XCTAssertLessThanOrEqual(piece.count, Int(14.9 * Double(rate)), "Every piece fits Parakeet's 15 s window")
        }
        for piece in result.dropLast() {
            XCTAssertGreaterThanOrEqual(piece.count, 6 * rate)
        }
    }

    func testCutLandsInThePause() {
        let samples = speech(seconds: 20, silences: [9.0...9.4])
        let cut = pieces(samples)[0].upperBound
        XCTAssertTrue((9.0...9.4).contains(Double(cut) / Double(rate)), "Cut at \(Double(cut) / Double(rate)) s")
    }

    func testPiecesDoNotDependOnHowTheAudioArrives() {
        let samples = speech(seconds: 61, silences: [8.0...8.3, 30.5...31.0, 47.0...47.2])
        let whole = pieces(samples)
        for chunk in [1, 160, 1_237, 4_000, 16_000, 333_333] {
            XCTAssertEqual(pieces(samples, chunk: chunk), whole, "Chunk \(chunk)")
        }
    }
}

final class SegmentedTranscriberTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        var windows: [(samples: [Float], start: Double)] = []
    }

    private func samples(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * Float($0 % 7_919 == 0 ? 0 : 0.2) }
    }

    private func transcriber(_ calls: Calls, text: @escaping (Int) -> String = { "piece \($0)." }) -> SegmentedTranscriber {
        SegmentedTranscriber { window, start in
            calls.windows.append((window, start))
            return text(calls.windows.count)
        }
    }

    func testJoinsEachPieceAndSkipsSilentOnes() async throws {
        let calls = Calls()
        let subject = transcriber(calls) { $0 == 2 ? "  " : "piece \($0)." }
        try await subject.append(samples(seconds: 40))
        let text = try await subject.finish()
        XCTAssertGreaterThanOrEqual(calls.windows.count, 3)
        let expected = (1...calls.windows.count).filter { $0 != 2 }.map { "piece \($0)." }.joined(separator: " ")
        XCTAssertEqual(text, expected, "Pieces join in order with one space; a silent piece adds nothing")
    }

    func testFeedingLiveSendsTheSameWindowsAsTheFinishedFile() async throws {
        let audio = samples(seconds: 52)
        let whole = Calls()
        let offline = transcriber(whole)
        try await offline.append(audio)
        let offlineText = try await offline.finish()

        let streamed = Calls()
        let live = transcriber(streamed)
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + 4_000)
            try await live.append(audio[offset..<end])
            offset = end
        }
        let liveText = try await live.finish()

        XCTAssertEqual(liveText, offlineText)
        XCTAssertEqual(streamed.windows.map(\.start), whole.windows.map(\.start))
        XCTAssertEqual(streamed.windows.map(\.samples), whole.windows.map(\.samples), "Trimming kept every window whole")
        var position = 0
        for window in whole.windows {
            XCTAssertEqual(window.samples, Array(audio[position..<position + window.samples.count]))
            position += window.samples.count
        }
        XCTAssertEqual(position, audio.count)
    }

    func testCancellationStopsBeforeTheNextPiece() async throws {
        let calls = Calls()
        let subject = transcriber(calls)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await subject.append(self.samples(seconds: 40))
        }
        do {
            try await task.value
            XCTFail("A cancelled transcription must not finish")
        } catch is CancellationError {}
        XCTAssertTrue(calls.windows.isEmpty)
    }
}

final class GrowingWAVReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GrowingWAVReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    static func writerSettings(channels: Int = 1, rate: Double = 16_000) -> [String: Any] {
        [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    }

    static func buffer(_ values: [Float], rate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buffer.frameLength = AVAudioFrameCount(values.count)
        for (index, value) in values.enumerated() { buffer.floatChannelData![0][index] = value }
        return buffer
    }

    private func finishedSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func testReadsWhatTheRecorderWriterWroteExactlyAsTheFinishedFileReads() throws {
        let url = directory.appendingPathComponent("growing.wav")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: Self.writerSettings(),
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let reader = GrowingWAVReader(url: url)
        var heard: [Float] = []
        for block in 0..<40 {
            let values = (0..<1_600).map { Float(sin(Double(block * 1_600 + $0) * 0.01)) * 0.5 }
            try writer?.write(from: Self.buffer(values))
            heard += try reader.readAvailable()
        }
        writer = nil
        heard += try reader.readAvailable()
        let finished = try finishedSamples(url)
        XCTAssertEqual(finished.count, 64_000)
        XCTAssertEqual(heard, finished, "Every sample, read mid-write, matches the finished file")
    }

    func testWaitsForAnIncompleteHeaderAndCarriesAHalfSample() throws {
        let url = directory.appendingPathComponent("partial.wav")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: Self.writerSettings(),
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer?.write(from: Self.buffer((0..<3_000).map { Float($0 % 200) / 400 }))
        writer = nil
        let bytes = try Data(contentsOf: url)
        let dataStart = try XCTUnwrap(GrowingWAVReader.locateSamples(in: url))

        let copy = directory.appendingPathComponent("copy.wav")
        FileManager.default.createFile(atPath: copy.path, contents: bytes.prefix(Int(dataStart) - 3))
        let reader = GrowingWAVReader(url: copy)
        XCTAssertEqual(try reader.readAvailable(), [], "No samples until the header is complete")

        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes[(Int(dataStart) - 3)..<(Int(dataStart) + 101)])
        let first = try reader.readAvailable()
        XCTAssertEqual(first.count, 50, "101 sample bytes are 50 whole samples and one half")
        try handle.write(contentsOf: bytes[(Int(dataStart) + 101)...])
        try handle.close()
        let rest = try reader.readAvailable()
        XCTAssertEqual(first + rest, try finishedSamples(url))
    }

    func testOtherFormatsAreLeftToTheFinishedFilePath() throws {
        for (channels, rate) in [(2, 16_000.0), (1, 44_100.0)] {
            let url = directory.appendingPathComponent("other-\(channels)-\(Int(rate)).wav")
            var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: Self.writerSettings(channels: channels, rate: rate))
            let format = writer!.processingFormat
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000)!
            buffer.frameLength = 1_000
            try writer?.write(from: buffer)
            writer = nil
            XCTAssertThrowsError(try GrowingWAVReader(url: url).readAvailable()) { error in
                XCTAssertEqual(error as? GrowingWAVReader.ReadError, .unsupportedFormat)
            }
        }
        let notWAV = directory.appendingPathComponent("not.wav")
        try Data(repeating: 7, count: 64).write(to: notWAV)
        XCTAssertThrowsError(try GrowingWAVReader(url: notWAV).readAvailable())
    }

    func testFindsSamplesAfterPaddingAndExtensibleFormatChunks() throws {
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            let size = UInt32(body.count)
            return Array(id.utf8) + (0..<4).map { UInt8((size >> (8 * $0)) & 0xFF) } + body + (body.count % 2 == 1 ? [0] : [])
        }
        func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        let pcm = le16(1) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
        let extensible = le16(0xFFFE) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
            + le16(22) + le16(16) + le32(4) + le16(1) + [UInt8](repeating: 0, count: 14)
        for format in [pcm, extensible] {
            let body = Array("WAVE".utf8) + chunk("JUNK", [UInt8](repeating: 0, count: 27)) + chunk("fmt ", format)
                + chunk("FLLR", [UInt8](repeating: 0, count: 3_000))
            let header = Array("RIFF".utf8) + le32(0) + body + Array("data".utf8) + le32(0)
            XCTAssertEqual(try GrowingWAVReader.locateSamples(inHeader: header), UInt64(header.count))
        }
    }
}

final class LiveTranscriptionTests: XCTestCase {
    private var directory: URL!
    private let engine = NSObject()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTranscriptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Recognizer: @unchecked Sendable {
        let lock = NSLock()
        var windows: [Double] = []
        func transcriber() -> SegmentedTranscriber {
            SegmentedTranscriber { samples, start in
                self.lock.withLock { self.windows.append(start) }
                let energy = samples.reduce(0) { $0 + abs($1) } / Float(max(samples.count, 1))
                return String(format: "words from %.1f s, level %.4f.", start, energy)
            }
        }
    }

    private func audio(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { index in
            let time = Double(index) / 16_000
            // A short pause every 9.5 s, like breaths between phrases.
            return time.truncatingRemainder(dividingBy: 9.5) < 0.3 ? 0 : Float(sin(time * 2 * .pi * 220)) * 0.3
        }
    }

    /// Writes `samples` through AVAudioFile in 100 ms blocks, letting the live
    /// recognition read between them, then closes the file.
    private func record(_ samples: [Float], to url: URL, during live: LiveTranscription? = nil) async throws {
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: GrowingWAVReaderTests.writerSettings(),
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        await live?.start()
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + 1_600)
            try writer?.write(from: GrowingWAVReaderTests.buffer(Array(samples[offset..<end])))
            offset = end
            if offset % 48_000 == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        writer = nil
    }

    private func offlineText(_ url: URL) async throws -> String {
        let transcriber = Recognizer().transcriber()
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        try await transcriber.append(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return try await transcriber.finish()
    }

    private func live(_ url: URL, recognizer: Recognizer, language: String = "en") -> LiveTranscription {
        LiveTranscription(reader: GrowingWAVReader(url: url), transcriber: recognizer.transcriber(), engine: engine, language: language)
    }

    func testLiveResultIsTheFinishedFileResultWithOnlyTheLastPieceLeft() async throws {
        let url = directory.appendingPathComponent("dictation.wav")
        let recognizer = Recognizer()
        let subject = live(url, recognizer: recognizer)
        try await record(audio(seconds: 47), to: url, during: subject)
        // Give the follower time to read the last full pieces, as during speech.
        try await Task.sleep(for: .milliseconds(600))
        let before = recognizer.lock.withLock { recognizer.windows.count }
        let text = try await subject.finish(finalAudio: url, engine: engine, language: "en")
        let expected = try await offlineText(url)
        XCTAssertEqual(text, expected, "Live and finished-file recognition agree word for word")
        XCTAssertGreaterThanOrEqual(before, 2, "Pieces were recognized while recording")
        XCTAssertEqual(recognizer.lock.withLock { recognizer.windows.count } - before, 1, "Only the last piece was left at stop")
        let fallback = await subject.fallback
        XCTAssertNil(fallback)
    }

    func testChangedAudioFallsBackToTheFinishedFile() async throws {
        let url = directory.appendingPathComponent("changed.wav")
        let subject = live(url, recognizer: Recognizer())
        try await record(audio(seconds: 20), to: url, during: subject)
        try await Task.sleep(for: .milliseconds(400))
        // The finished file is not what was heard.
        let finished = directory.appendingPathComponent("finished.wav")
        try await record(audio(seconds: 20).map { $0 * 0.5 }, to: finished)
        let text = try await subject.finish(finalAudio: finished, engine: engine, language: "en")
        XCTAssertNil(text)
        let fallback = await subject.fallback
        XCTAssertEqual(fallback, .audioChanged)
    }

    func testAnotherEngineOrLanguageFallsBack() async throws {
        let url = directory.appendingPathComponent("settings.wav")
        let first = live(url, recognizer: Recognizer())
        try await record(audio(seconds: 3), to: url, during: first)
        let otherEngine = try await first.finish(finalAudio: url, engine: NSObject(), language: "en")
        XCTAssertNil(otherEngine)
        let firstFallback = await first.fallback
        XCTAssertEqual(firstFallback, .engineChanged)

        let second = live(url, recognizer: Recognizer())
        await second.start()
        let otherLanguage = try await second.finish(finalAudio: url, engine: engine, language: "de")
        let third = live(url, recognizer: Recognizer())
        await third.start()
        let short = try await third.finish(finalAudio: url, engine: engine, language: "en")
        XCTAssertNil(short, "A recording that fits one piece is recognized from the file, exactly as before")
        let thirdFallback = await third.fallback
        XCTAssertEqual(thirdFallback, .onePiece)
        XCTAssertNil(otherLanguage)
        let secondFallback = await second.fallback
        XCTAssertEqual(secondFallback, .languageChanged)
    }

    func testUnsupportedRecordingFallsBack() async throws {
        let url = directory.appendingPathComponent("stereo.wav")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: GrowingWAVReaderTests.writerSettings(channels: 2))
        let buffer = AVAudioPCMBuffer(pcmFormat: writer!.processingFormat, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try writer?.write(from: buffer)
        let subject = live(url, recognizer: Recognizer())
        await subject.start()
        try await Task.sleep(for: .milliseconds(300))
        writer = nil
        let text = try await subject.finish(finalAudio: url, engine: engine, language: "en")
        XCTAssertNil(text)
        let fallback = await subject.fallback
        XCTAssertEqual(fallback, .unreadable)
    }

    func testCancelledRecordingGivesNothing() async throws {
        let url = directory.appendingPathComponent("cancelled.wav")
        let recognizer = Recognizer()
        let subject = live(url, recognizer: recognizer)
        try await record(audio(seconds: 18), to: url, during: subject)
        await subject.cancel()
        let text = try await subject.finish(finalAudio: url, engine: engine, language: "en")
        XCTAssertNil(text)
    }
}

/// The service uses the live result only when it fits, and the engine otherwise.
@MainActor
final class LiveTranscriptionServiceTests: XCTestCase {
    private final class FileEngine: TranscriptionEngine {
        var isModelLoaded: Bool { true }
        var engineName: String { "File" }
        var files: [URL] = []
        func initialize() async throws {}
        func transcribeAudio(url: URL, settings: Settings) async throws -> String {
            files.append(url)
            return "from the file"
        }
        func cancelTranscription() {}
        func getSupportedLanguages() -> [String] { ["en"] }
    }

    func testUsesLiveTextWhenItCoversTheRecordingAndTheFileOtherwise() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.wav")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: GrowingWAVReaderTests.writerSettings(),
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer?.write(from: GrowingWAVReaderTests.buffer([Float](repeating: 0.1, count: 20 * 16_000)))
        writer = nil

        let engine = FileEngine()
        let service = TranscriptionService(engine: engine)
        let settings = Settings()
        let matching = LiveTranscription(
            reader: GrowingWAVReader(url: url),
            transcriber: SegmentedTranscriber { _, start in start == 0 ? "from the live recognition" : "" },
            engine: engine, language: settings.selectedLanguage
        )
        await matching.start()
        // Let it recognize the first piece, as it would while recording.
        try await Task.sleep(for: .milliseconds(500))
        let liveText = try await service.transcribeAudio(url: url, settings: settings, live: matching)
        XCTAssertEqual(liveText, "from the live recognition")
        XCTAssertEqual(engine.files, [], "The file was not recognized again")

        let otherEngine = LiveTranscription(
            reader: GrowingWAVReader(url: url),
            transcriber: SegmentedTranscriber { _, _ in "stale" },
            engine: NSObject(), language: settings.selectedLanguage
        )
        await otherEngine.start()
        let fileText = try await service.transcribeAudio(url: url, settings: settings, live: otherEngine)
        XCTAssertEqual(fileText, "from the file")
        XCTAssertEqual(engine.files, [url])
    }
}
