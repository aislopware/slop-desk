// PaneCanvasDragControllerTests — the pane-move drag's decisions, now that they are reachable.
//
// These rules spent their whole life as private methods on a `some View`, so nothing headless could
// ask them: the only way to exercise `commitDestination` was to mount the compositor and drag. That is
// the shape docs/56 §3 tests per DECLARATION, and it is why the suite exists the moment the
// declarations descend rather than after the AppKit canvas lands.
//
// THE ORDERING TEST IS THE ONE THIS FILE WAS WRITTEN FOR. A tear-off is two ordered steps, not one op:
// `recordPlacement` must run BEFORE `store.detachPaneToWindow`, because `detachedPanes` changes
// SYNCHRONOUSLY inside that call and the satellite-window coordinator reads the placement as it opens
// the window. Reversed, the satellite still opens — it just opens at the centre-cascade instead of
// under the cursor, and only when the reader wins the race. An occasional wrong-place window is the
// worst failure shape there is, and the ordering was pinned by nothing but prose in a doc comment,
// which is exactly what a hand-written second renderer re-derives by eye. So it is pinned by
// OBSERVING the store the way the real reader does: `withObservationTracking` over `detachedPanes`,
// asking the coordinator for the placement at the instant the tree mutates. Swap the two lines in
// `commitDestination` and this test fails; nothing else in the repo would.
//
// Headless: a tree-model `WorkspaceStore` over this suite's `RecordingPaneSession` double — no socket,
// no video, no Metal, no window (hang-safety). The coordinator's drop targets are plain rect closures,
// which is the whole reason ``PaneDragCoordinator`` keeps a registry instead of reaching for views.

