//! The session's OWN state, split out from the orchestration that drives it.
//!
//! The Swift host session's stored properties — the half of that 3728-line actor that was fields
//! rather than behaviour.
//!
//! ## Why this is a file of its own
//! The Swift actor's fields and its methods were one type because an actor has to be: `private var`
//! meant "actor-isolated", and isolation was the only lock it had. A Rust port has real locks, and
//! the moment it does, the fields split into three groups that do NOT want the same one:
//!
//! * the CONTROLLERS — the congestion controller, the QP ladder, the FPS governor, the LTR
//!   bookkeeping, the recovery-IDR admission, the folded network estimate. Every one is a pure
//!   value type in [`slopdesk_video`], every one is touched only from the report-fold path and the
//!   encoded-frame path, and they move together. They are [`Controllers`].
//! * the LIVE COMPONENTS — the capturer, the encoder, the geometry watcher, the cursor sampler, the
//!   injector. These are framework objects with lifetimes, they are swapped as a SET at every
//!   rebuild, and every rebuild path guards on their IDENTITY. They are [`Live`].
//! * the WIRE COUNTERS — the send stamps, the frame count, the dup throttles. Small, hot, and read
//!   from the encoded-frame path alone.
//!
//! The Swift could not say that, so it said `private var` forty times and relied on one actor to
//! serialise all three. Saying it here is what lets the encoded-frame path take the controller lock
//! without also excluding a resize that is rebuilding the capture stream.
//!
//! ## What this file does NOT hold
//! Any decision. Every field below is either a [`slopdesk_video`] value type that decides for
//! itself, or a counter whose only rule is "monotonic". If something here starts to look like a
//! policy, it belongs in `slopdesk-video` where a test can reach it without a window server.

use std::sync::Arc;

use slopdesk_video::adaptive_fec::TierState;
use slopdesk_video::congestion::{CongestionConfig, LiveCongestionController};
use slopdesk_video::fps_governor::{FpsGovernor, FpsGovernorConfig};
use slopdesk_video::host_gates::HostGates;
use slopdesk_video::ltr::LtrController;
use slopdesk_video::network_estimate::NetworkEstimate;
use slopdesk_video::qp_control::{QpConfig, QpController};
use slopdesk_video::recovery_idr::{RecoveryIdrConfig, RecoveryIdrPolicy};

/// The measured state every per-report controller folds into, as ONE lockable group.
///
/// Grouped rather than held apart because the report path touches all of them in one pass and in a
/// fixed order — fold the estimate, step the FEC ladder, tick the ABR, tick the QP ladder, tick the
/// governor — and a lock per controller would be five acquisitions for one report with no
/// concurrency to show for it. The Swift's actor isolation gave exactly this grouping by accident;
/// here it is the declared shape.
#[derive(Debug)]
pub struct Controllers {
    /// The folded view of the link: smoothed RTT, loss EWMA, one-way-delay trend.
    ///
    /// Written only by the report fold, read by every controller under this same lock, which is why
    /// none of them has to be told what the others saw.
    pub estimate: NetworkEstimate,
    /// The AIMD bitrate controller, or `None` when ABR is off or no encoder has been built.
    ///
    /// `Option` rather than a disabled controller because the Swift distinguished them and the
    /// distinction is real: "off" means never seeded and never ticked, so the live rate stays
    /// pinned at the resolution-aware ceiling, and a controller that existed but declined to move
    /// would still have to be asked once per report.
    pub congestion: Option<LiveCongestionController>,
    /// The constant-quantiser link-AIMD, or `None` unless const-QP mode is on.
    ///
    /// Rides the ABR's tick and reuses its congestion VERDICT rather than deriving a second one —
    /// under const-QP that verdict is exactly what drives Q, and two detectors that disagreed would
    /// be a stream that coarsened and sharpened against itself.
    pub qp: Option<QpController>,
    /// The cadence governor, or `None` when it is off.
    ///
    /// Seeded at the INITIAL encoder build only, and deliberately NOT re-seeded at a resize: the
    /// governor holds knowledge about the PATH, which a change of capture geometry does not
    /// invalidate. The capturer and encoder latches are re-applied at every install site instead.
    pub fps: Option<FpsGovernor>,
    /// The long-term-reference bookkeeping: frame id to ack token, and the bounded acked set.
    ///
    /// Reset at every encoder build AND at every encoded keyframe. The second is the one that is
    /// easy to miss and expensive to get wrong: an IDR clears the decoder's whole reference world
    /// by HEVC spec, long-term references included, so every token acked before it names a
    /// reference the client no longer holds.
    pub ltr: LtrController,
    /// The delivery-keyed recovery-IDR admission: sent-keyframe ring, decode-acked id, token
    /// bucket.
    ///
    /// Deliberately NOT reset on an encoder rebuild. The packetize lane — and so the frame id space
    /// — outlives every rebuild, so the ring and the delivered id stay valid; and the token bucket
    /// MUST survive one, or a resize storm during loss would refill the recovery budget it exists
    /// to bound.
    pub recovery_idr: RecoveryIdrPolicy,
    /// The last bitrate actually pushed to the encoder.
    ///
    /// The throttle's memory, and the adaptive pacer's input. The controller's `current` advances
    /// every tick; actuation compares against THIS, so only a material move reaches the framework.
    /// Seeded to the real resolution-aware ceiling at every encoder build — even when ABR is off —
    /// because the send pacer reads it, and a pacer reading the 12 Mbps fallback instead of the
    /// true ceiling serialises heavy frames at four times the gap.
    pub last_actuated_bps: i64,
    /// The resolution-aware policy ceiling of the CURRENT encoder build.
    ///
    /// The ABR-off baseline a user bitrate ceiling clamps against. With ABR on the controller's own
    /// effective ceiling rules instead, which is why this is not simply read everywhere.
    pub policy_ceiling_bps: i64,
    /// An EWMA of encoded DELTA-frame bytes, tracked independently of the FPS governor.
    ///
    /// The ABR's idle-ramp guard: offered load is this times eight times the effective cadence, and
    /// the controller suppresses its additive probe while the stream is application-limited. Kept
    /// separately from the governor's own EWMA because the governor is usually OFF and this signal
    /// must be available at every ABR tick regardless. Zero until the first delta frame, which the
    /// reader spells as "no gate yet" rather than as "no load".
    pub offered_bytes_per_frame: f64,
    /// The adaptive-FEC tier the wire is currently stamped with, and its dwell bookkeeping.
    ///
    /// Here rather than in the packetize lane because it is STEPPED by the report fold — one step
    /// per feedback report, under this same lock, from the loss EWMA in `estimate` two fields up —
    /// and merely READ by the frame path. A copy in the lane would be a second answer that could
    /// disagree with the one the fold just computed, which is exactly what a receiver decoding
    /// against the stamped tier cannot survive.
    ///
    /// [`slopdesk_video::adaptive_fec::next_parity_tier_state`] is the step when adaptive `m` is
    /// on; [`slopdesk_video::adaptive_fec::next_tier_state`] otherwise. The default is
    /// [`slopdesk_video::adaptive_fec::DEFAULT_TIER`], which is also the value multi-loss forces.
    pub fec_tier: TierState,
}

