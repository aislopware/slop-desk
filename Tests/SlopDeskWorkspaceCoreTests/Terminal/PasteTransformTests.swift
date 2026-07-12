import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The PURE "Paste as…" clipboard transforms: the bracketed-paste wrap, the POSIX
/// shell escape, and the file → base64 encode. Each case pins the transform against a HAND-WRITTEN
/// expected string (never the function's own derivation), so a broken transform fails loudly.
final class PasteTransformTests: XCTestCase {
    // MARK: Bracketed paste

    func testBracketedWrapsWithDecMarkers() {
        // ESC [ 200 ~  …  ESC [ 201 ~ — the DEC bracketed-paste framing, written out by hand.
        XCTAssertEqual(PasteTransform.bracketed("ls -la"), "\u{1b}[200~ls -la\u{1b}[201~")
    }

    func testBracketedEmptyStillFramed() {
        XCTAssertEqual(PasteTransform.bracketed(""), "\u{1b}[200~\u{1b}[201~")
    }

    func testBracketedStripsEmbeddedEndMarkerSoPasteStaysInert() {
        // A clipboard payload carrying the END marker would otherwise BREAK OUT of the bracketed
        // block early (the classic bracketed-paste injection) — it must be removed so the whole
        // payload lands as one inert block. The middle "\u{1b}[201~" is dropped, the framing kept.
        XCTAssertEqual(
            PasteTransform.bracketed("a\u{1b}[201~b"),
            "\u{1b}[200~ab\u{1b}[201~",
        )
    }

    // MARK: Shell escaping (POSIX, shlex.quote-equivalent)

    func testShellEscapedSafeStringUnquoted() {
        // A token of only safe characters needs no quoting at all.
        XCTAssertEqual(PasteTransform.shellEscaped("file.txt"), "file.txt")
        XCTAssertEqual(PasteTransform.shellEscaped("a/b-c_d.e"), "a/b-c_d.e")
    }

    func testShellEscapedEmptyBecomesEmptyQuotes() {
        XCTAssertEqual(PasteTransform.shellEscaped(""), "''")
    }

    func testShellEscapedPathWithSpaceIsSingleQuoted() {
        XCTAssertEqual(PasteTransform.shellEscaped("/My Documents/a.txt"), "'/My Documents/a.txt'")
    }

    func testShellEscapedMetacharactersAreSingleQuoted() {
        XCTAssertEqual(PasteTransform.shellEscaped("rm -rf *"), "'rm -rf *'")
        XCTAssertEqual(PasteTransform.shellEscaped("a;b&c|d"), "'a;b&c|d'")
        XCTAssertEqual(PasteTransform.shellEscaped("$(whoami)"), "'$(whoami)'")
    }

    func testShellEscapedEmbeddedSingleQuoteUsesCloseEscapeReopen() {
        // The single-quote can't appear inside a single-quoted string, so it is emitted as
        // '\'' (close-quote, backslash-escaped quote, reopen-quote). Input it's → 'it'\''s'.
        XCTAssertEqual(PasteTransform.shellEscaped("it's"), "'it'\\''s'")
    }

    // MARK: File → base64

    func testBase64OfFileBytes() {
        // "hello" → aGVsbG8= (a known, externally-verifiable base64 value).
        XCTAssertEqual(PasteTransform.base64(ofFileBytes: Data("hello".utf8)), "aGVsbG8=")
    }

    func testBase64OfEmptyFileIsEmpty() {
        XCTAssertEqual(PasteTransform.base64(ofFileBytes: Data()), "")
    }

    func testBase64OfBinaryBytes() {
        // Raw bytes 0x00 0xFF 0x10 → AP8Q (base64 of those three octets).
        XCTAssertEqual(PasteTransform.base64(ofFileBytes: Data([0x00, 0xFF, 0x10])), "AP8Q")
    }
}
