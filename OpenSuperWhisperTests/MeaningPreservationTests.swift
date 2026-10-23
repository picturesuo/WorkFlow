import XCTest
@testable import OpenSuperWhisper

/// Provider rewrites the guard used to accept although they dropped meaning
/// the speaker said: the whole dictation (EMPTY), a negation, a number in a
/// built-in mode, or a path, flag, or URL. Each falls back to the local
/// transcript in every mode.
final class MeaningPreservationGuardTests: XCTestCase {
    private func rejects(
        _ cleaned: String,
        source: String,
        mode: CleanupMode = .everyday,
        formatting: Bool? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CleanupGuard.postprocess(
                cleaned, source: source, mode: mode, allowsNumberFormatting: formatting ?? mode.formatsNumbers
            ),
            "Accepted \(cleaned) for \(source) in \(mode)",
            file: file,
            line: line
        )
    }

    private func accepts(
        _ cleaned: String,
        source: String,
        mode: CleanupMode = .everyday,
        formatting: Bool? = nil,
        expected: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            try CleanupGuard.postprocess(
                cleaned, source: source, mode: mode, allowsNumberFormatting: formatting ?? mode.formatsNumbers
            ),
            expected ?? cleaned,
            file: file,
            line: line
        )
    }

    func testEmptyIsAcceptedOnlyForFillerOnlySources() {
        for mode in CleanupMode.allCases {
            rejects("EMPTY", source: "Wire the 2,400 dollars to account 7731 before Friday, not after.", mode: mode)
            rejects("EMPTY", source: "Call Sarah about the contract.", mode: mode)
            accepts("EMPTY", source: "Um, uh.", mode: mode, expected: "")
        }
        accepts("EMPTY", source: "uh, you know, um, hmm", expected: "")
        accepts("EMPTY", source: "So, like, I mean, well...", expected: "")
    }

    func testDroppedNegationFallsBackInEveryMode() {
        for mode in CleanupMode.allCases {
            rejects("Delete the backup folder.", source: "do not delete the backup folder", mode: mode)
            rejects("Push to main.", source: "never push to main", mode: mode)
            rejects("I can make the meeting.", source: "I can't make the meeting", mode: mode)
            rejects("We can merge.", source: "we cannot merge", mode: mode)
            rejects("There were errors in the build.", source: "there were no errors in the build", mode: mode)
            rejects("Ship it with tests.", source: "ship it without tests", mode: mode)
        }
        rejects("Don't delete it, then push.", source: "don't delete it and don't push", mode: .technical)
    }

    func testKeptOrRewordedNegationIsAccepted() {
        accepts("Don't delete the backup folder.", source: "um do not delete the backup folder")
        accepts("We can't merge yet.", source: "we cannot merge yet")
        accepts("I won't be there.", source: "I will not be there")
        accepts("I wasn't sure, so I didn't send it.", source: "I I wasn't sure so I didn’t send it")
        accepts("Never push to main without review.", source: "never push to main without review", mode: .technical)
        accepts("x ≠ 5", source: "x is not equal to five", mode: .homework)
    }

    func testCorrectedOrRepeatedNegationMayBeDropped() {
        accepts("Do send it.", source: "don't, sorry, do send it")
        accepts("Don't touch that.", source: "don't don't touch that")
        accepts("Meet at six.", source: "meet at five, no, six")
        accepts("Bring twelve plates.", source: "bring ten no wait twelve plates")
        accepts("Bring twelve plates.", source: "bring ten no twelve plates")
        accepts("Yeah, that's fine, I'll do it later.", source: "yeah no that's fine I'll do it later")
        // A correction word with no pause before it is part of the sentence.
        rejects("Wait for me.", source: "don't wait for me")
        rejects("I'm actually sure.", source: "I'm not actually sure")
        rejects("Six people came.", source: "no six people came", mode: .technical)
    }

    func testDroppedNumbersFallBackInBuiltInModesToo() {
        rejects("Call me later.", source: "call me at five", mode: .everyday)
        rejects("Retry the job.", source: "retry the job 3 times", mode: .technical)
        rejects("Start the server on the default port.", source: "start the server on port 8080", mode: .technical)
        rejects("Allow some minutes.", source: "allow twelve to fifteen minutes", mode: .everyday)
        accepts("Call me at five.", source: "um call me at like five", mode: .everyday)
        accepts("Retry the job 3 times.", source: "so retry the job 3 times", mode: .technical)
        // A number restated in other words is kept, not dropped.
        accepts("Run it twice.", source: "run it two times, twice", mode: .technical)
    }

    func testDroppedOrChangedIdentifiersFallBack() {
        for mode in CleanupMode.allCases {
            rejects("Run the tests.", source: "run npm test in packages/api", mode: mode)
            rejects("Use git push --force.", source: "use git push --force-with-lease", mode: mode)
            rejects("Open the docs.", source: "open https://example.com/docs", mode: mode)
            rejects("Email me.", source: "email me at sam@example.com", mode: mode)
            rejects("Rename the user id column.", source: "rename the user_id column", mode: mode)
            rejects("Wrap it in use effect.", source: "wrap it in useEffect", mode: mode)
            rejects("Edit the readme.", source: "edit README.md", mode: mode)
        }
    }

    func testKeptIdentifiersAreAccepted() {
        accepts("Run `npm test` in `packages/api`.", source: "um run npm test in packages/api", mode: .technical)
        accepts("Packages/api is failing.", source: "packages/api is failing")
        accepts("Use git push --force-with-lease.", source: "so use git push --force-with-lease", mode: .technical)
        accepts("Open https://example.com/docs.", source: "open https://example.com/docs.")
        accepts("Email sam@example.com about README.md.", source: "uh email sam@example.com about README.md")
        accepts("Rename user_id in useEffect.", source: "rename user_id in useEffect", mode: .technical)
        accepts("GitHub is down.", source: "um GitHub's down")
    }

    func testOrdinaryProseIsNotTreatedAsIdentifiers() {
        accepts("Bring snacks or drinks, for example chips.", source: "bring snacks and/or drinks e.g. chips")
        accepts("I was thinking we could grab lunch.", source: "um so I was thinking we could like grab lunch")
        accepts("It's at 9 a.m. in the U.S. office.", source: "it's at 9 a.m. in the U.S. office")
    }
}

