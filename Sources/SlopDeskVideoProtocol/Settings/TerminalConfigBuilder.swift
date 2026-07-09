import Foundation

/// PURE, headless builder: ``TerminalPreferences`` → a libghostty config string (W13).
///
/// libghostty's `ghostty_config_load_string` (header 1133) accepts the SAME newline-separated
/// `key = value` syntax as `~/.config/ghostty/config`. `GhosttyTerminalView` feeds ``string(for:)``'s
/// output through it BEFORE `ghostty_config_finalize`, so a font / theme / cursor change applies live
/// (host PTY grid re-measured + resized after the reflow).
///
/// Testable seam: the mapping is pure (no libghostty, no SwiftUI), so `TerminalConfigBuilderTests` pins
/// every field → its Ghostty config key WITHOUT a surface (hang-safety rule — no `ghostty_*` in a test).
/// The libghostty apply call site is compiled + code-reviewed only.
///
/// Ghostty config keys (verified against the upstream config reference / `ghostty +list-actions`):
///   • `font-family`        — the monospace family name.
///   • `font-size`          — point size.
///   • `font-style`         — weight / style token (e.g. `Regular`, `Bold`).
///   • `theme`              — named theme / palette.
///   • `background`         — surface background colour (6-hex; overrides the theme).
///   • `foreground`         — text colour (6-hex; overrides the theme).
///   • `cursor-style`       — `block` / `block_hollow` / `bar` / `underline`.
///   • `cursor-style-blink` — `true` / `false`, or OMITTED (tri-state `.default` defers to DEC mode 12).
///   • `scrollback-limit`   — buffer size in BYTES (we map lines × a per-line estimate —
///                            see ``scrollbackLimitBytes``).
///   • `keybind`            — one `keybind = <chord>=<action>` line per user rebind (additive).
public enum TerminalConfigBuilder {
    /// Per-line byte estimate to convert user-facing "scrollback lines" → Ghostty's BYTE `scrollback-limit`.
    /// Generous 256 B/line so the user gets at LEAST the lines they asked for; over-provisioning is cheap.
    static let bytesPerScrollbackLine = 256

    /// Convert a scrollback LINE count to Ghostty's BYTE `scrollback-limit`. Clamped at 0 (negative → 0,
    /// never a trap). Pure integer math.
    public static func scrollbackLimitBytes(lines: Int) -> Int {
        let safe = lines > 0 ? lines : 0
        return safe &* bytesPerScrollbackLine
    }

    /// Build the libghostty config string for `prefs` — one `key = value` line per setting, in a STABLE
    /// order (font, theme, cursor, scrollback). Every value is emitted (real defaults, unlike the nil-able
    /// video env overlay). An EMPTY family / theme is SKIPPED — an empty `font-family =` would clear
    /// Ghostty's default to nothing (the one place "unset" is honoured).
    ///
    /// `backgroundOverride` / `foregroundOverride` (6-hex, no `#`) — a non-empty value REPLACES the pref's
    /// own `background`/`foreground`; the seam the active THEME drives (``PreferencesStore`` passes
    /// `terminalBackgroundHex`/`terminalForegroundHex`). Omit (`nil`) to keep the pref's colours.
    /// `controls` (E8 WI-2) — non-nil APPENDS the E8 control passthrough block after the render lines; `nil`
    /// (default) reproduces the pre-E8 output BYTE-FOR-BYTE (wire / golden corpus untouched — client-side).
    /// `paletteOverride` (E15 WI-2) — the theme's 16-entry ANSI palette. Valid (exactly ``paletteCount``
    /// clean 6-hex entries) → `palette = N=hex` lines (0–15) AFTER `foreground`; `nil`/malformed emits none.
    /// `selectionBackgroundOverride` (E15 WI-2) — valid 6-hex → `selection-background` after the palette;
    /// `nil` / malformed ⇒ no line. Always pairs with `selection-foreground = cell-foreground` so each cell
    /// keeps its original glyph colour under the highlight (libghostty v1.2+ token; NOT `auto` — that is
    /// invalid and silently drops, restoring the default window fg↔bg invert).
    /// FONT-PARITY keys (E15 WI-2) read from `prefs`: all EXCEPT `font-feature` emit only for a non-default
    /// value; `font-feature` emits UNCONDITIONALLY (ligatures-off's `-calt,-liga,-dlig` must always be sent
    /// to un-ligate `calt`-on GSUB fonts — see ``appendFontParity``). So a default `prefs` gains exactly ONE
    /// line vs pre-E15 — NOT byte-identical — but this string is CLIENT-only, so the golden corpus is
    /// unaffected. Underline-off / SGR blink / `srgb-over`·`linear`·`perceptual` blending are PERSISTED but
    /// NOT emitted (no verified libghostty key — deferred-apply; decision #5).
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

