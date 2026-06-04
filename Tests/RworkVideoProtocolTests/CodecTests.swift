import XCTest
@testable import RworkVideoProtocol

/// Cursor / window-geometry / input-event / recovery-signaling codec round-trips,
/// plus the <64-byte cursor-message size assertion.
final class CodecTests: XCTestCase {

    // MARK: Cursor side-channel

    func testCursorUpdateRoundTrip() throws {
        let cases = [
            CursorUpdate(position: VideoPoint(x: 0, y: 0), shapeID: 0, hotspot: VideoPoint(x: 0, y: 0), visible: true),
            CursorUpdate(position: VideoPoint(x: 1234.5, y: -987.25), shapeID: 65535, hotspot: VideoPoint(x: 8, y: 16), visible: false),
            CursorUpdate(position: VideoPoint(x: 0.5, y: 0.5), shapeID: 7, hotspot: VideoPoint(x: 1.5, y: 2.5), visible: true),
        ]
        for update in cases {
            let decoded = try CursorUpdate.decode(update.encode())
            XCTAssertEqual(decoded, update)
        }
    }

    /// The cursor message MUST be < 64 bytes (doc 17 §3.3) so it can fire at ~120 Hz.
    func testCursorUpdateIsUnder64Bytes() {
        let update = CursorUpdate(position: VideoPoint(x: 1920, y: 1080), shapeID: 42, hotspot: VideoPoint(x: 8, y: 8))
        let encoded = update.encode()
        XCTAssertLessThan(encoded.count, 64, "cursor side-channel message must be < 64 bytes")
        XCTAssertEqual(encoded.count, CursorUpdate.encodedSize)
        XCTAssertEqual(encoded.count, 36)
    }

    func testCursorUpdateRejectsWrongType() {
        var bytes = Data([99]) // wrong type byte
        bytes.append(Data(repeating: 0, count: 35))
        XCTAssertThrowsError(try CursorUpdate.decode(bytes))
    }

    func testCursorUpdateRejectsNonFiniteFloatFields() {
        // Symmetric to testInputEventRejectsNonFiniteFloatFields (host-bound): the CLIENT-bound cursor
        // codec must also reject NaN/±inf. A non-finite position/hotspot off the wire would propagate
        // NaN through the client's aspect-fit math into a CALayer frame → uncaught CALayerInvalidGeometry
        // crash. Decode must throw .malformed so receiveCursor drops the single packet (audit FIX:
        // cursor-NaN client crash). Encode/decode round-trips the raw IEEE-754 bits, so we can craft one.
        let nonFinite: [CursorUpdate] = [
            CursorUpdate(position: VideoPoint(x: .nan, y: 0), shapeID: 1, hotspot: VideoPoint(x: 0, y: 0)),
            CursorUpdate(position: VideoPoint(x: 0, y: .infinity), shapeID: 1, hotspot: VideoPoint(x: 0, y: 0)),
            CursorUpdate(position: VideoPoint(x: 0, y: 0), shapeID: 1, hotspot: VideoPoint(x: -.infinity, y: 0)),
            CursorUpdate(position: VideoPoint(x: 0, y: 0), shapeID: 1, hotspot: VideoPoint(x: 0, y: .nan)),
        ]
        for update in nonFinite {
            XCTAssertThrowsError(try CursorUpdate.decode(update.encode()), "expected \(update.position) to be rejected") { error in
                guard let e = error as? VideoProtocolError, case .malformed = e else {
                    return XCTFail("expected .malformed, got \(error)")
                }
            }
        }
        // A finite (even large/negative) position still decodes — only non-finite is rejected.
        XCTAssertNoThrow(try CursorUpdate.decode(
            CursorUpdate(position: VideoPoint(x: 1e9, y: -1e9), shapeID: 2, hotspot: VideoPoint(x: 8, y: 8)).encode()))
    }

    // MARK: Window geometry

    func testWindowGeometryRoundTrip() throws {
        let cases: [WindowGeometryMessage] = [
            .move(VideoPoint(x: 100, y: 200)),
            .resize(VideoSize(width: 1280, height: 800)),
            .bounds(VideoRect(x: -50.5, y: 0, width: 1920, height: 1080.25)),
            .title("Untitled — Project"),
            .title("日本語のタイトル 🚀"),
            .title(""),
        ]
        for message in cases {
            let decoded = try WindowGeometryMessage.decode(message.encode())
            XCTAssertEqual(decoded, message)
        }
    }

    func testWindowGeometryRejectsUnknownType() {
        XCTAssertThrowsError(try WindowGeometryMessage.decode(Data([200])))
    }

    func testWindowGeometryRejectsInvalidUTF8Title() {
        let bytes = Data([4, 0xFF, 0xFE]) // type 4 (title) + invalid UTF-8
        XCTAssertThrowsError(try WindowGeometryMessage.decode(bytes))
    }

    // MARK: Input events

