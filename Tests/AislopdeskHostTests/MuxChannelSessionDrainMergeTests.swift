import AislopdeskProtocol
import AislopdeskTransport
import XCTest
@testable import AislopdeskHost

/// Drain-merge semantics for the host output FIFO (`MuxChannelSession.takeMergedFrame`):
/// adjacent flood chunks coalesce into ONE `.output` frame up to
/// `MuxFlowControl.hostMergeCapBytes` (amortizing seq/encode/send per kernel-sized chunk),
/// while the interactive steady state (single queued chunk) passes through byte-identical
/// with zero added copies. `.exit` is a merge BARRIER so the R5-rank-5 tail ordering
/// (final output strictly before exit) survives the merge. Driven WITHOUT a PTY or
/// running drain via the `_…ForTesting` seams.
final class MuxChannelSessionDrainMergeTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; FIFO driven via seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    func testEmptyFIFOReturnsNil() {
        let session = makeSession()
        XCTAssertNil(session.takeMergedFrame())
    }

    func testAdjacentChunksUnderCapMergeIntoOneFrameInOrder() {
        let session = makeSession()
        let title: WireMessage = .title("t1")
        let bell: WireMessage = .bell
        session.enqueueChunkForTesting(bytes: Data("aaa".utf8), control: [title])
        session.enqueueChunkForTesting(bytes: Data("bb".utf8), control: [])
        session.enqueueChunkForTesting(bytes: Data("cccc".utf8), control: [bell])

        guard case let .output(bytes, byteCount, control)? = session.takeMergedFrame() else {
            XCTFail("expected one merged .output frame")
            return
        }
        XCTAssertEqual(bytes, Data("aaabbcccc".utf8), "bytes concatenate in FIFO order")
        XCTAssertEqual(byteCount, 9)
        XCTAssertEqual(control, [title, bell], "control lists concatenate in pop order")
        XCTAssertNil(session.takeMergedFrame(), "everything was absorbed into one frame")
    }

    func testMergeStopsAtCapOnChunkBoundary() {
        let session = makeSession()
        let cap = MuxFlowControl.hostMergeCapBytes
        let a = Data(repeating: 0x61, count: cap / 3)
        let b = Data(repeating: 0x62, count: cap / 3)
        let c = Data(repeating: 0x63, count: cap / 2) // a+b+c > cap → c starts frame 2
        session.enqueueChunkForTesting(bytes: a)
        session.enqueueChunkForTesting(bytes: b)
        session.enqueueChunkForTesting(bytes: c)

        guard case let .output(first, firstCount, _)? = session.takeMergedFrame() else {
            XCTFail("expected a merged first frame")
            return
        }
        XCTAssertEqual(first, a + b, "merge absorbs whole chunks while the NEXT one still fits")
        XCTAssertEqual(firstCount, a.count + b.count)

        guard case let .output(second, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected the over-cap remainder as frame 2")
            return
        }
        XCTAssertEqual(second, c, "chunks are never split at the cap — boundary is chunk-granular")
        XCTAssertNil(session.takeMergedFrame())
    }

    /// SUPERSEDED SEMANTICS (night review): an oversized chunk used to pass through WHOLE,
    /// but a frame whose WIRE size exceeds window/2 can park its sender permanently (the
    /// header-overhead dead zone). It is now SPLIT at the safe cap; the parts reassemble
    /// byte-identically in order. (Full split coverage in MuxChannelSessionFrameBoundTests.)
    func testSingleOverCapChunkIsSplitAndReassemblesByteIdentical() {
        let session = makeSession()
        let big = Data(repeating: 0x7A, count: MuxFlowControl.hostMergeCapBytes * 2)
        session.enqueueChunkForTesting(bytes: big)
        var reassembled = Data()
        var frames = 0
        while case let .output(bytes, byteCount, _)? = session.takeMergedFrame() {
            XCTAssertLessThanOrEqual(
                bytes.count,
                MuxFlowControl.maxOutputFramePayloadBytes,
                "every emitted frame respects the safe cap",
            )
            XCTAssertEqual(byteCount, bytes.count)
            reassembled.append(bytes)
            frames += 1
        }
        XCTAssertGreaterThan(frames, 1, "an over-cap chunk is split across frames")
        XCTAssertEqual(reassembled, big, "the split reassembles byte-identically, in order")
    }

    func testExitIsAMergeBarrier() {
        let session = makeSession()
        session.enqueueChunkForTesting(bytes: Data("tail-a".utf8))
        session.enqueueChunkForTesting(bytes: Data("tail-b".utf8))
        session.enqueueExitForTesting(code: 7)
        session.enqueueChunkForTesting(bytes: Data("late".utf8))

        guard case let .output(tail, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected the merged tail first")
            return
        }
        XCTAssertEqual(tail, Data("tail-atail-b".utf8), "the final tail merges and stays BEFORE exit")

        guard case let .exit(code)? = session.takeMergedFrame() else {
            XCTFail("expected .exit second — it must never merge with chunks")
            return
        }
        XCTAssertEqual(code, 7)

        guard case let .output(late, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected the post-exit chunk last")
            return
        }
        XCTAssertEqual(late, Data("late".utf8), "a chunk after exit stays after it (barrier both ways)")
    }

    func testExitAtHeadReturnsAlone() {
        let session = makeSession()
        session.enqueueExitForTesting(code: 0)
        guard case .exit(0)? = session.takeMergedFrame() else {
            XCTFail("expected .exit alone at head")
            return
        }
        XCTAssertNil(session.takeMergedFrame())
    }

    // MARK: - Control-out sender queue (FIFO per channel)

    func testControlBatchPreservesPerChannelFIFO() {
        let session = makeSession()
        let t1: WireMessage = .title("t1")
        let running: WireMessage = .commandStatus(.running)
        let t2: WireMessage = .title("t2")
        let idle: WireMessage = .commandStatus(.idle(exitCode: 0, durationMS: 12))
        session.enqueueControlForTesting([t1, running])
        session.enqueueControlForTesting([t2, idle])

        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [t1, running, t2, idle],
            "control messages drain in exact enqueue order (running before its idle)",
        )
        XCTAssertNil(session.takeControlBatchForTesting(), "empty queue → nil (drain re-parks)")
    }

    func testControlQueueNeverExceedsTheBoundOnABulkBatch() {
        // A merged frame can carry MULTIPLE sniffed control messages, so a bulk enqueue that lands the
        // queue ONE-UNDER the cap must not overshoot: the slot-limited append takes only the free slots.
        let session = makeSession()
        let cap = MuxChannelSession.maxControlOutQueuedForTesting
        // Fill to cap-1.
        session.enqueueControlForTesting(Array(repeating: .title("x"), count: cap - 1))
        // A 5-element batch at count==cap-1 would naively land at cap+4 — must clamp to exactly cap.
        session.enqueueControlForTesting(Array(repeating: .commandStatus(.running), count: 5))
        XCTAssertEqual(
            session.takeControlBatchForTesting()?.count,
            cap,
            "the control queue is clamped to the cap, never cap+(K-1)",
        )
    }
}
