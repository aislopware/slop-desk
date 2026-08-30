//! The host video session's lifecycle, and the two negotiations that ride on it.
//!
//! The state machine validates the client hello, decides the acknowledgement, and gates whether
//! media may flow — with NO live component anywhere near it. The actor advances it and performs the
//! returned effects, so every transition is decided here and only actuated there.
//!
//! Two pure policies sit beside it because they are the same kind of decision: what capture size an
//! in-session resize settles on, and how the client's live stream overrides clamp on apply.

use crate::geometry::{VideoRect, VideoSize};
use crate::video_control::VideoControlMessage;

/// The wire protocol version for the video path, bumped on any breaking change.
pub const PROTOCOL_VERSION: u16 = 1;

/// A host video session's lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VideoSessionState {
    /// Sockets not yet bound; nothing flowing.
    #[default]
    Idle,
    /// Sockets bound, awaiting the client hello.
    Listening,
    /// The hello was accepted; capture and encode are running and media is flowing.
    Streaming,
    /// A local stop ran. Terminal.
    Stopped,
}

/// A side effect the actor must perform after a transition.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionEffect {
    /// Send this control message back to the client.
    SendControl(VideoControlMessage),
    /// Bring up capture and encode for a target at the negotiated dimensions.
    StartCapture {
        /// The window or display being remoted.
        window_id: u32,
        /// The negotiated capture width.
        width: u16,
        /// The negotiated capture height.
        height: u16,
    },
    /// Tear down capture and encode.
    StopCapture,
    /// Re-size the LIVE capture and encode of the streaming window.
    ///
    /// The actor performs the resize and replies with the acknowledgement. It does NOT mint a new
    /// stream id — it is the same session, and only the capture geometry changes.
    ResizeCapture {
        /// The clamped width.
        width: u16,
        /// The clamped height.
        height: u16,
        /// The epoch this answers.
        epoch: u32,
    },
    /// Apply the client's live stream overrides to the running session.
    ///
    /// The values ride RAW; the actor clamps on apply through [`fps_cap_from_wire`] and
    /// [`bitrate_ceiling_from_wire`] and actuates through the same paths a governed frame-rate step
    /// or a bitrate report takes.
    ApplyStreamSettings {
        /// The requested cap, or zero for auto.
        fps_cap: u8,
        /// The requested ceiling, or zero for auto.
        bitrate_ceiling_bps: u32,
    },
    /// Apply the client's audio wish — the stream-settings twin for the audio lane. Per-session
    /// HOST state, reset off when capture starts, so the client re-sends after every accepted
    /// hello.
    ApplyAudioControl {
        /// Whether audio should flow.
        enabled: bool,
    },
    /// Apply the client's privacy-blank wish. Emitted ONLY for a display target, because a window
    /// session has no whole display to blank.
    ApplyPrivacyMode {
        /// Whether the blank is on.
        enabled: bool,
    },
}

/// The pure state machine driving a host video session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoSessionStateMachine {
    /// The lifecycle state.
    state: VideoSessionState,
    /// The negotiated capture width, set once a hello is accepted.
    capture_width: u16,
    /// The negotiated capture height.
    capture_height: u16,
    /// The window — or, for a full-desktop session, the display — being remoted.
    window_id: u32,
    /// Whether the accepted session targets a whole DISPLAY rather than a window.
    ///
    /// A duplicate hello re-acknowledges on a match of BOTH id and kind, so a window hello can
    /// never re-acknowledge a display session; and an in-session resize is refused for a
    /// display target, because the display never resizes — the client letterboxes.
    is_display_target: bool,
    /// The next stream id to mint. Monotonic, so a reconnecting client can tell a fresh session
    /// from the one it lost.
    next_stream_id: u32,
    /// The id handed out on the most recent accept, echoed by a duplicate re-acknowledgement.
    last_stream_id: u32,
    /// Whether this host encodes FULL-RANGE luma.
    ///
    /// Stamped into every accepted acknowledgement, and into the duplicate re-acknowledgement,
    /// which MUST echo the same value, so the client derives its decoder pixel format and
    /// shader coefficients from the stream. A reject always says video range.
    full_range: bool,
    /// The highest resize epoch already APPLIED for the current session, so a stale or duplicate
    /// request — the datagrams may reorder or duplicate — is dropped. Zero means none applied yet,
    /// and the first request always wins.
    last_resize_epoch: u32,
}

