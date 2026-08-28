//! The two pumps a live session runs: capture into the encoder, and encoded frames onto the wire.
//!
//! Replaces the hot half of the Swift host's session actor — the capture closure it handed the
//! window capturer, and `onEncodedFrame` with its `sendPaced` drain. Both were closures over an
//! actor; here each is a value with a name, because the thread it runs on is part of what it is.
//!
//! ## The queue that is gone
//! The Swift put an `EncodedFrameQueue` plus a wakeup plus a consumer task between the encoder and
//! the packetizer, for ONE reason: an `actor` reorders anything that `await`s into it, so two
//! frames could be assigned ids out of encode order. `VideoToolbox` calls its sink back on its own
//! SERIAL queue, so encode order is already call order, and with no actor there is nothing left to
//! re-serialise. [`EncodedPump`] IS the pump: one queue, one wakeup and one thread hop per frame
//! deleted from between the encoder and the wire.
//!
//! Two obligations come with that, and both are why this module is short:
//!
//! * **The bytes are borrowed.** [`FinishedFrame::avcc`] is the framework's buffer, valid for the
//!   call. Nothing here copies it: [`crate::packetize::PacketizeLane::packetize`] consumes the
//!   borrow synchronously and what outlives the call is the DATAGRAMS, which are owned by
//!   construction. The retransmit log takes its own handle on those, which is its contract, not a
//!   second copy of the frame.
//! * **The sink must not sleep.** A pacing gap paid on this thread delays frames N+1..k behind
//!   frame N — the measured 28–179 ms send gaps the Swift note names. Every paced sleep belongs to
//!   [`crate::sendlane::VideoSendLane`]'s own thread, and the one exception is the operator who
//!   turned the lane OFF and asked for exactly that.
//!
//! ## One schedule, never two
//! `SLOPDESK_SEND_LANE=0` ([`Session::send_lane`] is `None`) drains through [`drain_inline`], which
//! asks [`slopdesk_video::send_pacing::pace_plan`] for the same schedule the lane's own consumer
//! asks it for, off the same [`crate::sendlane::Job`]. The Swift once wrote that arithmetic out a
//! second time here and the copies parted: the fallback had no `keyframe` to read, so it floored a
//! recovery IDR at the DELTA pace floor and serialised the one frame whose delivery time IS the
//! client's recovery time. One value cannot drift from itself, which is why the [`PacePlan`] is
//! decided ONCE above both arms.
//!
//! ## The clock
//! Every instant below is [`Session::now`] — seconds since the session's own epoch — including the
//! absolute deadlines [`drain_inline`] sleeps to. There is no [`std::time::Instant::now`] in this
//! file. A second clock would put the fragment stamps and the pacing schedule a start-up delay
//! apart, which is a wire bug no gate on either side of the link can see.
//!
//! ## Lock order on the hot path
//! Two short holds of `controllers`, two of `counters`, one of `state` per `media_flowing` check,
//! and at most one of `streaming` — never nested, and NEVER held across a send. In order:
//! `state` → `controllers` (the folds) → `counters` (the count) → `streaming` (the keyframe's
//! staged-token flush, cloned out and called on the far side of the guard) → packetize →
//! `state` again → `controllers` (the two records) → `counters` (the gap stamp and the duplicate
//! throttle) → the wire.
//!
//! ## What this module does NOT own
//! The heartbeat, the client-silence pause, the cadence announcement and the display-max report
//! live with the bring-up that arms them, in [`crate::session_capture`]. They were named in this
//! file's brief and moved before it was written; nothing here duplicates them.
//!
//! ## Two branches of the Swift that do not appear
//! * **Small-frame duplication** (`:2869`). Every one of its terms needs `adaptiveMEnabled`, and no
//!   `SLOPDESK_FEC_M` gate exists in [`slopdesk_video::host_gates`] — [`Session::new`] builds the
//!   packetizer with [`slopdesk_video::fec::ReedSolomonFec::default`], whose `m` is one. The branch
//!   is unreachable, and a port of unreachable code is a claim about behaviour nobody can check.
//! * **The self-heal disarm** on an encoded keyframe (`:2730`). `Capturer::set_self_heal_eligible`
//!   exists on the concrete capturer, but [`crate::session::CaptureStream`] does not carry it, and
//!   the live set holds the trait. It is a missing door, not a decision taken here.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Weak};
use std::thread;
use std::time::Duration;

use slopdesk_apple_sck::CMSampleBuffer;
use slopdesk_apple_vt::{CVImageBuffer, Timestamp};
use slopdesk_video::adaptive_fec::{self, multi_loss};
use slopdesk_video::fragment::MAX_DATAGRAM_SIZE;
use slopdesk_video::packetizer::PacketizeOptions;
use slopdesk_video::scroll_reproject::ScrollHint;
use slopdesk_video::send_pacing::pace_plan;
use slopdesk_video::video_control::VideoControlMessage;

use crate::audio::AudioSender;
use crate::capture::{CaptureEvents, FramePlan};
use crate::diag;
use crate::encode::{EncodedFrameSink, Encoder, FinishedFrame};
use crate::mux_registry::LaneSession;
use crate::sendlane::Job;
use crate::session::Session;
use crate::session_wiring::{KF_DUP_MIN_INTERVAL, PacePlan, backpressure_skip, should_dup_keyframe};

/// A send gap past this many seconds is what the debug trace reports.
///
/// 28 ms — one 30 fps slot — and [`crate::capture`]'s own delivery-gap threshold, because the two
/// traces bracket the same stall from the two ends of the encoder.
const SEND_GAP_TRACE_SECONDS: f64 = 0.028;

/// How often the frame counter prints itself under the debug gate.
const FRAME_TRACE_INTERVAL: u64 = 15;

