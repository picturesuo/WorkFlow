import CoreGraphics
import XCTest
@testable import OpenSuperWhisper

final class ModifierChordTriggerStateTests: XCTestCase {
    private let fn = ModifierKey.fn.keyCode
    private let leftControl = ModifierKey.leftControl.keyCode
    private let rightControl = ModifierKey.rightControl.keyCode
    private let leftShift = ModifierKey.leftShift.keyCode
    private let both: CGEventFlags = [.maskControl, .maskSecondaryFn]

    func testControlThenFnStartsAndReleasingFnFinishes() {
        var state = ModifierChordTriggerState()
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: .maskControl))
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fn, flags: both), .keyDown)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fn, flags: .maskControl), .keyUp)
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: []), "Only one key-up per gesture")
    }

    func testFnThenRightControlStartsAndReleasingControlFinishes() {
        var state = ModifierChordTriggerState()
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: .maskSecondaryFn))
        XCTAssertEqual(state.handleFlagsChanged(keyCode: rightControl, flags: both), .keyDown)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: rightControl, flags: .maskSecondaryFn), .keyUp)
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: []))
    }

    func testRepressingTheReleasedKeyWaitsUntilBothAreUp() {
        var state = ModifierChordTriggerState()
        _ = state.handleFlagsChanged(keyCode: leftControl, flags: .maskControl)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fn, flags: both), .keyDown)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fn, flags: .maskControl), .keyUp)
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: both), "No second session from the same hold")
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: .maskControl))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: []))

        _ = state.handleFlagsChanged(keyCode: fn, flags: .maskSecondaryFn)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: leftControl, flags: both), .keyDown, "A fresh chord works")
    }

    func testFnAloneAndControlAloneDoNothing() {
        var state = ModifierChordTriggerState()
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: .maskSecondaryFn))
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: []))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: .maskControl))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: []))
        XCTAssertNil(state.handleFlagsChanged(keyCode: rightControl, flags: .maskControl))
        XCTAssertNil(state.handleFlagsChanged(keyCode: rightControl, flags: []))
    }

    func testFnFlagFromArrowOrFunctionKeysIsNotThePhysicalFnKey() {
        var state = ModifierChordTriggerState()
        // Arrow and function keys set the Fn flag without an Fn key event.
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: both))
        XCTAssertFalse(state.isFnDown)
        XCTAssertNil(state.handleOtherInput(), "⌃→ is a shortcut, not dictation")
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: .maskSecondaryFn))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: []))
    }

    func testExtraModifierBeforeTheChordBlocksTheStart() {
        var state = ModifierChordTriggerState()
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftShift, flags: .maskShift))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: [.maskShift, .maskControl]))
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: [.maskShift, .maskControl, .maskSecondaryFn]))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftShift, flags: both), "Letting go of Shift doesn't start it")
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: .maskControl))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: []))
    }

    func testExtraModifierDuringTheChordCancelsOnce() {
        var state = ModifierChordTriggerState()
        _ = state.handleFlagsChanged(keyCode: leftControl, flags: .maskControl)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fn, flags: both), .keyDown)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: ModifierKey.leftCommand.keyCode, flags: [.maskCommand, .maskControl, .maskSecondaryFn]), .chord)
        XCTAssertNil(state.handleFlagsChanged(keyCode: ModifierKey.leftCommand.keyCode, flags: both), "No restart in the same hold")
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: .maskControl), "Release after a cancel is silent")
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: []))
    }

    func testKeyOrClickDuringTheChordCancelsAndKeyBeforeItBlocks() {
        var state = ModifierChordTriggerState()
        _ = state.handleFlagsChanged(keyCode: fn, flags: .maskSecondaryFn)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: leftControl, flags: both), .keyDown)
        XCTAssertEqual(state.handleOtherInput(), .chord)
        XCTAssertNil(state.handleOtherInput(), "Auto-repeat doesn't cancel twice")
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: .maskSecondaryFn))
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: []))

        _ = state.handleFlagsChanged(keyCode: leftControl, flags: .maskControl)
        XCTAssertNil(state.handleOtherInput(), "⌃C")
        XCTAssertNil(state.handleFlagsChanged(keyCode: fn, flags: both), "A typed key before Fn blocks the start")
        _ = state.handleFlagsChanged(keyCode: fn, flags: .maskControl)
        _ = state.handleFlagsChanged(keyCode: leftControl, flags: [])
        XCTAssertNil(state.handleOtherInput(), "Typing with nothing held is ignored")
        XCTAssertFalse(state.isSpoiled)
    }

    func testSecondControlKeyDoesNotEndTheChord() {
        var state = ModifierChordTriggerState()
        _ = state.handleFlagsChanged(keyCode: leftControl, flags: .maskControl)
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fn, flags: both), .keyDown)
        XCTAssertNil(state.handleFlagsChanged(keyCode: rightControl, flags: both))
        XCTAssertNil(state.handleFlagsChanged(keyCode: leftControl, flags: both), "Right Control still holds the chord")
        XCTAssertEqual(state.handleFlagsChanged(keyCode: rightControl, flags: .maskSecondaryFn), .keyUp)
    }
}

/// Feeds synthetic, never-posted CGEvents through the monitor's real tap
/// entry point. No event tap is installed, so nothing asks for Input
/// Monitoring, and the capture callbacks only count.
final class ModifierKeyMonitorChordBoundaryTests: XCTestCase {
    private var monitor: ModifierKeyMonitor!
    private var events: [String] = []

