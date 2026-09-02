//! The session's BRING-UP and TEARDOWN: the two fixed sequences, and nothing else.
//!
//! The Swift host session's `.startCapture` and `.stopCapture` arms, its
//! `startLiveComponents(width:height:)` and `teardownLiveComponents()`, its
//! `applyAudioControl(enabled:)`, and its `applyPrivacyMode(enabled:)` / `teardownPrivacyBlank()`
//! pair.
//!
//! ## The whole file is an ORDER
//! Five independent lifetimes come up here — the encoder, the audio lane, the capture stream, the
//! heartbeat and the host's display-wake assertion — and each one is either safe or a bug depending
//! on where it sits relative to the other four. [`Session::start_capture`] and
//! [`Session::teardown_live`] are therefore written as NUMBERED lists with a note per step saying
//! what breaks if it moves, the way [`crate::mux_registry::LaneSession::stop`] is. A step whose
//! note could be deleted without losing information is a step that did not need to be where it is.
//!
//! ## The generation discipline
//! The Swift guarded every post-suspension resume with `capturer === oldCapturer, encoder ===
//! oldEncoder, cursorSampler === …` — five comparisons per path, and the bug class was a path that
//! wrote four. [`crate::session_wiring::Live`] answers the same question once, over the SET, and
//! every path below asks it exactly ONCE and acts on that one answer:
//!
//! * [`Session::start_capture`] keeps the generation [`Live::install`] answered and presents it
//!   again at the one later step that can leak if it is stale — the display wake, which is a
//!   process-wide assertion and the only thing here that outlives a dropped `Arc`.
//! * [`Session::teardown_live`] does not ask at all, and that is not an omission: it takes the
//!   whole [`Streaming`] value out of its `Option` under the lock, so a bring-up that installs
//!   afterwards installs a DIFFERENT value and there is nothing for a late teardown to clobber.
//!   Asking `is_current` there would be a second question with no second answer.
//!
//! ## ⚠️ The privacy blank has ONE lock, and it is not the streaming one
//! [`Session::apply_privacy_mode`] engages a real gamma blackout, and the failure it is written
//! against is not a race in the ordinary sense: a blank engaged just after a teardown has restored
//! leaves the host's screen DARK with nothing alive to light it again, and a zeroed gamma table
//! outlives the process that set it. So the wish and the teardown take `Session::privacy` — one
//! lock, held across the check and the effect on both sides — and the teardown's step 3 both TAKES
//! the value and disengages it, which is what makes a late wish find nothing to engage.
//!
//! ⚠️ GUI + TCC ONLY from [`Session::start_capture`] step 8 down: `SCStream` and
//! `VTCompressionSession` both hang without a window server and a Screen-Recording grant, so no
//! test below reaches either. Everything that can be reached headlessly is tested at the bottom of
//! this file; each untestable step says so where it sits.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use slopdesk_video::audio_source::{CHANNEL_COUNT, SAMPLE_RATE};
use slopdesk_video::capture_gates::{self, CaptureGateContext, CaptureGates};
use slopdesk_video::congestion::{self, ABR_KEYS, CongestionConfig};
use slopdesk_video::fps_governor::{self, EncodeLoadPacerConfig, FpsGovernorConfig};
use slopdesk_video::geometry::VideoRect;
use slopdesk_video::keepalive::HOST_HEARTBEAT_INTERVAL_SECONDS;
use slopdesk_video::live_bitrate::{self, BITS_PER_PIXEL_KEY};
use slopdesk_video::qp_control::{self, QpConfig};
use slopdesk_video::video_control::VideoControlMessage;
use slopdesk_video::window_list::display_for_window_frame;

use crate::audio::AudioSender;
use crate::capture::{CannotResizeInPlace, CaptureEvents, Capturer, Shape as CaptureShape};
use crate::encode::{EncodedFrameSink, Encoder, Shape as EncodeShape, const_qp, max_allowed_frame_qp};
use crate::env::Overlay;
use crate::injector::Injector;
use crate::privacy::{HostGamma, PrivacyBlank};
use crate::session::{CaptureStream, Session, Streaming};
use crate::session_geometry::RegionState;
use crate::session_pump::{CapturePump, EncodedPump, EncoderSlot};
use crate::session_wiring::{ClientLiveness, Live, Target, initial_governor};
use crate::wake::HostDisplayWake;

/// What a teardown does with the button or the modifier the person is still physically holding.
///
/// The injector's ledger is the host's only memory of it, and the two teardowns want opposite
/// things of that memory: a re-mint seeds the replacement with it, so the drag the person never let
/// go of survives the reconnect, while a session that is over must let go on the host's behalf, or
/// the target app keeps tracking a button nobody will release.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HeldInputFate {
    /// A replacement is coming and has already read the balance; post nothing.
    Carry,
    /// Nothing replaces this injector: release every held button and modifier before it drops.
    Release,
}

/// How long after a cadence announcement its duplicate goes out.
///
/// `slopdesk_video::video_control`'s own term for [`VideoControlMessage::StreamCadence`]: the
/// message is sent twice about 25 ms apart, because a client that misses it renders at a cadence
/// the host is no longer producing and there is no second chance to say so — the governor only
/// speaks when the number CHANGES. The client's application is idempotent, so a duplicate that
/// arrives costs one decode of eight bytes.
const CADENCE_DUP_DELAY: Duration = Duration::from_millis(25);

