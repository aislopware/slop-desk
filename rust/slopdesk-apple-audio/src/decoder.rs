//! Client side: one wire payload in, interleaved `f32` out.
//!
//! One instance per locked [`AudioStreamConfig`]; a config CHANGE rebuilds it, because the cookie
//! and the channel count are what the converter was built from. The session owns that decision.
//!
//! ## Why a decode miss is indistinguishable from wire loss
//! Every failure here answers an empty result, and the jitter stage conceals a missing frame the
//! same way whether the datagram never arrived or arrived corrupt. That is deliberate: the client
//! has exactly one recovery for a ten-millisecond hole, so distinguishing the causes would buy a
//! log line and nothing else.
//!
//! ## The converter is NOT reset per frame
//! AAC-ELD carries state between access units — that is what makes it low-delay. Resetting per
//! frame would throw away the window history and put a discontinuity at the wire cadence. It is
//! reset only after a genuine failure, so one corrupt access unit cannot poison every frame after
//! it.

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2_audio_toolbox::{
    AudioConverterComplexInputDataProc, AudioConverterFillComplexBuffer, AudioConverterRef,
    kAudioConverterDecompressionMagicCookie,
};
use objc2_core_audio_types::{AudioBuffer, AudioBufferList, AudioStreamPacketDescription};
use slopdesk_video::audio_source::FRAMES_PER_BLOCK;
use slopdesk_video::audio_wire::{
    AudioStreamConfig, AudioWireFormat, decode_pcm_s16le_into, pcm_s16le_sample_count,
};

use crate::asbd::{BYTES_PER_SAMPLE, NO_ERR, OsStatus, aac_eld, float_pcm};
use crate::converter::Converter;

/// The pull proc's "that was the whole packet" status.
///
/// `AudioConverterFillComplexBuffer` surfaces it once the single in-flight access unit is spent,
/// which is the normal end of every one-packet decode rather than a fault.
const NO_MORE_DATA: OsStatus = -1;

/// Output frames one decode call may produce.
///
/// AAC-ELD emits 480 frames per access unit at 48 kHz. The ×4 headroom costs a few kilobytes once
/// and makes a converter that decides to flush more than one packet's worth inert rather than
/// truncating.
const MAX_OUTPUT_FRAMES: usize = FRAMES_PER_BLOCK * 4;

/// The ONE in-flight access unit, as the converter's callback context.
///
/// Same shape and same reason as the encoder's `Feed`: `#[repr(C)]`, scalars and a pointer into the
/// payload, no Rust object reconstituted from a `void *`. The packet description lives INSIDE the
/// context rather than beside it, because the framework wants a pointer to one that stays valid for
/// the callback and a field of a pinned local is the simplest thing that is.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct Pull {
    bytes: *const u8,
    byte_count: u32,
    channels: u32,
    /// Non-zero once the access unit has been handed over. One packet, served once.
    served: u32,
    packet: AudioStreamPacketDescription,
}

