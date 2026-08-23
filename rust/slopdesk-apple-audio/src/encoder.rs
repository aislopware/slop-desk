//! Host side: interleaved stereo `f32` in, wire payloads out.
//!
//! Every DECISION is `slopdesk_video::audio_source`'s — the 480-frame block cadence, the `s16le`
//! pack, the enable-transition drop. What is here is the AAC-ELD converter, the bitrate, the magic
//! cookie, and the fill loop.
//!
//! ## The codec-free arm never touches `AudioToolbox`
//! `SLOPDESK_AUDIO_CODEC=pcm` selects a path with no converter at all: the accumulator hands over a
//! block and `pack_s16le` turns it into bytes. That arm is entirely `slopdesk-video`'s and would
//! work on a machine with no `AudioToolbox`, which is exactly what makes it useful as the A/B
//! against a codec that is misbehaving.
//!
//! ## Why a failed converter latches
//! "This machine has no AAC-ELD encoder" is not a transient. Retrying it per capture buffer would
//! be a hundred refused framework calls a second and a log line for each. So the first refusal sets
//! `failed`, the config stays `None`, the session never sends a config packet, and the client never
//! opens an audio lane. Silence, arrived at once.

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2_audio_toolbox::{
    AudioConverterComplexInputDataProc, AudioConverterFillComplexBuffer, AudioConverterRef,
    kAudioConverterCompressionMagicCookie, kAudioConverterEncodeBitRate,
    kAudioConverterPropertyMaximumOutputPacketSize,
};
use objc2_core_audio_types::{AudioBuffer, AudioBufferList, AudioStreamPacketDescription};
use slopdesk_video::audio_source::{
    BlockAccumulator, CHANNEL_COUNT, FRAMES_PER_BLOCK, SAMPLE_RATE, SAMPLES_PER_BLOCK, pack_s16le,
};
use slopdesk_video::audio_wire::{AudioChannelMessage, AudioStreamConfig, AudioWireFormat};

use crate::asbd::{BYTES_PER_SAMPLE, NO_ERR, OsStatus, aac_eld, float_pcm};
use crate::converter::Converter;

/// The status the input proc answers once the block is fully handed over — `'slop'` as a four-char
/// code, so a status seen in a log is unambiguously ours and not a framework error.
///
/// `AudioConverterFillComplexBuffer` surfaces whatever the input proc returned, and this one means
/// "there is no more input, return what you completed". It is the NORMAL end of every block, not a
/// failure, which is why the fill loop compares against it before it reports anything.
const NO_MORE_INPUT: OsStatus = 0x736C_6F70;

/// A cursor over ONE block of interleaved sample memory, as the converter's callback context.
///
/// `#[repr(C)]` and nothing but scalars and the sample pointer, deliberately. `docs/57` §2 bars
/// this family from reconstituting a Rust object out of a `void *`, and the amendment does not
/// widen that — it widens sample memory. So the context the framework carries is not an `Encoder`
/// and not anything with a `Drop`, an invariant or a borrow: it is the base pointer of the block
/// being fed and how far into it the converter has got.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct Feed {
    /// First sample of the block. Valid for the whole fill loop, because the block is a local of
    /// the frame that calls it.
    base: *mut f32,
    total_frames: u32,
    next_frame: u32,
    channels: u32,
}