import CoreGraphics
import Observation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneCanvasDragControllerTests: XCTestCase {
    /// The canvas as the WINDOW SERVER sees it (AppKit bottom-left origin), deliberately NOT at the
    /// origin: a controller that forgot to go through ``PaneDragResolver/screenPoint(fromCanvasLocal:canvas:)``
    /// would still pass every assertion here if the canvas sat at (0, 0).
    private let canvasOnScreen = CGRect(x: 100, y: 200, width: 1000, height: 600)
    /// The same canvas in the compositor's own space (top-left origin) — what a gesture reports.
    private let container = CGRect(x: 0, y: 0, width: 1000, height: 600)

    // MARK: - Fixtures

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// A coordinator with the canvas registered — the state the compositor puts it in on appear.
    private func makeCoordinator(store: WorkspaceStore, canvas: CGRect? = nil) -> PaneDragCoordinator {
        let coordinator = PaneDragCoordinator()
        coordinator.store = store
        if let canvas {
            coordinator.register(.canvas) { canvas }
        }
        return coordinator
    }

    /// One tab, two panes stacked top/bottom — the same fixture `PaneCanvasDropTests` resolves against,
    /// so the two suites disagree about nothing.
    private func splitInTwo(_ store: WorkspaceStore) throws -> (top: PaneID, bottom: PaneID) {
        store.splitActivePane(axis: .vertical, kind: .terminal, leading: false)
        let panes = try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs()
        XCTAssertEqual(panes.count, 2, "fixture needs two panes")
        return (panes[0], panes[1])
    }

    private func leaves(top: PaneID, bottom: PaneID) -> [SplitTreeRenderModel.PlacedLeaf] {
        [
            SplitTreeRenderModel.PlacedLeaf(id: top, rect: CGRect(x: 0, y: 0, width: 1000, height: 300)),
            SplitTreeRenderModel.PlacedLeaf(id: bottom, rect: CGRect(x: 0, y: 300, width: 1000, height: 300)),
        ]
    }

    /// A flag box an Observation callback (nonisolated, `@Sendable`) can write into.
    private final class PlacementProbe: @unchecked Sendable {
        var fired = false
        var placementAtDetach: CGPoint?
    }

    // MARK: - The tear-off's ordering

    /// PLACEMENT BEFORE DETACH. The instant `detachPaneToWindow` mutates the tree — which is when the
    /// satellite coordinator learns there is a window to open — the drop point must ALREADY be sitting
    /// on the drag coordinator. Reversed, the placement arrives after the window has chosen its frame.
    func testTheTearOffRecordsThePlacementBeforeTheDetachMutatesTheTree() throws {
        let store = makeStore()
        let (top, _) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        let probe = PlacementProbe()

        // The real reader's dependency exactly: `detachedPanes` is derived from `tree`, so this fires
        // from inside `detachPaneToWindow` and nowhere else in this test.
        withObservationTracking {
            _ = store.detachedPanes
        } onChange: {
            MainActor.assumeIsolated {
                probe.fired = true
                probe.placementAtDetach = coordinator.takePlacement(for: top)
            }
        }

        controller.commitDestination(.tearOff, source: top, local: CGPoint(x: 250, y: 100))

        XCTAssertTrue(probe.fired, "the detach never mutated the tree — this test would pass vacuously")
        XCTAssertEqual(
            probe.placementAtDetach,
            // canvas-local (250, 100) in a canvas at (100, 200) 1000×600 ⇒ screen (350, 700).
            CGPoint(x: 350, y: 700),
            "the drop placement must be recorded BEFORE the detach — the satellite window reads it as it opens",
        )
        XCTAssertEqual(store.detachedPanes.map(\.pane), [top])
    }

    /// …and without a registered canvas there is no screen point to record, so the detach happens ALONE.
    /// That is the honest degradation (the window falls back to its cascade), not a reason to skip the
    /// detach or to record a fabricated point.
    func testATearOffWithNoRegisteredCanvasStillDetaches() throws {
        let store = makeStore()
        let (top, _) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store) // no `.canvas` provider
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)

        controller.commitDestination(.tearOff, source: top, local: CGPoint(x: 250, y: 100))

        XCTAssertEqual(store.detachedPanes.map(\.pane), [top])
        XCTAssertNil(coordinator.takePlacement(for: top), "no canvas rect means no honest screen point")
    }

    // MARK: - Resolution: the source IS in the active tab

    func testInsideTheCanvasTheInTabVocabularyResolves() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let controller = PaneCanvasDragController(
            store: store, coordinator: makeCoordinator(store: store, canvas: canvasOnScreen),
        )
        let placed = leaves(top: top, bottom: bottom)

        XCTAssertEqual(
            controller.dragDestination(
                at: CGPoint(x: 500, y: 450), leaves: placed, container: container,
                source: top, sourceRect: placed[0].rect,
            ),
            .canvas(.swap(target: bottom)),
            "the sibling's centre box is a swap — the in-tab vocabulary, unchanged by the coordinator",
        )
    }

    /// THE SOURCE'S OWN LEAF IS A CANCEL, and it stays one all the way up here: `PaneCanvasDrop` answers
    /// `.none` and the controller must carry that through as `.canvas(.none)` rather than falling into an
    /// external branch and inventing a landing for a pane that never left its own rectangle.
    func testTheSourcesOwnLeafResolvesToACanvasCancel() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let controller = PaneCanvasDragController(
            store: store, coordinator: makeCoordinator(store: store, canvas: canvasOnScreen),
        )
        let placed = leaves(top: top, bottom: bottom)

        XCTAssertEqual(
            controller.dragDestination(
                at: CGPoint(x: 500, y: 150), leaves: placed, container: container,
                source: top, sourceRect: placed[0].rect,
            ),
            .canvas(.none),
        )
    }

    /// Without a coordinator (previews, and the phone, which has one window and nothing to cross into)
    /// the gesture is canvas-only even for a point that has left the container — the old behaviour, and
    /// the arm that must not start resolving tear-offs from a nil registry.
    func testWithoutACoordinatorTheGestureStaysCanvasOnly() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let controller = PaneCanvasDragController(store: store, coordinator: nil)
        let placed = leaves(top: top, bottom: bottom)

        XCTAssertEqual(
            controller.dragDestination(
                at: CGPoint(x: -400, y: 450), leaves: placed, container: container,
                source: top, sourceRect: placed[0].rect,
            ),
            .canvas(.none),
            "off-canvas with no rendezvous is a cancel, never an invented external landing",
        )
    }

    /// Off the canvas WITH a coordinator, the registered targets take over. Nothing is registered but the
    /// main window here, and the point is outside it, so this is the tear-off boundary itself.
    func testOffTheCanvasTheCoordinatorsTargetsTakeOver() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        coordinator.mainWindowFrame = { CGRect(x: 0, y: 0, width: 1200, height: 900) }
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        let placed = leaves(top: top, bottom: bottom)

        // Canvas-local (2000, 100) ⇒ screen (2100, 700) — well outside the window frame above.
        XCTAssertEqual(
            controller.dragDestination(
                at: CGPoint(x: 2000, y: 100), leaves: placed, container: container,
                source: top, sourceRect: placed[0].rect,
            ),
            .tearOff,
        )
    }

    // MARK: - Resolution: the source is NOT in the active tab (a spring-loaded reveal)

    /// A background tab's pane is `sourceIsInActiveTab == false`, which is the whole fork.
    private func makeSpringLoadedScenario() throws -> (store: WorkspaceStore, background: PaneID, visible: PaneID) {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let background = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.selectTab(0)
        let visible = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return (store, background, visible)
    }

    func testASourceOutsideTheActiveTabIsNotInIt() throws {
        let (store, background, visible) = try makeSpringLoadedScenario()
        let controller = PaneCanvasDragController(store: store, coordinator: nil)

        XCTAssertTrue(controller.sourceIsInActiveTab(visible))
        XCTAssertFalse(
            controller.sourceIsInActiveTab(background),
            "a spring-loaded reveal moved the canvas out from under this drag",
        )
    }

    /// INSERT SEMANTICS, NEVER A SWAP. Once the visible canvas belongs to another tab, the drag resolves
    /// against the coordinator's PUSHED layout, where there is no source leaf to exclude and no swap in
    /// the vocabulary — the centre of a leaf re-splits rather than exchanging with it. A resolution that
    /// kept the in-tab rule would offer to swap the dragged pane with one it does not share a tree with.
    func testASpringLoadedSourceResolvesWithInsertSemantics() throws {
        let (store, background, visible) = try makeSpringLoadedScenario()
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        // The visible tab's geometry, pushed exactly the way the compositor pushes it.
        controller.reportContainerBounds(container)
        controller.reportSolvedLayout([visible: container], isActive: true)

        let destination = controller.dragDestination(
            at: CGPoint(x: 500, y: 400), leaves: [], container: container,
            source: background, sourceRect: .zero,
        )

        guard case let .canvas(.resplit(target, _)) = destination else {
            XCTFail("expected an insert re-split against the revealed tab, got \(destination)")
            return
        }
        XCTAssertEqual(target, visible)
    }

    /// The same fork with no canvas rect to resolve in is a cancel, NOT a fall-through into the in-tab
    /// arm: this layer's own leaves belong to a tab nobody is looking at.
    func testASpringLoadedSourceWithNoCanvasRectIsACancel() throws {
        let (store, background, _) = try makeSpringLoadedScenario()
        let controller = PaneCanvasDragController(
            store: store, coordinator: makeCoordinator(store: store),
        )

        XCTAssertEqual(
            controller.dragDestination(
                at: CGPoint(x: 500, y: 400), leaves: [], container: container,
                source: background, sourceRect: .zero,
            ),
            .canvas(.none),
        )
    }

    // MARK: - The reports

    /// The store's own copy is `private` (its readers are geometric ops, not tests), so the coordinator's
    /// mirror is what is asserted — the two are written by the same two lines under the same guard, which
    /// is precisely why the guard is worth pinning at all.
    func testTheReportsReachTheCoordinatorsMirror() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        let placed = leaves(top: top, bottom: bottom)
        let frames = Dictionary(placed.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })

        controller.reportContainerBounds(container)
        controller.reportSolvedLayout(frames, isActive: true)

        XCTAssertEqual(coordinator.canvasBounds, container)
        XCTAssertEqual(coordinator.canvasFrames, frames)
    }

    /// A HIDDEN TAB NEVER REPORTS. Only the geometry the user is actually looking at may be published, or
    /// the ⌃⌘arrow chords navigate a tab that is not on screen — under keep-all-mounted every tab is
    /// alive, so without the guard the LAST one to lay out would win. An empty layout is refused for the
    /// same reason: it is a tab mid-teardown, not a canvas with nothing in it.
    func testAHiddenTabAndAnEmptyLayoutReportNothing() throws {
        let store = makeStore()
        let (top, _) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)

        controller.reportSolvedLayout([top: container], isActive: false)
        XCTAssertTrue(coordinator.canvasFrames.isEmpty)

        controller.reportSolvedLayout([:], isActive: true)
        XCTAssertTrue(coordinator.canvasFrames.isEmpty)
    }

    // MARK: - The gesture's own lifecycle

    /// A frame of the drag: the local preview zone is set, and the FULL destination is published for the
    /// surfaces that render outside this canvas.
    func testAChangedFrameSetsTheLocalZoneAndPublishesTheDrag() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        let placed = leaves(top: top, bottom: bottom)

        controller.changed(
            leaf: placed[0], among: placed, container: container, at: CGPoint(x: 500, y: 450),
        )

        XCTAssertEqual(controller.move?.source, top)
        XCTAssertEqual(controller.move?.zone, .swap(target: bottom))
        XCTAssertEqual(coordinator.drag?.destination, .canvas(.swap(target: bottom)))
        XCTAssertEqual(coordinator.drag?.origin, .tree)
    }

    /// THE LOCAL PREVIEW IS MASKED FOR A LANDING THIS CANVAS DOES NOT OWN. The published destination is
    /// real (the chip and the sidebar render off it); the local zone is `.none`, because the overlay in
    /// THIS layer is drawing against the wrong tab's frames.
    func testASpringLoadedFramePublishesTheDestinationButPreviewsNothingLocally() throws {
        let (store, background, visible) = try makeSpringLoadedScenario()
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        controller.reportContainerBounds(container)
        controller.reportSolvedLayout([visible: container], isActive: true)
        let leaf = SplitTreeRenderModel.PlacedLeaf(id: background, rect: container)

        controller.changed(leaf: leaf, among: [leaf], container: container, at: CGPoint(x: 500, y: 400))

        XCTAssertEqual(controller.move?.zone, .none, "this layer's frames belong to the tab that left")
        guard case .canvas(.resplit) = try XCTUnwrap(coordinator.drag?.destination) else {
            XCTFail("the coordinator must still carry the real landing")
            return
        }
    }

    /// Release: the op runs, and BOTH halves of the drag state clear. Leaving either set wedges the
    /// canvas — the renderer gates every non-source handle's hit-testing on `move == nil`.
    func testAReleaseCommitsAndClearsBothHalvesOfTheDragState() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        let placed = leaves(top: top, bottom: bottom)

        controller.changed(leaf: placed[0], among: placed, container: container, at: CGPoint(x: 500, y: 450))
        controller.ended(leaf: placed[0], among: placed, container: container, at: CGPoint(x: 500, y: 450))

        XCTAssertEqual(
            try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs(), [bottom, top],
            "the release committed the swap",
        )
        XCTAssertNil(controller.move)
        XCTAssertNil(coordinator.drag)
    }

    /// A cancel commits NOTHING — and still clears, which is the whole reason the interruption path
    /// exists separately from the release.
    func testAnInterruptionClearsWithoutCommitting() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let coordinator = makeCoordinator(store: store, canvas: canvasOnScreen)
        let controller = PaneCanvasDragController(store: store, coordinator: coordinator)
        let placed = leaves(top: top, bottom: bottom)
        let before = try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs()

        controller.changed(leaf: placed[0], among: placed, container: container, at: CGPoint(x: 500, y: 450))
        controller.interrupted()

        XCTAssertEqual(try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs(), before)
        XCTAssertNil(controller.move)
        XCTAssertNil(coordinator.drag)
    }

    /// The keep-mounted gate: the layer OWNING a live drag stays mounted even once it is hidden, or the
    /// spring-loaded reveal would tear down the handle whose gesture is still tracking.
    func testTheKeepMountedGateFollowsTheDragsSource() throws {
        let store = makeStore()
        let (top, bottom) = try splitInTwo(store)
        let controller = PaneCanvasDragController(
            store: store, coordinator: makeCoordinator(store: store, canvas: canvasOnScreen),
        )
        let placed = leaves(top: top, bottom: bottom)
        let frames = [top: placed[0].rect]

        XCTAssertFalse(controller.moveSourceIsIn(frames), "no drag, nothing to keep mounted")
        controller.changed(leaf: placed[0], among: placed, container: container, at: CGPoint(x: 500, y: 450))
        XCTAssertTrue(controller.moveSourceIsIn(frames))
        XCTAssertFalse(controller.moveSourceIsIn([bottom: placed[1].rect]))
    }

    // MARK: - The commit fork

    /// The two shared halves of the vocabulary are picked by the ONE fact neither can read for itself.
    /// An in-tab `.canvas` goes to ``PaneCanvasDrop``; the same case for a source whose tab was
    /// spring-loaded away goes to ``PaneDragCommit``'s CROSS-TAB family, which is a different store op
    /// entirely.
    func testASpringLoadedCanvasLandingCommitsInTheCrossTabFamily() throws {
        let (store, background, visible) = try makeSpringLoadedScenario()
        let controller = PaneCanvasDragController(store: store, coordinator: nil)

        controller.commitDestination(
            .canvas(.resplit(target: visible, edge: .right)), source: background, local: .zero,
        )

        let panes = try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs()
        XCTAssertEqual(panes, [visible, background], "the background tab's pane moved into the visible tab")
    }

    /// `.none` is a cancel on both sides of that fork.
    func testACancelCommitsNothing() throws {
        let store = makeStore()
        let (top, _) = try splitInTwo(store)
        let controller = PaneCanvasDragController(store: store, coordinator: nil)
        let before = try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs()

        controller.commitDestination(.canvas(.none), source: top, local: .zero)
        controller.commitDestination(.none, source: top, local: .zero)

        XCTAssertEqual(try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs(), before)
        XCTAssertTrue(store.detachedPanes.isEmpty)
    }
}
