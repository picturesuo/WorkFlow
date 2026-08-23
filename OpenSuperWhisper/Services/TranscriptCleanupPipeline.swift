import Foundation

struct TranscriptCleanupOutcome: Equatable {
    enum Source: String, Codable, Equatable {
        case bedrock
        case ollama
        case openAICompatible = "openai_compatible"
        case rawFallback
        case budgetLimited = "budget_limited"
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
    private let bedrockBudgetProvider: () async -> BedrockBudgetStatus?

    init(
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.bedrockCleanupEnabled },
        providerResolver: @escaping () throws -> any TranscriptCleanupProviding = {
            try CleanupProviderFactory.makeSelected()
        },
        vocabularyProvider: @escaping () -> [VocabularyEntry] = { VocabularyStore.load() },
        appRuleProvider: @escaping (String?) -> TargetAppRule? = { TargetAppRuleStore.rule(for: $0) },
        bedrockBudgetProvider: @escaping () async -> BedrockBudgetStatus? = {
            let prefs = AppPreferences.shared
            guard prefs.bedrockMonthlyBudgetEnabled,
                  BedrockPricing.supports(modelID: prefs.bedrockModelID) else { return nil }
            let now = Date()
            let parts = Calendar.current.dateComponents([.year, .month], from: now)
            let monthStart = Calendar.current.date(from: parts) ?? now
            let spent = (try? await RecordingStore.shared.bedrockUsage(since: monthStart).estimatedCostUSD) ?? 0
            return BedrockBudgetStatus(spentUSD: spent, limitUSD: prefs.bedrockMonthlyBudgetUSD)
        }
    ) {
        self.isEnabled = isEnabled
        self.providerResolver = providerResolver
        self.vocabularyProvider = vocabularyProvider
        self.appRuleProvider = appRuleProvider
        self.bedrockBudgetProvider = bedrockBudgetProvider
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
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil }
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
            if provider.providerID == .bedrock,
               let budget = await bedrockBudgetProvider(),
               budget.isExhausted {
                clearFailure()
                print("Monthly Bedrock limit reached; using local text until next month.")
                return TranscriptCleanupOutcome(
                    text: localTranscript,
                    source: .budgetLimited,
                    inputTokens: nil,
                    outputTokens: nil,
                    modelID: AppPreferences.shared.bedrockModelID
                )
            }
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

struct BedrockBudgetStatus: Equatable {
    let spentUSD: Double
    let limitUSD: Double

    var isExhausted: Bool {
        limitUSD > 0 && spentUSD >= limitUSD
    }
}
