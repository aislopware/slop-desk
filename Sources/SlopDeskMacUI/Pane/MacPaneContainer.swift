// MacPaneContainer — one placed leaf, in AppKit: the flush, borderless pane content and the four
// things drawn over it (docs/56 wave R, batch R11, first of three files).
//
// It resolves the pane's live handle and spec from the store, routes by KIND to a leaf
// (``MacTerminalLeafView`` / ``MacGuiLeafView``), and carries the resize scrim, the drop overlay, the
// focus corner and the ⌃⇥ recede veil. Every decision is somewhere else already:
// `PaneResizeScrimState` is the scrim's three OR-ed signals as a value, `PaneFocusPolicy` answers both
// focus marks, `PaneDropGate`/`PaneDropActuator` own the drop, and `CodeSidebarKeyboardState` decides
// whether a workspace-focused pane RENDERS focused. What crossed is the drawing.
//
// FLUSH AND BORDERLESS. No card, no accent ring, no shadow, no gutter, and no per-pane header bar —
// adjacent split panes are separated only by the hairline ``MacSplitCanvasView`` places between them.
// At rest, focus is a MARK ADDED to the subject (the corner triangle), never a dimming of its
// siblings: that was tried and removed for washing out live content. The one exception is the ⌃⇥ walk,
// where the question changes on every tap and the answer must be findable in 200 ms — and it lasts
// exactly as long as the held modifier.
//
// THE SIZE SIGNAL IS `layout()`, NOT A PARAMETER. SwiftUI was handed the solver's rect and keyed a
// `.task(id: size)` on it; here the laid-out bounds ARE the signal, which is strictly closer to the
// truth — every source the SwiftUI comment lists (a divider commit, a window/sidebar/inspector
// resize, a split add/remove, a zoom, a balance, a tab switch) reaches this view as a `layout()` pass
// whether or not anything upstream remembered to thread a new value down.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The container

@MainActor
final class MacPaneContainer: NSView {
    /// The pane cluster's whole injection list, in one value — see ``PaneCanvasDeps``.
    private let deps: PaneCanvasDeps
    let paneID: PaneID

    private var isFocused: Bool
    /// Whether this pane is ON-SCREEN — its tab is active AND it is not zoom-hidden. Only the video
    /// leaf reads it, and it is what drives the `liveVideoCap` activation lifecycle.
    private var isVisible: Bool

    // MARK: The tree

    /// The drop wrapper IS the content's parent: it mounts the leaf under its own overlay, so the
    /// receiver's bounds are the pane's rect exactly — which is what the zone layout is built from and
    /// what the hover hit-tests against.
    private let receiver: MacPaneDropReceiver
    private let dropModel = PaneDropOverlayModel()
    private let resizeVeil = MacPaneVeil.resize()
    private let recedeVeil = MacPaneVeil.recede()
    private let focusCorner = MacPaneFocusCorner()

    /// The leaf, and the kind it was built for. A pane never changes kind in practice, but the routing
    /// is by DATA, so the rebuild path exists rather than being assumed away.
    private var leaf: NSView?
    private var leafKind: PaneKind?

    // MARK: The live reads

    /// The resize veil's reducer PLUS its settle wait — see ``PaneResizeScrimDriver``. `lazy` because
    /// it needs the store and the pane id, which are only known once `self` is initialised.
    private lazy var scrim = PaneResizeScrimDriver(store: deps.store, paneID: paneID)
    /// The live follow. Stored for BOTH reasons the handle exists: ``follow()`` is re-entered on every
    /// focus push, so each arm must displace the last, and ``detach()`` ends the following while this
    /// container lives on waiting to be re-attached.
    private var paneFollow: ObservationFollow?
    /// Idempotent attach/detach edges — see ``PaneMountGate``.
    private var mount = PaneMountGate()

    // MARK: - Life