impl VideoSessionStateMachine {
    /// A fresh idle machine.
    #[must_use]
    pub const fn new(next_stream_id: u32, full_range: bool) -> Self {
        Self {
            state: VideoSessionState::Idle,
            capture_width: 0,
            capture_height: 0,
            window_id: 0,
            is_display_target: false,
            next_stream_id,
            last_stream_id: 0,
            full_range,
            last_resize_epoch: 0,
        }
    }

    /// The lifecycle state.
    #[must_use]
    pub const fn state(&self) -> VideoSessionState {
        self.state
    }

    /// The negotiated capture size.
    #[must_use]
    pub const fn capture_size(&self) -> (u16, u16) {
        (self.capture_width, self.capture_height)
    }

    /// The window or display being remoted.
    #[must_use]
    pub const fn window_id(&self) -> u32 {
        self.window_id
    }

    /// Whether the session targets a whole display.
    #[must_use]
    pub const fn is_display_target(&self) -> bool {
        self.is_display_target
    }

    /// The highest resize epoch applied so far.
    #[must_use]
    pub const fn last_resize_epoch(&self) -> u32 {
        self.last_resize_epoch
    }

    /// The id the next accept will mint.
    #[must_use]
    pub const fn next_stream_id(&self) -> u32 {
        self.next_stream_id
    }

    /// The id the most recent accept minted, which a duplicate re-acknowledgement echoes.
    #[must_use]
    pub const fn last_stream_id(&self) -> u32 {
        self.last_stream_id
    }

    /// Whether this host encodes full-range luma.
    #[must_use]
    pub const fn full_range(&self) -> bool {
        self.full_range
    }

    /// Puts a machine back where a caller that cannot hold this type left it.
    ///
    /// Every field a transition reads or writes is here, so a machine restored from what
    /// [`Self::state`] and its siblings answered decides exactly what the original would have. It
    /// is the boundary's constructor, not a way to invent a state no transition could reach.
    pub const fn restore(
        &mut self,
        state: VideoSessionState,
        capture_size: (u16, u16),
        window_id: u32,
        is_display_target: bool,
        last_stream_id: u32,
        last_resize_epoch: u32,
    ) {
        self.state = state;
        (self.capture_width, self.capture_height) = capture_size;
        self.window_id = window_id;
        self.is_display_target = is_display_target;
        self.last_stream_id = last_stream_id;
        self.last_resize_epoch = last_resize_epoch;
    }

    /// Whether media — video, geometry, cursor — is allowed to flow right now.
    #[must_use]
    pub const fn media_flowing(&self) -> bool {
        matches!(self.state, VideoSessionState::Streaming)
    }

    /// Start was called: bind sockets and wait for the client hello.
    pub const fn start(&mut self) -> Vec<SessionEffect> {
        if matches!(self.state, VideoSessionState::Idle) {
            self.state = VideoSessionState::Listening;
        }
        Vec::new()
    }

    /// Stop was called LOCALLY, which is terminal.
    ///
    /// Unlike a client goodbye this also closes the sockets, so the session is NOT re-armable: a
    /// later hello finds a stopped machine.
    pub fn stop(&mut self) -> Vec<SessionEffect> {
        if matches!(self.state, VideoSessionState::Stopped) {
            return Vec::new();
        }
        let was_streaming = self.media_flowing();
        self.state = VideoSessionState::Stopped;
        if was_streaming {
            vec![SessionEffect::StopCapture]
        } else {
            Vec::new()
        }
    }

