//! What content size a window opens at, and where on its screen it lands.
//!
//! The near side owns the window system — an `NSWindow`, its screen's visible frame, the chrome it
//! carries — and this module owns none of it. Every rule here is arithmetic on numbers the caller
//! has already read out of its own types, which is why a rectangle arrives as the four scalars the
//! caller derived (`minX`, `maxY`, `width`, `height`) rather than as a rect this side would have to
//! re-interpret: `CGRect.width` STANDARDISES and `CGSize.width` does not, and that asymmetry
//! belongs with the type that has it.
//!
//! Two disciplines run through all of it.
//!
//! **Validate, then clamp — never trap.** A persisted count or pixel size can be 0, negative,
//! five-figure or corrupt, and none of those may become a 0×0 or off-screen-gigantic window. Every
//! numeric input is clamped into a band before it reaches any geometry, and the frame descriptor is
//! parsed strictly enough that a truncated or hostile string yields *no answer* rather than a
//! degenerate rect.
//!
//! **Ordered comparisons, not NaN-ignoring minima.** `a < b { a } else { b }` propagates a NaN
//! operand where `f64::min` would hand back the other value; the same spelling, for the same
//! reason, as [`slopdesk_video::window_placement`]. A NaN font size or screen extent stays NaN and
//! the caller sees it, instead of being silently rewritten into a number that looks plausible.

use crate::geometry::{Point, Size};

/// How a new window picks its size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowSizeMode {
    /// Restore whatever frame the app persisted; this module resolves no size at all.
    Remember,
    /// A terminal grid — `cols × rows` cells of the live cell advance.
    Grid,
    /// An explicit pixel size for the whole window.
    Frame,
}

/// The inclusive column / row band: at least 1 (a 0-row window is degenerate) and capped at a sane
/// 1000 — these are small cell counts, so a five-figure value is a typo or hostile.
pub const MIN_CELLS: i32 = 1;
/// The top of the cell band.
pub const MAX_CELLS: i32 = 1000;
/// The pixel floor: smaller than a usable window.
pub const MIN_PX: i32 = 64;
/// The pixel ceiling: the Metal max-texture / sane-display bound the video path also clamps to.
pub const MAX_PX: i32 = 16384;
/// The content floor a screen clamp can never resolve below, even on a tiny display — under it the
/// chrome would have no room left.
pub const MIN_CONTENT_WIDTH: f64 = 200.0;
/// The vertical half of that floor.
pub const MIN_CONTENT_HEIGHT: f64 = 120.0;
/// A typical monospace cell is about 0.6× the point size wide…
pub const FALLBACK_CELL_WIDTH_RATIO: f64 = 8.0 / 13.0;
/// …and about 1.2× tall. Tuned so the default 13pt font lands on ≈ 8×16pt and any other font
/// scales.
pub const FALLBACK_CELL_HEIGHT_RATIO: f64 = 16.0 / 13.0;
/// The font-size floor the fallback derivation clamps into — the same band the preferences offer,
/// so a hostile or zero persisted size cannot produce a zero cell.
pub const MIN_FONT_POINT_SIZE: f64 = 8.0;
/// The font-size ceiling of that band.
pub const MAX_FONT_POINT_SIZE: f64 = 32.0;

/// A rectangle as the caller's window system spells it.
///
/// An origin and an extent, in whatever orientation that system uses. This module reads the numbers
/// and never asks which corner they name — only the caller knows, and only the caller needs to.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct WindowFrame {
    /// The origin's horizontal coordinate.
    pub x: f64,
    /// The origin's vertical coordinate.
    pub y: f64,
    /// The width.
    pub width: f64,
    /// The height.
    pub height: f64,
}

/// A parsed frame descriptor: the window's frame, and the screen it was saved on.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct FrameDescriptor {
    /// The window frame at save time.
    pub frame: WindowFrame,
    /// The screen's frame at save time, which is what makes the window frame meaningful later.
    pub screen: WindowFrame,
}

