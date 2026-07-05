import Foundation
import XCTest
@testable import SlopDeskProtocol

private func roundTripCwd(_ message: WireMessage) throws -> WireMessage? {
    let decoder = FrameDecoder()
    decoder.append(message.encode())
    return try decoder.nextMessage()
}

private func decodeCwdPayload(_ payload: [UInt8]) throws -> WireMessage {
    try WireMessage.decode(payload: Data(payload))
}

final class WireMessageCwdRoundTripTests: XCTestCase {
    func testTypeByteAndChannel() {
        XCTAssertEqual(WireMessage.cwd("/Users/me/project").messageType, 33)
        XCTAssertEqual(WireMessage.cwd("/Users/me/project").channel, .control)
    }

    func testExactBytes() {
        XCTAssertEqual(
            [UInt8](WireMessage.cwd("/tmp/x").encode()),
            [0x00, 0x00, 0x00, 0x07, 33, 0x2F, 0x74, 0x6D, 0x70, 0x2F, 0x78],
        )
    }

    func testRoundTrip() throws {
        let messages: [WireMessage] = [
            .cwd("/tmp/x"),
            .cwd("/Users/me/project dir"),
            .cwd("/Users/me/tiếng Việt"),
        ]
        for message in messages {
            XCTAssertEqual(try roundTripCwd(message), message, "\(message)")
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
        }
    }

    func testInvalidUTF8ThrowsMalformedBody() {
        XCTAssertThrowsError(try decodeCwdPayload([33, 0xFF, 0xFE])) { error in
            guard case .malformedBody = error as? SlopDeskError else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }
}
