//! The furniture around a block: the gutter, the divider, the collapse mark and the scrollbar.
//!
//! ## Why the drawing is here and the design is not
//!
//! [`crate::paint`]'s header used to say the client fills these rects itself, in its own design
//! language. The rects crossed; the fill did not — and the two ways to finish it both went wrong.
//! Positioning `AppKit` and `UIKit` layers over the Metal layer means the chrome lags the present
//! by a frame during a scroll (the drift `on_screen` exists to kill) and puts one appearance in two
//! platform views. Streaming instances back from Swift per frame is the marshalling this tree has
//! already measured and rejected once, and header text would still have to shape through the atlas
//! that lives on this side.
//!
//! What actually separates is not "who draws" but "who decides". [`ChromeStyle`] is the decision —
//! every colour, thickness and inset, chosen in Swift where `DESIGN.md` lives — and this module is
//! the execution. That is the same seam [`crate::paint::PaintStyle`] and
//! [`crate::paint::SelectionColors`] already sit on, and it keeps ONE chrome for both platforms.
//!
//! ## What it draws, and what it deliberately cannot
//!
//! A gutter bar per block, a hairline between blocks, a collapse mark with the folded row count,
//! the scrollbar — and a block's exit code and duration, right-aligned on its header.
//!
//! ⚠️ That last one was recorded here as IMPOSSIBLE, and the reasoning is worth keeping because it
//! was wrong in an instructive way. It ran: `libghostty-vt` surfaces OSC 133 as three row states
//! and no command-end callback, so the engine does not know how a command ended; therefore the fix
//! is a shell-integration change; and counting prompts from the bottom to index the host's ring
//! "would be exactly the heuristic [`crate::block`] refuses".
//!
//! Both steps failed. The engine never had to know — the HOST's segmenter already knows, and
//! already ships the exit code, the duration and a `prompt_ordinal` to this very client on wire
//! type 28, so nothing was missing but the join. And the counting is not the refused heuristic:
//! [`crate::block`] refuses to GUESS a block's identity from its shape, while [`crate::blockjoin`]
//! proposes an anchor and then CONFIRMS it against the command text the host recorded, answering
//! nothing at all when the confirmation fails. A guess that can be checked and is checked is not a
//! heuristic.
//!
//! The cost of the error was not the missing feature but where it pointed: it parked closable work
//! behind someone else's release.
//!
//! ## The label is monospaced because the terminal is
//!
//! [`crate::glyph::TextShaper`] places glyphs on the cell grid — `slopdesk-apple-text` positions
//! every glyph at `cell_width * cell`. A chrome label therefore rides the same grid as the output
//! above it, which is not a compromise: a header whose text drifted off the column the command
//! starts in would read as a different typographic system laid over the terminal.

use slopdesk_terminal::geometry::Rect;

use crate::atlas::AtlasFormat;
use crate::block::{BlockLayout, PlacedBlock};
use crate::glyph::{GlyphCache, GlyphKey, GlyphRasterizer, ShapedGlyph, TextRun, TextShaper};
use crate::layout::Thumb;
use crate::paint::PaintStyle;
use crate::quad::{DrawList, GlyphInstance, RectInstance, RectStyle, Rgba, px};

/// Every colour and thickness the chrome draws with, chosen by the client.
///
/// Device pixels for the lengths, like everything else in this crate — the client scales its point
/// values once, at the boundary, where every other point→pixel conversion already happens.
///
/// [`ChromeStyle::NONE`] is the pre-install state and this module's contract in one value: handed
/// nothing, [`paint`] draws nothing, which is what lets a surface render before a client has chosen
/// a design. It is NOT how the alternate screen is served — that skips the pass outright, because
/// the frame the call would need hit-tests a pointer and asks the engine for a viewport, and both
/// answers would be discarded. See `Surface::draw` in `slopdesk-ffi` and `docs/68` §5.3.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ChromeStyle {
    /// The hairline between one block and the next.
    pub divider: Rgba,
    /// How thick that hairline is. Never drawn thinner than one device pixel.
    pub divider_thickness: f64,
    /// The bar down a block's leading edge, at rest.
    pub gutter: Rgba,
    /// The same bar for the block holding the cursor — the one still running.
    pub gutter_active: Rgba,
    /// How wide the bar is. The gutter RESERVED by
    /// [`crate::block::Chrome::gutter`] is wider; the rest is breathing room.
    pub gutter_thickness: f64,
    /// The wash over the block the pointer is inside.
    pub hover: Rgba,
    /// The collapse mark and the folded-row count.
    pub label: Rgba,
    /// The `✗ <code>` a failed block's header leads with — and NOTHING else, which is what keeps it
    /// worth spending a hue on. The duration beside it stays [`ChromeStyle::label`]: a slow command
    /// is not a broken one, and colouring the whole status would make the red mean "finished".
    pub status_err: Rgba,
    /// The scrollbar thumb.
    pub scrollbar: Rgba,
    /// How wide the thumb is.
    pub scrollbar_thickness: f64,
    /// How short the thumb may get in a long scrollback.
    pub scrollbar_min_height: f64,
    /// The gap between the thumb and the drawable's trailing edge.
    pub scrollbar_inset: f64,
}

