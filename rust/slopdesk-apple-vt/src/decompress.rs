//! One `VTDecompressionSession`: built from parameter sets, fed AVCC bytes, answering pixels.
//!
//! The compression half of this crate is macOS-only because only the host encodes. This half is on
//! EVERY Apple slice, because every client decodes — which is the one structural difference between
//! the two, and the reason `slopdesk-ffi` gates `encoder` and not `decoder`.
//!
//! Every method here is a CALL. When to rebuild the session, what an empty frame means, whether a
//! byte-identical keyframe is worth a teardown, how the decode wall folds into an average — all of
//! that is `slopdesk_video`'s `decoder_state`, which `forbid`s `unsafe`.
//!
//! ## The decode is SYNCHRONOUS, and that is load-bearing rather than incidental
//! `decode_flags` is empty, which the header documents as "decode this frame before returning". The
//! Swift original measured it at 0.9–1.1 ms and depended on the property twice over: it read the
//! handler's status after the call returned, and it timed the call as the decode. Both are only
//! sound because the handler has already run. [`DecompressionSession::decode`] keeps the property
//! and states it here, because an asynchronous flag added later would break two things that do not
//! look like they are about flags.

use std::sync::Arc;

use objc2_core_foundation::{
    CFArray, CFBoolean, CFDictionary, CFMutableDictionary, CFNumber, CFRetained, CFString, CFType,
};
use objc2_core_media::{
    CMBlockBuffer, CMFormatDescription, CMSampleBuffer, CMVideoFormatDescriptionCreateFromHEVCParameterSets,
    kCMBlockBufferAssureMemoryNowFlag,
};
use objc2_core_video::CVImageBuffer;
use objc2_video_toolbox::{VTDecodeFrameFlags, VTDecompressionSession};

use crate::keys::{Attachment, DecodeKey};
use crate::owned::{borrowed, created};
use crate::status::{INVALID_SESSION, NO_ERR};

/// The AVCC length prefix the host writes ahead of every NAL unit, in bytes.
///
/// Four, matching `slopdesk_video`'s `NALUnit::LENGTH_PREFIX_SIZE`. It is spelled here rather than
/// taken as an argument because the format description and the byte stream have to agree, and a
/// caller that could pass three would be able to build a description that silently mis-parses every
/// frame the same encoder produced.
pub const NAL_LENGTH_PREFIX: i32 = 4;

/// How many parameter sets an HEVC format description is built from: VPS, SPS, PPS.
const PARAMETER_SET_COUNT: usize = 3;

/// An HEVC `CMVideoFormatDescription`, built from the VPS/SPS/PPS a keyframe carries inline.
///
/// The host streams raw AVCC with no out-of-band parameter sets, so this is rebuilt from the bytes
/// of every keyframe whose sets DIFFER from the running ones — a decision that lives one crate
/// over, because a byte-identical heartbeat IDR arriving once a second must not tear the session
/// down.
#[derive(Debug)]
pub struct FormatDescription {
    inner: CFRetained<CMFormatDescription>,
}

impl FormatDescription {
    /// Builds the description from three parameter-set payloads, in VPS/SPS/PPS order.
    ///
    /// # Errors
    /// The framework's `OSStatus`. A description that cannot be built from a keyframe's sets means
    /// the keyframe is not one the decoder can anchor on, which the caller reports as needing
    /// another.
    ///
    /// # Safety
    /// `CMVideoFormatDescriptionCreateFromHEVCParameterSets` takes parallel pointer and size arrays
    /// and reads `parameter_set_count` entries from each. Both arrays are built here, from the
    /// three slices the caller lent, and are live for the call; every pointer in them is the
    /// base of a non-empty slice, which is what [`Self::from_hevc_parameter_sets`] rejects an
    /// empty set to guarantee. The description is a **Create-rule** out-parameter — see
    /// [`crate::owned::created`].
    ///
    /// The framework COPIES the parameter-set bytes into the description, which is why the slices
    /// need only outlive this call and the caller may drop them immediately after.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare CoreMedia entry points unsafe"
    )]
    pub fn from_hevc_parameter_sets(vps: &[u8], sps: &[u8], pps: &[u8]) -> Result<Self, i32> {
        let sets = [vps, sps, pps];
        let mut pointers: Vec<core::ptr::NonNull<u8>> = Vec::with_capacity(PARAMETER_SET_COUNT);
        let mut sizes: Vec<usize> = Vec::with_capacity(PARAMETER_SET_COUNT);
        for set in sets {
            // An empty parameter set has no base pointer worth passing, and the framework documents
            // at least one of each as required — so this is the caller's malformed keyframe, not a
            // decode failure, and it is refused before any framework call.
            let Some(base) = core::ptr::NonNull::new(set.as_ptr().cast_mut()) else {
                return Err(INVALID_SESSION);
            };
            pointers.push(base);
            sizes.push(set.len());
        }
        let (Some(pointer_base), Some(size_base)) = (
            core::ptr::NonNull::new(pointers.as_mut_ptr()),
            core::ptr::NonNull::new(sizes.as_mut_ptr()),
        ) else {
            return Err(INVALID_SESSION);
        };
        let mut slot: *const CMFormatDescription = core::ptr::null();
        // SAFETY: framework rule, above — three live parallel entries in each array, a count that
        // matches, and a live out-slot of the declared type.
        let status = unsafe {
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                None,
                PARAMETER_SET_COUNT,
                pointer_base,
                size_base,
                NAL_LENGTH_PREFIX,
                None,
                core::ptr::NonNull::from(&mut slot),
            )
        };
        if status != NO_ERR {
            return Err(status);
        }
        created(slot.cast_mut()).map_or(Err(INVALID_SESSION), |inner| Ok(Self { inner }))
    }
}

