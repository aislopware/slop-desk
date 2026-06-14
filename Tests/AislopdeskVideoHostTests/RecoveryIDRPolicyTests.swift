import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// Component 2 (2026-06-11): the DELIVERY-KEYED recovery-IDR admission policy. Pure wall-clock
/// decision logic — every verdict, the token accounting, the wrap-aware id compares, the grace
/// clamp and the grant-pending timeout are exercised headlessly (the F1 capturer gate this
/// replaces had ZERO test coverage — it was SCK-bound).
final class RecoveryIDRPolicyTests: XCTestCase {
    /// A fresh policy (no keyframe ever sent) grants immediately and spends a token.
    func testGrantWhenNoRecentKeyframe() {
        var policy = RecoveryIDRPolicy()
        XCTAssertEqual(policy.availableTokens, 2.0, accuracy: 1e-9)
        XCTAssertEqual(policy.decide(now: 10.0, clientLastDecoded: nil, smoothedRTTSeconds: 0.05), .grant)
        XCTAssertEqual(policy.availableTokens, 1.0, accuracy: 1e-9)
    }

    /// GOLD — the ~600 ms fix. A keyframe K was sent, both kfDup copies died; the client's next
    /// 2·RTT escalation arrives carrying lastDecoded < K with age(K) past the grace ⇒ the casualty
    /// bypass grants IMMEDIATELY (the legacy sent-keyed gate would suppress for the full 500 ms).
    func testCasualtyBypassAfterGrace() {
        var policy = RecoveryIDRPolicy()
        policy.noteKeyframeSent(frameID: 100, now: 5.0)
        // age 0.2 s ≥ grace(rtt 0.05) = max(0.75×0.05, 0.04) = 0.04 ⇒ bypass.
        XCTAssertEqual(policy.decide(now: 5.2, clientLastDecoded: 99, smoothedRTTSeconds: 0.05), .grant)
    }

    /// Within the grace the keyframe is plausibly still in flight — suppress, and spend NO token.
    func testSuppressInFlightWithinGrace() {
        var policy = RecoveryIDRPolicy()
        policy.noteKeyframeSent(frameID: 100, now: 5.0)
        let before = policy.availableTokens
        XCTAssertEqual(policy.decide(now: 5.02, clientLastDecoded: 99, smoothedRTTSeconds: 0.05), .suppressInFlight)
        XCTAssertEqual(policy.availableTokens, before, accuracy: 1e-9, "suppression must not spend a token")
    }

    /// A request whose lastDecoded ≥ the newest sent keyframe PROVES that keyframe delivered and
    /// reports a genuinely new post-K loss ⇒ grant at ANY age — the cooldown is self-keyed on
    /// delivery.
    func testRequestProvesDeliveryGrants() {
        var policy = RecoveryIDRPolicy()
        policy.noteKeyframeSent(frameID: 100, now: 5.0)
        // Immediately after the send (well inside the old 500 ms window AND inside grace).
        XCTAssertEqual(policy.decide(now: 5.01, clientLastDecoded: 100, smoothedRTTSeconds: 0.05), .grant)
        policy.noteKeyframeSent(frameID: 101, now: 5.02)
        XCTAssertEqual(
            policy.decide(now: 5.03, clientLastDecoded: 105, smoothedRTTSeconds: 0.05),
            .grant,
            "lastDecoded ahead of the newest keyframe also proves delivery",
        )
    }

    /// After the client decode-ACKED keyframe K, a delayed request predating K is suppressed at
    /// zero cost regardless of age (this is what the keyframe ack buys over the grace heuristic).
    func testSuppressStaleAfterDeliveredAck() {
        var policy = RecoveryIDRPolicy()
        policy.noteKeyframeSent(frameID: 100, now: 5.0)
        policy.noteKeyframeDelivered(frameID: 100)
        let before = policy.availableTokens
        // Far past any grace window — the legacy heuristic would have granted here.
        XCTAssertEqual(policy.decide(now: 9.0, clientLastDecoded: 99, smoothedRTTSeconds: 0.05), .suppressStale)
        XCTAssertEqual(policy.availableTokens, before, accuracy: 1e-9, "stale suppression spends no token")
    }

    /// Only ids matching the sent-keyframe ring count as keyframe delivery — an LTR-P ack must
    /// not masquerade as one.
    func testDeliveredAckIgnoredUnlessRingMatch() {
        var policy = RecoveryIDRPolicy()
        policy.noteKeyframeSent(frameID: 100, now: 5.0)
        policy.noteKeyframeDelivered(frameID: 555) // not a sent keyframe — ignored
        // If 555 had been folded, this pre-555 request would be .suppressStale; instead the
        // casualty bypass grants (age past grace).
        XCTAssertEqual(policy.decide(now: 5.3, clientLastDecoded: 99, smoothedRTTSeconds: 0.05), .grant)
    }

