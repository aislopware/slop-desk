// What a gesture DOES to a detected link, as the Swift face of `rust/slopdesk-terminal`'s
// `link_action`, reached through `rust/slopdesk-ffi`'s `link_action` door.
//
// ## What is not here any more
//
// The click-actions table: the ⌘click / ⌘⇧click branches, the URL rule that overrides the
// path-oriented ⌘⇧click setting, the context menu's four items, and the config-INDEPENDENT explicit
// open the keyboard affordances use. With it went the `:line[:col]` suffix scan that puts a
// compiler location back onto a resolved path, the purely-lexical POSIX parent, and the `cd` line
// with its parent fallback and its single-quoting. All Rust's, in the crate that already owns the
// scan that produced the link. This file owns the vocabulary the actuators speak and the marshalling.
//
// ## Why the verb is the RETURN
//
// The answer has two halves — what to do, and what to do it to. `.nothing` has no payload and
// `.copyPathClient("")` is a real (if degenerate) answer, so a length cannot double as the verb the
// way it does for a door that answers one string. The verb rides the return, the payload rides the
// usual `(out, cap)` pair, and `needed` carries docs/55 §4's retry number so a caller sizes its
// buffer without asking the verb twice.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// MARK: - Pure link gesture/menu → action mapping

/// The user gesture on a detected link the policy resolves. A plain (un-modified) click is included so
/// the "click does nothing — prevents accidental opens" rule is encoded HERE (not as an implicit
/// absence), keeping the mapping total and unit-testable.
public enum LinkGesture: Equatable, Sendable, CaseIterable {
    /// A bare left-click maps to *nothing* (no accidental opens).
    case plainClick
    /// `⌘`click — open / copy / nothing, per ``LinkActionConfig/cmdClick``.
    case commandClick
    /// `⌘⇧`click — reveal-in-Finder / open-system-default (paths) or copy (URLs), per
    /// ``LinkActionConfig/cmdShiftClick``.
    case commandShiftClick
}

/// The two link config knobs (`link-cmd-click` / `link-cmd-shift-click`) the policy reads, reusing
/// the persisted ``LinkCmdClick`` / ``LinkCmdShiftClick`` enums so there is ONE source of truth (the
/// renderer builds this from ``SettingsKey/linkCmdClick`` + ``SettingsKey/linkCmdShiftClick`` at click
/// time). Pure value type — no `Defaults`/AppKit — so the policy stays headless-testable.
public struct LinkActionConfig: Equatable, Sendable {
    /// What a `⌘`click does (`link-cmd-click`, default ``LinkCmdClick/open``).
    public var cmdClick: LinkCmdClick
    /// What a `⌘⇧`click does (`link-cmd-shift-click`, default ``LinkCmdShiftClick/revealFinder``).
    public var cmdShiftClick: LinkCmdShiftClick

    public init(cmdClick: LinkCmdClick = .open, cmdShiftClick: LinkCmdShiftClick = .revealFinder) {
        self.cmdClick = cmdClick
        self.cmdShiftClick = cmdShiftClick
    }

    /// The default behavior (open / reveal-finder).
    public static let `default` = Self()
}

/// The resolved action the renderer dispatches for a link gesture / context-menu item. Each case names
/// **where it actuates** so the thin macOS/iOS actuator can route it without re-deriving intent:
///
/// - ``copyPathClient``: write the resolved path / URL to the CLIENT pasteboard (Copy Path / Copy URL).
/// - ``changeDirectoryPTY``: inject `cd <path>` as **verbatim UTF-8** down the pane's PTY (Change
///   Directory Here) — never via `SendKeysParser` (memory: re-run/cd is verbatim UTF-8).
/// - ``openCodeHost``: ask the HOST to open the path in the embedded VS Code workbench (verb 19,
///   `code-server -r`) — the editor the user is actually looking at is the client's code panel, not
///   the host's screen. The carried target KEEPS the detector's `:line[:col]` suffix (code-server's
///   CLI jumps to it); the host falls back to a default-app open for a directory / a binary-less host.
/// - ``openHost``: ask the HOST to open the path in its best handler (the file lives on the host Mac, so
///   `NSWorkspace.open` must run host-side — delivered by the metadata RPC verb).
/// - ``revealHost``: ask the HOST to reveal the path in Finder (host-side `activateFileViewerSelecting`).
/// - ``openURLClient``: open the URL on the CLIENT (a URL / IP is host-agnostic — `NSWorkspace.open` /
///   `UIApplication.open`, or the in-app browser pane per config).
/// - ``nothing``: no-op (a plain click, or a config that disables the gesture).
public enum LinkAction: Equatable, Sendable {
    case copyPathClient(String)
    case changeDirectoryPTY(String)
    case openCodeHost(String)
    case openHost(String)
    case revealHost(String)
    case openURLClient(String)
    case nothing
}

