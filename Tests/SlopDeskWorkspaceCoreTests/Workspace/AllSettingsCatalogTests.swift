import Defaults
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// E7 WI-3: pins the headless ``AllSettingsCatalog`` (filter + full client-key coverage + buckets) and the
/// ``PreferencesStore`` reset behaviour the Advanced "All Settings" panel drives. All headless — no view.
@MainActor
final class AllSettingsCatalogTests: XCTestCase {
    // The global `Defaults.Keys` the reset tests flip live in `SettingsKey.store`; clean them up so the
    // dev machine's real defaults are not polluted (the catalog/filter tests touch no defaults at all). The
    // reset-completeness tests flip keys across the whole settings catalog, so the cleanup resets BOTH
    // PreferencesStore reset sets (every tab-reachable + advanced-only key) plus the density string key.
    private nonisolated static func cleanDefaults() {
        SettingsKey.store.removeObject(forKey: SettingsKey.density)
        Defaults.reset(PreferencesStore.tabReachableDefaultsKeys)
        Defaults.reset(PreferencesStore.advancedOnlyDefaultsKeys)
    }

    override nonisolated func setUp() { Self.cleanDefaults() }
    override nonisolated func tearDown() { Self.cleanDefaults() }

    // MARK: - Filter

    /// The search filter matches case-insensitively against key / label / description / keywords. The spec's
    /// own examples (`cursor`, `scrollback`, `blink`) narrow to the expected rows; an empty query returns
    /// ALL entries; a no-match query returns `[]`.
    func testFilterMatchesKeyLabelDescriptionKeywords() {
        // Empty query → every entry, order-preserving.
        XCTAssertEqual(AllSettingsCatalog.filter("").count, AllSettingsCatalog.entries.count)
        XCTAssertEqual(AllSettingsCatalog.filter("   ").count, AllSettingsCatalog.entries.count)

        // `cursor` → the two cursor render-pref rows PLUS the E8 "Cursor Click-to-Move" control row; all
        // three legitimately contain "cursor" in their key / label / description. The render rows are always
        // present (superset pin), and the faithfully-named Click-to-Move row now also matches.
        let cursorKeys = Set(AllSettingsCatalog.filter("cursor").map(\.key))
        XCTAssertTrue(cursorKeys.isSuperset(of: ["cursor-style", "cursor-style-blink"]))
        XCTAssertTrue(cursorKeys.contains(SettingsKey.clickToMove), "Cursor Click-to-Move matches a 'cursor' search")
        // Case-insensitive — the same matches.
        XCTAssertEqual(AllSettingsCatalog.filter("CURSOR").count, cursorKeys.count)

        // `scrollback` → only the scrollback row (the scroll-multiplier / scroll-on-output rows say "scroll",
        // never "scrollback").
        XCTAssertEqual(AllSettingsCatalog.filter("scrollback").map(\.key), ["scrollback-limit"])

        // `blink` → only the cursor-blink row.
        XCTAssertEqual(AllSettingsCatalog.filter("blink").map(\.key), ["cursor-style-blink"])

        // Matches a keyword that is in neither the key nor the label/description.
        XCTAssertTrue(AllSettingsCatalog.filter("autoscroll").contains { $0.key == SettingsKey.scrollOnOutput })

        // No-match query → empty. (`filter(_:)` here is the catalog's query-search method, not
        // `Sequence.filter(where:)`; bind the result so the lint's `.filter(...).isEmpty` heuristic — a
        // false positive on a domain search returning `[SettingEntry]` — doesn't misfire.)
        let noMatches = AllSettingsCatalog.filter("zzz-no-such-key")
        XCTAssertTrue(noMatches.isEmpty)
    }

    // MARK: - Full coverage (anti-drift)

