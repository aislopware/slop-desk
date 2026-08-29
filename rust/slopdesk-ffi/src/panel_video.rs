//! One device panel's video stream, from a config packet to the sample buffers a display layer
//! eats.
//!
//! ## What this is instead of
//! Three Swift files — `AndroidVideoFormat`, `SimulatorVideoFormat` and the
//! `DevicePanelSampleBuffer` they shared — built `CMVideoFormatDescription`, `CMBlockBuffer` and
//! `CMSampleBuffer` by hand, with the same three framework calls in the same order that
//! `slopdesk-apple-vt` was already making for the desktop decoder. That is the duplication
//! `CLAUDE.md`'s "one implementation, never two languages" names, and it had the shape that rule
//! warns about: the Swift copy carried its own `unsafeBitCast` on the attachment array, so a
//! framework contract was being discharged twice, in two languages, with only one of them tested
//! under Miri-adjacent scrutiny.
//!
//! What is left in Swift after this module is `layer.enqueue(sample)` — an
//! `AVSampleBufferDisplayLayer` call, which is presentation, which is the floor.
//!
//! ## Why a HANDLE rather than free functions
//! The format description outlives the frame. A stream is configured once and then fed thousands of
//! access units, every one of which must be wrapped against THAT description — so somebody holds it
//! between calls, and the only two candidates are this handle or a Swift property. A Swift property
//! would be a `CMVideoFormatDescription` living in Swift, which is exactly the type this module
//! exists to stop Swift from naming.
//!
//! ## The two configure doors, and why they are two
//! Both panels end at the same place and start from different bytes. The simulator server is asked
//! for `format=avcc` and sends an avcC record, which states its own NAL length prefix in a field.
//! `scrcpy` forwards raw `MediaCodec` output, so the parameter sets arrive as Annex-B NAL units and
//! the prefix is whatever the rewrite writes — four bytes, because
//! [`crate::annexb::slopdesk_annexb_to_avcc`] writes four. Each door parses its own dialect with
//! the parser that already existed for it and then calls the ONE builder.
//!
//! ## The sample buffer crosses at +1
//! [`slopdesk_panel_video_sample`] hands over a retained `CMSampleBuffer`, the same Create-rule
//! handoff [`crate::decoder`]'s pixel buffers already cross under. Swift's `takeRetainedValue()` IS
//! the matching release; `takeUnretainedValue()` there would leak one sample buffer per frame.

use core::ffi::{c_uchar, c_void};
use std::sync::Mutex;

use slopdesk_apple_vt::{Attachments, FormatDescription, ParameterSetCodec, SampleBuffer};
use slopdesk_devicepanel::sim_stream::parse_avc_configuration;
use slopdesk_video::annexb;

use crate::borrow;

/// The AVCC length prefix an Annex-B rewrite writes, in bytes.
///
/// Four, and not an argument: [`crate::annexb::slopdesk_annexb_to_avcc`] is what produces the
/// frames this description will be matched against, and it writes four. A caller free to pass three
/// could build a description that silently mis-parses every frame from the same stream.
const ANNEXB_REWRITE_PREFIX: i32 = 4;

/// One panel stream's `CoreMedia` state: the description its config packet described, or none yet.
///
/// `Mutex` rather than a bare field because the handle crosses a C ABI, where nothing stops two
/// threads from holding a copy of the pointer. In practice both panels drive it from the main
/// thread; the lock costs an uncontended atomic per frame and removes the question.
#[derive(Debug)]
pub struct SlopDeskPanelVideo {
    format: Mutex<Option<FormatDescription>>,
}

impl SlopDeskPanelVideo {
    /// Replaces the running description, answering whether one was built.
    ///
    /// A refusal leaves the PREVIOUS description in place. A malformed config packet mid-stream is
    /// a reason to keep showing frames against the description that was working, not a reason to
    /// stop showing anything.
    fn adopt(&self, built: Result<FormatDescription, i32>) -> bool {
        let Ok(format) = built else {
            return false;
        };
        let Ok(mut guard) = self.format.lock() else {
            return false;
        };
        *guard = Some(format);
        true
    }
}

