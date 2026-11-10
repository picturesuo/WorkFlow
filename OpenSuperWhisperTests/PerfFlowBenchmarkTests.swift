import AppKit
import AVFoundation
import GRDB
import KeyboardShortcuts
import QuartzCore
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

// Opt-in benchmark of WorkFlow's user flows, timed by the app's own
// PerfSignpost intervals. Every test skips unless `WF_PERF_OUT` (passed to
// xcodebuild as `TEST_RUNNER_WF_PERF_OUT`) names the JSON-lines file the
// signposts and this suite append to; `Scripts/perf/report.py` summarizes it.
// Only synthetic History and the repository's public-domain `jfk.wav` are
// used. Nothing writes the general pasteboard, posts a keystroke, plays a
// sound, registers a global hotkey, calls a provider, or shows a visible
// window: the windows here are alpha 0 and ignore the mouse.

// MARK: - Output

/// Appends to and follows the shared `WF_PERF_OUT` file.
final class PerfBenchOutput {
    static let shared: PerfBenchOutput? = ProcessInfo.processInfo.environment["WF_PERF_OUT"]
        .flatMap { $0.isEmpty ? nil : PerfBenchOutput(path: $0) }

    let url: URL
    private var reader: FileHandle?
    private var buffer = Data()
    /// Every line read so far, in file order.
    private(set) var lines: [[String: Any]] = []

    private init(path: String) {
        url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        reader = FileHandle(forReadingAtPath: path)
    }

    /// One write(2) per line on an O_APPEND descriptor, the same as
    /// PerfSignpost, so concurrent records never overwrite each other.
    func append(_ object: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let bytes = Array(json) + [0x0A]
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        bytes.withUnsafeBytes { buffer in
            while Darwin.write(fd, buffer.baseAddress, buffer.count) < 0, errno == EINTR {}
        }
    }

    func marker(_ name: String, section: String? = nil, index: Int? = nil) {
        var line: [String: Any] = ["marker": name]
        if let section { line["section"] = section }
        if let index { line["index"] = index }
        append(line)
    }

    /// Reads whatever was appended since the last call.
    @discardableResult
    func poll() -> Int {
        guard let reader else { return lines.count }
        buffer.append(reader.readDataToEndOfFile())
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                lines.append(object)
            }
        }
        return lines.count
    }
}

// MARK: - Main-thread hang watchdog

/// Every 10 ms a background thread hands the main queue a block and measures
/// how long the main thread takes to run it.
final class MainThreadHangWatchdog {
    private let lock = NSLock()
    private var generation = 0
    private var stalls = 0
    private var maxStallMs = 0.0
    private var thread: Thread?

