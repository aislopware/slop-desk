//! The session's RESIZE: one client-requested window size, and the rebuild that serves it.
//!
//! The Swift host session's `applyResize(width:height:epoch:)` and the two recovery helpers beneath
//! it, `rollBackWindow` and `restartOldSizeCapture`.
//!
//! ## Why a resize is not a bring-up
//! [`crate::session_capture::Session::start_capture`] may assume nothing is running. A resize may
//! not: it replaces the capture stream and the encoder UNDER a session that keeps streaming, and
//! four things deliberately SURVIVE the replacement, each because the client will never re-send it:
//!
//! * **The audio lane.** Its tag-6 sequence is monotone across capturer rebuilds and the client
//!   LATE-DROPS on that counter, so a lane respawned here would go silent for the rest of the
//!   session. It is carried over by [`CaptureStream::hand_over`], which is the whole reason that
//!   door exists.
//! * **The client's latched audio wish**, re-asserted onto the new capturer at the end — a fresh
//!   capturer's forwarding gate is down by construction, so without that step a resize would mute a
//!   client that had asked for audio and never asks again.
//! * **The user's stream settings.** The bitrate ceiling is re-layered through
//!   [`Controllers::seed_for_encoder`]'s own parameter, and the cadence cap through
//!   [`effective_fps`] at the end.
//! * **The FPS governor**, which is NOT re-minted. `session_wiring`'s `initial_governor` is a free
//!   function precisely so this path cannot call it: the governor's ladder position is knowledge
//!   about the LINK, and a resize does not change the link.
//!
//! ## The decisions are not here
//! The clamp is [`clamp_capture_size`]'s, the rate is [`live_bitrate::target_bitrate`]'s, the
//! cadence composition is [`effective_fps`]'s, the AX write and its display re-anchor are
//! [`crate::windowplace::resize`]'s, and the in-place-versus-restart verdict is
//! `slopdesk_video::capture_config::can_resize_in_place`'s. What is left here is order.
//!
//! ## The two paths, and why one of them cannot be trusted alone
//! [`Session::swap_in_place`] reconfigures the LIVE `SCStream` to the new size and swaps a new
//! encoder under it, saving the framework's ~120 ms stream spin-up — the resize freeze. It is
//! selected by [`takes_in_place`], which is `SLOPDESK_INPLACE_RESIZE` composed with the capture's
//! own shape through `slopdesk_video::capture_config::can_resize_in_place`, and it is a fast path
//! and nothing more: EVERY way it can decline — gate off, a per-window capture, a poller-owned
//! union crop, a framework that refused the new configuration — answers `None` and falls through
//! to [`Session::rebuild_live_set`] below, with a set that is still capturing at the old size.
//! That is what the Swift's own fallback did, and it is why correctness never rides on the fast
//! path: the restart path serves every resize the fast one declines, byte for byte as it always
//! did.
//!
//! The piece that used to be missing is [`crate::session_pump::EncoderSlot`]. A
//! `VTCompressionSession` cannot change dimensions and a `Capturer`'s event sink is fixed at
//! construction, so a stream that is never restarted needs its pump RE-POINTED at a new encoder
//! between frames — the Swift's `SwappableEncoder` box, as one lock and one swap. The order the
//! swap happens in is [`crate::session::CaptureStream::resize_in_place`]'s, because the swap and
//! the reconfigure have to succeed or fail together.
//!
//! ⚠️ GUI + TCC ONLY from [`Session::resize_capture`]'s geometry read down: a window server, an
//! Accessibility grant and a Screen-Recording grant. The two doors the fast path added are the
//! exceptions and deliberately so — [`takes_in_place`] is a verdict over values, and
//! [`Session::swap_in_place`] takes the encoder it installs as a PARAMETER rather than opening
//! one, so the order it keeps is reachable from a test with an unopened encoder and a recorded
//! capture stream. [`Session::open_encoder`] is the framework half, split out for exactly that
//! reason.

use std::sync::Arc;

use slopdesk_apple_sck::CaptureRegion;
use slopdesk_video::audio_source::{CHANNEL_COUNT, SAMPLE_RATE};
use slopdesk_video::capture_config::can_resize_in_place;
use slopdesk_video::congestion::{CongestionConfig, LiveCongestionController};
use slopdesk_video::fps_governor::FpsGovernor;
use slopdesk_video::geometry::{VideoRect, VideoSize};
use slopdesk_video::host_gates::HostGates;
use slopdesk_video::live_bitrate::{self, BITS_PER_PIXEL_KEY};
use slopdesk_video::qp_control::{QpConfig, QpController};
use slopdesk_video::session_state::{clamp_capture_size, effective_fps};
use slopdesk_video::video_control::VideoControlMessage;

use crate::capture::{CaptureEvents, Capturer, Shape as CaptureShape};
use crate::diag;
use crate::encode::{EncodedFrameSink, Encoder, Shape as EncodeShape, const_qp};
use crate::session::{CaptureStream, Session};
use crate::session_capture::pixels;
use crate::session_pump::{CapturePump, EncodedPump};
use crate::session_wiring::{Controllers, Target};
use crate::windowplace::{self, AccessibilityTree};

/// The live set a rebuild replaces.
///
/// One value rather than three parameters because the three are only ever read together, and
/// because the generation is what makes the other two safe to touch: a rebuild that resumes to find
/// it stale must install nothing, and neither handle below it means anything after that.
pub(crate) struct Replaced<'a> {
    /// The stream being retired — the audio lane's donor, and the thing that gets stopped.
    pub(crate) capture: &'a Arc<dyn CaptureStream>,
    /// The encoder being retired, drained once no capturer can reach it any more.
    pub(crate) encoder: &'a Arc<Encoder>,
    /// The install token both of the above were current as of.
    pub(crate) generation: u64,
}

/// How far a rebuild got, and therefore what the caller still owes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Rebuilt {
    /// Installed and capturing at the requested size. The only outcome that may be acknowledged.
    Live,
    /// The encoder refused to open. NOTHING was stopped — the outgoing set is still capturing at
    /// the old size, so the only debt is the window, which has already moved.
    EncoderRefused,
    /// The new `SCStream` refused to start, AFTER the outgoing stream was stopped. The session is
    /// left with no capture at all, which is the one outcome that has to be recovered from.
    StreamRefused,
    /// A newer owner is live. Nothing is owed and nothing may be acknowledged — see
    /// [`crate::session_wiring::Live::is_current`].
    Superseded,
}

