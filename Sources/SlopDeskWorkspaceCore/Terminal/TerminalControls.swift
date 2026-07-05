import Defaults
import Foundation

// MARK: - E8 terminal-control enums (the Controls / Mouse / Scroll multi-state knobs)

/// A clipboard-access decision for the OSC-52 read/write gates (config keys `clipboard-read` /
/// `clipboard-write`, libghostty `allow` / `deny` / `ask`).
///
/// - ``allow``: silently honour the request.
/// - ``deny``: silently refuse it.
/// - ``ask``: surface the confirmation sheet (WI-6 reuses the paste-protection surface).
///
/// PURE `String`-raw + `CaseIterable` so it bridges to `Defaults` and the pickers can enumerate it. Raw
/// values match the libghostty config tokens 1:1, so the config builder (WI-2) emits ``RawValue``
/// directly. ``init(rawValue:)`` is validate-then-repair to ``ask`` (a stale/hostile string never traps);
/// non-failable so the `Defaults.PreferRawRepresentable` bridge works.
public enum ClipboardAccess: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
    case ask

    /// Validate-then-repair: unrecognised values repair to ``ask`` (the conservative gate), never trap.
    /// Non-failable — the `RawRepresentable` bridge relies on never returning `nil`.
    public init(rawValue: String) {
        switch rawValue {
        case "allow": self = .allow
        case "deny": self = .deny
        case "ask": self = .ask
        default: self = .ask
        }
    }

    /// The SILENT (no-dialog) resolution of an OSC-52 clipboard-READ request, as the text the embedder hands
    /// `completeClipboardRead(_:confirmed: true)` (WI-6, GUI-only). ``allow`` returns the real `text`; ``deny``
    /// returns `""` — a well-formed EMPTY reply that frees the request without leaking the clipboard (and,
    /// paired with `confirmed: true`, never re-trips libghostty's read gate, which a `confirmed: false`
    /// completion recurses on — the read contract differs from a paste's). ``ask`` returns `nil`: the embedder
    /// surfaces the confirmation sheet and maps the verdict to the same allow (`text`) / deny (`""`).
    ///
    /// PURE so the GUI-only `confirm_read_clipboard_cb` routing is unit-pinned without a surface.
    public func silentClipboardRead(text: String) -> String? {
        switch self {
        case .allow: text
        case .deny: ""
        case .ask: nil
        }
    }
}

/// What a bare right-click does in the terminal viewport (settings key `mouse.rightClickAction`).
/// ⌃+right-click always shows the context menu regardless of this setting (GUI site, WI-7).
///
/// - ``contextMenu``: show the native context menu (the default).
/// - ``copy``: copy the current selection.
/// - ``paste``: paste the clipboard.
/// - ``copyOrPaste``: copy if there is a selection, otherwise paste.
/// - ``ignore``: do nothing.
///
/// PURE `String`-raw + `CaseIterable`; CLIENT-side dispatch (no libghostty config key), so the raw values
/// are slopdesk's own kebab-case tokens. ``init(rawValue:)`` is validate-then-repair to ``contextMenu``.
public enum RightClickAction: String, Codable, Sendable, CaseIterable {
    case contextMenu = "context-menu"
    case copy
    case paste
    case copyOrPaste = "copy-or-paste"
    case ignore

    /// Validate-then-repair to ``contextMenu`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "context-menu": self = .contextMenu
        case "copy": self = .copy
        case "paste": self = .paste
        case "copy-or-paste": self = .copyOrPaste
        case "ignore": self = .ignore
        default: self = .contextMenu
        }
    }

    // NOTE: the LIVE bare-right-click dispatch is owned END-TO-END by libghostty — the config builder (WI-2)
    // emits this action's ``rawValue`` as `right-click-action`, so the libghostty-based surface performs
    // Copy / Paste / Copy-or-Paste / Ignore / Context-Menu directly. That avoids the GUI re-reading
    // `hasSelection()` AFTER libghostty has already word-selected under the cursor (the WI-7 race). The GUI
    // view (`rightMouseDown`, compile-only behind `#if canImport(CGhostty)`) enforces ONLY the
    // ⌃-right-always-menu override; there is no client-side effect model to keep in sync.
}

