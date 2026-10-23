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

    // Esc cancels a dictation that is still transcribing (the indicator's
    // contract, see EscapeCancelConfirmationTests): nothing is pasted, and the
    // words are kept in History.
    func testEscWhileTranscribingSavesTheDictationWithoutPasting() async throws {
        let audio = try makeAudio()
        let entered = expectation(description: "Transcription started")
        let engine = ControlledTranscriptionEngine { _ in entered.fulfill() }
        let fixture = try Fixture(engine: engine)
        fixture.viewModel.state = .decoding
        let generation = fixture.gate.begin()
        let finishing = Task {
            await fixture.viewModel.finishDictation(audioAt: audio, generation: generation, recordingStartedAt: nil)
        }
        await fulfillment(of: [entered], timeout: 2)

        XCTAssertTrue(ShortcutManager.escapeCancels(activeRecording: false, indicatorState: .decoding),
                      "Before the fix Esc was swallowed once the recording stopped")
        // What IndicatorWindowManager.requestCancel does when Esc is accepted.
        XCTAssertTrue(fixture.viewModel.handleCancelRequest())
        fixture.viewModel.cancelRecording()
        fixture.viewModel.cleanup()
        engine.finish(audio, text: "Send the draft to the team")
        await finishing.value

        XCTAssertEqual(fixture.delivery.texts, [], "Nothing is pasted after Esc")
        let rows = try await fixture.rows(count: 1)
        let row = try XCTUnwrap(rows.first, "The words are kept in History")
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.transcription, "Send the draft to the team")
        let source = try await fixture.store.dictationSource(for: row.id)
        XCTAssertEqual(source?.disposition.rawValue, "cancelled")
        XCTAssertNil(source?.insertedText)
        XCTAssertEqual(fixture.finish.count, 1)
    }

    func testEscReachesOnlyARecordingOrAStoppedDictation() {
        XCTAssertTrue(ShortcutManager.escapeCancels(activeRecording: true, indicatorState: .recording))
        XCTAssertFalse(ShortcutManager.escapeCancels(activeRecording: false, indicatorState: nil), "No indicator, nothing to cancel")
        XCTAssertFalse(ShortcutManager.escapeCancels(activeRecording: false, indicatorState: .pasteFailed),
                       "A delivered dictation's message is not a cancel target")
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
    var result: Result<String, Error>

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

/// Queued failures (meetings, imports, dictations stopped while the queue was
/// busy) keep their audio where the temporary sweep cannot reach it, and
/// History-referenced temporary audio survives the launch sweep.
@MainActor
final class QueuedAudioRetentionTests: XCTestCase {
    private var temporaryAudio: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryAudio { try? FileManager.default.removeItem(at: url) }
    }

    func testFailedQueuedAudioMovesIntoHistoryAndRegeneratesAfterTheSweep() async throws {
        let store = try makeIsolatedStore()
        let engine = ScriptedEngine(.failure(TranscriptionError.processingFailed))
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: engine),
            recordingStore: store,
            cleanupPipeline: makeLocalPipeline()
        )
        try FileManager.default.createDirectory(at: AudioRecorder.temporaryRecordingsDirectory, withIntermediateDirectories: true)
        let recorded = AudioRecorder.temporaryRecordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("synthetic meeting audio".utf8).write(to: recorded)
        temporaryAudio.append(recorded)

        await queue.addFileToQueue(url: recorded, mode: .meeting)
        var row = try await settledRow(in: store, queue: queue)
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path),
                      "Before the fix the audio stayed in the temporary folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.path))
        XCTAssertEqual(row.sourceFileURL, row.url.path)

        // A day later the launch sweep runs; History's audio is outside its reach.
        if FileManager.default.fileExists(atPath: recorded.path) {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: recorded.path)
        }
        let referenced = try await store.referencedAudioPaths()
        AudioRecorder.sweepTemporaryRecordings(
            in: AudioRecorder.temporaryRecordingsDirectory, olderThan: AudioRecorder.temporaryFileMaxAge, keeping: referenced
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path))

        engine.result = .success("We agreed to ship on Friday")
        await queue.requeueRecording(row)
        row = try await settledRow(in: store, queue: queue)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.transcription, "We agreed to ship on Friday")
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path))

        try await store.deleteRecordingSync(row)
        XCTAssertFalse(FileManager.default.fileExists(atPath: row.url.path), "Deleting the History item deletes its audio")
    }

    func testLaunchSweepKeepsTemporaryAudioThatHistoryStillUses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueuedAudioRetentionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String, daysOld: Double) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let kept = try file("kept-after-failed-move.wav", daysOld: 3)
        let stale = try file("abandoned.wav", daysOld: 3)
        let fresh = try file("recording-now.wav", daysOld: 0)

        AudioRecorder.sweepTemporaryRecordings(in: directory, olderThan: AudioRecorder.temporaryFileMaxAge, keeping: [kept.path])

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "Before the fix History's audio was swept after a day")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testHistoryReportsTheTemporaryAudioItStillUses() async throws {
        let store = try makeIsolatedStore()
        let kept = Recording(id: UUID(), timestamp: Date(), fileName: "a.wav", transcription: "Kept", duration: 1,
                             status: .completed, progress: 1, sourceFileURL: "/private/tmp/x/../x/kept.wav")
        let plain = Recording(id: UUID(), timestamp: Date(), fileName: "b.wav", transcription: "Plain", duration: 1,
                              status: .completed, progress: 1)
        try await store.addRecordingSync(kept)
        try await store.addRecordingSync(plain)
        let referenced = try await store.referencedAudioPaths()
        XCTAssertEqual(referenced, ["/private/tmp/x/kept.wav"])
    }

    func testRegenerateNeverReplacesATranscriptWhoseAudioIsGone() async throws {
        let store = try makeIsolatedStore()
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: ScriptedEngine(.success("unused"))),
            recordingStore: store,
            cleanupPipeline: makeLocalPipeline()
        )
        let row = Recording(id: UUID(), timestamp: Date(), fileName: "\(UUID().uuidString).wav", transcription: "Call the vendor at noon",
                            duration: 4, status: .completed, progress: 1)
        try await store.addRecordingSync(row)
        XCTAssertNil(row.playableAudioURL, "No audio is offered for playback")

        await queue.requeueRecording(row)

        let saved = try await store.fetchRecordings(limit: 1, offset: 0).first
        XCTAssertEqual(saved?.transcription, "Call the vendor at noon", "Before the fix the transcript became an error message")
        XCTAssertEqual(saved?.status, .completed)
    }

    /// Waits for the queue to finish and returns the newest row.
    private func settledRow(in store: RecordingStore, queue: TranscriptionQueue) async throws -> Recording {
        for _ in 0..<300 {
            if let row = try await store.fetchRecordings(limit: 1, offset: 0).first, !row.isPending, !queue.isProcessing {
                return row
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let newest = try await store.fetchRecordings(limit: 1, offset: 0).first
        return try XCTUnwrap(newest)
    }
}
