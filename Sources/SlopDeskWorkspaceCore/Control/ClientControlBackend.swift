import SlopDeskAgentDetect
import SlopDeskWorkspaceModel

// Client control backend seam.
//
// The one thing the client control socket asks of this language: reaching the running GUI. Every
// other step — the listener, the framing, the decode, the validation, the refusal words and the
// reply encoder — is `slopdesk-clientctl`, and `ClientControlHost` is the face that carries one
// already-decoded request across to a conformance here. The concrete one
// (`WorkspaceControlBackend`) adapts `WorkspaceStore` / `PreferencesStore` /
// `WorkspaceBindingRegistry` / `FolderFrecencyStore`.
//
// `@MainActor`: every concrete client store is `@MainActor`, so the seam is main-actor isolated and
// the face hops to reach it.

// MARK: - Value types (the face pushes these back through the reply handle)

/// One window in a `windows` listing.
public struct ClientWindowInfo: Sendable, Equatable {
    public let id: String
    public let title: String
    public let tabCount: Int
    public let isFocused: Bool

    public init(id: String, title: String, tabCount: Int, isFocused: Bool) {
        self.id = id
        self.title = title
        self.tabCount = tabCount
        self.isFocused = isFocused
    }
}

/// One tab in a `tabs` listing. `badge` is the tab's current badge, or `nil` for all-clear.
///
/// The KIND rather than its token: the token is the socket's spelling and lives one side over, so a
/// listing that carried a string here would be this language naming a word it does not own.
public struct ClientTabInfo: Sendable, Equatable {
    public let id: String
    public let windowId: String
    public let title: String
    public let paneCount: Int
    public let isFocused: Bool
    public let badge: TabBadgeKind?

    public init(
        id: String,
        windowId: String,
        title: String,
        paneCount: Int,
        isFocused: Bool,
        badge: TabBadgeKind?,
    ) {
        self.id = id
        self.windowId = windowId
        self.title = title
        self.paneCount = paneCount
        self.isFocused = isFocused
        self.badge = badge
    }
}

/// One pane in a `panes` listing. `cwd` is the last OSC-7 working directory the client cached, if any.
public struct ClientPaneInfo: Sendable, Equatable {
    public let id: String
    public let tabId: String
    public let title: String
    public let kind: String
    public let isFocused: Bool
    public let cwd: String?

    public init(
        id: String,
        tabId: String,
        title: String,
        kind: String,
        isFocused: Bool,
        cwd: String?,
    ) {
        self.id = id
        self.tabId = tabId
        self.title = title
        self.kind = kind
        self.isFocused = isFocused
        self.cwd = cwd
    }
}

/// One font family in a `font list`.
public struct ClientFontInfo: Sendable, Equatable {
    public let family: String
    public let isMonospace: Bool
    public let isSystem: Bool

    public init(family: String, isMonospace: Bool, isSystem: Bool) {
        self.family = family
        self.isMonospace = isMonospace
        self.isSystem = isSystem
    }
}

/// One keybinding in a `keybind list`: an action name and its human-readable chord(s).
public struct ClientKeybindInfo: Sendable, Equatable {
    public let action: String
    public let keys: String

    public init(action: String, keys: String) {
        self.action = action
        self.keys = keys
    }
}

/// The outcome of a `jump`: the resolved path, and whether a `cd` was actually sent to the focused
/// pane (`false` when `--no-cd` only printed it).
public struct ClientJumpOutcome: Sendable, Equatable {
    public let path: String
    public let didChangeDirectory: Bool

    public init(path: String, didChangeDirectory: Bool) {
        self.path = path
        self.didChangeDirectory = didChangeDirectory
    }
}

/// Whether a `view`/`edit` shim opens a read-only viewer (`less`/`open`) or an editor (`$EDITOR`).
public enum ClientControlOpenMode: Sendable, Equatable {
    case view
    case edit
}

/// Where a `view`/`edit` shim opens.
///
/// The raw value is the placement's POSITION in `slopdesk-clientctl`'s vocabulary, not its spelling:
/// the token is parsed once, on the far side, and only the index crosses. `newTab` is `0` because it
/// is what a request naming no placement means.
public enum ClientControlPlacement: UInt8, Sendable, Equatable, CaseIterable {
    case newTab = 0
    case newWindow = 1
    case left = 2
    case right = 3
    case top = 4
    case bottom = 5
}

/// `font list --system` / `--user` scope, by position in the same vocabulary. A request naming no
/// scope asks for BOTH, which is a `nil` filter rather than a case here.
public enum ClientControlFontScope: UInt8, Sendable, Equatable, CaseIterable {
    case system = 0
    case user = 1
}

