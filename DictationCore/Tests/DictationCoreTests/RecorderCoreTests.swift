import DictationCore
import XCTest

final class RecorderCoreTests: XCTestCase {
    typealias S = RecorderCore.State
    typealias E = RecorderCore.Effect

    let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let idle = E.publish(isRecording: false, isConnecting: false)

    private func state(owner: UUID? = nil, _ phase: RecorderCore.Phase = .idle, detached: [UUID: RecorderCore.Detached] = [:], notifiedEnded: Bool = false) -> S {
        var s = S()
        s.owner = owner
        s.phase = phase
        s.detached = detached
        s.notifiedEnded = notifiedEnded
        return s
    }

    private func run(_ events: [RecorderCore.Event], from start: S = S()) -> (S, [E]) {
        var s = start
        var all: [E] = []
        for event in events {
            let (next, effects) = RecorderCore.reduce(s, event)
            s = next
            all += effects
        }
        return (s, all)
    }

    func testInitialState() {
        XCTAssertEqual(S(), state())
        XCTAssertEqual(S().published.isRecording, false)
        XCTAssertEqual(S().published.isConnecting, false)
    }

    // MARK: reserve

    func testReserveWhenFreeTakesOwnershipAndOpens() {
        let (s, fx) = RecorderCore.reduce(state(detached: [b: .finishing], notifiedEnded: true), .reserve(a))
        XCTAssertEqual(fx, [.open(a)])
        XCTAssertEqual(s, state(owner: a, .opening, detached: [b: .finishing]))
    }

    func testReserveWhenOwnedIsRefused() {
        for phase in [RecorderCore.Phase.opening, .connecting, .live, .ended] {
            let before = state(owner: b, phase)
            let (s, fx) = RecorderCore.reduce(before, .reserve(a))
            XCTAssertEqual(fx, [.refuse(a)])
            XCTAssertEqual(s, before)
        }
        let before = state(owner: a, .live)
        XCTAssertEqual(RecorderCore.reduce(before, .reserve(a)).1, [.refuse(a)])
        XCTAssertEqual(RecorderCore.reduce(before, .reserve(a)).0, before)
    }

    func testReserveOfAnIdStillDetachedIsRefused() {
        let before = state(detached: [a: .finishing])
        let (s, fx) = RecorderCore.reduce(before, .reserve(a))
        XCTAssertEqual(fx, [.refuse(a)])
        XCTAssertEqual(s, before)
    }

    // MARK: opened

    func testOpenedForTheOwnerGoesLive() {
        let (s, fx) = RecorderCore.reduce(state(owner: a, .opening), .opened(a, needsConnection: false))
        XCTAssertEqual(fx, [.publish(isRecording: true, isConnecting: false)])
        XCTAssertEqual(s, state(owner: a, .live))
    }

    func testOpenedNeedingConnectionStartsConnecting() {
        let (s, fx) = RecorderCore.reduce(state(owner: a, .opening), .opened(a, needsConnection: true))
        XCTAssertEqual(fx, [.publish(isRecording: false, isConnecting: true), .monitorConnection(a)])
        XCTAssertEqual(s, state(owner: a, .connecting))
    }

    func testDuplicateOpenedForTheOwnerIsIgnored() {
        for phase in [RecorderCore.Phase.connecting, .live, .ended] {
            let before = state(owner: a, phase)
            let (s, fx) = RecorderCore.reduce(before, .opened(a, needsConnection: false))
            XCTAssertEqual(fx, [])
            XCTAssertEqual(s, before)
        }
    }

    func testOpenedAfterStopFinishesWithATail() {
        let before = state(owner: b, .opening, detached: [a: .finishing])
        let (s, fx) = RecorderCore.reduce(before, .opened(a, needsConnection: true))
        XCTAssertEqual(fx, [.finishAfterTail(a)])
        XCTAssertEqual(s, before)
    }

    func testOpenedAfterCancelClosesAndDiscards() {
        let (s, fx) = RecorderCore.reduce(state(detached: [a: .discarding]), .opened(a, needsConnection: false))
        XCTAssertEqual(fx, [.closeAndDiscard(a)])
        XCTAssertEqual(s, state())
    }

