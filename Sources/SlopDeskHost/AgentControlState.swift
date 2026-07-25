import Foundation
import SlopDeskAgentDetect

/// The pure mapping between the host-side ``ClaudeStatus`` (state machine verdict) and the
/// stable wire string the agent-control NDJSON socket exposes (`idle` / `working` / `blocked`
/// / `done`). Kept tiny and dependency-free so it is unit-testable with no socket and no PTY.
///
/// ## Why a separate vocabulary
/// The ctl surface is a SUPERVISION API for an orchestrator agent ("which pane needs me?"),
/// so it uses the supervision word `blocked` (the Herdr/Warp term) for ``ClaudeStatus/needsPermission``
/// rather than leaking the host's internal enum case names. The set is closed (validate-then-drop:
/// the `report` verb rejects any string outside it).
///
/// ## `.none` mapping
/// A live pane whose detector has never sampled `claude` reports `.none` (no claude present).
/// For the ctl supervision view a live pane with no agent is simply "idle" — there is nothing
/// blocking and nothing running. We deliberately collapse `.none → "idle"` (rather than inventing
/// an `"unknown"` token) so the closed set the `report` verb validates against stays exactly the
/// four supervision states. Pinned by ``AgentControlStateTests``.
///
/// The collapse costs the stream one distinction, though: `.none` and `.idle` are the SAME string,
/// so a pane whose agent EXITED emits `"idle"` — byte-identical to the `"idle"` it was already
/// sitting at — and the subscriber's consecutive-duplicate dedupe swallows it. An orchestrator
/// watching `events` could therefore never see an agent leave. ``presence(from:)`` carries that one
/// bit alongside the state instead of widening the vocabulary.
public enum AgentControlState {
    /// The four supervision state strings, in increasing urgency. The closed set the `report`
    /// verb validates against (anything else is dropped).
    public static let allStates: [String] = ["idle", "working", "done", "blocked"]

    /// Maps a host ``ClaudeStatus`` to its ctl wire string.
    /// `none`/`idle → "idle"`, `working → "working"`, `done → "done"`, `needsPermission → "blocked"`.
    public static func string(from status: ClaudeStatus) -> String {
        switch status {
        case .none,
             .idle:
            "idle"
        case .working:
            "working"
        case .done:
            "done"
        case .needsPermission:
            "blocked"
        }
    }

    /// Whether an agent is PRESENT in the pane at all — the bit ``string(from:)`` collapses away.
    /// `false` only for ``ClaudeStatus/none``; every other status implies a detected agent.
    public static func presence(from status: ClaudeStatus) -> Bool {
        status != .none
    }

    /// Whether `s` is one of the four known supervision states. Used by the `report` verb to
    /// validate-then-drop an unknown state BEFORE touching any session.
    public static func isValid(_ s: String) -> Bool {
        allStates.contains(s)
    }
}