/// EWMA smoothing for [`Controllers::offered_bytes_per_frame`]. The FPS governor's own constant,
/// shared so the two utilisation signals cannot drift into disagreeing about the same stream.
pub const OFFERED_EWMA_ALPHA: f64 = 0.125;

impl Controllers {
    /// The controller set a fresh session starts with, configured from the resolved gates.
    ///
    /// Every controller that is gated OFF is `None` rather than constructed-and-idle, so the report
    /// path's cost when a feature is off is a discriminant test, not a tick.
    #[must_use]
    pub fn new(recovery_idr: RecoveryIdrConfig) -> Self {
        Self {
            estimate: NetworkEstimate::default(),
            congestion: None,
            qp: None,
            fps: None,
            ltr: LtrController::new(),
            recovery_idr: RecoveryIdrPolicy::new(recovery_idr),
            last_actuated_bps: 0,
            policy_ceiling_bps: 0,
            offered_bytes_per_frame: 0.0,
            fec_tier: TierState::default(),
        }
    }

    /// Folds one encoded DELTA frame's size into the offered-load EWMA.
    ///
    /// Anchors are excluded by the CALLER, not here, because the caller is the only one that knows
    /// whether this frame was a keyframe or a crisp refresh — and folding them would let the 5–10×
    /// IDR outlier fake high utilisation for the several reports after every recovery, which is
    /// precisely when the controller must not suppress its probe.
    ///
    /// The multiply and the add are SEPARATE by rule: `a * b + c` fused into one rounding moves the
    /// bit patterns `golden/golden_vectors.json` pins.
    pub fn note_delta_bytes(&mut self, bytes: usize) {
        #[expect(
            clippy::cast_precision_loss,
            reason = "an encoded frame is kilobytes; f64 is exact far past any size a frame reaches"
        )]
        let observed = bytes as f64;
        self.offered_bytes_per_frame =
            self.offered_bytes_per_frame * (1.0 - OFFERED_EWMA_ALPHA) + observed * OFFERED_EWMA_ALPHA;
    }

    /// The offered throughput to hand the congestion controller, or `None` before the first delta.
    ///
    /// `None` is the warm-up answer and means "do not gate the probe", which is different from a
    /// zero — a zero would read as a fully idle stream and suppress the ramp for ever.
    #[must_use]
    pub fn offered_bps(&self, effective_fps: i64) -> Option<f64> {
        if self.offered_bytes_per_frame <= 0.0 {
            return None;
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "a frame rate is a small integer; the conversion is exact for every value on the ladder"
        )]
        let cadence = effective_fps as f64;
        Some(self.offered_bytes_per_frame * 8.0 * cadence)
    }

    /// Re-anchors the rate controllers to a freshly built encoder's resolution-aware ceiling.
    ///
    /// Called at EVERY encoder build — initial bring-up and both resize rebuild paths — because a
    /// controller left holding the OLD ceiling either starves the new resolution or overshoots it.
    ///
    /// The ORDER inside is load-bearing and cost a bug once. `last_actuated_bps` is seeded to the
    /// real ceiling BEFORE the ABR gate, not inside it, because the send pacer is its only other
    /// reader and the pacer must see the true ceiling even when ABR is off.
    ///
    /// Answers the target to actuate, or `None` when nothing changed. The caller actuates, because
    /// only the caller holds the encoder and only the caller knows whether const-QP has taken the
    /// rate over.
    #[expect(
        clippy::too_many_arguments,
        reason = "the seed is where six independent axes meet once; grouping them would name a \
                  configuration that exists for exactly this call"
    )]
    pub fn seed_for_encoder(
        &mut self,
        ceiling: i64,
        gates: &HostGates,
        congestion_config: CongestionConfig,
        gradient_cut: bool,
        qp_config: QpConfig,
        const_qp: Option<i32>,
        user_ceiling_bps: Option<i64>,
    ) -> Option<i64> {
        self.last_actuated_bps = ceiling;
        self.policy_ceiling_bps = ceiling;
        // Const-QP mode seeds the link-AIMD at the configured quantiser. It rides the ABR's tick,
        // so it is built here beside the controller it borrows a verdict from.
        self.qp = const_qp.map(|seed| QpController::new(qp_config, seed));
        if gates.abr_enabled {
            let mut controller =
                LiveCongestionController::with_ceiling(ceiling, congestion_config, gradient_cut);
            // A user ceiling survives an encoder rebuild: the client sends its settings once after
            // a hello and never again on a resize, so a live override has to be
            // re-layered here or a mid-session resize would silently discard it.
            controller.set_user_ceiling_bps(user_ceiling_bps);
            self.congestion = Some(controller);
        }
        let effective = self.congestion.as_ref().map_or_else(
            || ceiling.min(user_ceiling_bps.unwrap_or(ceiling)),
            LiveCongestionController::current,
        );
        if effective == self.last_actuated_bps {
            return None;
        }
        self.last_actuated_bps = effective;
        Some(effective)
    }

    /// Invalidates the long-term-reference state for a freshly installed encoder session.
    ///
    /// A new `VTCompressionSession` holds ZERO acknowledged long-term references. Without this the
    /// acked set — acked against the now-destroyed session — would keep answering "yes, refresh
    /// against a token", and the resulting `ForceLTRRefresh` would name a reference the rebuilt
    /// session never had. Only the framework's own contract would then stand between that and a
    /// corrupt stream.
    ///
    /// The CAPTURER's self-heal eligibility is deliberately not disarmed alongside this, and that
    /// is a structural difference from the Swift rather than an omission. The Swift kept ONE
    /// long-lived capturer across encoder rebuilds, so a rebuild had to clear a latch that would
    /// otherwise survive; here every rebuild mints a fresh [`crate::capture::Capturer`], whose
    /// latch starts disarmed by construction — the same reason the audio wish has to be
    /// re-asserted after a resize and this does not.
    ///
    /// [`Self::recovery_idr`] is deliberately untouched — see its own note.
    pub fn reset_ltr_for_new_encoder(&mut self) {
        self.ltr.reset();
    }
}

