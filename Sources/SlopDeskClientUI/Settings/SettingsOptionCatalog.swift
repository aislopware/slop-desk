// SettingsOptionCatalog — the option LISTS the illustrated card groups render, as pure data.
//
// WHY A CATALOG: a `Picker`'s choices used to live as inline `Text("…").tag(…)` children inside a view body,
// which meant the labels, their order, and the honesty captions were unreachable to a test and easy to drift
// from the enum they tag. Lifting them out follows the same pattern `GeneralSettingsLayout` set for the General
// page's section headers: the view renders the list, `SettingsOptionCatalogTests` pins it.
//
// EVERY LIST IS EXHAUSTIVE OVER ITS ENUM. That is the invariant worth having: a new
// `RightClickAction` / `CursorStyle` / `WindowSizeMode` case must appear in its card group, and the test asserts
// list-vs-`allCases` coverage so an added case can't silently become unreachable in the UI (a dropped option is
// invisible in a card grid — there is no "…" to hint at what's missing).
//
// CAPTIONS ARE THE HONESTY CHANNEL: where a choice is deferred, aliased, or caveated, the caveat rides the
// option's caption rather than a paragraph elsewhere on the page — `auto` new-tab position IS `end` today
// (`NewTabPosition.insertionIndex` returns `tabCount` for both), so its card says so. A card hangs the
// caption under the label; a menu folds it in after an en dash (`SettingsOption.menuLabel`).
//
// NOT EVERY LIST IS A CARD GRID. Lists whose options differ only by which WORD names them (right-click
// action, on-launch behaviour, close-confirmation scope) render as a `SettingsOptionMenuRow` — same list,
// same exhaustiveness pin, no picture frames. See `SettingsControls`' header for the rule.
//
// The scalar ladders (scrollback depth, scroll multiplier, busy-reveal delay) live here too: their presets and
// readout formatting are pure functions, pinned rather than eyeballed.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

/// The card-group option lists. One `static let` per illustrated group, in the order the cards render.
enum SettingsOptionCatalog {
    // MARK: - Appearance

    /// Appearance → Cursor → Style. Drawn by ``SettingsCaretArt`` (the same caret geometry as the live preview
    /// directly above the cards), so the four styles are told apart by silhouette.
    static let cursorStyles: [SettingsOption<TerminalPreferences.CursorStyle>] = [
        SettingsOption(.block, "Block"),
        SettingsOption(.blockHollow, "Hollow"),
        SettingsOption(.bar, "Bar"),
        SettingsOption(.underline, "Underline"),
    ]

    /// Appearance → Tabs → New tab position. Drawn by ``SettingsTabPositionArt`` as the vertical tab column
    /// slopdesk actually has. `auto` carries the alias caption because it resolves to the same append as `end`.
    static let newTabPositions: [SettingsOption<NewTabPosition>] = [
        SettingsOption(.auto, "Automatic", caption: "Appends, like End"),
        SettingsOption(.end, "End"),
        SettingsOption(.afterCurrent, "After current"),
    ]

    /// Appearance → Theme → Density. The value is the raw `appearance.density` string the store persists.
    /// Drawn by ``SettingsDensityArt`` — more rows, tighter, is what compact BUYS.
    static let densities: [SettingsOption<String>] = [
        SettingsOption(densityComfortable, "Comfortable"),
        SettingsOption(densityCompact, "Compact"),
    ]

    /// The persisted `density` tokens. Named so the picker, the store default, and the test agree on one
    /// spelling instead of three string literals.
    static let densityComfortable = "comfortable"
    static let densityCompact = "compact"

    // MARK: - Controls

    /// Controls → Keyboard → Option as Alt. Drawn by ``SettingsOptionKeyArt``: four prose labels that read
    /// almost identically become four distinct key-row silhouettes.
    static let optionAsAlt: [SettingsOption<OptionAsAlt>] = [
        SettingsOption(.off, "Off", caption: "Accents"),
        SettingsOption(.both, "Both"),
        SettingsOption(.left, "Left only"),
        SettingsOption(.right, "Right only"),
    ]

    /// Controls → Mouse → Right-click action. A MENU, not cards: five actions with no shared geometry to
    /// diagram, told apart by their verb. Ctrl+right-click always opens the menu regardless — that lives in
    /// the row's subtitle, not per option.
    static let rightClickActions: [SettingsOption<RightClickAction>] = [
        SettingsOption(.contextMenu, "Context menu"),
        SettingsOption(.copy, "Copy"),
        SettingsOption(.paste, "Paste"),
        SettingsOption(.copyOrPaste, "Copy or paste"),
        SettingsOption(.ignore, "Ignore"),
    ]

    // MARK: - General

