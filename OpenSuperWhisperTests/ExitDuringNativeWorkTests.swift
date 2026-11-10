import Foundation
import XCTest
@testable import OpenSuperWhisper

/// Opt-in end-to-end reproduction: the test host exits while the bundled
/// speech detector is inside whisper.cpp on a background thread. Without
/// ProcessExitGate, exit destroys ggml's statics under the running call and
/// the host aborts; with it, exit waits for the call to return.
///
/// Run alone, with `TEST_RUNNER_WF_EXIT_REPRO=1`. Optional
/// `TEST_RUNNER_WF_EXIT_REPRO_LOG` names a file that receives timestamped
/// marks, including one when exit begins and one when the call returns;
/// the long recording is written next to it.
final class ExitDuringNativeWorkTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Read by the C atexit callback, which can't capture context.
    nonisolated(unsafe) private static var logPath: String?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["WF_EXIT_REPRO"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_WF_EXIT_REPRO=1 and run this class alone")
        }
    }

    private static func mark(_ event: String) {
        guard let logPath else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, event)
        guard let handle = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)
        }() else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.synchronize()
        try? handle.close()
    }

    func testHostExitsWhileTheDetectorIsInsideWhisperCpp() async throws {
        Self.logPath = ProcessInfo.processInfo.environment["WF_EXIT_REPRO_LOG"]
        // Registered after the app's own handler, so it runs first at exit.
        atexit { ExitDuringNativeWorkTests.mark("exit begins") }

        // At least 10 minutes of 16 kHz mono speech, from jfk.wav repeated.
        let converted = try await WhisperEngine().convertAudioToPCM(fileURL: Self.root.appendingPathComponent("jfk.wav"))
        let jfk = try XCTUnwrap(converted)
        var samples: [Float] = []
        samples.reserveCapacity(16_000 * 610)
        while samples.count < 16_000 * 600 { samples += jfk }
        // Next to the log when one is named, so its owner can remove it after
        // the host has exited; the recording outlives this test by design.
        let folder = Self.logPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.temporaryDirectory
        let long = folder.appendingPathComponent("exit-repro-\(UUID().uuidString).wav")
        try writeWAV(samples, to: long)

        // Load the detector's model first, so the only native call left is
        // the detection over the long recording.
        let detector = SileroSpeechDetector()
        _ = try await detector.detectSpeech(in: Self.root.appendingPathComponent("jfk.wav"))
        XCTAssertEqual(ProcessExitGate.shared.inFlightCount, 0)

        Self.mark("detection starts")
        Task.detached {
            let detection = try? await detector.detectSpeech(in: long)
            ExitDuringNativeWorkTests.mark("detection returned intervals=\(detection?.intervals.count ?? -1)")
        }

        let deadline = Date().addingTimeInterval(120)
        while ProcessExitGate.shared.inFlightCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(ProcessExitGate.shared.inFlightCount, 1, "The detection is inside whisper.cpp")
        Self.mark("test returns with the detection in flight")
        // Returning now lets XCTest exit the host while the call runs.
    }
}
