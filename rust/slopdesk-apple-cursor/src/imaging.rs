//! Rendering a cursor's TIFF into a PNG of a chosen pixel size.
//!
//! Split from the read because it is the half that touches `AppKit`'s DRAWING machinery rather than
//! its cursor state, and because the two are called on different cadences: the shape is read
//! whenever the window server says it changed, and a render happens only the first time a shape is
//! seen. Both `unsafe` blocks in this crate are here.
//!
//! Nothing here decides WHAT size to render at. That ladder — start at the Retina-logical size, and
//! shrink only if the encoded bytes miss the datagram budget — is `slopdesk_video::cursor`'s, where
//! it is a function over integers with tests.

use objc2::AllocAnyThread as _;
use objc2::rc::Retained;
use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSGraphicsContext};
use objc2_foundation::{NSData, NSDictionary, NSRect};

/// A cursor bitmap's PIXEL dimensions, which are not its logical size.
///
/// A `HiDPI` or large-pointer cursor hands back a bitmap many times the points it draws at —
/// measured at 583 KB on one host — so the caller needs both numbers to decide what to render.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bitmap {
    /// Pixels across.
    pub pixels_wide: usize,
    /// Pixels down.
    pub pixels_high: usize,
}

/// The pixel dimensions of `tiff`, or `None` when it holds no bitmap representation.
#[must_use]
pub fn measure(tiff: &[u8]) -> Option<Bitmap> {
    let rep = representation(tiff)?;
    Some(Bitmap {
        pixels_wide: usize::try_from(rep.pixelsWide()).ok()?,
        pixels_high: usize::try_from(rep.pixelsHigh()).ok()?,
    })
}

/// Renders `tiff` into a PNG of exactly `width` × `height` pixels.
///
/// `None` when the TIFF holds no bitmap representation, when the destination cannot be allocated,
/// or when the encode produced nothing — all of which the caller reads the same way: this shape
/// cannot be shipped, so no shape message goes out and the client keeps compositing the last one.
///
/// The draw is offscreen. No window server is involved, which is what lets it run on a daemon with
/// no windows of its own.
#[must_use]
#[expect(
    unsafe_code,
    reason = "the PNG encoder's properties dictionary is typed only by convention in the binding"
)]
pub fn render_png(tiff: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let source = representation(tiff)?;
    let destination = allocate(width, height)?;
    draw_into(&source, &destination, width, height);
    // SAFETY: the binding is `unsafe` for one reason its own note gives — the properties
    // dictionary's generic must match what the encoder expects. An EMPTY dictionary satisfies every
    // encoder, which is the framework's documented "use the defaults", so there is no key here to
    // get wrong.
    let png = unsafe {
        destination.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
    }?;
    Some(png.to_vec())
}

/// The first bitmap representation inside a TIFF, as `AppKit` reads it.
fn representation(tiff: &[u8]) -> Option<Retained<NSBitmapImageRep>> {
    let data = NSData::with_bytes(tiff);
    NSBitmapImageRep::imageRepWithData(&data)
}

/// A fresh `width` × `height` RGBA bitmap the framework owns the storage for.
///
/// Sizes of zero are refused here rather than passed on: `AppKit`'s behaviour for a zero-dimension
/// rep is to answer nil, and clamping to 1 instead would hand back a one-pixel cursor that looks
/// like a successful render.
#[expect(
    unsafe_code,
    reason = "a NULL data-planes pointer is how AppKit is asked to own the pixel buffer"
)]
fn allocate(width: usize, height: usize) -> Option<Retained<NSBitmapImageRep>> {
    if width == 0 || height == 0 {
        return None;
    }
    let (wide, high) = (isize::try_from(width).ok()?, isize::try_from(height).ok()?);
    // SAFETY: AppKit's contract for `initWithBitmapDataPlanes:` is that a NULL `planes` argument
    // means the framework allocates and OWNS the pixel buffer, sized from the dimensions and the
    // per-sample values given here — so nothing this side allocates is handed over, and nothing it
    // hands back is borrowed. The remaining arguments are the documented RGBA-8888 combination:
    // 8 bits per sample, 4 samples, alpha present, interleaved, device RGB, and 0 for both row and
    // pixel strides, which asks the framework to compute them.
    let rep = unsafe {
        NSBitmapImageRep::initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel(
            NSBitmapImageRep::alloc(),
            std::ptr::null_mut(),
            wide,
            high,
            8,
            4,
            true,
            false,
            objc2_app_kit::NSDeviceRGBColorSpace,
            0,
            0,
        )
    }?;
    rep.setSize(objc2_foundation::NSSize::new(pixels(width), pixels(height)));
    Some(rep)
}

/// Draws `source` into `destination`, scaled to fill it.
///
/// The interpolation is left at the context's default rather than raised to `.high`. The Swift this
/// replaced raised it, and the reason it could is that it ran on the main actor where a slow filter
/// costs one frame of a UI; here the same draw sits between a shape change and the client seeing
/// it, and the default is what the framework picks for an offscreen bitmap of this size.
fn draw_into(source: &NSBitmapImageRep, destination: &NSBitmapImageRep, width: usize, height: usize) {
    let Some(context) = NSGraphicsContext::graphicsContextWithBitmapImageRep(destination) else {
        return;
    };
    let rect = NSRect::new(
        objc2_foundation::NSPoint::new(0.0, 0.0),
        objc2_foundation::NSSize::new(pixels(width), pixels(height)),
    );
    // The bindings generate all four of these SAFE, so what is left to honour is AppKit's own rule
    // rather than Rust's: `saveGraphicsState` and `restoreGraphicsState` bracket every change to
    // the current context, on the SAME thread, with no early return between them — which is why
    // this is four statements with no `?` in them. Leaving a bitmap context current would make the
    // next unrelated draw on this thread land in a buffer that is about to be freed.
    NSGraphicsContext::saveGraphicsState_class();
    NSGraphicsContext::setCurrentContext(Some(&context));
    let _drawn = source.drawInRect(rect);
    NSGraphicsContext::restoreGraphicsState_class();
}

/// A pixel count as the `CGFloat` `AppKit` takes.
///
/// Lossless in practice and deliberately not `try_into`: a cursor is tens of pixels on a side, and
/// `f64` is exact to 2^53, so the cast cannot lose a bit for any value that reached this far.
#[expect(
    clippy::cast_precision_loss,
    reason = "a cursor edge is tens of pixels; f64 is exact past 2^53"
)]
const fn pixels(count: usize) -> f64 {
    count as f64
}
