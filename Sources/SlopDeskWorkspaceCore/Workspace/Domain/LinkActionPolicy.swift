import Foundation

// MARK: - E10 WI-6 (ES-E10-2): pure link gesture/menu → action mapping

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
/// - ``openHost``: ask the HOST to open the path in its best handler (the file lives on the host Mac, so
///   `NSWorkspace.open` must run host-side — delivered by the E10 WI-7 metadata RPC verb).
/// - ``revealHost``: ask the HOST to reveal the path in Finder (host-side `activateFileViewerSelecting`,
///   WI-7).
/// - ``openURLClient``: open the URL on the CLIENT (a URL / IP is host-agnostic — `NSWorkspace.open` /
///   `UIApplication.open`, or the in-app browser pane per config).
/// - ``nothing``: no-op (a plain click, or a config that disables the gesture).
public enum LinkAction: Equatable, Sendable {
    case copyPathClient(String)
    case changeDirectoryPTY(String)
    case openHost(String)
    case revealHost(String)
    case openURLClient(String)
    case nothing
}

/// The PURE mapping `(gesture or menu item) × link kind × config → ``LinkAction``` behind the
/// "Click Actions" table (see `docs/ui-shell/spec/user-interface__files-and-links.md` §"Click Actions"):
///
/// | Target | Click | ⌘click | ⌘⇧click |
/// |---|---|---|---|
/// | Path | nothing | open best handler (host) / copy / nothing | reveal-Finder (host) / open-default (host) |
/// | URL  | nothing | open URL (client) / copy / nothing | Copy URL (client) |
///
/// Splitting it out as a pure enum keeps the click-actions table unit-testable headless (``LinkActionPolicyTests``,
/// revert-to-confirm-fail) and lets BOTH the ⌘click/⌘⇧click renderer path (WI-6) and the right-click
/// context menu (``TerminalContextMenu/LinkItem``) resolve through the SAME logic — no parallel switch
/// that could drift. The renderer is the thin actuator: it feeds the ``DetectedLink`` under the pointer
/// + the live config and dispatches the returned action.
///
/// A path's actuation path uses ``DetectedLink/resolvedAbsolute`` when the detector could resolve it
/// purely (an absolute path, a relative path joined to an absolute cwd, a `file://` path) and falls back
/// to the raw matched text otherwise (a `~`-path / an unresolved relative path) — the HOST expands the
/// remainder (`~`/cwd) and validates before acting (WI-7), so the client never reads the disk.
public enum LinkActionPolicy {
    /// Resolve a left-click gesture on `link` under `config`.
    public static func action(for gesture: LinkGesture, link: DetectedLink, config: LinkActionConfig) -> LinkAction {
        switch gesture {
        case .plainClick:
            // A bare click on a link does NOTHING — it prevents accidental opens.
            .nothing
        case .commandClick:
            commandClickAction(link: link, behavior: config.cmdClick)
        case .commandShiftClick:
            commandShiftClickAction(link: link, behavior: config.cmdShiftClick)
        }
    }

    /// Resolve an EXPLICIT open intent on `link` — the keyboard-only affordances that MEAN "open": Hint-to-Open
    /// (⌘⇧J) and the Jump-To row default (↩). These always OPEN (a path on the host, a URL on the
    /// client) — they are NOT governed by `link-cmd-click`, which only configures the MOUSE ⌘click gesture.
    /// This is exactly the menu-item ``TerminalContextMenu/LinkItem/open`` resolution; naming it gives BOTH
    /// keyboard actuators one config-INDEPENDENT entry so neither can drift back onto the configurable gesture
    /// (the E10 review bug: a `link-cmd-click = copy/nothing` made ⌘⇧J / ↩ silently copy / no-op). Pinned by
    /// ``LinkActionPolicyTests`` (revert-to-confirm-fail: it stays `.openHost`/`.openURLClient` under any config).
    public static func explicitOpenAction(link: DetectedLink) -> LinkAction {
        action(for: .open, link: link)
    }

    /// Resolve a right-click context-menu item on `link` (``TerminalContextMenu/LinkItem``). The menu
    /// only offers reveal / cd for path kinds (see ``TerminalContextMenu/linkItems(for:)``), so a URL +
    /// reveal/cd is defensively ``LinkAction/nothing``.
    public static func action(for menuItem: TerminalContextMenu.LinkItem, link: DetectedLink) -> LinkAction {
        switch menuItem {
        case .open:
            if isURL(link) { .openURLClient(link.raw) } else { .openHost(effectivePath(link)) }
        case .copyPath:
            .copyPathClient(isURL(link) ? link.raw : effectivePath(link))
        case .revealInFinder:
            isURL(link) ? .nothing : .revealHost(effectivePath(link))
        case .changeDirectoryHere:
            isURL(link) ? .nothing : .changeDirectoryPTY(effectivePath(link))
        }
    }

