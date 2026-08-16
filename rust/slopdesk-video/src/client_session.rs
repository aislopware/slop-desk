//! The client session's lifecycle: what it says to the host, what it does with the answers.
//!
//! It is the mirror of the host's session machine and holds no live component at all — the runtime
//! advances it and performs the effects it returns, so every decision is decided here and only
//! actuated there.
//!
//! Three things sit beside it because they are the same kind of decision. The hello RETRY cadence,
//! because over plain UDP a one-shot hello or its acknowledgement can be lost and a session would
//! otherwise wedge waiting forever. The reconnecting SCRIM latch, which is sticky for a reason the
//! type spells out. And the received-datagram ROUTER, which is pure triage — no reassembler, no
//! decoder, nothing that needs a socket to test.

use crate::audio_wire::AudioChannelMessage;
use crate::fragment::FrameFragment;
use crate::geometry::{VideoRect, VideoSize};
use crate::keepalive::StallVerdict;
use crate::recovery_routing::VideoChannel;
use crate::session_state::PROTOCOL_VERSION;
use crate::video_control::{MaskRect, VideoControlMessage};
use crate::window_geometry::WindowGeometryMessage;

/// A client session's lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VideoClientState {
    /// Not yet started.
    #[default]
    Idle,
    /// The hello went out; the acknowledgement has not come back.
    Connecting,
    /// Accepted: video and cursor are flowing.
    Streaming,
    /// The host refused the hello — a version mismatch, or the window is gone.
    Rejected,
    /// A local stop, or a received farewell. Terminal.
    Stopped,
}

/// What the client asked the host to stream.
///
/// Everything downstream of the hello — the acknowledgement, the decode, the input mapping — is
/// target-agnostic, so the distinction lives here and nowhere else.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoStreamTarget {
    /// One window, by its host window id.
    Window(u32),
    /// A whole display; zero means the host's main one.
    Display(u32),
}

/// A side effect the runtime performs after a transition.
#[derive(Debug, Clone, PartialEq)]
pub enum ClientEffect {
    /// Send this control message to the host.
    SendControl(VideoControlMessage),
    /// Re-send the cursor side-channel prime, so the host re-learns this lane's cursor reply flow.
    ///
    /// The cursor socket is host-to-client only after the prime — there is NO ongoing
    /// client-to-host traffic on it — so unlike the media flow, which every routed inbound
    /// datagram re-stamps, a lost stamp NEVER self-heals. A host daemon restart between the
    /// one-shot lane prime and the hello leaves video and input working while every cursor
    /// update is silently dropped and the pointer freezes on the default arrow. Emitting the
    /// prime with EVERY hello closes that hole.
    PrimeCursorFlow,
    /// The session is up at the negotiated capture size: bring up the decoder, pacer and renderer.
    StartDecodePipeline {
        /// The negotiated capture size.
        capture_size: VideoSize,
        /// The target's top-left bounds, which is the initial input-mapping origin.
        window_bounds_cg: VideoRect,
        /// The stream's negotiated luma range, which sets the decoder's pixel format and the
        /// renderer's coefficients FROM THE STREAM rather than from an assumption.
        full_range: bool,
    },
    /// Tear the decode pipeline down.
    StopDecodePipeline,
    /// The host acknowledged an in-session resize.
    ///
    /// The runtime stages it as the PENDING capture size and adopts it as the aspect-fit
    /// denominator only once a decoded buffer actually arrives at that size, because in-flight
    /// old-size frames may still be queued behind the acknowledgement.
    UpdateCaptureSize(VideoSize),
    /// The stream's content cadence, at session start and on every governed step. Duplicate
    /// deliveries are idempotent, which is why the host sends it twice.
    ApplyStreamCadence(u16),
    /// A host-measured scroll offset for the reprojector, with the moving-content band. A zero
    /// offset arms the reprojector's decay, meaning scrolling stopped.
    ApplyScrollOffset {
        /// Signed horizontal shift.
        dx: i16,
        /// Signed vertical shift.
        dy: i16,
        /// Top of the moving band.
        band_top: u16,
        /// Bottom of the moving band.
        band_bottom: u16,
    },
    /// The opaque-content rectangles after a capture-region change: everything outside them renders
    /// transparent, so a popup overhanging the window floats over the canvas instead of a black
    /// bar. An empty list clears the mask.
    ApplyContentMask(Vec<MaskRect>),
    /// The host's maximum resizable point size, which caps the resize popover's fields.
    ApplyDisplayMax(VideoSize),
    /// The host's own half of the stats readout. Informational.
    ApplyHostStats {
        /// Smoothed round-trip time, tenths of a millisecond.
        rtt_tenths_millis: u16,
        /// Encode wall-time average, tenths of a millisecond.
        encode_tenths_millis: u16,
    },
    /// The HOST ended the session — a daemon shutdown, a display teardown, or a restarted daemon
    /// answering an unbound lane. The runtime rebuilds the WHOLE pipeline on a fresh lane, which is
    /// the reconnect-wedge fix, and is deliberately distinct from a local stop.
    SessionEndedByHost,
    /// The host REFUSED the session. Terminal and NON-retrying.
    ///
    /// Deliberately distinct from the ended case, whose handler rebuilds and re-hellos: rebuilding
    /// on a refusal would re-send the same doomed hello forever. The pane tears down and falls back
    /// to the picker instead.
    SessionRejectedByHost,
}

