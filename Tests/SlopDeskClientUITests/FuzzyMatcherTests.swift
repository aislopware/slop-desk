// FuzzyMatcherTests — golden pins for the vendored fzf `FuzzyMatchV2` port (`FuzzyMatcher`). Two kinds of
// assertions, both INDEPENDENT of the implementation (not tautological):
//
//   1. EXACT scores hand-derived from fzf's published constants (scoreMatch 16, bonusBoundaryWhite 10,
//      bonusBoundaryDelimiter 9, bonusBoundary 8, bonusFirstCharMultiplier 2, scoreGapStart -3,
//      bonusConsecutive logic) — if the matcher disagrees, the matcher (or a constant) is wrong.
//   2. ORDERING properties lifted straight from fzf's own algo.go doc comment (the "fuzzy-finder" vs
//      "fuzzyfinder", "foobar" vs "foo-bar", "fo-bar" vs "foob-r" examples) — these are the SPEC, and a
//      naive contains/prefix scorer (the one this replaced) would tie them, so the tests discriminate.
//
// Live ranking/throughput parity against the REAL `fzf` binary is proven separately by
// `slopdesk-fuzzybench` (match-set identical 16/16 queries; 0 strict score inversions over fzf's order).

import XCTest
@testable import SlopDeskClientUI

final class FuzzyMatcherTests: XCTestCase {
    private func score(_ q: String, _ c: String) -> Int? { FuzzyMatcher.score(q, c)?.score }

    // MARK: Exact single-char scores — pins the position bonus table + first-char multiplier

    func testFirstCharBoundaryBonuses() {
        // M==1 score = scoreMatch(16) + positionBonus * bonusFirstCharMultiplier(2).
        XCTAssertEqual(score("a", "a"), 36) // start-of-string ⇒ bonusBoundaryWhite 10 → 16 + 20
        XCTAssertEqual(score("a", " a"), 36) // after whitespace ⇒ bonusBoundaryWhite 10
        XCTAssertEqual(score("a", "/a"), 34) // after delimiter '/' ⇒ bonusBoundaryDelimiter 9 → 16 + 18
        XCTAssertEqual(score("a", "-a"), 32) // after non-word '-' ⇒ bonusBoundary 8 → 16 + 16
        XCTAssertEqual(score("a", "ba"), 16) // mid-word (b→a, no boundary) ⇒ bonus 0 → 16 + 0
    }

    // MARK: Non-word first char — fzf gates the word-boundary bonus on `class > charNonWord` (STRICT)

    func testNonWordFirstCharDoesNotGetBoundaryBonus() {
        // A NON-word matched char (e.g. '-') is NOT a word boundary in fzf: whatever precedes it, it earns
        // `bonusNonWord` (8), NEVER the after-whitespace (10) / after-delimiter (9) boundary bonuses.
        // M==1 score = scoreMatch(16) + positionBonus * bonusFirstCharMultiplier(2).
        // Un-fixed (`>=`): " -" scored 16 + 10*2 = 36 and ":-" 16 + 9*2 = 34.
        XCTAssertEqual(score("-", " -"), 32) // after whitespace ⇒ bonusNonWord 8 → 16 + 16 (NOT 36)
        XCTAssertEqual(score("-", ":-"), 32) // after delimiter ':' ⇒ bonusNonWord 8 → 16 + 16 (NOT 34)
        XCTAssertEqual(score("-", "a-"), 32) // mid-word non-word ⇒ bonusNonWord 8 → 16 + 16
        XCTAssertEqual(score("-", "-"), 32) // start-of-string non-word ⇒ bonusNonWord 8 (prev==white default)
    }

    // MARK: Exact multi-char score — pins the Smith-Waterman DP + consecutive-chunk bonus