/// Creates a panel stream. It has no format description until a config packet gives it one.
///
/// # Safety
/// The answer must be passed to [`slopdesk_panel_video_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_panel_video_new() -> *mut SlopDeskPanelVideo {
    Box::into_raw(Box::new(SlopDeskPanelVideo {
        format: Mutex::new(None),
    }))
}

/// Tears a panel stream down, releasing the format description it holds.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_panel_video_new`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_video_free(handle: *mut SlopDeskPanelVideo) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `new` with no call in
    // flight — so this reconstitutes the unique owner. The description's release is its `Drop`.
    drop(unsafe { Box::from_raw(handle) });
}

/// Borrows a handle for the length of one call.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_panel_video_new`].
#[expect(
    unsafe_code,
    reason = "reconstituting a borrow from a raw handle is the door convention"
)]
const unsafe fn held<'a>(handle: *const SlopDeskPanelVideo) -> Option<&'a SlopDeskPanelVideo> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — the one field behind it is guarded,
    // so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// Configures the stream from a simulator avcC record; `false` leaves the running description.
///
/// H.264 always: the simulator server's stream dialect has one codec, and the record's own
/// `nalUnitHeaderLength` field is honoured rather than assumed — every observed stream says four,
/// and a wrong guess decodes as garbage instead of failing loudly.
///
/// # Safety
/// [`held`]'s, plus `(record, len)` must be null-with-zero-length or `len` readable bytes for the
/// duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_video_configure_avcc(
    handle: *mut SlopDeskPanelVideo,
    record: *const c_uchar,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(stream) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let buffer = unsafe { borrow(record, len) };
    let Some(configuration) = parse_avc_configuration(buffer) else {
        return false;
    };
    let sets: Vec<&[u8]> = configuration.parameter_sets.iter().map(Vec::as_slice).collect();
    stream.adopt(FormatDescription::from_parameter_sets(
        ParameterSetCodec::H264,
        &sets,
        i32::from(configuration.nal_unit_header_length),
    ))
}

/// Configures the stream from an Annex-B config packet; `false` leaves the running description.
///
/// `hevc` picks which parameter-set walk reads the packet AND which framework entry point builds
/// the description, because the two must agree: an H.264 walk over an HEVC packet finds nothing,
/// and finding nothing is what this refuses.
///
/// # Safety
/// [`held`]'s, plus `(config, len)` must be null-with-zero-length or `len` readable bytes for the
/// duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_video_configure_annexb(
    handle: *mut SlopDeskPanelVideo,
    config: *const c_uchar,
    len: usize,
    hevc: bool,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(stream) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let buffer = unsafe { borrow(config, len) };
    let (spans, codec) = if hevc {
        (annexb::h265_parameter_sets(buffer), ParameterSetCodec::Hevc)
    } else {
        (annexb::h264_parameter_sets(buffer), ParameterSetCodec::H264)
    };
    // The walk answers WHERE each set sits; the bytes never left `buffer`. A span the walk produced
    // is in range by construction, and `get` rather than an index states that without asserting it.
    let sets: Vec<&[u8]> = spans.into_iter().filter_map(|span| buffer.get(span)).collect();
    stream.adopt(FormatDescription::from_parameter_sets(
        codec,
        &sets,
        ANNEXB_REWRITE_PREFIX,
    ))
}

/// The stream's encoded pixel dimensions; `false` — outputs untouched — before a config packet.
///
/// Read off the DESCRIPTION rather than any session header the device advertised: the encoded frame
/// is routinely smaller than the device (`--scale` on the simulator, `max_size` on the bridge), and
/// it is the frame the view has to fit.
///
/// # Safety
/// [`held`]'s, plus `width_out` and `height_out` must each be null or writable for one `int32_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_video_dimensions(
    handle: *mut SlopDeskPanelVideo,
    width_out: *mut i32,
    height_out: *mut i32,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(stream) = (unsafe { held(handle) }) else {
        return false;
    };
    let Ok(guard) = stream.format.lock() else {
        return false;
    };
    let Some(format) = guard.as_ref() else {
        return false;
    };
    let (width, height) = format.dimensions();
    if let Some(slot) = core::ptr::NonNull::new(width_out) {
        // SAFETY: the caller's obligation — non-null and writable for one `i32`.
        unsafe { slot.write(width) };
    }
    if let Some(slot) = core::ptr::NonNull::new(height_out) {
        // SAFETY: the caller's obligation — non-null and writable for one `i32`.
        unsafe { slot.write(height) };
    }
    true
}

