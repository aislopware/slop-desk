// SplitCanvasView — the pane canvas, in UIKit: every tab's pane tree, revealing only the active one
// (docs/62 stage E.0). The IDENTITY-PRESERVING compositor.
//
// KEEP-ALL-MOUNTED is the invariant the whole file exists to hold. Every tab of every RETAINED session
// stays mounted at opacity 0, never torn down, because unmounting an inactive tab's subtree kills its
// libghostty surface — and switching back would then show a soft-reset screen rebuilt from the lossy
// ring replay instead of that pane's CURRENT one. The same rule covers a zoom: a zoomed tab still emits
// every sibling as a hidden compositor leaf at its un-zoomed rect, so un-zoom is a pure visibility flip.
// Docs/62 stage E names this as the one thing that makes the stage un-landable if it breaks.
//
// IT PLACES BY FRAME, and that is not a shortcut. `SplitTreeRenderModel.layout(for:in:)` — the same
// pure solver the FocusResolver reads — turns the tab's `SplitNode` tree into ABSOLUTE leaf and divider
// rects, so there is nothing left for Auto Layout to solve: a constraint pair rewritten sixty times a
// second during a divider drag would be the same placement bought through the engine (docs/62 §3.3).
// Branch nodes are never walked into nested stack views. This is what honours the repo guardrail "drive
// geometry in one structure, never tree-relocate a pane on a mode change" — a zoom, a split add/remove
// and a resize all just re-emit rects, and every pane view keeps its identity.
//
// A HIDDEN TAB'S PROMISE IS ONE SENTENCE HERE, NOT TWO. The AppKit half must say `hitTest → nil` AND
// tell every `NSTrackingArea` owner it is non-interactive, because a tracking area is rect-based and
// keeps firing under a hidden tab (docs/56 risk 3). UIKit has no tracking areas, so
// `isUserInteractionEnabled = false` suppresses the whole subtree by itself — docs/62's substitution 1,
// and the one place the port is genuinely SMALLER than the original. What does not come free is
// accessibility, which is stated separately.
//
// NO DRAG DECISIONS, NO PLATFORM GATE, NO DROP-TARGET READER. Where the finger would land, whether the
// source is still in the active tab, what a release commits, and the two geometry reports are
// ``PaneCanvasDragController``'s in `SlopDeskClientCore` — this canvas CALLS them rather than
// translating them.
//
// THE MOVE LAYER IS MOUNTED HERE AND DECIDED ELSEWHERE (docs/62 stage E.2). Each leaf of the active tab
// gets a `PaneMoveHandleView`, and one `PaneMoveOverlayView` draws the drop preview above them all; both
// are drawings that report, and every verdict they report against is the controller's. Three gates are
// this file's own and are stated where they are spent: the layer is mounted only where a move is POSSIBLE
// (more than one leaf), only the SOURCE handle stays touchable once a drag is live, and the whole band
// survives on a tab whose pane is in the air even when that tab is no longer the revealed one.
//
// THE CANCEL KEY IS READ ONCE, IN THIS VIEW. `PaneMoveEscapeResponder` DISSOLVED here rather than being
// ported — docs/62 stage E.2 — because a responder per handle was N views contending for one keyboard,
// and this view is already an ancestor of every pane in the canvas. It is published as a `UIKeyCommand`
// while a drag is live and as a `pressesBegan` net behind it, and BOTH are gated on that drag: the
// terminal is first responder during a move and Escape is a byte it legitimately consumes, so a command
// left installed at rest would take that key away from the shell for the whole session.
//
// The external-landing preview has NO half here, and that is a platform fact rather than a gap: this
// canvas is built with `paneDrag: nil`, because the phone has no satellite window to tear a pane out
// into, so there is no cross-window rendezvous for a preview to draw.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

// MARK: - The canvas

@MainActor
final class SplitCanvasView: UIView {
    /// The canvas cluster's whole injection list — the store, the cross-container drag rendezvous (nil
    /// on this platform), the overlay summoner and the chrome state. See ``PaneCanvasDeps``.
    private let deps: PaneCanvasDeps

    /// The live pane-move drag and every decision it turns on. Built once with the store and the
    /// coordinator, both of which are app-lifetime and which this view holds for exactly as long.
    private let drag: PaneCanvasDragController

    private var layers: [TabID: PaneTabLayerView] = [:]
    private var generation = 0
    private var isWired = false

