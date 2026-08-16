//! The keepalive timing contract, and the frozen-stream verdict it makes possible.
//!
//! ## Why keepalive exists
//!
//! UDP has no FIN. A client that VANISHES without a `bye` — a crash, a network drop, or a last lane
//! closing as its fire-and-forget bye is still in flight — would leave the host's pinned flow slot
//! pinned and its capture and encode running with no peer. The clean-`bye` path already frees the
//! slot; the crash-without-bye case is what the client keepalive and the host idle-reaper below are
//! for. The constants are compile-time and shared, so host and client cannot silently drift apart.

/// The client keepalive cadence, in seconds.
///
/// RFC 7675 §5.1's consent-check default is 5 s, well under the 30 s NAT-UDP mapping expiry of
/// RFC 9000 §10.1.2 — so one empty two-byte datagram every 5 s also refreshes the path mapping.
pub const KEEPALIVE_INTERVAL_SECONDS: f64 = 5.0;

/// How long (seconds) a keepalive-proven flow may be idle before the host declares it dead.
///
/// RFC 7675's 30 s consent expiry is 6× the interval, which tolerates about five consecutive
/// keepalive losses before reaping and so survives mobile burst loss. The minimum safe ratio is 3×;
/// 6× is comfortable for a video session, where a 30 s slot reclaim is nobody's problem.
pub const IDLE_TIMEOUT_SECONDS: f64 = 30.0;

/// The host reaper's scan cadence (seconds) — deliberately coarse, and equal to the keepalive
/// interval, so the worst-case reclaim latency is `IDLE_TIMEOUT + REAPER_TICK`, at most 35 s.
pub const REAPER_TICK_SECONDS: f64 = 5.0;

/// The HOST→client heartbeat cadence (seconds): the counterpart of the client keepalive, and the
/// signal the stall scrim is judged by.
///
/// While a session streams, the host sends a zero-body keepalive on the control channel every
/// second, so the client can tell a healthily IDLE window — where idle-skip suppresses frames by
/// design — from a DEAD host, where nothing arrives at all. One second means the 3 s
/// [`StreamStallPolicy::DEFAULT_THRESHOLD_SECONDS`] tolerates two consecutive losses before
/// declaring a stall, at the cost of roughly one 21-byte datagram per second per session.
pub const HOST_HEARTBEAT_INTERVAL_SECONDS: f64 = 1.0;

/// The timestamped liveness inputs. Every time shares one monotonic clock.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StallInputs {
    /// The current time.
    pub now: f64,
    /// When the most recent decoded frame arrived, or `None` if none has.
    pub last_frame_at: Option<f64>,
    /// When the most recent host heartbeat arrived, or `None` if none has — the idle-skip-safe
    /// signal, and the only one trusted while frames are suppressed by design.
    pub last_heartbeat_at: Option<f64>,
    /// Whether the session is nominally connected. A `bye` or a hard disconnect has its own path; a
    /// stall is the "connected but frozen" case that path never sees.
    pub connected: bool,
    /// Whether the host is currently idle-skipping, suppressing frames because the window is
    /// static. While it is, a stale last frame is EXPECTED.
    pub idle_skip_active: bool,
}

/// The stream-liveness verdict.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StallVerdict {
    /// A liveness signal arrived within the threshold: the stream is flowing, or healthily idle.
    Live,
    /// Connected, but no liveness signal for at least the threshold — the stream is FROZEN. Show
    /// the scrim and trigger the reconnect.
    Stalled,
    /// Not connected: the disconnect path owns recovery, and the stall scrim must NOT fire here.
    NotConnected,
    /// No liveness signal has arrived yet, on a just-opened stream. Nothing to judge, no scrim.
    Unknown,
}

/// The frozen-stream detector behind the remote-GUI pane's "reconnecting…" scrim.
///
/// ## The idle-skip trap this is built around
///
/// Idle-skip means the host sends NO frames by design when the remote window is static, so keying a
/// stall off "no frames for N seconds" would false-fire on a perfectly healthy idle window. The
/// heartbeat keeps flowing underneath it — so while idle-skip is active, liveness is judged by the
/// HEARTBEAT alone. When it is not, a fresh frame is itself strong liveness, and the newest of the
/// two counts.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamStallPolicy {
    /// How long (seconds) with no liveness signal before a connected stream is declared stalled.
    pub threshold: f64,
}

impl Default for StreamStallPolicy {
    fn default() -> Self {
        Self {
            threshold: Self::DEFAULT_THRESHOLD_SECONDS,
        }
    }
}

impl StreamStallPolicy {
    /// The default stall threshold (seconds): long enough to ride out a normal keepalive gap and a
    /// brief loss episode, short enough to react before the user gives up on the window.
    pub const DEFAULT_THRESHOLD_SECONDS: f64 = 3.0;

