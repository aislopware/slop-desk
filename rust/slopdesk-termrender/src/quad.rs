//! What the GPU is handed: a handful of instance arrays and nothing else.
//!
//! ## The buffers, and the order is the whole design
//!
//! [`DrawList`] keeps backgrounds, glyphs and overlays apart because they must be drawn in that
//! order and because each wants a different pipeline. What makes the split load-bearing rather than
//! tidy is the **block cursor**: a filled block sits UNDER its glyph and inverts it, so it is a
//! background; a bar or an underline sits OVER the glyph, so it is an overlay. One buffer would
//! force a sort per frame to express a rule that is already known at build time.
//!
//! Images are the fourth buffer and the one that breaks the pattern, because a kitty placement
//! carries a Z INDEX and the protocol gives that index three meanings: below the cell background,
//! between the background and the text, or over the text. So the image instances are ONE array
//! visited THREE times — the run list says which layer each stretch belongs to, and
//! `slopdesk-apple-metal` draws each layer at its own point in the pass. Three separate arrays
//! would have been the obvious spelling and the wrong one: it is the same pipeline and the same
//! textures every time, and a program that puts one image behind text and another in front would
//! then need its instances split across two allocations to say so.
//!
//! The pinned trio is the same three kinds again, drawn after all of the above. It exists because
//! this renderer has no scissor rect: [`crate::pin`]'s band cannot be clipped, so being LAST is the
//! whole of how it stays on top of rows it overlaps. Three more arrays rather than a z field on
//! every instance, for the reason the first three are separate — the order is known when the
//! instance is built, and a sort per frame would be paying to rediscover it.
//!
//! ## Why `#[repr(C)]` in a crate that forbids `unsafe`
//!
//! These structs are copied into a `MTLBuffer` and read by a vertex shader whose `struct` must
//! match them field for field. `repr(C)` is what makes that match a fact rather than a hope — it
//! costs nothing here and it is the reason `slopdesk-apple-metal` can memcpy a slice instead of
//! marshalling. The `unsafe` that does the copy lives there, inside the `apple-*` family, exactly
//! where `CLAUDE.md` puts it.
//!
//! ## Pixels, and which ones
//!
//! Every coordinate in this module is a DEVICE pixel with a top-left origin — points multiplied by
//! the contents scale, already. Points stop at [`crate::layout`]. A shader that had to apply a
//! scale would be a second place the scale could be wrong.

use slopdesk_vterm::Rgb;

/// A colour with an alpha, as an instance carries one.
///
/// Four bytes rather than four floats: this is `uchar4` in the shader, normalised by the hardware
/// for free, and a full 200×50 repaint is 10 000 instances where 12 saved bytes each is real.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(C)]
pub struct Rgba {
    /// Red.
    pub r: u8,
    /// Green.
    pub g: u8,
    /// Blue.
    pub b: u8,
    /// Alpha. `255` is opaque.
    pub a: u8,
}

impl Rgba {
    /// Fully transparent.
    pub const CLEAR: Self = Self {
        r: 0,
        g: 0,
        b: 0,
        a: 0,
    };

