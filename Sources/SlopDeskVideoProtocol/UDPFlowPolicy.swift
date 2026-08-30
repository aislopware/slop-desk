import CSlopDeskFFI
import Foundation

// The Swift face of `rust/slopdesk-video`'s `mux_flow` receive-loop policy, reached through the
// `mux_client` door. ONE copy, in the module both ends already import: the re-arm rule used to be
// written out twice — once in the host module, once in the client's, each copy commented with the
// fact that the other existed — and a contract kept by reading is not kept.
//
// Both loops that ASK it are Rust now — `slopdesk-videohostd`'s `mux_transport` and
// `slopdesk-videolink`'s reader threads — so this face's remaining job is to pin the two doors
// against `golden/golden_vectors.json`, which is what a face is for. `UDPSendPathPolicy` used to
// sit below it and does not: it mapped an `NWConnection.State`, and there is no longer one to map.

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
