import SlopDeskAgentDetect
import SlopDeskCLICore
import XCTest

// `slopdesk watch:claude <id>` exit-code state machine.
//
// The EXPECTED exit codes / steps are authored INDEPENDENTLY here (literal `0`/`4`/`9` and the
// hand-written at-rest classification), not derived from `WatchClaudeOutcome`'s own output, so a
// silent change to the mapping FAILS these tests (revert-to-confirm-fail). The poll loop that drives
// this machine lives in `main.swift` (compiled-only — it sleeps + does socket I/O); the DECISIONS are
// all exercised here with no socket, no GUI, no subprocess.

final class WatchClaudeOutcomeTests: XCTestCase {
    private typealias Outcome = WatchClaudeOutcome

    // MARK: - Exit-code constants (0 = idle/closed · 4 = never-seen · 9 = timeout)

    func testExitRawValuesArePinned() {
        XCTAssertEqual(Outcome.Exit.settled.rawValue, 0)
        XCTAssertEqual(Outcome.Exit.neverSeen.rawValue, 4)
        XCTAssertEqual(Outcome.Exit.timedOut.rawValue, 9)
    }

    // MARK: - Observation decoding ({seen, status?} → Observation), forward-tolerant

    func testObservationNotSeenWhenSeenFalse() {
        XCTAssertEqual(Outcome.observation(seen: false, statusToken: nil), .notSeen)
        // `seen:false` wins even if a stray status token is present.
        XCTAssertEqual(Outcome.observation(seen: false, statusToken: "idle"), .notSeen)
    }

    func testObservationDecodesEveryKnownStatusToken() {
        for status in ClaudeStatus.allCases {
            XCTAssertEqual(
                Outcome.observation(seen: true, statusToken: status.rawValue),
                .status(status),
                "token \(status.rawValue) should decode to .status(\(status))",
            )
        }
    }

    func testObservationSeenWithUnknownTokenDegradesToNone() {
        // Forward-tolerant: a seen session with an unknown/future or empty (non-nil) token is read as
        // "no agent here / closed" (.none → settled), never a trap.
        XCTAssertEqual(Outcome.observation(seen: true, statusToken: "warp-drive"), .status(.none))
        XCTAssertEqual(Outcome.observation(seen: true, statusToken: ""), .status(.none))
    }

    func testObservationSeenWithNoTokenIsSeenNoStatusNotNone() {
        // `seen:true` with a MISSING status token = the pane exists but the agent has not
        // reported yet (the startup window). It must decode to `.seenNoStatus`, NOT `.status(.none)` — the
        // latter is "at rest" (settled) and would exit a still-starting agent immediately.
        XCTAssertEqual(Outcome.observation(seen: true, statusToken: nil), .seenNoStatus)
        XCTAssertNotEqual(Outcome.observation(seen: true, statusToken: nil), .status(.none))
    }

    // MARK: - isAtRest classification (independently authored)

    func testIsAtRest() {
        XCTAssertTrue(Outcome.isAtRest(.idle))
        XCTAssertTrue(Outcome.isAtRest(.done))
        XCTAssertTrue(Outcome.isAtRest(.none))
        XCTAssertFalse(Outcome.isAtRest(.working))
        XCTAssertFalse(Outcome.isAtRest(.needsPermission))
    }

    // MARK: - Exit 0 — idle / done / closed (settled)

    func testIdleSettlesWithExitZero() {
        let step = Outcome.decide(observation: .status(.idle), hasEverBeenSeen: true, deadlineExceeded: false)
        XCTAssertEqual(step, .finished(.settled))
    }

    func testDoneSettlesWithExitZero() {
        // `done` is the leading edge of idle (the actual "finished a turn" signal) → settled.
        let step = Outcome.decide(observation: .status(.done), hasEverBeenSeen: true, deadlineExceeded: false)
        XCTAssertEqual(step, .finished(.settled))
    }