    func testOpenedThatNobodyOwnsClosesAndDiscards() {
        let before = state(owner: b, .live)
        let (s, fx) = RecorderCore.reduce(before, .opened(a, needsConnection: false))
        XCTAssertEqual(fx, [.closeAndDiscard(a)])
        XCTAssertEqual(s, before)
    }

    // MARK: openFailed

    func testOpenFailedForTheOwnerReportsAndFreesTheRecorder() {
        let (s, fx) = RecorderCore.reduce(state(owner: a, .opening), .openFailed(a))
        XCTAssertEqual(fx, [idle, .reportStartFailure(a)])
        XCTAssertEqual(s, state())
    }

    func testOpenFailedAfterStopResolvesTheStopWithoutAudio() {
        let (s, fx) = RecorderCore.reduce(state(detached: [a: .finishing]), .openFailed(a))
        XCTAssertEqual(fx, [.resolveStop(a, hasAudio: false)])
        XCTAssertEqual(s, state())
    }

    func testOpenFailedAfterCancelIsDroppedSilently() {
        let (s, fx) = RecorderCore.reduce(state(detached: [a: .discarding]), .openFailed(a))
        XCTAssertEqual(fx, [])
        XCTAssertEqual(s, state())
    }

    func testOpenFailedOtherwiseChangesNothing() {
        for before in [state(), state(owner: b, .live), state(owner: a, .live)] {
            let (s, fx) = RecorderCore.reduce(before, .openFailed(a))
            XCTAssertEqual(fx, [])
            XCTAssertEqual(s, before)
        }
    }

    // MARK: connected

    func testConnectedWhileConnectingGoesLive() {
        let (s, fx) = RecorderCore.reduce(state(owner: a, .connecting), .connected(a))
        XCTAssertEqual(fx, [.publish(isRecording: true, isConnecting: false)])
        XCTAssertEqual(s, state(owner: a, .live))
    }

    func testConnectedOtherwiseChangesNothing() {
        for before in [state(), state(owner: a, .live), state(owner: a, .ended), state(owner: b, .connecting), state(detached: [a: .finishing])] {
            let (s, fx) = RecorderCore.reduce(before, .connected(a))
            XCTAssertEqual(fx, [])
            XCTAssertEqual(s, before)
        }
    }

    // MARK: captureEnded

    func testCaptureEndedWhileLiveOrConnectingTellsTheOwner() {
        for phase in [RecorderCore.Phase.live, .connecting] {
            let (s, fx) = RecorderCore.reduce(state(owner: a, phase), .captureEnded(a))
            XCTAssertEqual(fx, [idle, .notifyCaptureEnded(a)])
            XCTAssertEqual(s, state(owner: a, .ended, notifiedEnded: true))
        }
    }

    func testCaptureEndedOtherwiseChangesNothing() {
        let cases = [
            state(owner: a, .opening),
            state(owner: a, .ended, notifiedEnded: true),
            state(owner: b, .live),
            state(detached: [a: .finishing]),
        ]
        for before in cases {
            let (s, fx) = RecorderCore.reduce(before, .captureEnded(a))
            XCTAssertEqual(fx, [])
            XCTAssertEqual(s, before)
        }
    }

    // MARK: stop

    func testStopWhileOpeningDetachesWithoutATail() {
        let (s, fx) = RecorderCore.reduce(state(owner: a, .opening), .stop(a))
        XCTAssertEqual(fx, [idle])
        XCTAssertEqual(s, state(detached: [a: .finishing]))
    }

    func testStopOfAnOpenCaptureFinishesAfterTheTail() {
        for phase in [RecorderCore.Phase.connecting, .live, .ended] {
            let (s, fx) = RecorderCore.reduce(state(owner: a, phase, notifiedEnded: phase == .ended), .stop(a))
            XCTAssertEqual(fx, [idle, .finishAfterTail(a)])
            XCTAssertEqual(s, state(detached: [a: .finishing], notifiedEnded: phase == .ended))
        }
    }

    func testStopByANonOwnerResolvesWithoutAudio() {
        for before in [state(), state(owner: b, .live), state(detached: [a: .finishing])] {
            let (s, fx) = RecorderCore.reduce(before, .stop(a))
            XCTAssertEqual(fx, [.resolveStop(a, hasAudio: false)])
            XCTAssertEqual(s, before)
        }
    }

