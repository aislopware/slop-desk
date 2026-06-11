import XCTest
@testable import AislopdeskVideoProtocol

/// Length-prefixed (AVCC) NAL-unit iteration — defensive parsing per doc 18 (macOS
/// 26 emits 1 NALU but we iterate anyway; a bad prefix must not crash).
final class NALUnitTests: XCTestCase {

    private func avcc(_ units: [[UInt8]]) -> Data {
        NALUnit.join(units.map { Data($0) })
    }

    func testSingleNALURoundTrip() {
        let units = [Data([0x40, 0x01, 0x0c, 0x01])] // an HEVC VPS-ish blob
        let joined = NALUnit.join(units)
        XCTAssertEqual(NALUnit.split(joined), units)
    }

    func testMultipleNALURoundTrip() {
        let units = [Data([1, 2, 3]), Data([4, 5]), Data([6, 7, 8, 9, 10])]
        let joined = NALUnit.join(units)
        XCTAssertEqual(NALUnit.split(joined), units)
        // Verify the byte layout: 4-byte BE length prefix per unit.
        XCTAssertEqual(joined.prefix(4), Data([0, 0, 0, 3]))
    }

    func testTruncatedTailStopsCleanly() {
        // A valid unit followed by a length prefix that overruns the buffer.
        var bytes = NALUnit.join([Data([1, 2, 3])])
        bytes.append(contentsOf: [0, 0, 0, 99]) // claims 99 bytes, none follow
        let units = NALUnit.split(bytes)
        XCTAssertEqual(units, [Data([1, 2, 3])]) // the overrun tail is ignored, no crash
    }

    func testZeroLengthPrefixStops() {
        var bytes = NALUnit.join([Data([9, 9])])
        bytes.append(contentsOf: [0, 0, 0, 0]) // zero length — stop
        XCTAssertEqual(NALUnit.split(bytes), [Data([9, 9])])
    }

    func testEmptyBuffer() {
        XCTAssertEqual(NALUnit.split(Data()), [])
        XCTAssertEqual(NALUnit.join([]), Data())
    }
}
