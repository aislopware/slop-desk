import Foundation

/// PURE, headless builder: ``TerminalPreferences`` → a libghostty config string (W13).
///
/// libghostty's `ghostty_config_load_string` (header 1133) accepts the SAME newline-separated
/// `key = value` syntax as `~/.config/ghostty/config`. W13's `GhosttyTerminalView` feeds the output of
/// ``string(for:)`` through that call BEFORE `ghostty_config_finalize`, so a font / theme / cursor
/// change applies live (and the host PTY grid is re-measured + resized after the reflow).
///
/// This type is the testable seam: the config-string mapping is pure (no libghostty, no SwiftUI), so
/// `TerminalConfigBuilderTests` can pin every field → its Ghostty config key WITHOUT a surface (the
/// hang-safety rule — no `ghostty_*` symbol is touched in a test). The libghostty apply call site is
/// compiled + code-reviewed only.
///
/// Ghostty config key names (verified against the upstream config reference / `ghostty +list-actions`):
///   • `font-family`        — the monospace family name.
///   • `font-size`          — point size.
///   • `font-style`         — weight / style token (e.g. `Regular`, `Bold`).
///   • `theme`              — named theme / palette.
///   • `background`         — surface background colour (6-hex; overrides the theme).
///   • `foreground`         — text colour (6-hex; overrides the theme).
///   • `cursor-style`       — `block` / `block_hollow` / `bar` / `underline`.
///   • `cursor-style-blink` — `true` / `false`, or OMITTED (tri-state `.default` defers to DEC mode 12).
///   • `scrollback-limit`   — scrollback buffer size (BYTES in Ghostty; we map lines × a per-line
///                            estimate — see ``scrollbackLimitBytes``).
///   • `keybind`            — one `keybind = <chord>=<action>` line per user rebind (additive).
public enum TerminalConfigBuilder {
    /// The per-line byte estimate used to convert a user-facing "scrollback lines" count to Ghostty's
    /// BYTE-denominated `scrollback-limit`. A generous 256 B/line (a wide 8-bit-styled row) so the user
    /// gets at LEAST the lines they asked for; over-provisioning scrollback is cheap and never wrong.
    static let bytesPerScrollbackLine = 256

    /// Convert a user-facing scrollback LINE count to Ghostty's BYTE `scrollback-limit`. Clamped at 0
    /// (a negative / nonsensical request → 0, never a trap). Pure integer math.
    public static func scrollbackLimitBytes(lines: Int) -> Int {
        let safe = lines > 0 ? lines : 0
        return safe &* bytesPerScrollbackLine
    }

