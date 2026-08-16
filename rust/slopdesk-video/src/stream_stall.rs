//! The frozen-stream verdict: is a connected pane still receiving anything?
//!
//! The client's remote-GUI pane shows a "reconnecting…" scrim and re-dials when the picture stops
//! moving while the session still believes it is up. This module is the decision alone — no timer,
//! no session, no scrim. The caller stamps two arrival times and asks.
//!
//! ## The idle-skip trap this is built around
//!
//! Idle-skip means the host sends NO frames BY DESIGN while the remote window is static, so a stall
//! keyed on "no frame for N seconds" fires on a perfectly healthy idle window. What keeps flowing
//! under idle-skip is the keepalive, so while it is active the heartbeat is the ONLY liveness
//! signal and a stale last-frame is expected. With idle-skip off, a fresh frame is itself strong
//! liveness, so the newer of the two counts.
//!
//! The [`StallScrimLatch`](crate::client_session::StallScrimLatch) downstream is what decides how
//! long the scrim stays up. This says only what the stream is doing right now.

/// How long with no liveness signal before a connected stream reads as frozen.
///
/// Three seconds: long enough to ride out an ordinary keepalive gap and a brief loss episode, short
/// enough to react before the viewer concludes the app is broken.
pub const DEFAULT_THRESHOLD_SECONDS: f64 = 3.0;

/// The timestamped liveness inputs, all on one monotonic clock.
///
/// The two arrival times are `Option` rather than a sentinel, because "no frame has EVER arrived"
/// and "the last frame arrived at time zero" are different states and only one of them is a stall.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Liveness {
    /// The current time.
    pub now: f64,
    /// When the most recent decoded frame arrived.
    pub last_frame_at: Option<f64>,
    /// When the most recent host keepalive arrived — the idle-skip-safe signal.
    pub last_heartbeat_at: Option<f64>,
    /// Whether the session still believes it is connected. A hard disconnect has its own path.
    pub connected: bool,
    /// Whether the host is suppressing frames because the window is static.
    pub idle_skip_active: bool,
}

/// What the stream is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamVerdict {
    /// A liveness signal arrived within the threshold — flowing, or healthily idle.
    Live,
    /// Connected, and nothing has arrived for at least the threshold. Show the scrim, re-dial.
    Stalled,
    /// Not connected: the disconnect path owns recovery and the stall scrim must NOT fire here.
    NotConnected,
    /// Nothing has arrived yet on a just-opened stream — there is nothing to judge.
    Unknown,
}

/// The verdict for `inputs`, with `threshold` seconds of silence as the stall line.
///
/// Stalled the instant the gap REACHES the threshold (`>=`), so a caller polling on a tick boundary
/// cannot sit one sample short of the decision forever. A non-finite `now` or threshold cannot make
/// this say stalled: the comparison is ordered, and an unordered one is not `>=`.
#[must_use]
pub fn verdict(inputs: Liveness, threshold: f64) -> StreamVerdict {
    if !inputs.connected {
        return StreamVerdict::NotConnected;
    }
    let signal = if inputs.idle_skip_active {
        // Under idle-skip the frames are absent on purpose, so only the keepalive means anything.
        inputs.last_heartbeat_at
    } else {
        newest(inputs.last_frame_at, inputs.last_heartbeat_at)
    };
    let Some(signal) = signal else {
        return StreamVerdict::Unknown;
    };
    if inputs.now - signal >= threshold {
        StreamVerdict::Stalled
    } else {
        StreamVerdict::Live
    }
}

