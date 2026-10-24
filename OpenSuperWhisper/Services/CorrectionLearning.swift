import CryptoKit
import Foundation

// Correction learning compares a finished document the user pastes with the
// dictations WorkFlow produced for it, and keeps only reusable, validated
// style preferences for one built-in mode. Everything here is local and
// deterministic except the single classification request the session sends.

/// One completed dictation that a finished document may contain.
struct CorrectionCandidate: Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    /// The text WorkFlow produced for the dictation.
    let emitted: String
    /// What cleanup received; nil for legacy History, which kept no original.
    let cleanupInput: String?
    let recognizer: String?
    let selectedMode: CleanupMode?

    var isLegacy: Bool { cleanupInput == nil }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        emitted: String,
        cleanupInput: String? = nil,
        recognizer: String? = nil,
        selectedMode: CleanupMode? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.emitted = emitted
        self.cleanupInput = cleanupInput
        self.recognizer = recognizer
        self.selectedMode = selectedMode
    }

    /// New dictations use their first emitted text and original input, even if
    /// History was regenerated since. Rows without evidence are legacy: their
    /// saved text is the only thing known, and no original words are invented.
    init?(recording: Recording, source: DictationSource?) {
        if let source, let emitted = source.emittedText, let recognizer = source.recognizerText {
            self.init(
                id: recording.id,
                timestamp: recording.timestamp,
                emitted: emitted,
                cleanupInput: source.cleanupInput,
                recognizer: recognizer,
                selectedMode: source.selectedMode
            )
        } else {
            self.init(
                id: recording.id,
                timestamp: recording.timestamp,
                emitted: recording.transcription,
                selectedMode: recording.cleanupMode
            )
        }
        guard !emitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    }
}

/// A reusable style preference from a closed set of kinds. Its instruction is
/// a fixed template; only a validated short word or phrase is ever taken from
/// the user's text, so a document can never add free-form model instructions.
struct LearnedPreference: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case spelling
        case removeFiller = "remove_filler"
        case keepWord = "keep_word"
        case semicolonJoin = "semicolon_join"
        case connectedSentences = "connected_sentences"
        case inlineEnumeration = "inline_enumeration"
        case digits
        case percentSign = "percent_sign"
        case numberWords = "number_words"
        case contractions
        case noContractions = "no_contractions"

        var conflicting: Kind? {
            switch self {
            case .digits: .numberWords
            case .numberWords: .digits
            case .contractions: .noContractions
            case .noContractions: .contractions
            case .removeFiller: .keepWord
            case .keepWord: .removeFiller
            default: nil
            }
        }
    }

    /// Where the corrected words came from, so recognition fixes, undone
    /// cleanup changes, and the user's own revisions stay distinguishable.
    enum Origin: String, Codable, Sendable {
        /// The recognizer's words, which cleanup kept and the user corrected.
        case recognition
        /// The user undid a change cleanup made.
        case cleanup
        /// The user's own revision of the emitted text.
        case finalEdit = "final_edit"

        var label: String {
            switch self {
            case .recognition: "Recognition fix"
            case .cleanup: "Undid a cleanup change"
            case .finalEdit: "Your edit"
            }
        }
    }

    var id = UUID()
    let mode: CleanupMode
    let kind: Kind
    /// The spelling to replace, or the word for filler kinds.
    let from: String?
    /// The preferred spelling.
    let to: String?
    var isEnabled = true
    var origin: Origin
    /// Fingerprints of the supporting edits; never their text.
    var evidence: [String]
    /// True when every supporting edit came from legacy History.
    var fromLegacyOnly: Bool
    var learnedAt: Date
    var updatedAt: Date

    var formatsNumbers: Bool { kind == .digits || kind == .percentSign }

    var key: String { [kind.rawValue, from?.lowercased() ?? "", to ?? ""].joined(separator: "|") }

    var instruction: String {
        switch kind {
        case .spelling: "Write “\(from ?? "")” as “\(to ?? "")”."
        case .removeFiller: "Remove the filler word “\(from ?? "")”."
        case .keepWord: "Keep the informal word “\(from ?? "")” where the speaker says it."
        case .semicolonJoin: "Join closely related clauses with a semicolon rather than starting a new sentence."
        case .connectedSentences: "Keep long, connected sentences; do not split them into short ones."
        case .inlineEnumeration: "Mark spoken enumerations inline as (1), (2) within the sentence; never make a list."
        case .digits: "Write numerical quantities as digits without changing any value."
        case .percentSign: "Write “percent” after a number as the % sign."
        case .numberWords: "Spell out numbers as words without changing any value."
        case .contractions: "Use contractions such as “don't” and “it's”."
        case .noContractions: "Avoid contractions; write “do not” and “it is”."
        }
    }

    /// A preference the mode's own contract already guarantees, or contradicts.
    static func isRedundant(_ kind: Kind, in mode: CleanupMode) -> Bool {
        switch (mode, kind) {
        case (.homework, .digits), (.homework, .percentSign),
             (.writing, .inlineEnumeration), (.writing, .connectedSentences):
            true
        default:
            false
        }
    }

    static func isAllowed(_ kind: Kind, in mode: CleanupMode) -> Bool {
        // Homework writes quantities as digits by request; edits cannot undo that.
        !(mode == .homework && kind == .numberWords)
    }

    /// Words the filler kinds may name. Anything else is a content edit.
    static let fillerWords: Set<String> = [
        "um", "uh", "erm", "hmm", "like", "basically", "actually", "literally", "just",
        "so", "really", "right", "okay", "ok", "well", "anyway", "you know", "i mean",
        "kind of", "sort of"
    ]

    static let maximumPhraseLength = 40
    static let maximumPhraseWords = 4

    /// A short word or phrase safe to place in a fixed template, or nil.
    static func sanitizedPhrase(_ value: String?) -> String? {
        guard let value else { return nil }
        let phrase = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !phrase.isEmpty, phrase.count <= maximumPhraseLength,
              phrase.split(separator: " ").count <= maximumPhraseWords,
              phrase.contains(where: \.isLetter),
              phrase.allSatisfy({ $0.isLetter || $0.isNumber || " -'’".contains($0) }) else { return nil }
        return phrase
    }

    /// Re-checks a stored or proposed preference against the closed contract.
    var isWellFormed: Bool {
        switch kind {
        case .spelling:
            guard let from, let to, Self.sanitizedPhrase(from) == from, Self.sanitizedPhrase(to) == to,
                  from != to else { return false }
            return CorrectionText.isSpellingChange(from: from, to: to)
        case .removeFiller, .keepWord:
            guard let from, Self.sanitizedPhrase(from) == from, to == nil else { return false }
            return Self.fillerWords.contains(from.lowercased())
        default:
            return from == nil && to == nil
        }
    }
}

