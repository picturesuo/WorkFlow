import AppKit
import Combine
import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// The History window's cost guarantees: what is measured, published and
/// loaded when it opens and when a search runs.
@MainActor
final class HistoryPerformanceBehaviorTests: XCTestCase {
    // MARK: Window minimum size

    func testWindowMinimumSizeIsConstantAndDoesNotMeasureContent() {
        let counter = MeasureCounter()
        let controller = NSHostingController(rootView: FixedMinimumSizeLayout(
            minimum: CGSize(width: 440, height: 460), ideal: CGSize(width: 560, height: 720)
        ) {
            MeasuringProbe(counter: counter) { Color.clear }
        })

        XCTAssertEqual(controller.sizeThatFits(in: .zero), CGSize(width: 440, height: 460))
        XCTAssertEqual(controller.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)),
                       CGSize(width: 10_000, height: 10_000))
        XCTAssertEqual(counter.count, 0, "The window's size queries never measure the content")
    }

    func testMainWindowMinimumMatchesWhatItsContentNeeds() async throws {
        let minimum = CGSize(width: 440, height: 460)
        let store = try temporaryStore()
        for index in 0..<4 {
            try await store.store.addRecordingSync(row("Row \(index) with a few words in it.", daysAgo: Double(index)))
        }
        defer { store.remove() }
        let pasteboard = NSPasteboard(name: .init("workflow-history-perf-tests"))
        defer { pasteboard.releaseGlobally() }

        for (name, microphone) in [("main window", true), ("permissions", false)] {
            func content(_ model: ContentViewModel) -> some View {
                ContentView(
                    viewModel: model,
                    permissionsManager: PermissionsManager(microphone: microphone, accessibility: true, inputMonitoring: true)
                )
                .environment(\.transcriptPasteboard, pasteboard.name)
            }
            let controller = NSHostingController(rootView: content(ContentViewModel(recordingStore: store.store)))
            XCTAssertEqual(controller.sizeThatFits(in: .zero), minimum, "\(name): the window minimum")

            let model = ContentViewModel(recordingStore: store.store)
            let host = NSHostingView(rootView: content(model))
            host.frame = NSRect(origin: .zero, size: minimum)
            host.layoutSubtreeIfNeeded()
            if microphone {
                let loaded = try await waitUntil { model.recordings.count == 4 }
                XCTAssertTrue(loaded, "\(name): rows load")
            }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            var outside: [String] = []
            var stack = host.subviews
            while let view = stack.popLast() {
                let frame = view.convert(view.bounds, to: host)
                if frame.minX < -0.5 || frame.minY < -0.5
                    || frame.maxX > host.bounds.width + 0.5 || frame.maxY > host.bounds.height + 0.5 {
                    outside.append("\(type(of: view)) \(frame)")
                }
                stack.append(contentsOf: view.subviews)
            }
            XCTAssertEqual(outside, [], "\(name): nothing extends outside the window at its minimum")
        }
    }

    // MARK: Search keeps the list on screen

    func testSearchKeepsPreviousRowsUntilTheNewPageArrives() async {
        let loader = SuspendingHistoryLoader()
        let history = RecordingHistoryModel(loader: loader.load)
        let rows = [row("alpha"), row("bravo"), row("charlie")]
        let firstTask = history.refresh()
        await loader.nextRequest().succeed(rows)
        await firstTask.value
        XCTAssertEqual(history.recordings, rows)

        let searchTask = history.search(query: "x")
        let request = await loader.nextRequest()
        XCTAssertEqual(request.query, "x")
        XCTAssertEqual(history.recordings, rows, "The previous rows stay on screen while the search loads")
        XCTAssertFalse(history.isInitialLoading, "No loading placeholder replaces the list")

        let match = row("x match")
        request.succeed([match])
        await searchTask.value
        XCTAssertEqual(history.recordings, [match])
    }

    func testSearchPublishesNothingUntilItsPageArrives() async {
        let loader = SuspendingHistoryLoader()
        let history = RecordingHistoryModel(loader: loader.load)
        let firstTask = history.refresh()
        await loader.nextRequest().succeed([row("alpha"), row("bravo"), row("charlie")])
        await firstTask.value

        let changes = ChangeCounter(history.objectWillChange)
        let searchTask = history.search(query: "x")
        let request = await loader.nextRequest()
        XCTAssertEqual(changes.count, 0, "A search with rows on screen publishes nothing while it loads")
        request.succeed([row("x match")])
        await searchTask.value
        XCTAssertGreaterThan(changes.count, 0)
        XCTAssertLessThanOrEqual(changes.count, 2, "The new page publishes once per changed property")

        changes.count = 0
        let sameTask = history.search(query: "x m")
        let sameRequest = await loader.nextRequest()
        sameRequest.succeed(history.recordings)
        await sameTask.value
        XCTAssertEqual(changes.count, 0, "An identical page publishes nothing")
    }

    func testFirstLoadStillShowsLoading() async {
        let loader = SuspendingHistoryLoader()
        let history = RecordingHistoryModel(loader: loader.load)
        XCTAssertFalse(history.isInitialLoading)
        let task = history.refresh()
        let request = await loader.nextRequest()
        XCTAssertTrue(history.isInitialLoading, "An empty window shows its loading state")
        XCTAssertFalse(history.isLoadingMore, "The bottom spinner is only for later pages")
        request.succeed([row("alpha")])
        await task.value
        XCTAssertFalse(history.isInitialLoading)
        XCTAssertEqual(history.recordings.count, 1)
    }

    // MARK: History changes stay inside the list

    func testHistoryChangesDoNotInvalidateTheWholeWindowModel() async throws {
        let temporary = try temporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        for (index, text) in ["alpha river", "bravo river", "charlie stone"].enumerated() {
            try await store.addRecordingSync(row(text, daysAgo: Double(index)))
        }
        let viewModel = ContentViewModel(recordingStore: store)
        viewModel.search(query: "")
        let loaded = try await waitUntil { viewModel.recordings.count == 3 }
        XCTAssertTrue(loaded, "The first page loads")

        let changes = ChangeCounter(viewModel.objectWillChange)
        for typed in ["r", "ri", "riv"] { viewModel.search.textChanged(typed) }
        XCTAssertEqual(changes.count, 0, "Typing publishes nothing on the window's view model before the debounce")
        let debounced = try await waitUntil { viewModel.search.debounced == "riv" && viewModel.recordings.count == 2 }
        XCTAssertTrue(debounced, "The debounced query applies")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes.count, 1, "Only the search-active flag changes when the query applies")

        changes.count = 0
        viewModel.search.textChanged("")
        let cleared = try await waitUntil { viewModel.recordings.count == 3 }
        XCTAssertTrue(cleared, "Clearing the field restores History")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes.count, 1, "Clearing the field flips only the search-active flag")

        changes.count = 0
        viewModel.search(query: "river")
        let searched = try await waitUntil { viewModel.recordings.count == 2 }
        XCTAssertTrue(searched, "The search returns its page")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes.count, 0, "History publishes on its own object, not the window's view model")

        viewModel.search(query: "zzzz")
        let emptied = try await waitUntil { viewModel.recordings.isEmpty }
        XCTAssertTrue(emptied, "A search with no match shows no rows")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes.count, 1, "Only the empty flag changes the window's view model")
        withExtendedLifetime(viewModel) {}
    }

    // MARK: Fixtures

    /// An on-disk History in its own temporary folder.
    private func temporaryStore() throws -> (store: RecordingStore, remove: () -> Void) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkFlowHistoryPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = try RecordingStore(
            database: DatabaseQueue(path: scratch.appendingPathComponent("history.sqlite").path),
            recordingsDirectory: scratch.appendingPathComponent("recordings"),
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        return (store, { try? FileManager.default.removeItem(at: scratch) })
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func row(_ text: String, daysAgo: Double = 0) -> Recording {
        Recording(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            fileName: "fixture.wav", transcription: text, duration: 1,
            status: .completed, progress: 1
        )
    }
}

