//! The arithmetic, kept apart from the framework so it can be tested with no GPU attached.
//!
//! Everything in this module is a pure function over integers and floats. That is deliberate and it
//! is the same argument `slopdesk-termrender`'s header makes: the parts of a renderer most likely
//! to be subtly wrong are the index arithmetic and the coordinate conversion, and both of those are
//! reachable from `cargo test` on a machine with no display. What is left in the rest of the crate
//! is calls, which a test could only ever assert did not crash.
//!
//! Three things live here:
//!
//! - [`Viewport`], the one per-frame uniform, plus the vertex shader's own pixels-to-clip-space
//!   conversion transcribed into this module's TESTS. Having it twice looks like duplication; it is
//!   a CHECK, and the test module is the honest place for it because nothing in the library ever
//!   runs it — the shader does. `cargo test` cannot reach the shader, so the transcription is what
//!   pins the corners a regression would move.
//! - [`Upload`], the map from an [`AtlasRegion`] to the four arguments `replaceRegion:` wants plus
//!   the byte range a caller must lend. Getting that range one row short is a diagonal tear across
//!   every glyph added since the last frame, and it is exactly the sort of off-by-one that reads
//!   correct.
//! - [`TextureKey`], which answers the question `docs/68` cares about most: patch, or throw away?

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use slopdesk_termrender::AtlasRegion;

/// The drawable's size in device pixels, as the vertex shader reads it.
///
/// `#[repr(C)]` and two `f32`s, matching `Viewport` in `shaders.metal`. It goes across by
/// `setVertexBytes`, Metal's inline path for a uniform under 4 KiB — a whole `MTLBuffer` for eight
/// bytes that change once a frame would be an allocation and a fence for nothing.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
#[repr(C)]
pub(crate) struct Viewport {
    /// Drawable width in device pixels.
    pub(crate) width: f32,
    /// Drawable height in device pixels.
    pub(crate) height: f32,
}

impl Viewport {
    /// Whether the viewport would divide by zero.
    ///
    /// A zero-sized drawable is what a collapsed split and a window mid-resize both produce, and it
    /// arrives here rather than at the shader because a NaN clip coordinate does not fail — it
    /// draws nothing, silently, and looks like a bug somewhere else.
    #[must_use]
    pub(crate) fn is_degenerate(self) -> bool {
        // `f32::max` rather than a `<` ternary — `CLAUDE.md`'s bit-exactness rule — and it does the
        // NaN work for free: `max` of NaN and zero is zero, so a NaN drawable size reads degenerate
        // rather than sailing through a comparison that is false in both directions.
        let smallest = self.width.max(0.0).min(self.height.max(0.0));
        smallest <= 0.0 || self.width.is_nan() || self.height.is_nan()
    }
}

/// How many bytes `count` instances of `T` occupy in an `MTLBuffer`.
///
/// A function rather than an inline multiply so there is ONE place the buffer length, the copy
/// length and the capacity check are derived from — three spellings of the same product is how a
/// buffer comes to be sized for the old frame.
#[must_use]
pub(crate) const fn instance_bytes<T>(count: usize) -> usize {
    size_of::<T>() * count
}

/// What identifies the texture currently standing in for an atlas.
///
/// [`slopdesk_termrender::Atlas`] bumps its generation on `grow` — which also DOUBLES the size and
/// throws every packed region away — and on `reset`, which keeps the size and throws the regions
/// away anyway. Either way every UV the cache hands out afterwards refers to a different picture,
/// so patching the old texture with the new dirty rect would leave the untouched majority of it
/// holding the previous frame's glyphs at the previous frame's coordinates. That is the "screen of
/// garbage" case, and the generation is the only thing that distinguishes it from an ordinary
/// incremental frame — the size alone does NOT, because `reset` does not change it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TextureKey {
    /// The atlas edge length in texels. Square, always — `Atlas::new` takes one number.
    pub(crate) size: u32,
    /// The atlas generation this texture was filled from.
    pub(crate) generation: u32,
}

