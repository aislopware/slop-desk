import XCTest
@testable import SlopDeskWorkspaceCore

/// ⇧⌘F's cross-pane scan over a text mirror (``ScrollbackMatcher``): literal + regex matching, the case
/// and whole-word toggles, the ordered match list, and every arm of the guess-then-retry answer buffer.
/// All against an in-memory line buffer — no view, no libghostty-vt.
///
/// ⚠️ **The navigation half of this suite is GONE rather than moved.** Next/prev, the wrap, the "N of M"
/// position and the re-anchor on recompute used to live here because the in-pane ⌘F bar drove them from
/// this scan — which is exactly the second engine gap 4 deleted. The match CURSOR is the terminal
/// surface's now (`slopdesk-vterm`, tested there); what is left in Swift is a pure function from lines to
/// matches, and a stateful cursor is not a thing this type has any more.
final class ScrollbackMatcherTests: XCTestCase {
    private let buffer = [
        "the quick brown fox",
        "jumps over the lazy dog",
        "THE END",
        "error: file not found",
        "error: permission denied",
    ]

    /// The scan under test, spelled once so a mode is a named argument rather than a positional habit.
    private func scan(
        _ lines: [String],
        _ query: String,
        caseSensitive: Bool = false,
        isRegex: Bool = false,
        wholeWord: Bool = false,
        expecting: Int = 0,
    ) -> [ScrollbackMatcher.Match] {
        ScrollbackMatcher.computeMatches(
            lines: lines, query: query, caseSensitive: caseSensitive, isRegex: isRegex,
            wholeWord: wholeWord, expecting: expecting,
        )
    }

    // MARK: Literal matching

    func testEmptyQueryHasNoMatches() {
        XCTAssertTrue(scan(buffer, "").isEmpty)
    }

    func testCaseInsensitiveByDefaultFindsAllOccurrences() {
        // "the" (l0), "the" (l1 in "the lazy"), "THE" (l2) — case-insensitive default.
        XCTAssertEqual(scan(buffer, "the").map(\.line), [0, 1, 2])
    }