impl Session {
    /// Applies one `ResizeCapture` effect: resize the real window, then re-capture it.
    ///
    /// The steps are the Swift's, in the Swift's order, and each note says what breaks if the step
    /// moves. Two orderings differ from the original and both are noted where they sit.
    ///
    /// ⚠️ KNOWN RESIDUAL, carried over verbatim from the Swift (re-ack edge): the state machine
    /// commits the capture size and `last_resize_epoch` SYNCHRONOUSLY before this effect runs. On a
    /// refused or rolled-back resize below, the WINDOW and the capture go back to the old size but
    /// the machine is NOT corrected, so it still reports the REQUESTED one and a duplicate hello's
    /// re-ack would echo that. The machine is deliberately left alone: a blind rollback risks an
    /// epoch/size desync worse than a cosmetic echo, and the next real resize corrects it anyway.
    pub(crate) fn resize_capture(self: &Arc<Self>, width: u16, height: u16, epoch: u32) {
        // 1. STILL STREAMING, WITH A LIVE SET. A `bye`, a reap or a stop can have raced in between
        //    the state machine emitting this effect and this running. Dropped with no ack, because
        //    an ack for a resize that never happened would move the client's own capture size.
        let Some((capture, encoder, generation)) = self.live_set() else {
            return;
        };
        let outgoing = Replaced {
            capture: &capture,
            encoder: &encoder,
            generation,
        };

        // 2. A WINDOW TARGET. The state machine REJECTS a display resize — a display does not have
        //    a size to write — so this is defensive, and it is a guard rather than an `expect`
        //    because a daemon that panics on an unreachable branch is worse than one that ignores a
        //    message it cannot serve.
        let Target::Window { id, pid, .. } = self.spec.target else {
            return;
        };

        // 3. THE PRE-RESIZE POINT SIZE, READ BEFORE THE WINDOW MOVES. Every abort below this line
        //    happens with the window ALREADY at the new size, and a window whose aspect no longer
        //    matches the running capture is a distorted stream with no ack to explain it. This is
        //    the only moment the old size can still be observed, so it is read here whether or not
        //    it is ever used.
        let pre_resize = self.window_bounds_cg().size;

        // 4. THE AX RESIZE, AND THE SIZE THE WINDOW ACTUALLY TOOK. A fixed-size window, a sheet or
        //    a hung app answers `None`: ABORT, keep the old encoder, send no ack. The window has
        //    not moved on that path — the write is what failed — so there is nothing to roll back.
        let Some(achieved) = resize_window(id, pid, VideoSize::new(f64::from(width), f64::from(height)))
        else {
            return;
        };

        // 5. THE SUPERSEDE RE-CHECK, BECAUSE STEP 4 BLOCKED. The accessibility write is a
        //    cross-process round trip, and a teardown or a newer resize can complete inside it.
        //    Asked BEFORE anything is built so a dead session costs one geometry read rather than a
        //    `VTCompressionSession`.
        if !self.resize_is_current(generation, epoch) {
            return;
        }

        // 6. THE ACHIEVED SIZE ON THE WIRE'S OWN TERMS, THEN IN PIXELS. The clamp is the rules
        //    crate's and the bounds are the wire's — a size the ack cannot carry is a size the
        //    client cannot adopt. The pixel conversion is `session_capture`'s own, not a second
        //    spelling of it: these numbers are pinned by `golden/golden_vectors.json`.
        let (achieved_width, achieved_height) = clamp_capture_size(
            achieved,
            VideoSize::new(1.0, 1.0),
            VideoSize::new(f64::from(u16::MAX), f64::from(u16::MAX)),
        );
        let pixel_width = pixels(achieved_width, self.spec.capture_scale);
        let pixel_height = pixels(achieved_height, self.spec.capture_scale);

        // 7. THE REBUILD, IN PLACE WHERE IT CAN BE. The fast path is asked FIRST and every way it
        //    declines is a `None` that has touched nothing, so the restart below is reached with
        //    the same live set it would have had if the fast path did not exist — which is what
        //    makes the gate a pure latency knob rather than a second correctness story.
        let rebuilt = self
            .swap_in_place(&outgoing, epoch, pixel_width, pixel_height)
            .unwrap_or_else(|| self.rebuild_live_set(&outgoing, id, epoch, pixel_width, pixel_height, None));
        match rebuilt {
            // 8. THE ACK, LAST AND ONLY HERE. It may reach the client just BEFORE the first new-size
            //    keyframe, because starting a stream is not waiting for a frame from it. That is safe and it
            //    is the CLIENT's invariant, not this one's: adoption is frame-gated on a decoded buffer at
            //    the new size, never on ack receipt.
            Rebuilt::Live => {
                self.send_control(&VideoControlMessage::ResizeAck {
                    capture_width: achieved_width,
                    capture_height: achieved_height,
                    epoch,
                });
            },
            // The old set never stopped, so the stream is still live at the OLD size and the only
            // thing out of step is the window. Put it back and degrade to no-resize.
            Rebuilt::EncoderRefused => roll_back_window(id, pid, pre_resize),
            // The old set is stopped and nothing replaced it: frames have stopped and NOTHING else
            // can restart them — a keyframe request and the heartbeat are both no-ops on a stream
            // that never came up. Roll the window back FIRST, so the rebuild below captures a
            // window that already matches the size it is about to be captured at.
            Rebuilt::StreamRefused => {
                roll_back_window(id, pid, pre_resize);
                let recovery_width = pixels(clamped_axis(pre_resize.width), self.spec.capture_scale);
                let recovery_height = pixels(clamped_axis(pre_resize.height), self.spec.capture_scale);
                // The SAME rebuild at the OLD size. `outgoing` is still the installed set —
                // stopping it twice and draining it twice are both no-ops — so the recovery needs
                // no path of its own. Its own failure is NOT recovered from a second time: a host
                // that cannot start a stream at either size has a problem no third attempt fixes,
                // and the idle reaper is what reclaims the session. No ack either way.
                let _recovered =
                    self.rebuild_live_set(&outgoing, id, epoch, recovery_width, recovery_height, None);
            },
            // A newer owner is live and owns everything this path would have touched.
            Rebuilt::Superseded => {},
        }
    }

