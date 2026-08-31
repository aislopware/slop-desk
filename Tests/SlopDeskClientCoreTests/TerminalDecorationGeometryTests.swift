// TerminalDecorationGeometryTests — the two cell-grid decorations, finally reachable.
//
// Neither of these rules had a test before, and not because nobody wrote one: the ⌘-hold underline's
// arm predicate was a six-clause `if` in a `body` (one clause of which read a user SETTING), and its
// path math lived inside a `Canvas` closure, which is a place no test can call at all. The vi block
// cursor's visibility + span was the same shape one file over. Both are values now, so both are
// pinned here.
//
// The family's law is what these mostly assert: ABSENT, never wrong. Every input can legitimately be
// missing, and in each case the honest answer is that nothing is drawn.
//
// Headless — no surface, no libghostty-vt, no window (CLAUDE.md rule #6). Cases are hand-enumerated
// rather than derived from the expressions under test, so none of this is tautological.

import CoreGraphics
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

final class LinkUnderlineGeometryTests: XCTestCase {
    private let metrics = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 20, rows: 5)

    private func link(row: Int, from colStart: Int, to colEnd: Int) -> DetectedLink {
        DetectedLink(
            row: row, colStart: colStart, colEnd: colEnd, kind: .absolutePath,
            raw: "/a/b", resolvedAbsolute: "/a/b",
        )
    }

    /// THE ARM PREDICATE. Three independent gates, each answering a different question, and each one
    /// alone is enough to keep the underline off: the ⌘-hold mirror (false forever on a phone), the
    /// user's link-detection setting, and the alt-screen TUI gate.
    func testTheUnderlineArmsOnlyUnderHeldCommandWithDetectionOnOutsideATUI() {
        XCTAssertTrue(
            LinkUnderlineGeometry.isArmed(
                highlightActive: true, detectionEnabled: true, isAlternateScreen: false,
            ),
        )
        XCTAssertFalse(
            LinkUnderlineGeometry.isArmed(
                highlightActive: false, detectionEnabled: true, isAlternateScreen: false,
            ),
            "⌘ is not held — and on iOS it never is, which is why this overlay needs no platform gate",
        )
        XCTAssertFalse(
            LinkUnderlineGeometry.isArmed(
                highlightActive: true, detectionEnabled: false, isAlternateScreen: false,
            ),
            "the user turned link detection off",
        )
        XCTAssertFalse(
            LinkUnderlineGeometry.isArmed(
                highlightActive: true, detectionEnabled: true, isAlternateScreen: true,
            ),
            "a full-screen application owns its own cells — underlining vim's status line is a wrong mark",
        )
    }

    /// THE PATH: the stroke is a horizontal hairline one point ABOVE the cell's bottom edge, spanning
    /// exactly the clamped cell rect. This is the arithmetic that used to live inside a `Canvas`.
    func testTheStrokeSitsOneShortOfTheRowBoundary() {
        let rect = CGRect(x: 16, y: 32, width: 24, height: 16)
        let stroke = LinkUnderlineGeometry.stroke(under: rect)

        XCTAssertEqual(stroke.start.y, 47, "baseline = maxY − 1, so the line belongs to the glyph")
        XCTAssertEqual(stroke.end.y, stroke.start.y, "an underline is horizontal")
        XCTAssertEqual(stroke.start.x, 16)
        XCTAssertEqual(stroke.end.x, 40)
        XCTAssertEqual(stroke.lineWidth, 1)
    }

    /// A span is mapped through the grid CLAMP, so a soft-wrap-shifted link is trimmed to the grid
    /// edge and one that starts past it is dropped rather than painted in the void to the right.
    func testSpansAreClampedToTheVisibleGrid() {
        let strokes = LinkUnderlineGeometry.strokes(
            links: [link(row: 0, from: 16, to: 40), link(row: 1, from: 20, to: 30)],
            metrics: metrics,
        )

        XCTAssertEqual(strokes.count, 1, "the span starting AT the grid edge is dropped")
        XCTAssertEqual(strokes[0].start.x, 128, "16 cells × 8pt")
        XCTAssertEqual(strokes[0].end.x, 160, "trimmed to the 20-column grid, not 40 cells wide")
    }

    /// A surface with no measured cell yet draws nothing at all — the pre-layout beat is a moment
    /// with no honest answer, not a moment for zero-size strokes.
    func testDegenerateMetricsDrawNothing() {
        XCTAssertTrue(
            LinkUnderlineGeometry.strokes(
                links: [link(row: 0, from: 0, to: 4)],
                metrics: TerminalCellMetrics(cellWidth: 0, cellHeight: 0, cols: 20, rows: 5),
            ).isEmpty,
        )
    }
}

@MainActor
final class ViCursorGeometryTests: XCTestCase {
    private let metrics = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 20, rows: 5)

    /// THE WIDE-GLYPH SPAN RULE: `colEnd = col + width`, so a fullwidth CJK glyph wears a two-cell
    /// block instead of half a character.
    func testAWideGlyphGetsATwoCellBlock() throws {
        let narrow = try XCTUnwrap(ViCursorGeometry.rect(
            copyModeActive: true,
            cell: TerminalViewModel.ViCursorCell(col: 3, row: 2, width: 1),
            metrics: metrics,
        ))
        XCTAssertEqual(narrow, CGRect(x: 24, y: 32, width: 8, height: 16))

        let wide = try XCTUnwrap(ViCursorGeometry.rect(
            copyModeActive: true,
            cell: TerminalViewModel.ViCursorCell(col: 3, row: 2, width: 2),
            metrics: metrics,
        ))
        XCTAssertEqual(wide.width, 16, "a fullwidth glyph's block covers the whole character")
        XCTAssertEqual(wide.minX, narrow.minX, "…anchored at the same cell")
    }

    /// FOUR WAYS TO BE ABSENT, and all four are real states rather than defensive padding: copy mode
    /// is not armed, the model cleared the cursor because it scrolled off-viewport, the surface is a
    /// placeholder with no metrics, or the clamp rejects the span.
    func testEveryAbsentInputDrawsNothing() {
        let cell = TerminalViewModel.ViCursorCell(col: 3, row: 2, width: 1)

        XCTAssertNil(
            ViCursorGeometry.rect(copyModeActive: false, cell: cell, metrics: metrics),
            "copy mode is not armed",
        )
        XCTAssertNil(
            ViCursorGeometry.rect(copyModeActive: true, cell: nil, metrics: metrics),
            "the cursor scrolled off-viewport and the model cleared it — absent, never stale",
        )
        XCTAssertNil(
            ViCursorGeometry.rect(copyModeActive: true, cell: cell, metrics: nil),
            "a headless / placeholder surface has no cell metrics",
        )
        XCTAssertNil(
            ViCursorGeometry.rect(
                copyModeActive: true,
                cell: TerminalViewModel.ViCursorCell(col: 20, row: 0, width: 1),
                metrics: metrics,
            ),
            "a column at or past the grid edge is skipped, never painted in the void",
        )
    }
}
