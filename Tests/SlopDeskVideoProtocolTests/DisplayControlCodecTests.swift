// DisplayControlCodecTests — pins the full-desktop wire trio (docs/20 §9.2, golden-spliced):
// `listDisplays` (22) / `displayList` (23) / `helloDisplay` (24). Round-trips + the untrusted-count
// discipline every list decoder shares.

import XCTest
@testable import SlopDeskVideoProtocol

final class DisplayControlCodecTests: XCTestCase {
    func testListDisplaysRoundTripsAsZeroBodyType22() throws {
        let encoded = VideoControlMessage.listDisplays.encode()
        XCTAssertEqual(encoded, Data([22]))
        XCTAssertEqual(try VideoControlMessage.decode(encoded), .listDisplays)
    }

    func testDisplayListRoundTrips() throws {
        let message = VideoControlMessage.displayList([
            DisplaySummary(displayID: 1, width: 2560, height: 1440, isMain: true),
            DisplaySummary(displayID: 0x04FD_0002, width: 1920, height: 1080, isMain: false),
        ])
        let decoded = try VideoControlMessage.decode(message.encode())
        XCTAssertEqual(decoded, message)
    }

    func testHelloDisplayRoundTrips() throws {
        let message = VideoControlMessage.helloDisplay(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedDisplayID: 0,
            viewport: VideoSize(width: 1512.0, height: 945.5),
        )
        let decoded = try VideoControlMessage.decode(message.encode())
        XCTAssertEqual(decoded, message)
    }

    /// A bogus huge count over a short datagram throws `.truncated` — the same untrusted-count
    /// discipline as windowList (no reserveCapacity, bail on the first missing byte).
    func testDisplayListHostileCountThrowsTruncated() {
        var hostile = Data([23])
        hostile.appendBE(UInt16.max) // claims 65535 records
        hostile.appendBE(UInt32(1)) // ... then supplies half of one
        XCTAssertThrowsError(try VideoControlMessage.decode(hostile))
    }

    /// A truncated helloDisplay body throws rather than mis-reading.
    func testHelloDisplayTruncatedBodyThrows() {
        let full = VideoControlMessage.helloDisplay(
            protocolVersion: 7, requestedDisplayID: 3, viewport: VideoSize(width: 1, height: 1),
        ).encode()
        XCTAssertThrowsError(try VideoControlMessage.decode(full.prefix(8)))
    }
}
