import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// "Learn…" in the menu bar opens the main window and asks for Settings on
/// Personalize. On a menu-bar-only launch the window, and so its listener,
/// does not exist yet when the request is made.
@MainActor
final class SettingsRequestTests: XCTestCase {
    private final class Presentation: ObservableObject {
        @Published var isPresented = false
        @Published var tab = 0
    }

    private struct Host: View {
        @ObservedObject var presentation: Presentation
        var body: some View {
            Color.clear
                .frame(width: 40, height: 40)
                .modifier(OpenSettingsRequests(isPresented: $presentation.isPresented, tab: $presentation.tab))
        }
    }

    private func host(_ presentation: Presentation) -> (NSWindow, NSHostingView<Host>) {
        let view = NSHostingView(rootView: Host(presentation: presentation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testRequestBeforeTheMainWindowExistsOpensPersonalizeWhenItAppears() async {
        SettingsRequest.open(tab: SettingsView.personalizeTab)
        let presentation = Presentation()
        let (window, _) = host(presentation)
        await settle()

        XCTAssertTrue(presentation.isPresented, "Before the fix the request was lost on a menu-bar-only launch")
        XCTAssertEqual(presentation.tab, SettingsView.personalizeTab)
        XCTAssertFalse(window.isVisible, "Verified offscreen")
    }

    func testRequestWhileTheWindowIsOpenStillOpensTheRequestedTab() async {
        let presentation = Presentation()
        let (window, _) = host(presentation)
        await settle()
        XCTAssertFalse(presentation.isPresented, "Nothing was requested")

        SettingsRequest.open()
        await settle()
        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.tab, 0)

        presentation.isPresented = false
        SettingsRequest.open(tab: SettingsView.personalizeTab)
        await settle()
        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.tab, SettingsView.personalizeTab)

        // A handled request is not replayed by the next window.
        let next = Presentation()
        let (nextWindow, _) = host(next)
        await settle()
        XCTAssertFalse(next.isPresented)
        XCTAssertFalse(window.isVisible || nextWindow.isVisible)
    }
}
