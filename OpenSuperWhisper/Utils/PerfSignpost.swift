import Darwin
import Foundation
import os

/// The user flows WorkFlow times. Each is one signpost interval in
/// Instruments (subsystem `com.picturesuo.WorkFlow.perf`, category `flow`).
enum PerfFlow: String, CaseIterable {
    case triggerToMicLive = "trigger_to_mic_live"
    case triggerToIndicatorVisible = "trigger_to_indicator_visible"
    /// startDecoding() accepted the stop -> delivery returned.
    case stopToDelivered = "stop_to_delivered"
    /// The recorder's stop, including its fixed tail.
    case stopTail = "stop_tail"
    /// finishDictation entry -> delivery returned.
    case finishDictation = "finish_dictation"
    case transcribe = "transcribe"
    case cleanup = "cleanup"
    case deliver = "deliver"
    case historyOpen = "history_open"
    case searchKeystroke = "search_keystroke"
    /// How long the main thread is blocked cancelling a just-started recording.
    case cancelAfterStart = "cancel_after_start"
}

/// Signpost intervals for the flows above, callable from any thread.
///
/// When the environment variable `WF_PERF_OUT` names a file, every ended
/// interval and every event is also appended to it as one JSON line, for the
/// benchmark in `Scripts/perf`. Without it nothing is written anywhere.
///
/// Privacy: a token (which can be the user's search text) is only compared in
/// memory and is never logged or written. Outcomes are fixed code strings.
enum PerfSignpost {
    private struct Interval {
        let state: OSSignpostIntervalState
        let start: ContinuousClock.Instant
        let token: String?
        let id: UInt64
        /// The main thread's CPU clock at `begin`, recorded only when
        /// `WF_PERF_OUT` is set and `begin` ran on the main thread.
        let mainCPUStart: UInt64?
    }

    private struct State {
        var intervals: [PerfFlow: Interval] = [:]
        var seq = 0
        var firedOnce: Set<String> = []
        var nextID: UInt64 = 0
    }

    private static let signposter = OSSignposter(subsystem: "com.picturesuo.WorkFlow.perf", category: "flow")
    /// Guards `State`; held only for dictionary updates, never for file I/O.
    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var value = State()

        func withLock<R>(_ body: (inout State) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private static let state = Locked()

    /// The `WF_PERF_OUT` file, opened once for appending. Guarded by its own
    /// lock so interval bookkeeping never waits on the disk.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?

        func append(_ bytes: [UInt8], to path: String) {
            lock.lock()
            defer { lock.unlock() }
            if descriptor == nil {
                let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
                guard fd >= 0 else { return }
                descriptor = fd
            }
            guard let fd = descriptor else { return }
            // One write(2) per record, so O_APPEND keeps each line whole.
            bytes.withUnsafeBytes { buffer in
                while Darwin.write(fd, buffer.baseAddress, buffer.count) < 0, errno == EINTR {}
            }
        }
    }

    private static let output = Output()
    private static let outputPath: String? = {
        guard let path = ProcessInfo.processInfo.environment["WF_PERF_OUT"], !path.isEmpty else { return nil }
        return path
    }()

    /// Starts `flow`. One still in flight is first ended as "superseded".
    /// Returns a process-unique id that `end(_:outcome:token:id:)` can match.
    @discardableResult
    static func begin(_ flow: PerfFlow, token: String? = nil) -> UInt64 {
        let signpostID = signposter.makeSignpostID()
        let newState = beginInterval(flow, id: signpostID)
        let mainCPUStart = outputPath != nil && Thread.isMainThread ? mainThreadCPUNanoseconds() : nil
        let (id, now, superseded): (UInt64, ContinuousClock.Instant, (Interval, Int)?) = state.withLock { state in
            // Taken under the lock, so a superseded interval never ends before it began.
            let now = ContinuousClock.now
            state.nextID += 1
            let previous = state.intervals[flow]
            state.intervals[flow] = Interval(state: newState, start: now, token: token, id: state.nextID, mainCPUStart: mainCPUStart)
            guard let previous else { return (state.nextID, now, nil) }
            state.seq += 1
            return (state.nextID, now, (previous, state.seq))
        }
        if let (previous, seq) = superseded {
            finish(flow, previous, outcome: "superseded", seq: seq, at: now)
        }
        return id
    }

    /// Ends `flow` if it is in flight. With a token, only the interval begun
    /// with the same token ends; with an id, only the interval whose `begin`
    /// returned that id.
    static func end(_ flow: PerfFlow, outcome: String = "ok", token: String? = nil, id: UInt64? = nil) {
        let ended: (Interval, Int, ContinuousClock.Instant)? = state.withLock { state in
            guard let interval = state.intervals[flow] else { return nil }
            if let token, interval.token != token { return nil }
            if let id, interval.id != id { return nil }
            state.intervals[flow] = nil
            state.seq += 1
            return (interval, state.seq, ContinuousClock.now)
        }
        if let (interval, seq, now) = ended {
            finish(flow, interval, outcome: outcome, seq: seq, at: now)
        }
    }

