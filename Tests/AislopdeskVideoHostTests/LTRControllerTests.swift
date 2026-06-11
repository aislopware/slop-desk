import XCTest
@testable import AislopdeskVideoHost

/// PURE WF-8 Long-Term-Reference recovery bookkeeping. The ``VideoEncoder`` it drives is HW-gated and
/// never instantiated in a test, so this is the only headlessly-verifiable layer — it covers the
/// `frameID → token` map (record + bounded evict-oldest), the acknowledged-token set (fold + bounded
/// keep-most-recent), the unknown/duplicate-ack no-op, and — paramount — the ACKED-ONLY recovery
/// decision (`.ltrRefresh` ONLY when LTR is on AND a token is acked; `.idr` otherwise / for requestIDR).
final class LTRControllerTests: XCTestCase {

    // MARK: record + ack

    func testAckUnknownFrameReturnsNilAndNoToken() {
        var c = LTRController()
        XCTAssertNil(c.ackFrame(frameID: 42), "an unknown frameID acks nothing")
        XCTAssertFalse(c.hasAckedToken)
        XCTAssertTrue(c.currentAcknowledgedTokens().isEmpty)
    }

    func testRecordThenAckFoldsTokenAndArmsHasAcked() {
        var c = LTRController()
        c.recordLTRFrame(frameID: 7, token: 0xABCD)
        XCTAssertFalse(c.hasAckedToken, "recording alone does NOT acknowledge — only a client ack does")
        let folded = c.ackFrame(frameID: 7)
        XCTAssertEqual(folded, 0xABCD, "acking a recorded frameID returns its token to stage on the encoder")
        XCTAssertTrue(c.hasAckedToken)
        XCTAssertEqual(c.currentAcknowledgedTokens(), [0xABCD])
    }

    func testDuplicateAckIsIdempotentNoGrowth() {
        var c = LTRController()
        c.recordLTRFrame(frameID: 1, token: 100)
        XCTAssertEqual(c.ackFrame(frameID: 1), 100)
        XCTAssertEqual(c.ackFrame(frameID: 1), 100, "re-acking the same frame still returns the token")
        XCTAssertEqual(c.currentAcknowledgedTokens(), [100], "the acked set does not duplicate a token")
    }

    func testAckAfterEvictionIsSafeNoOp() {
        var c = LTRController()
        // Record one, then overflow the map past it so its mapping is evicted.
        c.recordLTRFrame(frameID: 0, token: 999)
        for f in 1...(LTRController.frameTokenCap + 4) {
            c.recordLTRFrame(frameID: UInt32(f), token: Int64(f))
        }
        XCTAssertNil(c.ackFrame(frameID: 0), "an evicted frameID acks nothing (safe no-op, never a crash)")
        XCTAssertFalse(c.hasAckedToken)
    }

    // MARK: bounds

    func testFrameTokenMapEvictsOldest() {
        var c = LTRController()
        let n = LTRController.frameTokenCap + 30
        for f in 0..<n {
            c.recordLTRFrame(frameID: UInt32(f), token: Int64(f))
        }
        XCTAssertEqual(c.frameTokens.count, LTRController.frameTokenCap, "map is capped")
        XCTAssertEqual(c.frameOrder.count, LTRController.frameTokenCap, "order list is capped in lockstep")
        // The oldest recordings are gone; the most-recent cap survive.
        XCTAssertNil(c.frameTokens[0])
        XCTAssertNotNil(c.frameTokens[UInt32(n - 1)])
        XCTAssertEqual(c.frameTokens[UInt32(n - 1)], Int64(n - 1))
    }

    func testAcknowledgedSetKeepsMostRecentBounded() {
        var c = LTRController()
        let n = LTRController.acknowledgedTokenCap + 20
        for f in 0..<n {
            c.recordLTRFrame(frameID: UInt32(f), token: Int64(f * 7))
            _ = c.ackFrame(frameID: UInt32(f))
        }
        let acked = c.currentAcknowledgedTokens()
        XCTAssertEqual(acked.count, LTRController.acknowledgedTokenCap, "acked set is capped")
        // It keeps the MOST-RECENT tokens (oldest dropped first), in oldest→newest order.
        let expected = ((n - LTRController.acknowledgedTokenCap)..<n).map { Int64($0 * 7) }
        XCTAssertEqual(acked, expected)
        XCTAssertEqual(acked.last, Int64((n - 1) * 7), "the newest acked token is last")
    }

    func testStagingNeverGrowsUnderLongStream() {
        // A long synthetic record+ack stream must not grow either dimension past its cap.
        var c = LTRController()
        for f in 0..<10_000 {
            c.recordLTRFrame(frameID: UInt32(truncatingIfNeeded: f), token: Int64(f))
            _ = c.ackFrame(frameID: UInt32(truncatingIfNeeded: f))
        }
        XCTAssertLessThanOrEqual(c.frameTokens.count, LTRController.frameTokenCap)
        XCTAssertLessThanOrEqual(c.frameOrder.count, LTRController.frameTokenCap)
        XCTAssertLessThanOrEqual(c.currentAcknowledgedTokens().count, LTRController.acknowledgedTokenCap)
        XCTAssertTrue(c.hasAckedToken)
    }

