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
