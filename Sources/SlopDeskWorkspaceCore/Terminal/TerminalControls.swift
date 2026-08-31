// TerminalControls — the near-side FACE of `slopdesk_terminal::controls`, plus the fire-time bundle
// the terminal config builder consumes.
//
// Each of the eight vocabularies below is the same shape: a small closed set, a stored spelling per
// case, and a repair for a token this build does not know. So each crosses TWICE — one delivery of
// the whole table in declaration order, read once per process, and one door that repairs an
// arbitrary stored token to a code. A door per case would be forty crossings for eight enumerations
// whose members are known at compile time on both sides.
//
// ⚠️ THREE OF THEM CARRY A SECOND SPELLING — the value written into the terminal's own config, which
// is inverted or renamed for reasons the rule module documents — and those tables deliver the PAIR.
// That is the whole reason the config value crosses at all: `disabled → "true"` is exactly the
// transcription nobody would reproduce correctly twice, and it was already spelled once here and
// once in a Zig-facing comment.
//
// The enums keep `RawRepresentable` by hand rather than `: String`, because a `: String` enum's raw
// values ARE the literals — writing them here would put the stored vocabulary back in a second
// place, which is the drift the crossing removes. `Codable` is the same story one layer up: it
// encodes and decodes the raw value, so it goes through the same table.

import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol // AppConfig — every field below is a `[controls]` row
import SlopDeskWorkspaceModel

// MARK: - The token tables, read once per process

/// One vocabulary's stored spellings, in the far side's own `ALL` order.
///
/// Three of the tables carry a `configValue` beside each token; the other five do not, and asking
/// one of those for a config value is a programming error rather than a missing string, so the
/// accessor is only offered on the two enums that have one.
private enum ControlTokens {
    static let clipboard: [String] = runs(3) { out, cap in
        Int(slopdesk_terminal_clipboard_tokens(out, cap))
    }

    static let rightClick: [String] = runs(5) { out, cap in
        Int(slopdesk_terminal_right_click_tokens(out, cap))
    }

    /// Token then config value, per case.
    static let mouseShift: [String] = runs(8) { out, cap in
        Int(slopdesk_terminal_mouse_shift_tokens(out, cap))
    }

    /// Token then config value, per case.
    static let optionAsAlt: [String] = runs(8) { out, cap in
        Int(slopdesk_terminal_option_as_alt_tokens(out, cap))
    }

    static let schemeDetection: [String] = runs(2) { out, cap in
        Int(slopdesk_terminal_scheme_detection_tokens(out, cap))
    }

    /// ⌘-click's three, then ⌘⇧-click's two — one delivery, because the two settings are drawn as
    /// one pair of rows and neither is read alone.
    static let linkClick: [String] = runs(5) { out, cap in
        Int(slopdesk_terminal_link_click_tokens(out, cap))
    }

    private static func runs(_ count: Int, _ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> [String] {
        wsRuns(wsAnswerBytes(door), count: count)
    }
}

/// Repairs a stored token through `door` and lands on the case at the code it answers.
private func repaired<Case>(
    _ token: String, _ cases: [Case], _ door: (UnsafePointer<UInt8>?, Int) -> UInt8,
) -> Case {
    let bytes = Array(token.utf8)
    let code = Int(bytes.withUnsafeBufferPointer { lent in door(lent.baseAddress, lent.count) })
    // The far side repairs an unknown token to each vocabulary's own default, so a code past the end
    // can only mean this build is older than the crate — take the default rather than trap.
    return cases.indices.contains(code) ? cases[code] : cases[0]
}

// MARK: - Terminal-control enums (the Controls / Mouse / Scroll multi-state knobs)

/// A clipboard-access decision for the OSC-52 read/write gates (config keys `clipboard-read` /
/// `clipboard-write`, `allow` / `deny` / `ask`).
///
/// ⚠️ The READ arm's OSC-52 subject is gone: `libghostty-vt` documents OSC-52 read requests (`?`) as
/// "always ignored and never forwarded", so no program can ask and there is nothing left to gate on
/// that path (`DECISIONS.md`). The `clipboard-read` setting stays live regardless — it now governs
/// only the metadata clipboard-read channel (verbs the host answers, a different path), not OSC-52.
///
/// - ``allow``: silently honour the request.
/// - ``deny``: silently refuse it.
/// - ``ask``: surface the confirmation sheet (reuses the paste-protection surface).
///
/// ``init(rawValue:)`` is validate-then-repair to ``ask`` (a stale/hostile string never traps);
/// non-failable so the `Defaults.PreferRawRepresentable` bridge works.
public enum ClipboardAccess: Sendable, CaseIterable, RawRepresentable, Codable {
    case allow
    case deny
    case ask

