import Defaults
import Foundation
import SlopDeskVideoProtocol
import SlopDeskWorkspaceModel

// `SettingsKey`: the pure `UserDefaults`-key namespace + fire-time boolean/`PaneKind` accessors read by the
// headless logic (CommandCompletionNotifier, AppLaunchMonitor, WorkspaceStore+Completion, the monitors). The
// Settings UI binds the SAME keys via `@Default(.key)` (the typed `Defaults.Keys` below).
//
// Accessors read sindresorhus/Defaults typed keys — the per-key default lives ONCE in `Defaults.Keys`, not
// repeated in each `?? true`. The wire STRING constants stay the one source of truth (the `Defaults.Key`
// names reuse them; `SettingsKeyTests` pins them, `@Default`/`@AppStorage` consumers share them). No SwiftUI
// import — headless.
public enum SettingsKey {
    /// The ONE `UserDefaults` suite backing the whole global-flag namespace — every `Defaults.Keys`
    /// entry below is pinned to it via `Defaults.Key.init(slopDesk:default:)`.
    ///
    /// In the app this IS `.standard` (the same domain the `@AppStorage(SettingsKey.…)` views bind),
    /// so every consumer agrees on one store. Under XCTest it is a per-PROCESS suite, wiped at
    /// creation and removed at exit: `swift test --parallel` runs many xctest processes that all
    /// share ONE standard domain through cfprefsd, so a global toggle flipped in one worker races a
    /// read in another, and a crashed run's mutations persist into the next run. Tests must mutate
    /// global flags via `SettingsKey.store` — a write to `UserDefaults.standard` is invisible to the
    /// keys in a test process.
    ///
    /// `SLOPDESK_DEFAULTS_SUITE` names a suite for the SHIPPING app, and exists for one reason: the
    /// GUI gates exec this bundle's binary directly, and `CFFIXED_USER_HOME` — which moves their
    /// Application Support container — does NOT move `UserDefaults`. cfprefsd resolves the real home
    /// whatever the environment says, so every gate that connects has been writing its own loopback
    /// port into the developer's `connection.recentTargets`, five entries deep, evicting the host
    /// they actually use. A suite isolates BOTH directions: a suite-backed `UserDefaults` cannot see
    /// this bundle's own persistent domain, and `NSArgumentDomain` still outranks it — which is what
    /// keeps `check-launch-restore.sh`'s `-connection.recentTargets` fixture driving the real
    /// auto-reconnect. The XCTest suite wins over it, so an exported variable in a developer's shell
    /// cannot collapse `swift test --parallel` back onto one shared domain.
    /// `nonisolated(unsafe)`: `UserDefaults` is documented thread-safe; it just lacks a `Sendable` mark.
    public nonisolated(unsafe) static let store: UserDefaults = {
        installSuiteRemovalHook() // as early as this process ever gets — see the LIFO note there
        guard let name = resolvedSuiteName, let suite = UserDefaults(suiteName: name) else {
            return .standard
        }
        // The XCTest suite is anonymous — nobody outside this process knows its name, so nothing else
        // can clean it and a reused pid would inherit the last run's mutations. It wipes itself.
        //
        // An env-named suite is the opposite: whoever set `SLOPDESK_DEFAULTS_SUITE` owns its lifetime
        // and SEEDS it. `check-launch-restore.sh` drives the returning-user launch path, and a
        // returning user is precisely someone whose defaults are not empty — wiping here would erase
        // the fixture and turn every run of that gate into a fresh install.
        if testProcessSuiteName != nil {
            suite.removePersistentDomain(forName: name)
            removeSuiteAtExit(named: name)
        }
        return suite
    }()

    /// Queues a throwaway suite for removal when this process EXITS, and takes it away then.
    ///
    /// Removing one mid-process does NOT stick. cfprefsd is a separate daemon and keeps the domain
    /// for as long as a live `UserDefaults` still registers it, so it re-creates the plist on its
    /// next flush — measured, with a test that removed its own suite, asserted the file gone (it
    /// was), and still left it in `~/Library/Preferences` at the end of the run. Process exit is the
    /// one moment nothing can write it back.
    ///
    /// The caller is any test that builds its own `UserDefaults(suiteName:)` and writes to it. There
    /// is no shipping caller other than ``store`` itself: an app that names a suite through
    /// `SLOPDESK_DEFAULTS_SUITE` is one an automation run `pkill`s, so nothing inside it runs at
    /// exit and the gate's own trap removes it from the shell.
    static func removeSuiteAtExit(named name: String) {
        installSuiteRemovalHook()
        suiteRemovalLock.lock()
        defer { suiteRemovalLock.unlock() }
        guard !pendingSuiteRemovals.contains(name) else { return }
        pendingSuiteRemovals.append(name)
    }

    /// `atexit` is LIFO, so the sweep has to be registered EARLY to run LATE — after whatever
    /// CoreFoundation registers on its own way out, whose flush otherwise re-creates every file the
    /// sweep just unlinked. ``store`` calls this first thing, which in a test process is the first
    /// settings read; a caller that beats it there installs the hook itself.
    private static func installSuiteRemovalHook() {
        suiteRemovalLock.lock()
        defer { suiteRemovalLock.unlock() }
        guard !suiteRemovalHookInstalled else { return }
        suiteRemovalHookInstalled = true
        atexit {
            suiteRemovalLock.lock()
            let names = pendingSuiteRemovals
            suiteRemovalLock.unlock()
            for name in names { Self.removeSuite(named: name) }
        }
    }

    /// Takes a throwaway suite away COMPLETELY — the domain AND the file it lives in.
    ///
    /// `removePersistentDomain` empties the domain and leaves a 58-byte plist behind. That is what
    /// put 55,003 `slopdesk.tests.pid*.plist` files in this machine's `~/Library/Preferences`: one
    /// per xctest process ever run here, every one of them emptied and none of them removed. A GUI
    /// gate's per-run suite leaks the same way, and its cleanup trap calls the shell equivalent of
    /// this.
    ///
    /// `synchronize()` between the emptying and the unlink is load-bearing. The emptying is written
    /// back lazily, so unlinking first lets cfprefsd re-create the file after the process is gone.
    ///
    /// The path is `NSHomeDirectory()`-relative, which is where cfprefsd puts it for THIS process.
    /// Under `CFFIXED_USER_HOME` the two disagree — every home API reports the fixed home while
    /// cfprefsd keeps writing the real one — so an app a gate launches cannot clean up after itself
    /// and the gate's trap does it from a shell that still has the real `HOME`.
    static func removeSuite(named name: String) {
        let suite = UserDefaults(suiteName: name)
        suite?.removePersistentDomain(forName: name)
        suite?.synchronize()
        // cfprefsd is a SEPARATE process and keeps the domain cached after this one empties it; an
        // unlink alone races its idle flush and the file comes back. This is what makes it let go.
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(
            atPath: NSHomeDirectory() + "/Library/Preferences/\(name).plist",
        )
    }

    /// Which suite ``store`` binds, given the two things that can ask for one. `nil` = `.standard`.
    ///
    /// Pure, so the precedence can be pinned without a second process: the XCTest per-pid suite
    /// FIRST (a stray `SLOPDESK_DEFAULTS_SUITE` in the environment must never put parallel xctest
    /// workers back on one domain), then the environment, then nothing. An empty environment value
    /// is unset — `FOO="${BAR}"` with `BAR` unset is how a shell delivers one by accident, and
    /// `UserDefaults(suiteName: "")` is not a store anybody meant to name.
    static func suiteName(
        testProcessSuite: String?,
        environment: [String: String],
    ) -> String? {
        if let testProcessSuite { return testProcessSuite }
        guard let named = environment[defaultsSuiteEnvKey], !named.isEmpty else { return nil }
        return named
    }

    /// The environment variable an automation run sets to keep its writes off the developer's domain.
    public static let defaultsSuiteEnvKey = "SLOPDESK_DEFAULTS_SUITE"

