//! What a glyph is to this crate, and the two doors a font engine comes in through.
//!
//! ## The seam
//!
//! `slopdesk-termrender` has no font engine and must not grow one: Core Text lives in
//! `slopdesk-apple-text`, which `docs/57` §2 makes the only place an Apple framework may be called.
//! What crosses the boundary is two traits and a key.
//!
//! - [`TextShaper`] turns a run of same-styled cells into positioned glyph ids. Shaping is where
//!   ligatures and the fallback chain are decided, and both need the font — so both stay on the
//!   other side of this trait.
//! - [`GlyphRasterizer`] turns one glyph id into coverage. Also the font's business.
//!
//! Everything after those two answers — packing, caching, invalidation, quads — is arithmetic, and
//! arithmetic belongs where it can be tested without a font installed. Every test in this crate
//! drives a fake implementation of both traits.
//!
//! ## Why the key is a glyph id and not a string
//!
//! The obvious cache key is the grapheme cluster: `"a"`, `"→"`, `"👍🏽"`. It is wrong twice. It
//! misses the case a ligature covers — `!=` shapes to ONE glyph in a font that has it, and a
//! per-cluster key cannot name that glyph. And it over-keys the common case: two clusters that
//! shape to the same glyph (a precomposed `é` and a decomposed one) would rasterise twice and eat
//! two atlas slots for identical pixels. Keying by what the rasteriser actually consumes — font,
//! glyph id, size, subpixel phase — is both narrower and complete.

use std::collections::HashMap;

use crate::atlas::{Atlas, AtlasFormat, AtlasRegion, MIN_ATLAS_SIZE};

/// How many horizontal subpixel phases a glyph is rasterised at.
///
/// Text in a terminal is laid out on a cell grid, so a glyph's x usually lands on an integer — but
/// "usually" is not "always": a 1.5× Retina scale, a fractional cell width from a fitted font size,
/// and the shaper's own offsets all put glyphs between texels. Four phases is the ordinary
/// compromise: it removes the visible jitter at the cost of at most 4× the atlas slots for the
/// glyphs that need it, and phase 0 — the whole steady state of a monospace grid — is shared.
pub const SUBPIXEL_PHASES: u8 = 4;

/// The synthetic styling a rasteriser has to apply because the face does not carry it.
///
/// Not "is this bold" — that is the face the shaper picked. This is the fallback: a monospace
/// family with no italic cut still has to draw italic, and the answer is a shear applied at
/// rasterisation time. It belongs in the key because the same glyph id sheared and unsheared are
/// different pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Synthetic {
    /// Emboldening was synthesised rather than taken from a bold face.
    pub bold: bool,
    /// The slant was synthesised rather than taken from an italic face.
    pub italic: bool,
}

/// Everything that decides a glyph's pixels.
///
/// `Copy` and hashable because it is the cache key and is looked up once per drawn cell — 10 000
/// times for a 200×50 viewport repaint, which is a rate at which an allocation would show up.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GlyphKey {
    /// Which face in the fallback chain the shaper resolved to. The chain's order is
    /// `slopdesk-apple-text`'s business; this is only an identity.
    pub font: u16,
    /// The face-specific glyph id the shaper produced.
    pub glyph: u32,
    /// Rasterisation size in DEVICE pixels — already multiplied by the contents scale, because a
    /// glyph rasterised for a 1× display and one for a 2× display are different pixels and must not
    /// collide.
    pub size_px: u16,
    /// The horizontal subpixel phase, <code>0..[SUBPIXEL_PHASES]</code>.
    pub subpixel: u8,
    /// The styling the rasteriser has to synthesise.
    pub synthetic: Synthetic,
}

