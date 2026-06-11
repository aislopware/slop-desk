import XCTest
@testable import AislopdeskVideoProtocol

/// R7 #6 hostile-input hardening for ``FrameReassembler``: UDP video has no auth beyond the mesh, so a
/// peer-crafted fragment header must not let it allocate/iterate a huge per-frame buffer (alloc+CPU DoS)
/// or wedge a frame with an out-of-range index. Pure: no transport.
final class FrameReassemblerValidationTests: XCTestCase {

    private func frag(frameID: UInt32, fragIndex: UInt16, fragCount: UInt16,
                      parity: Bool = false, keyframe: Bool = false, payload: Data = Data([1, 2, 3])) -> FrameFragment {
        var flags: FrameFragmentHeader.Flags = []
        if parity { flags.insert(.parity) }
        if keyframe { flags.insert(.keyframe) }
        let header = FrameFragmentHeader(
            streamSeq: frameID, frameID: frameID, fragIndex: fragIndex, fragCount: fragCount,
            flags: flags, payloadLength: UInt16(payload.count))
        return FrameFragment(header: header, payload: payload)
    }

    /// An implausibly huge `fragCount` (peer-controlled UInt16) is rejected as `.stale` BEFORE any
    /// per-frame buffer is allocated — no alloc/CPU amplification, no pending frame created.
    func testHugeFragCountIsRejected() {
        var r = FrameReassembler()
        XCTAssertEqual(r.ingest(frag(frameID: 1, fragIndex: 0, fragCount: .max)), .stale,
                       "an implausibly huge fragCount is dropped, not buffered")
        XCTAssertEqual(r.ingest(frag(frameID: 2, fragIndex: 0, fragCount: 9000)), .stale,
                       "a fragCount just over the 8192 cap is dropped")
        XCTAssertNil(r.nextDroppedFrame(), "a rejected fragment never creates a frame to drop")
    }

    /// `fragIndex >= fragCount` (and `fragCount == 0`) are invalid — every legitimate fragment has
    /// `0 < fragCount` and `fragIndex < fragCount` (parity ids are `dataCount + groupOrder < fragCount`).
    func testOutOfRangeFragIndexAndZeroCountRejected() {
        var r = FrameReassembler()
        XCTAssertEqual(r.ingest(frag(frameID: 1, fragIndex: 5, fragCount: 3)), .stale, "fragIndex >= fragCount")
        XCTAssertEqual(r.ingest(frag(frameID: 1, fragIndex: 0, fragCount: 0)), .stale, "fragCount 0")
        XCTAssertEqual(r.ingest(frag(frameID: 1, fragIndex: 3, fragCount: 3)), .stale, "fragIndex == fragCount")
        XCTAssertNil(r.nextDroppedFrame())
    }

    /// The guard does NOT reject valid input: a legitimate single-fragment keyframe still completes.
    func testValidSingleFragmentFrameStillCompletes() {
        var r = FrameReassembler()
        let result = r.ingest(frag(frameID: 1, fragIndex: 0, fragCount: 1, keyframe: true, payload: Data([9, 8, 7])))
        XCTAssertEqual(result, .completed(ReassembledFrame(frameID: 1, keyframe: true, crisp: false, avcc: Data([9, 8, 7]))),
                       "a valid single-fragment frame reassembles normally — the guard is not over-broad")
    }

    /// R7 #3 contract lock: in the reorder-then-loss interleaving, the INGESTED fragment's own frame can
    /// become hopeless during its OWN ingest — `ingest()` then returns `.dropped(frameID:)` DIRECTLY and
    /// pops it OFF the drain queue, so `nextDroppedFrame()` is empty for it. A client that only drains
    /// `nextDroppedFrame()` (ignoring the `.dropped` return) would NEVER signal recovery for that frame
    /// (the bug R7 #3 fixed by routing the `.dropped` return through the same recovery path).
    func testReorderThenLossReturnsDroppedFromIngestNotViaQueue() {
        var r = FrameReassembler() // no FEC: any missing data fragment on an old frame is terminal
        // frame1 arrives first → advances the loss frontier, still incomplete (needs fragIndex 1).
        XCTAssertEqual(r.ingest(frag(frameID: 1, fragIndex: 0, fragCount: 2)), .incomplete)
        // frame0's late fragment arrives — frame0 is older than the frontier, missing fragIndex 0, no
        // FEC → hopeless. ingest() returns .dropped(0) DIRECTLY (and removes it from the drain queue).
        XCTAssertEqual(r.ingest(frag(frameID: 0, fragIndex: 1, fragCount: 2)), .dropped(frameID: 0),
                       "the ingested frame's own loss is surfaced via the .dropped RETURN")
        XCTAssertNil(r.nextDroppedFrame(),
                     "frame0 was returned directly, NOT left on the drain queue — so ignoring the return loses it")
    }
}
