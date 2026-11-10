import AppKit
import XCTest
@testable import OpenSuperWhisper

/// The hidden indicator must cost nothing between dictations. Regression for
/// the Nov 2026 idle sample (26-29% CPU an hour after launch): a finished
/// dictation left the reused, ordered-out panel bound to its `.decoding`
/// model, whose IndicatorProcessingWave TimelineView(.animation) kept the
/// panel laying out and committing a frame at display rate.
///
/// The panel is built but never ordered on screen (warmUp() skips that under
/// tests), no microphone or recorder is touched, and each test uses its own
/// defaults suite.
@MainActor
final class IndicatorIdleCostTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "IndicatorIdleCostTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// The path of every delivered dictation (and of "no speech", empty
    /// cleanup, and stale results): finishDictation() -> finishDecoding() ->
    /// didFinishDecoding -> hide(), with the state still `.decoding`.
    func testFinishedDictationLeavesTheHiddenPanelIdle() throws {
        let (manager, panel, host, session) = try makeSession(.decoding)

        manager.didFinishDecoding(session)
        // Nothing changes before the hide spring has run: the capsule still
        // shows the wave and "Transcribing...".
        XCTAssertTrue(host.rootView.viewModel === session)
        XCTAssertEqual(host.rootView.viewModel.state, .decoding)

        XCTAssertTrue(spin(until: { manager.viewModel == nil }, timeout: 5), "hide() did not finish")
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(host.rootView.viewModel.state, .idle,
                       "The hidden panel still draws the finished session: .decoding keeps TimelineView(.animation) ticking")
        XCTAssertFalse(host.rootView.viewModel === session,
                       "The hidden panel must not keep the finished session alive")
    }

    /// Esc or a chord cancels through stopForce(); every state it can leave
    /// is parked too, and none changes before the hide spring has run.
    func testCancelledSessionsLeaveTheHiddenPanelIdle() throws {
        let states: [RecordingState] = [.connecting, .recording, .decoding, .busy, .transcriptionFailed, .pasteFailed]
        for state in states {
            let (manager, _, host, session) = try makeSession(state)

            manager.stopForce()
            XCTAssertTrue(host.rootView.viewModel === session, "\(state): changed before the hide animation")
            XCTAssertEqual(host.rootView.viewModel.state, state, "\(state): changed before the hide animation")

            XCTAssertTrue(spin(until: { manager.viewModel == nil }, timeout: 5), "\(state): hide() did not finish")
            XCTAssertEqual(host.rootView.viewModel.state, .idle,
                           "\(state): the hidden panel keeps the cancelled session's content")
            XCTAssertFalse(host.rootView.viewModel === session,
                           "\(state): the hidden panel must not keep the cancelled session")
        }
    }

    /// A dictation started while the previous one's hide is pending owns the
    /// panel; the older hide must neither hide nor park it.
    func testNewSessionDuringHideIsNotParked() throws {
        let (manager, _, host, a) = try makeSession(.decoding)

        manager.didFinishDecoding(a)
        let b = manager.prepare()
        b.state = .recording

        spin(0.5)
        XCTAssertTrue(manager.viewModel === b, "The older hide took the panel from the new session")
        XCTAssertTrue(host.rootView.viewModel === b, "The older hide rebound the new session's panel")
        XCTAssertEqual(b.state, .recording)
    }

    /// After the hide, nothing in the panel keeps the finished session alive.
    func testFinishedSessionIsReleasedAfterHide() throws {
        weak var released: IndicatorViewModel?
        let manager: IndicatorWindowManager
        do {
            let made = try makeSession(.decoding)
            manager = made.manager
            released = made.session
            manager.didFinishDecoding(made.session)
        }
        XCTAssertTrue(spin(until: { manager.viewModel == nil }, timeout: 5), "hide() did not finish")
        XCTAssertTrue(spin(until: { released == nil }, timeout: 2),
                      "The hidden panel still retains the finished session's view model")
    }

    /// Parking rebinds and lays out the ordered-out panel; that must neither
    /// show it nor overwrite the position the user dragged the capsule to.
    func testParkingDoesNotShowThePanelOrMoveTheSavedPosition() throws {
        defaults.set([300.0, 400.0], forKey: "indicatorCardCenter")
        let (manager, panel, host, session) = try makeSession(.decoding)

        manager.didFinishDecoding(session)
        XCTAssertTrue(spin(until: { manager.viewModel == nil }, timeout: 5), "hide() did not finish")
        spin(0.3) // the parked root lays out and reports its width
        XCTAssertFalse(panel.isVisible, "Parking ordered the hidden panel in")
        XCTAssertEqual(host.rootView.viewModel.state, .idle)
        XCTAssertEqual(manager.savedCardCenter, CGPoint(x: 300, y: 400),
                       "Parking overwrote the user's saved capsule position")
    }

    /// What the user pays: once the finished session is parked, the hidden
    /// panel no longer wakes the main thread every frame.
    func testHiddenPanelStopsWakingTheMainThread() throws {
        let (manager, _, _, session) = try makeSession(.decoding)
        let animating = mainRunLoopWakeups(during: 1.0)
        print("IndicatorIdleCostTests: \(animating) main run loop wake-ups in 1 s with the panel in .decoding")
        if animating < 20 {
            throw XCTSkip("an off-screen panel does not tick in this host (\(animating) wake-ups in 1 s)")
        }

        manager.didFinishDecoding(session)
        XCTAssertTrue(spin(until: { manager.viewModel == nil }, timeout: 5), "hide() did not finish")
        spin(0.3) // the parked root renders once

        let cpuBefore = mainThreadCPUSeconds()
        let idle = mainRunLoopWakeups(during: 2.0)
        let cpu = mainThreadCPUSeconds() - cpuBefore
        print("IndicatorIdleCostTests: \(idle) main run loop wake-ups in 2 s after the hide, \(cpu) s main-thread CPU")
        XCTAssertLessThanOrEqual(idle, 10, "The hidden panel still wakes the main thread (\(idle) wake-ups in 2 s)")
        XCTAssertLessThan(cpu, 0.02, "The hidden panel still costs \(cpu) s of main-thread CPU per 2 s")
    }

    // MARK: Helpers

    /// A built, never-shown panel whose hosting view shows `session` in
    /// `state`, owned by `manager` the way prepare() leaves it.
    private func makeSession(_ state: RecordingState) throws
        -> (manager: IndicatorWindowManager, panel: NSWindow, host: IndicatorHostingView, session: IndicatorViewModel) {
        let manager = IndicatorWindowManager(defaults: defaults)
        manager.warmUp()
        let panel = try XCTUnwrap(manager.window)
        let host = try XCTUnwrap(panel.contentView as? IndicatorHostingView)
        // The springs leave the layer at opacity 0; animateHide() then returns
        // at once instead of waiting on a Core Animation completion that a
        // never-shown layer may not deliver.
        host.layer?.opacity = 0
        let session = host.rootView.viewModel
        session.delegate = manager
        manager.viewModel = session
        if state == .recording { session.recordingStartedAt = Date() } // the clock's TimelineView
        session.state = state
        spin(0.2)
        XCTAssertFalse(panel.isVisible, "Tests never order the panel in")
        return (manager, panel, host, session)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func spin(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
        return condition()
    }

    /// How often the main run loop wakes from sleep while it runs for `seconds`.
    private func mainRunLoopWakeups(during seconds: TimeInterval) -> Int {
        var wakeups = 0
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { _, _ in wakeups += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        spin(seconds)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        return wakeups
    }

    /// CPU time the main thread has used so far, user plus system.
    private func mainThreadCPUSeconds() -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        func seconds(_ time: time_value_t) -> TimeInterval {
            TimeInterval(time.seconds) + TimeInterval(time.microseconds) / 1_000_000
        }
        return seconds(info.user_time) + seconds(info.system_time)
    }
}
