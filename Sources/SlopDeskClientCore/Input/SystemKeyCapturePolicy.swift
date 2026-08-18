// SystemKeyCapturePolicy — the near side of the immersive-mode system-key capture decision.
//
// The rules are `slopdesk_video::key_capture`: which chords must stay reachable while every key is
// being swallowed, which modifier edges may be forwarded at all, and how a modifier edge's direction
// is derived. What is here is the marshalling, and the one thing that cannot cross — `CGEventFlags`.
// Apple's flag constants stay on this side, where there is a header for them; the crate speaks the
// wire's own six-bit mask, which is what every other input door already carries.

#if os(macOS)
import CoreGraphics
import CSlopDeskFFI

/// The immersive-mode event tap's per-event decision. Stateless — modifier tracking (for the
/// stuck-key flush) is the controller's job, and the controller is the only actuator.
package enum SystemKeyCapturePolicy {
    /// What the tap callback does with one event. `Equatable` for the headless test pins.
    package enum Decision: Equatable {
        /// Deliver to the remote host and return `nil` from the tap callback (macOS never sees it).
        case forwardAndSwallow
        /// Return the event untouched — the local system/app handles it (the never-trap chords).
        case passThrough
        /// The escape chord: tear down capture. The chord itself is swallowed and NEVER forwarded — it is a
        /// client-side control, not input meant for either machine.
        case disengage
    }

    /// The one decision per tap event. `keyCode` = `.keyboardEventKeycode`, `flags` = the event's modifier
    /// flags, `type` = keyDown / keyUp / flagsChanged; anything else is an event the policy has no rule for.
    package static func decision(keyCode: UInt16, flags: CGEventFlags, type: CGEventType) -> Decision {
        switch slopdesk_key_capture_decision(keyCode, flags.wireMask, type.ffiByte) {
        case 0: .forwardAndSwallow
        case 2: .disengage
        default: .passThrough
        }
    }

    /// Whether the event is a press (`true`) or release (`false`) for the forward closure.
    package static func isDown(keyCode: UInt16, flags: CGEventFlags, type: CGEventType) -> Bool {
        slopdesk_key_capture_is_down(keyCode, flags.wireMask, type.ffiByte)
    }

    /// The coarse `CGEventFlags` bit a modifier keyCode drives, or `nil` for a keyCode that is not a known
    /// modifier key. The table is the crate's; this turns its answer back into Apple's constant.
    package static func modifierMask(for keyCode: UInt16) -> CGEventFlags? {
        let bit = slopdesk_key_capture_modifier_bit(keyCode)
        guard let bit = UInt8(exactly: bit) else { return nil }
        return CGEventFlags(wireMask: bit)
    }
}

// MARK: - CGEventFlags ⇄ the wire's six-bit mask

private extension CGEventFlags {
    /// Shift 1, control 2, option 4, command 8, caps lock 16, fn 32 — the mask
    /// `slopdesk_video::input_event::InputModifiers` carries. Every other bit `CGEventFlags` sets
    /// (the device-specific left/right ones, the numeric-pad and help bits) is dropped: the rules
    /// read only these six, and a chord is matched by containment so an extra bit could never
    /// change an answer anyway.
    var wireMask: UInt8 {
        var mask: UInt8 = 0
        if contains(.maskShift) { mask |= 1 << 0 }
        if contains(.maskControl) { mask |= 1 << 1 }
        if contains(.maskAlternate) { mask |= 1 << 2 }
        if contains(.maskCommand) { mask |= 1 << 3 }
        if contains(.maskAlphaShift) { mask |= 1 << 4 }
        if contains(.maskSecondaryFn) { mask |= 1 << 5 }
        return mask
    }

    /// The inverse, for the single-bit answer the modifier table gives.
    init(wireMask: UInt8) {
        var flags = CGEventFlags()
        if wireMask & (1 << 0) != 0 { flags.insert(.maskShift) }
        if wireMask & (1 << 1) != 0 { flags.insert(.maskControl) }
        if wireMask & (1 << 2) != 0 { flags.insert(.maskAlternate) }
        if wireMask & (1 << 3) != 0 { flags.insert(.maskCommand) }
        if wireMask & (1 << 4) != 0 { flags.insert(.maskAlphaShift) }
        if wireMask & (1 << 5) != 0 { flags.insert(.maskSecondaryFn) }
        self = flags
    }
}

private extension CGEventType {
    /// `0` key down · `1` key up · `2` flags changed · anything else the tap can deliver.
    var ffiByte: UInt8 {
        switch self {
        case .keyDown: 0
        case .keyUp: 1
        case .flagsChanged: 2
        default: 255
        }
    }
}
#endif
