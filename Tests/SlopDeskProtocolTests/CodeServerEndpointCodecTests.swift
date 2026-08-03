import Foundation
import XCTest
@testable import SlopDeskProtocol

/// The ``MetadataCodec/CodeServerEndpoint`` wire codec (`ensureCodeServer` = 18): the 3-byte
/// `[UInt8 state][UInt16 BE port]` shape, validate-then-drop on truncation, trailer toleration,
/// and the forward-tolerant state byte (unknown → `.starting`, the benign keep-polling fallback).
final class CodeServerEndpointCodecTests: XCTestCase {
    func testRoundTripEveryState() throws {
        for state in MetadataCodec.CodeServerState.allCases {
            let endpoint = MetadataCodec.CodeServerEndpoint(state: state, port: 62636)
            let decoded = try MetadataCodec.decodeCodeServerEndpoint(
                MetadataCodec.encodeCodeServerEndpoint(endpoint),
            )
            XCTAssertEqual(decoded, endpoint)
            XCTAssertEqual(decoded.state, state)
        }
    }

    func testEncodedShapeIsPinned() {
        // [state][port BE] — 3 bytes, multi-byte int big-endian per the wire invariant.
        let data = MetadataCodec.encodeCodeServerEndpoint(
            MetadataCodec.CodeServerEndpoint(state: .ready, port: 0x1F90),
        )
        XCTAssertEqual(Array(data), [1, 0x1F, 0x90])
    }

    func testTruncatedThrows() {
        XCTAssertThrowsError(try MetadataCodec.decodeCodeServerEndpoint(Data()))
        XCTAssertThrowsError(try MetadataCodec.decodeCodeServerEndpoint(Data([1])))
        XCTAssertThrowsError(try MetadataCodec.decodeCodeServerEndpoint(Data([1, 0])))
    }

    func testTrailerTolerated() throws {
        // A future field appended after the port must not break this reader.
        let decoded = try MetadataCodec.decodeCodeServerEndpoint(Data([1, 0x1F, 0x90, 0xAB, 0xCD]))
        XCTAssertEqual(decoded, MetadataCodec.CodeServerEndpoint(state: .ready, port: 0x1F90))
    }

    func testUnknownStateByteReadsStarting() throws {
        // Forward-tolerant: a state this build cannot interpret must keep the client polling,
        // never render the install-hint error surface.
        let decoded = try MetadataCodec.decodeCodeServerEndpoint(Data([7, 0x00, 0x50]))
        XCTAssertEqual(decoded.stateByte, 7)
        XCTAssertEqual(decoded.state, .starting)
    }
}

/// The ``MetadataCodec/CodeFontSpec`` wire codec (`syncCodeFont` = 20): the
/// `[UInt16 len][family UTF-8][UInt64 BE size bits][UInt64 BE lineHeight bits]` shape,
/// validate-then-drop on truncation AND on out-of-range values — these numbers land in a settings
/// file the workbench trusts, so the DECODER is the range gate, not the writer.
final class CodeFontSpecCodecTests: XCTestCase {
    func testRoundTrip() throws {
        let spec = MetadataCodec.CodeFontSpec(family: "JetBrains Mono", size: 14, lineHeight: 1.58)
        let decoded = try MetadataCodec.decodeCodeFontSpec(MetadataCodec.encodeCodeFontSpec(spec))
        XCTAssertEqual(decoded, spec)
    }

    func testEncodedShapeIsPinned() {
        // [u16 len][utf8][size bitPattern BE][lineHeight bitPattern BE] — 14.0 = 0x402C…, 1.5 = 0x3FF8….
        let data = MetadataCodec.encodeCodeFontSpec(
            MetadataCodec.CodeFontSpec(family: "JB", size: 14, lineHeight: 1.5),
        )
        XCTAssertEqual(
            Array(data),
            [
                0x00,
                0x02,
                0x4A,
                0x42,
                0x40,
                0x2C,
                0,
                0,
                0,
                0,
                0,
                0,
                0x3F,
                0xF8,
                0,
                0,
                0,
                0,
                0,
                0,
            ],
        )
    }