impl Session {
    /// Brings the live capture and encode path up at `width` × `height` POINTS.
    ///
    /// The steps below are the Swift's `.startCapture` arm and `startLiveComponents` folded into
    /// one list, because the split between them was an `async` boundary this port does not have.
    /// Each note says what breaks if the step moves.
    ///
    /// ⚠️ Steps 7 and down need a window server and a Screen-Recording grant.
    #[expect(
        clippy::too_many_lines,
        reason = "the fourteen bring-up steps are ONE order, and every note below says what breaks if a \
                  step moves; splitting them would hide the order from the reader"
    )]
    pub(crate) fn start_capture(self: &Arc<Self>, width: u16, height: u16) {
        // 1. THE RE-MINT KILLS EVERYTHING THE LAST STREAM ASSERTED. User stream settings, the
        //    client's audio wish, the privacy blank and the display wake all die here, because a
        //    fresh hello starts clean and the client re-sends each of them after the ack. On the
        //    ordinary path the state machine has already emitted `StopCapture`, so this finds
        //    nothing — and on the path where it has not, this is what stops the previous `SCStream`
        //    instead of orphaning it behind the install at step 9.
        //
        //    The outgoing generation is read BEFORE the teardown, because the teardown drops the
        // [`Live`]    that holds it. [`Live::new`] restarts the counter at zero, so without
        // this the second    bring-up would hand out the same tokens as the first, and a
        // straggler from bring-up A —    step 13's wake adopt above all — could answer
        // `is_current` against bring-up B and act on a    set it never installed. Seeding
        // the fresh counter with the old one makes the token monotone    across re-mints,
        // which is the invariant [`Live`]'s own test asserts WITHIN one value.
        //    The held-input BALANCE is read here for the same reason and only that reason: the
        //    teardown below clears the injector seam, and what the user is physically holding has
        // to    outlive it. Everything else about the last stream dies; the user's hands
        // are not part of    the last stream. Step 6 seeds the replacement with this.
        let outgoing_generation = self
            .locked_streaming()
            .as_ref()
            .map_or(0, |live| live.live.generation);
        let held = self.input_balance();
        self.teardown_live(HeldInputFate::Carry);

        // 2. THE PIXEL GEOMETRY AND THE RATE, BEFORE ANYTHING IS BUILT. The bitrate is
        //    resolution-aware and is BOTH the encoder's target and the congestion controller's
        //    ceiling, so it is resolved once here rather than twice below: a 2× HiDPI window has
        //    four times the pixels, and a rate cap that ignored that starves scroll frames into
        //    stutter. Every number is `slopdesk_video`'s.
        let pixel_width = pixels(width, self.spec.capture_scale);
        let pixel_height = pixels(height, self.spec.capture_scale);
        let bits_per_pixel =
            live_bitrate::bits_per_pixel_from_env(self.overlay.get(BITS_PER_PIXEL_KEY).as_deref());
        let ceiling = live_bitrate::target_bitrate(
            i64::from(pixel_width),
            i64::from(pixel_height),
            self.spec.fps,
            self.spec.bitrate,
            bits_per_pixel,
        );

        // 3. THE ENCODER, BUILT AND OPENED BEFORE IT IS SHARED. `open` takes `&mut self` and can
        //    fail; installing behind the `Arc` first would mean either a fallible call through a
        //    shared handle or a half-open encoder visible to the capture path. A failed create
        //    ABORTS the bring-up — the Swift returned here too, and the alternative is a session
        //    whose every frame is dropped by a `None` session with nothing to report it.
        //
        //    The sink is built FIRST because `Encoder::new` takes it: the wire pump needs only a
        //    `Weak<Session>`, and the capture pump at step 7 needs the encoder, so the two halves
        //    of the pump can only be built in this order.
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
            // Nothing is installed and nothing was started, so there is nothing to unwind. The
            // state machine still believes media flows; the idle reaper is what reclaims that,
            // exactly as it did when the Swift returned from this arm.
            return;
        }
        let encoder = Arc::new(encoder);

        // 4. RE-ANCHOR THE CONTROLLERS TO THIS BUILD, BEFORE A FRAME CAN REACH THEM. Three separate
        //    obligations under ONE lock, which is why they are one block:
        //      * the LTR acked-set is cleared — a new `VTCompressionSession` holds zero
        //        acknowledged long-term references, and a surviving ack names one the client no
        //        longer has;
        //      * the FPS governor is minted FRESH at the base cadence, through the free function
        //        that only an initial build may call — see `Controllers::fps`;
        //      * the rate controllers are seeded to THIS build's ceiling, with NO user ceiling.
        //        That `None` is the "user stream settings die with the re-mint" reset: the client
        //        re-sends its wish after the ack, and layering a stale one here would apply a cap
        //        the client has not asked for since the last session.
        let governor_texts = resolved(&self.overlay, &fps_governor::KEYS);
        let abr_texts = resolved(&self.overlay, &ABR_KEYS);
        let qp_texts = resolved(&self.overlay, &qp_control::KEYS);
        let quantiser = const_qp(&self.overlay);
        let actuate = {
            let mut controllers = self.locked_controllers();
            controllers.reset_ltr_for_new_encoder();
            controllers.fps = initial_governor(
                &self.gates,
                self.spec.fps,
                FpsGovernorConfig::from_env(&borrowed(&governor_texts)),
            );
            controllers.seed_for_encoder(
                ceiling,
                &self.gates,
                CongestionConfig::from_env(&borrowed(&abr_texts)),
                // `SLOPDESK_ABR_GRAD` is the LAST slot of `ABR_KEYS`, not a second lookup: the whole
                // `SLOPDESK_ABR_*` family resolves from the one table, so a key added to it cannot
                // be read here through a name spelled by hand.
                congestion::gradient_cut_enabled_from_env(abr_texts.last().and_then(Option::as_deref)),
                QpConfig::from_env(&borrowed(&qp_texts)),
                quantiser,
                None,
            )
        };
        // Actuated OUTSIDE the controller lock: the property write is a framework call, and a
        // report folding on another thread must not wait behind one.
        if let Some(target) = actuate {
            let _actuated = encoder.set_live_bitrate(target);
        }

        // 5. THE AUDIO LANE, BEFORE THE PUMP THAT FEEDS IT AND BEFORE THE TAP'S SHAPE. ⚠️ The epoch
        //    is the SESSION's, never a fresh `Instant::now()`. Audio timestamps and video fragment
        //    headers are both host-relative milliseconds on ONE clock, and a second epoch here
        //    would put the two timelines a start-up delay apart — a wire bug neither end can see,
        //    because each stream is internally consistent.
        //
        //    The master gate is resolved from the rules crate's own table rather than read as a
        //    string here: the capturer would answer it through `Capturer::gates()`, but the tap's
        //    sample rate is part of the shape the capturer is CONSTRUCTED with, so the answer is
        //    needed one step before a capturer exists. One clamp, in `capture_gates`, as
        //    `docs/46` requires.
        let capture_texts = resolved(&self.overlay, &capture_gates::KEYS);
        let tap_gates = CaptureGates::from_env(&borrowed(&capture_texts), CaptureGateContext {
            max_allowed_frame_qp: max_allowed_frame_qp(&self.overlay),
            encode_ewma_alpha: EncodeLoadPacerConfig::default().alpha,
        });
        let audio = tap_gates.audio_capture.then(|| {
            Arc::new(AudioSender::spawn(
                Arc::clone(&self.transport),
                self.epoch,
                &self.overlay,
            ))
        });

        // 6. THE INPUT INJECTOR, BEFORE ANY FRAME GOES OUT. Ordered here and not later because the
        //    client's first click can arrive on the very datagram after the ack, and an inbound
        //    path with a `None` injector drops it silently — the Swift's `guard let injector`
        //    behaviour, which was a real lost-first-click on a slow bring-up.
        //
        //    The balance `held` was read at step 1, BEFORE the teardown that cleared the last seam.
        //    A transparent reconnect rebuilds the injector while the user may still be physically
        //    holding a drag or ⌘; seeding empty would classify the eventual release as an orphan,
        //    suppress it, and strand the host mid-drag.
        //
        //    A DISPLAY target passes pid `0`, which is what tells the injector it has no window to
        //    raise: whole-desktop input goes wherever the frontmost app is, exactly like a local
        //    user's.
        let (injector_pid, injector_window) = match self.spec.target {
            Target::Window { id, pid, .. } => (pid, id),
            Target::Display { .. } => (0, 0),
        };
        self.set_input_injector(Some(Arc::new(Injector::new(
            &self.overlay,
            self.gates.input_trace,
            injector_pid,
            injector_window,
            self.window_bounds_cg(),
            held,
        ))));

        // 7. THE CAPTURE PUMP, which is what the capturer delivers into. It holds the encoder and
        //    the audio lane and a `Weak<Session>` — weak, because the session owns the capturer
        //    which owns this, and a strong edge back would close a cycle nothing could drop.
        let pump = CapturePump::new(self, &encoder, audio.clone());
        // Concrete parameter, so the unsizing happens at the binding rather than inside an
        // inference that would look for an `Arc<dyn CaptureEvents>` to clone.
        let events: Arc<dyn CaptureEvents> = Arc::<CapturePump>::clone(&pump);

        // 8. THE CAPTURE STREAM. ⚠️ Blocks, and needs the window server. A refused start is NOT
        //    fatal here, and that is the Swift's own choice carried over: by the time this runs the
        //    state machine is already `.streaming`, so returning without installing would leave the
        //    session believing it streams with no component to stop — the "streaming but dead"
        //    state `Live`'s own note names. Installing a stream that never came up leaves the
        //    teardown something to find.
        let capturer = Capturer::new(
            CaptureShape {
                fps: i32::try_from(self.spec.fps).unwrap_or(i32::MAX),
                capture_scale: self.spec.capture_scale,
                full_range: self.gates.full_range,
                // The live session's low-latency default: display-anchored capture is a whole
                // 60 Hz slot lower glass-to-glass, and occlusion-proof.
                prefer_display_anchored: true,
                audio_sample_rate: if tap_gates.audio_capture {
                    i32::try_from(SAMPLE_RATE).unwrap_or(i32::MAX)
                } else {
                    Default::default()
                },
                audio_channel_count: if tap_gates.audio_capture {
                    i32::try_from(CHANNEL_COUNT).unwrap_or(i32::MAX)
                } else {
                    Default::default()
                },
            },
            events,
            &self.overlay,
        );
        let _refused = match self.spec.target {
            // `None` region: a fresh bring-up is always captured at the plain window frame. The
            // dialog-expand union is a LATER re-target, decided by the geometry poller.
            Target::Window { id, .. } => capturer.start_window(id, pixel_width, pixel_height, None),
            Target::Display { id } => capturer.start_display(id, pixel_width, pixel_height),
        };

        // 9. THE TWO WATCHERS, BEFORE THE INSTALL. Both publish through a `Weak<Session>` and both
        //    are safe to start early: the geometry watcher's first poll re-origins an injector step
        //    6 has already installed and sends on a lane that is already up, and the cursor
        //    sampler's first position is gated behind a main-thread refresh that has not landed
        //    yet. Started here rather than after the install because the install is what MOVES them
        //    into `Streaming`, and a set installed without them would have a window in which a
        //    teardown finds nothing to join.
        //
        //    They are deliberately NOT inside `Live`: a resize replaces the capture stream and the
        //    encoder as a set, and both of these are watching the same window either way — see
        //    `Streaming`'s own field notes.
        let (geometry, cursor) = self.start_watchers();

        // 10. INSTALL THE SET, AND KEEP THE GENERATION. Everything below this line can race a
        //    teardown, and `generation` is the one token that answers whether it did.
        let live_capture = Arc::new(LiveCapture::new(capturer, pump.slot(), audio));
        // Spelled with the concrete parameter so the unsizing happens at the binding, not inside an
        // inference that would try to clone an `Arc<dyn CaptureStream>` that does not exist yet.
        let installed: Arc<dyn CaptureStream> = Arc::<LiveCapture>::clone(&live_capture);
        let generation = {
            let mut streaming = self.locked_streaming();
            let mut live = Live::new();
            // Resume the counter rather than restarting it — see step 1.
            live.generation = outgoing_generation;
            let generation = live.install(installed, encoder);
            *streaming = Some(Streaming {
                live,
                // Recorded at step 14, once the assertion is actually held. A `true` written here
                // would let a teardown in between release a wake nobody took.
                holds_display_wake: false,
                // The client's wish dies with the re-mint and is re-sent after the ack. The fresh
                // capturer's forwarding gate is down by construction, so the two agree.
                audio_enabled: false,
                geometry,
                cursor,
                // A fresh bring-up is always captured at the plain window frame — step 8 passes a
                // `None` region for exactly this reason — so the crop state starts at `None` and
                // the first dialog-expand sample is what moves it.
                region: RegionState::default(),
            });
            generation
        };
        // The pump learns its generation only now, because the generation does not exist until the
        // install above and the pump had to exist before the capturer at step 8. Everything the
        // pump reports — a capture death above all — is guarded on it.
        pump.adopt_generation(generation);

        // 11. RE-SEED THE CLIENT-SILENCE STAMP, before the heartbeat can consult it. A reused or
        //     reconnected
        //    session that inherited a stale "silent" stamp would pause a capturer that has not had
        // its    first inbound datagram yet — a stream that starts frozen.
        *self.locked_liveness() = ClientLiveness::starting_at(self.now());

        // 12. ANNOUNCE THE CADENCE AND THE RESIZE CEILING, once per bring-up. The cadence goes out
        //     ONLY when the governor is armed: with the gate off the host is byte-identical to one
        //     that never had the feature, which is what makes the gate testable against the golden
        //     vectors at all.
        if self.gates.fps_governor_enabled {
            self.send_cadence(u16::try_from(self.spec.fps).unwrap_or(u16::MAX));
        }
        self.send_display_max();

        // 13. THE STALL-SCRIM HEARTBEAT. After step 11, because its first tick reads the stamp that
        //     step re-seeded; after step 9, because the client-silence pause it pushes goes to the
        //     capture stream the install made reachable.
        live_capture.start_heartbeat(self);

        // 14. THE HOST DISPLAY WAKE, and only for a DISPLAY target — the sleep timer does not count
        //     a remote viewer as activity, so a full-desktop session must say so, and a window pane
        //     must NOT or every open pane would pin the host's display awake. `Target` answers it;
        //     this does not re-derive it.
        //
        //     The assertion is process-wide and outlives every `Arc` here, so it is the ONE step
        //     that re-presents the generation: acquire, then record under the lock only if this
        //     bring-up is still the live one, and release immediately if a teardown got in first.
        if self.spec.target.holds_display_wake() {
            let _held = HostDisplayWake::shared().acquire();
            let adopted = {
                let mut streaming = self.locked_streaming();
                match streaming.as_mut() {
                    Some(live) if live.live.is_current(generation) => {
                        live.holds_display_wake = true;
                        true
                    },
                    _ => false,
                }
            };
            if !adopted {
                let _released = HostDisplayWake::shared().release();
            }
        }
    }

    /// Stops the live capture and encode path.
    ///
    /// The Swift's `.stopCapture` arm was four statements — stop the heartbeat, release the wake,
    /// restore the privacy blank, tear the components down — and all four are
    /// [`Session::teardown_live`] here, because this port groups those assertions INTO the live set
    /// rather than scattering them beside it. There is nothing left for this arm to add, and a
    /// statement that appeared here but not in the teardown would be one a `bye` skipped.
    pub(crate) fn stop_capture(&self) {
        self.teardown_live(HeldInputFate::Release);
    }

    /// Tears the live components down, in the one order that ends with the host as it was found.
    ///
    /// Reached from [`Self::stop_capture`] and from [`crate::mux_registry::LaneSession::stop`], and
    /// the two race in normal operation — a client `bye` and the idle reaper arrive together. Made
    /// idempotent by TAKING the [`Streaming`] value: whoever wins the lock gets the components, and
    /// every later caller finds a `None` and does nothing.
    pub(crate) fn teardown_live(&self, held_input: HeldInputFate) {
        // 1. TAKE THE SET, AND DROP THE LOCK. Not just for contention: step 4 JOINS the heartbeat
        //    thread, and that thread takes this same lock on every tick, so holding it here would
        //    deadlock a teardown against a heartbeat that had just woken.
        let Some(mut streaming) = self.locked_streaming().take() else {
            return;
        };

        // 2. RELEASE THE DISPLAY WAKE. Before the slow steps, because it is the only thing here
        //    that is process-wide: a teardown that stalled in the framework would otherwise hold
        //    the host's display awake for the length of the stall. The flag is what remembers — a
        //    window session never acquired one and must not release one.
        if streaming.holds_display_wake {
            let _released = HostDisplayWake::shared().release();
        }

        // 3. THE PRIVACY BLANK, TAKEN AND DISENGAGED. Before the slow steps below for the same
        //    reason as step 2, and unconditionally: a session that ended while blanked leaves the
        //    host dark and input-dead, and the keyboard that would undo it is the one that was
        //    swallowed. A zeroed gamma table is not cleaned up by anything underneath this —
        //    measured, it outlives the process that set it — so this call is the ONLY thing that
        //    gives the host's screen back.
        //
        //    TAKEN, not merely disengaged, and that is what closes the race with
        // `apply_privacy_mode`:    step 1 already emptied `streaming`, so a wish that
        // arrives between then and here is refused    there, and one that arrives after
        // this finds a `None` and has nothing to re-engage. The    explicit `disengage` is
        // redundant with `Drop` and is written anyway, because the restore has    to be a
        // statement in this order rather than a consequence of where a binding ends.
        let blank = self.privacy.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(blank) = blank {
            blank.disengage();
        }

        // 4. FLUSH THE SEND LANE. The frames queued in it belong to the capture and encode
        //    generation being torn down, and draining them would spend the wire on a stream the
        //    client is about to be told is over. The lane itself SURVIVES — `close` is the
        //    session's own stop, not this.
        if let Some(lane) = self.send_lane.as_ref() {
            lane.flush();
        }

        // 5. THE TWO WATCHERS, BEFORE THE STREAM THEY PUBLISH ABOUT. Both `stop` calls JOIN a
        //    thread, and that is the whole point of doing it here: the geometry thread can be
        //    mid-region-rebuild against the very capture step 6 is about to stop, and the cursor
        //    thread publishes onto a lane step 7 of `LaneSession::stop` retires. Neither is
        //    idempotence — `Drop` would join them at step 6 anyway — it is ORDER, so that no poll
        //    and no sample is in flight past this line.
        if let Some(mut watcher) = streaming.geometry.take() {
            watcher.stop();
        }
        if let Some(mut sampler) = streaming.cursor.take() {
            sampler.stop();
        }

        // 6. THE LIVE CAPTURE ITSELF: heartbeat, audio gate, stream, audio thread, in that order —
        //    see `LiveCapture::stop`.
        if let Some(capture) = streaming.live.capture.as_ref() {
            capture.stop();
        }

        // 7. THE ENCODER GOES LAST, by being dropped last. `Encoder::drop` COMPLETES the frames
        //    still in the compression session, and completing them after step 6 means the capture
        //    path can no longer present a new one into a session that is draining.
        drop(streaming);

        // 8. THE INJECTOR, AFTER EVERYTHING ELSE. Dropping it JOINS its two threads, and the raise
        //    thread can be mid-accessibility-chain against a hung app for a second or more — so it
        //    goes after the steps that give the host its screen and its wire back, never before
        //    them. Clearing the seam is what makes the join happen: the pump holds the only other
        //    handle, and it drops this one on the next drain.
        //
        //    What happens to the button or the ⌘ the person is still holding is the caller's to
        //    say. A re-mint has already read the balance and will seed the replacement with it, so
        //    releasing here would break the very drag the reconnect is keeping alive; a session
        //    that is OVER has no replacement coming, and a button left down or a modifier left
        //    latched on the host's shared event source outlives the session that put it there. The
        //    release runs on the taken handle, outside the seam's lock, because it posts.
        let injector = self.take_input_injector();
        if held_input == HeldInputFate::Release
            && let Some(injector) = injector.as_ref()
        {
            injector.release_all();
        }
        drop(injector);
    }

    /// Applies the client's app-audio wish: the latch, the lane's gate and the tap's gate.
    ///
    /// No `SCStream` reconfiguration, which is the point of it: the audio tap runs for as long as
    /// the master gate allows, and OFF simply drops `.audio` buffers before any extract or encode
    /// work — so toggling is hitch-free rather than a stream restart.
    ///
    /// A session that is not streaming does nothing. The state machine only emits this effect while
    /// `.streaming`, so the `None` arm is a race with a teardown rather than a state to handle.
    pub(crate) fn apply_audio_control(&self, enabled: bool) {
        let capture = {
            let mut streaming = self.locked_streaming();
            let Some(live) = streaming.as_mut() else {
                return;
            };
            live.audio_enabled = enabled;
            let capture = live.live.capture.clone();
            drop(streaming);
            capture
        };
        // Outside the lock: the gate flip BLOCKS on the audio lane's queue by design — losing one
        // would leave a lane sending after its client asked it to stop — and blocking under the
        // streaming lock would stall a teardown behind a user's toggle.
        if let Some(capture) = capture {
            capture.set_audio_forwarding(enabled);
        }
    }

    /// Darkens the host's own display, or gives it back — the Swift's `applyPrivacyMode` verbatim,
    /// over [`crate::privacy::HostGamma`] instead of an inline `CGSetDisplayTransferByTable`.
    ///
    /// [`crate::privacy::PrivacyBlank`] holds every case — the idempotence, the gamma-first engage
    /// order, the failure arm that stays disengaged so the client's re-send retries, the tap-first
    /// teardown, the restore on `Drop`. This function decides only WHICH display and WHETHER a
    /// blank may exist at all, which is what a daemon is allowed to decide.
    ///
    /// ## The one lock, and the loss it prevents
    ///
    /// `Session::privacy` is held across BOTH the liveness check and the effect. The failure it
    /// rules out is not a lost update: a `set_enabled(true)` that lands after
    /// [`Session::teardown_live`]'s step 3 has already restored leaves the host's screen black with
    /// no session left to light it, and a zeroed gamma table survives the daemon's exit — nothing
    /// underneath this restores it, and the user's remaining move is to log out blind. So a blank
    /// is engaged only while [`Streaming`] is present, checked UNDER this lock, and the teardown's
    /// step 1 empties `streaming` before its step 3 takes this lock: whichever order the two
    /// threads arrive in, the last word belongs to the teardown.
    ///
    /// The nesting is one-directional and that is what keeps it from deadlocking: this path takes
    /// `privacy` then `streaming`, and the teardown holds `streaming` only for the duration of its
    /// own step-1 statement, so the two locks are never held together on the teardown side.
    ///
    /// A disengage is never refused for a dead session, only an engage. `enabled == false` on a
    /// session whose stream has already gone is the arm that HEALS a host, and refusing it for
    /// tidiness would be refusing the only call that helps.
    #[expect(
        clippy::significant_drop_tightening,
        reason = "the privacy guard spans the streaming check by design — releasing it early would let a \
                  teardown blank a display between the check and the engage"
    )]
    pub(crate) fn apply_privacy_mode(&self, enabled: bool) {
        // The state machine emits this effect for a DISPLAY target only — a window session has no
        // display to black without hiding an unrelated app — so the other arm is unreachable rather
        // than merely unhandled.
        let Target::Display { id } = self.spec.target else {
            return;
        };
        // Held across the streaming check below ON PURPOSE — see the comment there. Releasing it
        // early would let a teardown blank a display between the check and the engage.
        let mut privacy = self.privacy.lock().unwrap_or_else(PoisonError::into_inner);
        if !enabled {
            // Taken, not just disabled: a disengaged blank holds nothing worth keeping, and leaving
            // the `Some` behind would mean a later teardown restoring a display that is already
            // lit.
            let blank = privacy.take();
            drop(privacy);
            if let Some(blank) = blank {
                blank.disengage();
            }
            return;
        }
        // Under the lock, and this is the check the whole ordering exists for. `None` here means a
        // teardown has already run, and the correct answer to "go private" for a stream that is
        // over is to darken nothing at all.
        if self.locked_streaming().is_none() {
            return;
        }
        // `Drop` restores, so the blank has to be constructed IN PLACE rather than built, engaged
        // and then stored: a temporary that was dropped on the way into the `Option` would black
        // the display and light it again within the same statement.
        let blank = privacy.get_or_insert_with(|| PrivacyBlank::new(id, HostGamma));
        if !blank.set_enabled(true) {
            // The gamma call was refused by the window server. `PrivacyBlank` has already stayed
            // disengaged, so the client's next re-assert retries against the same controller; what
            // must NOT happen is this reporting a privacy the host never entered.
            crate::diag::say("privacy blank refused; the host's screen is still lit");
        }
    }

    /// Sends the stream's content cadence, twice, about [`CADENCE_DUP_DELAY`] apart.
    ///
    /// The duplicate is the wire's own term for this message and not a retry policy invented here:
    /// the governor speaks only when the number CHANGES, so a client that misses the single copy
    /// renders at a cadence the host stopped producing and is never told again. Application is
    /// idempotent, so the copy that arrives costs a decode.
    ///
    /// The second copy rides a detached thread that re-checks the flow. A thread rather than a
    /// timer because the whole obligation is one 25 ms sleep, and a `Weak` because a session torn
    /// down inside that window must not be kept alive by its own duplicate.
    pub(crate) fn send_cadence(self: &Arc<Self>, fps: u16) {
        if !self.locked_state().media_flowing() {
            return;
        }
        let message = VideoControlMessage::StreamCadence { fps };
        self.send_control(&message);
        let weak = Arc::downgrade(self);
        let spawned = thread::Builder::new()
            .name("slopdesk-cadence-dup".to_owned())
            .spawn(move || {
                thread::sleep(CADENCE_DUP_DELAY);
                let Some(session) = weak.upgrade() else {
                    return;
                };
                if session.locked_state().media_flowing() {
                    session.send_control(&message);
                }
            });
        // A thread that could not be spawned costs the duplicate and nothing else — the first copy
        // is already on the wire, and a bring-up must not fail because the process is out of
        // threads.
        drop(spawned);
    }

    /// Announces the maximum POINT size this target can be resized to, once per bring-up.
    ///
    /// Additive on the wire: a client that predates the message drops an unknown type, and one that
    /// understands it caps its resize popover's fields at a size the host can actually serve.
    fn send_display_max(&self) {
        if !self.locked_state().media_flowing() {
            return;
        }
        let displays: Vec<VideoRect> = slopdesk_apple_cgdisplay::active()
            .into_iter()
            .map(|display| display.bounds)
            .collect();
        if let Some((width, height)) =
            display_max_points(self.spec.target, self.window_bounds_cg(), &displays)
        {
            self.send_control(&VideoControlMessage::DisplayMax { width, height });
        }
    }
}