/// The state machine.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoClientStateMachine {
    state: VideoClientState,
    target: VideoStreamTarget,
    viewport: VideoSize,
    stream_id: u32,
    capture_size: VideoSize,
    window_bounds_cg: VideoRect,
}

impl VideoClientStateMachine {
    /// A machine for one target and the client viewport the host should size capture against.
    #[must_use]
    pub const fn new(target: VideoStreamTarget, viewport: VideoSize) -> Self {
        Self {
            state: VideoClientState::Idle,
            target,
            viewport,
            stream_id: 0,
            capture_size: VideoSize::new(0.0, 0.0),
            window_bounds_cg: VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
        }
    }

    /// A machine rebuilt from state that was carried elsewhere and handed back.
    ///
    /// The machine is six scalars and two rectangles, all of them read by whoever drives it, so a
    /// caller that holds it by value — the Swift session struct across the FFI boundary — hands the
    /// whole thing in on every call rather than owning an allocation here. This is the only way
    /// back in, and it takes exactly what [`Self::state`] and its siblings answer.
    #[must_use]
    pub const fn restored(
        state: VideoClientState,
        target: VideoStreamTarget,
        viewport: VideoSize,
        stream_id: u32,
        capture_size: VideoSize,
        window_bounds_cg: VideoRect,
    ) -> Self {
        Self {
            state,
            target,
            viewport,
            stream_id,
            capture_size,
            window_bounds_cg,
        }
    }

    /// The lifecycle state.
    #[must_use]
    pub const fn state(&self) -> VideoClientState {
        self.state
    }

    /// The client viewport the host sizes capture against.
    #[must_use]
    pub const fn viewport(&self) -> VideoSize {
        self.viewport
    }

    /// What this session asked for.
    #[must_use]
    pub const fn target(&self) -> VideoStreamTarget {
        self.target
    }

    /// The window this session asked to remote, or zero for a display target.
    #[must_use]
    pub const fn requested_window_id(&self) -> u32 {
        match self.target {
            VideoStreamTarget::Window(id) => id,
            VideoStreamTarget::Display(_) => 0,
        }
    }

    /// The session id the host minted, populated on an accepted acknowledgement.
    #[must_use]
    pub const fn stream_id(&self) -> u32 {
        self.stream_id
    }

    /// The negotiated capture size.
    #[must_use]
    pub const fn capture_size(&self) -> VideoSize {
        self.capture_size
    }

    /// The target's bounds as the acknowledgement reported them.
    #[must_use]
    pub const fn window_bounds_cg(&self) -> VideoRect {
        self.window_bounds_cg
    }

    /// Whether received media should be processed right now.
    #[must_use]
    pub const fn media_flowing(&self) -> bool {
        matches!(self.state, VideoClientState::Streaming)
    }

    /// Starts the session: prime the cursor flow, send the hello.
    pub fn start(&mut self) -> Vec<ClientEffect> {
        if self.state != VideoClientState::Idle {
            return Vec::new();
        }
        self.state = VideoClientState::Connecting;
        vec![
            ClientEffect::PrimeCursorFlow,
            ClientEffect::SendControl(self.hello_message()),
        ]
    }