        // PRIMARY font family — the resolved override (``PreferencesStore`` passes the active Light/Dark
        // theme font via `fontFamilyOverride`) wins over the pref's own; empty is skipped (an empty
        // `font-family =` would CLEAR Ghostty's default).
        let family = resolved(fontFamilyOverride, or: prefs.fontFamily)
        if !family.isEmpty {
            lines.append("font-family = \(family)")
            // E15 (font-fallback fix): ghostty has NO `font-family-fallback` key — `font-family` is a
            // `RepeatableString`, so the FALLBACK CHAIN is REPEATED `font-family` lines, in order, AFTER the
            // primary (J5 CJK/Nerd-Font coverage). Only emitted when the primary is present (the first
            // `font-family` must be the primary).
            for fallback in fallbackFamilies(prefs.fontFamilyFallback) {
                lines.append("font-family = \(fallback)")
            }
        }
        lines.append("font-size = \(formatSize(prefs.fontSize))")
        let weight = prefs.fontWeight.trimmingCharacters(in: .whitespaces)
        if !weight.isEmpty { lines.append("font-style = \(weight)") }
        // E15 WI-2: the font-parity block (per-face families / ligatures / bold-italic mode / line-height /
        // blending). All gated on non-default EXCEPT `font-feature` — see ``appendFontParity`` and the doc above.
        appendFontParity(&lines, prefs: prefs)
        let theme = prefs.theme.trimmingCharacters(in: .whitespaces)
        if !theme.isEmpty { lines.append("theme = \(theme)") }
        // background/foreground AFTER `theme` so they override the named theme (which isn't bundled and
        // won't resolve) — this is what actually pins the surface palette. Override wins; empty is skipped.
        let background = resolved(backgroundOverride, or: prefs.background)
        if !background.isEmpty { lines.append("background = \(background)") }
        let foreground = resolved(foregroundOverride, or: prefs.foreground)
        if !foreground.isEmpty { lines.append("foreground = \(foreground)") }
        // E15 WI-2: theme ANSI palette + selection colour, AFTER bg/fg. Both validate-then-drop — nil /
        // malformed emits nothing.
        appendPalette(
            &lines,
            paletteOverride: paletteOverride,
            selectionBackgroundOverride: selectionBackgroundOverride,
        )

        lines.append("cursor-style = \(prefs.cursorStyle.rawValue)")
        // `cursor-style-blink` is a libghostty OPTIONAL bool. Tri-state pref: `.default` → SKIP (defer to
        // DEC mode 12), `.on`/`.off` → explicit `true`/`false`.
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

        // E8 WI-2: control passthrough block — emitted ONLY when `controls` is supplied, so a `nil` build
        // stays byte-identical to pre-E8 (regression guard for the frozen golden corpus).
        if let controls { appendControls(&lines, controls: controls, prefs: prefs) }