/// The encoder's output, on its way to the wire.
///
/// Holds a [`Weak`] and nothing else. The session owns the encoder, the encoder owns this sink, and
/// a strong edge back would close a cycle nothing could drop — and this is also built BEFORE the
/// encoder exists, so there is nothing else it could hold.
#[derive(Debug)]
pub(crate) struct EncodedPump {
    /// The session this frame belongs to, or a dead handle once it has been dropped.
    session: Weak<Session>,
}

impl EncodedPump {
    /// The sink for one session's encoder.
    #[must_use]
    pub(crate) fn new(session: &Arc<Session>) -> Arc<Self> {
        Arc::new(Self {
            session: Arc::downgrade(session),
        })
    }
}

impl EncodedFrameSink for EncodedPump {
    /// ⚠️ Runs on `VideoToolbox`'s own callback thread. See the module note: the bytes are borrowed
    /// for this call, and nothing here may sleep.
    fn frame(&self, frame: &FinishedFrame<'_>) {
        let Some(session) = self.session.upgrade() else {
            // The session went while this frame was in the encoder. Its transport is retired and
            // its lane is closed, so there is nowhere for the frame to go and nothing to report.
            return;
        };
        wire_frame(&session, frame);
    }
}

/// One finished frame, packetized, recorded and sent.
///
/// A free function over `&Session` rather than a method on the sink so the whole hot path is
/// reachable from a test with no encoder, no capturer and no window server anywhere near it.
#[expect(
    clippy::too_many_lines,
    reason = "the hot path for one frame, written straight through: every lock it takes is scoped to the \
              statement that needs it, and a split would hide which"
)]
fn wire_frame(session: &Session, frame: &FinishedFrame<'_>) {
    if !session.locked_state().media_flowing() {
        trace(session, || "encoded frame dropped (media not flowing)".to_owned());
        return;
    }
    let anchor = frame.keyframe || frame.crisp;
    let bytes = frame.avcc.len();

    // FOLD, ONCE. The governor's own EWMA and the ABR's utilisation signal both exclude ANCHORS:
    // an IDR is an episodic 5–10× outlier, and folding it would fake a saturated link for the
    // several reports after every recovery — precisely when the controller must not back off. The
    // long-term-reference world is cleared here too, on a keyframe, BEFORE this frame's own token
    // is recorded below: an IDR clears the decoder's DPB by HEVC spec, so every token acked before
    // it names a reference the client no longer holds.
    let (abr_bps, loss_rate, ladder_tier) = {
        let mut controllers = session.locked_controllers();
        if let Some(governor) = controllers.fps.as_mut() {
            governor.note_encoded_frame(i64::try_from(bytes).unwrap_or(i64::MAX), anchor);
        }
        if !anchor {
            controllers.note_delta_bytes(bytes);
        }
        if frame.keyframe {
            controllers.ltr.reset();
        }
        // Read HERE, under the lock the report fold steps it under, rather than in `wire_tier`
        // below: a second acquisition would be a second answer, and the frame between the fold's
        // write and that read would go out stamped with a tier the fold had already retired.
        (
            controllers.last_actuated_bps,
            controllers.estimate.loss_rate,
            controllers.fec_tier.tier,
        )
    };

    let encoded = {
        let mut counters = session.locked_counters();
        counters.encoded = counters.encoded.wrapping_add(1);
        counters.encoded
    };
    if encoded == 1 || encoded.is_multiple_of(FRAME_TRACE_INTERVAL) {
        trace(session, || {
            format!(
                "encoded+sent frame #{encoded} ({bytes}B, keyframe={}, crisp={})",
                frame.keyframe, frame.crisp
            )
        });
    }

    // The staged acknowledged tokens die with the keyframe that flushed the client's picture. The
    // handle is cloned OUT of the lock and the framework call made on the far side of it: a resize
    // installing the next live set must never wait behind a property write.
    if frame.keyframe {
        let held = session
            .locked_streaming()
            .as_ref()
            .and_then(|streaming| streaming.live.encode.clone());
        if let Some(held) = held {
            held.clear_staged_tokens();
        }
    }

    let packed = session.packetize.packetize(frame.avcc, PacketizeOptions {
        keyframe: frame.keyframe,
        crisp: frame.crisp,
        // All fragments of one frame share one stamp. Zero when telemetry is off, which the client
        // reads as "no host send time" and answers by skipping its RTT fold.
        host_send_ts_millis: if session.gates.telemetry_enabled {
            host_send_millis(session)
        } else {
            0
        },
        fec_tier: wire_tier(session, ladder_tier),
        // The wire bit that tells the client to acknowledge this frame after it decodes. Off
        // whenever the gate is off or the encoder surfaced no token, in which case there is also
        // nothing to record below.
        is_ltr: session.gates.ltr_enabled && frame.ltr_token.is_some(),
        acked_anchored: frame.acked_anchored,
        interleave: session.gates.interleave_transmit,
    });

    // A teardown can interleave with the packetization above: its flush already dropped this
    // capture generation's queued frames, so this one is dropped too rather than enqueued after
    // the flush — and NOTHING below runs, because a frame that is never sent must leave no id
    // behind for a recovery or a NACK to name.
    if !session.locked_state().media_flowing() {
        trace(session, || {
            "encoded frame dropped post-packetize (media not flowing)".to_owned()
        });
        return;
    }

    let now = session.now();
    {
        let mut controllers = session.locked_controllers();
        // Recorded against the id the lane just ASSIGNED, which is why the lane answers it: a
        // caller that read the id first could have another frame slip between, and the mapping
        // would then name the wrong frame.
        if let Some(token) = frame.ltr_token.filter(|_| session.gates.ltr_enabled) {
            controllers.ltr.record_ltr_frame(packed.frame_id, token);
        }
        // EVERY keyframe — recovery, first frame, crisp re-anchor, heartbeat. The duplicate below
        // reuses this same id, so there is nothing extra to record for it.
        if frame.keyframe {
            controllers.recovery_idr.note_keyframe_sent(packed.frame_id, now);
        }
    }

    // Recorded BEFORE the send, so a NACK can never observe a sent-but-unrecorded frame.
    if let Some(log) = session.retransmit.as_ref() {
        log.record(packed.frame_id, &packed.outgoings);
    }

    // The counters, once more: the send-gap probe's stamp and the duplicate throttle's verdict,
    // taken together so the hot path touches this lock twice per frame rather than three times.
    // The verdict is DECIDED here and acted on outside, because the guard may not be held across a
    // send.
    let (gap, duplicate) = {
        let mut counters = session.locked_counters();
        let gap = (counters.last_send_at > 0.0).then(|| now - counters.last_send_at);
        counters.last_send_at = now;
        let duplicate = session.gates.kf_dup
            && frame.keyframe
            && should_dup_keyframe(
                loss_rate,
                now,
                counters.kf_dup_fast_attack_until,
                session.gates.kf_dup_loss_threshold,
            )
            // Zero is "never duplicated", not "duplicated at time zero". The Swift compared against
            // the machine's uptime, where a session's first frame is already hours past the origin;
            // this clock starts AT the session, so a plain subtraction would suppress the duplicate
            // of every keyframe in the first quarter-second — which is exactly the connect-time
            // IDR the fast-attack window exists to protect.
            && (counters.last_keyframe_dup <= 0.0
                || now - counters.last_keyframe_dup >= KF_DUP_MIN_INTERVAL);
        if duplicate {
            counters.last_keyframe_dup = now;
        }
        drop(counters);
        (gap, duplicate)
    };
    if let Some(gap) = gap.filter(|gap| *gap > SEND_GAP_TRACE_SECONDS) {
        trace(session, || format!("send gap {:.0}ms", gap * 1000.0));
    }

    // ONE plan for whichever drain sends it, and one job off that plan. Keyframes floor at the
    // keyframe pace target because an IDR's delivery time IS the client's recovery time; deltas
    // floor at their own, which lifts a scroll-onset frame off a stale-low rate without un-pacing
    // it. `PacePlan` owns both floors; this only asks.
    let plan = PacePlan::for_frame(&session.gates, frame.keyframe, abr_bps, MAX_DATAGRAM_SIZE);
    let job = Job::new(
        Arc::clone(&packed.outgoings),
        plan.gap_nanos,
        plan.chunk_fragments,
        0,
    );
    // The duplicate's separation is the STATIC gate value, not this frame's computed adaptive gap:
    // it separates two copies in time, and an adaptive gap would shrink that separation exactly
    // when the link is fast enough for a burst to take both copies at once.
    let separation = session.gates.pace_gap_nanos;

    let Some(lane) = session.send_lane.as_ref() else {
        drain_inline(session, &job);
        // `drain_inline` re-checks on the far side of the leading delay, so a teardown racing the
        // gap still aborts before a byte of the second copy goes out.
        if duplicate {
            drain_inline(session, &job.delayed(separation));
        }
        return;
    };
    // Inline fast path: a tiny single-shot DELTA that produces no second copy can skip the lane's
    // wakeup hop when the wire is idle — the typing-idle keystroke, where a fraction of a
    // millisecond off input-to-photon is felt. The one-shot test is the LANE's, so an inlined frame
    // goes out byte-for-byte as the lane would have sent it, and it refuses whenever the lane is
    // busy, so a keystroke can never overtake an earlier frame. Keyframes always take the lane:
    // their duplicate must stay ordered behind the primary on the one consumer.
    let inlined = !frame.keyframe && lane.try_send_inline(&job);
    if !inlined {
        lane.enqueue(job.clone());
    }
    if duplicate {
        lane.enqueue(job.delayed(separation));
    }
}

