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

    /// The row's ATTENTION INK — how a `needsAttention` state colours the row's own TITLE text, on
    /// the hue budget: amber = act-now (a question waits), red = broken, green = unread-done. `nil`
    /// for every non-attention kind (the title keeps the resting ink ladder).
    ///
    /// This is the INK DIALECT: a sidebar row never mounts a lifecycle glyph. The states that need
    /// the eye recolour the text that is already there — the same move the working shimmer makes for
    /// motion — so the rail stays a column of plain terminal text and status can never disagree with
    /// its own indicator. Every attention ink holds STILL (MERIDIAN's hard-cut ethos: animation is
    /// reserved for sustained live signals — the shimmer; a waiting state is not motion).
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
        // Motion and privilege never recolour the title: busy is the shimmer's job, and the
        // privilege markers are slot text (``tabBadge(_:)``).
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

    /// The row's trailing STATUS MARK — the T3 Code SidebarV2 port: the ink names the state, the
    /// SHAPE carries the grammar (dashed RING = in flight, its `CircleDashedIcon`; solid RING =
    /// the run finished, unread — the loop closed; filled DOT = a question/failure waiting on a
    /// human), and nothing animates — running MOTION is the title shimmer's job alone. The
    /// ladder, strongest first: a WORKING AGENT dash-rings on the accent (keyed on the RAW
    /// `.working` status, same key as the shimmer — the gated badge must not kill it); the
    /// attention states wear their TITLE ink exactly (the mark and the title can never disagree
    /// about one pane) — the unread finish as the green solid ring, amber question / red failure
    /// as the filled dot; a running COMMAND dash-rings on the muted secondary ink (in flight
    /// without hue — colour stays reserved for states that need a human); everything else mounts
    /// nothing (an idle row spends no mark — T3 Code renders null, and the resting rail stays
    /// bare).
    static func statusDot(working: Bool, badge: TabBadgeKind?) -> StatusDotStyle? {
        if working { return StatusDotStyle(ink: Slate.State.accent, shape: .dashedRing) }
        guard let badge else { return nil }
        if let ink = attentionInk(badge) {
            let finished = badge == .completed || badge == .finished
            return StatusDotStyle(ink: ink, shape: finished ? .solidRing : .fill)
        }
        switch badge {
        // The agent tier arriving through the badge route ("Badge while processing" ON) reads
        // identically to the raw-working route above.
        case .running: return StatusDotStyle(ink: Slate.State.accent, shape: .dashedRing)
        case .commandBusy,
             .commandRunning: return StatusDotStyle(ink: Slate.Text.secondary, shape: .dashedRing)
        // Attention kinds already returned above; privilege modifiers are slot text, not lifecycle.
        case .awaitingInput,
             .caffeinate,
             .completed,
             .error,
             .finished,
             .sudo: return nil
        }
    }

    /// The trailing-slot marker for a ``TabBadgeKind`` — ONLY the privilege modifiers (`#` sudo,
    /// `∞` caffeinate), small muted text in the shell's own dialect. Every lifecycle state returns
    /// `nil`: motion lives in the title's shimmer, attention lives in the title's ink
    /// (``attentionInk(_:)``), so the slot keeps the shell label / elapsed readout.
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