    init(deps: PaneCanvasDeps, paneID: PaneID, isFocused: Bool, isVisible: Bool) {
        self.deps = deps
        self.paneID = paneID
        self.isFocused = isFocused
        self.isVisible = isVisible
        receiver = MacPaneDropReceiver(paneID: paneID, model: dropModel, deps: deps)
        super.init(frame: .zero)
        build()
        // No separate mount: ``attach()`` runs ``follow()``, and the leaf is mounted from INSIDE that
        // arm now — so the one construction site is also the one that re-runs when the pane's session
        // materialises. A second mount here would build the leaf against a handle read outside the arm.
        attach()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        paint()

        // Z-ORDER, and it is the SwiftUI half's exactly: content, resize scrim, drop zones (inside the
        // receiver), then the focus corner, then the recede veil OUTERMOST — during a walk the corner
        // is the resting answer to a question the switcher is currently asking louder, so the veil
        // covers it too.
        for overlay in [receiver, resizeVeil, focusCorner, recedeVeil] as [NSView] {
            addSubview(overlay)
            NSLayoutConstraint.activate(overlay.slateEdges(of: self))
        }
        // Both veils and the corner ride alpha, never `isHidden`: a layer-hosting leaf sizes its
        // surface in `layout()`, which does not run on a hidden subtree, so an un-hide after a scale
        // change would present stale geometry (docs/56 risk 3's sibling finding).
        resizeVeil.alphaValue = 0
        recedeVeil.alphaValue = 0
        focusCorner.alphaValue = 0
    }

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
        if window != nil { attach() } else if superview == nil { detach() }
    }

    private func attach() {
        guard mount.attach() else { return }
        follow()
    }

    private func detach() {
        guard mount.detach() else { return }
        paneFollow?.stop()
        paneFollow = nil
        scrim.cancel()
    }

    /// The pane is closed for good. Forwarded to the leaf, which owns the renderer that a mere unmount
    /// must NOT take down (see either leaf's `viewDidMoveToWindow`).
    func teardown() {
        detach()
        (leaf as? MacTerminalLeafView)?.teardown()
        (leaf as? MacGuiLeafView)?.teardown()
    }

    // MARK: - What the canvas pushes

    func setFocused(_ isFocused: Bool) {
        guard isFocused != self.isFocused else { return }
        self.isFocused = isFocused
        (leaf as? MacTerminalLeafView)?.setFocused(isFocused)
        (leaf as? MacGuiLeafView)?.setFocused(isFocused)
        if mount.isArmed { follow() }
    }

    func setVisible(_ isVisible: Bool) {
        guard isVisible != self.isVisible else { return }
        self.isVisible = isVisible
        (leaf as? MacGuiLeafView)?.setVisible(isVisible)
    }

    // MARK: - The resize signal

    /// THE SINGLE GENERIC RESIZE SIGNAL. Whatever moved this pane — a divider commit, a window edge,
    /// the sidebar, a zoom, a tab switch — the content has been resized and its frozen or stretched
    /// surface will not match until it re-renders, so the scrim goes up until things settle.
    ///
    /// A change between two REAL sizes is a resize; a transition from or to `.zero` is the initial
    /// layout settling (or teardown) and must NOT flash the scrim on mount. Both rules are the
    /// reducer's — what is left here is the wait.
    override func layout() {
        super.layout()
        scrim.noteLayout(bounds.size) { [weak self] in self?.applyScrim() }
    }

    /// The scrim's answer, from the reducer, so the three OR-ed signals are stated once.
    ///
    /// `awaitingReflow` is what HOLDS the veil past the geometry settle: on a slow link the timer
    /// alone would uncover the stretched frame about one RTT too early.
    private func applyScrim() {
        MacPaneFade.set(resizeVeil, shown: scrim.isVeilShown())
    }

    // MARK: - The leaf

    /// Routed by KIND: a terminal pane over the terminal-renderer seam, a `.desktop` pane over the
    /// `VideoWindowFactory` seam with its cap-enforced activation lifecycle.
    private func mountLeaf(live: LivePaneSession?, kind: PaneKind) {
        if kind == leafKind, let leaf {
            (leaf as? MacTerminalLeafView)?.setLive(live)
            (leaf as? MacGuiLeafView)?.setLive(live)
            return
        }
        (leaf as? MacTerminalLeafView)?.teardown()
        (leaf as? MacGuiLeafView)?.teardown()
        leaf?.removeFromSuperview()
        leafKind = kind

        // `.desktop` is the whole video set today; the check matches `PaneKind.isVideo`, which is
        // internal to WorkspaceCore and so cannot be named from here.
        let built: NSView = kind == .desktop
            ? MacGuiLeafView(
                live: live, isFocused: isFocused, isVisible: isVisible, store: deps.store, paneID: paneID,
            )
            : MacTerminalLeafView(TerminalLeafDependencies(
                live: live,
                isFocused: isFocused,
                // The host-reported cwd feeds the leaf's bottom status bar. The host is the app-global
                // connection target: device-local, and it never rides the shared layout.
                cwd: deps.store.paneCwd(for: paneID),
                store: deps.store,
                overlay: deps.overlay,
                chrome: deps.chrome,
            ))
        leaf = built
        receiver.mount(built)
    }

    // MARK: - The live read

    /// ONE tracked read of everything this container draws on. Same rule as either leaf: one arm, not
    /// one per concern — and `replacing:` because a focus push re-enters this method, where a plain
    /// arm would leave the previous chain live and applying alongside the new one.
    private func follow() {
        paneFollow = ObservationFollow.arm(self, replacing: paneFollow) { pane in
            // THE PANE'S SESSION, READ INSIDE `read`. The registry it comes out of is `@Observable`
            // state on the store, so reading it here is what makes a session MINTED OR SWAPPED under
            // a stable pane id reach the leaf. Read in `apply` it registers no dependency: the leaf
            // then keeps whatever handle happened to be current at mount, and on the ordinary launch
            // — where `reconcileTree()` has already run — nothing ever says otherwise, so the miss is
            // silent. Same reason the drop receiver takes a CLOSURE rather than a value (see `init`).
            let live = pane.deps.store.handle(for: pane.paneID) as? LivePaneSession
            // Registers the resize veil's third signal. `applyScrim()` re-reads it — this read is what
            // makes a change to it INVALIDATE, which nothing else in this view was doing.
            _ = live?.awaitingResizeReflow
            return (
                live: live,
                // Routed by KIND, and the fallback reads the spec, so a `.desktop` pane that arrives
                // with the document rebuilds into the video leaf instead of staying a terminal.
                kind: live?.kind
                    ?? pane.deps.store.tree.activeSession?.specs[pane.paneID]?.kind ?? .terminal,
                // A hidden tab's pane is not the subject of anything, so both marks read from the SAME
                // `isFocused` this container was pushed rather than from the store — the canvas already
                // resolved the zoom-hidden and sidebar-owns-keyboard arms before pushing it.
                showsCorner: PaneFocusPolicy.showsFocusCorner(
                    isFocused: pane.isFocused, tabPaneCount: pane.tabPaneCount,
                ),
                // Observing the switcher HERE is what repaints the veil on every ⇥ tap. It costs
                // nothing at rest, where the switcher is nil and the branch is a compare.
                recedes: PaneFocusPolicy.showsSwitcherRecede(
                    switcherIsOpen: pane.deps.store.paneSwitcher != nil, isFocused: pane.isFocused,
                ),
                cwd: pane.deps.store.paneCwd(for: pane.paneID),
            )
        } apply: { pane, reading in
            pane.mountLeaf(live: reading.live, kind: reading.kind)
            (pane.leaf as? MacTerminalLeafView)?.setCwd(reading.cwd)
            MacPaneFade.set(pane.focusCorner, shown: reading.showsCorner)
            MacPaneFade.set(pane.recedeVeil, shown: reading.recedes, curve: Slate.Motion.smallFade)
            pane.applyScrim()
        }
    }

    /// How many panes the tab CONTAINING this pane holds — 1 for an unsplit tab, where the corner
    /// stays bare because there is no sibling to disambiguate from. Defaults to 1 when the pane is not
    /// in the active session's tabs (a teardown race), which hides the mark rather than guessing.
    ///
    /// ⚠️ The owning tab is found with ``Tab/contains(_:)`` rather than
    /// `allPaneIDs().contains(_:)`. Both walk the same split tree, but the second ALLOCATES that
    /// tab's whole id list to throw it away — once per tab, before the match, and then again on the
    /// tab that matched. This read sits inside ``follow()``'s tracking arm, which observes
    /// `store.paneSwitcher`, so every mounted container re-ran it on every ⌃⇥ tap: T+1 arrays per
    /// pane per keypress across the canvas.
    private var tabPaneCount: Int {
        deps.store.tree.activeSession?.tabs
            .first { $0.contains(paneID) }?
            .allPaneIDs().count ?? 1
    }

    // MARK: - The click

    /// Tap anywhere focuses the pane. `mouseDown` rather than a click-through override: the leaf and
    /// its renderer are in front, so a click that lands on remote pixels reaches THEM first and this
    /// only ever sees a click on the container's own bare area.
    override func mouseDown(with event: NSEvent) {
        deps.store.focusPaneTree(paneID)
        super.mouseDown(with: event)
    }
}

