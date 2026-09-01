//! Inline images: the CPU-side pixel cache, and where a placement lands on a block layout.
//!
//! ## Two caches, one generation
//!
//! [`ImageStore`] holds every visible image's pixels; `slopdesk-apple-metal` holds a `MTLTexture`
//! per image beside it. That is the same split [`crate::Atlas`] and its `AtlasTexture` already
//! have, and for the same reason: the decision about what is stale is arithmetic, so it lives in
//! the `forbid(unsafe_code)` crate, and the upload is a framework call, so it lives in the
//! `apple-*` one. The staleness key is the engine's GENERATION and never the dimensions — a program
//! that redraws a chart in place retransmits the same id at the same size with different pixels,
//! which is the case a size heuristic cannot see and the case that happens every second.
//!
//! ## Placing an image is a BLOCK-layout problem, which is the whole reason `docs/68` exists
//!
//! The engine answers where a placement sits in VIEWPORT ROWS. Under block layout a row's y is not
//! `row × cell_height` — headers, gaps and collapses put it somewhere only [`BlockLayout`] knows —
//! so the row is looked up exactly the way [`crate::paint`] looks one up, through
//! [`crate::block::PlacedBlock::row_y`]. An image and the text beside it therefore cannot disagree
//! about where their row is, because neither computes it.
//!
//! ## An image is clipped to its own block, and that is a decision rather than a formality
//!
//! A placement is `rows` tall, and nothing in the protocol stops those rows from running past the
//! end of the command that emitted them. Under a flat grid that is harmless; under block layout the
//! next thing down is the NEXT command's header, and an image spilling over it would paint over
//! furniture that describes a different command. So the destination is intersected with the block's
//! own body, and the source rectangle is narrowed by the same fraction — which is what makes the
//! clip a crop rather than a squash.
//!
//! The same intersection does the scrolled-off case for free. The engine reports a NEGATIVE row for
//! a placement whose top has scrolled above the viewport, and the anchor is therefore taken at row
//! zero with the off-screen rows subtracted from the source, rather than at a row the frame does
//! not have.
//!
//! ## Device pixels, like everything else in this crate
//!
//! Every pixel number that arrives here is already a device pixel, because the engine was told the
//! cell's device-pixel size when the session was built and every size it computes rides on that.
//! There is no scale factor in this module and there must not be one.

use std::collections::HashMap;

use slopdesk_terminal::geometry::Rect;
pub use slopdesk_vterm::{ImageMeta, ImagePixels, ImagePlacement};

use crate::block::BlockLayout;
use crate::paint::PaintStyle;
use crate::quad::{DrawList, ImageInstance, ImageLayer, px};

/// The z index at or above which a placement is drawn over the text.
///
/// The protocol's own boundary: `z >= 0` is in front. Named rather than inlined because the other
/// boundary below is derived from it and the pair only reads as a partition when both are here.
const ABOVE_TEXT_Z: i32 = 0;

/// The z index below which a placement is drawn behind even the cell BACKGROUND.
///
/// The kitty protocol's own boundary, not a choice: it splits the negative half into "behind the
/// background" and "behind the text but in front of the background", and a terminal that picked its
/// own split would put an image on the wrong side of a colour the program expected to see through.
/// Spelled as the literal `i32::MIN / 2` rather than the division, because the crate denies
/// `integer_division` — a rule aimed at arithmetic that silently truncates, which this is not.
pub const BELOW_BACKGROUND_Z: i32 = -1_073_741_824;

/// Classifies a placement's z index into the band that decides when it is drawn.
#[must_use]
pub const fn layer_of(z: i32) -> ImageLayer {
    if z >= ABOVE_TEXT_Z {
        ImageLayer::AboveText
    } else if z >= BELOW_BACKGROUND_Z {
        ImageLayer::BelowText
    } else {
        ImageLayer::BelowBackground
    }
}

/// One image's pixels, and the stamp that says whether they are still current.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredImage {
    /// Which image, how old, and how big.
    pub meta: ImageMeta,
    /// `width × height × 4` bytes of straight-alpha RGBA8, exactly as the engine handed them over.
    pub rgba: Vec<u8>,
    /// Bumped every time [`Self::rgba`] is replaced.
    ///
    /// The GPU mirror keys on this rather than on [`ImageMeta::generation`] for one reason: the two
    /// agree today and would part the moment an image were ever re-fetched for a reason other than
    /// a content change, and a mirror that keyed on the engine's stamp would then quietly keep a
    /// texture of the previous pixels. One number, owned by the thing that decides when to replace.
    pub revision: u64,
}

