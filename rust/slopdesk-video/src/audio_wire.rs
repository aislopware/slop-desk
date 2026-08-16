//! Host→client app audio — `Sources/SlopDeskVideoProtocol/AudioWireCodec.swift`.
//!
//! One datagram per message on the media socket (channel tag 6), sent IMMEDIATE: no packetizer, no
//! FEC, no retransmit. A lost ~10 ms audio frame is cheaper to conceal — the client's jitter ring
//! underruns to silence — than to wait for, and neither stream may ever delay the other.
//!
//! ```text
//! off 0: u32  seq                — ONE monotonic counter for ALL tag-6 packets of a session
//!                                  (config and frames share it; the client orders and late-drops on it)
//! off 4: u32  host_send_ts_millis — host-monotonic ms, same contract as the fragment header:
//!                                  relative to the host session, NEVER cross-clock arithmetic
//! off 8: u8   flags              — bit0 = config packet; bits 1-7 reserved (encode 0, decode ignore)
//! off 9: u16  payload length     — must equal the remaining byte count EXACTLY; ≤ 8192
//! off11: payload
//! ```
//!
//! A frame payload is one encoded codec frame; a config payload is an [`AudioStreamConfig`]:
//!
//! ```text
//! off 0: u8   format id   — an `AudioWireFormat`; unknown ⇒ malformed
//! off 1: u32  sample rate — Hz (48000); 0 ⇒ malformed
//! off 5: u8   channels    — interleaved channel count (2); 0 ⇒ malformed
//! off 6: u16  cookie len  — must equal the remaining byte count exactly
//! off 8: cookie
//! ```
//!
//! Pinned by the `audioWire` golden vectors.
//!
//! ## Validate then drop, in both grammars
//!
//! Every inconsistency is a decode error the receiver drops the datagram on: a declared length past
//! the end is truncation, an over-cap length or trailing bytes are malformed. The reserved flag
//! bits are the one exception — they are IGNORED, so a future sender can set them without breaking
//! this decoder. Only bit 0 selects the payload grammar.

use crate::bytes::{ByteReader, ByteWriter, truncating_u16};
use crate::error::{Result, VideoProtocolError};

/// The codec the host's app audio rides the wire in.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum AudioWireFormat {
    /// AAC-ELD access units — the default: low-delay, ~10 ms frames. The config cookie carries the
    /// AAC magic cookie the decoder needs.
    #[default]
    AacEld,
    /// Interleaved signed 16-bit little-endian PCM, 480 samples × channels per frame: the
    /// codec-free fallback (`SLOPDESK_AUDIO_CODEC=pcm`). The cookie is empty.
    PcmS16Le,
}

impl AudioWireFormat {
    /// The on-wire format id.
    #[must_use]
    pub const fn raw_value(self) -> u8 {
        match self {
            Self::AacEld => 1,
            Self::PcmS16Le => 2,
        }
    }

    /// Parses a wire format id, or `None` for one this build does not speak — which makes the
    /// client DROP the config, and with it the stream, rather than feed garbage to a decoder.
    #[must_use]
    pub const fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            1 => Some(Self::AacEld),
            2 => Some(Self::PcmS16Le),
            _ => None,
        }
    }
}

/// The audio stream's decode parameters.
///
/// The client rebuilds its decoder only when a received config DIFFERS from the one in force. The
/// host re-sends it about a second apart because UDP may drop any single copy, so re-application
/// must be — and is — idempotent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioStreamConfig {
    /// The codec.
    pub format: AudioWireFormat,
    /// Sample rate in Hz — 48000 on the live host path.
    pub sample_rate: u32,
    /// Interleaved channel count — 2 on the live host path.
    pub channels: u8,
    /// The AAC magic cookie the decoder is initialised from; empty for
    /// [`AudioWireFormat::PcmS16Le`].
    pub cookie: Vec<u8>,
}

impl AudioStreamConfig {
    /// Builds a config.
    #[must_use]
    pub const fn new(format: AudioWireFormat, sample_rate: u32, channels: u8, cookie: Vec<u8>) -> Self {
        Self {
            format,
            sample_rate,
            channels,
            cookie,
        }
    }
}

