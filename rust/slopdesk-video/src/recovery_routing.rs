//! The host's side of the dedicated recovery channel, the static re-encode timer, and the send
//! scheduler that puts every finished message on the right channel.
//!
//! Recovery rides its OWN channel rather than sharing the input one, and that is not tidiness: a
//! recovery message's leading type bytes ALIAS the input grammar's, so a shared channel would
//! mis-decode a recovery datagram as a phantom mouse event. The two are routed by separate
//! functions here for the same reason.

use crate::cursor::CursorChannelMessage;
use crate::fragment::FrameFragment;
use crate::recovery::{NO_FRAME_DECODED_SENTINEL, NetworkStatsReport, RecoveryMessage};
use crate::video_control::VideoControlMessage;
use crate::window_geometry::WindowGeometryMessage;

/// The decision for one received recovery datagram.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryDecision {
    /// Force a real keyframe on the next captured frame.
    ///
    /// This is the GUARANTEED-recovery escalation: a keyframe unconditionally re-anchors a desynced
    /// client. It is kept distinct from [`RecoveryDecision::RefreshLtr`] so the escalation can
    /// never degrade to a cheap re-anchor. It carries the client's decode frontier — `None`
    /// when the wire sentinel said nothing has decoded yet — for the actor's delivery-keyed
    /// admission policy.
    ForceKeyframe {
        /// The client's decode frontier.
        last_decoded_frame_id: Option<u32>,
    },
    /// The client asked for a long-term-reference refresh.
    ///
    /// The ACTOR decides at runtime whether to issue the cheap re-anchor — only when the feature is
    /// on AND a token has been acknowledged, the acked-only invariant — or to fall back to a real
    /// keyframe. With the feature off this folds to a keyframe. The frontier is carried like the
    /// escalation's and consumed ONLY on that fallback path, because a refresh is never
    /// policy-gated.
    RefreshLtr {
        /// The client's decode frontier.
        last_decoded_frame_id: Option<u32>,
    },
    /// A durable-receipt acknowledgement: the host may advance its retransmit and reference window.
    Ack {
        /// The acknowledged sequence, or the acknowledged reference frame.
        stream_seq: u32,
    },
    /// Re-ship the cursor SHAPE bitmap — a self-heal for a client whose one-shot shape datagram was
    /// lost or over-sized. The re-insert is idempotent.
    ReshipCursorShape {
        /// The shape the client's cache is missing.
        shape_id: u16,
    },
    /// A periodic client network report, which the actor folds into its estimate. Nothing about the
    /// stream changes off the back of it directly.
    NetworkStats(NetworkStatsReport),
    /// Selective retransmit: the client is missing specific DATA fragments and asks for them back.
    ///
    /// The actor looks each up in its send-history ring and re-enqueues the originals — cheaper
    /// than a recovery keyframe, and it lands inside the client's playout buffer. A ring miss
    /// is a no-op; the client's own escalation is still the fallback once its grace expires.
    RetransmitFragments {
        /// The frame missing fragments.
        frame_id: u32,
        /// The missing DATA indices.
        frag_indices: Vec<u16>,
    },
    /// Drop a malformed datagram. A corrupt single packet must never crash the receiver.
    Drop,
    /// Ignore the datagram, because the session is not streaming.
    IgnoreNotStreaming,
}

/// Maps a wire decode frontier to a clean optional, so the sentinel never leaks into the policy.
const fn frontier(raw: u32) -> Option<u32> {
    if raw == NO_FRAME_DECODED_SENTINEL {
        None
    } else {
        Some(raw)
    }
}

/// Decides what to do with one raw recovery datagram.
///
/// A non-streaming session ignores it BEFORE any decode; an undecodable one drops.
#[must_use]
pub fn route_recovery(datagram: &[u8], media_flowing: bool) -> RecoveryDecision {
    if !media_flowing {
        return RecoveryDecision::IgnoreNotStreaming;
    }
    let Ok(message) = RecoveryMessage::decode(datagram) else {
        return RecoveryDecision::Drop;
    };
    match message {
        RecoveryMessage::RequestIdr {
            last_decoded_frame_id,
        } => {
            RecoveryDecision::ForceKeyframe {
                last_decoded_frame_id: frontier(last_decoded_frame_id),
            }
        },
        RecoveryMessage::RequestLtrRefresh {
            last_decoded_frame_id,
            ..
        } => {
            RecoveryDecision::RefreshLtr {
                last_decoded_frame_id: frontier(last_decoded_frame_id),
            }
        },
        RecoveryMessage::Ack { stream_seq } => RecoveryDecision::Ack { stream_seq },
        RecoveryMessage::RequestCursorShape { shape_id } => RecoveryDecision::ReshipCursorShape { shape_id },
        RecoveryMessage::NetworkStats(report) => RecoveryDecision::NetworkStats(report),
        RecoveryMessage::RequestFragments {
            frame_id,
            frag_indices,
        } => {
            RecoveryDecision::RetransmitFragments {
                frame_id,
                frag_indices,
            }
        },
    }
}

