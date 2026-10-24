import AppKit

/// Reads the names VoiceOver hears from SwiftUI views rendered offscreen.
@MainActor
enum AccessibilityTree {
    /// SwiftUI builds its accessibility tree only once an assistive client
    /// asks, so act as one (the way VoiceOver does) and stop afterwards.
    static func withSwiftUITree<T>(_ body: () throws -> T) rethrows -> T {
        let setValue = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        _ = NSApp.perform(setValue, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { _ = NSApp.perform(setValue, with: NSNumber(value: false), with: "AXEnhancedUserInterface") }
        return try body()
    }

    /// The names VoiceOver reads for elements with these roles, in tree order.
    static func labels(in element: Any, roles: Set<NSAccessibility.Role>, depth: Int = 0) -> [String] {
        guard depth < 60, let node = element as? NSAccessibilityProtocol else { return [] }
        var labels: [String] = []
        if let role = node.accessibilityRole(), roles.contains(role) {
            labels.append(node.accessibilityLabel() ?? "")
        }
        for child in node.accessibilityChildren() ?? [] {
            labels += Self.labels(in: child, roles: roles, depth: depth + 1)
        }
        return labels
    }
}