/// The FPS governor a fresh session starts with, or `None` when the gate is off.
///
/// A free function rather than a method because it is called at the INITIAL build only, and putting
/// it on [`Controllers`] beside [`Controllers::seed_for_encoder`] — which every build calls — would
/// invite the resize paths to call it too, which is the one thing the governor must not have.
#[must_use]
pub fn initial_governor(gates: &HostGates, base_fps: i64, config: FpsGovernorConfig) -> Option<FpsGovernor> {
    gates
        .fps_governor_enabled
        .then(|| FpsGovernor::new(base_fps, config))
}

/// The per-frame counters the encoded-frame path owns, and nothing else reads.
///
/// Split from [`Controllers`] because they are touched on EVERY frame while the controllers move
/// once per report — sixty times a second against twenty — and because none of them is a decision:
/// each is a stamp or a throttle whose only rule is monotonicity.
#[derive(Debug, Default, Clone, Copy)]
pub struct FrameCounters {
    /// How many frames this session has encoded and sent. Diagnostics only.
    pub encoded: u64,
    /// Uptime seconds of the last keyframe whose datagrams were duplicate-sent.
    ///
    /// The duplicate throttle's memory: at most one duplicated keyframe per interval, so a recovery
    /// IDR burst is not byte-amplified into the very congestion it is recovering from.
    pub last_keyframe_dup: f64,
    /// The duplicate fast-attack deadline in uptime seconds; zero means disarmed.
    ///
    /// The loss EWMA LAGS — it only moves when a report folds — so at a clean-to-burst edge the
    /// client's recovery request can reach the send path before the burst has folded into the rate.
    /// That first re-anchor IDR is the load-bearing case duplication exists for, so requesting a
    /// recovery keyframe arms this directly rather than waiting for the evidence to arrive.
    pub kf_dup_fast_attack_until: f64,
    /// The most recent frame-send start, for the send-gap probe. Debug builds only.
    pub last_send_at: f64,
}

