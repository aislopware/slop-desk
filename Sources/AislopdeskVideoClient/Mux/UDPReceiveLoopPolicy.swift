#if canImport(Network)
import Foundation

/// Pure re-arm decision for a UDP `receiveMessage` loop (BUG-L) — the client-side mirror
/// of the host's `AislopdeskVideoHost.UDPReceiveLoopPolicy`.
///
/// The receive loop must keep itself armed across TRANSIENT per-datagram errors (an ICMP
/// port-unreachable surfaces as a receive error even while the connection stays `.ready`)
/// and stop ONLY when the connection is genuinely dead. The liveness signal comes from the
/// connection's `stateUpdateHandler` (`.failed`/`.cancelled`), not from the per-receive
/// error — so the decision is purely "is the connection still alive?", which is
/// unit-testable without a socket. (Client + host live in separate modules and each owns
/// an identical copy; the behaviour contract is the agreement, not a shared Swift type.)
public enum UDPReceiveLoopPolicy {
    /// Re-arm the receive loop iff the connection is still alive. A per-datagram error
    /// does NOT stop the loop; only a dead connection does.
    public static func shouldRearm(connectionIsAlive: Bool) -> Bool {
        connectionIsAlive
    }

    /// Smallest re-arm delay after the first consecutive error (5 ms).
    static let baseBackoff: TimeInterval = 0.005
    /// Capped re-arm delay so a long ECONNREFUSED storm settles at ~250 ms, not a spin.
    static let maxBackoff: TimeInterval = 0.25

    /// The delay before re-arming the UDP `receiveMessage` loop after an ERROR-bearing
    /// completion, given how many errors have arrived back-to-back without an
    /// intervening good datagram (F3). The BUG-L fix re-arms on a transient error, but a
    /// SUSTAINED error (an ICMP port-unreachable delivered as ECONNREFUSED on every
    /// `receiveMessage` while the connection stays `.ready`) re-armed with ZERO delay →
    /// 100% CPU busy-loop. Exponential growth from `baseBackoff` (×2 per consecutive
    /// error), capped at `maxBackoff`. The loop RESETS `consecutiveErrors` to 0 on the
    /// first error-free datagram, so `nextBackoff(0)` is 0 (immediate re-arm — the normal
    /// hot path is never delayed). Pure + unit-testable (no socket / clock).
    ///
    /// - Parameter consecutiveErrors: number of back-to-back errors INCLUDING the one
    ///   just observed (0 ⇒ no error, immediate re-arm).
    public static func nextBackoff(consecutiveErrors: Int) -> TimeInterval {
        guard consecutiveErrors > 0 else { return 0 }
        // baseBackoff · 2^(n-1), clamped to maxBackoff. Compute the multiplier without
        // overflow for large n by capping the shift exponent.
        let exponent = min(consecutiveErrors - 1, 16) // 2^16 · 5ms ≫ 250ms cap
        let scaled = baseBackoff * Double(1 << exponent)
        return min(scaled, maxBackoff)
    }
}
#endif