/// Overscroll behaviour past the LAST line of content ("Scroll Past Last Line", default Disabled).
/// Suppressed on the alternate screen (`ScrollPastPolicy`, WI-12, returns `nil` there so full-screen TUIs
/// keep their bottom edge).
///
/// - ``disabled``: clamp at the buffer bottom (the default).
/// - ``lastLineWithContent``: the bottom-most content row lands at the viewport top.
/// - ``lastLineInMiddle``: that row lands at the vertical centre.
/// - ``cursorLine``: the cursor row lands at the top, even if it is on a blank line.
///
/// PURE `String`-raw + `CaseIterable`; CLIENT-side render policy (no libghostty key).
/// ``init(rawValue:)`` is validate-then-repair to ``disabled``.
public enum ScrollPastLast: String, Codable, Sendable, CaseIterable {
    case disabled
    case lastLineWithContent = "last-line-with-content"
    case lastLineInMiddle = "last-line-in-middle"
    case cursorLine = "cursor-line"

    /// Validate-then-repair to ``disabled`` (clamp), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "last-line-with-content": self = .lastLineWithContent
        case "last-line-in-middle": self = .lastLineInMiddle
        case "cursor-line": self = .cursorLine
        default: self = .disabled
        }
    }
}

/// Overscroll behaviour past the FIRST (oldest) line of scrollback ("Scroll Past First Line", default
/// Disabled). Symmetric with ``ScrollPastLast``.
///
/// - ``disabled``: clamp at the scrollback top (the default).
/// - ``sameAsLast``: mirror the ``ScrollPastLast`` setting.
/// - ``firstLineWithContent``: the topmost history row lands at the viewport bottom.
/// - ``firstLineInMiddle``: that row lands at the vertical centre.
///
/// PURE `String`-raw + `CaseIterable`; CLIENT-side render policy (no libghostty key).
/// ``init(rawValue:)`` is validate-then-repair to ``disabled``.
public enum ScrollPastFirst: String, Codable, Sendable, CaseIterable {
    case disabled
    case sameAsLast = "same-as-last"
    case firstLineWithContent = "first-line-with-content"
    case firstLineInMiddle = "first-line-in-middle"

    /// Validate-then-repair to ``disabled`` (clamp), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "same-as-last": self = .sameAsLast
        case "first-line-with-content": self = .firstLineWithContent
        case "first-line-in-middle": self = .firstLineInMiddle
        default: self = .disabled
        }
    }
}

/// Whether ⇧+click / ⇧+drag bypasses a program's mouse capture to make a native selection ("Allow Shift
/// with Mouse Click", libghostty `mouse-shift-capture`).
///
/// - ``disabled``: never bypass (program always captures).
/// - ``enabled``: ⇧ bypasses capture for that one gesture (the default).
/// - ``always``: ⇧ is always consumed for selection.
/// - ``never``: ⇧ is never consumed for selection (always forwarded to the program).
///
/// PURE `String`-raw + `CaseIterable`. Raw values are slopdesk's own semantic tokens; the libghostty
/// token (`false` / `true` / `always` / `never`) is exposed separately as ``configValue`` so persistence
/// stays readable. ``init(rawValue:)`` is validate-then-repair to ``enabled`` (default).
public enum MouseShiftCapture: String, Codable, Sendable, CaseIterable {
    case disabled
    case enabled
    case always
    case never

    /// Validate-then-repair to ``enabled`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "enabled": self = .enabled
        case "always": self = .always
        case "never": self = .never
        default: self = .enabled
        }
    }

    /// The libghostty `mouse-shift-capture` token this case maps to. Consumed by the config builder (WI-2);
    /// kept next to the enum and unit-pinned.
    ///
    /// **The mapping is INVERTED on purpose**: this enum's axis ("⇧ *selects text* even when the app captures
    /// the mouse") is the opposite of libghostty's `mouse-shift-capture` axis (whether ⇧ is *captured into the
    /// mouse protocol and sent to the program*). Per the vendored ghostty `Config.zig`: `false` = ⇧ NOT sent,
    /// EXTENDS THE SELECTION (libghostty default, program may override via `XTSHIFTESCAPE`); `true` = ⇧ sent to
    /// the program (overridable); `never` = `false` but program CANNOT override; `always` = `true` but program
    /// CANNOT override. So "⇧ selects" (ON) → the *don't-capture* tokens, "⇧ to program" (OFF) → the *capture*
    /// tokens:
    ///
    /// - ``enabled`` (default — ⇧ extends selection, soft) → `false` — matches libghostty's own default, so
    ///   the factory terminal honours rather than overrides it.
    /// - ``disabled`` (⇧ goes to the program, soft) → `true`.
    /// - ``always`` (⇧ ALWAYS extends selection, program can't override) → `never`.
    /// - ``never`` (⇧ NEVER extends selection / always forwarded to the program) → `always`.
    public var configValue: String {
        switch self {
        case .disabled: "true"
        case .enabled: "false"
        case .always: "never"
        case .never: "always"
        }
    }

    /// Whether ⇧ EXTENDS THE SELECTION — the ON state of the binary "Allow Shift with Mouse Click" toggle.
    /// The Settings UI is a simple ON/OFF (not the 4-way enum), so a value from the removed 4-way picker
    /// projects onto that axis: ``enabled`` / ``always`` read ON, ``disabled`` / ``never`` read OFF. Without
    /// this a stale ``always`` would mis-read as OFF against a bare `== .enabled` check.
    public var extendsSelection: Bool {
        switch self {
        case .enabled,
             .always: true
        case .disabled,
             .never: false
        }
    }
}