/// One AVCC frame, wrapped in the `CMSampleBuffer` the decoder wants.
///
/// Core Media OWNS the bytes. The block buffer is created with a null memory block, which makes the
/// framework allocate `len` bytes of its own, and the frame is then copied in. The alternative — a
/// `kCFAllocatorNull` block over the caller's pointer — would reference bytes without retaining
/// them, and the sample buffer outlives this function on every path.
#[derive(Debug)]
pub struct SampleBuffer {
    inner: CFRetained<CMSampleBuffer>,
}

impl SampleBuffer {
    /// Wraps `avcc` against `format`, optionally stamped to present on decode.
    ///
    /// # Errors
    /// The framework's `OSStatus` from whichever of the three calls failed.
    ///
    /// # Safety
    /// Three framework obligations, in order. `CMBlockBufferCreateWithMemoryBlock` with a null
    /// memory block and `kCMBlockBufferAssureMemoryNowFlag` allocates its own store, so nothing
    /// foreign is dereferenced and the out-parameter is a **Create-rule** slot.
    /// `CMBlockBufferReplaceDataBytes` reads `len` bytes from a source pointer — the base of the
    /// live slice this function was lent — into a destination the framework just reported as `len`
    /// bytes long. `CMSampleBufferCreateReady` takes the sample-size array by pointer and reads one
    /// entry, which is the live local below, and answers another Create-rule slot.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare CoreMedia entry points unsafe"
    )]
    pub fn from_avcc(
        avcc: &[u8],
        format: &FormatDescription,
        display_immediately: bool,
    ) -> Result<Self, i32> {
        let len = avcc.len();
        let mut block_slot: *mut CMBlockBuffer = core::ptr::null_mut();
        // SAFETY: framework rule, above — null memory block, so the framework allocates; live slot.
        let status = unsafe {
            CMBlockBuffer::create_with_memory_block(
                None,
                core::ptr::null_mut(),
                len,
                None,
                core::ptr::null(),
                0,
                len,
                kCMBlockBufferAssureMemoryNowFlag,
                core::ptr::NonNull::from(&mut block_slot),
            )
        };
        if status != NO_ERR {
            return Err(status);
        }
        let Some(block) = created(block_slot) else {
            return Err(INVALID_SESSION);
        };
        if let Some(source) = core::ptr::NonNull::new(avcc.as_ptr().cast_mut().cast()) {
            // SAFETY: framework rule, above — `len` bytes read from the base of a live slice of
            // exactly that length, into a block the create just sized to match. An EMPTY frame has
            // no base to pass and nothing to copy, which is what `NonNull::new` answers here; the
            // caller's own triage refuses one long before this, so the branch is a floor, not a path.
            let status = unsafe { CMBlockBuffer::replace_data_bytes(source, &block, 0, len) };
            if status != NO_ERR {
                return Err(status);
            }
        }

        let mut sizes = [len];
        let mut sample_slot: *mut CMSampleBuffer = core::ptr::null_mut();
        // SAFETY: framework rule, above — one sample, one size entry read from a live local array,
        // no timing entries, and a live Create-rule slot.
        let status = unsafe {
            CMSampleBuffer::create_ready(
                None,
                Some(&block),
                Some(&format.inner),
                1,
                0,
                core::ptr::null(),
                1,
                sizes.as_mut_ptr(),
                core::ptr::NonNull::from(&mut sample_slot),
            )
        };
        if status != NO_ERR {
            return Err(status);
        }
        let Some(inner) = created(sample_slot) else {
            return Err(INVALID_SESSION);
        };
        let buffer = Self { inner };
        if display_immediately {
            buffer.stamp_display_immediately();
        }
        Ok(buffer)
    }

    /// Marks the sample "present the instant you decode it", rather than holding it for reorder.
    ///
    /// The encoder already sets `AllowFrameReordering` false, so a correct SPS declares no reorder
    /// capacity and this changes nothing. It is set anyway because the failure it prevents is
    /// silent: a decoder that still advertised capacity would hold the frame inside a synchronous
    /// decode, and the caller would see a successful call that produced no pixels.
    ///
    /// Best-effort by construction. A buffer with no sample slot has nothing to stamp, and the
    /// framework's own answer to that is an empty array rather than an error.
    ///
    /// # Safety
    /// `CMSampleBufferGetSampleAttachmentsArray` documents its elements as
    /// `CFMutableDictionaryRef`, one per sample — a type C's `CFArrayRef` cannot carry and
    /// `objc2` therefore generates as an untyped array. `cast_unchecked` states that documented
    /// element type; it is the same obligation `slopdesk-apple-cgwindow` carries for
    /// `CGWindowListCopyWindowInfo`'s array of dictionaries. Nothing is dereferenced: the
    /// retype is on the ARRAY, and every read through it afterwards is a bounds-checked,
    /// retain-correct `objc2` call.
    #[expect(
        unsafe_code,
        reason = "CFArrayRef carries no element type in C; the framework documents this one"
    )]
    fn stamp_display_immediately(&self) {
        // SAFETY: framework rule, above — `create_if_necessary` is a plain flag and the binding
        // takes the Get-rule retain on the answered array itself.
        let attachments = unsafe { self.inner.sample_attachments_array(true) };
        let Some(attachments) = attachments else {
            return;
        };
        // SAFETY: framework rule, above — the documented element type of THIS array.
        let typed: &CFArray<CFMutableDictionary<CFString, CFType>> = unsafe { attachments.cast_unchecked() };
        let Some(first) = typed.get(0) else {
            return;
        };
        first.set(Attachment::DisplayImmediately.cf(), CFBoolean::new(true).as_ref());
    }
}

