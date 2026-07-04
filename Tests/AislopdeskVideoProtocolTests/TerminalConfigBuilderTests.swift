import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// W13 — the PURE `TerminalPreferences → ghostty config string` builder. Pins every field to its
/// Ghostty config key (`font-family`, `font-size`, `font-style`, `theme`, `cursor-style`,
/// `cursor-style-blink`, `scrollback-limit`) + the keybind lines, headlessly (no libghostty surface).
final class TerminalConfigBuilderTests: XCTestCase {
    /// Split the config string into its `key` set + a `[key: value]` map (keys are unique per build).
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

    func testDefaultPrefsMapEachFieldToTheRightGhosttyKey() {
        let config = TerminalConfigBuilder.string(for: TerminalPreferences())
        let map = parse(config)
        XCTAssertEqual(map["font-family"], "SF Mono")
        XCTAssertEqual(map["font-size"], "13") // integral → no decimal
        XCTAssertEqual(map["font-style"], "regular")
        XCTAssertEqual(map["theme"], "Aislopdesk Dark")
        XCTAssertEqual(map["background"], "FCFBF9") // default light background — overrides the (unbundled) named theme
        XCTAssertEqual(map["foreground"], "37352F")
        XCTAssertEqual(map["cursor-style"], "block")
        // The default cursor blink is the TRI-STATE `.default` (defer to DEC mode 12), which SKIPS the
        // `cursor-style-blink` line entirely (libghostty's optional-bool null). Pre-fix this emitted `true`.
        XCTAssertNil(map["cursor-style-blink"], "the .default tri-state defers to DEC mode 12 (no line)")
        // 10000 lines × 256 B/line.
        XCTAssertEqual(map["scrollback-limit"], "2560000")
    }

    /// The tri-state cursor blink: `.default` SKIPS the line (defer to DEC mode 12), `.on`/`.off` emit the
    /// explicit libghostty optional-bool. FAILS before the fix (blink was a plain Bool that always emitted).
    func testCursorBlinkTriStateEmitsOnlyForExplicitStates() {
        let def = parse(TerminalConfigBuilder.string(for: TerminalPreferences(cursorBlink: .default)))
        XCTAssertNil(def["cursor-style-blink"], ".default defers to DEC mode 12 → no line")
        let on = parse(TerminalConfigBuilder.string(for: TerminalPreferences(cursorBlink: .on)))
        XCTAssertEqual(on["cursor-style-blink"], "true")
        let off = parse(TerminalConfigBuilder.string(for: TerminalPreferences(cursorBlink: .off)))
        XCTAssertEqual(off["cursor-style-blink"], "false")
    }

    func testEachCustomFieldChangesItsLine() {
        let prefs = TerminalPreferences(
            fontFamily: "JetBrains Mono", fontSize: 14.5, fontWeight: "bold", theme: "Light",
            cursorStyle: .bar, cursorBlink: .off, scrollbackLines: 5000,
        )
        let map = parse(TerminalConfigBuilder.string(for: prefs))
        XCTAssertEqual(map["font-family"], "JetBrains Mono")
        XCTAssertEqual(map["font-size"], "14.5") // fractional preserved
        XCTAssertEqual(map["font-style"], "bold")
        XCTAssertEqual(map["theme"], "Light")
        XCTAssertEqual(map["cursor-style"], "bar")
        XCTAssertEqual(map["cursor-style-blink"], "false")
        XCTAssertEqual(map["scrollback-limit"], "1280000") // 5000 × 256
    }

    func testEveryCursorStyleRawValueIsAValidGhosttyToken() {
        for style in TerminalPreferences.CursorStyle.allCases {
            let prefs = TerminalPreferences(cursorStyle: style)
            let map = parse(TerminalConfigBuilder.string(for: prefs))
            XCTAssertEqual(map["cursor-style"], style.rawValue)
            XCTAssertTrue(["block", "block_hollow", "bar", "underline"].contains(style.rawValue))
        }
    }

    /// The four cursor styles round-trip through `cursor-style`, including the native libghostty
    /// `block_hollow` (`terminal/cursor.zig`). FAILS before the fix: the enum lacked `blockHollow`.
    func testBlockHollowCursorStyleEmitsNativeToken() {
        let map = parse(TerminalConfigBuilder.string(for: TerminalPreferences(cursorStyle: .blockHollow)))
        XCTAssertEqual(map["cursor-style"], "block_hollow")
        XCTAssertEqual(TerminalPreferences.CursorStyle.allCases.count, 4, "Block / Block (hollow) / Bar / Underline")
    }

