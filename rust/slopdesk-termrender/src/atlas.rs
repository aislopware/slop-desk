//! The glyph atlas: one texture, packed by shelves, owned on the CPU side.
//!
//! ## Why the pixels live here and not in the Metal crate
//!
//! An atlas is a packing decision and a byte copy. Neither needs a GPU, and putting them behind one
//! would make the whole cache untestable — the thing most likely to be subtly wrong (a region that
//! overlaps its neighbour, a growth that forgets to invalidate) would only be observable as smeared
//! text on a screen. So `slopdesk-termrender` owns the bytes and the packing, and
//! `slopdesk-apple-metal` does exactly one thing with an [`Atlas`]: uploads [`Atlas::dirty`] into a
//! `MTLTexture` and clears it. That split is also what `docs/57` §2 asks for — the `apple-*` family
//! holds the framework call and nothing else.
//!
//! ## Why shelves
//!
//! Glyphs from one font at one size are almost the same height, which is the case shelf packing is
//! best at and the case a general rectangle packer pays for without using. A shelf is a horizontal
//! band fixed at the height of the first glyph put on it; a new glyph joins the shortest shelf that
//! can hold it without wasting more than [`SHELF_SLACK`] of its height, and opens a new band
//! otherwise. The result for a monospace face is near-perfect rows, and the code is short enough to
//! be read for correctness rather than trusted.
//!
//! ## Growth invalidates, deliberately
//!
//! [`Atlas::grow`] does not re-pack. It doubles the texture, throws every region away and bumps
//! [`Atlas::generation`], and the caller re-rasterises what it still needs. Re-packing into a
//! larger texture would preserve regions at the cost of a second packing pass whose bugs would be
//! invisible — and growth happens a handful of times in a session, against a rasteriser that costs
//! microseconds. The cheap-and-obviously-correct branch wins a contest that is not close.

/// How much of a shelf's height a glyph may leave unused and still join it.
///
/// A glyph that is much shorter than the shelf wastes the difference for as long as the atlas
/// lives. Half is the ordinary tuning: it keeps ascender-height and x-height glyphs together on a
/// monospace face while sending a comma to its own band rather than to a band sized for `Ř`.
const SHELF_SLACK: u32 = 2;

/// The smallest atlas ever allocated, in texels per side.
pub const MIN_ATLAS_SIZE: u32 = 512;

/// The largest atlas ever allocated, in texels per side.
///
/// Every Metal feature set slopdesk can run on guarantees 8192, so this is not a hardware limit —
/// it is a budget. At 4096 an alpha atlas is 16 MiB and a colour one 64 MiB, and a session that
/// fills either has a font-fallback bug rather than a lot of glyphs.
pub const MAX_ATLAS_SIZE: u32 = 4096;

/// What one texel holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AtlasFormat {
    /// One byte of coverage. Text, and every glyph that takes the foreground colour.
    Alpha8,
    /// Four bytes, blue-green-red-alpha, premultiplied. Colour emoji, which carry their own colour
    /// and ignore the cell's foreground entirely.
    Bgra8,
}

impl AtlasFormat {
    /// Bytes per texel.
    #[must_use]
    pub const fn bytes_per_texel(self) -> u32 {
        match self {
            Self::Alpha8 => 1,
            Self::Bgra8 => 4,
        }
    }
}

/// A rectangle of texels inside an atlas, top-left origin.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AtlasRegion {
    /// Left edge, in texels.
    pub x: u32,
    /// Top edge, in texels.
    pub y: u32,
    /// Width in texels. Zero for a glyph that rasterised to nothing, such as a space.
    pub width: u32,
    /// Height in texels.
    pub height: u32,
}

