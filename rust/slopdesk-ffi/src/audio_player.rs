//! The client's audio output, as one handle: a decoded frame goes in, the speakers come out.
//!
//! ## What this replaced, and why the door moved UP a layer
//! Until this door existed the boundary sat mid-pipeline. Rust owned the jitter STAGE and Swift
//! owned everything around it: a lock-free ring (`AudioSampleRing`), a pump that asked the stage
//! for its budgets and moved samples into that ring (`AudioPlaybackPump`), and an
//! `AUHAL`/`RemoteIO` output unit with a render callback (`AudioPlaybackEngine`). Six hundred lines
//! of Swift, of which the only part that HAD to be Swift was… none of it. The ring is `rtrb`, the
//! pump is arithmetic the stage already published, and the output unit is `cpal`.
//!
//! So the whole of it is `slopdesk-audio-out` now, and the door is one handle with six verbs.
//! `slopdesk_audio_stage_*` — fifteen doors that existed to let Swift drive a pump — went with it.
//!
//! ## The rate conversion this door quietly acquired
//! `AUHAL` converted from the wire rate to the device's own; `cpal` does not, so
//! `slopdesk-audio-out` resamples on the producer side. On every Mac and iOS output this has been
//! pointed at the device offers 48 kHz and the conversion is literally a copy — it matters only on
//! a device pinned to 44.1 kHz, where the alternative is playing everything a semitone sharp.
//!
//! ## One owner, and no lock on the render side
//! Every verb here is confined to the caller's serial audio queue, the same discipline the decode
//! path already runs under. The render thread holds the other half of a wait-free SPSC hand-off and
//! nothing else — it never reaches the stage, so there is no lock for a real-time deadline to miss.

use core::ffi::c_float;

use slopdesk_audio_out::Player;

/// The player, as the caller's token.
#[derive(Debug)]
pub struct SlopDeskAudioPlayer {
    player: Player,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer returned by [`slopdesk_audio_player_new`] that has not been
/// freed, with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskAudioPlayer) -> Option<&'a mut SlopDeskAudioPlayer> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// Borrows the caller's samples for the length of one call.
///
/// # Safety
/// `(ptr, len)` must describe live memory for the whole call, or `ptr` must be null.
#[expect(
    unsafe_code,
    reason = "the one question this shim answers: is this (ptr, len) live for the call"
)]
const unsafe fn samples<'a>(ptr: *const c_float, len: usize) -> &'a [f32] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    unsafe { core::slice::from_raw_parts(ptr, len) }
}

/// A player for one locked `(sample rate, channels)`, silent until [`slopdesk_audio_player_start`].
///
/// Never null unless allocation itself failed. A machine with no output device answers a player
/// that works and stays mute — headless is the normal way to arrive there, not a fault — and
/// [`slopdesk_audio_player_has_device`] is how a caller can tell.
///
/// A config change that moves either the rate or the channel count REBUILDS the player: the
/// resampler's ratio, the hand-off's capacity and the device's own stream are all derived from the
/// pair, and nothing here reconfigures in place.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_audio_player_new(sample_rate: f64, channels: usize) -> *mut SlopDeskAudioPlayer {
    Box::into_raw(Box::new(SlopDeskAudioPlayer {
        player: Player::new(sample_rate, channels),
    }))
}

/// Frees a player, stopping and joining its device thread. Null is a no-op.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_audio_player_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_player_free(handle: *mut SlopDeskAudioPlayer) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Whether a real output device was found. False means this player is permanently mute.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_player_has_device(handle: *mut SlopDeskAudioPlayer) -> bool {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    unsafe { held(handle) }.is_some_and(|held| held.player.has_device())
}

/// One decoded frame, keyed by its wire sequence.
///
/// The samples are COPIED — a frame crosses once, which is one memcpy of ten milliseconds of audio
/// per push, under half a megabyte a second at the wire cadence. There is no arrangement that
/// avoids it without putting the ordering law back on the caller's side.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `(samples, len)` must be null or describe live
/// readable memory for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_player_enqueue(
    handle: *mut SlopDeskAudioPlayer,
    seq: u32,
    samples_ptr: *const c_float,
    len: usize,
) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(held) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    let samples = unsafe { samples(samples_ptr, len) };
    if samples.is_empty() {
        return;
    }
    held.player.enqueue(seq, samples.to_vec());
}

