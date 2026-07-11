// E20 WI-3 — Client control backend over the live client stores.
//
// The concrete ``ClientControlBackend`` the ``ClientControlServer`` drives: adapts the running client
// GUI's `@MainActor` stores — ``WorkspaceStore`` (the `Session → Tab → Pane` tree), ``PreferencesStore``
// (render/appearance), ``ThemeStore`` / ``ThemeCatalog``, ``WorkspaceBindingRegistry`` (keybinds), and
// ``FolderFrecencyStore`` (jump) — onto the verb seam the PURE ``ClientControlDispatcher`` (WI-2) calls.
//
// ## Compiled-only (hang-safety)
// Like the host's `AgentControlListener`, this touches live GUI stores and is **never instantiated in a
// unit test** — the dispatcher is tested against a FAKE backend (WI-2 `ClientControlDispatcherTests`).
// Stores are held WEAKLY (the app owns them); a deallocated store degrades to empty/`nil`/`false`, never a trap.
//
// ## Validate-then-drop
// The dispatcher already validated + bounded every param before calling here (CLAUDE.md untrusted-input
// contract), so each method assumes well-formed inputs and only maps identity strings → tree nodes (a
// bad/unknown id → `nil` → the dispatcher emits an `ok:false` error, never a crash). Literal `cd` /
// send-keys / shim text is sent **VERBATIM UTF-8**; named keys go through a small explicit keycode table
// (never `SendKeysParser`), per CLAUDE.md.
//
// ## Refinement boundary (later work items)
// Every method wires against an existing seam so the socket is functional end-to-end at WI-3. The
// scrollback `pane capture` read's DEPTH lands with WI-4 (marked inline). `config get/set/unset/show/
// reload` drive the LIVE settings — `theme` retints via ``ThemeStore``, render keys reflow/retint via
// ``PreferencesStore``, unknown keys honestly error (no dead namespace / no `EnvConfig.overlay` write).
// `tab badge --kind` writes the store-side per-tab override the rail + `tab list` render (E20 ES-E20-3).
// The `view`/`edit` shim landed its new-pane placement in WI-6. None of these are on the golden wire; this
// is the NDJSON control plane only.

#if canImport(SwiftUI)
import Foundation
import SlopDeskAgentDetect
import SlopDeskCLICore // JumpResolver — the PURE frecency/$HOME-toggle/`--no-cd` jump resolution (WI-5)
import SlopDeskVideoProtocol // ThemeChoice — the typed theme selection the `config set theme` write maps onto
import SlopDeskWorkspaceCore
#if canImport(AppKit)
import AppKit // NSFontManager — the macOS font enumeration for `font list` (compiled-only; iOS = empty)
import CoreText // CTFontDescriptorCopyAttribute(kCTFontURLAttribute) — the per-face URL the scope split reads
#endif

/// The concrete ``ClientControlBackend`` over the live client stores. `@MainActor` (every store it adapts is
/// main-actor isolated); held by the ``ClientControlServer`` and called from the socket's per-connection
/// thread via a main-actor hop. Stores are weak — the app owns them, and a deallocated store degrades
/// gracefully.
@MainActor
final class WorkspaceControlBackend: ClientControlBackend {
    private weak var store: WorkspaceStore?
    private weak var preferences: PreferencesStore?
    private weak var folders: FolderFrecencyStore?

    /// The directory a prior no-query `jump` left — the mutable pole of the `$HOME`↔last-jump-source toggle
    /// (`reference__cli.md`). Held on this long-lived backend so the toggle persists across the separate,
    /// short-lived `slopdesk jump` CLI processes that drive it. `nil` until the first committed jump from `$HOME`.
    private var lastJumpSource: String?

    /// Posted by ``configReload()`` alongside its concrete re-apply, so any additional config-change
    /// observer can refresh — a broadcast hook beside the direct re-apply.
    static let configReloadNotification = Notification.Name("SlopDeskClientControlConfigReload")