/// The mapping `(gesture or menu item) × link kind × config → ``LinkAction``` behind the
/// "Click Actions" table (see `docs/ui-shell/spec/user-interface__files-and-links.md` §"Click Actions"):
///
/// | Target | Click | ⌘click | ⌘⇧click |
/// |---|---|---|---|
/// | Path | nothing | open in code panel (host workbench) / copy / nothing | reveal-Finder (host) / open-default (host) |
/// | URL  | nothing | open URL (client) / copy / nothing | Copy URL (client) |
///
/// Every entry is `slopdesk_terminal::link_action`'s, so BOTH the ⌘click/⌘⇧click renderer path and the
/// right-click context menu (``TerminalContextMenu/LinkItem``) resolve through the SAME table — no
/// parallel switch that could drift, in either language. The renderer is the thin actuator: it feeds
/// the ``DetectedLink`` under the pointer + the live config and dispatches the returned action.
///
/// A path's actuation path uses ``DetectedLink/resolvedAbsolute`` when the detector could resolve it
/// purely (an absolute path, a relative path joined to an absolute cwd, a `file://` path) and falls back
/// to the raw matched text otherwise (a `~`-path / an unresolved relative path) — the HOST expands the
/// remainder (`~`/cwd) and validates before acting, so the client never reads the disk.
public enum LinkActionPolicy {
    /// Resolve a left-click gesture on `link` under `config`.
    public static func action(for gesture: LinkGesture, link: DetectedLink, config: LinkActionConfig) -> LinkAction {
        resolve(trigger: gesture.ffiTrigger, link: link, config: config)
    }

    /// Resolve an EXPLICIT open intent on `link` — the keyboard-only affordances that MEAN "open": Hint-to-Open
    /// (⌘⇧J) and the Jump-To row default (↩). These always OPEN (a path on the host, a URL on the
    /// client) — they are NOT governed by `link-cmd-click`, which only configures the MOUSE ⌘click gesture.
    /// This is exactly the menu-item ``TerminalContextMenu/LinkItem/open`` resolution; naming it gives BOTH
    /// keyboard actuators one config-INDEPENDENT entry so neither can drift back onto the configurable gesture —
    /// wiring ⌘⇧J / ↩ through `link-cmd-click` directly would let `link-cmd-click = copy/nothing` silently turn
    /// them into copy / no-op. Pinned by ``LinkActionPolicyTests`` (revert-to-confirm-fail: it stays
    /// `.openCodeHost`/`.openURLClient` under any config — a path goes to the EMBEDDED editor, not
    /// the host's default app).
    public static func explicitOpenAction(link: DetectedLink) -> LinkAction {
        action(for: .open, link: link)
    }

    /// Resolve a right-click context-menu item on `link` (``TerminalContextMenu/LinkItem``). The menu
    /// only offers reveal / cd for path kinds (see ``TerminalContextMenu/linkItems(for:)``), so a URL +
    /// reveal/cd is defensively ``LinkAction/nothing``. The four menu triggers read no config — the
    /// menu says what it does on its own label — so the door takes the default one.
    public static func action(for menuItem: TerminalContextMenu.LinkItem, link: DetectedLink) -> LinkAction {
        resolve(trigger: menuItem.ffiTrigger, link: link, config: .default)
    }

    // MARK: - Helpers

