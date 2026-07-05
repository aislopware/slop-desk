import CoreGraphics
import SlopDeskTerminal
import XCTest
@testable import SlopDeskWorkspaceCore

/// E19/A29 — pins the PURE window-sizing arithmetic (``WindowSizeMath``) + the ``WindowSizeMode`` enum and
/// its persisted-`Defaults` round-trip / repair. No `NSWindow` instantiation (hang-safe): the math is the
/// tested unit; the macOS glue (WI-4) is compiled + GUI-verified only.
@MainActor
final class WindowSizeMathTests: XCTestCase {
    /// The default cell advance used across the grid math (a typical monospace cell ≈ 8×16pt).
    private let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 80, rows: 24)

    /// A roomy display so the screen clamp is a no-op unless a test deliberately oversizes the content.
    private let bigScreen = CGRect(x: 0, y: 0, width: 5000, height: 5000)

    private let windowKeys = [
        SettingsKey.windowSizeKey,
        SettingsKey.windowColsKey,
        SettingsKey.windowRowsKey,
        SettingsKey.windowWidthPxKey,
        SettingsKey.windowHeightPxKey,
    ]

    override func setUp() { windowKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { windowKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    // MARK: gridContentSize

    /// A known cell × a known grid resolves to exactly `cols*cellW × rows*cellH` (8×16 → 80×24 = 640×384).
    /// Asserts against an INDEPENDENT hand-computed expectation, not the function's own derivation.
    func testGridContentSizeIsExactCellByGrid() {
        XCTAssertEqual(
            WindowSizeMath.gridContentSize(cols: 80, rows: 24, cell: cell),
            CGSize(width: 640, height: 384),
        )
        // A second cell metric proves it is not hard-coded to one size.
        let wideCell = TerminalCellMetrics(cellWidth: 10, cellHeight: 20, cols: 1, rows: 1)
        XCTAssertEqual(
            WindowSizeMath.gridContentSize(cols: 100, rows: 50, cell: wideCell),
            CGSize(width: 1000, height: 1000),
        )
    }

    /// A 0 / negative grid is clamped to the 1-cell floor BEFORE the multiply — never a 0-extent size.
    func testGridContentSizeClampsDegenerateGrid() {
        let zero = WindowSizeMath.gridContentSize(cols: 0, rows: -5, cell: cell)
        XCTAssertEqual(zero, CGSize(width: 8, height: 16), "0/negative cols/rows floor to 1 cell each")
    }

    // MARK: scalar clamps

    func testClampColsRowsFloorAndCap() {
        XCTAssertEqual(WindowSizeMath.clampCols(0), 1, "0 floors to 1")
        XCTAssertEqual(WindowSizeMath.clampCols(-7), 1, "negative floors to 1")
        XCTAssertEqual(WindowSizeMath.clampCols(80), 80, "an in-band value passes through")
        XCTAssertEqual(WindowSizeMath.clampCols(5000), 1000, "an over-large value caps at 1000")
        XCTAssertEqual(WindowSizeMath.clampRows(0), 1)
        XCTAssertEqual(WindowSizeMath.clampRows(24), 24)
        XCTAssertEqual(WindowSizeMath.clampRows(99999), 1000)
    }

    func testClampPxFloorAndCap() {
        XCTAssertEqual(WindowSizeMath.clampPx(0), 64, "0 floors to 64px")
        XCTAssertEqual(WindowSizeMath.clampPx(-100), 64, "negative floors to 64px")
        XCTAssertEqual(WindowSizeMath.clampPx(1000), 1000, "an in-band value passes through")
        XCTAssertEqual(WindowSizeMath.clampPx(99999), 16384, "an over-large value caps at 16384")
    }

    // MARK: clampToScreen

    /// An oversized content+chrome is shrunk so `content + chrome ≤ visible` (visible 1000×800, 28pt title
    /// chrome → content caps at 1000×772).
    func testClampToScreenShrinksOversized() {
        let clamped = WindowSizeMath.clampToScreen(
            CGSize(width: 2000, height: 2000),
            visible: CGRect(x: 0, y: 0, width: 1000, height: 800),
            chromeInsets: CGSize(width: 0, height: 28),
        )
        XCTAssertEqual(clamped, CGSize(width: 1000, height: 772))
    }

    /// A content size that already fits is returned untouched.
    func testClampToScreenLeavesFittingUntouched() {
        let clamped = WindowSizeMath.clampToScreen(
            CGSize(width: 640, height: 384),
            visible: CGRect(x: 0, y: 0, width: 1000, height: 800),
            chromeInsets: CGSize(width: 0, height: 28),
        )
        XCTAssertEqual(clamped, CGSize(width: 640, height: 384))
    }

    /// A tiny request floors at the sane minimum (200×120) — never a degenerate window.
    func testClampToScreenFloorsAtSaneMin() {
        let clamped = WindowSizeMath.clampToScreen(
            CGSize(width: 10, height: 10),
            visible: bigScreen,
            chromeInsets: .zero,
        )
        XCTAssertEqual(clamped, CGSize(width: 200, height: 120))
    }

    // MARK: resolvedContentSize

    /// `.remember` yields `nil` — the glue lets the autosaved frame stand (no explicit size).
    func testResolvedRememberIsNil() {
        XCTAssertNil(WindowSizeMath.resolvedContentSize(
            mode: .remember,
            cols: 80, rows: 24, widthPx: 1000, heightPx: 600,
            cell: cell, visible: bigScreen, chromeInsets: .zero, chromeOverhead: .zero,
        ))
    }

    /// `.grid` resolves to the (screen-clamped) grid content size.
    func testResolvedGridIsClampedGrid() {
        let size = WindowSizeMath.resolvedContentSize(
            mode: .grid,
            cols: 80, rows: 24, widthPx: 1000, heightPx: 600,
            cell: cell, visible: bigScreen, chromeInsets: .zero, chromeOverhead: .zero,
        )
        XCTAssertEqual(size, CGSize(width: 640, height: 384))
    }

    /// `.frame` resolves to the (screen-clamped) clamped pixel size.
    func testResolvedFrameIsClampedPixels() {
        let size = WindowSizeMath.resolvedContentSize(
            mode: .frame,
            cols: 80, rows: 24, widthPx: 1000, heightPx: 600,
            cell: cell, visible: bigScreen, chromeInsets: .zero, chromeOverhead: .zero,
        )
        XCTAssertEqual(size, CGSize(width: 1000, height: 600))
    }

    /// A 0-col grid / 0-px frame is clamped, never a 0-extent window (floors at the sane minimum).
    func testResolvedClampsDegenerateInputsNeverZero() {
        let grid = WindowSizeMath.resolvedContentSize(
            mode: .grid,
            cols: 0, rows: 0, widthPx: 0, heightPx: 0,
            cell: cell, visible: bigScreen, chromeInsets: .zero, chromeOverhead: .zero,
        )
        XCTAssertEqual(grid, CGSize(width: 200, height: 120), "a 0-col grid floors, never 0")
        let frame = WindowSizeMath.resolvedContentSize(
            mode: .frame,
            cols: 0, rows: 0, widthPx: 0, heightPx: 0,
            cell: cell, visible: bigScreen, chromeInsets: .zero, chromeOverhead: .zero,
        )
        XCTAssertEqual(frame, CGSize(width: 200, height: 120), "a 0-px frame floors, never 0")
    }

    // MARK: chromeOverhead (E19/A29 — grid sizes the TERMINAL, not the whole content view)

    /// `.grid` ADDS `chromeOverhead` (the revealed sidebar + shown inspector widths) to the grid extent so the
    /// resolved WINDOW content yields a TERMINAL of exactly cols×rows. 80×24 at 8×16 = 640×384 terminal; with a
    /// 220 sidebar + 240 inspector (460 wide) overhead the window content must be 1100×384. REVERT-TO-CONFIRM-
    /// FAIL: the pre-fix `resolvedContentSize` ignored the overhead and returned 640×384 — an 80-col grid then
    /// gave a terminal NARROWER than 80 cols (the sidebar ate into it). Asserts the hand-computed sum.
    func testGridAddsChromeOverheadSoTerminalIsExactGrid() {
        let size = WindowSizeMath.resolvedContentSize(
            mode: .grid,
            cols: 80, rows: 24, widthPx: 1000, heightPx: 600,
            cell: cell, visible: bigScreen, chromeInsets: .zero,
            chromeOverhead: CGSize(width: 460, height: 0),
        )
        XCTAssertEqual(size, CGSize(width: 1100, height: 384), "grid content = terminal grid + chrome overhead")
    }

    /// `.frame` IGNORES `chromeOverhead` — `window-width-px`/`window-height-px` are the explicit WHOLE-window
    /// pixel size, not a terminal extent. A non-zero overhead must not change the resolved 1000×600 frame.
    func testFrameIgnoresChromeOverhead() {
        let size = WindowSizeMath.resolvedContentSize(
            mode: .frame,
            cols: 80, rows: 24, widthPx: 1000, heightPx: 600,
            cell: cell, visible: bigScreen, chromeInsets: .zero,
            chromeOverhead: CGSize(width: 460, height: 99),
        )
        XCTAssertEqual(size, CGSize(width: 1000, height: 600), "frame is the whole-window px size; overhead unused")
    }

    // MARK: fallbackCell (E19/A29 — font-derived cell advance, NOT a hard 8×16)

    /// The default 13pt font derives ≈ 8×16pt — the old hard-coded fallback — so a default-font launch is
    /// unchanged. (The ratios are 8/13 × 16/13, so 13pt resolves EXACTLY to 8×16.)
    func testFallbackCellAtDefaultFontMatchesLegacyEightBySixteen() {
        let c = WindowSizeMath.fallbackCell(fontPointSize: 13)
        XCTAssertEqual(c.cellWidth, 8, accuracy: 0.0001)
        XCTAssertEqual(c.cellHeight, 16, accuracy: 0.0001)
    }

    /// A LARGER font scales the fallback cell proportionally — the bug the hard 8×16 caused (a 26pt font got an
    /// 8×16 cell → a grid window half the right size). 26pt = 2× the default ⇒ 16×32. Asserts the independent
    /// doubling, not the function's own multiply.
    func testFallbackCellScalesWithFontSize() {
        let c = WindowSizeMath.fallbackCell(fontPointSize: 26)
        XCTAssertEqual(c.cellWidth, 16, accuracy: 0.0001, "2× the default font ⇒ 2× the cell width")
        XCTAssertEqual(c.cellHeight, 32, accuracy: 0.0001, "2× the default font ⇒ 2× the cell height")
    }

    /// A 0 / negative / gigantic font size clamps into the 8…32 band (never a 0 or absurd cell) — validate-then-
    /// clamp, no trap. 0 floors to 8pt (→ 8×8/13 ≈ 4.92 wide); 999 caps to 32pt.
    func testFallbackCellClampsDegenerateFontSize() {
        let zero = WindowSizeMath.fallbackCell(fontPointSize: 0)
        XCTAssertEqual(zero.cellWidth, 8 * WindowSizeMath.fallbackCellWidthRatio, accuracy: 0.0001, "0 floors to 8pt")
        let huge = WindowSizeMath.fallbackCell(fontPointSize: 999)
        XCTAssertEqual(huge.cellHeight, 32 * WindowSizeMath.fallbackCellHeightRatio, accuracy: 0.0001, "caps at 32pt")
    }

    // MARK: WindowSizeMode raw values + Defaults round-trip / repair

    /// The enum raw values are the `window-size` config tokens and round-trip exactly.
    func testWindowSizeModeRawRoundTrip() {
        XCTAssertEqual(WindowSizeMode.allCases, [.remember, .grid, .frame])
        XCTAssertEqual(WindowSizeMode.remember.rawValue, "remember")
        XCTAssertEqual(WindowSizeMode.grid.rawValue, "grid")
        XCTAssertEqual(WindowSizeMode.frame.rawValue, "frame")
        XCTAssertEqual(WindowSizeMode(rawValue: "grid"), .grid)
        XCTAssertNil(WindowSizeMode(rawValue: "garbage-from-a-future-version"))
    }

    /// The new `Defaults.Keys` read their declared defaults when unset (`.remember`, 80, 24, 1000, 600),
    /// round-trip a written value, and a bogus persisted raw repairs to `.remember` (the
    /// `Defaults.PreferRawRepresentable` bridge) rather than trapping. Read through the public ``SettingsKey``
    /// accessors + the raw `UserDefaults` the `@Default(.key)` views bind (the file's no-`import Defaults`
    /// convention).
    func testWindowSizeDefaultsRoundTripAndRepair() {
        // Defaults when unset.
        XCTAssertEqual(SettingsKey.windowSize, .remember)
        XCTAssertEqual(SettingsKey.windowCols, 80)
        XCTAssertEqual(SettingsKey.windowRows, 24)
        XCTAssertEqual(SettingsKey.windowWidthPx, 1000)
        XCTAssertEqual(SettingsKey.windowHeightPx, 600)
        // Round-trip written values from their persisted form.
        UserDefaults.standard.set("grid", forKey: SettingsKey.windowSizeKey)
        UserDefaults.standard.set(120, forKey: SettingsKey.windowColsKey)
        UserDefaults.standard.set(40, forKey: SettingsKey.windowRowsKey)
        XCTAssertEqual(SettingsKey.windowSize, .grid)
        XCTAssertEqual(SettingsKey.windowCols, 120)
        XCTAssertEqual(SettingsKey.windowRows, 40)
        // A bogus persisted raw repairs to the default rather than trapping.
        UserDefaults.standard.set("garbage-from-a-future-version", forKey: SettingsKey.windowSizeKey)
        XCTAssertEqual(SettingsKey.windowSize, .remember, "an invalid raw value repairs to remember")
    }
}
