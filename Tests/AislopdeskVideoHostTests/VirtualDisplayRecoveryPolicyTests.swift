#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// C6 BUG A — the PURE "WindowServer terminated the virtual display" decision: which live sessions
/// must be disconnected (bye + stop) so their clients' reconnect UI engages, instead of silently
/// capturing a dead display forever. The AX/SCK side effects (bye send, session stop, window
/// restore, VD re-create) are HW-gated and live in the daemon; this locks the decision inputs →
/// actions mapping.
final class VirtualDisplayTerminationPolicyTests: XCTestCase {
    // Only sessions whose window was PARKED on the dead VD are affected; the output is sorted for
    // deterministic teardown order.
    func testDisconnectsParkedLiveIntersectionSorted() {
        let out = VirtualDisplayTerminationPolicy.channelsToDisconnect(
            parkedChannels: [9, 2, 5],
            liveChannels: [5, 2, 9],
        )
        XCTAssertEqual(out, [2, 5, 9])
    }

    // A parked channel with NO live session (mint aborted mid-park, lane already reaped) has
    // nothing to stop — the window restore (restoreAll) covers it; it must NOT appear.
    func testParkedWithoutLiveSessionIsNotDisconnected() {
        let out = VirtualDisplayTerminationPolicy.channelsToDisconnect(
            parkedChannels: [1, 2],
            liveChannels: [2],
        )
        XCTAssertEqual(out, [2])
    }

    // A live session that never parked (1× real-display capture) is UNAFFECTED by VD death —
    // tearing it down would be the conservative-fallback blast radius, not the targeted fix.
    func testUnparkedLiveSessionsSurvive() {
        let out = VirtualDisplayTerminationPolicy.channelsToDisconnect(
            parkedChannels: [7],
            liveChannels: [7, 30, 31],
        )
        XCTAssertEqual(out, [7])
    }

    func testEmptyInputsDisconnectNothing() {
        XCTAssertEqual(
            VirtualDisplayTerminationPolicy.channelsToDisconnect(parkedChannels: [], liveChannels: [1, 2]),
            [],
        )
        XCTAssertEqual(
            VirtualDisplayTerminationPolicy.channelsToDisconnect(parkedChannels: [1, 2], liveChannels: []),
            [],
        )
    }
}

/// C6 BUG A — the lazy VD re-create throttle: after a WindowServer termination the NEXT park
/// request may re-create the VD, but exactly one attempt at a time (create blocks up to ~10 s on
/// WindowServer IPC) and never more often than the cooldown (a host whose WindowServer keeps
/// killing VDs must not stall every mint for 10 s).
final class VirtualDisplayRecreatePolicyTests: XCTestCase {
    func testFirstAttemptAllowed() {
        XCTAssertTrue(VirtualDisplayRecreatePolicy.shouldAttempt(
            now: 100, lastAttempt: nil, cooldown: 30, attemptInFlight: false,
        ))
    }

    func testInFlightAttemptBlocksEvenPastCooldown() {
        XCTAssertFalse(VirtualDisplayRecreatePolicy.shouldAttempt(
            now: 1000, lastAttempt: nil, cooldown: 30, attemptInFlight: true,
        ))
        XCTAssertFalse(VirtualDisplayRecreatePolicy.shouldAttempt(
            now: 1000, lastAttempt: 1, cooldown: 30, attemptInFlight: true,
        ))
    }

    func testWithinCooldownBlocksAndBoundaryAllows() {
        XCTAssertFalse(VirtualDisplayRecreatePolicy.shouldAttempt(
            now: 129.9, lastAttempt: 100, cooldown: 30, attemptInFlight: false,
        ))
        // Boundary: exactly one cooldown elapsed → allowed (>=, not >).
        XCTAssertTrue(VirtualDisplayRecreatePolicy.shouldAttempt(
            now: 130, lastAttempt: 100, cooldown: 30, attemptInFlight: false,
        ))
    }

    // The gate composes the policy under a lock: begin() admits exactly one in-flight attempt;
    // end() releases the flight but the cooldown (stamped at begin) still throttles the next one.
    func testGateSingleFlightThenCooldown() {
        let gate = VirtualDisplayRecreateGate(cooldown: 30)
        XCTAssertTrue(gate.begin(now: 100), "first attempt admitted")
        XCTAssertFalse(gate.begin(now: 100), "concurrent attempt refused (single-flight)")
        gate.end()
        XCTAssertFalse(gate.begin(now: 110), "post-flight retry inside the cooldown refused")
        XCTAssertTrue(gate.begin(now: 130), "retry after the cooldown admitted")
        gate.end()
    }
}
#endif
