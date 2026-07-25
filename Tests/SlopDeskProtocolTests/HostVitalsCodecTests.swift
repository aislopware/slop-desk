import Foundation
import SlopDeskProtocol
import XCTest

/// The `hostVitals` (verb 17) payload codec: `[UInt8 cpu%][UInt8 mem%][UInt8 pressure][UInt32 disk
/// free MiB]`. Every behaviour has a test that FAILS on the un-fixed code:
/// - reorder/resize the fields → the byte-layout pin fails;
/// - drop the encode/decode clamp → the out-of-range test renders "197%";
/// - map an unknown pressure byte to anything but `.normal` → the forward-tolerance test fails;
/// - treat the disk sentinel as a reading → an unreadable volume renders as a 4 PiB disk;
/// - read past the body → the truncated test crashes instead of throwing.
final class HostVitalsCodecTests: XCTestCase {
    func testByteLayoutIsCPUThenMemoryThenPressureThenDisk() {
        let vitals = MetadataCodec.HostVitals(
            cpuPercent: 34, memoryPercent: 61, pressure: .warn, diskFreeMiB: 245_760,
        )
        XCTAssertEqual(
            MetadataCodec.encodeHostVitals(vitals),
            Data([34, 61, 1, 0x00, 0x03, 0xC0, 0x00]),
            "7 bytes, in order, the disk figure big-endian",
        )
    }

    func testRoundTripPreservesEveryField() throws {
        for pressure in MetadataCodec.MemoryPressure.allCases {
            let vitals = MetadataCodec.HostVitals(
                cpuPercent: 7, memoryPercent: 100, pressure: pressure, diskFreeMiB: 4096,
            )
            let decoded = try MetadataCodec.decodeHostVitals(MetadataCodec.encodeHostVitals(vitals))
            XCTAssertEqual(decoded, vitals)
            XCTAssertEqual(decoded.memoryPressure, pressure)
        }
    }

    func testPercentsClampOnBothEncodeAndDecode() throws {
        // Encode clamps at the source…
        let wild = MetadataCodec.HostVitals(
            cpuPercent: 250, memoryPercent: 197, pressureByte: 0, diskFreeMiB: 0,
        )
        XCTAssertEqual(MetadataCodec.encodeHostVitals(wild), Data([100, 100, 0, 0, 0, 0, 0]))
        // …and decode clamps again, so a hostile/buggy body can never render "197%".
        let decoded = try MetadataCodec.decodeHostVitals(Data([250, 197, 0, 0, 0, 0, 0]))
        XCTAssertEqual(decoded.cpuPercent, 100)
        XCTAssertEqual(decoded.memoryPercent, 100)
    }

    func testUnknownPressureByteReadsNormalNeverAnUnjustifiedAlarm() throws {
        let decoded = try MetadataCodec.decodeHostVitals(Data([10, 20, 99, 0, 0, 0, 1]))
        XCTAssertEqual(decoded.pressureByte, 99, "the raw byte is carried forward-tolerantly")
        XCTAssertEqual(decoded.memoryPressure, .normal, "a level this build cannot read lights nothing")
    }

    func testUnreadableDiskIsItsOwnValueNotZero() throws {
        // A full volume genuinely reads 0 MiB, so "unreadable" cannot borrow zero — it would draw a
        // full-disk alarm for a refused syscall.
        let unknown = MetadataCodec.HostVitals(cpuPercent: 1, memoryPercent: 2, pressure: .normal)
        let encoded = MetadataCodec.encodeHostVitals(unknown)
        XCTAssertEqual(encoded.suffix(4), Data([0xFF, 0xFF, 0xFF, 0xFF]), "the sentinel goes on the wire")
        XCTAssertNil(try MetadataCodec.decodeHostVitals(encoded).diskFreeMiB)
        let full = try MetadataCodec.decodeHostVitals(Data([1, 2, 0, 0, 0, 0, 0]))
        XCTAssertEqual(full.diskFreeMiB, 0, "a genuinely full disk survives the round trip as 0")
    }

    func testTrailingBytesAreToleratedSoAFutureFieldCanBeAppended() throws {
        let decoded = try MetadataCodec.decodeHostVitals(Data([12, 34, 2, 0, 0, 0x10, 0x00, 0xAB, 0xCD]))
        XCTAssertEqual(
            decoded,
            MetadataCodec.HostVitals(
                cpuPercent: 12, memoryPercent: 34, pressure: .critical, diskFreeMiB: 4096,
            ),
        )
    }

    func testShortBodyThrowsTruncatedNeverTraps() {
        for short in [Data(), Data([1]), Data([1, 2]), Data([1, 2, 0]), Data([1, 2, 0, 0, 0, 1])] {
            XCTAssertThrowsError(try MetadataCodec.decodeHostVitals(short)) { error in
                XCTAssertEqual(error as? SlopDeskError, .truncated)
            }
        }
    }
}