    func testNoneStatusSettlesWithExitZero() {
        // A seen pane whose agent has exited (status none) is "closed" → settled.
        let step = Outcome.decide(observation: .status(.none), hasEverBeenSeen: true, deadlineExceeded: false)
        XCTAssertEqual(step, .finished(.settled))
    }

    func testClosedAfterBeingSeenSettlesWithExitZero() {
        // notSeen AFTER the id was seen on an earlier poll = the session closed → settled (0), NOT 4.
        let step = Outcome.decide(observation: .notSeen, hasEverBeenSeen: true, deadlineExceeded: false)
        XCTAssertEqual(step, .finished(.settled))
    }

    // MARK: - Exit 4 — id never seen

    func testNeverSeenExitsFour() {
        // notSeen on the first poll (never seen before) = id never seen → exit 4.
        let step = Outcome.decide(observation: .notSeen, hasEverBeenSeen: false, deadlineExceeded: false)
        XCTAssertEqual(step, .finished(.neverSeen))
    }

    // MARK: - seenNoStatus — pane exists, agent not reporting yet (startup window) → keep polling

    func testSeenNoStatusOnFirstPollKeepsPollingNotNeverSeen() {
        // `watch:claude <id>` right after spawning Claude — the pane EXISTS but has not
        // reported a status yet. The first poll is `.seenNoStatus` with hasEverBeenSeen:false; it must keep
        // polling (block until idle), NOT decide `.neverSeen` (exit 4).
        let step = Outcome.decide(observation: .seenNoStatus, hasEverBeenSeen: false, deadlineExceeded: false)
        XCTAssertEqual(step, .keepPolling)
        XCTAssertNotEqual(step, .finished(.neverSeen))
    }

    func testSeenNoStatusPastDeadlineTimesOut() {
        // A pane that never reports a status before the (caller-supplied) deadline → timeout, not never-seen.
        let step = Outcome.decide(observation: .seenNoStatus, hasEverBeenSeen: false, deadlineExceeded: true)
        XCTAssertEqual(step, .finished(.timedOut))
    }

    func testSeenNoStatusEndToEndKeepsPolling() {
        // Wire reply {seen:true} (no status) on the first poll → keepPolling (exitCode nil), proving the
        // startup-window id does NOT terminate with exit 4. Revert-to-confirm-fail: before the fix, the
        // backend answered {seen:false} for this id and exitCode here would be 4.
        XCTAssertNil(exitCode(seen: true, status: nil, everSeen: false, expired: false))
    }

    // MARK: - Exit 9 — timeout while still active

    func testWorkingPastDeadlineTimesOut() {
        let step = Outcome.decide(observation: .status(.working), hasEverBeenSeen: true, deadlineExceeded: true)
        XCTAssertEqual(step, .finished(.timedOut))
    }

    func testNeedsPermissionPastDeadlineTimesOut() {
        // Blocked-on-a-human is NOT idle; if it never resolves before the deadline → timeout.
        let step = Outcome.decide(observation: .status(.needsPermission), hasEverBeenSeen: true, deadlineExceeded: true)
        XCTAssertEqual(step, .finished(.timedOut))
    }

    // MARK: - Still active, deadline not reached → keep polling

    func testWorkingBeforeDeadlineKeepsPolling() {
        let step = Outcome.decide(observation: .status(.working), hasEverBeenSeen: true, deadlineExceeded: false)
        XCTAssertEqual(step, .keepPolling)
    }

    func testNeedsPermissionBeforeDeadlineKeepsPolling() {
        let step = Outcome.decide(
            observation: .status(.needsPermission),
            hasEverBeenSeen: true,
            deadlineExceeded: false,
        )
        XCTAssertEqual(step, .keepPolling)
    }

    // MARK: - A settled / closed / never-seen verdict WINS over an expired deadline

    func testIdleWinsOverExpiredDeadline() {
        // A just-in-time idle must NOT be reported as a timeout.
        let step = Outcome.decide(observation: .status(.idle), hasEverBeenSeen: true, deadlineExceeded: true)
        XCTAssertEqual(step, .finished(.settled))
    }