/// Cut-off or filtered provider replies end early, so the guard sees a short
/// but otherwise valid rewrite. They must fall back to the local transcript
/// instead of inserting the first part of the dictation.
final class CleanupReplyCompletenessTransportTests: XCTestCase {
    private var session: URLSession!
    private var requests = 0
    private var failures: [String?] = []
    private let source = "Um, tell the team the launch moved to Thursday and the review is still on."
    private let truncated = "Tell the team the launch moved to Thursday"
    private let complete = "Tell the team the launch moved to Thursday and the review is still on."

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupURLProtocol.self]
        session = URLSession(configuration: configuration)
        requests = 0
        failures = []
    }

    override func tearDown() {
        session.invalidateAndCancel()
        CleanupURLProtocol.handler = nil
        super.tearDown()
    }

    private func pipeline(_ provider: any TranscriptCleanupProviding) -> TranscriptCleanupPipeline {
        TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) },
            failureRecorder: { [weak self] in self?.failures.append($0) }
        )
    }

    private func respond(_ body: String) {
        CleanupURLProtocol.handler = { [weak self] request in
            self?.requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private var bedrock: BedrockCleanupProvider {
        BedrockCleanupProvider(
            service: BedrockCleanupService(session: session),
            apiKey: "bedrock-test",
            configuration: BedrockCleanupConfiguration()
        )
    }

    private func compatible(_ id: CleanupProviderID) -> OpenAIChatCleanupService {
        switch id {
        case .ollama:
            OpenAIChatCleanupService(
                providerID: .ollama, baseURL: "http://localhost:11434", modelID: "llama3.2:3b",
                apiKey: nil, timeout: 1, session: session
            )
        case .azureOpenAI:
            OpenAIChatCleanupService(
                providerID: .azureOpenAI, baseURL: "https://example.openai.azure.com", modelID: "cleanup",
                apiKey: "azure-test", timeout: 1, session: session
            )
        default:
            OpenAIChatCleanupService(
                providerID: .openAICompatible, baseURL: "https://example.com/v1", modelID: "fast-model",
                apiKey: "compatible-test", timeout: 1, session: session
            )
        }
    }

    /// The text that would be saved and, with the post-processing space,
    /// inserted is the whole local transcript.
    @MainActor
    private func assertFallsBack(
        _ result: TranscriptCleanupOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.source, .rawFallback, file: file, line: line)
        XCTAssertEqual(result.text, source, file: file, line: line)
        XCTAssertEqual(IndicatorViewModel.applyPostProcessing(result.text).hasPrefix(source), true, file: file, line: line)
    }

    func testBedrockReplyCutOffAtTheTokenLimitFallsBack() async {
        for reason in ["max_tokens", "guardrail_intervened", "content_filtered"] {
            respond(#"{"output":{"message":{"content":[{"text":"\#(truncated)"}]}},"stopReason":"\#(reason)","usage":{"inputTokens":40,"outputTokens":12}}"#)
            await assertFallsBack(await pipeline(bedrock).finalize(source))
        }
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(failures, Array(repeating: TranscriptCleanupPipeline.safeFailureMessage, count: 3))
    }

    func testBedrockFinishedReplyIsKept() async {
        respond(#"{"output":{"message":{"content":[{"text":"\#(complete)"}]}},"stopReason":"end_turn","usage":{"inputTokens":40,"outputTokens":16}}"#)
        let result = await pipeline(bedrock).finalize(source)
        XCTAssertEqual(result.source, .bedrock)
        XCTAssertEqual(result.text, complete)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(failures, [nil])
    }

    func testOpenAICompatibleAndAzureRepliesCutOffAtTheTokenLimitFallBack() async {
        for id in [CleanupProviderID.openAICompatible, .azureOpenAI] {
            for reason in ["length", "content_filter"] {
                respond(#"{"choices":[{"message":{"role":"assistant","content":"\#(truncated)"},"finish_reason":"\#(reason)"}],"usage":{"prompt_tokens":30,"completion_tokens":12}}"#)
                await assertFallsBack(await pipeline(compatible(id)).finalize(source))
            }
            respond(#"{"choices":[{"message":{"role":"assistant","content":"\#(complete)"},"finish_reason":"stop"}]}"#)
            let kept = await pipeline(compatible(id)).finalize(source)
            XCTAssertEqual(kept.text, complete, "\(id)")
        }
        XCTAssertEqual(requests, 6)
        XCTAssertEqual(failures.compactMap { $0 }.count, 4)
    }

    func testOllamaReplyCutOffAtTheTokenLimitFallsBack() async {
        respond(#"{"message":{"role":"assistant","content":"\#(truncated)"},"done_reason":"length","prompt_eval_count":30,"eval_count":12}"#)
        await assertFallsBack(await pipeline(compatible(.ollama)).finalize(source))
        respond(#"{"message":{"role":"assistant","content":"\#(complete)"},"done_reason":"stop","prompt_eval_count":30,"eval_count":16}"#)
        let kept = await pipeline(compatible(.ollama)).finalize(source)
        XCTAssertEqual(kept.source, .ollama)
        XCTAssertEqual(kept.text, complete)
        XCTAssertEqual(requests, 2)
    }

    func testRepliesWithoutAStopReasonAreStillAccepted() async {
        respond(#"{"choices":[{"message":{"role":"assistant","content":"\#(complete)"}}]}"#)
        let result = await pipeline(compatible(.openAICompatible)).finalize(source)
        XCTAssertEqual(result.source, .openAICompatible)
        XCTAssertEqual(result.text, complete)
    }

    /// EMPTY used to discard a spoken dictation outright: the indicator drops
    /// an empty cleanup without saving or pasting it.
    func testEmptyReplyForRealSpeechKeepsTheLocalTranscript() async {
        respond(#"{"choices":[{"message":{"role":"assistant","content":"EMPTY"}}]}"#)
        await assertFallsBack(await pipeline(compatible(.openAICompatible)).finalize(source))
        let filler = await pipeline(compatible(.openAICompatible)).finalize("Um, uh.")
        XCTAssertEqual(filler.source, .openAICompatible)
        XCTAssertEqual(filler.text, "")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(failures, [TranscriptCleanupPipeline.safeFailureMessage, nil])
    }

    func testDroppedNegationOverTheWireKeepsTheLocalTranscript() async {
        let spoken = "Um, do not deploy the 2 services until Friday."
        respond(#"{"output":{"message":{"content":[{"text":"Deploy the 2 services until Friday."}]}},"stopReason":"end_turn"}"#)
        let result = await pipeline(bedrock).finalize(spoken)
        XCTAssertEqual(result.source, .rawFallback)
        XCTAssertEqual(result.text, spoken)
        XCTAssertEqual(requests, 1)
    }
}

/// Real speech through the real recognizer and the real provider transport.
/// The reference recording says "ask not what your country can do for you",
/// so a rewrite that drops "not" inverts it.
final class RecognizerToCleanupTraceTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var requests = 0
    private var failures: [String?] = []

    override func tearDown() {
        CleanupURLProtocol.handler = nil
        super.tearDown()
    }

    private func reply(_ content: String, finishReason: String = "stop") throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content], "finish_reason": finishReason]]
        ])
        CleanupURLProtocol.handler = { [weak self] request in
            self?.requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    func testRecognizedNegationSurvivesEveryUnsafeProviderReply() async throws {
        let modelDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
        let audioURL = Self.repoRoot.appendingPathComponent("jfk.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelDirectory.path)
                && FileManager.default.fileExists(atPath: audioURL.path),
            "Cached Parakeet v3 model and reference audio are required"
        )
        let prefs = AppPreferences.shared
        let originalVersion = prefs.fluidAudioModelVersion
        let originalLanguage = prefs.whisperLanguage
        defer {
            prefs.fluidAudioModelVersion = originalVersion
            prefs.whisperLanguage = originalLanguage
        }
        prefs.fluidAudioModelVersion = "v3"
        prefs.whisperLanguage = "en"

        let engine = FluidAudioEngine()
        try await engine.initialize()
        let recognized = try await engine.transcribeAudio(url: audioURL, settings: Settings())
        let negation = try XCTUnwrap(
            recognized.range(of: #"\bnot\b"#, options: [.regularExpression, .caseInsensitive]),
            "Unexpected recognizer output: \(recognized)"
        )
        let local = VocabularyRewriter.apply(recognized, entries: [])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: {
                OpenAIChatCleanupService(
                    providerID: .openAICompatible, baseURL: "https://example.com/v1", modelID: "fast-model",
                    apiKey: "compatible-test", timeout: 5, session: session
                )
            },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) },
            failureRecorder: { [weak self] in self?.failures.append($0) }
        )

        // Negative control: a faithful rewrite is kept as the provider wrote it.
        let faithful = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        try reply(faithful)
        let kept = await pipeline.finalize(recognized)
        XCTAssertEqual(kept.source, .openAICompatible)
        XCTAssertEqual(kept.text, faithful)

        var inverted = recognized
        inverted.removeSubrange(negation.lowerBound..<recognized.index(after: negation.upperBound))
        let truncated = String(recognized[..<negation.upperBound])
        for (content, reason) in [(inverted, "stop"), (truncated, "length"), ("EMPTY", "stop")] {
            try reply(content, finishReason: reason)
            let result = await pipeline.finalize(recognized)
            XCTAssertEqual(result.source, .rawFallback, content)
            XCTAssertEqual(result.text, local, content)
            XCTAssertNotNil(result.text.range(of: #"\bnot\b"#, options: [.regularExpression, .caseInsensitive]))
        }
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(failures.compactMap { $0 }.count, 3)
        let trace = XCTAttachment(
            string: "Recognized: \(recognized)\nInverted reply rejected: \(inverted)\nTruncated reply rejected: \(truncated)"
        )
        trace.name = "recognizer-cleanup-trace"
        trace.lifetime = .keepAlways
        add(trace)
    }
}
