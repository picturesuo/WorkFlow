import Foundation

struct TranscriptCleanupOutcome: Equatable {
    enum Source: String, Codable, Equatable {
        case bedrock
        case ollama
        case openAICompatible = "openai_compatible"
        case azureOpenAI = "azure_openai"
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
    /// Set only when a saved custom filter shaped this cleanup.
    let customFilterName: String?
    let customFilterInstructions: String?
    let rawTokenEstimate: Int?
    let finalTokenEstimate: Int?
    let tokenEstimatorID: String?
    /// The text cleanup received: the recognizer's words after vocabulary.
    let cleanupInput: String?
    /// The mode and filter selected for this dictation, kept even when
    /// cleanup was off and so shaped nothing.
    let selectedFilter: CleanupFilterSnapshot?

    /// Whether the saved filter that shaped this cleanup writes quantities as digits.
    var customFilterWritesDigits: Bool {
        customFilterName != nil && selectedFilter?.customWritesDigits == true
    }

    init(
        text: String,
        source: Source,
        inputTokens: Int?,
        outputTokens: Int?,
        modelID: String?,
        cleanupMode: CleanupMode? = nil,
        customFilterName: String? = nil,
        customFilterInstructions: String? = nil,
        rawTokenEstimate: Int? = nil,
        finalTokenEstimate: Int? = nil,
        tokenEstimatorID: String? = nil,
        cleanupInput: String? = nil,
        selectedFilter: CleanupFilterSnapshot? = nil
    ) {
        self.text = text
        self.source = source
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelID = modelID
        self.cleanupMode = cleanupMode
        self.customFilterName = customFilterName
        self.customFilterInstructions = customFilterInstructions
        self.rawTokenEstimate = rawTokenEstimate
        self.finalTokenEstimate = finalTokenEstimate
        self.tokenEstimatorID = tokenEstimatorID
        self.cleanupInput = cleanupInput
        self.selectedFilter = selectedFilter
    }

    init(
        text: String,
        source: Source,
        inputTokens: Int?,
        outputTokens: Int?,
        modelID: String?,
        filter: CleanupFilterSnapshot,
        rawTokenEstimate: Int?,
        finalTokenEstimate: Int?,
        tokenEstimatorID: String?,
        cleanupInput: String? = nil
    ) {
        self.init(
            text: text,
            source: source,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            modelID: modelID,
            cleanupMode: filter.mode,
            customFilterName: filter.customName,
            customFilterInstructions: filter.customInstructions,
            rawTokenEstimate: rawTokenEstimate,
            finalTokenEstimate: finalTokenEstimate,
            tokenEstimatorID: tokenEstimatorID,
            cleanupInput: cleanupInput,
            selectedFilter: filter
        )
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
    private let filterProvider: () -> CleanupFilterSnapshot
    /// Records the last cleanup failure, or clears it with nil.
    private let failureRecorder: (String?) -> Void

    init(
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.bedrockCleanupEnabled },
        providerResolver: @escaping () throws -> any TranscriptCleanupProviding = {
            try CleanupProviderFactory.makeSelected()
        },
        vocabularyProvider: @escaping () -> [VocabularyEntry] = { VocabularyStore.load() },
        appRuleProvider: @escaping (String?) -> TargetAppRule? = { TargetAppRuleStore.rule(for: $0) },
        bedrockBudgetProvider: @escaping () async -> BedrockBudgetStatus? = {
            await BedrockBudgetStatus.current()
        },
        filterProvider: @escaping () -> CleanupFilterSnapshot = {
            CustomCleanupFilterStore.currentSnapshot()
        },
        failureRecorder: @escaping (String?) -> Void = { message in
            AppPreferences.shared.bedrockLastErrorMessage = message
            AppPreferences.shared.bedrockLastErrorDate = message == nil ? nil : Date()
        }
    ) {
        self.isEnabled = isEnabled
        self.providerResolver = providerResolver
        self.vocabularyProvider = vocabularyProvider
        self.appRuleProvider = appRuleProvider
        self.bedrockBudgetProvider = bedrockBudgetProvider
        self.filterProvider = filterProvider
        self.failureRecorder = failureRecorder
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

    /// The filter a dictation stopped now would use, captured once per dictation.
    func selectedFilter() -> CleanupFilterSnapshot {
        filterProvider()
    }

    /// Whether `finalize` would clean up a dictation for this app.
    func cleanupRequested(targetBundleID: String?) -> Bool {
        TargetAppRuleStore.cleanupEnabled(rule: appRuleProvider(targetBundleID), globalDefault: isEnabled())
    }

    func finalize(
        _ rawTranscript: String,
        targetBundleID: String? = nil,
        cleanupOverride: Bool? = nil,
        filterOverride: CleanupFilterSnapshot? = nil
    ) async -> TranscriptCleanupOutcome {
        let vocabulary = vocabularyProvider()
        let localTranscript = VocabularyRewriter.apply(rawTranscript, entries: vocabulary)
        let rawTokenEstimate = LocalTokenEstimator.estimate(rawTranscript)
        let filter = filterOverride ?? filterProvider()
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
                tokenEstimatorID: LocalTokenEstimator.identifier,
                cleanupInput: localTranscript,
                selectedFilter: filter
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
                    filter: filter,
                    rawTokenEstimate: rawTokenEstimate,
                    finalTokenEstimate: LocalTokenEstimator.estimate(localTranscript),
                    tokenEstimatorID: LocalTokenEstimator.identifier,
                    cleanupInput: localTranscript
                )
            }
            let systemPrompt = CleanupPromptBuilder.systemPrompt(
                filter: filter,
                instruction: appRule?.cleanupInstruction
            )
            let chunks = TranscriptChunker.chunks(localTranscript)
            var cleanedTranscript = ""
            for chunk in chunks {
                let result = try await provider.clean(
                    transcript: chunk.text,
                    systemPrompt: systemPrompt,
                    filter: filter
                )
                cleanedTranscript += Self.digits(result.text, source: chunk.text, filter: filter) + chunk.separatorAfter
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
                filter: filter,
                rawTokenEstimate: rawTokenEstimate,
                finalTokenEstimate: LocalTokenEstimator.estimate(finalText),
                tokenEstimatorID: LocalTokenEstimator.identifier,
                cleanupInput: localTranscript
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
                filter: filter,
                rawTokenEstimate: rawTokenEstimate,
                finalTokenEstimate: LocalTokenEstimator.estimate(localTranscript),
                tokenEstimatorID: LocalTokenEstimator.identifier,
                cleanupInput: localTranscript
            )
        }
    }

    /// Homework, and a saved filter that asks for it, writes quantities as
    /// digits, which models do not reliably do, so that is finished here. The
    /// guard checks the result again, and a rewrite it refuses keeps the
    /// model's own text.
    private static func digits(_ text: String, source: String, filter: CleanupFilterSnapshot) -> String {
        guard filter.writesDigits else { return text }
        let formatted = HomeworkNumberFormatter.format(text)
        guard formatted != text,
              let checked = try? CleanupGuard.postprocess(
                  formatted, source: source, mode: filter.mode, allowsNumberFormatting: filter.allowsNumberFormatting
              ) else { return text }
        return checked
    }

    private func recordFailure(_ message: String) {
        failureRecorder(message)
    }

    private func clearFailure() {
        failureRecorder(nil)
    }
}

struct BedrockBudgetStatus: Equatable {
    let spentUSD: Double
    let limitUSD: Double

    var isExhausted: Bool {
        limitUSD > 0 && spentUSD >= limitUSD
    }
}
