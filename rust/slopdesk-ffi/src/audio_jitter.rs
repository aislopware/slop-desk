//! The audio jitter STAGE: every buffering decision between the decoder and whatever plays.
//!
//! ## Why this one is a HANDLE and the decoder's admission is not
//!
//! Both hold a queue of frames. The difference is what the LAW reads. The decode sequencer never
//! looks at a compressed byte, so its door moves frame ids and the caller keeps the payloads. This
//! stage's whole product IS the samples — it exists to hand back a steady stream of them, in an
//! order it chose, split at offsets it chose — so the samples have to live where the decisions are.
//! Rust owns the stage, the caller holds an opaque token, and samples cross once each way through
//! `(ptr, len)` pairs, which is one memcpy of ten milliseconds of audio per push. At a hundred
//! pushes a second that is under half a megabyte a second, and there is no arrangement that avoids
//! it without putting the ordering law back on the near side.
//!
//! ## What is NOT here
//!
//! The lock-free hand-off ring the render callback drains. That is raw storage partitioned by two
//! atomic counters — the one structure in the audio path that exists to keep a real-time thread
//! from ever blocking on the producer — and it belongs to the runtime that owns the audio unit. The
//! pump's own arithmetic IS here, as pure entries: the two sample budgets, the starvation test and
//! the combined-depth shed.

use core::ffi::c_float;

use slopdesk_video::audio_jitter::{
    AudioJitterBuffer, consumer_starved, high_water_samples, ring_target_samples, shed_to_depth_bound,
};

/// The stage, as the caller's token.
#[derive(Debug)]
pub struct SlopDeskAudioStage {
    stage: AudioJitterBuffer,
}

/// The cumulative policy counters. Monotonic odometers rather than levels.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskAudioStageStats {
    /// Frames accepted into the stage.
    pub frames_pushed: u64,
    /// Frames dropped for arriving at or behind the play frontier.
    pub late_dropped: u64,
    /// Frames dropped as duplicates of a pending frame, which is a re-delivery.
    pub duplicate_dropped: u64,
    /// Oldest-pending frames dropped past the high-water mark.
    pub overflow_dropped: u64,
    /// Times the stage ran dry mid-play. Priming silence is not an underrun.
    pub underruns: u64,
    /// Zero samples emitted, across priming and underrun tails.
    pub silence_samples: u64,
}

/// The stage's depth policy, which no fold moves.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskAudioStageShape {
    /// The interleaved channel count.
    pub channels: usize,
    /// Pending frames required before playback starts.
    pub target_depth_frames: usize,
    /// The pending-frame cap, past which the oldest is dropped.
    pub high_water_frames: usize,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer returned by [`slopdesk_audio_stage_new`] that has not been
/// freed, with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskAudioStage) -> Option<&'a mut SlopDeskAudioStage> {
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

/// Borrows the caller's destination for the length of one call.
///
/// # Safety
/// `(ptr, len)` must describe live, exclusively-held memory for the whole call, or `ptr` must be
/// null.
#[expect(
    unsafe_code,
    reason = "the one question this shim answers: is this (ptr, len) live for the call"
)]
const unsafe fn samples_mut<'a>(ptr: *mut c_float, len: usize) -> &'a mut [f32] {
    if ptr.is_null() || len == 0 {
        return &mut [];
    }
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    unsafe { core::slice::from_raw_parts_mut(ptr, len) }
}

/// A stage for the given channel count and depth policy, priming and empty.
///
/// Every argument is floored at what the policy can actually mean: one channel, one frame of target
/// depth, and a high water at least the target. Never null unless allocation itself failed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_audio_stage_new(
    channels: usize,
    target_depth_frames: usize,
    high_water_frames: usize,
) -> *mut SlopDeskAudioStage {
    Box::into_raw(Box::new(SlopDeskAudioStage {
        stage: AudioJitterBuffer::new(channels, target_depth_frames, high_water_frames),
    }))
}