/// The capture stream the session installs, and the two lifetimes that ride with it.
///
/// One type rather than three session fields because all three are born and die together at a
/// bring-up, and the Swift proved what happens when they are not: the audio lane, the heartbeat and
/// the capturer each had their own `private var`, their own teardown statement, and their own way
/// of being forgotten by a new path.
///
/// It is what stands behind [`crate::session::CaptureStream`], so
/// [`crate::session_wiring::Live`]'s generation covers all three at once.
#[derive(Debug)]
pub(crate) struct LiveCapture {
    /// The `SCStream` and its backlog.
    capturer: Capturer,
    /// The slot the capturer's pump reads its encoder out of.
    ///
    /// Held HERE and nowhere else because the two halves of an in-place resize are the swap and
    /// the reconfigure, and this is the one value that can reach both: the capturer's sink was
    /// fixed at construction, so re-pointing the pump is the only way a new encoder gets under a
    /// stream that is never restarted.
    encoder: Arc<EncoderSlot>,
    /// The app-audio lane, or `None` when `SLOPDESK_AUDIO=0` masters the feature off end to end —
    /// in which case the capturer has no audio tap either.
    audio: Option<Arc<AudioSender>>,
    /// The 1 Hz host→client liveness keepalive. Armed after the install, by
    /// [`Self::start_heartbeat`].
    heartbeat: Heartbeat,
    /// Set by [`Self::stop`], and read by [`Self::start_heartbeat`].
    ///
    /// The one race a bring-up cannot avoid: the install at step 9 publishes this value, so a
    /// teardown can stop it before step 12 arms the heartbeat. Without this latch that arm would
    /// start a thread nothing would ever join.
    stopped: AtomicBool,
}

