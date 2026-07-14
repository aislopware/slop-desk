import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - ViLineMotionTests (pure word/column motions in display cell columns)

/// Pins ``ViLineMotion`` — the horizontal half of the copy-mode cursor engine: vim small-word
/// steps (`w`/`b`/`e` + the row-wrap sentinels) and the column motions (`0`/`^`/`$`) over one row's
/// text, in DISPLAY CELL columns (wide glyphs advance 2). Pure string-in / column-out — no model,
/// no surface.
final class ViLineMotionTests: XCTestCase {
    // MARK: Column motions

    func testFirstNonBlankSkipsIndent() {
        XCTAssertEqual(ViLineMotion.firstNonBlank("    make check"), 4)
        XCTAssertEqual(ViLineMotion.firstNonBlank("make"), 0)
        XCTAssertEqual(ViLineMotion.firstNonBlank("    "), 0, "a blank row keeps column 0")
        XCTAssertEqual(ViLineMotion.firstNonBlank(""), 0)
    }

    func testLastNonBlankIsDollarTarget() {
        XCTAssertEqual(ViLineMotion.lastNonBlank("make check  "), 9, "$ lands ON the last glyph, not the padding")
        XCTAssertNil(ViLineMotion.lastNonBlank("   "), "a blank row has no $ target (the caller keeps col 0)")
    }

    // MARK: w — next word start (vim small-word: class change = new run)

    func testNextWordStartStepsWordsAndPunct() {
        // Columns:      0123456789
        let line = "foo(bar) baz"
        XCTAssertEqual(ViLineMotion.nextWordStart(line, from: 0), 3, "w from `foo` lands on `(` (class change)")
        XCTAssertEqual(ViLineMotion.nextWordStart(line, from: 3), 4, "w from `(` lands on `bar`")
        XCTAssertEqual(ViLineMotion.nextWordStart(line, from: 4), 7, "w from `bar` lands on `)`")
        XCTAssertEqual(ViLineMotion.nextWordStart(line, from: 7), 9, "w from `)` skips the space to `baz`")
        XCTAssertNil(ViLineMotion.nextWordStart(line, from: 9), "w off the last word wraps (nil sentinel)")
    }

    func testNextWordStartFromWhitespaceLandsOnNextRun() {
        XCTAssertEqual(ViLineMotion.nextWordStart("ab  cd", from: 2), 4, "w from the gap lands on the next word")
    }

    // MARK: b — previous word start

    func testPrevWordStartInsideRunGoesToItsStart() {
        XCTAssertEqual(ViLineMotion.prevWordStart("foo bar", from: 5), 4, "b inside `bar` lands on its start")
    }

    func testPrevWordStartAtRunStartGoesToPreviousRun() {
        let line = "foo(bar)"
        XCTAssertEqual(ViLineMotion.prevWordStart(line, from: 4), 3, "b at `bar`'s start lands on `(`")
        XCTAssertEqual(ViLineMotion.prevWordStart(line, from: 3), 0, "b at `(` lands on `foo`'s start")
        XCTAssertNil(ViLineMotion.prevWordStart(line, from: 0), "b at the row start wraps (nil sentinel)")
    }

    // MARK: e — word end

    func testWordEndStepsToRunEndsThenNextRun() {
        let line = "foo bar"
        XCTAssertEqual(ViLineMotion.wordEnd(line, from: 0), 2, "e inside `foo` lands on its end")
        XCTAssertEqual(ViLineMotion.wordEnd(line, from: 2), 6, "e AT `foo`'s end steps to `bar`'s end")
        XCTAssertNil(ViLineMotion.wordEnd(line, from: 6), "e off the last word wraps (nil sentinel)")
    }

    // MARK: Wrap landing helper

    func testLastWordStartForBackwardWrap() {
        XCTAssertEqual(ViLineMotion.lastWordStart("foo bar  "), 4, "the b-wrap lands on the previous row's last run")
        XCTAssertNil(ViLineMotion.lastWordStart("   "), "a blank row offers no run")
    }

    // MARK: Display-cell columns (wide glyphs advance 2 — the hint/underline width rules)

    func testWideGlyphsAdvanceTwoCells() {
        // 日(0-1) 本(2-3) space(4) a(5) b(6)
        let line = "日本 ab"
        XCTAssertEqual(ViLineMotion.nextWordStart(line, from: 0), 5, "w over a CJK word lands in CELL columns")
        XCTAssertEqual(ViLineMotion.lastNonBlank(line), 6)
        XCTAssertEqual(ViLineMotion.prevWordStart(line, from: 5), 0, "b from `ab` lands on the CJK run's start")
    }
}
