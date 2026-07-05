import SlopDeskAgentDetect

// `slopdesk watch:claude <id>` (ui-shell E20, WI-8) — the PURE exit-code state machine.
//
// `watch:claude <id>` blocks until the named Claude session reaches an at-rest state, then exits.
// Spec (reference__cli.md §CLI): exit `0` = idle or session closed, `4` = session id never seen,
// `9` = timeout. Claude-only — there is no `watch:codex`/`watch:opencode` (carry-over exclusion §4).
//
// The CLI polls the running app's `agent-status` method (``ClientControlProtocol/Method/agentStatus``),
// which answers `{seen, status?}`: `seen:false` = the id resolves to NO pane (→ exit 4); `seen:true` with
// NO `status` = the pane EXISTS but its agent has not reported yet (the startup window → keep polling);
// `seen:true` + a ``ClaudeStatus`` rawValue = the rolled-up agent status. This type turns each polled observation —
// plus whether the id has EVER been seen across polls and whether the deadline has elapsed — into a
// ``Step``: finish with an exit code, or keep polling. The poll loop itself (sleep + socket I/O + the
// clock) lives in `main.swift` (compiled-only — it does I/O and sleeps, so it is never instantiated in
// a unit test, hang-safety rule); ALL exit-code decisions are HERE and exhaustively unit-tested.

public enum WatchClaudeOutcome {
    /// The three terminal exit codes (see `reference__cli.md`).
    public enum Exit: Int32, Equatable, Sendable {
        /// The session reached an at-rest state — idle, done, or closed. Exit code `0`.
        case settled = 0
        /// The session id was never seen by the running app. Exit code `4`.
        case neverSeen = 4
        /// The deadline elapsed while the session was still active. Exit code `9`.
        case timedOut = 9
    }

    /// One poll's observation of the `agent-status` reply.
    public enum Observation: Equatable, Sendable {
        /// `seen:true` with the rolled-up status.
        case status(ClaudeStatus)
        /// `seen:true` but NO status token — the pane EXISTS but its agent has not reported a status yet
        /// (the agent-startup window). Distinct from a settled `.none`: still starting, so keep polling.
        case seenNoStatus
        /// `seen:false` — the id does not resolve to any pane the running app knows.
        case notSeen
    }

    /// The decision after one poll.
    public enum Step: Equatable, Sendable {
        /// Stop polling and exit with this code.
        case finished(Exit)
        /// Not settled yet — sleep and poll again.
        case keepPolling
    }

    /// Decode an `agent-status` reply's `{seen, status?}` fields into an ``Observation``. PURE +
    /// forward-tolerant (CLAUDE.md untrusted-input contract): `seen:false` ⇒ ``Observation/notSeen``;
    /// `seen:true` with NO status token ⇒ ``Observation/seenNoStatus`` (pane exists, agent not yet
    /// reporting — the startup window, keep polling); `seen:true` with a known status token ⇒ that
    /// ``ClaudeStatus``; `seen:true` with an UNKNOWN/future token degrades to ``ClaudeStatus/none``
    /// (i.e. "no agent here / closed" → settled) rather than trapping, mirroring ``ClaudeStatus/init(urgency:)``.
    public static func observation(seen: Bool, statusToken: String?) -> Observation {
        guard seen else { return .notSeen }
        guard let token = statusToken else { return .seenNoStatus }
        if let status = ClaudeStatus(rawValue: token) {
            return .status(status)
        }
        return .status(.none)
    }

    /// A polled ``ClaudeStatus`` is "at rest" — a state `watch:claude` returns on — when the session is
    /// neither actively working nor blocked on a human: `idle` (waiting for a fresh prompt), `done`
    /// (just finished a turn — the leading edge of idle, the actual "finished" signal), or `none`
    /// (claude exited / session closed). `working` and `needsPermission` are still active (the latter is
    /// blocked on a human, not idle), so they keep polling until they settle or the deadline elapses.
    public static func isAtRest(_ status: ClaudeStatus) -> Bool {
        switch status {
        case .idle,
             .done,
             .none: true
        case .working,
             .needsPermission: false
        }
    }

    /// The BLOCK deadline (in `DispatchTime` uptime nanoseconds), DECOUPLED from the per-IPC `--timeout`.
    ///
    /// `watch:claude` blocks until the session settles (spec: "block until idle"); the per-IPC `--timeout`
    /// (default 3000 ms) bounds each poll's socket recv/send ONLY, NOT the block — the old code fed
    /// `--timeout` straight into the block deadline, so the default exited `9` after 3 s while Claude was
    /// still working (shorter than essentially any real turn). The block is therefore UNBOUNDED by default
    /// (`blockTimeoutMs == nil` ⇒ `nil` ⇒ no deadline-driven exit `9`); a caller-supplied `--block-timeout`
    /// bounds it. A non-positive value also yields `nil` (treated as unbounded — never an instant timeout).
    public static func blockDeadlineNanos(startNanos: UInt64, blockTimeoutMs: Int?) -> UInt64? {
        guard let blockTimeoutMs, blockTimeoutMs > 0 else { return nil }
        return startNanos &+ UInt64(blockTimeoutMs) &* 1_000_000
    }

    /// Decide the next step from one poll.
    ///
    /// - `hasEverBeenSeen` carries forward across polls so a session that WAS seen and then disappears
    ///   (`notSeen` after a real status) reads as "closed" → exit `0`, while an id that is unknown on
    ///   the very first poll reads as "never seen" → exit `4`.
    /// - `deadlineExceeded` is the caller's clock verdict. It only forces a timeout while the session is
    ///   still active — a settled / closed / never-seen verdict wins over an expired deadline so a
    ///   just-in-time finish (or an unknown id) is never reported as a timeout.
    public static func decide(
        observation: Observation,
        hasEverBeenSeen: Bool,
        deadlineExceeded: Bool,
    ) -> Step {
        switch observation {
        case let .status(status):
            if isAtRest(status) { return .finished(.settled) }
            // Still working / blocked on a human → keep polling unless the deadline has elapsed.
            return deadlineExceeded ? .finished(.timedOut) : .keepPolling
        case .seenNoStatus:
            // Pane EXISTS but its agent has not reported a status yet (startup window) → keep polling
            // until it settles or the deadline elapses; never an instant never-seen on the first poll.
            return deadlineExceeded ? .finished(.timedOut) : .keepPolling
        case .notSeen:
            // An id that resolves to NO pane is "closed" when we have seen it before, else "never seen".
            return .finished(hasEverBeenSeen ? .settled : .neverSeen)
        }
    }
}
