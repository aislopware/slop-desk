import Foundation

/// Pure idle-timeout reap decision for a UDP video flow/lane (CONCURRENCY-HOST-1
/// crash-without-bye + its UDP-mux analogue). No socket, no wall-clock — the caller stamps
/// `now` and acts on the returned ids, exactly like ``LTREscalationTracker`` /
/// ``StaticIDRDecider`` / ``InputMotionCoalescer`` ("decider beside the actor"). Side
/// effects (the `DispatchSourceTimer`, `resetClientFlow`, `session.stop`) stay thin around it.
///
/// ## SAFETY — the never-reap-without-keepalive rule (RFC 7675 §5.1 / RFC 9000 §10.1.2 /
/// WireGuard / mosh)
/// A flow is reaped ONLY once it has PROVEN it speaks keepalive (`sawKeepalive == true`).
/// A flow that has NEVER delivered a keepalive (gate-OFF client, legacy client) is NEVER
/// eligible — ``reap(now:)`` skips it unconditionally. This single rule is what makes a
/// one-sided gate safe: a host with the gate ON but a client with it OFF degrades to today's
/// exact no-reap behaviour, because no flow ever proves keepalive. It is a property of the
/// per-flow record, not of the timer.
///
/// `sawKeepalive` is **sticky**: once true it never resets to false for the life of that flow
/// record — a live client that sends one keepalive then goes truly silent because it crashed is
/// exactly the case we want to reap. Identity is `FlowID` (``SinglePin`` for the single-pin
/// transport, the `UInt32` channelID for mux), so a reconnect under a FRESH channelID gets a
/// fresh record (`sawKeepalive == false` again — see ``forget(id:)``).
public struct IdleReapDecider<FlowID: Hashable & Sendable>: Sendable {
    public struct Record: Sendable, Equatable {
        /// Host time (seconds, monotonic) of the most recent inbound datagram of ANY kind.
        public var lastInbound: TimeInterval
        /// Whether this flow has EVER delivered a keepalive control datagram. Sticky-true.
        public var sawKeepalive: Bool
        public init(lastInbound: TimeInterval, sawKeepalive: Bool) {
            self.lastInbound = lastInbound
            self.sawKeepalive = sawKeepalive
        }
    }

    private var flows: [FlowID: Record] = [:]
    /// Idle threshold in seconds (``KeepaliveTiming/idleTimeout``, 30 s).
    public let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval) { self.idleTimeout = idleTimeout }

    /// Stamp an inbound datagram for `id` at host time `now`. `isKeepalive` latches
    /// `sawKeepalive` STICKY (never clears) so a later true silence is reapable. Any inbound —
    /// keepalive OR media/input — refreshes `lastInbound` (a client actively typing is obviously
    /// alive even between keepalives). A first-ever inbound creates the record.
    public mutating func noteInbound(id: FlowID, now: TimeInterval, isKeepalive: Bool) {
        var rec = flows[id] ?? Record(lastInbound: now, sawKeepalive: false)
        rec.lastInbound = now
        if isKeepalive { rec.sawKeepalive = true }
        flows[id] = rec
    }

    /// The ids to reap NOW: those that PROVED keepalive AND have been silent ≥ `idleTimeout`.
    /// PURE — does not mutate; the caller tears down each id then calls ``forget(id:)`` so a
    /// reaped flow is not re-reported on the next tick.
    public func reap(now: TimeInterval) -> [FlowID] {
        flows.compactMap { id, rec in
            (rec.sawKeepalive && now - rec.lastInbound >= idleTimeout) ? id : nil
        }
    }

    /// Drop a flow's record (after reaping, or on a clean `bye` / explicit retire) so it is
    /// neither re-reported nor leaked, and a reused id starts a FRESH record. Idempotent.
    public mutating func forget(id: FlowID) { flows.removeValue(forKey: id) }

    /// Test / introspection: the current record for `id`, if any.
    public func record(_ id: FlowID) -> Record? { flows[id] }
}

/// The single-flow identity for the single-pin ``NWVideoDatagramTransport`` (exactly one
/// client at a time). A 1-element type so ``IdleReapDecider`` can key the one flow.
public struct SinglePin: Hashable, Sendable {
    public static let pin = SinglePin()
    public init() {}
}
