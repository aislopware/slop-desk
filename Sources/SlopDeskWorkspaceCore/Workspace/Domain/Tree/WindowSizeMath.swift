// What content size a window opens at, as the Swift face of `slopdesk_workspace::window_size`,
// reached through `rust/slopdesk-ffi`'s `window_size` door.
//
// ## What is not here any more
//
// The arithmetic: the cell / pixel bands and their clamps, the font-derived fallback cell, the grid
// extent, the screen clamp against the chrome, the strict frame-descriptor parse and the unit
// position that reproduces a saved frame. All Rust's, beside `window_placement` — the host's
// where-does-a-remoted-window-go rule, which this file's float discipline was already written to
// match. That discipline now holds by construction: ONE implementation, in a crate that forbids
// `unsafe` and pins the NaN behaviour in its own tests.
//
// ## What stays
//
// The window system. `CGRect` standardises its extents and `CGSize` does not, so the four scalars a
// rect crosses as are derived HERE, where the types that know the difference live; a
// `TerminalCellMetrics` is likewise assembled here, because the cell advance the door answers is two
// numbers and the value type carries a grid alongside them.

import CoreGraphics
import CSlopDeskFFI
import SlopDeskTerminal

// MARK: - WindowSizeMath (the window-sizing arithmetic, marshalled)

/// The window-sizing rules for the `window-size` modes (`grid` / `frame` / `remember`) — the single
/// source of truth the (macOS-only, hang-unsafe) `NSWindow` glue calls to decide a new window's
/// initial CONTENT size, and the seed the scene creation reads for a `remember` window.
///
/// Every numeric input is clamped by the crate before it reaches any geometry, so a persisted 0 /
/// negative / gigantic value can never yield a 0×0 or off-screen-gigantic window, and a corrupted
/// frame descriptor yields `nil` rather than a rect something would be sized to.
public enum WindowSizeMath {
    // MARK: Clamp bands (validate-then-drop — never 0, never gigantic)

    /// The bands, read from the crate once. Spelling any of these numbers on this side would be a
    /// second source for a value the clamps already work to.
    private static let limits = slopdesk_window_size_limits()

    /// The inclusive column / row band: at least 1 (a 0-row window is degenerate) and capped at a
    /// sane 1000 (`window-cols`/`window-rows` are small cell counts; a 5-figure value is a typo /
    /// hostile).
    public static let minCells = Int(limits.min_cells)
    public static let maxCells = Int(limits.max_cells)
    /// The inclusive pixel band for `frame` mode: a 64pt floor (smaller than a usable window) up to
    /// 16384 (the Metal max-texture / sane-display ceiling, matching the video path's clamp).
    public static let minPx = Int(limits.min_px)
    public static let maxPx = Int(limits.max_px)
    /// The sane CONTENT floor for ``clampToScreen(_:visible:chromeInsets:)`` — a window can never
    /// resolve below this even on a tiny display (200×120pt ≈ a few cells; below it the chrome would
    /// have no room).
    public static let minContentWidth = CGFloat(limits.min_content_width)
    public static let minContentHeight = CGFloat(limits.min_content_height)

    // MARK: Scalar clamps

    /// Clamp a raw column count into `1...1000` — never 0 (degenerate), never gigantic.
    ///
    /// `Int32(clamping:)` is the whole width conversion: a count past `Int32`'s range saturates and
    /// then clamps to the band, which is where any such value was going anyway.
    public static func clampCols(_ raw: Int) -> Int {
        Int(slopdesk_window_size_clamp_cells(Int32(clamping: raw)))
    }

    /// Clamp a raw row count into `1...1000`. The same rule as ``clampCols(_:)`` — rows and columns
    /// share one band.
    public static func clampRows(_ raw: Int) -> Int {
        Int(slopdesk_window_size_clamp_cells(Int32(clamping: raw)))
    }

    /// Clamp a raw pixel dimension into `64...16384` — never below a usable window, never above the
    /// sane display / texture ceiling.
    public static func clampPx(_ raw: Int) -> Int {
        Int(slopdesk_window_size_clamp_px(Int32(clamping: raw)))
    }

    // MARK: Font-derived fallback cell (before the live terminal surface lays out)

