import CSlopDeskFFI
import Foundation

// MARK: - Remote-GUI pane frozen-stream detection (C7 improvement 2)

/// The PURE decision behind the remote-GUI pane's frozen-stream detector, as the Swift face of
/// `rust/slopdesk-video`'s `stream_stall`, reached through `rust/slopdesk-ffi`'s `video_policy` door.
///
/// Given the last frame + last heartbeat timestamps, whether the session is nominally connected, and
/// whether idle-skip is active, it decides whether the stream has STALLED (frames stopped arriving
/// while the session is still alive) so the pane can overlay a "reconnecting…" scrim + trigger the
/// existing reconnect path. No timers / session here — the app-target session feeds it timestamps and
/// acts on the verdict.
///
/// THE IDLE-SKIP TRAP this is built around: idle-skip means the host sends NO frames by design when
/// the remote window is static, so keying a stall off "no frames for N seconds" would false-fire on a
/// healthy idle window. The host's keepalive/heartbeat KEEPS flowing under idle-skip — so during
/// idle-skip liveness is judged by the HEARTBEAT alone (a stale last-frame is expected). When
/// idle-skip is inactive, a fresh frame is itself strong liveness, so the newest of frame/heartbeat
/// counts. That branch, the newest-of-two and the inclusive `>=` at the threshold are all on the far
/// side; this file carries the vocabulary and the `nil`-to-flag translation.
public struct StreamStallPolicy: Sendable, Equatable {
    /// How long (seconds) with NO liveness signal — no frame AND no heartbeat (idle-skip: no
    /// heartbeat) — before a connected stream is declared stalled. Default 3s: long enough to ride
    /// out a normal keepalive gap + a brief loss episode, short enough to react before the user
    /// gives up.
    public var threshold: TimeInterval

    /// How long without a liveness signal the stream is called frozen, from the door — the same
    /// record the keepalive cadences come from, since the threshold is sized against them.
    public static var defaultThreshold: TimeInterval { slopdesk_keepalive_timing().stall_threshold }

    public init(threshold: TimeInterval = Self.defaultThreshold) {
        self.threshold = threshold
    }

    /// The timestamped liveness inputs (all times share one monotonic clock, e.g. `Date`/uptime
    /// seconds).
    public struct Inputs: Equatable, Sendable {
        /// The current time.
        public var now: TimeInterval
        /// When the most recent decoded frame arrived (`nil` — none yet).
        public var lastFrameAt: TimeInterval?
        /// When the most recent host keepalive/heartbeat arrived (`nil` — none yet). The
        /// idle-skip-safe signal.
        public var lastHeartbeatAt: TimeInterval?
        /// Whether the session is nominally connected (a `.bye` / hard disconnect is handled by its
        /// own path; a stall is the "connected but frozen" case).
        public var connected: Bool
        /// Whether the host is currently idle-skipping (suppressing frames because the window is
        /// static). When true, a stale last-frame is EXPECTED — liveness is judged by the heartbeat
        /// alone.
        public var idleSkipActive: Bool

        public init(
            now: TimeInterval,
            lastFrameAt: TimeInterval?,
            lastHeartbeatAt: TimeInterval?,
            connected: Bool,
            idleSkipActive: Bool,
        ) {
            self.now = now
            self.lastFrameAt = lastFrameAt
            self.lastHeartbeatAt = lastHeartbeatAt
            self.connected = connected
            self.idleSkipActive = idleSkipActive
        }
    }

    /// The stream-liveness verdict.
    public enum Verdict: Equatable, Sendable {
        /// A liveness signal arrived within ``threshold`` — the stream is flowing (or healthily idle).
        case live
        /// Connected, but no liveness signal for ≥ ``threshold`` — the stream is FROZEN. Show the
        /// scrim + trigger reconnect.
        case stalled
        /// Not connected — the disconnect path owns recovery; the stall scrim must NOT fire here.
        case notConnected
        /// No liveness signal has arrived yet (a just-opened stream) — nothing to judge; no scrim.
        case unknown

        /// This verdict as the door's code — the other direction of the table ``evaluate(_:)``
        /// reads, for the doors that CONSUME a verdict (the reconnecting-scrim latch).
        public var code: UInt32 {
            switch self {
            case .live: UInt32(SLOPDESK_STREAM_LIVE)
            case .stalled: UInt32(SLOPDESK_STREAM_STALLED)
            case .notConnected: UInt32(SLOPDESK_STREAM_NOT_CONNECTED)
            case .unknown: UInt32(SLOPDESK_STREAM_UNKNOWN)
            }
        }
    }

    /// Decides the verdict for `inputs`.
    ///
    /// Each optional stamp crosses as a value plus a presence flag rather than a sentinel time,
    /// because "no frame has EVER arrived" and "the last frame arrived at time zero" are different
    /// states and only one of them can be a stall.
    public func evaluate(_ inputs: Inputs) -> Verdict {
        let liveness = SlopDeskLiveness(
            now: inputs.now,
            last_frame_at: inputs.lastFrameAt ?? 0,
            last_heartbeat_at: inputs.lastHeartbeatAt ?? 0,
            threshold: threshold,
            has_frame: inputs.lastFrameAt != nil,
            has_heartbeat: inputs.lastHeartbeatAt != nil,
            connected: inputs.connected,
            idle_skip_active: inputs.idleSkipActive,
        )
        switch slopdesk_stream_stall_verdict(liveness) {
        case UInt32(SLOPDESK_STREAM_STALLED): return .stalled
        case UInt32(SLOPDESK_STREAM_NOT_CONNECTED): return .notConnected
        case UInt32(SLOPDESK_STREAM_UNKNOWN): return .unknown
        default: return .live
        }
    }

    /// Convenience boolean: is the stream stalled (the scrim + reconnect trigger)?
    public func isStalled(_ inputs: Inputs) -> Bool { evaluate(inputs) == .stalled }
}