    // `isURL` and `effectivePath` were here, and both were second spellings of
    // `slopdesk_terminal::link_action`'s `LinkTarget::is_url` / `LinkTarget::effective_path`. The
    // first had no caller at all; the second was two lines re-growing the crate's fallback beside a
    // door that already answers it — every action carrying a path carries the effective one, so
    // `action(for: .copyPath, link:)` IS the question, asked once.

    /// The target string for an embedded-editor open (``LinkAction/openCodeHost(_:)``): the best path
    /// PLUS the detector's `:line[:col]` suffix when the match carried one (`resolvedAbsolute` drops
    /// it, `raw` keeps it — an unresolved link rides `raw` as-is, suffix already in place).
    ///
    /// `""` is a REAL answer here (an empty link has an empty target), so "no answer" maps to it.
    public static func codeOpenTarget(_ link: DetectedLink) -> String {
        withOptionalText(link.raw) { raw, rawLength, _ in
            withOptionalText(link.resolvedAbsolute) { resolved, resolvedLength, present in
                wsAnswer { out, cap in
                    slopdesk_link_code_open_target(raw, rawLength, resolved, resolvedLength, present, out, cap)
                } ?? ""
            }
        }
    }

    /// The trailing `:line[:col]` numeric suffix of `text` (leading colon included), or `""` — the
    /// same shape ``TerminalLinkDetector``'s splitter accepts.
    static func lineColSuffix(of text: String) -> String {
        answer(text) { bytes, length, out, cap in slopdesk_link_line_col_suffix(bytes, length, out, cap) }
    }

    // MARK: - "Change Directory Here" actuation idiom (cd a FILE → its parent folder)

    /// The verbatim-UTF-8 shell line that points the focused PTY at `path`, falling back to the path's PARENT
    /// folder when `path` is a FILE: cd the focused terminal to the path (**or its parent folder**).
    /// A bare `cd '<file>'` errors `cd: not a directory` for the headline `path:line:col` compiler-output case
    /// (the detector already stripped the `:line:col`, leaving a file), so the line tries the path first and,
    /// only if that fails, its dir: `cd '<path>' 2>/dev/null || cd '<parent>'\n`. For a real directory the
    /// first `cd` succeeds and the fallback never runs. Both operands are single-quote-escaped so spaces / `$`
    /// / `;` land literally. ALL THREE actuators (TerminalLeafView, JumpToView, GhosttyTerminalView) emit this
    /// one string (`Data(line.utf8)`) so the idiom cannot drift; NEVER via `SendKeysParser` (cd is verbatim).
    /// Pinned by ``LinkActionPolicyTests`` (revert-to-confirm-fail: a bare `cd '<file>'` must not regress).
    public static func changeDirectoryCommandLine(_ path: String) -> String {
        answer(path) { bytes, length, out, cap in slopdesk_link_cd_command_line(bytes, length, out, cap) }
    }

    /// The POSIX-`dirname` of `path`, computed PURELY (no disk access): the path with its last component
    /// dropped. A trailing slash is ignored (`/a/b/c/` → `/a/b`); the parent of a root-level entry is `/`
    /// (`/a` → `/`); a bare name with no slash is the current dir `.` (`file` → `.`); root stays root.
    /// Pinned by ``LinkActionPolicyTests``.
    public static func posixParent(_ path: String) -> String {
        answer(path) { bytes, length, out, cap in slopdesk_link_posix_parent(bytes, length, out, cap) }
    }

    // MARK: - Marshalling

