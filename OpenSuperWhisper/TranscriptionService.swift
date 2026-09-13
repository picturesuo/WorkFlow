import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isConverting = false
    @Published private(set) var conversionProgress: Float = 0.0
    
    private final class TranscriptionTaskBox {
        let requestID: UUID
        let token: UUID
        let task: Task<String, Error>
        var engine: (any TranscriptionEngine)?

        init(requestID: UUID, token: UUID, task: Task<String, Error>) {
            self.requestID = requestID
            self.token = token
            self.task = task
        }
    }
    
    private var currentEngine: TranscriptionEngine?
    private var engineLoadTask: Task<any TranscriptionEngine, Error>?
    private var engineLoadGeneration: UInt64 = 0
    private var transcriptionTask: TranscriptionTaskBox? = nil
    
    init() {
        loadEngine()
    }
    
    /// Supplies an already loaded engine without starting model downloads.
    init(engine: any TranscriptionEngine) {
        currentEngine = engine
    }

    func cancelTranscription(requestID: UUID) {
        guard let request = transcriptionTask, request.requestID == requestID else { return }
        request.engine?.cancelTranscription()
        request.task.cancel()
        currentSegment = ""
        progress = 0
        // Keep the reservation until the engine actually returns. Starting another
        // transcription while cancellation unwinds would reuse its live context.
    }

    private func loadEngine() {
        let selectedEngine = AppPreferences.shared.selectedEngine
        print("Loading engine: \(selectedEngine)")
        
        isLoading = true
        currentEngine = nil
        engineLoadGeneration &+= 1
        let generation = engineLoadGeneration
        
        let task = Task.detached(priority: .userInitiated) { () throws -> any TranscriptionEngine in
            let engine: any TranscriptionEngine
            if selectedEngine == "fluidaudio" {
                engine = FluidAudioEngine()
            } else {
                engine = WhisperEngine()
            }
            try await engine.initialize()
            return engine
        }
        engineLoadTask = task

        Task { [weak self] in
            do {
                let engine = try await task.value
                guard let self, self.engineLoadGeneration == generation else { return }
                self.currentEngine = engine
                self.engineLoadTask = nil
                self.isLoading = false
                print("Engine loaded: \(selectedEngine)")
            } catch {
                guard let self, self.engineLoadGeneration == generation else { return }
                self.engineLoadTask = nil
                self.isLoading = false
                print("Failed to load the transcription engine.")
            }
        }
    }
    
    func reloadEngine() {
        loadEngine()
    }
    
    func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings, requestID: UUID = UUID()) async throws -> String {
        try Task.checkCancellation()
        while let existing = transcriptionTask {
            _ = try? await existing.task.value
            // Cancelling a queued caller must not let it enter the engine after
            // the unrelated active request finishes.
            try Task.checkCancellation()
            if transcriptionTask === existing {
                transcriptionTask = nil
            }
        }

        // Reserve before the task can suspend in readyEngine(), including the
        // first transcription while a model is still loading.
        let token = UUID()
        let task = Task {
            try await performTranscription(url: url, settings: settings, token: token)
        }
        transcriptionTask = TranscriptionTaskBox(requestID: requestID, token: token, task: task)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performTranscription(url: URL, settings: Settings, token: UUID) async throws -> String {
        defer {
            // Cleanup runs before waiters resume and cannot clear a newer request.
            if transcriptionTask?.token == token {
                isTranscribing = false
                isConverting = false
                currentSegment = ""
                transcriptionTask = nil
            }
        }
        try Task.checkCancellation()
        progress = 0
        conversionProgress = 0
        isConverting = true
        isTranscribing = true
        transcribedText = ""
        currentSegment = ""

        let engine = try await readyEngine()
        try Task.checkCancellation()
        transcriptionTask?.engine = engine

        let reportProgress: (Float) -> Void = { [weak self] newProgress in
            Task { @MainActor in
                guard let self, let request = self.transcriptionTask,
                      request.token == token, !request.task.isCancelled else { return }
                self.progress = newProgress
            }
        }
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onProgressUpdate = reportProgress
        } else if let fluidEngine = engine as? FluidAudioEngine {
            fluidEngine.onProgressUpdate = reportProgress
        }

        let engineTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try await engine.transcribeAudio(url: url, settings: settings)
            try Task.checkCancellation()
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await engineTask.value
        } onCancel: {
            engineTask.cancel()
        }
        try Task.checkCancellation()
        transcribedText = result
        progress = 1
        return result
    }

    /// Waits for the newest load only. If the user changes engines while an
    /// older load is finishing, loop onto the replacement task instead of
    /// publishing the stale engine or clearing the new task.
    private func readyEngine() async throws -> any TranscriptionEngine {
        while true {
            if let currentEngine {
                return currentEngine
            }
            guard let loadTask = engineLoadTask else {
                throw TranscriptionError.contextInitializationFailed
            }

            let generation = engineLoadGeneration
            do {
                let loadedEngine = try await loadTask.value
                guard generation == engineLoadGeneration else { continue }
                currentEngine = loadedEngine
                engineLoadTask = nil
                isLoading = false
                return loadedEngine
            } catch {
                guard generation == engineLoadGeneration else { continue }
                engineLoadTask = nil
                isLoading = false
                throw TranscriptionError.contextInitializationFailed
            }
        }
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
