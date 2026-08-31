#if os(macOS)
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskTerminal

/// The band's pure text arithmetic — the half of `MacTerminalPromptView` that decides WHERE, and the
/// only half a headless test can reach.
///
/// The conversion under test is the seam the whole prompt is drawn through: the editor reports every
/// position in UTF-8 bytes and Core Text takes UTF-16 units, and the two agree on ASCII only. A test
/// in Latin letters would pass against the broken arithmetic, so every case here is Vietnamese —
/// which is also the composition `docs/68` §5.1 puts on the critical path.
@MainActor
final class TerminalPromptBandTests: XCTestCase {
    func testAsciiOffsetsAreTheSameInBothUnits() {
        let text = "git commit"
        for byte in 0...text.utf8.count {
            XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: byte), byte)
        }
    }

    /// `ế` is three UTF-8 bytes and one UTF-16 unit, so every position after it is two units left of
    /// its byte — which, drawn against the un-converted byte, is a caret two columns right of the
    /// letter it belongs to.
    func testVietnameseOffsetsDivergeFromTheirBytes() {
        let text = "Tiếng"
        XCTAssertEqual(text.utf8.count, 7)
        XCTAssertEqual(text.utf16.count, 5)
        XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: 0), 0)
        XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: 2), 2, "T, i, then the ế starts")
        XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: 5), 3, "past the three-byte ế")
        XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: 7), 5, "the end")
    }

    /// A byte INSIDE a scalar rounds down to that scalar's start rather than trapping.
    ///
    /// The editor never reports one — its caret is on grapheme boundaries — but a span from a build
    /// whose lexer disagrees could, and `draw(_:)` has nowhere to put a trap.
    func testAByteInsideAScalarRoundsDown() {
        XCTAssertEqual(MacTerminalPromptView.utf16Offset("Tiếng", utf8: 3), 2)
        XCTAssertEqual(MacTerminalPromptView.utf16Offset("Tiếng", utf8: 4), 2)
    }

    /// A caret past the end is what a stale span or a shorter re-lex produces, and it must clamp
    /// rather than trap: the whole band is drawn inside one `draw(_:)` that cannot throw.
    func testAnOutOfRangeByteClampsToTheEnd() {
        XCTAssertEqual(MacTerminalPromptView.utf16Offset("xin chào", utf8: 999), 8)
        XCTAssertEqual(MacTerminalPromptView.utf16Offset("", utf8: 4), 0)
        XCTAssertEqual(MacTerminalPromptView.utf16Offset("", utf8: 0), 0)
    }

    /// An emoji is one grapheme, four bytes and a SURROGATE PAIR — two UTF-16 units — which is the
    /// case that catches an implementation counting scalars instead.
    func testASurrogatePairCountsAsTwoUnits() {
        let text = "a🙂b"
        XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: 1), 1)
        XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: 5), 3, "past the surrogate pair")
        XCTAssertEqual(MacTerminalPromptView.utf16Offset(text, utf8: 6), 4)
    }

    /// An unlexed document paints plainly rather than vanishing — a span list that claims nothing
    /// still covers the line end to end.
    func testRunsCoverALineNoSpanClaims() {
        let runs = MacTerminalPromptView.runs([], over: 0..<6, in: "ls -la")
        XCTAssertEqual(runs.map(\.0), ["ls -la"])
        XCTAssertEqual(runs.map(\.1), [.argument])
    }

    /// What Enter is waiting for, in the words the accessory row prints.
    func testTheOpenLabelNamesTheThingToClose() {
        XCTAssertNil(MacTerminalPromptView.openLabel(.nothing))
        XCTAssertEqual(MacTerminalPromptView.openLabel(.singleQuote), "unclosed '")
        XCTAssertEqual(MacTerminalPromptView.openLabel(.substitution), "unclosed $(")
    }

    /// The regression for what the first pixel render of the band found: the ⌃R row printed the
    /// query and stopped, so the search never showed what it had matched. The buffer stays empty
    /// until accept, which is what makes this row the only place a hit can appear.
    func testTheSearchRowShowsTheHitItWouldAccept() {
        XCTAssertEqual(
            MacTerminalPromptView.searchRow(query: "clip", hit: "cargo clippy --all-targets"),
            "(reverse-i-search)`clip': cargo clippy --all-targets",
        )
        XCTAssertEqual(
            MacTerminalPromptView.searchRow(query: "zzz", hit: nil),
            "(reverse-i-search)`zzz'  (no match)",
        )
        // A recorded EMPTY command is still a hit, and reads as one rather than as no match — which
        // is why the caller keys on `searchHasHit` rather than on the string being empty.
        XCTAssertEqual(MacTerminalPromptView.searchRow(query: "", hit: ""), "(reverse-i-search)`': ")
    }
}
#endif
