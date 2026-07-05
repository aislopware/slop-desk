import XCTest
@testable import SlopDeskVideoClient

/// Adaptive playout (2026-06-15): the deadline pacer's jitter buffer auto-tunes to the LIVE network
/// jitter via the rust-core law (`clamp(k·jitter + base, [floor, ceil])`, grow-fast / shrink-slow),
/// so a fixed value isn't hand-tuned per link. Driven through the headless test seams
/// (`notePlayoutJitterForTest` / `playoutDelayMsForTest`) — no display-link; the REAL rust-core law
/// runs through the C ABI, so this also proves the FFI wiring end-to-end.
final class FramePacerAdaptivePlayoutTests: XCTestCase {
    private func makePacer(adaptive: Bool, fixedOverride: Bool = false, seedMs: Double = 10) -> FramePacer {
        FramePacer(
            maxFrameRate: 120,
            targetDepth: 1,
            deadlineMode: true,
            contentFps: 60,
            playoutDelayMs: seedMs,
            adaptivePlayout: adaptive,
            fixedPlayoutOverride: fixedOverride,
        ) { _ in }
    }

    private func converge(_ pacer: FramePacer, jitterMs: Double, steps: Int = 200) {
        for _ in 0..<steps { pacer.notePlayoutJitterForTest(jitterMs / 1000.0) }
    }

    /// The live-rig p50 (~12ms jitter) converges to the known-smooth 13.6ms — reproducing the
    /// hand-tuned 10ms feel with a touch more margin, WITHOUT a hardcoded constant.
    func testValidatedLinkConvergesToHandTunedBand() {
        let pacer = makePacer(adaptive: true)
        converge(pacer, jitterMs: 12)
        XCTAssertEqual(pacer.playoutDelayMsForTest(), 13.6, accuracy: 0.01)
    }

    /// A clean LAN (~2ms jitter) floats down toward the floor (5.6ms), reclaiming ~4ms of latency
    /// that the fixed 10ms wasted.
    func testCleanLanFloatsTowardFloor() {
        let pacer = makePacer(adaptive: true)
        converge(pacer, jitterMs: 2)
        XCTAssertEqual(pacer.playoutDelayMsForTest(), 5.6, accuracy: 0.01)
    }

    /// A pathological link (40ms jitter) inflates but is bounded by the 35ms ceiling.
    func testPathologicalLinkClampsAtCeil() {
        let pacer = makePacer(adaptive: true)
        converge(pacer, jitterMs: 40)
        XCTAssertEqual(pacer.playoutDelayMsForTest(), 35, accuracy: 0.01)
    }

    /// Grow-fast / shrink-slow: a spike inflates immediately, then a clean link DECAYS back toward
    /// the floor (≤2ms per recompute), proving there is no permanent latency ratchet.
    func testGrowsFastShrinksSlowNoRatchet() {
        let pacer = makePacer(adaptive: true, seedMs: 4)
        pacer.notePlayoutJitterForTest(0.030) // target 0.8*30+4 = 28ms — jump up immediately
        XCTAssertEqual(pacer.playoutDelayMsForTest(), 28, accuracy: 0.01)
        converge(pacer, jitterMs: 2, steps: 100) // clean link → decays to floor band
        XCTAssertEqual(pacer.playoutDelayMsForTest(), 5.6, accuracy: 0.01)
    }

    /// An explicit `SLOPDESK_PLAYOUT_MS` (fixedPlayoutOverride) PINS the buffer — the proven A/B
    /// escape hatch is preserved; adaptation never touches it.
    func testFixedOverridePinsTheValue() {
        let pacer = makePacer(adaptive: true, fixedOverride: true, seedMs: 10)
        converge(pacer, jitterMs: 30)
        XCTAssertEqual(pacer.playoutDelayMsForTest(), 10, accuracy: 0.01)
    }

    /// Adaptation OFF leaves the construction-time seed untouched (purely additive default).
    func testAdaptiveOffLeavesSeed() {
        let pacer = makePacer(adaptive: false, seedMs: 10)
        converge(pacer, jitterMs: 30)
        XCTAssertEqual(pacer.playoutDelayMsForTest(), 10, accuracy: 0.01)
    }
}
