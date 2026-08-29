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
    CMBlockBuffer, CMFormatDescription, CMSampleBuffer, CMVideoFormatDescriptionCreateFromH264ParameterSets,
    CMVideoFormatDescriptionCreateFromHEVCParameterSets, CMVideoFormatDescriptionGetDimensions,
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

/// Which framework entry point turns parameter sets into a description.
///
/// Two arms because Core Media has two functions, not because the caller has a preference: the
/// H.264 one takes no `extensions` argument and the HEVC one does, so no amount of wishing makes
/// them one call. Everything AROUND them — flattening the sets into parallel arrays, refusing an
/// empty one, taking the Create rule on the answer — is identical, which is why that part is
/// written once in [`FormatDescription::from_parameter_sets`] and this enum is the only fork.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParameterSetCodec {
    /// H.264, via `CMVideoFormatDescriptionCreateFromH264ParameterSets`.
    H264,
    /// HEVC (H.265), via `CMVideoFormatDescriptionCreateFromHEVCParameterSets`.
    Hevc,
}

/// A `CMVideoFormatDescription`, built from the parameter sets a stream carries.
///
/// Three streams reach this type and they carry their sets three ways, which is exactly why the
/// building is here and the finding is not: the desktop host streams raw AVCC with no out-of-band
/// sets, so this is rebuilt from the bytes of every keyframe whose sets DIFFER from the running
/// ones (a decision one crate over, because a byte-identical heartbeat IDR arriving once a second
/// must not tear the session down); the simulator server sends an avcC record once; and the Android
/// bridge forwards `MediaCodec`'s Annex-B config packet. Each caller parses its own dialect and
/// arrives here with the same thing — a list of parameter-set payloads and a length prefix.
#[derive(Debug)]
pub struct FormatDescription {
    inner: CFRetained<CMFormatDescription>,
}

impl FormatDescription {
    /// Builds the description from three parameter-set payloads, in VPS/SPS/PPS order.
    ///
    /// The desktop stream's shape, and the one place [`NAL_LENGTH_PREFIX`] is pinned rather than
    /// passed: the host writes those four bytes, so a caller free to say three could build a
    /// description that silently mis-parses every frame that same encoder produced.
    ///
    /// # Errors
    /// The framework's `OSStatus`. A description that cannot be built from a keyframe's sets means
    /// the keyframe is not one the decoder can anchor on, which the caller reports as needing
    /// another.
    pub fn from_hevc_parameter_sets(vps: &[u8], sps: &[u8], pps: &[u8]) -> Result<Self, i32> {
        let sets: [&[u8]; PARAMETER_SET_COUNT] = [vps, sps, pps];
        Self::from_parameter_sets(ParameterSetCodec::Hevc, &sets, NAL_LENGTH_PREFIX)
    }

