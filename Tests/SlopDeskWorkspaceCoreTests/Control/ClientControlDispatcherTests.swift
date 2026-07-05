import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

// E20 WI-2 — `ClientControlDispatcher` tests.
//
// Each method: parse → dispatch → response with a FAKE ``ClientControlBackend`` (no socket, no GUI).
// Plus the validate-then-drop contract: hostile / short / malformed input ALWAYS yields an error
// response and NEVER traps (force-unwrap would crash these cases — the un-fixed code fails).

// MARK: - Fake backend

/// A recording fake. Each method returns a canned value and records the args the dispatcher passed,
/// so a test can assert the dispatcher validated/decoded the request before delegating.
@MainActor
private final class FakeClientControlBackend: ClientControlBackend {
    // Canned returns
    var windowsReturn: [ClientWindowInfo] = []
    var tabsReturn: [ClientTabInfo] = []
    var panesReturn: [ClientPaneInfo] = []
    var setTabBadgeReturn = true
    var jumpReturn: ClientJumpOutcome?
    var learnReturn: String? = "/learned/dir"
    var ignoreReturn = true
    var openReturn = true
    var configGetReturn: String?
    var configSetReturn = true
    var configUnsetReturn = true
    var configReloadReturn = true
    var configShowReturn: [ClientConfigEntry] = []
    var themesReturn: [ClientThemeInfo] = []
    var fontsReturn: [ClientFontInfo] = []
    var keybindsReturn: [ClientKeybindInfo] = []
    var capturePaneReturn: [String]? = []
    var sendKeysReturn = true
    var agentStatusByID: [String: ClaudeStatus] = [:]
    /// Ids that resolve to a live pane but carry NO agent status yet (the startup window) → `resolvedNoStatus`.
    var resolvedNoStatusIDs: Set<String> = []

    // Recorded args
    var recordedTabsWindowId: String?
    var recordedPanesTabId: String?
    var recordedBadgeKind: TabBadgeKind?
    var recordedBadgeTabId: String?
    var recordedJumpQuery: String?
    var recordedJumpChangeDir: Bool?
    var learnCalled = false
    var recordedLearnPath: String?
    var recordedIgnorePath: String?
    var recordedOpenTarget: String?
    var recordedOpenMode: ClientControlOpenMode?
    var recordedOpenPlacement: ClientControlProtocol.Placement?
    var recordedConfigGetKey: String?
    var recordedConfigSetKey: String?
    var recordedConfigSetValue: String?
    var recordedConfigSetTransient: Bool?
    var recordedConfigUnsetKey: String?
    var recordedConfigUnsetTransient: Bool?
    var recordedThemeColor: ClientControlProtocol.ThemeColorFilter?
    var recordedFontMonospace: Bool?
    var recordedFontFamily: String?
    var recordedFontScope: ClientControlProtocol.FontScope?
    var recordedKeybindFilter: String?
    var recordedCapturePaneId: String?
    var recordedCaptureLines: Int?
    var recordedSendPaneId: String?
    var recordedSendText: String?
    var recordedSendKeys: [String]?
    var recordedAgentStatusId: String?

    func listWindows() -> [ClientWindowInfo] { windowsReturn }

    func listTabs(windowId: String?) -> [ClientTabInfo] {
        recordedTabsWindowId = windowId
        return tabsReturn
    }

    func listPanes(tabId: String?) -> [ClientPaneInfo] {
        recordedPanesTabId = tabId
        return panesReturn
    }

    func setTabBadge(tabId: String?, kind: TabBadgeKind) -> Bool {
        recordedBadgeTabId = tabId
        recordedBadgeKind = kind
        return setTabBadgeReturn
    }

    func jump(query: String?, changeDirectory: Bool) -> ClientJumpOutcome? {
        recordedJumpQuery = query
        recordedJumpChangeDir = changeDirectory
        return jumpReturn
    }

    func learn(path: String?) -> String? {
        learnCalled = true
        recordedLearnPath = path
        return learnReturn
    }

    func ignore(path: String) -> Bool {
        recordedIgnorePath = path
        return ignoreReturn
    }

    func open(target: String, mode: ClientControlOpenMode, placement: ClientControlProtocol.Placement) -> Bool {
        recordedOpenTarget = target
        recordedOpenMode = mode
        recordedOpenPlacement = placement
        return openReturn
    }

    func configGet(key: String) -> String? {
        recordedConfigGetKey = key
        return configGetReturn
    }