/// Frees a stage. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_audio_stage_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_free(handle: *mut SlopDeskAudioStage) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// The depth policy the stage was built with. A null handle answers the degenerate shape.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_shape(
    handle: *mut SlopDeskAudioStage,
) -> SlopDeskAudioStageShape {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    unsafe { held(handle) }.map_or(
        SlopDeskAudioStageShape {
            channels: 1,
            target_depth_frames: 1,
            high_water_frames: 1,
        },
        |held| {
            SlopDeskAudioStageShape {
                channels: held.stage.channels(),
                target_depth_frames: held.stage.target_depth_frames(),
                high_water_frames: held.stage.high_water_frames(),
            }
        },
    )
}

/// The cumulative counters. A null handle answers zeroes.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_stats(
    handle: *mut SlopDeskAudioStage,
) -> SlopDeskAudioStageStats {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let stats = unsafe { held(handle) }.map(|held| held.stage.stats());
    SlopDeskAudioStageStats {
        frames_pushed: stats.map_or(0, |inner| inner.frames_pushed),
        late_dropped: stats.map_or(0, |inner| inner.late_dropped),
        duplicate_dropped: stats.map_or(0, |inner| inner.duplicate_dropped),
        overflow_dropped: stats.map_or(0, |inner| inner.overflow_dropped),
        underruns: stats.map_or(0, |inner| inner.underruns),
        silence_samples: stats.map_or(0, |inner| inner.silence_samples),
    }
}

/// Whether the stage has filled to its target depth and is playing rather than priming.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_primed(handle: *mut SlopDeskAudioStage) -> bool {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    unsafe { held(handle) }.is_some_and(|held| held.stage.primed())
}

/// The unplayed frame count, which is the stage's live depth.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_pending_frames(handle: *mut SlopDeskAudioStage) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    unsafe { held(handle) }.map_or(0, |held| held.stage.pending_frames())
}

/// The samples currently available to pull, with a partially played head accounted for.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_available_samples(handle: *mut SlopDeskAudioStage) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    unsafe { held(handle) }.map_or(0, |held| held.stage.available_samples())
}

/// Offers one decoded frame, keyed by its wire sequence. An empty sample set is a decoder miss
/// rather than a frame, and is dropped.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `(samples, len)` must be live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_push(
    handle: *mut SlopDeskAudioStage,
    seq: u32,
    samples_ptr: *const c_float,
    samples_len: usize,
) {
    // SAFETY: both obligations are the caller's, discharged by a scoped buffer access at the site.
    let (held, offered) = unsafe { (held(handle), samples(samples_ptr, samples_len)) };
    if let Some(held) = held {
        held.stage.push(seq, offered.to_vec());
    }
}

/// Fills the destination with the next interleaved samples, zero-filling whatever the stage cannot
/// supply — priming, or a mid-play underrun, which drops back to priming.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `(out, len)` must be live and exclusively held
/// for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_pull(
    handle: *mut SlopDeskAudioStage,
    out: *mut c_float,
    out_len: usize,
) {
    // SAFETY: both obligations are the caller's, discharged by a scoped buffer access at the site.
    let (held, target) = unsafe { (held(handle), samples_mut(out, out_len)) };
    if let Some(held) = held {
        held.stage.pull(target);
    }
}

/// Copies up to the destination's length of what is available, when primed, and marks it consumed.
///
/// No zero-fill and no underrun re-prime: running short HERE only means nothing is staged to hand
/// off, and actual consumer starvation is signalled separately. Answers the samples written.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `(out, len)` must be live and exclusively held
/// for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_drain_available(
    handle: *mut SlopDeskAudioStage,
    out: *mut c_float,
    out_len: usize,
) -> usize {
    // SAFETY: both obligations are the caller's, discharged by a scoped buffer access at the site.
    let (held, target) = unsafe { (held(handle), samples_mut(out, out_len)) };
    held.map_or(0, |held| held.stage.drain_available(target))
}

