// PaneStatusPillPresentationTests — which pane status chips are up, in what order, and what each one is.
//
// The ORDERED VISIBILITY LIST is the part that could not be tested before: the four gates and the
// top-down stacking lived inside `TerminalLeafView`'s body, where asking "does secure input hide under
// read-only?" meant mounting a leaf, a store and a terminal model. As a list over a value it is six
// booleans in and an array out.
//
// The asymmetry is the invariant worth pinning hardest. Two of the three chips step aside for a mode
// above them and the third steps aside for nothing, because sync input warns about a leak coming FROM
// this pane's siblings rather than about this pane's own gate — a "tidy" gate added to it would hide the
// one chip whose absence a user cannot explain.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

final class PaneStatusPillPresentationTests: XCTestCase {
    // MARK: - The list

    /// Nothing armed, nothing drawn — and the vi pill is not owed either.
    func testQuietPaneShowsNothing() {
        let quiet = PaneStatusConditions()
        XCTAssertEqual(PaneStatusPillPresentation.visible(quiet), [])
        XCTAssertFalse(PaneStatusPillPresentation.showsViModePill(quiet))
    }

    /// All three armed at once stack read-only, secure input, sync input — top-down, with the ungated
    /// safety chip last so an arriving or leaving chip never makes it jump.
    func testEveryChipStacksInOrder() {
        let loud = PaneStatusConditions(
            readOnly: false, secureInput: true, secureInputIndicator: true, syncInput: true,
        )
        XCTAssertEqual(PaneStatusPillPresentation.visible(loud), [.secureInput, .syncInput])

        // Read-only and secure input are mutually exclusive by rule, so "all three" is really
        // read-only + sync, or secure + sync.
        let locked = PaneStatusConditions(
            readOnly: true, secureInput: true, secureInputIndicator: true, syncInput: true,
        )
        XCTAssertEqual(PaneStatusPillPresentation.visible(locked), [.readOnly, .syncInput])
    }

    /// Copy mode takes the read-only chip away — its keybindings drive a selection rather than the shell,
    /// so the lock is not what the user is being told about. The lock itself is untouched, which is why
    /// the same conditions with `copyMode` cleared bring it straight back.
    func testCopyModeHidesTheReadOnlyChip() {
        var conditions = PaneStatusConditions(readOnly: true, copyMode: true)
        XCTAssertEqual(PaneStatusPillPresentation.visible(conditions), [])
        conditions.copyMode = false
        XCTAssertEqual(PaneStatusPillPresentation.visible(conditions), [.readOnly])
    }

    /// Read-only takes the secure-input chip away: no input path can fire there, so the cue is moot.
    func testReadOnlyHidesTheSecureInputChip() {
        let conditions = PaneStatusConditions(
            readOnly: true, secureInput: true, secureInputIndicator: true,
        )
        XCTAssertEqual(PaneStatusPillPresentation.visible(conditions), [.readOnly])
    }

    /// The INDICATOR setting is a second gate on the secure-input chip, not a synonym for the state:
    /// turning the setting off must hide the chip while secure entry stays on.
    func testSecureInputNeedsBothTheStateAndTheIndicator() {
        var conditions = PaneStatusConditions(secureInput: true, secureInputIndicator: true)
        XCTAssertEqual(PaneStatusPillPresentation.visible(conditions), [.secureInput])
        conditions.secureInputIndicator = false
        XCTAssertEqual(PaneStatusPillPresentation.visible(conditions), [])
    }

    /// SYNC INPUT STEPS ASIDE FOR NOTHING. The mode leaks into this pane from its siblings regardless of
    /// this pane's own gates, so every combination that hides the other two keeps this one up.
    func testSyncInputSurvivesEveryOtherMode() {
        for readOnly in [false, true] {
            for copyMode in [false, true] {
                for hintMode in [false, true] {
                    let conditions = PaneStatusConditions(
                        readOnly: readOnly, copyMode: copyMode, hintMode: hintMode, syncInput: true,
                    )
                    XCTAssertTrue(
                        PaneStatusPillPresentation.visible(conditions).contains(.syncInput),
                        "sync input hidden by readOnly=\(readOnly) copyMode=\(copyMode) hintMode=\(hintMode)",
                    )
                }
            }
        }
    }

    // MARK: - The vi slot

    /// One corner, one mode chip: the `HINTS` badge owns the same top-trailing region from another
    /// overlay, so the vi pill yields to it and returns the instant hints cancel.
    func testViPillYieldsToHintMode() {
        var conditions = PaneStatusConditions(copyMode: true)
        XCTAssertTrue(PaneStatusPillPresentation.showsViModePill(conditions))
        conditions.hintMode = true
        XCTAssertFalse(PaneStatusPillPresentation.showsViModePill(conditions))
    }

    /// The vi pill and the read-only chip can never both be up — the one gate is the mirror of the other.
    func testViPillAndReadOnlyChipAreMutuallyExclusive() {
        let conditions = PaneStatusConditions(readOnly: true, copyMode: true)
        XCTAssertTrue(PaneStatusPillPresentation.showsViModePill(conditions))
        XCTAssertFalse(PaneStatusPillPresentation.visible(conditions).contains(.readOnly))
    }

    /// The key-hint card needs BOTH vi mode and the per-session `⌘/` toggle — the copy-mode leg makes
    /// teardown unconditional, so the card can never linger after vi mode exits.
    func testKeyHintCardNeedsViModeAndTheToggle() {
        let inVi = PaneStatusConditions(copyMode: true)
        XCTAssertTrue(PaneStatusPillPresentation.showsViKeyHintBar(inVi, hintsToggled: true))
        XCTAssertFalse(PaneStatusPillPresentation.showsViKeyHintBar(inVi, hintsToggled: false))
        XCTAssertFalse(
            PaneStatusPillPresentation.showsViKeyHintBar(PaneStatusConditions(), hintsToggled: true),
        )
    }

    // MARK: - What a chip is

    /// Only secure input has no `×`, and that is a decision: it is a safety indicator the user does not
    /// dismiss with a click, so a `×` would offer to turn off something the chip does not own.
    func testOnlySecureInputHasNoDismiss() {
        XCTAssertTrue(PaneStatusPill.readOnly.isDismissible)
        XCTAssertFalse(PaneStatusPill.secureInput.isDismissible)
        XCTAssertTrue(PaneStatusPill.syncInput.isDismissible)
        XCTAssertNil(PaneStatusPill.secureInput.dismissHelp)
    }

    /// The two LOUD chips wear a fixed, theme-independent tone and the quiet one wears the chrome plate.
    /// This is the invariant the `fillColor` escape hatches existed for, said once: a chip re-routed onto
    /// the palette would be invisible against the accent on every shipped theme (`info == accent`).
    func testFillKindsSplitTheQuietChipFromTheLoudOnes() {
        XCTAssertEqual(PaneStatusPill.readOnly.fill, .chrome)
        XCTAssertEqual(PaneStatusPill.secureInput.fill, .fixed(.security))
        XCTAssertEqual(PaneStatusPill.syncInput.fill, .fixed(.sync))
    }

    /// Every chip says something, is spoken as something, and explains itself — three strings, none of
    /// them empty and none of them the same as another chip's.
    func testEveryChipCarriesItsWholeVocabulary() {
        let labels = PaneStatusPill.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, PaneStatusPill.allCases.count, "two chips share a label")
        for pill in PaneStatusPill.allCases {
            XCTAssertFalse(pill.label.isEmpty)
            XCTAssertFalse(pill.accessibilityLabel.isEmpty)
            XCTAssertFalse(pill.accessibilityHint.isEmpty)
        }
    }
}
