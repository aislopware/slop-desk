import Foundation
import XCTest
@testable import SlopDeskProtocol

/// E17 / I22 — the secure-input echo wire codec (terminal CONTROL channel, host → client):
///
/// - **type 31** `inputEcho(enabled:)` — the PTY termios `ECHO` edge that drives AUTO Secure
///   Keyboard Entry. Body = a single `[UInt8 enabled]` (`1` = canonical echo on, `0` = no-echo
///   password prompt). `enabled = false` means the remote shell cleared `ECHO` (sudo/ssh/read -s).
///
/// These tests PIN the exact bytes, prove encode↔decode round-trips, pin `wireByteCount ==
/// encode().count` (flow-control debit parity), and prove validate-then-drop on a truncated body +
/// the untrusted-bool read (`byte != 0`, never assuming `{0,1}`). They REVERT-TO-FAIL on the
/// un-fixed code: before type 31 existed, `decode([31, …])` threw `unknownMessageType` and there was
/// no `.inputEcho` case at all.
private func roundTrip(_ message: WireMessage) throws -> WireMessage? {
    let decoder = FrameDecoder()
    decoder.append(message.encode())
    return try decoder.nextMessage()
}

/// Decodes a raw PAYLOAD (`[type][body]`, no length prefix) directly — used to feed hand-crafted
/// hostile bodies that `FrameDecoder` would otherwise frame.
private func decodePayload(_ payload: [UInt8]) throws -> WireMessage {
    try WireMessage.decode(payload: Data(payload))
}

final class WireMessageInputEchoTests: XCTestCase {
    // MARK: type byte + channel

    func testTypeByteAndChannel() {
        XCTAssertEqual(WireMessage.inputEcho(enabled: true).messageType, 31)
        XCTAssertEqual(WireMessage.inputEcho(enabled: false).messageType, 31)
        XCTAssertEqual(WireMessage.inputEcho(enabled: true).channel, .control)
        XCTAssertEqual(WireMessage.inputEcho(enabled: false).channel, .control)
    }

    // MARK: exact bytes (the golden-pinned frames)

    func testEnabledFalseExactBytes() {
        // payload = [31][0]; frame = [UInt32 BE len=2][payload]. Matches golden `000000021f00`.
        XCTAssertEqual(
            [UInt8](WireMessage.inputEcho(enabled: false).encode()),
            [0x00, 0x00, 0x00, 0x02, 31, 0x00],
        )
    }

    func testEnabledTrueExactBytes() {
        // payload = [31][1]; frame = [UInt32 BE len=2][payload]. Matches golden `000000021f01`.
        XCTAssertEqual(
            [UInt8](WireMessage.inputEcho(enabled: true).encode()),
            [0x00, 0x00, 0x00, 0x02, 31, 0x01],
        )
    }

    // MARK: round-trip

    func testRoundTrip() throws {
        for message in [WireMessage.inputEcho(enabled: true), .inputEcho(enabled: false)] {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    // MARK: untrusted-bool read (byte != 0, never assume {0,1})

    func testNonOneTrueByteDecodesAsEnabled() throws {
        // Any non-zero byte means echo-on (untrusted-bool rule): 0xFF / 0x02 → enabled == true.
        XCTAssertEqual(try decodePayload([31, 0xFF]), .inputEcho(enabled: true))
        XCTAssertEqual(try decodePayload([31, 0x02]), .inputEcho(enabled: true))
        XCTAssertEqual(try decodePayload([31, 0x00]), .inputEcho(enabled: false))
    }

    // MARK: validate-then-drop (truncated body)

    func testMissingBodyDrops() throws {
        // type 31 with NO body (missing the enabled byte) → truncated, never a trap.
        XCTAssertThrowsError(try decodePayload([31])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    // MARK: forward-tolerance — a peer that does not know type 31 drops cleanly

    func testTrailingBytesAreToleratedNotTrapped() throws {
        // The fixed-field decoders (bell/ack/…) ignore trailing bytes; type 31 reads the first body
        // byte and tolerates the rest (never traps on a longer-than-expected body).
        XCTAssertEqual(try decodePayload([31, 0x01, 0xAB, 0xCD]), .inputEcho(enabled: true))
    }

    // MARK: wireByteCount parity (flow-control debit == encode().count)

    func testWireByteCountMatchesEncode() {
        for message in [WireMessage.inputEcho(enabled: true), .inputEcho(enabled: false)] {
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
            XCTAssertEqual(message.wireByteCount, 6, "4 len prefix + 1 type + 1 body")
        }
    }
}
