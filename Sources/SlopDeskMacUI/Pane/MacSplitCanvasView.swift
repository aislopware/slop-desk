// MacSplitCanvasView — the pane canvas, in AppKit: every tab's pane tree, revealing only the active
// one (docs/56 wave R, batch R11, second of three files). The IDENTITY-PRESERVING compositor.
//
// KEEP-ALL-MOUNTED is the invariant the whole file exists to hold. Every tab of every RETAINED session
// stays mounted at `alphaValue = 0`, never torn down, because unmounting an inactive tab's subtree
// kills its libghostty surface — and switching back would then show a soft-reset screen rebuilt from
// the lossy ring replay instead of that pane's CURRENT one. The same rule covers a zoom: a zoomed tab
// still emits every sibling as a hidden compositor leaf at its un-zoomed rect, so un-zoom is a pure
// visibility flip.
//
// IT PLACES BY FRAME, and that is not a shortcut. `SplitTreeRenderModel.layout(for:in:)` — the same
// pure solver the FocusResolver reads — turns the tab's `SplitNode` tree into ABSOLUTE leaf and
// divider rects, so there is nothing left for Auto Layout to solve: a constraint pair rewritten sixty
// times a second during a divider drag would be the same placement bought through the engine. Branch
// nodes are never walked into nested stack views. This is what honours the repo guardrail "drive
// geometry in one structure, never tree-relocate a pane on a mode change" — a zoom, a split
// add/remove and a resize all just re-emit rects, and every pane view keeps its identity.
//
// TWO PROMISES SWIFTUI MADE IN ONE MODIFIER. `.allowsHitTesting(isActive)` suppressed a composed
// subtree whole; AppKit's `hitTest → nil` does not touch an `NSTrackingArea`, which is rect-based and
// keeps firing under a hidden tab. So a hidden layer states BOTH: `hitTest` refuses the pointer, and
// every part that owns a tracking area is told it is non-interactive (`MacPaneMoveHandle.isInteractive`,
// and the leaves' own occlusion sweep). That asymmetry is docs/56 risk 3, and it reaches this file too.
//
// NO DRAG DECISIONS, NO PLATFORM GATE, NO DROP-TARGET READER. Where the cursor would land, whether the
// source is still in the active tab, what a release commits, and the two geometry reports are
// ``PaneCanvasDragController``'s in `SlopDeskClientCore` — this canvas CALLS them rather than
// translating them, `commitDestination`'s load-bearing tear-off order included. The screen rect the
// tear-off resolves against is registered by ``MacContentColumn``, whose hosting view IS this canvas.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The canvas

@MainActor
final class MacSplitCanvasView: NSView {
    /// The canvas cluster's whole injection list — the store, the cross-container drag rendezvous, the
    /// overlay summoner and the chrome state — in one value. See ``PaneCanvasDeps``.
    private let deps: PaneCanvasDeps

    /// The live pane-move drag and every decision it turns on. Built once with the store and the
    /// coordinator, both of which are app-lifetime and which this view holds for exactly as long.
    private let drag: PaneCanvasDragController

    private var layers: [TabID: MacTabLayer] = [:]
    /// The live follow. Stored so ``teardown()`` can END it while this view lives on, and armed with
    /// `replacing:` because a teardown clears `isWired` — a re-attach re-enters ``follow()``.
    private var canvasFollow: ObservationFollow?
    private var isWired = false