    /// A control datagram arrived.
    ///
    /// `window_bounds_cg` is the live window bounds to report in the acknowledgement — the machine
    /// just forwards what the actor read from the geometry watcher.
    ///
    /// `resolve_capture_size` maps a client viewport to the capture size the host will use, and
    /// `None` REJECTS the session. `resolve_resize_size` maps an in-session request's desired size
    /// for the streaming window to the clamped size to adopt, and `None` rejects the resize so
    /// capture stays put. `resolve_display_capture_size` is the full-desktop sibling — a window
    /// session passes one that always refuses, so it can never accept a display hello.
    pub fn handle_control<Capture, Resize, Display>(
        &mut self,
        message: &VideoControlMessage,
        window_bounds_cg: VideoRect,
        resolve_capture_size: Capture,
        resolve_resize_size: Resize,
        resolve_display_capture_size: Display,
    ) -> Vec<SessionEffect>
    where
        Capture: FnOnce(u32, VideoSize) -> Option<(u16, u16)>,
        Resize: FnOnce(u32, VideoSize) -> Option<(u16, u16)>,
        Display: FnOnce(u32, VideoSize) -> Option<(u16, u16)>,
    {
        match *message {
            VideoControlMessage::Hello {
                protocol_version,
                requested_window_id,
                viewport,
            } => {
                self.accept_hello(
                    protocol_version,
                    requested_window_id,
                    false,
                    viewport,
                    window_bounds_cg,
                    resolve_capture_size,
                )
            },
            VideoControlMessage::HelloDisplay {
                protocol_version,
                requested_display_id,
                viewport,
            } => {
                self.accept_hello(
                    protocol_version,
                    requested_display_id,
                    true,
                    viewport,
                    window_bounds_cg,
                    resolve_display_capture_size,
                )
            },
            VideoControlMessage::Bye => self.handle_bye(),
            VideoControlMessage::ResizeRequest { desired, epoch } => {
                self.handle_resize(desired, epoch, resolve_resize_size)
            },
            VideoControlMessage::StreamSettings {
                fps_cap,
                bitrate_ceiling_bps,
            } if self.media_flowing() => {
                // Live controls apply only to a STREAMING session: there is no capture or encoder
                // to actuate otherwise, and the client re-sends after every
                // accepted hello, so a pre-stream message is never load-bearing.
                vec![SessionEffect::ApplyStreamSettings {
                    fps_cap,
                    bitrate_ceiling_bps,
                }]
            },
            VideoControlMessage::AudioControl { enabled } if self.media_flowing() => {
                vec![SessionEffect::ApplyAudioControl { enabled }]
            },
            VideoControlMessage::PrivacyMode { enabled }
                if self.media_flowing() && self.is_display_target =>
            {
                // Scoped to a DISPLAY target: a window session drops it, because there is no
                // display to black without hiding an unrelated app.
                vec![SessionEffect::ApplyPrivacyMode { enabled }]
            },
            // Everything else is a no-op here. A keepalive carries no state-machine semantics — its
            // only effect is the transport's inbound stamp that the idle reaper reads — and a focus
            // request is actioned at the actor level with no capture-state effect. Window, display
            // and icon discovery are answered at the DAEMON level, session-less, and never reach a
            // session at all. The remaining variants are host-to-client and never arrive here.
            _ => Vec::new(),
        }
    }

    /// A client goodbye RE-ARMS the session so a fresh hello can reconnect without a daemon
    /// restart.
    ///
    /// The next hello mints a fresh stream id and re-resolves the capture size, so a re-accepted
    /// session is fully re-initialised.
    fn handle_bye(&mut self) -> Vec<SessionEffect> {
        let was_streaming = self.media_flowing();
        if !was_streaming && !matches!(self.state, VideoSessionState::Listening) {
            return Vec::new();
        }
        self.state = VideoSessionState::Listening;
        if was_streaming {
            vec![SessionEffect::StopCapture]
        } else {
            Vec::new()
        }
    }

