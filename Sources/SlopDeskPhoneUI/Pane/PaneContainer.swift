// PaneContainer — one placed leaf = the flush, borderless pane content.
//
// Resolves the pane's `LivePaneSession` handle + `PaneSpec` from the store, routes by pane kind to the
// content view (terminal → `TerminalLeafView`; `.desktop` → the `VideoWindowFactory`
// seam, else a native placeholder). The terminal renders as a FLUSH, borderless panel on paper — there
// is NO floating card, NO accent ring, NO drop shadow and NO inset gutter. The per-pane controls
// (split/close) hover-reveal as a top overlay instead of a resting header bar. At REST focus is conveyed
// by adding a mark to the subject (`PaneFocusCorner`), never by dimming its siblings — that was tried and
// removed for washing out live content. The one exception is the ⌃⇥ walk, where the question changes on
// every tap and the answer has to be findable in 200ms (`PaneRecedeScrim`); it lasts exactly as long as
// the walk, which on THIS platform is not the length of a held modifier — nothing is held here, so the
// veil stands until the reader commits or cancels in the card
// (`Sources/SlopDeskPhoneUI/Overlays/PaneSwitcherOverlay.swift`). That card is what makes the veil legible
// rather than a lockup: the two read the same `store.paneSwitcher`, so for a while this pane dimmed for a
// gesture the phone drew no surface for and offered no way out of. Tap anywhere focuses the pane via the
// store.
//
// The whole pane is keyed `.id(PaneID)` by the SplitContainer so the surface/connection are never reused
// across panes (identity hazard). SYSTEM colours/fonts only.
//
// The old "DEFERRED to L5" note here named a per-pane agent footer and an overflow context menu. It is
// gone rather than done: neither exists on the MAC half either, so it was never a phone gap — it was a
// staging plan that outlived its stage, and a `TODO` naming something no half has reads as parity debt
// on the file that carries it. Agent state reaches both halves through the marks, not a pane footer.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct PaneContainer: View {
    let store: WorkspaceStore
    let paneID: PaneID
    /// Whether this pane is the active tab's active (focused) pane.
    let isFocused: Bool
    /// Whether this pane is currently ON-SCREEN (its tab is active AND it is not zoom-hidden). Drives the video
    /// activation lifecycle for a video pane (see ``GuiLeafView``). Defaults to `true` so a terminal
    /// caller is unaffected.
    var isVisible: Bool = true
    /// This pane's current laid-out size (from the solver, via ``SplitContainer``). The SINGLE generic resize
    /// signal: whenever it changes — a pane-divider commit, a window-edge / sidebar / inspector resize, a
    /// split add/remove, a zoom, a balance, a tab switch — the content has been resized and its (frozen /
    /// stretched) surface won't match until it re-renders, so the scrim is shown until things settle.
    var size: CGSize = .zero

    /// The resize-scrim reducer (``PaneResizeScrimState``): the geometry settle, the sticky drag hold,
    /// and the mount-is-not-a-resize rule, as a value rather than three `@State` flags. Only the
    /// `.task(id: size)` timer below stays here — a sleep is the framework's; every EDGE it drives is
    /// the reducer's.
    @State private var scrim = PaneResizeScrimState()

    /// The external-drag state for THIS pane: the classified payload of a hovering drag + the
    /// zone under the cursor. Drives ``PaneDropOverlay`` (which zones to show / highlight) and is mutated by
    /// the ``PaneDropReceiver`` `DropDelegate`. Per-pane (the whole pane is `.id(PaneID)`-keyed).
    @State private var dropModel = PaneDropOverlayModel()

    /// The scene-root overlay coordinator: the receiver pushes the host-resolved advisory toast
    /// for a folder → New-Tab `cd` into it, and the terminal leaf below reports a failed host
    /// open/reveal through it. `nil` in tests, where the toast is a no-op.
    ///
    /// A PARAMETER, not `@Environment(\.overlayCoordinator)` (docs/62 stage B) — see
    /// ``TerminalLeafView/overlayCoordinator``.
    var overlayCoordinator: OverlayCoordinator?

    /// The shared chrome model, threaded to the terminal leaf's open-in-code-panel reveal. It used to
    /// ride `.environment(chrome)` from ``ContentColumn``; a `UIViewController` inherits neither
    /// environment, so it takes the same road as ``overlayCoordinator``.
    var workspaceChrome: WorkspaceChromeState?

    /// The pane content model's "resized but not re-rendered yet" signal (terminal host-reflow wait OR
    /// remote-GUI host-re-capture wait), `false` for a pane with no live model. HOLDS the scrim past the
    /// geometry settle so the overlay clears only when the fresh pixels actually land — on a slow link the
    /// geometry timer alone would uncover the stretched / stale frame ~1 RTT too early.
    private var awaitingReflow: Bool { live?.awaitingResizeReflow ?? false }

    /// Whether an interactive divider drag is in progress anywhere (pane or sidebar divider). A fact
    /// about the whole workspace rather than this pane, so the reducer takes it as a parameter.
    private var dragging: Bool { store.isInteractiveResizeActive }

    /// Cover the surface with the resize scrim while a resize is settling — the reducer's answer, so
    /// the three OR-ed signals are stated once and pinned by tests.
    private var showResizeScrim: Bool {
        scrim.isVisible(isDragging: dragging, awaitingReflow: awaitingReflow)
    }

    /// The live session for this pane (terminal model / input bar), if materialized.
    private var live: LivePaneSession? { store.handle(for: paneID) as? LivePaneSession }

    /// How many panes the tab CONTAINING this pane holds (1 = an unsplit tab). Defaults to 1 when the
    /// pane is not in the active session's tabs (teardown race) — the marker then stays hidden.
    private var tabPaneCount: Int {
        store.tree.activeSession?.tabs
            .first { $0.allPaneIDs().contains(paneID) }?
            .allPaneIDs().count ?? 1
    }

    /// This pane's reading of ``PaneFocusPolicy/showsSwitcherRecede(switcherIsOpen:isFocused:)``.
    /// Observing `store.paneSwitcher` here is what repaints the veil on every ⇥ tap; it costs nothing at
    /// rest, where the switcher is nil and the branch is a compare.
    private var recedesForSwitcher: Bool {
        PaneFocusPolicy.showsSwitcherRecede(switcherIsOpen: store.paneSwitcher != nil, isFocused: isFocused)
    }

    private var spec: PaneSpec? { store.tree.activeSession?.specs[paneID] }

    /// The pane's kind drives which leaf view renders. Reads the live handle's kind (falls back to spec).
    private var kind: PaneKind { live?.kind ?? spec?.kind ?? .terminal }

    /// Whether this is a video (PATH 2) pane. `PaneKind.isVideo` is internal to WorkspaceCore, so the
    /// equivalent check is inlined here (the case set matches `PaneKind.isVideo`).
    private var isVideo: Bool { kind == .desktop }

    /// The leaf content, routed by pane kind. A terminal pane renders the `TerminalLeafView` over the
    /// terminal-renderer seam; a video pane renders the `GuiLeafView` over the `VideoWindowFactory` seam
    /// (live surface / in-pane picker / cap-gated placeholder, with the cap-enforced activation lifecycle).
    @ViewBuilder private var paneContent: some View {
        if isVideo {
            GuiLeafView(
                live: live,
                isFocused: isFocused,
                store: store,
                paneID: paneID,
                isVisible: isVisible,
            )
        } else {
            TerminalLeafView(
                live: live,
                isFocused: isFocused,
                // Feeds the bottom status bar. cwd is the host-reported `pane/cwd` read through the
                // mirror (reactive — reading it here re-renders on change); host is the app-global
                // connection target, which is device-local and never rides the shared layout.
                cwd: store.paneCwd(for: paneID),
                host: store.committedConnectionTarget?.host ?? "",
                // The Command Navigator (⌃⌘O) jumps the scrollback through the store.
                store: store,
                overlayCoordinator: overlayCoordinator,
                workspaceChrome: workspaceChrome,
            )
        }
    }

    var body: some View {
        paneContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Slate.Surface.terminal)
            // While this pane is mid-resize, cover its (frozen / stretched) surface with a calm scrim so the
            // moment reads as a deliberate "resizing" state, not a glitchy stretch. Kept in the tree at
            // opacity 0 (cheap) and faded in — never hit-tests, so taps / the divider gesture pass through.
            .overlay {
                PaneResizeScrim()
                    .opacity(showResizeScrim ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(Slate.Anim.reveal, value: showResizeScrim)
            }
            // The external-drag drop-zone overlay. Kept in the tree at opacity 0 (cheap, never
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
            // scrim, then hold it until the size has been steady for `PaneResizeScrimState.settle`.
            // `.task(id:)` cancels + restarts on every change, so a continuous drag keeps the scrim up.
            // This timer is only the START + a floor — once it elapses, `awaitingReflow` (the model's real
            // "fresh pixels landed" signal) keeps the overlay up across the host round-trip and clears it
            // the instant the reflowed / re-captured content actually renders.
            .task(id: size) {
                // A change between two REAL (non-empty) sizes is a resize. A transition from / to `.zero` is
                // just the initial layout settling (or teardown), which must NOT flash the scrim on mount.
                // Both rules live in the reducer; what is left here is the wait.
                guard scrim.noteSize(size, isDragging: dragging) else { return }
                do { try await Task.sleep(for: PaneResizeScrimState.settle) } catch { return }
                scrim.noteSettled()
            }
            // Drag ENDED → drop the sticky drag-hold. The release commit arms `awaitingReflow`, which now
            // carries the scrim across the host round-trip until the reflowed pixels land — so clearing the
            // hold here (both settle in the same runloop turn) leaves no gap for the overlay to flash through.
            .onChange(of: dragging) { _, active in
                if !active { scrim.noteDragEnded() }
            }
            // The terminal is a FLUSH, borderless panel on paper — fills the leaf rect edge-to-edge.
            // No rounded card, no accent ring, no drop shadow, no gutter, and NO per-pane header bar (the
            // active pane's title + split/close controls live in the titlebar `⋯` menu). Adjacent split
            // panes are separated only by the `PaneDivider` hairline `SplitContainer` places between leaves.
            .contentShape(Rectangle())
            .onTapGesture { store.focusPaneTree(paneID) }
            // Accepts external file/folder/URL/text drags. The receiver gates the overlay above and on
            // `performDrop` FOCUSES
            // THIS pane (`paneID`) then actuates against the store (terminal-rooted `cd` ingress),
            // THIS (dropped-on) pane's live terminal (verbatim inject / host-open), and the overlay
            // coordinator (advisory toast) — so a Split / Open-In-Place drop targets the pane under the cursor,
            // not whichever pane was focused. The accepted UTTypes mirror the receiver's classifier precedence.
            .onDrop(of: PaneDropGate.acceptedTypes, delegate: PaneDropReceiver(
                paneID: paneID,
                layout: PaneDropZoneLayout(size: size),
                model: dropModel,
                // (No `enabled:` — increment 57b took it. It was `!staticMirror` until 56d deleted that
                // path, then a literal `true` from this one call site, threaded through
                // ``PaneDropReceiver`` into ``PaneDropGate/acceptsDrag(carriesSupportedType:isReadOnly:)``
                // as a parameter with one reachable value. The AppKit twin would have re-typed the guard.)
                store: store,
                terminalModel: live?.terminalModel,
                overlayCoordinator: overlayCoordinator,
            ))
            // FOCUS = a small FILLED accent triangle tucked into the active pane's TOP-LEFT corner (Warp-style).
            // `Slate.State.accent`, faded in only while focused AND the tab is actually SPLIT (`showsFocusCorner` — a single-pane
            // tab has no sibling to disambiguate, so it stays bare); the unfocused panes render at FULL
            // opacity (no dim — it washed out live content). `allowsHitTesting(false)` so taps / the divider
            // gesture pass through. OUTERMOST overlay → above the resize-scrim + drop-zone overlays.
            .overlay(alignment: .topLeading) {
                PaneFocusCorner(size: Slate.Metric.focusCornerSize)
                    .fill(Slate.State.accent)
                    .opacity(PaneFocusPolicy.showsFocusCorner(isFocused: isFocused, tabPaneCount: tabPaneCount) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // The ⌃⇥ walk's contrast: every pane but the one the walk is on recedes, for the length of the
            // held modifier only. OUTERMOST so it veils the focus corner too — during a walk the corner is
            // the resting answer to a question the switcher is currently asking louder.
            .overlay {
                PaneRecedeScrim()
                    .opacity(recedesForSwitcher ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(Slate.Anim.smallFade, value: recedesForSwitcher)
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
