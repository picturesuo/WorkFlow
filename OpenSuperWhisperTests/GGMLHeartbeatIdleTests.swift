import Darwin
import XCTest
@testable import OpenSuperWhisper

/// Opt-in proof that ggml's Metal residency heartbeat stops waking once its
/// keep-alive expires (libwhisper/patches/ggml-metal-rsets-idle-heartbeat.patch).
/// The keep-alive length is read once, when the ggml backend registry starts
/// the Metal device, so this must run alone in a fresh test host: pass
/// `TEST_RUNNER_WF_HEARTBEAT_TEST=1` to xcodebuild and `-only-testing` this
/// class. No microphone, playback, provider, pasteboard, or keystroke is used.
final class GGMLHeartbeatIdleTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["WF_HEARTBEAT_TEST"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_WF_HEARTBEAT_TEST=1 and run this class alone in a fresh test host")
        }
    }

    /// Context switches of every thread in this process so far, from
    /// `task_info(TASK_EVENTS_INFO).csw`.
    private func contextSwitches() throws -> Int64 {
        var info = task_events_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(result))
        }
        return Int64(info.csw)
    }

    private func contextSwitches(over seconds: Double) async throws -> Int64 {
        let start = try contextSwitches()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return try contextSwitches() - start
    }

    func testHeartbeatStopsWakingOnceItsKeepAliveExpires() async throws {
        // Before anything builds the ggml backend registry: keep residency
        // alive for 1 s instead of 180 s.
        setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", "1", 1)

        let before = try await contextSwitches(over: 2.0)

        // The bundled Silero VAD, created the way SileroSpeechDetector does.
        // It runs on the CPU, but creating it builds the ggml backend
        // registry, which starts the Metal device and its heartbeat.
        let vadPath = try XCTUnwrap(WhisperEngine.vadModelPath)
        var vad: MyWhisperVadContext? = try XCTUnwrap(MyWhisperVadContext(modelPath: vadPath))

        // Diagnostic only: the first 0.5 s, while the 1 s keep-alive runs.
        let active = try await contextSwitches(over: 0.5)
        try await Task.sleep(nanoseconds: 2_500_000_000)

        let afterExpiry = try await contextSwitches(over: 2.0)
        print("GGMLHeartbeatIdleTests: context switches over 2.0 s before=\(before) afterExpiry=\(afterExpiry) delta=\(afterExpiry - before); over 0.5 s while active=\(active)")
        // The unpatched heartbeat wakes every 5 ms forever: about 400 in 2 s.
        XCTAssertLessThan(afterExpiry - before, 100)

        let started = Date()
        let audio = Self.root.appendingPathComponent("jfk.wav")
        let converted = try await WhisperEngine().convertAudioToPCM(fileURL: audio)
        let samples = try XCTUnwrap(converted)
        let segments = try XCTUnwrap(vad?.speechSegments(in: samples))
        XCTAssertFalse(segments.isEmpty)
        vad = nil
        let vadElapsed = Date().timeIntervalSince(started)
        print("GGMLHeartbeatIdleTests: VAD pass and free took \(String(format: "%.2f", vadElapsed)) s")
        XCTAssertLessThan(vadElapsed, 10)

        // The VAD never computes on the GPU, so it never calls the keep-alive.
        // A Whisper pass on Metal does: it must wake the idle heartbeat and
        // finish, and freeing its buffers must not deadlock against it.
        let metalStarted = Date()
        do {
            let engine = WhisperEngine()
            try engine.load(modelPath: Self.root.appendingPathComponent("ggml-tiny.en.bin").path)
            let text = try await engine.transcribeAudio(url: audio, settings: OpenSuperWhisper.Settings())
            let afterKeepAlive = try await contextSwitches(over: 0.5)
            // Baseline: this process idle with the heartbeat blocked, per 0.5 s.
            let idle = afterExpiry / 4
            print("GGMLHeartbeatIdleTests: context switches over 0.5 s after a Metal pass afterKeepAlive=\(afterKeepAlive) idleBaseline=\(idle)")
            XCTAssertTrue(text.lowercased().contains("country"), text)
            // Awake again, it polls every 5 ms for the 1 s keep-alive.
            XCTAssertGreaterThan(afterKeepAlive - idle, 50)
        }
        let metalElapsed = Date().timeIntervalSince(metalStarted)
        print("GGMLHeartbeatIdleTests: Metal pass and free took \(String(format: "%.2f", metalElapsed)) s")
        // Generous: a fresh process compiles its Metal pipelines on this first pass.
        XCTAssertLessThan(metalElapsed, 30)
    }
}
