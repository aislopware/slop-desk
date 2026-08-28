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
// ⚠️ THE PANE-MOVE AFFORDANCE IS NOT MOUNTED YET, AND THAT IS A SEAM, NOT AN OMISSION OF POLICY. The
// AppKit twin also mounts a grab handle per leaf, a move overlay and an external landing preview
// (`MacPaneMoveAffordance.swift`); the deleted SwiftUI half mounted `PaneMoveHandle`,
// `PaneMoveOverlay`, `PaneMoveEscapeMonitor` and `ExternalDropZonePreview`. None of those has a UIKit
// half yet — docs/62 puts them in stage E.2 alongside `PaneMoveEscapeResponder` DISSOLVING into the
// canvas controller's `pressesBegan` — so this file mounts panes and dividers and stops there. What is
// already wired is everything the move layer would need from this view and everything the rest of the
// app needs from it regardless: the controller is built, `reportContainerBounds` and
// `reportSolvedLayout` are called, and the layer's tracking arm is the one those reads join. The
// deleted half also passed `paneDrag: nil` — the phone has no satellite window to tear a pane out
// into — so the external-preview arm is inert on this platform even once the handles land.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

// MARK: - The canvas

@MainActor
final class SplitCanvasView: UIView {
    private let store: WorkspaceStore
    /// The cross-container drag rendezvous — resolves SIDEBAR / New-Tab / tear-off destinations once
    /// the finger leaves this view. `nil` keeps every drag canvas-only, which is what the phone passes.
    private let paneDrag: PaneDragCoordinator?
    private let overlay: OverlayCoordinator?
    private let chrome: WorkspaceChromeState?

    /// The live pane-move drag and every decision it turns on. Built once with the store and the
    /// coordinator, both of which are app-lifetime and which this view holds for exactly as long.
    private let drag: PaneCanvasDragController

    private var layers: [TabID: PaneTabLayerView] = [:]
    private var lastReportedBounds: CGRect = .zero
    private var generation = 0
    private var isWired = false

