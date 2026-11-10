import DictationCore
import Foundation

/// Runs ExitGateCore: counts native library calls in flight, refuses new ones
/// once the process is exiting, and lets exit wait for the rest.
///
/// whisper.cpp and ggml keep C++ statics (a mutex, the backend registry)
/// whose destructors run during `exit`. A call still running on another
/// thread then touches destroyed state and aborts the process. Every call
/// into those libraries goes through `run`, and the atexit handler installed
/// by `installAtExit` closes the gate and waits for the calls in flight.
final class ProcessExitGate: @unchecked Sendable {
    /// The app waits up to 3 s, then leaves without running static
    /// destructors. A test host waits up to 120 s and never forces its exit.
    static let shared: ProcessExitGate = OpenSuperWhisperApp.isRunningTests
        ? ProcessExitGate(drainTimeout: 120, onAbandon: {})
        : ProcessExitGate(drainTimeout: 3, onAbandon: { _exit(0) })

    private let condition = NSCondition()
    private var state = ExitGateCore.State()
    private let drainTimeout: TimeInterval
    private let onAbandon: @Sendable () -> Void

    init(drainTimeout: TimeInterval, onAbandon: @escaping @Sendable () -> Void) {
        self.drainTimeout = drainTimeout
        self.onAbandon = onAbandon
    }

    /// True once `shutdown` has begun.
    var isExiting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return state.phase != .open
    }

    /// Calls running inside `run` right now. Tests use it to time an exit.
    var inFlightCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return state.inFlight
    }

    /// Runs `body` unless the process is exiting; nil means refused.
    func run<T>(_ body: () throws -> T) rethrows -> T? {
        condition.lock()
        let effects = send(.enter)
        condition.unlock()

        var admitted = false
        for effect in effects {
            switch effect {
            case .admit: admitted = true
            case .refuse: return nil
            case .awaitDrain, .drained, .abandon: break
            }
        }
        guard admitted else { return nil }
        defer {
            condition.lock()
            _ = send(.leave)
            condition.unlock()
        }
        return try body()
    }

    /// Refuses new work and blocks until in-flight calls have returned or the
    /// timeout passes. Idempotent.
    func shutdown() {
        condition.lock()
        var effects = send(.shutdown)
        if effects.contains(.awaitDrain) {
            let deadline = Date().addingTimeInterval(drainTimeout)
            while state.phase != .closed {
                if !condition.wait(until: deadline) {
                    effects += send(.timeout)
                }
            }
        }
        condition.unlock()
        if effects.contains(.abandon) {
            onAbandon()
        }
    }

    /// Registers `shared.shutdown()` with atexit, once.
    static func installAtExit() {
        _ = atExitRegistration
    }

    private static let atExitRegistration: Void = {
        atexit {
            ProcessExitGate.shared.shutdown()
        }
    }()

    /// Applies one event through the reducer and returns its effects.
    /// Caller holds `condition`.
    private func send(_ event: ExitGateCore.Event) -> [ExitGateCore.Effect] {
        let (next, effects) = ExitGateCore.reduce(state, event)
        state = next
        if effects.contains(.drained) {
            condition.broadcast()
        }
        return effects
    }
}
