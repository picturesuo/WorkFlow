import DictationCore
import XCTest

final class ExitGateCoreTests: XCTestCase {
    typealias S = ExitGateCore.State

    private func state(_ phase: ExitGateCore.Phase, _ inFlight: Int) -> S {
        var s = S()
        s.phase = phase
        s.inFlight = inFlight
        return s
    }

    private func check(_ before: S, _ event: ExitGateCore.Event, _ after: S, _ effects: [ExitGateCore.Effect], line: UInt = #line) {
        let (s, fx) = ExitGateCore.reduce(before, event)
        XCTAssertEqual(s, after, line: line)
        XCTAssertEqual(fx, effects, line: line)
    }

    func testInitialState() {
        XCTAssertEqual(S(), state(.open, 0))
    }

    func testEnterWhileOpenAdmits() {
        check(state(.open, 0), .enter, state(.open, 1), [.admit])
        check(state(.open, 2), .enter, state(.open, 3), [.admit])
    }

    func testEnterAfterShutdownRefuses() {
        check(state(.closing, 1), .enter, state(.closing, 1), [.refuse])
        check(state(.closed, 0), .enter, state(.closed, 0), [.refuse])
        check(state(.closed, 2), .enter, state(.closed, 2), [.refuse])
    }

    func testLeaveWhileOpenDecrements() {
        check(state(.open, 2), .leave, state(.open, 1), [])
        check(state(.open, 1), .leave, state(.open, 0), [])
    }

    func testLastLeaveWhileClosingDrains() {
        check(state(.closing, 1), .leave, state(.closed, 0), [.drained])
    }

    func testLeaveWhileClosingWithOthersInFlightWaits() {
        check(state(.closing, 3), .leave, state(.closing, 2), [])
    }

    func testLeaveAfterAbandonDecrementsQuietly() {
        check(state(.closed, 2), .leave, state(.closed, 1), [])
    }

    func testLeaveWithNothingInFlightIsIgnored() {
        check(state(.open, 0), .leave, state(.open, 0), [])
        check(state(.closed, 0), .leave, state(.closed, 0), [])
    }

    func testShutdownWithNothingInFlightDrainsAtOnce() {
        check(state(.open, 0), .shutdown, state(.closed, 0), [.drained])
    }

    func testShutdownWithCallsInFlightAwaitsDrain() {
        check(state(.open, 2), .shutdown, state(.closing, 2), [.awaitDrain])
    }

    func testShutdownWhileClosingAwaitsTheSameDrain() {
        check(state(.closing, 2), .shutdown, state(.closing, 2), [.awaitDrain])
    }

    func testShutdownWhenClosedDoesNothing() {
        check(state(.closed, 0), .shutdown, state(.closed, 0), [])
    }

    func testTimeoutWhileClosingAbandons() {
        check(state(.closing, 2), .timeout, state(.closed, 2), [.abandon])
    }

    func testTimeoutOtherwiseDoesNothing() {
        check(state(.open, 1), .timeout, state(.open, 1), [])
        check(state(.closed, 0), .timeout, state(.closed, 0), [])
    }

    func testEnterSaturatesInsteadOfTrapping() {
        check(state(.open, .max), .enter, state(.open, .max), [.refuse])
    }
}

/// Native calls that enter and later leave, a shutdown, and a timeout, in any
/// order, plus stray leaves. Checks E1-E5.
struct ExitGateModel: PropertyModel {
    typealias Step = ExitGateCore.Event

    var state = ExitGateCore.State()
    /// Admitted calls that have not left yet.
    var outstanding = 0
    var shutdownSeen = false
    var timeoutAfterShutdown = false
    var terminals = 0

    mutating func generate(_ rng: inout SplitMix64) -> Step {
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<40: return .enter
        case 40..<85: return .leave
        case 85..<93: return .shutdown
        default: return .timeout
        }
    }

    mutating func drain(_ rng: inout SplitMix64) -> Step? {
        if !shutdownSeen { return .shutdown }
        if outstanding > 0 && !timeoutAfterShutdown { return rng.chance(0.2) ? .timeout : .leave }
        return nil
    }

    mutating func apply(_ event: Step) -> [String] {
        var v: [String] = []
        let pre = state
        let (post, effects) = ExitGateCore.reduce(pre, event)
        state = post

        if event == .leave, outstanding > 0 { outstanding -= 1 }
        for effect in effects {
            switch effect {
            case .admit:
                outstanding += 1
                if shutdownSeen { v.append("E2: admit after shutdown") }
            case .drained:
                terminals += 1
                if post.inFlight != 0 { v.append("E3: drained with \(post.inFlight) in flight") }
            case .abandon:
                terminals += 1
                if post.inFlight <= 0 { v.append("E3: abandon with nothing in flight") }
            case .refuse, .awaitDrain:
                break
            }
        }
        if event == .shutdown { shutdownSeen = true }
        if event == .timeout, shutdownSeen { timeoutAfterShutdown = true }

        // E1
        if post.inFlight < 0 { v.append("E1: inFlight \(post.inFlight)") }
        if post.inFlight != outstanding { v.append("E1: inFlight \(post.inFlight) but \(outstanding) admitted calls have not left") }
        // E3
        if terminals > 1 { v.append("E3: \(terminals) of drained/abandon") }
        // E4
        if shutdownSeen, outstanding == 0 || timeoutAfterShutdown, terminals != 1 {
            v.append("E4: shutdown settled but \(terminals) of drained/abandon were emitted")
        }
        // E5: every shutdown that leaves the gate closing, first or repeated, awaits the drain.
        if event == .shutdown, post.phase == .closing, effects != [.awaitDrain] {
            v.append("E5: shutdown while closing emitted \(effects)")
        }
        return v
    }

    func finalViolations() -> [String] {
        terminals == 1 ? [] : ["E4: \(terminals) of drained/abandon at rest"]
    }
}

final class ExitGateCorePropertyTests: XCTestCase {
    func testInvariants() {
        PropertyCheck.run(ExitGateModel.self, name: "ExitGateCore")
    }
}
