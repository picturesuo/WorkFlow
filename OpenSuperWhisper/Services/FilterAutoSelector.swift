import Foundation

// Auto: an opt-in way to let what a dictation is about pick one saved
// filter. It is deterministic and runs on this Mac between transcription and
// cleanup: no extra provider request, no model, and nothing read from the
// screen or other windows. The order is fixed before anything is clever:
//
// 1. A filter picked by hand (a built-in mode or a saved filter) is used
//    as-is; Auto is simply not in play.
// 2. Under Auto, a saved filter wins when at least two of its different
//    trigger phrases occur as whole words in the dictation and no other
//    filter also reaches two.
// 3. Otherwise, Auto's fallback filter. One hit, a tie, or no hit never
//    guess.

/// Trigger phrases: what a saved filter listens for under Auto.
enum FilterTriggers {
    static let maximumCount = 8
    static let maximumWords = 3
    static let maximumLength = 30
    /// Two different phrases must occur before Auto switches filters.
    static let minimumDistinctHits = 2

    /// Words that occur in nearly any dictation, so a phrase made only of
    /// them could never mean anything about the subject.
    static let commonWords: Set<String> = [
        "a", "about", "actually", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "because", "been", "but", "by", "can", "could", "did", "do", "does", "doing", "done", "for", "from",
        "get", "go", "going", "got", "had", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if",
        "im", "in", "into", "is", "it", "its", "just", "know", "like", "me", "more", "my", "no", "not", "now",
        "of", "oh", "ok", "okay", "on", "one", "or", "our", "out", "really", "right", "say", "said", "she", "so",
        "some", "that", "thats", "the", "their", "them", "then", "there", "these", "they", "thing", "things",
        "think", "this", "those", "to", "too", "uh", "um", "up", "us", "very", "want", "was", "we", "well",
        "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "yeah", "yes", "you",
        "your",
    ]

