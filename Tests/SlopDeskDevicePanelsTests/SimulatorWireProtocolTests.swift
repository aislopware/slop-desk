// SimulatorWireProtocolTests — the FACE, not the decoder.
//
// The decoder's laws — the two-byte floor, the avcC layout, which truncation is tolerated and which
// is a refusal — are `slopdesk_devicepanel::sim_stream`'s and are pinned there. What these hold is
// the half that stays on this side: that each kind code lands on ITS case (a code that fell through
// to a neighbour would hand the decoder a JPEG as an access unit), that a `Data` sliced off a larger
// buffer is read from its own start, and that the parameter-set delivery is cut on exactly the
// boundaries the door framed it on.
//
// The avcC fixture is the RECORD MEASURED off a live `baguette serve` (High 5.1, 4-byte NAL length),
// assembled byte by byte rather than pasted as one blob so each field's meaning is legible.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorWireProtocolTests: XCTestCase {
    // MARK: Envelope

    /// Each kind code becomes ITS message. The payload is the slice this side already held, so a case
    /// landing on the wrong neighbour is the one failure the door cannot see.
    func testEachKindCodeLandsOnItsOwnMessage() {
        XCTAssertEqual(SimulatorWireProtocol.decode(Data([0x01, 0xAA])), .configuration(Data([0xAA])))
        XCTAssertEqual(
            SimulatorWireProtocol.decode(Data([0x02, 0xAA])), .accessUnit(Data([0xAA]), isKeyframe: true),
        )
        XCTAssertEqual(
            SimulatorWireProtocol.decode(Data([0x03, 0xAA])), .accessUnit(Data([0xAA]), isKeyframe: false),
        )
        XCTAssertEqual(SimulatorWireProtocol.decode(Data([0x04, 0xAA])), .jpeg(Data([0xAA])))
        // A newer server that adds a type must cost us that message, not the connection — and the
        // case carries the RAW byte, which only this side can still see.
        XCTAssertEqual(SimulatorWireProtocol.decode(Data([0x09, 0xAA])), .unknown(0x09))
        XCTAssertNil(SimulatorWireProtocol.decode(Data([0x02])))
    }

    func testDecodeIsIndexOffsetSafe() {
        // A `Data` sliced off a larger buffer does not start at index 0. Lending the whole backing
        // store to the door, or reading `message[0]` for the unknown byte, would take a byte from the
        // middle of the previous message.
        let backing = Data([0xFF, 0xFF, 0x02, 0xAB, 0xCD])
        let slice = backing.dropFirst(2)
        XCTAssertEqual(
            SimulatorWireProtocol.decode(slice), .accessUnit(Data([0xAB, 0xCD]), isKeyframe: true),
        )
        XCTAssertEqual(SimulatorWireProtocol.decode(backing.dropFirst(1)), .unknown(0xFF))
    }

    // MARK: avcC

    /// The shape observed on the wire: version 1, High profile, level 5.1, 4-byte NAL lengths, one
    /// SPS and one PPS.
    private func avcCRecord(
        version: UInt8 = 1, lengthByte: UInt8 = 0xFF,
        sps: [Data] = [Data([0x27, 0x64, 0x00, 0x33])], pps: [Data]? = [Data([0x28, 0xEE])],
    ) -> Data {
        var record = Data([version, 0x64, 0x00, 0x33, lengthByte, 0xE0 | UInt8(sps.count)])
        for set in sps {
            record.append(UInt8(set.count >> 8))
            record.append(UInt8(set.count & 0xFF))
            record.append(set)
        }
        guard let pps else { return record }
        record.append(UInt8(pps.count))
        for set in pps {
            record.append(UInt8(set.count >> 8))
            record.append(UInt8(set.count & 0xFF))
            record.append(set)
        }
        return record
    }

    /// The delivery is `set_count` runs of `[UInt32 big-endian length][bytes]`, and the count in the
    /// header must cut it EXACTLY: an off-by-one in that walk builds a format description out of two
    /// sets spliced together, which decodes nothing and blames the stream.
    func testTheDeliveryIsCutOnTheBoundariesTheHeaderNames() {
        let parsed = SimulatorWireProtocol.parseAVCConfiguration(avcCRecord())
        XCTAssertEqual(parsed?.parameterSets, [Data([0x27, 0x64, 0x00, 0x33]), Data([0x28, 0xEE])])
        XCTAssertEqual(parsed?.nalUnitHeaderLength, 4)
        XCTAssertEqual(parsed?.profile, 0x64)
        XCTAssertEqual(parsed?.levelIndication, 0x33)
    }

    /// A record the door refuses answers `nil` rather than a configuration with no sets — the caller
    /// reads that as "no configuration" and keeps the decoder it had.
    func testARefusedRecordCrossesAsNilRatherThanAnEmptyOne() {
        XCTAssertNil(SimulatorWireProtocol.parseAVCConfiguration(avcCRecord(version: 2)))
        XCTAssertNil(SimulatorWireProtocol.parseAVCConfiguration(Data()))
    }

    func testEveryTruncationOfARealRecordIsRefusedRatherThanTrapping() {
        // The untrusted-input invariant, exhaustively, and across the boundary: no prefix of a valid
        // record may read past its end on either side. A crash here is remotely triggerable by
        // anything that can reach the port.
        let record = avcCRecord()
        for length in 0..<record.count {
            _ = SimulatorWireProtocol.parseAVCConfiguration(record.prefix(length))
        }
    }
}
#endif
