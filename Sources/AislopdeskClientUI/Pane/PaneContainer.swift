// PaneContainer — one placed leaf = the flush, borderless pane content.
//
// Resolves the pane's `LivePaneSession` handle + `PaneSpec` from the store, routes by pane kind to the
// content view (terminal → `TerminalLeafView`; `.remoteGUI`/`.systemDialog` → the `VideoWindowFactory`
// seam, else a native placeholder). The terminal renders as a FLUSH, borderless panel on paper — there
// is NO floating card, NO accent ring, NO drop shadow and NO inset gutter. The per-pane controls
// (split/close) hover-reveal as a top overlay instead of a resting header bar; focus is conveyed only by
// dimming the unfocused panes (the `⌘D` split treatment). Tap anywhere focuses the pane via the store.
//
// The whole pane is keyed `.id(PaneID)` by the SplitContainer so the surface/connection are never reused
// across panes (identity hazard). SYSTEM colours/fonts only.
//
// DEFERRED (clean seams, do NOT wire in L2):
//   - TODO(L5): the per-pane agent footer coordinator + overflow context menu.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI
import UniformTypeIdentifiers

struct PaneContainer: View {
    let store: WorkspaceStore
    let paneID: PaneID
    /// Whether this pane is the active tab's active (focused) pane.
    let isFocused: Bool
    /// Whether this pane is currently ON-SCREEN (its tab is active AND it is not zoom-hidden). Drives the video
    /// activation lifecycle for a `.remoteGUI` pane (see ``GuiLeafView``). Defaults to `true` so terminal /
    /// static-mirror callers are unaffected.
    var isVisible: Bool = true
    /// This pane's current laid-out size (from the solver, via ``SplitContainer``). The SINGLE generic resize
    /// signal: whenever it changes — a pane-divider commit, a window-edge / sidebar / inspector resize, a
    /// split add/remove, a zoom, a balance, a tab switch — the content has been resized and its (frozen /
    /// stretched) surface won't match until it re-renders, so the scrim is shown until things settle.
    var size: CGSize = .zero
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// `true` from the moment ``size`` changes until it has held steady for ``resizeScrimSettle``. This is
    /// the geometry signal that STARTS the scrim — it covers EVERY resize source and self-clears. On its
    /// own it is only a TIMER proxy for "re-rendered"; the real "fresh pixels landed" signal that HOLDS the
    /// scrim past this timer is the model's ``LivePaneSession/awaitingResizeReflow`` (OR-ed in below).
    @State private var resizing = false
    /// The last ``size`` the settle task observed — distinguishes the initial mount (no scrim) from a real
    /// resize, and lets the task keep the scrim up across a continuous drag (every step restarts the settle).
    @State private var settledSize: CGSize?

    /// STICKY for the duration of an interactive divider drag: set the first time THIS pane changes size
    /// while a drag is active, cleared when the drag ends. It holds the scrim across a PAUSED drag (mouse
    /// held, cursor still) — the geometry-settle timer clears `resizing` after 200 ms, but the host send is
    /// deferred to release so `awaitingReflow` is not armed yet, leaving a gap the overlay would flash
    /// through. Gating on a real size-change keeps it scoped to the panes actually being resized.
    @State private var resizedDuringDrag = false

    /// The external-drag state for THIS pane (E18 WI-5): the classified payload of a hovering drag + the
    /// zone under the cursor. Drives ``PaneDropOverlay`` (which zones to show / highlight) and is mutated by
    /// the ``PaneDropReceiver`` `DropDelegate`. Per-pane (the whole pane is `.id(PaneID)`-keyed).
    @State private var dropModel = PaneDropOverlayModel()

    /// The scene-root overlay coordinator (E18 WI-6): the receiver pushes the host-resolved advisory toast
    /// for a folder → New-Tab `cd` into it. `nil` outside the scene root (tests / the static mirror), where
    /// the toast is a no-op.
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    /// How long ``size`` must hold steady before the scrim fades — long enough to span the host grid-reflow /
    /// surface relayout that lands the fresh pixels, short enough not to linger once they have.
    private let resizeScrimSettle: Duration = .milliseconds(200)

    /// The pane content model's "resized but not re-rendered yet" signal (terminal host-reflow wait OR
    /// remote-GUI host-re-capture wait), `false` for a pane with no live model. HOLDS the scrim past the
    /// geometry settle so the overlay clears only when the fresh pixels actually land — on a slow link the
    /// geometry timer alone would uncover the stretched / stale frame ~1 RTT too early.
    private var awaitingReflow: Bool { live?.awaitingResizeReflow ?? false }