/// Hands the converter up to the packets it asked for, then reports the block exhausted.
///
/// For LPCM one packet IS one frame — `float_pcm` says so with `mFramesPerPacket = 1` — so the
/// requested packet count and the frames remaining are in the same unit and no conversion happens
/// here.
///
/// # Safety
/// This is the callback `AudioConverterFillComplexBuffer` invokes, synchronously, inside a call
/// this crate made. The framework's contract for it is: `packet_count` and `data` are live slots it
/// owns for the duration of the callback, and `user_data` is the pointer the caller passed to the
/// same fill call. `Encoder::encode_block` passes `&mut Feed` to a local that outlives the call, so
/// the context is a live, aligned, initialised `Feed`, and this proc is never installed anywhere
/// else. The sample memory it publishes into the buffer list belongs to that same local block and
/// is not touched by anything else while the converter reads it.
///
/// The cursor is advanced BEFORE returning, so a converter that calls back twice within one fill
/// cannot be handed the same frames twice.
#[expect(
    unsafe_code,
    reason = "the AudioConverter input contract publishes sample memory through a C callback"
)]
unsafe extern "C-unwind" fn feed_input(
    _converter: AudioConverterRef,
    packet_count: NonNull<u32>,
    data: NonNull<AudioBufferList>,
    _packet_descriptions: *mut *mut AudioStreamPacketDescription,
    user_data: *mut c_void,
) -> OsStatus {
    let Some(context) = NonNull::new(user_data.cast::<Feed>()) else {
        // SAFETY: framework rule, above — a live out-slot the framework owns for this callback.
        unsafe { packet_count.write(0) };
        return NO_MORE_INPUT;
    };
    // SAFETY: framework rule, above — `user_data` is the `&mut Feed` local the fill call passed.
    let feed = unsafe { context.read() };
    let available = feed.total_frames.saturating_sub(feed.next_frame);
    if available == 0 {
        // SAFETY: framework rule, above — a live out-slot the framework owns for this callback.
        unsafe { packet_count.write(0) };
        return NO_MORE_INPUT;
    }
    // SAFETY: framework rule, above — a live in/out slot carrying what the converter asked for.
    let asked = unsafe { packet_count.read() };
    let provide = asked.min(available);
    let bytes_per_frame = feed.channels.saturating_mul(BYTES_PER_SAMPLE);
    let offset = feed.next_frame as usize * feed.channels as usize;
    // SAFETY: framework rule, above — `offset` is inside the block: `next_frame < total_frames`
    // because `available` is non-zero, and the block is `total_frames * channels` samples long by
    // `encode_block`'s own construction. The result is published, never dereferenced here.
    let base = unsafe { feed.base.add(offset) };
    let list = AudioBufferList {
        mNumberBuffers: 1,
        mBuffers: [AudioBuffer {
            mNumberChannels: feed.channels,
            mDataByteSize: provide.saturating_mul(bytes_per_frame),
            mData: base.cast::<c_void>(),
        }],
    };
    // SAFETY: framework rule, above — a live out-slot the framework owns for this callback. One
    // buffer fits: `AudioBufferList`'s own inline array is exactly one, and the fill call sized the
    // slot as that type.
    unsafe { data.write(list) };
    // SAFETY: framework rule, above — the same live context, advanced past what was handed over.
    unsafe {
        context.write(Feed {
            next_frame: feed.next_frame + provide,
            ..feed
        });
    }
    // SAFETY: framework rule, above — a live out-slot the framework owns for this callback.
    unsafe { packet_count.write(provide) };
    NO_ERR
}

/// The host's audio encoder for one locked wire format.
#[derive(Debug)]
pub struct Encoder {
    format: AudioWireFormat,
    bitrate_bps: u32,
    accumulator: BlockAccumulator,
    /// `None` for the PCM arm, and for AAC until the first block builds one.
    converter: Option<Converter>,
    /// One-shot: a converter that refused to build never retries.
    failed: bool,
    max_packet_bytes: usize,
    config: Option<AudioStreamConfig>,
    /// Output scratch, reused: one allocation for the life of the encoder rather than one per
    /// packet at a hundred packets a second.
    packet: Vec<u8>,
    /// The block currently being fed, owned so the input proc has a stable base pointer.
    block: Vec<f32>,
}

impl Encoder {
    /// An encoder for `format` at `bitrate_bps`.
    ///
    /// The PCM arm's config is known immediately, because there is no codec to ask; the AAC arm's
    /// waits for the converter, because the cookie is the converter's to publish.
    #[must_use]
    pub fn new(format: AudioWireFormat, bitrate_bps: u32) -> Self {
        let config = matches!(format, AudioWireFormat::PcmS16Le).then(|| {
            AudioStreamConfig::new(
                AudioWireFormat::PcmS16Le,
                SAMPLE_RATE,
                u8::try_from(CHANNEL_COUNT).unwrap_or(2),
                Vec::new(),
            )
        });
        Self {
            format,
            bitrate_bps,
            accumulator: BlockAccumulator::new(),
            converter: None,
            failed: false,
            max_packet_bytes: AudioChannelMessage::MAX_PAYLOAD_BYTES,
            config,
            packet: Vec::new(),
            block: Vec::with_capacity(SAMPLES_PER_BLOCK),
        }
    }

