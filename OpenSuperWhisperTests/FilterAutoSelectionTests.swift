import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

// Auto filter choice, proven against the shipped selector, store, pipeline,
// queue, History, and views with synthetic fixtures. Recognizer words and
// provider replies are scripted, so this proves the deterministic rules and
// the plumbing, not how well trigger phrases suit real dictations. Nothing
// reaches a microphone, model, paid provider, Keychain, the general
// pasteboard, the user's preferences, or their History, and nothing is shown.

/// Synthetic saved filters with trigger phrases.
private enum Fixtures {
    static let calculus = CustomCleanupFilter(
        name: "Calculus", baseMode: .homework, instructions: "Write math notation compactly.", writesDigits: true,
        triggers: ["derivative", "integral", "limit", "calculus"]
    )
    static let spanish = CustomCleanupFilter(
        name: "Spanish class", baseMode: .writing, instructions: "Keep Spanish accents exactly as spoken.",
        triggers: ["subjunctive", "conjugation", "preterite"]
    )
    static let codeReview = CustomCleanupFilter(
        name: "Code review", baseMode: .technical, instructions: "Use backticks around identifiers.",
        triggers: ["pull request", "unit test", "stack trace"]
    )
    static let chemistry = CustomCleanupFilter(
        name: "Chemistry lab", baseMode: .homework, instructions: "Write chemical formulas with subscripts.", writesDigits: true,
        triggers: ["molarity", "titration", "reagent"]
    )
    /// A filter with no phrases: it can only ever be picked by hand.
    static let plain = CustomCleanupFilter(name: "Plain notes", baseMode: .everyday, instructions: "Keep sentences short.")

    static let all = [calculus, spanish, codeReview, chemistry, plain]

    static func config(
        fallback: CapturedFilter = .builtIn(.everyday, learned: [])
    ) -> FilterAutoConfig {
        FilterAutoConfig(
            candidates: all.filter { $0.triggers.count >= FilterTriggers.minimumDistinctHits },
            fallback: fallback
        )
    }

    /// Each contains at most one phrase of any single filter: an ambiguous
    /// word, a repeat of one phrase, one phrase each from two filters, or a
    /// near miss (plural, prefix, split phrase). None may switch filters.
    static let oneHitControls: [String] = [
        "the derivative lawsuit got dismissed this morning",
        "that move was integral to winning the game",
        "there is a limit on how many tickets we can buy",
        "I took calculus years ago and forgot all of it",
        "can you send me the conjugation chart from yesterday",
        "the subjunctive mood of the poem felt heavy",
        "my preterite essay is due tomorrow",
        "please open a pull request when you are ready",
        "the unit test passed on my machine",
        "paste the stack trace into the ticket",
        "molarity came up at trivia night",
        "the titration video went viral",
        "buy more reagent before the lab closes",
        "speed limit signs are posted on the bridge",
        "her contribution was integral to the project",
        "we hit the credit limit again",
        "the derivative work clause in the contract",
        "a pull request for the garden club website",
        "a stack trace showed up in the console",
        "limit limit limit no means no",
        "integral, integral, it's integral",
        "the derivative of the derivative of the joke",
        "the unit test for the derivative",
        "titration and the subjunctive",
        "a pull request about molarity",
        "calculus homework on conjugation",
        "the Limit of my patience",
        "DERIVATIVE markets were calm today",
        "an integral-looking sculpture",
        "reagent, reagent, and more reagent",
        "the preterite and the stack trace",
        "the stack trace from the unit testing run",
        // Near misses with no whole-word phrase at all.
        "derivatives and integrals are plural here",
        "the limitless calculator",
        "unit testing the stack",
        "pull the request back",
        "subjunctives are hard",
        "derivation and integration",
    ]
}

/// The pure selector and trigger rules.
final class FilterAutoSelectorTests: XCTestCase {
    private func resolve(_ text: String, config: FilterAutoConfig = Fixtures.config()) -> FilterChoice {
        FilterAutoSelector.resolve(config, text: text)
    }

    func testTwoDistinctPhrasesOfOneFilterPickIt() {
        let choice = resolve("find the derivative and then the integral of x squared")
        XCTAssertEqual(choice.filter, CleanupFilterSnapshot(filter: Fixtures.calculus))
        XCTAssertEqual(choice.reason, .triggers(["derivative", "integral"]))

        let code = resolve("the unit test failed and the stack trace points at the parser")
        XCTAssertEqual(code.filter.customID, Fixtures.codeReview.id)
        XCTAssertEqual(code.reason, .triggers(["unit test", "stack trace"]))
    }

    func testMatchingIsWholeWordAndIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(resolve("DERIVATIVE, then… Integral!").reason, .triggers(["derivative", "integral"]))
        XCTAssertEqual(resolve("la Dérivative et Intégral").reason, .triggers(["derivative", "integral"]))
        XCTAssertEqual(resolve("a pull-request with a unit test").reason, .triggers(["pull request", "unit test"]))
        XCTAssertEqual(resolve("derivatives and integrals").reason, .fallback, "Plurals are different words")
        XCTAssertEqual(resolve("pull the request, test the unit").reason, .fallback, "A phrase must be contiguous")
    }

    func testOneHitTieAndNoHitKeepTheFallback() {
        let fallback = CapturedFilter.custom(Fixtures.plain)
        let config = Fixtures.config(fallback: fallback)
        XCTAssertEqual(resolve("what a derivative idea", config: config), FilterChoice(filter: fallback.snapshot, reason: .fallback))
        XCTAssertEqual(resolve("nothing specific at all", config: config).reason, .fallback)
        let tie = resolve("the derivative and integral of the titration molarity curve", config: config)
        XCTAssertEqual(tie.reason, .fallback, "Two filters each reaching two phrases is a tie")
        XCTAssertEqual(tie.filter, fallback.snapshot)
        let lopsided = resolve("derivative integral limit and also titration molarity", config: config)
        XCTAssertEqual(lopsided.reason, .fallback, "A tie is any second qualifying filter, never the larger count")
    }

    /// Non-circular: each control is first shown to hold at most one phrase
    /// of any filter, and most hold exactly one, before the selector runs.
    func testThirtyPlusOneHitControlsNeverSwitch() {
        let controls = Fixtures.oneHitControls
        XCTAssertGreaterThanOrEqual(controls.count, 30)
        var withAHit = 0
        for text in controls {
            let words = FilterTriggers.words(text)
            let counts = Fixtures.all.map { FilterTriggers.hits(of: $0.triggers, in: words).count }
            XCTAssertLessThanOrEqual(counts.max() ?? 0, 1, "“\(text)” is a one-hit control")
            if counts.contains(1) { withAHit += 1 }
            let choice = resolve(text)
            XCTAssertEqual(choice.reason, .fallback, "“\(text)” must keep the fallback")
            XCTAssertEqual(choice.filter, CleanupFilterSnapshot.builtIn(.everyday))
        }
        XCTAssertGreaterThanOrEqual(withAHit, 30, "At least 30 controls contain exactly one phrase")
    }

    func testOverlappingPhrasesCountAsOneMention() {
        let overlapping = CustomCleanupFilter(
            name: "Testing", baseMode: .technical, instructions: "Be terse.", triggers: ["unit test", "test", "coverage"]
        )
        let config = FilterAutoConfig(candidates: [overlapping], fallback: .builtIn(.everyday, learned: []))
        XCTAssertEqual(FilterAutoSelector.resolve(config, text: "the unit test is green").reason, .fallback)
        XCTAssertEqual(
            FilterAutoSelector.resolve(config, text: "the unit test is green and so is the test").reason,
            .triggers(["unit test", "test"])
        )
        XCTAssertEqual(
            FilterAutoSelector.resolve(config, text: "unit test coverage").reason,
            .triggers(["unit test", "coverage"])
        )
    }

    func testResolutionIsPureAndRepeatable() {
        let config = Fixtures.config()
        let text = "the preterite and the subjunctive conjugation"
        let first = resolve(text, config: config)
        for _ in 0..<50 { XCTAssertEqual(resolve(text, config: config), first) }
        XCTAssertEqual(first.reason, .triggers(["subjunctive", "conjugation", "preterite"]))
    }

    func testPhraseRulesRefuseTooManyLongCommonAndTakenPhrases() throws {
        XCTAssertEqual(try FilterTriggers.validated(["  Derivative ", "derivative", "", "Integral"], others: []), ["Derivative", "Integral"])
        XCTAssertThrowsError(try FilterTriggers.validated((1...9).map { "term\($0)" }, others: [])) {
            XCTAssertEqual($0 as? CustomCleanupFilterValidationError, .tooManyTriggers)
        }
        XCTAssertThrowsError(try FilterTriggers.validated(["one two three four"], others: [])) {
            XCTAssertEqual($0 as? CustomCleanupFilterValidationError, .triggerTooLong("one two three four"))
        }
        XCTAssertThrowsError(try FilterTriggers.validated([String(repeating: "x", count: 31)], others: []))
        for common in ["the", "and so", "like", "I", "you know", "x"] {
            XCTAssertThrowsError(try FilterTriggers.validated([common], others: []), "“\(common)” is refused") {
                XCTAssertEqual($0 as? CustomCleanupFilterValidationError, .triggerTooCommon(common))
            }
        }
        XCTAssertThrowsError(try FilterTriggers.validated(["Pull-Request"], others: [Fixtures.codeReview])) {
            XCTAssertEqual($0 as? CustomCleanupFilterValidationError, .duplicateTrigger("Pull-Request", otherFilter: "Code review"))
        }
        XCTAssertEqual(FilterTriggers.parse("derivative,  integral ;limit\n,"), ["derivative", "integral", "limit"])
    }

    func testSnapshotsOfAnAutoChoiceCarryTheFilterExactly() {
        let choice = resolve("molarity of the reagent")
        XCTAssertEqual(choice.filter, CleanupFilterSnapshot(filter: Fixtures.chemistry), "Same constructor, same ID and digits flag")
        XCTAssertEqual(choice.filter.customID, Fixtures.chemistry.id)
        XCTAssertEqual(choice.filter.mode, .homework)
    }

    func testReasonAndConfigRoundTripThroughJSON() throws {
        let config = Fixtures.config(fallback: .custom(Fixtures.plain))
        XCTAssertEqual(try JSONDecoder().decode(FilterAutoConfig.self, from: JSONEncoder().encode(config)), config)
        for reason in [FilterChoiceReason.manual, .fallback, .triggers(["a b", "c"])] {
            XCTAssertEqual(try JSONDecoder().decode(FilterChoiceReason.self, from: JSONEncoder().encode(reason)), reason)
        }
        XCTAssertNil(FilterChoiceReason.manual.label, "A filter picked by hand adds nothing to History")
        XCTAssertEqual(FilterChoiceReason.triggers(["derivative", "integral"]).label, "Auto: mentions derivative, integral")
        XCTAssertEqual(FilterChoiceReason.fallback.label, "Auto: no clear match")
    }
}