    public var rawValue: String { ControlTokens.clipboard[index] }

    /// Validate-then-repair: unrecognised values repair to ``ask`` (the conservative gate), never trap.
    /// Non-failable — the `RawRepresentable` bridge relies on never returning `nil`.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_clipboard_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// ⚠️ NOTHING SHIPPING CALLS THIS ANY MORE — its OSC-52 clipboard-READ subject is gone (see the
    /// type doc's ⚠️). Kept, unit-tested only, as the SILENT (no-dialog) resolution the deleted fork's
    /// embedder handed `completeClipboardRead(_:confirmed: true)`: ``allow`` returns the real `text`;
    /// ``deny`` returns `""` — a well-formed EMPTY reply that frees the request without leaking the
    /// clipboard (and, paired with `confirmed: true`, never re-trips the fork's read gate, which a
    /// `confirmed: false` completion recursed on — the read contract differed from a paste's). ``ask``
    /// returns `nil`: the embedder surfaces the confirmation sheet and maps the verdict to the same
    /// allow (`text`) / deny (`""`).
    public func silentClipboardRead(text: String) -> String? {
        let bytes = Array(text.utf8)
        let blob = bytes.withUnsafeBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_terminal_clipboard_silent_read(
                    UInt8(index), lent.baseAddress, lent.count, out, cap,
                ))
            }
        }
        // A `0` answer is "the caller must ASK" — the sheet is the near side's to raise, either way.
        return blob.isEmpty ? nil : wsRuns(blob, count: 1)[0]
    }

    var index: Int {
        switch self {
        case .allow: 0
        case .deny: 1
        case .ask: 2
        }
    }
}

/// What a bare right-click does in the terminal viewport (settings key `mouse.rightClickAction`).
/// ⌃+right-click always shows the context menu regardless of this setting (GUI site).
///
/// - ``contextMenu``: show the native context menu (the default).
/// - ``copy``: copy the current selection.
/// - ``paste``: paste the clipboard.
/// - ``copyOrPaste``: copy if there is a selection, otherwise paste.
/// - ``ignore``: do nothing.
///
/// CLIENT-side dispatch (no engine-native vocabulary of its own), so the tokens are slopdesk's own
/// kebab-case ones. ``init(rawValue:)`` is validate-then-repair to ``contextMenu``.
public enum RightClickAction: Sendable, CaseIterable, RawRepresentable, Codable {
    case contextMenu
    case copy
    case paste
    case copyOrPaste
    case ignore

    public var rawValue: String { ControlTokens.rightClick[index] }

    /// Validate-then-repair to ``contextMenu`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_right_click_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var index: Int {
        switch self {
        case .contextMenu: 0
        case .copy: 1
        case .paste: 2
        case .copyOrPaste: 3
        case .ignore: 4
        }
    }

    // NOTE: the deleted fork's bare-right-click dispatch was owned END-TO-END by its libghostty embedder
    // — the config builder emitted this action's ``rawValue`` as `right-click-action`, and the
    // libghostty-based surface performed Copy / Paste / Copy-or-Paste / Ignore / Context-Menu directly.
    // That avoided the GUI re-reading `hasSelection()` AFTER libghostty had already word-selected under
    // the cursor (a race), and its `rightMouseDown` (compile-only behind `#if canImport(CGhostty)`)
    // enforced ONLY the ⌃-right-always-menu override.
    //
    // ⚠️ `libghostty-vt` has no UI of its own, so it cannot own this end-to-end the way the fork did:
    // `MacTerminalRendererView.rightMouseDown` forwards the click through `driver.sendMouse` and, when
    // the engine does not consume it, falls through to AppKit's own `menu(for:)` / ``TerminalContextMenu``
    // — this config value's live consumer is worth re-checking against that path rather than assumed.
}