    func start() {
        lock.lock()
        generation += 1
        let mine = generation
        stalls = 0
        maxStallMs = 0
        lock.unlock()
        let thread = Thread { [weak self] in self?.loop(mine) }
        thread.name = "perf-hang-watchdog"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func loop(_ mine: Int) {
        while true {
            lock.lock()
            let keepRunning = generation == mine
            lock.unlock()
            guard keepRunning else { return }
            let semaphore = DispatchSemaphore(value: 0)
            let start = ContinuousClock.now
            DispatchQueue.main.async { semaphore.signal() }
            semaphore.wait()
            let stall = start.duration(to: .now)
            let ms = Double(stall.components.seconds) * 1_000 + Double(stall.components.attoseconds) / 1e15
            lock.lock()
            guard generation == mine else { lock.unlock(); return }
            if ms >= 250 { stalls += 1 }
            maxStallMs = max(maxStallMs, ms)
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func stop() -> (count: Int, maxStallMs: Double) {
        lock.lock()
        generation += 1
        let result = (stalls, maxStallMs)
        lock.unlock()
        thread = nil
        return result
    }
}

// MARK: - Frame hitch meter

/// Hitch time per second of frames, from the window's own display link.
final class FrameHitchMeter: NSObject {
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var hitchSeconds: CFTimeInterval = 0
    private var frames = 0
    private var started = ContinuousClock.now

    func start(on window: NSWindow) {
        previous = nil
        hitchSeconds = 0
        frames = 0
        started = .now
        let link = window.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        frames += 1
        if let previous {
            let expected = link.targetTimestamp - link.timestamp
            hitchSeconds += max(0, (link.timestamp - previous) - expected)
        }
        previous = link.timestamp
    }

    func stop() -> (msPerSecond: Double, frames: Int, seconds: Double) {
        link?.invalidate()
        link = nil
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (seconds > 0 ? hitchSeconds * 1_000 / seconds : 0, frames, seconds)
    }
}

// MARK: - Suite

@MainActor
final class PerfFlowBenchmarkTests: XCTestCase {
    private static let words = [
        "river", "garden", "window", "paper", "bridge", "orange", "silver", "market", "planet", "candle",
        "forest", "pencil", "basket", "mirror", "ladder", "harbor", "valley", "meadow", "copper", "lantern",
        "table", "chair", "cloud", "stone", "field", "north", "south", "early", "later", "quiet",
        "simple", "yellow", "purple", "number", "letter", "report", "budget", "travel", "dinner", "coffee",
        "music", "story", "train", "plane", "light", "green", "water", "sugar", "bread", "apple",
        "the", "and", "with", "from", "into", "over", "under", "after", "before", "around",
        "about", "every", "other", "small", "large", "short", "long", "happy", "ready", "clear"
    ]
    private static let queries = ["river", "garden", "copper", "meadow", "zqxjv", "bread", "lantern", "north", "coffee", "stone"]
    private static let jfkURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("jfk.wav")

    private var output: PerfBenchOutput!
    private var iterations = 12
    private let watchdog = MainThreadHangWatchdog()
    private static var didHandshake = false

    override func setUp() async throws {
        guard let output = PerfBenchOutput.shared else {
            throw XCTSkip("Set TEST_RUNNER_WF_PERF_OUT to run the perf flow benchmark")
        }
        self.output = output
        iterations = max(2, Int(ProcessInfo.processInfo.environment["WF_PERF_ITERATIONS"] ?? "") ?? 12)
        Self.disableEveryHotkey()
        try await Self.traceHandshakeIfRequested(output)
    }

    // MARK: Shared helpers

    /// Disables both shortcuts in this test host's own defaults domain before
    /// either name is first touched: the first touch of a name that has no
    /// stored value registers its default with Carbon. A stored `false` makes
    /// KeyboardShortcuts treat the name as having no shortcut, so enabling it
    /// registers nothing.
    private static func disableEveryHotkey() {
        for key in ["KeyboardShortcuts_toggleRecord", "KeyboardShortcuts_escape"]
        where UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(false, forKey: key)
        }
        // A shortcut stored earlier is unregistered and disabled here.
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecord)
        KeyboardShortcuts.setShortcut(nil, for: .escape)
        let prefs = AppPreferences.shared
        // The plain key combination (now empty): no event tap, no mouse monitor.
        prefs.modifierOnlyHotkey = "none"
        prefs.secondaryModifierOnlyHotkey = "none"
        prefs.mouseButtonHotkey = "none"
        prefs.modifierChordHotkey = "none"
        prefs.holdToRecord = false
        prefs.doublePressToTrigger = false
        prefs.playSoundOnRecordStart = false
        prefs.reduceBackgroundAudio = false
        // A dictation from the shared pipeline is saved only: no cleanup
        // provider, no pasteboard, no keystroke.
        prefs.bedrockCleanupEnabled = false
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.selectedEngine = "fluidaudio"
        prefs.fluidAudioModelVersion = "v3"
        prefs.whisperLanguage = "en"
        precondition(RecordingTriggerConfiguration() == .keyCombination)
        precondition(KeyboardShortcuts.getShortcut(for: .toggleRecord) == nil)
        precondition(KeyboardShortcuts.getShortcut(for: .escape) == nil)
    }

    /// With `WF_PERF_WAIT_FOR_TRACE=1`, publishes the pid and waits for the
    /// driver to attach xctrace and create `<out>.go`.
    private static func traceHandshakeIfRequested(_ output: PerfBenchOutput) async throws {
        guard !didHandshake else { return }
        didHandshake = true
        guard ProcessInfo.processInfo.environment["WF_PERF_WAIT_FOR_TRACE"] == "1" else { return }
        let pidURL = URL(fileURLWithPath: output.url.path + ".pid")
        let goPath = output.url.path + ".go"
        try "\(getpid())\n".write(to: pidURL, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: goPath), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        output.marker("trace_go", section: FileManager.default.fileExists(atPath: goPath) ? "attached" : "timeout")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// The first line for `flow` appended after line index `mark`.
    private func waitForFlow(_ flow: PerfFlow, after mark: Int, timeout: TimeInterval) async throws -> [String: Any]? {
        var found: [String: Any]?
        _ = try await waitUntil(timeout: timeout) {
            output.poll()
            found = output.lines[mark...].first { $0["flow"] as? String == flow.rawValue }
            return found != nil
        }
        return found
    }

    private func beginSection(_ section: String) {
        output.marker("\(section)_begin", section: section)
        watchdog.start()
    }

    private func endSection(_ section: String) {
        let hangs = watchdog.stop()
        output.append(["metric": "hangs_over_250ms", "section": section, "count": hangs.count, "max_stall_ms": hangs.maxStallMs])
        output.marker("\(section)_end", section: section)
    }

    private func iteration(_ index: Int, of section: String) {
        output.marker("iteration", section: section, index: index)
    }

    /// Orders out every window of this test host except `window`, so the
    /// host's own WindowGroup window never reaches the owner's screen.
    private func hideOtherWindows(except window: NSWindow) {
        for other in NSApp.windows where other !== window {
            other.orderOut(nil)
        }
    }

    private struct VisibleWindowError: Error {}

    /// Fails hard if any on-screen window of this process is not fully
    /// transparent.
    private func assertNothingVisible() throws {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let pid = getpid()
        let visible = info.filter { entry in
            (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
        }
        guard visible.isEmpty else {
            let names = visible.map { "\($0[kCGWindowNumber as String] ?? "?") alpha \($0[kCGWindowAlpha as String] ?? "?")" }
            XCTFail("A test host window is visible on screen: \(names.joined(separator: ", "))")
            throw VisibleWindowError()
        }
    }

    /// The shared service's real Parakeet engine, loaded before any timing.
    private func readyTranscriptionService() async throws -> TranscriptionService {
        let modelDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDirectory.path),
                          "The cached Parakeet v3 model is required; this suite never downloads it")
        let service = TranscriptionService.shared
        let loaded = try await waitUntil(timeout: 300) { !service.isLoading }
        XCTAssertTrue(loaded, "The engine did not finish loading")
        return service
    }

    /// Microphone access as macOS reports it to this test host, without asking.
    private func requireMicrophoneWithoutPrompt() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let name: String = switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
        output.append(["metric": "microphone_authorization", "status": name])
        if status == .notDetermined {
            throw XCTSkip("Microphone access is not determined for this test host; starting the recorder would raise the system prompt, so this flow is skipped")
        }
        try XCTSkipIf(MicrophoneService.shared.getActiveMicrophone() == nil, "No input device")
    }