// MARK: - The focus mark

/// The active-pane focus marker: a small FILLED right-triangle in the pane's top-left corner
/// (Warp-style) — the two legs run along the top and left edges, the hypotenuse cuts across.
///
/// Auto-capped at the smaller pane side, so a pane too small for the full leg keeps a proportional
/// mark instead of losing it or overflowing.
@MainActor
final class MacPaneFocusCorner: NSView {
    /// Leg length in points. The cap below is why this is not simply the layer's size.
    private let leg = Slate.Metric.focusCornerSize
    private let triangle = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(triangle)
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The mark is a statement, never a target — a click, and the divider gesture, pass through it.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    /// TOP-LEFT in the SCREEN's sense, which in AppKit's y-up default space is `maxY` — the one place
    /// in this file where the port is not a transcription. A `minY` triangle would be a correct
    /// reading of the SwiftUI source and the wrong corner on this platform.
    override func layout() {
        super.layout()
        let side = Swift.min(leg, Swift.min(bounds.width, bounds.height))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + side, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY - side))
        path.closeSubpath()
        triangle.frame = bounds
        triangle.path = path
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            triangle.fillColor = Slate.Native.accent.cgColor
        }
    }
}

// MARK: - The reveal

/// The container's four overlays arrive and leave by fading, and by nothing else.
///
/// `isHidden` is deliberately NOT used, unlike the chip columns' reveal: a layer-hosting leaf sizes
/// its surface and picks its `contentsScale` in `layout()`, which does not run on a hidden subtree, so
/// hiding one of these could leave a sibling presenting stale geometry after a display change. Every
/// one of them already refuses the pointer on its own, so alpha alone is safe here in a way it is not
/// for a control.
@MainActor
private enum MacPaneFade {
    static func set(_ view: NSView, shown: Bool, curve: SlateCurve = Slate.Motion.reveal) {
        let wanted: CGFloat = shown ? 1 : 0
        guard view.alphaValue != wanted else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            context.timingFunction = curve.timingFunction
            view.animator().alphaValue = wanted
        }
    }
}
