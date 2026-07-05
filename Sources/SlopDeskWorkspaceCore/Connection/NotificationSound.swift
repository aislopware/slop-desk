import Foundation

// MARK: - Bell / error-exit sound policy (E14/K10 — the PURE "should this beep" decisions)

/// The PURE decision for the **Sound — Shell Controlled** bell: a `BEL` (`0x07`) rings the system
/// alert sound (`NSSound.beep()`) iff the toggle is on (default ON). Audio-only — there is no
/// visual/flash bell. `UN`-free + AppKit-free so the rule is unit-tested without a real `NSSound`; the
/// actuation stays behind the existing injected `beep` seam on ``TerminalViewModel``.
public enum BellPolicy {
    /// Ring on a `BEL` iff `soundShellControlled` is on.
    public static func shouldBeep(soundShellControlled: Bool) -> Bool {
        soundShellControlled
    }
}

/// The PURE decision for the **Sound on Error Exit** beep: a command that exits non-zero beeps iff the
/// toggle is on (default OFF; requires shell integration / OSC 133). `exit == nil` (a completion carrying no
/// code) is treated as a clean exit 0 → no error beep, matching the BackgroundCompletionPolicy convention.
public enum ErrorSoundPolicy {
    /// Beep iff `soundOnErrorEnabled` AND the command exited non-zero.
    public static func shouldBeep(exit: Int32?, soundOnErrorEnabled: Bool) -> Bool {
        guard soundOnErrorEnabled else { return false }
        return (exit ?? 0) != 0
    }
}
