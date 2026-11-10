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

    // MARK: Fixtures

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
