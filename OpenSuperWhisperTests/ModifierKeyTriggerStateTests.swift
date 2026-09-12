import XCTest
@testable import OpenSuperWhisper

final class ModifierKeyTriggerStateTests: XCTestCase {
    private let fnCode = ModifierKey.fn.keyCode
    private let controlCode = ModifierKey.leftControl.keyCode

    func testEitherConfiguredKeyTogglesRecording() {
        var state = ModifierKeyTriggerState(modifierKeys: [.fn, .leftControl])

        XCTAssertEqual(state.handleFlagsChanged(keyCode: fnCode, flags: .maskSecondaryFn), .keyDown(.fn))
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fnCode, flags: []), .keyUp(.fn))

        XCTAssertEqual(state.handleFlagsChanged(keyCode: controlCode, flags: .maskControl), .keyDown(.leftControl))
        XCTAssertEqual(state.handleFlagsChanged(keyCode: controlCode, flags: []), .keyUp(.leftControl))
    }

    func testSecondKeyIsIgnoredWhileFirstIsHeld() {
        var state = ModifierKeyTriggerState(modifierKeys: [.fn, .leftControl])

        XCTAssertEqual(state.handleFlagsChanged(keyCode: fnCode, flags: .maskSecondaryFn), .keyDown(.fn))
        XCTAssertNil(state.handleFlagsChanged(keyCode: controlCode, flags: [.maskSecondaryFn, .maskControl]))
        XCTAssertNil(state.handleFlagsChanged(keyCode: controlCode, flags: .maskSecondaryFn))
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fnCode, flags: []), .keyUp(.fn))
    }

    func testUnconfiguredKeysAndReleaseWithoutPressAreIgnored() {
        var state = ModifierKeyTriggerState(modifierKeys: [.fn])

        XCTAssertNil(state.handleFlagsChanged(keyCode: controlCode, flags: .maskControl))
        XCTAssertNil(state.handleFlagsChanged(keyCode: fnCode, flags: []))
        XCTAssertEqual(state.handleFlagsChanged(keyCode: fnCode, flags: .maskSecondaryFn), .keyDown(.fn))
        XCTAssertNil(state.handleFlagsChanged(keyCode: fnCode, flags: .maskSecondaryFn))
    }

    func testNoneAndDuplicateKeysAreDropped() {
        XCTAssertTrue(ModifierKeyTriggerState(modifierKeys: [.none, .none]).isEmpty)
        XCTAssertEqual(ModifierKeyTriggerState(modifierKeys: [.fn, .none, .fn]).modifierKeys, [.fn])
    }

    func testRightControlKeyCodeDoesNotTriggerLeftControl() {
        var state = ModifierKeyTriggerState(modifierKeys: [.leftControl])
        XCTAssertNil(state.handleFlagsChanged(keyCode: ModifierKey.rightControl.keyCode, flags: .maskControl))
    }
}
