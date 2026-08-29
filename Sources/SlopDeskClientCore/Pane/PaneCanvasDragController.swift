// PaneCanvasDragController — the pane-move drag's DECISION half: where a grab handle's cursor would
// land, what a release there commits, and the one piece of view-local state the whole gesture turns on.
//
// It was `SplitContainer`'s private half — a `@State private var move: PaneMoveDrag?` and the six
// methods that read or wrote it — and every one of those six was already pure-or-actuation with no
// drawing in it: no design token, no layout, no view type named. That is exactly the per-declaration
// test docs/56 §3 states, and increment 56c's ruling about ``PaneDropGeometry`` applies word for word:
// *a method on a `View` is not a view, but nothing that is not one can reach it.* The canvas is about
// to get a second renderer in AppKit, and a decision left inside the SwiftUI compositor gets TRANSLATED
// BY HAND into a second language — the "one implementation, never two" failure `CLAUDE.md` bans, in the
// same commit that claims to honour it.
//
// ``commitDestination`` IS THE REASON THIS FILE EXISTS AND NOT THE FIVE AROUND IT. Its `.tearOff` arm
// is two ORDERED steps rather than one op: the drop point is recorded on the coordinator FIRST, and
// only then does `store.detachPaneToWindow` run — because `detachedPanes` changes SYNCHRONOUSLY inside
// that call and the satellite-window coordinator reads the placement as it opens the window. Swap the
// two lines and the window still opens; it just opens at the centre-cascade instead of under the
// cursor, and only when the reader happens to win the race. A satellite landing in the wrong place
// *occasionally* is the worst failure shape there is, and it was pinned by nothing but the prose in
// that method's own doc comment — prose an AppKit rewrite would have re-derived by eye.
// `PaneCanvasDragControllerTests` pins the order directly now, by observing the store's `tree` at the
// instant the detach mutates it and asserting the placement is ALREADY there.
//
// SHAPE: `@Observable`, holding `move`, driven by `changed` / `ended` / `interrupted` —
// ``TerminalFindBarModel``'s shape exactly, for the same reason (a driver the renderer observes, with
// the framework left on the other side of the seam). What was rejected: passing the store and the
// coordinator per call, which would have put the same two arguments on six signatures; and stashing the
// solved layout on the controller so the gesture methods could take `(leaf, point)` alone — a second,
// STALER copy of the solver's output, which is precisely the "one parse behind the screen the user is
// looking at" trap ``TerminalFindBarModel``'s own header records about DECCKM. The layout is threaded
// through every call, so the resolution can only ever run against the frame that drew the handle.
//
// NOT HERE, deliberately: the grab handle's `onTap` (`store.focusPaneTree`) and its `contentIsUnthemed`
// read. Neither is part of the drag — a tap is not a move — and the drag state is what this type owns.

