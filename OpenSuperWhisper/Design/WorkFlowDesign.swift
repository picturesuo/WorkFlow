import AppKit
import SwiftUI

// MARK: - Spacing & radii

enum WFSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum WFRadius {
    static let control: CGFloat = 10
    static let card: CGFloat = 14
}

// MARK: - Motion

enum WFMotion {
    static let quick = Animation.spring(response: 0.28, dampingFraction: 0.85)
    static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

// MARK: - Palette

enum ThemePalette {
    static func windowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.105, green: 0.105, blue: 0.12)
            : Color(red: 0.965, green: 0.965, blue: 0.975)
    }

    static func panelSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.04)
            : Color.black.opacity(0.025)
    }

    static func panelBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.145, green: 0.145, blue: 0.165)
            : Color.white
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 0.88, green: 0.88, blue: 0.93)
    }

    static func cardShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color.black.opacity(0.025)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    static func iconAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? BrandPalette.lavender : BrandPalette.violet
    }

    static func linkText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? BrandPalette.lavender : BrandPalette.violet
    }

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [BrandPalette.violet, BrandPalette.lavender],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Button style

struct WFPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(reduceMotion ? nil : WFMotion.quick, value: configuration.isPressed)
    }
}

// MARK: - Toolbar icon button

struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    var tint: Color = .secondary
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

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
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: WFRadius.control, style: .continuous)
                        .fill(isHovered
                              ? BrandPalette.violet.opacity(0.14)
                              : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: WFRadius.control, style: .continuous))
        }
        .buttonStyle(WFPressableStyle())
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
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
                    .stroke(
                        isHovered
                            ? BrandPalette.violet.opacity(0.35)
                            : ThemePalette.cardBorder(colorScheme),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: ThemePalette.cardShadow(colorScheme),
                radius: isHovered ? 6 : 2,
                y: isHovered ? 2 : 1
            )
    }
}

extension View {
    func surfaceCard(isHovered: Bool = false) -> some View {
        modifier(SurfaceCard(isHovered: isHovered))
    }
}

// MARK: - Window chrome

/// Makes the hidden-title-bar window draggable by its background so the custom
/// header row can act as the title bar.
struct WindowChromeConfigurator: NSViewRepresentable {
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
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