/// The timer that re-encodes the cached frame while the screen is STILL.
///
/// A live screen drives its own re-anchors through the normal path, so this fires only once that
/// path has gone quiet — which is exactly when a frozen client has nothing else coming.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StaticIdrDecider {
    /// The heartbeat cadence in seconds.
    heartbeat: f64,
    /// The quiet window in seconds: suppress a synthetic re-encode when a REAL frame was encoded
    /// within it, so the timer never double-emits over a live screen.
    quiet_window: f64,
    /// When the last REAL frame was encoded. Zero means none yet.
    last_complete_encode: f64,
    /// When the last SYNTHETIC re-encode went out. Zero means none yet.
    last_synthetic_encode: f64,
}

impl StaticIdrDecider {
    /// A decider whose quiet window defaults to one heartbeat.
    #[must_use]
    pub const fn new(heartbeat: f64, quiet_window: Option<f64>) -> Self {
        Self {
            heartbeat,
            quiet_window: match quiet_window {
                Some(window) => window,
                None => heartbeat,
            },
            last_complete_encode: 0.0,
            last_synthetic_encode: 0.0,
        }
    }

    /// The capture path encoded a REAL frame, which re-anchors the live clock so the timer stays
    /// quiet while the screen is live.
    pub const fn on_complete_frame(&mut self, now: f64) {
        self.last_complete_encode = now;
    }

    /// The timer fired a synthetic re-encode, which re-anchors the synthetic clock.
    pub const fn record_synthetic(&mut self, now: f64) {
        self.last_synthetic_encode = now;
    }

    /// Whether the caller should re-encode the cached buffer as a forced keyframe.
    ///
    /// `forced_latched` means a client recovery request is pending, and `has_retained_buffer` means
    /// there are cached pixels to re-encode at all.
    ///
    /// The heartbeat is measured from the last SYNTHETIC emission ONLY. Anchoring it on the later
    /// of the two clocks would make the first crisp re-anchor after a scroll wait a full
    /// heartbeat even though the quiet window had long since passed; synthetic-only fires that
    /// first crisp as soon as the quiet window clears, while the steady-state static cadence
    /// still stays one heartbeat apart.
    #[must_use]
    pub fn should_reencode(&self, now: f64, forced_latched: bool, has_retained_buffer: bool) -> bool {
        if !has_retained_buffer {
            return false; // nothing to re-encode, as before the first ever real frame
        }
        // A real frame inside the quiet window means the live path is driving the stream, so let it
        // own the cadence. A recovery request while live is already serviced faster by the live
        // path's own latch drain — this timer is the fallback for when that path has gone quiet, so
        // the quiet window gates the forced case too.
        if self.last_complete_encode != 0.0 && now - self.last_complete_encode < self.quiet_window {
            return false;
        }
        // Once the live path IS quiet a recovery request always wins, whatever the heartbeat phase:
        // a client is frozen, and that is latency-critical.
        if forced_latched {
            return true;
        }
        if self.last_synthetic_encode == 0.0 {
            return true; // armed, quiet, and nothing emitted yet
        }
        now - self.last_synthetic_encode >= self.heartbeat
    }
}

/// A video path channel. The discriminants are the wire mux tags.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum VideoChannel {
    /// Session bring-up control.
    Control,
    /// Encoded video fragments.
    Video,
    /// Window move, resize and title.
    Geometry,
    /// Cursor position and shape, on its own socket.
    Cursor,
    /// Client to host input — received, not sent, by the host.
    Input,
    /// Client to host loss recovery — received, not sent, by the host, and DEDICATED rather than
    /// multiplexed onto the input channel, because the two grammars' leading type bytes alias.
    Recovery,
    /// Host to client app audio. It rides the shared media socket but is always sent IMMEDIATELY,
    /// never through the paced lane, so audio never queues behind a fat video frame. No forward
    /// error correction and no retransmit: a lost frame is concealed at the client.
    Audio,
}

impl VideoChannel {
    /// The wire mux tag.
    #[must_use]
    pub const fn raw_value(self) -> u8 {
        match self {
            Self::Control => 0,
            Self::Video => 1,
            Self::Geometry => 2,
            Self::Cursor => 3,
            Self::Input => 4,
            Self::Recovery => 5,
            Self::Audio => 6,
        }
    }