    init(deps: PaneCanvasDeps) {
        self.deps = deps
        drag = PaneCanvasDragController(store: deps.store, coordinator: deps.paneDrag)
        super.init(frame: .zero)
        wantsLayer = true
        paint()
        attach()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// TOP-LEFT ORIGIN, the space the solver's rects are already in. Everything under this view — the
    /// tab layers, the drop receiver, the move handle and the move overlay — is flipped for the same
    /// reason, so no rect is ever converted between two conventions on the way down.
    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { paint() }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attach() }
    }

    private func attach() {
        guard !isWired else { return }
        isWired = true
        follow()
    }

    // MARK: - The live read

    /// ONE tracked read of the tab set. Everything a LAYER draws on is that layer's own tracked read —
    /// this one only answers which tabs are mounted and which is revealed, so a keystroke inside one
    /// pane does not re-run the whole canvas's reconcile.
    private func follow() {
        canvasFollow = ObservationFollow.arm(self, replacing: canvasFollow) { canvas in
            (
                // EVERY tab of every RETAINED session (the active one plus the LRU-retained previous
                // ones), in session-then-tab-bar order. Rendering all of them is what makes an A→B→A
                // session switch a visibility flip rather than a teardown of every outgoing surface.
                tabs: PaneCanvasMounting.mountedTabs(
                    sessions: canvas.deps.store.tree.sessions,
                    retained: canvas.deps.store.retainedSessionIDs,
                    activeID: canvas.deps.store.tree.activeSessionID,
                ),
                activeTabID: canvas.deps.store.tree.activeSession?.activeTab?.id,
            )
        } apply: { canvas, reading in
            canvas.reconcile(tabs: reading.tabs, activeTabID: reading.activeTabID)
        }
    }

    private func reconcile(tabs: [SlopDeskWorkspaceModel.Tab], activeTabID: TabID?) {
        // A tab that left the mounted set is genuinely GONE — closed, or evicted from the retention
        // window. This is the one place a pane's renderer may come down, and it must, or the sockets
        // and threads behind it outlive every reference to them. Teardown BEFORE detach, always.
        PaneCanvasMounting.drop(from: &layers, keeping: Set(tabs.map(\.id))) { layer in
            layer.teardown()
            layer.removeFromSuperview()
        }
        for tab in tabs {
            let layer = layers[tab.id] ?? {
                let made = MacTabLayer(deps: deps, drag: drag)
                made.translatesAutoresizingMaskIntoConstraints = true
                addSubview(made)
                layers[tab.id] = made
                return made
            }()
            layer.frame = bounds
            layer.apply(tab: tab, isActive: tab.id == activeTabID, in: bounds)
        }
    }

    override func layout() {
        super.layout()
        let rect = CGRect(origin: .zero, size: bounds.size)
        // The container bounds are the geometric ops' fallback before the first SOLVED-layout report.
        // Reported once at this level, never per tab — and reported UNCONDITIONALLY, because the
        // controller now drops a rect it has already pushed (``PaneCanvasDragController``).
        drag.reportContainerBounds(rect)
        for layer in layers.values {
            layer.frame = rect
            layer.relayout(in: rect)
        }
    }

    /// The whole canvas is closing. Forwarded so every leaf's renderer comes down — see the reconcile
    /// above for why this is not something a mere unmount may do.
    func teardown() {
        canvasFollow?.stop()
        canvasFollow = nil
        isWired = false
        for layer in layers.values {
            layer.teardown()
            layer.removeFromSuperview()
        }
        layers = [:]
    }
}

// MARK: - One tab

/// One tab's pane tree, placed absolutely. Rendered for EVERY mounted tab; all but the active one are
/// transparent and non-interactive.
///
/// Interaction chrome (dividers, grab handles, the drop preview) is drawn only for the active tab,
/// with ONE exception that is load-bearing: the move layer of the tab OWNING a live drag stays
/// mounted even after a spring-loaded reveal switches tabs, because unmounting it would destroy the
/// grab handle whose gesture is still tracking the mouse.
@MainActor
private final class MacTabLayer: NSView {
    private let deps: PaneCanvasDeps
    private let drag: PaneCanvasDragController

