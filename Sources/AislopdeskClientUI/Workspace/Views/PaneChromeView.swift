// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import AislopdeskAgentDetect
import SwiftUI

// MARK: - PaneChromeView (chrome-less on the tree shell; compact header on iOS carousel)

/// Wraps every leaf's content. The Muxy redesign makes the IDE tree shell CHROME-LESS: no per-pane
/// header, no opacity dim. The focused pane is full-opacity and seamless with its split siblings; the
/// bottom ``PaneStatusBar`` surfaces the focused pane's connection / title / RTT / agent state.
///
/// FOCUS RING (P2 polish): on a SPLIT tab the card border becomes a soft accent FOCUS RING on the
/// focused leaf (accent·0.55, 1.5pt) and a neutral hairline (`border`, 1pt) on the others — the
/// Linear/Raycast "active surface" cue. This intentionally reverses the earlier "no focus ring, focus
/// lives on the tab only" stance (the tab accent line still marks the active TAB; the ring marks the
/// active PANE within a split). The hard invariant that survives: NEVER dim an inactive pane — both
/// panes stay full-opacity; only the border colour/width changes.
///
/// The iOS compact carousel keeps a slim header (``showsHeader == true``): a single carousel pane has no
/// tab strip, so its header is the only place to surface the title + split/zoom/close controls. All
/// actions funnel through the store's pure mutations, so the chrome holds no state of its own.
struct PaneChromeView<Content: View>: View {
    /// The leaf this chrome wraps.
    let id: PaneID
    /// The leaf's intent (kind + title) — drives the header glyph and label.
    let spec: PaneSpec
    /// The live session, for the header status dot (read-only).
    let handle: (any PaneSessionHandle)?
    /// Whether this pane is focused. On the tree shell this drives the soft accent FOCUS RING (see the
    /// type doc); it also tints the compact carousel header.
    let isFocused: Bool
    /// Whether the tab is currently maximized on THIS pane (flips the maximize button's glyph/intent).
    let isZoomed: Bool
    /// The store, for the chrome's mutations.
    let store: WorkspaceStore
    /// Whether to draw the per-pane header bar. The Muxy IDE tree shell (``SplitTreeView``) sets this
    /// FALSE — Muxy has NO per-pane header (the tab strip is the only header; focus is the tab's accent
    /// line). The iOS compact carousel keeps it TRUE.
    var showsHeader: Bool = true
    /// Whether this chrome is mounted INSIDE a floating card (``FloatingPaneView``). When true the FLOATING
    /// CARD border is the single focus authority, so the chrome-less branch SUPPRESSES its own accent focus
    /// ring (keeping only the neutral hairline so the content keeps its rounded edge) to avoid a redundant
    /// double ring (outer card edge + inner pane edge). The P3 attention ring is UNAFFECTED — it must stay
    /// visible on a float (that is the whole point of P3).
    var isFloating: Bool = false
    /// The wrapped content (the leaf view).
    @ViewBuilder let content: () -> Content

    #if os(macOS)
    /// Whether THIS view's window is the key window. A FREE SwiftUI environment value (no NSWindow access,
    /// hang-safe) — when the window is backgrounded the focus ring falls back to the neutral border so a
    /// backgrounded window doesn't show a stale accent ring. On iOS this value is always `.active`, so the
    /// ring gates on `isFocused` alone there.
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    /// Reduce-Motion gate: the focus-ring spring + the attention-overlay fade fall to a near-instant
    /// crossfade under the system preference (via ``DSMotion/resolve(_:reduceMotion:)``).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the soft accent focus ring should show: the leaf is focused AND (on macOS) its window is key.
    /// SUPPRESSED for a floating mount — the floating card's own border is the focus authority there, so the
    /// inner chrome must not draw a second concentric ring.
    private var ringActive: Bool {
        guard !isFloating else { return false }
        #if os(macOS)
        return isFocused && controlActiveState == .key
        #else
        return isFocused
        #endif
    }

