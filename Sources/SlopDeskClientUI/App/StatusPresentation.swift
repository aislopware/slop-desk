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
    /// never recolours — this ink is worn by the row's trailing ring mark
    /// (``statusDot(working:badge:)``) and the collapsed-group roll-up count
    /// (``attentionRollupInk(_:)``), so every surface names one
    /// pane's state in the same hue. Everything holds STILL (MERIDIAN's hard-cut ethos: nothing
    /// in the rail animates).
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
        // Running and privilege never recolour the title: busy is the trailing ring's job
        // (``statusDot(working:badge:)``), and the privilege markers are slot text (``tabBadge(_:)``).
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

    /// The row's trailing STATUS MARK — the T3 Code SidebarV2 port: ONE shape (the static dashed
    /// ring, its `CircleDashedIcon`) and the HUE names the state, T3 Code's own status-hue
    /// convention. The ladder: a WORKING AGENT rings on the accent (keyed on the RAW `.working`
    /// status, so the badge gate can't kill it; the badge-routed `.running` tier reads
    /// identically); a RESTING CODE AGENT rings on the muted secondary ink (present, spending no
    /// hue); the attention states ring on their attention ink (``attentionInk(_:)`` — green unread
    /// finish, amber question, red failure), the mark's hue being that state's WHOLE rendering
    /// now that the title stays neutral. The one non-hue distinction: an unread FINISH CLOSES the
    /// ring (``closesTheRing(_:)``) — a broken circle for work still open, a whole one for work that
    /// ended. A plain running COMMAND rings NOTHING — the mark is the
    /// AGENT's column, and a muted ring on every `npm run dev` row spent it on the one thing the
    /// row's own running title already says. Bare shells and privilege-only rows mount nothing
    /// either — the resting rail stays bare.
    ///
    /// - Parameter agentIdle: whether a code agent is present in the pane and AT REST
    ///   (`ClaudeStatus.idle`) — the muted ring's ONLY source. The `claude` process holds the
    ///   shell's OSC-133 block open for its whole lifetime, so a resting agent's row arrives here
    ///   as a bare ``TabBadgeKind/commandBusy`` (or no badge at all): without this input it is
    ///   indistinguishable from a plain long-running command.
    static func statusDot(
        working: Bool, badge: TabBadgeKind?, agentIdle: Bool = false,
    ) -> StatusDotStyle? {
        if working { return StatusDotStyle(ink: Slate.State.accent) }
        // The resting-agent ring — the floor every non-attention branch below falls back to.
        let resting = agentIdle ? StatusDotStyle(ink: Slate.Text.secondary) : nil
        guard let badge else { return resting }
        switch badge {
        // The agent tier arriving through the badge route ("Badge while processing" ON) reads
        // identically to the raw-working route above.
        case .running: return StatusDotStyle(ink: Slate.State.accent)
        case .awaitingInput,
             .completed,
             .error,
             .finished:
            return attentionInk(badge).map {
                StatusDotStyle(ink: $0, closed: closesTheRing(badge))
            }
        // A busy shell says nothing of its own (the row's title already names the command) and the
        // privilege modifiers are slot text, not lifecycle — both fall through to whether a code
        // agent is resting in this pane.
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .sudo: return resting
        }
    }

    /// Whether a state draws the ring CLOSED rather than dashed — TRUE for the unread finish alone
    /// (both the fresh `.completed` flash and the settled `.finished` unread; that split is semantic,
    /// never visual). Everything else is still open in some way — working, resting, waiting on a
    /// human, failed — and keeps the broken ring, so the closed circle keeps meaning exactly one
    /// thing. ⚠️ This is the ONLY shape distinction in the column: a previous round spent a day
    /// giving each state its own silhouette (hand, triangle, `?`, `!`, filled dot) and pulled every
    /// one of them for reading as fussy detail at 8pt (docs/DECISIONS.md rounds 19–20). One
    /// closed-versus-broken bit survives that because it is legible at any size and needs no legend.
    static func closesTheRing(_ kind: TabBadgeKind) -> Bool {
        switch kind {
        case .completed,
             .finished: true
        case .awaitingInput,
             .caffeinate,
             .commandBusy,
             .commandRunning,
             .error,
             .running,
             .sudo: false
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