impl ChromeStyle {
    /// Nothing to draw with — the alternate screen.
    pub const NONE: Self = Self {
        divider: Rgba::CLEAR,
        divider_thickness: 0.0,
        gutter: Rgba::CLEAR,
        gutter_active: Rgba::CLEAR,
        gutter_thickness: 0.0,
        hover: Rgba::CLEAR,
        label: Rgba::CLEAR,
        status_err: Rgba::CLEAR,
        scrollbar: Rgba::CLEAR,
        scrollbar_thickness: 0.0,
        scrollbar_min_height: 0.0,
        scrollbar_inset: 0.0,
    };
}

/// What is true of the list this frame, as opposed to what is true of the design.
///
/// Separate from [`ChromeStyle`] because it changes at a different rate: the style crosses the FFI
/// once, when the appearance is installed, and this is rebuilt per frame from the surface's own
/// state. Merging them would put a pointer position through a door that exists for colours.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ChromeFrame {
    /// The block the pointer is inside, if any.
    pub hovered: Option<usize>,
    /// The block holding the cursor — the newest one, still receiving output.
    pub active: Option<usize>,
    /// The drawable's content box: where the scrollbar's track runs and how wide a block is.
    pub viewport: Rect,
    /// The scrollbar thumb, or `None` when everything fits.
    pub thumb: Option<Thumb>,
}

/// What the host recorded about a block, reduced to what a header prints.
///
/// Built by the surface from the command-block ring after [`crate::blockjoin`] has decided which
/// record describes which block, so a `Some` here means the join was CONFIRMED — this type carries
/// no doubt and the painter does no second-guessing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockStatus {
    /// The command's exit code, or `None` while it is still running.
    ///
    /// `None` is drawn as nothing rather than as a spinner or a zero: the gutter already accents
    /// the running block, so a second running indicator on the header would say the same thing
    /// twice, and a zero would be a lie with a number on it.
    pub exit_code: Option<i32>,
    /// How long it took, in milliseconds, or `None` when the host has not closed the block.
    pub duration_ms: Option<u32>,
}

/// The two halves of a status: what FAILED, and how long it took. Either may be empty.
///
/// Two rather than one because they are drawn in different inks and the split has to be decided
/// where the words are chosen, not re-derived at the painter by looking for a `✗`. Failure leads,
/// because that is the thing a reader scrolls back to find; success contributes no mark of its own
/// — a `✓` on every successful block is ink on the majority case to distinguish the case nobody is
/// looking for.
#[must_use]
pub(crate) fn status_parts(status: BlockStatus) -> (String, String) {
    let mut failure = String::new();
    if let Some(code) = status.exit_code
        && code != 0
    {
        failure.push_str("✗ ");
        failure.push_str(&code.to_string());
    }
    let spent = status.duration_ms.and_then(duration_label).unwrap_or_default();
    (failure, spent)
}

/// The whole status as one string — what the header reads out, and what its width is measured from.
///
/// The two halves are joined by two spaces, the same gap the painter leaves between the runs it
/// draws them as. ⚠️ Keep this the ONE arithmetic: a width computed from a differently-joined
/// string would right-align the status against a length nothing on the row actually occupies.
#[must_use]
pub(crate) fn status_label(status: BlockStatus) -> String {
    let (failure, spent) = status_parts(status);
    match (failure.is_empty(), spent.is_empty()) {
        (true, _) => spent,
        (false, true) => failure,
        (false, false) => format!("{failure}{STATUS_GAP}{spent}"),
    }
}

/// What parts a failure's code from its duration. Two cells, so the number and the time never read
/// as one figure in a monospaced face.
const STATUS_GAP: &str = "  ";

/// A duration a reader can take in at a glance, or `None` for one too short to be worth the ink.
///
/// The threshold is the point of the function: almost every command in a session finishes in
/// milliseconds, and printing `0.01s` on all of them would make the header noise that hides the one
/// slow command it exists to mark.
#[must_use]
fn duration_label(ms: u32) -> Option<String> {
    if ms < 1000 {
        return None;
    }
    let seconds = f64::from(ms) / 1000.0;
    if seconds < 60.0 {
        return Some(format!("{seconds:.1}s"));
    }
    // Truncation is the format, not a loss: a command past a minute is reported as whole minutes
    // and whole seconds, and a fractional second inside `4m 7s` would be ink nobody reads.
    #[expect(
        clippy::integer_division,
        reason = "minutes and seconds are whole by definition"
    )]
    let (minutes, seconds) = {
        let whole = ms / 1000;
        (whole / 60, whole % 60)
    };
    Some(format!("{minutes}m {seconds}s"))
}

