import CoreText
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskTerminal

/// The band's pure text arithmetic — the half of `TerminalPromptBand` that decides WHERE, and the
/// only half a headless test can reach.
///
/// Unfenced, and that is the point of the extraction: this arithmetic is the same on both platforms
/// now, so a test that only ran on macOS would leave the phone's band pinned by nothing.
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
            XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: byte), byte)
        }
    }

    /// `ế` is three UTF-8 bytes and one UTF-16 unit, so every position after it is two units left of
    /// its byte — which, drawn against the un-converted byte, is a caret two columns right of the
    /// letter it belongs to.
    func testVietnameseOffsetsDivergeFromTheirBytes() {
        let text = "Tiếng"
        XCTAssertEqual(text.utf8.count, 7)
        XCTAssertEqual(text.utf16.count, 5)
        XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: 0), 0)
        XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: 2), 2, "T, i, then the ế starts")
        XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: 5), 3, "past the three-byte ế")
        XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: 7), 5, "the end")
    }

    /// A byte INSIDE a scalar rounds down to that scalar's start rather than trapping.
    ///
    /// The editor never reports one — its caret is on grapheme boundaries — but a span from a build
    /// whose lexer disagrees could, and `draw(_:)` has nowhere to put a trap.
    func testAByteInsideAScalarRoundsDown() {
        XCTAssertEqual(TerminalPromptBand.utf16Offset("Tiếng", utf8: 3), 2)
        XCTAssertEqual(TerminalPromptBand.utf16Offset("Tiếng", utf8: 4), 2)
    }

    /// A caret past the end is what a stale span or a shorter re-lex produces, and it must clamp
    /// rather than trap: the whole band is drawn inside one `draw(_:)` that cannot throw.
    func testAnOutOfRangeByteClampsToTheEnd() {
        XCTAssertEqual(TerminalPromptBand.utf16Offset("xin chào", utf8: 999), 8)
        XCTAssertEqual(TerminalPromptBand.utf16Offset("", utf8: 4), 0)
        XCTAssertEqual(TerminalPromptBand.utf16Offset("", utf8: 0), 0)
    }

    /// An emoji is one grapheme, four bytes and a SURROGATE PAIR — two UTF-16 units — which is the
    /// case that catches an implementation counting scalars instead.
    func testASurrogatePairCountsAsTwoUnits() {
        let text = "a🙂b"
        XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: 1), 1)
        XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: 5), 3, "past the surrogate pair")
        XCTAssertEqual(TerminalPromptBand.utf16Offset(text, utf8: 6), 4)
    }

    /// An unlexed document paints plainly rather than vanishing — a span list that claims nothing
    /// still covers the line end to end.
    func testRunsCoverALineNoSpanClaims() {
        let runs = TerminalPromptBand.runs([], over: 0..<6, in: "ls -la")
        XCTAssertEqual(runs.map(\.0), ["ls -la"])
        XCTAssertEqual(runs.map(\.1), [.argument])
    }

    /// What Enter is waiting for, in the words the accessory row prints.
    func testTheOpenLabelNamesTheThingToClose() {
        XCTAssertNil(TerminalPromptBand.openLabel(.nothing))
        XCTAssertEqual(TerminalPromptBand.openLabel(.singleQuote), "unclosed '")
        XCTAssertEqual(TerminalPromptBand.openLabel(.substitution), "unclosed $(")
    }

    /// A ⌃R session is the query row PLUS its panel, and the count has to say so.
    ///
    /// The regression: `accessoryRows` answered a flat `1` while searching, which was right when a
    /// search had exactly one hit spliced into that row and clips every row of the panel that
    /// replaced it. Arithmetic can settle this one because the same number both reserves the height
    /// and places the rows — a wrong answer agrees with itself and draws off the end of the band.
    func testASearchCountsItsQueryRowAndItsPanel() {
        let prompt = CommandPrompt()
        for command in ["cargo test", "cargo build", "ls"] { prompt.recordHistory(command) }
        XCTAssertEqual(TerminalPromptBand.accessoryRows(prompt), 0, "a closed line shows nothing")

        prompt.beginSearch()
        XCTAssertEqual(
            TerminalPromptBand.accessoryRows(prompt), 4,
            "an empty query lists every command, under the row it is typed on",
        )
        prompt.searchType("cargo")
        XCTAssertEqual(TerminalPromptBand.accessoryRows(prompt), 3, "`ls` is out; the row stays")
        prompt.searchType("zzz")
        XCTAssertEqual(TerminalPromptBand.accessoryRows(prompt), 1, "nothing matched: the row alone")
        prompt.cancelSearch()
        XCTAssertEqual(TerminalPromptBand.accessoryRows(prompt), 0, "and the panel goes with it")
    }

    /// The panel is capped, so a thousand-command history cannot take the pane.
    func testThePanelNeverGrowsPastItsLimit() {
        let prompt = CommandPrompt()
        for index in 0..<40 { prompt.recordHistory("cargo test --lib \(index)") }
        prompt.beginSearch()
        XCTAssertEqual(
            TerminalPromptBand.accessoryRows(prompt), TerminalPromptBand.candidateLimit + 1,
        )
    }

    /// The count on the query row is what MATCHED, and the rows are not where it can come from.
    ///
    /// Two caps sit between the history and the screen — the engine's, before the records cross the
    /// FFI, and the band's six — so `candidates.count` is the middle one and reads as a plausible
    /// total right up until a query matches more than it. 60 entries is past the engine's, which is
    /// the only place that shows.
    func testTheCountIsWhatMatchedAndNotWhatCrossed() {
        let prompt = CommandPrompt()
        for index in 0..<60 { prompt.recordHistory("cargo test --lib \(index)") }
        prompt.beginSearch()
        prompt.searchType("cargo")
        XCTAssertEqual(prompt.searchMatches, 60, "every entry matched")
        XCTAssertLessThan(prompt.candidates.count, 60, "and the list crossed capped")
        XCTAssertEqual(
            TerminalPromptBand.searchRow(
                query: "cargo",
                matches: prompt.searchMatches,
                shown: TerminalPromptBand.candidateLimit,
            ),
            "(reverse-i-search)`cargo'  6 of 60",
        )
    }

    /// The ⌃R row says the query and the one thing the panel under it CANNOT: what did not fit.
    ///
    /// It used to splice the single hit in, because the search only ever found one and the buffer
    /// stays untouched until accept — the first pixel render of the band caught it printing the
    /// query and stopping, which was a search that never showed a result. The panel shows every
    /// match now, so a hit here would print the selected row twice.
    func testTheSearchRowCountsOnlyWhatDidNotFit() {
        // Everything fits: no count, because a count of what you can see is noise.
        XCTAssertEqual(
            TerminalPromptBand.searchRow(query: "clip", matches: 3, shown: 6),
            "(reverse-i-search)`clip'",
        )
        // Truncated: the total, which is otherwise invisible.
        XCTAssertEqual(
            TerminalPromptBand.searchRow(query: "git", matches: 23, shown: 6),
            "(reverse-i-search)`git'  6 of 23",
        )
        XCTAssertEqual(
            TerminalPromptBand.searchRow(query: "zzz", matches: 0, shown: 6),
            "(reverse-i-search)`zzz'  (no match)",
        )
        // A fresh ⌃R has an empty query and a full panel — the recent-commands list, not "no match".
        XCTAssertEqual(
            TerminalPromptBand.searchRow(query: "", matches: 4, shown: 6),
            "(reverse-i-search)`'",
        )
    }
}

