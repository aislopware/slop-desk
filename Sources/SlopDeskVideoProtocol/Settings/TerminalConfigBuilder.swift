import CSlopDeskFFI

/// The Swift face of `rust/slopdesk-terminal`'s `config`, reached through the door of the same name.
///
/// libghostty's `ghostty_config_load_string` accepts the same newline-separated `key = value` syntax as
/// `~/.config/ghostty/config`. `GhosttyTerminalView` feeds ``string(for:)``'s output through it BEFORE
/// `ghostty_config_finalize`, so a font / theme / cursor change applies live (the host PTY grid is
/// re-measured and resized after the reflow).
///
/// What stays HERE is the crossing and nothing else. Every preference that is an enum on this side —
/// the ligature mode, the two face modes, the blending mode, the cursor style and its blink tri-state —
/// crosses as the RAW VALUE it persists as, and the far side decides which libghostty key that
/// actuates. The one resolved value that crosses as a number is the cell-height percent, because
/// ``LineHeightMode/adjustCellHeightPercent`` has a second reader on this side (`CodeFontSync`); the
/// clamp and the formatting of it are the far side's.
///
/// The record's runs — two dozen of them — ride in one blob lent to the door, and the two lists (the
/// user's keybind lines, the theme's sixteen palette entries) ride as their own arrays of runs rather
/// than as one delimited blob: a delimiter is a thing a value could contain and a count is not. The
/// answer is asked for twice, as every text door here is: measure, then fill.
public enum TerminalConfigBuilder {
    /// Build the libghostty config string for `prefs`.
    ///
    /// `backgroundOverride` / `foregroundOverride` (6-hex, no `#`) — a non-empty value REPLACES the
    /// pref's own `background`/`foreground`; the seam the active THEME drives (``PreferencesStore``
    /// passes `terminalBackgroundHex`/`terminalForegroundHex`). `paletteOverride` — the theme's
    /// 16-entry ANSI palette, emitted only when every entry is clean 6-hex.
    /// `selectionBackgroundOverride` — same validation, one line. `controls` — non-nil APPENDS the
    /// control passthrough block after the render lines; `nil` reproduces the base output
    /// byte-for-byte.
    public static func string(
        for prefs: TerminalPreferences,
        keybinds: [String] = [],
        backgroundOverride: String? = nil,
        foregroundOverride: String? = nil,
        paletteOverride: [String]? = nil,
        selectionBackgroundOverride: String? = nil,
        controls: TerminalControlsConfig? = nil,
    ) -> String {
        var blob = Blob()
        let percent = prefs.lineHeight.adjustCellHeightPercent
        let font = SlopDeskTerminalFont(
            family: blob.run(prefs.fontFamily),
            fallback: blob.run(prefs.fontFamilyFallback),
            weight: blob.run(prefs.fontWeight),
            family_bold: blob.run(prefs.fontFamilyBold),
            family_italic: blob.run(prefs.fontFamilyItalic),
            family_bold_italic: blob.run(prefs.fontFamilyBoldItalic),
            ligatures: blob.run(prefs.fontLigatures.rawValue),
            bold: blob.run(prefs.fontBold.rawValue),
            italic: blob.run(prefs.fontItalic.rawValue),
            blending: blob.run(prefs.fontBlending.rawValue),
            size: prefs.fontSize,
            cell_height_percent: percent ?? 0,
            auto_match_weight_style: prefs.autoMatchWeightStyle,
            ligatures_alphabet: prefs.fontLigaturesAlphabet,
            has_cell_height: percent != nil,
        )
        let colors = SlopDeskTerminalColors(
            theme: blob.run(prefs.theme),
            background: blob.run(prefs.background),
            foreground: blob.run(prefs.foreground),
            background_override: blob.run(backgroundOverride ?? ""),
            foreground_override: blob.run(foregroundOverride ?? ""),
            selection_background: blob.run(selectionBackgroundOverride ?? ""),
        )
        let cursor = SlopDeskTerminalCursor(
            style: blob.run(prefs.cursorStyle.rawValue),
            blink: blob.run(prefs.cursorBlink.rawValue),
            color: blob.run(prefs.cursorColor),
            text_color: blob.run(prefs.cursorTextColor),
            opacity: prefs.cursorOpacity,
        )
        let record = SlopDeskTerminalConfig(
            font: font,
            colors: colors,
            cursor: cursor,
            controls: controlsRecord(controls, &blob),
            scrollback_lines: Int64(prefs.scrollbackLines),
            has_controls: controls != nil,
        )
        let keybindRuns = keybinds.map { blob.run($0) }
        let paletteRuns = (paletteOverride ?? []).map { blob.run($0) }
        return built(record, blob.bytes, keybindRuns, paletteRuns)
    }

