import XCTest
import Foundation
@testable import AislopdeskProtocol

/// Pins `WireMessage.wireByteCount == encode().count` for EVERY variant — the receive-side
/// flow-control credit is computed from `wireByteCount` while the sender debits the actual
/// encoded frame, so any drift slowly stalls (under-credit) or unbounds (over-credit) the
/// window.
final class WireMessageWireByteCountTests: XCTestCase {

    func testWireByteCountMatchesEncodeForEveryVariant() {
        let payloads: [Data] = [
            Data(),
            Data("x".utf8),
            Data(repeating: 0x41, count: 128 * 1024),
        ]
        var messages: [WireMessage] = []
        for p in payloads {
            messages.append(.output(seq: 1, bytes: p))
            messages.append(.output(seq: Int64.max, bytes: p))
            messages.append(.input(p))
        }
        messages += [
            .exit(code: 0), .exit(code: -1),
            .hello(protocolVersion: 1, sessionID: UUID(), lastReceivedSeq: 42),
            .hello(protocolVersion: UInt16.max, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0),
            .resize(cols: 80, rows: 24, pxWidth: 0, pxHeight: 0),
            .ack(seq: 7),
            .bye,
            .ping(timestampMS: 0), .ping(timestampMS: UInt64.max),
            .pong(timestampMS: 12_345),
            .helloAck(sessionID: UUID(), resumeFromSeq: 3, returningClient: true),
            .helloAck(sessionID: UUID(), resumeFromSeq: 0, returningClient: false),
            .title(""),
            .title("hello"),
            .title("tiếng Việt — đa byte ✓"),
            .bell,
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 0, durationMS: 12)),
            .commandStatus(.idle(exitCode: nil, durationMS: 0)),
            .commandStatus(.idle(exitCode: -127, durationMS: UInt32.max)),
        ]
        for message in messages {
            XCTAssertEqual(message.wireByteCount, message.encode().count,
                           "wireByteCount must equal encode().count for \(message)")
        }
    }
}