impl GlyphKey {
    /// The phase bucket for a glyph whose left edge lands at `x` device pixels.
    #[must_use]
    pub fn phase(x: f64) -> u8 {
        // NaN is answered here rather than by the clamp below, because `f64::min` does NOT
        // propagate it — IEEE `minNum` answers the non-NaN operand, so a NaN x would fall
        // out as the LAST phase rather than the first. Named because it is exactly the bug
        // the naive version has.
        if x.is_nan() {
            return 0;
        }
        let phases = f64::from(SUBPIXEL_PHASES);
        let fraction = x - x.floor();
        // `f64::min` rather than a `<` ternary, per `CLAUDE.md`.
        let bucket = f64::min(fraction * phases, phases - 1.0);
        if bucket >= 0.0 {
            // The value is in `0.0..SUBPIXEL_PHASES` by the clamp above, so the cast is exact.
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "clamped to 0..SUBPIXEL_PHASES immediately above"
            )]
            let phase = bucket as u8;
            phase
        } else {
            0
        }
    }
}

/// Coverage for one glyph, as the rasteriser hands it over.
///
/// The bitmap is owned because rasterisation is a cold path — once per glyph per session, against a
/// cache that answers every subsequent lookup — and a borrowed buffer would put a lifetime through
/// the whole trait for no measurable gain.
#[derive(Debug, Clone, PartialEq)]
pub struct RasterGlyph {
    /// Bitmap width in texels. Zero for a glyph with no ink, such as a space.
    pub width: u32,
    /// Bitmap height in texels.
    pub height: u32,
    /// Pixels from the glyph's origin to the bitmap's LEFT edge, positive rightwards.
    pub bearing_x: f32,
    /// Pixels from the glyph's baseline to the bitmap's TOP edge, positive upwards.
    pub bearing_y: f32,
    /// What one texel holds. Colour emoji come back [`AtlasFormat::Bgra8`]; everything else is
    /// coverage the cell's foreground is multiplied through.
    pub format: AtlasFormat,
    /// `width × height` texels at `format`, row-major, tightly packed, top-left origin.
    pub pixels: Vec<u8>,
}

impl RasterGlyph {
    /// A glyph with no ink — what a space, a control picture placeholder and an unmapped id all
    /// rasterise to.
    #[must_use]
    pub const fn blank() -> Self {
        Self {
            width: 0,
            height: 0,
            bearing_x: 0.0,
            bearing_y: 0.0,
            format: AtlasFormat::Alpha8,
            pixels: Vec::new(),
        }
    }
}

/// One shaped glyph, positioned relative to its run's origin.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShapedGlyph {
    /// What to rasterise.
    pub key: GlyphKey,
    /// Device pixels right of the run origin, to the glyph's own origin.
    pub x: f32,
    /// Device pixels DOWN from the run's baseline, to the glyph's origin. Usually zero; non-zero
    /// for a mark the shaper repositioned.
    pub y: f32,
    /// Which cell of the run this glyph belongs to, zero-based.
    ///
    /// A ligature reports the FIRST cell it covers, which is what makes a selection or a cursor
    /// under the second half of `!=` still find something to invert.
    pub cell: u16,
}

/// A run of cells the shaper may treat as one piece of text.
///
/// A run never crosses a styling change, because a bold `f` and a regular `i` cannot ligate, and it
/// never crosses a selection boundary, because the two halves draw in different colours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextRun<'a> {
    /// The run's text, back to back with no separators.
    pub text: &'a str,
    /// The run's first column in the row.
    pub start_col: u16,
    /// How many cells the run covers. Not the same as the character count — a wide glyph is two.
    pub cells: u16,
    /// Whether a bold face is wanted.
    pub bold: bool,
    /// Whether an italic face is wanted.
    pub italic: bool,
    /// The size to shape at, in DEVICE pixels.
    pub size_px: u16,
    /// The run origin's subpixel phase, which the shaper folds into every key it emits.
    pub subpixel: u8,
}

/// Turns text into positioned glyph ids. Implemented in `slopdesk-apple-text` over Core Text.
pub trait TextShaper {
    /// Appends `run`'s glyphs to `out`. An implementation that cannot shape appends nothing, and
    /// the run draws blank rather than the caller failing.
    fn shape(&mut self, run: &TextRun<'_>, out: &mut Vec<ShapedGlyph>);
}

/// Turns a glyph id into coverage. Implemented in `slopdesk-apple-text` over Core Text.
pub trait GlyphRasterizer {
    /// Rasterises `key`, or `None` when the face cannot draw it.
    ///
    /// `None` and [`RasterGlyph::blank`] mean different things and both are cached: `None` is "this
    /// id does not exist", `blank` is "it exists and has no ink". Neither is retried.
    fn rasterize(&mut self, key: GlyphKey) -> Option<RasterGlyph>;
}

/// Where a glyph ended up, and how to place it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CachedGlyph {
    /// The texels, or an empty region for a glyph with no ink.
    pub region: AtlasRegion,
    /// Which atlas holds it.
    pub format: AtlasFormat,
    /// Pixels from the glyph's origin to the bitmap's left edge.
    pub bearing_x: i32,
    /// Pixels from the glyph's baseline to the bitmap's top edge, positive upwards.
    pub bearing_y: i32,
}