    func testClosedWinsOverExpiredDeadline() {
        let step = Outcome.decide(observation: .notSeen, hasEverBeenSeen: true, deadlineExceeded: true)
        XCTAssertEqual(step, .finished(.settled))
    }

    func testNeverSeenWinsOverExpiredDeadline() {
        // An unknown id is "never seen" (4) even if the deadline has already elapsed — not a timeout.
        let step = Outcome.decide(observation: .notSeen, hasEverBeenSeen: false, deadlineExceeded: true)
        XCTAssertEqual(step, .finished(.neverSeen))
    }

    // MARK: - End-to-end: wire reply ({seen, status?}) → decide → exit code

    func testWireReplyToExitCode() {
        // idle reply → 0
        XCTAssertEqual(
            exitCode(seen: true, status: ClaudeStatus.idle.rawValue, everSeen: true, expired: false),
            0,
        )
        // never-seen reply → 4
        XCTAssertEqual(exitCode(seen: false, status: nil, everSeen: false, expired: false), 4)
        // working-past-deadline reply → 9
        XCTAssertEqual(
            exitCode(seen: true, status: ClaudeStatus.working.rawValue, everSeen: true, expired: true),
            9,
        )
    }

    /// Mirror the `main.swift` poll step: decode the wire fields, decide, and surface the terminal exit
    /// code (or `nil` when the machine would keep polling).
    private func exitCode(seen: Bool, status: String?, everSeen: Bool, expired: Bool) -> Int32? {
        let observation = Outcome.observation(seen: seen, statusToken: status)
        let step = Outcome.decide(observation: observation, hasEverBeenSeen: everSeen, deadlineExceeded: expired)
        switch step {
        case let .finished(outcome): return outcome.rawValue
        case .keepPolling: return nil
        }
    }

    // MARK: - Block deadline is DECOUPLED from the per-IPC --timeout

    /// The DEFAULT `watch:claude` block is UNBOUNDED — it must NOT inherit the per-IPC `--timeout`
    /// (default 3000 ms) as its block deadline. Computing `deadlineNs = start + invocation.timeoutMs *
    /// 1e6` for the unflagged case would exit 9 after 3 s while Claude was still working; this pins that
    /// the default block produces NO deadline at all.
    func testDefaultBlockIsUnboundedNotThreeSeconds() {
        // No `--block-timeout` ⇒ nil ⇒ no deadline ⇒ never a deadline-driven exit 9.
        XCTAssertNil(Outcome.blockDeadlineNanos(startNanos: 1_000_000_000, blockTimeoutMs: nil))
        // Even feeding the per-IPC default (3000 ms) is NOT how the default behaves — the loop passes
        // `nil` for the unflagged case; the IPC timeout never reaches this function.
    }

    /// A non-positive block timeout is treated as unbounded (never an instant timeout at start).
    func testNonPositiveBlockTimeoutIsUnbounded() {
        XCTAssertNil(Outcome.blockDeadlineNanos(startNanos: 42, blockTimeoutMs: 0))
        XCTAssertNil(Outcome.blockDeadlineNanos(startNanos: 42, blockTimeoutMs: -5))
    }

    /// An explicit `--block-timeout <ms>` bounds the block: deadline = start + ms·1e6.
    func testExplicitBlockTimeoutBoundsTheDeadline() {
        let start: UInt64 = 5_000_000_000
        XCTAssertEqual(
            Outcome.blockDeadlineNanos(startNanos: start, blockTimeoutMs: 1500),
            start &+ 1500 &* 1_000_000,
        )
        // A long turn (e.g. 10 minutes) maps to a far-future deadline — proving the cap is the caller's
        // choice, not the 3 s IPC default.
        XCTAssertEqual(
            Outcome.blockDeadlineNanos(startNanos: start, blockTimeoutMs: 600_000),
            start &+ 600_000 &* 1_000_000,
        )
    }
}