impl LiveCapture {
    /// A live set that is capturing but has no heartbeat yet.
    fn new(capturer: Capturer, encoder: Arc<EncoderSlot>, audio: Option<Arc<AudioSender>>) -> Self {
        Self {
            capturer,
            encoder,
            audio,
            heartbeat: Heartbeat::idle(),
            stopped: AtomicBool::new(false),
        }
    }

    /// Arms the 1 Hz heartbeat against `session`.
    ///
    /// Called AFTER the install, because the tick pushes the client-silence pause into whatever
    /// capture stream is installed and a tick that preceded the install would find none. A set that
    /// has already been stopped arms nothing.
    fn start_heartbeat(&self, session: &Arc<Session>) {
        if self.stopped.load(Ordering::Acquire) {
            return;
        }
        let weak = Arc::downgrade(session);
        self.heartbeat.start(
            Duration::from_secs_f64(HOST_HEARTBEAT_INTERVAL_SECONDS),
            move || {
                let Some(session) = weak.upgrade() else {
                    return false;
                };
                heartbeat_tick(&session);
                true
            },
        );
    }
}

impl CaptureStream for LiveCapture {
    /// Stops all three, in the one order a teardown can take.
    ///
    /// 1. **The heartbeat first, and JOINED.** It is the only thing here that reaches back into the
    ///    session and pushes into the capturer, so everything below it is racing a tick until this
    ///    returns.
    /// 2. **The audio SEND gate, before the stream stops.** A buffer already queued on the tap's
    ///    delivery queue must not race a datagram onto the wire mid-teardown — "streaming AND
    ///    enabled" is the lane's send contract, and this is the half that is still true.
    /// 3. **The capture stream**, which joins its own two threads.
    /// 4. **The audio lane's thread**, last, because step 3 is what guarantees no further buffer is
    ///    delivered into a queue that is about to close.
    ///
    /// Idempotent: every step under it is, and the latch is what makes a late
    /// [`LiveCapture::start_heartbeat`] one too.
    fn stop(&self) {
        self.stopped.store(true, Ordering::Release);
        self.heartbeat.stop();
        if let Some(audio) = self.audio.as_ref() {
            audio.set_enabled(false);
        }
        self.capturer.stop();
        if let Some(audio) = self.audio.as_ref() {
            audio.stop();
        }
    }