    /// Builds the description from however many parameter sets the stream carried.
    ///
    /// `nal_length` is the stream's own AVCC length prefix — 1, 2 or 4 — and it is an ARGUMENT here
    /// where [`Self::from_hevc_parameter_sets`] pins it, because the simulator's avcC record states
    /// it in a field and a stream is entitled to say two. The description and the byte stream have
    /// to agree; the difference between the two constructors is only WHO knows the right answer.
    ///
    /// # Errors
    /// The framework's `OSStatus`, or [`INVALID_SESSION`] for a set list this refuses before the
    /// framework sees it: no sets at all, or one that is empty.
    ///
    /// # Safety
    /// Both `CMVideoFormatDescriptionCreateFrom*ParameterSets` take parallel pointer and size
    /// arrays and read `parameter_set_count` entries from each. Both arrays are built here, from
    /// the slices the caller lent, and are live for the call; every pointer in them is the base of
    /// a non-empty slice, which is what refusing an empty set guarantees. The description is a
    /// **Create-rule** out-parameter — see [`crate::owned::created`].
    ///
    /// The framework COPIES the parameter-set bytes into the description, which is why the slices
    /// need only outlive this call and the caller may drop them immediately after.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare CoreMedia entry points unsafe"
    )]
    pub fn from_parameter_sets(
        codec: ParameterSetCodec,
        sets: &[&[u8]],
        nal_length: i32,
    ) -> Result<Self, i32> {
        // No sets is not a stream this can describe, and the framework's own answer to a count of
        // zero is undefined rather than an error — so it is refused here, where the cause is named.
        if sets.is_empty() {
            return Err(INVALID_SESSION);
        }
        let mut pointers: Vec<core::ptr::NonNull<u8>> = Vec::with_capacity(sets.len());
        let mut sizes: Vec<usize> = Vec::with_capacity(sets.len());
        for set in sets {
            // An empty parameter set has no base pointer worth passing, and the framework documents
            // at least one of each as required — so this is the caller's malformed config packet,
            // not a decode failure, and it is refused before any framework call.
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
        // SAFETY: framework rule, above — `sets.len()` live parallel entries in each array, a count
        // that matches, and a live out-slot of the declared type.
        let status = unsafe {
            match codec {
                ParameterSetCodec::H264 => {
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        None,
                        sets.len(),
                        pointer_base,
                        size_base,
                        nal_length,
                        core::ptr::NonNull::from(&mut slot),
                    )
                },
                ParameterSetCodec::Hevc => {
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        None,
                        sets.len(),
                        pointer_base,
                        size_base,
                        nal_length,
                        None,
                        core::ptr::NonNull::from(&mut slot),
                    )
                },
            }
        };
        if status != NO_ERR {
            return Err(status);
        }
        created(slot.cast_mut()).map_or(Err(INVALID_SESSION), |inner| Ok(Self { inner }))
    }

    /// The stream's encoded pixel dimensions, as `(width, height)`.
    ///
    /// Read off the DESCRIPTION rather than any session header a device advertised, and every
    /// caller wants it for the same reason: the encoded frame is routinely smaller than the device
    /// (`--scale` on the simulator, `max_size` on the Android bridge), and it is the FRAME a view
    /// has to fit. A header that agrees today is a header that can disagree tomorrow.
    ///
    /// # Safety
    /// `CMVideoFormatDescriptionGetDimensions` reads two fields out of a description it borrows for
    /// the call and returns them by value. Nothing is allocated, nothing is retained, and the
    /// borrow is `&self`.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare CoreMedia entry points unsafe"
    )]
    #[must_use]
    pub fn dimensions(&self) -> (i32, i32) {
        // SAFETY: framework rule, above — a live description, borrowed for the length of the call.
        let dimensions = unsafe { CMVideoFormatDescriptionGetDimensions(&self.inner) };
        (dimensions.width, dimensions.height)
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

/// What a sample's attachment dictionary says about it, before anyone consumes it.
///
/// Two flags rather than one because the two consumers read different things.
/// A `VTDecompressionSession` decodes what it is handed and takes sync-ness from the bitstream, so
/// the decoder path sets [`Self::display_immediately`] alone and leaves [`Self::not_sync`] false —
/// which is what it did before this struct existed, and stating it that way is the point.
/// `AVSampleBufferDisplayLayer` schedules, so the device panels must tell it which frames are not
/// anchors; a layer that treated every delta as a sync point would try to start from one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Attachments {
    /// `kCMSampleAttachmentKey_DisplayImmediately` — emit on decode rather than hold for reorder.
    pub display_immediately: bool,
    /// `kCMSampleAttachmentKey_NotSync` — this frame is not a keyframe and cannot be started from.
    pub not_sync: bool,
}

impl SampleBuffer {
    /// Wraps `avcc` against `format`, stamped with `attachments`.
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
    pub fn from_avcc(avcc: &[u8], format: &FormatDescription, attachments: Attachments) -> Result<Self, i32> {
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
        buffer.stamp(attachments);
        Ok(buffer)
    }

    /// Hands the buffer over at **+1**, for a caller on the other side of the C ABI.
    ///
    /// The Create rule, pointed outwards. `CFRetained` is consumed rather than dropped, so the
    /// retain it holds becomes the receiver's and this side keeps nothing — which makes the
    /// receiver's release the one that frees it. Swift spells that release `takeRetainedValue()`,
    /// the same term [`crate::DecodedSink::decoded`]'s pixels already cross under; a caller that
    /// spelled it `takeUnretainedValue()` would leak one sample buffer per frame.
    ///
    /// There is no matching `from_raw` and there must not be: ownership goes OUT here, so this is
    /// not one of `docs/57` §2's two counted `CFRetained::from_raw` admissions.
    #[must_use]
    pub fn into_raw(self) -> *mut CMSampleBuffer {
        CFRetained::into_raw(self.inner).as_ptr()
    }

