import XCTest
@testable import OpenSuperWhisper

/// Hold to talk, release, and press again within the 0.25 s stop tail: the
/// newer dictation starts before the older one reaches the engine, which
/// retires the older one, and it is released while the older one is still
/// transcribing. No microphone or recorder session is opened.
@MainActor
final class LatestDictationDeliveryTests: XCTestCase {
    func testDictationStoppedWhileAnOlderOneTranscribesIsDecodedNotQueued() async throws {
        let olderEntered = expectation(description: "Older dictation entered the engine")
        let olderURL = URL(fileURLWithPath: "/fixture/older.wav")
        let engine = ControlledTranscriptionEngine { url in
            if url == olderURL { olderEntered.fulfill() }
        }
        let service = TranscriptionService(engine: engine)
        let older = Task { try await service.transcribeAudio(url: olderURL, settings: Settings()) }
        await fulfillment(of: [olderEntered], timeout: 2)
        XCTAssertTrue(service.isTranscribing)

        let newer = IndicatorViewModel(latestDictationGate: LatestDictationGate(), transcriptionService: service)
        newer.state = .recording
        newer.recorderSessionID = UUID()
        newer.startDecoding()

        // Queueing shows "Processing..." and never pastes the newest words.
        XCTAssertEqual(newer.state, .decoding)
        engine.finish(olderURL, text: "older")
        _ = try await older.value
        newer.cleanup()
    }

    func testSerializedTranscriptionDeliversOnlyTheNewestDictation() async throws {
        let olderEntered = expectation(description: "Older dictation entered the engine")
        let newerWaiting = expectation(description: "Newer dictation is waiting for the engine")
        let newerEntered = expectation(description: "Newer dictation entered the engine")
        let olderURL = URL(fileURLWithPath: "/fixture/older.wav")
        let newerURL = URL(fileURLWithPath: "/fixture/newer.wav")
        let engine = ControlledTranscriptionEngine { url in
            if url == olderURL { olderEntered.fulfill() }
            if url == newerURL { newerEntered.fulfill() }
        }
        let service = TranscriptionService(engine: engine)
        let gate = LatestDictationGate()

        let olderGeneration = gate.begin()
        let older = Task { try await service.transcribeAudio(url: olderURL, settings: Settings()) }
        await fulfillment(of: [olderEntered], timeout: 2)
        let newerGeneration = gate.begin()
        let newer = Task {
            newerWaiting.fulfill()
            return try await service.transcribeAudio(url: newerURL, settings: Settings())
        }
        await fulfillment(of: [newerWaiting], timeout: 2)
        XCTAssertEqual(engine.enteredURLs, [olderURL], "The newer dictation waits instead of sharing the engine")

        var pasted: [String] = []
        engine.finish(olderURL, text: "older words")
        let olderText = try await older.value
        if gate.claimIfCurrent(olderGeneration) { pasted.append(olderText) }
        await fulfillment(of: [newerEntered], timeout: 2)
        engine.finish(newerURL, text: "newer words")
        let newerText = try await newer.value
        for _ in 0..<2 where gate.claimIfCurrent(newerGeneration) { pasted.append(newerText) }

        XCTAssertEqual(pasted, ["newer words"])
        XCTAssertEqual(engine.enteredURLs, [olderURL, newerURL])
        XCTAssertFalse(service.isTranscribing)
    }
}
