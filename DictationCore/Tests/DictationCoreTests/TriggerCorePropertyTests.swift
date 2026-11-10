import DictationCore
import Foundation
import XCTest

/// Invariants T1-T6, shared by the open-loop and the closed-loop model.
struct TriggerInvariants {
    var state = TriggerCore.State()
    /// The hold timer the outside world believes is outstanding, from effects alone.
    var outstandingTimer: UInt64?
    var scheduledTokens: Set<UInt64> = []
    /// The time of the most recent keyDown, for T6.
    var lastKeyDownAt: TimeInterval?

    mutating func apply(_ event: TriggerCore.Event, _ config: TriggerCore.Config) -> (effects: [TriggerCore.Effect], violations: [String]) {
        var v: [String] = []
        let (next, effects) = TriggerCore.reduce(state, event, config: config)
        state = next

        let intents = effects.filter { [.startSession, .stopSession, .abortSession].contains($0) }

        // T1
        for intent in intents {
            switch (intent, event) {
            case (.startSession, .keyDown(_, false)): break
            case (.startSession, _): v.append("T1: startSession from \(event)")
            case (_, .keyDown(_, true)), (_, .keyUp(true)), (_, .chord(true)): break
            default: v.append("T1: \(intent) from \(event)")
            }
        }
        // T2
        if intents.count > 1 { v.append("T2: \(intents.count) session intents in one event: \(effects)") }

        // T3
        for effect in effects {
            switch effect {
            case let .cancelHold(token):
                if outstandingTimer != token {
                    v.append("T3: cancelHold(\(token)) but the outstanding timer is \(String(describing: outstandingTimer))")
                }
                outstandingTimer = nil
            case let .scheduleHold(token, _):
                if !scheduledTokens.insert(token).inserted { v.append("T3: token \(token) scheduled twice") }
                if let old = outstandingTimer { v.append("T3: scheduled \(token) while \(old) was still outstanding") }
                outstandingTimer = token
            default: break
            }
        }
        if case let .holdElapsed(token) = event, token == outstandingTimer {
            outstandingTimer = nil
        }
        if state.holdTimer != outstandingTimer {
            v.append("T3: state.holdTimer \(String(describing: state.holdTimer)) != outstanding \(String(describing: outstandingTimer))")
        }
        if state.holdTimer != nil, state.press != .down(startedSession: true, holdArmed: false) {
            v.append("T3: holdTimer set with press \(state.press)")
        }

        // T4
        if case .down(false, true) = state.press { v.append("T4: holdArmed on a press that started no session") }

        // T5
        switch event {
        case .keyUp:
            if effects.contains(.startSession) || effects.contains(.abortSession) { v.append("T5: keyUp emitted \(effects)") }
        case .chord:
            if effects.contains(.startSession) || effects.contains(.stopSession) { v.append("T5: chord emitted \(effects)") }
        default: break
        }

        // T6
        if case let .keyDown(t, false) = event {
            if config.doublePress {
                let earlierTapInside = lastKeyDownAt.map { t - $0 <= config.doublePressInterval } ?? false
                if !earlierTapInside, !intents.isEmpty {
                    v.append("T6: double-press keyDown with no earlier tap inside \(config.doublePressInterval)s emitted \(intents)")
                }
            }
        }
        if case let .keyDown(t, _) = event { lastKeyDownAt = t }

        return (effects, v)
    }

    static func randomConfig(_ rng: inout SplitMix64) -> TriggerCore.Config {
        TriggerCore.Config(
            holdToRecord: rng.chance(0.5),
            doublePress: rng.chance(0.35),
            doublePressInterval: Double.random(in: 0.2...0.6, using: &rng),
            holdThreshold: Double.random(in: 0.1...0.5, using: &rng)
        )
    }
}

/// Random events with random `capturing` inputs and random timer tokens.
struct TriggerOpenLoopModel: PropertyModel {
    struct Step: CustomStringConvertible {
        var event: TriggerCore.Event
        var config: TriggerCore.Config
        var description: String {
            "\(event)  [hold: \(config.holdToRecord), double: \(config.doublePress) @\(String(format: "%.3f", config.doublePressInterval))]"
        }
    }

    var checks = TriggerInvariants()
    var config = TriggerCore.Config()
    var clock: TimeInterval = 0

    mutating func generate(_ rng: inout SplitMix64) -> Step {
        if rng.chance(0.15) { config = TriggerInvariants.randomConfig(&rng) }
        let event: TriggerCore.Event
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...2:
            clock += Double.random(in: 0...0.8, using: &rng)
            event = .keyDown(at: clock, capturing: rng.chance(0.5))
        case 3...5:
            event = .keyUp(capturing: rng.chance(0.5))
        case 6:
            event = .chord(capturing: rng.chance(0.5))
        case 7, 8:
            let token = checks.outstandingTimer.flatMap { rng.chance(0.7) ? $0 : nil }
                ?? UInt64.random(in: 0...(checks.state.nextToken + 2), using: &rng)
            event = .holdElapsed(token: token)
        default:
            event = .sessionEnded
        }
        return Step(event: event, config: config)
    }

    mutating func apply(_ step: Step) -> [String] {
        checks.apply(step.event, step.config).violations
    }
}