/// Draws the furniture for every visible block, plus the scrollbar.
///
/// Runs AFTER the text pass and writes to both ends of the list: the gutter, the divider and the
/// hover wash are backgrounds, because output has to read over them; the scrollbar is an overlay,
/// because it is the one thing that must never be hidden by a wide line of output.
///
/// `text` is the pass's own [`PaintStyle`] rather than a second copy of the font facts, so a chrome
/// label can never be shaped at a size the output beside it is not.
#[expect(
    clippy::too_many_arguments,
    reason = "the list, its design, its frame, the font stack, the atlas and the sink — each used once"
)]
pub fn paint(
    layout: &BlockLayout,
    style: &ChromeStyle,
    frame: &ChromeFrame,
    statuses: &[Option<BlockStatus>],
    text: &PaintStyle,
    cache: &mut GlyphCache,
    shaper: &mut impl TextShaper,
    rasterizer: &mut impl GlyphRasterizer,
    out: &mut DrawList,
) {
    for (index, block) in layout.blocks.iter().enumerate() {
        if !block.is_visible() {
            continue;
        }
        // Into the drawable's space ONCE, at the top, so no helper below can be written against a
        // content-space rect: everything past this line is where it will land on screen. The two
        // terms are the same ones `crate::paint` adds to every row it places, which is the point —
        // a gutter drawn at `body.y` while its rows draw at `content_origin_y + body.y` slid down
        // the drawable by the whole scroll offset.
        let block = &block.translated(text.geometry.metrics.origin_x, text.content_origin_y);
        if frame.hovered == Some(index) {
            out.push_background(solid(block.frame, style.hover));
        }
        // The divider goes at the block's TOP rather than its bottom, and the first block skips it:
        // a line above the newest block would be a line hanging under nothing once that block is
        // the only one on screen.
        if index > 0 {
            out.push_background(solid(
                Rect {
                    height: f64::max(style.divider_thickness, 1.0),
                    ..block.frame
                },
                style.divider,
            ));
        }
        let active = frame.active == Some(index);
        paint_gutter(block, style, active, out);
        paint_mark(block, style, text, cache, shaper, rasterizer, out);
        // Read positionally, and a short slice means "nothing known" for the rest — the same rule
        // `lay_out` reads `collapsed` by, so a caller whose records lag a resize by one frame draws
        // yesterday's header rather than panicking.
        //
        // The ACTIVE block never wears one, whatever the caller passed. It is by definition the
        // block whose command has not finished, so it has no outcome to print — and the
        // join upstream can still hand one over: retype a command the newest record already
        // holds (`clear`, `ls`) and the text check confirms an anchor that maps the live
        // prompt onto the PREVIOUS run. That would print a stale `✗ 1` under a command the
        // user has not even entered yet. Nothing is lost by the skip, since a running
        // block's label is empty either way.
        if let (false, Some(Some(status))) = (active, statuses.get(index)) {
            paint_status(block, *status, style, text, cache, shaper, rasterizer, out);
        }
    }
    paint_scrollbar(style, frame, out);
}

/// The bar down a block's leading edge.
///
/// Along the BODY and not the whole frame: the bar names the rows, and running it up through the
/// header would put it beside the collapse mark, where it reads as part of the control rather than
/// as the block's own edge.
fn paint_gutter(block: &PlacedBlock, style: &ChromeStyle, active: bool, out: &mut DrawList) {
    let ink = if active { style.gutter_active } else { style.gutter };
    out.push_background(solid(
        Rect {
            x: block.frame.x,
            y: block.body.y,
            width: style.gutter_thickness,
            height: block.body.height,
        },
        ink,
    ));
}

/// The collapse mark, and the row count a collapse folded away.
///
/// Only a block with a header gets one — an orphan has no command of its own to fold, and a
/// [`crate::block::Chrome::NONE`] block has nowhere to put the mark.
fn paint_mark(
    block: &PlacedBlock,
    style: &ChromeStyle,
    text: &PaintStyle,
    cache: &mut GlyphCache,
    shaper: &mut impl TextShaper,
    rasterizer: &mut impl GlyphRasterizer,
    out: &mut DrawList,
) {
    let Some(header) = block.header else {
        return;
    };
    if header.height <= 0.0 {
        return;
    }
    // Centred in the band by its own line height rather than by the glyph's ink, so the mark does
    // not jump between `v` and `>` — two characters whose ink boxes are different heights.
    let geometry = text.geometry;
    let baseline = header.y + (header.height - geometry.metrics.cell_height) / 2.0 + geometry.font.baseline;

    // A triangle rather than ASCII `>`/`v`: in a monospaced face at output size, a lone `v` reads
    // as the LETTER v sitting where a command's first character would be, and the mark has to
    // be the one thing on the header row that is obviously not text.
    let mut mark = String::new();
    mark.push(if block.collapsed { '▸' } else { '▾' });
    if block.collapsed {
        let folded = block.span.output_rows();
        if folded > 0 {
            mark.push_str("  ");
            mark.push_str(&folded.to_string());
            mark.push_str(if folded == 1 { " line" } else { " lines" });
        }
    }

    label(
        &mark,
        header.x,
        baseline,
        style.label,
        text.size_px,
        cache,
        shaper,
        rasterizer,
        out,
    );
}

