import AVFoundation
import CryptoKit
import GRDB
import XCTest
@testable import OpenSuperWhisper

// Speaking-versus-typing figures by estimated active speech, checked against
// numbers worked by hand. Every fixture is synthetic or the repository's own
// jfk.wav: no microphone, provider, network, pasteboard, the person's
// preferences, or their History is read or written.

private func words(_ count: Int) -> String {
    (0..<count).map { _ in "word" }.joined(separator: " ")
}

private func sample(
    active: TimeInterval,
    recorded: TimeInterval = 60,
    spoken: Int,
    produced: Int,
    processing: TimeInterval? = nil
) -> SpeakingSample {
    SpeakingSample(
        recordingSeconds: recorded, activeSpeechSeconds: active,
        spokenWords: spoken, producedWords: produced, processingSeconds: processing
    )
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
    processing: TimeInterval? = 10,
    activity: SpeechActivityStatus? = .measured,
    active: TimeInterval? = 30
) -> DictationSource {
    var source = DictationSource(
        recordingID: recording.id,
        recognizerText: spoken,
        emittedText: produced,
        disposition: .pasteSent,
        filter: .builtIn(.everyday),
        captureOrigin: origin,
        processingSeconds: processing,
        speechActivity: activity
    )
    if activity == .measured {
        source.activeSpeechSeconds = active
        source.speechDetector = "fixture"
    }
    return source
}