impl FrameCounters {
    /// Arms the duplicate fast-attack window from `now`.
    ///
    /// Called wherever a RECOVERY keyframe is actually requested — never on the heartbeat path. On
    /// a clean link no recovery is ever requested, so this never arms and the periodic crisp IDR
    /// stays un-duplicated, which is the bandwidth this gate exists to save.
    pub fn arm_fast_attack(&mut self, now: f64, window: f64) {
        self.kf_dup_fast_attack_until = now + window;
    }
}

/// How long the duplicate fast-attack window stays open after a recovery keyframe is requested.
///
/// Comfortably covers the recovery IDR's next capture, its encode and its paced send even while the
/// loss rate still reads as zero; re-armed on each request through a sustained burst.
pub const KF_DUP_FAST_ATTACK_WINDOW: f64 = 0.5;

/// The minimum spacing between two duplicated keyframes.
pub const KF_DUP_MIN_INTERVAL: f64 = 0.25;

/// The client-silence liveness the heartbeat consults.
///
/// Three fields that are one idea, which is why they are a type rather than three loose members of
/// the session: a stamp, the proof the peer speaks feedback at all, and the latch. The pause is
/// DISTINCT from the idle reaper — it keeps the session streaming and advances no encoder
/// reference, so detach tolerance is unchanged and the reaper still reclaims a client that is
/// genuinely gone.
#[derive(Debug, Clone, Copy)]
pub struct ClientLiveness {
    /// Monotonic time of the most recent inbound datagram of ANY kind.
    ///
    /// Any kind, including an undecodable one: an arriving datagram proves the peer is back, and
    /// waiting to decode it before resuming video would add a decode to the resume path for no
    /// information.
    pub last_inbound: f64,
    /// Sticky-true once the client has sent a report.
    ///
    /// Proves a peer that speaks the feedback protocol, so the pause can never fire on a legacy
    /// client that never reports — the same never-act-without-evidence rule the idle reaper uses.
    pub saw_feedback: bool,
    /// Whether the pause is currently pushed to the capturer.
    ///
    /// Held so the one-second heartbeat re-pushes on a TRANSITION rather than on every tick.
    pub paused: bool,
}

impl ClientLiveness {
    /// A fresh liveness record, stamped now.
    ///
    /// Re-made at every capture start rather than carried, so a reused or reconnected session never
    /// inherits a stale silent stamp and pauses a capturer that has not had its first inbound yet.
    #[must_use]
    pub const fn starting_at(now: f64) -> Self {
        Self {
            last_inbound: now,
            saw_feedback: false,
            paused: false,
        }
    }

    /// Notes an inbound datagram; answers whether video must RESUME as a result.
    ///
    /// Answers rather than acts because the capturer is the caller's, and because a resume that
    /// happened inside a stamp update would be an effect hidden in a setter.
    pub const fn note_inbound(&mut self, now: f64) -> bool {
        self.last_inbound = now;
        let resuming = self.paused;
        self.paused = false;
        resuming
    }

    /// Whether video should PAUSE for client silence, per `slopdesk_video`'s rule.
    ///
    /// Disabled — a non-positive threshold — or an unproven client never pauses.
    #[must_use]
    pub fn should_pause(&self, now: f64, threshold: f64) -> bool {
        if threshold <= 0.0 || !self.saw_feedback {
            return false;
        }
        now - self.last_inbound >= threshold
    }
}

/// Everything a session needs to exist, gathered so the constructor takes ONE argument.
///
/// The Swift had two initialisers — one per target kind — differing in five defaulted parameters,
/// and the pair had already drifted: the display arm forgot the size override and the resize limit,
/// which was correct, and forgot to SAY it was correct. Here the target kind is a field with its
/// own documented arms, so the difference is data rather than a second function to keep in step.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SessionSpec {
    /// Which target this session remotes, and everything that follows from the choice.
    pub target: Target,
    /// Capture and encode at target points times this, in PIXELS.
    ///
    /// Two on a Retina window gives sharp text. Coordinates stay in POINTS on the wire, so this
    /// multiplier is display-only and never reaches the client's input mapping.
    pub capture_scale: f64,
    /// The live encoder's bitrate FLOOR, in bits per second.
    ///
    /// A floor and not a target: the real rate is resolution-aware, because a 2× window has four
    /// times the pixels and a rate cap that ignored that starves scroll frames into stutter.
    pub bitrate: i64,
    /// The capture and encode cadence cap, chosen by the caller per pane kind.
    ///
    /// A window pane runs the latency-first default; the full-desktop pane runs higher, because 30
    /// reads as visibly stepped across a whole desktop. The bitrate ceiling is provisioned from
    /// area times THIS, so the choice moves both.
    pub fps: i64,
}