    /// How long the `view`/`edit` shim defers its command injection while the new pane's prompt comes up.
    /// The pane's inherited cwd is applied host-side at PTY spawn, so relative paths already resolve there.
    /// Defaults to production 1500 ms; injectable so a test observes the deferred launch bytes without a 1.5 s wall.
    private let shimLaunchGrace: Duration

    init(
        store: WorkspaceStore,
        preferences: PreferencesStore,
        folders: FolderFrecencyStore,
        shimLaunchGrace: Duration = .milliseconds(1500),
    ) {
        self.store = store
        self.preferences = preferences
        self.folders = folders
        self.shimLaunchGrace = shimLaunchGrace
    }

    // MARK: - Windows / tabs / panes (the tree reads)

    func listWindows() -> [ClientWindowInfo] {
        guard let store else { return [] }
        let activeID = store.tree.activeSessionID
        return store.tree.sessions.map { session in
            ClientWindowInfo(
                id: session.id.raw.uuidString,
                title: session.name,
                tabCount: session.tabs.count,
                isFocused: session.id == activeID,
            )
        }
    }

    func listTabs(windowId: String?) -> [ClientTabInfo] {
        guard let store else { return [] }
        let activeSessionID = store.tree.activeSessionID
        var out: [ClientTabInfo] = []
        for session in store.tree.sessions {
            if let windowId, session.id.raw.uuidString != windowId { continue }
            let isActiveSession = session.id == activeSessionID
            for (index, tab) in session.tabs.enumerated() {
                out.append(ClientTabInfo(
                    id: tab.id.raw.uuidString,
                    windowId: session.id.raw.uuidString,
                    title: tabTitle(session: session, tab: tab),
                    paneCount: tab.allPaneIDs().count,
                    isFocused: isActiveSession && index == session.activeTabIndex,
                    badge: tabBadgeToken(session: session, tab: tab),
                ))
            }
        }
        return out
    }

    func listPanes(tabId: String?) -> [ClientPaneInfo] {
        guard let store else { return [] }
        let focused = focusedPaneID()
        var out: [ClientPaneInfo] = []
        for session in store.tree.sessions {
            for tab in session.tabs {
                if let tabId, tab.id.raw.uuidString != tabId { continue }
                for paneID in tab.allPaneIDs() {
                    let spec = session.specs[paneID]
                    out.append(ClientPaneInfo(
                        id: paneID.raw.uuidString,
                        tabId: tab.id.raw.uuidString,
                        title: spec?.lastKnownTitle ?? spec?.title ?? "",
                        kind: (spec?.kind ?? .terminal).rawValue,
                        isFocused: paneID == focused,
                        cwd: Self.nonEmpty(spec?.lastKnownCwd),
                    ))
                }
            }
        }
        return out
    }

    // MARK: - Tab badge

    /// Set the MANUAL status badge on a tab (focused tab when `tabId` is nil) — the `tab badge --kind` verb.
    /// Resolves the target ``TabID`` (unknown/absent → `false` → dispatcher's `tab not found`) and writes the
    /// per-tab override the rail + `tab list` consult AHEAD of the derived badge
    /// (``WorkspaceStore/setTabBadgeOverride(_:for:)``). The real ES-E20-3 write path — no longer reports
    /// success while doing nothing.
    func setTabBadge(tabId: String?, kind: TabBadgeKind) -> Bool {
        guard let store, let target = resolveTabID(tabId) else { return false }
        store.setTabBadgeOverride(kind, for: target)
        return true
    }

    // MARK: - Jump / learn / ignore (frecency)

