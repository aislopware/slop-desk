//! `CVPixelBuffer` — made, locked, and described. Never READ or WRITTEN here.
//!
//! The encoder half of this crate takes pixel buffers it is handed; nothing in the shipping path
//! ever makes one, because `ScreenCaptureKit` delivers them. The headless validation harness has no
//! capture stack, so its frames have to come from somewhere — and "somewhere" is this module, which
//! calls `CVPixelBufferCreate`, brackets the base-address lock, and answers where each plane starts
//! and how far apart its rows are.
//!
//! ## Where the line is, and why it is exactly here
//! `docs/57` §2 bars this family from hand-writing a raw-pointer DEREFERENCE. Every call below is a
//! framework call — the thing this family exists to make — and [`Plane`] hands back an ADDRESS and
//! a stride, which is a description and not a read. Turning that pair into a slice is the operation
//! `slopdesk-ffi` already owns for the capture path (`video_frame::plane_bytes`), and its mutable
//! twin lives beside it for the same reason: the obligation is "does `stride * rows` stay inside
//! the mapping", which is answerable without knowing anything about slopdesk.
//!
//! ## The lock is an RAII bracket, not two calls a caller must pair
//! `CVPixelBufferLockBaseAddress` and its unlock are the one place in this crate where a missing
//! second call is a leak the type system can prevent, so [`Locked`] holds the buffer and unlocks on
//! drop. A plane address is only reachable THROUGH that guard, which is what makes "the mapping is
//! live for as long as you hold this address" a lifetime rather than a comment.

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2_core_foundation::{CFDictionary, CFRetained, CFString, CFType};
use objc2_core_video::{
    CVImageBuffer, CVPixelBuffer, CVPixelBufferGetBaseAddressOfPlane, CVPixelBufferGetBytesPerRowOfPlane,
    CVPixelBufferGetHeightOfPlane, CVPixelBufferGetWidthOfPlane, CVPixelBufferLockBaseAddress,
    CVPixelBufferLockFlags, CVPixelBufferUnlockBaseAddress,
};

use crate::keys::DecodeKey;
use crate::owned::created;

/// `kCVReturnSuccess`. Zero, like every other Core Video status.
const CV_SUCCESS: i32 = 0;

/// The status this module reports when the framework wrote no buffer but claimed success.
const NO_BUFFER: i32 = -6660;

/// One NV12 pixel buffer, owned.
#[derive(Debug)]
pub struct PixelBuffer {
    /// The framework object, released when this drops.
    buffer: CFRetained<CVPixelBuffer>,
}

