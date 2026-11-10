import Foundation

enum OpenAIChatCleanupError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case emptyResponse
    case incompleteResponse
    case unsafeRewrite
    case refused

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .invalidResponse: "The cleanup provider returned an invalid response."
        case .requestFailed(let statusCode, let message): "Cleanup request failed (HTTP \(statusCode)): \(message)"
        case .emptyResponse: "The cleanup provider returned no transcript."
        case .incompleteResponse: "The cleanup provider stopped before finishing the transcript."
        case .unsafeRewrite: "The cleanup provider changed the transcript too aggressively."
        case .refused: "The cleanup provider declined to rewrite this text."
        }
    }
}

/// The `reasoning_effort` WorkFlow sends to OpenAI. Reasoning models think by
/// default, which costs time and tokens a short rewrite doesn't need; older
/// non-reasoning models reject the parameter, so it can be left out.
enum OpenAIReasoningEffort: String, CaseIterable, Identifiable {
    case none
    case minimal
    case low
    case notSent = "not_sent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None (fastest)"
        case .minimal: "Minimal"
        case .low: "Low"
        case .notSent: "Don’t send (older models)"
        }
    }

    /// Whether the model may spend completion tokens on reasoning.
    var reasons: Bool { self == .minimal || self == .low }
}

final class OpenAIChatCleanupService: TranscriptCleanupProviding, CleanupChatCompleting {
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    let providerID: CleanupProviderID
    let baseURL: String
    let modelID: String
    let apiKey: String?
    let timeout: TimeInterval
    /// Azure reasoning deployments (o-series, gpt-5 family) reject
    /// `temperature`; they get a low reasoning effort and extra completion
    /// headroom because reasoning tokens count against the completion limit.
    let usesReasoningParameters: Bool
    /// Direct OpenAI only.
    let reasoningEffort: OpenAIReasoningEffort
    private let session: URLSession

    static let reasoningTokenHeadroom = 1_024
    static let openAIBaseURL = "https://api.openai.com/v1"
    /// OpenAI's models page lists GPT-6 Luna for cost-sensitive, high-volume
    /// work, with Chat Completions support and a `none` reasoning effort.
    static let recommendedOpenAIModelID = "gpt-6-luna"

    init(
        providerID: CleanupProviderID,
        baseURL: String,
        modelID: String,
        apiKey: String?,
        timeout: TimeInterval,
        usesReasoningParameters: Bool = false,
        reasoningEffort: OpenAIReasoningEffort = .notSent,
        session: URLSession? = nil
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey
        self.timeout = timeout
        self.usesReasoningParameters = usesReasoningParameters
        self.reasoningEffort = reasoningEffort
        self.session = session ?? Self.sharedSession
    }

    static func isLocalBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http",
              let rawHost = components.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    func clean(
        transcript: String,
        systemPrompt: String,
        filter: CleanupFilterSnapshot = .builtIn(.everyday)
    ) async throws -> CleanupProviderResult {
        let cleanupMode = filter.mode
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return CleanupProviderResult(text: "", inputTokens: 0, outputTokens: 0, modelID: modelID)
        }

        let (result, stopReason) = try await send(
            ProviderChatRequest(
                systemPrompt: systemPrompt,
                messages: [ProviderChatMessage(role: .user, content: CleanupPromptBuilder.userMessage(transcript: raw))],
                maxOutputTokens: CleanupTokenBudget.outputTokenLimit(for: raw, mode: cleanupMode)
            )
        )
        // A reply cut off at the token limit or by a content filter reads as
        // a valid but shorter rewrite and would drop the end of the dictation.
        guard !Self.incompleteStopReasons.contains(stopReason ?? "") else {
            throw OpenAIChatCleanupError.incompleteResponse
        }

        do {
            let cleaned = try CleanupGuard.postprocess(
                result.text,
                source: raw,
                mode: cleanupMode,
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

    /// Whether a request without a key is refused before anything is sent.
    private var requiresKey: Bool { providerID == .azureOpenAI || providerID == .openAI }

    /// OpenAI and Azure report `finish_reason`; Ollama reports `done_reason`.
    static let incompleteStopReasons: Set<String> = ["length", "content_filter"]

    func complete(_ chat: ProviderChatRequest) async throws -> CleanupProviderResult {
        try await send(chat).result
    }

    private func send(_ chat: ProviderChatRequest) async throws -> (result: CleanupProviderResult, stopReason: String?) {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw OpenAIChatCleanupError.invalidConfiguration(
                providerID == .azureOpenAI ? "Enter a deployment name first." : "Enter a model name first."
            )
        }
        let endpoint = try endpointURL()
        let timeout = max(timeout, chat.minimumTimeout)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.5, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            if providerID == .azureOpenAI {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        } else if requiresKey {
            throw CleanupProviderError.missingCredential(providerID.displayName)
        }

        let messages = [ChatMessage(role: "system", content: chat.systemPrompt)]
            + chat.messages.map { ChatMessage(role: $0.role.rawValue, content: $0.content) }
        let maxTokens = chat.maxOutputTokens
        if providerID == .ollama {
            request.httpBody = try JSONEncoder().encode(
                OllamaRequest(
                    model: model,
                    messages: messages,
                    stream: false,
                    options: .init(temperature: 0, numPredict: maxTokens)
                )
            )
        } else if providerID == .azureOpenAI {
            // The v1 API takes the deployment name as `model`. `max_tokens` is
            // deprecated there and rejected by reasoning models.
            request.httpBody = try JSONEncoder().encode(
                AzureOpenAIRequest(
                    model: model,
                    messages: messages,
                    temperature: usesReasoningParameters ? nil : 0,
                    maxCompletionTokens: usesReasoningParameters
                        ? maxTokens + Self.reasoningTokenHeadroom
                        : maxTokens,
                    reasoningEffort: usesReasoningParameters ? "low" : nil
                )
            )
        } else if providerID == .openAI {
            // Chat Completions: `max_tokens` is deprecated in favor of
            // `max_completion_tokens`, which also bounds reasoning tokens.
            request.httpBody = try JSONEncoder().encode(
                OpenAIDirectRequest(
                    model: model,
                    messages: messages,
                    temperature: reasoningEffort == .notSent ? 0 : nil,
                    maxCompletionTokens: reasoningEffort.reasons ? maxTokens + Self.reasoningTokenHeadroom : maxTokens,
                    reasoningEffort: reasoningEffort == .notSent ? nil : reasoningEffort.rawValue
                )
            )
        } else {
            request.httpBody = try JSONEncoder().encode(
                OpenAIRequest(
                    model: model,
                    messages: messages,
                    temperature: 0,
                    maxTokens: maxTokens
                )
            )
        }

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
            let message = (try? JSONDecoder().decode(ServiceErrorEnvelope.self, from: result.data))?.error.message
            throw OpenAIChatCleanupError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: ProviderErrorText.describe(statusCode: httpResponse.statusCode, providerMessage: message)
            )
        }

