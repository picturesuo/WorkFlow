import XCTest
@testable import OpenSuperWhisper

/// The cases the correction-evidence scout observed the guard accepting. Each
/// must fall back to the local transcript before Homework may write digits.
final class NumericPreservationGuardTests: XCTestCase {
    private func rejects(
        _ cleaned: String,
        source: String,
        mode: CleanupMode = .homework,
        formatting: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CleanupGuard.postprocess(cleaned, source: source, mode: mode, allowsNumberFormatting: formatting),
            "Accepted \(cleaned)",
            file: file,
            line: line
        )
    }

    private func accepts(
        _ cleaned: String,
        source: String,
        mode: CleanupMode = .homework,
        formatting: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            try CleanupGuard.postprocess(cleaned, source: source, mode: mode, allowsNumberFormatting: formatting),
            cleaned,
            file: file,
            line: line
        )
    }

    func testDroppedSourceNumbersFallBackWhenNumbersMayBeFormatted() {
        rejects("Allow some minutes.", source: "allow twelve to fifteen minutes")
        rejects("Allow some minutes.", source: "allow 12 to 15 minutes")
        rejects("We need chairs by 1984.", source: "we need twenty five chairs by nineteen eighty four")
        rejects("Score was high.", source: "score was ninety five", mode: .writing)
    }

    func testChangedWordFormValuesFallBackInEveryMode() {
        rejects("I have six apples.", source: "I have five apples", mode: .everyday, formatting: false)
        rejects("I have six apples.", source: "I have five apples", mode: .technical, formatting: false)
        rejects("About twenty-six people.", source: "about 25 people", mode: .everyday)
        rejects("About twenty-six people.", source: "about 25 people", mode: .everyday, formatting: false)
    }

    func testInventedPercentSignsAndOperatorsFallBack() {
        rejects("40% of the class.", source: "forty of the class")
        rejects("5 - 3", source: "five plus three")
        rejects("x² + 1", source: "x plus one")
        rejects("-4 degrees", source: "four degrees")
        rejects("2x + 5 = 9", source: "two x plus five is nine")
        rejects("5 + 3", source: "five and three")
        // Invented signs are rejected even where digits are not formatted.
        rejects("10% off", source: "10 off", mode: .everyday, formatting: false)
        rejects("x = 5", source: "x is 5", mode: .technical, formatting: false)
    }

    func testGroundedHomeworkFormattingIsAccepted() {
        accepts("About 10% of 105 students in 2026.", source: "about ten percent of one hundred five students in twenty twenty six")
        accepts("Raise it 15%.", source: "raise it fifteen percent")
        accepts("2x + 5 = 9", source: "two x plus five equals nine")
        accepts("5 - 3 = 2", source: "five minus three equals two")
        accepts("It was -4 degrees.", source: "it was negative four degrees")
        accepts("x² + 1", source: "x squared plus one")
        accepts("Allow 12-15 minutes.", source: "allow twelve to fifteen minutes")
        accepts("The third try took 2.5 hours.", source: "the third try took two point five hours")
    }

    func testDroppedOrMovedPercentsAndSignsFallBackInEveryMode() {
        let percent = "about fifteen percent of the one hundred five students finished by twenty twenty six"
        rejects("About 15 of the 105 students finished by 2026.", source: percent)
        rejects("About 15 of the 105% students finished by 2026.", source: percent)
        rejects("The low was 4 degrees at night.", source: "the low was negative four degrees at night")
        rejects("The low was 4 and -5 degrees.", source: "the low was negative four and five degrees")
        rejects("Growth was 15, then 1.5%.", source: "growth was fifteen percent then one point five")
        for mode in [CleanupMode.everyday, .technical, .writing] {
            let formatting = mode.formatsNumbers
            rejects("About fifteen of the students finished early.", source: "about fifteen percent of the students finished early",
                    mode: mode, formatting: formatting)
            rejects("The low was four degrees at night.", source: "the low was negative four degrees at night",
                    mode: mode, formatting: formatting)
            rejects("Set the offset to three pixels.", source: "set the offset to minus three pixels",
                    mode: mode, formatting: formatting)
        }
    }

    func testKeptPercentsAndSignsAreAccepted() {
        accepts("About 15% of the 105 students finished by 2026.",
                source: "about fifteen percent of the one hundred five students finished by twenty twenty six")
        accepts("Attendance hit 105%.", source: "attendance hit one hundred five percent")
        accepts("About 15 percent of the students finished early.", source: "about fifteen percent of the students finished early")
        accepts("About fifteen percent of the students finished early.", source: "about fifteen percent of the students finished early",
                mode: .everyday, formatting: false)
        accepts("The low was −4 degrees at night.", source: "the low was negative four degrees at night")
        accepts("The low was minus four degrees.", source: "the low was minus four degrees", mode: .technical, formatting: false)
        accepts("Aim for ±5%.", source: "aim for plus or minus five percent")
        accepts("It was -5 degrees.", source: "it was negative four, sorry, negative five degrees")
    }

    func testLiteralIdentifiersAndSourceDigitsSurvive() {
        accepts("Read ES30 and CE11 by 5:30.", source: "read ES30 and CE11 by five thirty")
        rejects("Read ES and CE11 by 5:30.", source: "read ES30 and CE11 by five thirty")
        accepts("Version 2 of the 10% rule.", source: "version 2 of the 10% rule")
    }

    func testSpokenCorrectionsMayDropTheReplacedNumber() {
        accepts("The answer is 6.", source: "the answer is five, sorry, six")
        accepts("Bring 12 plates.", source: "bring ten no wait twelve plates")
        rejects("Bring plates.", source: "bring ten no wait twelve plates")
    }

    func testAmbiguousNumberWordsAreNotTreatedAsQuantities() {
        accepts("Oh, this one is first-rate.", source: "oh this one is first rate", mode: .everyday, formatting: false)
        accepts("It's the one I want.", source: "um it's the one I want", mode: .homework)
        accepts("First, plates were not a plan; second, I missed it.", source: "first plates were not a plan and second I missed it", mode: .writing)
    }

    func testBuiltInEverydayAndTechnicalStillForbidNewDigitsAndDropsAreAllowed() {
        rejects("I have 5 apples.", source: "I have five apples", mode: .everyday, formatting: false)
        // Self-correction and repetition removal in built-in modes may still drop a number.
        accepts("Run it twice.", source: "run it two times, twice", mode: .technical, formatting: false)
    }
}

