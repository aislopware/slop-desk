//! One `MTLTexture` per inline image, mirrored from [`slopdesk_termrender::ImageStore`].
//!
//! ## The same split as `texture.rs`, one level up
//!
//! `texture.rs` mirrors ONE atlas whose contents the renderer packs. This mirrors N images a
//! program transmitted, and the difference that matters is the lifetime: an atlas lives as long as
//! the pane, an image lives as long as something on screen places it. So this map is driven
//! ENTIRELY by the store — every id the store holds gets a texture, every id it has dropped loses
//! one — and the eviction policy is `image.rs`'s, not this module's. Nothing here decides anything,
//! which is the crate's charter and is why the rule is one line of `retain`.
//!
//! ## Keyed on the store's REVISION, not on the engine's generation
//!
//! [`slopdesk_termrender::StoredImage`] carries both, and its own doc comment says why this one:
//! the revision is bumped by the thing that replaces the pixels, so a texture keyed on it cannot
//! survive a replacement. The engine's generation is the store's input, not the store's state, and
//! a mirror keyed on an input is a mirror that goes stale the first time the two stop agreeing.
//!
//! ## `RGBA8Unorm`, and the premultiply is in the shader
//!
//! `slopdesk-vterm` hands over STRAIGHT-alpha RGBA — its `ImagePixels` says so — while the
//! pipelines blend `One / OneMinusSourceAlpha`. Something has to multiply, and `image_fragment` in
//! `shaders.metal` is where, for the same reason `rect_fragment` and the coverage half of
//! `glyph_fragment` do it there: a CPU premultiply would be a pass over every byte of every image
//! on upload, it would make the store's pixels a different thing from the engine's, and it would
//! put a second alpha convention in a crate that already documents one. The shader multiply is one
//! instruction on fragments that are already being shaded.
//!
//! The format is `RGBA8Unorm` and not the `BGRA8Unorm` `texture.rs` uses, because the byte order is
//! the engine's rather than the window server's: `graphics.rs` widens every kitty format to R, G,
//! B, A in that order. Naming the format after the bytes is what keeps the shader free of a
//! swizzle.

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
use std::collections::HashMap;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::{
    MTLDevice, MTLOrigin, MTLPixelFormat, MTLRegion, MTLSize, MTLStorageMode, MTLTexture,
    MTLTextureDescriptor, MTLTextureUsage,
};
use slopdesk_termrender::{ImageStore, StoredImage};

use crate::error::MetalError;

/// Bytes per texel of `RGBA8Unorm`.
const RGBA_BYTES: usize = 4;

/// One image's texture and the revision it was filled from.
#[derive(Debug)]
struct Held {
    texture: Retained<ProtocolObject<dyn MTLTexture>>,
    revision: u64,
}

/// Every transmitted image, as textures.
#[derive(Debug, Default)]
pub(crate) struct ImageTextures {
    held: HashMap<u32, Held>,
}

impl ImageTextures {
    /// An empty mirror.
    #[must_use]
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Brings every texture level with `store`, and forgets the images it has dropped.
    ///
    /// The drop is FIRST so a session that scrolls past a large image releases its device memory in
    /// the same frame the store released its bytes, rather than one frame later.
    ///
    /// # Errors
    ///
    /// [`MetalError::Allocation`] if the device refuses a texture. A frame is worth skipping over
    /// that; the next one retries with the same store.
    pub(crate) fn sync(
        &mut self,
        device: &ProtocolObject<dyn MTLDevice>,
        store: &ImageStore,
    ) -> Result<(), MetalError> {
        self.held.retain(|id, _| store.get(*id).is_some());
        for image in store.iter() {
            if self
                .held
                .get(&image.meta.id)
                .is_some_and(|held| held.revision == image.revision)
            {
                continue;
            }
            let texture = upload(device, image)?;
            self.held.insert(image.meta.id, Held {
                texture,
                revision: image.revision,
            });
        }
        Ok(())
    }

    /// One image's texture, if it has been uploaded.
    #[must_use]
    pub(crate) fn texture(&self, id: u32) -> Option<&ProtocolObject<dyn MTLTexture>> {
        self.held.get(&id).map(|held| &*held.texture)
    }

    /// How many textures are held. Tests and nothing else.
    #[cfg(test)]
    #[must_use]
    pub(crate) fn len(&self) -> usize {
        self.held.len()
    }
}

