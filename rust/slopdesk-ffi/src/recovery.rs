//! The recovery channel: what the client says when it loses a frame, and when it stops asking
//! nicely.
//!
//! [`slopdesk_video::recovery`] holds the message codec, the escalation clock, the request
//! redundancy and the loss-observing window. This module is the boundary to it.
//!
//! ## Why the message crosses FLAT and not as a tagged union
//! Six arms, one of them variable-length. A C union would have to be kept in step with the Rust
//! enum by hand on both sides, which is the drift this port exists to remove. So the message
//! crosses as one flat `#[repr(C)]` struct with a type byte and every arm's fields beside each
//! other: reading a field an arm does not carry is a caller error the type byte already names.
//! It is seventy-odd bytes copied on a channel that carries a datagram every fiftieth of a second.
//!
//! ## Why the NACK indices need no second call
//! The codec caps them at [`slopdesk_video::recovery::MAX_NACK_FRAGMENTS`] — a longer loss
//! escalates to a refresh instead — so a caller with that many slots can never be told to ask
//! again. The indices land in the caller's buffer during the one decode, and `frag_count` says how
//! many are real. A NULL buffer still parses and still counts.
//!
//! ## Why the ROUTING answer is its own shape and not the flat message
//! The host does not want a message, it wants a verdict, and the two differ in exactly one field
//! that matters: the wire carries a decode frontier with a no-frame-decoded SENTINEL in it, and the
//! policy wants an `Option`. Answering with [`SlopDeskRecoveryMessage`] would hand the raw sentinel
//! over and leave the near side writing `raw == sentinel ? nil : raw` — which is half the routing
//! rule, respelled in the caller's language. `docs/55` §4 is explicit that an `Option` crosses as a
//! value plus a flag, never as a sentinel, so [`SlopDeskRecoveryDecision`] carries `frontier`
//! beside `has_frontier` and the sentinel never leaves this side.
//!
//! ## Why the loss window crosses as a plain array
//! Its state is a ring of timestamps, and a ring of timestamps is DATA. So the caller keeps the
//! array and this side keeps the law: `note` answers the ring that pruning and the capacity drop
//! leave behind, `observing` reads one without touching it. Nothing is owned across the boundary
//! and no shape has to be mirrored in a header — just `(ptr, len)` in and `(out, cap)` out, which
//! is [`crate`]'s own convention.

use core::ffi::c_uchar;

use slopdesk_video::VideoProtocolError;
use slopdesk_video::recovery::{
    self, LtrEscalationTracker, NetworkStatsReport, RecoveryMessage, RecoveryPolicy,
    RecoveryRequestRedundancy, is_observing_loss, note_in_place,
};
use slopdesk_video::recovery_routing::{RecoveryDecision, StaticIdrDecider, route_recovery};

use crate::{borrow, deliver};

/// The datagram parsed.
pub const DECODE_OK: u32 = 0;
/// Too few bytes for a field the type byte promised.
pub const DECODE_TRUNCATED: u32 = 1;
/// Enough bytes, but a value no arm accepts: an unknown type, a NACK over the cap, trailing bytes.
pub const DECODE_MALFORMED: u32 = 2;

/// One recovery message, flat: the type byte plus every arm's fields side by side.
///
/// Only the fields the type byte names carry meaning. The rest are zero on decode and ignored on
/// encode, which is why there is no union here to keep in step.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskRecoveryMessage {
    /// Type 1: the acked sequence, or the acked LTR frame id.
    pub stream_seq: u32,
    /// Type 2: first lost frame, inclusive.
    pub from_frame_id: u32,
    /// Type 2: last lost frame, inclusive.
    pub to_frame_id: u32,
    /// Types 2 and 3: the client's decode frontier, or the no-frame-decoded sentinel.
    pub last_decoded_frame_id: u32,
    /// Type 6: the frame missing fragments.
    pub frame_id: u32,
    /// Type 5: complete frames received in the window.
    pub frames_received: u32,
    /// Type 5: of those, how many completed through FEC.
    pub fec_recovered: u32,
    /// Type 5: frames declared unrecoverably lost.
    pub unrecovered: u32,
    /// Type 5: the newest host send stamp the client observed.
    pub latest_host_send_ts: u32,
    /// Type 5: client-local ms since it observed that stamp.
    pub client_hold_ms: u32,
    /// Type 5: inter-arrival jitter in microseconds.
    pub owd_jitter_micros: u32,
    /// Type 5: the delay-gradient trend, ×1000, as an `i32` bit pattern.
    pub owd_trend_milli: u32,
    /// Type 5: the delay-gradient detector's state and sample count.
    pub owd_trend_flags: u32,
    /// Type 5: presents that ended a dense-flow late gap.
    pub pacer_late_frames: u32,
    /// Type 5: late-gap episodes opened.
    pub pacer_present_gaps: u32,
    /// Type 5: the client pacer's live presentation depth.
    pub pacer_depth: u32,
    /// Type 6: how many fragment indices the message carries.
    pub frag_count: u16,
    /// Type 4: the shape the client's cache is missing.
    pub shape_id: u16,
    /// The on-wire type byte, and the only field that is always meaningful.
    pub message_type: u8,
}

impl SlopDeskRecoveryMessage {
    fn from_message(message: &RecoveryMessage) -> Self {
        let mut flat = Self {
            message_type: message.message_type(),
            ..Self::default()
        };
        match message {
            RecoveryMessage::Ack { stream_seq } => flat.stream_seq = *stream_seq,
            RecoveryMessage::RequestLtrRefresh {
                from_frame_id,
                to_frame_id,
                last_decoded_frame_id,
            } => {
                flat.from_frame_id = *from_frame_id;
                flat.to_frame_id = *to_frame_id;
                flat.last_decoded_frame_id = *last_decoded_frame_id;
            },
            RecoveryMessage::RequestIdr {
                last_decoded_frame_id,
            } => flat.last_decoded_frame_id = *last_decoded_frame_id,
            RecoveryMessage::RequestCursorShape { shape_id } => flat.shape_id = *shape_id,
            RecoveryMessage::NetworkStats(report) => {
                flat.frames_received = report.frames_received;
                flat.fec_recovered = report.fec_recovered;
                flat.unrecovered = report.unrecovered;
                flat.latest_host_send_ts = report.latest_host_send_ts;
                flat.client_hold_ms = report.client_hold_ms;
                flat.owd_jitter_micros = report.owd_jitter_micros;
                flat.owd_trend_milli = report.owd_trend_milli;
                flat.owd_trend_flags = report.owd_trend_flags;
                flat.pacer_late_frames = report.pacer_late_frames;
                flat.pacer_present_gaps = report.pacer_present_gaps;
                flat.pacer_depth = report.pacer_depth;
            },
            RecoveryMessage::RequestFragments {
                frame_id,
                frag_indices,
            } => {
                flat.frame_id = *frame_id;
                flat.frag_count = u16::try_from(frag_indices.len()).unwrap_or(u16::MAX);
            },
        }
        flat
    }

