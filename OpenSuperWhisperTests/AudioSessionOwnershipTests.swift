import XCTest
@testable import OpenSuperWhisper

final class AudioSessionOwnershipTests: XCTestCase {
    func testRejectedIndicatorCannotConsumeTheCurrentDictation() {
        let gate = AudioRecordingSessionGate()
        let current = UUID()
        let indicator = UUID()

        XCTAssertTrue(gate.reserve(current))
        XCTAssertFalse(gate.reserve(indicator))
        XCTAssertFalse(gate.isCurrent(indicator))
        XCTAssertFalse(gate.take(ifMatching: indicator))
        XCTAssertTrue(gate.isCurrent(current))
        XCTAssertTrue(gate.take(ifMatching: current))
    }

    func testStaleIndicatorCannotStopOrObserveNewerRecording() {
        let gate = AudioRecordingSessionGate()
        let oldIndicator = UUID()
        let newRecording = UUID()
        XCTAssertTrue(gate.reserve(oldIndicator))
        XCTAssertTrue(gate.take(ifMatching: oldIndicator))
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
        XCTAssertFalse(gate.take(ifMatching: second))
    }

    func testMainWindowStopCannotConsumeTheAssistantSession() {
        let gate = AudioRecordingSessionGate()
        let assistant = UUID()
        let mainWindow = UUID()
        XCTAssertTrue(gate.reserve(assistant))
        XCTAssertFalse(gate.reserve(mainWindow))
        XCTAssertFalse(gate.take(ifMatching: mainWindow))
        XCTAssertTrue(gate.isCurrent(assistant))
        XCTAssertTrue(gate.take(ifMatching: assistant))
    }

    // MARK: Dictating during a meeting

    func testDictationAndMeetingSessionsNeverConsumeEachOther() {
        // The recorder keeps one gate per purpose, so a dictation can start,
        // stop, and cancel while a meeting records.
        let meetingGate = AudioRecordingSessionGate()
        let dictationGate = AudioRecordingSessionGate()
        let meeting = UUID()
        let dictation = UUID()

        XCTAssertTrue(meetingGate.reserve(meeting))
        XCTAssertTrue(dictationGate.reserve(dictation), "Before this change the shortcut was refused for the whole meeting")
        XCTAssertFalse(meetingGate.take(ifMatching: dictation), "Stopping the dictation never stops the meeting")
        XCTAssertTrue(dictationGate.take(ifMatching: dictation))
        XCTAssertTrue(meetingGate.isCurrent(meeting))
        XCTAssertTrue(dictationGate.reserve(UUID()), "The next dictation starts while the meeting still records")
        XCTAssertTrue(meetingGate.take(ifMatching: meeting))
    }

    func testDictationDuringAMeetingKeepsTheMeetingsInput() {
        var lease = SharedInputLease()

        XCTAssertTrue(lease.opensInput, "The meeting chooses the system input")
        lease.acquire()
        XCTAssertFalse(lease.opensInput, "A dictation during the meeting reads the same input")
        lease.acquire()
        XCTAssertFalse(lease.release(), "The dictation ending leaves the meeting's input in place")
        XCTAssertFalse(lease.opensInput)
        XCTAssertTrue(lease.release(), "The meeting ending restores the input")
        XCTAssertTrue(lease.opensInput)
    }

    func testMeetingEndingDuringADictationLeavesTheInputToTheDictation() {
        var lease = SharedInputLease()
        lease.acquire() // meeting
        lease.acquire() // dictation
        XCTAssertFalse(lease.release(), "The meeting stops first; the dictation keeps recording")
        XCTAssertTrue(lease.release(), "The dictation ending restores the input")
    }

    func testDictationStartedDuringAStopTailSharesTheInput() {
        var lease = SharedInputLease()
        lease.acquire() // the previous dictation, still capturing its tail
        XCTAssertFalse(lease.opensInput)
        lease.acquire() // the next dictation
        XCTAssertFalse(lease.release(), "The tail finishing does not restore under the next dictation")
        XCTAssertTrue(lease.release())
    }

    func testExtraReleaseNeverGoesBelowZero() {
        var lease = SharedInputLease()
        XCTAssertTrue(lease.release())
        XCTAssertEqual(lease.holders, 0)
        lease.acquire()
        XCTAssertTrue(lease.release())
        XCTAssertEqual(lease.holders, 0)
    }
}