    /// An opaque colour.
    #[must_use]
    pub const fn opaque(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    /// This colour at `alpha`.
    #[must_use]
    pub const fn with_alpha(self, alpha: u8) -> Self {
        Self { a: alpha, ..self }
    }

    /// Whether the colour would draw nothing.
    #[must_use]
    pub const fn is_invisible(self) -> bool {
        self.a == 0
    }
}

impl From<Rgb> for Rgba {
    fn from(value: Rgb) -> Self {
        Self::opaque(value.r, value.g, value.b)
    }
}

/// Which pipeline draws a rect.
///
/// A curly underline is not a rectangle and never will be — it is a sine wave the fragment shader
/// evaluates inside the rect's bounds. Dotted and dashed are the same trick with a cheaper
/// function. Carrying the shape here rather than emitting geometry for it keeps a wavy underline at
/// one instance instead of thirty, and keeps this crate free of a curve tessellator it would then
/// have to test.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u32)]
pub enum RectStyle {
    /// Fill the whole rect.
    #[default]
    Solid = 0,
    /// A dotted line along the rect, phase-locked to the rect's own left edge so adjacent cells
    /// continue one pattern rather than restarting it.
    Dotted = 1,
    /// A dashed line, same phase rule.
    Dashed = 2,
    /// A sine wave fitted to the rect's height.
    Curly = 3,
    /// A one-pixel outline rather than a fill — the unfocused cursor.
    Hollow = 4,
}

/// One solid-ish rectangle: a cell background, a decoration, a cursor.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
#[repr(C)]
pub struct RectInstance {
    /// Left edge in device pixels.
    pub x: f32,
    /// Top edge in device pixels.
    pub y: f32,
    /// Width in device pixels.
    pub width: f32,
    /// Height in device pixels.
    pub height: f32,
    /// The fill.
    pub color: Rgba,
    /// Which pipeline draws it.
    pub style: RectStyle,
}

/// One glyph, placed and tinted.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
#[repr(C)]
pub struct GlyphInstance {
    /// Left edge of the glyph's bitmap in device pixels.
    pub x: f32,
    /// Top edge of the glyph's bitmap in device pixels.
    pub y: f32,
    /// Bitmap width in device pixels.
    pub width: f32,
    /// Bitmap height in device pixels.
    pub height: f32,
    /// `[u0, v0, u1, v1]` into whichever atlas [`GlyphInstance::color_atlas`] names.
    pub uv: [f32; 4],
    /// The tint. Ignored by the fragment shader for a colour glyph, which carries its own.
    pub color: Rgba,
    /// Whether the texels come from the colour atlas rather than the coverage one.
    ///
    /// A `u32` and not a `bool`: this is read by a shader, and a one-byte field would put padding
    /// into a struct whose layout has to be predictable from the Metal side.
    pub color_atlas: u32,
}

impl GlyphInstance {
    /// Whether this instance samples the colour atlas.
    #[must_use]
    pub const fn is_color_atlas(self) -> bool {
        self.color_atlas != 0
    }
}

/// Where an image sits in the painter's order, which the kitty protocol calls its z index.
///
/// The three bands are the protocol's own, not a rendering convenience: a program says "behind
/// everything", "behind the text but over the cell colour" or "in front" by choosing a number, and
/// these are the three ranges those numbers fall into. Carried as an enum because the RANGES are
/// the engine's to classify and the ORDER is this crate's to honour, and a raw `i32` on the
/// instance would put the classification in whichever module happened to read it next.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub enum ImageLayer {
    /// Under the cell backgrounds — a wallpaper the terminal's own colours paint over.
    BelowBackground = 0,
    /// Over the cell backgrounds, under the text. The commonest case a program that draws behind
    /// its own output asks for.
    BelowText = 1,
    /// Over everything the terminal drew. The protocol's default, and what `z=0` means.
    #[default]
    AboveText = 2,
}

/// One stretch of [`DrawList::images`] that shares a texture and a layer.
///
/// A run rather than a per-instance texture id, because binding a texture is an ENCODER action and
/// an instance field could not express one: the GPU reads one texture per draw call, so the runs
/// are exactly the draw calls. `first` is carried rather than accumulated so the renderer's loop
/// has nothing to get wrong when it skips the runs of the two layers it is not drawing yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageRun {
    /// Which image's texture the run samples.
    pub image: u32,
    /// When in the pass the run is drawn.
    pub layer: ImageLayer,
    /// Index of the run's first instance in [`DrawList::images`].
    pub first: u32,
    /// How many instances the run holds.
    pub count: u32,
}

