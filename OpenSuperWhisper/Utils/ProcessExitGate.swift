import DictationCore
import Foundation

/// Runs ExitGateCore: counts native library calls in flight, refuses new ones
/// once the process is exiting, and lets shutdown wait for the rest.
///
/// whisper.cpp and ggml keep C++ statics whose destructors run during `exit`;
/// a call still running on another thread then touches destroyed state and
/// crashes the process. Every call into those libraries goes through `run`.
///
/// The gate must be closed before `exit` begins: `exit` destroys ggml's
/// function-local statics (the CPU extra-buffer-type list, the Metal device
/// list) in reverse order of creation, before any handler registered at
/// launch runs, so draining inside `exit` was tried and crashed (one SIGSEGV
/// in `ggml_cpu_extra_work_size` in 30 runs). The app closes it in
/// `applicationWillTerminate`; the hosted test bundle closes it when the test
/// run ends; a host that calls `exit` without either is not covered.
final class ProcessExitGate: @unchecked Sendable {
    /// The app waits up to 3 s, then leaves without running static
    /// destructors. A test host waits up to 120 s and never forces its exit.
    static let shared: ProcessExitGate = OpenSuperWhisperApp.isRunningTests
        ? ProcessExitGate(drainTimeout: 120, onAbandon: {})
        : ProcessExitGate(drainTimeout: 3, onAbandon: {
            // _exit skips the exit handlers that would otherwise flush preferences.
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            _exit(0)
        })

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
