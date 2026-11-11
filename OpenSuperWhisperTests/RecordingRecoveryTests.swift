import AVFoundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

/// A recording whose WorkFlow quit, crashed or was force-quit before it
/// reached History must not be swept away a day later. At launch it becomes
/// a failed History row that keeps its audio and offers Regenerate; nothing
/// is transcribed or pasted until the user asks. Every recording here is a
/// synthetic tone written by the test into a private folder that stands in
/// for the temporary recordings folder, History is a private in-memory
/// database, and the recognizer is scripted: no microphone, model, provider,
/// pasteboard or real History is used.
@MainActor
final class RecordingRecoveryTests: XCTestCase {
    /// Stands in for the temporary recordings folder.
    private var directory: URL!
    /// Audio that moved into the test History folder.
    private var historyAudio: [URL] = []
    private let launchedAt = Date()

    // Async, so both run on the main actor with the rest of the class.
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        for url in historyAudio { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - The loss

    func testAnOrphanedRecordingBecomesOneFailedRowWithItsAudioAndDate() async throws {
        let store = try makeStore()
        // Three days old: today's launch sweep deletes it.
        let orphan = try makeRecording(seconds: 1, modified: launchedAt.addingTimeInterval(-3 * 86_400))
        let recordedAt = try modificationDate(of: orphan)
        let audio = try Data(contentsOf: orphan)

        let adopted = await adopt(into: store)
        // Launch sweeps the folder next, keeping what History references.
        let referenced = try await store.referencedAudioPaths()
        AudioRecorder.sweepTemporaryRecordings(in: directory, olderThan: AudioRecorder.temporaryFileMaxAge, keeping: referenced)

        XCTAssertEqual(adopted, 1)
        let rows = try await rows(in: store)
        XCTAssertEqual(rows.count, 1, "Before the fix History stayed empty and the sweep deleted the audio")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.mode, .dictation)
        XCTAssertEqual(row.timestamp.timeIntervalSince1970, recordedAt.timeIntervalSince1970, accuracy: 0.002,
                       "The row is dated when it was recorded, not when it was recovered")
        XCTAssertEqual(row.duration, 1, accuracy: 0.01)
        let playable = try XCTUnwrap(row.playableAudioURL, "The row keeps its audio")
        XCTAssertEqual(playable, row.url, "The audio moved into History, as every failed dictation's does")
        XCTAssertNil(row.sourceFileURL)
        XCTAssertEqual(try Data(contentsOf: playable), audio, "The recording still exists, byte for byte")
        XCTAssertEqual(try contents(of: directory), [], "It is no longer an orphan in the temporary folder")
    }

    func testARecoveredRowSaysWhatItIsAndOffersRegenerate() async throws {
        let store = try makeStore()
        try makeRecording(seconds: 1)

        await adopt(into: store)

        let row = try await onlyRow(in: store)
        XCTAssertEqual(row.transcription, TranscriptionQueue.failedTranscriptionText(RecordingRecovery.ClosedBeforeTranscription()),
                       "Stored the way every failed row's message is")
        XCTAssertEqual(
            HistoryRow.failureDetail(row.transcription),
            "Recovered recording - WorkFlow closed before this was transcribed. Select Regenerate to transcribe it."
        )
        let actions = HistoryRowActions(recording: row, hasAudio: row.playableAudioURL != nil, isPlaying: false)
        XCTAssertEqual(actions.visible, [.regenerate], "The existing failed-row action")
        XCTAssertFalse(actions.isEnabled(.copy), "There is no transcript to copy")
        let source = try await store.dictationSource(for: row.id)
        let evidence = try XCTUnwrap(source)
        XCTAssertEqual(evidence.disposition, .pending, "Filled on the first regeneration, as failed dictations are")
        XCTAssertNil(evidence.recognizerText)
        XCTAssertNil(evidence.insertedText, "Nothing was pasted")
    }

