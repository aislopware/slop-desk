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
/// toast/banner. The two events gate differently on purpose: awaiting-input plays even while the source
/// pane is focused (the agent is standing still until the user acts — being "on screen" is no guarantee
/// of being noticed), while task-complete stays silent for a watched pane (the finished turn is right
/// there; only a background finish earns a cue).
public enum AgentSoundPolicy {
    public static func sound(
        needsInput: Bool,
        sourcePaneFocused: Bool,
        soundTaskComplete: Bool,
        soundAwaitInput: Bool,
    ) -> AgentSound? {
        if needsInput {
            return soundAwaitInput ? .awaitInput : nil
        }
        return soundTaskComplete && !sourcePaneFocused ? .taskComplete : nil
    }
}