import CoreGraphics
import Observation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The canvas compositor's live pane-move drag: the state, the resolution, and the commit.
///
/// Held by the renderer for the life of the canvas (SwiftUI: one `@State`), which is why the store and
/// the coordinator are taken at construction rather than through a settable seam — both are
/// app-lifetime and the mount already holds them for exactly as long. A late `attach` would also have
/// raised an ordering question the reports below cannot afford: `reportSolvedLayout` fires from a tab
/// layer's appear hook, and SwiftUI does not promise the container's own hook has run first.
@MainActor
@Observable
package final class PaneCanvasDragController {
    /// The LIVE pane-move drag (grab handle), or `nil` at rest. Renderer-local by design: the store is
    /// untouched until release, so the terminal-grid / remote-window redraw fires ONCE on commit rather
    /// than on every cursor sample. `private(set)` — only this type's own methods move it, and each
    /// mutation is what re-renders the overlay.
    package private(set) var move: PaneMoveDrag?

    /// The workspace store every commit lands in. Strong: the renderer that owns this controller holds
    /// the store strongly for its whole life anyway, so a weak ref would buy nothing and cost a
    /// silently-skipped commit. `@ObservationIgnored` — pure wiring.
    @ObservationIgnored private let store: WorkspaceStore

    /// The cross-container drag rendezvous — resolves SIDEBAR / New-Tab / tear-off destinations once the
    /// cursor leaves the canvas's hosting view, and carries the tear-off placement hand-off. `nil`
    /// (previews / iOS) keeps the gesture canvas-only, which is the old behaviour exactly.
    @ObservationIgnored private let paneDrag: PaneDragCoordinator?

    package init(store: WorkspaceStore, coordinator: PaneDragCoordinator?) {
        self.store = store
        paneDrag = coordinator
    }

    // MARK: - The gesture (the renderer's whole drag vocabulary)

    /// One drag FRAME: resolve the full destination, set the local preview zone, publish the drag.
    ///
    /// The local overlay draws only the CANVAS zones of the source's OWN (active) tab. An external
    /// destination reads `.none` here — its cursor chip is clipped at the hosting-view edge anyway, and
    /// the coordinator's floating panel plus the sidebar highlights are the affordance out there — and
    /// so does a spring-loaded canvas zone, because the ACTIVE tab's own external-drop preview owns that
    /// drawing and this layer's frames are the wrong tab's.
    package func changed(
        leaf: SplitTreeRenderModel.PlacedLeaf,
        among leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
        at location: CGPoint,
    ) {
        let destination = dragDestination(
            at: location, leaves: leaves, container: container, source: leaf.id, sourceRect: leaf.rect,
        )
        let localZone: PaneDropZone = sourceIsInActiveTab(leaf.id)
            ? PaneCanvasMetrics.canvasZone(of: destination) : .none
        move = PaneMoveDrag(source: leaf.id, location: location, zone: localZone)
        publishTreeDrag(destination, source: leaf.id, local: location, soleLeaf: leaves.count <= 1)
    }

    /// RELEASE: re-resolve at the final point, commit it, then clear both halves of the drag state.
    ///
    /// The destination is resolved again rather than read off ``move``, because `move.zone` is the
    /// LOCAL preview (`.none` for everything outside this tab's canvas) — committing that would silently
    /// cancel every sidebar, New-Tab and tear-off landing.
    package func ended(
        leaf: SplitTreeRenderModel.PlacedLeaf,
        among leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
        at location: CGPoint,
    ) {
        let destination = dragDestination(
            at: location, leaves: leaves, container: container, source: leaf.id, sourceRect: leaf.rect,
        )
        commitDestination(destination, source: leaf.id, local: location)
        move = nil
        paneDrag?.end()
    }

    /// The interruption safety net — Escape, a gesture cancel, or this leaf closing mid-drag (torn out
    /// of the renderer's leaf list before a release can fire). Clears the local move state AND the
    /// cross-window coordinator; commits NOTHING, because a cancel commits nothing.
    ///
    /// Not clearing it wedges the canvas: the renderer gates every other handle's hit-testing on
    /// `move == nil`, so a stranded drag leaves every grab handle but one dead forever.
    package func interrupted() {
        move = nil
        paneDrag?.end()
    }

    /// Whether the live drag's SOURCE pane is one of the given tab layer's leaves — the keep-mounted
    /// gate that lets its grab-handle gesture survive a spring-loaded tab switch. A reveal switches the
    /// active tab mid-drag, and unmounting the source tab's layer would destroy the handle whose gesture
    /// is still tracking.
    package func moveSourceIsIn(_ frames: [PaneID: CGRect]) -> Bool {
        guard let move else { return false }
        return frames[move.source] != nil
    }

    // MARK: - The reports the geometry ops run against

    /// Push the container bounds to the store (the geometric ops' fallback before the first solved
    /// layout) AND to the drag coordinator (the canvas-local space a satellite-origin drag resolves its
    /// insert zones in). Renderer-driven, never reconciling: fires once at the container level.
    ///
    /// DEDUPED HERE rather than at the two renderers. An imperative shell's layout pass runs on every
    /// pass, not only on a size change, so both shells had grown the same `lastReportedBounds` property
    /// and the same three-line guard around this call — a cache of the ARGUMENT, kept beside the view
    /// instead of beside the thing that is expensive to tell. One controller is built per canvas and it
    /// is the only caller, so the last value it sent IS the store's reading; a shell that reports the
    /// same rect twice now costs nothing and has to remember nothing.
    package func reportContainerBounds(_ bounds: CGRect) {
        guard bounds != lastReportedBounds else { return }
        lastReportedBounds = bounds
        store.updateContainerBounds(bounds)
        paneDrag?.canvasBounds = bounds
    }

    /// The last rect ``reportContainerBounds(_:)`` actually pushed. `@ObservationIgnored` — it is the
    /// dedupe's own memory and nothing renders from it.
    @ObservationIgnored private var lastReportedBounds: CGRect?

    /// Forward the ACTIVE tab's solved frames to the store and mirror them to the drag coordinator, so a
    /// satellite-origin drag resolves its canvas insert zones against the same live geometry.
    ///
    /// A hidden tab NEVER reports — the store must only ever hold the geometry the user actually sees,
    /// or the ⌃⌘arrow / ⌥⌘⇧arrow chords would navigate a tab that is not on screen. Required wiring
    /// rather than an optimisation: without it `lastSolvedLayout` stays forever nil and those chords
    /// resolve against the store's nominal fallback instead of the real rects.
    package func reportSolvedLayout(_ frames: [PaneID: CGRect], isActive: Bool) {
        guard isActive, !frames.isEmpty else { return }
        store.updateSolvedLayout(SolvedLayout(frames: frames))
        paneDrag?.canvasFrames = frames
    }

    // MARK: - Resolution

    /// The FULL destination for a tree drag at canvas-local `loc`: inside the canvas the live in-tab
    /// resolution applies unchanged; outside it, the coordinator's registered targets (sidebar rows, the
    /// New-Tab slot, the tear-off boundary) take over. Without a coordinator (previews / iOS) the
    /// gesture stays canvas-only.
    ///
    /// A SPRING-LOADED reveal can switch the active tab mid-drag — the source then no longer lives in
    /// the visible tab, so the canvas resolves with INSERT semantics against the coordinator's pushed
    /// active-tab layout instead of this (hidden) layer's own leaves.
    package func dragDestination(
        at loc: CGPoint,
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
        source: PaneID,
        sourceRect: CGRect,
    ) -> PaneDragDestination {
        if let paneDrag, !sourceIsInActiveTab(source) {
            guard let canvas = paneDrag.targetFrame(.canvas) else { return .canvas(.none) }
            return paneDrag.resolveSpringLoadedTreeDestination(
                at: PaneDragResolver.screenPoint(fromCanvasLocal: loc, canvas: canvas),
                source: source,
                sourceIsSoleLeafOfItsTab: leaves.count <= 1,
            )
        }
        if container.contains(loc) || paneDrag == nil {
            return .canvas(PaneCanvasDrop.zone(
                at: loc, leaves: leaves, container: container, source: source, sourceRect: sourceRect,
            ))
        }
        guard let paneDrag, let canvas = paneDrag.targetFrame(.canvas) else { return .canvas(.none) }
        return paneDrag.resolveTreeExternalDestination(
            at: PaneDragResolver.screenPoint(fromCanvasLocal: loc, canvas: canvas),
            source: source,
            sourceIsSoleLeafOfItsTab: leaves.count <= 1,
        )
    }

    /// Whether `source` still lives in the ACTIVE tab — false after a spring-loaded reveal switched tabs
    /// under a live drag. Decides both the canvas resolution semantics (in-tab swap/re-split vs insert)
    /// and the commit family (same-tab move vs cross-tab move).
    ///
    /// No active tab answers TRUE: a canvas with nothing in it resolves canvas-locally, which is the
    /// arm that commits nothing rather than the arm that reaches across tabs.
    package func sourceIsInActiveTab(_ source: PaneID) -> Bool {
        store.tree.activeSession?.activeTab?.allPaneIDs().contains(source) ?? true
    }

    /// Mirror the live tree drag to the coordinator — the sidebar highlights / New-Tab slot / floating
    /// chip / spring-load dwell all render off this one published state. `soleLeaf` rides along so the
    /// coordinator's auto-scroll tick can re-resolve the external destination without re-asking here.
    private func publishTreeDrag(
        _ dest: PaneDragDestination, source: PaneID, local: CGPoint, soleLeaf: Bool,
    ) {
        guard let paneDrag, let canvas = paneDrag.targetFrame(.canvas) else { return }
        paneDrag.update(
            source: source,
            origin: .tree,
            screenPoint: PaneDragResolver.screenPoint(fromCanvasLocal: local, canvas: canvas),
            destination: dest,
            sourceIsSoleLeafOfItsTab: soleLeaf,
        )
    }

    // MARK: - Commit

    /// Commits the FULL destination with exactly ONE store op, by asking whichever half of the drop
    /// vocabulary owns it.
    ///
    /// The fork here is not a fourth spelling of the four cases — it is the ONE fact the two shared
    /// decisions cannot read for themselves. ``PaneCanvasDrop`` owns the in-tab vocabulary (swap, in-tab
    /// re-split, in-tab dock); ``PaneDragCommit`` owns every landing that leaves the tab, in the `.tree`
    /// op family, and is the same decision the satellite window's reattach asks.
    ///
    /// WHAT IS LEFT IS THE TEAR-OFF, AND ITS ORDER IS THE WHOLE REASON IT STAYS SPELLED OUT.
    /// `recordPlacement` runs BEFORE `detachPaneToWindow`, because `detachedPanes` changes
    /// SYNCHRONOUSLY inside that call and the satellite coordinator reads the placement as it opens the
    /// window. Reversed, the window opens at the centre-cascade instead of under the cursor — and only
    /// sometimes, which is the failure shape nobody can reproduce. Folding it into either shared switch
    /// would hide the ordering from both readers; `PaneCanvasDragControllerTests` pins it instead.
    package func commitDestination(_ dest: PaneDragDestination, source: PaneID, local: CGPoint) {
        switch dest {
        case let .canvas(zone) where sourceIsInActiveTab(source):
            PaneCanvasDrop.commit(zone, pane: source, in: store)
        case .tearOff:
            if let paneDrag, let canvas = paneDrag.targetFrame(.canvas) {
                paneDrag.recordPlacement(
                    source, at: PaneDragResolver.screenPoint(fromCanvasLocal: local, canvas: canvas),
                )
            }
            store.detachPaneToWindow(source)
        default:
            // A spring-loaded landing (the zone was resolved with INSERT semantics against ANOTHER
            // tab's canvas), a sidebar row, or the New-Tab slot. `.none` — and the `.swap` an insert
            // resolution can never produce — commit nothing there, which is the cancel.
            PaneDragCommit.commit(dest, pane: source, origin: .tree, in: store)
        }
    }
}