    /// The installed set and the token it is current as of, or `None` when nothing is streaming.
    ///
    /// Both locks are taken and released in the house order — state, then streaming — and the
    /// handles are CLONED out, because everything the caller does with them blocks on a framework.
    pub(crate) fn live_set(&self) -> Option<(Arc<dyn CaptureStream>, Arc<Encoder>, u64)> {
        if !self.locked_state().media_flowing() {
            return None;
        }
        let streaming = self.locked_streaming();
        let set = streaming.as_ref().and_then(|live| {
            Some((
                live.live.capture.clone()?,
                live.live.encode.clone()?,
                live.live.generation,
            ))
        });
        // Dropped HERE, not at the end of the function: everything the caller does with these
        // handles blocks on a framework, and the streaming lock is what a report fold and a reap
        // both want. Holding it one statement longer than the clone needs it would put a
        // `VTCompressionSession` open on the far side of it.
        drop(streaming);
        set
    }

    /// Whether this resize may still act: the session flows, `generation` is installed, and no
    /// newer epoch has been committed.
    ///
    /// The epoch half is `>=`, not [`slopdesk_video::session_state::is_stale_epoch`], and the
    /// difference is deliberate: that door answers the PRE-commit question — may this request be
    /// admitted at all — and by the time an effect runs the machine has already committed THIS
    /// epoch as the last one, so `is_stale_epoch` would reject every resize including the one it
    /// was asked about. What is left to check here is only that a NEWER one has not landed since.
    fn resize_is_current(&self, generation: u64, epoch: u32) -> bool {
        let (flowing, last_applied) = {
            let state = self.locked_state();
            (state.media_flowing(), state.last_resize_epoch())
        };
        if !flowing || epoch < last_applied {
            return false;
        }
        self.locked_streaming()
            .as_ref()
            .is_some_and(|live| live.live.is_current(generation))
    }

    /// Opens a fresh encoder at `pixel_width` × `pixel_height`, answering it and the ceiling it
    /// was opened at.
    ///
    /// BOTH resize paths' first act, and deliberately the same act: the ceiling is a function of
    /// the resolution, so two spellings of this would let an in-place resize and a restart at the
    /// same size open two differently-rated encoders and nothing downstream would notice. The
    /// ceiling is answered rather than re-derived by the caller for the same reason — it is what
    /// the controllers are re-seeded to once this encoder is the installed one.
    ///
    /// `None` is a refused open, which by contract has stopped NOTHING: the outgoing set is still
    /// capturing at the old size and the only debt is the window.
    ///
    /// ⚠️ Needs `VideoToolbox`. This is the framework half of both paths, split out so the ORDER
    /// either of them keeps is reachable from a test that hands in an unopened encoder.
    fn open_encoder(self: &Arc<Self>, pixel_width: i32, pixel_height: i32) -> Option<(Arc<Encoder>, i64)> {
        let bits_per_pixel =
            live_bitrate::bits_per_pixel_from_env(self.overlay.get(BITS_PER_PIXEL_KEY).as_deref());
        let ceiling = live_bitrate::target_bitrate(
            i64::from(pixel_width),
            i64::from(pixel_height),
            self.spec.fps,
            self.spec.bitrate,
            bits_per_pixel,
        );
        let sink: Arc<dyn EncodedFrameSink> = EncodedPump::new(self);
        let mut encoder = Encoder::new(
            EncodeShape {
                // The SAME conversion `EncoderSlot::swap` arms its size guard with, so the encoder
                // and the buffer size it will accept cannot be two different numbers.
                width: usize::try_from(pixel_width).unwrap_or_default(),
                height: usize::try_from(pixel_height).unwrap_or_default(),
                bitrate: ceiling,
                fps: self.spec.fps,
                full_range: self.gates.full_range,
                ltr_enabled: self.gates.ltr_enabled,
            },
            Some(sink),
            &self.overlay,
        );
        if encoder.open().is_err() {
            return None;
        }
        Some((Arc::new(encoder), ceiling))
    }

    /// The IN-PLACE resize: a new encoder swapped under a capture stream that is never restarted.
    ///
    /// `None` is NOT TAKEN, and it is the only answer that leaves the caller work to do — see the
    /// module note. Three things produce it and none of them has changed anything: the verdict
    /// refused ([`takes_in_place`]), the framework refused the new configuration, or the encoder
    /// refused to open — that last one answers [`Rebuilt::EncoderRefused`] rather than `None`
    /// because a restart would only open the same encoder and fail the same way, and the window
    /// roll-back is owed either way.
    ///
    /// The order, and what breaks if a step moves:
    ///
    /// 1. **The verdict, before a `VTCompressionSession` is opened.** An ineligible resize must
    ///    cost nothing at all, because the restart path is about to open its own.
    /// 2. **The encoder, before the stream is told anything.** A refused open must leave the live
    ///    stream capturing at the old size, which is only true while nothing has been swapped.
    /// 3. **The forced IDR, armed on the live capturer.** Belt and braces: a fresh
    ///    `VTCompressionSession`'s first frame is an IDR by construction, which is the real
    ///    guarantee — the capturer is NOT rebuilt here, so its own first-frame anchor does not
    ///    fire. The latch's position relative to the swap is not load-bearing for that reason, and
    ///    it sits here because this is the module that owns the order.
    /// 4. **The swap and the reconfigure, as ONE act.** Both or neither: see
    ///    [`crate::session::CaptureStream::resize_in_place`], which puts the old encoder back
    ///    before it reports a refusal.
    /// 5. **The supersede re-check, because step 4 blocked on the framework.** A teardown or a
    ///    newer resize can complete inside it, and only the newest may install.
    /// 6. **Drain the outgoing encoder, AFTER the swap.** In that order, because after the swap no
    ///    frame routes to it any more — draining it first would race a frame still on its way in.
    ///    There is no capture half to stop: that is the whole point.
    /// 7. **Re-anchor what the new encoder does not inherit.** Three of
    ///    [`Self::rebuild_live_set`]'s four, and never the fourth: the capturer is the SAME object,
    ///    so its governed-fps latch, its audio forwarding gate and its heartbeat are already right,
    ///    and re-asserting them would be re-asserting them onto themselves.
    ///
    /// ⚠️ Steps 2 and 4 need the frameworks. Steps 1 and 3–7 do not.
    fn swap_in_place(
        self: &Arc<Self>,
        outgoing: &Replaced<'_>,
        epoch: u32,
        pixel_width: i32,
        pixel_height: i32,
    ) -> Option<Rebuilt> {
        if !takes_in_place(&self.gates, outgoing.capture) {
            return None;
        }
        let Some((encoder, ceiling)) = self.open_encoder(pixel_width, pixel_height) else {
            return Some(Rebuilt::EncoderRefused);
        };
        self.install_in_place(outgoing, &encoder, ceiling, epoch, pixel_width, pixel_height)
    }

