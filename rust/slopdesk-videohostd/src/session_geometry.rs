//! Where the two watchers publish: the geometry channel, the cursor channel, and the DIALOG-EXPAND
//! rebuild the region half asks for.
//!
//! [`crate::windowgeometry`] and [`crate::cursor`] are complete and decide nothing about a session
//! — one polls a window frame at 30 Hz, the other samples a pointer at 120 Hz, and both publish
//! through a trait. This file is the other end of those two traits, and it is the only reason
//! either of them runs: the Swift host session's `onGeometry`, `onAssociatedUnion`,
//! `scheduleContract`, `applyCaptureRegion`, `recoverPlainWindowCapture` and
//! `onCursorUpdate`/`onCursorShape`.
//!
//! ## Both pumps hold a `Weak<Session>`, and that is the whole lifetime story
//! The session owns the watcher, the watcher owns the sink, and a strong edge back would close a
//! cycle nothing could drop. Each publish upgrades, does its work and lets go — the same shape
//! [`crate::session_pump`] uses for the encoded-frame path and for the same reason. A session torn
//! down between two polls simply fails to upgrade, which is the poll that publishes nothing.
//!
//! ## Three things happen on a window MOVE, and only the first is on the wire
//! 1. The [`WindowGeometryMessage`] goes out on [`VideoChannel::Geometry`], so the client's own
//!    window repositions BEFORE the next video frame rather than a frame behind it.
//! 2. The input and cursor MAPPING re-origins to the new frame — but only while the capture is at
//!    the plain window frame. [`should_reorigin_to_window_on_geometry`] owns that condition: under
//!    an expanded region the mapping belongs to the UNION, and re-origining would put every click
//!    in the dialog area at the wrong absolute point.
//! 3. The display-anchored CROP re-anchors, which is a framework reconfigure and therefore the one
//!    step that is gated on both of [`crate::session::CaptureStream::is_display_anchored`] and
//!    [`crate::session::CaptureStream::is_union_anchored`]: per-window mode has no crop to move,
//!    and a union crop is the region sampler's to re-decide rather than the mover's to slide.
//!
//! ## The region half is a rebuild, and rebuilds do not overlap
//! [`RegionState::rebuilding`] is the latch. Without it a poll landing inside the ~120 ms an
//! `SCStream` takes to spin up would start a SECOND rebuild against a set the first has already
//! stopped, and two live capturers would encode two sizes into one send lane — the failure
//! [`crate::session_resize`]'s own step 4 note names, reached from a different direction.
//!
//! A CONTRACT is debounced by [`CONTRACT_DEBOUNCE`] and an EXPAND is not, which is not a symmetry
//! anyone forgot: a menu that opens, is picked from and closes inside half a second would otherwise
//! rebuild the encoder twice for a picture the person never finished looking at, while an expand
//! that waited would show them a cropped dialog for the length of the wait.
//!
//! ⚠️ GUI + TCC ONLY below [`Session::apply_capture_region`]: the rebuild it drives opens a
//! `VTCompressionSession` and starts an `SCStream`, so no test here reaches it. What IS testable —
//! the debounce token, the latch, the decision routing — is at the bottom of this file.

use std::sync::{Arc, Weak};
use std::thread;
use std::time::Duration;

use slopdesk_apple_sck::CaptureRegion;
use slopdesk_video::capture_recovery::{CaptureFailureAction, capture_failure_action};
use slopdesk_video::capture_region::{
    DEFAULT_MIN_DELTA, RegionDecision, mask_rects, region_decision, should_reorigin_to_window_on_geometry,
};
use slopdesk_video::geometry::{VideoPoint, VideoRect};
use slopdesk_video::recovery_routing::VideoChannel;
use slopdesk_video::video_control::{MaskRect, VideoControlMessage};
use slopdesk_video::window_geometry::WindowGeometryMessage;

use crate::cursor::{CursorSampler, HostPointer, HostShape, MainHop, SendsCursor};
use crate::session::Session;
use crate::session_capture::pixels;
use crate::session_resize::{Rebuilt, Replaced};
use crate::session_wiring::Target;
use crate::windowgeometry::{GeometryChange, GeometryWatcher, HostGeometry, SendsGeometry};

