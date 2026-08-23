//! What one finished encode says about itself, read once.
//!
//! A `CMSampleBuffer` from a compression session carries four things the host needs: the coded
//! bytes, whether the frame is a keyframe, the long-term-reference token when the session is
//! emitting them, and — only on a keyframe — the parameter sets, which `VideoToolbox` keeps in the
//! FORMAT DESCRIPTION rather than inline. That last one is the trap the Swift original documented
//! in capitals: assume the bytes are self-contained and the client can never build a decoder, so
//! the window stays blank with no error anywhere.
//!
//! Every reading happens ONCE per frame. The attachments dictionary in particular is fetched a
//! single time and both the keyframe flag and the token come out of it, because fetching it is a
//! bridge and this runs sixty times a second.

use core::ffi::{c_char, c_void};
use core::ptr::NonNull;

use objc2_core_foundation::{CFArray, CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType};
use objc2_core_media::{
    CMBlockBuffer, CMFormatDescription, CMSampleBuffer, CMVideoFormatDescriptionGetHEVCParameterSetAtIndex,
};

use crate::keys::Attachment;
use crate::session::NO_ERR;

/// A run of bytes the FRAMEWORK owns, as its own `(pointer, length)`.
///
/// A VALUE rather than a slice, deliberately. Turning a framework-owned `(pointer, length)` into a
/// `&[u8]` is a RUST obligation — it asserts alignment, initialisation and a lifetime the framework
/// never states — and `docs/57` §2 bars this family from writing one. `slopdesk-ffi`, whose entire
/// `unsafe` remit is that exact question, makes the slice, and it can answer the lifetime half
/// because it holds the [`EncodedSample`] borrowed across the call that reads it.
///
/// The bytes live as long as the `EncodedSample` this came from, which holds both the block buffer
/// and the format description that own them.
#[derive(Clone, Copy, Debug)]
pub struct FrameworkBytes {
    /// First byte of the run.
    pub bytes: NonNull<u8>,
    /// How many bytes.
    pub len: usize,
}

/// A finished encode, with every per-frame reading already taken.
#[derive(Debug)]
pub struct EncodedSample {
    keyframe: bool,
    ltr_token: Option<i64>,
    block: CFRetained<CMBlockBuffer>,
    payload_len: usize,
    /// Held only for a keyframe: it is what owns the parameter-set bytes.
    format: Option<CFRetained<CMFormatDescription>>,
}

