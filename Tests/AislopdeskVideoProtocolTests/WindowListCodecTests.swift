import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip + hostile-decode for the window-discovery control pair (docs/31 remote-window PICKER):
/// `listWindows` (type 7, client→host, zero body) and `windowList([WindowSummary])` (type 8,
/// host→client). The list is the only multi-record variable-length payload in the video protocol, so
/// decode MUST be hardened: a truncated / oversized datagram DROPS (throws `.malformed`/`.truncated`),
/// never over-reads or crashes.
final class WindowListCodecTests: XCTestCase {

    // MARK: listWindows (request)

    func testListWindowsRoundTripIsSingleTypeByte() throws {
        let req = VideoControlMessage.listWindows
        XCTAssertEqual(req.encode(), Data([7]), "listWindows is a single type byte (7, zero body)")
        XCTAssertEqual(req.messageType, 7)
        XCTAssertEqual(try VideoControlMessage.decode(Data([7])), .listWindows)
    }

    // MARK: windowList (response)

    func testWindowListRoundTripPreservesEveryField() throws {
        let windows = [
            WindowSummary(windowID: 604, appName: "Google Chrome", title: "New chat - Claude", width: 1800, height: 943),
            WindowSummary(windowID: 464, appName: "Ghostty", title: "/Volumes/Lacie", width: 1408, height: 889),
            WindowSummary(windowID: 10, appName: "Finder", title: "", width: 920, height: 436),   // empty title
        ]
        let msg = VideoControlMessage.windowList(windows)
        XCTAssertEqual(msg.messageType, 8)
        let decoded = try VideoControlMessage.decode(msg.encode())
        XCTAssertEqual(decoded, .windowList(windows), "every record field round-trips, in order")
    }

    func testEmptyWindowListRoundTrips() throws {
        let msg = VideoControlMessage.windowList([])
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), .windowList([]))
    }

    func testNonASCIITitleRoundTrips() throws {
        let w = WindowSummary(windowID: 1, appName: "Trình duyệt", title: "Cửa sổ — 窗口 🪟", width: 100, height: 50)
        XCTAssertEqual(try VideoControlMessage.decode(VideoControlMessage.windowList([w]).encode()),
                       .windowList([w]), "UTF-8 app/title survive the length-prefixed round-trip")
    }

    // MARK: hostile decode — a corrupt datagram must DROP, never crash / over-allocate

    func testTruncatedAfterCountThrows() {
        // count says 3 but no records follow → readUInt32 on the first record throws .truncated.
        var data = Data([8])          // type
        data.appendBE(UInt16(3))      // count = 3, then nothing
        XCTAssertThrowsError(try VideoControlMessage.decode(data))
    }

    func testRecordTitleLengthOverrunsDatagramThrows() {
        // One record whose title length-prefix claims more bytes than remain → readBytes throws.
        var data = Data([8])
        data.appendBE(UInt16(1))      // count = 1
        data.appendBE(UInt32(42))     // windowID
        data.appendBE(UInt16(100))    // width
        data.appendBE(UInt16(50))     // height
        data.appendBE(UInt16(0))      // appLen = 0 (empty app)
        data.appendBE(UInt16(9999))   // titleLen = 9999 but no bytes follow
        XCTAssertThrowsError(try VideoControlMessage.decode(data),
                             "an oversized length prefix must throw, not over-read")
    }

    func testHugeCountDoesNotOverAllocateAndThrows() {
        // count = UInt16.max with no records: the decoder must bail on the FIRST missing record
        // (it does not reserveCapacity(count)), throwing quickly rather than allocating 64K records.
        var data = Data([8])
        data.appendBE(UInt16.max)
        XCTAssertThrowsError(try VideoControlMessage.decode(data))
    }

    // MARK: Size budget — the encoded list stays modest

    func testRealisticListStaysModestlySized() {
        // A control datagram is sent whole (NOT frame-packetized at the 1200-byte video MTU); a larger
        // list is IP-fragmented and the client's discovery retry covers occasional loss. 40 windows with
        // typical names is a few KB — comfortably under the host's safety cap. This pins that a normal
        // machine's window set encodes small (the host additionally filters junk + caps the count).
        let windows = (0..<40).map {
            WindowSummary(windowID: UInt32($0), appName: "Application \($0)", title: "A reasonably long window title \($0)", width: 1920, height: 1080)
        }
        let bytes = VideoControlMessage.windowList(windows).encode()
        XCTAssertLessThan(bytes.count, 8000, "even 40 windows encode to a few KB (host filters + caps in practice)")
    }
}
