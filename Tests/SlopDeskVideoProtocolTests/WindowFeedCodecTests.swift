import XCTest
@testable import SlopDeskVideoProtocol

/// Wire codec for the host-window FEED trio (docs/45 host-windows rail):
/// type 16 `windowFeedSubscribe` (c→h, u32 knownGeneration), type 17 `windowFeedSnapshot`
/// (h→c, chunked full snapshots), type 18 `windowFeedCurrent` (h→c, u32 generation ack).
/// Pattern of StreamCadenceCodecTests: round-trip + byte-layout pins + truncation +
/// validate-then-drop + existing-cases-unperturbed.
final class WindowFeedCodecTests: XCTestCase {
    private func record(
        id: UInt32 = 7,
        flags: HostWindowFlags = [.onScreen],
        display: UInt8 = 0,
        bundleID: String = "com.mitchellh.ghostty",
        app: String = "Ghostty",
        title: String = "~/work — zsh",
    ) -> HostWindowRecord {
        HostWindowRecord(
            windowID: id, widthPt: 1512, heightPt: 982, flags: flags,
            displayIndex: display, bundleID: bundleID, appName: app, title: title,
        )
    }

    // MARK: Round-trips

    func testSubscribeRoundTripAcrossGenerations() throws {
        for generation: UInt32 in [0, 1, 0xDEAD_BEEF, .max] {
            let msg = VideoControlMessage.windowFeedSubscribe(knownGeneration: generation)
            XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        }
    }

    func testCurrentRoundTrip() throws {
        for generation: UInt32 in [0, 42, .max] {
            let msg = VideoControlMessage.windowFeedCurrent(generation: generation)
            XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        }
    }

    func testSnapshotRoundTripWithMixedRecords() throws {
        let msg = VideoControlMessage.windowFeedSnapshot(
            generation: 9,
            chunkIndex: 1,
            chunkCount: 3,
            records: [
                record(),
                record(
                    id: 8, flags: [.minimized, .appHidden], display: 1,
                    bundleID: "", app: "SomeTool", title: "",
                ),
                record(
                    id: 9, flags: [.onScreen, .frontmostApp, .focusedWindow],
                    title: "tiếng Việt — đề mục 🚀",
                ),
            ],
        )
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
    }

    func testEmptyChunkRoundTrips() throws {
        // A legitimately EMPTY snapshot (zero shareable windows) is one chunk with zero records.
        let msg = VideoControlMessage.windowFeedSnapshot(
            generation: 3, chunkIndex: 0, chunkCount: 1, records: [],
        )
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
    }

    // MARK: Byte-layout pins

    func testTypeBytesAreNextFreeAfterDisplayMax() {
        XCTAssertEqual(VideoControlMessage.displayMax(width: 1, height: 1).messageType, 15)
        XCTAssertEqual(VideoControlMessage.windowFeedSubscribe(knownGeneration: 0).messageType, 16)
        XCTAssertEqual(
            VideoControlMessage.windowFeedSnapshot(generation: 0, chunkIndex: 0, chunkCount: 1, records: [])
                .messageType,
            17,
        )
        XCTAssertEqual(VideoControlMessage.windowFeedCurrent(generation: 0).messageType, 18)
    }

    func testSubscribeWireLayoutIsTypeBytePlusBigEndianUInt32() {
        XCTAssertEqual(
            VideoControlMessage.windowFeedSubscribe(knownGeneration: 0x0102_0304).encode(),
            Data([16, 0x01, 0x02, 0x03, 0x04]),
            "type 16 | UInt32 BE knownGeneration — exactly 5 bytes",
        )
    }

    func testCurrentWireLayoutIsTypeBytePlusBigEndianUInt32() {
        XCTAssertEqual(
            VideoControlMessage.windowFeedCurrent(generation: 0x0A0B_0C0D).encode(),
            Data([18, 0x0A, 0x0B, 0x0C, 0x0D]),
            "type 18 | UInt32 BE generation — exactly 5 bytes",
        )
    }

    func testSnapshotWireLayoutPinnedByteForByte() {
        let msg = VideoControlMessage.windowFeedSnapshot(
            generation: 2,
            chunkIndex: 0,
            chunkCount: 1,
            records: [HostWindowRecord(
                windowID: 0x0000_0001, widthPt: 0x0102, heightPt: 0x0304,
                flags: [.onScreen, .frontmostApp, .focusedWindow], displayIndex: 1,
                bundleID: "a.b", appName: "A", title: "",
            )],
        )
        var expected = Data([17]) // type
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // generation BE
        expected.append(contentsOf: [0x00, 0x01]) // chunkIndex | chunkCount
        expected.append(contentsOf: [0x00, 0x01]) // recordCount BE
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // windowID BE
        expected.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // width | height BE
        expected.append(contentsOf: [0b0001_1001]) // flags: onScreen|frontmostApp|focusedWindow
        expected.append(contentsOf: [0x01]) // displayIndex
        expected.append(contentsOf: [0x00, 0x03]) // lp bundleID len
        expected.append(contentsOf: Array("a.b".utf8))
        expected.append(contentsOf: [0x00, 0x01]) // lp appName len
        expected.append(contentsOf: Array("A".utf8))
        expected.append(contentsOf: [0x00, 0x00]) // lp title len (empty)
        XCTAssertEqual(msg.encode(), expected)
    }