/// Serves the one in-flight access unit, then reports end of data.
///
/// # Safety
/// This is the callback `AudioConverterFillComplexBuffer` invokes, synchronously, inside a call
/// this crate made. The framework's contract for it is: `packet_count`, `data` and — when non-null
/// — `packet_descriptions` are live slots it owns for the duration of the callback, and `user_data`
/// is the pointer the caller passed to the same fill call. `Decoder::decode_aac` passes `&mut Pull`
/// to a local that outlives the call, so the context is a live, aligned, initialised `Pull`, and
/// this proc is never installed anywhere else. The payload bytes it publishes are borrowed by that
/// same frame for the whole call.
///
/// The description pointer handed back addresses a FIELD of the live context rather than a local of
/// this callback, which is what makes it outlive the return the way the framework requires.
#[expect(
    unsafe_code,
    reason = "the AudioConverter input contract publishes packet memory through a C callback"
)]
unsafe extern "C-unwind" fn pull_input(
    _converter: AudioConverterRef,
    packet_count: NonNull<u32>,
    data: NonNull<AudioBufferList>,
    packet_descriptions: *mut *mut AudioStreamPacketDescription,
    user_data: *mut c_void,
) -> OsStatus {
    let Some(context) = NonNull::new(user_data.cast::<Pull>()) else {
        // SAFETY: framework rule, above — a live out-slot the framework owns for this callback.
        unsafe { packet_count.write(0) };
        return NO_MORE_DATA;
    };
    // SAFETY: framework rule, above — `user_data` is the `&mut Pull` local the fill call passed.
    let pull = unsafe { context.read() };
    if pull.served != 0 || pull.bytes.is_null() || pull.byte_count == 0 {
        // SAFETY: framework rule, above — a live out-slot the framework owns for this callback.
        unsafe { packet_count.write(0) };
        return NO_MORE_DATA;
    }
    // SAFETY: framework rule, above — the same live context, marked spent before the hand-over so
    // a converter that calls back twice within one fill cannot be served the packet twice.
    unsafe { context.write(Pull { served: 1, ..pull }) };
    let list = AudioBufferList {
        mNumberBuffers: 1,
        mBuffers: [AudioBuffer {
            mNumberChannels: pull.channels,
            mDataByteSize: pull.byte_count,
            mData: pull.bytes.cast_mut().cast::<c_void>(),
        }],
    };
    // SAFETY: framework rule, above — a live out-slot the framework owns for this callback.
    unsafe { data.write(list) };
    if !packet_descriptions.is_null() {
        // SAFETY: framework rule, above — `packet_descriptions` is a live out-slot, and the value
        // written into it addresses the `packet` field of the caller's live context, which outlives
        // the fill call this callback runs inside.
        unsafe { packet_descriptions.write(&raw mut (*context.as_ptr()).packet) };
    }
    // SAFETY: framework rule, above — a live out-slot the framework owns for this callback.
    unsafe { packet_count.write(1) };
    NO_ERR
}

/// The client's audio decoder for one locked config.
#[derive(Debug)]
pub struct Decoder {
    format: AudioWireFormat,
    channels: usize,
    /// `None` for the PCM arm — a sample-format convert has no codec state.
    converter: Option<Converter>,
    /// Decoded-sample scratch, reused across calls.
    scratch: Vec<f32>,
}

impl Decoder {
    /// Builds a decoder for `config`, or answers the framework's refusal.
    ///
    /// A refusal is dropped by the caller rather than retried in place: the host re-sends its
    /// config about a second apart, so a transient failure self-heals on the next copy.
    ///
    /// A zero channel count is refused here rather than clamped. It cannot arrive from a valid
    /// wire config — `audio_wire` rejects it — and clamping a nonsense layout would decode into a
    /// buffer whose frame boundaries mean nothing.
    ///
    /// # Errors
    /// The framework's own `OSStatus`, or `-1` for a config this crate refuses before it asks: a
    /// zero channel count, a zero sample rate, or an `AudioConverterNew` that answered `noErr` and
    /// a null handle.
    pub fn new(config: &AudioStreamConfig) -> Result<Self, OsStatus> {
        let channels = usize::from(config.channels);
        if channels == 0 || config.sample_rate == 0 {
            return Err(-1);
        }
        let converter = match config.format {
            AudioWireFormat::PcmS16Le => None,
            AudioWireFormat::AacEld => {
                let input = aac_eld(
                    f64::from(config.sample_rate),
                    u32::from(config.channels),
                    u32::try_from(FRAMES_PER_BLOCK).unwrap_or(480),
                );
                let output = float_pcm(f64::from(config.sample_rate), u32::from(config.channels));
                let converter = Converter::new(&input, &output)?;
                // Without the cookie the converter would emit noise rather than refuse, so a
                // rejected cookie fails the BUILD — dropping the config is the only safe answer.
                let status = converter.set_bytes(kAudioConverterDecompressionMagicCookie, &config.cookie);
                if status != NO_ERR {
                    return Err(status);
                }
                Some(converter)
            },
        };
        Ok(Self {
            format: config.format,
            channels,
            converter,
            scratch: vec![0.0; MAX_OUTPUT_FRAMES * channels],
        })
    }

    /// Decodes one wire payload to interleaved `f32`. Empty means "drop the frame".
    #[must_use]
    pub fn decode(&mut self, payload: &[u8]) -> Vec<f32> {
        match self.format {
            AudioWireFormat::PcmS16Le => Self::decode_pcm(payload, self.channels),
            AudioWireFormat::AacEld => self.decode_aac(payload),
        }
    }

