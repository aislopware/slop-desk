import Foundation
import XCTest
@testable import SlopDeskProtocol

/// E4 — the generic host-metadata RPC envelope (terminal CONTROL channel):
///
/// - **type 16** `metadataRequest(requestID:verb:payload:)` — client → host. Body =
///   `[UInt32 BE requestID][UInt8 verb][UInt32 BE payloadLen][payload bytes]`.
/// - **type 30** `metadataResponse(requestID:status:payload:)` — host → client. Body =
///   `[UInt32 BE requestID][UInt8 status][UInt32 BE payloadLen][payload bytes]`.
///
/// These PIN the exact bytes, prove encode↔decode round-trips (incl. every status/verb byte and
/// unknown future values, since the wire carries the RAW byte forward-tolerantly), prove
/// `wireByteCount` parity, and prove validate-then-drop on a truncated body and an over-long declared
/// payload length — never a trap on a hostile datagram. The `payload` is OPAQUE to this envelope (the
/// per-verb `MetadataCodec` validates it), so there is no UTF-8 check here.
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

final class MetadataWireMessageTests: XCTestCase {
    // MARK: type byte + channel

    func testTypeBytesAndChannel() {
        let request = WireMessage.metadataRequest(requestID: 1, verb: 1, payload: Data())
        XCTAssertEqual(request.messageType, 16)
        XCTAssertEqual(request.channel, .control)

        let response = WireMessage.metadataResponse(requestID: 1, status: 0, payload: Data())
        XCTAssertEqual(response.messageType, 30)
        XCTAssertEqual(response.channel, .control)
    }

    // MARK: type 16 — metadataRequest (client → host)