    func testEmptyFamilyOrThemeIsSkippedNotEmittedEmpty() {
        // An empty `font-family =` would CLEAR Ghostty's default to nothing — so it is skipped, not
        // emitted as a blank line. font-size / cursor / scrollback always emit (they have real values).
        let prefs = TerminalPreferences(fontFamily: "  ", theme: "")
        let map = parse(TerminalConfigBuilder.string(for: prefs))
        XCTAssertNil(map["font-family"], "an empty family is omitted, not emitted blank")
        XCTAssertNil(map["theme"], "an empty theme is omitted")
        XCTAssertNotNil(map["font-size"], "size always emits")
        XCTAssertNotNil(map["cursor-style"])
    }

    func testBackgroundForegroundEmittedAfterThemeAndEmptySkipped() {
        // A custom bg/fg emit their lines; an empty one is skipped (so it never clears Ghostty's value).
        let custom = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(background: "112233", foreground: "AABBCC"),
        ))
        XCTAssertEqual(custom["background"], "112233")
        XCTAssertEqual(custom["foreground"], "AABBCC")

        let empty = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(background: "  ", foreground: ""),
        ))
        XCTAssertNil(empty["background"], "an empty background is omitted, not emitted blank")
        XCTAssertNil(empty["foreground"], "an empty foreground is omitted")

        // Order: background/foreground come AFTER theme so they override the named theme.
        let lines = TerminalConfigBuilder.string(for: TerminalPreferences()).split(separator: "\n").map(String.init)
        guard let themeIdx = lines.firstIndex(where: { $0.hasPrefix("theme = ") }),
              let bgIdx = lines.firstIndex(where: { $0.hasPrefix("background = ") })
        else {
            XCTFail("expected both theme and background lines")
            return
        }
        XCTAssertLessThan(themeIdx, bgIdx, "background must follow theme so it overrides it")
    }

    func testThemeBackgroundForegroundOverrideWins() {
        // The theme-driven override REPLACES the pref's own bg/fg — the flat-design seam that pins the
        // terminal cells to the active chrome palette.
        let overridden = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(background: "FCFBF9", foreground: "37352F"),
            backgroundOverride: "2D2A2E",
            foregroundOverride: "FCFCFA",
        ))
        XCTAssertEqual(overridden["background"], "2D2A2E", "the theme override wins over the pref background")
        XCTAssertEqual(overridden["foreground"], "FCFCFA", "the theme override wins over the pref foreground")

        // An empty / nil override transparently KEEPS the pref's own colour (so existing callers are unchanged).
        let kept = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(background: "112233", foreground: "AABBCC"),
            backgroundOverride: "   ",
            foregroundOverride: nil,
        ))
        XCTAssertEqual(kept["background"], "112233", "an empty override keeps the pref colour")
        XCTAssertEqual(kept["foreground"], "AABBCC", "a nil override keeps the pref colour")
    }

    func testScrollbackLimitClampsNonPositiveToZero() {
        XCTAssertEqual(TerminalConfigBuilder.scrollbackLimitBytes(lines: 0), 0)
        XCTAssertEqual(TerminalConfigBuilder.scrollbackLimitBytes(lines: -5), 0)
        XCTAssertEqual(TerminalConfigBuilder.scrollbackLimitBytes(lines: 1), 256)
    }

    func testKeybindLinesAreAppendedAndEmptyOnesSkipped() {
        let config = TerminalConfigBuilder.string(
            for: TerminalPreferences(),
            keybinds: ["cmd+d=new_split:right", "  ", "cmd+w=close_surface"],
        )
        let keybindLines = config.split(separator: "\n").filter { $0.hasPrefix("keybind = ") }
        XCTAssertEqual(keybindLines.count, 2, "two real binds, the blank one skipped")
        XCTAssertTrue(config.contains("keybind = cmd+d=new_split:right"))
        XCTAssertTrue(config.contains("keybind = cmd+w=close_surface"))
    }

    func testBuildIsDeterministicAndStableOrdered() {
        // The same prefs always produce byte-identical output (deterministic order: font → theme →
        // cursor → scrollback). A round-trip of the prefs → config → re-parse recovers the fields.
        let prefs = TerminalPreferences(fontFamily: "Menlo", fontSize: 12)
        let a = TerminalConfigBuilder.string(for: prefs)
        let b = TerminalConfigBuilder.string(for: prefs)
        XCTAssertEqual(a, b)
        let lines = a.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "font-family = Menlo", "font-family leads the stable order")
    }

    // MARK: - E15 WI-2: byte-identical pre-E15 guard

    /// The load-bearing regression guard: a default-constructed `TerminalPreferences` with NO E15 args
    /// (palette / selection nil) reproduces the EXACT default builder output. The ONLY E15 key in the default
    /// output is `font-feature = -calt,-liga,-dlig` — the ligature-DISABLING set (the `off` default truly
    /// turns ligatures off, including for a font that ships them; item 7). No per-face / palette /
    /// cell-height / thicken default leaks a line. FAILS if any other font-parity default emits.
    func testDefaultPathEmitsTheExpectedLinesExactly() {
        let expected = [
            "font-family = SF Mono",
            "font-size = 13",
            "font-style = regular",
            "font-feature = -calt,-liga,-dlig",
            "theme = Aislopdesk Dark",
            "background = FCFBF9",
            "foreground = 37352F",
            "cursor-style = block",
            "scrollback-limit = 2560000",
        ].joined(separator: "\n")
        XCTAssertEqual(TerminalConfigBuilder.string(for: TerminalPreferences()), expected)
    }

    /// Passing the new E15 args as nil is byte-for-byte the no-args build (so existing callers and the
    /// headless build are untouched), even when the prefs carry old non-default font/cursor/keybind data.
    func testE15NilArgsAreByteForByteTheNoArgsBuild() {
        let prefs = TerminalPreferences(fontFamily: "JetBrains Mono", fontSize: 14.5, cursorStyle: .bar)
        XCTAssertEqual(
            TerminalConfigBuilder.string(
                for: prefs, keybinds: ["cmd+d=new_split:right"],
                paletteOverride: nil, selectionBackgroundOverride: nil,
            ),
            TerminalConfigBuilder.string(for: prefs, keybinds: ["cmd+d=new_split:right"]),
            "nil palette/selection must not perturb the output",
        )
    }

    // MARK: - E15 WI-2: palette + selection emission (validate-then-drop)

    /// A valid 16-entry palette emits `palette = N=hex` for indices 0–15, AFTER `foreground`. The palette
    /// hex matches the existing bare-hex `background`/`foreground` form (no leading `#`).
    func testPaletteOverrideEmitsSixteenIndexedLinesAfterForeground() {
        let palette = (0..<16).map { String(format: "%06X", $0 * 0x111111 % 0x1000000) }
        let config = TerminalConfigBuilder.string(for: TerminalPreferences(), paletteOverride: palette)
        let paletteLines = config.split(separator: "\n").filter { $0.hasPrefix("palette = ") }.map(String.init)
        XCTAssertEqual(paletteLines.count, 16, "all sixteen ANSI indices emit")
        XCTAssertEqual(paletteLines.first, "palette = 0=\(palette[0])")
        XCTAssertEqual(paletteLines.last, "palette = 15=\(palette[15])")
        // Order: the first palette line follows the foreground line.
        let lines = config.split(separator: "\n").map(String.init)
        guard let fgIdx = lines.firstIndex(where: { $0.hasPrefix("foreground = ") }),
              let palIdx = lines.firstIndex(where: { $0.hasPrefix("palette = ") })
        else {
            XCTFail("expected both foreground and palette lines")
            return
        }
        XCTAssertLessThan(fgIdx, palIdx, "palette follows foreground")
    }

    /// validate-then-drop: a short (≠16) palette or one with a bad-hex entry emits NO `palette` line — the
    /// same discipline as a hostile datagram. FAILS on a builder that emits an unvalidated palette.
    func testMalformedPaletteOverrideIsDropped() {
        let short = Array(repeating: "FF6188", count: 15) // one short
        XCTAssertFalse(
            TerminalConfigBuilder.string(for: TerminalPreferences(), paletteOverride: short).contains("palette = "),
            "a 15-entry palette is dropped (must be exactly 16)",
        )
        var badHex = Array(repeating: "FF6188", count: 16)
        badHex[7] = "#GG0000" // hash + non-hex
        XCTAssertFalse(
            TerminalConfigBuilder.string(for: TerminalPreferences(), paletteOverride: badHex).contains("palette = "),
            "a palette with any invalid-hex entry is dropped whole",
        )
        XCTAssertFalse(
            TerminalConfigBuilder.string(for: TerminalPreferences(), paletteOverride: []).contains("palette = "),
            "an empty palette is dropped",
        )
    }

    /// A valid selection colour emits `selection-background`; a malformed / nil one is dropped.
    func testSelectionBackgroundOverrideEmitsWhenValidAndDropsOtherwise() {
        let valid = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), selectionBackgroundOverride: "403E41",
        ))
        XCTAssertEqual(valid["selection-background"], "403E41")
        let bad = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(), selectionBackgroundOverride: "nope",
        ))
        XCTAssertNil(bad["selection-background"], "a non-hex selection is dropped")
        let nilArg = parse(TerminalConfigBuilder.string(for: TerminalPreferences()))
        XCTAssertNil(nilArg["selection-background"], "nil selection emits nothing")
    }

    // MARK: - E15 WI-2: font-parity keys

    /// The fallback chain (item 6): ghostty has NO `font-family-fallback` key — the chain is REPEATED
    /// `font-family =` lines (the primary first, then each fallback in order), since `font-family` is a
    /// `RepeatableString` in Config.zig. A blank entry in the comma list is dropped (validate-then-skip).
    func testFontFamilyFallbackEmitsRepeatedFontFamilyLinesInOrder() {
        let config = TerminalConfigBuilder.string(for: TerminalPreferences(
            fontFamily: "JetBrains Mono",
            fontFamilyFallback: "PingFang SC, , Symbols Nerd Font",
        ))
        let familyLines = config.split(separator: "\n").filter { $0.hasPrefix("font-family = ") }.map(String.init)
        XCTAssertEqual(
            familyLines,
            ["font-family = JetBrains Mono", "font-family = PingFang SC", "font-family = Symbols Nerd Font"],
            "primary first, then each non-empty fallback as its own repeated font-family line",
        )
        // The dead key must NOT appear anywhere.
        XCTAssertFalse(config.contains("font-family-fallback"), "the non-existent ghostty key is never emitted")
        // The default empty fallback emits ONLY the single primary font-family line.
        let plain = TerminalConfigBuilder.string(for: TerminalPreferences(fontFamily: "Menlo"))
            .split(separator: "\n").filter { $0.hasPrefix("font-family = ") }
        XCTAssertEqual(plain, ["font-family = Menlo"], "no fallback ⇒ a single font-family line")
    }

    /// The fallback chain is suppressed when the primary family is empty — the first `font-family` MUST be the
    /// primary (the "unset honoured" rule), so an empty primary emits neither it nor the fallbacks.
    func testFallbackChainSuppressedWhenPrimaryEmpty() {
        let config = TerminalConfigBuilder.string(for: TerminalPreferences(
            fontFamily: "  ", fontFamilyFallback: "PingFang SC",
        ))
        XCTAssertFalse(config.contains("font-family"), "an empty primary suppresses the whole font-family chain")
    }

    /// The explicit per-face families surface ONLY when Auto-match is OFF.
    func testPerFaceFamiliesEmitOnlyWhenAutoMatchOff() {
        // Auto-match ON (default): the per-face families are NOT emitted even when set.
        let on = parse(TerminalConfigBuilder.string(for: TerminalPreferences(
            fontFamilyBold: "IBM Plex Mono Bold", autoMatchWeightStyle: true,
        )))
        XCTAssertNil(on["font-family-bold"], "auto-match ON suppresses the manual face keys")
        // Auto-match OFF: each non-empty face emits its key; an empty one is skipped.
        let off = parse(TerminalConfigBuilder.string(for: TerminalPreferences(
            fontFamilyBold: "IBM Plex Mono Bold", fontFamilyItalic: "IBM Plex Mono Italic",
            fontFamilyBoldItalic: "", autoMatchWeightStyle: false,
        )))
        XCTAssertEqual(off["font-family-bold"], "IBM Plex Mono Bold")
        XCTAssertEqual(off["font-family-italic"], "IBM Plex Mono Italic")
        XCTAssertNil(off["font-family-bold-italic"], "an empty bold-italic face is skipped")
    }

    /// Ligatures → `font-feature` (item 7): `off` emits the DISABLING set `-calt,-liga,-dlig` (so a font that
    /// ships ligatures is actually un-ligated — Config.zig documents exactly this), `calt` → `calt`, `dlig` →
    /// `calt,dlig`; the alphabet flag appends `liga` ONLY when ligatures are on. FAILS on a builder that emits
    /// nothing for `off` (the old dead behaviour).
    func testLigatureModesMapToFontFeature() {
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontLigatures: .off)))["font-feature"],
            "-calt,-liga,-dlig",
            "off DISABLES ligatures (does not silently emit nothing)",
        )
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontLigatures: .calt)))["font-feature"], "calt",
        )
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontLigatures: .dlig)))["font-feature"],
            "calt,dlig",
        )
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(
                fontLigatures: .calt, fontLigaturesAlphabet: true,
            )))["font-feature"], "calt,liga", "the alphabet flag appends liga",
        )
        // Alphabet has no effect while ligatures are off — off stays the disabling set (no `liga`).
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(
                fontLigatures: .off, fontLigaturesAlphabet: true,
            )))["font-feature"], "-calt,-liga,-dlig", "off + alphabet still disables (no liga added)",
        )
    }

    /// The per-scope font override (item 8): a non-nil `fontFamilyOverride` REPLACES the pref's primary
    /// `font-family` (the seam `PreferencesStore` drives from the active theme slot's `themeFonts` entry); an
    /// empty / nil override keeps the pref's own family.
    func testFontFamilyOverrideReplacesPrimaryFamily() {
        let overridden = TerminalConfigBuilder.string(
            for: TerminalPreferences(fontFamily: "SF Mono"), fontFamilyOverride: "Fira Code",
        ).split(separator: "\n").first { $0.hasPrefix("font-family = ") }
        XCTAssertEqual(overridden, "font-family = Fira Code", "a non-empty override wins over the pref family")
        let kept = TerminalConfigBuilder.string(
            for: TerminalPreferences(fontFamily: "SF Mono"), fontFamilyOverride: "   ",
        ).split(separator: "\n").first { $0.hasPrefix("font-family = ") }
        XCTAssertEqual(kept, "font-family = SF Mono", "a blank override keeps the pref's own family")
    }

    /// Bold / italic FACE modes: `off` → `font-style-{kind} = false`; `primaryOnly` / `synthetic` feed a
    /// SINGLE combined `font-synthetic-style`; `auto` (default) emits nothing.
    func testBoldItalicFaceModesMapToStyleAndSyntheticKeys() {
        let auto = parse(TerminalConfigBuilder.string(for: TerminalPreferences()))
        XCTAssertNil(auto["font-style-bold"], "auto emits no font-style-bold")
        XCTAssertNil(auto["font-style-italic"])
        XCTAssertNil(auto["font-synthetic-style"], "auto/auto contributes no synthetic-style")

        let off = parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontBold: .off, fontItalic: .off)))
        XCTAssertEqual(off["font-style-bold"], "false")
        XCTAssertEqual(off["font-style-italic"], "false")
        XCTAssertNil(off["font-synthetic-style"], "off uses font-style-*=false, not synthetic")

        // A combined synthetic key: synthetic bold + primary-only italic → `bold,no-italic` (one line).
        let mixed = TerminalConfigBuilder.string(for: TerminalPreferences(
            fontBold: .synthetic,
            fontItalic: .primaryOnly,
        ))
        XCTAssertTrue(mixed.contains("font-synthetic-style = bold,no-italic"))
        let syntheticLines = mixed.split(separator: "\n").filter { $0.hasPrefix("font-synthetic-style") }
        XCTAssertEqual(syntheticLines.count, 1, "bold + italic collapse into ONE font-synthetic-style key")
    }

    /// `font-synthetic-style` is a REAL ghostty key (Config.zig:218, a `FontSyntheticStyle` packed flag-set of
    /// `bold`/`italic`/`bold-italic`) and the tokens this builder emits are in its documented vocabulary
    /// (Config.zig:201-205 — `no-bold`/`no-italic`/`no-bold-italic` disable; `bold`/`italic`/`bold-italic`
    /// enable). This pins each mode's emitted token so the mapping is provably actuated, NOT a no-op:
    /// `primaryOnly` ⇒ `no-{kind}` (disable synthesis), `synthetic` ⇒ `{kind}` (re-assert default-on synthesis).
    func testFontSyntheticStyleTokensAreValidGhosttyValues() {
        // primary-only bold → `no-bold` (disables synthetic bold; ghostty uses only the primary face).
        let primaryOnly = parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontBold: .primaryOnly)))
        XCTAssertEqual(primaryOnly["font-synthetic-style"], "no-bold")
        // synthetic italic → `italic` (re-asserts the default-ON synthesis for the italic face).
        let synthetic = parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontItalic: .synthetic)))
        XCTAssertEqual(synthetic["font-synthetic-style"], "italic")
        // Both at once collapse into ONE key with both tokens — pinned in builder order (bold then italic).
        let both = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(fontBold: .primaryOnly, fontItalic: .synthetic),
        ))
        XCTAssertEqual(both["font-synthetic-style"], "no-bold,italic")
    }

    /// Line-height → `adjust-cell-height`: default → no line, compact → `0%`, loose → `20%`, custom →
    /// `(m-1)*100%` (integral-formatted), and an out-of-band / NaN custom multiplier is clamped (no trap).
    func testLineHeightModesMapToAdjustCellHeight() {
        XCTAssertNil(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(lineHeight: .default)))["adjust-cell-height"],
            "default defers to the theme/font (no line)",
        )
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(lineHeight: .compact)))["adjust-cell-height"],
            "0%",
        )
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(lineHeight: .loose)))["adjust-cell-height"],
            "20%",
        )
        // Exactly-representable multipliers so the plain `(m-1)*100` lands on a clean integral percent
        // (1.5 → 50, 0.5 → -50). Arbitrary fractional multipliers (e.g. 1.1) emit float-faithful noise.
        XCTAssertEqual(
            parse(TerminalConfigBuilder
                .string(for: TerminalPreferences(lineHeight: .custom(1.5))))["adjust-cell-height"],
            "50%", "(1.5 - 1) * 100 = 50, integral-formatted",
        )
        XCTAssertEqual(
            parse(TerminalConfigBuilder
                .string(for: TerminalPreferences(lineHeight: .custom(0.5))))["adjust-cell-height"],
            "-50%", "a sub-1 multiplier tightens the cell (negative percent)",
        )
        // A huge multiplier clamps to the +200% band; a NaN resolves to a finite bound (never `nan%`).
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(
                for: TerminalPreferences(lineHeight: .custom(99)),
            ))["adjust-cell-height"],
            "200%",
        )
        let nanValue = parse(TerminalConfigBuilder.string(
            for: TerminalPreferences(lineHeight: .custom(.nan)),
        ))["adjust-cell-height"]
        XCTAssertNotNil(nanValue)
        XCTAssertFalse(nanValue?.lowercased().contains("nan") ?? true, "a NaN multiplier never emits `nan%`")
    }

    /// Blending → `font-thicken`: only `macos-like` maps; `default` and the three deferred modes emit
    /// nothing (no verified libghostty key — the documented deferral).
    func testFontBlendingOnlyMacosLikeEmitsFontThicken() {
        XCTAssertEqual(
            parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontBlending: .macosLike)))["font-thicken"],
            "true",
        )
        for mode in [FontBlending.default, .srgbOver, .linear, .perceptual] {
            XCTAssertNil(
                parse(TerminalConfigBuilder.string(for: TerminalPreferences(fontBlending: mode)))["font-thicken"],
                "\(mode) does not map to font-thicken",
            )
        }
    }

    /// The DEFERRED controls (underline-off, SGR blink, the non-mapping blending modes) are PERSISTED but
    /// emit NO libghostty line — we only emit keys verified to exist. FAILS if a future change leaks an
    /// unverified `font-underline` / `font-blink` / `font-blending` key.
    func testDeferredUnderlineBlinkBlendingEmitNoLine() {
        let config = TerminalConfigBuilder.string(for: TerminalPreferences(
            fontUnderline: false, fontBlink: true, fontBlending: .perceptual,
        ))
        XCTAssertFalse(config.contains("font-underline"), "underline-off has no verified key (deferred)")
        XCTAssertFalse(config.contains("font-blink"), "SGR blink has no verified key (deferred)")
        XCTAssertFalse(config.contains("font-blending"), "the blending mode itself is never emitted as a key")
    }
}
