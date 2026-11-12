import AppKit
import Combine
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

// What a recording's level meter costs the main thread, and what it must
// not cost. No microphone is opened and nothing is recorded or played: the
// recording state is scripted and the levels are synthetic. No window is
// ever ordered in, so the owner sees nothing.

// MARK: - Helpers

/// Pushes synthetic levels into the shared meter the way
/// `AudioRecorder.startLevelMetering` does: 20 a second from a background
/// queue, hopping to the main queue.
final class SyntheticMeterFeed {
    enum Pattern: String {
        /// The recorder is not metering: nothing is pushed.
        case none
        /// A silent room: every reading is 0.
        case silent
        /// A constant tone: the smoothed level settles and stops changing.
        case steady
        /// Speech: the level changes on every reading.
        case speech
    }

    private let queue = DispatchQueue(label: "workflow.tests.synthetic-meter")
    private var timer: DispatchSourceTimer?
    private var tick = 0

    static func level(_ pattern: Pattern, tick: Int) -> CGFloat? {
        switch pattern {
        case .none: return nil
        case .silent: return 0
        case .steady: return 0.5
        case .speech:
            // Syllables: a slow swell with a faster ripple, always moving.
            let swell = 0.5 + 0.35 * sin(Double(tick) * 0.37)
            let ripple = 0.12 * sin(Double(tick) * 1.9)
            return CGFloat(min(max(swell + ripple, 0.05), 1))
        }
    }