    // General / launch
    /// The `On Launch` general setting — restore the last session vs open a fresh window.
    /// Stored as the ``OnLaunchBehavior`` rawValue (`restore-last-session` / `new-window`); default
    /// `.restoreLastSession` (the existing launch behaviour). Read by the app-launch path via
    /// ``WorkspacePersistence/launchTree(behavior:persistence:)`` at store construction.
    public static let onLaunchKey = "general.onLaunch" // OnLaunchBehavior.rawValue
    // Notifications
    public static let oscNotifications = "notifications.osc"
    public static let longCommandNotifications = "notifications.longCommand"
    // (notification-setting.png NOTIFICATION section). Fire-time `Defaults.Keys` flags, never folded
    // into a typed prefs model → golden-safe. The pure ``NotificationPolicy`` reads the resolved
    // ``notificationSettings`` bundle; the UI (the navigator) binds the SAME keys.
    /// "Notify on Command Finish" — fire when a command exits 0 (default OFF).
    public static let notifyOnFinish = "notifications.onFinish"
    /// "Notify on Error Exit" — fire when a command exits non-zero (default ON).
    public static let notifyOnError = "notifications.onError"
    /// "Notify on Watch Finish" — fire when an `slopdesk watch`-wrapped command finishes (default ON).
    public static let notifyOnWatchFinish = "notifications.onWatchFinish"
    /// "Notify While Foreground" — banner behaviour while the app is frontmost. Stored as the
    /// ``NotifyWhileForeground`` rawValue (`off`/`always`/`tab-unfocused`); default `.off`. `Key` suffix frees
    /// the bare name for the typed accessor.
    public static let notifyWhileForegroundKey = "notifications.whileForeground" // NotifyWhileForeground.rawValue
    /// "Bounce Dock Icon" — bounce the Dock when a notification arrives and the app is not focused
    /// (default ON; macOS-only behaviour — the Dock tile is process-global).
    public static let bounceDockIcon = "notifications.bounceDock"
    /// "Sound — Shell Controlled" — a `BEL` rings `NSSound.beep()` (default ON). Read by ``BellPolicy``.
    public static let soundShellControlled = "notifications.soundShellControlled"
    /// "Sound on Error Exit" — beep when a command exits non-zero (default OFF). Read by ``ErrorSoundPolicy``.
    public static let soundOnErrorExit = "notifications.soundOnErrorExit"
    /// "Code Agent — Notify When Task Completes" — agent went idle (default ON; Claude-only).
    public static let agentNotifyTaskComplete = "notifications.agentTaskComplete"
    /// "Code Agent — Notify When Awaiting Input" — agent needs approval / input (default ON; Claude-only).
    public static let agentNotifyAwaitInput = "notifications.agentAwaitInput"
    // (agents__agents-overview.md "Agent Behaviour"). The three BADGE toggles — fire-time
    // `Defaults.Keys` flags, never folded into a typed prefs model → golden-safe. They gate which fused tab
    // badge the sidebar SHOWS via the pure ``AgentBadgeGates``; a per-pane override in ``WorkspaceStore`` beats
    // this global default. Claude-only.
    /// "Badge while processing" — show the agent THINKING spinner (default OFF per `progress-state.md`
    /// "Claude Code — While Processing (off by default)"; Claude-only). Gates ONLY the agent's own spinner — a
    /// program's busy / OSC 9;4 progress spinner is never silenced by it.
    public static let agentBadgeWhileProcessing = "agents.badgeWhileProcessing"
    /// "Badge when complete" — show the completed-checkmark / finished-dot badge (default ON; Claude-only).
    public static let agentBadgeWhenComplete = "agents.badgeWhenComplete"
    /// "Badge when awaiting input" — show the awaiting-input hand badge (default ON; Claude-only).
    public static let agentBadgeWhenAwaitingInput = "agents.badgeWhenAwaitingInput"
    // Progress cluster (progress-state.md — Settings → Shell "TAB BADGE"). The three COMMAND-driven badge
    // toggles, DISTINCT from the Claude `agentBadge*` set so command vs agent badges are controlled
    // independently. Fire-time flags, never folded into a typed prefs model → golden-safe. Consumed via
    // `SettingsKey.commandBadgeGates` → `TabBadgeGating.resolve`.
    /// "Tab Badge — When Command Finishes" — show the completed/finished badge for a clean command exit
    /// (default ON). Distinct from the agent `agentBadgeWhenComplete` gate.
    public static let tabBadgeOnCommandFinish = "tabBadge.onCommandFinish"
    /// "Tab Badge — When Command Fails" — show the error badge for a non-zero command exit (default ON).
    /// Gates only the `.failure` COMMAND-exit badge; an OSC 9;4;2 program progress error has no opt-out.
    public static let tabBadgeOnCommandFail = "tabBadge.onCommandFail"
    /// "Tab Badge — When Command Awaits Input" — show the awaiting-input hand for a plain command stopped at
    /// an interactive prompt (default ON). The host-side ~1.5s cursor-at-prompt quiescence detector that would
    /// DRIVE it is deferred (see `docs/DECISIONS.md`); the toggle is wired so the future signal gates without a
    /// code change. Distinct from the agent `agentBadgeWhenAwaitingInput` gate.
    public static let tabBadgeOnCommandAwaitInput = "tabBadge.onCommandAwaitInput"
    /// "Tab Badge — Busy Dot Delay" — seconds a foreground command must have been running before the plain
    /// busy dot (`TabBadgeKind.commandBusy`) is shown (default 3 s; 0 = immediate). Keeps a fast `ls`/`cd`
    /// from flashing the rail. Consumed via `WorkspaceStore.paneShowsBusyDot(_:now:)`.
    public static let tabBadgeBusyDelaySeconds = "tabBadge.busyDelaySeconds"
    // Controls / scroll / copy (Controls section). FIRE-TIME `Defaults.Keys` flags, deliberately NOT folded
    // into any typed prefs model, so they never reach the `EnvConfig` overlay or the `video-prefs.json`
    // sidecar → golden-safe. The behaviour lives elsewhere; this file only declares + surfaces them (persisted
    // forward-stubs that round-trip today).
    /// `copy-on-select` — copy the selection to the pasteboard as soon as it is made (default OFF).
    /// **The behaviour lives elsewhere.**
    public static let copyOnSelect = "controls.copyOnSelect"
    /// `clipboard-trim-trailing-spaces` — strip trailing whitespace from each copied line (default ON).
    /// **The behaviour lives elsewhere.**
    public static let trimTrailingSpacesOnCopy = "controls.trimTrailingSpaces"
    /// `clipboard-paste-protection` — warn before pasting text that contains a newline / control char
    /// (default ON). **The behaviour lives elsewhere.**
    public static let pasteProtection = "controls.pasteProtection"
    /// `mouse-hide-while-typing` — hide the mouse pointer while typing (default ON). **The behaviour lives
    /// elsewhere.**
    public static let mouseHideWhileTyping = "controls.mouseHideWhileTyping"
    /// `focus-follows-mouse` — focus the pane the pointer is over without a click (default OFF).
    /// Read live by the libghostty surface's `mouseMoved` via ``FocusFollowsMousePolicy``.
    public static let focusFollowsMouse = "controls.focusFollowsMouse"
    /// `mouse-scroll-multiplier` — multiply the scroll-wheel delta (default `1.0`). **The behaviour lives
    /// elsewhere.**
    public static let scrollMultiplier = "controls.scrollMultiplier"

    // The remaining Controls / Mouse / Scroll knobs. Same fire-time flags → golden-safe. The behaviour lives
    // elsewhere; declared + persisted here so the Controls UI round-trips. Bool keys take the bare name
    // (`…Enabled` accessor); enum-valued keys take a `…Key` suffix (like `onLaunchKey`) so the typed accessor
    // below can use the bare name.
    /// `selection-clear-on-typing` — clear the selection when the user types (default ON).
    public static let clearSelectionOnTyping = "controls.clearSelectionOnTyping"
    /// `selection-clear-on-copy` — clear the selection after an explicit copy (default OFF).
    public static let clearSelectionOnCopy = "controls.clearSelectionOnCopy"
    /// "Shift+Arrow Select" — ⇧+arrows drive native selection instead of forwarding the arrow
    /// escapes (default ON). Emits the four `adjust_selection` keybinds.
    public static let shiftArrowSelect = "controls.shiftArrowSelect"
    /// `clipboard-paste-bracketed-safe` — treat a bracketed paste as safe, skipping the warning when
    /// the program advertised `?2004h` (default ON).
    public static let pasteBracketedSafe = "controls.pasteBracketedSafe"
    /// `clipboard-write` — the OSC-52 clipboard-WRITE access gate (stored ``ClipboardAccess`` rawValue,
    /// default `allow`).
    public static let clipboardWriteKey = "controls.clipboardWrite"
    /// `clipboard-read` — the OSC-52 clipboard-READ access gate (stored ``ClipboardAccess`` rawValue,
    /// default `ask`).
    public static let clipboardReadKey = "controls.clipboardRead"
    /// `mouse-reporting` (Allow Mouse Capture) — allow programs to capture mouse events (default ON).
    public static let allowMouseCapture = "controls.allowMouseCapture"
    /// `mouse-shift-capture` (Allow Shift with Mouse Click) — whether ⇧ bypasses a program's mouse
    /// capture (stored ``MouseShiftCapture`` rawValue, default `enabled`).
    public static let allowShiftClickKey = "controls.allowShiftClick"
    /// `cursor-click-to-move` — click in the prompt to move the shell cursor (default ON).
    public static let clickToMove = "controls.clickToMove"
    /// "Option as Alt" — whether the macOS Option key sends Alt/Meta (stored ``OptionAsAlt`` rawValue,
    /// default `off`). Emitted by the config builder as libghostty `macos-option-as-alt`.
    public static let optionAsAltKey = "controls.optionAsAlt"
    /// `mouse.rightClickAction` — what a bare right-click does in the viewport (stored
    /// ``RightClickAction`` rawValue, default `context-menu`).
    public static let rightClickActionKey = "controls.rightClickAction"
    /// undo-at-prompt — ⌘Z emits the readline undo (`0x1f`) when in the prompt zone (default ON).
    /// Read live by the libghostty surface's `keyDown` via ``PromptEditPolicy``.
    public static let undoAtPrompt = "controls.undoAtPrompt"
    /// `auto-secure-input` — automatically engage macOS Secure Keyboard Entry while the
    /// remote shell is at a no-echo (hidden-password) prompt (default ON; macOS-only). **The behaviour lives
    /// elsewhere.**
    public static let autoSecureInput = "controls.autoSecureInput"
    /// secure-input INDICATOR — show the `🛡 SECURE INPUT` pill while secure input is
    /// active (default ON; macOS-only). **The behaviour lives elsewhere.**
    public static let secureInputIndicator = "controls.secureInputIndicator"
    /// ⌃⇥ FOLLOW-ALONG PREVIEW — as the switcher's highlight walks, show that tab underneath it
    /// (default ON). Read at step time by ``WorkspaceStore/previewHighlightedTab()``.
    public static let tabSwitcherPreview = "controls.tabSwitcherPreview"

    // (terminal-features__notifications.md privilege surface — Settings → Advanced). Fire-time
    // flags, never folded into a typed prefs model → golden-safe. These gate what an OSC sequence from the
    // remote shell is allowed to do client-side.
    /// "Title — Shell Controlled" — allow apps to set the tab/window title via `OSC 0` / `OSC 2`
    /// (default ON). Read fire-time by ``TerminalViewModel`` at the `.title` event: OFF drops the title update.
    public static let titleShellControlled = "controls.titleShellControlled"
    /// "Clipboard — Shell Controlled" — the master switch for the whole `OSC 52` clipboard path (default
    /// ON). When OFF, ``TerminalControls/from(defaults:)`` resolves BOTH read + write to ``ClipboardAccess/deny``
    /// ahead of the per-direction gate, so the libghostty config emits `clipboard-read/write = deny`.
    public static let clipboardShellControlled = "controls.clipboardShellControlled"

