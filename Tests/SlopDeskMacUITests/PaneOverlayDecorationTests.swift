// PaneOverlayDecorationTests proves the three AppKit terminal-surface decorations (docs/56 wave R,
// batch R3) keep the promises their SwiftUI halves make and a compiler cannot check.
//
// 1. THEY ARE ALL FLIPPED. `TerminalCellMetrics` answers in the surface's TOP-LEFT-origin space —
//    row 0 at the top, y growing downward — which is the space SwiftUI's `Canvas`/`offset` already
//    draw in, so the SwiftUI halves never had to say so and the ported headers are the only place it
//    is written down. An `NSView` is y-UP by default. A port that dropped `isFlipped` compiles, runs,
//    and draws every decoration mirrored about the viewport's middle: the vi block at the wrong row,
//    the underlines under the wrong text, and the landing flash on the bottom row of a pane whose
//    prompt libghostty-vt pinned at the top. Nothing crashes and nothing is empty, which is exactly the
//    kind of wrongness that survives a review.
//
// 2. THEY ARE ALL TRANSPARENT TO THE POINTER. These sit OVER a terminal that must keep every click —
//    select, ⌘click a link, right-click the context menu. `.allowsHitTesting(false)` is one modifier
//    in SwiftUI and an override here, which is precisely the kind of promise that survives a port by
//    luck. The link underline is the sharpest case: the renderer owns ⌘click, so an overlay that
//    answered the hit would make every underlined link unopenable while looking correct.
//
// 3. THE FLASH RESTS INVISIBLE. Its peak lives only in the decay animation's `fromValue`, so a
//    mounted overlay that has never seen a jump — and one whose fade was cut short — paints nothing.
//    A port that had put the peak in the layer's model opacity would leave an accent band stranded
//    over a pane's content on any torn-down or retargeted flash.
//
// 4. THE VI BLOCK'S EDGE STAYS INSIDE ITS CELL. SwiftUI's `.strokeBorder` strokes INWARD;
//    `NSBezierPath.stroke()` centres the line on the path. The inset is the whole difference between
//    a block exactly one glyph wide and one bleeding accent into the columns either side of it.
//
// Headless: `isFlipped`, `hitTest`, a layer's opacity and a rect inset all need no window (the
// hang-safety rule forbids an `NSWindow` in a test), and the models are built over a `nil` surface so
// no libghostty-vt / Metal / socket is touched.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class PaneOverlayDecorationTests: XCTestCase {
    /// All three decorations over one headless model, each named for the failure message. Built per
    /// test rather than shared so no assertion can be read as depending on another's mutation.
    private func decorations() -> [(name: String, view: NSView)] {
        let model = TerminalViewModel()
        return [
            ("prompt-jump flash", MacPromptJumpFlashOverlay(model: model)),
            ("link underline", MacLinkHighlightOverlay(model: model, cwd: nil)),
            ("vi block cursor", MacViCursorOverlay(model: model)),
        ]
    }

    func testEveryDecorationDrawsInTheCellGridsTopLeftOriginSpace() {
        for (name, view) in decorations() {
            XCTAssertTrue(
                view.isFlipped,
                "the \(name) overlay is y-UP — every cell rect it takes from TerminalCellMetrics is "
                    + "top-left-origin, so it now draws the viewport upside down",
            )
        }
    }

    func testEveryDecorationIsTransparentToThePointer() {
        for (name, view) in decorations() {
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
            XCTAssertNil(
                view.hitTest(NSPoint(x: 200, y: 120)),
                "a click in the middle of the \(name) overlay must reach the terminal under it — "
                    + "the renderer owns select, ⌘click and the context menu",
            )
        }
    }

    func testTheFlashRestsInvisible() {
        let overlay = MacPromptJumpFlashOverlay(model: TerminalViewModel())
        XCTAssertEqual(
            overlay.layer?.opacity, 0,
            "the landing flash mounted VISIBLE — its peak belongs to the decay animation alone, or a "
                + "cancelled fade strands an accent band over the pane",
        )
    }

    func testTheViBlocksEdgeStaysInsideItsOwnCell() {
        // A plausible cell: an 8×17pt monospace box at column 5, row 3 of a laid-out grid.
        let cell = CGRect(x: 40, y: 51, width: 8, height: 17)
        let border = MacViCursorOverlay.borderRect(in: cell)
        // What the stroke actually covers: the border path grown by half a line width on each side.
        let half = ViCursorGeometry.strokeWidth / 2
        XCTAssertEqual(
            border.insetBy(dx: -half, dy: -half), cell,
            "the vi block's edge is centred on the cell boundary instead of stroked inward — it "
                + "smears accent into the columns either side of the glyph it is supposed to wear",
        )
    }
}
#endif
