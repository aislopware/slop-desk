//! The answers that mint nothing: session-LESS control, answered and forgotten.
//!
//! `WindowFeedGlue.swift`'s `makeSessionlessDispatcher`, plus `main.swift`'s `answerWindowList`,
//! `answerDisplayList` and `ListAnswerGuard`.
//!
//! Three of the wire's control messages ask a question about the HOST rather than about a stream —
//! what can I watch, what displays are there, what windows are open right now — and none of them
//! wants a capture session. The mux still bootstraps their lane, because a reply needs a flow to
//! ride on ([`crate::mux_transport`]'s `payload_is_list_request` is where that is decided), but the
//! lane is a courier and not a session: `listWindows` and `listDisplays` retire theirs the instant
//! the reply is on the socket, and only the feed's survives, because Phase 2 pushes ride it between
//! renewals.
//!
//! ## Where this sits in the receive path
//! First. The daemon offers each unbound control datagram here, and only what this file declines
//! reaches [`crate::mux_registry`], which mints. Declining is the whole of the contract: a `false`
//! means "not a question about the host", and the registry then either mints on a hello or drops.
//!
//! ## What it does NOT answer, and why that is a `false` rather than a silence
//! `appIconRequest` and `windowPreviewRequest` are session-less on the wire and stamped by the
//! transport as such, but nothing in the `slopdesk-apple-*` family renders an application icon or
//! takes a window screenshot, so there is no door to call and this file grows no arm for them.
//! Their datagrams fall through to the registry, which drops them as unbound; both clients already
//! treat silence as the answer, and the never-admitted flow stamp is swept on the transport's own
//! timer. `listSystemDialogs` is the third one this file does not answer, for the opposite reason:
//! the feature was removed (`docs/DECISIONS.md`, 2026-07-23) and the wire kept only so the golden
//! vectors stay pinned, so the request is SWALLOWED — consumed, answered with nothing, and never
//! offered to a mint that would have nothing to make.
//!
//! ## Two decisions this file takes, and reports
//! Everything a summary means is [`slopdesk_video`]'s: the inclusion verdict is
//! [`includes_window`], shared with the feed so the picker and the rail cannot drift, and the reply
//! order is [`arrange_streamable_windows`], which keeps minimized and other-Space windows in the
//! answer because the mint path rescues them. What is written here is the pair of CAPS — the codec
//! states in [`VideoControlMessage::encode`]'s own doc that the caller, always the host, must cap a
//! list to one datagram — and which display is the MAIN one, which no crate answers today. Both are
//! named below and both are candidates for promotion.
//!
//! ## Untestable by design, and which half is not
//! The three live answers all reach a framework: two go through `SCShareableContent` and
//! `CoreGraphics`, which need a window server and a Screen-Recording grant and HANG headlessly
//! rather than failing, and the feed's reaches the accessibility tree. Nothing that calls them can
//! be reached by a test, the way [`crate::shareable`] says of the same query. What IS tested here
//! is everything a datagram meets before that: the coalescing guard, and which messages this file
//! claims at all.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_apple_sck::ShareableContent;
use slopdesk_video::capture_recovery::arrange_streamable_windows;
use slopdesk_video::geometry::VideoPoint;
use slopdesk_video::recovery_routing::VideoChannel;
use slopdesk_video::video_control::{DisplaySummary, VideoControlMessage, WindowSummary};
use slopdesk_video::window_feed_host::includes_window;

use crate::feed::{SendsFeed, WindowFeed};
use crate::mux_lane::LaneControl;
use crate::windowprobe::AccessibilityTree;
use crate::windowsource::{HostDesktop, WindowSource, points};

/// The most windows one `windowList` reply carries.
///
/// Sixty-four, carried from the Swift's `prefix(64)`. A cap rather than a guess for the reason the
/// codec states itself: control is not packetized, so a list message must fit ONE datagram, and
/// [`VideoControlMessage::encode`]'s doc puts that on the caller — always the host. It happens to
/// equal [`slopdesk_video::window_feed_host::MAX_RECORDS`] and is not spelled as it: the feed's cap
/// bounds a CHUNKED snapshot and this one bounds a single datagram, so a future change to either
/// has no business moving the other.
pub const MAX_WINDOW_SUMMARIES: usize = 64;