    /// Every client-side ``SettingsKey`` that the settings taxonomy surfaces MUST appear in the catalog
    /// — the All-Settings list is "complete". Revert-to-fail: dropping a `SettingEntry` makes this fail. The
    /// required list references the `SettingsKey` constants directly (independent of `entries`), so it is a
    /// real anti-drift pin, not a tautology. (Canvas-mode keys — `canvas.*` — are intentionally excluded;
    /// they belong to the legacy canvas surface, not the 8-section settings.)
    func testCatalogCoversEveryClientSettingsKey() {
        let required: [String] = [
            // General (close confirmation is on the General page — launch-option.png)
            SettingsKey.onLaunchKey, SettingsKey.redactSecrets, SettingsKey.defaultPaneKindKey,
            SettingsKey.closeConfirmTabKey, SettingsKey.closeConfirmWindowKey,
            // Shell (notifications — notification-setting.png — + working directory — window-tab-split spec)
            SettingsKey.oscNotifications, SettingsKey.longCommandNotifications,
            SettingsKey.workingDirectoryNewWindowKey, SettingsKey.workingDirectoryNewTabKey,
            SettingsKey.workingDirectoryNewSplitKey,
            // Controls / copy / mouse / scroll
            SettingsKey.copyOnSelect, SettingsKey.trimTrailingSpacesOnCopy, SettingsKey.pasteProtection,
            SettingsKey.mouseHideWhileTyping, SettingsKey.focusFollowsMouse, SettingsKey.scrollOnOutput,
            SettingsKey.scrollMultiplier, SettingsKey.systemDialogPanes,
            // E8 WI-1: the remaining Controls / Mouse / Scroll knobs
            SettingsKey.clearSelectionOnTyping, SettingsKey.clearSelectionOnCopy,
            SettingsKey.backspaceDeletesSelection, SettingsKey.shiftArrowSelect, SettingsKey.pasteBracketedSafe,
            SettingsKey.clipboardReadKey, SettingsKey.clipboardWriteKey, SettingsKey.allowMouseCapture,
            SettingsKey.allowShiftClickKey, SettingsKey.clickToMove, SettingsKey.rightClickActionKey,
            SettingsKey.scrollPastLastLineKey, SettingsKey.scrollPastFirstLineKey, SettingsKey.smoothScroll,
            SettingsKey.undoAtPrompt,
            // E10 (Path/link detection — Open With / Link Schemes)
            SettingsKey.linkDetection, SettingsKey.linkCmdClickKey, SettingsKey.linkCmdShiftClickKey,
            SettingsKey.autoDetectLinkSchemesKey, SettingsKey.customLinkSchemes,
            // E14/K11-K12 (privilege surface — title gates + OSC-52 master switch — Advanced)
            SettingsKey.titleShellControlled, SettingsKey.titleReport, SettingsKey.clipboardShellControlled,
            // E14/K13 (IPC guards on the agent-control ctl socket — Advanced)
            SettingsKey.ipcAllowSendKeys, SettingsKey.ipcAllowSensitiveSessions,
            // Appearance (New Tab Position — tab-setting.png — + chrome orphans + density)
            SettingsKey.newTabPositionKey, SettingsKey.showBlockDividers,
            SettingsKey.density,
            // Agents
            SettingsKey.autoSwitchLayouts, SettingsKey.recordClipboardHistory,
        ]
        let present = Set(AllSettingsCatalog.entries.map(\.key))
        for key in required {
            XCTAssertTrue(present.contains(key), "All Settings catalog is missing client key '\(key)'")
        }
    }

