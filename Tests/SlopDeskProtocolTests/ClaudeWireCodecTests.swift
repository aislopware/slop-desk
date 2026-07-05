import XCTest
@testable import SlopDeskProtocol

/// W9 — the Claude-Code agent-status wire codecs (terminal CONTROL channel, host → client):
///
/// - **type 26** `foregroundProcess(name:)` — the coarse process-watch path. Body =
///   `[remaining bytes = UTF-8 process basename]` (like `title`). The client derives a
///   `ClaudeStatus` floor (`claude` present → idle) from the name.
/// - **type 27** `claudeStatus(state:kind:label:)` — the rich hook path. Body =
///   `[UInt8 state][UInt8 kind][UInt16 BE labelLen][label UTF-8]`. `state` maps 1:1 to
///   `SlopDeskAgentDetect.ClaudeStatus.urgency` (0 none / 1 idle / 2 done / 3 working /
///   4 needsPermission); `kind` maps the notification class (0 none / 1 permission /
///   2 waitingForInput / 3 other); `label` is the (optional) Stop/Notification message.
///
/// These tests PIN the exact bytes, prove encode↔decode round-trips, and prove
/// validate-then-drop on a truncated body, an over-long declared label length, and an
/// unknown type byte (an older peer must DROP types 26/27 cleanly, never trap).
private func roundTrip(_ message: WireMessage) throws -> WireMessage? {
    let decoder = FrameDecoder()
    decoder.append(message.encode())
    return try decoder.nextMessage()
}

/// Decodes a raw PAYLOAD (`[type][body]`, no length prefix) directly — used to feed
/// hand-crafted hostile bodies that `FrameDecoder` would otherwise frame.
private func decodePayload(_ payload: [UInt8]) throws -> WireMessage {
    try WireMessage.decode(payload: Data(payload))
}

final class ClaudeWireCodecTests: XCTestCase {
    // MARK: type 26 — foregroundProcess

