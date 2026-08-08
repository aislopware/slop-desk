// SettingsOptionCatalogTests — the anti-drift pin for the illustrated card groups.
//
// The card groups replaced `.menu` `Picker`s whose choices lived as inline `Text("…").tag(…)` children. That
// move buys a real invariant a dropdown never had, and this file enforces it:
//
//   EXHAUSTIVE COVERAGE. A card grid has no "…" — an option missing from a `SettingsOptionCatalog` list is
//   simply INVISIBLE and unreachable, with nothing on screen hinting that a choice exists. So every list is
//   asserted to cover its enum's `allCases` exactly. Adding a `RightClickAction` / `CursorStyle` /
//   `WindowSizeMode` case without adding its card fails here rather than shipping a setting no user can pick.
//
// Labels are pinned against an INDEPENDENT hand-written table (not the catalog's own derivation), the same
// contract `SettingsSectionTaxonomyTests` holds for the section list.
//
// The scalar ladders are pinned for the properties that would break the control silently: preset stops must
// lie INSIDE the slider's range (an out-of-range stop is a chip that can never light), and each readout is
// checked at its edges — `Instant` at zero is a behaviour word, not a rounded `0.0s`.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientUI

final class SettingsOptionCatalogTests: XCTestCase {
    // MARK: - Exhaustiveness (the regression that a card grid cannot show)

    func testCursorStyleCardsCoverEveryStyle() {
        assertCoversAllCases(
            SettingsOptionCatalog.cursorStyles.map(\.value),
            TerminalPreferences.CursorStyle.allCases,
            "cursor style",
        )
    }

    func testNewTabPositionCardsCoverEveryPosition() {
        assertCoversAllCases(
            SettingsOptionCatalog.newTabPositions.map(\.value),
            NewTabPosition.allCases,
            "new tab position",
        )
    }

    func testOptionAsAltCardsCoverEveryMode() {
        assertCoversAllCases(
            SettingsOptionCatalog.optionAsAlt.map(\.value),
            OptionAsAlt.allCases,
            "option-as-alt",
        )
    }

    func testRightClickCardsCoverEveryAction() {
        assertCoversAllCases(
            SettingsOptionCatalog.rightClickActions.map(\.value),
            RightClickAction.allCases,
            "right-click action",
        )
    }

    func testOnLaunchCardsCoverEveryBehavior() {
        assertCoversAllCases(
            SettingsOptionCatalog.onLaunch.map(\.value),
            OnLaunchBehavior.allCases,
            "on-launch behaviour",
        )
    }

    func testCloseConfirmationCardsCoverEveryPolicy() {
        assertCoversAllCases(
            SettingsOptionCatalog.closeConfirmation.map(\.value),
            CloseConfirmationPolicy.allCases,
            "close-confirmation policy",
        )
    }

    #if os(macOS)
    func testWindowSizeCardsCoverEveryMode() {
        assertCoversAllCases(
            SettingsOptionCatalog.windowSizes.map(\.value),
            WindowSizeMode.allCases,
            "window size mode",
        )
    }

    func testDesktopPresentationCardsCoverEveryKind() {
        assertCoversAllCases(
            SettingsOptionCatalog.desktopPresentations.map(\.value),
            DesktopWindowPresentation.allCases,
            "desktop presentation",
        )
    }
    #endif

    // MARK: - Labels (independent table)

    /// Card labels are SHORT — a card is ~96pt wide, so "Left Option Only" becomes "Left only" with the full
    /// sentence living in the group subtitle. Pinned so a re-word can't quietly overflow the cards.
    func testCardLabelsArePinned() {
        XCTAssertEqual(SettingsOptionCatalog.cursorStyles.map(\.label), ["Block", "Hollow", "Bar", "Underline"])
        XCTAssertEqual(SettingsOptionCatalog.optionAsAlt.map(\.label), ["Off", "Both", "Left only", "Right only"])
        XCTAssertEqual(
            SettingsOptionCatalog.rightClickActions.map(\.label),
            ["Context menu", "Copy", "Paste", "Copy or paste", "Ignore"],
        )
        XCTAssertEqual(
            SettingsOptionCatalog.newTabPositions.map(\.label),
            ["Automatic", "End", "After current"],
        )
    }

    /// `auto` and `end` produce the SAME insertion index today (`NewTabPosition.insertionIndex` returns
    /// `tabCount` for both), so the Automatic card must SAY so rather than implying a distinct behaviour its
    /// diagram can't show. This asserts the alias both ways: the caption exists, and the two really do agree.
    func testAutomaticTabPositionDeclaresItsAlias() {
        let automatic = SettingsOptionCatalog.newTabPositions.first { $0.value == .auto }
        XCTAssertEqual(automatic?.caption, "Appends, like End")
        XCTAssertEqual(
            NewTabPosition.auto.insertionIndex(activeTabIndex: 0, tabCount: 3),
            NewTabPosition.end.insertionIndex(activeTabIndex: 0, tabCount: 3),
            "the caption claims auto == end — if that stops being true, the caption is a lie",
        )
    }