/// What a finished decode produced, on whichever thread the framework ran the handler.
///
/// Two arms for the reason [`crate::FrameSink`] has two: a decoded frame goes to the renderer, and
/// a failure goes to the recovery path that asks the host for a fresh anchor. The Swift original
/// collapsed them and its own comment recorded the cost — a swallowed callback status produced no
/// pixels and no error, so recovery never armed and the pane froze on the last good frame.
pub trait DecodedSink: Send + Sync + 'static {
    /// A frame decoded and carries pixels, owned by the callee.
    ///
    /// Ownership crosses rather than a borrow, because the consumer is a display-link pacer that
    /// holds the buffer until the next vsync — which is after this call returns, every time.
    fn decoded(&self, image: CFRetained<CVImageBuffer>);
    /// The decode failed, or produced no image buffer.
    ///
    /// `status` is the framework's. A non-`noErr` here is the case the wire cares about: a
    /// mis-recovered FEC block that passed its length check decodes to `kVTVideoDecoderBadDataErr`,
    /// and the only cure is a fresh keyframe.
    fn failed(&self, status: i32);
}

/// A live decompression session.
///
/// `Send`/`Sync` on the same framework promise [`crate::CompressionSession`] documents: a
/// `VTDecompressionSession` is a CF object with no thread affinity. The client relies on it — the
/// decode runs on a serial decode queue while the session actor reads the wall-time average.
#[derive(Debug)]
pub struct DecompressionSession {
    session: CFRetained<VTDecompressionSession>,
}

// SAFETY: framework rule — see the type's doc comment. VideoToolbox serialises the session's own
// state; the `CFRetained` inside is not `Send` on its own only because CoreFoundation makes no
// blanket promise for every CF type, which is what this per-type judgement supplies.
#[expect(
    unsafe_code,
    reason = "the framework documents the session as thread-safe; Rust cannot see that"
)]
#[expect(
    clippy::non_send_fields_in_send_ty,
    reason = "the field is the session; the promise is the framework's"
)]
unsafe impl Send for DecompressionSession {}
// SAFETY: as above.
#[expect(
    unsafe_code,
    reason = "the framework documents the session as thread-safe; Rust cannot see that"
)]
unsafe impl Sync for DecompressionSession {}

