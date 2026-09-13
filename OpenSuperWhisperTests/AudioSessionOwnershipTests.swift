import XCTest
@testable import OpenSuperWhisper

final class AudioSessionOwnershipTests: XCTestCase {
    func testRejectedIndicatorCannotConsumeMeetingSession() {
        let gate = AudioRecordingSessionGate()
        let meeting = UUID()
        let indicator = UUID()

        XCTAssertTrue(gate.reserve(meeting))
        XCTAssertFalse(gate.reserve(indicator))
        XCTAssertFalse(gate.isCurrent(indicator))
        XCTAssertFalse(gate.take(ifMatching: indicator))
        XCTAssertTrue(gate.isCurrent(meeting))
        XCTAssertTrue(gate.take(ifMatching: meeting))
    }

    func testStaleIndicatorCannotStopOrObserveNewerRecording() {
        let gate = AudioRecordingSessionGate()
        let oldIndicator = UUID()
        let newRecording = UUID()
        XCTAssertTrue(gate.reserve(oldIndicator))
        // The main-window Stop intentionally addresses the active recorder.
        XCTAssertTrue(gate.take(ifMatching: nil))
        XCTAssertTrue(gate.reserve(newRecording))

        XCTAssertFalse(gate.isCurrent(oldIndicator))
        XCTAssertFalse(gate.take(ifMatching: oldIndicator))
        XCTAssertTrue(gate.isCurrent(newRecording))
        XCTAssertTrue(gate.take(ifMatching: newRecording))
    }

    func testStopConsumesOwnershipBeforeAnotherSessionStarts() {
        let gate = AudioRecordingSessionGate()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(gate.reserve(first))
        XCTAssertTrue(gate.take(ifMatching: first))
        XCTAssertTrue(gate.reserve(second))
        // Duplicate stop/cancel arriving during the old session's tail is inert.
        XCTAssertFalse(gate.take(ifMatching: first))
        XCTAssertFalse(gate.reserve(UUID()))
        XCTAssertTrue(gate.take(ifMatching: second))
        XCTAssertFalse(gate.take(ifMatching: nil))
    }
}
