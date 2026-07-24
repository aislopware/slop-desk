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

    /// Tint for an agent status — the SAME hue budget the tab badges speak (``tabBadge(_:)``), so
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

    /// How a fused ``TabBadgeKind`` renders — the TERMINAL-DIALECT vocabulary: every lifecycle state
    /// is a single mono character (``StatusGlyph``), exactly what a CLI would print for that state,
    /// so the badge column reads like terminal output rather than drawn iconography. The view layer
    /// (``TabBadgeView``) switches on this so the reading + tint have a single source, reused
    /// verbatim by every surface that mounts a badge (title-menu attention rows, iOS rows).
    ///
    /// The SIDEBAR rows never mount the busy tiers here — busy renders as the title's working
    /// shimmer (``WorkingShimmer``; `TabBadgeKind.isBusyTier` is the split) so the trailing slot
    /// keeps the shell label while a command runs. The spinners stay the vocabulary for any
    /// surface that does pass a busy kind.
    ///
    /// The hue budget: accent = agent in motion, amber = act-now, red = broken, green = unread-done;
    /// plain command motion and the privilege markers stay muted, and the resting row has no badge at
    /// all — its slot shows the shell label instead.
    static func tabBadge(_ kind: TabBadgeKind) -> TabBadgeStyle {
        switch kind {
        // The agent in motion — the AI-CLI asterisk pulse, in accent (the in-motion hue).
        case .running: .reading(.working, tint: Slate.State.accent)
        // Plain command motion — the braille dot-walker, muted (the shell's own spinner; a
        // command is not an agent, and its glyph says so before its hue does).
        case .commandRunning,
             .commandBusy: .reading(.busy, tint: Slate.Text.secondary)
        // The clean finish — fresh flash and settled unread alike print the quiet green `●`.
        // "Unread finish" needs a marker, not a trophy. The completed/finished split stays
        // semantic (freshness machinery, control-backend tokens).
        case .completed: .reading(.done, tint: Slate.Status.ok)
        case .finished: .reading(.done, tint: Slate.Status.ok)
        // Error — the red `✗` every CLI prints for a failure: static, waits on you.
        case .error: .reading(.error, tint: Slate.Status.err)
        // Awaiting input — the amber `?`, blinking on the cursor's cadence: act-now; red stays
        // reserved for broken.
        case .awaitingInput: .reading(.awaiting, tint: Slate.Status.warn)
        // Privilege markers — small muted text in the shell's own dialect (modifiers, not states,
        // so they stay outside the lifecycle vocabulary).
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

/// The rendering recipe for one tab badge (see ``StatusPresentation/tabBadge(_:)``) — the terminal
/// text dialect. A pure value (no view), so the badge map can be unit-tested without rendering.
enum TabBadgeStyle: Equatable {
    /// A ``StatusGlyph`` lifecycle reading — the character a CLI would print for that state.
    case reading(StatusGlyph.Reading, tint: Color)
    /// A small static text marker in the shell's dialect (`#` sudo, `∞` caffeinate).
    case glyph(text: String, tint: Color)
}
#endif
