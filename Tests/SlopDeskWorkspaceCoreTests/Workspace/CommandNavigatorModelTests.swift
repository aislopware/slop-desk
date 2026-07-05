import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// E10 WI-10 (G8): the pure Command Navigator filter (⌃⌘O). These pin the FILTER contract — an injected
/// scorer drops non-matches AND still-forming (empty-command) blocks, orders survivors by score descending
/// with a STABLE tie-break that keeps the caller's newest-first order, and an empty query returns the list
/// unchanged — plus the ⌃⌘O binding the WI reuses (presence + collision-freedom).
///
/// Each assertion is revert-to-confirm-fail: it fails on a filter that forgets to drop a non-match, emits a
/// row for an empty (still-forming) command when querying, mis-orders by score, or breaks a score tie out of
/// newest-first order. The tests pull NO view-module `FuzzyMatcher` (a deterministic stand-in scorer), so
/// they run headless.
final class CommandNavigatorModelTests: XCTestCase {
    // MARK: - Fixtures

    private func block(_ index: UInt32, _ command: String, exit: Int32? = 0, complete: Bool = true) -> CommandBlock {
        CommandBlock(
            index: index,
            commandText: command,
            exitCode: exit,
            durationMS: 5,
            complete: complete,
            outputLen: 0,
        )
    }

    /// A deterministic, fzf-shaped stand-in scorer (the SAME shape `JumpToModelTests` uses): `nil` unless
    /// every query character appears in order (subsequence), else a score that rewards an EARLIER first match
    /// (so a closer-to-front match ranks higher). Exercises the filter+order contract without the view module.
    private func subsequenceScore(_ query: String, _ haystack: String) -> Int? {
        let h = Array(haystack.lowercased())
        var hi = 0
        var firstMatch: Int?
        for qc in query.lowercased() {
            var found = false
            while hi < h.count {
                if h[hi] == qc {
                    if firstMatch == nil { firstMatch = hi }
                    hi += 1
                    found = true
                    break
                }
                hi += 1
            }
            if !found { return nil }
        }
        return 1000 - (firstMatch ?? 0)
    }

    // MARK: - Filter / fuzzy ordering

    func testFilteredDropsNonMatchesAndOrdersByScore() {
        let blocks = [
            block(3, "git status"), // "gs": g@0 (front → higher score)
            block(2, "regis status"), // "gs": g@3 (later → lower score)
            block(1, "ls"), // no "g" → dropped
        ]
        let filtered = CommandNavigatorModel.filtered(blocks, query: "gs", score: subsequenceScore)
        XCTAssertEqual(
            filtered.map(\.commandText), ["git status", "regis status"],
            "drops the non-matching 'ls'; the front-loaded match ranks first",
        )
    }

    func testFilteredEmptyQueryReturnsAllUnchanged() {
        let blocks = [block(2, "make build"), block(1, "echo hi")]
        let filtered = CommandNavigatorModel.filtered(blocks, query: "   ", score: subsequenceScore)
        XCTAssertEqual(filtered, blocks, "a blank query is the zero-state — every block, caller order (newest-first)")
    }

    func testFilteredStableTieBreakKeepsNewestFirstOrder() {
        // Two rows whose first-match position is identical (score ties) must keep the caller's newest-first
        // order (index 2 before index 1).
        let blocks = [block(2, "abc one"), block(1, "abc two")]
        let filtered = CommandNavigatorModel.filtered(blocks, query: "abc", score: subsequenceScore)
        XCTAssertEqual(
            filtered.map(\.commandText), ["abc one", "abc two"],
            "equal scores keep the caller's newest-first order",
        )
    }

    func testFilteredSkipsEmptyCommandBlocksWhenQuerying() {
        // A still-forming block (empty commandText) can never match a real query → never a row under a query.
        let blocks = [block(2, "make build"), block(3, "", complete: false)]
        let filtered = CommandNavigatorModel.filtered(blocks, query: "make", score: subsequenceScore)
        XCTAssertEqual(filtered.map(\.commandText), ["make build"], "the empty (still-forming) block is dropped")
    }

    // MARK: - ⌃⌘O binding (reused, not new — pin presence + collision-freedom)

    func testCommandNavigatorChordIsRegisteredAndUnique() {
        let chord = KeyChord(character: "o", [.control, .command])
        XCTAssertEqual(WorkspaceBindingRegistry.chordTable[chord], .commandNavigator, "⌃⌘O maps to .commandNavigator")

        let binding = WorkspaceBindingRegistry.allBindings.first { $0.id == "view.commandNavigator" }
        XCTAssertNotNil(binding, "binding 'view.commandNavigator' must exist")
        XCTAssertEqual(binding?.action, .commandNavigator)

        let chords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "⌃⌘O leaves the chord table collision-free")
    }
}
