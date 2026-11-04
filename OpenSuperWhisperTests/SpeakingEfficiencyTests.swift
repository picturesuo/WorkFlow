import AVFoundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

// Speaking-versus-typing figures, checked against numbers worked by hand.
// Every fixture is synthetic: no microphone, provider, pasteboard, the
// person's preferences, or their History is read or written.

private func words(_ count: Int) -> String {
    (0..<count).map { _ in "word" }.joined(separator: " ")
}

private func sample(spoken: Int, produced: Int, seconds: TimeInterval, processing: TimeInterval?) -> SpeakingSample {
    SpeakingSample(recordingSeconds: seconds, spokenWords: spoken, producedWords: produced, processingSeconds: processing)
}

private func row(
    mode: RecordingMode = .dictation,
    status: RecordingStatus = .completed,
    duration: TimeInterval = 60,
    timestamp: Date = Date()
) -> Recording {
    let id = UUID()
    return Recording(
        id: id, timestamp: timestamp, fileName: "\(id).wav", transcription: "final",
        duration: duration, status: status, progress: status == .completed ? 1 : 0, mode: mode
    )
}

private func evidence(
    for recording: Recording,
    spoken: String = words(120),
    produced: String = words(120),
    origin: CaptureOrigin? = .live,
    processing: TimeInterval? = 10
) -> DictationSource {
    DictationSource(
        recordingID: recording.id,
        recognizerText: spoken,
        emittedText: produced,
        disposition: .pasteSent,
        filter: .builtIn(.everyday),
        captureOrigin: origin,
        processingSeconds: processing
    )
}