    /// The channel a wire mux tag names, or `None` for an unknown one.
    #[must_use]
    pub const fn from_raw_value(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Control),
            1 => Some(Self::Video),
            2 => Some(Self::Geometry),
            3 => Some(Self::Cursor),
            4 => Some(Self::Input),
            5 => Some(Self::Recovery),
            6 => Some(Self::Audio),
            _ => None,
        }
    }
}

/// One scheduled datagram: the channel it belongs on, and its encoded bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    /// The channel.
    pub channel: VideoChannel,
    /// The wire bytes.
    pub bytes: Vec<u8>,
}

/// Schedules one encoded frame's fragments as ordered video datagrams.
///
/// Data fragments precede parity — the packetizer already emits them in that order — so a client on
/// a lossless link decodes without waiting for parity at all.
#[must_use]
pub fn schedule_frame(fragments: &[FrameFragment]) -> Vec<Outgoing> {
    fragments
        .iter()
        .map(|fragment| {
            Outgoing {
                channel: VideoChannel::Video,
                bytes: fragment.encode(),
            }
        })
        .collect()
}

/// The send path's fast lane: wraps already-finished wire datagrams WITHOUT the parse-and-re-encode
/// round trip. Same channel and same byte order as [`schedule_frame`].
#[must_use]
pub fn schedule_frame_raw(datagrams: Vec<Vec<u8>>) -> Vec<Outgoing> {
    datagrams
        .into_iter()
        .map(|bytes| {
            Outgoing {
                channel: VideoChannel::Video,
                bytes,
            }
        })
        .collect()
}

/// Schedules a geometry update on the geometry channel.
#[must_use]
pub fn schedule_geometry(message: &WindowGeometryMessage) -> Outgoing {
    Outgoing {
        channel: VideoChannel::Geometry,
        bytes: message.encode(),
    }
}

/// Schedules a cursor message on the dedicated cursor socket.
#[must_use]
pub fn schedule_cursor(message: &CursorChannelMessage) -> Outgoing {
    Outgoing {
        channel: VideoChannel::Cursor,
        bytes: message.encode(),
    }
}