    // MARK: - Gesture sub-rules

    private static func commandClickAction(link: DetectedLink, behavior: LinkCmdClick) -> LinkAction {
        switch behavior {
        case .open:
            if isURL(link) { .openURLClient(link.raw) } else { .openHost(effectivePath(link)) }
        case .copy:
            .copyPathClient(isURL(link) ? link.raw : effectivePath(link))
        case .nothing:
            .nothing
        }
    }

    private static func commandShiftClickAction(link: DetectedLink, behavior: LinkCmdShiftClick) -> LinkAction {
        // A URL has no Finder target, so ⌘⇧click on a URL maps to *Copy URL* regardless of the
        // (path-oriented) `link-cmd-shift-click` setting.
        if isURL(link) { return .copyPathClient(link.raw) }
        switch behavior {
        case .revealFinder:
            return .revealHost(effectivePath(link))
        case .openSystemDefault:
            return .openHost(effectivePath(link))
        }
    }

    // MARK: - Helpers

    /// A pure URL (`scheme://…` or `mailto:`), as opposed to a filesystem path. A `file://` URL is a PATH
    /// for action purposes — its filesystem target is what `Open` / `Reveal` / `Copy Path` act on.
    static func isURL(_ link: DetectedLink) -> Bool { link.kind == .url }

    /// The best path string for a path-kind action: the purely-resolved absolute path when the detector
    /// could derive one, else the raw matched text (the host expands `~`/cwd + validates). Never reads
    /// the disk.
    static func effectivePath(_ link: DetectedLink) -> String { link.resolvedAbsolute ?? link.raw }

    // MARK: - "Change Directory Here" actuation idiom (E10 review fix — cd a FILE → its parent folder)

    /// The verbatim-UTF-8 shell line that points the focused PTY at `path`, falling back to the path's PARENT
    /// folder when `path` is a FILE: cd the focused terminal to the path (**or its parent folder**).
    /// A bare `cd '<file>'` errors `cd: not a directory` for the headline `path:line:col` compiler-output case
    /// (the detector already stripped the `:line:col`, leaving a file), so the line tries the path first and,
    /// only if that fails, its dir: `cd '<path>' 2>/dev/null || cd '<parent>'\n`. For a real directory the
    /// first `cd` succeeds and the fallback never runs. Both operands are single-quote-escaped so spaces / `$`
    /// / `;` land literally. ALL THREE actuators (TerminalLeafView, JumpToView, GhosttyTerminalView) emit this
    /// one string (`Data(line.utf8)`) so the idiom cannot drift; NEVER via `SendKeysParser` (cd is verbatim).
    /// Pinned by ``LinkActionPolicyTests`` (revert-to-confirm-fail vs the old bare `cd '<file>'`).
    public static func changeDirectoryCommandLine(_ path: String) -> String {
        "cd " + shellSingleQuoted(path) + " 2>/dev/null || cd " + shellSingleQuoted(posixParent(path)) + "\n"
    }

    /// The POSIX-`dirname` of `path`, computed PURELY (no disk access): the path with its last component
    /// dropped. A trailing slash is ignored (`/a/b/c/` → `/a/b`); the parent of a root-level entry is `/`
    /// (`/a` → `/`); a bare name with no slash is the current dir `.` (`file` → `.`); root stays root.
    /// Pinned by ``LinkActionPolicyTests``.
    public static func posixParent(_ path: String) -> String {
        var p = Substring(path)
        // Drop a trailing slash run, but never collapse root "/" itself.
        while p.count > 1, p.last == "/" { p = p.dropLast() }
        guard let slash = p.lastIndex(of: "/") else { return "." }
        if slash == p.startIndex { return "/" } // the only "/" is the leading one → parent is root
        return String(p[p.startIndex..<slash])
    }

    /// POSIX single-quote `s` so it survives the shell verbatim: wrap in `'…'` and rewrite each embedded `'`
    /// as `'\''` (close-quote, escaped-quote, reopen-quote). Safe for spaces, `$`, `` ` ``, `;`, etc.
    static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