/// The most displays one `displayList` reply carries.
///
/// Sixteen, the Swift's `prefix(16)`, and the same one-datagram reason. Sixteen displays is already
/// more than any host this daemon has met.
pub const MAX_DISPLAY_SUMMARIES: usize = 16;

/// The feed this daemon runs: the real desktop, answering onto the shared lanes.
type HostWindowFeed = WindowFeed<WindowSource<HostDesktop, AccessibilityTree>, FeedLane>;

/// The shared transport, as the two verbs [`WindowFeed`] needs from it.
///
/// The feed talks about a channel and a payload; the lane control talks about a datagram, a channel
/// and a lane id. This is the whole of the difference between them, and it exists so the feed can
/// be handed a recorder in its own tests without knowing a socket exists.
#[derive(Debug)]
struct FeedLane {
    /// Where a datagram goes, and how a lane is closed.
    lanes: Arc<dyn LaneControl>,
}

impl SendsFeed for FeedLane {
    fn send_control(&self, channel_id: u32, payload: &[u8]) {
        self.lanes.send(payload, VideoChannel::Control, channel_id);
    }

    fn retire(&self, channel_id: u32) {
        self.lanes.retire(channel_id);
    }
}

/// One in-flight answer per lane; retransmits while it runs are DROPPED, never queued.
///
/// The discovery path's mirror of [`crate::mux_registry`]'s `minting` mark, and it exists for the
/// same reason that one does. A list lane never mints, so nothing else in the daemon remembers that
/// an answer is already being built — and a lossy, fast-retransmitting or simply looping client
/// would then spawn one `SCShareableContent` enumeration per retransmit, piling up window-server
/// round trips behind each other until the desktop stutters. Dropping is right rather than queuing:
/// the retransmits are copies of ONE question, and the answer in flight is the answer to all of
/// them.
#[derive(Debug, Default)]
struct AnswerGuard {
    /// The lanes whose answer is being built.
    in_flight: Mutex<BTreeSet<u32>>,
}

impl AnswerGuard {
    /// Claims `channel_id`, or reports that an answer for it is already running.
    fn begin(&self, channel_id: u32) -> bool {
        self.locked().insert(channel_id)
    }

    /// Releases `channel_id`, so a later retransmit is answered afresh.
    fn end(&self, channel_id: u32) {
        let _released = self.locked().remove(&channel_id);
    }

    /// Locks the set, treating a poisoned lock as a live one — the crate's idiom, and here it is
    /// also the safe reading: a poisoned guard that refused to unlock would lock every lane out of
    /// discovery for the daemon's whole life.
    fn locked(&self) -> std::sync::MutexGuard<'_, BTreeSet<u32>> {
        self.in_flight.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Which answer a claimed lane is owed. Carried into the answering thread rather than re-decoded
/// there, so the wire is read exactly once per datagram.
#[derive(Debug, Clone, Copy)]
enum Answer {
    /// The picker's list.
    Windows,
    /// The full-desktop pane's list.
    Displays,
    /// A feed renewal, holding the generation the client says it already has.
    Feed {
        /// `0` when the client has nothing.
        known_generation: u32,
    },
}

/// One session-less answer service over the shared transport.
#[derive(Debug)]
pub struct Discovery {
    /// Where a reply goes, and how a courier lane is closed.
    lanes: Arc<dyn LaneControl>,
    /// One answer per lane at a time.
    guard: Arc<AnswerGuard>,
    /// The host-window feed: the roster, the cache, the differ and the push fan-out.
    feed: Arc<HostWindowFeed>,
}

impl Discovery {
    /// A discovery service answering onto `lanes`.
    ///
    /// Starts the feed, which is the one piece here with a life of its own — it holds a roster and
    /// runs a differ while anybody is subscribed. Nothing else is built until a datagram asks.
    #[must_use]
    pub fn new(lanes: Arc<dyn LaneControl>) -> Self {
        let sink = FeedLane {
            lanes: Arc::clone(&lanes),
        };
        Self {
            guard: Arc::new(AnswerGuard::default()),
            feed: Arc::new(WindowFeed::new(crate::windowsource::host_source(), sink)),
            lanes,
        }
    }

