import Foundation

/// Cleanup and bounded chat through Anthropic's Messages API with the user's
/// own Anthropic API key.
final class AnthropicCleanupService: TranscriptCleanupProviding, CleanupChatCompleting {
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The current dated API version. It removes `temperature`, `top_p`, and
    /// `top_k`, which WorkFlow does not send.
    static let apiVersion = "2026-10-21"
    /// Anthropic's models overview lists Claude Haiku 5.5 as its fastest model.
    static let recommendedModelID = "claude-haiku-5-5"

    let providerID: CleanupProviderID = .anthropic
    let modelID: String
    let apiKey: String
    let timeout: TimeInterval
    private let session: URLSession

    init(modelID: String, apiKey: String, timeout: TimeInterval, session: URLSession? = nil) {
        self.modelID = modelID
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session ?? Self.sharedSession
    }

    /// Stop reasons that mean the reply is the whole answer.
    static let completeStopReasons: Set<String> = ["end_turn", "stop_sequence"]

    /// Claude Haiku 5.5 documents that extended thinking can be turned off; the
    /// other Claude 5 models reject `thinking.type=disabled` with HTTP 400, so
    /// the parameter is omitted for any other model and the provider's default
    /// thinking applies.
    static func disablesThinking(for model: String) -> Bool {
        model == recommendedModelID
    }

    func clean(
        transcript: String,
        systemPrompt: String,
        filter: CleanupFilterSnapshot = .builtIn(.everyday)
    ) async throws -> CleanupProviderResult {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return CleanupProviderResult(text: "", inputTokens: 0, outputTokens: 0, modelID: modelID)
        }

        let (result, stopReason) = try await send(
            ProviderChatRequest(
                systemPrompt: systemPrompt,
                messages: [ProviderChatMessage(role: .user, content: CleanupPromptBuilder.userMessage(transcript: raw))],
                maxOutputTokens: CleanupTokenBudget.outputTokenLimit(for: raw, mode: filter.mode)
            )
        )
        // `max_tokens`, `model_context_window_exceeded`, `pause_turn`, and
        // `tool_use` all leave a reply that reads as a shorter rewrite.
        guard Self.completeStopReasons.contains(stopReason ?? "") else {
            throw OpenAIChatCleanupError.incompleteResponse
        }

        do {
            let cleaned = try CleanupGuard.postprocess(
                result.text,
                source: raw,
                mode: filter.mode,
                allowsNumberFormatting: filter.allowsNumberFormatting
            )
            return CleanupProviderResult(
                text: cleaned,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                modelID: result.modelID
            )
        } catch CleanupGuardError.emptyResponse {
            throw OpenAIChatCleanupError.emptyResponse
        } catch CleanupGuardError.unsafeRewrite {
            throw OpenAIChatCleanupError.unsafeRewrite
        }
    }

    func complete(_ chat: ProviderChatRequest) async throws -> CleanupProviderResult {
        try await send(chat).result
    }

    private func send(_ chat: ProviderChatRequest) async throws -> (result: CleanupProviderResult, stopReason: String?) {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw OpenAIChatCleanupError.invalidConfiguration("Enter a model name first.")
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw CleanupProviderError.missingCredential(providerID.displayName)
        }

        let timeout = max(timeout, chat.minimumTimeout)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.5, timeout)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(
            MessagesRequest(
                model: model,
                maxTokens: chat.maxOutputTokens,
                system: chat.systemPrompt,
                messages: chat.messages.map { .init(role: $0.role.rawValue, content: $0.content) },
                thinking: Self.disablesThinking(for: model) ? .init(type: "disabled") : nil
            )
        )

        let session = session
        let preparedRequest = request
        let result = try await CleanupDeadline.run(seconds: timeout) {
            let (data, response) = try await session.data(for: preparedRequest)
            return CleanupHTTPResponse(data: data, response: response)
        }
        guard let httpResponse = result.response as? HTTPURLResponse else {
            throw OpenAIChatCleanupError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: result.data))?.error.message
            throw OpenAIChatCleanupError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: ProviderErrorText.describe(statusCode: httpResponse.statusCode, providerMessage: message)
            )
        }

        guard let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: result.data) else {
            throw OpenAIChatCleanupError.invalidResponse
        }
        if decoded.stopReason == "refusal" {
            throw OpenAIChatCleanupError.refused
        }
        // A reply can hold several text blocks, plus thinking blocks that are
        // not part of the answer.
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        let usage = decoded.usage
        let inputTokens = usage.flatMap { usage -> Int? in
            guard let input = usage.inputTokens else { return nil }
            return input + (usage.cacheCreationInputTokens ?? 0) + (usage.cacheReadInputTokens ?? 0)
        }
        let reply = CleanupProviderResult(
            text: text,
            inputTokens: inputTokens,
            outputTokens: usage?.outputTokens,
            modelID: model
        )
        return (reply, decoded.stopReason)
    }
}

private struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Thinking: Encodable {
        let type: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let thinking: Thinking?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, thinking
        case maxTokens = "max_tokens"
    }
}

private struct MessagesResponse: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    let content: [Content]
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }
}

private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