impl AtlasRegion {
    /// Whether the region covers no texels, which is how a blank glyph is cached.
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.width == 0 || self.height == 0
    }

    /// The region's texture coordinates as `[u0, v0, u1, v1]` in `0.0..=1.0`.
    ///
    /// `size` is the atlas side the region was allocated against. Passing a different one is a
    /// caller bug that shows up as misplaced glyphs, which is why every read of this goes through
    /// [`Atlas::uv`] rather than being computed at a call site.
    #[must_use]
    pub fn uv(self, size: u32) -> [f32; 4] {
        if size == 0 {
            return [0.0; 4];
        }
        let extent = f64::from(size);
        let u0 = f64::from(self.x) / extent;
        let v0 = f64::from(self.y) / extent;
        let u1 = f64::from(self.x + self.width) / extent;
        let v1 = f64::from(self.y + self.height) / extent;
        [narrow(u0), narrow(v0), narrow(u1), narrow(v1)]
    }

    /// Whether this region and `other` share a texel — the invariant a packer must never break.
    #[must_use]
    pub const fn intersects(self, other: Self) -> bool {
        self.x < other.x + other.width
            && other.x < self.x + self.width
            && self.y < other.y + other.height
            && other.y < self.y + self.height
    }

    /// The smallest region covering both.
    #[must_use]
    const fn union(self, other: Self) -> Self {
        if self.is_empty() {
            return other;
        }
        if other.is_empty() {
            return self;
        }
        let x = if self.x < other.x { self.x } else { other.x };
        let y = if self.y < other.y { self.y } else { other.y };
        let right = {
            let (a, b) = (self.x + self.width, other.x + other.width);
            if a > b { a } else { b }
        };
        let bottom = {
            let (a, b) = (self.y + self.height, other.y + other.height);
            if a > b { a } else { b }
        };
        Self {
            x,
            y,
            width: right - x,
            height: bottom - y,
        }
    }
}

/// Texture coordinates are `f32` because that is what a vertex buffer holds; the arithmetic above
/// is `f64` so the division is exact enough that adjacent glyphs cannot round onto each other.
#[expect(
    clippy::cast_possible_truncation,
    reason = "a UV is a 0..=1 ratio; f32 carries it with room to spare, and the buffer is f32"
)]
const fn narrow(value: f64) -> f32 {
    value as f32
}

/// One horizontal band of the atlas, fixed at the height of the first glyph placed on it.
#[derive(Debug, Clone, Copy)]
struct Shelf {
    top: u32,
    height: u32,
    next_x: u32,
}

/// A square texture, its packing state, and its bytes.
#[derive(Debug, Clone)]
pub struct Atlas {
    size: u32,
    format: AtlasFormat,
    shelves: Vec<Shelf>,
    next_shelf_top: u32,
    generation: u32,
    pixels: Vec<u8>,
    dirty: AtlasRegion,
}

impl Atlas {
    /// An empty atlas of `size` texels per side, clamped into
    /// <code>[MIN_ATLAS_SIZE]..=[MAX_ATLAS_SIZE]</code>.
    ///
    /// Allocated in full up front rather than grown lazily: the texture on the GPU side is a fixed
    /// allocation anyway, and a CPU buffer that disagrees with it about size is a class of bug this
    /// crate should not be able to express.
    #[must_use]
    pub fn new(size: u32, format: AtlasFormat) -> Self {
        let size = size.clamp(MIN_ATLAS_SIZE, MAX_ATLAS_SIZE);
        let bytes = (size as usize) * (size as usize) * (format.bytes_per_texel() as usize);
        Self {
            size,
            format,
            shelves: Vec::new(),
            next_shelf_top: 0,
            generation: 0,
            pixels: vec![0; bytes],
            dirty: AtlasRegion::default(),
        }
    }

    /// The texture side, in texels.
    #[must_use]
    pub const fn size(&self) -> u32 {
        self.size
    }

    /// What one texel holds.
    #[must_use]
    pub const fn format(&self) -> AtlasFormat {
        self.format
    }

    /// The whole CPU-side texture, row-major, top-left origin.
    #[must_use]
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    /// Bumped by every [`Atlas::grow`] and [`Atlas::reset`].
    ///
    /// A cached region is only meaningful against the generation it was allocated in. Anything
    /// holding one compares this first; that is the entire invalidation protocol.
    #[must_use]
    pub const fn generation(&self) -> u32 {
        self.generation
    }

    /// The region written since the last [`Atlas::take_dirty`], or an empty region.
    #[must_use]
    pub const fn dirty(&self) -> AtlasRegion {
        self.dirty
    }

    /// Answers [`Atlas::dirty`] and clears it — what an uploader calls once per frame.
    pub const fn take_dirty(&mut self) -> AtlasRegion {
        let region = self.dirty;
        self.dirty = AtlasRegion {
            x: 0,
            y: 0,
            width: 0,
            height: 0,
        };
        region
    }

