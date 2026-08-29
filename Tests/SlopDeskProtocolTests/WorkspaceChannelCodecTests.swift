import Foundation
import XCTest
@testable import SlopDeskProtocol

private extension UUID {
    /// The UUID's 16 raw bytes as `Data`, in canonical order.
    ///
    /// A TEST helper, and it lives here for the same reason `appendBE` does: hand-spelling the
    /// bytes a decode must accept is the point. It was `Sources/SlopDeskProtocol`'s until G.4,
    /// where the census found its last production caller had been a `UUID(dataBytes:)` initialiser
    /// nothing called at all — a helper kept alive by the tests that checked it worked.
    var dataBytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}

/// The payloads that ride INSIDE types 17 and 37 (docs/45 §5.2).
///
/// These bytes arrive from a network peer over a channel that carries no authentication of any kind
/// (security is the WireGuard mesh, not the app layer), so every decode here is validate-then-drop:
/// a declared length is bounded against the bytes ACTUALLY present before any allocation, a
/// wrong-width scalar is a drop rather than a lenient prefix read, and nothing is force-unwrapped.
final class WorkspaceChannelCodecTests: XCTestCase {
    private let clientID = UUID(uuidString: "5D05DE5C-0000-4000-8000-000000000001")!
    private let epoch = UUID(uuidString: "5D05DE5C-0000-4000-8000-000000000002")!

    // MARK: subscribe

    func testSubscribeRoundTrips() throws {
        let cases = [
            WorkspaceSubscribe(clientInstanceID: clientID, clientKind: 0),
            WorkspaceSubscribe(
                clientInstanceID: clientID,
                clientKind: 1,
                knownEpoch: epoch,
                knownStateNum: Int64.max,
                flags: WorkspaceSubscribe.flagContributesSize | WorkspaceSubscribe.flagFollowsFocus,
                label: "congtran's iPhone — café 🚀",
            ),
            WorkspaceSubscribe(
                clientInstanceID: clientID,
                clientKind: 0,
                knownStateNum: Int64.min,
                flags: 0xFF,
            ),
        ]
        for subscribe in cases {
            XCTAssertEqual(try WorkspaceSubscribe.decode(subscribe.encode()), subscribe)
        }
    }

    func testSubscribeExactBytes() {
        // Pin the layout: [16B clientInstanceID][u8 kind][16B epoch][i64 stateNum][u8 flags][u16 len][label]
        let subscribe = WorkspaceSubscribe(
            clientInstanceID: WireMessage.newSessionID,
            clientKind: 1,
            knownEpoch: WireMessage.newSessionID,
            knownStateNum: 1,
            flags: 3,
            label: "ok",
        )
        var expected = [UInt8](repeating: 0, count: 16)
        expected.append(1)
        expected.append(contentsOf: [UInt8](repeating: 0, count: 16))
        expected.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        expected.append(3)
        expected.append(contentsOf: [0, 2, 0x6F, 0x6B])
        XCTAssertEqual([UInt8](subscribe.encode()), expected)
    }

    func testSubscribeFlagsDecodeIndependently() {
        let contributing = WorkspaceSubscribe(
            clientInstanceID: clientID,
            clientKind: 0,
            flags: WorkspaceSubscribe.flagContributesSize,
        )
        XCTAssertTrue(contributing.contributesSize)
        XCTAssertFalse(contributing.followsFocus)
        let following = WorkspaceSubscribe(
            clientInstanceID: clientID,
            clientKind: 0,
            flags: WorkspaceSubscribe.flagFollowsFocus,
        )
        XCTAssertFalse(following.contributesSize)
        XCTAssertTrue(following.followsFocus)
    }

    func testSubscribeUnknownFlagBitsAreIgnoredNotRejected() throws {
        // Forward tolerance without version negotiation (which this protocol is not allowed to have):
        // an unknown bit from a newer client must not fail the whole subscribe.
        let subscribe = WorkspaceSubscribe(clientInstanceID: clientID, clientKind: 9, flags: 0b1111_1100)
        let decoded = try WorkspaceSubscribe.decode(subscribe.encode())
        XCTAssertEqual(decoded.flags, 0b1111_1100)
        XCTAssertFalse(decoded.contributesSize)
        XCTAssertFalse(decoded.followsFocus)
    }