    func configSet(key: String, value: String, transient: Bool) -> Bool {
        recordedConfigSetKey = key
        recordedConfigSetValue = value
        recordedConfigSetTransient = transient
        return configSetReturn
    }

    func configUnset(key: String, transient: Bool) -> Bool {
        recordedConfigUnsetKey = key
        recordedConfigUnsetTransient = transient
        return configUnsetReturn
    }

    func configReload() -> Bool { configReloadReturn }

    func configShow() -> [ClientConfigEntry] { configShowReturn }

    func listThemes(color: ClientControlProtocol.ThemeColorFilter) -> [ClientThemeInfo] {
        recordedThemeColor = color
        return themesReturn
    }

    func listFonts(
        monospaceOnly: Bool,
        family: String?,
        scope: ClientControlProtocol.FontScope?,
    ) -> [ClientFontInfo] {
        recordedFontMonospace = monospaceOnly
        recordedFontFamily = family
        recordedFontScope = scope
        return fontsReturn
    }

    func listKeybinds(actionFilter: String?) -> [ClientKeybindInfo] {
        recordedKeybindFilter = actionFilter
        return keybindsReturn
    }

    func capturePane(paneId: String?, lines: Int) -> [String]? {
        recordedCapturePaneId = paneId
        recordedCaptureLines = lines
        return capturePaneReturn
    }

    func sendKeys(paneId: String?, text: String, keys: [String]) -> Bool {
        recordedSendPaneId = paneId
        recordedSendText = text
        recordedSendKeys = keys
        return sendKeysReturn
    }

    func agentStatus(id: String) -> AgentStatusResolution {
        recordedAgentStatusId = id
        if let status = agentStatusByID[id] { return .status(status) }
        if resolvedNoStatusIDs.contains(id) { return .resolvedNoStatus }
        return .unresolved
    }
}

// MARK: - Tests

@MainActor
final class ClientControlDispatcherTests: XCTestCase {
    /// XCTest builds a FRESH test-case instance per test method, so each test gets its own backend
    /// (no shared state, no implicitly-unwrapped optional, no setUp/tearDown). `lazy` so the
    /// `@MainActor` init runs on first access inside a `@MainActor` test method, not in the
    /// (nonisolated) XCTestCase initializer.
    private lazy var backend = FakeClientControlBackend()
    /// A fresh dispatcher over the current `backend` (a value type sharing the same backend ref).
    private var dispatcher: ClientControlDispatcher { ClientControlDispatcher(backend: backend) }

    // MARK: Helpers

    /// Dispatch a method+params and return the response object.
    private func run(_ method: String, _ params: [String: Any] = [:], id: String = "1") -> [String: Any] {
        dispatcher.dispatch(id: id, method: method, params: params)
    }

    private func isOK(_ obj: [String: Any]) -> Bool { (obj["ok"] as? Bool) ?? false }
    private func result(_ obj: [String: Any]) -> [String: Any] { obj["result"] as? [String: Any] ?? [:] }
    private func errorMessage(_ obj: [String: Any]) -> String? { obj["error"] as? String }

