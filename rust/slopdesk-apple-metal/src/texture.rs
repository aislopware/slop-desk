//! One CPU atlas, mirrored into one `MTLTexture`.
//!
//! ## Patch, or throw away — and getting it wrong is a screen of garbage
//!
//! [`slopdesk_termrender::Atlas`] is a shelf packer that hands out a UV per glyph, and it carries a
//! GENERATION beside its pixels for exactly one reason: `grow` and `reset` both throw every packed
//! region away, so every UV the cache issues afterwards points somewhere else in a differently
//! arranged picture. Patching a stale texture with the new dirty rect would upload the handful of
//! texels that changed and leave the rest of the texture holding the PREVIOUS arrangement — a
//! screen where every glyph is some other glyph, drawn correctly.
//!
//! So the rule is: the generation, not the size, decides. `grow` doubles and bumps; `reset` keeps
//! the size and bumps. [`crate::geom::TextureKey::can_patch`] is that rule as a pure function, and
//! `geom.rs`'s tests are where it is checked — a device-backed test could never tell the two cases
//! apart without a readback this crate has deliberately given up (`framebufferOnly`).
//!
//! ## Two formats, one module
//!
//! `Alpha8` is text: one coverage byte per texel, from a rasteriser that drew into an 8-bit
//! context. `Bgra8` is emoji: four premultiplied bytes. They are the same code path with a
//! different pixel format and a different `bytes_per_texel`, which is why there is one type here
//! and two instances of it rather than two types.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::{
    MTLDevice, MTLOrigin, MTLPixelFormat, MTLRegion, MTLSize, MTLStorageMode, MTLTexture,
    MTLTextureDescriptor, MTLTextureUsage,
};
use slopdesk_termrender::{Atlas, AtlasFormat};

use crate::error::MetalError;
use crate::geom::{TextureKey, Upload};

/// The texture standing in for one atlas, and the key that says whether it still may.
#[derive(Debug)]
pub(crate) struct AtlasTexture {
    texture: Option<Retained<ProtocolObject<dyn MTLTexture>>>,
    key: TextureKey,
}

impl AtlasTexture {
    /// An empty mirror. Nothing is allocated until the first [`AtlasTexture::sync`].
    ///
    /// Lazy on purpose: a pane that opens and closes without ever drawing text — a split being
    /// dragged, a tab created and abandoned — should not have cost 512 KiB of device memory for a
    /// picture nothing sampled.
    #[must_use]
    pub(crate) const fn new() -> Self {
        Self {
            texture: None,
            key: TextureKey {
                size: 0,
                generation: 0,
            },
        }
    }

    /// Brings the texture level with `atlas`, recreating it if the generation moved.
    ///
    /// Takes the atlas MUTABLY because [`slopdesk_termrender::Atlas::take_dirty`] is what clears
    /// the pending region, and clearing it is part of having uploaded it. A `&Atlas` version
    /// would upload the same rect every frame forever.
    pub(crate) fn sync(
        &mut self,
        device: &ProtocolObject<dyn MTLDevice>,
        atlas: &mut Atlas,
    ) -> Result<(), MetalError> {
        let wanted = TextureKey {
            size: atlas.size(),
            generation: atlas.generation(),
        };
        let format = atlas.format();
        let texels = format.bytes_per_texel();

        let plan = if self.texture.is_some() && self.key.can_patch(wanted) {
            Upload::plan(atlas.take_dirty(), wanted.size, texels)
        } else {
            self.texture = Some(allocate(device, format, wanted.size)?);
            self.key = wanted;
            // The dirty rect is consumed rather than read: a brand-new texture is entirely stale,
            // so the whole atlas goes up and whatever subset was pending is a subset of
            // that. Leaving it set would make the NEXT frame re-upload a region that is
            // already correct.
            let _consumed = atlas.take_dirty();
            Upload::whole(wanted.size, texels)
        };

        let (Some(plan), Some(texture)) = (plan, self.texture.as_ref()) else {
            // No plan is the ordinary steady state — most frames add no glyph — and there is
            // nothing to do about it.
            return Ok(());
        };

        // A SAFE subslice, and it is the whole reason this upload spends no raw-pointer budget.
        // `Upload::plan` computed the exact half-open range Metal will read (see its doc comment
        // for why the end is the last row's right edge rather than the last row's end), and
        // `get` is what turns "I computed it correctly" into "the compiler checked it". A
        // `None` here would mean `geom.rs` and `atlas.rs` disagree about how big `pixels()`
        // is, which is a bug rather than a condition — hence the error rather than a silent
        // skip.
        let bytes = atlas
            .pixels()
            .get(plan.offset..plan.end)
            .ok_or(MetalError::Allocation)?;

        let region = MTLRegion {
            origin: MTLOrigin {
                x: plan.origin_x as usize,
                y: plan.origin_y as usize,
                z: 0,
            },
            size: MTLSize {
                width: plan.width as usize,
                height: plan.height as usize,
                depth: 1,
            },
        };

        // # Safety
        //
        // `replaceRegion:mipmapLevel:withBytes:bytesPerRow:` is Metal's own contract, and it has
        // three terms. (1) The region must lie inside the texture at that mip level: `Upload::plan`
        // rejected any region that leaves the `size × size` atlas, and the texture was allocated at
        // that same `size` four lines up or is keyed to it. (2) The framework reads `height` rows
        // of `width × bytes_per_texel` bytes, `bytes_per_row` apart, starting at the
        // pointer — the subslice above is exactly that extent, taken safely. (3) The
        // texture's storage mode must allow a CPU write, which `allocate` guarantees by
        // asking for `Shared`.
        //
        // Level 0 because this crate creates no mipmaps: a glyph atlas is sampled at exactly its
        // own scale (`shaders.metal` uses a `nearest` sampler for the same reason), so a
        // mip chain would be memory spent on levels nothing can ever select.
        #[expect(
            unsafe_code,
            reason = "replaceRegion: takes the texels as a bare pointer; the region and the byte extent are \
                      both checked above"
        )]
        unsafe {
            texture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(
                region,
                0,
                NonNull::from(bytes).cast::<c_void>(),
                plan.bytes_per_row,
            );
        }

        Ok(())
    }

    /// The texture, if one has been made.
    #[must_use]
    pub(crate) fn texture(&self) -> Option<&ProtocolObject<dyn MTLTexture>> {
        self.texture.as_deref()
    }
}

