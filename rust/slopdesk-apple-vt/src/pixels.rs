//! `CVPixelBuffer` — made, locked, and read as BYTES.
//!
//! The encoder half of this crate takes pixel buffers it is handed; nothing in the shipping path
//! ever makes one, because `ScreenCaptureKit` delivers them. The headless validation harness has no
//! capture stack, so its frames have to come from somewhere — and "somewhere" is this module, which
//! calls `CVPixelBufferCreate`, brackets the base-address lock, and answers each plane as the bytes
//! it covers.
//!
//! ## Both views are SLICES, and no address leaves this file
//! [`Locked::plane_view`] and [`Locked::plane_mut`] are the only two ways out, and each answers a
//! borrow of the mapping rather than the pair describing it. Nothing here hands back an address and
//! a stride, so no consumer has to be a crate allowed to make a slice of framework memory —
//! which is what lets the capture daemon and the loopback harness that drive them stay
//! `forbid(unsafe_code)`.
//!
//! Those two slice constructions are `docs/57` §2's sample-memory amendment spent twice, beside
//! `sample.rs`'s one, and `slopdesk-invariants` ratchets the total. They are HERE rather than in
//! `slopdesk-ffi` — which is where they lived, as `pixel_plane`, and whose whole `unsafe` remit is
//! "is this `(ptr, len)` live for this call" — because that hatch closed with the C doors. The shim
//! is no longer on the path between this crate and the daemon that reads a plane, and that daemon
//! may not make the slice itself, so §2's route-one escape no longer exists for this operation and
//! the site has to be at the framework.
//!
//! ## Why the mutable view takes `&mut Locked`
//! Describing a plane needs only `&self`, so two descriptions would hand out two addresses into the
//! same mapping, and one aliasing pair of `&mut [u8]` is undefined behaviour that no test could
//! see. Taking the guard exclusively makes the borrow checker the thing that prevents it: a second
//! plane cannot be taken while the first is live, which matches how a caller uses them anyway —
//! luma, then chroma.
//!
//! ## The lock is an RAII bracket, not two calls a caller must pair
//! `CVPixelBufferLockBaseAddress` and its unlock are the one place in this crate where a missing
//! second call is a leak the type system can prevent, so [`Locked`] holds the buffer and unlocks on
//! drop. A plane's bytes are only reachable THROUGH that guard, which is what makes "the mapping is
//! live for as long as you hold these bytes" a lifetime rather than a comment.

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
    /// Borrows one plane of the locked buffer for READING.
    ///
    /// `None` for a plane the buffer does not have — the framework's null base address — and for a
    /// geometry that describes no mapping at all: a zero stride, no rows, or a `stride * height`
    /// that does not fit. None of those is a SMALL plane, so none of them answers an empty slice.
    ///
    /// A SHARED borrow of the guard is what this takes, which permits several readers of the same
    /// mapping at once. That is sound because none of them writes, and it is what a caller wants:
    /// luma and chroma are read together.
    ///
    /// # Safety
    /// TWO obligations, and they are different in kind.
    ///
    /// The FRAMEWORK's: `CVPixelBufferGetBaseAddressOfPlane` describes a mapping Core Video
    /// keeps live for exactly as long as the base address is LOCKED, and that lock's lifetime
    /// is this guard's. `CVPixelBufferGetBytesPerRowOfPlane` and its height twin are that
    /// mapping's own shape for the same plane, so `stride * height` bytes of it are mapped and
    /// readable for the whole of the borrow answered here.
    ///
    /// RUST's, which this family does not normally carry: making a `&[u8]` of that address
    /// asserts alignment, initialisation and a lifetime the framework never states. It is
    /// admitted as `docs/57` §2's sample-memory amendment, at a site `slopdesk-invariants`
    /// ratchets. Alignment is trivially satisfied for `u8`; the bytes are the allocation Core
    /// Video made and owns, row padding included, and `u8` has no invalid bit pattern; and the
    /// lifetime is the guard's, which outlives the borrow because the borrow is OF it.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "the sample-memory amendment: a locked plane is bytes, and only this crate may say so"
    )]
    pub fn plane_view(&self, index: usize) -> Option<PlaneView<'_>> {
        let plane = self.describe(index)?;
        let len = plane.span()?;
        Some(PlaneView {
            // SAFETY: both obligations, above — `len` mapped bytes, only read through this view.
            bytes: unsafe { core::slice::from_raw_parts(plane.base.cast_const(), len) },
            stride: plane.stride,
            width: plane.width,
            height: plane.height,
        })
    }

    /// Borrows one plane of the locked buffer for WRITING.
    ///
    /// `None` on the same two readings [`Self::plane_view`] answers `None` on.
    ///
    /// The EXCLUSIVE borrow of the guard is the whole point, and the module head is where the
    /// reasoning is: describing a plane needs only `&self`, so a shared-borrow version of this
    /// door would let a caller hold two `&mut [u8]` over one mapping with nothing to stop it.
    ///
    /// # Safety
    /// [`Self::plane_view`]'s two obligations, plus exclusivity. Taking the guard `&mut` is what
    /// makes this the only live view of those bytes for as long as the borrow lasts, which is the
    /// half a shared borrow could not answer.
    ///
    /// `ReadOnly` is not a protection and is not relied on here: it is a promise to Core Video
    /// about cache invalidation, so a caller that means to write takes [`PixelBuffer::lock`] and
    /// a caller that does not takes [`PixelBuffer::lock_read_only`]. Either way the mapping is
    /// this process's to write, and the aliasing question is the one above.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "the sample-memory amendment: a locked plane is bytes, and only this crate may say so"
    )]
    pub fn plane_mut(&mut self, index: usize) -> Option<PlaneBytes<'_>> {
        let plane = self.describe(index)?;
        let len = plane.span()?;
        Some(PlaneBytes {
            // SAFETY: both obligations, above — `len` mapped bytes, exclusively borrowed.
            bytes: unsafe { core::slice::from_raw_parts_mut(plane.base, len) },
            stride: plane.stride,
            width: plane.width,
            height: plane.height,
        })
    }

    /// Describes one plane: where its first row starts, how far apart the rows are, and how much of
    /// each row is picture rather than padding.
    ///
    /// Private, and that is the design: the address it carries is what must not leave this crate,
    /// so the only two callers are the doors above, which turn it into bytes on the same line they
    /// read it.
    ///
    /// `None` for a plane the buffer does not have, which is the framework's null base address.
    fn describe(&self, index: usize) -> Option<Plane> {
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

/// Where one locked plane is, and the geometry needed to walk it.
///
/// PRIVATE, and that is the whole point of this module's shape: `base` is an ADDRESS, and one that
/// escaped would take the `stride * height` obligation with it into a crate that may not carry one.
/// `width` is the VISIBLE bytes per row, which is what makes padding legible rather than picture.
#[derive(Clone, Copy, Debug)]
struct Plane {
    /// The first byte of the first row.
    base: *mut u8,
    /// Bytes from the start of one row to the start of the next.
    stride: usize,
    /// Visible bytes per row.
    width: usize,
    /// Rows in this plane.
    height: usize,
}

impl Plane {
    /// The mapping's length, or `None` when the geometry cannot describe one.
    ///
    /// A zero stride or a product that does not fit is not a small plane — it is a plane that was
    /// never described, and answering `None` is what keeps a hostile or absurd geometry a missing
    /// measurement rather than a read past the mapping.
    const fn span(&self) -> Option<usize> {
        if self.base.is_null() || self.stride == 0 || self.height == 0 {
            return None;
        }
        self.stride.checked_mul(self.height)
    }
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
        let Some(luma) = locked.plane_view(0) else {
            panic!("no luma plane");
        };
        assert_eq!((luma.width, luma.height), (64, 32));
        assert!(luma.stride >= luma.width, "a stride is never below the width");
        let Some(chroma) = locked.plane_view(1) else {
            panic!("no chroma plane");
        };
        assert_eq!((chroma.width, chroma.height), (32, 16));
        assert!(locked.plane_view(2).is_none(), "NV12 is bi-planar");
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
            assert!(locked.plane_view(0).is_some());
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
        let Some(luma) = locked.plane_mut(0) else {
            panic!("no luma plane");
        };
        assert_eq!((luma.width, luma.height), (64, 32));
        assert_eq!(luma.bytes.len(), luma.stride * luma.height);
        let stride = luma.stride;
        for (offset, byte) in luma.bytes.iter_mut().enumerate() {
            *byte = u8::try_from(offset % 251).unwrap_or_default();
        }
        let Some(view) = locked.plane_view(0) else {
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
        let Some(chroma) = locked.plane_view(1) else {
            panic!("no chroma plane");
        };
        assert_eq!((chroma.width, chroma.height), (32, 16));
        assert!(locked.plane_view(2).is_none(), "NV12 is bi-planar");
    }
}
