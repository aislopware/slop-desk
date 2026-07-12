import XCTest
@testable import SlopDeskVideoProtocol

/// Tests for `ScrollResampler` — the bursty-low-rate → steady-high-rate scroll resampler that fixes
/// the VS Code remote-scroll judder (HW-measured: Chromium needs ~250 Hz injection to render 60 fps;
/// the wire delivers ~60–120 Hz). The load-bearing invariant is TOTAL PRESERVATION: the summed output
/// must equal the summed input (to <1 px/axis), or remote scroll would drift away from the user's
/// gesture. Also pinned: markers pass through 1:1, the continuous stream resamples to a high tick
/// rate, the fast-flick lag is bounded, and an idle resampler emits nothing.
final class ScrollResamplerTests: XCTestCase {
    // CGScrollPhase / CGMomentumScrollPhase codes (as carried on the wire).
    private let began: UInt8 = 1
    private let changed: UInt8 = 2
    private let ended: UInt8 = 4
    private let mBegan: UInt8 = 1
    private let mContinue: UInt8 = 2
    private let mEnd: UInt8 = 3

    /// Drains the resampler to idle, returning every emitted sub-event.
    private func drainToIdle(_ r: inout ScrollResampler, maxTicks: Int = 100_000) -> [ScrollResampler.SubEvent] {
        var out: [ScrollResampler.SubEvent] = []
        var ticks = 0
        while !r.isIdle, ticks < maxTicks {
            if let e = r.drain() { out.append(e) }
            ticks += 1
        }
        return out
    }

    // MARK: - 1. Total preservation (the load-bearing invariant)