/// How long a CONTRACT waits before it rebuilds, and what an EXPAND inside the window cancels.
///
/// The Swift's 400 ms verbatim. Long enough that open → pick → close on a menu costs one rebuild
/// rather than two, short enough that a genuinely closed dialog does not leave the stream carrying
/// its empty rectangle for a noticeable beat.
pub const CONTRACT_DEBOUNCE: Duration = Duration::from_millis(400);

/// How long after a content mask its duplicate goes out.
///
/// [`crate::session_capture`]'s cadence duplicate for the same reason and at the same spacing: the
/// mask is sent once per region change and there is no second chance to say it, so a client that
/// missed the only copy would mask the wrong pixels until the NEXT dialog opened. Application is
/// idempotent — last wins — so the copy that arrives costs one decode.
pub const MASK_DUP_DELAY: Duration = Duration::from_millis(25);

/// The 30 Hz window-frame poller, as one session installs it.
pub type LiveGeometry = GeometryWatcher<HostGeometry, Arc<GeometryPump>>;

/// The 120 Hz cursor sampler, as one session installs it.
pub type LiveCursor = CursorSampler<HostPointer, HostShape, Arc<CursorPump>, MainHop>;

/// What the session remembers about its DIALOG-EXPAND crop.
///
/// Three fields that are one idea, which is why they are a type rather than three loose members of
/// [`crate::session::Streaming`]: what the capture is pointed at, whether a rebuild owns the set
/// right now, and which pending contract is still the current one.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RegionState {
    /// The union the capture is cropped to, or `None` for the plain window frame.
    ///
    /// `None` is not "unknown": it is the state a fresh bring-up starts in and the state a contract
    /// returns to, and [`should_reorigin_to_window_on_geometry`] reads exactly this distinction.
    pub active: Option<VideoRect>,
    /// Whether a rebuild owns the live set right now.
    ///
    /// See the module note — two overlapping rebuilds put two capturers on one send lane.
    pub rebuilding: bool,
    /// Which scheduled contract is still current.
    ///
    /// A debounce with no cancel: an expand and a fresh contract both BUMP this, and the sleeping
    /// thread compares the value it captured before acting. That is what a cancelled `Task` bought
    /// the Swift, without a handle anything has to hold or remember to drop.
    pub contract_token: u64,
}

/// The geometry channel's host end: a [`Weak<Session>`] and nothing else.
#[derive(Debug)]
pub struct GeometryPump {
    session: Weak<Session>,
}

impl GeometryPump {
    /// A sink that publishes into `session` for as long as it lives.
    #[must_use]
    pub fn new(session: &Arc<Session>) -> Arc<Self> {
        Arc::new(Self {
            session: Arc::downgrade(session),
        })
    }
}

impl SendsGeometry for GeometryPump {
    /// The wire, then the mapping, then the crop — see the module note for why that order and why
    /// only the first is unconditional.
    fn geometry(&self, change: GeometryChange, frame: VideoRect) {
        let Some(session) = self.session.upgrade() else {
            return;
        };
        if !session.locked_state().media_flowing() {
            return;
        }
        let message = match change {
            GeometryChange::Bounds(bounds) => WindowGeometryMessage::Bounds(bounds),
            GeometryChange::Move(origin) => WindowGeometryMessage::Move(origin),
            GeometryChange::Resize(size) => WindowGeometryMessage::Resize(size),
        };
        session.transport.send(&message.encode(), VideoChannel::Geometry);
        session.follow_window(frame);
    }

    fn region(&self, union: VideoRect, contents: &[VideoRect]) {
        let Some(session) = self.session.upgrade() else {
            return;
        };
        session.decide_region(union, contents);
    }
}

/// The cursor channel's host end. Already-encoded bytes straight onto the socket.
///
/// The sampler builds the datagram, so decoding it here for [`Session::send_control`] to build it
/// again would be a parse and a build 120 times a second with no reader — the reason
/// [`crate::cursor::SendsCursor`] takes bytes rather than values.
#[derive(Debug)]
pub struct CursorPump {
    session: Weak<Session>,
}

impl CursorPump {
    /// A sink that publishes into `session` for as long as it lives.
    #[must_use]
    pub fn new(session: &Arc<Session>) -> Arc<Self> {
        Arc::new(Self {
            session: Arc::downgrade(session),
        })
    }

    /// Both messages go out the same way; only the cadence differs.
    fn publish(&self, datagram: &[u8]) {
        let Some(session) = self.session.upgrade() else {
            return;
        };
        if !session.locked_state().media_flowing() {
            return;
        }
        session.transport.send(datagram, VideoChannel::Cursor);
    }
}

