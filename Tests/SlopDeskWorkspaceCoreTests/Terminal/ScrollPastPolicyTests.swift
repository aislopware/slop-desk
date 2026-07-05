import XCTest
@testable import SlopDeskWorkspaceCore

/// E8 WI-12 (I14/I15, ES-E8-5): pins the pure ``ScrollPastPolicy`` — the testable heart of the
/// "Scroll Past Last Line" / "Scroll Past First Line" overscroll. The GUI surface (`GhosttyTerminalView`,
/// compile-only behind `#if canImport(CGhostty)`) only documents the deferred RENDERING ceiling (no
/// libghostty viewport hook), so the anchor arithmetic + the alt-screen suppression gate are pinned here.
///
/// None of these assertions is tautological — each expected anchor is the SPEC value hand-computed from the
/// `spec/terminal-features__scroll.md` description (e.g. "the bottom-most content row lands at the viewport
/// top" ⇒ `top == contentRows − 1`), not the function's own derivation. A naive implementation fails a
/// specific case: one that dropped the alt-screen gate fails ``testAltScreenSuppressesEveryMode``; one that
/// clamped overscroll to `contentRows − viewportRows` (so content that fits the viewport could not float up)
/// fails ``testLastLineWithContentOverscrollsEvenWhenContentFits``; one that confused the cursor anchor with
/// the last-content-row anchor fails ``testCursorLineUsesCursorRowNotLastContentRow``.
final class ScrollPastPolicyTests: XCTestCase {
    // A representative "cursor at the bottom of a long buffer" geometry: 100 content rows in a 24-row
    // viewport, cursor on the last row. normalMaxTop = max(0, 100 − 24) = 76.
    private let contentRows = 100
    private let viewportRows = 24
    private let normalMaxTop = 76

    // MARK: Scroll Past Last Line (the max-top anchor, blank below)

    /// Disabled (the default) → `nil`: clamp at the buffer bottom, no overscroll. Swept across geometries so a
    /// regression that returned a stray anchor for the default fails here.
    func testDisabledClampsToNil() {
        for cursor in [0, 50, 99] {
            XCTAssertNil(
                ScrollPastPolicy.targetTopRow(
                    mode: .disabled,
                    contentRows: contentRows,
                    viewportRows: viewportRows,
                    cursorRow: cursor,
                    isAlternateScreen: false,
                ),
                "Scroll-Past-Last disabled must clamp (nil) — cursor=\(cursor)",
            )
        }
    }

    /// "Last Line With Content": the bottom-most content row lands at the viewport TOP ⇒ `top == contentRows − 1`.
    func testLastLineWithContentAnchorsLastRowAtTop() {
        XCTAssertEqual(
            ScrollPastPolicy.targetTopRow(
                mode: .lastLineWithContent,
                contentRows: contentRows,
                viewportRows: viewportRows,
                cursorRow: 99,
                isAlternateScreen: false,
            ),
            contentRows - 1, // 99
        )
    }

    /// "Last Line In Middle": the bottom-most content row lands at the vertical CENTRE (offset viewportRows/2
    /// from the top) ⇒ `top == (contentRows − 1) − viewportRows/2 == 99 − 12 == 87`. Strictly between the
    /// normal clamp (76) and the with-content anchor (99) — the in-between ordering the spec implies.
    func testLastLineInMiddleAnchorsLastRowAtCentre() throws {
        let anchor = try XCTUnwrap(ScrollPastPolicy.targetTopRow(
            mode: .lastLineInMiddle,
            contentRows: contentRows,
            viewportRows: viewportRows,
            cursorRow: 99,
            isAlternateScreen: false,
        ))
        XCTAssertEqual(anchor, 87)
        XCTAssertGreaterThan(anchor, normalMaxTop, "middle must overscroll past the normal clamp")
        XCTAssertLessThan(anchor, contentRows - 1, "middle must sit below the with-content anchor")
    }

    /// "Cursor Line": the cursor row lands at the TOP, even on a blank line. With the cursor NOT on the last
    /// content row (95 vs 99), the anchor must be the CURSOR row, distinct from the with-content anchor — the
    /// case that catches an implementation conflating the two.
    func testCursorLineUsesCursorRowNotLastContentRow() {
        let cursorRow = 95
        let anchor = ScrollPastPolicy.targetTopRow(
            mode: .cursorLine,
            contentRows: contentRows,
            viewportRows: viewportRows,
            cursorRow: cursorRow,
            isAlternateScreen: false,
        )
        XCTAssertEqual(anchor, cursorRow, "cursor-line anchors the cursor row")
        XCTAssertNotEqual(anchor, contentRows - 1, "cursor-line must NOT collapse to the last-content-row anchor")
    }

    /// "Last Line With Content" must overscroll even when ALL content fits inside the viewport (the design intent:
    /// only the prompt floats at the top, blank below). 5 rows in a 24-row viewport: normalMaxTop = 0, but the
    /// anchor is `contentRows − 1 == 4`. A naive `contentRows − viewportRows` clamp would yield 0 and FAIL.
    func testLastLineWithContentOverscrollsEvenWhenContentFits() {
        XCTAssertEqual(
            ScrollPastPolicy.targetTopRow(
                mode: .lastLineWithContent,
                contentRows: 5,
                viewportRows: 24,
                cursorRow: 4,
                isAlternateScreen: false,
            ),
            4,
            "with a 5-row buffer the last row (index 4) still floats to the top",
        )
    }

