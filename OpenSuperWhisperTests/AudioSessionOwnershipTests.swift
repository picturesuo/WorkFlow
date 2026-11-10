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

    func testDictationStartsStopsAndCancelsWhileAMeetingRecords() {
        let sessions = RecordingSessionLanes()
        let meeting = UUID()
        let dictation = UUID()

        XCTAssertTrue(sessions.reserve(meeting, for: .meeting))
        XCTAssertTrue(sessions.reserve(dictation, for: .dictation), "The shortcut works for the whole meeting")
        XCTAssertTrue(sessions.owns(meeting))
        XCTAssertTrue(sessions.owns(dictation))

        XCTAssertFalse(sessions.take(ifMatching: dictation, for: .meeting), "Stopping the dictation never stops the meeting")
        XCTAssertTrue(sessions.takeDictationForStop(dictation))
        sessions.dictationStopTailFinished()
        XCTAssertFalse(sessions.owns(dictation))
        XCTAssertTrue(sessions.owns(meeting))

        let next = UUID()
        XCTAssertTrue(sessions.reserve(next, for: .dictation), "The next dictation starts while the meeting still records")
        XCTAssertTrue(sessions.take(ifMatching: next, for: .dictation), "Cancelling it")
        XCTAssertTrue(sessions.owns(meeting), "leaves the meeting recording")
    }

    func testMeetingEndingLeavesTheDictationRecording() {
        let sessions = RecordingSessionLanes()
        let meeting = UUID()
        let dictation = UUID()
        XCTAssertTrue(sessions.reserve(meeting, for: .meeting))
        XCTAssertTrue(sessions.reserve(dictation, for: .dictation))

        XCTAssertFalse(sessions.take(ifMatching: meeting, for: .dictation))
        XCTAssertTrue(sessions.take(ifMatching: meeting, for: .meeting))
        XCTAssertTrue(sessions.owns(dictation))
        XCTAssertTrue(sessions.isCurrent(dictation, for: .dictation))
        XCTAssertFalse(sessions.reserve(UUID(), for: .dictation), "Only one dictation records at a time")
    }

    func testMeetingCannotStartWhileADictationIsActive() {
        let sessions = RecordingSessionLanes()
        let dictation = UUID()
        let meeting = UUID()
        XCTAssertTrue(sessions.reserve(dictation, for: .dictation))

        XCTAssertFalse(sessions.reserve(meeting, for: .meeting), "Starting a meeting during a dictation stays blocked")
        XCTAssertFalse(sessions.owns(meeting))
        XCTAssertTrue(sessions.owns(dictation), "The refused meeting leaves the dictation recording")

        XCTAssertTrue(sessions.take(ifMatching: dictation, for: .dictation))
        XCTAssertTrue(sessions.reserve(meeting, for: .meeting), "A cancelled dictation frees the meeting to start")
    }

    func testMeetingCannotStartDuringADictationsStopTail() {
        let sessions = RecordingSessionLanes()
        let dictation = UUID()
        let meeting = UUID()
        XCTAssertTrue(sessions.reserve(dictation, for: .dictation))
        XCTAssertTrue(sessions.takeDictationForStop(dictation))

        XCTAssertFalse(sessions.reserve(meeting, for: .meeting), "The stopped dictation is still capturing its last word")
        XCTAssertTrue(sessions.reserve(UUID(), for: .dictation), "The next dictation can start during the tail")
        sessions.dictationStopTailFinished()
        XCTAssertFalse(sessions.reserve(meeting, for: .meeting), "That next dictation still blocks the meeting")
    }

    func testMeetingStartsOnceTheDictationsStopTailHasFinished() {
        let sessions = RecordingSessionLanes()
        let dictation = UUID()
        XCTAssertTrue(sessions.reserve(dictation, for: .dictation))
        XCTAssertFalse(sessions.takeDictationForStop(UUID()), "A stale stop holds nothing back")
        XCTAssertTrue(sessions.takeDictationForStop(dictation))
        sessions.dictationStopTailFinished()

        XCTAssertTrue(sessions.reserve(UUID(), for: .meeting))
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