/// The inline ghost — Warp's other completion affordance, next to the list.
///
/// The list answers "what are the choices"; the ghost answers "what would THIS one do", which for a
/// long path or a subcommand is the only one of the two a reader can act on without counting
/// characters. What every case here pins is the same invariant from a different side: **the ghost is
/// exactly what accepting would add, or it is nothing.** A preview that is off by even a quote is
/// worse than no preview, because the user has already read it as the outcome.
@MainActor
final class TerminalPromptGhostTests: XCTestCase {
    /// The ghost IS the accept, character for character — asserted by performing the accept.
    ///
    /// Deliberately not spelled as "expect `mit`": a hard-coded tail would still pass if `insert` and
    /// `text` diverged (a quoted path, a case fix), which is the one way this can be wrong and look
    /// right. Comparing against the document the accept actually produces cannot.
    func testTheGhostIsExactlyWhatAcceptingWouldAdd() throws {
        let prompt = seeded("git com")
        XCTAssertGreaterThan(prompt.complete(), 0, "the seeded subcommand ranks")
        let ghost = try XCTUnwrap(TerminalPromptBand.ghost(prompt), "something is highlighted to preview")
        let before = prompt.text
        XCTAssertTrue(prompt.acceptCompletion())
        XCTAssertEqual(prompt.text, before + ghost)
    }

