import Foundation

/// What a finished document can teach, worked out on this Mac before anything
/// is sent: the dictations it contains, the mode or filter each one teaches,
/// every matched edit and what happens to it, and the exact lines one Learn
/// sends. Check matches and Learn build the same plan. It holds document text
/// only in memory and is never saved.
struct CorrectionLearningPlan: Equatable, Sendable {
    /// Where one matched dictation's edits go.
    enum Scope: Hashable, Sendable {
        /// The mode or filter History recorded for the dictation.
        case recorded(LearningTarget)
        /// Older History that recorded no mode teaches the mode picked for it.
        case fallback(LearningTarget)
        /// Made with a saved filter that has since been deleted.
        case deletedFilter
        /// Made with a saved filter History did not record.
        case unknownFilter

        var target: LearningTarget? {
            switch self {
            case .recorded(let target), .fallback(let target): target
            case .deletedFilter, .unknownFilter: nil
            }
        }
    }

    struct Dictation: Equatable, Sendable, Identifiable {
        let id: UUID
        let timestamp: Date
        let isLegacy: Bool
        let scope: Scope
    }

    enum Disposition: Equatable, Sendable {
        /// In this Learn's request, exactly as shown.
        case send
        /// For another mode or filter, or past this request's limit: the next Learn sends it.
        case later
        case alreadyReviewed
        /// The same edit again in one dictation, sent once.
        case repeated
        case excluded(CorrectionExclusion.Reason)
        /// The dictation's filter is gone or was never recorded.
        case unscoped(Scope)
    }

    struct Item: Equatable, Sendable, Identifiable {
        let id: Int
        let dictationID: UUID
        /// For `send`, the exact line in the request; otherwise the same form.
        let excerpt: String
        let disposition: Disposition
        let target: LearningTarget?

        var isLeftOut: Bool {
            switch disposition {
            case .excluded(let reason): reason != .wordChange
            case .unscoped: true
            default: false
            }
        }
    }

    /// A word the person swapped for another, offered for Vocabulary.
    struct WordChange: Hashable, Sendable, Identifiable {
        let spoken: String
        let replacement: String
        var id: String { spoken.lowercased() + "\u{1F}" + replacement }
    }

    /// The History compared, for explaining a document that matched nothing.
    struct Search: Equatable, Sendable {
        var dictations = 0
        var oldest: Date?
        var newest: Date?
        /// Dictations too short to ever match.
        var tooShort = 0
    }

    var dictations: [Dictation] = []
    var items: [Item] = []
    var wordChanges: [WordChange] = []
    /// What this Learn teaches: the mode or filter with the most new edits.
    var target: LearningTarget?
    /// The edits this Learn sends, in request order.
    var batch: [CorrectionEdit] = []
    /// New edits a later Learn sends.
    var remainingEdits = 0
    /// Matched edits that may teach a style habit, before review.
    var learnableEdits = 0
    var matchedPassages = 0
    var ambiguousRegions = 0
    var nearMisses = 0
    var repeatedPassages = 0
    var search = Search()

    var matchedDictations: Int { dictations.count }
    var legacyDictations: Int { dictations.filter(\.isLegacy).count }
    var excludedEdits: Int { items.filter(\.isLeftOut).count }
    var unreviewedEdits: Int { batch.count + remainingEdits }

