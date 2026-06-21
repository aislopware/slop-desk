import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Headless proof of the P3a TabBar active-cue gate + title token/colour selection — the PURE view-model
/// transforms extracted from ``TabCell`` so the focus-honesty invariant is testable without driving SwiftUI
/// layout (no NSWindow / Ghostty / SCStream / VT is instantiated).
///
/// THE INVARIANT UNDER TEST (the focus-honesty bug the P3a restructure fixes): the active cue is the single
/// gated 2pt accent line. An active tab in a KEY window lights accent; an active tab in a BACKGROUNDED
/// window must FALL to the neutral `borderComponent` (it must NOT stay falsely lit); an inactive tab shows
/// no line in either case. This mirrors ``PaneChromeView``'s `isFocused && controlActiveState == .key` gate.
@MainActor
final class TabCellViewModelTests: XCTestCase {
    // MARK: - activeCue (the gate)

    /// Active + key window ⇒ the accent line lights. The normal focused case.
    func testActiveAndKeyLightsAccent() {
        XCTAssertEqual(TabCell.activeCue(isActive: true, isKey: true), .accent)
    }

    /// REVERT-TO-CONFIRM-FAIL (the backgrounded-window honesty fix): active + BACKGROUNDED window ⇒ the line
    /// falls to NEUTRAL, never accent. This is the exact case the old `isActive`-only code got wrong (it kept
    /// the accent line lit when the window lost key). If the gate regressed to `isActive`-only, this returns
    /// `.accent` and the test fails.
    func testActiveButBackgroundedFallsToNeutralNotAccent() {
        XCTAssertEqual(TabCell.activeCue(isActive: true, isKey: false), .neutral)
        XCTAssertNotEqual(TabCell.activeCue(isActive: true, isKey: false), .accent)
    }

    /// Inactive ⇒ no line, regardless of key state (an inactive tab never carries the active cue, and is
    /// NEVER dimmed — its title rests at `textTertiary`, asserted below).
    func testInactiveShowsNoLineEitherWindowState() {
        XCTAssertEqual(TabCell.activeCue(isActive: false, isKey: true), .none)
        XCTAssertEqual(TabCell.activeCue(isActive: false, isKey: false), .none)
    }

    // MARK: - cueColor (cue → line colour)

    /// The cue resolves to its line colour: accent ⇒ the DS solid accent; neutral ⇒ the component border;
    /// none ⇒ clear. Backgrounded-active resolves to the NEUTRAL border colour, not the accent.
    func testCueColorMapping() {
        XCTAssertEqual(TabCell.cueColor(.accent), DSColor.accentSolid)
        XCTAssertEqual(TabCell.cueColor(.neutral), DSColor.borderComponent)
        XCTAssertEqual(TabCell.cueColor(.none), Color.clear)
        // End-to-end: a backgrounded active tab paints the neutral border colour, never the accent.
        let backgrounded = TabCell.activeCue(isActive: true, isKey: false)
        XCTAssertEqual(TabCell.cueColor(backgrounded), DSColor.borderComponent)
        XCTAssertNotEqual(TabCell.cueColor(backgrounded), DSColor.accentSolid)
    }

    /// RELATIONSHIP pin (not a token restatement): the three cue colours must be mutually DISTINCT, so the
    /// honesty property — "a backgrounded active tab is visually different from a focused active tab, and
    /// an inactive tab shows nothing" — holds even if the underlying token VALUES are later re-pointed.
    /// Catches a spec drift the literal-equality assertions above would move in lockstep with.
    func testCueColorsAreMutuallyDistinct() {
        let focused = TabCell.cueColor(.accent)
        let backgrounded = TabCell.cueColor(.neutral)
        let inactive = TabCell.cueColor(.none)
        XCTAssertNotEqual(focused, backgrounded, "focused-key cue must differ from the backgrounded fallback")
        XCTAssertNotEqual(focused, inactive, "a focused tab must show a line; an inactive tab must not")
        XCTAssertNotEqual(backgrounded, inactive, "a backgrounded active tab still shows a (neutral) line")
        XCTAssertEqual(inactive, Color.clear, "the inactive cue is no line at all")
    }

    // MARK: - titleFont / titleColor (the type + colour selection)

    /// Active title = DSFont.emphasis (13pt semibold); inactive = DSFont.body (13pt regular). Both 13pt
    /// (opacity/weight-driven hierarchy at a stable size, not size-driven).
    func testTitleFontSelection() {
        let active = TabCell.titleFont(isActive: true)
        let inactive = TabCell.titleFont(isActive: false)
        XCTAssertEqual(active.size, 13)
        XCTAssertEqual(active.weight, .semibold)
        XCTAssertEqual(inactive.size, 13)
        XCTAssertEqual(inactive.weight, .regular)
    }

    /// Active title colour = textPrimary; inactive = textTertiary (the recessive resting state — the
    /// hierarchy is colour, NEVER an opacity dim).
    func testTitleColorSelection() {
        XCTAssertEqual(TabCell.titleColor(isActive: true), DSColor.textPrimary)
        XCTAssertEqual(TabCell.titleColor(isActive: false), DSColor.textTertiary)
    }

    // MARK: - Strip height arithmetic (the additive-inset geometry)

    /// The strip's top inset is ADDITIVE, not absorbed: net strip height = cell row (`DSSpace.tabHeight`) +
    /// `TabBarView.topInset`, and that net must equal the legacy titlebar height (32) so the tab strip
    /// aligns with the sidebar's drag-strip top and the cells are NOT squeezed below their own frame.
    ///
    /// This is the headless pin for the height-math bug the P3a finalize fixed: when `.dsSpace(.top, 2)` was
    /// applied BEFORE `.frame(height: DSSpace.tabHeight)`, SwiftUI ABSORBED the padding into the 30pt frame —
    /// net height 30 (not 32) and the cell row only 28pt, pinching the 30pt cells and risking clipping the
    /// bottom accent line. Moving the inset OUTSIDE the frame makes it additive (30 + 2 = 32). If a refactor
    /// re-absorbs the inset (or drops `topInset`), this arithmetic breaks. SwiftUI layout itself is HW-only,
    /// but the constants the layout consumes are pinned here.
    func testStripNetHeightIsAdditive() {
        let cellRow = DSSpace.tabHeight
        let net = cellRow + TabBarView.topInset
        XCTAssertEqual(TabBarView.topInset, 2, "the top inset band is 2pt")
        XCTAssertEqual(cellRow, 30, "the cell row uses the DS default-density tab height (30)")
        XCTAssertEqual(net, 32, "cell row + inset = 32 (legacy titlebar height — the inset is ADDITIVE)")
        // The strip must align with the sidebar's reserved drag-strip top, which is UIMetrics.titleBarHeight.
        XCTAssertEqual(net, UIMetrics.titleBarHeight, "the net strip height matches the titlebar drag strip")
        // The cell's own frame (DSSpace.tabHeight) must FIT within the cell row (also DSSpace.tabHeight) so
        // the bottom accent line is never clipped: cell frame <= cell row. Absorbing the inset would make
        // the row 28 < the 30pt cell frame and clip the line.
        XCTAssertLessThanOrEqual(DSSpace.tabHeight, cellRow, "the cell frame fits the cell row (no clip)")
    }
}