/// One image placement, or one visible piece of one.
///
/// No colour and no tint: an image carries its own pixels, and a terminal that recoloured one would
/// be answering a question the protocol never asked. What it does carry is a source rectangle in
/// NORMALISED texture coordinates, because clipping a placement against the viewport and against
/// its own block is done on this side — see [`crate::image`] — and the result is a sub-rectangle of
/// the texture that the vertex stage interpolates exactly as the glyph pass does.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
#[repr(C)]
pub struct ImageInstance {
    /// Left edge in device pixels.
    pub x: f32,
    /// Top edge in device pixels.
    pub y: f32,
    /// Width in device pixels.
    pub width: f32,
    /// Height in device pixels.
    pub height: f32,
    /// `[u0, v0, u1, v1]` into the run's texture.
    pub uv: [f32; 4],
}

/// Everything one frame draws, in draw order.
///
/// Reused across frames: [`DrawList::clear`] keeps every allocation, so the steady state of a
/// repaint is writing over memory that is already warm. That matters more than it looks — the
/// buffers are the size of the viewport, and a fresh `Vec` per frame would put a 200 KiB allocation
/// on the path `docs/68` §6.3 measures.
#[derive(Debug, Clone, Default)]
pub struct DrawList {
    /// Kitty image placements, sorted so every run of one layer is contiguous. Which of them is
    /// drawn WHEN is [`Self::image_runs`]'s answer, not this vector's order alone.
    pub images: Vec<ImageInstance>,
    /// The draw calls [`Self::images`] is cut into, in ascending layer order.
    pub image_runs: Vec<ImageRun>,
    /// Cell backgrounds, the selection fill, and a filled block cursor. Drawn after
    /// [`ImageLayer::BelowBackground`].
    pub backgrounds: Vec<RectInstance>,
    /// Text. Drawn over the backgrounds and over [`ImageLayer::BelowText`].
    pub glyphs: Vec<GlyphInstance>,
    /// Underlines, strikethroughs, overlines, and any cursor that is not a filled block. Drawn
    /// last, because a strikethrough that the glyph painted over is not a strikethrough.
    pub overlays: Vec<RectInstance>,
    /// Backgrounds that draw over everything above — the pinned head's bed.
    pub pinned_backgrounds: Vec<RectInstance>,
    /// Text drawn over [`Self::pinned_backgrounds`], and over every unpinned instance.
    pub pinned_glyphs: Vec<GlyphInstance>,
    /// The pinned pass's own decorations, last of all.
    pub pinned_overlays: Vec<RectInstance>,
}

/// Where a [`DrawList`] stood before a pass appended to it.
///
/// Opaque on purpose — the only thing a caller may do with one is hand it back to
/// [`DrawList::lift_pinned`], which is what keeps "everything since here" from becoming three
/// indices a caller could get individually wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mark {
    backgrounds: usize,
    glyphs: usize,
    overlays: usize,
}

impl DrawList {
    /// An empty list.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Empties every buffer, keeping their allocations.
    pub fn clear(&mut self) {
        self.images.clear();
        self.image_runs.clear();
        self.backgrounds.clear();
        self.glyphs.clear();
        self.overlays.clear();
        self.pinned_backgrounds.clear();
        self.pinned_glyphs.clear();
        self.pinned_overlays.clear();
    }

