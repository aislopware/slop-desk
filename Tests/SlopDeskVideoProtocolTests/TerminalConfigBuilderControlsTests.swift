import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// The CONTROL passthrough leg of the pure `TerminalPreferences`/`TerminalControlsConfig` →
/// libghostty config-string builder. Pins every control field to its exact libghostty config line
/// (`copy-on-select`, `clipboard-*`, `selection-clear-*`, `mouse-*`, `cursor-*` + the ⇧+arrow
/// `adjust_selection` keybinds), on AND off, headlessly (no libghostty surface — the hang-safety rule).
///
/// The load-bearing regression guard: a `controls: nil` build is BYTE-FOR-BYTE the no-controls output (so the
/// existing `TerminalConfigBuilderTests` and the frozen golden corpus are untouched — controls do not
/// touch the wire). Each control assertion checks the line against the INDEPENDENTLY-known libghostty key +
/// token (not the builder's own derivation), so every case FAILS on a builder that does not emit the key.
final class TerminalConfigBuilderControlsTests: XCTestCase {
    /// Split the config string into a `[key: value]` map. For the unique single-valued control keys the map
    /// is exact; the multi-line `keybind` lines collapse (use ``keybindLines`` for those).
    private func parse(_ config: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in config.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            map[key] = value
        }
        return map
    }

    /// Every `keybind = …` line's VALUE (the `<chord>=<action>` payload), in emission order.
    private func keybindLines(_ config: String) -> [String] {
        config.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("keybind = ") }
            .map { String($0.dropFirst("keybind = ".count)) }
    }

    // MARK: controls: nil — the regression guard (byte-for-byte the no-controls output)

    func testControlsNilIsByteForByteTheNoControlsBuild() {
        // Default prefs.
        let defaultPrefs = TerminalPreferences()
        XCTAssertEqual(
            TerminalConfigBuilder.string(for: defaultPrefs, controls: nil),
            TerminalConfigBuilder.string(for: defaultPrefs),
            "a nil controls build must reproduce the no-controls signature byte-for-byte",
        )
        // Custom prefs incl. cursor render fields + keybinds + theme override — still identical with nil.
        let customPrefs = TerminalPreferences(
            fontFamily: "JetBrains Mono", fontSize: 14.5, cursorColor: "FF8800",
            cursorTextColor: "111111", cursorOpacity: 0.5,
        )
        XCTAssertEqual(
            TerminalConfigBuilder.string(
                for: customPrefs, keybinds: ["cmd+d=new_split:right"],
                backgroundOverride: "2D2A2E", controls: nil,
            ),
            TerminalConfigBuilder.string(
                for: customPrefs, keybinds: ["cmd+d=new_split:right"], backgroundOverride: "2D2A2E",
            ),
            "nil controls must not perturb the output even when the prefs carry cursor/keybind/theme data",
        )
    }

    func testControlsNilEmitsNoneOfTheControlKeys() {
        let map = parse(TerminalConfigBuilder.string(for: TerminalPreferences(), controls: nil))
        for key in [
            "copy-on-select", "clipboard-trim-trailing-spaces", "selection-clear-on-typing",
            "selection-clear-on-copy", "clipboard-paste-protection", "clipboard-paste-bracketed-safe",
            "clipboard-read", "clipboard-write", "mouse-hide-while-typing", "mouse-shift-capture",
            "cursor-click-to-move", "mouse-reporting", "right-click-action", "mouse-scroll-multiplier",
            "cursor-opacity", "macos-option-as-alt",
        ] {
            XCTAssertNil(map[key], "\(key) must be absent when controls are not supplied")
        }
        // …and no ⇧+arrow selection keybinds either.
        XCTAssertTrue(keybindLines(TerminalConfigBuilder.string(for: TerminalPreferences(), controls: nil)).isEmpty)
    }

    // MARK: Copy-on-select + trim

    func testCopyOnSelectOnEmitsClipboardOffEmitsFalse() {
        let on = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(copyOnSelect: true),
        ))
        XCTAssertEqual(on["copy-on-select"], "clipboard", "ON maps to libghostty's `clipboard` (system pasteboard)")
        let off = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(copyOnSelect: false),
        ))
        XCTAssertEqual(off["copy-on-select"], "false")
    }

    func testTrimTrailingSpacesOnOff() {
        let on = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(trimTrailing: true),
        ))
        XCTAssertEqual(on["clipboard-trim-trailing-spaces"], "true")
        let off = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(trimTrailing: false),
        ))
        XCTAssertEqual(off["clipboard-trim-trailing-spaces"], "false")
    }

    // MARK: Clear-on-typing / clear-on-copy

    func testSelectionClearKeys() {
        let map = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(),
            controls: TerminalControlsConfig(clearOnTyping: false, clearOnCopy: true),
        ))
        XCTAssertEqual(map["selection-clear-on-typing"], "false")
        XCTAssertEqual(map["selection-clear-on-copy"], "true")
    }

    // MARK: Paste protection

    func testPasteProtectionAndBracketedSafe() {
        let map = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(),
            controls: TerminalControlsConfig(pasteProtection: false, bracketedSafe: false),
        ))
        XCTAssertEqual(map["clipboard-paste-protection"], "false")
        XCTAssertEqual(map["clipboard-paste-bracketed-safe"], "false")
    }

    // MARK: OSC-52 access

    func testClipboardReadWriteTokensPassThroughVerbatim() {
        let map = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(),
            controls: TerminalControlsConfig(clipboardReadToken: "deny", clipboardWriteToken: "ask"),
        ))
        XCTAssertEqual(map["clipboard-read"], "deny")
        XCTAssertEqual(map["clipboard-write"], "ask")
        // The default config carries the libghostty access defaults.
        let defaults = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(),
        ))
        XCTAssertEqual(defaults["clipboard-read"], "ask")
        XCTAssertEqual(defaults["clipboard-write"], "allow")
    }

    // MARK: Mouse knobs (hide-while-typing / shift-capture / click-to-move / mouse-reporting)

    func testMouseControlKeys() {
        let map = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(),
            controls: TerminalControlsConfig(
                hideMouseWhileTyping: false, mouseShiftCaptureToken: "always",
                clickToMove: false, allowMouseCapture: false,
            ),
        ))
        XCTAssertEqual(map["mouse-hide-while-typing"], "false")
        XCTAssertEqual(map["mouse-shift-capture"], "always")
        XCTAssertEqual(map["cursor-click-to-move"], "false")
        XCTAssertEqual(map["mouse-reporting"], "false", "Allow-Mouse-Capture maps to libghostty `mouse-reporting`")
    }

    /// The FACTORY control bundle must emit `mouse-shift-capture = false` — the libghostty token whose docs
    /// say the shift key is NOT sent to the program and EXTENDS THE SELECTION (and libghostty's own default).
    /// This pins the "Allow Shift with Mouse Click" default (hold ⇧ to select even when an app captures the
    /// mouse): a regression that flips the leaf default back to a capture token (`true`/`always`) would defeat
    /// the shift-to-select escape hatch, and is caught here independently of the `MouseShiftCapture` enum.
    func testDefaultMouseShiftCaptureExtendsSelection() {
        let map = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(),
        ))
        XCTAssertEqual(
            map["mouse-shift-capture"], "false",
            "the factory control bundle keeps the shift-extends-selection escape hatch (libghostty `false`)",
        )
    }

    // MARK: Right-Click Action — libghostty owns the dispatch via `right-click-action`

    /// The Right-Click Action token passes through verbatim as libghostty's `right-click-action`, so the
    /// surface itself performs Copy / Paste / Copy-or-Paste / Ignore / Context-Menu — the GUI view no longer
    /// re-reads `hasSelection()` after libghostty has already word-selected. FAILS without this: the builder
    /// would emit NO `right-click-action` line, so libghostty stays at its default Context-Menu
    /// and word-selects on every bare right-click. Each token is one of the libghostty enum values 1:1.
    func testRightClickActionTokenPassesThroughVerbatim() {
        for token in ["context-menu", "copy", "paste", "copy-or-paste", "ignore"] {
            let map = parse(TerminalConfigBuilder.string(
                for: TerminalPreferences(), controls: TerminalControlsConfig(rightClickActionToken: token),
            ))
            XCTAssertEqual(map["right-click-action"], token, "the \(token) action must reach libghostty verbatim")
        }
    }

    /// The FACTORY control bundle keeps libghostty's own default Right-Click Action (`context-menu`), so a
    /// fresh terminal shows the native menu on right-click by default.
    func testDefaultRightClickActionIsContextMenu() {
        let map = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(),
        ))
        XCTAssertEqual(map["right-click-action"], "context-menu")
    }

    /// The scroll multiplier rides BOTH axes but PRESERVES libghostty's native per-axis ratio (precision:1,
    /// discrete:3) — precision = `m`, discrete = `3 × m`. FAILS before the fix: the builder emitted the SAME
    /// factor on both axes, so at the default `m == 1.0` discrete (mouse-wheel) scroll ran 3× slower than
    /// stock ghostty. `2.5` → `precision:2.5,discrete:7.5` (the integral-aware `formatSize` mirror).
    func testScrollMultiplierPreservesGhosttyDiscreteRatio() {
        let custom = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(scrollMultiplier: 2.5),
        ))
        XCTAssertEqual(custom["mouse-scroll-multiplier"], "precision:2.5,discrete:7.5")
    }

    /// The DEFAULT control bundle (`m == 1.0`) must emit ghostty's NATIVE per-axis defaults —
    /// `precision:1,discrete:3` — so out of the box mouse-wheel scroll matches stock ghostty (not the
    /// pre-fix `discrete:1`, which was 3× too slow). The pin for the default-scroll behaviour.
    func testDefaultScrollMultiplierMatchesGhosttyNativeDefaults() {
        let unit = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(),
        ))
        XCTAssertEqual(unit["mouse-scroll-multiplier"], "precision:1,discrete:3")
    }

    // MARK: Option as Alt — libghostty owns the macOS Option→Alt/Meta encoding via `macos-option-as-alt`

    /// The Option-as-Alt token passes through verbatim as libghostty's `macos-option-as-alt`, so the client's
    /// libghostty surface encodes the Option key the way the user chose. FAILS before the fix: the builder
    /// emitted NO `macos-option-as-alt` line, so Option always composed accented characters and never reached a
    /// TUI as Alt/Meta. Each token is one of the libghostty `OptionAsAlt` enum values 1:1.
    func testOptionAsAltTokenPassesThroughVerbatim() {
        for token in ["false", "true", "left", "right"] {
            let map = parse(TerminalConfigBuilder.string(
                for: TerminalPreferences(), controls: TerminalControlsConfig(macosOptionAsAltToken: token),
            ))
            XCTAssertEqual(map["macos-option-as-alt"], token, "the \(token) option must reach libghostty verbatim")
        }
    }

    /// The FACTORY control bundle keeps libghostty's own default (`macos-option-as-alt = false`), so out of the
    /// box Option composes accented characters — the "Option as Alt" default stays OFF.
    func testDefaultOptionAsAltIsFalse() {
        let map = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(),
        ))
        XCTAssertEqual(map["macos-option-as-alt"], "false")
    }

    // MARK: Cursor color / text / opacity — from TerminalPreferences

    func testCursorColorOpacityTextEmittedFromPrefs() {
        let prefs = TerminalPreferences(cursorColor: "FF8800", cursorTextColor: "111111", cursorOpacity: 0.6)
        let map = parse(TerminalConfigBuilder.string(for: prefs, controls: TerminalControlsConfig()))
        XCTAssertEqual(map["cursor-color"], "FF8800")
        XCTAssertEqual(map["cursor-text"], "111111")
        XCTAssertEqual(map["cursor-opacity"], "0.6")
    }

    func testEmptyCursorColorsSkippedButOpacityAlwaysEmits() {
        // Default cursor colours are "" (follow theme) → skipped; opacity 1.0 still emits (a numeric pref).
        let map = parse(TerminalConfigBuilder.string(for: TerminalPreferences(), controls: TerminalControlsConfig()))
        XCTAssertNil(map["cursor-color"], "an empty cursor colour is omitted, not emitted blank")
        XCTAssertNil(map["cursor-text"], "an empty cursor-text colour is omitted")
        XCTAssertEqual(map["cursor-opacity"], "1", "opacity always emits (default 1.0 → `1`)")
    }

    // MARK: Shift+Arrow select

    func testShiftArrowSelectOnEmitsFourAdjustSelectionKeybinds() {
        let config = TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(shiftArrowSelect: true),
        )
        let binds = keybindLines(config)
        XCTAssertEqual(binds, [
            "shift+left=adjust_selection:left",
            "shift+right=adjust_selection:right",
            "shift+up=adjust_selection:up",
            "shift+down=adjust_selection:down",
        ])
    }

    func testShiftArrowSelectOffUnbindsSoArrowsForwardToTheProgram() {
        // libghostty's vendored fork binds shift+arrow → adjust_selection by DEFAULT, so OFF must `unbind`
        // (not simply emit nothing) for the arrow escapes to reach the program.
        let config = TerminalConfigBuilder.string(
            for: TerminalPreferences(), controls: TerminalControlsConfig(shiftArrowSelect: false),
        )
        XCTAssertEqual(keybindLines(config), [
            "shift+left=unbind", "shift+right=unbind", "shift+up=unbind", "shift+down=unbind",
        ])
    }

    // MARK: Determinism + ordering

    func testControlsBlockIsDeterministicAndFollowsTheRenderLines() {
        let prefs = TerminalPreferences(fontFamily: "Menlo")
        let controls = TerminalControlsConfig(copyOnSelect: true)
        let a = TerminalConfigBuilder.string(for: prefs, controls: controls)
        let b = TerminalConfigBuilder.string(for: prefs, controls: controls)
        XCTAssertEqual(a, b, "same inputs ⇒ byte-identical output")
        let lines = a.split(separator: "\n").map(String.init)
        guard let fontIdx = lines.firstIndex(where: { $0.hasPrefix("font-family = ") }),
              let copyIdx = lines.firstIndex(where: { $0.hasPrefix("copy-on-select = ") })
        else {
            XCTFail("expected both the font line and the control block")
            return
        }
        XCTAssertLessThan(fontIdx, copyIdx, "the control block follows the existing render lines")
    }
}