    var body: some View {
        if showsHeader {
            // The compact carousel keeps a slim header over the content (no tab strip to carry focus).
            // P2 ELEVATION NOTE: the inner-top highlight is INTENTIONALLY omitted on this branch — the
            // header bar + its bottom `Divider` already own the card's top edge, so a 1pt highlight would
            // sit UNDER chrome rather than on a bare card top. The highlight lives only on the chrome-less
            // tree-shell branch below, where the card top edge is exposed.
            VStack(spacing: 0) {
                header
                Divider()
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AislopdeskTheme.bg)
            // P3 ATTENTION RING on the compact/iOS carousel pane too: the carousel shows one pane at a
            // time so the "background pane" motivation is weaker, but the blocked/done cue on the visible
            // pane must not be lost. Same self-contained, status-gated, hit-test-disabled leaf overlay.
            .overlay(attentionOverlay)
            // P5 MOTION: the attention-overlay fade routes through DSMotion.layout (spring), Reduce-Motion-
            // gated to the near-instant crossfade. Keyed on `paneStatus` so it fades on a blocked/done flip.
            .animation(DSMotion.resolve(DSMotion.layout, reduceMotion: reduceMotion), value: paneStatus)
        } else {
            // The IDE tree shell: CHROME-LESS pane body — no per-pane header, no opacity dim. The Warp
            // "floating card" look: 8pt continuous rounded corners floating on the sunken gutter that
            // SplitTreeView's half-gap padding exposes.
            //
            // BORDER → FOCUS RING: the focused pane gets a soft accent ring (accent·0.55, 1.5pt); the
            // others keep the neutral `border` hairline (1pt). NEVER an opacity dim on the inactive
            // branch — both panes stay full-opacity; only the border colour/width changes (the documented
            // hard invariant). The tab's bottom accent line still marks the active TAB; this ring marks
            // the active PANE within a split.
            //
            // METAL CLIPPING: SwiftUI `.clipShape` clips the SwiftUI render tree but NOT the hosted
            // AppKit/UIKit sublayer that libghostty installs (the IOSurfaceLayer — see
            // GhosttyLayerBackedView). The corner radius for the live Metal surface is applied directly
            // on the hosted layer in GhosttyLayerBackedView.layout() via `layer?.cornerRadius` +
            // `layer?.masksToBounds = true`. This view supplies the visual card chrome only; the renderer
            // is responsible for its own layer clipping.
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // P3a PANE-CARD DEPTH: the content-card bg moves to the L2 token `DSColor.paneBg` (n2
                // #17181C), one step lighter than the L1 window bg (n1), completing the surface-lightness
                // ladder (gutter n0 < window n1 < pane-card n2). HONEST SCOPE: the libghostty IOSurface
                // draws its OWN opaque content bg and covers essentially the whole card interior, so this
                // n2 fill is SEEN only at the 8pt rounded-corner arcs + the 1pt frame between the IOSurface
                // edge and the strokeBorder — the value is the consistent L2 token (a non-terminal/empty/
                // loading pane, or the corner antialiasing, all read the same n2), not a dramatic change.
                // Content stays FLAT OPAQUE: this swaps one opaque fill for another opaque sibling-lightness
                // fill UNDER the existing clip/highlight/border overlays — no glass, no shadow, no new seam.
                .background(DSColor.paneBg)
                .clipShape(
                    RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous),
                )
                // P2 ELEVATION: the inner top-edge highlight (white·0.12 → clear, 1pt) — the premium
                // dark-surface "tell" the redesign adds to the pane card. Depth on L2/L3 comes from the
                // lightness ladder + hairline + THIS highlight; there is deliberately NO drop-shadow here
                // (shadows are L4-overlay-only, adopted in P4). Clipped to the SAME rounded card shape so
                // the 1pt highlight follows the corner radius and never bleeds past the card edge.
                // `allowsHitTesting(false)` lives inside `innerTopHighlight()`, so it never swallows a tap
                // meant for the terminal content. The libghostty IOSurface keeps drawing its own opaque
                // content bg underneath — the card stays flat-opaque; this is a decorative leaf stroke.
                .overlay(alignment: .top) {
                    DSElevation.innerTopHighlight()
                        .clipShape(
                            RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous),
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous)
                        .strokeBorder(
                            ringActive
                                ? AnyShapeStyle(AislopdeskTheme.accent.opacity(0.55))
                                : AnyShapeStyle(AislopdeskTheme.border),
                            lineWidth: ringActive ? 1.5 : 1,
                        )
                        // P5 MOTION (the spec headline): the focus-ring colour+width transition is the pane
                        // SELECTION cue, so it springs via DSMotion.select (slight overshoot reads premium on
                        // dark) — Reduce-Motion-gated to the near-instant crossfade. ringActive logic + the
                        // never-dim invariant are UNCHANGED; only the curve moves from the old easeInOut(0.15).
                        .animation(DSMotion.resolve(DSMotion.select, reduceMotion: reduceMotion), value: ringActive),
                )
                // P3 ATTENTION RING: layered OUTSIDE the focus-ring overlay above so it shows EVEN WHEN
                // UNFOCUSED (the whole point — notice a background pane). Gated purely on the pane's
                // status (`attentionColor != nil`), independent of `ringActive`. Blocked pulses, done is
                // steady. NEVER an opacity dim on content (the hard invariant) — this is a leaf stroke.
                //
                // CONCENTRIC, NOT CO-EDGE: the attention ring is drawn on the OUTER edge (a strokeBorder
                // on the full bounds, same radius as the focus ring), and when the pane is ALSO focused a
                // thin accent focus ring is redrawn on an INSET shape inside it (see `attentionOverlay`).
                // A bare co-edge stroke would fully cover the 1.5pt focus ring; insetting keeps both legible
                // so a focused+blocked pane unambiguously reads "this is the active pane AND it's blocked".
                .overlay(attentionOverlay)
                // P5 MOTION: the attention-overlay fade routes through DSMotion.layout (spring), Reduce-Motion-
                // gated to the near-instant crossfade. Keyed on `paneStatus` so it fades on a blocked/done flip.
                .animation(DSMotion.resolve(DSMotion.layout, reduceMotion: reduceMotion), value: paneStatus)
        }
    }

    // MARK: P3 attention ring (supervision cockpit)

    /// This pane's current agent status (the same source the carousel dot reads). Drives the attention
    /// ring + the pulse predicate — a pure function of the current status (no history), so it clears
    /// automatically when the pane returns to idle/working/none.
    private var paneStatus: ClaudeStatus { store.agentStatus(for: id) }

    /// The attention ring colour, or `nil` when the pane needs no attention: needsPermission → statusRed
    /// (blocked, the most urgent), done → statusGreen (finished, waiting to be seen). idle/working/none
    /// → `nil` (no ring).
    private var attentionColor: Color? {
        switch paneStatus {
        case .needsPermission: AislopdeskTheme.statusRed
        case .done: AislopdeskTheme.statusGreen
        case .none,
             .idle,
             .working: nil
        }
    }

    /// The status-coloured attention ring on the OUTER edge of the chrome-less card, plus — when the pane
    /// is ALSO focused — a thin accent focus ring redrawn on an INSET shape inside it, so the two read
    /// concentrically (outer status ring, inner blue focus ring) rather than the status ring covering the
    /// focus ring at the same edge. A `needsPermission` ring breathes (the leaf-local sanctioned pulse,
    /// like the working dot); a `done` ring is steady. Empty when the pane needs no attention. A short
    /// ease (≤0.22s) fades the whole overlay in/out so a background pane going blocked/done — or clearing
    /// back to idle — matches the focus ring's easing instead of popping.
    @ViewBuilder
    private var attentionOverlay: some View {
        if let color = attentionColor {
            ZStack {
                // Outer status ring on the full bounds.
                RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous)
                    .strokeBorder(color, lineWidth: UIMetrics.paneAttentionRing)
                    .modifier(AttentionPulse(active: paneStatus == .needsPermission))

                // Inner focus ring (concentric) only when the pane is also focused — inset by the
                // attention-ring width so a thin blue ring shows INSIDE the red/green status ring. The
                // outer status ring is the dominant "needs you" cue; this keeps "you are here" legible too.
                if ringActive {
                    RoundedRectangle(
                        cornerRadius: AislopdeskTheme.Radius.pane - UIMetrics.paneAttentionRing,
                        style: .continuous,
                    )
                    .strokeBorder(AislopdeskTheme.accent.opacity(0.55), lineWidth: 1.5)
                    .padding(UIMetrics.paneAttentionRing)
                }
            }
            .transition(.opacity)
            .allowsHitTesting(false) // decorative — never swallow a tap meant for the content
            .accessibilityHidden(true)
        }
    }

    // MARK: Header (compact carousel only)

    private var header: some View {
        HStack(spacing: AislopdeskTheme.Space.m) {
            Image(systemName: PaneLeafView.icon(for: spec.kind))
                .font(.system(size: UIMetrics.fontCaption))
                .foregroundStyle(isFocused ? AislopdeskTheme.accent : AislopdeskTheme.fgMuted)
                .accessibilityHidden(true) // decorative — the title Text carries the row's label

            let status = connectionStatus
            PaneStatusDot(status: status, running: isRunning)

            // W5: the per-leaf Claude/agent status dot (hidden when `.none` — the common case until W10/W11).
            AgentStatusDot(status: store.agentStatus(for: id))

            Text(displayTitle)
                .font(.system(size: UIMetrics.fontCaption, design: .monospaced))
                .foregroundStyle(isFocused ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            // Reconnecting/unreachable detail beside the dot so "connecting forever" reads as a clear
            // "Reconnecting (n) — retrying in Ns" / "Unreachable" (surfacing the WF3 timeout + backoff).
            statusDetail(status)

            // Live RTT badge (docs/26 D10): the smoothed ping/pong RTT beside the title while
            // connected. Hidden until the first sample; amber past 100ms (the "this will feel laggy" line).
            if case .connected = status.phase, let ms = latencyMS {
                Text(ms < 1 ? "<1ms" : "\(Int(ms.rounded()))ms")
                    .font(.system(size: UIMetrics.fontMicro).monospacedDigit())
                    .foregroundStyle(ms > 100 ? AnyShapeStyle(.orange) : AnyShapeStyle(AislopdeskTheme.fgDim))
                    .lineLimit(1)
                    .accessibilityLabel(Text("latency \(Int(ms.rounded())) milliseconds"))
                    .help("Smoothed round-trip time to the host (3s ping)")
            }

            // A "running…" affordance while an OSC 133 command executes on this pane.
            if isRunning {
                Text("running…")
                    .font(.system(size: UIMetrics.fontMicro))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityLabel(Text("command running"))
            }

            // WB2: the Warp-style block STATUS CHIP — the latest command's status, tappable to open the
            // Command Navigator. Hidden until the first block.
            blockStatusChip

            Spacer(minLength: AislopdeskTheme.Space.m)

            controls
        }
        .padding(.horizontal, AislopdeskTheme.Space.m)
        .padding(.vertical, AislopdeskTheme.Space.s)
        #if os(macOS)
            // BUG-2 ("ở cạnh trên/header vẫn bị"): the header bar is hit-OPAQUE (it carries the
            // tap-to-focus gesture over the whole bar), so a scroll over it was SWALLOWED instead of
            // panning. Fix with a `ScrollPanForwarder` (a real NSView that forwards scroll →
            // `store.scrollPan`) that ALSO carries the tap.
            .background {
                ScrollPanForwarder(store: store)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { focusThisLeaf() })
            }
            .background(isFocused ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
        #else
            .background(isFocused ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
            .contentShape(Rectangle())
            // A plain TAP on the title bar focuses the pane.
            .simultaneousGesture(TapGesture().onEnded { focusThisLeaf() })
        #endif
    }

    // MARK: WB2 block status chip

    /// The pane's latest Warp-style block (the current/last command), or `nil` until one has run.
    private var latestBlock: CommandBlock? { PanePresentation.latestBlock(handle) }

    /// The block status chip: the latest command's status icon + a compact "exit N · 1.2s" label, tappable
    /// to open the Command Navigator. Hidden until the first block lands (and quiet while running — the
    /// existing "running…" cue already covers that).
    @ViewBuilder
    private var blockStatusChip: some View {
        if let block = latestBlock, block.complete {
            Button { PanePresentation.openBlockNavigator(handle) } label: {
                HStack(spacing: 3) {
                    Image(systemName: block.statusSymbol)
                        .foregroundStyle(blockTint(block))
                    Text(blockChipLabel(block))
                        .font(.system(size: UIMetrics.fontMicro).monospacedDigit())
                        .foregroundStyle(AislopdeskTheme.fgMuted)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderless)
            .help("Open Command Navigator (⌃⌘O)")
            .accessibilityLabel(Text("Last command \(block.statusLabel)"))
        }
    }

    /// The chip's compact label: the exit badge plus a duration when known ("exit 0 · 1.2s").
    private func blockChipLabel(_ block: CommandBlock) -> String {
        if let duration = block.durationLabel {
            return "\(block.statusLabel) · \(duration)"
        }
        return block.statusLabel
    }

    /// The chip's status tint (green succeeded / red failed; the running case is filtered out above).
    private func blockTint(_ block: CommandBlock) -> Color {
        switch block.status {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }

    /// Focuses this leaf in whichever live model is active (W5): the tree's active pane on the IDE shell,
    /// the canvas focus on the retained-but-dead path.
    private func focusThisLeaf() {
        switch store.liveModel {
        case .tree: store.focusPaneTree(id)
        case .canvas: store.focus(id)
        }
    }

    /// The per-leaf controls. On the LIVE tree shell it is the slim coding-IDE split-leaf header —
    /// split-right (⌘D), split-down (⌘⇧D), zoom, close — all funneling through the store's tree ops. On
    /// the retained-but-dead canvas path it keeps the old add-KIND-picker + maximize + close.
    @ViewBuilder
    private var controls: some View {
        switch store.liveModel {
        case .tree:
            HStack(spacing: 2) {
                chromeButton("rectangle.split.2x1", help: "Split right (⌘D)") {
                    store.focusPaneTree(id)
                    store.splitPaneTree(id, axis: .horizontal, kind: SettingsKey.defaultPaneKind)
                }
                chromeButton("rectangle.split.1x2", help: "Split down (⌘⇧D)") {
                    store.focusPaneTree(id)
                    store.splitPaneTree(id, axis: .vertical, kind: SettingsKey.defaultPaneKind)
                }
                chromeButton(
                    isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: isZoomed ? "Restore" : "Zoom",
                ) {
                    store.focusPaneTree(id)
                    store.toggleZoomTree()
                }
                chromeButton("xmark", help: "Close pane", role: .destructive) {
                    // ITEM A3: route through the busy-shell guard so the chrome close honours the same
                    // confirmation ⌘W / the canvas path do — not a raw close.
                    store.requestClosePaneTree(id)
                }
            }
            .font(.system(size: UIMetrics.fontCaption))
        case .canvas:
            HStack(spacing: 2) {
                addMenu
                chromeButton(
                    isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: isZoomed ? "Restore" : "Maximize",
                ) {
                    store.focus(id) // maximize acts on the focused pane — ensure it's this one first
                    store.toggleZoom()
                }
                chromeButton(
                    "xmark",
                    help: store.isOnlyLeaf(id) ? "Close last pane" : "Close pane",
                    role: .destructive,
                ) {
                    store.requestClosePane(id)
                }
            }
            .font(.system(size: UIMetrics.fontCaption))
        }
    }

    /// The "add pane" KIND-picker: tap to add a terminal pane to the canvas, or open the menu to add a
    /// Claude Code / Remote pane.
    @ViewBuilder
    private var addMenu: some View {
        Menu {
            Button {
                store.addPane(kind: .terminal)
            } label: {
                Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
            }
            Button {
                store.addPane(kind: .remoteGUI)
            } label: {
                Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: UIMetrics.resizeHandleHitArea, height: UIMetrics.resizeHandleHitArea)
        } primaryAction: {
            store.addPane(kind: .terminal)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
            .menuStyle(.borderlessButton)
        #endif
            .fixedSize()
            .foregroundStyle(AislopdeskTheme.fgMuted)
            .help("Add pane")
            .accessibilityLabel("Add pane")
    }

    private func chromeButton(
        _ systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void,
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: UIMetrics.resizeHandleHitArea, height: UIMetrics.resizeHandleHitArea)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AislopdeskTheme.fgMuted)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Status dot

    /// The header status presentation (the shared ``PanePresentation`` derivation).
    private var connectionStatus: PaneConnectionStatus { PanePresentation.connectionStatus(handle) }

    /// Whether an OSC 133 command is currently executing in this pane's shell.
    private var isRunning: Bool { PanePresentation.isRunning(handle) }

    /// The smoothed app-layer RTT for the latency badge (`nil` until the first ping/pong completes).
    private var latencyMS: Double? { PanePresentation.latencyMS(handle) }

    /// The header label: the LIVE OSC 0/2 terminal title when set, else `spec.title`.
    private var displayTitle: String { PanePresentation.displayTitle(handle, spec: spec) }

    /// The compact status detail shown beside the title for the in-flight / terminal states. For a
    /// reconnecting pane with a known next-retry instant it ticks a live "retrying in Ns" countdown via
    /// a `TimelineView`; otherwise it shows the static label. Hidden for the steady connected/idle states.
    @ViewBuilder
    private func statusDetail(_ status: PaneConnectionStatus) -> some View {
        switch status.phase {
        case .reconnecting:
            if let nextRetry = status.nextRetry {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(reconnectLabel(status, now: context.date, nextRetry: nextRetry))
                        .font(.system(size: UIMetrics.fontMicro))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            } else {
                Text(status.label)
                    .font(.system(size: UIMetrics.fontMicro))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        case .connecting:
            // An initial dial can block on the dead-host handshake/timeout (~10s); surface "Connecting…"
            // beside the title — neutral (muted) since it is not yet an error.
            Text(status.label)
                .font(.system(size: UIMetrics.fontMicro))
                .foregroundStyle(AislopdeskTheme.fgMuted)
                .lineLimit(1)
        case .unreachable,
             .failed:
            // Show the CONCRETE reason ("Failed: timed out") inline, not the bare word "Failed".
            Text(status.detailedLabel)
                .font(.system(size: UIMetrics.fontMicro))
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(status.detailedLabel)
        default:
            EmptyView()
        }
    }

    /// "Reconnecting (n) — retrying in Ns" once a countdown is known; clamps the remaining seconds at 0
    /// and collapses to "Reconnecting (n)…" when the deadline has passed (the attempt is firing now).
    private func reconnectLabel(_ status: PaneConnectionStatus, now: Date, nextRetry: Date) -> String {
        let remaining = Int(nextRetry.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return status.label }
        return "\(status.label) retrying in \(remaining)s"
    }
}

// MARK: - AttentionPulse (a gentle breathe for the BLOCKED attention ring only)

/// Wraps the P3 attention ring in a calm opacity breathe when `active` — used for the `needsPermission`
/// (blocked) ring so it gently pulses to demand attention; the `done` ring is steady (`active == false`).
/// The SAME sanctioned leaf-local `repeatForever` pattern as ``WorkingPulse`` (the breathing working
/// dot): a single repeating `.easeInOut` opacity fade driven by a local `@State` on `.onAppear`. It is a
/// leaf stroke overlay (NOT on the keystroke/echo path, NOT over the terminal/IOSurface), so the
/// interpolated fade is correct + cheap. When `active` is false the receiver is returned untouched.
private struct AttentionPulse: ViewModifier {
    let active: Bool

    /// Floor / ceiling of the breathe — never fully fades (the ring stays legible). Matches the house
    /// ``WorkingPulse`` floor (`0.6` ≈ `0.65`) so a whole-pane ring inhales as calmly as the working dot
    /// rather than reading as a blink — only a touch deeper since "attention" is a hair more insistent.
    private static let floor = 0.6

    @State private var breathing = false
    /// Reduce-Motion gate: under the system preference the repeatForever breathe is DROPPED — the ring stays
    /// steady at full opacity (legible, never pulsing) per the spec's "spring/translate → near-instant" rule.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content
                .opacity(breathing ? 1.0 : Self.floor)
                // P5 MOTION: the blocked-pane attention pulse is DSMotion.attention (the repeatForever
                // breathe). Under Reduce Motion the `!reduceMotion` guard above takes the steady branch
                // instead, so a motion-sensitive user gets a static ring (the spec's reduced-motion fallback).
                .animation(DSMotion.attention, value: breathing)
                .onAppear { breathing = true }
        } else {
            // Steady: either no attention needed, or Reduce Motion is on (the ring shows at full opacity but
            // does not pulse).
            content
        }
    }
}

#endif
