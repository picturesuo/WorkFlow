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

    // MARK: Dock status detail

    func testDockStatusDetailStringsAreUnchanged() {
        let shortcut = "⌃ / fn"
        let expected: [(DictationDockStatus, String)] = [
            (.ready, "Press ⌃ / fn to dictate anywhere"),
            (.recording(7), "0:07 · Stop when you’re finished"),
            (.meeting(3_725), "1:02:05 · Stop to save it to History"),
            (.connecting, "Your microphone is getting ready"),
            (.transcribing, "You can keep browsing your history"),
            (.loadingModel, "You can keep browsing your history"),
            (.processingQueue, "You can keep browsing your history"),
            (.savingMeeting, "You can keep browsing your history"),
            (.noMicrophone, "Connect a microphone to start dictating"),
        ]
        for (status, detail) in expected {
            XCTAssertEqual(status.detail(shortcut: shortcut), detail, "\(status)")
        }
        XCTAssertEqual(DictationDockStatus.ready.detail(shortcut: ""), "Click the microphone to start")
    }

    /// The Auto hint may be dropped from the line when it does not fit, but
    /// VoiceOver reads it at every width.
    func testDockAutoHintIsAlwaysSpoken() {
        let full = "0:07 · Stop when you’re finished · Auto picks the filter after"
        for width in [360.0, 440, 560, 900] {
            let spoken = AccessibilityTree.withSwiftUITree {
                let dock = OffscreenHost(
                    DictationDock(status: .recording(7), shortcut: "⌃⌥⇧⌘ Space / Middle mouse button",
                                  writingSelection: .constant(.builtIn(.everyday)), writingAuto: .constant(true),
                                  onRecord: {}),
                    size: CGSize(width: width, height: 120)
                )
                return Self.spokenText(in: dock.host)
            }
            XCTAssertTrue(spoken.contains { $0.contains(full) }, "\(Int(width)) pt: \(spoken)")
        }
    }

    // MARK: History rows

    func testFailureDetailStripsOnlyTheKnownPrefix() {
        XCTAssertEqual(HistoryRow.failureDetail("Failed to transcribe: The speech model could not process the audio."),
                       "The speech model could not process the audio.")
        XCTAssertEqual(HistoryRow.failureDetail("The speech model could not process the audio."),
                       "The speech model could not process the audio.")
        XCTAssertEqual(HistoryRow.failureDetail(""), "")
        XCTAssertEqual(HistoryRow.failureDetail("Failed to transcribe: "), "")
        XCTAssertEqual(HistoryRow.failureDetail("Retry: Failed to transcribe: the file"), "Retry: Failed to transcribe: the file")
        XCTAssertEqual(HistoryRow.failureDetail("Failed to transcribe:no space"), "Failed to transcribe:no space")
    }

    // MARK: Microphone menu

    func testMicrophoneMenuKeepsItsNameAndValue() {
        let microphone = MainWindowFixtures.microphone
        let menu = AccessibilityTree.withSwiftUITree {
            let host = OffscreenHost(
                MicrophoneMenu(microphones: [microphone], currentID: microphone.id, onSelect: { _ in }),
                size: CGSize(width: 40, height: 30)
            )
            return (AccessibilityTree.labels(in: host.host, roles: [.popUpButton, .menuButton]), Self.spokenText(in: host.host))
        }
        XCTAssertEqual(menu.0, ["Microphone"], "\(menu.1)")
        XCTAssertTrue(menu.1.contains(microphone.displayName), "\(menu.1)")
    }

    // MARK: Permissions

    func testPermissionRowSpeaksTitleDescriptionAndButton() {
        let spoken = AccessibilityTree.withSwiftUITree {
            let row = OffscreenHost(
                PermissionRow(isGranted: false, title: "Microphone Access", description: "Required for audio recording", action: {}),
                size: CGSize(width: 480, height: 90)
            )
            return Self.spokenText(in: row.host)
        }
        for text in ["Microphone Access", "Required for audio recording", "Grant Microphone Access"] {
            XCTAssertTrue(spoken.contains(text), "\(text): \(spoken)")
        }
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
