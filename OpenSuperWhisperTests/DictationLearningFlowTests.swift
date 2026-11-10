import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

// One synthetic dictation followed end to end through the shipped code: the
// recognizer's words, cleanup, delivery, History with its original evidence,
// the finished document matched back to that dictation, the learned mode
// preference, and the next dictation's cleanup using it. The recognizer,
// cleanup model, and learning classifier are deterministic fakes that follow
// rules mechanically, so this proves the plumbing, not how a real provider
// behaves. Nothing reaches a microphone, model, provider, pasteboard, the
// user's preferences, or the user's History.

/// Returns the words "spoken" into each synthetic audio file.
private final class SpokenWordsEngine: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Spoken words fixture"
    var spoken: [URL: String] = [:]

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}
    func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String {
        spoken[url] ?? ""
    }
}

/// A stand-in cleanup model: drops "um" and "uh", capitalizes, ends the
/// sentence, and follows learned spellings that reach its prompt. The real
/// guard validates its output, as the shipped providers do.
private final class StyleFollowingCleanup: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .ollama
    private(set) var prompts: [String] = []

    func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
        prompts.append(systemPrompt)
        var text = transcript.split(separator: " ").filter { !["um", "uh"].contains($0.lowercased()) }.joined(separator: " ")
        let spelling = try NSRegularExpression(pattern: #"Write “([^”]+)” as “([^”]+)”\."#)
        for match in spelling.matches(in: systemPrompt, range: NSRange(systemPrompt.startIndex..., in: systemPrompt)) {
            guard let from = Range(match.range(at: 1), in: systemPrompt),
                  let to = Range(match.range(at: 2), in: systemPrompt) else { continue }
            text = text.replacingOccurrences(of: systemPrompt[from], with: systemPrompt[to], options: .caseInsensitive)
        }
        text = text.prefix(1).uppercased() + text.dropFirst()
        if let last = text.last, !".!?".contains(last) { text += "." }
        let cleaned = try CleanupGuard.postprocess(
            text, source: transcript, mode: filter.mode, allowsNumberFormatting: filter.allowsNumberFormatting
        )
        return CleanupProviderResult(text: cleaned, inputTokens: 12, outputTokens: 12, modelID: "fixture-cleanup")
    }
}

/// A stand-in learning classifier: reads the edits it is sent and names a
/// spelling preference wherever the person only closed up a space.
private final class EditReadingClassifier: CleanupChatCompleting {
    let providerID: CleanupProviderID = .ollama
    private(set) var requests: [ProviderChatRequest] = []

    func complete(_ request: ProviderChatRequest) async throws -> CleanupProviderResult {
        requests.append(request)
        let line = try NSRegularExpression(pattern: #"^(\d+) \[\w+\] ….*«(.*)» → «(.*)»"#, options: [.anchorsMatchLines])
        let message = request.messages.last?.content ?? ""
        var preferences: [String] = []
        for match in line.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
            let value = { (index: Int) in String(message[Range(match.range(at: index), in: message)!]) }
            let (number, before, after) = (value(1), value(2), value(3))
            if before != after, before.replacingOccurrences(of: " ", with: "") == after {
                preferences.append(#"{"kind": "spelling", "edits": [\#(number)], "from": "\#(before)", "to": "\#(after)"}"#)
            }
        }
        return CleanupProviderResult(
            text: #"{"preferences": [\#(preferences.joined(separator: ", "))]}"#,
            inputTokens: 40, outputTokens: 20, modelID: "fixture-classifier"
        )
    }
}

@MainActor
private final class DeliveredText {
    var texts: [String] = []
}

@MainActor
final class DictationLearningFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var audioDirectory: URL!
    private var savedAudio: [URL] = []

    override func setUpWithError() throws {
        suite = "DictationLearningFlowTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        audioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: audioDirectory)
        for url in savedAudio { try? FileManager.default.removeItem(at: url) }
    }