impl PixelBuffer {
    /// Creates an `IOSurface`-backed bi-planar NV12 buffer of the given size.
    ///
    /// `IOSurface`-backed is not a preference: `VTCompressionSession` takes a surface-less buffer
    /// by copying it into one of its own on every frame, so a harness that skipped the
    /// attribute would be measuring an encode with a per-frame blit in front of it that the
    /// live path never pays.
    ///
    /// Answers the framework's `CVReturn` on failure.
    ///
    /// # Errors
    /// The framework's status, or [`NO_BUFFER`] when it reported success and wrote nothing.
    pub fn nv12(width: usize, height: usize, full_range: bool) -> Result<Self, i32> {
        let empty: CFRetained<CFDictionary<CFString, CFType>> = CFDictionary::from_slices(&[], &[]);
        let keys: [&CFString; 1] = [DecodeKey::IoSurfaceProperties.cf()];
        let values: [&CFType; 1] = [&**empty];
        let attributes: CFRetained<CFDictionary<CFString, CFType>> =
            CFDictionary::from_slices(&keys, &values);

        let mut slot: *mut CVPixelBuffer = core::ptr::null_mut();
        // SAFETY: framework rule — the out-parameter's slot is live and correctly typed, and the
        // attribute dictionary is a `CFDictionary` of the `CFString` keys the call documents.
        #[expect(
            unsafe_code,
            reason = "a Core Video create with an out-parameter; the same shape session.rs uses"
        )]
        let status = unsafe {
            objc2_core_video::CVPixelBufferCreate(
                None,
                width,
                height,
                Self::format(full_range),
                Some(attributes.as_opaque()),
                NonNull::from(&mut slot),
            )
        };
        if status != CV_SUCCESS {
            return Err(status);
        }
        // SAFETY: framework rule — `CVPixelBufferCreate` is a Create-rule function, so the slot
        // holds a reference this call owns.
        created(slot).map_or(Err(NO_BUFFER), |buffer| Ok(Self { buffer }))
    }

    /// Takes over a `CVPixelBufferRef` a Create-rule door already handed across at +1.
    ///
    /// The decoder's frame callback is exactly that door: `slopdesk_video_decoder_decode` delivers
    /// the image buffer retained, and whoever receives it must release it. Wrapping it here is that
    /// release, attached to a scope.
    #[must_use]
    pub fn from_created(raw: *mut c_void) -> Option<Self> {
        // SAFETY: framework rule — the caller obtained this from a door documented to hand over at
        // +1, which is the Copy/Create rule stated in the calling convention rather than the name.
        created(raw.cast::<CVPixelBuffer>()).map(|buffer| Self { buffer })
    }

    /// The address the encoder doors want, which take a `CVPixelBufferRef` as an opaque pointer.
    #[must_use]
    pub fn as_ptr(&self) -> *const c_void {
        CFRetained::as_ptr(&self.buffer).as_ptr().cast()
    }

    /// Takes over a buffer the decoder's sink already owns.
    ///
    /// `CVPixelBuffer` and `CVImageBuffer` are one type, so this is a rename of an ownership that
    /// already exists — no retain, no release, and nothing to get wrong.
    #[must_use]
    pub const fn from_retained(buffer: CFRetained<CVImageBuffer>) -> Self {
        Self { buffer }
    }

    /// Gives the buffer up at +1, for a caller whose own contract says it will release.
    ///
    /// The mirror of [`Self::from_created`]: what one takes, this hands back. Every use is a door
    /// whose documented term is that the callee now owns the reference.
    #[must_use]
    pub fn into_created(self) -> *mut c_void {
        CFRetained::into_raw(self.buffer).as_ptr().cast()
    }

    /// The same object under the name the encoder's Rust surface takes.
    ///
    /// `CVPixelBuffer`, `CVImageBuffer` and `CVBuffer` are ONE Core Video type wearing three names,
    /// which the bindings spell as two type aliases — so this is a borrow and not a cast, and a
    /// caller that has a pixel buffer can feed a session without going through a raw pointer.
    #[must_use]
    pub fn image(&self) -> &CVImageBuffer {
        &self.buffer
    }

    /// Locks the base address, answering a guard that unlocks when it drops.
    ///
    /// `None` when the framework refused the lock, which is the only outcome that is not a plane
    /// address: a caller that wrote through an unlocked mapping would be writing into whatever the
    /// surface was last bound to.
    #[must_use]
    pub fn lock(&self) -> Option<Locked<'_>> {
        Self::lock_with(&self.buffer, CVPixelBufferLockFlags::empty())
    }

    /// Locks read-only — the flag that lets Core Video skip invalidating the surface's caches.
    #[must_use]
    pub fn lock_read_only(&self) -> Option<Locked<'_>> {
        Self::lock_with(&self.buffer, CVPixelBufferLockFlags::ReadOnly)
    }

    /// The shared half of the two locks.
    fn lock_with(buffer: &CVPixelBuffer, flags: CVPixelBufferLockFlags) -> Option<Locked<'_>> {
        // SAFETY: framework rule — a Get-rule reference borrowed for the call, and the matching
        // unlock is `Locked`'s `Drop`.
        #[expect(
            unsafe_code,
            reason = "the base-address lock is a framework call; its pairing is the guard below"
        )]
        let status = unsafe { CVPixelBufferLockBaseAddress(buffer, flags) };
        (status == CV_SUCCESS).then_some(Locked { buffer, flags })
    }

    /// The NV12 four-character code for the requested luma range.
    const fn format(full_range: bool) -> u32 {
        if full_range {
            objc2_core_video::kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        } else {
            objc2_core_video::kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }
}

/// A pixel buffer whose base address is locked for the life of this value.
#[derive(Debug)]
pub struct Locked<'a> {
    /// The buffer this guard unlocks.
    buffer: &'a CVPixelBuffer,
    /// The flags the lock was taken with; the unlock must match them.
    flags: CVPixelBufferLockFlags,
}

