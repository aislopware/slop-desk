import Foundation
import SlopDeskVideoProtocol

// PURE unbound-lane bye policy (the reconnect-wedge fix, 2026-07-03). No sockets, no clock —
// the transport passes `now` in — exactly the "decider beside the actor" discipline of
// ``VideoMuxRouter`` / ``IdleReapDecider``, so both halves are unit-testable headlessly.

/// Decides whether a datagram the mux transport is DROPPING for an unbound lane (unadmitted or
/// retired, non-bootstrap) proves the SENDER still believes a live session exists — in which case
/// the host answers with a `bye` on the arrival flow so the client learns its session is gone and
/// can rebuild (fresh hello, fresh lane).
///
/// ## The wedge this fixes
/// A videohostd RESTART forgets every admitted lane, but a client mid-session has no way to know:
/// UDP gives it no signal, its state machine stays `.streaming` forever, and its keepalive/input
/// datagrams land here and used to be dropped SILENTLY — a frozen pane with dead input until the
/// app relaunched. Answering those datagrams with a `bye` closes the loop: the client's existing
/// `bye` handling tears the dead session down and re-hellos within one keepalive interval.
///
/// ## What warrants a bye (and what must NOT)
/// - `.input` / `.recovery` datagrams — only ever sent by a client that believes it is streaming.
/// - `.control` `keepalive` / `resizeRequest` / `focusWindow` — likewise in-session-only messages.
/// - A `hello` NEVER reaches this decider (it bootstraps a mint), and `listWindows` /
///   `listSystemDialogs` are session-LESS discovery (answered by the daemon) — no bye.
/// - A stray `bye` gets no reply (nothing to end; replying could ping-pong with a confused peer).
/// - Host→client-only channels/messages arriving inbound are corrupt/hostile — drop, no reply
///   (validate-then-drop; never reflect at garbage).
public enum UnboundLaneByeDecider {
    /// Whether the dropped datagram implies the sender holds a live-session belief worth correcting.
    public static func warrantsBye(channel: VideoChannel, payload: Data) -> Bool {
        switch channel {
        case .input,
             .recovery:
            // Client→host in-session lanes: the sender is unquestionably mid-session.
            return true
        case .control:
            guard let message = try? VideoControlMessage.decode(payload) else { return false }
            switch message {
            case .keepalive,
                 .resizeRequest,
                 .focusWindow:
                return true
            case .hello,
                 .helloAck,
                 .bye,
                 .resizeAck,
                 .streamCadence,
                 .scrollOffset,
                 .contentMask,
                 .displayMax,
                 .listWindows,
                 .windowList,
                 .listSystemDialogs,
                 .systemDialogList,
                 .windowFeedSubscribe,
                 .windowFeedSnapshot,
                 .windowFeedCurrent:
                // `windowFeedSubscribe` is session-LESS discovery like the list requests (answered by
                // the daemon — it must bootstrap, never bye); the snapshot/current replies are
                // host→client and never arrive inbound legitimately.
                return false
            }
        case .video,
             .geometry,
             .cursor:
            // Host→client-only payloads arriving inbound: corrupt/hostile — never reflect.
            return false
        }
    }
}

/// Bounds how often the transport actually SENDS an unbound-lane `bye`: at most one per
/// `minInterval` per channelID, over at most `capacity` tracked channelIDs. A wedged client emits
/// a keepalive every ~5 s plus input bursts on interaction — one bye per second per lane is ample
/// to unwedge it, and the capacity bound keeps a hostile datagram source from growing the map.
/// Pure value type (caller passes `now`); owned by the transport under its mux lock.
public struct UnboundByeRateLimiter: Sendable {
    /// Last bye send time per channelID (monotonic seconds).
    private var lastSent: [UInt32: TimeInterval] = [:]
    /// Minimum spacing between byes for the SAME channelID (seconds).
    public let minInterval: TimeInterval
    /// Maximum tracked channelIDs. When full, stale entries (≥ `minInterval` old) are pruned;
    /// if every entry is still fresh the new channelID is DENIED (fail-quiet, never unbounded).
    public let capacity: Int

    public init(minInterval: TimeInterval = 1.0, capacity: Int = 256) {
        self.minInterval = minInterval
        self.capacity = max(1, capacity)
    }

    /// Query+mutator (acted-on decision): whether a bye may be sent for `channelID` at `now`.
    /// Records the send time when it returns `true`.
    public mutating func admit(channelID: UInt32, now: TimeInterval) -> Bool {
        if let last = lastSent[channelID] {
            guard now - last >= minInterval else { return false }
            lastSent[channelID] = now
            return true
        }
        if lastSent.count >= capacity {
            lastSent = lastSent.filter { now - $0.value < minInterval }
            guard lastSent.count < capacity else { return false }
        }
        lastSent[channelID] = now
        return true
    }
}