    /// The per-cell advance ratios the fallback cell derives from the configured font point size —
    /// tuned so the default 13pt font resolves to ≈ 8×16pt while any other font scales with it.
    public static let fallbackCellWidthRatio = CGFloat(limits.fallback_cell_width_ratio)
    public static let fallbackCellHeightRatio = CGFloat(limits.fallback_cell_height_ratio)
    /// The inclusive font-size band the fallback derivation clamps into — mirrors `PreferencesStore`'s
    /// `8...32` range so a hostile / zero / NaN persisted size can never produce a 0 or absurd cell.
    public static let minFontPointSize = CGFloat(limits.min_font_point_size)
    public static let maxFontPointSize = CGFloat(limits.max_font_point_size)

    /// Derive a fallback ``TerminalCellMetrics`` from `fontPointSize` — used by the macOS window-size
    /// glue ONLY before the active terminal surface has reported its real cell advance, so a
    /// non-default font still resolves to a correctly-scaled cell instead of a hard-coded 8×16.
    ///
    /// `cols`/`rows` are placeholders: the grid extent reads only the advance, and the value type has
    /// nowhere to leave them empty.
    public static func fallbackCell(fontPointSize: CGFloat) -> TerminalCellMetrics {
        let cell = slopdesk_window_size_fallback_cell(Double(fontPointSize))
        return TerminalCellMetrics(
            cellWidth: CGFloat(cell.width), cellHeight: CGFloat(cell.height), cols: 80, rows: 24,
        )
    }

    // MARK: Grid → content points

    /// The CONTENT size (points) for a `cols × rows` grid given the live per-cell advance in `cell` —
    /// the RAW extent, before the separate screen clamp.
    public static func gridContentSize(cols: Int, rows: Int, cell: TerminalCellMetrics) -> CGSize {
        let grid = slopdesk_window_size_grid(
            Int32(clamping: cols), Int32(clamping: rows),
            Double(cell.cellWidth), Double(cell.cellHeight),
        )
        return CGSize(width: grid.width, height: grid.height)
    }

    // MARK: Screen clamp

    /// Clamp a desired CONTENT size so `content + chrome ≤ visible`, then floor it at the sane
    /// minimum (``minContentWidth`` × ``minContentHeight``) so a tiny request / tiny display can
    /// never resolve to a degenerate window. `chromeInsets` is the window's non-content overhead
    /// (title bar + borders).
    ///
    /// `visible.width`/`.height` are read HERE because `CGRect` standardises them (always ≥ 0) and
    /// the crate takes the numbers as given.
    public static func clampToScreen(_ size: CGSize, visible: CGRect, chromeInsets: CGSize) -> CGSize {
        let clamped = slopdesk_window_size_clamp_to_screen(
            Double(size.width), Double(size.height),
            Double(visible.width), Double(visible.height),
            Double(chromeInsets.width), Double(chromeInsets.height),
        )
        return CGSize(width: clamped.width, height: clamped.height)
    }

    // MARK: Saved-frame descriptor (`remember` — the scene-creation seed)

    /// Parse an `NSWindow.frameDescriptor` string ("x y w h screenX screenY screenW screenH" — the
    /// window FRAME then the screen's frame at save time; bottom-left origin, points). `nil` unless
    /// the first 8 whitespace-separated tokens are all finite numbers with positive, ≤ ``maxPx``
    /// window + screen extents. Extra trailing tokens are ignored (AppKit's format has grown before).
    ///
    /// Consumed by the macOS scene glue to SEED `.defaultSize` / `.defaultPosition` so a `remember`
    /// window is CREATED at the persisted geometry — the post-first-paint `setFrame(from:)` then
    /// reconciles exactly (screen topology changes) without a visible wrong-size first frame.
    public static func parseFrameDescriptor(_ descriptor: String) -> (frame: CGRect, screen: CGRect)? {
        var bytes = Array(descriptor.utf8)
        let parsed = bytes.withUnsafeMutableBufferPointer {
            slopdesk_window_size_parse_frame($0.baseAddress, $0.count)
        }
        guard parsed.present else { return nil }
        return (
            CGRect(
                x: parsed.frame_x, y: parsed.frame_y,
                width: parsed.frame_width, height: parsed.frame_height,
            ),
            CGRect(
                x: parsed.screen_x, y: parsed.screen_y,
                width: parsed.screen_width, height: parsed.screen_height,
            ),
        )
    }

