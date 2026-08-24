//! Client→host loss recovery and acknowledgement —
//! `Sources/SlopDeskVideoProtocol/RecoverySignaling.swift` (doc 17 §3.6).
//!
//! Recovery prefers an **LTR refresh** over a forced IDR, to dodge a keyframe's bandwidth and
//! latency spike: the client names the frames it missed, the host marks that long-term reference
//! invalid and encodes the next frame against an older, still-valid one. No usable frame within
//! about two RTT escalates to a forced IDR. Invalidation runs client→host; this module is the
//! messages and the client-side decision logic, not the encoder wiring.
//!
//! ## Trailing bytes are rejected, and that is load-bearing
//!
//! The client always emits exact-width datagrams, and the host's request deduper keys on the RAW
//! datagram bytes. A decoder that tolerated a suffix would let suffix-varied copies of ONE logical
//! request each decode identically while bypassing the byte-keyed dedup — re-triggering a second
//! `ForceLTRRefresh` or IDR for a loss that was already answered. No backcompat is owed: both ends
//! redeploy together, so a body missing or gaining a field is simply hostile input.
//!
//! ## Every stats field is RELATIVE
//!
//! The report carries windowed counters, an echo of the newest host stamp the client saw, and
//! client-local deltas — never an absolute client timestamp. The host derives RTT in its OWN clock,
//! so no part of the estimate depends on the two machines agreeing about what time it is.
//!
//! Pinned by the `recovery` golden vectors.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};
use crate::reassembler::distance_wrapped;

/// Wire sentinel for "the client has not decoded any frame yet".
///
/// It cannot collide with a real id at session start: packetizer ids begin at 0, so this is a full
/// 2^32 frames away across the wrap — about 2.3 years at 60 fps.
pub const NO_FRAME_DECODED_SENTINEL: u32 = 0xFFFF_FFFF;

/// Max fragment indices a single NACK may carry. A larger loss escalates to an LTR refresh or an
/// IDR rather than a big selective retransmit.
pub const MAX_NACK_FRAGMENTS: usize = 64;

/// Periodic client→host network feedback.
///
/// Telemetry only — it does not change stream behaviour. Fixed-width and all-`u32`, so a malformed
/// report fails decode, the router drops the one datagram, and nothing else notices.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NetworkStatsReport {
    /// Complete frames received in this report window.
    pub frames_received: u32,
    /// Of those, how many completed via FEC recovery.
    pub fec_recovered: u32,
    /// Frames declared unrecoverably lost in this window — the loss numerator.
    pub unrecovered: u32,
    /// The newest `host_send_ts_millis` observed on a fragment; 0 means none, or telemetry off.
    pub latest_host_send_ts: u32,
    /// Client-LOCAL elapsed ms since it observed `latest_host_send_ts` — a delta in the client's
    /// own monotonic clock, never an absolute timestamp. The host subtracts it so the
    /// client-side processing hold is removed from RTT.
    pub client_hold_ms: u32,
    /// Inter-arrival jitter in microseconds, RFC 3550 second-difference form, from relative deltas
    /// only and so fully skew-immune.
    pub owd_jitter_micros: u32,
    /// The trendline detector's modified trend ×1000, clamped to ±1e9, carried as an `i32` bit
    /// pattern. 0 when disabled or not yet warmed up.
    pub owd_trend_milli: u32,
    /// Detector flags: bits 0-1 the state, bits 8-15 the sample count saturated at 255. 0 is inert.
    pub owd_trend_flags: u32,
    /// Windowed count of presents that ENDED a dense-flow late gap — the clean hitch signal.
    pub pacer_late_frames: u32,
    /// Windowed count of late-gap EPISODES opened. A superset of `pacer_late_frames`: it includes
    /// motion-stop boundaries.
    pub pacer_present_gaps: u32,
    /// Gauge: the client pacer's live presentation depth; 0 means no pacer attached.
    pub pacer_depth: u32,
}

impl NetworkStatsReport {
    /// The number of `u32` fields on the wire.
    const FIELD_COUNT: usize = 11;

    /// Detector state from bits 0-1 of the flags: 0 normal, 1 overusing, 2 underusing.
    #[must_use]
    pub const fn owd_trend_state_raw(&self) -> u8 {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the mask keeps only the low two bits"
        )]
        {
            (self.owd_trend_flags as u8) & 0x3
        }
    }

    /// Detector sample count from bits 8-15 of the flags, saturated at 255.
    #[must_use]
    pub const fn owd_trend_deltas(&self) -> u32 {
        (self.owd_trend_flags >> 8) & 0xFF
    }

    /// The trend field reinterpreted as the signed milli-trend it carries.
    #[must_use]
    pub const fn owd_trend_modified_milli_signed(&self) -> i32 {
        #[expect(
            clippy::cast_possible_wrap,
            reason = "the field IS an i32 bit pattern; the u32 is how the wire spells it"
        )]
        {
            self.owd_trend_milli as i32
        }
    }
}

/// A client→host recovery-channel message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryMessage {
    /// Acknowledge the highest contiguous `stream_seq` durably received, bounding the host's
    /// retransmit and LTR-pin window.
    ///
    /// Doubles as the LTR ack, sent after a SUCCESSFUL decode of an LTR-flagged frame and carrying
    /// that frame's `frame_id` in this field. The name is a misnomer in that arm: the host feeds
    /// the value to its LTR controller, not to a sequence tracker.
    Ack {
        /// The acked sequence, or the acked LTR `frame_id`.
        stream_seq: u32,
    },
    /// Request-for-invalidate: frames `[from, to]` inclusive were lost, so refresh from an earlier
    /// LTR rather than a full IDR.
    ///
    /// Carries `last_decoded_frame_id` for the host's DELIVERY-KEYED cooldown: it distinguishes a
    /// recently-sent keyframe that was delivered — the request is newer than it — from one that was
    /// itself a casualty, which bypasses the cooldown immediately.
    RequestLtrRefresh {
        /// First lost frame, inclusive.
        from_frame_id: u32,
        /// Last lost frame, inclusive.
        to_frame_id: u32,
        /// The client's highest successfully decoded frame, or [`NO_FRAME_DECODED_SENTINEL`].
        last_decoded_frame_id: u32,
    },
    /// Escalation after the LTR-refresh timeout elapsed with no decodable frame: demand a forced
    /// IDR.
    RequestIdr {
        /// The client's decode frontier, for the same delivery-keyed cooldown.
        last_decoded_frame_id: u32,
    },
    /// Re-request a cursor SHAPE bitmap the client is missing.
    ///
    /// A shape ships once per id, so a lost datagram would otherwise leave the overlay wrong for
    /// the whole session — the host strips the real cursor. The re-insert is idempotent.
    RequestCursorShape {
        /// The shape the client's cache is missing.
        shape_id: u16,
    },
    /// Periodic network feedback.
    NetworkStats(NetworkStatsReport),
    /// NACK / selective ARQ: retransmit exactly these DATA fragments of `frame_id` from the host's
    /// send-history ring, instead of a full recovery IDR.
    ///
    /// With the client's playout buffer well above RTT the retransmit lands before playout, so the
    /// loss costs no stutter at all. Variable-length but SELF-DELIMITING — a count precedes the
    /// indices — so the trailing-bytes rejection still holds.
    RequestFragments {
        /// The frame missing fragments.
        frame_id: u32,
        /// The missing DATA indices, at most [`MAX_NACK_FRAGMENTS`].
        frag_indices: Vec<u16>,
    },
}

