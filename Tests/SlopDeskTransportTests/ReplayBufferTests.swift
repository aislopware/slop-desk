import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

/// Exhaustive unit tests for the pure ``ReplayBuffer`` logic (no networking).
final class ReplayBufferTests: XCTestCase {
    // MARK: Constants / contract

    func testCapsAreContractValues() {
        XCTAssertEqual(ReplayBuffer.maxBackupBytes, 256 * 1024 * 1024)
        XCTAssertEqual(ReplayBuffer.offlineGateBytes, 64 * 1024 * 1024)
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
        // messages(after: ackedSeq) returns ONLY the un-acked tail (seq > 3). With scrollback
        // enabled, messages(after: 0) would also include the ring (seq 1..3); use ackedSeq here
        // to isolate un-acked behavior. The ring content is separately tested in the scrollback suite.
        let tail = buffer.messages(after: buffer.ackedSeq).map(\.seq)
        XCTAssertEqual(tail, [4, 5], "ack(3) must remove seq 1..3 from un-acked entries")
    }

    func testAckIsIdempotent() {
        var buffer = ReplayBuffer()
        for _ in 1...5 { buffer.append(bytes: Data(count: 1)) }
        buffer.ack(upTo: 3)
        let bytesAfterFirstAck = buffer.retainedBytes
        buffer.ack(upTo: 3) // duplicate
        XCTAssertEqual(buffer.retainedBytes, bytesAfterFirstAck)
        XCTAssertEqual(buffer.ackedSeq, 3)
        // Un-acked tail only (after: ackedSeq); ring is separately verified in the scrollback suite.
        XCTAssertEqual(buffer.messages(after: buffer.ackedSeq).map(\.seq), [4, 5])
    }

    func testStaleAckIsNoOp() {
        var buffer = ReplayBuffer()
        for _ in 1...5 { buffer.append(bytes: Data(count: 1)) }
        buffer.ack(upTo: 4)
        buffer.ack(upTo: 2) // stale, lower than acked
        XCTAssertEqual(buffer.ackedSeq, 4, "ackedSeq must only advance")
        // Un-acked tail only; ring (seq 1..4) is accessible via messages(after: 0).
        XCTAssertEqual(buffer.messages(after: buffer.ackedSeq).map(\.seq), [5])
    }