    /// Feeds the link + the trigger through the table and reads the `(verb, payload)` pair back as the
    /// action the actuators dispatch. An unknown verb — a door newer than this file — is ``LinkAction/nothing``,
    /// which is the safe reading of "I do not know what this gesture does".
    private static func resolve(trigger: UInt8, link: DetectedLink, config: LinkActionConfig) -> LinkAction {
        let kind = TerminalLinkDetector.code(of: link.kind)
        let (verb, payload) = withOptionalText(link.raw) { raw, rawLength, _ in
            withOptionalText(link.resolvedAbsolute) { resolved, resolvedLength, present in
                verbAnswer { out, cap, needed in
                    slopdesk_link_action(
                        trigger, config.cmdClick.ffiCode, config.cmdShiftClick.ffiCode, kind,
                        raw, rawLength, resolved, resolvedLength, present, out, cap, needed,
                    )
                }
            }
        }
        switch UInt32(verb) {
        case SLOPDESK_LINK_ACTION_COPY_PATH_CLIENT: return .copyPathClient(payload)
        case SLOPDESK_LINK_ACTION_CHANGE_DIRECTORY_PTY: return .changeDirectoryPTY(payload)
        case SLOPDESK_LINK_ACTION_OPEN_CODE_HOST: return .openCodeHost(payload)
        case SLOPDESK_LINK_ACTION_OPEN_HOST: return .openHost(payload)
        case SLOPDESK_LINK_ACTION_REVEAL_HOST: return .revealHost(payload)
        case SLOPDESK_LINK_ACTION_OPEN_URL_CLIENT: return .openURLClient(payload)
        default: return .nothing
        }
    }

    /// Reads the two-part answer: the verb from the return, the payload from `(out, cap)` with `needed`
    /// carrying the retry number. Unlike ``wsAnswer``, `needed == 0` is not "no answer" — `.nothing`
    /// legitimately has no payload — so the verb survives an empty read.
    private static func verbAnswer(
        _ call: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> UInt8,
    ) -> (verb: UInt8, payload: String) {
        var out = [UInt8](repeating: 0, count: 256)
        var needed = 0
        var verb = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &needed) }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            verb = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &needed) }
        }
        guard needed > 0, needed <= out.count,
              let payload = String(bytes: out[0..<needed], encoding: .utf8) else { return (verb, "") }
        return (verb, payload)
    }

    /// One string in, one string out. `""` is the real answer for every door that reaches this — no
    /// suffix, the parent of a bare name, the line for an empty path — so "no answer" maps to it.
    private static func answer(
        _ input: String,
        _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int) -> Int,
    ) -> String {
        wsTransform(input, call).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }
}

// MARK: - The codes the door reads

// Each case names its `SLOPDESK_LINK_*` macro rather than a number, so no code is spelled twice and
// the two languages cannot drift apart over one — the same reason the detector's kinds cross that way.

private extension LinkGesture {
    var ffiTrigger: UInt8 {
        switch self {
        case .plainClick: UInt8(SLOPDESK_LINK_TRIGGER_PLAIN_CLICK)
        case .commandClick: UInt8(SLOPDESK_LINK_TRIGGER_COMMAND_CLICK)
        case .commandShiftClick: UInt8(SLOPDESK_LINK_TRIGGER_COMMAND_SHIFT_CLICK)
        }
    }
}

private extension TerminalContextMenu.LinkItem {
    var ffiTrigger: UInt8 {
        switch self {
        case .open: UInt8(SLOPDESK_LINK_TRIGGER_OPEN)
        case .copyPath: UInt8(SLOPDESK_LINK_TRIGGER_COPY_PATH)
        case .revealInFinder: UInt8(SLOPDESK_LINK_TRIGGER_REVEAL_IN_FINDER)
        case .changeDirectoryHere: UInt8(SLOPDESK_LINK_TRIGGER_CHANGE_DIRECTORY)
        }
    }
}

private extension LinkCmdClick {
    var ffiCode: UInt8 {
        switch self {
        case .open: UInt8(SLOPDESK_LINK_CMD_CLICK_OPEN)
        case .copy: UInt8(SLOPDESK_LINK_CMD_CLICK_COPY)
        case .nothing: UInt8(SLOPDESK_LINK_CMD_CLICK_NOTHING)
        }
    }
}

private extension LinkCmdShiftClick {
    var ffiCode: UInt8 {
        switch self {
        case .revealFinder: UInt8(SLOPDESK_LINK_CMD_SHIFT_CLICK_REVEAL_FINDER)
        case .openSystemDefault: UInt8(SLOPDESK_LINK_CMD_SHIFT_CLICK_OPEN_SYSTEM_DEFAULT)
        }
    }
}
