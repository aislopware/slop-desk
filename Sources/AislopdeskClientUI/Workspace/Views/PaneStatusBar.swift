// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneStatusBar (the bottom status strip — Muxy ProjectStatusBar)

/// The DS-density bottom status bar (Muxy `ProjectStatusBar`, default `DSSpace.statusBarHeight` = 26pt):
/// since the Muxy redesign removed the per-pane header, the FOCUSED pane's connection dot / title / RTT /
/// agent status live here instead — one quiet strip at the bottom of the detail rather than a header bar on
/// every pane. P3b: the bar is `DSColor.chrome` (L3, n3 — a step above the `paneBg` content it summarises)
/// with a 1px `borderComponent` (white·0.11) hairline along its TOP edge; the LEFT identity cluster carries
/// a semibold kind glyph + the display title as the HEADING, the right CLUSTER carries the subordinate live
/// telemetry (running / agent / RTT) split by 1px vertical separators. Reads the same shared
/// ``PanePresentation`` derivations the old header used, so nothing drifts; reading the `@Observable` handle
/// re-renders the strip as the focused pane's status changes.
struct PaneStatusBar: View {
    @Bindable var store: WorkspaceStore

    /// The active session's active tab's focused pane — the one the status bar describes.
    private var focusedPaneID: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    /// Cached last non-nil focused pane ID. Prevents a blank flash during the single render pass
    /// where `focusedPaneID` is transiently nil (close + reseed reconciliation gap).
    @State private var lastKnownPaneID: PaneID?

    /// Resolve the pane ID to render: live value when available, cached value during the transient
    /// nil window, nil only when no pane has ever been focused (truly empty workspace).
    private var resolvedPaneID: PaneID? { focusedPaneID ?? lastKnownPaneID }

    /// The live density multiplier (OPTIONAL form — falls back to the shared instance rather than TRAPPING
    /// when rendered outside the injected scope). P5: reading it inside `body` records the dependency so the
    /// HStack's INNER item spacing reflows on a density-tier flip too (the horizontal PADDING reflows via the
    /// tracked `.dsSpace` modifier; the spacing PARAMETER must be a value, so it scales through this).
    @Environment(DSScale.self) private var scale: DSScale?

    /// The inner HStack item spacing, scaled live (base 6 — the old fixed `Space.m`). Single `*`, no FMA.
    private var itemSpacing: CGFloat { 6 * (scale?.multiplier ?? DSScale.shared.multiplier) }

