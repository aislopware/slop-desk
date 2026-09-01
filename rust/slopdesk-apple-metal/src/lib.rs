//! Metal, and the `CAMetalLayer` that presents it — the GPU half of the terminal surface.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything, and `docs/68` §10.1 for
//! why this crate exists at all. It owns the device, the command queue, the layer, the shader
//! library, the three pipeline states, the instance buffers, the two atlas textures and one texture
//! per inline image. It takes a [`slopdesk_termrender::DrawList`], a
//! [`slopdesk_termrender::GlyphCache`] and a [`slopdesk_termrender::ImageStore`], and draws one
//! frame.
//!
//! ## It decides nothing
//!
//! Identical to the charter every crate in this family carries, and unusually easy to check here
//! because the whole input is three values. WHERE a cell background goes, WHICH atlas a glyph came
//! from, whether a cursor is a fill or an outline, how thick an underline is, what colour anything
//! is, which z band an image belongs in and where it is cropped — every one of those is
//! `slopdesk-termrender`, which is `forbid(unsafe_code)` and runs its tests with no display
//! attached. This crate reads four `Vec`s in the order they were stored, issues the draw calls they
//! describe, and presents.
//!
//! What IS decided here is the framework's own vocabulary, and it is decided in comments at the
//! sites: the drawable's pixel format, the drawable queue depth, vsync, the blend factors, the
//! storage modes, the sampler's filter, and how deep the CPU may run ahead of the GPU. Each of
//! those is argued where it is set, because `docs/68` §6 makes macOS the veto platform and a
//! default taken silently is a default nobody can review.
//!
//! ## The shape of one frame
//!
//! ``text
//!   atlas dirty rects  ->  replaceRegion: into two MTLTextures   (no slot, no command buffer)
//!   stale images       ->  one MTLTexture each, whole            (same, and keyed on a revision)
//!   acquire a ring slot -> memcpy four instance slices           (the semaphore is the fence)
//!   nextDrawable       ->  one render pass, clear to background
//!     images       (image pipeline, z <  i32::MIN/2)
//!     backgrounds  (rect pipeline)
//!     images       (image pipeline, i32::MIN/2 <= z < 0)
//!     glyphs       (glyph pipeline, both atlases bound)
//!     images       (image pipeline, z >= 0)
//!     overlays     (rect pipeline)
//!   presentDrawable, commit, release the slot on completion
//! ``
//!
//! ## Where the `unsafe` is
//!
//! Thirteen sites, every one a CALL into a binding `objc2` generated `unsafe`, except one. Most of
//! Metal turns out to be safe: the device, the queue, the library, the pipeline states, the
//! textures, the render pass and the command buffer all cost nothing, and so does every
//! `CAMetalLayer` property in `surface.rs`. What is left `unsafe` upstream is the family whose C
//! signature carries a bare pointer or an unchecked slot index.
//!
//! The exception is `frames.rs`'s write through `MTLBuffer::contents()`, which is a raw-pointer
//! write rather than a call and therefore a live tension with `docs/57` §2's ban. That module's
//! header runs §2's own three-route test on it and states plainly what this crate may not do about
//! it. Read it before touching the instance ring.

#![cfg_attr(
    not(any(target_os = "macos", target_os = "ios")),
    allow(unused_crate_dependencies)
)]

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod error;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod frames;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod geom;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod images;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod pipeline;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod renderer;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod surface;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod texture;

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use error::MetalError;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use renderer::Renderer;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use surface::{DRAWABLE_FORMAT, Surface};