    /// Build the libghostty config string for `prefs` — one `key = value` line per setting, in a
    /// STABLE order (font, theme, cursor, scrollback). Every value is emitted (these are render prefs
    /// with real defaults, unlike the nil-able video env overlay), so the string is deterministic and
    /// fully pins the surface's appearance. An EMPTY family / theme is SKIPPED (an empty `font-family =`
    /// would clear Ghostty's default to nothing) — the one place "unset" is honoured.
    /// `backgroundOverride` / `foregroundOverride` (6-hex, no `#`) — when a non-empty value is supplied it
    /// REPLACES the pref's own `background`/`foreground`. This is the seam the active THEME drives
    /// (``PreferencesStore`` passes the theme's `terminalBackgroundHex`/`terminalForegroundHex`) so the
    /// terminal cells track the chrome flat-design palette. Omit them (the default `nil`) to keep the pref's
    /// own colours — existing callers are unchanged.
    /// `controls` (E8 WI-2) — when a non-nil ``TerminalControlsConfig`` is supplied the builder APPENDS the
    /// E8 control passthrough block (selection / copy / paste / mouse / scroll knobs + the cursor
    /// colour/opacity/text render lines + the ⇧+arrow `adjust_selection` keybinds), after the existing
    /// render lines. A `nil` `controls` (the default — existing callers, the headless build, the golden
    /// generator) reproduces the pre-E8 output BYTE-FOR-BYTE: no control key is emitted, so the wire / golden
    /// corpus is untouched (this epic is wholly client-side). ``PreferencesStore`` always passes a resolved
    /// `controls` so the live surface tracks the fire-time Controls toggles.
    /// `paletteOverride` (E15 WI-2) — the active theme's 16-entry ANSI palette. When supplied AND valid
    /// (exactly ``paletteCount`` entries, every one a clean 6-hex), the builder emits
    /// `palette = N=hex` lines (indices 0–15) AFTER `foreground`, so the terminal cells track the theme. A
    /// `nil` (or malformed — validate-then-drop) value emits NO `palette` line (byte-identical default).
    /// `selectionBackgroundOverride` (E15 WI-2) — the theme's selection-highlight colour. A valid 6-hex emits
    /// `selection-background` after the palette; `nil` / malformed ⇒ no line.
    /// The FONT-PARITY keys (E15 WI-2) are read from `prefs` (``TerminalFontSettings``). All EXCEPT
    /// `font-feature` are emitted only for the non-default value of each setting; `font-feature` is emitted
    /// UNCONDITIONALLY (ligatures default `.off`, whose disabling set `-calt,-liga,-dlig` must always be sent
    /// to un-ligate fonts that ship `calt`-on GSUB tables — see ``appendFontParity``). So a default-constructed
    /// `prefs` gains exactly ONE new line versus pre-E15 — `font-feature = -calt,-liga,-dlig` — i.e. the default
    /// config is NOT byte-identical to the pre-E15 output (the rest of the font-parity block stays gated). This
    /// string is CLIENT-only (never on the wire), so the golden corpus is unaffected. Underline-off /
    /// SGR blink / and the `srgb-over`/`linear`/`perceptual` blending modes are PERSISTED but NOT emitted (no
    /// verified libghostty key — deferred-apply; decision #5).
    public static func string(
        for prefs: TerminalPreferences,
        keybinds: [String] = [],
        backgroundOverride: String? = nil,
        foregroundOverride: String? = nil,
        fontFamilyOverride: String? = nil,
        paletteOverride: [String]? = nil,
        selectionBackgroundOverride: String? = nil,
        controls: TerminalControlsConfig? = nil,
    ) -> String {
        var lines: [String] = []

        // The PRIMARY font family — the per-scope resolved family (``PreferencesStore`` passes the active
        // Light/Dark-theme override via `fontFamilyOverride`) wins over the pref's own; an empty value is
        // skipped (the "unset honoured" rule — an empty `font-family =` would CLEAR Ghostty's default).
        let family = resolved(fontFamilyOverride, or: prefs.fontFamily)
        if !family.isEmpty {
            lines.append("font-family = \(family)")
            // E15 (font-fallback fix): ghostty has NO `font-family-fallback` key — `font-family` is a
            // `RepeatableString` and the FALLBACK CHAIN is expressed by REPEATING `font-family` (Config.zig:
            // "This configuration can be repeated multiple times to specify preferred fallback fonts when the
            // requested codepoint is not available in the primary font"). So each comma-separated fallback
            // family becomes another `font-family =` line, in order, AFTER the primary — the J5 CJK/Nerd-Font
            // coverage. Only emitted when the primary is present (the first `font-family` must be the primary).
            for fallback in fallbackFamilies(prefs.fontFamilyFallback) {
                lines.append("font-family = \(fallback)")
            }
        }
        lines.append("font-size = \(formatSize(prefs.fontSize))")
        let weight = prefs.fontWeight.trimmingCharacters(in: .whitespaces)
        if !weight.isEmpty { lines.append("font-style = \(weight)") }
        // E15 WI-2: the font-parity block (fallback / per-face families / ligatures / bold-italic mode /
        // line-height / blending). Grouped here with the other font keys. Every line is gated on a non-default
        // value EXCEPT `font-feature`, which is emitted unconditionally — so a default-constructed `prefs` gains
        // exactly the one `font-feature = -calt,-liga,-dlig` line (NOT byte-identical to pre-E15; client-only,
        // so the golden corpus is untouched).
        appendFontParity(&lines, prefs: prefs)
        let theme = prefs.theme.trimmingCharacters(in: .whitespaces)
        if !theme.isEmpty { lines.append("theme = \(theme)") }
        // Emit explicit background/foreground AFTER `theme` so they override the named theme (which isn't
        // bundled and won't resolve) — this is what actually pins the surface palette. A non-empty
        // theme override wins over the pref's own; an empty value is skipped (the "unset is honoured" rule).
        let background = resolved(backgroundOverride, or: prefs.background)
        if !background.isEmpty { lines.append("background = \(background)") }
        let foreground = resolved(foregroundOverride, or: prefs.foreground)
        if !foreground.isEmpty { lines.append("foreground = \(foreground)") }
        // E15 WI-2: the active theme's ANSI palette + selection colour, AFTER bg/fg (so they layer onto the
        // surface). Both validate-then-drop — a nil / malformed value emits nothing (byte-identical default).
        appendPalette(
            &lines,
            paletteOverride: paletteOverride,
            selectionBackgroundOverride: selectionBackgroundOverride,
        )

        lines.append("cursor-style = \(prefs.cursorStyle.rawValue)")
        // `cursor-style-blink` is a libghostty OPTIONAL bool (null = defer to DEC mode 12). The tri-state pref
        // maps `.default` → SKIP the line (defer to DEC mode 12), `.on`/`.off` → explicit `true`/`false`.
        switch prefs.cursorBlink {
        case .default: break
        case .on: lines.append("cursor-style-blink = true")
        case .off: lines.append("cursor-style-blink = false")
        }
        lines.append("scrollback-limit = \(scrollbackLimitBytes(lines: prefs.scrollbackLines))")

        // Additive keybind lines (one per user rebind), validate-then-skip an empty one.
        for kb in keybinds where !kb.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("keybind = \(kb)")
        }