    private var panes: [PaneID: MacPaneContainer] = [:]
    private var dividers: [SplitTreeRenderModel.DividerHandle.Key: MacPaneDivider] = [:]
    private var handles: [PaneID: MacPaneMoveHandle] = [:]
    /// Whether a leaf's content is UNTHEMED — a video pane, which needs the pill's contrast plate.
    ///
    /// ⚠️ MEMOIZED, and the reason is asymptotic rather than tidy. It was
    /// `store.tree.spec(for: leaf.id)?.kind == .desktop` inside ``applyHandles(_:)``'s leaf loop, and
    /// `TreeWorkspace.spec(for:)` is a full DFS — every session, every tab, every split node — so the
    /// loop was O(panes × workspace) on a path that runs per frame of a divider drag, per frame of a
    /// live window resize, and per pointer move of a pane drag (``dragChanged(_:at:)``). A pane's KIND
    /// is fixed for the life of its id, so the answer is asked once per leaf and pruned with its
    /// handle.
    private var handleIsUnthemed: [PaneID: Bool] = [:]
    private let moveOverlay = MacPaneMoveOverlay()
    private var externalPreview: NSView?

    /// The last solved layout, kept so ``relayout(in:)`` can re-place without the store being asked
    /// again — a window resize is geometry, not a model change.
    private var tab: SlopDeskWorkspaceModel.Tab?
    private var isActive = false
    private var leaves: [SplitTreeRenderModel.PlacedLeaf] = []
    private var frames: [PaneID: CGRect] = [:]
    private var container: CGRect = .zero
    /// The live follow. Stored because ``apply(tab:isActive:in:)`` re-enters ``follow()`` on every
    /// reconcile of this layer, and ``teardown()`` must end it while the layer lives on.
    private var layerFollow: ObservationFollow?

    init(deps: PaneCanvasDeps, drag: PaneCanvasDragController) {
        self.deps = deps
        self.drag = drag
        super.init(frame: .zero)
        moveOverlay.translatesAutoresizingMaskIntoConstraints = true
        addSubview(moveOverlay)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    /// The first of a hidden tab's two promises. The second — telling every tracking-area owner it is
    /// non-interactive — is made in ``applyHandles(_:)`` and by the leaves' own occlusion sweep,
    /// because `hitTest` alone does not reach an `NSTrackingArea`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive ? super.hitTest(point) : nil
    }

    // MARK: The reconcile

    func apply(tab: SlopDeskWorkspaceModel.Tab, isActive: Bool, in bounds: CGRect) {
        self.tab = tab
        self.isActive = isActive
        alphaValue = isActive ? 1 : 0
        setAccessibilityHidden(!isActive)
        // `container` first, then the arm: ``ObservationFollow/arm(_:replacing:read:apply:)`` runs its
        // first apply SYNCHRONOUSLY, and that apply is the relayout — so this method no longer places
        // the layer itself and then follows, it places it BY following.
        container = bounds
        follow()
    }