/// One host→client audio datagram.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AudioChannelMessage {
    /// The stream's decode parameters, sent when audio is (re-)enabled and re-sent on a slow
    /// heartbeat so a client that missed a copy — or attached late — still locks on.
    Config {
        /// The shared tag-6 sequence number.
        seq: u32,
        /// Host-monotonic send timestamp, milliseconds.
        host_send_ts_millis: u32,
        /// The parameters.
        config: AudioStreamConfig,
    },
    /// One encoded ~10 ms audio frame.
    Frame {
        /// The shared tag-6 sequence number.
        seq: u32,
        /// Host-monotonic send timestamp, milliseconds.
        host_send_ts_millis: u32,
        /// The encoded frame.
        payload: Vec<u8>,
    },
}

impl AudioChannelMessage {
    /// Header size in bytes.
    pub const HEADER_SIZE: usize = 11;
    /// Hostile-input cap on the declared payload length — generous over the real maximum (a
    /// 1920-byte PCM frame; AAC-ELD frames are far smaller) while bounding what a corrupt length
    /// can make the receiver allocate.
    pub const MAX_PAYLOAD_BYTES: usize = 8192;
    /// Header flags bit 0: the payload is an [`AudioStreamConfig`], not a codec frame.
    const CONFIG_FLAG: u8 = 1 << 0;

    /// Serialises the datagram.
    ///
    /// The CALLER keeps payloads within [`Self::MAX_PAYLOAD_BYTES`] — the encoder emits at most a
    /// couple of kilobytes by construction — and the length field truncates to `u16` like every
    /// other wire count.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        match *self {
            Self::Config {
                seq,
                host_send_ts_millis,
                ref config,
            } => {
                encode_message(
                    seq,
                    host_send_ts_millis,
                    Self::CONFIG_FLAG,
                    &encode_config_payload(config),
                )
            },
            Self::Frame {
                seq,
                host_send_ts_millis,
                ref payload,
            } => encode_message(seq, host_send_ts_millis, 0, payload),
        }
    }

    /// Parses one datagram.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when a declared length runs past the datagram end;
    /// [`VideoProtocolError::Malformed`] for an over-cap length, trailing bytes, an unknown audio
    /// format, or a zero sample rate or channel count.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let (seq, host_send_ts_millis, is_config, payload) = decode_parts(data)?;
        if !is_config {
            return Ok(Self::Frame {
                seq,
                host_send_ts_millis,
                payload: payload.to_vec(),
            });
        }
        let (format, sample_rate, channels, cookie) = decode_config_parts(payload)?;
        Ok(Self::Config {
            seq,
            host_send_ts_millis,
            config: AudioStreamConfig::new(format, sample_rate, channels, cookie.to_vec()),
        })
    }
}

/// The datagram's header and the span its payload occupies — every guard applied, nothing copied.
///
/// This is where the declared length is checked: over the cap is malformed, past the end is
/// truncated, and a byte left over is malformed. [`AudioChannelMessage::decode`] is this function
/// plus a `to_vec`, so a caller that already holds the datagram can skip the copy without skipping
/// a check.
///
/// # Errors
/// As [`AudioChannelMessage::decode`], minus the config grammar.
pub fn decode_parts(data: &[u8]) -> Result<(u32, u32, bool, &[u8])> {
    let mut reader = ByteReader::new(data);
    let seq = reader.read_u32()?;
    let host_send_ts_millis = reader.read_u32()?;
    let flags = reader.read_u8()?;
    let payload_len = usize::from(reader.read_u16()?);
    if payload_len > AudioChannelMessage::MAX_PAYLOAD_BYTES {
        return Err(VideoProtocolError::malformed(format!(
            "audio payloadLen {payload_len} exceeds cap {}",
            AudioChannelMessage::MAX_PAYLOAD_BYTES
        )));
    }
    // `read_bytes` bounds-checks against the buffer BEFORE reading, so a corrupt length drops the
    // datagram rather than over-reading or over-allocating.
    let payload = reader.read_bytes(payload_len)?;
    let trailing = reader.bytes_remaining();
    if trailing != 0 {
        return Err(VideoProtocolError::malformed(format!(
            "audio datagram carries {trailing} trailing bytes"
        )));
    }
    Ok((
        seq,
        host_send_ts_millis,
        flags & AudioChannelMessage::CONFIG_FLAG != 0,
        payload,
    ))
}

