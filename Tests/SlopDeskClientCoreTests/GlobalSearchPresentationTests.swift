// GlobalSearchPresentationTests — pins how a cross-tab hit is READ, below both platforms.
//
// The results surface is drawn twice (docs/56 stage D): an `NSPanel` on the Mac, a full card on the
// phone. Most of what the two share is copy, and copy drifts loudly. The one that drifts SILENTLY is
// ``GlobalSearchPresentation/excerptSlices(_:)``: it maps a UTF-16 highlight range back onto a Swift
// `String`, which can fail on a boundary inside a surrogate pair, and a half that re-derived the
// mapping would index out of bounds on exactly one line in a scrollback — the one with an emoji in
// it. So the emoji cases are here in full, not as an afterthought.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // PaneID / SessionID / TabID — a hit's coordinates
import XCTest
@testable import SlopDeskClientCore

final class GlobalSearchPresentationTests: XCTestCase {
    private func hit(_ excerpt: String, _ highlight: Range<Int>) -> GlobalSearchHit {
        GlobalSearchHit(
            paneID: PaneID(),
            sessionID: SessionID(),
            tabID: TabID(),
            line: 0,
            column: highlight.lowerBound,
            length: highlight.count,
            excerpt: excerpt,
            highlight: highlight,
        )
    }

    // MARK: - Cutting the excerpt

    /// The ordinary case, and the only property worth stating about it: the three runs re-join into
    /// the line they came from. A row draws them side by side, so a cut that lost or duplicated a
    /// character would show the user a line their scrollback does not contain.
    func testTheThreeRunsRejoinIntoTheLine() {
        let slices = GlobalSearchPresentation.excerptSlices(hit("make quick is green", 5..<10))
        XCTAssertEqual(slices.before, "make ")
        XCTAssertEqual(slices.match, "quick")
        XCTAssertEqual(slices.after, " is green")
        XCTAssertEqual(slices.before + slices.match + slices.after, "make quick is green")
    }

    /// A match at the very start and one at the very end each leave an EMPTY outer run rather than a
    /// missing one — an empty run marks nothing, which is what both halves need it to do.
    func testAMatchAtEitherEndLeavesAnEmptyRunNotAMissingOne() {
        let leading = GlobalSearchPresentation.excerptSlices(hit("error: boom", 0..<5))
        XCTAssertEqual(leading.before, "")
        XCTAssertEqual(leading.match, "error")

        let trailing = GlobalSearchPresentation.excerptSlices(hit("exit 1", 5..<6))
        XCTAssertEqual(trailing.match, "1")
        XCTAssertEqual(trailing.after, "")
    }

    /// An emoji BEFORE the match: the offsets are UTF-16, so the run starts two units later than a
    /// character count would say. Getting this wrong marks the wrong word rather than trapping,
    /// which is why it is pinned separately from the surrogate-straddle case below.
    func testAnEmojiBeforeTheMatchDoesNotShiftTheRun() {
        // "🐈 build failed" — the cat is 2 UTF-16 units, so "failed" starts at 9.
        let slices = GlobalSearchPresentation.excerptSlices(hit("🐈 build failed", 9..<15))
        XCTAssertEqual(slices.match, "failed")
        XCTAssertEqual(slices.before, "🐈 build ")
        XCTAssertEqual(slices.after, "")
    }

    /// A range that CUTS a surrogate pair in half has no character position, and the answer is the
    /// whole line in `before` — never a trap, never a guessed run. This is the case the whole file
    /// exists for.
    func testASurrogateStraddlingRangeDegradesToAFlatExcerpt() {
        let slices = GlobalSearchPresentation.excerptSlices(hit("🐈 build failed", 1..<7))
        XCTAssertEqual(slices.before, "🐈 build failed")
        XCTAssertEqual(slices.match, "")
        XCTAssertEqual(slices.after, "")
    }