impl RecoveryMessage {
    /// The on-wire message-type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match *self {
            Self::Ack { .. } => 1,
            Self::RequestLtrRefresh { .. } => 2,
            Self::RequestIdr { .. } => 3,
            Self::RequestCursorShape { .. } => 4,
            Self::NetworkStats(_) => 5,
            Self::RequestFragments { .. } => 6,
        }
    }

    /// Serialises the message as `[type][body]`.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(1 + Self::FIXED_BODY_MAX);
        out.put_u8(self.message_type());
        match *self {
            Self::Ack { stream_seq } => out.put_u32(stream_seq),
            Self::RequestLtrRefresh {
                from_frame_id,
                to_frame_id,
                last_decoded_frame_id,
            } => {
                out.put_u32(from_frame_id);
                out.put_u32(to_frame_id);
                out.put_u32(last_decoded_frame_id);
            },
            Self::RequestIdr {
                last_decoded_frame_id,
            } => out.put_u32(last_decoded_frame_id),
            Self::RequestCursorShape { shape_id } => out.put_u16(shape_id),
            Self::NetworkStats(report) => {
                out.put_u32(report.frames_received);
                out.put_u32(report.fec_recovered);
                out.put_u32(report.unrecovered);
                out.put_u32(report.latest_host_send_ts);
                out.put_u32(report.client_hold_ms);
                out.put_u32(report.owd_jitter_micros);
                out.put_u32(report.owd_trend_milli);
                out.put_u32(report.owd_trend_flags);
                out.put_u32(report.pacer_late_frames);
                out.put_u32(report.pacer_present_gaps);
                out.put_u32(report.pacer_depth);
            },
            Self::RequestFragments {
                frame_id,
                ref frag_indices,
            } => {
                out.put_u32(frame_id);
                // The caller bounds the list; truncating here is a defensive backstop, never live.
                let capped = frag_indices.get(..MAX_NACK_FRAGMENTS).unwrap_or(frag_indices);
                #[expect(
                    clippy::cast_possible_truncation,
                    reason = "the slice above is at most 64 long"
                )]
                out.put_u16(capped.len() as u16);
                for index in capped {
                    out.put_u16(*index);
                }
            },
        }
        out.into_vec()
    }

    /// The widest fixed body, so the writer sizes itself once: the eleven-field stats report.
    const FIXED_BODY_MAX: usize = NetworkStatsReport::FIELD_COUNT * 4;

    /// Parses a recovery message.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for a short body, and [`VideoProtocolError::Malformed`]
    /// for an unknown type, a NACK count past the cap, or ANY trailing byte. Every read is
    /// bounds-checked first, so a hostile datagram is an error rather than a crash.
    pub fn decode(datagram: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(datagram);
        let message_type = reader.read_u8()?;
        let message = match message_type {
            1 => {
                Self::Ack {
                    stream_seq: reader.read_u32()?,
                }
            },
            2 => {
                Self::RequestLtrRefresh {
                    from_frame_id: reader.read_u32()?,
                    to_frame_id: reader.read_u32()?,
                    last_decoded_frame_id: reader.read_u32()?,
                }
            },
            3 => {
                Self::RequestIdr {
                    last_decoded_frame_id: reader.read_u32()?,
                }
            },
            4 => {
                Self::RequestCursorShape {
                    shape_id: reader.read_u16()?,
                }
            },
            5 => {
                Self::NetworkStats(NetworkStatsReport {
                    frames_received: reader.read_u32()?,
                    fec_recovered: reader.read_u32()?,
                    unrecovered: reader.read_u32()?,
                    latest_host_send_ts: reader.read_u32()?,
                    client_hold_ms: reader.read_u32()?,
                    owd_jitter_micros: reader.read_u32()?,
                    owd_trend_milli: reader.read_u32()?,
                    owd_trend_flags: reader.read_u32()?,
                    pacer_late_frames: reader.read_u32()?,
                    pacer_present_gaps: reader.read_u32()?,
                    pacer_depth: reader.read_u32()?,
                })
            },
            6 => {
                let frame_id = reader.read_u32()?;
                let count = usize::from(reader.read_u16()?);
                if count > MAX_NACK_FRAGMENTS {
                    return Err(VideoProtocolError::malformed(
                        "NACK fragment count exceeds the cap",
                    ));
                }
                // No `reserve` for a peer-supplied count: the cap above already bounds it, and the
                // loop below fails on the first missing byte either way.
                let mut frag_indices = Vec::new();
                for _ in 0..count {
                    frag_indices.push(reader.read_u16()?);
                }
                Self::RequestFragments {
                    frame_id,
                    frag_indices,
                }
            },
            other => {
                return Err(VideoProtocolError::malformed(
                    &format!("unknown recovery message type {other}")[..],
                ));
            },
        };
        if !reader.remaining().is_empty() {
            return Err(VideoProtocolError::malformed("trailing bytes"));
        }
        Ok(message)
    }
}

