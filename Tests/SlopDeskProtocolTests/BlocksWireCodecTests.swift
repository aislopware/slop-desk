import Foundation
import XCTest
@testable import SlopDeskProtocol

/// WB1 — the Warp-style "Blocks" wire codecs (terminal CONTROL channel):
///
/// - **type 28** `commandBlock(index:exitCode:durationMS:complete:outputLen:commandText:promptOrdinal:)` —
///   block METADATA only (NOT the output bytes), host → client. Body =
///   `[UInt32 index][UInt8 hasExit][Int32 BE exit][UInt8 hasDuration][UInt32 BE duration]
///    [UInt8 complete][UInt32 BE outputLen][UInt32 BE promptOrdinal][UInt16 BE cmdLen][commandText UTF-8]`.
/// - **type 15** `requestBlockOutput(index:)` — client → host. Body = `[UInt32 index]`.
/// - **type 29** `blockOutput(index:output:)` — host → client. Body =
///   `[UInt32 index][UInt32 BE outputLen][output bytes]` (output is RAW VT bytes, not UTF-8).
///
/// These PIN the exact bytes, prove encode↔decode round-trips, prove `wireByteCount` parity, and
/// prove validate-then-drop on a truncated body, an over-long declared length, and a non-UTF-8
/// command text — never a trap on a hostile datagram.
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

final class BlocksWireCodecTests: XCTestCase {
    // MARK: type 15 — requestBlockOutput (client → host)

