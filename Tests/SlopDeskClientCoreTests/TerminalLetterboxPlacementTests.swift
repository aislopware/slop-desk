// TerminalLetterboxPlacementTests — the phone letterbox's OPTIONAL half.
//
// `TerminalGridFitTests` pins ``TerminalLetterbox/fit(cols:rows:cellWidth:cellHeight:in:)``, the
// arithmetic. What this pins is the composition on top of it — the one the iOS leaf container was
// computing inside a `some View`, where the only test that could reach it was an iOS render.
//
// ITS WHOLE JOB IS THE DEGRADE. Three inputs can each be missing for a legitimate reason — the host
// has not published a grid yet, the surface has not measured a cell yet, the container has no area
// yet — and in every one of those cases the answer is `nil`, which the view reads as "draw the
// surface full-bleed". A `?? 0` anywhere on this path is a zero-sized terminal, not a fallback.
//
// The NATURAL size travels with the fit because the renderer is sized at the grid's natural point
// size and SCALED into the fit — sizing it to the fit rect directly would re-derive a different
// grid inside the renderer and start a reflow fight with the host.
//
// Plain separate `*` (never `addingProduct`/`fma`), per CLAUDE.md §2.

import CoreGraphics
import SlopDeskTerminal
import XCTest

final class TerminalLetterboxPlacementTests: XCTestCase {
    /// A grid too wide for the container is scaled to fit, and the NATURAL size it is scaled FROM
    /// comes back with it: `cols × cellWidth` by `rows × cellHeight`, untouched by the scale.
    func testThePlacementCarriesTheNaturalSizeAlongsideTheFit() throws {
        let placement = try XCTUnwrap(TerminalLetterbox.placement(
            grid: (cols: 120, rows: 40),
            cellSize: CGSize(width: 8, height: 16),
            in: CGSize(width: 480, height: 1280),
        ))

        XCTAssertEqual(placement.natural, CGSize(width: 960, height: 640))
        XCTAssertEqual(placement.fit.scale, 0.5, accuracy: 1e-9, "the width ratio is the tighter constraint")
        XCTAssertEqual(
            placement.fit, try XCTUnwrap(TerminalLetterbox.fit(
                cols: 120, rows: 40, cellWidth: 8, cellHeight: 16,
                in: CGSize(width: 480, height: 1280),
            )),
            "the composition must not re-derive the fit differently from the fit itself",
        )
    }

    /// THE DEGRADE, one missing input at a time. Each of these is a real beat in a pane's life, not a
    /// defensive branch, and `nil` is what the view reads as full-bleed.
    func testEveryMissingInputDegradesToNothing() {
        XCTAssertNil(
            TerminalLetterbox.placement(
                grid: nil, cellSize: CGSize(width: 8, height: 16), in: CGSize(width: 480, height: 640),
            ),
            "the host has not published a resolved grid yet",
        )
        XCTAssertNil(
            TerminalLetterbox.placement(
                grid: (cols: 80, rows: 24), cellSize: nil, in: CGSize(width: 480, height: 640),
            ),
            "the surface has not measured a cell yet",
        )
        XCTAssertNil(
            TerminalLetterbox.placement(
                grid: (cols: 80, rows: 24),
                cellSize: CGSize(width: 8, height: 16),
                in: .zero,
            ),
            "a container with no area places nothing",
        )
    }
}