/// The client-side recovery policy: which message to send for a detected loss, and when to
/// escalate.
///
/// Pure decision logic — the timer and the transport live in the client.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecoveryPolicy {
    /// Escalate to IDR after this multiple of the measured RTT.
    pub idr_timeout_rtt_multiple: f64,
    /// The HALVED multiple used while the client is observing loss. Once requests go out
    /// redundantly, the 2·RTT wait becomes the dominant residual freeze term, and a lossy path has
    /// already shown that waiting longer rarely saves the IDR.
    pub lossy_idr_timeout_rtt_multiple: f64,
    /// Floor on the LOSSY deadline, in seconds.
    ///
    /// An LTR-refresh response physically needs host encode plus flight plus client decode — about
    /// 40-60 ms at the live path's 10-30 ms RTT — so a lower floor lets the client escalate BEFORE
    /// the medicine can land. A 30 ms floor measured 202 IDR requests against 100 LTR refreshes in
    /// 169 s: a 97-suppression storm.
    pub lossy_escalation_floor: f64,
    /// The RTT-proportional part of the lossy floor. A refresh round trip is at least one RTT, plus
    /// encode, decode and frame-interval overhead worth about half an RTT on the target path, so
    /// escalating earlier than 1.5·RTT can only duplicate work.
    pub lossy_escalation_floor_rtt_multiple: f64,
}

impl Default for RecoveryPolicy {
    fn default() -> Self {
        Self {
            idr_timeout_rtt_multiple: 2.0,
            lossy_idr_timeout_rtt_multiple: 1.0,
            lossy_escalation_floor: DEFAULT_LOSSY_ESCALATION_FLOOR_SECONDS,
            lossy_escalation_floor_rtt_multiple: 1.5,
        }
    }
}

/// The lossy escalation floor when the environment says nothing: 60 ms.
pub const DEFAULT_LOSSY_ESCALATION_FLOOR_SECONDS: f64 = 0.06;

/// PURE resolution of `SLOPDESK_ESCALATION_FLOOR_MS`, in seconds.
///
/// Absent, unparseable, non-finite or out-of-band values keep the default — this runs at process
/// start and must never be the thing that stops a session. The band is 20…500 ms, and a value
/// OUTSIDE it is rejected rather than clamped, because a caller asking for 5000 ms has
/// misunderstood the knob, and honouring half of that request would be worse than ignoring it.
#[must_use]
pub fn escalation_floor_seconds(raw: Option<&str>) -> f64 {
    let Some(value) = raw.and_then(|text| text.parse::<f64>().ok()) else {
        return DEFAULT_LOSSY_ESCALATION_FLOOR_SECONDS;
    };
    if !value.is_finite() || !(20.0..=500.0).contains(&value) {
        return DEFAULT_LOSSY_ESCALATION_FLOOR_SECONDS;
    }
    value / 1000.0
}

impl RecoveryPolicy {
    /// The first message to send when frames `[lost_from, lost_to]` are detected lost: prefer an
    /// LTR refresh. `last_decoded` is passed through for the host's delivery-keyed cooldown.
    #[must_use]
    pub const fn initial_request(lost_from: u32, lost_to: u32, last_decoded: u32) -> RecoveryMessage {
        RecoveryMessage::RequestLtrRefresh {
            from_frame_id: lost_from,
            to_frame_id: lost_to,
            last_decoded_frame_id: last_decoded,
        }
    }

    /// Whether to escalate to a forced IDR.
    ///
    /// Not observing loss is the plain multiple with NO floor. Observing loss is the halved clock
    /// floored at the physically-arrivable response time, so the halving stays above the floor and
    /// the floor only guarantees a refresh gets the time it needs before the IDR sledgehammer.
    #[must_use]
    pub fn should_escalate_to_idr(&self, elapsed_since_request: f64, rtt: f64, observing_loss: bool) -> bool {
        let deadline = if observing_loss {
            // NaN-ignoring IEEE max, matching Swift's `Double.maximum` — never a `>` ternary.
            let floor = self
                .lossy_escalation_floor
                .max(self.lossy_escalation_floor_rtt_multiple * rtt);
            (self.lossy_idr_timeout_rtt_multiple * rtt).max(floor)
        } else {
            self.idr_timeout_rtt_multiple * rtt
        };
        elapsed_since_request >= deadline
    }
}

/// How many byte-identical copies of one logical recovery request the client sends, and how far
/// apart.
///
/// A recovery request is a single datagram of at most 17 bytes riding the same lossy path it
/// reports on — measured bursts of 3-9%. A lost request costs the full escalation wait of extra
/// frozen frame, which is the ranked hitch tail.
///
/// ## Why the copies are SPACED rather than sent back to back
///
/// Measured losses are bursty — up to about fifteen adjacent datagrams, which is the interleaver's
/// whole reason for existing — so spacing decorrelates the copies' fate. At recovery time the send
/// lane is mostly idle, so without spacing the copies would land adjacent on the wire and share one
/// burst.
///
/// ## The coupling invariant
///
/// The total spread `(copies - 1) * spacing` must stay at or under HALF the host's dedup window —
/// 25 ms by default — for EVERY legal copy count: 6 ms at the default 3 copies, 12 ms at the
/// maximum 5, against a 12.5 ms budget. Duplicates do not refresh the dedup timestamp, so a copy
/// that aged past the window would re-admit as a second host action: a double `ForceLTRRefresh` for
/// one loss. A 5 ms spacing breaks this — it stretches the maximum spread to 20 ms, a margin thin
/// enough for a delayed copy to re-admit.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecoveryRequestRedundancy {
    copies: usize,
    spacing: f64,
}

impl Default for RecoveryRequestRedundancy {
    fn default() -> Self {
        Self::new(3, 0.003)
    }
}

impl RecoveryRequestRedundancy {
    /// The most copies one logical request may be sent as.
    pub const MAX_COPIES: usize = 5;

    /// Builds a redundancy plan. `copies` is clamped to 1…[`Self::MAX_COPIES`]; 1 is a single send.
    #[must_use]
    pub const fn new(copies: usize, spacing: f64) -> Self {
        Self {
            copies: if copies < 1 {
                1
            } else if copies > Self::MAX_COPIES {
                Self::MAX_COPIES
            } else {
                copies
            },
            spacing,
        }
    }

    /// Total sends per logical request.
    #[must_use]
    pub const fn copies(&self) -> usize {
        self.copies
    }

    /// Seconds between consecutive copies.
    #[must_use]
    pub const fn spacing(&self) -> f64 {
        self.spacing
    }

