import Foundation

/// Ownership and capture lifecycle of the single microphone recorder.
///
/// Models `AudioRecorder` (`sessionGate`, `startRecording`, `performStart`,
/// `stopRecording`, `cancelRecording`, `performStop`, the voice capture's
/// `onStopped`, and `audioRecorderDidFinishRecording`). Events are applied
/// atomically in arrival order. Effects are executed later, in order, by a
/// runner on a serial queue, which feeds its results back as events.
///
/// At most one session owns the recorder. A session that was stopped or
/// cancelled while its capture is still closing is `detached`: it no longer
/// owns the recorder, so a new session can start during its stop tail.
///
/// Transition table (`A` is the event's session id; "owner" means `owner == A`):
///
/// | Event | Condition | Transition | Effects |
/// |---|---|---|---|
/// | `reserve(A)` | `owner == nil` and `A` not detached | `owner = A`, `phase = .opening`, `notifiedEnded = false` | `open(A)` |
/// | `reserve(A)` | otherwise | unchanged | `refuse(A)` |
/// | `opened(A, n)` | owner, `phase == .opening` | `phase = n ? .connecting : .live` | `publish(!n, n)`, then `monitorConnection(A)` if `n` |
/// | `opened(A, _)` | owner, any other phase (duplicate) | unchanged | none |
/// | `opened(A, _)` | `detached[A] == .finishing` | unchanged (detached until `tailFinished`) | `finishAfterTail(A)` |
/// | `opened(A, _)` | `detached[A] == .discarding` | remove `detached[A]` | `closeAndDiscard(A)` |
/// | `opened(A, _)` | otherwise (nobody owns it) | unchanged | `closeAndDiscard(A)` |
/// | `openFailed(A)` | owner, `phase == .opening` | `owner = nil`, `phase = .idle` | `publish(false, false)`, `reportStartFailure(A)` |
/// | `openFailed(A)` | `detached[A] == .finishing` | remove `detached[A]` | `resolveStop(A, hasAudio: false)` |
/// | `openFailed(A)` | `detached[A] == .discarding` | remove `detached[A]` | none |
/// | `openFailed(A)` | otherwise | unchanged | none |
/// | `connected(A)` | owner, `phase == .connecting` | `phase = .live` | `publish(true, false)` |
/// | `connected(A)` | otherwise | unchanged | none |
/// | `captureEnded(A)` | owner, `phase` is `.connecting` or `.live` | `phase = .ended`, `notifiedEnded = true` | `publish(false, false)`, `notifyCaptureEnded(A)` |
/// | `captureEnded(A)` | otherwise (a detached tail still finishes) | unchanged | none |
/// | `stop(A)` | owner, `phase == .opening` | `owner = nil`, `phase = .idle`, `detached[A] = .finishing` | `publish(false, false)` |
/// | `stop(A)` | owner, any other phase | same | `publish(false, false)`, `finishAfterTail(A)` |
/// | `stop(A)` | not the owner | unchanged | `resolveStop(A, hasAudio: false)` |
/// | `cancel(A)` | owner, `phase == .opening` | `owner = nil`, `phase = .idle`, `detached[A] = .discarding` | `publish(false, false)` |
/// | `cancel(A)` | owner, any other phase | `owner = nil`, `phase = .idle` | `publish(false, false)`, `closeAndDiscard(A)` |
/// | `cancel(A)` | not the owner | unchanged | none |
/// | `tailFinished(A, keep)` | `detached[A] == .finishing` | remove `detached[A]` | `resolveStop(A, hasAudio: keep)` |
/// | `tailFinished(A, _)` | otherwise | unchanged | none |
public enum RecorderCore {
    /// The phase of the owner's capture.
    public enum Phase: Sendable, Hashable {
        case idle
        case opening
        case connecting
        case live
        /// The capture stopped on its own and the owner has not stopped it yet.
        case ended
    }

    public enum Detached: Sendable, Hashable {
        /// Stop requested: keep the audio.
        case finishing
        /// Cancel requested while the capture was still opening.
        case discarding
    }

    public struct State: Sendable, Hashable {
        public var owner: UUID?
        public var phase: Phase
        public var detached: [UUID: Detached]
        public var notifiedEnded: Bool

        public init() {
            owner = nil
            phase = .idle
            detached = [:]
            notifiedEnded = false
        }

