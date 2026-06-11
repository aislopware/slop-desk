import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pins that the canvas reuses ``FocusResolver`` verbatim (docs/30 §3): ``Canvas/solvedLayout()``
/// produces the items' canvas-space frames (camera-independent), and `FocusResolver.neighbor` /
/// `cycle` resolve directional + cyclic focus against them exactly as they did for the tiling layout.
/// Off-viewport panes stay keyboard-navigable because the layout is canvas-space, not screen-space.
final class CanvasFocusTests: XCTestCase {

    private func pid(_ n: Int) -> PaneID {
        PaneID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
    }
    private func item(_ n: Int, _ frame: CGRect, z: Int) -> CanvasItem {
        CanvasItem(id: pid(n), spec: PaneSpec(kind: .terminal, title: "p\(n)"), frame: frame, z: z)
    }

    /// A 2×2 grid of panes; directional focus lands on the correct geometric neighbour.
    func testDirectionalFocusOverCanvasFrames() {
        // (1) top-left, (2) top-right, (3) bottom-left, (4) bottom-right
        let canvas = Canvas(items: [
            item(1, CGRect(x: 0,   y: 0,   width: 400, height: 300), z: 0),
            item(2, CGRect(x: 500, y: 0,   width: 400, height: 300), z: 1),
            item(3, CGRect(x: 0,   y: 400, width: 400, height: 300), z: 2),
            item(4, CGRect(x: 500, y: 400, width: 400, height: 300), z: 3),
        ])
        let solved = canvas.solvedLayout()

        XCTAssertEqual(FocusResolver.neighbor(of: pid(1), .right, in: solved), pid(2), "right of TL = TR")
        XCTAssertEqual(FocusResolver.neighbor(of: pid(1), .down, in: solved), pid(3), "down of TL = BL")
        XCTAssertEqual(FocusResolver.neighbor(of: pid(4), .left, in: solved), pid(3), "left of BR = BL")
        XCTAssertEqual(FocusResolver.neighbor(of: pid(4), .up, in: solved), pid(2), "up of BR = TR")
        XCTAssertNil(FocusResolver.neighbor(of: pid(1), .left, in: solved), "nothing left of the leftmost")
    }

    /// The directional layout is CAMERA-INDEPENDENT: an item far off the current viewport is still a
    /// valid focus target (the solved frames are canvas-space, not screen-space).
    func testFocusIsCameraIndependent() {
        let canvas = Canvas(
            items: [
                item(1, CGRect(x: 0, y: 0, width: 400, height: 300), z: 0),
                item(2, CGRect(x: 5000, y: 0, width: 400, height: 300), z: 1),   // far off-viewport
            ],
            camera: CanvasCamera(origin: CGPoint(x: 9999, y: 9999))             // panned away from both
        )
        let solved = canvas.solvedLayout()
        XCTAssertEqual(FocusResolver.neighbor(of: pid(1), .right, in: solved), pid(2),
                       "an off-viewport pane is still keyboard-navigable (canvas-space layout)")
    }

    /// `.next`/`.previous` cycle through the canvas z-order with wrap (the carousel + ⌘]/⌘[ path).
    func testCycleOverCanvasIDs() {
        let canvas = Canvas(items: [
            item(1, CGRect(x: 0, y: 0, width: 200, height: 200), z: 0),
            item(2, CGRect(x: 0, y: 0, width: 200, height: 200), z: 1),
            item(3, CGRect(x: 0, y: 0, width: 200, height: 200), z: 2),
        ])
        let ids = canvas.allIDs()
        XCTAssertEqual(FocusResolver.cycle(ids, from: pid(1), forward: true), pid(2))
        XCTAssertEqual(FocusResolver.cycle(ids, from: pid(3), forward: true), pid(1), "wraps at the end")
        XCTAssertEqual(FocusResolver.cycle(ids, from: pid(1), forward: false), pid(3), "wraps backward at the start")
    }
}