    /// General → On launch. A menu — two behaviours, distinguished by their sentence.
    static let onLaunch: [SettingsOption<OnLaunchBehavior>] = [
        SettingsOption(.restoreLastSession, "Restore session"),
        SettingsOption(.newWindow, "New window"),
    ]

    /// General → Close confirmation (rendered TWICE — once for a closing tab, once for a closing window — off
    /// the one list, so the two rows can never offer different policies). A menu.
    static let closeConfirmation: [SettingsOption<CloseConfirmationPolicy>] = [
        SettingsOption(.process, "Running process", caption: "only if busy"),
        SettingsOption(.always, "Always"),
        SettingsOption(.multipleTabs, "Multiple tabs"),
    ]

    // MARK: - Appearance → Window (macOS-only)

    #if os(macOS)
    /// Appearance → Window → Window size. Drawn by ``SettingsWindowArt``: the remembered frame as a dashed
    /// ghost, the grid mode as actual cells, the frame mode as the two pixel rules it asks for.
    static let windowSizes: [SettingsOption<WindowSizeMode>] = [
        SettingsOption(.remember, "Remember", caption: "Last size"),
        SettingsOption(.grid, "Grid", caption: "Cols × rows"),
        SettingsOption(.frame, "Frame", caption: "Pixels"),
    ]

    /// Appearance → Window → Remote desktop opens. Drawn by ``SettingsWindowArt``, whose screen bezel makes
    /// "fills the screen" a visible relationship and whose title strip is the one mark separating native
    /// fullscreen from a borderless cover.
    static let desktopPresentations: [SettingsOption<DesktopWindowPresentation>] = [
        SettingsOption(.window, "Window"),
        SettingsOption(.fullscreen, "Fullscreen", caption: "Captures ⌘Tab"),
        SettingsOption(.borderless, "Borderless", caption: "Covers the Space"),
    ]
    #endif
}

// MARK: - Scalar ladders (slider presets + readouts)

/// Controls → Scroll → Scrollback depth. Was a `Stepper` with a 1 000-line increment: crossing its own
/// 1 000…100 000 range took 99 clicks, so the top of the range was effectively unreachable. A slider plus
/// magnitude stops makes every useful depth one gesture away.
enum SettingsScrollbackLadder {
    static let range: ClosedRange<Double> = 1000...100_000
    static let step: Double = 1000

    /// The magnitude stops, in order. Values a user actually picks — a shallow buffer, the default, and the
    /// deep ones — not an even subdivision of the range.
    static let presets: [(label: String, value: Double)] = [
        ("1k", 1000),
        ("10k", 10000),
        ("25k", 25000),
        ("50k", 50000),
        ("100k", 100_000),
    ]

    /// The readout: thin-space grouped so a five-digit depth is legible at a glance (`50 000 lines`). Uses a
    /// NARROW NO-BREAK SPACE (U+202F) as the group separator rather than a locale comma — the value sits in a
    /// monospaced-digit readout, where a comma reads as a decimal point in half the world.
    static func readout(_ lines: Double) -> String {
        "\(grouped(Int(lines.rounded()))) lines"
    }

    /// Group an integer in thousands with a narrow no-break space.
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) { out.append("\u{202F}") }
            out.append(character)
        }
        return out
    }
}

/// Controls → Scroll → Scroll multiplier. The slider was already there; the stops name the values that mean
/// something (half speed, the 1× identity, double, triple) so "back to normal" is one tap, not a drag hunt.
enum SettingsScrollMultiplierLadder {
    static let range: ClosedRange<Double> = 0.25...5
    static let step: Double = 0.25
    static let presets: [(label: String, value: Double)] = [
        ("0.5×", 0.5),
        ("1×", 1),
        ("2×", 2),
        ("3×", 3),
    ]

    /// Two decimals so a quarter-step is visible (`1.25×`), matching the slider's own granularity.
    static func readout(_ multiplier: Double) -> String {
        String(format: "%.2f×", multiplier)
    }
}

/// Shell → Tab Badge → Busy reveal delay: how long a command must run before its row shows as busy. The stops
/// are the three real intentions — immediate, a beat, or only for genuinely slow work.
enum SettingsBusyDelayLadder {
    static let range: ClosedRange<Double> = 0...10
    static let step: Double = 0.5
    static let presets: [(label: String, value: Double)] = [
        ("Instant", 0),
        ("1s", 1),
        ("3s", 3),
        ("5s", 5),
    ]

    /// `Instant` at zero (the behaviour, not the number — `0.0s` reads as a delay that happens to be short),
    /// otherwise one decimal to match the half-second step.
    static func readout(_ seconds: Double) -> String {
        seconds == 0 ? "Instant" : String(format: "%.1fs", seconds)
    }
}
#endif