/// The later of two optional timestamps.
const fn newest(a: Option<f64>, b: Option<f64>) -> Option<f64> {
    match (a, b) {
        // The NaN-ignoring IEEE max: one unusable stamp must not discard the other.
        (Some(x), Some(y)) => Some(x.max(y)),
        (Some(x), None) => Some(x),
        (None, Some(y)) => Some(y),
        (None, None) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_THRESHOLD_SECONDS, Liveness, StreamVerdict, verdict};

    /// A connected, actively-streaming pane whose last frame arrived `age` seconds ago.
    fn streaming(age: f64) -> Liveness {
        Liveness {
            now: 100.0,
            last_frame_at: Some(100.0 - age),
            last_heartbeat_at: None,
            connected: true,
            idle_skip_active: false,
        }
    }

    #[test]
    fn a_recent_frame_is_liveness_and_the_threshold_is_inclusive() {
        assert_eq!(
            verdict(streaming(0.5), DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Live
        );
        assert_eq!(
            verdict(streaming(2.999), DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Live
        );
        // Exactly at the line reads as stalled, so a caller polling on the tick cannot miss it.
        assert_eq!(
            verdict(streaming(3.0), DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Stalled
        );
        assert_eq!(
            verdict(streaming(30.0), DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Stalled
        );
    }

    #[test]
    fn under_idle_skip_only_the_heartbeat_counts() {
        let stale_frame_fresh_beat = Liveness {
            now: 100.0,
            last_frame_at: Some(10.0), // ninety seconds old, and expected to be
            last_heartbeat_at: Some(99.0),
            connected: true,
            idle_skip_active: true,
        };
        assert_eq!(
            verdict(stale_frame_fresh_beat, DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Live,
            "a static window is not a frozen one"
        );
        // The same shape with the keepalive gone IS a stall: nothing at all is arriving.
        let silent = Liveness {
            last_heartbeat_at: Some(90.0),
            ..stale_frame_fresh_beat
        };
        assert_eq!(verdict(silent, DEFAULT_THRESHOLD_SECONDS), StreamVerdict::Stalled);
        // And with idle-skip OFF, that same stale frame is not excused by anything.
        let active = Liveness {
            idle_skip_active: false,
            last_heartbeat_at: None,
            ..stale_frame_fresh_beat
        };
        assert_eq!(verdict(active, DEFAULT_THRESHOLD_SECONDS), StreamVerdict::Stalled);
    }

    #[test]
    fn an_active_stream_takes_the_newer_of_the_two_signals() {
        let beat_is_newer = Liveness {
            now: 100.0,
            last_frame_at: Some(90.0),
            last_heartbeat_at: Some(99.0),
            connected: true,
            idle_skip_active: false,
        };
        assert_eq!(
            verdict(beat_is_newer, DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Live
        );
        let frame_is_newer = Liveness {
            last_frame_at: Some(99.5),
            last_heartbeat_at: Some(80.0),
            ..beat_is_newer
        };
        assert_eq!(
            verdict(frame_is_newer, DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Live
        );
    }

    #[test]
    fn a_disconnected_or_silent_stream_is_never_stalled() {
        let disconnected = Liveness {
            connected: false,
            ..streaming(600.0)
        };
        assert_eq!(
            verdict(disconnected, DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::NotConnected,
            "the disconnect path owns recovery"
        );
        let nothing_yet = Liveness {
            now: 100.0,
            last_frame_at: None,
            last_heartbeat_at: None,
            connected: true,
            idle_skip_active: false,
        };
        assert_eq!(
            verdict(nothing_yet, DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Unknown
        );
        // Idle-skip with no keepalive yet is the same "nothing to judge", not a stall.
        let idle_no_beat = Liveness {
            last_frame_at: Some(99.0),
            idle_skip_active: true,
            ..nothing_yet
        };
        assert_eq!(
            verdict(idle_no_beat, DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Unknown
        );
    }

    #[test]
    fn an_unusable_stamp_cannot_produce_a_stall() {
        // NaN compares unordered, so `now - signal >= threshold` is false and the verdict is live
        // rather than a scrim raised on arithmetic nobody can read.
        let broken = Liveness {
            now: f64::NAN,
            ..streaming(0.5)
        };
        assert_eq!(verdict(broken, DEFAULT_THRESHOLD_SECONDS), StreamVerdict::Live);
        // And one bad stamp beside a good one does not discard the good one.
        let half_broken = Liveness {
            now: 100.0,
            last_frame_at: Some(f64::NAN),
            last_heartbeat_at: Some(99.9),
            connected: true,
            idle_skip_active: false,
        };
        assert_eq!(
            verdict(half_broken, DEFAULT_THRESHOLD_SECONDS),
            StreamVerdict::Live
        );
    }
}
