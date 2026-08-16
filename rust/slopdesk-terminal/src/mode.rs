//! What the host's terminal is presenting, and the markers that say so.

/// Which screen the host's terminal is currently presenting.
///
/// Derived from the host→client output byte stream (docs/14 §"External input box" A: sniff
/// DECSET/DECRST 1049 before feeding ghostty — libghostty's surface is opaque, so we sniff
/// ourselves).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TerminalMode {
    /// Main screen — a shell prompt / inline content. The external input box runs in **'A' (shell
    /// command)** mode here.
    #[default]
    ShellPrompt,
    /// Alternate screen — a fullscreen TUI (vim, btop, Claude Code interactive). The external input
    /// box runs in **'B1' (TUI compose)** mode here.
    AltScreen,
}

/// An event emitted by [`TerminalModeTracker`](crate::tracker::TerminalModeTracker) as it parses
/// the output stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TerminalModeEvent {
    /// The terminal entered the alternate screen (`ESC[?1049h`, or legacy `?47h`/`?1047h`).
    EnteredAltScreen,
    /// The terminal left the alternate screen (`ESC[?1049l`, or legacy `?47l`/`?1047l`).
    ExitedAltScreen,
    /// OSC 133;A — prompt start (shell integration).
    PromptStart,
    /// OSC 133;B — command start / prompt end (the user is about to type / has typed).
    CommandStart,
    /// OSC 133;C — command output begins.
    CommandStarted,
    /// OSC 133;D[;exit] — command finished, with an optional decoded exit code.
    CommandFinished {
        /// The decoded exit code, when the mark carried one that parsed.
        exit_code: Option<i64>,
    },
}
