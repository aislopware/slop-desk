import XCTest
import RworkVideoProtocol
@testable import RworkVideoHost

/// PURE idle-timeout reap decision (CONCURRENCY-HOST-1 crash-without-bye + mux analogue).
/// Injected `now`, a concrete `Int` flow id, no sockets / timers / SCStream — safe under
/// `swift test --filter IdleReapDeciderTests`. The single load-bearing rule is
/// never-reap-without-keepalive (the safety property that makes a one-sided gate degrade,
/// never misbehave).
final class IdleReapDeciderTests: XCTestCase {
    private let idleTimeout: TimeInterval = 30

    private func make() -> IdleReapDecider<Int> { IdleReapDecider<Int>(idleTimeout: idleTimeout) }

    // 1. reap-after-timeout: a keepalive-proven flow is reapable at exactly +idleTimeout (>=), not before.
    func testReapAfterTimeout() {
        var d = make()
        d.noteInbound(id: 1, now: 0, isKeepalive: true)
        XCTAssertEqual(d.reap(now: 29.9), [], "just under idleTimeout ⇒ not yet reapable")
        XCTAssertEqual(d.reap(now: 30), [1], "exactly idleTimeout elapsed ⇒ reapable (>= boundary)")
        XCTAssertEqual(d.reap(now: 100), [1], "long past idleTimeout ⇒ still reapable")
    }

    // 2. THE safety rule: a flow that NEVER proved keepalive is NEVER reaped, no matter how silent.
    func testNeverReapWithoutKeepalive() {
        var d = make()
        for t in stride(from: 0.0, through: 25.0, by: 5.0) {
            d.noteInbound(id: 1, now: t, isKeepalive: false)   // media/input only, never a keepalive
        }
        XCTAssertEqual(d.reap(now: 1_000), [], "a flow that streams forever but never keepalives is never reaped")
        XCTAssertNotNil(d.record(1), "the record still exists — it is simply not eligible")
        XCTAssertFalse(d.record(1)!.sawKeepalive)
    }

    // 3. keepalive refreshes lastInbound; sawKeepalive is STICKY (a later non-keepalive inbound still
    //    leaves the flow reapable once it goes truly silent).
    func testKeepaliveRefreshesAndStickyFlag() {
        var d = make()
        d.noteInbound(id: 1, now: 0, isKeepalive: true)
        d.noteInbound(id: 1, now: 25, isKeepalive: false)   // a media datagram advances lastInbound
        XCTAssertEqual(d.reap(now: 30), [], "lastInbound advanced to 25 ⇒ only 5s idle ⇒ not reapable")
        XCTAssertEqual(d.reap(now: 55.001), [1],
                       "55.001 - 25 > 30 AND sawKeepalive stayed true ⇒ reapable even though last inbound was non-keepalive")
    }

    // 4. reconnect resets: forget() drops the record; a reused id starts a FRESH (unproven) record.
    func testReconnectResetsViaForget() {
        var d = make()
        d.noteInbound(id: 1, now: 0, isKeepalive: true)
        d.forget(id: 1)
        XCTAssertNil(d.record(1), "forget drops the record")
        d.noteInbound(id: 1, now: 0, isKeepalive: false)   // fresh record under the same id (a reconnect)
        XCTAssertEqual(d.reap(now: 1_000), [],
                       "the fresh record never proved keepalive ⇒ never reaped (a reconnect under a reused id starts safe)")
    }

    // 5. multi-lane independence: only the silent-keepalive-proven lane is due; the others survive,
    //    and reaping/forgetting it leaves them untouched.
    func testMultiLaneIndependence() {
        var d = make()
        d.noteInbound(id: 1, now: 0, isKeepalive: true)    // proven + will go silent → reapable
        d.noteInbound(id: 2, now: 0, isKeepalive: true)    // proven but recently active
        d.noteInbound(id: 2, now: 40, isKeepalive: false)  // lane 2 still talking at t=40
        d.noteInbound(id: 3, now: 0, isKeepalive: false)   // never proved keepalive → never reapable
        let due = d.reap(now: 45).sorted()
        XCTAssertEqual(due, [1], "only lane 1 (proven + silent ≥ 30) is due")
        d.forget(id: 1)
        XCTAssertNil(d.record(1))
        XCTAssertNotNil(d.record(2), "sibling lane 2 untouched")
        XCTAssertNotNil(d.record(3), "sibling lane 3 untouched")
    }

    // 6. forget de-dupes: after reap returns [1] and the caller forgets, the next reap does not re-report it.
    func testForgetDeDupes() {
        var d = make()
        d.noteInbound(id: 1, now: 0, isKeepalive: true)
        XCTAssertEqual(d.reap(now: 40), [1])
        d.forget(id: 1)
        XCTAssertEqual(d.reap(now: 40), [], "a reaped+forgotten flow is not double-reported")
        // forget is idempotent — forgetting again is a no-op, still no report.
        d.forget(id: 1)
        XCTAssertEqual(d.reap(now: 40), [])
    }

    // 7. The gate threshold ÷ interval invariant ≥ 3 (RFC-minimum-safe ratio) — guards a future
    //    constant edit from making the host trigger-happy. The shipping ratio is 6× (30s / 5s).
    func testKeepaliveRatioInvariant() {
        let ratio = KeepaliveTiming.idleTimeout / KeepaliveTiming.keepaliveInterval
        XCTAssertGreaterThanOrEqual(ratio, 3,
                                    "idleTimeout must be ≥ 3× the keepalive interval (RFC 9000 §10.1.2 / WireGuard) so a burst loss can't false-reap")
        XCTAssertEqual(KeepaliveTiming.keepaliveInterval, 5)
        XCTAssertEqual(KeepaliveTiming.idleTimeout, 30)
        XCTAssertEqual(KeepaliveTiming.reaperTick, 5)
    }

    // 8. Record creation: a first-ever inbound creates the record stamped at `now`.
    func testFirstInboundCreatesRecord() {
        var d = make()
        XCTAssertNil(d.record(7))
        d.noteInbound(id: 7, now: 12.5, isKeepalive: false)
        XCTAssertEqual(d.record(7), IdleReapDecider<Int>.Record(lastInbound: 12.5, sawKeepalive: false))
    }

    // 9. SinglePin keys exactly one flow (the single-pin transport's identity type).
    func testSinglePinIdentity() {
        var d = IdleReapDecider<SinglePin>(idleTimeout: idleTimeout)
        d.noteInbound(id: .pin, now: 0, isKeepalive: true)
        XCTAssertEqual(d.reap(now: 30), [.pin])
        XCTAssertEqual(SinglePin.pin, SinglePin(), "SinglePin is a 1-element identity")
    }
}