    func testMetadataRequestRoundTrip() throws {
        let payloads: [Data] = [
            Data(),
            Data("Sources/main.swift".utf8),
            Data([0x00, 0xFF, 0x80, 0x7F]),
            Data(repeating: 0x41, count: 4096),
        ]
        // Every defined verb byte plus unknown future bytes — the wire carries the RAW byte.
        let verbs: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 0, 9, 10, 11, 12, 13, 200, 255]
        for verb in verbs {
            for payload in payloads {
                for requestID: UInt32 in [0, 1, 0x0102_0304, UInt32.max] {
                    let message = WireMessage.metadataRequest(requestID: requestID, verb: verb, payload: payload)
                    XCTAssertEqual(try roundTrip(message), message, "\(verb) \(requestID) \(payload.count)")
                }
            }
        }
    }

    func testMetadataRequestExactBytes() {
        // requestID=0x01020304, verb=5, payload=[0xAA,0xBB] (len=2).
        // payload = [16][01020304][05][00000002][AA BB]; frame = [UInt32 BE len][payload].
        let message = WireMessage.metadataRequest(requestID: 0x0102_0304, verb: 5, payload: Data([0xAA, 0xBB]))
        XCTAssertEqual(
            [UInt8](message.encode()),
            [
                0x00, 0x00, 0x00, 0x0C, // frame len = 12 (type + 11 body)
                16,
                0x01, 0x02, 0x03, 0x04, // requestID
                0x05, // verb
                0x00, 0x00, 0x00, 0x02, // payloadLen = 2
                0xAA, 0xBB,
            ],
        )
    }

    func testMetadataRequestEmptyPayloadExactBytes() {
        // requestID=0, verb=1, empty payload. payload = [16][00000000][01][00000000].
        let message = WireMessage.metadataRequest(requestID: 0, verb: 1, payload: Data())
        XCTAssertEqual(
            [UInt8](message.encode()),
            [
                0x00, 0x00, 0x00, 0x0A, // frame len = 10 (type + 9 body)
                16,
                0x00, 0x00, 0x00, 0x00, // requestID
                0x01, // verb
                0x00, 0x00, 0x00, 0x00, // payloadLen = 0
            ],
        )
    }

    func testMetadataRequestTruncatedBodyDrops() throws {
        // Each prefix that stops before a required fixed field → truncated, never a trap.
        let truncations: [[UInt8]] = [
            [16], // no requestID
            [16, 0x00, 0x00, 0x00], // partial requestID
            [16, 0x00, 0x00, 0x00, 0x01], // requestID but no verb
            [16, 0x00, 0x00, 0x00, 0x01, 0x05], // verb but no payloadLen
            [16, 0x00, 0x00, 0x00, 0x01, 0x05, 0x00, 0x00], // half-read payloadLen
        ]
        for payload in truncations {
            XCTAssertThrowsError(try decodePayload(payload)) { error in
                XCTAssertEqual(error as? SlopDeskError, .truncated, "\(payload)")
            }
        }
    }

    func testMetadataRequestOverLongPayloadLengthDrops() throws {
        // payloadLen claims 256 bytes but only 2 are present → validate the declared length BEFORE
        // allocating/reading and DROP (truncated), never over-read / over-allocate a hostile datagram.
        let payload: [UInt8] = [
            16,
            0x00, 0x00, 0x00, 0x01, // requestID
            0x05, // verb
            0x00, 0x00, 0x01, 0x00, // payloadLen = 256
            0xAA, 0xBB, // only 2 present
        ]
        XCTAssertThrowsError(try decodePayload(payload)) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    // MARK: type 30 — metadataResponse (host → client)

    func testMetadataResponseRoundTrip() throws {
        let payloads: [Data] = [
            Data(),
            Data("/Users/me/project".utf8),
            Data([0x1B, 0x5B, 0x00, 0xFF]), // raw opaque bytes (not UTF-8) survive verbatim
            Data(repeating: 0x42, count: 8192),
        ]
        // Every defined status byte plus unknown future bytes — the wire carries the RAW byte.
        let statuses: [UInt8] = [0, 1, 2, 3, 4, 200, 255]
        for status in statuses {
            for payload in payloads {
                for requestID: UInt32 in [0, 7, 0x0102_0304, UInt32.max] {
                    let message = WireMessage.metadataResponse(requestID: requestID, status: status, payload: payload)
                    XCTAssertEqual(try roundTrip(message), message, "\(status) \(requestID) \(payload.count)")
                }
            }
        }
    }

    func testMetadataResponseExactBytes() {
        // requestID=7, status=0 (ok), payload=[0xAA,0xBB,0xCC] (len=3).
        // payload = [30][00000007][00][00000003][AA BB CC].
        let message = WireMessage.metadataResponse(requestID: 7, status: 0, payload: Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(
            [UInt8](message.encode()),
            [
                0x00, 0x00, 0x00, 0x0D, // frame len = 13 (type + 12 body)
                30,
                0x00, 0x00, 0x00, 0x07, // requestID
                0x00, // status = ok
                0x00, 0x00, 0x00, 0x03, // payloadLen = 3
                0xAA, 0xBB, 0xCC,
            ],
        )
    }

    func testMetadataResponseTruncatedBodyDrops() throws {
        let truncations: [[UInt8]] = [
            [30], // no requestID
            [30, 0x00, 0x00], // partial requestID
            [30, 0x00, 0x00, 0x00, 0x07], // requestID but no status
            [30, 0x00, 0x00, 0x00, 0x07, 0x00], // status but no payloadLen
            [30, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00], // half-read payloadLen
        ]
        for payload in truncations {
            XCTAssertThrowsError(try decodePayload(payload)) { error in
                XCTAssertEqual(error as? SlopDeskError, .truncated, "\(payload)")
            }
        }
    }

    func testMetadataResponseOverLongPayloadLengthDrops() throws {
        // payloadLen claims 1024 bytes but only 3 are present → DROP (truncated), never over-read.
        let payload: [UInt8] = [
            30,
            0x00, 0x00, 0x00, 0x07, // requestID
            0x00, // status
            0x00, 0x00, 0x04, 0x00, // payloadLen = 1024
            0xAA, 0xBB, 0xCC, // only 3 present
        ]
        XCTAssertThrowsError(try decodePayload(payload)) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    // MARK: GitStatus repoRoot survives the full envelope (E6 WI-7 end-to-end)

    func testGitStatusRepoRootRidesMetadataResponseEnvelope() throws {
        // The E4 gitStatus payload (now carrying E6 WI-7's repoRoot) is OPAQUE to the type-30 envelope; it
        // must survive a real FrameDecoder round-trip and decode back with repoRoot intact — the wire path
        // end-to-end, not just the isolated codec. Fails on the un-fixed code (no repoRoot on the wire).
        let payload = MetadataCodec.GitStatusPayload(
            hasRepo: true, branch: "main", remoteURL: "",
            repoRoot: "/Users/me/slopdesk", ahead: 0, behind: 0, files: [],
        )
        let body = MetadataCodec.encodeGitStatus(payload)
        let message = WireMessage.metadataResponse(requestID: 4, status: 0, payload: body)
        guard case let .metadataResponse(rid, status, framed)? = try roundTrip(message) else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(rid, 4)
        XCTAssertEqual(status, 0)
        let decoded = try MetadataCodec.decodeGitStatus(framed)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.repoRoot, "/Users/me/slopdesk")
    }

    // MARK: unknown-type drop (older-peer forward-compat)

    func testUnknownTypeDropsNotTraps() throws {
        // A peer that does not know 16/30 DROPS the frame via unknownMessageType, never traps. (17 and 35
        // are still-unassigned "next free" bytes — 31 became inputEcho in E17, 32 became progress in E14,
        // 33 became cwd (OSC 7), 34 became projectKey; 99 is arbitrary.)
        for unknown: UInt8 in [17, 35, 99] {
            XCTAssertThrowsError(try decodePayload([unknown, 0xAB, 0xCD])) { error in
                XCTAssertEqual(error as? SlopDeskError, .unknownMessageType(unknown))
            }
        }
    }

    // MARK: wireByteCount parity (flow-control debit == encode().count)

    func testWireByteCountMatchesEncode() {
        let cases: [WireMessage] = [
            .metadataRequest(requestID: 0, verb: 1, payload: Data()),
            .metadataRequest(requestID: UInt32.max, verb: 200, payload: Data([0x00, 0xFF, 0x80])),
            .metadataRequest(requestID: 5, verb: 5, payload: Data(repeating: 0x41, count: 70000)),
            .metadataResponse(requestID: 0, status: 0, payload: Data()),
            .metadataResponse(requestID: 7, status: 3, payload: Data([0xAA, 0xBB, 0xCC, 0x1B])),
            .metadataResponse(requestID: 9, status: 200, payload: Data(repeating: 0x42, count: 70000)),
        ]
        for message in cases {
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message.messageType)")
        }
    }

    // MARK: MetadataVerb / MetadataStatus forward-tolerant raw mapping

    func testMetadataVerbRawValuesAndUnknownToleration() {
        XCTAssertEqual(MetadataVerb.processes.rawValue, 1)
        XCTAssertEqual(MetadataVerb.ports.rawValue, 2)
        XCTAssertEqual(MetadataVerb.cwd.rawValue, 3)
        XCTAssertEqual(MetadataVerb.gitStatus.rawValue, 4)
        XCTAssertEqual(MetadataVerb.gitDiff.rawValue, 5)
        XCTAssertEqual(MetadataVerb.listDirectory.rawValue, 6)
        XCTAssertEqual(MetadataVerb.listAgentSessions.rawValue, 7)
        XCTAssertEqual(MetadataVerb.readAgentSession.rawValue, 8)
        // E10 WI-7: the two side-effecting path verbs.
        XCTAssertEqual(MetadataVerb.openPath.rawValue, 9)
        XCTAssertEqual(MetadataVerb.revealPath.rawValue, 10)
        // E13 WI-1: the three agent-hooks verbs (11/12 side-effecting, 13 a pure flag read — the
        // 2-byte [installed][listenerActive] payload, docs/20).
        XCTAssertEqual(MetadataVerb.installAgentHooks.rawValue, 11)
        XCTAssertEqual(MetadataVerb.uninstallAgentHooks.rawValue, 12)
        XCTAssertEqual(MetadataVerb.agentHookStatus.rawValue, 13)
        // MERIDIAN C2: the host-identity pure read (raw UTF-8 hostname payload, docs/20).
        XCTAssertEqual(MetadataVerb.hostInfo.rawValue, 14)
        // Unknown verb bytes map to nil (caller answers unsupportedVerb) — never a trap.
        XCTAssertNil(MetadataVerb(rawValue: 0))
        XCTAssertNil(MetadataVerb(rawValue: 15))
        XCTAssertNil(MetadataVerb(rawValue: 200))
    }

    func testMetadataStatusRawValuesAndUnknownToleration() {
        XCTAssertEqual(MetadataStatus.ok.rawValue, 0)
        XCTAssertEqual(MetadataStatus.notFound.rawValue, 1)
        XCTAssertEqual(MetadataStatus.error.rawValue, 2)
        XCTAssertEqual(MetadataStatus.unsupportedVerb.rawValue, 3)
        // Unknown status bytes map to nil (caller clamps to error) — never a trap.
        XCTAssertNil(MetadataStatus(rawValue: 4))
        XCTAssertNil(MetadataStatus(rawValue: 200))
    }
}