    /// Lowercased words without accents, apostrophes, or punctuation, so
    /// matching is whole-word and ignores case: “Follow-up” is “follow up”.
    static func words(_ text: String) -> [String] {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// The comparable form of a phrase: its words joined by single spaces.
    static func key(_ phrase: String) -> String {
        words(phrase).joined(separator: " ")
    }

    /// A phrase as the person wrote it, trimmed, with spaces collapsed.
    static func display(_ phrase: String) -> String {
        phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Splits what was typed into the editor's field into phrases.
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { ",;\n".contains($0) })
            .map { display(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// The editor's field text for saved phrases.
    static func joined(_ phrases: [String]) -> String {
        phrases.joined(separator: ", ")
    }

    /// Validates one filter's phrases against every other saved filter.
    static func validated(_ phrases: [String], others: [CustomCleanupFilter]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for phrase in phrases.map(display) where !phrase.isEmpty {
            let words = words(phrase)
            let key = words.joined(separator: " ")
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard words.count <= maximumWords, phrase.count <= maximumLength else {
                throw CustomCleanupFilterValidationError.triggerTooLong(phrase)
            }
            guard !isTooCommon(words) else {
                throw CustomCleanupFilterValidationError.triggerTooCommon(phrase)
            }
            if let other = others.first(where: { $0.triggers.contains { self.key($0) == key } }) {
                throw CustomCleanupFilterValidationError.duplicateTrigger(phrase, otherFilter: other.name)
            }
            result.append(phrase)
        }
        guard result.count <= maximumCount else { throw CustomCleanupFilterValidationError.tooManyTriggers }
        return result
    }

    /// Keeps the valid stored phrases no earlier filter already uses.
    static func sanitized(_ phrases: [String], excluding taken: inout Set<String>) -> [String] {
        var result: [String] = []
        for phrase in phrases.map(display) {
            let words = words(phrase)
            let key = words.joined(separator: " ")
            guard !key.isEmpty, words.count <= maximumWords, phrase.count <= maximumLength,
                  !isTooCommon(words), result.count < maximumCount,
                  taken.insert(key).inserted else { continue }
            result.append(phrase)
        }
        return result
    }

    private static func isTooCommon(_ words: [String]) -> Bool {
        words.allSatisfy { commonWords.contains($0) || $0.count < 2 }
    }

    /// The filter's distinct phrases found in the words, longest first so
    /// one mention can never count twice: “unit test” and “test” in “unit
    /// test” are one hit. Returned in the filter's own phrase order.
    static func hits(of phrases: [String], in words: [String]) -> [String] {
        let ordered = phrases.enumerated()
            .map { (index: $0.offset, phrase: $0.element, words: self.words($0.element)) }
            .filter { !$0.words.isEmpty }
            .sorted { $0.words.count != $1.words.count ? $0.words.count > $1.words.count : $0.index < $1.index }
        var used = Set<Int>()
        var found: [(index: Int, phrase: String)] = []
        for candidate in ordered {
            let length = candidate.words.count
            guard length <= words.count else { continue }
            for start in 0...(words.count - length) {
                let span = start..<(start + length)
                guard Array(words[span]) == candidate.words, used.isDisjoint(with: span) else { continue }
                used.formUnion(span)
                found.append((candidate.index, candidate.phrase))
                break
            }
        }
        return found.sorted { $0.index < $1.index }.map(\.phrase)
    }
}

/// Why one dictation used the filter it did. Kept in History on this Mac.
enum FilterChoiceReason: Equatable, Sendable {
    /// Picked by hand, before the dictation or for a regeneration.
    case manual
    /// Auto: these different trigger phrases of the filter came up.
    case triggers([String])
    /// Auto: nothing was clear enough, so the fallback filter was used.
    case fallback

    var isAutomatic: Bool { self != .manual }

    /// A short History label, nil for a filter picked by hand.
    var label: String? {
        switch self {
        case .manual: nil
        case .triggers(let phrases): "Auto: mentions \(phrases.joined(separator: ", "))"
        case .fallback: "Auto: no clear match"
        }
    }

    /// One sentence explaining the choice.
    var explanation: String {
        switch self {
        case .manual:
            "You picked this filter."
        case .triggers(let phrases):
            "Auto picked this filter because the dictation mentioned \(phrases.map { "“\($0)”" }.joined(separator: " and "))."
        case .fallback:
            "Auto used its “When unsure” filter because no saved filter had two of its phrases in the dictation."
        }
    }
}

extension FilterChoiceReason: Codable {
    private enum CodingKeys: String, CodingKey { case kind, phrases }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "triggers":
            self = .triggers(try container.decode([String].self, forKey: .phrases))
        case "unsure":
            self = .fallback
        default:
            self = .manual
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode("manual", forKey: .kind)
        case .triggers(let phrases):
            try container.encode("triggers", forKey: .kind)
            try container.encode(phrases, forKey: .phrases)
        case .fallback:
            try container.encode("unsure", forKey: .kind)
        }
    }
}

/// A filter captured with everything cleanup needs, so a queued dictation
/// keeps it even if the filter is edited or deleted later.
enum CapturedFilter: Codable, Equatable, Sendable {
    case builtIn(CleanupMode, learned: [LearnedPreference])
    case custom(CustomCleanupFilter)

    var snapshot: CleanupFilterSnapshot {
        switch self {
        case .builtIn(let mode, let learned): CleanupFilterSnapshot(mode: mode, learned: learned)
        case .custom(let filter): CleanupFilterSnapshot(filter: filter)
        }
    }
}

/// Everything Auto may choose from, captured once per dictation: when it
/// stops, or when it is queued.
struct FilterAutoConfig: Codable, Equatable, Sendable {
    /// Saved filters with enough phrases to ever win.
    var candidates: [CustomCleanupFilter]
    var fallback: CapturedFilter
}

/// The filter a dictation will use: fixed, or chosen by Auto from its words.
enum CleanupFilterPlan: Equatable, Sendable {
    case fixed(CleanupFilterSnapshot, FilterChoiceReason)
    case auto(FilterAutoConfig)

    static func manual(_ filter: CleanupFilterSnapshot) -> CleanupFilterPlan {
        .fixed(filter, .manual)
    }

    /// The filter used when no words are known yet: the fixed one, or Auto's fallback.
    var provisionalFilter: CleanupFilterSnapshot {
        switch self {
        case .fixed(let filter, _): filter
        case .auto(let config): config.fallback.snapshot
        }
    }

    var autoConfig: FilterAutoConfig? {
        if case .auto(let config) = self { return config }
        return nil
    }

