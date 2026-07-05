import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The pure ⌘F find-in-terminal engine (docs/42 W14 #5): literal + regex matching, case toggle, the
/// ordered match list, next/prev/wrap navigation, the "N of M" position, and re-anchoring on recompute.
/// All against an in-memory line buffer — no view, no libghostty.
final class TerminalSearchControllerTests: XCTestCase {
    private let buffer = [
        "the quick brown fox",
        "jumps over the lazy dog",
        "THE END",
        "error: file not found",
        "error: permission denied",
    ]

    private func make() -> TerminalSearchController {
        var c = TerminalSearchController()
        c.setLines(buffer)
        return c
    }

    // MARK: Literal matching

    func testEmptyQueryHasNoMatches() {
        var c = make()
        c.setQuery("")
        XCTAssertEqual(c.matchCount, 0)
        XCTAssertNil(c.currentIndex)
        XCTAssertNil(c.positionLabel)
    }

    func testCaseInsensitiveByDefaultFindsAllOccurrences() {
        var c = make()
        c.setQuery("the")
        // "the" (l0), "the" (l1 in "the lazy"), "THE" (l2) — case-insensitive default.
        XCTAssertEqual(c.matchCount, 3)
        XCTAssertEqual(c.matches.map(\.line), [0, 1, 2])
    }

    func testCaseSensitiveNarrows() {
        var c = make()
        c.setQuery("THE")
        c.setCaseSensitive(true)
        XCTAssertEqual(c.matchCount, 1)
        XCTAssertEqual(c.matches.first?.line, 2)
    }

    func testColumnAndLengthAreReported() {
        var c = make()
        c.setQuery("error")
        XCTAssertEqual(c.matchCount, 2)
        XCTAssertEqual(c.matches[0].line, 3)
        XCTAssertEqual(c.matches[0].column, 0)
        XCTAssertEqual(c.matches[0].length, 5)
    }

    func testOverlappingLiteralMatchesAreAllFound() {
        var c = TerminalSearchController()
        c.setLines(["aaaa"])
        c.setQuery("aa")
        // "aa" at offsets 0,1,2 — overlapping matches advance by one.
        XCTAssertEqual(c.matchCount, 3)
        XCTAssertEqual(c.matches.map(\.column), [0, 1, 2])
    }

    // MARK: Navigation + wrap

    func testNextWrapsAround() {
        var c = make()
        c.setQuery("the")
        XCTAssertEqual(c.currentIndex, 0)
        c.next()
        XCTAssertEqual(c.currentIndex, 1)
        c.next()
        XCTAssertEqual(c.currentIndex, 2)
        c.next()
        XCTAssertEqual(c.currentIndex, 0) // wrap
    }

    func testPreviousWrapsAround() {
        var c = make()
        c.setQuery("the")
        XCTAssertEqual(c.currentIndex, 0)
        c.previous()
        XCTAssertEqual(c.currentIndex, 2) // wrap to last
        c.previous()
        XCTAssertEqual(c.currentIndex, 1)
    }

    func testPositionLabel() {
        var c = make()
        c.setQuery("error")
        XCTAssertEqual(c.positionLabel?.current, 1)
        XCTAssertEqual(c.positionLabel?.total, 2)
        c.next()
        XCTAssertEqual(c.positionLabel?.current, 2)
        XCTAssertEqual(c.positionLabel?.total, 2)
    }

    func testCurrentMatchTracksIndex() {
        var c = make()
        c.setQuery("error")
        XCTAssertEqual(c.current?.line, 3)
        c.next()
        XCTAssertEqual(c.current?.line, 4)
    }

    // MARK: Recompute re-anchoring

    func testRecomputeClampsCurrentIndexWhenMatchesShrink() {
        var c = make()
        c.setQuery("error")
        c.next() // index 1 (the second "error")
        XCTAssertEqual(c.currentIndex, 1)
        // Narrowing to a query with ONE match must clamp the old index-1 into range.
        c.setQuery("permission")
        XCTAssertEqual(c.matchCount, 1)
        XCTAssertEqual(c.currentIndex, 0)
    }

    func testClearResetsQueryAndMatchesButKeepsBuffer() {
        var c = make()
        c.setQuery("the")
        XCTAssertEqual(c.matchCount, 3)
        c.clear()
        XCTAssertEqual(c.matchCount, 0)
        XCTAssertNil(c.currentIndex)
        XCTAssertTrue(c.query.isEmpty)
        // Buffer survives — reopening + querying works without re-feeding.
        c.setQuery("dog")
        XCTAssertEqual(c.matchCount, 1)
    }

    // MARK: Regex

    func testRegexMatching() {
        var c = make()
        c.setRegex(true)
        c.setQuery("error: \\w+")
        XCTAssertEqual(c.matchCount, 2)
        XCTAssertEqual(c.matches.map(\.line), [3, 4])
    }

    func testInvalidRegexYieldsNoMatchesNeverTraps() {
        var c = make()
        c.setRegex(true)
        c.setQuery("error(") // unbalanced — invalid pattern
        XCTAssertEqual(c.matchCount, 0) // validate-then-drop, no crash
        XCTAssertNil(c.currentIndex)
    }

    func testRegexAnchors() {
        var c = make()
        c.setRegex(true)
        c.setQuery("^error")
        XCTAssertEqual(c.matchCount, 2) // lines 3 & 4 start with "error"
    }

    // MARK: Whole-word (the underlined `ab` toggle)

    /// The core whole-word contract: a query matches a STANDALONE word but NOT a substring inside a larger word.
    /// Revert-to-confirm-fail: before the `wholeWord` mode existed there was no `setWholeWord(_:)` to flip and
    /// the literal scan counted every substring — so the post-toggle count below (2, the two standalone "the")
    /// could not be produced. With whole-word OFF the same query counts all 5 substring occurrences.
    func testWholeWordMatchesStandaloneWordNotSubstring() {
        var c = TerminalSearchController()
        c.setLines([
            "the theory of the case", // "the" ×2 standalone + "the" inside "theory"
            "breathe and soothe", // "the" buried inside "breathe" and "soothe"
        ])
        c.setQuery("the")
        XCTAssertEqual(c.matchCount, 5, "literal default counts every substring 'the'")

        c.setWholeWord(true)
        XCTAssertTrue(c.wholeWord)
        XCTAssertEqual(c.matchCount, 2, "whole-word keeps only the two standalone 'the' tokens")
        XCTAssertEqual(c.matches.map(\.line), [0, 0])
        XCTAssertEqual(c.matches.map(\.column), [0, 14], "the standalone 'the' at line start and in 'of the case'")
    }

    /// Whole-word honours the line edges (a word touching the start/end of a line is still standalone) and
    /// rejects a needle glued to a trailing word character (`fox` vs `foxes`).
    func testWholeWordRespectsLineEdgesAndTrailingWordChars() {
        var c = TerminalSearchController()
        c.setLines(["fox", "foxes", "a fox here"])
        c.setQuery("fox")
        c.setWholeWord(true)
        // "fox" (whole line, both edges) + "a fox here" (space-bounded); NOT "foxes" (followed by 'e').
        XCTAssertEqual(c.matchCount, 2)
        XCTAssertEqual(c.matches.map(\.line), [0, 2])
    }

    /// Digits and `_` count as word characters for boundary purposes (the `\w` sense), so `id` is NOT whole-word
    /// inside `id_3`, `id42`, or `_id` — only the bare `id` token matches.
    func testWholeWordTreatsDigitsAndUnderscoreAsWordChars() {
        var c = TerminalSearchController()
        c.setLines(["id id_3 id42 _id", "the id."])
        c.setQuery("id")
        c.setWholeWord(true)
        // Standalone "id" on line 0 (start) + "id" before the '.' on line 1; the glued forms are rejected.
        XCTAssertEqual(c.matchCount, 2)
        XCTAssertEqual(c.matches.map(\.line), [0, 1])
    }

    /// Whole-word composes with case sensitivity (orthogonal flags): case-sensitive + whole-word keeps only the
    /// exact-case standalone token.
    func testWholeWordComposesWithCaseSensitivity() {
        var c = TerminalSearchController()
        c.setLines(["The cat", "the theory", "THE cat"])
        c.setQuery("the")
        // Without whole-word this counts 4 (the buried 'the' in 'theory' too); whole-word drops that one to 3:
        // 'The' (l0), the standalone 'the' starting l1, 'THE' (l2) — all case-insensitive.
        c.setWholeWord(true)
        XCTAssertEqual(c.matchCount, 3, "case-insensitive whole-word excludes the 'the' buried in 'theory'")

        c.setCaseSensitive(true)
        XCTAssertEqual(c.matchCount, 1, "case-sensitive whole-word: only the lowercase standalone 'the'")
        XCTAssertEqual(c.matches.first?.line, 1)
    }

    /// Whole-word composes with regex too: the boundary filter applies AFTER the pattern scan, so `ca.` matches
    /// "cat"/"car" as standalone words but not when the three-char hit lands inside a larger token.
    func testWholeWordComposesWithRegex() {
        var c = TerminalSearchController()
        c.setLines(["cat car", "scatter", "a cab"])
        c.setRegex(true)
        c.setQuery("ca.")
        // Regex alone: "cat","car" (line0), "cat" inside "scatter" (line1), "cab" (line2) = 4.
        XCTAssertEqual(c.matchCount, 4)
        c.setWholeWord(true)
        // Whole-word drops the "cat" buried in "scatter"; keeps the three standalone words.
        XCTAssertEqual(c.matchCount, 3)
        XCTAssertEqual(c.matches.map(\.line), [0, 0, 2])
    }

    // MARK: Navigation no-ops with no matches

    func testNavigationIsNoOpWithoutMatches() {
        var c = make()
        c.setQuery("zzzznotfound")
        XCTAssertEqual(c.matchCount, 0)
        c.next()
        XCTAssertNil(c.currentIndex)
        c.previous()
        XCTAssertNil(c.currentIndex)
    }
}