/// Learned preferences per built-in mode, kept in preferences on this Mac.
/// Every write starts from a fresh load, so a cancelled or late request can
/// never overwrite a reset or an edit made meanwhile.
enum LearnedPreferenceStore {
    static let dataKey = "learnedPreferencesData"
    static let enabledKey = "correctionLearningEnabled"
    /// Fingerprints of edits already classified per mode, accepted or not, so
    /// a repeated document is never sent again.
    static let reviewedKey = "learnedPreferencesReviewedEdits"
    static let maximumReviewedPerMode = 500
    static let maximumRulesPerMode = 12
    static let maximumEvidencePerRule = 40

    struct MergeResult: Equatable {
        var added: [LearnedPreference] = []
        var reinforced: [LearnedPreference] = []
        var replaced: [LearnedPreference] = []
        var skippedForLimit = 0
        var unchanged = 0
    }

    static func isLearningEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setLearningEnabled(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enabledKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> [LearnedPreference] {
        preferences(from: defaults.data(forKey: dataKey))
    }

    static func preferences(from data: Data?) -> [LearnedPreference] {
        guard let data, !data.isEmpty,
              let values = try? JSONDecoder().decode([LearnedPreference].self, from: data) else { return [] }
        return sanitized(values)
    }

    static func save(_ preferences: [LearnedPreference], to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(sanitized(preferences)), forKey: dataKey)
    }

    static func preferences(for mode: CleanupMode, in defaults: UserDefaults = .standard) -> [LearnedPreference] {
        load(from: defaults).filter { $0.mode == mode }
    }

    /// What cleanup applies for a mode now: nothing while learning is off.
    static func activePreferences(for mode: CleanupMode, in defaults: UserDefaults = .standard) -> [LearnedPreference] {
        guard isLearningEnabled(in: defaults) else { return [] }
        return preferences(for: mode, in: defaults).filter(\.isEnabled)
    }

