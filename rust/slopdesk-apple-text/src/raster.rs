//! A glyph id into a bitmap.
//!
//! ## Where the pixels live, and why that decides the whole module
//!
//! The obvious way to rasterise through Core Graphics is to pass NULL for the bitmap's data, let it
//! allocate, and read the result back through `CGBitmapContextGetData`. That answers a
//! `*mut c_void`, and turning one into bytes needs `slice::from_raw_parts` — which `docs/57` §2
//! bars from this family by name, with only `slopdesk-apple-audio` and `slopdesk-apple-vt` exempt.
//!
//! So the buffer is ours. [`Rasterizer`] keeps a `Vec<u8>`, sizes it to the glyph, and hands Core
//! Graphics a pointer INTO it. Core Graphics draws through a slot the caller allocated and never
//! frees it, which is the shape §2 blesses through `AXValueGetValue` and
//! `CMBlockBufferCopyDataBytes`, and reading the result back is an ordinary slice read that needs
//! no exemption at all. The scratch buffer is reused across glyphs, so the allocation the NULL-data
//! form would have made per call does not happen either.
//!
//! ## Bearings, in the renderer's convention rather than a new one
//!
//! `paint.rs` places a glyph at `origin_x + shaped.x + bearing_x` and
//! `baseline + shaped.y - bearing_y`, with the quad drawn downwards from there. So `bearing_x` runs
//! RIGHT from the glyph's origin to the bitmap's left edge and `bearing_y` runs UP from the
//! baseline to its top edge — the `FreeType` convention, and the renderer is written, so this
//! matches it. Core Text's `CTFontGetBoundingRectsForGlyphs` answers a rect in font space with a
//! y-up origin at the glyph's origin, which makes the conversion the two lines it looks like: the
//! left edge is the rect's `origin.x` and the top edge is `origin.y + height`, both taken outward
//! to an integer so the bitmap contains the ink rather than clipping it.
//!
//! ## Coverage, not subpixel antialiasing
//!
//! Font smoothing is turned OFF. LCD antialiasing puts coverage in three channels, and an `Alpha8`
//! atlas has one; a colour atlas has four but would blend them as colour rather than as coverage.
//! Grayscale coverage in the alpha channel is what the atlas's format means, and the way to get it
//! from Core Graphics is an `kCGImageAlphaOnly` context with a NULL colour space, drawn with a
//! fully opaque fill.

use core::ptr;
use core::ptr::NonNull;

use objc2_core_foundation::{CFRetained, CGAffineTransform, CGPoint};
use objc2_core_graphics::{
    CGBitmapContextCreate, CGColorSpace, CGContext, CGGlyph, CGImageAlphaInfo, CGImageByteOrderInfo,
    CGTextDrawingMode,
};
use objc2_core_text::{CTFont, CTFontOrientation};
use slopdesk_termrender::atlas::AtlasFormat;
use slopdesk_termrender::glyph::{GlyphKey, GlyphRasterizer, RasterGlyph, SUBPIXEL_PHASES};

use crate::font::{Faces, MAX_GLYPH_EDGE, finite, narrow};

/// How far a fake italic leans, as a horizontal shift per unit of height.
///
/// 0.21 is `tan(12°)`, which is where the real italic cuts of the monospace faces this ships with
/// sit. A synthesised italic that leans further than the family's own would look like a different
/// decision rather than like a missing cut.
const ITALIC_SHEAR: f64 = 0.21;

/// How heavy a fake bold is, as a stroke width per point of size.
///
/// A stroke thickens a glyph on BOTH sides of its outline, so half of this lands outside the
/// original ink — which is why the bounding box below is padded by the whole stroke rather than by
/// half of it.
const BOLD_STROKE: f64 = 0.028;

/// Draws one glyph at a time into a buffer it owns.
#[derive(Debug)]
pub struct Rasterizer {
    faces: Faces,
    size_px: u16,
    scratch: Vec<u8>,
}