/// The exit code and duration, against the header's trailing edge.
///
/// Right-aligned, and that is the whole layout decision: the command text starts at the left and is
/// as long as it is, so a status pinned to the left would sit at a different column on every block
/// and a status after the text would wander. Against the trailing edge the numbers stack in one
/// column, which is what makes a failed block findable by scrolling rather than by reading.
///
/// TWO runs, one ink each. The `✗ <code>` takes [`ChromeStyle::status_err`] — the island's own ANSI
/// red, which is why this stopped being "a token invented on the Rust side of a design system that
/// lives in Swift" and became a colour the profile already publishes — and the duration keeps
/// [`ChromeStyle::label`]. Shaped separately rather than as one run with a colour break, because a
/// run is the shaper's unit and splitting one afterwards would put this file in the business of
/// counting glyphs back to a character index.
#[expect(
    clippy::too_many_arguments,
    reason = "the same stack `paint_mark` takes, plus the status it prints"
)]
fn paint_status(
    block: &PlacedBlock,
    status: BlockStatus,
    style: &ChromeStyle,
    text: &PaintStyle,
    cache: &mut GlyphCache,
    shaper: &mut impl TextShaper,
    rasterizer: &mut impl GlyphRasterizer,
    out: &mut DrawList,
) {
    let Some(header) = block.header else {
        return;
    };
    if header.height <= 0.0 {
        return;
    }
    let geometry = text.geometry;
    let baseline = header.y + (header.height - geometry.metrics.cell_height) / 2.0 + geometry.font.baseline;
    status_columns(
        status, header, baseline, style, text, cache, shaper, rasterizer, out,
    );
}

/// The status itself, right-aligned inside `header` and sitting on `baseline`.
///
/// Its own function because the pinned head prints the SAME status in the same column while the
/// real header is scrolled off ([`crate::pin`]), and a second copy of this arithmetic there would
/// be two right-alignments to keep agreeing — the exact thing that would let the head and the
/// header disagree about where a number sits, or about which half is red.
#[expect(
    clippy::too_many_arguments,
    reason = "the painter's stack, plus the header row it is placed in"
)]
pub(crate) fn status_columns(
    status: BlockStatus,
    header: Rect,
    baseline: f64,
    style: &ChromeStyle,
    text: &PaintStyle,
    cache: &mut GlyphCache,
    shaper: &mut impl TextShaper,
    rasterizer: &mut impl GlyphRasterizer,
    out: &mut DrawList,
) {
    let printed = status_label(status);
    if printed.is_empty() {
        return;
    }
    let geometry = text.geometry;
    let Ok(cells) = u16::try_from(printed.chars().count()) else {
        return;
    };
    // One cell of air off the edge, so the last glyph is not flush against the scrollbar's track.
    let width = f64::from(cells) * geometry.metrics.cell_width;
    let x = header.x + header.width - width - geometry.metrics.cell_width;
    // A header narrow enough that the status would collide with the collapse mark prints nothing:
    // the mark is the control, and a number overlapping it would break the one thing on the row a
    // pointer has to be able to hit.
    if x <= header.x + geometry.metrics.cell_width {
        return;
    }
    let (failure, spent) = status_parts(status);
    // The duration's column is the failure's length plus the gap, measured in CELLS off the same
    // origin the whole label was aligned from — never `x + measured width of the first run`, which
    // would let a shaper that reports a different advance for `✗` drift the two runs apart.
    let gap = if failure.is_empty() {
        0
    } else {
        STATUS_GAP.chars().count()
    };
    let after_failure = u16::try_from(failure.chars().count().saturating_add(gap)).unwrap_or(u16::MAX);
    let spent_x = x + f64::from(after_failure) * geometry.metrics.cell_width;
    label(
        &failure,
        x,
        baseline,
        style.status_err,
        text.size_px,
        cache,
        shaper,
        rasterizer,
        out,
    );
    label(
        &spent,
        spent_x,
        baseline,
        style.label,
        text.size_px,
        cache,
        shaper,
        rasterizer,
        out,
    );
}

/// The scrollbar thumb, against the trailing edge of the content box.
fn paint_scrollbar(style: &ChromeStyle, frame: &ChromeFrame, out: &mut DrawList) {
    let Some(thumb) = frame.thumb else {
        return;
    };
    if style.scrollbar_thickness <= 0.0 {
        return;
    }
    out.push_overlay(solid(
        Rect {
            x: frame.viewport.x + frame.viewport.width - style.scrollbar_thickness - style.scrollbar_inset,
            y: frame.viewport.y + thumb.y,
            width: style.scrollbar_thickness,
            height: thumb.height,
        },
        style.scrollbar,
    ));
}

/// Shapes one chrome string onto the cell grid and emits its glyphs.
///
/// The cell count is CHARACTERS, not bytes: the collapse mark is a triangle, and handing a shaper a
/// byte length for it would claim three cells for one column. Every chrome string is one column per
/// character by construction — no combining marks, no emoji, no wide characters — so counting
/// `chars` is the whole conversion rather than a width table.
///
/// One column of triangle is also the whole of what leaves the shaper's ASCII fast path, and it
/// leaves it on purpose: falling through to `CTLine` is what finds the face that has the glyph, and
/// a `.notdef` box would be worse than the slow path on ten headers a frame.
///
/// `size_px` is the OUTPUT's, always — `slopdesk-apple-text` resolves one size per stack and stamps
/// it on every key, so a second chrome size would not be a design choice this crate could honour,
/// it would be a run asking for a size the shaper has no face at.
#[expect(
    clippy::too_many_arguments,
    reason = "the text, its place, its ink, the font stack, the atlas and the sink — each used once"
)]
pub(crate) fn label(
    text: &str,
    origin_x: f64,
    baseline: f64,
    ink: Rgba,
    size_px: u16,
    cache: &mut GlyphCache,
    shaper: &mut impl TextShaper,
    rasterizer: &mut impl GlyphRasterizer,
    out: &mut DrawList,
) {
    if text.is_empty() || ink.is_invisible() {
        return;
    }
    let Ok(cells) = u16::try_from(text.chars().count()) else {
        return;
    };
    let mut glyphs: Vec<ShapedGlyph> = Vec::new();
    shaper.shape(
        &TextRun {
            text,
            start_col: 0,
            cells,
            bold: false,
            italic: false,
            size_px,
            subpixel: GlyphKey::phase(origin_x),
        },
        &mut glyphs,
    );

    for glyph in &glyphs {
        let Some(cached) = cache.get(glyph.key, rasterizer) else {
            continue;
        };
        if cached.is_blank() {
            continue;
        }
        let atlas = match cached.format {
            AtlasFormat::Alpha8 => cache.alpha_atlas(),
            AtlasFormat::Bgra8 => cache.color_atlas(),
        };
        out.push_glyph(GlyphInstance {
            x: px(origin_x + f64::from(glyph.x) + f64::from(cached.bearing_x)),
            y: px(baseline + f64::from(glyph.y) - f64::from(cached.bearing_y)),
            width: px(f64::from(cached.region.width)),
            height: px(f64::from(cached.region.height)),
            uv: atlas.uv(cached.region),
            color: ink,
            color_atlas: u32::from(cached.format == AtlasFormat::Bgra8),
        });
    }
}

