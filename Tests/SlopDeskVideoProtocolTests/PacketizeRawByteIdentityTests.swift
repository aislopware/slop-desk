import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

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

    /// Pins the OTHER half of the send path: one frame is one buffer, and its datagrams are SLICES
    /// of it rather than fresh copies.
    ///
    /// The bytes are identical either way — the test above says so — which is exactly why this needs
    /// its own claim: reintroducing a `Data(...)` per datagram would leave the wire untouched, the
    /// suite green, and a 400 KB `memcpy` plus ~350 allocations back on the 60 fps path. What a
    /// slice cannot hide is WHERE it was cut, so the offsets are the pin: the first datagram starts
    /// after the list's `u32` count and its own `u32` length, and each later one starts exactly four
    /// bytes (its length prefix) past the end of the one before.
    func testOneFrameIsOneBufferTheDatagramsShare() {
        let packetizer = VideoPacketizer(fec: RustReedSolomonFEC())
        let frame = Data((0..<9000).map { UInt8(($0 &* 37 &+ 11) & 0xFF) })
        let datagrams = packetizer.packetizeRaw(frame: frame, keyframe: true, interleave: true)
        XCTAssertGreaterThan(datagrams.count, 1, "a 9 KB frame is many datagrams")
        XCTAssertEqual(datagrams.first?.startIndex, 8, "the count and the first length precede it")
        for (index, datagram) in datagrams.enumerated().dropFirst() {
            XCTAssertEqual(
                datagram.startIndex, datagrams[index - 1].endIndex + 4,
                "datagram \(index) is cut from the same buffer as the one before it",
            )
        }
    }
}