/// Drains one job on the CALLING thread — the `SLOPDESK_SEND_LANE=0` path.
///
/// The lane's own consumer with the session's `media_flowing` in place of the lane's flush
/// generation, and the SAME schedule: [`pace_plan`] is asked off the job's own spec, so the two
/// drains cannot part. Deadlines are ABSOLUTE, anchored at the start on [`Session::now`], because a
/// relative sleep oversleeps by the platform's timer quantum and the overshoot accumulates per
/// chunk; an absolute deadline already past sends at once, which is the catch-up the schedule is
/// shaped for.
fn drain_inline(session: &Session, job: &Job) {
    if job.spec().leading_delay_nanos > 0 {
        let until = session.now() + Duration::from_nanos(job.spec().leading_delay_nanos).as_secs_f64();
        if !park_until(session, until) {
            return;
        }
    }
    let plan = pace_plan(job.spec());
    // Started AFTER the leading delay, so the delay is not paid twice — the plan's own offsets are
    // relative to this instant.
    let start = session.now();
    for (index, chunk) in plan.iter().enumerate() {
        for slot in chunk.start..chunk.end {
            if let Some(outgoing) = job.outgoings().get(slot) {
                session.transport.send(&outgoing.bytes, outgoing.channel);
            }
        }
        let Some(next) = plan.get(index + 1) else {
            return;
        };
        if !park_until(
            session,
            start + Duration::from_nanos(next.due_nanos).as_secs_f64(),
        ) {
            return;
        }
    }
}

/// Sleeps until `deadline` on the SESSION's clock, answering whether the job may go on.
///
/// A deadline already past returns without sleeping. The answer is the `mediaFlowing` re-check the
/// Swift made at every boundary a sleep could be raced across: a `bye` or a stop that arrives
/// during a pacing gap aborts the rest of the frame rather than paving a dead client's socket.
fn park_until(session: &Session, deadline: f64) -> bool {
    let remaining = deadline - session.now();
    if remaining > 0.0 {
        thread::sleep(Duration::from_secs_f64(remaining));
    }
    session.locked_state().media_flowing()
}