impl TextureKey {
    /// Whether a texture keyed `self` may be patched to serve an atlas keyed `wanted`.
    ///
    /// Both halves matter and neither is redundant: a size change without a generation change is
    /// impossible today but would be a resized texture tomorrow, and a generation change without a
    /// size change is `reset`, which is the common one.
    #[must_use]
    pub(crate) const fn can_patch(self, wanted: Self) -> bool {
        self.size == wanted.size && self.generation == wanted.generation
    }
}

/// One `replaceRegion:mipmapLevel:withBytes:bytesPerRow:` call, resolved to numbers.
///
/// The byte range is the load-bearing part. Metal reads `height` rows of `width * bytes_per_texel`
/// bytes each, `bytes_per_row` apart, starting at the pointer it is given — so the last byte it
/// touches is in the LAST row and at the RIGHT edge, not at the end of the last row's stride.
/// Handing it a slice that stops at `offset + height * bytes_per_row` would be over-lending by most
/// of a row; handing it one that stops at `offset + height * width * bytes_per_texel` would be
/// under. [`Upload::end`] is the exact answer, and the crate takes a safe subslice with it rather
/// than building a pointer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Upload {
    /// Left edge of the region, in texels.
    pub(crate) origin_x: u32,
    /// Top edge of the region, in texels.
    pub(crate) origin_y: u32,
    /// Region width in texels.
    pub(crate) width: u32,
    /// Region height in texels.
    pub(crate) height: u32,
    /// First byte of the region within `Atlas::pixels`.
    pub(crate) offset: usize,
    /// One past the last byte Metal will read.
    pub(crate) end: usize,
    /// The ATLAS row stride, not the region's. Passing the region's would make Metal walk a
    /// sub-rectangle as if it were contiguous and shear it.
    pub(crate) bytes_per_row: usize,
}

impl Upload {
    /// The upload for one dirty region of a `size × size` atlas at `bytes_per_texel`.
    ///
    /// `None` for an empty region — the ordinary case, since most frames add no glyph — and `None`
    /// for a region that does not fit the atlas, which cannot happen through
    /// [`slopdesk_termrender::Atlas`]'s own allocator but is checked anyway because this is the
    /// function whose output becomes a slice bound.
    #[must_use]
    pub(crate) fn plan(region: AtlasRegion, size: u32, bytes_per_texel: u32) -> Option<Self> {
        if region.is_empty() || size == 0 || bytes_per_texel == 0 {
            return None;
        }
        let right = region.x.checked_add(region.width)?;
        let bottom = region.y.checked_add(region.height)?;
        if right > size || bottom > size {
            return None;
        }
        let stride = (size as usize).checked_mul(bytes_per_texel as usize)?;
        let offset =
            (region.y as usize).checked_mul(stride)? + (region.x as usize) * (bytes_per_texel as usize);
        let last_row = (bottom as usize - 1).checked_mul(stride)?;
        let end = last_row + (right as usize) * (bytes_per_texel as usize);
        Some(Self {
            origin_x: region.x,
            origin_y: region.y,
            width: region.width,
            height: region.height,
            offset,
            end,
            bytes_per_row: stride,
        })
    }

