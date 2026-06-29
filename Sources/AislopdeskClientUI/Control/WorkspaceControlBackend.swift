// E20 WI-3 — Client control backend over the live client stores.
//
// The concrete ``ClientControlBackend`` the ``ClientControlServer`` (this same WI) drives: it adapts the
// running client GUI's `@MainActor` stores — ``WorkspaceStore`` (the `Session → Tab → Pane` tree),
// ``PreferencesStore`` (live render/appearance config), ``ThemeStore`` / ``ThemeCatalog`` (themes),
// ``WorkspaceBindingRegistry`` (keybinds), and ``FolderFrecencyStore`` (jump) — onto the verb seam the
// PURE ``ClientControlDispatcher`` (WI-2) calls.
//
// ## Compiled-only (hang-safety)
// Like the host's `AgentControlListener`, this adapter touches live GUI stores and is **never instantiated
// in a unit test** — the dispatcher is tested against a FAKE backend (WI-2 `ClientControlDispatcherTests`).
// It holds the stores WEAKLY (the app owns them); a store that has gone away degrades to an empty/`nil`/
// `false` result, never a trap.
//
// ## Validate-then-drop
// The dispatcher has already validated + bounded every param before calling here (CLAUDE.md untrusted-input
// contract), so each method assumes well-formed inputs and only has to map identity strings → tree nodes
// (a bad/unknown id resolves to `nil` → the dispatcher emits an `ok:false` error, never a crash). Literal
// `cd` / send-keys / shim text is sent **VERBATIM UTF-8**; named keys go through a small explicit keycode
// table (never `SendKeysParser`), per CLAUDE.md.
//
// ## Refinement boundary (later work items)
// This adapter wires every method against an existing seam so the socket is functional end-to-end at WI-3.
// A few methods carry a documented best-effort whose DEPTH lands with the WI that owns the matching CLI
// surface: the scrollback `pane capture` read (WI-4). Each is marked inline. `config get/set/unset/show/
// reload` now drive the LIVE settings — `theme` retints via ``ThemeStore``, the render keys reflow/retint
// via ``PreferencesStore``, unknown keys honestly error (no dead namespace / no `EnvConfig.overlay`
// write). The `tab badge --kind` override now writes the store-side per-tab override
// the rail + `tab list` render (E20 ES-E20-3, no longer deferred). The `view`/`edit` shim landed its
// new-pane placement in WI-6 (below). None of these are on the golden wire; this is the NDJSON control plane only.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskCLICore // JumpResolver — the PURE frecency/$HOME-toggle/`--no-cd` jump resolution (WI-5)
import AislopdeskVideoProtocol // ThemeChoice — the typed theme selection the `config set theme` write maps onto
import AislopdeskWorkspaceCore
import Foundation
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

    /// The directory a prior no-query `jump` left — the mutable pole of otty's `$HOME`↔last-jump-source
    /// toggle (`reference__cli.md`). Held on this long-lived backend (owned by the running app) so the
    /// toggle persists across the separate, short-lived `aislopdesk jump` CLI processes that drive it.
    /// `nil` until the first committed jump away from `$HOME`.
    private var lastJumpSource: String?

    /// Posted by ``configReload()`` (in ADDITION to its concrete re-apply of the live settings) so any
    /// additional config-change observer can refresh — a broadcast hook alongside the direct re-apply.
    static let configReloadNotification = Notification.Name("AislopdeskClientControlConfigReload")

    /// How long the `view`/`edit` shim defers its command injection past the new pane's inherited-cwd `cd`
    /// (so a RELATIVE path resolves in the inherited directory first). Defaults to the production 1500 ms;
    /// injectable so a unit test can observe the deferred launch bytes without a 1.5 s wall.
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

    /// Set the MANUAL status badge on a tab (the focused tab when `tabId` is nil) — otty `tab badge --kind`.
    /// Resolves the target ``TabID`` (an unknown / absent tab → `false`, which the dispatcher turns into
    /// `tab not found`) and writes the per-tab override the rail + `tab list` consult AHEAD of the derived
    /// badge (``WorkspaceStore/setTabBadgeOverride(_:for:)``). This is the real ES-E20-3 write path — the
    /// command no longer reports success while doing nothing.
    func setTabBadge(tabId: String?, kind: TabBadgeKind) -> Bool {
        guard let store, let target = resolveTabID(tabId) else { return false }
        store.setTabBadgeOverride(kind, for: target)
        return true
    }

    // MARK: - Jump / learn / ignore (frecency)

    /// Resolve a frecency target via the PURE ``JumpResolver`` (frecency rank + `$HOME`↔last-jump toggle +
    /// `--no-cd`) and, unless `--no-cd`, `cd` the focused pane VERBATIM. The resolver is fed the live
    /// frecency entries, the focused pane's cached OSC-7 cwd, the resolved `$HOME`, and the persisted
    /// ``lastJumpSource``; its committed source is stored back (a no-op on a `--no-cd` preview).
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
            // The PATH is sent VERBATIM (CLAUDE.md: jump literal text is never routed through `SendKeysParser`)
            // but SHELL-QUOTED — an unquoted `cd /Users/x/My Project` would `cd` to `/Users/x/My`. Reuses the
            // shared `'…'`-with-`'\''` idiom (zoxide/otty quote the target the same way); only shell-safe
            // quoting is added, the bytes are still derived verbatim from the user's path. Enter == CR.
            handle.sendText("cd -- " + ShellQuoting.singleQuote(resolution.path))
            handle.sendBytes([0x0D])
            didChange = true
        }
        return ClientJumpOutcome(path: resolution.path, didChangeDirectory: didChange)
    }

    /// Record a directory visit in the frecency DB. A nil/blank `path` records the focused pane's cached
    /// OSC-7 cwd (otty `learn` with no args). Returns the recorded path, or `nil` when neither a path nor a
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

    /// Remove `path` from the frecency DB (otty `ignore`). `forget` is idempotent — a path with no entry is
    /// a silent no-op — so this only reports `false` when the store has gone away.
    func ignore(path: String) -> Bool {
        guard let folders else { return false }
        folders.forget(path: path)
        return true
    }

    // MARK: - view / edit shim (WI-6)

    /// Open the read-only `view` / editor `edit` shim in a NEW pane (otty `--new-tab` default / `--new-window` /
    /// split side) — NOT a native local file renderer (an aislopdesk pane IS a remote PTY; there is no local
    /// renderer — the documented E20 shim, carry-over §4). The shim TYPES a shell command into the freshly-spawned
    /// pane: `view` → `open <url>` for a URL else `less <path>`; `edit` → `${EDITOR:-vi} <path>`. The command is
    /// injected through the SAME new-pane launch seam template panes use
    /// (``SessionTemplateEngine/launchBytes(cwd:command:)``), deferred past the new pane's inherited-cwd `cd` so a
    /// RELATIVE path resolves in the inherited directory first. Returns `false` only when the placement op spawned
    /// no pane (e.g. no active session to split / new-tab into).
    func open(target: String, mode: ClientControlOpenMode, placement: ClientControlProtocol.Placement) -> Bool {
        guard let store else { return false }
        let command = Self.shimCommand(target: target, mode: mode)
        // Resolve the new leaf by DIFFING the live leaf set across the placement op: the public split / new-tab /
        // new-window store ops don't return the new id, and the tree's active-pane truth is module-internal.
        let before = Self.leafIDs(of: store)
        switch placement {
        case .newTab: store.newTab(kind: .terminal)
        case .newWindow: store.newSession(name: Self.shimSessionName(target: target), kind: .terminal)
        case .left: store.splitActivePane(axis: .horizontal, kind: .terminal, leading: true)
        case .right: store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false)
        case .top: store.splitActivePane(axis: .vertical, kind: .terminal, leading: true)
        case .bottom: store.splitActivePane(axis: .vertical, kind: .terminal, leading: false)
        }
        guard let newPane = Self.leafIDs(of: store).subtracting(before).first else { return false }
        // `cwd: nil` — the placement op already scheduled the inherited-cwd `cd`; this injects only the shim
        // command, the SAME way a launch-preset / template command is delivered into a fresh pane.
        guard let bytes = SessionTemplateEngine.launchBytes(cwd: nil, command: command) else { return false }
        Task { @MainActor [weak store, grace = shimLaunchGrace] in
            try? await Task.sleep(for: grace)
            store?.handle(for: newPane)?.sendBytes(bytes)
        }
        return true
    }

    /// The shim shell command typed into the new pane: `view` → `open '<url>'` for a URL else `less -- '<path>'`;
    /// `edit` → `${EDITOR:-vi} -- '<path>'`. The `target` is derived VERBATIM from the file path / URL the user
    /// passed but SHELL-QUOTED (the shared `'…'`-with-`'\''` idiom) so a path with a space / metacharacter
    /// (`My Project`, `a'b`) survives as a single argument instead of being word-split. `--` terminates option
    /// parsing for the path forms; `open` does not take `--` reliably for a URL, so it is quoted without it.
    private static func shimCommand(target: String, mode: ClientControlOpenMode) -> String {
        let quoted = ShellQuoting.singleQuote(target)
        switch mode {
        case .view: return looksLikeURL(target) ? "open " + quoted : "less -- " + quoted
        case .edit: return "${EDITOR:-vi} -- " + quoted
        }
    }

    /// The session name for a `--new-window` shim — the target's last path component (a stable human label),
    /// falling back to a generic name for an empty / odd target.
    private static func shimSessionName(target: String) -> String {
        let last = URL(fileURLWithPath: target).lastPathComponent
        return last.isEmpty ? "View" : last
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

    // MARK: - open-recipe

    /// Open a `.ottyrecipe` by path or a saved-library recipe by name. A path that does not exist / a name
    /// with no library match → `false` (validate-then-drop; the store's parse is itself drop-on-malformed).
    func openRecipe(reference: String) -> Bool {
        guard let store else { return false }
        let url: URL
        // A by-NAME resolution is a saved-library recipe (its Command-Replay default follows
        // `replayModeSaved`); a path/`.ottyrecipe` reference is an external file (`replayModeFiles`).
        let source: RecipeSource
        if reference.hasSuffix("." + RecipeLibrary.fileExtension) || reference.contains("/") {
            // swiftlint:disable:next legacy_objc_type
            let expanded = (reference as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            source = .file
        } else {
            let files = store.savedRecipeFiles()
            guard let match = files.first(where: { $0.recipe?.name == reference }) else { return false }
            url = match.url
            source = .savedLibrary
        }
        store.openRecipe(at: url, source: source)
        return true
    }

    // MARK: - config

    /// The otty config key whose value is the active theme NAME — `reference__cli.md` line 34 documents
    /// `config set theme <name>` as THE CLI theme switch. Resolved here (not in ``PreferencesStore``)
    /// because it needs the GUI ``ThemeStore`` / ``ThemeCatalog`` the headless store cannot import.
    private static let themeConfigKey = "theme"

    /// Resolve a config key's value for the running app, reflecting the LIVE settings (not a catalog
    /// default and not a dead namespace): `theme` → the active ``ThemeStore`` theme id; the render keys →
    /// the live ``PreferencesStore`` typed model. A key aislopdesk does NOT bind live falls back to its
    /// catalog default (best-effort, honest), or `nil` when the catalog has no entry either.
    func configGet(key: String) -> String? {
        if key == Self.themeConfigKey { return liveThemeName() }
        if let value = preferences?.renderConfigValue(forKey: key) { return value }
        return AllSettingsCatalog.entries.first { $0.key == key }?.defaultText
    }

    /// Write one config key to the LIVE running app: `theme` retints via ``PreferencesStore/appearance``;
    /// the render keys reflow/retint via the live typed model (which also persists). A key with NO live
    /// binding — or a value that fails to parse — returns `false`, which the dispatcher turns into an
    /// honest `config set rejected` error (NEVER a silent success, the `setTabBadge` lesson).
    ///
    /// `transient` is accepted for CLI parity but does not branch the render keys: aislopdesk's live render
    /// settings ARE their own persistence (there is no separate ephemeral render layer the renderer reads,
    /// unlike otty's config-file ⇄ running-app split), so a `--transient` set applies live exactly like a
    /// persisted one. The old code routed BOTH through ``EnvConfig/overlay`` — a `nonisolated(unsafe)`
    /// static the realtime pipeline reads AND that ``PreferencesStore`` wholesale-replaces on any video/
    /// agent change, so the write both raced and was silently clobbered; it is gone.
    func configSet(key: String, value: String, transient _: Bool) -> Bool {
        guard let preferences else { return false }
        if key == Self.themeConfigKey { return applyThemeByName(value, on: preferences) }
        return preferences.setRenderConfig(value, forKey: key)
    }

    /// Remove one config key — reset it to its model default. `theme` clears the primary slot back to the
    /// compile-time default; the render keys reset via ``PreferencesStore/unsetRenderConfig(forKey:)``. A
    /// key with no live binding → `false` (honest error).
    func configUnset(key: String, transient _: Bool) -> Bool {
        guard let preferences else { return false }
        if key == Self.themeConfigKey {
            var appearance = preferences.appearance
            appearance.theme = nil
            appearance.customLightSlug = nil
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
    /// render/appearance value where aislopdesk binds it (`theme`, font, cursor, scrollback, density), else
    /// the catalog default.
    func configShow() -> [ClientConfigEntry] {
        AllSettingsCatalog.entries.map { entry in
            ClientConfigEntry(key: entry.key, value: configGet(key: entry.key) ?? entry.defaultText)
        }
    }

    /// The LIVE active theme's name — the resolved ``ThemeStore`` theme id, which already collapses the
    /// default, the dual-slot / follow-OS selection, and custom themes to a concrete id matching the
    /// `theme list` `name` column (so `config get theme` round-trips a `theme list` entry).
    private func liveThemeName() -> String {
        ThemeStore.shared.active.id
    }

    /// Switch the active theme by NAME — a built-in theme id (from `theme list`, e.g. `monokai-classic`),
    /// a ``ThemeChoice`` raw value (e.g. `system`), or a scanned custom-theme slug — routed through
    /// ``PreferencesStore/appearance`` so the chrome retints + the terminal cells repaint LIVE (and the
    /// choice persists). Sets the PRIMARY (light / single) slot, the slot every OS appearance resolves to
    /// unless the user separately enabled a dark-slot override. Returns `false` for an UNKNOWN name (honest
    /// error, never a silent no-op).
    private func applyThemeByName(_ name: String, on preferences: PreferencesStore) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var appearance = preferences.appearance
        if let choice = ThemeChoice.allCases.first(where: { $0.builtinID == trimmed })
            ?? ThemeChoice(rawValue: trimmed)
        {
            appearance.theme = choice
            appearance.customLightSlug = nil // a built-in choice clears any prior custom-slug override
            preferences.appearance = appearance
            return true
        }
        // Not a built-in → a scanned custom theme slug (validate against the catalog; unknown → reject).
        guard ThemeCatalog.shared.customDocument(slug: trimmed) != nil else { return false }
        appearance.customLightSlug = trimmed
        preferences.appearance = appearance
        return true
    }

    // MARK: - theme / font / keybind

    func listThemes(color: ClientControlProtocol.ThemeColorFilter) -> [ClientThemeInfo] {
        let activeID = ThemeStore.shared.active.id
        var all = ThemeCatalog.builtinThemes
        all.append(contentsOf: ThemeCatalog.shared.customThemes.map { OttyTheme(document: $0) })
        var out: [ClientThemeInfo] = []
        for theme in all {
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

    /// Import a theme file via the E15 importers (`ThemeLibrary.importFile` — auto-detects Otty `.ottytheme`
    /// / iTerm2 / kitty / alacritty / ghostty), re-scan the custom catalog, and optionally activate it. A
    /// missing / unreadable / unparseable file → `nil` (validate-then-drop). `overwrite` is accepted for CLI
    /// parity; the importer already resolves slug collisions by suffixing (`-1`, `-2`), so a forced replace
    /// of an existing same-slug theme is a documented refinement.
    func themeImport(path: String, activate: Bool, overwrite _: Bool) -> String? {
        // The E15 importer + the custom-theme directory are macOS-only (`ThemeLibrary.importFile` /
        // `~/.config/aislopdesk/themes/`, both `#if os(macOS)`); iOS has no custom-theme filesystem analog, so
        // `theme import` is unavailable there (validate-then-drop → nil), matching the macOS-only import UI.
        #if os(macOS)
        // swiftlint:disable:next legacy_objc_type
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let builtinSlugs = Set(ThemeCatalog.builtinThemes.map(\.id))
        guard let result = try? ThemeLibrary.importFile(at: url, builtinSlugs: builtinSlugs) else { return nil }
        ThemeCatalog.shared.reloadCustom()
        if activate { activateCustomTheme(slug: result.slug) }
        return result.slug
        #else
        nil
        #endif
    }

    /// Activate an imported custom theme in the slot the current OS appearance resolves to (mirrors
    /// `ThemeEditorView.activate` — the dark slot only when "separate dark theme" is on AND the OS is dark).
    private func activateCustomTheme(slug: String) {
        guard let preferences else { return }
        var appearance = preferences.appearance
        if appearance.useSeparateDarkTheme ?? false, ThemeStore.shared.osIsDark() {
            appearance.customDarkSlug = slug
        } else {
            appearance.customLightSlug = slug
        }
        preferences.appearance = appearance
    }

    /// Enumerate font families (macOS via `NSFontManager`; iOS returns empty — no `font list` surface there).
    /// `monospaceOnly` filters by fixed-pitch; `family` is a case-insensitive substring filter. `scope` honors
    /// the otty system/user split (`reference__cli.md`): each family is classified by the on-disk URL of its
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
    /// else the badge resolved for its representative (active) pane via the SAME pure ``TabBadgeResolver`` +
    /// ``AgentBadgeGates`` path the sidebar rail uses (E6), or `nil` when all-clear.
    private func tabBadgeToken(session _: Session, tab: Tab) -> String? {
        guard let store else { return nil }
        // E20 ES-E20-3: an explicit manual override wins over the derived per-pane badge (and the gates).
        if let override = store.tabBadgeOverride(for: tab.id) {
            return ClientControlProtocol.badgeToken(for: override)
        }
        guard let paneID = tab.activePane ?? tab.allPaneIDs().first else { return nil }
        let status = store.paneAgentStatus[paneID] ?? .none
        let resolved = TabBadgeResolver.badge(
            agent: status,
            completion: store.panePendingCompletion[paneID],
            isBusy: store.paneIsBusy(paneID),
            foregroundProcess: store.paneForegroundProcess[paneID],
            completionFreshness: store.completionFreshness(forPane: paneID),
            progress: store.progress(for: paneID),
        )
        let gated = AgentBadgeGates.gated(resolved, by: store.agentBadgeGates(for: paneID))
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
    /// `store.tree.sessions`), so in `.tree` mode the focus truth is the active tab's active pane — NOT the
    /// canvas-only `store.focusedPane`, which in tree mode names a SEPARATE, never-materialized canvas leaf
    /// (so `handle(for:)` would return `nil` and `jump`/`send-keys`/`capture` would silently target nothing,
    /// and `pane list`'s `isFocused` would never match). Falls back to the canvas passthrough for a
    /// `.canvas`-model store (the pre-cutover test seam).
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
