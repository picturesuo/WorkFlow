import AppKit
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Where the floating capsule sits after the user drags it, with synthetic
/// screen frames only. The panel is built but never ordered on screen, and
/// the user's position preference is never read or written: each test uses
/// its own defaults suite.
@MainActor
final class IndicatorPlacementTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let card = CGSize(width: 110, height: 32)
    /// A laptop screen at the origin and an external display to its right.
    private let laptop = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          visible: CGRect(x: 0, y: 70, width: 1440, height: 805))
    private let external = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                            visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

    override func setUp() {
        super.setUp()
        suiteName = "IndicatorPlacementTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Pure geometry

    func testCenterInsideTheScreenIsKept() {
        let center = CGPoint(x: 700, y: 500)
        XCTAssertEqual(IndicatorPlacement.clampedCenter(center, cardSize: card, in: laptop.visible), center)
    }

    func testCardIsPulledFullyOntoTheVisibleFrame() {
        let bounds = laptop.visible
        let corner = IndicatorPlacement.clampedCenter(CGPoint(x: -40, y: 2_000), cardSize: card, in: bounds)
        XCTAssertEqual(corner, CGPoint(x: bounds.minX + card.width / 2, y: bounds.maxY - card.height / 2),
                       "Past the top-left corner, it stops at the corner below the menu bar")
        let bottom = IndicatorPlacement.clampedCenter(CGPoint(x: 1_500, y: 10), cardSize: card, in: bounds)
        XCTAssertEqual(bottom, CGPoint(x: bounds.maxX - card.width / 2, y: bounds.minY + card.height / 2),
                       "and above the Dock at the bottom right")
    }

    func testTinyBoundsCenterTheCard() {
        let bounds = CGRect(x: 0, y: 0, width: 50, height: 20)
        XCTAssertEqual(IndicatorPlacement.clampedCenter(CGPoint(x: 400, y: 400), cardSize: card, in: bounds),
                       CGPoint(x: 25, y: 10))
    }

    func testSavedPositionStaysOnItsOwnScreen() {
        let saved = CGPoint(x: 2_400, y: 900)
        let restored = IndicatorPlacement.restoredCenter(saved, cardSize: card, screens: [laptop, external], fallback: laptop.visible)
        XCTAssertEqual(restored, saved, "A spot on the external display is kept there")
    }

    func testUnpluggedDisplayMovesTheCardOntoTheDictationScreen() {
        let saved = CGPoint(x: 2_400, y: 900)
        let restored = IndicatorPlacement.restoredCenter(saved, cardSize: card, screens: [laptop], fallback: laptop.visible)
        XCTAssertTrue(laptop.visible.insetBy(dx: card.width / 2 - 0.5, dy: card.height / 2 - 0.5).contains(restored),
                      "With the external display gone, the whole card lands on the laptop: \(restored)")
    }

    func testStoredValueDecodesOnlyWhenWellFormed() {
        XCTAssertEqual(IndicatorPlacement.decode([12, 34]), CGPoint(x: 12, y: 34))
        XCTAssertNil(IndicatorPlacement.decode(nil))
        XCTAssertNil(IndicatorPlacement.decode([1]))
        XCTAssertNil(IndicatorPlacement.decode([1, 2, 3]))
        XCTAssertNil(IndicatorPlacement.decode([.nan, 2]))
        XCTAssertNil(IndicatorPlacement.decode([.infinity, 2]))
        XCTAssertEqual(IndicatorPlacement.windowOrigin(forCardCenter: CGPoint(x: 500, y: 400), windowSize: IndicatorWindow.windowSize),
                       CGPoint(x: 500 - IndicatorWindow.windowSize.width / 2, y: 400 - IndicatorWindow.windowSize.height / 2))
    }

    // MARK: The panel

    /// The capsule takes a click only to be dragged: it never becomes key or
    /// main and never activates WorkFlow, so the target app keeps focus, the
    /// recording keeps running, and the shortcuts keep working.
    func testPanelCanBeDraggedWithoutTakingFocus() throws {
        let manager = IndicatorWindowManager(defaults: defaults)
        let keyBefore = NSApp.keyWindow
        manager.warmUp()
        let panel = try XCTUnwrap(manager.window as? NSPanel)
        XCTAssertFalse(panel.ignoresMouseEvents, "It can be grabbed")
        XCTAssertTrue(panel.isMovable)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "Clicking it never activates WorkFlow")
        XCTAssertFalse(panel.canBecomeKey, "It never takes the keyboard from the target app")
        XCTAssertFalse(panel.canBecomeMain)
        let host = try XCTUnwrap(panel.contentView as? IndicatorHostingView)
        XCTAssertTrue(host.acceptsFirstMouse(for: nil), "The first click drags without activating anything")
        XCTAssertTrue(host.mouseDownCanMoveWindow)
        let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        XCTAssertTrue(host.hitTest(center) === host, "A click on the capsule drags it, never an inner view")
        XCTAssertFalse(panel.isVisible, "Built offscreen; tests never order it in")
        XCTAssertTrue(NSApp.keyWindow === keyBefore, "Focus is unchanged")
    }

    /// A drag is remembered; the manager's own placement is not.
    func testOnlyTheUsersMoveIsRemembered() throws {
        let manager = IndicatorWindowManager(defaults: defaults)
        manager.warmUp()
        let panel = try XCTUnwrap(manager.window)
        XCTAssertNil(manager.savedCardCenter, "Follows the caret until dragged")

        panel.setFrameOrigin(NSPoint(x: 300, y: 200))
        manager.windowDidMove(byUser: false)
        XCTAssertNil(manager.savedCardCenter, "A move without a drag is not remembered")

        panel.setFrameOrigin(NSPoint(x: 600, y: 400))
        manager.windowDidMove(byUser: true)
        let saved = try XCTUnwrap(manager.savedCardCenter)
        XCTAssertEqual(saved, CGPoint(x: panel.frame.midX, y: panel.frame.midY), "The card's center is kept")

        // Displays change: the manager pulls the card onto a screen without
        // forgetting where the user put it.
        manager.keepOnScreen(screens: [(frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                        visible: CGRect(x: 0, y: 0, width: 400, height: 280))])
        XCTAssertLessThanOrEqual(panel.frame.midX + manager.cardSize.width / 2, 400, "Pulled fully on screen")
        XCTAssertLessThanOrEqual(panel.frame.midY + manager.cardSize.height / 2, 280)
        XCTAssertEqual(manager.savedCardCenter, saved, "The chosen spot survives the clamp")
        XCTAssertFalse(panel.isVisible)
    }

    /// A double-click returns the capsule to following the caret.
    func testDoubleClickForgetsThePosition() throws {
        let manager = IndicatorWindowManager(defaults: defaults)
        manager.warmUp()
        let panel = try XCTUnwrap(manager.window)
        panel.setFrameOrigin(NSPoint(x: 600, y: 400))
        manager.windowDidMove(byUser: true)
        XCTAssertNotNil(manager.savedCardCenter)

        let host = try XCTUnwrap(panel.contentView as? IndicatorHostingView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: host.bounds.midX, y: host.bounds.midY),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 2, pressure: 1
        ))
        host.mouseDown(with: event)
        XCTAssertNil(manager.savedCardCenter)
        XCTAssertFalse(panel.isVisible)
    }

    /// The panel is the pill plus a shadow margin, resized around its center
    /// as the pill's width changes, so it never covers a large invisible area.
    func testPanelTracksThePillWidth() throws {
        let manager = IndicatorWindowManager(defaults: defaults)
        manager.warmUp()
        let panel = try XCTUnwrap(manager.window)
        panel.setFrameOrigin(NSPoint(x: 600, y: 400))
        manager.windowDidMove(byUser: true)
        let saved = manager.savedCardCenter
        for width in [CGFloat(104), 186, 150] {
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            manager.cardWidthDidChange(width)
            XCTAssertEqual(manager.cardSize.width, width)
            XCTAssertEqual(panel.frame.size, CGSize(width: width + 2 * IndicatorWindow.panelPadding,
                                                    height: IndicatorWindow.cardSize.height + 2 * IndicatorWindow.panelPadding))
            XCTAssertEqual(panel.frame.midX, center.x, accuracy: 0.5, "Resized around its center")
            XCTAssertEqual(panel.frame.midY, center.y, accuracy: 0.5)
            XCTAssertEqual(panel.contentView?.frame.size, panel.frame.size, "The capsule's view fills the panel")
        }
        XCTAssertEqual(manager.savedCardCenter, saved, "Resizing is not a user move")
        manager.cardWidthDidChange(10_000)
        XCTAssertEqual(manager.cardSize.width, IndicatorWindow.cardSize.width, "Never wider than the capsule can draw")
        XCTAssertEqual(panel.frame.size, IndicatorWindow.windowSize)
        XCTAssertFalse(panel.isVisible)
    }

    /// Only the visible pill takes a click: the shadow margin and the
    /// corners outside its rounded ends hit nothing.
    func testOnlyTheVisiblePillIsClickable() throws {
        let manager = IndicatorWindowManager(defaults: defaults)
        manager.warmUp()
        manager.cardWidthDidChange(110)
        let panel = try XCTUnwrap(manager.window)
        let host = try XCTUnwrap(panel.contentView as? IndicatorHostingView)
        let pad = IndicatorWindow.panelPadding
        let card = host.bounds.insetBy(dx: pad, dy: pad)
        XCTAssertEqual(card.size, CGSize(width: 110, height: IndicatorWindow.cardSize.height))
        let inside = [NSPoint(x: card.midX, y: card.midY), NSPoint(x: card.minX + card.height / 2, y: card.midY),
                      NSPoint(x: card.maxX - 2, y: card.midY), NSPoint(x: card.midX, y: card.maxY - 1)]
        for point in inside {
            XCTAssertTrue(host.hitTest(point) === host, "\(point) is on the pill")
        }
        let outside = [NSPoint(x: 1, y: 1), NSPoint(x: host.bounds.midX, y: pad / 2), NSPoint(x: host.bounds.maxX - 1, y: host.bounds.midY),
                       NSPoint(x: card.minX + 1, y: card.minY + 1), NSPoint(x: card.maxX - 1, y: card.maxY - 1)]
        for point in outside {
            XCTAssertNil(host.hitTest(point), "\(point) is margin or outside a rounded end")
        }
        XCTAssertFalse(panel.isVisible)
    }
}