/// Whether ⇧+click / ⇧+drag bypasses a program's mouse capture to make a native selection ("Allow Shift
/// with Mouse Click", libghostty `mouse-shift-capture`).
///
/// - ``disabled``: never bypass (program always captures).
/// - ``enabled``: ⇧ bypasses capture for that one gesture (the default).
/// - ``always``: ⇧ is always consumed for selection.
/// - ``never``: ⇧ is never consumed for selection (always forwarded to the program).
///
/// The tokens are slopdesk's own semantic ones; the libghostty token (`false` / `true` / `always` /
/// `never`) rides beside each as ``configValue`` so persistence stays readable.
public enum MouseShiftCapture: Sendable, CaseIterable, RawRepresentable, Codable {
    case disabled
    case enabled
    case always
    case never

    public var rawValue: String { ControlTokens.mouseShift[index * 2] }

    /// Validate-then-repair to ``enabled`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            UInt8(truncatingIfNeeded: slopdesk_terminal_mouse_shift_from_token(token, len))
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The libghostty `mouse-shift-capture` token this case maps to. Consumed by the config builder.
    ///
    /// **The mapping is INVERTED on purpose**: this enum's axis ("⇧ *selects text* even when the app captures
    /// the mouse") is the opposite of libghostty's `mouse-shift-capture` axis (whether ⇧ is *captured into the
    /// mouse protocol and sent to the program*). Per the deleted fork's vendored ghostty `Config.zig`: `false` = ⇧ NOT sent,
    /// EXTENDS THE SELECTION (libghostty default, program may override via `XTSHIFTESCAPE`); `true` = ⇧ sent to
    /// the program (overridable); `never` = `false` but program CANNOT override; `always` = `true` but program
    /// CANNOT override.
    public var configValue: String { ControlTokens.mouseShift[index * 2 + 1] }

    /// Whether ⇧ EXTENDS THE SELECTION — the ON state of the binary "Allow Shift with Mouse Click" toggle.
    /// The stored value is a four-way enum but the reading is a binary axis, so ``enabled`` / ``always``
    /// read ON and ``disabled`` / ``never`` read OFF. Without this a stale ``always`` would mis-read as
    /// OFF against a bare `== .enabled` check — which is why it is a RULE and not a comparison.
    ///
    /// It rides bit 8 of the same repair the token lookup uses: a stored token is resolved exactly
    /// when a shift-drag has to be routed, so both readings are wanted at the same moment.
    public var extendsSelection: Bool {
        let bytes = Array(rawValue.utf8)
        let packed = bytes.withUnsafeBufferPointer { lent in
            slopdesk_terminal_mouse_shift_from_token(lent.baseAddress, lent.count)
        }
        return packed & 0x0100 != 0
    }

    var index: Int {
        switch self {
        case .disabled: 0
        case .enabled: 1
        case .always: 2
        case .never: 3
        }
    }
}

/// How the macOS Option key is treated for terminal input ("Option as Alt", libghostty
/// `macos-option-as-alt`, default ``off``). The client renders with libghostty-vt, so key→byte encoding
/// happens in the local surface — a real, reachable knob the builder emits.
///
/// - ``off``: Option composes accented characters (¡, é, ©…) as normal — libghostty `false`.
/// - ``both``: BOTH Option keys send Alt/Meta (Esc-prefixed) sequences — libghostty `true`.
/// - ``left`` / ``right``: only the named Option key sends Alt/Meta; the other still composes.
///
/// The tokens are slopdesk's own (`both` persists as `both`, not `true`); the libghostty token rides
/// beside each as ``configValue``.
public enum OptionAsAlt: Sendable, CaseIterable, RawRepresentable, Codable {
    case off
    case both
    case left
    case right

    public var rawValue: String { ControlTokens.optionAsAlt[index * 2] }

    /// Validate-then-repair to ``off`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_option_as_alt_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The libghostty `macos-option-as-alt` token this case maps to (values `false` / `true` / `left` /
    /// `right` — see the deleted fork's vendored ghostty `input/config.zig` `OptionAsAlt`). ``both`` → `true`,
    /// ``off`` → `false`.
    public var configValue: String { ControlTokens.optionAsAlt[index * 2 + 1] }

