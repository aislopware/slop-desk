import Foundation

// C6 BUG A (2026-07-03): WindowServer can TERMINATE the virtual display out from under the daemon
// (sleep/wake, GPU reset, fast-user-switch, display reconfig). Before this fix the daemon only
// restored the parked window FRAMES — every live session whose window was parked on the VD kept
// its SCStream pointed at the dead display: a silent client freeze with no bye and no reconnect.
// These PURE policies (no AX, no SCK, no CG IPC — headlessly unit-tested) decide the recovery; the
// side effects (bye send, session stop, window restore, VD re-create) stay thin in
// `aislopdesk-videohostd`.

/// The "which sessions must be disconnected" decision for a VD termination. A session is affected
/// iff its lane PARKED a window on the dead VD (the parking ledger's channel bindings) AND it is
/// still a live lane (the registry's registered-sink set). Each affected lane gets a host→client
/// `.bye` (so the client's existing disconnect/reconnect UI engages — the client re-dials and the
/// fresh mint re-negotiates onto post-termination capture) followed by a session stop. Unparked
/// (1× real-display) sessions are untouched; parked channels with no live lane are covered by the
/// window restore alone.
public enum VirtualDisplayTerminationPolicy {
    /// The channelIDs to bye + stop, sorted for a deterministic teardown order.
    public static func channelsToDisconnect(
        parkedChannels: Set<UInt32>,
        liveChannels: Set<UInt32>,
    ) -> [UInt32] {
        parkedChannels.intersection(liveChannels).sorted()
    }
}

/// The lazy VD re-create throttle: after a termination, the NEXT park request may re-create the VD
/// (`VirtualDisplay.create` on the SAME held instance — its state was cleared by the termination
/// handler), but at most ONE attempt at a time (create blocks up to ~10 s on WindowServer IPC) and
/// never more often than `cooldown` — a host whose WindowServer keeps killing VDs must degrade to
/// 1× capture, not stall every mint for 10 s.
public enum VirtualDisplayRecreatePolicy {
    /// Default seconds between re-create attempts.
    public static let defaultCooldown: TimeInterval = 30

    /// Whether a re-create attempt may start now. An in-flight attempt always blocks; otherwise the
    /// first attempt is free and later ones must be `cooldown` past the previous attempt's START
    /// (stamped at begin — a hung create must not re-arm early).
    public static func shouldAttempt(
        now: TimeInterval,
        lastAttempt: TimeInterval?,
        cooldown: TimeInterval = defaultCooldown,
        attemptInFlight: Bool,
    ) -> Bool {
        if attemptInFlight { return false }
        guard let lastAttempt else { return true }
        return now - lastAttempt >= cooldown
    }
}

/// The lock-protected gate composing ``VirtualDisplayRecreatePolicy`` for the daemon's concurrent
/// mint lanes: `begin(now:)` admits exactly one in-flight re-create (stamping the cooldown anchor);
/// `end()` releases the flight. Losers fall back to 1× capture for their mint and retry the VD on
/// a later hello. Pure bookkeeping (no CG) — headlessly unit-tested.
public final class VirtualDisplayRecreateGate: @unchecked Sendable {
    private let lock = NSLock()
    private let cooldown: TimeInterval
    private var inFlight = false
    private var lastAttempt: TimeInterval?

    public init(cooldown: TimeInterval = VirtualDisplayRecreatePolicy.defaultCooldown) {
        self.cooldown = cooldown
    }

    /// Admits (and stamps) a re-create attempt, or refuses (in-flight / inside the cooldown).
    public func begin(now: TimeInterval) -> Bool {
        lock.withLock {
            guard VirtualDisplayRecreatePolicy.shouldAttempt(
                now: now,
                lastAttempt: lastAttempt,
                cooldown: cooldown,
                attemptInFlight: inFlight,
            ) else { return false }
            inFlight = true
            lastAttempt = now
            return true
        }
    }

    /// Releases the in-flight attempt (success or failure — the cooldown stamped at `begin` still
    /// throttles the next one).
    public func end() {
        lock.withLock { inFlight = false }
    }
}
