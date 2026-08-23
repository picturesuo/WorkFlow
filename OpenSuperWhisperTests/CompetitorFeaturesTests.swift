import XCTest
@testable import OpenSuperWhisper

final class VocabularyAndRulesTests: XCTestCase {
    func testVocabularyUsesLiteralWholePhraseMatches() {
        let entries = [
            VocabularyEntry(spoken: "fable orchestrator", replacement: "Fable Orchestrator"),
            VocabularyEntry(spoken: "codex", replacement: "Codex")
        ]

        XCTAssertEqual(
            VocabularyRewriter.apply("Use fable orchestrator with codex.", entries: entries),
            "Use Fable Orchestrator with Codex."
        )
        XCTAssertEqual(
            VocabularyRewriter.apply("The codexical name stays unchanged.", entries: entries),
            "The codexical name stays unchanged."
        )
    }

    func testDisabledVocabularyEntryIsIgnored() {
        let entries = [VocabularyEntry(spoken: "chat", replacement: "Chat", isEnabled: false)]
        XCTAssertEqual(VocabularyRewriter.apply("open chat", entries: entries), "open chat")
    }

    func testRuleLookupUsesExactBundleIdentifierIgnoringCase() {
        let rules = [TargetAppRule(bundleID: "com.apple.TextEdit", appName: "TextEdit")]
        XCTAssertEqual(
            TargetAppRuleStore.rule(for: "COM.APPLE.TEXTEDIT", in: rules)?.appName,
            "TextEdit"
        )
        XCTAssertNil(TargetAppRuleStore.rule(for: "com.apple.TextEdit.beta", in: rules))
    }

    func testRuleCleanupBehaviorOverridesGlobalDefault() {
        XCTAssertFalse(TargetAppRuleStore.cleanupEnabled(
            rule: TargetAppRule(bundleID: "com.example.off", appName: "Off", cleanupBehavior: .disabled),
            globalDefault: true
        ))
        XCTAssertTrue(TargetAppRuleStore.cleanupEnabled(
            rule: TargetAppRule(bundleID: "com.example.on", appName: "On", cleanupBehavior: .enabled),
            globalDefault: false
        ))
        XCTAssertTrue(TargetAppRuleStore.cleanupEnabled(rule: nil, globalDefault: true))
    }

    func testRuleSanitizationCapsAndDeduplicatesImports() {
        let oversized = String(repeating: "x", count: TargetAppRuleStore.maximumInstructionLength + 20)
        var rules = (0..<(TargetAppRuleStore.maximumEntries + 20)).map { index in
            TargetAppRule(
                bundleID: " com.example.app\(index) ",
                appName: String(repeating: "A", count: TargetAppRuleStore.maximumAppNameLength + 10),
                cleanupInstruction: oversized
            )
        }
        rules.insert(TargetAppRule(bundleID: "COM.EXAMPLE.APP0", appName: "Duplicate"), at: 1)
        rules.insert(TargetAppRule(bundleID: "   ", appName: "Empty"), at: 2)

        let sanitized = TargetAppRuleStore.sanitized(rules)

        XCTAssertEqual(sanitized.count, TargetAppRuleStore.maximumEntries)
        XCTAssertEqual(sanitized.first?.bundleID, "com.example.app0")
        XCTAssertEqual(sanitized.first?.appName.count, TargetAppRuleStore.maximumAppNameLength)
        XCTAssertEqual(sanitized.first?.cleanupInstruction.count, TargetAppRuleStore.maximumInstructionLength)
        XCTAssertEqual(sanitized.filter { $0.bundleID.lowercased() == "com.example.app0" }.count, 1)
    }

    func testPromptCapsUserControlledInstruction() {
        let prompt = CleanupPromptBuilder.systemPrompt(
            instruction: String(repeating: "instruction ", count: 100)
        )

        XCTAssertTrue(prompt.contains(CleanupPromptBuilder.baseSystemPrompt))
        XCTAssertLessThan(prompt.count, CleanupPromptBuilder.baseSystemPrompt.count + 600)
        XCTAssertFalse(prompt.contains(String(repeating: "instruction ", count: 50)))
    }

