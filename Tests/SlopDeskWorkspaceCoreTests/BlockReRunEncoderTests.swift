import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// WB3 — the PURE re-run encoder: a captured ``CommandBlock`` command → the exact bytes re-injected into
/// the shell (wire type 3 `.input`). The contract is security-critical: VERBATIM literal UTF-8 (NEVER the
/// send-keys parser, so a captured `"<Enter>"` is not turned into a control byte), exactly one trailing
/// newline (no double-execute), and a `nil` no-op for an empty / whitespace-only command.
final class BlockReRunEncoderTests: XCTestCase {
    private func bytes(_ command: String) -> Data? {
        BlockReRunEncoder.bytes(for: command)
    }

    /// A plain command gets exactly one trailing newline and nothing else.
    func testBasicCommandAppendsSingleNewline() {
        XCTAssertEqual(bytes("ls -la"), Data("ls -la\n".utf8))
    }

    /// A literal "<Enter>" substring is sent VERBATIM — NOT parsed into a carriage return. This is the
    /// load-bearing difference from LaunchPreset (which parses send-keys macros); a captured command must
    /// replay exactly what ran. (If this routed through SendKeysParser, the bytes would contain a 0x0D, not
    /// the literal text.)
    func testLiteralEnterTokenIsNotTransformed() {
        let out = bytes(#"echo "<Enter>""#)
        XCTAssertEqual(out, Data(#"echo "<Enter>"#.utf8) + Data(#"""#.utf8) + Data([0x0A]))
        // And concretely: the verbatim "<Enter>" text survives, no 0x0D was synthesized.
        let str = String(bytes: out ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("<Enter>"), "the literal token text is preserved verbatim")
        XCTAssertFalse(out?.contains(0x0D) ?? true, "no carriage return was synthesized from the token")
    }

    /// A command the host segmented WITH a trailing newline yields exactly ONE newline (no double-execute).
    func testTrailingNewlineCollapsesToSingle() {
        XCTAssertEqual(bytes("make\n"), Data("make\n".utf8))
        XCTAssertEqual(bytes("make\r\n"), Data("make\n".utf8))
        XCTAssertEqual(bytes("make\n\n"), Data("make\n".utf8), "a run of trailing newlines collapses to one")
    }

    /// Empty / whitespace-only commands are a no-op (`nil`) — never send a bare newline.
    func testEmptyOrWhitespaceReturnsNil() {
        XCTAssertNil(bytes(""))
        XCTAssertNil(bytes("   "))
        XCTAssertNil(bytes("\n"))
        XCTAssertNil(bytes(" \t\r\n "))
    }

    /// A multi-line command (newlines in the MIDDLE) is replayed verbatim — only the trailing newline is
    /// normalized; the interior newlines the user typed survive.
    func testMiddleNewlinesPreserved() {
        XCTAssertEqual(
            bytes("for i in 1 2\ndo echo $i\ndone"),
            Data("for i in 1 2\ndo echo $i\ndone\n".utf8),
        )
        // With a trailing newline too: interior kept, trailing collapsed to one.
        XCTAssertEqual(bytes("a\nb\n"), Data("a\nb\n".utf8))
    }
}