    /// The client's audio wish, applied to the lane and then to the tap.
    ///
    /// Both, and in this order. The LANE's gate is what re-arms the config resend on an OFF→ON
    /// edge, so a fresh `AudioStreamConfig` datagram precedes the first frame of a re-enable — the
    /// client may have missed every earlier copy, or predate them. The TAP's gate is the cheap one
    /// that drops the buffer before any extract or encode work. Flipping the tap first would let
    /// one buffer through a lane that has not re-asserted its format yet.
    fn set_audio_forwarding(&self, enabled: bool) {
        if let Some(audio) = self.audio.as_ref() {
            audio.set_enabled(enabled);
        }
        self.capturer.set_audio_forwarding_enabled(enabled);
    }

    fn set_governed_fps(&self, fps: i32) {
        self.capturer.set_governed_fps(fps);
    }

    fn set_client_silence_paused(&self, paused: bool) {
        self.capturer.set_client_silence_paused(paused);
    }

    fn request_keyframe(&self) {
        self.capturer.request_keyframe();
    }

    fn request_ltr_refresh(&self) {
        self.capturer.request_ltr_refresh();
    }

    fn set_self_heal_eligible(&self, eligible: bool) {
        self.capturer.set_self_heal_eligible(eligible);
    }

    fn set_self_heal_loss_rate(&self, rate: f64) {
        self.capturer.set_self_heal_loss_rate(rate);
    }

    fn encode_millis_ewma(&self) -> f64 {
        self.capturer.encode_millis_ewma()
    }

    fn audio_lane(&self) -> Option<Arc<AudioSender>> {
        self.audio.clone()
    }

    /// The successor FIRST, this set's capture half second.
    ///
    /// In that order because the successor is minted from `self.audio` — the one member a rebuild
    /// carries over — and [`Self::stop_capture_only`] is written to leave that member alone. Doing
    /// it the other way round would still work today and would break the moment the stop learned to
    /// touch the lane, so the dependency is spelled rather than assumed.
    ///
    /// The successor inherits the lane by CLONE, not by move: both sets hold it until the caller
    /// installs one, and an abandoned rebuild that never installs drops its clone without stopping
    /// a lane the live set is still sending on.
    fn hand_over(&self, capturer: Capturer, encoder: Arc<EncoderSlot>) -> Option<Arc<dyn CaptureStream>> {
        let successor: Arc<dyn CaptureStream> = Arc::new(Self::new(capturer, encoder, self.audio.clone()));
        self.stop_capture_only();
        Some(successor)
    }

    /// The swap, then the reconfigure, and the swap BACK if the framework refused.
    ///
    /// In that order and no other. New-size buffers must reach the new-size encoder, so the pump
    /// is re-pointed before the stream is told anything; the reconfigure is what can fail, and
    /// after a failure the live stream is still running at the OLD size, so the old encoder has to
    /// be under it again before this answers. What the restore puts back is what the swap took
    /// out — see [`crate::session_pump::Retired`] — rather than a size recomputed from the
    /// pre-resize geometry.
    ///
    /// The capturer is UNTOUCHED apart from its configuration: its governed-fps latch, its audio
    /// forwarding gate, its heartbeat and its keyframe latch all belong to a stream that never
    /// stopped, which is the whole saving this path exists for.
    fn resize_in_place(
        &self,
        encoder: &Arc<Encoder>,
        pixel_width: i32,
        pixel_height: i32,
    ) -> Result<(), CannotResizeInPlace> {
        let retired = self.encoder.swap(encoder, pixel_width, pixel_height);
        // Drained HERE, before the stream can deliver a new-size frame to the new encoder — see
        // `Retired::complete_frames`. The drain after `install_swapped` stays as the belt.
        retired.complete_frames();
        let outcome = self.capturer.resize(pixel_width, pixel_height);
        if outcome.is_err() {
            self.encoder.restore(retired);
        }
        outcome
    }

    /// Steps 1 and 3 of [`Self::stop`], without steps 2 and 4.
    ///
    /// The heartbeat is stopped and JOINED first for the same reason the full teardown does it
    /// first: it is the only thing here that reaches back into the session, so the capturer below
    /// is racing a tick until this returns. The latch is set before either, which is what makes a
    /// later [`Self::start_heartbeat`] — or a later full [`Self::stop`] — a no-op.
    ///
    /// The audio lane is UNTOUCHED, deliberately. See [`CaptureStream::stop_capture_only`].
    fn stop_capture_only(&self) {
        self.stopped.store(true, Ordering::Release);
        self.heartbeat.stop();
        self.capturer.stop();
    }

    fn arm_heartbeat(&self, session: &Arc<Session>) {
        self.start_heartbeat(session);
    }

    fn reanchor(&self, window_origin: slopdesk_video::geometry::VideoPoint) {
        self.capturer.reanchor(window_origin);
    }

    fn is_display_anchored(&self) -> bool {
        self.capturer.is_display_anchored()
    }

    fn is_union_anchored(&self) -> bool {
        self.capturer.is_union_anchored()
    }
}

/// One heartbeat tick: the keepalive, then the client-silence check.
///
/// A free function over `&Session` rather than a method, because it is this module's own half of
/// the session and nothing outside the heartbeat calls it.
///
/// The keepalive is fire-and-forget. A lost one costs nothing — the client's stall threshold
/// tolerates two consecutive losses — which is why this never retries and never queues.
fn heartbeat_tick(session: &Session) {
    if !session.locked_state().media_flowing() {
        // A session that has gone back to listening must go SILENT, or the client's stall monitor
        // reads a dead stream as a live one.
        return;
    }
    session.send_control(&VideoControlMessage::Keepalive);
    push_client_silence_pause(session);
}

/// Pauses or resumes video for client silence, on the TRANSITION only.
///
/// The pause is distinct from the idle reaper: it keeps the session streaming, advances no encoder
/// reference, and resumes on the next inbound datagram — so detach tolerance is unchanged and the
/// reaper still reclaims a client that is genuinely gone. The verdict is
/// [`ClientLiveness::should_pause`]'s; this only actuates it.
///
/// The capture handle is cloned out from under the liveness lock before it is driven. Two locks
/// held across a framework call is how a heartbeat tick ends up behind a resize.
fn push_client_silence_pause(session: &Session) {
    let now = session.now();
    let threshold = session.gates.client_silence_pause_seconds;
    let transition = {
        let mut liveness = session.locked_liveness();
        let wanted = liveness.should_pause(now, threshold);
        let changed = wanted != liveness.paused;
        liveness.paused = wanted;
        drop(liveness);
        changed.then_some(wanted)
    };
    let Some(paused) = transition else {
        return;
    };
    let capture = session
        .locked_streaming()
        .as_ref()
        .and_then(|live| live.live.capture.clone());
    if let Some(capture) = capture {
        capture.set_client_silence_paused(paused);
    }
}