/// How the macOS Option key is treated for terminal input ("Option as Alt", libghostty
/// `macos-option-as-alt`, default ``off``). The client renders with libghostty, so key→byte encoding
/// happens in the local surface — a real, reachable knob the builder (WI-2) emits.
///
/// - ``off``: Option composes accented characters (¡, é, ©…) as normal — libghostty `false`.
/// - ``both``: BOTH Option keys send Alt/Meta (Esc-prefixed) sequences — libghostty `true`.
/// - ``left`` / ``right``: only the named Option key sends Alt/Meta; the other still composes.
///
/// PURE `String`-raw + `CaseIterable`. Raw values are slopdesk's own kebab tokens (NOT libghostty's —
/// `both` persists as `both`, not `true`); the libghostty token is exposed separately as ``configValue``.
/// ``init(rawValue:)`` is validate-then-repair to ``off`` (default); non-failable for the `Defaults` bridge.
public enum OptionAsAlt: String, Codable, Sendable, CaseIterable {
    case off
    case both
    case left
    case right

    /// Validate-then-repair to ``off`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "both": self = .both
        case "left": self = .left
        case "right": self = .right
        default: self = .off
        }
    }

    /// The libghostty `macos-option-as-alt` token this case maps to (values `false` / `true` / `left` /
    /// `right` — see the vendored ghostty `input/config.zig` `OptionAsAlt`). Consumed by the config builder
    /// (WI-2); kept next to the enum and unit-pinned. ``both`` → `true`, ``off`` → `false`.
    public var configValue: String {
        switch self {
        case .off: "false"
        case .both: "true"
        case .left: "left"
        case .right: "right"
        }
    }
}

// MARK: - E10 link-interaction enums (Settings → Controls → Open With / Link Schemes)

/// What a `⌘`click on a detected link / path does (settings key `link-cmd-click`, default ``open``).
///
/// - ``open``: open in the best handler — a file / folder opens or reveals on the HOST (over the E4
///   metadata RPC, E10 WI-7), a URL opens in the client's system browser.
/// - ``copy``: copy the resolved absolute path / URL to the client pasteboard.
/// - ``nothing``: do nothing (reach links via the right-click menu / Jump-To / Hint Mode) — the escape
///   hatch when ⌘click conflicts with a TUI.
///
/// PURE `String`-raw + `CaseIterable`; CLIENT-side dispatch token (no libghostty config key), so raw
/// values are slopdesk's own tokens. ``init(rawValue:)`` is validate-then-repair to ``open`` (default);
/// non-failable for the `Defaults` bridge.
public enum LinkCmdClick: String, Codable, Sendable, CaseIterable {
    case open
    case copy
    case nothing

    /// Validate-then-repair to ``open`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "copy": self = .copy
        case "nothing": self = .nothing
        default: self = .open
        }
    }
}

/// What a `⌘⇧`click on a detected link / path does (settings key `link-cmd-shift-click`, default
/// ``revealFinder``).
///
/// - ``revealFinder``: reveal the path in the HOST Finder (`open -R`-equivalent over the metadata RPC,
///   E10 WI-7); a URL has no Finder target, so the click copies it instead.
/// - ``openSystemDefault``: open the path / URL with the HOST's system-default handler.
///
/// PURE `String`-raw + `CaseIterable`; CLIENT-side dispatch token. ``init(rawValue:)`` is
/// validate-then-repair to ``revealFinder`` (default).
public enum LinkCmdShiftClick: String, Codable, Sendable, CaseIterable {
    case revealFinder = "reveal-finder"
    case openSystemDefault = "open-system-default"

    /// Validate-then-repair to ``revealFinder`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "reveal-finder": self = .revealFinder
        case "open-system-default": self = .openSystemDefault
        default: self = .revealFinder
        }
    }
}

