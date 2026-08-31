// The Swift half of the FFI boundary, tested where a Rust test cannot reach.
//
// `slopdesk-ffi`'s own suites prove what each door WRITES. Nothing proved that Swift reads the same
// bytes back the same way, and the failure mode of a mismatch is silent: a decoder that misreads a
// length answers a SHORT list rather than raising, because every decoder here is deliberately
// forgiving of a truncated blob — a search that lost the tail of the scrollback beats a search that
// answers nothing. That forgiveness is exactly what would hide an off-by-one, so each frame below is
// written out BY HAND from the door's documented layout, never built by calling the encoder.
//
// ⚠️ NOTHING HERE OPENS A SURFACE. `TerminalRendererSurface.init` asks for a Metal device, and a
// unit suite has no business acquiring one; every decoder under test is `static` for that reason.

import Foundation
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskTerminal

final class TerminalBlobDecoderTests: XCTestCase {
    // MARK: - Frame builders (hand-written, never the encoder's)

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func beDouble(_ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return (0..<8).map { UInt8(truncatingIfNeeded: bits >> (56 - 8 * $0)) }
    }

    // MARK: - decodeRows

    func testRowsCarryEveryStringInOrder() {
        var blob = be32(3)
        for row in ["one", "", "trailing space "] {
            let utf8 = Array(row.utf8)
            blob += be32(UInt32(utf8.count)) + utf8
        }
        XCTAssertEqual(
            TerminalRendererSurface.decodeRows(blob),
            ["one", "", "trailing space "],
        )
    }

    /// Non-ASCII is the case a byte-vs-scalar length confusion passes for ASCII and fails for: the
    /// length is BYTES, and "现在" is six of them across two scalars.
    func testRowsLengthIsBytesNotScalars() {
        let utf8 = Array("现在".utf8)
        XCTAssertEqual(utf8.count, 6)
        let blob = be32(1) + be32(6) + utf8
        XCTAssertEqual(TerminalRendererSurface.decodeRows(blob), ["现在"])
    }

    /// A truncated blob answers the rows it DID carry — the decoder's own documented behaviour, and
    /// the reason every other case here is written by hand.
    func testRowsTruncatedMidRunKeepsWhatArrived() {
        let blob = be32(2) + be32(2) + Array("ok".utf8) + be32(9) + Array("short".utf8)
        XCTAssertEqual(TerminalRendererSurface.decodeRows(blob), ["ok"])
    }

    func testRowsEmptyBlobIsNoRows() {
        XCTAssertEqual(TerminalRendererSurface.decodeRows([]), [])
        XCTAssertEqual(TerminalRendererSurface.decodeRows(be32(0)), [])
    }

    // MARK: - decodeCellMetrics

    func testCellMetricsReadsAllSixFieldsInOrder() {
        // Every field a DIFFERENT value, and the two `u32`s not interchangeable with each other:
        // a frame of zeros would pass with a decoder that read the fields in any order at all.
        let blob = beDouble(7.5) + beDouble(16.25) + be32(120) + be32(40)
            + beDouble(4.0) + beDouble(2.5)
        let metrics = TerminalRendererSurface.decodeCellMetrics(blob)
        XCTAssertEqual(metrics?.cellWidth, 7.5)
        XCTAssertEqual(metrics?.cellHeight, 16.25)
        XCTAssertEqual(metrics?.cols, 120)
        XCTAssertEqual(metrics?.rows, 40)
        XCTAssertEqual(metrics?.originX, 4.0)
        XCTAssertEqual(metrics?.originY, 2.5)
    }

    /// One byte short is `nil`, not a metric with a garbage origin — a partial geometry would place
    /// every overlay in the pane slightly wrong, which is worse than placing none.
    func testCellMetricsShortBlobIsNil() {
        let full = beDouble(7.5) + beDouble(16.25) + be32(120) + be32(40)
            + beDouble(4.0) + beDouble(2.5)
        XCTAssertNil(TerminalRendererSurface.decodeCellMetrics(Array(full.dropLast())))
        XCTAssertNil(TerminalRendererSurface.decodeCellMetrics([]))
    }

    // MARK: - decodeViewportInfo

