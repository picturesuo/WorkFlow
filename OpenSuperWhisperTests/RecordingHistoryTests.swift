import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingHistoryTests: XCTestCase {
    func testNewSearchStartsWhileOldRequestIsRunningAndIgnoresItsCompletion() async {
        let loader = ControlledHistoryLoader()
        let history = RecordingHistoryModel(loader: loader.load)
        let oldTask = history.search(query: "old")
        let oldRequest = await loader.nextRequest()
        let newTask = history.search(query: "new")
        let newRequest = await loader.nextRequest()

        XCTAssertEqual(newRequest.query, "new")
        XCTAssertEqual(newRequest.offset, 0)
        oldRequest.succeed([recording("old result")])
        await oldTask.value
        XCTAssertTrue(history.recordings.isEmpty)
        XCTAssertTrue(history.isLoadingMore)

        let expected = recording("new result")
        newRequest.succeed([expected])
        await newTask.value
        XCTAssertEqual(history.recordings, [expected])
        XCTAssertFalse(history.isLoadingMore)
    }

    func testSameQueryRefreshCannotBeOverwrittenByEarlierResponse() async {
        let loader = ControlledHistoryLoader()
        let history = RecordingHistoryModel(loader: loader.load)
        let oldTask = history.search(query: "same")
        let oldRequest = await loader.nextRequest()
        let refreshTask = history.refresh()
        let refreshRequest = await loader.nextRequest()
        let latest = recording("latest")

        refreshRequest.succeed([latest])
        await refreshTask.value
        oldRequest.succeed([recording("obsolete")])
        await oldTask.value

        XCTAssertEqual(history.query, "same")
        XCTAssertEqual(history.recordings, [latest])
        XCTAssertFalse(history.isLoadingMore)
        XCTAssertNil(history.errorMessage)
    }

    func testRefreshPreservesSearchAndVisibleResultsUntilReplacementArrives() async {
        let loader = ControlledHistoryLoader()
        let history = RecordingHistoryModel(loader: loader.load)
        let initialTask = history.search(query: "project")
        let initialRequest = await loader.nextRequest()
        let original = recording("project original")
        initialRequest.succeed([original])
        await initialTask.value

        let refreshTask = history.refresh()
        let refreshRequest = await loader.nextRequest()
        XCTAssertEqual(refreshRequest.query, "project")
        XCTAssertEqual(refreshRequest.offset, 0)
        XCTAssertEqual(history.recordings, [original])
        XCTAssertTrue(history.isLoadingMore)

        let updated = recording("project updated")
        refreshRequest.succeed([updated])
        await refreshTask.value
        XCTAssertEqual(history.recordings, [updated])
        XCTAssertEqual(history.query, "project")
    }

    func testFailedPageClearsSpinnerAndRetriesSameOffsetWithoutLosingRows() async throws {
        let loader = ControlledHistoryLoader()
        let history = RecordingHistoryModel(pageSize: 2, loader: loader.load)
        let initialTask = history.refresh()
        let initialRequest = await loader.nextRequest()
        let firstPage = [recording("first"), recording("second")]
        initialRequest.succeed(firstPage)
        await initialTask.value

        let pageTask = try XCTUnwrap(history.loadMore())
        let pageRequest = await loader.nextRequest()
        XCTAssertEqual(pageRequest.offset, 2)
        XCTAssertEqual(pageRequest.limit, 2)
        XCTAssertNil(history.loadMore(), "Concurrent pagination must not duplicate a page")
        pageRequest.fail()
        await pageTask.value

        XCTAssertFalse(history.isLoadingMore)
        XCTAssertNotNil(history.errorMessage)
        XCTAssertEqual(history.recordings, firstPage)
        XCTAssertTrue(history.canLoadMore)

        let retryTask = try XCTUnwrap(history.loadMore())
        let retryRequest = await loader.nextRequest()
        XCTAssertEqual(retryRequest.offset, 2)
        XCTAssertNil(history.errorMessage)
        let last = recording("third")
        retryRequest.succeed([last])
        await retryTask.value

        XCTAssertEqual(history.recordings, firstPage + [last])
        XCTAssertFalse(history.isLoadingMore)
        XCTAssertFalse(history.canLoadMore)
        XCTAssertNil(history.loadMore())
    }

    func testInitialFailureCanRetryAndObsoleteFailureCannotReplaceSuccess() async throws {
        let loader = ControlledHistoryLoader()
        let history = RecordingHistoryModel(loader: loader.load)
        let initialTask = history.refresh()
        let initialRequest = await loader.nextRequest()
        initialRequest.fail()
        await initialTask.value
        XCTAssertFalse(history.isLoadingMore)
        XCTAssertNotNil(history.errorMessage)

        let retryTask = try XCTUnwrap(history.loadMore())
        let retryRequest = await loader.nextRequest()
        XCTAssertEqual(retryRequest.offset, 0)
        let searchTask = history.search(query: "current")
        let searchRequest = await loader.nextRequest()
        let expected = recording("current result")
        searchRequest.succeed([expected])
        await searchTask.value
        retryRequest.fail()
        await retryTask.value

        XCTAssertEqual(history.recordings, [expected])
        XCTAssertNil(history.errorMessage)
        XCTAssertFalse(history.isLoadingMore)
    }

    private func recording(_ text: String) -> Recording {
        Recording(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1),
            fileName: "fixture.wav", transcription: text, duration: 1,
            status: .completed, progress: 1
        )
    }

    func testRefreshKeepsLoadedDepthAndPaginationContinuesWithoutDuplicates() async throws {
        let loader = ControlledHistoryLoader()
        let history = RecordingHistoryModel(pageSize: 2, loader: loader.load)
        let first = [recording("one"), recording("two")]
        let second = [recording("three"), recording("four")]
        let firstTask = history.refresh()
        let firstRequest = await loader.nextRequest()
        firstRequest.succeed(first)
        await firstTask.value
        let secondTask = try XCTUnwrap(history.loadMore())
        let secondRequest = await loader.nextRequest()
        secondRequest.succeed(second)
        await secondTask.value

        let refreshTask = history.refresh()
        let refreshRequest = await loader.nextRequest()
        XCTAssertEqual(refreshRequest.offset, 0)
        XCTAssertEqual(refreshRequest.limit, 4, "A background completion must not drop the second page")
        XCTAssertEqual(history.recordings, first + second)
        refreshRequest.succeed(first + second)
        await refreshTask.value
        XCTAssertEqual(history.recordings, first + second)

        let nextTask = try XCTUnwrap(history.loadMore())
        let nextRequest = await loader.nextRequest()
        XCTAssertEqual(nextRequest.offset, 4)
        XCTAssertEqual(nextRequest.limit, 2)
        let last = recording("five")
        nextRequest.succeed([last])
        await nextTask.value
        XCTAssertEqual(history.recordings, first + second + [last])
        XCTAssertEqual(Set(history.recordings.map(\.id)).count, 5)
        XCTAssertFalse(history.canLoadMore)

        let searchTask = history.search(query: "new query")
        let searchRequest = await loader.nextRequest()
        XCTAssertEqual(searchRequest.offset, 0)
        XCTAssertEqual(searchRequest.limit, 2, "A new search starts at the normal page size")
        searchRequest.succeed([])
        await searchTask.value
    }

}

/// Requests complete only when the test decides, including after cancellation.
/// This exercises stale database completions without sleeps or real user data.
@MainActor
private final class ControlledHistoryLoader {
    struct Request {
        let query: String
        let limit: Int
        let offset: Int
        let continuation: CheckedContinuation<[Recording], Error>

        func succeed(_ recordings: [Recording]) {
            continuation.resume(returning: recordings)
        }

        func fail() {
            continuation.resume(throwing: LoadFailure())
        }
    }

    private struct LoadFailure: Error {}
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
        if !requests.isEmpty {
            return requests.removeFirst()
        }
        return await withCheckedContinuation { waiting = $0 }
    }
}