// MARK: - Helpers

/// Counts a publisher's emissions on the main actor.
@MainActor
private final class ChangeCounter {
    var count = 0
    private var subscription: AnyCancellable?

    init<P: Publisher>(_ publisher: P) where P.Failure == Never {
        subscription = publisher.sink { [weak self] _ in self?.count += 1 }
    }
}

/// History pages that arrive only when the test resumes them.
@MainActor
private final class SuspendingHistoryLoader {
    struct Request {
        let query: String
        let limit: Int
        let offset: Int
        let continuation: CheckedContinuation<[Recording], Error>

        func succeed(_ recordings: [Recording]) { continuation.resume(returning: recordings) }
    }

    private var requests: [Request] = []
    private var waiting: CheckedContinuation<Request, Never>?

    func load(query: String, limit: Int, offset: Int) async throws -> [Recording] {
        try await withCheckedThrowingContinuation { continuation in
            let request = Request(query: query, limit: limit, offset: offset, continuation: continuation)
            if let waiting {
                self.waiting = nil
                waiting.resume(returning: request)
            } else {
                requests.append(request)
            }
        }
    }

    func nextRequest() async -> Request {
        if !requests.isEmpty { return requests.removeFirst() }
        return await withCheckedContinuation { waiting = $0 }
    }
}

private final class MeasureCounter {
    var count = 0
}

/// A layout that counts how often SwiftUI measures it.
private struct MeasuringProbe: Layout {
    let counter: MeasureCounter

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        counter.count += 1
        return CGSize(width: 100, height: 100)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
