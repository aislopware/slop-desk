// PaneContainerView — one placed leaf, in UIKit: the flush, borderless pane content and the four
// things drawn over it (docs/62 stage E.0).
//
// It resolves the pane's live handle and spec from the store, routes by KIND to a leaf
// (``TerminalLeafView`` / ``GuiLeafView``), and carries the resize veil, the drop overlay, the focus
// corner and the switcher recede veil. Every decision is somewhere else already:
// `PaneResizeScrimState` is the veil's three OR-ed signals as a value, `PaneFocusPolicy` answers both
// focus marks, `PaneDropGate`/`PaneDropActuator` own the drop, and `CodeSidebarKeyboardState` decides
// whether a workspace-focused pane RENDERS focused. What crossed is the drawing.
//
// FLUSH AND BORDERLESS. No card, no accent ring, no shadow, no gutter, and no per-pane header bar —
// adjacent split panes are separated only by the hairline ``SplitCanvasView`` places between them. At
// rest, focus is a MARK ADDED to the subject (the corner triangle), never a dimming of its siblings:
// that was tried and removed for washing out live content. The one exception is the pane-switcher
// walk, where the question changes on every step and the answer must be findable in 200 ms.
//
// THE SIZE SIGNAL IS `layoutSubviews`, NOT A PARAMETER. SwiftUI was handed the solver's rect and keyed
// a `.task(id: size)` on it; here the laid-out bounds ARE the signal, which is strictly closer to the
// truth — every source the deleted comment lists (a divider commit, a rotation, a keyboard raise, a
// split add/remove, a zoom, a balance, a tab switch) reaches this view as a layout pass whether or not
// anything upstream remembered to thread a new value down.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

@MainActor
final class PaneContainerView: UIView {
    private let store: WorkspaceStore
    let paneID: PaneID
    private let overlayCoordinator: OverlayCoordinator?
    private let chrome: WorkspaceChromeState?

    private var isFocused: Bool
    /// Whether this pane is ON-SCREEN — its tab is active AND it is not zoom-hidden. The video leaf
    /// reads it as its activation lifecycle; the terminal leaf reads its inverse as occlusion.
    private var isVisible: Bool

    // MARK: The tree

    /// The drop wrapper IS the content's parent: it mounts the leaf under its own overlay, so the
    /// receiver's bounds are the pane's rect exactly — which is what the zone layout is built from and
    /// what the hover hit-tests against.
    private let receiver: PaneDropReceiverView
    private let dropModel = PaneDropOverlayModel()
    private let resizeVeil = PaneVeilView.resize()
    private let recedeVeil = PaneVeilView.recede()
    private let focusCorner = PaneFocusCornerView()

    /// The leaf, and the kind it was built for. A pane never changes kind in practice, but the routing
    /// is by DATA, so the rebuild path exists rather than being assumed away.
    private var leaf: UIView?
    private var leafKind: PaneKind?

    // MARK: The live reads

    private var scrim = PaneResizeScrimState()
    private var settleTask: Task<Void, Never>?
    private var lastSize: CGSize = .zero
    private var generation = 0
    private var isWired = false

    // MARK: - Life