    // (Path/link detection — Settings → Controls → Open With / Link Schemes). Fire-time flags, never
    // folded into a typed prefs model → golden-safe. Declared + persisted here so the Controls UI round-trips;
    // read fire-time (⌘-hold underline, click/context-menu dispatch, Jump-To, Hint Mode).
    // Naming: bool key = bare name (`…Enabled` accessor); enum-valued keys = `…Key` suffix (like
    // `rightClickActionKey`); list-valued keys = bare name (read via bridged accessors / `@Default`).
    /// `link-detection` — detect paths / URLs in terminal output and underline them on ⌘-hover (default
    /// ON). Turn OFF when a TUI's mouse reporting conflicts with the detection overlay.
    public static let linkDetection = "controls.linkDetection"
    /// `link-cmd-click` — what a ⌘click on a detected link does (stored ``LinkCmdClick`` rawValue,
    /// default `open`).
    public static let linkCmdClickKey = "controls.linkCmdClick" // LinkCmdClick.rawValue
    /// `link-cmd-shift-click` — what a ⌘⇧click on a detected link does (stored ``LinkCmdShiftClick``
    /// rawValue, default `reveal-finder`).
    public static let linkCmdShiftClickKey = "controls.linkCmdShiftClick" // LinkCmdShiftClick.rawValue
    /// "Auto-Detect Link Schemes" — which URL schemes are underlined / clickable (stored
    /// ``AutoDetectLinkSchemes`` rawValue, default `all`). `http(s)` / `file` / `mailto` are always detected.
    public static let autoDetectLinkSchemesKey = "controls.autoDetectLinkSchemes" // AutoDetectLinkSchemes.rawValue
    /// "Custom Link Schemes" — the extra `scheme`s detected when ``autoDetectLinkSchemes`` is `custom`
    /// (stored `[String]`, e.g. `codex`, `ssh`, `vscode`). Default empty. Read via ``linkSchemePolicy``.
    public static let customLinkSchemes = "controls.customLinkSchemes" // [String]
    /// hint-mode user patterns — extra regexes whose matches also get a hint label (stored
    /// `[String]`). Default empty. Declared here so the key round-trips; **the behaviour lives elsewhere.**
    public static let hintPatterns = "controls.hintPatterns" // [String]
    /// The parallel per-pattern action for each ``hintPatterns`` entry (stored `[String]`, e.g. `open` /
    /// `copy`). Default empty. **The behaviour lives elsewhere.**
    public static let hintPatternActions = "controls.hintPatternActions" // [String]
    // Features / advanced
    public static let autoSwitchLayouts = "features.autoSwitchLayouts"
    public static let redactSecrets = "features.redactSecrets"
    public static let recordClipboardHistory = "features.recordClipboardHistory"
    // The host-side auto-progress prefix list and the agent-control IPC guards used to carry CLIENT keys
    // here. They were removed: nothing serialised them into the env overlay or the `video-prefs.json`
    // sidecar, so the toggles wrote a value the host never read. The host still resolves
    // `SLOPDESK_AUTO_PROGRESS_COMMANDS` / `SLOPDESK_IPC_ALLOW_SEND_KEYS` / `SLOPDESK_IPC_ALLOW_SENSITIVE`,
    // and Settings → Advanced → Raw overrides DOES reach the sidecar — so that box is the honest editor.
    // Appearance / chrome
    /// The active ``DSDensity`` tier rawValue. Mirrors ``DSDensity/storageKey`` (the SAME `UserDefaults`
    /// key ``DSThemeStore`` reads at init + on a Settings change) so the picker, persistence, and the live
    /// `DSScale`/height tokens all agree on one source.
    public static let density = "appearance.density"
    // (terminal-features__progress-state.md "DOCK ICON" group). macOS-only NSDockTile behaviour;
    // the keys compile + round-trip on iOS, inert there (no Dock). Fire-time flags, never folded into a typed
    // prefs model → golden-safe.
    /// "Animate Dock Icon During Progress" (`dock-icon-animate-progress`) — animate the macOS Dock tile
    /// while ANY session reports an OSC 9;4 in-progress / indeterminate state (default OFF; macOS-only). Read
    /// by the macOS ``DockProgressController`` via the pure ``DockTintPolicy``.
    public static let dockIconAnimateProgress = "appearance.dockIconAnimateProgress"
    /// "Red Icon on Error" (`dock-icon-error-badge`) — tint the macOS Dock tile red when any session
    /// reports a non-zero exit / OSC 9;4;2 error; clicking the Dock jumps to the next failing tab + clears the
    /// tint (default ON; macOS-only). Read by the macOS ``DockProgressController`` via ``DockTintPolicy``.
    public static let dockIconErrorBadge = "appearance.dockIconErrorBadge"
    // Shell / window behaviour
    /// Where a new tab is inserted in the active session's tab bar (`new-tab-position`). Stored as the
    /// ``NewTabPosition`` rawValue (`auto`/`end`/`after-current`); default `.auto` (= append). Read at the ⌘T
    /// fire-site (`WorkspaceStore.newTab`). `Key` suffix frees the bare
    /// ``newTabPosition`` name for the typed accessor.
    public static let newTabPositionKey = "shell.newTabPosition" // NewTabPosition.rawValue

    /// When the vertical TABS panel (sidebar) is shown (`auto-hide-tabs-panel`). Stored as the
    /// ``AutoHideTabsPanelMode`` rawValue (`default`/`always`/`auto`); default `.default` (always shown). Only
    /// `.auto` auto-hides when the active session has a single tab — the decision lives in the pure
    /// ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)`` and the view-side glue drives
    /// ``WorkspaceChromeState/sidebarCollapsed`` from it. `Key` suffix frees the bare ``autoHideTabsPanel`` name.
    public static let autoHideTabsPanelKey = "shell.autoHideTabsPanel" // AutoHideTabsPanelMode.rawValue

    /// The working-directory policy for a NEW WINDOW (`working-directory`), default `home` — a fresh
    /// window opens at the shell's login cwd. Stored as the ``WorkingDirectoryPolicy/rawConfig`` string
    /// (`inherit` / `home` / an absolute path). Read at the new-window fire-site.
    public static let workingDirectoryNewWindowKey = "shell.workingDirectory.newWindow"
    /// The working-directory policy for a NEW TAB, default `inherit` — a ⌘T tab starts in the active pane's
    /// last-known cwd. Stored as the ``WorkingDirectoryPolicy/rawConfig`` string. Read at the ⌘T fire-site
    /// (`WorkspaceStore.newTab`).
    public static let workingDirectoryNewTabKey = "shell.workingDirectory.newTab"
    /// The working-directory policy for a NEW SPLIT, default `inherit` — a split starts in the active pane's
    /// last-known cwd. Stored as the ``WorkingDirectoryPolicy/rawConfig`` string. Read at the split fire-site
    /// (`WorkspaceStore.splitActivePane`).
    public static let workingDirectoryNewSplitKey = "shell.workingDirectory.newSplit"

    /// The close-confirmation policy for a TAB / PANE close (close-confirmation), default `process` —
    /// confirm only when a child process is running. Stored as the ``CloseConfirmationPolicy`` rawValue
    /// (`process` / `always` / `multiple_tabs`). Read at the tab/pane close fire-sites
    /// (`WorkspaceStore.requestClosePaneTree` / `requestCloseActivePaneTree` / `closeActiveTab`).
    public static let closeConfirmTabKey = "shell.closeConfirm.tab" // CloseConfirmationPolicy.rawValue
    /// The close-confirmation policy for a WINDOW close (mapped to the active ``Session`` — see
    /// `docs/DECISIONS.md`), default `process`. Stored as the ``CloseConfirmationPolicy`` rawValue. Read at
    /// the window-close fire-site (`WorkspaceStore.requestCloseWindow`).
    public static let closeConfirmWindowKey = "shell.closeConfirm.window" // CloseConfirmationPolicy.rawValue