    init(deps: PaneCanvasDeps) {
        self.deps = deps
        drag = PaneCanvasDragController(store: deps.store, coordinator: deps.paneDrag)
        super.init(frame: .zero)
        // A dynamic `UIColor` on the view re-resolves itself on a theme flip; the AppKit half needs
        // `wantsUpdateLayer` + an appearance override for the same one line.
        backgroundColor = Slate.Native.Surface.terminal
        attach()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
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
        generation &+= 1
        let generation = generation

        var tabs: [SlopDeskWorkspaceModel.Tab] = []
        var activeTabID: TabID?

        withObservationTracking {
            // EVERY tab of every RETAINED session (the active one plus the LRU-retained previous ones),
            // in session-then-tab-bar order. Rendering all of them is what makes an A→B→A session
            // switch a visibility flip rather than a teardown of every outgoing surface.
            tabs = PaneCanvasMounting.mountedTabs(
                sessions: deps.store.tree.sessions,
                retained: deps.store.retainedSessionIDs,
                activeID: deps.store.tree.activeSessionID,
            )
            activeTabID = deps.store.tree.activeSession?.activeTab?.id
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        reconcile(tabs: tabs, activeTabID: activeTabID)
    }

    /// The keyed-dictionary reconcile (docs/62 §3.2): drop what left, mint what arrived, re-place and
    /// re-push the survivors. Identity is the tab id, never a position in an array.
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
                let made = PaneTabLayerView(deps: deps, drag: drag)
                addSubview(made)
                layers[tab.id] = made
                return made
            }()
            layer.frame = bounds
            layer.apply(tab: tab, isActive: tab.id == activeTabID, in: bounds)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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

    // MARK: - The cancel key

