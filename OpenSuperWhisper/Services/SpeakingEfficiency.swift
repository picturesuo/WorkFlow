import Foundation

/// Where a dictation's audio came from. Only live dictations compare
/// speaking with typing: an imported file was not spoken into WorkFlow.
enum CaptureOrigin: String, Codable, Equatable {
    case live
    case imported
}

/// The non-content numbers behind one dictation's speaking-versus-typing
/// comparison. Every figure WorkFlow shows is computed from these.
struct SpeakingSample: Equatable {
    /// The recorded audio's length, pauses included.
    let recordingSeconds: TimeInterval
    /// Words the speech recognizer heard.
    let spokenWords: Int
    /// Words in the text WorkFlow produced for this dictation.
    let producedWords: Int
    /// Measured time from stopping the recording to the text being ready,
    /// or nil when it was not measured.
    let processingSeconds: TimeInterval?
}

/// Why a History row is not part of the speaking-versus-typing comparison.
enum SpeakingExclusion: String, CaseIterable, Equatable {
    /// Meetings are long recordings that are never typed instead.
    case meeting
    /// Imported audio was not spoken into WorkFlow.
    case imported
    case failed
    /// Queued, transcribing, or being regenerated.
    case pending
    /// Recorded before WorkFlow kept the counts or the audio's origin.
    case legacy
    /// A zero, negative, or unreadable recording length.
    case invalidDuration
    /// The recognizer heard no words or the produced text has none.
    case emptyText
}

enum SpeakingEligibility: Equatable {
    case eligible(SpeakingSample)
    case excluded(SpeakingExclusion)

    var sample: SpeakingSample? {
        if case .eligible(let sample) = self { return sample }
        return nil
    }
}

enum SpeakingEfficiency {
    /// An assumed typing speed, editable in Settings. It is not a measurement
    /// of the person or a cited population average.
    static let defaultTypingWPM: Double = 40
    static let typingWPMRange: ClosedRange<Double> = 10...200
    static let typingWPMKey = "typingBaselineWPM"

    static func clampedTypingWPM(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTypingWPM }
        return min(max(value, typingWPMRange.lowerBound), typingWPMRange.upperBound)
    }

    /// Words as the system's word segmentation finds them, so "don't" and
    /// "3.5" are one word each, punctuation is none, and languages written
    /// without spaces are still split into words.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Seconds from a Duration, for the measured processing time.
    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// Decides whether one History row is a comparable dictation. A
    /// regenerated row counts once, by the text and timing of its original
    /// capture, so a later retry never changes or doubles its figures.
    static func classify(_ recording: Recording, source: DictationSource?) -> SpeakingEligibility {
        if recording.mode == .meeting { return .excluded(.meeting) }
        if recording.isPending { return .excluded(.pending) }
        if recording.status == .failed { return .excluded(.failed) }
        guard let source,
              let recognizerText = source.recognizerText,
              let emittedText = source.emittedText else { return .excluded(.legacy) }
        switch source.captureOrigin {
        case .imported: return .excluded(.imported)
        case nil: return .excluded(.legacy)
        case .live: break
        }
        guard recording.duration.isFinite, recording.duration > 0 else { return .excluded(.invalidDuration) }
        let spoken = wordCount(recognizerText)
        let produced = wordCount(emittedText)
        guard spoken > 0, produced > 0 else { return .excluded(.emptyText) }
        let processing = source.processingSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return .eligible(SpeakingSample(
            recordingSeconds: recording.duration,
            spokenWords: spoken,
            producedWords: produced,
            processingSeconds: processing
        ))
    }

    static func summarize(_ eligibility: [SpeakingEligibility]) -> SpeakingSummary {
        var summary = SpeakingSummary.empty
        for item in eligibility {
            switch item {
            case .eligible(let sample):
                if sample.processingSeconds != nil {
                    summary.measured.add(sample)
                } else {
                    summary.recordingOnly.add(sample)
                }
            case .excluded(let reason):
                summary.exclusions[reason, default: 0] += 1
            }
        }
        return summary
    }
}

/// Totals for a set of dictations. Rates are ratios of sums (duration
/// weighted), never averages of each dictation's rate.
struct SpeakingTotals: Equatable {
    var count = 0
    var recordingSeconds: TimeInterval = 0
    /// Measured processing time; zero for a recording-only cohort.
    var processingSeconds: TimeInterval = 0
    var spokenWords = 0
    var producedWords = 0

    init() {}

    init(_ sample: SpeakingSample) {
        add(sample)
    }

    mutating func add(_ sample: SpeakingSample) {
        count += 1
        recordingSeconds += sample.recordingSeconds
        processingSeconds += sample.processingSeconds ?? 0
        spokenWords += sample.spokenWords
        producedWords += sample.producedWords
    }

