import AppKit
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Renders the custom filter views without opening, activating, or capturing a
/// window. Fixtures are synthetic and never touch the user's History.
@MainActor
final class CustomCleanupFilterLayoutTests: XCTestCase {
    private var savedValues: [String: Any] = [:]
    private let keys = [
        CustomCleanupFilterStore.dataKey,
        CustomCleanupFilterStore.selectedIDKey,
        CustomCleanupFilterStore.modeKey
    ]

    override func setUp() {
        super.setUp()
        for key in keys {
            savedValues[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            UserDefaults.standard.set(savedValues[key], forKey: key)
        }
        super.tearDown()
    }

    func testFilterCardWithSavedFiltersAndEditor() throws {
        let digits = CustomCleanupFilterStore.examples[0]
        let hyphens = CustomCleanupFilterStore.examples[2]
        CustomCleanupFilterStore.save([digits, hyphens])
        CustomCleanupFilterStore.select(.custom(digits.id))

        let draft = CustomCleanupFilter(name: "Technical with words", baseMode: .technical, instructions: "")
        for (name, view) in [
            ("list", AnyView(CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences()))),
            ("editor", AnyView(CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences(), newDraft: draft))),
            ("picker", AnyView(WritingFilterPicker(
                selection: .constant(.custom(digits.id)),
                customFilters: [digits, hyphens]
            )))
        ] {
            for scheme in [ColorScheme.light, .dark] {
                try render(view, name: "custom-filters-\(name)", scheme: scheme)
            }
        }
    }

    private func render(_ view: AnyView, name: String, scheme: ColorScheme) throws {
        let width = 560.0
        let content = view
            .padding()
            .frame(width: width)
            .background(Color(.windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        XCTAssertGreaterThan(size.height, 20)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name)-\(scheme == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(window.isVisible, "Visual verification must stay offscreen")
    }
}
