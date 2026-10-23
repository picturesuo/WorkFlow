import AppKit
import PDFKit
import XCTest
@testable import OpenSuperWhisper

// Every file here is synthetic and written to a temporary directory.

/// Writes a PDF with one text line per drawn row, as a word processor's
/// export lays out wrapped lines.
func writeSyntheticPDF(pages: [[String]], to url: URL, password: String? = nil) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [:]
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password + "-owner"
    }
    let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
    for lines in pages {
        context.beginPDFPage(nil)
        var y: CGFloat = 740
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= 18
        }
        context.endPDFPage()
    }
    context.closePDF()
}

final class DocumentTextExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentTextExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testPDFTextDropsPageNumbersAndRunningHeaders() throws {
        let url = file("notes.pdf")
        try writeSyntheticPDF(pages: [
            ["Course Notes", "The first page says the trails were empty", "every morning in the spring.", "Page 1 of 3"],
            ["Course Notes", "The second page says the library opens", "at eight on weekdays.", "Page 2 of 3"],
            ["Course Notes", "The third page ends here.", "3"]
        ], to: url)

        let text = try DocumentTextExtractor.text(from: url)
        let flat = flattened(text)
        XCTAssertTrue(flat.contains("The first page says the trails were empty every morning in the spring."), text)
        XCTAssertTrue(flat.contains("The second page says the library opens at eight on weekdays."), text)
        XCTAssertTrue(flat.hasSuffix("The third page ends here."), text)
        XCTAssertFalse(text.contains("Course Notes"))
        XCTAssertFalse(text.contains("Page 2"))
    }

    func testPDFRejoinsLineBreakHyphenationOnlyWhenTheWordAppearsElsewhere() throws {
        let url = file("hyphens.pdf")
        try writeSyntheticPDF(pages: [[
            "The optimization was simple, and the opti-",
            "mization kept working for a well-",
            "known reason."
        ]], to: url)

        let flat = flattened(try DocumentTextExtractor.text(from: url))
        XCTAssertTrue(flat.contains("and the optimization kept working"), flat)
        XCTAssertTrue(flat.contains("a well-known reason."), flat)
        XCTAssertFalse(flat.contains("opti-"))
    }

    func testTwoColumnPDFNeverTeachesTheOtherColumnsWords() throws {
        let left = ["The left column talks about running", "in the spring and the trails were", "nearly empty every single morning", "before the heat of the day arrived."]
        let right = ["The right column covers libraries", "which open at eight and fill up", "within an hour on most weekdays", "until the exams finally end."]
        let url = file("columns.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (row, pair) in zip(left, right).enumerated() {
            for (x, line) in [(CGFloat(72), pair.0), (CGFloat(330), pair.1)] {
                context.textPosition = CGPoint(x: x, y: 740 - CGFloat(row) * 16)
                let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 11)])
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
        }
        context.endPDFPage()
        context.closePDF()

        let text = try DocumentTextExtractor.text(from: url)
        // PDFKit reads each column in order here; the aligner's line rule
        // (CorrectionAlignerTests) guards layouts it interleaves.
        XCTAssertTrue(flattened(text).contains(left.joined(separator: " ")), text.debugDescription)
        let dictated = CorrectionCandidate(emitted: "The left column talks about running in the spring and the trails were basically nearly empty every single morning before the heat of the day arrived.")
        let alignment = CorrectionAligner.align(document: text, candidates: [dictated])
        let rightWords = Set(right.joined(separator: " ").lowercased().split(separator: " ").map(String.init))
            .subtracting(["the", "and", "of", "on", "in"])
        for edit in alignment.edits {
            let added = Set(edit.final.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            XCTAssertTrue(added.isDisjoint(with: rightWords), "Learned the other column's words: \(edit.final) from \(text.debugDescription)")
        }
    }

    func testLigaturesAndTypesetCharactersReadAsPlainLetters() {
        XCTAssertEqual(
            DocumentTextExtractor.normalized("An ﬁnal eﬃcient ﬂow\u{00A0}of oﬀers, ﬄuent and ﬀ."),
            "An final efficient flow of offers, ffluent and ff."
        )
    }

    func testScannedAndLockedPDFsExplainWhyTheyCannotBeRead() throws {
        let scanned = file("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(scanned as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.gray.cgColor)
        context.fill(CGRect(x: 72, y: 72, width: 400, height: 600))
        context.endPDFPage()
        context.closePDF()
        XCTAssertThrowsError(try DocumentTextExtractor.text(from: scanned)) { error in
            XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .noText("scan.pdf"))
        }

        let locked = file("locked.pdf")
        try writeSyntheticPDF(pages: [["Private words that need a password."]], to: locked, password: "synthetic")
        XCTAssertThrowsError(try DocumentTextExtractor.text(from: locked)) { error in
            XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .locked("locked.pdf"))
        }

        let broken = file("broken.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        XCTAssertThrowsError(try DocumentTextExtractor.text(from: broken)) { error in
            XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .unreadable("broken.pdf"))
        }
    }

    func testWordRichAndPlainTextFilesYieldTheirText() throws {
        let content = "I kept a notebook of every route; and I wrote down the distance.\n\nThe second paragraph stays separate."
        let attributed = NSAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let range = NSRange(location: 0, length: attributed.length)
        let documents: [(String, NSAttributedString.DocumentType)] = [
            ("essay.docx", .officeOpenXML), ("essay.doc", .docFormat), ("essay.odt", .openDocument), ("essay.rtf", .rtf)
        ]
        for (name, type) in documents {
            let data = try attributed.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: file(name))
            XCTAssertTrue(DocumentTextExtractor.isSupported(file(name)), name)
            XCTAssertEqual(try DocumentTextExtractor.text(from: file(name)), content, name)
        }

        try content.data(using: .utf16)!.write(to: file("essay.txt"))
        XCTAssertEqual(try DocumentTextExtractor.text(from: file("essay.txt")), content)
        try Data(("# Heading\r\n\r\n" + content + "\u{00A0}\u{FEFF}").utf8).write(to: file("essay.md"))
        XCTAssertEqual(try DocumentTextExtractor.text(from: file("essay.md")), "# Heading\n\n" + content)
    }

    func testUnsupportedEmptyAndOversizedFilesAreRefused() throws {
        for name in ["essay.pages", "photo.png", "slides.key"] {
            try Data("synthetic".utf8).write(to: file(name))
            XCTAssertFalse(DocumentTextExtractor.isSupported(file(name)), name)
            XCTAssertThrowsError(try DocumentTextExtractor.text(from: file(name))) { error in
                XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .unsupported(name))
            }
        }

        try Data(" \n\n ".utf8).write(to: file("blank.txt"))
        XCTAssertThrowsError(try DocumentTextExtractor.text(from: file("blank.txt"))) { error in
            XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .noText("blank.txt"))
        }

        let longPDF = file("long.pdf")
        try writeSyntheticPDF(pages: ["alpha", "bravo", "charlie", "delta", "echo"].map { ["The \($0) page of synthetic words keeps going."] }, to: longPDF)
        XCTAssertThrowsError(try DocumentTextExtractor.text(from: longPDF, maximumCharacters: 100)) { error in
            XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .tooLong("long.pdf", limit: 100), "Reading stops early")
        }
        XCTAssertNoThrow(try DocumentTextExtractor.text(from: longPDF, maximumCharacters: 1_000))

        try Data(String(repeating: "words ", count: 10).utf8).write(to: file("long.txt"))
        XCTAssertThrowsError(try DocumentTextExtractor.text(from: file("long.txt"), maximumCharacters: 20)) { error in
            XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .tooLong("long.txt", limit: 20))
        }
        XCTAssertThrowsError(try DocumentTextExtractor.text(from: file("long.txt"), maximumBytes: 20)) { error in
            XCTAssertEqual(error as? DocumentTextExtractor.ExtractionError, .tooLarge("long.txt"))
        }
    }

    func testDroppedFilesReachTheHandlerInsteadOfInsertingTheirPath() throws {
        let url = file("drop.txt")
        try Data("dropped".utf8).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DocumentTextExtractorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        let drag = SyntheticDrag(pasteboard: pasteboard)

        let view = FileDropTextView()
        view.string = "Existing text"
        var dropped: [URL] = []
        var targeted: [Bool] = []
        view.onFileDrop = { dropped = $0 }
        view.onTargetChange = { targeted.append($0) }
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertTrue(view.prepareForDragOperation(drag))
        XCTAssertTrue(view.performDragOperation(drag))
        view.concludeDragOperation(drag)
        XCTAssertEqual(dropped.map(\.standardizedFileURL), [url.standardizedFileURL])
        XCTAssertEqual(view.string, "Existing text", "The file path is never inserted")
        XCTAssertEqual(targeted, [true, false])

        // While the editor is locked (learning or off), a file drop is refused.
        view.onFileDrop = nil
        dropped = []
        XCTAssertEqual(view.draggingEntered(drag), [])
        XCTAssertFalse(view.performDragOperation(drag))
        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(view.string, "Existing text")
    }
}

/// The minimum of a drag session the text view reads.
private final class SyntheticDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