/// Everything the resolution reads, in one value.
///
/// Nine numbers is past what a signature should carry, and they are not independent anyway: the
/// mode decides which of the others are even consulted.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WindowSizeInputs {
    /// Which rule applies.
    pub mode: WindowSizeMode,
    /// The persisted column count, unclamped.
    pub cols: i32,
    /// The persisted row count, unclamped.
    pub rows: i32,
    /// The persisted window width in pixels, unclamped.
    pub width_px: i32,
    /// The persisted window height in pixels, unclamped.
    pub height_px: i32,
    /// The live per-cell advance.
    pub cell: Size,
    /// The screen's visible extent, already standardised by the caller.
    pub visible: Size,
    /// The window's out-of-content overhead: title bar and borders.
    pub chrome_insets: Size,
    /// The window content's NON-terminal extent: the revealed sidebar, the shown inspector, the
    /// pane's own inset. Added in grid mode so the TERMINAL ends up `cols × rows`, since that is
    /// what the setting sizes; ignored in frame mode, where the pixels are the whole window's.
    pub chrome_overhead: Size,
}

/// Clamp a raw column or row count into [`MIN_CELLS`]…[`MAX_CELLS`].
#[must_use]
pub fn clamp_cells(raw: i32) -> i32 {
    raw.clamp(MIN_CELLS, MAX_CELLS)
}

/// Clamp a raw pixel dimension into [`MIN_PX`]…[`MAX_PX`].
#[must_use]
pub fn clamp_px(raw: i32) -> i32 {
    raw.clamp(MIN_PX, MAX_PX)
}

/// The cell advance to assume from a font size alone, before any terminal surface has laid out.
///
/// A hard-coded 8×16 would be wrong for every font but the default one, and the window it sized
/// would be visibly the wrong shape for a moment. The size is clamped into the font band first, and
/// each axis is its own multiply — never a fused one.
#[must_use]
pub fn fallback_cell(font_point_size: f64) -> Size {
    let floored = if font_point_size < MIN_FONT_POINT_SIZE {
        MIN_FONT_POINT_SIZE
    } else {
        font_point_size
    };
    let size = if MAX_FONT_POINT_SIZE < floored {
        MAX_FONT_POINT_SIZE
    } else {
        floored
    };
    let width = size * FALLBACK_CELL_WIDTH_RATIO;
    let height = size * FALLBACK_CELL_HEIGHT_RATIO;
    Size::new(width, height)
}

/// The content extent a `cols × rows` grid of `cell` occupies, before any screen clamp.
///
/// The counts are clamped first, so no input can produce a zero or absurd extent, and each axis is
/// its own multiply.
#[must_use]
pub fn grid_content_size(cols: i32, rows: i32, cell: Size) -> Size {
    let width = cell.width * f64::from(clamp_cells(cols));
    let height = cell.height * f64::from(clamp_cells(rows));
    Size::new(width, height)
}

/// Cap a content extent against the screen, then floor it at a usable window.
///
/// The cap keeps content + chrome inside the visible extent; the floor is
/// [`MIN_CONTENT_WIDTH`] × [`MIN_CONTENT_HEIGHT`], so a tiny request or a tiny display still yields
/// a window with room for its chrome.
///
/// `visible` is the screen's visible extent as the caller standardised it; `chrome` is the window's
/// out-of-content overhead. The available content extent is one subtraction per axis, and both the
/// cap and the floor are ordered comparisons.
#[must_use]
pub fn clamp_to_screen(size: Size, visible: Size, chrome: Size) -> Size {
    let avail_width = visible.width - chrome.width;
    let avail_height = visible.height - chrome.height;
    let capped_width = if avail_width < size.width {
        avail_width
    } else {
        size.width
    };
    let capped_height = if avail_height < size.height {
        avail_height
    } else {
        size.height
    };
    let width = if capped_width < MIN_CONTENT_WIDTH {
        MIN_CONTENT_WIDTH
    } else {
        capped_width
    };
    let height = if capped_height < MIN_CONTENT_HEIGHT {
        MIN_CONTENT_HEIGHT
    } else {
        capped_height
    };
    Size::new(width, height)
}

