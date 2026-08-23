//! What one captured audio sample buffer holds, read once into interleaved stereo `f32`.
//!
//! The capture tap delivers a `CMSampleBuffer` whose samples live in a `CMBlockBuffer` behind an
//! `AudioBufferList`. Reading them is the ONE place in this crate that touches memory the framework
//! owns rather than memory it describes, and it is the reason `docs/57` §2 was amended — see the
//! crate manifest.
//!
//! ## Validate, then drop
//! The tap is configured 48 kHz interleaved stereo Float32 and `ScreenCaptureKit` is trusted to
//! honour it. It is still checked, every buffer, because the failure mode of NOT checking is
//! reinterpreting some other layout's bytes as `f32` — which is not a crash and not an error, it is
//! noise played at full scale into someone's headphones. A buffer that does not match is dropped.
//!
//! ## Why the fold lives one crate out
//! Mono duplicated into both channels, a wider layout truncated to the first two, a planar layout
//! zipped — those are RULES, they are `slopdesk_video::audio_source`'s, and they are tested there
//! without a framework. This module's job ends at handing that code two `&[f32]` and a frame count.

use objc2_core_audio_types::{
    AudioBuffer, AudioBufferList, AudioStreamBasicDescription, kAudioFormatFlagIsFloat,
    kAudioFormatFlagIsNonInterleaved, kAudioFormatLinearPCM,
};
use objc2_core_foundation::CFRetained;
use objc2_core_media::{
    CMAudioFormatDescriptionGetStreamBasicDescription, CMBlockBuffer, CMSampleBuffer,
    kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
};
use slopdesk_video::audio_source::{
    MAX_SOURCE_CHANNELS, fold_interleaved_to_stereo, fold_planar_to_stereo, source_layout_is_readable,
};

use crate::asbd::{BYTES_PER_SAMPLE, NO_ERR};