    func testCaseSensitiveNarrows() {
        let hits = scan(buffer, "THE", caseSensitive: true)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.line, 2)
    }

    func testColumnAndLengthAreReported() {
        let hits = scan(buffer, "error")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].line, 3)
        XCTAssertEqual(hits[0].column, 0)
        XCTAssertEqual(hits[0].length, 5)
    }

    func testOverlappingLiteralMatchesAreAllFound() {
        // "aa" at offsets 0,1,2 — overlapping matches advance by one.
        XCTAssertEqual(scan(["aaaa"], "aa").map(\.column), [0, 1, 2])
    }

    /// The order is the reading order — line index, then column — because the overlay's result list and
    /// its up/down keys walk this array directly.
    func testMatchesAreOrderedByLineThenColumn() {
        let hits = scan(["b a b", "a"], "a")
        XCTAssertEqual(hits.map { [$0.line, $0.column] }, [[0, 2], [1, 0]])
    }

    // MARK: Regex

    func testRegexMatching() {
        XCTAssertEqual(scan(buffer, "error: \\w+", isRegex: true).map(\.line), [3, 4])
    }

    func testInvalidRegexYieldsNoMatchesNeverTraps() {
        // Unbalanced group — validate-then-drop, no crash.
        XCTAssertTrue(scan(buffer, "error(", isRegex: true).isEmpty)
    }

    func testRegexAnchors() {
        XCTAssertEqual(scan(buffer, "^error", isRegex: true).count, 2) // lines 3 & 4 start with "error"
    }

    // MARK: Whole-word (the underlined `ab` toggle)

    /// The core whole-word contract: a query matches a STANDALONE word but NOT a substring inside a larger
    /// word. Revert-to-confirm-fail: before the `wholeWord` mode existed there was no flag to pass and the
    /// literal scan counted every substring — so the post-toggle count below (2, the two standalone "the")
    /// could not be produced. With whole-word OFF the same query counts all 5 substring occurrences.
    func testWholeWordMatchesStandaloneWordNotSubstring() {
        let lines = [
            "the theory of the case", // "the" ×2 standalone + "the" inside "theory"
            "breathe and soothe", // "the" buried inside "breathe" and "soothe"
        ]
        XCTAssertEqual(scan(lines, "the").count, 5, "literal default counts every substring 'the'")

        let whole = scan(lines, "the", wholeWord: true)
        XCTAssertEqual(whole.count, 2, "whole-word keeps only the two standalone 'the' tokens")
        XCTAssertEqual(whole.map(\.line), [0, 0])
        XCTAssertEqual(whole.map(\.column), [0, 14], "the standalone 'the' at line start and in 'of the case'")
    }

    /// Whole-word honours the line edges (a word touching the start/end of a line is still standalone) and
    /// rejects a needle glued to a trailing word character (`fox` vs `foxes`).
    func testWholeWordRespectsLineEdgesAndTrailingWordChars() {
        // "fox" (whole line, both edges) + "a fox here" (space-bounded); NOT "foxes" (followed by 'e').
        XCTAssertEqual(scan(["fox", "foxes", "a fox here"], "fox", wholeWord: true).map(\.line), [0, 2])
    }

    /// Digits and `_` count as word characters for boundary purposes (the `\w` sense), so `id` is NOT
    /// whole-word inside `id_3`, `id42`, or `_id` — only the bare `id` token matches.
    func testWholeWordTreatsDigitsAndUnderscoreAsWordChars() {
        // Standalone "id" on line 0 (start) + "id" before the '.' on line 1; the glued forms are rejected.
        XCTAssertEqual(scan(["id id_3 id42 _id", "the id."], "id", wholeWord: true).map(\.line), [0, 1])
    }

    /// Whole-word composes with case sensitivity (orthogonal flags): case-sensitive + whole-word keeps only
    /// the exact-case standalone token.
    func testWholeWordComposesWithCaseSensitivity() {
        let lines = ["The cat", "the theory", "THE cat"]
        // Without whole-word this counts 4 (the buried 'the' in 'theory' too); whole-word drops that one to 3:
        // 'The' (l0), the standalone 'the' starting l1, 'THE' (l2) — all case-insensitive.
        XCTAssertEqual(
            scan(lines, "the", wholeWord: true).count, 3,
            "case-insensitive whole-word excludes the 'the' buried in 'theory'",
        )

        let exact = scan(lines, "the", caseSensitive: true, wholeWord: true)
        XCTAssertEqual(exact.count, 1, "case-sensitive whole-word: only the lowercase standalone 'the'")
        XCTAssertEqual(exact.first?.line, 1)
    }

    /// Whole-word composes with regex too: the boundary filter applies AFTER the pattern scan, so `ca.`
    /// matches "cat"/"car" as standalone words but not when the three-char hit lands inside a larger token.
    func testWholeWordComposesWithRegex() {
        let lines = ["cat car", "scatter", "a cab"]
        // Regex alone: "cat","car" (line0), "cat" inside "scatter" (line1), "cab" (line2) = 4.
        XCTAssertEqual(scan(lines, "ca.", isRegex: true).count, 4)
        // Whole-word drops the "cat" buried in "scatter"; keeps the three standalone words.
        XCTAssertEqual(scan(lines, "ca.", isRegex: true, wholeWord: true).map(\.line), [0, 0, 2])
    }

    // MARK: The answer buffer — every arm of the guess-then-retry

    /// More matches than the stack guess holds, so the door reports a size the first buffer could not
    /// take and the answer arrives on the retry. The count and the LAST record both matter: a retry
    /// that silently truncated would still report a plausible count.
    func testAnswerSurvivesOutgrowingTheFirstGuess() {
        let hits = scan((0..<500).map { "row \($0) needle here" }, "needle")
        XCTAssertEqual(hits.count, 500, "every row matched, well past the 128-record stack guess")
        XCTAssertEqual(hits.last?.line, 499)
        XCTAssertEqual(hits.last?.length, 6)
    }

    /// The same answer whether the guess was short, exact or generous. ``GlobalSearchController`` carries
    /// one pane's count into the next pane's scan, so the guess is an input the door's answer must be
    /// independent of — that independence is what makes carrying it safe.
    func testTheGuessCannotChangeTheAnswer() {
        let rows = (0..<300).map { "row \($0) needle here" }
        let truth = scan(rows, "needle")
        XCTAssertEqual(truth.count, 300)
        for guess in [0, 1, 127, 128, 129, 299, 300, 301, 5000] {
            let answer = scan(rows, "needle", expecting: guess)
            XCTAssertEqual(answer.map(\.line), truth.map(\.line), "guess \(guess) changed the answer")
            XCTAssertEqual(answer.map(\.column), truth.map(\.column), "guess \(guess) changed the answer")
        }
    }

    /// A guess carried from a NARROWER query is the shape the retry exists for: a scan that answered zero
    /// last keystroke, then one matching far more than the stack guess, must still answer in full.
    func testCarriedGuessSurvivesWideningTheQuery() {
        let rows = (0..<400).map { "row \($0) alpha beta" }
        XCTAssertEqual(scan(rows, "alpha beta").count, 400)
        XCTAssertEqual(scan(rows, "alpha betaX").count, 0, "narrowing to nothing leaves a carried guess of zero")
        XCTAssertGreaterThan(
            scan(rows, "a", expecting: 0).count, 400,
            "widening past the carried guess still answers in full",
        )
    }
}