    /// A policy with an explicit threshold.
    #[must_use]
    pub const fn new(threshold: f64) -> Self {
        Self { threshold }
    }

    /// The verdict for one set of inputs. Stalled the instant the gap REACHES the threshold, and
    /// only while connected.
    #[must_use]
    pub fn evaluate(&self, inputs: &StallInputs) -> StallVerdict {
        if !inputs.connected {
            return StallVerdict::NotConnected;
        }
        let signal = if inputs.idle_skip_active {
            inputs.last_heartbeat_at
        } else {
            newest(inputs.last_frame_at, inputs.last_heartbeat_at)
        };
        let Some(signal) = signal else {
            return StallVerdict::Unknown;
        };
        if (inputs.now - signal) >= self.threshold {
            StallVerdict::Stalled
        } else {
            StallVerdict::Live
        }
    }

    /// Whether the stream is stalled — the scrim and reconnect trigger, as one boolean.
    #[must_use]
    pub fn is_stalled(&self, inputs: &StallInputs) -> bool {
        self.evaluate(inputs) == StallVerdict::Stalled
    }
}

/// The later of two optional timestamps, or `None` when neither is present.
const fn newest(a: Option<f64>, b: Option<f64>) -> Option<f64> {
    match (a, b) {
        // The NaN-ignoring IEEE max, matching the other side of the port.
        (Some(x), Some(y)) => Some(x.max(y)),
        (Some(x), None) => Some(x),
        (None, y) => y,
    }
}

#[cfg(test)]
mod tests {
    use super::{StallInputs, StallVerdict, StreamStallPolicy};

    /// A connected stream with both signals at the given times.
    fn inputs(now: f64, frame: Option<f64>, heartbeat: Option<f64>) -> StallInputs {
        StallInputs {
            now,
            last_frame_at: frame,
            last_heartbeat_at: heartbeat,
            connected: true,
            idle_skip_active: false,
        }
    }

    #[test]
    fn a_disconnected_session_is_never_stalled() {
        let mut state = inputs(100.0, Some(0.0), Some(0.0));
        state.connected = false;
        assert_eq!(
            StreamStallPolicy::default().evaluate(&state),
            StallVerdict::NotConnected
        );
    }

    #[test]
    fn a_stream_with_no_signal_yet_is_unknown_rather_than_stalled() {
        let state = inputs(100.0, None, None);
        assert_eq!(
            StreamStallPolicy::default().evaluate(&state),
            StallVerdict::Unknown
        );
    }

    #[test]
    fn the_newest_of_frame_and_heartbeat_is_the_liveness_signal() {
        let policy = StreamStallPolicy::default();
        // The frame is stale but the heartbeat is fresh, and vice versa: either one is enough.
        assert_eq!(
            policy.evaluate(&inputs(100.0, Some(90.0), Some(99.0))),
            StallVerdict::Live
        );
        assert_eq!(
            policy.evaluate(&inputs(100.0, Some(99.0), Some(90.0))),
            StallVerdict::Live
        );
        assert_eq!(
            policy.evaluate(&inputs(100.0, Some(90.0), None)),
            StallVerdict::Stalled
        );
        assert_eq!(
            policy.evaluate(&inputs(100.0, None, Some(99.5))),
            StallVerdict::Live
        );
    }

    #[test]
    fn the_threshold_is_reached_and_not_merely_passed() {
        let policy = StreamStallPolicy::default();
        assert_eq!(
            policy.evaluate(&inputs(100.0, Some(97.5), None)),
            StallVerdict::Live
        );
        assert_eq!(
            policy.evaluate(&inputs(100.0, Some(97.0), None)),
            StallVerdict::Stalled
        );
    }

    /// The trap the policy exists for: a healthy idle window sends no frames on purpose.
    #[test]
    fn during_idle_skip_only_the_heartbeat_is_trusted() {
        let policy = StreamStallPolicy::default();
        let mut state = inputs(100.0, Some(10.0), Some(99.5));
        state.idle_skip_active = true;
        assert_eq!(
            policy.evaluate(&state),
            StallVerdict::Live,
            "a stale frame is expected here"
        );

        // A fresh frame cannot vouch for a dead heartbeat while idle-skip is on…
        state.last_frame_at = Some(99.9);
        state.last_heartbeat_at = Some(80.0);
        assert_eq!(policy.evaluate(&state), StallVerdict::Stalled);
        // …but it can once the host is sending frames again.
        state.idle_skip_active = false;
        assert_eq!(policy.evaluate(&state), StallVerdict::Live);
    }

    #[test]
    fn a_custom_threshold_moves_the_line() {
        let policy = StreamStallPolicy::new(10.0);
        assert!(!policy.is_stalled(&inputs(100.0, Some(95.0), None)));
        assert!(policy.is_stalled(&inputs(100.0, Some(85.0), None)));
    }
}
