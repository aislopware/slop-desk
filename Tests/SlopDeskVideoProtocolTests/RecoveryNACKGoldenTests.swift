import XCTest
@testable import SlopDeskVideoProtocol

/// Golden pin for the NATIVE Swift NACK (`RecoveryMessage.requestFragments`) codec.
///
/// The NACK's variable-length frag list does not fit the flat FFI `AisdRecoveryMessage`, so it is
/// encoded/decoded in Swift rather than delegated to the Rust core. This test pins the Swift wire
/// bytes to the EXACT `RecoveryMessage::RequestFragments` format the Rust core uses
/// (`[6][frameID BE u32][count BE u16][idx BE u16]…`). The Rust side round-trips that same format in
/// `recovery.rs`, so pinning Swift to these canonical bytes proves Swift == Rust byte-for-byte.
final class RecoveryNACKGoldenTests: XCTestCase {
    func testNackEncodesToTheCanonicalWireBytes() {
        let msg = RecoveryMessage.requestFragments(frameID: 0x0102_0304, fragIndices: [0x0005, 0x000A])
        // type 06 | frameID 01 02 03 04 | count 00 02 | idx 00 05 | idx 00 0A
        let expected: [UInt8] = [0x06, 0x01, 0x02, 0x03, 0x04, 0x00, 0x02, 0x00, 0x05, 0x00, 0x0A]
        XCTAssertEqual([UInt8](msg.encode()), expected, "NACK wire bytes must match the Rust format")
        XCTAssertEqual(msg.messageType, 6)
    }

    func testNackRoundTrips() throws {
        let cases: [(UInt32, [UInt16])] = [
            (0, []), // degenerate empty list (self-delimiting)
            (42, [1, 4, 9, 63]),
            (0xFFFF_FFFF, (0..<10).map(UInt16.init)),
        ]
        for (fid, frags) in cases {
            let msg = RecoveryMessage.requestFragments(frameID: fid, fragIndices: frags)
            XCTAssertEqual(try RecoveryMessage.decode(msg.encode()), msg)
        }
    }

    func testNackRejectsTrailingBytes() {
        // The trailing-bytes rejection is load-bearing for the host's byte-keyed dedup.
        var bytes = RecoveryMessage.requestFragments(frameID: 9, fragIndices: [2, 4]).encode()
        bytes.append(0xFF)
        XCTAssertThrowsError(try RecoveryMessage.decode(bytes))
    }

    func testNackRejectsOversizedCount() {
        // Hand-built NACK whose declared count exceeds the cap → rejected before reading indices.
        var bytes: [UInt8] = [0x06, 0, 0, 0, 7] // type + frameID
        let over = UInt16(RecoveryMessage.maxNackFragments + 1)
        bytes.append(UInt8(over >> 8))
        bytes.append(UInt8(over & 0xFF))
        XCTAssertThrowsError(try RecoveryMessage.decode(Data(bytes)))
    }

    func testNonNackStillDelegatesToRust() throws {
        // The type-byte peek must not break the other (Rust-delegated) recovery messages.
        let idr = RecoveryMessage.requestIDR(lastDecodedFrameID: 99)
        XCTAssertEqual(try RecoveryMessage.decode(idr.encode()), idr)
        let ack = RecoveryMessage.ack(streamSeq: 7)
        XCTAssertEqual(try RecoveryMessage.decode(ack.encode()), ack)
    }
}