impl Rasterizer {
    /// Built by [`FontStack::rasterizer`], which is what owns the chain this one reads.
    ///
    /// [`FontStack::rasterizer`]: crate::FontStack::rasterizer
    pub(crate) const fn new(faces: Faces, size_px: u16) -> Self {
        Self {
            faces,
            size_px,
            scratch: Vec::new(),
        }
    }

    /// The face a key names, cloned out so the chain is not borrowed across a framework call.
    ///
    /// Cloning a `CFRetained` is a retain, which is cheaper than holding a `RefCell` borrow open
    /// while Core Text runs — and the shaper may want to append a face at any point, since both
    /// halves are driven from the same paint pass.
    fn face(&self, key: GlyphKey) -> Option<(CFRetained<CTFont>, bool)> {
        let faces = self.faces.borrow();
        let face = faces.get(usize::from(key.font))?;
        Some((face.font.clone(), face.color))
    }
}

/// Where a glyph's ink is, in device pixels around its own origin.
///
/// Split out because it is the arithmetic worth reading on its own: everything else in
/// [`GlyphRasterizer::rasterize`] is Core Graphics configuration.
#[derive(Debug, Clone, Copy)]
struct Box2D {
    left: f64,
    bottom: f64,
    right: f64,
    top: f64,
}

impl Box2D {
    /// The integer box that contains a glyph's ink once it has been sheared, stroked, and nudged by
    /// its subpixel phase.
    ///
    /// `None` for a glyph with no ink and for one whose face reports a box that is not a number —
    /// the caller turns both into a blank, because "exists and draws nothing" is a real answer a
    /// space needs and `None` from `rasterize` would mean "no such glyph".
    fn around(ink: (f64, f64, f64, f64), pad: f64, shear: f64, phase: f64) -> Option<Self> {
        let (x, y, width, height) = ink;
        if !(x.is_finite() && y.is_finite() && width.is_finite() && height.is_finite()) {
            return None;
        }
        if width <= 0.0 || height <= 0.0 {
            return None;
        }
        let bottom = y - pad;
        let top = y + height + pad;
        // A shear moves ink at height `h` right by `shear * h`, so it widens the box on the right
        // by whatever the box reaches ABOVE the baseline and on the left by whatever it
        // reaches below. Both are the identity when the shear is zero, which is the common
        // case.
        Some(Self {
            left: (x - pad + shear * f64::min(bottom, 0.0)).floor(),
            bottom: bottom.floor(),
            right: (x + width + pad + phase + shear * f64::max(top, 0.0)).ceil(),
            top: top.ceil(),
        })
    }

    /// The box's width and height as texel counts, refused when either is absurd.
    fn extent(self) -> Option<(u32, u32)> {
        let width = edge(self.right - self.left)?;
        let height = edge(self.top - self.bottom)?;
        Some((width, height))
    }
}