    init(
        store: WorkspaceStore,
        paneID: PaneID,
        isFocused: Bool,
        isVisible: Bool,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
    ) {
        self.store = store
        self.paneID = paneID
        self.isFocused = isFocused
        self.isVisible = isVisible
        overlayCoordinator = overlay
        self.chrome = chrome
        // The terminal model is a CLOSURE, not a value: it is resolved fresh at every drop, because a
        // pane that materialised its session after this container was built would otherwise actuate
        // against a `nil` captured at mount.
        receiver = PaneDropReceiverView(
            paneID: paneID,
            model: dropModel,
            store: store,
            terminalModel: { (store.handle(for: paneID) as? LivePaneSession)?.terminalModel },
            overlayCoordinator: overlay,
        )
        super.init(frame: .zero)
        build()
        // No separate mount: ``attach()`` runs ``follow()``, and the leaf is mounted from INSIDE that
        // arm — so the one construction site is also the one that re-runs when the pane's session
        // materialises. A second mount here would build the leaf against a handle read outside the arm.
        attach()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // A dynamic `UIColor` on the VIEW re-resolves itself on a theme flip; only a `CGColor` hung on
        // a layer is flat. `MacPaneContainer` spends `updateLayer` + an appearance override on exactly
        // this, and none of it survives the crossing.
        backgroundColor = Slate.Native.Surface.terminal

        // Z-ORDER, and it is the deleted half's exactly: content, resize veil, drop zones (inside the
        // receiver), then the focus corner, then the recede veil OUTERMOST — during a walk the corner
        // is the resting answer to a question the switcher is currently asking louder, so the veil
        // covers it too.
        for overlay in [receiver, resizeVeil, focusCorner, recedeVeil] as [UIView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: topAnchor),
                overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        // Both veils and the corner ride opacity, never `isHidden`: a layer-hosting leaf sizes its
        // surface in `layoutSubviews`, which does not run on a hidden subtree, so an un-hide after a
        // scale change would present stale geometry (docs/62 §3.2, keep-all-mounted).
        resizeVeil.layer.opacity = 0
        recedeVeil.layer.opacity = 0
        focusCorner.layer.opacity = 0

        // TAP ANYWHERE FOCUSES THE PANE. `cancelsTouchesInView = false` is what makes that safe: the
        // recogniser sits on the CONTAINER, so it sees touches that land on the leaf's remote pixels
        // too, and without the flag it would swallow the tap the terminal needs. AppKit gets the same
        // result for free — `MacPaneContainer.mouseDown` only ever fires on the container's own bare
        // area, because the leaf in front takes the click first — but a UIKit recogniser on an ancestor
        // is not the responder chain and does not work that way.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, superview == nil {
            detach()
        } else if window != nil {
            attach()
        }
    }

    private func attach() {
        guard !isWired else { return }
        isWired = true
        follow()
    }

    private func detach() {
        guard isWired else { return }
        isWired = false
        generation &+= 1
        settleTask?.cancel()
        settleTask = nil
    }

    /// The pane is closed for good. Forwarded to the leaf, which owns the renderer that a mere unmount
    /// must NOT take down.
    func teardown() {
        detach()
        receiver.teardown()
        (leaf as? TerminalLeafView)?.teardown()
        (leaf as? GuiLeafView)?.teardown()
    }

    // MARK: - What the canvas pushes

    func setFocused(_ isFocused: Bool) {
        guard isFocused != self.isFocused else { return }
        self.isFocused = isFocused
        (leaf as? TerminalLeafView)?.setFocused(isFocused)
        (leaf as? GuiLeafView)?.setFocused(isFocused)
        if isWired { follow() }
    }

    func setVisible(_ isVisible: Bool) {
        guard isVisible != self.isVisible else { return }
        self.isVisible = isVisible
        (leaf as? GuiLeafView)?.setVisible(isVisible)
        // The terminal leaf states the same fact the other way up. A mounted pane in a NON-active tab
        // is still laid out (keep-all-mounted requires it) and must still stop presenting frames, so
        // "not visible" is exactly what occlusion means here.
        (leaf as? TerminalLeafView)?.setOccluded(!isVisible)
    }

    // MARK: - The resize signal

    /// THE SINGLE GENERIC RESIZE SIGNAL. Whatever moved this pane — a divider commit, a rotation, the
    /// keyboard, a zoom, a tab switch — the content has been resized and its frozen or stretched
    /// surface will not match until it re-renders, so the veil goes up until things settle.
    ///
    /// A change between two REAL sizes is a resize; a transition from or to `.zero` is the initial
    /// layout settling (or teardown) and must NOT flash the veil on mount. Both rules are the
    /// reducer's — what is left here is the wait.
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size != lastSize else { return }
        lastSize = size
        guard scrim.noteSize(size, isDragging: store.isInteractiveResizeActive) else {
            applyScrim()
            return
        }
        applyScrim()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: PaneResizeScrimState.settle) } catch { return }
            guard let self else { return }
            scrim.noteSettled()
            applyScrim()
        }
    }

    /// The veil's answer, from the reducer, so the three OR-ed signals are stated once.
    ///
    /// `awaitingReflow` is what HOLDS the veil past the geometry settle: on a slow link the timer alone
    /// would uncover the stretched frame about one RTT too early.
    private func applyScrim() {
        let live = store.handle(for: paneID) as? LivePaneSession
        PaneFade.set(
            resizeVeil,
            shown: scrim.isVisible(
                isDragging: store.isInteractiveResizeActive,
                awaitingReflow: live?.awaitingResizeReflow ?? false,
            ),
        )
    }

    // MARK: - The leaf

    /// Routed by KIND: a terminal pane over the terminal-renderer seam, a `.desktop` pane over the
    /// `VideoWindowFactory` seam with its cap-enforced activation lifecycle.
    private func mountLeaf(live: LivePaneSession?, kind: PaneKind) {
        if kind == leafKind, let leaf {
            (leaf as? TerminalLeafView)?.setLive(live)
            (leaf as? GuiLeafView)?.setLive(live)
            return
        }
        (leaf as? TerminalLeafView)?.teardown()
        (leaf as? GuiLeafView)?.teardown()
        leaf?.removeFromSuperview()
        leafKind = kind

        // `.desktop` is the whole video set today; the check matches `PaneKind.isVideo`, which is
        // internal to WorkspaceCore and so cannot be named from here.
        let built: UIView = if kind == .desktop {
            GuiLeafView(
                live: live, isFocused: isFocused, isVisible: isVisible, store: store, paneID: paneID,
            )
        } else {
            TerminalLeafView(
                live: live,
                isFocused: isFocused,
                // The host-reported cwd feeds the leaf's bottom status bar. The host is the app-global
                // connection target: device-local, and it never rides the shared layout.
                cwd: store.paneCwd(for: paneID),
                store: store,
                overlay: overlayCoordinator,
                chrome: chrome,
            )
        }
        (built as? TerminalLeafView)?.setOccluded(!isVisible)
        leaf = built
        receiver.mount(built)
    }

    // MARK: - The live read

    /// ONE tracked read of everything this container draws on. Same rule as either leaf: one arm, not
    /// one per concern, superseded by generation because an arm cannot be cancelled (docs/62 §3.1).
    private func follow() {
        generation &+= 1
        let generation = generation

        var showsCorner = false
        var recedes = false
        var cwd: String?
        var live: LivePaneSession?
        var kind: PaneKind = .terminal

        withObservationTracking {
            // THE PANE'S SESSION, READ INSIDE THE ARM. The registry it comes out of is `@Observable`
            // state on the store, so reading it here is what makes a session MINTED OR SWAPPED under a
            // stable pane id reach the leaf. Read outside the arm it registers no dependency: the leaf
            // then keeps whatever handle happened to be current at mount, and on the ordinary launch —
            // where `reconcileTree()` has already run — nothing ever says otherwise, so the miss is
            // silent. Same reason the drop receiver takes a CLOSURE rather than a value (see `init`).
            live = store.handle(for: paneID) as? LivePaneSession
            // Routed by KIND, and the fallback reads the spec, so a `.desktop` pane that arrives with
            // the document rebuilds into the video leaf instead of staying a terminal.
            kind = live?.kind ?? store.tree.activeSession?.specs[paneID]?.kind ?? .terminal
            // Registers the resize veil's third signal. `applyScrim()` re-reads it — this read is what
            // makes a change to it INVALIDATE, which nothing else in this view was doing.
            _ = live?.awaitingResizeReflow
            // A hidden tab's pane is not the subject of anything, so both marks read from the SAME
            // `isFocused` this container was pushed rather than from the store — the canvas already
            // resolved the zoom-hidden and sidebar-owns-keyboard arms before pushing it.
            showsCorner = PaneFocusPolicy.showsFocusCorner(
                isFocused: isFocused, tabPaneCount: tabPaneCount,
            )
            // Observing the switcher HERE is what repaints the veil on every step. It costs nothing at
            // rest, where the switcher is nil and the branch is a compare.
            recedes = PaneFocusPolicy.showsSwitcherRecede(
                switcherIsOpen: store.paneSwitcher != nil, isFocused: isFocused,
            )
            cwd = store.paneCwd(for: paneID)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        mountLeaf(live: live, kind: kind)
        (leaf as? TerminalLeafView)?.setCwd(cwd)
        PaneFade.set(focusCorner, shown: showsCorner)
        PaneFade.set(recedeVeil, shown: recedes, curve: Slate.Motion.smallFade)
        applyScrim()
    }

    /// How many panes the tab CONTAINING this pane holds — 1 for an unsplit tab, where the corner stays
    /// bare because there is no sibling to disambiguate from. Defaults to 1 when the pane is not in the
    /// active session's tabs (a teardown race), which hides the mark rather than guessing.
    ///
    /// ⚠️ The owning tab is found with ``Tab/contains(_:)`` rather than `allPaneIDs().contains(_:)`.
    /// Both walk the same split tree, but the second ALLOCATES that tab's whole id list to throw it
    /// away — once per tab, before the match, and then again on the tab that matched. This read sits
    /// inside ``follow()``'s tracking arm, which observes `store.paneSwitcher`, so every mounted
    /// container re-ran it on every switcher step: T+1 arrays per pane per keypress across the canvas.
    private var tabPaneCount: Int {
        store.tree.activeSession?.tabs
            .first { $0.contains(paneID) }?
            .allPaneIDs().count ?? 1
    }

    // MARK: - The tap

    @objc private func handleTap() {
        store.focusPaneTree(paneID)
    }
}
#endif
