import Foundation

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
public enum InputModifierKeys {
    /// The Caps Lock virtual keyCode — the toggle key every held-modifier policy must skip.
    public static let capsLockKeyCode: UInt16 = 57

    /// Left+right ⌘ (55/54), ⇧ (56/60), ⌃ (59/62), ⌥ (58/61), and fn (63). Left/right variants are
    /// distinct keys (distinct latched flags), so policies key on the exact keyCode.
    public static let heldModifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    /// Whether `keyCode` is a held modifier key (never true for Caps Lock or an ordinary key).
    public static func isHeldModifier(_ keyCode: UInt16) -> Bool {
        heldModifierKeyCodes.contains(keyCode)
    }
}