    /// Moving the caret takes the ghost with it — and pins WHY, which is not a check in the band.
    ///
    /// The ghost is drawn at the caret, so a caret away from the replacement's end would print the
    /// tail in one place and insert it in another: a lie the user cannot see is a lie. The band does
    /// not guard against that and must not, because the state cannot arise — the engine's
    /// `after_navigation` dismisses the candidate list on every motion, so there is nothing
    /// highlighted left to preview.
    ///
    /// Asserting the DISMISSAL and not just the `nil` is the point. A test that only demanded
    /// `ghost == nil` would keep passing if the engine stopped dismissing and the ghost went stale
    /// over a moved caret — the one regression this is here to catch.
    func testMovingTheCaretTakesTheGhostWithIt() {
        let prompt = seeded("git com")
        XCTAssertGreaterThan(prompt.complete(), 0)
        XCTAssertNotNil(TerminalPromptBand.ghost(prompt))
        let back = prompt.cursor - 1
        prompt.pointerSelect(anchor: back, head: back, granularity: .caret)
        XCTAssertTrue(prompt.candidates.isEmpty, "the engine dropped the list the caret invalidated")
        XCTAssertNil(TerminalPromptBand.ghost(prompt))
    }

    /// No candidates, no ghost — the empty list is not a preview of the first thing that ranked last.
    func testNothingHighlightedPreviewsNothing() {
        XCTAssertNil(TerminalPromptBand.ghost(seeded("git com")))
    }

    /// A prompt holding `text`, with one command seeded so completion is deterministic and needs no
    /// filesystem.
    private func seeded(_ text: String) -> CommandPrompt {
        let prompt = CommandPrompt()
        prompt.addCommand(name: "git", subcommands: ["commit", "checkout"], flags: ["--amend"])
        prompt.insert(text)
        return prompt
    }
}

/// Where a pointer landed — the inverse of the row walk `draw` lays out, and the arithmetic every
/// click, drag, double-click and row pick goes through.
///
/// Pinning it with numbers rather than with a render is the point: the SAME two functions place the
/// caret and read a click back, so a disagreement between them is a click that selects the row above
/// the one under the pointer, and no screenshot says which of the two is wrong.
@MainActor
final class TerminalPromptHitTests: XCTestCase {
    /// A byte offset survives the trip out to a pixel and back — the property the whole pointer path
    /// rests on, since the caret is placed by the forward direction and clicked by the inverse.
    ///
    /// Vietnamese and an emoji rather than ASCII, because the conversion is the seam: a click that
    /// went out through `utf16Offset` and came back through a byte count would land two columns off
    /// per `ế`, and on the wrong half of a surrogate pair for the emoji.
    func testAClickLandsOnTheByteTheCaretWasDrawnAt() {
        let metrics = bandMetrics()
        for text in ["git commit", "xin chào thế giới", "echo 🙂 ok"] {
            let prompt = CommandPrompt()
            prompt.insert(text)
            for byte in text.utf8.indices.map({ text.utf8.distance(from: text.utf8.startIndex, to: $0) }) {
                prompt.pointerSelect(anchor: byte, head: byte, granularity: .caret)
                guard let origin = TerminalPromptBand.caretOrigin(
                    prompt, metrics: metrics, from: TerminalPromptBand.inset.height,
                ) else {
                    XCTFail("every caret in a one-line document is on that line")
                    continue
                }
                let point = CGPoint(x: origin.x, y: origin.y - metrics.ascent + 1)
                // Against the caret the editor SETTLED on, not the byte asked for: a byte inside a
                // cluster snaps back on the way in, so `à`'s continuation byte is the caret at `à`
                // and a click on the drawn bar has to answer that one. Asserting the request instead
                // would be asserting that the snap did not happen.
                XCTAssertEqual(
                    TerminalPromptBand.hit(prompt, metrics: metrics, at: point), .text(prompt.cursor),
                    "byte \(byte) of `\(text)`",
                )
            }
        }
    }

    /// A press inside the `❯ ` mark, or off the left edge entirely, is the line's start rather than a
    /// negative offset — `CTLineGetStringIndexForPosition` answers `kCFNotFound` for the second.
    func testTheLeadingMarkIsNotPartOfTheDocument() {
        let metrics = bandMetrics()
        let prompt = CommandPrompt()
        prompt.insert("ls -la")
        let y = TerminalPromptBand.inset.height + 1
        XCTAssertEqual(TerminalPromptBand.hit(prompt, metrics: metrics, at: CGPoint(x: 0, y: y)), .text(0))
        XCTAssertEqual(
            TerminalPromptBand.hit(prompt, metrics: metrics, at: CGPoint(x: -400, y: y)), .text(0),
        )
    }

