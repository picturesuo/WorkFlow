import AppKit
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Guards the WorkFlow brand: ivory and charcoal from the app icon, no
/// leftover violet palette, and readable contrast in light and dark.
@MainActor
final class BrandPaletteTests: XCTestCase {
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("OpenSuperWhisper")

    func testSourcesHaveNoRetiredPurplePalette() throws {
        let banned = ["violet", "lavender", "midnight", "brandGradient", "iconAccent"]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where banned.contains(where: { line.contains($0) }) {
                hits.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(hits, [], "Use ThemePalette tokens instead of the retired violet palette")
    }

    func testAccentColorAssetIsBrandTaupeInBothAppearances() throws {
        let url = Self.sourceRoot.appendingPathComponent("Assets.xcassets/AccentColor.colorset/Contents.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try XCTUnwrap(json["colors"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2, "Light and dark accents must both be explicit")
        for entry in entries {
            let components = try XCTUnwrap((entry["color"] as? [String: Any])?["components"] as? [String: String])
            func channel(_ key: String) throws -> CGFloat {
                let raw = try XCTUnwrap(components[key])
                return CGFloat(try XCTUnwrap(UInt8(raw.dropFirst(2), radix: 16))) / 255
            }
            let color = NSColor(srgbRed: try channel("red"), green: try channel("green"), blue: try channel("blue"), alpha: 1)
            assertNotPurple(color, "AccentColor")
        }
    }

    func testTokensAreWarmNeutralsWithReadableContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let card = resolved(ThemePalette.cardBackground(scheme), scheme)
            let window = resolved(ThemePalette.windowBackground(scheme), scheme)
            let ink = resolved(ThemePalette.ink(scheme), scheme)
            let onInk = resolved(ThemePalette.onInk(scheme), scheme)
            let link = resolved(ThemePalette.linkText(scheme), scheme)
            let tint = resolved(ThemePalette.controlTint, scheme)
            for (name, color) in [("card", card), ("window", window), ("ink", ink), ("onInk", onInk), ("link", link), ("tint", tint)] {
                assertNotPurple(color, "\(name) \(scheme)")
            }
            XCTAssertGreaterThanOrEqual(contrast(ink, card), 7, "ink on card \(scheme)")
            XCTAssertGreaterThanOrEqual(contrast(ink, window), 7, "ink on window \(scheme)")
            XCTAssertGreaterThanOrEqual(contrast(onInk, ink), 7, "glyph on record button \(scheme)")
            XCTAssertGreaterThanOrEqual(contrast(link, card), 4.5, "link text on card \(scheme)")
            XCTAssertGreaterThanOrEqual(contrast(.white, tint), 4.5, "white label on tinted control \(scheme)")
            XCTAssertGreaterThanOrEqual(contrast(tint, card), 3, "tinted control against card \(scheme)")
        }
        XCTAssertNotEqual(resolved(ThemePalette.controlTint, .light), resolved(ThemePalette.controlTint, .dark))
    }

    func testMarkIsTheBundledIvoryOnCharcoalAppIcon() throws {
        let icon = try XCTUnwrap(WorkFlowMark.image, "AppIcon.icns must ship in the app bundle")
        XCTAssertNotNil(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        var charcoal = 0, ivory = 0, purple = 0
        for x in 0..<128 {
            for y in 0..<128 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                if color.brightnessComponent < 0.15 { charcoal += 1 }
                if color.brightnessComponent > 0.9, color.saturationComponent < 0.15 { ivory += 1 }
                if isPurple(color) { purple += 1 }
            }
        }
        XCTAssertGreaterThan(charcoal, 4000, "charcoal tile")
        XCTAssertGreaterThan(ivory, 1500, "ivory ribbon W")
        XCTAssertEqual(purple, 0)
    }

    func testMenuBarTemplateIsTheRibbonW() throws {
        let image = try XCTUnwrap(NSImage(named: "tray_icon"))
        let side = 256
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var minX = side, maxX = 0, minY = side, maxY = 0, filled = 0
        for x in 0..<side {
            for y in 0..<side where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); filled += 1
            }
        }
        let width = Double(maxX - minX), height = Double(maxY - minY)
        XCTAssertGreaterThan(width / height, 1.35, "The W is wider than tall; the retired bear glyph was not")
        XCTAssertEqual(Double(filled) / Double(side * side), 0.08, accuracy: 0.02, "Same visual weight as the glyph it replaced")
        XCTAssertEqual(Double(minX + maxX) / 2, Double(side) / 2, accuracy: 4, "Centered for the status item")
    }

    private func assertNotPurple(_ color: NSColor, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(isPurple(color), "\(label) \(color) is purple", file: file, line: line)
    }
}