impl SendsCursor for CursorPump {
    fn update(&self, datagram: &[u8]) {
        self.publish(datagram);
    }

    fn shape(&self, datagram: &[u8]) {
        self.publish(datagram);
    }
}

impl Session {
    /// Starts the two watchers for this bring-up, or answers a pair of `None` for a display target.
    ///
    /// A DISPLAY never moves, never resizes and grows no attached dialog, so the geometry watcher
    /// has nothing to poll — [`Target`]'s own note calls that absence out. The CURSOR sampler runs
    /// for BOTH kinds, because a full-desktop session needs a pointer exactly as much as a window
    /// one does; what differs is only the rectangle it reports against, which is the whole frame.
    ///
    /// The region sampling is armed HERE rather than after the install, and the arm condition is
    /// the Swift's verbatim: the gate, AND a window the daemon parked on a virtual display. An
    /// unparked window is captured at whatever frame it has, and expanding a crop the daemon
    /// does not own the geometry of would fight whatever else is moving it.
    pub(crate) fn start_watchers(self: &Arc<Self>) -> (Option<LiveGeometry>, Option<LiveCursor>) {
        let bounds = self.window_bounds_cg();
        let cursor = Some(CursorSampler::start(
            HostPointer,
            HostShape,
            CursorPump::new(self),
            MainHop,
            bounds,
        ));
        let Target::Window {
            id,
            pid,
            size_override,
            ..
        } = self.spec.target
        else {
            return (None, cursor);
        };
        let watcher = GeometryWatcher::start(HostGeometry, GeometryPump::new(self), id, pid);
        watcher.arm_region(self.gates.dialog_expand_enabled && size_override.is_some());
        (Some(watcher), cursor)
    }

    /// Re-points everything that maps a client point onto the host, at `rect` in GLOBAL CG points.
    ///
    /// The injector and the cursor sampler together, because they are two halves of one mapping:
    /// the injector turns a normalised client point into an absolute one, the sampler turns an
    /// absolute pointer back into a normalised one, and a session where the two disagreed would
    /// report the cursor somewhere the clicks do not land.
    pub(crate) fn reorigin_mapping(&self, rect: VideoRect) {
        self.reorigin_input(rect);
        let streaming = self.locked_streaming();
        if let Some(cursor) = streaming.as_ref().and_then(|live| live.cursor.as_ref()) {
            cursor.set_bounds(rect);
        }
        drop(streaming);
    }

    /// Re-emits an already-shipped cursor shape, for a client whose one-shot shipment was lost.
    ///
    /// The sampler owns the shape cache and is the only thing that can answer, which is exactly why
    /// this door exists rather than the recovery path holding a second copy: re-READING the cursor
    /// would answer whatever shape is displayed now instead of the id the client asked for.
    pub(crate) fn reship_cursor_shape(&self, shape_id: u16) {
        let streaming = self.locked_streaming();
        if let Some(cursor) = streaming.as_ref().and_then(|live| live.cursor.as_ref()) {
            cursor.reship_shape(shape_id);
        }
        drop(streaming);
    }

    /// The mapping and the crop halves of a window move — steps 2 and 3 of the module note.
    fn follow_window(&self, frame: VideoRect) {
        let (active, capture) = {
            let streaming = self.locked_streaming();
            let read = streaming
                .as_ref()
                .map(|live| (live.region.active, live.live.capture.clone()));
            drop(streaming);
            match read {
                Some(read) => read,
                None => return,
            }
        };
        if should_reorigin_to_window_on_geometry(active) {
            self.reorigin_mapping(frame);
        }
        let Some(capture) = capture else {
            return;
        };
        // BOTH predicates, and both cheap: per-window mode has no crop a reconfigure could move,
        // and a union crop belongs to the region sampler — sliding it under a drag would
        // put the dialog half outside the very rectangle that was measured to contain it.
        // Asking first is what keeps a title-bar drag from entering the capturer's
        // coalescing machinery 30 times a second for an answer that is always "no".
        if capture.is_display_anchored() && !capture.is_union_anchored() {
            capture.reanchor(frame.origin);
        }
    }

