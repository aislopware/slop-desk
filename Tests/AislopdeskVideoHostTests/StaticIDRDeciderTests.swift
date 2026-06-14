import XCTest
@testable import AislopdeskVideoHost

/// PURE static-window forced-IDR decision logic (VIDEO-HOST-1). Decides whether the
/// frameQueue heartbeat timer should re-encode the cached buffer as a forced IDR, given an
/// injected clock + what was last encoded. No SCStream, no VideoToolbox, no Dispatch — safe
/// under `swift test --filter StaticIDRDeciderTests`.
final class StaticIDRDeciderTests: XCTestCase {
    private let heartbeat: TimeInterval = 1.0

    private func make(quietWindow: TimeInterval? = nil) -> StaticIDRDecider {
        StaticIDRDecider(heartbeat: heartbeat, quietWindow: quietWindow)
    }

    // 1. No cached buffer ⇒ never fire, for every now/forced combination.
    func testNoBufferNeverFires() {
        let d = make()
        for now: TimeInterval in [0, 1, 5, 100] {
            for forced in [false, true] {
                XCTAssertFalse(
                    d.shouldReencode(now: now, forcedLatched: forced, hasRetainedBuffer: false),
                    "no buffer must never fire (now=\(now), forced=\(forced))",
                )
            }
        }
    }

    // 2. Armed, never emitted, buffer present ⇒ fire at any now > 0.
    func testArmedNeverEmittedFires() {
        let d = make()
        XCTAssertTrue(d.shouldReencode(now: 0.001, forcedLatched: false, hasRetainedBuffer: true))
        XCTAssertTrue(d.shouldReencode(now: 50, forcedLatched: false, hasRetainedBuffer: true))
    }

    // 3. Heartbeat boundary is inclusive (>=): fires at exactly +heartbeat, not just before.
    func testHeartbeatBoundaryInclusive() {
        var d = make()
        d.onCompleteFrame(now: 10)
        XCTAssertTrue(
            d.shouldReencode(now: 11.0, forcedLatched: false, hasRetainedBuffer: true),
            "exactly one heartbeat elapsed ⇒ fire (>= inclusive)",
        )
        XCTAssertFalse(
            d.shouldReencode(now: 10.999, forcedLatched: false, hasRetainedBuffer: true),
            "just under one heartbeat ⇒ no fire",
        )
    }

    // 4. Quiet window suppresses the heartbeat while the live path is driving.
    func testQuietWindowSuppressesHeartbeat() {
        var d = make()
        d.onCompleteFrame(now: 10)
        XCTAssertFalse(
            d.shouldReencode(now: 10.5, forcedLatched: false, hasRetainedBuffer: true),
            "a real frame within the quiet window ⇒ live path owns it",
        )
    }

    // 5. Quiet window suppresses even a forced (recovery) request — the live latch drain handles it.
    func testQuietWindowSuppressesForced() {
        var d = make()
        d.onCompleteFrame(now: 10)
        XCTAssertFalse(
            d.shouldReencode(now: 10.5, forcedLatched: true, hasRetainedBuffer: true),
            "while live, recovery is serviced by the .complete latch drain, not the timer",
        )
    }

    // 6. Forced wins once quiet, BEFORE the heartbeat would otherwise fire (quietWindow < heartbeat
    //    isolates that recovery beats the heartbeat phase).
    func testForcedWinsOnceQuietBeforeHeartbeat() {
        var d = make(quietWindow: 0.3) // shorter than heartbeat (1.0) to isolate the forced path
        d.recordSynthetic(now: 10.1) // recent synthetic anchor ⇒ the heartbeat phase is mid-cycle
        d.onCompleteFrame(now: 10)
        // now=10.5: past the 0.3 quiet window but only 0.4 < 1.0 since the synthetic anchor →
        // heartbeat alone is silent.
        XCTAssertFalse(
            d.shouldReencode(now: 10.5, forcedLatched: false, hasRetainedBuffer: true),
            "sub-heartbeat, no forced ⇒ no fire",
        )
        XCTAssertTrue(
            d.shouldReencode(now: 10.5, forcedLatched: true, hasRetainedBuffer: true),
            "forced fires immediately once past the quiet window, any heartbeat phase",
        )
    }

    // 6b. Quiet-window EXACT boundary (sinceComplete == quietWindow): the strict `<` means the
    //     frame at exactly +quietWindow is NOT suppressed → a forced request fires; a sub-heartbeat
    //     non-forced still does not. Pins the strict-`<` semantics against a `<`→`<=` regression.
    func testQuietWindowExactBoundary() {
        var d = make(quietWindow: 0.3)
        d.recordSynthetic(now: 9.9) // recent synthetic anchor ⇒ the heartbeat phase is mid-cycle
        d.onCompleteFrame(now: 10)
        XCTAssertTrue(
            d.shouldReencode(now: 10.3, forcedLatched: true, hasRetainedBuffer: true),
            "forced at exactly +quietWindow ⇒ fire (strict `<` does not suppress the boundary)",
        )
        XCTAssertFalse(
            d.shouldReencode(now: 10.3, forcedLatched: false, hasRetainedBuffer: true),
            "non-forced sub-heartbeat at the quiet boundary ⇒ still no fire",
        )
    }

