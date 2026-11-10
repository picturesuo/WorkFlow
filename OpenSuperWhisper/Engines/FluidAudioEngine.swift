import Foundation
import AVFoundation
import FluidAudio

class FluidAudioEngine: TranscriptionEngine {
    var engineName: String { "FluidAudio" }

    /// Longer recordings, such as meetings, use FluidAudio's long-form path,
    /// which reads from disk instead of holding the audio in memory.
    static let segmentedLimitSeconds: Double = 20 * 60
    /// The pieces of a finished file are recognized this many at a time, as
    /// FluidAudio's own long-form path does.
    static let pieceConcurrency = 4

    private var asrManager: AsrManager?
    /// Recognizers sharing the loaded models, for pieces recognized at once.
    private var pieceManagers: [AsrManager] = []
    private var asrModels: AsrModels?
    private var isCancelled = false
    private var transcriptionTask: Task<String, Error>?
    private var progressTask: Task<Void, Never>?

    var onProgressUpdate: (@Sendable (Float) -> Void)?

    var isModelLoaded: Bool {
        asrManager != nil
    }

    func initialize() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        let version: AsrModelVersion = versionString == "v2" ? .v2 : .v3

        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        asrManager = manager
        asrModels = models
        pieceManagers = [manager] + (1..<Self.pieceConcurrency).map { _ in AsrManager(config: .default, models: models) }
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let asrManager = asrManager else {
            throw TranscriptionError.contextInitializationFailed
        }

        isCancelled = false

        // Notify start
        onProgressUpdate?(0.02)

        guard !isCancelled else {
            throw CancellationError()
        }

        let audioFile = try AVAudioFile(forReading: url)
        let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let text: String
        if seconds > Self.segmentedLimitSeconds {
            text = try await transcribeLongForm(url: url, manager: asrManager, settings: settings)
        } else {
            text = try await transcribeSegmented(AudioConverter().resampleAudioFile(url), settings: settings)
        }

        guard !isCancelled else {
            throw CancellationError()
        }

        onProgressUpdate?(1.0)
        return Self.postprocess(text, settings: settings)
    }

    /// Starts recognizing a dictation that is still being recorded to `url`,
    /// or returns nil when this engine has no model loaded.
    func makeLiveTranscription(audioAt url: URL, settings: Settings) -> LiveTranscription? {
        guard asrManager != nil, let asrModels else { return nil }
        let manager = AsrManager(config: .default, models: asrModels)
        let transcriber = makeTranscriber(manager: manager, settings: settings)
        return LiveTranscription(
            reader: GrowingWAVReader(url: url),
            transcriber: transcriber,
            engine: self,
            language: settings.selectedLanguage
        )
    }

    /// Recognizes a finished recording piece by piece, several pieces at a
    /// time. The pieces and their texts are those live recognition makes.
    private func transcribeSegmented(_ samples: [Float], settings: Settings) async throws -> String {
        var segmenter = SpeechSegmenter()
        var pieces = segmenter.append(samples)
        if let last = segmenter.finish() { pieces.append(last) }
        let managers = pieceManagers.isEmpty ? [asrManager].compactMap { $0 } : pieceManagers
        let languageHint = Language(rawValue: settings.selectedLanguage)
        let onProgress = onProgressUpdate
        var texts = [String](repeating: "", count: pieces.count)
        var done = 0
        try await withThrowingTaskGroup(of: (index: Int, slot: Int, text: String).self) { group in
            var next = 0
            func add(slot: Int) {
                guard next < pieces.count else { return }
                let index = next
                let piece = Array(samples[pieces[index]])
                let manager = managers[slot]
                next += 1
                group.addTask {
                    (index, slot, try await Self.recognize(piece, manager: manager, language: languageHint))
                }
            }
            for slot in managers.indices { add(slot: slot) }
            while let finished = try await group.next() {
                if isCancelled { throw CancellationError() }
                texts[finished.index] = finished.text
                done += 1
                onProgress?(0.05 + Float(done) / Float(pieces.count) * 0.90)
                // The recognizer that finished takes the next piece.
                add(slot: finished.slot)
            }
        }
        return SegmentedTranscriber.join(texts)
    }

    /// Follows a recording as it is written, one piece at a time.
    private func makeTranscriber(manager: AsrManager, settings: Settings) -> SegmentedTranscriber {
        let languageHint = Language(rawValue: settings.selectedLanguage)
        return SegmentedTranscriber { piece, _ in
            try await Self.recognize(piece, manager: manager, language: languageHint)
        }
    }

    /// One piece in Parakeet's single 15 s window.
    private static func recognize(_ piece: [Float], manager: AsrManager, language: Language?) async throws -> String {
        try Task.checkCancellation()
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: SpeechSegmenter.sampleRate)
        var samples = piece
        if samples.count < minimumSamples {
            // A last piece can be a sliver after a cut; silence pads it.
            samples += [Float](repeating: 0, count: minimumSamples - samples.count)
        }
        // FluidAudio 0.15+ requires an explicit decoder state per window.
        var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        // Parakeet v3 can use the selected language as a script constraint.
        // Passing it prevents acoustically similar tokens from another script
        // from winning while preserving automatic behavior for unsupported IDs.
        return try await manager.transcribe(samples, decoderState: &decoderState, language: language).text
    }

    private func transcribeLongForm(url: URL, manager asrManager: AsrManager, settings: Settings) async throws -> String {
        // Start progress monitoring task using FluidAudio's transcriptionProgressStream
        let onProgress = onProgressUpdate
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // Get the real progress stream from FluidAudio
                let progressStream = await asrManager.transcriptionProgressStream

                for try await progress in progressStream {
                    guard !Task.isCancelled, !self.isCancelled else { break }

                    // FluidAudio reports 0.0-1.0, we map to 0.05-0.95
                    let scaledProgress = 0.05 + Float(progress) * 0.90

                    await MainActor.run {
                        onProgress?(scaledProgress)
                    }
                }
            } catch {
                // Stream finished or error
            }
        }

        defer {
            progressTask?.cancel()
            progressTask = nil
        }

        // FluidAudio 0.15+ requires an explicit decoder state per transcription.
        var decoderState = try TdtDecoderState(decoderLayers: await asrManager.decoderLayerCount)
        let languageHint = Language(rawValue: settings.selectedLanguage)
        let result = try await asrManager.transcribe(
            url,
            decoderState: &decoderState,
            language: languageHint
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func postprocess(_ text: String, settings: Settings) -> String {
        var processedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.shouldApplyAsianAutocorrect && !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }
        return processedText
    }

    func cancelTranscription() {
        isCancelled = true
        progressTask?.cancel()
        progressTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    func getSupportedLanguages() -> [String] {
        LanguageUtil.supportedLanguages(
            engine: "fluidaudio",
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
    }
}