impl GlyphRasterizer for Rasterizer {
    fn rasterize(&mut self, key: GlyphKey) -> Option<RasterGlyph> {
        // The shaper stamps its stack's own size on every key it emits, so the only way to reach
        // this is to pair a shaper and a rasteriser built from two different stacks. Declining is
        // the honest answer: drawing at the wrong size would look like a font bug rather than like
        // a wiring one.
        if key.size_px != self.size_px {
            return None;
        }
        let (font, color) = self.face(key)?;
        let mut glyphs = [CGGlyph::try_from(key.glyph).ok()?];

        let size = f64::from(key.size_px);
        let shear = if key.synthetic.italic { ITALIC_SHEAR } else { 0.0 };
        let stroke = if key.synthetic.bold {
            size * BOLD_STROKE
        } else {
            0.0
        };
        // The four phases are a fraction of a pixel of extra offset, applied as a translation
        // before the glyph is drawn. Quantisation inside Core Graphics is turned off below
        // so it cannot round the offset away again.
        let phase = f64::from(key.subpixel) / f64::from(SUBPIXEL_PHASES);

        // SAFETY: framework rule. `CTFontGetBoundingRectsForGlyphs` is GET-rule — it owns nothing
        // and answers a rect by value. The glyph array is this function's own one-element slot and
        // the count passed is 1; the out-parameter for the per-glyph rects is null, which the
        // header documents as allowed when only the union is wanted, and the union of one
        // rect is it.
        #[expect(unsafe_code, reason = "a Get-rule call over a one-element slot this fn owns")]
        let ink = unsafe {
            font.bounding_rects_for_glyphs(
                CTFontOrientation::Horizontal,
                NonNull::from(&mut glyphs).cast(),
                ptr::null_mut(),
                1,
            )
        };

        // One device pixel of margin for the antialiaser, plus the whole stroke of a fake bold,
        // which lands half outside the original outline on every side.
        let pad = 1.0 + stroke;
        let ink = (ink.origin.x, ink.origin.y, ink.size.width, ink.size.height);
        let Some(bounds) = Box2D::around(ink, pad, shear, phase) else {
            return Some(RasterGlyph::blank());
        };
        let Some((width, height)) = bounds.extent() else {
            return Some(RasterGlyph::blank());
        };

        let format = if color {
            AtlasFormat::Bgra8
        } else {
            AtlasFormat::Alpha8
        };
        let bytes_per_texel = if color { 4_usize } else { 1 };
        let columns = usize::try_from(width).ok()?;
        let rows = usize::try_from(height).ok()?;
        let stride = columns.checked_mul(bytes_per_texel)?;
        let len = stride.checked_mul(rows)?;

        self.scratch.clear();
        self.scratch.resize(len, 0);
        self.draw(&font, &mut glyphs, key, DrawInto {
            bounds,
            columns,
            rows,
            stride,
            phase,
            shear,
            stroke,
            color,
        })?;

        // No row flip, and that is worth saying out loud because the obvious reading says
        // otherwise. Core Graphics' DRAWING origin is bottom-left — the translate above
        // depends on it — but its bitmap MEMORY is top-row-first, the same layout
        // `CGBitmapContextCreateImage` would hand back and the same one the atlas wants.
        // The two conventions cancel. Flipping to "fix" the origin is the bug this comment
        // exists to stop: it delivers every glyph in the grid upside down, which reads as a
        // font problem and is not one. `the_first_row_is_the_top_of_the_glyph` is the test
        // that catches it.
        let pixels = self.scratch.get(..len)?.to_vec();

        Some(RasterGlyph {
            width,
            height,
            bearing_x: narrow(bounds.left),
            bearing_y: narrow(bounds.top),
            format,
            pixels,
        })
    }
}

/// Everything the draw call needs that is not the font or the glyph.
///
/// One struct rather than nine arguments, because every field is derived from the key and the box
/// and losing track of which is which is exactly how a glyph ends up half a pixel out.
#[derive(Debug, Clone, Copy)]
struct DrawInto {
    bounds: Box2D,
    columns: usize,
    rows: usize,
    stride: usize,
    phase: f64,
    shear: f64,
    stroke: f64,
    color: bool,
}

