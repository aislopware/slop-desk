import XCTest
import AislopdeskProtocol
import AislopdeskTransport
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
            pty: PTYProcess(),  // unspawned — relay never started; FIFO driven via seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
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
        session._enqueueChunkForTesting(bytes: Data("aaa".utf8), control: [title])
        session._enqueueChunkForTesting(bytes: Data("bb".utf8), control: [])
        session._enqueueChunkForTesting(bytes: Data("cccc".utf8), control: [bell])

        guard case let .output(bytes, byteCount, control)? = session.takeMergedFrame() else {
            return XCTFail("expected one merged .output frame")
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
        let c = Data(repeating: 0x63, count: cap / 2)   // a+b+c > cap → c starts frame 2
        session._enqueueChunkForTesting(bytes: a)
        session._enqueueChunkForTesting(bytes: b)
        session._enqueueChunkForTesting(bytes: c)

        guard case let .output(first, firstCount, _)? = session.takeMergedFrame() else {
            return XCTFail("expected a merged first frame")
        }
        XCTAssertEqual(first, a + b, "merge absorbs whole chunks while the NEXT one still fits")
        XCTAssertEqual(firstCount, a.count + b.count)

        guard case let .output(second, _, _)? = session.takeMergedFrame() else {
            return XCTFail("expected the over-cap remainder as frame 2")
        }
        XCTAssertEqual(second, c, "chunks are never split at the cap — boundary is chunk-granular")
        XCTAssertNil(session.takeMergedFrame())
    }

    func testSingleOverCapChunkPassesThroughUnchanged() {
        let session = makeSession()
        let big = Data(repeating: 0x7A, count: MuxFlowControl.hostMergeCapBytes * 2)
        session._enqueueChunkForTesting(bytes: big)
        guard case let .output(bytes, byteCount, _)? = session.takeMergedFrame() else {
            return XCTFail("expected the oversized chunk as one frame")
        }
        XCTAssertEqual(bytes, big, "an oversized single chunk is passed through byte-identical, never split")
        XCTAssertEqual(byteCount, big.count)
    }

    func testExitIsAMergeBarrier() {
        let session = makeSession()
        session._enqueueChunkForTesting(bytes: Data("tail-a".utf8))
        session._enqueueChunkForTesting(bytes: Data("tail-b".utf8))
        session._enqueueExitForTesting(code: 7)
        session._enqueueChunkForTesting(bytes: Data("late".utf8))

        guard case let .output(tail, _, _)? = session.takeMergedFrame() else {
            return XCTFail("expected the merged tail first")
        }
        XCTAssertEqual(tail, Data("tail-atail-b".utf8), "the final tail merges and stays BEFORE exit")

        guard case let .exit(code)? = session.takeMergedFrame() else {
            return XCTFail("expected .exit second — it must never merge with chunks")
        }
        XCTAssertEqual(code, 7)

        guard case let .output(late, _, _)? = session.takeMergedFrame() else {
            return XCTFail("expected the post-exit chunk last")
        }
        XCTAssertEqual(late, Data("late".utf8), "a chunk after exit stays after it (barrier both ways)")
    }

    func testExitAtHeadReturnsAlone() {
        let session = makeSession()
        session._enqueueExitForTesting(code: 0)
        guard case .exit(0)? = session.takeMergedFrame() else {
            return XCTFail("expected .exit alone at head")
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
        session._enqueueControlForTesting([t1, running])
        session._enqueueControlForTesting([t2, idle])

        XCTAssertEqual(session._takeControlBatchForTesting(), [t1, running, t2, idle],
                       "control messages drain in exact enqueue order (running before its idle)")
        XCTAssertNil(session._takeControlBatchForTesting(), "empty queue → nil (drain re-parks)")
    }
}