    /// Whether an interactive divider drag is in progress anywhere (pane or sidebar divider). Combined with
    /// ``resizedDuringDrag`` it holds the scrim across a paused drag without showing it on untouched panes.
    private var dragging: Bool { store.isInteractiveResizeActive }

    /// Cover the surface with the resize scrim while a resize is settling (never on the static snapshot
    /// path). THREE signals OR together: the geometry settle STARTS it; the drag-in-progress hold keeps it
    /// up while the mouse is held (even paused); the model's reflow signal HOLDS it across the host
    /// round-trip until the fresh pixels land. Together they leave no gap to flash through.
    private var showResizeScrim: Bool {
        !staticMirror && (resizing || (dragging && resizedDuringDrag) || awaitingReflow)
    }

    /// The live session for this pane (terminal model / input bar), if materialized.
    private var live: LivePaneSession? { store.handle(for: paneID) as? LivePaneSession }

    private var spec: PaneSpec? { store.tree.activeSession?.specs[paneID] }

    /// The pane's kind drives which leaf view renders. Reads the live handle's kind (falls back to spec).
    private var kind: PaneKind { live?.kind ?? spec?.kind ?? .terminal }

    /// Whether this is a video (PATH 2) pane. `PaneKind.isVideo` is internal to WorkspaceCore, so the
    /// equivalent check is inlined here (the case set matches `PaneKind.isVideo`).
    private var isVideo: Bool { kind == .remoteGUI || kind == .systemDialog }

    /// The leaf content, routed by pane kind. A terminal pane renders the `TerminalLeafView` over the
    /// terminal-renderer seam; a video pane renders the `GuiLeafView` over the `VideoWindowFactory` seam
    /// (live surface / in-pane picker / cap-gated placeholder, with the cap-enforced activation lifecycle).
    @ViewBuilder private var paneContent: some View {
        if kind == .chooser {
            // A just-created, unconfigured pane: its CONTENT is the pane-type chooser (Terminal / Remote
            // window). Picking flips the spec kind in place (`choosePaneKind`) and reconcile materializes the
            // real session here on the SAME PaneID — no modal, no new leaf.
            InPaneChooserView(store: store, paneID: paneID)
        } else if isVideo {
            GuiLeafView(
                live: live,
                isFocused: isFocused,
                staticMirror: staticMirror,
                store: store,
                paneID: paneID,
                isVisible: isVisible,
            )
        } else {
            TerminalLeafView(
                live: live,
                isFocused: isFocused,
                staticMirror: staticMirror,
                // E10 WI-4 (ES-E10-3): feed the bottom status bar. cwd is the host-reported OSC-7 dir kept on
                // the spec (reactive — reading it here re-renders on change); host is the app-global
                // connection target persisted on the active session.
                cwd: spec?.lastKnownCwd,
                host: store.tree.activeSession?.connection?.host ?? "",
                // E10 WI-10 (G8): the Command Navigator (⌃⌘O) jumps the scrollback through the store.
                store: store,
            )
        }
    }