    /// The wire config a client needs to decode this stream, once there is one.
    ///
    /// `None` means "do not send a config packet yet", which for the AAC arm means "no frame has
    /// been produced" and, once `failed` latches, means "and none ever will".
    #[must_use]
    pub const fn config(&self) -> Option<&AudioStreamConfig> {
        self.config.as_ref()
    }

    /// Whether the converter refused to build. A permanently silent lane, not a transient.
    #[must_use]
    pub const fn failed(&self) -> bool {
        self.failed
    }

    /// Drops the sub-block remainder AND the codec's carried state — the enable transition.
    ///
    /// Both halves matter and for the same reason: samples accumulated before a disable are
    /// minutes stale by re-enable, and so is the bit reservoir the codec would splice them into.
    /// A failed converter stays failed; this is not a retry.
    pub fn reset(&mut self) {
        self.accumulator.reset();
        if let Some(converter) = self.converter.as_ref() {
            converter.reset();
        }
    }

    /// Appends `frames` of interleaved stereo and encodes every completed block.
    ///
    /// `interleaved.len()` must be exactly `frames × 2`; a mismatch is DROPPED rather than
    /// truncated, because a length that lies would shear the channel interleave and turn one bad
    /// buffer into permanently swapped stereo.
    ///
    /// A block is consumed unconditionally, even when the AAC arm produces nothing for it — a
    /// converter that has gone quiet must not be able to grow the accumulator without bound.
    pub fn push(&mut self, interleaved: &[f32], frames: usize) -> Vec<Vec<u8>> {
        if frames == 0 || interleaved.len() != frames * CHANNEL_COUNT {
            return Vec::new();
        }
        self.accumulator.push(interleaved);
        let mut out = Vec::new();
        loop {
            {
                let Some(block) = self.accumulator.next_block() else {
                    break;
                };
                self.block.clear();
                self.block.extend_from_slice(block);
            }
            // Taken out so the fill loop can hold `&mut self` and the block at once; put back
            // immediately, so the capacity survives to the next block and nothing allocates.
            let mut block = core::mem::take(&mut self.block);
            match self.format {
                AudioWireFormat::PcmS16Le => out.push(pack_s16le(&block)),
                AudioWireFormat::AacEld => self.encode_block(&mut block, &mut out),
            }
            self.block = block;
        }
        out
    }

    /// Builds the converter on first use, stages the bitrate, and publishes the config.
    fn ensure_converter(&mut self) -> Option<&Converter> {
        if self.converter.is_none() {
            if self.failed {
                return None;
            }
            let input = float_pcm(f64::from(SAMPLE_RATE), u32::try_from(CHANNEL_COUNT).unwrap_or(2));
            let output = aac_eld(
                f64::from(SAMPLE_RATE),
                u32::try_from(CHANNEL_COUNT).unwrap_or(2),
                u32::try_from(FRAMES_PER_BLOCK).unwrap_or(480),
            );
            let Ok(converter) = Converter::new(&input, &output) else {
                self.failed = true;
                return None;
            };
            // Best effort: a rate this encoder does not support keeps the codec's own default
            // rather than failing the lane, which is the same call the Swift made and for the same
            // reason — a slightly wrong bitrate is audio, a refused lane is silence.
            let _ = converter.set_u32(kAudioConverterEncodeBitRate, self.bitrate_bps);
            // The magic cookie is the AudioSpecificConfig. Without it the client cannot initialise
            // an ELD decoder at all, so it rides the wire config.
            let cookie = converter
                .get_bytes(kAudioConverterCompressionMagicCookie)
                .unwrap_or_default();
            // The converter's own worst case, capped at what a datagram can carry. Falling back to
            // the cap is safe in the direction that matters: an oversized scratch wastes a few KB,
            // an undersized one truncates a packet into noise.
            self.max_packet_bytes = converter
                .get_u32(kAudioConverterPropertyMaximumOutputPacketSize)
                .and_then(|max| (max > 0).then_some(max as usize))
                .map_or(AudioChannelMessage::MAX_PAYLOAD_BYTES, |max| {
                    max.min(AudioChannelMessage::MAX_PAYLOAD_BYTES)
                });
            self.packet = vec![0_u8; self.max_packet_bytes];
            self.config = Some(AudioStreamConfig::new(
                AudioWireFormat::AacEld,
                SAMPLE_RATE,
                u8::try_from(CHANNEL_COUNT).unwrap_or(2),
                cookie,
            ));
            self.converter = Some(converter);
        }
        self.converter.as_ref()
    }

