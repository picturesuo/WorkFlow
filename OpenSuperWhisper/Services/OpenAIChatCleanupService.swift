import Foundation

enum OpenAIChatCleanupError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case emptyResponse
    case unsafeRewrite

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .invalidResponse: "The cleanup provider returned an invalid response."
        case .requestFailed(let statusCode, let message): "Cleanup request failed (HTTP \(statusCode)): \(message)"
        case .emptyResponse: "The cleanup provider returned no transcript."
        case .unsafeRewrite: "The cleanup provider changed the transcript too aggressively."
        }
    }
}

final class OpenAIChatCleanupService: TranscriptCleanupProviding {
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
    private let session: URLSession

    static let reasoningTokenHeadroom = 1_024

    init(
        providerID: CleanupProviderID,
        baseURL: String,
        modelID: String,
        apiKey: String?,
        timeout: TimeInterval,
        usesReasoningParameters: Bool = false,
        session: URLSession? = nil
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey
        self.timeout = timeout
        self.usesReasoningParameters = usesReasoningParameters
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

        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw OpenAIChatCleanupError.invalidConfiguration(
                providerID == .azureOpenAI ? "Enter a deployment name first." : "Enter a model name first."
            )
        }
        let endpoint = try endpointURL()
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
        } else if providerID == .azureOpenAI {
            throw CleanupProviderError.missingCredential("Azure OpenAI")
        }

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: "RAW_TRANSCRIPTION:\n\(raw)")
        ]
        let maxTokens = CleanupTokenBudget.outputTokenLimit(for: raw, mode: cleanupMode)
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
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw OpenAIChatCleanupError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let value: String
        let inputTokens: Int?
        let outputTokens: Int?
        if providerID == .ollama {
            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: result.data)
            value = decoded.message.content
            inputTokens = decoded.promptEvalCount
            outputTokens = decoded.evalCount
        } else {
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: result.data)
            guard let content = decoded.choices.first?.message.content else {
                throw OpenAIChatCleanupError.invalidResponse
            }
            value = content
            inputTokens = decoded.usage?.promptTokens
            outputTokens = decoded.usage?.completionTokens
        }

        do {
            let cleaned = try CleanupGuard.postprocess(
                value,
                source: raw,
                mode: cleanupMode,
                allowsNumberFormatting: filter.isCustom
            )
            return CleanupProviderResult(
                text: cleaned,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                modelID: model
            )
        } catch CleanupGuardError.emptyResponse {
            throw OpenAIChatCleanupError.emptyResponse
        } catch CleanupGuardError.unsafeRewrite {
            throw OpenAIChatCleanupError.unsafeRewrite
        }
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

private struct ChatMessage: Codable {
    let role: String
    let content: String
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
    struct Choice: Decodable { let message: ChatMessage }
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
    let message: ChatMessage
    let promptEvalCount: Int?
    let evalCount: Int?
    enum CodingKeys: String, CodingKey {
        case message
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

private struct ServiceErrorEnvelope: Decodable {
    struct ServiceError: Decodable { let message: String }
    let error: ServiceError
}