/// Saved filters at the new capacity, trigger persistence, and Auto's keys.
final class FilterCollectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FilterCollectionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    static func fifty() -> [CustomCleanupFilter] { fiftyFilters }

    private static let fiftyFilters: [CustomCleanupFilter] = {
        (1...50).map { index in
            CustomCleanupFilter(
                name: "Course \(index)",
                baseMode: CleanupMode.allCases[index % CleanupMode.allCases.count],
                instructions: "Rule \(index): use short sentences.",
                writesDigits: index.isMultiple(of: 3),
                triggers: ["topic\(index)a", "topic\(index)b"]
            )
        }
    }()

    func testFiftyFiltersCreateEditDeleteAndRoundTrip() throws {
        XCTAssertEqual(CustomCleanupFilterStore.maximumFilters, 50)
        for filter in Self.fifty() { try CustomCleanupFilterStore.upsert(filter, in: defaults) }
        var loaded = CustomCleanupFilterStore.load(from: defaults)
        XCTAssertEqual(loaded, Self.fifty(), "All 50 round-trip with their phrases, digits, and IDs")

        XCTAssertThrowsError(try CustomCleanupFilterStore.upsert(
            CustomCleanupFilter(name: "Course 51", baseMode: .everyday, instructions: "One too many."), in: defaults
        )) { XCTAssertEqual($0 as? CustomCleanupFilterValidationError, .tooManyFilters) }
        XCTAssertThrowsError(try CustomCleanupFilterStore.upsert(
            CustomCleanupFilter(name: "course 7", baseMode: .everyday, instructions: "Same name."), in: defaults
        )) { XCTAssertEqual($0 as? CustomCleanupFilterValidationError, .duplicateName) }
        XCTAssertThrowsError(try CustomCleanupFilterStore.upsert(
            CustomCleanupFilter(name: "Homework", baseMode: .everyday, instructions: "Reserved."), in: defaults
        ))

        var edited = loaded[24]
        edited.instructions = "Edited rule."
        edited.triggers = ["fresh phrase", "second phrase"]
        try CustomCleanupFilterStore.upsert(edited, in: defaults)
        XCTAssertThrowsError(try CustomCleanupFilterStore.upsert(
            { var other = loaded[3]; other.triggers = ["Fresh Phrase", "unique"]; return other }(), in: defaults
        ), "A phrase already picking another filter is refused")
        loaded = CustomCleanupFilterStore.load(from: defaults)
        XCTAssertEqual(loaded[24], edited, "Full list editable at capacity")

        CustomCleanupFilterStore.delete(id: loaded[0].id, in: defaults)
        XCTAssertEqual(CustomCleanupFilterStore.load(from: defaults).count, 49)
        try CustomCleanupFilterStore.upsert(
            CustomCleanupFilter(name: "Course 51", baseMode: .everyday, instructions: "Now there is room."), in: defaults
        )
        XCTAssertEqual(CustomCleanupFilterStore.load(from: defaults).count, 50)
    }

    func testFiltersSavedBeforePhrasesDecodeWithNoneAndInvalidStoredPhrasesAreDropped() throws {
        let id = UUID()
        let legacy = Data("""
        [{"id":"\(id.uuidString)","name":"Old","baseMode":"everyday","instructions":"Keep it.","writesDigits":true}]
        """.utf8)
        let decoded = CustomCleanupFilterStore.filters(from: legacy)
        XCTAssertEqual(decoded, [CustomCleanupFilter(id: id, name: "Old", baseMode: .everyday, instructions: "Keep it.", writesDigits: true)])
        XCTAssertEqual(decoded.first?.triggers, [])

        let second = UUID()
        let messy = Data("""
        [{"id":"\(id.uuidString)","name":"A","baseMode":"everyday","instructions":"x","triggers":["the","derivative","one two three four","Derivative"]},
         {"id":"\(second.uuidString)","name":"B","baseMode":"technical","instructions":"y","triggers":["derivative","stack trace"]}]
        """.utf8)
        let cleaned = CustomCleanupFilterStore.filters(from: messy)
        XCTAssertEqual(cleaned.map(\.triggers), [["derivative"], ["stack trace"]], "Common, long, repeated, and taken phrases drop; filters stay")
    }

    func testGroupingAndSearchKeepALargeCollectionScannable() {
        let filters = Self.fifty()
        XCTAssertTrue(FilterCollection.isLarge(filters))
        XCTAssertFalse(FilterCollection.isLarge(Array(filters.prefix(8))))
        let groups = FilterCollection.grouped(filters)
        XCTAssertEqual(groups.map(\.mode), CleanupMode.allCases)
        XCTAssertEqual(groups.map(\.filters.count).reduce(0, +), 50, "Every filter is in exactly one group")
        XCTAssertTrue(groups.allSatisfy { group in group.filters.allSatisfy { $0.baseMode == group.mode } })
        XCTAssertEqual(groups[0].filters.prefix(2).map(\.name), ["Course 4", "Course 8"], "Sorted by name, numbers in order")
        XCTAssertEqual(FilterCollection.search(filters, query: "course 17").map(\.name), ["Course 17"])
        XCTAssertEqual(FilterCollection.search(filters, query: "TOPIC33B").map(\.name), ["Course 33"], "Phrases are searchable")
        XCTAssertEqual(FilterCollection.search(filters, query: "rule 44").map(\.name), ["Course 44"])
        XCTAssertEqual(FilterCollection.search(filters, query: "   ").count, 50)
        XCTAssertTrue(FilterCollection.search(filters, query: "nothing like this").isEmpty)
    }

    func testAutoIsOffByDefaultAndItsKeysNeverTouchTheHandPickedSelection() throws {
        try CustomCleanupFilterStore.upsert(Fixtures.calculus, in: defaults)
        try CustomCleanupFilterStore.upsert(Fixtures.plain, in: defaults)
        CustomCleanupFilterStore.select(.custom(Fixtures.plain.id), in: defaults)
        XCTAssertFalse(FilterAutoSettings.isEnabled(in: defaults))
        XCTAssertNil(FilterAutoSettings.currentConfig(in: defaults))
        XCTAssertEqual(
            FilterAutoSettings.currentPlan(in: defaults),
            .manual(CustomCleanupFilterStore.currentSnapshot(in: defaults)),
            "Off, the plan is exactly the hand-picked snapshot"
        )

        FilterAutoSettings.setEnabled(true, in: defaults)
        XCTAssertEqual(FilterAutoSettings.fallback(in: defaults), .custom(Fixtures.plain.id), "Turning Auto on keeps the filter in use as fallback")
        XCTAssertEqual(defaults.string(forKey: CustomCleanupFilterStore.selectedIDKey), Fixtures.plain.id.uuidString)
        XCTAssertNotEqual(FilterAutoSettings.enabledKey, CustomCleanupFilterStore.selectedIDKey)
        XCTAssertNotEqual(FilterAutoSettings.fallbackKey, CustomCleanupFilterStore.selectedIDKey)

        // Saving filters, which clears a dangling selected ID, leaves Auto alone.
        var calculus = Fixtures.calculus
        calculus.instructions = "Edited."
        try CustomCleanupFilterStore.upsert(calculus, in: defaults)
        XCTAssertTrue(FilterAutoSettings.isEnabled(in: defaults))
        XCTAssertEqual(defaults.string(forKey: FilterAutoSettings.fallbackKey), CleanupFilterSelection.custom(Fixtures.plain.id).tag)

        // Picking by hand turns Auto off and keeps its fallback for next time.
        CustomCleanupFilterStore.select(.builtIn(.technical), in: defaults)
        XCTAssertFalse(FilterAutoSettings.isEnabled(in: defaults))
        XCTAssertEqual(FilterAutoSettings.fallback(in: defaults), .custom(Fixtures.plain.id))
        FilterAutoSettings.setEnabled(true, in: defaults)
        XCTAssertEqual(FilterAutoSettings.fallback(in: defaults), .custom(Fixtures.plain.id), "A chosen fallback is not overwritten")
    }

    func testDeletedFallbackNeverGuessesAnotherFilter() throws {
        try CustomCleanupFilterStore.upsert(Fixtures.calculus, in: defaults)
        try CustomCleanupFilterStore.upsert(Fixtures.plain, in: defaults)
        try CustomCleanupFilterStore.upsert(Fixtures.spanish, in: defaults)
        FilterAutoSettings.setEnabled(true, in: defaults)
        FilterAutoSettings.setFallback(.custom(Fixtures.plain.id), in: defaults)
        var config = try XCTUnwrap(FilterAutoSettings.currentConfig(in: defaults))
        XCTAssertEqual(config.fallback, .custom(Fixtures.plain))
        XCTAssertEqual(config.candidates.map(\.id), [Fixtures.calculus.id, Fixtures.spanish.id], "Only filters with two or more phrases")

        CustomCleanupFilterStore.delete(id: Fixtures.plain.id, in: defaults)
        config = try XCTUnwrap(FilterAutoSettings.currentConfig(in: defaults))
        XCTAssertEqual(config.fallback, .builtIn(.everyday, learned: []), "A deleted fallback is Everyday")
        XCTAssertEqual(FilterAutoSelector.resolve(config, text: "hello there").reason, .fallback)
        XCTAssertEqual(defaults.string(forKey: FilterAutoSettings.fallbackKey), CleanupFilterSelection.custom(Fixtures.plain.id).tag,
                       "The stored choice is kept, not destroyed")
    }

    func testCapturedConfigIgnoresLaterEdits() throws {
        try CustomCleanupFilterStore.upsert(Fixtures.calculus, in: defaults)
        FilterAutoSettings.setEnabled(true, in: defaults)
        let captured = try XCTUnwrap(FilterAutoSettings.currentConfig(in: defaults))
        var edited = Fixtures.calculus
        edited.triggers = ["vector", "matrix"]
        edited.instructions = "Changed later."
        try CustomCleanupFilterStore.upsert(edited, in: defaults)
        FilterAutoSettings.setFallback(.builtIn(.writing), in: defaults)
        let choice = FilterAutoSelector.resolve(captured, text: "the derivative and the integral")
        XCTAssertEqual(choice.filter.customInstructions, Fixtures.calculus.instructions)
        XCTAssertEqual(FilterAutoSelector.resolve(captured, text: "vector matrix").filter.mode, .everyday)
    }

}