    // MARK: cancel

    func testCancelWhileOpeningDetachesForDiscard() {
        let (s, fx) = RecorderCore.reduce(state(owner: a, .opening), .cancel(a))
        XCTAssertEqual(fx, [idle])
        XCTAssertEqual(s, state(detached: [a: .discarding]))
    }

    func testCancelOfAnOpenCaptureClosesAndDiscards() {
        for phase in [RecorderCore.Phase.connecting, .live, .ended] {
            let (s, fx) = RecorderCore.reduce(state(owner: a, phase), .cancel(a))
            XCTAssertEqual(fx, [idle, .closeAndDiscard(a)])
            XCTAssertEqual(s, state())
        }
    }

    func testCancelByANonOwnerDoesNothing() {
        for before in [state(), state(owner: b, .live), state(detached: [a: .finishing])] {
            let (s, fx) = RecorderCore.reduce(before, .cancel(a))
            XCTAssertEqual(fx, [])
            XCTAssertEqual(s, before)
        }
    }

    // MARK: tailFinished

    func testTailFinishedResolvesTheStop() {
        for keep in [true, false] {
            let (s, fx) = RecorderCore.reduce(state(owner: b, .live, detached: [a: .finishing]), .tailFinished(a, keep: keep))
            XCTAssertEqual(fx, [.resolveStop(a, hasAudio: keep)])
            XCTAssertEqual(s, state(owner: b, .live))
        }
    }

    func testTailFinishedOtherwiseChangesNothing() {
        for before in [state(), state(owner: a, .live), state(detached: [a: .discarding])] {
            let (s, fx) = RecorderCore.reduce(before, .tailFinished(a, keep: true))
            XCTAssertEqual(fx, [])
            XCTAssertEqual(s, before)
        }
    }

    // MARK: scenarios

    func testCaptureThatEndsOnItsOwnKeepsItsAudioAndTellsItsOwner() {
        let (s, fx) = run([.reserve(a), .opened(a, needsConnection: false), .captureEnded(a), .stop(a), .tailFinished(a, keep: true)])
        XCTAssertEqual(fx, [
            .open(a),
            .publish(isRecording: true, isConnecting: false),
            idle, .notifyCaptureEnded(a),
            idle, .finishAfterTail(a),
            .resolveStop(a, hasAudio: true),
        ])
        XCTAssertFalse(fx.contains(.closeAndDiscard(a)))
        XCTAssertEqual(s.owner, nil)
        XCTAssertEqual(s.detached, [:])
    }

    func testCancelWhileOpeningNeverBlocksAndNeverLeaks() {
        let (afterCancel, cancelFx) = run([.reserve(a), .cancel(a)])
        // The cancel is answered at once: the recorder is free again before the open finishes.
        XCTAssertEqual(cancelFx, [.open(a), idle])
        XCTAssertNil(afterCancel.owner)
        let (s, fx) = RecorderCore.reduce(afterCancel, .opened(a, needsConnection: false))
        XCTAssertEqual(fx, [.closeAndDiscard(a)])
        XCTAssertEqual(s, state())
    }

    func testANewSessionCanStartDuringThePreviousOnesTail() {
        let (mid, _) = run([.reserve(a), .opened(a, needsConnection: false), .stop(a)])
        XCTAssertEqual(mid, state(detached: [a: .finishing]))
        let (s, fx) = run([.reserve(b), .opened(b, needsConnection: false), .tailFinished(a, keep: true)], from: mid)
        XCTAssertEqual(fx, [.open(b), .publish(isRecording: true, isConnecting: false), .resolveStop(a, hasAudio: true)])
        XCTAssertEqual(s, state(owner: b, .live))
    }

    func testAStaleOwnerCannotStopANewerSession() {
        let (mid, _) = run([.reserve(a), .opened(a, needsConnection: false), .stop(a), .tailFinished(a, keep: false), .reserve(b), .opened(b, needsConnection: false)])
        XCTAssertEqual(mid, state(owner: b, .live))
        let (s, fx) = run([.stop(a), .cancel(a)], from: mid)
        XCTAssertEqual(fx, [.resolveStop(a, hasAudio: false)])
        XCTAssertEqual(s, mid)
    }
}
