//! Client→host loss-recovery / acknowledgement codec — a port of the codec half of
//! Swift `RecoverySignaling` (`NetworkStatsReport`, `RecoveryMessage`).
//!
//! Recovery prefers an LTR refresh over a forced IDR. A `NetworkStats` report rides the
//! same channel. Every body is fixed-width; the decoder additionally REJECTS trailing
//! bytes so byte-keyed host dedup cannot be bypassed by suffix-varied copies.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};

/// A client→host network-feedback telemetry report.
///
/// Eleven fixed-width `u32`s; all fields
/// are RELATIVE (windowed counters / a host-stamp echo / client-local deltas) so the host
/// derives RTT in its own clock with no cross-machine skew.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NetworkStatsReport {
    /// Complete frames received this window.
    pub frames_received: u32,
    /// Of those, how many were completed via FEC recovery.
    pub fec_recovered: u32,
    /// Frames declared unrecoverably lost this window.
    pub unrecovered: u32,
    /// The newest `host_send_ts_millis` observed on a video fragment (0 = none).
    pub latest_host_send_ts: u32,
    /// Client-local elapsed ms since it observed `latest_host_send_ts`.
    pub client_hold_ms: u32,
    /// Inter-arrival jitter (microseconds), RFC3550 2nd-difference form.
    pub owd_jitter_micros: u32,
    /// Delay-gradient `modifiedTrend` ×1000, clamped, as an `i32` bit-pattern (0 = inert).
    pub owd_trend_milli: u32,
    /// Detector flags: bits 0-1 = state, bits 8-15 = `min(num_deltas, 255)`.
    pub owd_trend_flags: u32,
    /// Windowed count of presents that ended a dense-flow late gap.
    pub pacer_late_frames: u32,
    /// Windowed count of late-gap episodes opened (superset of `pacer_late_frames`).
    pub pacer_present_gaps: u32,
    /// Gauge: the client pacer's live presentation depth (0 = no pacer attached).
    pub pacer_depth: u32,
}

impl NetworkStatsReport {
    /// Detector state from bits 0-1 of `owd_trend_flags` (0 normal / 1 over / 2 under).
    #[must_use]
    pub const fn owd_trend_state_raw(&self) -> u8 {
        (self.owd_trend_flags as u8) & 0x3
    }

    /// Detector sample count from bits 8-15 of `owd_trend_flags` (saturated at 255).
    #[must_use]
    pub const fn owd_trend_deltas(&self) -> u32 {
        (self.owd_trend_flags >> 8) & 0xFF
    }

    /// `owd_trend_milli` reinterpreted as the signed milli-trend it carries.
    #[must_use]
    pub const fn owd_trend_modified_milli_signed(&self) -> i32 {
        self.owd_trend_milli as i32
    }
}

/// A client→host recovery / acknowledgement / telemetry message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryMessage {
    /// Acknowledge a `stream_seq` (WF-8 reuse: carries an LTR `frame_id` in this field).
    Ack {
        /// The acknowledged value (historically a `stream_seq`).
        stream_seq: u32,
    },
    /// Request-for-invalidate: frames `[from, to]` were lost; refresh from an earlier LTR.
    RequestLtrRefresh {
        /// First lost frame id (inclusive).
        from_frame_id: u32,
        /// Last lost frame id (inclusive).
        to_frame_id: u32,
        /// The client's highest successfully-decoded frame id (or the sentinel).
        last_decoded_frame_id: u32,
    },
    /// Escalation: demand a forced IDR keyframe.
    RequestIdr {
        /// The client's highest successfully-decoded frame id (or the sentinel).
        last_decoded_frame_id: u32,
    },
    /// Re-request a missing cursor shape bitmap.
    RequestCursorShape {
        /// The shape id the client is missing.
        shape_id: u16,
    },
    /// Periodic network-feedback telemetry.
    NetworkStats(NetworkStatsReport),
}

impl RecoveryMessage {
    /// Wire sentinel for "the client has not decoded any frame yet".
    pub const NO_FRAME_DECODED_SENTINEL: u32 = 0xFFFF_FFFF;