impl Rasterizer {
    /// Draws one glyph into [`Rasterizer::scratch`], which the caller has already sized.
    fn draw(
        &mut self,
        font: &CTFont,
        glyphs: &mut [CGGlyph; 1],
        key: GlyphKey,
        plan: DrawInto,
    ) -> Option<()> {
        // A colour glyph needs a real colour space; coverage needs the absence of one, because
        // `kCGImageAlphaOnly` is only legal with a NULL space.
        let space = if plan.color {
            Some(CGColorSpace::new_device_rgb()?)
        } else {
            None
        };
        // Premultiplied-first plus little-endian 32-bit is BGRA in memory, which is the byte order
        // `AtlasFormat::Bgra8` names and the one a Metal texture reads without a swizzle.
        let info = if plan.color {
            CGImageAlphaInfo::PremultipliedFirst.0 | CGImageByteOrderInfo::Order32Little.0
        } else {
            CGImageAlphaInfo::Only.0
        };

        // SAFETY: framework rule. Two obligations. The RETURN is the Core Foundation CREATE rule —
        // `CGBitmapContextCreate` answers a context this caller owns, and `objc2`'s hand-written
        // binding has already wrapped it in a `CFRetained` that releases it. The DATA argument is
        // the other: `scratch` is a `Vec<u8>` this crate allocated at exactly `stride * rows` bytes
        // before this call, nothing below reallocates or resizes it while the context is alive, and
        // the context is dropped before it is read. Core Graphics writes through the slot and never
        // frees it — the NULL-data form, which would make Core Graphics the owner and force a
        // `slice::from_raw_parts` to read back, is what this shape exists to avoid.
        #[expect(
            unsafe_code,
            reason = "a Create-rule return, plus a bitmap buffer this crate allocated"
        )]
        let context = unsafe {
            CGBitmapContextCreate(
                self.scratch.as_mut_ptr().cast(),
                plan.columns,
                plan.rows,
                8,
                plan.stride,
                space.as_deref(),
                info,
            )
        }?;

        CGContext::set_should_antialias(Some(&context), true);
        CGContext::set_allows_antialiasing(Some(&context), true);
        // Grayscale coverage, not LCD: see the module header.
        CGContext::set_allows_font_smoothing(Some(&context), false);
        CGContext::set_should_smooth_fonts(Some(&context), false);
        // The phase is ours, applied as a translation below; letting Core Graphics quantise on top
        // would round away the offset the whole four-phase cache exists to make.
        CGContext::set_allows_font_subpixel_quantization(Some(&context), false);
        CGContext::set_should_subpixel_quantize_fonts(Some(&context), false);
        CGContext::set_allows_font_subpixel_positioning(Some(&context), true);
        CGContext::set_should_subpixel_position_fonts(Some(&context), true);

        // Fully opaque white. In an alpha-only context the colour is ignored and the ALPHA is the
        // coverage that lands in the atlas; in a colour one the glyph carries its own colours and
        // this only matters for the parts of it that do not.
        if plan.color {
            CGContext::set_rgb_fill_color(Some(&context), 1.0, 1.0, 1.0, 1.0);
            CGContext::set_rgb_stroke_color(Some(&context), 1.0, 1.0, 1.0, 1.0);
        } else {
            CGContext::set_gray_fill_color(Some(&context), 1.0, 1.0);
            CGContext::set_gray_stroke_color(Some(&context), 1.0, 1.0);
        }
        if key.synthetic.bold {
            CGContext::set_text_drawing_mode(Some(&context), CGTextDrawingMode::FillStroke);
            CGContext::set_line_width(Some(&context), plan.stroke);
        }

        // Move the bitmap's origin onto the glyph's own, then add the subpixel phase.
        CGContext::translate_ctm(
            Some(&context),
            -plan.bounds.left + plan.phase,
            -plan.bounds.bottom,
        );
        if key.synthetic.italic {
            // Sheared about the point the translate just moved to, which is the glyph's origin: the
            // baseline stays put and only what rises above it leans, which is what a fake italic
            // is. Applied to the CTM rather than to the text matrix because the text
            // matrix also transforms the POSITION below, and a sheared position is not
            // where the glyph goes.
            CGContext::concat_ctm(Some(&context), CGAffineTransform {
                a: 1.0,
                b: 0.0,
                c: plan.shear,
                d: 1.0,
                tx: 0.0,
                ty: 0.0,
            });
        }

        let mut positions = [CGPoint { x: 0.0, y: 0.0 }];
        // SAFETY: framework rule. `CTFontDrawGlyphs` owns nothing and answers nothing; it reads two
        // one-element slots this function owns, with a count of 1 to match, and draws into a
        // context that is live for the whole call. Neither pointer is kept past the return.
        #[expect(
            unsafe_code,
            reason = "a draw call reading two one-element slots this fn owns"
        )]
        unsafe {
            font.draw_glyphs(
                NonNull::from(glyphs).cast(),
                NonNull::from(&mut positions).cast(),
                1,
                &context,
            );
        }
        // Explicit, and load-bearing: the `# Safety` note above promises the context is gone before
        // `scratch` is read, and the read is in the caller.
        drop(context);
        Some(())
    }
}