    /// Re-emits the hello while still connecting — the other half of the reconnect-wedge fix.
    ///
    /// Any resolved state returns nothing, which ends the retry loop. A duplicate hello is
    /// idempotent on the host: it re-acknowledges without restarting capture.
    ///
    /// The prime rides every retry rather than just the first hello, because a session that sat
    /// connecting across a host daemon restart reconnects THROUGH this path onto a daemon that
    /// never saw the lane's original one-shot prime — and without a re-prime its cursor channel
    /// stays dead while video and input recover.
    pub fn resend_hello(&mut self) -> Vec<ClientEffect> {
        if self.state != VideoClientState::Connecting {
            return Vec::new();
        }
        vec![
            ClientEffect::PrimeCursorFlow,
            ClientEffect::SendControl(self.hello_message()),
        ]
    }

    /// A local stop: tell the host, best effort, and tear down.
    pub fn stop(&mut self) -> Vec<ClientEffect> {
        if self.state == VideoClientState::Stopped {
            return Vec::new();
        }
        let was_streaming = self.state == VideoClientState::Streaming;
        self.state = VideoClientState::Stopped;
        let mut effects = vec![ClientEffect::SendControl(VideoControlMessage::Bye)];
        if was_streaming {
            effects.push(ClientEffect::StopDecodePipeline);
        }
        effects
    }

    /// A control datagram arrived from the host.
    ///
    /// A duplicate accepted acknowledgement while already streaming is ignored, because UDP may
    /// deliver the same one more than once.
    pub fn handle_control(&mut self, message: &VideoControlMessage) -> Vec<ClientEffect> {
        match *message {
            VideoControlMessage::HelloAck {
                accepted,
                stream_id,
                capture_width,
                capture_height,
                window_bounds_cg,
                full_range,
            } => {
                self.handle_hello_ack(
                    accepted,
                    stream_id,
                    capture_width,
                    capture_height,
                    window_bounds_cg,
                    full_range,
                )
            },
            VideoControlMessage::Bye => {
                if !matches!(
                    self.state,
                    VideoClientState::Streaming | VideoClientState::Connecting
                ) {
                    return Vec::new();
                }
                self.state = VideoClientState::Stopped;
                // The ended effect is emitted ONLY here, on a host-initiated end: the runtime
                // rebuilds the whole pipeline and re-hellos on a fresh lane. A local stop must never
                // trigger that rebuild.
                vec![ClientEffect::StopDecodePipeline, ClientEffect::SessionEndedByHost]
            },
            // The host adopted a new capture size. It is staged as pending; adopting it as the
            // aspect-fit denominator is frame-gated, because in-flight old-size frames may still be
            // queued behind the acknowledgement. The echoed epoch is not re-validated — the host
            // already dropped the stale ones. A fixed-size session never reaches this at all.
            VideoControlMessage::ResizeAck {
                capture_width,
                capture_height,
                ..
            } => {
                self.while_streaming(|| {
                    vec![ClientEffect::UpdateCaptureSize(VideoSize::new(
                        f64::from(capture_width),
                        f64::from(capture_height),
                    ))]
                })
            },
            // A zero cadence is nonsense the host never sends; dropping it is depth against a
            // corrupt body that still parsed.
            VideoControlMessage::StreamCadence { fps } => {
                self.while_streaming(|| {
                    if fps >= 1 {
                        vec![ClientEffect::ApplyStreamCadence(fps)]
                    } else {
                        Vec::new()
                    }
                })
            },
            // A zero offset still flows: it arms the reprojector's decay when scrolling stops.
            VideoControlMessage::ScrollOffset {
                dx,
                dy,
                band_top,
                band_bottom,
            } => {
                self.while_streaming(|| {
                    vec![ClientEffect::ApplyScrollOffset {
                        dx,
                        dy,
                        band_top,
                        band_bottom,
                    }]
                })
            },
            VideoControlMessage::ContentMask(ref rects) => {
                self.while_streaming(|| vec![ClientEffect::ApplyContentMask(rects.clone())])
            },
            // A degenerate maximum is dropped rather than pinning the popover's fields to zero.
            VideoControlMessage::DisplayMax { width, height } => {
                self.while_streaming(|| {
                    if width >= 1 && height >= 1 {
                        vec![ClientEffect::ApplyDisplayMax(VideoSize::new(
                            f64::from(width),
                            f64::from(height),
                        ))]
                    } else {
                        Vec::new()
                    }
                })
            },
            // Zeros flow: zero means no reading yet, which the readout renders as a dash rather
            // than a fake measurement.
            VideoControlMessage::HostStats {
                rtt_tenths_millis,
                encode_tenths_millis,
            } => {
                self.while_streaming(|| {
                    vec![ClientEffect::ApplyHostStats {
                        rtt_tenths_millis,
                        encode_tenths_millis,
                    }]
                })
            },
            // The rest are client-to-host, or host-to-client but answered out of band on their own
            // lanes — discovery, the window feed, the blob queries — rather than by a streaming
            // session's machine. The dormant dialog pair lands here too.
            _ => Vec::new(),
        }
    }