    /// Whether the list would draw nothing.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.backgrounds.is_empty()
            && self.glyphs.is_empty()
            && self.overlays.is_empty()
            && self.images.is_empty()
            && self.pinned_backgrounds.is_empty()
            && self.pinned_glyphs.is_empty()
            && self.pinned_overlays.is_empty()
    }

    /// How many instances the list holds, across every buffer.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.backgrounds.len()
            + self.glyphs.len()
            + self.overlays.len()
            + self.images.len()
            + self.pinned_backgrounds.len()
            + self.pinned_glyphs.len()
            + self.pinned_overlays.len()
    }

    /// Where the list stands right now, so a pass can lift what it is about to append.
    #[must_use]
    pub const fn mark(&self) -> Mark {
        Mark {
            backgrounds: self.backgrounds.len(),
            glyphs: self.glyphs.len(),
            overlays: self.overlays.len(),
        }
    }

    /// Moves everything appended since `mark` into the pinned buffers.
    ///
    /// ## Why lifting, rather than a second set of `push_*` doors
    ///
    /// The pinned pass draws a terminal ROW — the same cells, the same runs, the same selection and
    /// the same coalescing as the row beside it — so it runs [`crate::paint::Painter`]'s own row
    /// painter and can only be right by construction if that painter is the SAME code. A pinned
    /// variant of every push would make it a copy, and the day the two copies disagree is the day a
    /// user's sticky head renders with last month's underline rule.
    ///
    /// Images are not lifted, and there is nothing to lift: the pinned pass emits no placement, and
    /// [`crate::image`] places from the block layout after every text pass has run. A kitty image
    /// on a prompt row therefore scrolls away with its row rather than riding the head, which is
    /// the honest answer — the head is a label, and a label that redrew an image would have to
    /// clip it against a band it has no scissor for.
    pub fn lift_pinned(&mut self, mark: Mark) {
        self.pinned_backgrounds.extend(
            self.backgrounds
                .drain(mark.backgrounds.min(self.backgrounds.len())..),
        );
        self.pinned_glyphs
            .extend(self.glyphs.drain(mark.glyphs.min(self.glyphs.len())..));
        self.pinned_overlays
            .extend(self.overlays.drain(mark.overlays.min(self.overlays.len())..));
    }

    /// Appends an image instance to the run `image` and `layer` name, opening one if needed.
    ///
    /// Extending the LAST run rather than searching for a matching one is deliberate and is what
    /// makes the run list correct: runs are draw calls in order, so merging into an earlier run
    /// would move an instance backwards past everything emitted since — which for images is exactly
    /// the z ordering the layer exists to preserve. `crate::image` sorts before it pushes, so
    /// adjacency is where the merging opportunity actually is.
    pub fn push_image(&mut self, image: u32, layer: ImageLayer, instance: ImageInstance) {
        if instance.width <= 0.0 || instance.height <= 0.0 {
            return;
        }
        match self.image_runs.last_mut() {
            Some(run) if run.image == image && run.layer == layer => run.count += 1,
            _ => {
                // A `u32` because that is what a base-instance argument is; a list longer than four
                // billion image quads is not a frame anyone renders, and saturating keeps the
                // arithmetic total rather than making the render path the thing that panics.
                let first = u32::try_from(self.images.len()).unwrap_or(u32::MAX);
                self.image_runs.push(ImageRun {
                    image,
                    layer,
                    first,
                    count: 1,
                });
            },
        }
        self.images.push(instance);
    }

    /// Appends a background rect, dropping one that would draw nothing.
    ///
    /// The drop is not a micro-optimisation. A terminal's commonest cell is a space on the default
    /// background, and emitting a rect for each would double the instance count of an ordinary
    /// frame to paint the colour the render pass already cleared to.
    pub fn push_background(&mut self, rect: RectInstance) {
        if rect.color.is_invisible() || rect.width <= 0.0 || rect.height <= 0.0 {
            return;
        }
        self.backgrounds.push(rect);
    }

    /// Appends an overlay rect, dropping one that would draw nothing.
    pub fn push_overlay(&mut self, rect: RectInstance) {
        if rect.color.is_invisible() || rect.width <= 0.0 || rect.height <= 0.0 {
            return;
        }
        self.overlays.push(rect);
    }

    /// Appends a glyph, dropping one that would draw nothing.
    pub fn push_glyph(&mut self, glyph: GlyphInstance) {
        if glyph.width <= 0.0 || glyph.height <= 0.0 {
            return;
        }
        if glyph.color.is_invisible() && !glyph.is_color_atlas() {
            return;
        }
        self.glyphs.push(glyph);
    }
}

