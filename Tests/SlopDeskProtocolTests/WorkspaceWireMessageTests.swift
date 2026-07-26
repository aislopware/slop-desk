import Foundation
import XCTest
@testable import SlopDeskProtocol

/// The type 17 / 37 envelopes (docs/45 §5.2). `SlopDeskProtocol` never parses workspace STATE — it
/// carries an opaque payload, exactly as it does for `metadataRequest` — so these tests pin the
/// FRAMING: the hoisted header, the length-prefix discipline, and the drop-not-trap contract.
final class WorkspaceWireMessageTests: XCTestCase {
    private func roundTrip(_ message: WireMessage) throws -> WireMessage {
        let framed = message.encode()
        // Strip the 4-byte length prefix the frame carries; the decoder takes type + body.
        return try WireMessage.decode(payload: framed.dropFirst(4))
    }

    // MARK: - workspaceRequest (17)

    func testWorkspaceRequestRoundTrips() throws {
        for payload in [Data(), Data([0x00]), Data(repeating: 0xAB, count: 4096)] {
            for (seq, verb) in [(UInt32(0), UInt8(0)), (UInt32.max, UInt8(255)), (7, 3)] {
                let message = WireMessage.workspaceRequest(requestSeq: seq, verb: verb, payload: payload)
                XCTAssertEqual(try roundTrip(message), message)
            }
        }
    }

    // MARK: - workspaceEvent (37)

    func testWorkspaceEventRoundTripsIncludingExtremeStateNumbers() throws {
        let epoch = UUID()
        // Int64 min/max are the real boundary: `stateNum` shares the `output.seq` / `resumeFromSeq`
        // idiom, and a sign error there is exactly the kind of bug that only shows up after months.
        let numbers: [(Int64, Int64)] = [(0, 0), (0, 1), (Int64.min, Int64.max), (Int64.max, Int64.min)]
        for kind in [UInt8(0), 1, 2, 3, 4, 200] {
            for (base, new) in numbers {
                let message = WireMessage.workspaceEvent(
                    kind: kind, epoch: epoch, baseStateNum: base, newStateNum: new,
                    payload: Data("state".utf8),
                )
                XCTAssertEqual(try roundTrip(message), message, "kind \(kind), \(base) -> \(new)")
            }
        }
    }

    func testWorkspaceEventEmptyPayloadRoundTrips() throws {
        // kind 4 `reset` carries no payload at all — the empty body must survive framing.
        let message = WireMessage.workspaceEvent(
            kind: 4, epoch: UUID(), baseStateNum: 0, newStateNum: 0, payload: Data(),
        )
        XCTAssertEqual(try roundTrip(message), message)
    }

    /// The header is fixed-size and comes FIRST, so a client can reject a mis-based frame after 33
    /// bytes without touching the payload. Pinning the offset means a future field insertion that
    /// would break that cheap rejection shows up as a red test.
    func testWorkspaceEventHeaderIsHoistedAheadOfThePayload() {
        let epoch = UUID()
        let framed = WireMessage.workspaceEvent(
            kind: 1, epoch: epoch, baseStateNum: 0x0102_0304_0506_0708,
            newStateNum: 0x1112_1314_1516_1718, payload: Data([0xEE]),
        ).encode()
        let body = [UInt8](framed.dropFirst(4)) // drop length prefix
        XCTAssertEqual(body[0], 37, "type byte")
        XCTAssertEqual(body[1], 1, "kind")
        XCTAssertEqual(Array(body[2..<18]), [UInt8](epoch.dataBytes), "epoch")
        XCTAssertEqual(Array(body[18..<26]), [1, 2, 3, 4, 5, 6, 7, 8], "baseStateNum, big-endian")
        XCTAssertEqual(Array(body[26..<34]), [0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18], "newStateNum")
        XCTAssertEqual(Array(body[34..<38]), [0, 0, 0, 1], "payloadLen")
        XCTAssertEqual(body[38], 0xEE, "payload")
    }

    // MARK: - Hostile framing

    func testTruncationAtEveryOffsetThrows() {
        let framed = WireMessage.workspaceEvent(
            kind: 0, epoch: UUID(), baseStateNum: 4, newStateNum: 9, payload: Data("abc".utf8),
        ).encode().dropFirst(4)
        for cut in 0..<framed.count {
            XCTAssertThrowsError(try WireMessage.decode(payload: framed.prefix(cut)), "cut at \(cut)")
        }
    }

    /// A declared payload length far beyond the body must throw rather than over-read.
    func testOverlongDeclaredPayloadLengthThrows() {
        var body: [UInt8] = [17] // workspaceRequest
        body.append(contentsOf: [0, 0, 0, 1]) // requestSeq
        body.append(0) // verb
        body.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // payloadLen
        XCTAssertThrowsError(try WireMessage.decode(payload: Data(body)))
    }

    /// An unknown VERB or KIND is not this layer's problem — the envelope carries it verbatim and the
    /// consumer decides. That is what makes a future verb cost zero type numbers.
    func testUnknownVerbAndKindSurviveTheEnvelope() throws {
        let request = WireMessage.workspaceRequest(requestSeq: 1, verb: 250, payload: Data([1, 2]))
        XCTAssertEqual(try roundTrip(request), request)
        let event = WireMessage.workspaceEvent(
            kind: 250, epoch: UUID(), baseStateNum: 0, newStateNum: 0, payload: Data(),
        )
        XCTAssertEqual(try roundTrip(event), event)
    }

    // MARK: - Flow-control parity

    /// The credit debit must equal the encoded size, or the workspace channel desynchronises the
    /// receive window.
    func testWireByteCountMatchesEncode() {
        let cases: [WireMessage] = [
            .workspaceRequest(requestSeq: 0, verb: 0, payload: Data()),
            .workspaceRequest(requestSeq: .max, verb: 3, payload: Data(repeating: 7, count: 300)),
            .workspaceEvent(kind: 0, epoch: UUID(), baseStateNum: 0, newStateNum: 0, payload: Data()),
            .workspaceEvent(
                kind: 1, epoch: UUID(), baseStateNum: .min, newStateNum: .max,
                payload: Data(repeating: 9, count: 1024),
            ),
        ]
        for message in cases {
            XCTAssertEqual(message.wireByteCount, message.encode().count, "\(message)")
        }
    }
}
