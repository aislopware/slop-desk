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
//! and the scrollbar. Not an exit code and not a duration: `libghostty-vt` surfaces OSC 133 as
//! three row states — none, prompt, continuation — and exposes no command-end callback at all, so
//! the engine genuinely does not know how a command ended. `docs/68` §5.3 records the fix, and it
//! is a shell-integration change rather than a rendering one. Counting prompts from the bottom to
//! index the host's ring would be exactly the heuristic [`crate::block`] refuses.
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
        paint_gutter(block, style, frame.active == Some(index), out);
        paint_mark(block, style, text, cache, shaper, rasterizer, out);
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
fn label(
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
const fn solid(rect: Rect, color: Rgba) -> RectInstance {
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
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::geometry::{CellMetrics, Rect};

    use super::{ChromeFrame, ChromeStyle, paint};
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

    fn draw(layout: &BlockLayout, style: &ChromeStyle, frame: &ChromeFrame) -> (DrawList, Vec<String>) {
        let mut out = DrawList::new();
        let mut cache = GlyphCache::new();
        let mut shaper = OneToOne::default();
        paint(
            layout,
            style,
            frame,
            &text_style(),
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
}