/// The content size a newly opened window should adopt, or `None` when the persisted frame stands.
///
/// `None` is [`WindowSizeMode::Remember`] and only that: the caller restores the saved frame
/// itself, so applying any size here would fight it.
#[must_use]
pub fn resolved_content_size(inputs: WindowSizeInputs) -> Option<Size> {
    match inputs.mode {
        WindowSizeMode::Remember => None,
        WindowSizeMode::Grid => {
            let grid = grid_content_size(inputs.cols, inputs.rows, inputs.cell);
            // The grid sizes the TERMINAL, so the rest of the window's content is added on top —
            // one addition per axis, never fused.
            let content = Size::new(
                grid.width + inputs.chrome_overhead.width,
                grid.height + inputs.chrome_overhead.height,
            );
            Some(clamp_to_screen(content, inputs.visible, inputs.chrome_insets))
        },
        WindowSizeMode::Frame => {
            let desired = Size::new(
                f64::from(clamp_px(inputs.width_px)),
                f64::from(clamp_px(inputs.height_px)),
            );
            Some(clamp_to_screen(desired, inputs.visible, inputs.chrome_insets))
        },
    }
}

/// Parse a saved frame descriptor: `x y w h screenX screenY screenW screenH`, the window frame then
/// the screen's, in points.
///
/// `None` unless the first eight space-separated tokens are all finite numbers whose window and
/// screen extents are positive and no larger than [`MAX_PX`] — a truncated, corrupted or hostile
/// string has to yield no answer rather than a rect something will later be sized to. Trailing
/// tokens are ignored: the format has grown before.
///
/// One difference from the near side worth naming: its `Double(_:)` also reads a hex-float literal
/// (`0x1p3`), which this does not. Nothing writes one, and a descriptor that contains one is
/// unparseable rather than misread.
#[must_use]
pub fn parse_frame_descriptor(descriptor: &str) -> Option<FrameDescriptor> {
    let mut values = [0.0_f64; 8];
    let mut tokens = descriptor.split(' ').filter(|token| !token.is_empty());
    // Eight slots, filled in order: running out of tokens IS the truncated descriptor, and anything
    // after the eighth is a format that grew.
    for slot in &mut values {
        let value: f64 = tokens.next()?.parse().ok()?;
        if !value.is_finite() {
            return None;
        }
        *slot = value;
    }
    let [
        frame_x,
        frame_y,
        frame_width,
        frame_height,
        screen_x,
        screen_y,
        screen_width,
        screen_height,
    ] = values;
    // The RAW extents are what is checked, not a rectangle's: a rect that standardises would wave a
    // negative extent through as its absolute value.
    let cap = f64::from(MAX_PX);
    for extent in [frame_width, frame_height, screen_width, screen_height] {
        if !(extent > 0.0 && extent <= cap) {
            return None;
        }
    }
    Some(FrameDescriptor {
        frame: WindowFrame {
            x: frame_x,
            y: frame_y,
            width: frame_width,
            height: frame_height,
        },
        screen: WindowFrame {
            x: screen_x,
            y: screen_y,
            width: screen_width,
            height: screen_height,
        },
    })
}

/// The unit position that reproduces a window frame on its screen: per axis, the origin's offset
/// over the FREE extent, so 0 is flush against the leading edge and 1 against the trailing one.
///
/// The vertical axis is the caller's TOP gap over the free height, which is why it arrives as
/// `frame_max_y` and `screen_max_y` rather than as origins: the unit square grows down and the
/// caller's frames may not. A window as large as its screen has no free extent to sit in and
/// centres at 0.5, where position means nothing anyway.
#[must_use]
pub fn unit_position(
    frame_min_x: f64,
    frame_max_y: f64,
    frame: Size,
    screen_min_x: f64,
    screen_max_y: f64,
    screen: Size,
) -> Point {
    let free_width = screen.width - frame.width;
    let free_height = screen.height - frame.height;
    let raw_x = if free_width > 0.0 {
        (frame_min_x - screen_min_x) / free_width
    } else {
        0.5
    };
    let raw_y = if free_height > 0.0 {
        (screen_max_y - frame_max_y) / free_height
    } else {
        0.5
    };
    let floored_x = if raw_x < 0.0 { 0.0 } else { raw_x };
    let floored_y = if raw_y < 0.0 { 0.0 } else { raw_y };
    let x = if floored_x > 1.0 { 1.0 } else { floored_x };
    let y = if floored_y > 1.0 { 1.0 } else { floored_y };
    Point::new(x, y)
}

