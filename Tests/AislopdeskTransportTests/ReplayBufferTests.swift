import XCTest
import AislopdeskProtocol
@testable import AislopdeskTransport

/// Exhaustive unit tests for the pure ``ReplayBuffer`` logic (no networking).
final class ReplayBufferTests: XCTestCase {

    // MARK: Constants / contract

    func testCapsAreContractValues() {
        XCTAssertEqual(ReplayBuffer.maxBackupBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ReplayBuffer.offlineGateBytes, 4 * 1024 * 1024)
    }

    // MARK: Monotonic seq

    func testSeqStartsAtOneAndIsMonotonic() {
        var buffer = ReplayBuffer()
        XCTAssertEqual(buffer.highestSeq, 0)
        XCTAssertEqual(buffer.append(bytes: Data("a".utf8)), 1)
        XCTAssertEqual(buffer.append(bytes: Data("b".utf8)), 2)
        XCTAssertEqual(buffer.append(bytes: Data("c".utf8)), 3)
        XCTAssertEqual(buffer.highestSeq, 3)
    }

    func testEnqueueOutputCompatAPIAgreesWithAppend() {
        var buffer = ReplayBuffer()
        let (seq1, drain1) = buffer.enqueueOutput(Data("x".utf8))
        XCTAssertEqual(seq1, 1)
        XCTAssertEqual(drain1, .bufferedOnly)
        XCTAssertEqual(buffer.highestSeq, 1)
    }

    // MARK: retainedBytes accounting

    func testRetainedBytesEqualsSumOfUnackedBytes() {
        var buffer = ReplayBuffer()
        XCTAssertEqual(buffer.retainedBytes, 0)
        buffer.append(bytes: Data(count: 10))
        buffer.append(bytes: Data(count: 25))
        buffer.append(bytes: Data(count: 5))
        XCTAssertEqual(buffer.retainedBytes, 40)
        buffer.ack(upTo: 2) // drops the 10- and 25-byte entries
        XCTAssertEqual(buffer.retainedBytes, 5)
        buffer.ack(upTo: 3) // drops the last
        XCTAssertEqual(buffer.retainedBytes, 0)
    }

    // MARK: ack semantics — partial, idempotent, monotonic

    func testAckDropsReleasedPrefixOnly() {
        var buffer = ReplayBuffer()
        for i in 1...5 { buffer.append(bytes: Data("\(i)".utf8)) }
        buffer.ack(upTo: 3)
        XCTAssertEqual(buffer.ackedSeq, 3)
        let tail = buffer.messages(after: 0).map(\.seq)
        XCTAssertEqual(tail, [4, 5], "ack(3) must drop seq 1..3 and keep 4..5")
    }

    func testAckIsIdempotent() {
        var buffer = ReplayBuffer()
        for _ in 1...5 { buffer.append(bytes: Data(count: 1)) }
        buffer.ack(upTo: 3)
        let bytesAfterFirstAck = buffer.retainedBytes
        buffer.ack(upTo: 3) // duplicate
        XCTAssertEqual(buffer.retainedBytes, bytesAfterFirstAck)
        XCTAssertEqual(buffer.ackedSeq, 3)
        XCTAssertEqual(buffer.messages(after: 0).map(\.seq), [4, 5])
    }

    func testStaleAckIsNoOp() {
        var buffer = ReplayBuffer()
        for _ in 1...5 { buffer.append(bytes: Data(count: 1)) }
        buffer.ack(upTo: 4)
        buffer.ack(upTo: 2) // stale, lower than acked
        XCTAssertEqual(buffer.ackedSeq, 4, "ackedSeq must only advance")
        XCTAssertEqual(buffer.messages(after: 0).map(\.seq), [5])
    }

    func testAckPastHighestClearsAll() {
        var buffer = ReplayBuffer()
        for _ in 1...3 { buffer.append(bytes: Data(count: 7)) }
        buffer.ack(upTo: 100)
        XCTAssertEqual(buffer.retainedBytes, 0)
        XCTAssertTrue(buffer.messages(after: 0).isEmpty)
        XCTAssertEqual(buffer.append(bytes: Data(count: 1)), 4, "seq still continues from highestSeq")
    }

    // MARK: messages(after:) tail boundaries

    func testMessagesAfterZeroReturnsAll() {
        var buffer = ReplayBuffer()
        for i in 1...4 { buffer.append(bytes: Data("\(i)".utf8)) }
        XCTAssertEqual(buffer.messages(after: 0).map(\.seq), [1, 2, 3, 4])
    }

    func testMessagesAfterLastReturnsNone() {
        var buffer = ReplayBuffer()
        for _ in 1...4 { buffer.append(bytes: Data(count: 1)) }
        XCTAssertTrue(buffer.messages(after: 4).isEmpty)
    }

    func testMessagesAfterMidReturnsExactTailWithBytes() {
        var buffer = ReplayBuffer()
        buffer.append(bytes: Data("one".utf8))
        buffer.append(bytes: Data("two".utf8))
        buffer.append(bytes: Data("three".utf8))
        let tail = buffer.messages(after: 1)
        XCTAssertEqual(tail.map(\.seq), [2, 3])
        XCTAssertEqual(tail.map(\.bytes), [Data("two".utf8), Data("three".utf8)])
    }

    func testReplayWrapsAsOutputMessagesInOrder() {
        var buffer = ReplayBuffer()
        buffer.append(bytes: Data("a".utf8))
        buffer.append(bytes: Data("b".utf8))
        buffer.append(bytes: Data("c".utf8))
        let replay = buffer.replay(after: 1)
        XCTAssertEqual(replay, [
            .output(seq: 2, bytes: Data("b".utf8)),
            .output(seq: 3, bytes: Data("c".utf8)),
        ])
    }