    mutating func add(_ other: SpeakingTotals) {
        count += other.count
        recordingSeconds += other.recordingSeconds
        processingSeconds += other.processingSeconds
        spokenWords += other.spokenWords
        producedWords += other.producedWords
    }

    var isEmpty: Bool { count == 0 }

    /// Spoken words per minute of recording, pauses included.
    var speakingWPM: Double? {
        guard recordingSeconds > 0, spokenWords > 0 else { return nil }
        return Double(spokenWords) / recordingSeconds * 60
    }

    /// Recording plus measured processing: the time to ready text.
    var dictationSeconds: TimeInterval { recordingSeconds + processingSeconds }

    /// Produced words per minute of dictation time.
    var producedWPM: Double? {
        guard dictationSeconds > 0, producedWords > 0 else { return nil }
        return Double(producedWords) / dictationSeconds * 60
    }

    /// How long typing the produced words would take at an assumed speed.
    func typingSeconds(atWPM wpm: Double) -> TimeInterval {
        Double(producedWords) / SpeakingEfficiency.clampedTypingWPM(wpm) * 60
    }

    /// Estimated typing time minus dictation time; negative when dictating was slower.
    func savedSeconds(atWPM wpm: Double) -> TimeInterval {
        typingSeconds(atWPM: wpm) - dictationSeconds
    }

    /// Estimated typing time divided by dictation time.
    func speedup(atWPM wpm: Double) -> Double? {
        guard dictationSeconds > 0, producedWords > 0 else { return nil }
        return typingSeconds(atWPM: wpm) / dictationSeconds
    }
}

struct SpeakingSummary: Equatable {
    /// Dictations whose processing time was measured: savings include it.
    var measured = SpeakingTotals()
    /// Dictations without measured processing: compared on recording time
    /// alone, so their savings are overstated by the unmeasured time.
    var recordingOnly = SpeakingTotals()
    var exclusions: [SpeakingExclusion: Int] = [:]

    static let empty = SpeakingSummary()

    /// Every comparable dictation, for speaking pace, which needs no processing time.
    var allEligible: SpeakingTotals {
        var all = measured
        all.add(recordingOnly)
        return all
    }

    var excludedCount: Int { exclusions.values.reduce(0, +) }
}

/// Display strings shared by History, the main window, and Settings.
enum SpeakingFormat {
    static func wpm(_ value: Double) -> String {
        "\(Int(value.rounded())) WPM"
    }

    /// "1h 2m", "1m 50s", "45s"; whole seconds, sign dropped.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(abs(seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    static func speedup(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    static func words(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "word" : "words")"
    }

    static func dictations(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "dictation" : "dictations")"
    }

    /// "≈1m 50s saved" or "≈20s slower than typing".
    static func saved(_ seconds: TimeInterval) -> String {
        let rounded = seconds.rounded()
        if rounded > 0 { return "≈\(duration(rounded)) saved" }
        if rounded < 0 { return "≈\(duration(rounded)) slower than typing" }
        return "About the same as typing"
    }

    static func exclusion(_ reason: SpeakingExclusion) -> String {
        switch reason {
        case .meeting: "Meetings"
        case .imported: "Imported audio"
        case .failed: "Failed transcriptions"
        case .pending: "Still processing"
        case .legacy: "Recorded before timing was kept"
        case .invalidDuration: "No readable recording length"
        case .emptyText: "No words"
        }
    }

    /// The whole calculation for one dictation, in words anyone can recompute.
    static func explanation(_ sample: SpeakingSample, typingWPM: Double) -> String {
        let totals = SpeakingTotals(sample)
        let wpm = SpeakingEfficiency.clampedTypingWPM(typingWPM)
        var parts = ["Spoke \(words(sample.spokenWords)) in \(duration(sample.recordingSeconds))"]
        if let pace = totals.speakingWPM { parts[0] += " (\(self.wpm(pace)), pauses included)." }
        parts.append("Typing the \(words(sample.producedWords)) produced at an assumed \(self.wpm(wpm)) would take about \(duration(totals.typingSeconds(atWPM: wpm))).")
        if let processing = sample.processingSeconds {
            let difference = totals.savedSeconds(atWPM: wpm).rounded()
            let outcome = difference > 0 ? "saving about \(duration(difference))"
                : difference < 0 ? "about \(duration(difference)) slower than typing"
                : "about the same as typing"
            parts.append("Recording plus \(duration(processing)) of measured processing took \(duration(totals.dictationSeconds)), \(outcome).")
        } else {
            parts.append("Processing time wasn’t measured for this dictation, so no time saved is claimed.")
        }
        parts.append("Editing time isn’t measured. Change the assumed typing speed in Settings → Dictation.")
        return parts.joined(separator: " ")
    }
}
