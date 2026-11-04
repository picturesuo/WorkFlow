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
    /// The recorded audio's length, pauses and silence included. Shown for
    /// context; never compared with typing.
    let recordingSeconds: TimeInterval
    /// Seconds the speech detector heard speech: the time compared with typing.
    let activeSpeechSeconds: TimeInterval
    /// Words the speech recognizer heard in the original capture: what
    /// typing is estimated from.
    let spokenWords: Int
    /// Words in the text WorkFlow first produced, kept apart: cleanup that
    /// lengthens or shortens the text never changes the estimate.
    let producedWords: Int
    /// Measured time from stopping the recording to the text being ready, or
    /// nil when it was not measured. Shown on its own; never counted.
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
    /// Saved before WorkFlow measured active speech; never guessed.
    case speechNotMeasured
    /// Saved moments ago; the speech detector is still measuring it.
    case measuringSpeech
    /// The speech detector couldn't measure it or heard no speech.
    case speechUnavailable
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
    /// regenerated row counts once, by the text and active speech of its
    /// original capture, so a later retry never changes or doubles its figures.
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
        let active: TimeInterval
        switch source.speechActivity {
        case nil: return .excluded(.speechNotMeasured)
        case .measuring: return .excluded(.measuringSpeech)
        case .unavailable: return .excluded(.speechUnavailable)
        case .measured:
            // A measured row without a positive figure is unusable, never zero.
            guard let seconds = source.activeSpeechSeconds, seconds.isFinite, seconds > 0 else {
                return .excluded(.speechUnavailable)
            }
            active = seconds
        }
        let processing = source.processingSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return .eligible(SpeakingSample(
            recordingSeconds: recording.duration,
            activeSpeechSeconds: active,
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
                summary.counted.add(sample)
            case .excluded(let reason):
                summary.exclusions[reason, default: 0] += 1
            }
        }
        return summary
    }
}

/// Totals for a set of dictations. Rates are ratios of sums, never averages
/// of each dictation's rate.
struct SpeakingTotals: Equatable {
    var count = 0
    /// Recorded length, pauses included; shown for context only.
    var recordingSeconds: TimeInterval = 0
    var activeSpeechSeconds: TimeInterval = 0
    var spokenWords = 0
    var producedWords = 0

    init() {}

    init(_ sample: SpeakingSample) {
        add(sample)
    }

    mutating func add(_ sample: SpeakingSample) {
        count += 1
        recordingSeconds += sample.recordingSeconds
        activeSpeechSeconds += sample.activeSpeechSeconds
        spokenWords += sample.spokenWords
        producedWords += sample.producedWords
    }

    var isEmpty: Bool { count == 0 }

    /// Spoken words per minute of active speech.
    var speakingWPM: Double? {
        guard activeSpeechSeconds > 0, spokenWords > 0 else { return nil }
        return Double(spokenWords) / activeSpeechSeconds * 60
    }

    /// How long typing the words heard would take at an assumed speed. The
    /// recognizer's words, not cleanup's output, so expanding the text
    /// never inflates the estimate.
    func typingSeconds(atWPM wpm: Double) -> TimeInterval {
        Double(spokenWords) / SpeakingEfficiency.clampedTypingWPM(wpm) * 60
    }

    /// Estimated typing time minus active speech; negative when speaking took longer.
    func savedSeconds(atWPM wpm: Double) -> TimeInterval {
        typingSeconds(atWPM: wpm) - activeSpeechSeconds
    }

    /// Estimated typing time divided by active speech, for these same dictations.
    func speedup(atWPM wpm: Double) -> Double? {
        guard activeSpeechSeconds > 0, spokenWords > 0 else { return nil }
        return typingSeconds(atWPM: wpm) / activeSpeechSeconds
    }
}

struct SpeakingSummary: Equatable {
    /// Every dictation in the comparison: the totals behind each figure.
    var counted = SpeakingTotals()
    var exclusions: [SpeakingExclusion: Int] = [:]

    static let empty = SpeakingSummary()

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

    /// "0.4 min", "2.5 min", "12 min", "−1.5 min": tenths under ten minutes,
    /// whole minutes from ten, and the sign kept.
    static func minutes(_ seconds: TimeInterval) -> String {
        let tenths = (abs(seconds) / 60 * 10).rounded() / 10
        let magnitude: String
        if tenths >= 10 {
            magnitude = "\(Int((abs(seconds) / 60).rounded()))"
        } else if tenths == 0 {
            return "0 min"
        } else {
            magnitude = String(format: "%.1f", tenths)
        }
        return "\(seconds < 0 ? "−" : "")\(magnitude) min"
    }

    /// "≈12 min saved", or "≈−1.5 min saved" when speaking took longer.
    static func saved(_ seconds: TimeInterval) -> String {
        "≈\(minutes(seconds)) saved"
    }

    /// "3.1× faster", or "0.7× as fast" when speaking was slower.
    static func speedup(_ ratio: Double) -> String {
        let value = ratio >= 9.95 ? "\(Int(ratio.rounded()))" : String(format: "%.1f", ratio)
        return ratio >= 1.05 ? "\(value)× faster" : "\(value)× as fast"
    }

    /// "≈12 min saved · 3.1× faster" against the assumed typing speed, or nil
    /// when nothing can be compared.
    static func headline(_ totals: SpeakingTotals, typingWPM: Double) -> String? {
        guard let ratio = totals.speedup(atWPM: typingWPM) else { return nil }
        return "\(saved(totals.savedSeconds(atWPM: typingWPM))) · \(speedup(ratio))"
    }

    static func words(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "word" : "words")"
    }

    static func dictations(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "dictation" : "dictations")"
    }

    static func exclusion(_ reason: SpeakingExclusion) -> String {
        switch reason {
        case .meeting: "Meetings"
        case .imported: "Imported audio"
        case .failed: "Failed transcriptions"
        case .pending: "Still processing"
        case .legacy: "Recorded before timing was kept"
        case .speechNotMeasured: "Recorded before active speech was measured"
        case .measuringSpeech: "Measuring active speech"
        case .speechUnavailable: "Active speech couldn’t be measured"
        case .invalidDuration: "No readable recording length"
        case .emptyText: "No words"
        }
    }

    /// The whole calculation for one dictation, in words anyone can recompute.
    static func explanation(_ sample: SpeakingSample, typingWPM: Double) -> String {
        let totals = SpeakingTotals(sample)
        let wpm = SpeakingEfficiency.clampedTypingWPM(typingWPM)
        var parts = ["About \(duration(sample.activeSpeechSeconds)) of active speech in \(duration(sample.recordingSeconds)) recorded, as estimated by the speech detector on this Mac; pauses aren’t counted."]
        var typing = "Typing the \(words(sample.spokenWords)) you said at an assumed \(self.wpm(wpm)) would take about \(duration(totals.typingSeconds(atWPM: wpm)))"
        if let headline = headline(totals, typingWPM: wpm) {
            typing += ": \(headline)."
        } else {
            typing += "."
        }
        parts.append(typing)
        if let processing = sample.processingSeconds {
            parts.append("The text was ready \(duration(processing)) after you stopped; that wait isn’t counted.")
        }
        parts.append("Editing time isn’t measured. Change the assumed typing speed in Settings → Dictation.")
        return parts.joined(separator: " ")
    }
}