    /// Resolve a frecency target via the PURE ``JumpResolver`` (frecency rank + `$HOME`↔last-jump toggle +
    /// `--no-cd`) and, unless `--no-cd`, `cd` the focused pane VERBATIM. Fed the live frecency entries, the
    /// focused pane's cached OSC-7 cwd, the resolved `$HOME`, and the persisted ``lastJumpSource``; its
    /// committed source is stored back (a no-op on a `--no-cd` preview).
    func jump(query: String?, changeDirectory: Bool) -> ClientJumpOutcome? {
        guard let folders else { return nil }
        guard let resolution = JumpResolver.resolve(
            query: query,
            entries: folders.entries,
            now: Date(),
            // `NSHomeDirectory()` is cross-platform (`FileManager.homeDirectoryForCurrentUser` is macOS-only).
            homePath: NSHomeDirectory(),
            currentCwd: focusedCwd(),
            lastJumpSource: lastJumpSource,
            changeDirectory: changeDirectory,
        ) else {
            return nil // a query matched no visited folder
        }
        // The resolver already accounted for `--no-cd` (an unchanged source on a preview), so assign
        // unconditionally; only the actual `cd` is gated on `changeDirectory`.
        lastJumpSource = resolution.lastJumpSource
        var didChange = false
        if changeDirectory, let handle = focusedHandle() {
            // The PATH is sent VERBATIM (CLAUDE.md: jump literal text never routes through `SendKeysParser`)
            // but SHELL-QUOTED — unquoted `cd /Users/x/My Project` would `cd` to `/Users/x/My`. Reuses the
            // shared `'…'`-with-`'\''` idiom (as zoxide does); only shell-safe quoting is added, the bytes
            // stay verbatim from the user's path. Enter == CR.
            handle.sendText("cd -- " + ShellQuoting.singleQuote(resolution.path))
            handle.sendBytes([0x0D])
            didChange = true
        }
        return ClientJumpOutcome(path: resolution.path, didChangeDirectory: didChange)
    }

    /// Record a directory visit in the frecency DB. A nil/blank `path` records the focused pane's cached
    /// OSC-7 cwd (the `learn` verb with no args). Returns the recorded path, or `nil` when neither a path nor a
    /// focused-pane cwd is available. The store itself validates-then-drops an over-long path.
    func learn(path: String?) -> String? {
        guard let folders else { return nil }
        let resolved: String
        if let explicit = Self.nonEmpty(path) {
            resolved = explicit
        } else if let cwd = focusedCwd() {
            resolved = cwd
        } else {
            return nil // no path given AND no focused-pane cwd known
        }
        folders.record(cwd: resolved)
        return resolved
    }

    /// Remove `path` from the frecency DB (the `ignore` verb). `forget` is idempotent — a path with no entry is
    /// a silent no-op — so this only reports `false` when the store has gone away.
    func ignore(path: String) -> Bool {
        guard let folders else { return false }
        folders.forget(path: path)
        return true
    }

    // MARK: - view / edit shim (WI-6)

