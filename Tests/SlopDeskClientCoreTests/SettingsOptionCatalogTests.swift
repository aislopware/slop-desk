// SettingsOptionCatalogTests — the one pin that could not cross to Rust.
//
// The lists themselves are `slopdesk_workspace::settings_catalog`: the labels, the captions, the order, the
// ladders' stops and their readouts are all pinned there, in the language they live in. None of that is
// restated here — a mirror fixture in a second language is two sources, which is the thing the port removed.
//
// EXHAUSTIVE COVERAGE stays. A card grid has no "…": an option missing from a group is simply INVISIBLE and
// unreachable, with nothing on screen hinting a choice exists. Rust cannot check that, because the set a group
// must cover is a SWIFT enum's `allCases` — the boundary sees only tokens, and a token no case parses is
// dropped by `SettingsCatalog.options(_:)`'s `compactMap` exactly as silently as a missing row. So every group
// is asserted here to round-trip to its enum, both ways:
//
//   * every case of the enum appears as a card (nothing unreachable), and
//   * every token the boundary sent parsed (nothing silently dropped — the count survives the `compactMap`).
//
// That second half is what catches a token renamed on one side only, which is the failure the port introduced
// and the only one it did.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

final class SettingsOptionCatalogTests: XCTestCase {
    // MARK: - Exhaustiveness (the regression that a card grid cannot show)

    func testCursorStyleCardsCoverEveryStyle() {
        assertRoundTrips(.cursorStyle, TerminalPreferences.CursorStyle.allCases, "cursor style")
    }

    /// The all-settings index prints the current cursor style beside the ✎ that jumps to the picker
    /// drawing this same group, so the two have to read the same word. They did not: the index went
    /// through a `CursorStyle.displayName` saying "Block (hollow)" while the catalog — and therefore
    /// the control — said "Hollow", one setting reading as two values a scroll apart on one page.
    /// The label is now only the catalog's, and this is the assertion that keeps it that way.
    func testEveryCursorStyleReadsAsTheLabelItsOwnPickerDraws() {
        let drawn = SettingsCatalog.options(.cursorStyle, as: TerminalPreferences.CursorStyle.self)
        XCTAssertFalse(drawn.isEmpty, "the group crossed empty, so the comparison below proves nothing")
        for option in drawn {
            XCTAssertEqual(
                SettingsCatalog.label(.cursorStyle, for: option.value.rawValue),
                option.label,
                "the index readout for \(option.value.rawValue) is not what its card says",
            )
        }
    }

    func testNewTabPositionCardsCoverEveryPosition() {
        assertRoundTrips(.newTabPosition, NewTabPosition.allCases, "new tab position")
    }

    func testOptionAsAltCardsCoverEveryMode() {
        assertRoundTrips(.optionAsAlt, OptionAsAlt.allCases, "option-as-alt")
    }

    func testRightClickCardsCoverEveryAction() {
        assertRoundTrips(.rightClickAction, RightClickAction.allCases, "right-click action")
    }

    func testOnLaunchCardsCoverEveryBehavior() {
        assertRoundTrips(.onLaunch, OnLaunchBehavior.allCases, "on-launch behaviour")
    }

    func testCloseConfirmationCardsCoverEveryPolicy() {
        assertRoundTrips(.closeConfirmation, CloseConfirmationPolicy.allCases, "close-confirmation policy")
    }

    /// The TAB row is the window row's shared PREFIX, not a second list: closing one tab loses exactly one
    /// tab, so `multipleTabs` can never fire there and offering it would be a control that does nothing.
    /// A prefix rather than a copy is what keeps the two rows' wording identical, so this pins the SUBSET
    /// relation instead of a coverage one — the only group that is deliberately not exhaustive.
    func testCloseConfirmationTabRowIsThePrefixWithoutMultipleTabs() {
        let tab = SettingsCatalog.options(.closeConfirmationTab, as: CloseConfirmationPolicy.self)
        let window = SettingsCatalog.options(.closeConfirmation, as: CloseConfirmationPolicy.self)
        XCTAssertFalse(tab.map(\.value).contains(.multipleTabs), "one tab can never be more than one tab")
        XCTAssertEqual(
            tab.map(\.value), Array(window.map(\.value).prefix(tab.count)),
            "the tab row must be the window row's prefix, so the shared choices read identically",
        )
        XCTAssertEqual(tab.map(\.label), Array(window.map(\.label).prefix(tab.count)))
    }

    #if os(macOS)
    func testWindowSizeCardsCoverEveryMode() {
        assertRoundTrips(.windowSize, WindowSizeMode.allCases, "window size mode")
    }

    func testDesktopPresentationCardsCoverEveryKind() {
        assertRoundTrips(.desktopPresentation, DesktopWindowPresentation.allCases, "desktop presentation")
    }
    #endif

    /// The pacer menu offers both REAL modes. The model field is optional and absent presents on
    /// arrival, so the list is the enum and not the enum plus a "Default" — a third item that set
    /// `arrival` would be a second way to pick it that nothing on screen tells apart. The absent
    /// state is `VideoPreferences.pacerDefault`'s job, which is the binding's, not the menu's.
    func testPacerMenuCoversBothModesAndOffersNoDefaultItem() {
        assertRoundTrips(.videoPacer, VideoPreferences.Pacer.allCases, "pacer mode")
    }

