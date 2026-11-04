import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

// Regressions for finished-document preference learning: what may become a
// rule, which mode or filter it teaches, how it is undone, what Check matches
// shows without sending, and a train/held-out split. Every fixture is
// synthetic. Scripted providers prove plumbing and the deterministic guards,
// not how a real model responds.

private func makeSuite(_ name: String = #function) throws -> (UserDefaults, String) {
    let suite = "PreferenceLearningTests-\(name)-\(UUID().uuidString)"
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
}

@MainActor
private func makeHistory(_ database: DatabaseQueue? = nil) throws -> RecordingStore {
    try RecordingStore(
        database: try database ?? DatabaseQueue(),
        recordingsDirectory: Recording.recordingsDirectory,
        cancelQueuedRecording: { _ in },
        stopPlayback: { _ in }
    )
}

private func preference(
    _ kind: LearnedPreference.Kind, mode: CleanupMode = .everyday, from: String? = nil, to: String? = nil,
    filterID: UUID? = nil, sources: [UUID] = [], evidence: [String] = ["e"]
) -> LearnedPreference {
    LearnedPreference(
        mode: mode, kind: kind, from: from, to: to, origin: .finalEdit, evidence: evidence, fromLegacyOnly: false,
        learnedAt: Date(), updatedAt: Date(), filterID: filterID, sourceRecordingIDs: sources
    )
}

/// Replies with a fixed JSON body and records what it was sent.
private final class FixedClassifier: CleanupChatCompleting {
    let providerID: CleanupProviderID = .ollama
    var reply: String
    private(set) var requests: [ProviderChatRequest] = []
    init(_ reply: String = #"{"preferences": []}"#) { self.reply = reply }

    func complete(_ request: ProviderChatRequest) async throws -> CleanupProviderResult {
        requests.append(request)
        return CleanupProviderResult(text: reply, inputTokens: 5, outputTokens: 5, modelID: "fixed")
    }

    var sentLines: [String] {
        requests.flatMap { $0.messages.last?.content.split(separator: "\n").filter { $0.first?.isNumber == true }.map(String.init) ?? [] }
    }
}

/// A worst-case classifier: proposes every kind it can read into each edit,
/// so only local validation stands between an edit and a rule.
private final class EagerClassifier: CleanupChatCompleting {
    let providerID: CleanupProviderID = .ollama
    private(set) var requests: [ProviderChatRequest] = []

    func complete(_ request: ProviderChatRequest) async throws -> CleanupProviderResult {
        requests.append(request)
        let line = try NSRegularExpression(pattern: #"^(\d+) \[\w+\] ….*«(.*)» → «(.*)»"#, options: [.anchorsMatchLines])
        let message = request.messages.last?.content ?? ""
        var proposals: [String] = []
        for match in line.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
            let value = { (index: Int) in String(message[Range(match.range(at: index), in: message)!]) }
            let (number, before, after) = (value(1), value(2), value(3))
            let deleted = before.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).lowercased()
            if after.trimmingCharacters(in: .whitespaces).isEmpty, !deleted.isEmpty {
                proposals.append(#"{"kind": "remove_filler", "edits": [\#(number)], "word": "\#(deleted)"}"#)
            }
            if !before.isEmpty, !after.isEmpty {
                proposals.append(#"{"kind": "spelling", "edits": [\#(number)], "from": "\#(before)", "to": "\#(after)"}"#)
                proposals.append(#"{"kind": "digits", "edits": [\#(number)]}"#)
            }
        }
        return CleanupProviderResult(
            text: #"{"preferences": [\#(proposals.joined(separator: ", "))]}"#, inputTokens: 40, outputTokens: 30, modelID: "eager"
        )
    }
}

/// A cleanup stand-in that applies learned spellings and filler removals
/// literally (the worst case for over-application), can ignore its prompt
/// entirely, and can inject one violation; the real guard checks it all.
final class LiteralCleanup: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .ollama
    var readsPrompt = true
    var inject: ((String) -> String)?
    private(set) var prompts: [String] = []

    func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
        prompts.append(systemPrompt)
        var text = transcript
        if readsPrompt {
            for (from, to) in Self.matches(#"Write “([^”]+)” as “([^”]+)”\."#, in: systemPrompt) {
                text = text.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: from))\\b", with: to, options: [.regularExpression, .caseInsensitive])
            }
            for (word, _) in Self.matches(#"Remove the filler word “([^”]+)”\.()"#, in: systemPrompt) {
                text = text.replacingOccurrences(of: "\\b\(word)\\b ?", with: "", options: [.regularExpression, .caseInsensitive])
            }
        }
        if let inject { text = inject(text) }
        text = text.prefix(1).uppercased() + text.dropFirst()
        if let last = text.last, !".!?".contains(last) { text += "." }
        let cleaned = try CleanupGuard.postprocess(text, source: transcript, mode: filter.mode, allowsNumberFormatting: filter.allowsNumberFormatting)
        return CleanupProviderResult(text: cleaned, inputTokens: 1, outputTokens: 1, modelID: "literal")
    }

    private static func matches(_ pattern: String, in text: String) -> [(String, String)] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (String(text[Range($0.range(at: 1), in: text)!]), String(text[Range($0.range(at: 2), in: text)!]))
        }
    }
}

private final class FixedWords: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Fixed words"
    var words = ""
    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}
    func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String { words }
}