impl Default for AtlasTexture {
    fn default() -> Self {
        Self::new()
    }
}

/// One square, single-level, shader-readable texture.
fn allocate(
    device: &ProtocolObject<dyn MTLDevice>,
    format: AtlasFormat,
    size: u32,
) -> Result<Retained<ProtocolObject<dyn MTLTexture>>, MetalError> {
    let descriptor = MTLTextureDescriptor::new();

    // `A8Unorm` for coverage and `BGRA8Unorm` for colour, which is `atlas.rs`'s own vocabulary read
    // straight across. `A8Unorm` puts the single byte in `.a`, so `shaders.metal` would have to
    // sample `.a`; `R8Unorm` puts it in `.r`, which is what the shader reads and what every other
    // single-channel Metal texture in the world uses. The shader samples `.r`, so this is `R8Unorm`
    // — a rename of the same eight bits, not a conversion.
    let (pixel_format, storage) = match format {
        AtlasFormat::Alpha8 => (MTLPixelFormat::R8Unorm, MTLStorageMode::Shared),
        AtlasFormat::Bgra8 => (MTLPixelFormat::BGRA8Unorm, MTLStorageMode::Shared),
    };
    descriptor.setPixelFormat(pixel_format);

    // `Shared`, so `replaceRegion:` writes into memory the GPU already sees and there is nothing to
    // flush afterwards. On the Apple Silicon this repo ships for, that is simply the truth about
    // the machine — there is one pool. `Managed` would keep a second copy and make every dirty
    // rect a blit; `Private` cannot be written from the CPU at all, which is what an atlas
    // upload IS.
    //
    // Worth stating because the buffer side is different and the difference is a classic bug: a
    // MANAGED buffer needs `didModifyRange:` after a CPU write and a SHARED one does not. Both of
    // this crate's writable resources are `Shared`, so that call appears nowhere and its absence is
    // correct rather than forgotten.
    descriptor.setStorageMode(storage);
    descriptor.setUsage(MTLTextureUsage::ShaderRead);

    // # Safety
    //
    // `setWidth:`/`setHeight:` are generated `unsafe` because `MTLTextureDescriptor` accepts any
    // `NSUInteger` and only validates at `newTextureWithDescriptor:` time. Metal's rule is that
    // both must be within the device's maximum 2D texture dimension; `atlas.rs` caps its side
    // at 4096 and records that "every Metal feature set slopdesk can run on guarantees 8192",
    // so the value that arrives here is inside the guarantee by construction. A descriptor that
    // somehow was not is a `None` from the allocation below, not a fault.
    #[expect(
        unsafe_code,
        reason = "the descriptor setters are unchecked until allocation; atlas.rs caps the size at 4096 \
                  against a guaranteed 8192"
    )]
    unsafe {
        descriptor.setWidth(size as usize);
        descriptor.setHeight(size as usize);
    }

    device
        .newTextureWithDescriptor(&descriptor)
        .ok_or(MetalError::Allocation)
}
