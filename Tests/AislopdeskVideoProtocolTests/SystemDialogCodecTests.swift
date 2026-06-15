import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip + hostile-decode for the system-dialog discovery control pair (the "show system popups in
/// their own pane" feature): `listSystemDialogs` (type 11, client→host, zero body) and
/// `systemDialogList([SystemDialogSummary])` (type 12, host→client). Mirrors the windowList codec's
/// untrusted-count discipline — a truncated / oversized datagram DROPS (throws), never over-reads.
final class SystemDialogCodecTests: XCTestCase {
    // MARK: listSystemDialogs (request)

    func testListSystemDialogsIsSingleTypeByte() throws {
        let req = VideoControlMessage.listSystemDialogs
        XCTAssertEqual(req.messageType, 11)
        XCTAssertEqual(req.encode(), Data([11]), "listSystemDialogs is a single type byte (11, zero body)")
        XCTAssertEqual(try VideoControlMessage.decode(Data([11])), .listSystemDialogs)
    }

    // MARK: systemDialogList (response)

    func testSystemDialogListRoundTripPreservesEveryField() throws {
        let dialogs = [
            // The HW-probed SecurityAgent login prompt: secure class + keystrokes blocked (SEI live).
            SystemDialogSummary(
                windowID: 1966,
                owner: "SecurityAgent",
                title: "",
                width: 260,
                height: 312,
                isSecure: true,
                keystrokesBlocked: true,
            ),
            // A secure-class admin-auth prompt whose Secure Event Input is off → typable (the two
            // flags differ, pinning their independence through the round-trip).
            SystemDialogSummary(
                windowID: 2001,
                owner: "SecurityAgent",
                title: "Authorize",
                width: 420,
                height: 220,
                isSecure: true,
                keystrokesBlocked: false,
            ),
            SystemDialogSummary(
                windowID: 1755,
                owner: "Open and Save Panel Service",
                title: "Open",
                width: 880,
                height: 448,
                isSecure: false,
                keystrokesBlocked: false,
            ),
        ]
        let msg = VideoControlMessage.systemDialogList(dialogs)
        XCTAssertEqual(msg.messageType, 12)
        XCTAssertEqual(
            try VideoControlMessage.decode(msg.encode()),
            .systemDialogList(dialogs),
            "windowID/size/isSecure/keystrokesBlocked/owner/title all round-trip, in order",
        )
    }

    func testEmptySystemDialogListRoundTrips() throws {
        let msg = VideoControlMessage.systemDialogList([])
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), .systemDialogList([]))
    }

    func testSecureFlagRoundTripsBothWays() throws {
        let secure = SystemDialogSummary(
            windowID: 1,
            owner: "SecurityAgent",
            title: "Untitled",
            width: 9,
            height: 9,
            isSecure: true,
            keystrokesBlocked: true,
        )
        let open = SystemDialogSummary(
            windowID: 2,
            owner: "UserNotificationCenter",
            title: "Alert",
            width: 9,
            height: 9,
            isSecure: false,
            keystrokesBlocked: false,
        )
        XCTAssertEqual(
            try VideoControlMessage.decode(VideoControlMessage.systemDialogList([secure, open]).encode()),
            .systemDialogList([secure, open]),
        )
    }

    func testNonASCIIOwnerAndTitleRoundTrip() throws {
        let d = SystemDialogSummary(
            windowID: 7,
            owner: "Tiến trình hệ thống",
            title: "Mật khẩu — 密码 🔐",
            width: 100,
            height: 50,
            isSecure: true,
            keystrokesBlocked: true,
        )
        XCTAssertEqual(
            try VideoControlMessage.decode(VideoControlMessage.systemDialogList([d]).encode()),
            .systemDialogList([d]),
            "UTF-8 owner/title survive the length-prefixed round-trip",
        )
    }

    // MARK: hostile decode — a corrupt datagram must DROP, never crash / over-allocate

    func testTruncatedAfterCountThrows() {
        var data = Data([12]) // type
        data.appendBE(UInt16(3)) // count = 3, then nothing
        XCTAssertThrowsError(try VideoControlMessage.decode(data))
    }

    func testRecordOwnerLengthOverrunsDatagramThrows() {
        var data = Data([12])
        data.appendBE(UInt16(1)) // count = 1
        data.appendBE(UInt32(42)) // windowID
        data.appendBE(UInt16(100)) // width
        data.appendBE(UInt16(50)) // height
        data.append(1) // isSecure = 1
        data.append(0) // keystrokesBlocked = 0
        data.appendBE(UInt16(9999)) // ownerLen = 9999 but no bytes follow
        XCTAssertThrowsError(
            try VideoControlMessage.decode(data),
            "an oversized length prefix must throw, not over-read",
        )
    }

    func testHugeCountDoesNotOverAllocateAndThrows() {
        var data = Data([12])
        data.appendBE(UInt16.max) // no records — must bail on the first missing record
        XCTAssertThrowsError(try VideoControlMessage.decode(data))
    }
}
