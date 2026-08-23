import Foundation

enum CleanupProviderID: String, CaseIterable, Codable, Identifiable {
    case bedrock
    case ollama
    case openAICompatible = "openai_compatible"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bedrock: "Amazon Bedrock"
        case .ollama: "Ollama (local, free)"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    var outcomeSource: TranscriptCleanupOutcome.Source {
        switch self {
        case .bedrock: .bedrock
        case .ollama: .ollama
        case .openAICompatible: .openAICompatible
        }
    }
}

struct CleanupProviderResult: Equatable {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
    let modelID: String
}

protocol TranscriptCleanupProviding {
    var providerID: CleanupProviderID { get }
    func clean(
        transcript: String,
        systemPrompt: String,
        cleanupMode: CleanupMode
    ) async throws -> CleanupProviderResult
}

enum CleanupProviderError: LocalizedError, Equatable {
    case missingCredential(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            "No \(provider) API key is stored."
        case .invalidConfiguration(let message):
            message
        }
    }
}

struct BedrockCleanupProvider: TranscriptCleanupProviding {
    let providerID: CleanupProviderID = .bedrock
    let service: BedrockCleanupService
    let apiKey: String
    let configuration: BedrockCleanupConfiguration

    func clean(
        transcript: String,
        systemPrompt: String,
        cleanupMode: CleanupMode
    ) async throws -> CleanupProviderResult {
        let response = try await service.clean(
            transcript: transcript,
            apiKey: apiKey,
            configuration: configuration,
            systemPrompt: systemPrompt,
            cleanupMode: cleanupMode
        )
        return CleanupProviderResult(
            text: response.text,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens,
            modelID: configuration.modelID
        )
    }
}

enum CleanupProviderFactory {
    static func makeSelected() throws -> any TranscriptCleanupProviding {
        let prefs = AppPreferences.shared
        let providerID = CleanupProviderID(rawValue: prefs.cleanupProviderID) ?? .bedrock

        switch providerID {
        case .bedrock:
            guard let apiKey = try BedrockCredentialStore.loadAPIKey(), !apiKey.isEmpty else {
                throw CleanupProviderError.missingCredential("Bedrock")
            }
            return BedrockCleanupProvider(
                service: .shared,
                apiKey: apiKey,
                configuration: BedrockCleanupConfiguration(
                    region: prefs.bedrockRegion,
                    modelID: prefs.bedrockModelID,
                    timeout: prefs.bedrockTimeoutSeconds
                )
            )
        case .ollama:
            return OpenAIChatCleanupService(
                providerID: .ollama,
                baseURL: prefs.ollamaBaseURL,
                modelID: prefs.ollamaModelID,
                apiKey: nil,
                timeout: prefs.ollamaTimeoutSeconds
            )
        case .openAICompatible:
            let apiKey = try CleanupCredentialStore.loadAPIKey()
            guard (apiKey?.isEmpty == false) || OpenAIChatCleanupService.isLocalBaseURL(prefs.openAICompatibleBaseURL) else {
                throw CleanupProviderError.missingCredential("OpenAI-compatible")
            }
            return OpenAIChatCleanupService(
                providerID: .openAICompatible,
                baseURL: prefs.openAICompatibleBaseURL,
                modelID: prefs.openAICompatibleModelID,
                apiKey: apiKey,
                timeout: prefs.openAICompatibleTimeoutSeconds
            )
        }
    }
}