    static func setEnabled(_ id: UUID, _ isEnabled: Bool, in defaults: UserDefaults = .standard) {
        var values = load(from: defaults)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].isEnabled = isEnabled
        save(values, to: defaults)
    }

    static func delete(_ id: UUID, in defaults: UserDefaults = .standard) {
        save(load(from: defaults).filter { $0.id != id }, to: defaults)
    }

    static func reset(_ mode: CleanupMode, in defaults: UserDefaults = .standard) {
        save(load(from: defaults).filter { $0.mode != mode }, to: defaults)
        var reviewed = reviewedEdits(in: defaults)
        reviewed[mode.rawValue] = nil
        defaults.set(reviewed, forKey: reviewedKey)
    }

    /// Fingerprints of edits already learned from or classified for a mode.
    static func knownEvidence(for mode: CleanupMode, in defaults: UserDefaults = .standard) -> Set<String> {
        Set(preferences(for: mode, in: defaults).flatMap(\.evidence))
            .union(reviewedEdits(in: defaults)[mode.rawValue] ?? [])
    }

    static func markReviewed(_ fingerprints: [String], for mode: CleanupMode, in defaults: UserDefaults = .standard) {
        var reviewed = reviewedEdits(in: defaults)
        let current = reviewed[mode.rawValue] ?? []
        let fresh = fingerprints.filter { !current.contains($0) }
        reviewed[mode.rawValue] = Array((current + fresh).suffix(maximumReviewedPerMode))
        defaults.set(reviewed, forKey: reviewedKey)
    }

    private static func reviewedEdits(in defaults: UserDefaults) -> [String: [String]] {
        defaults.dictionary(forKey: reviewedKey) as? [String: [String]] ?? [:]
    }

    @discardableResult
    static func merge(
        _ learned: [LearnedPreference],
        into mode: CleanupMode,
        now: Date = Date(),
        in defaults: UserDefaults = .standard
    ) -> MergeResult {
        var values = load(from: defaults)
        var result = MergeResult()
        for preference in learned where preference.mode == mode && preference.isWellFormed {
            if let index = values.firstIndex(where: { $0.mode == mode && $0.key == preference.key }) {
                let known = Set(values[index].evidence)
                let fresh = preference.evidence.filter { !known.contains($0) }
                guard !fresh.isEmpty else {
                    result.unchanged += 1
                    continue
                }
                values[index].evidence = Array((values[index].evidence + fresh).suffix(maximumEvidencePerRule))
                values[index].fromLegacyOnly = values[index].fromLegacyOnly && preference.fromLegacyOnly
                values[index].updatedAt = now
                result.reinforced.append(values[index])
                continue
            }
            // The newer habit replaces a contradicting one for the same mode.
            let conflicts = values.filter {
                $0.mode == mode && $0.kind == preference.kind.conflicting
                    && ($0.from?.lowercased() == preference.from?.lowercased())
            }
            if !conflicts.isEmpty {
                let ids = Set(conflicts.map(\.id))
                values.removeAll { ids.contains($0.id) }
                result.replaced.append(contentsOf: conflicts)
            }
            guard values.filter({ $0.mode == mode }).count < maximumRulesPerMode else {
                result.skippedForLimit += 1
                continue
            }
            var added = preference
            added.learnedAt = now
            added.updatedAt = now
            values.append(added)
            result.added.append(added)
        }
        save(values, to: defaults)
        return result
    }

    static func sanitized(_ values: [LearnedPreference]) -> [LearnedPreference] {
        var seen = Set<String>()
        var perMode: [CleanupMode: Int] = [:]
        var result: [LearnedPreference] = []
        for var value in values where value.isWellFormed && LearnedPreference.isAllowed(value.kind, in: value.mode) {
            guard seen.insert("\(value.mode.rawValue)|\(value.key)").inserted,
                  perMode[value.mode, default: 0] < maximumRulesPerMode else { continue }
            value.evidence = Array(value.evidence.suffix(maximumEvidencePerRule))
            perMode[value.mode, default: 0] += 1
            result.append(value)
        }
        return result
    }
}

// MARK: - Text and alignment

struct CorrectionToken: Equatable {
    let text: String
    /// Lowercased, with curly apostrophes and quotes made straight.
    let key: String
    /// The same with case kept, so a capitalization edit is visible.
    var exactKey: String { text.replacingOccurrences(of: "’", with: "'") }
    let isWord: Bool
    let range: Range<String.Index>
}

