import Foundation

/// A semantic Claude Code hook event, decoupled from any transport. Each case carries
/// ONLY the fields the state machine needs — not the full hook JSON. The adapter that
/// maps `SlopDeskInspector.HookPayload` / the wire `claudeStatus` message → this enum
/// lives in W8/W10; W7 stays standalone (this vocabulary is expressible from what
/// `HookIngest` can already produce: SessionStart/PostToolUse/SubagentStop, plus the
/// W8-added Notification/Stop/SessionEnd).
///
/// Maps to the Claude Code hook events (docs/41 §2.6):
/// `SessionStart` / `UserPromptSubmit` / `PreToolUse` / `PostToolUse` /
/// `Notification(permission_prompt|…)` / `Stop` / `SubagentStop` / `SessionEnd`.
public enum ClaudeHookEvent: Sendable, Equatable {
    /// Session opened (`startup`/`resume`/`clear`/`compact`) → claude is present & at rest.
    case sessionStart(sessionID: String?)
    /// A user prompt was submitted → a turn began (working).
    case userPromptSubmit(sessionID: String?)
    /// A tool is about to run → working (and clears a just-resolved permission block).
    /// `tool` is the tool name (e.g. `Bash`) — carried for diagnostics/labels; the coarse
    /// status only needs that a tool is starting.
    case preToolUse(sessionID: String?, tool: String?)
    /// A tool finished → still working until the turn's Stop (a tool result is mid-turn).
    case postToolUse(sessionID: String?, tool: String?)
    /// An async notification — `permission_prompt` / waiting-for-input → BLOCKED.
    case notification(kind: NotificationKind, label: String?)
    /// The turn ended → done (then idle after a timeout). `label` = last assistant message.
    case stop(sessionID: String?, label: String? = nil)
    /// A subagent stopped — does not change the parent pane's coarse status (kept for completeness).
    case subagentStop(agentID: String?)
    /// The session ended → claude is gone (none).
    case sessionEnd(sessionID: String?)
    /// A transcript COMPACTION is starting (`/compact`, or the automatic mid-turn one). Carries no
    /// status of its own — it ARMS a one-shot marker saying "the next turn end may be the
    /// compaction's, not a task's". See ``ClaudeStatusMachine`` for how the marker is spent: a
    /// `Stop` that arrives with it still armed lands on `.idle` instead of `.done`, so finishing a
    /// `/compact` stops announcing "Claude is done" for work nobody asked about (user-reported
    /// 2026-08-10); any real turn activity in between (a tool, a new prompt) disarms it, so an
    /// AUTO-compaction mid-turn still ends on a genuine `.done`.
    case preCompact(sessionID: String?)

    /// The semantic class of a `Notification` hook (matcher field, docs/41 §2.6).
    public enum NotificationKind: Sendable, Equatable {
        /// `permission_prompt` — Claude needs explicit approval to proceed. → blocked.
        case permission
        /// Claude is idle-waiting on the human to type the next thing. → blocked.
        case waitingForInput
        /// `auth_success` / `elicitation_complete` / anything else — informational only.
        case other
    }
}

/// The INPUT signals the machine consumes — hook events, process-presence, manifest
/// verdicts, OSC titles, and a clock `tick`. Transport-agnostic by construction.
public enum ClaudeSignal: Sendable, Equatable {
    /// A semantic Claude Code hook event (the richest signal).
    case hook(ClaudeHookEvent)
    /// Host foreground-process watch: is `claude` the PTY's foreground process? (primary,
    /// zero-config signal — wire type 26). Presence is the FLOOR; absence forces `.none`.
    case processPresent(Bool)
    /// The no-hooks fallback's coarse verdict (`ClaudeManifestMatcher`). A conservative
    /// `.none` is IGNORED (never downgrades a present process); `.working`/`.needsPermission`
    /// promote only while a more-authoritative hook block is not in effect.
    case manifestVerdict(ClaudeStatus)
    /// An OSC 2 title (`Claude: …`) — weak corroboration; promotes at most to `.idle`.
    case oscTitle(String)
    /// A clock tick — drives time-based decay (done→idle) via the injected `now`.
    case tick
    /// A SCREEN-RULE verdict from the manifest engine (the herdr port): the live grid + OSC
    /// title/progress evaluated against the agent's bundled rule ladder. Continuous ground
    /// truth — richer than ``manifestVerdict`` (it carries the `visible*` chrome flags), and
    /// the machine lets it clear even a HOOK-sourced block once the block is old enough to
    /// have painted (a VISIBLE idle prompt box / live spinner proves the dialog is gone).
    /// `skipStateUpdate` verdicts (transcript viewer / model picker) freeze the status.
    case screen(AgentScreenDetection)
    /// A CANCEL key (`Esc` / `Ctrl-C`) routed into the pane's PTY — the caller classifies via
    /// ``PaneInputClassifier/containsCancelKeystroke(_:)``, which excludes the emulator's automatic
    /// replies (focus reports, device answers, mouse motion) AND every non-cancel key. Narrowly
    /// scoped: it demotes ONLY a standing `.needsPermission`, because Esc-cancel fires no Stop hook
    /// and the ✳ rest title shows while the dialog is still up, making it the one unblock edge the
    /// host can see. Every OTHER way out of a dialog re-promotes itself through a hook, so widening
    /// this to any keystroke only manufactured false blocked→idle→blocked flaps (see the classifier).
    case userInput
}
