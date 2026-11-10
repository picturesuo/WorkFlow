import Combine
import Foundation

/// Learns validated style preferences from a finished document the user
/// pastes, drops, or chooses as a file. Each matched dictation teaches the
/// mode or saved filter it was made with. Nothing is read from History until
/// Check matches or Learn; Check matches sends nothing, and Learn sends only
/// short matched edits to the selected cleanup provider. The document itself
/// is never stored. Learned preferences apply at once.
@MainActor
final class CorrectionLearningSession: ObservableObject {
    @Published var document = ""
    /// The mode older History without a recorded mode teaches. Dictations
    /// with a recorded mode or filter always teach that one.
    @Published var mode: CleanupMode
    @Published private(set) var isLearning = false
    @Published private(set) var isChecking = false
    @Published private(set) var isLoadingFile = false
    @Published private(set) var fileSummary: String?
    @Published private(set) var report: CorrectionLearningReport?
    @Published private(set) var errorMessage: String?
    /// A short non-blocking note about moving a word into Vocabulary, such as
    /// when Vocabulary is full, shown without hiding the report.
    @Published private(set) var vocabularyNotice: String?
    /// Word changes added to Vocabulary from the current report.
    @Published private(set) var addedWordChanges: Set<String> = []
    /// Learned preferences' source dictations no longer in History, as of the
    /// last Check matches or Learn.
    @Published private(set) var missingSources: Set<UUID> = []

    let destination: CleanupProviderDestination
    private let chatResolver: () throws -> any CleanupChatCompleting
    private let budgetProvider: () async -> BedrockBudgetStatus?
    private let candidateProvider: () async throws -> [CorrectionCandidate]
    private let filterProvider: () -> [CustomCleanupFilter]
    private let retentionProvider: () -> Int?
    private let sourceChecker: ([UUID]) async throws -> Set<UUID>
    private let vocabularyAdder: (VocabularyEntry) -> Bool
    private let defaults: UserDefaults
    private var generationID: UUID?
    private var learningTask: Task<Void, Never>?
    private var loadID: UUID?

    init(
        mode: CleanupMode = .everyday,
        destination: CleanupProviderDestination = CleanupProviderFactory.selectedDestination(),
        chatResolver: @escaping () throws -> any CleanupChatCompleting = { try CleanupProviderFactory.makeSelectedChat() },
        budgetProvider: @escaping () async -> BedrockBudgetStatus? = { await BedrockBudgetStatus.current() },
        candidateProvider: @escaping () async throws -> [CorrectionCandidate] = {
            try await RecordingStore.shared.learningCandidates()
        },
        filterProvider: (() -> [CustomCleanupFilter])? = nil,
        retentionProvider: @escaping () -> Int? = {
            AppPreferences.shared.autoDeleteRecordingsEnabled ? AppPreferences.shared.autoDeleteRecordingsAfterDays : nil
        },
        sourceChecker: @escaping ([UUID]) async throws -> Set<UUID> = { ids in
            try await RecordingStore.shared.existingRecordingIDs(ids)
        },
        vocabularyAdder: @escaping (VocabularyEntry) -> Bool = { VocabularyStore.add($0) },
        defaults: UserDefaults = .standard
    ) {
        self.mode = mode
        self.destination = destination
        self.chatResolver = chatResolver
        self.budgetProvider = budgetProvider
        self.candidateProvider = candidateProvider
        self.filterProvider = filterProvider ?? { CustomCleanupFilterStore.load(from: defaults) }
        self.retentionProvider = retentionProvider
        self.sourceChecker = sourceChecker
        self.vocabularyAdder = vocabularyAdder
        self.defaults = defaults
    }

    var isBusy: Bool { isLearning || isChecking }

    var canLearn: Bool {
        !isBusy && !isLoadingFile && LearnedPreferenceStore.isLearningEnabled(in: defaults)
            && !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && document.count <= CorrectionAligner.maximumDocumentLength
    }

    /// Learns from the document: matches it on this Mac, then sends the
    /// edits shown in the plan.
    func learn() { start(sending: true) }

    /// Matches the document on this Mac and shows what Learn would do,
    /// without sending anything or changing what was learned.
    func check() { start(sending: false) }