impl Locked<'_> {
    /// Describes one plane: where its first row starts, how far apart the rows are, and how much of
    /// each row is picture rather than padding.
    ///
    /// `None` for a plane the buffer does not have, which is the framework's null base address.
    #[must_use]
    pub fn plane(&self, index: usize) -> Option<Plane> {
        let base = CVPixelBufferGetBaseAddressOfPlane(self.buffer, index);
        if base.is_null() {
            return None;
        }
        Some(Plane {
            base: base.cast::<u8>(),
            stride: CVPixelBufferGetBytesPerRowOfPlane(self.buffer, index),
            width: CVPixelBufferGetWidthOfPlane(self.buffer, index),
            height: CVPixelBufferGetHeightOfPlane(self.buffer, index),
        })
    }
}

impl Drop for Locked<'_> {
    fn drop(&mut self) {
        // SAFETY: framework rule — the matching unlock for the lock this guard was built from, with
        // the same flags, on a reference borrowed for the call.
        #[expect(
            unsafe_code,
            reason = "the unlock half of the bracket this guard exists to close"
        )]
        let _ = unsafe { CVPixelBufferUnlockBaseAddress(self.buffer, self.flags) };
    }
}

/// Where one locked plane is, and the geometry needed to walk it.
///
/// `base` is an ADDRESS, not a borrow: this crate may not dereference it, and the caller that turns
/// it into a slice takes the `stride * height` obligation with it. `width` is the VISIBLE bytes per
/// row, which is what makes padding legible rather than picture.
#[derive(Clone, Copy, Debug)]
pub struct Plane {
    /// The first byte of the first row.
    pub base: *mut u8,
    /// Bytes from the start of one row to the start of the next.
    pub stride: usize,
    /// Visible bytes per row.
    pub width: usize,
    /// Rows in this plane.
    pub height: usize,
}

#[cfg(test)]
#[expect(
    clippy::panic,
    reason = "a panic in a test IS the failure report, and each message names what the framework refused"
)]
mod tests {
    use super::PixelBuffer;

    /// A create, a lock, two planes with the NV12 shape, and an unlock — the whole bracket. Runs
    /// headless: `CVPixelBufferCreate` needs no window server, unlike everything else in this
    /// crate.
    #[test]
    fn an_nv12_buffer_has_two_planes_at_the_expected_shape() {
        let Ok(buffer) = PixelBuffer::nv12(64, 32, false) else {
            panic!("Core Video refused a 64x32 NV12 buffer");
        };
        assert!(!buffer.as_ptr().is_null());
        let Some(locked) = buffer.lock() else {
            panic!("the base address would not lock");
        };
        let Some(luma) = locked.plane(0) else {
            panic!("no luma plane");
        };
        assert_eq!((luma.width, luma.height), (64, 32));
        assert!(luma.stride >= luma.width, "a stride is never below the width");
        let Some(chroma) = locked.plane(1) else {
            panic!("no chroma plane");
        };
        assert_eq!((chroma.width, chroma.height), (32, 16));
        assert!(locked.plane(2).is_none(), "NV12 is bi-planar");
    }

    /// A hundred thousand create/lock/drop cycles against the same geometry. The Create-rule
    /// ownership and the lock bracket are both counted here: a leaked +1 or a missing unlock would
    /// exhaust the surface cache long before the loop ended.
    #[test]
    fn a_hundred_thousand_buffers_neither_leak_nor_stay_locked() {
        for _ in 0..100_000_u32 {
            let Ok(buffer) = PixelBuffer::nv12(16, 16, true) else {
                panic!("Core Video refused a 16x16 NV12 buffer");
            };
            let Some(locked) = buffer.lock() else {
                panic!("the base address would not lock");
            };
            assert!(locked.plane(0).is_some());
            drop(locked);
            // A second lock only succeeds because the first one was released by its guard.
            assert!(buffer.lock_read_only().is_some());
        }
    }

    /// Null is an absence rather than a buffer, on the hand-over door.
    #[test]
    fn a_null_hand_over_is_no_buffer() {
        assert!(PixelBuffer::from_created(core::ptr::null_mut()).is_none());
    }
}