    func testFlagBitAssignmentsArePinned() {
        XCTAssertEqual(HostWindowFlags.onScreen.rawValue, 1 << 0)
        XCTAssertEqual(HostWindowFlags.minimized.rawValue, 1 << 1)
        XCTAssertEqual(HostWindowFlags.appHidden.rawValue, 1 << 2)
        XCTAssertEqual(HostWindowFlags.frontmostApp.rawValue, 1 << 3)
        XCTAssertEqual(HostWindowFlags.focusedWindow.rawValue, 1 << 4)
    }

    /// A future host may set flag bits this client doesn't know — they must round-trip inertly
    /// (raw byte preserved), never throw.
    func testUnknownFlagBitsDecodeInertly() throws {
        let msg = VideoControlMessage.windowFeedSnapshot(
            generation: 1, chunkIndex: 0, chunkCount: 1,
            records: [record(flags: HostWindowFlags(rawValue: 0b1110_0001))],
        )
        guard case let .windowFeedSnapshot(_, _, _, records) = try VideoControlMessage.decode(msg.encode())
        else {
            XCTFail("decoded to a different case")
            return
        }
        XCTAssertEqual(records[0].flags.rawValue, 0b1110_0001)
    }

    // MARK: Truncation + validate-then-drop

    func testTruncatedBodiesThrow() {
        // Bare type bytes and half-written generations bail bounds-checked, never over-read.
        for prefix: [UInt8] in [[16], [16, 0x00], [18], [18, 0x00, 0x00], [17], [17, 0x00, 0x00, 0x00, 0x01]] {
            XCTAssertThrowsError(try VideoControlMessage.decode(Data(prefix)))
        }
    }

    func testSnapshotRecordCountIsUntrusted() {
        // Claim 65535 records but supply zero bytes of body: the first record read must throw
        // `.truncated` (no reserveCapacity over-allocation, no over-read).
        var data = Data([17])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // generation
        data.append(contentsOf: [0x00, 0x01]) // chunk 0/1
        data.append(contentsOf: [0xFF, 0xFF]) // recordCount = 65535
        XCTAssertThrowsError(try VideoControlMessage.decode(data)) { error in
            guard case VideoProtocolError.truncated = error else {
                return XCTFail("bogus record count must throw .truncated, got \(error)")
            }
        }
    }

    /// chunkIndex must address a real slot: zero chunkCount or index ≥ count is corruption/hostile —
    /// `.malformed`, so the assembler is never handed an unsatisfiable generation.
    func testInvalidChunkSlotThrowsMalformed() {
        for (index, count): (UInt8, UInt8) in [(0, 0), (1, 1), (5, 3)] {
            var data = Data([17])
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // generation
            data.append(contentsOf: [index, count])
            data.append(contentsOf: [0x00, 0x00]) // recordCount = 0
            XCTAssertThrowsError(try VideoControlMessage.decode(data)) { error in
                guard case VideoProtocolError.malformed = error else {
                    return XCTFail("chunk \(index)/\(count) must throw .malformed, got \(error)")
                }
            }
        }
    }

    func testCorruptLengthPrefixDropsDatagram() {
        // A record whose title length prefix claims more bytes than remain must throw, not over-read.
        var data = VideoControlMessage.windowFeedSnapshot(
            generation: 1, chunkIndex: 0, chunkCount: 1, records: [record(title: "x")],
        ).encode()
        data[data.count - 3] = 0xFF // title length prefix hi-byte → 65281 claimed, 1 available
        XCTAssertThrowsError(try VideoControlMessage.decode(data))
    }

    // MARK: Budget constants

    /// The host packer's per-chunk record budget must equal one mux datagram minus framing minus the
    /// 9-byte message header — pinned against the real datagram cap so a cap change shows up here.
    func testFeedRecordBudgetMatchesDatagramCap() {
        let muxFraming = 5 // u32 channelID + u8 channel tag
        let messageHeader = 9 // type + u32 generation + chunkIndex + chunkCount + u16 recordCount
        XCTAssertEqual(
            VideoControlMessage.feedRecordBytesPerChunk,
            VideoPacketizer.maxDatagramSize - muxFraming - messageHeader,
        )
        // A max-budget chunk of worst-case records must actually fit one datagram once framed.
        XCTAssertLessThanOrEqual(
            VideoControlMessage.feedRecordBytesPerChunk + muxFraming + messageHeader,
            VideoPacketizer.maxDatagramSize,
        )
    }

    // MARK: Neighbours unperturbed

    func testExistingCasesUnperturbed() throws {
        XCTAssertEqual(VideoControlMessage.displayMax(width: 1, height: 2).encode(), Data([15, 0, 1, 0, 2]))
        XCTAssertEqual(VideoControlMessage.keepalive.encode(), Data([6]))
        let list = VideoControlMessage.windowList([
            WindowSummary(windowID: 1, appName: "A", title: "t", width: 10, height: 20),
        ])
        XCTAssertEqual(try VideoControlMessage.decode(list.encode()), list)
    }
}