    func testTruncatedThrows() {
        let full = MetadataCodec.encodeCodeFontSpec(
            MetadataCodec.CodeFontSpec(family: "JB", size: 14, lineHeight: 1.5),
        )
        for cut in 0..<full.count {
            XCTAssertThrowsError(try MetadataCodec.decodeCodeFontSpec(full.prefix(cut)))
        }
    }

    func testTrailerTolerated() throws {
        var data = MetadataCodec.encodeCodeFontSpec(
            MetadataCodec.CodeFontSpec(family: "JB", size: 14, lineHeight: 1.5),
        )
        data.append(contentsOf: [0xAB, 0xCD]) // a future field must not break this reader
        XCTAssertEqual(try MetadataCodec.decodeCodeFontSpec(data).family, "JB")
    }

    func testBlankFamilyDrops() {
        for family in ["", "   "] {
            XCTAssertThrowsError(try MetadataCodec.decodeCodeFontSpec(
                MetadataCodec.encodeCodeFontSpec(
                    MetadataCodec.CodeFontSpec(family: family, size: 14, lineHeight: 1.5),
                ),
            ))
        }
    }

    func testOutOfRangeAndNaNDrop() {
        // Size clamps to 4…128, lineHeight to 0.5…4; NaN fails BOTH `>=` gates by comparison
        // semantics — no explicit isNaN check needed, and these pin that stays true.
        let bad: [(Double, Double)] = [
            (3.9, 1.5), (128.1, 1.5), (14, 0.49), (14, 4.1),
            (Double.nan, 1.5), (14, Double.nan),
        ]
        for (size, lineHeight) in bad {
            XCTAssertThrowsError(try MetadataCodec.decodeCodeFontSpec(
                MetadataCodec.encodeCodeFontSpec(
                    MetadataCodec.CodeFontSpec(family: "JB", size: size, lineHeight: lineHeight),
                ),
            ), "size \(size) lineHeight \(lineHeight) must drop")
        }
    }

    func testBoundaryValuesPass() throws {
        for (size, lineHeight) in [(4.0, 0.5), (128.0, 4.0)] {
            let spec = MetadataCodec.CodeFontSpec(family: "JB", size: size, lineHeight: lineHeight)
            XCTAssertEqual(
                try MetadataCodec.decodeCodeFontSpec(MetadataCodec.encodeCodeFontSpec(spec)), spec,
            )
        }
    }
}

/// The ``MetadataCodec/CodeOpenDisposition`` wire codec (`openInCodeServer` = 19): the 1-byte
/// payload, truncation, trailer toleration, and the forward-tolerant unknown byte (→ `.workbench`,
/// the benign reveal-the-panel fallback).
final class CodeOpenDispositionCodecTests: XCTestCase {
    func testRoundTripAndPinnedBytes() throws {
        XCTAssertEqual(Array(MetadataCodec.encodeCodeOpenDisposition(.workbench)), [0])
        XCTAssertEqual(Array(MetadataCodec.encodeCodeOpenDisposition(.hostDefault)), [1])
        for disposition in MetadataCodec.CodeOpenDisposition.allCases {
            XCTAssertEqual(
                try MetadataCodec.decodeCodeOpenDisposition(
                    MetadataCodec.encodeCodeOpenDisposition(disposition),
                ),
                disposition,
            )
        }
    }

    func testEmptyThrowsTrailerToleratedUnknownReadsWorkbench() throws {
        XCTAssertThrowsError(try MetadataCodec.decodeCodeOpenDisposition(Data()))
        XCTAssertEqual(try MetadataCodec.decodeCodeOpenDisposition(Data([1, 0xFF])), .hostDefault)
        // An unknown future byte reveals the panel — worst case an expanded panel, never a
        // silently invisible open.
        XCTAssertEqual(try MetadataCodec.decodeCodeOpenDisposition(Data([9])), .workbench)
    }
}