/// Counts every provider request and keeps every prompt.
private final class CountingProvider: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .ollama
    private(set) var prompts: [String] = []
    private(set) var filters: [CleanupFilterSnapshot] = []

    func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
        prompts.append(systemPrompt)
        filters.append(filter)
        return CleanupProviderResult(text: transcript.prefix(1).uppercased() + transcript.dropFirst(), inputTokens: 1, outputTokens: 1, modelID: "count")
    }
}

/// The pipeline under Auto: precedence, request counts, and the off path.
final class FilterAutoPipelineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FilterAutoPipelineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        for filter in Fixtures.all { try? CustomCleanupFilterStore.upsert(filter, in: defaults) }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func pipeline(_ provider: CountingProvider, rules: [TargetAppRule] = []) -> TranscriptCleanupPipeline {
        let defaults = defaults!
        return TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: { [] },
            appRuleProvider: { TargetAppRuleStore.rule(for: $0, in: rules) },
            bedrockBudgetProvider: { nil },
            filterProvider: { CustomCleanupFilterStore.currentSnapshot(in: defaults) },
            autoConfigProvider: { FilterAutoSettings.currentConfig(in: defaults) },
            failureRecorder: { _ in }
        )
    }

    private static let corpus = [
        "find the derivative and then the integral of x squared",
        "the unit test failed and the stack trace points at the parser",
        "see you at lunch on friday",
        "what a derivative idea",
        "the subjunctive conjugation drill",
    ]

    private var selections: [CleanupFilterSelection] {
        CleanupMode.allCases.map(CleanupFilterSelection.builtIn) + [.custom(Fixtures.calculus.id), .custom(Fixtures.plain.id)]
    }

    private func run(_ text: String) async -> (prompt: String?, text: String, filter: CleanupFilterSnapshot?, reason: FilterChoiceReason?) {
        let provider = CountingProvider()
        let outcome = await pipeline(provider).finalize(text)
        return (provider.prompts.last, outcome.text, outcome.selectedFilter, outcome.filterReason)
    }

    /// Golden: prompts, output, and filter with Auto never on equal those
    /// after Auto was on and turned off, by its switch or by a hand pick,
    /// and equal the prompt built straight from the hand-picked snapshot.
    func testAutoOffIsByteForByteTheHandPickedPath() async throws {
        var baseline: [String: [String]] = [:]
        for selection in selections {
            CustomCleanupFilterStore.select(selection, in: defaults)
            for text in Self.corpus {
                let result = await run(text)
                let expected = CleanupPromptBuilder.systemPrompt(filter: CustomCleanupFilterStore.currentSnapshot(in: defaults), instruction: nil)
                XCTAssertEqual(result.prompt, expected)
                XCTAssertEqual(result.reason, .manual)
                baseline["\(selection.tag)|\(text)"] = [try XCTUnwrap(result.prompt), result.text, "\(String(describing: result.filter))"]
            }
        }

        for (index, selection) in selections.enumerated() {
            CustomCleanupFilterStore.select(selection, in: defaults)
            FilterAutoSettings.setEnabled(true, in: defaults)
            FilterAutoSettings.setFallback(.builtIn(.writing), in: defaults)
            if index.isMultiple(of: 2) {
                FilterAutoSettings.setEnabled(false, in: defaults)
            } else {
                CustomCleanupFilterStore.select(selection, in: defaults)
            }
            XCTAssertFalse(FilterAutoSettings.isEnabled(in: defaults))
            for text in Self.corpus {
                let result = await run(text)
                XCTAssertEqual([result.prompt ?? "", result.text, "\(String(describing: result.filter))"], baseline["\(selection.tag)|\(text)"],
                               "\(selection.tag): “\(text)”")
            }
        }
    }

    func testManualPickWinsOverPhrases() async throws {
        CustomCleanupFilterStore.select(.custom(Fixtures.plain.id), in: defaults)
        let provider = CountingProvider()
        let outcome = await pipeline(provider).finalize("the derivative and the integral")
        XCTAssertEqual(outcome.selectedFilter?.customID, Fixtures.plain.id)
        XCTAssertEqual(outcome.filterReason, .manual)
        XCTAssertTrue(try XCTUnwrap(provider.prompts.last).contains(Fixtures.plain.instructions))
    }

    func testAutoChoosesLocallyWithOneRequestPerChunk() async throws {
        FilterAutoSettings.setEnabled(true, in: defaults)
        let words = "find the derivative and then the integral of x squared"
        let first = CountingProvider()
        let firstOutcome = await pipeline(first).finalize(words)
        XCTAssertEqual(firstOutcome.selectedFilter?.customID, Fixtures.calculus.id)
        XCTAssertEqual(firstOutcome.filterReason, .triggers(["derivative", "integral"]))
        XCTAssertEqual(first.prompts.count, TranscriptChunker.chunks(words).count, "No request beyond cleanup's own")
        XCTAssertEqual(first.filters, [try XCTUnwrap(firstOutcome.selectedFilter)])

        let long = Array(repeating: "the derivative and then the integral of the curve keep going.", count: 120).joined(separator: " ")
        XCTAssertGreaterThan(TranscriptChunker.chunks(long).count, 1, "Fixture spans several chunks")
        let provider = CountingProvider()
        let outcome = await pipeline(provider).finalize(long)
        XCTAssertEqual(provider.prompts.count, TranscriptChunker.chunks(long).count)
        XCTAssertTrue(provider.filters.allSatisfy { $0 == CleanupFilterSnapshot(filter: Fixtures.calculus) }, "One choice for every chunk")
        XCTAssertEqual(outcome.filterReason, .triggers(["derivative", "integral"]))

        // Cleanup off: Auto still chooses on this Mac and nothing is sent.
        let off = CountingProvider()
        let disabled = await TranscriptCleanupPipeline(
            isEnabled: { false }, providerResolver: { off }, vocabularyProvider: { [] }, appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil }, filterProvider: { .builtIn(.everyday) },
            autoConfigProvider: { [defaults] in FilterAutoSettings.currentConfig(in: defaults!) },
            failureRecorder: { _ in }
        ).finalize(words)
        XCTAssertEqual(off.prompts.count, 0)
        XCTAssertEqual(disabled.source, .disabled)
        XCTAssertEqual(disabled.filterReason, .triggers(["derivative", "integral"]))
    }

    func testPhrasesAreReadAfterVocabularyRewrites() async {
        FilterAutoSettings.setEnabled(true, in: defaults)
        let defaults = defaults!
        let provider = CountingProvider()
        let outcome = await TranscriptCleanupPipeline(
            isEnabled: { true }, providerResolver: { provider },
            vocabularyProvider: { [VocabularyEntry(spoken: "tie tray shun", replacement: "titration")] },
            appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil },
            filterProvider: { CustomCleanupFilterStore.currentSnapshot(in: defaults) },
            autoConfigProvider: { FilterAutoSettings.currentConfig(in: defaults) },
            failureRecorder: { _ in }
        ).finalize("the tie tray shun used one reagent")
        XCTAssertEqual(outcome.filterReason, .triggers(["titration", "reagent"]))
    }
}

