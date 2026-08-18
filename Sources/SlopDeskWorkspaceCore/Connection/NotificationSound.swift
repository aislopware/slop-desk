import CSlopDeskFFI

// MARK: - Bell / error-exit sound policy (the "should this beep" decisions)

/// The **Sound — Shell Controlled** bell: a `BEL` (`0x07`) rings the system alert sound
/// (`NSSound.beep()`) iff the toggle is on (default ON). Audio-only — there is no visual/flash bell.
/// The rule is `slopdesk_workspace::notify`; the actuation stays behind the existing injected `beep`
/// seam on ``TerminalViewModel``.
public enum BellPolicy {
    /// Ring on a `BEL` iff `soundShellControlled` is on.
    public static func shouldBeep(soundShellControlled: Bool) -> Bool {
        slopdesk_ws_notify_should_ring_bell(soundShellControlled)
    }
}

/// The **Sound on Error Exit** beep: a command that exits non-zero beeps iff the toggle is on
/// (default OFF; requires shell integration / OSC 133). `exit == nil` (a completion carrying no code)
/// is a clean exit everywhere in `slopdesk_workspace::notify`, so it never beeps.
public enum ErrorSoundPolicy {
    /// Beep iff `soundOnErrorEnabled` AND the command exited non-zero.
    public static func shouldBeep(exit: Int32?, soundOnErrorEnabled: Bool) -> Bool {
        slopdesk_ws_notify_should_beep_on_error(exit ?? 0, exit != nil, soundOnErrorEnabled)
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

/// The **Code Agent sound** cues, riding the same `onAgentAttention` edge as the toast/banner.
///
/// **The sound is NOT focus-gated — the toast is** (user-directed 2026-08-10). `slopdesk_workspace::notify`
/// carries why. `sourcePaneFocused` is kept in the signature and deliberately unused: the parameter
/// documents that focus reaches this decision and is REFUSED by it, so a later reader cannot mistake
/// the absence of the input for an oversight.
public enum AgentSoundPolicy {
    public static func sound(
        needsInput: Bool,
        sourcePaneFocused _: Bool,
        soundTaskComplete: Bool,
        soundAwaitInput: Bool,
    ) -> AgentSound? {
        switch slopdesk_ws_notify_agent_sound(needsInput, soundTaskComplete, soundAwaitInput) {
        case 1: .taskComplete
        case 2: .awaitInput
        default: nil
        }
    }
}
