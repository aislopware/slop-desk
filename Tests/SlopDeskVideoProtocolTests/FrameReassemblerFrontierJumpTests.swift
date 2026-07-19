import XCTest
@testable import SlopDeskVideoProtocol

/// Hostile-input hardening for the loss frontier itself: `highestSeenFrameID` must not be trusted to
/// jump arbitrarily far forward on a single fragment (corrupt/off-path/stray UDP datagram), because
/// `sweepHopelessFrames()` then treats every subsequent LEGITIMATE frame as hopelessly-old-relative-
/// to-the-frontier and drops it forever — a single bad datagram would otherwise freeze the pane for the
/// rest of the session. A sustained, clustered run of far-forward candidates must still be honored as a
/// genuine resync (the encoder legitimately restarted, or a client attached mid-stream). Pure: no
/// transport.
final class FrameReassemblerFrontierJumpTests: XCTestCase {
    private func frag(
        frameID: UInt32,
        fragIndex: UInt16,
        fragCount: UInt16,
        payload: Data = Data([1, 2, 3]),
    ) -> FrameFragment {
        let header = FrameFragmentHeader(
            streamSeq: frameID, frameID: frameID, fragIndex: fragIndex, fragCount: fragCount,
            flags: [], payloadLength: UInt16(payload.count),
        )
        return FrameFragment(header: header, payload: payload)
    }

    /// THE audit scenario: one wildly-out-of-range `frameID` (checksum-surviving corruption, a stray
    /// datagram from a prior session, or a crafted packet) must not permanently latch the frontier —
    /// the very next LEGITIMATE frame still reassembles normally instead of being swept as hopeless.
    func testSingleWildJumpDoesNotWedgeSubsequentLegitFrames() {
        var r = FrameReassembler()
        XCTAssertEqual(
            r.ingest(frag(frameID: 0, fragIndex: 0, fragCount: 1, payload: Data([1]))),
            .completed(ReassembledFrame(frameID: 0, keyframe: false, crisp: false, avcc: Data([1]))),
        )

        // A single fragment carrying a frameID far beyond any plausible in-flight window.
        let wild = r.ingest(frag(frameID: 0 &+ 1_000_000, fragIndex: 0, fragCount: 1, payload: Data([0xFF])))
        XCTAssertEqual(wild, .stale, "a lone far-forward frameID is dropped, not latched as the new frontier")

        // The real stream continues right after the true frontier — must still reassemble, not be
        // swept as "older than the (falsely advanced) frontier".
        XCTAssertEqual(
            r.ingest(frag(frameID: 1, fragIndex: 0, fragCount: 1, payload: Data([2]))),
            .completed(ReassembledFrame(frameID: 1, keyframe: false, crisp: false, avcc: Data([2]))),
            "the wild fragment must not wedge legitimate frames right after the true frontier",
        )
        XCTAssertNil(r.nextDroppedFrame(), "the wild datagram never started a pending frame to drop")
    }

    /// A GENUINE resync: several consecutive far-forward candidates clustered close to each other (the
    /// real stream restarted/reattached far ahead) must eventually be accepted, not dropped forever.
    func testSustainedConsistentFarForwardStreamResyncs() {
        var r = FrameReassembler()
        XCTAssertEqual(
            r.ingest(frag(frameID: 0, fragIndex: 0, fragCount: 1, payload: Data([1]))),
            .completed(ReassembledFrame(frameID: 0, keyframe: false, crisp: false, avcc: Data([1]))),
        )

        let base: UInt32 = 1_000_000
        // Below the resync streak threshold: every candidate is still rejected.
        for i in 0..<7 {
            XCTAssertEqual(
                r.ingest(frag(frameID: base &+ UInt32(i), fragIndex: 0, fragCount: 1, payload: Data([2]))),
                .stale,
                "clustered jump candidate \(i) is rejected until the resync streak threshold is reached",
            )
        }

        // The 8th consecutive, closely-clustered candidate completes the streak → accepted and
        // reassembled normally (the frontier latches at the new region).
        let resynced = r.ingest(frag(frameID: base &+ 7, fragIndex: 0, fragCount: 1, payload: Data([9])))
        XCTAssertEqual(
            resynced,
            .completed(ReassembledFrame(frameID: base &+ 7, keyframe: false, crisp: false, avcc: Data([9]))),
            "a sustained, clustered far-forward run is honored as a genuine resync",
        )

        // The frontier really latched there: a nearby follow-on frame reassembles normally too.
        XCTAssertEqual(
            r.ingest(frag(frameID: base &+ 8, fragIndex: 0, fragCount: 1, payload: Data([10]))),
            .completed(ReassembledFrame(frameID: base &+ 8, keyframe: false, crisp: false, avcc: Data([10]))),
            "the resynced region keeps working for subsequent legitimate frames",
        )
    }
}