    /// An out-of-bounds upper bound degrades the same way rather than reading past the excerpt. The
    /// controller clamps, so this is a belt on a brace — but the belt is what keeps a future
    /// controller change from being a crash in two frameworks at once.
    func testARangePastTheEndDegradesRatherThanReadingPastIt() {
        let slices = GlobalSearchPresentation.excerptSlices(hit("short", 2..<99))
        XCTAssertEqual(slices.before, "short")
        XCTAssertEqual(slices.match, "")
    }

    /// An EMPTY match — a zero-width range, which a regex like `^` produces — cuts cleanly at its
    /// point rather than degrading. Nothing is marked either way; what differs is that `before` and
    /// `after` still split, so a caret-anchored search does not make every row look flat.
    func testAZeroWidthMatchStillSplitsTheLine() {
        let slices = GlobalSearchPresentation.excerptSlices(hit("make quick", 4..<4))
        XCTAssertEqual(slices.before, "make")
        XCTAssertEqual(slices.match, "")
        XCTAssertEqual(slices.after, " quick")
    }

    // MARK: - The zero state

    /// Two lines, and the difference between them is the whole reason there are two: "no results"
    /// under an empty field would report a failure nobody asked for.
    func testTheZeroStateHintsBeforeTheQueryAndJudgesAfterIt() {
        XCTAssertEqual(
            GlobalSearchPresentation.emptyStateLine(query: ""), "Search every tab’s scrollback.",
        )
        XCTAssertEqual(GlobalSearchPresentation.emptyStateLine(query: "boom"), "No results.")
    }

    /// Whitespace is not a query. A space-only field is still the BEFORE state — the search it would
    /// run has not been asked for.
    func testAWhitespaceOnlyQueryIsStillTheBeforeState() {
        XCTAssertEqual(
            GlobalSearchPresentation.emptyStateLine(query: "   "), "Search every tab’s scrollback.",
        )
    }

    // MARK: - The summary line

    /// The count is gated on the QUERY, not on the results: a cleared field over a stale result set
    /// must not go on printing a count for a search the user has abandoned.
    func testTheSummaryIsGatedOnTheQueryNotOnTheResults() {
        let results = GlobalSearchResults(groups: [], totalMatches: 4, tabCount: 3)
        XCTAssertEqual(GlobalSearchPresentation.summary(results, query: "boom"), "4 results — 3 tabs")
        XCTAssertNil(GlobalSearchPresentation.summary(results, query: ""))
        XCTAssertNil(GlobalSearchPresentation.summary(results, query: "  "))
        XCTAssertNil(GlobalSearchPresentation.summary(nil, query: "boom"))
    }

    // MARK: - The mode pills

    /// The cross-tab search offers two of the find bar's three, in the find bar's own order. Whole
    /// word is missing on purpose: this search runs over the scrollback mirror rather than over
    /// libghostty's buffer, and the two do not agree about where a word ends.
    func testTheCrossTabSearchOffersTwoOfTheThreePills() {
        XCTAssertEqual(FindModePill.globalSearch, [.caseSensitive, .regex])
        XCTAssertFalse(FindModePill.globalSearch.contains(.wholeWord))
    }

    /// The underline is the whole-word chip's own mark and nothing else's — the property both the
    /// SwiftUI pill and the `NSAttributedString` one read instead of each deciding.
    func testOnlyTheWholeWordChipIsUnderlined() {
        XCTAssertEqual(FindModePill.allCases.filter(\.underlined), [.wholeWord])
    }

    /// Every chip has a distinct glyph and a distinct help string — three surfaces draw these, and
    /// two chips that read alike would be a control the user cannot tell apart on any of them.
    func testEveryChipIsDistinctInBothGlyphAndHelp() {
        XCTAssertEqual(Set(FindModePill.allCases.map(\.label)).count, FindModePill.allCases.count)
        XCTAssertEqual(Set(FindModePill.allCases.map(\.help)).count, FindModePill.allCases.count)
    }
}