impl CachedGlyph {
    /// Whether there is anything to draw.
    #[must_use]
    pub const fn is_blank(&self) -> bool {
        self.region.is_empty()
    }
}

/// The two atlases and the map into them.
///
/// Two atlases and not one, because colour emoji cannot share a texture with coverage: they carry
/// their own colour, need four bytes a texel where text needs one, and sample through a different
/// fragment path. Merging them would quadruple the memory every ASCII glyph costs to make one rare
/// case simpler.
#[derive(Debug)]
pub struct GlyphCache {
    alpha: Atlas,
    color: Atlas,
    entries: HashMap<GlyphKey, Option<CachedGlyph>>,
}

impl Default for GlyphCache {
    fn default() -> Self {
        Self::new()
    }
}

impl GlyphCache {
    /// An empty cache with both atlases at [`MIN_ATLAS_SIZE`].
    #[must_use]
    pub fn new() -> Self {
        Self {
            alpha: Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8),
            color: Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Bgra8),
            entries: HashMap::new(),
        }
    }

    /// The coverage atlas — text.
    #[must_use]
    pub const fn alpha_atlas(&self) -> &Atlas {
        &self.alpha
    }

    /// The colour atlas — emoji.
    #[must_use]
    pub const fn color_atlas(&self) -> &Atlas {
        &self.color
    }

    /// Both atlases, mutably, for an uploader that needs [`Atlas::take_dirty`].
    pub const fn atlases_mut(&mut self) -> (&mut Atlas, &mut Atlas) {
        (&mut self.alpha, &mut self.color)
    }

    /// Throws every glyph away — what a font or a size change calls.
    ///
    /// A font change invalidates the KEYS as well as the pixels, because `font: 0` means a
    /// different face afterwards. Nothing in the key can express that, and nothing needs to:
    /// the cache is rebuilt from a cold start in a few milliseconds.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.alpha.reset();
        self.color.reset();
    }

    /// How many glyphs are cached, including the ones that resolved to nothing.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether nothing is cached.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The cached glyph for `key`, rasterising it through `rasterizer` on a miss.
    ///
    /// A full atlas grows once and the lookup is retried; a second failure answers `None` and is
    /// remembered, so a glyph too large for [`crate::atlas::MAX_ATLAS_SIZE`] costs one
    /// rasterisation rather than one per frame forever.
    ///
    /// **Growth invalidates every region the atlas that grew has ever returned** — the other
    /// atlas keeps its regions and its entries. A caller that keeps a [`CachedGlyph`] across calls
    /// must re-check [`Atlas::generation`] for that glyph's own format; a caller that looks up per
    /// draw — which is what [`crate::paint`] does — needs nothing, because the map is rebuilt in
    /// the same pass.
    pub fn get(&mut self, key: GlyphKey, rasterizer: &mut impl GlyphRasterizer) -> Option<CachedGlyph> {
        if let Some(held) = self.entries.get(&key) {
            return *held;
        }
        let entry = self.insert(key, rasterizer);
        self.entries.insert(key, entry);
        entry
    }

    fn insert(&mut self, key: GlyphKey, rasterizer: &mut impl GlyphRasterizer) -> Option<CachedGlyph> {
        let raster = rasterizer.rasterize(key)?;
        let atlas = match raster.format {
            AtlasFormat::Alpha8 => &mut self.alpha,
            AtlasFormat::Bgra8 => &mut self.color,
        };

        let mut region = atlas.alloc(raster.width, raster.height);
        if region.is_none() {
            // One growth, then one retry. Growth restarts the shelves of the atlas that grew, so
            // every region IT handed out is dead and handing one out again would sample generation
            // N-1. The other atlas is untouched, and dropping its entries too would ORPHAN regions
            // that are still allocated in it: nothing would ever hand them out again and nothing
            // frees them, so an emoji-heavy screen would refill the colour atlas from scratch every
            // time the text atlas grew. Retain by format, and keep the misses — a `None` belongs to
            // no atlas.
            let dead = raster.format;
            if !atlas.grow() {
                return None;
            }
            self.entries
                .retain(|_, held| held.is_none_or(|glyph| glyph.format != dead));
            let atlas = match raster.format {
                AtlasFormat::Alpha8 => &mut self.alpha,
                AtlasFormat::Bgra8 => &mut self.color,
            };
            region = atlas.alloc(raster.width, raster.height);
        }
        let region = region?;

        let atlas = match raster.format {
            AtlasFormat::Alpha8 => &mut self.alpha,
            AtlasFormat::Bgra8 => &mut self.color,
        };
        if !atlas.write(region, &raster.pixels) {
            return None;
        }

        Some(CachedGlyph {
            region,
            format: raster.format,
            bearing_x: round_to_i32(raster.bearing_x),
            bearing_y: round_to_i32(raster.bearing_y),
        })
    }
}

