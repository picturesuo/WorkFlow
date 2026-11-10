import Foundation

/// The press, hold, double-press and chord gestures of the dictation hotkey.
///
/// Pins the behavior of `ShortcutManager` (`handleKeyDownOnMain`,
/// `handleKeyUpOnMain`, `handleChordOnMain`, `indicatorWindowDidHide`) with one
/// deliberate change: instead of a private mirror of the session (`activeVm`),
/// every event carries `capturing`, supplied by the single owner of the
/// dictation session: "a hotkey dictation is currently capturing audio".
///
/// Transition table (`c` is the `Config` passed with the event):
///
/// | Event | Transition | Effects |
/// |---|---|---|
/// | any of keyDown, keyUp, chord | if `holdTimer` is set, clear it | `cancelHold(token)` first |
/// | `keyDown(t, cap)` | a `.down` press loses `holdArmed` | |
/// | `keyDown(t, false)`, `c.doublePress`, `firstTapAt` set and `t - firstTapAt <= c.doublePressInterval` | clear `firstTapAt`, continue as a start | |
/// | `keyDown(t, false)`, `c.doublePress`, otherwise | `firstTapAt = t`, `press = .up`, stop here | none |
/// | `keyDown(t, false)` (start) | `press = .down(startedSession: true, holdArmed: false)`; if `c.holdToRecord`: `holdTimer = nextToken`, `nextToken += 1` | `startSession`, then `scheduleHold(token, after: c.holdThreshold)` if `c.holdToRecord` |
/// | `keyDown(t, true)` (stop) | `press = .down(startedSession: false, holdArmed: false)` | `stopSession` |
/// | `holdElapsed(token)`, `token == holdTimer` | clear `holdTimer`; a `.down` press gets `holdArmed = true` | none |
/// | `holdElapsed(token)`, any other token | unchanged | none |
/// | `keyUp(cap)`, `press == .up` | unchanged (apart from the timer) | none |
/// | `keyUp(cap)`, `press == .down(_, armed)` | `press = .up` | `stopSession` if `c.holdToRecord && armed && cap` |
/// | `chord(cap)` | clear `firstTapAt` | |
/// | `chord(cap)`, `press == .up` | unchanged otherwise | none |
/// | `chord(cap)`, `press == .down(started, _)` | `press = .up` | `abortSession` if `started && cap` |
/// | `sessionEnded` | a `.down` press loses `holdArmed` | none |
///
/// A keyDown while already `.down` is processed as a new press, exactly like
/// any other keyDown.
public enum TriggerCore {
    public struct Config: Sendable, Hashable {
        public var holdToRecord: Bool
        public var doublePress: Bool
        public var doublePressInterval: TimeInterval
        public var holdThreshold: TimeInterval

        public init(
            holdToRecord: Bool = false,
            doublePress: Bool = false,
            doublePressInterval: TimeInterval = 0.5,
            holdThreshold: TimeInterval = 0.3
        ) {
            self.holdToRecord = holdToRecord
            self.doublePress = doublePress
            self.doublePressInterval = doublePressInterval
            self.holdThreshold = holdThreshold
        }
    }

    public struct State: Sendable, Hashable {
        public enum Press: Sendable, Hashable {
            case up
            /// The press was consumed: it started a session, or stopped one.
            case down(startedSession: Bool, holdArmed: Bool)
        }

        /// `.down` is the app's `pressConsumed`.
        public var press: Press
        /// The pending first tap of a double-press.
        public var firstTapAt: TimeInterval?
        /// The token of the one outstanding hold timer, if any.
        public var holdTimer: UInt64?
        public var nextToken: UInt64

        public init() {
            press = .up
            firstTapAt = nil
            holdTimer = nil
            nextToken = 0
        }
    }

    public enum Event: Sendable, Hashable {
        case keyDown(at: TimeInterval, capturing: Bool)
        case keyUp(capturing: Bool)
        case chord(capturing: Bool)
        case holdElapsed(token: UInt64)
        case sessionEnded
    }

    public enum Effect: Sendable, Hashable {
        case startSession
        case stopSession
        case abortSession
        case scheduleHold(token: UInt64, after: TimeInterval)
        case cancelHold(token: UInt64)
    }

    public static func reduce(_ state: State, _ event: Event, config c: Config) -> (State, [Effect]) {
        var s = state
        var effects: [Effect] = []

        switch event {
        case let .keyDown(t, capturing):
            s.cancelHoldTimer(into: &effects)
            s.disarmHold()

            if c.doublePress && !capturing {
                if let first = s.firstTapAt, t - first <= c.doublePressInterval {
                    s.firstTapAt = nil
                } else {
                    s.firstTapAt = t
                    s.press = .up
                    return (s, effects)
                }
            }

            s.press = .down(startedSession: !capturing, holdArmed: false)
            if capturing {
                effects.append(.stopSession)
            } else {
                effects.append(.startSession)
                if c.holdToRecord {
                    let token = s.nextToken
                    s.nextToken &+= 1
                    s.holdTimer = token
                    effects.append(.scheduleHold(token: token, after: c.holdThreshold))
                }
            }

        case let .holdElapsed(token):
            guard token == s.holdTimer else { break }
            s.holdTimer = nil
            if case let .down(started, _) = s.press {
                s.press = .down(startedSession: started, holdArmed: true)
            }

        case let .keyUp(capturing):
            s.cancelHoldTimer(into: &effects)
            guard case let .down(_, armed) = s.press else { break }
            s.press = .up
            if c.holdToRecord && armed && capturing {
                effects.append(.stopSession)
            }

        case let .chord(capturing):
            s.cancelHoldTimer(into: &effects)
            s.firstTapAt = nil
            guard case let .down(started, _) = s.press else { break }
            s.press = .up
            if started && capturing {
                effects.append(.abortSession)
            }

        case .sessionEnded:
            s.disarmHold()
        }

        return (s, effects)
    }
}

extension TriggerCore.State {
    fileprivate mutating func cancelHoldTimer(into effects: inout [TriggerCore.Effect]) {
        guard let token = holdTimer else { return }
        effects.append(.cancelHold(token: token))
        holdTimer = nil
    }

    fileprivate mutating func disarmHold() {
        if case let .down(started, _) = press {
            press = .down(startedSession: started, holdArmed: false)
        }
    }
}
