// StatusPresentation — pure view-side mapping of connection + agent state to native SwiftUI presentation.
// Shared by the connection cluster (`ConnectionCluster`, both platforms) and the Peek & Reply header so
// the copy + retry policy can't drift. The label copy itself comes from `ConnectionPresenter` (the one
// source of truth) — this adds only the view-layer help text, retry gating, and agent glyph/tint.

#if canImport(SwiftUI)
import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import SwiftUI

// `@MainActor` because the colour mappers read the runtime ``Slate/theme`` (D3) — every call site is a
// SwiftUI view body, all MainActor.
@MainActor
enum StatusPresentation {
    // MARK: Connection

    /// The compact pill label (e.g. "connected", "reconnecting 3/20", "failed").
    static func connectionLabel(_ status: ConnectionStatus) -> String {
        ConnectionPresenter.shortLabel(for: status)
    }

    /// Whether a manual Retry affordance applies (only the give-up states).
    static func showsRetry(_ status: ConnectionStatus) -> Bool {
        switch status {
        case .failed,
             .unreachable: true
        default: false
        }
    }

    /// The hover/accessibility help: host + the actionable headline.
    static func connectionHelp(host: String, status: ConnectionStatus) -> String {
        "Connection: \(host) — \(ConnectionPresenter.headline(for: status))"
    }

    // MARK: Agent (Claude Code)

    /// The ``StatusGlyph`` reading for an agent status. `nil` ⇒ render nothing (no active agent).
    /// The agent surfaces (iOS toolbar glyph, Peek & Reply header) speak the SAME terminal dialect as
    /// the tab badges — a state edge is one character trading for another in the same mono slot.
    static func agentReading(_ status: ClaudeStatus) -> StatusGlyph.Reading? {
        switch status {
        case .none: nil
        case .idle: .resting
        case .working: .working
        case .done: .done
        case .needsPermission: .awaiting
        }
    }

    /// Tint for an agent status — the SAME hue budget the tab rows speak (``attentionInk(_:)``), so
    /// the iOS toolbar glyph / Peek & Reply header can never disagree with the sidebar about one pane:
    /// working = accent (in-motion), needs-permission = amber (act-now; red is reserved for broken),
    /// done = green (unread finish), idle/none = muted (the resting state spends no colour).
    static func agentTint(_ status: ClaudeStatus) -> Color {
        switch status {
        case .none,
             .idle: Slate.Text.secondary
        case .working: Slate.State.accent
        case .done: Slate.Status.ok
        case .needsPermission: Slate.Status.warn
        }
    }

    /// The short agent label (the one source — `ClaudeStatus.displayLabel`).
    static func agentLabel(_ status: ClaudeStatus) -> String {
        status.displayLabel
    }

    // MARK: Tab badge

    /// A `needsAttention` state's HUE on the hue budget: amber = act-now (a question waits), red
    /// = broken, green = unread-done. `nil` for every non-attention kind. The sidebar row's TITLE
    /// never recolours — this ink is worn by the row's trailing mark
    /// (``statusDot(working:badge:agentIdle:)``, where the SHAPE names the state and this hue rides
    /// along) and the collapsed-group roll-up count (``attentionRollupInk(_:)``), so every surface
    /// names one pane's state in the same hue. Every attention mark holds STILL: motion in the rail
    /// is reserved for the two IN-FLIGHT marks (the working pulse, a command's slot spinner) —
    /// nothing blinks to say "unread".
    static func attentionInk(_ kind: TabBadgeKind) -> Color? {
        switch kind {
        // Awaiting input — act-now amber; red stays reserved for broken.
        case .awaitingInput: Slate.Status.warn
        // Error — the red every terminal already means by red text.
        case .error: Slate.Status.err
        // The clean finish — fresh flash and settled unread alike hold the green until the pane is
        // visited. The completed/finished split stays semantic (freshness machinery, control-backend
        // badge tokens).
        case .completed,
             .finished: Slate.Status.ok
        // Running and privilege never recolour the title: activity is the mark column's / the slot
        // spinner's job, and the privilege markers are slot text (``tabBadge(_:)``).
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: nil
        }
    }

    /// The COLLAPSED group's roll-up ink: the strongest attention ink among the hidden rows' fused
    /// badges, in the resolver's own urgency order — a waiting question outranks an error outranks
    /// an unread finish — so the header count wears exactly the ink the loudest hidden row would.
    /// `nil` when nothing inside waits (the count keeps the muted metadata ink). Folding a group
    /// shut therefore never hides an agent that needs the eye.
    static func attentionRollupInk(_ badges: [TabBadgeKind?]) -> Color? {
        let present = Set(badges.compactMap(\.self))
        for kind in [TabBadgeKind.awaitingInput, .error, .completed, .finished]
            where present.contains(kind)
        {
            return attentionInk(kind)
        }
        return nil
    }

