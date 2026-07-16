// SystemKeyCapturePolicy — the PURE per-event decision for immersive-mode system-key capture
// (`SystemKeyCaptureController`), CoreGraphics-value-types-only (CGEventType/CGEventFlags — no AppKit, no live
// CGEvent) so every rule is unit-pinned headlessly (`SystemKeyCapturePolicyTests`) without ever creating an
// event tap. The controller destructures the tap's CGEvent into (keyCode, flags, type) and actuates whatever
// this returns; all POLICY lives here, all MECHANISM lives in the controller.
//
// SAFETY INVARIANT — never trap the user: while capture is engaged every key is swallowed locally, so the two
// local bail-outs must stay reachable no matter what: ⌘Q (local quit) and ⌘⌥Esc (Force Quit) ALWAYS pass
// through, and the escape chord ⌃⌥⌘E ALWAYS disengages (checked with `contains`, not equality, so a stuck
// caps-lock/fn/shift bit can never dead-lock the escape hatch). Weakening any of these turns an engaged pane
// into a keyboard trap whose only exit is another machine.

#if os(macOS)
import CoreGraphics

/// Pure decision table for the immersive-mode event tap: given the destructured key event, says whether the
/// controller forwards-and-swallows, passes through to macOS, or tears capture down. Stateless — modifier
/// tracking (for the stuck-key flush) is the controller's job.
enum SystemKeyCapturePolicy {
    /// What the tap callback does with one event. `Equatable` for the headless test pins.
    enum Decision: Equatable {
        /// Deliver to the remote host and return `nil` from the tap callback (macOS never sees it).
        case forwardAndSwallow
        /// Return the event untouched — the local system/app handles it (the never-trap chords).
        case passThrough
        /// The escape chord: tear down capture. The chord itself is swallowed and NEVER forwarded — it is a
        /// client-side control, not input meant for either machine.
        case disengage
    }

    // Hardware-independent virtual key codes (Carbon `kVK_ANSI_E` / `kVK_ANSI_Q` / `kVK_Escape`) — literal so
    // this file needs no Carbon import and stays a pure-value dependency.
    private static let keyCodeE: UInt16 = 14
    private static let keyCodeQ: UInt16 = 12
    private static let keyCodeEscape: UInt16 = 53

    /// The one decision per tap event. `keyCode` = `.keyboardEventKeycode`, `flags` = the event's modifier
    /// flags, `type` = keyDown / keyUp / flagsChanged (anything else falls out `.passThrough` — never swallow
    /// what the policy does not understand).
    static func decision(keyCode: UInt16, flags: CGEventFlags, type: CGEventType) -> Decision {
        switch type {
        case .flagsChanged:
            // A modifier key edge. Forward only the keys whose flag bit is known (the `modifierMask` table) —
            // an unmapped flagsChanged keyCode has no derivable isDown, and forwarding a guess would desync
            // the remote modifier state; let macOS keep it instead.
            return modifierMask(for: keyCode) != nil ? .forwardAndSwallow : .passThrough

        case .keyDown,
             .keyUp:
            // Escape chord ⌃⌥⌘E, keyDown only (the keyUp never reaches the tap — it is already gone).
            // `contains`, not `== [.maskControl, …]`: extra bits (caps lock, fn, shift, the device-specific
            // left/right bits CGEventFlags carries) must never make the escape hatch unreachable.
            if type == .keyDown, keyCode == keyCodeE,
               flags.contains(.maskControl), flags.contains(.maskAlternate), flags.contains(.maskCommand)
            {
                return .disengage
            }
            // ⌘Q (and ⌘⇧Q — log out is a bail-out too): local quit is never trapped. ⌥/⌃ variants are NOT
            // quit chords and forward like any key. Both the down AND the up pass through so the local app
            // sees a consistent pair.
            if keyCode == keyCodeQ, flags.contains(.maskCommand),
               !flags.contains(.maskControl), !flags.contains(.maskAlternate)
            {
                return .passThrough
            }
            // ⌘⌥Esc (and ⌘⌥⇧Esc — force-quit-frontmost): the Force Quit dialog is the user's recovery path
            // when the app itself wedges, so it must survive capture.
            if keyCode == keyCodeEscape, flags.contains(.maskCommand), flags.contains(.maskAlternate) {
                return .passThrough
            }
            // Everything else — including the chords immersive mode exists for (⌘Tab, ⌘Space, ⌘`, F-keys, and
            // media keys arriving as plain F-key events under "Use F1, F2… as standard function keys" / Fn) —
            // goes to the remote host. Local chord passthrough above still works even though flagsChanged is
            // swallowed: a keyDown's flags are synthesized from hardware modifier state, not from the
            // (deleted) flagsChanged deliveries.
            return .forwardAndSwallow

        default:
            return .passThrough
        }
    }

    /// Whether the event is a press (`true`) or release (`false`) for the forward closure. For flagsChanged
    /// the edge direction is derived the way remote-desktop tools track modifiers: isDown = the changed key's
    /// flag bit is NOW SET in the event's flags (a set bit means the key just went down; cleared means up).
    static func isDown(keyCode: UInt16, flags: CGEventFlags, type: CGEventType) -> Bool {
        switch type {
        case .keyDown: true
        case .keyUp: false
        case .flagsChanged: modifierMask(for: keyCode).map { flags.contains($0) } ?? false
        default: false
        }
    }

    /// The coarse CGEventFlags bit a modifier keyCode drives, or `nil` for a keyCode that is not a known
    /// modifier key. Left/right variants collapse onto the same mask on purpose — the forward closure carries
    /// the keyCode itself, so the remote host still knows WHICH physical key moved; only the isDown derivation
    /// needs the bit.
    static func modifierMask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, // kVK_RightCommand
             55: // kVK_Command
            .maskCommand
        case 56, // kVK_Shift
             60: // kVK_RightShift
            .maskShift
        case 58, // kVK_Option
             61: // kVK_RightOption
            .maskAlternate
        case 59, // kVK_Control
             62: // kVK_RightControl
            .maskControl
        case 57: // kVK_CapsLock
            .maskAlphaShift
        case 63: // kVK_Function
            .maskSecondaryFn
        default:
            nil
        }
    }
}
#endif