    /// Token bucket: capacity 2 ⇒ two grants back-to-back (ordinary + casualty bypass), the third
    /// is rate-limited; a 500 ms refill restores one grant.
    func testTokenBucketCapsBurstAtTwo() {
        var policy = RecoveryIDRPolicy()
        XCTAssertEqual(policy.decide(now: 10.0, clientLastDecoded: nil, smoothedRTTSeconds: 0.05), .grant)
        policy.noteKeyframeSent(frameID: 1, now: 10.01)
        // Past grace (age 0.09 > 0.04), client still behind ⇒ casualty bypass — second token.
        XCTAssertEqual(policy.decide(now: 10.1, clientLastDecoded: 0, smoothedRTTSeconds: 0.05), .grant)
        policy.noteKeyframeSent(frameID: 2, now: 10.11)
        // Third request past grace: tokens exhausted (2 − 2 + ~0.2 refilled < 1).
        XCTAssertEqual(policy.decide(now: 10.2, clientLastDecoded: 0, smoothedRTTSeconds: 0.05), .suppressRateLimited)
        // ~500 ms later the bucket refilled ≥1 ⇒ grant returns.
        XCTAssertEqual(policy.decide(now: 10.75, clientLastDecoded: 0, smoothedRTTSeconds: 0.05), .grant)
    }

    /// While a grant is latched-but-unserviced, duplicate requests fold to suppressGrantPending;
    /// a noteKeyframeSent clears it; and the 1.5 s timeout un-wedges a dead capture path.
    func testSuppressGrantPendingUntilKeyframeSentOrTimeout() {
        var policy = RecoveryIDRPolicy()
        XCTAssertEqual(policy.decide(now: 10.0, clientLastDecoded: nil, smoothedRTTSeconds: 0.05), .grant)
        // Duplicates while the granted IDR has not hit the wire yet.
        XCTAssertEqual(
            policy.decide(now: 10.1, clientLastDecoded: nil, smoothedRTTSeconds: 0.05),
            .suppressGrantPending,
        )
        XCTAssertEqual(
            policy.decide(now: 11.0, clientLastDecoded: nil, smoothedRTTSeconds: 0.05),
            .suppressGrantPending,
        )
        // Serviced: the keyframe went out → pending clears → next decision is on the merits
        // (in-flight now, since the client is behind and the send is fresh).
        policy.noteKeyframeSent(frameID: 50, now: 11.1)
        XCTAssertEqual(policy.decide(now: 11.11, clientLastDecoded: nil, smoothedRTTSeconds: 0.05), .suppressInFlight)

        // Timeout arm: a grant never serviced (capture died) expires after 1.5 s.
        var wedged = RecoveryIDRPolicy()
        XCTAssertEqual(wedged.decide(now: 20.0, clientLastDecoded: nil, smoothedRTTSeconds: 0.05), .grant)
        XCTAssertEqual(
            wedged.decide(now: 21.4, clientLastDecoded: nil, smoothedRTTSeconds: 0.05),
            .suppressGrantPending,
        )
        XCTAssertEqual(
            wedged.decide(now: 21.6, clientLastDecoded: nil, smoothedRTTSeconds: 0.05),
            .grant,
            "grant-pending must expire (static-window wedge protection)",
        )
    }

    /// nil lastDecoded (the wire sentinel — nothing decoded yet) is maximally behind: suppressed
    /// within grace, granted after — the connect-time first-IDR-loss case.
    func testNilLastDecodedTreatedAsBehind() {
        var policy = RecoveryIDRPolicy()
        policy.noteKeyframeSent(frameID: 0, now: 5.0) // the FIRST-frame keyframe
        XCTAssertEqual(policy.decide(now: 5.01, clientLastDecoded: nil, smoothedRTTSeconds: 0.05), .suppressInFlight)
        XCTAssertEqual(
            policy.decide(now: 5.2, clientLastDecoded: nil, smoothedRTTSeconds: 0.05),
            .grant,
            "a lost first IDR must ride the same casualty bypass",
        )
    }