/// Returns scripted words, optionally holding until released, so the test
/// can edit filters after a dictation is queued and before it is processed.
private final class GatedSpeech: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Gated speech"
    var words = ""
    var isReleased = true

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}
    func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String {
        while !isReleased { try await Task.sleep(nanoseconds: 5_000_000) }
        return words
    }
}

/// What the scripted provider received, and how it replies. URL loading
/// calls it on its own thread, so it is guarded by a lock.
private final class ScriptedReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(system: String, user: String)] = []
    private var _reply: (String) -> String? = { _ in nil }

    var requests: [(system: String, user: String)] { lock.withLock { _requests } }
    var reply: (String) -> String? {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    func record(system: String, user: String, transcript: String) -> String? {
        lock.withLock {
            _requests.append((system, user))
            return _reply(transcript)
        }
    }
}

/// The real queue, History store, live dictation path, and OpenAI-compatible
/// transport over a scripted URL protocol, reading the host's own per-run
/// preferences, which are saved and restored.
@MainActor
final class FilterAutoQueueAndHistoryTests: XCTestCase {
    private static let savedKeys = [
        CustomCleanupFilterStore.modeKey, CustomCleanupFilterStore.selectedIDKey, CustomCleanupFilterStore.dataKey,
        FilterAutoSettings.enabledKey, FilterAutoSettings.fallbackKey, "targetAppRulesData",
    ]
    private var originals: [String: Any?] = [:]
    private var store: RecordingStore!
    private var session: URLSession!
    private var pipeline: TranscriptCleanupPipeline!
    private let replies = ScriptedReplies()
    private var requests: [(system: String, user: String)] { replies.requests }
    private var reply: (String) -> String? {
        get { replies.reply }
        set { replies.reply = newValue }
    }
    private var cleanup: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        for key in Self.savedKeys {
            originals[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        for filter in Fixtures.all { try CustomCleanupFilterStore.upsert(filter) }
        CustomCleanupFilterStore.select(.builtIn(.everyday))
        store = try RecordingStore(
            database: DatabaseQueue(), recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupURLProtocol.self]
        session = URLSession(configuration: configuration)
        let service = OpenAIChatCleanupService(
            providerID: .openAICompatible, baseURL: "https://cleanup.invalid/v1", modelID: "scripted",
            apiKey: "scripted-test", timeout: 5, session: session
        )
        let replies = replies
        CleanupURLProtocol.handler = { request in try Self.handle(request, replies: replies) }
        pipeline = TranscriptCleanupPipeline(
            isEnabled: { true }, providerResolver: { service }, vocabularyProvider: { [] },
            appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil }, failureRecorder: { _ in }
        )
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        CleanupURLProtocol.handler = nil
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        for (key, value) in originals {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    nonisolated private static func handle(_ request: URLRequest, replies: ScriptedReplies) throws -> (HTTPURLResponse, Data) {
        let body = try XCTUnwrap(Self.body(request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let system = messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
        let user = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let transcript = Self.transcript(in: user)
        let text = replies.record(system: system, user: user, transcript: transcript)
            ?? (transcript.prefix(1).uppercased() + transcript.dropFirst() + ".")
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 40, "completion_tokens": 12],
        ])
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
    }

    nonisolated private static func transcript(in user: String) -> String {
        for (open, close) in [("<transcript>\n", "\n</transcript>"), ("RAW_TRANSCRIPTION:\n", "")] {
            guard let start = user.range(of: open) else { continue }
            let rest = user[start.upperBound...]
            let end = close.isEmpty ? rest.endIndex : (rest.range(of: close)?.lowerBound ?? rest.endIndex)
            return String(rest[..<end])
        }
        return user
    }

    nonisolated private static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func queue(_ engine: GatedSpeech) -> TranscriptionQueue {
        TranscriptionQueue(transcriptionService: TranscriptionService(engine: engine), recordingStore: store, cleanupPipeline: pipeline)
    }

    private func queuedAudio() throws -> URL {
        try FileManager.default.createDirectory(at: AudioRecorder.temporaryRecordingsDirectory, withIntermediateDirectories: true)
        let url = AudioRecorder.temporaryRecordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("synthetic audio".utf8).write(to: url)
        cleanup.append(url)
        return url
    }

    private func settled(_ queue: TranscriptionQueue) async throws -> Recording {
        for _ in 0..<400 {
            if let row = try await store.fetchRecordings(limit: 1, offset: 0).first, !row.isPending, !queue.isProcessing {
                cleanup.append(row.url)
                return row
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let newest = try await store.fetchRecordings(limit: 1, offset: 0).first
        return try XCTUnwrap(newest)
    }

    func testQueuedDictationKeepsTheAutoChoicesCapturedAtEnqueue() async throws {
        FilterAutoSettings.setEnabled(true)
        FilterAutoSettings.setFallback(.custom(Fixtures.plain.id))
        let engine = GatedSpeech()
        engine.words = "find the derivative and then the integral of twenty five"
        engine.isReleased = false
        let queue = queue(engine)
        await queue.addFileToQueue(url: try queuedAudio(), cleanupRequested: true)

        let newest = try await store.fetchRecordings(limit: 1, offset: 0).first
        let pending = try XCTUnwrap(newest)
        XCTAssertNotNil(pending.cleanupFilterAuto, "Auto's choices are stored with the queued row")
        XCTAssertNil(pending.cleanupFilterReason, "Nothing is claimed before the words are known")
        XCTAssertEqual(pending.cleanupFilterName, Fixtures.plain.name, "The provisional filter is the fallback")

        // Edits after enqueue: phrases, fallback, and Auto itself.
        var calculus = Fixtures.calculus
        calculus.triggers = ["vector", "matrix"]
        calculus.instructions = "Edited after the dictation was queued."
        try CustomCleanupFilterStore.upsert(calculus)
        FilterAutoSettings.setFallback(.builtIn(.writing))
        CustomCleanupFilterStore.select(.builtIn(.technical))
        engine.isReleased = true

        var row = try await settled(queue)
        XCTAssertEqual(row.cleanupFilterName, "Calculus")
        XCTAssertEqual(row.cleanupFilterInstructions, Fixtures.calculus.instructions)
        XCTAssertEqual(row.cleanupFilterReason, .triggers(["derivative", "integral"]))
        XCTAssertNil(row.cleanupFilterAuto, "Cleared once the choice is made")
        XCTAssertEqual(row.transcription, "Find the derivative and then the integral of 25.", "Calculus writes digits")
        XCTAssertEqual(requests.count, 1, "One cleanup request, no other")
        XCTAssertTrue(requests[0].system.contains(Fixtures.calculus.instructions))
        let evidence = try await store.dictationSource(for: row.id)
        XCTAssertEqual(evidence?.filterID, Fixtures.calculus.id)
        XCTAssertEqual(evidence?.filterReason, .triggers(["derivative", "integral"]))

        // Regenerate keeps the choice it made, even with Auto now off.
        await queue.requeueRecording(row)
        row = try await settled(queue)
        XCTAssertEqual(row.cleanupFilterName, "Calculus")
        XCTAssertEqual(row.cleanupFilterReason, .triggers(["derivative", "integral"]))
        XCTAssertEqual(requests.count, 2)

        // Regenerate With overrides it by hand; the evidence keeps the original.
        await queue.requeueRecording(row, with: .builtIn(.writing))
        row = try await settled(queue)
        XCTAssertEqual(row.cleanupMode, .writing)
        XCTAssertNil(row.cleanupFilterName)
        XCTAssertEqual(row.cleanupFilterReason, .manual)
        XCTAssertFalse(try XCTUnwrap(requests.last).system.contains(Fixtures.calculus.instructions))
        let original = try await store.dictationSource(for: row.id)
        XCTAssertEqual(original?.filterID, Fixtures.calculus.id)

        await queue.requeueRecording(row, with: .custom(Fixtures.spanish.id))
        row = try await settled(queue)
        XCTAssertEqual(row.cleanupFilterName, Fixtures.spanish.name)
        XCTAssertTrue(try XCTUnwrap(requests.last).system.contains(Fixtures.spanish.instructions))
    }

    func testQueuedDictationWithAutoOffKeepsTheHandPickedFilter() async throws {
        CustomCleanupFilterStore.select(.custom(Fixtures.plain.id))
        let engine = GatedSpeech()
        engine.words = "the derivative and the integral"
        let queue = queue(engine)
        await queue.addFileToQueue(url: try queuedAudio(), cleanupRequested: true)
        let row = try await settled(queue)
        XCTAssertEqual(row.cleanupFilterName, Fixtures.plain.name, "Phrases never apply with Auto off")
        XCTAssertEqual(row.cleanupFilterReason, .manual)
        XCTAssertNil(row.cleanupFilterAuto)
    }

    func testLiveDictationRecordsTheAutoChoiceAndTheGuardStillHolds() async throws {
        FilterAutoSettings.setEnabled(true)
        let gate = LatestDictationGate()
        let engine = GatedSpeech()
        var delivered: [String] = []
        let indicator = IndicatorViewModel(
            latestDictationGate: gate, transcriptionService: TranscriptionService(engine: engine),
            recordingStore: store, cleanupPipeline: pipeline,
            delivery: { delivered.append($0); return .pasteSent }
        )
        defer { indicator.cleanup() }

        func dictate(_ words: String) async throws -> (Recording, DictationSource?) {
            engine.words = words
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilterAuto-\(UUID().uuidString).wav")
            try Data("synthetic audio".utf8).write(to: url)
            let before = try await store.fetchRecordings(limit: 100, offset: 0).count
            await indicator.finishDictation(audioAt: url, generation: gate.begin(), recordingStartedAt: Date())
            var rows: [Recording] = []
            for _ in 0..<300 {
                rows = try await store.fetchRecordings(limit: 100, offset: 0)
                if rows.count > before { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let row = try XCTUnwrap(rows.first)
            cleanup.append(row.url)
            return (row, try await store.dictationSource(for: row.id))
        }

        var (row, evidence) = try await dictate("the molarity of the reagent was twenty five percent")
        XCTAssertEqual(row.cleanupFilterName, Fixtures.chemistry.name)
        XCTAssertEqual(row.cleanupFilterReason, .triggers(["molarity", "reagent"]))
        XCTAssertEqual(evidence?.filterReason, .triggers(["molarity", "reagent"]))
        XCTAssertEqual(evidence?.filterID, Fixtures.chemistry.id)
        XCTAssertEqual(requests.count, 1, "Auto added no request")
        XCTAssertEqual(row.transcription, "The molarity of the reagent was 25%.")

        // A hostile reply that changes a value is refused for an Auto choice too.
        reply = { _ in "The molarity of the reagent was 26%." }
        (row, _) = try await dictate("the molarity of the reagent was twenty five percent")
        XCTAssertEqual(row.cleanupFilterReason, .triggers(["molarity", "reagent"]))
        XCTAssertNotEqual(row.transcription, "The molarity of the reagent was 26%.", "The numeric guard holds")
        XCTAssertEqual(row.cleanupSource, .rawFallback)

        // A one-hit dictation keeps the fallback, and says so.
        reply = { _ in nil }
        (row, evidence) = try await dictate("we hit the limit on lunch orders")
        XCTAssertEqual(row.cleanupMode, .everyday)
        XCTAssertNil(row.cleanupFilterName)
        XCTAssertEqual(row.cleanupFilterReason, .fallback)
        XCTAssertEqual(evidence?.filterReason, .fallback)
        XCTAssertEqual(HistoryRow(recording: row, searchQuery: "", isPlaying: false, onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {})
            .filterChoiceLabel, "Everyday · Auto: no clear match")
        XCTAssertEqual(delivered.count, 3)
    }

    func testHistoryReadsTheChoiceBackAndLegacyRowsShowNothingNew() async throws {
        let id = UUID()
        let auto = Recording(
            id: id, timestamp: Date(), fileName: "\(id).wav", transcription: "Done.", duration: 1, status: .completed,
            progress: 1, sourceFileURL: nil, cleanupSource: .ollama, cleanupMode: .homework, cleanupFilterName: "Calculus",
            cleanupFilterReason: .triggers(["derivative", "integral"])
        )
        let legacyID = UUID()
        let legacy = Recording(
            id: legacyID, timestamp: Date().addingTimeInterval(-10), fileName: "\(legacyID).wav", transcription: "Old.",
            duration: 1, status: .completed, progress: 1, sourceFileURL: nil, cleanupSource: .ollama, cleanupMode: .everyday
        )
        try await store.addRecordingSync(auto)
        try await store.addRecordingSync(legacy)
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(rows.first { $0.id == id }?.cleanupFilterReason, .triggers(["derivative", "integral"]))
        XCTAssertNil(rows.first { $0.id == legacyID }?.cleanupFilterReason)
        func label(_ row: Recording) -> String? {
            HistoryRow(recording: row, searchQuery: "", isPlaying: false, onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {}).filterChoiceLabel
        }
        XCTAssertEqual(label(try XCTUnwrap(rows.first { $0.id == id })), "Calculus · Auto: mentions derivative, integral")
        XCTAssertNil(label(try XCTUnwrap(rows.first { $0.id == legacyID })))
        var manual = auto
        manual.cleanupFilterReason = .manual
        XCTAssertNil(label(manual), "A hand-picked filter adds no label")
    }
}

/// The menu-bar Dictation Mode menu at both collection sizes.
@MainActor
final class DictationModeMenuTests: XCTestCase {
    private final class Target: NSObject {
        @objc func select(_ sender: Any?) {}
        @objc func auto() {}
        @objc func manage() {}
    }

    private func menu(_ filters: [CustomCleanupFilter], isAuto: Bool, selection: CleanupFilterSelection) -> NSMenu {
        let menu = NSMenu()
        let target = Target()
        DictationModeMenu.populate(
            menu, filters: filters, isAuto: isAuto, selection: selection, fallback: .builtIn(.writing), target: target,
            select: #selector(Target.select(_:)), selectAuto: #selector(Target.auto), manage: #selector(Target.manage)
        )
        return menu
    }

    func testFewFiltersStayFlatAndAutoIsChecked() {
        let filters = Array(Fixtures.all.prefix(3))
        let flat = menu(filters, isAuto: true, selection: .custom(filters[0].id))
        let titles = flat.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Auto"] + CleanupMode.allCases.map(\.displayName) + filters.map(\.name) + ["Manage Filters…"])
        XCTAssertEqual(flat.items.filter { $0.state == .on }.map(\.title), ["Auto"], "Under Auto nothing else is checked")
        XCTAssertTrue(flat.items[0].toolTip?.contains("Writing") == true)
        XCTAssertTrue(flat.items.allSatisfy { $0.submenu == nil })

        let manual = menu(filters, isAuto: false, selection: .custom(filters[1].id))
        XCTAssertEqual(manual.items.filter { $0.state == .on }.map(\.title), [filters[1].name])
    }

    func testFiftyFiltersMoveIntoSubmenusByBaseMode() {
        let filters = FilterCollectionStoreTests.fifty()
        let large = menu(filters, isAuto: false, selection: .custom(filters[10].id))
        let groups = large.items.filter { $0.submenu != nil }
        XCTAssertEqual(groups.map(\.title), FilterCollection.grouped(filters).map { "Based on \($0.mode.displayName) (\($0.filters.count))" })
        XCTAssertLessThan(large.items.count, 16, "The top level stays short")
        XCTAssertEqual(groups.flatMap { $0.submenu?.items ?? [] }.count, 50, "Every filter is reachable")
        XCTAssertEqual(groups.filter { $0.state == .mixed }.count, 1, "The group holding the filter in use is marked")
        XCTAssertEqual(groups.flatMap { $0.submenu?.items ?? [] }.filter { $0.state == .on }.map(\.title), [filters[10].name])
        XCTAssertEqual(groups.first?.submenu?.items.first?.representedObject as? String,
                       CleanupFilterSelection.custom(FilterCollection.grouped(filters)[0].filters[0].id).tag)
    }
}

/// Offscreen renders of the picker, Settings card, editor, Auto settings,
/// and a History row at both collection sizes, in light and dark.
@MainActor
final class FilterCollectionLayoutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FilterCollectionLayoutTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func render(_ view: some View, name: String, width: CGFloat = 560) throws {
        for scheme in [ColorScheme.light, .dark] {
            let content = view
                .padding()
                .frame(width: width)
                .background(Color(.windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: content)
            let size = host.fittingSize
            XCTAssertGreaterThan(size.height, 20)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
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
            if let directory = ProcessInfo.processInfo.environment["WORKFLOW_RENDER_DIR"] {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(attachment.name ?? name).png"))
            }
            XCTAssertFalse(window.isVisible, "Visual verification must stay offscreen")
            window.contentView = nil
        }
    }

    func testSmallCollectionPickerOffersAutoInOneMenu() throws {
        let filters = Array(Fixtures.all.prefix(3))
        let host = OffscreenHost(
            WritingFilterPicker(selection: .constant(.builtIn(.everyday)), customFilters: filters, isAuto: .constant(true), autoFallbackName: "Everyday")
                .defaultAppStorage(defaults),
            size: CGSize(width: 320, height: 40)
        )
        let popUp = try XCTUnwrap(host.popUps.first)
        XCTAssertEqual(popUp.titleOfSelectedItem, "Auto")
        XCTAssertTrue(popUp.itemTitles.contains("Auto"))
        XCTAssertTrue(filters.allSatisfy { popUp.itemTitles.contains($0.name) })
        try render(
            WritingFilterPicker(selection: .constant(.builtIn(.everyday)), customFilters: filters, isAuto: .constant(true)),
            name: "filters-picker-small", width: 320
        )
    }

    func testLargeCollectionPickerUsesSubmenusByBaseMode() throws {
        let filters = FilterCollectionStoreTests.fifty()
        let host = OffscreenHost(
            WritingFilterPicker(selection: .constant(.custom(filters[6].id)), customFilters: filters, isAuto: .constant(false))
                .defaultAppStorage(defaults),
            size: CGSize(width: 320, height: 40)
        )
        let popUp = try XCTUnwrap(host.popUps.first, "The large picker is still one AppKit menu button")
        XCTAssertTrue(popUp.pullsDown)
        XCTAssertEqual(popUp.title, filters[6].name, "The button names the filter in use")
        let items = try XCTUnwrap(popUp.menu).items
        let submenus = items.filter { $0.hasSubmenu }.map(\.title)
        XCTAssertEqual(submenus, FilterCollection.grouped(filters).map { "Based on \($0.mode.displayName) (\($0.filters.count))" })
        XCTAssertLessThan(items.count, 20, "The top level stays short")
        XCTAssertTrue(items.contains { $0.title == "Auto" })
        XCTAssertEqual(items.filter(\.hasSubmenu).flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem && $0.isEnabled }.count, 50)

        // Choosing from a submenu picks that filter by hand; Auto turns it on.
        final class Box { var selection: CleanupFilterSelection = .builtIn(.everyday); var auto = true }
        let box = Box()
        let live = OffscreenHost(
            WritingFilterPicker(
                selection: Binding(get: { box.selection }, set: { box.selection = $0; box.auto = false }),
                customFilters: filters,
                isAuto: Binding(get: { box.auto }, set: { box.auto = $0 })
            ).defaultAppStorage(defaults),
            size: CGSize(width: 320, height: 40)
        )
        let livePopUp = try XCTUnwrap(live.popUps.first)
        XCTAssertEqual(livePopUp.title, "Auto")
        let group = try XCTUnwrap(livePopUp.menu?.items.first { $0.title.hasPrefix("Based on Writing") }?.submenu)
        let target = try XCTUnwrap(FilterCollection.grouped(filters).first { $0.mode == .writing }?.filters.last)
        group.performActionForItem(at: group.indexOfItem(withTitle: target.name))
        XCTAssertEqual(box.selection, .custom(target.id))
        XCTAssertFalse(box.auto)
        let top = try XCTUnwrap(livePopUp.menu)
        // Index 0 is the pull-down's own title, never shown as a choice.
        top.performActionForItem(at: try XCTUnwrap(top.items.indices.dropFirst().first { top.items[$0].title == "Auto" }))
        XCTAssertTrue(box.auto)

        try render(
            WritingFilterPicker(selection: .constant(.custom(filters[6].id)), customFilters: filters, isAuto: .constant(false)),
            name: "filters-picker-large", width: 320
        )
    }

    func testSettingsCardWithFiftyFiltersSearchesAndGroups() throws {
        CustomCleanupFilterStore.save(FilterCollectionStoreTests.fifty(), to: defaults)
        // The group holding the filter in use starts open; the others start closed.
        defaults.set(FilterCollectionStoreTests.fifty()[6].id.uuidString, forKey: CustomCleanupFilterStore.selectedIDKey)
        let host = OffscreenHost(
            CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences()).defaultAppStorage(defaults),
            size: CGSize(width: 560, height: 3_600)
        )
        let fields = host.allViews().compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertTrue(fields.contains { $0.placeholderString?.hasPrefix("Search 50 filters") == true }, "Search appears past eight filters")
        try render(CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences()), name: "filters-card-large")
    }

    func testSettingsCardSmallAndEditorShowPhrases() throws {
        CustomCleanupFilterStore.save(Array(Fixtures.all.prefix(3)), to: defaults)
        try render(CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences()), name: "filters-card-small")
        var draft = Fixtures.chemistry
        draft.id = UUID()
        draft.name = "Organic chemistry"
        draft.triggers = ["alkene", "benzene ring"]
        let editor = OffscreenHost(
            CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences(), newDraft: draft).defaultAppStorage(defaults),
            size: CGSize(width: 560, height: 900)
        )
        let phraseField = editor.allViews().compactMap { $0 as? NSTextField }.first { $0.stringValue == "alkene, benzene ring" }
        XCTAssertNotNil(phraseField, "The editor shows the draft's phrases")
        XCTAssertFalse(editor.allViews().compactMap { $0 as? NSTextField }.contains { $0.placeholderString?.hasPrefix("Search") == true },
                       "No search for a short list")
        try render(CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences(), newDraft: draft), name: "filters-editor-phrases")
    }

    func testAutoSettingsAndHistoryRowRender() throws {
        CustomCleanupFilterStore.save(Fixtures.all, to: defaults)
        defaults.set(true, forKey: FilterAutoSettings.enabledKey)
        defaults.set(CleanupFilterSelection.custom(Fixtures.plain.id).tag, forKey: FilterAutoSettings.fallbackKey)
        try render(AutoFilterSettingsGroup(writingFilter: WritingFilterPreferences()), name: "filters-auto-settings")

        let id = UUID()
        let row = Recording(
            id: id, timestamp: Date(timeIntervalSince1970: 1_790_000_000), fileName: "\(id).wav",
            transcription: "Find the derivative of x² and then the integral from 0 to 1.", duration: 7, status: .completed,
            progress: 1, sourceFileURL: nil, cleanupSource: .ollama, cleanupMode: .homework, cleanupFilterName: "Calculus",
            cleanupFilterReason: .triggers(["derivative", "integral"])
        )
        try render(
            HistoryRow(
                recording: row, searchQuery: "", isPlaying: false, onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {},
                onRegenerateWith: { _ in }, regenerationFilters: Fixtures.all
            ),
            name: "filters-history-auto"
        )
    }
}