    /// An in-session resize, accepted ONLY while streaming.
    ///
    /// A stale or duplicate epoch is dropped, so a datagram reorder or retransmit cannot
    /// shrink-then-grow out of order and a burst coalesces to the highest, settled request. A
    /// rejected resolve leaves the epoch UNADVANCED, so a later valid request still wins.
    fn handle_resize<Resize>(
        &mut self,
        desired: VideoSize,
        epoch: u32,
        resolve_resize_size: Resize,
    ) -> Vec<SessionEffect>
    where
        Resize: FnOnce(u32, VideoSize) -> Option<(u16, u16)>,
    {
        if !self.media_flowing() || self.is_display_target {
            return Vec::new();
        }
        if is_stale_epoch(epoch, self.last_resize_epoch) {
            return Vec::new();
        }
        let Some((width, height)) = resolve_resize_size(self.window_id, desired) else {
            return Vec::new();
        };
        self.last_resize_epoch = epoch;
        self.capture_width = width;
        self.capture_height = height;
        vec![SessionEffect::ResizeCapture { width, height, epoch }]
    }

    /// The shared accept path for BOTH target kinds: a strict version check, a duplicate
    /// re-acknowledgement while streaming matched on id AND kind, resolve-or-reject, then accept
    /// with a fresh stream id.
    fn accept_hello<Resolve>(
        &mut self,
        version: u16,
        target_id: u32,
        display_target: bool,
        viewport: VideoSize,
        window_bounds_cg: VideoRect,
        resolve: Resolve,
    ) -> Vec<SessionEffect>
    where
        Resolve: FnOnce(u32, VideoSize) -> Option<(u16, u16)>,
    {
        if version != PROTOCOL_VERSION {
            return vec![reject_ack(window_bounds_cg)]; // strict, with no fallback
        }
        if !matches!(self.state, VideoSessionState::Listening) {
            // Ignore a duplicate once streaming — the hello is unreliable, so the client may
            // retransmit — but re-acknowledge it so a LOST acknowledgement is recovered without
            // restarting capture.
            if self.media_flowing() && target_id == self.window_id && display_target == self.is_display_target
            {
                return vec![SessionEffect::SendControl(VideoControlMessage::HelloAck {
                    accepted: true,
                    stream_id: self.last_stream_id,
                    capture_width: self.capture_width,
                    capture_height: self.capture_height,
                    window_bounds_cg,
                    full_range: self.full_range,
                })];
            }
            return Vec::new();
        }
        let Some((width, height)) = resolve(target_id, viewport) else {
            return vec![reject_ack(window_bounds_cg)];
        };
        let stream_id = self.next_stream_id;
        self.next_stream_id = self.next_stream_id.wrapping_add(1);
        self.last_stream_id = stream_id;
        self.capture_width = width;
        self.capture_height = height;
        self.window_id = target_id;
        self.is_display_target = display_target;
        // Re-arm the resize epoch for the FRESH session. A reconnecting client mints epochs from
        // one again, because its debounce is per-connection, so a stale epoch carried over
        // from the prior session would make every new one look stale and drop its first
        // resizes.
        self.last_resize_epoch = 0;
        self.state = VideoSessionState::Streaming;
        vec![
            SessionEffect::SendControl(VideoControlMessage::HelloAck {
                accepted: true,
                stream_id,
                capture_width: width,
                capture_height: height,
                window_bounds_cg,
                full_range: self.full_range,
            }),
            SessionEffect::StartCapture {
                window_id: target_id,
                width,
                height,
            },
        ]
    }
}

/// The rejection acknowledgement. A reject always reports video range.
const fn reject_ack(window_bounds_cg: VideoRect) -> SessionEffect {
    SessionEffect::SendControl(VideoControlMessage::HelloAck {
        accepted: false,
        stream_id: 0,
        capture_width: 0,
        capture_height: 0,
        window_bounds_cg,
        full_range: false,
    })
}

/// Whether an epoch is STALE against the last applied one.
///
/// A value at or below it — a duplicate, or an out-of-order older request — must be ignored, so a
/// datagram reorder or retransmit cannot un-settle the coalesced size. The first request of a
/// session is therefore never stale.
#[must_use]
pub const fn is_stale_epoch(epoch: u32, last_applied: u32) -> bool {
    epoch <= last_applied
}