/// What a session is pointed at. Exactly one of the two, which is why it is an enum and was two
/// nullable fields.
///
/// The Swift carried `window: SCWindow?` and `display: SCDisplay?` with "exactly one is set"
/// written in a comment, and then re-derived which one at fourteen call sites. Making it a sum type
/// deletes every one of those checks and the class of bug where a new path forgets one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Target {
    /// A single window: the classic per-pane session.
    Window {
        /// The window-server id being captured.
        id: u32,
        /// The owning process, for the accessibility raise and the bundle read.
        pid: i32,
        /// The daemon's AUTHORITATIVE post-move point size, when it parked the window on a virtual
        /// display.
        ///
        /// The achieved size, not the enumeration snapshot: a window resized DOWN to fit the
        /// display must be captured and acknowledged at its real new size, or the stream over-crops
        /// and the client's input-mapping denominator desynchronises. `None` means no move
        /// happened.
        size_override: Option<(f64, f64)>,
        /// The upper bound in POINTS for a client-driven resize, when parked.
        ///
        /// A resize past the virtual display's framebuffer pushes the capture crop off the display.
        /// `None` means unparked, and only the wire's own 16-bit limit applies.
        resize_limit: Option<(f64, f64)>,
    },
    /// A whole display: the full-desktop pane.
    ///
    /// The same wire, encode and input machinery minus every window-only piece — no parking, no
    /// geometry watcher, no raise. A display never moves and never resizes, and each of those
    /// absences is why a branch elsewhere is unreachable rather than merely unused.
    Display {
        /// The display id being captured.
        id: u32,
    },
}

impl Target {
    /// The window id, or `None` for a display target.
    #[must_use]
    pub const fn window_id(&self) -> Option<u32> {
        match *self {
            Self::Window { id, .. } => Some(id),
            Self::Display { .. } => None,
        }
    }

    /// The id to print in a diagnostic — a window id or a display id, whichever this is.
    #[must_use]
    pub const fn id(&self) -> u32 {
        match *self {
            Self::Window { id, .. } | Self::Display { id } => id,
        }
    }

    /// Whether this session holds the host display awake while it streams.
    ///
    /// Display targets only. The sleep timer does not count a remote viewer as activity, so a
    /// full-desktop session must say so; a window session must NOT, or every pane would pin the
    /// host's display awake for as long as it was open.
    #[must_use]
    pub const fn holds_display_wake(&self) -> bool {
        matches!(*self, Self::Display { .. })
    }
}

/// The pacing parameters for one frame, decided ONCE for whichever drain sends it.
///
/// This type exists because the two drains once computed them separately and the copies drifted:
/// the second had no `keyframe` to read, so it floored a recovery IDR at the DELTA pace floor and
/// serialised the one frame whose delivery time IS the client's recovery time. The gate meant to be
/// a byte-identical fallback was quietly the slower path. One value cannot drift from itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacePlan {
    /// The inter-chunk gap in nanoseconds; zero sends the whole frame in one shot.
    pub gap_nanos: u64,
    /// How many datagrams ride in one chunk.
    pub chunk_fragments: usize,
}

/// Frames with at most this many datagrams send in one shot, unpaced.
///
/// Covers the static-window P-frame and every small delta, so the typing path never pays a pacing
/// gap it does not need.
pub const PACE_CHUNK_FRAGMENTS: usize = 8;

/// The link-rate fallback when no ABR target is known yet.
pub const PACING_FALLBACK_BPS: i64 = 12_000_000;

/// The adaptive gap's floor: a high target would otherwise compute a gap of about zero.
pub const PACING_GAP_FLOOR_NANOS: u64 = 200_000;

/// The adaptive gap's ceiling: a target collapsed to its floor must not serialise one frame into a
/// multi-second stall.
pub const PACING_GAP_CEIL_NANOS: u64 = 40_000_000;

impl PacePlan {
    /// The plan for one frame, from the gates and the live rate.
    ///
    /// The keyframe distinction is the whole point of taking `keyframe` here: an IDR floors at the
    /// keyframe pace floor because its delivery time is the client's recovery time, and a delta
    /// floors at its own, which lifts a scroll-onset frame off a stale-low rate without un-pacing
    /// it. Both floors are `slopdesk_video`'s; this only asks.
    #[must_use]
    pub fn for_frame(gates: &HostGates, keyframe: bool, abr_bps: i64, datagram_size: usize) -> Self {
        if !gates.pace_send {
            return Self {
                gap_nanos: 0,
                chunk_fragments: PACE_CHUNK_FRAGMENTS,
            };
        }
        let target = if keyframe {
            abr_bps.max(gates.kf_pace_floor_bps)
        } else {
            abr_bps.max(gates.delta_pace_floor_bps)
        };
        let gap_nanos = if gates.pacing_adaptive {
            adaptive_gap_nanos(
                target,
                PACING_FALLBACK_BPS,
                PACE_CHUNK_FRAGMENTS,
                datagram_size,
                gates.pace_rate_multiplier,
            )
        } else {
            gates.pace_gap_nanos
        };
        Self {
            gap_nanos,
            chunk_fragments: PACE_CHUNK_FRAGMENTS,
        }
    }
}

