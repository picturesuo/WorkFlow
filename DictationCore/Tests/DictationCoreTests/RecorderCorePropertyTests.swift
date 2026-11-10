import DictationCore
import Foundation
import XCTest

extension RecorderCore.Event {
    var sessionID: UUID {
        switch self {
        case let .reserve(id), let .opened(id, _), let .openFailed(id), let .connected(id),
             let .captureEnded(id), let .stop(id), let .cancel(id), let .tailFinished(id, _):
            return id
        }
    }
}

extension RecorderCore.Effect {
    var sessionID: UUID? {
        switch self {
        case let .open(id), let .monitorConnection(id), let .reportStartFailure(id), let .notifyCaptureEnded(id),
             let .finishAfterTail(id), let .closeAndDiscard(id), let .resolveStop(id, _), let .refuse(id):
            return id
        case .publish:
            return nil
        }
    }
}

/// Callers that reserve, stop and cancel with a mix of fresh, current, detached,
/// stale and never-reserved ids, and a closed-loop runner that answers every
/// effect faithfully at random later times. Checks R1-R7.
struct RecorderModel: PropertyModel {
    typealias Step = RecorderCore.Event

    var state = RecorderCore.State()

    // Runner model.
    var pendingOpens: [UUID] = []
    var pendingTails: [UUID] = []
    var pendingConnects: [UUID] = []
    var openCaptures: Set<UUID> = []
    var endedCaptures: Set<UUID> = []

    // Bookkeeping for the invariants.
    var accepted: [UUID] = []
    var acceptedSet: Set<UUID> = []
    var refused: [UUID] = []
    var stopOrCancelSent: Set<UUID> = []
    var cancelled: Set<UUID> = []
    var stopped: Set<UUID> = []
    var opensEmitted: [UUID: Int] = [:]
    var micReleases: [UUID: Int] = [:]
    var terminals: [UUID: Int] = [:]
    var notified: [UUID: Int] = [:]

    private var staleIDs: [UUID] {
        accepted.filter { $0 != state.owner && state.detached[$0] == nil }
    }

    private func pick<T>(_ items: [T], _ rng: inout SplitMix64) -> T? {
        items.isEmpty ? nil : items[Int.random(in: 0..<items.count, using: &rng)]
    }

    /// A caller id: mostly the owner, sometimes a detached, stale or unknown one.
    private func callerID(_ rng: inout SplitMix64) -> UUID {
        let roll = Int.random(in: 0..<10, using: &rng)
        if roll < 6, let owner = state.owner { return owner }
        if roll < 8, let id = pick(Array(state.detached.keys).sorted { $0.uuidString < $1.uuidString }, &rng) { return id }
        if roll < 9, let id = pick(staleIDs, &rng) { return id }
        return pick(refused, &rng) ?? rng.uuid()
    }