    /// Main thread only: ends `flow` once the current run loop pass has
    /// finished SwiftUI's update and the Core Animation commit, which run in
    /// `beforeWaiting` observers ordered before this one.
    static func endAfterRender(_ flow: PerfFlow, outcome: String = "ok", token: String? = nil) {
        guard isInFlight(flow, token: token) else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { _, _ in
            end(flow, outcome: outcome, token: token)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// A point event.
    static func event(_ name: String) {
        signposter.emitEvent("event", "\(name, privacy: .public)")
        guard outputPath != nil else { return }
        write(["event": name, "pid": Int(getpid())])
    }

    /// A point event carrying the milliseconds since this process started.
    static func eventSinceProcessStart(_ name: String) {
        let ms = millisecondsSinceProcessStart()
        signposter.emitEvent("event", "\(name, privacy: .public) \(ms ?? -1, format: .fixed(precision: 1))ms")
        guard outputPath != nil else { return }
        var line: [String: Any] = ["event": name, "pid": Int(getpid())]
        line["ms_since_process_start"] = ms ?? NSNull()
        write(line)
    }

    /// `eventSinceProcessStart`, at most once per process for each name.
    static func eventSinceProcessStartOnce(_ name: String) {
        let first = state.withLock { $0.firedOnce.insert(name).inserted }
        if first { eventSinceProcessStart(name) }
    }

    private static func isInFlight(_ flow: PerfFlow, token: String?) -> Bool {
        state.withLock { state in
            guard let interval = state.intervals[flow] else { return false }
            return token == nil || interval.token == token
        }
    }

    private static func finish(_ flow: PerfFlow, _ interval: Interval, outcome: String, seq: Int, at now: ContinuousClock.Instant) {
        endInterval(flow, interval.state, outcome: outcome)
        guard outputPath != nil else { return }
        let duration = interval.start.duration(to: now)
        let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        var line: [String: Any] = ["flow": flow.rawValue, "ms": ms, "outcome": outcome, "pid": Int(getpid()), "seq": seq]
        if let begin = interval.mainCPUStart, Thread.isMainThread {
            let end = mainThreadCPUNanoseconds()
            line["main_cpu_ms"] = Double(end &- begin) / 1e6
        }
        write(line)
    }

    /// CPU time the calling thread has used, in nanoseconds. Only meaningful
    /// when compared with another reading on the same thread.
    static func mainThreadCPUNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    private static func write(_ object: [String: Any]) {
        guard let outputPath,
              let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        output.append(Array(json) + [0x0A], to: outputPath)
    }

    /// From the kernel's record of when this process started.
    private static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        let seconds = Double(now.tv_sec - start.tv_sec) + Double(now.tv_usec - start.tv_usec) / 1_000_000
        return seconds * 1_000
    }

    // OSSignposter names must be static strings.
    private static func beginInterval(_ flow: PerfFlow, id: OSSignpostID) -> OSSignpostIntervalState {
        switch flow {
        case .triggerToMicLive: signposter.beginInterval("trigger_to_mic_live", id: id)
        case .triggerToIndicatorVisible: signposter.beginInterval("trigger_to_indicator_visible", id: id)
        case .stopToDelivered: signposter.beginInterval("stop_to_delivered", id: id)
        case .stopTail: signposter.beginInterval("stop_tail", id: id)
        case .finishDictation: signposter.beginInterval("finish_dictation", id: id)
        case .transcribe: signposter.beginInterval("transcribe", id: id)
        case .cleanup: signposter.beginInterval("cleanup", id: id)
        case .deliver: signposter.beginInterval("deliver", id: id)
        case .historyOpen: signposter.beginInterval("history_open", id: id)
        case .searchKeystroke: signposter.beginInterval("search_keystroke", id: id)
        case .cancelAfterStart: signposter.beginInterval("cancel_after_start", id: id)
        }
    }

    private static func endInterval(_ flow: PerfFlow, _ state: OSSignpostIntervalState, outcome: String) {
        switch flow {
        case .triggerToMicLive: signposter.endInterval("trigger_to_mic_live", state, "\(outcome, privacy: .public)")
        case .triggerToIndicatorVisible: signposter.endInterval("trigger_to_indicator_visible", state, "\(outcome, privacy: .public)")
        case .stopToDelivered: signposter.endInterval("stop_to_delivered", state, "\(outcome, privacy: .public)")
        case .stopTail: signposter.endInterval("stop_tail", state, "\(outcome, privacy: .public)")
        case .finishDictation: signposter.endInterval("finish_dictation", state, "\(outcome, privacy: .public)")
        case .transcribe: signposter.endInterval("transcribe", state, "\(outcome, privacy: .public)")
        case .cleanup: signposter.endInterval("cleanup", state, "\(outcome, privacy: .public)")
        case .deliver: signposter.endInterval("deliver", state, "\(outcome, privacy: .public)")
        case .historyOpen: signposter.endInterval("history_open", state, "\(outcome, privacy: .public)")
        case .searchKeystroke: signposter.endInterval("search_keystroke", state, "\(outcome, privacy: .public)")
        case .cancelAfterStart: signposter.endInterval("cancel_after_start", state, "\(outcome, privacy: .public)")
        }
    }
}
