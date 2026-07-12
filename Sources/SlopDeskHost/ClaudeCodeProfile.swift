import Foundation

/// The `TERM` policy for the host PTY.
///
/// A Claude session is just a `.terminal` pane, auto-detected (see `ClaudePaneDetector`, docs/42,
/// DECISIONS #5) — there is no dedicated curated `claude` launch path. The only part of
/// ``ClaudeCodeProfile`` that's still referenced anywhere is the ``Term`` choice (read by
/// ``TerminfoResolver`` and ``HostServer`` to resolve the advertised `TERM`, and surfaced as
/// `HostEnvironment.defaultTerm`). Do not reintroduce a curated `environment(parent:)`,
/// `forcedKeys`/`inheritedKeys` allowlists, `loginShellArguments()`, or a `ClaudeAuthResolver` /
/// `AuthStrategy` credential resolver here — that machinery has no caller and would be dead code.
///
/// ## TERM choice (doc 14 — Decision 1) and the operator toggle
/// Default `TERM=xterm-ghostty`: native libghostty TERM → kitty keyboard protocol (Shift+Enter, modifier
/// combos) + DEC 2026 synchronized-output auto-detect. This accepts the risk of the multi-line paste bug
/// (#54700). If that manifests, the operator toggles to `.xterm256` (`xterm-256color`), which disables
/// DEC 2026 but avoids the paste-tokenization bug.
public enum ClaudeCodeProfile {
    /// The `TERM` value to advertise into the PTY.
    public enum Term: String, Sendable, Equatable {
        /// Native libghostty TERM (kitty keyboard + DEC 2026). Default.
        case ghostty = "xterm-ghostty"
        /// Documented fallback that mitigates the multi-line paste bug (#54700); disables DEC 2026
        /// synchronized output.
        case xterm256 = "xterm-256color"
    }
}