    /// Feeds one block and drains every access unit it completed.
    ///
    /// The converter's priming means the first block or two may produce nothing, and a later one
    /// may produce two. Neither matters on the wire: audio frames carry no timestamp, and the
    /// client's jitter stage paces by sequence.
    ///
    /// # Safety
    /// `AudioConverterFillComplexBuffer` reads through the input proc and writes through the packet
    /// count, the buffer list and the packet description — all four are live locals of this frame,
    /// and the output buffer it is handed is `self.packet`'s own allocation, described by its own
    /// length. The context handed to the proc is the `feed` local, which outlives the call because
    /// the framework invokes the proc synchronously within it. See `feed_input` for the callback's
    /// half of the contract.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    fn encode_block(&mut self, block: &mut [f32], out: &mut Vec<Vec<u8>>) {
        let channels = u32::try_from(CHANNEL_COUNT).unwrap_or(2);
        let Some(raw) = self.ensure_converter().map(Converter::raw) else {
            return;
        };
        // A whole block, always: `push` only ever hands over what `next_block` completed. Stating
        // it as an equality rather than dividing keeps the frame count a constant the reader can
        // check against the wire cadence, and refuses anything else outright.
        if block.len() != SAMPLES_PER_BLOCK {
            return;
        }
        let Ok(frames) = u32::try_from(FRAMES_PER_BLOCK) else {
            return;
        };
        let mut feed = Feed {
            base: block.as_mut_ptr(),
            total_frames: frames,
            next_frame: 0,
            channels,
        };
        let proc: AudioConverterComplexInputDataProc = Some(feed_input);
        loop {
            let Some(destination) = NonNull::new(self.packet.as_mut_ptr()) else {
                return;
            };
            let Ok(capacity) = u32::try_from(self.packet.len()) else {
                return;
            };
            let mut list = AudioBufferList {
                mNumberBuffers: 1,
                mBuffers: [AudioBuffer {
                    mNumberChannels: channels,
                    mDataByteSize: capacity,
                    mData: destination.cast::<c_void>().as_ptr(),
                }],
            };
            let mut packets = 1_u32;
            let mut description = AudioStreamPacketDescription {
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: 0,
            };
            // SAFETY: framework rule, above — four live locals, and `self.packet` as the sink.
            let status = unsafe {
                AudioConverterFillComplexBuffer(
                    raw,
                    proc,
                    NonNull::from(&mut feed).cast::<c_void>().as_ptr(),
                    NonNull::from(&mut packets),
                    NonNull::from(&mut list),
                    &raw mut description,
                )
            };
            if packets > 0 {
                let produced = (list.mBuffers[0].mDataByteSize as usize).min(self.packet.len());
                if let Some(bytes) = self.packet.get(..produced)
                    && produced > 0
                {
                    out.push(bytes.to_vec());
                }
            }
            // `NO_MORE_INPUT` is the input proc saying the block is spent, which is how every
            // successful block ends. Any other non-`noErr` drops what is left of it.
            if status != NO_ERR || packets == 0 {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::integer_division,
        reason = "a panic in a test IS the failure report, and a block over the channel count is a whole \
                  number of frames by the constants this crate is built on"
    )]

    use slopdesk_video::audio_source::{CHANNEL_COUNT, FRAMES_PER_BLOCK, SAMPLE_RATE};
    use slopdesk_video::audio_wire::AudioWireFormat;

    use super::Encoder;

    #[test]
    fn the_pcm_arm_knows_its_config_before_a_single_sample() {
        // No codec to ask, so the session can send a config packet immediately — which is what
        // makes this arm useful when the AAC one is suspect.
        let encoder = Encoder::new(AudioWireFormat::PcmS16Le, 128_000);
        let config = encoder.config().expect("the PCM config needs no converter");
        assert_eq!(config.format, AudioWireFormat::PcmS16Le);
        assert_eq!(config.sample_rate, SAMPLE_RATE);
        assert_eq!(config.channels, 2);
        assert!(config.cookie.is_empty(), "there is no cookie without a codec");
        assert!(!encoder.failed());
    }

