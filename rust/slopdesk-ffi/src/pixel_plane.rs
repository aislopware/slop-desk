//! A locked pixel buffer's planes, as BYTES.
//!
//! `slopdesk-apple-vt` locks the buffer and answers where each plane starts and how far apart its
//! rows are; `docs/57` §2 bars it from turning that pair into a slice, and this crate is where that
//! conversion already lives — [`crate::video_frame`] does exactly it for the capture path, with the
//! same `checked_mul` on the same obligation. This module is that conversion in the other
//! direction: the harness WRITES a synthetic picture and READS the decoded one back, so it needs
//! both a mutable and a shared view, and it may not write `unsafe` to get either.
//!
//! ## Why the mutable view takes `&mut Locked`
//! `Locked::plane` takes `&self`, so two calls would hand out two addresses into the same mapping.
//! One aliasing pair of `&mut [u8]` would be undefined behaviour that no test could see. Taking the
//! guard exclusively makes the borrow checker the thing that prevents it: a second plane cannot be
//! taken while the first is live, which matches how a caller uses them anyway — luma, then chroma.

use slopdesk_apple_vt::{Locked, Plane};

/// One locked plane, writable.
#[derive(Debug)]
pub struct PlaneBytes<'a> {
    /// Every byte of the mapping this plane covers, padding included.
    pub bytes: &'a mut [u8],
    /// Bytes from the start of one row to the start of the next.
    pub stride: usize,
    /// Visible bytes per row.
    pub width: usize,
    /// Rows in this plane.
    pub height: usize,
}

/// One locked plane, read-only.
#[derive(Debug)]
pub struct PlaneView<'a> {
    /// Every byte of the mapping this plane covers, padding included.
    pub bytes: &'a [u8],
    /// Bytes from the start of one row to the start of the next.
    pub stride: usize,
    /// Visible bytes per row.
    pub width: usize,
    /// Rows in this plane.
    pub height: usize,
}

/// The mapping's length, or `None` when the geometry cannot describe one.
///
/// A zero stride or a product that does not fit is not a small plane — it is a plane that was never
/// described, and answering `None` is what keeps a hostile or absurd geometry a missing measurement
/// rather than a read past the mapping.
const fn span(plane: &Plane) -> Option<usize> {
    if plane.base.is_null() || plane.stride == 0 || plane.height == 0 {
        return None;
    }
    plane.stride.checked_mul(plane.height)
}

/// Borrows one plane of a locked buffer for writing.
///
/// # Safety
/// The address and the stride come from Core Video for a buffer whose base address is locked for
/// the life of `locked`, so `stride * height` bytes are mapped and writable for that lifetime. The
/// exclusive borrow of the guard is what makes this the only live view of them.
#[must_use]
#[expect(
    unsafe_code,
    reason = "turning the framework's (address, stride) into a slice is this crate's remit"
)]
pub fn plane_mut<'a>(locked: &'a mut Locked<'_>, index: usize) -> Option<PlaneBytes<'a>> {
    let plane = locked.plane(index)?;
    let len = span(&plane)?;
    Some(PlaneBytes {
        // SAFETY: the mapping is live for `'a` and exclusively borrowed, per the note above.
        bytes: unsafe { core::slice::from_raw_parts_mut(plane.base, len) },
        stride: plane.stride,
        width: plane.width,
        height: plane.height,
    })
}

/// Borrows one plane of a locked buffer for reading.
///
/// # Safety
/// [`plane_mut`]'s, minus the exclusivity: a shared borrow of the guard permits several readers of
/// the same mapping, which is sound because none of them writes.
#[must_use]
#[expect(
    unsafe_code,
    reason = "turning the framework's (address, stride) into a slice is this crate's remit"
)]
pub fn plane_view<'a>(locked: &'a Locked<'_>, index: usize) -> Option<PlaneView<'a>> {
    let plane = locked.plane(index)?;
    let len = span(&plane)?;
    Some(PlaneView {
        // SAFETY: the mapping is live for `'a` and only read through this view.
        bytes: unsafe { core::slice::from_raw_parts(plane.base.cast_const(), len) },
        stride: plane.stride,
        width: plane.width,
        height: plane.height,
    })
}

#[cfg(test)]
#[expect(
    clippy::panic,
    reason = "a panic in a test IS the failure report, and each message names what the framework refused"
)]
mod tests {
    use slopdesk_apple_vt::PixelBuffer;

    use super::{plane_mut, plane_view};

    /// A write through the mutable view is visible through the shared one, at the geometry the
    /// framework reported — which is the whole contract: a plane read at another plane's stride is
    /// the bug this pairing exists to make unspellable.
    #[test]
    fn what_the_mutable_view_writes_the_shared_view_reads_back() {
        let Ok(buffer) = PixelBuffer::nv12(64, 32, false) else {
            panic!("Core Video refused a 64x32 NV12 buffer");
        };
        let Some(mut locked) = buffer.lock() else {
            panic!("the base address would not lock");
        };
        let Some(luma) = plane_mut(&mut locked, 0) else {
            panic!("no luma plane");
        };
        assert_eq!((luma.width, luma.height), (64, 32));
        assert_eq!(luma.bytes.len(), luma.stride * luma.height);
        let stride = luma.stride;
        for (offset, byte) in luma.bytes.iter_mut().enumerate() {
            *byte = u8::try_from(offset % 251).unwrap_or_default();
        }
        let Some(view) = plane_view(&locked, 0) else {
            panic!("no luma plane to read back");
        };
        assert_eq!(view.stride, stride);
        assert_eq!(view.bytes.first().copied(), Some(0));
        assert_eq!(view.bytes.get(250).copied(), Some(250));
        assert_eq!(view.bytes.get(251).copied(), Some(0));
    }

    /// The second plane of an NV12 buffer is half-size in both directions, and there is no third.
    #[test]
    fn the_chroma_plane_is_half_the_picture_and_there_is_no_third() {
        let Ok(buffer) = PixelBuffer::nv12(64, 32, true) else {
            panic!("Core Video refused a 64x32 NV12 buffer");
        };
        let Some(locked) = buffer.lock_read_only() else {
            panic!("the base address would not lock");
        };
        let Some(chroma) = plane_view(&locked, 1) else {
            panic!("no chroma plane");
        };
        assert_eq!((chroma.width, chroma.height), (32, 16));
        assert!(plane_view(&locked, 2).is_none(), "NV12 is bi-planar");
    }
}