    func testForegroundProcessRoundTrip() throws {
        let cases: [WireMessage] = [
            .foregroundProcess(name: "claude"),
            .foregroundProcess(name: ""), // empty (no foreground / cleared)
            .foregroundProcess(name: "-zsh"),
            .foregroundProcess(name: "node — café 🚀"), // multi-byte UTF-8
        ]
        for message in cases {
            XCTAssertEqual(message.messageType, 26)
            XCTAssertEqual(message.channel, .control)
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testForegroundProcessExactBytes() {
        // payload = [26][ "claude" UTF-8 ]; frame = [UInt32 BE len=7][payload]
        let frame = WireMessage.foregroundProcess(name: "claude").encode()
        XCTAssertEqual(
            [UInt8](frame),
            [0x00, 0x00, 0x00, 0x07, 26, 0x63, 0x6C, 0x61, 0x75, 0x64, 0x65],
        )
    }

    func testForegroundProcessNonUTF8DropsNotTraps() throws {
        // type 26 body with an invalid UTF-8 continuation byte → malformedBody, never a trap.
        XCTAssertThrowsError(try decodePayload([26, 0xFF, 0xFE])) { error in
            guard case SlopDeskError.malformedBody = error else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }

    // MARK: type 27 — claudeStatus

    func testClaudeStatusRoundTrip() throws {
        let cases: [WireMessage] = [
            .claudeStatus(state: 0, kind: 0, label: ""), // none, empty label
            .claudeStatus(state: 1, kind: 0, label: "idle"),
            .claudeStatus(state: 3, kind: 0, label: "Running tests…"), // working
            .claudeStatus(state: 4, kind: 1, label: "Allow Bash(rm -rf)?"), // needsPermission/permission
            .claudeStatus(state: 2, kind: 3, label: "Done — ✅ build green 🚀"), // done, multi-byte
        ]
        for message in cases {
            XCTAssertEqual(message.messageType, 27)
            XCTAssertEqual(message.channel, .control)
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testClaudeStatusExactBytes() {
        // payload = [27][state=4][kind=1][UInt16 BE labelLen=2]['o','k']
        // frame = [UInt32 BE len=7][payload]
        let frame = WireMessage.claudeStatus(state: 4, kind: 1, label: "ok").encode()
        XCTAssertEqual(
            [UInt8](frame),
            [0x00, 0x00, 0x00, 0x07, 27, 0x04, 0x01, 0x00, 0x02, 0x6F, 0x6B],
        )
    }

    func testClaudeStatusEmptyLabelExactBytes() {
        // payload = [27][state=0][kind=0][UInt16 BE labelLen=0]
        let frame = WireMessage.claudeStatus(state: 0, kind: 0, label: "").encode()
        XCTAssertEqual(
            [UInt8](frame),
            [0x00, 0x00, 0x00, 0x05, 27, 0x00, 0x00, 0x00, 0x00],
        )
    }

    func testClaudeStatusMaxLabelRoundTrips() throws {
        // A label exactly at the UInt16 length-field ceiling (65535 ASCII bytes) round-trips.
        let label = String(repeating: "x", count: Int(UInt16.max))
        let message = WireMessage.claudeStatus(state: 3, kind: 2, label: label)
        XCTAssertEqual(try roundTrip(message), message)
    }

    func testClaudeStatusStateAndKindBytesPreserved() throws {
        // Every state/kind byte we will ever send (0…4 state, 0…3 kind) survives the round-trip.
        for state: UInt8 in 0...4 {
            for kind: UInt8 in 0...3 {
                let message = WireMessage.claudeStatus(state: state, kind: kind, label: "L")
                guard case let .claudeStatus(s, k, l)? = try roundTrip(message) else {
                    XCTFail("expected claudeStatus for state=\(state) kind=\(kind)")
                    continue
                }
                XCTAssertEqual(s, state)
                XCTAssertEqual(k, kind)
                XCTAssertEqual(l, "L")
            }
        }
    }

    // MARK: validate-then-drop (hostile / truncated bodies)

    func testClaudeStatusTruncatedBodyDrops() throws {
        // type 27 with NO body (missing state) → truncated, never a trap.
        XCTAssertThrowsError(try decodePayload([27])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
        // type 27 with state but no kind → truncated.
        XCTAssertThrowsError(try decodePayload([27, 0x03])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
        // type 27 with state + kind but a half-read UInt16 labelLen → truncated.
        XCTAssertThrowsError(try decodePayload([27, 0x03, 0x00, 0x00])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    func testClaudeStatusOverLongLabelLengthDrops() throws {
        // labelLen claims 5 bytes but only 1 is present → must validate the declared length
        // BEFORE reading and DROP (truncated), never over-read a hostile datagram.
        XCTAssertThrowsError(try decodePayload([27, 0x01, 0x00, 0x00, 0x05, 0x41])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    func testClaudeStatusNonUTF8LabelDrops() throws {
        // labelLen=2 with invalid UTF-8 label bytes → malformedBody (strict UTF-8), never a trap.
        XCTAssertThrowsError(try decodePayload([27, 0x01, 0x00, 0x00, 0x02, 0xFF, 0xFE])) { error in
            guard case SlopDeskError.malformedBody = error else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }

    // MARK: unknown-type drop (older-peer forward-compat)

    func testUnknownTypeByteDropsNotTraps() throws {
        // An older peer that does not know 26/27 (or any future tag) DROPS the frame via
        // unknownMessageType — validate-then-drop, never a trap. (16/28/29/30/31 are now assigned
        // metadata/block/inputEcho tags, so use a still-unassigned tag.)
        for unknown: UInt8 in [17, 99, 0, 255] {
            XCTAssertThrowsError(try decodePayload([unknown, 0xAB, 0xCD])) { error in
                XCTAssertEqual(error as? SlopDeskError, .unknownMessageType(unknown))
            }
        }
    }

    // MARK: wireByteCount parity (flow-control debit == encode().count)

    func testWireByteCountMatchesEncode() {
        let cases: [WireMessage] = [
            .foregroundProcess(name: "claude"),
            .foregroundProcess(name: ""),
            .foregroundProcess(name: "node — café 🚀"),
            .claudeStatus(state: 0, kind: 0, label: ""),
            .claudeStatus(state: 4, kind: 1, label: "Allow Bash(rm -rf)?"),
            .claudeStatus(state: 2, kind: 3, label: "Done — ✅ 🚀"),
        ]
        for message in cases {
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
        }
    }
}
