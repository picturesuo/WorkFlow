import Foundation

struct VocabularyEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var spoken: String
    var replacement: String
    var isEnabled = true
}

enum VocabularyStore {
    static let maximumEntries = 500

    static func load() -> [VocabularyEntry] {
        guard let data = AppPreferences.shared.personalVocabularyData,
              let values = try? JSONDecoder().decode([VocabularyEntry].self, from: data) else {
            return []
        }
        return Array(values.prefix(maximumEntries))
    }

    static func save(_ entries: [VocabularyEntry]) {
        AppPreferences.shared.personalVocabularyData = try? JSONEncoder().encode(
            Array(entries.prefix(maximumEntries))
        )
    }

    /// Adds one entry the person chose, unless the same replacement for the
    /// same spoken words is already there, and tells open editors to reload.
    /// Returns true when the entry is present afterward (added or already
    /// there) and false only when Vocabulary is full.
    @discardableResult
    static func add(_ entry: VocabularyEntry) -> Bool {
        var entries = load()
        if entries.contains(where: {
            $0.spoken.caseInsensitiveCompare(entry.spoken) == .orderedSame && $0.replacement == entry.replacement
        }) {
            return true
        }
        guard entries.count < maximumEntries else { return false }
        entries.append(entry)
        save(entries)
        NotificationCenter.default.post(name: .vocabularyDidChange, object: nil)
        return true
    }
}

extension Notification.Name {
    /// Posted when Vocabulary changed outside its editor.
    static let vocabularyDidChange = Notification.Name("WorkFlowVocabularyDidChange")
}

enum VocabularyRewriter {
    static func apply(_ text: String, entries: [VocabularyEntry]) -> String {
        let normalized = entries
            .filter(\.isEnabled)
            .map { (spoken: $0.spoken.trimmingCharacters(in: .whitespacesAndNewlines), replacement: $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.spoken.isEmpty && !$0.replacement.isEmpty }
            .sorted {
                if $0.spoken.count == $1.spoken.count {
                    return $0.spoken.localizedCaseInsensitiveCompare($1.spoken) == .orderedAscending
                }
                return $0.spoken.count > $1.spoken.count
            }

        guard !normalized.isEmpty else { return text }
        let alternatives = normalized.map { NSRegularExpression.escapedPattern(for: $0.spoken) }
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let lookup = Dictionary(normalized.map { ($0.spoken.lowercased(), $0.replacement) }, uniquingKeysWith: { first, _ in first })
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let matched = nsText.substring(with: match.range).lowercased()
            guard let replacement = lookup[matched],
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