    /// Steps 3 to 7 of [`Self::swap_in_place`], over an encoder that is already open.
    ///
    /// Split at exactly this line because everything above it needs `VideoToolbox` and nothing
    /// below it does: the reconfigure is the capture stream's, the install is two locks, and the
    /// re-anchor is a rules-crate fold plus two property writes that a never-opened encoder
    /// ignores. That makes the ORDER — which is the only thing this module owns — a value a test
    /// can read.
    fn install_in_place(
        self: &Arc<Self>,
        outgoing: &Replaced<'_>,
        encoder: &Arc<Encoder>,
        ceiling: i64,
        epoch: u32,
        pixel_width: i32,
        pixel_height: i32,
    ) -> Option<Rebuilt> {
        outgoing.capture.request_keyframe();
        if let Err(refused) = outgoing
            .capture
            .resize_in_place(encoder, pixel_width, pixel_height)
        {
            // The live stream kept the OLD configuration and the old encoder is back under it, so
            // the only cost of this attempt is the one `VTCompressionSession` that is dropped
            // here. Said out loud under the debug gate because the visible symptom — a resize that
            // paid the ~120 ms freeze — has no other explanation on the wire.
            if self.gates.debug_stderr {
                diag::say(&format!(
                    "in-place resize declined ({refused}) — restarting the stream"
                ));
            }
            return None;
        }
        if !self.install_swapped(encoder, outgoing.generation, epoch) {
            // A newer owner is live. The stream it owns is the one that was just reconfigured, so
            // nothing is stopped and nothing is put back — see `Rebuilt::Superseded`.
            return Some(Rebuilt::Superseded);
        }
        // The drain, once no capturer can reach the outgoing encoder any more.
        outgoing.encoder.complete_frames();
        let user_ceiling = self.user_bitrate_ceiling();
        let user_cap = self.user_fps_cap();
        let quantiser = const_qp(&self.overlay);
        let (actuate, governed) = {
            let mut controllers = self.locked_controllers();
            // A new encoder session holds ZERO acknowledged long-term references, whether the
            // stream under it was restarted or not.
            controllers.reset_ltr_for_new_encoder();
            let seeded = reseed(&mut controllers, self, ceiling, quantiser, user_ceiling);
            let governed = controllers
                .fps
                .as_ref()
                .map_or(self.spec.fps, FpsGovernor::current_fps);
            drop(controllers);
            (seeded, governed)
        };
        if let Some(target) = actuate {
            let _actuated = encoder.set_live_bitrate(target);
        }
        // THE CADENCE, on the ENCODER only. `rebuild_live_set` writes it to both surfaces because
        // its capturer is new and started at the base rate; this capturer never stopped and is
        // still holding the governed step it was last given, so writing it again would be writing
        // a value onto itself.
        encoder.set_expected_frame_rate(effective_fps(governed, user_cap));
        Some(Rebuilt::Live)
    }

    /// Installs `encoder` under the SAME capture stream and the SAME generation.
    ///
    /// The in-place path's [`Self::install_rebuilt`], and the difference between the two is the
    /// generation: nothing here replaced the SET, so bumping it would tell the live capture pump
    /// it had been superseded — see [`crate::session_wiring::Live::replace_encode`], which owns
    /// that reasoning. Answers whether the install happened.
    fn install_swapped(&self, encoder: &Arc<Encoder>, generation: u64, epoch: u32) -> bool {
        if !self.resize_is_current(generation, epoch) {
            return false;
        }
        let mut streaming = self.locked_streaming();
        let installed = streaming
            .as_mut()
            .is_some_and(|live| live.live.replace_encode(generation, Arc::clone(encoder)));
        // Dropped explicitly: the caller's next act is a framework drain, and a report fold on
        // another thread must not wait behind it.
        drop(streaming);
        installed
    }

