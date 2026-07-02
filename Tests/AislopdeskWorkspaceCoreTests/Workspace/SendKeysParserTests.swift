import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the ``SendKeysParser`` control-key token grammar — the shared "send-keys" primitive (launch
/// presets, session templates, block re-run, drops, the CLI `pane send-keys`): literal text is UTF-8,
/// `<Token>` markers become control bytes, and anything unrecognized stays LITERAL so ordinary text with
/// `<` is never mangled.
final class SendKeysParserTests: XCTestCase {
    func testLiteralTextIsUTF8() {
        XCTAssertEqual(SendKeysParser.encode("ls"), Array("ls".utf8))
    }

    func testNamedControlTokens() {
        XCTAssertEqual(SendKeysParser.encode("<Enter>"), [0x0D])
        XCTAssertEqual(SendKeysParser.encode("<Tab>"), [0x09])
        XCTAssertEqual(SendKeysParser.encode("<Esc>"), [0x1B])
        XCTAssertEqual(SendKeysParser.encode("<BS>"), [0x7F])
        XCTAssertEqual(SendKeysParser.encode("<Up>"), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(SendKeysParser.encode("<Left>"), [0x1B, 0x5B, 0x44])
    }

    func testCtrlChordFoldsToControlByte() {
        XCTAssertEqual(SendKeysParser.encode("<C-c>"), [0x03], "Ctrl-C")
        XCTAssertEqual(SendKeysParser.encode("<C-d>"), [0x04], "Ctrl-D")
        XCTAssertEqual(SendKeysParser.encode("<c-C>"), [0x03], "token names are case-insensitive")
    }

    func testUnknownTokenAndBareAngleAreLiteral() {
        XCTAssertEqual(SendKeysParser.encode("<foo>"), Array("<foo>".utf8), "unknown token is literal")
        XCTAssertEqual(SendKeysParser.encode("a < b"), Array("a < b".utf8), "a bare '<' is literal")
        XCTAssertEqual(SendKeysParser.encode("x<"), Array("x<".utf8), "a trailing '<' is literal")
    }

    func testCombinedLiteralAndTokens() {
        XCTAssertEqual(SendKeysParser.encode("git add -A<Enter>"), Array("git add -A".utf8) + [0x0D])
        // A chained two-command macro.
        XCTAssertEqual(
            SendKeysParser.encode("a<Enter>b<Enter>"),
            Array("a".utf8) + [0x0D] + Array("b".utf8) + [0x0D],
        )
    }
}