    /// Routes one measured union: hold, expand now, or contract after the quiet window.
    ///
    /// Every verdict is [`region_decision`]'s, including the "a union strictly larger than the
    /// frame is a dialog overhanging it" rule and both hysteresis gates. The re-check against
    /// the LIVE region matters and is not redundant with the poller's own: the poller's
    /// baseline is the last union it PUBLISHED, which lags a rebuild by up to one sample.
    fn decide_region(self: &Arc<Self>, union: VideoRect, contents: &[VideoRect]) {
        if !self.locked_state().media_flowing() {
            return;
        }
        let active = {
            let streaming = self.locked_streaming();
            let read = streaming
                .as_ref()
                .map(|live| (live.region.active, live.region.rebuilding));
            drop(streaming);
            match read {
                // A rebuild owns the set; this sample is about a capture that is already changing.
                Some((_, true)) | None => return,
                Some((active, false)) => active,
            }
        };
        match region_decision(union, self.window_bounds_cg(), active, DEFAULT_MIN_DELTA) {
            RegionDecision::Hold => {},
            RegionDecision::Expand(target) => {
                // The pending contract is CANCELLED by the same bump that arms one — a popup that
                // re-opened inside the quiet window needs no shrink-then-grow.
                self.bump_contract_token();
                self.apply_capture_region(Some(target), contents);
            },
            RegionDecision::Contract => self.schedule_contract(),
        }
    }

    /// Arms the debounced contract, superseding whichever one was pending.
    ///
    /// A detached thread and a token rather than a cancellable handle, for
    /// [`Session::send_cadence`]'s reason: the whole obligation is one sleep, and a `Weak` is
    /// what stops a session torn down inside the window from being kept alive by its own
    /// debounce.
    fn schedule_contract(self: &Arc<Self>) {
        let token = self.bump_contract_token();
        let weak = Arc::downgrade(self);
        let spawned = thread::Builder::new()
            .name("slopdesk-region-contract".to_owned())
            .spawn(move || {
                thread::sleep(CONTRACT_DEBOUNCE);
                let Some(session) = weak.upgrade() else {
                    return;
                };
                if session.contract_token() == Some(token) {
                    session.apply_capture_region(None, &[]);
                }
            });
        // A thread that could not be spawned costs the contract and nothing else: the capture stays
        // at the expanded region, which is a larger picture rather than a wrong one, and the next
        // region sample asks again.
        drop(spawned);
    }

    /// Advances the debounce token and answers the new value. Every expand and every contract calls
    /// it, which is what makes either supersede a pending contract.
    fn bump_contract_token(&self) -> u64 {
        let mut streaming = self.locked_streaming();
        let token = streaming.as_mut().map_or(0, |live| {
            live.region.contract_token = live.region.contract_token.wrapping_add(1);
            live.region.contract_token
        });
        drop(streaming);
        token
    }

    /// The current debounce token, or `None` for a session that has stopped streaming.
    ///
    /// The `None` is what stops a contract firing into a session whose whole live set was torn down
    /// while its thread slept.
    fn contract_token(&self) -> Option<u64> {
        let streaming = self.locked_streaming();
        let token = streaming.as_ref().map(|live| live.region.contract_token);
        drop(streaming);
        token
    }