    /// The catalog has no duplicate keys (each is the list's identity).
    func testCatalogKeysAreUnique() {
        let keys = AllSettingsCatalog.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "duplicate keys in the All Settings catalog")
    }

    // MARK: - Buckets

    /// The orphan + new fire-time toggles are `.advancedOnly` (inline-editable in the list); the rich
    /// typed-render fields (font / theme / cursor) are `.hasDedicatedTab` (jump to their tab) and each names
    /// a destination section.
    func testAdvancedOnlyVsDedicatedTabBuckets() {
        func bucket(_ key: String) -> AllSettingsCatalog.SettingEntry.Bucket? {
            AllSettingsCatalog.entries.first { $0.key == key }?.bucket
        }
        for key in [
            SettingsKey.showBlockDividers, SettingsKey.systemDialogPanes,
            SettingsKey.autoSwitchLayouts, SettingsKey.recordClipboardHistory,
            SettingsKey.copyOnSelect, SettingsKey.scrollMultiplier,
        ] {
            XCTAssertEqual(bucket(key), .advancedOnly, "'\(key)' should be advancedOnly (inline)")
        }
        for key in ["font-family", "font-size", "theme", "cursor-style", "cursor-style-blink"] {
            XCTAssertEqual(bucket(key), .hasDedicatedTab, "'\(key)' should be hasDedicatedTab (jump)")
        }
        // Every hasDedicatedTab entry names a target section; every advancedOnly entry does NOT.
        for entry in AllSettingsCatalog.entries {
            switch entry.bucket {
            case .hasDedicatedTab:
                XCTAssertNotNil(entry.targetSection, "'\(entry.key)' (hasDedicatedTab) must name a target section")
            case .advancedOnly:
                XCTAssertNil(entry.targetSection, "'\(entry.key)' (advancedOnly) should not name a target section")
            }
        }
    }

    /// E7 fidelity fix: the ✎ jump destinations match the section taxonomy proven by the screenshots
    /// (`docs/ui-shell/screenshots/font-setting.png` shows FONT FAMILY under Appearance;
    /// `cursor-style.png` shows the CURSOR group under Appearance; `terminal-features__scroll.md` puts
    /// Scrollback under Controls → Scroll). Pins — against an INDEPENDENT expectation table, not the catalog's
    /// own derivation — that font + cursor + theme + density jump to **appearance** and scrollback jumps to
    /// **controls**. Revert-to-fail: the pre-fix catalog routed font/scrollback → `editor` and cursor →
    /// `controls`, which fails this.
    func testDedicatedTabTargetSectionsMatchSlateTaxonomy() {
        let expected: [String: String] = [
            "font-family": "appearance",
            "font-size": "appearance",
            "cursor-style": "appearance",
            "cursor-style-blink": "appearance",
            "scrollback-limit": "controls",
            "theme": "appearance",
            SettingsKey.density: "appearance",
        ]
        for (key, section) in expected {
            let entry = AllSettingsCatalog.entries.first { $0.key == key }
            XCTAssertEqual(entry?.targetSection, section, "'\(key)' must jump to the '\(section)' section")
        }
        // No dedicated-tab field still routes to the now-reserved (empty) Editor section.
        for entry in AllSettingsCatalog.entries where entry.bucket == .hasDedicatedTab {
            XCTAssertNotEqual(
                entry.targetSection,
                "editor",
                "'\(entry.key)' must not jump to the reserved Editor section",
            )
        }
    }

    /// M2: the Dock-icon toggles are surfaced under **Appearance → Dock Icon**, so their searchable All-Settings
    /// rows must JUMP to the Appearance section (`hasDedicatedTab` → `appearance`) rather than rendering a
    /// duplicate inline control. Revert-to-confirm-fail: the un-fixed catalog declared both keys `.advancedOnly`
    /// with a `nil` targetSection (so a search landed on a bare inline toggle, never the Appearance group) —
    /// this asserts they now jump to `appearance`, matching DECISIONS.md's "under Appearance per the spec".
    func testDockIconKeysJumpToAppearanceSection() {
        for key in [SettingsKey.dockIconAnimateProgress, SettingsKey.dockIconErrorBadge] {
            let entry = AllSettingsCatalog.entries.first { $0.key == key }
            XCTAssertEqual(entry?.bucket, .hasDedicatedTab, "'\(key)' must jump to its dedicated tab")
            XCTAssertEqual(entry?.targetSection, "appearance", "'\(key)' must jump to the Appearance section")
        }
    }

    // MARK: - PreferencesStore reset behaviour (the panel's Reset buttons)

    /// An isolated `UserDefaults` suite for the injected store models (the global `Defaults.Keys` are still
    /// `.standard`-backed — those are cleaned up in `tearDown`).
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "AllSettingsCatalogTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// "Reset Advanced Only" clears ONLY the advanced-only keys — the `video` / `agent` host flags + the raw
    /// `SLOPDESK_*` overrides (the keys with no dedicated tab) — and LEAVES every tab-reachable choice
    /// intact: font (`terminal`), theme (`appearance`), keybindings, AND the General/Shell/Controls/
    /// Appearance/Agents `Defaults.Keys` toggles. Per `customization__advanced-settings.md`: "restores only
    /// the advanced-only keys (those not reachable from General, Shell, Appearance, or Key Bindings), leaving
    /// font, theme, and keybinding choices intact."
    ///
    /// Revert-to-fail: before the data-loss fix, `resetAdvancedOnly()` reset the ENTIRE global toggle set, so
    /// `copyOnSelect` / `oscNotifications` / `showBlockDividers` / `autoSwitchLayouts` were wrongly cleared — the
    /// four `…Enabled` "preserved" asserts below fail on the un-fixed code.
    func testResetAdvancedOnlyPreservesAppearanceFontKeybindings() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        store.terminal = TerminalPreferences(fontSize: 18)
        store.appearance = AppearancePreferences(theme: .dark)
        store.keybindings = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "e", command: true)])
        store.video = VideoPreferences(qpSharp: 30)
        store.agent = AgentPreferences(agentDetect: true)
        store.rawOverrides = ["SLOPDESK_X": "9"]
        // Flip a tab-reachable toggle on each non-Advanced section (Controls / General / Appearance / Agents).
        // These are NON-default values that a Reset-Advanced-Only must NOT destroy.
        SettingsKey.store.set(true, forKey: SettingsKey.copyOnSelect) // Controls (default Off)
        SettingsKey.store.set(false, forKey: SettingsKey.oscNotifications) // Shell (default On)
        SettingsKey.store.set(false, forKey: SettingsKey.showBlockDividers) // Appearance (default On)
        SettingsKey.store.set(false, forKey: SettingsKey.autoSwitchLayouts) // Agents (default On)
        XCTAssertTrue(SettingsKey.copyOnSelectEnabled)
        XCTAssertFalse(SettingsKey.oscNotificationsEnabled)
        XCTAssertFalse(SettingsKey.showBlockDividersEnabled)
        XCTAssertFalse(SettingsKey.autoSwitchLayoutsEnabled)

        store.resetAdvancedOnly()

        // Advanced bucket cleared (the only thing Reset-Advanced-Only touches).
        XCTAssertEqual(store.video, VideoPreferences())
        XCTAssertEqual(store.agent, AgentPreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        // Font / theme / keybindings preserved.
        XCTAssertEqual(store.terminal.fontSize, 18)
        XCTAssertEqual(store.appearance.theme, .dark)
        XCTAssertEqual(store.keybindings.overrides["pane.splitRight"]?.key, "e")
        // Tab-reachable toggles PRESERVED — the data-loss fix. None of these is advanced-only.
        XCTAssertTrue(SettingsKey.copyOnSelectEnabled, "Controls toggle survives Reset-Advanced-Only")
        XCTAssertFalse(SettingsKey.oscNotificationsEnabled, "Shell toggle survives Reset-Advanced-Only")
        XCTAssertFalse(SettingsKey.showBlockDividersEnabled, "Appearance toggle survives Reset-Advanced-Only")
        XCTAssertFalse(SettingsKey.autoSwitchLayoutsEnabled, "Agents toggle survives Reset-Advanced-Only")
    }

    /// "Reset All Settings" returns EVERYTHING to defaults — the typed models AND a flipped global orphan
    /// toggle (`showBlockDividers`, default ON). Revert-to-fail: before WI-1 extended `resetAll()`, the
    /// `Defaults.Keys` toggle survived a reset.
    func testResetAllRestoresOrphanToggleToDefault() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        store.terminal = TerminalPreferences(fontSize: 18)
        store.appearance = AppearancePreferences(theme: .dark)
        SettingsKey.store.set(false, forKey: SettingsKey.showBlockDividers) // flip OFF the default-ON toggle
        XCTAssertFalse(SettingsKey.showBlockDividersEnabled)

        store.resetAll()

        XCTAssertEqual(store.terminal, TerminalPreferences())
        XCTAssertEqual(store.appearance, AppearancePreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        XCTAssertTrue(SettingsKey.showBlockDividersEnabled, "Reset All restores the orphan toggle to its default")
    }

    /// "Reset All Settings" returns the keys the old 23-entry hand-list MISSED — the ~35 advanced + Controls +
    /// notification keys that were never reset. Asserts a representative spread from EVERY previously-missed
    /// cluster returns to its declared default: a Controls enum (`rightClickAction`), a Controls bool
    /// (`smoothScroll`), a Shell notification bool (`notifyOnFinish` default OFF flipped ON), a privilege
    /// gate (`titleShellControlled`), an OSC-52 tri-state (`clipboardRead`), an IPC guard (`ipcAllowSendKeys`),
    /// and the auto-progress list (`autoProgressCommands`). Revert-to-confirm-fail: on the pre-fix
    /// `resetAll()` (which reset only the 23-key `globalTabReachableDefaultsKeys` + the typed models) NONE of
    /// these is cleared, so every assertion below fails.
    func testResetAllClearsPreviouslyMissedAdvancedAndControlsKeys() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        Defaults[.rightClickAction] = .copy // default .contextMenu
        Defaults[.smoothScroll] = false // default true
        Defaults[.notifyOnFinish] = true // default false
        Defaults[.titleShellControlled] = false // default true
        Defaults[.clipboardRead] = .deny // default .ask
        Defaults[.ipcAllowSendKeys] = true // default false
        Defaults[.autoProgressCommands] = ["only-one"] // default the built-in list

        store.resetAll()

        XCTAssertEqual(Defaults[.rightClickAction], .contextMenu, "rightClickAction restored by Reset All")
        XCTAssertTrue(Defaults[.smoothScroll], "smoothScroll restored by Reset All")
        XCTAssertFalse(Defaults[.notifyOnFinish], "notifyOnFinish restored by Reset All")
        XCTAssertTrue(Defaults[.titleShellControlled], "titleShellControlled restored by Reset All")
        XCTAssertEqual(Defaults[.clipboardRead], .ask, "clipboardRead restored by Reset All")
        XCTAssertFalse(Defaults[.ipcAllowSendKeys], "ipcAllowSendKeys restored by Reset All")
        XCTAssertEqual(
            Defaults[.autoProgressCommands], SettingsKey.autoProgressCommandsBuiltIn,
            "autoProgressCommands restored by Reset All",
        )
    }

    /// "Reset All Settings" must propagate the reset Controls to the LIVE terminal immediately — not only
    /// after the next settings change / relaunch. Copy-on-Select ON (`copy-on-select = clipboard`) must flip
    /// to the default (`false`) in the re-published libghostty config, and the broadcaster must re-publish.
    /// Revert-to-confirm-fail: without the trailing `refreshTerminalControls()`, the typed-model `didSet`s ran
    /// `applyTerminal()` BEFORE `Defaults.reset(...)` (so the config still carried the OLD Controls) and, with
    /// default typed models, no re-publish fired at all — so both assertions below fail.
    func testResetAllRepublishesTerminalControlsToLiveTerminal() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        Defaults[.copyOnSelect] = true // ON → libghostty `copy-on-select = clipboard`
        store.refreshTerminalControls()
        XCTAssertTrue(
            TerminalConfigBroadcaster.shared.configString.contains("copy-on-select = clipboard"),
            "precondition: the live config reflects Copy-on-Select ON",
        )
        let genBefore = TerminalConfigBroadcaster.shared.generation

        store.resetAll()

        XCTAssertGreaterThan(
            TerminalConfigBroadcaster.shared.generation, genBefore,
            "resetAll re-publishes the terminal config",
        )
        XCTAssertTrue(
            TerminalConfigBroadcaster.shared.configString.contains("copy-on-select = false"),
            "the live terminal reflects the reset (default-OFF) Copy-on-Select immediately",
        )
    }

    /// "Reset Advanced Only" now clears the genuinely advanced-only privilege/IPC/auto-progress keys it sits
    /// beside in the Advanced panel — `title*`, the OSC-52 master (`clipboardShellControlled`) + read/write
    /// tri-state, the IPC guards, and the auto-progress list — while STILL leaving every tab-reachable choice
    /// intact. Revert-to-confirm-fail: the pre-fix `resetAdvancedOnly()` reset only video/agent/rawOverrides,
    /// so the advanced asserts fail; meanwhile `copyOnSelect` (a Controls toggle) must survive both before and
    /// after, guarding against an over-broad reset that would re-introduce the data-loss footgun.
    func testResetAdvancedOnlyClearsAdvancedPrivilegeKeys() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        // Advanced-only keys at non-default values.
        Defaults[.titleShellControlled] = false // default true
        Defaults[.titleReport] = true // default false
        Defaults[.clipboardShellControlled] = false // default true
        Defaults[.clipboardWrite] = .deny // default .allow
        Defaults[.ipcAllowSensitiveSessions] = true // default false
        Defaults[.autoProgressCommands] = [] // default the built-in list
        // A tab-reachable Controls toggle that MUST survive Reset-Advanced-Only.
        SettingsKey.store.set(true, forKey: SettingsKey.copyOnSelect) // default Off
        XCTAssertTrue(SettingsKey.copyOnSelectEnabled)

        store.resetAdvancedOnly()

        XCTAssertTrue(Defaults[.titleShellControlled], "title gate restored by Reset Advanced")
        XCTAssertFalse(Defaults[.titleReport], "title report restored by Reset Advanced")
        XCTAssertTrue(Defaults[.clipboardShellControlled], "OSC-52 master restored by Reset Advanced")
        XCTAssertEqual(Defaults[.clipboardWrite], .allow, "clipboard write restored by Reset Advanced")
        XCTAssertFalse(Defaults[.ipcAllowSensitiveSessions], "IPC guard restored by Reset Advanced")
        XCTAssertEqual(
            Defaults[.autoProgressCommands], SettingsKey.autoProgressCommandsBuiltIn,
            "auto-progress list restored by Reset Advanced",
        )
        // The tab-reachable Controls toggle is UNTOUCHED — Reset-Advanced-Only never destroys a tab choice.
        XCTAssertTrue(SettingsKey.copyOnSelectEnabled, "Controls toggle survives Reset Advanced")
    }

    /// "Reset All Settings" also restores the progress-cluster command-badge toggles (Settings → Shell "TAB
    /// BADGE") — a flipped-OFF "When Command Finishes / Fails / Awaits Input" returns to its default ON. These
    /// keys are tab-reachable (the Shell tab), so they ride ``tabReachableDefaultsKeys``. Revert-to-confirm-fail:
    /// omit them from the reset set and the asserts below fail.
    func testResetAllRestoresTabBadgeCommandToggles() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        Defaults[.tabBadgeOnCommandFinish] = false // default true
        Defaults[.tabBadgeOnCommandFail] = false // default true
        Defaults[.tabBadgeOnCommandAwaitInput] = false // default true

        store.resetAll()

        XCTAssertTrue(Defaults[.tabBadgeOnCommandFinish], "When Command Finishes restored by Reset All")
        XCTAssertTrue(Defaults[.tabBadgeOnCommandFail], "When Command Fails restored by Reset All")
        XCTAssertTrue(Defaults[.tabBadgeOnCommandAwaitInput], "When Command Awaits Input restored by Reset All")
    }

    // MARK: - Reset coverage vs the catalog (anti-drift)

    /// Every key the Advanced → All Settings catalog advertises as `.advancedOnly` (i.e. a real, editable
    /// client `Defaults.Key`, not a `.hasDedicatedTab` render-pseudo-key like `font-family`) is cleared by a
    /// Reset All — it appears in EITHER ``PreferencesStore/tabReachableDefaultsKeys`` OR
    /// ``PreferencesStore/advancedOnlyDefaultsKeys``. This binds the reset sets to the catalog (the declared
    /// "every client key" source) so a future advertised row that nobody adds to a reset set fails here rather
    /// than silently surviving a Reset All. Revert-to-confirm-fail: the pre-fix 23-key `globalTabReachableDefaultsKeys`
    /// omits ~35 advertised keys, so this assertion fails against it.
    func testResetSetsCoverEveryAdvertisedAdvancedOnlyKey() {
        let resetNames = Set(
            (PreferencesStore.tabReachableDefaultsKeys + PreferencesStore.advancedOnlyDefaultsKeys).map(\.name),
        )
        for entry in AllSettingsCatalog.entries where entry.bucket == .advancedOnly {
            XCTAssertTrue(
                resetNames.contains(entry.key),
                "advertised All-Settings key '\(entry.key)' is reset by neither reset set (survives Reset All)",
            )
        }
    }

    /// The two reset sets are DISJOINT (no key is reset twice / classified both tab-reachable and
    /// advanced-only), so the tab-reachable/advanced-only split is unambiguous.
    func testResetSetsAreDisjoint() {
        let tabReachable = Set(PreferencesStore.tabReachableDefaultsKeys.map(\.name))
        let advancedOnly = Set(PreferencesStore.advancedOnlyDefaultsKeys.map(\.name))
        XCTAssertTrue(tabReachable.isDisjoint(with: advancedOnly), "a key is in BOTH reset sets")
    }

    // MARK: - No dead static rows (finding #3)

    /// Every `.advancedOnly` catalog row renders a real INLINE control in `AllSettingsListView`, never a dead
    /// default-value label. The view's `inlineControl(for:)` switch is mirrored by the pure
    /// ``AllSettingsCatalog/inlineEditableKeys`` contract; this pins that the contract covers EXACTLY the
    /// `.advancedOnly` keys (no advertised advanced row falls to the view's `default:` dead-text arm, and no
    /// stale contract entry lingers). Spot-checks the ~15 keys that previously rendered dead (notifications,
    /// sounds, agent-notify, the title/clipboard-master privilege gates, the IPC guards, auto-progress) via an
    /// INDEPENDENT `SettingsKey`-constant list. Revert-to-confirm-fail: before the fix those 15 keys were
    /// `.advancedOnly` with no inline case (dead rows) and absent from `inlineEditableKeys`.
    func testEveryAdvancedOnlyRowHasInlineControl() {
        let advancedOnlyKeys = Set(
            AllSettingsCatalog.entries.filter { $0.bucket == .advancedOnly }.map(\.key),
        )
        XCTAssertEqual(
            AllSettingsCatalog.inlineEditableKeys, advancedOnlyKeys,
            "inlineEditableKeys must list EXACTLY the .advancedOnly catalog keys (else a dead/stale row)",
        )
        // Independent anti-regression: the specific keys that previously rendered dead static labels.
        let previouslyDead = [
            SettingsKey.notifyOnFinish, SettingsKey.notifyOnError, SettingsKey.notifyOnWatchFinish,
            SettingsKey.notifyWhileForegroundKey, SettingsKey.bounceDockIcon,
            SettingsKey.soundShellControlled, SettingsKey.soundOnErrorExit,
            SettingsKey.agentNotifyTaskComplete, SettingsKey.agentNotifyAwaitInput,
            SettingsKey.titleShellControlled, SettingsKey.titleReport, SettingsKey.clipboardShellControlled,
            SettingsKey.ipcAllowSendKeys, SettingsKey.ipcAllowSensitiveSessions,
            SettingsKey.autoProgressCommands,
        ]
        for key in previouslyDead {
            XCTAssertTrue(
                advancedOnlyKeys.contains(key),
                "'\(key)' should be an advancedOnly catalog row",
            )
            XCTAssertTrue(
                AllSettingsCatalog.inlineEditableKeys.contains(key),
                "'\(key)' must now have an inline control (no dead static row)",
            )
        }
    }
}
