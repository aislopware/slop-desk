import CSlopDeskFFI
import Foundation

// The Swift face of `rust/slopdesk-video`'s `mux_flow` loop policies, reached through the
// `mux_client` door. ONE copy, in the module both ends already import: the re-arm rule used to be
// written out twice — once in the host module, once in the client's, each copy commented with the
// fact that the other existed — and a contract kept by reading is not kept. No Network import here,
// so the mapping stays testable headlessly on either side.

/// Re-arm decision + backoff for a UDP `receiveMessage` loop (BUG-L).
///
/// The loop must keep itself armed across TRANSIENT per-datagram errors (an ICMP port-unreachable
/// surfaces as a receive error even while the connection stays `.ready`) and stop ONLY when the
/// connection is genuinely dead — the liveness signal comes from the connection's
/// `stateUpdateHandler`, never from the per-receive error.
public enum UDPReceiveLoopPolicy {
    /// Re-arm the receive loop iff the connection is still alive. A per-datagram error does NOT
    /// stop the loop; only a dead connection does.
    public static func shouldRearm(connectionIsAlive: Bool) -> Bool {
        slopdesk_mux_should_rearm(connectionIsAlive)
    }

    /// The delay before re-arming after an ERROR-bearing completion, given how many errors have
    /// arrived back-to-back without an intervening good datagram (F3). Re-arming a SUSTAINED error
    /// (an ICMP port-unreachable delivered as ECONNREFUSED on every `receiveMessage` while the
    /// connection stays `.ready`) with ZERO delay was a 100% CPU busy-loop; the delay doubles per
    /// consecutive error from the base, capped. The loop RESETS the count on the first error-free
    /// datagram, so 0 re-arms immediately — the hot path is never delayed.
    ///
    /// - Parameter consecutiveErrors: back-to-back errors INCLUDING the one just observed.
    public static func nextBackoff(consecutiveErrors: Int) -> TimeInterval {
        slopdesk_mux_receive_backoff(UInt32(clamping: consecutiveErrors))
    }
}

/// Send-path viability mapping for the shared client UDP flow (wifi-flap hardening).
///
/// While the WireGuard/utun path is down the media `NWConnection` sits in `.waiting` and
/// `Network.framework` queues every datagram in-process with the completion deferred indefinitely —
/// so the client's PERIODIC producers (the 20 Hz NetworkStats reports, the 5 s keepalive) must skip
/// their fire while the path is not viable. Sparse best-effort sends (user input, hello) are NOT
/// gated: the user expects them to ride the first viable window.
public enum UDPSendPathPolicy {
    /// The `NWConnection.State` kinds, mirrored without the Network dependency so the mapping stays
    /// testable headlessly.
    public enum StateKind: Sendable {
        case setup
        case preparing
        case ready
        case waiting
        case failed
        case cancelled

        /// The code this state crosses as.
        var code: UInt32 {
            switch self {
            case .setup: SLOPDESK_CONN_SETUP
            case .preparing: SLOPDESK_CONN_PREPARING
            case .ready: SLOPDESK_CONN_READY
            case .waiting: SLOPDESK_CONN_WAITING
            case .failed: SLOPDESK_CONN_FAILED
            case .cancelled: SLOPDESK_CONN_CANCELLED
            }
        }
    }

    /// The new send-path viability after observing `state`, or `nil` to keep the previous reading —
    /// the bring-up states carry no verdict of their own, and "unchanged" is not a viability.
    /// Initial viability is optimistic (true) so sends during bring-up are not held back.
    public static func viability(after state: StateKind) -> Bool? {
        var viable = false
        guard slopdesk_mux_send_path_viability(state.code, &viable) else { return nil }
        return viable
    }
}
