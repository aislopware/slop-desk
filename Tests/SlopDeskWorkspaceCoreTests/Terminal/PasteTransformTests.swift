import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The PURE "Paste as…" clipboard transforms: the POSIX shell escape and the file → base64 encode.
/// Each case pins the transform against a HAND-WRITTEN expected string (never the function's own
/// derivation), so a broken transform fails loudly.
///
/// The bracketed-paste wrap is NOT here any more — the framing is the engine's, and
/// `slopdesk-vterm`'s `a_paste_is_framed_scrubbed_and_never_breaks_out_of_its_own_brackets` is where
/// the breakout case that used to live in this file is pinned.
final class PasteTransformTests: XCTestCase {
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
