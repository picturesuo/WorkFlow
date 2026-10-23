import GRDB
import XCTest
@testable import OpenSuperWhisper

/// A stopped hotkey dictation must not vanish. When the recognizer throws,
/// the audio is kept as a failed History row the user can regenerate, the
/// way the queue keeps its failures; when the audio cannot move into History,
/// the transcript is still delivered and saved. Every dictation runs through
/// `IndicatorViewModel` with a scripted recognizer, a private in-memory
/// History, and a delivery stub: no microphone, model, provider, pasteboard,
/// or keystroke is used.
@MainActor
final class DictationFailureRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationFailureRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecognizerFailureKeepsTheAudioAsAFailedHistoryRowLikeTheQueue() async throws {
        let audio = try makeAudio()
        let fixture = try Fixture(engine: ScriptedEngine(.failure(TranscriptionError.contextInitializationFailed)))
        let startedAt = Date(timeIntervalSince1970: 1_000)

        await fixture.viewModel.finishDictation(audioAt: audio, generation: fixture.gate.begin(), recordingStartedAt: startedAt)

        XCTAssertEqual(fixture.delivery.texts, [], "Nothing was transcribed, so nothing is pasted")
        XCTAssertEqual(fixture.viewModel.state, .transcriptionFailed, "The indicator says it failed instead of vanishing")
        let rows = try await fixture.rows(count: 1)
        let row = try XCTUnwrap(rows.first, "Before the fix the audio was deleted and History stayed empty")
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.transcription, "Failed to transcribe: The speech model could not be loaded.")
        XCTAssertEqual(row.transcription, TranscriptionQueue.failedTranscriptionText(TranscriptionError.contextInitializationFailed),
                       "Same History text as a queued failure")
        XCTAssertEqual(row.mode, .dictation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path), "The audio moved into History")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(
            TranscriptionQueue.recoverPendingAudioSource(
                sourceURL: row.sourceFileURL.map { URL(fileURLWithPath: $0) },
                savedAudioURL: row.url
            ),
            row.url,
            "Regenerate finds the audio through the queue's own lookup"
        )
        let source = try await fixture.store.dictationSource(for: row.id)
        let evidence = try XCTUnwrap(source)
        XCTAssertEqual(evidence.disposition, .pending, "Filled on the first successful regeneration, as queued rows are")
        XCTAssertNil(evidence.recognizerText)
        XCTAssertEqual(evidence.selectedMode, .everyday)
        XCTAssertEqual(evidence.recordingStartedAt, startedAt)
        fixture.viewModel.cleanup()
    }

    func testCancelledTranscriptionIsStillDiscarded() async throws {
        let audio = try makeAudio()
        let fixture = try Fixture(engine: ScriptedEngine(.failure(CancellationError())))

        await fixture.viewModel.finishDictation(audioAt: audio, generation: fixture.gate.begin(), recordingStartedAt: nil)

        XCTAssertNotEqual(fixture.viewModel.state, .transcriptionFailed)
        XCTAssertEqual(fixture.finish.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "A cancelled dictation keeps nothing")
        let rows = try await fixture.rows(count: 0)
        XCTAssertEqual(rows.count, 0)
        XCTAssertEqual(fixture.delivery.texts, [])
    }

    func testAnOlderFailureIsKeptWithoutCoveringTheNewerDictation() async throws {
        let audio = try makeAudio()
        let fixture = try Fixture(engine: ScriptedEngine(.failure(TranscriptionError.processingFailed)))
        let older = fixture.gate.begin()
        _ = fixture.gate.begin()

        await fixture.viewModel.finishDictation(audioAt: audio, generation: older, recordingStartedAt: nil)

        XCTAssertNotEqual(fixture.viewModel.state, .transcriptionFailed, "The newer dictation owns the indicator")
        XCTAssertEqual(fixture.finish.count, 1)
        let rows = try await fixture.rows(count: 1)
        let row = try XCTUnwrap(rows.first)
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path), "Its audio is kept all the same")
    }

    func testTranscriptSurvivesWhenItsAudioCannotMoveIntoHistory() async throws {
        // The temporary file is gone (swept or removed) before it can move.
        let missing = directory.appendingPathComponent("swept.wav")
        let fixture = try Fixture(engine: ScriptedEngine(.success("Ship the fix today")))

        await fixture.viewModel.finishDictation(audioAt: missing, generation: fixture.gate.begin(), recordingStartedAt: nil)

        XCTAssertEqual(fixture.delivery.texts, ["Ship the fix today"], "Before the fix the transcript was dropped unpasted")
        let rows = try await fixture.rows(count: 1)
        let row = try XCTUnwrap(rows.first, "Before the fix nothing reached History")
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.transcription, "Ship the fix today")
        XCTAssertNil(row.sourceFileURL, "No audio is claimed")
        let source = try await fixture.store.dictationSource(for: row.id)
        XCTAssertEqual(source?.disposition, .pasteSent)
        XCTAssertEqual(source?.recognizerText, "Ship the fix today")
        XCTAssertEqual(fixture.finish.count, 1)
    }

    func testAudioThatCannotMoveStaysAtItsTemporaryPath() throws {
        let audio = try makeAudio()
        let fixture = try Fixture(engine: ScriptedEngine(.success("")))
        let blocker = directory.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)

        XCTAssertEqual(fixture.viewModel.recorder.keepTemporaryRecording(audio, at: blocker.appendingPathComponent("a.wav")), audio,
                       "A History folder that cannot be created leaves the audio in place")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let destination = directory.appendingPathComponent("History/b.wav")
        XCTAssertEqual(fixture.viewModel.recorder.keepTemporaryRecording(audio, at: destination), destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(fixture.viewModel.recorder.keepTemporaryRecording(audio, at: directory.appendingPathComponent("c.wav")), "Nothing is left to keep")
    }

    // The main window's own record button stops into `ContentViewModel`, which
    // had the same loss: a recognizer failure deleted the audio.
    func testMainWindowRecognizerFailureKeepsTheAudioAndSaysWhereItIs() async throws {
        let audio = try makeAudio()
        let store = try makeIsolatedStore()
        let model = ContentViewModel()
        model.recordingStore = store
        model.transcriptionService = TranscriptionService(engine: ScriptedEngine(.failure(TranscriptionError.processingFailed)))
        model.cleanupPipeline = makeLocalPipeline()

        await model.finishRecording(audioAt: audio)

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(
            model.recordingError,
            "WorkFlow couldn’t transcribe this recording. Its audio is saved in History, so you can select Regenerate to try again."
        )
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first, "Before the fix the audio was deleted and History stayed empty")
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.transcription, "Failed to transcribe: The speech model could not process the audio.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path))
        let source = try await store.dictationSource(for: row.id)
        XCTAssertEqual(source?.disposition, .pending)
    }

    func testMainWindowTranscriptSurvivesAFailedAudioMove() async throws {
        let store = try makeIsolatedStore()
        let model = ContentViewModel()
        model.recordingStore = store
        model.transcriptionService = TranscriptionService(engine: ScriptedEngine(.success("Book the room for Friday")))
        model.cleanupPipeline = makeLocalPipeline()

        await model.finishRecording(audioAt: directory.appendingPathComponent("swept.wav"))

        XCTAssertNil(model.recordingError, "Before the fix the transcript was dropped with an error")
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(rows.map(\.transcription), ["Book the room for Friday"])
        XCTAssertEqual(rows.first?.status, .completed)
    }

    private func makeAudio() throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("synthetic audio bytes".utf8).write(to: url)
        return url
    }
}