final class SpeakingEfficiencyTests: XCTestCase {
    // 120 words in 60 s → 120 WPM. Typing 120 words at 40 WPM → 180 s.
    // 60 s recording + 10 s processing = 70 s → 180 − 70 = 110 s saved.
    func testHandCalculatedSingleDictation() throws {
        let totals = SpeakingTotals(sample(spoken: 120, produced: 120, seconds: 60, processing: 10))

        XCTAssertEqual(try XCTUnwrap(totals.speakingWPM), 120, accuracy: 1e-9)
        XCTAssertEqual(totals.typingSeconds(atWPM: 40), 180, accuracy: 1e-9)
        XCTAssertEqual(totals.dictationSeconds, 70, accuracy: 1e-9)
        XCTAssertEqual(totals.savedSeconds(atWPM: 40), 110, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.speedup(atWPM: 40)), 180.0 / 70.0, accuracy: 1e-9)
        // 120 produced words in 70 s of dictation time.
        XCTAssertEqual(try XCTUnwrap(totals.producedWPM), 120.0 / 70.0 * 60, accuracy: 1e-9)
    }

    // A: 30 words / 60 s (30 WPM). B: 270 words / 120 s (135 WPM).
    // Weighted: 300 words / 180 s = 100 WPM. A mean of rates would say 82.5.
    func testAggregateIsDurationWeightedNotAMeanOfRates() throws {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(spoken: 30, produced: 30, seconds: 60, processing: 4)),
            .eligible(sample(spoken: 270, produced: 240, seconds: 120, processing: 6)),
        ])

        let measured = summary.measured
        XCTAssertEqual(measured.count, 2)
        XCTAssertEqual(try XCTUnwrap(measured.speakingWPM), 100, accuracy: 1e-9)
        XCTAssertNotEqual(try XCTUnwrap(measured.speakingWPM), (30.0 + 135.0) / 2, accuracy: 1)
        // Typing 270 produced words at 40 WPM = 405 s; dictation 180 + 10 = 190 s.
        XCTAssertEqual(measured.typingSeconds(atWPM: 40), 405, accuracy: 1e-9)
        XCTAssertEqual(measured.savedSeconds(atWPM: 40), 215, accuracy: 1e-9)
    }

    // 10 words, 30 s recording + 5 s processing = 35 s; typing 10 words at 40 WPM = 15 s.
    func testNegativeSavingsAreReportedHonestly() {
        let totals = SpeakingTotals(sample(spoken: 10, produced: 10, seconds: 30, processing: 5))

        XCTAssertEqual(totals.savedSeconds(atWPM: 40), -20, accuracy: 1e-9)
        XCTAssertEqual(SpeakingFormat.saved(totals.savedSeconds(atWPM: 40)), "≈20s slower than typing")
    }

    func testMissingProcessingIsARecordingOnlyCohortNeverAZero() throws {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(spoken: 120, produced: 120, seconds: 60, processing: nil)),
        ])

        XCTAssertTrue(summary.measured.isEmpty)
        XCTAssertEqual(summary.recordingOnly.count, 1)
        XCTAssertEqual(summary.allEligible.count, 1)
        XCTAssertEqual(try XCTUnwrap(summary.allEligible.speakingWPM), 120, accuracy: 1e-9)

        let presentation = SpeakingPresentation(summary: summary, typingWPM: 40)
        XCTAssertEqual(presentation.savedValue, "Not measured yet")
        XCTAssertEqual(presentation.stripText, "This month: speaking 120 WPM · time saved is measured from your next dictation")
        // Recording-only: 180 s typing − 60 s recording = 120 s, labelled as excluding processing.
        XCTAssertEqual(presentation.recordingOnlyValue, "≈2m 0s saved")
        XCTAssertTrue(presentation.recordingOnlyDetail.contains("excludes processing"))
        XCTAssertTrue(presentation.recordingOnlyDetail.contains("isn’t added to the total"))
    }

    func testMeasuredAndRecordingOnlyCohortsAreNotBlended() {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(spoken: 120, produced: 120, seconds: 60, processing: 10)),
            .eligible(sample(spoken: 40, produced: 40, seconds: 20, processing: nil)),
        ])

        XCTAssertEqual(summary.measured.count, 1)
        XCTAssertEqual(summary.measured.savedSeconds(atWPM: 40), 110, accuracy: 1e-9)
        XCTAssertEqual(summary.recordingOnly.count, 1)
        // Pace uses both: 160 words / 80 s = 120 WPM.
        XCTAssertEqual(summary.allEligible.speakingWPM ?? 0, 120, accuracy: 1e-9)

        let presentation = SpeakingPresentation(summary: summary, typingWPM: 40)
        XCTAssertEqual(presentation.stripText, "This month: ≈1m 50s saved vs typing at 40 WPM · speaking 120 WPM")
        XCTAssertEqual(presentation.savedValue, "≈1m 50s saved")
        XCTAssertEqual(
            presentation.savedDetail,
            "1 dictation: recording plus measured processing took 1m 10s. Typing their 120 words at 40 WPM would take about 3m 0s, 2.6× the dictation time."
        )
        XCTAssertEqual(presentation.paceDetail, "160 words heard in 1m 20s of recording across 2 dictations, pauses included.")
    }

    func testStripReportsSlowerThanTypingWhenSavingsAreNegative() {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(spoken: 10, produced: 10, seconds: 30, processing: 5)),
        ])
        XCTAssertEqual(
            SpeakingPresentation(summary: summary, typingWPM: 40).stripText,
            "This month: ≈20s slower than typing at 40 WPM · speaking 20 WPM"
        )
    }

    func testTypingBaselineIsClampedAndChangesOnlyTheEstimate() {
        XCTAssertEqual(SpeakingEfficiency.clampedTypingWPM(0), 10)
        XCTAssertEqual(SpeakingEfficiency.clampedTypingWPM(500), 200)
        XCTAssertEqual(SpeakingEfficiency.clampedTypingWPM(.nan), SpeakingEfficiency.defaultTypingWPM)
        XCTAssertEqual(SpeakingEfficiency.defaultTypingWPM, 40)

        let totals = SpeakingTotals(sample(spoken: 120, produced: 120, seconds: 60, processing: 10))
        // At 80 WPM typing takes 90 s: 90 − 70 = 20 s saved. Pace is unchanged.
        XCTAssertEqual(totals.savedSeconds(atWPM: 80), 20, accuracy: 1e-9)
        XCTAssertEqual(totals.speakingWPM ?? 0, 120, accuracy: 1e-9)
    }

    func testEmptyInputHasNoRatesAndNoComparison() {
        let empty = SpeakingTotals()
        XCTAssertNil(empty.speakingWPM)
        XCTAssertNil(empty.speedup(atWPM: 40))
        XCTAssertNil(SpeakingPresentation(summary: .empty, typingWPM: 40).stripText)
        XCTAssertFalse(SpeakingPresentation(summary: .empty, typingWPM: 40).hasComparisons)
    }

    func testWordCountUsesSystemWordBoundaries() {
        XCTAssertEqual(SpeakingEfficiency.wordCount(""), 0)
        XCTAssertEqual(SpeakingEfficiency.wordCount("  …  — !"), 0)
        XCTAssertEqual(SpeakingEfficiency.wordCount("Don't stop, it's 3.5 km."), 5)
        XCTAssertEqual(SpeakingEfficiency.wordCount(words(120)), 120)
        XCTAssertGreaterThan(SpeakingEfficiency.wordCount("我喜欢你"), 1)
    }

    // MARK: Eligibility

    func testEligibleLiveDictationUsesOriginalCaptureCounts() throws {
        let recording = row(duration: 60)
        let result = SpeakingEfficiency.classify(recording, source: evidence(for: recording))
        XCTAssertEqual(result, .eligible(sample(spoken: 120, produced: 120, seconds: 60, processing: 10)))
    }

    func testExclusionsHaveNamedReasons() {
        let meeting = row(mode: .meeting)
        let pending = row(status: .pending)
        let transcribing = row(status: .transcribing)
        let failed = row(status: .failed)
        let legacy = row()
        let unclassified = row()
        let imported = row()
        let unfinished = row()
        let silent = row()
        let emptyOutput = row()

        XCTAssertEqual(SpeakingEfficiency.classify(meeting, source: nil), .excluded(.meeting))
        XCTAssertEqual(SpeakingEfficiency.classify(pending, source: evidence(for: pending)), .excluded(.pending))
        XCTAssertEqual(SpeakingEfficiency.classify(transcribing, source: evidence(for: transcribing)), .excluded(.pending))
        XCTAssertEqual(SpeakingEfficiency.classify(failed, source: evidence(for: failed)), .excluded(.failed))
        XCTAssertEqual(SpeakingEfficiency.classify(legacy, source: nil), .excluded(.legacy))
        XCTAssertEqual(SpeakingEfficiency.classify(unclassified, source: evidence(for: unclassified, origin: nil)), .excluded(.legacy))
        XCTAssertEqual(SpeakingEfficiency.classify(imported, source: evidence(for: imported, origin: .imported)), .excluded(.imported))
        var noText = evidence(for: unfinished)
        noText.recognizerText = nil
        XCTAssertEqual(SpeakingEfficiency.classify(unfinished, source: noText), .excluded(.legacy))
        XCTAssertEqual(SpeakingEfficiency.classify(silent, source: evidence(for: silent, spoken: " ")), .excluded(.emptyText))
        XCTAssertEqual(SpeakingEfficiency.classify(emptyOutput, source: evidence(for: emptyOutput, produced: "…")), .excluded(.emptyText))
    }

    func testZeroNegativeAndNonFiniteDurationsAreExcluded() {
        for duration in [0, -1, .nan, .infinity] as [TimeInterval] {
            let recording = row(duration: duration)
            XCTAssertEqual(
                SpeakingEfficiency.classify(recording, source: evidence(for: recording)),
                .excluded(.invalidDuration),
                "duration \(duration)"
            )
        }
    }

    func testInvalidProcessingTimeCountsAsUnmeasured() {
        for processing in [-0.5, .nan, .infinity] as [TimeInterval] {
            let recording = row()
            XCTAssertEqual(
                SpeakingEfficiency.classify(recording, source: evidence(for: recording, processing: processing)).sample?.processingSeconds,
                nil
            )
        }
    }

    func testPerDictationExplanationShowsEveryInput() {
        let measured = SpeakingFormat.explanation(sample(spoken: 120, produced: 120, seconds: 60, processing: 10), typingWPM: 40)
        XCTAssertEqual(
            measured,
            "Spoke 120 words in 1m 0s (120 WPM, pauses included). Typing the 120 words produced at an assumed 40 WPM would take about 3m 0s. Recording plus 10s of measured processing took 1m 10s, saving about 1m 50s. Editing time isn’t measured. Change the assumed typing speed in Settings → Dictation."
        )
        let unmeasured = SpeakingFormat.explanation(sample(spoken: 120, produced: 120, seconds: 60, processing: nil), typingWPM: 40)
        XCTAssertTrue(unmeasured.contains("Processing time wasn’t measured for this dictation, so no time saved is claimed."))
    }

    func testNoCompressionOrTokenLanguageInProductivityCopy() {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(spoken: 120, produced: 60, seconds: 60, processing: 10)),
            .eligible(sample(spoken: 40, produced: 40, seconds: 20, processing: nil)),
            .excluded(.meeting),
        ])
        let presentation = SpeakingPresentation(summary: summary, typingWPM: 40)
        let copy = [
            presentation.stripText ?? "", presentation.savedValue, presentation.savedDetail,
            presentation.paceDetail, presentation.recordingOnlyDetail, presentation.emptyDetail,
        ] + SpeakingPresentation.method
            + [SpeakingFormat.explanation(sample(spoken: 120, produced: 60, seconds: 60, processing: 10), typingWPM: 40)]
        for line in copy {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("token"), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("efficient"), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("compress"), line)
        }
    }
}

