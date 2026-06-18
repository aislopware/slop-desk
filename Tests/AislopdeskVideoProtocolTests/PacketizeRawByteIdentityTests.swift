import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// Pins the send-path perf optimization: `VideoPacketizer.packetizeRaw` (raw `[Data]` wire datagrams,
/// used by the host send path) MUST be byte-identical to the old `packetize(...).map { $0.encode() }`
/// round-trip (parse → re-encode). If this ever diverges, the raw fast path would change the wire —
/// so this is the gate that lets the host skip the parse/re-encode with zero wire risk.
final class PacketizeRawByteIdentityTests: XCTestCase {
    private func assertIdentical(fec: FECScheme?, file: StaticString = #filePath, line: UInt = #line) {
        // Two FRESH packetizers with identical config advance their frameID/streamSeq in lockstep, so
        // the Nth call on each sees the same counters → directly comparable bytes.
        let raw = VideoPacketizer(fec: fec)
        let viaFragments = VideoPacketizer(fec: fec)
        // A multi-fragment frame (well over one MTU) so splitting + FEC grouping + interleave all engage.
        let frame = Data((0..<9000).map { UInt8(($0 &* 37 &+ 11) & 0xFF) })
        let cases: [(keyframe: Bool, crisp: Bool, interleave: Bool, ltr: Bool)] = [
            (false, false, false, false),
            (false, false, true, false), // interleave on (the live default)
            (true, false, true, false), // keyframe
            (false, true, true, false), // crisp
            (false, false, true, true), // LTR-tagged
        ]
        for (i, c) in cases.enumerated() {
            let ts = UInt32(1000 + i)
            let rawDatagrams = raw.packetizeRaw(
                frame: frame, keyframe: c.keyframe, crisp: c.crisp, hostSendTsMillis: ts,
                isLTR: c.ltr, interleave: c.interleave,
            )
            let reencoded = viaFragments.packetize(
                frame: frame, keyframe: c.keyframe, crisp: c.crisp, hostSendTsMillis: ts,
                isLTR: c.ltr, interleave: c.interleave,
            ).map { $0.encode() }
            XCTAssertFalse(rawDatagrams.isEmpty, "case \(i) produced no datagrams", file: file, line: line)
            XCTAssertEqual(
                rawDatagrams, reencoded,
                "packetizeRaw must be byte-identical to packetize().encode() (case \(i): \(c))",
                file: file, line: line,
            )
        }
    }

    func testRawIsByteIdenticalNoFEC() { assertIdentical(fec: nil) }

    func testRawIsByteIdenticalRSm1() { assertIdentical(fec: RustReedSolomonFEC()) } // m=1, the live LAN default
}