    /// The control block's crossing form, or an all-zero one when there is no block — the `has_controls`
    /// flag, not this record, is what decides whether any of it is read.
    private static func controlsRecord(
        _ controls: TerminalControlsConfig?,
        _ blob: inout Blob,
    ) -> SlopDeskTerminalControls {
        guard let controls else { return SlopDeskTerminalControls() }
        return SlopDeskTerminalControls(
            clipboard_read: blob.run(controls.clipboardReadToken),
            clipboard_write: blob.run(controls.clipboardWriteToken),
            mouse_shift_capture: blob.run(controls.mouseShiftCaptureToken),
            right_click_action: blob.run(controls.rightClickActionToken),
            macos_option_as_alt: blob.run(controls.macosOptionAsAltToken),
            scroll_multiplier: controls.scrollMultiplier,
            copy_on_select: controls.copyOnSelect,
            trim_trailing: controls.trimTrailing,
            clear_on_typing: controls.clearOnTyping,
            clear_on_copy: controls.clearOnCopy,
            paste_protection: controls.pasteProtection,
            bracketed_safe: controls.bracketedSafe,
            hide_mouse_while_typing: controls.hideMouseWhileTyping,
            click_to_move: controls.clickToMove,
            allow_mouse_capture: controls.allowMouseCapture,
            shift_arrow_select: controls.shiftArrowSelect,
        )
    }

    /// The text the door spells for one record: measure, then fill.
    private static func built(
        _ record: SlopDeskTerminalConfig,
        _ text: [UInt8],
        _ keybinds: [SlopDeskConfigRun],
        _ palette: [SlopDeskConfigRun],
    ) -> String {
        // An empty config on the truncated branch is the same answer ``lentText`` gives everywhere:
        // half a terminal configuration is worse than none.
        text.withUnsafeBufferPointer { blob in
            keybinds.withUnsafeBufferPointer { binds in
                palette.withUnsafeBufferPointer { entries in
                    lentText { out, cap in
                        slopdesk_terminal_config_string(
                            record, blob.baseAddress, blob.count,
                            binds.baseAddress, binds.count, entries.baseAddress, entries.count,
                            out, cap,
                        )
                    }
                }
            }
        }
    }

    /// A byte pool that answers, for each string interned, WHERE it landed — so a record carries
    /// `(offset, length)` pairs rather than pointers, and no field makes the far side own a lifetime.
    private struct Blob {
        var bytes: [UInt8] = []

        mutating func run(_ text: String) -> SlopDeskConfigRun {
            let encoded = Array(text.utf8)
            let run = SlopDeskConfigRun(offset: UInt32(bytes.count), length: UInt32(encoded.count))
            bytes.append(contentsOf: encoded)
            return run
        }
    }
}

// MARK: - TerminalControlsConfig (the leaf, libghostty-token mirror the builder consumes)

/// The PURE, libghostty-token mirror of the fire-time terminal CONTROL knobs, defined HERE in the
/// leaf ``SlopDeskVideoProtocol`` so ``TerminalConfigBuilder`` (and its headless test) can carry the control
/// settings WITHOUT importing `SlopDeskWorkspaceCore.TerminalControls` (which carries the `Defaults`-backed
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
    /// Copy-on-Select — ON → libghostty `copy-on-select = clipboard`, OFF → `false`.
    public var copyOnSelect: Bool
    /// Trim-Trailing-Spaces — `clipboard-trim-trailing-spaces`.
    public var trimTrailing: Bool
    /// Clear-Selection-on-Typing — `selection-clear-on-typing`.
    public var clearOnTyping: Bool
    /// Clear-Selection-on-Copy — `selection-clear-on-copy`.
    public var clearOnCopy: Bool
    /// Paste-Protection — `clipboard-paste-protection`.
    public var pasteProtection: Bool
    /// Paste-Bracketed-Safe — `clipboard-paste-bracketed-safe`.
    public var bracketedSafe: Bool
    /// OSC-52 READ access token — emitted verbatim as `clipboard-read` (libghostty `allow`/`deny`/`ask`).
    public var clipboardReadToken: String
    /// OSC-52 WRITE access token — emitted verbatim as `clipboard-write`.
    public var clipboardWriteToken: String
    /// Hide-Mouse-When-Typing — `mouse-hide-while-typing`.
    public var hideMouseWhileTyping: Bool
    /// Allow-Shift-with-Mouse-Click token — emitted verbatim as `mouse-shift-capture`
    /// (libghostty `false`/`true`/`always`/`never`).
    public var mouseShiftCaptureToken: String
    /// Cursor-Click-to-Move — `cursor-click-to-move`.
    public var clickToMove: Bool
    /// Allow-Mouse-Capture — `mouse-reporting`.
    public var allowMouseCapture: Bool
    /// Right-Click Action token — emitted verbatim as `right-click-action` so libghostty owns the
    /// bare-right-click dispatch (libghostty `ignore`/`paste`/`copy`/`copy-or-paste`/`context-menu`, default
    /// `context-menu`). The GUI view keeps only the ⌃-right-always-menu override.
    public var rightClickActionToken: String
    /// Shift+Arrow-Select — ON emits four `shift+<dir>=adjust_selection:<dir>` keybinds; OFF emits
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