    /// frameIDs straddling the UInt32 wrap: ring compares, delivered-id monotonicity and the
    /// request compare all use distanceWrapped.
    func testWrapAwareIDs() {
        var policy = RecoveryIDRPolicy()
        let nearMax: UInt32 = .max - 1
        policy.noteKeyframeSent(frameID: nearMax, now: 5.0)
        // Client's lastDecoded is 3 (wrapped past .max) — AHEAD of nearMax ⇒ proves delivery.
        XCTAssertEqual(policy.decide(now: 5.01, clientLastDecoded: 3, smoothedRTTSeconds: 0.05), .grant)
        // Delivered-ack across the wrap stays monotonic: 2 (post-wrap) is newer than .max-1.
        policy.noteKeyframeSent(frameID: 2, now: 5.02)
        policy.noteKeyframeDelivered(frameID: nearMax)
        policy.noteKeyframeDelivered(frameID: 2)
        // A request with lastDecoded = .max (older than delivered 2, wrap-aware) is stale.
        XCTAssertEqual(policy.decide(now: 9.0, clientLastDecoded: .max, smoothedRTTSeconds: 0.05), .suppressStale)
        // The reverse fold (old ack after new) must not regress the delivered id.
        policy.noteKeyframeDelivered(frameID: nearMax)
        XCTAssertEqual(policy.decide(now: 9.5, clientLastDecoded: .max, smoothedRTTSeconds: 0.05), .suppressStale)
    }

    /// grace = clamp(0.75 × rtt, 40 ms, 250 ms).
    func testGraceClamp() {
        let policy = RecoveryIDRPolicy()
        XCTAssertEqual(policy.grace(rtt: 0), 0.040, accuracy: 1e-9) // bootstrap floor
        XCTAssertEqual(policy.grace(rtt: 0.059), 0.04425, accuracy: 1e-9) // 0.75 × 59 ms
        XCTAssertEqual(policy.grace(rtt: 1.0), 0.250, accuracy: 1e-9) // ceil = kfDupMinInterval
    }

    /// FPSGovernor-proof: the policy is 100% wall-clock — for the same timestamps the verdicts are
    /// identical no matter how many (no-op) extra decide() calls happen in between (i.e. cadence /
    /// call-count never changes outcomes; only time and ids do).
    func testWallClockOnly() {
        func run(extraProbes: Int) -> [RecoveryIDRPolicy.Verdict] {
            var policy = RecoveryIDRPolicy()
            var verdicts: [RecoveryIDRPolicy.Verdict] = []
            policy.noteKeyframeSent(frameID: 10, now: 1.0)
            verdicts.append(policy.decide(now: 1.02, clientLastDecoded: 9, smoothedRTTSeconds: 0.05)) // in-flight
            // Extra suppressed probes at the SAME timestamp (a higher request cadence) — all
            // in-flight, none spend tokens or change state.
            for _ in 0..<extraProbes {
                _ = policy.decide(now: 1.02, clientLastDecoded: 9, smoothedRTTSeconds: 0.05)
            }
            verdicts.append(policy.decide(now: 1.2, clientLastDecoded: 9, smoothedRTTSeconds: 0.05)) // bypass grant
            policy.noteKeyframeSent(frameID: 11, now: 1.21)
            verdicts.append(policy.decide(now: 1.3, clientLastDecoded: 9, smoothedRTTSeconds: 0.05)) // 2nd grant
            policy.noteKeyframeSent(frameID: 12, now: 1.31)
            verdicts.append(policy.decide(now: 1.4, clientLastDecoded: 9, smoothedRTTSeconds: 0.05)) // rate-limited
            return verdicts
        }
        XCTAssertEqual(run(extraProbes: 0), run(extraProbes: 7))
        XCTAssertEqual(run(extraProbes: 0), [.suppressInFlight, .grant, .grant, .suppressRateLimited])
    }

    /// The ring is bounded at `keyframeRingCapacity` (oldest evicted) — an ack for an evicted id
    /// no longer matches (bounded memory, no unbounded-map class of bug).
    func testKeyframeRingEvictsOldest() {
        var policy = RecoveryIDRPolicy()
        for id: UInt32 in [1, 2, 3, 4, 5] { // capacity 4 ⇒ 1 evicted
            policy.noteKeyframeSent(frameID: id, now: 5.0 + Double(id) * 0.001)
        }
        policy.noteKeyframeDelivered(frameID: 1) // evicted — must be ignored
        // Were 1 folded as delivered, lastDecoded=0 would be .suppressStale; instead the casualty
        // bypass grants (newest is 5, age past grace).
        XCTAssertEqual(policy.decide(now: 6.0, clientLastDecoded: 0, smoothedRTTSeconds: 0.05), .grant)
    }
}