/// The hand-off consumer ran the stage dry mid-play: drop back to priming so playback resumes with
/// full slack rather than one frame at a time. Pending frames stay buffered and re-count toward it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_audio_stage_note_consumer_starved(handle: *mut SlopDeskAudioStage) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(held) = unsafe { held(handle) } {
        held.stage.note_consumer_starved();
    }
}

/// Skips the oldest pending frame forward. A latency shed is a skip, not an underrun, so this never
/// re-primes.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_drop_oldest_pending(handle: *mut SlopDeskAudioStage) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(held) = unsafe { held(handle) } {
        held.stage.drop_oldest_pending();
    }
}

/// Drops everything buffered and returns to priming, KEEPING the play frontier.
///
/// The sequence space is session-scoped and monotonic, so frames arriving after a re-enable are
/// strictly newer and must not be read as late. The counters stay cumulative.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_clear(handle: *mut SlopDeskAudioStage) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(held) = unsafe { held(handle) } {
        held.stage.clear();
    }
}

/// Sheds the oldest staged frames until the combined stage-and-ring depth is back at the target,
/// answering how many were shed.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_stage_shed_to_depth_bound(
    handle: *mut SlopDeskAudioStage,
    ring_fill: usize,
    samples_per_frame: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    unsafe { held(handle) }.map_or(0, |held| {
        shed_to_depth_bound(&mut held.stage, ring_fill, samples_per_frame)
    })
}

/// The ring top-up bound in samples.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_audio_ring_target_samples(
    target_depth_frames: usize,
    samples_per_frame: usize,
) -> usize {
    ring_target_samples(target_depth_frames, samples_per_frame)
}

/// The combined stage-plus-ring depth cap in samples.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_audio_high_water_samples(
    high_water_frames: usize,
    samples_per_frame: usize,
) -> usize {
    high_water_samples(high_water_frames, samples_per_frame)
}

