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
    let providerID: CleanupProviderID
    let baseURL: String
    let modelID: String
    let apiKey: String?
    let timeout: TimeInterval
    private let session: URLSession?

    init(
        providerID: CleanupProviderID,
        baseURL: String,
        modelID: String,
        apiKey: String?,
        timeout: TimeInterval,
        session: URLSession? = nil
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    static func isLocalBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http",
              let rawHost = components.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    func clean(transcript: String, systemPrompt: String) async throws -> CleanupProviderResult {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return CleanupProviderResult(text: "", inputTokens: 0, outputTokens: 0, modelID: modelID)
        }

        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw OpenAIChatCleanupError.invalidConfiguration("Enter a model name first.")
        }
        let endpoint = try endpointURL()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.5, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: "RAW_TRANSCRIPTION:\n\(raw)")
        ]
        let maxTokens = min(4_096, max(1_024, raw.count / 2))
        if providerID == .ollama {
            request.httpBody = try JSONEncoder().encode(
                OllamaRequest(
                    model: model,
                    messages: messages,
                    stream: false,
                    options: .init(temperature: 0, numPredict: maxTokens)
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

        let requestSession: URLSession
        if let session {
            requestSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = max(0.5, timeout)
            configuration.timeoutIntervalForResource = max(0.5, timeout)
            requestSession = URLSession(configuration: configuration)
        }
        defer {
            if session == nil { requestSession.finishTasksAndInvalidate() }
        }

        let (data, response) = try await requestSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIChatCleanupError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ServiceErrorEnvelope.self, from: data))?.error.message
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw OpenAIChatCleanupError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let value: String
        let inputTokens: Int?
        let outputTokens: Int?
        if providerID == .ollama {
            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
            value = decoded.message.content
            inputTokens = decoded.promptEvalCount
            outputTokens = decoded.evalCount
        } else {
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                throw OpenAIChatCleanupError.invalidResponse
            }
            value = content
            inputTokens = decoded.usage?.promptTokens
            outputTokens = decoded.usage?.completionTokens
        }

        do {
            let cleaned = try CleanupGuard.postprocess(value, source: raw)
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
