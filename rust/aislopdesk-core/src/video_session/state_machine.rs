//! The host video-session state machine: validates the client `hello`, decides the `helloAck`,
//! gates whether media may flow, and folds in-session `resizeRequest`s into [`Effect`]s.

use super::{Effect, SizeNegotiation, VideoSessionState};
use crate::geometry::{VideoRect, VideoSize};
use crate::video_control::VideoControlMessage;

/// The pure state machine driving a host video session.
///
/// It validates the client `hello`,
/// decides the `helloAck`, and gates whether media may flow — with NO live component. The
/// actor advances it and acts on the returned [`Effect`]s. The Swift shell's
/// `VideoSessionStateMachine` mirrors this.
#[derive(Debug, Clone)]
pub struct VideoSessionStateMachine {
    state: VideoSessionState,
    capture_width: u16,
    capture_height: u16,
    window_id: u32,
    /// The monotonically increasing stream id handed to the client on accept (lets a
    /// reconnecting client distinguish a fresh session).
    next_stream_id: u32,
    /// WF-6 (#8): whether this host is encoding FULL-RANGE luma. Stamped into every accepted
    /// `helloAck` (and the duplicate re-ack — which MUST echo the same value). A reject always
    /// sends `full_range: false`. Default false ⇒ today's video-range, byte-identical.
    full_range: bool,
    /// The highest resize epoch already APPLIED for the current streaming session, so a
    /// stale/duplicate `resizeRequest` (UDP may reorder/duplicate) is dropped. Re-armed to 0
    /// per accepted session; 0 ⇒ none applied yet (the first request, epoch ≥ 1, always wins).
    last_resize_epoch: u32,
    /// The stream id minted for the CURRENT accepted session (echoed on the duplicate re-ack).
    last_stream_id: u32,
}

impl Default for VideoSessionStateMachine {
    fn default() -> Self {
        Self::new(Self::DEFAULT_NEXT_STREAM_ID, Self::DEFAULT_FULL_RANGE)
    }
}

impl VideoSessionStateMachine {
    /// Default `next_stream_id` (the first accepted session mints stream id 1).
    pub const DEFAULT_NEXT_STREAM_ID: u32 = 1;
    /// Default `full_range` (video-range, the wire-byte-identical OFF path).
    pub const DEFAULT_FULL_RANGE: bool = false;

    /// Builds a fresh state machine in [`VideoSessionState::Idle`]. `next_stream_id` is the id
    /// the first accepted session will mint; `full_range` stamps the negotiated luma range into
    /// every accept ack. See [`DEFAULT_NEXT_STREAM_ID`](Self::DEFAULT_NEXT_STREAM_ID) /
    /// [`DEFAULT_FULL_RANGE`](Self::DEFAULT_FULL_RANGE) (or [`Default`]) for the canonical defaults.
    #[must_use]
    pub const fn new(next_stream_id: u32, full_range: bool) -> Self {
        Self {
            state: VideoSessionState::Idle,
            capture_width: 0,
            capture_height: 0,
            window_id: 0,
            next_stream_id,
            full_range,
            last_resize_epoch: 0,
            last_stream_id: 0,
        }
    }

    /// The current lifecycle state.
    #[must_use]
    pub const fn state(&self) -> VideoSessionState {
        self.state
    }

    /// Negotiated capture width (0 until a hello is accepted).
    #[must_use]
    pub const fn capture_width(&self) -> u16 {
        self.capture_width
    }

    /// Negotiated capture height (0 until a hello is accepted).
    #[must_use]
    pub const fn capture_height(&self) -> u16 {
        self.capture_height
    }

    /// The window the accepted session is remoting (0 until a hello is accepted).
    #[must_use]
    pub const fn window_id(&self) -> u32 {
        self.window_id
    }

    /// Whether this host advertises full-range luma in its accept acks.
    #[must_use]
    pub const fn full_range(&self) -> bool {
        self.full_range
    }

    /// The highest resize epoch already applied for the current session (0 = none).
    #[must_use]
    pub const fn last_resize_epoch(&self) -> u32 {
        self.last_resize_epoch
    }

    /// Whether media (video/geometry/cursor) is allowed to flow right now.
    #[must_use]
    pub const fn media_flowing(&self) -> bool {
        matches!(self.state, VideoSessionState::Streaming)
    }