        // E8 WI-2: the control passthrough block — emitted ONLY when `controls` is supplied so a `nil`
        // build stays byte-identical to the pre-E8 output (the regression guard for the existing tests +
        // the frozen golden corpus).
        if let controls { appendControls(&lines, controls: controls, prefs: prefs) }

        return lines.joined(separator: "\n")
    }

    /// Append the E15 FONT-PARITY lines (the per-face families, `font-feature`, `font-style-bold/italic` +
    /// `font-synthetic-style`, `adjust-cell-height`, `font-thicken`) read from `prefs`. The fallback chain is
    /// NOT here — it rides repeated `font-family` lines in ``string(for:)`` (ghostty has no
    /// `font-family-fallback` key). `font-feature` is ALWAYS emitted (off = the disabling set); the rest are
    /// GATED on the setting being NON-default. Only keys verified to exist are
    /// emitted; underline-off / SGR blink / `srgb-over`·`linear`·`perceptual` blending are persisted
    /// but intentionally NOT emitted (deferred-apply — decision #5).
    private static func appendFontParity(_ lines: inout [String], prefs: TerminalPreferences) {
        // NOTE: the fallback CHAIN (CJK / Nerd-Font icon coverage) is NOT emitted here — ghostty has no
        // `font-family-fallback` key; the chain is repeated `font-family =` lines emitted next to the primary
        // family in ``string(for:)`` (Config.zig: `font-family` is a `RepeatableString`).
        // Explicit per-face families surface ONLY when "Auto-match weight & style" is OFF (the three manual
        // pickers show only then); each empty face is skipped.
        if !prefs.autoMatchWeightStyle {
            let bold = prefs.fontFamilyBold.trimmingCharacters(in: .whitespaces)
            if !bold.isEmpty { lines.append("font-family-bold = \(bold)") }
            let italic = prefs.fontFamilyItalic.trimmingCharacters(in: .whitespaces)
            if !italic.isEmpty { lines.append("font-family-italic = \(italic)") }
            let boldItalic = prefs.fontFamilyBoldItalic.trimmingCharacters(in: .whitespaces)
            if !boldItalic.isEmpty { lines.append("font-family-bold-italic = \(boldItalic)") }
        }
        // Ligatures → `font-feature` (always emitted). `off` emits the DISABLING set `-calt,-liga,-dlig` so a
        // font that ships ligatures (Fira Code / JetBrains Mono — `calt` is default-ON in their GSUB) is
        // actually un-ligated; `calt`/`dlig` opt in, and the alphabet flag (`font-ligatures-alphabet`) extends
        // ligation to alphabetic runs — but only when ligatures are ON (off stays off).
        var features = prefs.fontLigatures.baseFeatures
        if prefs.fontLigatures != .off, prefs.fontLigaturesAlphabet { features.append("liga") }
        lines.append("font-feature = \(features.joined(separator: ","))")
        // Bold / italic FACE mode. `off` disables the face (`font-style-{kind} = false`); the `primaryOnly` /
        // `synthetic` modes feed a SINGLE combined `font-synthetic-style` key (avoid a duplicate key). `auto`
        // (default) contributes nothing.
        if prefs.fontBold.disablesFace { lines.append("font-style-bold = false") }
        if prefs.fontItalic.disablesFace { lines.append("font-style-italic = false") }
        var synthetic = prefs.fontBold.syntheticTokens(kind: "bold")
        synthetic.append(contentsOf: prefs.fontItalic.syntheticTokens(kind: "italic"))
        if !synthetic.isEmpty { lines.append("font-synthetic-style = \(synthetic.joined(separator: ","))") }
        // Line-height → `adjust-cell-height` (percentage of the natural cell height). `.default` emits no
        // line. `compact`/`loose` are exact integral constants (0 / 20); `custom` uses `(m-1)*100` (PLAIN
        // subtract-then-multiply, never fused). The percent is clamped NaN-faithfully + integral-formatted.
        if let percent = prefs.lineHeight.adjustCellHeightPercent {
            lines.append("adjust-cell-height = \(formatSize(clampCellHeightPercent(percent)))%")
        }
        // Blending → only `macos-like` maps (a verified `font-thicken`); the rest persist but are not emitted.
        if prefs.fontBlending.thickens { lines.append("font-thicken = true") }
    }

    /// Ordered, NaN-faithful clamp of an `adjust-cell-height` percentage to a sane band (multiplier
    /// ~0.5…3.0 ⇒ −50 %…200 %). Uses ``Double/maximum(_:_:)`` / ``Double/minimum(_:_:)`` (NOT a bare `<`/`>`
    /// ternary) so a NaN / ±inf custom multiplier resolves to a finite bound rather than emitting garbage —
    /// mirrors the `CursorColorHex.channel` clamp discipline (validate, never trap).
    static func clampCellHeightPercent(_ percent: Double) -> Double {
        Double.maximum(-50.0, Double.minimum(200.0, percent))
    }

    /// The number of ANSI palette entries a valid theme palette MUST declare (indices 0–15).
    static let paletteCount = 16

    /// `true` iff `value` is a 6-digit hex colour with NO leading `#` (case-insensitive). Rejects the wrong
    /// length, `#`-prefixed strings, and any non-hex character — the caller drops the whole override then
    /// (validate-then-drop). The check is on the exact 6 characters, so embedded whitespace also fails.
    static func isValidHex(_ value: String) -> Bool {
        guard value.count == 6 else { return false }
        for scalar in value.unicodeScalars {
            let v = scalar.value
            let isDigit = v >= 48 && v <= 57 // 0–9
            let isUpperAF = v >= 65 && v <= 70 // A–F
            let isLowerAF = v >= 97 && v <= 102 // a–f
            if !(isDigit || isUpperAF || isLowerAF) { return false }
        }
        return true
    }

    /// Append the E15 theme PALETTE lines (`palette = N=hex`, indices 0–15) + `selection-background`. Both
    /// validate-then-drop: the palette is emitted only when it is exactly ``paletteCount`` clean 6-hex
    /// entries, and the selection only when it is a clean 6-hex — a `nil`/malformed value emits NOTHING
    /// (byte-identical default). Hex matches the existing bare-hex `background`/`foreground` form.
    private static func appendPalette(
        _ lines: inout [String],
        paletteOverride: [String]?,
        selectionBackgroundOverride: String?,
    ) {
        if let paletteOverride,
           paletteOverride.count == paletteCount,
           paletteOverride.allSatisfy(isValidHex)
        {
            for (index, hex) in paletteOverride.enumerated() {
                lines.append("palette = \(index)=\(hex)")
            }
        }
        if let selectionBackgroundOverride {
            let selection = selectionBackgroundOverride.trimmingCharacters(in: .whitespaces)
            if isValidHex(selection) { lines.append("selection-background = \(selection)") }
        }
    }

    /// Append the E8 *control* passthrough lines (selection / copy / paste / mouse / scroll knobs + the
    /// cursor colour/opacity/text render lines + the ⇧+arrow `adjust_selection` keybinds) to `lines`, in a
    /// STABLE order after the existing render lines. Every emitted token is a verified libghostty config
    /// value (see ``TerminalControlsConfig``); the cursor colours come from `prefs` (render prefs) under the
    /// same "empty ⇒ skip" rule as `background` / `foreground`.
    private static func appendControls(
        _ lines: inout [String],
        controls c: TerminalControlsConfig,
        prefs: TerminalPreferences,
    ) {
        // Selection → pasteboard. `copy-on-select` is a libghostty tri-state; the boolean control maps ON →
        // `clipboard` (copy straight to the system pasteboard) and OFF → `false`.
        lines.append("copy-on-select = \(c.copyOnSelect ? "clipboard" : "false")")
        lines.append("clipboard-trim-trailing-spaces = \(boolToken(c.trimTrailing))")
        lines.append("selection-clear-on-typing = \(boolToken(c.clearOnTyping))")
        lines.append("selection-clear-on-copy = \(boolToken(c.clearOnCopy))")
        // Paste protection.
        lines.append("clipboard-paste-protection = \(boolToken(c.pasteProtection))")
        lines.append("clipboard-paste-bracketed-safe = \(boolToken(c.bracketedSafe))")
        // OSC-52 clipboard access gates (token already resolved to libghostty's allow / deny / ask).
        lines.append("clipboard-read = \(c.clipboardReadToken)")
        lines.append("clipboard-write = \(c.clipboardWriteToken)")
        // Mouse / pointer.
        lines.append("mouse-hide-while-typing = \(boolToken(c.hideMouseWhileTyping))")
        lines.append("mouse-shift-capture = \(c.mouseShiftCaptureToken)")
        lines.append("cursor-click-to-move = \(boolToken(c.clickToMove))")
        lines.append("mouse-reporting = \(boolToken(c.allowMouseCapture))")
        // Right-Click Action (H7/H8) — libghostty OWNS the bare-right-click dispatch (Context Menu / Copy /
        // Paste / Copy or Paste / Ignore). The token is the libghostty `right-click-action` enum value 1:1
        // (`RightClickAction.rawValue` matches the Zig enum names exactly), so the
        // surface itself performs the action — the GUI view no longer re-reads `hasSelection()` after the
        // surface has already word-selected under the cursor (the WI-7 race). The view keeps ONLY the
        // ⌃-right-always-menu override.
        lines.append("right-click-action = \(c.rightClickActionToken)")
        // A single scroll multiplier drives BOTH of libghostty's precision + discrete factors, but
        // PRESERVING libghostty's native per-axis ratio (precision:1, discrete:3). Emitting the SAME factor on
        // both axes (the pre-fix bug) made discrete mouse-wheel scroll 3× slower than stock libghostty at the
        // default `m == 1.0`. So precision rides `m` and discrete rides `3 × m` (PLAIN multiply — NEVER fused /
        // `addingProduct`, per the codec/controller convention). Formatted via the integral-aware `formatSize`
        // mirror, so the default emits `precision:1,discrete:3` (ghostty's native defaults).
        let precision = formatSize(c.scrollMultiplier)
        let discrete = formatSize(c.scrollMultiplier * 3)
        lines.append("mouse-scroll-multiplier = precision:\(precision),discrete:\(discrete)")
        // "Option as Alt" (Settings → Controls → Keyboard) — the macOS Option-key→Alt/Meta behaviour. The
        // token is libghostty's `macos-option-as-alt` enum value 1:1 (`false`/`true`/`left`/`right`); the
        // client's libghostty surface owns the key→byte encoding, so emitting it here actuates the setting. The
        // factory bundle keeps `false` (the default — Option stays free for accented characters).
        lines.append("macos-option-as-alt = \(c.macosOptionAsAltToken)")
        // Cursor colour / text-under / opacity (render prefs). An empty colour ⇒ skip (the "unset honoured"
        // rule, same as background / foreground); opacity always emits (a numeric pref, formatted not fused).
        let cursorColor = prefs.cursorColor.trimmingCharacters(in: .whitespaces)
        if !cursorColor.isEmpty { lines.append("cursor-color = \(cursorColor)") }
        let cursorText = prefs.cursorTextColor.trimmingCharacters(in: .whitespaces)
        if !cursorText.isEmpty { lines.append("cursor-text = \(cursorText)") }
        lines.append("cursor-opacity = \(formatSize(prefs.cursorOpacity))")
        // ⇧+Arrow selection. The vendored libghostty fork binds shift+arrow → adjust_selection by DEFAULT, so
        // the toggle must EXPLICITLY (re)bind when ON and `unbind` when OFF — a bare "emit nothing" for OFF
        // would leave the default selection binding live and the arrows would never reach the program. NEVER
        // touch shift+cmd+arrow (the caret-move passthrough).
        for dir in ["left", "right", "up", "down"] {
            let action = c.shiftArrowSelect ? "adjust_selection:\(dir)" : "unbind"
            lines.append("keybind = shift+\(dir)=\(action)")
        }
    }

    /// Split the comma-separated fallback-family string into ordered, trimmed, non-empty family names.
    /// Each becomes a repeated `font-family =` line after the primary (ghostty's fallback chain). A blank /
    /// all-whitespace entry is dropped (validate-then-skip), so `"PingFang SC, , Symbols Nerd Font"` yields
    /// two families.
    static func fallbackFamilies(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The `true` / `false` token for a libghostty boolean config value.
    private static func boolToken(_ flag: Bool) -> String { flag ? "true" : "false" }

    /// Resolve a colour value: the `override` (trimmed) if it is non-empty, else the `fallback` (trimmed).
    /// Lets the theme override win while an empty / absent override transparently keeps the pref's colour.
    static func resolved(_ override: String?, or fallback: String) -> String {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback.trimmingCharacters(in: .whitespaces)
    }

    /// Format the font size without a spurious decimal / exponent: an integral size prints `13`, a
    /// fractional one `13.5` — what a user would type and what Ghostty's parser accepts. Mirrors
    /// ``EnvBridge/formatDouble(_:)`` so the two surfaces agree.
    static func formatSize(_ size: Double) -> String {
        if size.isFinite, size == size.rounded(), abs(size) < 1e9 {
            return String(Int(size))
        }
        return String(size)
    }
}

