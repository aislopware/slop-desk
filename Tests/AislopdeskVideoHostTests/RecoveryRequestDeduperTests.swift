import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// Component 5 (recovery-redundancy, 2026-06-11): the host-side dedup window that collapses the
/// client's byte-identical redundant recovery-request copies (3× spaced 3 ms) to ONE host action.
/// Pure value type — `now` injected, keyed on FULL raw datagram bytes (zero wire-layout coupling).
final class RecoveryRequestDeduperTests: XCTestCase {
    private func idrWire(lastDecoded: UInt32 = 400) -> Data {
        RecoveryMessage.requestIDR(lastDecodedFrameID: lastDecoded).encode()
    }

    private func ltrWire(from: UInt32 = 50, to: UInt32 = 50, lastDecoded: UInt32 = 49) -> Data {
        RecoveryMessage.requestLTRRefresh(fromFrameID: from, toFrameID: to, lastDecodedFrameID: lastDecoded).encode()
    }

    /// The redundancy burst: identical datagram at t / t+5ms / t+10ms → admit, drop, drop.
    func testRedundantBurstDedupsToOne() {
        var d = RecoveryRequestDeduper()
        let wire = ltrWire()
        XCTAssertTrue(d.admit(wire, now: 100.000))
        XCTAssertFalse(d.admit(wire, now: 100.005))
        XCTAssertFalse(d.admit(wire, now: 100.010))
    }

    /// A duplicate does NOT refresh the original's timestamp: identical at t and t+25 ms
    /// (window 20 ms) → both admitted, even with suppressed copies in between.
    func testWindowExpiryWithoutTimestampRefresh() {
        var d = RecoveryRequestDeduper(windowSeconds: 0.020)
        let wire = idrWire()
        XCTAssertTrue(d.admit(wire, now: 100.000))
        XCTAssertFalse(d.admit(wire, now: 100.010), "still inside the window")
        XCTAssertFalse(d.admit(wire, now: 100.019), "a drop must not extend the window")
        XCTAssertTrue(d.admit(wire, now: 100.025), "a legitimate identical re-request ages back to admissible")
    }

    /// Different requested context (another lostFrameID / frontier) inside the window must
    /// BOTH be admitted — the key is the full body, not just the type byte.
    func testDistinctContextBothAdmitted() {
        var d = RecoveryRequestDeduper()
        XCTAssertTrue(d.admit(ltrWire(from: 50, to: 50, lastDecoded: 49), now: 100.000))
        XCTAssertTrue(d.admit(ltrWire(from: 51, to: 51, lastDecoded: 49), now: 100.002))
        XCTAssertTrue(d.admit(idrWire(lastDecoded: 49), now: 100.004))
    }

    /// Type-2 (requestLTRRefresh) vs type-3 (requestIDR) are different bytes even if the
    /// context overlaps — both admitted (type-byte discrimination via byte-equality).
    func testTypeByteDiscrimination() {
        var d = RecoveryRequestDeduper()
        XCTAssertTrue(d.admit(ltrWire(), now: 100.000))
        XCTAssertTrue(d.admit(idrWire(), now: 100.001))
    }

    /// Capacity eviction (drop-oldest): 16 fresh distinct payloads evict entry #1, so its
    /// re-send inside the window is admitted again (bounded memory beats perfect dedup).
    func testCapacityEvictionDropOldest() {
        var d = RecoveryRequestDeduper(windowSeconds: 10, capacity: 16)
        let first = idrWire(lastDecoded: 0)
        XCTAssertTrue(d.admit(first, now: 100.0))
        for i in 1...16 {
            XCTAssertTrue(d.admit(idrWire(lastDecoded: UInt32(i)), now: 100.0 + Double(i) * 0.0001))
        }
        XCTAssertTrue(d.admit(first, now: 100.01), "evicted by capacity ⇒ admitted despite the window")
    }

    /// windowSeconds = 0 ⇒ kill switch: everything admitted, including immediate duplicates.
    func testZeroWindowAdmitsEverything() {
        var d = RecoveryRequestDeduper(windowSeconds: 0)
        let wire = ltrWire()
        XCTAssertTrue(d.admit(wire, now: 100.000))
        XCTAssertTrue(d.admit(wire, now: 100.000))
        XCTAssertTrue(d.admit(wire, now: 100.005))
    }

    /// Interleaved bursts: copies for lost frame N interleaving with copies for frame N+1
    /// (different bytes) — A, B admitted; A′, B′ dropped (the ring, not a single slot).
    func testInterleavedBurstsBothDedupCorrectly() {
        var d = RecoveryRequestDeduper()
        let a = ltrWire(from: 50, to: 50, lastDecoded: 49)
        let b = ltrWire(from: 51, to: 51, lastDecoded: 49)
        XCTAssertTrue(d.admit(a, now: 100.000)) // A
        XCTAssertTrue(d.admit(b, now: 100.003)) // B
        XCTAssertFalse(d.admit(a, now: 100.005)) // A′
        XCTAssertFalse(d.admit(b, now: 100.008)) // B′
        XCTAssertFalse(d.admit(a, now: 100.010)) // A″
    }

    /// CROSS-SIDE COUPLING at the RESOLVED defaults (no env overrides in tests): the client's
    /// full copy spread `(copies−1)·spacing` must stay ≤ HALF the host dedup window for EVERY
    /// legal copies count (1...5). Duplicates do not refresh the window timestamp, so a margin
    /// thinner than this lets a late/skewed copy age past the window, re-admit, and re-trigger a
    /// second ForceLTRRefresh/IDR — the double-action bug the deduper exists to prevent. Asserts
    /// against the actual constants (`AislopdeskVideoHostSession.recoveryDedupWindow` + the
    /// `RecoveryRequestRedundancy` default spacing), never literals.
    func testRedundancySpreadVsDedupWindowCouplingAtDefaults() {
        let window = AislopdeskVideoHostSession.recoveryDedupWindow
        XCTAssertGreaterThan(window, 0, "the default window must be a real (non-kill-switch) window")
        XCTAssertLessThan(
            window,
            RecoveryPolicy().lossyEscalationFloor,
            "must stay below the lossy-escalation floor (a legitimate re-request is never deduped)",
        )
        for copies in 1...5 {
            let r = RecoveryRequestRedundancy(copies: copies)
            let spread = Double(r.copies - 1) * r.spacing
            XCTAssertLessThanOrEqual(
                spread,
                window / 2,
                "copies=\(copies): spread \(spread * 1000) ms must be ≤ half the dedup window \(window * 1000) ms",
            )
        }
    }
}
