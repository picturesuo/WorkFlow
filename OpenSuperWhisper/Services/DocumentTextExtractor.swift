import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Reads the text of a finished document the user drops or chooses for
/// learning. Everything happens on this Mac; the file is never copied or
/// stored, and only the text it yields reaches the learning editor.
enum DocumentTextExtractor {
    static let maximumFileBytes = 50 * 1024 * 1024

    static let wordDocument = UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    static let legacyWordDocument = UTType(importedAs: "com.microsoft.word.doc")
    static let openDocumentText = UTType(importedAs: "org.oasis-open.opendocument.text")

    /// Plain text covers Markdown and other text formats that conform to it.
    static let supportedTypes: [UTType] = [.pdf, wordDocument, legacyWordDocument, openDocumentText, .rtf, .rtfd, .plainText]

    enum ExtractionError: LocalizedError, Equatable {
        case unsupported(String)
        case unreadable(String)
        case tooLarge(String)
        case locked(String)
        case noText(String)
        case tooLong(String, limit: Int)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                "\(name) is not a supported file. Use a PDF, Word, RTF, OpenDocument, or plain text file, or export it as one."
            case .unreadable(let name):
                "\(name) could not be read."
            case .tooLarge(let name):
                "\(name) is larger than \(maximumFileBytes / 1024 / 1024) MB."
            case .locked(let name):
                "\(name) is password-protected. Remove the password or paste its text instead."
            case .noText(let name):
                "\(name) has no selectable text. A scanned PDF holds only images of pages, so paste or export its text instead."
            case .tooLong(let name, let limit):
                "\(name) has more than \(limit.formatted()) characters. Paste only the part you dictated instead."
            }
        }
    }

    static func isSupported(_ url: URL) -> Bool {
        contentType(of: url).map { type in supportedTypes.contains { type.conforms(to: $0) } } ?? false
    }

    /// The document's text, ready to align against History. Reading stops
    /// once the text passes `maximumCharacters`, so a huge file cannot flood
    /// the editor.
    static func text(from url: URL, maximumBytes: Int = maximumFileBytes, maximumCharacters: Int = .max) throws -> String {
        let name = url.lastPathComponent
        guard let type = contentType(of: url), supportedTypes.contains(where: { type.conforms(to: $0) }) else {
            throw ExtractionError.unsupported(name)
        }
        let size = (try? url.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])).flatMap { $0.totalFileSize ?? $0.fileSize }
        if let size, size > maximumBytes { throw ExtractionError.tooLarge(name) }

        let raw: String
        if type.conforms(to: .pdf) {
            raw = try pdfText(url, name: name, maximumCharacters: maximumCharacters)
        } else if type.conforms(to: .plainText) {
            raw = try plainText(url, name: name)
        } else {
            raw = try richText(url, type: type, name: name)
        }
        let text = normalized(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExtractionError.noText(name) }
        guard text.count <= maximumCharacters else { throw ExtractionError.tooLong(name, limit: maximumCharacters) }
        return text
    }

    private static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
    }

    private static func plainText(_ url: URL, name: String) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw ExtractionError.unreadable(name) }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        guard encoding != 0, let converted else { throw ExtractionError.unreadable(name) }
        return converted as String
    }

    private static func richText(_ url: URL, type: UTType, name: String) throws -> String {
        let documentType: NSAttributedString.DocumentType = if type.conforms(to: wordDocument) {
            .officeOpenXML
        } else if type.conforms(to: legacyWordDocument) {
            .docFormat
        } else if type.conforms(to: openDocumentText) {
            .openDocument
        } else if type.conforms(to: .rtfd) {
            .rtfd
        } else {
            .rtf
        }
        guard let text = try? NSAttributedString(
            url: url,
            options: [.documentType: documentType],
            documentAttributes: nil
        ).string else { throw ExtractionError.unreadable(name) }
        return text
    }

    // MARK: - PDF

    private static func pdfText(_ url: URL, name: String, maximumCharacters: Int) throws -> String {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable(name) }
        if document.isLocked, !document.unlock(withPassword: "") { throw ExtractionError.locked(name) }
        var pages: [[String]] = []
        var characters = 0
        for index in 0..<document.pageCount {
            let page = document.page(at: index)?.string ?? ""
            characters += page.count
            guard characters <= maximumCharacters else { throw ExtractionError.tooLong(name, limit: maximumCharacters) }
            pages.append(page
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        return joinedPDFPages(pages)
    }

    /// Joins page lines, dropping page numbers and the running headers and
    /// footers PDF text carries, then rejoins words hyphenated across a line
    /// break so they read as the user wrote them.
    static func joinedPDFPages(_ pages: [[String]]) -> String {
        let repeated = repeatedMargins(pages)
        let lines = pages.flatMap { lines in
            lines.enumerated().filter { index, line in
                let isMargin = index == 0 || index == lines.count - 1
                return !(isMargin && (isPageNumber(line) || repeated.contains(marginKey(line))))
            }.map(\.element)
        }
        return dehyphenated(lines)
    }

    private static func marginKey(_ line: String) -> String {
        line.filter { !$0.isNumber }.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First or last lines that recur, ignoring digits, on at least half of
    /// two or more pages.
    private static func repeatedMargins(_ pages: [[String]]) -> Set<String> {
        guard pages.count >= 2 else { return [] }
        var counts: [String: Int] = [:]
        for lines in pages {
            let margins = Set([lines.first, lines.last].compactMap { $0 }.map(marginKey).filter { !$0.isEmpty })
            for key in margins { counts[key, default: 0] += 1 }
        }
        let needed = max(2, (pages.count + 1) / 2)
        return Set(counts.filter { $0.value >= needed }.map(\.key))
    }

    private static let pageNumberPattern = try! NSRegularExpression(
        pattern: #"^(page\s+)?[-–—]?\s*\d{1,4}\s*[-–—]?(\s+(of|/)\s+\d{1,4})?$"#,
        options: [.caseInsensitive]
    )

    private static func isPageNumber(_ line: String) -> Bool {
        pageNumberPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A word split as "opti-" / "mization" rejoins without the hyphen only
    /// when the document spells it that way elsewhere; otherwise the hyphen
    /// is kept, since documents without hyphenation break lines only at
    /// hyphens the writer typed ("well-" / "known").
    private static func dehyphenated(_ lines: [String]) -> String {
        guard lines.count > 1 else { return lines.joined() }
        let words = Set(lines.joined(separator: " ").lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty })
        var result = lines[0]
        for line in lines.dropFirst() {
            let stem = String(result.dropLast().reversed().prefix { $0.isLetter }.reversed())
            guard result.hasSuffix("-"), !stem.isEmpty, line.first?.isLowercase == true else {
                result += "\n" + line
                continue
            }
            let tail = String(line.prefix { $0.isLetter })
            if words.contains((stem + tail).lowercased()) { result.removeLast() }
            result += line
        }
        return result
    }

    // MARK: - Common

    /// Typeset ligatures a PDF or word processor may store as one character.
    private static let ligatures = ["ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st"]

    /// Removes characters that never appear in a dictation: attachment
    /// placeholders, soft hyphens, ligatures, and nonstandard spaces and
    /// line breaks.
    static func normalized(_ text: String) -> String {
        ligatures.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\u{000C}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
