import DictationCore
import XCTest

final class TriggerCoreTests: XCTestCase {
    typealias S = TriggerCore.State

    private let plain = TriggerCore.Config(holdToRecord: false, doublePress: false, doublePressInterval: 0.5, holdThreshold: 0.3)
    private let hold = TriggerCore.Config(holdToRecord: true, doublePress: false, doublePressInterval: 0.5, holdThreshold: 0.3)
    private let double = TriggerCore.Config(holdToRecord: false, doublePress: true, doublePressInterval: 0.5, holdThreshold: 0.3)

    private func state(
        _ press: S.Press = .up,
        firstTapAt: TimeInterval? = nil,
        holdTimer: UInt64? = nil,
        nextToken: UInt64 = 0
    ) -> S {
        var s = S()
        s.press = press
        s.firstTapAt = firstTapAt
        s.holdTimer = holdTimer
        s.nextToken = nextToken
        return s
    }

    func testInitialState() {
        XCTAssertEqual(S(), state(.up, firstTapAt: nil, holdTimer: nil, nextToken: 0))
    }

    // MARK: keyDown

    func testKeyDownCancelsOutstandingHoldAndDisarms() {
        let before = state(.down(startedSession: true, holdArmed: false), holdTimer: 4, nextToken: 5)
        let (after, effects) = TriggerCore.reduce(before, .keyDown(at: 10, capturing: true), config: hold)
        XCTAssertEqual(effects, [.cancelHold(token: 4), .stopSession])
        XCTAssertEqual(after, state(.down(startedSession: false, holdArmed: false), nextToken: 5))
    }

