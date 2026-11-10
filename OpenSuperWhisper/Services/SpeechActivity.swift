import Foundation

/// Where a dictation's active-speech measurement stands. Rows saved before
/// WorkFlow measured active speech have none and are never guessed.
enum SpeechActivityStatus: String, Codable, Equatable {
    /// Saved; the speech detector has not finished with its audio yet.
    case measuring
    /// The detector heard speech; the evidence holds how many seconds.
    case measured
    /// The detector couldn't run, the audio couldn't be read, or it heard no
    /// speech. Never replaced by the recording length or counted as zero.
    case unavailable
}

/// One stretch the detector heard as speech, in seconds from the recording's start.
struct SpeechInterval: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

/// What a detector found in one recording.
struct SpeechDetection: Equatable, Sendable {
    let intervals: [SpeechInterval]
    /// Length of the audio the detector analyzed.
    let analyzedSeconds: TimeInterval
}

/// Finds the stretches of a recording that are speech. Reads the audio and
/// never changes it.
protocol SpeechDetecting: Sendable {
    /// Identifies the detector and its settings in the stored evidence.
    var detectorID: String { get }
    func detectSpeech(in audioURL: URL) async throws -> SpeechDetection
}

/// The result written to a dictation's evidence, once.
struct SpeechActivityMeasurement: Equatable {
    let status: SpeechActivityStatus
    let activeSeconds: TimeInterval?
    let detectorID: String

    static func unavailable(_ detectorID: String) -> Self {
        Self(status: .unavailable, activeSeconds: nil, detectorID: detectorID)
    }
}

enum SpeechActivity {
    /// Seconds covered by the union of `intervals` after clamping each to
    /// [0, duration]: overlaps and repeats count once, and nothing outside
    /// the audio counts.
    static func unionSeconds(_ intervals: [SpeechInterval], within duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        let clamped = intervals
            .compactMap { interval -> (TimeInterval, TimeInterval)? in
                guard interval.start.isFinite, interval.end.isFinite else { return nil }
                let start = min(max(interval.start, 0), duration)
                let end = min(max(interval.end, 0), duration)
                return end > start ? (start, end) : nil
            }
            .sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (start: TimeInterval, end: TimeInterval)?
        for (start, end) in clamped {
            if let open = current, start <= open.end {
                current = (open.start, max(open.end, end))
            } else {
                if let open = current { total += open.end - open.start }
                current = (start, end)
            }
        }
        if let open = current { total += open.end - open.start }
        return total
    }

    /// Measures one recording's active speech. Any failure, or hearing no
    /// speech at all, is unavailable rather than a guessed or zero figure.
    /// Nil means the process is exiting: there is no result to record, and
    /// the next launch measures the recording again.
    static func measure(_ audioURL: URL, with detector: any SpeechDetecting) async -> SpeechActivityMeasurement? {
        do {
            let detection = try await detector.detectSpeech(in: audioURL)
            let active = unionSeconds(detection.intervals, within: detection.analyzedSeconds)
            guard active.isFinite, active > 0 else { return .unavailable(detector.detectorID) }
            return SpeechActivityMeasurement(status: .measured, activeSeconds: active, detectorID: detector.detectorID)
        } catch SpeechDetectionError.processExiting {
            return nil
        } catch {
            return .unavailable(detector.detectorID)
        }
    }
}

enum SpeechDetectionError: Error {
    case detectorUnavailable
    case unreadableAudio
    case detectionFailed
    /// The process is exiting, so whisper.cpp refused the call.
    case processExiting
}

/// The Silero voice-activity model bundled with WorkFlow, run on this Mac
/// through whisper.cpp with the same settings the Whisper engine uses to
/// skip silence. It classifies speech; it is not a loudness meter.
final class SileroSpeechDetector: SpeechDetecting {
    static let shared = SileroSpeechDetector()

    /// Whisper.cpp's default VAD settings: 0.5 speech threshold, 250 ms
    /// minimum speech, 100 ms minimum silence, 30 ms padding, and gaps
    /// under 200 ms merged.
    let detectorID = "silero-v5.1.2/whisper.cpp-default"

    private let model: Model

    init(modelPath: String? = WhisperEngine.vadModelPath) {
        model = Model(path: modelPath)
    }

    func detectSpeech(in audioURL: URL) async throws -> SpeechDetection {
        // The same read-only conversion transcription uses: 16 kHz mono.
        guard let samples = try await WhisperEngine().convertAudioToPCM(fileURL: audioURL),
              !samples.isEmpty else {
            throw SpeechDetectionError.unreadableAudio
        }
        return try await model.detect(samples)
    }

    /// The VAD context is not thread-safe, so detections take turns; waiting
    /// callers suspend instead of blocking a thread.
    private actor Model {
        private static let sampleRate: Double = 16_000
        private let path: String?
        private var context: MyWhisperVadContext?

        init(path: String?) {
            self.path = path
        }

        func detect(_ samples: [Float]) throws -> SpeechDetection {
            let gate = ProcessExitGate.shared
            if gate.isExiting { throw SpeechDetectionError.processExiting }
            if context == nil {
                guard let path, let loaded = MyWhisperVadContext(modelPath: path) else {
                    throw gate.isExiting ? SpeechDetectionError.processExiting : SpeechDetectionError.detectorUnavailable
                }
                context = loaded
            }
            guard let segments = context?.speechSegments(in: samples) else {
                throw gate.isExiting ? SpeechDetectionError.processExiting : SpeechDetectionError.detectionFailed
            }
            return SpeechDetection(
                intervals: segments.map {
                    SpeechInterval(start: TimeInterval($0.startCs) / 100, end: TimeInterval($0.endCs) / 100)
                },
                analyzedSeconds: Double(samples.count) / Self.sampleRate
            )
        }
    }
}
