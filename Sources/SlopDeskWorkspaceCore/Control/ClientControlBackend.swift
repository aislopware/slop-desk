import Foundation
import SlopDeskAgentDetect

// Client control backend seam.
//
// The protocol the ``ClientControlDispatcher`` calls to actually drive the running client GUI.
// The concrete conformance (`WorkspaceControlBackend`) adapts `WorkspaceStore` /
// `PreferencesStore` / `ThemeStore` / `WorkspaceBindingRegistry` / `FolderFrecencyStore`; the
// dispatcher is unit-tested against a FAKE conformance (no GUI, no socket — hang-safety).
//
// `@MainActor`: every concrete client store is `@MainActor`, so the seam — and therefore the
// dispatch that calls it — is main-actor isolated. The dispatch logic stays PURE (deterministic,
// no I/O) under that isolation.

// MARK: - Value types (the dispatcher serializes these to the NDJSON `result`)

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

/// One tab in a `tabs` listing. `badge` is the canonical token of the tab's current badge, or `nil`.
public struct ClientTabInfo: Sendable, Equatable {
    public let id: String
    public let windowId: String
    public let title: String
    public let paneCount: Int
    public let isFocused: Bool
    public let badge: String?

    public init(
        id: String,
        windowId: String,
        title: String,
        paneCount: Int,
        isFocused: Bool,
        badge: String?,
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

/// One theme in a `theme list`. `isDark` drives the `--color dark|light` filter; `isActive` marks
/// the currently-applied theme.
public struct ClientThemeInfo: Sendable, Equatable {
    public let name: String
    public let isDark: Bool
    public let isActive: Bool

    public init(name: String, isDark: Bool, isActive: Bool) {
        self.name = name
        self.isDark = isDark
        self.isActive = isActive
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

/// One key/value pair in a `config show` dump. An ARRAY (not a dict) so the dispatcher preserves the
/// backend's ordering for the table view.
public struct ClientConfigEntry: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
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

/// The outcome of resolving an `agent-status` query. Distinguishes a pane that does NOT exist from a
/// pane that EXISTS but whose agent has not yet reported a non-`.none` status — the agent-startup
/// window (`paneAgentStatus` has no entry until the first non-`.none` report over wire type 27).
///
/// `watch:claude` must KEEP POLLING in the startup window rather than declaring the id "never seen"
/// (exit 4) on the first poll: `resolvedNoStatus` ⇒ `{seen:true}` (no status) ⇒ keep polling;
/// `unresolved` ⇒ `{seen:false}` ⇒ exit 4 only for an id that resolves to NO pane at all.
public enum AgentStatusResolution: Sendable, Equatable {
    /// The id does not resolve to any pane the running app currently knows.
    case unresolved
    /// The id resolves to a live pane, but it has not yet reported an agent status.
    case resolvedNoStatus
    /// The id resolves to a live pane carrying this rolled-up agent status.
    case status(ClaudeStatus)
}

// MARK: - Backend seam

/// The seam the ``ClientControlDispatcher`` drives. Every method is SYNCHRONOUS and `@MainActor`
/// (it touches `@MainActor` client stores). Optionals / `Bool` returns encode the
/// "validate-then-drop" outcomes the dispatcher converts into NDJSON success/error responses:
///
/// - a `nil` / `false` return means "target not found / could not complete" → the dispatcher emits
///   an `ok:false` error response (never a trap).
/// - the dispatcher has ALREADY validated and bounded every param (counts, tokens, presence) before
///   calling the backend, so a conformance can assume well-formed inputs.
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
    func open(target: String, mode: ClientControlOpenMode, placement: ClientControlProtocol.Placement) -> Bool

    /// Read one config key; `nil` when the key is unset.
    func configGet(key: String) -> String?

    /// Write one config key. Returns `false` when the key/value is rejected — INCLUDING any `transient`
    /// request (the dispatcher short-circuits `--transient` with an honest reason; slopdesk has no
    /// apply-without-persist render layer — see ``configSet`` on the concrete backend).
    func configSet(key: String, value: String, transient: Bool) -> Bool

    /// Remove one config key. Returns `false` when the removal is rejected, including any `transient`
    /// request (same no-ephemeral-layer reason as ``configSet(key:value:transient:)``).
    func configUnset(key: String, transient: Bool) -> Bool

    /// Broadcast the config-change notification. Returns `false` on failure.
    func configReload() -> Bool

    /// The full effective config, ordered for display.
    func configShow() -> [ClientConfigEntry]

    /// Themes filtered by color appearance.
    func listThemes(color: ClientControlProtocol.ThemeColorFilter) -> [ClientThemeInfo]

    /// Fonts filtered by monospace / family substring / scope.
    func listFonts(
        monospaceOnly: Bool,
        family: String?,
        scope: ClientControlProtocol.FontScope?,
    ) -> [ClientFontInfo]

    /// Keybindings, optionally filtered by an action-name substring.
    func listKeybinds(actionFilter: String?) -> [ClientKeybindInfo]

    /// Capture the last `lines` of a pane's scrollback (nil `paneId` = the focused pane). Returns
    /// `nil` when the pane is unknown.
    func capturePane(paneId: String?, lines: Int) -> [String]?

    /// Send literal `text` followed by named `keys` to a pane (nil `paneId` = the focused pane).
    /// Returns `false` when the pane is unknown.
    func sendKeys(paneId: String?, text: String, keys: [String]) -> Bool

    /// Resolve the agent status for session/pane `id`. Reports pane EXISTENCE separately from agent-status
    /// presence (``AgentStatusResolution``) so `watch:claude` can keep polling through the agent-startup
    /// window (`resolvedNoStatus`) and reserve "never seen" → exit 4 for an id that resolves to no pane
    /// (`unresolved`).
    func agentStatus(id: String) -> AgentStatusResolution
}
