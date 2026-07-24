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

    /// The ``StatusRing`` reading for an agent status. `nil` ⇒ render nothing (no active agent).
    /// The agent surfaces (iOS toolbar glyph, Peek & Reply header) speak the SAME one-shape circle as
    /// the tab badges — a state edge is the one gauge changing its reading, never an icon swap.
    static func agentReading(_ status: ClaudeStatus) -> StatusRing.Reading? {
        switch status {
        case .none: nil
        case .idle: .resting
        case .working: .working
        case .done: .done
        case .needsPermission: .awaiting
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

    /// How a fused ``TabBadgeKind`` renders — the ONE-SHAPE vocabulary: every lifecycle state is a
    /// reading of the SAME Ø12 circle (``StatusRing``), so the user separates states by HUE and fill,
    /// never by learning a different silhouette per state. The view layer (``TabBadgeView``) switches
    /// on this so the reading + tint have a single source, reused verbatim by every surface that
    /// mounts a badge (title-menu attention rows, iOS rows).
    ///
    /// The SIDEBAR rows never mount the busy tiers here — busy renders as the title's working
    /// shimmer (``WorkingShimmer``; `TabBadgeKind.isBusyTier` is the split) so the trailing slot
    /// keeps the shell label while a command runs. The sweeping comet stays the vocabulary for any
    /// surface that does pass a busy kind.
    ///
    /// The hue budget: accent = agent in motion, amber = act-now, red = broken, green = unread-done;
    /// plain command motion and the privilege markers stay muted, and the resting row has no badge at
    /// all — its slot shows the shell label instead.
    static func tabBadge(_ kind: TabBadgeKind) -> TabBadgeStyle {
        switch kind {
        // The agent in motion — the sweeping comet in accent (the in-motion hue).
        case .running: .ring(.working, tint: Slate.State.accent)
        // Plain command motion — the same comet, muted (a shell command is not an agent).
        case .commandRunning,
             .commandBusy: .ring(.working, tint: Slate.Text.secondary)
        // The clean finish — fresh flash and settled unread alike render the quiet green filled
        // circle: the ring at FULL fill. "Unread finish" needs a marker, not a trophy. The
        // completed/finished split stays semantic (freshness machinery, control-backend tokens).
        case .completed: .ring(.done, tint: Slate.Status.ok)
        case .finished: .ring(.done, tint: Slate.Status.ok)
        // Error — the broken red ring: the circle itself snapped, waits on you, nothing moves.
        case .error: .ring(.error, tint: Slate.Status.err)
        // Awaiting input — the amber ring with the blinking cursor dot: act-now; red stays
        // reserved for broken.
        case .awaitingInput: .ring(.awaiting, tint: Slate.Status.warn)
        // Privilege markers — small muted text in the shell's own dialect (modifiers, not states,
        // so they stay outside the circle vocabulary).
        case .caffeinate: .glyph(text: "∞", tint: Slate.Text.secondary)
        case .sudo: .glyph(text: "#", tint: Slate.Text.secondary)
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

/// The rendering recipe for one tab badge (see ``StatusPresentation/tabBadge(_:)``) — the one-shape
/// circle vocabulary. A pure value (no view), so the badge map can be unit-tested without rendering.
enum TabBadgeStyle: Equatable {
    /// A ``StatusRing`` reading — every lifecycle state is the same circle, differing by hue + fill.
    case ring(StatusRing.Reading, tint: Color)
    /// A small text marker in the shell's dialect (`#` sudo, `∞` caffeinate).
    case glyph(text: String, tint: Color)
}
#endif