    /// Replaces `outgoing` with a fresh encoder and capture stream at `pixel_width` ×
    /// `pixel_height`.
    ///
    /// `region` is the DIALOG-EXPAND crop, `None` for the plain window frame — the one parameter a
    /// resize never sets and [`crate::session_geometry`] always does. It reaches the framework at
    /// step 4 and nowhere else: `pixel_width` × `pixel_height` must already be its size times the
    /// capture scale, which is the caller's obligation because only the caller knows which
    /// rectangle it measured.
    ///
    /// The order is the whole function, and it is the Swift's with ONE change, at step 4:
    ///
    /// 1. **The encoder, opened before anything is stopped.** A failed open must leave the outgoing
    ///    stream capturing — degrade to no-resize, never to a dead session — and that is only true
    ///    while nothing has been retired yet.
    /// 2. **The audio lane, then the pump, then the capturer.** Fixed by their own dependencies:
    ///    the pump is what the capturer delivers into and it needs the lane and the encoder to
    ///    exist first. The lane is the OUTGOING set's; see the module note for what respawning it
    ///    would cost.
    /// 3. **Stop the outgoing capture half, then drain its encoder.** In that order, so the drain
    ///    cannot race a frame still on its way in. `stop_capture_only` rather than the full stop:
    ///    the successor built at step 2 already holds the lane.
    /// 4. **Start the new stream.** ⚠️ The Swift installed before starting; this starts before
    ///    installing, which is `start_capture`'s own order and buys the post-start supersede guard
    ///    for free — a stream that is not installed yet cannot be clobbered, so the check at step 6
    ///    is the ONLY one needed and there is no orphan to tear down on the ordinary path. What it
    ///    does NOT permit is starting before step 3: two live capturers would encode two sizes into
    ///    one send lane, and nothing downstream filters by generation.
    /// 5. **Hand over**, which mints the successor over the started stream.
    /// 6. **Install under the generation**, which is the last point a supersede can be caught.
    /// 7. **Re-anchor everything the new build does not inherit**, then arm the heartbeat.
    ///
    /// ⚠️ Steps 1 and 4 need a window server and both TCC grants.
    pub(crate) fn rebuild_live_set(
        self: &Arc<Self>,
        outgoing: &Replaced<'_>,
        window_id: u32,
        epoch: u32,
        pixel_width: i32,
        pixel_height: i32,
        region: Option<CaptureRegion>,
    ) -> Rebuilt {
        // 1. THE NEW ENCODER, BUILT AND OPENED BEFORE ANYTHING IS SHARED — `start_capture` step 3's
        //    reasoning, unchanged. The new resolution has a new ceiling; the controllers are
        //    re-anchored to it at step 7, once this encoder is the installed one.
        let Some((encoder, ceiling)) = self.open_encoder(pixel_width, pixel_height) else {
            return Rebuilt::EncoderRefused;
        };

        // 2. THE LANE, THE PUMP, THE CAPTURER. The tap's SHAPE is derived from whether a lane
        //    exists rather than from a second read of `SLOPDESK_AUDIO`: the lane's existence IS
        //    that gate's answer, resolved once at bring-up, and a rebuild that re-read the table
        //    could build a tap the lane cannot serve. Gates resolve once per launch — `docs/46`.
        let audio = outgoing.capture.audio_lane();
        let pump = CapturePump::new(self, &encoder, audio.clone());
        // Concrete parameter, so the unsizing happens at the binding rather than inside an
        // inference that would look for an `Arc<dyn CaptureEvents>` to clone.
        let events: Arc<dyn CaptureEvents> = Arc::<CapturePump>::clone(&pump);
        // Zero on BOTH axes is how a `Capturer` is told there is no audio track to add — the two
        // move together, which is why they are decided together rather than one per field.
        let (audio_sample_rate, audio_channel_count) = if audio.is_some() {
            (
                i32::try_from(SAMPLE_RATE).unwrap_or(i32::MAX),
                i32::try_from(CHANNEL_COUNT).unwrap_or(i32::MAX),
            )
        } else {
            (0, 0)
        };
        let capturer = Capturer::new(
            CaptureShape {
                fps: i32::try_from(self.spec.fps).unwrap_or(i32::MAX),
                capture_scale: self.spec.capture_scale,
                full_range: self.gates.full_range,
                // The same low-latency default a bring-up takes: display-anchored capture is a
                // whole 60 Hz slot lower glass-to-glass, and occlusion-proof.
                prefer_display_anchored: true,
                audio_sample_rate,
                audio_channel_count,
            },
            events,
            &self.overlay,
        );

        // 3. RETIRE THE OUTGOING SET'S CAPTURE HALF, AND DRAIN ITS ENCODER. The stop first, so no
        //    further frame can enter the encoder being drained; the drain second, so whatever it
        //    already holds is flushed to the wire instead of dying with the session. The audio lane
        //    survives both — it is the successor's now.
        outgoing.capture.stop_capture_only();
        outgoing.encoder.complete_frames();

        // 4. START THE NEW STREAM. ⚠️ Blocks for the framework's whole spin-up — this is the resize
        //    freeze the in-place path would have avoided. A refusal here is FATAL to the rebuild,
        //    in contrast to `start_capture` step 7 where installing a dead stream is right: there,
        //    the alternative is a session with nothing to stop; here, the caller has a size to fall
        //    back to and a live session to restore.
        if capturer
            .start_window(window_id, pixel_width, pixel_height, region)
            .is_err()
        {
            return Rebuilt::StreamRefused;
        }

        // 5. THE SUCCESSOR. `None` means the outgoing stream was not one a rebuild can succeed —
        //    unreachable for a live set, and reported as a refusal rather than assumed away.
        let Some(successor) = outgoing.capture.hand_over(capturer, pump.slot()) else {
            return Rebuilt::StreamRefused;
        };

        // 6. INSTALL, UNDER THE GENERATION. The last moment a supersede can be caught, and the
        //    reason step 4 comes before it: a stream that was started but never installed is
        //    stopped here and orphans nothing, whereas one installed before it started would have
        //    to be un-installed from under whoever replaced it.
        let Some((generation, audio_enabled)) =
            self.install_rebuilt(&successor, &encoder, outgoing.generation, epoch)
        else {
            // The CAPTURE half only. A newer owner reached this set through `hand_over` and took
            // the audio lane with it, so the full stop would silence a lane that is live.
            successor.stop_capture_only();
            return Rebuilt::Superseded;
        };

        // 7. RE-ANCHOR WHAT THE NEW BUILD DOES NOT INHERIT. Four obligations, and the first three
        //    are what a fresh `VTCompressionSession` and a fresh `SCStream` know nothing about.
        //
        //    The pump learns its generation FIRST, because everything it reports — a capture death
        //    above all — is guarded on it, and a frame can arrive the instant step 4 returned.
        pump.adopt_generation(generation);
        let user_ceiling = self.user_bitrate_ceiling();
        let user_cap = self.user_fps_cap();
        let quantiser = const_qp(&self.overlay);
        let (actuate, governed) = {
            let mut controllers = self.locked_controllers();
            // A new encoder session holds ZERO acknowledged long-term references; an ack that
            // survived would name one the client no longer has.
            controllers.reset_ltr_for_new_encoder();
            let seeded = reseed(&mut controllers, self, ceiling, quantiser, user_ceiling);
            // The governor is READ, never re-minted — see the module note. `spec.fps` is the answer
            // when the gate is off, which is the same answer the encoder was built with.
            let governed = controllers
                .fps
                .as_ref()
                .map_or(self.spec.fps, FpsGovernor::current_fps);
            // Explicitly before the tail, so the two framework writes below are provably outside
            // the controller lock rather than outside it by where a brace happens to sit.
            drop(controllers);
            (seeded, governed)
        };
        // Actuated OUTSIDE the controller lock: the property write is a framework call, and a
        // report folding on another thread must not wait behind one.
        if let Some(target) = actuate {
            let _actuated = encoder.set_live_bitrate(target);
        }
        // THE CADENCE, on both surfaces and on NEITHER wire: the client's own cadence has not
        // changed, so this re-applies a live governed step to a capturer that started at the base
        // rate rather than announcing anything. The user cap composes here, by the same rules door
        // the governor's own actuation uses.
        let fps = effective_fps(governed, user_cap);
        successor.set_governed_fps(i32::try_from(fps).unwrap_or(i32::MAX));
        encoder.set_expected_frame_rate(fps);
        // THE CLIENT'S LATCHED AUDIO WISH. A fresh capturer's forwarding gate is down by
        // construction and the client sends its wish once, after the hello — so this latch is what
        // a rebuild re-asserts it from, and without this line audio stops at the first resize.
        successor.set_audio_forwarding(audio_enabled);
        // THE HEARTBEAT, last and only now: its tick pushes into whatever stream is INSTALLED, so
        // arming it before step 6 would arm it against a set that may never be installed.
        successor.arm_heartbeat(self);
        Rebuilt::Live
    }