    /// Answers `payload` if it is a session-less request.
    ///
    /// `true` means the datagram was consumed — answered, being answered, or deliberately
    /// swallowed — and `false` means it is not a question about the host, so the registry should
    /// see it and mint or drop. A retransmit that arrives while its answer is still being built
    /// reports `true` as well: it was consumed by the coalescing above, and reporting `false` would
    /// hand the registry a non-hello it can only drop, once per retransmit.
    #[must_use]
    pub fn dispatch(&self, channel_id: u32, channel: VideoChannel, payload: &[u8]) -> bool {
        if !matches!(channel, VideoChannel::Control) {
            return false;
        }
        let Ok(message) = VideoControlMessage::decode(payload) else {
            return false;
        };
        match message {
            VideoControlMessage::ListWindows => self.claim(channel_id, Answer::Windows),
            VideoControlMessage::ListDisplays => self.claim(channel_id, Answer::Displays),
            VideoControlMessage::WindowFeedSubscribe { known_generation } => {
                self.claim(channel_id, Answer::Feed { known_generation })
            },
            // DORMANT, and swallowed rather than declined: no shipped client sends it, and the one
            // that did would otherwise have its datagram offered to a mint with nothing to make.
            VideoControlMessage::ListSystemDialogs => true,
            _ => false,
        }
    }

    /// Asks the feed for one immediate differ turn — an app launched, quit or came forward.
    ///
    /// The daemon ticks this; the Swift's `WindowFeedKicker` observed `NSWorkspace` and the
    /// frontmost app's accessibility events and called the same thing, debounced. Inert with no
    /// subscribers, so calling it on a quiet host costs a lock.
    pub fn kick(&self) {
        self.feed.kick();
    }

