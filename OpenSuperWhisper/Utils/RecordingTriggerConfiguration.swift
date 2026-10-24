import Foundation

/// The one shortcut that starts dictation, resolved from the stored
/// preferences. A mouse button wins over the Control+Fn chord, which wins
/// over a modifier key, which wins over the key combination.
enum RecordingTriggerConfiguration: Equatable {
    case mouseButton(MouseButton)
    case chord(ModifierChord)
    case modifierKeys(primary: ModifierKey, secondary: ModifierKey)
    case keyCombination

    init(mouseButton: MouseButton, chord: ModifierChord, modifierKey: ModifierKey, secondaryModifierKey: ModifierKey) {
        if mouseButton != .none {
            self = .mouseButton(mouseButton)
        } else if chord != .none {
            self = .chord(chord)
        } else if modifierKey != .none {
            self = .modifierKeys(primary: modifierKey, secondary: secondaryModifierKey)
        } else {
            self = .keyCombination
        }
    }

    init(preferences: AppPreferences = .shared) {
        self.init(
            mouseButton: MouseButton(rawValue: preferences.mouseButtonHotkey) ?? .none,
            chord: ModifierChord(rawValue: preferences.modifierChordHotkey) ?? .none,
            modifierKey: ModifierKey(rawValue: preferences.modifierOnlyHotkey) ?? .none,
            secondaryModifierKey: ModifierKey(rawValue: preferences.secondaryModifierOnlyHotkey) ?? .none
        )
    }

    /// Modifier keys and chords are read from a listen-only event tap, which
    /// macOS allows only with Input Monitoring. Without it they stay off;
    /// nothing falls back to a single key.
    var requiresInputMonitoring: Bool {
        switch self {
        case .chord, .modifierKeys: return true
        case .mouseButton, .keyCombination: return false
        }
    }

    /// Keycaps for hints, e.g. "⌃ + fn" or "fn / ⌃". Nil for the key
    /// combination, which KeyboardShortcuts describes.
    var symbol: String? {
        switch self {
        case .mouseButton(let button):
            return button.shortSymbol
        case .chord(let chord):
            return chord.shortSymbol
        case .modifierKeys(let primary, let secondary):
            if secondary != .none, secondary != primary {
                return "\(primary.shortSymbol) / \(secondary.shortSymbol)"
            }
            return primary.shortSymbol
        case .keyCombination:
            return nil
        }
    }
}