    // (`window-size` — user-interface__window-tab-split.md). A `window.*` namespace, so a stale
    // read decode-fails to the key default per [[rwork-no-backcompat]] (no migration). CLIENT-side
    // initial-window-sizing: the macOS `NSWindow` glue reads them once per window open + resolves the
    // content size via ``WindowSizeMath``; iOS has no resizable window (keys compile + round-trip inert).
    // touchesWire:false — purely client view state.
    /// How a new window decides its initial dimensions (`window-size`). Stored as the ``WindowSizeMode``
    /// rawValue (`remember`/`grid`/`frame`); default `.remember` (restore the autosaved frame). `Key` suffix
    /// frees the bare ``windowSize`` name for the typed accessor.
    public static let windowSizeKey = "window.size" // WindowSizeMode.rawValue
    /// The column count for a new window when ``windowSize`` is ``WindowSizeMode/grid`` (`window-cols`),
    /// default `80`. Clamped into a sane band by ``WindowSizeMath/clampCols(_:)`` at the sizing fire-site.
    public static let windowColsKey = "window.cols"
    /// The row count for a new window when ``windowSize`` is ``WindowSizeMode/grid`` (`window-rows`),
    /// default `24`. Clamped by ``WindowSizeMath/clampRows(_:)`` at the sizing fire-site.
    public static let windowRowsKey = "window.rows"
    /// The width (px) for a new window when ``windowSize`` is ``WindowSizeMode/frame``
    /// (`window-width-px`), default `1000`. Clamped by ``WindowSizeMath/clampPx(_:)`` at the sizing fire-site.
    public static let windowWidthPxKey = "window.widthPx"
    /// The height (px) for a new window when ``windowSize`` is ``WindowSizeMode/frame``
    /// (`window-height-px`), default `600`. Clamped by ``WindowSizeMath/clampPx(_:)`` at the sizing fire-site.
    public static let windowHeightPxKey = "window.heightPx"
    /// The last window frame for ``WindowSizeMode/remember`` (`window.savedFrame`) — an
    /// `NSWindow.frameDescriptor` string the macOS glue writes on resize-end / move / quit and re-applies
    /// via `setFrame(from:)` once per window open. App-owned persistence (NOT `setFrameAutosaveName`):
    /// SwiftUI asserts its own type-derived autosave name on the scene window — a name containing a
    /// per-launch `(unknown context at $…)` address — so AppKit's autosave machinery saves under a key
    /// that changes every launch and can never restore. Default empty (a fresh install keeps the scene's
    /// `.defaultSize`).
    public static let windowSavedFrameKey = "window.savedFrame"
    /// How the dedicated remote-desktop window presents when it opens (`desktop-window`), default
    /// ``DesktopWindowPresentation/window``. Stored as the ``DesktopWindowPresentation`` rawValue
    /// (`window` / `fullscreen`). Read once per desktop-window open by the satellite-window glue
    /// (a `.fullscreen` value enters native fullscreen right after the window fronts).
    public static let desktopWindowPresentationKey = "desktopWindow.presentation"
    /// Whether SATELLITE windows (the dedicated remote desktop + ⌥⌘P pop-out panes) keep taking
    /// POINTER input while NOT key (`satellite-window`): hover/scroll/click forward to the host and a
    /// click leaves the window un-activated, so typing stays in the window the user is working in.
    /// Default ON. Read per render by the video-leaf seam (`GuiLeafView` → `RemotePaneContext`).
    public static let satelliteBackgroundPointerKey = "satelliteWindow.backgroundPointer"

    // (First-launch flow + Shell → SlopDesk CLI card — getting-started__first-launch.md). A
    // `firstLaunch.*` / `shell.cli.*` namespace, so a stale read decode-fails to the key default per
    // [[rwork-no-backcompat]] (no migration). Fire-time flags → golden-safe (client-side; touchesWire:false).
    // `hasCompletedFirstLaunch` gates the one-time guided sheet; the three `shell.cli.*` keys are the "Install
    // CLI" / "Omit Prefix" / "Allow Overwrite" toggles, displayed on macOS (the `/usr/local/bin` install is
    // `#if os(macOS)`).
    /// Whether the guided first-launch sheet has already run (first-launch). Default OFF — a fresh install
    /// presents the sheet exactly once; `FirstLaunchModel.finish()` flips it ON. Read at app launch via
    /// ``FirstLaunchModel/shouldPresent(hasCompleted:automationActive:)``.
    public static let hasCompletedFirstLaunch = "firstLaunch.completed"
    /// Whether the `slopdesk` CLI symlink (`/usr/local/bin/slopdesk`) is installed ("Install CLI").
    /// Default OFF. macOS-only behaviour (the symlink + admin escalation are `#if os(macOS)`); the key still
    /// compiles + round-trips on iOS, inert there.
    public static let cliInstalled = "shell.cli.installed"
    /// "Omit `slopdesk` Prefix" — expose `edit`/`view`/`watch`/`jump`/`learn` as bare shell functions in
    /// app-launched shells (default OFF). The functions wrap `slopdesk <name>`; see ``CLIShellShim``.
    public static let omitCLIPrefix = "shell.cli.omitPrefix"
    /// "Allow Overwrite" — whether the prefix-less shell functions overwrite an existing user-defined
    /// command of the same name (default OFF — only define a function when none already exists). See
    /// ``CLIShellShim``.
    public static let allowPrefixOverwrite = "shell.cli.allowPrefixOverwrite"

    /// Whether a layout with a trigger app auto-switches when that app launches on the host (default
    /// ON — assigning a trigger is itself the opt-in). Read at fire-time.
    public static var autoSwitchLayoutsEnabled: Bool { Defaults[.autoSwitchLayouts] }

    /// Whether explicit OSC 9/777 notifications should post (default ON). Read at fire-time.
    public static var oscNotificationsEnabled: Bool { Defaults[.oscNotifications] }

    /// Whether the long-command completion notification should post (default ON). Read at fire-time.
    public static var longCommandNotificationsEnabled: Bool { Defaults[.longCommandNotifications] }

    // MARK: Notification policy (fire-time accessors → the resolved `notificationSettings` bundle)

    /// "Notify on Command Finish" — fire when a command exits 0 (default OFF). Read at fire-time.
    public static var notifyOnFinishEnabled: Bool { Defaults[.notifyOnFinish] }

    /// "Notify on Error Exit" — fire when a command exits non-zero (default ON). Read at fire-time.
    public static var notifyOnErrorEnabled: Bool { Defaults[.notifyOnError] }

    /// "Notify on Watch Finish" — fire when an `slopdesk watch`-wrapped command finishes (default ON).
    public static var notifyOnWatchFinishEnabled: Bool { Defaults[.notifyOnWatchFinish] }

    /// "Notify While Foreground" — banner behaviour while the app is frontmost (default
    /// ``NotifyWhileForeground/off``). A stale / invalid persisted raw value repairs to `.off` via the
    /// `RawRepresentableBridge`. Read at fire-time.
    public static var notifyWhileForeground: NotifyWhileForeground { Defaults[.notifyWhileForeground] }

    /// "Bounce Dock Icon" — bounce the Dock when a notification arrives and the app is unfocused
    /// (default ON; macOS-only behaviour). Read at fire-time.
    public static var bounceDockIconEnabled: Bool { Defaults[.bounceDockIcon] }

    /// "Sound — Shell Controlled" — a `BEL` rings the system beep (default ON). Read at fire-time.
    public static var soundShellControlledEnabled: Bool { Defaults[.soundShellControlled] }

    /// "Sound on Error Exit" — beep when a command exits non-zero (default OFF). Read at fire-time.
    public static var soundOnErrorExitEnabled: Bool { Defaults[.soundOnErrorExit] }

    /// "Code Agent — Notify When Task Completes" (default ON; Claude-only). Read at fire-time.
    public static var agentNotifyTaskCompleteEnabled: Bool { Defaults[.agentNotifyTaskComplete] }

    /// "Code Agent — Notify When Awaiting Input" (default ON; Claude-only). Read at fire-time.
    public static var agentNotifyAwaitInputEnabled: Bool { Defaults[.agentNotifyAwaitInput] }

    // MARK: Agent badge gates (the global default the per-pane override falls back to)

    /// "Badge while processing" — show the running spinner badge (default ON; Claude-only). Read fire-time.
    public static var agentBadgeWhileProcessingEnabled: Bool { Defaults[.agentBadgeWhileProcessing] }

    /// "Badge when complete" — show the completed/finished badge (default ON; Claude-only). Read fire-time.
    public static var agentBadgeWhenCompleteEnabled: Bool { Defaults[.agentBadgeWhenComplete] }

    /// "Badge when awaiting input" — show the awaiting-input badge (default ON; Claude-only). Read fire-time.
    public static var agentBadgeWhenAwaitingInputEnabled: Bool { Defaults[.agentBadgeWhenAwaitingInput] }

    /// The resolved GLOBAL ``AgentBadgeGates`` the pure gating consumes — the ONE seam ``RailRowsBuilder`` reads
    /// (via ``WorkspaceStore/agentBadgeGates(for:)``, which prefers a per-pane override) so the three badge
    /// toggles are applied in exactly one place (mirrors ``notificationSettings`` / ``linkSchemePolicy``).
    public static var agentBadgeGates: AgentBadgeGates {
        AgentBadgeGates(
            badgeWhileProcessing: agentBadgeWhileProcessingEnabled,
            badgeWhenComplete: agentBadgeWhenCompleteEnabled,
            badgeWhenAwaitingInput: agentBadgeWhenAwaitingInputEnabled,
        )
    }

    // MARK: Progress cluster — command badge gates (Settings → Shell "TAB BADGE")

    /// "Tab Badge — When Command Finishes" — show the clean-exit badge (default ON). Read fire-time.
    public static var tabBadgeOnCommandFinishEnabled: Bool { Defaults[.tabBadgeOnCommandFinish] }

    /// "Tab Badge — When Command Fails" — show the error badge for a non-zero exit (default ON). Fire-time.
    public static var tabBadgeOnCommandFailEnabled: Bool { Defaults[.tabBadgeOnCommandFail] }

    /// "Tab Badge — When Command Awaits Input" — show the hand for a plain interactive prompt (default ON).
    /// Read fire-time. (The host detector that DRIVES the badge is deferred — see DECISIONS.md.)
    public static var tabBadgeOnCommandAwaitInputEnabled: Bool { Defaults[.tabBadgeOnCommandAwaitInput] }

    /// "Tab Badge — Busy Dot Delay": seconds a command must run before the busy dot shows (default 3;
    /// 0 = immediate). Read fire-time; a negative persisted value clamps to 0 (validate-then-default).
    public static var tabBadgeBusyDelaySecondsValue: Double {
        Double.maximum(Defaults[.tabBadgeBusyDelaySeconds], 0)
    }

    /// The resolved GLOBAL ``CommandBadgeGates`` the pure gating consumes — the ONE seam ``RailRowsBuilder`` /
    /// the control backend read alongside ``agentBadgeGates`` so the three COMMAND-badge toggles are applied in
    /// exactly one place. Command badges have no per-pane override (unlike the agent gates).
    public static var commandBadgeGates: CommandBadgeGates {
        CommandBadgeGates(
            whenCommandFinishes: tabBadgeOnCommandFinishEnabled,
            whenCommandFails: tabBadgeOnCommandFailEnabled,
            whenCommandAwaitsInput: tabBadgeOnCommandAwaitInputEnabled,
        )
    }