    /// The wire hello for this target, shared by the first send and every retry.
    const fn hello_message(&self) -> VideoControlMessage {
        match self.target {
            VideoStreamTarget::Window(id) => {
                VideoControlMessage::Hello {
                    protocol_version: PROTOCOL_VERSION,
                    requested_window_id: id,
                    viewport: self.viewport,
                }
            },
            VideoStreamTarget::Display(id) => {
                VideoControlMessage::HelloDisplay {
                    protocol_version: PROTOCOL_VERSION,
                    requested_display_id: id,
                    viewport: self.viewport,
                }
            },
        }
    }

    fn handle_hello_ack(
        &mut self,
        accepted: bool,
        stream_id: u32,
        capture_width: u16,
        capture_height: u16,
        window_bounds_cg: VideoRect,
        full_range: bool,
    ) -> Vec<ClientEffect> {
        if self.state != VideoClientState::Connecting {
            // Already resolved: a duplicate or late acknowledgement is inert.
            return Vec::new();
        }
        if !accepted {
            // A terminal refusal: the window is gone on the host, or the versions disagree. The
            // connecting guard above makes a duplicate refusal inert.
            self.state = VideoClientState::Rejected;
            return vec![ClientEffect::SessionRejectedByHost];
        }
        self.stream_id = stream_id;
        self.capture_size = VideoSize::new(f64::from(capture_width), f64::from(capture_height));
        self.window_bounds_cg = window_bounds_cg;
        self.state = VideoClientState::Streaming;
        vec![ClientEffect::StartDecodePipeline {
            capture_size: self.capture_size,
            window_bounds_cg,
            full_range,
        }]
    }

    /// Runs a handler only while streaming, so a stray or late message after teardown is inert.
    fn while_streaming(&self, handler: impl FnOnce() -> Vec<ClientEffect>) -> Vec<ClientEffect> {
        if self.media_flowing() {
            handler()
        } else {
            Vec::new()
        }
    }
}

/// The first hello retry fires this long after the initial hello, in seconds.
pub const HELLO_RETRY_INITIAL_DELAY: f64 = 0.5;
/// The ceiling on the hello retry backoff, in seconds.
pub const HELLO_RETRY_MAX_DELAY: f64 = 5.0;

/// How long to wait before re-sending the hello, for a zero-based retry number.
///
/// Exponential from the initial delay and capped: fast enough that a lost acknowledgement costs
/// half a second, slow enough that a pane pointed at a downed host settles to one small datagram
/// every few seconds. Two doublings already exceed the cap, so the shift is short-circuited well
/// before a long retry loop could overflow it.
#[must_use]
pub fn hello_retry_delay(attempt: u32) -> f64 {
    if attempt >= 4 {
        return HELLO_RETRY_MAX_DELAY;
    }
    let step = 1_u32 << attempt;
    HELLO_RETRY_MAX_DELAY.min(HELLO_RETRY_INITIAL_DELAY * f64::from(step))
}