    fn to_message(self, frags: &[u16]) -> Option<RecoveryMessage> {
        Some(match self.message_type {
            1 => {
                RecoveryMessage::Ack {
                    stream_seq: self.stream_seq,
                }
            },
            2 => {
                RecoveryMessage::RequestLtrRefresh {
                    from_frame_id: self.from_frame_id,
                    to_frame_id: self.to_frame_id,
                    last_decoded_frame_id: self.last_decoded_frame_id,
                }
            },
            3 => {
                RecoveryMessage::RequestIdr {
                    last_decoded_frame_id: self.last_decoded_frame_id,
                }
            },
            4 => {
                RecoveryMessage::RequestCursorShape {
                    shape_id: self.shape_id,
                }
            },
            5 => {
                RecoveryMessage::NetworkStats(NetworkStatsReport {
                    frames_received: self.frames_received,
                    fec_recovered: self.fec_recovered,
                    unrecovered: self.unrecovered,
                    latest_host_send_ts: self.latest_host_send_ts,
                    client_hold_ms: self.client_hold_ms,
                    owd_jitter_micros: self.owd_jitter_micros,
                    owd_trend_milli: self.owd_trend_milli,
                    owd_trend_flags: self.owd_trend_flags,
                    pacer_late_frames: self.pacer_late_frames,
                    pacer_present_gaps: self.pacer_present_gaps,
                    pacer_depth: self.pacer_depth,
                })
            },
            6 => {
                RecoveryMessage::RequestFragments {
                    frame_id: self.frame_id,
                    frag_indices: frags.to_vec(),
                }
            },
            _ => return None,
        })
    }
}

/// Serialises one recovery message. Returns bytes NEEDED under §4's convention; 0 for a type byte
/// no arm answers to, which is a caller error rather than a message.
///
/// `frags` is read only for the NACK arm, and only `message.frag_count` of it.
///
/// # Safety
/// `message` must be null or point to one readable, aligned [`SlopDeskRecoveryMessage`]; `frags`
/// must be null or point to `message.frag_count` readable `u16`s; `out` must be null or point to
/// `cap` writable bytes. All for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_encode(
    message: *const SlopDeskRecoveryMessage,
    frags: *const u16,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if message.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, one readable, aligned message.
    let flat = unsafe { message.read() };
    let count = usize::from(flat.frag_count);
    let indices: &[u16] = if frags.is_null() || count == 0 {
        &[]
    } else {
        // SAFETY: the caller's obligation — `count` readable `u16`s, live for the call.
        unsafe { core::slice::from_raw_parts(frags, count) }
    };
    let Some(built) = flat.to_message(indices) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&built.encode(), out, cap) }
}

/// Parses one recovery message, answering [`DECODE_OK`], [`DECODE_TRUNCATED`] or
/// [`DECODE_MALFORMED`] and writing nothing when it refuses.
///
/// The two refusals are told apart because the caller's own vocabulary tells them apart, and a
/// short body and a hostile one are different things to see in a log. The malformed REASON does not
/// cross: it is diagnostic, no caller branches on it, and a string is a poor thing to copy across a
/// boundary for a datagram that is already being dropped.
///
/// The trailing-bytes rejection is load-bearing rather than fastidious: the host's request deduper
/// keys on the RAW datagram bytes, so a decoder that tolerated suffixes would let suffix-varied
/// copies of one logical request each decode identically and yet each bypass the dedup, firing a
/// second refresh or IDR.
///
/// Fragment indices land in `frags`, which must hold
/// [`slopdesk_video::recovery::MAX_NACK_FRAGMENTS`] of them — the codec's own cap, so a buffer that
/// size can never be too small. A NULL `frags` still parses and still counts.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes; `out` must be null or point to one
/// writable, aligned [`SlopDeskRecoveryMessage`]; `frags` must be null or point to `frags_cap`
/// writable `u16`s. All for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskRecoveryMessage,
    frags: *mut u16,
    frags_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let message = match RecoveryMessage::decode(datagram) {
        Ok(message) => message,
        Err(VideoProtocolError::Truncated) => return DECODE_TRUNCATED,
        Err(VideoProtocolError::Malformed(_)) => return DECODE_MALFORMED,
    };
    let flat = SlopDeskRecoveryMessage::from_message(&message);
    if let RecoveryMessage::RequestFragments { frag_indices, .. } = &message
        && !frags.is_null()
    {
        if frag_indices.len() > frags_cap {
            return DECODE_MALFORMED;
        }
        for (slot, index) in frag_indices.iter().enumerate() {
            // SAFETY: `slot` is below `frag_indices.len()`, which the check above put at or under
            // `frags_cap` — the caller's promise of writable `u16`s.
            unsafe { frags.add(slot).write(*index) };
        }
    }
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, one writable, aligned message.
        unsafe { out.write(flat) };
    }
    DECODE_OK
}

/// The session is not streaming, so the datagram was ignored BEFORE any decode.
pub const ROUTE_IGNORE_NOT_STREAMING: u32 = 0;
/// The datagram did not decode. A corrupt single packet must never crash the receiver.
pub const ROUTE_DROP: u32 = 1;
/// Force a real keyframe on the next captured frame — the guaranteed-recovery escalation.
pub const ROUTE_FORCE_KEYFRAME: u32 = 2;
/// The client asked for a long-term-reference refresh; the caller decides refresh-versus-keyframe.
pub const ROUTE_REFRESH_LTR: u32 = 3;
/// A durable-receipt acknowledgement: the retransmit and reference window may advance.
pub const ROUTE_ACK: u32 = 4;
/// Re-ship the cursor shape bitmap the client's cache is missing.
pub const ROUTE_RESHIP_CURSOR_SHAPE: u32 = 5;
/// A periodic client network report, for the caller's estimate to fold.
pub const ROUTE_NETWORK_STATS: u32 = 6;
/// Selective retransmit: re-enqueue the named fragments of one frame.
pub const ROUTE_RETRANSMIT_FRAGMENTS: u32 = 7;

