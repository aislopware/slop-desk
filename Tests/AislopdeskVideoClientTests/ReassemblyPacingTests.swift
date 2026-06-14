import AislopdeskVideoProtocol
import CoreVideo
import XCTest
@testable import AislopdeskVideoClient

/// PURE reassembly → pace scheduling decisions the client orchestrator makes, with
/// fakes only: packetize a frame the way the host's scheduler does, reassemble it on
/// the client (incl. FEC single-loss recovery and the unrecoverable-loss → drop +
/// recovery-signal path), then exercise the pacer's most-recent-wins queue with the
/// reassembled outputs. NO decoder / display link / socket.
final class ReassemblyPacingTests: XCTestCase {
    private func makeAVCC(naluSizes: [Int]) -> Data {
        NALUnit.join(naluSizes.enumerated().map { i, size in
            Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ i &* 13) })
        })
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        return pb!
    }

    func testReassembleMultiFragmentFrameMatchesSource() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 200, 40])
        let fragments = packetizer.packetize(frame: frame, keyframe: true)

        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for f in fragments {
            if case let .completed(r) = try reassembler.ingest(FrameFragment.decode(f.encode())) { completed = r }
        }
        XCTAssertEqual(completed?.avcc, frame)
        XCTAssertEqual(completed?.keyframe, true)
    }

    func testFECRecoversSingleLostDataFragment() throws {
        var packetizer = VideoPacketizer(fec: XORParityFEC(groupSize: 5))
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize * 2 + 50])
        let fragments = packetizer.packetize(frame: frame, keyframe: true)
        // Drop the FIRST data fragment; FEC parity (sent last) must recover it.
        let dataDropIndex = try XCTUnwrap(fragments.firstIndex { !$0.header.flags.contains(.parity) })

        var reassembler = FrameReassembler(fec: XORParityFEC(groupSize: 5))
        var completed: ReassembledFrame?
        for (i, f) in fragments.enumerated() where i != dataDropIndex {
            if case let .completed(r) = try reassembler.ingest(FrameFragment.decode(f.encode())) { completed = r }
        }
        XCTAssertEqual(completed?.avcc, frame, "FEC recovered the single lost data fragment")
    }

    func testUnrecoverableLossSurfacesDropForRecoverySignal() throws {
        // No FEC: a missing data fragment in an OLD frame is terminal once a newer
        // frame's fragments advance the loss frontier. This is the path the orchestrator
        // turns into a requestLTRRefresh.
        var packetizer = VideoPacketizer()
        let frameA = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 10, 10]) // multi-fragment
        let fragsA = packetizer.packetize(frame: frameA, keyframe: true)
        let frameB = makeAVCC(naluSizes: [20])
        let fragsB = packetizer.packetize(frame: frameB, keyframe: false)

        var reassembler = FrameReassembler()
        // Deliver only the FIRST fragment of frame A (drop the rest), then all of B.
        _ = try reassembler.ingest(FrameFragment.decode(fragsA[0].encode()))
        for f in fragsB { _ = try reassembler.ingest(FrameFragment.decode(f.encode())) }

        var drops: [UInt32] = []
        while let lost = reassembler.nextDroppedFrame() { drops.append(lost) }
        XCTAssertEqual(drops, [fragsA[0].header.frameID], "frame A was declared lost once B advanced the frontier")
    }

    func testPacerBuffersTwoReassembledFramesInOrder() {
        // Two frames complete back-to-back; the jitter buffer (targetDepth 2) primes and
        // presents them IN ORDER (oldest first), not skip-late — smoothing arrival jitter.
        let pacer = FramePacer(targetDepth: 2, renderCallback: { _ in })
        let frame1 = makePixelBuffer()
        let frame2 = makePixelBuffer()
        pacer.submit(frame1)
        pacer.submit(frame2)
        XCTAssertTrue(pacer.frameForVSync() === frame1, "FIFO: oldest of the two presented first")
        XCTAssertTrue(pacer.frameForVSync() === frame2)
    }
}
