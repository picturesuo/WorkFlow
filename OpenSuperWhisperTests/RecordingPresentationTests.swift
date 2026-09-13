import Combine
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingPresentationTests: XCTestCase {
    func testCancelledMicrophoneConnectionReturnsToIdle() {
        let model = ContentViewModel()
        model.updateRecorderState(isRecording: false, isConnecting: true)
        XCTAssertEqual(model.state, .connecting)

        model.updateRecorderState(isRecording: false, isConnecting: false)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.recordingStartedAt)
    }

    func testRepeatedRecorderEventsDoNotRestartClockOrInvalidateHistory() throws {
        let model = ContentViewModel()
        model.updateRecorderState(isRecording: true, isConnecting: false)
        let startedAt = try XCTUnwrap(model.recordingStartedAt)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }

        for _ in 0..<100 {
            model.updateRecorderState(isRecording: true, isConnecting: false)
        }
        XCTAssertEqual(model.recordingStartedAt, startedAt)
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(subscription) {}

        model.updateRecorderState(isRecording: false, isConnecting: false)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.recordingStartedAt)
    }

    func testLateRecorderEventsDoNotDismissDecodingState() {
        let model = ContentViewModel()
        model.state = .decoding
        model.updateRecorderState(isRecording: false, isConnecting: false)
        model.updateRecorderState(isRecording: true, isConnecting: false)
        XCTAssertEqual(model.state, .decoding)
        XCTAssertNil(model.recordingStartedAt)
    }
}