    /// The `defaultPosition` unit point that reproduces `frame` on `screen`: per axis, the origin
    /// offset over the FREE extent (screen − window), so 0 = flush leading/top edge and 1 = flush
    /// trailing/bottom edge — exactly SwiftUI's `UnitPoint` placement model. The y-axis flips
    /// (`UnitPoint` grows DOWN from the top edge; AppKit frames grow UP from the bottom), which is
    /// why the two `maxY` edges cross rather than the origins. A window as large as the screen (free
    /// ≤ 0) centres at 0.5 — position is irrelevant there.
    public static func unitPosition(frame: CGRect, screen: CGRect) -> CGPoint {
        let unit = slopdesk_window_size_unit_position(
            Double(frame.minX), Double(frame.maxY), Double(frame.width), Double(frame.height),
            Double(screen.minX), Double(screen.maxY), Double(screen.width), Double(screen.height),
        )
        return CGPoint(x: unit.x, y: unit.y)
    }

    // MARK: Resolution (the single glue entry point)

    // The inputs stay a flat parameter list on this side: the glue reads each one from a different
    // place (defaults, the live surface, the screen, two chrome terms), and a Swift struct would only
    // relabel what the door already carries as one.
    // swiftlint:disable function_parameter_count

    /// Resolve the CONTENT size a newly opened window should adopt, or `nil` when the autosaved frame
    /// should stand (the `.remember` path). The ONE function the macOS `NSWindow` glue calls:
    ///
    /// - ``WindowSizeMode/remember`` → `nil` — the glue restores the app-persisted frame descriptor
    ///   itself (`setFrame(from:)`); apply no explicit size here.
    /// - ``WindowSizeMode/grid`` → the screen-clamped grid extent PLUS `chromeOverhead`.
    /// - ``WindowSizeMode/frame`` → the screen-clamped, band-clamped pixel size.
    ///
    /// `chromeOverhead` is the WINDOW content's NON-terminal extent — the revealed sidebar (TABS
    /// panel) + the shown inspector (Details panel) widths + any terminal pane content inset. It is
    /// added in `grid` mode so the resolved WINDOW content yields a TERMINAL of exactly `cols × rows`
    /// (`window-cols`/`window-rows` size the TERMINAL, not the whole window). `frame` mode ignores it
    /// — `window-width-px`/`window-height-px` are the explicit WHOLE-window pixel size.
    /// (`chromeInsets` stays the OUT-of-content overhead: title bar / borders.)
    public static func resolvedContentSize(
        mode: WindowSizeMode,
        cols: Int,
        rows: Int,
        widthPx: Int,
        heightPx: Int,
        cell: TerminalCellMetrics,
        visible: CGRect,
        chromeInsets: CGSize,
        chromeOverhead: CGSize,
    ) -> CGSize? {
        let resolved = slopdesk_window_size_resolved(SlopDeskWindowSizeInputs(
            mode: mode.ffiCode,
            cols: Int32(clamping: cols),
            rows: Int32(clamping: rows),
            width_px: Int32(clamping: widthPx),
            height_px: Int32(clamping: heightPx),
            cell_width: Double(cell.cellWidth),
            cell_height: Double(cell.cellHeight),
            visible_width: Double(visible.width),
            visible_height: Double(visible.height),
            chrome_inset_width: Double(chromeInsets.width),
            chrome_inset_height: Double(chromeInsets.height),
            chrome_overhead_width: Double(chromeOverhead.width),
            chrome_overhead_height: Double(chromeOverhead.height),
        ))
        guard resolved.present else { return nil }
        return CGSize(width: resolved.width, height: resolved.height)
    }
    // swiftlint:enable function_parameter_count
}

// MARK: - The code the door reads

private extension WindowSizeMode {
    /// The `SLOPDESK_WINDOW_SIZE_MODE_*` code for the mode, named rather than numbered so the two
    /// languages cannot drift apart over one.
    var ffiCode: UInt8 {
        switch self {
        case .remember: UInt8(SLOPDESK_WINDOW_SIZE_MODE_REMEMBER)
        case .grid: UInt8(SLOPDESK_WINDOW_SIZE_MODE_GRID)
        case .frame: UInt8(SLOPDESK_WINDOW_SIZE_MODE_FRAME)
        }
    }
}