    /// Escape, published ONLY while a pane is in the air — the dissolved `PaneMoveEscapeResponder`
    /// (docs/62 §2.4), which used to hold first responder for the length of the drag so the key could
    /// reach it at all.
    ///
    /// A `UIKeyCommand` and not just ``pressesBegan(_:with:)``, because the terminal underneath is the
    /// first responder during a drag and Escape is a key it CONSUMES — it is `\u{1b}` to the shell, and
    /// `TerminalLeafView` forwards only what it did not take. UIKit resolves key commands along the
    /// responder chain before it delivers a press to the first responder, and this view is an ancestor of
    /// every pane, so publishing one here is the only way the cancel gets ahead of the shell.
    ///
    /// ⚠️ WHICH IS ALSO WHY IT IS CONDITIONAL. A command published unconditionally would swallow Escape
    /// for the whole session and the terminal would never see one again — the single worst thing this
    /// file could do to a shell. The list is empty at rest, so `nil` here is not an optimisation; it is
    /// the feature.
    override var keyCommands: [UIKeyCommand]? {
        guard drag.move != nil else { return nil }
        return [.slateCancel(action: #selector(cancelPaneMove))]
    }

    /// The second net, for a press that no key command claimed — a focused pane that is not a terminal,
    /// or a drag begun from a canvas whose first responder is elsewhere entirely. Forwarded to `super`
    /// whenever it is not ours, so nothing else changes shape by this override existing.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard drag.move != nil,
              presses.contains(where: { $0.key?.keyCode == .keyboardEscape })
        else {
            super.pressesBegan(presses, with: event)
            return
        }
        cancelPaneMove()
    }

    /// ⚠️ THE CANCEL MUST REACH THE HANDLE, NOT JUST THE CONTROLLER. Clearing the drag state alone was
    /// the original defect on both platforms and it is a nasty one: the very next touch frame refills it
    /// and the release commits the landing the user explicitly backed out of, so a bail-out un-bails on a
    /// tremor — by which time nobody is watching the screen. ``PaneMoveHandleView/cancelDrag()`` latches
    /// the press inert, which is what makes the cancel stick; the controller being cleared is that
    /// latch's consequence rather than the act itself.
    ///
    /// Idempotent, which is what lets the two doors above both call it without coordinating: the handle
    /// only latches a press that is still dragging, and a drag with no handle left has nothing to latch.
    @objc
    private func cancelPaneMove() {
        guard let source = drag.move?.source else { return }
        // `tabLayer`, not `layer`: the shorter name is `UIView`'s own property, and shadowing it here
        // would make the next reader of this loop wonder which one they are looking at.
        for tabLayer in layers.values where tabLayer.cancelMove(of: source) { return }
        // No handle is tracking, so there is nothing to latch — but the drag state is real and would
        // otherwise stay non-nil forever, which wedges the hit-test gate on every remaining handle.
        drag.interrupted()
    }

    /// The whole canvas is closing. Forwarded so every leaf's renderer comes down — see the reconcile
    /// above for why this is not something a mere unmount may do.
    func teardown() {
        generation &+= 1
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
/// Interaction chrome (the dividers today, the grab handles and the drop preview once stage E.2 lands)
/// is drawn only for the active tab.
///
/// THE Z-BAND IS SUBVIEW ORDER, not `PaneCanvasMetrics.dividerZ`/`moveZ` — those two rungs exist
/// because SwiftUI needed a `.zIndex(_:)` number at two call sites, and a UIKit view hierarchy states
/// the same ordering by where a subview is inserted. Panes go to the BOTTOM of the layer, dividers on
/// top of them, so a seam is always grabbable over the pane edges it sits between.
@MainActor
private final class PaneTabLayerView: UIView {
    private let deps: PaneCanvasDeps
    private let drag: PaneCanvasDragController

    private var panes: [PaneID: PaneContainerView] = [:]
    private var dividers: [SplitTreeRenderModel.DividerHandle.Key: PaneDividerView] = [:]
    private var handles: [PaneID: PaneMoveHandleView] = [:]

    /// The grab handles' own container, mounted once and never re-parented.
    ///
    /// A band rather than N loose subviews, because the z-order of this layer is stated by INSERTION and
    /// the handles have to sit in a fixed place in it: above the panes, so a strip is reachable over the
    /// pane it lifts, and below the dividers, so a seam that runs past the top of a leaf is still
    /// grabbable where the two overlap. Adding each handle directly would put it above whichever divider
    /// happened to be minted first and below the ones minted after.
    private let handleBand = UIView()

    /// The drop preview, minted on the first drag of this tab's life and kept afterwards. Above
    /// everything, and touch-transparent — the only finger on screen belongs to the handle that started
    /// the drag, and an overlay that took it would cancel the gesture it exists to describe.
    private var moveOverlay: PaneMoveOverlayView?

    /// The last solved layout, kept so ``relayout(in:)`` can re-place without the store being asked
    /// again — a rotation is geometry, not a model change.
    private var tab: SlopDeskWorkspaceModel.Tab?
    private var isActive = false
    private var leaves: [SplitTreeRenderModel.PlacedLeaf] = []
    private var frames: [PaneID: CGRect] = [:]
    private var container: CGRect = .zero
    private var generation = 0

    init(deps: PaneCanvasDeps, drag: PaneCanvasDragController) {
        self.deps = deps
        self.drag = drag
        super.init(frame: .zero)
        // Nothing is drawn by the band itself; it is a position in the z-order with a name.
        handleBand.isUserInteractionEnabled = true
        addSubview(handleBand)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: The reconcile

    func apply(tab: SlopDeskWorkspaceModel.Tab, isActive: Bool, in bounds: CGRect) {
        self.tab = tab
        self.isActive = isActive
        // The hidden tab's whole promise, in the three statements docs/62 §3.2 names. Opacity rather
        // than `isHidden`, because `layoutSubviews` does not run on a hidden subtree and the leaves
        // size their drawables there.
        layer.opacity = isActive ? 1 : 0
        isUserInteractionEnabled = isActive
        accessibilityElementsHidden = !isActive
        relayout(in: bounds)
        follow()
    }

    /// Re-solve and re-place for a new container rect. Split from ``apply(tab:isActive:in:)`` because a
    /// rotation or a keyboard raise must not re-run the model reads — the tree did not change, the
    /// rectangle did.
    func relayout(in bounds: CGRect) {
        guard let tab else { return }
        container = bounds
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
        leaves = layout.leaves
        frames = Dictionary(
            layout.leaves.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first },
        )

        // Origin zero, not the passed rect: the solver states its leaf rects in the CONTAINER's own
        // space, and a band offset from that would place every handle by the same wrong delta.
        handleBand.frame = CGRect(origin: .zero, size: bounds.size)
        applyPanes(PaneCanvasMounting.place(
            layout.compositorLeaves, tab: tab, store: deps.store, tabIsActive: isActive,
        ))
        applyDividers(layout.dividers)
        applyHandles()
        applyMoveOverlay()

        // The ACTIVE tab's solved rects, to the store. Without this `lastSolvedLayout` stays forever
        // nil and the directional focus chords resolve against the nominal fallback instead of the real
        // geometry. Hidden tabs are skipped — only the visible geometry counts.
        drag.reportSolvedLayout(frames, isActive: isActive)
    }

    /// A pane leaving the mounted set: its renderer comes down FIRST, then the view detaches. The one
    /// place a pane's libghostty surface / video session may be destroyed.
    private func unmount(_ pane: PaneContainerView) {
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
                let made = PaneContainerView(
                    deps: deps, paneID: spot.id, isFocused: spot.isFocused, isVisible: spot.isVisible,
                )
                // The pane band is the BOTTOM of this layer's z-order — see the type's header.
                made.translatesAutoresizingMaskIntoConstraints = true
                insertSubview(made, at: 0)
                panes[spot.id] = made
                return made
            }()
            pane.frame = spot.rect
            pane.setFocused(spot.isFocused)
            pane.setVisible(spot.isVisible)
            // OPACITY, NEVER `isHidden`: a layer-hosting leaf sizes its surface and picks its
            // `contentsScale` in `layoutSubviews`, which does not run on a hidden subtree — un-hiding
            // after a display change would present stale geometry.
            pane.layer.opacity = spot.isHidden ? 0 : 1
            pane.isUserInteractionEnabled = !spot.isHidden
            pane.accessibilityElementsHidden = spot.isHidden
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
                // suspend/commit pair on release and the single-seam even on a double-tap. What is
                // here is only which gesture the seam reports.
                let made = PaneDividerView(handle: handle, actions: DecorationDividerActions(
                    onResizeBegin: { [store = deps.store] in PaneDividerActions.begin(store) },
                    onResizeChange: { [store = deps.store] leadingWeight in
                        PaneDividerActions.change(store, handle, leadingWeight)
                    },
                    onResizeEnd: { [store = deps.store] in PaneDividerActions.end(store) },
                    onReset: { [store = deps.store] in PaneDividerActions.reset(store, handle) },
                ))
                addSubview(made)
                dividers[handle.key] = made
                return made
            }()
            // The handle is re-pointed rather than rebuilt: it is re-solved on every frame of a live
            // drag, and rebuilding would tear the view out from under the gesture tracking it.
            divider.handle = handle
            divider.frame = handle.rect
        }
    }