    override func setUp() {
        super.setUp()
        events = []
        monitor = ModifierKeyMonitor()
        monitor.onKeyDown = { [unowned self] in self.events.append("down") }
        monitor.onKeyUp = { [unowned self] in self.events.append("up") }
        monitor.onChord = { [unowned self] in self.events.append("cancel") }
        monitor.configureForTesting(.chord(ModifierChordTriggerState()))
    }

    private func flags(_ keyCode: ModifierKey, _ flags: CGEventFlags) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode.keyCode, keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        monitor.handle(type: .flagsChanged, event: event)
    }

    private func keyDown() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        monitor.handle(type: .keyDown, event: event)
    }

    private func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func testBothOrdersProduceOneSessionEach() throws {
        try flags(.leftControl, .maskControl)
        try flags(.fn, [.maskControl, .maskSecondaryFn])
        try flags(.fn, .maskControl)
        try flags(.leftControl, [])
        try flags(.fn, .maskSecondaryFn)
        try flags(.rightControl, [.maskControl, .maskSecondaryFn])
        try flags(.rightControl, .maskSecondaryFn)
        try flags(.fn, [])
        drain()
        XCTAssertEqual(events, ["down", "up", "down", "up"])
    }

    func testSingleKeysAndTheFnFlagAloneNeverCapture() throws {
        try flags(.fn, .maskSecondaryFn)
        try flags(.fn, [])
        try flags(.leftControl, [.maskControl, .maskSecondaryFn])
        try flags(.leftControl, [])
        drain()
        XCTAssertEqual(events, [])
    }

    func testTypedKeyCancelsTheSessionWithoutAKeyUp() throws {
        try flags(.leftControl, .maskControl)
        try flags(.fn, [.maskControl, .maskSecondaryFn])
        try keyDown()
        try flags(.fn, .maskControl)
        try flags(.leftControl, [])
        drain()
        XCTAssertEqual(events, ["down", "cancel"])
    }

    func testStoppingDropsAHeldChord() throws {
        try flags(.leftControl, .maskControl)
        try flags(.fn, [.maskControl, .maskSecondaryFn])
        monitor.stop()
        try flags(.fn, .maskControl)
        try flags(.leftControl, [])
        drain()
        XCTAssertEqual(events, ["down"], "A settings change mid-hold leaves no stray key-up")
    }

    func testSingleKeyTriggerStillIgnoresTheOtherKey() throws {
        monitor.configureForTesting(.keys(ModifierKeyTriggerState(modifierKeys: [.fn])))
        try flags(.leftControl, .maskControl)
        try flags(.fn, [.maskControl, .maskSecondaryFn])
        try flags(.fn, .maskControl)
        drain()
        XCTAssertEqual(events, ["down", "up"], "The existing Fn trigger is unchanged")
    }
}

final class RecordingTriggerConfigurationTests: XCTestCase {
    func testPriorityIsMouseThenChordThenModifierThenKeyCombination() {
        XCTAssertEqual(RecordingTriggerConfiguration(mouseButton: .middle, chord: .controlFn, modifierKey: .fn, secondaryModifierKey: .none),
                       .mouseButton(.middle))
        XCTAssertEqual(RecordingTriggerConfiguration(mouseButton: .none, chord: .controlFn, modifierKey: .fn, secondaryModifierKey: .leftControl),
                       .chord(.controlFn))
        XCTAssertEqual(RecordingTriggerConfiguration(mouseButton: .none, chord: .none, modifierKey: .fn, secondaryModifierKey: .leftControl),
                       .modifierKeys(primary: .fn, secondary: .leftControl))
        XCTAssertEqual(RecordingTriggerConfiguration(mouseButton: .none, chord: .none, modifierKey: .none, secondaryModifierKey: .none),
                       .keyCombination)
    }

    func testOnlyEventTapTriggersNeedInputMonitoring() {
        XCTAssertTrue(RecordingTriggerConfiguration.chord(.controlFn).requiresInputMonitoring)
        XCTAssertTrue(RecordingTriggerConfiguration.modifierKeys(primary: .fn, secondary: .none).requiresInputMonitoring)
        XCTAssertFalse(RecordingTriggerConfiguration.keyCombination.requiresInputMonitoring)
        XCTAssertFalse(RecordingTriggerConfiguration.mouseButton(.middle).requiresInputMonitoring)
    }

    func testHintSymbols() {
        XCTAssertEqual(RecordingTriggerConfiguration.chord(.controlFn).symbol, "⌃ + fn")
        XCTAssertEqual(RecordingTriggerConfiguration.modifierKeys(primary: .fn, secondary: .leftControl).symbol, "fn / ⌃")
        XCTAssertEqual(RecordingTriggerConfiguration.modifierKeys(primary: .fn, secondary: .fn).symbol, "fn")
        XCTAssertNil(RecordingTriggerConfiguration.keyCombination.symbol)
        XCTAssertEqual(DictationDockStatus.ready.detail(shortcut: "⌃ + fn"), "Press ⌃ + fn to dictate anywhere")
    }

    func testUnsetChordPreferenceKeepsTodaysTrigger() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "modifierChordHotkey")
        defer { if let original { defaults.set(original, forKey: "modifierChordHotkey") } else { defaults.removeObject(forKey: "modifierChordHotkey") } }
        defaults.removeObject(forKey: "modifierChordHotkey")
        XCTAssertEqual(AppPreferences.shared.modifierChordHotkey, ModifierChord.none.rawValue)
        XCTAssertNil(defaults.object(forKey: "modifierChordHotkey"), "Reading the default stores nothing")
        defaults.set("unknown", forKey: "modifierChordHotkey")
        if case .chord = RecordingTriggerConfiguration() { XCTFail("An unknown value never enables the chord") }
    }
}