/// Narrows a layout coordinate to what a vertex buffer holds.
///
/// Layout is `f64` because `slopdesk_terminal::geometry` is, and that module's bit-exactness
/// discipline is the reason. Instances are `f32` because that is what the hardware reads. The
/// narrowing happens here, once, so there is one place to look when a coordinate is a pixel off.
#[expect(
    clippy::cast_possible_truncation,
    reason = "a device-pixel coordinate is bounded by the drawable; f32 carries it exactly"
)]
#[must_use]
pub const fn px(value: f64) -> f32 {
    value as f32
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_vterm::Rgb;

    use super::{DrawList, GlyphInstance, ImageInstance, ImageLayer, RectInstance, RectStyle, Rgba, px};

    fn rect(color: Rgba) -> RectInstance {
        RectInstance {
            x: 0.0,
            y: 0.0,
            width: 10.0,
            height: 10.0,
            color,
            style: RectStyle::Solid,
        }
    }

    #[test]
    fn an_invisible_rect_never_reaches_a_buffer() {
        let mut list = DrawList::new();
        list.push_background(rect(Rgba::CLEAR));
        list.push_overlay(rect(Rgba::CLEAR));
        assert!(list.is_empty());

        list.push_background(rect(Rgba::opaque(1, 2, 3)));
        assert_eq!(list.backgrounds.len(), 1);
    }

    #[test]
    fn a_zero_area_rect_never_reaches_a_buffer() {
        let mut list = DrawList::new();
        list.push_background(RectInstance {
            width: 0.0,
            ..rect(Rgba::opaque(1, 2, 3))
        });
        list.push_overlay(RectInstance {
            height: -1.0,
            ..rect(Rgba::opaque(1, 2, 3))
        });
        assert!(list.is_empty());
    }

    #[test]
    fn a_colour_glyph_survives_an_invisible_tint() {
        let mut list = DrawList::new();
        let emoji = GlyphInstance {
            width: 8.0,
            height: 8.0,
            color: Rgba::CLEAR,
            color_atlas: 1,
            ..GlyphInstance::default()
        };
        list.push_glyph(emoji);
        assert_eq!(
            list.glyphs.len(),
            1,
            "an emoji carries its own colour and ignores the tint"
        );

        list.clear();
        list.push_glyph(GlyphInstance {
            color_atlas: 0,
            ..emoji
        });
        assert!(
            list.glyphs.is_empty(),
            "a coverage glyph tinted clear draws nothing"
        );
    }

    #[test]
    fn clearing_keeps_the_allocations() {
        let mut list = DrawList::new();
        for _ in 0..64 {
            list.push_background(rect(Rgba::opaque(9, 9, 9)));
        }
        let capacity = list.backgrounds.capacity();
        list.clear();

        assert_eq!(list.len(), 0);
        assert_eq!(list.backgrounds.capacity(), capacity);
    }

    #[test]
    fn an_rgb_from_the_frame_arrives_opaque() {
        assert_eq!(Rgba::from(Rgb::new(1, 2, 3)), Rgba::opaque(1, 2, 3));
        assert!(Rgba::opaque(1, 2, 3).with_alpha(0).is_invisible());
    }

    #[test]
    fn narrowing_keeps_a_device_pixel_exact() {
        assert!((px(1234.5) - 1234.5_f32).abs() < f32::EPSILON);
    }

    fn image() -> ImageInstance {
        ImageInstance {
            x: 0.0,
            y: 0.0,
            width: 10.0,
            height: 10.0,
            uv: [0.0, 0.0, 1.0, 1.0],
        }
    }

    #[test]
    fn adjacent_placements_of_one_image_on_one_layer_are_one_draw_call() {
        let mut list = DrawList::new();
        list.push_image(1, ImageLayer::AboveText, image());
        list.push_image(1, ImageLayer::AboveText, image());

        assert_eq!(list.images.len(), 2);
        assert_eq!(
            list.image_runs.len(),
            1,
            "two placements of one image bound its texture twice"
        );
        assert_eq!(list.image_runs.first().map(|run| run.count), Some(2));
    }

    #[test]
    fn a_new_image_or_a_new_layer_opens_a_new_run() {
        let mut list = DrawList::new();
        list.push_image(1, ImageLayer::BelowText, image());
        list.push_image(2, ImageLayer::BelowText, image());
        list.push_image(2, ImageLayer::AboveText, image());
        // Back to the FIRST image and layer, but not adjacent to it: merging here would reorder the
        // draw and put an image on the wrong side of the text.
        list.push_image(1, ImageLayer::BelowText, image());

        let runs: Vec<(u32, ImageLayer, u32, u32)> = list
            .image_runs
            .iter()
            .map(|run| (run.image, run.layer, run.first, run.count))
            .collect();
        assert_eq!(runs, vec![
            (1, ImageLayer::BelowText, 0, 1),
            (2, ImageLayer::BelowText, 1, 1),
            (2, ImageLayer::AboveText, 2, 1),
            (1, ImageLayer::BelowText, 3, 1),
        ]);
    }

    #[test]
    fn a_zero_area_image_never_reaches_a_buffer() {
        let mut list = DrawList::new();
        list.push_image(1, ImageLayer::AboveText, ImageInstance {
            width: 0.0,
            ..image()
        });
        list.push_image(1, ImageLayer::AboveText, ImageInstance {
            height: -1.0,
            ..image()
        });

        assert!(list.is_empty());
        assert!(
            list.image_runs.is_empty(),
            "an empty run would still bind a texture"
        );
    }

    /// A lift takes everything since the mark and nothing before it.
    #[test]
    fn a_lift_moves_only_what_came_after_the_mark() {
        let mut list = DrawList::new();
        list.push_background(rect(Rgba::opaque(1, 1, 1)));
        list.push_overlay(rect(Rgba::opaque(2, 2, 2)));

        let mark = list.mark();
        list.push_background(rect(Rgba::opaque(3, 3, 3)));
        list.push_overlay(rect(Rgba::opaque(4, 4, 4)));
        list.lift_pinned(mark);

        assert_eq!(list.backgrounds.len(), 1);
        assert_eq!(list.backgrounds[0].color, Rgba::opaque(1, 1, 1));
        assert_eq!(list.overlays.len(), 1);
        assert_eq!(list.overlays[0].color, Rgba::opaque(2, 2, 2));
        assert_eq!(list.pinned_backgrounds.len(), 1);
        assert_eq!(list.pinned_backgrounds[0].color, Rgba::opaque(3, 3, 3));
        assert_eq!(list.pinned_overlays.len(), 1);
        assert_eq!(list.pinned_overlays[0].color, Rgba::opaque(4, 4, 4));
        assert_eq!(list.len(), 4, "a lift moves instances, it does not drop them");
    }

    /// ⚠️ A lift over a mark taken before a `clear` must not panic.
    ///
    /// The pinned pass takes its mark and lifts within one call, so this cannot happen today — but
    /// the mark is three plain indices and the drain that reads them is the one place a stale one
    /// would become a slice out of range rather than a wrong picture.
    #[test]
    fn a_stale_mark_lifts_nothing_rather_than_panicking() {
        let mut list = DrawList::new();
        list.push_background(rect(Rgba::opaque(1, 1, 1)));
        list.push_glyph(GlyphInstance {
            width: 4.0,
            height: 4.0,
            color: Rgba::opaque(9, 9, 9),
            ..GlyphInstance::default()
        });
        let mark = list.mark();
        list.clear();
        list.lift_pinned(mark);

        assert!(list.is_empty());
    }

    /// Clearing empties the pinned buffers too — a head left behind would draw over a new frame.
    #[test]
    fn a_clear_takes_the_pinned_buffers_with_it() {
        let mut list = DrawList::new();
        let mark = list.mark();
        list.push_background(rect(Rgba::opaque(1, 1, 1)));
        list.lift_pinned(mark);
        assert!(!list.is_empty());

        list.clear();
        assert!(list.is_empty());
        assert_eq!(list.len(), 0);
    }
}
