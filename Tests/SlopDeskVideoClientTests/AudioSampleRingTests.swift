import XCTest
@testable import SlopDeskVideoClient

/// Lock-free SPSC hand-off ring between the audio decode side and the render callback: bounded
/// produce, wait-free consume (caller zero-fills), wrap-around continuity, flush-skip, and a
/// two-thread hammer proving the acquire/release publication loses/duplicates/reorders nothing.
/// No AudioUnit anywhere near a test (repo hang-safety).
final class AudioSampleRingTests: XCTestCase {
    /// Produces `values` into the ring (as much as fits), returning the committed count.
    private func produce(_ ring: AudioSampleRing, _ values: [Float]) -> Int {
        var offset = 0
        return ring.produce { region in
            let n = min(values.count - offset, region.count)
            for i in 0..<n { region[i] = values[offset + i] }
            offset += n
            return n
        }
    }

    /// Consumes up to `count` samples, returning exactly the copied prefix.
    private func consume(_ ring: AudioSampleRing, count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        var copied = 0
        out.withUnsafeMutableBufferPointer { copied = ring.consume(into: $0) }
        return Array(out[0..<copied])
    }

    func testProduceConsumeRoundTripAcrossWrap() {
        let ring = AudioSampleRing(capacity: 8)
        XCTAssertEqual(produce(ring, [0, 1, 2, 3, 4, 5]), 6)
        XCTAssertEqual(ring.fillLevel, 6)
        XCTAssertEqual(consume(ring, count: 4), [0, 1, 2, 3])
        // 5 more wraps the write index past the storage end — continuity must hold.
        XCTAssertEqual(produce(ring, [6, 7, 8, 9, 10]), 5)
        XCTAssertEqual(ring.fillLevel, 7)
        XCTAssertEqual(consume(ring, count: 7), [4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(ring.fillLevel, 0)
    }

    func testConsumeFromEmptyReturnsNothing() {
        let ring = AudioSampleRing(capacity: 4)
        XCTAssertEqual(consume(ring, count: 4), [], "the shortfall zero-fill is the CALLER's job")
    }

    func testProduceStopsAtCapacity() {
        let ring = AudioSampleRing(capacity: 4)
        XCTAssertEqual(produce(ring, [1, 2, 3, 4, 5, 6]), 4, "a full ring backpressures the producer")
        XCTAssertEqual(produce(ring, [7]), 0)
        XCTAssertEqual(consume(ring, count: 6), [1, 2, 3, 4])
    }

    func testRequestFlushSkipsExactlyTheBufferedSamples() {
        let ring = AudioSampleRing(capacity: 8)
        XCTAssertEqual(produce(ring, [1, 2, 3, 4, 5]), 5)
        ring.requestFlush()
        // Samples produced AFTER the flush request play normally.
        XCTAssertEqual(produce(ring, [6, 7]), 2)
        XCTAssertEqual(consume(ring, count: 8), [6, 7], "the flushed span skips un-copied")
        XCTAssertEqual(ring.fillLevel, 0)
    }

    func testShortfallCountsOnlyUnsatisfiedSamples() {
        let ring = AudioSampleRing(capacity: 8)
        XCTAssertEqual(produce(ring, [1, 2, 3]), 3)
        XCTAssertEqual(consume(ring, count: 3), [1, 2, 3])
        XCTAssertEqual(ring.shortfallSamples, 0, "an exact dry drain concealed nothing — no shortfall")
        XCTAssertEqual(consume(ring, count: 4), [])
        XCTAssertEqual(ring.shortfallSamples, 4, "an empty-ring ask is all shortfall (the caller zero-fills it)")
        XCTAssertEqual(produce(ring, [4, 5]), 2)
        XCTAssertEqual(consume(ring, count: 4), [4, 5])
        XCTAssertEqual(ring.shortfallSamples, 6, "a partial fill adds only the zero-filled tail")
    }

    func testFlushWithNothingBufferedIsInert() {
        let ring = AudioSampleRing(capacity: 4)
        ring.requestFlush()
        XCTAssertEqual(produce(ring, [1, 2]), 2)
        XCTAssertEqual(consume(ring, count: 4), [1, 2])
    }

    /// Consumer-thread result box: written by the ONE consumer thread, read by the test thread
    /// only after `DispatchGroup.wait` establishes happens-after (`@unchecked Sendable` is sound
    /// under that ordering).
    private final class ReceivedBox: @unchecked Sendable {
        var values: [Float] = []
    }

    func testConcurrentHandOffConservesOrder() {
        // SPSC hammer: one producer thread pushes a monotonic ramp through a deliberately tiny
        // ring while a consumer thread drains it. The acquire/release contract must deliver the
        // ramp intact — any lost publication shows as a gap, duplicate, or reorder. Iteration
        // caps keep a broken ring from hanging the suite (the count assert then fails loudly).
        let ring = AudioSampleRing(capacity: 64)
        let total = 100_000
        let group = DispatchGroup()
        let box = ReceivedBox()
        box.values.reserveCapacity(total)
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            var next = 0
            var spins = 0
            while next < total, spins < 100_000_000 {
                let committed = ring.produce { region in
                    let n = min(total - next, region.count)
                    for i in 0..<n { region[i] = Float(next + i) }
                    next += n
                    return n
                }
                if committed == 0 { spins += 1 }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            var out = [Float](repeating: .nan, count: 48)
            var spins = 0
            while box.values.count < total, spins < 100_000_000 {
                var copied = 0
                out.withUnsafeMutableBufferPointer { copied = ring.consume(into: $0) }
                if copied == 0 {
                    spins += 1
                } else {
                    box.values.append(contentsOf: out[0..<copied])
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "hand-off must finish (no wedge)")
        XCTAssertEqual(box.values.count, total)
        for (i, value) in box.values.enumerated() where value != Float(i) {
            XCTFail("sample \(i) arrived as \(value) — the hand-off lost/reordered data")
            break
        }
    }
}