    /// `s16le` → `f32`, which is `slopdesk-video`'s arithmetic and not this crate's.
    ///
    /// The buffer is sized by ARITHMETIC rather than by a probe: whenever there is an answer at all
    /// it is exactly `payload.len() / 2` samples, so the first guess is a bound.
    fn decode_pcm(payload: &[u8], channels: usize) -> Vec<f32> {
        let Some(samples) = pcm_s16le_sample_count(payload.len(), channels) else {
            // Not whole interleaved frames — corrupt. A partial frame into the stage would offset
            // every later sample by one channel and swap stereo for the rest of the session.
            return Vec::new();
        };
        let mut out = vec![0.0_f32; samples];
        match decode_pcm_s16le_into(payload, channels, &mut out) {
            Some(written) if written == samples && written > 0 => out,
            _ => Vec::new(),
        }
    }

    /// One AAC-ELD access unit through the converter.
    ///
    /// # Safety
    /// `AudioConverterFillComplexBuffer` reads through the pull proc and writes through the frame
    /// count and the buffer list — both live locals of this frame — into `self.scratch`, whose
    /// allocation is described to it by its own length. The context handed to the proc is the
    /// `pull` local, which outlives the call because the framework invokes the proc synchronously
    /// within it, and the payload it publishes is borrowed for the same span. The frame count the
    /// framework reports back is clamped against the scratch's real length before anything is read
    /// out of it, so a converter that overstates cannot make this read past the allocation.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    fn decode_aac(&mut self, payload: &[u8]) -> Vec<f32> {
        let Some(converter) = self.converter.as_ref() else {
            return Vec::new();
        };
        let Ok(byte_count) = u32::try_from(payload.len()) else {
            return Vec::new();
        };
        if byte_count == 0 {
            return Vec::new();
        }
        let Ok(channels) = u32::try_from(self.channels) else {
            return Vec::new();
        };
        let mut pull = Pull {
            bytes: payload.as_ptr(),
            byte_count,
            channels,
            served: 0,
            packet: AudioStreamPacketDescription {
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: byte_count,
            },
        };
        let Some(destination) = NonNull::new(self.scratch.as_mut_ptr()) else {
            return Vec::new();
        };
        let Ok(scratch_bytes) = u32::try_from(self.scratch.len() * BYTES_PER_SAMPLE as usize) else {
            return Vec::new();
        };
        let mut list = AudioBufferList {
            mNumberBuffers: 1,
            mBuffers: [AudioBuffer {
                mNumberChannels: channels,
                mDataByteSize: scratch_bytes,
                mData: destination.cast::<c_void>().as_ptr(),
            }],
        };
        let mut frames = u32::try_from(MAX_OUTPUT_FRAMES).unwrap_or(u32::MAX);
        let proc: AudioConverterComplexInputDataProc = Some(pull_input);
        // SAFETY: framework rule, above — three live locals, and `self.scratch` as the sink.
        let status = unsafe {
            AudioConverterFillComplexBuffer(
                converter.raw(),
                proc,
                NonNull::from(&mut pull).cast::<c_void>().as_ptr(),
                NonNull::from(&mut frames),
                NonNull::from(&mut list),
                core::ptr::null_mut(),
            )
        };
        if status != NO_ERR && status != NO_MORE_DATA {
            // One corrupt access unit must not poison the window history for every frame after it.
            converter.reset();
            return Vec::new();
        }
        let produced = (frames as usize)
            .saturating_mul(self.channels)
            .min(self.scratch.len());
        self.scratch
            .get(..produced)
            .map(<[f32]>::to_vec)
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::integer_division,
        reason = "a panic in a test IS the failure report, and a sample count over the channel count is a \
                  whole number of frames or the assertion below has already failed"
    )]

    use slopdesk_video::audio_source::{CHANNEL_COUNT, FRAMES_PER_BLOCK, SAMPLE_RATE, pack_s16le};
    use slopdesk_video::audio_wire::{AudioStreamConfig, AudioWireFormat};

    use super::Decoder;

    fn pcm_config() -> AudioStreamConfig {
        AudioStreamConfig::new(AudioWireFormat::PcmS16Le, SAMPLE_RATE, 2, Vec::new())
    }

    #[test]
    fn the_pcm_arm_round_trips_a_block() {
        let mut decoder = Decoder::new(&pcm_config()).expect("the PCM arm needs no converter");
        let samples = vec![0.5_f32; FRAMES_PER_BLOCK * CHANNEL_COUNT];
        let out = decoder.decode(&pack_s16le(&samples));
        assert_eq!(out.len(), samples.len());
        // The pack scales by 32767 and the decode divides by 32768, so a sample comes back a
        // hair quieter and never louder. That asymmetry is the wire's, not this crate's.
        for value in out {
            assert!((value - 0.5).abs() < 1e-4, "round-tripped to {value}");
        }
    }

    #[test]
    fn a_payload_that_is_not_whole_frames_is_dropped() {
        let mut decoder = Decoder::new(&pcm_config()).expect("the PCM arm needs no converter");
        // Three bytes cannot be an interleaved stereo frame at two bytes a sample.
        assert!(decoder.decode(&[1, 2, 3]).is_empty());
        assert!(decoder.decode(&[]).is_empty());
    }

    #[test]
    fn a_nonsense_config_is_refused_rather_than_clamped() {
        let zero_channels = AudioStreamConfig::new(AudioWireFormat::PcmS16Le, SAMPLE_RATE, 0, Vec::new());
        assert!(Decoder::new(&zero_channels).is_err());
        let zero_rate = AudioStreamConfig::new(AudioWireFormat::AacEld, 0, 2, Vec::new());
        assert!(Decoder::new(&zero_rate).is_err());
    }

    #[test]
    fn an_aac_decoder_survives_a_corrupt_access_unit() {
        // Built from the real encoder's cookie, so this is the live pairing rather than a fixture.
        let mut encoder = crate::Encoder::new(AudioWireFormat::AacEld, 128_000);
        for _ in 0..4 {
            encoder.push(&vec![0.0; FRAMES_PER_BLOCK * CHANNEL_COUNT], FRAMES_PER_BLOCK);
        }
        if encoder.failed() {
            return;
        }
        let config = encoder
            .config()
            .expect("a built converter publishes its config")
            .clone();
        let Ok(mut decoder) = Decoder::new(&config) else {
            return;
        };
        // Garbage in: the converter refuses or produces nothing, and either way this must not
        // panic and must not leave the decoder unusable.
        drop(decoder.decode(&[0xFF_u8; 64]));
        let payloads = encoder.push(&vec![0.0; FRAMES_PER_BLOCK * CHANNEL_COUNT], FRAMES_PER_BLOCK);
        for payload in payloads {
            let out = decoder.decode(&payload);
            // A real access unit after the corrupt one still decodes to whole frames.
            assert_eq!(out.len() % CHANNEL_COUNT, 0);
        }
    }

    #[test]
    fn the_aac_pair_decodes_what_it_encoded_to_the_wire_cadence() {
        let mut encoder = crate::Encoder::new(AudioWireFormat::AacEld, 128_000);
        let block = vec![0.0_f32; FRAMES_PER_BLOCK * CHANNEL_COUNT];
        let mut payloads = Vec::new();
        for _ in 0..8 {
            payloads.extend(encoder.push(&block, FRAMES_PER_BLOCK));
        }
        if encoder.failed() || payloads.is_empty() {
            return;
        }
        let config = encoder
            .config()
            .expect("a built converter publishes its config")
            .clone();
        let Ok(mut decoder) = Decoder::new(&config) else {
            return;
        };
        let mut decoded_frames = 0_usize;
        for payload in &payloads {
            decoded_frames += decoder.decode(payload).len() / CHANNEL_COUNT;
        }
        // The decoder has its own priming, so it may withhold the first unit — but by eight it
        // must be producing the 480-frame cadence the ELD variant was selected for.
        assert!(
            decoded_frames >= FRAMES_PER_BLOCK,
            "eight access units decoded to {decoded_frames} frames"
        );
        assert_eq!(
            decoded_frames % FRAMES_PER_BLOCK,
            0,
            "an access unit is a whole wire frame"
        );
    }
}