    // MARK: The move layer

    /// One grab handle per leaf, and THREE gates that are this file's alone.
    ///
    /// ⚠️ MORE THAN ONE LEAF, OR NONE AT ALL. A finger reveals its pill unconditionally — that is
    /// ``PaneGrabPill/isRevealed(input:hovering:isDragging:)``'s verdict and the right one, since a
    /// finger cannot hover and an affordance that has to be guessed at by pressing is not an affordance.
    /// The price is that the mount is the ONLY thing bounding it, so a lone pane on a phone would carry a
    /// permanent pill offering a move with nowhere to go.
    ///
    /// The second gate is the tab: handles stay up while this layer's own pane is in the air even after
    /// the revealed tab changes underneath it, because unmounting the handle whose gesture is still
    /// tracking strands the drag. The third is per handle — once a move is live, only the SOURCE may take
    /// a touch, or a second finger could start a second drag against a canvas that holds one `move`.
    private func applyHandles() {
        let mounted = leaves.count > 1 && (isActive || drag.moveSourceIsIn(frames))
        let wanted = mounted ? leaves : []
        let ids = Set(wanted.map(\.id))
        for (id, handle) in handles where !ids.contains(id) {
            // The handle reports its own interruption on the way out — see its unmount net — so a leaf
            // closing under a live drag cannot leave `move` set forever.
            handle.removeFromSuperview()
            handles[id] = nil
        }
        let lifted = drag.move?.source
        for leaf in wanted {
            let handle = handles[leaf.id] ?? {
                let made = PaneMoveHandleView(paneID: leaf.id)
                made.onDragChanged = { [weak self] id, point in
                    self?.reportMove(id, at: point, committing: false)
                }
                made.onDragEnded = { [weak self] id, point in
                    self?.reportMove(id, at: point, committing: true)
                }
                made.onDragInterrupted = { [weak self] _ in self?.drag.interrupted() }
                // A tap on the strip is not a move at all: it focuses the pane, which is what a tap
                // anywhere else on that pane already does.
                made.onTap = { [store = deps.store] id in store.focusPaneTree(id) }
                handleBand.addSubview(made)
                handles[leaf.id] = made
                return made
            }()
            handle.frame = leaf.rect
            // A `.desktop` leaf streams somebody else's desktop, which is usually light and never the
            // terminal palette — the flat tertiary bar disappears on it, so the pill gains a plate. The
            // lookup is a dictionary hit on the workspace's located index, not a walk of the tree.
            handle.contentIsUnthemed = deps.store.tree.spec(for: leaf.id)?.kind.isVideo == true
            handle.isUserInteractionEnabled = lifted == nil || lifted == leaf.id
        }
    }

