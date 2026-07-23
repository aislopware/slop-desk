import Foundation
import XCTest
@testable import SlopDeskProtocol

private func roundTrip(_ message: WireMessage) throws -> WireMessage? {
    let decoder = FrameDecoder()
    decoder.append(message.encode())
    return try decoder.nextMessage()
}

private func decodePayload(_ payload: [UInt8]) throws -> WireMessage {
    try WireMessage.decode(payload: Data(payload))
}

/// Wire type 35 — the host-pushed project git summary (`.projectGitStatus`). Pins the exact byte
/// layout (two `[UInt16 BE len][UTF-8]` strings, then Int32 ahead/behind/stash and UInt32
/// staged/modified/untracked/conflicted/changed, all BE), the round-trip, `wireByteCount` parity,
/// and validate-then-drop on truncated / non-UTF-8 hostile frames.
final class WireMessageProjectGitStatusTests: XCTestCase {
    private func sample(
        repoRoot: String = "/r", branch: String = "m",
    ) -> WireMessage.ProjectGitStatus {
        WireMessage.ProjectGitStatus(
            repoRoot: repoRoot, branch: branch, ahead: 1, behind: 2, stashCount: 3,
            staged: 4, modified: 5, untracked: 6, conflicted: 7, changedCount: 8,
        )
    }

    func testTypeByteAndChannel() {
        XCTAssertEqual(WireMessage.projectGitStatus(sample()).messageType, 35)
        XCTAssertEqual(WireMessage.projectGitStatus(sample()).channel, .control)
    }

    func testExactBytes() {
        XCTAssertEqual(
            [UInt8](WireMessage.projectGitStatus(sample()).encode()),
            [
                0x00, 0x00, 0x00, 0x28, // payload length: 1 type + 4+3 strings + 12 + 20 = 40
                35,
                0x00, 0x02, 0x2F, 0x72, // "/r"
                0x00, 0x01, 0x6D, // "m"
                0x00, 0x00, 0x00, 0x01, // ahead
                0x00, 0x00, 0x00, 0x02, // behind
                0x00, 0x00, 0x00, 0x03, // stash
                0x00, 0x00, 0x00, 0x04, // staged
                0x00, 0x00, 0x00, 0x05, // modified
                0x00, 0x00, 0x00, 0x06, // untracked
                0x00, 0x00, 0x00, 0x07, // conflicted
                0x00, 0x00, 0x00, 0x08, // changed
            ],
        )
    }

    func testRoundTrip() throws {
        let messages: [WireMessage] = [
            .projectGitStatus(sample()),
            .projectGitStatus(sample(repoRoot: "/Users/me/dự án", branch: "tính-năng/tiếng-việt")),
            .projectGitStatus(WireMessage.ProjectGitStatus(
                repoRoot: "/x", branch: "", ahead: -3, behind: Int32.max, stashCount: -1,
                staged: 0, modified: 0, untracked: UInt32.max, conflicted: 0, changedCount: 0,
            )), // detached HEAD, negative/extreme counts carried verbatim
        ]
        for message in messages {
            XCTAssertEqual(try roundTrip(message), message, "\(message)")
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
        }
    }

    func testTruncatedFixedTrailerThrows() {
        // Valid strings, then the fixed trailer cut short mid-Int32 — must throw, never over-read.
        XCTAssertThrowsError(try decodePayload([35, 0x00, 0x01, 0x2F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]))
    }

    func testDeclaredStringLengthPastBodyThrows() {
        // rootLen declares 5 bytes but only 1 follows — readBytes must validate-then-throw.
        XCTAssertThrowsError(try decodePayload([35, 0x00, 0x05, 0x2F]))
    }

    func testInvalidUTF8ThrowsMalformedBody() {
        XCTAssertThrowsError(try decodePayload([35, 0x00, 0x02, 0xFF, 0xFE])) { error in
            guard case .malformedBody = error as? SlopDeskError else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }
}