/// The config payload's parameters and the span its cookie occupies, borrowed the same way.
///
/// # Errors
/// [`VideoProtocolError::Malformed`] for an unknown format, a zero sample rate or channel count, or
/// a cookie length that does not consume the payload exactly.
pub fn decode_config_parts(payload: &[u8]) -> Result<(AudioWireFormat, u32, u8, &[u8])> {
    let mut reader = ByteReader::new(payload);
    let format_id = reader.read_u8()?;
    let format = AudioWireFormat::from_raw(format_id)
        .ok_or_else(|| VideoProtocolError::malformed(format!("unknown audio wire format {format_id}")))?;
    let sample_rate = reader.read_u32()?;
    let channels = reader.read_u8()?;
    if sample_rate == 0 || channels == 0 {
        return Err(VideoProtocolError::malformed(
            "audio config with zero sampleRate/channels",
        ));
    }
    let cookie_len = usize::from(reader.read_u16()?);
    let cookie = reader.read_bytes(cookie_len)?;
    let trailing = reader.bytes_remaining();
    if trailing != 0 {
        return Err(VideoProtocolError::malformed(format!(
            "audio config carries {trailing} trailing cookie bytes"
        )));
    }
    Ok((format, sample_rate, channels, cookie))
}

fn encode_message(seq: u32, host_send_ts_millis: u32, flags: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(AudioChannelMessage::HEADER_SIZE + payload.len());
    out.put_u32(seq);
    out.put_u32(host_send_ts_millis);
    out.put_u8(flags);
    out.put_u16(truncating_u16(payload.len()));
    out.put_bytes(payload);
    out.into_vec()
}

fn encode_config_payload(config: &AudioStreamConfig) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(8 + config.cookie.len());
    out.put_u8(config.format.raw_value());
    out.put_u32(config.sample_rate);
    out.put_u8(config.channels);
    // The cookie is an AAC magic cookie — tens of bytes — so this length truncates to `u16` like
    // every other wire count.
    out.put_u16(truncating_u16(config.cookie.len()));
    out.put_bytes(&config.cookie);
    out.into_vec()
}

/// The full-scale divisor a signed 16-bit sample is normalised by.
pub const PCM_S16_FULL_SCALE: f32 = 32768.0;