    /// Reserves `width × height` texels, or `None` when the atlas is full.
    ///
    /// A zero-area request succeeds with an empty region and consumes nothing: a space has no
    /// coverage but still wants a cache entry, so that looking it up is a hit rather than a
    /// rasterisation every frame.
    pub fn alloc(&mut self, width: u32, height: u32) -> Option<AtlasRegion> {
        if width == 0 || height == 0 {
            return Some(AtlasRegion::default());
        }
        if width > self.size || height > self.size {
            return None;
        }

        // The shortest shelf that fits, so a small glyph does not claim a tall band while a short
        // one is still open. `SHELF_SLACK` is what stops a comma from being filed under `Ř`.
        let mut best: Option<usize> = None;
        for (index, shelf) in self.shelves.iter().enumerate() {
            if shelf.height < height || shelf.height > height.saturating_mul(SHELF_SLACK) {
                continue;
            }
            if self.size - shelf.next_x < width {
                continue;
            }
            let better = best
                .and_then(|held| self.shelves.get(held))
                .is_none_or(|held| shelf.height < held.height);
            if better {
                best = Some(index);
            }
        }

        if let Some(index) = best
            && let Some(shelf) = self.shelves.get_mut(index)
        {
            let region = AtlasRegion {
                x: shelf.next_x,
                y: shelf.top,
                width,
                height,
            };
            shelf.next_x += width;
            return Some(region);
        }

        if self.size - self.next_shelf_top < height {
            return None;
        }
        let region = AtlasRegion {
            x: 0,
            y: self.next_shelf_top,
            width,
            height,
        };
        self.shelves.push(Shelf {
            top: self.next_shelf_top,
            height,
            next_x: width,
        });
        self.next_shelf_top += height;
        Some(region)
    }

    /// Copies `src` into `region`, row by row.
    ///
    /// `src` is tightly packed at this atlas's format — `region.width * bytes_per_texel` per row,
    /// `region.height` rows. A short or over-long buffer is refused rather than clipped: a caller
    /// that miscomputed its stride would otherwise write a glyph that looks almost right, and
    /// almost-right is the failure mode that survives review. `false` means nothing was written.
    pub fn write(&mut self, region: AtlasRegion, src: &[u8]) -> bool {
        if region.is_empty() {
            return true;
        }
        let bpt = self.format.bytes_per_texel() as usize;
        let row_bytes = (region.width as usize) * bpt;
        if src.len() != row_bytes * (region.height as usize) {
            return false;
        }
        if region.x + region.width > self.size || region.y + region.height > self.size {
            return false;
        }

        let stride = (self.size as usize) * bpt;
        for row in 0..(region.height as usize) {
            let dst_start = (region.y as usize + row) * stride + (region.x as usize) * bpt;
            let src_start = row * row_bytes;
            let (Some(dst), Some(src_row)) = (
                self.pixels.get_mut(dst_start..dst_start + row_bytes),
                src.get(src_start..src_start + row_bytes),
            ) else {
                return false;
            };
            dst.copy_from_slice(src_row);
        }
        self.dirty = self.dirty.union(region);
        true
    }

    /// Doubles the texture and throws every region away, or `false` at [`MAX_ATLAS_SIZE`].
    ///
    /// The caller must treat every [`AtlasRegion`] it holds as dead — see the module header for why
    /// this does not re-pack.
    pub fn grow(&mut self) -> bool {
        if self.size >= MAX_ATLAS_SIZE {
            return false;
        }
        let size = (self.size * 2).min(MAX_ATLAS_SIZE);
        *self = Self {
            generation: self.generation.wrapping_add(1),
            ..Self::new(size, self.format)
        };
        true
    }

    /// Empties the atlas at its current size, bumping the generation.
    pub fn reset(&mut self) {
        let generation = self.generation.wrapping_add(1);
        *self = Self {
            generation,
            ..Self::new(self.size, self.format)
        };
    }

    /// [`AtlasRegion::uv`] against this atlas's own side, which is the only correct one.
    #[must_use]
    pub fn uv(&self, region: AtlasRegion) -> [f32; 4] {
        region.uv(self.size)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Atlas, AtlasFormat, AtlasRegion, MAX_ATLAS_SIZE, MIN_ATLAS_SIZE};

    #[test]
    fn a_row_of_same_height_glyphs_shares_one_shelf() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        let first = atlas.alloc(10, 20).unwrap();
        let second = atlas.alloc(10, 20).unwrap();
        let third = atlas.alloc(10, 20).unwrap();