    // 2b. Forced + armed (no real frame ever encoded, buffer present) — the real first-frame
    //     recovery on a window that went static immediately ⇒ fire.
    func testForcedArmedFires() {
        let d = make()
        XCTAssertTrue(
            d.shouldReencode(now: 0.5, forcedLatched: true, hasRetainedBuffer: true),
            "forced recovery with a cached buffer but no prior emission ⇒ fire",
        )
    }

    // 7. A synthetic emission re-anchors the cadence (measured from max(lastComplete, lastSynthetic)).
    func testSyntheticReAnchorsCadence() {
        var d = make()
        d.onCompleteFrame(now: 10)
        d.recordSynthetic(now: 11) // a synthetic fired at 11
        XCTAssertFalse(
            d.shouldReencode(now: 11.5, forcedLatched: false, hasRetainedBuffer: true),
            "0.5s after the synthetic ⇒ no fire",
        )
        XCTAssertTrue(
            d.shouldReencode(now: 12.0, forcedLatched: false, hasRetainedBuffer: true),
            "one heartbeat after the synthetic ⇒ fire",
        )
    }

    // 8. A real frame after a synthetic still gates via its quiet window; once quiet AND one
    //    heartbeat past the synthetic anchor, fire.
    func testRealFrameAfterSyntheticReAnchorsToReal() {
        var d = make()
        d.recordSynthetic(now: 11)
        d.onCompleteFrame(now: 11.2) // a real frame landed shortly after the synthetic
        XCTAssertFalse(
            d.shouldReencode(now: 11.9, forcedLatched: false, hasRetainedBuffer: true),
            "within the quiet window of the real frame ⇒ no fire",
        )
        XCTAssertTrue(
            d.shouldReencode(now: 12.3, forcedLatched: false, hasRetainedBuffer: true),
            "quiet window cleared + one heartbeat past the synthetic anchor ⇒ fire",
        )
    }

    // 11. SHARPNESS (2026-06-10): the FIRST crisp after motion stops fires as soon as the quiet
    //     window clears — it does NOT wait a full heartbeat from the last REAL frame. Production
    //     shape: heartbeat 2.5, quietWindow 1.0 ⇒ crisp ~1 s after the scroll ends (Parsec-like),
    //     then steady-state synthetics one heartbeat apart.
    func testFirstCrispAfterMotionFiresAtQuietWindowNotHeartbeat() {
        var d = StaticIDRDecider(heartbeat: 2.5, quietWindow: 1.0)
        d.recordSynthetic(now: 2) // an old static-phase synthetic long ago
        d.onCompleteFrame(now: 10) // ...then motion; the last real frame lands at t=10
        XCTAssertFalse(
            d.shouldReencode(now: 10.9, forcedLatched: false, hasRetainedBuffer: true),
            "still inside the quiet window ⇒ live path owns it",
        )
        XCTAssertTrue(
            d.shouldReencode(now: 11.0, forcedLatched: false, hasRetainedBuffer: true),
            "quiet window cleared ⇒ first crisp fires NOW (not at lastComplete+heartbeat=12.5)",
        )
        d.recordSynthetic(now: 11.0)
        XCTAssertFalse(
            d.shouldReencode(now: 12.5, forcedLatched: false, hasRetainedBuffer: true),
            "subsequent statics pace one heartbeat from the synthetic anchor",
        )
        XCTAssertTrue(
            d.shouldReencode(now: 13.5, forcedLatched: false, hasRetainedBuffer: true),
            "heartbeat elapsed since the synthetic ⇒ steady-state cadence holds",
        )
    }

    // 9. lastComplete == 0 but lastSynthetic set: max() picks the synthetic anchor, quiet-window
    //    check is skipped (guarded by lastComplete != 0).
    func testLastEmissionPicksSyntheticWhenNoRealFrame() {
        var d = make()
        d.recordSynthetic(now: 5)
        XCTAssertFalse(
            d.shouldReencode(now: 5.5, forcedLatched: false, hasRetainedBuffer: true),
            "0.5s after the only (synthetic) emission, no real frame ⇒ no fire",
        )
        XCTAssertTrue(
            d.shouldReencode(now: 6.0, forcedLatched: false, hasRetainedBuffer: true),
            "one heartbeat after the synthetic anchor ⇒ fire (cadence from lastSynthetic)",
        )
    }

    // 10. Equatable sanity — identical anchors compare equal (guards against accidental field drift).
    func testEquatable() {
        var a = make()
        var b = make()
        XCTAssertEqual(a, b)
        a.onCompleteFrame(now: 10)
        b.onCompleteFrame(now: 10)
        a.recordSynthetic(now: 11)
        b.recordSynthetic(now: 11)
        XCTAssertEqual(a, b)
        b.recordSynthetic(now: 12)
        XCTAssertNotEqual(a, b)
    }

    // Default quietWindow == heartbeat (one cadence) when nil is passed.
    func testDefaultQuietWindowEqualsHeartbeat() {
        let d = StaticIDRDecider(heartbeat: 2.0)
        XCTAssertEqual(d.quietWindow, 2.0)
        XCTAssertEqual(d.heartbeat, 2.0)
    }
}