    /// The byte `slopdesk_term_surface_set_option_as_alt` takes: `0` off, `1` both, `2` left,
    /// `3` right.
    ///
    /// The same order as ``index``, and deliberately written as its own `switch` rather than a cast
    /// of it: `index` is this type's position in a token TABLE, and a door's wire byte that happened
    /// to agree with a table order would be two facts sharing one number until someone reordered the
    /// table. The renderer reads this; nothing else may.
    public var surfaceCode: UInt8 {
        switch self {
        case .off: 0
        case .both: 1
        case .left: 2
        case .right: 3
        }
    }

    var index: Int {
        switch self {
        case .off: 0
        case .both: 1
        case .left: 2
        case .right: 3
        }
    }
}

// MARK: - Link-interaction enums (Settings → Controls → Open With / Link Schemes)

/// What a `⌘`click on a detected link / path does (settings key `link-cmd-click`, default ``open``).
///
/// - ``open``: open in the best handler — a file / folder opens or reveals on the HOST (over the
///   metadata RPC), a URL opens in the client's system browser.
/// - ``copy``: copy the resolved absolute path / URL to the client pasteboard.
/// - ``nothing``: do nothing (reach links via the right-click menu / Jump-To / Hint Mode) — the escape
///   hatch when ⌘click conflicts with a TUI.
public enum LinkCmdClick: Sendable, CaseIterable, RawRepresentable, Codable {
    case open
    case copy
    case nothing

    public var rawValue: String { ControlTokens.linkClick[index] }

    /// Validate-then-repair to ``open`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_cmd_click_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var index: Int {
        switch self {
        case .open: 0
        case .copy: 1
        case .nothing: 2
        }
    }
}

/// What a `⌘⇧`click on a detected link / path does (settings key `link-cmd-shift-click`, default
/// ``revealFinder``).
///
/// - ``revealFinder``: reveal the path in the HOST Finder (`open -R`-equivalent over the metadata RPC);
///   a URL has no Finder target, so the click copies it instead.
/// - ``openSystemDefault``: open the path / URL with the HOST's system-default handler.
public enum LinkCmdShiftClick: Sendable, CaseIterable, RawRepresentable, Codable {
    case revealFinder
    case openSystemDefault

    /// ⌘⇧-click's tokens sit AFTER ⌘-click's three in the one delivery the pair of rows reads.
    public var rawValue: String { ControlTokens.linkClick[LinkCmdClick.allCases.count + index] }

    /// Validate-then-repair to ``revealFinder`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_cmd_shift_click_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var index: Int {
        switch self {
        case .revealFinder: 0
        case .openSystemDefault: 1
        }
    }
}

/// Which URL schemes are auto-detected / underlined on `⌘`-hover ("Auto-Detect Link Schemes", default
/// ``all``). `http(s)`, `file`, and `mailto` are ALWAYS detected regardless of this mode (hard-coded — see
/// ``LinkSchemePolicy``); this only governs OTHER `scheme://…` forms.
///
/// - ``all``: detect ANY `scheme://…`.
/// - ``custom``: detect only the always-on schemes plus the `controls.custom-link-schemes` list.
///
/// The POLICY itself does not cross: it is consumed by the detector, which is already Rust's.
public enum AutoDetectLinkSchemes: Sendable, CaseIterable, RawRepresentable, Codable {
    case all
    case custom

    public var rawValue: String { ControlTokens.schemeDetection[index] }

    /// Validate-then-repair to ``all`` (default), never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_scheme_detection_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var index: Int {
        switch self {
        case .all: 0
        case .custom: 1
        }
    }
}

// MARK: - TerminalControls (the fire-time control bundle the config builder consumes)