    func testCleanupGuardRejectsAssistantStyleExpansion() {
        XCTAssertThrowsError(try CleanupGuard.postprocess("Sure, here is an answer.", source: "Answer this")) {
            XCTAssertEqual($0 as? CleanupGuardError, .unsafeRewrite)
        }
    }

    func testLongTranscriptIsSplitWithoutDroppingText() {
        let words = (0..<120).map { "word\($0)" }
        let source = words.joined(separator: " ")
        let chunks = TranscriptChunker.chunks(source, characterLimit: 120)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 120 })
        XCTAssertEqual(chunks.map { $0.text + $0.separatorAfter }.joined(), source)
    }

    func testChunkingPreservesParagraphBoundary() {
        let source = String(repeating: "a", count: 60) + "\n\n" + String(repeating: "b", count: 60)
        let chunks = TranscriptChunker.chunks(source, characterLimit: 100)

        XCTAssertEqual(chunks.first?.separatorAfter, "\n\n")
        XCTAssertEqual(chunks.map { $0.text + $0.separatorAfter }.joined(), source)
    }

    func testCleanupGuardRejectsSuspiciouslyShortLongResponse() {
        XCTAssertThrowsError(
            try CleanupGuard.postprocess("Too short.", source: String(repeating: "long transcript ", count: 60))
        ) {
            XCTAssertEqual($0 as? CleanupGuardError, .unsafeRewrite)
        }
    }
}

