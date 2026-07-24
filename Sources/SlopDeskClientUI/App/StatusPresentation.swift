// StatusPresentation — pure view-side mapping of connection + agent state to native SwiftUI presentation.
// Shared by the connection cluster (`ConnectionCluster`, both platforms) and the Peek & Reply header so
// the copy + retry policy can't drift. The label copy itself comes from `ConnectionPresenter` (the one
// source of truth) — this adds only the view-layer help text, retry gating, and agent glyph/tint.

#if canImport(SwiftUI)
import SFSafeSymbols
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

    /// How a fused ``TabBadgeKind`` renders as a GLYPH — the otty badge vocabulary
    /// (`docs/otty-clone/screenshots/tab-badge.png`): ONE muted spinner for every busy tier (otty
    /// does not colour-grade motion), then a distinct static icon per terminal state. The view layer
    /// (``TabBadgeView``) switches on this so the reading + tint have a single source, reused
    /// verbatim by every surface that mounts a badge (title-menu attention rows, iOS rows).
    ///
    /// The SIDEBAR rows never mount the busy tiers here — busy renders as the title's working
    /// shimmer (``WorkingShimmer``; `TabBadgeKind.isBusyTier` is the split) so the trailing slot
    /// keeps the shell label while a command runs. The spinner mapping stays the vocabulary for any
    /// surface that does pass a busy kind.
    ///
    /// The hue budget: colour is spent ONLY on act-now (orange hand), broken (red triangle) and
    /// unread-done (the small green dot); motion and the privilege markers stay muted, and the resting
    /// row has no badge at all — its slot shows the shell label instead.
    static func tabBadge(_ kind: TabBadgeKind) -> TabBadgeStyle {
        switch kind {
        // Every busy tier — the muted rays spinner (the otty gray spinner, one reading for motion).
        case .running,
             .commandRunning,
             .commandBusy: .spinner(tint: Slate.Text.secondary)
        // The clean finish — fresh flash and settled unread alike render otty's small green dot.
        // ONE quiet reading: the filled SF check-circle sat visually heavier than every other badge
        // in the row's muted vocabulary, and "unread finish" needs a marker, not a trophy. The
        // completed/finished split stays semantic (freshness machinery, control-backend tokens).
        case .completed: .dot(tint: Slate.Status.ok)
        case .finished: .dot(tint: Slate.Status.ok)
        // Error — the red warning triangle: broken, waits on you, nothing moves.
        case .error: .symbol(symbol: .exclamationmarkTriangleFill, tint: Slate.Status.err)
        // Awaiting input — the orange raised hand: act-now; red stays reserved for broken.
        case .awaitingInput: .symbol(symbol: .handRaisedFill, tint: Slate.Status.warn)
        // Privilege markers — small muted text in the shell's own dialect.
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

/// The rendering recipe for one tab badge (see ``StatusPresentation/tabBadge(_:)``) — the otty badge
/// set. A pure value (no view), so the badge map can be unit-tested without rendering.
enum TabBadgeStyle {
    /// Anything busy — the muted rays spinner (otty's one reading for motion).
    case spinner(tint: Color)
    /// A static SF-symbol state (hand / triangle / check).
    case symbol(symbol: SFSymbol, tint: Color)
    /// The unseen-finish dot — a small filled circle.
    case dot(tint: Color)
    /// A small text marker in the shell's dialect (`#` sudo, `∞` caffeinate).
    case glyph(text: String, tint: Color)
}
#endif
