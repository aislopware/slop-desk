//! What content size a window opens at, and where on its screen it lands.
//!
//! Numbers in, numbers out: nothing here holds state, owns memory or answers a string, so every
//! rule crosses BY VALUE and the only pointer in the module is the descriptor's text. The one shape
//! worth naming is the resolution's, which carries nine inputs the mode selects between — the same
//! reason the pane-title rules cross as a struct rather than as a positional list nobody can read.
//!
//! The near side keeps its window-system semantics. A rectangle arrives as the four scalars the
//! caller derived from it (`minX`, `maxY`, `width`, `height`) because `CGRect` STANDARDISES its
//! extents and `CGSize` does not, and that asymmetry belongs with the types that have it.

use core::ffi::c_uchar;

use slopdesk_workspace::geometry::Size;
use slopdesk_workspace::window_size::{self, WindowSizeInputs, WindowSizeMode};

use crate::borrow;

/// The persisted frame stands — restore it, size nothing.
pub const SLOPDESK_WINDOW_SIZE_MODE_REMEMBER: u8 = 0;
/// A terminal grid of `cols × rows` cells.
pub const SLOPDESK_WINDOW_SIZE_MODE_GRID: u8 = 1;
/// An explicit pixel size for the whole window.
pub const SLOPDESK_WINDOW_SIZE_MODE_FRAME: u8 = 2;

/// An extent, in points.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskWindowExtent {
    /// The width.
    pub width: f64,
    /// The height.
    pub height: f64,
}

/// A resolved content size, or the absence of one.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskWindowContentSize {
    /// The width, meaningful only when `present`.
    pub width: f64,
    /// The height, meaningful only when `present`.
    pub height: f64,
    /// Whether a size was resolved at all. `false` is the remember mode: the caller restores the
    /// frame it persisted and applies no size of its own.
    pub present: bool,
}

/// A point in the unit square, its y growing DOWN from the top edge.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskWindowUnitPoint {
    /// Horizontal, 0 at the leading edge and 1 at the trailing one.
    pub x: f64,
    /// Vertical, 0 at the top edge and 1 at the bottom one.
    pub y: f64,
}

/// The bands every clamp in this module works to, read once rather than spelled twice.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskWindowSizeLimits {
    /// The column / row floor.
    pub min_cells: i32,
    /// The column / row ceiling.
    pub max_cells: i32,
    /// The pixel floor.
    pub min_px: i32,
    /// The pixel ceiling.
    pub max_px: i32,
    /// The content width a screen clamp never resolves below.
    pub min_content_width: f64,
    /// The content height a screen clamp never resolves below.
    pub min_content_height: f64,
    /// The cell width a point of font size is worth.
    pub fallback_cell_width_ratio: f64,
    /// The cell height a point of font size is worth.
    pub fallback_cell_height_ratio: f64,
    /// The font-size floor the fallback cell clamps into.
    pub min_font_point_size: f64,
    /// The font-size ceiling of that band.
    pub max_font_point_size: f64,
}

/// Everything the resolution reads.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskWindowSizeInputs {
    /// A `SLOPDESK_WINDOW_SIZE_MODE_*` code. An unknown one reads as remember — the mode that
    /// changes nothing.
    pub mode: u8,
    /// The persisted column count, unclamped.
    pub cols: i32,
    /// The persisted row count, unclamped.
    pub rows: i32,
    /// The persisted window width in pixels, unclamped.
    pub width_px: i32,
    /// The persisted window height in pixels, unclamped.
    pub height_px: i32,
    /// The live per-cell advance's width.
    pub cell_width: f64,
    /// The live per-cell advance's height.
    pub cell_height: f64,
    /// The screen's visible width, already standardised by the caller.
    pub visible_width: f64,
    /// The screen's visible height, already standardised by the caller.
    pub visible_height: f64,
    /// The window's horizontal out-of-content overhead: borders.
    pub chrome_inset_width: f64,
    /// The window's vertical out-of-content overhead: the title bar.
    pub chrome_inset_height: f64,
    /// The window content's non-terminal width: sidebar, inspector, pane inset.
    pub chrome_overhead_width: f64,
    /// The vertical half of that overhead.
    pub chrome_overhead_height: f64,
}

/// A parsed frame descriptor, or the absence of one.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskWindowFrameDescriptor {
    /// The saved window frame's origin, horizontal.
    pub frame_x: f64,
    /// The saved window frame's origin, vertical.
    pub frame_y: f64,
    /// The saved window frame's width.
    pub frame_width: f64,
    /// The saved window frame's height.
    pub frame_height: f64,
    /// The saved screen frame's origin, horizontal.
    pub screen_x: f64,
    /// The saved screen frame's origin, vertical.
    pub screen_y: f64,
    /// The saved screen frame's width.
    pub screen_width: f64,
    /// The saved screen frame's height.
    pub screen_height: f64,
    /// Whether the descriptor parsed at all. `false` leaves every field at zero.
    pub present: bool,
}

