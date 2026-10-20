import Combine
import Foundation

/// Learns validated style preferences for one mode from a finished document
/// the user pastes. Nothing is read from History or sent until `learn()`;
/// the document itself is never stored, and only short matched edits are
/// sent to the selected cleanup provider. Learned preferences apply at once.
@MainActor
final class CorrectionLearningSession: ObservableObject {
    @Published var document = ""
    @Published var mode: CleanupMode
    @Published private(set) var isLearning = false
    @Published private(set) var report: CorrectionLearningReport?
    @Published private(set) var errorMessage: String?

    let destination: CleanupProviderDestination
    private let chatResolver: () throws -> any CleanupChatCompleting
    private let budgetProvider: () async -> BedrockBudgetStatus?
    private let candidateProvider: () async throws -> [CorrectionCandidate]
    private let defaults: UserDefaults
    private var generationID: UUID?
    private var learningTask: Task<Void, Never>?

    init(
        mode: CleanupMode = .everyday,
        destination: CleanupProviderDestination = CleanupProviderFactory.selectedDestination(),
        chatResolver: @escaping () throws -> any CleanupChatCompleting = { try CleanupProviderFactory.makeSelectedChat() },
        budgetProvider: @escaping () async -> BedrockBudgetStatus? = { await BedrockBudgetStatus.current() },
        candidateProvider: @escaping () async throws -> [CorrectionCandidate] = {
            try await RecordingStore.shared.learningCandidates()
        },
        defaults: UserDefaults = .standard
    ) {
        self.mode = mode
        self.destination = destination
        self.chatResolver = chatResolver
        self.budgetProvider = budgetProvider
        self.candidateProvider = candidateProvider
        self.defaults = defaults
    }

    var canLearn: Bool {
        !isLearning && LearnedPreferenceStore.isLearningEnabled(in: defaults)
            && !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func learn() {
        guard !isLearning else { return }
        let document = document.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard LearnedPreferenceStore.isLearningEnabled(in: defaults) else { throw CorrectionLearningError.learningDisabled }
            guard !document.isEmpty else { throw CorrectionLearningError.emptyDocument }
            guard document.count <= CorrectionAligner.maximumDocumentLength else { throw CorrectionLearningError.documentTooLong }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // The mode is fixed at submission; switching the picker mid-flight
        // cannot redirect what this request learns.
        let mode = mode
        let id = UUID()
        generationID = id
        isLearning = true
        errorMessage = nil
        report = nil
        learningTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(document: document, mode: mode)
            guard self.generationID == id, !Task.isCancelled else { return }
            self.generationID = nil
            self.learningTask = nil
            self.isLearning = false
            switch outcome {
            case .finished(var report, let accepted, let reviewed):
                if !reviewed.isEmpty {
                    // Learning switched off mid-flight discards the result.
                    guard LearnedPreferenceStore.isLearningEnabled(in: self.defaults) else {
                        self.errorMessage = CorrectionLearningError.learningDisabled.localizedDescription
                        return
                    }
                    LearnedPreferenceStore.markReviewed(reviewed, for: mode, in: self.defaults)
                }
                if !accepted.isEmpty {
                    report.merge = LearnedPreferenceStore.merge(accepted, into: mode, in: self.defaults)
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

    func cancel() {
        guard isLearning else { return }
        generationID = nil
        learningTask?.cancel()
        learningTask = nil
        isLearning = false
        errorMessage = "Cancelled. Nothing was learned."
    }

    private enum Outcome {
        /// The report, validated preferences, and fingerprints of every edit
        /// the provider classified.
        case finished(CorrectionLearningReport, [LearnedPreference], [String])
        case failure(String)
    }

    private func run(document: String, mode: CleanupMode) async -> Outcome {
        do {
            let candidates = try await candidateProvider()
            try Task.checkCancellation()
            let alignment = await Task.detached(priority: .userInitiated) {
                CorrectionAligner.align(document: document, candidates: candidates)
            }.value
            try Task.checkCancellation()

            let edits = alignment.edits
            let matched = alignment.matchedDictations
            let legacy = Set(alignment.passages.filter(\.isLegacy).map(\.candidateID))
            func report(_ status: CorrectionLearningReport.Status, rejected: Int = 0) -> CorrectionLearningReport {
                CorrectionLearningReport(
                    status: status,
                    mode: mode,
                    matchedPassages: alignment.passages.count,
                    matchedDictations: matched.count,
                    legacyDictations: legacy.count,
                    learnableEdits: edits.count,
                    excludedEdits: alignment.excludedEdits,
                    ambiguousRegions: alignment.ambiguousRegions,
                    rejectedProposals: rejected
                )
            }
            guard !alignment.passages.isEmpty else { return .finished(report(.noMatch), [], []) }
            guard !edits.isEmpty else { return .finished(report(.noLearnableEdits), [], []) }

            // A repeated submission sends nothing: its edits are already known.
            let known = LearnedPreferenceStore.knownEvidence(for: mode, in: defaults)
            let fresh = edits.filter { !known.contains($0.fingerprint) }
            guard !fresh.isEmpty else { return .finished(report(.nothingNew), [], []) }

            let provider = try chatResolver()
            if provider.providerID == .bedrock, let budget = await budgetProvider(), budget.isExhausted {
                throw CorrectionLearningError.budgetReached
            }
            try Task.checkCancellation()
            let result = try await provider.complete(CorrectionLearningPrompt.request(mode: mode, edits: fresh))
            FilterAssistantUsageStore.record(
                providerID: provider.providerID,
                modelID: result.modelID,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                in: defaults
            )
            try Task.checkCancellation()
            let proposals = try CorrectionLearningPrompt.parse(result.text)
            let validated = CorrectionPreferenceValidator.validate(proposals, edits: fresh, mode: mode)
            guard !validated.accepted.isEmpty else {
                return .finished(report(.nothingQualified, rejected: validated.rejected), [], fresh.map(\.fingerprint))
            }
            return .finished(report(.learned, rejected: validated.rejected), validated.accepted, fresh.map(\.fingerprint))
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
