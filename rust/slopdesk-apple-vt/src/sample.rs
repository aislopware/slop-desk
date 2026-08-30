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
//!
//! ## Both readings COPY, and no framework pointer leaves this file
//! [`EncodedSample::copy_parameter_sets_into`] and [`EncodedSample::copy_payload_into`] are the
//! only two ways out, and each appends into a `Vec` the CALLER owns. Nothing here answers a
//! `(pointer, length)`, so no consumer has to be a crate allowed to make a slice of framework
//! memory — which is what lets the encoder driver be `forbid(unsafe_code)` (`docs/61` §2).
//!
//! The parameter-set copy is the ONE raw-pointer site `docs/57` §2's sample-memory amendment admits
//! in this crate, and it is here rather than anywhere else because the SDK publishes HEVC parameter
//! sets as a bare pointer and offers no copy-out variant at all. `slopdesk-invariants` ratchets the
//! count at one.
//!
//! Copying the payload rather than handing over the block buffer's own run costs nothing that was
//! ever saved: a finished frame crosses from `VideoToolbox`'s thread to the packetize lane, so it
//! has to become owned bytes before it is sent whatever this file answers. The zero-copy path that
//! used to exist here only ever deferred that copy to the Swift caller, which made one anyway.

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2_core_foundation::{CFArray, CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType};
use objc2_core_media::{
    CMBlockBuffer, CMFormatDescription, CMSampleBuffer, CMVideoFormatDescriptionGetHEVCParameterSetAtIndex,
};

use crate::keys::Attachment;
use crate::status::NO_ERR;

/// Big-endian length prefix width for an AVCC-framed NAL unit, and the only width this stream uses.
///
/// Not a choice made here: it is what `VideoToolbox` reports for every HEVC format description it
/// produces, and it is what the client builds its own format description with. It is written down
/// so [`EncodedSample::copy_parameter_sets_into`] can CHECK the framework's answer against it
/// rather than assume — a stream framed at a width the client does not expect decodes as garbage,
/// and a mismatch is the one thing a length prefix cannot report about itself.
const AVCC_LENGTH_BYTES: i32 = 4;

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

    /// Appends this frame's AVCC-framed parameter sets to `out`; answers whether it laid down ALL
    /// of them.
    ///
    /// `false` on a delta frame, which carries none and needs none — the ordinary case, and not a
    /// failure. `false` ALSO on a keyframe whose format description publishes nothing readable,
    /// which is a real answer the caller must handle: a keyframe shipped without parameter sets is
    /// one a client with no format description yet cannot decode, so the caller decides whether to
    /// ship it bare or drop it. Either way `out` is left exactly as it was found — a half-written
    /// prefix is the one outcome that would corrupt the frame behind it.
    ///
    /// Appends rather than answering a `Vec` so a keyframe costs ONE allocation and one copy: the
    /// caller lays the sets down and then [`Self::copy_payload_into`] appends the slice behind
    /// them.
    ///
    /// # Safety
    /// TWO obligations, and they are different in kind.
    ///
    /// The FRAMEWORK's: `CMVideoFormatDescriptionGetHEVCParameterSetAtIndex` writes through the
    /// caller's slots and only the non-null ones; every slot passed here is a live local of the
    /// declared type, and the two-pass shape — count and NAL width first, then each set — is the
    /// header's own. The pointer it reports is owned by the format description, which `self` holds
    /// for the whole of this call.
    ///
    /// RUST's, which this family does not normally carry: making a `&[u8]` of that pointer asserts
    /// alignment, initialisation and a lifetime the framework never states. It is admitted here as
    /// `docs/57` §2's sample-memory amendment, at the ONE site `slopdesk-invariants` ratchets, and
    /// the reason it cannot move is the SDK's — HEVC parameter sets have no copy-out variant, so
    /// there is no version of this read that is not a raw one. Alignment is trivially satisfied for
    /// `u8`; initialisation and length are the framework's own answer for the same call; and the
    /// lifetime is `self`'s, which outlives the `extend_from_slice` it is passed to.
    #[expect(
        unsafe_code,
        reason = "the SDK publishes HEVC parameter sets as a bare pointer and offers no copy-out"
    )]
    pub fn copy_parameter_sets_into(&self, out: &mut Vec<u8>) -> bool {
        let Some(format) = self.format.as_deref() else {
            return false;
        };
        let mut count = 0_usize;
        let mut nal_length = 0_i32;
        // SAFETY: framework rule, above — a probe with two null slots and two live ones.
        let probe = unsafe {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                0,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                &raw mut count,
                &raw mut nal_length,
            )
        };
        // A width this stream does not frame at is refused rather than honoured: the client builds
        // its format description at `AVCC_LENGTH_BYTES`, so writing the framework's other answer
        // would produce a frame that parses as garbage and reports nothing.
        if probe != NO_ERR || count == 0 || nal_length != AVCC_LENGTH_BYTES {
            return false;
        }
        let start = out.len();
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
            // A partial answer is not one: a decoder given some of the three parameter sets is no
            // better off than one given none, so the whole prefix is rolled back.
            let prefix = u32::try_from(len).ok().filter(|_| status == NO_ERR && len > 0);
            let (Some(prefix), Some(bytes)) = (prefix, NonNull::new(pointer.cast_mut())) else {
                out.truncate(start);
                return false;
            };
            out.extend_from_slice(&prefix.to_be_bytes());
            // SAFETY: Rust's obligation, above — `len` initialised bytes the format description
            // owns and `self` holds for this call, read as `u8`, which cannot be
            // misaligned.
            out.extend_from_slice(unsafe { core::slice::from_raw_parts(bytes.as_ptr().cast_const(), len) });
        }
        true
    }

    /// Appends this frame's coded bytes to `out`; answers whether the framework copied them.
    ///
    /// Appends rather than answering a `Vec` so the caller can lay the parameter sets down first
    /// and pay for ONE allocation and ONE copy of the payload per frame. The Swift this replaces
    /// paid for two of each on every keyframe, because it built the payload and then built a second
    /// buffer that was the parameter sets followed by the payload.
    ///
    /// The framework assembles a segmented buffer on the way out, so this is also the answer for a
    /// `CMBlockBuffer` that arrived as a chain — which the framework promises nothing about either
    /// way, and which is why there is one door rather than a fast path and a fallback that could
    /// disagree.
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
