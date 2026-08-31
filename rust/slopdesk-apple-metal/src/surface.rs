//! The `CAMetalLayer`, and the eight properties that are the whole latency argument.
//!
//! `docs/68` §6 makes macOS the veto platform, so every one of these is set deliberately rather
//! than left at its default, and each is argued at its own line. A layer is the one object in this
//! crate whose defaults are actively wrong for a terminal: `CoreAnimation` tunes them for a game
//! that would rather queue three frames than miss one, and a remote-coding surface would rather
//! show the keystroke.
//!
//! ## The admission this module does NOT spend
//! `docs/68` §10.1 budgets this crate one `Retained::retain`, "on the layer Swift hands over". It
//! is unspent, and that is a design choice worth naming: the layer is CREATED here and handed OUT,
//! so `Retained` owns it from birth and no borrowed +0 pointer ever crosses. The `AppKit` face's
//! job shrinks to `view.layer = renderer.layer()`, which is `objc2`'s safe setter on the Swift side
//! of the FFI boundary. An unspent admission is cheaper to review than a spent one, and this one
//! buys nothing.

// A lint CONFLICT rather than a preference: `MAX_DRAWABLES` and `next_drawable` are the crate's
// internal vocabulary and no part of its API, so `pub(crate)` is the only accurate visibility — and
// this nursery lint asks for `pub` while rustc's `unreachable_pub`, denied by the manifest, refuses
// exactly that. Clippy's own documentation records the conflict; the stricter of the two wins.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_core_foundation::CGSize;
use objc2_metal::{MTLDevice, MTLPixelFormat};
use objc2_quartz_core::{CAMetalDrawable, CAMetalLayer};

use crate::error::MetalError;

/// The pixel format the whole pipeline agrees on.
///
/// `BGRA8Unorm` and NOT `BGRA8Unorm_sRGB`, which is the choice with consequences. The sRGB variant
/// makes the hardware linearise on write and re-encode on read, so blending happens in linear light
/// — physically correct, and wrong for text. A glyph's coverage came out of a rasteriser that
/// assumed the blend would happen in the display's own space, and linear blending thins every
/// antialiased stem enough to read as a different font weight. Every terminal on this platform
/// makes the same choice for the same reason.
///
/// `BGRA` rather than `RGBA` because it is the order the display pipeline composites in; the other
/// spelling costs a swizzle on the way to the screen for no gain.
pub const DRAWABLE_FORMAT: MTLPixelFormat = MTLPixelFormat::BGRA8Unorm;

/// How many drawables the layer may hold.
///
/// Two, not the default three, and this is the single most latency-relevant number in the crate.
/// Each queued drawable is one whole vblank between the frame being finished and the frame being
/// seen: at three the compositor may be showing what was drawn two refreshes ago, at two it is
/// showing the previous one. The cost of two is a stall when the producer is late — irrelevant
/// here, because a terminal frame is ten thousand instances and two draw calls, and the GPU is
/// never the thing that is late. `docs/68` §6.3's measured budget is the keystroke's; this is the
/// other end of the same path and it should not be spent on a queue.
pub(crate) const MAX_DRAWABLES: usize = 2;

/// The layer this crate draws into, configured.
///
/// A newtype rather than a bare `Retained<CAMetalLayer>` so the configuration cannot be
/// half-applied: there is one constructor, it sets everything, and the only thing a caller may
/// change afterwards is the size.
#[derive(Debug)]
pub struct Surface {
    layer: Retained<CAMetalLayer>,
}