/// Wraps one AVCC access unit as a `CMSampleBuffer` at **+1**; null when there is nothing to show.
///
/// Null covers all three refusals a caller treats the same way — no config packet has arrived yet,
/// the access unit is empty, or the framework declined — because the caller's response to each is
/// to drop the frame and wait for the next one.
///
/// Timing is deliberately ABSENT and `DisplayImmediately` set instead. Real presentation timestamps
/// against a control timebase buy smooth playback of a RECORDING and cost a frame of buffering;
/// both panels are an interactive mirror of a device someone is tapping, so the frame is worth more
/// than the smoothing. `is_keyframe` is stamped as its negation, `NotSync`, which is what tells the
/// display layer which frames it may start from.
///
/// # Safety
/// [`held`]'s, plus `(avcc, len)` must be null-with-zero-length or `len` readable bytes for the
/// duration of the call. The answer, when non-null, is a **retained** `CMSampleBufferRef` the
/// caller owns and must release exactly once — Swift's `takeRetainedValue()`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_panel_video_sample(
    handle: *mut SlopDeskPanelVideo,
    avcc: *const c_uchar,
    len: usize,
    is_keyframe: bool,
) -> *mut c_void {
    // SAFETY: the caller's obligation, above.
    let Some(stream) = (unsafe { held(handle) }) else {
        return core::ptr::null_mut();
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let buffer = unsafe { borrow(avcc, len) };
    if buffer.is_empty() {
        return core::ptr::null_mut();
    }
    let Ok(guard) = stream.format.lock() else {
        return core::ptr::null_mut();
    };
    let Some(format) = guard.as_ref() else {
        return core::ptr::null_mut();
    };
    let attachments = Attachments {
        display_immediately: true,
        not_sync: !is_keyframe,
    };
    SampleBuffer::from_avcc(buffer, format, attachments)
        .map_or_else(|_| core::ptr::null_mut(), |sample| sample.into_raw().cast())
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::expect_used,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use slopdesk_apple_vt::{CFRetained, CMSampleBuffer};

    use super::{
        SlopDeskPanelVideo, slopdesk_panel_video_configure_annexb, slopdesk_panel_video_configure_avcc,
        slopdesk_panel_video_dimensions, slopdesk_panel_video_free, slopdesk_panel_video_new,
        slopdesk_panel_video_sample,
    };

    /// The avcC record as it arrived off a live `baguette serve` streaming an iPhone 17 Pro:
    /// version 1, High profile, level 5.1, 4-byte NAL lengths, one 22-byte SPS and one 4-byte PPS.
    /// Measured, not synthesised — a made-up record would prove only that the parser agrees with
    /// itself.
    const MEASURED_AVCC: [u8; 37] = [
        0x01, 0x64, 0x00, 0x33, 0xFF, 0xE1, 0x00, 0x16, 0x27, 0x64, 0x00, 0x33, 0xAC, 0x13, 0x14, 0x3C, 0x04,
        0xC0, 0x14, 0x9E, 0x6A, 0x9A, 0x81, 0x01, 0x01, 0x03, 0xC2, 0x01, 0x08, 0xF8, 0x01, 0x00, 0x04, 0x28,
        0xEE, 0x3C, 0xB0,
    ];

    /// The same two sets as `scrcpy` would forward them: Annex-B start codes, no wrapper.
    fn measured_annexb() -> Vec<u8> {
        let mut packet = vec![0, 0, 0, 1];
        packet.extend_from_slice(&MEASURED_AVCC[8..30]);
        packet.extend_from_slice(&[0, 0, 0, 1]);
        packet.extend_from_slice(&MEASURED_AVCC[33..37]);
        packet
    }

    /// One access unit of the observed shape: a four-byte big-endian length, then that many bytes.
    fn access_unit(payload: usize) -> Vec<u8> {
        let mut unit = Vec::with_capacity(4 + payload);
        unit.extend_from_slice(&u32::try_from(payload).expect("a test payload fits").to_be_bytes());
        unit.extend(core::iter::repeat_n(0x41, payload));
        unit
    }

    /// Runs `body` against a fresh handle and frees it, so a failing assertion cannot leak one.
    fn with_stream(body: impl FnOnce(*mut SlopDeskPanelVideo)) {
        // SAFETY: the answer is freed exactly once, below, and nothing else holds the pointer.
        let handle = unsafe { slopdesk_panel_video_new() };
        assert!(
            !handle.is_null(),
            "a stream is an allocation, and one that failed is a dead process"
        );
        body(handle);
        // SAFETY: the pointer came from `new`, has not been freed, and no call is in flight.
        unsafe { slopdesk_panel_video_free(handle) };
    }

    /// Reclaims a +1 sample buffer — what Swift's `takeRetainedValue()` is, on this side.
    fn release(raw: *mut core::ffi::c_void) {
        let slot = core::ptr::NonNull::new(raw.cast::<CMSampleBuffer>()).expect("a built sample is not null");
        // SAFETY: the door just handed this over at +1 and kept nothing, so this reconstitutes the
        // unique owner — the Create rule's receiving half, exactly once per pointer.
        drop(unsafe { CFRetained::from_raw(slot) });
    }

    /// A stream with no config packet describes nothing and shows nothing. Both refusals matter:
    /// the panel mounts before the first packet lands, and every frame arriving in that window has
    /// to be dropped rather than wrapped against a description that does not exist.
    #[test]
    fn a_stream_with_no_configuration_refuses_dimensions_and_samples() {
        with_stream(|handle| {
            let (mut width, mut height) = (-1_i32, -1_i32);
            // SAFETY: a live handle and two live out-slots.
            assert!(!unsafe { slopdesk_panel_video_dimensions(handle, &raw mut width, &raw mut height) });
            assert_eq!((width, height), (-1, -1), "a refusal leaves the outputs alone");

            let unit = access_unit(16);
            // SAFETY: a live handle and a live buffer for the call.
            let sample = unsafe { slopdesk_panel_video_sample(handle, unit.as_ptr(), unit.len(), true) };
            assert!(sample.is_null());
        });
    }

    /// The end-to-end claim: the record a real device sends becomes a description whose dimensions
    /// are the device's, and an access unit then wraps against it. A wrong parse shows up here as a
    /// wrong resolution rather than as a silent decode failure a stream later.
    #[test]
    fn the_measured_record_configures_the_stream_and_frames_wrap() {
        with_stream(|handle| {
            // SAFETY: a live handle and a live record for the call.
            assert!(unsafe {
                slopdesk_panel_video_configure_avcc(handle, MEASURED_AVCC.as_ptr(), MEASURED_AVCC.len())
            });
            let (mut width, mut height) = (0_i32, 0_i32);
            // SAFETY: a live handle and two live out-slots.
            assert!(unsafe { slopdesk_panel_video_dimensions(handle, &raw mut width, &raw mut height) });
            assert_eq!((width, height), (1206, 2622));

            let unit = access_unit(64);
            for is_keyframe in [true, false] {
                // SAFETY: a live handle and a live buffer for the call.
                let sample =
                    unsafe { slopdesk_panel_video_sample(handle, unit.as_ptr(), unit.len(), is_keyframe) };
                release(sample);
            }
        });
    }

    /// The Annex-B door reaches the SAME description from the same sets in the other dialect. That
    /// is the whole reason both doors exist rather than one: two servers, two wrappers, one
    /// builder.
    #[test]
    fn the_annexb_packet_reaches_the_same_description() {
        with_stream(|handle| {
            let packet = measured_annexb();
            // SAFETY: a live handle and a live packet for the call.
            assert!(unsafe {
                slopdesk_panel_video_configure_annexb(handle, packet.as_ptr(), packet.len(), false)
            });
            let (mut width, mut height) = (0_i32, 0_i32);
            // SAFETY: a live handle and two live out-slots.
            assert!(unsafe { slopdesk_panel_video_dimensions(handle, &raw mut width, &raw mut height) });
            assert_eq!(
                (width, height),
                (1206, 2622),
                "the wrapper differs; the stream does not"
            );
        });
    }

    /// `hevc` picks BOTH the walk and the entry point, and they must agree: an HEVC walk over an
    /// H.264 packet finds nothing, and finding nothing is what this refuses.
    #[test]
    fn an_h264_packet_read_as_hevc_is_refused() {
        with_stream(|handle| {
            let packet = measured_annexb();
            // SAFETY: a live handle and a live packet for the call.
            assert!(!unsafe {
                slopdesk_panel_video_configure_annexb(handle, packet.as_ptr(), packet.len(), true)
            });
        });
    }

    /// A REFUSED config packet leaves the running description in place. A malformed packet
    /// mid-stream is a reason to keep showing frames against the one that was working, not a reason
    /// to stop showing anything — and this is the assertion that keeps that promise honest.
    #[test]
    fn a_refused_configuration_leaves_the_running_description() {
        with_stream(|handle| {
            // SAFETY: a live handle and a live record for the call.
            assert!(unsafe {
                slopdesk_panel_video_configure_avcc(handle, MEASURED_AVCC.as_ptr(), MEASURED_AVCC.len())
            });
            let junk = [0xFF_u8; 8];
            // SAFETY: a live handle and a live buffer for the call.
            assert!(!unsafe { slopdesk_panel_video_configure_avcc(handle, junk.as_ptr(), junk.len()) });

            let (mut width, mut height) = (0_i32, 0_i32);
            // SAFETY: a live handle and two live out-slots.
            assert!(unsafe { slopdesk_panel_video_dimensions(handle, &raw mut width, &raw mut height) });
            assert_eq!(
                (width, height),
                (1206, 2622),
                "the description that was working survived"
            );
        });
    }

    /// An empty access unit is nothing to show, and it is refused before the framework sees it —
    /// `CMBlockBufferCreateWithMemoryBlock` of zero length is not an error the caller could read.
    #[test]
    fn an_empty_access_unit_makes_no_sample() {
        with_stream(|handle| {
            // SAFETY: a live handle and a live record for the call.
            assert!(unsafe {
                slopdesk_panel_video_configure_avcc(handle, MEASURED_AVCC.as_ptr(), MEASURED_AVCC.len())
            });
            // SAFETY: a live handle and the null-with-zero-length pair the doors accept.
            let sample = unsafe { slopdesk_panel_video_sample(handle, core::ptr::null(), 0, true) };
            assert!(sample.is_null());
        });
    }

    /// Every door tolerates a null handle rather than dereferencing one. A view whose stream failed
    /// to allocate still gets its frames, and dropping them is the whole of what it may do.
    #[test]
    fn every_door_tolerates_a_null_handle() {
        let (mut width, mut height) = (0_i32, 0_i32);
        // SAFETY: a null handle is the documented input here; the out-slots are live locals.
        unsafe {
            assert!(!slopdesk_panel_video_configure_avcc(
                core::ptr::null_mut(),
                MEASURED_AVCC.as_ptr(),
                MEASURED_AVCC.len()
            ));
            assert!(!slopdesk_panel_video_configure_annexb(
                core::ptr::null_mut(),
                MEASURED_AVCC.as_ptr(),
                MEASURED_AVCC.len(),
                false
            ));
            assert!(!slopdesk_panel_video_dimensions(
                core::ptr::null_mut(),
                &raw mut width,
                &raw mut height
            ));
            assert!(slopdesk_panel_video_sample(core::ptr::null_mut(), core::ptr::null(), 0, true).is_null());
            slopdesk_panel_video_free(core::ptr::null_mut());
        }
    }

    /// The +1 handoff under repetition, which is the leak test this door owes: ten thousand rounds
    /// of wrap-and-release against one description. A door that handed back a borrowed pointer, or
    /// a reclaim that took the wrong side of the contract, shows up here and nowhere else.
    #[test]
    fn ten_thousand_samples_wrap_and_release() {
        with_stream(|handle| {
            // SAFETY: a live handle and a live record for the call.
            assert!(unsafe {
                slopdesk_panel_video_configure_avcc(handle, MEASURED_AVCC.as_ptr(), MEASURED_AVCC.len())
            });
            let unit = access_unit(16);
            for index in 0..10_000_u32 {
                // SAFETY: a live handle and a live buffer for the call.
                let sample = unsafe {
                    slopdesk_panel_video_sample(handle, unit.as_ptr(), unit.len(), index.is_multiple_of(60))
                };
                release(sample);
            }
        });
    }
}
