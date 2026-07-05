import Foundation

/// Which screen the host's terminal is currently presenting, as derived from the
/// host->client output byte stream (doc 14 §"Ô input ngoài" A: sniff DECSET/DECRST 1049
/// before feeding ghostty — libghostty's surface is opaque, so we sniff ourselves).
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