/// One routing verdict, flat: every field any arm could want, under a code that names which.
///
/// Only the fields the returned code names carry meaning; the rest are zero. That is
/// [`SlopDeskRecoveryMessage`]'s bargain one step further along — a verdict flattens, because a C
/// enum with a payload is not a thing (`docs/55` §4b).
///
/// The one field that is NOT the message's is the frontier. It arrives on the wire with a
/// no-frame-decoded sentinel in it and leaves here as a value plus a flag, so the near side never
/// has to know what the sentinel is.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskRecoveryDecision {
    /// Force-keyframe and refresh-LTR: the client's decode frontier, meaningful only while
    /// `has_frontier`.
    pub frontier: u32,
    /// Ack: the acknowledged sequence, or the acknowledged LTR frame id.
    pub stream_seq: u32,
    /// Re-ship: the shape the client's cache is missing. Widened from the wire's `u16` so the
    /// record is sixteen words with no interior padding for a hand-written header to transcribe.
    pub shape_id: u32,
    /// Retransmit: the frame missing fragments.
    pub frame_id: u32,
    /// Retransmit: how many fragment indices the request names, whether or not they fit `frags`.
    pub frag_count: u32,
    /// Network stats: complete frames received in the window.
    pub frames_received: u32,
    /// Network stats: of those, how many completed through FEC.
    pub fec_recovered: u32,
    /// Network stats: frames declared unrecoverably lost.
    pub unrecovered: u32,
    /// Network stats: the newest host send stamp the client observed.
    pub latest_host_send_ts: u32,
    /// Network stats: client-local ms since it observed that stamp.
    pub client_hold_ms: u32,
    /// Network stats: inter-arrival jitter in microseconds.
    pub owd_jitter_micros: u32,
    /// Network stats: the delay-gradient trend, ×1000, as an `i32` bit pattern.
    pub owd_trend_milli: u32,
    /// Network stats: the delay-gradient detector's state and sample count.
    pub owd_trend_flags: u32,
    /// Network stats: presents that ended a dense-flow late gap.
    pub pacer_late_frames: u32,
    /// Network stats: late-gap episodes opened.
    pub pacer_present_gaps: u32,
    /// Network stats: the client pacer's live presentation depth.
    pub pacer_depth: u32,
    /// Whether the client has decoded anything at all — the wire sentinel, read as the `Option` it
    /// stands for.
    pub has_frontier: bool,
}

impl SlopDeskRecoveryDecision {
    /// The frontier written as the value-plus-flag pair it crosses as.
    fn with_frontier(frontier: Option<u32>) -> Self {
        Self {
            frontier: frontier.unwrap_or(0),
            has_frontier: frontier.is_some(),
            ..Self::default()
        }
    }

    /// One network report written into the verdict, field for field.
    fn with_stats(report: &NetworkStatsReport) -> Self {
        Self {
            frames_received: report.frames_received,
            fec_recovered: report.fec_recovered,
            unrecovered: report.unrecovered,
            latest_host_send_ts: report.latest_host_send_ts,
            client_hold_ms: report.client_hold_ms,
            owd_jitter_micros: report.owd_jitter_micros,
            owd_trend_milli: report.owd_trend_milli,
            owd_trend_flags: report.owd_trend_flags,
            pacer_late_frames: report.pacer_late_frames,
            pacer_present_gaps: report.pacer_present_gaps,
            pacer_depth: report.pacer_depth,
            ..Self::default()
        }
    }
}

/// Decides what to do with one raw recovery datagram, answering one of the `ROUTE_*` codes above
/// and filling `out` with the fields that code names.
///
/// This is [`slopdesk_video::recovery_routing::route_recovery`] and nothing else: a session that is
/// not streaming ignores the datagram BEFORE any decode, an undecodable one drops, and the six
/// message arms map to their own actions. The guard order is the rule, not an implementation
/// detail — a decode attempted first would let a hostile datagram be parsed on a session that is
/// not even streaming.
///
/// The malformed REASON does not cross, for [`slopdesk_recovery_decode`]'s reason: nothing branches
/// on it, and the datagram is being dropped either way. A caller that wants the taxonomy has that
/// door.
///
/// Fragment indices land in `frags` on the retransmit arm, and `out.frag_count` says how many the
/// request names WHETHER OR NOT they fit. A `frag_count` over `frags_cap` leaves the buffer
/// untouched and still reports the count, so the caller calls again with a bigger one — §4's retry,
/// at the width of an index. It is never travelled in practice: the codec caps a NACK at
/// [`slopdesk_video::recovery::MAX_NACK_FRAGMENTS`], so a buffer that size can never be too small.
/// A NULL `frags` still routes and still counts.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes; `out` must be null or point to one
/// writable, aligned [`SlopDeskRecoveryDecision`]; `frags` must be null or point to `frags_cap`
/// writable `u16`s. All for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_route(
    bytes: *const c_uchar,
    len: usize,
    media_flowing: bool,
    out: *mut SlopDeskRecoveryDecision,
    frags: *mut u16,
    frags_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let decision = route_recovery(datagram, media_flowing);
    let (code, flat) = match &decision {
        RecoveryDecision::IgnoreNotStreaming => {
            (ROUTE_IGNORE_NOT_STREAMING, SlopDeskRecoveryDecision::default())
        },
        RecoveryDecision::Drop => (ROUTE_DROP, SlopDeskRecoveryDecision::default()),
        RecoveryDecision::ForceKeyframe {
            last_decoded_frame_id,
        } => {
            (
                ROUTE_FORCE_KEYFRAME,
                SlopDeskRecoveryDecision::with_frontier(*last_decoded_frame_id),
            )
        },
        RecoveryDecision::RefreshLtr {
            last_decoded_frame_id,
        } => {
            (
                ROUTE_REFRESH_LTR,
                SlopDeskRecoveryDecision::with_frontier(*last_decoded_frame_id),
            )
        },
        RecoveryDecision::Ack { stream_seq } => {
            (ROUTE_ACK, SlopDeskRecoveryDecision {
                stream_seq: *stream_seq,
                ..SlopDeskRecoveryDecision::default()
            })
        },
        RecoveryDecision::ReshipCursorShape { shape_id } => {
            (ROUTE_RESHIP_CURSOR_SHAPE, SlopDeskRecoveryDecision {
                shape_id: u32::from(*shape_id),
                ..SlopDeskRecoveryDecision::default()
            })
        },
        RecoveryDecision::NetworkStats(report) => {
            (ROUTE_NETWORK_STATS, SlopDeskRecoveryDecision::with_stats(report))
        },
        RecoveryDecision::RetransmitFragments {
            frame_id,
            frag_indices,
        } => {
            (ROUTE_RETRANSMIT_FRAGMENTS, SlopDeskRecoveryDecision {
                frame_id: *frame_id,
                frag_count: u32::try_from(frag_indices.len()).unwrap_or(u32::MAX),
                ..SlopDeskRecoveryDecision::default()
            })
        },
    };
    if let RecoveryDecision::RetransmitFragments { frag_indices, .. } = &decision
        && !frags.is_null()
        && frag_indices.len() <= frags_cap
    {
        for (slot, index) in frag_indices.iter().enumerate() {
            // SAFETY: `slot` is below `frag_indices.len()`, which the check above put at or under
            // `frags_cap` — the caller's promise of writable `u16`s.
            unsafe { frags.add(slot).write(*index) };
        }
    }
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, one writable, aligned decision.
        unsafe { out.write(flat) };
    }
    code
}