    /// Decode a raw NDJSON response line into an object (for the `handleLine` hostile-input tests).
    /// Trims the trailing `\n` the dispatcher appends (the socket layer splits on it).
    private func decodeLine(_ line: String?) -> [String: Any]? {
        guard let line else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: windows / tabs / panes

    func testWindowsListsBackend() {
        backend.windowsReturn = [
            ClientWindowInfo(id: "w1", title: "One", tabCount: 2, isFocused: true),
            ClientWindowInfo(id: "w2", title: "Two", tabCount: 1, isFocused: false),
        ]
        let obj = run(ClientControlProtocol.Method.windows)
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(obj["id"] as? String, "1")
        let windows = result(obj)["windows"] as? [[String: Any]]
        XCTAssertEqual(windows?.count, 2)
        XCTAssertEqual(windows?.first?["id"] as? String, "w1")
        XCTAssertEqual(windows?.first?["tabCount"] as? Int, 2)
        XCTAssertEqual(windows?.first?["focused"] as? Bool, true)
    }

    func testTabsPassesWindowFilter() {
        _ = run(ClientControlProtocol.Method.tabs, ["windowId": "w9"])
        XCTAssertEqual(backend.recordedTabsWindowId, "w9")
    }

    func testTabsNoFilterIsNil() {
        _ = run(ClientControlProtocol.Method.tabs)
        XCTAssertNil(backend.recordedTabsWindowId)
    }

    func testTabsIncludesBadgeTokenOnlyWhenPresent() {
        backend.tabsReturn = [
            ClientTabInfo(id: "t1", windowId: "w1", title: "A", paneCount: 1, isFocused: true, badge: "running"),
            ClientTabInfo(id: "t2", windowId: "w1", title: "B", paneCount: 2, isFocused: false, badge: nil),
        ]
        let tabs = result(run(ClientControlProtocol.Method.tabs))["tabs"] as? [[String: Any]]
        XCTAssertEqual(tabs?.first?["badge"] as? String, "running")
        XCTAssertNil(tabs?.last?["badge"])
    }

    func testPanesPassesTabFilterAndCwd() {
        backend.panesReturn = [
            ClientPaneInfo(id: "p1", tabId: "t1", title: "sh", kind: "terminal", isFocused: true, cwd: "/tmp"),
        ]
        let obj = run(ClientControlProtocol.Method.panes, ["tabId": "t1"])
        XCTAssertEqual(backend.recordedPanesTabId, "t1")
        let panes = result(obj)["panes"] as? [[String: Any]]
        XCTAssertEqual(panes?.first?["cwd"] as? String, "/tmp")
    }

    // MARK: tab-badge

    func testTabBadgeValidKind() {
        let obj = run(ClientControlProtocol.Method.tabBadge, ["kind": "error", "tabId": "t1"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedBadgeKind, .error)
        XCTAssertEqual(backend.recordedBadgeTabId, "t1")
        XCTAssertEqual(result(obj)["kind"] as? String, "error")
    }

    func testTabBadgeUnreadMapsToFinished() {
        // `unread` has no distinct TabBadgeKind — it maps to the documented closest case `.finished`.
        let obj = run(ClientControlProtocol.Method.tabBadge, ["kind": "unread"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedBadgeKind, .finished)
        XCTAssertEqual(result(obj)["kind"] as? String, "finished")
    }

    func testTabBadgeAwaitingInputToken() {
        let obj = run(ClientControlProtocol.Method.tabBadge, ["kind": "awaiting-input"])
        XCTAssertEqual(backend.recordedBadgeKind, .awaitingInput)
        XCTAssertEqual(result(obj)["kind"] as? String, "awaiting-input")
    }

    func testTabBadgeUnknownKindErrors() {
        let obj = run(ClientControlProtocol.Method.tabBadge, ["kind": "purple"])
        XCTAssertFalse(isOK(obj))
        XCTAssertNil(backend.recordedBadgeKind)
        XCTAssertNotNil(errorMessage(obj))
    }

    func testTabBadgeMissingKindErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.tabBadge)))
    }

    func testTabBadgeNonStringKindDoesNotTrap() {
        // Hostile: kind is a number — must NOT force-unwrap/trap.
        let obj = run(ClientControlProtocol.Method.tabBadge, ["kind": 42])
        XCTAssertFalse(isOK(obj))
    }

    func testTabBadgeTabNotFound() {
        backend.setTabBadgeReturn = false
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.tabBadge, ["kind": "running"])))
    }

    // MARK: jump

    func testJumpResolvesAndChangesDir() throws {
        backend.jumpReturn = ClientJumpOutcome(path: "/repo", didChangeDirectory: true)
        let obj = run(ClientControlProtocol.Method.jump, ["query": "rep"])
        XCTAssertEqual(backend.recordedJumpQuery, "rep")
        XCTAssertTrue(try XCTUnwrap(backend.recordedJumpChangeDir))
        XCTAssertEqual(result(obj)["path"] as? String, "/repo")
        XCTAssertEqual(result(obj)["changed"] as? Bool, true)
    }

    func testJumpNoCdDoesNotChangeDir() throws {
        backend.jumpReturn = ClientJumpOutcome(path: "/repo", didChangeDirectory: false)
        _ = run(ClientControlProtocol.Method.jump, ["noCd": true])
        XCTAssertFalse(try XCTUnwrap(backend.recordedJumpChangeDir))
        XCTAssertNil(backend.recordedJumpQuery)
    }

    func testJumpNoTargetErrors() {
        backend.jumpReturn = nil
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.jump)))
    }

    // MARK: learn

    func testLearnPassesExplicitPath() {
        let obj = run(ClientControlProtocol.Method.learn, ["path": "/work/repo"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedLearnPath, "/work/repo")
        XCTAssertEqual(result(obj)["path"] as? String, "/learned/dir")
    }

    func testLearnNoPathPassesNil() {
        // No `path` → the dispatcher passes nil (the backend uses the focused pane's cwd).
        let obj = run(ClientControlProtocol.Method.learn)
        XCTAssertTrue(isOK(obj))
        XCTAssertTrue(backend.learnCalled)
        XCTAssertNil(backend.recordedLearnPath)
    }

    func testLearnNonStringPathPassesNil() {
        // Hostile: path is a number → treated as absent (no-arg), never a trap.
        let obj = run(ClientControlProtocol.Method.learn, ["path": 42])
        XCTAssertTrue(isOK(obj))
        XCTAssertNil(backend.recordedLearnPath)
    }

    func testLearnNoDirectoryErrors() {
        // Backend reports it could resolve neither a path nor a focused-pane cwd.
        backend.learnReturn = nil
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.learn)))
    }

    // MARK: ignore

    func testIgnoreRemovesPath() {
        let obj = run(ClientControlProtocol.Method.ignore, ["path": "/old/dir"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedIgnorePath, "/old/dir")
        XCTAssertEqual(result(obj)["path"] as? String, "/old/dir")
    }

    func testIgnoreMissingPathErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.ignore)))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.ignore, ["path": ""])))
        XCTAssertNil(backend.recordedIgnorePath)
    }

    func testIgnoreNonStringPathDoesNotTrap() {
        let obj = run(ClientControlProtocol.Method.ignore, ["path": 7])
        XCTAssertFalse(isOK(obj))
        XCTAssertNil(backend.recordedIgnorePath)
    }

    func testIgnoreStoreUnavailableErrors() {
        backend.ignoreReturn = false
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.ignore, ["path": "/x"])))
    }

    // MARK: view / edit

    func testViewDefaultPlacementNewTab() {
        let obj = run(ClientControlProtocol.Method.view, ["target": "/etc/hosts"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedOpenMode, .view)
        XCTAssertEqual(backend.recordedOpenPlacement, .newTab)
        XCTAssertEqual(backend.recordedOpenTarget, "/etc/hosts")
    }

    func testEditPlacementRight() {
        let obj = run(ClientControlProtocol.Method.edit, ["target": "a.txt", "placement": "right"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedOpenMode, .edit)
        XCTAssertEqual(backend.recordedOpenPlacement, .right)
    }

    func testViewMissingTargetErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.view)))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.view, ["target": ""])))
    }

    func testViewInvalidPlacementErrors() {
        let obj = run(ClientControlProtocol.Method.view, ["target": "x", "placement": "diagonal"])
        XCTAssertFalse(isOK(obj))
        XCTAssertNil(backend.recordedOpenPlacement)
    }

    func testViewOpenFailureErrors() {
        backend.openReturn = false
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.view, ["target": "x"])))
    }

    func testViewParsesEveryPlacementToken() {
        // Each placement token routes to the matching `Placement` (revert-to-confirm-fail: dropping the
        // placement parse would collapse every case to the default `.newTab`).
        for placement in ClientControlProtocol.Placement.allCases {
            backend.recordedOpenPlacement = nil
            let obj = run(ClientControlProtocol.Method.view, ["target": "/f", "placement": placement.rawValue])
            XCTAssertTrue(isOK(obj), "placement \(placement.rawValue) should dispatch")
            XCTAssertEqual(backend.recordedOpenPlacement, placement)
        }
    }

    func testEditDefaultsToNewTabPlacement() {
        let obj = run(ClientControlProtocol.Method.edit, ["target": "a.txt"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedOpenMode, .edit)
        XCTAssertEqual(backend.recordedOpenPlacement, .newTab)
    }

    func testViewNonStringTargetDoesNotTrap() {
        // Hostile: target is a number → "missing target" error, never a force-unwrap trap.
        let obj = run(ClientControlProtocol.Method.view, ["target": 42])
        XCTAssertFalse(isOK(obj))
        XCTAssertNil(backend.recordedOpenTarget)
    }

    func testViewNonStringPlacementFallsBackToNewTab() {
        // Hostile: placement is a number → treated as absent → the default `.newTab`, never a trap.
        let obj = run(ClientControlProtocol.Method.view, ["target": "/f", "placement": 7])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedOpenPlacement, .newTab)
    }

    // MARK: config

    func testConfigGetSetValue() {
        backend.configGetReturn = "14"
        let obj = run(ClientControlProtocol.Method.configGet, ["key": "font-size"])
        XCTAssertEqual(backend.recordedConfigGetKey, "font-size")
        XCTAssertEqual(result(obj)["value"] as? String, "14")
        XCTAssertEqual(result(obj)["key"] as? String, "font-size")
    }

    func testConfigGetUnsetIsOKWithoutValue() {
        backend.configGetReturn = nil
        let obj = run(ClientControlProtocol.Method.configGet, ["key": "missing"])
        XCTAssertTrue(isOK(obj))
        XCTAssertNil(result(obj)["value"])
    }

    func testConfigGetMissingKeyErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configGet)))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configGet, ["key": ""])))
    }

    /// `--transient` is HONESTLY REJECTED at the dispatcher BEFORE the backend is touched: slopdesk applies
    /// config live through the same model that persists it (no apply-without-persist layer), so the pre-fix
    /// behavior (echo `transient:true` while the backend silently persisted) was a lie. Revert-to-confirm-fail:
    /// the pre-fix dispatcher returned ok + `transient:true` and recorded the backend call.
    func testConfigSetTransientIsHonestlyRejected() {
        let obj = run(
            ClientControlProtocol.Method.configSet,
            ["key": "font-size", "value": "16", "transient": true],
        )
        XCTAssertFalse(isOK(obj), "--transient is rejected, not a silent persist")
        XCTAssertNil(backend.recordedConfigSetKey, "the backend is never invoked for a transient set")
        XCTAssertTrue((errorMessage(obj) ?? "").contains("--transient"), "the error names the rejected flag")
    }

    func testConfigSetDefaultsTransientFalse() throws {
        _ = run(ClientControlProtocol.Method.configSet, ["key": "k", "value": "v"])
        XCTAssertFalse(try XCTUnwrap(backend.recordedConfigSetTransient))
    }

    func testConfigSetMissingValueErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configSet, ["key": "k"])))
    }

    func testConfigSetRejected() {
        backend.configSetReturn = false
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configSet, ["key": "k", "value": "v"])))
    }

    func testConfigUnsetPersisted() throws {
        let obj = run(ClientControlProtocol.Method.configUnset, ["key": "font-size"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedConfigUnsetKey, "font-size")
        XCTAssertFalse(try XCTUnwrap(backend.recordedConfigUnsetTransient))
        XCTAssertEqual(result(obj)["key"] as? String, "font-size")
    }

    func testConfigUnsetTransientIsHonestlyRejected() {
        let obj = run(ClientControlProtocol.Method.configUnset, ["key": "font-size", "transient": true])
        XCTAssertFalse(isOK(obj), "--transient unset is rejected, not a silent persist")
        XCTAssertNil(backend.recordedConfigUnsetKey, "the backend is never invoked for a transient unset")
        XCTAssertTrue((errorMessage(obj) ?? "").contains("--transient"), "the error names the rejected flag")
    }

    func testConfigUnsetMissingKeyErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configUnset)))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configUnset, ["key": ""])))
        XCTAssertNil(backend.recordedConfigUnsetKey)
    }

    func testConfigUnsetRejected() {
        backend.configUnsetReturn = false
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configUnset, ["key": "k"])))
    }

    func testConfigReload() {
        XCTAssertTrue(isOK(run(ClientControlProtocol.Method.configReload)))
        backend.configReloadReturn = false
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.configReload)))
    }

    func testConfigShowOrderedEntries() {
        backend.configShowReturn = [
            ClientConfigEntry(key: "theme", value: "Monokai"),
            ClientConfigEntry(key: "font-size", value: "14"),
        ]
        let entries = result(run(ClientControlProtocol.Method.configShow))["config"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?.first?["key"] as? String, "theme")
        XCTAssertEqual(entries?.last?["key"] as? String, "font-size")
    }

    // MARK: theme / font / keybind

    func testThemeListDefaultColorAll() {
        backend.themesReturn = [ClientThemeInfo(name: "Paper", isDark: false, isActive: true)]
        let obj = run(ClientControlProtocol.Method.themeList)
        XCTAssertEqual(backend.recordedThemeColor, .all)
        let themes = result(obj)["themes"] as? [[String: Any]]
        XCTAssertEqual(themes?.first?["name"] as? String, "Paper")
        XCTAssertEqual(themes?.first?["active"] as? Bool, true)
    }

    func testThemeListColorFilter() {
        _ = run(ClientControlProtocol.Method.themeList, ["color": "dark"])
        XCTAssertEqual(backend.recordedThemeColor, .dark)
    }

    func testThemeListInvalidColorErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.themeList, ["color": "ultraviolet"])))
    }

    func testFontListFilters() throws {
        let obj = run(
            ClientControlProtocol.Method.fontList,
            ["monospace": true, "family": "Mono", "scope": "user"],
        )
        XCTAssertTrue(isOK(obj))
        XCTAssertTrue(try XCTUnwrap(backend.recordedFontMonospace))
        XCTAssertEqual(backend.recordedFontFamily, "Mono")
        XCTAssertEqual(backend.recordedFontScope, .user)
    }

    func testFontListInvalidScopeErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.fontList, ["scope": "cloud"])))
    }

    func testKeybindListFilter() {
        backend.keybindsReturn = [ClientKeybindInfo(action: "newTab", keys: "cmd+t")]
        let obj = run(ClientControlProtocol.Method.keybindList, ["action": "tab"])
        XCTAssertEqual(backend.recordedKeybindFilter, "tab")
        let binds = result(obj)["keybinds"] as? [[String: Any]]
        XCTAssertEqual(binds?.first?["keys"] as? String, "cmd+t")
    }

    // MARK: pane-capture

    func testPaneCaptureDefaultLines() {
        backend.capturePaneReturn = ["a", "b"]
        let obj = run(ClientControlProtocol.Method.paneCapture)
        XCTAssertEqual(backend.recordedCaptureLines, ClientControlDispatcher.defaultCaptureLines)
        XCTAssertEqual(result(obj)["lines"] as? [String], ["a", "b"])
    }

    func testPaneCaptureClampsHugeCount() {
        _ = run(ClientControlProtocol.Method.paneCapture, ["lines": 5_000_000])
        XCTAssertEqual(backend.recordedCaptureLines, ClientControlDispatcher.maxCaptureLines)
    }

    func testPaneCapturePassesPaneIdAndLines() {
        _ = run(ClientControlProtocol.Method.paneCapture, ["paneId": "p1", "lines": 25])
        XCTAssertEqual(backend.recordedCapturePaneId, "p1")
        XCTAssertEqual(backend.recordedCaptureLines, 25)
    }

    func testPaneCaptureNonPositiveLinesErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneCapture, ["lines": 0])))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneCapture, ["lines": -10])))
        XCTAssertNil(backend.recordedCaptureLines)
    }

    func testPaneCaptureNonIntLinesDoesNotTrap() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneCapture, ["lines": "lots"])))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneCapture, ["lines": 1.5])))
    }

    func testPaneCapturePaneNotFound() {
        backend.capturePaneReturn = nil
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneCapture, ["lines": 5])))
    }

    // MARK: pane-send-keys

    func testSendKeysTextVerbatim() {
        let obj = run(
            ClientControlProtocol.Method.paneSendKeys,
            ["paneId": "p1", "text": "ls -la", "keys": ["Enter"]],
        )
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(backend.recordedSendPaneId, "p1")
        XCTAssertEqual(backend.recordedSendText, "ls -la")
        XCTAssertEqual(backend.recordedSendKeys, ["Enter"])
    }

    func testSendKeysDropsNonStringElements() {
        _ = run(ClientControlProtocol.Method.paneSendKeys, ["keys": ["a", 5, "b", true]])
        XCTAssertEqual(backend.recordedSendKeys, ["a", "b"])
    }

    func testSendKeysNonArrayKeysErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneSendKeys, ["keys": "Enter"])))
    }

    func testSendKeysEmptyPayloadErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneSendKeys)))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneSendKeys, ["text": "", "keys": []])))
    }

    func testSendKeysPaneNotFound() {
        backend.sendKeysReturn = false
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.paneSendKeys, ["text": "x"])))
    }

    // MARK: agent-status

    func testAgentStatusSeen() {
        backend.agentStatusByID = ["s1": .needsPermission]
        let obj = run(ClientControlProtocol.Method.agentStatus, ["id": "s1"])
        XCTAssertEqual(backend.recordedAgentStatusId, "s1")
        XCTAssertEqual(result(obj)["seen"] as? Bool, true)
        XCTAssertEqual(result(obj)["status"] as? String, ClaudeStatus.needsPermission.rawValue)
    }

    func testAgentStatusNeverSeen() {
        // An id that resolves to NO pane → `seen:false` (maps to watch:claude exit 4).
        let obj = run(ClientControlProtocol.Method.agentStatus, ["id": "ghost"])
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(result(obj)["seen"] as? Bool, false)
        XCTAssertNil(result(obj)["status"])
    }

    func testAgentStatusResolvedButNoStatusYet() {
        // M6 regression: a pane that EXISTS but whose agent has not reported a status yet (the startup
        // window) must answer `seen:true` with NO status — so watch:claude keeps polling, NOT exit 4.
        // Revert-to-confirm-fail: the old `agentStatus(id:) -> ClaudeStatus?` returned nil here, which the
        // dispatcher encoded as `seen:false` → first-poll never-seen → exit 4.
        backend.resolvedNoStatusIDs = ["starting"]
        let obj = run(ClientControlProtocol.Method.agentStatus, ["id": "starting"])
        XCTAssertEqual(backend.recordedAgentStatusId, "starting")
        XCTAssertTrue(isOK(obj))
        XCTAssertEqual(result(obj)["seen"] as? Bool, true)
        XCTAssertNil(result(obj)["status"])
    }

    func testAgentStatusMissingIdErrors() {
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.agentStatus)))
        XCTAssertFalse(isOK(run(ClientControlProtocol.Method.agentStatus, ["id": ""])))
    }

    // MARK: unknown method

    func testUnknownMethodErrors() {
        let obj = run("teleport")
        XCTAssertFalse(isOK(obj))
        XCTAssertEqual(obj["id"] as? String, "1")
        XCTAssertNotNil(errorMessage(obj))
    }

    // MARK: handleLine — hostile / short / malformed input (validate-then-drop, never trap)

    func testHandleLineBlankIsNil() {
        XCTAssertNil(dispatcher.handleLine(""))
        XCTAssertNil(dispatcher.handleLine("   \n  "))
    }

    func testHandleLineGarbageIsMalformed() {
        for raw in ["not json", "{", "{\"id\":", "[]", "12345", "\u{FFFF}{bad"] {
            let obj = decodeLine(dispatcher.handleLine(raw))
            XCTAssertNotNil(obj, "should still emit a response line for: \(raw)")
            XCTAssertEqual(obj?["ok"] as? Bool, false)
            XCTAssertEqual(obj?["id"] as? String, "?")
        }
    }

    func testHandleLineMissingFieldsMalformed() {
        // No id/method, id not a string, no method — all malformed (id "?"), never a trap.
        for raw in [
            "{}",
            #"{"id":123,"method":"windows"}"#,
            #"{"id":"x"}"#,
            #"{"method":"windows"}"#,
        ] {
            let obj = decodeLine(dispatcher.handleLine(raw))
            XCTAssertEqual(obj?["ok"] as? Bool, false, "raw: \(raw)")
            XCTAssertEqual(obj?["id"] as? String, "?")
        }
    }

    func testHandleLineValidRequestRoundTrips() {
        backend.windowsReturn = [ClientWindowInfo(id: "w1", title: "T", tabCount: 1, isFocused: true)]
        let obj = decodeLine(dispatcher.handleLine(#"{"id":"7","method":"windows","params":{}}"#))
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(obj?["id"] as? String, "7")
        let res = obj?["result"] as? [String: Any]
        XCTAssertNotNil(res?["windows"])
    }

    func testHandleLineOversizedRejected() {
        let huge = "{\"id\":\"1\",\"method\":\"windows\",\"params\":{\"x\":\""
            + String(repeating: "a", count: ClientControlDispatcher.maxRequestBytes + 16) + "\"}}"
        let obj = decodeLine(dispatcher.handleLine(huge))
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["error"] as? String, "request too large")
    }

    func testHandleLineParamsNotObjectTreatedAsEmpty() {
        // `params` present but not an object → treated as empty params (windows needs none) → ok.
        let obj = decodeLine(dispatcher.handleLine(#"{"id":"3","method":"windows","params":"oops"}"#))
        XCTAssertEqual(obj?["ok"] as? Bool, true)
    }

    func testHandleLineUnknownMethodEchoesId() {
        let obj = decodeLine(dispatcher.handleLine(#"{"id":"9","method":"warp-drive"}"#))
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["id"] as? String, "9")
    }
}
