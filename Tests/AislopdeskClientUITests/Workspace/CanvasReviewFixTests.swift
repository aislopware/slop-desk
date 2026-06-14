import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the fixes from the adversarial review of the infinite-canvas implementation (docs/30): the
/// focus↔maximize coupling, the `isPaneVisible` reported-vs-empty semantics, camera/coordinate
/// sanitation against non-finite/extreme values, and the dangling-`maximizedPane` load repair.
@MainActor
final class CanvasReviewFixTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
    }

    private func pid(_ n: Int) -> PaneID {
        PaneID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
    }

    // MARK: - focus() re-points maximize (no typing into an invisible pane)

    func testFocusWhileMaximizedRepointsMaximizeToTheFocusedPane() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.focusedPane)
        store.addPane(kind: .terminal) // pane b, focused
        let b = try XCTUnwrap(store.focusedPane)
        XCTAssertNotEqual(a, b)

        store.focus(a)
        store.toggleZoom() // maximize a
        XCTAssertEqual(store.workspace.maximizedPane, a)

        store.focus(b) // ⌘K-style jump to b while a is maximized
        XCTAssertEqual(store.focusedPane, b)
        XCTAssertEqual(
            store.workspace.maximizedPane,
            b,
            "maximize follows focus — the on-screen pane equals the focused one (no invisible-pane typing)",
        )
    }

    // MARK: - isPaneVisible: reported-vs-empty semantics

    func testIsPaneVisibleReportedVsEmptySemantics() {
        let p0 = PaneID(), p1 = PaneID()
        let store = makeStore(restoring: .make(panes: [
            (p0, PaneSpec(kind: .remoteGUI, title: "0")),
            (p1, PaneSpec(kind: .remoteGUI, title: "1")),
        ]))

        // Pre-report: falls back to isPaneOnCanvas (both true).
        XCTAssertTrue(store.isPaneVisible(p0))
        XCTAssertTrue(store.isPaneVisible(p1))

        // Reported with only p0 in the viewport → p1 is off-screen (false).
        store.updateViewportMembership([p0])
        XCTAssertTrue(store.isPaneVisible(p0))
        XCTAssertFalse(store.isPaneVisible(p1), "an off-viewport pane is not visible once membership is reported")

        // Reported EMPTY (panned into the void) → BOTH off-screen (not the pre-report fallback).
        store.updateViewportMembership([])
        XCTAssertFalse(store.isPaneVisible(p0), "reported-empty means nothing on screen — release, do not keep")
        XCTAssertFalse(store.isPaneVisible(p1))

        // Cleared (canvas disappeared → compact flip) → fallback restored.
        store.clearViewportMembership()
        XCTAssertTrue(store.isPaneVisible(p0), "after clear, the compact fallback to isPaneOnCanvas is restored")

        // A pane no longer on the canvas is never visible (the on-canvas guard).
        store.closePane(p0)
        XCTAssertFalse(store.isPaneVisible(p0), "p0 is no longer on the canvas")
    }

    // MARK: - camera / coordinate sanitation

    func testCanvasCameraSanitizedCollapsesNonFinite() {
        let nan = CanvasCamera(origin: CGPoint(x: CGFloat.nan, y: 50)).sanitized()
        XCTAssertEqual(nan.origin, CGPoint(x: 0, y: 50))
        let inf = CanvasCamera(origin: CGPoint(x: CGFloat.infinity, y: -CGFloat.infinity)).sanitized()
        XCTAssertEqual(inf.origin, CGPoint.zero)
        // Extreme-but-finite is clamped to the coordinate bound.
        let huge = CanvasCamera(origin: CGPoint(x: 1e300, y: -1e300)).sanitized()
        XCTAssertEqual(huge.origin, CGPoint(x: Canvas.coordinateBound, y: -Canvas.coordinateBound))
    }

    func testCameraSettersSanitize() {
        let canvas = Canvas(items: [CanvasItem(
            id: pid(1),
            spec: PaneSpec(kind: .terminal, title: "t"),
            frame: CGRect(x: 0, y: 0, width: 640, height: 420),
            z: 0,
        )])
        XCTAssertEqual(
            canvas.camera(CanvasCamera(origin: CGPoint(x: CGFloat.nan, y: CGFloat.nan))).camera.origin,
            .zero,
        )
        XCTAssertTrue(canvas.panned(by: CGSize(width: CGFloat.infinity, height: 0)).camera.origin.x.isFinite)
    }

    /// Extreme-but-finite item coords decode CLAMPED, so a Center-on-All bbox union cannot overflow to
    /// inf (which would make every subsequent save throw and silently stop persistence).
    func testExtremeItemsDecodeClampedSoCenterOnAllStaysFinite() throws {
        let a = pid(1), b = pid(2)
        let json = """
        {
          "items": [
            { "id": { "raw": "\(a.raw.uuidString)" }, "z": 0,
              "frame": { "origin": {"x": 1e308, "y": 0}, "size": {"width": 640, "height": 420} },
              "spec": { "kind": "terminal", "title": "a" } },
            { "id": { "raw": "\(b.raw.uuidString)" }, "z": 1,
              "frame": { "origin": {"x": -1e308, "y": 0}, "size": {"width": 640, "height": 420} },
              "spec": { "kind": "terminal", "title": "b" } }
          ]
        }
        """
        let canvas = try JSONDecoder().decode(Canvas.self, from: Data(json.utf8))
        for f in canvas.items.map(\.frame) {
            XCTAssertTrue(
                f.origin.x.isFinite && abs(f.origin.x) <= Canvas.coordinateBound,
                "item origin clamped finite",
            )
        }
        let centered = canvas.centeredOnAll(viewport: CGSize(width: 1280, height: 800))
        XCTAssertTrue(
            centered.camera.origin.x.isFinite && centered.camera.origin.y.isFinite,
            "Center-on-All over clamped items yields a finite camera (no inf overflow → save never throws)",
        )
    }

    // MARK: - dangling maximizedPane repair on load

    func testLoadRepairsDanglingMaximizedPane() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasReviewFixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)

        let real = PaneID()
        // Dangling maximizedPane — a pane not on the canvas.
        let workspace = Workspace.make(
            panes: [(real, PaneSpec(kind: .terminal, title: "A"))],
            focused: real,
            maximized: PaneID(),
        )
        try persistence.save(workspace)

        let loaded = persistence.load()
        XCTAssertNil(loaded.maximizedPane, "a dangling maximizedPane is cleared on load (symmetric with focus repair)")
        XCTAssertEqual(loaded.focusedPane, real)
    }
}