final class SpeakingEfficiencyTests: XCTestCase {
    // 120 heard words at 40 WPM → 180 s of typing. 45 s of active speech
    // → 180 − 45 = 135 s = 2.25 min saved, 180 ÷ 45 = 4.0× faster.
    // 120 heard words in 45 s of active speech → 160 WPM while talking.
    // The 130 words cleanup produced are not typed in the estimate.
    func testHandCalculatedSingleDictation() throws {
        let totals = SpeakingTotals(sample(active: 45, recorded: 70, spoken: 120, produced: 130, processing: 3))

        XCTAssertEqual(totals.typingSeconds(atWPM: 40), 180, accuracy: 1e-9)
        XCTAssertEqual(totals.savedSeconds(atWPM: 40), 135, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.speedup(atWPM: 40)), 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.speakingWPM), 160, accuracy: 1e-9)
        XCTAssertEqual(SpeakingFormat.headline(totals, typingWPM: 40), "≈2.3 min saved · 4.0× faster")
    }

    // Recording length and the wait for text change nothing: only active speech is compared.
    func testIdleTimeAndProcessingWaitDoNotChangeTheFigures() {
        let straight = SpeakingTotals(sample(active: 45, recorded: 50, spoken: 120, produced: 130, processing: 2))
        let paused = SpeakingTotals(sample(active: 45, recorded: 110, spoken: 120, produced: 130, processing: 20))

        XCTAssertEqual(straight.savedSeconds(atWPM: 40), paused.savedSeconds(atWPM: 40))
        XCTAssertEqual(straight.speedup(atWPM: 40), paused.speedup(atWPM: 40))
        XCTAssertEqual(
            SpeakingFormat.headline(straight, typingWPM: 40),
            SpeakingFormat.headline(paused, typingWPM: 40)
        )
    }

    // A: 20 heard words (30 s typing) in 60 s active → 0.5×. B: 200 heard
    // words (300 s typing) in 30 s active → 10×. Same cohort: 330 ÷ 90 =
    // 3.67×, never the mean of rows (5.25×). Saved: 330 − 90 = 240 s = 4.0 min.
    // Pace: 220 heard words ÷ 90 s = 146.7 WPM.
    func testCohortIsARatioOfSumsNeverAMeanOfRows() throws {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(active: 60, recorded: 90, spoken: 20, produced: 25)),
            .eligible(sample(active: 30, recorded: 40, spoken: 200, produced: 210)),
        ])
        let counted = summary.counted

        XCTAssertEqual(counted.count, 2)
        XCTAssertEqual(counted.typingSeconds(atWPM: 40), 330, accuracy: 1e-9)
        XCTAssertEqual(counted.activeSpeechSeconds, 90, accuracy: 1e-9)
        XCTAssertEqual(counted.savedSeconds(atWPM: 40), 240, accuracy: 1e-9)
        let ratio = try XCTUnwrap(counted.speedup(atWPM: 40))
        XCTAssertEqual(ratio, 330.0 / 90, accuracy: 1e-9)
        XCTAssertNotEqual(ratio, (0.5 + 10) / 2, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(counted.speakingWPM), 220.0 / 90 * 60, accuracy: 1e-9)
        XCTAssertEqual(SpeakingPresentation(summary: summary, typingWPM: 40).stripText, "This month: ≈4.0 min saved · 3.7× faster")
    }

    // 10 words → 15 s of typing; 40 s of active speech → −25 s, 0.375×.
    func testNegativeSavingsAndSlowerRatiosStayHonest() throws {
        let totals = SpeakingTotals(sample(active: 40, spoken: 10, produced: 10))

        XCTAssertEqual(totals.savedSeconds(atWPM: 40), -25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.speedup(atWPM: 40)), 0.375, accuracy: 1e-9)
        XCTAssertEqual(SpeakingFormat.headline(totals, typingWPM: 40), "≈−0.4 min saved · 0.4× as fast")
        XCTAssertEqual(
            SpeakingPresentation(summary: SpeakingEfficiency.summarize([.eligible(sample(active: 40, spoken: 10, produced: 10))]), typingWPM: 40).stripText,
            "This month: ≈−0.4 min saved · 0.4× as fast"
        )
    }

    func testMinutesAndMultipliersRoundUsefullyBelowAMinute() {
        XCTAssertEqual(SpeakingFormat.minutes(0), "0 min")
        XCTAssertEqual(SpeakingFormat.minutes(2), "0 min")
        XCTAssertEqual(SpeakingFormat.minutes(-2), "0 min")
        XCTAssertEqual(SpeakingFormat.minutes(9), "0.2 min")
        XCTAssertEqual(SpeakingFormat.minutes(40), "0.7 min")
        XCTAssertEqual(SpeakingFormat.minutes(135), "2.3 min")
        XCTAssertEqual(SpeakingFormat.minutes(594), "9.9 min")
        XCTAssertEqual(SpeakingFormat.minutes(598), "10 min")
        XCTAssertEqual(SpeakingFormat.minutes(750), "13 min")
        XCTAssertEqual(SpeakingFormat.minutes(-90), "−1.5 min")
        XCTAssertEqual(SpeakingFormat.minutes(-1_500), "−25 min")
        XCTAssertEqual(SpeakingFormat.speedup(4), "4.0× faster")
        XCTAssertEqual(SpeakingFormat.speedup(1.2), "1.2× faster")
        XCTAssertEqual(SpeakingFormat.speedup(1.02), "1.0× as fast")
        XCTAssertEqual(SpeakingFormat.speedup(0.375), "0.4× as fast")
        XCTAssertEqual(SpeakingFormat.speedup(9.96), "10× faster")
        XCTAssertEqual(SpeakingFormat.speedup(12.4), "12× faster")
    }

    func testTypingBaselineIsClampedAndChangesOnlyTheEstimate() throws {
        XCTAssertEqual(SpeakingEfficiency.clampedTypingWPM(0), 10)
        XCTAssertEqual(SpeakingEfficiency.clampedTypingWPM(500), 200)
        XCTAssertEqual(SpeakingEfficiency.clampedTypingWPM(.nan), SpeakingEfficiency.defaultTypingWPM)
        XCTAssertEqual(SpeakingEfficiency.defaultTypingWPM, 40)

        let totals = SpeakingTotals(sample(active: 45, spoken: 120, produced: 130))
        // At 80 WPM typing takes 90 s: 90 − 45 = 45 s saved, 2.0×. Pace is unchanged.
        XCTAssertEqual(totals.savedSeconds(atWPM: 80), 45, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.speedup(atWPM: 80)), 2, accuracy: 1e-9)
        XCTAssertEqual(totals.speakingWPM ?? 0, 160, accuracy: 1e-9)
    }

    // 20 heard words → 30 s of typing against 6 s of active speech, whether
    // cleanup kept 20 words or expanded them to 200 (as Homework can):
    // 24 s = 0.4 min saved, 5.0× faster. By produced words it would have
    // claimed 300 s of typing and 49×.
    func testCleanupExpansionNeverInflatesTheEstimate() {
        let kept = SpeakingTotals(sample(active: 6, spoken: 20, produced: 20))
        let expanded = SpeakingTotals(sample(active: 6, spoken: 20, produced: 200))

        XCTAssertEqual(expanded.typingSeconds(atWPM: 40), 30, accuracy: 1e-9)
        XCTAssertEqual(expanded.savedSeconds(atWPM: 40), kept.savedSeconds(atWPM: 40))
        XCTAssertEqual(expanded.speedup(atWPM: 40), kept.speedup(atWPM: 40))
        XCTAssertEqual(SpeakingFormat.headline(expanded, typingWPM: 40), "≈0.4 min saved · 5.0× faster")
        XCTAssertEqual(SpeakingFormat.headline(kept, typingWPM: 40), "≈0.4 min saved · 5.0× faster")
        XCTAssertEqual(expanded.producedWords, 200, "The produced count stays its own figure")
    }

    func testEmptyInputHasNoRatesAndNoComparison() {
        let empty = SpeakingTotals()
        XCTAssertNil(empty.speakingWPM)
        XCTAssertNil(empty.speedup(atWPM: 40))
        XCTAssertNil(SpeakingFormat.headline(empty, typingWPM: 40))
        XCTAssertNil(SpeakingPresentation(summary: .empty, typingWPM: 40).stripText)
        XCTAssertFalse(SpeakingPresentation(summary: .empty, typingWPM: 40).hasComparisons)
        XCTAssertNil(SpeakingPresentation(summary: .empty, typingWPM: 40).notCountedValue)
    }

    func testWordCountUsesSystemWordBoundaries() {
        XCTAssertEqual(SpeakingEfficiency.wordCount(""), 0)
        XCTAssertEqual(SpeakingEfficiency.wordCount("  …  — !"), 0)
        XCTAssertEqual(SpeakingEfficiency.wordCount("Don't stop, it's 3.5 km."), 5)
        XCTAssertEqual(SpeakingEfficiency.wordCount(words(120)), 120)
        XCTAssertGreaterThan(SpeakingEfficiency.wordCount("我喜欢你"), 1)
    }

    // MARK: Presentation

    func testMonthlyBarIsMinutesAndMultiplierWithoutTypingSpeedOrPace() throws {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(active: 60, recorded: 90, spoken: 20, produced: 25, processing: 4)),
            .eligible(sample(active: 30, recorded: 40, spoken: 200, produced: 210, processing: 2)),
        ])
        let strip = try XCTUnwrap(SpeakingPresentation(summary: summary, typingWPM: 40).stripText)

        XCTAssertEqual(strip, "This month: ≈4.0 min saved · 3.7× faster")
        for hidden in ["WPM", "40", "words per minute", "speaking", "typing"] {
            XCTAssertFalse(strip.localizedCaseInsensitiveContains(hidden), "The bar leaves \(hidden) to Settings")
        }
    }

    func testSettingsHoldTheAssumptionPaceAndMethod() {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(active: 60, recorded: 90, spoken: 20, produced: 25)),
            .eligible(sample(active: 30, recorded: 40, spoken: 200, produced: 210)),
            .excluded(.meeting),
            .excluded(.speechNotMeasured),
            .excluded(.speechNotMeasured),
        ])
        let presentation = SpeakingPresentation(summary: summary, typingWPM: 40)

        XCTAssertEqual(presentation.savedValue, "≈4.0 min saved")
        XCTAssertEqual(
            presentation.savedDetail,
            "Typing the 220 words you said in 2 dictations at 40 WPM would take about 5.5 min; you spoke them in 1.5 min of active speech."
        )
        XCTAssertEqual(presentation.speedValue, "3.7× faster")
        XCTAssertEqual(presentation.activeValue, "1.5 min")
        XCTAssertEqual(
            presentation.activeDetail,
            "Estimated by the speech detector on this Mac, out of 2.2 min recorded. Pauses, thinking, and waiting for text aren’t counted. Speaking pace while talking: 147 WPM."
        )
        XCTAssertEqual(presentation.notCountedValue, "3")
        XCTAssertEqual(presentation.notCountedDetail, "Meetings: 1 · Recorded before active speech was measured: 2")
        XCTAssertTrue(SpeakingPresentation.method.joined().contains("the recognizer heard ÷ the assumed typing speed"))
        XCTAssertTrue(SpeakingPresentation.method.joined().contains("typing time − active speech"))
        XCTAssertTrue(SpeakingPresentation.method.joined().contains("never averaged per dictation"))
    }

    // Dictations from before this version are left out and visibly so, never zero.
    func testUnknownActiveSpeechIsVisiblyNotCountedNeverZero() {
        let summary = SpeakingEfficiency.summarize([.excluded(.speechNotMeasured), .excluded(.speechNotMeasured)])
        let presentation = SpeakingPresentation(summary: summary, typingWPM: 40)

        XCTAssertFalse(presentation.hasComparisons)
        XCTAssertEqual(presentation.stripText, "This month: time saved counts from your next dictation")
        XCTAssertEqual(presentation.notCountedValue, "2")
        XCTAssertTrue(presentation.emptyDetail.contains("aren’t counted"))
        XCTAssertFalse((presentation.stripText ?? "").contains("0 min"))
    }

    func testPerDictationExplanationShowsEveryInput() {
        XCTAssertEqual(
            SpeakingFormat.explanation(sample(active: 45, recorded: 70, spoken: 120, produced: 130, processing: 3), typingWPM: 40),
            "About 45s of active speech in 1m 10s recorded, as estimated by the speech detector on this Mac; pauses aren’t counted. Typing the 120 words you said at an assumed 40 WPM would take about 3m 0s: ≈2.3 min saved · 4.0× faster. The text was ready 3s after you stopped; that wait isn’t counted. Editing time isn’t measured. Change the assumed typing speed in Settings → Dictation."
        )
        XCTAssertFalse(
            SpeakingFormat.explanation(sample(active: 45, spoken: 120, produced: 130, processing: nil), typingWPM: 40)
                .contains("ready")
        )
    }

    func testNoCompressionOrTokenLanguageInProductivityCopy() {
        let summary = SpeakingEfficiency.summarize([
            .eligible(sample(active: 30, spoken: 120, produced: 60, processing: 10)),
            .excluded(.meeting),
            .excluded(.speechUnavailable),
        ])
        let presentation = SpeakingPresentation(summary: summary, typingWPM: 40)
        let copy = [
            presentation.stripText ?? "", presentation.savedValue, presentation.savedDetail,
            presentation.speedDetail, presentation.activeDetail, presentation.notCountedDetail, presentation.emptyDetail,
        ] + SpeakingPresentation.method
            + [SpeakingFormat.explanation(sample(active: 30, spoken: 120, produced: 60, processing: 10), typingWPM: 40)]
        for line in copy {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("token"), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("efficient"), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("compress"), line)
        }
    }

    // MARK: Eligibility

    func testEligibleLiveDictationUsesOriginalCountsAndActiveSpeech() {
        let recording = row(duration: 60)
        XCTAssertEqual(
            SpeakingEfficiency.classify(recording, source: evidence(for: recording, active: 30)),
            .eligible(sample(active: 30, recorded: 60, spoken: 120, produced: 120, processing: 10))
        )
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
        let unknown = row()
        let measuring = row()
        let unavailable = row()

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
        XCTAssertEqual(SpeakingEfficiency.classify(unknown, source: evidence(for: unknown, activity: nil)), .excluded(.speechNotMeasured))
        XCTAssertEqual(SpeakingEfficiency.classify(measuring, source: evidence(for: measuring, activity: .measuring)), .excluded(.measuringSpeech))
        XCTAssertEqual(SpeakingEfficiency.classify(unavailable, source: evidence(for: unavailable, activity: .unavailable)), .excluded(.speechUnavailable))
    }

    // A measured row without a usable figure is never zero and never the recording length.
    func testUnusableActiveSpeechIsUnavailable() {
        for active in [nil, 0, -1, .nan, .infinity] as [TimeInterval?] {
            let recording = row()
            XCTAssertEqual(
                SpeakingEfficiency.classify(recording, source: evidence(for: recording, active: active)),
                .excluded(.speechUnavailable),
                "active \(String(describing: active))"
            )
        }
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
}

