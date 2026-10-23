import SwiftUI

// MARK: - Pane chrome

/// The pane switcher at the top of Settings, drawn like a macOS settings
/// toolbar: a symbol over a short label, the current pane filled.
struct SettingsPaneBar: View {
    @Binding var selection: SettingsPane
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WFSpace.xs) {
            ForEach(Array(SettingsPane.allCases.enumerated()), id: \.element) { index, pane in
                let isSelected = pane == selection
                Button {
                    selection = pane
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                            .frame(height: 20)
                        Text(pane.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 84, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? ThemePalette.ink(colorScheme).opacity(colorScheme == .dark ? 0.12 : 0.07) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("\(pane.title) (⌘\(index + 1))")
                .accessibilityLabel(pane.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

/// A pane's title and one-line purpose.
struct SettingsPaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Groups and rows

/// A titled group of rows on one card, like a System Settings group.
/// Separate rows with `SettingsDivider`.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSurface()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// A setting's name, an optional one-sentence explanation, and its control.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: WFSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .settingsRowPadding()
    }
}

/// A switch row whose VoiceOver label is the visible title.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var accessibilityHint: String?

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityHint(accessibilityHint ?? detail ?? "")
        }
    }
}

struct SettingsDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(ThemePalette.hairline(colorScheme))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

/// An amber notice inside a group: what is wrong, why it matters, and the fix.
struct SettingsNotice<Action: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            action
        }
        .settingsRowPadding()
    }
}

/// A row that reveals rarely needed settings in place.
struct SettingsDisclosureRow: View {
    let title: String
    var detail: String?
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(WFMotion.gentle) { isExpanded.toggle() }
            }
        } label: {
            HStack(spacing: WFSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .settingsRowPadding()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(detail ?? "")
    }
}

/// A small link-styled button in the brand's link color.
struct SettingsLinkButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(ThemePalette.linkText(colorScheme))
            .fixedSize()
    }
}

/// A web link in the brand's link color instead of the system blue.
struct SettingsWebLink: View {
    let title: String
    let destination: URL
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(ThemePalette.linkText(colorScheme))
        }
        .help(destination.host ?? destination.absoluteString)
    }
}

// MARK: - Surfaces

private struct SettingsSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(ThemePalette.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
            )
    }
}

extension View {
    /// The card every settings group sits on.
    func settingsSurface() -> some View {
        modifier(SettingsSurface())
    }

    func settingsRowPadding() -> some View {
        padding(.horizontal, 14).padding(.vertical, 10)
    }
}