    var body: some View {
        paneContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Slate.Surface.face)
            // While this pane is mid-resize, cover its (frozen / stretched) surface with a calm scrim so the
            // moment reads as a deliberate "resizing" state, not a glitchy stretch. Kept in the tree at
            // opacity 0 (cheap) and faded in — never hit-tests, so taps / the divider gesture pass through.
            .overlay {
                PaneResizeScrim()
                    .opacity(showResizeScrim ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(Slate.Anim.reveal, value: showResizeScrim)
            }
            // E18 WI-5: the external-drag drop-zone overlay. Kept in the tree at opacity 0 (cheap, never
            // hit-tests) and faded in only while a supported drag hovers the pane (`dropModel.isActive`). It
            // DRAWS from the same ``PaneDropZoneLayout`` the ``PaneDropReceiver`` below hit-tests against, so
            // the highlighted blob is exactly the zone the cursor is over (draw == hit).
            .overlay {
                PaneDropOverlay(
                    layout: PaneDropZoneLayout(size: size),
                    activeZone: dropModel.activeZone,
                    allowedZones: dropModel.allowedZones,
                )
                .opacity(dropModel.isActive ? 1 : 0)
                .allowsHitTesting(false)
                .animation(Slate.Anim.reveal, value: dropModel.isActive)
            }
            // Generic resize signal: when this pane's laid-out `size` changes (from ANY source) show the
            // scrim, then hold it until the size has been steady for `resizeScrimSettle`. `.task(id:)`
            // cancels + restarts on every change, so a continuous drag keeps the scrim up. The first run
            // (initial mount, `settledSize == nil`) is NOT a resize, so it shows nothing. This timer is only
            // the START + a floor — once it elapses, `awaitingReflow` (the model's real "fresh pixels
            // landed" signal, OR-ed into `showResizeScrim`) keeps the overlay up across the host round-trip
            // and clears it the instant the reflowed / re-captured content actually renders.
            .task(id: size) {
                guard !staticMirror else { return }
                let prev = settledSize
                settledSize = size
                // A change between two REAL (non-empty) sizes is a resize. A transition from / to `.zero` is
                // just the initial layout settling (or teardown), which must NOT flash the scrim on mount.
                if let prev, prev != size,
                   prev.width > 0, prev.height > 0, size.width > 0, size.height > 0
                {
                    resizing = true
                    // Mark this pane as part of the active drag (sticky through pauses) so the scrim
                    // survives a still-held cursor — see ``resizedDuringDrag``.
                    if dragging { resizedDuringDrag = true }
                }
                guard resizing else { return }
                do { try await Task.sleep(for: resizeScrimSettle) } catch { return }
                resizing = false
            }
            // Drag ENDED → drop the sticky drag-hold. The release commit arms `awaitingReflow`, which now
            // carries the scrim across the host round-trip until the reflowed pixels land — so clearing the
            // hold here (both settle in the same runloop turn) leaves no gap for the overlay to flash through.
            .onChange(of: dragging) { _, active in
                if !active { resizedDuringDrag = false }
            }
            // The terminal is a FLUSH, borderless panel on paper — fills the leaf rect edge-to-edge.
            // No rounded card, no accent ring, no drop shadow, no gutter, and NO per-pane header bar (the
            // active pane's title + split/close controls live in the titlebar `⋯` menu). Adjacent split
            // panes are separated only by the `PaneDivider` hairline `SplitContainer` places between leaves.
            .contentShape(Rectangle())
            .onTapGesture { store.focusPaneTree(paneID) }
            // E18 WI-5/WI-6: accept external file/folder/URL/text drags. The receiver is disabled on the
            // static snapshot path (`!staticMirror`); it gates the overlay above and on `performDrop` FOCUSES
            // THIS pane (`paneID`) then actuates against the store (terminal-rooted `cd` ingress),
            // THIS (dropped-on) pane's live terminal (verbatim inject / host-open), and the overlay
            // coordinator (advisory toast) — so a Split / Open-In-Place drop targets the pane under the cursor,
            // not whichever pane was focused. The accepted UTTypes mirror the receiver's classifier precedence.
            .onDrop(of: PaneDropReceiver.acceptedTypes, delegate: PaneDropReceiver(
                paneID: paneID,
                layout: PaneDropZoneLayout(size: size),
                model: dropModel,
                enabled: !staticMirror,
                store: store,
                terminalModel: live?.terminalModel,
                overlayCoordinator: overlayCoordinator,
            ))
            // FOCUS = a small FILLED accent triangle tucked into the active pane's TOP-LEFT corner (Warp-style,
            // the KEPT marker after the box/bracket/underline/dot/top-bar iterations). `Slate.State.accent`,
            // faded in only while focused; the unfocused panes render at FULL opacity (no dim — it washed out
            // live content). `allowsHitTesting(false)` so taps / the divider gesture pass through. OUTERMOST
            // overlay → above the resize-scrim + drop-zone overlays (KEPT exactly as-is — re-render logic).
            .overlay(alignment: .topLeading) {
                PaneFocusCorner(size: Slate.Metric.focusCornerSize)
                    .fill(Slate.State.accent)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(Slate.Anim.standard, value: isFocused)
    }
}

/// The active-pane focus marker: a small FILLED right-triangle in the TOP-LEFT corner (Warp-style) — the
/// two legs run along the top + left pane edges, the hypotenuse cuts across. Sized by `size` (leg length),
/// auto-capped at the smaller pane side so a tiny pane keeps it.
private struct PaneFocusCorner: Shape {
    /// Leg length (points) of the corner triangle.
    var size: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = Swift.min(size, Swift.min(rect.width, rect.height))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY)) // the corner
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.minY)) // along the top edge
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + s)) // along the left edge
        p.closeSubpath()
        return p
    }
}
#endif