// MARK: - Measuring active speech

/// Returns fixed intervals and records which audio it was asked about.
final class FixedSpeechDetector: SpeechDetecting, @unchecked Sendable {
    let detectorID = "fixture"
    private let intervals: [SpeechInterval]
    private let analyzedSeconds: TimeInterval
    private let error: Error?
    private let lock = NSLock()
    private var requested: [URL] = []

    init(intervals: [SpeechInterval] = [], analyzedSeconds: TimeInterval = 600, error: Error? = nil) {
        self.intervals = intervals
        self.analyzedSeconds = analyzedSeconds
        self.error = error
    }

    var requestedURLs: [URL] { lock.withLock { requested } }

    func detectSpeech(in audioURL: URL) async throws -> SpeechDetection {
        lock.withLock { requested.append(audioURL) }
        if let error { throw error }
        return SpeechDetection(intervals: intervals, analyzedSeconds: analyzedSeconds)
    }
}

/// Holds every detection until released, to show nothing waits for it.
final class GatedSpeechDetector: SpeechDetecting, @unchecked Sendable {
    let detectorID = "gated"
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var startedCount = 0

    var started: Int { lock.withLock { startedCount } }

    func release() {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            isReleased = true
            defer { waiting.removeAll() }
            return waiting
        }
        continuations.forEach { $0.resume() }
    }

    func detectSpeech(in audioURL: URL) async throws -> SpeechDetection {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                startedCount += 1
                if isReleased { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return SpeechDetection(intervals: [SpeechInterval(start: 0.5, end: 1.5)], analyzedSeconds: 2)
    }
}