enum CorrectionText {
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)*|[^\s\p{L}\p{N}]"#
    )

    static func tokens(_ text: String) -> [CorrectionToken] {
        tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            let isWord = value.first.map { $0.isLetter || $0.isNumber } ?? false
            return CorrectionToken(text: value, key: normalized(value), isWord: isWord, range: range)
        }
    }

    static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
    }

    static func words(_ text: String) -> [String] {
        tokens(text).filter(\.isWord).map(\.key)
    }

    /// Letters and digits only, lowercased: "long-term" and "long term" match.
    static func letters(_ text: String) -> String {
        String(normalized(text).filter { $0.isLetter || $0.isNumber })
    }

    /// A change of spelling, spacing, hyphenation, or capitalization, not of
    /// wording: "key board" → "keyboard", "long term" → "long-term". It never
    /// changes a number, a negation, or a contraction, and never trades a word
    /// for one that means something else: another weekday or month, a
    /// look-alike ("accept" → "except"), or its counterpart by a polarity
    /// prefix or suffix ("possible" → "impossible", "include" → "exclude",
    /// "careful" → "careless").
    static func isSpellingChange(from: String, to: String) -> Bool {
        let source = letters(from)
        let target = letters(to)
        guard !source.isEmpty, !target.isEmpty,
              source.filter(\.isNumber) == target.filter(\.isNumber),
              CleanupGuard.negationCount(in: from) == CleanupGuard.negationCount(in: to),
              apostrophes(in: from) == apostrophes(in: to) else { return false }
        if source == target { return from != to }
        guard min(source.count, target.count) >= 4,
              numberValues(from) == numberValues(to),
              !tradesMeaning(words(from), words(to)) else { return false }
        let distance = editDistance(Array(source), Array(target))
        return Double(distance) / Double(max(source.count, target.count)) <= 0.34
    }

    private static func apostrophes(in text: String) -> Int {
        text.filter { $0 == "'" || $0 == "’" }.count
    }

    private static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december"
    ]

    /// Words close enough in letters to pass for a respelling of each other.
    private static let lookAlikes: Set<Set<String>> = [
        ["accept", "except"], ["affect", "effect"], ["then", "than"], ["loose", "lose"], ["quiet", "quite"],
        ["were", "where"], ["advice", "advise"], ["hire", "fire"], ["later", "latter"], ["weather", "whether"],
        ["desert", "dessert"], ["principal", "principle"], ["complement", "compliment"],
        ["stationary", "stationery"], ["breath", "breathe"], ["elicit", "illicit"], ["eminent", "imminent"],
        ["discreet", "discrete"], ["council", "counsel"], ["personal", "personnel"], ["precede", "proceed"],
        ["formally", "formerly"], ["allusion", "illusion"], ["adverse", "averse"], ["cite", "site"]
    ]

    /// Prefixes and suffixes that turn a word into its opposite or its
    /// counterpart; the empty string stands for the bare word.
    private static let polarityPrefixes: Set<String> = [
        "", "un", "in", "im", "il", "ir", "dis", "non", "a", "anti", "de", "ex", "as", "des",
        "max", "min", "up", "down", "out", "over", "under", "pre", "post"
    ]
    private static let polaritySuffixes: Set<String> = ["", "ful", "less"]

    private static func tradesMeaning(_ from: [String], _ to: [String]) -> Bool {
        guard from.count == to.count else { return false }
        return zip(from, to).contains { a, b in
            a != b && ((calendarWords.contains(a) && calendarWords.contains(b))
                || lookAlikes.contains([a, b])
                || isPolarityCounterpart(a, b))
        }
    }

    private static func isPolarityCounterpart(_ a: String, _ b: String) -> Bool {
        let stem = zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count
        if stem >= 4, polarityPrefixes.contains(String(a.dropLast(stem))),
           polarityPrefixes.contains(String(b.dropLast(stem))) {
            return true
        }
        let root = zip(a, b).prefix { $0 == $1 }.count
        return root >= 3 && polaritySuffixes.contains(String(a.dropFirst(root)))
            && polaritySuffixes.contains(String(b.dropFirst(root)))
    }

    static func editDistance(_ first: [Character], _ second: [Character]) -> Int {
        guard !first.isEmpty else { return second.count }
        guard !second.isEmpty else { return first.count }
        var previous = Array(0...second.count)
        for (i, a) in first.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: second.count)
            for (j, b) in second.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (a == b ? 0 : 1))
            }
            previous = current
        }
        return previous[second.count]
    }

    /// Every numeric value written as digits or as number words.
    static func numberValues(_ text: String) -> Set<String> {
        let spoken = SpokenNumberParser.parse(text)
        let digits = try! NSRegularExpression(pattern: #"\d+(?:[.,:]\d+)*"#)
        let found = digits.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).replacingOccurrences(of: ",", with: "") }
        }
        return spoken.values.union(spoken.digitSequences).union(found)
    }

    static func joined(_ tokens: ArraySlice<CorrectionToken>, in text: String) -> String {
        guard let first = tokens.first, let last = tokens.last else { return "" }
        return String(text[first.range.lowerBound..<last.range.upperBound])
    }
}

/// One local difference between what WorkFlow emitted and what the user kept.
struct CorrectionEdit: Equatable, Sendable {
    var number = 0
    let candidateID: UUID
    let emitted: String
    let final: String
    let before: String
    let after: String
    let origin: LearnedPreference.Origin
    let isLegacy: Bool
    /// What cleanup received at this spot, for new dictations only.
    let cleanupInput: String?
    let documentPosition: Int

    var fingerprint: String {
        let value = [candidateID.uuidString, CorrectionText.normalized(emitted), CorrectionText.normalized(final)]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate var matchKey: String {
        "\(documentPosition)|\(CorrectionText.normalized(emitted))|\(CorrectionText.normalized(final))"
    }
}

struct CorrectionAlignment: Equatable {
    struct Passage: Equatable {
        let candidateID: UUID
        let isLegacy: Bool
        let documentTokens: Range<Int>
        let matchedWords: Int
        let similarity: Double
        var edits: [CorrectionEdit]
        var isAmbiguous = false
    }

    var passages: [Passage] = []
    /// Edits too large, numeric, or quoted to teach a style habit.
    var excludedEdits = 0
    /// Document regions two dictations matched about equally well.
    var ambiguousRegions = 0