        if providerID == .ollama {
            guard let decoded = try? JSONDecoder().decode(OllamaResponse.self, from: result.data) else {
                throw OpenAIChatCleanupError.invalidResponse
            }
            let reply = CleanupProviderResult(
                text: decoded.message.content ?? "",
                inputTokens: decoded.promptEvalCount,
                outputTokens: decoded.evalCount,
                modelID: model
            )
            return (reply, decoded.doneReason)
        }
        guard let decoded = try? JSONDecoder().decode(OpenAIResponse.self, from: result.data),
              let choice = decoded.choices.first else {
            throw OpenAIChatCleanupError.invalidResponse
        }
        // `content` is null when the model refuses; the refusal text itself
        // is not shown, since it can quote the transcript.
        if let refusal = choice.message.refusal, !refusal.isEmpty, (choice.message.content ?? "").isEmpty {
            throw OpenAIChatCleanupError.refused
        }
        let reply = CleanupProviderResult(
            text: choice.message.content ?? "",
            inputTokens: decoded.usage?.promptTokens,
            outputTokens: decoded.usage?.completionTokens,
            modelID: model
        )
        return (reply, choice.finishReason)
    }

    private func endpointURL() throws -> URL {
        if providerID == .azureOpenAI {
            return try Self.azureChatCompletionsURL(endpoint: baseURL)
        }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw OpenAIChatCleanupError.invalidConfiguration("Enter a valid cleanup server URL.")
        }

        if scheme != "https" && !(scheme == "http" && Self.isLocalBaseURL(trimmed)) {
            throw OpenAIChatCleanupError.invalidConfiguration("Remote cleanup servers must use HTTPS. Plain HTTP is allowed only on this Mac.")
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let suffix = providerID == .ollama ? "/api/chat" : "/chat/completions"
        if !path.hasSuffix(suffix) { path += suffix }
        components.path = path
        guard let url = components.url else {
            throw OpenAIChatCleanupError.invalidConfiguration("Enter a valid cleanup server URL.")
        }
        return url
    }
}

extension OpenAIChatCleanupService {
    static let azureEndpointHelp = "Enter your Azure resource endpoint, for example https://YOUR-RESOURCE.openai.azure.com."

    /// Builds the Azure OpenAI v1 chat completions URL from a resource
    /// endpoint. The v1 API needs no dated `api-version`, so dated deployment
    /// URLs and query strings are rejected rather than silently rewritten.
    static func azureChatCompletionsURL(endpoint: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw OpenAIChatCleanupError.invalidConfiguration(azureEndpointHelp)
        }
        guard components.scheme?.lowercased() == "https" else {
            throw OpenAIChatCleanupError.invalidConfiguration("Azure OpenAI endpoints must use HTTPS.")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        guard components.query == nil, !path.lowercased().contains("/deployments/") else {
            throw OpenAIChatCleanupError.invalidConfiguration(
                "Use the resource endpoint only. WorkFlow calls the Azure OpenAI v1 API, so no deployment path or api-version is needed."
            )
        }
        let lowered = path.lowercased()
        if lowered.hasSuffix("/openai/v1/chat/completions") {
            // Already a full v1 chat completions URL.
        } else if lowered.hasSuffix("/openai/v1") {
            path += "/chat/completions"
        } else if lowered.hasSuffix("/openai") {
            path += "/v1/chat/completions"
        } else if lowered.isEmpty {
            path = "/openai/v1/chat/completions"
        } else {
            throw OpenAIChatCleanupError.invalidConfiguration(azureEndpointHelp)
        }
        components.path = path
        guard let url = components.url else {
            throw OpenAIChatCleanupError.invalidConfiguration(azureEndpointHelp)
        }
        return url
    }
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ReplyMessage: Decodable {
    let content: String?
    let refusal: String?
}

private struct OpenAIDirectRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxCompletionTokens: Int
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct AzureOpenAIRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxCompletionTokens: Int
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

private struct OllamaRequest: Encodable {
    struct Options: Encodable {
        let temperature: Double
        let numPredict: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let options: Options
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        let message: ReplyMessage
        let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
    let choices: [Choice]
    let usage: Usage?
}

private struct OllamaResponse: Decodable {
    let message: ReplyMessage
    let promptEvalCount: Int?
    let evalCount: Int?
    let doneReason: String?
    enum CodingKeys: String, CodingKey {
        case message
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case doneReason = "done_reason"
    }
}

private struct ServiceErrorEnvelope: Decodable {
    struct ServiceError: Decodable { let message: String }
    let error: ServiceError
}