    private func start(sending: Bool) {
        guard !isBusy, !isLoadingFile else { return }
        let document = document.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard LearnedPreferenceStore.isLearningEnabled(in: defaults) else { throw CorrectionLearningError.learningDisabled }
            guard !document.isEmpty else { throw CorrectionLearningError.emptyDocument }
            guard document.count <= CorrectionAligner.maximumDocumentLength else { throw CorrectionLearningError.documentTooLong }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // The fallback mode, the saved filters, and what was already learned
        // are fixed at submission; changing them mid-flight cannot redirect
        // what this request learns.
        let context = Context(
            fallbackMode: mode,
            filters: filterProvider(),
            knownEvidence: knownEvidence(),
            storedSources: Array(Set(LearnedPreferenceStore.load(from: defaults).flatMap(\.sourceRecordingIDs))),
            retentionDays: retentionProvider()
        )
        let id = UUID()
        generationID = id
        if sending { isLearning = true } else { isChecking = true }
        errorMessage = nil
        report = nil
        fileSummary = nil
        addedWordChanges = []
        vocabularyNotice = nil
        learningTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(document: document, context: context, sending: sending)
            guard self.generationID == id, !Task.isCancelled else { return }
            self.generationID = nil
            self.learningTask = nil
            self.isLearning = false
            self.isChecking = false
            switch outcome {
            case .finished(var report, let accepted, let reviewed, let missing):
                if let missing { self.missingSources = missing }
                if let target = report.target, !reviewed.isEmpty {
                    // Learning switched off mid-flight discards the result.
                    guard LearnedPreferenceStore.isLearningEnabled(in: self.defaults) else {
                        self.errorMessage = CorrectionLearningError.learningDisabled.localizedDescription
                        return
                    }
                    LearnedPreferenceStore.markReviewed(reviewed, for: target, in: self.defaults)
                }
                if let target = report.target, !accepted.isEmpty {
                    report.merge = LearnedPreferenceStore.merge(accepted, into: target, in: self.defaults)
                    report.proposals = Self.resolve(report.proposals, with: report.merge)
                    let changed = !report.merge.added.isEmpty || !report.merge.reinforced.isEmpty
                    report.status = changed ? .learned : .nothingNew
                    if changed {
                        NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
                    }
                }
                self.report = report
            case .failure(let message):
                self.errorMessage = message
            }
        }
    }

    /// Adds a word change from the report to Vocabulary, the person's own
    /// explicit choice; learning never adds one by itself.
    func addToVocabulary(_ change: CorrectionLearningPlan.WordChange) {
        guard !addedWordChanges.contains(change.id) else { return }
        guard vocabularyAdder(VocabularyEntry(spoken: change.spoken, replacement: change.replacement)) else {
            vocabularyNotice = Self.vocabularyFullNotice
            return
        }
        vocabularyNotice = nil
        addedWordChanges.insert(change.id)
    }

    /// Moves a kept word-change preference that no longer applies into
    /// Vocabulary, then removes it from what was learned.
    func moveToVocabulary(_ preference: LearnedPreference) {
        guard preference.inactivity == .wordChange, let from = preference.from, let to = preference.to else { return }
        guard vocabularyAdder(VocabularyEntry(spoken: from, replacement: to)) else {
            vocabularyNotice = Self.vocabularyFullNotice
            return
        }
        vocabularyNotice = nil
        LearnedPreferenceStore.delete(preference.id, in: defaults)
    }

    private static let vocabularyFullNotice = "Vocabulary is full (\(VocabularyStore.maximumEntries) entries), so nothing was moved. Remove an entry in Vocabulary, then try again."

    private struct Context: Sendable {
        let fallbackMode: CleanupMode
        let filters: [CustomCleanupFilter]
        let knownEvidence: [String: Set<String>]
        let storedSources: [UUID]
        let retentionDays: Int?
    }

    private func knownEvidence() -> [String: Set<String>] {
        let targets = CleanupMode.allCases.map { LearningTarget.mode($0) } + filterProvider().map { LearningTarget.filter($0) }
        return Dictionary(targets.map { ($0.storageKey, LearnedPreferenceStore.knownEvidence(for: $0, in: defaults)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Marks merged proposals learned, reinforced, already learned, or over the limit.
    static func resolve(_ outcomes: [ProposalOutcome], with merge: LearnedPreferenceStore.MergeResult) -> [ProposalOutcome] {
        let added = Set(merge.added.map(\.key))
        let reinforced = Set(merge.reinforced.map(\.key))
        return outcomes.map { outcome in
            guard outcome.status == .learned, let key = outcome.key else { return outcome }
            var value = outcome
            value.status = added.contains(key) ? .learned : reinforced.contains(key) ? .reinforced
                : merge.skippedForLimitKeys.contains(key) ? .overLimit : .alreadyLearned
            return value
        }
    }

    static let maximumLoadedCharacters = 4 * CorrectionAligner.maximumDocumentLength

    /// Replaces the document with the text of the given files, read on this
    /// Mac. Several files join in the order given, separated by a blank line.
    func load(_ urls: [URL]) {
        guard !isBusy else { return }
        var seen = Set<URL>()
        let urls = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        guard !urls.isEmpty else { return }
        let id = UUID()
        loadID = id
        isLoadingFile = true
        errorMessage = nil
        report = nil
        fileSummary = nil
        let limit = Self.maximumLoadedCharacters
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                // A file somewhat over the limit loads so it can be trimmed;
                // far beyond it, nothing is loaded.
                Result { try urls.map { try DocumentTextExtractor.text(from: $0, maximumCharacters: limit) } }
            }.value
            guard let self, self.loadID == id else { return }
            self.loadID = nil
            self.isLoadingFile = false
            switch result {
            case .success(let texts) where texts.reduce(0, { $0 + $1.count }) > limit:
                self.errorMessage = "These files have more than \(limit.formatted()) characters together. Add fewer files or paste only the part you dictated."
            case .success(let texts):
                let text = texts.joined(separator: "\n\n")
                self.document = text
                let names = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
                var summary = "Loaded \(names): \(text.count.formatted()) characters. Check the text, then select Learn."
                if text.count > CorrectionAligner.maximumDocumentLength {
                    summary = "Loaded \(names), but it has \(text.count.formatted()) characters. Remove parts you did not dictate to fit \(CorrectionAligner.maximumDocumentLength.formatted())."
                }
                self.fileSummary = summary
            case .failure(let error):
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "The file could not be read."
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        let wasLearning = isLearning
        generationID = nil
        learningTask?.cancel()
        learningTask = nil
        isLearning = false
        isChecking = false
        errorMessage = wasLearning ? "Cancelled. Nothing was learned." : "Cancelled."
    }

    private enum Outcome {
        /// The report, validated preferences, fingerprints of every edit the
        /// provider classified, and source dictations no longer in History.
        case finished(CorrectionLearningReport, [LearnedPreference], [String], Set<UUID>?)
        case failure(String)
    }

    private func run(document: String, context: Context, sending: Bool) async -> Outcome {
        do {
            let candidates = try await candidateProvider()
            try Task.checkCancellation()
            let plan = await Task.detached(priority: .userInitiated) {
                CorrectionLearningPlan.make(
                    document: document,
                    candidates: candidates,
                    filters: context.filters,
                    fallbackMode: context.fallbackMode,
                    knownEvidence: context.knownEvidence
                )
            }.value
            try Task.checkCancellation()
            // Which learned preferences' dictations are gone; a failed check
            // only leaves the labels as they were.
            var missing: Set<UUID>?
            if !context.storedSources.isEmpty, let existing = try? await sourceChecker(context.storedSources) {
                missing = Set(context.storedSources).subtracting(existing)
            }
            try Task.checkCancellation()

            func report(_ status: CorrectionLearningReport.Status) -> CorrectionLearningReport {
                CorrectionLearningReport(
                    status: status, plan: plan, fallbackMode: context.fallbackMode, retentionDays: context.retentionDays
                )
            }
            guard plan.matchedDictations > 0 else { return .finished(report(.noMatch), [], [], missing) }
            guard plan.learnableEdits > 0 else { return .finished(report(.noLearnableEdits), [], [], missing) }
            // A repeated submission sends nothing: its edits are already known.
            guard let target = plan.target, !plan.batch.isEmpty else { return .finished(report(.nothingNew), [], [], missing) }
            guard sending else { return .finished(report(.ready), [], [], missing) }

            let provider = try chatResolver()
            if provider.providerID == .bedrock, let budget = await budgetProvider(), budget.isExhausted {
                throw CorrectionLearningError.budgetReached
            }
            try Task.checkCancellation()
            let result = try await provider.complete(CorrectionLearningPrompt.request(target: target, edits: plan.batch))
            FilterAssistantUsageStore.record(
                providerID: provider.providerID,
                modelID: result.modelID,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                in: defaults
            )
            try Task.checkCancellation()
            let proposals = try CorrectionLearningPrompt.parse(result.text)
            let validated = CorrectionPreferenceValidator.validate(proposals, edits: plan.batch, target: target)
            var finished = report(validated.accepted.isEmpty ? .nothingQualified : .learned)
            finished.proposals = validated.outcomes
            finished.rejectedProposals = validated.rejected
            return .finished(finished, validated.accepted, plan.batch.map(\.fingerprint), missing)
        } catch is CancellationError {
            return .failure("Cancelled. Nothing was learned.")
        } catch let error as URLError where error.code == .timedOut {
            return .failure("The provider did not answer in time. Nothing was learned.")
        } catch let error as URLError where error.code == .cancelled {
            return .failure("Cancelled. Nothing was learned.")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? "The request failed."
            return .failure(String(description.prefix(300)) + (error is CorrectionLearningError ? "" : " Nothing was learned."))
        }
    }
}
