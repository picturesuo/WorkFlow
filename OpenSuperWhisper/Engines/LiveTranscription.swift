import CryptoKit
import FluidAudio
import Foundation

/// Recognizes a dictation while it is being recorded, so that when the key is
/// released only its last piece is left to recognize.
///
/// It follows the recording file as the recorder writes it and feeds the
/// same piece-by-piece recognizer that a finished file goes through. When the
/// recording stops, the audio it heard is checked against the finished file;
/// if they differ in any sample, or anything went wrong while following, it
/// returns nil and the finished file is recognized as usual, so the result
/// never depends on reading a file mid-write.
actor LiveTranscription {
    /// Why the finished file is recognized instead; for diagnostics only.
    enum Fallback: Equatable {
        /// The recording fit one piece, so nothing was recognized ahead and
        /// the file is as quick.
        case onePiece
        case unreadable
        case tooLong
        case audioChanged
        case engineChanged
        case languageChanged
    }

    /// How often the recording file is read.
    static let pollInterval: Duration = .milliseconds(250)

    /// The engine whose model hears the pieces; held so a reloaded engine is
    /// never mistaken for it.
    let engine: AnyObject
    let language: String
    private let reader: GrowingWAVReader
    private let transcriber: SegmentedTranscriber
    private var task: Task<Void, Never>?
    /// The wait between reads, cut short by a stop.
    private var nap: Task<Void, Never>?
    private var stopRequested = false
    private var isCancelled = false
    /// The audio heard so far, as Float bit patterns, to compare with the finished file.
    private var hasher = SHA256()
    private(set) var samplesHeard = 0
    private(set) var fallback: Fallback?

    init(reader: GrowingWAVReader, transcriber: SegmentedTranscriber, engine: AnyObject, language: String) {
        self.reader = reader
        self.transcriber = transcriber
        self.engine = engine
        self.language = language
    }

    /// Begins following the recording.
    func start() {
        guard task == nil, !isCancelled else { return }
        task = Task { await self.follow() }
    }

    /// Stops following and forgets everything; the recording was discarded.
    func cancel() {
        isCancelled = true
        stopRequested = true
        nap?.cancel()
        task?.cancel()
    }

    /// The transcript of the finished recording at `url`, or nil when it has
    /// to be recognized from the file instead. Throws only on cancellation.
    func finish(finalAudio url: URL, engine currentEngine: AnyObject, language currentLanguage: String) async throws -> String? {
        stopRequested = true
        nap?.cancel()
        // Let a piece in progress finish so the recognizer's state stays whole.
        await task?.value
        task = nil
        try Task.checkCancellation()
        if fallback == nil, currentEngine !== engine { fallback = .engineChanged }
        if fallback == nil, currentLanguage != language { fallback = .languageChanged }
        guard fallback == nil, !isCancelled else { return nil }
        guard transcriber.recognizedPieces > 0 else {
            fallback = .onePiece
            return nil
        }

        // The finished file, exactly as the finished-file path reads it.
        guard let finalSamples = try? AudioConverter().resampleAudioFile(url),
              finalSamples.count >= samplesHeard else {
            fallback = .audioChanged
            return nil
        }
        var check = SHA256()
        Self.update(&check, with: finalSamples[0..<samplesHeard])
        guard check.finalize() == hasher.finalize() else {
            fallback = .audioChanged
            return nil
        }
        try await transcriber.append(finalSamples[samplesHeard...])
        return try await transcriber.finish()
    }

    private func follow() async {
        while !stopRequested, !Task.isCancelled {
            do {
                let samples = try reader.readAvailable()
                if !samples.isEmpty {
                    Self.update(&hasher, with: samples[...])
                    samplesHeard += samples.count
                    if Double(samplesHeard) / Double(SpeechSegmenter.sampleRate) > FluidAudioEngine.segmentedLimitSeconds {
                        fallback = .tooLong
                        return
                    }
                    try await transcriber.append(samples)
                }
            } catch {
                if !isCancelled { fallback = fallback ?? .unreadable }
                return
            }
            guard !stopRequested else { return }
            let nap = Task<Void, Never> { try? await Task.sleep(for: Self.pollInterval) }
            self.nap = nap
            await nap.value
            self.nap = nil
        }
    }

    private static func update(_ hasher: inout SHA256, with samples: ArraySlice<Float>) {
        samples.withUnsafeBufferPointer { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
    }
}