    /// Send-time offsets for one logical request: `[0, spacing, 2·spacing, …]`.
    #[must_use]
    pub fn send_offsets(&self) -> Vec<f64> {
        #[expect(
            clippy::cast_precision_loss,
            reason = "the copy count is at most 5, which every f64 represents exactly"
        )]
        (0..self.copies)
            .map(|index| index as f64 * self.spacing)
            .collect()
    }

    /// The probability every copy is lost under i.i.d. per-datagram loss.
    #[must_use]
    pub fn all_copies_lost_probability(per_datagram_loss: f64, copies: usize) -> f64 {
        // NOT `clamp`: it returns NaN for a NaN input, where the IEEE max-then-min pair — like the
        // Swift original's `min(1.0, max(0.0, p))` — folds a NaN loss rate to 0. A garbage estimate
        // must read as "no loss", never poison the freeze budget.
        #[expect(
            clippy::manual_clamp,
            reason = "the NaN behaviour is the difference, see above"
        )]
        let probability = per_datagram_loss.max(0.0).min(1.0);
        let plan = Self::new(copies, 0.0);
        let mut out = 1.0;
        for _ in 0..plan.copies {
            out *= probability;
        }
        out
    }

    /// Expected freeze added by REQUEST loss per loss event — the freeze-time math as a function
    /// rather than as a paragraph.
    #[must_use]
    pub fn expected_request_loss_freeze(per_datagram_loss: f64, copies: usize, escalation_delay: f64) -> f64 {
        Self::all_copies_lost_probability(per_datagram_loss, copies) * escalation_delay
    }
}

/// The predicate gating the halved escalation clock.
///
/// Fed from what the client already knows: every unrecoverable loss, AND every FEC-recovered frame.
/// The second is the early-warning channel — the measured 10 s bursts produce several FEC
/// recoveries per second BEFORE the first unrecoverable frame, so the very first frozen-frame
/// episode already runs the halved clock. The defaults keep a lone baseline ~1% loss on the
/// conservative clock.
#[derive(Debug, Clone, PartialEq)]
pub struct LossObservationWindow {
    window_seconds: f64,
    min_events: usize,
    capacity: usize,
    /// Event timestamps in the caller's monotonic clock, newest last.
    events: Vec<f64>,
}

impl Default for LossObservationWindow {
    fn default() -> Self {
        Self::new(1.0, 2, 8)
    }
}

impl LossObservationWindow {
    /// Builds a window. `min_events` and `capacity` are floored at 1.
    #[must_use]
    pub const fn new(window_seconds: f64, min_events: usize, capacity: usize) -> Self {
        Self {
            window_seconds,
            min_events: floor_at_one(min_events),
            capacity: floor_at_one(capacity),
            events: Vec::new(),
        }
    }

    /// The events currently held, oldest first.
    #[must_use]
    pub fn events(&self) -> &[f64] {
        &self.events
    }

    /// Records one loss-ish event. Prunes events older than the window, and drops oldest at
    /// capacity, so the window stays bounded whatever the feed rate.
    pub fn note_event(&mut self, now: f64) {
        // Push first so the ring owns the spare slot the law writes `now` into, then cut back to
        // what the law kept. The law itself lives in `note_in_place` — a caller holding its own
        // ring runs the same code this does, rather than a second copy of it.
        self.events.push(now);
        let held = self.events.len().saturating_sub(1);
        let live = note_in_place(self.window_seconds, self.capacity, &mut self.events, held, now);
        self.events.truncate(live);
    }

    /// Whether at least `min_events` events lie within the window of `now`. A pure read: it does
    /// not prune, because a stale entry simply fails the recency test.
    #[must_use]
    pub fn is_observing_loss(&self, now: f64) -> bool {
        is_observing_loss(self.window_seconds, self.min_events, &self.events, now)
    }
}

/// The pruning law, applied to a ring a caller owns — no window, no allocation.
///
/// `ring` holds `count` timestamps oldest-first and must have one slot spare for the event being
/// recorded; a `ring` too short for that is left untouched and answers `count + 1`, the length it
/// would need, exactly as the `(out, cap)` convention does. Otherwise: events older than
/// `window_seconds` go, the oldest go while the ring is at `capacity`, `now` lands last, and the
/// new length comes back.
///
/// [`LossObservationWindow::note_event`] is this function over its own `Vec`, which is what keeps
/// a ring carried across an FFI boundary from being pruned by a second, drifting copy of the rule.
#[must_use]
pub fn note_in_place(
    window_seconds: f64,
    capacity: usize,
    ring: &mut [f64],
    count: usize,
    now: f64,
) -> usize {
    let capacity = floor_at_one(capacity);
    let held = count.min(ring.len());
    if ring.len() <= held {
        return held.saturating_add(1);
    }
    // Compact what is still inside the window forward over what is not: one pass, in place, where
    // `retain` + repeated `remove(0)` was a shift per dropped event.
    let mut live = 0;
    for slot in 0..held {
        let event = ring.get(slot).copied().unwrap_or(f64::NAN);
        if now - event <= window_seconds {
            if let Some(cell) = ring.get_mut(live) {
                *cell = event;
            }
            live += 1;
        }
    }
    let overflow = live.saturating_sub(capacity.saturating_sub(1));
    ring.copy_within(overflow..live, 0);
    live -= overflow;
    if let Some(cell) = ring.get_mut(live) {
        *cell = now;
    }
    live.saturating_add(1)
}

/// The observing predicate over a ring a caller owns. The capacity does not enter a read: it only
/// ever bounds what [`note_in_place`] keeps.
#[must_use]
pub fn is_observing_loss(window_seconds: f64, min_events: usize, ring: &[f64], now: f64) -> bool {
    ring.iter()
        .filter(|event| now - *event <= window_seconds && now - *event >= 0.0)
        .count()
        >= floor_at_one(min_events)
}

/// The floor both the window's constructor and the free laws apply, written once.
const fn floor_at_one(value: usize) -> usize {
    if value < 1 { 1 } else { value }
}

