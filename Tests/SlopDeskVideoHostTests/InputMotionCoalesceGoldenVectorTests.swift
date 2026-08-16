import Foundation
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// Replays the `inputMotionCoalesce` key of `golden/golden_vectors.json` through the live
/// ``InputMotionCoalescer``.
///
/// ## Why this suite exists
///
/// The key is frozen in `golden-check.sh` — in the corpus, not regenerated, listed as "XCTest-pinned".
/// **Nothing read it, and nothing even mentioned it**: unlike the capture and virtual-display keys,
/// which at least had a stale note in the generator claiming a Rust core validated them, this one had
/// no reader, no note and no emission. Fourteen cases of a hot-path collapse rule, recorded and
/// unchecked.
///
/// What it pins: which runs merge and which do not. A `.mouseMove` and a `.mouseDrag` must never
/// collapse into each other (a drag carries a held button; the transition is what the target app
/// needs), any non-motion event is a hard flush barrier, and the LAST event of a run always survives
/// — the trailing-edge guarantee the client's own send path is written 1:1 against
/// (`ConnectionViewModel`). Those are properties an optimisation would quietly break.
///
/// The vectors are hex-encoded wire bytes, so the events go in and come out through the SAME codec
/// the datagram path uses — the `inputEvent` key pins that codec separately, so a decode failure here
/// is a coalescer problem, not a codec one.
///
/// The corpus is READ here, never written.
final class InputMotionCoalesceGoldenVectorTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let inputHex: [String]
        let outputHex: [String]
    }

    func testCoalesceVectorsStillHold() throws {
        let cases: [Case] = try GoldenCorpus.load("inputMotionCoalesce")
        XCTAssertEqual(cases.count, 14, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            let batch = try testCase.inputHex.map { try InputEvent.decode(Self.bytes($0)) }
            let coalesced = InputMotionCoalescer.coalesce(batch)
            XCTAssertEqual(
                coalesced.map { $0.encode().map { String(format: "%02x", $0) }.joined() },
                testCase.outputHex,
                testCase.name,
            )
        }
    }

    private static func bytes(_ hex: String) throws -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = try XCTUnwrap(hex.index(index, offsetBy: 2, limitedBy: hex.endIndex))
            try out.append(XCTUnwrap(UInt8(hex[index..<next], radix: 16), "bad hex in \(hex)"))
            index = next
        }
        return out
    }
}