    /// Installs `capture` and `encoder` if this rebuild is still the current one.
    ///
    /// Answers the new generation and the client's latched audio wish, or `None` for a rebuild that
    /// has been superseded. Two locks, in the house order, and the streaming one is authoritative:
    /// the state read above it can go stale in the gap, but a generation that is still installed
    /// under the streaming lock is one no other owner has replaced.
    fn install_rebuilt(
        &self,
        capture: &Arc<dyn CaptureStream>,
        encoder: &Arc<Encoder>,
        generation: u64,
        epoch: u32,
    ) -> Option<(u64, bool)> {
        if !self.resize_is_current(generation, epoch) {
            return None;
        }
        let mut streaming = self.locked_streaming();
        let installed = streaming.as_mut().and_then(|live| {
            if !live.live.is_current(generation) {
                return None;
            }
            // Read BEFORE the install, because the install is what makes this rebuild the live set
            // and the latch belongs to the session either way — the order only matters to a reader.
            let audio_enabled = live.audio_enabled;
            Some((
                live.live.install(Arc::clone(capture), Arc::clone(encoder)),
                audio_enabled,
            ))
        });
        // The install is the last thing this lock guards; step 7 re-anchors framework state and
        // must not do it holding the lock a report fold takes on another thread.
        drop(streaming);
        installed
    }
}

/// Whether this resize may reconfigure the live stream instead of rebuilding the set.
///
/// The gate composed with the capture's own shape, and the composition is
/// `slopdesk_video::capture_config::can_resize_in_place`'s — asked rather than spelled, because
/// `slopdesk-apple-sck` asks the same door about the same three terms one layer further down and
/// two spellings of "eligible" would be a fast path that starts and then refuses itself.
///
/// This is the ONE place `SLOPDESK_INPLACE_RESIZE` is read on the host. Off ⇒ every resize takes
/// the restart path, byte for byte as it did before the fast path existed.
fn takes_in_place(gates: &HostGates, capture: &Arc<dyn CaptureStream>) -> bool {
    can_resize_in_place(
        gates.in_place_resize_enabled,
        capture.is_display_anchored(),
        capture.is_union_anchored(),
    )
}

/// Re-seeds the rate controllers to a rebuild's ceiling, from the configuration they already hold.
///
/// The tunables are read off the LIVE controllers rather than re-resolved from the overlay, and
/// that is the point: the overlay is fixed at launch, so the two agree by construction, but reading
/// them here means a rebuild cannot be configured differently from the build it is replacing even
/// if that ever stops being true.
///
/// The `default()` fallbacks are unreachable where they would matter.
/// [`Controllers::seed_for_encoder`] reads the congestion configuration only inside the ABR gate —
/// which is exactly the condition under which a congestion controller exists to have been read —
/// and the quantiser configuration only when const-QP names a seed, which is the condition under
/// which a QP controller exists.
fn reseed(
    controllers: &mut Controllers,
    session: &Session,
    ceiling: i64,
    quantiser: Option<i32>,
    user_ceiling: Option<i64>,
) -> Option<i64> {
    let congestion = controllers
        .congestion
        .as_ref()
        .map(LiveCongestionController::snapshot);
    let qp_config = controllers
        .qp
        .as_ref()
        .map_or_else(QpConfig::default, QpController::config);
    let congestion_config = congestion
        .as_ref()
        .map_or_else(CongestionConfig::default, |snapshot| snapshot.config);
    let gradient_cut = congestion.is_some_and(|snapshot| snapshot.gradient_cut_enabled);
    controllers.seed_for_encoder(
        ceiling,
        &session.gates,
        congestion_config,
        gradient_cut,
        qp_config,
        quantiser,
        user_ceiling,
    )
}

/// Resizes the real window through the accessibility tree, answering the size it actually took.
///
/// The display list is LENT to the write, which is what makes the re-anchor part of the same act:
/// [`windowplace::resize`] moves the window to its display's origin before it writes the size, so a
/// window growing at the bottom-right of a display does not end up half off it. `None` is a window
/// that cannot be resized at all — a sheet, a fixed-size panel, or an app that stopped answering.
fn resize_window(window_id: u32, pid: i32, points: VideoSize) -> Option<VideoSize> {
    let displays: Vec<VideoRect> = slopdesk_apple_cgdisplay::active()
        .into_iter()
        .map(|display| display.bounds)
        .collect();
    let (width, height) = windowplace::resize(
        &AccessibilityTree,
        window_id,
        pid,
        points.width,
        points.height,
        &displays,
    )?;
    Some(VideoSize::new(width, height))
}

/// Puts the window back where a failed resize found it. Best-effort by design.
///
/// Called only on a path that has already given up, so a refusal here changes nothing that was
/// going to happen anyway: the window is left at the requested size, the capture keeps running at
/// the old one, and the next successful resize corrects both. A beachballing app is exactly the
/// case that reaches this and exactly the case that can refuse it.
fn roll_back_window(window_id: u32, pid: i32, points: VideoSize) {
    let _rolled = resize_window(window_id, pid, points);
}