    /// The resolved ``NotificationSettings`` bundle the pure ``NotificationPolicy`` consumes — the ONE seam
    /// the macOS poster (``CommandCompletionNotifier``) reads so the notification toggles are applied in
    /// exactly one place (mirrors ``linkSchemePolicy``). The master "Allow App Notifications" maps onto the
    /// existing ``oscNotifications`` key.
    public static var notificationSettings: NotificationSettings {
        NotificationSettings(
            appNotificationsEnabled: oscNotificationsEnabled,
            notifyOnFinish: notifyOnFinishEnabled,
            notifyOnError: notifyOnErrorEnabled,
            notifyOnWatchFinish: notifyOnWatchFinishEnabled,
            notifyWhileForeground: notifyWhileForeground,
            agentNotifyTaskComplete: agentNotifyTaskCompleteEnabled,
            agentNotifyAwaitInput: agentNotifyAwaitInputEnabled,
        )
    }

    /// Whether to mask likely secrets (access keys, bearer tokens, `PASSWORD=…`) out of window titles and
    /// notification bodies before they reach the sidebar/pill/Notification Center (default ON — security
    /// by default; the escape hatch is for someone who genuinely wants raw titles). Read at fire-time.
    public static var redactSecretsEnabled: Bool { Defaults[.redactSecrets] }

    /// Whether the ⌃⇥ switcher shows each tab as its highlight walks over it, instead of revealing the
    /// choice only on release (default ON — a switcher you can SEE through is the point of holding the
    /// key). OFF is a legitimate mode, not a broken product: the preview flips a video pane's
    /// UDP/VT/Metal pipeline on and off as the walk passes, and some people simply want the workspace to
    /// hold still. Read at step time, so a change applies to the next gesture.
    public static var tabSwitcherPreviewEnabled: Bool { Defaults[.tabSwitcherPreview] }

    /// Whether copied text is archived into the clipboard-history ring that backs the pill's "Paste Recent"
    /// submenu (default ON). OFF stops the monitor retaining any copied string — the privacy escape hatch for
    /// someone who copies secrets into sudo/SSH prompts. Read at fire-time (applies live); existing entries are
    /// cleared from the pill's "Clear History".
    public static var recordClipboardHistoryEnabled: Bool { Defaults[.recordClipboardHistory] }

    /// Whether the macOS Dock tile animates during OSC 9;4 progress (`dock-icon-animate-progress`),
    /// default OFF (macOS-only; inert on iOS). Read fire-time by ``DockProgressController`` via ``DockTintPolicy``.
    public static var dockIconAnimateProgressEnabled: Bool { Defaults[.dockIconAnimateProgress] }

    /// Whether the macOS Dock tile tints red on a non-zero exit / OSC 9;4;2 error (`dock-icon-error-badge`),
    /// default ON (macOS-only; inert on iOS). Read fire-time by ``DockProgressController`` via ``DockTintPolicy``.
    public static var dockIconErrorBadgeEnabled: Bool { Defaults[.dockIconErrorBadge] }

    /// Where a new tab opens in the active session's tab bar (`new-tab-position`), default `.auto`
    /// (= append, matching the original behaviour before this setting existed). A stale / invalid persisted
    /// raw value falls back to `.auto` via the `RawRepresentableBridge`. Read at the ⌘T fire-site.
    public static var newTabPosition: NewTabPosition { Defaults[.newTabPosition] }

    /// When the vertical TABS panel is shown (`auto-hide-tabs-panel`), default
    /// ``AutoHideTabsPanelMode/default`` (always shown). A stale / invalid persisted raw value repairs to
    /// `.default` via the `RawRepresentableBridge`. Read by the view-side auto-hide glue, which feeds it
    /// to ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)``.
    public static var autoHideTabsPanel: AutoHideTabsPanelMode { Defaults[.autoHideTabsPanel] }

