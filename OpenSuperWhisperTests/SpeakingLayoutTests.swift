import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Renders the speaking-versus-typing surfaces offscreen with synthetic
/// totals: the Settings group, the main window's summary line, and History
/// badges. Attachments are safe to share for visual review.
@MainActor
final class SpeakingLayoutTests: XCTestCase {
    private var originalWPM: Any?

    override func setUp() {
        super.setUp()
        originalWPM = UserDefaults.standard.object(forKey: SpeakingEfficiency.typingWPMKey)
        UserDefaults.standard.removeObject(forKey: SpeakingEfficiency.typingWPMKey)
    }

    override func tearDown() {
        if let originalWPM {
            UserDefaults.standard.set(originalWPM, forKey: SpeakingEfficiency.typingWPMKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SpeakingEfficiency.typingWPMKey)
        }
        super.tearDown()
    }

    /// Twelve measured dictations and three older ones without processing time.
    private func fixtureStore() async throws -> RecordingStore {
        let store = try RecordingStore(
            database: DatabaseQueue(),
            recordingsDirectory: FileManager.default.temporaryDirectory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in }
        )
        func add(seconds: TimeInterval, spoken: Int, produced: Int, processing: TimeInterval?, mode: RecordingMode = .dictation) async throws {
            let id = UUID()
            let recording = Recording(
                id: id, timestamp: Date(), fileName: "\(id).wav", transcription: "synthetic",
                duration: seconds, status: .completed, progress: 1, mode: mode
            )
            let text = { (count: Int) in (0..<count).map { _ in "word" }.joined(separator: " ") }
            try await store.addRecordingSync(recording, source: DictationSource(
                recordingID: id, recognizerText: text(spoken), emittedText: text(produced),
                disposition: .pasteSent, filter: .builtIn(.everyday),
                captureOrigin: .live, processingSeconds: processing
            ))
        }
        for index in 0..<12 {
            try await add(seconds: 20 + Double(index), spoken: 52 + index, produced: 48 + index, processing: 1.2)
        }
        for _ in 0..<3 { try await add(seconds: 15, spoken: 36, produced: 34, processing: nil) }
        try await store.addRecordingSync(Recording(
            id: UUID(), timestamp: Date(), fileName: "meeting.wav", transcription: "synthetic",
            duration: 600, status: .completed, progress: 1, mode: .meeting
        ))
        return store
    }

    @discardableResult
    private func render<Content: View>(_ view: Content, size: CGSize, scheme: ColorScheme, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "\(name)-\(scheme == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(window.isVisible, "Visual verification must stay offscreen")
        return bitmap
    }

    func testSettingsGroupAndMainWindowSummaryRenderInBothThemes() async throws {
        let store = try await fixtureStore()
        let model = SettingsViewModel(credentials: StoredCredentialStatus(bedrock: { false }, cleanup: { _ in false }))
        await model.refreshSpeakingSummary(store: store)
        XCTAssertEqual(model.speakingSummary.measured.count, 12)
        XCTAssertEqual(model.speakingSummary.recordingOnly.count, 3)
        XCTAssertEqual(model.speakingSummary.exclusions, [.meeting: 1])

        for scheme in [ColorScheme.light, .dark] {
            for width in [460.0, 620.0] {
                try render(
                    ScrollView { SpeakingSettingsGroup(viewModel: model).padding(20) }
                        .background(ThemePalette.windowBackground(scheme)),
                    size: CGSize(width: width, height: 560), scheme: scheme, name: "speaking-settings-\(Int(width))"
                )
                try render(
                    VStack(spacing: 0) {
                        SpeakingSummaryStrip(presentation: SpeakingPresentation(summary: model.speakingSummary, typingWPM: 40)) {}
                        Spacer()
                    }
                    .background(ThemePalette.contentBackground(scheme)),
                    size: CGSize(width: width, height: 44), scheme: scheme, name: "speaking-strip-\(Int(width))"
                )
            }
        }
    }

    func testAssumedTypingSpeedWritesThroughAndIsClamped() {
        let model = SettingsViewModel(credentials: StoredCredentialStatus(bedrock: { false }, cleanup: { _ in false }))
        XCTAssertEqual(model.typingBaselineWPM, 40, "The assumption defaults to 40 WPM")
        model.typingBaselineWPM = 65
        XCTAssertEqual(AppPreferences.shared.typingBaselineWPM, 65)
        model.typingBaselineWPM = 2
        XCTAssertEqual(model.typingBaselineWPM, 10)
        XCTAssertEqual(AppPreferences.shared.typingBaselineWPM, 10)
    }

    func testHistoryBadgesReadTimeAndPaceNeverTokens() {
        func badge(_ speaking: SpeakingEligibility?) -> HistoryRow {
            HistoryRow(
                recording: Recording(
                    id: UUID(), timestamp: Date(), fileName: "badge.wav", transcription: "synthetic",
                    duration: 60, status: .completed, progress: 1, cleanupSource: .disabled,
                    cleanupMode: .technical, rawTokenEstimate: 90, finalTokenEstimate: 30,
                    tokenEstimatorID: LocalTokenEstimator.identifier, speaking: speaking
                ),
                searchQuery: "", isPlaying: false, onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {}
            )
        }
        let measured = badge(.eligible(SpeakingSample(recordingSeconds: 60, spokenWords: 120, producedWords: 120, processingSeconds: 10)))
        XCTAssertEqual(measured.speakingBadgeLabel, "≈1m 50s saved")
        XCTAssertTrue(measured.speakingBadgeHelp.contains("assumed 40 WPM"))
        let unmeasured = badge(.eligible(SpeakingSample(recordingSeconds: 60, spokenWords: 120, producedWords: 120, processingSeconds: nil)))
        XCTAssertEqual(unmeasured.speakingBadgeLabel, "120 WPM spoken")
        let slower = badge(.eligible(SpeakingSample(recordingSeconds: 30, spokenWords: 10, producedWords: 10, processingSeconds: 5)))
        XCTAssertEqual(slower.speakingBadgeLabel, "≈20s slower than typing")
        XCTAssertNil(badge(.excluded(.legacy)).speakingBadgeLabel, "A row with token estimates but no capture evidence shows no productivity badge")
        XCTAssertNil(badge(nil).speakingBadgeLabel)
        var regenerating = measured.recording
        regenerating.status = .transcribing
        XCTAssertNil(HistoryRow(recording: regenerating, searchQuery: "", isPlaying: false,
                                onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {}).speakingBadgeLabel)
    }
}