/// The inter-chunk gap that drains `chunk × datagram` bytes at `target × multiplier`.
///
/// Clamped into the floor and ceiling above. A non-positive target falls back, and a fallback that
/// is itself non-positive answers the ceiling — the slowest safe gap — rather than dividing by it.
///
/// The multiply and the divide stay SEPARATE from any add, and no fused multiply-add appears: the
/// golden vectors pin these bit patterns, and a single rounding where the wire does two moves them.
#[must_use]
pub fn adaptive_gap_nanos(
    target_bps: i64,
    fallback_bps: i64,
    chunk_fragments: usize,
    datagram_size: usize,
    rate_multiplier: f64,
) -> u64 {
    let bps = if target_bps > 0 { target_bps } else { fallback_bps };
    if bps <= 0 {
        return PACING_GAP_CEIL_NANOS;
    }
    let multiplier = if rate_multiplier.is_finite() {
        rate_multiplier.max(1.0)
    } else {
        1.0
    };
    #[expect(
        clippy::cast_precision_loss,
        reason = "a bitrate is at most a hundred million; f64 is exact to 2^53"
    )]
    let effective_bps = bps as f64 * multiplier;
    let chunk_bytes = chunk_fragments.saturating_mul(datagram_size);
    #[expect(
        clippy::cast_precision_loss,
        reason = "a chunk is a few tens of kilobytes; the conversion is exact"
    )]
    let chunk_bits = chunk_bytes as f64 * 8.0;
    let gap = chunk_bits / effective_bps * 1_000_000_000.0;
    if !gap.is_finite() || gap < 0.0 {
        return PACING_GAP_CEIL_NANOS;
    }
    #[expect(
        clippy::cast_precision_loss,
        reason = "the ceiling is 4e7; f64 represents it exactly"
    )]
    let ceiling = PACING_GAP_CEIL_NANOS as f64;
    let bounded = gap.min(ceiling);
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "bounded is finite, non-negative and at most the ceiling, checked immediately above"
    )]
    let nanos = bounded as u64;
    nanos.clamp(PACING_GAP_FLOOR_NANOS, PACING_GAP_CEIL_NANOS)
}

/// Whether this captured frame must be SKIPPED because the send lane is backed up.
///
/// The real-time discipline is to DROP rather than to queue: an unbounded lane under a sustained
/// scroll lets the encoder outrun the drain and latency bloats to seconds, which no environment
/// knob can fix because a deep-buffered path triggers no loss-based backoff until the buffer is
/// already huge.
///
/// The drop happens BEFORE encode, which is what makes it safe: the P-frame reference chain stays
/// intact, so the client never sees a decode break — unlike dropping a frame that is already
/// queued. A frame carrying any forced obligation always passes; those are recovery and sharpness
/// anchors, and an anchor dropped for congestion is a client that stays broken through the very
/// congestion the anchor was answering.
#[must_use]
pub const fn backpressure_skip(
    enabled: bool,
    lane_depth: usize,
    depth_threshold: usize,
    forced: bool,
) -> bool {
    if !enabled || forced {
        return false;
    }
    lane_depth > depth_threshold
}

/// Whether to duplicate-send this keyframe.
///
/// True when loss is present — the smoothed rate is at or above the threshold — OR the fast-attack
/// window is still open. The second term closes the EWMA's leading-edge lag, so the FIRST re-anchor
/// IDR of a burst is protected before the burst has folded into the rate at all.
///
/// On a clean link neither term holds, so the periodic crisp IDR is not duplicated. That is the
/// bandwidth this gate exists to save, and the reason it is a gate rather than an always-on.
#[must_use]
pub fn should_dup_keyframe(loss_rate: f64, now: f64, fast_attack_until: f64, threshold: f64) -> bool {
    loss_rate >= threshold || now < fast_attack_until
}

/// The two components a teardown takes back, each absent when it was never installed.
///
/// Named because it is the ANSWER of a fallible take: `None` for a stale caller, and inside it a
/// pair either of whose halves a partial bring-up may have left empty.
pub type TakenComponents<Capture, Encode> = Option<(Option<Arc<Capture>>, Option<Arc<Encode>>)>;

