import Foundation
import XCTest
@testable import SlopDeskProtocol

/// The `progress` wire codec (terminal CONTROL channel, host → client, type 32):
///
/// - `progress(state: UInt8, percent: UInt8)` — the OSC 9;4 taskbar-progress badge. Body = a flat
///   2-byte `[UInt8 state][UInt8 percent]` (no BE for single bytes). The state is carried VERBATIM
///   (an unknown discriminant is NOT rejected by the codec — the byte round-trip stays faithful so the
///   golden vector is stable; the client validates via `ProgressState(wire:)`).
///
/// These PIN the exact bytes, prove encode↔decode round-trips, pin `wireByteCount == encode().count`
/// (flow-control debit parity), prove validate-then-drop on a truncated body, and prove a longer-than-2
/// body / a following frame are not corrupted. They REVERT-TO-FAIL on the un-fixed code: before type 32
/// existed, `decode([32, …])` threw `unknownMessageType` and there was no `.progress` case at all.
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

final class WireMessageProgressRoundTripTests: XCTestCase {
    // MARK: type byte + channel

    func testTypeByteAndChannel() {
        XCTAssertEqual(WireMessage.progress(state: 1, percent: 40).messageType, 32)
        XCTAssertEqual(WireMessage.progress(state: 0, percent: 0).channel, .control)
    }

    // MARK: exact bytes (the golden-pinned frames)

    func testExactBytes() {
        // payload = [32][state][percent]; frame = [UInt32 BE len=3][payload].
        // state 1, percent 40 (0x28) → matches golden `00000003200128`.
        XCTAssertEqual(
            [UInt8](WireMessage.progress(state: 1, percent: 40).encode()),
            [0x00, 0x00, 0x00, 0x03, 32, 0x01, 0x28],
        )
        // state 2, percent 80 (0x50) → matches golden `00000003200250`.
        XCTAssertEqual(
            [UInt8](WireMessage.progress(state: 2, percent: 80).encode()),
            [0x00, 0x00, 0x00, 0x03, 32, 0x02, 0x50],
        )
    }

    // MARK: round-trip across the four canonical states + boundary bytes

    func testRoundTrip() throws {
        let messages: [WireMessage] = [
            .progress(state: 0, percent: 0),
            .progress(state: 1, percent: 40),
            .progress(state: 2, percent: 80),
            .progress(state: 3, percent: 0),
            .progress(state: 1, percent: 100),
            .progress(state: 255, percent: 255), // codec carries unknown state VERBATIM
        ]
        for message in messages {
            XCTAssertEqual(try roundTrip(message), message, "\(message)")
        }
    }

    // MARK: codec carries an unknown state verbatim (client validates, not the decoder)

    func testDecoderDoesNotRejectUnknownState() throws {
        // The decoder must NOT validate the state enum (keep the byte round-trip faithful for the
        // golden vector); a state of 9 decodes as `.progress(state: 9, …)`, and the CLIENT drops it.
        XCTAssertEqual(try decodePayload([32, 0x09, 0x32]), .progress(state: 9, percent: 50))
    }

    // MARK: validate-then-drop (truncated body)

    func testMissingPercentByteDrops() throws {
        // type 32 with only the state byte (no percent) → truncated, never a trap.
        XCTAssertThrowsError(try decodePayload([32, 0x01])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    func testMissingBodyDrops() throws {
        // type 32 with NO body at all → truncated.
        XCTAssertThrowsError(try decodePayload([32])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    // MARK: forward-tolerance — trailing bytes ignored, next frame intact

    func testTrailingBytesAreToleratedNotTrapped() throws {
        // The fixed-field decoders ignore trailing bytes; type 32 reads the first two body bytes and
        // tolerates the rest (never traps on a longer-than-expected body).
        XCTAssertEqual(try decodePayload([32, 0x01, 0x28, 0xAB, 0xCD]), .progress(state: 1, percent: 40))
    }

    func testTrailingBytesInOneFrameDoNotCorruptTheNextFrame() throws {
        // A progress frame whose declared length INCLUDES two junk trailing bytes, immediately followed
        // by a `bell` frame: the length prefix bounds the over-long body, so the bell still decodes.
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x05, 32, 0x01, 0x28, 0xAB, 0xCD] // len=5 progress + junk
        bytes.append(contentsOf: [UInt8](WireMessage.bell.encode()))
        let decoder = FrameDecoder()
        decoder.append(Data(bytes))
        XCTAssertEqual(try decoder.nextMessage(), .progress(state: 1, percent: 40))
        XCTAssertEqual(try decoder.nextMessage(), .bell)
    }

    // MARK: wireByteCount parity (flow-control debit == encode().count)

    func testWireByteCountMatchesEncode() {
        let messages: [WireMessage] = [
            .progress(state: 0, percent: 0),
            .progress(state: 1, percent: 40),
            .progress(state: 2, percent: 80),
            .progress(state: 3, percent: 0),
        ]
        for message in messages {
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
            XCTAssertEqual(message.wireByteCount, 7, "4 len prefix + 1 type + 2 body")
        }
    }
}
