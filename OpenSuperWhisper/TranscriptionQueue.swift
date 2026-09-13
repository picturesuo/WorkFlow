import Foundation
import Combine

@MainActor
class TranscriptionQueue: ObservableObject {
    static let shared = TranscriptionQueue()

    @Published private(set) var isProcessing = false
    @Published private(set) var currentRecordingId: UUID?

    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    private let cleanupPipeline: TranscriptCleanupPipeline
    private var processingTask: Task<Void, Never>?
    private var currentTranscriptionTask: Task<Void, Never>?
    private var cancelledRecordingIds: Set<UUID> = []
    private var progressCancellable: AnyCancellable?

    private init() {
        self.transcriptionService = TranscriptionService.shared
        self.recordingStore = RecordingStore.shared
        self.cleanupPipeline = TranscriptCleanupPipeline.shared
        setupProgressObserver()
    }
    
    private func setupProgressObserver() {
        progressCancellable = transcriptionService.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProgress in
                guard let self = self,
                      let recordingId = self.currentRecordingId,
                      newProgress > 0,
                      newProgress < 1.0 else { return }
                
                self.recordingStore.updateRecordingProgressTransient(
                    recordingId,
                    progress: newProgress,
                    status: .transcribing
                )
            }
    }

    func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)

        if currentRecordingId == recordingId {
            transcriptionService.cancelTranscription(requestID: recordingId)
            currentTranscriptionTask?.cancel()
        }
    }

    private func isRecordingCancelled(_ recordingId: UUID) -> Bool {
        return cancelledRecordingIds.contains(recordingId)
    }

    private func clearCancellation(_ recordingId: UUID) {
        cancelledRecordingIds.remove(recordingId)
    }

    func startProcessingQueue() {
        guard !isProcessing else { return }

        isProcessing = true

        processingTask = Task {
            await cleanupMissingFiles()
            await processQueue()
            isProcessing = false
            processingTask = nil
        }
    }

    /// Older pending rows can point at a temp file already moved to their owned
    /// audio path before interruption. Recover that exact path, never another recording.
    nonisolated static func recoverPendingAudioSource(sourceURL: URL?, savedAudioURL: URL) -> URL? {
        let fileManager = FileManager.default
        if let sourceURL, fileManager.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        return fileManager.fileExists(atPath: savedAudioURL.path) ? savedAudioURL : nil
    }

    private func cleanupMissingFiles() async {
        let pendingRecordings = recordingStore.getPendingRecordings()
        let recoveredSources = await Task.detached(priority: .utility) {
            pendingRecordings.map { recording in
                let sourceURL = recording.sourceFileURL.flatMap { path in
                    path.isEmpty ? nil : URL(fileURLWithPath: path)
                }
                return (recording, Self.recoverPendingAudioSource(
                    sourceURL: sourceURL, savedAudioURL: recording.url
                ))
            }
        }.value

        for (recording, sourceURL) in recoveredSources {
            guard let sourceURL else {
                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: recording.transcription.isEmpty
                        ? "Audio file not found. This recording could not resume."
                        : recording.transcription,
                    progress: 0,
                    status: .failed,
                    isRegeneration: false
                )
                continue
            }
            if sourceURL.path != recording.sourceFileURL {
                do {
                    try await recordingStore.updateSourceFileURL(recording.id, sourceURL: sourceURL.path)
                } catch {
                    await recordingStore.updateRecordingStatusOnly(recording.id, progress: 0, status: .failed)
                }
            }
        }
    }

    func addFileToQueue(
        url: URL,
        title: String? = nil,
        mode: RecordingMode = .dictation,
        cleanupRequested: Bool = false,
        targetBundleID: String? = nil
    ) async {
        do {
            let durationInSeconds = await AudioUtil.audioDuration(url: url)

            let timestamp = Date()
            let id = UUID()
            let fileName = AudioRecorder.recordingFileName(id: id)

            let recording = Recording(
                id: id,
                timestamp: timestamp,
                fileName: fileName,
                transcription: "",
                duration: durationInSeconds,
                status: .pending,
                progress: 0.0,
                sourceFileURL: url.path,
                title: title,
                mode: mode,
                cleanupRequested: cleanupRequested,
                targetBundleID: targetBundleID,
                cleanupMode: cleanupRequested
                    ? (CleanupMode(rawValue: AppPreferences.shared.cleanupMode) ?? .everyday)
                    : nil
            )

            try await recordingStore.addRecordingSync(recording)

            startProcessingQueue()
        } catch {
            print("Failed to add the audio file to the transcription queue.")
        }
    }

    func requeueRecording(_ recording: Recording) async {
        let sourceURL: URL? = await Task.detached(priority: .userInitiated) {
            if let existingSource = recording.sourceFileURL,
               !existingSource.isEmpty,
               FileManager.default.fileExists(atPath: existingSource) {
                return URL(fileURLWithPath: existingSource)
            } else if FileManager.default.fileExists(atPath: recording.url.path) {
                return recording.url
            }
            return nil
        }.value
        
        guard let sourceURL = sourceURL else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Cannot regenerate: audio file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        let shouldCleanup = recording.cleanupRequested
            || (recording.cleanupSource != nil && recording.cleanupSource != .disabled)
        await recordingStore.updateCleanupRequested(recording.id, cleanupRequested: shouldCleanup)
        await recordingStore.updateRecordingStatusOnly(
            recording.id,
            progress: 0.0,
            status: .pending,
            isRegeneration: true
        )

        do {
            try await recordingStore.updateSourceFileURL(recording.id, sourceURL: sourceURL.path)
        } catch {
            print("Failed to update the queued audio source.")
        }

        startProcessingQueue()
    }

    nonisolated static func shouldDiscardEmptyDictation(
        text: String,
        sourceURL: URL,
        mode: RecordingMode
    ) -> Bool {
        mode == .dictation
            && text.isEmpty
            && sourceURL.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path)
    }

    private func processQueue() async {
        while let recording = recordingStore.getNextPendingRecording() {
            currentRecordingId = recording.id
            await processRecording(recording)
            currentRecordingId = nil
        }
    }

    /// Cancellation comes from committed History deletion. If an awaited copy
    /// finishes after that deletion, remove the newly recreated owned audio too.
    private func discardCancelledOutput(_ recording: Recording) async -> Bool {
        guard isRecordingCancelled(recording.id) || Task.isCancelled else { return false }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: recording.url)
        }.value
        return true
    }

    private func processRecording(_ recording: Recording) async {
        if isRecordingCancelled(recording.id) {
            clearCancellation(recording.id)
            return
        }

        guard let sourceURLString = recording.sourceFileURL,
              !sourceURLString.isEmpty else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        let sourceURL = URL(fileURLWithPath: sourceURLString)

        let sourceExists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: sourceURL.path)
        }.value
        
        guard sourceExists else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        let isRegeneration = !recording.transcription.isEmpty && 
            recording.transcription != "In queue..." && 
            recording.transcription != "Starting transcription..."

        if isRegeneration {
            await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .converting
            )
        } else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "",
                progress: 0.0,
                status: .converting
            )
        }

        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) {
                    return
                }

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let settings = Settings()
                let text = try await transcriptionService.transcribeAudio(url: sourceURL, settings: settings, requestID: recording.id)

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                if Self.shouldDiscardEmptyDictation(
                    text: text,
                    sourceURL: sourceURL,
                    mode: recording.mode
                ) {
                    try await recordingStore.deleteRecordingSync(recording)
                    await Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: sourceURL)
                    }.value
                    return
                }

                let finalURL = recording.url
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.createDirectory(
                        at: Recording.recordingsDirectory,
                        withIntermediateDirectories: true
                    )

                    if sourceURL.path != finalURL.path {
                        if FileManager.default.fileExists(atPath: finalURL.path) {
                            try? FileManager.default.removeItem(at: finalURL)
                        }
                        // Our own temp recordings are moved (no disk duplication);
                        // user-provided files must stay in place, so they are copied.
                        if sourceURL.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path) {
                            try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                        } else {
                            try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                        }
                    }
                }.value

                if await discardCancelledOutput(recording) { return }
                // Commit the new source before remote cleanup; startup also recovers
                // the narrow move/DB-write interruption window from recording.url.
                try await recordingStore.updateSourceFileURL(recording.id, sourceURL: finalURL.path)
                if await discardCancelledOutput(recording) { return }

                if recording.mode == .meeting,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await recordingStore.updateRecordingProgressOnlySync(
                        recording.id,
                        transcription: "No speech was detected. The meeting audio was saved for playback or retry.",
                        progress: 0,
                        status: .failed,
                        isRegeneration: false
                    )
                    return
                }

                if recording.cleanupRequested {
                    let cleanup = await cleanupPipeline.finalize(
                        text,
                        targetBundleID: recording.targetBundleID,
                        cleanupOverride: true,
                        cleanupModeOverride: recording.cleanupMode
                    )
                    if await discardCancelledOutput(recording) { return }
                    await recordingStore.completeRecording(
                        recording.id,
                        transcription: cleanup.text,
                        cleanup: cleanup
                    )
                } else {
                    let localText = VocabularyRewriter.apply(text, entries: VocabularyStore.load())
                    let localOutcome = TranscriptCleanupOutcome(
                        text: localText,
                        source: .disabled,
                        inputTokens: nil,
                        outputTokens: nil,
                        modelID: nil,
                        rawTokenEstimate: LocalTokenEstimator.estimate(text),
                        finalTokenEstimate: LocalTokenEstimator.estimate(localText),
                        tokenEstimatorID: LocalTokenEstimator.identifier
                    )
                    await recordingStore.completeRecording(
                        recording.id,
                        transcription: localText,
                        cleanup: localOutcome
                    )
                }

                _ = await discardCancelledOutput(recording)
            } catch {
                if await discardCancelledOutput(recording) { return }
                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: "Failed to transcribe: \(error.localizedDescription)",
                    progress: 0.0,
                    status: .failed,
                    isRegeneration: false
                )
            }
        }

        await currentTranscriptionTask?.value
        currentTranscriptionTask = nil
        clearCancellation(recording.id)
    }

}
