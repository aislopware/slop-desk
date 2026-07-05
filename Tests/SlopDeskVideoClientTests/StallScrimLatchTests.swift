import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoClient

/// The STICKY show/hide reducer behind the remote-GUI pane's "Reconnecting…" scrim (the stall-scrim
/// wiring that closes the reconnect-wedge residual). The load-bearing property is STICKINESS: once
/// the scrim is up, a host-ended rebuild drops the session to `.connecting` (verdict `.notConnected`)
/// and a fresh session starts with no liveness yet (verdict `.unknown`) — the scrim must HOLD through
/// both and clear only on a real `.live` verdict (traffic actually flowing again), or the pane would
/// flash "healthy" while showing a stale frozen frame mid-recovery.
final class StallScrimLatchTests: XCTestCase {
    func testStartsHidden() {
        XCTAssertFalse(StallScrimLatch().visible)
    }

    func testStalledShowsExactlyOnce() {
        var latch = StallScrimLatch()
        XCTAssertEqual(latch.apply(.stalled), true, "first stall flips the scrim on")
        XCTAssertTrue(latch.visible)
        XCTAssertNil(latch.apply(.stalled), "repeat stall verdicts are quiet (no re-notify)")
        XCTAssertTrue(latch.visible)
    }

    func testLiveHidesExactlyOnce() {
        var latch = StallScrimLatch()
        _ = latch.apply(.stalled)
        XCTAssertEqual(latch.apply(.live), false, "recovery flips the scrim off")
        XCTAssertFalse(latch.visible)
        XCTAssertNil(latch.apply(.live), "repeat live verdicts are quiet")
    }

    /// STICKY across the rebuild: `.notConnected` (the FSM is `.connecting`/`.stopped` mid-rebuild) and
    /// `.unknown` (a fresh session with no liveness signal yet) must NOT clear a shown scrim.
    func testScrimHoldsThroughRebuildVerdicts() {
        var latch = StallScrimLatch()
        _ = latch.apply(.stalled)
        XCTAssertNil(latch.apply(.notConnected))
        XCTAssertTrue(latch.visible, "rebuild in flight — still reconnecting")
        XCTAssertNil(latch.apply(.unknown))
        XCTAssertTrue(latch.visible, "fresh session, no traffic yet — still reconnecting")
        XCTAssertEqual(latch.apply(.live), false, "first real liveness clears it")
    }

    /// A hidden scrim stays hidden through the benign verdicts (no spurious notify while healthy,
    /// while connecting at pane-open, or on a just-started stream).
    func testHiddenScrimIsQuietOnBenignVerdicts() {
        var latch = StallScrimLatch()
        XCTAssertNil(latch.apply(.live))
        XCTAssertNil(latch.apply(.notConnected))
        XCTAssertNil(latch.apply(.unknown))
        XCTAssertFalse(latch.visible)
    }

    /// THE BYE-PATH GAP (HW-found 2026-07-03): a host that shuts down GRACEFULLY sends `bye` — the FSM
    /// leaves `.streaming` before any stall verdict can fire, so verdicts run `.notConnected` and the
    /// scrim would never show while the pane sits frozen in hello-retry limbo. The rebuild path calls
    /// ``StallScrimLatch/noteReconnecting()`` to force the scrim up; it must show exactly once, hold
    /// through the connecting verdicts, and clear only on a real `.live`.
    func testNoteReconnectingShowsImmediatelyAndClearsOnlyOnLive() {
        var latch = StallScrimLatch()
        XCTAssertEqual(latch.noteReconnecting(), true, "a host-ended rebuild shows the scrim at once")
        XCTAssertNil(latch.noteReconnecting(), "duplicate byes / rebuild retries are quiet")
        XCTAssertNil(latch.apply(.notConnected), "hello-retry limbo holds the scrim")
        XCTAssertNil(latch.apply(.unknown), "fresh session with no traffic holds the scrim")
        XCTAssertTrue(latch.visible)
        XCTAssertEqual(latch.apply(.live), false, "traffic resumed — scrim clears")
    }

    /// CROSS-CONSTANT contract: the stall threshold must exceed the host heartbeat cadence by enough
    /// margin (≥ 3×) that a healthy link — even one dropping a heartbeat or two — can never false-stall.
    /// Pins the pair so neither constant is retuned without noticing the other.
    func testStallThresholdToleratesLostHeartbeats() {
        XCTAssertGreaterThanOrEqual(
            StreamStallPolicy().threshold,
            3 * KeepaliveTiming.hostHeartbeatInterval,
            "threshold must ride out ≥2 consecutive lost heartbeats (loss is normal on this path)",
        )
    }
}