/// One of the recovery vocabulary's integer constants, by index — so neither end writes a number
/// the other also writes.
///
/// 0 the no-frame-decoded sentinel · 1 the NACK fragment cap · 2 the redundancy copy cap. An
/// unknown index answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_recovery_constant(index: u8) -> u32 {
    let size = |value: usize| u32::try_from(value).unwrap_or(0);
    match index {
        0 => recovery::NO_FRAME_DECODED_SENTINEL,
        1 => size(recovery::MAX_NACK_FRAGMENTS),
        2 => size(RecoveryRequestRedundancy::MAX_COPIES),
        _ => 0,
    }
}

// The DEFAULT floor has no door of its own, because no caller wants it on its own.
//
// Swift reads the floor exactly once, through `slopdesk_recovery_escalation_floor_seconds` with the
// process environment — and that door already ANSWERS the default for an absent, unparseable or
// out-of-band `SLOPDESK_ESCALATION_FLOOR_MS`. A second door would let a caller take the default
// while skipping the env, which is the one way the resolved floor could differ per process.

/// What `SLOPDESK_ESCALATION_FLOOR_MS` means, in seconds.
///
/// A value outside the 20…500 ms band is REJECTED rather than clamped: a caller asking for 5000 ms
/// has misunderstood the knob, and honouring half of that request would be worse than ignoring it.
///
/// # Safety
/// `raw` must be null or point to `len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_escalation_floor_seconds(raw: *const c_uchar, len: usize) -> f64 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let bytes = unsafe { borrow(raw, len) };
    let text = if bytes.is_empty() {
        None
    } else {
        core::str::from_utf8(bytes).ok()
    };
    recovery::escalation_floor_seconds(text)
}

/// Whether the client should stop waiting for an LTR refresh and demand an IDR.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_recovery_should_escalate_to_idr(
    idr_timeout_rtt_multiple: f64,
    lossy_idr_timeout_rtt_multiple: f64,
    lossy_escalation_floor: f64,
    lossy_escalation_floor_rtt_multiple: f64,
    elapsed_since_request: f64,
    rtt: f64,
    observing_loss: bool,
) -> bool {
    RecoveryPolicy {
        idr_timeout_rtt_multiple,
        lossy_idr_timeout_rtt_multiple,
        lossy_escalation_floor,
        lossy_escalation_floor_rtt_multiple,
    }
    .should_escalate_to_idr(elapsed_since_request, rtt, observing_loss)
}

/// One client's escalation episode, crossing as a VALUE.
///
/// Two optionals and nothing else, so there is no handle to allocate, free or alias: the caller
/// keeps the value and every door below answers the value that follows from it. `Option` has no C
/// spelling, so each one crosses as a payload plus the flag that says whether it is there — reading
/// a payload whose flag is false is a caller error, exactly as with the flat recovery message
/// above.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskLtrEscalation {
    /// When the episode's first request went out; meaningful only while `has_first_request`.
    pub first_request_time: f64,
    /// The newest frame id attributed to the episode; meaningful only while `has_max_lost`.
    pub max_lost_frame_id: u32,
    /// Whether an episode is outstanding.
    pub has_first_request: bool,
    /// Whether any loss was attributed to it.
    pub has_max_lost: bool,
}

/// A decode fed to the episode: the value that follows, and whether it CLOSED the episode.
///
/// The two answers arrive together because a caller that took them separately would have to decide
/// which one to trust when it re-derived the second from the first.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskLtrEscalationDecode {
    /// The episode after the decode.
    pub state: SlopDeskLtrEscalation,
    /// Whether that decode proved the chain re-anchored and ended the episode.
    pub cleared: bool,
}

impl SlopDeskLtrEscalation {
    /// The value read as the tracker it spells.
    const fn tracker(self) -> LtrEscalationTracker {
        let mut tracker = LtrEscalationTracker::new();
        if self.has_max_lost {
            tracker.note_loss(self.max_lost_frame_id);
        }
        if self.has_first_request {
            tracker.note_escalated(self.first_request_time);
        }
        tracker
    }

    /// The tracker written back as the value that crosses.
    fn of(tracker: &LtrEscalationTracker) -> Self {
        Self {
            first_request_time: tracker.first_request_time().unwrap_or(0.0),
            max_lost_frame_id: tracker.max_lost_frame_id().unwrap_or(0),
            has_first_request: tracker.has_outstanding_request(),
            has_max_lost: tracker.max_lost_frame_id().is_some(),
        }
    }
}