/// The sticky show-and-hide reducer behind the pane's reconnecting scrim.
///
/// Sticky for a reason: once shown, the recovery path ITSELF makes the verdict leave stalled — a
/// host-ended rebuild drops the machine back to connecting, and the fresh session starts with no
/// liveness signal at all. Clearing on either would flash the pane healthy while it still shows a
/// stale frozen frame mid-recovery, so the scrim clears ONLY on a real live verdict, meaning
/// traffic is actually flowing again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StallScrimLatch {
    visible: bool,
}

impl StallScrimLatch {
    /// A latch with the scrim down.
    #[must_use]
    pub const fn new() -> Self {
        Self { visible: false }
    }

    /// A latch rebuilt from the one bit it is, for a caller that carries that bit itself.
    #[must_use]
    pub const fn restored(visible: bool) -> Self {
        Self { visible }
    }

    /// Whether the scrim is up.
    #[must_use]
    pub const fn visible(&self) -> bool {
        self.visible
    }

    /// A host-ended rebuild started, so show the scrim NOW.
    ///
    /// The farewell path never produces a stalled verdict — the machine leaves streaming before the
    /// monitor can see a gap — so without this a gracefully shut-down host that never returns would
    /// leave the pane frozen in hello-retry limbo with no scrim at all. Returns what changed, and
    /// nothing when the scrim is already up, because duplicate farewells should be quiet.
    pub const fn note_reconnecting(&mut self) -> Option<bool> {
        if self.visible {
            return None;
        }
        self.visible = true;
        Some(true)
    }

    /// Folds one verdict, returning the new visibility only when it FLIPPED. The two indefinite
    /// verdicts hold the current state, which is what makes the latch sticky through a rebuild.
    pub const fn apply(&mut self, verdict: StallVerdict) -> Option<bool> {
        match verdict {
            StallVerdict::Stalled if !self.visible => {
                self.visible = true;
                Some(true)
            },
            StallVerdict::Live if self.visible => {
                self.visible = false;
                Some(false)
            },
            StallVerdict::Stalled
            | StallVerdict::Live
            | StallVerdict::NotConnected
            | StallVerdict::Unknown => None,
        }
    }
}

/// The typed outcome of one received media datagram.
#[derive(Debug, Clone, PartialEq)]
pub enum RoutedDatagram {
    /// A control message.
    Control(VideoControlMessage),
    /// A video fragment, for the reassembler.
    VideoFragment(Box<FrameFragment>),
    /// A window geometry update.
    Geometry(WindowGeometryMessage),
    /// An audio datagram, either the stream config or one encoded frame.
    Audio(AudioChannelMessage),
    /// Malformed: drop it. A corrupt single packet must never take the receiver down, which is the
    /// same contract the reassembler holds.
    Drop,
    /// A channel the client does not receive on, or media while not streaming.
    Ignore,
}

