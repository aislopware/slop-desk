import XCTest
@testable import SlopDeskVideoClient

/// Producer-side pump: jitter-stage policy (priming, reorder, high-water, frontier) feeding the
/// lock-free hand-off ring, plus the producer-side starvation detection that replaces the old
/// pull-side underrun check. Behavior parity with the pull surface is pinned frame-for-frame.
/// No AudioUnit anywhere near a test (repo hang-safety).
final class AudioPlaybackPumpTests: XCTestCase {
    /// One small stereo frame (60 sample-frames × 2 channels) marked with its seq.
    private func frame(_ seq: UInt32) -> [Float] {
        [Float](repeating: Float(seq), count: 120)
    }

    /// Pump over a ring sized like the engine's: the stage's high-water worth of frames.
    private func makePump(ringFrames: Int = 8) -> AudioPlaybackPump {
        AudioPlaybackPump(
            stage: AudioJitterBuffer(channels: 2),
            ring: AudioSampleRing(capacity: ringFrames * 120),
            samplesPerFrame: 120,
        )
    }

    /// Total client-side depth — staged samples plus the hand-off fill: the listener's backlog.
    private func combinedDepth(_ pump: AudioPlaybackPump) -> Int {
        pump.stage.availableSamples + pump.ring.fillLevel
    }

    /// Drains up to `count` samples from the pump's hand-off ring (the render side).
    private func consume(_ pump: AudioPlaybackPump, count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        var copied = 0
        out.withUnsafeMutableBufferPointer { copied = pump.ring.consume(into: $0) }
        return Array(out[0..<copied])
    }

    func testPrimingHoldsHandOffUntilTargetDepth() {
        var pump = makePump()
        pump.enqueue(seq: 1, samples: frame(1))
        XCTAssertEqual(pump.ring.fillLevel, 0, "one frame < target depth 2 — nothing hands off yet")
        XCTAssertEqual(consume(pump, count: 120), [], "the consumer zero-fills priming silence itself")
        pump.enqueue(seq: 2, samples: frame(2))
        XCTAssertEqual(pump.ring.fillLevel, 240, "priming complete — both staged frames hand off")
        XCTAssertEqual(consume(pump, count: 120), frame(1))
        XCTAssertEqual(consume(pump, count: 120), frame(2))
    }

    func testReorderedArrivalHandsOffInSeqOrder() {
        var pump = makePump()
        pump.enqueue(seq: 2, samples: frame(2))
        pump.enqueue(seq: 1, samples: frame(1))
        XCTAssertEqual(consume(pump, count: 120), frame(1), "a swapped datagram pair still plays in seq order")
        XCTAssertEqual(consume(pump, count: 120), frame(2))
    }

    func testSteadyStateFlowsThroughTheRing() {
        var pump = makePump()
        pump.enqueue(seq: 1, samples: frame(1))
        pump.enqueue(seq: 2, samples: frame(2))
        // One frame in, one frame out — the render cadence. No underruns, no drops, no silence.
        for seq: UInt32 in 3...50 {
            pump.enqueue(seq: seq, samples: frame(seq))
            XCTAssertEqual(consume(pump, count: 120), frame(seq - 2))
        }
        XCTAssertEqual(pump.stage.stats.underruns, 0)
        XCTAssertEqual(pump.stage.stats.overflowDropped, 0)
        XCTAssertEqual(pump.stage.stats.framesPushed, 50)
    }

    func testConsumerStarvationReprimesAndResumes() {
        var pump = makePump()
        pump.enqueue(seq: 1, samples: frame(1))
        pump.enqueue(seq: 2, samples: frame(2))
        XCTAssertEqual(
            consume(pump, count: 480).count,
            240,
            "the render side drained the ring dry (zero-filling the rest)",
        )
        // The next push detects the starvation producer-side: back to priming with full slack.
        pump.enqueue(seq: 3, samples: frame(3))
        XCTAssertEqual(pump.stage.stats.underruns, 1)
        XCTAssertEqual(pump.ring.fillLevel, 0, "one frame < target depth — re-priming holds it staged")
        pump.enqueue(seq: 4, samples: frame(4))
        XCTAssertEqual(pump.stage.stats.underruns, 1, "one starvation episode counts once")
        XCTAssertEqual(consume(pump, count: 120), frame(3))
        XCTAssertEqual(consume(pump, count: 120), frame(4))
    }

    func testRingBackpressureStagesFramesAndHighWaterBounds() {
        // A stalled consumer (never consumes): the ring fills to capacity, later frames stay
        // staged, and past the stage's high-water the OLDEST staged frames drop — total
        // in-flight audio stays bounded exactly as the jitter policy demands.
        var pump = makePump(ringFrames: 2)
        for seq: UInt32 in 1...16 { pump.enqueue(seq: seq, samples: frame(seq)) }
        XCTAssertEqual(pump.ring.fillLevel, 240, "the ring holds its capacity worth")
        XCTAssertLessThanOrEqual(pump.stage.pendingFrames, 8, "high-water bounds the staged backlog")
        XCTAssertGreaterThan(pump.stage.stats.overflowDropped, 0, "the oldest staged frames were skipped forward")
    }

