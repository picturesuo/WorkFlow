import Foundation

struct SpokenNumbers: Equatable {
    /// Numeric values the words spell out, such as "25", "2.5", "1984", and
    /// unambiguous clock forms such as "5:30" or "5:00". A digit spoken as
    /// part of a sequence, or the whole part of a decimal, is not a value of
    /// its own.
    var values: Set<String> = []
    /// Contiguous runs of single digit words in spoken order, such as
    /// "four seven two one" → "4721". Codes and phone numbers keep their digit
    /// order, so a reordered form never matches, even one digit per group.
    var digitSequences: Set<String> = []
}

/// Finds the numbers that English number words in a transcript spell out.
/// Cleanup uses the result only to accept a custom filter's digit formatting
/// when the value already exists in the source; unusual phrasings simply yield
/// nothing, so the cleanup guard keeps falling back to the local transcript
/// for them.
enum SpokenNumberParser {
    private enum Kind {
        case none, unit, teen, tens, hundred, scale
    }

    private struct Segment {
        let value: Int
        let smallOnly: Bool
        let start: Int
        let end: Int

        var isTwoDigit: Bool { smallOnly && (10...99).contains(value) }
        var isDigit: Bool { smallOnly && value < 10 && end - start == 1 }
        var isHour: Bool { smallOnly && (1...23).contains(value) }
    }

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
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

    static func parse(_ text: String) -> SpokenNumbers {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }

        var numbers = SpokenNumbers()
        var segments: [Segment] = []
        var start: Int?
        var total = 0
        var current = 0
        var kind = Kind.none
        var inNumber = false
        var smallOnly = true

        func flush(at index: Int) {
            guard inNumber else { return }
            segments.append(Segment(value: total + current, smallOnly: smallOnly, start: start ?? index, end: index))
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
                if digits.allSatisfy({ $0 == "0" }) { numbers.values.insert(String(whole)) }
                numbers.values.insert("\(whole).\(digits)")
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

        var runMembers = Set<Int>()
        var run: [Int] = []
        func closeRun() {
            if run.count > 1 {
                numbers.digitSequences.insert(run.map { String(segments[$0].value) }.joined())
                runMembers.formUnion(run)
            }
            run = []
        }
        for (offset, segment) in segments.enumerated() {
            if segment.isDigit, let last = run.last, segments[last].end == segment.start {
                run.append(offset)
            } else {
                closeRun()
                // A leading "oh" is the interjection ("oh, five chairs"), not a digit.
                if segment.isDigit, words[segment.start] != "oh" { run = [offset] }
            }
        }
        closeRun()

        for (offset, segment) in segments.enumerated() where !runMembers.contains(offset) {
            numbers.values.insert(String(segment.value))
        }

        for (first, second) in zip(segments, segments.dropFirst()) where second.start == first.end {
            // Spoken years and codes pair two-digit groups: "twenty twenty six" → 2026.
            if first.isTwoDigit, second.isTwoDigit {
                numbers.values.insert(String(format: "%d%02d", first.value, second.value))
            }
            // "five thirty" → 5:30.
            if first.isHour, second.isTwoDigit, second.value < 60 {
                numbers.values.insert(String(format: "%d:%02d", first.value, second.value))
            }
        }

        for (offset, hour) in segments.enumerated() where hour.isHour {
            // "five o'clock" → 5:00.
            if hour.end < words.count,
               words[hour.end] == "oclock" || (words[hour.end] == "o" && hour.end + 1 < words.count && words[hour.end + 1] == "clock") {
                numbers.values.insert(String(format: "%d:00", hour.value))
            }
            // "five oh five" → 5:05.
            if offset + 2 < segments.count {
                let zero = segments[offset + 1]
                let minute = segments[offset + 2]
                if zero.isDigit, zero.value == 0, zero.start == hour.end, minute.isDigit, minute.start == zero.end {
                    numbers.values.insert(String(format: "%d:0%d", hour.value, minute.value))
                }
            }
        }

        return numbers
    }
}