    // MARK: Offline gate transitions + shouldPauseDrain

    func testOnlineBelowGateDoesNotPause() {
        var buffer = ReplayBuffer()
        buffer.isClientOnline = true
        buffer.append(bytes: Data(count: ReplayBuffer.offlineGateBytes - 1))
        XCTAssertFalse(buffer.shouldPauseDrain)
        XCTAssertEqual(buffer.drainState, .bufferedOnly)
    }

    func testOnlineAboveOfflineGateDoesNotPause() {
        // The 4 MiB gate only applies while OFFLINE. Online, only the 64 MiB cap pauses.
        var buffer = ReplayBuffer()
        buffer.isClientOnline = true
        buffer.append(bytes: Data(count: ReplayBuffer.offlineGateBytes + 1))
        XCTAssertFalse(buffer.shouldPauseDrain, "online + above 4MiB gate must not pause (below 64MiB)")
    }

    func testOfflineCrossingGatePauses() {
        var buffer = ReplayBuffer()
        buffer.isClientOnline = false
        buffer.append(bytes: Data(count: ReplayBuffer.offlineGateBytes - 1))
        XCTAssertFalse(buffer.shouldPauseDrain, "just below gate: keep buffering")
        buffer.append(bytes: Data(count: 2)) // now at/over the gate
        XCTAssertTrue(buffer.shouldPauseDrain, "offline + at/over 4MiB gate: pause drain (SKIPPED)")
        XCTAssertEqual(buffer.drainState, .skipped)
    }

    func testGoingOfflineWithLargeBacklogPauses() {
        var buffer = ReplayBuffer()
        buffer.isClientOnline = true
        buffer.append(bytes: Data(count: ReplayBuffer.offlineGateBytes + 100))
        XCTAssertFalse(buffer.shouldPauseDrain)
        buffer.isClientOnline = false
        XCTAssertTrue(buffer.shouldPauseDrain, "flipping offline with backlog over gate must pause")
    }

    func testAckBelowGateResumesAfterOfflinePause() {
        var buffer = ReplayBuffer()
        buffer.isClientOnline = false
        // Two ~2.1 MiB chunks => over the 4 MiB gate.
        let chunk = ReplayBuffer.offlineGateBytes / 2 + 1024
        let s1 = buffer.append(bytes: Data(count: chunk))
        buffer.append(bytes: Data(count: chunk))
        XCTAssertTrue(buffer.shouldPauseDrain)
        // Client (briefly back) acks the first chunk → retained drops below the gate.
        buffer.ack(upTo: s1)
        XCTAssertFalse(buffer.shouldPauseDrain, "ack dropping below gate resumes drain")
    }

    func testComingBackOnlineResumesEvenWithBacklog() {
        var buffer = ReplayBuffer()
        buffer.isClientOnline = false
        buffer.append(bytes: Data(count: ReplayBuffer.offlineGateBytes + 1))
        XCTAssertTrue(buffer.shouldPauseDrain)
        buffer.isClientOnline = true
        XCTAssertFalse(buffer.shouldPauseDrain, "online again (below 64MiB) resumes regardless of 4MiB gate")
    }

    // MARK: Never-drop invariant

    func testUnackedDataIsNeverDroppedToSatisfyGate() {
        var buffer = ReplayBuffer()
        buffer.isClientOnline = false
        // Pile up well past the 4 MiB offline gate without any ack.
        for _ in 0..<6 {
            buffer.append(bytes: Data(count: 1024 * 1024)) // 1 MiB each → 6 MiB
        }
        XCTAssertTrue(buffer.shouldPauseDrain)
        // Every un-acked seq (1..6) must still be replayable — none silently dropped.
        XCTAssertEqual(buffer.messages(after: 0).map(\.seq), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(buffer.retainedBytes, 6 * 1024 * 1024)
    }

    // MARK: Instance-configurable caps (R5 rank 2 — lets the relay wiring be tested at a tiny cap)

    /// `shouldPauseDrain` must honor the INSTANCE caps, not just the 64 MiB / 4 MiB statics — so a tiny
    /// cap exercises the same online-slow-consumer and offline-gate transitions without 64 MiB of heap.
    func testShouldPauseDrainHonorsInstanceCaps() {
        var buf = ReplayBuffer(maxBackupBytes: 100, offlineGateBytes: 40)
        XCTAssertFalse(buf.shouldPauseDrain)
        buf.append(bytes: Data(count: 50))      // retained 50 < 100, online → no pause
        XCTAssertFalse(buf.shouldPauseDrain)
        buf.isClientOnline = false
        XCTAssertTrue(buf.shouldPauseDrain, "offline + retained(50) ≥ offlineGate(40) → pause")
        buf.isClientOnline = true
        XCTAssertFalse(buf.shouldPauseDrain, "back online, retained(50) < maxBackup(100) → no pause")
        buf.append(bytes: Data(count: 60))      // retained 110 ≥ 100 → online slow-consumer pause
        XCTAssertTrue(buf.shouldPauseDrain, "online: retained(110) ≥ maxBackup(100) → pause regardless of online")
        buf.ack(upTo: buf.highestSeq)           // release all → retained 0
        XCTAssertFalse(buf.shouldPauseDrain, "ack released the backlog → resume")
        // The public statics remain the production contract values (unchanged by the instance caps).
        XCTAssertEqual(ReplayBuffer.maxBackupBytes, 64 * 1024 * 1024)
    }
}
