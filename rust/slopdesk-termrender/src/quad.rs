//! What the GPU is handed: two instance arrays and nothing else.
//!
//! ## Three buffers, and the order is the whole design
//!
//! [`DrawList`] keeps backgrounds, glyphs and overlays apart because they must be drawn in that
//! order and because each wants a different pipeline. What makes the split load-bearing rather than
//! tidy is the **block cursor**: a filled block sits UNDER its glyph and inverts it, so it is a
//! background; a bar or an underline sits OVER the glyph, so it is an overlay. One buffer would
//! force a sort per frame to express a rule that is already known at build time.
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

/// Everything one frame draws, in draw order.
///
/// Reused across frames: [`DrawList::clear`] keeps all three allocations, so the steady state of a
/// repaint is writing over memory that is already warm. That matters more than it looks — the
/// buffers are the size of the viewport, and a fresh `Vec` per frame would put a 200 KiB allocation
/// on the path `docs/68` §6.3 measures.
#[derive(Debug, Clone, Default)]
pub struct DrawList {
    /// Cell backgrounds, the selection fill, and a filled block cursor. Drawn first.
    pub backgrounds: Vec<RectInstance>,
    /// Text. Drawn over the backgrounds.
    pub glyphs: Vec<GlyphInstance>,
    /// Underlines, strikethroughs, overlines, and any cursor that is not a filled block. Drawn
    /// last, because a strikethrough that the glyph painted over is not a strikethrough.
    pub overlays: Vec<RectInstance>,
}

impl DrawList {
    /// An empty list.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Empties all three buffers, keeping their allocations.
    pub fn clear(&mut self) {
        self.backgrounds.clear();
        self.glyphs.clear();
        self.overlays.clear();
    }

    /// Whether the list would draw nothing.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.backgrounds.is_empty() && self.glyphs.is_empty() && self.overlays.is_empty()
    }

    /// How many instances the list holds, across all three buffers.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.backgrounds.len() + self.glyphs.len() + self.overlays.len()
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
    use slopdesk_vterm::Rgb;

    use super::{DrawList, GlyphInstance, RectInstance, RectStyle, Rgba, px};

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
}