/// One filled rect, which is every rect this module draws.
pub(crate) const fn solid(rect: Rect, color: Rgba) -> RectInstance {
    RectInstance {
        x: px(rect.x),
        y: px(rect.y),
        width: px(rect.width),
        height: px(rect.height),
        color,
        style: RectStyle::Solid,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::panic,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::geometry::{CellMetrics, Rect};

    use super::{BlockStatus, ChromeFrame, ChromeStyle, paint, status_label};
    use crate::atlas::AtlasFormat;
    use crate::block::{BlockLayout, BlockSpan, PlacedBlock, RowRange};
    use crate::glyph::{
        GlyphCache, GlyphKey, GlyphRasterizer, RasterGlyph, ShapedGlyph, TextRun, TextShaper,
    };
    use crate::layout::{CellGeometry, FontMetrics, Thumb};
    use crate::paint::{PaintStyle, SelectionColors};
    use crate::quad::{DrawList, Rgba};

    /// One glyph per char, a cell apart — the same fake the paint pass tests with.
    #[derive(Debug, Default)]
    struct OneToOne {
        runs: Vec<String>,
    }

    impl TextShaper for OneToOne {
        fn shape(&mut self, run: &TextRun<'_>, out: &mut Vec<ShapedGlyph>) {
            self.runs.push(run.text.to_owned());
            for (index, ch) in run.text.chars().enumerate() {
                let offset = u16::try_from(index).unwrap_or(u16::MAX);
                out.push(ShapedGlyph {
                    key: GlyphKey {
                        font: 0,
                        glyph: ch as u32,
                        size_px: run.size_px,
                        subpixel: run.subpixel,
                        synthetic: crate::glyph::Synthetic {
                            bold: run.bold,
                            italic: run.italic,
                        },
                    },
                    x: f32::from(offset) * 10.0,
                    y: 0.0,
                    cell: offset,
                });
            }
        }
    }

    /// Every glyph an 8×8 square.
    #[derive(Debug)]
    struct Square;

    impl GlyphRasterizer for Square {
        fn rasterize(&mut self, _key: GlyphKey) -> Option<RasterGlyph> {
            Some(RasterGlyph {
                width: 8,
                height: 8,
                bearing_x: 0.0,
                bearing_y: 8.0,
                format: AtlasFormat::Alpha8,
                pixels: vec![0xFF; 64],
            })
        }
    }

    fn text_style() -> PaintStyle {
        PaintStyle {
            geometry: CellGeometry {
                metrics: CellMetrics {
                    cell_width: 10.0,
                    cell_height: 20.0,
                    origin_x: 0.0,
                    origin_y: 0.0,
                },
                font: FontMetrics {
                    baseline: 15.0,
                    underline_position: 17.0,
                    underline_thickness: 1.0,
                    strikethrough_position: 10.0,
                    strikethrough_thickness: 1.0,
                    cursor_thickness: 2.0,
                },
            },
            size_px: 24,
            content_origin_y: 0.0,
            selection: SelectionColors {
                background: Rgba::opaque(40, 60, 90),
                foreground: None,
            },
            focused: true,
            blink_visible: true,
            cursor_opacity: 1.0,
            cursor_text: None,
            arrow_box_drawing_join: true,
        }
    }

    fn style() -> ChromeStyle {
        ChromeStyle {
            divider: Rgba::opaque(1, 1, 1),
            divider_thickness: 1.0,
            gutter: Rgba::opaque(2, 2, 2),
            gutter_active: Rgba::opaque(3, 3, 3),
            gutter_thickness: 2.0,
            hover: Rgba::opaque(4, 4, 4),
            label: Rgba::opaque(5, 5, 5),
            status_err: Rgba::opaque(7, 7, 7),
            scrollbar: Rgba::opaque(6, 6, 6),
            scrollbar_thickness: 4.0,
            scrollbar_min_height: 24.0,
            scrollbar_inset: 4.0,
        }
    }

    fn frame() -> ChromeFrame {
        ChromeFrame {
            hovered: None,
            active: None,
            viewport: Rect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            thumb: None,
        }
    }

    /// `count` stacked 60px blocks, each with a 20px header, all on screen.
    fn layout(count: u16, collapsed: bool) -> BlockLayout {
        let blocks = (0..count)
            .map(|index| {
                let top = f64::from(index) * 60.0;
                PlacedBlock {
                    span: BlockSpan {
                        rows: RowRange {
                            start: index * 3,
                            end: index * 3 + 3,
                        },
                        prompt_rows: 1,
                    },
                    frame: Rect {
                        x: 0.0,
                        y: top,
                        width: 400.0,
                        height: 60.0,
                    },
                    header: Some(Rect {
                        x: 14.0,
                        y: top,
                        width: 386.0,
                        height: 20.0,
                    }),
                    body: Rect {
                        x: 14.0,
                        y: top + 20.0,
                        width: 386.0,
                        height: 40.0,
                    },
                    collapsed,
                    visible: RowRange {
                        start: index * 3,
                        end: index * 3 + 3,
                    },
                }
            })
            .collect();
        BlockLayout {
            blocks,
            content_height: f64::from(count) * 60.0,
        }
    }

    /// A header prints a failure's code and a slow command's duration.
    #[test]
    fn a_failed_block_leads_with_its_code() {
        assert_eq!(
            status_label(BlockStatus {
                exit_code: Some(1),
                duration_ms: Some(2400),
            }),
            "✗ 1  2.4s"
        );
    }

    /// Success prints the duration alone — no ✓ on the majority case.
    #[test]
    fn a_slow_success_prints_only_its_duration() {
        assert_eq!(
            status_label(BlockStatus {
                exit_code: Some(0),
                duration_ms: Some(65_000),
            }),
            "1m 5s"
        );
    }

    /// ⚠️ The case that keeps the column quiet: almost every command is fast and succeeds, and a
    /// header that printed `0.0s` on all of them would bury the one it exists to mark.
    #[test]
    fn a_fast_success_prints_nothing_at_all() {
        assert_eq!(
            status_label(BlockStatus {
                exit_code: Some(0),
                duration_ms: Some(12),
            }),
            ""
        );
    }

    /// A fast FAILURE still prints, because the code is the point, not the time.
    #[test]
    fn a_fast_failure_still_prints_its_code() {
        assert_eq!(
            status_label(BlockStatus {
                exit_code: Some(127),
                duration_ms: Some(3),
            }),
            "✗ 127"
        );
    }

    /// A running block says nothing — the accented gutter already says it.
    #[test]
    fn a_running_block_prints_nothing() {
        assert_eq!(
            status_label(BlockStatus {
                exit_code: None,
                duration_ms: None,
            }),
            ""
        );
    }

    /// The status reaches the header, and a block with no status leaves it alone.
    #[test]
    fn the_status_is_shaped_onto_the_header() {
        let layout = layout(2, false);
        let statuses = [
            None,
            Some(BlockStatus {
                exit_code: Some(2),
                duration_ms: Some(5000),
            }),
        ];
        let (_, runs) = draw_with(&layout, &style(), &frame(), &statuses, &text_style());
        // TWO runs, because the two halves take different inks — the joined string is what the
        // WIDTH is measured from, not what is shaped.
        assert!(runs.iter().any(|run| run == "✗ 2"), "{runs:?}");
        assert!(runs.iter().any(|run| run == "5.0s"), "{runs:?}");
        assert_eq!(
            runs.iter().filter(|run| run.starts_with('✗')).count(),
            1,
            "only the block with a record got one"
        );
    }

    /// ⚠️ The failure wears the error ink and the duration does not — one status, two inks.
    ///
    /// Asserted on the GLYPHS rather than on the runs, because a shaper that returned the right two
    /// strings in one colour is exactly the regression this exists to catch: a reader scanning a
    /// scrollback for a red mark would find every slow command wearing one.
    #[test]
    fn only_the_failure_half_takes_the_error_ink() {
        let layout = layout(1, false);
        let statuses = [Some(BlockStatus {
            exit_code: Some(2),
            duration_ms: Some(5000),
        })];
        let (drawn, _) = draw_with(&layout, &style(), &frame(), &statuses, &text_style());
        let failed: Vec<_> = drawn
            .glyphs
            .iter()
            .filter(|glyph| glyph.color == style().status_err)
            .collect();
        // The collapse mark shares `label`, so the duration is the label ink RIGHT of the status's
        // own origin — everything else in that ink is at the header's leading edge.
        let quiet: Vec<_> = drawn
            .glyphs
            .iter()
            .filter(|glyph| glyph.color == style().label && glyph.x > 200.0)
            .collect();
        assert_eq!(
            failed.len(),
            3,
            "`✗`, a space and `2` — and nothing of the duration"
        );
        assert_eq!(quiet.len(), 4, "`5.0s`, in the ink every other header word takes");
        // The duration follows the failure across the row rather than sitting on top of it.
        let rightmost_failure = failed.iter().map(|glyph| glyph.x).fold(f32::MIN, f32::max);
        let leftmost_quiet = quiet.iter().map(|glyph| glyph.x).fold(f32::MAX, f32::min);
        assert!(
            leftmost_quiet > rightmost_failure,
            "{leftmost_quiet} vs {rightmost_failure}"
        );
    }

    /// A successful block's duration starts where a failure would have — at the left of the whole
    /// status — rather than being pushed right by a gap that has nothing in front of it.
    #[test]
    fn a_success_spends_no_room_on_the_mark_it_does_not_print() {
        let layout = layout(1, false);
        let statuses = [Some(BlockStatus {
            exit_code: Some(0),
            duration_ms: Some(5000),
        })];
        let (drawn, runs) = draw_with(&layout, &style(), &frame(), &statuses, &text_style());
        assert_eq!(
            runs.iter().filter(|run| !run.is_empty()).count(),
            2,
            "the mark and the time"
        );
        assert!(runs.iter().any(|run| run == "5.0s"), "{runs:?}");
        assert!(
            !drawn.glyphs.iter().any(|glyph| glyph.color == style().status_err),
            "nothing failed, so nothing wears the failure ink"
        );
        let time = drawn
            .glyphs
            .iter()
            .filter(|glyph| glyph.color == style().label && glyph.x > 200.0)
            .map(|glyph| glyph.x)
            .fold(f32::MAX, f32::min);
        // Four cells of `5.0s` plus one of air off a header that ends at 400, at 10px cells — the
        // same trailing edge the failed case lands its LAST glyph on.
        assert!((time - 350.0).abs() < f32::EPSILON, "{time}");
    }

    /// The active block refuses a status even when one is handed to it.
    ///
    /// Not a redundant guard over `a_running_block_prints_nothing`: that one covers the status the
    /// caller KNOWS is unfinished. This is the caller getting it WRONG — the join confirming a
    /// stale anchor because the user retyped a command the newest record already holds — and
    /// the paint dropping it anyway.
    #[test]
    fn the_active_block_refuses_a_status_it_is_handed() {
        let layout = layout(2, false);
        let statuses = [
            None,
            Some(BlockStatus {
                exit_code: Some(1),
                duration_ms: Some(200),
            }),
        ];
        let (_, runs) = draw_with(
            &layout,
            &style(),
            &ChromeFrame {
                active: Some(1),
                ..frame()
            },
            &statuses,
            &text_style(),
        );
        assert!(!runs.iter().any(|run| run.starts_with('✗')), "{runs:?}");
    }

    fn draw(layout: &BlockLayout, style: &ChromeStyle, frame: &ChromeFrame) -> (DrawList, Vec<String>) {
        draw_with(layout, style, frame, &[], &text_style())
    }

    fn draw_with(
        layout: &BlockLayout,
        style: &ChromeStyle,
        frame: &ChromeFrame,
        statuses: &[Option<BlockStatus>],
        text: &PaintStyle,
    ) -> (DrawList, Vec<String>) {
        let mut out = DrawList::new();
        let mut cache = GlyphCache::new();
        let mut shaper = OneToOne::default();
        paint(
            layout,
            style,
            frame,
            statuses,
            text,
            &mut cache,
            &mut shaper,
            &mut Square,
            &mut out,
        );
        (out, shaper.runs)
    }

    #[test]
    fn the_first_block_takes_no_divider() {
        let (drawn, _) = draw(&layout(3, false), &style(), &frame());
        let dividers = drawn
            .backgrounds
            .iter()
            .filter(|rect| rect.color == style().divider)
            .count();
        assert_eq!(dividers, 2, "three blocks have two seams between them, not three");
    }

    #[test]
    fn the_active_block_is_the_only_one_wearing_the_accent() {
        let (drawn, _) = draw(&layout(3, false), &style(), &ChromeFrame {
            active: Some(1),
            ..frame()
        });
        let accented: Vec<_> = drawn
            .backgrounds
            .iter()
            .filter(|rect| rect.color == style().gutter_active)
            .collect();
        assert_eq!(accented.len(), 1);
        // The bar runs down the BODY, so it starts below that block's header.
        assert!((accented[0].y - 80.0).abs() < f32::EPSILON);
        assert!((accented[0].height - 40.0).abs() < f32::EPSILON);
    }

    #[test]
    fn only_a_hovered_block_takes_the_wash() {
        let plain = draw(&layout(2, false), &style(), &frame()).0;
        assert!(
            !plain.backgrounds.iter().any(|rect| rect.color == style().hover),
            "nothing is hovered, so nothing is washed"
        );

        let hovered = draw(&layout(2, false), &style(), &ChromeFrame {
            hovered: Some(1),
            ..frame()
        })
        .0;
        let washes: Vec<_> = hovered
            .backgrounds
            .iter()
            .filter(|rect| rect.color == style().hover)
            .collect();
        assert_eq!(washes.len(), 1);
        assert!(
            (washes[0].height - 60.0).abs() < f32::EPSILON,
            "the whole block, not its body"
        );
    }

    #[test]
    fn a_collapsed_block_says_how_many_rows_it_folded() {
        let (_, runs) = draw(&layout(1, true), &style(), &frame());
        assert_eq!(runs, vec!["▸  2 lines".to_owned()]);

        let (_, open) = draw(&layout(1, false), &style(), &frame());
        assert_eq!(open, vec!["▾".to_owned()], "an open block only offers the fold");
    }

    #[test]
    fn one_folded_row_is_a_line_rather_than_lines() {
        let mut single = layout(1, true);
        single.blocks[0].span.prompt_rows = 2;
        let (_, runs) = draw(&single, &style(), &frame());
        assert_eq!(runs, vec!["▸  1 line".to_owned()]);
    }

    #[test]
    fn an_orphan_gets_no_mark_because_it_has_no_command_to_fold() {
        let mut orphan = layout(1, true);
        orphan.blocks[0].header = None;
        orphan.blocks[0].span.prompt_rows = 0;
        let (drawn, runs) = draw(&orphan, &style(), &frame());
        assert!(runs.is_empty());
        assert!(
            drawn.backgrounds.iter().any(|rect| rect.color == style().gutter),
            "it is still a block, and still wears its edge"
        );
    }

    #[test]
    fn the_scrollbar_is_an_overlay_against_the_trailing_edge() {
        let bare = draw(&layout(2, false), &style(), &frame()).0;
        assert!(bare.overlays.is_empty(), "everything fits, so there is no thumb");

        let scrolled = draw(&layout(2, false), &style(), &ChromeFrame {
            thumb: Some(Thumb {
                y: 30.0,
                height: 50.0,
            }),
            ..frame()
        })
        .0;
        assert_eq!(scrolled.overlays.len(), 1);
        let thumb = scrolled.overlays[0];
        // 400 wide, 4 of thickness and 4 of inset off the right edge.
        assert!((thumb.x - 392.0).abs() < f32::EPSILON);
        assert!((thumb.y - 30.0).abs() < f32::EPSILON);
        assert!((thumb.height - 50.0).abs() < f32::EPSILON);
    }

    #[test]
    fn the_alternate_screen_is_handed_nothing_and_draws_nothing() {
        let (drawn, runs) = draw(&layout(3, false), &ChromeStyle::NONE, &frame());
        assert!(drawn.is_empty(), "a full-screen program owns every cell");
        assert!(runs.is_empty());
    }

    #[test]
    fn a_block_off_screen_costs_nothing() {
        let mut scrolled = layout(2, false);
        scrolled.blocks[0].visible = RowRange { start: 0, end: 0 };
        let (drawn, _) = draw(&scrolled, &style(), &frame());
        assert!(
            !drawn
                .backgrounds
                .iter()
                .any(|rect| rect.y < 0.5 && rect.color == style().gutter),
            "the culled block drew no edge"
        );
    }

    /// ⚠️ The furniture has to land in the SAME space as the rows it decorates.
    ///
    /// [`crate::block::lay_out`] measures the content from the top of the first block, at x zero.
    /// The paint pass puts a row at `content_origin_y + row_y` and `origin_x + body.x`, where
    /// `content_origin_y` carries the top inset AND the scroll offset together. A chrome pass that
    /// emitted a block's rect verbatim therefore drew the gutter, the divider and the header band
    /// where the rows would have been at scroll zero — off by the inset at rest, and by the WHOLE
    /// scroll offset the moment anyone scrolled.
    ///
    /// It shipped that way because every other test in this module runs at the origin, which is
    /// the one offset where the two spaces coincide and the bug is invisible. This one runs at a
    /// nonzero inset AND a nonzero scroll, on both axes, for that reason.
    #[test]
    fn the_furniture_lands_on_the_rows_it_decorates() {
        let scrolled = PaintStyle {
            geometry: CellGeometry {
                metrics: CellMetrics {
                    origin_x: 12.0,
                    ..text_style().geometry.metrics
                },
                ..text_style().geometry
            },
            // The top inset less a screen of scroll — what `Surface::draw` hands the paint pass.
            content_origin_y: 8.0 - 300.0,
            ..text_style()
        };
        let laid = layout(3, false);
        let (drawn, _) = draw_with(
            &laid,
            &style(),
            &ChromeFrame {
                hovered: Some(1),
                ..frame()
            },
            &[],
            &scrolled,
        );

        let middle = &laid.blocks[1];
        let Some(gutter) = drawn
            .backgrounds
            .iter()
            .filter(|rect| rect.color == style().gutter)
            .nth(1)
        else {
            panic!("every visible block wears an edge")
        };
        let Some(body_top) = middle.row_y(middle.span.rows.start, 20.0) else {
            panic!("a block holds its own first row")
        };
        // Spelled the way `crate::paint` spells it, so the assertion is the other pass's arithmetic
        // rather than a number copied out of it.
        let row_top = scrolled.content_origin_y + body_top;
        assert!(
            (f64::from(gutter.y) - row_top).abs() < 1e-4,
            "the edge at {} against rows at {row_top}",
            gutter.y
        );
        assert!(
            (f64::from(gutter.x) - scrolled.geometry.metrics.origin_x).abs() < 1e-4,
            "the leading edge sits on the content box, not on x zero"
        );

        // The mark starts on the column the command's own text starts on.
        let column = scrolled.geometry.metrics.origin_x + middle.body.x;
        assert!(
            drawn
                .glyphs
                .iter()
                .all(|glyph| (f64::from(glyph.x) - column).abs() < 1e-4),
            "a chrome label drifted off the command's column"
        );

        // And the wash covers the block, not the place it would sit at rest.
        let Some(wash) = drawn.backgrounds.iter().find(|rect| rect.color == style().hover) else {
            panic!("the hovered block takes a wash")
        };
        assert!((f64::from(wash.y) - (scrolled.content_origin_y + middle.frame.y)).abs() < 1e-4);
    }
}
