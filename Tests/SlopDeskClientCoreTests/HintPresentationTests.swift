// HintPresentationTests — the Hint Mode overlay's four decisions and its words.
//
// The per-letter FADE is the one that hides. `offset < typed.count` and any plausible re-derivation agree
// on the common case (nothing typed, nothing faded) and part company only once a letter is in — which is
// exactly the half-second the cue exists for.
//
// The ARM predicate's third leg is the honest ceiling, not a guard: a headless surface reports no cell
// metrics, and the answer to that is to draw NOTHING. A badge placed at a guessed cell size would point
// at the wrong word, which is worse than an absent label in a way no screenshot would reveal.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

final class HintPresentationTests: XCTestCase {
    // MARK: - Is it up?

    /// All three legs are required, and the two geometry ones are required SEPARATELY — a surface that
    /// reported a width and no height would otherwise draw a row of zero-height badges.
    func testArmedNeedsAnIntentAndRealCellGeometry() {
        XCTAssertTrue(HintPresentation.isArmed(intent: .open, cellWidth: 7, cellHeight: 15))
        XCTAssertFalse(HintPresentation.isArmed(intent: nil, cellWidth: 7, cellHeight: 15))
        XCTAssertFalse(HintPresentation.isArmed(intent: .open, cellWidth: 0, cellHeight: 15))
        XCTAssertFalse(HintPresentation.isArmed(intent: .open, cellWidth: 7, cellHeight: 0))
    }

    // MARK: - Reading a label

    /// Labels are assigned lowercase and always DRAWN uppercase — a two-letter badge over terminal
    /// output has to be read at a glance.
    func testLabelsAreDrawnUppercase() {
        XCTAssertEqual(HintPresentation.displayLabel("as"), "AS")
        XCTAssertEqual(HintPresentation.displayLabel("AS"), "AS")
    }

    /// The already-typed prefix draws faded; the rest does not. Nothing typed ⇒ nothing faded, which is
    /// the case every re-derivation gets right.
    func testFadeCoversExactlyTheTypedPrefix() {
        XCTAssertFalse(HintPresentation.isFaded(offset: 0, typed: ""))
        XCTAssertTrue(HintPresentation.isFaded(offset: 0, typed: "a"))
        XCTAssertFalse(HintPresentation.isFaded(offset: 1, typed: "a"))
        XCTAssertTrue(HintPresentation.isFaded(offset: 1, typed: "as"))
    }

    /// A typed first letter dims the labels it rules out and leaves the rest alone — and dims RATHER THAN
    /// REMOVES, so the field the eye is scanning stays where it was.
    func testTypedPrefixDimsTheRuledOutLabels() {
        let labels = ["as", "ad", "sa"]
        let matched = HintPresentation.matchedLabels(typed: "a", labels: labels)
        XCTAssertFalse(HintPresentation.dimmed(label: "as", matched: matched))
        XCTAssertFalse(HintPresentation.dimmed(label: "ad", matched: matched))
        XCTAssertTrue(HintPresentation.dimmed(label: "sa", matched: matched))
    }

    /// Before anything is typed, NO badge is dimmed — the empty prefix admits every label.
    func testNothingIsDimmedBeforeAnythingIsTyped() {
        let labels = ["as", "ad", "sa"]
        let matched = HintPresentation.matchedLabels(typed: "", labels: labels)
        for label in labels {
            XCTAssertFalse(HintPresentation.dimmed(label: label, matched: matched))
        }
    }

    /// The prefix is matched case-insensitively — a user with caps lock on is still hinting.
    func testPrefixMatchingIgnoresCase() {
        let matched = HintPresentation.matchedLabels(typed: "A", labels: ["as", "sa"])
        XCTAssertFalse(HintPresentation.dimmed(label: "as", matched: matched))
        XCTAssertTrue(HintPresentation.dimmed(label: "sa", matched: matched))
    }

    // MARK: - The words

    /// One word per intent, and the a11y label is that word in a sentence — so the badge and VoiceOver
    /// can never name different modes.
    func testEveryIntentIsNamedOnceAndSpokenTheSameWay() {
        XCTAssertEqual(HintIntent.open.badgeLabel, "OPEN")
        XCTAssertEqual(HintIntent.copy.badgeLabel, "COPY")
        XCTAssertEqual(HintIntent.reveal.badgeLabel, "REVEAL")
        for intent in [HintIntent.open, .copy, .reveal] {
            XCTAssertEqual(
                HintPresentation.badgeAccessibilityLabel(intent),
                "Hint mode \(intent.badgeLabel)",
            )
        }
    }

    /// A badge is spoken by its DRAWN label, uppercase — VoiceOver and the eye read the same two letters.
    func testBadgeIsSpokenByItsDrawnLabel() {
        XCTAssertEqual(HintPresentation.labelAccessibility("as"), "Hint AS")
    }
}
