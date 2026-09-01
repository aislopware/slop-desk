// TerminalControls — the near-side FACE of `slopdesk_terminal::controls`.
//
// Each of the seven vocabularies below is the same shape: a small closed set, a stored spelling per
// case, and a repair for a token this build does not know. So each crosses TWICE — one delivery of
// the whole table in declaration order, read once per process, and one door that repairs an
// arbitrary stored token to a code. A door per case would be thirty-odd crossings for seven
// enumerations whose members are known at compile time on both sides.
//
// ⚠️ THE FIRE-TIME BUNDLE THAT USED TO CLOSE THIS FILE IS GONE. `TerminalControls` was a sixteen-field
// value read out of `[controls]` in one crossing so the terminal config BUILDER could emit it; with
// the builder deleted (docs/68) nothing asked for the bundle, and each of its rows is already read at
// the point of use through `SettingsKey`. Two of the tables shrank with it — they used to interleave a
// second spelling per case, the word the fork's config text wrote the same setting with, one of them
// inverted against this enum's own axis. Nothing parses that text, so nothing needs the transcription.
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
/// One run per case, every table. Two of them used to interleave a SECOND spelling — the deleted
/// fork's config-text word for the same setting — and dropping it halved both.
private enum ControlTokens {
    static let clipboard: [String] = runs(3) { out, cap in
        Int(slopdesk_terminal_clipboard_tokens(out, cap))
    }

    static let rightClick: [String] = runs(5) { out, cap in
        Int(slopdesk_terminal_right_click_tokens(out, cap))
    }

    static let mouseShift: [String] = runs(4) { out, cap in
        Int(slopdesk_terminal_mouse_shift_tokens(out, cap))
    }

    static let optionAsAlt: [String] = runs(4) { out, cap in
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

    /// Scroll-past-LAST's four, then scroll-past-FIRST's four — one delivery, for the link pair's
    /// reason: one setting with two ends, and ``ScrollPastFirst/sameAsLast`` makes the second quote
    /// the first outright.
    static let scrollPast: [String] = runs(8) { out, cap in
        Int(slopdesk_terminal_scroll_past_tokens(out, cap))
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

/// How far past the NEWEST line the viewport may scroll, and what it anchors on
/// (`controls.scroll-past-last-line`).
///
/// - ``disabled``: clamp at the bottom of the content, which is the default and what every
///   terminal does out of the box.
/// - ``lastLineWithContent``: the bottom-most row holding text floats to the TOP of the viewport.
/// - ``lastLineInMiddle``: that same row floats to the middle.
/// - ``cursorLine``: the CURSOR's row floats to the top even when it is blank — which is the whole
///   difference from ``lastLineWithContent``, since a shell that prints a trailing blank line puts
///   the two anchors on different rows.
///
/// The anchor is resolved in Rust against the laid-out content, because the block chrome sits
/// between the rows and only the layout knows where a row ended up. ``init(rawValue:)`` is
/// validate-then-repair to ``disabled``.
public enum ScrollPastLast: Sendable, CaseIterable, RawRepresentable, Codable {
    case disabled
    case lastLineWithContent
    case lastLineInMiddle
    case cursorLine

    public var rawValue: String { ControlTokens.scrollPast[index] }

    /// Validate-then-repair to ``disabled``, never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_scroll_past_last_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The code `slopdesk_term_surface_set_overscroll` takes — this case's place in the far side's
    /// own `ALL` order. `public` unlike its neighbours' because the surface that reads it lives in
    /// another module.
    public var index: Int {
        switch self {
        case .disabled: 0
        case .lastLineWithContent: 1
        case .lastLineInMiddle: 2
        case .cursorLine: 3
        }
    }
}

/// How far past the OLDEST retained line the viewport may scroll
/// (`controls.scroll-past-first-line`).
///
/// - ``disabled``: clamp at the top of the scrollback.
/// - ``sameAsLast``: whatever ``ScrollPastLast`` says, mirrored onto this end — most people want
///   both ends alike and should not have to keep two knobs in step by hand.
/// - ``firstLineWithContent``: the oldest retained row sinks to the BOTTOM of the viewport.
/// - ``firstLineInMiddle``: that same row sinks to the middle.
///
/// ``sameAsLast`` is resolved in Rust, so past that resolution there are three stops and not four.
/// ``init(rawValue:)`` is validate-then-repair to ``disabled``.
public enum ScrollPastFirst: Sendable, CaseIterable, RawRepresentable, Codable {
    case disabled
    case sameAsLast
    case firstLineWithContent
    case firstLineInMiddle

    /// Offset by ``ScrollPastLast``'s four, which share the one delivery.
    public var rawValue: String { ControlTokens.scrollPast[ScrollPastLast.allCases.count + index] }

    /// Validate-then-repair to ``disabled``, never trapping; non-failable for the `Defaults` bridge.
    public init(rawValue: String) {
        self = repaired(rawValue, Self.allCases) { token, len in
            slopdesk_terminal_scroll_past_first_from_token(token, len)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// This case's place in the far side's own `ALL` order — ``ScrollPastLast/index``'s twin, and
    /// `public` for the same reason.
    public var index: Int {
        switch self {
        case .disabled: 0
        case .sameAsLast: 1
        case .firstLineWithContent: 2
        case .firstLineInMiddle: 3
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
    // `libghostty-vt` has no UI of its own, so it cannot own this the way the fork did. The dispatch
    // moved to ``RightClickPolicy`` over `slopdesk_terminal::surface::right_click`, which
    // `MacTerminalRendererView.rightMouseDown` actuates — and it still reads the selection BEFORE
    // forwarding the click, which is the race the fork's arrangement was avoiding.
}

/// Whether ⇧+click / ⇧+drag bypasses a program's mouse capture to make a native selection ("Allow Shift
/// with Mouse Click", libghostty `mouse-shift-capture`).
///
/// - ``disabled``: never bypass (program always captures).
/// - ``enabled``: ⇧ bypasses capture for that one gesture (the default).
/// - ``always``: ⇧ is always consumed for selection.
/// - ``never``: ⇧ is never consumed for selection (always forwarded to the program).
///
/// The tokens are slopdesk's own semantic ones, and they are the only ones: the inverted libghostty
/// spelling that used to ride beside each died with the config text nothing parsed.
public enum MouseShiftCapture: Sendable, CaseIterable, RawRepresentable, Codable {
    case disabled
    case enabled
    case always
    case never

    public var rawValue: String { ControlTokens.mouseShift[index] }

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
/// The tokens are slopdesk's own (`both` persists as `both`, not `true`).
public enum OptionAsAlt: Sendable, CaseIterable, RawRepresentable, Codable {
    case off
    case both
    case left
    case right

    public var rawValue: String { ControlTokens.optionAsAlt[index] }

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
