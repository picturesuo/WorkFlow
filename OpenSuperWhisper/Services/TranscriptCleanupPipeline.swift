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
    let cleanupMode: CleanupMode?
    let rawTokenEstimate: Int?
    let finalTokenEstimate: Int?
    let tokenEstimatorID: String?

    init(
        text: String,
        source: Source,
        inputTokens: Int?,
        outputTokens: Int?,
        modelID: String?,
        cleanupMode: CleanupMode? = nil,
        rawTokenEstimate: Int? = nil,
        finalTokenEstimate: Int? = nil,
        tokenEstimatorID: String? = nil
    ) {
        self.text = text
        self.source = source
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelID = modelID
        self.cleanupMode = cleanupMode
        self.rawTokenEstimate = rawTokenEstimate
        self.finalTokenEstimate = finalTokenEstimate
        self.tokenEstimatorID = tokenEstimatorID
    }
}

final class TranscriptCleanupPipeline {
    static let shared = TranscriptCleanupPipeline()
    static let safeFailureMessage = "Cleanup failed; local text was used."

    private let isEnabled: () -> Bool
    private let providerResolver: () throws -> any TranscriptCleanupProviding
    private let vocabularyProvider: () -> [VocabularyEntry]
    private let appRuleProvider: (String?) -> TargetAppRule?
    private let bedrockBudgetProvider: () async -> BedrockBudgetStatus?
    private let cleanupModeProvider: () -> CleanupMode

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
        },
        cleanupModeProvider: @escaping () -> CleanupMode = {
            CleanupMode(rawValue: AppPreferences.shared.cleanupMode) ?? .everyday
        }
    ) {
        self.isEnabled = isEnabled
        self.providerResolver = providerResolver
        self.vocabularyProvider = vocabularyProvider
        self.appRuleProvider = appRuleProvider
        self.bedrockBudgetProvider = bedrockBudgetProvider
        self.cleanupModeProvider = cleanupModeProvider
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
            bedrockBudgetProvider: { nil },
            cleanupModeProvider: {
                CleanupMode(rawValue: AppPreferences.shared.cleanupMode) ?? .everyday
            }
        )
    }

    func finalize(
        _ rawTranscript: String,
        targetBundleID: String? = nil,
        cleanupOverride: Bool? = nil,
        cleanupModeOverride: CleanupMode? = nil
    ) async -> TranscriptCleanupOutcome {
        let vocabulary = vocabularyProvider()
        let localTranscript = VocabularyRewriter.apply(rawTranscript, entries: vocabulary)
        let rawTokenEstimate = LocalTokenEstimator.estimate(rawTranscript)
        let cleanupMode = cleanupModeOverride ?? cleanupModeProvider()
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
                modelID: nil,
                rawTokenEstimate: rawTokenEstimate,
                finalTokenEstimate: LocalTokenEstimator.estimate(localTranscript),
                tokenEstimatorID: LocalTokenEstimator.identifier
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
                    modelID: AppPreferences.shared.bedrockModelID,
                    cleanupMode: cleanupMode,
                    rawTokenEstimate: rawTokenEstimate,
                    finalTokenEstimate: LocalTokenEstimator.estimate(localTranscript),
                    tokenEstimatorID: LocalTokenEstimator.identifier
                )
            }
            let systemPrompt = CleanupPromptBuilder.systemPrompt(
                mode: cleanupMode,
                instruction: appRule?.cleanupInstruction
            )
            let chunks = TranscriptChunker.chunks(localTranscript)
            var cleanedTranscript = ""
            for chunk in chunks {
                let result = try await provider.clean(
                    transcript: chunk.text,
                    systemPrompt: systemPrompt,
                    cleanupMode: cleanupMode
                )
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
            let finalText = cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptCleanupOutcome(
                text: finalText,
                source: provider.providerID.outcomeSource,
                inputTokens: hasInputTokens ? inputTokens : nil,
                outputTokens: hasOutputTokens ? outputTokens : nil,
                modelID: modelID,
                cleanupMode: cleanupMode,
                rawTokenEstimate: rawTokenEstimate,
                finalTokenEstimate: LocalTokenEstimator.estimate(finalText),
                tokenEstimatorID: LocalTokenEstimator.identifier
            )
        } catch {
            print(Self.safeFailureMessage)
            recordFailure(Self.safeFailureMessage)
            return TranscriptCleanupOutcome(
                text: localTranscript,
                source: .rawFallback,
                inputTokens: hasInputTokens ? inputTokens : nil,
                outputTokens: hasOutputTokens ? outputTokens : nil,
                modelID: modelID,
                cleanupMode: cleanupMode,
                rawTokenEstimate: rawTokenEstimate,
                finalTokenEstimate: LocalTokenEstimator.estimate(localTranscript),
                tokenEstimatorID: LocalTokenEstimator.identifier
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
