import AppKit
import SwiftUI

// MARK: - Window sizing

/// A container whose own size never depends on its content: at least
/// `minimum`, `ideal` when a dimension is unspecified, otherwise whatever
/// is proposed. The window's minimum-size query therefore costs nothing.
struct FixedMinimumSizeLayout: Layout {
    var minimum: CGSize
    var ideal: CGSize
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: Self.dimension(proposal.width, minimum.width, ideal.width),
               height: Self.dimension(proposal.height, minimum.height, ideal.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(bounds.size))
        }
    }
    func spacing(subviews: Subviews, cache: inout ()) -> ViewSpacing { ViewSpacing() }
    static func dimension(_ proposed: CGFloat?, _ minimum: CGFloat, _ ideal: CGFloat) -> CGFloat {
        guard let proposed else { return ideal }
        return max(proposed, minimum)   // an infinite proposal stays infinite: the window may grow freely
    }
}

// MARK: - Spacing & radii

enum WFSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum WFRadius {
    static let card: CGFloat = 14
    /// The floating dictation bar.
    static let bar: CGFloat = 20
    /// A fill behind one row or a small group of controls.
    static let panel: CGFloat = 10
}

// MARK: - Type

/// The few text sizes the app uses, so every surface reads as one system.
/// They follow the system text styles, so they scale with the Mac's text size.
enum WFType {
    /// A window or pane title.
    static let title = Font.title2.weight(.semibold)
    /// The name of a group of rows, or a day in History.
    static let sectionLabel = Font.callout.weight(.semibold)
    /// What a dictation says.
    static let transcript = Font.body
    /// Time, length, and how a text was produced.
    static let meta = Font.subheadline
    /// The one line that says what is happening now.
    static let status = Font.body.weight(.semibold)
}

// MARK: - Motion

enum WFMotion {
    static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.9)
    /// A state change on the record control: quick, with no bounce.
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// How fast a level meter follows the voice.
    static let level = Animation.easeOut(duration: 0.12)

    /// The animation to use, or none when Reduce Motion is on.
    static func unlessReduced(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Reduce Motion as the system reports it, unless a subtree overrides it.
@propertyWrapper
struct WFReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.reduceMotionOverride) private var override

    var wrappedValue: Bool { override ?? system }
}

private struct ReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Forces Reduce Motion on or off for a subtree, which the system value
    /// cannot be; nil follows the system. Renders and previews use it.
    var reduceMotionOverride: Bool? {
        get { self[ReduceMotionOverrideKey.self] }
        set { self[ReduceMotionOverrideKey.self] = newValue }
    }
}

// MARK: - Palette

/// Charcoal ink on clean white in light mode and ivory ink on near black in
/// dark mode. The mark's two colors carry the brand; every surface around
/// them is a quiet neutral, so text and the record control stand out.
enum ThemePalette {
    private static func gray(_ value: Double) -> Color {
        Color(red: value / 255, green: value / 255, blue: value / 255)
    }

    /// Behind grouped content: Settings, onboarding, the permissions screen.
    static func windowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 22 / 255, green: 22 / 255, blue: 23 / 255)
            : Color(red: 246 / 255, green: 246 / 255, blue: 245 / 255)
    }

    /// A quiet fill with no border: an example, a summary, a hovered row.
    static func panelSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.055)
            : Color.black.opacity(0.04)
    }

    static func panelBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.07)
    }

    /// A group of rows, or anything that floats above the window.
    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 32 / 255, green: 32 / 255, blue: 34 / 255)
            : gray(255)
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.07)
    }

    static func cardShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color.black.opacity(0.04)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    /// The main window's toolbar. It shares the History's surface, so the
    /// window reads as one sheet with the title bar part of it.
    static func chromeBackground(_ scheme: ColorScheme) -> Color {
        contentBackground(scheme)
    }

    /// The History list and anything else that is read rather than set.
    static func contentBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? windowBackground(.dark) : gray(255)
    }

    /// The mark's charcoal in light mode and its ivory in dark mode: the record
    /// control, the ready state, and selection.
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? BrandPalette.ivory : BrandPalette.charcoal
    }

    /// Glyphs drawn on `ink`, like the W on its tile.
    static func onInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? BrandPalette.charcoal : BrandPalette.ivory
    }

    /// Words that do something when clicked. They are the ink itself, set
    /// apart from the text around them by weight rather than by a hue
    /// (17:1 on cards in light mode, 13:1 in dark).
    static func linkText(_ scheme: ColorScheme) -> Color {
        ink(scheme)
    }

    /// A link that should not pull the eye, such as "Show full text" under
    /// a transcript: the ink at reduced strength (4.9:1 on the History in
    /// light mode, 7:1 in dark).
    static func quietLink(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(0.62)
    }

    /// Live recording: a warm vermilion that sits with charcoal and ivory.
    /// White glyphs stay readable on it (5.3:1 light, 4.8:1 dark) and it
    /// stands out from the window at least 3:1 as a control should.
    static func signal(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 207 / 255, green: 63 / 255, blue: 51 / 255)
            : Color(red: 196 / 255, green: 55 / 255, blue: 44 / 255)
    }

    /// Words in the recording and failure color. Light mode uses the signal
    /// itself (4.8:1 on the window); dark mode lifts it to stay above 4.5:1
    /// on the darker surfaces, where the fill would read only 3.5:1.
    static func signalText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 242 / 255, green: 115 / 255, blue: 104 / 255)
            : signal(.light)
    }

    /// Recoverable problems: amber text that keeps 4.5:1 on its surface.
    static func caution(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? BrandPalette.amber
            : Color(red: 150 / 255, green: 88 / 255, blue: 0 / 255)
    }

    /// Done, granted, ready: a green quiet enough to sit beside the ink and
    /// still read as text (5.0:1 on cards in light mode, 7.6:1 in dark).
    static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 98 / 255, green: 196 / 255, blue: 141 / 255)
            : Color(red: 30 / 255, green: 126 / 255, blue: 78 / 255)
    }

    /// Fill for switches, prominent buttons, and checkboxes: the charcoal in
    /// light mode and a neutral gray in dark mode. White labels stay readable
    /// on it (17:1 light, 4.7:1 dark), and setting it explicitly keeps a
    /// user-chosen system accent from recoloring the app.
    static let controlTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 116 / 255, green: 116 / 255, blue: 118 / 255, alpha: 1)
            : NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 28 / 255, alpha: 1)
    })
}

