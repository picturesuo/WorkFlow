import Combine
import Foundation

/// One conversation that drafts a new filter or improves a saved one. Saved
/// filters and the global selection change only through `save`.
@MainActor
final class FilterAssistantSession: ObservableObject {
    enum Target: Equatable {
        case new
        /// The filter as it was when the conversation started.
        case existing(CustomCleanupFilter)
    }

    struct Entry: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
    }

    let target: Target
    @Published var request = ""
    @Published var example = ""
    @Published var context = ""
    /// The editable proposal. Read-only while a request is in flight, so a
    /// late reply can never overwrite the user's own edits.
    @Published var proposal: FilterAssistantProposal?
    @Published var selectAfterSaving = true
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage: String?
    /// Set when the saved target was edited or deleted elsewhere.
    @Published private(set) var hasSaveConflict = false

    let destination: CleanupProviderDestination
    private let chatResolver: () throws -> any CleanupChatCompleting
    private let budgetProvider: () async -> BedrockBudgetStatus?
    private let defaults: UserDefaults
    private var messages: [ProviderChatMessage] = []
    private var lastSentExample = ""
    private var lastSentContext = ""
    private var generationID: UUID?
    private var generationTask: Task<Void, Never>?
    private let newFilterID = UUID()

    init(
        target: Target,
        destination: CleanupProviderDestination = CleanupProviderFactory.selectedDestination(),
        chatResolver: @escaping () throws -> any CleanupChatCompleting = { try CleanupProviderFactory.makeSelectedChat() },
        budgetProvider: @escaping () async -> BedrockBudgetStatus? = { await BedrockBudgetStatus.current() },
        defaults: UserDefaults = .standard
    ) {
        self.target = target
        self.destination = destination
        self.chatResolver = chatResolver
        self.budgetProvider = budgetProvider
        self.defaults = defaults
    }

    var userTurnCount: Int { messages.filter { $0.role == .user }.count }

    var canSend: Bool {
        !isGenerating && userTurnCount < FilterAssistantPrompt.maximumUserTurns
            && !(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 && example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Sends the composer to the selected provider. Nothing leaves the Mac
    /// until this is called.
    func send() {
        guard !isGenerating else { return }
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let example = example.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !request.isEmpty || !example.isEmpty else { throw FilterAssistantError.emptyRequest }
            guard request.count <= FilterAssistantPrompt.maximumRequestLength else { throw FilterAssistantError.requestTooLong }
            guard example.count <= FilterAssistantPrompt.maximumExampleLength else { throw FilterAssistantError.exampleTooLong }
            guard context.count <= FilterAssistantPrompt.maximumContextLength else { throw FilterAssistantError.contextTooLong }
            guard userTurnCount < FilterAssistantPrompt.maximumUserTurns else { throw FilterAssistantError.conversationTooLong }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // The example and class are sent once, then again only when changed.
        let existing: CustomCleanupFilter? = if case .existing(let filter) = target { filter } else { nil }
        let content = FilterAssistantPrompt.userMessage(
            request: request,
            example: example == lastSentExample ? nil : example,
            context: context == lastSentContext ? nil : context,
            currentDraft: proposal,
            existingFilter: existing
        )
        let outgoing = messages + [ProviderChatMessage(role: .user, content: content)]
        guard outgoing.reduce(0, { $0 + $1.content.count }) <= FilterAssistantPrompt.maximumConversationLength else {
            errorMessage = FilterAssistantError.conversationTooLong.localizedDescription
            return
        }

        let id = UUID()
        generationID = id
        isGenerating = true
        errorMessage = nil
        let chatRequest = ProviderChatRequest(
            systemPrompt: FilterAssistantPrompt.systemPrompt,
            messages: outgoing,
            maxOutputTokens: FilterAssistantPrompt.maximumOutputTokens,
            minimumTimeout: FilterAssistantPrompt.minimumTimeout
        )
        let summary = request.isEmpty ? "Match the style of my example." : request
        generationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.generate(chatRequest)
            guard self.generationID == id, !Task.isCancelled else { return }
            self.generationID = nil
            self.generationTask = nil
            self.isGenerating = false
            switch outcome {
            case .success(let (raw, reply)):
                self.messages = outgoing + [ProviderChatMessage(role: .assistant, content: raw)]
                self.lastSentExample = example
                self.lastSentContext = context
                self.entries.append(Entry(role: .user, text: summary))
                self.entries.append(Entry(role: .assistant, text: reply.message))
                if let proposal = reply.proposal {
                    self.proposal = proposal
                    self.hasSaveConflict = false
                }
                self.request = ""
            case .failure(let message):
                self.errorMessage = message
            }
        }
    }

    private enum Outcome {
        case success((String, FilterAssistantReply))
        case failure(String)
    }

    private func generate(_ chatRequest: ProviderChatRequest) async -> Outcome {
        do {
            let provider = try chatResolver()
            if provider.providerID == .bedrock, let budget = await budgetProvider(), budget.isExhausted {
                throw FilterAssistantError.budgetReached
            }
            try Task.checkCancellation()
            let result = try await provider.complete(chatRequest)
            // Billed tokens are recorded even when the reply is unusable or stale.
            FilterAssistantUsageStore.record(
                providerID: provider.providerID,
                modelID: result.modelID,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                in: defaults
            )
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FilterAssistantError.malformedResponse
            }
            return .success((result.text, try FilterAssistantPrompt.parse(result.text)))
        } catch is CancellationError {
            return .failure("Cancelled.")
        } catch let error as URLError where error.code == .timedOut {
            return .failure("The provider did not answer in time. Your draft is unchanged; try again.")
        } catch let error as URLError where error.code == .cancelled {
            return .failure("Cancelled.")
        } catch {
            return .failure(Self.safeMessage(for: error))
        }
    }

    /// Provider errors are shown as their own short descriptions; nothing the
    /// user typed or pasted is echoed into an error.
    private static func safeMessage(for error: Error) -> String {
        let description = (error as? LocalizedError)?.errorDescription ?? "The request failed."
        return String(description.prefix(300))
    }

    func cancelGeneration() {
        guard isGenerating else { return }
        generationID = nil
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        errorMessage = "Cancelled. Your draft is unchanged."
    }

    func startOver() {
        cancelGeneration()
        messages = []
        entries = []
        proposal = nil
        lastSentExample = ""
        lastSentContext = ""
        errorMessage = nil
        hasSaveConflict = false
    }

    var saveTitle: String {
        if case .existing = target, !hasSaveConflict { return "Update filter" }
        return "Save filter"
    }

    /// Saves the reviewed proposal. Updating requires the saved filter to be
    /// unchanged since the conversation began; otherwise the user chooses to
    /// save a new filter instead.
    @discardableResult
    func save() -> CustomCleanupFilter? {
        guard let proposal, !isGenerating else { return nil }
        var id = newFilterID
        if case .existing(let original) = target, !hasSaveConflict {
            let current = CustomCleanupFilterStore.load(from: defaults).first { $0.id == original.id }
            guard current == original else {
                hasSaveConflict = true
                errorMessage = current == nil
                    ? "This filter was deleted while you were drafting. Save the draft as a new filter instead."
                    : "This filter was edited elsewhere while you were drafting. Save the draft as a new filter instead."
                return nil
            }
            id = original.id
        }
        let filter = CustomCleanupFilter(
            id: id,
            name: proposal.name,
            baseMode: proposal.baseMode,
            instructions: proposal.instructions
        )
        do {
            try CustomCleanupFilterStore.upsert(filter, in: defaults)
            if selectAfterSaving {
                CustomCleanupFilterStore.select(.custom(id), in: defaults)
            }
            NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            errorMessage = nil
            return CustomCleanupFilterStore.load(from: defaults).first { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

/// Records a short spoken request for the assistant composer with the local
/// speech model. It never runs transcript cleanup, writes History, touches the
/// clipboard, or pastes; the text goes only to `onTranscript`.
@MainActor
final class FilterAssistantVoiceInput: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    struct Dependencies {
        var start: (UUID, @escaping (String?) -> Void) -> Bool
        var stop: (UUID) async -> URL?
        var cancel: (UUID) -> Void
        var transcribe: (URL) async throws -> String
        var modelLoading: AnyPublisher<Bool, Never>
        var removeFile: (URL) -> Void

        @MainActor static var live: Dependencies {
            Dependencies(
                start: { id, completion in AudioRecorder.shared.startRecording(sessionID: id, completion: completion) },
                stop: { id in await AudioRecorder.shared.stopRecording(sessionID: id) },
                cancel: { id in AudioRecorder.shared.cancelRecording(sessionID: id) },
                transcribe: { url in try await TranscriptionService.shared.transcribeAudio(url: url, settings: Settings()) },
                modelLoading: TranscriptionService.shared.$isLoading.eraseToAnyPublisher(),
                removeFile: { url in try? FileManager.default.removeItem(at: url) }
            )
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var isModelLoading = false
    var onTranscript: (String) -> Void = { _ in }

    private let dependencies: Dependencies
    private var sessionID: UUID?
    private var transcriptionTask: Task<Void, Never>?
    private var loadingSubscription: AnyCancellable?

    init(dependencies: Dependencies? = nil) {
        let dependencies = dependencies ?? .live
        self.dependencies = dependencies
        loadingSubscription = dependencies.modelLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isModelLoading = value }
    }

    func start() {
        guard state == .idle else { return }
        guard !isModelLoading else {
            errorMessage = "The speech model is still loading. Type your request, or try the microphone again shortly."
            return
        }
        let id = UUID()
        errorMessage = nil
        let started = dependencies.start(id) { [weak self] failure in
            guard let failure else { return }
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                self.sessionID = nil
                self.state = .idle
                self.errorMessage = failure
            }
        }
        guard started else {
            errorMessage = "The microphone is busy with another recording."
            return
        }
        sessionID = id
        state = .recording
    }

    func stop() {
        guard state == .recording, let id = sessionID else { return }
        state = .transcribing
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            let url = await self.dependencies.stop(id)
            guard self.sessionID == id else {
                if let url { self.dependencies.removeFile(url) }
                return
            }
            defer {
                if self.sessionID == id {
                    self.sessionID = nil
                    self.state = .idle
                    self.transcriptionTask = nil
                }
            }
            guard let url else {
                self.errorMessage = "That recording was too short. Try again."
                return
            }
            defer { self.dependencies.removeFile(url) }
            do {
                let text = try await self.dependencies.transcribe(url)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.sessionID == id, !Task.isCancelled else { return }
                if text.isEmpty {
                    self.errorMessage = "No speech was detected. Try again."
                } else {
                    self.onTranscript(text)
                }
            } catch {
                guard self.sessionID == id else { return }
                self.errorMessage = "The local speech model could not transcribe that. Your typed text is unchanged."
            }
        }
    }

    /// Releases the microphone and discards any audio or pending text.
    func cancel() {
        guard let id = sessionID else { return }
        sessionID = nil
        if state == .recording {
            dependencies.cancel(id)
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle
    }
}