/// The FEC tier every fragment of this frame carries.
///
/// `ladder_tier` is [`crate::session_wiring::Controllers::fec_tier`]'s, read by the caller under
/// the lock the report fold steps it under — never re-read here, for the reason stated there.
///
/// The gate is consulted the way the Swift's was: the ladder's tier is only trusted when the ladder
/// is actually RUNNING, because a stale tier from a session that later turned adaptive FEC off
/// would otherwise keep being stamped. Off ⇒ the configured baseline, which is the shipped default.
///
/// The adaptive-`m` term is the FOLD'S OWN term, asked for rather than restated. It has to be: the
/// fold routes to [`slopdesk_video::adaptive_fec::next_parity_tier_state`] when the ladder is on,
/// and that ladder emits only tiers 5/6/7 — which are precisely the tiers
/// [`slopdesk_video::adaptive_fec::wire_tier`] passes through instead of forcing to
/// [`slopdesk_video::adaptive_fec::DEFAULT_TIER`] under multi-loss. A `false` here would therefore
/// clobber, on the wire, the exact ladder the fold had just stepped.
///
/// With the shipped codec the two branches are byte-identical — `Session::new` pins
/// [`slopdesk_video::fec::ReedSolomonFec::default`] at `m = 1`, so multi-loss is inactive and
/// nothing is forced either way. The wiring is here for the build where `m` is not 1, because that
/// is the build where a hardcode would be silent.
fn wire_tier(session: &Session, ladder_tier: u8) -> u8 {
    let adaptive = if session.gates.adaptive_fec_enabled {
        ladder_tier
    } else {
        adaptive_fec::DEFAULT_TIER
    };
    let parity = session.packetize.fec().map_or(0, |scheme| scheme.parity_count());
    adaptive_fec::wire_tier(
        adaptive,
        session.adaptive_m_enabled(),
        multi_loss::is_active(parity),
    )
}

/// The host-relative send stamp, in milliseconds, wrapped into the wire's 32 bits.
///
/// The session's OWN epoch, masked exactly as [`crate::audio`] masks its own stamp: the two streams
/// share one clock contract, and a millisecond that wrapped differently on one of them would put
/// the client's two timelines apart at the wrap.
fn host_send_millis(session: &Session) -> u32 {
    u32::try_from(session.epoch.elapsed().as_millis() & u128::from(u32::MAX)).unwrap_or(u32::MAX)
}

/// One debug line, built only when the gate is open.
///
/// The message is a closure because every caller interpolates: formatting first and discarding the
/// string second would put an allocation on the hot path for a line nobody prints.
fn trace(session: &Session, message: impl FnOnce() -> String) {
    if session.gates.debug_stderr {
        diag::say(&message());
    }
}

/// What the capturer delivers into: the encoder, the audio lane, and the session's control channel.
///
/// Holds a [`Weak`] session for [`EncodedPump`]'s reason — the session owns the capturer, which
/// owns this — and STRONG handles to the encoder and the audio lane, which are this pump's to
/// drive and which the live set replaces wholesale on a resize.
#[derive(Debug)]
pub(crate) struct CapturePump {
    /// The session, or a dead handle once it has been dropped.
    session: Weak<Session>,
    /// The encoder every captured frame is handed to, on the capture queue.
    encoder: Arc<Encoder>,
    /// The audio lane, or `None` when the tap was never armed.
    audio: Option<Arc<AudioSender>>,
    /// Which install this pump belongs to; zero until the bring-up adopts it.
    ///
    /// The pump exists BEFORE the capturer it is handed to, so it cannot be constructed with its
    /// generation. Zero is therefore "not yet installed", and a capture death reported in that
    /// window names no live set and tears nothing down.
    generation: AtomicU64,
}

impl CapturePump {
    /// The pump for one bring-up. See [`Self::adopt_generation`] for the half that comes later.
    #[must_use]
    pub(crate) fn new(
        session: &Arc<Session>,
        encoder: &Arc<Encoder>,
        audio: Option<Arc<AudioSender>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            session: Arc::downgrade(session),
            encoder: Arc::clone(encoder),
            audio,
            generation: AtomicU64::new(0),
        })
    }

    /// Tells the pump which install it belongs to, once the live set exists.
    ///
    /// `&self` because by this point the pump is already behind the [`Arc`] the capturer holds —
    /// which is the whole reason the generation is an atomic rather than a field.
    pub(crate) fn adopt_generation(&self, generation: u64) {
        self.generation.store(generation, Ordering::Release);
    }
}

impl CaptureEvents for CapturePump {
    /// ⚠️ Runs on the capture frame queue. Nothing here may re-enter the capturer.
    fn frame(&self, image: &CVImageBuffer, presentation: Timestamp, plan: FramePlan) {
        let Some(session) = self.session.upgrade() else {
            return;
        };
        // CONGESTION BACKPRESSURE, before the encode and not after it: dropping a delta BEFORE it
        // is encoded leaves the P-frame reference chain intact, so the client never sees a decode
        // break, and it is what bounds end-to-end latency under a scroll burst. A frame carrying
        // any forced obligation always passes — those are recovery and sharpness anchors, and an
        // anchor dropped for congestion is a client that stays broken through the congestion the
        // anchor was answering. No lane ⇒ no depth ⇒ never skipped.
        if let Some(lane) = session.send_lane.as_ref() {
            let depth = lane.depth();
            if backpressure_skip(
                session.gates.backpressure_enabled,
                depth,
                usize::try_from(session.gates.backpressure_depth).unwrap_or_default(),
                plan.force_keyframe || plan.crisp || plan.compact || plan.ltr_refresh,
            ) {
                trace(&session, || {
                    format!(
                        "backpressure skip: lane depth {depth} > {}",
                        session.gates.backpressure_depth
                    )
                });
                return;
            }
        }
        // The four ways a frame reaches the encoder, in the Swift's own order — a refresh is
        // cheapest and most specific, a live frame is the fall-through. Every branch is the PLAN's,
        // decided by `slopdesk_video::capture_gates` before this call.
        let encoded = if plan.ltr_refresh {
            self.encoder.encode_ltr_refresh(image, presentation)
        } else if plan.crisp {
            self.encoder.encode_crisp(image, presentation)
        } else if plan.compact {
            self.encoder.encode_compact(image, presentation)
        } else {
            self.encoder
                .encode_live(image, presentation, plan.force_keyframe, plan.per_frame_max_qp)
        };
        if let Err(error) = encoded {
            // Reported, not recovered from: the encoder-rebuild ladder belongs to whoever owns the
            // resize and rebuild paths, and a half-ladder here would be a second answer to a
            // question that must have one.
            trace(&session, || format!("encode refused: {error}"));
        }
    }

