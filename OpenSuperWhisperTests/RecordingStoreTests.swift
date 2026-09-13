import Foundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingStoreTests: XCTestCase {
    func testDeleteAllCommitsBeforeCancellingPlaybackAndRemovingAudio() async throws {
        let fixture = try RecordingStoreFixture()
        defer { fixture.removeFiles() }
        let completed = fixture.recording("completed")
        let pending = fixture.recording("pending", status: .pending)
        try await fixture.insertWithAudio(completed)
        try await fixture.insertWithAudio(pending)

        try await fixture.store.deleteAllRecordingsSync()

        let remaining = try await fixture.store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(fixture.cancelledIDs, [pending.id])
        XCTAssertEqual(Set(fixture.stoppedURLs), Set([fixture.url(completed), fixture.url(pending)]))
        XCTAssertEqual(fixture.rowCountsWhenPlaybackStopped, [0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url(completed).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url(pending).path))
    }

    func testFailedBulkDeleteLeavesRowsAudioAndPlaybackUntouched() async throws {
        let fixture = try RecordingStoreFixture()
        defer { fixture.removeFiles() }
        let pending = fixture.recording("keep me", status: .pending)
        try await fixture.insertWithAudio(pending)
        try await fixture.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_fixture_delete BEFORE DELETE ON recordings
                BEGIN SELECT RAISE(ABORT, 'fixture delete failure'); END
                """)
        }

        do {
            try await fixture.store.deleteAllRecordingsSync()
            XCTFail("The transaction should fail")
        } catch {}

        let remaining = try await fixture.store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(remaining.map(\.id), [pending.id])
        XCTAssertEqual(try Data(contentsOf: fixture.url(pending)), Data("fixture audio".utf8))
        XCTAssertTrue(fixture.cancelledIDs.isEmpty)
        XCTAssertTrue(fixture.stoppedURLs.isEmpty)
    }

    func testRetentionStopsOnlyDeletedAudioAndPreservesPendingAndRecentRows() async throws {
        let fixture = try RecordingStoreFixture()
        defer { fixture.removeFiles() }
        let oldDate = Date(timeIntervalSinceNow: -40 * 24 * 60 * 60)
        let old = fixture.recording("old", timestamp: oldDate)
        let pending = fixture.recording("pending", timestamp: oldDate, status: .pending)
        let recent = fixture.recording("recent")
        for recording in [old, pending, recent] {
            try await fixture.insertWithAudio(recording)
        }

        try await fixture.store.deleteRecordings(olderThanDays: 30)

        let remaining = try await fixture.store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(Set(remaining.map(\.id)), Set([pending.id, recent.id]))
        XCTAssertEqual(fixture.stoppedURLs, [fixture.url(old)])
        XCTAssertEqual(fixture.rowCountsWhenPlaybackStopped, [2])
        XCTAssertTrue(fixture.cancelledIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url(old).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url(pending).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url(recent).path))
    }

    func testSingleDeleteUsesCommittedRowStatusForCancellation() async throws {
        let fixture = try RecordingStoreFixture()
        defer { fixture.removeFiles() }
        let staleCompleted = fixture.recording("requeued")
        var pending = staleCompleted
        pending.status = .pending
        try await fixture.insertWithAudio(pending)

        try await fixture.store.deleteRecordingSync(staleCompleted)

        XCTAssertEqual(fixture.cancelledIDs, [pending.id])
        XCTAssertEqual(fixture.stoppedURLs, [fixture.url(pending)])
        let remaining = try await fixture.store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSearchTreatsPercentUnderscoreAndEscapeCharacterLiterally() async throws {
        let fixture = try RecordingStoreFixture()
        defer { fixture.removeFiles() }
        let samples = ["100% complete", "100 dollars", "snake_case", "snakeXcase", "a!b", "aZZb"]
        for text in samples {
            try await fixture.store.addRecordingSync(fixture.recording(text))
        }

        for (query, expected) in [("100%", "100% complete"), ("snake_case", "snake_case"), ("a!b", "a!b")] {
            let asyncResults = try await fixture.store.searchRecordingsAsync(query: query)
            let syncResults = fixture.store.searchRecordings(query: query)
            XCTAssertEqual(asyncResults.map(\.transcription), [expected])
            XCTAssertEqual(syncResults.map(\.transcription), [expected])
        }
        let caseInsensitive = try await fixture.store.searchRecordingsAsync(query: "SNAKE_CASE")
        XCTAssertEqual(caseInsensitive.map(\.transcription), ["snake_case"])
    }
}

@MainActor
private final class RecordingStoreFixture {
    let database: DatabaseQueue
    let directory: URL
    private(set) var store: RecordingStore!
    var cancelledIDs: [UUID] = []
    var stoppedURLs: [URL] = []
    var rowCountsWhenPlaybackStopped: [Int] = []

    init() throws {
        database = try DatabaseQueue(path: ":memory:")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-store-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try RecordingStore(
            database: database,
            recordingsDirectory: directory,
            cancelQueuedRecording: { [weak self] in self?.cancelledIDs.append($0) },
            stopPlayback: { [weak self] urls in
                guard let self else { return }
                self.stoppedURLs.append(contentsOf: urls)
                let count = try? self.database.read { try Recording.fetchCount($0) }
                self.rowCountsWhenPlaybackStopped.append(count ?? -1)
            }
        )
    }

    func recording(_ text: String, timestamp: Date = Date(), status: RecordingStatus = .completed) -> Recording {
        let id = UUID()
        return Recording(
            id: id, timestamp: timestamp, fileName: "\(id).wav", transcription: text,
            duration: 1, status: status, progress: status == .completed ? 1 : 0
        )
    }

    func url(_ recording: Recording) -> URL {
        directory.appendingPathComponent(recording.fileName).standardizedFileURL
    }

    func insertWithAudio(_ recording: Recording) async throws {
        try Data("fixture audio".utf8).write(to: url(recording))
        try await store.addRecordingSync(recording)
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}