    /// The row walk is `draw`'s: document rows first, then the accessory, and a point above the band
    /// clamps into the first row rather than answering nothing.
    ///
    /// The clamp is what a DRAG needs — the pointer leaves the band's top on any upward selection —
    /// and it is why ``TerminalPromptBand/byteOffset(_:metrics:at:)`` is total over the whole plane.
    func testTheRowWalkMatchesTheDrawingOrder() {
        let metrics = bandMetrics()
        let prompt = CommandPrompt()
        prompt.insert("one")
        prompt.insertNewline()
        prompt.insert("two")
        XCTAssertEqual(TerminalPromptBand.documentRows(prompt), 2)

        let top = TerminalPromptBand.inset.height
        XCTAssertEqual(
            TerminalPromptBand.hit(prompt, metrics: metrics, at: CGPoint(x: 0, y: top - 99)), .text(0),
            "above the band is still the first row",
        )
        XCTAssertEqual(
            TerminalPromptBand.hit(prompt, metrics: metrics, at: CGPoint(x: 0, y: top + 1)), .text(0),
        )
        XCTAssertEqual(
            TerminalPromptBand.hit(prompt, metrics: metrics, at: CGPoint(x: 0, y: top + metrics.lineHeight + 1)),
            .text(4),
            "the second logical line starts past the newline",
        )
    }

    /// A ⌃R session spends its first accessory row on the query, so every candidate row is one lower
    /// than it would be under a completion list. Getting that off by one picks the row above the one
    /// the user pointed at.
    func testTheSearchQueryRowIsNotACandidate() {
        let metrics = bandMetrics()
        let prompt = CommandPrompt()
        for command in ["cargo test", "cargo build"] { prompt.recordHistory(command) }
        prompt.beginSearch()
        prompt.searchType("cargo")
        XCTAssertEqual(prompt.candidates.count, 2)

        // One document row, then the query row, then the two matches.
        let row = { (index: Int) in
            CGPoint(x: 20, y: TerminalPromptBand.inset.height + CGFloat(index) * metrics.lineHeight + 1)
        }
        XCTAssertEqual(TerminalPromptBand.hit(prompt, metrics: metrics, at: row(1)), .inert, "the query")
        XCTAssertEqual(TerminalPromptBand.hit(prompt, metrics: metrics, at: row(2)), .candidate(0))
        XCTAssertEqual(TerminalPromptBand.hit(prompt, metrics: metrics, at: row(3)), .candidate(1))
        XCTAssertEqual(TerminalPromptBand.hit(prompt, metrics: metrics, at: row(4)), .inert, "past the list")
    }

    /// Without a search the panel starts at the accessory's first row, and the "unclosed" hint that
    /// occupies the same row is never a candidate.
    func testACompletionPanelStartsAtTheFirstAccessoryRow() {
        let metrics = bandMetrics()
        let prompt = seeded("git com")
        XCTAssertGreaterThan(prompt.complete(), 0)
        let row = { (index: Int) in
            CGPoint(x: 20, y: TerminalPromptBand.inset.height + CGFloat(index) * metrics.lineHeight + 1)
        }
        XCTAssertEqual(TerminalPromptBand.hit(prompt, metrics: metrics, at: row(1)), .candidate(0))

        let open = CommandPrompt()
        open.insert("echo \"unclosed")
        XCTAssertEqual(TerminalPromptBand.accessoryRows(open), 1, "the hint takes a row")
        XCTAssertEqual(
            TerminalPromptBand.hit(open, metrics: metrics, at: row(1)), .inert,
            "which is a label and not a row to pick",
        )
    }

    /// The UTF-16→UTF-8 direction, on its own: the inverse of `utf16Offset` at every boundary, with a
    /// unit inside a surrogate pair rounding back to the pair's start rather than splitting a scalar.
    func testUtf8OffsetInvertsUtf16Offset() {
        for text in ["git commit", "Tiếng Việt", "a🙂b"] {
            for byte in 0...text.utf8.count where String.Index(
                text.utf8.index(text.utf8.startIndex, offsetBy: byte), within: text,
            ) != nil {
                let unit = TerminalPromptBand.utf16Offset(text, utf8: byte)
                XCTAssertEqual(TerminalPromptBand.utf8Offset(text, utf16: unit), byte, "`\(text)` at \(byte)")
            }
        }
        XCTAssertEqual(TerminalPromptBand.utf8Offset("a🙂b", utf16: 2), 1, "inside the pair, rounded back")
        XCTAssertEqual(TerminalPromptBand.utf8Offset("a🙂b", utf16: 99), 6, "past the end clamps")
    }

    /// A prompt holding `text`, with one command seeded so completion is deterministic and needs no
    /// filesystem.
    private func seeded(_ text: String) -> CommandPrompt {
        let prompt = CommandPrompt()
        prompt.addCommand(name: "git", subcommands: ["commit", "checkout"], flags: ["--amend"])
        prompt.insert(text)
        return prompt
    }

    /// Metrics with round numbers, so a row test says which row it means instead of depending on
    /// whatever face this machine resolved.
    private func bandMetrics() -> TerminalPromptBand.Metrics {
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, 12, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, 12, nil)
        return TerminalPromptBand.Metrics(font: font, ascent: 10, lineHeight: 20)
    }
}