    /// The on-wire message-type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match self {
            Self::Ack { .. } => 1,
            Self::RequestLtrRefresh { .. } => 2,
            Self::RequestIdr { .. } => 3,
            Self::RequestCursorShape { .. } => 4,
            Self::NetworkStats(_) => 5,
        }
    }

    /// Serialises the message (`[u8 type][body]`).
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.put_u8(self.message_type());
        match self {
            Self::Ack { stream_seq } => w.put_u32(*stream_seq),
            Self::RequestLtrRefresh {
                from_frame_id,
                to_frame_id,
                last_decoded_frame_id,
            } => {
                w.put_u32(*from_frame_id);
                w.put_u32(*to_frame_id);
                w.put_u32(*last_decoded_frame_id);
            }
            Self::RequestIdr {
                last_decoded_frame_id,
            } => w.put_u32(*last_decoded_frame_id),
            Self::RequestCursorShape { shape_id } => w.put_u16(*shape_id),
            Self::NetworkStats(r) => {
                w.put_u32(r.frames_received);
                w.put_u32(r.fec_recovered);
                w.put_u32(r.unrecovered);
                w.put_u32(r.latest_host_send_ts);
                w.put_u32(r.client_hold_ms);
                w.put_u32(r.owd_jitter_micros);
                w.put_u32(r.owd_trend_milli);
                w.put_u32(r.owd_trend_flags);
                w.put_u32(r.pacer_late_frames);
                w.put_u32(r.pacer_present_gaps);
                w.put_u32(r.pacer_depth);
            }
        }
        w.into_vec()
    }

    /// Parses a recovery message. An unknown type, a short body, OR trailing bytes are
    /// malformed — the trailing-bytes rejection is load-bearing for the host's
    /// byte-keyed request dedup.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = ByteReader::new(data);
        let kind = r.read_u8()?;
        let message = match kind {
            1 => Self::Ack {
                stream_seq: r.read_u32()?,
            },
            2 => Self::RequestLtrRefresh {
                from_frame_id: r.read_u32()?,
                to_frame_id: r.read_u32()?,
                last_decoded_frame_id: r.read_u32()?,
            },
            3 => Self::RequestIdr {
                last_decoded_frame_id: r.read_u32()?,
            },
            4 => Self::RequestCursorShape {
                shape_id: r.read_u16()?,
            },
            5 => Self::NetworkStats(NetworkStatsReport {
                frames_received: r.read_u32()?,
                fec_recovered: r.read_u32()?,
                unrecovered: r.read_u32()?,
                latest_host_send_ts: r.read_u32()?,
                client_hold_ms: r.read_u32()?,
                owd_jitter_micros: r.read_u32()?,
                owd_trend_milli: r.read_u32()?,
                owd_trend_flags: r.read_u32()?,
                pacer_late_frames: r.read_u32()?,
                pacer_present_gaps: r.read_u32()?,
                pacer_depth: r.read_u32()?,
            }),
            other => {
                return Err(VideoProtocolError::malformed(format!(
                    "unknown recovery message type {other}"
                )))
            }
        };
        if r.bytes_remaining() == 0 {
            Ok(message)
        } else {
            Err(VideoProtocolError::malformed("trailing bytes"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(m: &RecoveryMessage) {
        assert_eq!(&RecoveryMessage::decode(&m.encode()).unwrap(), m);
    }

    #[test]
    fn round_trips_all_variants() {
        round_trip(&RecoveryMessage::Ack { stream_seq: 123 });
        round_trip(&RecoveryMessage::RequestLtrRefresh {
            from_frame_id: 10,
            to_frame_id: 12,
            last_decoded_frame_id: RecoveryMessage::NO_FRAME_DECODED_SENTINEL,
        });
        round_trip(&RecoveryMessage::RequestIdr {
            last_decoded_frame_id: 9,
        });
        round_trip(&RecoveryMessage::RequestCursorShape { shape_id: 0xABCD });
        round_trip(&RecoveryMessage::NetworkStats(NetworkStatsReport {
            frames_received: 100,
            fec_recovered: 5,
            unrecovered: 2,
            latest_host_send_ts: 999,
            client_hold_ms: 3,
            owd_jitter_micros: 1500,
            owd_trend_milli: (-1234_i32) as u32,
            owd_trend_flags: (255u32 << 8) | 0x1,
            pacer_late_frames: 4,
            pacer_present_gaps: 6,
            pacer_depth: 2,
        }));
    }

    #[test]
    fn rejects_trailing_bytes() {
        let mut bytes = RecoveryMessage::Ack { stream_seq: 1 }.encode();
        bytes.push(0); // one trailing byte
        assert!(matches!(
            RecoveryMessage::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn rejects_short_and_unknown() {
        assert!(matches!(
            RecoveryMessage::decode(&[2, 0, 0]),
            Err(VideoProtocolError::Truncated)
        ));
        assert!(matches!(
            RecoveryMessage::decode(&[99]),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn network_stats_flag_accessors() {
        let r = NetworkStatsReport {
            owd_trend_flags: (200u32 << 8) | 0x2,
            owd_trend_milli: (-5000_i32) as u32,
            ..NetworkStatsReport::default()
        };
        assert_eq!(r.owd_trend_state_raw(), 2);
        assert_eq!(r.owd_trend_deltas(), 200);
        assert_eq!(r.owd_trend_modified_milli_signed(), -5000);
    }
}
