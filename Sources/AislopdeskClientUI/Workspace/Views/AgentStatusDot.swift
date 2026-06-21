#if canImport(SwiftUI)
import AislopdeskAgentDetect
import SwiftUI

// MARK: - AgentStatusDot (the Claude/agent status indicator — W5)

/// A small colored indicator for a pane / tab / session's rolled-up ``ClaudeStatus`` (docs/41 §4.3,
/// docs/42 W5). The colour maps to the premium SEMANTIC status palette (P2 polish):
/// `working → statusBlue` (actively working a turn — the in-flight signal, with a subtle breathe),
/// `done → statusGreen` (finished, waiting to be seen), `needsPermission → statusRed` (blocked on a
/// human — the most urgent), `idle → fgDim` (at rest — recedes), `none → hidden`.
///
/// `.none` renders an EMPTY view (zero size) so a plain terminal pane with no agent shows no dot at all —
/// the sidebar/tab/chrome stays clean until a `claude` is actually detected. Pure presentation; the W10/W11
/// detection pipeline feeds the status in via the store.
struct AgentStatusDot: View {
    /// The rolled-up status to render. `.none` ⇒ nothing.
    let status: ClaudeStatus
    /// The dot diameter as an UNSCALED base point size (the sidebar uses a slightly larger dot than the pane
    /// chrome). P5: the diameter is applied via the tracked `.dsScaledFrame(square:)` so the dot reflows LIVE
    /// on a density-tier flip — callers pass the BASE (e.g. `8`), NOT a pre-scaled `UIMetrics.scaled(8)`.
    var size: CGFloat = 7

    var body: some View {
        if let color = Self.color(for: status) {
            base(color)
                // WORKING breathes via a single repeating .easeInOut opacity fade (a leaf-dot-local
                // repeatForever, NO symbolEffect, never on the keystroke / terminal-render path) so the
                // in-flight cue is alive but calm. Every other state is steady.
                .modifier(WorkingPulse(active: status == .working))
                // P5: tracked scaled frame (base `size` × the live density multiplier) so the dot reflows on a
                // tier flip in lockstep with the surrounding `.dsFont` text instead of freezing.
                .dsScaledFrame(square: size)
                .help(Self.label(for: status))
                .accessibilityLabel(Text("agent \(Self.label(for: status))"))
        } else {
            // `.none`: render nothing (zero size) so a no-agent row carries no dot.
            EmptyView()
        }
    }

    private func base(_ color: Color) -> some View {
        Circle()
            .fill(color)
            // A subtle ring so the dot reads on both light and dark sidebars.
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }

    /// The dot colour for `status`, or `nil` for ``ClaudeStatus/none`` (hidden). Maps to the semantic
    /// status palette: working=blue (in-flight), done=green (finished), needsPermission=red (blocked),
    /// idle=dim (at rest, recedes).
    static func color(for status: ClaudeStatus) -> Color? {
        switch status {
        case .none: nil
        case .idle: AislopdeskTheme.fgDim
        case .working: AislopdeskTheme.statusBlue
        case .done: AislopdeskTheme.statusGreen
        case .needsPermission: AislopdeskTheme.statusRed
        }
    }

    /// A short human label for the tooltip / accessibility.
    static func label(for status: ClaudeStatus) -> String {
        switch status {
        case .none: "none"
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .needsPermission: "needs permission"
        }
    }
}

// MARK: - WorkingPulse (a gentle breathe for the WORKING dot only)

/// Wraps the WORKING dot in a calm opacity breathe — a single repeating opacity fade between `~0.65` and
/// `1.0` on the ``DSMotion/attention`` token (the house repeatForever curve, shared with the sibling
/// ``AttentionPulse``), toggled by a local `@State` driven on `.onAppear`. This is the ONE place a
/// `repeatForever` animation is acceptable on the chrome: it is a leaf indicator (a 7pt dot), NOT on the
/// keystroke / echo latency path and not over the terminal/IOSurface, so the SwiftUI-interpolated fade is
/// both correct (no strobe) and cheap. We deliberately do NOT use a `TimelineView` sampled at a coarse
/// interval — that interpolates nothing between samples and renders a hard two-state flip, the opposite of
/// the intended breathe. When `active` is false — OR Reduce Motion is on — the receiver rests steady (the
/// reduced-motion fallback for a continuously-repeating animation).
private struct WorkingPulse: ViewModifier {
    let active: Bool

    /// Floor / ceiling of the breathe — a calm fade that never fully dims (the dot stays legible).
    private static let floor = 0.65

    @State private var breathing = false
    /// Reduce-Motion gate: under the system preference the repeatForever breathe is DROPPED — the dot rests
    /// steady at full opacity (legible, never pulsing), mirroring the sibling ``AttentionPulse`` fix per the
    /// spec's "EVERY spring/translate gated → near-instant" rule (a `repeatForever` can't be made near-instant;
    /// resting steady is the right fallback).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content
                .opacity(breathing ? 1.0 : Self.floor)
                // P5 MOTION: the working-dot breathe is DSMotion.attention (the house repeatForever token).
                // Under Reduce Motion the `!reduceMotion` guard above takes the steady branch (full-opacity,
                // no pulse) — the spec's reduced-motion fallback for a continuously-repeating animation.
                .animation(DSMotion.attention, value: breathing)
                .onAppear { breathing = true }
        } else {
            // Steady: either no agent is working, or Reduce Motion is on (the dot shows at full opacity but
            // does not pulse).
            content
        }
    }
}
#endif
