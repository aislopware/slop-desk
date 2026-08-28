//! The audio codec's doors: a capture buffer becomes wire payloads, a wire payload becomes samples.
//!
//! The Swift host's audio stream encoder and `Sources/SlopDeskVideoClient/AudioStreamDecoder.swift`
//! were 640 lines of `AudioConverter` calls wrapped around about forty lines of rule. Not one of
//! those calls is left: the encoding half went with the video host's port to Rust, and what remains
//! of the decoder is a face. Three crates meet at this door:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::audio_source`] | the block cadence, the stereo fold, the `s16le` pack |
//! | `slopdesk-apple-audio` | the `AudioConverter` calls, and the read of a sample buffer |
//! | this module | the pointers, and the one callback |
//!
//! ## Why the encoder answers through a CALLBACK and the decoder does not
//! They have different arities. One decode call answers at most one run of samples, whose exact
//! length is arithmetic the caller can do — so it is §4's ordinary `(out, cap)` shape and the first
//! guess is never wrong. One capture buffer can complete zero, one or two wire frames, and the
//! caller cannot know which before the call; an `(out, cap)` door would have to either cap the
//! count silently or run the whole encode twice. So the encoder takes a sink, on the encoder
//! module's own terms: the callback is given borrowed pointers valid ONLY for the duration of the
//! call, it is called on the caller's own audio queue and never reentrantly, and the context
//! outlives the handle.
//!
//! ## The two halves are gated apart
//! Only the host encodes and only the host has a capture tap, so the encoder doors are macOS-only
//! and `slopdesk_ffi.h` declares them inside its `TARGET_OS_OSX` region. Every client decodes, so
//! the decoder doors are declared outside it. That is `slopdesk-apple-vt`'s split exactly.

use core::ffi::{c_float, c_uchar};

use slopdesk_apple_audio::Decoder;
use slopdesk_video::audio_wire::{AudioStreamConfig, AudioWireFormat};

use crate::borrow;

/// One of the capture tap's three fixed numbers, by index; `0` for an index this build lacks.
///
/// A door rather than three Swift constants for the reason `slopdesk_audio_constant` is one: the
/// capture tap is CONFIGURED from these — `SlopDeskCaptureDesc` carries the rate and the channel
/// count straight into `ScreenCaptureKit` — and the encoder's block cadence is derived from them on
/// the far side. Two copies of a number that must agree is the one thing that cannot be tested for.
///
/// `0` = sample rate (Hz) · `1` = channel count · `2` = frames per wire block.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_audio_source_constant(index: u8) -> usize {
    match index {
        0 => slopdesk_video::audio_source::SAMPLE_RATE as usize,
        1 => slopdesk_video::audio_source::CHANNEL_COUNT,
        2 => slopdesk_video::audio_source::FRAMES_PER_BLOCK,
        _ => 0,
    }
}

/// The decoder, as the caller's token.
#[derive(Debug)]
pub struct SlopDeskAudioDecoder {
    decoder: Decoder,
}