/// Every image the last frame could see, keyed by the protocol's image id.
///
/// Bounded by what is PLACED rather than by a count: [`ImageStore::retain`] drops everything the
/// current frame did not name, so a session that scrolls past a hundred images holds only the ones
/// on screen. An LRU with a fixed ceiling was the alternative and would have been worse in both
/// directions — too small and a scroll re-copies megabytes per frame, too large and a pane keeps
/// pixels nothing can ever draw.
#[derive(Debug, Clone, Default)]
pub struct ImageStore {
    images: HashMap<u32, StoredImage>,
    revisions: u64,
}

impl ImageStore {
    /// An empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether `meta` describes pixels this store does not already hold.
    #[must_use]
    pub fn is_stale(&self, meta: ImageMeta) -> bool {
        self.images
            .get(&meta.id)
            .is_none_or(|stored| stored.meta.generation != meta.generation)
    }

    /// Takes `pixels` in, replacing whatever was held for that id.
    pub fn insert(&mut self, pixels: ImagePixels) {
        self.revisions = self.revisions.wrapping_add(1);
        self.images.insert(pixels.meta.id, StoredImage {
            meta: pixels.meta,
            rgba: pixels.rgba,
            revision: self.revisions,
        });
    }

    /// Drops every image whose id is not in `live`.
    pub fn retain(&mut self, live: &[u32]) {
        self.images.retain(|id, _| live.contains(id));
    }

    /// One image's pixels, if the store holds them.
    #[must_use]
    pub fn get(&self, id: u32) -> Option<&StoredImage> {
        self.images.get(&id)
    }

    /// Every image held, in no particular order.
    pub fn iter(&self) -> impl Iterator<Item = &StoredImage> {
        self.images.values()
    }

    /// How many images are held.
    #[must_use]
    pub fn len(&self) -> usize {
        self.images.len()
    }

    /// Whether nothing is held.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.images.is_empty()
    }
}

/// A placement's destination rectangle and the slice of its texture that fills it.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Placed {
    /// Where it draws, in device pixels.
    dest: Rect,
    /// The source rectangle inside the image, in IMAGE pixels — normalised only at the very end.
    source: Rect,
}

/// Whether every one of a rectangle's four numbers is a real number.
const fn finite(rect: Rect) -> bool {
    rect.x.is_finite() && rect.y.is_finite() && rect.width.is_finite() && rect.height.is_finite()
}

/// Narrows `placed` so its destination fits inside `bounds`, cropping the source to match.
///
/// A crop and not a squash: the fraction of the destination that survives is the fraction of the
/// source that is sampled, so the image keeps its scale and loses its edges. That is what a
/// terminal that scrolls has to do — the alternative squeezes a picture every time it crosses the
/// top of the viewport.
///
/// `None` when nothing survives, which is the ordinary answer for a placement inside a collapsed
/// block or one scrolled entirely past.
///
/// The finiteness check is FIRST and is not decoration. `CLAUDE.md` requires [`f64::max`] over a
/// `<` ternary for bit-exactness, and those two differ on exactly this input: `f64::max` implements
/// IEEE `maxNum`, which SWALLOWS a NaN and answers the other operand, so a NaN bound would be
/// silently replaced by the image's own edge and the placement would draw at full size in the wrong
/// place. Written as a comparison the intersections could be trusted to make, this would be a bug
/// that only appears when a metric upstream goes bad — measured here, not assumed.
fn clip(placed: Placed, bounds: Rect) -> Option<Placed> {
    if !(finite(placed.dest) && finite(placed.source) && finite(bounds)) {
        return None;
    }

    let left = f64::max(placed.dest.x, bounds.x);
    let top = f64::max(placed.dest.y, bounds.y);
    let right = f64::min(placed.dest.x + placed.dest.width, bounds.x + bounds.width);
    let bottom = f64::min(placed.dest.y + placed.dest.height, bounds.y + bounds.height);
    if !(right > left && bottom > top && placed.dest.width > 0.0 && placed.dest.height > 0.0) {
        return None;
    }

    // The four fractions of the destination that were cut, each turned into the same fraction of
    // the source. Every one is a separate `*` and `+` — `CLAUDE.md`'s bit-exactness rule — because
    // these land in a vertex buffer beside `layout.rs`'s numbers and a fused multiply-add here
    // would put a texel of drift between an image's edge and the cell it is supposed to align to.
    let cut_left = (left - placed.dest.x) / placed.dest.width;
    let cut_top = (top - placed.dest.y) / placed.dest.height;
    let kept_width = (right - left) / placed.dest.width;
    let kept_height = (bottom - top) / placed.dest.height;

    Some(Placed {
        dest: Rect {
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
        },
        source: Rect {
            x: placed.source.x + placed.source.width * cut_left,
            y: placed.source.y + placed.source.height * cut_top,
            width: placed.source.width * kept_width,
            height: placed.source.height * kept_height,
        },
    })
}

