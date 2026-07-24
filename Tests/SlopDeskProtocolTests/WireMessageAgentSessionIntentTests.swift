import Foundation
import XCTest
@testable import SlopDeskProtocol

private func roundTripIntent(_ message: WireMessage) throws -> WireMessage? {
    let decoder = FrameDecoder()
    decoder.append(message.encode())
    return try decoder.nextMessage()
}

private func decodeIntentPayload(_ payload: [UInt8]) throws -> WireMessage {
    try WireMessage.decode(payload: Data(payload))
}

/// Type 36 `agentSessionIntent` (host → client, CONTROL): the sticky agent-session intent line,
/// a single trailing UTF-8 string — the `cwd`/`projectKey` shape. Empty = cleared.
final class WireMessageAgentSessionIntentTests: XCTestCase {
    func testTypeByteAndChannel() {
        XCTAssertEqual(WireMessage.agentSessionIntent("fix CI").messageType, 36)
        XCTAssertEqual(WireMessage.agentSessionIntent("fix CI").channel, .control)
    }

    func testExactBytes() {
        XCTAssertEqual(
            [UInt8](WireMessage.agentSessionIntent("fix").encode()),
            [0x00, 0x00, 0x00, 0x04, 36, 0x66, 0x69, 0x78],
        )
    }

    func testRoundTrip() throws {
        let messages: [WireMessage] = [
            .agentSessionIntent("fix the flaky CI test"),
            .agentSessionIntent("sửa test tiếng Việt ✳"),
            .agentSessionIntent(""), // the CLEAR frame (session ended)
        ]
        for message in messages {
            XCTAssertEqual(try roundTripIntent(message), message, "\(message)")
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
        }
    }

    func testInvalidUTF8ThrowsMalformedBody() {
        XCTAssertThrowsError(try decodeIntentPayload([36, 0xFF, 0xFE])) { error in
            guard case .malformedBody = error as? SlopDeskError else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }
}