/// Turns the caller's decoder handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer returned by [`slopdesk_audio_decoder_new`] that has not been
/// freed, with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held_decoder<'a>(handle: *mut SlopDeskAudioDecoder) -> Option<&'a mut SlopDeskAudioDecoder> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// A decoder for a wire config, or null for one the framework refused.
///
/// Null is the caller's cue to DROP the config and keep whatever stream was in force: the host
/// re-sends its config about a second apart, so a transient refusal self-heals on the next copy.
///
/// # Safety
/// `(cookie, cookie_len)` must be null or describe live readable memory for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_decoder_new(
    format: u8,
    sample_rate: u32,
    channels: u8,
    cookie: *const c_uchar,
    cookie_len: usize,
) -> *mut SlopDeskAudioDecoder {
    let Some(format) = AudioWireFormat::from_raw(format) else {
        // A format this build does not speak. Refusing here rather than defaulting is the wire's
        // own rule: a config that cannot be understood drops the stream, it does not guess one.
        return core::ptr::null_mut();
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let cookie = unsafe { borrow(cookie, cookie_len) }.to_vec();
    let config = AudioStreamConfig::new(format, sample_rate, channels, cookie);
    Decoder::new(&config).map_or(core::ptr::null_mut(), |decoder| {
        Box::into_raw(Box::new(SlopDeskAudioDecoder { decoder }))
    })
}

/// Frees a decoder. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_audio_decoder_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_decoder_free(handle: *mut SlopDeskAudioDecoder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Decodes one wire payload into `out`; answers the SAMPLE count the answer needs.
///
/// `0` is §4's "no answer" and means DROP the frame — a corrupt payload, or a converter that
/// produced nothing for this one. The client's jitter stage conceals it exactly as it would a lost
/// datagram, which is deliberate: there is one recovery for a ten-millisecond hole either way.
///
/// A count above `cap` leaves the destination untouched. The honest call sizes the buffer at four
/// wire frames' worth, which is what the decoder can produce at most.
///
/// # Safety
/// `handle` must satisfy [`held_decoder`]'s obligation, `(payload, payload_len)` must be null or
/// describe live readable memory, and `(out, cap)` null or live writable memory for `cap` floats —
/// all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_decoder_decode(
    handle: *mut SlopDeskAudioDecoder,
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut c_float,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(held) = (unsafe { held_decoder(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let payload = unsafe { borrow(payload, payload_len) };
    let decoded = held.decoder.decode(payload);
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    unsafe { crate::spill(&decoded, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        clippy::indexing_slicing,
        clippy::float_cmp,
        reason = "these entry points are unsafe by definition, a panic in a test IS the failure report, and \
                  the PCM arm is a sample-format convert pinned by exact bits"
    )]

    use slopdesk_video::audio_source::{CHANNEL_COUNT, FRAMES_PER_BLOCK, SAMPLE_RATE, pack_s16le};
    use slopdesk_video::audio_wire::AudioWireFormat;

    use super::{slopdesk_audio_decoder_decode, slopdesk_audio_decoder_free, slopdesk_audio_decoder_new};

    #[test]
    fn a_pcm_payload_round_trips_through_the_door() {
        let handle = unsafe {
            slopdesk_audio_decoder_new(
                AudioWireFormat::PcmS16Le.raw_value(),
                SAMPLE_RATE,
                2,
                core::ptr::null(),
                0,
            )
        };
        assert!(!handle.is_null(), "the PCM arm needs no converter");
        let payload = pack_s16le(&vec![0.5_f32; FRAMES_PER_BLOCK * CHANNEL_COUNT]);
        let mut room = vec![0.0_f32; FRAMES_PER_BLOCK * CHANNEL_COUNT];
        let written = unsafe {
            slopdesk_audio_decoder_decode(
                handle,
                payload.as_ptr(),
                payload.len(),
                room.as_mut_ptr(),
                room.len(),
            )
        };
        assert_eq!(written, room.len());
        assert!((room[0] - 0.5).abs() < 1e-4);
        unsafe { slopdesk_audio_decoder_free(handle) };
    }

    #[test]
    fn an_undersized_destination_writes_nothing_and_says_how_much_it_needs() {
        let handle = unsafe {
            slopdesk_audio_decoder_new(
                AudioWireFormat::PcmS16Le.raw_value(),
                SAMPLE_RATE,
                2,
                core::ptr::null(),
                0,
            )
        };
        let payload = pack_s16le(&[0.25_f32; 8]);
        let mut room = [-1.0_f32; 2];
        let needed = unsafe {
            slopdesk_audio_decoder_decode(handle, payload.as_ptr(), payload.len(), room.as_mut_ptr(), 2)
        };
        assert_eq!(needed, 8);
        assert_eq!(room, [-1.0, -1.0], "nothing was written");
        unsafe { slopdesk_audio_decoder_free(handle) };
    }

    #[test]
    fn a_format_this_build_does_not_speak_answers_null() {
        // The wire's own rule: a config that cannot be understood drops the stream rather than
        // guessing a codec for it.
        let handle = unsafe { slopdesk_audio_decoder_new(200, SAMPLE_RATE, 2, core::ptr::null(), 0) };
        assert!(handle.is_null());
    }

    #[test]
    fn every_door_tolerates_a_null_handle() {
        let mut room = [0.0_f32; 4];
        assert_eq!(
            unsafe {
                slopdesk_audio_decoder_decode(
                    core::ptr::null_mut(),
                    core::ptr::null(),
                    0,
                    room.as_mut_ptr(),
                    4,
                )
            },
            0
        );
        unsafe { slopdesk_audio_decoder_free(core::ptr::null_mut()) };
    }
}