// MARK: - TerminalControlsConfig (the leaf, libghostty-token mirror the builder consumes)

/// The PURE, libghostty-token mirror of the fire-time terminal CONTROL knobs (E8 WI-2), defined HERE in the
/// leaf ``AislopdeskVideoProtocol`` module so ``TerminalConfigBuilder`` (and its headless test) can emit the
/// control config lines WITHOUT importing the higher-level `AislopdeskWorkspaceCore.TerminalControls` value
/// type — which carries the `Defaults`-backed `from(defaults:)` factory and the multi-state enums
/// (`ClipboardAccess`, `MouseShiftCapture`, …). The module graph is one-way (`AislopdeskWorkspaceCore` →
/// `AislopdeskVideoProtocol`, never the reverse — VideoProtocol stays the pure wire/settings leaf with no
/// `Defaults` dependency), so the builder's input MUST live in the leaf; the embedder maps
/// `AislopdeskWorkspaceCore.TerminalControls` → this struct at the `PreferencesStore.applyTerminal()`
/// call-site (boolean knobs pass straight through; the multi-state enums resolve to their libghostty token —
/// `clipboard-read` / `clipboard-write` ← `ClipboardAccess.rawValue`, `mouse-shift-capture` ←
/// `MouseShiftCapture.configValue`).
///
/// The init defaults MIRROR `TerminalControls`' defaults, so a default-constructed value is a faithful
/// "factory" control bundle and a test can vary one field at a time.
public struct TerminalControlsConfig: Sendable, Equatable {
    /// Copy-on-Select (I4) — ON → libghostty `copy-on-select = clipboard`, OFF → `false`.
    public var copyOnSelect: Bool
    /// Trim-Trailing-Spaces (I5) — `clipboard-trim-trailing-spaces`.
    public var trimTrailing: Bool
    /// Clear-Selection-on-Typing (I6) — `selection-clear-on-typing`.
    public var clearOnTyping: Bool
    /// Clear-Selection-on-Copy (I6) — `selection-clear-on-copy`.
    public var clearOnCopy: Bool
    /// Paste-Protection (I9) — `clipboard-paste-protection`.
    public var pasteProtection: Bool
    /// Paste-Bracketed-Safe (I9) — `clipboard-paste-bracketed-safe`.
    public var bracketedSafe: Bool
    /// OSC-52 READ access token (I11) — emitted verbatim as `clipboard-read` (libghostty `allow`/`deny`/`ask`).
    public var clipboardReadToken: String
    /// OSC-52 WRITE access token (I11) — emitted verbatim as `clipboard-write`.
    public var clipboardWriteToken: String
    /// Hide-Mouse-When-Typing (H9) — `mouse-hide-while-typing`.
    public var hideMouseWhileTyping: Bool
    /// Allow-Shift-with-Mouse-Click (H-shift) token — emitted verbatim as `mouse-shift-capture`
    /// (libghostty `false`/`true`/`always`/`never`).
    public var mouseShiftCaptureToken: String
    /// Cursor-Click-to-Move — `cursor-click-to-move`.
    public var clickToMove: Bool
    /// Allow-Mouse-Capture — `mouse-reporting`.
    public var allowMouseCapture: Bool
    /// Right-Click Action (H7/H8) token — emitted verbatim as `right-click-action` so libghostty owns the
    /// bare-right-click dispatch (libghostty `ignore`/`paste`/`copy`/`copy-or-paste`/`context-menu`, default
    /// `context-menu`). The GUI view keeps only the ⌃-right-always-menu override.
    public var rightClickActionToken: String
    /// Shift+Arrow-Select (I2) — ON emits four `shift+<dir>=adjust_selection:<dir>` keybinds; OFF emits
    /// four `shift+<dir>=unbind` (the fork binds them by default, so OFF must unbind to forward to the program).
    public var shiftArrowSelect: Bool
    /// Scroll-Multiplier — drives BOTH `mouse-scroll-multiplier` precision + discrete factors.
    public var scrollMultiplier: Double
    /// "Option as Alt" token — emitted verbatim as libghostty's `macos-option-as-alt`
    /// (`false`/`true`/`left`/`right`, default `false`). Resolved from `OptionAsAlt.configValue` at the
    /// `PreferencesStore.applyTerminal()` call-site (the leaf stays `Defaults`-free).
    public var macosOptionAsAltToken: String