/// Which URL schemes are auto-detected / underlined on `⌘`-hover ("Auto-Detect Link Schemes", default
/// ``all``). `http(s)`, `file`, and `mailto` are ALWAYS detected regardless of this mode (hard-coded — see
/// ``LinkSchemePolicy``); this only governs OTHER `scheme://…` forms.
///
/// - ``all``: detect ANY `scheme://…`.
/// - ``custom``: detect only the always-on schemes plus ``SettingsKey/customLinkSchemes``.
///
/// PURE `String`-raw + `CaseIterable`; CLIENT-side persistence token. ``init(rawValue:)`` is
/// validate-then-repair to ``all`` (default). Bridged to the richer ``LinkSchemePolicy`` by
/// ``SettingsKey/linkSchemePolicy``.
public enum AutoDetectLinkSchemes: String, Codable, Sendable, CaseIterable {
    case all
    case custom

    /// Validate-then-repair to ``all`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "custom": self = .custom
        default: self = .all
        }
    }
}

// MARK: - TerminalControls (the fire-time control bundle the config builder consumes)

/// The pure, headless bundle of E8 terminal CONTROL values the libghostty config builder (WI-2) turns into
/// `copy-on-select` / `clipboard-*` / `mouse-*` config lines (+ the ⇧+arrow `adjust_selection` keybinds).
/// Controls sibling of ``TerminalPreferences`` (render prefs) — the two are independent inputs to
/// `TerminalConfigBuilder.string(...)`, NOT nested: the builder emits render lines from
/// ``TerminalPreferences`` and control lines from this struct.
///
/// Every field derives from a fire-time `Defaults.Keys` flag (in `SettingsKey`), so this bundle never
/// reaches the `EnvConfig` overlay or the `video-prefs.json` sidecar — golden-safe by construction, like
/// the E7 stubs. ``from(defaults:)`` is the single read site (`PreferencesStore.applyTerminal` rebuilds it
/// on every apply / `refreshTerminalControls()`), so the init defaults mirror the `Defaults.Keys` defaults
/// and a default-constructed value is a faithful "factory" terminal.
///
/// PURE `Codable + Sendable + Equatable` — no SwiftUI/AppKit — so `TerminalControlsTests` pins the factory
/// + enum round-trips with no view.
public struct TerminalControls: Codable, Sendable, Equatable {
    /// The `copy-on-select` config line — copy the selection to the pasteboard as soon as it is made
    /// (default OFF). The builder emits `clipboard` when on, `false` when off.
    public var copyOnSelect: Bool
    /// The `clipboard-trim-trailing-spaces` config line — strip trailing whitespace from each copied line
    /// (default ON).
    public var trimTrailing: Bool
    /// The `selection-clear-on-typing` config line — clear the selection when the user types (default ON).
    public var clearOnTyping: Bool
    /// The `selection-clear-on-copy` config line — clear the selection after an explicit copy (default OFF).
    public var clearOnCopy: Bool
    /// The `clipboard-paste-protection` config line — warn before pasting unsafe text (default ON).
    public var pasteProtection: Bool
    /// The `clipboard-paste-bracketed-safe` config line — treat bracketed paste as safe (skips the warning
    /// when the program advertised `?2004h`) (default ON).
    public var bracketedSafe: Bool
    /// The `clipboard-read` config line — the OSC-52 clipboard-READ access gate (default ``ClipboardAccess/ask``).
    public var clipboardRead: ClipboardAccess
    /// The `clipboard-write` config line — the OSC-52 clipboard-WRITE access gate (default ``ClipboardAccess/allow``).
    public var clipboardWrite: ClipboardAccess
    /// The `mouse-hide-while-typing` config line — hide the pointer while typing (default ON).
    public var hideMouseWhileTyping: Bool
    /// The `mouse-shift-capture` config line — whether ⇧ bypasses a program's mouse capture for a native
    /// selection (default ``MouseShiftCapture/enabled``).
    public var allowShiftClick: MouseShiftCapture
    /// The `cursor-click-to-move` config line — click in the prompt to move the shell cursor (default ON).
    public var clickToMove: Bool
    /// The `mouse-reporting` config line — allow programs (vim, tmux, htop) to capture mouse events (default ON).
    public var allowMouseCapture: Bool
    /// The `mouse.rightClickAction` settings key (H7/H8) — what a bare right-click does in the viewport (default
    /// ``RightClickAction/contextMenu``). The config builder (WI-2) emits its `rawValue` as libghostty's
    /// `right-click-action` so libghostty owns the dispatch; the GUI view keeps only the ⌃-right-always-menu
    /// override.
    public var rightClickAction: RightClickAction
    /// "Shift+Arrow Select" — ⇧+arrows drive native selection (emits four `adjust_selection` keybinds)
    /// instead of forwarding the arrow escapes to the program (default ON).
    public var shiftArrowSelect: Bool
    /// The `mouse-scroll-multiplier` config line — multiply the scroll-wheel delta (default `1.0`).
    public var scrollMultiplier: Double
    /// "Option as Alt" — whether the macOS Option key sends Alt/Meta (Esc-prefixed) sequences
    /// (default ``OptionAsAlt/off``, libghostty `macos-option-as-alt`). The config builder (WI-2) emits its
    /// ``OptionAsAlt/configValue`` as `macos-option-as-alt`; the client's libghostty surface owns the
    /// key→byte encoding, so this is a real, reachable knob.
    public var optionAsAlt: OptionAsAlt