/// Allocates a texture for `image` and fills it in one go.
///
/// Allocate-and-replace rather than patch, unlike `texture.rs`: an atlas changes by a rect and an
/// image changes by being retransmitted whole, so there is no dirty region to plan and a new
/// texture is what a new revision means.
fn upload(
    device: &ProtocolObject<dyn MTLDevice>,
    image: &StoredImage,
) -> Result<Retained<ProtocolObject<dyn MTLTexture>>, MetalError> {
    let (width, height) = (image.meta.width as usize, image.meta.height as usize);
    let bytes_per_row = width.checked_mul(RGBA_BYTES).ok_or(MetalError::Allocation)?;
    let needed = bytes_per_row.checked_mul(height).ok_or(MetalError::Allocation)?;

    // The safe subslice that makes the `replaceRegion:` extent below a checked fact rather than a
    // claim, exactly as `texture.rs` does it. A short buffer here would mean `graphics.rs` and this
    // module disagree about what `width × height × 4` means, which is a bug and not a condition.
    let pixels = image.rgba.get(..needed).ok_or(MetalError::Allocation)?;

    let descriptor = MTLTextureDescriptor::new();
    descriptor.setPixelFormat(MTLPixelFormat::RGBA8Unorm);
    descriptor.setStorageMode(MTLStorageMode::Shared);
    descriptor.setUsage(MTLTextureUsage::ShaderRead);

    // # Safety
    //
    // The same rule `texture.rs` names: `setWidth:`/`setHeight:` accept any `NSUInteger` and Metal
    // validates only at `newTextureWithDescriptor:` time, where an oversized dimension answers
    // `None` rather than faulting. The bound that matters is the device's maximum 2D dimension, and
    // an image past it is a `None` on the next line and a skipped image — not a crash. Unlike the
    // atlas, this size comes from the FAR SIDE of a pty, so there is no upstream cap to lean on and
    // the `None` is the whole check.
    #[expect(
        unsafe_code,
        reason = "the descriptor setters are unchecked until allocation, which answers None for a size the \
                  device refuses"
    )]
    unsafe {
        descriptor.setWidth(width);
        descriptor.setHeight(height);
    }

    let texture = device
        .newTextureWithDescriptor(&descriptor)
        .ok_or(MetalError::Allocation)?;

    let region = MTLRegion {
        origin: MTLOrigin { x: 0, y: 0, z: 0 },
        size: MTLSize {
            width,
            height,
            depth: 1,
        },
    };

    // # Safety
    //
    // `replaceRegion:mipmapLevel:withBytes:bytesPerRow:`'s three terms, the same three `texture.rs`
    // discharges. (1) The region is the whole texture at the size just allocated. (2) The framework
    // reads `height` rows of `bytes_per_row` bytes from the pointer, and `pixels` is a subslice of
    // exactly `bytes_per_row × height` taken safely above. (3) `Shared` storage permits the CPU
    // write, asked for four lines up.
    //
    // Level 0 because no mip chain is created. Unlike a glyph, an image IS scaled — a program picks
    // its own pixel size and the placement's cell box may not match — so `image_fragment` samples
    // `linear`; mipmaps would only help minification past 2×, and would cost a generate pass per
    // transmission to do it.
    #[expect(
        unsafe_code,
        reason = "replaceRegion: takes the texels as a bare pointer; the region and the byte extent are \
                  both checked above"
    )]
    unsafe {
        texture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(
            region,
            0,
            NonNull::from(pixels).cast::<c_void>(),
            bytes_per_row,
        );
    }

    Ok(texture)
}

#[cfg(test)]
mod tests {
    use slopdesk_termrender::{ImageMeta, ImagePixels, ImageStore, StoredImage};

    use super::{ImageTextures, RGBA_BYTES};

    fn pixels(id: u32, generation: u64) -> ImagePixels {
        let meta = ImageMeta {
            id,
            generation,
            width: 2,
            height: 2,
        };
        ImagePixels {
            rgba: vec![0; meta.rgba_len()],
            meta,
        }
    }

    #[test]
    fn a_texel_is_four_bytes_because_the_engine_widens_to_rgba() {
        // `graphics.rs` widens every kitty format — gray, gray+alpha, rgb — to four channels before
        // anything downstream sees it, so this is the one texel size this module ever uploads.
        assert_eq!(RGBA_BYTES, 4);
        assert_eq!(pixels(1, 1).rgba.len(), 2 * 2 * RGBA_BYTES);
    }

    #[test]
    fn a_fresh_mirror_holds_nothing_and_answers_nothing() {
        // Every other property of this module needs a device. This one does not, and it is the one
        // that guards the render path: `encode_images` skips a run whose texture is missing rather
        // than binding `None`, and that is only correct if a miss really answers `None`.
        let textures = ImageTextures::new();
        assert_eq!(textures.len(), 0);
        assert!(textures.texture(1).is_none());
    }

    #[test]
    fn the_stale_check_is_the_revision_and_the_store_owns_it() {
        // `sync` needs a device, but the predicate it branches on does not — so the predicate is
        // what is tested. Re-inserting the SAME generation still bumps the revision, which is the
        // conservative direction: a redundant upload is a copy, a missed one is the wrong picture.
        let mut store = ImageStore::new();
        store.insert(pixels(1, 7));
        let first = store.get(1).map(|held: &StoredImage| held.revision);

        store.insert(pixels(1, 7));
        assert_ne!(store.get(1).map(|held| held.revision), first);
    }
}