    /// The row's trailing STATUS MARK. Round 19 (otty parity) makes the SHAPE the grammar and lets
    /// the hue ride along: a WORKING AGENT breathes the accent PULSE (keyed on the RAW `.working`
    /// status, so the badge gate can't kill it; the badge-routed `.running` tier reads identically);
    /// a RESTING CODE AGENT keeps the original static dashed RING on the muted secondary ink
    /// (present, spending no hue); the attention states wear otty's own pictograms on their
    /// attention ink (``attentionInk(_:)`` — the raised HAND for a question, the filled green DOT
    /// for an unread finish, the red TRIANGLE for a failure). A plain running COMMAND mounts
    /// NOTHING here — this column is the AGENT's, and a busy command's motion is the
    /// ``CommandSpinner`` that takes the process-label slot instead
    /// (``RailRowsBuilder/showsCommandSpinner(badge:isAgent:processLabel:)``), so no row ever
    /// carries two activity marks. Bare shells and privilege-only rows mount nothing either — the
    /// resting rail stays bare.
    ///
    /// - Parameter agentIdle: whether a code agent is present in the pane and AT REST
    ///   (`ClaudeStatus.idle`) — the muted ring's ONLY source. The `claude` process holds the
    ///   shell's OSC-133 block open for its whole lifetime, so a resting agent's row arrives here
    ///   as a bare ``TabBadgeKind/commandBusy`` (or no badge at all): without this input it is
    ///   indistinguishable from a plain long-running command.
    static func statusDot(
        working: Bool, badge: TabBadgeKind?, agentIdle: Bool = false,
    ) -> StatusDotStyle? {
        if working { return StatusDotStyle(shape: .pulse, ink: Slate.State.accent) }
        // The resting-agent ring — the floor every non-attention branch below falls back to.
        let resting = agentIdle ? StatusDotStyle(shape: .ring, ink: Slate.Text.secondary) : nil
        guard let badge else { return resting }
        switch badge {
        // The agent tier arriving through the badge route ("Badge while processing" ON) reads
        // identically to the raw-working route above.
        case .running: return StatusDotStyle(shape: .pulse, ink: Slate.State.accent)
        case .awaitingInput,
             .completed,
             .error,
             .finished:
            return attentionInk(badge).map { StatusDotStyle(shape: attentionShape(badge), ink: $0) }
        // A busy shell says nothing of its own (the row's title already names the command) and the
        // privilege modifiers are slot text, not lifecycle — both fall through to whether a code
        // agent is resting in this pane.
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .sudo: return resting
        }
    }

    /// The PICTOGRAM an attention state wears in the mark column — otty's own vocabulary, so the
    /// shape is readable before the hue is (and stays readable to a colour-blind eye): the raised
    /// HAND for a question waiting on you, the filled DOT for an unread finish (fresh flash and
    /// settled alike — the split is semantic, never visual), the warning TRIANGLE for a failure.
    /// Non-attention kinds have no pictogram of their own; the resting ring / working pulse are the
    /// resolver's own branches, so this map is only ever reached for the four attention kinds.
    static func attentionShape(_ kind: TabBadgeKind) -> StatusMarkShape {
        switch kind {
        case .awaitingInput: .hand
        case .error: .alert
        case .completed,
             .finished: .dot
        // Unreachable through ``statusDot(working:badge:agentIdle:)`` (the busy tiers mount no mark
        // and the privilege markers are slot text) — the resting ring is the honest default.
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: .ring
        }
    }

    /// The trailing-slot marker for a ``TabBadgeKind`` — ONLY the privilege modifiers (`#` sudo,
    /// `∞` caffeinate), small muted text in the shell's own dialect. Every lifecycle state returns
    /// `nil`: every lifecycle state lives in the trailing ring mark's hue
    /// (``statusDot(working:badge:)``), so the slot keeps the shell label.
    static func tabBadge(_ kind: TabBadgeKind) -> TabBadgeStyle? {
        switch kind {
        case .caffeinate: TabBadgeStyle(text: "∞", tint: Slate.Text.secondary)
        case .sudo: TabBadgeStyle(text: "#", tint: Slate.Text.secondary)
        case .awaitingInput,
             .commandBusy,
             .commandRunning,
             .completed,
             .error,
             .finished,
             .running: nil
        }
    }

    /// The accessibility / tooltip label for a tab badge, so the otherwise icon-only glyph is VoiceOver-
    /// legible and testable. Pure text — mirrors the `progress-state.md` badge vocabulary.
    static func tabBadgeLabel(_ kind: TabBadgeKind) -> String {
        switch kind {
        case .running: "Agent working"
        case .commandRunning: "Loading"
        case .commandBusy: "Running"
        case .completed: "Completed"
        case .finished: "Finished"
        case .error: "Error"
        case .awaitingInput: "Awaiting input"
        case .caffeinate: "Caffeinated"
        case .sudo: "Privileged"
        }
    }
}

/// The trailing-slot marker for one tab badge (see ``StatusPresentation/tabBadge(_:)``) — a small
/// static text glyph in the shell's dialect (`#` sudo, `∞` caffeinate). A pure value (no view), so
/// the badge map can be unit-tested without rendering.
struct TabBadgeStyle: Equatable {
    let text: String
    let tint: Color
}
#endif