    /// Density is the one group with no enum behind it — the store persists the raw string — so it has no
    /// `allCases` to cover. What it has instead is two NAMED tokens, and the group must be exactly them:
    /// a picker writing a token the appearance applier does not know leaves the tier silently unapplied.
    func testDensityGroupIsExactlyItsTwoNamedTokens() {
        XCTAssertEqual(
            SettingsCatalog.stringOptions(.density).map(\.value),
            [SettingsCatalog.densityComfortable, SettingsCatalog.densityCompact],
        )
        XCTAssertFalse(SettingsCatalog.densityCompact.isEmpty, "the token crossed empty")
        XCTAssertNotEqual(SettingsCatalog.densityComfortable, SettingsCatalog.densityCompact)
    }

    // MARK: - The crossing

    /// `auto` and `end` produce the SAME insertion index today (`NewTabPosition.insertionIndex` returns
    /// `tabCount` for both), which is what the Automatic card's caption claims. The caption lives in Rust;
    /// the BEHAVIOUR it describes lives here, so this is the assertion that the claim is still true.
    func testAutomaticTabPositionDeclaresItsAlias() {
        let automatic = SettingsCatalog.options(.newTabPosition, as: NewTabPosition.self).first { $0.value == .auto }
        XCTAssertNotNil(automatic?.caption, "the alias caption must reach the card")
        XCTAssertEqual(
            NewTabPosition.auto.insertionIndex(activeTabIndex: 0, tabCount: 3),
            NewTabPosition.end.insertionIndex(activeTabIndex: 0, tabCount: 3),
            "the caption claims auto == end — if that stops being true, the caption is a lie",
        )
    }

    /// A menu row draws ``SettingsOption/menuLabel``, which is a CROSSED field. A door that answered zero
    /// bytes would silently blank every item in every dropdown, so the near side checks it arrived and that
    /// it is the label once a caveat is folded in.
    func testMenuLabelsCrossRatherThanBlanking() {
        for option in SettingsCatalog.options(.closeConfirmation, as: CloseConfirmationPolicy.self) {
            XCTAssertFalse(option.menuLabel.isEmpty, "a blank menu item for \(option.value)")
            XCTAssertTrue(
                option.menuLabel.hasPrefix(option.label),
                "the folded form starts with the label it folds into",
            )
            if option.caption == nil {
                XCTAssertEqual(option.menuLabel, option.label, "no caveat, no dangling dash")
            } else {
                XCTAssertNotEqual(option.menuLabel, option.label, "a caveat must survive into the dropdown")
            }
        }
    }

    /// A ladder's stops and its readout cross as a count plus indexed accessors, where an unknown index is a
    /// `NaN` the near side drops. That makes a slider with no chips, or a blank readout, a silent outcome —
    /// so the near side asserts the ladder arrived whole and that its stops can actually be reached.
    func testEveryLadderCrossesWithStopsInsideItsRange() {
        for ladder in SettingsCatalog.Ladder.allCases {
            let range = ladder.range
            XCTAssertLessThan(range.lowerBound, range.upperBound, "\(ladder) crossed with an empty range")
            XCTAssertGreaterThan(ladder.step, 0, "\(ladder) crossed with no granularity")
            XCTAssertFalse(ladder.presets.isEmpty, "\(ladder) crossed with no stops")
            for preset in ladder.presets {
                XCTAssertTrue(
                    range.contains(preset.value),
                    "\(ladder) preset \(preset.label) (\(preset.value)) is outside \(range)",
                )
                XCTAssertFalse(preset.label.isEmpty, "\(ladder) stop \(preset.value) crossed unlabelled")
            }
            XCTAssertFalse(ladder.readout(range.lowerBound).isEmpty, "\(ladder) reads as nothing at its floor")
            XCTAssertFalse(ladder.readout(range.upperBound).isEmpty, "\(ladder) reads as nothing at its ceiling")
        }
    }

    /// The apply-timing chip's two words are the boundary's; that they arrive, differ, and carry a glyph is
    /// the near side's concern — a blank chip is invisible rather than wrong-looking.
    func testTimingChipsCrossDistinctly() {
        let labels = SettingsCatalog.ApplyTiming.allCases.map(\.label)
        let symbols = SettingsCatalog.ApplyTiming.allCases.map(\.symbol)
        XCTAssertEqual(Set(labels).count, labels.count, "the two timings must read differently")
        XCTAssertEqual(Set(symbols).count, symbols.count, "the two timings must look different")
        XCTAssertFalse(labels.contains(where: \.isEmpty))
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }

    // MARK: - Helpers

    /// Assert a group round-trips to its enum: every case is offered, and every token the boundary sent
    /// parsed. The second half is the one the `compactMap` would otherwise swallow.
    private func assertRoundTrips<Value: RawRepresentable & Hashable & Sendable>(
        _ group: SettingsCatalog.Group,
        _ allCases: [Value],
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) where Value.RawValue == String {
        let parsed = SettingsCatalog.options(group, as: Value.self)
        XCTAssertEqual(
            Set(parsed.map(\.value)), Set(allCases),
            "every \(what) needs a card — an unlisted case is unreachable in a card grid",
            file: file, line: line,
        )
        XCTAssertEqual(
            parsed.count, SettingsCatalog.tokens(group).count,
            "a \(what) token the boundary sent did not parse — renamed on one side only",
            file: file, line: line,
        )
        XCTAssertEqual(
            parsed.count, Set(parsed.map(\.value)).count, "duplicate \(what) card", file: file, line: line,
        )
        for option in parsed {
            XCTAssertFalse(option.label.isEmpty, "\(what) \(option.value) crossed unlabelled", file: file, line: line)
        }
    }
}
#endif
