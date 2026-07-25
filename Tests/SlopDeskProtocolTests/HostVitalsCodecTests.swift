import Foundation
import SlopDeskProtocol
import XCTest

/// The `hostVitals` (verb 17) payload codec: `[UInt8 cpu%][UInt8 mem%][UInt8 pressure]`. Every
/// behaviour has a test that FAILS on the un-fixed code:
/// - reorder/resize the fields → the byte-layout pin fails;
/// - drop the encode/decode clamp → the out-of-range test renders "197%";
/// - map an unknown pressure byte to anything but `.normal` → the forward-tolerance test fails;
/// - read past the body → the truncated test crashes instead of throwing.
final class HostVitalsCodecTests: XCTestCase {
    func testByteLayoutIsCPUThenMemoryThenPressure() {
        let vitals = MetadataCodec.HostVitals(cpuPercent: 34, memoryPercent: 61, pressure: .warn)
        XCTAssertEqual(MetadataCodec.encodeHostVitals(vitals), Data([34, 61, 1]), "3 bytes, in order")
    }

    func testRoundTripPreservesEveryField() throws {
        for pressure in MetadataCodec.MemoryPressure.allCases {
            let vitals = MetadataCodec.HostVitals(cpuPercent: 7, memoryPercent: 100, pressure: pressure)
            let decoded = try MetadataCodec.decodeHostVitals(MetadataCodec.encodeHostVitals(vitals))
            XCTAssertEqual(decoded, vitals)
            XCTAssertEqual(decoded.memoryPressure, pressure)
        }
    }

    func testPercentsClampOnBothEncodeAndDecode() throws {
        // Encode clamps at the source…
        let wild = MetadataCodec.HostVitals(cpuPercent: 250, memoryPercent: 197, pressureByte: 0)
        XCTAssertEqual(MetadataCodec.encodeHostVitals(wild), Data([100, 100, 0]))
        // …and decode clamps again, so a hostile/buggy body can never render "197%".
        let decoded = try MetadataCodec.decodeHostVitals(Data([250, 197, 0]))
        XCTAssertEqual(decoded.cpuPercent, 100)
        XCTAssertEqual(decoded.memoryPercent, 100)
    }

    func testUnknownPressureByteReadsNormalNeverAnUnjustifiedAlarm() throws {
        let decoded = try MetadataCodec.decodeHostVitals(Data([10, 20, 99]))
        XCTAssertEqual(decoded.pressureByte, 99, "the raw byte is carried forward-tolerantly")
        XCTAssertEqual(decoded.memoryPressure, .normal, "a level this build cannot read lights nothing")
    }

    func testTrailingBytesAreToleratedSoAFutureFieldCanBeAppended() throws {
        let decoded = try MetadataCodec.decodeHostVitals(Data([12, 34, 2, 0xAB, 0xCD]))
        XCTAssertEqual(decoded, MetadataCodec.HostVitals(cpuPercent: 12, memoryPercent: 34, pressure: .critical))
    }

    func testShortBodyThrowsTruncatedNeverTraps() {
        for short in [Data(), Data([1]), Data([1, 2])] {
            XCTAssertThrowsError(try MetadataCodec.decodeHostVitals(short)) { error in
                XCTAssertEqual(error as? SlopDeskError, .truncated)
            }
        }
    }
}