    /// Hand a finger frame to the controller, having re-found the leaf it belongs to by IDENTITY.
    ///
    /// Re-found, and not carried in the closure, because a leaf's rect is re-solved on every layout pass
    /// and the drop is resolved against rects: a captured `PlacedLeaf` would answer with the geometry the
    /// drag STARTED in, so a pane that moved under the finger — a sibling closing, a divider settling —
    /// would land somewhere the preview never showed. A source that has left the list entirely is not an
    /// error either; it is a pane that closed mid-drag, and the only honest answer is to interrupt.
    private func reportMove(_ id: PaneID, at point: CGPoint, committing: Bool) {
        guard let leaf = leaves.first(where: { $0.id == id }) else {
            drag.interrupted()
            return
        }
        if committing {
            drag.ended(leaf: leaf, among: leaves, container: container, at: point)
        } else {
            drag.changed(leaf: leaf, among: leaves, container: container, at: point)
        }
    }

    /// The drop preview, mounted lazily and cleared rather than torn down.
    ///
    /// Kept once minted because a drag is a repeated gesture and rebuilding the band per drag would
    /// rebuild a shape layer and a chip on the first frame of each one — the frame where the user is
    /// watching most closely. Cleared it costs one opacity.
    private func applyMoveOverlay() {
        guard let move = drag.move, isActive || drag.moveSourceIsIn(frames) else {
            moveOverlay?.clear()
            return
        }
        let placed = CGRect(origin: .zero, size: container.size)
        let preview = moveOverlay ?? {
            let made = PaneMoveOverlayView(frame: placed)
            addSubview(made)
            moveOverlay = made
            return made
        }()
        preview.frame = placed
        // Above the dividers as well as the panes: the preview describes where a whole pane is going, and
        // a seam drawn over it would read as part of the answer.
        bringSubviewToFront(preview)
        preview.show(
            drag: move,
            frames: frames,
            container: container,
            sourceTitle: deps.store.tree.spec(for: move.source)?.title,
        )
    }

    /// Latch the handle lifting `source` inert, if it is one of this layer's. Answers whether it was —
    /// the canvas asks every layer and stops at the one that says yes, because only the tab holding the
    /// source has a gesture to cancel.
    func cancelMove(of source: PaneID) -> Bool {
        guard let handle = handles[source] else { return false }
        handle.cancelDrag()
        return true
    }

    // MARK: The live read

    /// What this LAYER draws on, apart from geometry: the keyboard-ownership flag both focus arms read,
    /// and the live move the handles and the preview are placed against.
    ///
    /// ⚠️ STILL ONE ARM. Stage E.2's two reads GREW this one rather than opening a second — reading them
    /// apart would arm two observers over the same drag and re-place the whole tab twice per finger move,
    /// which on a sixty-frame gesture is a hundred and twenty solver runs to draw sixty pictures. The
    /// cross-window read is nil on this platform (`paneDrag: nil`) and is named anyway: what it observes
    /// is the same drag from the other side, and an arm that would have to be reopened to gain it is the
    /// arm this note exists to prevent.
    private func follow() {
        generation &+= 1
        let generation = generation
        withObservationTracking {
            _ = CodeSidebarKeyboardState.shared.ownsKeyboard
            _ = drag.move
            _ = deps.paneDrag?.drag
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.relayout(in: self.container)
                    self.follow()
                }
            }
        }
    }

    func teardown() {
        generation &+= 1
        for pane in panes.values {
            pane.teardown()
            pane.removeFromSuperview()
        }
        panes = [:]
        // The handles come down explicitly rather than riding the layer's own removal, so a drag still in
        // flight when its tab is evicted reports its interruption here — where the canvas is still around
        // to hear it — instead of during whatever teardown order UIKit chooses afterwards.
        for handle in handles.values { handle.removeFromSuperview() }
        handles = [:]
        moveOverlay?.clear()
    }
}
#endif