/// The assistant may propose phrases inside its existing review-then-save flow.
@MainActor
final class FilterAssistantTriggerTests: XCTestCase {
    private func reply(_ filter: [String: Any]) throws -> FilterAssistantReply {
        let data = try JSONSerialization.data(withJSONObject: ["message": "Here is a draft.", "filter": filter])
        return try FilterAssistantPrompt.parse(String(decoding: data, as: UTF8.self))
    }

    func testProposalCarriesValidPhrasesAndOlderRepliesStillParse() throws {
        let base: [String: Any] = ["name": "Calculus", "base_mode": "homework", "instructions": "Write math compactly.", "digits": true]
        XCTAssertEqual(try reply(base).proposal?.triggers, [], "Replies without phrases still parse")
        var withPhrases = base
        withPhrases["triggers"] = ["derivative", "Integral", "derivative"]
        XCTAssertEqual(try reply(withPhrases).proposal?.triggers, ["derivative", "Integral"])
        for bad: Any in [["the", "derivative"], ["one two three four"], "derivative", [1, 2], (1...9).map { "term\($0)" }] {
            var invalid = base
            invalid["triggers"] = bad
            XCTAssertThrowsError(try reply(invalid), "\(bad) is rejected whole, never trimmed")
        }
        XCTAssertTrue(FilterAssistantPrompt.systemPrompt.contains("\"triggers\""))
    }