    func testTotalDeltaPreservedOverMixedSequence() {
        var r = ScrollResampler()
        var inX = 0.0, inY = 0.0
        var outX = 0.0, outY = 0.0
        func ingest(_ dx: Double, _ dy: Double, _ sp: UInt8, _ mp: UInt8) {
            inX += dx
            inY += dy
            for e in r.ingest(dx: dx, dy: dy, scrollPhase: sp, momentumPhase: mp, continuous: true) {
                outX += e.dx
                outY += e.dy
            }
        }
        // A realistic gesture: Began, a run of Changed (varying deltas incl. a reversal), finger Ended,
        // a momentum coast (Began + Continues), momentum End.
        ingest(0, 3, began, 0)
        var seed: UInt64 = 0xC0FFEE
        for _ in 0..<40 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let dy = Double(Int(seed >> 40) % 25 - 6) // -6...18, sometimes negative (reversal)
            ingest(0, dy, changed, 0)
            // interleave drains, as the real pump does (drain rate > ingest rate)
            if let e = r.drain() { outX += e.dx
                outY += e.dy
            }
            if let e = r.drain() { outX += e.dx
                outY += e.dy
            }
        }
        ingest(0, 5, ended, 0)
        ingest(0, 9, 0, mBegan)
        for _ in 0..<10 { ingest(0, 7, 0, mContinue) }
        ingest(0, 0, 0, mEnd)
        for e in drainToIdle(&r) { outX += e.dx
            outY += e.dy
        }
        XCTAssertEqual(outX, inX, accuracy: 1.0, "horizontal scroll must be preserved (no drift)")
        XCTAssertEqual(outY, inY, accuracy: 1.0, "vertical scroll must be preserved (no drift)")
    }

    func testSubPixelInputAccumulatesAndIsPreserved() {
        var r = ScrollResampler()
        var total = 0.0
        var out = 0.0
        // 30 sub-pixel (0.4 px) Changed samples = 12 px total; must emit ~12 px, not lose the fractions.
        for _ in 0..<30 {
            total += 0.4
            _ = r.ingest(dx: 0, dy: 0.4, scrollPhase: changed, momentumPhase: 0, continuous: true)
            if let e = r.drain() { out += e.dy }
        }
        for e in drainToIdle(&r) { out += e.dy }
        XCTAssertEqual(out, total, accuracy: 1.0, "sub-pixel deltas must accumulate, not vanish")
    }

    // MARK: - 2. Markers pass through 1:1; continuous resamples

    func testMarkersPassThroughImmediately() {
        var r = ScrollResampler()
        // Began is a marker → returned immediately, verbatim.
        let m = r.ingest(dx: 1, dy: 2, scrollPhase: began, momentumPhase: 0, continuous: true)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].scrollPhase, began)
        XCTAssertEqual(m[0].dy, 2)
        // Ended marker too.
        let e = r.ingest(dx: 0, dy: 1, scrollPhase: ended, momentumPhase: 0, continuous: true)
        XCTAssertEqual(e.first?.scrollPhase, ended)
    }

    func testContinuousChangedIsDeferredToDrain() {
        var r = ScrollResampler()
        // A Changed sample returns NO immediate marker — it accumulates for the pump.
        let immediate = r.ingest(dx: 0, dy: 20, scrollPhase: changed, momentumPhase: 0, continuous: true)
        XCTAssertTrue(immediate.isEmpty, "the continuous stream is resampled, not posted inline")
        XCTAssertFalse(r.isIdle, "the residual is pending")
        let first = r.drain()
        XCTAssertNotNil(first, "drain surfaces the accumulated continuous scroll")
        XCTAssertEqual(first?.scrollPhase, changed, "a finger continuation carries scroll-Changed")
        XCTAssertEqual(first?.momentumPhase, 0)
    }

    func testMomentumContinuationCarriesMomentumPhase() {
        var r = ScrollResampler()
        _ = r.ingest(dx: 0, dy: 30, scrollPhase: 0, momentumPhase: mContinue, continuous: true)
        let e = r.drain()
        XCTAssertEqual(e?.scrollPhase, 0)
        XCTAssertEqual(e?.momentumPhase, mContinue, "an inertial coast continuation carries momentum-Continue")
    }

    func testEndMarkerFlushesResidualBeforeEndedNoStrayAfter() {
        // The phase-fidelity bug the review caught: a finger flick leaves residual, then Ended arrives.
        // The leftover MUST flush (as Changed, the residual's phase) BEFORE the Ended marker, and NO
        // stray Changed may drain on a later tick AFTER Ended (a malformed phase-2-after-4).
        var r = ScrollResampler()
        _ = r.ingest(dx: 0, dy: 50, scrollPhase: changed, momentumPhase: 0, continuous: true)
        XCTAssertFalse(r.isIdle, "residual is pending when the finger lifts")
        let endOut = r.ingest(dx: 0, dy: 0, scrollPhase: ended, momentumPhase: 0, continuous: true)
        XCTAssertEqual(endOut.count, 2, "a flush sub-event THEN the Ended marker")
        XCTAssertEqual(endOut[0].scrollPhase, changed, "leftover flushes under its own (Changed) phase")
        XCTAssertGreaterThan(endOut[0].dy, 0, "the flush carries the leftover scroll (no drift)")
        XCTAssertEqual(endOut[1].scrollPhase, ended, "the Ended marker comes AFTER the flush")
        XCTAssertTrue(r.isIdle, "residual is fully flushed at the boundary")
        XCTAssertNil(r.drain(), "NO stray Changed is emitted after Ended")
    }

    func testMomentumEndFlushesUnderMomentumPhase() {
        // Same flush rule for the inertial coast: leftover momentum residual flushes as momentum-Continue
        // before the momentum-End marker, never as a stray after it.
        var r = ScrollResampler()
        _ = r.ingest(dx: 0, dy: 40, scrollPhase: 0, momentumPhase: mContinue, continuous: true)
        let endOut = r.ingest(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: mEnd, continuous: true)
        XCTAssertEqual(endOut.first?.momentumPhase, mContinue, "coast leftover flushes as momentum-Continue")
        XCTAssertEqual(endOut.last?.momentumPhase, mEnd, "momentum-End marker comes after")
        XCTAssertNil(r.drain())
    }

    func testFlickFirstEmitDrainsToLagCap() throws {
        // The lag cap must make a fast flick drain to ~lagCap in the FIRST emit (not crawl at half),
        // so the flick isn't laggy. (A regression making lagCap a no-op would otherwise pass on
        // tick-count alone.)
        var r = ScrollResampler(spread: 2.0, lagCap: 48.0)
        _ = r.ingest(dx: 0, dy: 600, scrollPhase: changed, momentumPhase: 0, continuous: true)
        let first = try XCTUnwrap(r.drain())
        XCTAssertGreaterThanOrEqual(
            first.dy, 600 - 48 - 1, "the first emit must drain down to the lag cap (got \(first.dy))",
        )
    }

    // MARK: - 3. Output RATE — the whole point (steady high rate under continuous input)

    func testContinuousInputProducesAnEmissionNearlyEveryTick() {
        // Model: 250 Hz drain (the host timer) with 125 Hz input (a Changed every 2 ticks). A high
        // fraction of ticks must emit ⇒ the output approaches the tick rate (here ≈250 Hz), which is
        // what drives Chromium to 60 fps. (Direct posting would stay at the ~125 Hz input rate.)
        var r = ScrollResampler()
        var emits = 0
        let ticks = 250
        for t in 0..<ticks {
            if t.isMultiple(of: 2) {
                _ = r.ingest(dx: 0, dy: 8, scrollPhase: changed, momentumPhase: 0, continuous: true)
            }
            if r.drain() != nil { emits += 1 }
        }
        XCTAssertGreaterThanOrEqual(
            emits, 230,
            "continuous input must yield an emission nearly every output tick (got \(emits)/\(ticks))",
        )
    }

    // MARK: - 4. Fast-flick lag is bounded (a big delta drains quickly, not over many ticks)

    func testFastFlickDrainsWithinBoundedTicks() {
        var r = ScrollResampler(spread: 2.0, lagCap: 48.0)
        _ = r.ingest(dx: 0, dy: 600, scrollPhase: changed, momentumPhase: 0, continuous: true)
        var ticks = 0
        while !r.isIdle, ticks < 1000 {
            _ = r.drain()
            ticks += 1
        }
        // With the lag cap, a 600 px flick drains to ≤48 px in the first tick, then halves — so it
        // settles in well under ~12 ticks (≈48 ms at 250 Hz), not 300 ticks of crawling.
        XCTAssertLessThan(ticks, 16, "a fast flick must drain in a bounded number of ticks (got \(ticks))")
    }

    // MARK: - 5. Idle + reset

    func testIdleEmitsNothing() {
        var r = ScrollResampler()
        XCTAssertTrue(r.isIdle)
        XCTAssertNil(r.drain(), "an idle resampler emits nothing")
    }

    func testReversalNetsToZero() {
        var r = ScrollResampler()
        _ = r.ingest(dx: 0, dy: 40, scrollPhase: changed, momentumPhase: 0, continuous: true)
        _ = r.ingest(dx: 0, dy: -40, scrollPhase: changed, momentumPhase: 0, continuous: true)
        var net = 0.0
        for e in drainToIdle(&r) { net += e.dy }
        XCTAssertEqual(net, 0, accuracy: 1.0, "equal-and-opposite scroll nets to zero")
    }

    func testResetDropsResidual() {
        var r = ScrollResampler()
        _ = r.ingest(dx: 0, dy: 50, scrollPhase: changed, momentumPhase: 0, continuous: true)
        XCTAssertFalse(r.isIdle)
        r.reset()
        XCTAssertTrue(r.isIdle, "reset drops the pending residual")
        XCTAssertNil(r.drain())
    }

    // MARK: - 6. Determinism

    func testDeterministic() {
        func run() -> [Double] {
            var r = ScrollResampler()
            var out: [Double] = []
            for k in 0..<20 {
                _ = r.ingest(dx: 0, dy: Double(k % 7 + 1), scrollPhase: changed, momentumPhase: 0, continuous: true)
                if let e = r.drain() { out.append(e.dy) }
            }
            for e in drainToIdle(&r) { out.append(e.dy) }
            return out
        }
        XCTAssertEqual(run(), run(), "the resampler is deterministic")
    }
}