    /// ⚠️ Runs on the capture AUDIO queue, which is not the frame queue.
    fn audio(&self, sample: &CMSampleBuffer) {
        if let Some(audio) = self.audio.as_ref() {
            audio.handle(sample);
        }
    }

    /// ⚠️ Runs on the frame queue WHILE the capturer holds its frame-state lock — so this sends and
    /// does nothing else.
    ///
    /// Fire-and-forget, and deliberately not duplicated: this is a per-frame stream, and a lost
    /// hint costs one reprojected frame that the next real frame corrects.
    fn scroll(&self, hint: ScrollHint) {
        let Some(session) = self.session.upgrade() else {
            return;
        };
        if !session.locked_state().media_flowing() {
            return;
        }
        session.send_control(&VideoControlMessage::ScrollOffset {
            dx: hint.dx(),
            dy: hint.dy(),
            band_top: hint.band_top(),
            band_bottom: hint.band_bottom(),
        });
    }

    /// The stream died under the session: the window closed, the display was unplugged, the grant
    /// was revoked, the window server reset.
    ///
    /// The session still believes it streams, and the one-second heartbeat keeps the client's stall
    /// scrim disarmed — so without this the pane freezes PERMANENTLY and silently on its last
    /// decoded frame, and every recovery request just re-encodes it. A visible disconnect beats a
    /// silent freeze: two goodbyes (one unacked UDP datagram is not a delivery) and then the stop.
    ///
    /// Guarded on the adopted generation, which answers both cases the Swift asked separately: a
    /// teardown already ran, or a resize superseded this capturer and a newer owner owns the
    /// session's fate.
    ///
    /// ⚠️ Runs on the frame queue, and [`crate::session::Session::stop`] joins that queue — so the
    /// teardown happens on a thread of its own. Doing it here would deadlock the capturer against
    /// its own death.
    fn capture_failed(&self) {
        let generation = self.generation.load(Ordering::Acquire);
        let Some(session) = self.session.upgrade() else {
            return;
        };
        let current = session
            .locked_streaming()
            .as_ref()
            .is_some_and(|streaming| streaming.live.is_current(generation));
        if generation == 0 || !current || !session.locked_state().media_flowing() {
            trace(&session, || {
                "capture death ignored (torn down, or a superseded capturer died)".to_owned()
            });
            return;
        }
        diag::say("capture died — sending bye + stopping session");
        let spawned = thread::Builder::new()
            .name("slopdesk-capture-death".to_owned())
            .spawn(move || {
                session.send_control(&VideoControlMessage::Bye);
                session.send_control(&VideoControlMessage::Bye);
                session.stop();
            });
        if spawned.is_err() {
            // Nothing else can be done from the frame queue, and saying so is better than a pane
            // that freezes for a reason nobody logged.
            diag::say("capture death teardown could not be started");
        }
    }

