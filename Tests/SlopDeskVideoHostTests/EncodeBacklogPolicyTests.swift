#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// PURE policy for the decoupled encode backlog (``WindowCapturer/backlogDecision``). Decides, when a
/// captured frame arrives and the encoder is behind, whether to admit it, drop it, or coalesce out an
/// older pending delta. No CoreMedia / VideoToolbox — just the drop-vs-keep arithmetic, so it is
/// headless-safe and pins the freshest-wins inversion the Parsec RE motivated:
/// default = drop the NEWEST delta; `freshest` = keep the newest, evict the stalest.
final class EncodeBacklogPolicyTests: XCTestCase {
    // Room in the backlog → always enqueue, regardless of policy or forced-ness.
    func testUnderCapAlwaysEnqueues() {
        for freshest in [false, true] {
            XCTAssertEqual(WindowCapturer.backlogDecision(
                pendingForced: [], incomingForced: false, max: 3, freshest: freshest,
            ), .enqueue)
            XCTAssertEqual(WindowCapturer.backlogDecision(
                pendingForced: [false, false], incomingForced: false, max: 3, freshest: freshest,
            ), .enqueue)
        }
    }

    // DEFAULT (freshest == false): a full backlog drops the INCOMING (newest) delta — the historical
    // ragged drop-newest the audit flagged as the 100–140ms present-hitch source.
    func testDefaultFullDropsNewest() {
        XCTAssertEqual(WindowCapturer.backlogDecision(
            pendingForced: [false, false, false], incomingForced: false, max: 3, freshest: false,
        ), .dropIncoming)
    }

    // FRESHEST: a full backlog evicts the OLDEST unforced pending delta and admits the newest.
    func testFreshestFullEvictsOldestUnforced() {
        XCTAssertEqual(WindowCapturer.backlogDecision(
            pendingForced: [false, false, false], incomingForced: false, max: 3, freshest: true,
        ), .evictOldestUnforced(0))
    }

    // FRESHEST evicts the oldest UNFORCED, skipping a forced frame at the head (recovery anchor kept).
    func testFreshestSkipsForcedWhenEvicting() {
        XCTAssertEqual(WindowCapturer.backlogDecision(
            pendingForced: [true, false, false], incomingForced: false, max: 3, freshest: true,
        ), .evictOldestUnforced(1))
    }

    // A forced incoming (IDR/crisp/compact/LTR) is NEVER dropped — it enqueues even when full,
    // overflowing the cap, under both policies (recovery/sharpness anchor must reach the encoder).
    func testForcedIncomingAlwaysEnqueuesEvenWhenFull() {
        for freshest in [false, true] {
            XCTAssertEqual(WindowCapturer.backlogDecision(
                pendingForced: [false, false, false], incomingForced: true, max: 3, freshest: freshest,
            ), .enqueue)
        }
    }

    // FRESHEST with an ALL-forced full backlog: there is no unforced frame to evict, so keep the fresh
    // delta (enqueue/overflow) rather than drop it — freshness wins over the cap in this rare corner.
    func testFreshestAllForcedBacklogKeepsFreshDelta() {
        XCTAssertEqual(WindowCapturer.backlogDecision(
            pendingForced: [true, true, true], incomingForced: false, max: 3, freshest: true,
        ), .enqueue)
    }

    // The load-bearing contrast: SAME full-unforced state + unforced incoming → the two policies make
    // OPPOSITE choices. Default discards the newest; freshest discards the oldest and keeps the newest.
    func testPolicyInversionOnIdenticalInput() {
        let pending = [false, false, false]
        let def = WindowCapturer.backlogDecision(
            pendingForced: pending, incomingForced: false, max: 3, freshest: false,
        )
        let fresh = WindowCapturer.backlogDecision(
            pendingForced: pending, incomingForced: false, max: 3, freshest: true,
        )
        XCTAssertEqual(def, .dropIncoming, "default keeps stale, drops newest")
        XCTAssertEqual(fresh, .evictOldestUnforced(0), "freshest drops stalest, keeps newest")
        XCTAssertNotEqual(def, fresh)
    }
}
#endif