/// A periodic worker that can be armed once and stopped once.
///
/// A thread and a condvar rather than a timer, because the ONE thing a stop must guarantee is that
/// no tick is in flight when it returns — a tick reaches the session's locks and the capture
/// stream, and a teardown that raced one would be tearing down under a live reader. The condvar is
/// what makes the stop immediate rather than a wait-out of the interval.
#[derive(Debug)]
struct Heartbeat {
    /// Shared with the worker, which is the only reason it is behind an [`Arc`].
    gate: Arc<Gate>,
    /// `None` before the arm and after the stop. Taking it is what makes a second stop a no-op.
    worker: Mutex<Option<JoinHandle<()>>>,
}

/// The stop flag and the wakeup that goes with it, as one shareable value.
#[derive(Debug, Default)]
struct Gate {
    /// Sticky-true once a stop has been asked for. The worker re-reads it after every wait.
    stopping: Mutex<bool>,
    /// What turns the stop from a wait-out of the interval into an immediate one.
    wake: Condvar,
}

impl Heartbeat {
    /// A heartbeat with no thread behind it yet.
    fn idle() -> Self {
        Self {
            gate: Arc::new(Gate::default()),
            worker: Mutex::new(None),
        }
    }

    /// Arms the worker. `tick` answers whether to keep going; a `false` ends the thread.
    ///
    /// Takes a closure rather than a session so the cadence, the wakeup and the join discipline can
    /// be driven by a test that has no session and no sockets — this is the only piece of the
    /// bring-up that is periodic, and a periodic thing nobody can test is one nobody can fix.
    fn start(&self, interval: Duration, mut tick: impl FnMut() -> bool + Send + 'static) {
        let gate = Arc::clone(&self.gate);
        let spawned = thread::Builder::new()
            .name("slopdesk-video-heartbeat".to_owned())
            .spawn(move || {
                while gate.sleep(interval) {
                    if !tick() {
                        break;
                    }
                }
            })
            .ok();
        let mut worker = self.worker.lock().unwrap_or_else(PoisonError::into_inner);
        *worker = spawned;
    }

    /// Signals the worker and JOINS it. Idempotent, and safe on one that was never armed.
    ///
    /// The join is not optional: it is the whole reason this exists rather than a detached thread
    /// with a flag. See the type's note.
    fn stop(&self) {
        {
            let mut stopping = self.gate.stopping.lock().unwrap_or_else(PoisonError::into_inner);
            *stopping = true;
        }
        self.gate.wake.notify_all();
        let worker = self.worker.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(worker) = worker {
            drop(worker.join());
        }
    }
}

impl Gate {
    /// Waits one interval, or until stopped. Answers whether a tick should run.
    ///
    /// The stop flag is re-read after the wait rather than trusting the timeout report, because a
    /// spurious wakeup and a stop are the same event to `wait_timeout` and only the flag tells them
    /// apart.
    fn sleep(&self, interval: Duration) -> bool {
        let stopping = self.stopping.lock().unwrap_or_else(PoisonError::into_inner);
        if *stopping {
            return false;
        }
        let (stopping, _timed_out) = self
            .wake
            .wait_timeout(stopping, interval)
            .unwrap_or_else(PoisonError::into_inner);
        !*stopping
    }
}

/// A point dimension in capture PIXELS: points times the scale, floored at one.
///
/// Both bounds are real. The floor is what stops a window that reported a zero height from
/// configuring a zero-height compression session, and the ceiling is what stops a garbage bounds
/// read from wrapping into a negative dimension the framework would take at face value.
///
/// The multiply and the round stay SEPARATE from any add — no fused multiply-add anywhere on this
/// path, because the sizes it produces are pinned by `golden/golden_vectors.json`.
///
/// `pub(crate)` for [`crate::session_resize`], which sizes a rebuild the same way a bring-up sizes
/// the first stream. A second spelling of this arithmetic is exactly what the pin forbids.
pub(crate) fn pixels(points: u16, scale: f64) -> i32 {
    let scaled = f64::from(points) * scale;
    let bounded = if scaled.is_finite() {
        scaled.round().clamp(1.0, f64::from(i32::MAX))
    } else {
        1.0
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "clamped into i32's range on the line above, so no value is left that can wrap"
    )]
    let value = bounded as i32;
    value
}

/// The maximum POINT size this target can be resized to, or `None` when nothing can be said.
///
/// Three answers in priority order, and the order is the whole function:
///
/// 1. A PARKED window's recorded resize limit. It is the tightest and the only one that is
///    authoritative — a resize past the virtual display's framebuffer pushes the capture crop off
///    the display, and no display enumeration knows that.
/// 2. The DISPLAY the target sits on. A full-desktop session's own frame is exactly this, since it
///    never resizes; a window's is the display its frame lands on.
/// 3. The target's own current size, as the degenerate fallback. It is never zero, which is the
///    property this function exists to guarantee — a zero would cap the client's resize fields at
///    nothing.
///
/// The display PICK is `slopdesk_video::window_list`'s; only the enumeration that feeds it is
/// impure, and that stays in the caller.
fn display_max_points(target: Target, bounds: VideoRect, displays: &[VideoRect]) -> Option<(u16, u16)> {
    let size = match target {
        Target::Window {
            resize_limit: Some((width, height)),
            ..
        } => (width, height),
        Target::Display { .. } => (bounds.size.width, bounds.size.height),
        Target::Window { .. } => {
            display_for_window_frame(bounds, displays)
                .map_or((bounds.size.width, bounds.size.height), |display| {
                    (display.size.width, display.size.height)
                })
        },
    };
    let width = wire_points(size.0)?;
    let height = wire_points(size.1)?;
    Some((width, height))
}

/// One point dimension as the wire carries it, or `None` for anything under a point.
///
/// A zero or a negative is REFUSED rather than floored: this number caps a client's resize fields,
/// and a one-point ceiling is a worse answer than saying nothing at all.
fn wire_points(points: f64) -> Option<u16> {
    if !points.is_finite() || points < 1.0 {
        return None;
    }
    let bounded = points.round().clamp(1.0, f64::from(u16::MAX));
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "clamped into u16's range on the line above, and positive by the guard before it"
    )]
    let value = bounded as u16;
    Some(value)
}

/// The overlay's answers for one rules-crate key table, in that table's own order.
///
/// The names are resolved through the settings overlay — `docs/58`'s env → `video-prefs.json`
/// precedence — and handed back POSITIONALLY, which is the shape every `from_env` in
/// `slopdesk_video` takes. The rules crate reads them by name from there.
fn resolved<const N: usize>(overlay: &Overlay, keys: &[&str; N]) -> [Option<String>; N] {
    core::array::from_fn(|index| keys.get(index).and_then(|key| overlay.get(key)))
}