/// Schedules a control message.
#[must_use]
pub fn schedule_control(message: &VideoControlMessage) -> Outgoing {
    Outgoing {
        channel: VideoChannel::Control,
        bytes: message.encode(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Outgoing, RecoveryDecision, StaticIdrDecider, VideoChannel, route_recovery, schedule_control,
        schedule_frame, schedule_frame_raw,
    };
    use crate::fragment::{Flags, FrameFragment, FrameFragmentHeader};
    use crate::recovery::{NO_FRAME_DECODED_SENTINEL, RecoveryMessage};
    use crate::session_state::PROTOCOL_VERSION;
    use crate::video_control::VideoControlMessage;

    #[test]
    fn a_datagram_is_ignored_before_it_is_even_decoded_when_nothing_is_streaming() {
        assert_eq!(
            route_recovery(&[0xFF], false),
            RecoveryDecision::IgnoreNotStreaming
        );
    }

    #[test]
    fn a_corrupt_datagram_drops_rather_than_crashing_the_receiver() {
        assert_eq!(route_recovery(&[0xFF], true), RecoveryDecision::Drop);
        assert_eq!(route_recovery(&[], true), RecoveryDecision::Drop);
    }

    /// The escalation exists precisely because a cheap re-anchor was not enough.
    #[test]
    fn the_escalation_is_always_a_real_keyframe_and_never_degrades() {
        let request = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: 900,
        };
        assert_eq!(
            route_recovery(&request.encode(), true),
            RecoveryDecision::ForceKeyframe {
                last_decoded_frame_id: Some(900),
            },
        );
    }

    #[test]
    fn the_wire_sentinel_becomes_a_clean_absent_frontier() {
        for message in [
            RecoveryMessage::RequestIdr {
                last_decoded_frame_id: NO_FRAME_DECODED_SENTINEL,
            },
            RecoveryMessage::RequestLtrRefresh {
                from_frame_id: 1,
                to_frame_id: 4,
                last_decoded_frame_id: NO_FRAME_DECODED_SENTINEL,
            },
        ] {
            let decision = route_recovery(&message.encode(), true);
            assert!(
                matches!(
                    decision,
                    RecoveryDecision::ForceKeyframe {
                        last_decoded_frame_id: None,
                    } | RecoveryDecision::RefreshLtr {
                        last_decoded_frame_id: None,
                    },
                ),
                "the sentinel must not leak into the policy: {decision:?}",
            );
        }
    }

    #[test]
    fn every_other_recovery_message_maps_to_its_own_action() {
        assert_eq!(
            route_recovery(&RecoveryMessage::Ack { stream_seq: 77 }.encode(), true),
            RecoveryDecision::Ack { stream_seq: 77 },
        );
        assert_eq!(
            route_recovery(
                &RecoveryMessage::RequestCursorShape { shape_id: 12 }.encode(),
                true
            ),
            RecoveryDecision::ReshipCursorShape { shape_id: 12 },
        );
        assert_eq!(
            route_recovery(
                &RecoveryMessage::RequestFragments {
                    frame_id: 500,
                    frag_indices: vec![1, 3, 4],
                }
                .encode(),
                true,
            ),
            RecoveryDecision::RetransmitFragments {
                frame_id: 500,
                frag_indices: vec![1, 3, 4],
            },
        );
    }

    #[test]
    fn nothing_is_re_encoded_before_there_are_any_cached_pixels() {
        let decider = StaticIdrDecider::new(1.0, None);
        assert!(!decider.should_reencode(100.0, true, false));
    }

    #[test]
    fn a_live_screen_owns_the_cadence_and_the_timer_stays_quiet() {
        let mut decider = StaticIdrDecider::new(1.0, None);
        decider.on_complete_frame(100.0);
        assert!(!decider.should_reencode(100.5, false, true));
        assert!(
            !decider.should_reencode(100.5, true, true),
            "even a recovery request defers while the live path is driving",
        );
    }

    /// The measured behaviour: the first crisp re-anchor lands as soon as motion stops.
    #[test]
    fn the_first_crisp_fires_the_moment_the_quiet_window_clears() {
        let mut decider = StaticIdrDecider::new(1.0, None);
        decider.on_complete_frame(100.0);
        assert!(!decider.should_reencode(100.9, false, true));
        assert!(
            decider.should_reencode(101.0, false, true),
            "not a full heartbeat later — the moment the screen went still",
        );
    }

    #[test]
    fn the_steady_static_cadence_is_one_heartbeat_apart() {
        let mut decider = StaticIdrDecider::new(1.0, None);
        decider.on_complete_frame(100.0);
        decider.record_synthetic(101.0);
        assert!(!decider.should_reencode(101.5, false, true));
        assert!(decider.should_reencode(102.0, false, true));
    }

    #[test]
    fn a_frozen_client_wins_over_the_heartbeat_phase_once_the_screen_is_still() {
        let mut decider = StaticIdrDecider::new(1.0, None);
        decider.on_complete_frame(100.0);
        decider.record_synthetic(101.0);
        assert!(!decider.should_reencode(101.1, false, true));
        assert!(
            decider.should_reencode(101.1, true, true),
            "a frozen client is latency-critical",
        );
    }

    #[test]
    fn the_channel_tags_round_trip_and_reject_an_unknown_one() {
        for channel in [
            VideoChannel::Control,
            VideoChannel::Video,
            VideoChannel::Geometry,
            VideoChannel::Cursor,
            VideoChannel::Input,
            VideoChannel::Recovery,
            VideoChannel::Audio,
        ] {
            assert_eq!(VideoChannel::from_raw_value(channel.raw_value()), Some(channel));
        }
        assert_eq!(VideoChannel::from_raw_value(7), None);
    }

    #[test]
    fn a_frame_schedules_in_order_on_the_video_channel_either_way() {
        let fragments: Vec<FrameFragment> = (0_u16..3)
            .map(|index| {
                FrameFragment::new(
                    FrameFragmentHeader::new(u32::from(index), 10, index, 3, Flags::empty(), 4, 0),
                    vec![0xAB; 4],
                )
            })
            .collect();
        let scheduled = schedule_frame(&fragments);
        assert!(scheduled.iter().all(|out| out.channel == VideoChannel::Video));
        let raw: Vec<Vec<u8>> = fragments.iter().map(FrameFragment::encode).collect();
        assert_eq!(
            schedule_frame_raw(raw),
            scheduled,
            "the fast lane is byte-identical to the parsing one",
        );
    }

    #[test]
    fn a_control_message_schedules_on_the_control_channel() {
        let message = VideoControlMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            requested_window_id: 1,
            viewport: crate::geometry::VideoSize {
                width: 100.0,
                height: 100.0,
            },
        };
        assert_eq!(schedule_control(&message), Outgoing {
            channel: VideoChannel::Control,
            bytes: message.encode(),
        },);
    }
}