/// The live framework objects a session installs as a SET.
///
/// A struct rather than five fields because every rebuild path replaces all of them together and
/// every one of those paths guards on IDENTITY across a suspension. The Swift wrote that guard five
/// times per path — `capturer === oldCapturer, encoder === oldEncoder, …` — and the class of bug it
/// was defending against is a path that forgets one of the five. A generation counter over the set
/// answers the same question once and cannot be partially written.
#[derive(Debug)]
pub struct Live<Capture: ?Sized, Encode: ?Sized> {
    /// Which install this is. Bumped on every replacement, never reused.
    ///
    /// This is the identity comparison, done properly. `===` on five objects asks "is each of these
    /// the one I started with"; a generation asks "is the SET the one I started with", which is the
    /// question every call site actually had, and it cannot be answered half-right.
    pub generation: u64,
    /// The capture stream, absent before bring-up and after teardown.
    pub capture: Option<Arc<Capture>>,
    /// The encoder session, installed and replaced with the capture stream.
    pub encode: Option<Arc<Encode>>,
}

impl<Capture: ?Sized, Encode: ?Sized> Default for Live<Capture, Encode> {
    fn default() -> Self {
        Self {
            generation: 0,
            capture: None,
            encode: None,
        }
    }
}

impl<Capture: ?Sized, Encode: ?Sized> Live<Capture, Encode> {
    /// An empty set, before any bring-up.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Installs a fresh capture and encoder pair, answering the generation they were installed as.
    ///
    /// The caller keeps that number and presents it again after any suspension; see
    /// [`Self::is_current`].
    pub fn install(&mut self, capture: Arc<Capture>, encode: Arc<Encode>) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.capture = Some(capture);
        self.encode = Some(encode);
        self.generation
    }

    /// Whether `generation` is still the installed one.
    ///
    /// The one question every post-suspension guard asks. A rebuild that resumes to find this false
    /// must install nothing and acknowledge nothing: a newer owner is live, and clearing the
    /// session's references would orphan ITS capture stream — the leak the Swift's five-way
    /// comparison existed to prevent, expressed once.
    #[must_use]
    pub const fn is_current(&self, generation: u64) -> bool {
        self.generation == generation
    }

    /// Takes the set out, leaving it empty, when `generation` is still current.
    ///
    /// Answers `None` for a stale caller, which is what makes a late teardown a no-op rather than a
    /// clobber of the newer owner's components.
    pub const fn take_if_current(&mut self, generation: u64) -> TakenComponents<Capture, Encode> {
        if !self.is_current(generation) {
            return None;
        }
        Some((self.capture.take(), self.encode.take()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for a framework object, so the generation discipline is testable with no window
    /// server anywhere near it.
    #[derive(Debug)]
    struct Fake(u32);

    /// The two timings a live daemon resolves before it folds the gate table, spelled as the rule
    /// crate spells them rather than as round numbers — a pause threshold is lifted to the
    /// keepalive interval and held under the idle timeout, so a made-up pair would test a
    /// clamp that never runs.
    const CONTEXT: slopdesk_video::host_gates::GateContext = slopdesk_video::host_gates::GateContext {
        scroll_resampler_active: false,
        keepalive_interval: slopdesk_video::keepalive::KEEPALIVE_INTERVAL_SECONDS,
        idle_timeout: slopdesk_video::keepalive::IDLE_TIMEOUT_SECONDS,
    };

    #[test]
    fn an_unpaced_gate_answers_a_zero_gap_whatever_the_rate() {
        let mut gates = HostGates::from_env(&[], CONTEXT);
        gates.pace_send = false;
        let plan = PacePlan::for_frame(&gates, true, 40_000_000, 1200);
        assert_eq!(plan.gap_nanos, 0, "pacing off must not compute a gap at all");
    }

    #[test]
    fn a_keyframe_paces_at_its_own_floor_when_the_live_rate_is_below_it() {
        let gates = HostGates::from_env(&[], CONTEXT);
        // The bug this pins: a recovery IDR paced at a collapsed ABR serialises for hundreds of
        // milliseconds, and IDR delivery time IS recovery time.
        let collapsed = 1_000_000;
        let key = PacePlan::for_frame(&gates, true, collapsed, 1200);
        let delta_gates = gates;
        let delta = PacePlan::for_frame(&delta_gates, false, collapsed, 1200);
        assert!(
            key.gap_nanos <= delta.gap_nanos,
            "a keyframe must drain at least as fast as a delta at the same collapsed rate"
        );
    }

    #[test]
    fn the_adaptive_gap_is_clamped_at_both_ends() {
        #[expect(
            clippy::integer_division,
            reason = "a literal quarter of the range, exact by construction"
        )]
        let huge = adaptive_gap_nanos(i64::MAX / 4, PACING_FALLBACK_BPS, 8, 1200, 2.5);
        assert_eq!(
            huge, PACING_GAP_FLOOR_NANOS,
            "a high rate must not compute a zero gap"
        );
        let none = adaptive_gap_nanos(0, 0, 8, 1200, 2.5);
        assert_eq!(
            none, PACING_GAP_CEIL_NANOS,
            "no rate at all must answer the slowest safe gap"
        );
    }

    #[test]
    fn a_non_finite_multiplier_falls_back_to_one_rather_than_poisoning_the_gap() {
        let gap = adaptive_gap_nanos(12_000_000, PACING_FALLBACK_BPS, 8, 1200, f64::NAN);
        assert!(
            (PACING_GAP_FLOOR_NANOS..=PACING_GAP_CEIL_NANOS).contains(&gap),
            "a NaN multiplier must not escape the clamp"
        );
    }

    #[test]
    fn backpressure_never_drops_a_frame_carrying_an_obligation() {
        assert!(
            !backpressure_skip(true, 999, 3, true),
            "an anchor must reach the encoder however deep the lane is"
        );
        assert!(
            backpressure_skip(true, 4, 3, false),
            "an ordinary delta past the threshold is the droppable case"
        );
        assert!(
            !backpressure_skip(false, 999, 3, false),
            "the gate off means the lane depth is never consulted"
        );
    }

    #[test]
    fn the_fast_attack_window_duplicates_a_keyframe_before_any_loss_has_folded() {
        let mut counters = FrameCounters::default();
        counters.arm_fast_attack(100.0, KF_DUP_FAST_ATTACK_WINDOW);
        assert!(
            should_dup_keyframe(0.0, 100.1, counters.kf_dup_fast_attack_until, 0.005),
            "the first re-anchor IDR of a burst must be duplicated even at a zero loss rate"
        );
        assert!(
            !should_dup_keyframe(0.0, 101.0, counters.kf_dup_fast_attack_until, 0.005),
            "once the window closes a clean link must stop paying for duplication"
        );
    }

    #[test]
    fn the_offered_ewma_reads_as_absent_until_a_delta_lands() {
        let mut controllers = Controllers::new(RecoveryIdrConfig::default());
        assert!(
            controllers.offered_bps(60).is_none(),
            "before the first delta the probe must not be gated at all"
        );
        controllers.note_delta_bytes(10_000);
        assert!(
            controllers.offered_bps(60).is_some_and(|bps| bps > 0.0),
            "one delta is enough to start reporting offered load"
        );
    }

    #[test]
    fn a_silent_client_that_never_spoke_feedback_is_never_paused() {
        let liveness = ClientLiveness::starting_at(0.0);
        assert!(
            !liveness.should_pause(1_000.0, 5.0),
            "a client that never reported must never be paused, however long it is quiet"
        );
    }

    #[test]
    fn a_proven_client_pauses_and_resumes_on_the_next_datagram() {
        let mut liveness = ClientLiveness::starting_at(0.0);
        liveness.saw_feedback = true;
        assert!(
            liveness.should_pause(6.0, 5.0),
            "past the threshold a proven client pauses"
        );
        liveness.paused = true;
        assert!(
            liveness.note_inbound(6.1),
            "the next inbound datagram must report that video is resuming"
        );
        assert!(!liveness.paused, "and must clear the latch");
    }

    #[test]
    fn a_disabled_threshold_never_pauses_however_silent_the_client() {
        let mut liveness = ClientLiveness::starting_at(0.0);
        liveness.saw_feedback = true;
        assert!(
            !liveness.should_pause(10_000.0, 0.0),
            "a zero threshold is the disabled spelling, not an instant one"
        );
    }

    #[test]
    fn a_stale_generation_can_neither_read_nor_clear_the_newer_owners_components() {
        let mut live: Live<Fake, Fake> = Live::new();
        let first = live.install(Arc::new(Fake(1)), Arc::new(Fake(1)));
        let second = live.install(Arc::new(Fake(2)), Arc::new(Fake(2)));
        assert!(!live.is_current(first), "the first install is superseded");
        assert!(live.is_current(second), "the second is the live one");
        assert!(
            live.take_if_current(first).is_none(),
            "a late teardown must not clear the newer owner's components"
        );
        assert_eq!(
            live.capture.as_ref().map(|capture| capture.0),
            Some(2),
            "and must leave the NEWER owner's set installed — this is the streaming-but-dead leak, and the \
             tag is what tells a cleared set apart from a set replaced by the wrong one"
        );
        assert!(
            live.take_if_current(second).is_some(),
            "the current owner tears its own set down"
        );
    }

    #[test]
    fn a_generation_is_never_reused() {
        let mut live: Live<Fake, Fake> = Live::new();
        let mut seen = std::collections::BTreeSet::new();
        for _ in 0..64 {
            let generation = live.install(Arc::new(Fake(0)), Arc::new(Fake(0)));
            assert!(
                seen.insert(generation),
                "a reused generation would revive a stale guard"
            );
        }
    }

    #[test]
    fn a_display_target_holds_the_wake_and_a_window_target_does_not() {
        let display = Target::Display { id: 7 };
        let window = Target::Window {
            id: 7,
            pid: 42,
            size_override: None,
            resize_limit: None,
        };
        assert!(
            display.holds_display_wake(),
            "a full-desktop session keeps the display awake"
        );
        assert!(
            !window.holds_display_wake(),
            "a window pane must not pin the host's display awake"
        );
        assert_eq!(window.window_id(), Some(7));
        assert_eq!(
            display.window_id(),
            None,
            "a display target has no window id to resize"
        );
    }
}