/// The mode a `SLOPDESK_WINDOW_SIZE_MODE_*` code names.
const fn mode_of(code: u8) -> WindowSizeMode {
    match code {
        SLOPDESK_WINDOW_SIZE_MODE_GRID => WindowSizeMode::Grid,
        SLOPDESK_WINDOW_SIZE_MODE_FRAME => WindowSizeMode::Frame,
        _ => WindowSizeMode::Remember,
    }
}

/// The bands every clamp works to.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_window_size_limits() -> SlopDeskWindowSizeLimits {
    SlopDeskWindowSizeLimits {
        min_cells: window_size::MIN_CELLS,
        max_cells: window_size::MAX_CELLS,
        min_px: window_size::MIN_PX,
        max_px: window_size::MAX_PX,
        min_content_width: window_size::MIN_CONTENT_WIDTH,
        min_content_height: window_size::MIN_CONTENT_HEIGHT,
        fallback_cell_width_ratio: window_size::FALLBACK_CELL_WIDTH_RATIO,
        fallback_cell_height_ratio: window_size::FALLBACK_CELL_HEIGHT_RATIO,
        min_font_point_size: window_size::MIN_FONT_POINT_SIZE,
        max_font_point_size: window_size::MAX_FONT_POINT_SIZE,
    }
}

/// A column or row count, clamped into its band.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_size_clamp_cells(raw: i32) -> i32 {
    window_size::clamp_cells(raw)
}

/// A pixel dimension, clamped into its band.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_size_clamp_px(raw: i32) -> i32 {
    window_size::clamp_px(raw)
}

/// The cell advance to assume from a font size alone, before any terminal surface has laid out.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_size_fallback_cell(font_point_size: f64) -> SlopDeskWindowExtent {
    extent(window_size::fallback_cell(font_point_size))
}

/// The content extent a `cols × rows` grid occupies, before any screen clamp.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_size_grid(
    cols: i32,
    rows: i32,
    cell_width: f64,
    cell_height: f64,
) -> SlopDeskWindowExtent {
    extent(window_size::grid_content_size(
        cols,
        rows,
        Size::new(cell_width, cell_height),
    ))
}

/// A content extent capped against the visible screen minus the chrome, then floored at a usable
/// window.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_size_clamp_to_screen(
    width: f64,
    height: f64,
    visible_width: f64,
    visible_height: f64,
    chrome_width: f64,
    chrome_height: f64,
) -> SlopDeskWindowExtent {
    extent(window_size::clamp_to_screen(
        Size::new(width, height),
        Size::new(visible_width, visible_height),
        Size::new(chrome_width, chrome_height),
    ))
}

/// The content size a newly opened window should adopt, or nothing when the persisted frame stands.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_size_resolved(
    inputs: SlopDeskWindowSizeInputs,
) -> SlopDeskWindowContentSize {
    let resolved = window_size::resolved_content_size(WindowSizeInputs {
        mode: mode_of(inputs.mode),
        cols: inputs.cols,
        rows: inputs.rows,
        width_px: inputs.width_px,
        height_px: inputs.height_px,
        cell: Size::new(inputs.cell_width, inputs.cell_height),
        visible: Size::new(inputs.visible_width, inputs.visible_height),
        chrome_insets: Size::new(inputs.chrome_inset_width, inputs.chrome_inset_height),
        chrome_overhead: Size::new(inputs.chrome_overhead_width, inputs.chrome_overhead_height),
    });
    resolved.map_or(
        SlopDeskWindowContentSize {
            width: 0.0,
            height: 0.0,
            present: false,
        },
        |size| {
            SlopDeskWindowContentSize {
                width: size.width,
                height: size.height,
                present: true,
            }
        },
    )
}

/// The unit position that reproduces a window frame on its screen.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_size_unit_position(
    frame_min_x: f64,
    frame_max_y: f64,
    frame_width: f64,
    frame_height: f64,
    screen_min_x: f64,
    screen_max_y: f64,
    screen_width: f64,
    screen_height: f64,
) -> SlopDeskWindowUnitPoint {
    let point = window_size::unit_position(
        frame_min_x,
        frame_max_y,
        Size::new(frame_width, frame_height),
        screen_min_x,
        screen_max_y,
        Size::new(screen_width, screen_height),
    );
    SlopDeskWindowUnitPoint {
        x: point.x,
        y: point.y,
    }
}