// MARK: - Storage, migration, and the production paths

@MainActor
final class SpeakingEfficiencyStoreTests: XCTestCase {
    private func makeStore(_ database: DatabaseQueue) throws -> RecordingStore {
        try RecordingStore(
            database: database,
            recordingsDirectory: FileManager.default.temporaryDirectory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in }
        )
    }

    func testSummaryCountsEachRowOnceAndNamesEveryExclusion() async throws {
        let store = try makeStore(DatabaseQueue())
        let measured = row(duration: 60)
        let recordingOnly = row(duration: 20)
        try await store.addRecordingSync(measured, source: evidence(for: measured))
        try await store.addRecordingSync(recordingOnly, source: evidence(for: recordingOnly, spoken: words(40), produced: words(40), processing: nil))
        let imported = row()
        try await store.addRecordingSync(imported, source: evidence(for: imported, origin: .imported))
        try await store.addRecordingSync(row(mode: .meeting))
        try await store.addRecordingSync(row())
        let failed = row(status: .failed)
        try await store.addRecordingSync(failed, source: evidence(for: failed))
        let zero = row(duration: 0)
        try await store.addRecordingSync(zero, source: evidence(for: zero))
        let old = row(timestamp: Date(timeIntervalSince1970: 0))
        try await store.addRecordingSync(old, source: evidence(for: old))

        let summary = try await store.speakingSummary(since: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(summary.measured, SpeakingTotals(sample(spoken: 120, produced: 120, seconds: 60, processing: 10)))
        XCTAssertEqual(summary.recordingOnly, SpeakingTotals(sample(spoken: 40, produced: 40, seconds: 20, processing: nil)))
        XCTAssertEqual(summary.exclusions, [.imported: 1, .meeting: 1, .legacy: 1, .failed: 1, .invalidDuration: 1])
        XCTAssertEqual(summary.measured.savedSeconds(atWPM: 40), 110, accuracy: 1e-9)

        // History rows carry the same verdict their badge reads.
        let rows = try await store.fetchRecordings(limit: 20, offset: 0)
        XCTAssertEqual(rows.first { $0.id == measured.id }?.speaking?.sample?.processingSeconds, 10)
        XCTAssertEqual(rows.first { $0.id == imported.id }?.speaking, .excluded(.imported))
        let searched = try await store.searchRecordingsAsync(query: "final")
        XCTAssertEqual(searched.first { $0.id == measured.id }?.speaking, rows.first { $0.id == measured.id }?.speaking)
    }

    func testRegenerationKeepsTheOriginalCaptureFigures() async throws {
        let store = try makeStore(DatabaseQueue())
        // A live dictation queued while the engine was busy, then transcribed.
        var queued = row(status: .pending, duration: 60)
        queued.transcription = ""
        try await store.addRecordingSync(queued, source: DictationSource(
            recordingID: queued.id, disposition: .pending, filter: .builtIn(.everyday), captureOrigin: .live
        ))
        func outcome(_ text: String) -> TranscriptCleanupOutcome {
            TranscriptCleanupOutcome(
                text: text, source: .disabled, inputTokens: nil, outputTokens: nil, modelID: nil,
                rawTokenEstimate: nil, finalTokenEstimate: nil, tokenEstimatorID: nil, cleanupInput: text
            )
        }
        await store.completeDictationSource(queued.id, recognizerText: words(120), cleanup: outcome(words(120)))
        await store.completeRecording(queued.id, transcription: words(120), cleanup: outcome(words(120)))
        let first = try await store.speakingSummary(since: .distantPast)

        // Regenerate with different text: the figures and count stay the same.
        await store.completeDictationSource(queued.id, recognizerText: words(5), cleanup: outcome(words(5)))
        await store.completeRecording(queued.id, transcription: words(5), cleanup: outcome(words(5)))
        let second = try await store.speakingSummary(since: .distantPast)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.recordingOnly, SpeakingTotals(sample(spoken: 120, produced: 120, seconds: 60, processing: nil)))
        XCTAssertTrue(second.measured.isEmpty, "Queued work never claims a processing time")
    }

    /// A v10 database (before timing columns) keeps every row and value; only
    /// sources that recorded a start time are classified as live.
    func testMigrationFromV10KeepsDataAndClassifiesOnlyProvenLiveRows() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("speaking-migration-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let indicator = row(duration: 60)
        let mainWindow = row(duration: 30)
        let legacy = row(duration: 10)
        do {
            let database = try DatabaseQueue(path: path)
            let store = try makeStore(database)
            var indicatorSource = evidence(for: indicator, origin: nil, processing: nil)
            indicatorSource.recordingStartedAt = Date()
            try await store.addRecordingSync(indicator, source: indicatorSource)
            try await store.addRecordingSync(mainWindow, source: evidence(for: mainWindow, origin: nil, processing: nil))
            try await store.addRecordingSync(legacy)
            try await database.write { db in
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN captureOrigin")
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN processingSeconds")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v11_add_dictation_timing'")
            }
            let columns = try await database.read { try $0.columns(in: "dictation_sources").map(\.name) }
            XCTAssertFalse(columns.contains("captureOrigin"))
        }

        let reopened = try DatabaseQueue(path: path)
        let store = try makeStore(reopened)
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(Set(rows.map(\.id)), [indicator.id, mainWindow.id, legacy.id])
        let indicatorSource = try await store.dictationSource(for: indicator.id)
        XCTAssertEqual(indicatorSource?.captureOrigin, .live)
        XCTAssertNil(indicatorSource?.processingSeconds)
        XCTAssertEqual(indicatorSource?.recognizerText, words(120))
        let mainWindowSource = try await store.dictationSource(for: mainWindow.id)
        XCTAssertNil(mainWindowSource?.captureOrigin, "Origin is not guessed without proof")

        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(summary.recordingOnly.count, 1)
        XCTAssertTrue(summary.measured.isEmpty)
        XCTAssertEqual(summary.exclusions, [.legacy: 2])
    }

    // MARK: Production paths, with real WAV durations and fake recognizers

    private var cleanupURLs: [URL] = []

    override func tearDown() {
        for url in cleanupURLs { try? FileManager.default.removeItem(at: url) }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    private func liveAudio(seconds: Double) throws -> URL {
        try FileManager.default.createDirectory(at: AudioRecorder.temporaryRecordingsDirectory, withIntermediateDirectories: true)
        let url = AudioRecorder.temporaryRecordingsDirectory.appendingPathComponent("speaking-\(UUID().uuidString).wav")
        try writeSilentWAV(to: url, seconds: seconds)
        cleanupURLs.append(url)
        return url
    }

    private func localPipeline() -> TranscriptCleanupPipeline {
        TranscriptCleanupPipeline(
            isEnabled: { false },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) },
            failureRecorder: { _ in }
        )
    }

    private func newestRow(_ store: RecordingStore, where predicate: (Recording) -> Bool = { !$0.isPending }) async throws -> Recording {
        for _ in 0..<300 {
            if let row = try await store.fetchRecordings(limit: 1, offset: 0).first, predicate(row) {
                cleanupURLs.append(row.url)
                return row
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(nil as Recording?, "History saved the row")
    }

    func testIndicatorDictationStoresMeasuredTimingAndReachesTheSummary() async throws {
        let store = try makeStore(DatabaseQueue())
        let gate = LatestDictationGate()
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(120))),
            recordingStore: store,
            cleanupPipeline: localPipeline(),
            delivery: { _ in .pasteSent }
        )
        defer { viewModel.cleanup() }
        let audio = try liveAudio(seconds: 2)
        let stoppedAt = ContinuousClock.now

        await viewModel.finishDictation(audioAt: audio, generation: gate.begin(), recordingStartedAt: Date(), stoppedAt: stoppedAt)
        let elapsed = SpeakingEfficiency.seconds(stoppedAt.duration(to: .now))

        let row = try await newestRow(store)
        let source = try await store.dictationSource(for: row.id)
        XCTAssertEqual(source?.captureOrigin, .live)
        let processing = try XCTUnwrap(source?.processingSeconds)
        XCTAssertGreaterThanOrEqual(processing, 0)
        XCTAssertLessThanOrEqual(processing, elapsed)
        let sample = try XCTUnwrap(row.speaking?.sample)
        XCTAssertEqual(sample.recordingSeconds, 2, accuracy: 0.05)
        XCTAssertEqual(sample.spokenWords, 120)
        XCTAssertEqual(sample.producedWords, 120)

        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(summary.measured.count, 1)
        // 120 words over 2 s of audio is 3,600 WPM, recomputed from the stored counts.
        XCTAssertEqual(summary.measured.speakingWPM ?? 0, 120 / sample.recordingSeconds * 60, accuracy: 1e-9)
        XCTAssertEqual(summary.measured.savedSeconds(atWPM: 40), 180 - sample.recordingSeconds - processing, accuracy: 1e-9)
    }

    func testIndicatorDictationWithoutAStopTimeClaimsNoProcessing() async throws {
        let store = try makeStore(DatabaseQueue())
        let gate = LatestDictationGate()
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(12))),
            recordingStore: store,
            cleanupPipeline: localPipeline(),
            delivery: { _ in .pasteSent }
        )
        defer { viewModel.cleanup() }

        await viewModel.finishDictation(audioAt: try liveAudio(seconds: 1), generation: gate.begin(), recordingStartedAt: nil)

        let row = try await newestRow(store)
        XCTAssertNil(row.speaking?.sample?.processingSeconds)
        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(summary.recordingOnly.count, 1)
        XCTAssertTrue(summary.measured.isEmpty)
    }

    func testMainWindowDictationStoresMeasuredTiming() async throws {
        let store = try makeStore(DatabaseQueue())
        let model = ContentViewModel()
        model.recordingStore = store
        model.transcriptionService = TranscriptionService(engine: FixedWordsEngine(words(30)))
        model.cleanupPipeline = localPipeline()

        await model.finishRecording(audioAt: try liveAudio(seconds: 1), stoppedAt: .now)

        let row = try await newestRow(store)
        let source = try await store.dictationSource(for: row.id)
        XCTAssertEqual(source?.captureOrigin, .live)
        XCTAssertNotNil(source?.processingSeconds)
        XCTAssertEqual(row.speaking?.sample?.spokenWords, 30)
    }

    func testQueueKeepsImportsOutAndLiveQueuedDictationsRecordingOnly() async throws {
        let store = try makeStore(DatabaseQueue())
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(40))),
            recordingStore: store,
            cleanupPipeline: localPipeline()
        )
        let imported = FileManager.default.temporaryDirectory.appendingPathComponent("speaking-import-\(UUID()).wav")
        try writeSilentWAV(to: imported, seconds: 1)
        cleanupURLs.append(imported)

        await queue.addFileToQueue(url: imported)
        _ = try await newestRow(store) { !$0.isPending && !queue.isProcessing }
        await queue.addFileToQueue(url: try liveAudio(seconds: 1), captureOrigin: .live)
        _ = try await newestRow(store) { !$0.isPending && !queue.isProcessing }

        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(summary.exclusions, [.imported: 1])
        XCTAssertEqual(summary.recordingOnly.count, 1)
        XCTAssertEqual(summary.recordingOnly.spokenWords, 40)
        XCTAssertTrue(summary.measured.isEmpty, "Time spent waiting in the queue is never claimed as processing")
    }

    func testMainWindowSummaryLoadsFromTheStore() async throws {
        let store = try makeStore(DatabaseQueue())
        let measured = row(duration: 60)
        try await store.addRecordingSync(measured, source: evidence(for: measured))
        let model = ContentViewModel(recordingStore: store)

        await model.refreshSpeakingSummary().value

        XCTAssertEqual(
            SpeakingPresentation(summary: model.speakingSummary, typingWPM: 40).stripText,
            "This month: ≈1m 50s saved vs typing at 40 WPM · speaking 120 WPM"
        )
    }
}

/// Hears the same words in every file.
private final class FixedWordsEngine: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Fixed words fixture"
    private let text: String

    init(_ text: String) { self.text = text }

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}
    func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String { text }
}

func writeSilentWAV(to url: URL, seconds: Double, sampleRate: Double = 16_000) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    // AVAudioFile writes its header on deinit, so the file is closed before use.
    try {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
    }()
}
