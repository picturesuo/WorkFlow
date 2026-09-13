import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class TranscriptionCancellationTests: XCTestCase {
    func testCancellingQueuedRequestLeavesActiveDictationRunning() async throws {
        let dictationEntered = expectation(description: "Dictation entered engine")
        let queuedCallerStarted = expectation(description: "Queued caller started")
        let dictationURL = URL(fileURLWithPath: "/fixture/dictation.wav")
        let queuedURL = URL(fileURLWithPath: "/fixture/queued.wav")
        let engine = ControlledTranscriptionEngine { url in
            if url == dictationURL { dictationEntered.fulfill() }
        }
        let service = TranscriptionService(engine: engine)
        let dictationID = UUID()
        let queuedID = UUID()
        let dictation = Task {
            try await service.transcribeAudio(url: dictationURL, settings: Settings(), requestID: dictationID)
        }
        await fulfillment(of: [dictationEntered], timeout: 2)

        let queued = Task {
            queuedCallerStarted.fulfill()
            return try await service.transcribeAudio(url: queuedURL, settings: Settings(), requestID: queuedID)
        }
        await fulfillment(of: [queuedCallerStarted], timeout: 2)

        // These are the same two calls made when History deletes the queued row.
        service.cancelTranscription(requestID: queuedID)
        queued.cancel()
        XCTAssertEqual(engine.cancellationCount, 0)
        XCTAssertEqual(engine.enteredURLs, [dictationURL])
        XCTAssertTrue(service.isTranscribing)

        engine.finish(dictationURL, text: "Dictation preserved")
        let result = try await dictation.value
        XCTAssertEqual(result, "Dictation preserved")
        do {
            _ = try await queued.value
            XCTFail("The cancelled queued caller must not enter the engine")
        } catch is CancellationError {
            // Expected after the serialization wait finishes.
        }
        XCTAssertEqual(engine.enteredURLs, [dictationURL])
        XCTAssertEqual(service.transcribedText, "Dictation preserved")
        XCTAssertFalse(service.isTranscribing)
    }

    func testActiveCancellationRetainsReservationUntilEngineReturns() async throws {
        let firstEntered = expectation(description: "First request entered")
        let secondCallerStarted = expectation(description: "Second caller started")
        let secondEntered = expectation(description: "Second request entered")
        let firstURL = URL(fileURLWithPath: "/fixture/first.wav")
        let secondURL = URL(fileURLWithPath: "/fixture/second.wav")
        let engine = ControlledTranscriptionEngine { url in
            if url == firstURL { firstEntered.fulfill() }
            if url == secondURL { secondEntered.fulfill() }
        }
        let service = TranscriptionService(engine: engine)
        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            try await service.transcribeAudio(url: firstURL, settings: Settings(), requestID: firstID)
        }
        await fulfillment(of: [firstEntered], timeout: 2)
        service.cancelTranscription(requestID: firstID)

        let second = Task {
            secondCallerStarted.fulfill()
            return try await service.transcribeAudio(url: secondURL, settings: Settings(), requestID: secondID)
        }
        await fulfillment(of: [secondCallerStarted], timeout: 2)
        XCTAssertEqual(engine.cancellationCount, 1)
        XCTAssertEqual(engine.enteredURLs, [firstURL])
        XCTAssertTrue(service.isTranscribing, "The cancelled engine has not returned yet")

        engine.finish(firstURL, text: "Discard cancelled result")
        do {
            _ = try await first.value
            XCTFail("Cancelled active work must not publish its result")
        } catch is CancellationError {}

        await fulfillment(of: [secondEntered], timeout: 2)
        XCTAssertTrue(service.isTranscribing, "Old cleanup must not clear the new request")
        service.cancelTranscription(requestID: firstID)
        XCTAssertEqual(engine.cancellationCount, 1, "A stale cancel must not reach the new request's engine")
        engine.finish(secondURL, text: "Second result")
        let result = try await second.value
        XCTAssertEqual(result, "Second result")
        XCTAssertEqual(service.transcribedText, "Second result")
        XCTAssertFalse(service.isTranscribing)
    }
}

/// Exercises TranscriptionService itself. No file, microphone, model, or provider
/// is opened; each engine call returns only when the test releases it.
private final class ControlledTranscriptionEngine: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Controlled fixture"
    private let lock = NSLock()
    private let onEnter: (URL) -> Void
    private var continuations: [URL: CheckedContinuation<String, Error>] = [:]
    private var calls: [URL] = []
    private var cancellations = 0

    init(onEnter: @escaping (URL) -> Void) {
        self.onEnter = onEnter
    }

    var enteredURLs: [URL] { lock.withLock { calls } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                calls.append(url)
                continuations[url] = continuation
            }
            onEnter(url)
        }
    }

    func cancelTranscription() {
        lock.withLock { cancellations += 1 }
    }

    func finish(_ url: URL, text: String) {
        let continuation = lock.withLock { continuations.removeValue(forKey: url) }
        continuation?.resume(returning: text)
    }
}
