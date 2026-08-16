import CSlopDeskFFI

/// Who is holding a pane's PTY foreground: is it `claude`, or something that commonly WRAPS one?
///
/// Pure string logic on a process name, validate-then-drop: every input is tolerated (empty, huge,
/// hostile, non-ASCII) without trapping; no force-unwrap on foreign text.
///
/// ## It reads a process name and nothing else
/// It used to read SCREENS too — a `coarseStatus(screen:)` over three tables of literal Claude TUI
/// cues, the Herdr-style no-hooks fallback from docs/41. That was a second screen matcher living in
/// Swift next to the manifest rule ladder, and it lost: the ladder covers nineteen agents with
/// upstream's own rules and a differential harness proving it, while the cue tables covered one
/// agent by hand. The ladder is now `rust/slopdesk-screend` (docs/52) and this type kept the half
/// that was never about a screen. `ClaudeSignal.manifestVerdict` — the signal those cues fed — is
/// still in the state machine, because a coarse verdict from ANY source folds through it.
public struct ClaudeProcessMatcher: Sendable {
    public init() {}

    /// True when the foreground process basename is exactly `claude`.
    /// Exact basename match — no substring false-positive (`claudefoo` ≠ claude).
    public func isClaudeRunning(processName: String) -> Bool {
        agentPredicate(processName) { bytes, len in
            slopdesk_agent_is_claude_running(bytes, len)
        }
    }

    /// True when the foreground basename is a known LAUNCHER/RUNTIME that commonly hosts a *wrapped*
    /// `claude` (the npm-installed `claude` bin is a `#!/usr/bin/env node` shebang, so the PTY
    /// foreground resolves to `node`; `npx`/`bun`/`deno` runtimes and `mise` shims likewise never
    /// classify as `claude`). A wrapper is **NOT presence** — it must never lift the presence floor
    /// (any `node` dev server would light the agent dot) — it only makes an ABSENCE *indeterminate*,
    /// so the ~1 Hz foreground poll does not terminate a hook/report-established status while the
    /// wrapper holds the PTY foreground. Shells are deliberately NOT listed: the shell returning to
    /// the foreground is the classic "claude exited" signal.
    ///
    /// The basename set is `rust/slopdesk-agent::process` (docs/55).
    public func isLikelyWrapper(processName: String) -> Bool {
        agentPredicate(processName) { bytes, len in
            slopdesk_agent_is_likely_wrapper(bytes, len)
        }
    }
}