/// A deterministic generator, so scale fixtures are identical on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Shared fixtures; it declares no tests of its own.
@MainActor
class PreferenceLearningTestCase: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var history: RecordingStore!
    var vocabulary: [VocabularyEntry] = []

    override func setUp() async throws {
        (defaults, suite) = try makeSuite("\(type(of: self))-\(name)")
        history = try makeHistory()
        vocabulary = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Saves one dictation with its evidence, as the hotkey path does.
    @discardableResult
    func dictation(_ spoken: String, emitted: String, filter: CleanupFilterSnapshot = .builtIn(.everyday), at seconds: Double = 1_000) async throws -> UUID {
        let id = UUID()
        let outcome = TranscriptCleanupOutcome(
            text: emitted, source: .ollama, inputTokens: 1, outputTokens: 1, modelID: "m", filter: filter,
            rawTokenEstimate: 1, finalTokenEstimate: 1, tokenEstimatorID: LocalTokenEstimator.identifier, cleanupInput: spoken
        )
        try await history.addRecordingSync(
            Recording(id: id, timestamp: Date(timeIntervalSince1970: seconds), fileName: "\(id).wav", transcription: emitted,
                      duration: 1, status: .completed, progress: 1, cleanupSource: .ollama, cleanupRequested: true,
                      cleanupMode: filter.mode, cleanupFilterName: filter.customName),
            source: DictationSource(recordingID: id, recognizerText: spoken, cleanup: outcome, fallbackFilter: filter,
                                    disposition: .pasteSent, insertedText: emitted)
        )
        return id
    }

    func session(
        _ chat: any CleanupChatCompleting, mode: CleanupMode = .everyday, retention: Int? = nil,
        vocabularyAdder: ((VocabularyEntry) -> Bool)? = nil
    ) -> CorrectionLearningSession {
        let history = history!
        return CorrectionLearningSession(
            mode: mode,
            destination: CleanupProviderDestination(providerID: .ollama, model: "fixture", isOnThisMac: true),
            chatResolver: { chat },
            budgetProvider: { nil },
            candidateProvider: { try await history.learningCandidates() },
            retentionProvider: { retention },
            sourceChecker: { try await history.existingRecordingIDs($0) },
            vocabularyAdder: vocabularyAdder ?? { [weak self] in self?.vocabulary.append($0); return true },
            defaults: defaults
        )
    }

    func settle(_ session: CorrectionLearningSession) async throws {
        for _ in 0..<600 where session.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(session.isBusy)
    }

    func pipeline(_ cleanup: LiteralCleanup, filter: (() -> CleanupFilterSnapshot)? = nil) -> TranscriptCleanupPipeline {
        let defaults = defaults!
        return TranscriptCleanupPipeline(
            isEnabled: { true }, providerResolver: { cleanup }, vocabularyProvider: { [] }, appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: filter ?? { CustomCleanupFilterStore.currentSnapshot(in: defaults) },
            failureRecorder: { _ in }
        )
    }
}

// MARK: - A1: word swaps and names never become rules on their own

@MainActor
final class LearnedWordChangeTests: XCTestCase {
    func testWordSwapsAndNamesPassAsRespellingsButNeverAsLearnableSpellings() {
        let swaps: [(String, String)] = [
            ("lunch", "launch"), ("cost", "coast"), ("morning", "mourning"), ("patience", "patients"), ("Anna", "Anne"),
            ("Steven", "Stephen"), ("flower", "flour"), ("dual", "duel"), ("steal", "steel"), ("horse", "hoarse"),
            ("bring", "being"), ("farther", "further"), ("cereal", "serial")
        ]
        for (from, to) in swaps {
            XCTAssertTrue(CorrectionText.isWordChange(from: from, to: to), "\(from) → \(to)")
            XCTAssertFalse(CorrectionText.isOrthographicChange(from: from, to: to), "\(from) → \(to)")
            let edit = CorrectionEdit(candidateID: UUID(), emitted: from, final: to, before: "", after: "", origin: .recognition,
                                      isLegacy: false, cleanupInput: from, documentPosition: 1)
            var numbered = edit
            numbered.number = 1
            let result = CorrectionPreferenceValidator.validate(
                [ProposedPreference(kind: .spelling, edits: [1], from: from, to: to, word: nil)], edits: [numbered], mode: .everyday
            )
            XCTAssertTrue(result.accepted.isEmpty, "\(from) → \(to)")
        }
    }
}

@MainActor
final class PreferenceLearningFlowTests: PreferenceLearningTestCase {
    private var harness: PreferenceLearningFlowTests { self }

    /// P1: one "lunch" → "launch" fix used to become "Write lunch as launch"
    /// for all of Everyday and change the next unrelated dictation.
    func testAOneOffWordFixIsNeitherSentNorLearnedAndIsOfferedForVocabulary() async throws {
        let h = harness
        let emitted = "The team met for lunch on Friday to review the plan for the spring product release and the budget."
        try await h.dictation("the team met for lunch on friday to review the plan for the spring product release and the budget", emitted: emitted)
        let chat = FixedClassifier(#"{"preferences": [{"kind": "spelling", "edits": [1], "from": "lunch", "to": "launch"}]}"#)
        let session = h.session(chat)
        session.document = emitted.replacingOccurrences(of: "for lunch", with: "for launch")
        session.learn()
        try await h.settle(session)

        let report = try XCTUnwrap(session.report, session.errorMessage ?? "")
        XCTAssertEqual(report.status, .noLearnableEdits)
        XCTAssertTrue(chat.requests.isEmpty, "A word change is never sent")
        XCTAssertTrue(LearnedPreferenceStore.load(from: h.defaults).isEmpty)
        XCTAssertEqual(report.plan.wordChanges, [.init(spoken: "lunch", replacement: "launch")])
        XCTAssertTrue(report.summary.contains("1 word change can be added to Vocabulary"), report.summary)

        // Only the person's explicit choice adds it, once.
        session.addToVocabulary(report.plan.wordChanges[0])
        session.addToVocabulary(report.plan.wordChanges[0])
        XCTAssertEqual(h.vocabulary.map { "\($0.spoken)→\($0.replacement)" }, ["lunch→launch"])

        // The next unrelated Everyday dictation keeps its words.
        let next = await h.pipeline(LiteralCleanup()).finalize("can we grab lunch with the new hires after the standup tomorrow")
        XCTAssertTrue(next.text.contains("lunch"), next.text)
    }

    /// Rules learned before this contract are kept and listed, never
    /// silently deleted, but no longer apply until converted or deleted.
    func testStoredWordChangeAndAmbiguousFillerAreKeptButNotApplied() async throws {
        let h = harness
        let baseline = CleanupPromptBuilder.systemPrompt(filter: CustomCleanupFilterStore.currentSnapshot(in: h.defaults))
        let stored = [
            preference(.spelling, from: "lunch", to: "launch"),
            preference(.removeFiller, from: "like"),
            preference(.spelling, from: "note book", to: "notebook")
        ]
        h.defaults.set(try JSONEncoder().encode(stored), forKey: LearnedPreferenceStore.dataKey)

        let kept = LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults)
        XCTAssertEqual(kept.count, 3, "Nothing is deleted silently")
        XCTAssertEqual(kept.map(\.inactivity), [.wordChange, .ambiguousFiller, nil])
        let snapshot = CustomCleanupFilterStore.currentSnapshot(in: h.defaults)
        XCTAssertEqual(snapshot.learned.map(\.instruction), ["Write “note book” as “notebook”."])
        let prompt = CleanupPromptBuilder.systemPrompt(filter: snapshot)
        XCTAssertFalse(prompt.contains("launch"))
        XCTAssertFalse(prompt.contains("“like”"))

        // Saving again keeps them too.
        LearnedPreferenceStore.setEnabled(kept[2].id, false, in: h.defaults)
        XCTAssertEqual(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).count, 3)
        XCTAssertEqual(CleanupPromptBuilder.systemPrompt(filter: CustomCleanupFilterStore.currentSnapshot(in: h.defaults)), baseline)