    /// The working-directory policy applied when a NEW WINDOW opens (`working-directory`), default
    /// ``WorkingDirectoryPolicy/home``. Decoded from the persisted ``WorkingDirectoryPolicy/rawConfig``
    /// string (an empty / unknown value repairs to `.home`). Read at fire-time.
    public static var workingDirectoryNewWindow: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: Defaults[.workingDirectoryNewWindow])
    }

    /// The working-directory policy applied when a NEW TAB opens, default ``WorkingDirectoryPolicy/inherit``
    /// (the ⌘T tab starts in the active pane's last-known cwd). Read at the ⌘T fire-site.
    public static var workingDirectoryNewTab: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: Defaults[.workingDirectoryNewTab])
    }

    /// The working-directory policy applied when a NEW SPLIT opens, default
    /// ``WorkingDirectoryPolicy/inherit``. Read at the split fire-site.
    public static var workingDirectoryNewSplit: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: Defaults[.workingDirectoryNewSplit])
    }

    /// The close-confirmation policy applied to a TAB / PANE close (close-confirmation), default
    /// ``CloseConfirmationPolicy/process``. A stale / invalid persisted raw value repairs to `.process` (via
    /// ``CloseConfirmationPolicy/init(rawValue:)`` + the `RawRepresentableBridge`). Read at fire-time.
    public static var closeConfirmTab: CloseConfirmationPolicy { Defaults[.closeConfirmTab] }

    /// The close-confirmation policy applied to a WINDOW close (mapped to the active ``Session`` — see
    /// `docs/DECISIONS.md`), default ``CloseConfirmationPolicy/process``. Read at fire-time.
    public static var closeConfirmWindow: CloseConfirmationPolicy { Defaults[.closeConfirmWindow] }

    /// The `On Launch` behaviour applied when the app opens, default
    /// ``OnLaunchBehavior/restoreLastSession`` (the existing launch behaviour — the store already restores
    /// the persisted tree). A stale / invalid persisted raw value repairs to `.restoreLastSession` (via the
    /// policy's own non-failable ``OnLaunchBehavior/init(rawValue:)`` + the `RawRepresentableBridge`). Read
    /// by the app-launch path via ``WorkspacePersistence/launchTree(behavior:persistence:)`` (a `.newWindow`
    /// value seeds a fresh single-pane session instead of restoring the persisted tree).
    public static var onLaunch: OnLaunchBehavior { Defaults[.onLaunch] }

    // MARK: window-size (`window-size` — read once per window open by the macOS NSWindow glue)

    /// How a new window decides its initial dimensions (`window-size`), default
    /// ``WindowSizeMode/remember`` (restore the autosaved frame). A stale / invalid persisted raw value
    /// repairs to `.remember` via the `RawRepresentableBridge`. Read by the macOS `NSWindow` glue,
    /// which resolves the content size through ``WindowSizeMath/resolvedContentSize(mode:cols:rows:widthPx:heightPx:cell:visible:chromeInsets:)``.
    public static var windowSize: WindowSizeMode { Defaults[.windowSize] }

    /// The persisted `grid`-mode column count (`window-cols`), default `80`. The RAW value — the
    /// sizing math clamps it via ``WindowSizeMath/clampCols(_:)``.
    public static var windowCols: Int { Defaults[.windowCols] }

    /// The persisted `grid`-mode row count (`window-rows`), default `24`. The RAW value — clamped by
    /// ``WindowSizeMath/clampRows(_:)``.
    public static var windowRows: Int { Defaults[.windowRows] }

    /// The persisted `frame`-mode width in px (`window-width-px`), default `1000`. The RAW value —
    /// clamped by ``WindowSizeMath/clampPx(_:)``.
    public static var windowWidthPx: Int { Defaults[.windowWidthPx] }

    /// The persisted `frame`-mode height in px (`window-height-px`), default `600`. The RAW value —
    /// clamped by ``WindowSizeMath/clampPx(_:)``.
    public static var windowHeightPx: Int { Defaults[.windowHeightPx] }

    /// The persisted `remember`-mode frame descriptor (`window.savedFrame`), default empty (no frame
    /// saved yet — the scene's `.defaultSize` stands). Settable: the macOS glue WRITES it on
    /// resize-end / move / quit and re-applies it via `NSWindow.setFrame(from:)` once per window open
    /// (see ``windowSavedFrameKey`` for why AppKit's autosave machinery cannot own this).
    public static var savedWindowFrame: String {
        get { Defaults[.savedWindowFrame] }
        set { Defaults[.savedWindowFrame] = newValue }
    }

    /// How the dedicated remote-desktop window presents when it opens (`desktop-window`), default
    /// ``DesktopWindowPresentation/window``. A stale / invalid persisted raw value repairs to
    /// `.window` via the `RawRepresentableBridge`. Read once per desktop-window open by the macOS
    /// satellite-window glue.
    public static var desktopWindowPresentation: DesktopWindowPresentation {
        Defaults[.desktopWindowPresentation]
    }

    /// Whether satellite windows keep taking pointer input while not key (`satellite-window`),
    /// default ON. Read per render by the video-leaf seam.
    public static var satelliteBackgroundPointerEnabled: Bool { Defaults[.satelliteBackgroundPointer] }

    // MARK: First-launch + SlopDesk CLI (getting-started__first-launch.md)

    /// Whether the guided first-launch sheet has already run (first-launch), default OFF. Read at app
    /// launch; the sheet presents only when this is OFF (and no automation env is set).
    public static var hasCompletedFirstLaunchEnabled: Bool { Defaults[.hasCompletedFirstLaunch] }

    /// Whether the `slopdesk` CLI symlink is installed ("Install CLI"), default OFF. macOS-only
    /// behaviour; inert on iOS. Read fire-time by the Shell CLI card + the first-launch Install-CLI step.
    public static var cliInstalledEnabled: Bool { Defaults[.cliInstalled] }

    /// Whether the prefix-less shell functions are exposed in app-launched shells ("Omit Prefix"),
    /// default OFF. Read fire-time by the shell-shim injection path (``CLIShellShim``).
    public static var omitCLIPrefixEnabled: Bool { Defaults[.omitCLIPrefix] }

    /// Whether the prefix-less functions overwrite an existing same-named command ("Allow Overwrite"),
    /// default OFF. Read fire-time by ``CLIShellShim/snippet(allowOverwrite:binary:)``.
    public static var allowPrefixOverwriteEnabled: Bool { Defaults[.allowPrefixOverwrite] }

    // MARK: Controls / scroll / copy (behaviour lives elsewhere — declared + persisted here)

    /// Whether the selection is copied to the pasteboard as soon as it is made (`copy-on-select`),
    /// default OFF. **The behaviour lives elsewhere**; declared + persisted here so the Controls picker
    /// round-trips.
    public static var copyOnSelectEnabled: Bool { Defaults[.copyOnSelect] }

    /// Whether trailing whitespace is trimmed from each copied line (`clipboard-trim-trailing-spaces`),
    /// default ON. **The behaviour lives elsewhere.**
    public static var trimTrailingSpacesOnCopyEnabled: Bool { Defaults[.trimTrailingSpacesOnCopy] }

    /// Whether pasting text with a newline / control char prompts a confirmation
    /// (`clipboard-paste-protection`), default ON. **The behaviour lives elsewhere.**
    public static var pasteProtectionEnabled: Bool { Defaults[.pasteProtection] }

    /// Whether the mouse pointer hides while typing (`mouse-hide-while-typing`), default ON. **The behaviour
    /// lives elsewhere.**
    public static var mouseHideWhileTypingEnabled: Bool { Defaults[.mouseHideWhileTyping] }

    /// Whether focus follows the mouse pointer without a click (`focus-follows-mouse`), default OFF. Read
    /// fire-time by the libghostty surface's `mouseMoved` via ``FocusFollowsMousePolicy``.
    public static var focusFollowsMouseEnabled: Bool { Defaults[.focusFollowsMouse] }

    /// The scroll-wheel delta multiplier (`mouse-scroll-multiplier`), default `1.0`. **The behaviour lives
    /// elsewhere.**
    public static var scrollMultiplierValue: Double { Defaults[.scrollMultiplier] }

    // MARK: The remaining Controls / Mouse / Scroll knobs (fire-time accessors)

    /// Whether the selection clears when the user types (`selection-clear-on-typing`), default ON.
    public static var clearSelectionOnTypingEnabled: Bool { Defaults[.clearSelectionOnTyping] }

    /// Whether the selection clears after an explicit copy (`selection-clear-on-copy`), default OFF.
    public static var clearSelectionOnCopyEnabled: Bool { Defaults[.clearSelectionOnCopy] }

    /// Whether ⇧+arrows drive native selection ("Shift+Arrow Select"), default ON.
    public static var shiftArrowSelectEnabled: Bool { Defaults[.shiftArrowSelect] }

    /// Whether a bracketed paste is treated as safe (`clipboard-paste-bracketed-safe`), default ON.
    public static var pasteBracketedSafeEnabled: Bool { Defaults[.pasteBracketedSafe] }

    /// Whether programs may capture mouse events (`mouse-reporting`, Allow Mouse Capture), default ON.
    public static var allowMouseCaptureEnabled: Bool { Defaults[.allowMouseCapture] }

    /// Whether clicking in the prompt moves the shell cursor (`cursor-click-to-move`), default ON.
    public static var clickToMoveEnabled: Bool { Defaults[.clickToMove] }

    /// Whether ⌘Z at the prompt emits the readline undo (undo-at-prompt), default ON. Read fire-time by
    /// the libghostty surface's `keyDown` via ``PromptEditPolicy``.
    public static var undoAtPromptEnabled: Bool { Defaults[.undoAtPrompt] }

    /// Whether macOS Secure Keyboard Entry engages AUTOMATICALLY on a host no-echo password prompt
    /// (`auto-secure-input`), default ON. Read fire-time by ``SecureKeyboardEntryController`` +
    /// ``TerminalViewModel/secureInputActive``. macOS-only behaviour (the controller is inert off macOS).
    public static var autoSecureInputEnabled: Bool { Defaults[.autoSecureInput] }

    /// Whether the `🛡 SECURE INPUT` pill is shown while secure input is active (secure-input indicator),
    /// default ON. Read fire-time by the leaf's pill gate. macOS-only (the pill never lights
    /// on iOS — ``TerminalViewModel/secureInputActive`` is always `false` there).
    public static var secureInputIndicatorEnabled: Bool { Defaults[.secureInputIndicator] }

    /// The OSC-52 clipboard-WRITE access gate (`clipboard-write`), default ``ClipboardAccess/allow``.
    /// A stale / invalid persisted raw value repairs to `.allow` via the `RawRepresentableBridge`.
    public static var clipboardWrite: ClipboardAccess { Defaults[.clipboardWrite] }

    /// The OSC-52 clipboard-READ access gate (`clipboard-read`), default ``ClipboardAccess/ask``.
    /// A stale / invalid persisted raw value repairs to `.ask` via the `RawRepresentableBridge`.
    public static var clipboardRead: ClipboardAccess { Defaults[.clipboardRead] }

    // MARK: Privilege surface (title + OSC-52 master switch)

    /// "Title — Shell Controlled" — whether a remote `OSC 0` / `OSC 2` may set the tab/window title
    /// (default ON). Read fire-time by ``TerminalViewModel`` at the `.title` event (OFF drops the update).
    public static var titleShellControlledEnabled: Bool { Defaults[.titleShellControlled] }

    /// "Clipboard — Shell Controlled" — the master switch gating the whole `OSC 52` path (default ON).
    /// When OFF, ``TerminalControls/from(defaults:)`` resolves read + write to ``ClipboardAccess/deny``.
    public static var clipboardShellControlledEnabled: Bool { Defaults[.clipboardShellControlled] }

    /// Whether ⇧ bypasses a program's mouse capture (`mouse-shift-capture`, Allow Shift with Mouse
    /// Click), default ``MouseShiftCapture/enabled``. A stale / invalid raw value repairs to `.enabled`.
    public static var allowShiftClick: MouseShiftCapture { Defaults[.allowShiftClick] }

    /// What a bare right-click does in the viewport (`mouse.rightClickAction`), default
    /// ``RightClickAction/contextMenu``. A stale / invalid raw value repairs to `.contextMenu`.
    public static var rightClickAction: RightClickAction { Defaults[.rightClickAction] }

    /// How the macOS Option key is treated ("Option as Alt", libghostty `macos-option-as-alt`), default
    /// ``OptionAsAlt/off``. A stale / invalid raw value repairs to `.off`.
    public static var optionAsAlt: OptionAsAlt { Defaults[.optionAsAlt] }

    // MARK: Link interaction (declared + persisted here; the behaviour lives elsewhere)

    /// Whether path / URL link detection is on (`link-detection`), default ON. Read fire-time by the
    /// ⌘-hold underline overlay + the click / context-menu / Jump-To / Hint paths.
    public static var linkDetectionEnabled: Bool { Defaults[.linkDetection] }

    /// What a ⌘click on a detected link does (`link-cmd-click`), default ``LinkCmdClick/open``. A stale /
    /// invalid persisted raw value repairs to `.open` via the `RawRepresentableBridge`.
    public static var linkCmdClick: LinkCmdClick { Defaults[.linkCmdClick] }

    /// What a ⌘⇧click on a detected link does (`link-cmd-shift-click`), default
    /// ``LinkCmdShiftClick/revealFinder``. A stale / invalid raw value repairs to `.revealFinder`.
    public static var linkCmdShiftClick: LinkCmdShiftClick { Defaults[.linkCmdShiftClick] }

    /// Which URL schemes are auto-detected ("Auto-Detect Link Schemes"), default
    /// ``AutoDetectLinkSchemes/all``. A stale / invalid raw value repairs to `.all`.
    public static var autoDetectLinkSchemes: AutoDetectLinkSchemes { Defaults[.autoDetectLinkSchemes] }

    /// The resolved ``LinkSchemePolicy`` the detector consumes — bridges the persisted mode + custom list
    /// into the detector's richer policy (`.all` ⇒ detect any scheme; `.custom` ⇒ the always-on schemes plus
    /// the user list). The ONE seam the ⌘-hold underline / Jump-To / Hint Mode read so the scheme setting is
    /// applied in exactly one place.
    public static var linkSchemePolicy: LinkSchemePolicy {
        switch autoDetectLinkSchemes {
        case .all: .all
        case .custom: .custom(Defaults[.customLinkSchemes])
        }
    }

    /// The resolved user Hint Mode patterns — zips the persisted parallel `hint-pattern` /
    /// `hint-pattern-action` lists into ``HintPattern`` values the assigner consumes. A pattern with no
    /// paired action (the actions list is shorter) carries `nil`; an empty pattern string is dropped. The ONE
    /// seam Hint Mode reads, so the pattern config is applied in exactly one place (mirrors ``linkSchemePolicy``).
    public static var hintPatternList: [HintPattern] {
        let patterns = Defaults[.hintPatterns]
        let actions = Defaults[.hintPatternActions]
        return patterns.enumerated().compactMap { index, regex in
            guard !regex.isEmpty else { return nil }
            let action = index < actions.count && !actions[index].isEmpty ? actions[index] : nil
            return HintPattern(regex: regex, action: action)
        }
    }
}

/// The suites ``SettingsKey/removeSuiteAtExit(named:)`` takes away on the way out, and the lock over
/// them. File-scope for the same reason as everything else here: the `atexit` hook is a
/// non-capturing C function pointer and can reach nothing but a global.
/// `nonisolated(unsafe)`: every access goes through `suiteRemovalLock`.
private nonisolated(unsafe) var pendingSuiteRemovals: [String] = []
private nonisolated(unsafe) var suiteRemovalHookInstalled = false
private let suiteRemovalLock = NSLock()