// MARK: - Brand mark

/// The WorkFlow mark, drawn from the bundled `AppIcon.icns` so the window and
/// the Dock always show the same logo.
struct WorkFlowMark: View {
    var size: CGFloat = 24

    static let image = NSImage(named: "AppIcon")

    var body: some View {
        Image(nsImage: Self.image ?? NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Main window chrome

enum WFChrome {
    /// The title bar band the main window's toolbar row shares with the
    /// traffic lights (an empty compact toolbar centers them in it).
    static let titleBarHeight: CGFloat = 40
    /// Clears the traffic lights, which end 72 pt from the leading edge.
    static let trafficLightInset: CGFloat = 84
}

/// A one-point separator between window regions. In a stack it also keeps
/// the History scroll view from reaching under the toolbar band, where macOS
/// 26 would otherwise extend it with a glass edge over the toolbar row.
struct WFHairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(ThemePalette.hairline(colorScheme))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A toolbar glyph with the hover plate macOS toolbar items show.
struct ToolbarGlyph: View {
    let systemImage: String
    var tint: Color = .secondary
    var size: CGFloat = 28
    var symbolSize: CGFloat = 15
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(isHovered && isEnabled && tint == .secondary ? Color.primary : tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered && isEnabled ? ThemePalette.ink(colorScheme).opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    var tint: Color = .secondary
    let action: () -> Void

    init(
        systemImage: String,
        help: String,
        accessibilityLabel: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ToolbarGlyph(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The system search field, so search looks and behaves as it does in
/// Mail or Notes: magnifier, clear button, Escape to clear, focus ring.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(prompt)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        /// Also fires for the clear button and Escape.
        @objc func searchChanged(_ sender: NSSearchField) {
            if text.wrappedValue != sender.stringValue { text.wrappedValue = sender.stringValue }
        }
    }
}

// MARK: - Surface card

struct SurfaceCard: ViewModifier {
    var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(ThemePalette.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: WFRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WFRadius.card, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? ThemePalette.ink(colorScheme).opacity(0.22)
                            : ThemePalette.cardBorder(colorScheme),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: ThemePalette.cardShadow(colorScheme),
                radius: isHovered ? 8 : 3,
                y: isHovered ? 2 : 1
            )
    }
}

/// A control surface that floats over content: translucent, softly lit at
/// its edge, and lifted by a wide shadow, so what scrolls beneath shows
/// through without competing with it.
struct FloatingBar: ViewModifier {
    var cornerRadius: CGFloat = WFRadius.bar
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(ThemePalette.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.78))
                    .background { shape.fill(Material.regularMaterial) }
            }
            .overlay { shape.strokeBorder(ThemePalette.panelBorder(colorScheme), lineWidth: 1) }
            .clipShape(shape)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.10), radius: 16, y: 6)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.05), radius: 2, y: 1)
    }
}

extension View {
    func surfaceCard(isHovered: Bool = false) -> some View {
        modifier(SurfaceCard(isHovered: isHovered))
    }

    func floatingBar(cornerRadius: CGFloat = WFRadius.bar) -> some View {
        modifier(FloatingBar(cornerRadius: cornerRadius))
    }
}

// MARK: - Window chrome

/// Makes the hidden-title-bar window draggable by its background so the
/// toolbar row can act as the title bar, and gives it an empty compact
/// toolbar, which centers the traffic lights in a band that row shares.
struct WindowChromeConfigurator: NSViewRepresentable {
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "WorkFlowMainWindow")
            }
            window.toolbarStyle = .unifiedCompact
        }
    }

    func makeNSView(context: Context) -> NSView {
        ChromeView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Date formatting

enum WFDateFormat {
    static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Elapsed time

enum WFTime {
    /// A running clock: 0:07, 12:40, 1:02:03.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