    /// Re-points the capture at `region_global` — `None` being the plain window frame — WITHOUT
    /// touching the window itself.
    ///
    /// [`Session::resize_capture`]'s rebuild minus its accessibility write: the window is untouched
    /// and only the captured RECT and the input mapping move. The client adopts the new size
    /// frame-gated and grows its pane for free, which is the resize path's own ack contract reused
    /// rather than a second one invented here.
    ///
    /// The FAILURE ladder is [`capture_failure_action`]'s, and it is the reason this is a loop
    /// rather than a call: the union start happens AFTER the old capturer was stopped, so a refusal
    /// leaves the session streaming with no capturer at all — a silent forever-freeze. The rungs
    /// are try the union, degrade to the plain window frame, and only then disconnect, because
    /// a visible disconnect the client's reconnect handles beats a frozen picture.
    ///
    /// ⚠️ BLOCKS for a `VTCompressionSession` create and an `SCStream` spin-up, on the geometry
    /// watcher's own thread. That is deliberate: the polls dropped meanwhile are polls about a
    /// capture that is being replaced, and the alternative is a fourth thread whose only job is to
    /// serialise against this one.
    pub(crate) fn apply_capture_region(
        self: &Arc<Self>,
        region_global: Option<VideoRect>,
        contents: &[VideoRect],
    ) {
        if !self.begin_region_rebuild() {
            return;
        }
        // The ladder, walked at most twice: the union, then the plain window frame. A third attempt
        // is not a rung — a host that cannot start a stream at either rectangle has a problem no
        // further attempt fixes.
        let mut attempt = region_global;
        let mut attempt_contents = contents;
        loop {
            match self.rebuild_at_region(attempt, attempt_contents) {
                // Installed, acknowledged and masked, or refused before anything was stopped, or
                // superseded by a newer owner. None of the three owes anything further.
                Rebuild::Applied | Rebuild::Held | Rebuild::Superseded => break,
                Rebuild::Lost => {
                    let flowing = self.locked_state().media_flowing();
                    // `is_fallback_rebuild` is whether the attempt that just failed WAS the plain
                    // window frame — the last rung — which is exactly what `attempt.is_none()`
                    // says.
                    match capture_failure_action(flowing, false, attempt.is_none()) {
                        CaptureFailureAction::RebuildPlainWindow => {
                            attempt = None;
                            attempt_contents = &[];
                        },
                        CaptureFailureAction::Disconnect => {
                            self.end_region_rebuild();
                            // Outside the latch, because the goodbye tears the whole session down
                            // and a teardown must not find a rebuild flag still raised.
                            self.disconnect_after_capture_loss();
                            return;
                        },
                        CaptureFailureAction::Abandon => break,
                    }
                },
            }
        }
        self.end_region_rebuild();
    }

    /// Claims the rebuild latch. `false` when one is already running or the session is not
    /// streaming.
    fn begin_region_rebuild(&self) -> bool {
        let mut streaming = self.locked_streaming();
        let claimed = streaming.as_mut().is_some_and(|live| {
            if live.region.rebuilding {
                return false;
            }
            live.region.rebuilding = true;
            true
        });
        drop(streaming);
        claimed
    }

    /// Releases the latch. Safe on a session whose live set went away underneath the rebuild.
    fn end_region_rebuild(&self) {
        let mut streaming = self.locked_streaming();
        if let Some(live) = streaming.as_mut() {
            live.region.rebuilding = false;
        }
        drop(streaming);
    }

    /// ONE attempt at `region_global`, start to finish.
    ///
    /// The steps are [`Session::resize_capture`]'s, minus the accessibility write and plus the two
    /// things a region rebuild owes that a resize does not: the mapping re-origin to the captured
    /// rectangle, and the transparency mask that tells the client which of its pixels are real.
    fn rebuild_at_region(
        self: &Arc<Self>,
        region_global: Option<VideoRect>,
        contents: &[VideoRect],
    ) -> Rebuild {
        // 1. STILL STREAMING, WITH A LIVE SET, AND A WINDOW. A display target never reaches here —
        //    it has no geometry watcher — so the second guard is defensive rather than a state.
        let Some((capture, encoder, generation)) = self.live_set() else {
            return Rebuild::Held;
        };
        let Target::Window { id, .. } = self.spec.target else {
            return Rebuild::Held;
        };
        let outgoing = Replaced {
            capture: &capture,
            encoder: &encoder,
            generation,
        };

        // 2. THE RECTANGLE, AND THE DISPLAY IT IS LOCAL TO. A contract resolves to the LIVE window
        //    frame rather than to a remembered one: the window may have moved while the dialog was
        //    up, and cropping to where it used to be would stream the desktop beside it.
        let region = region_global.unwrap_or_else(|| self.window_bounds_cg());
        let centre = VideoPoint::new(region.mid_x(), region.mid_y());
        let Some(display) = slopdesk_apple_cgdisplay::under(centre) else {
            // A region centred on no display at all — a screen asleep, a display unplugged
            // mid-dialog. Nothing is stopped and nothing is built, so the live capture keeps
            // running at whatever it was pointed at.
            return Rebuild::Held;
        };
        let override_region = region_global.map(|rect| {
            CaptureRegion {
                display_id: display.id,
                display_local: VideoRect::xywh(
                    rect.min_x() - display.bounds.min_x(),
                    rect.min_y() - display.bounds.min_y(),
                    rect.size.width,
                    rect.size.height,
                ),
            }
        });

        // 3. THE SIZE, IN POINTS AND THEN IN PIXELS. `pixels` is `session_capture`'s own, not a
        //    second spelling of it: these numbers are pinned by `golden/golden_vectors.json`.
        let point_width = wire_axis(region.size.width);
        let point_height = wire_axis(region.size.height);
        let pixel_width = pixels(point_width, self.spec.capture_scale);
        let pixel_height = pixels(point_height, self.spec.capture_scale);

        // 4. THE EPOCH. The RESIZE epoch verbatim, not a counter of this path's own, and the client
        //    is why: it does not re-validate the echoed epoch at all — see `client_session`'s own
        //    note on `ResizeAck` — so the only reader left is the host's own supersede guard, and
        //    what that guard must answer is "has a NEWER resize landed", which is exactly what
        //    presenting the current epoch asks.
        let epoch = self.locked_state().last_resize_epoch();

        // 5. THE REBUILD ITSELF, shared verbatim with the resize path.
        match self.rebuild_live_set(&outgoing, id, epoch, pixel_width, pixel_height, override_region) {
            Rebuilt::Live => {
                self.adopt_region(region_global, region, epoch, point_width, point_height, contents);
                Rebuild::Applied
            },
            // Nothing was stopped — the outgoing set is still capturing at the old rectangle — so
            // this degrades to no-expand rather than to a dead session, and no rung is owed.
            Rebuilt::EncoderRefused => Rebuild::Held,
            Rebuilt::StreamRefused => Rebuild::Lost,
            Rebuilt::Superseded => Rebuild::Superseded,
        }
    }