        return lines.joined(separator: "\n")
    }

    /// Append the E15 FONT-PARITY lines (per-face families, `font-feature`, `font-style-bold/italic` +
    /// `font-synthetic-style`, `adjust-cell-height`, `font-thicken`) from `prefs`. The fallback chain is NOT
    /// here — it rides repeated `font-family` lines in ``string(for:)`` (no `font-family-fallback` key).
    /// `font-feature` is ALWAYS emitted (off = the disabling set); the rest GATED on a NON-default value.
    /// Underline-off / SGR blink / `srgb-over`·`linear`·`perceptual` blending are persisted but NOT emitted
    /// (deferred-apply — decision #5).
    private static func appendFontParity(_ lines: inout [String], prefs: TerminalPreferences) {
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
        // Ligatures → `font-feature` (always emitted). `off` emits the DISABLING set `-calt,-liga,-dlig` to
        // un-ligate fonts that ship `calt`-on GSUB (Fira Code / JetBrains Mono); the alphabet flag extends
        // ligation to alphabetic runs, but only when ligatures are ON.
        var features = prefs.fontLigatures.baseFeatures
        if prefs.fontLigatures != .off, prefs.fontLigaturesAlphabet { features.append("liga") }
        lines.append("font-feature = \(features.joined(separator: ","))")
        // Bold / italic FACE mode. `off` disables the face (`font-style-{kind} = false`); `primaryOnly` /
        // `synthetic` feed a SINGLE combined `font-synthetic-style` key (avoid a duplicate); `auto` emits nothing.
        if prefs.fontBold.disablesFace { lines.append("font-style-bold = false") }
        if prefs.fontItalic.disablesFace { lines.append("font-style-italic = false") }
        var synthetic = prefs.fontBold.syntheticTokens(kind: "bold")
        synthetic.append(contentsOf: prefs.fontItalic.syntheticTokens(kind: "italic"))
        if !synthetic.isEmpty { lines.append("font-synthetic-style = \(synthetic.joined(separator: ","))") }
        // Line-height → `adjust-cell-height` (% of natural cell height). `.default` emits nothing; `compact`/
        // `loose` are integral constants (0 / 20); `custom` uses `(m-1)*100` (PLAIN subtract-then-multiply,
        // NEVER fused). Clamped NaN-faithfully + integral-formatted.
        if let percent = prefs.lineHeight.adjustCellHeightPercent {
            lines.append("adjust-cell-height = \(formatSize(clampCellHeightPercent(percent)))%")
        }
        // Blending → only `macos-like` maps (a verified `font-thicken`); the rest persist but are not emitted.
        if prefs.fontBlending.thickens { lines.append("font-thicken = true") }
    }

    /// Ordered, NaN-faithful clamp of an `adjust-cell-height` % to a sane band (multiplier ~0.5…3.0 ⇒
    /// −50 %…200 %). Uses ``Double/maximum(_:_:)`` / ``Double/minimum(_:_:)`` (NOT a bare `<`/`>` ternary)
    /// so a NaN / ±inf multiplier resolves to a finite bound, not garbage — mirrors `CursorColorHex.channel`.
    static func clampCellHeightPercent(_ percent: Double) -> Double {
        Double.maximum(-50.0, Double.minimum(200.0, percent))
    }

    /// The number of ANSI palette entries a valid theme palette MUST declare (indices 0–15).
    static let paletteCount = 16

    /// `true` iff `value` is a 6-digit hex colour with NO leading `#` (case-insensitive). Rejects wrong
    /// length, `#`-prefix, or any non-hex char (validate-then-drop); embedded whitespace also fails.
    /// Used for palette / background / foreground / selection-background (libghostty `Color` is RGB-only —
    /// no alpha channel; 8-digit `#rrggbbaa` is rejected by `Color.fromHex`).
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

    /// Append the E15 theme PALETTE lines (`palette = N=hex`, 0–15) + selection highlight.
    /// Palette validate-then-drop: only when exactly ``paletteCount`` clean 6-hex entries.
    /// Selection: always emit `selection-foreground = cell-foreground` (libghostty v1.2+ — keep each
    /// cell's original glyph colour under the highlight; the default null path uses the *window*
    /// bg as fg which reads as an invert). When a valid 6-hex `selectionBackgroundOverride` is present,
    /// emit `selection-background` (opaque RGB fill — true alpha wash is not in the cell path).
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
        // Keep original cell colours (ANSI red stays red, etc.) under the selection fill.
        lines.append("selection-foreground = cell-foreground")
        if let selectionBackgroundOverride {
            let selection = selectionBackgroundOverride.trimmingCharacters(in: .whitespaces)
            if isValidHex(selection) { lines.append("selection-background = \(selection)") }
        }
    }

    /// Append the E8 *control* passthrough lines (selection / copy / paste / mouse / scroll knobs + cursor
    /// colour/opacity/text + the ⇧+arrow `adjust_selection` keybinds), STABLE order after the render lines.
    /// Every token is a verified libghostty value (see ``TerminalControlsConfig``); cursor colours come from
    /// `prefs` under the same "empty ⇒ skip" rule as `background` / `foreground`.
    private static func appendControls(
        _ lines: inout [String],
        controls c: TerminalControlsConfig,
        prefs: TerminalPreferences,
    ) {
        // Selection → pasteboard. `copy-on-select` is a libghostty tri-state; the bool maps ON → `clipboard`,
        // OFF → `false`.
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
        // Right-Click Action (H7/H8) — libghostty OWNS the bare-right-click dispatch. The token is the
        // `right-click-action` enum value 1:1 (`RightClickAction.rawValue` = the Zig enum names), so the
        // surface performs the action — the GUI view no longer re-reads `hasSelection()` after the surface
        // has already word-selected under the cursor (the WI-7 race). The view keeps ONLY the
        // ⌃-right-always-menu override.
        lines.append("right-click-action = \(c.rightClickActionToken)")
        // One multiplier drives BOTH precision + discrete factors, PRESERVING libghostty's native per-axis
        // ratio (precision:1, discrete:3). Emitting the SAME factor on both axes (the pre-fix bug) made
        // discrete wheel scroll 3× slower than stock at the default `m == 1.0`. So precision rides `m`,
        // discrete rides `3 × m` (PLAIN multiply — NEVER fused / `addingProduct`). Default emits
        // `precision:1,discrete:3`.
        let precision = formatSize(c.scrollMultiplier)
        let discrete = formatSize(c.scrollMultiplier * 3)
        lines.append("mouse-scroll-multiplier = precision:\(precision),discrete:\(discrete)")
        // "Option as Alt" — the macOS Option-key→Alt/Meta behaviour. Token is `macos-option-as-alt` 1:1
        // (`false`/`true`/`left`/`right`); the surface owns the key→byte encoding. Factory keeps `false`
        // (Option stays free for accented characters).
        lines.append("macos-option-as-alt = \(c.macosOptionAsAltToken)")
        // Cursor colour / text-under / opacity (render prefs). Empty colour ⇒ skip (same as background /
        // foreground); opacity always emits (numeric pref, formatted not fused).
        let cursorColor = prefs.cursorColor.trimmingCharacters(in: .whitespaces)
        if !cursorColor.isEmpty { lines.append("cursor-color = \(cursorColor)") }
        let cursorText = prefs.cursorTextColor.trimmingCharacters(in: .whitespaces)
        if !cursorText.isEmpty { lines.append("cursor-text = \(cursorText)") }
        lines.append("cursor-opacity = \(formatSize(prefs.cursorOpacity))")
        // ⇧+Arrow selection. The vendored fork binds shift+arrow → adjust_selection by DEFAULT, so the toggle
        // must EXPLICITLY (re)bind when ON and `unbind` when OFF — emitting nothing for OFF would leave the
        // default binding live and arrows would never reach the program. NEVER touch shift+cmd+arrow (the
        // caret-move passthrough).
        for dir in ["left", "right", "up", "down"] {
            let action = c.shiftArrowSelect ? "adjust_selection:\(dir)" : "unbind"
            lines.append("keybind = shift+\(dir)=\(action)")
        }
    }

    /// Split the comma-separated fallback-family string into ordered, trimmed, non-empty names — each a
    /// repeated `font-family =` line after the primary. Blank entries are dropped, so
    /// `"PingFang SC, , Symbols Nerd Font"` yields two families.
    static func fallbackFamilies(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The `true` / `false` token for a libghostty boolean config value.
    private static func boolToken(_ flag: Bool) -> String { flag ? "true" : "false" }

    /// Resolve a colour: the `override` (trimmed) if non-empty, else the `fallback` (trimmed). Lets the
    /// theme override win while an empty / absent one keeps the pref's colour.
    static func resolved(_ override: String?, or fallback: String) -> String {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback.trimmingCharacters(in: .whitespaces)
    }

    /// Format the font size without a spurious decimal / exponent: `13` for integral, `13.5` for fractional
    /// — what Ghostty's parser accepts. Mirrors ``EnvBridge/formatDouble(_:)`` so the two surfaces agree.
    static func formatSize(_ size: Double) -> String {
        if size.isFinite, size == size.rounded(), abs(size) < 1e9 {
            return String(Int(size))
        }
        return String(size)
    }
}