/// An episode with nothing outstanding — what a keyframe decode also leaves behind, which is why
/// there is no separate door for that: a keyframe references nothing, so it clears unconditionally.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ltr_escalation_clear() -> SlopDeskLtrEscalation {
    SlopDeskLtrEscalation::of(&LtrEscalationTracker::new())
}

/// Records one unrecoverably-lost frame, wrap-aware keep-newest.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ltr_escalation_note_loss(
    state: SlopDeskLtrEscalation,
    frame_id: u32,
) -> SlopDeskLtrEscalation {
    let mut tracker = state.tracker();
    tracker.note_loss(frame_id);
    SlopDeskLtrEscalation::of(&tracker)
}

/// Arms the clock on the FIRST request of an episode, and on no later one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ltr_escalation_note_request_sent(
    state: SlopDeskLtrEscalation,
    now: f64,
) -> SlopDeskLtrEscalation {
    let mut tracker = state.tracker();
    tracker.note_request_sent(now);
    SlopDeskLtrEscalation::of(&tracker)
}

/// Re-anchors the clock after an escalation FIRED, so the next one waits a full deadline.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ltr_escalation_note_escalated(
    state: SlopDeskLtrEscalation,
    now: f64,
) -> SlopDeskLtrEscalation {
    let mut tracker = state.tracker();
    tracker.note_escalated(now);
    SlopDeskLtrEscalation::of(&tracker)
}

/// Feeds a NON-keyframe decode to the episode.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ltr_escalation_frame_decoded(
    state: SlopDeskLtrEscalation,
    frame_id: u32,
) -> SlopDeskLtrEscalationDecode {
    let mut tracker = state.tracker();
    let cleared = tracker.frame_decoded(frame_id);
    SlopDeskLtrEscalationDecode {
        state: SlopDeskLtrEscalation::of(&tracker),
        cleared,
    }
}

/// Whether a forced IDR is due right now. Pure — the caller decides whether to act, and re-anchors
/// through [`slopdesk_ltr_escalation_note_escalated`] when it does.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ltr_escalation_should_escalate(
    state: SlopDeskLtrEscalation,
    idr_timeout_rtt_multiple: f64,
    lossy_idr_timeout_rtt_multiple: f64,
    lossy_escalation_floor: f64,
    lossy_escalation_floor_rtt_multiple: f64,
    now: f64,
    rtt: f64,
    observing_loss: bool,
) -> bool {
    state.tracker().should_escalate(
        now,
        rtt,
        &RecoveryPolicy {
            idr_timeout_rtt_multiple,
            lossy_idr_timeout_rtt_multiple,
            lossy_escalation_floor,
            lossy_escalation_floor_rtt_multiple,
        },
        observing_loss,
    )
}

/// The send-time offsets for one logical request. Returns how many offsets there ARE, writing them
/// only when `cap` holds them all.
///
/// # Safety
/// `out` must be null or point to `cap` writable `f64`s for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_send_offsets(
    copies: usize,
    spacing: f64,
    out: *mut f64,
    cap: usize,
) -> usize {
    let offsets = RecoveryRequestRedundancy::new(copies, spacing).send_offsets();
    if offsets.len() > cap || out.is_null() {
        return offsets.len();
    }
    for (slot, offset) in offsets.iter().enumerate() {
        // SAFETY: `slot` is below `offsets.len()`, which the check above put at or under `cap` —
        // the caller's promise of writable `f64`s.
        unsafe { out.add(slot).write(*offset) };
    }
    offsets.len()
}

/// The copy count a redundancy asks for, clamped to the legal band.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_recovery_clamped_copies(copies: usize) -> usize {
    RecoveryRequestRedundancy::new(copies, 0.0).copies()
}

/// `P(all copies lost)` under i.i.d. per-datagram loss.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_recovery_all_copies_lost_probability(
    per_datagram_loss: f64,
    copies: usize,
) -> f64 {
    RecoveryRequestRedundancy::all_copies_lost_probability(per_datagram_loss, copies)
}

/// The freeze that request loss is expected to add per loss event.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_recovery_expected_request_loss_freeze(
    per_datagram_loss: f64,
    copies: usize,
    escalation_delay: f64,
) -> f64 {
    RecoveryRequestRedundancy::expected_request_loss_freeze(per_datagram_loss, copies, escalation_delay)
}

/// Whether the host's frameQueue timer should re-encode its cached buffer as a forced keyframe.
///
/// The decider's whole state is four `f64`s and the rule is pure, so the state crosses as those
/// four scalars rather than as a handle: there is nothing to own across a call, and a handle would
/// buy an allocation, a free and a lifetime for a struct that is smaller than the pointer to it.
/// That keeps this the same shape as [`slopdesk_recovery_should_escalate_to_idr`] above — every
/// input a scalar, the answer a `bool`, no out-buffer and so no refusal to encode.
///
/// `0.0` is the "never happened" sentinel for both anchors, which is why they can be replayed
/// through the setters rather than needing a constructor: setting an anchor to `0.0` leaves the
/// value the freshly built decider already had.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_static_idr_should_reencode(
    heartbeat: f64,
    quiet_window: f64,
    last_complete_encode: f64,
    last_synthetic_encode: f64,
    now: f64,
    forced_latched: bool,
    has_retained_buffer: bool,
) -> bool {
    let mut decider = StaticIdrDecider::new(heartbeat, Some(quiet_window));
    decider.on_complete_frame(last_complete_encode);
    decider.record_synthetic(last_synthetic_encode);
    decider.should_reencode(now, forced_latched, has_retained_buffer)
}

/// Records one loss-ish event at `now`, rewriting the caller's ring IN PLACE.
///
/// An event is an unrecoverable loss or an FEC recovery. What the ring becomes is itself with
/// events older than the window pruned, the oldest dropped once the capacity is reached, and `now`
/// appended. Returns the new length, which is at most `count + 1`.
///
/// One buffer rather than a `(ptr, len)` in and an `(out, cap)` out: the answer is the argument,
/// one element longer at worst, so a caller that keeps one slot spare never allocates for an event.
/// Nothing aliases — the ring is read into an owned window before a byte of it is written back.
/// A `cap` too small to hold the answer leaves the buffer UNTOUCHED and still returns the length
/// the caller needs, exactly as §4's convention does.
///
/// # Safety
/// `events` must be null or point to `cap` writable, aligned `f64`s, of which the first `count`
/// are initialised, for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_loss_window_note(
    window_seconds: f64,
    capacity: usize,
    events: *mut f64,
    count: usize,
    now: f64,
    cap: usize,
) -> usize {
    if events.is_null() {
        return count.saturating_add(1);
    }
    // SAFETY: the caller's obligation — `cap` writable slots, the first `count` initialised.
    let ring = unsafe { core::slice::from_raw_parts_mut(events, cap) };
    note_in_place(window_seconds, capacity, ring, count, now)
}