/// The borrowed view of [`resolved`]'s answers, which is what `from_env` actually takes.
///
/// Two functions because the `String`s must outlive the borrow, and one function returning both
/// would be returning a value that borrows from itself.
fn borrowed<const N: usize>(texts: &[Option<String>; N]) -> [Option<&str>; N] {
    core::array::from_fn(|index| texts.get(index).and_then(|slot| slot.as_deref()))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::atomic::AtomicU32;
    use std::sync::{Weak, mpsc};

    use slopdesk_video::geometry::VideoRect;
    use slopdesk_video::host_gates::{GateContext, HostGates};
    use slopdesk_video::recovery_idr::RecoveryIdrConfig;
    use slopdesk_video::recovery_routing::VideoChannel;
    use slopdesk_video::session_state::VideoSessionStateMachine;

    use super::*;
    use crate::mux_lane::{LaneControl, LaneRetired, MuxLaneTransport};
    use crate::mux_sink::MuxSinkTable;
    use crate::session_wiring::SessionSpec;

    /// The two timings a live daemon resolves before it folds the gate table, spelled the way the
    /// rules crate spells them — a made-up pair would exercise a clamp that never runs.
    const CONTEXT: GateContext = GateContext {
        scroll_resampler_active: false,
        keepalive_interval: slopdesk_video::keepalive::KEEPALIVE_INTERVAL_SECONDS,
        idle_timeout: slopdesk_video::keepalive::IDLE_TIMEOUT_SECONDS,
    };

    /// A shared flow that records nothing and refuses nothing, so a session can exist with no
    /// sockets anywhere near it.
    #[derive(Debug, Default)]
    struct Flow {
        sent: AtomicU32,
    }

    impl LaneControl for Flow {
        fn admit(&self, _channel_id: u32) {}
        fn retire(&self, _channel_id: u32) {}
        fn send(&self, _datagram: &[u8], _channel: VideoChannel, _channel_id: u32) {
            self.sent.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// The registry's half of a lane's retirement, which a test session never consults.
    #[derive(Debug, Default)]
    struct Registry;

    impl LaneRetired for Registry {
        fn lane_retired(&self, _channel_id: u32) {}
    }

    /// A capture sink that answers nothing, for the one test that needs a real [`Capturer`] rather
    /// than a double of one.
    #[derive(Debug)]
    struct Silent;

    impl CaptureEvents for Silent {
        fn frame(
            &self,
            _image: &slopdesk_apple_vt::CVImageBuffer,
            _presentation: slopdesk_apple_vt::Timestamp,
            _plan: crate::capture::FramePlan,
        ) {
        }
        fn audio(&self, _sample: &slopdesk_apple_sck::CMSampleBuffer) {}
        fn scroll(&self, _hint: slopdesk_video::scroll_reproject::ScrollHint) {}
        fn capture_failed(&self) {}
    }

    /// A capture stream that records what was asked of it, so the ORDER of a teardown is a value a
    /// test can read rather than a sequence it has to trust.
    #[derive(Debug, Default)]
    struct Recorder {
        stops: AtomicU32,
        audio_gate: Mutex<Vec<bool>>,
        pauses: Mutex<Vec<bool>>,
    }

    impl CaptureStream for Recorder {
        fn stop(&self) {
            self.stops.fetch_add(1, Ordering::Relaxed);
        }
        fn set_audio_forwarding(&self, enabled: bool) {
            self.audio_gate
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(enabled);
        }
        fn set_governed_fps(&self, _fps: i32) {}
        fn set_client_silence_paused(&self, paused: bool) {
            self.pauses
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(paused);
        }
        fn request_keyframe(&self) {}
        fn request_ltr_refresh(&self) {}
    }

    /// A listening session over a lane with no socket under it.
    ///
    /// The registry handle is returned with it because the lane holds only a `Weak` to it, and a
    /// dropped registry would make every retirement a no-op for a reason the test did not choose.
    fn session(target: Target) -> (Arc<Session>, Arc<Registry>) {
        let registry = Arc::new(Registry);
        // The unsizing happens at this typed binding, not inside `downgrade`. `registry` is
        // returned to the caller, so the allocation outlives the strong handle dropped here.
        let watcher: Arc<dyn LaneRetired> = registry.clone();
        let observer: Weak<dyn LaneRetired> = Arc::downgrade(&watcher);
        let flow: Arc<dyn LaneControl> = Arc::new(Flow::default());
        let transport = Arc::new(MuxLaneTransport::new(
            1,
            flow,
            Arc::new(MuxSinkTable::new()),
            observer,
        ));
        let mut gates = HostGates::from_env(&[], CONTEXT);
        // The paced drain owns a thread of its own and none of these tests is about pacing.
        gates.send_lane_enabled = false;
        let session = Arc::new(Session::new(
            SessionSpec {
                target,
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

    /// Installs a recorded capture stream and an unopened encoder as the live set, answering the
    /// recorder so the test can read what the teardown did to it.
    fn install(session: &Arc<Session>, holds_display_wake: bool) -> Arc<Recorder> {
        let recorder = Arc::new(Recorder::default());
        let encoder = Arc::new(Encoder::new(
            EncodeShape::default(),
            None,
            &Overlay::from_text(""),
        ));
        let installed: Arc<dyn CaptureStream> = recorder.clone();
        let mut live = Live::new();
        let _generation = live.install(installed, encoder);
        *session.locked_streaming() = Some(Streaming {
            live,
            holds_display_wake,
            audio_enabled: false,
            geometry: None,
            cursor: None,
            region: RegionState::default(),
        });
        recorder
    }

    fn window_target() -> Target {
        Target::Window {
            id: 7,
            pid: 42,
            size_override: None,
            resize_limit: None,
        }
    }

    /// A DISPLAY target naming no display that exists.
    ///
    /// ⚠️ `u32::MAX` and never a small integer, for the reason `slopdesk-apple-cgdisplay`'s gamma
    /// tests give at length: a real display id here would black the screen of whoever ran this
    /// suite, and a zeroed gamma table outlives the test process that set it. This id lets the
    /// display arm's ORDER be tested — which is all this file owns — while the gamma call itself is
    /// refused by the window server every time.
    fn unreal_display_target() -> Target {
        Target::Display { id: u32::MAX }
    }

    #[test]
    fn a_point_size_scales_into_pixels_and_never_leaves_the_wire_range() {
        assert_eq!(
            pixels(800, 2.0),
            1600,
            "a Retina window captures at twice its points"
        );
        assert_eq!(
            pixels(0, 2.0),
            1,
            "a zero would configure a zero-height encoder session"
        );
        assert_eq!(
            pixels(u16::MAX, 1_000_000.0),
            i32::MAX,
            "a garbage scale must clamp rather than wrap into a negative dimension"
        );
        assert_eq!(
            pixels(100, f64::NAN),
            1,
            "a non-finite scale must not escape the clamp"
        );
    }

    #[test]
    fn a_parked_windows_recorded_limit_outranks_every_display_it_might_sit_on() {
        let target = Target::Window {
            id: 1,
            pid: 2,
            size_override: None,
            resize_limit: Some((1024.0, 768.0)),
        };
        let displays = [VideoRect::xywh(0.0, 0.0, 3840.0, 2160.0)];
        assert_eq!(
            display_max_points(target, VideoRect::xywh(0.0, 0.0, 400.0, 300.0), &displays),
            Some((1024, 768)),
            "a resize past the virtual display's framebuffer pushes the crop off the display"
        );
    }

    #[test]
    fn a_window_with_no_limit_takes_the_display_it_sits_on() {
        let displays = [
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
            VideoRect::xywh(1920.0, 0.0, 3840.0, 2160.0),
        ];
        let bounds = VideoRect::xywh(2000.0, 100.0, 400.0, 300.0);
        assert_eq!(
            display_max_points(window_target(), bounds, &displays),
            Some((3840, 2160)),
            "the second display is the one the frame lands on"
        );
    }

    #[test]
    fn a_window_on_no_known_display_falls_back_to_its_own_size_and_never_to_zero() {
        let bounds = VideoRect::xywh(-9000.0, -9000.0, 400.0, 300.0);
        assert_eq!(
            display_max_points(window_target(), bounds, &[]),
            Some((400, 300)),
            "the degenerate fallback still reports a reachable size"
        );
        assert_eq!(
            display_max_points(window_target(), VideoRect::xywh(0.0, 0.0, 0.0, 0.0), &[]),
            None,
            "nothing at all is a better answer than a one-point resize ceiling"
        );
    }

    #[test]
    fn a_display_target_reports_its_own_frame_because_it_never_resizes() {
        let bounds = VideoRect::xywh(0.0, 0.0, 2560.0, 1440.0);
        assert_eq!(
            display_max_points(Target::Display { id: 3 }, bounds, &[]),
            Some((2560, 1440))
        );
    }

    #[test]
    fn the_heartbeat_ticks_on_its_interval_and_a_stop_joins_it_at_once() {
        let heartbeat = Heartbeat::idle();
        let (sender, receiver) = mpsc::channel();
        heartbeat.start(Duration::from_millis(5), move || sender.send(()).is_ok());
        receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("the worker must tick without being woken");
        heartbeat.stop();
        heartbeat.stop();
    }

    #[test]
    fn a_heartbeat_whose_tick_gives_up_ends_its_own_thread() {
        let heartbeat = Heartbeat::idle();
        let ticks = Arc::new(AtomicU32::new(0));
        let counter = Arc::clone(&ticks);
        // The `false` is what a dead `Weak<Session>` answers: the session is gone, so the worker
        // must end rather than tick against nothing until someone remembers to stop it.
        heartbeat.start(Duration::from_millis(1), move || {
            counter.fetch_add(1, Ordering::Relaxed);
            false
        });
        heartbeat.stop();
        assert!(
            ticks.load(Ordering::Relaxed) <= 1,
            "a tick that answered false must not be followed by another"
        );
    }

    #[test]
    fn a_heartbeat_that_was_never_armed_stops_without_complaint() {
        Heartbeat::idle().stop();
    }

    #[test]
    fn a_teardown_clears_the_slot_and_stops_the_stream_exactly_once() {
        let (session, _registry) = session(window_target());
        let recorder = install(&session, false);
        session.teardown_live(HeldInputFate::Release);
        assert!(
            session.locked_streaming().is_none(),
            "the live slot must be empty for the next bring-up to install into"
        );
        assert_eq!(recorder.stops.load(Ordering::Relaxed), 1);
        // A client `bye` and the idle reaper reach this together in normal operation, and each of
        // the steps under it is a double-free in a different library.
        session.teardown_live(HeldInputFate::Release);
        session.teardown_live(HeldInputFate::Release);
        assert_eq!(
            recorder.stops.load(Ordering::Relaxed),
            1,
            "taking the value out of the Option is what makes the teardown idempotent"
        );
    }

    #[test]
    fn stopping_capture_is_the_teardown_and_nothing_besides() {
        let (session, _registry) = session(window_target());
        let recorder = install(&session, false);
        session.stop_capture();
        assert_eq!(recorder.stops.load(Ordering::Relaxed), 1);
        assert!(session.locked_streaming().is_none());
    }

    #[test]
    fn a_teardown_releases_the_display_wake_only_when_this_session_took_one() {
        // A window pane must never release an assertion it did not acquire; the flag on the live
        // set is the only memory of which kind of session this was by the time a teardown runs.
        let (window, _window_registry) = session(window_target());
        let _recorder = install(&window, false);
        window.teardown_live(HeldInputFate::Release);

        let (display, _display_registry) = session(Target::Display { id: 5 });
        let _display_recorder = install(&display, true);
        display.teardown_live(HeldInputFate::Release);
        // The assertion count clamps at zero on the owner thread, so the pair above is observable
        // only as the absence of a hang: a release that underflowed would hold the host's display
        // awake until the daemon died.
    }

    #[test]
    fn the_audio_wish_is_latched_on_the_live_set_and_pushed_to_the_stream() {
        let (session, _registry) = session(window_target());
        let recorder = install(&session, false);
        session.apply_audio_control(true);
        assert!(
            session
                .locked_streaming()
                .as_ref()
                .is_some_and(|live| live.audio_enabled),
            "the latch is what a resize rebuild re-asserts the gate from"
        );
        session.apply_audio_control(false);
        assert!(
            session
                .locked_streaming()
                .as_ref()
                .is_some_and(|live| !live.audio_enabled)
        );
        assert_eq!(
            *recorder.audio_gate.lock().unwrap_or_else(PoisonError::into_inner),
            vec![true, false],
            "every wish reaches the stream, in the order the client sent it"
        );
    }

    #[test]
    fn an_audio_wish_that_arrives_after_the_teardown_touches_nothing() {
        let (session, _registry) = session(window_target());
        let recorder = install(&session, false);
        session.teardown_live(HeldInputFate::Release);
        session.apply_audio_control(true);
        assert!(
            recorder
                .audio_gate
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_empty(),
            "a torn-down set must not be driven by a message still in flight"
        );
    }

    #[test]
    fn a_window_session_has_no_display_to_blank_and_the_effect_is_a_no_op() {
        // The one arm of `apply_privacy_mode` that is reachable headlessly. The DISPLAY arm is
        // not: it is a real `CGSetDisplayTransferByTable`, whose cases are all tested against a
        // fake in `crate::privacy` — where the whole blank lives precisely so this file can stay
        // an order and take no privacy decision of its own.
        let (session, _registry) = session(window_target());
        let recorder = install(&session, true);
        session.apply_privacy_mode(true);
        assert!(
            session
                .privacy
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_none(),
            "a window target names no display, so there is nothing a blank could darken"
        );
        assert_eq!(
            recorder.stops.load(Ordering::Relaxed),
            0,
            "and the blank is never wired to the live set — it has its own lock for that reason"
        );
        session.teardown_live(HeldInputFate::Release);
    }

    /// The race this whole ordering exists for: a `PrivacyMode { enabled: true }` still in the
    /// inbound queue when the session is torn down must darken NOTHING.
    ///
    /// The loss it prevents has no undo. A gamma table zeroed after the teardown has restored stays
    /// zeroed past the daemon's own exit — measured, not assumed — so the host's screen would be
    /// dark with nothing left alive to light it. `teardown_live` empties `streaming` before it
    /// takes the privacy lock, and this arm refuses an engage under that lock when `streaming`
    /// is `None`.
    #[test]
    fn a_privacy_wish_that_arrives_after_the_teardown_darkens_nothing() {
        let (session, _registry) = session(unreal_display_target());
        let _recorder = install(&session, true);
        session.teardown_live(HeldInputFate::Release);
        session.apply_privacy_mode(true);
        assert!(
            session
                .privacy
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_none(),
            "a torn-down session must never construct a blank it will not be alive to restore"
        );
    }

    /// A teardown TAKES the blank rather than leaving a disengaged one behind, so a wish arriving
    /// after it finds nothing and the second teardown has nothing to restore twice.
    #[test]
    fn a_teardown_takes_the_blank_and_a_second_one_finds_nothing() {
        let (session, _registry) = session(unreal_display_target());
        let _recorder = install(&session, true);
        session.apply_privacy_mode(true);
        session.teardown_live(HeldInputFate::Release);
        assert!(
            session
                .privacy
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_none(),
            "step 3 takes the value, so a late wish has nothing to re-engage"
        );
        // Idempotent by the same take: the second call is the `bye`-racing-the-reaper path.
        session.teardown_live(HeldInputFate::Release);
    }

    /// A refused gamma call leaves the session NOT private, and says so by leaving the controller
    /// disengaged — the arm that must never report a privacy the host never entered.
    ///
    /// Runs headlessly because the display id names nothing: the window server refuses it, which is
    /// exactly the failure a real host reaches when the blank cannot be applied.
    #[test]
    fn a_refused_blank_leaves_the_session_visibly_not_private() {
        let (session, _registry) = session(unreal_display_target());
        let _recorder = install(&session, true);
        session.apply_privacy_mode(true);
        let privacy = session.privacy.lock().unwrap_or_else(PoisonError::into_inner);
        assert!(
            privacy.as_ref().is_some_and(|blank| !blank.is_engaged()),
            "the controller exists so the client's re-assert retries, but it is not engaged"
        );
        drop(privacy);
        session.teardown_live(HeldInputFate::Release);
    }

    /// Disengaging is answered for a session whose stream has already gone. That arm HEALS a host,
    /// and the liveness check guards only the engage — refusing the restore for tidiness would be
    /// refusing the one call that can give a screen back.
    #[test]
    fn a_disengage_is_answered_even_after_the_stream_is_over() {
        let (session, _registry) = session(unreal_display_target());
        let _recorder = install(&session, true);
        session.teardown_live(HeldInputFate::Release);
        session.apply_privacy_mode(false);
        assert!(
            session
                .privacy
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_none(),
            "a disengage on a dead session is a no-op, never a panic and never a construction"
        );
    }

    #[test]
    fn a_silent_client_is_paused_once_and_a_never_silent_one_is_never_touched() {
        let (session, _registry) = session(window_target());
        let recorder = install(&session, false);
        // A client that never sent feedback is never paused, however long it is quiet — the same
        // never-act-without-evidence rule the idle reaper uses.
        push_client_silence_pause(&session);
        assert!(
            recorder
                .pauses
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_empty()
        );
        {
            let mut liveness = session.locked_liveness();
            liveness.saw_feedback = true;
            liveness.last_inbound = -1_000.0;
        }
        push_client_silence_pause(&session);
        push_client_silence_pause(&session);
        let pauses = recorder
            .pauses
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        // Zero when the gate is off, which is the shipped default — the capturer is then never
        // told to pause at all and the host is byte-identical to one without the feature.
        if session.gates.client_silence_pause_seconds > 0.0 {
            assert_eq!(
                pauses,
                vec![true],
                "the pause is pushed on the TRANSITION, not every tick"
            );
        } else {
            assert!(
                pauses.is_empty(),
                "a disabled threshold never reaches the capturer"
            );
        }
    }

    #[test]
    fn a_refused_in_place_resize_puts_the_old_encoder_back_under_the_live_stream() {
        // A REAL `Capturer` with no stream behind it, which is the one in-place refusal reachable
        // without a window server — and the one whose contract matters most: after it, the live
        // set has to be exactly what the swap found, or the restart path inherits a stream running
        // at one size into an encoder opened for another.
        let sink: Arc<dyn CaptureEvents> = Arc::new(Silent);
        let capturer = Capturer::new(CaptureShape::default(), sink, &Overlay::from_text(""));
        let built = Arc::new(Encoder::new(
            EncodeShape::default(),
            None,
            &Overlay::from_text(""),
        ));
        let slot = EncoderSlot::new(&built);
        let live = LiveCapture::new(capturer, Arc::clone(&slot), None);
        let incoming = Arc::new(Encoder::new(
            EncodeShape::default(),
            None,
            &Overlay::from_text(""),
        ));

        let refused = live.resize_in_place(&incoming, 1280, 720);

        assert_eq!(
            refused,
            Err(CannotResizeInPlace::NoStream),
            "a capture that never started has no configuration to rewrite"
        );
        let (held, accepts) = slot.current();
        assert!(
            Arc::ptr_eq(&held, &built),
            "the swap is undone by the refusal, or frames would go to an encoder the stream is not sized for"
        );
        assert_eq!(
            accepts, None,
            "the size guard goes back to disarmed with it — this pump has never been re-pointed"
        );
    }
}
