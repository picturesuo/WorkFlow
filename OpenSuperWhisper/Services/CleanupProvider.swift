import Foundation

enum CleanupProviderID: String, CaseIterable, Codable, Identifiable {
    case bedrock
    case ollama
    case openAICompatible = "openai_compatible"
    case azureOpenAI = "azure_openai"
    case openAI = "openai"
    case anthropic

    var id: String { rawValue }

    /// The order the provider picker lists them in.
    static let pickerOrder: [CleanupProviderID] = [.bedrock, .openAI, .anthropic, .azureOpenAI, .ollama, .openAICompatible]

    var displayName: String {
        switch self {
        case .bedrock: "Amazon Bedrock"
        case .ollama: "Ollama (local, free)"
        case .openAICompatible: "OpenAI-compatible"
        case .azureOpenAI: "Azure OpenAI"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    /// The Keychain account that holds this provider's own key, if it uses one.
    var credentialAccount: CleanupCredentialAccount? {
        switch self {
        case .bedrock, .ollama: nil
        case .openAICompatible: .openAICompatible
        case .azureOpenAI: .azureOpenAI
        case .openAI: .openAI
        case .anthropic: .anthropic
        }
    }

    var outcomeSource: TranscriptCleanupOutcome.Source {
        switch self {
        case .bedrock: .bedrock
        case .ollama: .ollama
        case .openAICompatible: .openAICompatible
        case .azureOpenAI: .azureOpenAI
        case .openAI: .openAI
        case .anthropic: .anthropic
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
    /// What the factory reads besides preferences. Production loads keys from
    /// Keychain and uses each service's own session; tests substitute
    /// synthetic keys and a fixture session so no real key or network is used.
    struct Environment {
        var loadBedrockKey: () throws -> String?
        var loadCleanupKey: (CleanupCredentialAccount) throws -> String?
        var session: URLSession?
        var bedrockService: BedrockCleanupService

        static let keychain = Environment(
            loadBedrockKey: { try BedrockCredentialStore.loadAPIKey() },
            loadCleanupKey: { try CleanupCredentialStore.loadAPIKey(for: $0) },
            session: nil,
            bedrockService: .shared
        )
    }

    static func makeSelected(environment: Environment = .keychain) throws -> any TranscriptCleanupProviding {
        try make(selectedProviderID(), environment: environment)
    }

    /// The same selected provider and stored credential, for bounded requests
    /// that are not transcript cleanup. There is no fallback to another provider.
    static func makeSelectedChat(environment: Environment = .keychain) throws -> any CleanupChatCompleting {
        try make(selectedProviderID(), environment: environment)
    }

    static func selectedProviderID() -> CleanupProviderID {
        CleanupProviderID(rawValue: AppPreferences.shared.cleanupProviderID) ?? .bedrock
    }

    /// Where a request to the selected provider goes, without loading a key.
    static func selectedDestination() -> CleanupProviderDestination {
        let prefs = AppPreferences.shared
        let providerID = selectedProviderID()
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
        case .openAI:
            return CleanupProviderDestination(providerID: providerID, model: prefs.openAIModelID, isOnThisMac: false)
        case .anthropic:
            return CleanupProviderDestination(providerID: providerID, model: prefs.anthropicModelID, isOnThisMac: false)
        }
    }

    /// Builds one provider from the current preferences and its own key.
    /// Save & Test passes an environment that offers the key being tested.
    static func make(
        _ providerID: CleanupProviderID,
        environment: Environment = .keychain
    ) throws -> any TranscriptCleanupProviding & CleanupChatCompleting {
        let prefs = AppPreferences.shared

        switch providerID {
        case .bedrock:
            guard let apiKey = try environment.loadBedrockKey(), !apiKey.isEmpty else {
                throw CleanupProviderError.missingCredential("Bedrock")
            }
            return BedrockCleanupProvider(
                service: environment.bedrockService,
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
                timeout: prefs.ollamaTimeoutSeconds,
                session: environment.session
            )
        case .openAICompatible:
            let apiKey = try environment.loadCleanupKey(.openAICompatible)
            guard (apiKey?.isEmpty == false) || OpenAIChatCleanupService.isLocalBaseURL(prefs.openAICompatibleBaseURL) else {
                throw CleanupProviderError.missingCredential("OpenAI-compatible")
            }
            return OpenAIChatCleanupService(
                providerID: .openAICompatible,
                baseURL: prefs.openAICompatibleBaseURL,
                modelID: prefs.openAICompatibleModelID,
                apiKey: apiKey,
                timeout: prefs.openAICompatibleTimeoutSeconds,
                session: environment.session
            )
        case .azureOpenAI:
            return OpenAIChatCleanupService(
                providerID: .azureOpenAI,
                baseURL: prefs.azureOpenAIEndpoint,
                modelID: prefs.azureOpenAIDeployment,
                apiKey: try requiredKey(.azureOpenAI, environment: environment),
                timeout: prefs.azureOpenAITimeoutSeconds,
                usesReasoningParameters: prefs.azureOpenAIReasoningDeployment,
                session: environment.session
            )
        case .openAI:
            return OpenAIChatCleanupService(
                providerID: .openAI,
                baseURL: OpenAIChatCleanupService.openAIBaseURL,
                modelID: prefs.openAIModelID,
                apiKey: try requiredKey(.openAI, environment: environment),
                timeout: prefs.openAITimeoutSeconds,
                reasoningEffort: OpenAIReasoningEffort(rawValue: prefs.openAIReasoningEffort) ?? .none,
                session: environment.session
            )
        case .anthropic:
            return AnthropicCleanupService(
                modelID: prefs.anthropicModelID,
                apiKey: try requiredKey(.anthropic, environment: environment),
                timeout: prefs.anthropicTimeoutSeconds,
                session: environment.session
            )
        }
    }

    private static func requiredKey(_ providerID: CleanupProviderID, environment: Environment) throws -> String {
        guard let account = providerID.credentialAccount,
              let apiKey = try environment.loadCleanupKey(account)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw CleanupProviderError.missingCredential(providerID.displayName)
        }
        return apiKey
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
