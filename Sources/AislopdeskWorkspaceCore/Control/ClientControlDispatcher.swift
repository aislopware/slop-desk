import AislopdeskAgentDetect
import Foundation

// E20 WI-2 — Client control dispatcher.
//
// The PURE verb dispatcher for the client control socket. Given a parsed request triple
// `(id, method, params)` and a ``ClientControlBackend``, it runs the verb and returns the NDJSON
// response object. The thin AF_UNIX shim (`ClientControlServer`, WI-3, compiled-only) reads request
// lines, calls ``handleLine(_:)``, and writes the reply — mirroring the host's
// `AgentControlAcceptor`/`AgentControlHandler` split so the dispatch logic is unit-testable against a
// FAKE backend with NO socket and NO GUI (hang-safety rule).
//
// ## Validate-then-drop (CLAUDE.md untrusted-input contract)
// Every request field is validated BEFORE it is used; counts/lengths are bounded BEFORE the backend
// allocates; there is no force-unwrap (`!`) and no trap on a hostile or short datagram. A malformed
// line, a missing required param, an out-of-range count, or an unknown method all produce an
// `ok:false` error response — never a crash. A `nil`/`false` backend return (target not found)
// likewise becomes an error response.

/// The PURE client-control verb dispatcher. `@MainActor` because every ``ClientControlBackend`` op
/// touches a `@MainActor` client store; the dispatch decisions themselves are deterministic and
/// side-effect-free apart from the backend calls.
@preconcurrency
@MainActor
public struct ClientControlDispatcher {
    private let backend: any ClientControlBackend

    /// Max bytes per request line (validate-then-drop beyond this) — matches the host ctl socket.
    static let maxRequestBytes = 64 * 1024
    /// Default `pane-capture` line count when the request omits `lines`.
    static let defaultCaptureLines = 100
    /// Upper bound on `pane-capture` `lines` so a hostile count can't force an unbounded read.
    static let maxCaptureLines = 100_000
    /// Honest rejection for `config set/unset --transient`: aislopdesk applies render settings LIVE through the
    /// same typed model that persists them, so there is no apply-without-persist layer. Rejecting beats the
    /// pre-fix lie (persist silently while reporting `transient:true`). See `docs/DECISIONS.md`.
    static let transientUnsupportedMessage =
        "--transient is unsupported: aislopdesk applies config live AND persists it (no separate ephemeral "
            + "render layer); re-run without --transient to apply (and persist), or config unset to revert"

    public init(backend: any ClientControlBackend) {
        self.backend = backend
    }

    // MARK: - Line entry point