    /// The overscroll anchor never drops BELOW the normal clamp: "Last Line In Middle" on a tiny buffer (5 rows
    /// in a 24-row viewport) would compute `4 − 12 == −8`, but middle overscroll only adds blank BELOW, so it
    /// clamps up to normalMaxTop (0). Catches a missing ordered-max clamp.
    func testMiddleNeverDropsBelowNormalClamp() {
        XCTAssertEqual(
            ScrollPastPolicy.targetTopRow(
                mode: .lastLineInMiddle,
                contentRows: 5,
                viewportRows: 24,
                cursorRow: 4,
                isAlternateScreen: false,
            ),
            0, // == normalMaxTop for this geometry; no overscroll possible
        )
    }

    /// The alt-screen suppression (ES-E8-5): EVERY mode returns `nil` while a full-screen TUI owns the screen,
    /// so vim/htop/less keep their own bottom edge. The load-bearing gate — a missing `isAlternateScreen`
    /// guard fails here on the enabled modes.
    func testAltScreenSuppressesEveryMode() {
        for mode in ScrollPastLast.allCases {
            XCTAssertNil(
                ScrollPastPolicy.targetTopRow(
                    mode: mode,
                    contentRows: contentRows,
                    viewportRows: viewportRows,
                    cursorRow: 99,
                    isAlternateScreen: true,
                ),
                "alt-screen must suppress overscroll for mode \(mode)",
            )
        }
    }

    /// A degenerate empty buffer → `nil` (clamp) for every enabled mode: no content to anchor against.
    func testEmptyBufferClampsToNil() {
        for mode in ScrollPastLast.allCases {
            XCTAssertNil(
                ScrollPastPolicy.targetTopRow(
                    mode: mode,
                    contentRows: 0,
                    viewportRows: viewportRows,
                    cursorRow: 0,
                    isAlternateScreen: false,
                ),
                "an empty buffer must clamp (nil) for mode \(mode)",
            )
        }
    }

    // MARK: Scroll Past First Line (the min-top anchor, blank above)

    /// First-line disabled (the default) → `nil`: clamp at the scrollback top.
    func testFirstLineDisabledClampsToNil() {
        XCTAssertNil(
            ScrollPastPolicy.minTopRow(
                mode: .disabled,
                lastLineMode: .lastLineWithContent,
                contentRows: contentRows,
                viewportRows: viewportRows,
                isAlternateScreen: false,
            ),
        )
    }

    /// "First Line With Content": the topmost history row (index 0) lands at the viewport BOTTOM (offset
    /// viewportRows − 1) ⇒ `top == −(viewportRows − 1) == −23`. The min-top goes negative (blank above).
    func testFirstLineWithContentAnchorsFirstRowAtBottom() {
        XCTAssertEqual(
            ScrollPastPolicy.minTopRow(
                mode: .firstLineWithContent,
                lastLineMode: .disabled,
                contentRows: contentRows,
                viewportRows: viewportRows,
                isAlternateScreen: false,
            ),
            -(viewportRows - 1), // −23
        )
    }

    /// "First Line In Middle": the topmost history row lands at the vertical CENTRE ⇒ `top == −(viewportRows/2)
    /// == −12`.
    func testFirstLineInMiddleAnchorsFirstRowAtCentre() {
        XCTAssertEqual(
            ScrollPastPolicy.minTopRow(
                mode: .firstLineInMiddle,
                lastLineMode: .disabled,
                contentRows: contentRows,
                viewportRows: viewportRows,
                isAlternateScreen: false,
            ),
            -(viewportRows / 2), // −12
        )
    }

    /// "Same as Scroll Past Last Line" mirrors the bottom knob into the symmetric top mode so only one knob is
    /// tuned: with-content ⇒ first-line-with-content (−23); in-middle ⇒ first-line-in-middle (−12); cursor-line
    /// ⇒ the closest top analog first-line-with-content (−23, no cursor at the top of history); disabled ⇒ nil.
    func testSameAsLastMirrorsTheBottomSetting() {
        XCTAssertEqual(
            ScrollPastPolicy.minTopRow(
                mode: .sameAsLast,
                lastLineMode: .lastLineWithContent,
                contentRows: contentRows,
                viewportRows: viewportRows,
                isAlternateScreen: false,
            ),
            -(viewportRows - 1), // −23, mirrors with-content
        )
        XCTAssertEqual(
            ScrollPastPolicy.minTopRow(
                mode: .sameAsLast,
                lastLineMode: .lastLineInMiddle,
                contentRows: contentRows,
                viewportRows: viewportRows,
                isAlternateScreen: false,
            ),
            -(viewportRows / 2), // −12, mirrors in-middle
        )
        XCTAssertEqual(
            ScrollPastPolicy.minTopRow(
                mode: .sameAsLast,
                lastLineMode: .cursorLine,
                contentRows: contentRows,
                viewportRows: viewportRows,
                isAlternateScreen: false,
            ),
            -(viewportRows - 1), // −23, cursor-line has no top analog → with-content
        )
        XCTAssertNil(
            ScrollPastPolicy.minTopRow(
                mode: .sameAsLast,
                lastLineMode: .disabled,
                contentRows: contentRows,
                viewportRows: viewportRows,
                isAlternateScreen: false,
            ),
            "same-as-last mirroring a disabled bottom must itself clamp (nil)",
        )
    }

    /// First-line overscroll is suppressed on the alternate screen too (symmetric with the bottom gate).
    func testFirstLineAltScreenSuppressesEveryMode() {
        for mode in ScrollPastFirst.allCases {
            XCTAssertNil(
                ScrollPastPolicy.minTopRow(
                    mode: mode,
                    lastLineMode: .lastLineWithContent,
                    contentRows: contentRows,
                    viewportRows: viewportRows,
                    isAlternateScreen: true,
                ),
                "alt-screen must suppress first-line overscroll for mode \(mode)",
            )
        }
    }
}
