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

    /// SF Symbol for an agent status. `nil` ⇒ render nothing (no active agent).
    static func agentSymbol(_ status: ClaudeStatus) -> String? {
        switch status {
        case .none: nil
        case .idle: "circle.fill"
        case .working: "gearshape.fill"
        case .done: "checkmark.circle.fill"
        case .needsPermission: "exclamationmark.triangle.fill"
        }
    }

    /// Tint for an agent status (docs/42 glyph palette: idle🟢 working🟡 done🔵 needs🔴).
    static func agentTint(_ status: ClaudeStatus) -> Color {
        switch status {
        case .none: Slate.Text.secondary
        case .idle: Slate.Status.ok
        case .working: Slate.Status.warn
        case .done: Slate.Status.info
        case .needsPermission: Slate.Status.err
        }
    }

    /// The short agent label (the one source — `ClaudeStatus.displayLabel`).
    static func agentLabel(_ status: ClaudeStatus) -> String {
        status.displayLabel
    }

    // MARK: Tab badge (E6 sidebar row, WI-4)

    /// How a sidebar tab's fused ``TabBadgeKind`` renders — the glyph map, kept next to ``agentSymbol``
    /// so the two status vocabularies can't drift (`terminal-features__progress-state.md` "The full badge
    /// set"). `.spinner` (running) and `.dot` (the settled accent dot) are bespoke shapes; every other kind
    /// is a tinted SF-symbol fill. The view layer (``TabBadgeView``) switches on this so the symbol + tint
    /// have a single source.
    static func tabBadge(_ kind: TabBadgeKind) -> TabBadgeStyle {
        switch kind {
        // ONE dot language on the agent palette (docs/42: working🟡 done🔵 needs🔴 idle🟢) — the COLOUR
        // carries the state, a spinner ring means "live right now", and no badge is ever a character glyph
        // (the old checkmark/triangle/hand SF-symbols read as foreign next to the dots). Only the at-rest
        // privilege markers stay symbols (a shield/cup IS their meaning).
        //
        // Agent WORKING — amber dot + spinner ring (live).
        case .running: .working(tint: Slate.Status.warn)
        // An OSC 9;4 progress load — the muted dot + spinner ring (live, but not the agent).
        case .commandRunning: .commandBusy(tint: Slate.Text.secondary)
        // A plain busy shell — the bare static muted dot, NO ring (the ring is earned by an explicit
        // progress report / a working agent).
        case .commandBusy: .dot(Slate.Text.secondary)
        // Completed — the brief green flash of a clean finish (settles to the blue unread dot).
        case .completed: .dot(Slate.Status.ok)
        // Finished — the persistent BLUE "unread output" dot (done, not yet seen).
        case .finished: .dot(Slate.Status.info)
        // Error / blocked — the RED dot, static: it waits on YOU, nothing is spinning.
        case .error: .dot(Slate.Status.err)
        case .awaitingInput: .dot(Slate.Status.err)
        case .caffeinate: .symbol(name: "cup.and.saucer.fill", tint: Slate.Text.secondary)
        case .sudo: .symbol(name: "shield.lefthalf.filled", tint: Slate.Text.secondary)
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

    // MARK: Progress (E14/K1 — OSC 9;4 taskbar-style readout)

    /// The taskbar-style percent readout for a pane's OSC 9;4 progress, or `nil` when there is no number to
    /// show. Only a DETERMINATE state (`9;4;1;<pct>`) carries a meaningful "taskbar" percent — an
    /// indeterminate spinner shows the spinner only, and an error is conveyed by its alert glyph (held red),
    /// not a number. Renders the determinate "NN%" readout (`progress-state.md` Behaviors). Pure text.
    static func progressPercentLabel(_ progress: PaneProgress?) -> String? {
        if case let .determinate(percent) = progress { return "\(percent)%" }
        return nil
    }

    /// How a pane's OSC 9;4 progress renders in the status presentation (E14/K1) — a pure value (no view) so
    /// the status strip's progress affordance and the Dock have one source. A determinate state carries its
    /// 0…1 bar fraction PLUS the "NN%" readout; an indeterminate state is the bare spinner; an error holds
    /// red; `nil` = nothing. The 0…1 fraction is plain view geometry (a single `/`, no fused multiply).
    static func progressPresentation(_ progress: PaneProgress?) -> ProgressPresentation {
        switch progress {
        case .none: .none
        case .indeterminate: .spinner
        case let .determinate(percent):
            .determinate(fraction: Double(Swift.min(percent, 100)) / 100.0, label: "\(percent)%")
        case .error: .error
        }
    }
}

/// The rendering recipe for a pane's OSC 9;4 progress (see ``StatusPresentation/progressPresentation(_:)``).
/// A pure value (no view) so the determinate / indeterminate / error mapping is unit-testable without
/// rendering. `.spinner` is a bespoke indeterminate animation; `.determinate` carries the 0…1 fraction the
/// taskbar-style bar fills to plus its "NN%" label; `.error` holds red; `.none` draws nothing.
enum ProgressPresentation: Equatable {
    case none
    case spinner
    case determinate(fraction: Double, label: String)
    case error
}

/// The rendering recipe for one tab badge (see ``StatusPresentation/tabBadge(_:)``). `.spinner` and `.dot`
/// are bespoke shapes the view draws directly; `.symbol` is an SF-symbol name + its tint. A pure value (no
/// view), so the badge map can be unit-tested without rendering.
enum TabBadgeStyle {
    /// The AGENT-working indicator — the amber dot with a spinner ring (``SlateOrbitDot``): live, the
    /// agent palette's 🟡. A pure SwiftUI animation, never a video/capture session (hang-safety rule #6).
    case working(tint: Color)
    /// An OSC 9;4 progress load — the muted dot with a spinner ring (``SlateOrbitDot``). Distinct from
    /// ``working`` by TINT (secondary, never a status colour) so the sidebar reads "a program reports
    /// progress" apart from "the agent is thinking".
    case commandBusy(tint: Color)
    /// A small STATIC filled dot — the whole settled vocabulary: red = waits on you (blocked / failed),
    /// blue = done unread, green = the brief clean-finish flash. No spinner: nothing is running.
    case dot(Color)
    /// A tinted SF-symbol fill (the at-rest privilege markers: caffeinate / sudo).
    case symbol(name: String, tint: Color)
}
#endif