    mutating func generate(_ rng: inout SplitMix64) -> Step {
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<18:
            let roll = Int.random(in: 0..<10, using: &rng)
            if roll < 2, let owner = state.owner { return .reserve(owner) }
            if roll < 4, let id = pick(Array(state.detached.keys).sorted { $0.uuidString < $1.uuidString }, &rng) {
                return .reserve(id)
            }
            return .reserve(rng.uuid())
        case 18..<32:
            return .stop(callerID(&rng))
        case 32..<40:
            return .cancel(callerID(&rng))
        case 40..<92:
            if let step = runnerAnswer(&rng) { return step }
            return .reserve(rng.uuid())
        default:
            // Spurious runner events: unknown ids for every kind, stale ids for the
            // kinds that cannot be confused with a fresh open.
            let unknown = pick(refused, &rng) ?? rng.uuid()
            let stale = pick(staleIDs, &rng) ?? unknown
            switch Int.random(in: 0..<8, using: &rng) {
            case 0: return .opened(unknown, needsConnection: rng.chance(0.5))
            case 1: return .openFailed(unknown)
            case 2: return .openFailed(stale)
            case 3: return .connected(stale)
            case 4: return .captureEnded(stale)
            case 5: return .tailFinished(stale, keep: rng.chance(0.5))
            case 6: return .connected(unknown)
            default: return .tailFinished(unknown, keep: rng.chance(0.5))
            }
        }
    }

    private func runnerAnswer(_ rng: inout SplitMix64) -> Step? {
        var choices: [Step] = []
        if let id = pick(pendingOpens, &rng) {
            choices.append(rng.chance(0.2) ? .openFailed(id) : .opened(id, needsConnection: rng.chance(0.35)))
        }
        if let id = pick(pendingTails, &rng) { choices.append(.tailFinished(id, keep: rng.chance(0.7))) }
        if let id = pick(pendingConnects, &rng) { choices.append(.connected(id)) }
        let running = openCaptures.subtracting(endedCaptures).sorted { $0.uuidString < $1.uuidString }
        if rng.chance(0.3), let id = pick(running, &rng) { choices.append(.captureEnded(id)) }
        return pick(choices, &rng)
    }

    mutating func drain(_ rng: inout SplitMix64) -> Step? {
        if let id = pendingOpens.first {
            return rng.chance(0.2) ? .openFailed(id) : .opened(id, needsConnection: rng.chance(0.35))
        }
        if let id = pendingTails.first { return .tailFinished(id, keep: rng.chance(0.7)) }
        if let owner = state.owner { return rng.chance(0.5) ? .stop(owner) : .cancel(owner) }
        return nil
    }

    mutating func apply(_ event: Step) -> [String] {
        var v: [String] = []
        let pre = state
        let (post, effects) = RecorderCore.reduce(pre, event)
        state = post
        let id = event.sessionID

        // Runner bookkeeping for delivered answers.
        switch event {
        case .opened:
            if let index = pendingOpens.firstIndex(of: id) {
                pendingOpens.remove(at: index)
                openCaptures.insert(id)
            }
        case .openFailed:
            if let index = pendingOpens.firstIndex(of: id) {
                pendingOpens.remove(at: index)
                micReleases[id, default: 0] += 1
            }
        case .tailFinished:
            if let index = pendingTails.firstIndex(of: id) {
                pendingTails.remove(at: index)
                openCaptures.remove(id)
                endedCaptures.remove(id)
            }
        case .connected:
            pendingConnects.removeAll { $0 == id }
        case .captureEnded:
            if openCaptures.contains(id) { endedCaptures.insert(id) }
        case .reserve:
            if effects == [.open(id)] {
                accepted.append(id)
                acceptedSet.insert(id)
            } else if !acceptedSet.contains(id), !refused.contains(id) {
                refused.append(id)
            }
        case .stop:
            if pre.owner == id { stopOrCancelSent.insert(id); stopped.insert(id) }
        case .cancel:
            if pre.owner == id { stopOrCancelSent.insert(id); cancelled.insert(id) }
        }

        let fromRunner: Bool
        switch event {
        case .opened, .openFailed, .connected, .captureEnded, .tailFinished: fromRunner = true
        case .reserve, .stop, .cancel: fromRunner = false
        }

        // R1
        if (post.phase == .idle) != (post.owner == nil) {
            v.append("R1: phase \(post.phase) with owner \(String(describing: post.owner))")
        }

        // Terminal answers (R3) and their accounting.
        var terminalIDs: [UUID] = []
        if case .openFailed = event, pre.detached[id] == .discarding { terminalIDs.append(id) }

        for effect in effects {
            switch effect {
            case let .open(x):
                pendingOpens.append(x)
                opensEmitted[x, default: 0] += 1
            case let .monitorConnection(x):
                pendingConnects.append(x)
            case let .finishAfterTail(x):
                pendingTails.append(x)
                micReleases[x, default: 0] += 1
                if !openCaptures.contains(x) { v.append("R7: finishAfterTail(\(x)) for a capture that is not open") }
            case let .closeAndDiscard(x):
                openCaptures.remove(x)
                endedCaptures.remove(x)
                if opensEmitted[x] != nil { micReleases[x, default: 0] += 1 }
                // R2
                let nobodyOwnsThisOpen: Bool
                if case .opened = event, pre.owner != x, pre.detached[x] == nil { nobodyOwnsThisOpen = true } else { nobodyOwnsThisOpen = false }
                if stopped.contains(x) { v.append("R2: closeAndDiscard(\(x)) for a stopped session") }
                if !cancelled.contains(x) && !nobodyOwnsThisOpen {
                    v.append("R2: closeAndDiscard(\(x)) for a session that was not cancelled")
                }
                if cancelled.contains(x) { terminalIDs.append(x) }
            case let .reportStartFailure(x):
                terminalIDs.append(x)
            case let .resolveStop(x, _):
                if fromRunner { terminalIDs.append(x) }
            case let .notifyCaptureEnded(x):
                // R4
                notified[x, default: 0] += 1
                if notified[x]! > 1 { v.append("R4: notifyCaptureEnded(\(x)) twice") }
                if pre.owner != x || post.owner != x { v.append("R4: notifyCaptureEnded(\(x)) while not the owner") }
            case .publish, .refuse:
                break
            }
        }

        // R3
        for x in terminalIDs {
            terminals[x, default: 0] += 1
            if !acceptedSet.contains(x) { v.append("R3: terminal answer for \(x), which was never accepted") }
            if terminals[x]! > 1 { v.append("R3: second terminal answer for \(x) from \(event): \(effects)") }
            let isStartFailure = effects.contains(.reportStartFailure(x))
            if !isStartFailure && !stopOrCancelSent.contains(x) {
                v.append("R3: terminal answer for \(x) before any stop or cancel: \(effects)")
            }
        }

        // R5
        if case .reserve = event {
            if effects == [.refuse(id)], post != pre { v.append("R5: a refused reserve changed state") }
        } else if pre.owner != id && pre.detached[id] == nil {
            if post != pre { v.append("R5: \(event) for an unknown id changed state") }
            let allowed: [RecorderCore.Effect]
            switch event {
            case .stop: allowed = [.resolveStop(id, hasAudio: false)]
            case .opened: allowed = [.closeAndDiscard(id)]
            default: allowed = []
            }
            if effects != allowed { v.append("R5: \(event) for an unknown id emitted \(effects)") }
        }
        for key in Set(pre.detached.keys).union(post.detached.keys) where key != id {
            if pre.detached[key] != post.detached[key] { v.append("R5: \(event) changed another session's detached entry") }
        }
        if effects.contains(where: { $0.sessionID != nil && $0.sessionID != id }) {
            v.append("R5: \(event) emitted an effect for another session: \(effects)")
        }

        // R6
        let derived = post.published
        let lastPublish = effects.last { if case .publish = $0 { return true } else { return false } }
        if let last = lastPublish, last != .publish(isRecording: derived.isRecording, isConnecting: derived.isConnecting) {
            v.append("R6: last publish \(last) but state publishes \(derived)")
        }
        if pre.published != derived, lastPublish == nil {
            v.append("R6: published state changed from \(pre.published) to \(derived) without a publish")
        }

        // R7
        for (x, count) in micReleases where count > (opensEmitted[x] ?? 0) {
            v.append("R7: \(x) released the microphone \(count) times for \(opensEmitted[x] ?? 0) opens")
        }
        if post.owner == nil && post.detached.isEmpty {
            for (x, opens) in opensEmitted where micReleases[x, default: 0] != opens {
                v.append("R7: at rest, \(x) had \(opens) opens but \(micReleases[x, default: 0]) releases")
            }
            if !openCaptures.isEmpty { v.append("R7: at rest, captures still open: \(openCaptures)") }
        }

        return v
    }

    func finalViolations() -> [String] {
        var v: [String] = []
        for x in accepted where terminals[x, default: 0] != 1 {
            v.append("R3: \(x) got \(terminals[x, default: 0]) terminal answers once the runner was done")
        }
        if state.owner != nil || !state.detached.isEmpty { v.append("drain left \(state)") }
        if !pendingOpens.isEmpty || !pendingTails.isEmpty { v.append("drain left runner work") }
        return v
    }
}

final class RecorderCorePropertyTests: XCTestCase {
    func testInvariants() {
        PropertyCheck.run(RecorderModel.self, name: "RecorderCore")
    }
}