    var edits: [CorrectionEdit] {
        var numbered: [CorrectionEdit] = []
        for edit in passages.flatMap(\.edits).sorted(by: { $0.documentPosition < $1.documentPosition }) {
            var value = edit
            value.number = numbered.count + 1
            numbered.append(value)
        }
        return numbered
    }

    var matchedDictations: Set<UUID> { Set(passages.map(\.candidateID)) }
}

/// Finds which parts of a finished document came from which dictations, using
/// unique four-word anchors that appear once in each text. Only confident,
/// unambiguous matches produce edits; everything else is left alone.
enum CorrectionAligner {
    static let anchorLength = 4
    static let minimumMatchedWords = 8
    static let minimumCoverage = 0.5
    static let minimumSimilarity = 0.6
    static let maximumEditWords = 5
    static let maximumCandidateTokens = 2_500
    static let maximumDocumentLength = 100_000

    private enum Operation: Equatable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    static func align(document: String, candidates: [CorrectionCandidate]) -> CorrectionAlignment {
        let documentTokens = CorrectionText.tokens(String(document.prefix(maximumDocumentLength)))
        let text = String(document.prefix(maximumDocumentLength))
        let quoted = quotedTokens(documentTokens)
        let lineEnds = lineEndTokens(documentTokens, in: text)
        let documentWords = documentTokens.indices.filter { documentTokens[$0].isWord }
        let documentAnchors = anchorPositions(documentWords.map { documentTokens[$0].key })

        var alignment = CorrectionAlignment()
        var found: [CorrectionAlignment.Passage] = []
        for candidate in candidates {
            let candidateTokens = Array(CorrectionText.tokens(candidate.emitted).prefix(maximumCandidateTokens))
            let candidateWords = candidateTokens.indices.filter { candidateTokens[$0].isWord }
            guard candidateWords.count >= minimumMatchedWords else { continue }
            let candidateAnchors = anchorPositions(candidateWords.map { candidateTokens[$0].key })
            var anchors: [(candidate: Int, document: Int)] = []
            for (shingle, positions) in candidateAnchors where positions.count == 1 {
                if let documentPositions = documentAnchors[shingle], documentPositions.count == 1 {
                    anchors.append((positions[0], documentPositions[0]))
                }
            }
            anchors.sort { $0.candidate < $1.candidate }

            let anchorChains = chains(anchors)
            for chain in anchorChains {
                let candidateRange = candidateTokenRange(
                    chain: chain,
                    chainCount: anchorChains.count,
                    words: candidateWords,
                    tokens: candidateTokens
                )
                let anchorStart = documentWords[chain[0].document]
                let anchorEnd = documentWords[chain[chain.count - 1].document + anchorLength - 1] + 1
                let firstAnchorToken = candidateWords[chain[0].candidate]
                let lastAnchorToken = candidateWords[chain[chain.count - 1].candidate + anchorLength - 1]
                let window = max(0, anchorStart - (firstAnchorToken - candidateRange.lowerBound) - 12)
                    ..< min(documentTokens.count, anchorEnd + (candidateRange.upperBound - lastAnchorToken - 1) + 12)
                if let passage = passage(
                    candidate: candidate,
                    candidateTokens: candidateTokens,
                    candidateRange: candidateRange,
                    documentText: text,
                    documentTokens: documentTokens,
                    window: window,
                    quoted: quoted,
                    lineEnds: lineEnds,
                    excluded: &alignment.excludedEdits
                ) {
                    found.append(passage)
                }
            }
        }

        // The strongest passage claims a region. A near-equal rival there is a
        // repeated take: only edits both takes show are kept.
        for passage in found.sorted(by: { $0.matchedWords > $1.matchedWords }) {
            if let index = alignment.passages.firstIndex(where: { overlap($0.documentTokens, passage.documentTokens) > 0.3 }) {
                let claimed = alignment.passages[index]
                if Double(passage.matchedWords) >= 0.9 * Double(claimed.matchedWords) {
                    let shared = Set(passage.edits.map(\.matchKey))
                    if !alignment.passages[index].isAmbiguous { alignment.ambiguousRegions += 1 }
                    alignment.passages[index].isAmbiguous = true
                    alignment.passages[index].edits = claimed.edits.filter { shared.contains($0.matchKey) }
                }
                continue
            }
            alignment.passages.append(passage)
        }
        return alignment
    }

    private static func anchorPositions(_ words: [String]) -> [String: [Int]] {
        guard words.count >= anchorLength else { return [:] }
        var positions: [String: [Int]] = [:]
        for start in 0...(words.count - anchorLength) {
            positions[words[start..<(start + anchorLength)].joined(separator: " "), default: []].append(start)
        }
        return positions
    }