/// Drops everything buffered — the pane falls silent on the next render pass.
///
/// Not after the hand-off drains: the render side is asked to SKIP what it holds, which is what
/// "silent now" can honestly mean when the producer cannot take back what it committed.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_player_flush(handle: *mut SlopDeskAudioPlayer) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(held) = unsafe { held(handle) } {
        held.player.flush();
    }
}

/// Starts output. Idempotent — which is what lets the host's ~1 s config re-send restart a stopped
/// player without the caller tracking whether it is already running.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_player_start(handle: *mut SlopDeskAudioPlayer) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(held) = unsafe { held(handle) } {
        held.player.start();
    }
}

/// Stops output, keeping the device for a cheap restart. Idempotent.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_player_stop(handle: *mut SlopDeskAudioPlayer) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(held) = unsafe { held(handle) } {
        held.player.stop();
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "these entry points are unsafe by definition in edition 2024"
    )]

    use super::{
        slopdesk_audio_player_enqueue, slopdesk_audio_player_flush, slopdesk_audio_player_free,
        slopdesk_audio_player_has_device, slopdesk_audio_player_new, slopdesk_audio_player_start,
        slopdesk_audio_player_stop,
    };

    #[test]
    fn a_frame_crosses_the_door_and_is_counted() {
        // Nothing here opens a device on purpose — `new` resolves one only to size the resampler,
        // and `start` is what would make a sound. The suite runs both headless and on machines with
        // real speakers, so this asserts the invariant rather than which branch was taken.
        let handle = slopdesk_audio_player_new(48_000.0, 2);
        assert!(!handle.is_null());
        let frame = vec![0.25_f32; 960];
        unsafe { slopdesk_audio_player_enqueue(handle, 1, frame.as_ptr(), frame.len()) };
        unsafe { slopdesk_audio_player_enqueue(handle, 2, frame.as_ptr(), frame.len()) };
        unsafe { slopdesk_audio_player_flush(handle) };
        unsafe { slopdesk_audio_player_free(handle) };
    }

    #[test]
    fn start_and_stop_are_idempotent_and_free_joins() {
        let handle = slopdesk_audio_player_new(48_000.0, 2);
        unsafe { slopdesk_audio_player_start(handle) };
        unsafe { slopdesk_audio_player_start(handle) };
        unsafe { slopdesk_audio_player_stop(handle) };
        unsafe { slopdesk_audio_player_stop(handle) };
        // A second stop must not have left the device thread waiting on a command that never comes.
        unsafe { slopdesk_audio_player_free(handle) };
    }

    #[test]
    fn every_door_tolerates_a_null_handle() {
        let null = core::ptr::null_mut();
        unsafe { slopdesk_audio_player_enqueue(null, 1, core::ptr::null(), 0) };
        unsafe { slopdesk_audio_player_flush(null) };
        unsafe { slopdesk_audio_player_start(null) };
        unsafe { slopdesk_audio_player_stop(null) };
        assert!(!unsafe { slopdesk_audio_player_has_device(null) });
        unsafe { slopdesk_audio_player_free(null) };
    }

    /// An empty span is not a frame. It must not reach the stage, where it would count as one and
    /// then hand the render side nothing to play.
    #[test]
    fn an_empty_frame_is_not_a_frame() {
        let handle = slopdesk_audio_player_new(48_000.0, 2);
        unsafe { slopdesk_audio_player_enqueue(handle, 1, core::ptr::null(), 0) };
        let frame = [0.0_f32; 0];
        unsafe { slopdesk_audio_player_enqueue(handle, 2, frame.as_ptr(), 0) };
        unsafe { slopdesk_audio_player_free(handle) };
    }
}