    /// The upload that covers a whole atlas — what a recreated texture needs.
    #[must_use]
    pub(crate) fn whole(size: u32, bytes_per_texel: u32) -> Option<Self> {
        Self::plan(
            AtlasRegion {
                x: 0,
                y: 0,
                width: size,
                height: size,
            },
            size,
            bytes_per_texel,
        )
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_termrender::{AtlasRegion, GlyphInstance, RectInstance, RectStyle};

    use super::{TextureKey, Upload, Viewport, instance_bytes};

    /// Device pixels with a top-left origin to Metal clip space, exactly as `shaders.metal` does
    /// it.
    ///
    /// The three steps stay apart because `CLAUDE.md` forbids a fused multiply-add: `a * b + c`
    /// written as one expression is a licence for the optimiser to round once instead of twice,
    /// and a renderer whose Rust and Metal halves round differently has a half-pixel seam that
    /// only shows on some hardware.
    #[must_use]
    fn to_clip(x: f32, y: f32, viewport: Viewport) -> [f32; 2] {
        let unit_x = x / viewport.width;
        let unit_y = y / viewport.height;
        let doubled_x = unit_x * 2.0;
        let doubled_y = unit_y * 2.0;
        let ndc_x = doubled_x - 1.0;
        let ndc_y = doubled_y - 1.0;
        [ndc_x, -ndc_y]
    }

    const VIEWPORT: Viewport = Viewport {
        width: 800.0,
        height: 600.0,
    };

    #[test]
    fn the_instance_structs_are_the_size_the_shader_asserts() {
        // `shaders.metal` carries the same two numbers in `static_assert`s, so this test and the
        // shader compile fail TOGETHER when `quad.rs` grows a field — one of them from `cargo test`
        // with no GPU, the other from `Renderer::new` on a machine that has one.
        assert_eq!(
            size_of::<RectInstance>(),
            24,
            "RectInstance drifted from shaders.metal"
        );
        assert_eq!(
            size_of::<GlyphInstance>(),
            40,
            "GlyphInstance drifted from shaders.metal"
        );
        assert_eq!(size_of::<Viewport>(), 8, "Viewport drifted from shaders.metal");
    }

    #[test]
    fn the_rect_styles_match_the_shader() {
        // `shaders.metal`'s `kStyle*` constants, from the Rust side. Nothing else can check them:
        // the shader is a string until start-up, and a mismatch here paints a solid block where an
        // underline belongs rather than failing.
        assert_eq!(RectStyle::Solid as u32, 0);
        assert_eq!(RectStyle::Dotted as u32, 1);
        assert_eq!(RectStyle::Dashed as u32, 2);
        assert_eq!(RectStyle::Curly as u32, 3);
        assert_eq!(RectStyle::Hollow as u32, 4);
    }

    #[test]
    fn the_corners_of_the_drawable_land_on_the_corners_of_clip_space() {
        assert_corner(to_clip(0.0, 0.0, VIEWPORT), [-1.0, 1.0], "top left");
        assert_corner(to_clip(800.0, 0.0, VIEWPORT), [1.0, 1.0], "top right");
        assert_corner(to_clip(0.0, 600.0, VIEWPORT), [-1.0, -1.0], "bottom left");
        assert_corner(to_clip(800.0, 600.0, VIEWPORT), [1.0, -1.0], "bottom right");
        assert_corner(to_clip(400.0, 300.0, VIEWPORT), [0.0, 0.0], "the centre");
    }

    /// A clip coordinate against its expected corner, componentwise.
    ///
    /// The corners of clip space are exact in binary — the arithmetic is a divide by the viewport,
    /// a double and a subtract of one — so this could be `assert_eq!`. It is not, because a lint
    /// that objects to comparing float arrays is objecting to the SHAPE rather than to this case,
    /// and a helper answers it once instead of five suppressions.
    fn assert_corner(actual: [f32; 2], expected: [f32; 2], corner: &str) {
        let [x, y] = actual;
        let [want_x, want_y] = expected;
        assert!(
            (x - want_x).abs() < f32::EPSILON,
            "{corner}: x was {x}, wanted {want_x}"
        );
        assert!(
            (y - want_y).abs() < f32::EPSILON,
            "{corner}: y was {y}, wanted {want_y}"
        );
    }

    #[test]
    fn y_is_flipped_and_x_is_not() {
        let [x, y] = to_clip(200.0, 150.0, VIEWPORT);
        assert!(x < 0.0, "a quarter across is left of centre in clip space");
        assert!(
            y > 0.0,
            "a quarter down is ABOVE centre — Metal's clip space is Y-up"
        );
    }

    #[test]
    fn a_collapsed_drawable_is_caught_before_it_divides() {
        assert!(
            Viewport {
                width: 0.0,
                height: 600.0
            }
            .is_degenerate()
        );
        assert!(
            Viewport {
                width: 800.0,
                height: 0.0
            }
            .is_degenerate()
        );
        assert!(
            Viewport {
                width: f32::NAN,
                height: 600.0
            }
            .is_degenerate()
        );
        assert!(!VIEWPORT.is_degenerate());
    }

    #[test]
    fn a_buffer_is_sized_by_the_struct_and_not_by_a_guess() {
        assert_eq!(instance_bytes::<RectInstance>(0), 0);
        assert_eq!(instance_bytes::<RectInstance>(1000), 24_000);
        assert_eq!(instance_bytes::<GlyphInstance>(1000), 40_000);
    }

    #[test]
    fn a_dirty_rect_lends_exactly_the_bytes_metal_reads() {
        // A 4×3 region at (2, 1) of a 16-texel coverage atlas. Metal reads three rows of four
        // bytes, sixteen bytes apart; the last byte it touches is row 3's, column 5 — `3 *
        // 16 + 6`, which is a whole stride short of where "three full rows" would put it.
        let region = AtlasRegion {
            x: 2,
            y: 1,
            width: 4,
            height: 3,
        };
        assert_eq!(
            Upload::plan(region, 16, 1),
            Some(Upload {
                origin_x: 2,
                origin_y: 1,
                width: 4,
                height: 3,
                offset: 16 + 2,
                end: 3 * 16 + 6,
                bytes_per_row: 16,
            }),
            "the stride is the ATLAS's, and the end is the last row's RIGHT EDGE"
        );
    }

    #[test]
    fn a_four_byte_texel_scales_both_the_stride_and_the_column() {
        let region = AtlasRegion {
            x: 2,
            y: 1,
            width: 4,
            height: 3,
        };
        assert_eq!(
            Upload::plan(region, 16, 4),
            Some(Upload {
                origin_x: 2,
                origin_y: 1,
                width: 4,
                height: 3,
                offset: 64 + 8,
                end: 3 * 64 + 24,
                bytes_per_row: 64,
            })
        );
    }

    #[test]
    fn the_last_texel_of_an_atlas_is_the_last_byte_of_its_pixels() {
        assert_eq!(
            Upload::whole(512, 4),
            Some(Upload {
                origin_x: 0,
                origin_y: 0,
                width: 512,
                height: 512,
                offset: 0,
                end: 512 * 512 * 4,
                bytes_per_row: 512 * 4,
            }),
            "one texel short would clip a row"
        );
    }

    #[test]
    fn an_empty_or_escaping_region_plans_nothing() {
        assert!(
            Upload::plan(AtlasRegion::default(), 512, 1).is_none(),
            "an empty dirty rect"
        );
        assert!(
            Upload::plan(
                AtlasRegion {
                    x: 510,
                    y: 0,
                    width: 4,
                    height: 1
                },
                512,
                1
            )
            .is_none(),
            "a region running off the right edge"
        );
        assert!(
            Upload::plan(
                AtlasRegion {
                    x: 0,
                    y: 510,
                    width: 1,
                    height: 4
                },
                512,
                1
            )
            .is_none(),
            "a region running off the bottom edge"
        );
        assert!(Upload::whole(0, 1).is_none(), "an atlas with no texels");
    }

    #[test]
    fn a_generation_bump_forbids_a_patch_even_at_the_same_size() {
        let held = TextureKey {
            size: 1024,
            generation: 7,
        };
        assert!(
            held.can_patch(TextureKey {
                size: 1024,
                generation: 7
            }),
            "an ordinary frame patches"
        );
        assert!(
            !held.can_patch(TextureKey {
                size: 1024,
                generation: 8
            }),
            "Atlas::reset keeps the size and invalidates every UV — patching would keep the old glyphs"
        );
        assert!(
            !held.can_patch(TextureKey {
                size: 2048,
                generation: 8
            }),
            "Atlas::grow doubles and invalidates"
        );
        assert!(
            !held.can_patch(TextureKey {
                size: 2048,
                generation: 7
            }),
            "a size change alone is still a different texture"
        );
    }
}