/// Turns `placed`'s image-pixel source rectangle into the normalised one a sampler reads.
///
/// A zero dimension answers the whole texture rather than a degenerate rectangle: it can only come
/// from an image the engine reported as zero-sized, which draws nothing anyway, and a division
/// there would put a NaN in a vertex buffer instead.
fn normalise(source: Rect, meta: ImageMeta) -> [f32; 4] {
    let (width, height) = (f64::from(meta.width), f64::from(meta.height));
    if !(width > 0.0 && height > 0.0) {
        return [0.0, 0.0, 1.0, 1.0];
    }
    [
        px(source.x / width),
        px(source.y / height),
        px((source.x + source.width) / width),
        px((source.y + source.height) / height),
    ]
}

/// Appends every placement that has somewhere to draw, in layer then z order.
///
/// `viewport` is the grid's own box in device pixels — the drawable minus its insets — and is the
/// outer clip. The inner one is each placement's own block, per this module's header.
///
/// A placement whose image the store does not hold is SKIPPED rather than drawn as a hole: the
/// pixels are still arriving in chunks, and a frame or two later they will be there. Drawing a
/// placeholder would put a flicker on every image transmission over a slow link, which is every
/// image transmission this app has.
pub fn place(
    placements: &mut [ImagePlacement],
    layout: &BlockLayout,
    style: &PaintStyle,
    viewport: Rect,
    store: &ImageStore,
    out: &mut DrawList,
) {
    // By layer, then by the protocol's own z, then by image so equal-z placements of one image
    // share a draw call. Sorted in place because the caller's buffer is scratch that is refilled
    // every frame, and a copy to sort would be an allocation on the render path.
    placements.sort_by_key(|placement| {
        (
            layer_of(placement.z),
            placement.z,
            placement.image_id,
            placement.placement_id,
        )
    });

    let metrics = style.geometry.metrics;
    for placement in &*placements {
        let Some(stored) = store.get(placement.image_id) else {
            continue;
        };

        // The anchor row. A negative row means the top has scrolled off, so row zero is where the
        // image's remaining rows start and `clip` below is what removes the rest — the arithmetic
        // is done once, by the intersection, rather than twice.
        let anchor = placement.row.max(0);
        let Ok(anchor) = u16::try_from(anchor) else {
            continue;
        };
        let Some(block) = layout.block_at_row(anchor) else {
            continue;
        };
        let Some(content_y) = block.row_y(anchor, metrics.cell_height) else {
            continue;
        };

        // Where row `placement.row` WOULD be, which for a negative row is above the anchor by
        // exactly the rows that scrolled off. Reconstructing it this way rather than clamping the
        // destination is what lets one intersection handle the scroll and the block edge together.
        let rows_above = f64::from(anchor) - f64::from(placement.row);
        // The cell offsets are the protocol's `X=`/`Y=` — a sub-cell nudge a program uses to line
        // an image up with something drawn beside it — and for a virtually placed image they are
        // the blank band the aspect fit left over. Added as separate terms, never folded into the
        // multiply, per `CLAUDE.md`'s bit-exactness rule: these numbers land in the same vertex
        // buffer as `layout.rs`'s, and a fused multiply-add here would drift an image's edge off
        // the cell it was placed to align with.
        let top = style.content_origin_y + content_y - metrics.cell_height * rows_above
            + f64::from(placement.cell_offset_y);
        let left = metrics.origin_x
            + block.body.x
            + metrics.cell_width * f64::from(placement.col)
            + f64::from(placement.cell_offset_x);

        let full = Placed {
            dest: Rect {
                x: left,
                y: top,
                width: f64::from(placement.width_px),
                height: f64::from(placement.height_px),
            },
            source: Rect {
                x: f64::from(placement.source_x),
                y: f64::from(placement.source_y),
                width: f64::from(placement.source_width),
                height: f64::from(placement.source_height),
            },
        };

        // [`PlacedBlock::body`] is in LAYOUT space — [`crate::paint`] adds the same two origins to
        // it before drawing a row, and `top`/`left` above already have. The clip has to be lifted
        // into screen space too, or a pane with a left inset would crop every image against a box
        // one inset to the left of where the image is.
        let body = Rect {
            x: metrics.origin_x + block.body.x,
            y: style.content_origin_y + block.body.y,
            width: block.body.width,
            height: block.body.height,
        };
        let Some(clipped) = clip(full, body).and_then(|placed| clip(placed, viewport)) else {
            continue;
        };
        out.push_image(placement.image_id, layer_of(placement.z), ImageInstance {
            x: px(clipped.dest.x),
            y: px(clipped.dest.y),
            width: px(clipped.dest.width),
            height: px(clipped.dest.height),
            uv: normalise(clipped.source, stored.meta),
        });
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::geometry::{CellMetrics, Rect};
    use slopdesk_vterm::{ImageMeta, ImagePixels, ImagePlacement};

    use super::{BELOW_BACKGROUND_Z, ImageStore, Placed, clip, layer_of, normalise, place};
    use crate::block::{BlockSpan, Chrome, RowRange, Viewport, lay_out};
    use crate::layout::FontMetrics;
    use crate::paint::{PaintStyle, SelectionColors};
    use crate::quad::{DrawList, ImageLayer};

    const CELL_W: f64 = 10.0;
    const CELL_H: f64 = 20.0;

    /// Whether two normalised source rectangles agree to within a device pixel of a 100px image.
    fn uv_eq(actual: [f32; 4], want: [f32; 4]) -> bool {
        actual
            .iter()
            .zip(want)
            .all(|(actual, want)| (f64::from(*actual) - f64::from(want)).abs() < 1e-6)
    }

    fn meta(id: u32, generation: u64) -> ImageMeta {
        ImageMeta {
            id,
            generation,
            width: 100,
            height: 100,
        }
    }

    fn pixels(id: u32, generation: u64) -> ImagePixels {
        let meta = meta(id, generation);
        ImagePixels {
            rgba: vec![0; meta.rgba_len()],
            meta,
        }
    }

    fn style() -> PaintStyle {
        PaintStyle {
            geometry: crate::layout::CellGeometry {
                metrics: CellMetrics {
                    cell_width: CELL_W,
                    cell_height: CELL_H,
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
            size_px: 20,
            content_origin_y: 0.0,
            selection: SelectionColors {
                background: crate::quad::Rgba::CLEAR,
                foreground: None,
            },
            focused: true,
            blink_visible: true,
            cursor_opacity: 1.0,
            cursor_text: None,
        }
    }

    /// One headerless block over ten rows — the alternate-screen shape, which is the layout that
    /// isolates the image arithmetic from the chrome's.
    fn flat_layout() -> crate::block::BlockLayout {
        let spans = [BlockSpan {
            rows: RowRange { start: 0, end: 10 },
            prompt_rows: 0,
        }];
        lay_out(&spans, &[], Chrome::NONE, CELL_H, Viewport {
            scroll_y: 0.0,
            height: 200.0,
            width: 400.0,
        })
    }

    fn placement(row: i32, col: i32) -> ImagePlacement {
        ImagePlacement {
            image_id: 1,
            placement_id: 0,
            z: 0,
            col,
            row,
            width_px: 100,
            height_px: 100,
            cols: 10,
            rows: 5,
            source_x: 0,
            source_y: 0,
            source_width: 100,
            source_height: 100,
            cell_offset_x: 0,
            cell_offset_y: 0,
        }
    }

    fn store() -> ImageStore {
        let mut store = ImageStore::new();
        store.insert(pixels(1, 7));
        store
    }

    #[test]
    fn the_three_layers_are_the_protocols_own_ranges() {
        assert_eq!(layer_of(0), ImageLayer::AboveText);
        assert_eq!(layer_of(1), ImageLayer::AboveText);
        assert_eq!(layer_of(-1), ImageLayer::BelowText);
        assert_eq!(layer_of(BELOW_BACKGROUND_Z), ImageLayer::BelowText);
        assert_eq!(layer_of(BELOW_BACKGROUND_Z - 1), ImageLayer::BelowBackground);
        assert_eq!(layer_of(i32::MIN), ImageLayer::BelowBackground);
    }

    #[test]
    fn a_placement_lands_on_the_row_the_layout_puts_it_on() {
        let mut placements = vec![placement(2, 3)];
        let mut list = DrawList::new();
        place(
            &mut placements,
            &flat_layout(),
            &style(),
            Rect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            &store(),
            &mut list,
        );

        let instance = list.images.first().copied().unwrap();
        assert!((f64::from(instance.y) - CELL_H * 2.0).abs() < 1e-6);
        assert!((f64::from(instance.x) - CELL_W * 3.0).abs() < 1e-6);
        assert!((f64::from(instance.width) - 100.0).abs() < 1e-6);
        assert!(
            uv_eq(instance.uv, [0.0, 0.0, 1.0, 1.0]),
            "an unclipped image samples all of itself"
        );
        assert_eq!(list.image_runs.len(), 1);
    }

    #[test]
    fn the_cell_offsets_move_the_image_inside_its_anchor_cell() {
        // The protocol's `X=`/`Y=`, and the same two numbers a virtually placed image uses to carry
        // the blank band its aspect fit left over. Sub-cell by construction, which is exactly why
        // ignoring them is invisible in a screenshot and wrong in every one: an image nudged to
        // line up with a box-drawing character beside it lands a few pixels off, and a
        // tiled image lands a fraction of a row off on every tile.
        let mut placements = vec![ImagePlacement {
            cell_offset_x: 4,
            cell_offset_y: 7,
            ..placement(2, 3)
        }];
        let mut list = DrawList::new();
        place(
            &mut placements,
            &flat_layout(),
            &style(),
            Rect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            &store(),
            &mut list,
        );

        let instance = list.images.first().copied().unwrap();
        assert!((f64::from(instance.x) - (CELL_W * 3.0 + 4.0)).abs() < 1e-6);
        assert!((f64::from(instance.y) - (CELL_H * 2.0 + 7.0)).abs() < 1e-6);
        assert!(
            uv_eq(instance.uv, [0.0, 0.0, 1.0, 1.0]),
            "an offset moves the destination and must not crop the source"
        );
    }

    #[test]
    fn an_image_scrolled_above_the_viewport_is_cropped_and_not_squashed() {
        // The case the negative row exists for. Two of the image's five rows are off the top, so
        // two rows' worth of PIXELS come off the source and the rest keeps its scale — the picture
        // does not compress to fit what is left.
        let mut placements = vec![placement(-2, 0)];
        let mut list = DrawList::new();
        place(
            &mut placements,
            &flat_layout(),
            &style(),
            Rect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            &store(),
            &mut list,
        );

        let instance = list.images.first().copied().unwrap();
        assert!(
            f64::from(instance.y).abs() < 1e-6,
            "the visible part starts at the top edge"
        );
        assert!(
            (f64::from(instance.height) - 60.0).abs() < 1e-6,
            "40 device pixels of image were above the viewport"
        );
        assert!(
            (f64::from(instance.uv[1]) - 0.4).abs() < 1e-6,
            "the source has to start 40% down, or the picture is squashed instead of cropped"
        );
        assert!((f64::from(instance.uv[3]) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn a_pane_with_insets_crops_against_the_block_where_the_block_actually_is() {
        // The regression this test exists for: `PlacedBlock::body` is LAYOUT space and the
        // destination is SCREEN space, so clipping one against the other silently crops every image
        // by the insets. Invisible at the origin, which is where every other test in this module
        // sits — so this one moves both origins.
        let mut style = style();
        style.geometry.metrics.origin_x = 5.0;
        style.content_origin_y = 7.0;

        // The last row of a ten-row block: its image runs past the block's bottom, so the crop is
        // what decides the height and a clip in the wrong space answers a different number.
        let mut placements = vec![placement(9, 0)];
        let mut list = DrawList::new();
        place(
            &mut placements,
            &flat_layout(),
            &style,
            Rect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 400.0,
            },
            &store(),
            &mut list,
        );

        let instance = list.images.first().copied().unwrap();
        assert!((f64::from(instance.x) - 5.0).abs() < 1e-6);
        assert!((f64::from(instance.y) - (7.0 + CELL_H * 9.0)).abs() < 1e-6);
        assert!(
            (f64::from(instance.height) - CELL_H).abs() < 1e-6,
            "one row of the block was left, so one row of image should be"
        );
    }

    #[test]
    fn a_placement_with_no_pixels_yet_draws_nothing() {
        let mut placements = vec![placement(0, 0)];
        let mut list = DrawList::new();
        place(
            &mut placements,
            &flat_layout(),
            &style(),
            Rect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            &ImageStore::new(),
            &mut list,
        );
        assert!(list.images.is_empty(), "a chunked transmission drew a hole");
    }

    #[test]
    fn placements_are_emitted_in_layer_order_so_the_runs_are_the_draw_calls() {
        let mut placements = vec![
            ImagePlacement {
                z: 5,
                ..placement(0, 0)
            },
            ImagePlacement {
                z: i32::MIN,
                ..placement(1, 0)
            },
            ImagePlacement {
                z: -1,
                ..placement(2, 0)
            },
        ];
        let mut list = DrawList::new();
        place(
            &mut placements,
            &flat_layout(),
            &style(),
            Rect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            &store(),
            &mut list,
        );

        let layers: Vec<ImageLayer> = list.image_runs.iter().map(|run| run.layer).collect();
        assert_eq!(layers, vec![
            ImageLayer::BelowBackground,
            ImageLayer::BelowText,
            ImageLayer::AboveText
        ]);
        let total: u32 = list.image_runs.iter().map(|run| run.count).sum();
        assert_eq!(total as usize, list.images.len(), "a run lost an instance");
        assert_eq!(list.image_runs.first().unwrap().first, 0);
    }

    #[test]
    fn clipping_to_nothing_answers_nothing_and_a_nan_does_too() {
        let placed = Placed {
            dest: Rect {
                x: 0.0,
                y: 0.0,
                width: 10.0,
                height: 10.0,
            },
            source: Rect {
                x: 0.0,
                y: 0.0,
                width: 10.0,
                height: 10.0,
            },
        };
        assert!(
            clip(placed, Rect {
                x: 100.0,
                y: 100.0,
                width: 10.0,
                height: 10.0
            })
            .is_none()
        );
        assert!(
            clip(placed, Rect {
                x: f64::NAN,
                y: 0.0,
                width: 10.0,
                height: 10.0
            })
            .is_none(),
            "`f64::max` SWALLOWS a NaN and answers the other operand, so without the explicit finiteness \
             check the intersection would silently draw at full size"
        );
    }

    #[test]
    fn a_zero_sized_image_normalises_to_the_whole_texture_rather_than_a_nan() {
        let empty = ImageMeta {
            id: 1,
            generation: 1,
            width: 0,
            height: 0,
        };
        assert!(uv_eq(
            normalise(
                Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 4.0,
                    height: 4.0
                },
                empty
            ),
            [0.0, 0.0, 1.0, 1.0]
        ));
    }

    #[test]
    fn the_store_goes_stale_on_the_generation_and_not_on_the_size() {
        // The whole reason the engine stamps a generation at all: a chart redrawn in place is the
        // same id at the same size with different pixels, and every other key calls that fresh.
        let mut store = ImageStore::new();
        assert!(store.is_stale(meta(1, 7)), "an image nobody holds is stale");

        store.insert(pixels(1, 7));
        assert!(!store.is_stale(meta(1, 7)));
        assert!(store.is_stale(meta(1, 8)));
        assert!(store.get(1).unwrap().revision > 0);
    }

    #[test]
    fn retaining_drops_what_the_frame_did_not_place() {
        let mut store = ImageStore::new();
        store.insert(pixels(1, 1));
        store.insert(pixels(2, 1));
        store.retain(&[2]);

        assert_eq!(store.len(), 1);
        assert!(store.get(1).is_none());
        assert!(store.get(2).is_some());

        store.retain(&[]);
        assert!(store.is_empty());
    }
}
