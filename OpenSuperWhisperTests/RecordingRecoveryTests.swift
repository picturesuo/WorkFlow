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
        // Unfinished recordings the pass must not repair: too short, still
        // being written by this process, not the recorder's name, already
        // owned by a row, and floating-point audio the repair does not cover.
        let unfinishedShort = try makeUnfinishedRecording(.killed, seconds: 0.2)
        let unfinishedNow = try makeUnfinishedRecording(.killed, seconds: 1, modified: launchedAt.addingTimeInterval(5))
        let unfinishedOtherName = try makeUnfinishedRecording(.killed, seconds: 1, name: "draft.wav")
        let unfinishedReferenced = try makeUnfinishedRecording(.killed, seconds: 1)
        try await store.addRecordingSync(Recording(
            id: UUID(), timestamp: Date(), fileName: AudioRecorder.recordingFileName(), transcription: "", duration: 1,
            status: .pending, progress: 0, sourceFileURL: unfinishedReferenced.path
        ))
        let unfinishedFloat = try makeUnfinishedRecording(.killed, seconds: 1, isFloat: true)
        let files = [
            referenced, recordedAfterLaunch, tooShort, notAudio, otherName,
            unfinishedShort, unfinishedNow, unfinishedOtherName, unfinishedReferenced, unfinishedFloat,
        ]
        let before = try files.map { try Snapshot(of: $0) }

        let adopted = await adopt(into: store)

        XCTAssertEqual(adopted, 0)
        let rows = try await rows(in: store)
        XCTAssertEqual(rows.map(\.status), [.pending, .pending], "Only the rows that were already there")
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

    // MARK: - Killed while recording

    func testARecordingKilledMidCaptureIsRepairedAndAdopted() async throws {
        // What each unfinished header reads as before recovery, in frames,
        // and whether recovery has to rewrite its sizes.
        let table: [(kind: Unfinished, readsAs: AVAudioFramePosition?, isPatched: Bool)] = [
            (.killed, 0, true),
            (.killedWithPartialFrame, 0, true),
            (.riffSizeNeverFilled, 2, true),
            (.noSizes, nil, true),
            (.allOnes, 16_000, false),
            (.declaresMoreThanIsOnDisk, 16_000, false),
        ]
        for row in table {
            let store = try makeStore()
            let orphan = try makeUnfinishedRecording(row.kind, seconds: 1, modified: launchedAt.addingTimeInterval(-7_200))
            let recordedAt = try modificationDate(of: orphan)
            let before = try Data(contentsOf: orphan)
            let samples = try payload(of: before, frames: 16_000)
            XCTAssertEqual(try? AVAudioFile(forReading: orphan).length, row.readsAs, "\(row.kind) before recovery")

            let adopted = await adopt(into: store)

            XCTAssertEqual(adopted, 1, "\(row.kind)")
            let saved = try await onlyRow(in: store)
            XCTAssertEqual(saved.status, .failed, "\(row.kind)")
            XCTAssertEqual(saved.duration, 1, accuracy: 0.001, "\(row.kind): the audio on disk, not what the header declared")
            XCTAssertEqual(saved.timestamp.timeIntervalSince1970, recordedAt.timeIntervalSince1970, accuracy: 0.002,
                           "\(row.kind): dated before the repair touched the file")
            let playable = try XCTUnwrap(saved.playableAudioURL, "\(row.kind)")
            XCTAssertEqual(try AVAudioFile(forReading: playable).length, 16_000, "\(row.kind): Regenerate can read every frame")
            let after = try Data(contentsOf: playable)
            XCTAssertEqual(try payload(of: after, frames: 16_000), samples, "\(row.kind): no sample changed")
            XCTAssertEqual(after.count, before.count, "\(row.kind): only size fields are ever rewritten")
            XCTAssertEqual(after != before, row.isPatched, "\(row.kind)")
            XCTAssertEqual(try contents(of: directory), [], "\(row.kind)")
        }
    }

    func testTheFixtureMatchesAKilledCoreAudioWriter() throws {
        // A writer killed with SIGKILL left: JUNK, fmt, a FLLR filler up to
        // byte 4,096, RIFF size 4,088, data size 0, and every sample on disk.
        let bytes = [UInt8](try Data(contentsOf: try makeUnfinishedRecording(.killed, seconds: 1)))
        XCTAssertEqual(String(bytes: bytes[12..<16], encoding: .ascii), "JUNK")
        XCTAssertEqual(String(bytes: bytes[48..<52], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(bytes: bytes[72..<76], encoding: .ascii), "FLLR")
        XCTAssertEqual(String(bytes: bytes[4_088..<4_092], encoding: .ascii), "data")
        XCTAssertEqual(Array(bytes[4..<8]), [0xF8, 0x0F, 0, 0])
        XCTAssertEqual(Array(bytes[4_092..<4_096]), [0, 0, 0, 0])
        XCTAssertEqual(bytes.count, 4_096 + 32_000)
    }

    func testNothingIsRepairedWhileAnotherWorkFlowIsRunning() async throws {
        let store = try makeStore()
        let orphan = try makeUnfinishedRecording(.killed, seconds: 1)
        let before = try Snapshot(of: orphan)

        let adopted = await adopt(into: store, anotherWorkFlowIsRunning: true)

        XCTAssertEqual(adopted, 0)
        XCTAssertEqual(try Snapshot(of: orphan), before, "The other WorkFlow may still be writing it")
    }

    func testARepairThatCannotBeWrittenLeavesTheFileUntouchedAndUnadopted() async throws {
        let store = try makeStore()
        let orphan = try makeUnfinishedRecording(.killed, seconds: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: orphan.path)
        let before = try Snapshot(of: orphan)

        let adopted = await adopt(into: store)

        XCTAssertEqual(adopted, 0, "A row whose audio the engine cannot read would promise a Regenerate that fails")
        let rows = try await rows(in: store)
        XCTAssertEqual(rows.count, 0)
        XCTAssertEqual(try Snapshot(of: orphan), before)
    }

    func testARepairedRecordingKeepsItsDateWhenHistoryCannotSaveIt() async throws {
        let database = try DatabaseQueue()
        let store = try makeStore(database)
        try await refuseRows(in: database)
        let orphan = try makeUnfinishedRecording(.killed, seconds: 1, modified: launchedAt.addingTimeInterval(-7_200))
        let recordedAt = try modificationDate(of: orphan)

        let adopted = await adopt(into: store)

        XCTAssertEqual(adopted, 0)
        XCTAssertEqual(try AVAudioFile(forReading: orphan).length, 16_000, "Back where it was found, now readable")
        XCTAssertEqual(try modificationDate(of: orphan), recordedAt, "Still dated when it was recorded")

        try await database.write { db in try db.execute(sql: "DROP TRIGGER refuse_rows") }
        let retried = await adopt(into: store)
        XCTAssertEqual(retried, 1)
        let saved = try await onlyRow(in: store)
        XCTAssertEqual(saved.timestamp.timeIntervalSince1970, recordedAt.timeIntervalSince1970, accuracy: 0.002)
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
        modified: Date? = nil,
        isFloat: Bool = false
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: isFloat ? 32 : 16,
            AVLinearPCMIsFloatKey: isFloat,
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

    /// The header states a recording is left in when its writer never stopped.
    private enum Unfinished {
        /// What a killed CoreAudio writer leaves: the RIFF size covers only
        /// the header, the data size is 0, every sample is on disk.
        case killed
        /// The same, killed halfway through writing a frame.
        case killedWithPartialFrame
        /// The data size was filled in but the RIFF size was not.
        case riffSizeNeverFilled
        /// Both sizes are 0.
        case noSizes
        /// Both sizes are 0xFFFFFFFF, a streaming writer's placeholder.
        case allOnes
        /// Sizes for twice the audio that reached the disk.
        case declaresMoreThanIsOnDisk
    }

    /// Writes a finished recording, then rewrites its header and length the
    /// way an interrupted writer would have left them.
    private func makeUnfinishedRecording(
        _ kind: Unfinished,
        seconds: Double,
        name: String = AudioRecorder.recordingFileName(),
        modified: Date? = nil,
        isFloat: Bool = false
    ) throws -> URL {
        let written = kind == .declaresMoreThanIsOnDisk ? seconds * 2 : seconds
        let url = try makeRecording(seconds: written, name: name, modified: modified, isFloat: isFloat)
        let date = try modificationDate(of: url)
        var bytes = [UInt8](try Data(contentsOf: url))
        let dataOffset = try dataOffset(in: bytes)
        func set(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        switch kind {
        case .killed:
            set(UInt32(dataOffset - 8), at: 4)
            set(0, at: dataOffset - 4)
        case .killedWithPartialFrame:
            set(UInt32(dataOffset - 8), at: 4)
            set(0, at: dataOffset - 4)
            bytes.append(0x55)
        case .riffSizeNeverFilled:
            set(UInt32(dataOffset - 8), at: 4)
        case .noSizes:
            set(0, at: 4)
            set(0, at: dataOffset - 4)
        case .allOnes:
            set(0xFFFF_FFFF, at: 4)
            set(0xFFFF_FFFF, at: dataOffset - 4)
        case .declaresMoreThanIsOnDisk:
            bytes.removeLast((bytes.count - dataOffset) / 2)
        }
        try Data(bytes).write(to: url)
        try setModificationDate(date, of: url)
        return url
    }

    /// Where the samples of a fixture begin.
    private func dataOffset(in bytes: [UInt8]) throws -> Int {
        var offset = 12
        var found: Int?
        while found == nil, offset + 8 <= bytes.count {
            if bytes[offset..<offset + 4].elementsEqual(Array("data".utf8)) { found = offset + 8 }
            let size = (0..<4).reduce(0) { $0 | Int(bytes[offset + 4 + $1]) << (8 * $1) }
            offset += 8 + size + size % 2
        }
        return try XCTUnwrap(found, "The fixture has a data chunk")
    }

    /// The first `frames` 16-bit samples of a fixture.
    private func payload(of data: Data, frames: Int) throws -> Data {
        let offset = try dataOffset(in: [UInt8](data))
        return data.subdata(in: offset..<offset + frames * 2)
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
