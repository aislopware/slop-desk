//! The two stream descriptions this crate ever builds, and the one status it compares against.
//!
//! An `AudioStreamBasicDescription` is a plain `#[repr(C)]` value — no allocation, no ownership, no
//! framework call — so nothing here is `unsafe` and every field is checkable by a headless test.
//! They live in their own module because the encoder and the decoder each need BOTH of them, in
//! opposite roles: what the encoder calls its input the decoder calls its output.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use objc2_core_audio_types::{
    AudioStreamBasicDescription, kAudioFormatFlagIsFloat, kAudioFormatFlagIsPacked, kAudioFormatLinearPCM,
    kAudioFormatMPEG4AAC_ELD,
};

/// What every `AudioToolbox` entry point answers.
///
/// Spelled here rather than imported: `objc2-core-media` and `objc2-audio-toolbox` each keep their
/// own `OSStatus` crate-private, and it is `i32` in both — the same thing `slopdesk-apple-vt` does
/// for the two `VideoToolbox` codes it speaks.
pub(crate) type OsStatus = i32;

/// `noErr`. Every `AudioToolbox` entry point answers one of these, and every one of them is
/// checked.
pub(crate) const NO_ERR: OsStatus = 0;

/// Bytes in one `f32` sample. Named because it appears in three field computations where a bare
/// `4` would read as a frame count.
pub(crate) const BYTES_PER_SAMPLE: u32 = 4;

/// Interleaved packed Float32 LPCM — the format on the Rust side of both converters.
///
/// This is the jitter stage's sample format and the capture tap's, which is why it is the one
/// uncompressed description in the crate: everything above this layer speaks interleaved `f32` and
/// nothing has to convert to talk to it.
pub(crate) const fn float_pcm(sample_rate: f64, channels: u32) -> AudioStreamBasicDescription {
    let bytes_per_frame = BYTES_PER_SAMPLE * channels;
    AudioStreamBasicDescription {
        mSampleRate: sample_rate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        // For LPCM one packet IS one frame, which is what lets the encoder's input proc measure its
        // hand-over in frames and answer the converter in packets without converting.
        mBytesPerPacket: bytes_per_frame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytes_per_frame,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0,
    }
}

/// AAC-ELD at a stated frames-per-packet — the format on the wire side of both converters.
///
/// `frames_per_packet` is the whole reason this takes an argument. AAC-ELD has a 512-frame variant
/// and a 480-frame one, and the codec picks the default; asking for 480 explicitly is what makes
/// one packet exactly one ten-millisecond wire frame at 48 kHz. Leaving it to the default would put
/// the codec's own cadence in a slow beat against the wire's, which surfaces as a periodic hiccup
/// rather than as an error anyone can see.
///
/// Every size field is zero because a compressed packet has no fixed size, which is also why the
/// converter reports its worst case through `kAudioConverterPropertyMaximumOutputPacketSize`
/// instead.
pub(crate) const fn aac_eld(
    sample_rate: f64,
    channels: u32,
    frames_per_packet: u32,
) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription {
        mSampleRate: sample_rate,
        mFormatID: kAudioFormatMPEG4AAC_ELD,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: frames_per_packet,
        mBytesPerFrame: 0,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 0,
        mReserved: 0,
    }
}

#[cfg(test)]
mod tests {
    use objc2_core_audio_types::{
        kAudioFormatFlagIsFloat, kAudioFormatFlagIsNonInterleaved, kAudioFormatFlagIsPacked,
        kAudioFormatLinearPCM, kAudioFormatMPEG4AAC_ELD,
    };

    use super::{aac_eld, float_pcm};

    #[test]
    fn float_pcm_is_interleaved_and_one_frame_per_packet() {
        let desc = float_pcm(48_000.0, 2);
        assert_eq!(desc.mFormatID, kAudioFormatLinearPCM);
        assert_eq!(
            desc.mFormatFlags & kAudioFormatFlagIsFloat,
            kAudioFormatFlagIsFloat
        );
        assert_eq!(
            desc.mFormatFlags & kAudioFormatFlagIsPacked,
            kAudioFormatFlagIsPacked
        );
        // The flag that must be ABSENT: setting it would mean planar, and every caller of this
        // crate hands over one interleaved run.
        assert_eq!(desc.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0);
        assert_eq!(desc.mFramesPerPacket, 1);
        assert_eq!(desc.mBytesPerFrame, 8, "two channels of f32");
        assert_eq!(desc.mBytesPerPacket, desc.mBytesPerFrame);
        assert_eq!(desc.mBitsPerChannel, 32);
    }

    #[test]
    fn aac_eld_asks_for_the_480_frame_variant() {
        let desc = aac_eld(48_000.0, 2, 480);
        assert_eq!(desc.mFormatID, kAudioFormatMPEG4AAC_ELD);
        // Ten milliseconds at 48 kHz, which is the wire cadence. A 512 here is the beat this field
        // exists to prevent.
        assert_eq!(desc.mFramesPerPacket, 480);
        assert_eq!(desc.mBytesPerPacket, 0, "a compressed packet has no fixed size");
        assert_eq!(desc.mFormatFlags, 0);
    }
}