    public init(
        copyOnSelect: Bool = false,
        trimTrailing: Bool = true,
        clearOnTyping: Bool = true,
        clearOnCopy: Bool = false,
        pasteProtection: Bool = true,
        bracketedSafe: Bool = true,
        clipboardRead: ClipboardAccess = .ask,
        clipboardWrite: ClipboardAccess = .allow,
        hideMouseWhileTyping: Bool = true,
        allowShiftClick: MouseShiftCapture = .enabled,
        clickToMove: Bool = true,
        allowMouseCapture: Bool = true,
        rightClickAction: RightClickAction = .contextMenu,
        shiftArrowSelect: Bool = true,
        scrollMultiplier: Double = 1.0,
        optionAsAlt: OptionAsAlt = .off,
    ) {
        self.copyOnSelect = copyOnSelect
        self.trimTrailing = trimTrailing
        self.clearOnTyping = clearOnTyping
        self.clearOnCopy = clearOnCopy
        self.pasteProtection = pasteProtection
        self.bracketedSafe = bracketedSafe
        self.clipboardRead = clipboardRead
        self.clipboardWrite = clipboardWrite
        self.hideMouseWhileTyping = hideMouseWhileTyping
        self.allowShiftClick = allowShiftClick
        self.clickToMove = clickToMove
        self.allowMouseCapture = allowMouseCapture
        self.rightClickAction = rightClickAction
        self.shiftArrowSelect = shiftArrowSelect
        self.scrollMultiplier = scrollMultiplier
        self.optionAsAlt = optionAsAlt
    }

    /// Read the live control bundle from the persisted fire-time `Defaults.Keys` flags. Reading through the
    /// typed-key subscript (`defaults[.copyOnSelect]`) lets an injected suite isolate the factory in tests
    /// while production passes `.standard`. Each missing key falls back to its `Defaults.Key` default
    /// (mirrored by this struct's init defaults).
    public static func from(defaults: UserDefaults = .standard) -> Self {
        // E14/K12: the "Clipboard — Shell Controlled" master switch (default ON) gates the WHOLE OSC-52 path
        // ahead of the per-direction Ask/Allow/Deny gate. When OFF, read + write resolve to `.deny`, so the
        // builder emits `clipboard-read/write = deny` and no remote OSC-52 reaches the gate.
        let clipboardShellControlled = defaults[.clipboardShellControlled]
        return Self(
            copyOnSelect: defaults[.copyOnSelect],
            trimTrailing: defaults[.trimTrailingSpacesOnCopy],
            clearOnTyping: defaults[.clearSelectionOnTyping],
            clearOnCopy: defaults[.clearSelectionOnCopy],
            pasteProtection: defaults[.pasteProtection],
            bracketedSafe: defaults[.pasteBracketedSafe],
            clipboardRead: clipboardShellControlled ? defaults[.clipboardRead] : .deny,
            clipboardWrite: clipboardShellControlled ? defaults[.clipboardWrite] : .deny,
            hideMouseWhileTyping: defaults[.mouseHideWhileTyping],
            allowShiftClick: defaults[.allowShiftClick],
            clickToMove: defaults[.clickToMove],
            allowMouseCapture: defaults[.allowMouseCapture],
            rightClickAction: defaults[.rightClickAction],
            shiftArrowSelect: defaults[.shiftArrowSelect],
            scrollMultiplier: defaults[.scrollMultiplier],
            optionAsAlt: defaults[.optionAsAlt],
        )
    }
}