    func testRequestBlockOutputRoundTrip() throws {
        for index: UInt32 in [0, 1, 0x0102_0304, UInt32.max] {
            let message = WireMessage.requestBlockOutput(index: index)
            XCTAssertEqual(message.messageType, 15)
            XCTAssertEqual(message.channel, .control)
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testRequestBlockOutputExactBytes() {
        // payload = [15][index BE 0x01020304]; frame = [UInt32 BE len=5][payload]
        let frame = WireMessage.requestBlockOutput(index: 0x0102_0304).encode()
        XCTAssertEqual(
            [UInt8](frame),
            [0x00, 0x00, 0x00, 0x05, 15, 0x01, 0x02, 0x03, 0x04],
        )
    }

    func testRequestBlockOutputTruncatedDrops() throws {
        // type 15 with a half-read UInt32 index → truncated, never a trap.
        XCTAssertThrowsError(try decodePayload([15, 0x00, 0x01])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
        XCTAssertThrowsError(try decodePayload([15])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    // MARK: type 28 — commandBlock (metadata, host → client)

    func testCommandBlockRoundTrip() throws {
        let cases: [WireMessage] = [
            .commandBlock(
                index: 0, exitCode: 0, durationMS: 1250, complete: true, outputLen: 3, commandText: "ls",
                promptOrdinal: 1,
            ),
            // running block: no exit, no duration, not complete, empty command, unknown ordinal.
            .commandBlock(
                index: 1, exitCode: nil, durationMS: nil, complete: false, outputLen: 0, commandText: "",
                promptOrdinal: 0,
            ),
            // negative exit + max duration + multi-byte command text.
            .commandBlock(
                index: 42,
                exitCode: Int32.min,
                durationMS: UInt32.max,
                complete: true,
                outputLen: 262_144,
                commandText: "grep · 文字 🚀",
                promptOrdinal: UInt32.max,
            ),
            // exit absent but duration present (distinct presence bytes).
            .commandBlock(
                index: 7, exitCode: nil, durationMS: 5, complete: true, outputLen: 1, commandText: "x",
                promptOrdinal: 9,
            ),
            // exit present but duration absent.
            .commandBlock(
                index: 8, exitCode: 130, durationMS: nil, complete: false, outputLen: 99, commandText: "y",
                promptOrdinal: 12,
            ),
        ]
        for message in cases {
            XCTAssertEqual(message.messageType, 28)
            XCTAssertEqual(message.channel, .control)
            XCTAssertEqual(try roundTrip(message), message, "\(message)")
        }
    }

    func testCommandBlockExactBytes() {
        // index=7, exit=0 (present), duration=1250 (present, 0x000004E2), complete=1, outputLen=3,
        // promptOrdinal=8, cmd="ls" (cmdLen=2).
        // payload = [28][00000007][01][00000000][01][000004E2][01][00000003][00000008][0002]['l','s']
        let message = WireMessage.commandBlock(
            index: 7, exitCode: 0, durationMS: 1250, complete: true, outputLen: 3, commandText: "ls",
            promptOrdinal: 8,
        )
        let body: [UInt8] = [
            28,
            0x00, 0x00, 0x00, 0x07, // index
            0x01, // hasExit
            0x00, 0x00, 0x00, 0x00, // exit = 0
            0x01, // hasDuration
            0x00, 0x00, 0x04, 0xE2, // duration = 1250
            0x01, // complete
            0x00, 0x00, 0x00, 0x03, // outputLen = 3
            0x00, 0x00, 0x00, 0x08, // promptOrdinal = 8
            0x00, 0x02, // cmdLen = 2
            0x6C, 0x73, // "ls"
        ]
        var frame: [UInt8] = [0x00, 0x00, 0x00, UInt8(body.count)]
        frame.append(contentsOf: body)
        XCTAssertEqual([UInt8](message.encode()), frame)
    }

    func testCommandBlockAbsentExitAndDurationExactBytes() {
        // running block: hasExit=0, exit field still present (0), hasDuration=0, duration field 0.
        let message = WireMessage.commandBlock(
            index: 0, exitCode: nil, durationMS: nil, complete: false, outputLen: 0, commandText: "",
            promptOrdinal: 0,
        )
        let body: [UInt8] = [
            28,
            0x00, 0x00, 0x00, 0x00, // index
            0x00, // hasExit = 0
            0x00, 0x00, 0x00, 0x00, // exit = 0 (absent)
            0x00, // hasDuration = 0
            0x00, 0x00, 0x00, 0x00, // duration = 0 (absent)
            0x00, // complete = 0
            0x00, 0x00, 0x00, 0x00, // outputLen = 0
            0x00, 0x00, 0x00, 0x00, // promptOrdinal = 0 (unknown)
            0x00, 0x00, // cmdLen = 0
        ]
        var frame: [UInt8] = [0x00, 0x00, 0x00, UInt8(body.count)]
        frame.append(contentsOf: body)
        XCTAssertEqual([UInt8](message.encode()), frame)
    }

    func testCommandBlockMaxCommandTextRoundTrips() throws {
        // A command text exactly at the UInt16 length-field ceiling (65535 ASCII bytes) round-trips.
        let cmd = String(repeating: "x", count: Int(UInt16.max))
        let message = WireMessage.commandBlock(
            index: 3, exitCode: 1, durationMS: 9, complete: true, outputLen: 0, commandText: cmd,
            promptOrdinal: 4,
        )
        XCTAssertEqual(try roundTrip(message), message)
    }

    func testCommandBlockTruncatedBodyDrops() throws {
        // Each prefix that stops before a required fixed field → truncated, never a trap.
        let truncations: [[UInt8]] = [
            [28], // no index
            [28, 0x00, 0x00, 0x00, 0x07], // index but no hasExit
            [28, 0x00, 0x00, 0x00, 0x07, 0x01], // hasExit but partial exit
            [28, 0x00, 0x00, 0x00, 0x07, 0x01, 0x00, 0x00, 0x00, 0x00], // exit but no hasDuration
            // through outputLen but a half-read promptOrdinal.
            [28, 0, 0, 0, 7, 1, 0, 0, 0, 0, 1, 0, 0, 4, 0xE2, 1, 0, 0, 0, 3, 0x00, 0x00],
            // through promptOrdinal but a half-read cmdLen.
            [28, 0, 0, 0, 7, 1, 0, 0, 0, 0, 1, 0, 0, 4, 0xE2, 1, 0, 0, 0, 3, 0, 0, 0, 8, 0x00],
        ]
        for payload in truncations {
            XCTAssertThrowsError(try decodePayload(payload)) { error in
                XCTAssertEqual(error as? SlopDeskError, .truncated, "\(payload)")
            }
        }
    }

    func testCommandBlockOverLongCommandLengthDrops() throws {
        // cmdLen claims 5 bytes but only 1 is present → validate the declared length BEFORE reading
        // and DROP (truncated), never over-read a hostile datagram.
        let payload: [UInt8] = [
            28, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // fixed fields, index=1
            0x00, 0x05, // cmdLen = 5
            0x41, // only 1 byte present
        ]
        XCTAssertThrowsError(try decodePayload(payload)) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    func testCommandBlockNonUTF8CommandDrops() throws {
        // cmdLen=2 with invalid UTF-8 command bytes → malformedBody (strict UTF-8), never a trap.
        let payload: [UInt8] = [
            28, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0x00, 0x02, 0xFF, 0xFE,
        ]
        XCTAssertThrowsError(try decodePayload(payload)) { error in
            guard case SlopDeskError.malformedBody = error else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }

    // MARK: type 29 — blockOutput (output bytes, host → client)

    func testBlockOutputRoundTrip() throws {
        let cases: [WireMessage] = [
            .blockOutput(index: 0, output: Data()), // evicted / empty
            .blockOutput(index: 5, output: Data([0xAA, 0xBB, 0xCC])),
            // raw VT bytes incl. ESC + control sequences (NOT UTF-8 — must survive verbatim).
            .blockOutput(index: 42, output: Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x00, 0xFF, 0x80, 0x7F])),
        ]
        for message in cases {
            XCTAssertEqual(message.messageType, 29)
            XCTAssertEqual(message.channel, .control)
            XCTAssertEqual(try roundTrip(message), message, "\(message)")
        }
    }

    func testBlockOutputExactBytes() {
        // index=5, output=[0xAA,0xBB] (len=2). payload = [29][00000005][00000002][AA BB]
        let message = WireMessage.blockOutput(index: 5, output: Data([0xAA, 0xBB]))
        XCTAssertEqual(
            [UInt8](message.encode()),
            [
                0x00, 0x00, 0x00, 0x0B, // frame len = 11
                29,
                0x00, 0x00, 0x00, 0x05, // index
                0x00, 0x00, 0x00, 0x02, // outputLen = 2
                0xAA, 0xBB,
            ],
        )
    }

    func testBlockOutputTruncatedDrops() throws {
        // half-read index → truncated.
        XCTAssertThrowsError(try decodePayload([29, 0x00, 0x00])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
        // index but a half-read outputLen → truncated.
        XCTAssertThrowsError(try decodePayload([29, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00])) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    func testBlockOutputOverLongLengthDrops() throws {
        // outputLen claims 256 bytes but only 2 are present → validate BEFORE allocating/reading
        // and DROP (truncated), never over-read / over-allocate on a hostile datagram.
        let payload: [UInt8] = [
            29,
            0x00, 0x00, 0x00, 0x05, // index
            0x00, 0x00, 0x01, 0x00, // outputLen = 256
            0xAA, 0xBB, // only 2 present
        ]
        XCTAssertThrowsError(try decodePayload(payload)) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    // MARK: unknown-type drop (older-peer forward-compat)

    func testUnknownTypeDropsNotTraps() throws {
        // A peer that does not know 15/28/29 DROPS the frame via unknownMessageType, never traps.
        // (16/30 are metadataRequest/metadataResponse and 31 is inputEcho since E17, so use unassigned tags.)
        for unknown: UInt8 in [17, 18, 19, 200] {
            XCTAssertThrowsError(try decodePayload([unknown, 0xAB, 0xCD])) { error in
                XCTAssertEqual(error as? SlopDeskError, .unknownMessageType(unknown))
            }
        }
    }

    // MARK: wireByteCount parity (flow-control debit == encode().count)

    func testWireByteCountMatchesEncode() {
        let cases: [WireMessage] = [
            .requestBlockOutput(index: 0),
            .requestBlockOutput(index: UInt32.max),
            .commandBlock(
                index: 0, exitCode: 0, durationMS: 1250, complete: true, outputLen: 3, commandText: "ls",
                promptOrdinal: 1,
            ),
            .commandBlock(
                index: 1, exitCode: nil, durationMS: nil, complete: false, outputLen: 0, commandText: "",
                promptOrdinal: 0,
            ),
            .commandBlock(
                index: 42, exitCode: Int32.min, durationMS: UInt32.max, complete: true, outputLen: 9,
                commandText: "grep · 文字 🚀", promptOrdinal: UInt32.max,
            ),
            .blockOutput(index: 0, output: Data()),
            .blockOutput(index: 5, output: Data([0xAA, 0xBB, 0xCC, 0x1B])),
        ]
        for message in cases {
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
        }
    }
}
