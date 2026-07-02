import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the `SettingsKey` fire-time accessors (default ON for the gates, with env/UserDefaults
/// overrides) — the shared source of truth between the Settings scene and the consumers.
@MainActor
final class SettingsKeyTests: XCTestCase {
    private var keys: [String] {
        [
            SettingsKey.oscNotifications,
            SettingsKey.longCommandNotifications,
            // E14/K9 notification policy keys.
            SettingsKey.notifyOnFinish,
            SettingsKey.notifyOnError,
            SettingsKey.notifyOnWatchFinish,
            SettingsKey.notifyWhileForegroundKey,
            SettingsKey.bounceDockIcon,
            SettingsKey.soundShellControlled,
            SettingsKey.soundOnErrorExit,
            SettingsKey.agentNotifyTaskComplete,
            SettingsKey.agentNotifyAwaitInput,
            // E13/WI-3 agent badge gates.
            SettingsKey.agentBadgeWhileProcessing,
            SettingsKey.agentBadgeWhenComplete,
            SettingsKey.agentBadgeWhenAwaitingInput,
            // Progress cluster: command-driven TAB BADGE toggles.
            SettingsKey.tabBadgeOnCommandFinish,
            SettingsKey.tabBadgeOnCommandFail,
            SettingsKey.tabBadgeOnCommandAwaitInput,
            SettingsKey.systemDialogPanes,
            SettingsKey.defaultPaneKindKey,
            SettingsKey.snapPanes,
            SettingsKey.snapGrid,
            SettingsKey.showGrid,
            SettingsKey.nonOverlap,
            SettingsKey.autoSwitchLayouts,
            SettingsKey.redactSecrets,
            SettingsKey.recordClipboardHistory,
            SettingsKey.showBlockDividers,
            SettingsKey.onLaunchKey,
            SettingsKey.copyOnSelect,
            SettingsKey.trimTrailingSpacesOnCopy,
            SettingsKey.pasteProtection,
            SettingsKey.mouseHideWhileTyping,
            SettingsKey.focusFollowsMouse,
            SettingsKey.scrollOnOutput,
            SettingsKey.scrollMultiplier,
            // E8 WI-1: the remaining Controls / Mouse / Scroll knobs.
            SettingsKey.clearSelectionOnTyping,
            SettingsKey.clearSelectionOnCopy,
            SettingsKey.backspaceDeletesSelection,
            SettingsKey.shiftArrowSelect,
            SettingsKey.pasteBracketedSafe,
            SettingsKey.allowMouseCapture,
            SettingsKey.clickToMove,
            SettingsKey.smoothScroll,
            SettingsKey.undoAtPrompt,
            SettingsKey.clipboardReadKey,
            SettingsKey.clipboardWriteKey,
            // E14/K11-K12: privilege surface (title gates + OSC-52 master switch).
            SettingsKey.titleShellControlled,
            SettingsKey.titleReport,
            SettingsKey.clipboardShellControlled,
            // E14/K13: IPC guards on the agent-control ctl socket.
            SettingsKey.ipcAllowSendKeys,
            SettingsKey.ipcAllowSensitiveSessions,
            SettingsKey.allowShiftClickKey,
            SettingsKey.rightClickActionKey,
            SettingsKey.scrollPastLastLineKey,
            SettingsKey.scrollPastFirstLineKey,
            // E10 WI-3: link & status-bar config keys.
            SettingsKey.linkDetection,
            SettingsKey.linkCmdClickKey,
            SettingsKey.linkCmdShiftClickKey,
            SettingsKey.autoDetectLinkSchemesKey,
            SettingsKey.customLinkSchemes,
            SettingsKey.hintPatterns,
            SettingsKey.hintPatternActions,
            // E19/A29 + A18: window-size + auto-hide-tabs-panel keys.
            SettingsKey.windowSizeKey,
            SettingsKey.windowColsKey,
            SettingsKey.windowRowsKey,
            SettingsKey.windowWidthPxKey,
            SettingsKey.windowHeightPxKey,
            SettingsKey.autoHideTabsPanelKey,
        ]
    }

    override func setUp() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    func testGatesDefaultOnWhenUnset() {
        XCTAssertTrue(SettingsKey.oscNotificationsEnabled)
        XCTAssertTrue(SettingsKey.longCommandNotificationsEnabled)
        XCTAssertTrue(SettingsKey.systemDialogPanesEnabled)
    }

    func testGatesRespectAnExplicitFalse() {
        UserDefaults.standard.set(false, forKey: SettingsKey.oscNotifications)
        UserDefaults.standard.set(false, forKey: SettingsKey.systemDialogPanes)
        XCTAssertFalse(SettingsKey.oscNotificationsEnabled)
        XCTAssertFalse(SettingsKey.systemDialogPanesEnabled)
        XCTAssertTrue(SettingsKey.longCommandNotificationsEnabled, "an unset key stays default-ON")
    }

    func testCanvasKeyWireValuesArePinned() {
        // These exact strings are the single source of truth shared with every @AppStorage consumer
        // (CanvasView / CanvasItemView / FloatingPaneHandle / the menu toggles). Pinning the wire values
        // here means a rename that would silently split-brain the Settings UI from the canvas consumers
        // (a user toggles a setting that no longer applies) fails this test.
        XCTAssertEqual(SettingsKey.snapPanes, "canvas.snapPanes")
        XCTAssertEqual(SettingsKey.snapGrid, "canvas.snapGrid")
        XCTAssertEqual(SettingsKey.showGrid, "canvas.showGrid")
        XCTAssertEqual(SettingsKey.nonOverlap, "canvas.nonOverlap")
    }

    func testPrivacyAndLayoutGatesDefaultOnAndRespectFalse() {
        XCTAssertTrue(SettingsKey.redactSecretsEnabled)
        XCTAssertTrue(SettingsKey.recordClipboardHistoryEnabled)
        XCTAssertTrue(SettingsKey.autoSwitchLayoutsEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.redactSecrets)
        UserDefaults.standard.set(false, forKey: SettingsKey.recordClipboardHistory)
        UserDefaults.standard.set(false, forKey: SettingsKey.autoSwitchLayouts)
        XCTAssertFalse(SettingsKey.redactSecretsEnabled)
        XCTAssertFalse(SettingsKey.recordClipboardHistoryEnabled)
        XCTAssertFalse(SettingsKey.autoSwitchLayoutsEnabled)
    }

    /// Chrome toggle `showBlockDividers` defaults ON (dividers shown) and respects a persisted explicit value —
    /// the toggle-persistence proof. The wire key strings are pinned so a rename can't split-brain the Settings
    /// UI from the SplitWorkspaceView / TerminalScreenView consumers.
    func testChromeTogglesDefaultsAndPersistence() {
        // Default when unset.
        XCTAssertTrue(SettingsKey.showBlockDividersEnabled, "block dividers show by default")
        // An explicit persisted value is respected (the toggle persists across reads).
        UserDefaults.standard.set(false, forKey: SettingsKey.showBlockDividers)
        XCTAssertFalse(SettingsKey.showBlockDividersEnabled)
        // The wire keys are the single source of truth shared with the @AppStorage consumers.
        XCTAssertEqual(SettingsKey.showBlockDividers, "terminal.showBlockDividers")
        XCTAssertEqual(SettingsKey.density, "appearance.density")
    }

    func testDefaultPaneKindDefaultsToTerminalAndRoundTrips() {
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal)
        UserDefaults.standard.set(PaneKind.remoteGUI.rawValue, forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .remoteGUI)
        // W11: a stale persisted `claudeCode` value (the retired kind) is no longer a valid raw value
        // here → falls back to `.terminal` (the safe default), like any other invalid raw value.
        UserDefaults.standard.set("claudeCode", forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal, "a retired/invalid raw value falls back to terminal")
        UserDefaults.standard.set("garbage", forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal, "an invalid raw value falls back to terminal")
    }

    // MARK: - E14/K9: notification policy keys + the resolved `notificationSettings` bundle

    /// The new E14 notification keys read their notification-setting.png defaults when unset, and the
    /// resolved ``SettingsKey/notificationSettings`` bundle (which the macOS poster consumes) matches the
    /// spec baseline `NotificationSettings()`. This pins the `Defaults.Key` defaults against an INDEPENDENT
    /// expectation (the struct defaults), catching a divergence between the two sources. Round-trips the
    /// `notifyWhileForeground` enum + repairs a stale raw value to `.off`.
    func testNotificationKeyDefaultsAndResolvedBundle() {
        XCTAssertFalse(SettingsKey.notifyOnFinishEnabled, "Notify on Command Finish defaults OFF")
        XCTAssertTrue(SettingsKey.notifyOnErrorEnabled, "Notify on Error Exit defaults ON")
        XCTAssertTrue(SettingsKey.notifyOnWatchFinishEnabled, "Notify on Watch Finish defaults ON")
        XCTAssertEqual(SettingsKey.notifyWhileForeground, .off, "Notify While Foreground defaults Off")
        XCTAssertTrue(SettingsKey.bounceDockIconEnabled, "Bounce Dock Icon defaults ON")
        XCTAssertTrue(SettingsKey.soundShellControlledEnabled, "Sound — Shell Controlled defaults ON")
        XCTAssertFalse(SettingsKey.soundOnErrorExitEnabled, "Sound on Error Exit defaults OFF")
        XCTAssertTrue(SettingsKey.agentNotifyTaskCompleteEnabled, "Agent task-complete defaults ON")
        XCTAssertTrue(SettingsKey.agentNotifyAwaitInputEnabled, "Agent await-input defaults ON")
        // E13/WI-3 agent badge gates: "while processing" defaults OFF (progress-state.md "off by default"),
        // the other two ON.
        XCTAssertFalse(SettingsKey.agentBadgeWhileProcessingEnabled, "Badge while processing defaults OFF (spec)")
        XCTAssertTrue(SettingsKey.agentBadgeWhenCompleteEnabled, "Badge when complete defaults ON")
        XCTAssertTrue(SettingsKey.agentBadgeWhenAwaitingInputEnabled, "Badge when awaiting input defaults ON")
        XCTAssertEqual(
            SettingsKey.agentBadgeGates,
            AgentBadgeGates(badgeWhileProcessing: false, badgeWhenComplete: true, badgeWhenAwaitingInput: true),
            "the resolved global gates default with while-processing OFF",
        )
        // Progress cluster: the three COMMAND-driven "TAB BADGE" toggles all default ON (distinct keys).
        XCTAssertTrue(SettingsKey.tabBadgeOnCommandFinishEnabled, "Tab Badge When Command Finishes defaults ON")
        XCTAssertTrue(SettingsKey.tabBadgeOnCommandFailEnabled, "Tab Badge When Command Fails defaults ON")
        XCTAssertTrue(SettingsKey.tabBadgeOnCommandAwaitInputEnabled, "Tab Badge When Command Awaits Input defaults ON")
        XCTAssertEqual(SettingsKey.commandBadgeGates, .allOn, "the resolved global command gates default all-on")
        // The resolved bundle the notifier reads equals the spec baseline (the two default sources agree).
        XCTAssertEqual(SettingsKey.notificationSettings, NotificationSettings())
        // Round-trip the enum from its persisted raw value + repair a stale value.
        UserDefaults.standard.set("tab-unfocused", forKey: SettingsKey.notifyWhileForegroundKey)
        XCTAssertEqual(SettingsKey.notifyWhileForeground, .tabUnfocused)
        UserDefaults.standard.set("garbage-from-a-future-version", forKey: SettingsKey.notifyWhileForegroundKey)
        XCTAssertEqual(SettingsKey.notifyWhileForeground, .off, "an invalid raw value repairs to off")
        // A flipped toggle flows into the resolved bundle (proves the resolver reads the live keys).
        UserDefaults.standard.set(true, forKey: SettingsKey.notifyOnFinish)
        XCTAssertTrue(SettingsKey.notificationSettings.notifyOnFinish)
    }

    /// The new E14 wire key strings are the single source of truth shared with every `@Default`/`@AppStorage`
    /// consumer + the All-Settings catalog + the WI-7 navigator — a rename that would split-brain them fails
    /// this pin. The `notifyWhileForeground` enum raw values are the declared persisted config tokens.
    func testNotificationKeyStringsAreStable() {
        XCTAssertEqual(SettingsKey.notifyOnFinish, "notifications.onFinish")
        XCTAssertEqual(SettingsKey.notifyOnError, "notifications.onError")
        XCTAssertEqual(SettingsKey.notifyOnWatchFinish, "notifications.onWatchFinish")
        XCTAssertEqual(SettingsKey.notifyWhileForegroundKey, "notifications.whileForeground")
        XCTAssertEqual(SettingsKey.bounceDockIcon, "notifications.bounceDock")
        XCTAssertEqual(SettingsKey.soundShellControlled, "notifications.soundShellControlled")
        XCTAssertEqual(SettingsKey.soundOnErrorExit, "notifications.soundOnErrorExit")
        XCTAssertEqual(SettingsKey.agentNotifyTaskComplete, "notifications.agentTaskComplete")
        XCTAssertEqual(SettingsKey.agentNotifyAwaitInput, "notifications.agentAwaitInput")
        XCTAssertEqual(SettingsKey.agentBadgeWhileProcessing, "agents.badgeWhileProcessing")
        XCTAssertEqual(SettingsKey.agentBadgeWhenComplete, "agents.badgeWhenComplete")
        XCTAssertEqual(SettingsKey.agentBadgeWhenAwaitingInput, "agents.badgeWhenAwaitingInput")
        XCTAssertEqual(SettingsKey.tabBadgeOnCommandFinish, "tabBadge.onCommandFinish")
        XCTAssertEqual(SettingsKey.tabBadgeOnCommandFail, "tabBadge.onCommandFail")
        XCTAssertEqual(SettingsKey.tabBadgeOnCommandAwaitInput, "tabBadge.onCommandAwaitInput")
        XCTAssertEqual(NotifyWhileForeground.off.rawValue, "off")
        XCTAssertEqual(NotifyWhileForeground.always.rawValue, "always")
        XCTAssertEqual(NotifyWhileForeground.tabUnfocused.rawValue, "tab-unfocused")
    }

    // MARK: - PreferencesStore (W13) — the live source the Settings panels bind to

    /// An isolated `UserDefaults` suite so the round-trips don't touch the real defaults.
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "PreferencesStoreTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testPreferencesStoreLoadsModelDefaultsOnFreshInstall() {
        // A fresh install (no persisted prefs) loads the model DEFAULTS, and the all-nil video/agent
        // models contribute NOTHING to the EnvConfig overlay (behaviour-preserving). `applyOnInit: false`
        // so we assert the loaded models without mutating the process-wide overlay.
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        XCTAssertEqual(store.terminal, TerminalPreferences())
        XCTAssertEqual(store.video, VideoPreferences())
        XCTAssertEqual(store.agent, AgentPreferences())
        XCTAssertEqual(store.keybindings, KeybindingPreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        // The behaviour-preservation proof: the default video ∪ agent overlay is EMPTY.
        XCTAssertTrue(EnvBridge.toEnv(store.video).isEmpty)
        XCTAssertTrue(EnvBridge.toEnv(store.agent).isEmpty)
    }

    func testPreferencesStoreRoundTripsEachModelThroughUserDefaults() {
        let defaults = makeIsolatedDefaults()
        // Write a custom value for each model, then reload a NEW store from the SAME defaults.
        let store = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        store.terminal = TerminalPreferences(fontFamily: "JetBrains Mono", fontSize: 15, cursorStyle: .bar)
        store.video = VideoPreferences(qpSharp: 22, fecM: 2, fecK: 5)
        store.agent = AgentPreferences(agentDetect: true)
        store.keybindings = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "e", command: true)])
        store.rawOverrides = ["AISLOPDESK_FOO": "1"]

        let reloaded = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        XCTAssertEqual(reloaded.terminal, store.terminal)
        XCTAssertEqual(reloaded.video, store.video)
        XCTAssertEqual(reloaded.agent, store.agent)
        XCTAssertEqual(reloaded.keybindings, store.keybindings)
        XCTAssertEqual(reloaded.rawOverrides, store.rawOverrides)
    }

    func testResetAllReturnsToBehaviourPreservingDefaults() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        store.video = VideoPreferences(qpSharp: 30)
        store.rawOverrides = ["AISLOPDESK_X": "9"]
        store.resetAll()
        XCTAssertEqual(store.video, VideoPreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        XCTAssertTrue(EnvBridge.toEnv(store.video).isEmpty)
    }

    // MARK: - E7 WI-1: On-Launch behaviour + new Controls/Scroll/Copy toggles

    /// O1: the `On Launch` general setting defaults to ``OnLaunchBehavior/restoreLastSession`` (the existing
    /// launch behaviour — the store already restores the persisted tree), round-trips ``newWindow`` through
    /// the persisted raw string, and a stale / junk persisted raw value repairs to `.restoreLastSession`
    /// (validate-then-repair, never traps). Read through the public ``SettingsKey/onLaunch`` accessor + the
    /// raw `UserDefaults` the `@Default(.onLaunch)` picker binds (the file's established no-`import Defaults`
    /// convention).
    func testOnLaunchDefaultsToRestore() {
        // Default when unset.
        XCTAssertEqual(SettingsKey.onLaunch, .restoreLastSession)
        // Round-trips the alternative case from its persisted raw value.
        UserDefaults.standard.set("new-window", forKey: SettingsKey.onLaunchKey)
        XCTAssertEqual(SettingsKey.onLaunch, .newWindow)
        // The case's raw value matches the declared config string.
        XCTAssertEqual(OnLaunchBehavior.newWindow.rawValue, "new-window")
        XCTAssertEqual(OnLaunchBehavior.restoreLastSession.rawValue, "restore-last-session")
        // A stale / hostile persisted raw value repairs to the default rather than trapping.
        UserDefaults.standard.set("garbage-from-a-future-version", forKey: SettingsKey.onLaunchKey)
        XCTAssertEqual(SettingsKey.onLaunch, .restoreLastSession, "an invalid raw value repairs to restore")
    }

    /// The new E8-consumed Controls/Scroll/Copy toggles each read their declared default when unset (they are
    /// fire-time `Defaults.Keys` flags, not typed-model fields → golden-safe). E8 owns the behaviour; this
    /// pins the persisted defaults + round-trip so the Controls picker is faithful today.
    func testNewControlsToggleDefaults() {
        // Declared defaults for the Controls config values.
        XCTAssertFalse(SettingsKey.copyOnSelectEnabled, "copy-on-select defaults OFF")
        XCTAssertTrue(SettingsKey.trimTrailingSpacesOnCopyEnabled, "trim trailing spaces defaults ON")
        XCTAssertTrue(SettingsKey.pasteProtectionEnabled, "paste protection defaults ON")
        XCTAssertTrue(SettingsKey.mouseHideWhileTypingEnabled, "mouse-hide-while-typing defaults ON")
        XCTAssertFalse(SettingsKey.focusFollowsMouseEnabled, "focus-follows-mouse defaults OFF")
        XCTAssertTrue(SettingsKey.scrollOnOutputEnabled, "scroll-on-output defaults ON")
        XCTAssertEqual(SettingsKey.scrollMultiplierValue, 1.0, "scroll multiplier defaults to 1.0")
        // An explicit persisted value is respected (the toggle persists across reads).
        UserDefaults.standard.set(true, forKey: SettingsKey.copyOnSelect)
        UserDefaults.standard.set(false, forKey: SettingsKey.scrollOnOutput)
        UserDefaults.standard.set(2.5, forKey: SettingsKey.scrollMultiplier)
        XCTAssertTrue(SettingsKey.copyOnSelectEnabled)
        XCTAssertFalse(SettingsKey.scrollOnOutputEnabled)
        XCTAssertEqual(SettingsKey.scrollMultiplierValue, 2.5)
    }

    /// The new E7 wire key strings are the single source of truth shared with every `@Default`/`@AppStorage`
    /// consumer — a rename that would split-brain the Settings UI from the (E8) fire-sites fails this pin.
    func testSettingsKeyStringsAreStable() {
        XCTAssertEqual(SettingsKey.onLaunchKey, "general.onLaunch")
        XCTAssertEqual(SettingsKey.copyOnSelect, "controls.copyOnSelect")
        XCTAssertEqual(SettingsKey.trimTrailingSpacesOnCopy, "controls.trimTrailingSpaces")
        XCTAssertEqual(SettingsKey.pasteProtection, "controls.pasteProtection")
        XCTAssertEqual(SettingsKey.mouseHideWhileTyping, "controls.mouseHideWhileTyping")
        XCTAssertEqual(SettingsKey.focusFollowsMouse, "controls.focusFollowsMouse")
        XCTAssertEqual(SettingsKey.scrollOnOutput, "controls.scrollOnOutput")
        XCTAssertEqual(SettingsKey.scrollMultiplier, "controls.scrollMultiplier")
    }

    // MARK: - E8 WI-1: the remaining Controls / Mouse / Scroll knobs

    /// The new E8 Bool toggles each read their declared default when unset, and respect a persisted explicit
    /// value (the toggle-persistence proof). These are fire-time `Defaults.Keys` flags (never folded into a
    /// typed prefs model → golden-safe). E8 owns the behaviour; this pins the persisted defaults today.
    func testE8BoolToggleDefaults() {
        XCTAssertTrue(SettingsKey.clearSelectionOnTypingEnabled, "clear-on-typing defaults ON")
        XCTAssertFalse(SettingsKey.clearSelectionOnCopyEnabled, "clear-on-copy defaults OFF")
        // Backspace-deletes-selection ships default OFF: with no libghostty selection-geometry API it cannot
        // faithfully delete the run (it degrades to a single-char Backspace, indistinguishable from OFF), so
        // it is NOT presented as a default-ON toggle that does nothing (honest-disclosure, docs/DECISIONS E8).
        XCTAssertFalse(SettingsKey.backspaceDeletesSelectionEnabled, "backspace-deletes-selection defaults OFF")
        XCTAssertTrue(SettingsKey.shiftArrowSelectEnabled, "shift-arrow-select defaults ON")
        XCTAssertTrue(SettingsKey.pasteBracketedSafeEnabled, "paste-bracketed-safe defaults ON")
        XCTAssertTrue(SettingsKey.allowMouseCaptureEnabled, "allow-mouse-capture defaults ON")
        XCTAssertTrue(SettingsKey.clickToMoveEnabled, "click-to-move defaults ON")
        XCTAssertTrue(SettingsKey.smoothScrollEnabled, "smooth-scroll defaults ON")
        XCTAssertTrue(SettingsKey.undoAtPromptEnabled, "undo-at-prompt defaults ON")
        // An explicit persisted value is respected.
        UserDefaults.standard.set(false, forKey: SettingsKey.clearSelectionOnTyping)
        UserDefaults.standard.set(true, forKey: SettingsKey.clearSelectionOnCopy)
        UserDefaults.standard.set(false, forKey: SettingsKey.smoothScroll)
        XCTAssertFalse(SettingsKey.clearSelectionOnTypingEnabled)
        XCTAssertTrue(SettingsKey.clearSelectionOnCopyEnabled)
        XCTAssertFalse(SettingsKey.smoothScrollEnabled)
    }

    /// The new enum-valued knobs default to the declared value when unset, round-trip the alternative case via
    /// the persisted raw string (`Defaults.PreferRawRepresentable` → `RawRepresentableBridge`), and repair a
    /// stale / hostile persisted raw value to the default rather than trapping (the non-failable
    /// `init(rawValue:)`). Read through the public typed accessors + the raw `UserDefaults` the
    /// `@Default(.key)` pickers bind.
    func testE8EnumKnobDefaultsAndRoundTrip() {
        // Defaults when unset.
        XCTAssertEqual(SettingsKey.clipboardRead, .ask, "clipboard-read defaults Ask")
        XCTAssertEqual(SettingsKey.clipboardWrite, .allow, "clipboard-write defaults Allow")
        XCTAssertEqual(SettingsKey.allowShiftClick, .enabled, "allow-shift-click defaults Enabled")
        XCTAssertEqual(SettingsKey.rightClickAction, .contextMenu, "right-click-action defaults Context Menu")
        XCTAssertEqual(SettingsKey.scrollPastLastLine, .disabled, "scroll-past-last defaults Disabled")
        XCTAssertEqual(SettingsKey.scrollPastFirstLine, .disabled, "scroll-past-first defaults Disabled")
        // Round-trip the alternative case from its persisted raw value.
        UserDefaults.standard.set(ClipboardAccess.deny.rawValue, forKey: SettingsKey.clipboardReadKey)
        UserDefaults.standard.set(MouseShiftCapture.always.rawValue, forKey: SettingsKey.allowShiftClickKey)
        UserDefaults.standard.set(RightClickAction.copyOrPaste.rawValue, forKey: SettingsKey.rightClickActionKey)
        UserDefaults.standard.set(ScrollPastLast.cursorLine.rawValue, forKey: SettingsKey.scrollPastLastLineKey)
        UserDefaults.standard.set(
            ScrollPastFirst.firstLineInMiddle.rawValue,
            forKey: SettingsKey.scrollPastFirstLineKey,
        )
        XCTAssertEqual(SettingsKey.clipboardRead, .deny)
        XCTAssertEqual(SettingsKey.allowShiftClick, .always)
        XCTAssertEqual(SettingsKey.rightClickAction, .copyOrPaste)
        XCTAssertEqual(SettingsKey.scrollPastLastLine, .cursorLine)
        XCTAssertEqual(SettingsKey.scrollPastFirstLine, .firstLineInMiddle)
        // A stale / hostile persisted raw value repairs to the default rather than trapping.
        UserDefaults.standard.set("garbage-from-a-future-version", forKey: SettingsKey.clipboardReadKey)
        UserDefaults.standard.set("garbage", forKey: SettingsKey.rightClickActionKey)
        XCTAssertEqual(SettingsKey.clipboardRead, .ask, "an invalid raw value repairs to ask")
        XCTAssertEqual(SettingsKey.rightClickAction, .contextMenu, "an invalid raw value repairs to context menu")
    }

    /// The new E8 wire key strings are the single source of truth shared with every `@Default`/`@AppStorage`
    /// consumer + the fire-sites — a rename that would split-brain the Settings UI from the fire-sites fails
    /// this pin.
    func testE8SettingsKeyStringsAreStable() {
        XCTAssertEqual(SettingsKey.clearSelectionOnTyping, "controls.clearSelectionOnTyping")
        XCTAssertEqual(SettingsKey.clearSelectionOnCopy, "controls.clearSelectionOnCopy")
        XCTAssertEqual(SettingsKey.backspaceDeletesSelection, "controls.backspaceDeletesSelection")
        XCTAssertEqual(SettingsKey.shiftArrowSelect, "controls.shiftArrowSelect")
        XCTAssertEqual(SettingsKey.pasteBracketedSafe, "controls.pasteBracketedSafe")
        XCTAssertEqual(SettingsKey.allowMouseCapture, "controls.allowMouseCapture")
        XCTAssertEqual(SettingsKey.clickToMove, "controls.clickToMove")
        XCTAssertEqual(SettingsKey.smoothScroll, "controls.smoothScroll")
        XCTAssertEqual(SettingsKey.undoAtPrompt, "controls.undoAtPrompt")
        XCTAssertEqual(SettingsKey.clipboardReadKey, "controls.clipboardRead")
        XCTAssertEqual(SettingsKey.clipboardWriteKey, "controls.clipboardWrite")
        XCTAssertEqual(SettingsKey.allowShiftClickKey, "controls.allowShiftClick")
        XCTAssertEqual(SettingsKey.rightClickActionKey, "controls.rightClickAction")
        XCTAssertEqual(SettingsKey.scrollPastLastLineKey, "controls.scrollPastLastLine")
        XCTAssertEqual(SettingsKey.scrollPastFirstLineKey, "controls.scrollPastFirstLine")
    }

    // MARK: - E10 WI-3: link & status-bar config keys

    /// The new E10 link-interaction keys read their declared defaults when unset, round-trip the alternative
    /// case via the persisted raw value (`Defaults.PreferRawRepresentable` → `RawRepresentableBridge`), and
    /// repair a stale / hostile persisted raw value to the default rather than trapping (the non-failable
    /// `init(rawValue:)`). ``SettingsKey/linkSchemePolicy`` bridges the persisted mode + custom list into the
    /// detector's ``LinkSchemePolicy``. Read through the public typed accessors + the raw `UserDefaults` the
    /// `@Default(.key)` pickers bind (the file's established no-`import Defaults` convention).
    func testE10LinkKeyDefaultsAndRoundTrip() {
        // Defaults when unset.
        XCTAssertTrue(SettingsKey.linkDetectionEnabled, "link-detection defaults ON")
        XCTAssertEqual(SettingsKey.linkCmdClick, .open, "link-cmd-click defaults Open")
        XCTAssertEqual(SettingsKey.linkCmdShiftClick, .revealFinder, "link-cmd-shift-click defaults Reveal")
        XCTAssertEqual(SettingsKey.autoDetectLinkSchemes, .all, "auto-detect schemes defaults All")
        XCTAssertEqual(SettingsKey.linkSchemePolicy, .all, "the default scheme policy detects any scheme")
        // Round-trip the alternative case from its persisted raw value.
        UserDefaults.standard.set(false, forKey: SettingsKey.linkDetection)
        UserDefaults.standard.set(LinkCmdClick.copy.rawValue, forKey: SettingsKey.linkCmdClickKey)
        UserDefaults.standard.set(
            LinkCmdShiftClick.openSystemDefault.rawValue,
            forKey: SettingsKey.linkCmdShiftClickKey,
        )
        UserDefaults.standard.set(AutoDetectLinkSchemes.custom.rawValue, forKey: SettingsKey.autoDetectLinkSchemesKey)
        UserDefaults.standard.set(["codex", "ssh"], forKey: SettingsKey.customLinkSchemes)
        XCTAssertFalse(SettingsKey.linkDetectionEnabled)
        XCTAssertEqual(SettingsKey.linkCmdClick, .copy)
        XCTAssertEqual(SettingsKey.linkCmdShiftClick, .openSystemDefault)
        XCTAssertEqual(SettingsKey.autoDetectLinkSchemes, .custom)
        // Custom mode bridges the persisted list into the detector policy (the always-on schemes are folded in
        // by the detector itself, not by this policy value).
        XCTAssertEqual(SettingsKey.linkSchemePolicy, .custom(["codex", "ssh"]))
        // A stale / hostile persisted raw value repairs to the default rather than trapping.
        UserDefaults.standard.set("garbage-from-a-future-version", forKey: SettingsKey.linkCmdClickKey)
        UserDefaults.standard.set("nonsense", forKey: SettingsKey.autoDetectLinkSchemesKey)
        XCTAssertEqual(SettingsKey.linkCmdClick, .open, "an invalid raw value repairs to open")
        XCTAssertEqual(SettingsKey.autoDetectLinkSchemes, .all, "an invalid raw value repairs to all")
    }

    /// The new E10 wire key strings are the single source of truth shared with every `@Default`/`@AppStorage`
    /// consumer + the All-Settings catalog + the (E10 WI-5/6/8/9) fire-sites — a rename that would split-brain
    /// the Settings UI from the fire-sites fails this pin. The enum raw values are the declared config tokens
    /// (shared with the host-route dispatch + `docs/20-wire-protocol.md`).
    func testE10LinkKeyStringsAreStable() {
        XCTAssertEqual(SettingsKey.linkDetection, "controls.linkDetection")
        XCTAssertEqual(SettingsKey.linkCmdClickKey, "controls.linkCmdClick")
        XCTAssertEqual(SettingsKey.linkCmdShiftClickKey, "controls.linkCmdShiftClick")
        XCTAssertEqual(SettingsKey.autoDetectLinkSchemesKey, "controls.autoDetectLinkSchemes")
        XCTAssertEqual(SettingsKey.customLinkSchemes, "controls.customLinkSchemes")
        XCTAssertEqual(SettingsKey.hintPatterns, "controls.hintPatterns")
        XCTAssertEqual(SettingsKey.hintPatternActions, "controls.hintPatternActions")
        XCTAssertEqual(LinkCmdClick.open.rawValue, "open")
        XCTAssertEqual(LinkCmdClick.nothing.rawValue, "nothing")
        XCTAssertEqual(LinkCmdShiftClick.revealFinder.rawValue, "reveal-finder")
        XCTAssertEqual(LinkCmdShiftClick.openSystemDefault.rawValue, "open-system-default")
        XCTAssertEqual(AutoDetectLinkSchemes.all.rawValue, "all")
        XCTAssertEqual(AutoDetectLinkSchemes.custom.rawValue, "custom")
    }

    // MARK: - E14/K11-K12: privilege surface (title gates + OSC-52 master switch)

    /// The new E14 privilege keys read their notification-setting.png defaults when unset (Title — Shell
    /// Controlled ON, Title Report OFF, Clipboard — Shell Controlled ON), respect an explicit persisted value,
    /// and their wire key strings are the single source of truth shared with the navigator + the All-Settings
    /// catalog (a rename that would split-brain them fails this pin).
    func testPrivilegeKeyDefaultsAndStrings() {
        // Defaults when unset.
        XCTAssertTrue(SettingsKey.titleShellControlledEnabled, "Title — Shell Controlled defaults ON")
        XCTAssertFalse(SettingsKey.titleReportEnabled, "Title Report defaults OFF")
        XCTAssertTrue(SettingsKey.clipboardShellControlledEnabled, "Clipboard — Shell Controlled defaults ON")
        // An explicit persisted value is respected (the toggle persists across reads).
        UserDefaults.standard.set(false, forKey: SettingsKey.titleShellControlled)
        UserDefaults.standard.set(true, forKey: SettingsKey.titleReport)
        UserDefaults.standard.set(false, forKey: SettingsKey.clipboardShellControlled)
        XCTAssertFalse(SettingsKey.titleShellControlledEnabled)
        XCTAssertTrue(SettingsKey.titleReportEnabled)
        XCTAssertFalse(SettingsKey.clipboardShellControlledEnabled)
        // The wire key strings are the single source of truth.
        XCTAssertEqual(SettingsKey.titleShellControlled, "controls.titleShellControlled")
        XCTAssertEqual(SettingsKey.titleReport, "controls.titleReport")
        XCTAssertEqual(SettingsKey.clipboardShellControlled, "controls.clipboardShellControlled")
    }

    /// The "Clipboard — Shell Controlled" master switch (default ON) gates the resolved OSC-52 read/write
    /// access AHEAD of the per-direction Ask/Allow/Deny gate: when OFF, ``TerminalControls/from(defaults:)``
    /// resolves BOTH directions to ``ClipboardAccess/deny`` so the libghostty config emits
    /// `clipboard-read/write = deny`. Revert-to-confirm-fail: before the master gate, `from()` returned the
    /// raw per-direction value, so the two `.deny` asserts fail on the un-gated code.
    func testClipboardMasterSwitchGatesResolvedAccess() {
        // Set both directions to a permissive non-default value so the gate's effect is observable.
        UserDefaults.standard.set(ClipboardAccess.allow.rawValue, forKey: SettingsKey.clipboardReadKey)
        UserDefaults.standard.set(ClipboardAccess.allow.rawValue, forKey: SettingsKey.clipboardWriteKey)
        // Master ON (the unset default) → the per-direction values pass through.
        let onControls = TerminalControls.from(defaults: .standard)
        XCTAssertEqual(onControls.clipboardRead, .allow, "master ON passes the per-direction read value")
        XCTAssertEqual(onControls.clipboardWrite, .allow, "master ON passes the per-direction write value")
        // Master OFF → both resolve to deny regardless of the per-direction value.
        UserDefaults.standard.set(false, forKey: SettingsKey.clipboardShellControlled)
        let offControls = TerminalControls.from(defaults: .standard)
        XCTAssertEqual(offControls.clipboardRead, .deny, "master OFF denies clipboard read")
        XCTAssertEqual(offControls.clipboardWrite, .deny, "master OFF denies clipboard write")
    }

    // MARK: - E14/K13: IPC guards on the agent-control ctl socket (client edit surface)

    /// The two E14/K13 IPC-guard keys are the CLIENT edit/display surface for the HOST ctl-socket guards
    /// (enforced host-side via the AISLOPDESK_IPC_ALLOW_* env bridge). They default OFF (conservative —
    /// mutation / sensitive-session access is opt-in), respect an explicit persisted value, and their wire
    /// strings are the single source of truth shared with the All-Settings catalog.
    func testIPCGuardKeyDefaultsAndStrings() {
        // Defaults when unset — both OFF.
        XCTAssertFalse(SettingsKey.ipcAllowSendKeysEnabled, "IPC — Allow Send Keys defaults OFF")
        XCTAssertFalse(SettingsKey.ipcAllowSensitiveSessionsEnabled, "IPC — Allow Sensitive Sessions defaults OFF")
        // An explicit persisted value is respected.
        UserDefaults.standard.set(true, forKey: SettingsKey.ipcAllowSendKeys)
        UserDefaults.standard.set(true, forKey: SettingsKey.ipcAllowSensitiveSessions)
        XCTAssertTrue(SettingsKey.ipcAllowSendKeysEnabled)
        XCTAssertTrue(SettingsKey.ipcAllowSensitiveSessionsEnabled)
        // The wire key strings are the single source of truth.
        XCTAssertEqual(SettingsKey.ipcAllowSendKeys, "advanced.ipcAllowSendKeys")
        XCTAssertEqual(SettingsKey.ipcAllowSensitiveSessions, "advanced.ipcAllowSensitiveSessions")
    }

    // MARK: - E19/A29 + A18: window-size + auto-hide-tabs-panel keys (surfaced by the Appearance WI-6 rows)

    /// The E19 window-size + auto-hide keys read their declared defaults when unset (`.remember`, 80, 24,
    /// 1000, 600, `.default`), round-trip a written value via the persisted raw, and a stale / hostile persisted
    /// ENUM raw repairs to the default rather than trapping (the `Defaults.PreferRawRepresentable` bridge — a
    /// failable `init(rawValue:)` would otherwise return nil; the bridge falls back to the key default). The
    /// Int keys are plain raw values clamped downstream by `WindowSizeMath`, so they store/read verbatim here.
    /// Read through the public typed accessors + the raw `UserDefaults` the `@Default(.key)` pickers bind (the
    /// file's established no-`import Defaults` convention).
    func testWindowSizeAndAutoHideKeyDefaultsAndRoundTrip() {
        // Defaults when unset.
        XCTAssertEqual(SettingsKey.windowSize, .remember, "window-size defaults to Remember")
        XCTAssertEqual(SettingsKey.windowCols, 80, "window-cols defaults to 80")
        XCTAssertEqual(SettingsKey.windowRows, 24, "window-rows defaults to 24")
        XCTAssertEqual(SettingsKey.windowWidthPx, 1000, "window-width-px defaults to 1000")
        XCTAssertEqual(SettingsKey.windowHeightPx, 600, "window-height-px defaults to 600")
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .default, "auto-hide-tabs-panel defaults to Default")
        // Round-trip a written value.
        UserDefaults.standard.set(WindowSizeMode.grid.rawValue, forKey: SettingsKey.windowSizeKey)
        UserDefaults.standard.set(120, forKey: SettingsKey.windowColsKey)
        UserDefaults.standard.set(40, forKey: SettingsKey.windowRowsKey)
        UserDefaults.standard.set(1440, forKey: SettingsKey.windowWidthPxKey)
        UserDefaults.standard.set(900, forKey: SettingsKey.windowHeightPxKey)
        UserDefaults.standard.set(AutoHideTabsPanelMode.auto.rawValue, forKey: SettingsKey.autoHideTabsPanelKey)
        XCTAssertEqual(SettingsKey.windowSize, .grid)
        XCTAssertEqual(SettingsKey.windowCols, 120)
        XCTAssertEqual(SettingsKey.windowRows, 40)
        XCTAssertEqual(SettingsKey.windowWidthPx, 1440)
        XCTAssertEqual(SettingsKey.windowHeightPx, 900)
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .auto)
        // A stale / hostile persisted enum raw repairs to the default rather than trapping.
        UserDefaults.standard.set("garbage-from-a-future-version", forKey: SettingsKey.windowSizeKey)
        UserDefaults.standard.set("nonsense", forKey: SettingsKey.autoHideTabsPanelKey)
        XCTAssertEqual(SettingsKey.windowSize, .remember, "an invalid raw value repairs to remember")
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .default, "an invalid raw value repairs to default")
    }

    /// The new E19 wire key strings are the single source of truth shared with every `@Default`/`@AppStorage`
    /// consumer (the Appearance Window + Auto Hide Tabs Panel rows, the WI-7 auto-hide glue, the macOS NSWindow
    /// size glue) — a rename that would split-brain them fails this pin. The enum raw values are the declared
    /// config tokens (`window-size` = `remember`/`grid`/`frame`; `auto-hide-tabs-panel` = `default`/`always`/`auto`).
    func testWindowSizeAndAutoHideKeyStringsAreStable() {
        XCTAssertEqual(SettingsKey.windowSizeKey, "window.size")
        XCTAssertEqual(SettingsKey.windowColsKey, "window.cols")
        XCTAssertEqual(SettingsKey.windowRowsKey, "window.rows")
        XCTAssertEqual(SettingsKey.windowWidthPxKey, "window.widthPx")
        XCTAssertEqual(SettingsKey.windowHeightPxKey, "window.heightPx")
        XCTAssertEqual(SettingsKey.autoHideTabsPanelKey, "shell.autoHideTabsPanel")
        XCTAssertEqual(WindowSizeMode.remember.rawValue, "remember")
        XCTAssertEqual(WindowSizeMode.grid.rawValue, "grid")
        XCTAssertEqual(WindowSizeMode.frame.rawValue, "frame")
        XCTAssertEqual(AutoHideTabsPanelMode.default.rawValue, "default")
        XCTAssertEqual(AutoHideTabsPanelMode.always.rawValue, "always")
        XCTAssertEqual(AutoHideTabsPanelMode.auto.rawValue, "auto")
    }
}