    /// Monotonic anchor chains, longest first, so reordered passages of one
    /// dictation align separately. At most three chains of two or more anchors.
    private static func chains(_ anchors: [(candidate: Int, document: Int)]) -> [[(candidate: Int, document: Int)]] {
        var remaining = anchors
        var result: [[(candidate: Int, document: Int)]] = []
        while result.count < 3, remaining.count >= 2 {
            let chain = longestIncreasing(remaining)
            guard chain.count >= 2 else { break }
            result.append(chain)
            let used = Set(chain.map(\.candidate))
            let span = chain[0].candidate...chain[chain.count - 1].candidate
            remaining.removeAll { used.contains($0.candidate) || span.contains($0.candidate) }
        }
        return result.sorted { $0[0].candidate < $1[0].candidate }
    }

    private static func longestIncreasing(_ anchors: [(candidate: Int, document: Int)]) -> [(candidate: Int, document: Int)] {
        guard !anchors.isEmpty else { return [] }
        var length = Array(repeating: 1, count: anchors.count)
        var previous = Array(repeating: -1, count: anchors.count)
        for i in anchors.indices {
            for j in 0..<i where anchors[j].document < anchors[i].document && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var index = length.indices.max { length[$0] < length[$1] } ?? 0
        var chain: [(candidate: Int, document: Int)] = []
        while index >= 0 {
            chain.append(anchors[index])
            index = previous[index]
        }
        return chain.reversed()
    }

    /// The whole dictation for a single chain; otherwise the anchored span
    /// widened to sentence boundaries.
    private static func candidateTokenRange(
        chain: [(candidate: Int, document: Int)],
        chainCount: Int,
        words: [Int],
        tokens: [CorrectionToken]
    ) -> Range<Int> {
        guard chainCount > 1 else { return 0..<tokens.count }
        var start = words[chain[0].candidate]
        var end = words[chain[chain.count - 1].candidate + anchorLength - 1] + 1
        while start > 0, !".!?".contains(tokens[start - 1].text) { start -= 1 }
        while end < tokens.count, !".!?".contains(tokens[end - 1].text) { end += 1 }
        return start..<end
    }

    private static func passage(
        candidate: CorrectionCandidate,
        candidateTokens: [CorrectionToken],
        candidateRange: Range<Int>,
        documentText: String,
        documentTokens: [CorrectionToken],
        window: Range<Int>,
        quoted: Set<Int>,
        lineEnds: Set<Int>,
        excluded: inout Int
    ) -> CorrectionAlignment.Passage? {
        let left = Array(candidateTokens[candidateRange])
        let right = Array(documentTokens[window])
        var operations = diff(left.map(\.exactKey), right.map(\.exactKey))
        guard let firstEqual = operations.firstIndex(where: { if case .equal = $0 { true } else { false } }),
              let lastEqual = operations.lastIndex(where: { if case .equal = $0 { true } else { false } }) else { return nil }
        // Unmatched text at either edge is kept only when it is short and in
        // the same sentence: anything more is surrounding document content.
        let breaks = Set(right.indices.filter { ".!?".contains(right[$0].text) || lineEnds.contains(window.lowerBound + $0) })
        operations = edge(Array(operations[..<firstEqual]), leading: true, breaks: breaks)
            + Array(operations[firstEqual...lastEqual])
            + edge(Array(operations[(lastEqual + 1)...]), leading: false, breaks: breaks)

        var matched = 0
        var leftWords = 0
        var rightWords = 0
        for operation in operations {
            switch operation {
            case .equal(let a, _):
                if left[a].isWord { matched += 1; leftWords += 1; rightWords += 1 }
            case .delete(let a):
                if left[a].isWord { leftWords += 1 }
            case .insert(let b):
                if right[b].isWord { rightWords += 1 }
            }
        }
        let candidateWords = left.filter(\.isWord).count
        guard matched >= minimumMatchedWords,
              Double(matched) / Double(max(candidateWords, 1)) >= minimumCoverage,
              2 * Double(matched) / Double(max(leftWords + rightWords, 1)) >= minimumSimilarity else { return nil }

        let documentIndices = operations.compactMap { operation -> Int? in
            switch operation {
            case .equal(_, let b), .insert(let b): window.lowerBound + b
            case .delete: nil
            }
        }
        guard let documentStart = documentIndices.min(), let documentEnd = documentIndices.max() else { return nil }
        let documentRange = documentStart..<(documentEnd + 1)
        // A quotation of the dictation is not the user's own writing.
        guard Double(documentRange.filter(quoted.contains).count) <= 0.5 * Double(documentRange.count) else { return nil }

        let cleanupMap = candidate.cleanupInput.map { cleanupAlignment(input: $0, emitted: candidate.emitted) }
        var edits: [CorrectionEdit] = []
        var index = 0
        while index < operations.count {
            guard !isEqual(operations[index]) else { index += 1; continue }
            var end = index
            while end < operations.count, !isEqual(operations[end]) { end += 1 }
            let hunk = operations[index..<end]
            let deleted = hunk.compactMap { if case .delete(let a) = $0 { a } else { nil } }
            let inserted = hunk.compactMap { if case .insert(let b) = $0 { b } else { nil } }
            let leftStart = deleted.first ?? previousLeft(operations, before: index) + 1
            let leftSlice = deleted.isEmpty ? left[leftStart..<leftStart] : left[deleted[0]...deleted[deleted.count - 1]]
            let rightSlice = inserted.isEmpty ? right[0..<0] : right[inserted[0]...inserted[inserted.count - 1]]
            let documentPosition = window.lowerBound + (inserted.first ?? nextRight(operations, after: end - 1, fallback: right.count))
            defer { index = end }

            let emitted = CorrectionText.joined(leftSlice, in: candidate.emitted)
            let final = CorrectionText.joined(rightSlice, in: documentText)
            let isQuoted = rightSlice.indices.contains { quoted.contains(window.lowerBound + $0) }
                || quoted.contains(documentPosition)
            // Added words that span a line break, or fill a line of their
            // own, may be a neighboring column, heading, or footnote of an
            // imported layout rather than the user's edit, so they are too
            // uncertain to learn from.
            let crossesLine = rightSlice.contains(where: \.isWord) && inserted.first.map { first in
                let start = window.lowerBound + first
                let end = window.lowerBound + inserted[inserted.count - 1]
                return (start..<end).contains(where: lineEnds.contains)
                    || (lineEnds.contains(start - 1) && lineEnds.contains(end))
            } ?? false
            // A changed value or a flipped negation is content, not style.
            guard leftSlice.filter(\.isWord).count <= maximumEditWords,
                  rightSlice.filter(\.isWord).count <= maximumEditWords,
                  !isQuoted,
                  !crossesLine,
                  CleanupGuard.negationCount(in: emitted) == CleanupGuard.negationCount(in: final),
                  CorrectionText.numberValues(emitted) == CorrectionText.numberValues(final)
                    || isNumberFormatting(emitted, final) else {
                excluded += 1
                continue
            }
            let candidateOffset = candidateRange.lowerBound + leftStart
            let candidateSpan = candidateOffset..<(candidateOffset + leftSlice.count)
            let (origin, cleanupInput) = classify(
                emitted: emitted,
                final: final,
                candidateSpan: candidateSpan,
                candidateTokens: candidateTokens,
                cleanupMap: cleanupMap,
                isLegacy: candidate.isLegacy
            )
            edits.append(CorrectionEdit(
                candidateID: candidate.id,
                emitted: emitted,
                final: final,
                before: context(left, before: leftStart, in: candidate.emitted),
                after: context(left, after: leftStart + leftSlice.count, in: candidate.emitted),
                origin: origin,
                isLegacy: candidate.isLegacy,
                cleanupInput: cleanupInput,
                documentPosition: documentPosition
            ))
        }
        return CorrectionAlignment.Passage(
            candidateID: candidate.id,
            isLegacy: candidate.isLegacy,
            documentTokens: documentRange,
            matchedWords: matched,
            similarity: 2 * Double(matched) / Double(max(leftWords + rightWords, 1)),
            edits: edits
        )
    }

    /// "ten percent" → "10%": the same values in another notation.
    private static func isNumberFormatting(_ emitted: String, _ final: String) -> Bool {
        let before = CorrectionText.numberValues(emitted)
        let after = CorrectionText.numberValues(final)
        return !after.isEmpty && after.isSubset(of: before)
            && SpokenNumberParser.occurrences(in: emitted).allSatisfy { !$0.values.isDisjoint(with: after) }
    }

    private static func isEqual(_ operation: Operation) -> Bool {
        if case .equal = operation { return true }
        return false
    }

    private static func previousLeft(_ operations: [Operation], before index: Int) -> Int {
        for operation in operations[..<index].reversed() {
            switch operation {
            case .equal(let a, _), .delete(let a): return a
            case .insert: continue
            }
        }
        return -1
    }

    private static func nextRight(_ operations: [Operation], after index: Int, fallback: Int) -> Int {
        for operation in operations.dropFirst(index + 1) {
            switch operation {
            case .equal(_, let b), .insert(let b): return b
            case .delete: continue
            }
        }
        return fallback
    }

    /// The edge operations that belong to the dictation: document text only
    /// back to the sentence break before the match (or up to the one after
    /// it), and nothing at all when that leaves more than a few tokens.
    /// `breaks` are document tokens that end a sentence or a line.
    private static func edge(_ operations: [Operation], leading: Bool, breaks: Set<Int>) -> [Operation] {
        let limit = 3
        var kept: [Operation] = []
        var reachedBreak = false
        for operation in leading ? operations.reversed() : operations {
            if case .insert(let b) = operation {
                if leading && breaks.contains(b) { reachedBreak = true }
                if !leading && breaks.contains(b - 1) { reachedBreak = true }
                if reachedBreak { continue }
                if !leading && breaks.contains(b) { reachedBreak = true }
            }
            kept.append(operation)
        }
        if leading { kept.reverse() }
        let deletes = kept.filter { if case .delete = $0 { true } else { false } }.count
        let inserts = kept.count - deletes
        return deletes <= limit && inserts <= limit ? kept : []
    }

    private static func context(_ tokens: [CorrectionToken], before index: Int, in text: String) -> String {
        CorrectionText.joined(tokens[max(0, index - 6)..<max(0, index)], in: text)
    }

    private static func context(_ tokens: [CorrectionToken], after index: Int, in text: String) -> String {
        CorrectionText.joined(tokens[min(tokens.count, index)..<min(tokens.count, index + 6)], in: text)
    }

    /// Which cleanup-input token each emitted token was carried over from,
    /// or nil where cleanup wrote something new.
    private struct CleanupMap {
        let inputTokens: [CorrectionToken]
        let input: String
        let carriedFrom: [Int?]

        /// Cleanup's input around an emitted span, including words cleanup
        /// removed on either side of it.
        func inputRange(for span: Range<Int>) -> Range<Int> {
            let start = carriedFrom[..<min(span.lowerBound, carriedFrom.count)].last(where: { $0 != nil }).flatMap { $0 }.map { $0 + 1 } ?? 0
            let end = carriedFrom[min(span.upperBound, carriedFrom.count)...].first(where: { $0 != nil }).flatMap { $0 } ?? inputTokens.count
            return start..<max(start, end)
        }
    }

    private static func cleanupAlignment(input: String, emitted: String) -> CleanupMap {
        let inputTokens = Array(CorrectionText.tokens(input).prefix(maximumCandidateTokens))
        let emittedTokens = Array(CorrectionText.tokens(emitted).prefix(maximumCandidateTokens))
        var carriedFrom = [Int?](repeating: nil, count: emittedTokens.count)
        for case .equal(let a, let b) in diff(inputTokens.map(\.key), emittedTokens.map(\.key)) {
            carriedFrom[b] = a
        }
        return CleanupMap(inputTokens: inputTokens, input: input, carriedFrom: carriedFrom)
    }

    private static func classify(
        emitted: String,
        final: String,
        candidateSpan: Range<Int>,
        candidateTokens: [CorrectionToken],
        cleanupMap: CleanupMap?,
        isLegacy: Bool
    ) -> (LearnedPreference.Origin, String?) {
        // Legacy History has no original, so its edits are emitted-to-final only.
        guard !isLegacy, let map = cleanupMap,
              candidateSpan.upperBound <= map.carriedFrom.count else { return (.finalEdit, nil) }
        let inputSlice = map.inputTokens[map.inputRange(for: candidateSpan)]
        let inputText = CorrectionText.joined(inputSlice, in: map.input)
        let emittedKeys = candidateTokens[candidateSpan].map(\.key)
        if inputSlice.map(\.key) == emittedKeys, !candidateSpan.isEmpty,
           candidateSpan.allSatisfy({ map.carriedFrom[$0] != nil }) {
            return (CorrectionText.isSpellingChange(from: emitted, to: final) ? .recognition : .finalEdit, inputText)
        }
        if CorrectionText.words(inputText) == CorrectionText.words(final), inputText != emitted {
            return (.cleanup, inputText)
        }
        return (.finalEdit, inputText)
    }

    /// Indices of document tokens followed by a line break.
    private static func lineEndTokens(_ tokens: [CorrectionToken], in text: String) -> Set<Int> {
        Set(tokens.indices.dropLast().filter { text[tokens[$0].range.upperBound..<tokens[$0 + 1].range.lowerBound].contains(where: \.isNewline) })
    }

    /// Indices of document tokens inside quotation marks.
    private static func quotedTokens(_ tokens: [CorrectionToken]) -> Set<Int> {
        var result = Set<Int>()
        var straightOpen = false
        var curlyDepth = 0
        for (index, token) in tokens.enumerated() {
            switch token.text {
            case "\"": straightOpen.toggle(); continue
            case "“": curlyDepth += 1; continue
            case "”": curlyDepth = max(0, curlyDepth - 1); continue
            default: break
            }
            if straightOpen || curlyDepth > 0 { result.insert(index) }
        }
        return result
    }

    private static func overlap(_ first: Range<Int>, _ second: Range<Int>) -> Double {
        let shared = max(0, min(first.upperBound, second.upperBound) - max(first.lowerBound, second.lowerBound))
        return Double(shared) / Double(max(1, min(first.count, second.count)))
    }

    /// Longest-common-subsequence alignment of two token key lists.
    private static func diff(_ left: [String], _ right: [String]) -> [Operation] {
        let n = left.count
        let m = right.count
        guard n > 0 || m > 0 else { return [] }
        var table = Array(repeating: Array(repeating: Int32(0), count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = left[i] == right[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var operations: [Operation] = []
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, left[i] == right[j] {
                operations.append(.equal(i, j)); i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                operations.append(.insert(j)); j += 1
            } else {
                operations.append(.delete(i)); i += 1
            }
        }
        return operations
    }
}