/// Clamps a desired size into the host's policy bounds per axis, rounding to a non-zero integer.
///
/// This is the identity, within rounding, when the desired size is already inside the bounds. A
/// zero capture dimension is an invalid encoder configuration, so the lower bound is floored at one
/// and the upper ceilinged at the wire maximum — a degenerate or swapped policy still clamps into a
/// valid window rather than yielding zero or overflowing.
#[must_use]
pub fn clamp_capture_size(desired: VideoSize, min: VideoSize, max: VideoSize) -> (u16, u16) {
    (
        clamp_axis(desired.width, min.width, max.width),
        clamp_axis(desired.height, min.height, max.height),
    )
}

/// One axis of [`clamp_capture_size`].
fn clamp_axis(value: f64, low: f64, high: f64) -> u16 {
    let bound = |edge: f64| f64::from(u16::MAX).min(edge.round()).max(1.0);
    let low = bound(low);
    let high = bound(high);
    // Order them, so a swapped policy still describes a real interval.
    let lower = low.min(high);
    let upper = low.max(high);
    // A non-finite desired size collapses to the lower bound: never zero, and never a trap.
    let rounded = if value.is_finite() { value.round() } else { lower };
    let clamped = rounded.max(lower).min(upper);
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the value is clamped into 1..=u16::MAX before it is cast"
    )]
    let axis = clamped as u16;
    axis
}

/// The band a user frame-rate cap is accepted in.
///
/// Below the floor the stream is a slideshow, and a hostile request of one frame a second would
/// starve recovery; above the ceiling exceeds every panel the client drives.
pub const FPS_CAP_RANGE: (i64, i64) = (5, 120);

/// The band a user bitrate ceiling is accepted in.
///
/// Below the floor the encoder starves even at its coarsest quantiser; above the ceiling is past
/// any realistic provision.
pub const BITRATE_CEILING_RANGE: (i64, i64) = (500_000, 200_000_000);

/// Maps the wire frame-rate cap to the applied override: zero is AUTO, and anything else clamps.
///
/// The clamp lives here rather than in the decoder because the host's contract is
/// validate-then-drop at the LENGTH level only — a semantically odd value is corrected, not
/// dropped.
#[must_use]
pub fn fps_cap_from_wire(raw: u8) -> Option<i64> {
    if raw == 0 {
        return None;
    }
    Some(i64::from(raw).clamp(FPS_CAP_RANGE.0, FPS_CAP_RANGE.1))
}

/// Maps the wire bitrate ceiling to the applied override: zero is AUTO, and anything else clamps.
#[must_use]
pub fn bitrate_ceiling_from_wire(raw: u32) -> Option<i64> {
    if raw == 0 {
        return None;
    }
    Some(i64::from(raw).clamp(BITRATE_CEILING_RANGE.0, BITRATE_CEILING_RANGE.1))
}

/// The encode cadence actually in force: the governed rate, capped by the user's override.
///
/// With no override this is EXACTLY the governed rate, so every actuation is byte-identical to one
/// with the feature absent.
#[must_use]
pub fn effective_fps(governed: i64, user_cap: Option<i64>) -> i64 {
    user_cap.map_or(governed, |cap| governed.min(cap))
}

#[cfg(test)]
mod tests {
    use super::{
        BITRATE_CEILING_RANGE, FPS_CAP_RANGE, PROTOCOL_VERSION, SessionEffect, VideoSessionState,
        VideoSessionStateMachine, bitrate_ceiling_from_wire, clamp_capture_size, effective_fps,
        fps_cap_from_wire, is_stale_epoch,
    };
    use crate::geometry::{VideoPoint, VideoRect, VideoSize};
    use crate::video_control::VideoControlMessage;

    const BOUNDS: VideoRect = VideoRect::new(VideoPoint { x: 0.0, y: 0.0 }, VideoSize {
        width: 1280.0,
        height: 800.0,
    });

    fn viewport() -> VideoSize {
        VideoSize {
            width: 1280.0,
            height: 800.0,
        }
    }

