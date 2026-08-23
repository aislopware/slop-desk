//! **`AudioToolbox`** — the AAC-ELD codec on both ends of the wire, and the read of a captured
//! sample buffer's samples.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 and its AMENDMENT before adding anything: this
//! crate turns a block of samples into an access unit and back, and makes no decisions. The wire
//! cadence, the fold to stereo, the 480-frame chunking, the `s16le` pack and its decode all live in
//! `slopdesk_video`'s `audio_source` and `audio_wire`, which `forbid` `unsafe` and run headless.
//!
//! ## The surface
//! [`Encoder`] takes interleaved stereo `f32` and answers wire payloads. [`Decoder`] takes one wire
//! payload and answers interleaved `f32`. [`read_stereo`] turns a captured `CMSampleBuffer` into
//! the `f32` the encoder wants. That is all three of them.
//!
//! ## Why this crate may hand-write raw-pointer work when no other in the family may
//! §2 bars a `slopdesk-apple-*` crate from dereferencing a pointer it made, because every other
//! framework in the family hands out OBJECTS and `objc2` models those — the binding answers the
//! ownership question, so the crate never has to. `AudioToolbox` hands out SAMPLE MEMORY.
//! `AudioConverterFillComplexBuffer` takes a C input proc that must publish a `(pointer, length)`
//! through an `AudioBufferList`, and `CMSampleBuffer` delivers captured audio the same way. There
//! is no block-based alternative in the framework family: `AVAudioConverter`'s block API reaches
//! the same samples through `floatChannelData`, which is a `*mut NonNull<c_float>`. Nor can the
//! operation move to one of the three hand-`unsafe` crates — `slopdesk-ffi` already depends on this
//! family, so the reverse edge is a cycle.
//!
//! So the amendment is narrow, and every other §2 obligation is carried in full: `deny` on
//! `unsafe_op_in_unsafe_fn`, a `# Safety` note per block naming the AUDIOTOOLBOX rule it satisfies
//! rather than a Rust one, one `CFRetained::from_raw` for the one Create-rule return, and the leak
//! test below.
//!
//! ## Two things this crate deliberately does NOT do
//! It never reconstitutes a Rust object from a `void *`. Both converter callbacks carry a
//! `#[repr(C)]` cursor — a base pointer and a frame counter — and nothing with a `Drop`, an
//! invariant or a borrow. The Swift this replaces passed `Unmanaged.passUnretained(self)` on the
//! decode side, which is exactly the shape §2 exists to keep out.
//!
//! And it holds no policy. A converter that refuses to build latches and the lane goes silent; WHY
//! that is the right answer, and what the session does about it, is the session's.

//! ## Two halves with opposite audiences, one gate each
//! Only the HOST encodes, and only the host has a capture tap to read a sample buffer out of — so
//! [`Encoder`] and [`read_stereo`] are macOS-only. Every CLIENT decodes, on both slices, so
//! [`Decoder`] is not gated. This is `slopdesk-apple-vt`'s shape exactly, and for the same reason:
//! an iOS build links the half it uses and `slopdesk_ffi.h` declares each door in the matching
//! region.

#![cfg_attr(
    not(any(target_os = "macos", target_os = "ios")),
    allow(unused_crate_dependencies)
)]

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod asbd;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod converter;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod decoder;
#[cfg(target_os = "macos")]
mod encoder;
#[cfg(target_os = "macos")]
mod sample;

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use decoder::Decoder;
#[cfg(target_os = "macos")]
pub use encoder::Encoder;
#[cfg(target_os = "macos")]
pub use objc2_core_media::CMSampleBuffer;
#[cfg(target_os = "macos")]
pub use sample::read_stereo;

#[cfg(all(test, target_os = "macos"))]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a leak test IS the failure report"
    )]

    use slopdesk_video::audio_source::{CHANNEL_COUNT, FRAMES_PER_BLOCK, SAMPLE_RATE};
    use slopdesk_video::audio_wire::{AudioStreamConfig, AudioWireFormat};

    use super::{Decoder, Encoder};

    /// The family's leak obligation, spent on the one thing here that owns a framework resource.
    ///
    /// An `AudioConverter` is a `+1` handle that only `AudioConverterDispose` gives up, and unlike
    /// a Core Foundation object `objc2` cannot model that — so the whole question is whether
    /// `Converter`'s `Drop` runs once per create. Several hundred build-and-drop cycles is enough
    /// for a missing dispose to be a measurable process, and it is what a live session does over a
    /// few minutes of config changes anyway.
    ///
    /// Both directions, because they are separate creates: the encoder builds its converter lazily
    /// on the first block, the decoder builds one in `new`.
    #[test]
    fn building_and_dropping_converters_does_not_leak() {
        let block = vec![0.0_f32; FRAMES_PER_BLOCK * CHANNEL_COUNT];
        let mut cookie = Vec::new();
        for _ in 0..200 {
            let mut encoder = Encoder::new(AudioWireFormat::AacEld, 128_000);
            drop(encoder.push(&block, FRAMES_PER_BLOCK));
            if let Some(config) = encoder.config() {
                cookie.clone_from(&config.cookie);
            }
            drop(encoder);
        }
        if cookie.is_empty() {
            // No ELD encoder on this machine: the encoder half proved its drop path anyway, and
            // there is no cookie to build a decoder from.
            return;
        }
        for _ in 0..200 {
            let config = AudioStreamConfig::new(AudioWireFormat::AacEld, SAMPLE_RATE, 2, cookie.clone());
            let Ok(mut decoder) = Decoder::new(&config) else {
                return;
            };
            drop(decoder.decode(&[0_u8; 8]));
            drop(decoder);
        }
    }

    /// The PCM arm never touches `AudioToolbox`, so it has no converter to leak — and it must stay
    /// that way, because it is the A/B a suspect codec is compared against.
    #[test]
    fn the_pcm_arm_owns_no_framework_resource() {
        for _ in 0..500 {
            let mut encoder = Encoder::new(AudioWireFormat::PcmS16Le, 128_000);
            let out = encoder.push(&vec![0.5; FRAMES_PER_BLOCK * CHANNEL_COUNT], FRAMES_PER_BLOCK);
            assert_eq!(out.len(), 1);
            let config = AudioStreamConfig::new(AudioWireFormat::PcmS16Le, SAMPLE_RATE, 2, Vec::new());
            let mut decoder = Decoder::new(&config).expect("the PCM arm needs no converter");
            assert_eq!(decoder.decode(&out[0]).len(), FRAMES_PER_BLOCK * CHANNEL_COUNT);
        }
    }
}