    /// ⚠️ Runs on the frame queue WHILE the capturer holds its frame-state lock.
    fn delivery_gap(&self, seconds: f64) {
        let Some(session) = self.session.upgrade() else {
            return;
        };
        trace(&session, || {
            format!("capture delivery gap {:.0}ms", seconds * 1000.0)
        });
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::atomic::AtomicU32;
    use std::sync::{Mutex, PoisonError};

    use slopdesk_video::fragment::FrameFragmentHeader;
    use slopdesk_video::geometry::{VideoRect, VideoSize};
    use slopdesk_video::host_gates::{GateContext, HostGates};
    use slopdesk_video::recovery_idr::{IdrVerdict, RecoveryIdrConfig};
    use slopdesk_video::recovery_routing::VideoChannel;
    use slopdesk_video::session_state::{PROTOCOL_VERSION, VideoSessionStateMachine};

    use super::*;
    use crate::encode::Shape as EncodeShape;
    use crate::env::Overlay;
    use crate::mux_lane::{LaneControl, LaneRetired, MuxLaneTransport};
    use crate::mux_sink::MuxSinkTable;
    use crate::session::{CaptureStream, Streaming};
    use crate::session_wiring::{KF_DUP_FAST_ATTACK_WINDOW, Live, SessionSpec, Target};

    /// The two timings a live daemon resolves before it folds the gate table, spelled the way the
    /// rules crate spells them — a made-up pair would exercise a clamp that never runs.
    const CONTEXT: GateContext = GateContext {
        scroll_resampler_active: false,
        keepalive_interval: slopdesk_video::keepalive::KEEPALIVE_INTERVAL_SECONDS,
        idle_timeout: slopdesk_video::keepalive::IDLE_TIMEOUT_SECONDS,
    };

    /// A shared flow that keeps every datagram it is handed, so what went out is a value a test can
    /// read rather than a count it has to trust.
    #[derive(Debug, Default)]
    struct Flow {
        sent: Mutex<Vec<Vec<u8>>>,
    }

    impl LaneControl for Flow {
        fn admit(&self, _channel_id: u32) {}
        fn retire(&self, _channel_id: u32) {}
        fn send(&self, datagram: &[u8], _channel: VideoChannel, _channel_id: u32) {
            self.sent
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(datagram.to_vec());
        }
    }

    /// The registry's half of a lane's retirement, which a test session never consults.
    #[derive(Debug, Default)]
    struct Registry;

    impl LaneRetired for Registry {
        fn lane_retired(&self, _channel_id: u32) {}
    }

    /// A capture stream that counts what was asked of it.
    #[derive(Debug, Default)]
    struct Recorder {
        stops: AtomicU32,
    }

    impl CaptureStream for Recorder {
        fn stop(&self) {
            self.stops.fetch_add(1, Ordering::Relaxed);
        }
        fn set_audio_forwarding(&self, _enabled: bool) {}
        fn set_governed_fps(&self, _fps: i32) {}
        fn set_client_silence_paused(&self, _paused: bool) {}
        fn request_keyframe(&self) {}
        fn request_ltr_refresh(&self) {}
    }

    /// Everything a test holds onto: the session, the flow it writes to, and the registry the lane
    /// holds only a `Weak` to.
    struct Harness {
        session: Arc<Session>,
        flow: Arc<Flow>,
        _registry: Arc<Registry>,
    }

    impl Harness {
        /// The datagrams that reached the wire, in send order.
        fn sent(&self) -> Vec<Vec<u8>> {
            self.flow
                .sent
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        /// The `frame_id` every datagram sent so far carries, in send order.
        fn frame_ids(&self) -> Vec<u32> {
            self.sent()
                .iter()
                .map(|datagram| {
                    FrameFragmentHeader::decode(datagram)
                        .expect("a datagram this host just encoded")
                        .0
                        .frame_id
                })
                .collect()
        }
    }

    /// A listening session with no socket under it, and no send lane — every test here is about
    /// what reaches the wire, and the lane's own thread would only add a wait.
    fn harness(edit: impl FnOnce(&mut HostGates)) -> Harness {
        let registry = Arc::new(Registry);
        // The unsizing happens at this typed binding, not inside `downgrade`. `registry` outlives
        // the strong handle dropped here, so the weak one still upgrades.
        let watcher: Arc<dyn LaneRetired> = registry.clone();
        let observer: Weak<dyn LaneRetired> = Arc::downgrade(&watcher);
        let flow = Arc::new(Flow::default());
        let control: Arc<dyn LaneControl> = flow.clone();
        let transport = Arc::new(MuxLaneTransport::new(
            1,
            control,
            Arc::new(MuxSinkTable::new()),
            observer,
        ));
        let mut gates = HostGates::from_env(&[], CONTEXT);
        gates.send_lane_enabled = false;
        edit(&mut gates);
        let session = Arc::new(Session::new(
            SessionSpec {
                target: Target::Window {
                    id: 7,
                    pid: 42,
                    size_override: None,
                    resize_limit: None,
                },
                capture_scale: 2.0,
                bitrate: 12_000_000,
                fps: 60,
            },
            transport,
            gates,
            RecoveryIdrConfig::default(),
            Overlay::from_text(""),
            VideoSessionStateMachine::new(1, false),
        ));
        Harness {
            session,
            flow,
            _registry: registry,
        }
    }

    /// Drives the state machine to STREAMING through its own hello, and DISCARDS the effects: the
    /// capture arm needs a window server, and every test here is about the pump, not the bring-up.
    fn flowing(session: &Session) {
        let mut state = session.locked_state();
        let _listening = state.start();
        let _accepted = state.handle_control(
            &VideoControlMessage::Hello {
                protocol_version: PROTOCOL_VERSION,
                requested_window_id: 7,
                viewport: VideoSize::new(800.0, 600.0),
            },
            VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
            |_, _| Some((800, 600)),
            |_, _| None,
            |_, _| None,
        );
        assert!(state.media_flowing(), "the hello must have been accepted");
        drop(state);
    }

    /// Installs a recorded capture stream and an unopened encoder as the live set, answering the
    /// generation it went in as and the recorder the test reads.
    ///
    /// `previous` is the counter a bring-up RESUMES from, exactly as the real one does: a fresh
    /// `Live` would restart at one, and a resize would then hand the superseded pump the very
    /// number its successor holds.
    fn install(session: &Session, previous: u64) -> (u64, Arc<Recorder>) {
        let recorder = Arc::new(Recorder::default());
        let installed: Arc<dyn CaptureStream> = recorder.clone();
        let mut live = Live::new();
        live.generation = previous;
        let generation = live.install(installed, encoder());
        *session.locked_streaming() = Some(Streaming {
            live,
            holds_display_wake: false,
            audio_enabled: false,
        });
        (generation, recorder)
    }

    /// An encoder that was never opened, which is all any test here needs one to be.
    fn encoder() -> Arc<Encoder> {
        Arc::new(Encoder::new(
            EncodeShape::default(),
            None,
            &Overlay::from_text(""),
        ))
    }

    /// One finished frame over the given bytes.
    fn finished(avcc: &[u8], keyframe: bool) -> FinishedFrame<'_> {
        FinishedFrame {
            avcc,
            keyframe,
            crisp: false,
            ltr_token: None,
            acked_anchored: false,
        }
    }

    /// Waits up to about five seconds for `done`, answering whether it came true.
    ///
    /// A poll COUNT rather than a deadline, so this file keeps the promise its module note makes:
    /// the only clock anywhere in it is the session's own.
    fn settle(mut done: impl FnMut() -> bool) -> bool {
        for _ in 0..2_500 {
            if done() {
                return true;
            }
            thread::sleep(Duration::from_millis(2));
        }
        done()
    }

    #[test]
    fn a_frame_that_arrives_before_the_hello_never_reaches_the_wire() {
        let harness = harness(|_| {});
        wire_frame(&harness.session, &finished(&[1, 2, 3], true));
        assert!(
            harness.sent().is_empty(),
            "a session that is not streaming has no client to send to"
        );
        assert_eq!(
            harness.session.locked_counters().encoded,
            0,
            "a dropped frame must not be counted as one that went out"
        );
    }

    #[test]
    fn every_datagram_of_a_frame_goes_out_once_under_the_id_the_lane_assigned() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        wire_frame(&harness.session, &finished(&[7; 40], true));
        let ids = harness.frame_ids();
        assert!(
            !ids.is_empty(),
            "a frame must reach the wire as at least one datagram"
        );
        assert!(
            ids.iter().all(|id| *id == 0),
            "every fragment of the first frame carries the first id, parity included"
        );
        wire_frame(&harness.session, &finished(&[8; 40], false));
        assert!(
            harness.frame_ids().contains(&1),
            "the second frame takes the next id, in encode order"
        );
    }

