import Foundation

/// The Herdr-style NO-HOOKS fallback (docs/41 §2.2, §4.2 signal 3): given a terminal
/// pane's title and/or recent screen text, detect (a) whether `claude` is running and
/// (b) a coarse status (working vs waiting-for-input vs idle) from recognizable Claude
/// Code TUI cues.
///
/// **Conservative by construction** (Herdr's rule): a verdict is returned ONLY on a
/// known cue; an ambiguous / non-Claude / empty screen yields `nil`. "Blocked"
/// (`.needsPermission`) is emitted only on a known approval/permission UI — never guessed.
/// Pure string logic, validate-then-drop: every input is tolerated (empty, huge, hostile,
/// non-ASCII) without trapping; no force-unwrap on foreign text.
///
/// **Precedence** (when several cues co-occur in a scrolled buffer): a live approval UI
/// (`.needsPermission`) outranks a possibly-stale spinner line; a spinner outranks the
/// idle compose box.
public struct ClaudeManifestMatcher: Sendable {
    public init() {}

    // MARK: Presence

    /// True when the foreground process basename is exactly `claude`.
    /// Exact basename match — no substring false-positive (`claudefoo` ≠ claude).
    public func isClaudeRunning(processName: String) -> Bool {
        guard !processName.isEmpty else { return false }
        // Basename of the path (works for "claude" and "/usr/local/bin/claude").
        let base = processName.split(separator: "/").last.map(String.init) ?? processName
        return base == "claude"
    }

    /// True when an OSC 2 title names Claude (weak corroboration).
    public func isClaudeRunning(title: String) -> Bool {
        guard !title.isEmpty else { return false }
        return title.range(of: "claude", options: .caseInsensitive) != nil
    }

    /// True when the foreground basename is a known LAUNCHER/RUNTIME that commonly hosts a *wrapped*
    /// `claude` (the npm-installed `claude` bin is a `#!/usr/bin/env node` shebang, so the PTY
    /// foreground resolves to `node`; `npx`/`bun`/`deno` runtimes and `mise` shims likewise never
    /// classify as `claude`). A wrapper is **NOT presence** — it must never lift the presence floor
    /// (any `node` dev server would light the agent dot) — it only makes an ABSENCE *indeterminate*,
    /// so the ~1 Hz foreground poll does not terminate a hook/report-established status while the
    /// wrapper holds the PTY foreground (queue-safety fix, 2026-07-02). Shells are deliberately NOT
    /// listed: the shell returning to the foreground is the classic "claude exited" signal.
    public func isLikelyWrapper(processName: String) -> Bool {
        guard !processName.isEmpty else { return false }
        let base = processName.split(separator: "/").last.map(String.init) ?? processName
        return Self.wrapperBasenames.contains(base)
    }

    /// Known wrapper/runtime basenames (exact match, like the `claude` presence match).
    static let wrapperBasenames: Set<String> = ["node", "npx", "bun", "deno", "mise"]

    // MARK: Coarse status from screen text

    /// A coarse status from the recent screen buffer, or `nil` when no known cue matches.
    /// Returns `.working` (spinner), `.needsPermission` (approval/trust prompt), `.idle`
    /// (empty compose box), or `nil` (unsure — the caller keeps its prior verdict).
    public func coarseStatus(screen: String) -> ClaudeStatus? {
        // Validate-then-drop: nothing to read.
        let trimmed = screen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = screen.lowercased()

        // 1. Permission / approval / trust UI — the strongest, most conservative cue. A live
        //    approval prompt outranks any (possibly stale) spinner line left in the buffer.
        if matchesPermission(lower) {
            return .needsPermission
        }

        // 2. Working spinner — the "esc to interrupt" interrupt hint Claude shows while a turn runs.
        if matchesWorking(lower) {
            return .working
        }

        // 3. Idle compose box — the bordered input with the empty-prompt hint and no spinner.
        if matchesIdle(lower) {
            return .idle
        }

        // Unknown / ambiguous → no verdict (conservative).
        return nil
    }

    // MARK: Cue tables (conservative literal matches, case-folded)

    /// Approval / permission / trust UI — only well-known Claude Code prompt lines.
    private func matchesPermission(_ lower: String) -> Bool {
        for cue in Self.permissionCues where lower.contains(cue) {
            return true
        }
        return false
    }

    /// The working spinner — the universal "esc to interrupt" interrupt affordance.
    private func matchesWorking(_ lower: String) -> Bool {
        for cue in Self.workingCues where lower.contains(cue) {
            return true
        }
        return false
    }

    /// The idle compose box — the empty-prompt hint Claude renders at rest.
    private func matchesIdle(_ lower: String) -> Bool {
        for cue in Self.idleCues where lower.contains(cue) {
            return true
        }
        return false
    }

    /// Known approval/permission/trust prompt lines (lowercased). Conservative.
    static let permissionCues: [String] = [
        "do you want to proceed?",
        "do you want to make this edit",
        "do you want to create",
        "do you trust the files",
        "no, and tell claude what to do differently",
    ]

    /// Known working-spinner cues (lowercased). The interrupt hint is the reliable one.
    static let workingCues: [String] = [
        "esc to interrupt",
        "interrupt)",
    ]

    /// Known idle compose-box cues (lowercased).
    static let idleCues: [String] = [
        "? for shortcuts",
        "try \"edit ",
        "or ask a question",
    ]
}
