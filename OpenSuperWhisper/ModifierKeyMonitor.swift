import AppKit
import Carbon
import Foundation

enum ModifierKey: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case leftOption = "leftOption"
    case rightOption = "rightOption"
    case leftShift = "leftShift"
    case rightShift = "rightShift"
    case leftControl = "leftControl"
    case rightControl = "rightControl"
    case fn = "fn"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "None"
        case .leftCommand: return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .leftShift: return "Left ⇧ Shift"
        case .rightShift: return "Right ⇧ Shift"
        case .leftControl: return "Left ⌃ Control"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "Fn"
        }
    }
    
    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .leftCommand: return "⌘"
        case .rightCommand: return "⌘"
        case .leftOption: return "⌥"
        case .rightOption: return "⌥"
        case .leftShift: return "⇧"
        case .rightShift: return "⇧"
        case .leftControl: return "⌃"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }
    
    var keyCode: UInt16 {
        switch self {
        case .none: return 0
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftControl: return 59
        case .rightControl: return 62
        case .fn: return 63
        }
    }
    
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        case .fn: return .function
        }
    }
    
    var cgEventFlag: CGEventFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftShift, .rightShift: return .maskShift
        case .leftControl, .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }
    
    var isCommandOrOption: Bool {
        switch self {
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            return true
        default:
            return false
        }
    }
}

/// Pure press/release tracking for one or more trigger modifier keys.
///
/// Any configured key can start a press. While that key is held, the other
/// configured keys are ignored so a second key cannot inject a spurious
/// key-up or key-down in the middle of a hold-to-record gesture.
struct ModifierKeyTriggerState {
    enum Transition: Equatable {
        case keyDown(ModifierKey)
        case keyUp(ModifierKey)
        /// A regular key or mouse button was used while the trigger key was
        /// held, so the press was a shortcut chord (e.g. ⌃C), not dictation.
        case chord(ModifierKey)
    }

    let modifierKeys: [ModifierKey]
    private(set) var pressedKey: ModifierKey?
    private(set) var chordDetected = false

    init(modifierKeys: [ModifierKey]) {
        var unique: [ModifierKey] = []
        for key in modifierKeys where key != .none && !unique.contains(key) {
            unique.append(key)
        }
        self.modifierKeys = unique
    }

    var isEmpty: Bool { modifierKeys.isEmpty }

    mutating func handleFlagsChanged(keyCode: UInt16, flags: CGEventFlags) -> Transition? {
        guard let key = modifierKeys.first(where: { $0.keyCode == keyCode }) else { return nil }

        let isPressed = flags.contains(key.cgEventFlag)

        if isPressed {
            guard pressedKey == nil else { return nil }
            pressedKey = key
            chordDetected = false
            return .keyDown(key)
        }

        guard pressedKey == key else { return nil }
        pressedKey = nil
        let wasChord = chordDetected
        chordDetected = false
        return wasChord ? nil : .keyUp(key)
    }

    /// Call for any non-modifier input (key down, mouse down) observed while
    /// monitoring. Returns `.chord` the first time it happens during a press.
    mutating func handleOtherInput() -> Transition? {
        guard let key = pressedKey, !chordDetected else { return nil }
        chordDetected = true
        return .chord(key)
    }

    mutating func reset() {
        pressedKey = nil
        chordDetected = false
    }
}

class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var triggerState = ModifierKeyTriggerState(modifierKeys: [])

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    /// Fired when the held trigger key turns out to be part of a shortcut chord.
    var onChord: (() -> Void)?

    private init() {}

    func start(modifierKey: ModifierKey) {
        start(modifierKeys: [modifierKey])
    }

    /// Monitors every key in `modifierKeys`; any of them toggles recording.
    func start(modifierKeys: [ModifierKey]) {
        let state = ModifierKeyTriggerState(modifierKeys: modifierKeys)
        guard !state.isEmpty else {
            stop()
            return
        }

        stop()

        triggerState = state
        
        // Key-down and mouse-down events are observed only to notice that the
        // trigger modifier is being used in a chord (⌃C, ⌃-click, Fn+arrow).
        // Their key codes and contents are never read or stored.
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                
                let monitor = Unmanaged<ModifierKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                
                if type == .flagsChanged {
                    monitor.handleFlagsChanged(event: event)
                } else {
                    monitor.handleOtherInput()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("ModifierKeyMonitor: Failed to create event tap. Check accessibility permissions.")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            let names = triggerState.modifierKeys.map(\.displayName).joined(separator: ", ")
            print("ModifierKeyMonitor: Started monitoring for \(names)")
        }
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        triggerState.reset()
        print("ModifierKeyMonitor: Stopped")
    }
    
    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Re-enabled tap after timeout")
        }
    }
    
    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch triggerState.handleFlagsChanged(keyCode: keyCode, flags: event.flags) {
        case .keyDown:
            DispatchQueue.main.async {
                self.onKeyDown?()
            }
        case .keyUp:
            DispatchQueue.main.async {
                self.onKeyUp?()
            }
        case .chord, nil:
            break
        }
    }

    private func handleOtherInput() {
        guard case .chord = triggerState.handleOtherInput() else { return }
        DispatchQueue.main.async {
            self.onChord?()
        }
    }
    
    deinit {
        stop()
    }
}