    func testRefiningASavedFilterKeepsItsPhrasesInTheRequest() {
        let message = FilterAssistantPrompt.userMessage(
            request: "Add more hyphens", example: nil, context: nil, currentDraft: nil, existingFilter: Fixtures.calculus
        )
        XCTAssertTrue(message.contains("ITS TRIGGER PHRASES:\n<<<\nderivative, integral, limit, calculus\n>>>"))
        let plain = FilterAssistantPrompt.userMessage(
            request: "Add more hyphens", example: nil, context: nil, currentDraft: nil, existingFilter: Fixtures.plain
        )
        XCTAssertFalse(plain.contains("TRIGGER"), "Filters without phrases send what they always did")
    }

    func testSavingAProposalStoresItsPhrasesAndAPhraseConflictIsReported() throws {
        let suite = "FilterAssistantTriggerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try CustomCleanupFilterStore.upsert(Fixtures.codeReview, in: defaults)
        let session = FilterAssistantSession(target: .new, defaults: defaults)
        session.proposal = FilterAssistantProposal(
            name: "Calculus", baseMode: .homework, instructions: "Write math compactly.", triggers: ["derivative", "integral"]
        )
        let saved = try XCTUnwrap(session.save())
        XCTAssertEqual(saved.triggers, ["derivative", "integral"])

        let conflicting = FilterAssistantSession(target: .new, defaults: defaults)
        conflicting.proposal = FilterAssistantProposal(
            name: "Reviews", baseMode: .technical, instructions: "Be terse.", triggers: ["stack trace", "diff"]
        )
        XCTAssertNil(conflicting.save())
        XCTAssertEqual(conflicting.errorMessage, "“stack trace” already picks “Code review”. Each phrase can pick only one filter.")
    }
}
