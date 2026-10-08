import Foundation

/// Accepts a custom filter's math symbols only where the speaker said the
/// operation. A filter may write "square root of sixteen" as "√16" or "five
/// times three" as "5 x 3", but cleanup must never introduce an operation,
/// solve anything, or guess how far a radical extends. Anything else falls
/// back to the local transcript.
enum MathNotationGuard {
    static func isGrounded(_ cleaned: String, source: String) -> Bool {
        let addedRoots = max(0, count("√", in: cleaned) - count("√", in: source))
        guard addedRoots <= spokenSquareRoots(in: source) else { return false }

        let addedProducts = max(0, multiplicationSigns(in: cleaned) - multiplicationSigns(in: source))
        guard addedProducts <= spokenProducts(in: source) else { return false }

        // "Square root of x plus one" does not say whether the radical covers
        // the sum, so a newly parenthesized radicand is a guessed structure
        // unless the speaker grouped it out loud.
        let addedGroupedRoots = count("√(", in: cleaned) - count("√(", in: source)
        if addedGroupedRoots > 0 {
            let lower = source.lowercased()
            let saysGrouping = ["quantity", "parenthes", "bracket", "open paren"].contains { lower.contains($0) }
            guard saysGrouping else { return false }
        }
        return true
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static let squareRootPattern = try! NSRegularExpression(
        pattern: #"\bsquare[\s-]+roots?\b"#,
        options: [.caseInsensitive]
    )

    private static func spokenSquareRoots(in source: String) -> Int {
        squareRootPattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    /// "×", or a standalone x between two operands, such as "5 x 3" or "a x b".
    private static let signPattern = try! NSRegularExpression(
        pattern: #"×|(?<=[\p{L}\p{N})\]])\s+[xX]\s+(?=[\p{L}\p{N}(\[√])"#
    )

    private static func multiplicationSigns(in text: String) -> Int {
        signPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static let spokenProductPattern = try! NSRegularExpression(
        pattern: #"([\p{L}\p{N}.)]+)[\s,]+(?:times|multiplied\s+by)\s+([\p{L}\p{N}(]+)"#,
        options: [.caseInsensitive]
    )

    /// Spoken multiplications whose both neighbours are numbers or single-letter
    /// variables. "Three times a day" and "two times" are not multiplication.
    private static func spokenProducts(in source: String) -> Int {
        let range = NSRange(source.startIndex..., in: source)
        var total = 0
        var searchStart = range.location
        while searchStart < range.upperBound,
              let match = spokenProductPattern.firstMatch(
                  in: source,
                  range: NSRange(location: searchStart, length: range.upperBound - searchStart)
              ),
              let left = Range(match.range(at: 1), in: source),
              let right = Range(match.range(at: 2), in: source) {
            if isOperand(String(source[left])) && isOperand(String(source[right])) {
                total += 1
            }
            // Re-scan from the right operand so "two times three times four" counts twice.
            searchStart = match.range(at: 2).location
        }
        return total
    }

    private static func isOperand(_ raw: String) -> Bool {
        let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".()"))
        guard !word.isEmpty else { return false }
        if word.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        if word.count == 1, let letter = word.first, letter.isLetter {
            // Articles and the pronoun are prose, not variables.
            return !["a", "i"].contains(word.lowercased())
        }
        return SpokenNumberParser.isCardinalWord(word)
    }
}