/// Renders the rebranded surfaces offscreen with synthetic fixtures and
/// isolated defaults. Nothing reads preferences, Keychain, or History.
@MainActor
final class BrandLayoutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BrandLayoutTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMainWindowUsesTheMarkAndNoPurpleAtCompactAndWideSizes() throws {
        for width in [440.0, 640.0] {
            for scheme in [ColorScheme.light, .dark] {
                let bitmap = try render(AnyView(MainWindowFixture(scheme: scheme, status: .ready)),
                                        name: "brand-main-\(Int(width))", width: width, scheme: scheme)
                XCTAssertEqual(purplePixels(in: bitmap), 0, "main \(Int(width)) \(scheme)")
            }
        }
    }

    func testDictationDockStatesStayDistinctAndOnBrand() throws {
        let states: [DictationDockStatus] = [.ready, .recording(83), .transcribing, .loadingModel, .noMicrophone, .meeting]
        for scheme in [ColorScheme.light, .dark] {
            let bitmap = try render(AnyView(VStack(spacing: 8) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, status in
                    DictationDock(status: status, shortcut: "fn", writingSelection: .constant(.builtIn(.everyday)),
                                  onLearn: {}, onRecord: {})
                }
            }.background(ThemePalette.windowBackground(scheme))), name: "brand-dock-states", width: 440, scheme: scheme)
            XCTAssertEqual(purplePixels(in: bitmap), 0, "dock \(scheme)")
        }
        XCTAssertEqual(DictationDockStatus.ready.detail(shortcut: "fn"), "Press fn to dictate anywhere")
        XCTAssertEqual(DictationDockStatus.ready.detail(shortcut: ""), "Click the microphone to start")
    }

    func testOnboardingAndSettingsSurfaces() throws {
        CustomCleanupFilterStore.save([CustomCleanupFilterStore.examples[0]], to: defaults)
        CustomCleanupFilterStore.select(.custom(CustomCleanupFilterStore.examples[0].id), in: defaults)
        for scheme in [ColorScheme.light, .dark] {
            let bitmaps = [
                try render(AnyView(OnboardingWelcomeHeader().padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ThemePalette.windowBackground(scheme))), name: "brand-onboarding-header", width: 440, scheme: scheme),
                try render(AnyView(HistoryEmptyState(isSearching: false).background(ThemePalette.windowBackground(scheme))),
                           name: "brand-empty-history", width: 440, scheme: scheme),
                try render(AnyView(CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences())
                    .padding().background(Color(.windowBackgroundColor))), name: "brand-settings-filters", width: 560, scheme: scheme),
                try render(AnyView(VStack(alignment: .leading, spacing: 12) {
                    Toggle("Hold to record", isOn: .constant(true)).toggleStyle(SwitchToggleStyle(tint: ThemePalette.controlTint))
                    Button("Done") {}.buttonStyle(.borderedProminent)
                    PermissionRow(isGranted: false, title: "Microphone Access", description: "Required for audio recording", action: {})
                }.padding().background(Color(.windowBackgroundColor))), name: "brand-settings-controls", width: 440, scheme: scheme),
            ]
            for bitmap in bitmaps {
                XCTAssertEqual(purplePixels(in: bitmap), 0, "\(scheme)")
            }
        }
    }

    func testIndicatorMessagesFitTheCardAndStayOnBrand() throws {
        let viewModel = IndicatorViewModel(
            latestDictationGate: LatestDictationGate(),
            transcriptionService: TranscriptionService(engine: ControlledTranscriptionEngine { _ in })
        )
        defer { viewModel.cleanup() }
        let states: [RecordingState] = [
            .connecting, .recording, .decoding, .busy, .noMicrophone,
            .recordingFailed, .transcriptionFailed, .pasteFailed, .clipboardFailed
        ]
        for scheme in [ColorScheme.light, .dark] {
            for state in states {
                viewModel.state = state
                let bitmap = try render(AnyView(IndicatorWindow(viewModel: viewModel)),
                                        name: "brand-indicator-\(state)", width: IndicatorWindow.windowSize.width, scheme: scheme)
                XCTAssertEqual(purplePixels(in: bitmap), 0, "\(state) \(scheme)")
            }
        }
    }

    @discardableResult
    private func render(_ view: AnyView, name: String, width: CGFloat, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let content = view
            .frame(width: width)
            .tint(ThemePalette.controlTint)
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(defaults)
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
        return bitmap
    }
}