final class OpenAIChatCleanupServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        CleanupURLProtocol.handler = nil
        super.tearDown()
    }

    func testOllamaUsesLocalChatEndpointWithoutAuthorization() async throws {
        CleanupURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try Self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let options = try XCTUnwrap(json["options"] as? [String: Any])
            XCTAssertEqual(options["num_predict"] as? Int, 64)
            return Self.response(
                request,
                body: #"{"message":{"role":"assistant","content":"Send the report."},"prompt_eval_count":20,"eval_count":4}"#
            )
        }

        let service = OpenAIChatCleanupService(
            providerID: .ollama,
            baseURL: "http://localhost:11434",
            modelID: "llama3.2:3b",
            apiKey: nil,
            timeout: 1,
            session: session
        )
        let result = try await service.clean(
            transcript: "Um, send the report.",
            systemPrompt: CleanupPromptBuilder.baseSystemPrompt
        )

        XCTAssertEqual(result.text, "Send the report.")
        XCTAssertEqual(result.inputTokens, 20)
        XCTAssertEqual(result.outputTokens, 4)
    }

    func testOpenAICompatibleUsesBearerAndChatCompletions() async throws {
        CleanupURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            return Self.response(
                request,
                body: #"{"choices":[{"message":{"role":"assistant","content":"Ship it."}}],"usage":{"prompt_tokens":18,"completion_tokens":3}}"#
            )
        }

        let service = OpenAIChatCleanupService(
            providerID: .openAICompatible,
            baseURL: "https://example.com/v1",
            modelID: "fast-model",
            apiKey: "test-key",
            timeout: 1,
            session: session
        )
        let result = try await service.clean(
            transcript: "Um, ship it.",
            systemPrompt: CleanupPromptBuilder.baseSystemPrompt
        )

        XCTAssertEqual(result.text, "Ship it.")
        XCTAssertEqual(result.inputTokens, 18)
        XCTAssertEqual(result.outputTokens, 3)
    }

    func testRemotePlainHTTPIsRejected() async {
        let service = OpenAIChatCleanupService(
            providerID: .openAICompatible,
            baseURL: "http://example.com/v1",
            modelID: "fast-model",
            apiKey: "test-key",
            timeout: 1,
            session: session
        )

        do {
            _ = try await service.clean(
                transcript: "Keep this private.",
                systemPrompt: CleanupPromptBuilder.baseSystemPrompt
            )
            XCTFail("Expected insecure remote HTTP to be rejected")
        } catch let error as OpenAIChatCleanupError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIPv6LoopbackIsAcceptedAsLocal() {
        XCTAssertTrue(OpenAIChatCleanupService.isLocalBaseURL("http://[::1]:11434"))
    }

    private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

final class ProviderPipelineTests: XCTestCase {
    func testExhaustedBedrockBudgetSkipsRemoteProvider() async {
        let provider = FakeBedrockCleanupProvider()
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: {
                BedrockBudgetStatus(spentUSD: 0.25, limitUSD: 0.25)
            }
        )

        let result = await pipeline.finalize("Keep this local.")

        XCTAssertEqual(result.text, "Keep this local.")
        XCTAssertEqual(result.source, .budgetLimited)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testUnknownBedrockPriceDoesNotClaimToEnforceDollarBudget() {
        XCTAssertFalse(BedrockPricing.supports(modelID: "custom.unpriced-model"))
    }

    func testPerAppDisableSkipsProviderAndStillAppliesVocabulary() async {
        let provider = FakeCleanupProvider()
        let rule = TargetAppRule(
            bundleID: "com.example.private",
            appName: "Private",
            cleanupBehavior: .disabled
        )
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: {
                [VocabularyEntry(spoken: "fable orchestrator", replacement: "Fable Orchestrator")]
            },
            appRuleProvider: { bundleID in
                TargetAppRuleStore.rule(for: bundleID, in: [rule])
            }
        )

        let result = await pipeline.finalize(
            "Use fable orchestrator.",
            targetBundleID: "com.example.private"
        )

        XCTAssertEqual(result.text, "Use Fable Orchestrator.")
        XCTAssertEqual(result.source, .disabled)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testLongCleanupUsesMultipleBoundedProviderCalls() async {
        let provider = FakeCleanupProvider()
        let source = (0..<1_000).map { "word\($0)" }.joined(separator: " ")
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil }
        )

        let result = await pipeline.finalize(source)

        XCTAssertGreaterThan(provider.callCount, 1)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.source, .ollama)
    }

    func testMeetingCleanupOverrideRunsWhenDictationCleanupIsOff() async {
        let provider = FakeCleanupProvider()
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { false },
            providerResolver: { provider },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil }
        )

        let result = await pipeline.finalize("Meeting notes.", cleanupOverride: true)

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(result.source, .ollama)
    }

    func testVocabularyIsAppliedOnlyOnceBeforeProviderCleanup() async {
        let provider = FakeCleanupProvider()
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: {
                [
                    VocabularyEntry(spoken: "acme", replacement: "Acme Corp"),
                    VocabularyEntry(spoken: "corp", replacement: "Corporation")
                ]
            },
            appRuleProvider: { _ in nil }
        )

        let result = await pipeline.finalize("acme")

        XCTAssertEqual(result.text, "Acme Corp")
    }

    func testFailedLaterChunkPreservesEarlierUsage() async {
        let provider = PartiallyFailingCleanupProvider()
        let source = (0..<1_000).map { "word\($0)" }.joined(separator: " ")
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil }
        )

        let result = await pipeline.finalize(source)

        XCTAssertGreaterThan(provider.callCount, 1)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.source, .rawFallback)
        XCTAssertEqual(result.inputTokens, 12)
        XCTAssertEqual(result.outputTokens, 7)
        XCTAssertEqual(result.modelID, "amazon.nova-micro-v1:0")
    }
}

private final class FakeCleanupProvider: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .ollama
    private(set) var callCount = 0

    func clean(transcript: String, systemPrompt: String) async throws -> CleanupProviderResult {
        callCount += 1
        return CleanupProviderResult(text: transcript, inputTokens: nil, outputTokens: nil, modelID: "fake")
    }
}

private final class FakeBedrockCleanupProvider: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .bedrock
    private(set) var callCount = 0

    func clean(transcript: String, systemPrompt: String) async throws -> CleanupProviderResult {
        callCount += 1
        return CleanupProviderResult(
            text: transcript,
            inputTokens: 10,
            outputTokens: 5,
            modelID: BedrockCleanupConfiguration.defaultModelID
        )
    }
}

private final class PartiallyFailingCleanupProvider: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .bedrock
    private(set) var callCount = 0

    func clean(transcript: String, systemPrompt: String) async throws -> CleanupProviderResult {
        callCount += 1
        if callCount > 1 {
            throw URLError(.timedOut)
        }
        return CleanupProviderResult(
            text: transcript,
            inputTokens: 12,
            outputTokens: 7,
            modelID: "amazon.nova-micro-v1:0"
        )
    }
}

private final class CleanupURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
