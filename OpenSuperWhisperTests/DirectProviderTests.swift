import Foundation
import XCTest
@testable import OpenSuperWhisper

// Contract tests for the direct OpenAI (Chat Completions) and Anthropic
// (Messages) cleanup providers. Every request is answered by an in-process
// URLProtocol fixture; keys are synthetic placeholders that only look like
// real ones so redaction can be checked. Nothing touches Keychain or the network.
// The keys are assembled at runtime so secret scanners never see a full
// key-shaped literal in the source.

private let syntheticOpenAIKey = ["sk", "proj", "SYNTHETICtestKEY" + String(repeating: "0", count: 24)].joined(separator: "-")
private let syntheticAnthropicKey = ["sk", "ant", "api03", "SYNTHETICtestKEY" + String(repeating: "0", count: 22)].joined(separator: "-")

/// Answers each request from `handler`, records what was sent, and can hold a
/// request open forever to exercise timeouts.
final class ProviderFixtureProtocol: URLProtocol {
    enum Reply {
        case http(status: Int, body: String, headers: [String: String] = [:])
        case hang
    }

    static var handler: ((URLRequest, Data) -> Reply)?
    private(set) static var requests: [(request: URLRequest, body: Data)] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.requests.append((request, body))
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request, body) {
        case .hang:
            return
        case .http(let status, let text, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func json(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
}

enum ProviderFixtureReplies {
    static func openAI(_ content: String?, finishReason: String = "stop", refusal: String? = nil) -> String {
        var message: [String: Any] = ["role": "assistant", "content": content ?? NSNull()]
        if let refusal { message["refusal"] = refusal }
        return encode([
            "id": "chatcmpl-fixture",
            "object": "chat.completion",
            "choices": [["index": 0, "message": message, "finish_reason": finishReason]],
            "usage": ["prompt_tokens": 41, "completion_tokens": 7, "total_tokens": 48]
        ])
    }

    static func anthropic(_ blocks: [[String: Any]], stopReason: String = "end_turn") -> String {
        encode([
            "id": "msg_fixture",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-5-5",
            "content": blocks,
            "stop_reason": stopReason,
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 30, "output_tokens": 6, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 5]
        ])
    }

    static func anthropicText(_ text: String, stopReason: String = "end_turn") -> String {
        anthropic([["type": "text", "text": text]], stopReason: stopReason)
    }

    static func openAIError(_ message: String, type: String, code: String?) -> String {
        encode(["error": ["message": message, "type": type, "param": NSNull(), "code": code.map { $0 as Any } ?? NSNull()]])
    }

    static func anthropicError(_ message: String, type: String) -> String {
        encode(["type": "error", "error": ["type": type, "message": message], "request_id": "req_fixture"])
    }

    private static func encode(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

// MARK: - OpenAI Chat Completions contract

final class OpenAIDirectTransportTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        ProviderFixtureProtocol.reset()
        session = ProviderFixtureProtocol.session()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        ProviderFixtureProtocol.reset()
        super.tearDown()
    }

    private func service(effort: OpenAIReasoningEffort = .none, model: String = "gpt-6-luna", timeout: TimeInterval = 2) -> OpenAIChatCleanupService {
        OpenAIChatCleanupService(
            providerID: .openAI,
            baseURL: OpenAIChatCleanupService.openAIBaseURL,
            modelID: model,
            apiKey: syntheticOpenAIKey,
            timeout: timeout,
            reasoningEffort: effort,
            session: session
        )
    }

    func testRequestMatchesChatCompletionsContract() async throws {
        ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: ProviderFixtureReplies.openAI("Send the report.")) }
        let transcript = "Um, send the report."
        let result = try await service().clean(transcript: transcript, systemPrompt: CleanupPromptBuilder.baseSystemPrompt)

        XCTAssertEqual(result.text, "Send the report.")
        XCTAssertEqual(result.inputTokens, 41)
        XCTAssertEqual(result.outputTokens, 7)
        XCTAssertEqual(result.modelID, "gpt-6-luna")

        let sent = try XCTUnwrap(ProviderFixtureProtocol.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(syntheticOpenAIKey)")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "api-key"), "The Azure header is never sent to OpenAI")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "x-api-key"))

        let json = ProviderFixtureProtocol.json(sent.body)
        XCTAssertEqual(Set(json.keys), ["model", "messages", "max_completion_tokens", "reasoning_effort"])
        XCTAssertEqual(json["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
        XCTAssertEqual(json["max_completion_tokens"] as? Int, CleanupTokenBudget.outputTokenLimit(for: transcript, mode: .everyday))
        XCTAssertNil(json["max_tokens"], "max_tokens is deprecated for Chat Completions")
        XCTAssertNil(json["temperature"], "Reasoning models get their default sampling")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, CleanupPromptBuilder.baseSystemPrompt)
        XCTAssertEqual(messages[1]["content"] as? String, CleanupPromptBuilder.userMessage(transcript: transcript))
    }

    func testReasoningEffortChoicesShapeTheBody() async throws {
        ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: ProviderFixtureReplies.openAI("Send the report.")) }
        let transcript = "Um, send the report."
        let budget = CleanupTokenBudget.outputTokenLimit(for: transcript, mode: .everyday)

        _ = try await service(effort: .notSent, model: "gpt-4.1").clean(transcript: transcript, systemPrompt: "s")
        _ = try await service(effort: .low, model: "gpt-6.1-terra").clean(transcript: transcript, systemPrompt: "s")

        let older = ProviderFixtureProtocol.json(ProviderFixtureProtocol.requests[0].body)
        XCTAssertNil(older["reasoning_effort"], "Older models reject reasoning_effort")
        XCTAssertEqual(older["temperature"] as? Double, 0)
        XCTAssertEqual(older["max_completion_tokens"] as? Int, budget)

        let reasoning = ProviderFixtureProtocol.json(ProviderFixtureProtocol.requests[1].body)
        XCTAssertEqual(reasoning["reasoning_effort"] as? String, "low")
        XCTAssertNil(reasoning["temperature"])
        XCTAssertEqual(reasoning["max_completion_tokens"] as? Int, budget + OpenAIChatCleanupService.reasoningTokenHeadroom,
                       "Reasoning tokens count against max_completion_tokens")
    }

    func testRefusalWithNullContentIsAnErrorNotAnEmptyTranscript() async {
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 200, body: ProviderFixtureReplies.openAI(nil, refusal: "I can't help with that."))
        }
        await assertThrows(OpenAIChatCleanupError.refused) {
            _ = try await self.service().clean(transcript: "Some private words.", systemPrompt: "s")
        }
    }

    func testTruncatedAndFilteredRepliesAreIncomplete() async {
        for reason in ["length", "content_filter"] {
            ProviderFixtureProtocol.handler = { _, _ in
                .http(status: 200, body: ProviderFixtureReplies.openAI("Send the", finishReason: reason))
            }
            await assertThrows(OpenAIChatCleanupError.incompleteResponse) {
                _ = try await self.service().clean(transcript: "Send the report to Dana.", systemPrompt: "s")
            }
        }
    }

    func testMalformedAndTruncatedBodiesAreInvalidResponses() async {
        let full = ProviderFixtureReplies.openAI("Send the report.")
        for body in ["", "not json", String(full.prefix(full.count / 2)), #"{"choices":[]}"#, #"{"choices":[{"message":{}}]"#] {
            ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: body) }
            await assertThrows(OpenAIChatCleanupError.invalidResponse) {
                _ = try await self.service().clean(transcript: "Send the report.", systemPrompt: "s")
            }
        }
    }

    func testInvalidKeyErrorNeverEchoesKeyText() async throws {
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 401, body: ProviderFixtureReplies.openAIError(
                "Incorrect API key provided: sk-proj-****************************0000. You can find your API key at https://platform.openai.com/account/api-keys.",
                type: "invalid_request_error",
                code: "invalid_api_key"
            ))
        }
        do {
            _ = try await service().clean(transcript: "Send the report.", systemPrompt: "s")
            XCTFail("Expected a rejected key")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("HTTP 401"), text)
            XCTAssertTrue(text.contains("API key was rejected"), text)
            XCTAssertFalse(text.contains("sk-"), text)
            XCTAssertFalse(text.contains("0000"), text)
        }
    }

    func testRateLimitAndQuotaErrorsExplainThemselves() async throws {
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 429, body: ProviderFixtureReplies.openAIError(
                "You exceeded your current quota, please check your plan and billing details.",
                type: "insufficient_quota",
                code: "insufficient_quota"
            ), headers: ["Retry-After": "20"])
        }
        do {
            _ = try await service().clean(transcript: "Send the report.", systemPrompt: "s")
            XCTFail("Expected a rate limit")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Rate limit or quota reached"), text)
            XCTAssertTrue(text.contains("exceeded your current quota"), text)
        }
    }

    func testMissingKeyIsRejectedBeforeAnyRequest() async {
        let keyless = OpenAIChatCleanupService(
            providerID: .openAI, baseURL: OpenAIChatCleanupService.openAIBaseURL, modelID: "gpt-6-luna",
            apiKey: "  ", timeout: 1, reasoningEffort: .none, session: session
        )
        await assertThrows(CleanupProviderError.missingCredential("OpenAI")) {
            _ = try await keyless.complete(ProviderChatRequest(systemPrompt: "s", messages: [], maxOutputTokens: 10))
        }
        XCTAssertTrue(ProviderFixtureProtocol.requests.isEmpty)
    }

    func testTimeoutCancelsTheRequest() async {
        ProviderFixtureProtocol.handler = { _, _ in .hang }
        let started = Date()
        do {
            _ = try await service(timeout: 0.5).clean(transcript: "Send the report.", systemPrompt: "s")
            XCTFail("Expected a timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

// MARK: - Anthropic Messages contract

final class AnthropicTransportTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        ProviderFixtureProtocol.reset()
        session = ProviderFixtureProtocol.session()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        ProviderFixtureProtocol.reset()
        super.tearDown()
    }

    private func service(model: String = "claude-haiku-5-5", timeout: TimeInterval = 2) -> AnthropicCleanupService {
        AnthropicCleanupService(modelID: model, apiKey: syntheticAnthropicKey, timeout: timeout, session: session)
    }

    func testRequestMatchesMessagesContract() async throws {
        ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: ProviderFixtureReplies.anthropicText("Send the report.")) }
        let transcript = "Um, send the report."
        let result = try await service().clean(transcript: transcript, systemPrompt: CleanupPromptBuilder.baseSystemPrompt)

        XCTAssertEqual(result.text, "Send the report.")
        XCTAssertEqual(result.inputTokens, 35, "Cache reads count as input")
        XCTAssertEqual(result.outputTokens, 6)
        XCTAssertEqual(result.modelID, "claude-haiku-5-5")

        let sent = try XCTUnwrap(ProviderFixtureProtocol.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "x-api-key"), syntheticAnthropicKey)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "Authorization"), "Anthropic takes the key in x-api-key")

        let json = ProviderFixtureProtocol.json(sent.body)
        XCTAssertEqual(Set(json.keys), ["model", "max_tokens", "system", "messages", "thinking"])
        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, CleanupTokenBudget.outputTokenLimit(for: transcript, mode: .everyday))
        XCTAssertEqual(json["system"] as? String, CleanupPromptBuilder.baseSystemPrompt)
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        for removed in ["temperature", "top_p", "top_k"] {
            XCTAssertNil(json[removed], "\(removed) returns HTTP 400 on API version 2026-10-21")
        }
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user"], "The system prompt is not a message")
        XCTAssertEqual(messages[0]["content"] as? String, CleanupPromptBuilder.userMessage(transcript: transcript))
    }

    func testMultiTurnChatKeepsRolesAndJoinsTextBlocksOnly() async throws {
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 200, body: ProviderFixtureReplies.anthropic([
                ["type": "thinking", "thinking": "hidden", "signature": "sig"],
                ["type": "text", "text": "{\"message\":\"Here"],
                ["type": "redacted_thinking", "data": "opaque"],
                ["type": "text", "text": " it is.\"}"]
            ]))
        }
        let request = ProviderChatRequest(
            systemPrompt: "SYSTEM",
            messages: [
                ProviderChatMessage(role: .user, content: "first"),
                ProviderChatMessage(role: .assistant, content: "reply"),
                ProviderChatMessage(role: .user, content: "second")
            ],
            maxOutputTokens: 700,
            minimumTimeout: 30
        )
        let result = try await service(timeout: 1).complete(request)
        XCTAssertEqual(result.text, #"{"message":"Here it is."}"#)

        let sent = try XCTUnwrap(ProviderFixtureProtocol.requests.first)
        XCTAssertEqual(sent.request.timeoutInterval, 30, "A caller's minimum timeout raises the provider timeout")
        let json = ProviderFixtureProtocol.json(sent.body)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(json["max_tokens"] as? Int, 700)
    }

    func testStopReasonsThatCutTheReplyShortAreIncomplete() async {
        for reason in ["max_tokens", "model_context_window_exceeded", "pause_turn", "tool_use"] {
            ProviderFixtureProtocol.handler = { _, _ in
                .http(status: 200, body: ProviderFixtureReplies.anthropicText("Send the", stopReason: reason))
            }
            await assertThrows(OpenAIChatCleanupError.incompleteResponse) {
                _ = try await self.service().clean(transcript: "Send the report to Dana.", systemPrompt: "s")
            }
        }
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 200, body: ProviderFixtureReplies.anthropicText("Send the report to Dana.", stopReason: "stop_sequence"))
        }
        let result = try? await service().clean(transcript: "Send the report to Dana.", systemPrompt: "s")
        XCTAssertEqual(result?.text, "Send the report to Dana.")
    }

    func testRefusalIsAnError() async {
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 200, body: ProviderFixtureReplies.anthropic([], stopReason: "refusal"))
        }
        await assertThrows(OpenAIChatCleanupError.refused) {
            _ = try await self.service().clean(transcript: "Some private words.", systemPrompt: "s")
        }
    }

    func testReplyWithoutTextIsEmpty() async {
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 200, body: ProviderFixtureReplies.anthropic([["type": "thinking", "thinking": "x", "signature": "s"]]))
        }
        await assertThrows(OpenAIChatCleanupError.emptyResponse) {
            _ = try await self.service().clean(transcript: "Send the report.", systemPrompt: "s")
        }
    }

    func testMalformedAndTruncatedBodiesAreInvalidResponses() async {
        let full = ProviderFixtureReplies.anthropicText("Send the report.")
        for body in ["", "<html>Bad gateway</html>", String(full.prefix(full.count / 2)), #"{"type":"message"}"#] {
            ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: body) }
            await assertThrows(OpenAIChatCleanupError.invalidResponse) {
                _ = try await self.service().clean(transcript: "Send the report.", systemPrompt: "s")
            }
        }
    }

    func testErrorStatusesAreExplainedWithoutKeyText() async {
        let cases: [(Int, String, String, String)] = [
            (401, "authentication_error", "invalid x-api-key \(syntheticAnthropicKey)", "API key was rejected"),
            (403, "permission_error", "Your API key does not have permission to use the specified resource.", "isn’t allowed"),
            (404, "not_found_error", "model: claude-nonexistent", "wasn’t found"),
            (429, "rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit", "Rate limit or quota reached"),
            (500, "api_error", "Internal server error", "server error"),
            (529, "overloaded_error", "Overloaded", "overloaded")
        ]
        for (status, type, message, expected) in cases {
            ProviderFixtureProtocol.handler = { _, _ in
                .http(status: status, body: ProviderFixtureReplies.anthropicError(message, type: type), headers: ["request-id": "req_fixture"])
            }
            do {
                _ = try await service().clean(transcript: "Send the report.", systemPrompt: "s")
                XCTFail("Expected HTTP \(status)")
            } catch {
                let text = error.localizedDescription
                XCTAssertTrue(text.contains("HTTP \(status)"), text)
                XCTAssertTrue(text.contains(expected), text)
                XCTAssertFalse(text.contains("sk-ant"), text)
                XCTAssertFalse(text.contains("SYNTHETIC"), text)
            }
        }
    }

    func testTimeoutCancelsTheRequest() async {
        ProviderFixtureProtocol.handler = { _, _ in .hang }
        do {
            _ = try await service(timeout: 0.5).clean(transcript: "Send the report.", systemPrompt: "s")
            XCTFail("Expected a timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationStopsTheRequest() async {
        ProviderFixtureProtocol.handler = { _, _ in .hang }
        let service = service(timeout: 20)
        let task = Task { try await service.clean(transcript: "Send the report.", systemPrompt: "s") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let started = Date()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard case .failure = result else { return XCTFail("A cancelled request must not succeed") }
    }
}

// MARK: - Error text

final class ProviderErrorTextTests: XCTestCase {
    func testKeyShapedTokensAreRedacted() {
        let samples = [
            "Incorrect API key provided: sk-proj-abc123************************wxyz.",
            "invalid x-api-key \(syntheticAnthropicKey)",
            "Authorization: Bearer abc.def.ghi",
            "The security token ABSKQmVkcm9ja0FQSUtleS1leGFtcGxl is invalid",
            "token 0123456789abcdef0123456789abcdef0123 leaked"
        ]
        for sample in samples {
            let redacted = ProviderErrorText.redacted(sample)
            XCTAssertTrue(redacted.contains("[redacted]"), redacted)
            XCTAssertFalse(redacted.contains("sk-"), redacted)
            XCTAssertFalse(redacted.contains("abc.def"), redacted)
            XCTAssertFalse(redacted.contains("0123456789abcdef"), redacted)
            XCTAssertFalse(redacted.contains("QmVkcm9ja"), redacted)
        }
    }

    func testDetailIsOneShortLine() {
        let long = String(repeating: "word ", count: 100) + "\nsecond line"
        let redacted = ProviderErrorText.redacted(long)
        XCTAssertLessThanOrEqual(redacted.count, ProviderErrorText.maximumDetailLength)
        XCTAssertFalse(redacted.contains("second line"))
    }

    func testKeyErrorsDropTheProviderText() {
        XCTAssertFalse(ProviderErrorText.describe(statusCode: 401, providerMessage: "anything at all").contains("anything"))
        XCTAssertFalse(ProviderErrorText.describe(statusCode: 403, providerMessage: "anything at all").contains("anything"))
        XCTAssertTrue(ProviderErrorText.describe(statusCode: 418, providerMessage: nil).hasSuffix("."))
    }

    func testBedrockFrontDoorCapitalizedMessageIsShown() async throws {
        ProviderFixtureProtocol.reset()
        defer { ProviderFixtureProtocol.reset() }
        let session = ProviderFixtureProtocol.session()
        defer { session.invalidateAndCancel() }
        ProviderFixtureProtocol.handler = { _, _ in
            .http(status: 403, body: #"{"Message":"The security token included in the request is invalid."}"#)
        }
        let provider = BedrockCleanupProvider(
            service: BedrockCleanupService(session: session),
            apiKey: "bedrock-synthetic",
            configuration: BedrockCleanupConfiguration()
        )
        do {
            _ = try await provider.clean(transcript: "Send the report.", systemPrompt: "s", filter: .builtIn(.everyday))
            XCTFail("Expected HTTP 403")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Bedrock request failed (HTTP 403): The security token included in the request is invalid.")
        }
    }
}

// MARK: - Production factory to every caller

@MainActor
final class DirectProviderFactoryTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let preferenceKeys = ["cleanupProviderID", "openAIModelID", "openAIReasoningEffort", "openAITimeoutSeconds",
                                  "anthropicModelID", "anthropicTimeoutSeconds", "openAICompatibleModelID", "openAICompatibleBaseURL",
                                  "openAICompatibleTimeoutSeconds"]
    private var session: URLSession!
    private var requestedAccounts: [CleanupCredentialAccount] = []
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        for key in preferenceKeys { saved[key] = UserDefaults.standard.object(forKey: key) }
        ProviderFixtureProtocol.reset()
        session = ProviderFixtureProtocol.session()
        requestedAccounts = []
        suite = "DirectProviderFactoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        for key in preferenceKeys {
            if let value = saved[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        session.invalidateAndCancel()
        ProviderFixtureProtocol.reset()
        defaults.removePersistentDomain(forName: suite)
    }

    /// The production factory, reading real preferences, with synthetic keys
    /// and the fixture session.
    private func environment(keys: [CleanupCredentialAccount: String] = [.openAI: syntheticOpenAIKey, .anthropic: syntheticAnthropicKey]) -> CleanupProviderFactory.Environment {
        CleanupProviderFactory.Environment(
            loadBedrockKey: { XCTFail("Bedrock's key must not be read"); return nil },
            loadCleanupKey: { [unowned self] account in
                requestedAccounts.append(account)
                return keys[account]
            },
            session: session,
            bedrockService: BedrockCleanupService(session: session)
        )
    }

    private func select(_ provider: CleanupProviderID) {
        AppPreferences.shared.cleanupProviderID = provider.rawValue
        AppPreferences.shared.openAIModelID = "gpt-6-luna"
        AppPreferences.shared.openAIReasoningEffort = OpenAIReasoningEffort.none.rawValue
        AppPreferences.shared.openAITimeoutSeconds = 2
        AppPreferences.shared.anthropicModelID = "claude-haiku-5-5"
        AppPreferences.shared.anthropicTimeoutSeconds = 2
    }

    private func pipeline(_ environment: CleanupProviderFactory.Environment) -> (TranscriptCleanupPipeline, () -> [String?]) {
        var failures: [String?] = []
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { try CleanupProviderFactory.makeSelected(environment: environment) },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { XCTFail("Only Bedrock reads the Bedrock stop"); return nil },
            filterProvider: { .builtIn(.everyday) },
            failureRecorder: { failures.append($0) }
        )
        return (pipeline, { failures })
    }

    private func reply(for provider: CleanupProviderID, _ text: String) -> String {
        provider == .openAI ? ProviderFixtureReplies.openAI(text) : ProviderFixtureReplies.anthropicText(text)
    }

    private func error(for provider: CleanupProviderID, status: Int) -> String {
        provider == .openAI
            ? ProviderFixtureReplies.openAIError("Incorrect API key provided: \(syntheticOpenAIKey)", type: "invalid_request_error", code: "invalid_api_key")
            : ProviderFixtureReplies.anthropicError("invalid x-api-key \(syntheticAnthropicKey)", type: status == 429 ? "rate_limit_error" : "authentication_error")
    }

    func testSelectedProviderCleansThroughItsOwnEndpointAndKey() async {
        for (provider, host, account) in [(CleanupProviderID.openAI, "api.openai.com", CleanupCredentialAccount.openAI),
                                          (.anthropic, "api.anthropic.com", .anthropic)] {
            ProviderFixtureProtocol.reset()
            requestedAccounts = []
            select(provider)
            ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: self.reply(for: provider, "Send the report to Dana by Friday.")) }
            let (pipeline, failures) = pipeline(environment())

            let outcome = await pipeline.finalize("um send the report to dana by friday")

            XCTAssertEqual(outcome.text, "Send the report to Dana by Friday.")
            XCTAssertEqual(outcome.source, provider == .openAI ? .openAI : .anthropic)
            XCTAssertNotNil(outcome.inputTokens)
            XCTAssertEqual(outcome.modelID, provider == .openAI ? "gpt-6-luna" : "claude-haiku-5-5")
            XCTAssertEqual(ProviderFixtureProtocol.requests.map { $0.request.url?.host }, [host])
            XCTAssertEqual(requestedAccounts, [account], "Only the selected provider's own key is read")
            XCTAssertEqual(failures(), [nil])
        }
    }

    func testEveryFailureKeepsTheOriginalTranscript() async {
        let spoken = "um send the report to dana by friday"
        let replies: [(String, (CleanupProviderID) -> ProviderFixtureProtocol.Reply)] = [
            ("invalid key", { .http(status: 401, body: self.error(for: $0, status: 401)) }),
            ("rate limit", { .http(status: 429, body: self.error(for: $0, status: 429)) }),
            ("timeout", { _ in .hang }),
            ("unsafe rewrite", { .http(status: 200, body: self.reply(for: $0, "Here is a poem about the sea instead.")) }),
            ("answered the question", { .http(status: 200, body: self.reply(for: $0, "Dana already has the report, so there is nothing to send.")) }),
            ("truncated body", { .http(status: 200, body: String(self.reply(for: $0, "Send the report to Dana by Friday.").prefix(40))) }),
            ("cut off at the token limit", {
                .http(status: 200, body: $0 == .openAI
                    ? ProviderFixtureReplies.openAI("Send the report", finishReason: "length")
                    : ProviderFixtureReplies.anthropicText("Send the report", stopReason: "max_tokens"))
            })
        ]
        for provider in [CleanupProviderID.openAI, .anthropic] {
            select(provider)
            AppPreferences.shared.openAITimeoutSeconds = 0.5
            AppPreferences.shared.anthropicTimeoutSeconds = 0.5
            for (name, reply) in replies {
                ProviderFixtureProtocol.reset()
                ProviderFixtureProtocol.handler = { _, _ in reply(provider) }
                let (pipeline, failures) = pipeline(environment())
                let outcome = await pipeline.finalize(spoken)
                XCTAssertEqual(outcome.text, spoken, "\(provider) \(name)")
                XCTAssertEqual(outcome.source, .rawFallback, "\(provider) \(name)")
                XCTAssertEqual(ProviderFixtureProtocol.requests.count, 1, "\(provider) \(name) reached the provider")
                XCTAssertEqual(failures(), [TranscriptCleanupPipeline.safeFailureMessage], "Only the fixed safe message is recorded")
            }
        }
    }

    func testMissingKeySendsNothingAndKeepsTheTranscript() async {
        for provider in [CleanupProviderID.openAI, .anthropic] {
            ProviderFixtureProtocol.reset()
            select(provider)
            XCTAssertThrowsError(try CleanupProviderFactory.makeSelectedChat(environment: environment(keys: [:]))) { error in
                XCTAssertEqual(error as? CleanupProviderError, .missingCredential(provider.displayName))
            }
            // Another provider's key is never borrowed.
            let other: [CleanupCredentialAccount: String] = provider == .openAI
                ? [.anthropic: syntheticAnthropicKey, .openAICompatible: "compatible", .azureOpenAI: "azure"]
                : [.openAI: syntheticOpenAIKey, .openAICompatible: "compatible", .azureOpenAI: "azure"]
            let (pipeline, _) = pipeline(environment(keys: other))
            let outcome = await pipeline.finalize("send the report")
            XCTAssertEqual(outcome.source, .rawFallback)
            XCTAssertEqual(outcome.text, "send the report")
            XCTAssertTrue(ProviderFixtureProtocol.requests.isEmpty)
        }
    }

    func testDestinationNamesTheEditableModel() {
        select(.openAI)
        AppPreferences.shared.openAIModelID = "gpt-6.1-terra"
        XCTAssertEqual(CleanupProviderFactory.selectedDestination().summary, "OpenAI · gpt-6.1-terra")
        select(.anthropic)
        AppPreferences.shared.anthropicModelID = "claude-sonnet-5-5"
        XCTAssertEqual(CleanupProviderFactory.selectedDestination().summary, "Anthropic · claude-sonnet-5-5")
        XCTAssertFalse(CleanupProviderFactory.selectedDestination().isOnThisMac)
    }

    func testDefaultsAreTheDocumentedModels() {
        for key in ["openAIModelID", "openAIReasoningEffort", "anthropicModelID"] { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertEqual(AppPreferences.shared.openAIModelID, "gpt-6-luna")
        XCTAssertEqual(AppPreferences.shared.openAIReasoningEffort, "none")
        XCTAssertEqual(AppPreferences.shared.anthropicModelID, "claude-haiku-5-5")
    }

    // MARK: OpenAI-compatible has no implicit model

    private func compatibleEnvironment() -> CleanupProviderFactory.Environment {
        environment(keys: [.openAICompatible: "compatible-synthetic"])
    }

    func testNewCompatibleConfigurationHasNoModelAndSendsNothing() async throws {
        UserDefaults.standard.removeObject(forKey: "openAICompatibleModelID")
        AppPreferences.shared.cleanupProviderID = CleanupProviderID.openAICompatible.rawValue
        AppPreferences.shared.openAICompatibleBaseURL = "https://compatible.example/v1"
        XCTAssertEqual(AppPreferences.shared.openAICompatibleModelID, "", "The retired gpt-4.1-nano is no longer implied")
        XCTAssertEqual(CleanupProviderFactory.selectedDestination().summary, "OpenAI-compatible")
        ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: ProviderFixtureReplies.openAI("Send the report.")) }

        for model in ["", "   "] {
            AppPreferences.shared.openAICompatibleModelID = model
            let chat = try CleanupProviderFactory.makeSelectedChat(environment: compatibleEnvironment())
            await assertThrows(OpenAIChatCleanupError.invalidConfiguration("Enter a model name first.")) {
                _ = try await chat.complete(ProviderChatRequest(systemPrompt: "s", messages: [], maxOutputTokens: 10))
            }
            let (pipeline, _) = pipeline(compatibleEnvironment())
            let outcome = await pipeline.finalize("send the report")
            XCTAssertEqual(outcome.source, .rawFallback)
            XCTAssertEqual(outcome.text, "send the report")
        }
        XCTAssertTrue(ProviderFixtureProtocol.requests.isEmpty, "A blank model sends nothing")
    }

    func testInvalidCompatibleServerSendsNothing() async {
        AppPreferences.shared.cleanupProviderID = CleanupProviderID.openAICompatible.rawValue
        AppPreferences.shared.openAICompatibleModelID = "custom-model"
        ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: ProviderFixtureReplies.openAI("Send the report.")) }
        for url in ["", "not a url", "http://compatible.example/v1", "https://user:pass@compatible.example/v1", "https://compatible.example/v1?key=1"] {
            AppPreferences.shared.openAICompatibleBaseURL = url
            let (pipeline, _) = pipeline(compatibleEnvironment())
            let outcome = await pipeline.finalize("send the report")
            XCTAssertEqual(outcome.source, .rawFallback, url)
        }
        XCTAssertTrue(ProviderFixtureProtocol.requests.isEmpty)
    }

    func testSavedCompatibleModelsRoundTripWithTheGenericProtocol() async throws {
        AppPreferences.shared.cleanupProviderID = CleanupProviderID.openAICompatible.rawValue
        AppPreferences.shared.openAICompatibleTimeoutSeconds = 2
        ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: ProviderFixtureReplies.openAI("Send the report.")) }
        // Saved settings, including the old default someone typed in, stay exactly as saved.
        let saved = [("https://openrouter.example/api/v1", "meta-llama/llama-3.3-8b-instruct"),
                     ("http://localhost:1234/v1", "local-model"),
                     ("https://api.openai.com/v1", "gpt-4.1-nano")]
        for (index, (baseURL, model)) in saved.enumerated() {
            UserDefaults.standard.set(baseURL, forKey: "openAICompatibleBaseURL")
            UserDefaults.standard.set(model, forKey: "openAICompatibleModelID")
            XCTAssertEqual(AppPreferences.shared.openAICompatibleModelID, model)
            XCTAssertEqual(AppPreferences.shared.openAICompatibleBaseURL, baseURL)

            let (pipeline, _) = pipeline(compatibleEnvironment())
            let outcome = await pipeline.finalize("um send the report")
            XCTAssertEqual(outcome.source, .openAICompatible, model)
            XCTAssertEqual(outcome.modelID, model)

            let sent = ProviderFixtureProtocol.requests[index]
            XCTAssertEqual(sent.request.url?.absoluteString, baseURL + "/chat/completions")
            let json = ProviderFixtureProtocol.json(sent.body)
            XCTAssertEqual(json["model"] as? String, model)
            XCTAssertEqual(Set(json.keys), ["model", "messages", "temperature", "max_tokens"],
                           "A generic server never gets OpenAI-only reasoning parameters")
            XCTAssertEqual(UserDefaults.standard.string(forKey: "openAICompatibleModelID"), model, "Reading never rewrites a saved model")
        }
    }

    func testFilterAssistantDraftsThroughTheSelectedProvider() async throws {
        let draft = #"{"message":"Here is a filter.","filter":{"name":"Standup notes","base_mode":"writing","instructions":"Write short bullet points.","digits":false}}"#
        for provider in [CleanupProviderID.openAI, .anthropic] {
            ProviderFixtureProtocol.reset()
            select(provider)
            ProviderFixtureProtocol.handler = { _, _ in .http(status: 200, body: self.reply(for: provider, draft)) }
            let env = environment()
            let session = FilterAssistantSession(
                target: .new,
                destination: CleanupProviderFactory.selectedDestination(),
                chatResolver: { try CleanupProviderFactory.makeSelectedChat(environment: env) },
                budgetProvider: { XCTFail("Only Bedrock reads the Bedrock stop"); return nil },
                defaults: defaults
            )
            session.request = "Short bullet points for standup."
            session.send()
            for _ in 0..<400 where session.isGenerating { try await Task.sleep(nanoseconds: 5_000_000) }

            XCTAssertNil(session.errorMessage, "\(provider)")
            XCTAssertEqual(session.proposal?.name, "Standup notes", "\(provider)")
            let sent = try XCTUnwrap(ProviderFixtureProtocol.requests.first)
            XCTAssertEqual(sent.request.timeoutInterval, FilterAssistantPrompt.minimumTimeout)
            let json = ProviderFixtureProtocol.json(sent.body)
            if provider == .openAI {
                XCTAssertEqual(json["max_completion_tokens"] as? Int, FilterAssistantPrompt.maximumOutputTokens)
            } else {
                XCTAssertEqual(json["max_tokens"] as? Int, FilterAssistantPrompt.maximumOutputTokens)
                XCTAssertEqual(json["system"] as? String, FilterAssistantPrompt.systemPrompt)
            }
        }
    }

    func testFilterAssistantShowsASafeErrorForARejectedKey() async throws {
        for provider in [CleanupProviderID.openAI, .anthropic] {
            ProviderFixtureProtocol.reset()
            select(provider)
            ProviderFixtureProtocol.handler = { _, _ in .http(status: 401, body: self.error(for: provider, status: 401)) }
            let env = environment()
            let session = FilterAssistantSession(
                target: .new,
                destination: CleanupProviderFactory.selectedDestination(),
                chatResolver: { try CleanupProviderFactory.makeSelectedChat(environment: env) },
                budgetProvider: { nil },
                defaults: defaults
            )
            session.request = "A private request about my clients."
            session.send()
            for _ in 0..<400 where session.isGenerating { try await Task.sleep(nanoseconds: 5_000_000) }
            let message = try XCTUnwrap(session.errorMessage)
            XCTAssertTrue(message.contains("API key was rejected"), message)
            XCTAssertFalse(message.contains("sk-"), message)
            XCTAssertFalse(message.contains("private request"), message)
        }
    }
}

private func assertThrows<E: Error & Equatable>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}