    /// `start()` was called: bind sockets, wait for the client hello. A no-op (empty effects)
    /// unless currently [`VideoSessionState::Idle`].
    pub fn start(&mut self) -> Vec<Effect> {
        if self.state != VideoSessionState::Idle {
            return Vec::new();
        }
        self.state = VideoSessionState::Listening;
        Vec::new()
    }

    /// Convenience for the hello/bye call sites that never carry an in-session resize: matches
    /// the Swift shell's `resolveResizeSize` default argument (`{ _, _ in nil }`). Equivalent to
    /// [`handle_control`](Self::handle_control) with a resolver that always rejects resizes.
    pub fn handle_control_no_resize(
        &mut self,
        message: &VideoControlMessage,
        window_bounds_cg: VideoRect,
        resolve_capture_size: impl Fn(u32, VideoSize) -> Option<(u16, u16)>,
    ) -> Vec<Effect> {
        self.handle_control(
            message,
            window_bounds_cg,
            resolve_capture_size,
            |_window_id: u32, _desired: VideoSize| None,
        )
    }

    /// A control datagram arrived. Returns the effects (helloAck + startCapture on a valid
    /// hello; stopCapture on bye; resizeCapture on an in-session resize). An invalid/duplicate
    /// hello is rejected.
    ///
    /// - `message`: the decoded control message.
    /// - `window_bounds_cg`: the live window bounds to report in the ack (the actor reads these
    ///   from the geometry watcher; the pure SM just forwards them).
    /// - `resolve_capture_size`: maps `(requested_window_id, viewport)` → the capture size the
    ///   host will actually use. `None` rejects the session.
    /// - `resolve_resize_size`: maps an in-session `resizeRequest`'s `(window_id, desired)` →
    ///   the clamped capture size the host will adopt (typically via
    ///   [`SizeNegotiation::clamp`]). `None` rejects the resize (window gone / out of policy),
    ///   so capture stays at its current size and the epoch is NOT advanced.
    #[allow(clippy::too_many_lines)] // one flat match over the wire variants reads clearest inline.
    pub fn handle_control(
        &mut self,
        message: &VideoControlMessage,
        window_bounds_cg: VideoRect,
        resolve_capture_size: impl Fn(u32, VideoSize) -> Option<(u16, u16)>,
        resolve_resize_size: impl Fn(u32, VideoSize) -> Option<(u16, u16)>,
    ) -> Vec<Effect> {
        match message {
            VideoControlMessage::Hello {
                protocol_version,
                requested_window_id,
                viewport,
            } => {
                let requested_window_id = *requested_window_id;
                let viewport = *viewport;
                // Strict version check — no fallback (doc 20 §4 discipline).
                if *protocol_version != crate::VIDEO_PROTOCOL_VERSION {
                    return vec![Effect::SendControl(reject_hello_ack(window_bounds_cg))];
                }
                // Only accept a hello while listening; ignore a duplicate once streaming
                // (idempotent — the client may retransmit the unreliable hello).
                if self.state != VideoSessionState::Listening {
                    if self.state == VideoSessionState::Streaming
                        && requested_window_id == self.window_id
                    {
                        // Re-ack an in-flight duplicate so a lost ack is recovered, but do NOT
                        // restart capture.
                        return vec![Effect::SendControl(VideoControlMessage::HelloAck {
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
                let Some((w, h)) = resolve_capture_size(requested_window_id, viewport) else {
                    return vec![Effect::SendControl(reject_hello_ack(window_bounds_cg))];
                };
                let stream_id = self.next_stream_id;
                self.next_stream_id = self.next_stream_id.wrapping_add(1);
                self.last_stream_id = stream_id;
                self.capture_width = w;
                self.capture_height = h;
                self.window_id = requested_window_id;
                // Reset the resize epoch for the FRESH session. A reconnecting client mints its
                // own epochs from 1 again (its `ResizeDebounce` is per-connection), so a stale
                // `last_resize_epoch` carried over from the PRIOR session would make every epoch
                // of the new session look stale and silently drop its first resizes. Re-arm to 0
                // here so the new session's first request (epoch ≥ 1) wins.
                self.last_resize_epoch = 0;
                self.state = VideoSessionState::Streaming;
                vec![
                    Effect::SendControl(VideoControlMessage::HelloAck {
                        accepted: true,
                        stream_id,
                        capture_width: w,
                        capture_height: h,
                        window_bounds_cg,
                        full_range: self.full_range,
                    }),
                    Effect::StartCapture {
                        window_id: requested_window_id,
                        width: w,
                        height: h,
                    },
                ]
            }
            VideoControlMessage::Bye => {
                // A client bye re-arms the session so a fresh hello can reconnect WITHOUT a
                // daemon restart (#8). Return to .listening (re-armable) and stop capture only if
                // it was actually streaming. (Local stop() — which also closes the UDP sockets —
                // stays terminal .stopped, NOT re-armable.)
                let was_streaming = self.state == VideoSessionState::Streaming;
                if self.state != VideoSessionState::Streaming
                    && self.state != VideoSessionState::Listening
                {
                    return Vec::new();
                }
                self.state = VideoSessionState::Listening;
                if was_streaming {
                    vec![Effect::StopCapture]
                } else {
                    Vec::new()
                }
            }
            VideoControlMessage::ResizeRequest { desired, epoch } => {
                let desired = *desired;
                let epoch = *epoch;
                // In-session resize: accept ONLY while streaming. A request that arrives while
                // listening/stopped (no live capture) is ignored — there is nothing to re-size.
                if self.state != VideoSessionState::Streaming {
                    return Vec::new();
                }
                // A stale/dup epoch (≤ the last applied) is dropped so a UDP reorder/retransmit
                // cannot shrink-then-grow the capture out of order.
                if SizeNegotiation::is_stale_epoch(epoch, self.last_resize_epoch) {
                    return Vec::new();
                }
                // The closure clamps `desired` against the LIVE window (min/max) for the
                // session's `window_id`; `None` ⇒ wrong/gone window or out-of-policy → reject
                // (capture stays put, epoch NOT advanced so a later valid request still wins).
                let Some((w, h)) = resolve_resize_size(self.window_id, desired) else {
                    return Vec::new();
                };
                self.last_resize_epoch = epoch;
                self.capture_width = w;
                self.capture_height = h;
                // Same session (same stream id, same window) — only the capture geometry changes.
                vec![Effect::ResizeCapture {
                    width: w,
                    height: h,
                    epoch,
                }]
            }
            // The host never receives a helloAck/resizeAck/streamCadence (all host→client) —
            // defensive no-op.
            VideoControlMessage::HelloAck { .. }
            | VideoControlMessage::ResizeAck { .. }
            | VideoControlMessage::StreamCadence { .. }
            // `keepalive` carries NO state-machine semantics — its only effect is the
            // transport-level `last_inbound` stamp the reaper reads. `focusWindow` is actioned at
            // the ACTOR level (it raises the captured window) and likewise has no SM/capture-state
            // effect. Both are defensive no-ops here.
            | VideoControlMessage::Keepalive
            | VideoControlMessage::FocusWindow
            // Window-list AND system-dialog-list discovery are answered at the DAEMON level
            // (session-less, no capture mint) and never reach a session's state machine.
            // `windowList`/`systemDialogList` are host→client and never arrive at the host at all.
            | VideoControlMessage::ListWindows
            | VideoControlMessage::WindowList(_)
            | VideoControlMessage::ListSystemDialogs
            | VideoControlMessage::SystemDialogList(_)
            // `scrollOffset` + `contentMask` are host→client (reprojection hint / transparency mask)
            // and never arrive at the host SM.
            | VideoControlMessage::ScrollOffset { .. }
            | VideoControlMessage::ContentMask(_) => Vec::new(),
        }
    }

    /// `stop()` was called locally (closes the UDP sockets). Terminal: transitions to
    /// [`VideoSessionState::Stopped`] and tears down capture if it was streaming. A second stop
    /// is a no-op.
    pub fn stop(&mut self) -> Vec<Effect> {
        if self.state == VideoSessionState::Stopped {
            return Vec::new();
        }
        let was_streaming = self.state == VideoSessionState::Streaming;
        self.state = VideoSessionState::Stopped;
        if was_streaming {
            vec![Effect::StopCapture]
        } else {
            Vec::new()
        }
    }
}

/// The rejecting `helloAck` (accepted: false, zeroed dims, never full-range). Both reject sites
/// (wrong protocol version, `resolve_capture_size` → `None`) emit this exact message.
const fn reject_hello_ack(window_bounds_cg: VideoRect) -> VideoControlMessage {
    VideoControlMessage::HelloAck {
        accepted: false,
        stream_id: 0,
        capture_width: 0,
        capture_height: 0,
        window_bounds_cg,
        full_range: false,
    }
}