    init(
        store: WorkspaceStore,
        paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
    ) {
        self.store = store
        self.paneDrag = paneDrag
        self.overlay = overlay
        self.chrome = chrome
        drag = PaneCanvasDragController(store: store, coordinator: paneDrag)
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
                sessions: store.tree.sessions,
                retained: store.retainedSessionIDs,
                activeID: store.tree.activeSessionID,
            )
            activeTabID = store.tree.activeSession?.activeTab?.id
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
        let wanted = Set(tabs.map(\.id))
        for (id, layer) in layers where !wanted.contains(id) {
            // A tab that left the mounted set is genuinely GONE — closed, or evicted from the retention
            // window. This is the one place a pane's renderer may come down, and it must, or the
            // sockets and threads behind it outlive every reference to them.
            layer.teardown()
            layer.removeFromSuperview()
            layers[id] = nil
        }
        for tab in tabs {
            let layer = layers[tab.id] ?? {
                let made = PaneTabLayerView(
                    store: store, paneDrag: paneDrag, overlay: overlay, chrome: chrome, drag: drag,
                )
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
        // Reported once at this level, never per tab.
        if rect != lastReportedBounds {
            lastReportedBounds = rect
            drag.reportContainerBounds(rect)
        }
        for layer in layers.values {
            layer.frame = rect
            layer.relayout(in: rect)
        }
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
    private let store: WorkspaceStore
    private let paneDrag: PaneDragCoordinator?
    private let overlay: OverlayCoordinator?
    private let chrome: WorkspaceChromeState?
    private let drag: PaneCanvasDragController

    private var panes: [PaneID: PaneContainerView] = [:]
    private var dividers: [SplitTreeRenderModel.DividerHandle.Key: PaneDividerView] = [:]

    /// The last solved layout, kept so ``relayout(in:)`` can re-place without the store being asked
    /// again — a rotation is geometry, not a model change.
    private var tab: SlopDeskWorkspaceModel.Tab?
    private var isActive = false
    private var leaves: [SplitTreeRenderModel.PlacedLeaf] = []
    private var frames: [PaneID: CGRect] = [:]
    private var container: CGRect = .zero
    private var generation = 0

    init(
        store: WorkspaceStore,
        paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
        drag: PaneCanvasDragController,
    ) {
        self.store = store
        self.paneDrag = paneDrag
        self.overlay = overlay
        self.chrome = chrome
        self.drag = drag
        super.init(frame: .zero)
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

        applyPanes(layout.compositorLeaves, tab: tab)
        applyDividers(layout.dividers)

        // The ACTIVE tab's solved rects, to the store. Without this `lastSolvedLayout` stays forever
        // nil and the directional focus chords resolve against the nominal fallback instead of the real
        // geometry. Hidden tabs are skipped — only the visible geometry counts.
        drag.reportSolvedLayout(frames, isActive: isActive)
    }

    /// EVERY pane — visible AND zoom-hidden — from one list, so the hidden↔visible flip never
    /// reconstructs a surface across the boundary.
    private func applyPanes(
        _ entries: [SplitTreeRenderModel.CompositorLeaf], tab: SlopDeskWorkspaceModel.Tab,
    ) {
        let wanted = Set(entries.map(\.id))
        for (id, pane) in panes where !wanted.contains(id) {
            pane.teardown()
            pane.removeFromSuperview()
            panes[id] = nil
        }
        let activeTabID = store.tree.activeSession?.activeTab?.id
        for entry in entries {
            // A zoom-hidden pane must never claim first responder — the same guard keep-all-mounted
            // needs for a hidden tab. And while the code panel's webview owns the keyboard, the
            // workspace-focused pane renders UNFOCUSED, which through the terminal's focus-gated
            // responder claim also stops it re-taking the keyboard the editor is using.
            let focused = CodeSidebarKeyboardState.paneRendersFocused(
                workspaceFocused: !entry.isHidden
                    && PaneFocusPolicy.isPaneFocused(entry.id, in: tab, activeTabID: activeTabID),
                sidebarOwnsKeyboard: CodeSidebarKeyboardState.shared.ownsKeyboard,
            )
            // ON-SCREEN: this tab is the active one AND the pane is not zoom-collapsed. A video pane
            // drives its `liveVideoCap` activation off exactly this, and the terminal leaf its
            // occlusion.
            let visible = isActive && !entry.isHidden
            let pane = panes[entry.id] ?? {
                let made = PaneContainerView(
                    store: store, paneID: entry.id, isFocused: focused, isVisible: visible,
                    overlay: overlay, chrome: chrome,
                )
                // The pane band is the BOTTOM of this layer's z-order — see the type's header.
                made.translatesAutoresizingMaskIntoConstraints = true
                insertSubview(made, at: 0)
                panes[entry.id] = made
                return made
            }()
            pane.frame = entry.leaf.rect
            pane.setFocused(focused)
            pane.setVisible(visible)
            // OPACITY, NEVER `isHidden`: a layer-hosting leaf sizes its surface and picks its
            // `contentsScale` in `layoutSubviews`, which does not run on a hidden subtree — un-hiding
            // after a display change would present stale geometry.
            pane.layer.opacity = entry.isHidden ? 0 : 1
            pane.isUserInteractionEnabled = !entry.isHidden
            pane.accessibilityElementsHidden = entry.isHidden
        }
    }

    /// The dividers, drawn only for the active tab — a hidden tab is non-interactive, so it needs none.
    private func applyDividers(_ handles: [SplitTreeRenderModel.DividerHandle]) {
        let wanted = isActive ? handles : []
        let keys = Set(wanted.map(\.key))
        for (key, divider) in dividers where !keys.contains(key) {
            divider.removeFromSuperview()
            dividers[key] = nil
        }
        for handle in wanted {
            let divider = dividers[handle.key] ?? {
                let made = PaneDividerView(
                    handle: handle,
                    // Live resize: hold the host grid-resize for the drag, set the leading weight
                    // absolutely each frame so the panes move live, then flush and persist ONCE.
                    onResizeBegin: { [store] in store.setTerminalResizeSuspended(true) },
                    onResizeChange: { [store] leadingWeight in
                        store.setDividerWeightLive(
                            splitID: handle.splitID,
                            leadingChildIndex: handle.childIndex,
                            leadingWeight: leadingWeight,
                        )
                    },
                    // The release, and the ONE place the suspend comes back down. It arrives on an end,
                    // on a cancel, AND on this seam's teardown — because the flag is workspace-wide
                    // store state rather than this seam's, and a seam unmounting mid-drag (which happens
                    // routinely: a neighbouring pane closing drops a handle) would otherwise leave every
                    // terminal's grid send suspended for the rest of the session.
                    onResizeEnd: { [store] in
                        store.setTerminalResizeSuspended(false)
                        store.commitDividerResize()
                    },
                    // Double-tap evens ONLY this seam — never `balanceActivePaneSplits()`, which
                    // rebalances the whole tab and wipes every other divider's dragged ratio.
                    onReset: { [store] in
                        store.evenDividerTree(
                            splitID: handle.splitID, leadingChildIndex: handle.childIndex,
                        )
                    },
                )
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

    // MARK: The live read

    /// What this LAYER draws on, apart from geometry: the keyboard-ownership flag both focus arms read.
    ///
    /// ⚠️ ONE arm, and it grows rather than splits when the move layer lands — `drag.move` and
    /// `paneDrag?.drag` are the two reads stage E.2 adds HERE, not in a second `withObservationTracking`
    /// of their own. Reading them separately would arm two observers over the same drag and re-place the
    /// whole tab twice per finger move.
    private func follow() {
        generation &+= 1
        let generation = generation
        withObservationTracking {
            _ = CodeSidebarKeyboardState.shared.ownsKeyboard
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
    }
}
#endif