    func start(_ pattern: Pattern) {
        stop()
        guard pattern != .none else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick += 1
            guard let level = Self.level(pattern, tick: self.tick) else { return }
            DispatchQueue.main.async {
                InputLevelMeter.shared.push(level)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Main-thread CPU time and run-loop wake-ups over a stretch of the main run loop.
@MainActor
struct MainThreadCost {
    let seconds: Double
    let cpuMilliseconds: Double
    let wakeups: Int

    var cpuMillisecondsPerSecond: Double { seconds > 0 ? cpuMilliseconds / seconds : 0 }
    var wakeupsPerSecond: Double { seconds > 0 ? Double(wakeups) / seconds : 0 }

    /// Runs the main run loop for `seconds` and reports what it cost.
    static func measure(for seconds: TimeInterval) -> MainThreadCost {
        var wakeups = 0
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { _, _ in wakeups += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let started = ContinuousClock.now
        let cpuStart = PerfSignpost.mainThreadCPUNanoseconds()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let cpuEnd = PerfSignpost.mainThreadCPUNanoseconds()
        let elapsed = started.duration(to: .now)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return MainThreadCost(seconds: wall, cpuMilliseconds: Double(cpuEnd &- cpuStart) / 1e6, wakeups: wakeups)
    }
}

/// A window that is never shown and answers for its own occlusion, so a test
/// can say "this window is on screen now" without putting one there. It
/// announces a change the way AppKit does.
final class ScriptedOcclusionWindow: NSWindow {
    var isOnScreen = false {
        didSet {
            guard isOnScreen != oldValue else { return }
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
        }
    }

    override var occlusionState: NSWindow.OcclusionState { isOnScreen ? .visible : [] }
}

/// The dictation bar alone in a window whose occlusion the test scripts.
@MainActor
private final class DictationBarHost: HostedControls {
    static let size = CGSize(width: 560, height: DictationDock.expectedHeight)

    let window: ScriptedOcclusionWindow
    let hosting: LayoutCountingHostingView<AnyView>
    var host: NSView { hosting }

    init(status: DictationDockStatus, windowOnScreenOverride: Bool? = nil) {
        let dock = DictationDock(
            status: status, shortcut: "⌃ / fn", writingSelection: .constant(.builtIn(.everyday)),
            microphones: [MainWindowFixtures.microphone], currentMicrophoneID: MainWindowFixtures.microphone.id,
            onSelectMicrophone: { _ in }, onRecord: {}
        )
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
        .background(ThemePalette.contentBackground(.light))
        .environment(\.colorScheme, .light)
        .environment(\.windowOnScreenOverride, windowOnScreenOverride)
        window = ScriptedOcclusionWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        hosting = LayoutCountingHostingView(rootView: AnyView(dock))
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        settle()
    }

    /// Lets SwiftUI finish what it has to draw, without showing anything.
    func settle(_ seconds: TimeInterval = 0.4) {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        hosting.layoutSubtreeIfNeeded()
    }

    /// Runs the main run loop until `condition` holds; false if `timeout`
    /// passes first. A loaded machine only makes this take longer.
    func wait(timeout: TimeInterval = 5, until condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            hosting.layoutSubtreeIfNeeded()
            if try condition() { return true }
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func render() throws -> NSBitmapImageRep {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// Whether two renders `interval` apart differ within `timeout`: something is moving.
    func moves(interval: TimeInterval = 0.25, timeout: TimeInterval = 5) throws -> Bool {
        try wait(timeout: timeout) {
            let first = try XCTUnwrap(render().tiffRepresentation)
            RunLoop.main.run(until: Date().addingTimeInterval(interval))
            return try XCTUnwrap(render().tiffRepresentation) != first
        }
    }

    /// Whether two renders `interval` apart are identical within `timeout`: nothing is moving.
    func holdsStill(interval: TimeInterval = 0.25, timeout: TimeInterval = 5) throws -> Bool {
        try wait(timeout: timeout) {
            let first = try XCTUnwrap(render().tiffRepresentation)
            RunLoop.main.run(until: Date().addingTimeInterval(interval))
            return try XCTUnwrap(render().tiffRepresentation) == first
        }
    }

    /// The color between the record control's disc (radius 20) and its ring
    /// (radius 24.5): the bar's surface while the halo rests, tinted while
    /// the halo has grown with a voice.
    func haloPixel() throws -> NSColor {
        let record = try XCTUnwrap(buttons.first {
            abs($0.frame.width - WFRecordControl.size) < 1 && abs($0.frame.height - WFRecordControl.size) < 1
        }, "No record control")
        let frame = frameInHost(record)
        let bitmap = try render()
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let offset = 23 * CGFloat(0.5).squareRoot()
        let color = bitmap.colorAt(x: Int((frame.midX + offset) * scale), y: Int((frame.midY + offset) * scale))
        return try XCTUnwrap(color?.usingColorSpace(.sRGB))
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

private func colorDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
    max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
}

// MARK: - Regression

/// The level meter must not make the main thread draw what nobody can see.
/// Regression for the Nov 2026 observation of the installed app at 82 to 92
/// percent of a core on its main thread through a recording of almost an
/// hour while none of its windows was on screen: the record control kept
/// following the meter, and SwiftUI kept redrawing its window at the
/// display's rate for nobody. A silent microphone cost a redraw 20 times a
/// second as well, because the meter published readings that changed nothing.
@MainActor
final class RecordingMeterCostTests: XCTestCase {
    private final class ScriptedRecordingViewModel: ContentViewModel {
        var scriptedRecording = false
        override var isRecording: Bool { scriptedRecording }
    }

    private let feed = SyntheticMeterFeed()
    private var appStorage: UserDefaults!
    private var appStorageSuite: String!
    private var savedMicrophones: [MicrophoneService.AudioDevice] = []
    private var savedCurrentMicrophone: MicrophoneService.AudioDevice?

    override func setUp() {
        super.setUp()
        appStorageSuite = "RecordingMeterCostTests-\(UUID().uuidString)"
        appStorage = UserDefaults(suiteName: appStorageSuite)
        let microphones = MicrophoneService.shared
        savedMicrophones = microphones.availableMicrophones
        savedCurrentMicrophone = microphones.currentMicrophone
        microphones.availableMicrophones = [MainWindowFixtures.microphone]
        microphones.currentMicrophone = MainWindowFixtures.microphone
        InputLevelMeter.shared.reset()
    }

    override func tearDown() {
        feed.stop()
        InputLevelMeter.shared.reset()
        appStorage.removePersistentDomain(forName: appStorageSuite)
        MicrophoneService.shared.availableMicrophones = savedMicrophones
        MicrophoneService.shared.currentMicrophone = savedCurrentMicrophone
        super.tearDown()
    }

    // MARK: The meter

    /// Silence, and a tone once the smoothed level has settled, publish
    /// nothing: every published value redraws whatever watches the meter.
    func testAReadingThatChangesNothingIsNotPublished() {
        let meter = InputLevelMeter()
        var published = 0
        let watching = meter.objectWillChange.sink { published += 1 }
        defer { watching.cancel() }

        for _ in 0..<40 { meter.push(0) }
        XCTAssertEqual(published, 0, "A silent microphone published \(published) changes in two seconds")

        meter.push(0.8)
        XCTAssertGreaterThan(published, 0, "A voice is published")
        XCTAssertGreaterThan(meter.level, 0.4)
        XCTAssertEqual(meter.history.last, meter.level, "The newest reading ends the history")

        for _ in 0..<200 { meter.push(0) }
        XCTAssertEqual(meter.level, 0)
        XCTAssertEqual(meter.history, Array(repeating: 0, count: InputLevelMeter.historyLength))
        let afterSpeech = published
        for _ in 0..<40 { meter.push(0) }
        XCTAssertEqual(published, afterSpeech, "Silence after speech goes quiet again")

        for _ in 0..<400 { meter.push(0.5) }
        XCTAssertEqual(meter.level, 0.5, accuracy: 0.001)
        let settled = published
        for _ in 0..<40 { meter.push(0.5) }
        XCTAssertEqual(published, settled, "A steady tone stops publishing once its level has settled")
    }

    /// A view that watches a feed, not the meter, is redrawn only while its feed is on.
    func testAFeedFollowsTheMeterOnlyWhileItIsOn() {
        let meter = InputLevelMeter()
        let feed = InputLevelFeed(meter: meter)
        var published = 0
        let watching = feed.objectWillChange.sink { published += 1 }
        defer { watching.cancel() }

        meter.push(0.8)
        XCTAssertFalse(feed.isOn)
        XCTAssertEqual(feed.level, 0)
        XCTAssertEqual(published, 0, "A feed that is off publishes nothing")

        feed.isOn = true
        XCTAssertEqual(feed.level, meter.level, "Turned on, it takes the meter's level at once")
        meter.push(1)
        XCTAssertEqual(feed.level, meter.level, "and follows it")

        feed.isOn = false
        XCTAssertEqual(feed.level, 0, "Turned off, it rests")
        let whenOff = published
        meter.push(0.2)
        meter.push(0.9)
        XCTAssertEqual(published, whenOff, "and publishes nothing more")
        XCTAssertEqual(feed.level, 0)
    }

    // MARK: The record control

    /// The halo grows with the voice while its window is on screen, rests
    /// while it is not, and SwiftUI lays the window out for none of the
    /// readings that arrive meanwhile.
    func testTheRecordControlFollowsTheMeterOnlyWhileItsWindowIsOnScreen() throws {
        let bar = DictationBarHost(status: .meeting(65))
        defer { bar.close() }
        let resting = try bar.haloPixel()
        func follows() throws -> Bool { colorDistance(try bar.haloPixel(), resting) > 0.04 }
        func rests() throws -> Bool { colorDistance(try bar.haloPixel(), resting) < 0.01 }

        bar.window.isOnScreen = true
        for _ in 0..<12 { InputLevelMeter.shared.push(0.9) }
        XCTAssertTrue(try bar.wait(until: follows), "On screen, the halo grows with the voice")

        bar.window.isOnScreen = false
        XCTAssertTrue(try bar.wait(until: rests), "Off screen, the halo rests")
        bar.settle()

        let before = bar.hosting.layoutPasses
        feed.start(.speech)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        feed.stop()
        let passes = bar.hosting.layoutPasses - before
        XCTAssertLessThanOrEqual(passes, 4, "SwiftUI laid an off-screen window out \(passes) times in 1.5 s for the meter")
        XCTAssertTrue(try rests(), "and the halo stayed at rest")

        for _ in 0..<12 { InputLevelMeter.shared.push(0.9) }
        bar.window.isOnScreen = true
        XCTAssertTrue(try bar.wait(until: follows), "Seen again, the halo follows the voice again")
    }

    /// The arc that turns while the app transcribes turns on screen and
    /// holds still off screen.
    func testTheTurningArcHoldsStillWhileItsWindowIsOffScreen() throws {
        let bar = DictationBarHost(status: .transcribing)
        defer { bar.close() }

        bar.window.isOnScreen = true
        XCTAssertTrue(try bar.moves(), "On screen, the arc turns")

        bar.window.isOnScreen = false
        XCTAssertTrue(try bar.holdsStill(), "Off screen, the arc holds still")
        let before = bar.hosting.layoutPasses
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let passes = bar.hosting.layoutPasses - before
        XCTAssertLessThanOrEqual(passes, 4, "SwiftUI laid an off-screen window out \(passes) times in 1.5 s for the arc")

        bar.window.isOnScreen = true
        XCTAssertTrue(try bar.moves(), "Seen again, the arc turns again")
    }

    // MARK: The main window

    /// The whole main window, recording: off screen it is not laid out for
    /// the meter whatever the microphone hears, and on screen a silent
    /// microphone redraws nothing. Only the bar's clock, once a second, does.
    func testTheMainWindowIsNotRedrawnForAMeterItCannotShow() throws {
        let cases: [(name: String, windowOnScreen: Bool?, meter: SyntheticMeterFeed.Pattern)] = [
            ("off screen, speech", nil, .speech),
            ("off screen, silence", nil, .silent),
            ("on screen, silence", true, .silent),
        ]
        for item in cases {
            let host = try MainWindowHost(
                recordings: MainWindowFixtures.history(), size: CGSize(width: 560, height: 720), scheme: .light,
                appStorage: appStorage, windowOnScreen: item.windowOnScreen
            ) { ScriptedRecordingViewModel(transcriptionService: $0, transcriptionQueue: $1, recordingStore: $2) }
            defer { host.close() }
            let model = try XCTUnwrap(host.viewModel as? ScriptedRecordingViewModel)
            model.scriptedRecording = true
            model.updateRecorderState(isRecording: true, isConnecting: false)
            host.settle()
            XCTAssertFalse(host.window.isVisible, "The window is never shown")

            InputLevelMeter.shared.reset()
            feed.start(item.meter)
            // Past the start: the window learns where it stands and the first
            // readings arrive. Counting begins once it has gone quiet, or
            // after 5 s if it never does.
            let deadline = Date().addingTimeInterval(5)
            var settling = host.layoutPasses()
            repeat {
                settling = host.layoutPasses()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            } while host.layoutPasses() - settling > 1 && Date() < deadline
            let before = host.layoutPasses()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let passes = host.layoutPasses() - before
            feed.stop()
            XCTAssertLessThanOrEqual(passes, 8, "\(item.name): the main window was laid out \(passes) times in 1.5 s")
        }
    }
}

// MARK: - Benchmark

/// Opt-in measurement of what the main thread pays while a recording's level
/// meter ticks, for each surface that shows the meter. Every test skips
/// unless `WF_METER_COST_OUT` (passed to xcodebuild as
/// `TEST_RUNNER_WF_METER_COST_OUT`) names the JSON-lines file the rows are
/// appended to.
///
/// No window is ever ordered in, and the suite fails hard if one of its
/// windows is on screen. "off_screen" rows let the window answer for itself;
/// "drawn_as_on_screen" rows tell the surface its window is on screen, which
/// is what following the meter costs before any pixel reaches a display.
/// What a window that really is on screen costs is not measured here.
@MainActor
final class RecordingMeterCostBenchmarkTests: XCTestCase {
    private final class ScriptedRecordingViewModel: ContentViewModel {
        var scriptedRecording = false
        override var isRecording: Bool { scriptedRecording }
    }

    private var outputURL: URL!
    private var sampleDirectory: URL?
    private var seconds: TimeInterval = 4
    private var appStorage: UserDefaults!
    private var appStorageSuite: String!
    private var savedMicrophones: [MicrophoneService.AudioDevice] = []
    private var savedCurrentMicrophone: MicrophoneService.AudioDevice?
    private let feed = SyntheticMeterFeed()

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WF_METER_COST_OUT"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_WF_METER_COST_OUT to run the recording meter cost benchmark")
        }
        outputURL = URL(fileURLWithPath: path)
        if let directory = environment["WF_METER_COST_SAMPLE_DIR"], !directory.isEmpty {
            sampleDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        }
        if let value = environment["WF_METER_COST_SECONDS"].flatMap(Double.init), value >= 1 {
            seconds = value
        }
        appStorageSuite = "RecordingMeterCostBenchmarkTests-\(UUID().uuidString)"
        appStorage = UserDefaults(suiteName: appStorageSuite)
        let microphones = MicrophoneService.shared
        savedMicrophones = microphones.availableMicrophones
        savedCurrentMicrophone = microphones.currentMicrophone
        microphones.availableMicrophones = [MainWindowFixtures.microphone]
        microphones.currentMicrophone = MainWindowFixtures.microphone
        InputLevelMeter.shared.reset()
    }

    override func tearDown() async throws {
        feed.stop()
        InputLevelMeter.shared.reset()
        guard appStorageSuite != nil else { return }
        appStorage.removePersistentDomain(forName: appStorageSuite)
        MicrophoneService.shared.availableMicrophones = savedMicrophones
        MicrophoneService.shared.currentMicrophone = savedCurrentMicrophone
    }

    private static func windowLabel(_ windowOnScreen: Bool?) -> String {
        windowOnScreen == true ? "drawn_as_on_screen" : "off_screen"
    }

    /// The main window, idle and recording, with each kind of meter reading.
    func testMainWindow() throws {
        let cases: [(recording: Bool, windowOnScreen: Bool?, meter: SyntheticMeterFeed.Pattern)] = [
            (false, nil, .none),
            (true, nil, .silent), (true, nil, .steady), (true, nil, .speech),
            (true, true, .silent), (true, true, .steady), (true, true, .speech),
        ]
        for item in cases {
            let host = try MainWindowHost(
                recordings: MainWindowFixtures.history(), size: CGSize(width: 560, height: 720), scheme: .light,
                appStorage: appStorage, windowOnScreen: item.windowOnScreen
            ) { ScriptedRecordingViewModel(transcriptionService: $0, transcriptionQueue: $1, recordingStore: $2) }
            let model = try XCTUnwrap(host.viewModel as? ScriptedRecordingViewModel)
            if item.recording {
                model.scriptedRecording = true
                model.updateRecorderState(isRecording: true, isConnecting: false)
            }
            host.settle()
            try measure(surface: "main_window", state: item.recording ? "recording" : "idle",
                        window: host.window, windowLabel: Self.windowLabel(item.windowOnScreen),
                        meter: item.meter, layoutPasses: host.layoutPasses)
            host.close()
            spin(0.3)
        }
    }

    /// The dictation bar alone, without History beneath it: a meeting, a
    /// dictation, and the turning arc it shows while transcribing.
    func testDictationBarAlone() throws {
        let cases: [(name: String, status: DictationDockStatus, windowOnScreen: Bool?, meter: SyntheticMeterFeed.Pattern)] = [
            ("ready", .ready, nil, .none),
            ("meeting", .meeting(3_725), nil, .silent),
            ("meeting", .meeting(3_725), nil, .speech),
            ("recording", .recording(754), nil, .speech),
            ("transcribing", .transcribing, nil, .none),
            ("meeting", .meeting(3_725), true, .silent),
            ("meeting", .meeting(3_725), true, .speech),
            ("transcribing", .transcribing, true, .none),
        ]
        for item in cases {
            let bar = DictationBarHost(status: item.status, windowOnScreenOverride: item.windowOnScreen)
            try measure(surface: "dictation_bar", state: item.name, window: bar.window,
                        windowLabel: Self.windowLabel(item.windowOnScreen), meter: item.meter,
                        layoutPasses: { bar.hosting.layoutPasses })
            bar.close()
            spin(0.3)
        }
    }

    /// The floating capsule a shortcut dictation shows: listening, and the
    /// travelling wave it shows while transcribing. The app shows the
    /// capsule only on screen, so it always follows the meter.
    func testIndicatorCapsule() throws {
        let cases: [(name: String, state: RecordingState, meter: SyntheticMeterFeed.Pattern)] = [
            ("recording", .recording, .silent), ("recording", .recording, .speech), ("transcribing", .decoding, .none),
        ]
        for item in cases {
            let suite = "RecordingMeterCostBenchmarkTests-indicator-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = IndicatorWindowManager(defaults: defaults)
            manager.warmUp()
            let panel = try XCTUnwrap(manager.window)
            let hosting = try XCTUnwrap(panel.contentView as? IndicatorHostingView)
            let session = hosting.rootView.viewModel
            if item.state == .recording { session.recordingStartedAt = Date() }
            session.state = item.state
            spin(0.2)
            try measure(surface: "indicator", state: item.name, window: panel, windowLabel: "always_follows",
                        meter: item.meter, layoutPasses: nil)
            session.state = .idle
            session.cleanup()
            panel.contentView = nil
            panel.close()
            spin(0.3)
        }
    }

    // MARK: Measuring

    private func measure(
        surface: String, state: String, window: NSWindow, windowLabel: String,
        meter: SyntheticMeterFeed.Pattern, layoutPasses: (() -> Int)?
    ) throws {
        // Never ordered in: nothing of this host may reach the owner's screen.
        XCTAssertFalse(window.isVisible, "The measured window must stay off screen")
        try assertNothingOnScreen()

        InputLevelMeter.shared.reset()
        feed.start(meter)
        // Past the start: the first frames lay the surface out for its state.
        spin(1.0)
        let loadBefore = Self.loadAverage()
        let passesBefore = layoutPasses?()
        let cost = MainThreadCost.measure(for: seconds)
        let passes = layoutPasses.map { Double($0() - (passesBefore ?? 0)) / cost.seconds }
        let loadAfter = Self.loadAverage()

        var row: [String: Any] = [
            "surface": surface, "state": state, "window": windowLabel, "meter": meter.rawValue,
            "seconds": cost.seconds,
            "main_cpu_ms_per_s": cost.cpuMillisecondsPerSecond,
            "wakeups_per_s": cost.wakeupsPerSecond,
            "window_is_visible": window.isVisible,
            "screen_fps": window.screen?.maximumFramesPerSecond ?? 0,
            "load_before": loadBefore, "load_after": loadAfter,
        ]
        if let passes { row["layout_passes_per_s"] = passes }

        if let sampleDirectory {
            // A second stretch with the system sampler on this test host only,
            // kept apart so sampling never inflates the measured cost.
            let name = "\(surface)-\(state)-\(windowLabel)-\(meter.rawValue).sample.txt"
            let file = sampleDirectory.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
            let sampler = Process()
            sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sampler.arguments = ["\(getpid())", "3", "1", "-file", file.path]
            sampler.standardOutput = FileHandle.nullDevice
            sampler.standardError = FileHandle.nullDevice
            try sampler.run()
            // The sampler writes its report after it stops sampling.
            let deadline = Date().addingTimeInterval(120)
            while sampler.isRunning, Date() < deadline { spin(0.25) }
            if sampler.isRunning { sampler.terminate() }
            row["sample_file"] = name
        }

        feed.stop()
        spin(0.1)
        InputLevelMeter.shared.reset()
        try assertNothingOnScreen()
        append(row)
        print(String(
            format: "RecordingMeterCost %@ %@ %@ meter=%@: main CPU %.1f ms/s, %.0f wake-ups/s, %@ layout passes/s (load %.0f)",
            surface, state, windowLabel, meter.rawValue,
            cost.cpuMillisecondsPerSecond, cost.wakeupsPerSecond, passes.map { String(format: "%.0f", $0) } ?? "-", loadAfter
        ))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func loadAverage() -> Double {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) > 0 ? load[0] : -1
    }

    /// One write(2) per line on an O_APPEND descriptor.
    private func append(_ object: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let bytes = Array(json) + [0x0A]
        let fd = Darwin.open(outputURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        bytes.withUnsafeBytes { buffer in
            while Darwin.write(fd, buffer.baseAddress, buffer.count) < 0, errno == EINTR {}
        }
    }

    private struct OnScreenWindowError: Error {}

    /// Fails hard if this process has a window on screen that a person
    /// could see or click: any size, any layer, unless it is fully transparent.
    private func assertNothingOnScreen() throws {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let pid = getpid()
        let visible = info.filter { entry in
            (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
        }
        guard visible.isEmpty else {
            XCTFail("A test host window is on screen (\(visible.count))")
            throw OnScreenWindowError()
        }
    }
}