/// A faithful session owner (`capturing` follows the session intents, and the
/// session may also end on its own) and faithful timers, plus scripted gestures.
struct TriggerClosedLoopModel: PropertyModel {
    enum Step: CustomStringConvertible {
        case event(TriggerCore.Event, TriggerCore.Config)
        /// The session ends on its own: `capturing` becomes false, then `sessionEnded`.
        case sessionEndsOnItsOwn(TriggerCore.Config)
        case expectCapturing(Bool, String)

        var description: String {
            switch self {
            case let .event(event, c):
                return "\(event)  [hold: \(c.holdToRecord), double: \(c.doublePress) @\(String(format: "%.3f", c.doublePressInterval))]"
            case .sessionEndsOnItsOwn: return "session ends on its own -> sessionEnded"
            case let .expectCapturing(value, why): return "expect capturing == \(value) (\(why))"
            }
        }
    }

    private enum Scripted {
        case keyDown, keyUp, deliverHold
        case expect(Bool, String)
    }

    var checks = TriggerInvariants()
    var capturing = false
    var config = TriggerCore.Config()
    var clock: TimeInterval = 0
    private var script: [Scripted] = []
    private var scriptConfig = TriggerCore.Config(holdToRecord: true, doublePress: false)

    mutating func generate(_ rng: inout SplitMix64) -> Step {
        if !script.isEmpty {
            switch script.removeFirst() {
            case .keyDown:
                clock += Double.random(in: 0.7...2, using: &rng)
                return .event(.keyDown(at: clock, capturing: capturing), scriptConfig)
            case .keyUp:
                return .event(.keyUp(capturing: capturing), scriptConfig)
            case .deliverHold:
                return .event(.holdElapsed(token: checks.outstandingTimer ?? .max), scriptConfig)
            case let .expect(value, why):
                return .expectCapturing(value, why)
            }
        }

        if !capturing, rng.chance(0.05) {
            scriptConfig.holdThreshold = Double.random(in: 0.1...0.5, using: &rng)
            if rng.chance(0.5) {
                script = [.keyDown, .deliverHold, .keyUp, .expect(false, "hold gesture ends the capture")]
            } else {
                script = [
                    .keyDown, .keyUp, .expect(true, "quick tap keeps capturing"),
                    .keyDown, .keyUp, .expect(false, "second tap stops"),
                ]
            }
            return generate(&rng)
        }

        if rng.chance(0.15) { config = TriggerInvariants.randomConfig(&rng) }
        switch Int.random(in: 0..<20, using: &rng) {
        case 0...5:
            clock += Double.random(in: 0...0.8, using: &rng)
            return .event(.keyDown(at: clock, capturing: capturing), config)
        case 6...11:
            return .event(.keyUp(capturing: capturing), config)
        case 12, 13:
            return .event(.chord(capturing: capturing), config)
        case 14...16:
            if let token = checks.outstandingTimer { return .event(.holdElapsed(token: token), config) }
            return .event(.keyUp(capturing: capturing), config)
        case 17:
            // A timer that was cancelled but raced its own cancellation.
            return .event(.holdElapsed(token: UInt64.random(in: 0...checks.state.nextToken, using: &rng)), config)
        case 18:
            if capturing { return .sessionEndsOnItsOwn(config) }
            return .event(.sessionEnded, config)
        default:
            return .event(.sessionEnded, config)
        }
    }

    mutating func apply(_ step: Step) -> [String] {
        switch step {
        case let .expectCapturing(value, why):
            return capturing == value ? [] : ["T7: \(why): capturing is \(capturing)"]
        case let .sessionEndsOnItsOwn(c):
            capturing = false
            return send(.sessionEnded, c)
        case let .event(event, c):
            return send(event, c)
        }
    }

    private mutating func send(_ event: TriggerCore.Event, _ c: TriggerCore.Config) -> [String] {
        var (effects, v) = checks.apply(event, c)
        for effect in effects {
            switch effect {
            case .startSession:
                if capturing { v.append("T7: startSession while a session is still capturing") }
                capturing = true
            case .stopSession, .abortSession:
                capturing = false
            default: break
            }
        }
        return v
    }
}

final class TriggerCorePropertyTests: XCTestCase {
    func testOpenLoopInvariants() {
        PropertyCheck.run(TriggerOpenLoopModel.self, name: "TriggerCore open loop")
    }

    func testClosedLoopInvariants() {
        PropertyCheck.run(TriggerClosedLoopModel.self, name: "TriggerCore closed loop")
    }
}
