import Foundation

// MARK: - Remote-GUI pane frozen-stream detection (C7 improvement 2)

/// The PURE decision behind the remote-GUI pane's frozen-stream detector: given the last frame + last
/// heartbeat timestamps, whether the session is nominally connected, and whether idle-skip is active, decide
/// whether the stream has STALLED (frames stopped arriving while the session is still alive) so the pane can
/// overlay a "reconnecting…" scrim + trigger the existing reconnect path. No timers / session here — the
/// app-target session feeds it timestamps and acts on the verdict; the policy is unit-tested headlessly.
///
/// THE IDLE-SKIP TRAP this is built around: idle-skip means the host sends NO frames by design when the
/// remote window is static, so keying a stall off "no frames for N seconds" would false-fire on a healthy
/// idle window. The host's keepalive/heartbeat KEEPS flowing under idle-skip — so during idle-skip liveness
/// is judged by the HEARTBEAT alone (a stale last-frame is expected). When idle-skip is inactive, a fresh
/// frame is itself strong liveness, so the newest of frame/heartbeat counts.
public struct StreamStallPolicy: Sendable, Equatable {
    /// How long (seconds) with NO liveness signal — no frame AND no heartbeat (idle-skip: no heartbeat) —
    /// before a connected stream is declared stalled. Default 3s: long enough to ride out a normal
    /// keepalive gap + a brief loss episode, short enough to react before the user gives up.
    public var threshold: TimeInterval

    public init(threshold: TimeInterval = 3.0) {
        self.threshold = threshold
    }

    /// The timestamped liveness inputs (all times share one monotonic clock, e.g. `Date`/uptime seconds).
    public struct Inputs: Equatable, Sendable {
        /// The current time.
        public var now: TimeInterval
        /// When the most recent decoded frame arrived (`nil` — none yet).
        public var lastFrameAt: TimeInterval?
        /// When the most recent host keepalive/heartbeat arrived (`nil` — none yet). The idle-skip-safe signal.
        public var lastHeartbeatAt: TimeInterval?
        /// Whether the session is nominally connected (a `.bye` / hard disconnect is handled by its own path;
        /// a stall is the "connected but frozen" case).
        public var connected: Bool
        /// Whether the host is currently idle-skipping (suppressing frames because the window is static). When
        /// true, a stale last-frame is EXPECTED — liveness is judged by the heartbeat alone.
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
        /// Connected, but no liveness signal for ≥ ``threshold`` — the stream is FROZEN. Show the scrim +
        /// trigger reconnect.
        case stalled
        /// Not connected — the disconnect path owns recovery; the stall scrim must NOT fire here.
        case notConnected
        /// No liveness signal has arrived yet (a just-opened stream) — nothing to judge; no scrim.
        case unknown
    }

    /// Decides the verdict. During idle-skip only the heartbeat is trusted (frames are suppressed by design);
    /// otherwise the NEWEST of frame/heartbeat is the liveness signal. Stalled the instant the gap reaches
    /// ``threshold`` (`>=`), and only while connected.
    public func evaluate(_ inputs: Inputs) -> Verdict {
        guard inputs.connected else { return .notConnected }
        let signal: TimeInterval? = inputs.idleSkipActive
            ? inputs.lastHeartbeatAt
            : newest(inputs.lastFrameAt, inputs.lastHeartbeatAt)
        guard let signal else { return .unknown }
        return (inputs.now - signal) >= threshold ? .stalled : .live
    }

    /// Convenience boolean: is the stream stalled (the scrim + reconnect trigger)?
    public func isStalled(_ inputs: Inputs) -> Bool { evaluate(inputs) == .stalled }

    /// The later of two optional timestamps (`nil` when both are absent).
    private func newest(_ a: TimeInterval?, _ b: TimeInterval?) -> TimeInterval? {
        switch (a, b) {
        case let (x?, y?): Swift.max(x, y)
        case let (x?, nil): x
        case let (nil, y?): y
        case (nil, nil): nil
        }
    }
}
