import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Pins the output-FIFO deque semantics of `MuxChannelSession.takeMergedFrame` across the
/// index-cursor refactor (perf: the detached-backlog drain used to be O(n²) — every pop was
/// an `Array.removeFirst()` memmove, and the over-cap split paid a `removeFirst` + an
/// `insert(at: 0)` per emitted frame; a 64 MiB detached backlog of kernel-sized reads made
/// reattach stall for ~10^11 element shifts).
///
/// The BEHAVIOUR contract must be byte-identical before and after the refactor:
/// - bytes reconstruct exactly, in enqueue order, across merges, over-cap splits, and
///   interleaved enqueue/pop cycles;
/// - every emitted `.output` payload respects `MuxFlowControl.maxOutputFramePayloadBytes`;
/// - an over-cap head's REMAINDER stays strictly ahead of chunks enqueued later;
/// - `.exit` is a merge barrier in both directions;
/// - control lists ride the frame that carries their chunk's first byte (split prefix keeps
///   the chunk's control; the remainder carries none — the pre-refactor pinned behaviour).
///
/// Driven WITHOUT a PTY or running drain via the `…ForTesting` seams (the
/// `MuxChannelSessionDrainMergeTests` pattern).
final class MuxChannelSessionFIFODequeTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; FIFO driven via seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    /// Patterned bytes so any ordering / boundary error changes the reconstruction.
    private func patterned(_ count: Int, seed: UInt8 = 0) -> Data {
        var d = Data(capacity: count)
        for i in 0..<count { d.append(seed &+ UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
        return d
    }

    /// Pops every immediately-available frame, appending `.output` payloads to `into` and
    /// asserting the frame-payload cap on each. Returns the popped frame payloads.
    @discardableResult
    private func drainAll(_ session: MuxChannelSession, into stream: inout Data) -> [Data] {
        var frames: [Data] = []
        while let frame = session.takeMergedFrame() {
            guard case let .output(bytes, byteCount, _) = frame else {
                XCTFail("unexpected non-output frame in drainAll")
                return frames
            }
            XCTAssertEqual(byteCount, bytes.count, "byteCount always matches the payload")
            XCTAssertLessThanOrEqual(
                bytes.count, MuxFlowControl.maxOutputFramePayloadBytes,
                "every emitted frame respects the safe cap",
            )
            stream.append(bytes)
            frames.append(bytes)
        }
        return frames
    }

    // MARK: - Byte-stream + frame-boundary pins

    func testInterleavedEnqueuePopPinsExactByteStreamAndBoundaries() {
        let session = makeSession()
        let cap = MuxFlowControl.maxOutputFramePayloadBytes
        var expected = Data() // every enqueued byte, in enqueue order
        var got = Data()

        // Phase 1: small chunks merge into ONE frame, control lists concatenate in pop order.
        let t1: WireMessage = .title("t1")
        let bell: WireMessage = .bell
        session.enqueueChunkForTesting(bytes: Data("A".utf8), control: [t1])
        session.enqueueChunkForTesting(bytes: Data("BB".utf8), control: [bell])
        expected.append(Data("ABB".utf8))
        guard case let .output(f1, c1, ctl1)? = session.takeMergedFrame() else {
            XCTFail("expected a merged .output frame")
            return
        }
        XCTAssertEqual(f1, Data("ABB".utf8))
        XCTAssertEqual(c1, 3)
        XCTAssertEqual(ctl1, [t1, bell])
        got.append(f1)

        // Phase 2: an over-cap chunk (2·cap + 3) splits at exact cap boundaries; the chunk's
        // control rides the FIRST emitted prefix only.
        let big = patterned(cap * 2 + 3, seed: 5)
        session.enqueueChunkForTesting(bytes: big, control: [t1])
        expected.append(big)
        guard case let .output(p1, _, ctlBig)? = session.takeMergedFrame() else {
            XCTFail("expected split prefix 1")
            return
        }
        XCTAssertEqual(p1, big.prefix(cap), "first split frame is exactly the cap prefix")
        XCTAssertEqual(ctlBig, [t1], "the chunk's control rides the first prefix")
        got.append(p1)

        // Phase 3: INTERLEAVE — enqueue while the split remainder is still at the head.
        // The remainder must stay strictly AHEAD of the later chunk.
        session.enqueueChunkForTesting(bytes: Data("EE".utf8))
        expected.append(Data("EE".utf8))
        guard case let .output(p2, _, ctlP2)? = session.takeMergedFrame() else {
            XCTFail("expected split prefix 2")
            return
        }
        XCTAssertEqual(p2, big.dropFirst(cap).prefix(cap), "second split frame continues the remainder")
        XCTAssertEqual(ctlP2, [], "a split remainder carries no control")
        got.append(p2)
        guard case let .output(tail, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected the 3-byte remainder tail")
            return
        }
        XCTAssertEqual(
            tail, big.suffix(3) + Data("EE".utf8),
            "the final remainder merges with the later-enqueued chunk, remainder first",
        )
        got.append(tail)
        XCTAssertNil(session.takeMergedFrame())

        // Phase 4: exit is a barrier both ways; drain-through preserves order.
        session.enqueueChunkForTesting(bytes: Data("GG".utf8))
        session.enqueueExitForTesting(code: 5)
        session.enqueueChunkForTesting(bytes: Data("HH".utf8))
        expected.append(Data("GGHH".utf8))
        guard case let .output(preExit, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected the pre-exit tail")
            return
        }
        XCTAssertEqual(preExit, Data("GG".utf8), "exit never merges with the chunk before it")
        got.append(preExit)
        guard case .exit(5)? = session.takeMergedFrame() else {
            XCTFail("expected .exit(5) after the tail")
            return
        }
        guard case let .output(postExit, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected the post-exit chunk")
            return
        }
        XCTAssertEqual(postExit, Data("HH".utf8))
        got.append(postExit)
        XCTAssertNil(session.takeMergedFrame())

        XCTAssertEqual(got, expected, "the reconstructed stream is byte-identical to the enqueue order")
    }

    func testRepeatedDrainAndRefillCyclesReconstructExactly() {
        // Exercises head-cursor reset / compaction across many enqueue→drain→empty cycles
        // (the interactive steady state plus small backlogs), with merges every round.
        let session = makeSession()
        for round in 0..<8 {
            var expected = Data()
            for i in 0..<200 {
                let chunk = patterned(3 + (i % 5), seed: UInt8(truncatingIfNeeded: round &* 37 &+ i))
                session.enqueueChunkForTesting(bytes: chunk)
                expected.append(chunk)
            }
            var got = Data()
            drainAll(session, into: &got)
            XCTAssertEqual(got, expected, "round \(round) reconstructs byte-identically")
            XCTAssertNil(session.takeMergedFrame(), "round \(round) fully drained")
        }
    }

    func testAlternatingSingleChunkFastPathIsByteIdentical() {
        // The interactive steady state: one queued chunk per pop, no merge partner.
        let session = makeSession()
        for i in 0..<300 {
            let chunk = patterned(1 + (i % 9), seed: UInt8(truncatingIfNeeded: i))
            session.enqueueChunkForTesting(bytes: chunk)
            guard case let .output(bytes, count, _)? = session.takeMergedFrame() else {
                XCTFail("expected the single chunk back at step \(i)")
                return
            }
            XCTAssertEqual(bytes, chunk, "single-chunk fast path returns the chunk unchanged")
            XCTAssertEqual(count, chunk.count)
            XCTAssertNil(session.takeMergedFrame())
        }
    }

    // MARK: - Perf shape (coarse — generous wall-clock bound, no tight timing)

    func testLargeDetachedBacklogDrainsInLinearTime() {
        // The finding's shape: a detached session accumulates one FIFO entry per PTY read
        // (nothing drains), then reattach pops every entry from the front. With
        // Array.removeFirst per pop this is O(n²) element shifts; the index-cursor deque
        // makes it amortized O(1) per pop. 250k × 16 B entries drain in well under the
        // bound post-fix; the pre-fix O(n²) walk demonstrably blows it (~15 s measured).
        let session = makeSession()
        let entries = 250_000
        let chunk = patterned(16, seed: 9)
        for _ in 0..<entries {
            session.enqueueChunkForTesting(bytes: chunk)
        }
        let start = Date()
        var total = 0
        while let frame = session.takeMergedFrame() {
            guard case let .output(bytes, byteCount, _) = frame else {
                XCTFail("unexpected non-output frame")
                return
            }
            XCTAssertEqual(byteCount, bytes.count)
            total += bytes.count
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(total, entries * chunk.count, "every backlog byte is drained exactly once")
        XCTAssertLessThan(elapsed, 5.0, "backlog drain must be linear, not O(n²) memmove")
    }
}