    func testExactDryDrainWithoutZeroFillIsNotStarvation() {
        var pump = makePump()
        pump.enqueue(seq: 1, samples: frame(1))
        pump.enqueue(seq: 2, samples: frame(2))
        // The consumer drains EXACTLY what is buffered — no shortfall, no conceal silence. The
        // ring being empty at the next push is pure phase alignment (~10 ms pushes vs ~10.7 ms
        // render quanta) and the listener missed nothing.
        XCTAssertEqual(consume(pump, count: 240).count, 240)
        XCTAssertEqual(pump.ring.fillLevel, 0)
        pump.enqueue(seq: 3, samples: frame(3))
        XCTAssertEqual(pump.stage.stats.underruns, 0, "an exact dry drain is not an underrun")
        XCTAssertEqual(pump.ring.fillLevel, 120, "no re-prime — the fresh frame hands off immediately")
        XCTAssertEqual(consume(pump, count: 120), frame(3), "playback continues without inserted silence")
    }

    // MARK: Total-depth bound (stage + ring combined)

    func testSustainedExactRateHoldsCombinedDepthAtTarget() {
        var pump = makePump()
        pump.enqueue(seq: 1, samples: frame(1))
        pump.enqueue(seq: 2, samples: frame(2))
        for seq: UInt32 in 3...60 {
            pump.enqueue(seq: seq, samples: frame(seq))
            XCTAssertEqual(consume(pump, count: 120), frame(seq - 2))
            XCTAssertLessThanOrEqual(combinedDepth(pump), 8 * 120, "combined stage+ring depth is the latency bound")
        }
        XCTAssertEqual(combinedDepth(pump), 2 * 120, "steady state sits at the target depth, not the ring's size")
        XCTAssertEqual(pump.stage.stats.overflowDropped, 0, "in-rate flow never trips the depth bound")
        XCTAssertEqual(pump.stage.stats.underruns, 0)
    }

    func testBurstBeyondHighWaterDropsOldestStagedAndBoundsDepth() {
        // A stalled consumer while pushes keep arriving: total in-flight audio (staged + already
        // handed off) must stay bounded by the high-water budget — the ring must never become a
        // second, undroppable backlog on top of the stage's.
        var pump = makePump()
        for seq: UInt32 in 1...16 { pump.enqueue(seq: seq, samples: frame(seq)) }
        XCTAssertLessThanOrEqual(combinedDepth(pump), 8 * 120, "a burst can never grow combined depth past high-water")
        XCTAssertGreaterThan(pump.stage.stats.overflowDropped, 0, "the bound sheds oldest STAGED frames")
        // The shed is a skip-forward: a re-send of a dropped seq is late, never re-inserted.
        pump.enqueue(seq: 12, samples: frame(12))
        XCTAssertEqual(pump.stage.stats.lateDropped, 1)
        // Samples already committed to the ring are the consumer's — playback resumes from them.
        XCTAssertEqual(consume(pump, count: 120), frame(1))
    }

    func testCombinedDepthConvergesToTargetAfterBurst() {
        var pump = makePump()
        for seq: UInt32 in 1...16 { pump.enqueue(seq: seq, samples: frame(seq)) }
        // Exact-rate flow resumes after the burst: in-flow matches out-flow, so whatever depth
        // the burst left is the depth that PERSISTS — the bound must already have shed the
        // backlog back to target, or the added latency would be permanent.
        for seq: UInt32 in 17...40 {
            pump.enqueue(seq: seq, samples: frame(seq))
            XCTAssertEqual(consume(pump, count: 120).count, 120, "the consumer never runs dry post-shed")
        }
        XCTAssertEqual(combinedDepth(pump), 2 * 120, "post-burst steady state re-converges to the target depth")
        XCTAssertEqual(pump.stage.stats.underruns, 0, "shedding the backlog never starves the consumer")
    }

    func testFlushDropsStagedAndHandedOffAudioButKeepsFrontier() {
        var pump = makePump()
        pump.enqueue(seq: 1, samples: frame(1))
        pump.enqueue(seq: 2, samples: frame(2))
        XCTAssertEqual(pump.ring.fillLevel, 240)
        pump.flush()
        XCTAssertEqual(consume(pump, count: 480), [], "flush silences the hand-off NOW, not after a drain")
        XCTAssertEqual(pump.stage.pendingFrames, 0)
        // The frontier survives the flush: a straggler behind it is late, newer frames flow.
        pump.enqueue(seq: 2, samples: frame(2))
        XCTAssertEqual(pump.stage.stats.lateDropped, 1)
        pump.enqueue(seq: 3, samples: frame(3))
        pump.enqueue(seq: 4, samples: frame(4))
        XCTAssertEqual(consume(pump, count: 120), frame(3))
        XCTAssertEqual(consume(pump, count: 120), frame(4))
        // A flush is not an underrun — the starvation check must not misfire on the next push.
        XCTAssertEqual(pump.stage.stats.underruns, 0)
    }
}