/// Non-nil exactly when running under XCTest — file-scope (not a `SettingsKey` member) so the
/// non-capturing `atexit` C hook inside ``SettingsKey/store`` can reference it as a global.
private let testProcessSuiteName: String? =
    NSClassFromString("XCTestCase") == nil
        ? nil
        : "slopdesk.tests.pid\(ProcessInfo.processInfo.processIdentifier)"

/// The suite ``SettingsKey/store`` actually binds. Same file-scope reason as above: the `atexit`
/// hook is a non-capturing C function pointer and can only reach a global.
private let resolvedSuiteName: String? = SettingsKey.suiteName(
    testProcessSuite: testProcessSuiteName,
    environment: ProcessInfo.processInfo.environment,
)

private extension Defaults.Key {
    /// Builds every SlopDesk global-flag key against ``SettingsKey/store`` (`.standard` in the app;
    /// a per-process wiped suite under XCTest) so no key can silently bind a different suite.
    convenience init(slopDesk name: String, default defaultValue: Value) {
        self.init(name, default: defaultValue, suite: SettingsKey.store)
    }
}

// MARK: - Typed Defaults keys (the single source the accessors + `@Default(.key)` views read)

/// The typed ``Defaults`` keys for the global app-flag namespace. Names reuse the ``SettingsKey`` string
/// constants so the wire strings stay the one source of truth (pinned by `SettingsKeyTests`, shared with
/// every `@Default`/`@AppStorage` consumer). All ``SettingsKey/store``-backed (`.standard` in the app; a
/// per-process suite under XCTest) — the per-instance-injectable ``PreferencesStore`` deliberately stays
/// on its own `UserDefaults`, not these.
public extension Defaults.Keys {
    static let oscNotifications = Key<Bool>(slopDesk: SettingsKey.oscNotifications, default: true)
    static let longCommandNotifications = Key<Bool>(slopDesk: SettingsKey.longCommandNotifications, default: true)
    // Notification policy (notification-setting.png). Fire-time flags → golden-safe. The enum-valued
    // `notifyWhileForeground` stores the bare rawValue via the `RawRepresentableBridge` (repairing a stale
    // value to `.off`).
    static let notifyOnFinish = Key<Bool>(slopDesk: SettingsKey.notifyOnFinish, default: false)
    static let notifyOnError = Key<Bool>(slopDesk: SettingsKey.notifyOnError, default: true)
    static let notifyOnWatchFinish = Key<Bool>(slopDesk: SettingsKey.notifyOnWatchFinish, default: true)
    static let notifyWhileForeground = Key<NotifyWhileForeground>(
        slopDesk: SettingsKey.notifyWhileForegroundKey,
        default: .off,
    )
    static let bounceDockIcon = Key<Bool>(slopDesk: SettingsKey.bounceDockIcon, default: true)
    static let soundShellControlled = Key<Bool>(slopDesk: SettingsKey.soundShellControlled, default: true)
    static let soundOnErrorExit = Key<Bool>(slopDesk: SettingsKey.soundOnErrorExit, default: false)
    static let agentNotifyTaskComplete = Key<Bool>(slopDesk: SettingsKey.agentNotifyTaskComplete, default: true)
    static let agentNotifyAwaitInput = Key<Bool>(slopDesk: SettingsKey.agentNotifyAwaitInput, default: true)
    // Agent badge gates (agents__agents-overview.md "Agent Behaviour"). Fire-time flags → golden-safe.
    // Consumed via `SettingsKey.agentBadgeGates` → `TabBadgeGating.resolve`. `whileProcessing` defaults OFF
    // (progress-state.md "Claude Code — While Processing (off by default)"); the other two default ON.
    static let agentBadgeWhileProcessing = Key<Bool>(slopDesk: SettingsKey.agentBadgeWhileProcessing, default: false)
    static let agentBadgeWhenComplete = Key<Bool>(slopDesk: SettingsKey.agentBadgeWhenComplete, default: true)
    static let agentBadgeWhenAwaitingInput = Key<Bool>(slopDesk: SettingsKey.agentBadgeWhenAwaitingInput, default: true)
    // Progress cluster (progress-state.md — Settings → Shell "TAB BADGE"). The three COMMAND-driven badge
    // toggles, DISTINCT from the agent set above. Fire-time flags → golden-safe. All default ON. Consumed via
    // `SettingsKey.commandBadgeGates` → `TabBadgeGating.resolve`.
    static let tabBadgeOnCommandFinish = Key<Bool>(slopDesk: SettingsKey.tabBadgeOnCommandFinish, default: true)
    static let tabBadgeOnCommandFail = Key<Bool>(slopDesk: SettingsKey.tabBadgeOnCommandFail, default: true)
    static let tabBadgeOnCommandAwaitInput = Key<Bool>(slopDesk: SettingsKey.tabBadgeOnCommandAwaitInput, default: true)
    static let tabBadgeBusyDelaySeconds = Key<Double>(slopDesk: SettingsKey.tabBadgeBusyDelaySeconds, default: 1)
    static let autoSwitchLayouts = Key<Bool>(slopDesk: SettingsKey.autoSwitchLayouts, default: true)
    static let redactSecrets = Key<Bool>(slopDesk: SettingsKey.redactSecrets, default: true)
    static let tabSwitcherPreview = Key<Bool>(slopDesk: SettingsKey.tabSwitcherPreview, default: true)
    static let recordClipboardHistory = Key<Bool>(slopDesk: SettingsKey.recordClipboardHistory, default: true)
    // Dock-icon toggles (macOS-only NSDockTile; the keys compile + round-trip on iOS, inert there).
    // Fire-time flags, never folded into a typed prefs model → golden-safe. Animate default OFF, error-tint ON.
    static let dockIconAnimateProgress = Key<Bool>(slopDesk: SettingsKey.dockIconAnimateProgress, default: false)
    static let dockIconErrorBadge = Key<Bool>(slopDesk: SettingsKey.dockIconErrorBadge, default: true)
    static let newTabPosition = Key<NewTabPosition>(slopDesk: SettingsKey.newTabPositionKey, default: .auto)
    // Vertical-sidebar auto-hide (`auto-hide-tabs-panel`). Stores the bare `AutoHideTabsPanelMode`
    // rawValue via the `RawRepresentableBridge` (the `PreferRawRepresentable` conformance below), repairing a
    // stale value to `.default`. Default `.default` (always shown — matching the original sidebar behaviour).
    static let autoHideTabsPanel = Key<AutoHideTabsPanelMode>(
        slopDesk: SettingsKey.autoHideTabsPanelKey,
        default: .default,
    )
    // Working-directory policies stored as the `WorkingDirectoryPolicy.rawConfig` String (config value).
    // New window defaults to `home` (login cwd); new tab / split default to `inherit` (active pane's cwd).
    static let workingDirectoryNewWindow = Key<String>(
        slopDesk: SettingsKey.workingDirectoryNewWindowKey,
        default: "home",
    )
    static let workingDirectoryNewTab = Key<String>(slopDesk: SettingsKey.workingDirectoryNewTabKey, default: "inherit")
    static let workingDirectoryNewSplit = Key<String>(
        slopDesk: SettingsKey.workingDirectoryNewSplitKey,
        default: "inherit",
    )
    // Close-confirmation policies stored as the `CloseConfirmationPolicy` rawValue (config value). Both
    // default to `process` (confirm only on a running child process — the original busy-shell guard).
    static let closeConfirmTab = Key<CloseConfirmationPolicy>(
        slopDesk: SettingsKey.closeConfirmTabKey,
        default: .process,
    )
    static let closeConfirmWindow = Key<CloseConfirmationPolicy>(
        slopDesk: SettingsKey.closeConfirmWindowKey,
        default: .process,
    )
    // On-Launch behaviour stored as the `OnLaunchBehavior` rawValue (`On Launch`); default
    // `.restoreLastSession` (the existing launch behaviour — the store already restores the persisted tree).
    static let onLaunch = Key<OnLaunchBehavior>(slopDesk: SettingsKey.onLaunchKey, default: .restoreLastSession)
    // window-size (`window-size`). A `window.*` namespace, CLIENT-side only (touchesWire:false).
    // The mode stores the bare `WindowSizeMode` rawValue via the `RawRepresentableBridge` (the
    // `PreferRawRepresentable` conformance below), repairing a stale value to `.remember`; the cols/rows/px
    // are native `Int`s. Defaults mirror the config values (80×24 grid, 1000×600 frame).
    static let windowSize = Key<WindowSizeMode>(slopDesk: SettingsKey.windowSizeKey, default: .remember)
    static let windowCols = Key<Int>(slopDesk: SettingsKey.windowColsKey, default: 80)
    static let windowRows = Key<Int>(slopDesk: SettingsKey.windowRowsKey, default: 24)
    static let windowWidthPx = Key<Int>(slopDesk: SettingsKey.windowWidthPxKey, default: 1000)
    static let windowHeightPx = Key<Int>(slopDesk: SettingsKey.windowHeightPxKey, default: 600)
    // `remember`-mode frame descriptor — a native `String` (`NSWindow.frameDescriptor`); empty = none saved.
    static let savedWindowFrame = Key<String>(slopDesk: SettingsKey.windowSavedFrameKey, default: "")
    // Desktop-window presentation stored as the `DesktopWindowPresentation` rawValue (`desktop-window`);
    // default `.window` (regular titled window — fullscreen is the Parsec-style opt-in).
    static let desktopWindowPresentation = Key<DesktopWindowPresentation>(
        slopDesk: SettingsKey.desktopWindowPresentationKey,
        default: .window,
    )
    // Satellite background-pointer interaction (`satellite-window`); default ON — the dedicated
    // desktop window stays pointer-operable while another window holds the keyboard.
    static let satelliteBackgroundPointer = Key<Bool>(
        slopDesk: SettingsKey.satelliteBackgroundPointerKey,
        default: true,
    )
    // First-launch + SlopDesk CLI (getting-started__first-launch.md). Fire-time flags → golden-safe;
    // client-side. `hasCompletedFirstLaunch` gates the one-time sheet (default OFF — present once on a fresh
    // install); the three `shell.cli.*` toggles default OFF (CLI opt-in, prefix-less functions opt-in, never
    // clobber a user command unless Allow Overwrite is on). macOS surfaces the install toggles; inert on iOS.
    static let hasCompletedFirstLaunch = Key<Bool>(slopDesk: SettingsKey.hasCompletedFirstLaunch, default: false)
    static let cliInstalled = Key<Bool>(slopDesk: SettingsKey.cliInstalled, default: false)
    static let omitCLIPrefix = Key<Bool>(slopDesk: SettingsKey.omitCLIPrefix, default: false)
    static let allowPrefixOverwrite = Key<Bool>(slopDesk: SettingsKey.allowPrefixOverwrite, default: false)
    // Controls / scroll / copy (Controls). FIRE-TIME flags only — never folded into a typed prefs model → never
    // reach the env overlay / sidecar → golden-safe. The behaviour lives elsewhere; these persist + round-trip
    // today.
    static let copyOnSelect = Key<Bool>(slopDesk: SettingsKey.copyOnSelect, default: false)
    static let trimTrailingSpacesOnCopy = Key<Bool>(slopDesk: SettingsKey.trimTrailingSpacesOnCopy, default: true)
    static let pasteProtection = Key<Bool>(slopDesk: SettingsKey.pasteProtection, default: true)
    static let mouseHideWhileTyping = Key<Bool>(slopDesk: SettingsKey.mouseHideWhileTyping, default: true)
    static let focusFollowsMouse = Key<Bool>(slopDesk: SettingsKey.focusFollowsMouse, default: false)
    static let scrollMultiplier = Key<Double>(slopDesk: SettingsKey.scrollMultiplier, default: 1.0)
    // The remaining Controls / Mouse / Scroll knobs. Same fire-time-only discipline → golden-safe. The
    // enum-valued keys store the bare enum rawValue via the `RawRepresentableBridge` (the
    // `Defaults.PreferRawRepresentable` conformances below), repairing a stale value to the default like
    // `closeConfirmTab` / `onLaunch`.
    static let clearSelectionOnTyping = Key<Bool>(slopDesk: SettingsKey.clearSelectionOnTyping, default: true)
    static let clearSelectionOnCopy = Key<Bool>(slopDesk: SettingsKey.clearSelectionOnCopy, default: false)
    static let shiftArrowSelect = Key<Bool>(slopDesk: SettingsKey.shiftArrowSelect, default: true)
    static let pasteBracketedSafe = Key<Bool>(slopDesk: SettingsKey.pasteBracketedSafe, default: true)
    static let allowMouseCapture = Key<Bool>(slopDesk: SettingsKey.allowMouseCapture, default: true)
    static let clickToMove = Key<Bool>(slopDesk: SettingsKey.clickToMove, default: true)
    static let undoAtPrompt = Key<Bool>(slopDesk: SettingsKey.undoAtPrompt, default: true)
    // Secure input — both default ON (macOS-only behaviour; the keys still compile +
    // round-trip on iOS, where the feature is inert). Fire-time flags, never folded into the env overlay.
    static let autoSecureInput = Key<Bool>(slopDesk: SettingsKey.autoSecureInput, default: true)
    static let secureInputIndicator = Key<Bool>(slopDesk: SettingsKey.secureInputIndicator, default: true)
    static let clipboardWrite = Key<ClipboardAccess>(slopDesk: SettingsKey.clipboardWriteKey, default: .allow)
    static let clipboardRead = Key<ClipboardAccess>(slopDesk: SettingsKey.clipboardReadKey, default: .ask)
    // Privilege surface (terminal-features__notifications.md → Settings → Advanced). Fire-time
    // flags, never folded into a typed prefs model → golden-safe. Title — Shell Controlled + Clipboard —
    // Shell Controlled default ON; Title Report defaults OFF (the conservative exfiltration-safe default, and
    // it cannot yet actuate — see docs/DECISIONS.md).
    static let titleShellControlled = Key<Bool>(slopDesk: SettingsKey.titleShellControlled, default: true)
    static let clipboardShellControlled = Key<Bool>(slopDesk: SettingsKey.clipboardShellControlled, default: true)
    static let allowShiftClick = Key<MouseShiftCapture>(slopDesk: SettingsKey.allowShiftClickKey, default: .enabled)
    static let rightClickAction = Key<RightClickAction>(
        slopDesk: SettingsKey.rightClickActionKey,
        default: .contextMenu,
    )
    static let optionAsAlt = Key<OptionAsAlt>(slopDesk: SettingsKey.optionAsAltKey, default: .off)
    // (Path/link detection — Settings → Controls → Open With / Link Schemes). Fire-time flags, never
    // folded into a typed prefs model → golden-safe. The enum keys store the bare enum rawValue via the
    // `RawRepresentableBridge` (repairing a stale value to the default exactly like `rightClickAction`); the
    // list keys store a native `[String]` (like `customLinkSchemes`).
    static let linkDetection = Key<Bool>(slopDesk: SettingsKey.linkDetection, default: true)
    static let linkCmdClick = Key<LinkCmdClick>(slopDesk: SettingsKey.linkCmdClickKey, default: .open)
    static let linkCmdShiftClick = Key<LinkCmdShiftClick>(
        slopDesk: SettingsKey.linkCmdShiftClickKey,
        default: .revealFinder,
    )
    static let autoDetectLinkSchemes = Key<AutoDetectLinkSchemes>(
        slopDesk: SettingsKey.autoDetectLinkSchemesKey,
        default: .all,
    )
    static let customLinkSchemes = Key<[String]>(slopDesk: SettingsKey.customLinkSchemes, default: [])
    static let hintPatterns = Key<[String]>(slopDesk: SettingsKey.hintPatterns, default: [])
    static let hintPatternActions = Key<[String]>(slopDesk: SettingsKey.hintPatternActions, default: [])
}