/// The outcome of resolving an `agent-status` query. Distinguishes a pane that does NOT exist from a
/// pane that EXISTS but whose agent has not yet reported a non-`.none` status — the agent-startup
/// window (`paneAgentStatus` has no entry until the first non-`.none` report over wire type 27).
///
/// `watch:claude` must KEEP POLLING in the startup window rather than declaring the id "never seen"
/// (exit 4) on the first poll: `resolvedNoStatus` ⇒ `{seen:true}` (no status) ⇒ keep polling;
/// `unresolved` ⇒ `{seen:false}` ⇒ exit 4 only for an id that resolves to NO pane at all.
/// What one `pane send-keys` did, when "it worked" and "the pane is gone" are no longer the only
/// two answers.
///
/// A named key that the key vocabulary does not recognise is a THIRD outcome, and it used to have
/// nowhere to go: the backend dropped the name and answered the same `true` a delivered keystroke
/// answers, so `--key f5` reported success and sent nothing. A `Bool` could carry the refusal only
/// by borrowing "pane not found", which would report the wrong reason for the right failure — so the
/// seam names all three, the way ``AgentStatusResolution`` above names the two ways an agent-status
/// lookup can come back empty.
public enum SendKeysOutcome: Sendable, Equatable {
    /// The text and every named key reached the pane.
    case sent
    /// The id does not resolve to any pane the running app currently knows.
    case paneNotFound
    /// This name is not a key. Nothing was sent — an unknown name rejects the WHOLE request, so a
    /// typo never leaves half a key sequence on a pane.
    case unknownKey(String)
}

public enum AgentStatusResolution: Sendable, Equatable {
    /// The id does not resolve to any pane the running app currently knows.
    case unresolved
    /// The id resolves to a live pane, but it has not yet reported an agent status.
    case resolvedNoStatus
    /// The id resolves to a live pane carrying this rolled-up agent status.
    case status(ClaudeStatus)
}

// MARK: - Backend seam

/// The seam `ClientControlHost` drives. Every method is SYNCHRONOUS and `@MainActor` (it touches
/// `@MainActor` client stores). Optionals / `Bool` returns name the outcomes the face turns into a
/// refusal:
///
/// - a `nil` / `false` return means "target not found / could not complete" → the face answers the
///   refusal the crate has a sentence for (never a trap).
/// - every param has ALREADY been validated and bounded by the time it reaches here — counts are
///   positive and clamped, tokens are parsed to indices, required fields are present — so a
///   conformance can assume well-formed inputs.
@preconcurrency
@MainActor
public protocol ClientControlBackend: AnyObject {
    /// All windows (focused flag set on at most one).
    func listWindows() -> [ClientWindowInfo]

    /// Tabs, optionally scoped to `windowId` (nil = every window).
    func listTabs(windowId: String?) -> [ClientTabInfo]

    /// Panes, optionally scoped to `tabId` (nil = every tab).
    func listPanes(tabId: String?) -> [ClientPaneInfo]

    /// Set `kind` on a tab (nil `tabId` = the focused tab). Returns `false` when the tab is unknown.
    func setTabBadge(tabId: String?, kind: TabBadgeKind) -> Bool

    /// Resolve a frecency-ranked jump target for `query` (nil = the `$HOME`↔last-jump toggle) and,
    /// when `changeDirectory` is true, send `cd <resolved>` to the focused pane. Returns `nil` when
    /// no target could be resolved.
    func jump(query: String?, changeDirectory: Bool) -> ClientJumpOutcome?

    /// Record a directory visit in the frecency database. A `nil`/empty `path` records the focused pane's
    /// cached OSC-7 cwd. Returns the recorded path, or `nil` when no `path` was given AND no focused-pane
    /// cwd is known (the dispatcher turns `nil` into an error response).
    func learn(path: String?) -> String?

    /// Remove `path` from the frecency database (idempotent — a no-op for an unknown path). Returns
    /// `false` only when the frecency store is unavailable.
    func ignore(path: String) -> Bool

    /// Open a `view`/`edit` shim for `target` at `placement`. Returns `false` on failure.
    func open(target: String, mode: ClientControlOpenMode, placement: ClientControlPlacement) -> Bool

    /// Fonts filtered by monospace / family substring / scope.
    func listFonts(
        monospaceOnly: Bool,
        family: String?,
        scope: ClientControlFontScope?,
    ) -> [ClientFontInfo]

    /// Keybindings, optionally filtered by an action-name substring.
    func listKeybinds(actionFilter: String?) -> [ClientKeybindInfo]

    /// Capture the last `lines` of a pane's scrollback (nil `paneId` = the focused pane). Returns
    /// `nil` when the pane is unknown.
    func capturePane(paneId: String?, lines: Int) -> [String]?

    /// Send literal `text` followed by named `keys` to a pane (nil `paneId` = the focused pane).
    /// The key NAMES are the conformance's to validate — see ``SendKeysOutcome``.
    func sendKeys(paneId: String?, text: String, keys: [String]) -> SendKeysOutcome

    /// Resolve the agent status for session/pane `id`. Reports pane EXISTENCE separately from agent-status
    /// presence (``AgentStatusResolution``) so `watch:claude` can keep polling through the agent-startup
    /// window (`resolvedNoStatus`) and reserve "never seen" → exit 4 for an id that resolves to no pane
    /// (`unresolved`).
    func agentStatus(id: String) -> AgentStatusResolution
}