    public init(
        copyOnSelect: Bool = false,
        trimTrailing: Bool = true,
        clearOnTyping: Bool = true,
        clearOnCopy: Bool = false,
        pasteProtection: Bool = true,
        bracketedSafe: Bool = true,
        clipboardReadToken: String = "ask",
        clipboardWriteToken: String = "allow",
        hideMouseWhileTyping: Bool = true,
        mouseShiftCaptureToken: String = "false",
        clickToMove: Bool = true,
        allowMouseCapture: Bool = true,
        rightClickActionToken: String = "context-menu",
        shiftArrowSelect: Bool = true,
        scrollMultiplier: Double = 1.0,
        macosOptionAsAltToken: String = "false",
    ) {
        self.copyOnSelect = copyOnSelect
        self.trimTrailing = trimTrailing
        self.clearOnTyping = clearOnTyping
        self.clearOnCopy = clearOnCopy
        self.pasteProtection = pasteProtection
        self.bracketedSafe = bracketedSafe
        self.clipboardReadToken = clipboardReadToken
        self.clipboardWriteToken = clipboardWriteToken
        self.hideMouseWhileTyping = hideMouseWhileTyping
        self.mouseShiftCaptureToken = mouseShiftCaptureToken
        self.clickToMove = clickToMove
        self.allowMouseCapture = allowMouseCapture
        self.rightClickActionToken = rightClickActionToken
        self.shiftArrowSelect = shiftArrowSelect
        self.scrollMultiplier = scrollMultiplier
        self.macosOptionAsAltToken = macosOptionAsAltToken
    }
}
