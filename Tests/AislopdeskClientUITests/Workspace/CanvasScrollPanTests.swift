import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the live SCROLL-pan accumulator (``WorkspaceStore/scrollPan(by:)`` / ``commitScrollPan()``) — the
/// 2026-06-08 BUG-2/BUG-1 freeze fix. A trackpad/wheel pan no longer calls ``commitCamera(_:)`` per step
/// (which thrashed the `report()` cascade → main-thread block → frozen video/cursor); instead it
/// accumulates a VISUAL-only ``liveCameraOffset`` and commits ONCE. These tests pin the two invariants
/// that keep that safe: (1) a step does NOT move the real camera, and (2) the commit folds the exact total
/// into the camera with NO visual jump (committed offset == live offset), plus the absolute-op discard.
///
/// `WorkspaceStore` is `@MainActor`; the suite uses the spec-only `FakePaneSession` seam (no client/host).
@MainActor
final class CanvasScrollPanTests: XCTestCase {
    private let eps: CGFloat = 1e-9

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
    }

    /// A live scroll step accumulates the visual offset as the NEGATIVE of the camera delta and leaves the
    /// real camera UNTOUCHED — so a pan re-renders only `CanvasView`, never the `report()` cascade.
    func testScrollStepAccumulatesVisualOffsetWithoutMovingCamera() {
        let store = makeStore()
        let origin0 = store.workspace.canvas.camera.origin

        store.scrollPan(by: CGSize(width: 10, height: 5))
        store.scrollPan(by: CGSize(width: 4, height: -3))

        // Visual offset is -(sum of camera deltas): content follows the camera.
        XCTAssertEqual(store.liveCameraOffset.width, -14, accuracy: eps)
        XCTAssertEqual(store.liveCameraOffset.height, -2, accuracy: eps)
        // The real (persisted) camera has NOT moved yet — this is what avoids the per-step re-render.
        XCTAssertEqual(store.workspace.canvas.camera.origin, origin0)
    }

    /// Committing folds the EXACT accumulated total into the camera and zeroes the visual offset, with no
    /// jump: the committed `.offset` (`-newOrigin`) equals the live `.offset` (`-oldOrigin + liveOffset`).
    func testCommitFoldsTotalIntoCameraWithNoJump() {
        let store = makeStore()
        let origin0 = store.workspace.canvas.camera.origin

        store.scrollPan(by: CGSize(width: 10, height: 5))
        store.scrollPan(by: CGSize(width: 4, height: -3))
        let liveOffset = store.liveCameraOffset // captured live visual offset

        store.commitScrollPan()

        let origin1 = store.workspace.canvas.camera.origin
        // Camera moved by the TOTAL of the steps (10+4, 5-3) = (14, 2).
        XCTAssertEqual(origin1.x, origin0.x + 14, accuracy: eps)
        XCTAssertEqual(origin1.y, origin0.y + 2, accuracy: eps)
        // Visual offset cleared.
        XCTAssertEqual(store.liveCameraOffset, .zero)
        // NO-JUMP invariant: committed offset (-origin1) == live offset (-origin0 + liveOffset).
        XCTAssertEqual(-origin1.x, -origin0.x + liveOffset.width, accuracy: eps)
        XCTAssertEqual(-origin1.y, -origin0.y + liveOffset.height, accuracy: eps)
    }

    /// Committing with nothing pending is a no-op (no spurious camera move).
    func testCommitWithNothingPendingIsNoOp() {
        let store = makeStore()
        let origin0 = store.workspace.canvas.camera.origin
        store.commitScrollPan()
        XCTAssertEqual(store.liveCameraOffset, .zero)
        XCTAssertEqual(store.workspace.canvas.camera.origin, origin0)
    }

    /// An ABSOLUTE camera op (recenter) must DISCARD a still-pending live scroll, so a late commit can't
    /// add a stale relative delta on top of the new absolute position.
    func testAbsoluteCameraOpDiscardsPendingLiveScroll() {
        let store = makeStore()
        store.scrollPan(by: CGSize(width: 120, height: 80))
        XCTAssertNotEqual(store.liveCameraOffset, .zero, "precondition: a live scroll is pending")

        store.centerOnAll()

        XCTAssertEqual(store.liveCameraOffset, .zero, "recenter discards the pending live scroll offset")
    }

    /// Switching to a saved layout preset sets the camera ABSOLUTELY (the preset's saved camera), so it must
    /// discard a still-pending live scroll — else a late `commitScrollPan()` folds a stale relative delta
    /// onto the restored camera, jumping the viewport off the saved layout (hunt 2026-06-13, finding #2).
    func testSwitchToLayoutPresetDiscardsPendingLiveScroll() {
        let store = makeStore()
        store.addPane(kind: .terminal)
        store.saveLayoutPreset(name: "p", triggerAppName: nil)
        store.scrollPan(by: CGSize(width: 120, height: 80))
        XCTAssertNotEqual(store.liveCameraOffset, .zero, "precondition: a live scroll is pending")

        store.switchToLayoutPreset(name: "p")

        XCTAssertEqual(
            store.liveCameraOffset,
            .zero,
            "switching to a saved layout preset discards the pending live scroll",
        )
    }

    /// The in-view-guarantee re-center in the placement paths (add / duplicate / reopen / system-dialog) is
    /// also an ABSOLUTE camera set, so it too must discard a pending live scroll when it fires (hunt
    /// 2026-06-13, finding #6). Drives the off-viewport branch by committing the camera far from where panes
    /// land, then adding a pane mid-scroll.
    func testOffscreenPlacementRecenterDiscardsPendingLiveScroll() {
        let store = makeStore()
        store.addPane(kind: .terminal) // a pane near the origin; becomes focused
        store.updateViewport(CGSize(width: 400, height: 300))
        // Commit the real camera far from where panes live, so the next pane lands off-viewport.
        store.scrollPan(by: CGSize(width: 5000, height: 5000))
        store.commitScrollPan()
        XCTAssertEqual(store.liveCameraOffset, .zero, "precondition: camera committed far away")
        // Start a fresh pending live scroll, then add a pane that lands off the (far) viewport.
        store.scrollPan(by: CGSize(width: 60, height: 40))
        XCTAssertNotEqual(store.liveCameraOffset, .zero, "precondition: a live scroll is pending")

        store.addPane(kind: .terminal) // placed near the origin-area focused pane → off the far viewport

        XCTAssertEqual(
            store.liveCameraOffset,
            .zero,
            "an off-viewport placement recenter discards the pending live scroll",
        )
    }
}
