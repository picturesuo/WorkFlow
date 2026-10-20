import Foundation

struct SpokenNumbers: Equatable {
    /// Numeric values the words spell out, such as "25", "2.5", "1984", and
    /// clock forms such as "5:30" or "5:00". Punctuation between words ends a
    /// number. A digit word inside a run of digit words, and the whole part of
    /// a spoken decimal, are not values of their own.
    var values: Set<String> = []
    /// Runs of single digit words separated only by spaces, in spoken order,
    /// such as "four seven two one" → "4721" or "oh two one" → "021". Only the
    /// complete run matches.
    var digitSequences: Set<String> = []
}

/// One spoken number in the text: where it is and every digit form that
/// writes it, such as "twenty" in "twenty twenty six" → ["20", "2026"].
struct SpokenNumberOccurrence: Equatable {
    let range: Range<String.Index>
    let words: [String]
    let values: Set<String>
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
        /// The first word, which `start` misses for a number that is only an
        /// ordinal ("third"); `start` keeps its role in digit runs.
        let firstWord: Int

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

    /// The digit a single number word stands for ("three" → "3", "oh" → "0").
    static func digit(forWord word: String) -> String? {
        units[word.lowercased()].map(String.init)
    }

    /// Whether a single word is a cardinal number word ("seven", "twenty", "hundred").
    static func isCardinalWord(_ word: String) -> Bool {
        let word = word.lowercased()
        return units[word] != nil || teens[word] != nil || tens[word] != nil
            || scales[word] != nil || word == "hundred"
    }

    static func parse(_ text: String) -> SpokenNumbers {
        analyze(text).numbers
    }

    /// Each spoken number with its position, for checks that a rewrite keeps
    /// every number the speaker said.
    static func occurrences(in text: String) -> [SpokenNumberOccurrence] {
        analyze(text).occurrences
    }

    private static func analyze(_ text: String) -> (numbers: SpokenNumbers, occurrences: [SpokenNumberOccurrence]) {
        var words: [String] = []
        var wordRanges: [Range<String.Index>] = []
        var boundaryBefore: [Bool] = []
        var word = ""
        var wordStart = text.startIndex
        var pendingBoundary = false
        var position = text.startIndex
        while position < text.endIndex {
            let character = text[position]
            if character.isLetter {
                if word.isEmpty { wordStart = position }
                word += character.lowercased()
            } else {
                if !word.isEmpty {
                    words.append(word)
                    wordRanges.append(wordStart..<position)
                    boundaryBefore.append(pendingBoundary)
                    word = ""
                    pendingBoundary = false
                }
                if !character.isWhitespace, !"-'’".contains(character) { pendingBoundary = true }
            }
            position = text.index(after: position)
        }
        if !word.isEmpty {
            words.append(word)
            wordRanges.append(wordStart..<text.endIndex)
            boundaryBefore.append(pendingBoundary)
        }
        func adjacent(_ first: Segment, _ second: Segment) -> Bool {
            second.start == first.end && !boundaryBefore[second.start]
        }

        var numbers = SpokenNumbers()
        var segments: [Segment] = []
        var decimals: [(start: Int, end: Int, value: String)] = []
        var start: Int?
        var total = 0
        var current = 0
        var kind = Kind.none
        var inNumber = false
        var smallOnly = true

        func flush(at index: Int) {
            guard inNumber else { return }
            segments.append(Segment(
                value: total + current,
                smallOnly: smallOnly,
                start: start ?? index,
                end: index,
                firstWord: start ?? max(0, index - 1)
            ))
            start = nil
            total = 0
            current = 0
            kind = .none
            inNumber = false
            smallOnly = true
        }

        var index = 0
        while index < words.count {
            if boundaryBefore[index] { flush(at: index) }
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
                while cursor < words.count, !boundaryBefore[cursor], let digit = units[words[cursor]] {
                    digits += String(digit)
                    cursor += 1
                }
                numbers.values.insert("\(whole).\(digits)")
                decimals.append((start: start ?? index, end: cursor, value: "\(whole).\(digits)"))
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

        // Every digit form of each segment, and of each digit run, in order.
        var forms = segments.map { Set([String($0.value)]) }
        var runs: [(members: [Int], value: String)] = []
        var runMembers = Set<Int>()
        var run: [Int] = []
        func closeRun() {
            if run.count > 1 {
                let value = run.map { String(segments[$0].value) }.joined()
                numbers.digitSequences.insert(value)
                runMembers.formUnion(run)
                runs.append((members: run, value: value))
            }
            run = []
        }
        for (offset, segment) in segments.enumerated() {
            if segment.isDigit, let last = run.last, adjacent(segments[last], segment) {
                run.append(offset)
            } else {
                closeRun()
                if segment.isDigit { run = [offset] }
            }
        }
        closeRun()

        for (offset, segment) in segments.enumerated() where !runMembers.contains(offset) {
            numbers.values.insert(String(segment.value))
        }

        func addForm(_ value: String, to members: [Int]) {
            numbers.values.insert(value)
            for member in members { forms[member].insert(value) }
        }

        for offset in segments.indices.dropLast() where adjacent(segments[offset], segments[offset + 1]) {
            let first = segments[offset]
            let second = segments[offset + 1]
            // Spoken years and codes pair two-digit groups: "twenty twenty six" → 2026.
            if first.isTwoDigit, second.isTwoDigit {
                addForm(String(format: "%d%02d", first.value, second.value), to: [offset, offset + 1])
            }
            // "five thirty" → 5:30.
            if first.isHour, second.isTwoDigit, second.value < 60 {
                addForm(String(format: "%d:%02d", first.value, second.value), to: [offset, offset + 1])
            }
        }

        for (offset, hour) in segments.enumerated() where hour.isHour {
            // "five o'clock" → 5:00.
            if hour.end < words.count, !boundaryBefore[hour.end],
               words[hour.end] == "oclock" || (words[hour.end] == "o" && hour.end + 1 < words.count && words[hour.end + 1] == "clock") {
                addForm(String(format: "%d:00", hour.value), to: [offset])
            }
            // "five oh five" → 5:05.
            if offset + 2 < segments.count {
                let zero = segments[offset + 1]
                let minute = segments[offset + 2]
                if zero.isDigit, zero.value == 0, adjacent(hour, zero), minute.isDigit, adjacent(zero, minute) {
                    addForm(String(format: "%d:0%d", hour.value, minute.value), to: [offset, offset + 1, offset + 2])
                }
            }
        }

        func occurrence(_ start: Int, _ end: Int, _ values: Set<String>) -> SpokenNumberOccurrence {
            SpokenNumberOccurrence(
                range: wordRanges[start].lowerBound..<wordRanges[end - 1].upperBound,
                words: Array(words[start..<end]),
                values: values
            )
        }
        var occurrences = segments.indices.filter { !runMembers.contains($0) }.map {
            occurrence(segments[$0].firstWord, segments[$0].end, forms[$0])
        }
        for run in runs {
            // A run also counts as written in a combined form, such as "five
            // oh five" → 5:05, but never as one of its single digits.
            var values: Set<String> = [run.value]
            for member in run.members {
                values.formUnion(forms[member].subtracting([String(segments[member].value)]))
            }
            let first = segments[run.members[0]]
            let last = segments[run.members[run.members.count - 1]]
            occurrences.append(occurrence(first.firstWord, last.end, values))
        }
        for decimal in decimals {
            occurrences.append(occurrence(decimal.start, decimal.end, [decimal.value]))
        }
        occurrences.sort { $0.range.lowerBound < $1.range.lowerBound }
        return (numbers, occurrences)
    }
}