    // MARK: THE ACKED-ONLY recovery invariant

    func testRecoveryDecisionRequiresAckedTokenForLTRRefresh() {
        var c = LTRController()
        // LTR on but NOTHING acked yet → must fall back to a real IDR (the central invariant).
        XCTAssertEqual(c.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true), .idr)
        c.recordLTRFrame(frameID: 3, token: 55)
        // Recorded but not yet ACKED → still .idr (recording != acked).
        XCTAssertEqual(c.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true), .idr)
        _ = c.ackFrame(frameID: 3)
        // Now a token is acked AND LTR is on → an LTR refresh is permitted.
        XCTAssertEqual(c.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true), .ltrRefresh)
    }

    func testRecoveryDecisionIDRWhenLTROff() {
        var c = LTRController()
        c.recordLTRFrame(frameID: 1, token: 9)
        _ = c.ackFrame(frameID: 1)
        // Even WITH an acked token, LTR off ⇒ always a real IDR (byte-identical to today).
        XCTAssertEqual(c.recoveryDecision(request: .ltrRefresh, hasEnableLTR: false), .idr)
    }

    func testRequestIDRAlwaysForcesIDR() {
        var c = LTRController()
        c.recordLTRFrame(frameID: 1, token: 9)
        _ = c.ackFrame(frameID: 1)
        // requestIDR is the guaranteed-recovery escalation: ALWAYS a real IDR, even with an acked
        // token and LTR on — it must never degrade to an LTR refresh.
        XCTAssertEqual(c.recoveryDecision(request: .idr, hasEnableLTR: true), .idr)
    }

    // MARK: reset — encoder/VT-session rebuild invalidation (the WF-8 self-audit fix)

    func testResetClearsAckedSetAndFrameMap() {
        var c = LTRController()
        c.recordLTRFrame(frameID: 1, token: 11)
        c.recordLTRFrame(frameID: 2, token: 22)
        _ = c.ackFrame(frameID: 1)
        _ = c.ackFrame(frameID: 2)
        XCTAssertTrue(c.hasAckedToken)
        XCTAssertFalse(c.frameTokens.isEmpty)
        XCTAssertFalse(c.frameOrder.isEmpty)

        c.reset()

        XCTAssertFalse(c.hasAckedToken, "reset clears the acknowledged set")
        XCTAssertTrue(c.currentAcknowledgedTokens().isEmpty)
        XCTAssertTrue(c.frameTokens.isEmpty, "reset clears the frameID→token map")
        XCTAssertTrue(c.frameOrder.isEmpty, "reset clears the insertion-order list in lockstep")
    }

    /// THE finding: across an encoder / VTCompressionSession rebuild (resize) the host installs a fresh
    /// VT session that holds ZERO acknowledged LTRs, but the controller's acked tokens belonged to the
    /// destroyed session. Until ``reset()`` existed there was no way to invalidate them, so
    /// `recoveryDecision` kept returning `.ltrRefresh` → a `ForceLTRRefresh` against an LTR the new
    /// session never had (host-side gate bypassed). After reset the gate correctly falls back to `.idr`
    /// until the client decodes+acks a NEW LTR frame on the rebuilt session.
    func testResetReArmsACKEDOnlyGateAfterSessionRebuild() {
        var c = LTRController()
        c.recordLTRFrame(frameID: 5, token: 0xDEAD)
        _ = c.ackFrame(frameID: 5)
        // Pre-rebuild: LTR on + a token acked ⇒ an LTR refresh is permitted.
        XCTAssertEqual(c.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true), .ltrRefresh)

        // Encoder rebuilt on resize — the host invalidates the acked-set for the new VT session.
        c.reset()

        // The gate now falls back to a real IDR — the new session has no acked LTR to reference.
        XCTAssertEqual(c.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true), .idr,
                       "after a session rebuild the ACKED-ONLY gate must require a FRESH ack before an LTR refresh")
        XCTAssertFalse(c.hasAckedToken)
    }

    /// A late ack carrying a frameID recorded against the DEAD (pre-rebuild) session must NOT re-arm the
    /// gate: reset clears the frame map too, so that frameID no longer maps to a token (safe no-op). Only
    /// a frame recorded+acked on the NEW session re-arms `hasAckedToken`.
    func testLateAckForPreRebuildFrameIsNoOpAfterReset() {
        var c = LTRController()
        c.recordLTRFrame(frameID: 9, token: 0xBEEF)
        c.reset()
        XCTAssertNil(c.ackFrame(frameID: 9), "a frameID from the destroyed session no longer maps to a token")
        XCTAssertFalse(c.hasAckedToken, "a stale ack must not re-arm the gate after a rebuild")
        // A frame recorded+acked on the NEW session does re-arm it.
        c.recordLTRFrame(frameID: 10, token: 0xCAFE)
        XCTAssertEqual(c.ackFrame(frameID: 10), 0xCAFE)
        XCTAssertTrue(c.hasAckedToken)
    }
}
