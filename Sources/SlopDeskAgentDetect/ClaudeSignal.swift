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
}