    /// - Parameters:
    ///   - filters: the saved filters now, to resolve recorded filter ids.
    ///   - fallbackMode: what History without a recorded mode teaches.
    ///   - knownEvidence: fingerprints already learned or reviewed, by
    ///     `LearningTarget.storageKey`.
    static func make(
        document: String,
        candidates: [CorrectionCandidate],
        filters: [CustomCleanupFilter],
        fallbackMode: CleanupMode,
        knownEvidence: [String: Set<String>],
        maximumEdits: Int = CorrectionLearningPrompt.maximumEdits
    ) -> CorrectionLearningPlan {
        let alignment = CorrectionAligner.align(document: document, candidates: candidates)
        var plan = CorrectionLearningPlan()
        plan.matchedPassages = alignment.passages.count
        plan.ambiguousRegions = alignment.ambiguousRegions
        plan.nearMisses = alignment.nearMisses
        plan.repeatedPassages = alignment.repeatedPassages
        plan.search = Search(
            dictations: candidates.count,
            oldest: candidates.map(\.timestamp).min(),
            newest: candidates.map(\.timestamp).max(),
            tooShort: candidates.filter { $0.wordCount < CorrectionAligner.minimumMatchedWords }.count
        )

        let candidatesByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let filtersByID = Dictionary(filters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func scope(_ candidate: CorrectionCandidate) -> Scope {
            switch candidate.provenance {
            case .mode(let mode): .recorded(.mode(mode))
            case .filter(let id): filtersByID[id].map { .recorded(.filter($0)) } ?? .deletedFilter
            case .unknownFilter: .unknownFilter
            case .unrecorded: .fallback(.mode(fallbackMode))
            }
        }
        var scopes: [UUID: Scope] = [:]
        for passage in alignment.passages.sorted(by: { $0.documentTokens.lowerBound < $1.documentTokens.lowerBound })
        where scopes[passage.candidateID] == nil {
            guard let candidate = candidatesByID[passage.candidateID] else { continue }
            let value = scope(candidate)
            scopes[passage.candidateID] = value
            plan.dictations.append(Dictation(id: candidate.id, timestamp: candidate.timestamp, isLegacy: candidate.isLegacy, scope: value))
        }

        // Edits each target has not seen, in document order; a repeated
        // edit counts once, like one piece of evidence.
        struct Entry {
            let position: Int
            let dictationID: UUID
            let excerpt: String
            var disposition: Disposition
            let target: LearningTarget?
            let editNumber: Int?
        }
        var entries: [Entry] = []
        var fresh: [LearningTarget: [CorrectionEdit]] = [:]
        var targetOrder: [LearningTarget] = []
        var seen = knownEvidence
        for edit in alignment.edits {
            let dictationScope = scopes[edit.candidateID] ?? .fallback(.mode(fallbackMode))
            let line = CorrectionLearningPrompt.line(for: edit)
            guard let target = dictationScope.target else {
                entries.append(Entry(position: edit.documentPosition, dictationID: edit.candidateID, excerpt: line,
                                     disposition: .unscoped(dictationScope), target: nil, editNumber: nil))
                continue
            }
            plan.learnableEdits += 1
            let key = target.storageKey
            let disposition: Disposition
            if knownEvidence[key]?.contains(edit.fingerprint) == true {
                disposition = .alreadyReviewed
            } else if !seen[key, default: []].insert(edit.fingerprint).inserted {
                disposition = .repeated
            } else {
                if fresh[target] == nil { targetOrder.append(target) }
                fresh[target, default: []].append(edit)
                disposition = .later
            }
            entries.append(Entry(position: edit.documentPosition, dictationID: edit.candidateID, excerpt: line,
                                 disposition: disposition, target: target, editNumber: edit.number))
        }

        // One request teaches one mode or filter: the one with the most new
        // edits, the first in the document on a tie.
        var best: LearningTarget?
        for target in targetOrder where (fresh[target]?.count ?? 0) > (best.flatMap { fresh[$0]?.count } ?? 0) {
            best = target
        }
        if let best {
            plan.target = best
            plan.batch = Array((fresh[best] ?? []).prefix(maximumEdits))
        }
        plan.remainingEdits = fresh.values.reduce(0) { $0 + $1.count } - plan.batch.count
        let sending = Set(plan.batch.map(\.number))
        for index in entries.indices where entries[index].disposition == .later
            && entries[index].target == plan.target && entries[index].editNumber.map(sending.contains) == true {
            entries[index].disposition = .send
        }

        var excludedSeen = Set<String>()
        var changesSeen = Set<String>()
        for exclusion in alignment.exclusions {
            let key = "\(exclusion.documentPosition)|\(exclusion.emitted)|\(exclusion.final)|\(exclusion.reason.rawValue)"
            guard excludedSeen.insert(key).inserted else { continue }
            let excerpt = CorrectionLearningPrompt.excerpt(
                before: exclusion.before, emitted: exclusion.emitted, final: exclusion.final, after: exclusion.after
            )
            entries.append(Entry(position: exclusion.documentPosition, dictationID: exclusion.candidateID, excerpt: excerpt,
                                 disposition: .excluded(exclusion.reason), target: nil, editNumber: nil))
            if exclusion.reason == .wordChange,
               let spoken = LearnedPreference.sanitizedPhrase(trimmedEdge(exclusion.emitted)),
               let replacement = LearnedPreference.sanitizedPhrase(trimmedEdge(exclusion.final)) {
                let change = WordChange(spoken: spoken, replacement: replacement)
                if changesSeen.insert(change.id).inserted { plan.wordChanges.append(change) }
            }
        }

        plan.items = entries.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .enumerated()
            .map { index, entry in
                Item(id: index + 1, dictationID: entry.element.dictationID, excerpt: entry.element.excerpt,
                     disposition: entry.element.disposition, target: entry.element.target)
            }
        return plan
    }

    /// The words without surrounding punctuation or space.
    private static func trimmedEdge(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "-'’")))
    }
}