    func testNothingIsTranscribedUntilTheUserRegenerates() async throws {
        let store = try makeStore()
        let engine = CountingEngine(text: "Send the draft to Priya")
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: engine),
            recordingStore: store,
            cleanupPipeline: makeLocalPipeline()
        )
        try makeRecording(seconds: 1)

        await adopt(into: store)
        // Launch starts the queue too; a recovered row gives it nothing to do.
        queue.startProcessingQueue()
        var row = try await settledRow(in: store, queue: queue)

        XCTAssertEqual(engine.calls, 0, "Recovery never transcribes on its own")
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(store.getPendingRecordings().isEmpty)

        await queue.requeueRecording(row)
        row = try await settledRow(in: store, queue: queue)
        XCTAssertEqual(engine.calls, 1)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.transcription, "Send the draft to Priya")
        XCTAssertNotNil(row.playableAudioURL, "Regenerate keeps the audio")
    }

    // MARK: - What is left alone

    func testFilesThatAreNotOrphanedRecordingsAreLeftUntouched() async throws {
        let store = try makeStore()
        let referenced = try makeRecording(seconds: 1)
        // A queued row points at its temporary audio, written here with a
        // path that is not standardized.
        try await store.addRecordingSync(Recording(
            id: UUID(), timestamp: Date(), fileName: AudioRecorder.recordingFileName(), transcription: "", duration: 1,
            status: .pending, progress: 0,
            sourceFileURL: directory.appendingPathComponent("../\(directory.lastPathComponent)/\(referenced.lastPathComponent)").path
        ))
        let recordedAfterLaunch = try makeRecording(seconds: 1, modified: launchedAt.addingTimeInterval(5))
        let tooShort = try makeRecording(seconds: 0.2)
        let notAudio = directory.appendingPathComponent(AudioRecorder.recordingFileName())
        try Data("not audio".utf8).write(to: notAudio)
        try setModificationDate(launchedAt.addingTimeInterval(-60), of: notAudio)
        let otherName = try makeRecording(seconds: 1, name: "meeting-notes.wav")
        // A capture that never stopped: the recorder fills in the header's
        // sizes only when it stops, so the file does not open as audio.
        let neverStopped = try makeRecording(seconds: 1)
        try zeroHeaderSizes(of: neverStopped)
        XCTAssertNil(RecordingRecovery.audioDuration(of: neverStopped))
        let files = [referenced, recordedAfterLaunch, tooShort, notAudio, otherName, neverStopped]
        let before = try files.map { try Snapshot(of: $0) }

        let adopted = await adopt(into: store)

        XCTAssertEqual(adopted, 0)
        let rows = try await rows(in: store)
        XCTAssertEqual(rows.map(\.status), [.pending], "Only the row that was already there")
        XCTAssertEqual(try files.map { try Snapshot(of: $0) }, before, "Nothing was moved, rewritten or deleted")
        XCTAssertEqual(try contents(of: directory), Set(files.map(\.lastPathComponent)))
    }

    func testNothingIsAdoptedWhileAnotherWorkFlowIsRunning() async throws {
        let store = try makeStore()
        let orphan = try makeRecording(seconds: 1)
        let before = try Snapshot(of: orphan)

        let skipped = await adopt(into: store, anotherWorkFlowIsRunning: true)

        XCTAssertEqual(skipped, 0, "The other WorkFlow may be about to transcribe it")
        let rowsWhileShared = try await rows(in: store)
        XCTAssertEqual(rowsWhileShared.count, 0)
        XCTAssertEqual(try Snapshot(of: orphan), before)

        let adopted = await adopt(into: store)
        XCTAssertEqual(adopted, 1, "The same file is adopted once this WorkFlow is alone")
        _ = try await onlyRow(in: store)
    }

    func testAFailedInsertLeavesTheRecordingInPlace() async throws {
        let database = try DatabaseQueue()
        let store = try makeStore(database)
        try await refuseRows(in: database)
        let orphan = try makeRecording(seconds: 1)
        let before = try Snapshot(of: orphan)
        var historyURL: URL?

        let adopted = await adopt(into: store) { temporary, final in
            historyURL = final
            return AudioRecorder.shared.keepTemporaryRecording(temporary, at: final)
        }

        XCTAssertEqual(adopted, 0)
        let rowsAfterFailure = try await rows(in: store)
        XCTAssertEqual(rowsAfterFailure.count, 0)
        XCTAssertEqual(try Snapshot(of: orphan), before, "The recording is back where it was found, for the next launch and the sweep")
        let moved = try XCTUnwrap(historyURL, "History was offered the audio before the insert failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path), "No unowned audio is left in History")

        try await database.write { db in try db.execute(sql: "DROP TRIGGER refuse_rows") }
        let retried = await adopt(into: store)
        XCTAssertEqual(retried, 1, "The next launch adopts it")
        _ = try await onlyRow(in: store)
    }

    func testAFailedSaveStillDeletesAnOrdinaryFailedDictationsAudio() async throws {
        let database = try DatabaseQueue()
        let store = try makeStore(database)
        try await refuseRows(in: database)
        let recorded = try makeRecording(seconds: 1)
        var historyURL: URL?

        let saved = await store.addFailedDictation(
            audioAt: recorded,
            error: TranscriptionError.processingFailed,
            duration: 1,
            selectedFilter: .builtIn(.everyday),
            cleanupRequested: false,
            targetBundleID: nil,
            recordingStartedAt: nil
        ) { temporary, final in
            historyURL = final
            return AudioRecorder.shared.keepTemporaryRecording(temporary, at: final)
        }

        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.path), "Only recovery asks for the audio back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(historyURL).path))
    }

    // MARK: - Once only

    func testASecondPassAdoptsNothing() async throws {
        let store = try makeStore()
        try makeRecording(seconds: 1)
        try makeRecording(seconds: 2, modified: launchedAt.addingTimeInterval(-7_200))

        let first = await adopt(into: store)
        let second = await adopt(into: store)

        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0)
        let rows = try await rows(in: store)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.duration).map { $0.rounded() }, [1, 2], "Newest first, dated by their files")
    }

    func testAudioThatCannotMoveIntoHistoryIsReferencedWhereItIsAndAdoptedOnce() async throws {
        let store = try makeStore()
        let orphan = try makeRecording(seconds: 1, modified: launchedAt.addingTimeInterval(-3 * 86_400))
        let before = try Snapshot(of: orphan)
        let stays: (URL, URL) -> URL? = { temporary, _ in temporary }

        let first = await adopt(into: store, keepAudio: stays)
        let second = await adopt(into: store, keepAudio: stays)
        let referenced = try await store.referencedAudioPaths()
        AudioRecorder.sweepTemporaryRecordings(in: directory, olderThan: AudioRecorder.temporaryFileMaxAge, keeping: referenced)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "History references it now")
        let row = try await onlyRow(in: store)
        XCTAssertEqual(row.sourceFileURL.map { URL(fileURLWithPath: $0).standardizedFileURL }, orphan.standardizedFileURL)
        XCTAssertEqual(row.playableAudioURL?.standardizedFileURL, orphan.standardizedFileURL)
        XCTAssertEqual(try Snapshot(of: orphan), before, "The sweep keeps audio a row still uses")
    }

    // MARK: - Deleted recordings stay deleted

    func testDeletingARowDeletesItsTemporaryAudioSoItIsNeverRecovered() async throws {
        let store = try makeStore()
        // A dictation queued while the engine was busy: its row points at
        // audio that is still in the temporary folder.
        let queuedAudio = try makeRecording(seconds: 1)
        let queued = Recording(
            id: UUID(), timestamp: Date(), fileName: AudioRecorder.recordingFileName(), transcription: "", duration: 1,
            status: .pending, progress: 0, sourceFileURL: queuedAudio.path
        )
        // An imported file is the user's own and lives elsewhere.
        let imports = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingRecoveryTests-imports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imports) }
        let importedAudio = imports.appendingPathComponent("interview.wav")
        try Data("the user's own file".utf8).write(to: importedAudio)
        let imported = Recording(
            id: UUID(), timestamp: Date(), fileName: AudioRecorder.recordingFileName(), transcription: "", duration: 1,
            status: .pending, progress: 0, sourceFileURL: importedAudio.path
        )
        try await store.addRecordingSync(queued)
        try await store.addRecordingSync(imported)

        try await store.deleteRecordingSync(queued)
        try await store.deleteRecordingSync(imported)

        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedAudio.path),
                       "Before the fix the audio stayed, and the next launch would have recovered a deleted recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedAudio.path), "A file outside the temporary folder is never deleted")
        let adopted = await adopt(into: store)
        XCTAssertEqual(adopted, 0)
        let rows = try await rows(in: store)
        XCTAssertEqual(rows.count, 0)
    }

    // MARK: - Another WorkFlow

    func testOnlyAnotherWorkFlowProcessCountsAsSharingTheFolder() {
        let own: pid_t = 100
        let table: [(bundleIdentifier: String?, pid: pid_t, ownBundleIdentifier: String?, shares: Bool)] = [
            ("com.picturesuo.WorkFlow", 200, "com.picturesuo.WorkFlow", true),
            ("com.picturesuo.WorkFlow", own, "com.picturesuo.WorkFlow", false),
            ("com.picturesuo.Chat", 200, "com.picturesuo.WorkFlow", true),
            ("com.picturesuo.GlowScribe", 200, "com.picturesuo.WorkFlow", true),
            ("com.picturesuo.WorkFlow", 200, "com.picturesuo.WorkFlow.fmtest.run1", true),
            ("com.picturesuo.WorkFlow.fmtest.run1", 200, "com.picturesuo.WorkFlow.fmtest.run1", true),
            ("com.picturesuo.WorkFlow.fmtest.run2", 200, "com.picturesuo.WorkFlow", false),
            ("com.picturesuo.WorkFlowTests", 200, "com.picturesuo.WorkFlow", false),
            ("com.apple.TextEdit", 200, "com.picturesuo.WorkFlow", false),
            ("com.picturesuo.WorkFlow", 200, nil, true),
            (nil, 200, "com.picturesuo.WorkFlow", false),
            (nil, 200, nil, false),
        ]
        for row in table {
            XCTAssertEqual(
                RecordingRecovery.isAnotherWorkFlow(
                    bundleIdentifier: row.bundleIdentifier, processIdentifier: row.pid,
                    ownBundleIdentifier: row.ownBundleIdentifier, ownProcessIdentifier: own
                ),
                row.shares,
                "\(row.bundleIdentifier ?? "nil") pid \(row.pid) seen from \(row.ownBundleIdentifier ?? "nil")"
            )
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func adopt(
        into store: RecordingStore,
        anotherWorkFlowIsRunning: Bool = false,
        keepAudio: ((URL, URL) -> URL?)? = nil
    ) async -> Int {
        await RecordingRecovery.adoptOrphans(
            in: directory,
            launchedAt: launchedAt,
            store: store,
            cleanupPipeline: makeLocalPipeline(),
            anotherWorkFlowIsRunning: { anotherWorkFlowIsRunning },
            keepAudio: keepAudio ?? AudioRecorder.shared.keepTemporaryRecording
        )
    }

    /// A private in-memory History whose speech measurement is scripted.
    private func makeStore(_ database: DatabaseQueue? = nil) throws -> RecordingStore {
        try RecordingStore(
            database: database ?? DatabaseQueue(),
            recordingsDirectory: Recording.recordingsDirectory,
            temporaryRecordingsDirectory: directory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in },
            speechDetector: FixedSpeechDetector()
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

    /// Writes a 16 kHz mono 16-bit WAV of a quiet tone, the recorder's own
    /// format, dated a minute before launch unless told otherwise.
    @discardableResult
    private func makeRecording(
        seconds: Double,
        name: String = AudioRecorder.recordingFileName(),
        modified: Date? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount((seconds * 16_000).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: try XCTUnwrap(writer).processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            samples[index] = 0.2 * sin(2 * .pi * 440 * Float(index) / 16_000)
        }
        try writer?.write(from: buffer)
        writer = nil
        try setModificationDate(modified ?? launchedAt.addingTimeInterval(-60), of: url)
        return url
    }

    /// Makes every insert into History fail until the trigger is dropped.
    private func refuseRows(in database: DatabaseQueue) async throws {
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_rows BEFORE INSERT ON \(Recording.databaseTableName)
                BEGIN SELECT RAISE(ABORT, 'History refuses rows in this test'); END
                """)
        }
    }

    /// Zeroes the RIFF and data chunk sizes, keeping the file's date.
    private func zeroHeaderSizes(of url: URL) throws {
        let modified = try modificationDate(of: url)
        var bytes = [UInt8](try Data(contentsOf: url))
        var offset = 12
        var dataSizeOffset: Int?
        while offset + 8 <= bytes.count {
            let size = (0..<4).reduce(0) { $0 | Int(bytes[offset + 4 + $1]) << (8 * $1) }
            if bytes[offset..<offset + 4].elementsEqual(Array("data".utf8)) {
                dataSizeOffset = offset + 4
                break
            }
            offset += 8 + size + size % 2
        }
        let sizeOffset = try XCTUnwrap(dataSizeOffset, "The fixture has a data chunk")
        for index in 0..<4 {
            bytes[4 + index] = 0
            bytes[sizeOffset + index] = 0
        }
        try Data(bytes).write(to: url)
        try setModificationDate(modified, of: url)
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func contents(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    /// Every row, newest first, with its History audio removed after the test.
    private func rows(in store: RecordingStore) async throws -> [Recording] {
        let rows = try await store.fetchRecordings(limit: 20, offset: 0)
        historyAudio.append(contentsOf: rows.map(\.url))
        return rows
    }

    private func onlyRow(in store: RecordingStore) async throws -> Recording {
        let rows = try await rows(in: store)
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(rows.first)
    }

    /// Waits for the queue to finish and returns the newest row.
    private func settledRow(in store: RecordingStore, queue: TranscriptionQueue) async throws -> Recording {
        for _ in 0..<300 {
            if let row = try await rows(in: store).first, !row.isPending, !queue.isProcessing {
                return row
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try await onlyRow(in: store)
    }

    /// A file's bytes and date, to show it was not touched.
    private struct Snapshot: Equatable {
        let data: Data
        let modified: Date

        init(of url: URL) throws {
            data = try Data(contentsOf: url)
            modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        }
    }
}

/// Returns one scripted transcript and counts how often it was asked.
private final class CountingEngine: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Counting fixture"
    private let text: String
    private(set) var calls = 0

    init(text: String) {
        self.text = text
    }

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        calls += 1
        return text
    }
}