    /// The density values are the raw strings the store persists. A typo here writes a token the appearance
    /// applier doesn't know, so the tier silently never applies.
    func testDensityValuesAreThePersistedTokens() {
        XCTAssertEqual(SettingsOptionCatalog.densities.map(\.value), ["comfortable", "compact"])
        XCTAssertEqual(SettingsOptionCatalog.densityComfortable, "comfortable")
        XCTAssertEqual(SettingsOptionCatalog.densityCompact, "compact")
    }

    /// A menu item has no second line, so ``SettingsOption/menuLabel`` folds the caption in after an en dash
    /// — otherwise the honesty a caption carries (`auto` IS `end`; "Running process" means "only if busy")
    /// would simply vanish when a group renders as a dropdown instead of as cards.
    func testMenuLabelFoldsTheCaptionIn() {
        let auto = SettingsOptionCatalog.newTabPositions.first { $0.value == .auto }
        XCTAssertEqual(auto?.menuLabel, "Automatic — Appends, like End")
        let process = SettingsOptionCatalog.closeConfirmation.first { $0.value == .process }
        XCTAssertEqual(process?.menuLabel, "Running process — only if busy")
        // No caption ⇒ the label alone, with no dangling dash.
        let always = SettingsOptionCatalog.closeConfirmation.first { $0.value == .always }
        XCTAssertEqual(always?.menuLabel, "Always")
    }

    // MARK: - Scalar ladders

    /// A preset outside the slider's own range is a chip that can never light (and, when tapped, writes a
    /// value the slider immediately clamps away).
    func testEveryPresetStopLiesInsideItsRange() {
        assertPresetsInRange(SettingsScrollbackLadder.presets, SettingsScrollbackLadder.range, "scrollback")
        assertPresetsInRange(
            SettingsScrollMultiplierLadder.presets, SettingsScrollMultiplierLadder.range, "scroll multiplier",
        )
        assertPresetsInRange(SettingsBusyDelayLadder.presets, SettingsBusyDelayLadder.range, "busy delay")
    }

    /// The scrollback range + step are the values the old `Stepper` carried, so the ladder is a control swap,
    /// not a silent policy change to how deep a buffer may be.
    func testScrollbackLadderKeepsTheStepperRange() {
        XCTAssertEqual(SettingsScrollbackLadder.range.lowerBound, 1000)
        XCTAssertEqual(SettingsScrollbackLadder.range.upperBound, 100_000)
        XCTAssertEqual(SettingsScrollbackLadder.step, 1000)
    }

    /// Thousands are grouped with a NARROW NO-BREAK SPACE (U+202F), not a comma — the readout sits in
    /// monospaced digits, where a comma reads as a decimal separator in half the world.
    func testScrollbackReadoutGroupsThousands() {
        XCTAssertEqual(SettingsScrollbackLadder.grouped(1000), "1\u{202F}000")
        XCTAssertEqual(SettingsScrollbackLadder.grouped(100_000), "100\u{202F}000")
        XCTAssertEqual(SettingsScrollbackLadder.grouped(999), "999")
        XCTAssertEqual(SettingsScrollbackLadder.readout(50000), "50\u{202F}000 lines")
    }

    /// Zero delay reads as the BEHAVIOUR ("Instant"), not as a delay that happens to round to nothing.
    func testBusyDelayReadoutNamesInstantAtZero() {
        XCTAssertEqual(SettingsBusyDelayLadder.readout(0), "Instant")
        XCTAssertEqual(SettingsBusyDelayLadder.readout(0.5), "0.5s")
        XCTAssertEqual(SettingsBusyDelayLadder.readout(10), "10.0s")
    }

    /// The multiplier readout keeps two decimals so a quarter-step is visible — matching the slider's own
    /// granularity (a `%.1f` would render 1.25 and 1.30 identically).
    func testScrollMultiplierReadoutShowsQuarterSteps() {
        XCTAssertEqual(SettingsScrollMultiplierLadder.readout(1), "1.00×")
        XCTAssertEqual(SettingsScrollMultiplierLadder.readout(1.25), "1.25×")
    }

    // MARK: - Helpers

    /// Assert an option list covers its enum exactly: same set, no duplicates, no strays.
    private func assertCoversAllCases<Value: Hashable>(
        _ listed: [Value],
        _ allCases: [Value],
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(
            Set(listed), Set(allCases),
            "every \(what) needs a card — an unlisted case is unreachable in a card grid",
            file: file, line: line,
        )
        XCTAssertEqual(
            listed.count, Set(listed).count, "duplicate \(what) card", file: file, line: line,
        )
    }

    private func assertPresetsInRange(
        _ presets: [(label: String, value: Double)],
        _ range: ClosedRange<Double>,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        for preset in presets {
            XCTAssertTrue(
                range.contains(preset.value),
                "\(what) preset \(preset.label) (\(preset.value)) is outside \(range)",
                file: file, line: line,
            )
        }
    }
}
#endif
