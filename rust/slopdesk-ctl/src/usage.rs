//! The `--help` text.
//!
//! Verbatim from the Swift original, with the program name substituted the same way — a caller
//! that renamed the binary sees its own name in the usage line.

/// Renders the usage text for `program`.
#[must_use]
pub fn usage(program: &str) -> String {
    format!(
        "usage: {program} [--socket PATH] <subcommand> [args...]

Subcommands:
  list-panes [--json]
      List all live panes.  --json emits the raw NDJSON response line.

  read <paneId> [--ansi] [--full] [--lines N] [--unwrapped]
      Dump the pane's scrollback.  --ansi keeps ANSI escape codes (default: stripped).
      --full reads the complete scrollback ring (overrides --lines).
      --lines N limits output to the last N lines.
      --unwrapped (alias --recent) returns logical lines (joined chunks, ANSI-stripped,
      split on hard newlines, partial trailing line dropped) so a regex is robust to
      read-chunk boundaries.  Combine with --lines N for the last N logical lines.

  screen <paneId> [--rows N] [--cols N] [--json]
      Dump the RENDERED screen: the host replays the pane's scrollback through its VT
      screen model at the live PTY size and returns the visible grid — a TUI pane
      (vim, htop, claude) reads as what a human sees, not raw escape-code soup.
      --rows/--cols override the grid size.  --json adds cursor position, altScreen
      flag, and the untrimmed per-row lines array.

  last-output <paneId> [--n N] [--ansi] [--json]
      The last N finished commands as OSC-133 blocks: command line, output, exit code,
      duration — no prompt scraping.  Default N=1.  A still-running command is noted.
      --ansi keeps escapes in output.  --json emits the raw NDJSON response.
      Requires shell integration marks (SLOPDESK_BLOCKS on, default).

  write <paneId> [--text \"...\"] [--key K[,K...]]
      Send raw text bytes and/or named keys to the pane's PTY (no implicit Enter).
      --key takes tmux send-keys names, comma-separated or repeated:
        Enter Tab Space Esc Backspace Delete Up Down Left Right Home End
        PageUp PageDown F1..F12 C-<x> (Ctrl, e.g. C-c) M-<x> (Alt/Meta)
      Text is sent before keys: --text \"ls\" --key Enter runs ls.

  run <paneId> --cmd \"...\" [--wait] [--timeout-ms N] [--ansi] [--json]
      Send text + Enter to the pane (execute a shell command).
      --wait blocks until the command's OSC-133 block closes, prints its output, and
      exits with the COMMAND's exit code (timeout → exit 124, \"timeout\" on stderr).
      A status line \"exit <code> (<duration>ms)\" goes to stderr.

  wait <paneId> (--until \"<regex>\" | --state S) [--timeout-ms N]
      Block until pane output matches <regex> (ANSI-stripped), or — with --state —
      until the pane's agent state is in S (comma-set of idle|working|done|blocked,
      e.g. --state done,blocked).
      Prints \"matched (Nms)\" (regex) / the matched state and exits 0.
      Prints \"timeout after Nms\" to stderr and exits 1 on timeout.
      Default timeout: 30000ms.

  spawn [--cmd \"...\"] [--cwd \"...\"] [--env K=V] [--rows N] [--cols N]
      Spawn a new standalone PTY pane.  Prints the new paneId to stdout.
      --cmd is passed as $SHELL -c \"<cmd>\".  Without --cmd, spawns the login shell.

  kill <paneId>
      Kill a pane by its UUID id.

  subscribe <paneId> [--ansi]
      Stream live PTY output as NDJSON event lines until the pane exits.
      Each line is one of:
        {{\"event\":\"output\",\"text\":\"<plain-text chunk>\"}}
        {{\"event\":\"closed\"}}
      --ansi keeps ANSI escape codes in event text (default: stripped).
      Prints event lines to stdout.  Exits 0 when the pane closes.

  resize <paneId> --rows N --cols N
      Resize the pane's PTY to N rows × N cols (1–65535 each).

  report <paneId> --state idle|working|done|blocked [--message \"...\"] [--json]
      Self-declare this pane's agent supervision state (authoritative — beats the
      foreground heuristic).  Use from inside a spawned agent pane.  --message attaches a
      human label (the blocking question / last line).

  events [--json]
      Stream top-level supervision events: one NDJSON line per pane status transition
      across ALL panes, until disconnected.  Line shape:
        {{\"type\":\"agent_status_changed\",\"paneId\":\"…\",\"state\":\"…\",\"title\":\"…\",\"ts\":…}}
      COARSE-STATE ONLY: an event fires on a state change (idle/working/blocked/done);
      a same-state `report` that only updates the --message does NOT re-emit (no message
      field is carried).  Use `read --unwrapped` to fetch the latest blocking prompt text.

Flags:
  --socket PATH   Override the control socket path.

Socket resolution (in order):
  1. --socket flag
  2. SLOPDESK_CONTROL_SOCKET environment variable
  3. Fatal error — no socket known.
"
    )
}

#[cfg(test)]
mod tests {
    use super::usage;

    #[test]
    fn the_usage_line_carries_the_programs_own_name() {
        assert!(usage("slopdesk-ctl").starts_with("usage: slopdesk-ctl [--socket PATH]"));
        assert!(usage("ctl2").starts_with("usage: ctl2 [--socket PATH]"));
    }

    #[test]
    fn the_braces_in_the_ndjson_examples_survive_the_format_string() {
        let text = usage("slopdesk-ctl");
        assert!(
            text.contains(r#"{"event":"output","text":"<plain-text chunk>"}"#),
            "{text}"
        );
        assert!(text.contains(r#"{"event":"closed"}"#));
        assert!(text.contains(r#"{"type":"agent_status_changed","#));
    }

    #[test]
    fn every_subcommand_the_dispatcher_accepts_is_documented() {
        let text = usage("slopdesk-ctl");
        for verb in [
            "list-panes",
            "read",
            "screen",
            "last-output",
            "write",
            "run",
            "wait",
            "spawn",
            "kill",
            "subscribe",
            "events",
            "report",
            "resize",
        ] {
            assert!(
                text.contains(&format!("\n  {verb} ")) || text.contains(&format!("\n  {verb}\n")),
                "usage never mentions `{verb}`"
            );
        }
    }
}
