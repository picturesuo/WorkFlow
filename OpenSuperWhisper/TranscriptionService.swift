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
        let task: Task<String, Error>
        init(_ task: Task<String, Error>) { self.task = task }
    }
    
    private var currentEngine: TranscriptionEngine?
    private var engineLoadTask: Task<any TranscriptionEngine, Error>?
    private var engineLoadGeneration: UInt64 = 0
    private var transcriptionTask: TranscriptionTaskBox? = nil
    private var isCancelled = false
    
    init() {
        loadEngine()
    }
    
    func cancelTranscription() {
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.task.cancel()
        transcriptionTask = nil
        
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
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
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        // Serialize access to the engine: a whisper context must not process
        // two transcriptions concurrently (indicator flow and queue flow can
        // both reach this point due to async busy checks).
        while let existing = transcriptionTask {
            _ = try? await existing.task.value
            if transcriptionTask === existing {
                transcriptionTask = nil
            }
        }
        
        progress = 0.0
        conversionProgress = 0.0
        isConverting = true
        isTranscribing = true
        transcribedText = ""
        currentSegment = ""
        isCancelled = false
        
        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.isConverting = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
            }
        }
        
        let engine = try await readyEngine()
        
        // Setup progress callback for engines
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        } else if let fluidEngine = engine as? FluidAudioEngine {
            fluidEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        }
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            
            let cancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            
            guard !cancelled else {
                throw CancellationError()
            }
            
            let result = try await engine.transcribeAudio(url: url, settings: settings)
            
            try Task.checkCancellation()
            
            let finalCancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            
            await MainActor.run {
                guard let self = self, !self.isCancelled else { return }
                self.transcribedText = result
                self.progress = 1.0
            }
            
            guard !finalCancelled else {
                throw CancellationError()
            }
            
            return result
        }
        
        transcriptionTask = TranscriptionTaskBox(task)
        
        do {
            return try await task.value
        } catch is CancellationError {
            isCancelled = true
            throw TranscriptionError.processingFailed
        }
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