/// Converts an interleaved signed-16-bit little-endian payload to the interleaved float samples the
/// jitter ring holds.
///
/// This is the codec-free fallback's whole decoder: a pure sample-format convert with no state, so
/// unlike the AAC path a corrupt payload cannot poison the frames after it. A payload that is not a
/// whole number of interleaved FRAMES is corrupt and drops entirely — a partial frame in the ring
/// would offset every later sample by one channel, turning a single bad datagram into permanently
/// swapped stereo.
///
/// The bytes are assembled explicitly rather than read as words: the payload is a wire slice with
/// no alignment guarantee, and the wire is little-endian regardless of what the machine is.
#[must_use]
pub fn decode_pcm_s16le(payload: &[u8], channels: usize) -> Vec<f32> {
    let bytes_per_frame = 2 * channels;
    if payload.is_empty() || bytes_per_frame == 0 || !payload.len().is_multiple_of(bytes_per_frame) {
        return Vec::new();
    }
    payload
        .chunks_exact(2)
        .map(|pair| {
            let raw = match *pair {
                [lo, hi] => u16::from_le_bytes([lo, hi]),
                _ => 0,
            };
            f32::from(raw.cast_signed()) / PCM_S16_FULL_SCALE
        })
        .collect()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{AudioChannelMessage, AudioStreamConfig, AudioWireFormat, decode_pcm_s16le};
    use crate::error::VideoProtocolError;

    fn sample_config() -> AudioChannelMessage {
        AudioChannelMessage::Config {
            seq: 1,
            host_send_ts_millis: 250,
            config: AudioStreamConfig::new(AudioWireFormat::AacEld, 48_000, 2, vec![0xDE, 0xAD]),
        }
    }

    #[test]
    fn full_scale_and_silence_land_where_the_ring_expects_them() {
        assert_eq!(decode_pcm_s16le(&[0x00, 0x00, 0xFF, 0x7F], 1), vec![
            0.0,
            32767.0 / 32768.0
        ]);
        assert_eq!(
            decode_pcm_s16le(&[0x00, 0x80], 1),
            vec![-1.0],
            "the negative full scale is exactly minus one",
        );
    }

    #[test]
    fn the_wire_stays_little_endian_whatever_the_machine_is() {
        // 0x0100 little-endian is 256, not 1.
        assert_eq!(decode_pcm_s16le(&[0x00, 0x01], 1), vec![256.0 / 32768.0]);
    }

    #[test]
    fn a_payload_that_is_not_whole_frames_drops_rather_than_offsetting_every_later_sample() {
        assert!(decode_pcm_s16le(&[0x00, 0x00, 0xFF, 0x7F, 0x11], 2).is_empty());
        assert!(
            decode_pcm_s16le(&[0x00, 0x00], 2).is_empty(),
            "half a stereo frame is not a frame"
        );
        assert!(decode_pcm_s16le(&[], 2).is_empty());
        assert!(
            decode_pcm_s16le(&[0x00, 0x00], 0).is_empty(),
            "a channel-less config decodes nothing"
        );
    }

    #[test]
    fn a_whole_stereo_frame_keeps_its_channels_interleaved() {
        assert_eq!(
            decode_pcm_s16le(&[0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F, 0x00, 0x40], 2),
            vec![-1.0, 0.0, 32767.0 / 32768.0, 0.5],
        );
    }

    #[test]
    fn a_config_and_a_frame_both_round_trip() {
        let cases = [
            sample_config(),
            AudioChannelMessage::Frame {
                seq: 2,
                host_send_ts_millis: 251,
                payload: vec![1, 2, 3, 4],
            },
            AudioChannelMessage::Frame {
                seq: u32::MAX,
                host_send_ts_millis: 0xDEAD_BEEF,
                payload: Vec::new(),
            },
        ];
        for case in cases {
            assert_eq!(AudioChannelMessage::decode(&case.encode()), Ok(case));
        }
    }

    #[test]
    fn a_pcm_config_carries_no_cookie() {
        let message = AudioChannelMessage::Config {
            seq: 9,
            host_send_ts_millis: 1,
            config: AudioStreamConfig::new(AudioWireFormat::PcmS16Le, 48_000, 2, Vec::new()),
        };
        assert_eq!(AudioChannelMessage::decode(&message.encode()), Ok(message));
    }

    #[test]
    fn reserved_flag_bits_do_not_change_the_payload_grammar() {
        // Bit 0 clear with every other bit set: still a frame, so an old client survives a new host.
        let mut bytes = AudioChannelMessage::Frame {
            seq: 1,
            host_send_ts_millis: 2,
            payload: vec![7],
        }
        .encode();
        bytes[8] = 0b1111_1110;
        let decoded = AudioChannelMessage::decode(&bytes).expect("reserved bits are ignored");
        assert!(matches!(decoded, AudioChannelMessage::Frame { .. }));
    }

    #[test]
    fn trailing_bytes_and_an_over_cap_length_are_both_malformed() {
        let mut trailing = sample_config().encode();
        trailing.push(0);
        assert!(matches!(
            AudioChannelMessage::decode(&trailing),
            Err(VideoProtocolError::Malformed(_))
        ));

        let mut over_cap = vec![0, 0, 0, 1, 0, 0, 0, 2, 0, 0xFF, 0xFF];
        over_cap.resize(11 + 65535, 0);
        assert!(matches!(
            AudioChannelMessage::decode(&over_cap),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn a_length_past_the_datagram_end_is_truncation_not_an_allocation() {
        let bytes = [0, 0, 0, 1, 0, 0, 0, 2, 0, 0x10, 0x00];
        assert_eq!(
            AudioChannelMessage::decode(&bytes),
            Err(VideoProtocolError::Truncated)
        );
    }

    #[test]
    fn an_unknown_format_and_a_zero_rate_both_drop_the_config() {
        let mut unknown = sample_config().encode();
        unknown[11] = 99;
        assert!(matches!(
            AudioChannelMessage::decode(&unknown),
            Err(VideoProtocolError::Malformed(_))
        ));

        let mut zero_rate = sample_config().encode();
        zero_rate.splice(12..16, [0, 0, 0, 0]);
        assert!(matches!(
            AudioChannelMessage::decode(&zero_rate),
            Err(VideoProtocolError::Malformed(_))
        ));
    }
}
