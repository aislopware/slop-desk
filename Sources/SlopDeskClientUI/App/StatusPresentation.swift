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

    /// Tint for an agent status — the SAME hue budget the tab-badge rings speak (``tabBadge(_:)``), so
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

    /// How a sidebar tab's fused ``TabBadgeKind`` renders — the ONE-SHAPE fill-fraction vocabulary
    /// (``StatusRing``): every lifecycle state is the same Ø12 circle varying only how much of it is
    /// drawn/filled (dashed → hollow → pie → armed → solid), so a state edge reads as one instrument
    /// changing its reading rather than an icon swap. The view layer (``TabBadgeView``) switches on
    /// this so the reading + tint have a single source, reused verbatim by every surface that mounts a
    /// badge (sidebar glyph column, title-menu attention rows, iOS rows) — one frozen vocabulary,
    /// never re-derived per surface.
    ///
    /// The hue budget: colour is spent ONLY on act-now (amber), in-motion (accent), broken (red) and
    /// unread-done (green); the command tiers and privilege markers stay muted, and the resting row has
    /// no badge at all.
    ///
    /// `progressFraction` is the pane's live OSC 9;4 determinate 0…1 (from
    /// ``progressPresentation(_:)``); only the `.commandRunning` tier consumes it.
    static func tabBadge(_ kind: TabBadgeKind, progressFraction: Double? = nil) -> TabBadgeStyle {
        switch kind {
        // Agent WORKING — the dashed `◌`, flickering on the stepped duty cycle, in the ACCENT hue.
        case .running: .ringWorking(tint: Slate.State.accent)
        // An OSC 9;4 progress load — the muted ring with the REAL fraction swept as a pie wedge (an
        // instrumented command earns geometry, not the agent's hue); indeterminate = the bare ring.
        case .commandRunning: .ringPie(fraction: progressFraction, tint: Slate.Text.secondary)
        // A plain busy shell — the hollow muted ring `○`: alive, nothing more to say.
        case .commandBusy: .ringHollow(tint: Slate.Text.secondary)
        // Completed flash + the unread finish — one reading: the solid green disc + knocked-out check,
        // held until seen. Terminal states earn the only full fill.
        case .completed: .ringDone(tint: Slate.Status.ok)
        case .finished: .ringDone(tint: Slate.Status.ok)
        // Error — the solid red disc + knocked-out cross: broken, waits on you, nothing moves.
        case .error: .ringError(tint: Slate.Status.err)
        // Awaiting input — the amber (act-now) ring + centre dot `◉`: armed, waiting. Static — amber
        // is the "answer me" hue; red stays reserved for something actually broken.
        case .awaitingInput: .ringAwaiting(tint: Slate.Status.warn)
        case .caffeinate: .ringGlyph(name: "cup.and.saucer.fill", tint: Slate.Text.secondary)
        case .sudo: .ringGlyph(name: "shield.lefthalf.filled", tint: Slate.Text.secondary)
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

    // MARK: Progress (OSC 9;4 taskbar-style readout)

    /// The taskbar-style percent readout for a pane's OSC 9;4 progress, or `nil` when there is no number to
    /// show. Only a DETERMINATE state (`9;4;1;<pct>`) carries a meaningful "taskbar" percent — an
    /// indeterminate spinner shows the spinner only, and an error is conveyed by its alert glyph (held red),
    /// not a number. Renders the determinate "NN%" readout (`progress-state.md` Behaviors). Pure text.
    static func progressPercentLabel(_ progress: PaneProgress?) -> String? {
        if case let .determinate(percent) = progress { return "\(percent)%" }
        return nil
    }

    /// How a pane's OSC 9;4 progress renders in the status presentation — a pure value (no view) so
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

/// The rendering recipe for one tab badge (see ``StatusPresentation/tabBadge(_:progressFraction:)``) —
/// the readings map 1:1 onto ``StatusRing/Reading``: one circle, state encoded by fill fraction. A
/// pure value (no view), so the badge map can be unit-tested without rendering.
enum TabBadgeStyle {
    /// A WORKING agent — the dashed `◌`, whole-glyph stepped flicker (the only motion in the system).
    case ringWorking(tint: Color)
    /// A blocked agent / interactive prompt — the ring + filled centre dot `◉`. Static: armed.
    case ringAwaiting(tint: Color)
    /// Done (flash + unread) — the solid disc + knocked-out check, held until the tab is viewed.
    case ringDone(tint: Color)
    /// A failed command / held progress error — the solid disc + knocked-out cross. Static.
    case ringError(tint: Color)
    /// A plain busy shell — the hollow ring `○` (running, uninstrumented).
    case ringHollow(tint: Color)
    /// An OSC 9;4 progress load — the ring + centre pie wedge swept to the real 0…1 fraction
    /// (`nil` = indeterminate: the bare ring).
    case ringPie(fraction: Double?, tint: Color)
    /// An at-rest privilege marker (caffeinate / sudo) — a small SF-symbol inside the muted ring.
    case ringGlyph(name: String, tint: Color)
}
#endif
