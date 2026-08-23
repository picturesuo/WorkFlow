import Foundation

struct BedrockCleanupConfiguration: Equatable {
    static let defaultRegion = "us-east-1"
    static let legacyOnDemandModelID = "amazon.nova-micro-v1:0"
    static let defaultModelID = "us.amazon.nova-micro-v1:0"
    static let defaultTimeout: TimeInterval = 3.0

    let region: String
    let modelID: String
    let timeout: TimeInterval

    init(
        region: String = defaultRegion,
        modelID: String = defaultModelID,
        timeout: TimeInterval = defaultTimeout
    ) {
        self.region = region
        self.modelID = modelID
        self.timeout = timeout
    }
}

enum BedrockCleanupError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case emptyResponse
    case unsafeRewrite

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Bedrock region or model ID is invalid."
        case .invalidResponse:
            "Bedrock returned an invalid response."
        case .requestFailed(let statusCode, let message):
            "Bedrock request failed (HTTP \(statusCode)): \(message)"
        case .emptyResponse:
            "Bedrock returned no cleaned transcript."
        case .unsafeRewrite:
            "Bedrock changed the transcript too aggressively."
        }
    }
}

struct BedrockCleanupResponse: Equatable {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
}

final class BedrockCleanupService {
    static let shared = BedrockCleanupService()

    static let systemPrompt = CleanupPromptBuilder.baseSystemPrompt

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: configuration)
        }
    }

    func clean(
        transcript: String,
        apiKey: String,
        configuration: BedrockCleanupConfiguration,
        systemPrompt: String = BedrockCleanupService.systemPrompt
    ) async throws -> BedrockCleanupResponse {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return BedrockCleanupResponse(text: "", inputTokens: 0, outputTokens: 0)
        }

        let region = configuration.region.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let validRegionCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !region.isEmpty,
              region.rangeOfCharacter(from: validRegionCharacters.inverted) == nil,
              !modelID.isEmpty, !token.isEmpty,
              let encodedModelID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encodedModelID)/converse")
        else {
            throw BedrockCleanupError.invalidConfiguration
        }

        let body = ConverseRequest(
            system: [.init(text: systemPrompt)],
            messages: [
                .init(
                    role: "user",
                    content: [.init(text: "RAW_TRANSCRIPTION:\n\(raw)")]
                )
            ],
            inferenceConfig: .init(maxTokens: CleanupTokenBudget.outputTokenLimit(for: raw), temperature: 0)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.5, configuration.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let session = session
        let preparedRequest = request
        let result = try await CleanupDeadline.run(seconds: configuration.timeout) {
            let (data, response) = try await session.data(for: preparedRequest)
            return CleanupHTTPResponse(data: data, response: response)
        }
        guard let httpResponse = result.response as? HTTPURLResponse else {
            throw BedrockCleanupError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let serviceError = try? JSONDecoder().decode(ServiceErrorResponse.self, from: result.data)
            let message = serviceError?.message ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw BedrockCleanupError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ConverseResponse.self, from: result.data)
        guard let first = decoded.output.message.content.first?.text else {
            throw BedrockCleanupError.invalidResponse
        }

        let cleaned: String
        do {
            cleaned = try CleanupGuard.postprocess(first, source: raw)
        } catch CleanupGuardError.emptyResponse {
            throw BedrockCleanupError.emptyResponse
        } catch CleanupGuardError.unsafeRewrite {
            throw BedrockCleanupError.unsafeRewrite
        }
        if cleaned.isEmpty {
            return BedrockCleanupResponse(
                text: "",
                inputTokens: decoded.usage?.inputTokens,
                outputTokens: decoded.usage?.outputTokens
            )
        }

        return BedrockCleanupResponse(
            text: cleaned,
            inputTokens: decoded.usage?.inputTokens,
            outputTokens: decoded.usage?.outputTokens
        )
    }

}

private struct ConverseRequest: Encodable {
    struct Content: Encodable {
        let text: String
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    struct InferenceConfiguration: Encodable {
        let maxTokens: Int
        let temperature: Double
    }

    let system: [Content]
    let messages: [Message]
    let inferenceConfig: InferenceConfiguration
}

private struct ConverseResponse: Decodable {
    struct Output: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: [Content]
    }

    struct Content: Decodable {
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
    }

    let output: Output
    let usage: Usage?
}

private struct ServiceErrorResponse: Decodable {
    let message: String?
}