    /// Writes [`Attachments`] onto the sample's first (and only) attachment dictionary.
    ///
    /// `DisplayImmediately` means "present the instant you decode it, rather than holding it for
    /// reorder". On the desktop decode path the encoder already sets `AllowFrameReordering` false,
    /// so a correct SPS declares no reorder capacity and this changes nothing; it is set anyway
    /// because the failure it prevents is silent — a decoder that still advertised capacity would
    /// hold the frame inside a synchronous decode, and the caller would see a successful call that
    /// produced no pixels. On the device panels there is no such encoder to trust, and the same
    /// flag is what makes an interactive mirror show the tap rather than smooth it.
    ///
    /// `NotSync` is the device panels' alone: it tells `AVSampleBufferDisplayLayer` which frames
    /// are not anchors, a question a `VTDecompressionSession` answers from the bitstream instead.
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
    fn stamp(&self, attachments: Attachments) {
        // Nothing to say is nothing to allocate: `create_if_necessary` below would make the array
        // the framework had not needed, and the decoder path asks for neither flag on most frames.
        if !attachments.display_immediately && !attachments.not_sync {
            return;
        }
        // SAFETY: framework rule, above — `create_if_necessary` is a plain flag and the binding
        // takes the Get-rule retain on the answered array itself.
        let array = unsafe { self.inner.sample_attachments_array(true) };
        let Some(array) = array else {
            return;
        };
        // SAFETY: framework rule, above — the documented element type of THIS array.
        let typed: &CFArray<CFMutableDictionary<CFString, CFType>> = unsafe { array.cast_unchecked() };
        let Some(first) = typed.get(0) else {
            return;
        };
        // Both keys are set only when TRUE. Core Media reads "absent" as false for each, so an
        // explicit false would be the same answer spelled twice, and a delta frame that carried
        // `NotSync = false` would claim to be an anchor it is not.
        if attachments.display_immediately {
            first.set(Attachment::DisplayImmediately.cf(), CFBoolean::new(true).as_ref());
        }
        if attachments.not_sync {
            first.set(Attachment::NotSync.cf(), CFBoolean::new(true).as_ref());
        }
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
#[expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report — the same relaxation every crate in this family \
              takes over its own tests"
)]
mod tests {
    use objc2_core_foundation::{CFArray, CFMutableDictionary, CFString, CFType};
    use objc2_core_media::CMBlockBuffer;

    use super::{
        Attachment, Attachments, DecodeKey, FormatDescription, NAL_LENGTH_PREFIX, NO_ERR, ParameterSetCodec,
        SampleBuffer, image_buffer_attributes,
    };

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
            assert_ne!(status, NO_ERR, "a refusal carries a real status");
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

    // ---- The H.264 half, and the sample buffer the device panels enqueue --------------------- //
    //
    // The fixtures below are MEASURED off a live `baguette serve` streaming an iPhone 17 Pro,
    // carried over from the Swift suite this replaced: the parameter sets verbatim, and access
    // units of the observed shape. A synthetic SPS would prove only that the parser agrees with
    // itself; these prove CoreMedia accepts what a real device actually sends.

    /// The measured SPS: High profile, level 5.1 — `avc1.640033`, hardware-decodable.
    const MEASURED_SPS: [u8; 22] = [
        0x27, 0x64, 0x00, 0x33, 0xAC, 0x13, 0x14, 0x3C, 0x04, 0xC0, 0x14, 0x9E, 0x6A, 0x9A, 0x81, 0x01, 0x01,
        0x03, 0xC2, 0x01, 0x08, 0xF8,
    ];
    /// The measured PPS from the same record.
    const MEASURED_PPS: [u8; 4] = [0x28, 0xEE, 0x3C, 0xB0];

    fn measured_format() -> FormatDescription {
        FormatDescription::from_parameter_sets(
            ParameterSetCodec::H264,
            &[MEASURED_SPS.as_slice(), MEASURED_PPS.as_slice()],
            NAL_LENGTH_PREFIX,
        )
        .expect("the measured record describes a real stream")
    }