        assert_eq!(first.y, second.y);
        assert_eq!(second.y, third.y);
        assert_eq!(first.x, 0);
        assert_eq!(second.x, 10);
        assert_eq!(third.x, 20);
    }

    #[test]
    fn a_much_shorter_glyph_opens_its_own_shelf() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        let tall = atlas.alloc(10, 40).unwrap();
        let short = atlas.alloc(10, 4).unwrap();

        assert_ne!(tall.y, short.y, "4 texels on a 40-texel shelf wastes 90% of it");
        assert!(!tall.intersects(short));
    }

    #[test]
    fn regions_never_overlap_across_a_full_pack() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        let mut placed = Vec::new();
        // Cycle the heights so several shelves are open at once — the case a single-shelf packer
        // gets right by accident.
        for step in 0..600_u32 {
            let height = 8 + (step % 5) * 7;
            let Some(region) = atlas.alloc(9 + step % 3, height) else {
                break;
            };
            placed.push(region);
        }
        assert!(placed.len() > 100, "the pack ended too early to prove anything");
        for (index, region) in placed.iter().enumerate() {
            for other in &placed[index + 1..] {
                assert!(!region.intersects(*other), "{region:?} overlaps {other:?}");
            }
        }
    }

    #[test]
    fn a_glyph_larger_than_the_atlas_is_refused_rather_than_clipped() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        assert_eq!(atlas.alloc(MIN_ATLAS_SIZE + 1, 10), None);
    }

    #[test]
    fn a_blank_glyph_allocates_nothing_and_still_succeeds() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        let region = atlas.alloc(0, 18).unwrap();
        assert!(region.is_empty());
        // The next real glyph still lands at the origin, so the space consumed no shelf.
        assert_eq!(atlas.alloc(10, 18).unwrap(), AtlasRegion {
            x: 0,
            y: 0,
            width: 10,
            height: 18
        });
    }

    #[test]
    fn a_write_lands_where_the_region_says() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        let region = atlas.alloc(2, 2).unwrap();
        let region = AtlasRegion { x: 3, y: 4, ..region };
        assert!(atlas.write(region, &[1, 2, 3, 4]));

        let stride = MIN_ATLAS_SIZE as usize;
        assert_eq!(atlas.pixels()[4 * stride + 3], 1);
        assert_eq!(atlas.pixels()[4 * stride + 4], 2);
        assert_eq!(atlas.pixels()[5 * stride + 3], 3);
        assert_eq!(atlas.pixels()[5 * stride + 4], 4);
    }

    #[test]
    fn a_write_with_the_wrong_stride_is_refused() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Bgra8);
        let region = atlas.alloc(2, 2).unwrap();
        assert!(
            !atlas.write(region, &[0; 8]),
            "8 bytes is the alpha stride, not the bgra one"
        );
        assert!(atlas.write(region, &[0; 16]));
    }

    #[test]
    fn the_dirty_region_covers_every_write_and_then_clears() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        assert!(atlas.write(
            AtlasRegion {
                x: 0,
                y: 0,
                width: 1,
                height: 1
            },
            &[7]
        ));
        assert!(atlas.write(
            AtlasRegion {
                x: 9,
                y: 5,
                width: 1,
                height: 1
            },
            &[7]
        ));

        assert_eq!(atlas.dirty(), AtlasRegion {
            x: 0,
            y: 0,
            width: 10,
            height: 6
        });
        assert_eq!(atlas.take_dirty(), AtlasRegion {
            x: 0,
            y: 0,
            width: 10,
            height: 6
        });
        assert!(atlas.dirty().is_empty());
    }

    #[test]
    fn growth_doubles_bumps_the_generation_and_empties() {
        let mut atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        let before = atlas.alloc(10, 20).unwrap();
        let generation = atlas.generation();

        assert!(atlas.grow());
        assert_eq!(atlas.size(), MIN_ATLAS_SIZE * 2);
        assert_ne!(atlas.generation(), generation);
        // The first allocation after a grow starts over at the origin — every old region is dead.
        assert_eq!(atlas.alloc(10, 20).unwrap(), before);
    }

    #[test]
    fn growth_stops_at_the_ceiling() {
        let mut atlas = Atlas::new(MAX_ATLAS_SIZE, AtlasFormat::Alpha8);
        assert!(!atlas.grow());
        assert_eq!(atlas.size(), MAX_ATLAS_SIZE);
    }

    #[test]
    fn uv_maps_the_region_onto_the_unit_square() {
        let atlas = Atlas::new(MIN_ATLAS_SIZE, AtlasFormat::Alpha8);
        let uv = atlas.uv(AtlasRegion {
            x: 0,
            y: 0,
            width: MIN_ATLAS_SIZE,
            height: 256,
        });
        for (had, want) in uv.into_iter().zip([0.0_f32, 0.0, 1.0, 0.5]) {
            assert!((had - want).abs() < f32::EPSILON, "{uv:?}");
        }
    }
}