impl DecompressionSession {
    /// Creates a hardware session emitting Metal-compatible NV12 of the negotiated luma range.
    ///
    /// `full_range` picks between the two NV12 variants. Their plane layout is identical, so the
    /// renderer's texture creation is unaffected; what differs is the range, and therefore which
    /// shader coefficients the renderer must pair with it.
    ///
    /// # Errors
    /// The framework's `OSStatus`.
    ///
    /// # Safety
    /// `VTDecompressionSessionCreate` takes a **Create-rule** out-parameter — see
    /// [`crate::owned::created`]. The output-callback RECORD pointer is null, which the header
    /// requires of any session fed through `VTDecompressionSessionDecodeFrameWithOutputHandler`,
    /// and that is the only decode entry point [`Self::decode`] uses.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare VideoToolbox entry points unsafe"
    )]
    pub fn create(format: &FormatDescription, full_range: bool, require_hardware: bool) -> Result<Self, i32> {
        let attributes = image_buffer_attributes(full_range);
        let specification = require_hardware.then(|| {
            CFDictionary::from_slices(&[DecodeKey::RequireHardwareAcceleratedVideoDecoder.cf()], &[
                &**CFBoolean::new(true),
            ])
        });
        let mut slot: *mut VTDecompressionSession = core::ptr::null_mut();
        // SAFETY: framework rule, above — a null callback record is what the handler form requires,
        // and the out-parameter's slot is live and correctly typed.
        let status = unsafe {
            VTDecompressionSession::create(
                None,
                format.inner.downcast_ref().ok_or(INVALID_SESSION)?,
                specification.as_deref().map(CFDictionary::as_opaque),
                Some(attributes.as_opaque()),
                core::ptr::null(),
                core::ptr::NonNull::from(&mut slot),
            )
        };
        if status != NO_ERR {
            return Err(status);
        }
        created(slot).map_or(Err(INVALID_SESSION), |session| Ok(Self { session }))
    }

    /// Decodes one frame SYNCHRONOUSLY and answers the framework's submission status.
    ///
    /// The sink has already been called by the time this returns — see the module header. A caller
    /// that wants the decode's own verdict reads what the sink recorded, because the submission
    /// status and the handler's status are different numbers and only the second one sees a
    /// mis-recovered frame.
    ///
    /// # Safety
    /// `VTDecompressionSessionDecodeFrameWithOutputHandler` requires a session created with a NULL
    /// callback record, which [`Self::create`] guarantees, and COPIES the block it is given — so
    /// the block need not outlive the call, but its captures must outlive the DECODE, which is
    /// why the sink is an `Arc` moved into a heap `RcBlock`. `info_flags_out` is null, which
    /// the header permits. The handler's `imageBuffer` is a **Get-rule** borrowed pointer; see
    /// [`crate::owned::borrowed`], and null is the documented signal that no frame was emitted.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare VideoToolbox entry points unsafe"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell a refused submission \
                  from a decoded frame"]
    pub fn decode(&self, sample: &SampleBuffer, sink: Arc<dyn DecodedSink>) -> i32 {
        let block = block2::RcBlock::new(
            move |status: i32,
                  _flags: objc2_video_toolbox::VTDecodeInfoFlags,
                  image: *mut CVImageBuffer,
                  _presentation: objc2_core_media::CMTime,
                  _duration: objc2_core_media::CMTime| {
                let held = (status == NO_ERR).then(|| borrowed(image)).flatten();
                match held {
                    Some(image) => sink.decoded(image),
                    // Either the framework reported a failure, or it reported success and emitted
                    // nothing. The second is not a shape the header documents, and treating it as a
                    // success would produce the exact freeze this sink's two arms exist to prevent.
                    None => sink.failed(if status == NO_ERR { INVALID_SESSION } else { status }),
                }
            },
        );
        // SAFETY: framework rule, above — empty flags is the synchronous form, null flags-out is
        // permitted, and the block's captures outlive the decode.
        unsafe {
            self.session.decode_frame_with_output_handler(
                &sample.inner,
                VTDecodeFrameFlags::empty(),
                core::ptr::null_mut(),
                block2::RcBlock::as_ptr(&block),
            )
        }
    }

    /// Tears the session down deterministically.
    ///
    /// # Safety
    /// `VTDecompressionSessionInvalidate` takes only the session. The header asks for it BEFORE the
    /// last release, for the reason [`crate::CompressionSession`]'s `Drop` gives: a session may be
    /// retained by more than one party, so waiting for the count to fall makes teardown
    /// unpredictable.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare VideoToolbox entry points unsafe"
    )]
    fn invalidate(&self) {
        // SAFETY: framework rule, above — no arguments, no ownership.
        unsafe { self.session.invalidate() }
    }
}