    /// One access unit of the observed shape: a four-byte big-endian length, then that many bytes.
    fn access_unit(payload: usize) -> Vec<u8> {
        let mut unit = Vec::with_capacity(4 + payload);
        unit.extend_from_slice(&u32::try_from(payload).expect("a test payload fits").to_be_bytes());
        unit.extend(core::iter::repeat_n(0x41, payload));
        unit
    }

    /// The end-to-end claim of this layer: the bytes a device sends make a real description, and
    /// the DIMENSIONS come out of the SPS — so a wrong parse shows up here as a wrong
    /// resolution rather than as a silent decode failure a stream later.
    #[test]
    fn the_measured_h264_sets_describe_the_device_resolution() {
        assert_eq!(measured_format().dimensions(), (1206, 2622));
    }

    /// No sets at all is refused before the framework sees it — a count of zero is undefined there,
    /// not an error, so the refusal has to be ours.
    #[test]
    fn no_parameter_sets_is_refused_before_the_framework_sees_it() {
        assert!(
            FormatDescription::from_parameter_sets(ParameterSetCodec::H264, &[], NAL_LENGTH_PREFIX).is_err()
        );
    }

    /// The untrusted-input rule reaching PAST our own parser: a well-formed wrapper can still carry
    /// a nonsense SPS, and the answer must be a status rather than a description that decodes
    /// noise.
    #[test]
    fn garbage_h264_sets_are_refused_by_the_framework_rather_than_trusted() {
        let junk = [0xFF_u8; 4];
        assert!(
            FormatDescription::from_parameter_sets(
                ParameterSetCodec::H264,
                &[junk.as_slice(), junk.as_slice()],
                NAL_LENGTH_PREFIX,
            )
            .is_err()
        );
    }

    /// The two codecs are two ENTRY POINTS, and they do not accept each other's bytes: H.264
    /// parameter sets built as HEVC is a description of nothing, and the framework says so.
    #[test]
    fn h264_sets_are_not_an_hevc_description() {
        assert!(
            FormatDescription::from_parameter_sets(
                ParameterSetCodec::Hevc,
                &[MEASURED_SPS.as_slice(), MEASURED_PPS.as_slice()],
                NAL_LENGTH_PREFIX,
            )
            .is_err()
        );
    }

    /// A sample carries the unit's bytes, one sample, against the description it was built for.
    #[expect(unsafe_code, reason = "objc2 generates every CMSampleBuffer accessor unsafe")]
    #[test]
    fn an_access_unit_becomes_a_sample_carrying_its_bytes() {
        let format = measured_format();
        let unit = access_unit(64);
        let sample = SampleBuffer::from_avcc(&unit, &format, Attachments::default())
            .expect("a well-formed unit wraps");
        // SAFETY: framework rule — three reads off a live sample, none of which take ownership.
        unsafe {
            assert_eq!(sample.inner.num_samples(), 1);
            assert_eq!(sample.inner.total_sample_size(), unit.len());
            assert!(sample.inner.is_valid());
        }
    }

