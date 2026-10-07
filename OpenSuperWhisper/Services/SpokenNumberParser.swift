import Foundation

/// Finds the numeric values that English number words in a transcript spell
/// out, such as "twenty five" → 25 or "two point five" → 2.5. Cleanup uses the
/// result only to accept a custom filter's digit formatting when the value
/// already exists in the source; unusual phrasings simply yield nothing, so the
/// cleanup guard keeps falling back to the local transcript for them.
enum SpokenNumberParser {
    private enum Kind {
        case none, unit, teen, tens, hundred, scale
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90
    ]

    static func values(in text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }

        var results = Set<String>()
        var segments: [(value: Int, isTwoDigit: Bool, start: Int, end: Int)] = []
        var start: Int?
        var total = 0
        var current = 0
        var kind = Kind.none
        var inNumber = false
        var smallOnly = true

        func flush(at index: Int) {
            guard inNumber else { return }
            let value = total + current
            results.insert(String(value))
            segments.append((value, smallOnly && (10...99).contains(value), start ?? index, index))
            start = nil
            total = 0
            current = 0
            kind = .none
            inNumber = false
            smallOnly = true
        }

        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil

            if let value = units[word] {
                if kind == .tens {
                    current += value
                } else if kind == .unit || kind == .teen {
                    flush(at: index)
                    current = value
                } else {
                    current += value
                }
                kind = .unit
                inNumber = true
            } else if let value = teens[word] {
                if kind == .unit || kind == .teen || kind == .tens { flush(at: index) }
                current += value
                kind = .teen
                inNumber = true
            } else if let value = tens[word] {
                if kind == .unit || kind == .teen || kind == .tens { flush(at: index) }
                current += value
                kind = .tens
                inNumber = true
            } else if word == "hundred" || (word == "a" && next == "hundred") {
                if word == "a" {
                    if inNumber { flush(at: index) }
                    index += 1
                    current = 100
                } else if current >= 100 || kind == .hundred {
                    flush(at: index)
                    current = 100
                } else {
                    current = max(current, 1) * 100
                }
                kind = .hundred
                inNumber = true
                smallOnly = false
            } else if let scale = scales[word] ?? (word == "a" ? next.flatMap { scales[$0] } : nil) {
                if word == "a" {
                    if inNumber { flush(at: index) }
                    index += 1
                    current = 1
                }
                total += max(current, 1) * scale
                current = 0
                kind = .scale
                inNumber = true
                smallOnly = false
            } else if let value = ordinals[word] {
                if kind == .tens, value < 10 {
                    current += value
                } else {
                    if kind == .unit || kind == .teen || kind == .tens { flush(at: index) }
                    current += value
                }
                inNumber = true
                flush(at: index + 1)
            } else if word == "and", inNumber, kind == .hundred || kind == .scale,
                      let next, units[next] != nil || teens[next] != nil || tens[next] != nil {
                // "two hundred and five" stays one number.
            } else if word == "point", inNumber, let next, units[next] != nil {
                let whole = total + current
                var digits = ""
                var cursor = index + 1
                while cursor < words.count, let digit = units[words[cursor]] {
                    digits += String(digit)
                    cursor += 1
                }
                results.insert(String(whole))
                results.insert("\(whole).\(digits)")
                total = 0
                current = 0
                kind = .none
                inNumber = false
                smallOnly = true
                start = nil
                index = cursor
                continue
            } else {
                flush(at: index)
            }
            if inNumber, start == nil { start = index }
            index += 1
        }
        flush(at: index)

        // Spoken years and codes pair two-digit groups: "twenty twenty six" → 2026.
        for (first, second) in zip(segments, segments.dropFirst())
        where first.isTwoDigit && second.isTwoDigit && second.start == first.end {
            results.insert(String(format: "%d%02d", first.value, second.value))
        }
        return results
    }
}