    func testKeyDownDisarmsHoldBeforeDoublePressFirstTap() {
        let before = state(.down(startedSession: true, holdArmed: true))
        let (after, effects) = TriggerCore.reduce(before, .keyDown(at: 3, capturing: false), config: double)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up, firstTapAt: 3))
    }

    func testKeyDownDoublePressFirstTapIsRecordedOnly() {
        let (after, effects) = TriggerCore.reduce(S(), .keyDown(at: 1, capturing: false), config: double)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up, firstTapAt: 1))
    }

    func testKeyDownDoublePressSecondTapInsideIntervalStarts() {
        let (after, effects) = TriggerCore.reduce(state(firstTapAt: 1), .keyDown(at: 1.5, capturing: false), config: double)
        XCTAssertEqual(effects, [.startSession])
        XCTAssertEqual(after, state(.down(startedSession: true, holdArmed: false)))
    }

    func testKeyDownDoublePressSecondTapOutsideIntervalRestartsTheWait() {
        let (after, effects) = TriggerCore.reduce(state(firstTapAt: 1), .keyDown(at: 1.6, capturing: false), config: double)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up, firstTapAt: 1.6))
    }

    func testKeyDownDoublePressIsSkippedWhileCapturing() {
        let (after, effects) = TriggerCore.reduce(state(firstTapAt: 1), .keyDown(at: 9, capturing: true), config: double)
        XCTAssertEqual(effects, [.stopSession])
        XCTAssertEqual(after, state(.down(startedSession: false, holdArmed: false), firstTapAt: 1))
    }

    func testKeyDownNotCapturingStarts() {
        let (after, effects) = TriggerCore.reduce(S(), .keyDown(at: 0, capturing: false), config: plain)
        XCTAssertEqual(effects, [.startSession])
        XCTAssertEqual(after, state(.down(startedSession: true, holdArmed: false)))
    }

    func testKeyDownStartWithHoldToRecordSchedulesAFreshHold() {
        let (after, effects) = TriggerCore.reduce(state(nextToken: 7), .keyDown(at: 0, capturing: false), config: hold)
        XCTAssertEqual(effects, [.startSession, .scheduleHold(token: 7, after: 0.3)])
        XCTAssertEqual(after, state(.down(startedSession: true, holdArmed: false), holdTimer: 7, nextToken: 8))
    }

    func testKeyDownCapturingStopsAndSchedulesNoHold() {
        let (after, effects) = TriggerCore.reduce(S(), .keyDown(at: 0, capturing: true), config: hold)
        XCTAssertEqual(effects, [.stopSession])
        XCTAssertEqual(after, state(.down(startedSession: false, holdArmed: false)))
    }

    func testKeyDownWhileDownIsANewPress() {
        let before = state(.down(startedSession: false, holdArmed: false))
        let (after, effects) = TriggerCore.reduce(before, .keyDown(at: 0, capturing: false), config: plain)
        XCTAssertEqual(effects, [.startSession])
        XCTAssertEqual(after, state(.down(startedSession: true, holdArmed: false)))
    }

    // MARK: holdElapsed

    func testHoldElapsedMatchingTokenArmsTheHold() {
        let before = state(.down(startedSession: true, holdArmed: false), holdTimer: 2, nextToken: 3)
        let (after, effects) = TriggerCore.reduce(before, .holdElapsed(token: 2), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.down(startedSession: true, holdArmed: true), nextToken: 3))
    }

    func testHoldElapsedMatchingTokenWhileUpOnlyClearsTheTimer() {
        let (after, effects) = TriggerCore.reduce(state(.up, holdTimer: 2, nextToken: 3), .holdElapsed(token: 2), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up, nextToken: 3))
    }

    func testHoldElapsedStaleTokenChangesNothing() {
        let before = state(.down(startedSession: true, holdArmed: false), holdTimer: 2, nextToken: 3)
        for token: UInt64 in [0, 1, 3, .max] {
            let (after, effects) = TriggerCore.reduce(before, .holdElapsed(token: token), config: hold)
            XCTAssertEqual(effects, [])
            XCTAssertEqual(after, before)
        }
        let (after, effects) = TriggerCore.reduce(S(), .holdElapsed(token: 0), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, S())
    }

    // MARK: keyUp

    func testKeyUpCancelsOutstandingHold() {
        let before = state(.down(startedSession: true, holdArmed: false), holdTimer: 0, nextToken: 1)
        let (after, effects) = TriggerCore.reduce(before, .keyUp(capturing: true), config: hold)
        XCTAssertEqual(effects, [.cancelHold(token: 0)])
        XCTAssertEqual(after, state(.up, nextToken: 1))
    }

    func testKeyUpWhileUpDoesNothing() {
        let before = state(.up, firstTapAt: 4)
        let (after, effects) = TriggerCore.reduce(before, .keyUp(capturing: true), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, before)
    }

    func testKeyUpAfterArmedHoldStopsTheCapture() {
        let (after, effects) = TriggerCore.reduce(state(.down(startedSession: true, holdArmed: true)), .keyUp(capturing: true), config: hold)
        XCTAssertEqual(effects, [.stopSession])
        XCTAssertEqual(after, state(.up))
    }

    func testKeyUpAfterArmedHoldDoesNothingWhenNotCapturing() {
        let (after, effects) = TriggerCore.reduce(state(.down(startedSession: true, holdArmed: true)), .keyUp(capturing: false), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up))
    }

    func testKeyUpAfterArmedHoldDoesNothingWhenHoldToRecordIsOff() {
        let (after, effects) = TriggerCore.reduce(state(.down(startedSession: true, holdArmed: true)), .keyUp(capturing: true), config: plain)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up))
    }

    func testKeyUpWithoutArmedHoldOnlyReleases() {
        let (after, effects) = TriggerCore.reduce(state(.down(startedSession: true, holdArmed: false)), .keyUp(capturing: true), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up))
    }

    // MARK: chord

    func testChordCancelsHoldAndClearsFirstTap() {
        let before = state(.up, firstTapAt: 2, holdTimer: 1, nextToken: 2)
        let (after, effects) = TriggerCore.reduce(before, .chord(capturing: false), config: hold)
        XCTAssertEqual(effects, [.cancelHold(token: 1)])
        XCTAssertEqual(after, state(.up, nextToken: 2))
    }

    func testChordWhileUpDoesNothingElse() {
        let (after, effects) = TriggerCore.reduce(state(.up, firstTapAt: 2), .chord(capturing: true), config: double)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up))
    }

    func testChordAfterAStartingPressAbortsTheCapture() {
        let before = state(.down(startedSession: true, holdArmed: false), holdTimer: 0, nextToken: 1)
        let (after, effects) = TriggerCore.reduce(before, .chord(capturing: true), config: hold)
        XCTAssertEqual(effects, [.cancelHold(token: 0), .abortSession])
        XCTAssertEqual(after, state(.up, nextToken: 1))
    }

    func testChordAfterAStartingPressDoesNothingWhenNotCapturing() {
        let (after, effects) = TriggerCore.reduce(state(.down(startedSession: true, holdArmed: true)), .chord(capturing: false), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up))
    }

    func testChordAfterAStoppingPressDoesNotAbort() {
        let (after, effects) = TriggerCore.reduce(state(.down(startedSession: false, holdArmed: false)), .chord(capturing: true), config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.up))
    }

    // MARK: sessionEnded

    func testSessionEndedDisarmsHoldAndKeepsEverythingElse() {
        let before = state(.down(startedSession: true, holdArmed: true), firstTapAt: 1, nextToken: 4)
        let (after, effects) = TriggerCore.reduce(before, .sessionEnded, config: hold)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after, state(.down(startedSession: true, holdArmed: false), firstTapAt: 1, nextToken: 4))
    }

    func testSessionEndedKeepsTheOutstandingTimerAndAnUpPress() {
        let pending = state(.down(startedSession: true, holdArmed: false), holdTimer: 3, nextToken: 4)
        XCTAssertEqual(TriggerCore.reduce(pending, .sessionEnded, config: hold).0, pending)
        XCTAssertEqual(TriggerCore.reduce(pending, .sessionEnded, config: hold).1, [])
        XCTAssertEqual(TriggerCore.reduce(S(), .sessionEnded, config: hold).0, S())
    }

    // MARK: gestures

    /// Drives the core with a faithful session owner and hold timer.
    private struct Driver {
        var state = S()
        var capturing = false
        var timer: UInt64?
        var config: TriggerCore.Config
        var clock: TimeInterval = 100

        init(_ config: TriggerCore.Config) { self.config = config }

        @discardableResult
        mutating func send(_ event: TriggerCore.Event) -> [TriggerCore.Effect] {
            let (next, effects) = TriggerCore.reduce(state, event, config: config)
            state = next
            for effect in effects {
                switch effect {
                case .startSession: capturing = true
                case .stopSession, .abortSession: capturing = false
                case let .scheduleHold(token, _): timer = token
                case .cancelHold: timer = nil
                }
            }
            return effects
        }

        @discardableResult
        mutating func down(after delay: TimeInterval = 1) -> [TriggerCore.Effect] {
            clock += delay
            return send(.keyDown(at: clock, capturing: capturing))
        }

        @discardableResult
        mutating func up() -> [TriggerCore.Effect] { send(.keyUp(capturing: capturing)) }

        @discardableResult
        mutating func elapse() -> [TriggerCore.Effect] {
            guard let token = timer else { return [] }
            timer = nil
            return send(.holdElapsed(token: token))
        }
    }

    func testGestureHoldToRecordRecordsWhileHeld() {
        var d = Driver(hold)
        d.down()
        XCTAssertTrue(d.capturing)
        d.elapse()
        XCTAssertTrue(d.capturing)
        XCTAssertEqual(d.up(), [.stopSession])
        XCTAssertFalse(d.capturing)
    }

    func testGestureQuickTapToggles() {
        var d = Driver(hold)
        XCTAssertEqual(d.down().first, .startSession)
        XCTAssertEqual(d.up(), [.cancelHold(token: 0)])
        XCTAssertTrue(d.capturing)
        XCTAssertEqual(d.down(), [.stopSession])
        XCTAssertEqual(d.up(), [])
        XCTAssertFalse(d.capturing)
        XCTAssertNil(d.timer)
    }

    func testGestureDoublePressStartsAndASinglePressStops() {
        var d = Driver(double)
        XCTAssertEqual(d.down(), [])
        d.up()
        XCTAssertEqual(d.down(after: 0.2), [.startSession])
        d.up()
        XCTAssertTrue(d.capturing)
        XCTAssertEqual(d.down(after: 3), [.stopSession])
        d.up()
        XCTAssertFalse(d.capturing)
    }

    func testGestureSlowDoublePressDoesNotStart() {
        var d = Driver(double)
        XCTAssertEqual(d.down(), [])
        d.up()
        XCTAssertEqual(d.down(after: 0.8), [])
        d.up()
        XCTAssertFalse(d.capturing)
    }

    func testGestureChordUndoesTheStartingPress() {
        var d = Driver(hold)
        d.down()
        XCTAssertEqual(d.send(.chord(capturing: d.capturing)), [.cancelHold(token: 0), .abortSession])
        XCTAssertFalse(d.capturing)
        XCTAssertEqual(d.up(), [])
    }

    func testGestureSessionEndingDuringAHoldDoesNotStopTheNextOne() {
        var d = Driver(hold)
        d.down()
        d.elapse()
        d.capturing = false
        d.send(.sessionEnded)
        XCTAssertEqual(d.up(), [])
        XCTAssertFalse(d.capturing)
    }
}