    func testSubscribeClampsAnOverLongLabelOnEncode() throws {
        // Clamping happens on ENCODE, at a scalar boundary, so the bytes stay valid UTF-8.
        let label = String(repeating: "🚀", count: 40) // 160 UTF-8 bytes
        let subscribe = WorkspaceSubscribe(clientInstanceID: clientID, clientKind: 0, label: label)
        let decoded = try WorkspaceSubscribe.decode(subscribe.encode())
        XCTAssertLessThanOrEqual(decoded.label.utf8.count, WorkspaceSubscribe.maxLabelBytes)
        XCTAssertTrue(label.hasPrefix(decoded.label))
    }

    func testSubscribeRejectsAnOverLongDeclaredLabel() {
        // A DECODER rejects rather than trims: silently truncating a field a peer over-declared hides
        // a framing bug behind a plausible value.
        var payload = Data()
        payload.append(clientID.dataBytes)
        payload.append(0)
        payload.append(epoch.dataBytes)
        payload.appendBE(Int64(0))
        payload.append(0)
        payload.appendBE(UInt16(WorkspaceSubscribe.maxLabelBytes + 1))
        payload.append(Data(repeating: 0x41, count: WorkspaceSubscribe.maxLabelBytes + 1))
        XCTAssertThrowsError(try WorkspaceSubscribe.decode(payload)) { error in
            guard case SlopDeskError.malformedBody = error else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }

    func testSubscribeRejectsALabelLongerThanTheBuffer() {
        var payload = Data()
        payload.append(clientID.dataBytes)
        payload.append(0)
        payload.append(epoch.dataBytes)
        payload.appendBE(Int64(0))
        payload.append(0)
        payload.appendBE(UInt16(10))
        payload.append(Data([0x41])) // one byte where ten were declared
        XCTAssertEqual(try? WorkspaceSubscribe.decode(payload), nil)
    }

    func testSubscribeRejectsNonUTF8Label() {
        var payload = Data()
        payload.append(clientID.dataBytes)
        payload.append(0)
        payload.append(epoch.dataBytes)
        payload.appendBE(Int64(0))
        payload.append(0)
        payload.appendBE(UInt16(2))
        payload.append(Data([0xFF, 0xFE]))
        XCTAssertThrowsError(try WorkspaceSubscribe.decode(payload)) { error in
            guard case SlopDeskError.malformedBody = error else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }

    func testSubscribeTruncatedAtEveryPrefixDrops() {
        let full = WorkspaceSubscribe(
            clientInstanceID: clientID,
            clientKind: 1,
            knownEpoch: epoch,
            knownStateNum: 42,
            flags: 1,
            label: "mac",
        ).encode()
        for length in 0..<full.count {
            XCTAssertThrowsError(
                try WorkspaceSubscribe.decode(full.prefix(length)),
                "prefix of length \(length) must not decode",
            )
        }
    }

    // MARK: presence

    func testPresenceUpdateRoundTrips() throws {
        let update = WorkspacePresenceUpdate(
            presenceClock: Int64.max,
            viewingTabID: epoch,
            viewingPaneID: clientID,
            cols: 213,
            rows: 51,
            flags: 1,
        )
        XCTAssertEqual(try WorkspacePresenceUpdate.decode(update.encode()), update)
        XCTAssertTrue(update.contributesSize)
    }

    func testPresenceUpdateTruncatedDrops() {
        let full = WorkspacePresenceUpdate(presenceClock: 1).encode()
        for length in 0..<full.count {
            XCTAssertThrowsError(try WorkspacePresenceUpdate.decode(full.prefix(length)))
        }
    }

    // MARK: intent

    func testIntentRoundTrips() throws {
        let intent = WorkspaceIntent(intentID: clientID, op: 6, args: Data([1, 2, 3, 4]))
        XCTAssertEqual(try WorkspaceIntent.decode(intent.encode()), intent)
        let empty = WorkspaceIntent(intentID: clientID, op: 0)
        XCTAssertEqual(try WorkspaceIntent.decode(empty.encode()), empty)
    }

    func testIntentRejectsAHostileArgLength() {
        // `UInt32.max` declared over a four-byte buffer must cost nothing — the length is bounded
        // against what remains BEFORE any read.
        var payload = Data()
        payload.append(clientID.dataBytes)
        payload.append(7)
        payload.appendBE(UInt32.max)
        payload.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try WorkspaceIntent.decode(payload)) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    // MARK: intentResult

    func testIntentResultRoundTripsEveryStatus() throws {
        for status in WorkspaceIntentStatus.allCases {
            let result = WorkspaceIntentResult(intentID: clientID, status: status)
            XCTAssertEqual(try WorkspaceIntentResult.decode(result.encode()), result)
        }
        // An unknown status byte from a newer host survives verbatim rather than failing the frame.
        let future = WorkspaceIntentResult(intentID: clientID, statusByte: 200)
        XCTAssertEqual(try WorkspaceIntentResult.decode(future.encode()).status, 200)
    }

    // MARK: roster

    func testRosterRoundTrips() throws {
        let roster = WorkspacePresenceRoster(
            clients: [
                WorkspaceRosterClient(
                    clientInstanceID: clientID,
                    clientKind: 0,
                    flags: 1,
                    viewingTabID: epoch,
                    viewingPaneID: clientID,
                    cols: 213,
                    rows: 51,
                    label: "mac-studio",
                ),
                WorkspaceRosterClient(clientInstanceID: epoch, clientKind: 1, label: "iPhone 📱"),
            ],
            panes: [
                WorkspaceRosterPane(
                    paneID: clientID,
                    resolvedCols: 120,
                    resolvedRows: 40,
                    attachments: [
                        .init(clientInstanceID: clientID, contributes: true, cols: 213, rows: 51),
                        .init(clientInstanceID: epoch, contributes: false, cols: 80, rows: 24),
                    ],
                ),
                WorkspaceRosterPane(paneID: epoch, resolvedCols: 0, resolvedRows: 0, attachments: []),
            ],
        )
        XCTAssertEqual(try WorkspacePresenceRoster.decode(roster.encode()), roster)
    }

    func testEmptyRosterRoundTrips() throws {
        // The null broadcast — the frame sent when the last client leaves.
        let empty = WorkspacePresenceRoster()
        XCTAssertEqual([UInt8](empty.encode()), [0, 0, 0, 0])
        XCTAssertEqual(try WorkspacePresenceRoster.decode(empty.encode()), empty)
    }

    func testRosterRejectsAHostileClientCount() {
        // 0xFFFF clients declared over an empty buffer: rejected by arithmetic, before `reserveCapacity`.
        XCTAssertThrowsError(try WorkspacePresenceRoster.decode(Data([0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    func testRosterRejectsAHostileAttachmentCount() {
        var payload = Data()
        payload.appendBE(UInt16(0)) // no clients
        payload.appendBE(UInt16(1)) // one pane
        payload.append(clientID.dataBytes)
        payload.appendBE(UInt16(80))
        payload.appendBE(UInt16(24))
        payload.appendBE(UInt16.max) // …claiming 65535 attachments
        XCTAssertThrowsError(try WorkspacePresenceRoster.decode(payload)) { error in
            XCTAssertEqual(error as? SlopDeskError, .truncated)
        }
    }

    func testRosterTruncatedAtEveryPrefixDrops() {
        let full = WorkspacePresenceRoster(
            clients: [WorkspaceRosterClient(clientInstanceID: clientID, clientKind: 0, label: "m")],
            panes: [WorkspaceRosterPane(
                paneID: epoch,
                resolvedCols: 1,
                resolvedRows: 2,
                attachments: [.init(clientInstanceID: clientID, contributes: true, cols: 3, rows: 4)],
            )],
        ).encode()
        for length in 0..<full.count {
            XCTAssertThrowsError(
                try WorkspacePresenceRoster.decode(full.prefix(length)),
                "prefix of length \(length) must not decode",
            )
        }
    }

    // MARK: vocabulary

    func testVerbAndKindBytesAreFrozen() {
        // These numbers are on the wire and in a golden vector. Renumbering one silently reinterprets
        // every frame a peer sends — there is no version negotiation to catch it.
        XCTAssertEqual(WorkspaceRequestVerb.subscribe.rawValue, 0)
        XCTAssertEqual(WorkspaceRequestVerb.ack.rawValue, 1)
        XCTAssertEqual(WorkspaceRequestVerb.presence.rawValue, 2)
        XCTAssertEqual(WorkspaceRequestVerb.intent.rawValue, 3)
        XCTAssertEqual(WorkspaceEventKind.snapshot.rawValue, 0)
        XCTAssertEqual(WorkspaceEventKind.diff.rawValue, 1)
        XCTAssertEqual(WorkspaceEventKind.presence.rawValue, 2)
        XCTAssertEqual(WorkspaceEventKind.intentResult.rawValue, 3)
        XCTAssertEqual(WorkspaceEventKind.reset.rawValue, 4)
        XCTAssertNil(WorkspaceRequestVerb(rawValue: 4))
        XCTAssertNil(WorkspaceEventKind(rawValue: 5))
    }
}