/// A bitmap edge, refused when a face's own tables ask for something absurd.
fn edge(value: f64) -> Option<u32> {
    let rounded = finite(value, 0.0);
    if !(1.0..=f64::from(MAX_GLYPH_EDGE)).contains(&rounded) {
        return None;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the range check above is exactly the one the cast would otherwise be trusted for"
    )]
    let edge = rounded as u32;
    Some(edge)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        clippy::integer_division,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_termrender::atlas::AtlasFormat;
    use slopdesk_termrender::glyph::{
        GlyphKey, GlyphRasterizer, ShapedGlyph, Synthetic, TextRun, TextShaper,
    };

    use crate::FontStack;

    const MONO: &str = "Menlo";

    /// One character through the real shaper, so the key under test is the one the renderer would
    /// actually hand over rather than one a test invented.
    fn key_of(stack: &FontStack, text: &str, subpixel: u8) -> GlyphKey {
        let mut shaper = stack.shaper();
        let mut out: Vec<ShapedGlyph> = Vec::new();
        shaper.shape(
            &TextRun {
                text,
                start_col: 0,
                cells: 1,
                bold: false,
                italic: false,
                size_px: stack.size_px(),
                subpixel,
            },
            &mut out,
        );
        out.first().unwrap().key
    }

    /// Ink, in the format an alpha atlas takes, inside a bitmap the bearings place on the baseline.
    #[test]
    fn a_letter_comes_back_as_coverage_with_ink_in_it() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        let glyph = rasterizer.rasterize(key_of(&stack, "M", 0)).unwrap();

        assert_eq!(glyph.format, AtlasFormat::Alpha8);
        assert!(glyph.width > 0 && glyph.height > 0);
        assert_eq!(
            glyph.pixels.len(),
            (glyph.width as usize) * (glyph.height as usize)
        );
        assert!(
            glyph.pixels.iter().any(|texel| *texel > 0),
            "a capital M is not blank"
        );
        // The bearings are the renderer's: up from the baseline to the top edge, right from the
        // origin to the left edge. An `M` sits on the baseline, so its top edge is above it and its
        // whole box is no taller than the cell.
        assert!(glyph.bearing_y > 0.0);
        assert!(f64::from(glyph.bearing_y) <= stack.cell_height());
        assert!(glyph.bearing_x.abs() < 8.0);
    }

    /// The top row of the bitmap is the TOP of the glyph. Core Graphics draws bottom-up, so a
    /// missing flip would put every glyph in the grid upside down — which reads as a font bug and
    /// is not one.
    #[test]
    fn the_first_row_is_the_top_of_the_glyph() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        // A `T` is a full-width crossbar over a narrow stem, so its two halves carry very different
        // amounts of ink and the difference survives any amount of antialiasing.
        let glyph = rasterizer.rasterize(key_of(&stack, "T", 0)).unwrap();
        let stride = glyph.width as usize;
        let rows = glyph.height as usize;
        let ink = |range: std::ops::Range<usize>| -> u32 {
            range
                .map(|row| {
                    glyph
                        .pixels
                        .get(row * stride..(row + 1) * stride)
                        .unwrap()
                        .iter()
                        .map(|t| u32::from(*t))
                        .sum::<u32>()
                })
                .sum()
        };
        assert!(
            ink(0..rows / 2) > ink(rows / 2..rows),
            "the crossbar is in the top half"
        );
    }

    /// A space EXISTS and draws nothing, which is a different answer from "no such glyph" — the
    /// cache keeps both and retries neither, so getting them the wrong way round would either draw
    /// a box or re-rasterise a space on every frame.
    #[test]
    fn a_space_exists_and_draws_nothing() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        let glyph = rasterizer.rasterize(key_of(&stack, " ", 0)).unwrap();
        assert_eq!(glyph.width, 0);
        assert_eq!(glyph.height, 0);
        assert!(glyph.pixels.is_empty());
    }

    /// A colour face comes back as BGRA, because coverage would lose everything about it.
    #[test]
    fn an_emoji_comes_back_as_colour() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        let key = key_of(&stack, "\u{1f600}", 0);
        assert_ne!(
            key.font, 0,
            "the Latin family has no emoji; Core Text substituted"
        );
        let glyph = rasterizer.rasterize(key).unwrap();

        assert_eq!(glyph.format, AtlasFormat::Bgra8);
        assert_eq!(
            glyph.pixels.len(),
            (glyph.width as usize) * (glyph.height as usize) * 4
        );
        // Premultiplied BGRA, so a coloured texel is one whose colour channels are not all equal —
        // a grayscale readback would make them identical and look like coverage in four copies.
        assert!(
            glyph
                .pixels
                .as_chunks::<4>()
                .0
                .iter()
                .any(|texel| texel[0] != texel[1] || texel[1] != texel[2]),
            "a yellow face is not gray"
        );
    }

    /// Four phases, four bitmaps. If they were identical the cache would be holding four copies of
    /// one answer and the whole subpixel key would be dead weight.
    #[test]
    fn the_four_phases_are_four_different_bitmaps() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        let base = key_of(&stack, "e", 0);
        let mut seen: Vec<Vec<u8>> = Vec::new();
        for phase in 0..4_u8 {
            let glyph = rasterizer
                .rasterize(GlyphKey {
                    subpixel: phase,
                    ..base
                })
                .unwrap();
            assert!(
                !seen.contains(&glyph.pixels),
                "phase {phase} repeats an earlier one"
            );
            seen.push(glyph.pixels);
        }
    }

    /// Synthesis is only for a family that needs it, but the mechanics have to be right when it
    /// does: a stroke adds ink and a shear moves it sideways.
    #[test]
    fn a_synthetic_bold_is_heavier_and_a_synthetic_italic_is_wider() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        let base = key_of(&stack, "H", 0);
        let plain = rasterizer.rasterize(base).unwrap();
        let coverage = |glyph: &slopdesk_termrender::glyph::RasterGlyph| -> u64 {
            glyph.pixels.iter().map(|texel| u64::from(*texel)).sum()
        };

        let bold = rasterizer
            .rasterize(GlyphKey {
                synthetic: Synthetic {
                    bold: true,
                    italic: false,
                },
                ..base
            })
            .unwrap();
        assert!(coverage(&bold) > coverage(&plain), "a stroke adds ink");

        let italic = rasterizer
            .rasterize(GlyphKey {
                synthetic: Synthetic {
                    bold: false,
                    italic: true,
                },
                ..base
            })
            .unwrap();
        assert!(
            italic.width > plain.width,
            "a shear leans the glyph out of its upright box"
        );
    }

    /// A key naming a face that is not in the chain, or a size that is not this stack's, is `None`
    /// — "no such glyph" — rather than something drawn at the wrong size.
    #[test]
    fn a_key_from_another_stack_is_declined() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        let base = key_of(&stack, "M", 0);
        assert!(
            rasterizer
                .rasterize(GlyphKey {
                    size_px: base.size_px + 1,
                    ..base
                })
                .is_none()
        );
        assert!(
            rasterizer
                .rasterize(GlyphKey {
                    font: u16::MAX,
                    ..base
                })
                .is_none()
        );
    }

    /// The leak test for the rasterising half: a thousand glyphs, each taking and dropping a bitmap
    /// context and a colour space.
    #[test]
    fn a_thousand_glyphs_hold_nothing() {
        let stack = FontStack::new(MONO, 13.0, 2.0).unwrap();
        let mut rasterizer = stack.rasterizer();
        let coverage = key_of(&stack, "W", 0);
        let color = key_of(&stack, "\u{1f600}", 0);
        for _ in 0..1000 {
            assert!(rasterizer.rasterize(coverage).is_some());
            assert!(rasterizer.rasterize(color).is_some());
        }
    }
}