    func testConsecutiveChunkExactScore() {
        // "ab" on "ab": match 'a' at start (16 + 10*2 = 36), then consecutive 'b' adds scoreMatch(16)
        // plus the chunk's first-char bonus (10) carried forward by the consecutive rule ⇒ 36 + 26 = 62.
        XCTAssertEqual(score("ab", "ab"), 62)
    }

    // MARK: Backtrace positions / ranges

    func testMatchedPositions() {
        // "fz" on "fuzzy": f@0, the leftmost optimal z@2. Score 49 (hand-traced through the DP).
        let m = FuzzyMatcher.match(pattern: ["f", "z"], in: Array("fuzzy".unicodeScalars), caseSensitive: false)
        XCTAssertEqual(m?.score, 49)
        XCTAssertEqual(m?.positions, [0, 2])
    }

    func testRangesHighlightOriginalCandidate() {
        // Ranges map onto the ORIGINAL (case-bearing) candidate so the palette can highlight matched chars.
        let candidate = "FuzzyMatcher"
        guard let ranges = FuzzyMatcher.score("fm", candidate)?.ranges else {
            XCTFail("expected a match for 'fm' in 'FuzzyMatcher'")
            return
        }
        let matched = ranges.map { String(candidate[$0]) }
        XCTAssertEqual(matched, ["F", "M"]) // F@0 (boundary, first char) + M@5 (camelCase hump)
    }

    // MARK: Ordering properties straight from fzf's algo.go documentation

    func testPrefersWordBoundaryOverPackedRun() {
        // algo.go: "fuzzyfinder" vs "fuzzy-finder" on "ff" → the boundary match wins.
        XCTAssertGreaterThan(score("ff", "fuzzy-finder") ?? .min, score("ff", "fuzzyfinder") ?? .min)
    }

    func testConsecutiveChunkBeatsBoundaryGap() {
        // algo.go: "foobar" vs "foo-bar" on "foob" → after the consecutive bonus, the packed run wins.
        XCTAssertGreaterThan(score("foob", "foobar") ?? .min, score("foob", "foo-bar") ?? .min)
    }

    func testFirstCharAtBoundaryWins() {
        // algo.go: "fo-bar" vs "foob-r" on "br" → first pattern char at a boundary is worth more.
        XCTAssertGreaterThan(score("br", "fo-bar") ?? .min, score("br", "foob-r") ?? .min)
    }

    func testCamelCaseBeatsMidWordGap() {
        // "gc": getConfig (g at start + C camelCase hump, tight) outranks gymnastic (g at start, far gap).
        XCTAssertGreaterThan(score("gc", "getConfig") ?? .min, score("gc", "gymnastic") ?? .min)
    }

    // MARK: Smith-Waterman correctness — order matters, omission forbidden

    func testNoMatchWhenCharsMissing() {
        XCTAssertNil(score("xyz", "getConfig"))
        XCTAssertNil(score("zx", "xyz")) // out of order: z then x, but x precedes z
        XCTAssertNil(score("abc", "ab")) // pattern longer than candidate
    }

    func testInOrderSubsequenceMatches() {
        XCTAssertNotNil(score("xz", "xyz")) // x@0, z@2 in order
    }

    // MARK: Smart case (fzf rule: case-sensitive iff the query has an uppercase char)

    func testSmartCase() {
        XCTAssertNotNil(score("gc", "getConfig")) // lowercase query ⇒ case-insensitive
        XCTAssertNil(score("GC", "getConfig")) // uppercase query ⇒ case-sensitive, no capital G/C present
        XCTAssertNotNil(score("GC", "GetConfig")) // case-sensitive match
    }

    // MARK: Empty query is a match-all with score 0 (zero-state path keeps source order)

    func testEmptyQueryMatchesEverything() {
        let r = FuzzyMatcher.score("", "anything")
        XCTAssertEqual(r?.score, 0)
        XCTAssertEqual(r?.ranges.count, 0)
        XCTAssertEqual(FuzzyMatcher.score("   ", "anything")?.score, 0) // whitespace-only trims to empty
    }
}