    #[test]
    fn an_anchor_is_kept_out_of_the_offered_load_ewma_and_a_delta_is_folded_in() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        wire_frame(&harness.session, &finished(&[1; 4000], true));
        assert!(
            harness.session.locked_controllers().offered_bytes_per_frame.abs() < f64::EPSILON,
            "an IDR is an episodic outlier; folding it would fake a saturated link"
        );
        wire_frame(&harness.session, &finished(&[1; 800], false));
        assert!(
            harness.session.locked_controllers().offered_bytes_per_frame > 0.0,
            "a delta is the steady-state cost the ABR's idle-ramp guard reads"
        );
    }

    #[test]
    fn a_keyframe_clears_every_token_acked_before_it_and_still_records_its_own() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        harness.session.locked_controllers().ltr.record_ltr_frame(900, 5);
        let frame = FinishedFrame {
            avcc: &[3; 30],
            keyframe: true,
            crisp: false,
            ltr_token: Some(11),
            acked_anchored: false,
        };
        wire_frame(&harness.session, &frame);
        let controllers = harness.session.locked_controllers();
        assert_eq!(
            controllers.ltr.token_for(900),
            None,
            "an IDR clears the decoder's whole reference world, long-term references included"
        );
        assert_eq!(
            controllers.ltr.token_for(0),
            Some(11),
            "the keyframe's OWN token is post-IDR and still valid, so the reset comes first"
        );
    }

    #[test]
    fn a_keyframe_is_recorded_for_the_delivery_keyed_recovery_cooldown_and_a_delta_is_not() {
        let delta = harness(|_| {});
        flowing(&delta.session);
        wire_frame(&delta.session, &finished(&[1; 30], false));
        let now = delta.session.now();
        assert_eq!(
            delta
                .session
                .locked_controllers()
                .recovery_idr
                .decide(now, None, 0.0),
            IdrVerdict::Grant,
            "with no keyframe in flight a recovery request is admitted"
        );

        let keyframe = harness(|_| {});
        flowing(&keyframe.session);
        wire_frame(&keyframe.session, &finished(&[1; 30], true));
        let now = keyframe.session.now();
        assert_eq!(
            keyframe
                .session
                .locked_controllers()
                .recovery_idr
                .decide(now, None, 0.0),
            IdrVerdict::SuppressInFlight,
            "the keyframe just sent is the answer the request is already getting"
        );
    }

    #[test]
    fn the_retransmit_log_holds_exactly_the_datagrams_that_went_out() {
        let harness = harness(|gates| gates.nack_enabled = true);
        flowing(&harness.session);
        wire_frame(&harness.session, &finished(&[4; 3000], true));
        let log = harness.session.retransmit.as_ref().expect("the gate is on");
        assert_eq!(log.frame_count(), 1);
        // Asked for by the indices the FRAGMENTS carry, not by their position in the send order:
        // parity fragments continue the numbering past the data ones, and the interleaver moves
        // both.
        let indices: Vec<u16> = harness
            .sent()
            .iter()
            .map(|datagram| {
                FrameFragmentHeader::decode(datagram)
                    .expect("a datagram this host just encoded")
                    .0
                    .frag_index
            })
            .collect();
        let restored: Vec<Vec<u8>> = log
            .fragments(0, &indices)
            .into_iter()
            .map(|outgoing| outgoing.bytes)
            .collect();
        let mut sent = harness.sent();
        sent.sort_unstable();
        let mut restored = restored;
        restored.sort_unstable();
        assert_eq!(
            restored, sent,
            "a NACK is answered with the bytes the client missed, not with a re-encode"
        );
    }

    #[test]
    fn a_keyframe_is_duplicated_only_while_the_fast_attack_window_is_open() {
        let quiet = harness(|_| {});
        flowing(&quiet.session);
        wire_frame(&quiet.session, &finished(&[5; 30], true));
        let clean = quiet.sent().len();

        let lossy = harness(|_| {});
        flowing(&lossy.session);
        let now = lossy.session.now();
        lossy
            .session
            .locked_counters()
            .arm_fast_attack(now, KF_DUP_FAST_ATTACK_WINDOW);
        wire_frame(&lossy.session, &finished(&[5; 30], true));
        assert_eq!(
            lossy.sent().len(),
            clean * 2,
            "the duplicate is the same ordered list a second time, so a burst cannot take both"
        );
        assert!(
            lossy.frame_ids().iter().all(|id| *id == 0),
            "the duplicate reuses the frame id, which is what lets the client dedupe it"
        );
    }

    #[test]
    fn a_second_keyframe_inside_the_throttle_interval_is_not_duplicated_again() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        let now = harness.session.now();
        harness
            .session
            .locked_counters()
            .arm_fast_attack(now, KF_DUP_FAST_ATTACK_WINDOW);
        wire_frame(&harness.session, &finished(&[5; 30], true));
        let after_first = harness.sent().len();
        wire_frame(&harness.session, &finished(&[6; 30], true));
        let second = harness.sent().len() - after_first;
        assert_eq!(
            second * 2,
            after_first,
            "a recovery storm must not be byte-amplified into the congestion it is recovering from"
        );
    }

    #[test]
    fn the_duplicate_is_time_separated_by_the_static_gap_and_not_by_the_frames_own_pace() {
        // The separation is read from the gate rather than from the plan, so a link fast enough to
        // compute a near-zero adaptive gap still separates the two copies.
        let harness = harness(|gates| {
            gates.pace_gap_nanos = 2_000_000;
            gates.pacing_adaptive = true;
        });
        flowing(&harness.session);
        let now = harness.session.now();
        harness
            .session
            .locked_counters()
            .arm_fast_attack(now, KF_DUP_FAST_ATTACK_WINDOW);
        let started = harness.session.now();
        wire_frame(&harness.session, &finished(&[5; 30], true));
        assert!(
            harness.session.now() - started >= 0.002,
            "the inline drain pays the leading delay the duplicate carries"
        );
    }

    #[test]
    fn a_scroll_hint_reaches_the_client_only_while_media_flows() {
        let harness = harness(|_| {});
        let pump = CapturePump::new(&harness.session, &encoder(), None);
        pump.scroll(ScrollHint::restored(0, 120, 100, 900));
        assert!(
            harness.sent().is_empty(),
            "a hint for a session with no client is a datagram into a retired lane"
        );
        flowing(&harness.session);
        pump.scroll(ScrollHint::restored(0, 120, 100, 900));
        assert_eq!(
            harness.sent().len(),
            1,
            "a per-frame hint is sent once and never duplicated"
        );
    }

    #[test]
    fn a_capture_death_before_the_generation_is_adopted_tears_nothing_down() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        let (_generation, recorder) = install(&harness.session, 0);
        let pump = CapturePump::new(&harness.session, &encoder(), None);
        pump.capture_failed();
        assert_eq!(
            recorder.stops.load(Ordering::Relaxed),
            0,
            "a pump that names no live set must not decide the session's fate"
        );
        assert!(harness.session.locked_streaming().is_some());
    }

    #[test]
    fn a_capture_death_of_a_superseded_generation_leaves_the_newer_owner_alone() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        let (generation, _first) = install(&harness.session, 0);
        let pump = CapturePump::new(&harness.session, &encoder(), None);
        pump.adopt_generation(generation);
        // A resize installs the next set; the old capturer's death arrives afterwards.
        let (_newer, recorder) = install(&harness.session, generation);
        pump.capture_failed();
        assert_eq!(
            recorder.stops.load(Ordering::Relaxed),
            0,
            "a newer owner owns the session's fate"
        );
    }

    #[test]
    fn a_live_capture_death_says_goodbye_twice_and_stops_the_session() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        let (generation, recorder) = install(&harness.session, 0);
        let pump = CapturePump::new(&harness.session, &encoder(), None);
        pump.adopt_generation(generation);
        pump.capture_failed();
        assert!(
            settle(|| recorder.stops.load(Ordering::Relaxed) == 1),
            "the teardown runs OFF the frame queue, because stopping the capturer joins it"
        );
        assert!(
            settle(|| harness.sent().len() >= 2),
            "one unacked UDP datagram is not a delivery, so the goodbye goes twice"
        );
        assert!(
            settle(|| harness.session.locked_streaming().is_none()),
            "a visible disconnect beats a pane frozen on its last decoded frame"
        );
    }

    #[test]
    fn the_send_gap_stamp_advances_on_every_frame_so_the_probe_measures_frames_and_not_sessions() {
        let harness = harness(|_| {});
        flowing(&harness.session);
        assert!(harness.session.locked_counters().last_send_at.abs() < f64::EPSILON);
        wire_frame(&harness.session, &finished(&[1; 30], false));
        let first = harness.session.locked_counters().last_send_at;
        assert!(
            first > 0.0,
            "the stamp is the session's own clock, never a second one"
        );
        wire_frame(&harness.session, &finished(&[1; 30], false));
        assert!(
            harness.session.locked_counters().last_send_at >= first,
            "the probe measures the gap between two frames, so every frame restamps it"
        );
    }

    #[test]
    fn the_fec_tier_is_the_configured_baseline_while_no_ladder_state_exists() {
        let shipped = harness(|_| {});
        assert_eq!(
            wire_tier(&shipped.session, adaptive_fec::DEFAULT_TIER),
            adaptive_fec::DEFAULT_TIER,
            "the shipped scheme is single-parity, so the multi-loss term forces nothing"
        );
        let bare = harness(|gates| gates.fec_disabled = true);
        assert_eq!(
            wire_tier(&bare.session, adaptive_fec::DEFAULT_TIER),
            adaptive_fec::DEFAULT_TIER,
            "a session with no FEC at all still stamps the baseline tier on the wire"
        );
    }

    #[test]
    fn the_ladder_tier_reaches_the_wire_only_while_the_ladder_gate_is_on() {
        // The whole point of threading the fold's tier down here: with the gate ON the stepped
        // value must reach the wire unchanged, and with it OFF a tier left over from a session
        // that has since turned adaptive FEC off must NOT keep being stamped.
        let stepped = adaptive_fec::PARITY_TIER_BURST;
        let on = harness(|gates| gates.adaptive_fec_enabled = true);
        assert_eq!(
            wire_tier(&on.session, stepped),
            stepped,
            "the gate is on, so the tier the fold stepped is the tier the frame carries"
        );
        let off = harness(|gates| gates.adaptive_fec_enabled = false);
        assert_eq!(
            wire_tier(&off.session, stepped),
            adaptive_fec::DEFAULT_TIER,
            "the gate is off, so the stale ladder tier is discarded for the baseline"
        );
    }
}