/// Bearings are texel offsets into an integer grid, so they round once here rather than at every
/// quad. `f32::round` then a saturating narrow: a NaN or an absurd bearing lands at zero rather
/// than wrapping into a glyph drawn two screens away.
#[expect(
    clippy::cast_possible_truncation,
    reason = "saturating: the comparisons below fence the value into i32 before the cast"
)]
fn round_to_i32(value: f32) -> i32 {
    let rounded = value.round();
    if rounded >= 2_147_483_000.0 {
        i32::MAX
    } else if rounded <= -2_147_483_000.0 {
        i32::MIN
    } else if rounded.is_nan() {
        0
    } else {
        rounded as i32
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        CachedGlyph, GlyphCache, GlyphKey, GlyphRasterizer, RasterGlyph, SUBPIXEL_PHASES, Synthetic,
    };
    use crate::atlas::AtlasFormat;

    /// A rasteriser that draws every glyph as a solid square, and counts how often it was asked.
    #[derive(Debug)]
    struct Counting {
        calls: usize,
        side: u32,
        format: AtlasFormat,
        refuse: bool,
    }

    impl Counting {
        fn new(side: u32) -> Self {
            Self {
                calls: 0,
                side,
                format: AtlasFormat::Alpha8,
                refuse: false,
            }
        }
    }

    impl GlyphRasterizer for Counting {
        fn rasterize(&mut self, _key: GlyphKey) -> Option<RasterGlyph> {
            self.calls += 1;
            if self.refuse {
                return None;
            }
            let texels =
                (self.side as usize) * (self.side as usize) * (self.format.bytes_per_texel() as usize);
            Some(RasterGlyph {
                width: self.side,
                height: self.side,
                bearing_x: 1.0,
                bearing_y: 2.0,
                format: self.format,
                pixels: vec![0xAB; texels],
            })
        }
    }

    fn key(glyph: u32) -> GlyphKey {
        GlyphKey {
            font: 0,
            glyph,
            size_px: 24,
            subpixel: 0,
            synthetic: Synthetic::default(),
        }
    }

    #[test]
    fn the_second_lookup_of_a_glyph_does_not_rasterise_it_again() {
        let mut cache = GlyphCache::new();
        let mut raster = Counting::new(8);

        let first = cache.get(key(7), &mut raster).unwrap();
        let second = cache.get(key(7), &mut raster).unwrap();

        assert_eq!(raster.calls, 1);
        assert_eq!(first, second);
        assert_eq!(first.bearing_x, 1);
        assert_eq!(first.bearing_y, 2);
    }

    #[test]
    fn a_refused_glyph_is_remembered_as_refused() {
        let mut cache = GlyphCache::new();
        let mut raster = Counting {
            refuse: true,
            ..Counting::new(8)
        };

        assert_eq!(cache.get(key(7), &mut raster), None);
        assert_eq!(cache.get(key(7), &mut raster), None);
        assert_eq!(
            raster.calls, 1,
            "a missing glyph must not be re-asked every frame"
        );
    }

    #[test]
    fn colour_glyphs_land_in_the_colour_atlas_and_text_in_the_alpha_one() {
        let mut cache = GlyphCache::new();
        let mut text = Counting::new(8);
        let mut emoji = Counting {
            format: AtlasFormat::Bgra8,
            ..Counting::new(8)
        };

        let glyph: CachedGlyph = cache.get(key(1), &mut text).unwrap();
        let emoji_glyph = cache.get(key(2), &mut emoji).unwrap();

        assert_eq!(glyph.format, AtlasFormat::Alpha8);
        assert_eq!(emoji_glyph.format, AtlasFormat::Bgra8);
        // Both took the origin of their own atlas — they are not sharing a packer.
        assert_eq!(glyph.region.x, 0);
        assert_eq!(emoji_glyph.region.x, 0);
    }

    #[test]
    fn a_full_atlas_grows_once_and_the_glyph_still_lands() {
        let mut cache = GlyphCache::new();
        // 96-texel squares: 25 fit across a 512 atlas, five shelves deep, so ~125 fill it.
        let mut raster = Counting::new(96);

        let before = cache.alpha_atlas().size();
        for glyph in 0..200 {
            assert!(
                cache.get(key(glyph), &mut raster).is_some(),
                "glyph {glyph} was dropped"
            );
        }
        assert!(cache.alpha_atlas().size() > before, "the atlas never grew");
    }

    #[test]
    fn growing_one_atlas_leaves_the_other_atlas_cached() {
        let mut cache = GlyphCache::new();
        let mut emoji = Counting {
            format: AtlasFormat::Bgra8,
            ..Counting::new(8)
        };
        let mut text = Counting::new(96);

        let before = cache.get(key(1), &mut emoji).unwrap();
        let generation = cache.color_atlas().generation();
        let alpha_generation = cache.alpha_atlas().generation();
        // Fill the alpha atlas until it has to grow. The colour atlas is not involved.
        for glyph in 1000..1200 {
            let _ = cache.get(key(glyph), &mut text);
        }
        assert_ne!(
            cache.alpha_atlas().generation(),
            alpha_generation,
            "the alpha atlas never grew"
        );

        let after = cache.get(key(1), &mut emoji).unwrap();
        assert_eq!(
            emoji.calls, 1,
            "growing the ALPHA atlas evicted a colour glyph and orphaned its region"
        );
        assert_eq!(after, before);
        assert_eq!(
            cache.color_atlas().generation(),
            generation,
            "the colour atlas was reset for no reason"
        );
    }

    #[test]
    fn clearing_empties_both_atlases_and_the_map() {
        let mut cache = GlyphCache::new();
        let mut raster = Counting::new(8);
        let _ = cache.get(key(1), &mut raster);
        let generation = cache.alpha_atlas().generation();

        cache.clear();

        assert!(cache.is_empty());
        assert_ne!(cache.alpha_atlas().generation(), generation);
        let _ = cache.get(key(1), &mut raster);
        assert_eq!(raster.calls, 2, "a cleared cache must re-rasterise");
    }

    #[test]
    fn a_blank_glyph_caches_as_blank_rather_than_as_a_miss() {
        #[derive(Debug)]
        struct Blank;
        impl GlyphRasterizer for Blank {
            fn rasterize(&mut self, _key: GlyphKey) -> Option<RasterGlyph> {
                Some(RasterGlyph::blank())
            }
        }

        let mut cache = GlyphCache::new();
        let glyph = cache.get(key(32), &mut Blank).unwrap();
        assert!(glyph.is_blank());
    }

    #[test]
    fn the_subpixel_phase_buckets_the_fraction() {
        assert_eq!(GlyphKey::phase(10.0), 0);
        assert_eq!(GlyphKey::phase(10.3), 1);
        assert_eq!(GlyphKey::phase(10.5), 2);
        assert_eq!(GlyphKey::phase(10.99), SUBPIXEL_PHASES - 1);
        assert_eq!(GlyphKey::phase(f64::NAN), 0, "a NaN must not pick a phase");
    }
}
