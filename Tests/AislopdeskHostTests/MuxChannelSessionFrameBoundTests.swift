import AislopdeskProtocol
import AislopdeskTransport
import Foundation
import XCTest
@testable import AislopdeskHost

/// The credit progress invariant at the host drain (night-review HIGH): every emitted
/// `.output` frame's WIRE size (payload + 13-byte header) must stay ≤ window/2, or a
/// sender can park permanently in the header-overhead dead zone — the receiver can only
/// re-grant COMPLETE decoded frames, and a partial prefix > the grant threshold is
/// uncreditable forever.
final class MuxChannelSessionFrameBoundTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(),
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    /// The structural invariant, pinned at the shipped defaults: a max-payload `.output`
    /// frame fits the grant threshold with margin.
    func testMaxOutputFrameWireSizeStaysUnderGrantThreshold() {
        let maxFrame = WireMessage.output(
            seq: Int64.max,
            bytes: Data(repeating: 0x61, count: MuxFlowControl.maxOutputFramePayloadBytes),
        )
        XCTAssertLessThanOrEqual(
            maxFrame.wireByteCount, MuxFlowControl.initialWindowBytes / 2,
            "frame WIRE bytes (payload + header) must fit window/2 — the 13-byte dead zone regression",
        )
        XCTAssertLessThanOrEqual(MuxFlowControl.maxOutputFramePayloadBytes, MuxFlowControl.hostMergeCapBytes)
        // Input direction too (paste split).
        let maxInput = WireMessage.input(Data(repeating: 0x61, count: MuxFlowControl.maxDataMessagePayloadBytes))
        XCTAssertLessThanOrEqual(maxInput.wireByteCount, MuxFlowControl.initialWindowBytes / 2)
    }

    /// An over-cap HEAD chunk (raw read chunk bigger than the safe frame bound) is SPLIT:
    /// prefix ships now, remainder reinserted at the head — byte order and totals intact.
    func testOverCapHeadChunkIsSplitNotShippedWhole() {
        let session = makeSession()
        let cap = MuxFlowControl.maxOutputFramePayloadBytes
        var big = Data()
        for i in 0..<(cap + 1000) { big.append(UInt8(i % 251)) }
        let bell: WireMessage = .bell
        session.enqueueChunkForTesting(bytes: big, control: [bell])

        guard case let .output(first, firstCount, control)? = session.takeMergedFrame() else {
            XCTFail("expected the split prefix")
            return
        }
        XCTAssertEqual(first.count, cap, "prefix is exactly the safe cap")
        XCTAssertEqual(firstCount, cap)
        XCTAssertEqual(control, [bell], "the chunk's sniffed control rides the first part")

        guard case let .output(second, secondCount, control2)? = session.takeMergedFrame() else {
            XCTFail("expected the remainder")
            return
        }
        XCTAssertEqual(secondCount, 1000)
        XCTAssertEqual(control2, [], "control is not duplicated onto the remainder")
        XCTAssertEqual(first + second, big, "split reassembles byte-identically in order")
        XCTAssertNil(session.takeMergedFrame())
    }

    /// Merging never crosses the safe cap even when the raw merge-cap env value would allow it.
    func testMergeRespectsSafeCapNotJustMergeCap() {
        let session = makeSession()
        let cap = MuxFlowControl.maxOutputFramePayloadBytes
        let a = Data(repeating: 0x61, count: cap - 10)
        let b = Data(repeating: 0x62, count: 100)
        session.enqueueChunkForTesting(bytes: a)
        session.enqueueChunkForTesting(bytes: b)
        guard case let .output(first, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected first frame")
            return
        }
        XCTAssertLessThanOrEqual(first.count, cap, "merged frame never exceeds the safe cap")
        XCTAssertEqual(first, a, "b did not fit → not absorbed")
        guard case let .output(second, _, _)? = session.takeMergedFrame() else {
            XCTFail("expected second frame")
            return
        }
        XCTAssertEqual(second, b)
    }
}