    /// Everything a LANDED region rebuild owes, in the order the client needs it.
    ///
    /// The mapping FIRST, because a click can arrive on the very next datagram and one mapped
    /// against the old rectangle lands wherever the offset happens to put it. The ack second, so
    /// the client sizes its pane. The mask last, because it is expressed in the pixels the ack
    /// just announced.
    fn adopt_region(
        self: &Arc<Self>,
        region_global: Option<VideoRect>,
        region: VideoRect,
        epoch: u32,
        point_width: u16,
        point_height: u16,
        contents: &[VideoRect],
    ) {
        {
            let mut streaming = self.locked_streaming();
            if let Some(live) = streaming.as_mut() {
                live.region.active = region_global;
            }
            drop(streaming);
        }
        // The CAPTURED rectangle, not the window's: a click in a dialog that sits left of or above
        // the window maps correctly only against the union, and the sampler's own visibility test
        // keys off the same rect so the pointer stays reported over the dialog.
        self.reorigin_mapping(region);
        self.send_control(&VideoControlMessage::ResizeAck {
            capture_width: point_width,
            capture_height: point_height,
            epoch,
        });
        // A CONTRACT sends an EMPTY mask, which is the instruction to stop masking: the plain
        // window frame is fully opaque. Only an expansion has a flank to describe.
        let mask = if region_global.is_none() {
            Vec::new()
        } else {
            mask_rects(
                contents,
                region,
                self.spec.capture_scale,
                pixels(point_width, self.spec.capture_scale),
                pixels(point_height, self.spec.capture_scale),
            )
        };
        self.send_control(&VideoControlMessage::ContentMask(mask.clone()));
        self.dup_content_mask(mask, region_global);
    }

    /// The mask's duplicate, [`MASK_DUP_DELAY`] later, on a detached thread.
    ///
    /// Re-checks that the region has not changed AGAIN in the meantime — a duplicate describing a
    /// crop the capture has already left would mask pixels that are now real content.
    fn dup_content_mask(self: &Arc<Self>, mask: Vec<MaskRect>, region_global: Option<VideoRect>) {
        let weak = Arc::downgrade(self);
        let spawned = thread::Builder::new()
            .name("slopdesk-mask-dup".to_owned())
            .spawn(move || {
                thread::sleep(MASK_DUP_DELAY);
                let Some(session) = weak.upgrade() else {
                    return;
                };
                let still = {
                    let streaming = session.locked_streaming();
                    let still = streaming
                        .as_ref()
                        .is_some_and(|live| live.region.active == region_global);
                    drop(streaming);
                    still
                };
                if still && session.locked_state().media_flowing() {
                    session.send_control(&VideoControlMessage::ContentMask(mask));
                }
            });
        // The first copy is already on the wire; a process out of threads loses the duplicate and
        // nothing else.
        drop(spawned);
    }