private struct MainWindowFixture: View {
    let scheme: ColorScheme
    let status: DictationDockStatus

    private var recordings: [Recording] {
        let now = Date(timeIntervalSince1970: 1_789_257_600)
        return [
            Recording(id: UUID(), timestamp: now, fileName: "fixture-one.wav",
                      transcription: "Make the search faster, keep every detail, and give the words a little more room.",
                      duration: 18, status: .completed, progress: 1,
                      cleanupSource: .bedrock, cleanupInputTokens: 230, cleanupOutputTokens: 42,
                      cleanupModelID: "us.amazon.nova-micro-v1:0", cleanupMode: .technical,
                      rawTokenEstimate: 73, finalTokenEstimate: 42,
                      tokenEstimatorID: LocalTokenEstimator.identifier),
            Recording(id: UUID(), timestamp: now.addingTimeInterval(-1800), fileName: "fixture-two.wav",
                      transcription: "We agreed to simplify the recording flow and review the first version on Friday. Keep the current shortcuts, make failures easy to recover from, and give every recording a stable home in the history.",
                      duration: 9, status: .completed, progress: 1, cleanupSource: .rawFallback)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryHeader(searchText: .constant(""), isSearching: false) {
                HStack(spacing: WFSpace.sm) {
                    ToolbarIconButton(systemImage: "person.2.wave.2.fill", help: "Start meeting", accessibilityLabel: "Start meeting") {}
                    ToolbarIconButton(systemImage: "mic.fill", help: "Microphone", accessibilityLabel: "Select microphone") {}
                    ToolbarIconButton(systemImage: "trash", help: "Delete all recordings", accessibilityLabel: "Delete all recordings") {}
                    ToolbarIconButton(systemImage: "gear", help: "Settings", accessibilityLabel: "Open settings") {}
                }
            }
            VStack(spacing: WFSpace.md) {
                ForEach(recordings) { recording in
                    RecordingCard(recording: recording, searchQuery: "", isPlaying: false,
                                  onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {})
                }
            }
            .padding(.horizontal, WFSpace.xl)
            Spacer(minLength: WFSpace.md)
            DictationDock(status: status, shortcut: "fn", writingSelection: .constant(.builtIn(.technical)),
                          onLearn: {}, onRecord: {})
        }
        .frame(height: 640)
        .background(ThemePalette.windowBackground(scheme))
    }
}

@MainActor
private func resolved(_ color: Color, _ scheme: ColorScheme) -> NSColor {
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
    var result = NSColor.clear
    appearance.performAsCurrentDrawingAppearance {
        result = NSColor(color).usingColorSpace(.sRGB) ?? .clear
    }
    return result
}

/// Violet through lavender: the retired palette spans hues 235-257 degrees.
private func isPurple(_ color: NSColor) -> Bool {
    guard let srgb = color.usingColorSpace(.sRGB) else { return false }
    let hue = srgb.hueComponent * 360
    return (225...335).contains(hue) && srgb.saturationComponent > 0.3 && srgb.brightnessComponent > 0.25
}

private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    func luminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent) + 0.0722 * linear(srgb.blueComponent)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// Counts opaque purple pixels after converting the render to 8-bit sRGB.
private func purplePixels(in bitmap: NSBitmapImageRep) -> Int {
    guard let srgb = bitmap.converting(to: .sRGB, renderingIntent: .default),
          srgb.bitsPerSample == 8, srgb.samplesPerPixel == 4, !srgb.isPlanar,
          let data = srgb.bitmapData else { return Int.max }
    var count = 0
    for y in 0..<srgb.pixelsHigh {
        for x in 0..<srgb.pixelsWide {
            let p = data + y * srgb.bytesPerRow + x * 4
            guard p[3] > 127 else { continue }
            let color = NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
            if isPurple(color) { count += 1 }
        }
    }
    return count
}