    var body: some View {
        HStack(spacing: itemSpacing) {
            if let id = resolvedPaneID, let spec = store.tree.spec(for: id) {
                content(id: id, spec: spec)
            } else {
                // Guard nil focus: render an empty bar so the shell keeps its bottom strip.
                Spacer()
            }
        }
        // P5: the horizontal padding routes through the tracked `.dsSpace` path (base 8 = old `Space.l`) so it
        // reflows live on a density-tier flip, instead of the fixed unscaled `AislopdeskTheme.Space.l` literal.
        .dsSpace(.horizontal, 8)
        // P3b: the status bar is L3 chrome, so its height comes from the DS density token (default 26) and
        // its bg is `DSColor.chrome` (n3), a step above the `paneBg` content it summarises. P5: via the
        // tracked `.dsFrame(height:)` so a density TIER flip reflows the strip height LIVE (reads
        // @Environment(DSThemeStore.self) for the tier height + @Environment(DSScale.self) for the multiplier).
        .dsFrame(height: \.statusBarHeight)
        .background(DSColor.chrome)
        .overlay(alignment: .top) {
            // The chrome-meets-content top hairline reads at `borderComponent` (white·0.11) — a visible
            // seam, vs the old near-invisible `border` (white·0.07).
            Rectangle().fill(DSColor.borderComponent).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status bar")
        .onChange(of: focusedPaneID) { _, newID in
            if let newID { lastKnownPaneID = newID }
        }
    }

    // MARK: - Pure telemetry transforms (unit-tested headlessly — no SwiftUI layout)

    /// The RTT label, a PURE function of milliseconds: "<1ms" for a sub-millisecond ping, else a rounded
    /// integer + "ms". Extracted so the format (which must pair with `.monospacedDigit()` to never jitter)
    /// is testable. `ms` is in practice a VALIDATED non-nil measured Double (from `PanePresentation.latencyMS`),
    /// but a TOTAL formatter must not be able to crash the GUI on a single bad sample: a non-finite `ms`
    /// (NaN — for which `ms < 1` is `false` — or ±inf, which overflows `Int`) would trap in `Int(_:)`, so we
    /// guard finiteness up front and emit the em-dash placeholder. The `< 1` boundary is then a plain ordered
    /// comparison on a finite value.
    static func rttLabel(_ ms: Double) -> String {
        guard ms.isFinite else { return "—" }
        return ms < 1 ? "<1ms" : "\(Int(ms.rounded()))ms"
    }

    /// The RTT colour, a PURE function of the over-threshold flag: amber (``DSColor/statusYellow``) when the
    /// ping is past the "this will feel laggy" line, else the subordinate ``DSColor/textTertiary``. The
    /// threshold comparison (`ms > 100`) is computed by the caller on a validated Double; this maps the
    /// resolved boolean to a colour so the telemetry colour rule is documented + testable.
    @MainActor
    static func rttColor(overThreshold: Bool) -> Color {
        overThreshold ? DSColor.statusYellow : DSColor.textTertiary
    }

    @ViewBuilder
    private func content(id: PaneID, spec: PaneSpec) -> some View {
        let handle = store.handle(for: id)
        let status = PanePresentation.connectionStatus(handle)
        let running = PanePresentation.isRunning(handle)

        // LEFT identity cluster — the HEADING (P3b): a semibold kind glyph + a footnote-medium title at
        // `textSecondary`, clearly heavier than the right-side telemetry so the strip reads identity-first.
        Image(systemName: PaneLeafView.icon(for: spec.kind))
            .font(.system(size: DSScale.scaled(11), weight: .semibold))
            .foregroundStyle(DSColor.textSecondary)
            .accessibilityHidden(true)
        Text(PanePresentation.displayTitle(handle, spec: spec))
            // P3b: footnote (11pt) + .medium weight, textSecondary — the heading role (heavier than the
            // caption2 telemetry, which is 9pt regular textTertiary).
            .dsFont(.footnote)
            .fontWeight(.medium)
            .foregroundStyle(DSColor.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)

        Spacer(minLength: AislopdeskTheme.Space.m)

        // RIGHT cluster — TELEMETRY, subordinate (P3b): every item is caption2 (9pt) textTertiary, numeric
        // values `.monospacedDigit()`. Split by 1px separators, each with `DSSpace.s2` breathing room per
        // side. Order: PaneStatusDot · running · AgentStatusDot · RTT · sync · copy.
        separator
        // P5: pass the UNSCALED base (7) — PaneStatusDot applies the live scale via `.dsScaledFrame`.
        PaneStatusDot(status: status, running: running, size: 7)

        if running {
            separator
            Text("running…")
                // Subordinate telemetry size (caption2 9pt) in the semantic statusYellow token (matches the
                // RTT amber) so the whole right cluster shares one palette — no raw system .orange.
                .dsFont(.caption2)
                .foregroundStyle(DSColor.statusYellow)
                .lineLimit(1)
        }

        // The per-pane Claude/agent status dot (hidden when `.none`).
        if store.agentStatus(for: id) != .none {
            separator
            // P5: pass the UNSCALED base (7) — AgentStatusDot applies the live scale via `.dsScaledFrame`.
            AgentStatusDot(status: store.agentStatus(for: id), size: 7)
        }

        // Live RTT (the same smoothed app-layer ping the old header showed): amber past 100ms. The label +
        // colour route through the pure `rttLabel` / `rttColor` transforms; `.monospacedDigit()` keeps the
        // numeric column from jittering as the value updates.
        if case .connected = status.phase, let ms = PanePresentation.latencyMS(handle) {
            separator
            Text(Self.rttLabel(ms))
                .dsFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(Self.rttColor(overThreshold: ms > 100))
                .help("Round-trip time to the host")
        }

        // Sync-input chip: shown while per-tab sync is ON for the active pane's tab (⌘⇧I).
        if let tabID = store.tree.activeSession?.activeTab?.id,
           store.syncInputTabs.contains(tabID)
        {
            separator
            Label("sync", systemImage: "keyboard.badge.ellipsis")
                .dsFont(.caption2)
                .foregroundStyle(DSColor.accentSolid)
                .help(
                    "Sync Input to All Panes is ON — keystrokes are mirrored to every pane in this tab (⌘⇧I to toggle)",
                )
        }

        // Copy-mode chip (P5b): shown while THIS focused pane is in modal keyboard copy-mode (⌘⇧C). Resolves
        // the live terminal model via the store helper so pane A's mode never lights pane B's badge.
        if store.isCopyMode(for: id) {
            separator
            Label("COPY", systemImage: "doc.on.clipboard")
                .dsFont(.caption2)
                .foregroundStyle(DSColor.accentSolid)
                .help("Copy mode — keyboard scrollback navigation (q/Esc to exit)")
        }

        // P3b: a trailing pad (DSSpace.s4 = 8pt) AFTER the right cluster so the last chip anchors to the
        // edge with breathing room rather than butting the window edge. `.dsSpace` keeps it on the
        // live-scale path.
        Color.clear.frame(width: 0).dsSpace(.trailing, 8)
    }

    /// A 1px vertical separator between right-cluster items (Muxy `ProjectStatusBar.separator`), ~14pt tall.
    /// P3b: `borderSubtle` colour + `DSSpace.s2` (4pt) breathing room on EACH side (via `.dsSpace`) so the
    /// separators don't share the dense HStack item gap — each gets its own air.
    private var separator: some View {
        Rectangle()
            .fill(DSColor.borderSubtle)
            .frame(width: 1, height: 14)
            .dsSpace(.horizontal, 4)
            .accessibilityHidden(true)
    }
}
#endif