impl Surface {
    /// Creates the layer and applies every property, on `device`.
    #[must_use]
    pub fn new(device: &ProtocolObject<dyn MTLDevice>) -> Self {
        let layer = CAMetalLayer::layer();

        layer.setDevice(Some(device));
        layer.setPixelFormat(DRAWABLE_FORMAT);

        // No readback, ever. This crate never samples a drawable, never blits one out and never
        // takes a screenshot through it — capture is `slopdesk-apple-sck`'s framework area. Saying
        // so lets the driver hand back a texture in whatever compressed layout the display likes,
        // which is free bandwidth on a surface that is mostly flat colour.
        layer.setFramebufferOnly(true);

        // A terminal has a background. Declaring the layer opaque lets the compositor skip blending
        // it against whatever is behind, which on a full-screen editor is the whole screen's worth
        // of per-pixel work saved. The render pass still clears to the theme's background
        // colour, so there is never an undefined pixel for the claim to be a lie about.
        layer.setOpaque(true);

        layer.setMaximumDrawableCount(MAX_DRAWABLES);

        // Vsync ON. The alternative trades tearing for a fraction of a frame, and a torn line of
        // text is legible-but-wrong in a way a torn game frame is not — the eye reads the seam as a
        // character. It also renders frames nobody will ever see, which on a laptop is battery
        // spent to make the fan the loudest thing about the editor. The frame of latency
        // this costs is real and it is the right trade: `docs/68` §6.3 measures the
        // keystroke path at 1.4 ms median, and the network between this Mac and the host is
        // two orders of magnitude above a vblank.
        layer.setDisplaySyncEnabled(true);

        // FALSE, and this one is a trap worth naming. `presentsWithTransaction` moves the present
        // into the `CoreAnimation` transaction, which means the main thread, which means the
        // present is serialised behind whatever layout `AppKit` is doing. It exists for
        // layers that must stay in lockstep with sibling `UIKit`/AppKit views mid-resize; a
        // terminal is one layer that owns its whole rectangle, and paying the main thread
        // for that synchronisation would put every frame behind the event loop this
        // surface's own input arrives on.
        layer.setPresentsWithTransaction(false);

        // TRUE, which is the default, and the reason is the error type. With the timeout ON,
        // `nextDrawable` gives up after a second and answers nothing, which becomes
        // [`MetalError::NoDrawable`] and skips a frame. With it OFF, the same condition — an
        // occluded or off-screen window, which happens every time the user switches Spaces
        // — blocks the render thread until the compositor changes its mind. A skipped frame
        // is recoverable; a wedged render thread is a hang report.
        layer.setAllowsNextDrawableTimeout(true);

        Self { layer }
    }

    /// The layer, for the `AppKit` or `UIKit` view that hosts it.
    ///
    /// The one door out of this module. Everything a view needs to do with the layer — install it,
    /// move it, resize it — it does through `CoreAnimation` itself, which is why nothing else here
    /// is public.
    #[must_use]
    pub fn layer(&self) -> &CAMetalLayer {
        &self.layer
    }

    /// Points and a contents scale to a drawable size, applied.
    ///
    /// Both halves, always together. `contentsScale` is what tells `CoreAnimation` how the layer's
    /// bounds map to its content, and `drawableSize` is how many texels that content actually has;
    /// setting one without the other is the classic blurry-on-Retina bug in one direction and a
    /// quarter-size image in the other. Doing it in one call is how they cannot drift.
    ///
    /// The multiply is written as a multiply and nothing else — `CLAUDE.md`'s bit-exactness rule —
    /// and the result is floored to whole texels because a drawable is an allocation and there is
    /// no such thing as 1599.5 of them.
    pub fn set_size(&self, width_points: f64, height_points: f64, scale: f64) {
        let safe_scale = scale.max(1.0);
        let width_px = (width_points * safe_scale).floor().max(0.0);
        let height_px = (height_points * safe_scale).floor().max(0.0);

        self.layer.setContentsScale(safe_scale);
        self.layer.setDrawableSize(CGSize::new(width_px, height_px));
    }

    /// The drawable size the layer currently reports, in device pixels.
    #[must_use]
    pub fn drawable_size(&self) -> CGSize {
        self.layer.drawableSize()
    }

    /// Asks `CoreAnimation` for the next drawable.
    ///
    /// Separate from [`crate::Renderer::draw`] because it is the one call in a frame that can
    /// block, and a reader looking for "why did that frame take 16 ms" should find it named.
    ///
    /// # Errors
    ///
    /// [`MetalError::NoDrawable`] when the layer has none — an off-screen or occluded window, which
    /// is a frame to skip rather than a failure to report.
    pub(crate) fn next_drawable(&self) -> Result<Retained<ProtocolObject<dyn CAMetalDrawable>>, MetalError> {
        self.layer.nextDrawable().ok_or(MetalError::NoDrawable)
    }
}
