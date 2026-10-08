import Foundation

enum CleanupProviderID: String, CaseIterable, Codable, Identifiable {
    case bedrock
    case ollama
    case openAICompatible = "openai_compatible"
    case azureOpenAI = "azure_openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bedrock: "Amazon Bedrock"
        case .ollama: "Ollama (local, free)"
        case .openAICompatible: "OpenAI-compatible"
        case .azureOpenAI: "Azure OpenAI"
        }
    }

    var outcomeSource: TranscriptCleanupOutcome.Source {
        switch self {
        case .bedrock: .bedrock
        case .ollama: .ollama
        case .openAICompatible: .openAICompatible
        case .azureOpenAI: .azureOpenAI
        }
    }
}

struct CleanupProviderResult: Equatable {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
    let modelID: String
}

/// One bounded chat turn sent through a cleanup provider's existing
/// credentials, endpoint validation, and timeout. Transcript cleanup and
/// filter drafting share this transport; each caller validates its own output.
struct ProviderChatMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct ProviderChatRequest: Equatable, Sendable {
    let systemPrompt: String
    let messages: [ProviderChatMessage]
    let maxOutputTokens: Int
    /// Raises, never lowers, the provider's configured timeout.
    var minimumTimeout: TimeInterval = 0
}

protocol CleanupChatCompleting {
    var providerID: CleanupProviderID { get }
    /// Returns the provider's raw reply text, unvalidated.
    func complete(_ request: ProviderChatRequest) async throws -> CleanupProviderResult
}

protocol TranscriptCleanupProviding {
    var providerID: CleanupProviderID { get }
    func clean(
        transcript: String,
        systemPrompt: String,
        filter: CleanupFilterSnapshot
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

struct BedrockCleanupProvider: TranscriptCleanupProviding, CleanupChatCompleting {
    let providerID: CleanupProviderID = .bedrock
    let service: BedrockCleanupService
    let apiKey: String
    let configuration: BedrockCleanupConfiguration

    func clean(
        transcript: String,
        systemPrompt: String,
        filter: CleanupFilterSnapshot
    ) async throws -> CleanupProviderResult {
        let response = try await service.clean(
            transcript: transcript,
            apiKey: apiKey,
            configuration: configuration,
            systemPrompt: systemPrompt,
            filter: filter
        )
        return CleanupProviderResult(
            text: response.text,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens,
            modelID: configuration.modelID
        )
    }

    func complete(_ request: ProviderChatRequest) async throws -> CleanupProviderResult {
        let response = try await service.complete(request, apiKey: apiKey, configuration: configuration)
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
        try makeSelectedProvider()
    }

    /// The same selected provider and stored credential, for bounded requests
    /// that are not transcript cleanup. There is no fallback to another provider.
    static func makeSelectedChat() throws -> any CleanupChatCompleting {
        try makeSelectedProvider()
    }

    /// Where a request to the selected provider goes, without loading a key.
    static func selectedDestination() -> CleanupProviderDestination {
        let prefs = AppPreferences.shared
        let providerID = CleanupProviderID(rawValue: prefs.cleanupProviderID) ?? .bedrock
        switch providerID {
        case .bedrock:
            return CleanupProviderDestination(providerID: providerID, model: prefs.bedrockModelID, isOnThisMac: false)
        case .ollama:
            return CleanupProviderDestination(
                providerID: providerID,
                model: prefs.ollamaModelID,
                isOnThisMac: OpenAIChatCleanupService.isLocalBaseURL(prefs.ollamaBaseURL)
            )
        case .openAICompatible:
            return CleanupProviderDestination(
                providerID: providerID,
                model: prefs.openAICompatibleModelID,
                isOnThisMac: OpenAIChatCleanupService.isLocalBaseURL(prefs.openAICompatibleBaseURL)
            )
        case .azureOpenAI:
            return CleanupProviderDestination(providerID: providerID, model: prefs.azureOpenAIDeployment, isOnThisMac: false)
        }
    }

    private static func makeSelectedProvider() throws -> any TranscriptCleanupProviding & CleanupChatCompleting {
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
            let apiKey = try CleanupCredentialStore.loadAPIKey(for: .openAICompatible)
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
        case .azureOpenAI:
            guard let apiKey = try CleanupCredentialStore.loadAPIKey(for: .azureOpenAI), !apiKey.isEmpty else {
                throw CleanupProviderError.missingCredential("Azure OpenAI")
            }
            return OpenAIChatCleanupService(
                providerID: .azureOpenAI,
                baseURL: prefs.azureOpenAIEndpoint,
                modelID: prefs.azureOpenAIDeployment,
                apiKey: apiKey,
                timeout: prefs.azureOpenAITimeoutSeconds,
                usesReasoningParameters: prefs.azureOpenAIReasoningDeployment
            )
        }
    }
}

struct CleanupProviderDestination: Equatable {
    let providerID: CleanupProviderID
    let model: String
    let isOnThisMac: Bool

    var summary: String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = providerID == .ollama ? "Ollama" : providerID.displayName
        return model.isEmpty ? name : "\(name) · \(model)"
    }
}
