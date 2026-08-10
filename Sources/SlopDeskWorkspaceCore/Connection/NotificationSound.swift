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

// MARK: - Code-agent attention sounds

/// Which macOS system sound announces an agent attention edge. The rawValue is the `NSSound(named:)`
/// name resolved from `/System/Library/Sounds` — kept as a plain string here so the policy module stays
/// AppKit-free; the actuation site owns the `NSSound` call.
public enum AgentSound: String, Sendable {
    /// The agent finished its task and went idle.
    case taskComplete = "Submarine"
    /// The agent is blocked waiting for approval / input.
    case awaitInput = "Glass"
}

/// The PURE decision for the **Code Agent sound** cues, riding the same `onAgentAttention` edge as the
/// toast/banner.
///
/// **The sound is NOT focus-gated — the toast is** (user-directed 2026-08-10). The two surfaces answer
/// different questions and the split is the point: a card is a PANE SPEAKING FROM OFF-SCREEN, so it is
/// suppressed for the pane you are looking at (the finished turn is right there on screen and a card
/// over it would be spam), but the CUE is what tells you an edge happened at all, and "the pane is
/// focused" is not evidence anyone was looking at it. A focused pane is routinely the one left running
/// in a background window, or on a second display, or behind the browser the user switched to while the
/// turn ran. Task-complete used to stay silent for a focused pane, which is exactly the case where the
/// user is most likely waiting for the ring and least likely to be watching the glyph.
///
/// Both events therefore gate on their own toggle ALONE. `sourcePaneFocused` is kept in the signature
/// and deliberately unused: the parameter documents that focus reaches this decision and is REFUSED by
/// it, so a later reader cannot mistake the absence of the input for an oversight.
public enum AgentSoundPolicy {
    public static func sound(
        needsInput: Bool,
        sourcePaneFocused _: Bool,
        soundTaskComplete: Bool,
        soundAwaitInput: Bool,
    ) -> AgentSound? {
        if needsInput {
            return soundAwaitInput ? .awaitInput : nil
        }
        return soundTaskComplete ? .taskComplete : nil
    }
}