/// One axis of a point size, on the wire's own terms.
///
/// The recovery rebuild needs the pre-resize size as [`pixels`] takes it, and that conversion is
/// the same clamp the achieved size goes through — asked of the rules crate rather than written
/// twice, because both ends of it are pinned.
fn clamped_axis(points: f64) -> u16 {
    let (axis, _same) = clamp_capture_size(
        VideoSize::new(points, points),
        VideoSize::new(1.0, 1.0),
        VideoSize::new(f64::from(u16::MAX), f64::from(u16::MAX)),
    );
    axis
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::{Mutex, PoisonError, Weak};

    use slopdesk_video::host_gates::GateContext;
    use slopdesk_video::recovery_idr::RecoveryIdrConfig;
    use slopdesk_video::recovery_routing::VideoChannel;
    use slopdesk_video::session_state::{PROTOCOL_VERSION, VideoSessionStateMachine};

    use super::*;
    use crate::capture::CannotResizeInPlace;
    use crate::encode::Shape as EncodeShape;
    use crate::env::Overlay;
    use crate::mux_lane::{LaneControl, LaneRetired, MuxLaneTransport};
    use crate::mux_sink::MuxSinkTable;
    use crate::session::Streaming;
    use crate::session_geometry::RegionState;
    use crate::session_pump::EncoderSlot;
    use crate::session_wiring::{Live, SessionSpec};

    /// The two timings a live daemon resolves before it folds the gate table, spelled the way the
    /// rules crate spells them — a made-up pair would exercise a clamp that never runs.
    const CONTEXT: GateContext = GateContext {
        scroll_resampler_active: false,
        keepalive_interval: slopdesk_video::keepalive::KEEPALIVE_INTERVAL_SECONDS,
        idle_timeout: slopdesk_video::keepalive::IDLE_TIMEOUT_SECONDS,
    };

    /// A shared flow with no socket under it. Nothing here is about what reached the wire.
    #[derive(Debug, Default)]
    struct Flow;

    impl LaneControl for Flow {
        fn admit(&self, _channel_id: u32) {}
        fn retire(&self, _channel_id: u32) {}
        fn send(&self, _datagram: &[u8], _channel: VideoChannel, _channel_id: u32) {}
    }

    /// The registry's half of a lane's retirement, which a test session never consults.
    #[derive(Debug, Default)]
    struct Registry;

    impl LaneRetired for Registry {
        fn lane_retired(&self, _channel_id: u32) {}
    }

    /// A capture stream of a chosen SHAPE that records the order it was driven in.
    ///
    /// The order is the only thing this module owns, so the double answers it as a list rather
    /// than as counters: "the IDR was armed before the reconfigure" and "nothing was stopped" are
    /// the same assertion read two ways.
    #[derive(Debug)]
    struct Recorder {
        /// What [`CaptureStream::is_display_anchored`] answers.
        display_anchored: bool,
        /// What [`CaptureStream::is_union_anchored`] answers.
        union_anchored: bool,
        /// What [`CaptureStream::resize_in_place`] answers.
        reconfigure: Result<(), CannotResizeInPlace>,
        /// Every door that was opened, in the order it was opened.
        calls: Mutex<Vec<&'static str>>,
        /// The size the reconfigure was asked for, once it has been asked.
        asked: Mutex<Option<(i32, i32)>>,
    }

    impl Recorder {
        /// A capture the fast path is eligible over, which answers `reconfigure` when asked.
        fn eligible(reconfigure: Result<(), CannotResizeInPlace>) -> Arc<Self> {
            Arc::new(Self {
                display_anchored: true,
                union_anchored: false,
                reconfigure,
                calls: Mutex::new(Vec::new()),
                asked: Mutex::new(None),
            })
        }

        fn note(&self, door: &'static str) {
            self.calls
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(door);
        }

        fn calls(&self) -> Vec<&'static str> {
            self.calls.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        fn asked(&self) -> Option<(i32, i32)> {
            *self.asked.lock().unwrap_or_else(PoisonError::into_inner)
        }
    }

    impl CaptureStream for Recorder {
        fn stop(&self) {
            self.note("stop");
        }
        fn set_audio_forwarding(&self, _enabled: bool) {
            self.note("set_audio_forwarding");
        }
        fn set_governed_fps(&self, _fps: i32) {
            self.note("set_governed_fps");
        }
        fn set_client_silence_paused(&self, _paused: bool) {}
        fn request_keyframe(&self) {
            self.note("request_keyframe");
        }
        fn request_ltr_refresh(&self) {}
        fn stop_capture_only(&self) {
            self.note("stop_capture_only");
        }
        fn arm_heartbeat(&self, _session: &Arc<Session>) {
            self.note("arm_heartbeat");
        }
        fn is_display_anchored(&self) -> bool {
            self.display_anchored
        }
        fn is_union_anchored(&self) -> bool {
            self.union_anchored
        }
        fn resize_in_place(
            &self,
            _encoder: &Arc<Encoder>,
            pixel_width: i32,
            pixel_height: i32,
        ) -> Result<(), CannotResizeInPlace> {
            self.note("resize_in_place");
            *self.asked.lock().unwrap_or_else(PoisonError::into_inner) = Some((pixel_width, pixel_height));
            self.reconfigure
        }
    }

    /// A listening session over a lane with no socket under it.
    ///
    /// The registry handle is returned with it because the lane holds only a `Weak` to it, and a
    /// dropped registry would make every retirement a no-op for a reason the test did not choose.
    fn session(edit: impl FnOnce(&mut HostGates)) -> (Arc<Session>, Arc<Registry>) {
        let registry = Arc::new(Registry);
        // The unsizing happens at this typed binding, not inside `downgrade`. `registry` is
        // returned to the caller, so the allocation outlives the strong handle dropped here.
        let watcher: Arc<dyn LaneRetired> = registry.clone();
        let observer: Weak<dyn LaneRetired> = Arc::downgrade(&watcher);
        let flow: Arc<dyn LaneControl> = Arc::new(Flow);
        let transport = Arc::new(MuxLaneTransport::new(
            1,
            flow,
            Arc::new(MuxSinkTable::new()),
            observer,
        ));
        let mut gates = HostGates::from_env(&[], CONTEXT);
        // The paced drain owns a thread of its own and nothing here is about pacing.
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
        (session, registry)
    }

    /// Drives the state machine to STREAMING through its own hello, and DISCARDS the effects: the
    /// capture arm needs a window server and nothing here is about the bring-up.
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

    /// An encoder that was never opened, which is all any test here needs one to be.
    ///
    /// Every property write below ignores it — `set_live_bitrate`, `set_expected_frame_rate` and
    /// `complete_frames` all no-op with no session behind them — which is exactly the split
    /// [`Session::open_encoder`] exists to make: the order runs, the framework does not.
    fn encoder() -> Arc<Encoder> {
        Arc::new(Encoder::new(
            EncodeShape::default(),
            None,
            &Overlay::from_text(""),
        ))
    }

    /// Installs `recorder` and a fresh encoder as the live set, answering the generation and the
    /// encoder a successful swap has to displace.
    fn install(session: &Session, recorder: &Arc<Recorder>) -> (u64, Arc<Encoder>) {
        let outgoing = encoder();
        let installed: Arc<dyn CaptureStream> = recorder.clone();
        let mut live = Live::new();
        let generation = live.install(installed, Arc::clone(&outgoing));
        *session.locked_streaming() = Some(Streaming {
            live,
            holds_display_wake: false,
            audio_enabled: false,
            geometry: None,
            cursor: None,
            region: RegionState::default(),
        });
        (generation, outgoing)
    }

    /// The encoder the live set currently holds.
    fn installed_encoder(session: &Session) -> Arc<Encoder> {
        session
            .locked_streaming()
            .as_ref()
            .and_then(|streaming| streaming.live.encode.clone())
            .expect("the test installed one")
    }

    #[test]
    fn the_gate_off_keeps_an_otherwise_eligible_capture_on_the_restart_path() {
        let (session, _registry) = session(|gates| gates.in_place_resize_enabled = false);
        let capture: Arc<dyn CaptureStream> = Recorder::eligible(Ok(()));
        assert!(
            !takes_in_place(&session.gates, &capture),
            "SLOPDESK_INPLACE_RESIZE=0 must reach the restart path with nothing tried first"
        );
    }

    #[test]
    fn a_display_anchored_capture_under_the_gate_takes_the_fast_path() {
        // The gate is set EXPLICITLY, and the assertion below it is why: the shipped default is
        // OFF until the branch has run on a real host, so a test that relied on the default would
        // be asserting the operator's setting rather than this door's rule.
        let (session, _registry) = session(|gates| gates.in_place_resize_enabled = true);
        let capture: Arc<dyn CaptureStream> = Recorder::eligible(Ok(()));
        assert!(takes_in_place(&session.gates, &capture));
    }

    #[test]
    fn a_capture_with_no_configuration_to_rewrite_never_takes_the_fast_path() {
        // Gate ON, so a `false` below is the SHAPE's refusal and not the operator's.
        let (session, _registry) = session(|gates| gates.in_place_resize_enabled = true);
        // The per-window compositor: the crop follows the window's own backing store, so there is
        // no live configuration a reconfigure could drive.
        let per_window = Arc::new(Recorder {
            display_anchored: false,
            union_anchored: false,
            reconfigure: Ok(()),
            calls: Mutex::new(Vec::new()),
            asked: Mutex::new(None),
        });
        let per_window: Arc<dyn CaptureStream> = per_window;
        assert!(!takes_in_place(&session.gates, &per_window));

        // The DIALOG-EXPAND union crop, which the geometry poller owns and re-targets itself.
        let union = Arc::new(Recorder {
            display_anchored: true,
            union_anchored: true,
            reconfigure: Ok(()),
            calls: Mutex::new(Vec::new()),
            asked: Mutex::new(None),
        });
        let union: Arc<dyn CaptureStream> = union;
        assert!(!takes_in_place(&session.gates, &union));
    }

    #[test]
    fn a_swap_installs_the_new_encoder_under_the_same_stream_and_the_same_generation() {
        let (session, _registry) = session(|gates| gates.in_place_resize_enabled = true);
        flowing(&session);
        let recorder = Recorder::eligible(Ok(()));
        let (generation, outgoing) = install(&session, &recorder);
        let capture: Arc<dyn CaptureStream> = recorder.clone();
        let replaced = Replaced {
            capture: &capture,
            encoder: &outgoing,
            generation,
        };
        let incoming = encoder();

        let rebuilt = session.install_in_place(&replaced, &incoming, 9_000_000, 4, 1280, 720);

        assert_eq!(
            rebuilt,
            Some(Rebuilt::Live),
            "an accepted reconfigure is the one outcome that may be acknowledged"
        );
        assert_eq!(
            recorder.calls(),
            vec!["request_keyframe", "resize_in_place"],
            "the IDR is armed before the stream is told anything, and NOTHING was stopped — a capture \
             re-dial is the ~120 ms freeze this path exists to avoid"
        );
        assert_eq!(
            recorder.asked(),
            Some((1280, 720)),
            "the stream is reconfigured to the size the encoder was opened at, or the pump's size guard \
             would refuse every buffer"
        );
        assert!(
            Arc::ptr_eq(&installed_encoder(&session), &incoming),
            "the live set must hold the encoder the frames now go to"
        );
        assert!(
            session
                .locked_streaming()
                .as_ref()
                .is_some_and(|streaming| streaming.live.is_current(generation)),
            "the SET was not replaced, so bumping the generation would tell the live capture pump it had \
             been superseded and swallow the next real capture death"
        );
    }

    #[test]
    fn a_refused_reconfigure_falls_through_with_the_old_encoder_still_installed() {
        let (session, _registry) = session(|gates| gates.in_place_resize_enabled = true);
        flowing(&session);
        let recorder = Recorder::eligible(Err(CannotResizeInPlace::Refused(-6661)));
        let (generation, outgoing) = install(&session, &recorder);
        let capture: Arc<dyn CaptureStream> = recorder.clone();
        let replaced = Replaced {
            capture: &capture,
            encoder: &outgoing,
            generation,
        };

        let rebuilt = session.install_in_place(&replaced, &encoder(), 9_000_000, 4, 1280, 720);

        assert_eq!(
            rebuilt, None,
            "a refusal is NOT TAKEN: the caller owes the restart path, which is what serves the resize"
        );
        assert!(
            Arc::ptr_eq(&installed_encoder(&session), &outgoing),
            "the live stream kept the old configuration, so the old encoder must still be the installed one"
        );
        assert!(
            !recorder.calls().contains(&"stop_capture_only"),
            "a declined fast path must hand the restart path a set that is still capturing"
        );
    }

    #[test]
    fn a_swap_that_a_newer_epoch_overtook_installs_nothing() {
        let (session, _registry) = session(|gates| gates.in_place_resize_enabled = true);
        flowing(&session);
        let recorder = Recorder::eligible(Ok(()));
        let (generation, outgoing) = install(&session, &recorder);
        // Moved rather than cloned: this test reads the live set afterwards, never the double.
        let capture: Arc<dyn CaptureStream> = recorder;
        let replaced = Replaced {
            capture: &capture,
            encoder: &outgoing,
            generation,
        };
        // A newer resize committed its epoch while this one was blocked on the framework.
        let _committed = session.locked_state().handle_control(
            &VideoControlMessage::ResizeRequest {
                desired: VideoSize::new(400.0, 300.0),
                epoch: 9,
            },
            VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
            |_, _| None,
            |_, _| Some((400, 300)),
            |_, _| None,
        );
        assert_eq!(
            session.locked_state().last_resize_epoch(),
            9,
            "the machine commits the newer epoch SYNCHRONOUSLY, before its effect runs"
        );

        let rebuilt = session.install_in_place(&replaced, &encoder(), 9_000_000, 4, 1280, 720);

        assert_eq!(
            rebuilt,
            Some(Rebuilt::Superseded),
            "only the newest epoch may install, and a superseded resize acknowledges nothing"
        );
        assert!(
            Arc::ptr_eq(&installed_encoder(&session), &outgoing),
            "the newer owner's set is the one that is live; this one installs nothing"
        );
    }

    #[test]
    fn an_unswapped_slot_keeps_the_encoder_a_bring_up_gave_it() {
        // The gate-OFF invariant, read at the door the guard lives behind: a pump that was never
        // re-pointed compares no sizes and hands every buffer to the encoder it was built with.
        let built = encoder();
        let slot = EncoderSlot::new(&built);
        let (held, accepts) = slot.current();
        assert!(Arc::ptr_eq(&held, &built));
        assert_eq!(accepts, None);
    }
}