    /// Claims the lane and answers it on a thread of its own. Always reports `true`.
    ///
    /// The thread is not an optimisation, for [`crate::mux_registry`]'s reason: an enumeration is a
    /// window-server round trip and the feed's reaches a budgeted accessibility sweep, so answering
    /// inline would hold every OTHER lane's datagrams — video, input, keepalives — for as long as
    /// the slowest hung app on the desktop takes to answer.
    ///
    /// The mark is taken BEFORE the spawn, so the retransmit that arrives a millisecond later is
    /// decided against it rather than racing the thread that would have set it.
    fn claim(&self, channel_id: u32, answer: Answer) -> bool {
        if !self.guard.begin(channel_id) {
            return true;
        }
        let lanes = Arc::clone(&self.lanes);
        let feed = Arc::clone(&self.feed);
        let guard = Arc::clone(&self.guard);
        let spawned = std::thread::Builder::new()
            .name("slopdesk.discovery.answer".to_owned())
            .spawn(move || {
                match answer {
                    Answer::Windows => answer_window_list(&lanes, channel_id),
                    Answer::Displays => answer_display_list(&lanes, channel_id),
                    // NOT retired afterwards: the roster's TTL retires a feed lane, three missed
                    // renewals later, because the pushes between renewals ride this very flow.
                    Answer::Feed { known_generation } => feed.answer(channel_id, known_generation),
                }
                guard.end(channel_id);
            })
            .is_ok();
        if !spawned {
            // The spawn was refused. A mark left standing would lock this lane out of discovery for
            // the daemon's whole life, so it is dropped and the client's next retransmit tries
            // again.
            self.guard.end(channel_id);
        }
        true
    }
}

/// One candidate row: what the window server said, before any verdict is taken about it.
///
/// The extents are POINTS as [`includes_window`] wants them, not the wire's `u16`, because the
/// minimum-dimension gate runs before anything is clamped.
#[derive(Debug)]
struct Candidate {
    /// The `CGWindowID`.
    window_id: u32,
    /// The owning application's name, empty when it has none.
    app_name: String,
    /// The window's title, empty when it has none.
    title: String,
    /// Width in points.
    width_pt: i32,
    /// Height in points.
    height_pt: i32,
    /// Whether the window server is currently drawing it.
    is_on_screen: bool,
}

/// Answers one `listWindows`, then retires the lane.
///
/// The order is load-bearing and is the registry's refusal path's: the reply goes out FIRST,
/// because the retire drops the reply-flow stamp the bootstrap request left and there is then no
/// flow to answer on.
///
/// An enumeration that failed answers an EMPTY list rather than silence. The reply is the client's
/// authority for the picker and for its open-time revalidation, and those two treat "no windows"
/// and "no answer" differently — one draws an empty picker, the other waits.
///
/// ⚠️ Requires a window server and a Screen-Recording grant.
fn answer_window_list(lanes: &Arc<dyn LaneControl>, channel_id: u32) {
    let reply = VideoControlMessage::WindowList(window_summaries()).encode();
    lanes.send(&reply, VideoChannel::Control, channel_id);
    lanes.retire(channel_id);
}

/// The picker's rows, in the order they go on the wire.
///
/// The enumeration is the FULL one — off-screen windows included — for the reason
/// [`arrange_streamable_windows`] states: a minimized or other-Space window is streamable, because
/// the mint path rescues it, and an on-screen-only reply made a freshly picked one resolve to
/// nothing and close the pane the host was mid-rescue for.
///
/// Sorted by owning app then window id BEFORE the arrangement, which is the reading order
/// [`crate::list::arrange`] applies to the terminal listing, restated here over a different row
/// type. It is not cosmetic on this path: the arrangement keeps each side's relative order, so this
/// is what decides which windows survive [`MAX_WINDOW_SUMMARIES`].
///
/// ⚠️ Requires a window server and a Screen-Recording grant.
fn window_summaries() -> Vec<WindowSummary> {
    let Some(content) = ShareableContent::current(false, false) else {
        return Vec::new();
    };
    let mut candidates: Vec<Candidate> = content
        .windows()
        .into_iter()
        .map(|window| {
            let frame = window.frame();
            Candidate {
                window_id: window.id(),
                app_name: window.app_name().unwrap_or_default(),
                title: window.title().unwrap_or_default(),
                width_pt: points(frame.width()),
                height_pt: points(frame.height()),
                is_on_screen: window.is_on_screen(),
            }
        })
        .collect();
    candidates.sort_by(|left, right| {
        left.app_name
            .cmp(&right.app_name)
            .then(left.window_id.cmp(&right.window_id))
    });
    arrange_streamable_windows(
        candidates,
        |candidate| candidate.is_on_screen,
        |candidate| candidate.title.as_str(),
    )
    .into_iter()
    .filter(|candidate| {
        includes_window(
            &candidate.app_name,
            &candidate.title,
            candidate.width_pt,
            candidate.height_pt,
        )
    })
    .take(MAX_WINDOW_SUMMARIES)
    .map(|candidate| {
        WindowSummary {
            window_id: candidate.window_id,
            app_name: candidate.app_name,
            title: candidate.title,
            width: wire_extent(candidate.width_pt),
            height: wire_extent(candidate.height_pt),
        }
    })
    .collect()
}

/// Answers one `listDisplays`, then retires the lane — [`answer_window_list`]'s mirror, in the same
/// order and for the same reason.
///
/// ⚠️ Requires a window server.
fn answer_display_list(lanes: &Arc<dyn LaneControl>, channel_id: u32) {
    let reply = VideoControlMessage::DisplayList(display_summaries()).encode();
    lanes.send(&reply, VideoChannel::Control, channel_id);
    lanes.retire(channel_id);
}

/// The full-desktop pane's targets.
///
/// ONLINE rather than active, which is `docs/20`'s own word for this message and is also the
/// honest one: a display that is asleep or mirrored is still a display a client may name, and the
/// virtual display a parked window lives on is listed like any other — it is streamable like any
/// other.
///
/// The MAIN display is asked for rather than compared: `CGMainDisplayID()` has no accessor in
/// `slopdesk-apple-cgdisplay`, so the display under the CG global ORIGIN is the one named, which is
/// the main display by `CoreGraphics`' own definition of that space — the origin is its top-left
/// corner. It is the second decision this module reports, and the promotion candidate is a
/// `main()` door beside `active()` and `online()`. On a locked or sleeping screen the lookup
/// answers nothing and every row reports `is_main = false`, which the client reads as "no default
/// I can name", falls back to `requestedDisplayID 0`, and the host resolves at mint time.
///
/// ⚠️ Requires a window server.
fn display_summaries() -> Vec<DisplaySummary> {
    let main = slopdesk_apple_cgdisplay::under(VideoPoint::new(0.0, 0.0)).map(|display| display.id);
    slopdesk_apple_cgdisplay::online()
        .into_iter()
        .take(MAX_DISPLAY_SUMMARIES)
        .map(|display| {
            DisplaySummary {
                display_id: display.id,
                width: wire_extent(points(display.bounds.size.width)),
                height: wire_extent(points(display.bounds.size.height)),
                is_main: main == Some(display.id),
            }
        })
        .collect()
}

/// A point extent as the wire's `u16`, CLAMPED.
///
/// Saturating rather than wrapping, which is what `UInt16(clamping:)` said: a detached display or a
/// window the server could not measure produces extents outside the field, and a wrapped one would
/// publish a plausible-looking wrong size instead of an obviously pinned one. Negative saturates to
/// zero, where the inclusion gate has already dropped the row.
fn wire_extent(value: i32) -> u16 {
    u16::try_from(value.clamp(0, i32::from(u16::MAX))).unwrap_or(u16::MAX)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::{Arc, Mutex};

    use slopdesk_video::geometry::VideoSize;
    use slopdesk_video::recovery_routing::VideoChannel;
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{AnswerGuard, Discovery};
    use crate::mux_lane::LaneControl;

    /// The shared transport, recorded rather than dialled.
    #[derive(Debug, Default)]
    struct Wire {
        acts: Mutex<Vec<String>>,
    }

    impl Wire {
        fn acts(&self) -> Vec<String> {
            self.acts.lock().expect("uncontended").clone()
        }
    }

    impl LaneControl for Wire {
        fn admit(&self, channel_id: u32) {
            self.acts
                .lock()
                .expect("uncontended")
                .push(format!("admit {channel_id}"));
        }

        fn retire(&self, channel_id: u32) {
            self.acts
                .lock()
                .expect("uncontended")
                .push(format!("retire {channel_id}"));
        }

        fn send(&self, datagram: &[u8], _channel: VideoChannel, channel_id: u32) {
            self.acts
                .lock()
                .expect("uncontended")
                .push(format!("send {channel_id} {}", datagram.len()));
        }
    }

    /// A service over a recorder. Nothing here reaches a framework: the feed's threads wait, and no
    /// arm this test drives claims a lane.
    fn service() -> (Discovery, Arc<Wire>) {
        let wire = Arc::new(Wire::default());
        let strong = Arc::clone(&wire);
        let lanes: Arc<dyn LaneControl> = strong;
        (Discovery::new(lanes), wire)
    }

    /// The whole of the coalescing: one claim per lane, and the second is refused rather than
    /// queued. Without it a retransmit burst is a burst of window-server enumerations.
    #[test]
    fn a_lane_admits_one_answer_at_a_time() {
        let guard = AnswerGuard::default();
        assert!(guard.begin(7));
        assert!(!guard.begin(7), "a retransmit while the answer runs is dropped");
        assert!(!guard.begin(7));
    }

    /// Released on the way out, so the NEXT question on the same lane is answered afresh — the
    /// coalescing is per answer, never a permanent lockout.
    #[test]
    fn a_finished_answer_releases_its_lane() {
        let guard = AnswerGuard::default();
        assert!(guard.begin(7));
        guard.end(7);
        assert!(guard.begin(7));
    }

    /// Ending a lane that was never claimed is quiet, which is what makes the spawn-refusal path
    /// and the normal one able to share one release.
    #[test]
    fn releasing_an_unclaimed_lane_is_quiet() {
        let guard = AnswerGuard::default();
        guard.end(9);
        assert!(guard.begin(9));
    }

    /// Two clients asking at once must not coalesce into each other: the mark is per LANE, and a
    /// shared one would answer one of them and silently drop the other.
    #[test]
    fn two_lanes_are_answered_at_the_same_time() {
        let guard = AnswerGuard::default();
        assert!(guard.begin(7));
        assert!(guard.begin(8));
        guard.end(7);
        assert!(!guard.begin(8), "ending one lane must not release the other");
    }

    /// A hello is the registry's, not this file's. Claiming it would mean a pane that never mints.
    #[test]
    fn a_hello_is_declined_so_the_registry_can_mint_it() {
        let (discovery, wire) = service();
        let hello = VideoControlMessage::Hello {
            protocol_version: 1,
            requested_window_id: 42,
            viewport: VideoSize {
                width: 1280.0,
                height: 800.0,
            },
        }
        .encode();
        assert!(!discovery.dispatch(7, VideoChannel::Control, &hello));
        assert!(wire.acts().is_empty());
    }

    /// Everything a live session sends rides a lane this file has no opinion about.
    #[test]
    fn a_session_message_is_declined() {
        let (discovery, _wire) = service();
        for message in [
            VideoControlMessage::Keepalive,
            VideoControlMessage::Bye,
            VideoControlMessage::FocusWindow,
        ] {
            assert!(
                !discovery.dispatch(7, VideoChannel::Control, &message.encode()),
                "{message:?} is a session's, not discovery's",
            );
        }
    }

    /// Undecodable bytes are declined rather than swallowed: this file may not decide what a
    /// malformed datagram means, and the registry's own drop already does.
    #[test]
    fn an_undecodable_datagram_is_declined() {
        let (discovery, _wire) = service();
        assert!(!discovery.dispatch(7, VideoChannel::Control, &[]));
        assert!(!discovery.dispatch(7, VideoChannel::Control, &[0xFF, 0xFF, 0xFF]));
    }

    /// The grammar is the CONTROL channel's. A list request arriving on video or cursor is not a
    /// question about the host — it is a datagram on the wrong channel, and the wire's rule is that
    /// nothing on another channel ever bootstraps anything.
    #[test]
    fn a_list_request_on_another_channel_is_declined() {
        let (discovery, _wire) = service();
        let list = VideoControlMessage::ListWindows.encode();
        for channel in [VideoChannel::Video, VideoChannel::Cursor] {
            assert!(!discovery.dispatch(7, channel, &list));
        }
    }

    /// The dormant one is CONSUMED and answered with nothing: no reply, no retire, and no lane
    /// claimed, so a client still sending it costs a decode and a return.
    #[test]
    fn the_dormant_system_dialog_request_is_swallowed_whole() {
        let (discovery, wire) = service();
        let dormant = VideoControlMessage::ListSystemDialogs.encode();
        assert!(discovery.dispatch(7, VideoChannel::Control, &dormant));
        assert!(wire.acts().is_empty(), "a swallowed request answers nothing");
    }

    /// The two the daemon cannot answer yet fall through rather than being swallowed. If an icon or
    /// preview door ever lands, this test is what says the arm is still missing.
    #[test]
    fn the_unported_blob_requests_fall_through_to_the_registry() {
        let (discovery, wire) = service();
        let icon = VideoControlMessage::AppIconRequest {
            size_px: 64,
            bundle_id: "com.example".to_owned(),
        }
        .encode();
        let preview = VideoControlMessage::WindowPreviewRequest {
            window_id: 42,
            max_width_px: 640,
        }
        .encode();
        assert!(!discovery.dispatch(7, VideoChannel::Control, &icon));
        assert!(!discovery.dispatch(7, VideoChannel::Control, &preview));
        assert!(wire.acts().is_empty());
    }

    /// A kick with nobody subscribed reaches the feed and stops there. It is the daemon's tick, so
    /// it runs on an idle host forever and must cost a lock rather than an enumeration.
    #[test]
    fn a_kick_on_an_idle_host_does_nothing() {
        let (discovery, wire) = service();
        discovery.kick();
        assert!(wire.acts().is_empty());
    }

    /// The wire's `u16` saturates rather than wrapping.
    #[test]
    fn an_extent_outside_the_field_saturates() {
        assert_eq!(super::wire_extent(1440), 1440);
        assert_eq!(super::wire_extent(-5), 0);
        assert_eq!(super::wire_extent(1_000_000), u16::MAX);
    }
}