    /// Open the read-only `view` / editor `edit` shim in a NEW pane (`--new-tab` default / `--new-window` /
    /// split side) — NOT a native local file renderer (an slopdesk pane IS a remote PTY; there is no local
    /// renderer — the documented E20 shim, carry-over §4). TYPES a shell command into the freshly-spawned
    /// pane: `view` → `open <url>` for a URL else `less <path>`; `edit` → `${EDITOR:-vi} <path>`. Injected
    /// through the SAME new-pane launch seam template panes use (``SessionTemplateEngine/launchBytes(cwd:command:)``),
    /// after the new pane's prompt appears. Returns `false` only when the placement op spawned no pane
    /// (e.g. no active session to split / new-tab into).
    func open(target: String, mode: ClientControlOpenMode, placement: ClientControlProtocol.Placement) -> Bool {
        guard let store else { return false }
        let command = Self.shimCommand(target: target, mode: mode)
        // Resolve the new leaf by DIFFING the live leaf set across the placement op: the public split / new-tab /
        // new-window store ops don't return the new id, and the tree's active-pane truth is module-internal.
        let before = Self.leafIDs(of: store)
        switch placement {
        case .newTab: store.newTab(kind: .terminal)
        // C8 improvement 2 (re-scope): the multi-session UI was pruned (no session switcher), so a
        // `--new-window` that mints a NEW SESSION and swaps the UI to it would strand the user with no way
        // back. Degrade UI-reachable `--new-window` to a NEW TAB in the CURRENT session — no orphan session
        // is ever user-created. Verb name stays `--new-window` for CLI compat
        // (see ``ClientControlProtocol/Placement``); only the placement target changed.
        case .newWindow: store.newTab(kind: .terminal)
        case .left: store.splitActivePane(axis: .horizontal, kind: .terminal, leading: true)
        case .right: store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false)
        case .top: store.splitActivePane(axis: .vertical, kind: .terminal, leading: true)
        case .bottom: store.splitActivePane(axis: .vertical, kind: .terminal, leading: false)
        }
        guard let newPane = Self.leafIDs(of: store).subtracting(before).first else { return false }
        // `cwd: nil` — the placement op already put the inherited cwd on the pane spec for host-side spawn;
        // this injects only the shim command, the SAME way a launch-preset / template command is delivered.
        guard let bytes = SessionTemplateEngine.launchBytes(cwd: nil, command: command) else { return false }
        Task { @MainActor [weak store, grace = shimLaunchGrace] in
            try? await Task.sleep(for: grace)
            store?.handle(for: newPane)?.sendBytes(bytes)
        }
        return true
    }

    /// The shim shell command typed into the new pane: `view` → `open '<url>'` for a URL else `less -- '<path>'`;
    /// `edit` → `${EDITOR:-vi} -- '<path>'`. `target` is VERBATIM from the user's path / URL but SHELL-QUOTED
    /// (the shared `'…'`-with-`'\''` idiom) so a path with a space / metacharacter (`My Project`, `a'b`) stays
    /// one argument instead of word-splitting. `--` terminates option parsing for the path forms; `open` does
    /// not take `--` reliably for a URL, so it is quoted without it.
    private static func shimCommand(target: String, mode: ClientControlOpenMode) -> String {
        let quoted = ShellQuoting.singleQuote(target)
        switch mode {
        case .view: return looksLikeURL(target) ? "open " + quoted : "less -- " + quoted
        case .edit: return "${EDITOR:-vi} -- " + quoted
        }
    }

    /// Every live leaf id across the tree — the before/after set the shim diffs to find the pane the placement
    /// op just created.
    private static func leafIDs(of store: WorkspaceStore) -> Set<PaneID> {
        var ids: Set<PaneID> = []
        for session in store.tree.sessions {
            for tab in session.tabs {
                for id in tab.allPaneIDs() { ids.insert(id) }
            }
        }
        return ids
    }

    // MARK: - config

    /// The config key whose value is the active theme NAME — `reference__cli.md` line 34 documents
    /// `config set theme <name>` as THE CLI theme switch. Resolved here (not in ``PreferencesStore``)
    /// because it needs the GUI ``ThemeStore`` / ``ThemeCatalog`` the headless store cannot import.
    private static let themeConfigKey = "theme"

    /// Resolve a config key's value for the running app, reflecting the LIVE settings (not a catalog default
    /// or dead namespace): `theme` → the active ``ThemeStore`` theme id; render keys → the live
    /// ``PreferencesStore`` typed model. A key not bound live falls back to its catalog default, or `nil`
    /// when the catalog has no entry either.
    func configGet(key: String) -> String? {
        if key == Self.themeConfigKey { return liveThemeName() }
        if let value = preferences?.renderConfigValue(forKey: key) { return value }
        return AllSettingsCatalog.entries.first { $0.key == key }?.defaultText
    }

    /// Write one config key to the LIVE running app: `theme` retints via ``PreferencesStore/appearance``;
    /// render keys reflow/retint via the live typed model (which also persists). A key with NO live binding —
    /// or a value that fails to parse — returns `false` → dispatcher's honest `config set rejected` (NEVER a
    /// silent success, the `setTabBadge` lesson).
    ///
    /// `transient` (apply-without-persisting) is HONESTLY REJECTED (returns `false`): slopdesk's live render
    /// settings ARE their own persistence — the typed ``PreferencesStore`` model the renderer reads is the
    /// SAME model whose `didSet` persists; there is no separate ephemeral render layer. The pre-fix backend
    /// ignored the flag and persisted identically while the dispatcher echoed `transient:true`, lying to the
    /// caller — so we reject rather than silently persist. Recorded as a ceiling in `docs/DECISIONS.md`. A
    /// genuine overlay would need splitting render-source-of-truth from persistence in the libghostty config
    /// builder + typed model — out of scope for the CLI. (The old ``EnvConfig/overlay`` route is gone: a
    /// `nonisolated(unsafe)` static the pipeline read AND ``PreferencesStore`` wholesale-replaced on any
    /// video/agent change, so the write both raced and was silently clobbered.)
    func configSet(key: String, value: String, transient: Bool) -> Bool {
        guard !transient else { return false }
        guard let preferences else { return false }
        if key == Self.themeConfigKey { return applyThemeByName(value, on: preferences) }
        return preferences.setRenderConfig(value, forKey: key)
    }

    /// Remove one config key — reset it to its model default. `theme` clears the primary slot back to the
    /// compile-time default; the render keys reset via ``PreferencesStore/unsetRenderConfig(forKey:)``. A
    /// key with no live binding → `false` (honest error). `transient` is rejected for the same reason as
    /// ``configSet(key:value:transient:)`` — there is no non-persisting render layer to unset.
    func configUnset(key: String, transient: Bool) -> Bool {
        guard !transient else { return false }
        guard let preferences else { return false }
        if key == Self.themeConfigKey {
            var appearance = preferences.appearance
            appearance.theme = nil
            preferences.appearance = appearance
            return true
        }
        return preferences.unsetRenderConfig(forKey: key)
    }

    /// Re-apply the live settings to the running app (theme retint + terminal reflow + keybinding
    /// overrides) AND post the config-change notification — a CONCRETE reload, not a dead broadcast. The
    /// `--reload`/`reload` CLI op therefore re-applies the current config to the GUI.
    func configReload() -> Bool {
        preferences?.reapplyLiveSettings()
        NotificationCenter.default.post(name: Self.configReloadNotification, object: nil)
        return true
    }

    /// The full known-settings catalog, in display order, each paired with its EFFECTIVE value — the LIVE
    /// render/appearance value where slopdesk binds it (`theme`, font, cursor, scrollback, density), else
    /// the catalog default.
    func configShow() -> [ClientConfigEntry] {
        AllSettingsCatalog.entries.map { entry in
            ClientConfigEntry(key: entry.key, value: configGet(key: entry.key) ?? entry.defaultText)
        }
    }

    /// The LIVE active theme's name — the resolved ``ThemeStore`` theme id, which already collapses the
    /// default and the dual-slot / follow-OS selection to a concrete id matching the `theme list` `name`
    /// column (so `config get theme` round-trips a `theme list` entry).
    private func liveThemeName() -> String {
        ThemeStore.shared.active.id
    }

    /// Switch the active theme by NAME — a built-in theme id (from `theme list`, e.g. `monokai-classic`) or
    /// a ``ThemeChoice`` raw value (e.g. `system`) — routed through ``PreferencesStore/appearance`` so the
    /// chrome retints + the terminal cells repaint LIVE (and the choice persists). Sets the PRIMARY (light /
    /// single) slot, the slot every OS appearance resolves to unless the user separately enabled a dark-slot
    /// override. Returns `false` for an UNKNOWN name (honest error, never a silent no-op).
    private func applyThemeByName(_ name: String, on preferences: PreferencesStore) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let choice = ThemeChoice.allCases.first(where: { $0.builtinID == trimmed })
            ?? ThemeChoice(rawValue: trimmed)
        else { return false }
        var appearance = preferences.appearance
        appearance.theme = choice
        preferences.appearance = appearance
        return true
    }

    // MARK: - theme / font / keybind

    func listThemes(color: ClientControlProtocol.ThemeColorFilter) -> [ClientThemeInfo] {
        let activeID = ThemeStore.shared.active.id
        var out: [ClientThemeInfo] = []
        for theme in ThemeCatalog.builtinThemes {
            let isDark = !theme.isLight
            switch color {
            case .dark where !isDark: continue
            case .light where isDark: continue
            default: break
            }
            out.append(ClientThemeInfo(name: theme.id, isDark: isDark, isActive: theme.id == activeID))
        }
        return out
    }

    /// Enumerate font families (macOS via `NSFontManager`; iOS returns empty — no `font list` surface there).
    /// `monospaceOnly` filters by fixed-pitch; `family` is a case-insensitive substring filter. `scope` honors
    /// the system/user split (`reference__cli.md`): each family is classified by the on-disk URL of its
    /// representative font face — a face under `~/Library/Fonts` is a USER font, everything else (the
    /// `/Library/Fonts` + `/System/Library/Fonts` bundles, or an unresolved URL) is a SYSTEM font — and the
    /// `SCOPE` column + the `--system`/`--user` filter reflect that classification.
    func listFonts(
        monospaceOnly: Bool,
        family: String?,
        scope: ClientControlProtocol.FontScope?,
    ) -> [ClientFontInfo] {
        #if canImport(AppKit)
        let needle = family?.lowercased()
        let userFontsDir = Self.userFontsDirectory
        var out: [ClientFontInfo] = []
        for familyName in NSFontManager.shared.availableFontFamilies.sorted() {
            if let needle, !familyName.lowercased().contains(needle) { continue }
            let isMonospace = NSFont(name: familyName, size: 12)?.isFixedPitch ?? false
            if monospaceOnly, !isMonospace { continue }
            let isSystem = !Self.isUserFont(
                url: Self.fontFileURL(forFamily: familyName),
                userFontsDirectory: userFontsDir,
            )
            switch scope {
            case .system where !isSystem: continue
            case .user where isSystem: continue
            default: break
            }
            out.append(ClientFontInfo(family: familyName, isMonospace: isMonospace, isSystem: isSystem))
        }
        return out
        #else
        return []
        #endif
    }

    #if canImport(AppKit)
    /// The user-domain Fonts directory (`~/Library/Fonts`) — the one pole of the system/user font split.
    private static var userFontsDirectory: String {
        NSHomeDirectory() + "/Library/Fonts"
    }

    /// The on-disk URL of a family's representative font face, via Core Text's `kCTFontURLAttribute` on the
    /// resolved descriptor. `nil` when the family does not resolve to a face (degrades to SYSTEM — the safe
    /// default, since a face we cannot place is not a user install).
    private static func fontFileURL(forFamily family: String) -> URL? {
        guard let font = NSFont(name: family, size: 12) else { return nil }
        let descriptor = font.fontDescriptor as CTFontDescriptor
        return CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
    }

    /// Whether a font file `url` lives under the user-domain Fonts directory — the PURE classifier the scope
    /// filter + `SCOPE` column turn on. An unresolved (`nil`) URL is NOT a user font (→ system). Standardized
    /// so a `/private`/symlink-laden path compares against the standardized user dir.
    static func isUserFont(url: URL?, userFontsDirectory: String) -> Bool {
        guard let url else { return false }
        let path = url.standardizedFileURL.path
        // swiftlint:disable:next legacy_objc_type
        let dir = (userFontsDirectory as NSString).standardizingPath
        return path == dir || path.hasPrefix(dir + "/")
    }
    #endif

    func listKeybinds(actionFilter: String?) -> [ClientKeybindInfo] {
        let needle = actionFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [ClientKeybindInfo] = []
        for binding in WorkspaceBindingRegistry.allBindings {
            if let needle, !needle.isEmpty,
               !binding.id.lowercased().contains(needle),
               !binding.title.lowercased().contains(needle) { continue }
            let keys = WorkspaceBindingRegistry.glyph(for: binding.action) ?? ""
            out.append(ClientKeybindInfo(action: binding.id, keys: keys))
        }
        return out
    }

    // MARK: - pane capture / send-keys

    /// The last `lines` of a pane's scrollback (nil `paneId` = the focused pane), read through the live
    /// handle's ``PaneSessionHandle/captureScrollback(lines:)`` seam (terminal truth via the
    /// `TerminalSurfaceActions` mirror; `[]` for a non-terminal pane). `nil` — "pane not found" — when no
    /// live handle backs the id. `lines` is already bounded by the dispatcher.
    func capturePane(paneId: String?, lines: Int) -> [String]? {
        guard let handle = resolveHandle(paneId) else { return nil }
        return handle.captureScrollback(lines: lines)
    }

    /// Send literal `text` VERBATIM, then each named key via the explicit keycode table. nil `paneId` = the
    /// focused pane; an unknown pane → `false`.
    func sendKeys(paneId: String?, text: String, keys: [String]) -> Bool {
        guard let handle = resolveHandle(paneId) else { return false }
        if !text.isEmpty { handle.sendText(text) } // VERBATIM UTF-8
        for key in keys {
            if let bytes = Self.namedKeyBytes(key) { handle.sendBytes(bytes) }
        }
        return true
    }

    // MARK: - agent status

    func agentStatus(id: String) -> AgentStatusResolution {
        // Pane EXISTENCE (`resolvePaneID`) is decoupled from agent-status presence: a pane that exists but
        // has not yet reported a non-`.none` status has NO `paneAgentStatus` entry (the agent-startup
        // window) → `resolvedNoStatus` so `watch:claude` keeps polling instead of exiting 4.
        guard let store, let paneID = resolvePaneID(id) else { return .unresolved }
        guard let status = store.paneAgentStatus[paneID] else { return .resolvedNoStatus }
        return .status(status)
    }

    // MARK: - Helpers

    /// The displayed tab title: the explicit `Tab.title`, else the active pane's last-known / spec title.
    private func tabTitle(session: Session, tab: Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        guard let active = tab.activePane ?? tab.allPaneIDs().first,
              let spec = session.specs[active] else { return "" }
        return spec.lastKnownTitle ?? spec.title
    }

    /// The tab's single fused badge TOKEN: a MANUAL `tab badge --kind` override (E20 ES-E20-3) if one is set,
    /// else the badge resolved for its representative (active) pane via the SAME ``TabBadgeGating/resolve(...)``
    /// path the sidebar rail uses (E6), or `nil` when all-clear.
    private func tabBadgeToken(session _: Session, tab: Tab) -> String? {
        guard let store else { return nil }
        // E20 ES-E20-3: an explicit manual override wins over the derived per-pane badge (and the gates).
        if let override = store.tabBadgeOverride(for: tab.id) {
            return ClientControlProtocol.badgeToken(for: override)
        }
        guard let paneID = tab.activePane ?? tab.allPaneIDs().first else { return nil }
        let status = store.paneAgentStatus[paneID] ?? .none
        let gated = TabBadgeGating.resolve(
            agent: status,
            completion: store.panePendingCompletion[paneID],
            // Reveal-thresholded, matching the rail's `chrome(...)` input (`tab list` must report the
            // same badge the sidebar renders).
            isBusy: store.paneShowsBusyDot(paneID),
            foregroundProcess: store.paneForegroundProcess[paneID],
            completionFreshness: store.completionFreshness(forPane: paneID),
            progress: store.progress(for: paneID),
            agentGates: store.agentBadgeGates(for: paneID),
            commandGates: store.commandBadgeGates,
        )
        return gated.map { ClientControlProtocol.badgeToken(for: $0) }
    }

    /// The live handle for `paneId` (nil = the focused pane), or `nil` when no such leaf is materialized.
    private func resolveHandle(_ paneId: String?) -> (any PaneSessionHandle)? {
        guard let store else { return nil }
        if let paneId {
            guard let id = resolvePaneID(paneId) else { return nil }
            return store.handle(for: id)
        }
        return focusedHandle()
    }

    /// The id of the focused pane in the LIVE model. The backend operates over the `tree` (every list reads
    /// `store.tree.sessions`), so in `.tree` mode focus truth is the active tab's active pane — NOT the
    /// canvas-only `store.focusedPane`, which in tree mode names a SEPARATE, never-materialized canvas leaf
    /// (so `handle(for:)` returns `nil` and `jump`/`send-keys`/`capture` would silently target nothing, and
    /// `pane list`'s `isFocused` would never match). Falls back to the canvas passthrough for a `.canvas`-model
    /// store (the pre-cutover test seam).
    private func focusedPaneID() -> PaneID? {
        guard let store else { return nil }
        switch store.liveModel {
        case .tree: return store.tree.activeSession?.activeTab?.activePane
        case .canvas: return store.focusedPane
        }
    }

    /// The focused pane's live handle, or `nil`.
    private func focusedHandle() -> (any PaneSessionHandle)? {
        guard let store, let focused = focusedPaneID() else { return nil }
        return store.handle(for: focused)
    }

    /// The focused pane's cached OSC-7 working directory (``PaneSpec/lastKnownCwd``), or `nil` when there is
    /// no focused pane / its cwd was never seen. This is the client cwd cache `jump` (no query) and `learn`
    /// (no path) default to (the cwd lives on the host; the client only knows it via OSC 7).
    private func focusedCwd() -> String? {
        guard let store, let focused = focusedPaneID() else { return nil }
        for session in store.tree.sessions {
            if let spec = session.specs[focused] { return Self.nonEmpty(spec.lastKnownCwd) }
        }
        return nil
    }

    /// Resolve a tab-id string (`nil` = the focused tab) into a known ``TabID`` in the live tree, else `nil`
    /// (validate-then-drop — the dispatcher turns `nil` into `tab not found`). A given id is matched by its
    /// `uuidString` across every session's tabs; `nil` resolves to the active session's active tab.
    private func resolveTabID(_ tabId: String?) -> TabID? {
        guard let store else { return nil }
        guard let tabId else { return store.tree.activeSession?.activeTab?.id }
        for session in store.tree.sessions {
            if let tab = session.tabs.first(where: { $0.id.raw.uuidString == tabId }) { return tab.id }
        }
        return nil
    }

    /// Parse a pane-id string into a known ``PaneID``: a valid UUID that names a leaf in the live tree, else
    /// `nil` (validate-then-drop — the dispatcher turns `nil` into the right error / never-seen response).
    private func resolvePaneID(_ string: String?) -> PaneID? {
        guard let store else { return nil }
        guard let string, let uuid = UUID(uuidString: string) else { return nil }
        let id = PaneID(raw: uuid)
        return store.tree.contains(id) ? id : nil
    }

    /// `s` trimmed; `nil` when empty/whitespace-only (so a blank cwd encodes as absent, not `""`).
    private static func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func looksLikeURL(_ s: String) -> Bool {
        s.hasPrefix("http://") || s.hasPrefix("https://")
    }

    /// The byte sequence for a named key (the keycode path — NEVER `SendKeysParser`, per CLAUDE.md). A small
    /// explicit table covering the common control keys; an unknown name is dropped. The full named-key set is
    /// a WI-4 refinement.
    private static func namedKeyBytes(_ name: String) -> [UInt8]? {
        switch name.lowercased() {
        case "enter",
             "return": [0x0D]
        case "tab": [0x09]
        case "escape",
             "esc": [0x1B]
        case "space": [0x20]
        case "backspace": [0x7F]
        case "up": [0x1B, 0x5B, 0x41] // CSI A
        case "down": [0x1B, 0x5B, 0x42] // CSI B
        case "right": [0x1B, 0x5B, 0x43] // CSI C
        case "left": [0x1B, 0x5B, 0x44] // CSI D
        default: nil
        }
    }
}
#endif
