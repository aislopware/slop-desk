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
//! ## ⚠️ The in-place fast path is NOT wired
//! The Swift had one — reconfigure the LIVE `SCStream` to the new size and swap the encoder under
//! it, saving the framework's ~120 ms stream spin-up — and every piece of it exists in Rust except
//! the swap. [`crate::capture::Capturer::resize`] is the reconfigure and
//! `slopdesk_video::capture_config::can_resize_in_place` is the verdict, but new-size buffers must
//! reach a NEW-size encoder and there is nowhere to put one: `session_pump`'s capture pump holds
//! its `Arc<Encoder>` immutably, a `Capturer`'s event sink is fixed at construction, and a
//! `VTCompressionSession` cannot change dimensions — the Swift's `SwappableEncoder` box has no
//! counterpart. Landing it needs ONE door in `crate::session_pump`: an encoder behind a lock and a
//! `swap_encoder` that replaces it between frames. Until then the restart path below serves every
//! resize, which is what the Swift's own fallback did on any in-place failure — correctness is
//! unchanged and only the freeze is paid. The gate that would select it,
//! `HostGates::in_place_resize_enabled`, is deliberately left unread rather than consulted for a
//! branch that does not exist.
//!
//! ⚠️ GUI + TCC ONLY. Every step below the geometry read needs a window server, an Accessibility
//! grant and a Screen-Recording grant, so nothing in this module is reachable from a test — which
//! is why it takes no decisions of its own.

use std::sync::Arc;

use slopdesk_apple_sck::CaptureRegion;
use slopdesk_video::audio_source::{CHANNEL_COUNT, SAMPLE_RATE};
use slopdesk_video::congestion::{CongestionConfig, LiveCongestionController};
use slopdesk_video::fps_governor::FpsGovernor;
use slopdesk_video::geometry::{VideoRect, VideoSize};
use slopdesk_video::live_bitrate::{self, BITS_PER_PIXEL_KEY};
use slopdesk_video::qp_control::{QpConfig, QpController};
use slopdesk_video::session_state::{clamp_capture_size, effective_fps};
use slopdesk_video::video_control::VideoControlMessage;

use crate::capture::{CaptureEvents, Capturer, Shape as CaptureShape};
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

        // 7. THE REBUILD. This is where the in-place fast path would branch — see the module note:
        //    `slopdesk_video::capture_config::can_resize_in_place` and
        //    `crate::capture::Capturer::resize` are both here, and the encoder swap they need is
        //    not.
        match self.rebuild_live_set(&outgoing, id, epoch, pixel_width, pixel_height, None) {
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
        // 1. THE NEW ENCODER, BUILT AND OPENED BEFORE IT IS SHARED — `start_capture` step 3's
        //    reasoning, unchanged. The new resolution has a new ceiling; the controllers are
        //    re-anchored to it at step 7, once this encoder is the installed one.
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
            return Rebuilt::EncoderRefused;
        }
        let encoder = Arc::new(encoder);

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
        let Some(successor) = outgoing.capture.hand_over(capturer) else {
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
