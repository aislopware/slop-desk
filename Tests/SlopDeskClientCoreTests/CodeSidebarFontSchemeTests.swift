// CodeSidebarFontSchemeTests — the pure half of the font scheme: the URLs the dressing sheet
// names, the faces a request resolves to, and the headers a served face carries. The
// `WKURLSchemeHandler` conformance itself is WebKit-only and deliberately unreachable here.

#if os(macOS)
import XCTest
@testable import SlopDeskClientCore

final class CodeSidebarFontSchemeTests: XCTestCase {
    /// The sheet and the handler have to agree on one URL shape; a round trip is the cheapest way
    /// to keep them from drifting apart.
    func testEveryFaceRoundTripsThroughItsURL() {
        for face in CodeSidebarFontScheme.Face.allCases {
            let url = URL(string: CodeSidebarFontScheme.url(for: face))
            XCTAssertEqual(CodeSidebarFontScheme.face(forRequest: url), face, "\(face) round-trips")
        }
    }

    /// The `fonts` authority is not decoration — a scheme URL with an empty authority parses
    /// opaque, and WebKit never routes it to the handler.
    func testURLCarriesASchemeAndAnAuthority() {
        let url = URL(string: CodeSidebarFontScheme.url(for: .nerdSymbols))

        XCTAssertEqual(url?.scheme, "slopdesk-font")
        XCTAssertEqual(url?.host, "fonts")
        XCTAssertEqual(url?.lastPathComponent, "nerd-symbols.ttf")
    }

    /// Validate-then-drop: anything this app did not mint resolves to no face, and the handler
    /// answers those with a failure rather than bytes.
    func testForeignRequestsResolveToNoFace() {
        for candidate in [
            "https://fonts/nerd-symbols.ttf", // right path, wrong scheme
            "slopdesk-font://fonts/not-a-face.ttf",
            "slopdesk-font://fonts/",
            "file:///etc/passwd",
        ] {
            XCTAssertNil(
                CodeSidebarFontScheme.face(forRequest: URL(string: candidate)), "rejected: \(candidate)",
            )
        }
        XCTAssertNil(CodeSidebarFontScheme.face(forRequest: nil))
    }

    /// The served face declares its type, length and cacheability, and answers the cross-origin
    /// question a CORS-anonymous CSS font load nominally asks. (Measured 2026-08-03: this WebKit
    /// loads the face with or without the CORS header — see `CodeSidebarFontScheme` — so the pin
    /// is on the contract we send, not on a claim about what WebKit enforces.)
    func testResponseHeadersDescribeTheServedFace() {
        let headers = CodeSidebarFontScheme.responseHeaders(byteCount: 2_440_316)

        XCTAssertEqual(headers["Access-Control-Allow-Origin"], "*")
        XCTAssertEqual(headers["Content-Type"], "font/ttf")
        XCTAssertEqual(headers["Content-Length"], "2440316")
        XCTAssertEqual(headers["Cache-Control"], "public, max-age=31536000, immutable")
    }

    /// The faces the sheet declares must all actually ship — a renamed or dropped bundle resource
    /// would otherwise degrade the editor to a system font with no other symptom.
    func testEveryFaceResolvesToABundledFile() throws {
        for face in CodeSidebarFontScheme.Face.allCases {
            let url = try XCTUnwrap(CodeSidebarFontScheme.bundledURL(for: face), "\(face) is bundled")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(face) exists on disk")
        }
    }
}
#endif