final class SpeechActivityTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private var cleanupURLs: [URL] = []

    override func tearDown() {
        for url in cleanupURLs { try? FileManager.default.removeItem(at: url) }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    // Clamped to [0, 10]: (0,2) (1.5,3) (5,6) (5.5,5.8) (9,10); (4,4) and
    // (7,6.5) are empty and NaN is dropped. Union: (0,3) + (5,6) + (9,10) = 5 s.
    func testUnionClampsAndMergesHandWorkedIntervals() {
        let intervals = [
            SpeechInterval(start: 9, end: 12), SpeechInterval(start: -1, end: 2), SpeechInterval(start: 5.5, end: 5.8),
            SpeechInterval(start: 1.5, end: 3), SpeechInterval(start: 4, end: 4), SpeechInterval(start: 7, end: 6.5),
            SpeechInterval(start: .nan, end: 1), SpeechInterval(start: 5, end: 6),
        ]
        XCTAssertEqual(SpeechActivity.unionSeconds(intervals, within: 10), 5, accuracy: 1e-12)
        // Touching intervals join; a repeated interval counts once.
        XCTAssertEqual(SpeechActivity.unionSeconds([
            SpeechInterval(start: 0, end: 1), SpeechInterval(start: 1, end: 2), SpeechInterval(start: 0, end: 1),
        ], within: 10), 2, accuracy: 1e-12)
        XCTAssertEqual(SpeechActivity.unionSeconds(intervals, within: 0), 0)
        XCTAssertEqual(SpeechActivity.unionSeconds([SpeechInterval(start: 11, end: 20)], within: 10), 0)
    }

    func testFailureSilenceAndOutOfRangeAreUnavailableNeverZero() async {
        let url = URL(fileURLWithPath: "/nonexistent/fixture.wav")
        let failed = await SpeechActivity.measure(url, with: FixedSpeechDetector(error: SpeechDetectionError.detectionFailed))
        XCTAssertEqual(failed, .unavailable("fixture"))
        let silent = await SpeechActivity.measure(url, with: FixedSpeechDetector(intervals: []))
        XCTAssertEqual(silent, .unavailable("fixture"))
        let outside = await SpeechActivity.measure(url, with: FixedSpeechDetector(intervals: [SpeechInterval(start: 30, end: 40)], analyzedSeconds: 20))
        XCTAssertEqual(outside, .unavailable("fixture"))
        let heard = await SpeechActivity.measure(url, with: FixedSpeechDetector(intervals: [
            SpeechInterval(start: 1, end: 3), SpeechInterval(start: 2, end: 4.5),
        ], analyzedSeconds: 20))
        XCTAssertEqual(heard, SpeechActivityMeasurement(status: .measured, activeSeconds: 3.5, detectorID: "fixture"))
    }

    // MARK: The bundled detector on real and synthetic audio

    private func jfkSamples() async throws -> [Float] {
        let converted = try await WhisperEngine().convertAudioToPCM(fileURL: Self.repoRoot.appendingPathComponent("jfk.wav"))
        return try XCTUnwrap(converted)
    }

    private func wav(_ samples: [Float], _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(name)-\(UUID().uuidString).wav")
        try writeWAV(samples, to: url)
        cleanupURLs.append(url)
        return url
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    /// Deterministic noise in [-amplitude, amplitude].
    private func whiteNoise(_ seconds: Double, amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<Int(seconds * 16_000)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    // jfk.wav is 11.0 s; its speech is about 7.4 s with four pauses.
    func testBundledDetectorTimesSpeechInARealRecording() async throws {
        let url = Self.repoRoot.appendingPathComponent("jfk.wav")
        let measurement = await SpeechActivity.measure(url, with: SileroSpeechDetector())

        XCTAssertEqual(measurement.status, .measured)
        XCTAssertEqual(measurement.detectorID, "silero-v5.1.2/whisper.cpp-default")
        XCTAssertEqual(try XCTUnwrap(measurement.activeSeconds), 7.44, accuracy: 0.3)
    }

    // The same speech twice, 2 s or 34 s apart, measures the same active
    // speech: the detector's state carries a few hundredths of a second, not
    // the 32 s of extra pause.
    func testLongIdleBetweenIdenticalSpeechMeasuresTheSameActiveSpeech() async throws {
        let speech = try await jfkSamples()
        let detector = SileroSpeechDetector()
        let close = await SpeechActivity.measure(try wav(speech + silence(2) + speech, "close"), with: detector)
        let apart = await SpeechActivity.measure(try wav(speech + silence(34) + speech, "apart"), with: detector)

        let closeSeconds = try XCTUnwrap(close.activeSeconds)
        let apartSeconds = try XCTUnwrap(apart.activeSeconds)
        XCTAssertEqual(closeSeconds, apartSeconds, accuracy: 0.1)
        XCTAssertEqual(closeSeconds, 2 * 7.44, accuracy: 0.6)
    }

    // Steady noise and a pure tone are not speech; noise under speech does
    // not inflate it. A low hum near a voice's pitch can still be counted;
    // that limit is stated in Settings.
    func testSyntheticNoiseIsNotCountedAsSpeech() async throws {
        let detector = SileroSpeechDetector()
        let tone = (0..<64_000).map { 0.3 * Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let fixtures: [(String, [Float])] = [
            ("white-40dB", whiteNoise(4, amplitude: 0.01, seed: 1)),
            ("white-20dB", whiteNoise(4, amplitude: 0.1, seed: 2)),
            ("white-6dB", whiteNoise(4, amplitude: 0.5, seed: 3)),
            ("tone-440Hz", tone),
        ]
        for (name, samples) in fixtures {
            let measurement = await SpeechActivity.measure(try wav(samples, name), with: detector)
            XCTAssertEqual(measurement.status, .unavailable, name)
            XCTAssertNil(measurement.activeSeconds, name)
        }

        let speech = try await jfkSamples()
        let noisy = zip(speech, whiteNoise(Double(speech.count) / 16_000, amplitude: 0.03, seed: 4)).map(+)
        let clean = await SpeechActivity.measure(try wav(speech, "clean"), with: detector)
        let withNoise = await SpeechActivity.measure(try wav(noisy, "noisy"), with: detector)
        XCTAssertEqual(try XCTUnwrap(withNoise.activeSeconds), try XCTUnwrap(clean.activeSeconds), accuracy: 0.2)
    }

    func testMissingModelOrUnreadableAudioIsUnavailable() async throws {
        let jfk = Self.repoRoot.appendingPathComponent("jfk.wav")
        let noModel = await SpeechActivity.measure(jfk, with: SileroSpeechDetector(modelPath: "/nonexistent/silero.bin"))
        XCTAssertEqual(noModel.status, .unavailable)

        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("speech-garbage-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: garbage)
        cleanupURLs.append(garbage)
        let unreadable = await SpeechActivity.measure(garbage, with: SileroSpeechDetector())
        XCTAssertEqual(unreadable.status, .unavailable)
    }

    func testMeasuringReadsTheAudioWithoutChangingIt() async throws {
        let url = try wav(try await jfkSamples() + silence(1), "unchanged")
        let before = SHA256.hash(data: try Data(contentsOf: url))
        _ = await SpeechActivity.measure(url, with: SileroSpeechDetector())
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
    }
}

// MARK: - Storage, migration, and the production paths

@MainActor
final class SpeakingEfficiencyStoreTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func makeStore(_ database: DatabaseQueue, detector: any SpeechDetecting = FixedSpeechDetector()) throws -> RecordingStore {
        try RecordingStore(
            database: database,
            recordingsDirectory: FileManager.default.temporaryDirectory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in },
            speechDetector: detector
        )
    }

    func testSummaryCountsEachRowOnceAndNamesEveryExclusion() async throws {
        let store = try makeStore(DatabaseQueue())
        let counted = row(duration: 60)
        try await store.addRecordingSync(counted, source: evidence(for: counted, active: 45))
        let unknown = row(duration: 20)
        try await store.addRecordingSync(unknown, source: evidence(for: unknown, activity: nil))
        let unavailable = row()
        try await store.addRecordingSync(unavailable, source: evidence(for: unavailable, activity: .unavailable))
        let imported = row()
        try await store.addRecordingSync(imported, source: evidence(for: imported, origin: .imported, activity: nil))
        try await store.addRecordingSync(row(mode: .meeting))
        try await store.addRecordingSync(row())
        let failed = row(status: .failed)
        try await store.addRecordingSync(failed, source: evidence(for: failed))
        let zero = row(duration: 0)
        try await store.addRecordingSync(zero, source: evidence(for: zero))
        let old = row(timestamp: Date(timeIntervalSince1970: 0))
        try await store.addRecordingSync(old, source: evidence(for: old))

        let summary = try await store.speakingSummary(since: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(summary.counted, SpeakingTotals(sample(active: 45, recorded: 60, spoken: 120, produced: 120, processing: 10)))
        XCTAssertEqual(summary.exclusions, [
            .speechNotMeasured: 1, .speechUnavailable: 1, .imported: 1, .meeting: 1, .legacy: 1, .failed: 1, .invalidDuration: 1,
        ])
        // 180 s of typing − 45 s of active speech.
        XCTAssertEqual(summary.counted.savedSeconds(atWPM: 40), 135, accuracy: 1e-9)

        // History rows carry the same verdict their badge reads.
        let rows = try await store.fetchRecordings(limit: 20, offset: 0)
        XCTAssertEqual(rows.first { $0.id == counted.id }?.speaking?.sample?.activeSpeechSeconds, 45)
        XCTAssertEqual(rows.first { $0.id == unknown.id }?.speaking, .excluded(.speechNotMeasured))
        let searched = try await store.searchRecordingsAsync(query: "final")
        XCTAssertEqual(searched.first { $0.id == counted.id }?.speaking, rows.first { $0.id == counted.id }?.speaking)
    }

    private func outcome(_ text: String) -> TranscriptCleanupOutcome {
        TranscriptCleanupOutcome(
            text: text, source: .disabled, inputTokens: nil, outputTokens: nil, modelID: nil,
            rawTokenEstimate: nil, finalTokenEstimate: nil, tokenEstimatorID: nil, cleanupInput: text
        )
    }

    private func audioInHistory(for recording: Recording, seconds: Double = 2) throws -> URL {
        try FileManager.default.createDirectory(at: Recording.recordingsDirectory, withIntermediateDirectories: true)
        try writeSilentWAV(to: recording.url, seconds: seconds)
        cleanupURLs.append(recording.url)
        return recording.url
    }

    func testRegenerationKeepsTheOriginalActiveSpeechAndWords() async throws {
        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 1, end: 31)])
        let store = try makeStore(DatabaseQueue(), detector: detector)
        // A live dictation queued while the engine was busy, then transcribed.
        var queued = row(status: .pending, duration: 60)
        queued.transcription = ""
        try await store.addRecordingSync(queued, source: DictationSource(
            recordingID: queued.id, disposition: .pending, filter: .builtIn(.everyday),
            captureOrigin: .live, speechActivity: .measuring
        ))
        _ = try audioInHistory(for: queued)
        // Not measured while still queued: its audio has not moved into History yet.
        await store.measureSpeechActivity(for: queued.id)
        XCTAssertTrue(detector.requestedURLs.isEmpty)

        await store.completeDictationSource(queued.id, recognizerText: words(120), cleanup: outcome(words(120)))
        await store.completeRecording(queued.id, transcription: words(120), cleanup: outcome(words(120)))
        await store.measureSpeechActivity(for: queued.id)
        let first = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(first.counted, SpeakingTotals(sample(active: 30, recorded: 60, spoken: 120, produced: 120)))

        // Regenerate with different text: the figures, count, and measurement stay.
        await store.completeDictationSource(queued.id, recognizerText: words(5), cleanup: outcome(words(5)))
        await store.completeRecording(queued.id, transcription: words(5), cleanup: outcome(words(5)))
        await store.measureSpeechActivity(for: queued.id)
        let second = try await store.speakingSummary(since: .distantPast)

        XCTAssertEqual(first, second)
        XCTAssertEqual(detector.requestedURLs, [queued.url], "Measured once, from the audio in History")
        let source = try await store.dictationSource(for: queued.id)
        XCTAssertEqual(source?.speechDetector, "fixture")
    }

    /// A v12 database keeps every row and value; active speech stays unknown
    /// and nothing is measured on upgrade.
    func testMigrationFromV12KeepsDataAndLeavesActiveSpeechUnknown() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("speech-migration-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dictation = row(duration: 60)
        let legacy = row(duration: 10)
        do {
            let database = try DatabaseQueue(path: path)
            let store = try makeStore(database)
            try await store.addRecordingSync(dictation, source: evidence(for: dictation, activity: nil))
            try await store.addRecordingSync(legacy)
            try await database.write { db in
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN speechActivity")
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN activeSpeechSeconds")
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN speechDetector")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v13_add_speech_activity'")
            }
        }

        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 0, end: 5)])
        let store = try makeStore(try DatabaseQueue(path: path), detector: detector)
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(Set(rows.map(\.id)), [dictation.id, legacy.id])
        let source = try await store.dictationSource(for: dictation.id)
        XCTAssertNil(source?.speechActivity)
        XCTAssertNil(source?.activeSpeechSeconds)
        XCTAssertEqual(source?.recognizerText, words(120))
        XCTAssertEqual(source?.processingSeconds, 10, "Recorded timing is kept")

        await store.measureInterruptedSpeechActivity()
        await store.measureSpeechActivity(for: dictation.id)
        XCTAssertTrue(detector.requestedURLs.isEmpty, "Older History is never backfilled")

        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertTrue(summary.counted.isEmpty)
        XCTAssertEqual(summary.exclusions, [.speechNotMeasured: 1, .legacy: 1])
        XCTAssertEqual(SpeakingPresentation(summary: summary, typingWPM: 40).stripText, "This month: time saved counts from your next dictation")
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
            var indicatorSource = evidence(for: indicator, origin: nil, processing: nil, activity: nil)
            indicatorSource.recordingStartedAt = Date()
            try await store.addRecordingSync(indicator, source: indicatorSource)
            try await store.addRecordingSync(mainWindow, source: evidence(for: mainWindow, origin: nil, processing: nil, activity: nil))
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
        XCTAssertTrue(summary.counted.isEmpty)
        XCTAssertEqual(summary.exclusions, [.speechNotMeasured: 1, .legacy: 2])
    }

    func testInterruptedMeasurementFinishesWithoutTouchingOtherRows() async throws {
        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 0, end: 12)])
        let store = try makeStore(DatabaseQueue(), detector: detector)
        let interrupted = row()
        let unknown = row()
        let measured = row()
        try await store.addRecordingSync(interrupted, source: evidence(for: interrupted, activity: .measuring))
        let unknownEvidence = evidence(for: unknown, activity: nil)
        try await store.addRecordingSync(unknown, source: unknownEvidence)
        try await store.addRecordingSync(measured, source: evidence(for: measured, active: 20))
        _ = try audioInHistory(for: interrupted)
        _ = try audioInHistory(for: unknown)
        let unknownBefore = try await store.dictationSource(for: unknown.id)
        XCTAssertEqual(unknownBefore?.recognizerText, unknownEvidence.recognizerText)

        await store.measureInterruptedSpeechActivity()

        XCTAssertEqual(detector.requestedURLs, [interrupted.url])
        let interruptedActive = try await store.dictationSource(for: interrupted.id)?.activeSpeechSeconds
        let unknownSource = try await store.dictationSource(for: unknown.id)
        let measuredActive = try await store.dictationSource(for: measured.id)?.activeSpeechSeconds
        XCTAssertEqual(interruptedActive, 12)
        XCTAssertEqual(unknownSource, unknownBefore, "Legacy unknown evidence is untouched, though its audio is there")
        XCTAssertNil(unknownSource?.speechActivity)
        XCTAssertEqual(measuredActive, 20)
    }

    // A failed dictation is regenerated while its measurement is still
    // running: the measurement writes only its own result, never older copies
    // of the evidence over what the regeneration just saved.
    func testMeasurementNeverOverwritesARegenerationThatFinishedMeanwhile() async throws {
        let detector = GatedSpeechDetector()
        let store = try makeStore(DatabaseQueue(), detector: detector)
        var failed = row(status: .failed, duration: 2)
        failed.transcription = "Failed to transcribe: fixture"
        try await store.addRecordingSync(failed, source: DictationSource(
            recordingID: failed.id, recordingStartedAt: Date(), disposition: .pending,
            filter: .builtIn(.everyday), captureOrigin: .live, speechActivity: .measuring
        ))
        _ = try audioInHistory(for: failed)

        let measuring = Task { await store.measureSpeechActivity(for: failed.id) }
        for _ in 0..<500 where detector.started == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(detector.started, 1)
        await store.completeDictationSource(failed.id, recognizerText: words(20), cleanup: outcome(words(25)))
        await store.completeRecording(failed.id, transcription: words(25), cleanup: outcome(words(25)))
        let regenerated = try await store.dictationSource(for: failed.id)
        detector.release()
        await measuring.value

        var expected = try XCTUnwrap(regenerated)
        expected.speechActivity = .measured
        expected.activeSpeechSeconds = 1
        expected.speechDetector = "gated"
        let source = try await store.dictationSource(for: failed.id)
        XCTAssertEqual(source, expected)
        XCTAssertEqual(source?.recognizerText, words(20))
        XCTAssertEqual(source?.emittedText, words(25))
        let rows = try await store.fetchRecordings(limit: 1, offset: 0)
        XCTAssertEqual(rows.first?.transcription, words(25))
        XCTAssertEqual(rows.first?.status, .completed)
    }

    func testMissingAudioOrFailedDetectorIsUnavailableNeverRecordingLength() async throws {
        let store = try makeStore(DatabaseQueue(), detector: FixedSpeechDetector(error: SpeechDetectionError.detectorUnavailable))
        let noAudio = row(duration: 60)
        let failing = row(duration: 60)
        try await store.addRecordingSync(noAudio, source: evidence(for: noAudio, activity: .measuring))
        try await store.addRecordingSync(failing, source: evidence(for: failing, activity: .measuring))
        _ = try audioInHistory(for: failing)

        await store.measureSpeechActivity(for: noAudio.id)
        await store.measureSpeechActivity(for: failing.id)

        for id in [noAudio.id, failing.id] {
            let source = try await store.dictationSource(for: id)
            XCTAssertEqual(source?.speechActivity, .unavailable)
            XCTAssertNil(source?.activeSpeechSeconds)
        }
        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertTrue(summary.counted.isEmpty)
        XCTAssertEqual(summary.exclusions, [.speechUnavailable: 2])
        XCTAssertNil(SpeakingPresentation(summary: summary, typingWPM: 40).stripText)
    }

    // MARK: Production paths, with real WAVs and fake recognizers

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

    /// The repository's jfk.wav, copied as if just recorded.
    private func liveSpeech() throws -> URL {
        try FileManager.default.createDirectory(at: AudioRecorder.temporaryRecordingsDirectory, withIntermediateDirectories: true)
        let url = AudioRecorder.temporaryRecordingsDirectory.appendingPathComponent("speaking-jfk-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: Self.repoRoot.appendingPathComponent("jfk.wav"), to: url)
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

    /// Waits for the background measurement to settle.
    private func settledSource(_ store: RecordingStore, _ id: UUID, timeout: TimeInterval = 5) async throws -> DictationSource {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let source = try await store.dictationSource(for: id), source.speechActivity != .measuring {
                return source
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(nil as DictationSource?, "The measurement finished")
    }

    func testIndicatorDictationMeasuresActiveSpeechAfterSavingAndKeepsProcessingSeparate() async throws {
        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 0.25, end: 1.5)])
        let store = try makeStore(DatabaseQueue(), detector: detector)
        let gate = LatestDictationGate()
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(12))),
            recordingStore: store,
            cleanupPipeline: localPipeline(),
            delivery: { _ in .pasteSent }
        )
        defer { viewModel.cleanup() }
        let stoppedAt = ContinuousClock.now

        await viewModel.finishDictation(audioAt: try liveAudio(seconds: 2), generation: gate.begin(), recordingStartedAt: Date(), stoppedAt: stoppedAt)

        let row = try await newestRow(store)
        let source = try await settledSource(store, row.id)
        XCTAssertEqual(source.captureOrigin, .live)
        XCTAssertEqual(source.speechActivity, .measured)
        XCTAssertEqual(try XCTUnwrap(source.activeSpeechSeconds), 1.25, accuracy: 1e-9)
        XCTAssertNotNil(source.processingSeconds, "The wait for text is still recorded")
        XCTAssertEqual(detector.requestedURLs, [row.url], "Measured from the saved History audio")

        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(summary.counted.count, 1)
        XCTAssertEqual(summary.counted.recordingSeconds, 2, accuracy: 0.05)
        // 12 words at 40 WPM = 18 s of typing − 1.25 s of active speech; no processing.
        XCTAssertEqual(summary.counted.savedSeconds(atWPM: 40), 18 - 1.25, accuracy: 1e-9)
    }

    func testIndicatorDeliveryAndSaveNeverWaitForTheMeasurement() async throws {
        let detector = GatedSpeechDetector()
        let store = try makeStore(DatabaseQueue(), detector: detector)
        let gate = LatestDictationGate()
        var delivered: [String] = []
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(12))),
            recordingStore: store,
            cleanupPipeline: localPipeline(),
            delivery: { delivered.append($0); return .pasteSent }
        )
        defer { viewModel.cleanup() }

        await viewModel.finishDictation(audioAt: try liveAudio(seconds: 1), generation: gate.begin(), recordingStartedAt: Date(), stoppedAt: .now)

        XCTAssertEqual(delivered, [words(12)], "Delivered while the detector is still held")
        let row = try await newestRow(store)
        let waiting = try await store.dictationSource(for: row.id)
        XCTAssertEqual(waiting?.speechActivity, .measuring)
        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(summary.exclusions, [.measuringSpeech: 1])

        detector.release()
        let settled = try await settledSource(store, row.id)
        XCTAssertEqual(settled.activeSpeechSeconds, 1)
    }

    // The bundled detector through the real indicator path, on jfk.wav.
    func testIndicatorDictationOfRealSpeechMeasuresItWithTheBundledDetector() async throws {
        let store = try makeStore(DatabaseQueue(), detector: SileroSpeechDetector())
        let gate = LatestDictationGate()
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(22))),
            recordingStore: store,
            cleanupPipeline: localPipeline(),
            delivery: { _ in .pasteSent }
        )
        defer { viewModel.cleanup() }

        await viewModel.finishDictation(audioAt: try liveSpeech(), generation: gate.begin(), recordingStartedAt: Date(), stoppedAt: .now)

        let row = try await newestRow(store)
        let source = try await settledSource(store, row.id, timeout: 60)
        XCTAssertEqual(source.speechActivity, .measured)
        XCTAssertEqual(try XCTUnwrap(source.activeSpeechSeconds), 7.44, accuracy: 0.3)
        XCTAssertEqual(source.speechDetector, "silero-v5.1.2/whisper.cpp-default")
        XCTAssertEqual(row.duration, 11, accuracy: 0.05)
        XCTAssertEqual(row.transcription, words(22), "Measuring never changes the transcript")
    }

    // Cleanup expands 8 heard words to 80 produced words, as Homework can.
    // The estimate types the 8 heard words: 12 s against 4 s of active
    // speech, 0.1 min saved and 3.0× faster, and regenerating with a new
    // expansion changes neither. By produced words it would claim 30×.
    func testCleanupExpansionAndRegenerationNeverInflateTheEstimateEndToEnd() async throws {
        let heard = "please keep the project notes short and clear"
        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 0, end: 4)])
        let store = try makeStore(DatabaseQueue(), detector: detector)
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { ExpandingCleanup(times: 10) },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.homework) },
            autoConfigProvider: { nil },
            failureRecorder: { _ in }
        )
        let gate = LatestDictationGate()
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(heard)),
            recordingStore: store,
            cleanupPipeline: pipeline,
            delivery: { _ in .pasteSent }
        )
        defer { viewModel.cleanup() }

        await viewModel.finishDictation(audioAt: try liveAudio(seconds: 6), generation: gate.begin(), recordingStartedAt: Date(), stoppedAt: .now)

        let dictated = try await newestRow(store)
        let source = try await settledSource(store, dictated.id)
        XCTAssertEqual(source.cleanupSource, .ollama, "The expanded cleanup was accepted")
        XCTAssertEqual(SpeakingEfficiency.wordCount(source.recognizerText ?? ""), 8)
        XCTAssertEqual(SpeakingEfficiency.wordCount(source.emittedText ?? ""), 80)
        let first = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(first.counted.spokenWords, 8)
        XCTAssertEqual(first.counted.producedWords, 80)
        XCTAssertEqual(first.counted.savedSeconds(atWPM: 40), 12 - 4, accuracy: 1e-9)
        XCTAssertEqual(SpeakingPresentation(summary: first, typingWPM: 40).stripText, "This month: ≈0.1 min saved · 3.0× faster")

        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: FixedWordsEngine("now keep every single project note much longer than before")),
            recordingStore: store,
            cleanupPipeline: pipeline
        )
        await queue.requeueRecording(dictated)
        let regenerated = try await newestRow(store) { $0.status == .completed && !$0.isRegeneration && !queue.isProcessing }
        XCTAssertEqual(SpeakingEfficiency.wordCount(regenerated.transcription), 100, "The final text is the regenerated expansion")
        let second = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(second, first, "Regenerating changes neither the counts nor the figures")
        XCTAssertEqual(detector.requestedURLs.count, 1)
    }

    func testMainWindowDictationMeasuresActiveSpeech() async throws {
        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 0, end: 0.75)])
        let store = try makeStore(DatabaseQueue(), detector: detector)
        let model = ContentViewModel()
        model.recordingStore = store
        model.transcriptionService = TranscriptionService(engine: FixedWordsEngine(words(30)))
        model.cleanupPipeline = localPipeline()

        await model.finishRecording(audioAt: try liveAudio(seconds: 1), stoppedAt: .now)

        let row = try await newestRow(store)
        let source = try await settledSource(store, row.id)
        XCTAssertEqual(source.captureOrigin, .live)
        XCTAssertNotNil(source.processingSeconds)
        XCTAssertEqual(source.activeSpeechSeconds, 0.75)
        let measuredRow = try await store.fetchRecordings(limit: 1, offset: 0).first
        XCTAssertEqual(measuredRow?.speaking?.sample?.spokenWords, 30)
    }

    func testQueueMeasuresLiveQueuedDictationsFromHistoryAndNeverImports() async throws {
        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 0, end: 0.5)])
        let store = try makeStore(DatabaseQueue(), detector: detector)
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(40))),
            recordingStore: store,
            cleanupPipeline: localPipeline()
        )
        let imported = FileManager.default.temporaryDirectory.appendingPathComponent("speaking-import-\(UUID()).wav")
        try writeSilentWAV(to: imported, seconds: 1)
        cleanupURLs.append(imported)

        await queue.addFileToQueue(url: imported)
        let importedRow = try await newestRow(store) { !$0.isPending && !queue.isProcessing }
        await queue.addFileToQueue(url: try liveAudio(seconds: 1), captureOrigin: .live)
        let liveRow = try await newestRow(store) { !$0.isPending && !queue.isProcessing }

        let liveSource = try await settledSource(store, liveRow.id)
        XCTAssertEqual(liveSource.activeSpeechSeconds, 0.5)
        XCTAssertNil(liveSource.processingSeconds, "Time waiting in the queue is never claimed as processing")
        let importedSource = try await store.dictationSource(for: importedRow.id)
        XCTAssertNil(importedSource?.speechActivity)
        XCTAssertEqual(detector.requestedURLs, [liveRow.url], "Only the live dictation, from its History audio")

        let summary = try await store.speakingSummary(since: .distantPast)
        XCTAssertEqual(summary.exclusions, [.imported: 1])
        XCTAssertEqual(summary.counted.count, 1)
        XCTAssertEqual(summary.counted.spokenWords, 40)
    }

    func testFailedDictationIsMeasuredOnceAndRegenerationKeepsIt() async throws {
        let detector = FixedSpeechDetector(intervals: [SpeechInterval(start: 0, end: 1.5)])
        let store = try makeStore(DatabaseQueue(), detector: detector)
        let saved = await store.addFailedDictation(
            audioAt: try liveAudio(seconds: 2),
            error: TranscriptionError.processingFailed,
            duration: 2,
            selectedFilter: .builtIn(.everyday),
            cleanupRequested: false,
            targetBundleID: nil,
            recordingStartedAt: Date(),
            keepAudio: AudioRecorder.shared.keepTemporaryRecording
        )
        XCTAssertTrue(saved)
        let failed = try await newestRow(store) { $0.status == .failed }
        let measured = try await settledSource(store, failed.id)
        XCTAssertEqual(measured.activeSpeechSeconds, 1.5)

        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: FixedWordsEngine(words(9))),
            recordingStore: store,
            cleanupPipeline: localPipeline()
        )
        await queue.requeueRecording(failed)
        let regenerated = try await newestRow(store) { $0.status == .completed && !queue.isProcessing }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(detector.requestedURLs.count, 1, "Regenerate never measures again")
        XCTAssertEqual(regenerated.speaking?.sample?.activeSpeechSeconds, 1.5)
        XCTAssertEqual(regenerated.speaking?.sample?.spokenWords, 9)
    }

    func testMainWindowSummaryLoadsFromTheStore() async throws {
        let store = try makeStore(DatabaseQueue())
        let counted = row(duration: 60)
        try await store.addRecordingSync(counted, source: evidence(for: counted, active: 45))
        let model = ContentViewModel(recordingStore: store)

        await model.refreshSpeakingSummary().value

        XCTAssertEqual(
            SpeakingPresentation(summary: model.speakingSummary, typingWPM: 40).stripText,
            "This month: ≈2.3 min saved · 4.0× faster"
        )
    }

    // The same 50 words spoken twice, once with a 32 s longer silent pause,
    // measured by the bundled detector, give the same figures: 75 s of typing
    // against about 15 s of active speech either way. By recording length
    // the pause alone would have cost 32 s.
    func testLongIdleBetweenIdenticalSpeechGivesTheSameFiguresEndToEnd() async throws {
        let store = try makeStore(DatabaseQueue(), detector: SileroSpeechDetector())
        let converted = try await WhisperEngine().convertAudioToPCM(fileURL: Self.repoRoot.appendingPathComponent("jfk.wav"))
        let speech = try XCTUnwrap(converted)
        var ids: [UUID] = []
        for gap in [2.0, 34.0] {
            let samples = speech + [Float](repeating: 0, count: Int(gap * 16_000)) + speech
            var recording = row(duration: Double(samples.count) / 16_000)
            recording.transcription = words(50)
            try FileManager.default.createDirectory(at: Recording.recordingsDirectory, withIntermediateDirectories: true)
            try writeWAV(samples, to: recording.url)
            cleanupURLs.append(recording.url)
            try await store.addRecordingSync(recording, source: evidence(for: recording, spoken: words(50), produced: words(50), activity: .measuring))
            await store.measureSpeechActivity(for: recording.id)
            ids.append(recording.id)
        }

        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let samples = try ids.map { id in try XCTUnwrap(rows.first { $0.id == id }?.speaking?.sample) }
        XCTAssertEqual(samples[1].recordingSeconds - samples[0].recordingSeconds, 32, accuracy: 0.01)
        XCTAssertEqual(samples[0].activeSpeechSeconds, samples[1].activeSpeechSeconds, accuracy: 0.1)
        let saved = samples.map { SpeakingTotals($0).savedSeconds(atWPM: 40) }
        XCTAssertEqual(saved[0], saved[1], accuracy: 0.1)
        let figures = samples.map { SpeakingFormat.headline(SpeakingTotals($0), typingWPM: 40) }
        XCTAssertEqual(figures[0], "≈1.0 min saved · 5.0× faster")
        XCTAssertEqual(figures[0], figures[1])
    }
}

/// Returns the transcript repeated as sentences: longer output with no new
/// words, the way Homework cleanup can write more than was said.
private final class ExpandingCleanup: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .ollama
    let times: Int

    init(times: Int) { self.times = times }

    func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
        let sentence = transcript.prefix(1).uppercased() + transcript.dropFirst() + "."
        let text = Array(repeating: sentence, count: times).joined(separator: " ")
        return CleanupProviderResult(text: text, inputTokens: 10, outputTokens: 100, modelID: "fixture-expansion")
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
    try writeWAV([Float](repeating: 0, count: Int(seconds * sampleRate)), to: url, sampleRate: sampleRate)
}

/// Writes mono float samples as a WAV file.
func writeWAV(_ samples: [Float], to url: URL, sampleRate: Double = 16_000) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    // AVAudioFile writes its header on deinit, so the file is closed before use.
    try {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }()
}
