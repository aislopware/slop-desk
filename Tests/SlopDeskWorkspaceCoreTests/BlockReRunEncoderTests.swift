import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// WB3 — the re-run encoder driven at its one public entry point: a captured ``CommandBlock`` command → the
/// exact bytes re-injected into the shell (wire type 3 `.input`).
///
/// WHAT THIS SUITE IS NOW. The rule is `slopdesk_terminal::blocks::rerun_bytes` and the crate pins it there —
/// verbatim literal UTF-8 rather than the send-keys parser, exactly one trailing newline, middle newlines
/// preserved, nothing at all for a blank command, and the one Unicode scalar where Foundation's whitespace
/// set and Rust's part company. Every behavioural case below predates the port and is unchanged, which is
/// how a reader checks that the Swift implementation was DELETED rather than kept as a second answer
/// (`docs/55` §6). The cases at the end are the marshalling half — the failures that can only happen on this
/// side of the boundary, and that no Rust test can see.
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

    // MARK: the crossing itself

    /// The caller sizes its buffer at the command's UTF-8 byte count plus one, which is an arithmetic bound
    /// rather than a guess. A command far larger than anything a prompt line holds still comes back whole,
    /// so a sizing mistake shows up as a truncation here rather than as a half-command reaching a shell.
    func testALargeCommandCrossesWhole() {
        let command = String(repeating: "echo hello; ", count: 4096)
        XCTAssertEqual(bytes(command), Data((command + "\n").utf8))
    }

    /// Non-ASCII is where a byte-length bound and a character count would part company, so the payload has
    /// to survive scalar for scalar — a re-run that mangles a path with an accent in it is a command that
    /// runs and does the wrong thing, which is worse than one that does not run.
    func testMultiByteScalarsSurviveTheCrossingByteForByte() {
        let command = "grep 'Đường' ./naïve/файл.txt 🎯"
        XCTAssertEqual(bytes(command), Data((command + "\n").utf8))
    }

    /// A NUL and the other C-hostile bytes are data to a shell, not terminators, and the door takes a
    /// pointer and a length precisely so no byte in the middle can end the command early.
    func testAnEmbeddedNulDoesNotTruncateTheCommand() {
        let command = "echo 'a\u{0}b'"
        XCTAssertEqual(bytes(command), Data((command + "\n").utf8))
    }
}