    func resolve(text: String) -> FilterChoice {
        switch self {
        case .fixed(let filter, let reason):
            FilterChoice(filter: filter, reason: reason)
        case .auto(let config):
            FilterAutoSelector.resolve(config, text: text)
        }
    }
}

struct FilterChoice: Equatable, Sendable {
    let filter: CleanupFilterSnapshot
    let reason: FilterChoiceReason
}

enum FilterAutoSelector {
    /// Pure and local: the same captured choices and words always give the
    /// same filter, and nothing here leaves this Mac.
    static func resolve(_ config: FilterAutoConfig, text: String) -> FilterChoice {
        let words = FilterTriggers.words(text)
        let qualifying: [(CustomCleanupFilter, [String])] = config.candidates.compactMap { filter in
            let hits = FilterTriggers.hits(of: filter.triggers, in: words)
            return hits.count >= FilterTriggers.minimumDistinctHits ? (filter, hits) : nil
        }
        if qualifying.count == 1, let (filter, hits) = qualifying.first {
            return FilterChoice(filter: CleanupFilterSnapshot(filter: filter), reason: .triggers(hits))
        }
        return FilterChoice(filter: config.fallback.snapshot, reason: .fallback)
    }
}

/// Auto's own preferences. They are separate keys, so the hand-picked mode
/// and saved filter stay exactly as they were and come back when Auto is
/// turned off, and a build without Auto reads the same selection.
enum FilterAutoSettings {
    static let enabledKey = "cleanupFilterAutoEnabled"
    static let fallbackKey = "cleanupFilterAutoUnsure"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Turns Auto on or off. Turning it on the first time makes the filter
    /// in use its fallback.
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        if enabled, (defaults.string(forKey: fallbackKey) ?? "").isEmpty {
            defaults.set(CustomCleanupFilterStore.currentSelection(in: defaults).tag, forKey: fallbackKey)
        }
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Auto's fallback. A deleted saved filter falls back to Everyday.
    static func fallback(
        in defaults: UserDefaults = .standard,
        filters: [CustomCleanupFilter]? = nil
    ) -> CleanupFilterSelection {
        let filters = filters ?? CustomCleanupFilterStore.load(from: defaults)
        return fallback(
            tag: defaults.string(forKey: fallbackKey) ?? "",
            manual: CustomCleanupFilterStore.currentSelection(in: defaults, filters: filters),
            filters: filters
        )
    }

    /// An unset fallback is the hand-picked filter; a saved filter that was
    /// deleted is Everyday, so a stale choice never guesses another filter.
    static func fallback(
        tag: String,
        manual: CleanupFilterSelection,
        filters: [CustomCleanupFilter]
    ) -> CleanupFilterSelection {
        switch CleanupFilterSelection(tag: tag) {
        case .custom(let id)? where filters.contains(where: { $0.id == id }):
            return .custom(id)
        case .builtIn(let mode)?:
            return .builtIn(mode)
        case .custom?:
            return .builtIn(.everyday)
        case nil:
            return manual
        }
    }

    static func setFallback(_ selection: CleanupFilterSelection, in defaults: UserDefaults = .standard) {
        defaults.set(selection.tag, forKey: fallbackKey)
    }

    /// The filter a selection means right now, with everything it needs, or
    /// nil for a saved filter that no longer exists.
    static func capture(
        _ selection: CleanupFilterSelection,
        filters: [CustomCleanupFilter],
        defaults: UserDefaults = .standard
    ) -> CapturedFilter? {
        switch selection {
        case .builtIn(let mode):
            return .builtIn(mode, learned: LearnedPreferenceStore.activePreferences(for: mode, in: defaults))
        case .custom(let id):
            return filters.first { $0.id == id }.map(CapturedFilter.custom)
        }
    }

    /// What Auto may choose from for one dictation, or nil when a filter was
    /// picked by hand.
    static func currentConfig(
        in defaults: UserDefaults = .standard
    ) -> FilterAutoConfig? {
        guard isEnabled(in: defaults) else { return nil }
        let filters = CustomCleanupFilterStore.load(from: defaults)
        let fallback = capture(fallback(in: defaults, filters: filters), filters: filters, defaults: defaults)
            ?? .builtIn(.everyday, learned: LearnedPreferenceStore.activePreferences(for: .everyday, in: defaults))
        return FilterAutoConfig(
            candidates: filters.filter { $0.triggers.count >= FilterTriggers.minimumDistinctHits },
            fallback: fallback
        )
    }

    /// The plan for a dictation starting or stopping now.
    static func currentPlan(
        in defaults: UserDefaults = .standard
    ) -> CleanupFilterPlan {
        if let config = currentConfig(in: defaults) {
            return .auto(config)
        }
        return .manual(CustomCleanupFilterStore.currentSnapshot(in: defaults))
    }
}