    func testInputEventRoundTrip() throws {
        let cases: [InputEvent] = [
            .mouseMove(normalized: VideoPoint(x: 0.5, y: 0.25), tag: 0xDEADBEEF),
            .mouseDown(button: .left, normalized: VideoPoint(x: 0, y: 0), clickCount: 1, modifiers: [.command, .shift], tag: 1),
            .mouseUp(button: .right, normalized: VideoPoint(x: 1, y: 1), clickCount: 2, modifiers: [.control], tag: 2),
            .mouseDrag(button: .left, normalized: VideoPoint(x: 0.4, y: 0.6), clickCount: 1, modifiers: [.shift], tag: 8),
            .mouseDrag(button: .other, normalized: VideoPoint(x: 0.9, y: 0.1), clickCount: 2, modifiers: [], tag: 9),
            .scroll(dx: -3.5, dy: 12.0, normalized: VideoPoint(x: 0.3, y: 0.7), tag: 3),
            .key(keyCode: 36, down: true, modifiers: [.option, .function], tag: 4),  // Return
            .key(keyCode: 53, down: false, modifiers: [], tag: 5),                    // Escape
            .text("hello 世界", tag: 6),
            .text("", tag: 7),
        ]
        for event in cases {
            let decoded = try InputEvent.decode(event.encode())
            XCTAssertEqual(decoded, event)
            XCTAssertEqual(decoded.tag, event.tag)
        }
    }

    func testInputEventTagIsExposedForSelfInjectFiltering() {
        // The host stamps `tag` on eventSourceUserData to filter its own events.
        XCTAssertEqual(InputEvent.mouseMove(normalized: VideoPoint(x: 0, y: 0), tag: 42).tag, 42)
        XCTAssertEqual(InputEvent.text("x", tag: 7).tag, 7)
    }

    func testInputEventRejectsUnknownButtonAndType() {
        // type 2 (mouseDown), tag(4) + button=9 (invalid)
        var bad = Data([2]); bad.appendBE(UInt32(0)); bad.append(9)
        bad.append(contentsOf: [1, 0]); bad.appendBE(0.0); bad.appendBE(0.0)
        XCTAssertThrowsError(try InputEvent.decode(bad))
        XCTAssertThrowsError(try InputEvent.decode(Data([250])))
    }

    func testInputEventRejectsNonFiniteFloatFields() {
        // A hostile peer can put ANY IEEE-754 bit pattern on the wire (`readFloat64` rebuilds
        // it verbatim). A non-finite coordinate / scroll delta must be rejected at decode: the
        // host's scroll injector converts the delta with the TRAPPING `Int32(Double)`, so a
        // single NaN/±inf datagram would otherwise crash the whole host process. The router
        // turns the throw into a dropped datagram (a corrupt packet must never crash the peer).
        let nonFinite: [InputEvent] = [
            .scroll(dx: .nan, dy: 1, normalized: VideoPoint(x: 0, y: 0), tag: 1),
            .scroll(dx: 1, dy: .infinity, normalized: VideoPoint(x: 0, y: 0), tag: 1),
            .scroll(dx: 1, dy: 1, normalized: VideoPoint(x: .nan, y: 0), tag: 1),
            .mouseMove(normalized: VideoPoint(x: .infinity, y: 0), tag: 1),
            .mouseDown(button: .left, normalized: VideoPoint(x: 0, y: -.infinity), clickCount: 1, modifiers: [], tag: 1),
            .mouseUp(button: .right, normalized: VideoPoint(x: .nan, y: .nan), clickCount: 1, modifiers: [], tag: 1),
            .mouseDrag(button: .left, normalized: VideoPoint(x: .infinity, y: 0.5), clickCount: 1, modifiers: [], tag: 1),
        ]
        for event in nonFinite {
            XCTAssertThrowsError(try InputEvent.decode(event.encode()), "expected \(event) to be rejected") { error in
                guard let e = error as? VideoProtocolError, case .malformed = e else {
                    return XCTFail("expected .malformed for \(event), got \(error)")
                }
            }
        }
        // A FINITE (even very large) scroll delta still decodes — clamping out-of-Int32-range
        // values is the host injector's job (Self.clampToInt32), not decode's.
        XCTAssertNoThrow(try InputEvent.decode(
            InputEvent.scroll(dx: 1e9, dy: -1e9, normalized: VideoPoint(x: 0.5, y: 0.5), tag: 1).encode()))
    }

    func testModifierBitmaskIsStable() {
        let all: InputModifiers = [.shift, .control, .option, .command, .capsLock, .function]
        XCTAssertEqual(all.rawValue, 0b0011_1111)
    }

    // MARK: Recovery signaling

    func testRecoveryMessageRoundTrip() throws {
        let cases: [RecoveryMessage] = [
            .ack(streamSeq: 0),
            .ack(streamSeq: .max),
            .requestLTRRefresh(fromFrameID: 10, toFrameID: 14),
            .requestIDR,
            .requestCursorShape(shapeID: 0),
            .requestCursorShape(shapeID: .max),
        ]
        for message in cases {
            XCTAssertEqual(try RecoveryMessage.decode(message.encode()), message)
        }
    }

    func testRecoveryMessageRejectsUnknownType() {
        XCTAssertThrowsError(try RecoveryMessage.decode(Data([99])))
    }

    func testRecoveryPolicyPrefersLTRThenEscalatesAfterTwoRTT() {
        let policy = RecoveryPolicy(idrTimeoutRTTMultiple: 2.0)
        // First response to a loss is an LTR refresh, not an IDR.
        XCTAssertEqual(policy.initialRequest(lostFrom: 5, lostTo: 8), .requestLTRRefresh(fromFrameID: 5, toFrameID: 8))
        let rtt = 0.011 // 11ms measured
        XCTAssertFalse(policy.shouldEscalateToIDR(elapsedSinceRequest: rtt, rtt: rtt))        // 1 RTT — wait
        XCTAssertFalse(policy.shouldEscalateToIDR(elapsedSinceRequest: 1.9 * rtt, rtt: rtt))  // <2 RTT — wait
        XCTAssertTrue(policy.shouldEscalateToIDR(elapsedSinceRequest: 2.0 * rtt, rtt: rtt))   // 2 RTT — escalate
    }
}