#[cfg(test)]
mod tests {
    // The fixtures are exact binary fractions and compare as whole `Size` / `Point` values, so
    // nothing here needs the float-comparison exemption: a value passing through UNCHANGED is the
    // property under test, and the one derived ratio is checked inside a tolerance.

    use super::{
        FrameDescriptor, MAX_CELLS, MAX_PX, MIN_CELLS, MIN_PX, Point, Size, WindowFrame, WindowSizeInputs,
        WindowSizeMode, clamp_cells, clamp_px, clamp_to_screen, fallback_cell, grid_content_size,
        parse_frame_descriptor, resolved_content_size, unit_position,
    };

    const CELL: Size = Size {
        width: 8.0,
        height: 16.0,
    };

    fn inputs(mode: WindowSizeMode) -> WindowSizeInputs {
        WindowSizeInputs {
            mode,
            cols: 80,
            rows: 24,
            width_px: 1000,
            height_px: 600,
            cell: CELL,
            visible: Size::new(1800.0, 1130.0),
            chrome_insets: Size::new(0.0, 28.0),
            chrome_overhead: Size::ZERO,
        }
    }

    #[test]
    fn a_count_outside_the_band_is_clamped_rather_than_carried() {
        assert_eq!(clamp_cells(0), MIN_CELLS, "a zero-row window is degenerate");
        assert_eq!(clamp_cells(-7), MIN_CELLS);
        assert_eq!(clamp_cells(80), 80, "an in-band count passes through");
        assert_eq!(clamp_cells(5000), MAX_CELLS);
        assert_eq!(clamp_px(0), MIN_PX);
        assert_eq!(clamp_px(1000), 1000);
        assert_eq!(clamp_px(99999), MAX_PX);
    }

    #[test]
    fn a_grid_is_its_cell_advance_times_its_clamped_counts() {
        assert_eq!(
            grid_content_size(80, 24, CELL),
            Size::new(640.0, 384.0),
            "80×24 of an 8×16 cell"
        );
        let zero = grid_content_size(0, -5, CELL);
        assert_eq!(
            zero,
            Size::new(8.0, 16.0),
            "a degenerate request still yields one cell, never nothing"
        );
    }

    #[test]
    fn the_fallback_cell_scales_with_the_font_and_stays_inside_its_band() {
        let default_font = fallback_cell(13.0);
        assert!((default_font.width - 8.0).abs() < 0.0001);
        assert!((default_font.height - 16.0).abs() < 0.0001);
        assert_eq!(
            fallback_cell(0.0),
            fallback_cell(8.0),
            "a zero font size floors into the band"
        );
        assert_eq!(
            fallback_cell(999.0),
            fallback_cell(32.0),
            "and an absurd one caps"
        );
    }

    #[test]
    fn a_nan_font_size_stays_nan_rather_than_becoming_a_plausible_cell() {
        let cell = fallback_cell(f64::NAN);
        assert!(
            cell.width.is_nan() && cell.height.is_nan(),
            "an ordered compare keeps the NaN the caller handed over"
        );
    }

    #[test]
    fn the_screen_clamp_caps_against_the_chrome_and_floors_at_a_usable_window() {
        let fits = clamp_to_screen(
            Size::new(640.0, 384.0),
            Size::new(1800.0, 1130.0),
            Size::new(0.0, 28.0),
        );
        assert_eq!(fits, Size::new(640.0, 384.0), "a window that fits is left alone");
        let capped = clamp_to_screen(
            Size::new(4000.0, 4000.0),
            Size::new(1800.0, 1130.0),
            Size::new(0.0, 28.0),
        );
        assert_eq!(
            capped,
            Size::new(1800.0, 1102.0),
            "the cap is the visible extent MINUS the chrome"
        );
        let floored = clamp_to_screen(Size::new(10.0, 10.0), Size::new(1800.0, 1130.0), Size::ZERO);
        assert_eq!(floored, Size::new(200.0, 120.0));
    }

    #[test]
    fn remember_resolves_no_size_at_all() {
        assert_eq!(resolved_content_size(inputs(WindowSizeMode::Remember)), None);
    }