// MARK: - TerminalControlsConfig (the leaf, libghostty-token mirror the builder consumes)

/// The PURE, libghostty-token mirror of the fire-time terminal CONTROL knobs (E8 WI-2), defined HERE in the
/// leaf ``SlopDeskVideoProtocol`` so ``TerminalConfigBuilder`` (and its headless test) can emit the control
/// lines WITHOUT importing `SlopDeskWorkspaceCore.TerminalControls` (which carries the `Defaults`-backed
/// `from(defaults:)` factory + multi-state enums `ClipboardAccess`, `MouseShiftCapture`, …). The module
/// graph is one-way (`SlopDeskWorkspaceCore` → `SlopDeskVideoProtocol`, never the reverse — VideoProtocol
/// stays a pure wire/settings leaf with no `Defaults` dependency), so the builder's input MUST live in the
/// leaf; the embedder maps `TerminalControls` → this struct at `PreferencesStore.applyTerminal()` (bools
/// pass through; multi-state enums resolve to their token — `clipboard-read`/`clipboard-write` ←
/// `ClipboardAccess.rawValue`, `mouse-shift-capture` ← `MouseShiftCapture.configValue`).
///
/// The init defaults MIRROR `TerminalControls`' defaults, so a default value is a faithful "factory" bundle
/// and a test can vary one field at a time.
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
