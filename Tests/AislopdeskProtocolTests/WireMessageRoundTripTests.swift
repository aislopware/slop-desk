import XCTest
@testable import AislopdeskProtocol

/// Encodes a message, feeds the resulting frame bytes through a fresh `FrameDecoder`,
/// and returns the decoded message — the canonical round-trip helper.
private func roundTrip(
    _ message: WireMessage,
    file _: StaticString = #filePath,
    line _: UInt = #line,
) throws -> WireMessage? {
    var decoder = FrameDecoder()
    decoder.append(message.encode())
    return try decoder.nextMessage()
}

final class WireMessageRoundTripTests: XCTestCase {
    func testOutputRoundTripRepresentativeAndBoundary() throws {
        let cases: [WireMessage] = [
            .output(seq: 1, bytes: Data("hello".utf8)),
            .output(seq: Int64.max, bytes: Data()), // empty payload, max seq
            .output(seq: 42, bytes: Data([0x1B, 0x5B, 0x32, 0x4A])), // ESC [ 2 J
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testExitRoundTrip() throws {
        for code: Int32 in [0, 1, -1, Int32.max, Int32.min] {
            let message = WireMessage.exit(code: code)
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testInputRoundTrip() throws {
        let cases: [WireMessage] = [
            .input(Data()), // empty
            .input(Data("ls -la\n".utf8)),
            .input(Data([0x00, 0xFF, 0x80, 0x7F])), // arbitrary bytes incl NUL & high bit
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testHelloRoundTripNewAndResumeSessions() throws {
        let cases: [WireMessage] = [
            .hello(
                protocolVersion: Aislopdesk.protocolVersion,
                sessionID: WireMessage.newSessionID,
                lastReceivedSeq: 0,
            ),
            .hello(protocolVersion: 1, sessionID: UUID(), lastReceivedSeq: Int64.max),
            .hello(protocolVersion: UInt16.max, sessionID: UUID(), lastReceivedSeq: -1),
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testResizeRoundTripBoundaries() throws {
        let cases: [WireMessage] = [
            .resize(cols: 0, rows: 0, pxWidth: 0, pxHeight: 0),
            .resize(cols: 65535, rows: 65535, pxWidth: 65535, pxHeight: 65535),
            .resize(cols: 80, rows: 24, pxWidth: 640, pxHeight: 384),
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testAckRoundTrip() throws {
        for seq: Int64 in [0, 1, Int64.max, -1] {
            let message = WireMessage.ack(seq: seq)
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testByeRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.bye), .bye)
    }

    func testPingPongRoundTrip() throws {
        for ts: UInt64 in [0, 1, 1_749_700_000_123, UInt64.max] {
            XCTAssertEqual(try roundTrip(.ping(timestampMS: ts)), .ping(timestampMS: ts))
            XCTAssertEqual(try roundTrip(.pong(timestampMS: ts)), .pong(timestampMS: ts))
        }
    }

    func testHelloAckRoundTrip() throws {
        let cases: [WireMessage] = [
            .helloAck(sessionID: UUID(), resumeFromSeq: 1, returningClient: true),
            .helloAck(sessionID: WireMessage.newSessionID, resumeFromSeq: 0, returningClient: false),
            .helloAck(sessionID: UUID(), resumeFromSeq: Int64.max, returningClient: true),
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testTitleRoundTripIncludingCJKAndEmoji() throws {
        let cases: [WireMessage] = [
            .title(""), // empty
            .title("zsh — ~/project"),
            .title("日本語タイトル"), // CJK
            .title("build ✅ done 🚀 — café"), // multi-byte emoji + accent
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testBellRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.bell), .bell)
    }

    func testNotificationRoundTripIncludingEmptyTitleAndUnicode() throws {
        let cases: [WireMessage] = [
            .notification(title: "", body: "build done"), // OSC 9: no title
            .notification(title: "CI", body: "all green ✅"), // OSC 777: title + body
            .notification(title: "日本語", body: "完了 🚀"), // multi-byte both fields
            .notification(title: "only title", body: ""), // empty body
            .notification(title: "semis;in;title", body: "and;in;body;too"), // length-prefix beats delimiters
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testNotificationOverlongTitleClampsWithoutCorruptingBody() throws {
        // A >64KiB title would wrap the UInt16 length field and mis-split title/body. The encoder clamps
        // the title to the field's limit so the body is NEVER corrupted (encode/decode stay symmetric).
        let body = "the body must survive intact — ✅"
        let decoded = try roundTrip(.notification(title: String(repeating: "T", count: 70000), body: body))
        guard case let .notification(dTitle, dBody)? = decoded else { XCTFail("not a notification")
            return
        }
        XCTAssertEqual(dBody, body, "the body is never corrupted by an overlong title (the wrap bug)")
        XCTAssertLessThanOrEqual(Data(dTitle.utf8).count, Int(UInt16.max), "title clamped to the UInt16 length limit")
        XCTAssertTrue(dTitle.allSatisfy { $0 == "T" }, "the clamped title is a valid prefix of the original")
    }

    func testCommandStatusRoundTrip() throws {
        let cases: [WireMessage] = [
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 0, durationMS: 12000)),
            .commandStatus(.idle(exitCode: 1, durationMS: 300)),
            .commandStatus(.idle(exitCode: 130, durationMS: 0)),
            .commandStatus(.idle(exitCode: -1, durationMS: 1)), // negative exit preserved
            .commandStatus(.idle(exitCode: Int32.min, durationMS: UInt32.max)), // boundary
            .commandStatus(.idle(exitCode: nil, durationMS: 5000)), // unreported exit (nil)
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    /// A `commandStatus` (type 23) frame with an unknown tag byte must throw `.malformedBody`.
    func testCommandStatusInvalidTagThrowsMalformedBody() {
        let body = Data([23, 0x09]) // type 23 + bogus tag 9 (only 0=running / 1=idle valid)
        var frame = Data()
        frame.appendBE(UInt32(body.count))
        frame.append(body)
        var decoder = FrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextMessage()) { error in
            guard case .malformedBody = (error as? AislopdeskError) else {
                return XCTFail("expected .malformedBody, got \(error)")
            }
        }
    }

    func testMessageTypeBytesMatchContract() {
        XCTAssertEqual(WireMessage.output(seq: 1, bytes: Data()).messageType, 1)
        XCTAssertEqual(WireMessage.exit(code: 0).messageType, 2)
        XCTAssertEqual(WireMessage.input(Data()).messageType, 3)
        XCTAssertEqual(WireMessage.hello(protocolVersion: 1, sessionID: UUID(), lastReceivedSeq: 0).messageType, 10)
        XCTAssertEqual(WireMessage.resize(cols: 0, rows: 0, pxWidth: 0, pxHeight: 0).messageType, 11)
        XCTAssertEqual(WireMessage.ack(seq: 0).messageType, 12)
        XCTAssertEqual(WireMessage.bye.messageType, 13)
        XCTAssertEqual(WireMessage.ping(timestampMS: 0).messageType, 14)
        XCTAssertEqual(
            WireMessage.helloAck(sessionID: UUID(), resumeFromSeq: 0, returningClient: false).messageType,
            20,
        )
        XCTAssertEqual(WireMessage.title("").messageType, 21)
        XCTAssertEqual(WireMessage.bell.messageType, 22)
        XCTAssertEqual(WireMessage.commandStatus(.running).messageType, 23)
        XCTAssertEqual(WireMessage.commandStatus(.idle(exitCode: 0, durationMS: 0)).messageType, 23)
        XCTAssertEqual(WireMessage.pong(timestampMS: 0).messageType, 24)
    }

    func testChannelAssignment() {
        XCTAssertEqual(WireMessage.output(seq: 1, bytes: Data()).channel, .data)
        XCTAssertEqual(WireMessage.exit(code: 0).channel, .data)
        XCTAssertEqual(WireMessage.input(Data()).channel, .data)
        XCTAssertEqual(WireMessage.hello(protocolVersion: 1, sessionID: UUID(), lastReceivedSeq: 0).channel, .control)
        XCTAssertEqual(WireMessage.bye.channel, .control)
        XCTAssertEqual(WireMessage.bell.channel, .control)
        XCTAssertEqual(WireMessage.commandStatus(.running).channel, .control)
        XCTAssertEqual(WireMessage.ping(timestampMS: 0).channel, .control)
        XCTAssertEqual(WireMessage.pong(timestampMS: 0).channel, .control)
    }

    // MARK: Decode error paths (complete-but-invalid frames)

    /// A frame whose declared payload length is honest (the whole frame arrives) but
    /// whose body is shorter than its message type requires must throw `.truncated`
    /// at decode time — distinct from a partial TCP read, which merely waits.
    func testCompleteFrameWithShortBodyThrowsTruncated() {
        // exit (type 2) needs a 4-byte Int32 code; supply only the type byte.
        var exitFrame = Data()
        exitFrame.appendBE(UInt32(1)) // payloadLength = 1 (just the type byte)
        exitFrame.append(2) // type = exit, missing 4 code bytes
        var exitDecoder = FrameDecoder()
        exitDecoder.append(exitFrame)
        XCTAssertThrowsError(try exitDecoder.nextMessage()) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }

        // resize (type 11) needs 8 body bytes (4 × UInt16); supply only 3.
        let resizeBody = Data([11, 0x00, 0x50, 0x00]) // type + 3 of 8 required bytes
        var resizeFrame = Data()
        resizeFrame.appendBE(UInt32(resizeBody.count))
        resizeFrame.append(resizeBody)
        var resizeDecoder = FrameDecoder()
        resizeDecoder.append(resizeFrame)
        XCTAssertThrowsError(try resizeDecoder.nextMessage()) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    /// A `title` (type 21) body with the right framing but invalid UTF-8 must throw
    /// `.malformedBody`, exercising the `String(data:encoding:.utf8)` guard.
    func testTitleWithInvalidUTF8ThrowsMalformedBody() {
        let body = Data([21, 0xFF, 0xFE, 0xFD]) // type 21 + invalid UTF-8 bytes
        var frame = Data()
        frame.appendBE(UInt32(body.count))
        frame.append(body)
        var decoder = FrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextMessage()) { error in
            guard case .malformedBody = (error as? AislopdeskError) else {
                return XCTFail("expected .malformedBody, got \(error)")
            }
        }
    }

    func testFrameLayoutLengthPrefixExcludesPrefixBytes() {
        // output(seq:1, bytes:"abc") => body = [type(1)] + [8-byte seq] + 3 bytes = 12.
        let frame = WireMessage.output(seq: 1, bytes: Data("abc".utf8)).encode()
        XCTAssertEqual(frame.count, 4 + 12)
        // Big-endian prefix == 12.
        let prefix = (UInt32(frame[0]) << 24) | (UInt32(frame[1]) << 16) | (UInt32(frame[2]) << 8) | UInt32(frame[3])
        XCTAssertEqual(prefix, 12)
        // First payload byte is the message type.
        XCTAssertEqual(frame[4], 1)
    }
}
