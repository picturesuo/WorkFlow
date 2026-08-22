import Foundation

struct TranscriptCleanupOutcome: Equatable {
    enum Source: String, Codable, Equatable {
        case bedrock
        case ollama
        case openAICompatible = "openai_compatible"
        case rawFallback
        case disabled
    }

    let text: String
    let source: Source
    let inputTokens: Int?
    let outputTokens: Int?
    let modelID: String?
}

final class TranscriptCleanupPipeline {
    static let shared = TranscriptCleanupPipeline()

    private let isEnabled: () -> Bool
    private let providerResolver: () throws -> any TranscriptCleanupProviding
    private let vocabularyProvider: () -> [VocabularyEntry]
    private let appRuleProvider: (String?) -> TargetAppRule?

    init(
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.bedrockCleanupEnabled },
        providerResolver: @escaping () throws -> any TranscriptCleanupProviding = {
            try CleanupProviderFactory.makeSelected()
        },
        vocabularyProvider: @escaping () -> [VocabularyEntry] = { VocabularyStore.load() },
        appRuleProvider: @escaping (String?) -> TargetAppRule? = { TargetAppRuleStore.rule(for: $0) }
    ) {
        self.isEnabled = isEnabled
        self.providerResolver = providerResolver
        self.vocabularyProvider = vocabularyProvider
        self.appRuleProvider = appRuleProvider
    }

    convenience init(
        service: BedrockCleanupService,
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.bedrockCleanupEnabled },
        credentialProvider: @escaping () throws -> String? = { try BedrockCredentialStore.loadAPIKey() },
        configurationProvider: @escaping () -> BedrockCleanupConfiguration = {
            let prefs = AppPreferences.shared
            return BedrockCleanupConfiguration(
                region: prefs.bedrockRegion,
                modelID: prefs.bedrockModelID,
                timeout: prefs.bedrockTimeoutSeconds
            )
        }
    ) {
        self.init(
            isEnabled: isEnabled,
            providerResolver: {
                guard let token = try credentialProvider(), !token.isEmpty else {
                    throw CleanupProviderError.missingCredential("Bedrock")
                }
                return BedrockCleanupProvider(
                    service: service,
                    apiKey: token,
                    configuration: configurationProvider()
                )
            },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil }
        )
    }

    func finalize(
        _ rawTranscript: String,
        targetBundleID: String? = nil,
        cleanupOverride: Bool? = nil
    ) async -> TranscriptCleanupOutcome {
        let vocabulary = vocabularyProvider()
        let localTranscript = VocabularyRewriter.apply(rawTranscript, entries: vocabulary)
        let appRule = appRuleProvider(targetBundleID)
        let cleanupEnabled: Bool
        if let cleanupOverride {
            cleanupEnabled = cleanupOverride
        } else {
            cleanupEnabled = TargetAppRuleStore.cleanupEnabled(
                rule: appRule,
                globalDefault: isEnabled()
            )
        }

        guard cleanupEnabled else {
            return TranscriptCleanupOutcome(
                text: localTranscript,
                source: .disabled,
                inputTokens: nil,
                outputTokens: nil,
                modelID: nil
            )
        }

        var inputTokens = 0
        var outputTokens = 0
        var hasInputTokens = false
        var hasOutputTokens = false
        var modelID: String?

        do {
            let provider = try providerResolver()
            let systemPrompt = CleanupPromptBuilder.systemPrompt(
                instruction: appRule?.cleanupInstruction
            )
            let chunks = TranscriptChunker.chunks(localTranscript)
            var cleanedTranscript = ""
            for chunk in chunks {
                let result = try await provider.clean(transcript: chunk.text, systemPrompt: systemPrompt)
                cleanedTranscript += result.text + chunk.separatorAfter
                if let value = result.inputTokens {
                    inputTokens += value
                    hasInputTokens = true
                }
                if let value = result.outputTokens {
                    outputTokens += value
                    hasOutputTokens = true
                }
                modelID = result.modelID
            }
            clearFailure()
            return TranscriptCleanupOutcome(
                text: cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                source: provider.providerID.outcomeSource,
                inputTokens: hasInputTokens ? inputTokens : nil,
                outputTokens: hasOutputTokens ? outputTokens : nil,
                modelID: modelID
            )
        } catch {
            print("Transcript cleanup unavailable; using local transcript: \(error.localizedDescription)")
            recordFailure(error.localizedDescription)
            return TranscriptCleanupOutcome(
                text: localTranscript,
                source: .rawFallback,
                inputTokens: hasInputTokens ? inputTokens : nil,
                outputTokens: hasOutputTokens ? outputTokens : nil,
                modelID: modelID
            )
        }
    }

    private func recordFailure(_ message: String) {
        AppPreferences.shared.bedrockLastErrorMessage = message
        AppPreferences.shared.bedrockLastErrorDate = Date()
    }

    private func clearFailure() {
        AppPreferences.shared.bedrockLastErrorMessage = nil
        AppPreferences.shared.bedrockLastErrorDate = nil
    }
}