/// The pure, headless bundle of terminal CONTROL values the terminal config builder turns into
/// `copy-on-select` / `clipboard-*` / `mouse-*` config lines (+ the ⇧+arrow `adjust_selection` keybinds).
/// Controls sibling of ``TerminalPreferences`` (render prefs) — the two are independent inputs to
/// `TerminalConfigBuilder.string(...)`, NOT nested: the builder emits render lines from
/// ``TerminalPreferences`` and control lines from this struct.
///
/// Every field derives from a `[controls]` row in the config file, so this bundle never reaches the
/// `EnvConfig` overlay or the `video-prefs.json` sidecar — golden-safe by construction.
/// ``from(config:)`` is the single read site (`PreferencesStore.applyTerminal` rebuilds it on every
/// apply / `refreshTerminalControls()`), so the init defaults mirror the rows' own defaults and a
/// default-constructed value is a faithful "factory" terminal.
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
    /// The `clipboard-read` config line (default ``ClipboardAccess/ask``) — used to be the OSC-52
    /// clipboard-READ access gate; that subject is gone (see ``ClipboardAccess``'s ⚠️), so it now governs
    /// only the metadata clipboard-read channel.
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
    /// The `mouse.rightClickAction` settings key — what a bare right-click does in the viewport (default
    /// ``RightClickAction/contextMenu``). The config builder emits its `rawValue` as `right-click-action`;
    /// the deleted fork's libghostty owned the dispatch end-to-end from that key (see the ⚠️ on
    /// ``RightClickAction`` for where that stands now).
    public var rightClickAction: RightClickAction
    /// "Shift+Arrow Select" — ⇧+arrows drive native selection (emits four `adjust_selection` keybinds)
    /// instead of forwarding the arrow escapes to the program (default ON).
    public var shiftArrowSelect: Bool
    /// The `mouse-scroll-multiplier` config line — multiply the scroll-wheel delta (default `1.0`).
    public var scrollMultiplier: Double
    /// "Option as Alt" — whether the macOS Option key sends Alt/Meta (Esc-prefixed) sequences
    /// (default ``OptionAsAlt/off``, libghostty `macos-option-as-alt`). The config builder emits its
    /// ``OptionAsAlt/configValue`` as `macos-option-as-alt`; the client's libghostty-vt surface owns the
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

    /// Read the live control bundle out of the config file's `[controls]` table.
    ///
    /// Every field is a declared row, so no default is spelled twice: an absent key already carries
    /// the row's compiled default out of ``AppConfig``, and a value the row refuses was dropped with
    /// a diagnostic at resolve time. The `choice` fallbacks below are unreachable — the enums repair
    /// an unknown token themselves — and exist only because the accessor insists on one.
    public static func from(config: AppConfig) -> Self {
        // The "Clipboard — Shell Controlled" master switch (default ON) gates the WHOLE OSC-52 path
        // ahead of the per-direction Ask/Allow/Deny gate. Both directions resolve in ONE crossing:
        // a master switch honoured in one direction and not the other is the failure that rules out.
        let gates = slopdesk_terminal_clipboard_gates(
            config.flag("controls.clipboard-shell-controlled"),
            UInt8(config.choice("controls.clipboard-read", ClipboardAccess.ask).index),
            UInt8(config.choice("controls.clipboard-write", ClipboardAccess.allow).index),
        )
        let all = ClipboardAccess.allCases
        return Self(
            copyOnSelect: config.flag("controls.copy-on-select"),
            trimTrailing: config.flag("controls.trim-trailing-spaces"),
            clearOnTyping: config.flag("controls.clear-selection-on-typing"),
            clearOnCopy: config.flag("controls.clear-selection-on-copy"),
            pasteProtection: config.flag("controls.paste-protection"),
            bracketedSafe: config.flag("controls.paste-bracketed-safe"),
            clipboardRead: all[Int(gates & 0xFF)],
            clipboardWrite: all[Int(gates >> 8)],
            hideMouseWhileTyping: config.flag("controls.mouse-hide-while-typing"),
            allowShiftClick: config.choice("controls.shift-click", MouseShiftCapture.enabled),
            clickToMove: config.flag("controls.click-to-move"),
            allowMouseCapture: config.flag("controls.allow-mouse-capture"),
            rightClickAction: config.choice("controls.right-click-action", RightClickAction.contextMenu),
            shiftArrowSelect: config.flag("controls.shift-arrow-select"),
            scrollMultiplier: config.double("controls.scroll-multiplier"),
            optionAsAlt: config.choice("controls.option-as-alt", OptionAsAlt.off),
        )
    }
}
