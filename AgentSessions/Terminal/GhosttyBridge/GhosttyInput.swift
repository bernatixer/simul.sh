import AppKit
import Foundation
import Ghostty

/// NSEvent/String ⇄ libghostty input conversion. Ported from Ghostty's
/// macOS app (NSEvent+Extension.swift, Ghostty.Input.swift) and kept in one
/// place so libghostty types never leak into the rest of the app.
enum GhosttyInput {
    // MARK: Mods

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    static func modifierFlags(fromMods mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: Scroll mods

    static func scrollMods(precision: Bool, momentumPhase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if precision { value |= 0b1 }
        value |= Int32(momentum(phase: momentumPhase)) << 1
        return ghostty_input_scroll_mods_t(value)
    }

    private static func momentum(phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case []: return 0
        case .began: return 1
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0
        }
    }

    // MARK: Mouse buttons

    static func mouseButton(fromNSEventButtonNumber number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT
        case 4: return GHOSTTY_MOUSE_NINE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_FOUR
        case 8: return GHOSTTY_MOUSE_FIVE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }
}

extension NSEvent {
    /// Builds a libghostty key event. `text`/`composing` are set by the caller.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(keyCode)
        key_ev.text = nil
        key_ev.composing = false
        key_ev.mods = GhosttyInput.mods(modifierFlags)
        key_ev.consumed_mods = GhosttyInput.mods(
            (translationMods ?? modifierFlags).subtracting([.control, .command])
        )
        key_ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }
        return key_ev
    }

    /// The text to attach to a key event, or nil for function keys/control
    /// characters which libghostty encodes itself.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}

extension String {
    /// Text suitable for a terminal key event; nil when empty or control input.
    var keyEventText: String? {
        guard let scalar = unicodeScalars.first else { return nil }
        guard !isEmpty, !(scalar.value < 0x20 || scalar.value == 0x7F) else { return nil }
        return self
    }
}