/// Whether the render side actually played conceal silence since the last push.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_audio_consumer_starved(
    primed: bool,
    emitted_since_prime: bool,
    shortfall_now: u64,
    last_shortfall: u64,
) -> bool {
    consumer_starved(primed, emitted_since_prime, shortfall_now, last_shortfall)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        slopdesk_audio_consumer_starved, slopdesk_audio_high_water_samples,
        slopdesk_audio_ring_target_samples, slopdesk_audio_stage_available_samples,
        slopdesk_audio_stage_clear, slopdesk_audio_stage_drain_available,
        slopdesk_audio_stage_drop_oldest_pending, slopdesk_audio_stage_free, slopdesk_audio_stage_new,
        slopdesk_audio_stage_note_consumer_starved, slopdesk_audio_stage_pending_frames,
        slopdesk_audio_stage_primed, slopdesk_audio_stage_pull, slopdesk_audio_stage_push,
        slopdesk_audio_stage_shape, slopdesk_audio_stage_shed_to_depth_bound, slopdesk_audio_stage_stats,
    };

    /// A stage of two channels at the stock depth policy.
    fn stage() -> *mut super::SlopDeskAudioStage {
        slopdesk_audio_stage_new(2, 2, 8)
    }

    /// One frame of four interleaved samples, all of one value.
    fn push(handle: *mut super::SlopDeskAudioStage, seq: u32, value: f32) {
        let frame = [value; 4];
        // SAFETY: the handle is live and the fixture outlives the call.
        unsafe { slopdesk_audio_stage_push(handle, seq, frame.as_ptr(), frame.len()) };
    }

    /// Pulls `len` samples, silence-filled.
    fn pull(handle: *mut super::SlopDeskAudioStage, len: usize) -> Vec<f32> {
        let mut out = vec![0.0; len];
        // SAFETY: the handle is live and the destination outlives the call.
        unsafe { slopdesk_audio_stage_pull(handle, out.as_mut_ptr(), out.len()) };
        out
    }

    #[test]
    fn a_null_handle_is_inert_at_every_entry_point() {
        // SAFETY: null is the documented no-op at every one of these.
        unsafe {
            assert!(!slopdesk_audio_stage_primed(core::ptr::null_mut()));
            assert_eq!(slopdesk_audio_stage_pending_frames(core::ptr::null_mut()), 0);
            assert_eq!(slopdesk_audio_stage_available_samples(core::ptr::null_mut()), 0);
            assert_eq!(slopdesk_audio_stage_stats(core::ptr::null_mut()).frames_pushed, 0);
            assert_eq!(slopdesk_audio_stage_shape(core::ptr::null_mut()).channels, 1);
            slopdesk_audio_stage_note_consumer_starved(core::ptr::null_mut());
            slopdesk_audio_stage_drop_oldest_pending(core::ptr::null_mut());
            slopdesk_audio_stage_clear(core::ptr::null_mut());
            slopdesk_audio_stage_free(core::ptr::null_mut());
        }
    }

    #[test]
    fn the_stage_primes_before_it_plays_and_then_hands_the_samples_back_in_order() {
        let handle = stage();
        push(handle, 1, 1.0);
        // SAFETY: the handle is live.
        assert!(
            !unsafe { slopdesk_audio_stage_primed(handle) },
            "one frame is not the depth"
        );
        assert_eq!(
            pull(handle, 4),
            [0.0; 4],
            "priming is silence, not a partial frame"
        );
        push(handle, 2, 2.0);
        // SAFETY: the handle is live.
        assert!(unsafe { slopdesk_audio_stage_primed(handle) });
        assert_eq!(pull(handle, 8), [1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0]);
        // SAFETY: the handle is live.
        unsafe { slopdesk_audio_stage_free(handle) };
    }

    #[test]
    fn a_swapped_pair_of_datagrams_still_plays_in_order_and_a_late_one_is_dropped() {
        let handle = stage();
        push(handle, 2, 2.0);
        push(handle, 1, 1.0);
        assert_eq!(
            pull(handle, 8),
            [1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0],
            "reordered"
        );
        push(handle, 1, 9.0);
        // SAFETY: the handle is live.
        let stats = unsafe { slopdesk_audio_stage_stats(handle) };
        assert_eq!(
            stats.late_dropped, 1,
            "behind the play frontier is too late to matter"
        );
        assert_eq!(stats.frames_pushed, 2);
        // SAFETY: the handle is live.
        unsafe { slopdesk_audio_stage_free(handle) };
    }

    #[test]
    fn running_dry_mid_play_conceals_and_drops_back_to_priming() {
        let handle = stage();
        push(handle, 1, 1.0);
        push(handle, 2, 2.0);
        assert_eq!(pull(handle, 12).len(), 12);
        // SAFETY: the handle is live.
        let (primed, stats) = unsafe {
            (
                slopdesk_audio_stage_primed(handle),
                slopdesk_audio_stage_stats(handle),
            )
        };
        assert!(
            !primed,
            "resuming one frame at a time is a crackle, not a recovery"
        );
        assert_eq!(stats.underruns, 1);
        assert_eq!(stats.silence_samples, 4);
        // SAFETY: the handle is live.
        unsafe { slopdesk_audio_stage_free(handle) };
    }

    #[test]
    fn past_the_high_water_the_oldest_frame_is_skipped_rather_than_the_latency_kept() {
        let handle = slopdesk_audio_stage_new(2, 2, 3);
        for seq in 1..=5 {
            #[expect(clippy::cast_precision_loss, reason = "five small integers as sample values")]
            push(handle, seq, seq as f32);
        }
        // SAFETY: the handle is live.
        let (pending, stats) = unsafe {
            (
                slopdesk_audio_stage_pending_frames(handle),
                slopdesk_audio_stage_stats(handle),
            )
        };
        assert_eq!(pending, 3, "the cap holds");
        assert_eq!(stats.overflow_dropped, 2, "stale audio is worse than a click");
        assert_eq!(pull(handle, 4), [3.0; 4], "playback skipped forward");
        // SAFETY: the handle is live.
        unsafe { slopdesk_audio_stage_free(handle) };
    }

    #[test]
    fn the_producer_drain_takes_what_is_there_without_concealing() {
        let handle = stage();
        push(handle, 1, 1.0);
        push(handle, 2, 2.0);
        let mut out = vec![0.0_f32; 16];
        // SAFETY: the handle is live and the destination outlives the call.
        let wrote = unsafe { slopdesk_audio_stage_drain_available(handle, out.as_mut_ptr(), out.len()) };
        assert_eq!(
            wrote, 8,
            "no zero-fill: running short only means nothing is staged"
        );
        // SAFETY: the handle is live.
        let stats = unsafe { slopdesk_audio_stage_stats(handle) };
        assert_eq!(stats.underruns, 0, "and no re-prime either");
        assert_eq!(stats.silence_samples, 0);
        // SAFETY: the handle is live.
        unsafe {
            slopdesk_audio_stage_note_consumer_starved(handle);
            assert_eq!(slopdesk_audio_stage_stats(handle).underruns, 1);
            assert!(
                !slopdesk_audio_stage_primed(handle),
                "starvation is the pump's to report"
            );
            slopdesk_audio_stage_free(handle);
        }
    }

    #[test]
    fn a_clear_keeps_the_frontier_so_a_re_enable_is_not_read_as_late() {
        let handle = stage();
        push(handle, 1, 1.0);
        push(handle, 2, 2.0);
        assert_eq!(pull(handle, 4).len(), 4);
        // SAFETY: the handle is live.
        unsafe { slopdesk_audio_stage_clear(handle) };
        // SAFETY: the handle is live.
        assert_eq!(unsafe { slopdesk_audio_stage_available_samples(handle) }, 0);
        push(handle, 3, 3.0);
        // SAFETY: the handle is live.
        assert_eq!(
            unsafe { slopdesk_audio_stage_stats(handle) }.late_dropped,
            0,
            "the sequence space is session-scoped, so what follows is strictly newer",
        );
        // SAFETY: the handle is live.
        unsafe { slopdesk_audio_stage_free(handle) };
    }

    #[test]
    fn the_pumps_arithmetic_is_the_doors_too() {
        assert_eq!(slopdesk_audio_ring_target_samples(2, 480), 960);
        assert_eq!(slopdesk_audio_high_water_samples(8, 480), 3840);
        assert!(slopdesk_audio_consumer_starved(true, true, 7, 4));
        assert!(
            !slopdesk_audio_consumer_starved(true, true, 4, 4),
            "an exact dry drain zero-fills nothing",
        );
        assert!(
            !slopdesk_audio_consumer_starved(true, false, 7, 4),
            "priming silence is never starvation",
        );

        let handle = slopdesk_audio_stage_new(2, 2, 4);
        for seq in 1..=4 {
            push(handle, seq, 1.0);
        }
        // SAFETY: the handle is live.
        // The stage alone is exactly at its own cap; it is the RING's fill that puts the combined
        // depth past the bound, which is the whole reason this decision is not the push-side one.
        let shed = unsafe { slopdesk_audio_stage_shed_to_depth_bound(handle, 8, 4) };
        assert!(
            shed > 0,
            "past the combined bound the backlog sheds down to target"
        );
        // SAFETY: the handle is live.
        unsafe {
            assert!(
                slopdesk_audio_stage_available_samples(handle) + 8
                    <= slopdesk_audio_ring_target_samples(2, 4)
            );
            assert_eq!(slopdesk_audio_stage_shape(handle).high_water_frames, 4);
            slopdesk_audio_stage_free(handle);
        }
    }
}
