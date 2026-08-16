import CSlopDeskFFI

/// The macOS virtual keyCodes of the **held** modifier keys — the ONE shared vocabulary for every
/// input-path policy that treats a modifier key edge specially. Pure data, no wire impact: keyCodes
/// ride the existing `InputEvent.key` message unchanged.
///
/// Used on BOTH ends of the GUI-video input path:
/// - **Client** (`SlopDeskVideoClientSession.keySendCount`): a modifier key-UP is sent with the same
///   N-times redundancy as a `mouseUp` — a lost release datagram permanently latches the modifier on
///   the host's shared `CGEventSource(.hidSystemState)` (every later plain scroll becomes ⌘-scroll)
///   until the user happens to press+release that modifier again.
/// - **Host** (`InputButtonBalance.plan`): per-keyCode duplicate suppression collapses that redundant
///   burst to ONE posted CGEvent (a release for an already-up modifier is a no-op; a down for an
///   already-down one likewise), mirroring the mouseUp idempotence.
///
/// **Caps Lock (57) is deliberately EXCLUDED**: it is a TOGGLE, not a held key. A synthesized down or
/// up on virtualKey 57 FLIPS the host's Caps state, so it must never ride the latch/resync/release/
/// redundancy machinery — its genuine `flagsChanged` edges forward 1:1 and post verbatim.
///
/// The table itself is `slopdesk-video`'s: the host's ledger keys its held-modifier bits on a key's
/// POSITION in it, so a table spelled twice would be a ledger that means one thing on one side of
/// the door and another on the other.
public enum InputModifierKeys {
    /// The Caps Lock virtual keyCode — the toggle key every held-modifier policy must skip.
    public static let capsLockKeyCode = slopdesk_input_caps_lock_key_code()

    /// Left+right ⌘ (55/54), ⇧ (56/60), ⌃ (59/62), ⌥ (58/61), and fn (63). Left/right variants are
    /// distinct keys (distinct latched flags), so policies key on the exact keyCode.
    public static let heldModifierKeyCodes: Set<UInt16> = {
        let needed = slopdesk_input_modifier_key_codes(nil, 0)
        var codes = [UInt16](repeating: 0, count: needed)
        let written = codes.withUnsafeMutableBufferPointer { room in
            slopdesk_input_modifier_key_codes(room.baseAddress, room.count)
        }
        return written == needed ? Set(codes) : []
    }()

    /// Whether `keyCode` is a held modifier key (never true for Caps Lock or an ordinary key).
    public static func isHeldModifier(_ keyCode: UInt16) -> Bool {
        heldModifierKeyCodes.contains(keyCode)
    }
}
