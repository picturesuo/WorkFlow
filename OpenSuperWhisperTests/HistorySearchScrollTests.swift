import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Where the History list stands when a new query's results arrive. Each
/// window is hosted the way the app shows it but never ordered in, so
/// nothing appears on screen.
@MainActor
final class HistorySearchScrollTests: XCTestCase {
    /// The results start at the top of the list, so the first day header and
    /// the first result's first line are fully visible, whether the list was
    /// scrolled down or already at its top when the search ran.
    func testSearchResultsStartAtTheTopOfTheList() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkFlowHistorySearchScroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let database = try DatabaseQueue()
        let store = try RecordingStore(
            database: database, recordingsDirectory: scratch,
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        // 36 rows over 3 days, enough to scroll; every third one mentions the review.
        let rows: [Recording] = (0..<36).map { (index: Int) -> Recording in
            let day = Double(index / 12)
            let minute = Double(index % 12)
            let seconds: TimeInterval = 1_800_000_000 - day * 86_400 - minute * 600
            let text = index % 3 == 1
                ? "Row \(index): notes for the quarterly review of the garden plan."
                : "Row \(index): notes about the garden plan and the shared tool shed."
            return Recording(
                id: UUID(), timestamp: Date(timeIntervalSince1970: seconds), fileName: "fixture-\(index).wav",
                transcription: text, duration: 4, status: .completed, progress: 1
            )
        }
        try database.write { db in
            for row in rows { try row.insert(db) }
        }
        let pasteboard = NSPasteboard(name: .init("workflow-history-search-scroll-tests"))
        defer { pasteboard.releaseGlobally() }

        for scrolledDown: CGFloat in [300, 0] {
            let offset = try offsetAfterSearch(store: store, rowCount: rows.count, scrolledDown: scrolledDown,
                                               query: "review", matches: 12, pasteboard: pasteboard.name)
            XCTAssertEqual(offset, 0, accuracy: 0.5,
                           "Searching with the list \(scrolledDown) pt down: the results must start at the top, "
                           + "but the list is scrolled \(offset) pt down, under the pinned day header")
        }
    }

    // MARK: Helpers

    /// Opens History over `store` at 440 x 500, scrolls the list down by
    /// `scrolledDown`, applies `query`, and returns the list's vertical
    /// offset once the results are laid out.
    private func offsetAfterSearch(store: RecordingStore, rowCount: Int, scrolledDown: CGFloat, query: String,
                                   matches: Int, pasteboard: NSPasteboard.Name) throws -> CGFloat {
        let model = ContentViewModel(recordingStore: store)
        let size = CGSize(width: 440, height: 500)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        let host = NSHostingView(rootView: ContentView(
            viewModel: model,
            permissionsManager: PermissionsManager(microphone: true, accessibility: true, inputMonitoring: true)
        )
        .environment(\.transcriptPasteboard, pasteboard))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer {
            window.contentView = nil
            window.close()
            settle(host, for: 0.1)
        }

        settle(host) { model.recordings.count == rowCount && !model.history.isInitialLoading }
        XCTAssertEqual(model.recordings.count, rowCount, "History loads every row")
        let list = try XCTUnwrap(historyScrollView(in: host), "The History list scrolls")
        XCTAssertEqual(list.contentView.bounds.minY, 0, accuracy: 0.5, "History opens at its top")
        if scrolledDown > 0 {
            list.contentView.scroll(to: NSPoint(x: list.contentView.bounds.minX, y: scrolledDown))
            list.reflectScrolledClipView(list.contentView)
            settle(host)
            XCTAssertGreaterThan(list.contentView.bounds.minY, 0, "The list is scrolled down before the search")
        }

        model.search.textChanged(query)
        settle(host) { model.history.shownQuery == query }
        XCTAssertEqual(model.history.shownQuery, query, "The search's results arrive")
        XCTAssertEqual(model.recordings.count, matches, "The query's rows are shown")
        settle(host)  // one more layout pass after the results apply

        return try XCTUnwrap(historyScrollView(in: host), "The results scroll").contentView.bounds.minY
    }

    /// Runs the main run loop, laying out after each turn, until `condition`
    /// holds or `timeout` passes, then for `seconds` more.
    private func settle(_ host: NSView, for seconds: TimeInterval = 0.3, timeout: TimeInterval = 5,
                        until condition: () -> Bool = { true }) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        } while !condition() && Date() < deadline
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    /// The History list's scroll view: the tallest scrolling document that is
    /// not a text view.
    private func historyScrollView(in root: NSView) -> NSScrollView? {
        var views: [NSView] = [root]
        var scrollViews: [NSScrollView] = []
        while let view = views.popLast() {
            if let scrollView = view as? NSScrollView, !(scrollView.documentView is NSTextView) {
                scrollViews.append(scrollView)
            }
            views.append(contentsOf: view.subviews)
        }
        return scrollViews.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}