        // Explicit conversion moves the word change into Vocabulary.
        let session = h.session(FixedClassifier())
        session.moveToVocabulary(kept[0])
        session.moveToVocabulary(kept[1])
        XCTAssertEqual(h.vocabulary.map(\.replacement), ["launch"], "Only a word change converts")
        XCTAssertEqual(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).map(\.kind), [.removeFiller, .spelling])
        LearnedPreferenceStore.delete(kept[1].id, in: h.defaults)
        XCTAssertEqual(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).map(\.from), ["note book"])
    }

    /// Regression: at the 500-entry Vocabulary cap the adder reports failure,
    /// so a kept word change must not be deleted and an offered one must not
    /// be marked added - the word change is never lost nowhere.
    func testVocabularyFullKeepsTheWordChangeInsteadOfLosingIt() async throws {
        let h = harness
        let full: (VocabularyEntry) -> Bool = { _ in false }

        // Move: a stored word-change preference stays when Vocabulary is full.
        h.defaults.set(try JSONEncoder().encode([preference(.spelling, from: "lunch", to: "launch")]),
                       forKey: LearnedPreferenceStore.dataKey)
        let moveSession = h.session(FixedClassifier(), vocabularyAdder: full)
        let kept = LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults)
        XCTAssertEqual(kept.count, 1)
        moveSession.moveToVocabulary(kept[0])
        XCTAssertEqual(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).map(\.from), ["lunch"],
                       "A full Vocabulary must not delete the kept word change")
        XCTAssertNotNil(moveSession.vocabularyNotice)
        XCTAssertTrue(h.vocabulary.isEmpty)

        // Add: an offered word change stays offerable when Vocabulary is full.
        let emitted = "The team met for lunch on Friday to review the plan for the spring product release and the budget."
        try await h.dictation("the team met for lunch on friday to review the plan for the spring product release and the budget", emitted: emitted)
        let addSession = h.session(FixedClassifier(#"{"preferences": [{"kind": "spelling", "edits": [1], "from": "lunch", "to": "launch"}]}"#),
                                   vocabularyAdder: full)
        addSession.document = emitted.replacingOccurrences(of: "for lunch", with: "for launch")
        addSession.learn()
        try await h.settle(addSession)
        let report = try XCTUnwrap(addSession.report, addSession.errorMessage ?? "")
        XCTAssertEqual(report.plan.wordChanges, [.init(spoken: "lunch", replacement: "launch")])
        addSession.addToVocabulary(report.plan.wordChanges[0])
        XCTAssertFalse(addSession.addedWordChanges.contains(report.plan.wordChanges[0].id),
                       "A full Vocabulary must not mark the change added")
        XCTAssertNotNil(addSession.vocabularyNotice)
        XCTAssertTrue(h.vocabulary.isEmpty)
    }

    /// Regression: in one Learn, an already-known proposal reads "already
    /// learned", not "over the limit", when a different proposal in the same
    /// batch is the one skipped for the rule limit.
    func testDetailsSeparatesAlreadyLearnedFromOverLimitInOneLearn() {
        let h = harness
        let limit = LearnedPreferenceStore.maximumRulesPerMode
        let filling = (0..<limit).map { preference(.spelling, from: "word\($0) part", to: "word\($0)part") }
        LearnedPreferenceStore.merge(filling, into: .everyday, in: h.defaults)

        let known = preference(.spelling, from: "word0 part", to: "word0part")
        let overflow = preference(.spelling, from: "fresh word", to: "freshword")
        let merge = LearnedPreferenceStore.merge([known, overflow], into: .everyday, in: h.defaults)
        XCTAssertEqual(merge.unchanged, 1)
        XCTAssertEqual(merge.skippedForLimit, 1)
        XCTAssertTrue(merge.skippedForLimitKeys.contains(overflow.key))
        XCTAssertFalse(merge.skippedForLimitKeys.contains(known.key))

        let resolved = CorrectionLearningSession.resolve(
            [ProposalOutcome(description: "known", key: known.key, status: .learned),
             ProposalOutcome(description: "overflow", key: overflow.key, status: .learned)],
            with: merge
        )
        XCTAssertEqual(resolved.map(\.status), [.alreadyLearned, .overLimit])
    }

    // MARK: A2: content-ambiguous fillers

    /// P2: literal removal of "like", "right", "just"... deleted content and
    /// passed the guard, so those removals are never learned.
    func testOnlyPureFillersAreLearnedForRemoval() {
        func validate(_ word: String) -> CorrectionPreferenceValidator.Result {
            var edit = CorrectionEdit(candidateID: UUID(), emitted: word, final: "", before: "", after: "", origin: .finalEdit,
                                      isLegacy: false, cleanupInput: nil, documentPosition: 1)
            edit.number = 1
            return CorrectionPreferenceValidator.validate(
                [ProposedPreference(kind: .removeFiller, edits: [1], from: nil, to: nil, word: word)], edits: [edit], mode: .everyday
            )
        }
        for word in ["like", "right", "just", "so", "well", "actually", "really", "literally", "okay", "kind of", "sort of"] {
            let result = validate(word)
            XCTAssertTrue(result.accepted.isEmpty, word)
            XCTAssertEqual(result.outcomes.map(\.status), [.ambiguousFiller], word)
        }
        for word in ["um", "uh", "basically", "you know", "i mean"] {
            XCTAssertEqual(validate(word).accepted.count, 1, word)
        }
        // Restoring an informal word cleanup removed is still learned.
        var restore = CorrectionEdit(candidateID: UUID(), emitted: "", final: "like", before: "", after: "", origin: .cleanup,
                                     isLegacy: false, cleanupInput: "like", documentPosition: 1)
        restore.number = 1
        XCTAssertEqual(CorrectionPreferenceValidator.validate(
            [ProposedPreference(kind: .keepWord, edits: [1], from: nil, to: nil, word: "like")], edits: [restore], mode: .everyday
        ).accepted.count, 1)
    }

    // MARK: A3: regeneration honors deletion, reset, and the off switch

    /// P3: Regenerate re-applied a captured preference after the person
    /// deleted it and switched learning off. Queued first runs keep theirs.
    func testRegenerationHonorsCurrentLearningStateWhileQueuedWorkKeepsItsSnapshot() async throws {
        let h = harness
        let rule = "Write “note book” as “notebook”."
        LearnedPreferenceStore.merge([preference(.spelling, from: "note book", to: "notebook")], into: .everyday, in: h.defaults)
        let captured = CleanupFilterSnapshot(mode: .everyday, learned: LearnedPreferenceStore.activePreferences(for: .everyday, in: h.defaults))
        XCTAssertEqual(captured.learned.count, 1)

        let engine = FixedWords()
        engine.words = "I bought a note book for the trip"
        let cleanup = LiteralCleanup()
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: engine), recordingStore: h.history,
            cleanupPipeline: h.pipeline(cleanup), learningDefaults: h.defaults
        )
        try FileManager.default.createDirectory(at: Recording.recordingsDirectory, withIntermediateDirectories: true)
        let id = UUID()
        var pending = Recording(id: id, timestamp: Date(), fileName: "\(id).wav", transcription: "", duration: 1,
                                status: .pending, progress: 0, cleanupRequested: true, cleanupMode: .everyday)
        try Data("synthetic audio".utf8).write(to: pending.url)
        defer { try? FileManager.default.removeItem(at: pending.url) }
        pending.sourceFileURL = pending.url.path
        try await h.history.addRecordingSync(pending, source: DictationSource(recordingID: id, disposition: .pending, filter: captured))

        func settled() async throws -> Recording {
            for _ in 0..<400 {
                if let row = try await h.history.fetchRecordings(limit: 1, offset: 0).first, !row.isPending, !queue.isProcessing { return row }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let newest = try await h.history.fetchRecordings(limit: 1, offset: 0).first
            return try XCTUnwrap(newest)
        }
        func regenerate() async throws -> (Recording, String) {
            let row = try await settled()
            await queue.requeueRecording(row)
            let after = try await settled()
            return (after, try XCTUnwrap(cleanup.prompts.last))
        }

        // Deleted after the dictation was queued: the queued run keeps its snapshot.
        LearnedPreferenceStore.reset(.everyday, in: h.defaults)
        queue.startProcessingQueue()
        var row = try await settled()
        XCTAssertTrue(try XCTUnwrap(cleanup.prompts.last).contains(rule))
        XCTAssertEqual(row.transcription, "I bought a notebook for the trip.")

        // Regenerate after the deletion: the rule is gone.
        var (regenerated, prompt) = try await regenerate()
        XCTAssertFalse(prompt.contains(rule))
        XCTAssertEqual(regenerated.transcription, "I bought a note book for the trip.")

        // Learned again, it applies again; nothing newer than the dictation is added.
        LearnedPreferenceStore.merge([preference(.spelling, from: "note book", to: "notebook"), preference(.semicolonJoin)],
                                     into: .everyday, in: h.defaults)
        (row, prompt) = try await regenerate()
        XCTAssertTrue(prompt.contains(rule))
        XCTAssertFalse(prompt.contains("semicolon"), "A regeneration never gains later preferences")

        // Learning switched off.
        LearnedPreferenceStore.setLearningEnabled(false, in: h.defaults)
        (row, prompt) = try await regenerate()
        XCTAssertFalse(prompt.contains(rule))
        LearnedPreferenceStore.setLearningEnabled(true, in: h.defaults)

        // The one preference switched off.
        let stored = try XCTUnwrap(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).first { $0.kind == .spelling })
        LearnedPreferenceStore.setEnabled(stored.id, false, in: h.defaults)
        (row, prompt) = try await regenerate()
        XCTAssertFalse(prompt.contains(rule))
        XCTAssertEqual(row.transcription, "I bought a note book for the trip.")
        _ = regenerated
    }

    // MARK: A9: provenance scope

    /// P4: a Technical dictation and a saved-filter dictation both taught the
    /// picker's mode, and the saved filter could never learn.
    func testEachDictationTeachesTheModeOrFilterItWasMadeWith() async throws {
        let h = harness
        let slack = try XCTUnwrap(CustomCleanupFilterStore.upsert(
            CustomCleanupFilter(name: "Slack", baseMode: .everyday, instructions: "Short casual sentences."), in: h.defaults
        ).first)
        let slackEmitted = "The build server went down again this morning and basically nobody could deploy until lunch time today."
        try await h.dictation("the build server went down again this morning and basically nobody could deploy until lunch time today",
                              emitted: slackEmitted, filter: CleanupFilterSnapshot(filter: slack), at: 1_000)
        let technicalEmitted = "Run the migration script against staging first. Then check the replica lag before touching production."
        try await h.dictation("run the migration script against staging first then check the replica lag before touching production",
                              emitted: technicalEmitted, filter: .builtIn(.technical), at: 1_001)

        let chat = FixedClassifier()
        let session = h.session(chat, mode: .everyday)
        session.document = slackEmitted.replacingOccurrences(of: "and basically nobody", with: "and nobody") + "\n\n"
            + technicalEmitted.replacingOccurrences(of: "first. Then", with: "first; then")

        // Check matches shows each dictation's own scope and sends nothing.
        session.check()
        try await h.settle(session)
        let plan = try XCTUnwrap(session.report?.plan, session.errorMessage ?? "")
        XCTAssertEqual(plan.dictations.map(\.scope), [.recorded(.filter(slack)), .recorded(.mode(.technical))])
        XCTAssertTrue(chat.requests.isEmpty)

        // One request teaches one scope; Learn again teaches the other.
        chat.reply = #"{"preferences": [{"kind": "remove_filler", "edits": [1], "word": "basically"}, {"kind": "semicolon_join", "edits": [2]}]}"#
        session.learn()
        try await h.settle(session)
        XCTAssertEqual(session.report?.target, .filter(slack))
        XCTAssertEqual(session.report?.remainingEdits, 1)
        session.learn()
        try await h.settle(session)
        XCTAssertEqual(session.report?.target, .mode(.technical))
        XCTAssertEqual(chat.requests.count, 2)
        XCTAssertTrue(chat.requests[0].messages[0].content.hasPrefix("FILTER: Slack (based on Everyday)"))
        XCTAssertTrue(chat.requests[1].messages[0].content.hasPrefix("MODE: Technical"))

        XCTAssertEqual(LearnedPreferenceStore.preferences(for: .filter(slack), in: h.defaults).map(\.kind), [.removeFiller])
        XCTAssertEqual(LearnedPreferenceStore.preferences(for: .technical, in: h.defaults).map(\.kind), [.semicolonJoin])
        XCTAssertTrue(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).isEmpty, "The picker never reassigns recorded provenance")

        // The filter applies its own list; its saved instructions never change.
        CustomCleanupFilterStore.select(.custom(slack.id), in: h.defaults)
        let snapshot = CustomCleanupFilterStore.currentSnapshot(in: h.defaults)
        XCTAssertEqual(snapshot.learned.map(\.kind), [.removeFiller])
        let prompt = CleanupPromptBuilder.systemPrompt(filter: snapshot)
        XCTAssertTrue(prompt.contains("Learned preferences for the \"Slack\" filter"))
        XCTAssertTrue(prompt.contains("The filter's saved preferences above take precedence over these."))
        XCTAssertEqual(CustomCleanupFilterStore.load(from: h.defaults), [slack])
        CustomCleanupFilterStore.select(.builtIn(.everyday), in: h.defaults)
        XCTAssertTrue(CustomCleanupFilterStore.currentSnapshot(in: h.defaults).learned.isEmpty, "Everyday never inherits the filter's list")

        // Deleting the filter deletes what it learned.
        CustomCleanupFilterStore.delete(id: slack.id, in: h.defaults)
        XCTAssertTrue(LearnedPreferenceStore.load(from: h.defaults).allSatisfy { $0.filterID == nil })
        XCTAssertTrue(LearnedPreferenceStore.knownEvidence(for: .filter(slack), in: h.defaults).isEmpty)
    }

    func testMixedScopeTakesUnknownFiltersAndDeletedFiltersTeachNothing() async throws {
        let h = harness
        let text = "The museum opened a new wing for modern sculpture last spring and the crowds have not slowed down since then."
        try await h.dictation("the museum opened a new wing for modern sculpture last spring and the crowds have not slowed down since then",
                              emitted: text, filter: .builtIn(.everyday), at: 1_000)
        try await h.dictation("the museum opened a new wing for modern sculpture last spring and the crowds have not slowed down since then",
                              emitted: text, filter: .builtIn(.technical), at: 1_001)
        let chat = FixedClassifier(#"{"preferences": [{"kind": "semicolon_join", "edits": [1]}]}"#)
        let session = h.session(chat)
        session.document = text.replacingOccurrences(of: "last spring and", with: "last spring; and")
        session.learn()
        try await h.settle(session)
        XCTAssertEqual(session.report?.status, .noLearnableEdits)
        XCTAssertTrue(chat.requests.isEmpty, "Takes from two scopes could belong to either")
        XCTAssertEqual(session.report?.plan.items.map(\.disposition), [.excluded(.mixedScope)])

        // Legacy rows: a recorded mode is used; a filter name without an id,
        // and a filter deleted since, teach nothing; no mode at all falls back.
        let legacyHistory = try makeHistory()
        let gone = CustomCleanupFilter(name: "Gone", baseMode: .writing, instructions: "x")
        let samples: [(Recording, DictationSource?)] = [
            (Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: 1), fileName: "a.wav",
                       transcription: "Our guide explained how each piece was cast in bronze using a method that dates back several thousand years.",
                       duration: 1, status: .completed, progress: 1, cleanupMode: .homework), nil),
            (Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: 2), fileName: "b.wav",
                       transcription: "Please remind me to call the dentist tomorrow morning before work starts at the clinic downtown.",
                       duration: 1, status: .completed, progress: 1, cleanupMode: .everyday, cleanupFilterName: "Old filter"), nil),
            (Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: 3), fileName: "c.wav",
                       transcription: "We walked along the harbor until the fog lifted and the fishing boats came back with their catch.",
                       duration: 1, status: .completed, progress: 1), nil)
        ]
        for (row, source) in samples {
            if let source { try await legacyHistory.addRecordingSync(row, source: source) } else { try await legacyHistory.addRecordingSync(row) }
        }
        let goneID = UUID()
        let deletedText = "The orchestra rehearsed the second movement twice before the conductor finally let everyone go home."
        try await legacyHistory.addRecordingSync(
            Recording(id: goneID, timestamp: Date(timeIntervalSince1970: 4), fileName: "d.wav", transcription: deletedText,
                      duration: 1, status: .completed, progress: 1, cleanupMode: .writing, cleanupFilterName: "Gone"),
            source: DictationSource(recordingID: goneID, recognizerText: deletedText, emittedText: deletedText, disposition: .pasteSent,
                                    filter: CleanupFilterSnapshot(filter: gone))
        )
        let candidates = try await legacyHistory.learningCandidates()
        let document = samples.map(\.0.transcription).joined(separator: "\n\n") + "\n\n" + deletedText
        let plan = CorrectionLearningPlan.make(document: document, candidates: candidates, filters: [], fallbackMode: .writing, knownEvidence: [:])
        XCTAssertEqual(Set(plan.dictations.map(\.scope)), [.recorded(.mode(.homework)), .unknownFilter, .fallback(.mode(.writing)), .deletedFilter])
    }

    func testStoredPreferencesFromEarlierVersionsDecodeUnchanged() throws {
        let h = harness
        let id = UUID()
        let legacyJSON = """
        [{"id":"\(id.uuidString)","mode":"writing","kind":"semicolon_join","isEnabled":true,"origin":"cleanup","evidence":["a1"],"fromLegacyOnly":false,"learnedAt":700000000,"updatedAt":700000000}]
        """
        h.defaults.set(Data(legacyJSON.utf8), forKey: LearnedPreferenceStore.dataKey)
        let loaded = LearnedPreferenceStore.load(from: h.defaults)
        XCTAssertEqual(loaded.map(\.id), [id])
        XCTAssertNil(loaded.first?.filterID)
        XCTAssertEqual(loaded.first?.sourceRecordingIDs, [])
        XCTAssertEqual(LearnedPreferenceStore.activePreferences(for: .writing, in: h.defaults).count, 1)
        // Their reviewed edits keep the mode's key.
        LearnedPreferenceStore.markReviewed(["r1"], for: .writing, in: h.defaults)
        XCTAssertEqual(LearnedPreferenceStore.knownEvidence(for: .mode(.writing), in: h.defaults), ["a1", "r1"])
    }

    // MARK: A4: Check matches, details, and no-match reasons

    /// P5: exclusions and rejections were counted but never explained.
    func testCheckMatchesSendsNothingAndShowsExactlyWhatLearnSends() async throws {
        let h = harness
        let a = "We counted twelve chairs in the hall and the caterer said there would be enough for every guest tonight."
        try await h.dictation("we counted twelve chairs in the hall and the caterer said there would be enough for every guest tonight", emitted: a, at: 1_000)
        let b = "The venue manager asked us to finish setting up the stage before six. And the doors open at seven."
        try await h.dictation("the venue manager asked us to finish setting up the stage before six and the doors open at seven", emitted: b, at: 1_001)
        // Only learnable edits are numbered: the value change is never sent, so the semicolon join is edit 1.
        let chat = FixedClassifier(#"{"preferences": [{"kind": "semicolon_join", "edits": [1]}, {"kind": "digits", "edits": [1]}]}"#)
        let session = h.session(chat)
        session.document = """
        Event notes

        \(a.replacingOccurrences(of: "twelve", with: "fifteen"))

        \(b.replacingOccurrences(of: "six. And", with: "six; and"))
        """
        let storedBefore = h.defaults.data(forKey: LearnedPreferenceStore.dataKey)
        session.check()
        try await h.settle(session)
        let checked = try XCTUnwrap(session.report, session.errorMessage ?? "")
        XCTAssertEqual(checked.status, .ready)
        XCTAssertTrue(chat.requests.isEmpty, "Check matches sends nothing")
        XCTAssertEqual(h.defaults.data(forKey: LearnedPreferenceStore.dataKey), storedBefore)
        XCTAssertNil(h.defaults.object(forKey: LearnedPreferenceStore.reviewedKey), "Nothing is marked reviewed")
        XCTAssertTrue(checked.summary.contains("nothing has been sent"), checked.summary)
        XCTAssertTrue(checked.summary.contains("1 edit was left out"), checked.summary)
        let excluded = try XCTUnwrap(checked.plan.items.first { $0.disposition == .excluded(.changesValue) })
        XCTAssertTrue(excluded.excerpt.contains("«twelve» → «fifteen»"), excluded.excerpt)
        let wouldSend = checked.plan.items.filter { $0.disposition == .send }.map(\.excerpt)
        XCTAssertEqual(wouldSend.count, 1)

        session.learn()
        try await h.settle(session)
        XCTAssertEqual(chat.sentLines, wouldSend, "Learn sends exactly the lines Check matches showed")
        XCTAssertFalse(chat.requests[0].messages[0].content.contains("fifteen"))
        let learned = try XCTUnwrap(session.report)
        XCTAssertEqual(learned.status, .learned)
        XCTAssertEqual(learned.proposals.map(\.status), [.learned, .notShown])
        XCTAssertEqual(learned.proposals.last?.description, "Write numerical quantities as digits without changing any value.")
    }

    func testNoMatchSaysWhy() async throws {
        let h = harness
        let long = "The venue manager asked us to finish setting up the stage before six because the doors open at seven."
        try await h.dictation("the venue manager asked us to finish setting up the stage before six because the doors open at seven", emitted: long, at: 1_000)
        try await h.dictation("send the slides to maya tonight", emitted: "Send the slides to Maya tonight.", at: 1_001)
        let chat = FixedClassifier()
        let session = h.session(chat, retention: 30)
        func summary(_ document: String) async throws -> String {
            session.document = document
            session.check()
            try await h.settle(session)
            XCTAssertEqual(session.report?.status, .noMatch)
            return session.report?.summary ?? ""
        }
        // The opening and closing words survive, the middle was rewritten.
        let rewritten = try await summary(long.replacingOccurrences(
            of: "to finish setting up the stage before six",
            with: "to bring extra chairs, test both microphones, sweep the lobby, and print new programs for everyone before dinner"
        ))
        XCTAssertTrue(rewritten.contains("rewritten too much"), rewritten)
        XCTAssertTrue(rewritten.contains("compared your 2 most recent dictations"), rewritten)
        XCTAssertTrue(rewritten.contains("Dictations under 8 words can't be matched, and 1 of these is."), rewritten)
        XCTAssertTrue(rewritten.contains("History deletes dictations older than 30 days."), rewritten)
        let quoted = try await summary("Our host wrote, “\(long)”")
        XCTAssertFalse(quoted.contains("rewritten too much"), "A quotation is not a rewrite: \(quoted)")
        let repeated = try await summary(long + "\n\n" + long)
        XCTAssertTrue(repeated.contains("appears more than once"), repeated)
        XCTAssertFalse(repeated.contains("rewritten too much"), repeated)
        XCTAssertTrue(chat.requests.isEmpty)
    }

    /// A6: learned preferences name their source dictations, never their
    /// text, and say when History no longer has them.
    func testSourcesAreTrackedAndMissingOnesAreLabelled() async throws {
        let h = harness
        let first = "I kept a note book of every route and I wrote down the distance and how my legs felt afterwards."
        let firstID = try await h.dictation("i kept a note book of every route and i wrote down the distance and how my legs felt afterwards", emitted: first, at: 1_000)
        let second = "My old note book from the trip finally fell apart after the second winter in the garage."
        let secondID = try await h.dictation("my old note book from the trip finally fell apart after the second winter in the garage", emitted: second, at: 1_001)
        let chat = FixedClassifier(#"{"preferences": [{"kind": "spelling", "edits": [1, 2], "from": "note book", "to": "notebook"}]}"#)
        let session = h.session(chat)
        session.document = first.replacingOccurrences(of: "note book", with: "notebook") + "\n\n" + second.replacingOccurrences(of: "note book", with: "notebook")
        session.learn()
        try await h.settle(session)
        let learned = try XCTUnwrap(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).first)
        XCTAssertEqual(Set(learned.sourceRecordingIDs), [firstID, secondID])
        let encoded = try XCTUnwrap(h.defaults.data(forKey: LearnedPreferenceStore.dataKey))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("route"), "No edit text is stored")

        let row = try await h.history.fetchRecordings(limit: 10, offset: 0).first { $0.id == secondID }
        try await h.history.deleteRecordingSync(try XCTUnwrap(row))
        session.check()
        try await h.settle(session)
        XCTAssertEqual(session.missingSources, [secondID])
    }

    func testDetailsRenderOffscreenFromMemoryOnly() async throws {
        let h = harness
        let a = "We counted twelve chairs in the hall and the caterer said there would be enough for every guest tonight."
        try await h.dictation("we counted twelve chairs in the hall and the caterer said there would be enough for every guest tonight", emitted: a, at: 1_000)
        let b = "After the hike we stopped for lunch at the lodge. And the owner told us about the new ski lift."
        try await h.dictation("after the hike we stopped for lunch at the lodge and the owner told us about the new ski lift", emitted: b, at: 1_001)
        let chat = FixedClassifier(#"{"preferences": [{"kind": "semicolon_join", "edits": [1]}, {"kind": "spelling", "edits": [1], "from": "lunch", "to": "launch"}]}"#)
        let session = h.session(chat)
        session.document = a.replacingOccurrences(of: "twelve", with: "fifteen") + "\n\n"
            + b.replacingOccurrences(of: "for lunch", with: "for launch").replacingOccurrences(of: "lodge. And", with: "lodge; and")
        session.learn()
        try await h.settle(session)
        let report = try XCTUnwrap(session.report, session.errorMessage ?? "")
        XCTAssertEqual(report.plan.wordChanges.count, 1)
        // A rule kept from before the current contract, listed as not applied.
        var stored = LearnedPreferenceStore.load(from: h.defaults)
        stored.append(preference(.spelling, from: "Anna", to: "Anne", evidence: ["old"]))
        LearnedPreferenceStore.save(stored, to: h.defaults)
        let views: [(String, AnyView)] = [
            ("learning-details", AnyView(CorrectionLearningDetails(report: report, destination: session.destination, session: session))),
            ("learning-card-after-learn", AnyView(CorrectionLearningCard(session: session, defaults: h.defaults)))
        ]
        for (name, content) in views {
        for scheme in [ColorScheme.light, .dark] {
            let view = content
                .padding()
                .frame(width: 560)
                .background(Color(.windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            XCTAssertGreaterThan(size.height, 150)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "\(name)-\(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["WORKFLOW_RENDER_DIR"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(attachment.name!).png"))
            }
            XCTAssertFalse(window.isVisible, "Visual verification stays offscreen")
        }
        }
        XCTAssertEqual(chat.requests.count, 1, "Rendering sent nothing more")
    }

    // MARK: A5: learned digits

    /// P7: a learned digits preference relied on the model; it now uses the
    /// local formatter a saved filter's digits choice uses.
    func testLearnedDigitsAreFinishedOnThisMacWithAPromptBlindModel() async throws {
        let h = harness
        LearnedPreferenceStore.merge([preference(.digits)], into: .everyday, in: h.defaults)
        let blind = LiteralCleanup()
        blind.readsPrompt = false
        let spoken = "we ordered twenty five chairs and fifteen percent arrived late"
        let snapshot = CustomCleanupFilterStore.currentSnapshot(in: h.defaults)
        XCTAssertTrue(snapshot.writesDigits)
        let on = await h.pipeline(blind).finalize(spoken)
        XCTAssertEqual(on.text, "We ordered 25 chairs and 15% arrived late.")
        XCTAssertEqual(on.source, .ollama)

        // Values, percents, and signs still hold under the guard.
        blind.inject = { $0.replacingOccurrences(of: "twenty five", with: "35") }
        let changed = await h.pipeline(blind).finalize(spoken)
        XCTAssertEqual(changed.source, .rawFallback)
        blind.inject = nil

        let stored = try XCTUnwrap(LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults).first)
        LearnedPreferenceStore.setEnabled(stored.id, false, in: h.defaults)
        let off = await h.pipeline(blind).finalize(spoken)
        XCTAssertEqual(off.text, "We ordered twenty five chairs and fifteen percent arrived late.")
    }

    // MARK: Train/held-out split

    func testHeldOutDictationsGainOnlyTheIntendedStyleAndKeepTheirMeaning() async throws {
        let h = harness
        let training: [(spoken: String, emitted: String, final: String)] = [
            ("basically I kept a note book of every hike and I wrote down the distance and the weather each morning",
             "Basically I kept a note book of every hike and I wrote down the distance and the weather each morning.",
             "I kept a notebook of every hike and I wrote down the distance and the weather each morning."),
            ("we hiked twenty five miles over the long weekend and the trail crew had cleared every fallen tree",
             "We hiked twenty five miles over the long weekend and the trail crew had cleared every fallen tree.",
             "We hiked 25 miles over the long weekend and the trail crew had cleared every fallen tree."),
            ("after the hike we stopped for lunch at the lodge and the owner told us about the new ski lift",
             "After the hike we stopped for lunch at the lodge and the owner told us about the new ski lift.",
             "After the hike we stopped for launch at the lodge and the owner told us about the new ski lift."),
            ("my friend anna drove the van back to town and like the roads were icy the whole way down the pass",
             "My friend Anna drove the van back to town and like the roads were icy the whole way down the pass.",
             "My friend Anne drove the van back to town and the roads were icy the whole way down the pass.")
        ]
        let heldOut = [
            "basically the new note book arrived on tuesday and it fits in my jacket pocket",
            "we packed thirty two granola bars for the ridge trip next month",
            "we should grab lunch with the volunteers before the cleanup starts",
            "I don't like hiking in the rain but the views from the summit were worth it"
        ]
        // No shared four-word run between training and held-out text.
        func shingles(_ text: String) -> Set<String> {
            let words = CorrectionText.words(text)
            return words.count < 4 ? [] : Set((0...(words.count - 4)).map { words[$0..<($0 + 4)].joined(separator: " ") })
        }
        let trainingShingles = training.reduce(into: Set<String>()) { $0.formUnion(shingles($1.spoken + " . " + $1.final)) }
        for sample in heldOut { XCTAssertTrue(shingles(sample).isDisjoint(with: trainingShingles), sample) }

        for (index, sample) in training.enumerated() {
            try await h.dictation(sample.spoken, emitted: sample.emitted, at: 1_000 + Double(index))
        }
        let baseline = CleanupPromptBuilder.systemPrompt(filter: CustomCleanupFilterStore.currentSnapshot(in: h.defaults))
        let literal = LiteralCleanup()
        var off: [String] = []
        for sample in heldOut { off.append(await h.pipeline(literal).finalize(sample).text) }

        let classifier = EagerClassifier()
        let session = h.session(classifier)
        session.document = "Trip log\n\n" + training.map(\.final).joined(separator: "\n\n") + "\n\nThis paragraph was typed and never dictated."
        session.learn()
        try await h.settle(session)
        let report = try XCTUnwrap(session.report, session.errorMessage ?? "")
        let sent = classifier.requests.flatMap { $0.messages.map(\.content) }.joined(separator: "\n")
        XCTAssertFalse(sent.contains("«lunch»") || sent.contains("«Anna»"), "Word changes and names are never sent")
        XCTAssertFalse(sent.contains("typed and never dictated"))
        XCTAssertEqual(Set(report.plan.wordChanges.map { "\($0.spoken)→\($0.replacement)" }), ["lunch→launch", "Anna→Anne"])
        let learned = LearnedPreferenceStore.preferences(for: .everyday, in: h.defaults)
        XCTAssertEqual(Set(learned.map(\.instruction)), [
            "Write “note book” as “notebook”.",
            "Remove the filler word “basically”.",
            "Write numerical quantities as digits without changing any value."
        ])
        XCTAssertTrue(report.proposals.contains { $0.status == .ambiguousFiller && $0.description.contains("“like”") })

        var on: [String] = []
        for sample in heldOut { on.append(await h.pipeline(literal).finalize(sample).text) }
        print("HELD_OUT off=\(off)")
        print("HELD_OUT on=\(on)")
        XCTAssertTrue(on[0].contains("notebook") && !on[0].lowercased().contains("basically"), on[0])
        XCTAssertTrue(on[1].contains("32"), on[1])
        XCTAssertTrue(on[2].contains("lunch"), "A one-off fix never changes a later dictation: \(on[2])")
        XCTAssertTrue(on[3].contains("don't like"), "Content words and negations stay: \(on[3])")
        for (before, after) in zip(heldOut, on) {
            XCTAssertEqual(CleanupGuard.negationCount(in: after), CleanupGuard.negationCount(in: before), after)
        }

        // A prompt-blind model still gets digits, the only style finished on this Mac.
        let blind = LiteralCleanup()
        blind.readsPrompt = false
        let blindOut = await h.pipeline(blind).finalize(heldOut[1]).text
        XCTAssertTrue(blindOut.contains("32"), blindOut)
        let blindSpelling = await h.pipeline(blind).finalize(heldOut[0]).text
        XCTAssertTrue(blindSpelling.contains("note book"), "Spelling preferences depend on the model: \(blindSpelling)")

        // Whatever a model does with these preferences, facts, signs,
        // negations, and questions survive: unsafe rewrites fall back.
        let attacks: [(String, (String) -> String)] = [
            ("we packed thirty two granola bars for the ridge trip next month", { $0.replacingOccurrences(of: "thirty two", with: "42") }),
            ("about fifteen percent of the note book pages were blank", { $0.replacingOccurrences(of: "fifteen percent", with: "15") }),
            ("the low tonight is negative four degrees so bring the note book inside", { $0.replacingOccurrences(of: "negative four", with: "4") }),
            ("basically we can ship the note book app on thursday", { $0.replacingOccurrences(of: "we can ship", with: "we cannot ship") }),
            ("I don't like hiking in the rain but the views from the summit were worth it", { $0.replacingOccurrences(of: "don't like", with: "like") }),
            ("where did I leave the note book yesterday", { _ in "You left it on the kitchen table" })
        ]
        for (spoken, inject) in attacks {
            literal.inject = inject
            let out = await h.pipeline(literal).finalize(spoken)
            XCTAssertEqual(out.source, .rawFallback, spoken)
        }
        literal.inject = nil

        // Deleting every preference restores the prompt byte for byte.
        for preference in LearnedPreferenceStore.load(from: h.defaults) {
            LearnedPreferenceStore.delete(preference.id, in: h.defaults)
        }
        XCTAssertEqual(CleanupPromptBuilder.systemPrompt(filter: CustomCleanupFilterStore.currentSnapshot(in: h.defaults)), baseline)
    }

    // MARK: A6: search scale

    func testFiveThousandDictationSearchIsBoundedRepeatableAndOffTheMainActor() async throws {
        let database = try DatabaseQueue()
        let store = try makeHistory(database)
        var generator = SplitMix64(state: 0x5EED)
        let words = "river garden window market ticket lantern harbor meadow pencil quarter ladder violin orchard canvas engine basket compass summit glacier canyon tunnel bridge kettle mirror pillow saddle anchor beacon cabin falcon"
            .split(separator: " ").map(String.init)
        func sentence() -> String { (0..<40).map { _ in words[Int(generator.next() % UInt64(words.count))] }.joined(separator: " ") + "." }
        let rows = (0..<5_100).map { index in
            Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index)), fileName: "\(index).wav",
                      transcription: sentence(), duration: 1, status: .completed, progress: 1, cleanupMode: .everyday)
        }
        try await database.write { db in for row in rows { try row.insert(db) } }

        func search() async throws -> (Int, Int, TimeInterval) {
            let start = Date()
            let candidates = try await store.learningCandidates()
            let document = rows.suffix(60).map(\.transcription).joined(separator: "\n\n")
            let plan = await Task.detached {
                CorrectionLearningPlan.make(document: document, candidates: candidates, filters: [], fallbackMode: .everyday, knownEvidence: [:])
            }.value
            return (candidates.count, plan.matchedDictations, Date().timeIntervalSince(start))
        }
        let first = try await search()
        let second = try await search()
        print("SCALE candidates=\(first.0) matched=\(first.1) seconds=\(String(format: "%.2f", first.2)),\(String(format: "%.2f", second.2))")
        XCTAssertEqual(first.0, RecordingStore.learningCandidateLimit, "The newest 5,000 dictations are compared")
        XCTAssertEqual(first.1, second.1, "Repeatable")
        XCTAssertGreaterThan(first.1, 0)
        XCTAssertLessThan(max(first.2, second.2), 60, "Generous bound; the measured time is printed above")
    }
}
