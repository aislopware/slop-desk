import Foundation
import XCTest
@testable import AislopdeskClientUI

/// Pure tests for ``ConnectionViewModel/packInputs(_:maxInputFrameBytes:)`` — the OUT-batch
/// input normalizer (merge adjacent tiny inputs, split oversized ones, `.resize` is a hard
/// barrier). The load-bearing property is CONCATENATION BYTE-IDENTITY: the emitted input
/// payloads concatenate to exactly the input payloads, in order.
final class PackInputsTests: XCTestCase {
    private typealias OutEvent = ConnectionViewModel.OutEvent

    private func concatInputs(_ events: [OutEvent]) -> Data {
        events.reduce(into: Data()) { acc, e in
            if case let .input(d) = e { acc.append(d) }
        }
    }

    func testAdjacentTinyInputsMergeIntoOneFrame() {
        let events: [OutEvent] = [.input(Data("a".utf8)), .input(Data("b".utf8)), .input(Data("c".utf8))]
        let packed = ConnectionViewModel.packInputs(events, maxInputFrameBytes: 1024)
        XCTAssertEqual(packed, [.input(Data("abc".utf8))], "key-repeat runs merge to one frame")
    }

    func testOversizedInputSplitsAtCap() {
        let big = Data((0..<10000).map { UInt8($0 % 251) })
        let packed = ConnectionViewModel.packInputs([.input(big)], maxInputFrameBytes: 4096)
        XCTAssertEqual(packed.count, 3, "10000 bytes at cap 4096 → 3 frames")
        for case let .input(d) in packed {
            XCTAssertLessThanOrEqual(d.count, 4096)
        }
        XCTAssertEqual(concatInputs(packed), big, "split frames reassemble byte-identically")
    }

    func testResizeIsAHardBarrier() {
        let events: [OutEvent] = [
            .input(Data("before".utf8)),
            .resize(cols: 100, rows: 30),
            .input(Data("after".utf8)),
        ]
        let packed = ConnectionViewModel.packInputs(events, maxInputFrameBytes: 1024)
        XCTAssertEqual(packed, [
            .input(Data("before".utf8)),
            .resize(cols: 100, rows: 30),
            .input(Data("after".utf8)),
        ], "input bytes never merge across a resize (a resize that preceded bytes is never emitted after them)")
    }

    func testConcatenationIdentityUnderMixedBatch() {
        var events: [OutEvent] = []
        var expected = Data()
        for i in 0..<50 {
            let payload = Data(repeating: UInt8(i % 256), count: (i % 7) * 700 + 1)
            events.append(.input(payload))
            expected.append(payload)
            if i.isMultiple(of: 11) { events.append(.resize(cols: UInt16(80 + i), rows: 24)) }
        }
        let packed = ConnectionViewModel.packInputs(events, maxInputFrameBytes: 2048)
        XCTAssertEqual(concatInputs(packed), expected, "byte-identity holds for arbitrary mixes")
        for case let .input(d) in packed {
            XCTAssertLessThanOrEqual(d.count, 2048, "every emitted frame respects the cap")
            XCTAssertFalse(d.isEmpty, "no empty frames are emitted")
        }
    }

    func testEmptyAndResizeOnlyBatchesPassThrough() {
        XCTAssertEqual(ConnectionViewModel.packInputs([]), [])
        let resizeOnly: [OutEvent] = [.resize(cols: 80, rows: 24)]
        XCTAssertEqual(ConnectionViewModel.packInputs(resizeOnly), resizeOnly)
    }

    func testPackAfterCoalesceKeepsTrailingResize() {
        // The production pipeline is packInputs(coalesceOut(batch)) — the trailing-edge
        // resize guarantee must survive the pack stage.
        let events: [OutEvent] = [
            .resize(cols: 90, rows: 25),
            .input(Data("x".utf8)),
            .resize(cols: 100, rows: 30),
            .resize(cols: 110, rows: 35),
        ]
        let packed = ConnectionViewModel.packInputs(ConnectionViewModel.coalesceOut(events))
        XCTAssertEqual(
            packed.last,
            .resize(cols: 110, rows: 35),
            "the final drag size still reaches the PTY after coalesce+pack",
        )
        XCTAssertEqual(concatInputs(packed), Data("x".utf8))
    }
}