    /// Parse a raw NDJSON request line and return the response line (UTF-8, newline-terminated), or
    /// `nil` for a blank/whitespace-only line (nothing to respond to). Validate-then-drop: an
    /// oversized, non-JSON, or structurally-malformed line yields an error response (id `"?"`), never
    /// a trap.
    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= Self.maxRequestBytes else {
            return Self.encodeLine(Self.error(id: "?", message: "request too large"))
        }
        guard let (id, method, params) = Self.parseRequest(trimmed) else {
            return Self.encodeLine(Self.error(id: "?", message: "malformed request"))
        }
        return Self.encodeLine(dispatch(id: id, method: method, params: params))
    }

    // MARK: - Dispatch

    /// Dispatch one decoded request to the backend and return the response OBJECT (id + ok +
    /// result/error). The socket shim serializes it via ``encodeLine(_:)``; tests can inspect the
    /// dict directly.
    public func dispatch(id: String, method: String, params: [String: Any]) -> [String: Any] {
        switch method {
        case ClientControlProtocol.Method.windows:
            windows(id: id)
        case ClientControlProtocol.Method.tabs:
            tabs(id: id, params: params)
        case ClientControlProtocol.Method.panes:
            panes(id: id, params: params)
        case ClientControlProtocol.Method.tabBadge:
            tabBadge(id: id, params: params)
        case ClientControlProtocol.Method.jump:
            jump(id: id, params: params)
        case ClientControlProtocol.Method.learn:
            learn(id: id, params: params)
        case ClientControlProtocol.Method.ignore:
            ignore(id: id, params: params)
        case ClientControlProtocol.Method.view:
            openShim(id: id, params: params, mode: .view)
        case ClientControlProtocol.Method.edit:
            openShim(id: id, params: params, mode: .edit)
        case ClientControlProtocol.Method.configGet:
            configGet(id: id, params: params)
        case ClientControlProtocol.Method.configSet:
            configSet(id: id, params: params)
        case ClientControlProtocol.Method.configUnset:
            configUnset(id: id, params: params)
        case ClientControlProtocol.Method.configReload:
            configReload(id: id)
        case ClientControlProtocol.Method.configShow:
            configShow(id: id)
        case ClientControlProtocol.Method.themeList:
            themeList(id: id, params: params)
        case ClientControlProtocol.Method.fontList:
            fontList(id: id, params: params)
        case ClientControlProtocol.Method.keybindList:
            keybindList(id: id, params: params)
        case ClientControlProtocol.Method.paneCapture:
            paneCapture(id: id, params: params)
        case ClientControlProtocol.Method.paneSendKeys:
            paneSendKeys(id: id, params: params)
        case ClientControlProtocol.Method.agentStatus:
            agentStatus(id: id, params: params)
        default:
            Self.error(id: id, message: "unknown method: \(method)")
        }
    }

    // MARK: - Verb implementations

    /// `windows` → `{windows: [{id, title, tabCount, focused}]}`.
    private func windows(id: String) -> [String: Any] {
        let items = backend.listWindows().map { w -> [String: Any] in
            ["id": w.id, "title": w.title, "tabCount": w.tabCount, "focused": w.isFocused]
        }
        return Self.success(id: id, result: ["windows": items])
    }

    /// `tabs` → `{tabs: [{id, windowId, title, paneCount, focused, badge?}]}`. Optional `windowId`
    /// filter (a present-but-non-string value is ignored — treated as "no filter").
    private func tabs(id: String, params: [String: Any]) -> [String: Any] {
        let windowId = params["windowId"] as? String
        let items = backend.listTabs(windowId: windowId).map { t -> [String: Any] in
            var d: [String: Any] = [
                "id": t.id, "windowId": t.windowId, "title": t.title,
                "paneCount": t.paneCount, "focused": t.isFocused,
            ]
            if let badge = t.badge { d["badge"] = badge }
            return d
        }
        return Self.success(id: id, result: ["tabs": items])
    }

    /// `panes` → `{panes: [{id, tabId, title, kind, focused, cwd?}]}`. Optional `tabId` filter.
    private func panes(id: String, params: [String: Any]) -> [String: Any] {
        let tabId = params["tabId"] as? String
        let items = backend.listPanes(tabId: tabId).map { p -> [String: Any] in
            var d: [String: Any] = [
                "id": p.id, "tabId": p.tabId, "title": p.title,
                "kind": p.kind, "focused": p.isFocused,
            ]
            if let cwd = p.cwd { d["cwd"] = cwd }
            return d
        }
        return Self.success(id: id, result: ["panes": items])
    }

    /// `tab-badge` → set `kind` on a tab. Validates the `kind` token; unknown token / missing kind /
    /// unknown tab → error.
    private func tabBadge(id: String, params: [String: Any]) -> [String: Any] {
        guard let token = params["kind"] as? String else {
            return Self.error(id: id, message: "missing params.kind")
        }
        guard let kind = ClientControlProtocol.tabBadgeKind(forToken: token) else {
            return Self.error(id: id, message: "invalid badge kind '\(token)'")
        }
        let tabId = params["tabId"] as? String
        guard backend.setTabBadge(tabId: tabId, kind: kind) else {
            return Self.error(id: id, message: "tab not found")
        }
        return Self.success(id: id, result: ["kind": ClientControlProtocol.badgeToken(for: kind)])
    }

    /// `jump` → resolve a frecency target and (unless `noCd`) `cd` the focused pane.
    private func jump(id: String, params: [String: Any]) -> [String: Any] {
        let query = params["query"] as? String
        let noCd = (params["noCd"] as? Bool) ?? false
        guard let outcome = backend.jump(query: query, changeDirectory: !noCd) else {
            return Self.error(id: id, message: "no jump target")
        }
        return Self.success(
            id: id,
            result: ["path": outcome.path, "changed": outcome.didChangeDirectory],
        )
    }

    /// `learn` → record a directory visit in the frecency DB. Optional `path` (omitted / non-string →
    /// the focused pane's cached cwd). No path AND no known cwd → error (never a trap).
    private func learn(id: String, params: [String: Any]) -> [String: Any] {
        let path = params["path"] as? String
        guard let recorded = backend.learn(path: path) else {
            return Self.error(id: id, message: "no directory to learn (give a path or focus a pane with a cwd)")
        }
        return Self.success(id: id, result: ["path": recorded])
    }

    /// `ignore` → remove a directory from the frecency DB. `path` required + non-empty (validate-then-drop).
    private func ignore(id: String, params: [String: Any]) -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            return Self.error(id: id, message: "missing params.path")
        }
        guard backend.ignore(path: path) else {
            return Self.error(id: id, message: "could not ignore path")
        }
        return Self.success(id: id, result: ["path": path])
    }

    /// `view`/`edit` → open a shim at a placement. Validates `target` (required, non-empty) and the
    /// optional `placement` token (default `new-tab`).
    private func openShim(
        id: String,
        params: [String: Any],
        mode: ClientControlOpenMode,
    ) -> [String: Any] {
        guard let target = params["target"] as? String, !target.isEmpty else {
            return Self.error(id: id, message: "missing params.target")
        }
        let placement: ClientControlProtocol.Placement
        if let token = params["placement"] as? String {
            guard let parsed = ClientControlProtocol.placement(forToken: token) else {
                return Self.error(id: id, message: "invalid placement '\(token)'")
            }
            placement = parsed
        } else {
            placement = .newTab
        }
        guard backend.open(target: target, mode: mode, placement: placement) else {
            return Self.error(id: id, message: "could not open target")
        }
        return Self.success(id: id, result: [:])
    }

    /// `config-get` → `{key, value?}`. An UNSET key is NOT an error (returns ok with no `value`).
    private func configGet(id: String, params: [String: Any]) -> [String: Any] {
        guard let key = params["key"] as? String, !key.isEmpty else {
            return Self.error(id: id, message: "missing params.key")
        }
        if let value = backend.configGet(key: key) {
            return Self.success(id: id, result: ["key": key, "value": value])
        }
        return Self.success(id: id, result: ["key": key])
    }

    /// `config-set` → write `key`=`value` (persisted, or `transient` running-app-only).
    private func configSet(id: String, params: [String: Any]) -> [String: Any] {
        guard let key = params["key"] as? String, !key.isEmpty else {
            return Self.error(id: id, message: "missing params.key")
        }
        guard let value = params["value"] as? String else {
            return Self.error(id: id, message: "missing params.value")
        }
        let transient = (params["transient"] as? Bool) ?? false
        if transient { return Self.error(id: id, message: Self.transientUnsupportedMessage) }
        guard backend.configSet(key: key, value: value, transient: transient) else {
            return Self.error(id: id, message: "config set rejected")
        }
        return Self.success(id: id, result: ["key": key, "value": value, "transient": transient])
    }

    /// `config-unset` → remove `key` (persisted, or `transient` running-app-only).
    private func configUnset(id: String, params: [String: Any]) -> [String: Any] {
        guard let key = params["key"] as? String, !key.isEmpty else {
            return Self.error(id: id, message: "missing params.key")
        }
        let transient = (params["transient"] as? Bool) ?? false
        if transient { return Self.error(id: id, message: Self.transientUnsupportedMessage) }
        guard backend.configUnset(key: key, transient: transient) else {
            return Self.error(id: id, message: "config unset rejected")
        }
        return Self.success(id: id, result: ["key": key, "transient": transient])
    }

    /// `config-reload` → broadcast the config-change notification.
    private func configReload(id: String) -> [String: Any] {
        guard backend.configReload() else {
            return Self.error(id: id, message: "config reload failed")
        }
        return Self.success(id: id, result: [:])
    }

    /// `config-show` → `{config: [{key, value}]}` (ordered).
    private func configShow(id: String) -> [String: Any] {
        let entries = backend.configShow().map { ["key": $0.key, "value": $0.value] }
        return Self.success(id: id, result: ["config": entries])
    }

    /// `theme-list` → `{themes: [{name, dark, active}]}`. Optional `color` token (default `all`).
    private func themeList(id: String, params: [String: Any]) -> [String: Any] {
        let color: ClientControlProtocol.ThemeColorFilter
        if let token = params["color"] as? String {
            guard let parsed = ClientControlProtocol.themeColorFilter(forToken: token) else {
                return Self.error(id: id, message: "invalid color filter '\(token)'")
            }
            color = parsed
        } else {
            color = .all
        }
        let items = backend.listThemes(color: color).map { t -> [String: Any] in
            ["name": t.name, "dark": t.isDark, "active": t.isActive]
        }
        return Self.success(id: id, result: ["themes": items])
    }

    /// `font-list` → `{fonts: [{family, monospace, system}]}`. Optional `monospace`/`family`/`scope`.
    private func fontList(id: String, params: [String: Any]) -> [String: Any] {
        let monospaceOnly = (params["monospace"] as? Bool) ?? false
        let family = params["family"] as? String
        var scope: ClientControlProtocol.FontScope?
        if let token = params["scope"] as? String {
            guard let parsed = ClientControlProtocol.fontScope(forToken: token) else {
                return Self.error(id: id, message: "invalid scope '\(token)'")
            }
            scope = parsed
        }
        let items = backend.listFonts(monospaceOnly: monospaceOnly, family: family, scope: scope)
            .map { f -> [String: Any] in
                ["family": f.family, "monospace": f.isMonospace, "system": f.isSystem]
            }
        return Self.success(id: id, result: ["fonts": items])
    }

    /// `keybind-list` → `{keybinds: [{action, keys}]}`. Optional `action` substring filter.
    private func keybindList(id: String, params: [String: Any]) -> [String: Any] {
        let actionFilter = params["action"] as? String
        let items = backend.listKeybinds(actionFilter: actionFilter).map { k -> [String: Any] in
            ["action": k.action, "keys": k.keys]
        }
        return Self.success(id: id, result: ["keybinds": items])
    }

    /// `pane-capture` → `{lines: [...]}`. Validates `lines` (positive Int, bounded) BEFORE the
    /// backend reads; an unknown pane → error.
    private func paneCapture(id: String, params: [String: Any]) -> [String: Any] {
        let paneId = params["paneId"] as? String
        let lines: Int
        if let raw = params["lines"] {
            guard let n = raw as? Int, n > 0 else {
                return Self.error(id: id, message: "lines must be a positive integer")
            }
            lines = min(n, Self.maxCaptureLines)
        } else {
            lines = Self.defaultCaptureLines
        }
        guard let captured = backend.capturePane(paneId: paneId, lines: lines) else {
            return Self.error(id: id, message: "pane not found")
        }
        return Self.success(id: id, result: ["lines": captured])
    }

    /// `pane-send-keys` → send literal `text` + named `keys` (VERBATIM text; keycode-path keys).
    /// Drops non-string `keys` elements; a non-array `keys`, an empty payload, or an unknown pane →
    /// error.
    private func paneSendKeys(id: String, params: [String: Any]) -> [String: Any] {
        let paneId = params["paneId"] as? String
        let text = params["text"] as? String ?? ""
        let keys: [String]
        if let rawKeys = params["keys"] {
            guard let arr = rawKeys as? [Any] else {
                return Self.error(id: id, message: "keys must be an array of strings")
            }
            keys = arr.compactMap { $0 as? String }
        } else {
            keys = []
        }
        guard !text.isEmpty || !keys.isEmpty else {
            return Self.error(id: id, message: "nothing to send (need text or keys)")
        }
        guard backend.sendKeys(paneId: paneId, text: text, keys: keys) else {
            return Self.error(id: id, message: "pane not found")
        }
        return Self.success(id: id, result: [:])
    }

    /// `agent-status` → `{seen, status?}`. `seen:false` (id resolves to NO pane) maps to `watch:claude`
    /// exit 4; `seen:true` with NO `status` (pane exists but the agent has not reported yet — the startup
    /// window) keeps `watch:claude` polling; `seen:true` + `status` carries the rolled-up status.
    private func agentStatus(id: String, params: [String: Any]) -> [String: Any] {
        guard let target = params["id"] as? String, !target.isEmpty else {
            return Self.error(id: id, message: "missing params.id")
        }
        switch backend.agentStatus(id: target) {
        case .unresolved:
            return Self.success(id: id, result: ["seen": false])
        case .resolvedNoStatus:
            return Self.success(id: id, result: ["seen": true])
        case let .status(status):
            return Self.success(id: id, result: ["seen": true, "status": status.rawValue])
        }
    }

    // MARK: - NDJSON helpers (pure, nonisolated — usable off the main actor by the socket shim)

    /// Build a success response object. Omits `result` when empty (matches the host ctl envelope).
    nonisolated static func success(id: String, result: [String: Any]) -> [String: Any] {
        var obj: [String: Any] = ["id": id, "ok": true]
        if !result.isEmpty { obj["result"] = result }
        return obj
    }

    /// Build an error response object.
    nonisolated static func error(id: String, message: String) -> [String: Any] {
        ["id": id, "ok": false, "error": message]
    }

    /// Serialize a response object to a NDJSON line (sorted keys + trailing `\n`). Falls back to a
    /// minimal error line on the (effectively impossible) serialization failure.
    nonisolated static func encodeLine(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(bytes: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"json encode failure"}"# + "\n"
        }
        return str + "\n"
    }

    /// Parse one NDJSON request line into `(id, method, params)`. Returns `nil` (validate-then-drop)
    /// when the line is not valid UTF-8 JSON, or `id`/`method` are missing / not strings.
    nonisolated static func parseRequest(_ line: String)
        -> (id: String, method: String, params: [String: Any])?
    {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String
        else { return nil }
        let params = obj["params"] as? [String: Any] ?? [:]
        return (id, method, params)
    }
}
