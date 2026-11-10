import Foundation

/// Lets process exit wait for in-flight native library calls.
///
/// Callers `enter` before a native call and `leave` after it. `shutdown`
/// closes the gate to new calls and waits for the in-flight ones to drain,
/// unless a `timeout` arrives first.
///
/// Transition table:
///
/// | Event | Condition | Transition | Effects |
/// |---|---|---|---|
/// | `enter` | `phase == .open` | `inFlight += 1` | `admit` |
/// | `enter` | otherwise | unchanged | `refuse` |
/// | `leave` | `inFlight > 0`, `phase == .closing`, `inFlight` becomes 0 | `inFlight -= 1`, `phase = .closed` | `drained` |
/// | `leave` | `inFlight > 0`, otherwise | `inFlight -= 1` | none |
/// | `leave` | `inFlight == 0` | ignored | none |
/// | `shutdown` | `phase == .open`, `inFlight == 0` | `phase = .closed` | `drained` |
/// | `shutdown` | `phase == .open`, `inFlight > 0` | `phase = .closing` | `awaitDrain` |
/// | `shutdown` | otherwise | unchanged | none |
/// | `timeout` | `phase == .closing` | `phase = .closed` | `abandon` |
/// | `timeout` | otherwise | unchanged | none |
public enum ExitGateCore {
    public enum Phase: Sendable, Hashable {
        case open
        case closing
        case closed
    }

    public struct State: Sendable, Hashable {
        public var phase: Phase
        public var inFlight: Int

        public init() {
            phase = .open
            inFlight = 0
        }
    }

    public enum Event: Sendable, Hashable {
        case enter
        case leave
        case shutdown
        case timeout
    }

    public enum Effect: Sendable, Hashable {
        case admit
        case refuse
        case awaitDrain
        case drained
        case abandon
    }

    public static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var s = state
        switch event {
        case .enter:
            // The saturation guard only keeps the reducer total; it is unreachable in practice.
            guard s.phase == .open, s.inFlight < Int.max else { return (s, [.refuse]) }
            s.inFlight += 1
            return (s, [.admit])

        case .leave:
            guard s.inFlight > 0 else { return (s, []) }
            s.inFlight -= 1
            if s.phase == .closing && s.inFlight == 0 {
                s.phase = .closed
                return (s, [.drained])
            }
            return (s, [])

        case .shutdown:
            guard s.phase == .open else { return (s, []) }
            if s.inFlight == 0 {
                s.phase = .closed
                return (s, [.drained])
            }
            s.phase = .closing
            return (s, [.awaitDrain])

        case .timeout:
            guard s.phase == .closing else { return (s, []) }
            s.phase = .closed
            return (s, [.abandon])
        }
    }
}