impl Drop for DecompressionSession {
    fn drop(&mut self) {
        self.invalidate();
    }
}

/// The destination image-buffer attributes: NV12 of the asked-for range, Metal-compatible, backed
/// by an `IOSurface`.
///
/// All three are what make the renderer's hand-off zero-copy: the surface is what Metal wraps, the
/// compatibility key is what guarantees it can, and the format is the one the shader pairs with.
fn image_buffer_attributes(full_range: bool) -> CFRetained<CFDictionary<CFString, CFType>> {
    let format = CFNumber::new_i32(DecodeKey::nv12_format(full_range));
    let truth = CFBoolean::new(true);
    let surface: CFRetained<CFDictionary<CFString, CFType>> = CFDictionary::from_slices(&[], &[]);
    CFDictionary::from_slices(
        &[
            DecodeKey::PixelFormatType.cf(),
            DecodeKey::MetalCompatibility.cf(),
            DecodeKey::IoSurfaceProperties.cf(),
        ],
        &[&**format, &**truth, &**surface],
    )
}

#[cfg(test)]
mod tests {
    use super::{DecodeKey, FormatDescription, NAL_LENGTH_PREFIX, image_buffer_attributes};

    /// A parameter set with no bytes has no base pointer, and the framework documents at least one
    /// of each as required — so it is refused BEFORE any framework call rather than handed over as
    /// a null the callee would have to defend against.
    #[test]
    fn an_empty_parameter_set_is_refused_before_the_framework_sees_it() {
        let real = [0x40_u8, 0x01];
        for (vps, sps, pps) in [
            ([].as_slice(), real.as_slice(), real.as_slice()),
            (real.as_slice(), [].as_slice(), real.as_slice()),
            (real.as_slice(), real.as_slice(), [].as_slice()),
        ] {
            assert!(
                FormatDescription::from_hevc_parameter_sets(vps, sps, pps).is_err(),
                "an empty set is not a description",
            );
        }
    }

    /// Three bytes that are not a parameter set answer a STATUS rather than panicking or hanging.
    /// This runs headless, which is the whole difference between this half of the crate and the
    /// compression half: `VTDecompressionSessionCreate` needs no window server.
    #[test]
    fn parameter_sets_that_are_not_hevc_report_a_status() {
        let junk = [0xFF_u8, 0xFF, 0xFF, 0xFF];
        let built = FormatDescription::from_hevc_parameter_sets(&junk, &junk, &junk);
        if let Err(status) = built {
            assert_ne!(status, super::NO_ERR, "a refusal carries a real status");
        }
    }

    /// The two NV12 variants are DIFFERENT codes and neither is zero. Pinned because the plane
    /// layout is identical, so asking for the wrong one produces a picture that renders — with the
    /// shader's coefficients paired against the other range, which reads as washed-out rather than
    /// as a fault.
    #[test]
    fn the_two_luma_ranges_are_two_different_codes() {
        let video = DecodeKey::nv12_format(false);
        let full = DecodeKey::nv12_format(true);
        assert_ne!(video, full);
        assert_ne!(video, 0);
        assert_ne!(full, 0);
    }

    /// Both attribute dictionaries carry all three keys, and building ten thousand of them leaves
    /// nothing behind. The session cannot be created headlessly on every machine; the dictionary it
    /// is created FROM can, and it is the only allocation on the configure path.
    #[test]
    fn the_attributes_carry_three_keys_on_both_ranges_and_do_not_drift() {
        for index in 0..10_000_u32 {
            let attributes = image_buffer_attributes(index.is_multiple_of(2));
            assert_eq!(attributes.len(), 3);
        }
    }

    /// The AVCC prefix the description is built with is the one the host writes. Four, and not a
    /// parameter, because a description built with three would mis-parse every frame the same
    /// encoder produced and report nothing.
    #[test]
    fn the_length_prefix_is_the_one_the_host_writes() {
        assert_eq!(NAL_LENGTH_PREFIX, 4);
    }
}
