/// Pure send-path viability mapping for the shared client UDP flow (wifi-flap hardening) —
/// the send-side sibling of ``UDPReceiveLoopPolicy``.
///
/// While the WireGuard/utun path is down the media `NWConnection` sits in `.waiting` and
/// `Network.framework` queues every datagram in-process with the completion deferred
/// indefinitely — so the client's PERIODIC producers (the 20 Hz NetworkStats reports, the 5 s
/// keepalive) must skip their fire while the path is not viable. Sparse best-effort sends
/// (user input, hello) are NOT gated — the user expects them to ride the first viable window.
///
/// The mapping is a pure function of the connection state so it is unit-testable without a
/// socket (the flow's `stateUpdateHandler` feeds it and stores the returned value; `nil`
/// keeps the previous reading — bring-up states carry no path verdict of their own).
public enum UDPSendPathPolicy {
    /// The `NWConnection.State` kinds, mirrored without the Network dependency so the
    /// mapping stays testable headlessly (same convention as ``UDPReceiveLoopPolicy``
    /// taking a plain `connectionIsAlive` Bool).
    public enum StateKind: Sendable {
        case setup
        case preparing
        case ready
        case waiting
        case failed
        case cancelled
    }

    /// The new send-path viability after observing `state`, or `nil` to keep the previous
    /// reading. `.ready` restores viability; `.waiting` (dead path, sends would buffer
    /// in-process) and `.failed`/`.cancelled` (dead connection) revoke it; the bring-up
    /// states (`.setup`/`.preparing`) leave it unchanged — initial viability is optimistic
    /// (true) so bring-up sends behave exactly as today.
    public static func viability(after state: StateKind) -> Bool? {
        switch state {
        case .ready:
            true
        case .waiting,
             .failed,
             .cancelled:
            false
        case .setup,
             .preparing:
            nil
        }
    }
}
