import AppKit
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// What VoiceOver reads and what the main window's smaller components say,
/// rendered offscreen without opening devices or touching History.
@MainActor
final class MainWindowPolishTests: XCTestCase {
    // MARK: History load error

    func testCompactLoadErrorBarSpeaksItsTextAndRetry() {
        let spoken = AccessibilityTree.withSwiftUITree {
            let bar = OffscreenHost(
                HistoryLoadError(message: "History couldn’t load. Try again.", onRetry: {}, compact: true),
                size: CGSize(width: 440, height: 40)
            )
            return Self.spokenText(in: bar.host)
        }
        XCTAssertTrue(spoken.contains("Couldn’t load more history"), "\(spoken)")
        XCTAssertTrue(spoken.contains("Try Again"), "\(spoken)")
    }

    // MARK: Helpers

    /// Every label, title and string value VoiceOver can read below
    /// `element`, in tree order. SwiftUI's own elements are not
    /// `NSAccessibilityProtocol` values in Swift, so each is read through
    /// its Objective-C accessibility getters.
    static func spokenText(in element: Any, depth: Int = 0) -> [String] {
        guard depth < 60, let node = element as? NSObject else { return [] }
        func read(_ getter: String) -> Any? {
            let selector = NSSelectorFromString(getter)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        var text: [String] = []
        for getter in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            switch read(getter) {
            case let string as String where !string.isEmpty: text.append(string)
            case let attributed as NSAttributedString where attributed.length > 0: text.append(attributed.string)
            default: break
            }
        }
        for child in read("accessibilityChildren") as? [Any] ?? [] {
            text += spokenText(in: child, depth: depth + 1)
        }
        return text
    }
}