/// The captured samples as interleaved stereo `f32`, or `None` for a buffer this cannot read.
///
/// `None` is a DROP, not an error: the caller sends nothing for this delivery and the client's
/// jitter stage conceals the gap exactly as it would a lost datagram.
///
/// # Safety
/// Four framework contracts, in order.
///
/// `CMSampleBufferGetNumSamples`, `CMSampleBufferDataIsReady` and
/// `CMSampleBufferGetFormatDescription` are Get-rule accessors on a live sample buffer; `objc2`
/// generates the last as an owned return, so nothing crosses raw.
///
/// `CMAudioFormatDescriptionGetStreamBasicDescription` answers a read-only pointer INTO the format
/// description, valid as long as that description is. `description` holds it across the read, the
/// pointer is null-checked, and the value is copied out by `read` rather than borrowed — so nothing
/// escapes the description's lifetime.
///
/// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` fills a caller-owned buffer list and
/// hands back a RETAINED block buffer. The list is `storage`'s own allocation, sized here to hold
/// exactly `channels` buffers and described to the framework by that same size; it is
/// zero-initialised before the call, so a partial fill leaves no uninitialised window. The block
/// buffer's `+1` is taken by this crate's one admitted `CFRetained::from_raw` — the framework's
/// Create-rule, named in the function itself — and released when that value drops at the end of
/// this function, which is after the last sample has been copied out.
///
/// The sample runs themselves are `(pointer, length)` pairs the framework published in that list.
/// Each is accepted only when its own `mDataByteSize` covers the frames the sample buffer claims,
/// each is read as `f32` only after the description said the samples ARE packed `f32`, and each is
/// borrowed for strictly less than the block buffer's life. This is the raw-pointer work `docs/57`
/// §2's amendment admits, and it is confined to this function.
#[must_use]
#[expect(
    unsafe_code,
    reason = "Core Audio publishes captured samples as (pointer, length) in a buffer list — docs/57 §2's \
              amendment"
)]
pub fn read_stereo(sample: &CMSampleBuffer) -> Option<Vec<f32>> {
    // SAFETY: framework rule, above — Get-rule reads of a live sample buffer's own bookkeeping.
    let frames = usize::try_from(unsafe { sample.num_samples() }).ok()?;
    if frames == 0 {
        return None;
    }
    // SAFETY: framework rule, above — a live sample buffer.
    if !unsafe { sample.data_is_ready() } {
        return None;
    }
    // SAFETY: framework rule, above — an owned-return Get-rule accessor on a live sample.
    let description = unsafe { sample.format_description() }?;
    // SAFETY: framework rule, above — a read-only pointer into a description this frame holds.
    let asbd_pointer = unsafe { CMAudioFormatDescriptionGetStreamBasicDescription(&description) };
    if asbd_pointer.is_null() {
        // A non-audio format description. Nothing to read, and nothing wrong.
        return None;
    }
    // SAFETY: framework rule, above — a live, aligned, framework-initialised description, copied
    // out by value so it does not outlive the format description that owns it.
    let asbd: AudioStreamBasicDescription = unsafe { asbd_pointer.read() };
    if asbd.mFormatID != kAudioFormatLinearPCM
        || asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0
        || asbd.mBitsPerChannel != 32
    {
        return None;
    }
    let channels = usize::try_from(asbd.mChannelsPerFrame).ok()?;
    if !source_layout_is_readable(channels) {
        return None;
    }
    let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0;

    // One `AudioBufferList` element per source buffer. `AudioBufferList` is a header plus a
    // FLEXIBLE array, so its Rust type is the one-buffer case; `channels` of them is at least the
    // bytes a `channels`-buffer list needs, and its alignment is the right one by construction.
    let mut storage = vec![
        AudioBufferList {
            mNumberBuffers: 0,
            mBuffers: [AudioBuffer {
                mNumberChannels: 0,
                mDataByteSize: 0,
                mData: core::ptr::null_mut(),
            }],
        };
        channels.min(MAX_SOURCE_CHANNELS)
    ];
    let list_bytes = size_of::<AudioBufferList>() + channels.saturating_sub(1) * size_of::<AudioBuffer>();
    let mut block_raw: *mut CMBlockBuffer = core::ptr::null_mut();
    // SAFETY: framework rule, above — `storage` is this crate's own zeroed allocation, described by
    // the size a `channels`-buffer list occupies, and the retained out-slot is a live local.
    let status = unsafe {
        sample.audio_buffer_list_with_retained_block_buffer(
            core::ptr::null_mut(),
            storage.as_mut_ptr(),
            list_bytes,
            None,
            None,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &raw mut block_raw,
        )
    };
    let block = core::ptr::NonNull::new(block_raw)?;
    // SAFETY: framework rule, above — the Create-rule `+1` this crate's ONE admitted `from_raw`
    // takes ownership of; released when `_block` drops, after the last read below.
    let _block = unsafe { CFRetained::from_raw(block) };
    if status != NO_ERR {
        return None;
    }

    // SAFETY: framework rule, above — the framework filled `storage`'s header; this reads back the
    // count it wrote, which is its own and never larger than what was asked for.
    let filled = usize::try_from(storage.first()?.mNumberBuffers).ok()?;
    if filled == 0 {
        return None;
    }
    if planar {
        let left = run(&storage, 0, frames)?;
        // Mono duplicates into both wire channels — the rule, and the check that the second plane
        // is really there, both belong to `audio_source`.
        let right = (filled > 1).then(|| run(&storage, 1, frames)).flatten();
        fold_planar_to_stereo(left, right, frames)
    } else {
        let interleaved = run_interleaved(&storage, frames, channels)?;
        fold_interleaved_to_stereo(interleaved, frames, channels)
    }
}

/// One PLANE of the list as `frames` samples, or `None` when the framework published fewer bytes
/// than the sample buffer's own frame count needs.
///
/// # Safety
/// See [`read_stereo`]. `storage` is a list the framework filled; `index` is checked against the
/// count it wrote before the buffer is reached. The run is accepted only when the buffer's own
/// `mDataByteSize` covers `frames` samples, and the caller holds the block buffer that owns the
/// memory for strictly longer than the returned borrow.
#[expect(
    unsafe_code,
    reason = "Core Audio publishes captured samples as (pointer, length) — docs/57 §2's amendment"
)]
fn run(storage: &[AudioBufferList], index: usize, frames: usize) -> Option<&[f32]> {
    let buffer = buffer_at(storage, index)?;
    let needed = frames.checked_mul(BYTES_PER_SAMPLE as usize)?;
    if (buffer.mDataByteSize as usize) < needed {
        return None;
    }
    let base = buffer.mData.cast::<f32>();
    if base.is_null() || !base.is_aligned() {
        return None;
    }
    // SAFETY: framework rule, above — `frames` packed `f32` inside a run the buffer's own size says
    // is at least that long, alive for as long as the caller's block buffer.
    Some(unsafe { core::slice::from_raw_parts(base, frames) })
}

