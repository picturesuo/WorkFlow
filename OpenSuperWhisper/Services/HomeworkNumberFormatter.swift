import Foundation

/// Homework writes spoken quantities as digits: "fifteen percent" → "15%",
/// "twenty twenty six" → "2026", and "one hundred five" → "105". Cleanup
/// models do not reliably follow that rule, so a successful Homework cleanup
/// is finished on this Mac, and the cleanup guard checks the result against
/// the original transcript.
///
/// Only plain quantities change: any spoken number with "percent", a spoken
/// year (two two-digit groups, 1900-2099), multi-word numbers and decimals,
/// single numbers of 10 or more, and digits followed by the word "percent".
/// These stay as the model wrote them: zero to nine on their own, ordinals,
/// digit runs such as codes and phone numbers, clock times, back-to-back
/// numbers other than a year, numbers in quotes, capitalized names and
/// titles, hyphenated compounds, and a million or more.
enum HomeworkNumberFormatter {
    private typealias Edit = (range: Range<String.Index>, replacement: String)

    static func format(_ text: String) -> String {
        var edits: [Edit] = []
        let occurrences = SpokenNumberParser.occurrences(in: text)
        var start = 0
        while start < occurrences.count {
            var end = start + 1
            while end < occurrences.count, isBackToBack(occurrences[end - 1], occurrences[end], in: text) { end += 1 }
            let group = Array(occurrences[start..<end])
            start = end
            if group.count == 1 {
                if let edit = edit(for: group[0], in: text) { edits.append(edit) }
                continue
            }
            // Back-to-back numbers are a year ("twenty twenty six") or stay
            // as words ("five thirty"), so no two digit groups end up joined.
            var index = 0
            while index + 1 < group.count {
                if let year = spokenYear(group[index], group[index + 1]) {
                    let range = group[index].range.lowerBound..<group[index + 1].range.upperBound
                    if isProse(range, in: text) { edits.append(withPercent(range, year, in: text)) }
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        for match in digitsBeforePercent.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text),
                  isProse(digits, in: text) else { continue }
            edits.append((range, String(text[digits]) + "%"))
        }

        var result = ""
        var cursor = text.startIndex
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where edit.range.lowerBound >= cursor {
            result += text[cursor..<edit.range.lowerBound] + edit.replacement
            cursor = edit.range.upperBound
        }
        return result + text[cursor...]
    }

    private static let percentAfter = try! NSRegularExpression(pattern: #"^\s*per\s?cent\b"#, options: [.caseInsensitive])
    private static let digitsBeforePercent = try! NSRegularExpression(
        pattern: #"(?<![\w.,])(\d+(?:\.\d+)?)\s*per\s?cent\b"#,
        options: [.caseInsensitive]
    )

    private static func edit(for occurrence: SpokenNumberOccurrence, in text: String) -> Edit? {
        let words = occurrence.words
        guard !words.contains(where: SpokenNumberParser.isOrdinalWord),
              !words.allSatisfy({ SpokenNumberParser.digit(forWord: $0) != nil }) || hasPercent(after: occurrence.range, in: text),
              !occurrence.values.contains(where: { $0.contains(":") }),
              let digits = digits(for: occurrence.value) else { return nil }
        var range = occurrence.range
        // "a hundred and five" → "105", not "a 105".
        if words.first == "hundred" || words.first == "thousand",
           let article = text[..<range.lowerBound].range(of: #"\b[aA]\s+$"#, options: .regularExpression) {
            range = article.lowerBound..<range.upperBound
        }
        guard isProse(range, in: text) else { return nil }
        return withPercent(range, digits, in: text)
    }

    /// "twenty twenty six" or "nineteen eighty four": two two-digit groups
    /// that the parser also reads as one year.
    private static func spokenYear(_ first: SpokenNumberOccurrence, _ second: SpokenNumberOccurrence) -> String? {
        guard let high = Int(first.value), let low = Int(second.value),
              (10...99).contains(high), (10...99).contains(low) else { return nil }
        let year = String(format: "%d%02d", high, low)
        guard (1900...2099).contains(high * 100 + low),
              first.values.contains(year), second.values.contains(year) else { return nil }
        return year
    }

    /// Plain digits up to 9999 and grouped thousands up to a million.
    private static func digits(for value: String) -> String? {
        if value.contains(".") { return value }
        guard let number = Int(value), number < 1_000_000 else { return nil }
        guard number >= 10_000 else { return value }
        return "\(number / 1_000)," + String(format: "%03d", number % 1_000)
    }

    private static func hasPercent(after range: Range<String.Index>, in text: String) -> Bool {
        let after = String(text[range.upperBound...].prefix(12))
        return percentAfter.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil
    }

    /// "fifteen percent" → "15%"; any other number → its digits.
    private static func withPercent(_ range: Range<String.Index>, _ digits: String, in text: String) -> Edit {
        let after = String(text[range.upperBound...].prefix(12))
        guard let match = percentAfter.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)),
              let matched = Range(match.range, in: after) else { return (range, digits) }
        let end = text.index(range.upperBound, offsetBy: after.distance(from: after.startIndex, to: matched.upperBound))
        return (range.lowerBound..<end, digits + "%")
    }

    private static func isBackToBack(_ first: SpokenNumberOccurrence, _ second: SpokenNumberOccurrence, in text: String) -> Bool {
        text[first.range.upperBound..<second.range.lowerBound].allSatisfy { $0.isWhitespace || $0 == "-" }
    }

    /// Ordinary lowercase wording, outside quotes, names, titles, and
    /// hyphenated compounds; only a sentence's first word may be capitalized.
    private static func isProse(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<range.lowerBound]
        guard before.filter({ $0 == "\"" }).count.isMultiple(of: 2),
              before.filter({ $0 == "“" }).count <= before.filter({ $0 == "”" }).count else { return false }

        let after = text[range.upperBound...]
        if before.last == "-", before.dropLast().last?.isLetter == true { return false }
        if after.first == "-", after.dropFirst().first?.isLetter == true { return false }
        // "Ten Commandments": a capitalized word right after names something.
        if after.drop(while: \.isWhitespace).first?.isUppercase == true { return false }

        let sentenceStart = before.last(where: { !$0.isWhitespace }).map { ".!?…:;\n".contains($0) } ?? true
        for (index, word) in text[range].split(whereSeparator: { !$0.isLetter }).enumerated() where word != word.lowercased() {
            let capitalizedOnly = word.dropFirst() == word.dropFirst().lowercased()
            guard index == 0, sentenceStart, capitalizedOnly else { return false }
        }
        return true
    }
}