/// The clock a client's forced-IDR escalation is measured against, and the loss it is measured for.
///
/// Loss is detected once per dropped frame, so re-anchoring on EVERY detection never reaches the
/// escalation deadline under sustained loss: the guaranteed-recovery IDR would never fire and the
/// stream could starve forever. Hence the clock is the time of the FIRST request of the current
/// episode — armed only on ENTERING recovery, never re-armed by a later loss, and cleared either by
/// a decoded keyframe or by a frame proving the chain re-anchored on its own.
///
/// ## Why a decoded keyframe cannot be the only way out
/// The LTR-refresh recovery frame, and every self-heal cadence refresh, is a plain P-frame on the
/// wire. A recovery that SUCCEEDED via refresh would leave the episode armed and fire a spurious
/// IDR — LTR recovery saving no IDR at all. A delta referencing a lost frame cannot decode, so any
/// frame strictly NEWER than every recorded loss decoding successfully proves the re-anchor,
/// keyframe or not.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LtrEscalationTracker {
    /// When the current episode's FIRST request went out, or `None` when none is outstanding.
    first_request_time: Option<f64>,
    /// The NEWEST (wrap-aware) frame id declared unrecoverably lost this episode.
    ///
    /// `None` when no loss was attributed — an IDR request from a hard decode failure arms the
    /// episode with no frame id, and then only a keyframe can clear it.
    max_lost_frame_id: Option<u32>,
}