    /// CORE MEDIA OWNS THE BYTES. The access unit's buffer dies with the receive callback while the
    /// sample lives on in the display layer's queue, so a block buffer that POINTED at the caller's
    /// storage would be a use-after-free showing up as intermittent corrupt frames. Wiping the
    /// source after the wrap is what proves the copy happened.
    #[expect(
        unsafe_code,
        reason = "reading the block buffer's own pointer is the only way to prove it is not ours"
    )]
    #[test]
    fn the_sample_owns_a_copy_rather_than_pointing_at_caller_memory() {
        let format = measured_format();
        let mut unit = access_unit(32);
        let sample = SampleBuffer::from_avcc(&unit, &format, Attachments::default()).expect("a unit wraps");
        unit.fill(0);

        // SAFETY: framework rule — a Get-rule read off a live sample; the binding takes the retain.
        let block = unsafe { sample.inner.data_buffer() }.expect("a ready sample has a block buffer");
        let mut length = 0_usize;
        let mut pointer: *mut core::ffi::c_char = core::ptr::null_mut();
        // SAFETY: framework rule — `CMBlockBufferGetDataPointer` writes through the two out-slots,
        // which are live locals, and lends a pointer valid while `block` is alive. Offset 4 is
        // inside a 36-byte block, and only ONE byte is read through it.
        let status = unsafe {
            CMBlockBuffer::data_pointer(
                &block,
                4,
                core::ptr::NonNull::from(&mut length).as_ptr(),
                core::ptr::null_mut(),
                core::ptr::NonNull::from(&mut pointer).as_ptr(),
            )
        };
        assert_eq!(status, NO_ERR);
        // 0x41 is the fill the unit was built with; a zero would mean the wipe reached the sample.
        // SAFETY: `pointer` is the framework's own, non-null on a `noErr` answer, and valid for
        // `length` bytes while `block` is alive — which is this whole scope.
        assert_eq!(unsafe { *pointer }.cast_unsigned(), 0x41);
    }

    /// Both attachments, on the axis each one is about. `DisplayImmediately` is unconditional on
    /// the panel path; `NotSync` is present only on a delta frame, because "absent" is the
    /// framework's own spelling of false and a keyframe claiming `NotSync = false` would be
    /// saying it twice.
    #[test]
    fn the_two_attachments_are_written_only_when_true() {
        let format = measured_format();
        for not_sync in [false, true] {
            let attachments = Attachments {
                display_immediately: true,
                not_sync,
            };
            let sample =
                SampleBuffer::from_avcc(&access_unit(16), &format, attachments).expect("a unit wraps");
            // SAFETY: framework rule — `create_if_necessary` false borrows what is already there.
            #[expect(unsafe_code, reason = "the attachments accessor is generated unsafe")]
            let array = unsafe { sample.inner.sample_attachments_array(false) }
                .expect("a stamped sample has an array");
            // SAFETY: framework rule — the documented element type of THIS array, as `stamp` states.
            #[expect(unsafe_code, reason = "CFArrayRef carries no element type in C")]
            let typed: &CFArray<CFMutableDictionary<CFString, CFType>> = unsafe { array.cast_unchecked() };
            let first = typed.get(0).expect("one sample, one dictionary");
            assert!(
                first.get(Attachment::DisplayImmediately.cf()).is_some(),
                "an interactive mirror never holds a frame back for reorder",
            );
            assert_eq!(
                first.get(Attachment::NotSync.cf()).is_some(),
                not_sync,
                "NotSync is present exactly when the frame is not an anchor",
            );
        }
    }

    /// Nothing to say is nothing to allocate: the decoder path asks for neither flag on most
    /// frames, and `create_if_necessary` would have made the array the framework had not
    /// needed.
    #[test]
    fn a_sample_with_no_attachments_asked_for_allocates_no_array() {
        let format = measured_format();
        let sample =
            SampleBuffer::from_avcc(&access_unit(16), &format, Attachments::default()).expect("a unit wraps");
        // SAFETY: framework rule — `create_if_necessary` false only borrows what is already there.
        #[expect(unsafe_code, reason = "the attachments accessor is generated unsafe")]
        let array = unsafe { sample.inner.sample_attachments_array(false) };
        assert!(array.is_none_or(|array| array.is_empty()));
    }

    /// The +1 handoff, and its price when nobody pays it: a raw pointer this side no longer owns.
    /// Reclaiming it here is what Swift's `takeRetainedValue()` is, and the loop is the leak test —
    /// ten thousand rounds of wrap-and-release under the same description.
    ///
    /// The reclaim goes through [`crate::owned::created`] rather than spelling
    /// `CFRetained::from_raw` here, and that is the §2 cap working as written rather than a way
    /// around it: `into_raw` is the Create rule pointed OUTWARDS, so taking the pointer back is
    /// the same obligation the helper already argues once for the whole crate.
    #[test]
    fn into_raw_hands_over_and_a_reclaim_releases() {
        let format = measured_format();
        for _ in 0..10_000 {
            let raw = SampleBuffer::from_avcc(&access_unit(16), &format, Attachments::default())
                .expect("a unit wraps")
                .into_raw();
            // SAFETY: framework rule — `into_raw` just handed this over at +1 and kept nothing, so
            // this reconstitutes the unique owner, exactly once per pointer.
            let reclaimed = crate::owned::created(raw);
            assert!(reclaimed.is_some(), "a built sample is never null");
            drop(reclaimed);
        }
    }
}
