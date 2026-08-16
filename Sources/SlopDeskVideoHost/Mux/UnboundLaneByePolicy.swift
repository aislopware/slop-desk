import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

// The Swift face of `rust/slopdesk-video`'s `mux_flow` bye policy, reached through the `mux_host`
// door: no sockets, no clock — the transport passes `now` in — exactly the "decider beside the
// actor" discipline of ``VideoMuxRouter`` / ``IdleReapDecider``.

/// Decides whether a datagram the mux transport is DROPPING for an unbound lane (unadmitted or
/// retired, non-bootstrap) proves the SENDER still believes a live session exists — in which case
/// the host answers with a `bye` on the arrival flow so the client learns its session is gone and
/// can rebuild (fresh hello, fresh lane).
///
/// ## The wedge this fixes
/// A videohostd RESTART forgets every admitted lane, but a client mid-session has no way to know:
/// UDP gives it no signal, its state machine stays `.streaming` forever, and its keepalive/input
/// datagrams land here. Dropping them silently would freeze the pane with dead input until the app
/// relaunched. Answering those datagrams with a `bye` closes the loop: the client's existing `bye`
/// handling tears the dead session down and re-hellos within one keepalive interval.
///
/// ## Why the payload crosses whole
/// The answer for a `.control` datagram is a fact about which MESSAGE it carries, and that decode
/// is the wire's — already on the far side, already golden-pinned. Peeking at it here to hand the
/// door a verdict would put a second reader of the control grammar in front of the one that owns
/// it; handing over the bytes keeps exactly one. Which messages count, and which are session-LESS
/// discovery that must never be answered, is stated in `mux_flow.rs`.
public enum UnboundLaneByeDecider {
    /// Whether the dropped datagram implies the sender holds a live-session belief worth correcting.
    public static func warrantsBye(channel: VideoChannel, payload: Data) -> Bool {
        payload.withUnsafeBytes { bytes in
            slopdesk_mux_warrants_bye(channel.rawValue, bytes.baseAddress, bytes.count)
        }
    }
}

/// Bounds how often the transport actually SENDS an unbound-lane `bye`: at most one per
/// `minInterval` per channelID, over at most `capacity` tracked channelIDs. A wedged client emits
/// a keepalive every ~5 s plus input bursts on interaction — one bye per second per lane is ample
/// to unwedge it, and the capacity bound keeps a hostile datagram source from growing the map.
///
/// A handle for the map it holds, and because the transport owns it under its mux lock the class
/// needs no locking of its own. `@unchecked Sendable` is sound for exactly that reason.
public final class UnboundByeRateLimiter: @unchecked Sendable {
    /// The far-side limiter, which owns the per-lane send times.
    private let handle: OpaquePointer?
    /// Minimum spacing between byes for the SAME channelID (seconds).
    public let minInterval: TimeInterval
    /// Maximum tracked channelIDs. When full, stale entries (≥ `minInterval` old) are pruned;
    /// if every entry is still fresh the new channelID is DENIED (fail-quiet, never unbounded).
    public let capacity: Int

    public init(minInterval: TimeInterval = 1.0, capacity: Int = 256) {
        self.minInterval = minInterval
        self.capacity = max(1, capacity)
        handle = slopdesk_mux_bye_limiter_new(minInterval, self.capacity)
    }

    deinit { slopdesk_mux_bye_limiter_free(handle) }

    /// Query+mutator (acted-on decision): whether a bye may be sent for `channelID` at `now`.
    /// Records the send time when it returns `true`.
    public func admit(channelID: UInt32, now: TimeInterval) -> Bool {
        slopdesk_mux_bye_limiter_admit(handle, channelID, now)
    }
}