impl EncodedSample {
    /// Reads everything this frame has to say, or `None` when it carries no data buffer at all.
    ///
    /// `read_ltr_token` is the SESSION's long-term-reference setting rather than the frame's: with
    /// long-term references off no sample carries the attachment, and skipping the lookup keeps the
    /// off path free of a dictionary read it would always lose.
    ///
    /// # Safety
    /// `CMSampleBufferGetDataBuffer`, `CMSampleBufferGetFormatDescription` and
    /// `CMSampleBufferGetSampleAttachmentsArray` are Get-rule accessors that `objc2` generates as
    /// owned returns — it applies the retain itself — so nothing crosses raw here. They are
    /// `unsafe` only because they are bare `extern` functions taking a sample buffer, and this
    /// one is a live reference for the whole call.
    ///
    /// `CMBlockBufferGetDataLength` is likewise a read of the buffer's own bookkeeping, with no
    /// pointer and no ownership.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare CoreMedia entry points unsafe"
    )]
    pub fn read(sample: &CMSampleBuffer, read_ltr_token: bool) -> Option<Self> {
        // SAFETY: framework rule, above — an owned-return Get-rule accessor on a live sample.
        let block = unsafe { sample.data_buffer() }?;
        // SAFETY: framework rule, above — a read of the block buffer's own length.
        let payload_len = unsafe { block.data_length() };
        let (keyframe, ltr_token) = read_attachments(sample, read_ltr_token);
        // The format description is fetched only for a keyframe, because it is only a keyframe that
        // needs the parameter sets prepended. A delta frame pays nothing for this.
        let format = if keyframe {
            // SAFETY: framework rule, above — an owned-return Get-rule accessor on a live sample.
            unsafe { sample.format_description() }
        } else {
            None
        };
        Some(Self {
            keyframe,
            ltr_token,
            block,
            payload_len,
            format,
        })
    }

    /// Whether the client may start decoding at this frame.
    ///
    /// The framework says so by ABSENCE: a sample with no `NotSync` attachment, or one set false,
    /// is a sync sample. Defaulting to `true` when the dictionary is missing entirely is the
    /// framework's own reading, not a guess.
    #[must_use]
    pub const fn is_keyframe(&self) -> bool {
        self.keyframe
    }

    /// The long-term-reference token the client must acknowledge, when this frame carries one.
    #[must_use]
    pub const fn ltr_token(&self) -> Option<i64> {
        self.ltr_token
    }

    /// How many bytes of coded slice this frame holds, WITHOUT any parameter sets.
    #[must_use]
    pub const fn payload_len(&self) -> usize {
        self.payload_len
    }

    /// The parameter sets a decoder needs before this frame, in index order.
    ///
    /// Empty on a delta frame, and empty on a keyframe whose format description publishes none —
    /// which is a real answer rather than a failure, and one the caller must handle, because a
    /// keyframe shipped without them is a frame no client can decode.
    ///
    /// # Safety
    /// `CMVideoFormatDescriptionGetHEVCParameterSetAtIndex` writes through the caller's slots and
    /// only the ones that are non-null; every slot passed here is a live local of the declared
    /// type, and the two-pass shape — count first, then each set — is the header's own. The pointer
    /// it reports is owned by the format description, which `self` holds for as long as the
    /// returned values are usable. Nothing is dereferenced here.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "the parameter-set enumerator writes through caller-owned slots"
    )]
    pub fn parameter_sets(&self) -> Vec<FrameworkBytes> {
        let Some(format) = self.format.as_deref() else {
            return Vec::new();
        };
        let mut count = 0_usize;
        // SAFETY: framework rule, above — a count-only probe with three null slots and one live one.
        let probe = unsafe {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                0,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                &raw mut count,
                core::ptr::null_mut(),
            )
        };
        if probe != NO_ERR || count == 0 {
            return Vec::new();
        }
        let mut sets: Vec<FrameworkBytes> = Vec::with_capacity(count);
        for index in 0..count {
            let mut pointer: *const u8 = core::ptr::null();
            let mut len = 0_usize;
            // SAFETY: framework rule, above — two live slots of the declared types, two nulls.
            let status = unsafe {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    index,
                    &raw mut pointer,
                    &raw mut len,
                    core::ptr::null_mut(),
                    core::ptr::null_mut(),
                )
            };
            if status != NO_ERR || len == 0 {
                // A partial answer is not one: a decoder given some of the three parameter sets is
                // no better off than one given none, so the caller sees an empty list and can
                // decide that this keyframe is not shippable.
                return Vec::new();
            }
            let Some(bytes) = NonNull::new(pointer.cast_mut()) else {
                return Vec::new();
            };
            sets.push(FrameworkBytes { bytes, len });
        }
        sets
    }

    /// This frame's coded bytes IN PLACE, when the block buffer happens to hold them contiguously.
    ///
    /// The fast path, and the reason it exists: a delta frame needs no parameter sets prepended, so
    /// if the bytes are already one run there is nothing to assemble and the consumer can read them
    /// where the encoder left them. Sixty times a second that is the difference between one copy of
    /// the frame and none.
    ///
    /// `None` means the buffer is SEGMENTED — `CMBlockBuffer` is a chain, and the framework
    /// promises nothing about how many links a given sample arrives in — and the caller must fall
    /// back to [`Self::copy_payload_into`], which asks the framework to assemble it. Answering the
    /// first segment as if it were the frame is the bug this shape exists to make impossible.
    ///
    /// # Safety
    /// `CMBlockBufferGetDataPointer` writes through the caller's slots, and only the non-null ones;
    /// all four here are live locals of the declared types. The pointer it reports is owned by the
    /// block buffer, which `self` holds for as long as the returned value is usable, and the run is
    /// accepted ONLY when the framework's own `lengthAtOffset` says it covers the whole sample.
    /// Nothing is dereferenced here.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "the data-pointer accessor writes through caller-owned slots"
    )]
    pub fn contiguous_payload(&self) -> Option<FrameworkBytes> {
        if self.payload_len == 0 {
            return None;
        }
        let mut run_len = 0_usize;
        let mut total = 0_usize;
        let mut pointer: *mut c_char = core::ptr::null_mut();
        // SAFETY: framework rule, above — three live slots of the declared types on a live buffer.
        let status = unsafe {
            self.block
                .data_pointer(0, &raw mut run_len, &raw mut total, &raw mut pointer)
        };
        if status != NO_ERR || run_len != self.payload_len || total != self.payload_len {
            return None;
        }
        NonNull::new(pointer.cast::<u8>()).map(|bytes| {
            FrameworkBytes {
                bytes,
                len: self.payload_len,
            }
        })
    }

    /// Appends this frame's coded bytes to `out`; answers whether the framework copied them.
    ///
    /// Appends rather than answering a `Vec` so the caller can lay the parameter sets down first
    /// and pay for ONE allocation and ONE copy of the payload per frame. The Swift this replaces
    /// paid for two of each on every keyframe, because it built the payload and then built a second
    /// buffer that was the parameter sets followed by the payload.
    ///
    /// # Safety
    /// `CMBlockBufferCopyDataBytes` copies `len` bytes into a destination the CALLER owns. The
    /// destination here is `out`'s own newly-grown tail — memory this process allocated, sized to
    /// the length the framework itself just reported for the same buffer, and already initialised
    /// by the resize, so there is no uninitialised window even if the copy fails. Nothing foreign
    /// is dereferenced and nothing is transmuted.
    #[expect(
        unsafe_code,
        reason = "the block-buffer copy writes into a destination this crate allocated"
    )]
    pub fn copy_payload_into(&self, out: &mut Vec<u8>) -> bool {
        if self.payload_len == 0 {
            return false;
        }
        let start = out.len();
        out.resize(start + self.payload_len, 0);
        let Some(tail) = out.get_mut(start..) else {
            return false;
        };
        let destination = NonNull::from(tail).cast::<c_void>();
        // SAFETY: framework rule, above — `destination` is `self.payload_len` initialised bytes of
        // this process's own allocation, and the length is the framework's own for this buffer.
        let status = unsafe { self.block.copy_data_bytes(0, self.payload_len, destination) };
        if status == NO_ERR {
            return true;
        }
        out.truncate(start);
        false
    }
}