impl LtrEscalationTracker {
    /// A tracker with no episode outstanding.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            first_request_time: None,
            max_lost_frame_id: None,
        }
    }

    /// When the current episode's first request went out.
    #[must_use]
    pub const fn first_request_time(&self) -> Option<f64> {
        self.first_request_time
    }

    /// The newest frame id attributed to the current episode.
    #[must_use]
    pub const fn max_lost_frame_id(&self) -> Option<u32> {
        self.max_lost_frame_id
    }

    /// Whether a recovery episode is outstanding.
    #[must_use]
    pub const fn has_outstanding_request(&self) -> bool {
        self.first_request_time.is_some()
    }

    /// Records one unrecoverably-lost frame, wrap-aware keep-newest. Called by the loss-detection
    /// path BEFORE the request goes out.
    pub const fn note_loss(&mut self, frame_id: u32) {
        if let Some(current) = self.max_lost_frame_id
            && distance_wrapped(frame_id, current) <= 0
        {
            return;
        }
        self.max_lost_frame_id = Some(frame_id);
    }

    /// A NON-keyframe decoded. Ends the episode iff it is strictly newer than every recorded loss
    /// AND a loss was actually attributed. Answers whether the episode was cleared.
    pub fn frame_decoded(&mut self, frame_id: u32) -> bool {
        let cleared = self.first_request_time.is_some()
            && self
                .max_lost_frame_id
                .is_some_and(|lost| distance_wrapped(frame_id, lost) > 0);
        if cleared {
            self.first_request_time = None;
            self.max_lost_frame_id = None;
        }
        cleared
    }

    /// Records that a recovery request is going out at `now`, arming the clock ONLY when entering
    /// recovery. A request sent while one is already outstanding must not move the clock.
    pub const fn note_request_sent(&mut self, now: f64) {
        if self.first_request_time.is_none() {
            self.first_request_time = Some(now);
        }
    }

    /// Whether to escalate to a forced IDR right now. Pure — the caller decides whether to act.
    #[must_use]
    pub fn should_escalate(&self, now: f64, rtt: f64, policy: &RecoveryPolicy, observing_loss: bool) -> bool {
        self.first_request_time
            .is_some_and(|first| policy.should_escalate_to_idr(now - first, rtt, observing_loss))
    }

    /// A keyframe decoded — the episode is over unconditionally, because a keyframe references
    /// nothing. The next loss starts a fresh one.
    pub const fn keyframe_decoded(&mut self) {
        self.first_request_time = None;
        self.max_lost_frame_id = None;
    }

    /// Re-anchors the clock AFTER a forced-IDR escalation actually fired, so the next escalation is
    /// gated to one per deadline rather than one per subsequent dropped frame.
    ///
    /// DISTINCT from [`Self::note_request_sent`]: an ordinary request must not move the clock, or
    /// the deadline never elapses at all. Only a fired escalation re-arms it.
    pub const fn note_escalated(&mut self, now: f64) {
        self.first_request_time = Some(now);
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::float_cmp,
        clippy::panic,
        reason = "a panic in a test is the failure report, and these floats are exact constants"
    )]

    use super::{
        DEFAULT_LOSSY_ESCALATION_FLOOR_SECONDS, LossObservationWindow, MAX_NACK_FRAGMENTS,
        NO_FRAME_DECODED_SENTINEL, NetworkStatsReport, RecoveryMessage, RecoveryPolicy,
        RecoveryRequestRedundancy, escalation_floor_seconds,
    };
    use crate::error::VideoProtocolError;

    fn round_trip(message: &RecoveryMessage) {
        let bytes = message.encode();
        assert_eq!(RecoveryMessage::decode(&bytes).as_ref(), Ok(message));
    }

    #[test]
    fn every_variant_round_trips() {
        round_trip(&RecoveryMessage::Ack { stream_seq: 123 });
        round_trip(&RecoveryMessage::RequestLtrRefresh {
            from_frame_id: 10,
            to_frame_id: 12,
            last_decoded_frame_id: NO_FRAME_DECODED_SENTINEL,
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
            owd_trend_milli: 0xFFFF_FB2E,
            owd_trend_flags: 0x0000_FF01,
            pacer_late_frames: 4,
            pacer_present_gaps: 6,
            pacer_depth: 2,
        }));
        round_trip(&RecoveryMessage::RequestFragments {
            frame_id: 0x0102_0304,
            frag_indices: vec![5, 10],
        });
    }

    #[test]
    fn the_type_bytes_are_dense_and_unique_from_one_to_six() {
        let types: Vec<u8> = [
            RecoveryMessage::Ack { stream_seq: 0 },
            RecoveryMessage::RequestLtrRefresh {
                from_frame_id: 0,
                to_frame_id: 0,
                last_decoded_frame_id: 0,
            },
            RecoveryMessage::RequestIdr {
                last_decoded_frame_id: 0,
            },
            RecoveryMessage::RequestCursorShape { shape_id: 0 },
            RecoveryMessage::NetworkStats(NetworkStatsReport::default()),
            RecoveryMessage::RequestFragments {
                frame_id: 0,
                frag_indices: Vec::new(),
            },
        ]
        .iter()
        .map(RecoveryMessage::message_type)
        .collect();
        assert_eq!(types, vec![1, 2, 3, 4, 5, 6]);
    }

    #[test]
    fn a_trailing_byte_is_rejected_on_every_variant() {
        // Load-bearing: the host's deduper keys on RAW bytes, so a tolerated suffix would let
        // suffix-varied copies of one request each bypass the dedup and trigger a second refresh.
        for message in [
            RecoveryMessage::Ack { stream_seq: 1 },
            RecoveryMessage::RequestIdr {
                last_decoded_frame_id: 1,
            },
            RecoveryMessage::RequestCursorShape { shape_id: 1 },
            RecoveryMessage::RequestFragments {
                frame_id: 1,
                frag_indices: vec![7],
            },
        ] {
            let mut bytes = message.encode();
            bytes.push(0);
            assert!(
                matches!(
                    RecoveryMessage::decode(&bytes),
                    Err(VideoProtocolError::Malformed(_))
                ),
                "a suffix on {message:?} must not decode"
            );
        }
    }

    #[test]
    fn a_short_body_is_truncation_and_an_unknown_type_is_malformed() {
        assert_eq!(
            RecoveryMessage::decode(&[1, 0, 0]),
            Err(VideoProtocolError::Truncated)
        );
        assert_eq!(RecoveryMessage::decode(&[]), Err(VideoProtocolError::Truncated));
        assert!(matches!(
            RecoveryMessage::decode(&[99]),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn a_nack_count_past_the_cap_is_rejected_before_any_index_is_read() {
        // The count is peer-supplied, so it is checked against the cap BEFORE the read loop and
        // without reserving anything for it.
        let mut bytes = vec![6, 0, 0, 0, 1];
        #[expect(clippy::cast_possible_truncation, reason = "the cap is 64")]
        let over = MAX_NACK_FRAGMENTS as u16 + 1;
        bytes.extend_from_slice(&over.to_be_bytes());
        assert!(matches!(
            RecoveryMessage::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn a_nack_whose_count_outruns_its_body_is_truncation_not_a_short_list() {
        let mut bytes = vec![6, 0, 0, 0, 1, 0, 4];
        bytes.extend_from_slice(&7_u16.to_be_bytes()); // one index where four were promised
        assert_eq!(
            RecoveryMessage::decode(&bytes),
            Err(VideoProtocolError::Truncated)
        );
    }

    #[test]
    fn an_empty_nack_list_is_legal() {
        round_trip(&RecoveryMessage::RequestFragments {
            frame_id: 7,
            frag_indices: Vec::new(),
        });
    }

    #[test]
    fn the_encoder_caps_an_overlong_nack_list() {
        let message = RecoveryMessage::RequestFragments {
            frame_id: 1,
            frag_indices: (0..200).collect(),
        };
        let decoded = RecoveryMessage::decode(&message.encode()).expect("the cap keeps it legal");
        let RecoveryMessage::RequestFragments { frag_indices, .. } = decoded else {
            panic!("the variant must survive the round trip");
        };
        assert_eq!(frag_indices.len(), MAX_NACK_FRAGMENTS);
    }

    #[test]
    fn the_stats_flag_accessors_read_the_documented_bit_ranges() {
        let report = NetworkStatsReport {
            owd_trend_flags: 0x0000_FF01,
            owd_trend_milli: 0xFFFF_FB2E,
            ..NetworkStatsReport::default()
        };
        assert_eq!(report.owd_trend_state_raw(), 1, "bits 0-1 are the state");
        assert_eq!(report.owd_trend_deltas(), 255, "bits 8-15 are the sample count");
        assert_eq!(
            report.owd_trend_modified_milli_signed(),
            -1234,
            "the trend field is an i32 the wire spells as a u32"
        );
    }

    #[test]
    fn the_normal_escalation_clock_has_no_floor_and_the_lossy_one_does() {
        let policy = RecoveryPolicy::default();
        // Normal: exactly 2·RTT, however small the RTT.
        assert!(!policy.should_escalate_to_idr(0.019, 0.01, false));
        assert!(policy.should_escalate_to_idr(0.02, 0.01, false));
        // Lossy at the same 10 ms RTT: the 60 ms floor dominates 1·RTT and 1.5·RTT both.
        assert!(!policy.should_escalate_to_idr(0.059, 0.01, true));
        assert!(policy.should_escalate_to_idr(0.06, 0.01, true));
    }

    #[test]
    fn the_lossy_floor_tracks_the_path_once_rtt_dominates() {
        let policy = RecoveryPolicy::default();
        // At 100 ms RTT the 1.5·RTT term is 150 ms, well past the 60 ms constant.
        assert!(!policy.should_escalate_to_idr(0.14, 0.1, true));
        assert!(policy.should_escalate_to_idr(0.16, 0.1, true));
        // And the halved clock still escalates SOONER than the normal one, which is its point.
        assert!(!policy.should_escalate_to_idr(0.16, 0.1, false));
        assert!(policy.should_escalate_to_idr(0.21, 0.1, false));
    }

    #[test]
    fn the_initial_request_is_always_a_refresh_never_an_idr() {
        assert_eq!(
            RecoveryPolicy::initial_request(4, 6, 3),
            RecoveryMessage::RequestLtrRefresh {
                from_frame_id: 4,
                to_frame_id: 6,
                last_decoded_frame_id: 3,
            }
        );
    }

    #[test]
    fn the_escalation_floor_keeps_the_default_for_anything_out_of_band() {
        assert_eq!(escalation_floor_seconds(Some("120")), 0.12);
        assert_eq!(escalation_floor_seconds(Some("20")), 0.02);
        assert_eq!(escalation_floor_seconds(Some("500")), 0.5);
        for raw in [None, Some("nonsense"), Some("19"), Some("501"), Some("nan")] {
            assert_eq!(
                escalation_floor_seconds(raw),
                DEFAULT_LOSSY_ESCALATION_FLOOR_SECONDS,
                "{raw:?} must not move the floor"
            );
        }
    }

    #[test]
    fn the_redundancy_spread_stays_inside_half_the_dedup_window() {
        // The coupling invariant, as an assertion rather than a comment: a copy that aged past the
        // host's 25 ms dedup window would re-admit as a SECOND ForceLTRRefresh for one loss.
        const DEDUP_WINDOW: f64 = 0.025;
        let default = RecoveryRequestRedundancy::default();
        for copies in 1..=RecoveryRequestRedundancy::MAX_COPIES {
            let plan = RecoveryRequestRedundancy::new(copies, default.spacing());
            #[expect(clippy::cast_precision_loss, reason = "the count is at most 5")]
            let spread = (plan.copies() - 1) as f64 * plan.spacing();
            assert!(
                spread <= DEDUP_WINDOW / 2.0,
                "{copies} copies spread {spread}s, past half the dedup window"
            );
        }
    }

    #[test]
    fn the_copy_count_is_clamped_and_the_offsets_start_at_zero() {
        assert_eq!(RecoveryRequestRedundancy::new(0, 0.003).copies(), 1);
        assert_eq!(RecoveryRequestRedundancy::new(99, 0.003).copies(), 5);
        assert_eq!(RecoveryRequestRedundancy::new(3, 0.003).send_offsets(), vec![
            0.0, 0.003, 0.006
        ]);
    }

    #[test]
    fn redundancy_turns_a_loss_rate_into_a_freeze_budget() {
        // One copy at 10% loss freezes a tenth of the escalation delay; three copies, a thousandth.
        assert_eq!(
            RecoveryRequestRedundancy::all_copies_lost_probability(0.1, 1),
            0.1
        );
        let three = RecoveryRequestRedundancy::expected_request_loss_freeze(0.1, 3, 0.1);
        assert!(three < 0.0002, "three copies make request loss a rounding error");
        // A loss rate outside [0, 1] is clamped rather than believed.
        assert_eq!(
            RecoveryRequestRedundancy::all_copies_lost_probability(5.0, 2),
            1.0
        );
        assert_eq!(
            RecoveryRequestRedundancy::all_copies_lost_probability(-5.0, 2),
            0.0
        );
    }

    #[test]
    fn the_loss_window_needs_two_events_inside_one_second() {
        let mut window = LossObservationWindow::default();
        assert!(!window.is_observing_loss(0.0), "an empty window observes nothing");
        window.note_event(0.0);
        assert!(
            !window.is_observing_loss(0.1),
            "one event is a lone baseline blip"
        );
        window.note_event(0.5);
        assert!(window.is_observing_loss(0.6), "two inside the window is loss");
        assert!(
            !window.is_observing_loss(2.0),
            "and both age out rather than latching the halved clock forever"
        );
    }

    #[test]
    fn the_loss_window_stays_bounded_however_fast_it_is_fed() {
        let mut window = LossObservationWindow::new(1.0, 2, 4);
        for step in 0..1000 {
            window.note_event(f64::from(step) * 0.0001);
        }
        assert!(window.is_observing_loss(0.1));
        // The bound is the point: a feed rate the client cannot control must not grow the ring.
        assert_eq!(window.events.len(), 4);
    }
}

#[cfg(test)]
mod escalation_tests {
    use super::{LtrEscalationTracker, RecoveryPolicy};

    /// 50 ms, so the plain deadline is 100 ms and the lossy one is `max(1·RTT, 60 ms, 1.5·RTT)` =
    /// 75 ms — strictly under it, which is what makes the two clocks separable in one test.
    const RTT: f64 = 0.05;

    /// The escalation is a clock, and a clock that was never started cannot ring.
    #[test]
    fn nothing_escalates_before_the_first_request() {
        let tracker = LtrEscalationTracker::new();
        assert!(!tracker.has_outstanding_request());
        assert!(!tracker.should_escalate(100.0, RTT, &RecoveryPolicy::default(), false));
    }

    /// THE defect this type exists for: repeated losses each send a request, and the clock stays
    /// pinned to the FIRST one. Re-anchoring per loss meant the deadline was never reached and the
    /// guaranteed-recovery IDR never fired at all.
    #[test]
    fn the_clock_stays_on_the_first_request_through_sustained_loss() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert!(tracker.has_outstanding_request());
        assert_eq!(tracker.first_request_time(), Some(0.0));

        for step in 1..=9_u32 {
            let now = f64::from(step) / 100.0;
            tracker.note_request_sent(now);
            assert_eq!(tracker.first_request_time(), Some(0.0));
            assert!(
                !tracker.should_escalate(now, RTT, &policy, false),
                "must not escalate at {now}s, inside the deadline measured from the first request"
            );
        }
        assert!(tracker.should_escalate(0.10, RTT, &policy, false));
    }

    /// A decoded keyframe ends the episode outright, and the next loss opens a fresh window from
    /// its own first request rather than inheriting the closed one's clock.
    #[test]
    fn a_decoded_keyframe_closes_the_episode_and_the_next_one_starts_clean() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert!(tracker.should_escalate(0.10, RTT, &policy, false));

        tracker.keyframe_decoded();
        assert!(!tracker.has_outstanding_request());
        assert_eq!(tracker.first_request_time(), None);
        assert!(!tracker.should_escalate(0.50, RTT, &policy, false));

        tracker.note_request_sent(1.0);
        assert_eq!(tracker.first_request_time(), Some(1.0));
        assert!(!tracker.should_escalate(1.05, RTT, &policy, false));
        assert!(tracker.should_escalate(1.10, RTT, &policy, false));
    }

    /// The forced IDR request the escalation itself sends goes through the same door as an
    /// ordinary one, so that door must not move the clock either.
    #[test]
    fn a_forced_idr_request_does_not_move_the_clock() {
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        tracker.note_request_sent(0.10);
        assert_eq!(tracker.first_request_time(), Some(0.0));
    }

    /// Once an escalation FIRES the drain loop re-anchors, and a second one waits a full deadline.
    /// Without the re-anchor every subsequent dropped frame in the episode resent a `requestIdr`.
    #[test]
    fn a_fired_escalation_coalesces_the_ones_behind_it() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert!(tracker.should_escalate(0.10, RTT, &policy, false));

        tracker.note_escalated(0.10);
        assert_eq!(tracker.first_request_time(), Some(0.10));
        assert!(!tracker.should_escalate(0.11, RTT, &policy, false));
        assert!(!tracker.should_escalate(0.19, RTT, &policy, false));
        assert!(tracker.should_escalate(0.20, RTT, &policy, false));
    }

    /// The re-anchor must not wedge the clock armed: a keyframe after an escalation still ends it.
    #[test]
    fn a_keyframe_after_an_escalation_still_closes_the_episode() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert!(tracker.should_escalate(0.10, RTT, &policy, false));
        tracker.note_escalated(0.10);
        tracker.keyframe_decoded();
        assert!(!tracker.has_outstanding_request());
        assert_eq!(tracker.first_request_time(), None);
        assert!(!tracker.should_escalate(1.0, RTT, &policy, false));
    }

    /// The self-heal: the LTR-refresh recovery frame is a plain P-frame, so clearing only on a
    /// keyframe fired a spurious IDR after every SUCCESSFUL refresh. A frame strictly newer than
    /// the loss decoding proves the chain re-anchored; equal or older proves nothing.
    #[test]
    fn a_frame_newer_than_the_loss_heals_the_episode() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_loss(100);
        tracker.note_request_sent(0.0);
        assert!(tracker.has_outstanding_request());

        assert!(!tracker.frame_decoded(99), "an older frame proves nothing");
        assert!(tracker.has_outstanding_request());
        assert!(!tracker.frame_decoded(100), "the boundary itself proves nothing");
        assert!(tracker.has_outstanding_request());

        assert!(tracker.frame_decoded(101));
        assert!(!tracker.has_outstanding_request());
        assert_eq!(tracker.max_lost_frame_id(), None);
        assert!(!tracker.should_escalate(1.0, RTT, &policy, false));
    }

    /// With several losses in one episode the boundary is the NEWEST, and an out-of-order report
    /// of an older one does not walk it backwards.
    #[test]
    fn the_boundary_is_the_newest_loss_however_they_arrive() {
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_loss(100);
        tracker.note_request_sent(0.0);
        tracker.note_loss(140);
        tracker.note_request_sent(0.01);
        tracker.note_loss(120);
        assert_eq!(tracker.max_lost_frame_id(), Some(140));

        assert!(
            !tracker.frame_decoded(130),
            "between losses, the chain is not proven past 140"
        );
        assert!(tracker.has_outstanding_request());
        assert!(tracker.frame_decoded(141));
        assert!(!tracker.has_outstanding_request());
    }

    /// An episode armed by a hard decode failure carries no frame id, and the decoder session it
    /// invalidated is reconfigured only by an IDR — so a delta decode must be inert against it.
    #[test]
    fn an_episode_with_no_attributed_loss_yields_only_to_a_keyframe() {
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert_eq!(tracker.max_lost_frame_id(), None);
        assert!(!tracker.frame_decoded(5000));
        assert!(tracker.has_outstanding_request());
        tracker.keyframe_decoded();
        assert!(!tracker.has_outstanding_request());
    }

    /// The frame-id space wraps, and the heal comparison is the reassembler's own wrap-aware one.
    #[test]
    fn a_post_wrap_frame_heals_a_loss_from_before_the_wrap() {
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_loss(u32::MAX - 1);
        tracker.note_request_sent(0.0);
        assert!(
            !tracker.frame_decoded(u32::MAX - 2),
            "older across the wrap proves nothing"
        );
        assert!(tracker.frame_decoded(2), "a post-wrap frame is newer, and heals");
        assert!(!tracker.has_outstanding_request());
    }

    /// While observing loss the halved clock fires at its floor, and the same instant without the
    /// loss signal still waits the full deadline. The samples sit off the exact 75 ms boundary
    /// because 1.5 × 0.05 is not exact in binary.
    #[test]
    fn observing_loss_escalates_at_the_lossy_deadline_and_only_then() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert!(!tracker.should_escalate(0.0749, RTT, &policy, true));
        assert!(tracker.should_escalate(0.0751, RTT, &policy, true));
        assert!(
            !tracker.should_escalate(0.0751, RTT, &policy, false),
            "the plain clock is still the full deadline at that instant"
        );
    }

    /// No outstanding request never escalates, lossy or not.
    #[test]
    fn observing_loss_without_a_request_never_escalates() {
        let tracker = LtrEscalationTracker::new();
        assert!(!tracker.should_escalate(100.0, RTT, &RecoveryPolicy::default(), true));
    }

    /// The halved clock must not reopen the per-dropped-frame storm the re-anchor exists to close.
    #[test]
    fn the_lossy_clock_coalesces_after_a_re_anchor_too() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert!(tracker.should_escalate(0.0751, RTT, &policy, true));
        tracker.note_escalated(0.0751);
        assert!(!tracker.should_escalate(0.085, RTT, &policy, true));
        assert!(!tracker.should_escalate(0.149, RTT, &policy, true));
        assert!(tracker.should_escalate(0.1503, RTT, &policy, true));
    }

    /// The 60 ms floor flows through the tracker: at a 10 ms round trip a lossy escalation still
    /// waits 60 ms, because a refresh physically cannot arrive faster.
    #[test]
    fn the_lossy_floor_holds_at_a_short_round_trip() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        assert!(!tracker.should_escalate(0.010, 0.01, &policy, true));
        assert!(!tracker.should_escalate(0.059, 0.01, &policy, true));
        assert!(tracker.should_escalate(0.060, 0.01, &policy, true));
    }

    /// The measured-defect pin: at the live path's 20 ms round trip the halved deadline never
    /// drops under 60 ms. The old 30 ms floor measured 202 IDR requests against 100 refreshes.
    #[test]
    fn the_lossy_deadline_never_drops_below_the_floor_in_the_live_band() {
        let policy = RecoveryPolicy::default();
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_request_sent(0.0);
        for step in 0..60_u32 {
            let now = f64::from(step) / 1000.0;
            assert!(
                !tracker.should_escalate(now, 0.02, &policy, true),
                "must not escalate at {step} ms, under the floor"
            );
        }
        assert!(tracker.should_escalate(0.060, 0.02, &policy, true));
    }

    /// A keyframe clears the loss boundary too, so a stale one can never leak into the episode
    /// after it and heal something it has no evidence for.
    #[test]
    fn a_keyframe_clears_the_loss_boundary_as_well_as_the_clock() {
        let mut tracker = LtrEscalationTracker::new();
        tracker.note_loss(100);
        tracker.note_request_sent(0.0);
        tracker.keyframe_decoded();
        assert_eq!(tracker.max_lost_frame_id(), None);

        tracker.note_request_sent(1.0);
        assert!(!tracker.frame_decoded(101));
        assert!(tracker.has_outstanding_request());
    }
}