    func testAckPastHighestClearsAll() {
        var buffer = ReplayBuffer()
        for _ in 1...3 { buffer.append(bytes: Data(count: 7)) }
        buffer.ack(upTo: 100)
        XCTAssertEqual(buffer.retainedBytes, 0)
        // Un-acked tail is empty; acked history lives in the scrollback ring and IS returned
        // by messages(after: 0). Use scrollbackBytes: 0 to verify the no-ring contract.
        XCTAssertTrue(
            buffer.messages(after: buffer.ackedSeq).isEmpty,
            "no un-acked entries remain after acking past highestSeq",
        )
        var noRing = ReplayBuffer(scrollbackBytes: 0)
        for _ in 1...3 { noRing.append(bytes: Data(count: 7)) }
        noRing.ack(upTo: 100)
        XCTAssertTrue(
            noRing.messages(after: 0).isEmpty,
            "with scrollback disabled, acking past highestSeq leaves nothing in messages(after:0)",
        )
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
        // Instance caps (tiny) — the invariant is cap-relative, and the production offline gate
        // is now 64 MiB (heap-hostile to exceed in a unit test).
        var buffer = ReplayBuffer(maxBackupBytes: 1000, offlineGateBytes: 400)
        buffer.isClientOnline = false
        // Pile up well past the offline gate without any ack.
        for _ in 0..<6 {
            buffer.append(bytes: Data(count: 100)) // 600 total > 400 gate
        }
        XCTAssertTrue(buffer.shouldPauseDrain)
        // Every un-acked seq (1..6) must still be replayable — none silently dropped.
        XCTAssertEqual(buffer.messages(after: 0).map(\.seq), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(buffer.retainedBytes, 600)
    }

    // MARK: Instance-configurable caps (R5 rank 2 — lets the relay wiring be tested at a tiny cap)

    /// `shouldPauseDrain` must honor the INSTANCE caps, not just the 64 MiB / 4 MiB statics — so a tiny
    /// cap exercises the same online-slow-consumer and offline-gate transitions without 64 MiB of heap.
    func testShouldPauseDrainHonorsInstanceCaps() {
        var buf = ReplayBuffer(maxBackupBytes: 100, offlineGateBytes: 40)
        XCTAssertFalse(buf.shouldPauseDrain)
        buf.append(bytes: Data(count: 50)) // retained 50 < 100, online → no pause
        XCTAssertFalse(buf.shouldPauseDrain)
        buf.isClientOnline = false
        XCTAssertTrue(buf.shouldPauseDrain, "offline + retained(50) ≥ offlineGate(40) → pause")
        buf.isClientOnline = true
        XCTAssertFalse(buf.shouldPauseDrain, "back online, retained(50) < maxBackup(100) → no pause")
        buf.append(bytes: Data(count: 60)) // retained 110 ≥ 100 → online slow-consumer pause
        XCTAssertTrue(buf.shouldPauseDrain, "online: retained(110) ≥ maxBackup(100) → pause regardless of online")
        buf.ack(upTo: buf.highestSeq) // release all → retained 0
        XCTAssertFalse(buf.shouldPauseDrain, "ack released the backlog → resume")
        // The public statics remain the production contract values (unchanged by the instance caps).
        XCTAssertEqual(ReplayBuffer.maxBackupBytes, 256 * 1024 * 1024)
    }

    // MARK: Scrollback ring — default constant

    func testDefaultScrollbackBytesIsCorrect() {
        XCTAssertEqual(ReplayBuffer.defaultScrollbackBytes, 64 * 1024 * 1024)
    }

    // MARK: Scrollback ring — retention up to cap

    /// Acked entries move into the scrollback ring and are visible via messages(after:0).
    func testAckedEntriesMovedIntoScrollbackRing() {
        var buf = ReplayBuffer(scrollbackBytes: 1024)
        let s1 = buf.append(bytes: Data("hello".utf8))
        let s2 = buf.append(bytes: Data("world".utf8))
        buf.append(bytes: Data("tail".utf8))
        buf.ack(upTo: s2)
        // un-acked entries: only seq 3 remains
        XCTAssertEqual(buf.retainedBytes, 4, "only the un-acked 'tail' entry counts toward retainedBytes")
        // scrollback ring holds the two acked entries
        XCTAssertEqual(buf.scrollbackRingSeqsForTesting, [s1, s2])
        // cold replay (after:0) returns ring + live tail in order
        let msgs = buf.messages(after: 0)
        XCTAssertEqual(msgs.map(\.seq), [1, 2, 3])
        XCTAssertEqual(msgs[0].bytes, Data("hello".utf8))
        XCTAssertEqual(msgs[1].bytes, Data("world".utf8))
        XCTAssertEqual(msgs[2].bytes, Data("tail".utf8))
    }

    /// messages(after:0) when everything is acked returns only the scrollback ring.
    func testColdReplayAfterFullAckReturnsScrollbackOnly() {
        var buf = ReplayBuffer(scrollbackBytes: 512)
        buf.append(bytes: Data("a".utf8))
        buf.append(bytes: Data("b".utf8))
        buf.ack(upTo: buf.highestSeq)
        XCTAssertEqual(buf.retainedBytes, 0)
        let msgs = buf.messages(after: 0)
        XCTAssertEqual(msgs.map(\.seq), [1, 2])
    }

    // MARK: Scrollback ring — eviction stays within cap

    func testScrollbackRingEvictsOldestToStayWithinCap() {
        // 10-byte cap; each entry is 4 bytes ("abcd", "efgh", "ijkl").
        var buf = ReplayBuffer(scrollbackBytes: 10)
        let s1 = buf.append(bytes: Data("abcd".utf8)) // 4 B
        let s2 = buf.append(bytes: Data("efgh".utf8)) // 4 B
        let s3 = buf.append(bytes: Data("ijkl".utf8)) // 4 B
        buf.ack(upTo: s1) // ring: [s1=4B] → 4B total, under cap
        XCTAssertTrue(buf.scrollbackRingBytesForTesting <= 10)
        buf.ack(upTo: s2) // ring: [s1, s2] → 8B, still under cap
        XCTAssertTrue(buf.scrollbackRingBytesForTesting <= 10)
        buf.ack(upTo: s3) // adding s3 (4B) → would be 12B, must evict s1 → 8B
        XCTAssertTrue(
            buf.scrollbackRingBytesForTesting <= 10,
            "ring must not exceed scrollbackBytesCap after eviction",
        )
        // s1 must have been evicted; s2 and s3 (or a tail including them) are still available
        let seqs = buf.scrollbackRingSeqsForTesting
        XCTAssertFalse(seqs.contains(s1), "oldest entry must be evicted to satisfy cap")
        XCTAssertTrue(seqs.contains(s3), "newest acked entry must survive")
    }

    // MARK: Scrollback ring — line-aligned eviction

    /// After eviction the new oldest ring entry must not start mid-line; the trim must advance
    /// past the nearest \n so a cold replay starts on a clean line boundary.
    func testScrollbackRingEvictionIsLineAligned() {
        // Cap = 10 bytes. We feed:
        //   s1 = "line1\nli"   (8 bytes, contains a \n at index 5)
        //   s2 = "ne2\n"       (4 bytes)
        // After acking s1, ring holds s1 (8 B ≤ 10 B cap → no eviction yet).
        // After acking s2 (ring = s1 + s2 = 12 B > 10 B → evict s1 (8 B) → 4 B, under cap; no trim needed).
        // Use a tighter scenario: cap = 6, entries overlap the boundary.
        //   s1 = "AB\nCD"  (5 bytes, \n at index 2)
        //   s2 = "EF"      (2 bytes)
        // Ack s1 → ring = [s1=5B] ≤ 6B cap → no eviction.
        // Ack s2 → ring = [s1=5B, s2=2B] = 7B > 6B cap → evict s1 → ring = [s2=2B] = 2B ≤ 6B;
        //   now trim the NEW oldest (s2 = "EF", no \n) → left intact.
        // So trim fires when eviction leaves us at/under cap and the new oldest starts mid-line.
        // Demonstrate the trim:
        //   s1 = "AB\nCD"    (5 bytes, \n at 2; after trimming: "CD" remains if s1 is now oldest after eviction)
        // Better: two entries where the new-oldest (after evicting s1) is "half\nrest" and we expect trim.
        //   cap = 8
        //   s1 = "AAAA"    (4 bytes)
        //   s2 = "BB\nCC"  (5 bytes, \n at index 2)
        // Ack s1 → ring = [s1=4B] ≤ 8B → no evict.
        // Ack s2 → ring = [s1=4, s2=5] = 9 > 8 → evict s1 → ring = [s2=5] = 5 ≤ 8 → trim s2:
        //   s2 = "BB\nCC": \n at index 2 → afterNL index 3 → trimmed = "CC" (2 bytes); removed = 3.
        //   ring = [entry(seq:s2, bytes:"CC")] with scrollbackBytes = 2.
        var buf = ReplayBuffer(scrollbackBytes: 8)
        let s1 = buf.append(bytes: Data("AAAA".utf8)) // 4 bytes
        let s2 = buf.append(bytes: Data("BB\nCC".utf8)) // 5 bytes, \n at index 2
        _ = buf.append(bytes: Data("live".utf8)) // un-acked, stays in entries
        buf.ack(upTo: s1)
        // s1 (4B) in ring, under cap (8B) — no eviction yet
        XCTAssertEqual(buf.scrollbackRingSeqsForTesting, [s1])
        buf.ack(upTo: s2)
        // s1(4) + s2(5) = 9 > 8 → evict s1 → ring=[s2(5)] = 5 ≤ 8 → trim s2 from 'BB\nCC' → 'CC'
        XCTAssertEqual(
            buf.scrollbackRingSeqsForTesting,
            [s2],
            "s1 must be evicted; s2 (trimmed) must survive",
        )
        let oldest = buf.scrollbackRingOldestBytesForTesting
        XCTAssertEqual(
            oldest,
            Data("CC".utf8),
            "line-aligned trim must advance past the \\n in the new oldest entry",
        )
        XCTAssertEqual(buf.scrollbackRingBytesForTesting, 2)
    }

    // MARK: Scrollback ring — offline gate is unaffected

    /// The offline gate and 64 MiB ceiling must continue to use ONLY retainedBytes (un-acked),
    /// not scrollbackBytes. A full scrollback ring must not trigger shouldPauseDrain.
    func testScrollbackRingDoesNotAffectOfflineGate() {
        // Use a tiny scrollback cap (8 bytes) but a standard offline gate (4 MiB).
        var buf = ReplayBuffer(maxBackupBytes: 64 * 1024, offlineGateBytes: 32 * 1024, scrollbackBytes: 8)
        buf.isClientOnline = false
        // Append two 3-byte entries and ack them → they move into the scrollback ring
        buf.append(bytes: Data("abc".utf8))
        buf.append(bytes: Data("def".utf8))
        buf.ack(upTo: buf.highestSeq)
        // retainedBytes is 0 (all acked), scrollbackBytes = 6 (under tiny cap of 8)
        XCTAssertEqual(buf.retainedBytes, 0)
        XCTAssertFalse(
            buf.shouldPauseDrain,
            "scrollback ring bytes must NOT contribute to shouldPauseDrain",
        )
    }

    // MARK: Scrollback ring — warm reconnect returns only un-acked tail

    func testWarmReconnectSeesOnlyUnackedTail() {
        var buf = ReplayBuffer(scrollbackBytes: 512)
        buf.append(bytes: Data("A".utf8)) // seq 1
        buf.append(bytes: Data("B".utf8)) // seq 2
        buf.append(bytes: Data("C".utf8)) // seq 3
        buf.ack(upTo: 2) // seqs 1+2 → scrollback ring; seq 3 stays in entries
        // Warm reconnect: client already received seq 2; only seq 3 is new.
        let msgs = buf.messages(after: 2)
        XCTAssertEqual(msgs.map(\.seq), [3], "warm reconnect must return only seq 3 (un-acked tail)")
    }

    // MARK: Scrollback ring — scrollbackBytes == 0 disables ring

    func testScrollbackDisabledWhenCapIsZero() {
        var buf = ReplayBuffer(scrollbackBytes: 0)
        buf.append(bytes: Data("hello".utf8))
        buf.ack(upTo: buf.highestSeq)
        // With cap 0, ring stays empty — acked entries are discarded as before.
        XCTAssertEqual(buf.scrollbackRingCountForTesting, 0)
        XCTAssertEqual(buf.scrollbackRingBytesForTesting, 0)
        // Cold replay returns nothing (ring is empty and nothing is un-acked).
        XCTAssertTrue(
            buf.messages(after: 0).isEmpty,
            "scrollback disabled: cold replay must return empty when everything is acked",
        )
    }

    // MARK: Scrollback ring — un-acked never-drop invariant unchanged

    func testScrollbackDoesNotDropUnackedEntries() {
        // Even with a tiny scrollback cap, un-acked entries are NEVER moved to the ring
        // (and thus never evicted). The never-drop invariant for `entries` is unchanged.
        var buf = ReplayBuffer(scrollbackBytes: 4)
        for _ in 0..<5 {
            buf.append(bytes: Data("XX".utf8)) // 2 bytes each, 10 bytes un-acked total
        }
        // Ack none → entries stays full; ring is empty.
        XCTAssertEqual(buf.scrollbackRingCountForTesting, 0)
        XCTAssertEqual(buf.retainedBytes, 10)
        // All five are still replayable.
        XCTAssertEqual(buf.messages(after: 0).map(\.seq), [1, 2, 3, 4, 5])
    }

    // MARK: Scrollback ring — replay(after:) delegates to updated messages(after:)

    func testReplayAfterZeroIncludesScrollback() {
        var buf = ReplayBuffer(scrollbackBytes: 256)
        buf.append(bytes: Data("x".utf8)) // seq 1
        buf.append(bytes: Data("y".utf8)) // seq 2
        buf.ack(upTo: 1) // seq 1 → scrollback ring
        // replay(after:0) must include seq 1 from the ring plus seq 2 from entries.
        let replayed = buf.replay(after: 0)
        XCTAssertEqual(replayed, [
            .output(seq: 1, bytes: Data("x".utf8)),
            .output(seq: 2, bytes: Data("y".utf8)),
        ])
    }

    // MARK: Scrollback distiller injection (cold-reattach cleanup)

    /// A synthetic "distiller" that drops every `-` byte — stands in for the OSC-133 churn collapse so the
    /// transport-layer wiring is tested independently of ``ScrollbackDistiller``'s algorithm (host layer).
    private static let dropDashes: @Sendable (Data) -> Data = { Data($0.filter { $0 != UInt8(ascii: "-") }) }

    /// Destructures a `.output` wire message into its `(seq, bytes)` (WireMessage is an enum).
    private func output(_ message: WireMessage) -> (seq: Int64, bytes: Data) {
        guard case let .output(seq, bytes) = message else {
            XCTFail("expected .output, got \(message)")
            return (0, Data())
        }
        return (seq, bytes)
    }

    func testColdReplayDistillsScrollbackPortion() {
        var buf = ReplayBuffer(scrollbackBytes: 256, scrollbackDistiller: Self.dropDashes)
        buf.append(bytes: Data("a-b".utf8)) // seq 1 → will be acked into the ring
        buf.append(bytes: Data("c-d".utf8)) // seq 2 → ring
        buf.append(bytes: Data("tail-raw".utf8)) // seq 3 → un-acked live tail
        buf.ack(upTo: 2) // seqs 1,2 move to scrollback
        let replayed = buf.replay(after: 0)
        // Scrollback bytes are distilled (dashes dropped); the un-acked tail is RAW (dash preserved).
        var scrollbackText = ""
        var tailText = ""
        for m in replayed {
            let (seq, bytes) = output(m)
            let s = String(bytes: bytes, encoding: .utf8) ?? ""
            if seq <= 2 { scrollbackText += s } else { tailText += s }
        }
        XCTAssertEqual(scrollbackText, "abcd", "scrollback churn (dashes) collapsed")
        XCTAssertEqual(tailText, "tail-raw", "un-acked tail replayed byte-exact (never distilled)")
        // Seqs remain ascending and the distilled scrollback stays strictly below the un-acked tail seq.
        let seqs = replayed.map { output($0).seq }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertTrue(seqs.filter { $0 <= 2 }.allSatisfy { $0 < 3 })
        XCTAssertTrue(seqs.contains(3), "tail seq present")
    }

    func testWarmReconnectNeverDistills() {
        // A warm reconnect (lastReceivedSeq at the frontier) selects no scrollback entries, so the
        // distiller never runs — only the raw un-acked tail is returned.
        var buf = ReplayBuffer(scrollbackBytes: 256, scrollbackDistiller: Self.dropDashes)
        buf.append(bytes: Data("a-b".utf8)) // seq 1
        buf.ack(upTo: 1) // → ring
        buf.append(bytes: Data("live-tail".utf8)) // seq 2 un-acked
        let replayed = buf.replay(after: 1) // client already has up to seq 1
        XCTAssertEqual(replayed, [.output(seq: 2, bytes: Data("live-tail".utf8))])
    }

    func testDistilledScrollbackRechunkSeqsStayBelowTail() {
        // Many tiny scrollback entries + a distiller that passes the (dash-free) bytes through unchanged:
        // the re-chunker must assign only scrollback seqs, ascending, each strictly below the un-acked tail
        // seq, and the concatenated distilled bytes must equal the distiller output.
        var buf = ReplayBuffer(scrollbackBytes: 4096, scrollbackDistiller: Self.dropDashes)
        var expected = ""
        for i in 0..<50 {
            let s = "L\(i)\n" // no dashes → dropDashes is a no-op here (effective identity)
            expected += s
            buf.append(bytes: Data(s.utf8)) // seqs 1...50
        }
        buf.ack(upTo: 50) // all → scrollback ring
        buf.append(bytes: Data("TAIL".utf8)) // seq 51 un-acked
        let replayed = buf.replay(after: 0)
        let sbSeqs = replayed.map { output($0).seq }.filter { $0 <= 50 }
        XCTAssertEqual(sbSeqs, sbSeqs.sorted(), "scrollback chunk seqs ascending")
        XCTAssertTrue(sbSeqs.allSatisfy { $0 >= 1 && $0 <= 50 }, "chunk seqs drawn from the scrollback range")
        XCTAssertEqual(Set(sbSeqs).count, sbSeqs.count, "no seq reused across chunks")
        XCTAssertTrue(sbSeqs.allSatisfy { $0 < 51 }, "distilled scrollback stays below the un-acked tail seq")
        let sbText = replayed
            .filter { output($0).seq <= 50 }
            .map { String(bytes: output($0).bytes, encoding: .utf8) ?? "" }
            .joined()
        XCTAssertEqual(sbText, expected, "distilled bytes preserved across the re-chunk")
        XCTAssertEqual(replayed.last, .output(seq: 51, bytes: Data("TAIL".utf8)))
    }

    func testNilDistillerIsRawByteIdentical() {
        // With no distiller, replay(after:) is byte-identical to the pre-distiller behaviour.
        var buf = ReplayBuffer(scrollbackBytes: 256) // distiller defaults to nil
        buf.append(bytes: Data("a-b".utf8))
        buf.append(bytes: Data("c-d".utf8))
        buf.ack(upTo: 1)
        XCTAssertEqual(buf.replay(after: 0), [
            .output(seq: 1, bytes: Data("a-b".utf8)),
            .output(seq: 2, bytes: Data("c-d".utf8)),
        ])
    }
}