/// The single INTERLEAVED run of the list as `frames × channels` samples.
///
/// # Safety
/// Identical to [`run`], with the length requirement scaled by the channel count — an interleaved
/// buffer holds every channel of every frame in one allocation.
#[expect(
    unsafe_code,
    reason = "Core Audio publishes captured samples as (pointer, length) — docs/57 §2's amendment"
)]
fn run_interleaved(storage: &[AudioBufferList], frames: usize, channels: usize) -> Option<&[f32]> {
    let buffer = buffer_at(storage, 0)?;
    let samples = frames.checked_mul(channels)?;
    let needed = samples.checked_mul(BYTES_PER_SAMPLE as usize)?;
    if (buffer.mDataByteSize as usize) < needed {
        return None;
    }
    let base = buffer.mData.cast::<f32>();
    if base.is_null() || !base.is_aligned() {
        return None;
    }
    // SAFETY: framework rule, above — `samples` packed `f32` inside a run the buffer's own size
    // says is at least that long, alive for as long as the caller's block buffer.
    Some(unsafe { core::slice::from_raw_parts(base, samples) })
}

/// The `index`-th `AudioBuffer` of a filled list.
///
/// `AudioBufferList`'s Rust type names a one-element array because C's names a flexible one, so
/// reaching the second buffer is arithmetic past the end of that array — the framework's own
/// layout, and the whole reason this helper exists rather than being spelled three times.
///
/// # Safety
/// See [`read_stereo`]. `index` is checked against the count the framework wrote into the header,
/// and the allocation `storage` names was sized for at least that many buffers before the call — so
/// the offset stays inside one allocation. The buffer is copied out by value.
#[expect(
    unsafe_code,
    reason = "AudioBufferList's mBuffers is a C flexible array member — docs/57 §2's amendment"
)]
#[expect(
    clippy::integer_division,
    reason = "a byte capacity over a struct's size is how many of it fit — a remainder is slack"
)]
fn buffer_at(storage: &[AudioBufferList], index: usize) -> Option<AudioBuffer> {
    let header = storage.first()?;
    if index >= usize::try_from(header.mNumberBuffers).ok()? {
        return None;
    }
    // The list's own capacity, which is what actually bounds the arithmetic: `read_stereo` sized
    // `storage` for the source channel count, and the framework cannot have written more buffers
    // than the size it was handed described.
    let capacity = size_of_val(storage).saturating_sub(size_of::<u32>()) / size_of::<AudioBuffer>();
    if index >= capacity {
        return None;
    }
    let first: *const AudioBuffer = header.mBuffers.as_ptr();
    // SAFETY: framework rule, above — `index` is inside both the count the framework wrote and the
    // capacity this crate allocated, so the offset lands on a buffer of the same allocation.
    Some(unsafe { first.add(index).read() })
}

#[cfg(test)]
mod tests {
    use objc2_core_audio_types::{AudioBuffer, AudioBufferList};

    use super::buffer_at;

    fn empty() -> AudioBuffer {
        AudioBuffer {
            mNumberChannels: 0,
            mDataByteSize: 0,
            mData: core::ptr::null_mut(),
        }
    }

    #[test]
    fn an_index_past_the_written_count_is_refused() {
        // The framework says one buffer; asking for the second must not read the allocation's next
        // element and call it a channel.
        let storage = vec![
            AudioBufferList {
                mNumberBuffers: 1,
                mBuffers: [empty()],
            };
            2
        ];
        assert!(buffer_at(&storage, 0).is_some());
        assert!(buffer_at(&storage, 1).is_none());
    }

    #[test]
    fn an_index_past_the_allocation_is_refused_even_when_the_header_claims_it() {
        // A header that overstates its own count is the one thing that could walk this off the end,
        // so the capacity check is independent of what the framework wrote.
        let storage = vec![AudioBufferList {
            mNumberBuffers: 8,
            mBuffers: [empty()],
        }];
        assert!(buffer_at(&storage, 0).is_some());
        assert!(buffer_at(&storage, 4).is_none());
    }

    #[test]
    fn an_empty_list_answers_nothing() {
        assert!(buffer_at(&[], 0).is_none());
    }
}