/// One isolated hotkey-dictation path: private History, local-only cleanup,
/// and recorded delivery.
@MainActor
private final class Fixture {
    let store: RecordingStore
    let gate: LatestDictationGate
    let delivery: DeliverySpy
    let finish: FinishSpy
    let viewModel: IndicatorViewModel

    init(engine: any TranscriptionEngine) throws {
        let store = try makeIsolatedStore()
        let pipeline = makeLocalPipeline()
        let gate = LatestDictationGate()
        let delivery = DeliverySpy()
        let finish = FinishSpy()
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: engine),
            recordingStore: store,
            cleanupPipeline: pipeline,
            delivery: { delivery.texts.append($0); return .pasteSent }
        )
        viewModel.delegate = finish
        self.store = store
        self.gate = gate
        self.delivery = delivery
        self.finish = finish
        self.viewModel = viewModel
    }

    /// History saves successful dictations asynchronously, so wait briefly for them.
    func rows(count: Int) async throws -> [Recording] {
        for _ in 0..<100 {
            let rows = try await store.fetchRecordings(limit: 10, offset: 0)
            if rows.count >= max(count, 1) { return rows }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try await store.fetchRecordings(limit: 10, offset: 0)
    }
}

/// A private in-memory History; audio goes to the test recordings folder.
@MainActor
private func makeIsolatedStore() throws -> RecordingStore {
    try RecordingStore(
        database: DatabaseQueue(),
        recordingsDirectory: Recording.recordingsDirectory,
        cancelQueuedRecording: { _ in },
        stopPlayback: { _ in }
    )
}

/// Cleanup off, so text stays local and no provider can be reached.
private func makeLocalPipeline() -> TranscriptCleanupPipeline {
    TranscriptCleanupPipeline(
        isEnabled: { false },
        providerResolver: { throw CleanupProviderError.missingCredential("none") },
        vocabularyProvider: { [] },
        appRuleProvider: { _ in nil },
        bedrockBudgetProvider: { nil },
        filterProvider: { .builtIn(.everyday) },
        failureRecorder: { _ in }
    )
}

@MainActor
private final class DeliverySpy {
    var texts: [String] = []
}

@MainActor
private final class FinishSpy: IndicatorViewDelegate {
    var count = 0
    func didFinishDecoding(_ viewModel: IndicatorViewModel) { count += 1 }
}

/// Returns one scripted result without reading the audio file.
private final class ScriptedEngine: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Scripted fixture"
    private let result: Result<String, Error>

    init(_ result: Result<String, Error>) {
        self.result = result
    }

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try result.get()
    }
}
