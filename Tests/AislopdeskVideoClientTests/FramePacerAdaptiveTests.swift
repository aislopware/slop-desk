import XCTest
import CoreVideo
@testable import AislopdeskVideoClient

/// Adaptive jitter-buffer wiring in ``FramePacer`` (env `AISLOPDESK_ADAPTIVE_JITTER`). The
/// jitter-GROW path depends on the real monotonic clock (submit folds `currentHostTimeSeconds`)
/// so it is not asserted deterministically here; instead these tests lock in the two CLOCK-FREE
/// invariants that are pure queue mechanics: (1) a transient underrun grows the live depth, and
/// (2) a genuine IDLE re-prime does NOT — the exact idle-vs-underrun discriminator. The OFF path
/// is asserted byte-stable (liveDepth pinned to targetDepth). Existing FramePacerTests cover the
/// full fixed-depth queue policy with adaptive defaulting OFF.
final class FramePacerAdaptiveTests: XCTestCase {

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        precondition(status == kCVReturnSuccess && pb != nil, "CVPixelBufferCreate failed (\(status))")
        return pb!
    }

    func testOffPathKeepsFixedDepth() {
        // adaptive OFF (default): currentDepth must equal targetDepth at all times, regardless of
        // submits / presents / underruns — the byte-identical fixed-depth guarantee.
        let pacer = FramePacer(maxFrameRate: 60, targetDepth: 3, maxDepth: 8, renderCallback: { _ in })
        XCTAssertEqual(pacer.currentDepth, 3)
        let f = (0..<4).map { _ in makePixelBuffer() }
        f.forEach { pacer.submit($0) }
        _ = pacer.frameForVSync()         // prime + present
        _ = pacer.frameForVSync()
        _ = pacer.frameForVSync()
        _ = pacer.frameForVSync()         // drain → underflow
        _ = pacer.frameForVSync()         // more underflow
        XCTAssertEqual(pacer.currentDepth, 3, "OFF ⇒ liveDepth never moves")
    }

    func testTransientUnderrunGrowsDepth() {
        // Prime at depth 2, present both, take ONE empty vsync while STILL PRIMED (a transient dip),
        // then present the next frame → the underrun-grow hook bumps liveDepth to 3.
        let pacer = FramePacer(maxFrameRate: 60, targetDepth: 2, maxDepth: 8, adaptiveJitter: true, renderCallback: { _ in })
        let a = makePixelBuffer(); let b = makePixelBuffer()
        pacer.submit(a); pacer.submit(b)
        XCTAssertTrue(pacer.frameForVSync() === a, "primed ⇒ present oldest")
        XCTAssertTrue(pacer.frameForVSync() === b)
        XCTAssertEqual(pacer.currentDepth, 2, "no underrun yet (presents do not grow)")
        // One empty vsync: underflowRun 1 < liveDepth 2 ⇒ still primed (transient dip, not re-prime).
        XCTAssertTrue(pacer.frameForVSync() === b, "empty vsync re-shows last")
        let c = makePixelBuffer()
        pacer.submit(c)
        XCTAssertTrue(pacer.frameForVSync() === c, "present after the dip")
        // Baseline was 2 (asserted above); a transient underrun grows it. `>=` (not `== 3`) only
        // because the submit-side jitter fold reads the real clock — in a tight test loop that
        // contributes ~0, so this is 3 in practice, but `>=` is robust to any incidental jitter.
        XCTAssertGreaterThanOrEqual(pacer.currentDepth, 3, "a transient underrun grows the buffer")
    }

    func testFloorTransientDipStillGrows() {
        // REGRESSION (floor lockup): at the adaptive floor (liveDepth == 1 — the steady state a clean
        // link drives toward) a SINGLE empty vsync must still be classified as a transient dip → grow,
        // not a re-prime. Constructing with targetDepth == 1 starts the controller at initialDepth 1, so
        // this exercises the floor directly without 180 shrink frames. Before the fix the re-prime gate
        // (max(1, liveDepth) == 1) collided with the transient-dip detector (1 empty vsync): the first
        // empty vsync re-primed (reset underflowRun + wiped the jitter estimator) so noteUnderrun never
        // fired and the buffer pinned at 1 — single-frame-repeat judder with no self-healing.
        let pacer = FramePacer(maxFrameRate: 60, targetDepth: 1, maxDepth: 8, adaptiveJitter: true, renderCallback: { _ in })
        XCTAssertEqual(pacer.currentDepth, 1, "constructed at the floor (initialDepth == targetDepth == 1)")
        let a = makePixelBuffer()
        pacer.submit(a)
        XCTAssertTrue(pacer.frameForVSync() === a, "prime + present at depth 1")
        // ONE empty vsync at the floor: underflowRun 1 < max(2, liveDepth)=2 ⇒ STILL PRIMED (transient
        // dip, not a re-prime), and the jitter estimator is NOT reset.
        XCTAssertTrue(pacer.frameForVSync() === a, "single empty vsync re-shows last (transient dip)")
        let b = makePixelBuffer()
        pacer.submit(b)
        XCTAssertTrue(pacer.frameForVSync() === b, "present after the dip")
        // The dip is recovered as a transient underrun ⇒ the buffer re-inflates off the floor. `>=` (not
        // `== 2`) is robust to the submit-side real-clock jitter fold (≈0 in a tight loop).
        XCTAssertGreaterThanOrEqual(pacer.currentDepth, 2, "a transient dip at the floor must still grow the buffer (no floor lockup)")
    }

    func testFloorSustainedIdleDoesNotGrow() {
        // The OTHER side of the floor discriminator: a SUSTAINED idle at the floor (≥ 2 empty vsyncs ⇒ a
        // real producer stall, since the host idle-skips static frames) must re-prime and NOT inflate the
        // buffer — otherwise every stop→scroll would ratchet the latency up. Two empty vsyncs reach the
        // max(2, liveDepth)=2 re-prime threshold, resetting underflowRun at the priming gate so the next
        // present is not mistaken for a transient dip.
        let pacer = FramePacer(maxFrameRate: 60, targetDepth: 1, maxDepth: 8, adaptiveJitter: true, renderCallback: { _ in })
        let a = makePixelBuffer()
        pacer.submit(a)
        XCTAssertTrue(pacer.frameForVSync() === a, "prime + present at depth 1")
        XCTAssertTrue(pacer.frameForVSync() === a, "idle underflow 1 (still primed)")
        XCTAssertTrue(pacer.frameForVSync() === a, "idle underflow 2 ⇒ re-prime armed")
        let b = makePixelBuffer()
        pacer.submit(b)
        XCTAssertTrue(pacer.frameForVSync() === b, "scroll resumes (re-prime to depth 1 is instant)")
        XCTAssertEqual(pacer.currentDepth, 1, "a real idle at the floor must NOT inflate the buffer")
    }

    func testIdleReprimeDoesNotGrowDepth() {
        // A SUSTAINED idle (empty ≥ liveDepth vsyncs) re-primes; the present that follows must NOT be
        // mistaken for a transient underrun, so the buffer must NOT grow on every stop→scroll.
        let pacer = FramePacer(maxFrameRate: 60, targetDepth: 2, maxDepth: 8, adaptiveJitter: true, renderCallback: { _ in })
        let a = makePixelBuffer(); let b = makePixelBuffer()
        pacer.submit(a); pacer.submit(b)
        XCTAssertTrue(pacer.frameForVSync() === a)   // prime + present
        XCTAssertTrue(pacer.frameForVSync() === b)
        // Idle: 2 empty vsyncs ⇒ underflowRun reaches liveDepth(2) ⇒ primed reset to false.
        XCTAssertTrue(pacer.frameForVSync() === b, "underflow 1")
        XCTAssertTrue(pacer.frameForVSync() === b, "underflow 2 ⇒ re-prime armed (+ jitter reset)")
        XCTAssertEqual(pacer.currentDepth, 2, "idle drain itself does not grow")
        // Scroll resumes: re-prime holds the single frame, then presents once slack is rebuilt — and
        // because underflowRun was reset to 0 at the priming gate, that present is NOT a transient dip.
        let c = makePixelBuffer(); let d = makePixelBuffer()
        pacer.submit(c)
        XCTAssertTrue(pacer.frameForVSync() === b, "re-primed ⇒ hold the single new frame")
        pacer.submit(d)
        XCTAssertTrue(pacer.frameForVSync() === c, "slack rebuilt ⇒ present in order")
        XCTAssertEqual(pacer.currentDepth, 2, "idle re-prime must NOT inflate the buffer")
    }
}