    #[test]
    fn a_short_buffer_accumulates_and_a_full_block_emits() {
        let mut encoder = Encoder::new(AudioWireFormat::PcmS16Le, 128_000);
        let short = FRAMES_PER_BLOCK / 3;
        assert!(
            encoder.push(&vec![0.25; short * CHANNEL_COUNT], short).is_empty(),
            "a third of a block is not a wire frame"
        );
        let rest = FRAMES_PER_BLOCK - short;
        let out = encoder.push(&vec![0.25; rest * CHANNEL_COUNT], rest);
        assert_eq!(out.len(), 1, "the remainder carried across the call boundary");
        // 480 frames × 2 channels × 2 bytes.
        assert_eq!(out[0].len(), FRAMES_PER_BLOCK * CHANNEL_COUNT * 2);
    }

    #[test]
    fn a_length_that_lies_is_dropped_rather_than_sheared() {
        let mut encoder = Encoder::new(AudioWireFormat::PcmS16Le, 128_000);
        // Claims a whole block, hands over one sample short. Truncating would offset every later
        // sample by one channel and swap stereo permanently.
        assert!(
            encoder
                .push(&vec![0.5; FRAMES_PER_BLOCK * CHANNEL_COUNT - 1], FRAMES_PER_BLOCK)
                .is_empty()
        );
        assert!(encoder.push(&[], 0).is_empty());
    }

    #[test]
    fn the_enable_transition_drops_the_remainder() {
        let mut encoder = Encoder::new(AudioWireFormat::PcmS16Le, 128_000);
        let half = FRAMES_PER_BLOCK / 2;
        encoder.push(&vec![0.9; half * CHANNEL_COUNT], half);
        encoder.reset();
        // Splicing the pre-disable half into the first fresh frame would play a five-millisecond
        // shard of minutes-old audio, so the second half must NOT complete a block.
        assert!(encoder.push(&vec![0.1; half * CHANNEL_COUNT], half).is_empty());
    }

    #[test]
    fn the_aac_arm_builds_a_real_converter_and_publishes_a_cookie() {
        // An AudioConverter is an in-process codec — no window server, no device, no TCC — so
        // unlike the capture and compression crates this one CAN be built under `cargo test`. What
        // is not asserted is the bytes it produced: AAC-ELD output is not specified bit for bit.
        let mut encoder = Encoder::new(AudioWireFormat::AacEld, 128_000);
        assert!(
            encoder.config().is_none(),
            "no cookie before the converter exists"
        );
        let produced = encoder.push(&vec![0.0; FRAMES_PER_BLOCK * CHANNEL_COUNT], FRAMES_PER_BLOCK);
        if encoder.failed() {
            // A machine with no ELD encoder is a real answer: silent lane, no config, no retry.
            assert!(encoder.config().is_none());
            assert!(produced.is_empty());
            return;
        }
        let config = encoder.config().expect("a built converter publishes its config");
        assert_eq!(config.format, AudioWireFormat::AacEld);
        assert_eq!(config.sample_rate, SAMPLE_RATE);
        assert!(
            !config.cookie.is_empty(),
            "without the AudioSpecificConfig no client can initialise an ELD decoder"
        );
    }

    #[test]
    fn the_aac_arm_reaches_its_wire_cadence() {
        let mut encoder = Encoder::new(AudioWireFormat::AacEld, 128_000);
        let mut packets = 0_usize;
        // Twenty blocks is two hundred milliseconds — far past the converter's priming delay, so
        // an arm that produces nothing at all is broken rather than warming up.
        for _ in 0..20 {
            packets += encoder
                .push(&vec![0.0; FRAMES_PER_BLOCK * CHANNEL_COUNT], FRAMES_PER_BLOCK)
                .len();
        }
        if encoder.failed() {
            return;
        }
        assert!(
            packets > 0,
            "twenty blocks in, the converter has produced nothing"
        );
        // Priming withholds a block or two at the start; it never invents extra ones.
        assert!(packets <= 20, "more packets than blocks fed");
        for payload in encoder.push(&vec![0.0; FRAMES_PER_BLOCK * CHANNEL_COUNT], FRAMES_PER_BLOCK) {
            assert!(!payload.is_empty());
            assert!(
                payload.len() <= 8192,
                "a payload past the datagram cap cannot be sent"
            );
        }
    }
}