    /// Re-solve and re-place for a new container rect. Split from ``apply(tab:isActive:in:)`` because a
    /// window resize must not re-run the model reads — the tree did not change, the rectangle did.
    func relayout(in bounds: CGRect) {
        guard let tab else { return }
        container = bounds
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
        leaves = layout.leaves
        frames = Dictionary(layout.leaves.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        moveOverlay.frame = bounds

        applyPanes(PaneCanvasMounting.place(
            layout.compositorLeaves, tab: tab, store: deps.store, tabIsActive: isActive,
        ))
        applyDividers(layout.dividers)
        applyHandles(layout.leaves)
        applyMoveOverlay()
        applyExternalPreview()

        // The ACTIVE tab's solved rects, to the store. Without this `lastSolvedLayout` stays forever
        // nil and the ⌃⌘arrow / ⌥⌘⇧arrow chords resolve against the nominal fallback instead of the
        // real geometry. Hidden tabs are skipped — only the visible geometry counts.
        drag.reportSolvedLayout(frames, isActive: isActive)
    }

    /// A pane leaving the mounted set: its renderer comes down FIRST, then the view detaches. The one
    /// place a pane's libghostty surface / video session may be destroyed.
    private func unmount(_ pane: MacPaneContainer) {
        pane.teardown()
        pane.removeFromSuperview()
    }

    /// EVERY pane — visible AND zoom-hidden — from one list, so the hidden↔visible flip never
    /// reconstructs a surface across the boundary.
    ///
    /// The three flags each pane is told about itself (focused, visible, zoom-hidden) are resolved by
    /// ``PaneCanvasMounting/place(_:tab:store:tabIsActive:)``, which is where the focus rule and the
    /// code sidebar's keyboard claim meet. What is left here is the mounting.
    private func applyPanes(_ spots: [PaneCanvasMounting.PanePlacement]) {
        PaneCanvasMounting.drop(from: &panes, keeping: Set(spots.map(\.id)), teardown: unmount)
        for spot in spots {
            let pane = panes[spot.id] ?? {
                let made = MacPaneContainer(
                    deps: deps, paneID: spot.id, isFocused: spot.isFocused, isVisible: spot.isVisible,
                )
                made.translatesAutoresizingMaskIntoConstraints = true
                // UNDER the move overlay, which is the top of this layer's z-band.
                addSubview(made, positioned: .below, relativeTo: moveOverlay)
                panes[spot.id] = made
                return made
            }()
            pane.frame = spot.rect
            pane.setFocused(spot.isFocused)
            pane.setVisible(spot.isVisible)
            // ALPHA, NEVER `isHidden`: a layer-hosting leaf sizes its surface and picks its
            // `contentsScale` in `layout()`, which does not run on a hidden subtree — un-hiding after
            // a display change would present stale geometry.
            pane.alphaValue = spot.isHidden ? 0 : 1
            pane.setAccessibilityHidden(spot.isHidden)
        }
    }

    /// The dividers, drawn only for the active tab — a hidden tab is non-interactive, so it needs none.
    private func applyDividers(_ handles: [SplitTreeRenderModel.DividerHandle]) {
        let wanted = isActive ? handles : []
        PaneCanvasMounting.drop(from: &dividers, keeping: Set(wanted.map(\.key))) { divider in
            divider.removeFromSuperview()
        }
        for handle in wanted {
            let divider = dividers[handle.key] ?? {
                // What each gesture MEANS is ``PaneDividerActions``' — the live-weight write, the
                // suspend/commit pair on release and the single-seam even on a double-click. What is
                // here is only which gesture the seam reports.
                let made = MacPaneDivider(handle: handle, actions: DecorationDividerActions(
                    onResizeBegin: { [store = deps.store] in PaneDividerActions.begin(store) },
                    onResizeChange: { [store = deps.store] leadingWeight in
                        PaneDividerActions.change(store, handle, leadingWeight)
                    },
                    onResizeEnd: { [store = deps.store] in PaneDividerActions.end(store) },
                    onReset: { [store = deps.store] in PaneDividerActions.reset(store, handle) },
                ))
                addSubview(made, positioned: .below, relativeTo: moveOverlay)
                dividers[handle.key] = made
                return made
            }()
            // The handle is re-pointed rather than rebuilt: it is re-solved on every frame of a live
            // drag, and rebuilding would tear the view out from under the gesture tracking it.
            divider.handle = handle
            divider.frame = handle.rect
        }
    }

    /// The grab handles. With a coordinator wired even a SOLE leaf gets one — a lone pane has no
    /// in-tab target, but it can still leave: onto a sidebar row, the New-Tab slot, or out of the
    /// window entirely.
    private func applyHandles(_ leaves: [SplitTreeRenderModel.PlacedLeaf]) {
        // The exception in the type's header: the move layer of the tab OWNING a live drag stays
        // mounted through a spring-loaded tab switch.
        let mounted = isActive || drag.moveSourceIsIn(frames)
        let wanted = mounted && (leaves.count > 1 || deps.paneDrag != nil) ? leaves : []
        let ids = Set(wanted.map(\.id))
        for (id, handle) in handles where !ids.contains(id) {
            // A leaf torn out mid-drag can never fire its own release, so the safety net is spent
            // HERE. No commit — a cancel commits nothing — but the drag state and the cross-window
            // coordinator must both clear, or every other handle stays wedged non-interactive forever.
            if drag.move?.source == id { drag.interrupted() }
            handle.removeFromSuperview()
            handles[id] = nil
            handleIsUnthemed[id] = nil
        }
        for leaf in wanted {
            let handle = handles[leaf.id] ?? {
                let made = MacPaneMoveHandle(
                    paneID: leaf.id,
                    // Every arm is the controller's: this layer supplies the cursor point and the
                    // frame it was measured in, and nothing else.
                    onChanged: { [weak self] id, point in self?.dragChanged(id, at: point) },
                    onEnded: { [weak self] id, point in self?.dragEnded(id, at: point) },
                    onTap: { [store = deps.store] id in store.focusPaneTree(id) },
                    onInterrupted: { [drag] _ in drag.interrupted() },
                )
                made.translatesAutoresizingMaskIntoConstraints = true
                addSubview(made, positioned: .below, relativeTo: moveOverlay)
                handles[leaf.id] = made
                return made
            }()
            handle.frame = leaf.rect
            // A video leaf streams arbitrary — usually light — content, where the bare tertiary pill
            // disappears, so it gains a contrast plate. Read through the memo — see
            // ``handleIsUnthemed`` for why the tree walk may not be in this loop.
            let unthemed = handleIsUnthemed[leaf.id] ?? {
                let answer = deps.store.tree.spec(for: leaf.id)?.kind == .desktop
                handleIsUnthemed[leaf.id] = answer
                return answer
            }()
            handle.contentIsUnthemed = unthemed
            // During a drag only the SOURCE handle stays live: it owns the gesture, and the others'
            // top strips would otherwise shadow the drop target. This is also the second of a hidden
            // tab's two promises — it takes the tracking area down, which `hitTest` cannot.
            handle.isInteractive = isActive && (drag.move == nil || drag.move?.source == leaf.id)
        }
    }

    private func dragChanged(_ id: PaneID, at point: CGPoint) {
        guard let leaf = leaves.first(where: { $0.id == id }) else { return }
        drag.changed(leaf: leaf, among: leaves, container: container, at: point)
        applyMoveOverlay()
        applyHandles(leaves)
    }

    private func dragEnded(_ id: PaneID, at point: CGPoint) {
        guard let leaf = leaves.first(where: { $0.id == id }) else { return }
        drag.ended(leaf: leaf, among: leaves, container: container, at: point)
        applyMoveOverlay()
    }

    private func applyMoveOverlay() {
        if let move = drag.move {
            moveOverlay.isHidden = false
            moveOverlay.show(
                drag: move, frames: frames, container: container,
                sourceTitle: deps.store.tree.activeSession?.specs[move.source]?.title,
            )
        } else {
            moveOverlay.clear()
            moveOverlay.isHidden = true
        }
    }

    /// The landing preview for a drag whose SOURCE is not in this tab — a satellite window's grab
    /// strip, or a tree pane whose own tab was spring-loaded away mid-drag. Same zone vocabulary as
    /// the in-canvas overlay, driven by the coordinator's published destination, so it re-draws on a
    /// destination transition and never per cursor frame.
    private func applyExternalPreview() {
        externalPreview?.removeFromSuperview()
        externalPreview = nil
        guard isActive, let paneDrag = deps.paneDrag, let published = paneDrag.drag,
              frames[published.source] == nil
        else { return }
        let zone = PaneCanvasMetrics.canvasZone(of: published.destination)
        guard let preview = MacPaneMovePreview.view(
            for: zone, frames: frames, container: container,
        ) else { return }
        preview.translatesAutoresizingMaskIntoConstraints = true
        addSubview(preview, positioned: .below, relativeTo: moveOverlay)
        externalPreview = preview
    }

    // MARK: The live read

    /// What this LAYER draws on, apart from geometry: the drag the coordinator publishes, and the
    /// keyboard-ownership flag both focus arms read.
    private func follow() {
        layerFollow = ObservationFollow.arm(self, replacing: layerFollow) { layer in
            _ = layer.drag.move
            _ = layer.deps.paneDrag?.drag
            _ = CodeSidebarKeyboardState.shared.ownsKeyboard
        } apply: { layer, _ in
            layer.relayout(in: layer.container)
        }
    }

    func teardown() {
        layerFollow?.stop()
        layerFollow = nil
        for pane in panes.values {
            pane.teardown()
            pane.removeFromSuperview()
        }
        panes = [:]
    }
}
