import Foundation

// E20 WI-2 — Client control protocol.
//
// The method-name vocabulary + param builders for the CLIENT-side control socket — the
// runtime-control surface the new `aislopdesk` CLI uses to drive the running client GUI
// (windows/tabs/panes, badges, jump/view/edit, config, theme/font/keybind dumps, pane
// capture/send-keys, agent status).
//
// This mirrors the style of `AislopdeskCtlCore/CtlCore.swift`'s `*Params` builders and reuses
// the SAME NDJSON line protocol: a request is `{"id":…,"method":…,"params":{…}}` and a response
// is `{"id":…,"ok":true,"result":{…}}` / `{"id":…,"ok":false,"error":"…"}`. The new CLI builds a
// request line with `AislopdeskCtlCore.encodeRequestLine(id:method:params:)` and one of these
// param builders, and decodes the reply with `AislopdeskCtlCore.decodeResponseLine(_:)`.
//
// PURE — no I/O, no socket, no SwiftUI. The dispatcher side (`ClientControlDispatcher`) parses a
// request line and dispatches against the `ClientControlBackend` seam.

/// The method names + param builders for the client control socket. A caseless namespace so the
/// CLI front-end and the dispatcher share ONE source of truth for the method strings (a typo on
/// either side can't drift) and the param shapes.
public enum ClientControlProtocol {
    // MARK: - Method names

    /// The wire method strings. The CLI sends one of these as the `method` field; the dispatcher
    /// switches on it. Hyphenated to match the host ctl verbs (`list-panes`) and the CLI surface.
    public enum Method {
        /// List all windows.
        public static let windows = "windows"
        /// List tabs (optionally scoped to a window).
        public static let tabs = "tabs"
        /// List panes (optionally scoped to a tab).
        public static let panes = "panes"
        /// Set a tab status badge.
        public static let tabBadge = "tab-badge"
        /// Resolve a frecency-ranked jump target and `cd` the focused pane (or just print it).
        public static let jump = "jump"
        /// Record a directory visit in the frecency database (no path → the focused pane's cached cwd).
        public static let learn = "learn"
        /// Remove a directory from the frecency database.
        public static let ignore = "ignore"
        /// Open a read-only `view` shim (`less <path>` / `open <url>`) in a new split/tab/window.
        public static let view = "view"
        /// Open an editable `edit` shim (`$EDITOR <path>`) in a new split/tab/window.
        public static let edit = "edit"
        /// Read one config key.
        public static let configGet = "config-get"
        /// Write one config key (persisted, or `--transient` for the running app only).
        public static let configSet = "config-set"
        /// Remove one config key (persisted, or `--transient` for the running app only).
        public static let configUnset = "config-unset"
        /// Broadcast the config-change notification to the running app.
        public static let configReload = "config-reload"
        /// Dump the full effective config.
        public static let configShow = "config-show"
        /// Enumerate themes (filtered by color appearance).
        public static let themeList = "theme-list"
        /// Enumerate fonts.
        public static let fontList = "font-list"
        /// Enumerate keybindings (optionally filtered by action substring).
        public static let keybindList = "keybind-list"
        /// Capture the last N lines of a pane's scrollback.
        public static let paneCapture = "pane-capture"
        /// Send literal text + named keys to a pane (VERBATIM; named keys via the keycode path).
        public static let paneSendKeys = "pane-send-keys"
        /// Poll an agent session's rolled-up status (for `watch:claude`).
        public static let agentStatus = "agent-status"

        /// Every recognised method — the dispatcher rejects anything outside this set.
        public static let all: Set<String> = [
            windows, tabs, panes, tabBadge, jump, learn, ignore, view, edit,
            configGet, configSet, configUnset, configReload, configShow,
            themeList, fontList, keybindList, paneCapture, paneSendKeys, agentStatus,
        ]
    }

    // MARK: - Tab-badge tokens

    /// The badge tokens a `tab badge --kind <token>` accepts (`docs/ui-shell/spec/reference__cli.md`):
    /// `running`, `completed`, `finished`, `unread`, `error`, `awaiting-input`. `unread` has no
    /// distinct ``TabBadgeKind`` — it maps to the documented closest case ``TabBadgeKind/finished``
    /// (literally the "unread output" marker in `TabBadge.swift`). The privilege badges
    /// (`caffeinate`/`sudo`) are NOT settable via the CLI — they are foreground-process derived — so
    /// they are absent from the SETTABLE set but present in the reverse token map for listing.
    public static let settableBadgeTokens: [String: TabBadgeKind] = [
        "running": .running,
        "completed": .completed,
        "finished": .finished,
        "unread": .finished,
        "error": .error,
        "awaiting-input": .awaitingInput,
    ]

    /// Parse a settable badge token into a ``TabBadgeKind``; `nil` for an unknown token
    /// (validate-then-drop — the dispatcher turns this into an error response, never a trap).
    public static func tabBadgeKind(forToken token: String) -> TabBadgeKind? {
        settableBadgeTokens[token]
    }

    /// The canonical token for a resolved ``TabBadgeKind`` (used when LISTING a tab's current badge).
    /// Total over every case so the reverse map can't miss a future badge. `unread`↔`finished` is a
    /// many-to-one mapping, so the reverse of ``TabBadgeKind/finished`` is the canonical `finished`.
    public static func badgeToken(for kind: TabBadgeKind) -> String {
        switch kind {
        case .running: "running"
        case .completed: "completed"
        case .finished: "finished"
        case .error: "error"
        case .awaitingInput: "awaiting-input"
        case .caffeinate: "caffeinate"
        case .sudo: "sudo"
        }
    }

    // MARK: - Placement tokens (view/edit)

