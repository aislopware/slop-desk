import XCTest
@testable import SlopDeskVideoClient

/// PURE audio jitter stage: priming, in-order fill/pull, silence on underrun (with re-prime),
/// wrap-aware reorder/duplicate/late handling, high-water drop-oldest, frontier advance, and the
/// producer-side drain/starvation contract the lock-free hand-off pump drives — all
/// deterministic, no AudioUnit / AudioConverter anywhere near a test (repo hang-safety).
final class AudioJitterBufferTests: XCTestCase {
    /// One ~10 ms stereo frame (480 sample-frames × 2 channels) filled with a per-seq marker
    /// value, so pulled samples identify exactly which frame (and ordering) they came from.
    private func frame(_ seq: UInt32, samplesPerFrame: Int = 480, channels: Int = 2) -> [Float] {
        [Float](repeating: Float(seq), count: samplesPerFrame * channels)
    }

    private func makeBuffer(targetDepth: Int = 2, highWater: Int = 8) -> AudioJitterBuffer {
        AudioJitterBuffer(channels: 2, targetDepthFrames: targetDepth, highWaterFrames: highWater)
    }

    func testHoldsSilenceWhilePriming() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        XCTAssertFalse(ring.primed, "one frame < target depth 2 — still priming")
        let out = ring.pull(frameCount: 480)
        XCTAssertEqual(out.count, 960, "frameCount is sample-frames — × channels samples out")
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "priming plays silence, never a half-filled buffer")
        XCTAssertEqual(ring.stats.silenceSamples, 960)
        XCTAssertEqual(ring.stats.underruns, 0, "priming silence is not an underrun")
        XCTAssertEqual(ring.pendingFrames, 1, "the buffered frame is held, not consumed, while priming")
    }

    func testInOrderFillAndPull() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        XCTAssertTrue(ring.primed, "target depth reached")
        XCTAssertEqual(ring.pull(frameCount: 480), frame(1))
        XCTAssertEqual(ring.pull(frameCount: 480), frame(2))
        XCTAssertEqual(ring.stats.silenceSamples, 0)
        XCTAssertEqual(ring.stats.framesPushed, 2)
    }

    func testPartialPullsSpanFrameBoundaries() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        // 3 pulls of 320 sample-frames (640 samples) walk 960+960 samples with one boundary
        // crossing mid-pull — continuity across blocks, no repeats, no gaps.
        XCTAssertEqual(ring.pull(frameCount: 320), [Float](repeating: 1, count: 640))
        let straddling = ring.pull(frameCount: 320)
        XCTAssertEqual(Array(straddling[0..<320]), [Float](repeating: 1, count: 320))
        XCTAssertEqual(Array(straddling[320...]), [Float](repeating: 2, count: 320))
        XCTAssertEqual(ring.pull(frameCount: 320), [Float](repeating: 2, count: 640))
        XCTAssertEqual(ring.stats.silenceSamples, 0)
    }

    func testUnderrunFillsSilenceAndReprimes() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        // Ask for 3 frames' worth with only 2 buffered: real samples then a silent tail.
        let out = ring.pull(frameCount: 1440)
        XCTAssertEqual(Array(out[0..<960]), frame(1))
        XCTAssertEqual(Array(out[960..<1920]), frame(2))
        XCTAssertTrue(out[1920...].allSatisfy { $0 == 0 })
        XCTAssertEqual(ring.stats.underruns, 1)
        XCTAssertEqual(ring.stats.silenceSamples, 960)
        XCTAssertFalse(ring.primed, "an underrun drops back to priming")
        // One new frame is below target depth — still silent; the second re-primes.
        ring.push(seq: 3, samples: frame(3))
        XCTAssertTrue(ring.pull(frameCount: 480).allSatisfy { $0 == 0 })
        ring.push(seq: 4, samples: frame(4))
        XCTAssertTrue(ring.primed)
        XCTAssertEqual(ring.pull(frameCount: 480), frame(3))
    }

    func testReorderedArrivalPlaysInSeqOrder() {
        var ring = makeBuffer()
        ring.push(seq: 2, samples: frame(2))
        ring.push(seq: 1, samples: frame(1))
        XCTAssertEqual(ring.pull(frameCount: 480), frame(1), "a swapped datagram pair still plays in seq order")
        XCTAssertEqual(ring.pull(frameCount: 480), frame(2))
    }

    func testDuplicateSeqDropped() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 1, samples: frame(1))
        XCTAssertEqual(ring.stats.duplicateDropped, 1)
        XCTAssertEqual(ring.pendingFrames, 1)
        XCTAssertEqual(ring.stats.framesPushed, 1, "the duplicate never counted as a push")
    }

    func testLateSeqBehindFrontierDropped() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        _ = ring.pull(frameCount: 960) // both frames fully played — frontier at 2
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        XCTAssertEqual(ring.stats.lateDropped, 2, "at-or-behind the play frontier ⇒ too late to matter")
        XCTAssertEqual(ring.pendingFrames, 0)
    }

    func testSeqOlderThanPartiallyPlayedHeadDropped() {
        var ring = makeBuffer()
        ring.push(seq: 2, samples: frame(2))
        ring.push(seq: 3, samples: frame(3))
        _ = ring.pull(frameCount: 100) // seq 2 has BEGUN playing
        ring.push(seq: 1, samples: frame(1))
        XCTAssertEqual(ring.stats.lateDropped, 1, "cannot insert before a frame already mid-play")
        // Playback continues uninterrupted from the partial head.
        XCTAssertEqual(ring.pull(frameCount: 380), [Float](repeating: 2, count: 760))
    }

    func testHighWaterDropsOldestAndAdvancesFrontier() {
        var ring = makeBuffer(highWater: 8)
        for seq in 1...10 { ring.push(seq: UInt32(seq), samples: frame(UInt32(seq))) }
        XCTAssertEqual(ring.stats.overflowDropped, 2)
        XCTAssertEqual(ring.pendingFrames, 8)
        // The two OLDEST were skipped; playback resumes at 3…
        XCTAssertEqual(ring.pull(frameCount: 480), frame(3))
        // …and a straggling re-send of a dropped seq is late, never re-inserted.
        ring.push(seq: 2, samples: frame(2))
        XCTAssertEqual(ring.stats.lateDropped, 1)
    }

    func testFrontierAdvancesAcrossSkippedSeqs() {
        // Config packets share the tag-6 seq space, and a lost frame leaves a hole — pending
        // seqs are NOT contiguous. The ring plays across gaps seamlessly.
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 3, samples: frame(3))
        XCTAssertEqual(ring.pull(frameCount: 480), frame(1))
        XCTAssertEqual(ring.pull(frameCount: 480), frame(3))
        ring.push(seq: 2, samples: frame(2))
        XCTAssertEqual(ring.stats.lateDropped, 1, "the gap frame arriving after play passed it is late")
    }

    func testSeqOrderingIsWrapAware() {
        var ring = makeBuffer()
        ring.push(seq: UInt32.max, samples: frame(UInt32.max))
        ring.push(seq: 0, samples: frame(0)) // wrapped successor — NEWER than UInt32.max
        XCTAssertTrue(ring.primed)
        XCTAssertEqual(ring.pull(frameCount: 480), frame(UInt32.max))
        XCTAssertEqual(ring.pull(frameCount: 480), frame(0))
        ring.push(seq: UInt32.max, samples: frame(UInt32.max))
        XCTAssertEqual(ring.stats.lateDropped, 1, "pre-wrap seq is behind the wrapped frontier")
    }

    func testClearDropsBufferKeepsFrontier() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        _ = ring.pull(frameCount: 960) // frontier at 2
        ring.push(seq: 3, samples: frame(3))
        ring.clear()
        XCTAssertEqual(ring.pendingFrames, 0)
        XCTAssertFalse(ring.primed, "clear re-primes (a re-enable starts with fresh slack)")
        // The frontier survives: seq is session-scoped monotonic, so post-clear pushes behind it
        // are still late…
        ring.push(seq: 2, samples: frame(2))
        XCTAssertEqual(ring.stats.lateDropped, 1)
        // …and newer ones fill normally.
        ring.push(seq: 4, samples: frame(4))
        ring.push(seq: 5, samples: frame(5))
        XCTAssertEqual(ring.pull(frameCount: 480), frame(4))
    }

    func testPullIntoZeroLengthAndEmptyPushAreInert() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: [])
        XCTAssertEqual(ring.pendingFrames, 0, "an empty sample set is a decoder miss, not a frame")
        XCTAssertEqual(ring.pull(frameCount: 0), [])
        XCTAssertEqual(ring.stats.silenceSamples, 0)
    }

    // MARK: Producer-side drain (the lock-free hand-off pump's contract)

    /// Drains up to `count` samples via `drainAvailable(into:)`, sentinel-prefilled so a
    /// zero-fill (which the producer drain must NEVER do) is detectable.
    private func drain(_ ring: inout AudioJitterBuffer, count: Int) -> (written: Int, out: [Float]) {
        var out = [Float](repeating: .nan, count: count)
        var written = 0
        out.withUnsafeMutableBufferPointer { written = ring.drainAvailable(into: $0) }
        return (written, out)
    }

    func testDrainAvailableHoldsWhilePriming() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        let (written, out) = drain(&ring, count: 960)
        XCTAssertEqual(written, 0, "an unprimed stage hands off nothing — priming silence is the consumer's zero-fill")
        XCTAssertTrue(out.allSatisfy(\.isNaN), "drain must never zero-fill (no conceal on the producer side)")
        XCTAssertEqual(ring.pendingFrames, 1, "the buffered frame is held toward the prime depth")
    }

    func testDrainAvailableMovesAvailableWithoutZeroFillOrReprime() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        // Partial drain (mid-block), then an over-ask: exactly the available samples move,
        // the shortfall stays untouched, and running dry does NOT unprime (that signal is
        // noteConsumerStarved's — the producer running dry just means nothing staged).
        let first = drain(&ring, count: 700)
        XCTAssertEqual(first.written, 700)
        XCTAssertEqual(Array(first.out[0..<700]), [Float](repeating: 1, count: 700))
        let rest = drain(&ring, count: 2000)
        XCTAssertEqual(rest.written, 1220, "960 + 960 − 700 staged samples remained")
        XCTAssertEqual(Array(rest.out[0..<260]), [Float](repeating: 1, count: 260))
        XCTAssertEqual(Array(rest.out[260..<1220]), [Float](repeating: 2, count: 960))
        XCTAssertTrue(rest.out[1220...].allSatisfy(\.isNaN))
        XCTAssertTrue(ring.primed, "running dry on the producer side is not an underrun")
        XCTAssertEqual(ring.stats.underruns, 0)
        XCTAssertEqual(ring.stats.silenceSamples, 0)
    }

    func testDrainAvailableAdvancesPlayFrontier() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        _ = drain(&ring, count: 1920) // both blocks fully handed off — frontier at 2
        ring.push(seq: 2, samples: frame(2))
        XCTAssertEqual(ring.stats.lateDropped, 1, "a re-send of a fully handed-off seq is late, exactly like pull")
    }

    func testDropOldestPendingSkipsForwardLikeOverflow() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        ring.push(seq: 3, samples: frame(3))
        _ = drain(&ring, count: 100) // seq 1 has BEGUN handing off — a partial head still drops whole
        ring.dropOldestPending()
        XCTAssertEqual(ring.stats.overflowDropped, 1)
        XCTAssertEqual(ring.pendingFrames, 2)
        XCTAssertTrue(ring.primed, "a depth-bound shed is a skip forward, not an underrun — no re-prime")
        XCTAssertEqual(ring.stats.underruns, 0)
        XCTAssertEqual(drain(&ring, count: 960).out, frame(2), "playback resumes at the next frame boundary")
        // The frontier advanced past the dropped seq: a straggling re-send is late, never re-inserted.
        ring.push(seq: 1, samples: frame(1))
        XCTAssertEqual(ring.stats.lateDropped, 1)
    }

    func testDropOldestPendingWithNothingPendingIsInert() {
        var ring = makeBuffer()
        ring.dropOldestPending()
        XCTAssertEqual(ring.stats.overflowDropped, 0)
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        _ = drain(&ring, count: 1920) // both blocks consumed, awaiting push-side reclaim
        ring.dropOldestPending()
        XCTAssertEqual(
            ring.stats.overflowDropped,
            0,
            "consumed-awaiting-reclaim blocks are not pending — nothing to drop",
        )
        XCTAssertEqual(ring.pendingFrames, 0)
    }

    func testNoteConsumerStarvedDropsBackToPriming() {
        var ring = makeBuffer()
        ring.push(seq: 1, samples: frame(1))
        ring.push(seq: 2, samples: frame(2))
        _ = drain(&ring, count: 1920)
        ring.noteConsumerStarved()
        XCTAssertEqual(ring.stats.underruns, 1)
        XCTAssertFalse(ring.primed, "consumer starvation re-primes so playback resumes with full slack")
        ring.noteConsumerStarved()
        XCTAssertEqual(ring.stats.underruns, 1, "starvation while already priming never double-counts")
        // Pending frames re-count toward the re-prime.
        ring.push(seq: 3, samples: frame(3))
        XCTAssertEqual(drain(&ring, count: 960).written, 0, "one frame < target depth — still priming")
        ring.push(seq: 4, samples: frame(4))
        XCTAssertTrue(ring.primed)
        XCTAssertEqual(drain(&ring, count: 960).out, frame(3))
    }
}