    #[test]
    fn a_grid_window_carries_the_non_terminal_content_on_top_of_its_cells() {
        let bare = resolved_content_size(inputs(WindowSizeMode::Grid));
        assert_eq!(bare, Some(Size::new(640.0, 384.0)));
        let with_sidebar = WindowSizeInputs {
            chrome_overhead: Size::new(260.0, 0.0),
            ..inputs(WindowSizeMode::Grid)
        };
        assert_eq!(
            resolved_content_size(with_sidebar),
            Some(Size::new(900.0, 384.0)),
            "the terminal still ends up 80 columns wide"
        );
    }

    #[test]
    fn a_frame_window_is_its_clamped_pixels_and_ignores_the_overhead() {
        let with_overhead = WindowSizeInputs {
            chrome_overhead: Size::new(260.0, 0.0),
            ..inputs(WindowSizeMode::Frame)
        };
        assert_eq!(
            resolved_content_size(with_overhead),
            Some(Size::new(1000.0, 600.0)),
            "the pixels are the WHOLE window's"
        );
        let hostile = WindowSizeInputs {
            width_px: 0,
            height_px: -20,
            ..inputs(WindowSizeMode::Frame)
        };
        assert_eq!(
            resolved_content_size(hostile),
            Some(Size::new(200.0, 120.0)),
            "clamped to the pixel floor, then floored again by the screen clamp"
        );
    }

    #[test]
    fn a_descriptor_parses_when_its_first_eight_tokens_are_a_sane_pair_of_rects() {
        assert_eq!(
            parse_frame_descriptor("260 189 1280 800 0 0 1800 1130 "),
            Some(FrameDescriptor {
                frame: WindowFrame {
                    x: 260.0,
                    y: 189.0,
                    width: 1280.0,
                    height: 800.0,
                },
                screen: WindowFrame {
                    x: 0.0,
                    y: 0.0,
                    width: 1800.0,
                    height: 1130.0,
                },
            })
        );
        assert!(
            parse_frame_descriptor("-100 50 640 480 0 0 1440 900 future tokens").is_some(),
            "a format that grew is still readable"
        );
    }

    #[test]
    fn a_descriptor_that_could_size_a_degenerate_window_yields_nothing() {
        for hostile in [
            "",
            "260 189 1280 800 0 0 1800",
            "260 189 xyz 800 0 0 1800 1130",
            "260 189 nan 800 0 0 1800 1130",
            "260 189 inf 800 0 0 1800 1130",
            "260 189 0 800 0 0 1800 1130",
            "260 189 1280 -800 0 0 1800 1130",
            "260 189 99999 800 0 0 1800 1130",
            "260 189 1280 800 0 0 1800 0",
        ] {
            assert_eq!(
                parse_frame_descriptor(hostile),
                None,
                "`{hostile}` must not size a window"
            );
        }
        assert!(
            parse_frame_descriptor(&format!("0 0 {MAX_PX} 800 0 0 1800 1130")).is_some(),
            "the ceiling itself is allowed"
        );
    }

    #[test]
    fn a_unit_position_is_the_origins_share_of_the_free_extent() {
        let screen = Size::new(1000.0, 1000.0);
        let frame = Size::new(500.0, 500.0);
        // Bottom-left corner of a bottom-left-origin screen: flush left, flush BOTTOM.
        assert_eq!(
            unit_position(0.0, 500.0, frame, 0.0, 1000.0, screen),
            Point::new(0.0, 1.0)
        );
        // Top-left: the top gap is zero.
        assert_eq!(
            unit_position(0.0, 1000.0, frame, 0.0, 1000.0, screen),
            Point::new(0.0, 0.0)
        );
        assert_eq!(
            unit_position(250.0, 750.0, frame, 0.0, 1000.0, screen),
            Point::new(0.5, 0.5),
            "dead centre"
        );
        assert_eq!(
            unit_position(0.0, 1000.0, screen, 0.0, 1000.0, screen),
            Point::new(0.5, 0.5),
            "a window as large as its screen has nowhere to sit"
        );
        assert_eq!(
            unit_position(-400.0, 1700.0, frame, 0.0, 1000.0, screen),
            Point::new(0.0, 0.0),
            "an off-screen frame clamps into the unit square"
        );
    }
}
