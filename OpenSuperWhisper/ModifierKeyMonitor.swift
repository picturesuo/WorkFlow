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

/// A two-key shortcut that starts dictation only while both keys are held.
enum ModifierChord: String, CaseIterable, Identifiable {
    case none = "none"
    case controlFn = "controlFn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .controlFn: return "Control + Fn (hold both)"
        }
    }

    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .controlFn: return "⌃ + fn"
        }
    }
}

/// Pure press/release tracking for the Control+Fn chord.
///
/// Dictation starts only when Control (either side) and the physical Fn key
/// are both held with no other modifier, key, or click since the first of
/// them went down, in either order. Releasing either key finishes. Fn or
/// Control alone never starts anything. Fn is tracked only from its own
/// key code: arrow and function keys also carry the Fn flag.
struct ModifierChordTriggerState {
    enum Transition: Equatable {
        case keyDown
        case keyUp
        /// Another modifier, key, or click joined the held chord, so it was a
        /// shortcut (⌃⇧ fn, ⌃ fn ←), not dictation.
        case chord
    }

    private static let fnKeyCode = ModifierKey.fn.keyCode
    private static let otherModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]

    private(set) var isControlDown = false
    private(set) var isFnDown = false
    private(set) var isActive = false
    /// Set once anything else happens while a chord key is held. Cleared only
    /// when both keys are up, so a stray press can't turn into dictation.
    private(set) var isSpoiled = false

    mutating func handleFlagsChanged(keyCode: UInt16, flags: CGEventFlags) -> Transition? {
        isControlDown = flags.contains(.maskControl)
        if keyCode == Self.fnKeyCode {
            isFnDown = flags.contains(.maskSecondaryFn)
        } else if !flags.contains(.maskSecondaryFn) {
            isFnDown = false
        }

        guard isControlDown || isFnDown else {
            let wasActive = isActive
            reset()
            return wasActive ? .keyUp : nil
        }

        let hasOtherModifier = !flags.intersection(Self.otherModifiers).isEmpty
        if isActive {
            if hasOtherModifier {
                isActive = false
                isSpoiled = true
                return .chord
            }
            if !(isControlDown && isFnDown) {
                isActive = false
                isSpoiled = true
                return .keyUp
            }
            return nil
        }

        if hasOtherModifier {
            isSpoiled = true
            return nil
        }
        guard isControlDown, isFnDown, !isSpoiled else { return nil }
        isActive = true
        return .keyDown
    }

    /// Call for any non-modifier input (key down, mouse down) observed while
    /// monitoring. Returns `.chord` when it cancels an active chord.
    mutating func handleOtherInput() -> Transition? {
        guard isControlDown || isFnDown else { return nil }
        isSpoiled = true
        guard isActive else { return nil }
        isActive = false
        return .chord
    }

    mutating func reset() {
        isControlDown = false
        isFnDown = false
        isActive = false
        isSpoiled = false
    }
}

class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trigger = Trigger.keys(ModifierKeyTriggerState(modifierKeys: []))

    /// What the tap listens for: any one of several keys, or a held chord.
    enum Trigger {
        case keys(ModifierKeyTriggerState)
        case chord(ModifierChordTriggerState)
    }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    /// Fired when the held trigger key turns out to be part of a shortcut chord.
    var onChord: (() -> Void)?

    /// Tests drive their own instance; the app uses `shared`.
    init() {}

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
        start(.keys(state), description: state.modifierKeys.map(\.displayName).joined(separator: ", "))
    }

    /// Monitors a chord; only holding all of its keys toggles recording.
    func start(chord: ModifierChord) {
        guard chord != .none else {
            stop()
            return
        }
        start(.chord(ModifierChordTriggerState()), description: chord.displayName)
    }

    private func start(_ newTrigger: Trigger, description: String) {
        stop()
        trigger = newTrigger

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
                
                monitor.handle(type: type, event: event)
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
            print("ModifierKeyMonitor: Started monitoring for \(description)")
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
        trigger = .keys(ModifierKeyTriggerState(modifierKeys: []))
        print("ModifierKeyMonitor: Stopped")
    }
    
    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Re-enabled tap after timeout")
        }
    }
    
    /// Installs a trigger without an event tap, so tests can feed events to
    /// `handle(type:event:)` without asking macOS for Input Monitoring.
    func configureForTesting(_ newTrigger: Trigger) {
        trigger = newTrigger
    }

    /// The tap's single entry point: a modifier change, or any other key or
    /// click that may turn the held trigger into a shortcut chord.
    func handle(type: CGEventType, event: CGEvent) {
        if type == .flagsChanged {
            handleFlagsChanged(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags)
        } else {
            handleOtherInput()
        }
    }

    private enum Output {
        case keyDown, keyUp, chord
    }

    private func handleFlagsChanged(keyCode: UInt16, flags: CGEventFlags) {
        switch trigger {
        case .keys(var state):
            let transition = state.handleFlagsChanged(keyCode: keyCode, flags: flags)
            trigger = .keys(state)
            switch transition {
            case .keyDown: emit(.keyDown)
            case .keyUp: emit(.keyUp)
            case .chord, nil: break
            }
        case .chord(var state):
            let transition = state.handleFlagsChanged(keyCode: keyCode, flags: flags)
            trigger = .chord(state)
            switch transition {
            case .keyDown: emit(.keyDown)
            case .keyUp: emit(.keyUp)
            case .chord: emit(.chord)
            case nil: break
            }
        }
    }

    private func handleOtherInput() {
        switch trigger {
        case .keys(var state):
            let transition = state.handleOtherInput()
            trigger = .keys(state)
            if case .chord = transition { emit(.chord) }
        case .chord(var state):
            let transition = state.handleOtherInput()
            trigger = .chord(state)
            if case .chord = transition { emit(.chord) }
        }
    }

    private func emit(_ output: Output) {
        DispatchQueue.main.async {
            switch output {
            case .keyDown: self.onKeyDown?()
            case .keyUp: self.onKeyUp?()
            case .chord: self.onChord?()
            }
        }
    }
    
    deinit {
        stop()
    }
}