    /// The indicator panel is built now and kept invisible: alpha 0 and
    /// click-through, so ordering it in never shows the owner a capsule.
    private func prepareInvisibleIndicator() {
        let manager = IndicatorWindowManager.shared
        manager.warmUp()
        guard let window = manager.window else { return XCTFail("The indicator panel was not built") }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    private func waitForIndicatorIdle() async throws {
        let idle = try await waitUntil(timeout: 20) {
            IndicatorWindowManager.shared.viewModel == nil
                && !AudioRecorder.shared.isRecording && !AudioRecorder.shared.isConnecting
        }
        XCTAssertTrue(idle, "The indicator did not hide")
        XCTAssertEqual(IndicatorWindowManager.shared.window?.alphaValue ?? 0, 0)
        try await Task.sleep(for: .milliseconds(300))
    }

    // MARK: Flow 1: press to microphone live, and stop through the same press

    func testTriggerToMicLive() async throws {
        try requireMicrophoneWithoutPrompt()
        _ = try await readyTranscriptionService()
        prepareInvisibleIndicator()
        let manager = ShortcutManager.shared
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .toggleRecord))

        let section = "trigger"
        beginSection(section)
        for index in 0..<iterations {
            iteration(index, of: section)
            let mark = output.poll()
            manager.handleKeyDown()
            let live = try await waitForFlow(.triggerToMicLive, after: mark, timeout: 10)
            XCTAssertNotNil(live, "No trigger_to_mic_live within 10 s")
            if live?["outcome"] as? String != "ok" { output.append(["metric": "trigger_failed", "outcome": live?["outcome"] ?? "timeout"]) }
            try await Task.sleep(for: .milliseconds(600))
            let stopMark = output.poll()
            manager.handleKeyDown()
            let delivered = try await waitForFlow(.stopToDelivered, after: stopMark, timeout: 60)
            XCTAssertNotNil(delivered, "The stopped dictation never finished")
            try await waitForIndicatorIdle()
        }
        endSection(section)
    }

    // MARK: Flow 1b: cancel right after the press

    func testCancelRightAfterStart() async throws {
        try requireMicrophoneWithoutPrompt()
        _ = try await readyTranscriptionService()
        prepareInvisibleIndicator()
        let manager = ShortcutManager.shared

        let section = "cancel_after_start"
        beginSection(section)
        for index in 0..<iterations {
            iteration(index, of: section)
            manager.handleKeyDown()
            let pressed = try await waitUntil(timeout: 10) { IndicatorWindowManager.shared.viewModel != nil }
            XCTAssertTrue(pressed, "The press never reached the main thread")
            PerfSignpost.begin(.cancelAfterStart)
            IndicatorWindowManager.shared.stopForce()
            PerfSignpost.end(.cancelAfterStart)
            try await waitForIndicatorIdle()
        }
        endSection(section)
    }

    // MARK: Flow 2: stop to delivered text

    func testStopToDeliveredLocal() async throws {
        try await runStopToDelivered(section: "stop_local", pipeline: TranscriptCleanupPipeline(
            isEnabled: { false },
            providerResolver: { throw CleanupProviderError.missingCredential("none") },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) },
            autoConfigProvider: { nil },
            failureRecorder: { _ in }
        ), expectedCleanupSource: nil)
    }

    func testStopToDeliveredCloudStub() async throws {
        // OpenAI's real request and reply code, answered in process by a
        // fixture that echoes the transcript at once. The key is a placeholder.
        ProviderFixtureProtocol.reset()
        let session = ProviderFixtureProtocol.session()
        defer {
            session.invalidateAndCancel()
            ProviderFixtureProtocol.reset()
        }
        ProviderFixtureProtocol.handler = { _, body in
            let json = ProviderFixtureProtocol.json(body)
            let messages = json["messages"] as? [[String: Any]] ?? []
            let user = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
            var transcript = user
            if let open = user.range(of: "<transcript>\n"), let close = user.range(of: "\n</transcript>", options: .backwards) {
                transcript = String(user[open.upperBound..<close.lowerBound])
            }
            return .http(status: 200, body: ProviderFixtureReplies.openAI(transcript))
        }
        let environment = CleanupProviderFactory.Environment(
            loadBedrockKey: { nil },
            loadCleanupKey: { _ in "perf-bench-placeholder" },
            session: session,
            bedrockService: BedrockCleanupService(session: session)
        )
        AppPreferences.shared.openAITimeoutSeconds = 10
        let provider = try CleanupProviderFactory.make(.openAI, environment: environment)
        try await runStopToDelivered(section: "stop_cloud_stub", pipeline: TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { provider },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) },
            autoConfigProvider: { nil },
            failureRecorder: { _ in }
        ), expectedCleanupSource: .openAI)
        XCTAssertGreaterThanOrEqual(ProviderFixtureProtocol.requests.count, iterations)
        XCTAssertTrue(ProviderFixtureProtocol.requests.allSatisfy { $0.request.url?.host == "api.openai.com" })
    }

    private func runStopToDelivered(
        section: String,
        pipeline: TranscriptCleanupPipeline,
        expectedCleanupSource: TranscriptCleanupOutcome.Source?
    ) async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.jfkURL.path), "jfk.wav is missing")
        let service = try await readyTranscriptionService()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WorkFlowPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try RecordingStore(
            database: DatabaseQueue(path: scratch.appendingPathComponent("history.sqlite").path),
            recordingsDirectory: scratch.appendingPathComponent("recordings"),
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        let gate = LatestDictationGate()
        let pasteboard = NSPasteboard(name: .init("workflow-perf-bench"))
        defer { pasteboard.releaseGlobally() }

        beginSection(section)
        for index in 0..<iterations {
            iteration(index, of: section)
            let copy = scratch.appendingPathComponent("\(UUID().uuidString).wav")
            try FileManager.default.copyItem(at: Self.jfkURL, to: copy)
            let viewModel = IndicatorViewModel(
                latestDictationGate: gate,
                transcriptionService: service,
                recordingStore: store,
                cleanupPipeline: pipeline,
                delivery: { text in
                    ClipboardUtil.insertText(text, targetPID: nil, pasteboard: pasteboard, restoreDelay: 0.05,
                                             paste: { _ in true }) ? .pasteSent : .pasteFailed
                }
            )
            let mark = output.poll()
            await viewModel.finishDictation(audioAt: copy, generation: gate.begin(), recordingStartedAt: Date(),
                                            stoppedAt: .now)
            viewModel.cleanup()
            let line = try await waitForFlow(.finishDictation, after: mark, timeout: 5)
            XCTAssertEqual(line?["outcome"] as? String, "paste_sent")
        }
        endSection(section)

        // Saving runs in the background after delivery; wait for the last row.
        var saved: [Recording] = []
        let deadline = Date().addingTimeInterval(20)
        repeat {
            saved = try await store.fetchRecordings(limit: 1_000, offset: 0)
            if saved.count >= iterations { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        XCTAssertEqual(saved.count, iterations)
        // Let the background speech measurement of the last rows finish
        // before the database folder is removed.
        try await Task.sleep(for: .seconds(2))
        if let expectedCleanupSource {
            let matching = saved.filter { $0.cleanupSource == expectedCleanupSource }.count
            output.append(["metric": "cleanup_source", "section": section, "expected": "\(expectedCleanupSource)",
                           "matching": matching, "total": saved.count])
            XCTAssertEqual(matching, saved.count, "Every dictation went through the stubbed provider")
        }
        // The view model moves each recording's audio into the test host's
        // own temporary History folder.
        for recording in saved { try? FileManager.default.removeItem(at: recording.url) }
    }

    // MARK: Flow 3: History open, scroll, and search

    func testHistoryOpenAndSearch() async throws {
        _ = try await readyTranscriptionService()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WorkFlowPerfHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var database: DatabaseQueue? = try DatabaseQueue(path: scratch.appendingPathComponent("history.sqlite").path)
        var store: RecordingStore? = try RecordingStore(
            database: database!,
            recordingsDirectory: scratch.appendingPathComponent("recordings"),
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        // The database is closed and released before its folder is removed.
        defer {
            store = nil
            try? database?.close()
            database = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        try await seed(store!, count: 1_200)
        let pasteboard = NSPasteboard(name: .init("workflow-perf-bench-history"))
        defer { pasteboard.releaseGlobally() }

        var openHangs: (Int, Double) = (0, 0)
        var scrollHangs: (Int, Double) = (0, 0)
        var searchHangs: (Int, Double) = (0, 0)
        var hitches: [String: (ms: Double, frames: Int, seconds: Double)] = [:]
        func addHitch(_ section: String, _ value: (msPerSecond: Double, frames: Int, seconds: Double)) {
            let old = hitches[section] ?? (0, 0, 0)
            // Accumulate total hitch milliseconds, then divide once at the end.
            hitches[section] = (old.ms + value.msPerSecond * value.seconds, old.frames + value.frames, old.seconds + value.seconds)
        }
        func addHang(_ total: inout (Int, Double), _ value: (count: Int, maxStallMs: Double)) {
            total = (total.0 + value.count, max(total.1, value.maxStallMs))
        }

        for section in ["history_open", "history_scroll", "history_search"] { output.marker("\(section)_begin", section: section) }
        for index in 0..<iterations {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.isReleasedWhenClosed = false
            let viewModel = ContentViewModel(recordingStore: store!)
            let content = ContentView(
                viewModel: viewModel,
                permissionsManager: PermissionsManager(microphone: true, accessibility: true, inputMonitoring: true)
            )
            .environment(\.transcriptPasteboard, pasteboard.name)
            window.contentView = NSHostingView(rootView: content)

            // Open.
            iteration(index, of: "history_open")
            let meter: FrameHitchMeter? = FrameHitchMeter()
            watchdog.start()
            meter?.start(on: window)
            let openMark = output.poll()
            PerfSignpost.begin(.historyOpen)
            hideOtherWindows(except: window)
            window.orderFrontRegardless()
            hideOtherWindows(except: window)
            try assertNothingVisible()
            let opened = try await waitForFlow(.historyOpen, after: openMark, timeout: 20)
            XCTAssertEqual(opened?["outcome"] as? String, "ok")
            try await Task.sleep(for: .milliseconds(300))
            if let meter { addHitch("history_open", meter.stop()) }
            addHang(&openHangs, watchdog.stop())

            // Scroll.
            iteration(index, of: "history_scroll")
            let scrollView = Self.views(of: NSScrollView.self, in: window.contentView!)
                .max { $0.frame.height < $1.frame.height }
            XCTAssertNotNil(scrollView, "No History scroll view")
            watchdog.start()
            meter?.start(on: window)
            if let scrollView {
                let clip = scrollView.contentView
                let scrollStart = ContinuousClock.now
                let cpuStart = PerfSignpost.mainThreadCPUNanoseconds()
                while scrollStart.duration(to: .now) < .seconds(2) {
                    var origin = clip.bounds.origin
                    origin.y += clip.isFlipped ? 24 : -24
                    clip.scroll(to: origin)
                    scrollView.reflectScrolledClipView(clip)
                    try await Task.sleep(for: .milliseconds(8))
                }
                let cpuEnd = PerfSignpost.mainThreadCPUNanoseconds()
                output.append(["metric": "main_cpu_ms", "section": "history_scroll",
                               "value": Double(cpuEnd &- cpuStart) / 1e6, "iteration": index])
                output.append(["metric": "scroll_offset", "section": "history_scroll", "y": Double(clip.bounds.origin.y)])
            }
            if let meter { addHitch("history_scroll", meter.stop()) }
            addHang(&scrollHangs, watchdog.stop())

            // Search, one character at a time through the field's delegate.
            iteration(index, of: "history_search")
            let field = Self.views(of: NSSearchField.self, in: window.contentView!).first
            XCTAssertNotNil(field, "No search field")
            watchdog.start()
            meter?.start(on: window)
            if let field {
                let query = Self.queries[index % Self.queries.count]
                var typed = ""
                for character in query + "\u{8}" {
                    typed = character == "\u{8}" ? "" : typed + String(character)
                    // Clearing skips the debounce, so the report keeps it apart.
                    if typed.isEmpty { output.marker("search_clear") }
                    let mark = output.poll()
                    field.stringValue = typed
                    (field.delegate as NSControlTextEditingDelegate?)?
                        .controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                    let line = try await waitForFlow(.searchKeystroke, after: mark, timeout: 10)
                    XCTAssertEqual(line?["outcome"] as? String, "ok", "Query \(typed.isEmpty ? "(cleared)" : "\(typed.count) letters")")
                }
            }
            if let meter { addHitch("history_search", meter.stop()) }
            addHang(&searchHangs, watchdog.stop())

            window.orderOut(nil)
            window.contentView = nil
            window.close()
            try await Task.sleep(for: .milliseconds(200))
            try assertNothingVisible()
        }
        for (section, hangs) in [("history_open", openHangs), ("history_scroll", scrollHangs), ("history_search", searchHangs)] {
            output.append(["metric": "hangs_over_250ms", "section": section, "count": hangs.0, "max_stall_ms": hangs.1])
            if let hitch = hitches[section] {
                output.append(["metric": "hitch_ratio_ms_per_s", "section": section,
                               "value": hitch.seconds > 0 ? hitch.ms / hitch.seconds : 0,
                               "frames": hitch.frames, "duration_s": hitch.seconds])
            }
            output.marker("\(section)_end", section: section)
        }
    }

    private static func views<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let match = view as? T { found.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// 1,200 synthetic dictations from a fixed seed: neutral words, 5 to 120
    /// per row, over the last 120 days; about 80% carry dictation evidence.
    private func seed(_ store: RecordingStore, count: Int) async throws {
        var state: UInt64 = 0x5EED_2026
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        let now = Date()
        for _ in 0..<count {
            let wordCount = 5 + Int(next() % 116)
            var words: [String] = []
            for _ in 0..<wordCount { words.append(Self.words[Int(next() % UInt64(Self.words.count))]) }
            var text = words.joined(separator: " ")
            text = text.prefix(1).uppercased() + text.dropFirst() + "."
            let id = UUID()
            let recording = Recording(
                id: id,
                timestamp: now.addingTimeInterval(-Double(next() % (120 * 24 * 3_600))),
                fileName: AudioRecorder.recordingFileName(id: id),
                transcription: text,
                duration: Double(wordCount) / 2.5,
                status: .completed,
                progress: 1
            )
            if next() % 10 < 8 {
                try await store.addRecordingSync(recording, source: DictationSource(
                    recordingID: id,
                    recognizerText: text,
                    emittedText: text,
                    disposition: .pasteSent,
                    filter: .builtIn(.everyday),
                    captureOrigin: .live,
                    processingSeconds: 0.4
                ))
            } else {
                try await store.addRecordingSync(recording)
            }
        }
        let total = try await store.fetchRecordings(limit: count + 10, offset: 0).count
        XCTAssertEqual(total, count)
    }
}
