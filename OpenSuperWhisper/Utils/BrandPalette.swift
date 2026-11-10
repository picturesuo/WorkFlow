import SwiftUI

/// The two colors of the WorkFlow mark, an ivory ribbon W on charcoal
/// (`AppIcon.icns`). Interface tokens in `ThemePalette` derive from these.
enum BrandPalette {
    static let ivory = Color(red: 250 / 255, green: 244 / 255, blue: 231 / 255)
    static let charcoal = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
    /// Warnings on charcoal, such as the floating indicator (8.7:1).
    static let amber = Color(red: 242 / 255, green: 166 / 255, blue: 58 / 255)
}