/// A model that ignores Homework's digit rule, as Nova Micro did on the
/// user's own Homework dictations: it only capitalizes and ends the sentence.
/// The real guard validates its reply, as the shipped providers do.
private final class WordKeepingCleanup: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .ollama
    var reply: ((String) -> String)?

    func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
        var text = reply?(transcript) ?? transcript.prefix(1).uppercased() + transcript.dropFirst()
        if let last = text.last, !".!?".contains(last) { text += "." }
        return CleanupProviderResult(
            text: try CleanupGuard.postprocess(text, source: transcript, mode: filter.mode, allowsNumberFormatting: filter.allowsNumberFormatting),
            inputTokens: nil, outputTokens: nil, modelID: "word-keeping"
        )
    }
}

/// Homework writes spoken quantities as digits even when the model keeps the
/// words; the guard still checks the result, and no other mode, filter, or
/// fallback changes number form.
final class HomeworkNumberFormattingTests: XCTestCase {
    private let spoken = "the price went up fifteen percent in twenty twenty six and one hundred five students passed"

    private func finalize(
        _ spoken: String,
        filter: CleanupFilterSnapshot,
        provider: (any TranscriptCleanupProviding)? = nil
    ) async -> TranscriptCleanupOutcome {
        let model = provider ?? WordKeepingCleanup()
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true }, providerResolver: { model }, vocabularyProvider: { [] },
            appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil }, filterProvider: { filter },
            failureRecorder: { _ in }
        )
        return await pipeline.finalize(spoken)
    }

    func testHomeworkWritesQuantitiesAsDigitsWhenTheModelKeepsWords() async {
        let result = await finalize(spoken, filter: .builtIn(.homework))
        XCTAssertEqual(result.source, .ollama)
        XCTAssertEqual(result.cleanupMode, .homework)
        XCTAssertEqual(result.text, "The price went up 15% in 2026 and 105 students passed.")
    }

    func testOtherModesCustomFiltersAndFallbacksKeepTheSpokenForm() async {
        let words = "The price went up fifteen percent in twenty twenty six and one hundred five students passed."
        for mode in [CleanupMode.writing, .technical, .everyday] {
            let result = await finalize(spoken, filter: .builtIn(mode))
            XCTAssertEqual(result.text, words, "\(mode) keeps the number form")
        }
        let wordsFilter = CleanupFilterSnapshot(mode: .homework, customName: "Words", customInstructions: "Spell numbers as words.")
        let custom = await finalize(spoken, filter: wordsFilter)
        XCTAssertEqual(custom.text, words, "A custom filter's own number style governs")

        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true }, providerResolver: { throw CleanupProviderError.missingCredential("Bedrock") },
            vocabularyProvider: { [] }, appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.homework) }, failureRecorder: { _ in }
        )
        let fallback = await pipeline.finalize(spoken)
        XCTAssertEqual(fallback.source, .rawFallback)
        XCTAssertEqual(fallback.text, spoken, "A fallback keeps the original transcript")
    }

    func testFormatterWritesSpokenQuantitiesAsDigits() {
        let written: [(String, String)] = [
            ("Fifteen percent, twenty twenty-six, one hundred five.", "15%, 2026, 105."),
            ("The price went up ten percent in twenty twenty six.", "The price went up 10% in 2026."),
            ("There were fifteen students.", "There were 15 students."),
            ("A hundred and five students came.", "105 students came."),
            ("We waited two point five hours.", "We waited 2.5 hours."),
            ("About twenty five thousand people.", "About 25,000 people."),
            ("Only one percent agreed.", "Only 1% agreed."),
            ("Growth was 15 percent.", "Growth was 15%."),
            ("It was negative twelve degrees.", "It was negative 12 degrees."),
        ]
        for (text, expected) in written {
            XCTAssertEqual(HomeworkNumberFormatter.format(text), expected)
        }
    }

    func testFormatterKeepsWordsThatAreNotPlainQuantities() {
        let kept = [
            "It's the one I want.",
            "We have two cats and zero dogs.",
            "Meet at eleven o'clock.",
            "The third try worked.",
            "Meet at five thirty.",
            "Call four seven two one.",
            "Three quarters of the class agreed.",
            "She read “Twenty Thousand Leagues” twice.",
            "We watched Ocean's Eleven again.",
            "The Ten Commandments came up.",
            "A three-bedroom house.",
            "Three million people.",
        ]
        for text in kept {
            XCTAssertEqual(HomeworkNumberFormatter.format(text), text)
        }
    }

    func testSignsAndPercentsStayWithTheirNumbersAndDigitsAreNeverJoined() async {
        let signed = await finalize("the low was negative twelve degrees and growth was fifteen percent", filter: .builtIn(.homework))
        XCTAssertEqual(signed.text, "The low was negative 12 degrees and growth was 15%.")
        // A year beside another number becomes digits; the other number stays
        // words, so "2026 105" never reads as one joined value.
        let backToBack = await finalize("in twenty twenty six one hundred five students passed", filter: .builtIn(.homework))
        XCTAssertEqual(backToBack.text, "In 2026 one hundred five students passed.")
    }

    func testDigitsTheGuardRefusesKeepTheModelText() async {
        // Two separate twenties, not the year 2020: the model drops the comma,
        // and the digit form it would suggest is not what the speaker said.
        let model = WordKeepingCleanup()
        model.reply = { _ in "The scores were twenty twenty and thirty" }
        let result = await finalize("the scores were twenty, twenty and thirty", filter: .builtIn(.homework), provider: model)
        XCTAssertEqual(result.source, .ollama)
        XCTAssertEqual(result.text, "The scores were twenty twenty and thirty.")
    }
}