/// Routes one media-socket datagram by its channel.
///
/// Control is ALWAYS processed, because the acknowledgement that starts streaming and the farewell
/// both arrive on it. Everything else waits for the session to be streaming. The cursor arrives on
/// its own socket, and input and recovery are client-to-host only.
#[must_use]
pub fn route_datagram(channel: VideoChannel, data: &[u8], media_flowing: bool) -> RoutedDatagram {
    match channel {
        VideoChannel::Control => {
            VideoControlMessage::decode(data).map_or(RoutedDatagram::Drop, RoutedDatagram::Control)
        },
        VideoChannel::Video if media_flowing => {
            FrameFragment::decode(data).map_or(RoutedDatagram::Drop, |fragment| {
                RoutedDatagram::VideoFragment(Box::new(fragment))
            })
        },
        VideoChannel::Geometry if media_flowing => {
            WindowGeometryMessage::decode(data).map_or(RoutedDatagram::Drop, RoutedDatagram::Geometry)
        },
        VideoChannel::Audio if media_flowing => {
            AudioChannelMessage::decode(data).map_or(RoutedDatagram::Drop, RoutedDatagram::Audio)
        },
        VideoChannel::Video
        | VideoChannel::Geometry
        | VideoChannel::Audio
        | VideoChannel::Cursor
        | VideoChannel::Input
        | VideoChannel::Recovery => RoutedDatagram::Ignore,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the negotiated sizes are exact small integers carried as doubles"
    )]

    use super::{
        ClientEffect, HELLO_RETRY_INITIAL_DELAY, HELLO_RETRY_MAX_DELAY, RoutedDatagram, StallScrimLatch,
        VideoClientState, VideoClientStateMachine, VideoStreamTarget, hello_retry_delay, route_datagram,
    };
    use crate::geometry::{VideoRect, VideoSize};
    use crate::keepalive::StallVerdict;
    use crate::recovery_routing::VideoChannel;
    use crate::session_state::PROTOCOL_VERSION;
    use crate::video_control::VideoControlMessage;

    fn viewport() -> VideoSize {
        VideoSize::new(1440.0, 900.0)
    }

    fn machine() -> VideoClientStateMachine {
        VideoClientStateMachine::new(VideoStreamTarget::Window(42), viewport())
    }

    fn accepted_ack() -> VideoControlMessage {
        VideoControlMessage::HelloAck {
            accepted: true,
            stream_id: 7,
            capture_width: 1200,
            capture_height: 800,
            window_bounds_cg: VideoRect::xywh(10.0, 20.0, 1200.0, 800.0),
            full_range: true,
        }
    }

    /// A machine already streaming, which is where most of the message handling lives.
    fn streaming() -> VideoClientStateMachine {
        let mut machine = machine();
        machine.start();
        machine.handle_control(&accepted_ack());
        machine
    }

    #[test]
    fn starting_primes_the_cursor_flow_before_it_says_hello() {
        let mut machine = machine();
        let effects = machine.start();
        assert_eq!(effects, vec![
            ClientEffect::PrimeCursorFlow,
            ClientEffect::SendControl(VideoControlMessage::Hello {
                protocol_version: PROTOCOL_VERSION,
                requested_window_id: 42,
                viewport: viewport(),
            }),
        ],);
        assert_eq!(machine.state(), VideoClientState::Connecting);
        assert!(machine.start().is_empty(), "starting twice says nothing twice");
    }

    #[test]
    fn a_display_session_says_a_different_hello_and_reports_no_window() {
        let mut machine = VideoClientStateMachine::new(VideoStreamTarget::Display(0), viewport());
        assert_eq!(
            machine.start().last(),
            Some(&ClientEffect::SendControl(VideoControlMessage::HelloDisplay {
                protocol_version: PROTOCOL_VERSION,
                requested_display_id: 0,
                viewport: viewport(),
            })),
        );
        assert_eq!(machine.requested_window_id(), 0);
    }

    #[test]
    fn an_accepted_acknowledgement_brings_the_pipeline_up_at_the_negotiated_size() {
        let mut machine = machine();
        machine.start();
        let effects = machine.handle_control(&accepted_ack());
        assert_eq!(effects, vec![ClientEffect::StartDecodePipeline {
            capture_size: VideoSize::new(1200.0, 800.0),
            window_bounds_cg: VideoRect::xywh(10.0, 20.0, 1200.0, 800.0),
            full_range: true,
        }],);
        assert_eq!(machine.state(), VideoClientState::Streaming);
        assert_eq!(machine.stream_id(), 7);
        assert_eq!(machine.capture_size().width, 1200.0);
        assert!(machine.media_flowing());
        assert!(
            machine.handle_control(&accepted_ack()).is_empty(),
            "the wire may deliver the same acknowledgement twice",
        );
    }

    #[test]
    fn a_refusal_is_terminal_and_never_rebuilds() {
        let mut machine = machine();
        machine.start();
        let refusal = VideoControlMessage::HelloAck {
            accepted: false,
            stream_id: 0,
            capture_width: 0,
            capture_height: 0,
            window_bounds_cg: VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
            full_range: false,
        };
        assert_eq!(
            machine.handle_control(&refusal),
            vec![ClientEffect::SessionRejectedByHost],
            "rebuilding here would re-send the same doomed hello forever",
        );
        assert_eq!(machine.state(), VideoClientState::Rejected);
        assert!(machine.handle_control(&refusal).is_empty());
        assert!(
            machine.resend_hello().is_empty(),
            "a resolved state ends the retry loop"
        );
    }

    #[test]
    fn a_farewell_from_the_host_rebuilds_where_a_local_stop_does_not() {
        let mut machine = streaming();
        assert_eq!(machine.handle_control(&VideoControlMessage::Bye), vec![
            ClientEffect::StopDecodePipeline,
            ClientEffect::SessionEndedByHost,
        ],);
        assert_eq!(machine.state(), VideoClientState::Stopped);

        let mut local = streaming();
        assert_eq!(
            local.stop(),
            vec![
                ClientEffect::SendControl(VideoControlMessage::Bye),
                ClientEffect::StopDecodePipeline,
            ],
            "a local stop must not ask for a rebuild",
        );
        assert!(local.stop().is_empty());
    }

    #[test]
    fn a_farewell_while_still_connecting_still_ends_the_session() {
        let mut machine = machine();
        machine.start();
        assert_eq!(
            machine.handle_control(&VideoControlMessage::Bye).len(),
            2,
            "a restarted daemon answering an unbound lane arrives here",
        );
        assert_eq!(machine.state(), VideoClientState::Stopped);
    }

    #[test]
    fn stopping_before_the_stream_came_up_tells_the_host_and_nothing_else() {
        let mut machine = machine();
        machine.start();
        assert_eq!(
            machine.stop(),
            vec![ClientEffect::SendControl(VideoControlMessage::Bye)],
            "there is no pipeline to tear down yet",
        );
    }

    #[test]
    fn the_retry_re_primes_the_cursor_flow_every_time() {
        let mut machine = machine();
        machine.start();
        let retry = machine.resend_hello();
        assert_eq!(retry.first(), Some(&ClientEffect::PrimeCursorFlow));
        assert_eq!(retry.len(), 2);
        assert_eq!(
            machine.state(),
            VideoClientState::Connecting,
            "a retry decides nothing"
        );
    }

    #[test]
    fn the_in_session_messages_only_land_while_streaming() {
        let resize = VideoControlMessage::ResizeAck {
            capture_width: 640,
            capture_height: 480,
            epoch: 3,
        };
        let mut connecting = machine();
        connecting.start();
        assert!(connecting.handle_control(&resize).is_empty());

        let mut machine = streaming();
        assert_eq!(machine.handle_control(&resize), vec![
            ClientEffect::UpdateCaptureSize(VideoSize::new(640.0, 480.0))
        ],);
        assert_eq!(
            machine.handle_control(&VideoControlMessage::StreamCadence { fps: 30 }),
            vec![ClientEffect::ApplyStreamCadence(30)],
        );
        assert_eq!(
            machine.handle_control(&VideoControlMessage::ScrollOffset {
                dx: 0,
                dy: 0,
                band_top: 0,
                band_bottom: 0,
            }),
            vec![ClientEffect::ApplyScrollOffset {
                dx: 0,
                dy: 0,
                band_top: 0,
                band_bottom: 0,
            }],
            "a zero offset arms the reprojector's decay rather than meaning nothing",
        );
        assert_eq!(
            machine.handle_control(&VideoControlMessage::ContentMask(Vec::new())),
            vec![ClientEffect::ApplyContentMask(Vec::new())],
            "an empty list clears the mask",
        );
        assert_eq!(
            machine.handle_control(&VideoControlMessage::HostStats {
                rtt_tenths_millis: 0,
                encode_tenths_millis: 12,
            }),
            vec![ClientEffect::ApplyHostStats {
                rtt_tenths_millis: 0,
                encode_tenths_millis: 12,
            }],
            "a zero reads as no reading yet, not as a fake measurement",
        );
    }

    #[test]
    fn a_degenerate_cadence_or_maximum_is_dropped_rather_than_applied() {
        let mut machine = streaming();
        assert!(
            machine
                .handle_control(&VideoControlMessage::StreamCadence { fps: 0 })
                .is_empty(),
        );
        assert!(
            machine
                .handle_control(&VideoControlMessage::DisplayMax {
                    width: 0,
                    height: 900,
                })
                .is_empty(),
            "pinning the popover's field to zero is worse than leaving it uncapped",
        );
        assert_eq!(
            machine.handle_control(&VideoControlMessage::DisplayMax {
                width: 1440,
                height: 900,
            }),
            vec![ClientEffect::ApplyDisplayMax(VideoSize::new(1440.0, 900.0))],
        );
    }

    #[test]
    fn a_client_to_host_message_arriving_back_is_a_quiet_no_op() {
        let mut machine = streaming();
        assert!(machine.handle_control(&VideoControlMessage::Keepalive).is_empty());
        assert!(
            machine
                .handle_control(&VideoControlMessage::ListWindows)
                .is_empty()
        );
        assert!(
            machine
                .handle_control(&VideoControlMessage::WindowFeedCurrent { generation: 4 })
                .is_empty(),
            "the feed is answered on its own lane, not by a streaming session",
        );
    }

    #[test]
    fn the_retry_backoff_doubles_and_then_holds_at_the_cap() {
        assert_eq!(hello_retry_delay(0), HELLO_RETRY_INITIAL_DELAY);
        assert_eq!(hello_retry_delay(1), 1.0);
        assert_eq!(hello_retry_delay(2), 2.0);
        assert_eq!(hello_retry_delay(3), 4.0);
        assert_eq!(hello_retry_delay(4), HELLO_RETRY_MAX_DELAY);
        assert_eq!(
            hello_retry_delay(u32::MAX),
            HELLO_RETRY_MAX_DELAY,
            "a long loop can never overflow the shift",
        );
    }

    #[test]
    fn the_scrim_clears_only_on_real_traffic() {
        let mut latch = StallScrimLatch::new();
        assert_eq!(latch.apply(StallVerdict::Unknown), None);
        assert_eq!(latch.apply(StallVerdict::Stalled), Some(true));
        assert_eq!(latch.apply(StallVerdict::Stalled), None, "no per-tick re-notify");
        assert_eq!(
            latch.apply(StallVerdict::NotConnected),
            None,
            "the rebuild itself must not read as healthy",
        );
        assert_eq!(
            latch.apply(StallVerdict::Unknown),
            None,
            "nor must a fresh session"
        );
        assert!(latch.visible());
        assert_eq!(latch.apply(StallVerdict::Live), Some(false));
        assert_eq!(latch.apply(StallVerdict::Live), None);
    }

    #[test]
    fn a_farewell_raises_the_scrim_that_no_verdict_would_have() {
        let mut latch = StallScrimLatch::new();
        assert_eq!(latch.note_reconnecting(), Some(true));
        assert_eq!(latch.note_reconnecting(), None, "duplicate farewells are quiet");
        assert!(latch.visible());
    }

    #[test]
    fn control_routes_even_before_the_stream_flows() {
        let bye = VideoControlMessage::Bye.encode();
        assert_eq!(
            route_datagram(VideoChannel::Control, &bye, false),
            RoutedDatagram::Control(VideoControlMessage::Bye),
        );
    }

    #[test]
    fn media_is_ignored_until_the_session_is_streaming() {
        assert_eq!(
            route_datagram(VideoChannel::Video, &[0; 32], false),
            RoutedDatagram::Ignore,
        );
        assert_eq!(
            route_datagram(VideoChannel::Geometry, &[0; 32], false),
            RoutedDatagram::Ignore,
        );
        assert_eq!(
            route_datagram(VideoChannel::Audio, &[0; 32], false),
            RoutedDatagram::Ignore,
        );
    }

    #[test]
    fn a_corrupt_datagram_is_dropped_rather_than_taking_the_receiver_down() {
        assert_eq!(
            route_datagram(VideoChannel::Control, &[], true),
            RoutedDatagram::Drop
        );
        assert_eq!(
            route_datagram(VideoChannel::Video, &[0xFF], true),
            RoutedDatagram::Drop,
        );
        assert_eq!(
            route_datagram(VideoChannel::Geometry, &[0xFF], true),
            RoutedDatagram::Drop,
        );
        assert_eq!(
            route_datagram(VideoChannel::Audio, &[0xFF], true),
            RoutedDatagram::Drop,
        );
    }

    #[test]
    fn the_client_never_receives_on_its_own_send_channels() {
        for channel in [VideoChannel::Cursor, VideoChannel::Input, VideoChannel::Recovery] {
            assert_eq!(
                route_datagram(channel, &[1, 2, 3], true),
                RoutedDatagram::Ignore,
                "the cursor has its own socket; input and recovery only ever go out",
            );
        }
    }
}