        /// What the recorder publishes for the owner's capture.
        public var published: (isRecording: Bool, isConnecting: Bool) {
            (phase == .live, phase == .connecting)
        }
    }

    public enum Event: Sendable, Hashable {
        /// A caller asks to start.
        case reserve(UUID)
        /// Runner: the capture is open.
        case opened(UUID, needsConnection: Bool)
        /// Runner: the capture could not open.
        case openFailed(UUID)
        /// Runner: audio is flowing from a device that needed connecting.
        case connected(UUID)
        /// Runner: the open capture stopped on its own (either capture path).
        case captureEnded(UUID)
        /// The owner asks to stop and keep the audio.
        case stop(UUID)
        /// The owner asks to stop and discard.
        case cancel(UUID)
        /// Runner: the stop tail elapsed and the capture is closed;
        /// `keep` means it is long enough to use.
        case tailFinished(UUID, keep: Bool)
    }

    public enum Effect: Sendable, Hashable {
        case open(UUID)
        case publish(isRecording: Bool, isConnecting: Bool)
        case monitorConnection(UUID)
        case reportStartFailure(UUID)
        /// Tell the owner its capture stopped on its own; the audio so far is kept.
        case notifyCaptureEnded(UUID)
        /// Keep capturing the stop tail, then close and send `tailFinished`.
        case finishAfterTail(UUID)
        /// Close now and delete the audio.
        case closeAndDiscard(UUID)
        /// Answer the owner's pending stop.
        case resolveStop(UUID, hasAudio: Bool)
        /// Reserve refused: someone else owns the recorder.
        case refuse(UUID)
    }

    public static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var s = state
        let idle = Effect.publish(isRecording: false, isConnecting: false)

        switch event {
        case let .reserve(id):
            guard s.owner == nil, s.detached[id] == nil else { return (s, [.refuse(id)]) }
            s.owner = id
            s.phase = .opening
            s.notifiedEnded = false
            return (s, [.open(id)])

        case let .opened(id, needsConnection):
            if s.owner == id {
                guard s.phase == .opening else { return (s, []) }
                s.phase = needsConnection ? .connecting : .live
                var effects: [Effect] = [.publish(isRecording: !needsConnection, isConnecting: needsConnection)]
                if needsConnection {
                    effects.append(.monitorConnection(id))
                }
                return (s, effects)
            }
            switch s.detached[id] {
            case .finishing:
                return (s, [.finishAfterTail(id)])
            case .discarding:
                s.detached[id] = nil
                return (s, [.closeAndDiscard(id)])
            case nil:
                return (s, [.closeAndDiscard(id)])
            }

        case let .openFailed(id):
            if s.owner == id, s.phase == .opening {
                s.owner = nil
                s.phase = .idle
                return (s, [idle, .reportStartFailure(id)])
            }
            switch s.detached[id] {
            case .finishing:
                s.detached[id] = nil
                return (s, [.resolveStop(id, hasAudio: false)])
            case .discarding:
                s.detached[id] = nil
                return (s, [])
            case nil:
                return (s, [])
            }

        case let .connected(id):
            guard s.owner == id, s.phase == .connecting else { return (s, []) }
            s.phase = .live
            return (s, [.publish(isRecording: true, isConnecting: false)])

        case let .captureEnded(id):
            guard s.owner == id, s.phase == .connecting || s.phase == .live else { return (s, []) }
            s.phase = .ended
            s.notifiedEnded = true
            return (s, [idle, .notifyCaptureEnded(id)])

        case let .stop(id):
            guard s.owner == id else { return (s, [.resolveStop(id, hasAudio: false)]) }
            let prior = s.phase
            s.owner = nil
            s.phase = .idle
            s.detached[id] = .finishing
            return (s, prior == .opening ? [idle] : [idle, .finishAfterTail(id)])

        case let .cancel(id):
            guard s.owner == id else { return (s, []) }
            let prior = s.phase
            s.owner = nil
            s.phase = .idle
            if prior == .opening {
                s.detached[id] = .discarding
                return (s, [idle])
            }
            return (s, [idle, .closeAndDiscard(id)])

        case let .tailFinished(id, keep):
            guard s.detached[id] == .finishing else { return (s, []) }
            s.detached[id] = nil
            return (s, [.resolveStop(id, hasAudio: keep)])
        }
    }
}