    /// Where a `view`/`edit` shim opens (`--new-tab` default / `--new-window` / split sides).
    public enum Placement: String, Sendable, Equatable, CaseIterable {
        case newTab = "new-tab"
        case newWindow = "new-window"
        case left
        case right
        case top
        case bottom
    }

    /// Parse a placement token; `nil` for an unknown token (validate-then-drop).
    public static func placement(forToken token: String) -> Placement? {
        Placement(rawValue: token)
    }

    // MARK: - Theme color filter / font scope tokens

    /// `theme list --color <dark|light|all>` filter.
    public enum ThemeColorFilter: String, Sendable, Equatable, CaseIterable {
        case dark
        case light
        case all
    }

    /// Parse a theme-color filter token; `nil` for unknown.
    public static func themeColorFilter(forToken token: String) -> ThemeColorFilter? {
        ThemeColorFilter(rawValue: token)
    }

    /// `font list --system`/`--user` scope.
    public enum FontScope: String, Sendable, Equatable, CaseIterable {
        case system
        case user
    }

    /// Parse a font-scope token; `nil` for unknown.
    public static func fontScope(forToken token: String) -> FontScope? {
        FontScope(rawValue: token)
    }

    // MARK: - Param builders (mirror CtlCore `*Params` style)

    /// `windows` — no params.
    public static func windowsParams() -> [String: Any] { [:] }

    /// `tabs` — optional `windowId` filter (omit to list every window's tabs).
    public static func tabsParams(windowId: String? = nil) -> [String: Any] {
        var params: [String: Any] = [:]
        if let windowId { params["windowId"] = windowId }
        return params
    }

    /// `panes` — optional `tabId` filter (omit to list every tab's panes).
    public static func panesParams(tabId: String? = nil) -> [String: Any] {
        var params: [String: Any] = [:]
        if let tabId { params["tabId"] = tabId }
        return params
    }

    /// `tab-badge` — set `kind` on a tab (default: the focused tab).
    public static func tabBadgeParams(kind: String, tabId: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["kind": kind]
        if let tabId { params["tabId"] = tabId }
        return params
    }

    /// `jump` — optional `query`; `noCd` prints the resolved path without sending `cd`.
    public static func jumpParams(query: String? = nil, noCd: Bool = false) -> [String: Any] {
        var params: [String: Any] = ["noCd": noCd]
        if let query { params["query"] = query }
        return params
    }

    /// `learn` — optional `path` (omit to record the focused pane's cached OSC-7 cwd).
    public static func learnParams(path: String? = nil) -> [String: Any] {
        var params: [String: Any] = [:]
        if let path { params["path"] = path }
        return params
    }

    /// `ignore` — the `path` to remove from the frecency database.
    public static func ignoreParams(path: String) -> [String: Any] {
        ["path": path]
    }

    /// `view` — `target` (path or URL) + optional `placement` token (default `new-tab`).
    public static func viewParams(target: String, placement: Placement = .newTab) -> [String: Any] {
        ["target": target, "placement": placement.rawValue]
    }

    /// `edit` — `target` (path or URL) + optional `placement` token (default `new-tab`).
    public static func editParams(target: String, placement: Placement = .newTab) -> [String: Any] {
        ["target": target, "placement": placement.rawValue]
    }

    /// `config-get` — one `key`.
    public static func configGetParams(key: String) -> [String: Any] {
        ["key": key]
    }

    /// `config-set` — `key`/`value`; `transient` writes the running app only (no persist).
    public static func configSetParams(key: String, value: String, transient: Bool = false) -> [String: Any] {
        ["key": key, "value": value, "transient": transient]
    }

    /// `config-unset` — remove `key`; `transient` removes from the running app only (no persist).
    public static func configUnsetParams(key: String, transient: Bool = false) -> [String: Any] {
        ["key": key, "transient": transient]
    }

    /// `config-reload` — no params.
    public static func configReloadParams() -> [String: Any] { [:] }

    /// `config-show` — no params.
    public static func configShowParams() -> [String: Any] { [:] }

    /// `theme-list` — optional `color` filter token (default `all`).
    public static func themeListParams(color: ThemeColorFilter = .all) -> [String: Any] {
        ["color": color.rawValue]
    }

    /// `font-list` — optional `monospace` filter, `family` substring, and `scope` token.
    public static func fontListParams(
        monospace: Bool = false,
        family: String? = nil,
        scope: FontScope? = nil,
    ) -> [String: Any] {
        var params: [String: Any] = ["monospace": monospace]
        if let family { params["family"] = family }
        if let scope { params["scope"] = scope.rawValue }
        return params
    }

    /// `keybind-list` — optional `action` substring filter.
    public static func keybindListParams(action: String? = nil) -> [String: Any] {
        var params: [String: Any] = [:]
        if let action { params["action"] = action }
        return params
    }

    /// `pane-capture` — optional `paneId` (default: the focused pane) + `lines` count.
    public static func paneCaptureParams(paneId: String? = nil, lines: Int) -> [String: Any] {
        var params: [String: Any] = ["lines": lines]
        if let paneId { params["paneId"] = paneId }
        return params
    }

    /// `pane-send-keys` — optional `paneId` (default: the focused pane), literal `text`, and an
    /// ordered list of named `keys` (VERBATIM text + keycode-path named keys; never SendKeysParser).
    public static func paneSendKeysParams(
        paneId: String? = nil,
        text: String = "",
        keys: [String] = [],
    ) -> [String: Any] {
        var params: [String: Any] = ["text": text, "keys": keys]
        if let paneId { params["paneId"] = paneId }
        return params
    }

    /// `agent-status` — poll the agent session identified by `id`.
    public static func agentStatusParams(id: String) -> [String: Any] {
        ["id": id]
    }
}
