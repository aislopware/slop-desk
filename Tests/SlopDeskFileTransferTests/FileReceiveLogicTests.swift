import XCTest
@testable import SlopDeskFileTransfer

final class FileReceiveLogicTests: XCTestCase {
    private func afterHello(_ logic: inout FileReceiveLogic) {
        XCTAssertEqual(logic.handle(.hello(version: fileTransferVersion)), [.reply(.helloAck(accepted: true))])
    }

    func testHelloAcceptsMatchingVersion() {
        var logic = FileReceiveLogic()
        XCTAssertEqual(logic.handle(.hello(version: fileTransferVersion)), [.reply(.helloAck(accepted: true))])
    }

    func testHelloRejectsMismatch() {
        var logic = FileReceiveLogic()
        XCTAssertEqual(logic.handle(.hello(version: 99)), [.reply(.helloAck(accepted: false))])
    }

    func testHappyPath() {
        var logic = FileReceiveLogic()
        afterHello(&logic)

        let offer = logic.handle(.offer(transferId: 1, fileSize: 3, name: "a.txt"))
        XCTAssertEqual(offer, [
            .open(transferId: 1, name: "a.txt", size: 3),
            .reply(.accept(transferId: 1)),
        ])

        XCTAssertEqual(
            logic.handle(.chunk(transferId: 1, data: Data([1, 2]))),
            [.write(transferId: 1, data: Data([1, 2]))],
        )
        XCTAssertEqual(
            logic.handle(.chunk(transferId: 1, data: Data([3]))),
            [.write(transferId: 1, data: Data([3]))],
        )

        XCTAssertEqual(logic.handle(.finish(transferId: 1)), [
            .finalize(transferId: 1),
            .reply(.complete(transferId: 1)),
        ])
    }

    func testOfferBeforeHelloFails() {
        var logic = FileReceiveLogic()
        XCTAssertEqual(
            logic.handle(.offer(transferId: 1, fileSize: 1, name: "a")),
            [.reply(.failed(transferId: 1, reason: "no handshake"))],
        )
    }

    func testChunkBeforeOfferFails() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        XCTAssertEqual(
            logic.handle(.chunk(transferId: 1, data: Data([1]))),
            [.reply(.failed(transferId: 1, reason: "no such transfer"))],
        )
    }

    func testByteOverrunAborts() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        _ = logic.handle(.offer(transferId: 1, fileSize: 2, name: "a.txt"))
        let effects = logic.handle(.chunk(transferId: 1, data: Data([1, 2, 3]))) // 3 > 2
        XCTAssertEqual(effects, [
            .abort(transferId: 1),
            .reply(.failed(transferId: 1, reason: "body exceeds offered size")),
        ])
    }

    func testFinishWithIncompleteBodyAborts() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        _ = logic.handle(.offer(transferId: 1, fileSize: 5, name: "a.txt"))
        _ = logic.handle(.chunk(transferId: 1, data: Data([1, 2])))
        XCTAssertEqual(logic.handle(.finish(transferId: 1)), [
            .abort(transferId: 1),
            .reply(.failed(transferId: 1, reason: "incomplete body")),
        ])
    }

    func testDuplicateTransferIdFails() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        _ = logic.handle(.offer(transferId: 1, fileSize: 5, name: "a.txt"))
        XCTAssertEqual(
            logic.handle(.offer(transferId: 1, fileSize: 9, name: "b.txt")),
            [.reply(.failed(transferId: 1, reason: "duplicate transfer id"))],
        )
    }

    func testOverCapOfferFails() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        let huge = FileTransferProtocolConstants.maxTransferBytes + 1
        XCTAssertEqual(
            logic.handle(.offer(transferId: 1, fileSize: huge, name: "a.txt")),
            [.reply(.failed(transferId: 1, reason: "file too large"))],
        )
    }

    func testBadNameFails() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        XCTAssertEqual(
            logic.handle(.offer(transferId: 1, fileSize: 1, name: "..")),
            [.reply(.failed(transferId: 1, reason: "invalid file name"))],
        )
    }

    func testNameIsSanitizedInOpenEffect() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        let effects = logic.handle(.offer(transferId: 1, fileSize: 1, name: "../../etc/passwd"))
        XCTAssertEqual(effects, [
            .open(transferId: 1, name: "passwd", size: 1),
            .reply(.accept(transferId: 1)),
        ])
    }

    func testCancelAborts() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        _ = logic.handle(.offer(transferId: 1, fileSize: 5, name: "a.txt"))
        XCTAssertEqual(logic.handle(.cancel(transferId: 1)), [.abort(transferId: 1)])
        // A second cancel for a gone transfer is inert.
        XCTAssertEqual(logic.handle(.cancel(transferId: 1)), [])
    }

    func testZeroByteFileCompletes() {
        var logic = FileReceiveLogic()
        afterHello(&logic)
        _ = logic.handle(.offer(transferId: 1, fileSize: 0, name: "empty"))
        XCTAssertEqual(logic.handle(.finish(transferId: 1)), [
            .finalize(transferId: 1),
            .reply(.complete(transferId: 1)),
        ])
    }
}