/// The keyframe flag and the long-term-reference token, from ONE fetch of the attachments array.
///
/// # Safety
/// `CMSampleBufferGetSampleAttachmentsArray` is a Get-rule accessor `objc2` generates as an owned
/// return, so nothing crosses raw. Its `createIfNecessary` is false: this is a read, and asking the
/// framework to MAKE an attachments array on a sample that has none would be a write.
///
/// The array it answers is untyped, because C's `CFArrayRef` carries no element type. `CoreMedia`
/// documents every element as a `CFDictionary` keyed by `CFString`, and one `cast_unchecked` states
/// that once — every read after it is type-checked by `CoreFoundation` itself.
#[expect(
    unsafe_code,
    reason = "C's CFArrayRef carries no element type; the CoreMedia header is where it lives"
)]
fn read_attachments(sample: &CMSampleBuffer, read_ltr_token: bool) -> (bool, Option<i64>) {
    // SAFETY: framework rule, above — an owned-return Get-rule accessor, asked not to create.
    let Some(array) = (unsafe { sample.sample_attachments_array(false) }) else {
        // No attachments at all means no `NotSync`, which means a sync sample. This is the
        // framework's reading, and it is the one the Swift original took too.
        return (true, None);
    };
    // SAFETY: framework rule, above — CoreMedia documents these as dictionaries of `CFString` keys.
    let typed = unsafe { CFRetained::cast_unchecked::<CFArray<CFDictionary<CFString, CFType>>>(array) };
    let Some(first) = typed.get(0) else {
        return (true, None);
    };
    let keyframe = first
        .get(Attachment::NotSync.cf())
        .and_then(|value| value.downcast::<CFBoolean>().ok())
        .is_none_or(|not_sync| !not_sync.value());
    let ltr_token = read_ltr_token
        .then(|| {
            first
                .get(Attachment::RequireLtrAcknowledgementToken.cf())
                .and_then(|value| value.downcast::<CFNumber>().ok())
                .and_then(|number| number.as_i64())
        })
        .flatten();
    (keyframe, ltr_token)
}