    /// The field ORDER is the whole risk here: the blob is six `u32`s and any permutation decodes,
    /// so every value is distinct and the cursor's two are deliberately not equal.
    func testViewportInfoReadsSixDistinctFieldsInOrder() {
        let blob = be32(5000) + be32(4800) + be32(40) + be32(120) + be32(11) + be32(4807)
        let info = TerminalRendererSurface.decodeViewportInfo(blob)
        XCTAssertEqual(info?.totalRows, 5000)
        XCTAssertEqual(info?.viewportTopRow, 4800)
        XCTAssertEqual(info?.viewportRows, 40)
        XCTAssertEqual(info?.cols, 120)
        XCTAssertEqual(info?.cursor.col, 11)
        XCTAssertEqual(info?.cursor.row, 4807)
    }

    func testViewportInfoShortBlobIsNil() {
        XCTAssertNil(TerminalRendererSurface.decodeViewportInfo(be32(1) + be32(2)))
        XCTAssertNil(TerminalRendererSurface.decodeViewportInfo([]))
    }

    // MARK: - decodeLogicalLines

    func testLogicalLinesCarryTheirRowSpans() {
        var blob = be32(2)
        blob += be32(0) + be32(2) + be32(5) + Array("first".utf8)
        blob += be32(3) + be32(3) + be32(6) + Array("second".utf8)
        let lines = TerminalRendererSurface.decodeLogicalLines(blob)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first?.text, "first")
        XCTAssertEqual(lines.first?.firstRow, 0)
        XCTAssertEqual(lines.first?.lastRow, 2)
        XCTAssertEqual(lines.last?.text, "second")
        XCTAssertEqual(lines.last?.firstRow, 3)
        XCTAssertEqual(lines.last?.lastRow, 3)
    }

    /// Three fields per record is three more chances at an off-by-one than `decodeRows` has, and a
    /// record that is cut between them must not be half-read into the one before it.
    func testLogicalLinesTruncatedBetweenFieldsKeepsWhatArrived() {
        var blob = be32(2)
        blob += be32(0) + be32(0) + be32(4) + Array("kept".utf8)
        blob += be32(1) + be32(1) // the length and the run never arrive
        let lines = TerminalRendererSurface.decodeLogicalLines(blob)
        XCTAssertEqual(lines.map(\.text), ["kept"])
    }

    // MARK: - decodeClipboardWrites

    /// The count is a `u16` here where every other frame's is a `u32`, and the queue is bounded at 8
    /// — reading four bytes would consume the first record's target and length as part of it.
    func testClipboardWritesCountIsSixteenBit() {
        var blob = be16(2)
        blob += [0] + be32(5) + Array("hello".utf8)
        blob += [1] + be32(3) + Array("bye".utf8)
        let writes = TerminalRendererSurface.decodeClipboardWrites(blob)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.first?.target, .standard)
        XCTAssertEqual(writes.first?.text, "hello")
        XCTAssertEqual(writes.last?.target, .selection)
        XCTAssertEqual(writes.last?.text, "bye")
    }

    /// An unknown target code is the standard clipboard, not a dropped write: Apple has exactly one
    /// board, so a write the caller cannot place is still a write the program asked for.
    func testClipboardWriteWithUnknownTargetLandsOnTheStandardBoard() {
        let blob = be16(1) + [99] + be32(2) + Array("hi".utf8)
        let writes = TerminalRendererSurface.decodeClipboardWrites(blob)
        XCTAssertEqual(writes.first?.target, .standard)
        XCTAssertEqual(writes.first?.text, "hi")
    }

    func testClipboardWritesEmptyDrainIsNoWrites() {
        XCTAssertEqual(TerminalRendererSurface.decodeClipboardWrites([]).count, 0)
        XCTAssertEqual(TerminalRendererSurface.decodeClipboardWrites(be16(0)).count, 0)
    }

    func testClipboardWritesTruncatedMidTextKeepsWhatArrived() {
        var blob = be16(2)
        blob += [0] + be32(4) + Array("kept".utf8)
        blob += [0] + be32(40) + Array("short".utf8)
        XCTAssertEqual(TerminalRendererSurface.decodeClipboardWrites(blob).map(\.text), ["kept"])
    }
}
