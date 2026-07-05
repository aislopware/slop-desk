import Foundation

/// The `TERM` policy for the host PTY.
///
/// W11 retired the dedicated curated `claude` launch (a Claude session is now just a `.terminal` pane,
/// auto-detected — see `ClaudePaneDetector` / docs/42 W11, DECISIONS #5). With it gone, the only part of
/// the old ``ClaudeCodeProfile`` still referenced anywhere is the ``Term`` choice (read by
/// ``TerminfoResolver`` and ``HostServer`` to resolve the advertised `TERM`, and surfaced as
/// `HostEnvironment.defaultTerm`). The dead members — the curated `environment(parent:)`, the
/// `forcedKeys`/`inheritedKeys` allowlists, `loginShellArguments()`, and the `ClaudeAuthResolver` /
/// `AuthStrategy` credential resolver — were removed in P4 (review #12) as unreachable production code.
///
/// ## TERM choice (doc 14 — "Quyết định 1") + the documented toggle
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