/// A saved frame descriptor, parsed strictly: `present` is false for anything that could size a
/// degenerate window.
///
/// # Safety
/// `text` must be null or point to `len` initialised bytes, live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_window_size_parse_frame(
    text: *const c_uchar,
    len: usize,
) -> SlopDeskWindowFrameDescriptor {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    let descriptor = core::str::from_utf8(bytes)
        .ok()
        .and_then(window_size::parse_frame_descriptor);
    descriptor.map_or(
        SlopDeskWindowFrameDescriptor {
            frame_x: 0.0,
            frame_y: 0.0,
            frame_width: 0.0,
            frame_height: 0.0,
            screen_x: 0.0,
            screen_y: 0.0,
            screen_width: 0.0,
            screen_height: 0.0,
            present: false,
        },
        |parsed| {
            SlopDeskWindowFrameDescriptor {
                frame_x: parsed.frame.x,
                frame_y: parsed.frame.y,
                frame_width: parsed.frame.width,
                frame_height: parsed.frame.height,
                screen_x: parsed.screen.x,
                screen_y: parsed.screen.y,
                screen_width: parsed.screen.width,
                screen_height: parsed.screen.height,
                present: true,
            }
        },
    )
}

/// The crate's extent as the boundary's.
const fn extent(size: Size) -> SlopDeskWindowExtent {
    SlopDeskWindowExtent {
        width: size.width,
        height: size.height,
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]
    #![expect(
        clippy::float_cmp,
        reason = "the fixtures are exact binary fractions, and a value passing through UNCHANGED is the \
                  property under test"
    )]

    use super::{
        SLOPDESK_WINDOW_SIZE_MODE_FRAME, SLOPDESK_WINDOW_SIZE_MODE_GRID, SLOPDESK_WINDOW_SIZE_MODE_REMEMBER,
        SlopDeskWindowSizeInputs, slopdesk_window_size_limits, slopdesk_window_size_parse_frame,
        slopdesk_window_size_resolved,
    };

    fn inputs(mode: u8) -> SlopDeskWindowSizeInputs {
        SlopDeskWindowSizeInputs {
            mode,
            cols: 80,
            rows: 24,
            width_px: 1000,
            height_px: 600,
            cell_width: 8.0,
            cell_height: 16.0,
            visible_width: 1800.0,
            visible_height: 1130.0,
            chrome_inset_width: 0.0,
            chrome_inset_height: 0.0,
            chrome_overhead_width: 0.0,
            chrome_overhead_height: 0.0,
        }
    }

    #[test]
    fn the_mode_selects_which_inputs_are_read() {
        assert!(!slopdesk_window_size_resolved(inputs(SLOPDESK_WINDOW_SIZE_MODE_REMEMBER)).present);
        let grid = slopdesk_window_size_resolved(inputs(SLOPDESK_WINDOW_SIZE_MODE_GRID));
        assert_eq!((grid.width, grid.height, grid.present), (640.0, 384.0, true));
        let frame = slopdesk_window_size_resolved(inputs(SLOPDESK_WINDOW_SIZE_MODE_FRAME));
        assert_eq!((frame.width, frame.height), (1000.0, 600.0));
        assert!(
            !slopdesk_window_size_resolved(inputs(200)).present,
            "a code from a newer door sizes nothing rather than guessing"
        );
    }

    #[test]
    fn a_descriptor_crosses_as_eight_numbers_and_a_flag() {
        let text = b"260 189 1280 800 0 0 1800 1130";
        // SAFETY: a live borrow of a local buffer for the duration of the call.
        let parsed = unsafe { slopdesk_window_size_parse_frame(text.as_ptr(), text.len()) };
        assert!(parsed.present);
        assert_eq!((parsed.frame_x, parsed.frame_width), (260.0, 1280.0));
        assert_eq!((parsed.screen_width, parsed.screen_height), (1800.0, 1130.0));
        // SAFETY: as above; a null pointer with a zero length is the empty descriptor.
        let empty = unsafe { slopdesk_window_size_parse_frame(core::ptr::null(), 0) };
        assert!(!empty.present, "nothing saved sizes nothing");
    }

    #[test]
    fn the_limits_are_the_bands_the_clamps_work_to() {
        let limits = slopdesk_window_size_limits();
        assert_eq!((limits.min_cells, limits.max_cells), (1, 1000));
        assert_eq!((limits.min_px, limits.max_px), (64, 16384));
        assert_eq!(limits.min_content_width, 200.0);
        assert_eq!(limits.max_font_point_size, 32.0);
    }
}
