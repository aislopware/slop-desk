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

/// The payloads that ride INSIDE types 17 and 37 (docs/45 §5.2), from the ONE side this target has.
///
/// `WorkspaceChannelCodec` faces the client's way: it ENCODES subscribe, presence and intent, and
/// DECODES the roster and intentResult. The opposite diagonal is `rust/slopdesk-wire`'s alone, and
/// so are the round trips that used to be here — a round trip through one codebase's own encoder and
/// decoder passes just as happily when both have drifted from the wire, and `workspace.rs`'s own
/// suite already pins every fault this one asserted twice.
///
/// What is left is what only THIS side can answer: the bytes an encoder actually emits, and what the
/// roster decoder does with bytes no encoder here can produce. Those roster bodies arrive from a
/// network peer over a channel that carries no authentication of any kind (security is the WireGuard
/// mesh, not the app layer), so the decode is validate-then-drop: a declared count is bounded against
/// the bytes ACTUALLY present before any allocation, and nothing is force-unwrapped.
final class WorkspaceChannelCodecTests: XCTestCase {
    private let clientID = UUID(uuidString: "5D05DE5C-0000-4000-8000-000000000001")!
    private let epoch = UUID(uuidString: "5D05DE5C-0000-4000-8000-000000000002")!

    // MARK: subscribe

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

    func testSubscribeFlagBitsReadIndependently() {
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

    // MARK: intentResult

    func testIntentResultRoundTripsEveryStatus() throws {
        // The one crossing that faces BOTH ways here: `LoopbackWorkspaceDocument` is a client-local
        // host, so it encodes the results this client decodes.
        for status in WorkspaceIntentStatus.allCases {
            let result = WorkspaceIntentResult(intentID: clientID, status: status)
            XCTAssertEqual(try WorkspaceIntentResult.decode(result.encode()), result)
        }
        // An unknown status byte from a newer host survives verbatim rather than failing the frame.
        let future = WorkspaceIntentResult(intentID: clientID, statusByte: 200)
        XCTAssertEqual(try WorkspaceIntentResult.decode(future.encode()).status, 200)
    }

    // MARK: roster

    func testTheNullRosterBroadcastDecodesToAnEmptyRoster() throws {
        // The frame sent when the last client leaves: two zero counts and nothing else.
        XCTAssertEqual(try WorkspacePresenceRoster.decode(Data([0, 0, 0, 0])), WorkspacePresenceRoster())
    }

    func testRosterRejectsAHostileClientCount() {
        // 0xFFFF clients declared over an empty buffer: over `MAX_RECORDS`, so the count itself is
        // malformed — refused before anything is sized, not after a per-record read runs dry.
        XCTAssertThrowsError(try WorkspacePresenceRoster.decode(Data([0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? SlopDeskError, .malformedBody("workspace roster: rejected by the workspace codec"))
        }
        // A count UNDER the cap over an empty buffer is the other refusal: the records it promises
        // never arrive, and that is truncation.
        XCTAssertThrowsError(try WorkspacePresenceRoster.decode(Data([0x00, 0x10]))) { error in
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
        payload.appendBE(UInt16.max) // …claiming 65535 attachments, past `MAX_RECORDS`
        XCTAssertThrowsError(try WorkspacePresenceRoster.decode(payload)) { error in
            XCTAssertEqual(error as? SlopDeskError, .malformedBody("workspace roster: rejected by the workspace codec"))
        }
    }

    func testARosterDecodesFromHandSpelledBytesAndDropsEveryPrefixOfThem() throws {
        // One client and one pane holding one attachment, spelled against `encode_into` in
        // `rust/slopdesk-wire/src/workspace.rs`:
        //   [u16 clientCount]
        //     [16B id][u8 kind][u8 flags][16B tabID][16B paneID][u16 cols][u16 rows][u16 len][label]
        //   [u16 paneCount]
        //     [16B paneID][u16 resolvedCols][u16 resolvedRows][u16 attachCount]
        //       [16B clientID][u8 contributes][u16 cols][u16 rows]
        // The attachments sit INLINE behind their pane — the `(offset, count)` run the Swift decoder
        // reads them back through is the FFI crossing's shape, not the wire's.
        var full = Data()
        full.appendBE(UInt16(1))
        full.append(clientID.dataBytes)
        full.append(0) // clientKind
        full.append(0) // flags
        full.append(WireMessage.newSessionID.dataBytes)
        full.append(WireMessage.newSessionID.dataBytes)
        full.appendBE(UInt16(0)) // cols
        full.appendBE(UInt16(0)) // rows
        full.appendBE(UInt16(1))
        full.append(contentsOf: Array("m".utf8))
        full.appendBE(UInt16(1))
        full.append(epoch.dataBytes)
        full.appendBE(UInt16(1)) // resolvedCols
        full.appendBE(UInt16(2)) // resolvedRows
        full.appendBE(UInt16(1)) // one attachment
        full.append(clientID.dataBytes)
        full.append(1) // contributes
        full.appendBE(UInt16(3))
        full.appendBE(UInt16(4))

        XCTAssertEqual(
            try WorkspacePresenceRoster.decode(full),
            WorkspacePresenceRoster(
                clients: [WorkspaceRosterClient(clientInstanceID: clientID, clientKind: 0, label: "m")],
                panes: [WorkspaceRosterPane(
                    paneID: epoch,
                    resolvedCols: 1,
                    resolvedRows: 2,
                    attachments: [.init(clientInstanceID: clientID, contributes: true, cols: 3, rows: 4)],
                )],
            ),
        )
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