/// Whether enough events lie within the window of `now`. A pure read — it does not prune, because a
/// stale entry simply fails the recency test.
///
/// # Safety
/// `events` must be null or point to `count` readable `f64`s for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_loss_window_observing(
    window_seconds: f64,
    min_events: usize,
    events: *const f64,
    count: usize,
    now: f64,
) -> bool {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBufferPointer`.
    let held = unsafe { borrow_events(events, count) };
    is_observing_loss(window_seconds, min_events, held, now)
}

/// The `f64` twin of [`crate::borrow`]: a null pointer is an empty ring, never a dereference.
///
/// # Safety
/// `ptr` must be null or point to `count` readable, aligned `f64`s for the borrow's lifetime.
#[expect(
    unsafe_code,
    reason = "reading a caller's (ptr, len) is the obligation this crate exists to carry"
)]
const unsafe fn borrow_events<'a>(ptr: *const f64, count: usize) -> &'a [f64] {
    if ptr.is_null() || count == 0 {
        return &[];
    }
    // SAFETY: the caller's obligation.
    unsafe { core::slice::from_raw_parts(ptr, count) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::expect_used,
    clippy::float_cmp,
    reason = "calling the boundary IS what these tests are for, and these floats are exact constants"
)]
mod tests {
    use super::*;

    fn encode(flat: &SlopDeskRecoveryMessage, frags: &[u16]) -> Vec<u8> {
        let mut out = [0u8; 256];
        let needed = unsafe {
            slopdesk_recovery_encode(&raw const *flat, frags.as_ptr(), out.as_mut_ptr(), out.len())
        };
        out[..needed].to_vec()
    }

    fn decode(bytes: &[u8]) -> Option<(SlopDeskRecoveryMessage, Vec<u16>)> {
        let mut flat = SlopDeskRecoveryMessage::default();
        let mut frags = [0u16; recovery::MAX_NACK_FRAGMENTS];
        let verdict = unsafe {
            slopdesk_recovery_decode(
                bytes.as_ptr(),
                bytes.len(),
                &raw mut flat,
                frags.as_mut_ptr(),
                frags.len(),
            )
        };
        let count = usize::from(flat.frag_count);
        (verdict == DECODE_OK).then(|| (flat, frags[..count].to_vec()))
    }

    #[test]
    fn every_arm_round_trips_through_the_flat_shape() {
        let arms: [(SlopDeskRecoveryMessage, Vec<u16>); 4] = [
            (
                SlopDeskRecoveryMessage {
                    message_type: 1,
                    stream_seq: 4242,
                    ..SlopDeskRecoveryMessage::default()
                },
                Vec::new(),
            ),
            (
                SlopDeskRecoveryMessage {
                    message_type: 2,
                    from_frame_id: 7,
                    to_frame_id: 9,
                    last_decoded_frame_id: recovery::NO_FRAME_DECODED_SENTINEL,
                    ..SlopDeskRecoveryMessage::default()
                },
                Vec::new(),
            ),
            (
                SlopDeskRecoveryMessage {
                    message_type: 4,
                    shape_id: 3,
                    ..SlopDeskRecoveryMessage::default()
                },
                Vec::new(),
            ),
            (
                SlopDeskRecoveryMessage {
                    message_type: 6,
                    frame_id: 11,
                    frag_count: 3,
                    ..SlopDeskRecoveryMessage::default()
                },
                vec![1, 4, 9],
            ),
        ];
        for (flat, frags) in arms {
            let wire = encode(&flat, &frags);
            let (back, back_frags) = decode(&wire).expect("what this side wrote, this side reads");
            assert_eq!(back, flat, "type {}", flat.message_type);
            assert_eq!(back_frags, frags, "type {}", flat.message_type);
        }
    }

    #[test]
    fn the_boundary_agrees_with_the_codec_it_wraps() {
        let stats = NetworkStatsReport {
            frames_received: 120,
            fec_recovered: 4,
            unrecovered: 1,
            latest_host_send_ts: 90_000,
            client_hold_ms: 3,
            owd_jitter_micros: 850,
            owd_trend_milli: 17,
            owd_trend_flags: 0x0501,
            pacer_late_frames: 2,
            pacer_present_gaps: 5,
            pacer_depth: 1,
        };
        let direct = RecoveryMessage::NetworkStats(stats).encode();
        let flat = SlopDeskRecoveryMessage::from_message(&RecoveryMessage::NetworkStats(stats));
        assert_eq!(encode(&flat, &[]), direct);
    }

    #[test]
    fn a_trailing_byte_is_refused_because_the_host_dedups_on_raw_bytes() {
        let mut wire = encode(
            &SlopDeskRecoveryMessage {
                message_type: 3,
                last_decoded_frame_id: 5,
                ..SlopDeskRecoveryMessage::default()
            },
            &[],
        );
        assert!(decode(&wire).is_some());
        wire.push(0);
        assert!(decode(&wire).is_none(), "a suffix must not decode");
        assert!(decode(&[]).is_none(), "nor an empty datagram");
        assert!(decode(&[99, 0, 0, 0, 0]).is_none(), "nor an unknown type");

        // And the two refusals stay told apart, because the caller's vocabulary tells them apart.
        let verdict = |bytes: &[u8]| unsafe {
            slopdesk_recovery_decode(
                bytes.as_ptr(),
                bytes.len(),
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(verdict(&[3, 0, 0]), DECODE_TRUNCATED, "a body cut short");
        assert_eq!(verdict(&wire), DECODE_MALFORMED, "a body with a suffix");
        assert_eq!(verdict(&[99]), DECODE_MALFORMED, "a type no arm answers to");
    }

    #[test]
    fn an_unknown_type_encodes_to_nothing_rather_than_to_a_guess() {
        let flat = SlopDeskRecoveryMessage {
            message_type: 99,
            ..SlopDeskRecoveryMessage::default()
        };
        let mut out = [0u8; 32];
        let needed = unsafe {
            slopdesk_recovery_encode(&raw const flat, core::ptr::null(), out.as_mut_ptr(), out.len())
        };
        assert_eq!(needed, 0);
        assert_eq!(out, [0u8; 32], "a refusal writes nothing at all");
    }

    fn route(bytes: &[u8], media_flowing: bool) -> (u32, SlopDeskRecoveryDecision, Vec<u16>) {
        let mut flat = SlopDeskRecoveryDecision::default();
        let mut frags = [0u16; recovery::MAX_NACK_FRAGMENTS];
        let code = unsafe {
            slopdesk_recovery_route(
                bytes.as_ptr(),
                bytes.len(),
                media_flowing,
                &raw mut flat,
                frags.as_mut_ptr(),
                frags.len(),
            )
        };
        let count = usize::try_from(flat.frag_count).unwrap_or(0);
        (code, flat, frags[..count.min(frags.len())].to_vec())
    }

    /// The guard order IS the rule: a datagram that could not decode still answers IGNORE, not
    /// DROP, when nothing is streaming — a decode attempted first would parse hostile bytes on a
    /// session that has no stream to recover.
    #[test]
    fn a_datagram_is_ignored_before_it_is_decoded_when_nothing_is_streaming() {
        assert_eq!(route(&[0xFF], false).0, ROUTE_IGNORE_NOT_STREAMING);
        assert_eq!(route(&[0xFF], true).0, ROUTE_DROP);
    }

    /// The sentinel is the half of the routing rule that must not cross. Both frontier-carrying
    /// arms answer `has_frontier == false` for it, so the near side never compares against a magic
    /// number of its own.
    #[test]
    fn the_wire_sentinel_crosses_as_an_absent_frontier_and_never_as_its_number() {
        for (message, expected) in [
            (
                RecoveryMessage::RequestIdr {
                    last_decoded_frame_id: recovery::NO_FRAME_DECODED_SENTINEL,
                },
                ROUTE_FORCE_KEYFRAME,
            ),
            (
                RecoveryMessage::RequestLtrRefresh {
                    from_frame_id: 1,
                    to_frame_id: 4,
                    last_decoded_frame_id: recovery::NO_FRAME_DECODED_SENTINEL,
                },
                ROUTE_REFRESH_LTR,
            ),
        ] {
            let (code, flat, _) = route(&message.encode(), true);
            assert_eq!(code, expected);
            assert!(!flat.has_frontier, "the sentinel is an ABSENT frontier");
            assert_ne!(
                flat.frontier,
                recovery::NO_FRAME_DECODED_SENTINEL,
                "and its number must not be what crossed",
            );
        }
        let (code, flat, _) = route(
            &RecoveryMessage::RequestIdr {
                last_decoded_frame_id: 900,
            }
            .encode(),
            true,
        );
        assert_eq!(code, ROUTE_FORCE_KEYFRAME);
        assert!(flat.has_frontier);
        assert_eq!(flat.frontier, 900);
    }

    /// Every field of a report reaches the verdict. A record that dropped one would still route,
    /// still compile and simply lose a number the estimate folds.
    #[test]
    fn a_network_report_crosses_the_verdict_field_for_field() {
        let stats = NetworkStatsReport {
            frames_received: 600,
            fec_recovered: 12,
            unrecovered: 3,
            latest_host_send_ts: 1_234_567,
            client_hold_ms: 7,
            owd_jitter_micros: 850,
            owd_trend_milli: (-987_i32).cast_unsigned(),
            owd_trend_flags: (42 << 8) | 1,
            pacer_late_frames: 4,
            pacer_present_gaps: 6,
            pacer_depth: 2,
        };
        let (code, flat, _) = route(&RecoveryMessage::NetworkStats(stats).encode(), true);
        assert_eq!(code, ROUTE_NETWORK_STATS);
        assert_eq!(flat, SlopDeskRecoveryDecision::with_stats(&stats));
        assert_eq!(flat.frames_received, 600);
        assert_eq!(flat.fec_recovered, 12);
        assert_eq!(flat.unrecovered, 3);
        assert_eq!(flat.latest_host_send_ts, 1_234_567);
        assert_eq!(flat.client_hold_ms, 7);
        assert_eq!(flat.owd_jitter_micros, 850);
        assert_eq!(flat.owd_trend_milli, (-987_i32).cast_unsigned());
        assert_eq!(flat.owd_trend_flags, (42 << 8) | 1);
        assert_eq!(flat.pacer_late_frames, 4);
        assert_eq!(flat.pacer_present_gaps, 6);
        assert_eq!(flat.pacer_depth, 2);
    }

    /// The three remaining arms each name their own field, and none of them borrows another's.
    #[test]
    fn the_scalar_arms_each_answer_in_their_own_field() {
        let (code, flat, _) = route(&RecoveryMessage::Ack { stream_seq: 77 }.encode(), true);
        assert_eq!((code, flat.stream_seq), (ROUTE_ACK, 77));

        let (code, flat, _) = route(
            &RecoveryMessage::RequestCursorShape { shape_id: 12 }.encode(),
            true,
        );
        assert_eq!((code, flat.shape_id), (ROUTE_RESHIP_CURSOR_SHAPE, 12));

        let (code, flat, frags) = route(
            &RecoveryMessage::RequestFragments {
                frame_id: 500,
                frag_indices: vec![1, 3, 4],
            }
            .encode(),
            true,
        );
        assert_eq!(code, ROUTE_RETRANSMIT_FRAGMENTS);
        assert_eq!((flat.frame_id, flat.frag_count), (500, 3));
        assert_eq!(frags, vec![1, 3, 4]);
    }

    /// A buffer too small is told how many indices there are and given none of them — §4's retry,
    /// so a caller that asks again sees an untouched buffer rather than a partial request.
    #[test]
    fn a_short_index_buffer_is_left_untouched_and_still_counted() {
        let wire = RecoveryMessage::RequestFragments {
            frame_id: 8,
            frag_indices: vec![2, 5, 9],
        }
        .encode();
        let mut flat = SlopDeskRecoveryDecision::default();
        let mut tiny = [0u16; 2];
        let code = unsafe {
            slopdesk_recovery_route(
                wire.as_ptr(),
                wire.len(),
                true,
                &raw mut flat,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert_eq!(code, ROUTE_RETRANSMIT_FRAGMENTS);
        assert_eq!(flat.frag_count, 3, "the count crosses whether or not it fits");
        assert_eq!(tiny, [0u16; 2], "and nothing at all was written");

        // A NULL buffer still routes and still counts, exactly as the decode door's does.
        let code = unsafe {
            slopdesk_recovery_route(
                wire.as_ptr(),
                wire.len(),
                true,
                &raw mut flat,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!((code, flat.frag_count), (ROUTE_RETRANSMIT_FRAGMENTS, 3));
    }

    #[test]
    fn the_escalation_clock_halves_but_never_below_the_floor() {
        // Not observing loss: the plain 2·RTT, no floor at all.
        assert!(!slopdesk_recovery_should_escalate_to_idr(
            2.0, 1.0, 0.06, 1.5, 0.15, 0.1, false
        ));
        assert!(slopdesk_recovery_should_escalate_to_idr(
            2.0, 1.0, 0.06, 1.5, 0.2, 0.1, false
        ));
        // Observing loss at a 10 ms RTT: 1·RTT would be 10 ms, but the 60 ms floor holds.
        assert!(!slopdesk_recovery_should_escalate_to_idr(
            2.0, 1.0, 0.06, 1.5, 0.05, 0.01, true
        ));
        assert!(slopdesk_recovery_should_escalate_to_idr(
            2.0, 1.0, 0.06, 1.5, 0.06, 0.01, true
        ));
    }

    #[test]
    fn the_floor_takes_the_default_for_anything_outside_its_band() {
        let default = recovery::DEFAULT_LOSSY_ESCALATION_FLOOR_SECONDS;
        for raw in ["", "nonsense", "5000", "1"] {
            let seconds = unsafe { slopdesk_recovery_escalation_floor_seconds(raw.as_ptr(), raw.len()) };
            assert_eq!(seconds, default, "{raw} is not in the band");
        }
        let inside = "120";
        let seconds = unsafe { slopdesk_recovery_escalation_floor_seconds(inside.as_ptr(), inside.len()) };
        assert!((seconds - 0.12).abs() < 1e-12);
    }

    #[test]
    fn the_offsets_are_spaced_and_the_copies_are_clamped() {
        let mut out = [0.0f64; 8];
        let count = unsafe { slopdesk_recovery_send_offsets(3, 0.003, out.as_mut_ptr(), out.len()) };
        assert_eq!(count, 3);
        assert!((out[1] - 0.003).abs() < 1e-12);
        assert!((out[2] - 0.006).abs() < 1e-12);
        assert_eq!(slopdesk_recovery_clamped_copies(99), 5);
        assert_eq!(slopdesk_recovery_clamped_copies(0), 1);

        // A buffer too small is told how many there are and given none of them.
        let mut tiny = [0.0f64; 1];
        let needed = unsafe { slopdesk_recovery_send_offsets(3, 0.003, tiny.as_mut_ptr(), 1) };
        assert_eq!(needed, 3);
        assert_eq!(tiny, [0.0]);
    }

    #[test]
    fn the_static_idr_state_replays_through_the_scalars_the_swift_timer_passes() {
        // Called exactly as `WindowCapturer`'s frameQueue tick calls it: the four anchors it is
        // holding, then the tick's `now` and the two latches.
        let ask = |complete: f64, synthetic: f64, now: f64, forced: bool, retained: bool| {
            slopdesk_static_idr_should_reencode(1.0, 1.0, complete, synthetic, now, forced, retained)
        };

        assert!(
            !ask(0.0, 0.0, 5.0, true, false),
            "no cached pixels beats even a latched request"
        );
        assert!(
            ask(0.0, 0.0, 0.0, false, true),
            "armed, quiet, nothing emitted yet"
        );
        assert!(
            !ask(4.5, 0.0, 5.0, true, true),
            "the live path owns the cadence inside the window"
        );
        assert!(
            ask(3.0, 9.0, 5.0, true, true),
            "once quiet, a frozen client wins any phase"
        );
        assert!(
            !ask(3.0, 4.5, 5.0, false, true),
            "half a heartbeat since the last synthetic"
        );
        assert!(
            ask(3.0, 4.0, 5.0, false, true),
            "a whole heartbeat since the last synthetic"
        );

        // The anchors are replayed through the setters, and `0.0` must stay the "never happened"
        // sentinel rather than becoming an event at time zero — otherwise the first tick of a
        // session would read as a synthetic emitted a heartbeat ago and fire twice.
        assert!(
            ask(0.0, 0.0, 0.5, false, true),
            "a zero anchor is no anchor, not an early one"
        );
    }

    #[test]
    fn the_window_prunes_by_age_and_drops_the_oldest_at_capacity() {
        fn note(events: &[f64], now: f64) -> Vec<f64> {
            // Nine slots for a window of eight: the caller owes the law one spare, which is what
            // Swift's `events.append(now)` buys before it hands the ring over.
            let mut ring = [0.0f64; 9];
            let live = events.len().min(8);
            ring.get_mut(..live)
                .unwrap_or_default()
                .copy_from_slice(events.get(..live).unwrap_or_default());
            let count = unsafe {
                slopdesk_recovery_loss_window_note(1.0, 8, ring.as_mut_ptr(), live, now, ring.len())
            };
            ring.get(..count).unwrap_or_default().to_vec()
        }

        fn observing(events: &[f64], now: f64) -> bool {
            unsafe { slopdesk_recovery_loss_window_observing(1.0, 2, events.as_ptr(), events.len(), now) }
        }

        let one = note(&[], 0.0);
        assert!(!observing(&one, 0.0), "one event is not a pattern");
        let two = note(&one, 0.1);
        assert!(observing(&two, 0.1));
        assert!(!observing(&two, 5.0), "both have aged out by then");
        let later = note(&two, 5.0);
        assert_eq!(later.len(), 1, "the stale pair was pruned, not counted");

        // At capacity the oldest goes, so the ring stays bounded whatever the feed rate.
        let mut ring = Vec::new();
        for step in 0..12 {
            ring = note(&ring, f64::from(step) * 0.01);
        }
        assert_eq!(ring.len(), 8);
    }
}
