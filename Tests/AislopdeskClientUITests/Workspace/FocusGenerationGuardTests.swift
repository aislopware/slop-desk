import XCTest
@testable import AislopdeskClientUI

/// Pure, macOS-runnable tests for ``FocusGenerationGuard`` — the value-typed generation counter
/// that defeats the iOS first-responder race (docs/22 §7). No UIKit: the race logic is assertable
/// without a device, exactly like ``FloatingCursorMapping`` is.
///
/// Guard contract under test:
/// - The initial generation is `0` (a sentinel no real callback is issued under).
/// - `begin()` bumps the counter and returns the new current token (first call → `1`).
/// - `isCurrent(_:)` is `true` ONLY for the latest token; every earlier token — including a
///   pre-begin `0` — is stale and returns `false`.
/// - A rapid `begin()` sequence keeps only the latest token current; all prior ones are rejected
///   (this is precisely how a superseded async `becomeFirstResponder` callback gets dropped).
final class FocusGenerationGuardTests: XCTestCase {
    /// `begin()` increments monotonically and returns the new current token (1, 2, 3, …).
    func testBeginBumpsAndReturnsCurrent() {
        var guardState = FocusGenerationGuard()
        XCTAssertEqual(guardState.generation, 0, "initial generation is the 0 sentinel")

        XCTAssertEqual(guardState.begin(), 1, "first begin() → 1")
        XCTAssertEqual(guardState.generation, 1)
        XCTAssertEqual(guardState.begin(), 2, "second begin() → 2")
        XCTAssertEqual(guardState.begin(), 3, "third begin() → 3")
        XCTAssertEqual(guardState.generation, 3)
    }

    /// A token captured at an earlier generation is rejected once a newer `begin()` supersedes it —
    /// the core "drop the stale becomeFirstResponder callback" behaviour.
    func testEarlierTokenIsRejectedAfterNewerBegin() {
        var guardState = FocusGenerationGuard()
        let stale = guardState.begin() // generation 1, captured by an in-flight callback
        XCTAssertTrue(guardState.isCurrent(stale), "freshly minted token is current")

        let fresh = guardState.begin() // generation 2 — supersedes the in-flight one
        XCTAssertFalse(guardState.isCurrent(stale), "the older token is now stale → rejected")
        XCTAssertTrue(guardState.isCurrent(fresh), "only the latest token is current")
    }

    /// The 0 sentinel (a token from before any `begin()`) is never current.
    func testZeroSentinelIsNeverCurrent() {
        var guardState = FocusGenerationGuard()
        XCTAssertFalse(guardState.isCurrent(0), "the pre-begin 0 sentinel is never a current token")
        _ = guardState.begin()
        XCTAssertFalse(guardState.isCurrent(0), "…and still isn't after a begin()")
    }

    /// A rapid `begin()` burst (A→B→C→…) keeps ONLY the latest token current; every prior token is
    /// rejected. This is the multi-focus-change race: only the last-requested pane wins.
    func testRapidBeginSequenceKeepsOnlyLatestCurrent() throws {
        var guardState = FocusGenerationGuard()
        var tokens: [Int] = []
        for _ in 0..<10 { tokens.append(guardState.begin()) }

        let latest = try XCTUnwrap(tokens.last)
        XCTAssertTrue(guardState.isCurrent(latest), "the last token in the burst is current")
        for stale in tokens.dropLast() {
            XCTAssertFalse(guardState.isCurrent(stale), "every superseded token (\(stale)) is rejected")
        }
        XCTAssertEqual(tokens, Array(1...10), "tokens are strictly monotonic with no gaps")
    }

    /// Tokens are unique across the guard's lifetime, so a recycled callback can never masquerade
    /// as a fresh one.
    func testTokensAreUniqueAndMonotonic() {
        var guardState = FocusGenerationGuard()
        var seen = Set<Int>()
        var previous = 0
        for _ in 0..<100 {
            let token = guardState.begin()
            XCTAssertGreaterThan(token, previous, "strictly increasing")
            XCTAssertTrue(seen.insert(token).inserted, "no token is ever reused")
            previous = token
        }
    }
}