    /// The ladder's last rung: say goodbye and stop.
    ///
    /// Reached only when the plain-window fallback ALSO failed to start, which means the session is
    /// streaming with nothing capturing and nothing left that could restart it. A visible
    /// disconnect puts the client on its own reconnect path; the alternative is a frozen
    /// picture the person has no way to interpret.
    fn disconnect_after_capture_loss(self: &Arc<Self>) {
        self.send_control(&VideoControlMessage::Bye);
        crate::diag::say("capture region rebuild lost the stream at both rectangles; disconnecting");
        crate::mux_registry::LaneSession::stop(self.as_ref());
    }
}

/// How far one region attempt got, and therefore whether the ladder owes another rung.
///
/// Deliberately NOT [`Rebuilt`]: that enum answers "what did the shared rebuild do", and this one
/// answers "does the caller still owe something", which folds three of its four arms together. The
/// one arm that must stay apart is the stream refusal, because it is the only outcome that left the
/// session with no capturer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Rebuild {
    /// Installed, acknowledged and masked.
    Applied,
    /// Nothing was stopped and nothing was built. The live capture is untouched.
    Held,
    /// A newer owner is live and owns everything this attempt would have touched.
    Superseded,
    /// The stream refused to start AFTER the old one was stopped — the ladder's own case.
    Lost,
}

/// One axis of a region, in the points the wire carries, with a floor of one.
///
/// Both bounds are real. A zero would divide by zero in the client's aspect fit, and a union wider
/// than `u16::MAX` points does not exist but a garbage bounds read does.
///
/// The `is_finite` test is NOT redundant with the clamp, and [`pixels`] carries the same one for
/// the same reason: `f64::clamp` propagates a NaN rather than bounding it, and the cast then
/// saturates that NaN to ZERO — the one value the floor exists to rule out. A non-finite axis is a
/// garbage bounds read, and the honest answer to one is the smallest capture the wire can carry.
fn wire_axis(points: f64) -> u16 {
    if !points.is_finite() {
        return 1;
    }
    let bounded = points.round().clamp(1.0, f64::from(u16::MAX));
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "clamped into u16's range on the line above, so no value is left that can wrap"
    )]
    let value = bounded as u16;
    value
}

#[cfg(test)]
mod tests {
    use slopdesk_video::geometry::VideoRect;

    use super::{CONTRACT_DEBOUNCE, MASK_DUP_DELAY, RegionState, wire_axis};

    /// A fresh region state is the PLAIN window frame with nothing pending — the state a bring-up
    /// installs and the state a contract returns to. `None` here is load-bearing:
    /// `should_reorigin_to_window_on_geometry` reads exactly this field.
    #[test]
    fn a_fresh_region_is_the_plain_window_frame_with_nothing_in_flight() {
        let region = RegionState::default();
        assert_eq!(region.active, None);
        assert!(!region.rebuilding);
        assert_eq!(region.contract_token, 0);
    }

    /// The debounce is long enough to fold an open-pick-close and short enough not to strand the
    /// stream at a rectangle whose dialog has gone. Pinned because the number IS the behaviour.
    #[test]
    fn the_contract_debounce_outlasts_a_menu_and_the_mask_duplicate_does_not() {
        assert_eq!(CONTRACT_DEBOUNCE.as_millis(), 400);
        assert_eq!(MASK_DUP_DELAY.as_millis(), 25);
        assert!(
            MASK_DUP_DELAY < CONTRACT_DEBOUNCE,
            "the duplicate must land inside the region it describes"
        );
    }

    /// The wire clamp, at both ends. A zero would divide by zero in the client's aspect fit; a
    /// garbage bounds read must saturate rather than wrap into a one-point capture.
    #[test]
    fn a_region_axis_is_clamped_into_the_wires_range_at_both_ends() {
        assert_eq!(wire_axis(1024.4), 1024);
        assert_eq!(wire_axis(0.0), 1, "a zero would divide by zero downstream");
        assert_eq!(wire_axis(-500.0), 1);
        assert_eq!(wire_axis(1e12), u16::MAX);
        assert_eq!(wire_axis(f64::NAN), 1, "a NaN must not escape the clamp");
    }

    /// A rect the size of a whole 5K display still names a size the wire can carry, which is what
    /// makes the clamp above a guard rather than a limit anyone runs into.
    #[test]
    fn an_ordinary_desktop_region_is_nowhere_near_the_clamp() {
        let desktop = VideoRect::xywh(0.0, 0.0, 5120.0, 2880.0);
        assert_eq!(wire_axis(desktop.size.width), 5120);
        assert_eq!(wire_axis(desktop.size.height), 2880);
    }
}