    func testDictationToFinishedDocumentToLearnedModeToNextCleanup() async throws {
        let store = try RecordingStore(
            database: DatabaseQueue(),
            recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in }
        )
        let engine = SpokenWordsEngine()
        let cleanup = StyleFollowingCleanup()
        let delivered = DeliveredText()
        let gate = LatestDictationGate()
        let defaults = defaults!
        CustomCleanupFilterStore.select(.builtIn(.writing), in: defaults)
        let viewModel = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: engine),
            recordingStore: store,
            cleanupPipeline: TranscriptCleanupPipeline(
                isEnabled: { true },
                providerResolver: { cleanup },
                vocabularyProvider: { [] },
                appRuleProvider: { _ in nil },
                bedrockBudgetProvider: { nil },
                filterProvider: { CustomCleanupFilterStore.currentSnapshot(in: defaults) },
                failureRecorder: { _ in }
            ),
            delivery: { delivered.texts.append($0); return .pasteSent }
        )
        defer { viewModel.cleanup() }

        func dictate(_ words: String) async throws -> (Recording, DictationSource) {
            let audio = audioDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            try Data("synthetic audio".utf8).write(to: audio)
            engine.spoken[audio] = words
            let before = try await store.fetchRecordings(limit: 50, offset: 0).count
            await viewModel.finishDictation(audioAt: audio, generation: gate.begin(), recordingStartedAt: Date())
            var rows: [Recording] = []
            for _ in 0..<200 {
                rows = try await store.fetchRecordings(limit: 50, offset: 0)
                if rows.count > before { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let row = try XCTUnwrap(rows.first { row in !savedAudio.contains(row.url) }, "History saved the dictation")
            savedAudio.append(row.url)
            let evidence = try await store.dictationSource(for: row.id)
            return (row, try XCTUnwrap(evidence))
        }

        // 1. Original speech → Writing cleanup → pasted and kept in History with its evidence.
        let firstSpoken = "um I kept a note book of every route and I wrote down the distance and how my legs felt afterwards"
        let (first, firstSource) = try await dictate(firstSpoken)
        let firstText = "I kept a note book of every route and I wrote down the distance and how my legs felt afterwards."
        XCTAssertEqual(first.transcription, firstText)
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(first.cleanupMode, .writing)
        XCTAssertEqual(first.cleanupSource, .ollama)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path), "The audio moved into History")
        XCTAssertEqual(delivered.texts, [firstText])
        XCTAssertEqual(firstSource.recognizerText, firstSpoken)
        XCTAssertEqual(firstSource.emittedText, firstText)
        XCTAssertEqual(firstSource.insertedText, IndicatorViewModel.applyPostProcessing(firstText))
        XCTAssertEqual(firstSource.disposition, .pasteSent)
        XCTAssertEqual(firstSource.selectedMode, .writing)
        XCTAssertEqual(firstSource.learnedPreferences, [])
        XCTAssertFalse(try XCTUnwrap(cleanup.prompts.last).contains("Write “note book” as “notebook”."))

        // 2. The finished document closes up "note book"; the rest was typed, not dictated.
        let classifier = EditReadingClassifier()
        let session = CorrectionLearningSession(
            mode: .writing,
            destination: CleanupProviderDestination(providerID: .ollama, model: "fixture", isOnThisMac: true),
            chatResolver: { classifier },
            budgetProvider: { nil },
            candidateProvider: { try await store.learningCandidates() },
            defaults: defaults
        )
        session.document = """
        Running notes

        I kept a notebook of every route and I wrote down the distance and how my legs felt afterwards.

        This closing paragraph was typed, not dictated, and is never sent anywhere.
        """
        session.learn()
        for _ in 0..<400 where session.isLearning { try await Task.sleep(nanoseconds: 5_000_000) }
        let report = try XCTUnwrap(session.report, session.errorMessage ?? "no report")

        // 3. The edit matched back to the dictation becomes a Writing preference.
        XCTAssertEqual(report.status, .learned)
        XCTAssertEqual(report.matchedDictations, 1)
        XCTAssertEqual(classifier.requests.count, 1)
        let sent = try XCTUnwrap(classifier.requests.first?.messages.last?.content)
        XCTAssertTrue(sent.contains("«note book» → «notebook»"), sent)
        XCTAssertFalse(sent.contains("typed, not dictated"), "Unmatched document text is never sent")
        XCTAssertFalse(sent.contains("Running notes"))
        let learned = LearnedPreferenceStore.preferences(for: .writing, in: defaults)
        XCTAssertEqual(learned.map(\.kind), [.spelling])
        XCTAssertEqual(learned.first?.instruction, "Write “note book” as “notebook”.")
        XCTAssertEqual(learned.first?.origin, .recognition, "Cleanup kept the recognizer's words")
        XCTAssertEqual(LearnedPreferenceStore.preferences(for: .technical, in: defaults), [])

        // 4. The next Writing dictation is cleaned with the learned preference.
        let nextSpoken = "um I bought another note book for the trail and it fits in my jacket pocket"
        let (next, nextSource) = try await dictate(nextSpoken)
        let nextText = "I bought another notebook for the trail and it fits in my jacket pocket."
        XCTAssertTrue(try XCTUnwrap(cleanup.prompts.last).contains("Write “note book” as “notebook”."))
        XCTAssertEqual(next.transcription, nextText)
        XCTAssertEqual(delivered.texts.last, nextText)
        XCTAssertEqual(nextSource.recognizerText, nextSpoken)
        XCTAssertEqual(nextSource.learnedPreferences.map(\.kind), [.spelling], "The dictation records what shaped it")

        // Controls: another mode, or learning switched off, leaves the words as spoken.
        CustomCleanupFilterStore.select(.builtIn(.technical), in: defaults)
        let (technical, _) = try await dictate(nextSpoken)
        XCTAssertTrue(technical.transcription.contains("note book"), technical.transcription)
        CustomCleanupFilterStore.select(.builtIn(.writing), in: defaults)
        LearnedPreferenceStore.setLearningEnabled(false, in: defaults)
        let (off, offSource) = try await dictate(nextSpoken)
        XCTAssertTrue(off.transcription.contains("note book"), off.transcription)
        XCTAssertEqual(offSource.learnedPreferences, [])
        LearnedPreferenceStore.setLearningEnabled(true, in: defaults)

        print("FLOW_TRACE original=\(firstSpoken)")
        print("FLOW_TRACE cleanup=\(firstText) disposition=\(firstSource.disposition.rawValue)")
        print("FLOW_TRACE learned=\(learned.map(\.instruction)) origin=\(learned.first?.origin.label ?? "")")
        print("FLOW_TRACE next=\(next.transcription) technical=\(technical.transcription) off=\(off.transcription)")

        // The same flow in the shipped UI: History, the learning card, and the dock's way back to it.
        for scheme in [ColorScheme.light, .dark] {
            try render(AnyView(VStack(spacing: WFSpace.md) {
                ForEach([next, first]) { recording in
                    HistoryRow(recording: recording, searchQuery: "", isPlaying: false,
                                  onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {})
                }
                DictationDock(status: .ready, shortcut: "fn", writingSelection: .constant(.builtIn(.writing)),
                              onLearn: {}, onRecord: {})
            }
            .padding(.top, WFSpace.lg)
            .background(ThemePalette.windowBackground(scheme))), name: "flow-history-and-dock", width: 560, scheme: scheme)
            try render(AnyView(CorrectionLearningCard(session: session, defaults: defaults)
                .padding()
                .background(Color(.windowBackgroundColor))), name: "flow-learning-card", width: 600, scheme: scheme)
        }
    }

    private func render(_ view: AnyView, name: String, width: CGFloat, scheme: ColorScheme) throws {
        let content = view
            .frame(width: width)
            .tint(ThemePalette.controlTint)
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name)-\(scheme == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(window.isVisible, "Visual verification must stay offscreen")
    }
}
