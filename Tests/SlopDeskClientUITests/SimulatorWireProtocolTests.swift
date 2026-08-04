// SimulatorWireProtocolTests — pins the untrusted decoder for the host simulator server's stream.
//
// The avcC fixtures are the RECORD MEASURED off a live `baguette serve` (High 5.1, 4-byte NAL
// length), assembled byte by byte rather than pasted as one blob so each field's meaning is legible
// at the point it is asserted.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class SimulatorWireProtocolTests: XCTestCase {
    // MARK: Envelope

    func testEachTypeByteMapsToItsMessage() {
        XCTAssertEqual(SimulatorWireProtocol.decode(Data([0x01, 0xAA])), .configuration(Data([0xAA])))
        XCTAssertEqual(
            SimulatorWireProtocol.decode(Data([0x02, 0xAA])), .accessUnit(Data([0xAA]), isKeyframe: true),
        )
        XCTAssertEqual(
            SimulatorWireProtocol.decode(Data([0x03, 0xAA])), .accessUnit(Data([0xAA]), isKeyframe: false),
        )
        XCTAssertEqual(SimulatorWireProtocol.decode(Data([0x04, 0xAA])), .jpeg(Data([0xAA])))
    }

    func testAnUnknownTypeIsIgnorableRatherThanFatal() {
        // A newer server that adds a message type must cost us that message, not the connection.
        XCTAssertEqual(SimulatorWireProtocol.decode(Data([0x09, 0xAA])), .unknown(0x09))
    }

    func testAMessageTooShortToCarryAPayloadIsRefused() {
        // The server never sends a bodiless frame; one on the wire means this is not the stream we
        // think it is.
        XCTAssertNil(SimulatorWireProtocol.decode(Data()))
        XCTAssertNil(SimulatorWireProtocol.decode(Data([0x02])))
    }

    func testDecodeIsIndexOffsetSafe() {
        // A `Data` sliced off a larger buffer does not start at index 0. Reading `message[0]` instead
        // of `message[startIndex]` would take a byte from the middle of the previous message.
        let backing = Data([0xFF, 0xFF, 0x02, 0xAB, 0xCD])
        let slice = backing.dropFirst(2)
        XCTAssertEqual(
            SimulatorWireProtocol.decode(slice), .accessUnit(Data([0xAB, 0xCD]), isKeyframe: true),
        )
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

    func testTheMeasuredRecordParsesToItsParameterSets() {
        let parsed = SimulatorWireProtocol.parseAVCConfiguration(avcCRecord())
        XCTAssertEqual(parsed?.parameterSets, [Data([0x27, 0x64, 0x00, 0x33]), Data([0x28, 0xEE])])
        XCTAssertEqual(parsed?.profile, 0x64)
        XCTAssertEqual(parsed?.levelIndication, 0x33)
    }

    func testTheNALLengthSizeIsReadRatherThanAssumed() {
        // Guessing 4 here would decode a 1- or 2-byte-prefixed stream as garbage — silently, since
        // every length would be read from the wrong bytes.
        XCTAssertEqual(
            SimulatorWireProtocol.parseAVCConfiguration(avcCRecord(lengthByte: 0xFF))?.nalUnitHeaderLength,
            4,
        )
        XCTAssertEqual(
            SimulatorWireProtocol.parseAVCConfiguration(avcCRecord(lengthByte: 0xFC))?.nalUnitHeaderLength,
            1,
        )
        XCTAssertEqual(
            SimulatorWireProtocol.parseAVCConfiguration(avcCRecord(lengthByte: 0xFD))?.nalUnitHeaderLength,
            2,
        )
    }

    func testAnUnknownConfigurationVersionIsRefused() {
        // Version 1 is the only one defined. Parsing a future record with today's field layout would
        // produce a plausible-looking format description that decodes nothing.
        XCTAssertNil(SimulatorWireProtocol.parseAVCConfiguration(avcCRecord(version: 2)))
    }

    func testARecordWithNoParameterSetsIsRefused() {
        XCTAssertNil(SimulatorWireProtocol.parseAVCConfiguration(avcCRecord(sps: [], pps: [])))
    }

    func testAnEmptyParameterSetIsSkippedRatherThanCarried() {
        // A zero-length set means nothing to the decoder and would only fail later, further from the
        // cause.
        let parsed = SimulatorWireProtocol.parseAVCConfiguration(
            avcCRecord(sps: [Data([0x27]), Data()], pps: nil),
        )
        XCTAssertEqual(parsed?.parameterSets, [Data([0x27])])
    }

    func testAMissingPPSSectionStillYieldsAUsableConfiguration() {
        // An SPS alone is enough to build a format description; refusing would turn a recoverable
        // stream into a dead panel.
        let parsed = SimulatorWireProtocol.parseAVCConfiguration(avcCRecord(pps: nil))
        XCTAssertEqual(parsed?.parameterSets, [Data([0x27, 0x64, 0x00, 0x33])])
    }

    func testEveryTruncationOfARealRecordIsRefusedRatherThanTrapping() {
        // The untrusted-input invariant, exhaustively: no prefix of a valid record may read past its
        // end. A crash here is remotely triggerable by anything that can reach the port.
        let record = avcCRecord()
        for length in 0..<record.count {
            _ = SimulatorWireProtocol.parseAVCConfiguration(record.prefix(length))
        }
    }

    func testALengthPrefixLongerThanTheRecordIsRefused() {
        // The hostile case the bounds check exists for: a declared 0xFFFF-byte SPS in a 10-byte
        // record.
        var record = Data([0x01, 0x64, 0x00, 0x33, 0xFF, 0xE1])
        record.append(contentsOf: [0xFF, 0xFF, 0x27, 0x64])
        XCTAssertNil(SimulatorWireProtocol.parseAVCConfiguration(record))
    }
}
#endif