    fn hello(window_id: u32) -> VideoControlMessage {
        VideoControlMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            requested_window_id: window_id,
            viewport: viewport(),
        }
    }

    /// Feeds one message with a resolver that always accepts a fixed size.
    fn feed(machine: &mut VideoSessionStateMachine, message: &VideoControlMessage) -> Vec<SessionEffect> {
        machine.handle_control(
            message,
            BOUNDS,
            |_, _| Some((640, 400)),
            |_, _| Some((800, 600)),
            |_, _| Some((1920, 1080)),
        )
    }

    /// A machine already streaming a window.
    fn streaming() -> VideoSessionStateMachine {
        let mut machine = VideoSessionStateMachine::new(1, false);
        machine.start();
        feed(&mut machine, &hello(42));
        machine
    }

    #[test]
    fn a_valid_hello_accepts_mints_a_stream_and_starts_capture() {
        let machine = streaming();
        assert_eq!(machine.state(), VideoSessionState::Streaming);
        assert_eq!(machine.capture_size(), (640, 400));
        assert_eq!(machine.window_id(), 42);
        assert!(machine.media_flowing());
    }

    #[test]
    fn a_version_mismatch_is_rejected_outright() {
        let mut machine = VideoSessionStateMachine::new(1, false);
        machine.start();
        let effects = feed(&mut machine, &VideoControlMessage::Hello {
            protocol_version: PROTOCOL_VERSION + 1,
            requested_window_id: 42,
            viewport: viewport(),
        });
        assert!(matches!(effects.as_slice(), [SessionEffect::SendControl(
            VideoControlMessage::HelloAck { accepted: false, .. }
        )],));
        assert_eq!(
            machine.state(),
            VideoSessionState::Listening,
            "no session was minted"
        );
    }

    #[test]
    fn an_unresolvable_target_is_rejected_and_leaves_the_machine_listening() {
        let mut machine = VideoSessionStateMachine::new(1, false);
        machine.start();
        let effects = machine.handle_control(&hello(42), BOUNDS, |_, _| None, |_, _| None, |_, _| None);
        assert!(matches!(effects.as_slice(), [SessionEffect::SendControl(
            VideoControlMessage::HelloAck { accepted: false, .. }
        )],));
        assert_eq!(machine.state(), VideoSessionState::Listening);
    }

    /// A lost acknowledgement must be recoverable without restarting capture.
    #[test]
    fn a_duplicate_hello_re_acknowledges_the_same_stream_without_restarting_capture() {
        let mut machine = streaming();
        let effects = feed(&mut machine, &hello(42));
        assert_eq!(effects.len(), 1, "no second startCapture");
        assert!(
            matches!(
                effects.first(),
                Some(SessionEffect::SendControl(VideoControlMessage::HelloAck {
                    accepted: true,
                    stream_id: 1, // the SAME stream id, not a fresh mint
                    ..
                })),
            ),
            "expected a re-acknowledgement, got {effects:?}",
        );
    }

    /// The rule that keeps a window hello from hijacking a display session.
    #[test]
    fn a_hello_for_a_different_target_or_kind_is_ignored_while_streaming() {
        let mut machine = streaming();
        assert!(feed(&mut machine, &hello(99)).is_empty());
        assert!(
            feed(&mut machine, &VideoControlMessage::HelloDisplay {
                protocol_version: PROTOCOL_VERSION,
                requested_display_id: 42,
                viewport: viewport(),
            },)
            .is_empty(),
            "the same id but the wrong KIND is not a duplicate",
        );
    }

    #[test]
    fn a_client_bye_re_arms_the_session_but_a_local_stop_is_terminal() {
        let mut machine = streaming();
        assert_eq!(feed(&mut machine, &VideoControlMessage::Bye), [
            SessionEffect::StopCapture
        ]);
        assert_eq!(machine.state(), VideoSessionState::Listening);
        // …and a fresh hello reconnects with NO daemon restart, minting a new stream id.
        feed(&mut machine, &hello(7));
        assert_eq!(machine.state(), VideoSessionState::Streaming);
        assert_eq!(machine.window_id(), 7);
        assert_eq!(machine.stop(), [SessionEffect::StopCapture]);
        assert_eq!(machine.state(), VideoSessionState::Stopped);
        assert!(
            feed(&mut machine, &hello(7)).is_empty(),
            "stopped is not re-armable"
        );
    }

    #[test]
    fn a_resize_applies_once_and_a_stale_epoch_never_un_settles_it() {
        let mut machine = streaming();
        let desired = VideoSize {
            width: 900.0,
            height: 700.0,
        };
        let effects = feed(&mut machine, &VideoControlMessage::ResizeRequest {
            desired,
            epoch: 3,
        });
        assert_eq!(effects, [SessionEffect::ResizeCapture {
            width: 800,
            height: 600,
            epoch: 3,
        }],);
        assert_eq!(machine.capture_size(), (800, 600));
        assert!(
            feed(&mut machine, &VideoControlMessage::ResizeRequest {
                desired,
                epoch: 3
            })
            .is_empty(),
            "a duplicate epoch is dropped",
        );
        assert!(
            feed(&mut machine, &VideoControlMessage::ResizeRequest {
                desired,
                epoch: 2
            })
            .is_empty(),
            "and so is a reordered older one",
        );
    }

    /// A rejected resize must not burn the epoch, or a later valid request would look stale.
    #[test]
    fn a_rejected_resize_leaves_the_epoch_unadvanced() {
        let mut machine = streaming();
        let request = VideoControlMessage::ResizeRequest {
            desired: viewport(),
            epoch: 5,
        };
        assert!(
            machine
                .handle_control(&request, BOUNDS, |_, _| None, |_, _| None, |_, _| None)
                .is_empty(),
        );
        assert_eq!(machine.last_resize_epoch(), 0);
        assert!(!feed(&mut machine, &request).is_empty(), "the retry still wins");
    }

    #[test]
    fn a_fresh_session_re_arms_the_resize_epoch() {
        let mut machine = streaming();
        feed(&mut machine, &VideoControlMessage::ResizeRequest {
            desired: viewport(),
            epoch: 7,
        });
        assert_eq!(machine.last_resize_epoch(), 7);
        feed(&mut machine, &VideoControlMessage::Bye);
        feed(&mut machine, &hello(42));
        assert_eq!(
            machine.last_resize_epoch(),
            0,
            "or every new epoch would look stale"
        );
    }

    #[test]
    fn a_display_session_never_resizes_and_only_it_takes_a_privacy_blank() {
        let mut machine = VideoSessionStateMachine::new(1, false);
        machine.start();
        feed(&mut machine, &VideoControlMessage::HelloDisplay {
            protocol_version: PROTOCOL_VERSION,
            requested_display_id: 1,
            viewport: viewport(),
        });
        assert!(machine.is_display_target());
        assert_eq!(machine.capture_size(), (1920, 1080));
        assert!(
            feed(&mut machine, &VideoControlMessage::ResizeRequest {
                desired: viewport(),
                epoch: 1,
            },)
            .is_empty(),
            "the display never resizes; the client letterboxes",
        );
        assert_eq!(
            feed(&mut machine, &VideoControlMessage::PrivacyMode { enabled: true }),
            [SessionEffect::ApplyPrivacyMode { enabled: true }],
        );
        let mut window_session = streaming();
        assert!(
            feed(&mut window_session, &VideoControlMessage::PrivacyMode {
                enabled: true
            },)
            .is_empty(),
            "a window session has no display to black",
        );
    }

    #[test]
    fn the_live_knobs_only_reach_a_streaming_session() {
        let mut listening = VideoSessionStateMachine::new(1, false);
        listening.start();
        let settings = VideoControlMessage::StreamSettings {
            fps_cap: 30,
            bitrate_ceiling_bps: 8_000_000,
        };
        assert!(feed(&mut listening, &settings).is_empty());
        assert!(
            feed(&mut listening, &VideoControlMessage::AudioControl {
                enabled: true
            })
            .is_empty()
        );
        let mut machine = streaming();
        assert_eq!(feed(&mut machine, &settings), [
            SessionEffect::ApplyStreamSettings {
                fps_cap: 30,
                bitrate_ceiling_bps: 8_000_000,
            }
        ],);
        assert_eq!(
            feed(&mut machine, &VideoControlMessage::AudioControl {
                enabled: false
            }),
            [SessionEffect::ApplyAudioControl { enabled: false }],
        );
    }

    #[test]
    fn a_keepalive_and_the_host_to_client_messages_are_no_ops() {
        let mut machine = streaming();
        for message in [
            VideoControlMessage::Keepalive,
            VideoControlMessage::FocusWindow,
            VideoControlMessage::ListWindows,
            VideoControlMessage::StreamCadence { fps: 30 },
        ] {
            assert!(feed(&mut machine, &message).is_empty(), "{message:?}");
        }
        assert_eq!(machine.state(), VideoSessionState::Streaming);
    }

    #[test]
    fn the_epoch_order_admits_the_first_request_of_a_session() {
        assert!(!is_stale_epoch(1, 0));
        assert!(is_stale_epoch(3, 3));
        assert!(is_stale_epoch(2, 3));
    }

    #[test]
    fn the_size_clamp_is_the_identity_inside_the_bounds() {
        let size = |width: f64, height: f64| VideoSize { width, height };
        assert_eq!(
            clamp_capture_size(size(900.0, 700.0), size(320.0, 240.0), size(1920.0, 1080.0)),
            (900, 700),
        );
    }

    #[test]
    fn the_size_clamp_never_yields_zero_and_survives_a_degenerate_policy() {
        let size = |width: f64, height: f64| VideoSize { width, height };
        assert_eq!(
            clamp_capture_size(size(0.0, -50.0), size(0.0, 0.0), size(0.0, 0.0)),
            (1, 1),
            "a zero-dimension capture configuration is invalid",
        );
        assert_eq!(
            clamp_capture_size(size(100.0, 100.0), size(1920.0, 1080.0), size(320.0, 240.0)),
            (320, 240),
            "a swapped policy still describes a real interval, ordered low to high",
        );
        assert_eq!(
            clamp_capture_size(size(5000.0, 5000.0), size(1920.0, 1080.0), size(320.0, 240.0)),
            (1920, 1080),
        );
        assert_eq!(
            clamp_capture_size(
                size(f64::NAN, f64::INFINITY),
                size(320.0, 240.0),
                size(1920.0, 1080.0),
            ),
            (320, 240),
            "a non-finite desire collapses to the lower bound rather than trapping",
        );
        assert_eq!(
            clamp_capture_size(size(1e9, 1e9), size(320.0, 240.0), size(1e9, 1e9),),
            (u16::MAX, u16::MAX),
            "and the upper bound cannot overflow the wire field",
        );
    }

    #[test]
    fn the_user_overrides_clamp_rather_than_dropping_and_zero_means_auto() {
        assert_eq!(fps_cap_from_wire(0), None);
        assert_eq!(fps_cap_from_wire(30), Some(30));
        assert_eq!(fps_cap_from_wire(1), Some(FPS_CAP_RANGE.0));
        assert_eq!(fps_cap_from_wire(240), Some(FPS_CAP_RANGE.1));
        assert_eq!(bitrate_ceiling_from_wire(0), None);
        assert_eq!(bitrate_ceiling_from_wire(8_000_000), Some(8_000_000));
        assert_eq!(bitrate_ceiling_from_wire(1), Some(BITRATE_CEILING_RANGE.0));
        assert_eq!(bitrate_ceiling_from_wire(u32::MAX), Some(BITRATE_CEILING_RANGE.1));
    }

    #[test]
    fn without_an_override_the_cadence_is_exactly_the_governed_rate() {
        assert_eq!(effective_fps(60, None), 60);
        assert_eq!(effective_fps(60, Some(30)), 30);
        assert_eq!(effective_fps(20, Some(30)), 20, "the cap never raises the rate");
    }
}