/// Store ``PaneKind`` as its bare `String` rawValue (not JSON-wrapped) so it stays wire-compatible with the
/// existing direct-string writes + `@AppStorage`/`@Default` consumers.
/// `PreferRawRepresentable` selects `RawRepresentableBridge`, which yields the key default for a
/// retired/invalid raw value (e.g. the retired `"claudeCode"`).
extension PaneKind: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``NewTabPosition`` as its bare `String` rawValue (`auto`/`end`/`after-current`) so the persisted
/// `new-tab-position` setting round-trips with the config value; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`, which yields the key default (`.auto`) for a stale / invalid raw value.
extension NewTabPosition: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``AutoHideTabsPanelMode`` as its bare `String` rawValue (`default`/`always`/`auto`) so the persisted
/// `auto-hide-tabs-panel` setting round-trips with the config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`, which yields the key default (`.default`) for a stale / invalid raw
/// value.
extension AutoHideTabsPanelMode: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``CloseConfirmationPolicy`` as its bare `String` rawValue (`process`/`always`/`multiple_tabs`) so
/// the persisted close-confirmation setting round-trips with the config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`. A stale / invalid raw value repairs to `.process` via the policy's
/// own non-failable ``CloseConfirmationPolicy/init(rawValue:)`` (and the key default is also `.process`).
extension CloseConfirmationPolicy: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``OnLaunchBehavior`` as its bare `String` rawValue (`restore-last-session`/`new-window`) so the
/// persisted `On Launch` setting round-trips with the config value; `PreferRawRepresentable` selects
/// the `RawRepresentableBridge`. A stale / invalid raw value repairs to `.restoreLastSession` via the enum's
/// own non-failable ``OnLaunchBehavior/init(rawValue:)`` (and the key default is also `.restoreLastSession`).
extension OnLaunchBehavior: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``DesktopWindowPresentation`` as its bare `String` rawValue (`window`/`fullscreen`) so the
/// persisted `desktop-window` setting round-trips with the config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`, which yields the key default (`.window`) for a stale / invalid
/// raw value.
extension DesktopWindowPresentation: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``WindowSizeMode`` as its bare `String` rawValue (`remember`/`grid`/`frame`) so the persisted
/// `window-size` setting round-trips with the config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`, which yields the key default (`.remember`) for a stale / invalid
/// raw value.
extension WindowSizeMode: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``NotifyWhileForeground`` as its bare `String` rawValue (`off`/`always`/`tab-unfocused`) so the
/// persisted "Notify While Foreground" setting round-trips with the config value;
/// `PreferRawRepresentable` selects the `RawRepresentableBridge`, which yields the key default (`.off`) for a
/// stale / invalid raw value.
extension NotifyWhileForeground: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store the Controls / Mouse / Scroll enums as their bare `String` rawValue (the slopdesk config tokens)
/// so each persisted setting round-trips compactly; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`. Each enum's own non-failable ``init(rawValue:)`` repairs a stale / hostile
/// persisted string to its default (`.ask` / `.contextMenu` / `.disabled` / `.enabled`), so a future-version
/// value can never trap the bridge.
extension ClipboardAccess: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension RightClickAction: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension MouseShiftCapture: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension OptionAsAlt: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store the link-interaction enums as their bare `String` rawValue (the slopdesk config tokens) so each
/// persisted link setting round-trips compactly; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`. Each enum's own non-failable ``init(rawValue:)`` repairs a stale / hostile
/// persisted string to its default (`.open` / `.revealFinder` / `.all`), so a future-version value can never
/// trap the bridge.
extension LinkCmdClick: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension LinkCmdShiftClick: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension AutoDetectLinkSchemes: Defaults.Serializable, Defaults.PreferRawRepresentable {}
