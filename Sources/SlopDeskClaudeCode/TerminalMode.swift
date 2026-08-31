import CSlopDeskFFI

/// Which screen the host's terminal is currently presenting, as derived from the
/// host->client output byte stream (doc 14 §"External input box" A: sniff DECSET/DECRST 1049
/// before feeding `libghostty-vt` — its session state is opaque, so we sniff ourselves).
public enum TerminalMode: Sendable, Equatable {
    /// Main screen — a shell prompt / inline content. The external input box runs in
    /// **'A' (shell command)** mode here.
    case shellPrompt
    /// Alternate screen — a fullscreen TUI (vim, btop, Claude Code interactive /
    /// fullscreen). The external input box runs in **'B1' (TUI compose)** mode here.
    case altScreen
}

/// An event emitted by ``TerminalModeTracker`` as it parses the output stream.
public enum TerminalModeEvent: Sendable, Equatable {
    /// The terminal entered the alternate screen (`ESC[?1049h`, or legacy `?47h`/`?1047h`).
    case enteredAltScreen
    /// The terminal left the alternate screen (`ESC[?1049l`, or legacy `?47l`/`?1047l`).
    case exitedAltScreen

    /// OSC 133;A — prompt start (shell integration).
    case promptStart
    /// OSC 133;B — command start / prompt end (the user is about to type / has typed).
    case commandStart
    /// OSC 133;C — command output begins.
    case commandStarted
    /// OSC 133;D[;exit] — command finished, with an optional decoded exit code.
    case commandFinished(exitCode: Int?)
}

public extension TerminalModeEvent {
    /// Rebuilds one parked event out of the door's flat record. `nil` for the defined non-event,
    /// which a correct read never sees — the count came from the same call that parked the run.
    ///
    /// It lives ON the type rather than beside a reader because it is the case list crossing as a
    /// DISCRIMINANT, which `docs/55` §6 makes a contract: the enum's cases are one vocabulary in two
    /// type systems, and the mapping between them has exactly one right spelling. It had two — the
    /// mode tracker's and the input box's, identical down to the doc comment — which is two places
    /// for a new `SLOPDESK_MODE_EVENT_*` to be added in one of.
    init?(_ record: SlopDeskModeEvent) {
        switch record.kind {
        case UInt32(SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN): self = .enteredAltScreen
        case UInt32(SLOPDESK_MODE_EVENT_EXITED_ALT_SCREEN): self = .exitedAltScreen
        case UInt32(SLOPDESK_MODE_EVENT_PROMPT_START): self = .promptStart
        case UInt32(SLOPDESK_MODE_EVENT_COMMAND_START): self = .commandStart
        case UInt32(SLOPDESK_MODE_EVENT_COMMAND_STARTED): self = .commandStarted
        case UInt32(SLOPDESK_MODE_EVENT_COMMAND_FINISHED):
            self = .commandFinished(exitCode: record.has_exit_code ? Int(record.exit_code) : nil)
        default: return nil
        }
    }
}
