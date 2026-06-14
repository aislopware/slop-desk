#if os(macOS)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// FIX C: the encoder-OUTPUT ordering pump. `VideoEncoder` is RealTime + AllowFrameReordering=
/// false, so its VT callback fires in STRICT encode order on a serial queue. The prior shape —
/// `Task { await self.onEncodedFrame(...) }` per frame — gave NO FIFO guarantee across
/// separately-created Tasks targeting the actor, so frame N+1 could be packetized (and get a
/// LOWER frameID/streamSeq) before frame N → the client saw a delta before its IDR. The single
/// ordered consumer drains this FIFO in encode order and `await`s `onEncodedFrame` one at a time.
///
/// Socket-free: exercises the `EncodedFrameQueue` FIFO + the pure `VideoPacketizer` (no encoder,
/// no SCStream, no actor) to prove the property the consumer guarantees — frameID/streamSeq are
/// assigned in DRAIN (= encode) order.
final class EncodedFrameQueueTests: XCTestCase {
    /// The FIFO preserves append (encode) order on a single full drain.
    func testDrainPreservesAppendOrder() {
        let q = EncodedFrameQueue()
        for i in 0..<8 {
            q.append(.init(avcc: Data([UInt8(i)]), keyframe: i == 0, crisp: false, ltrToken: nil, ackedAnchored: false))
        }
        let drained = q.drainAll()
        XCTAssertEqual(drained.map(\.avcc.first), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertTrue(q.drainAll().isEmpty, "a second drain on an empty queue yields nothing")
    }

    /// Interleaved append/drain bursts (the realistic VT-callback vs consumer race) still keep
    /// global FIFO order: each drain returns its slice in encode order, and concatenation is the
    /// original sequence.
    func testInterleavedAppendDrainKeepsGlobalOrder() {
        let q = EncodedFrameQueue()
        var seen: [UInt8] = []
        var next: UInt8 = 0
        for burst in 0..<5 {
            for _ in 0...burst { // growing bursts: 1,2,3,4,5 appends
                q.append(.init(
                    avcc: Data([next]),
                    keyframe: next == 0,
                    crisp: false,
                    ltrToken: nil,
                    ackedAnchored: false,
                ))
                next += 1
            }
            seen.append(contentsOf: q.drainAll().compactMap(\.avcc.first))
        }
        seen.append(contentsOf: q.drainAll().compactMap(\.avcc.first))
        XCTAssertEqual(seen, Array(0..<next), "drain order is global FIFO across interleaved bursts")
    }

    /// The PROPERTY the ordered consumer guarantees: packetizing frames in DRAIN order assigns
    /// monotonic frameIDs in encode order — so an IDR (frame 0) always precedes the delta that
    /// references it (the awaitingKeyframe-drop the Task-per-frame race caused). The first frame is
    /// the keyframe; every subsequent frameID is exactly +1, so no delta ever carries a lower
    /// frameID than its anchoring IDR.
    func testPacketizingInDrainOrderYieldsMonotonicFrameIDs() {
        let q = EncodedFrameQueue()
        // Encode order: IDR, delta, delta, delta...
        for i in 0..<10 {
            q.append(.init(avcc: Data([UInt8(i)]), keyframe: i == 0, crisp: false, ltrToken: nil, ackedAnchored: false))
        }
        var packetizer = VideoPacketizer(fec: nil)
        var frameIDs: [UInt32] = []
        var keyframeFrameID: UInt32?
        for frame in q.drainAll() {
            let fragments = packetizer.packetize(frame: frame.avcc, keyframe: frame.keyframe, crisp: frame.crisp)
            let id = fragments[0].header.frameID
            // All fragments of one frame share its frameID.
            XCTAssertTrue(fragments.allSatisfy { $0.header.frameID == id })
            frameIDs.append(id)
            if frame.keyframe { keyframeFrameID = id }
        }
        XCTAssertEqual(frameIDs, Array(0..<10).map { UInt32($0) }, "frameIDs monotonic in encode order")
        // The IDR's frameID is the LOWEST — no delta precedes it (the bug's symptom).
        XCTAssertEqual(keyframeFrameID, frameIDs.min())
        XCTAssertEqual(keyframeFrameID, 0)
    }
}
#endif
