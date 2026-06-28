import AislopdeskVideoProtocol
import Defaults
import Foundation

// L0: extracted from the deleted SwiftUI `SettingsScene.swift`. `SettingsKey` is the pure
// `UserDefaults`-key namespace + the fire-time boolean/`PaneKind` accessors that the headless logic
// (CommandCompletionNotifier, AppLaunchMonitor, WorkspaceStore+Completion, the monitors) reads. The
// new Settings UI binds the SAME keys via `@Default(.key)` (the typed `Defaults.Keys` below).
//
// G2 / Defaults: the fire-time accessors now read sindresorhus/Defaults typed keys — the per-key default
// lives ONCE in the `Defaults.Keys` declaration instead of being repeated in each `?? true`. The wire
// STRING constants stay (the `Defaults.Key` names reuse them, so there is one source of truth that
// `SettingsKeyTests` pins and the `@Default`/`@AppStorage` consumers share). No SwiftUI import — headless.
public enum SettingsKey {
    // Canvas
    public static let snapPanes = "canvas.snapPanes"
    public static let snapGrid = "canvas.snapGrid"
    public static let showGrid = "canvas.showGrid"
    public static let nonOverlap = "canvas.nonOverlap"
    public static let defaultPaneKindKey = "canvas.defaultPaneKind" // PaneKind.rawValue
    // General / launch
    /// The otty `On Launch` general setting (O1) — restore the last session vs open a fresh window.
    /// Stored as the ``OnLaunchBehavior`` rawValue (`restore-last-session` / `new-window`); default
    /// `.restoreLastSession` (the existing launch behaviour). Read by the app-launch path via
    /// ``WorkspacePersistence/launchTree(behavior:persistence:)`` at store construction.
    public static let onLaunchKey = "general.onLaunch" // OnLaunchBehavior.rawValue
    // Notifications
    public static let oscNotifications = "notifications.osc"
    public static let longCommandNotifications = "notifications.longCommand"
    // E14/K9 (notification-setting.png NOTIFICATION section). Fire-time `Defaults.Keys` flags, never folded
    // into a typed prefs model (golden-safe, like `oscNotifications`). The pure ``NotificationPolicy`` reads
    // the resolved ``notificationSettings`` bundle; the UI (WI-7 navigator) binds the SAME keys.
    /// otty "Notify on Command Finish" — fire when a command exits 0 (default OFF).
    public static let notifyOnFinish = "notifications.onFinish"
    /// otty "Notify on Error Exit" — fire when a command exits non-zero (default ON).
    public static let notifyOnError = "notifications.onError"
    /// otty "Notify on Watch Finish" — fire when an `aislopdesk watch`-wrapped command finishes (default ON).
    public static let notifyOnWatchFinish = "notifications.onWatchFinish"
    /// otty "Notify While Foreground" — banner behaviour while the app is frontmost. Stored as the
    /// ``NotifyWhileForeground`` rawValue (`off`/`always`/`tab-unfocused`); default `.off`. Named with the
    /// `Key` suffix (like ``newTabPositionKey``) so the typed accessor below takes the bare name.
    public static let notifyWhileForegroundKey = "notifications.whileForeground" // NotifyWhileForeground.rawValue
    /// otty "Bounce Dock Icon" — bounce the Dock when a notification arrives and the app is not focused
    /// (default ON; macOS-only behaviour — the Dock tile is process-global, wired in WI-5).
    public static let bounceDockIcon = "notifications.bounceDock"
    /// otty "Sound — Shell Controlled" — a `BEL` rings `NSSound.beep()` (default ON). Read by ``BellPolicy``.
    public static let soundShellControlled = "notifications.soundShellControlled"
    /// otty "Sound on Error Exit" — beep when a command exits non-zero (default OFF). Read by ``ErrorSoundPolicy``.
    public static let soundOnErrorExit = "notifications.soundOnErrorExit"
    /// otty "Code Agent — Notify When Task Completes" — agent went idle (default ON; Claude-only).
    public static let agentNotifyTaskComplete = "notifications.agentTaskComplete"
    /// otty "Code Agent — Notify When Awaiting Input" — agent needs approval / input (default ON; Claude-only).
    public static let agentNotifyAwaitInput = "notifications.agentAwaitInput"
    // E13/WI-3 (agents__agents-overview.md "Agent Behaviour"). The three otty BADGE toggles, fire-time
    // `Defaults.Keys` flags (never folded into a typed prefs model → golden-safe, like `agentNotify*`). They
    // gate which fused tab badge the sidebar SHOWS via the pure ``AgentBadgeGates`` (the resolver stays pure +
    // unchanged); a per-pane override in ``WorkspaceStore`` beats this global default. Claude-only.
    /// otty "Badge while processing" — show the running spinner badge (default ON; Claude-only).
    public static let agentBadgeWhileProcessing = "agents.badgeWhileProcessing"
    /// otty "Badge when complete" — show the completed-checkmark / finished-dot badge (default ON; Claude-only).
    public static let agentBadgeWhenComplete = "agents.badgeWhenComplete"
    /// otty "Badge when awaiting input" — show the awaiting-input hand badge (default ON; Claude-only).
    public static let agentBadgeWhenAwaitingInput = "agents.badgeWhenAwaitingInput"
    // Controls / scroll / copy (otty Controls section). These are FIRE-TIME `Defaults.Keys` flags — they
    // are deliberately NOT folded into any typed prefs model, so they never reach the `EnvConfig` overlay
    // or the `video-prefs.json` sidecar (golden-safe by construction, like `oscNotifications`). E8 owns the
    // BEHAVIOUR; E7 only declares + surfaces them. They are persisted forward-stubs that round-trip today.
    /// otty `copy-on-select` — copy the selection to the pasteboard as soon as it is made (default OFF).
    /// **E8 owns the behaviour.**
    public static let copyOnSelect = "controls.copyOnSelect"
    /// otty `clipboard-trim-trailing-spaces` — strip trailing whitespace from each copied line (default ON).
    /// **E8 owns the behaviour.**
    public static let trimTrailingSpacesOnCopy = "controls.trimTrailingSpaces"
    /// otty `clipboard-paste-protection` — warn before pasting text that contains a newline / control char
    /// (default ON). **E8 owns the behaviour.**
    public static let pasteProtection = "controls.pasteProtection"
    /// otty `mouse-hide-while-typing` — hide the mouse pointer while typing (default ON). **E8 owns the
    /// behaviour.**
    public static let mouseHideWhileTyping = "controls.mouseHideWhileTyping"
    /// otty `focus-follows-mouse` — focus the pane the pointer is over without a click (default OFF).
    /// **E8 owns the behaviour.**
    public static let focusFollowsMouse = "controls.focusFollowsMouse"
    /// otty `scroll-on-output` — scroll the viewport to the bottom on new output (default ON). **E8 owns the
    /// behaviour.**
    public static let scrollOnOutput = "controls.scrollOnOutput"
    /// otty `mouse-scroll-multiplier` — multiply the scroll-wheel delta (default `1.0`). **E8 owns the
    /// behaviour.**
    public static let scrollMultiplier = "controls.scrollMultiplier"

    // E8 WI-1: the remaining otty Controls / Mouse / Scroll knobs. Same fire-time `Defaults.Keys`
    // discipline (never folded into a typed prefs model → never reach the env overlay / sidecar →
    // golden-safe). E8 owns the behaviour; declared + persisted here so the Controls UI round-trips. The
    // bool keys take the bare name (`…Enabled` accessor); the enum-valued keys take a `…Key` suffix (like
    // `onLaunchKey`) so the typed accessor below can use the bare name.
    /// otty `selection-clear-on-typing` — clear the selection when the user types (default ON).
    public static let clearSelectionOnTyping = "controls.clearSelectionOnTyping"
    /// otty `selection-clear-on-copy` — clear the selection after an explicit copy (default OFF).
    public static let clearSelectionOnCopy = "controls.clearSelectionOnCopy"
    /// otty backspace-deletes-selection (I7) — Backspace with an active prompt-line selection deletes the
    /// whole selection (default ON). Read by `BackspaceSelectionPolicy` (WI-10).
    public static let backspaceDeletesSelection = "controls.backspaceDeletesSelection"
    /// otty "Shift+Arrow Select" (I2) — ⇧+arrows drive native selection instead of forwarding the arrow
    /// escapes (default ON). Emits the four `adjust_selection` keybinds (WI-2).
    public static let shiftArrowSelect = "controls.shiftArrowSelect"
    /// otty `clipboard-paste-bracketed-safe` — treat a bracketed paste as safe, skipping the warning when
    /// the program advertised `?2004h` (default ON).
    public static let pasteBracketedSafe = "controls.pasteBracketedSafe"
    /// otty `clipboard-write` — the OSC-52 clipboard-WRITE access gate (stored ``ClipboardAccess`` rawValue,
    /// default `allow`).
    public static let clipboardWriteKey = "controls.clipboardWrite"
    /// otty `clipboard-read` — the OSC-52 clipboard-READ access gate (stored ``ClipboardAccess`` rawValue,
    /// default `ask`).
    public static let clipboardReadKey = "controls.clipboardRead"
    /// otty `mouse-reporting` (Allow Mouse Capture) — allow programs to capture mouse events (default ON).
    public static let allowMouseCapture = "controls.allowMouseCapture"
    /// otty `mouse-shift-capture` (Allow Shift with Mouse Click) — whether ⇧ bypasses a program's mouse
    /// capture (stored ``MouseShiftCapture`` rawValue, default `enabled`).
    public static let allowShiftClickKey = "controls.allowShiftClick"
    /// otty `cursor-click-to-move` — click in the prompt to move the shell cursor (default ON).
    public static let clickToMove = "controls.clickToMove"
    /// otty `mouse.rightClickAction` — what a bare right-click does in the viewport (stored
    /// ``RightClickAction`` rawValue, default `context-menu`).
    public static let rightClickActionKey = "controls.rightClickAction"
    /// otty "Scroll Past Last Line" — overscroll past the last content row (stored ``ScrollPastLast``
    /// rawValue, default `disabled`).
    public static let scrollPastLastLineKey = "controls.scrollPastLastLine"
    /// otty "Scroll Past First Line" — overscroll past the first scrollback row (stored ``ScrollPastFirst``
    /// rawValue, default `disabled`).
    public static let scrollPastFirstLineKey = "controls.scrollPastFirstLine"
    /// otty "Smooth Scroll" — pixel-granularity scrolling during the gesture, snap-to-row on end (default
    /// ON).
    public static let smoothScroll = "controls.smoothScroll"
    /// otty undo-at-prompt (I18) — ⌘Z emits the readline undo (`0x1f`) when in the prompt zone (default ON).
    public static let undoAtPrompt = "controls.undoAtPrompt"
    /// otty `auto-secure-input` (E17 ES-E17-4) — automatically engage macOS Secure Keyboard Entry while the
    /// remote shell is at a no-echo (hidden-password) prompt (default ON; macOS-only). **WI-7 owns it.**
    public static let autoSecureInput = "controls.autoSecureInput"
    /// otty secure-input INDICATOR (E17 ES-E17-4) — show the `🛡 SECURE INPUT` pill while secure input is
    /// active (default ON; macOS-only). **WI-7 owns it.**
    public static let secureInputIndicator = "controls.secureInputIndicator"

    // E14/K11-K12 (terminal-features__notifications.md privilege surface — Settings → Advanced). Fire-time
    // `Defaults.Keys` flags (never folded into a typed prefs model → golden-safe, like the clipboard keys).
    // These gate what an OSC sequence from the remote shell is allowed to do client-side.
    /// otty "Title — Shell Controlled" — allow apps to set the tab/window title via `OSC 0` / `OSC 2`
    /// (default ON). Read fire-time by ``TerminalViewModel`` at the `.title` event: OFF drops the title update.
    public static let titleShellControlled = "controls.titleShellControlled"
    /// otty "Title Report" — allow apps to read the window title back via `OSC 21` / XTWINOPS (default OFF —
    /// a program that can both set and read the title can exfiltrate data through a pane). **CEILING:** the
    /// pinned libghostty fork answers XTWINOPS itself with no enable/disable hook on the ``TerminalSurface``
    /// seam, so this persists/surfaces but does NOT yet actuate — see docs/DECISIONS.md (E14 WI-7).
    public static let titleReport = "controls.titleReport"
    /// otty "Clipboard — Shell Controlled" — the master switch for the whole `OSC 52` clipboard path (default
    /// ON). When OFF, ``TerminalControls/from(defaults:)`` resolves BOTH read + write to ``ClipboardAccess/deny``
    /// ahead of the per-direction gate, so the libghostty config emits `clipboard-read/write = deny`.
    public static let clipboardShellControlled = "controls.clipboardShellControlled"

    // E10 (Path/link detection — otty Settings → Controls → Open With / Link Schemes). Fire-time
    // `Defaults.Keys` flags (never folded into a typed prefs model → golden-safe). Declared + persisted here
    // so the Controls UI round-trips; E10 WI-5/6/8/9 read them fire-time (the ⌘-hold underline, the
    // click/context-menu dispatch, Jump-To, and Hint Mode). The bool key takes the bare name (`…Enabled`
    // accessor); the enum-valued keys take a `…Key` suffix (like `rightClickActionKey`) so the typed accessor
    // below can use the bare name; the list-valued keys take the bare name (read via the bridged accessors /
    // `@Default`, like `composerPinnedPaneIDs`).
    /// otty `link-detection` — detect paths / URLs in terminal output and underline them on ⌘-hover (default
    /// ON). Turn OFF when a TUI's mouse reporting conflicts with the detection overlay.
    public static let linkDetection = "controls.linkDetection"
    /// otty `link-cmd-click` — what a ⌘click on a detected link does (stored ``LinkCmdClick`` rawValue,
    /// default `open`).
    public static let linkCmdClickKey = "controls.linkCmdClick" // LinkCmdClick.rawValue
    /// otty `link-cmd-shift-click` — what a ⌘⇧click on a detected link does (stored ``LinkCmdShiftClick``
    /// rawValue, default `reveal-finder`).
    public static let linkCmdShiftClickKey = "controls.linkCmdShiftClick" // LinkCmdShiftClick.rawValue
    /// otty "Auto-Detect Link Schemes" — which URL schemes are underlined / clickable (stored
    /// ``AutoDetectLinkSchemes`` rawValue, default `all`). `http(s)` / `file` / `mailto` are always detected.
    public static let autoDetectLinkSchemesKey = "controls.autoDetectLinkSchemes" // AutoDetectLinkSchemes.rawValue
    /// otty "Custom Link Schemes" — the extra `scheme`s detected when ``autoDetectLinkSchemes`` is `custom`
    /// (stored `[String]`, e.g. `codex`, `ssh`, `vscode`). Default empty. Read via ``linkSchemePolicy``.
    public static let customLinkSchemes = "controls.customLinkSchemes" // [String]
    /// otty hint-mode user patterns (E10 WI-9) — extra regexes whose matches also get a hint label (stored
    /// `[String]`). Default empty. Declared here so the key round-trips; **WI-9 owns the behaviour.**
    public static let hintPatterns = "controls.hintPatterns" // [String]
    /// The parallel per-pattern action for each ``hintPatterns`` entry (stored `[String]`, e.g. `open` /
    /// `copy`). Default empty. **WI-9 owns the behaviour.**
    public static let hintPatternActions = "controls.hintPatternActions" // [String]
    // Features / advanced
    public static let systemDialogPanes = "features.systemDialogPanes"
    public static let autoSwitchLayouts = "features.autoSwitchLayouts"
    public static let redactSecrets = "features.redactSecrets"
    public static let recordClipboardHistory = "features.recordClipboardHistory"
    /// otty "Auto Progress-Bar Commands" (E14/K2) — the whitespace-delimited command PREFIX list that
    /// auto-emits an INDETERMINATE OSC-9;4 progress spinner while running (Settings → Advanced). Default =
    /// the otty built-in slow-command list (``autoProgressCommandsBuiltIn``); clearing the list disables
    /// auto-progress entirely. The CLIENT setting is the EDIT/DISPLAY surface; the HOST resolves its own
    /// copy from `AISLOPDESK_AUTO_PROGRESS_COMMANDS` at launch (set identically host+client, like
    /// `AISLOPDESK_FEC_M`) — a live edit re-drives the host on the NEXT launch. Stored `[String]`.
    public static let autoProgressCommands = "advanced.autoProgressCommands" // [String]
    // E14/K13 (IPC guards on the agent-control ctl socket — terminal-features__notifications.md privilege
    // surface → Settings → Advanced). Fire-time `Defaults.Keys` flags (never folded into a typed prefs model
    // → golden-safe, like `autoProgressCommands`). These are CLIENT-displayed toggles whose ENFORCEMENT is
    // HOST-side: the guard runs on the host's NDJSON ctl socket, so a live client edit applies on the NEXT
    // host launch via the env bridge (same resolution discipline as K2 — set identically host+client, like
    // `AISLOPDESK_FEC_M`). The threat model differs from otty's local-process IPC (the WireGuard mesh is the
    // security boundary); this maps the toggles onto the host agent-control socket. See docs/DECISIONS.md.
    /// otty/E14-K13 "IPC — Allow Send Keys" — whether the agent-control ctl socket may run the MUTATING verbs
    /// (`write`/`run`/`spawn`/`kill`/`resize`, the "send keys" equivalents). Default OFF. The host ENFORCES
    /// via `HostEnvironment.ipcAllowSendKeys()` (`AISLOPDESK_IPC_ALLOW_SEND_KEYS`); read-only verbs
    /// (`list-panes`/`read`/`wait`/`report`) are ALWAYS allowed. Stored Bool.
    public static let ipcAllowSendKeys = "advanced.ipcAllowSendKeys"
    /// otty/E14-K13 "IPC — Allow Sensitive Sessions" — whether a mutating ctl verb may target a pane whose
    /// foreground process is a SENSITIVE command (`ssh`/`sudo`/`login`/…). Default OFF — OFF refuses
    /// send-keys into a live password prompt. Host-enforced via `AISLOPDESK_IPC_ALLOW_SENSITIVE`; same
    /// next-launch env-bridge discipline as ``ipcAllowSendKeys``. Stored Bool.
    public static let ipcAllowSensitiveSessions = "advanced.ipcAllowSensitiveSessions"
    // Appearance / chrome
    /// The active ``DSDensity`` tier rawValue. Mirrors ``DSDensity/storageKey`` (the SAME `UserDefaults`
    /// key ``DSThemeStore`` reads at init + on a Settings change) so the picker, persistence, and the live
    /// `DSScale`/height tokens all agree on one source.
    public static let density = "appearance.density"
    /// Whether the bottom ``PaneStatusBar`` is hidden (the chrome recedes toward pure terminal). Default OFF.
    public static let hideStatusBar = "appearance.hideStatusBar"
    /// Whether the per-block sticky command divider/header is shown over terminal panes. Default ON.
    public static let showBlockDividers = "terminal.showBlockDividers"
    // E14/K5/K8 (terminal-features__progress-state.md "DOCK ICON" group). macOS-only NSDockTile behaviour;
    // the keys still compile + round-trip on iOS, where the feature is inert (no Dock). Fire-time
    // `Defaults.Keys` flags, never folded into a typed prefs model → golden-safe (like `hideStatusBar`).
    /// otty "Animate Dock Icon During Progress" (`dock-icon-animate-progress`) — animate the macOS Dock tile
    /// while ANY session reports an OSC 9;4 in-progress / indeterminate state (default OFF; macOS-only). Read
    /// by the macOS ``DockProgressController`` via the pure ``DockTintPolicy``.
    public static let dockIconAnimateProgress = "appearance.dockIconAnimateProgress"
    /// otty "Red Icon on Error" (`dock-icon-error-badge`) — tint the macOS Dock tile red when any session
    /// reports a non-zero exit / OSC 9;4;2 error; clicking the Dock jumps to the next failing tab + clears the
    /// tint (default ON; macOS-only). Read by the macOS ``DockProgressController`` via ``DockTintPolicy``.
    public static let dockIconErrorBadge = "appearance.dockIconErrorBadge"
    // E12 (Composer / Prompt Queue). Fire-time `Defaults.Keys` flags — like the E8 Controls knobs they are
    // NEVER folded into the env overlay / sidecar (golden-safe by construction). They MIRROR the typed
    // `TerminalPreferences.composer*` client-pref fields; the leaf view reads these fire-time accessors so it
    // doesn't have to thread `PreferencesStore` down the pane subtree.
    /// otty "Composer max height" — the fraction of the pane height the Composer grows to before internal
    /// scroll. Default ``TerminalPreferences/defaultComposerMaxHeightFraction`` (~0.4).
    public static let composerMaxHeight = "composer.maxHeightFraction"
    /// The set of pane UUIDs whose Composer is PINNED (rides along across tab switches, E12 WI-6). Pinning is
    /// PER-PANE, so persistence is a set keyed by the stable leaf ``PaneID`` (NOT a single global Bool), and
    /// each pane re-pins on a fresh launch (`LivePaneSession.adopt`). Default empty (nothing pinned).
    public static let composerPinnedPaneIDs = "composer.pinnedPaneIDs"
    // Shell / window behaviour
    /// Where a new tab is inserted in the active session's tab bar (otty `new-tab-position`). Stored as the
    /// ``NewTabPosition`` rawValue (`auto`/`end`/`after-current`); default `.auto` (= append). Read at the
    /// ⌘T fire-site (`WorkspaceStore.newTab`). Named with the `Key` suffix (like ``defaultPaneKindKey``) so
    /// the typed ``NewTabPosition`` accessor below can take the bare ``newTabPosition`` name.
    public static let newTabPositionKey = "shell.newTabPosition" // NewTabPosition.rawValue

    /// How the vertical sidebar BUCKETS tabs into sections (otty sort-hamburger "Group By", E6). Stored as
    /// the ``TabGrouping`` rawValue (`none`/`byProject`/`byDate`); default `.none` (one flat list). Read +
    /// written by ``WorkspaceStore`` (the single source of truth for row order). Named with the `Key` suffix
    /// (like ``newTabPositionKey``) so the typed ``tabGrouping`` accessor below takes the bare name.
    public static let tabGroupingKey = "shell.tabGrouping" // TabGrouping.rawValue
    /// How tabs are ORDERED within a sidebar section (otty sort-hamburger "Sort By", E6). Stored as the
    /// ``TabSort`` rawValue (`created`/`updated`/`manual`); default `.created` (= `session.tabs` array order).
    public static let tabSortKey = "shell.tabSort" // TabSort.rawValue

    /// When the vertical TABS panel (sidebar) is shown (otty `auto-hide-tabs-panel`, E19/A18). Stored as the
    /// ``AutoHideTabsPanelMode`` rawValue (`default`/`always`/`auto`); default `.default` (always shown). Only
    /// `.auto` auto-hides the panel when the active session has a single tab — the show/hide decision lives in
    /// the pure ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)`` and the view-side glue (WI-7) drives
    /// ``WorkspaceChromeState/sidebarCollapsed`` from it. Named with the `Key` suffix (like ``tabSortKey``) so
    /// the typed ``autoHideTabsPanel`` accessor below can take the bare name.
    public static let autoHideTabsPanelKey = "shell.autoHideTabsPanel" // AutoHideTabsPanelMode.rawValue

    /// The working-directory policy for a NEW WINDOW (otty `working-directory`), default `home` — a fresh
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

    /// The close-confirmation policy for a TAB / PANE close (otty close-confirmation), default `process` —
    /// confirm only when a child process is running. Stored as the ``CloseConfirmationPolicy`` rawValue
    /// (`process` / `always` / `multiple_tabs`). Read at the tab/pane close fire-sites
    /// (`WorkspaceStore.requestClosePaneTree` / `requestCloseActivePaneTree` / `closeActiveTab`).
    public static let closeConfirmTabKey = "shell.closeConfirm.tab" // CloseConfirmationPolicy.rawValue
    /// The close-confirmation policy for a WINDOW close (mapped to the active ``Session`` — see
    /// `docs/DECISIONS.md`), default `process`. Stored as the ``CloseConfirmationPolicy`` rawValue. Read at
    /// the window-close fire-site (`WorkspaceStore.requestCloseWindow`).
    public static let closeConfirmWindowKey = "shell.closeConfirm.window" // CloseConfirmationPolicy.rawValue

    // E19/A29 (otty `window-size` — user-interface__window-tab-split.md). A NEW `window.*` namespace, so a
    // stale read decode-fails to the key default per [[rwork-no-backcompat]] (no migration). These are the
    // CLIENT-side initial-window-sizing settings: the macOS `NSWindow` glue (WI-4) reads them once per window
    // open + resolves the content size via ``WindowSizeMath``; iOS has no resizable window (the keys still
    // compile + round-trip there, inert). touchesWire:false — purely client view state.
    /// How a new window decides its initial dimensions (otty `window-size`). Stored as the ``WindowSizeMode``
    /// rawValue (`remember`/`grid`/`frame`); default `.remember` (restore the autosaved frame). Named with
    /// the `Key` suffix (like ``newTabPositionKey``) so the typed ``windowSize`` accessor takes the bare name.
    public static let windowSizeKey = "window.size" // WindowSizeMode.rawValue
    /// The column count for a new window when ``windowSize`` is ``WindowSizeMode/grid`` (otty `window-cols`),
    /// default `80`. Clamped into a sane band by ``WindowSizeMath/clampCols(_:)`` at the sizing fire-site.
    public static let windowColsKey = "window.cols"
    /// The row count for a new window when ``windowSize`` is ``WindowSizeMode/grid`` (otty `window-rows`),
    /// default `24`. Clamped by ``WindowSizeMath/clampRows(_:)`` at the sizing fire-site.
    public static let windowRowsKey = "window.rows"
    /// The width (px) for a new window when ``windowSize`` is ``WindowSizeMode/frame`` (otty
    /// `window-width-px`), default `1000`. Clamped by ``WindowSizeMath/clampPx(_:)`` at the sizing fire-site.
    public static let windowWidthPxKey = "window.widthPx"
    /// The height (px) for a new window when ``windowSize`` is ``WindowSizeMode/frame`` (otty
    /// `window-height-px`), default `600`. Clamped by ``WindowSizeMath/clampPx(_:)`` at the sizing fire-site.
    public static let windowHeightPxKey = "window.heightPx"

    // E16 (Recipes — Command Replay + at-prompt snippet auto-expand). Fire-time `Defaults.Keys` flags, never
    // folded into a typed prefs model → golden-safe (recipes are 100% client-side; touchesWire:false). The two
    // replay-mode keys store the bare ``RecipeReplayMode`` rawValue via the `RawRepresentableBridge` (the
    // conformance below); the auto-expand key is a native Bool. The enum-valued keys take a `Key` suffix (like
    // ``newTabPositionKey``) so the typed ``replayModeSaved`` / ``replayModeFiles`` accessors take the bare name.
    /// otty Recipes → Command Replay for INTERNALLY-saved recipes (the `.ottyrecipe` ⌘S writes). Stored as the
    /// ``RecipeReplayMode`` rawValue; default `.auto` (a recipe you saved yourself replays automatically).
    public static let replayModeSavedKey = "recipes.replayMode.saved" // RecipeReplayMode.rawValue
    /// otty Recipes → Command Replay for EXTERNALLY-opened `.ottyrecipe` FILES. Stored as the
    /// ``RecipeReplayMode`` rawValue; default `.askOnce` (a recipe from elsewhere shows its commands first).
    public static let replayModeFilesKey = "recipes.replayMode.files" // RecipeReplayMode.rawValue
    /// otty snippet at-prompt AUTO-EXPAND (E16 ES-E16-4) — whether typing a snippet's alias at the shell prompt
    /// auto-expands it (default OFF — opt-in). RESERVED key for the **pinned-deferred** at-prompt expansion glue
    /// (plans/E16.md WI-10 / §6): no live reader yet — the shipped baseline is the explicit palette expand (type
    /// a snippet name/alias under ⌘⇧P). Settings deliberately surfaces NO toggle for this (a control that
    /// promised the behavior while doing nothing would be a lying control — honesty over a dead toggle).
    public static let snippetAutoExpand = "recipes.snippetAutoExpand"

    /// Whether a layout with a trigger app auto-switches when that app launches on the host (default
    /// ON — assigning a trigger is itself the opt-in). Read at fire-time.
    public static var autoSwitchLayoutsEnabled: Bool { Defaults[.autoSwitchLayouts] }

    /// Whether explicit OSC 9/777 notifications should post (default ON). Read at fire-time.
    public static var oscNotificationsEnabled: Bool { Defaults[.oscNotifications] }

    /// Whether the long-command completion notification should post (default ON). Read at fire-time.
    public static var longCommandNotificationsEnabled: Bool { Defaults[.longCommandNotifications] }

    // MARK: E14/K9 notification policy (fire-time accessors → the resolved `notificationSettings` bundle)

    /// otty "Notify on Command Finish" — fire when a command exits 0 (default OFF). Read at fire-time.
    public static var notifyOnFinishEnabled: Bool { Defaults[.notifyOnFinish] }

    /// otty "Notify on Error Exit" — fire when a command exits non-zero (default ON). Read at fire-time.
    public static var notifyOnErrorEnabled: Bool { Defaults[.notifyOnError] }

    /// otty "Notify on Watch Finish" — fire when an `aislopdesk watch`-wrapped command finishes (default ON).
    public static var notifyOnWatchFinishEnabled: Bool { Defaults[.notifyOnWatchFinish] }

    /// otty "Notify While Foreground" — banner behaviour while the app is frontmost (default
    /// ``NotifyWhileForeground/off``). A stale / invalid persisted raw value repairs to `.off` via the
    /// `RawRepresentableBridge`. Read at fire-time.
    public static var notifyWhileForeground: NotifyWhileForeground { Defaults[.notifyWhileForeground] }

    /// otty "Bounce Dock Icon" — bounce the Dock when a notification arrives and the app is unfocused
    /// (default ON; macOS-only behaviour, actuated in WI-5). Read at fire-time.
    public static var bounceDockIconEnabled: Bool { Defaults[.bounceDockIcon] }

    /// otty "Sound — Shell Controlled" — a `BEL` rings the system beep (default ON). Read at fire-time.
    public static var soundShellControlledEnabled: Bool { Defaults[.soundShellControlled] }

    /// otty "Sound on Error Exit" — beep when a command exits non-zero (default OFF). Read at fire-time.
    public static var soundOnErrorExitEnabled: Bool { Defaults[.soundOnErrorExit] }

    /// otty "Code Agent — Notify When Task Completes" (default ON; Claude-only). Read at fire-time.
    public static var agentNotifyTaskCompleteEnabled: Bool { Defaults[.agentNotifyTaskComplete] }

    /// otty "Code Agent — Notify When Awaiting Input" (default ON; Claude-only). Read at fire-time.
    public static var agentNotifyAwaitInputEnabled: Bool { Defaults[.agentNotifyAwaitInput] }

    // MARK: E13/WI-3 agent badge gates (the global default the per-pane override falls back to)

    /// otty "Badge while processing" — show the running spinner badge (default ON; Claude-only). Read fire-time.
    public static var agentBadgeWhileProcessingEnabled: Bool { Defaults[.agentBadgeWhileProcessing] }

    /// otty "Badge when complete" — show the completed/finished badge (default ON; Claude-only). Read fire-time.
    public static var agentBadgeWhenCompleteEnabled: Bool { Defaults[.agentBadgeWhenComplete] }

    /// otty "Badge when awaiting input" — show the awaiting-input badge (default ON; Claude-only). Read fire-time.
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

    /// Whether the system-dialog monitor should auto-spawn dialog panes (default ON). The
    /// `AISLOPDESK_SYSTEM_DIALOG_PANES` env var still overrides for tests (`0` off / `force` on).
    public static var systemDialogPanesEnabled: Bool { Defaults[.systemDialogPanes] }

    /// Whether to mask likely secrets (access keys, bearer tokens, `PASSWORD=…`) out of window titles and
    /// notification bodies before they reach the sidebar/pill/Notification Center (default ON — security
    /// by default; the escape hatch is for someone who genuinely wants raw titles). Read at fire-time.
    public static var redactSecretsEnabled: Bool { Defaults[.redactSecrets] }

    /// Whether copied text is archived into the clipboard-history ring that backs the pill's "Paste
    /// Recent" submenu (default ON). Turn it OFF to stop the monitor from retaining any copied string —
    /// the privacy escape hatch for someone who copies secrets to paste into sudo/SSH prompts. Read at
    /// fire-time so a settings change applies live; existing entries are cleared from the pill's "Clear
    /// History".
    public static var recordClipboardHistoryEnabled: Bool { Defaults[.recordClipboardHistory] }

    /// The otty built-in slow-command prefix list (E14/K2) — the DEFAULT for ``autoProgressCommands``
    /// and the value otty pre-populates in the field. CLIENT-SIDE mirror of the host's
    /// `AutoProgressMatcher.builtInPrefixes` (the two live in different modules — `AislopdeskWorkspaceCore`
    /// cannot import `AislopdeskHost` — so the canonical list is duplicated; this copy is the DISPLAY/edit
    /// default, the host copy is the ENFORCEMENT fallback). Keep the two in sync; see docs/DECISIONS.md.
    public static let autoProgressCommandsBuiltIn: [String] = [
        "curl",
        "wget",
        "rsync",
        "scp",
        "git fetch",
        "git pull",
        "git push",
        "git clone",
        "brew install",
        "brew update",
        "brew upgrade",
        "npm install",
        "pnpm install",
        "yarn install",
        "bun install",
        "pip install",
        "cargo build",
        "cargo install",
        "cargo update",
        "docker pull",
        "docker push",
        "docker build",
        "apt install",
        "apt update",
        "apt upgrade",
        "apt-get install",
        "apt-get update",
        "apt-get upgrade",
    ]

    /// The configured auto-progress slow-command prefix list (E14/K2), default ``autoProgressCommandsBuiltIn``.
    /// The read seam the client→host env bridge serialises into `AISLOPDESK_AUTO_PROGRESS_COMMANDS`; an
    /// empty list disables auto-progress entirely. Read at fire-time.
    public static var autoProgressCommandsList: [String] { Defaults[.autoProgressCommands] }

    /// otty/E14-K13 "IPC — Allow Send Keys" (default OFF) — the CLIENT edit/display surface for the host
    /// ctl-socket send-keys guard. The host ENFORCES via `HostEnvironment.ipcAllowSendKeys()`; this toggle
    /// round-trips today + bridges to the host env on the next launch. Read at fire-time.
    public static var ipcAllowSendKeysEnabled: Bool { Defaults[.ipcAllowSendKeys] }

    /// otty/E14-K13 "IPC — Allow Sensitive Sessions" (default OFF) — the CLIENT edit/display surface for the
    /// host ctl-socket sensitive-session guard. Host-enforced via `HostEnvironment.ipcAllowSensitiveSessions()`.
    /// Read at fire-time.
    public static var ipcAllowSensitiveSessionsEnabled: Bool { Defaults[.ipcAllowSensitiveSessions] }

    /// Whether the bottom status bar is hidden (default OFF — the strip shows unless the user hides it).
    /// Read at fire-time so a Settings change applies on the next render.
    public static var hideStatusBarEnabled: Bool { Defaults[.hideStatusBar] }

    /// Whether the per-block command divider/header is shown (default ON). Read at fire-time.
    public static var showBlockDividersEnabled: Bool { Defaults[.showBlockDividers] }

    /// Whether the macOS Dock tile animates during OSC 9;4 progress (otty `dock-icon-animate-progress`),
    /// default OFF (macOS-only; inert on iOS). Read fire-time by ``DockProgressController`` via ``DockTintPolicy``.
    public static var dockIconAnimateProgressEnabled: Bool { Defaults[.dockIconAnimateProgress] }

    /// Whether the macOS Dock tile tints red on a non-zero exit / OSC 9;4;2 error (otty `dock-icon-error-badge`),
    /// default ON (macOS-only; inert on iOS). Read fire-time by ``DockProgressController`` via ``DockTintPolicy``.
    public static var dockIconErrorBadgeEnabled: Bool { Defaults[.dockIconErrorBadge] }

    /// The resolved Composer max-height fraction (otty "Composer max height", E12) — the persisted value
    /// clamped into a sane `0.15…0.9` band, or ``TerminalPreferences/defaultComposerMaxHeightFraction`` (~0.4)
    /// when unset. The leaf multiplies this by the live pane height to size the Composer field (then internal
    /// scroll). Ordered min/max (NaN-safe — never a bare `<`/`>` ternary).
    public static var composerMaxHeightFraction: Double {
        Double.minimum(0.9, Double.maximum(0.15, Defaults[.composerMaxHeight]))
    }

    /// Whether the Composer in the pane with `paneID` is PINNED across tab switches (E12 WI-6). Read at
    /// session materialization (`LivePaneSession.adopt`) to re-pin the RIGHT pane on a fresh launch — the
    /// otty "pinned state is persisted as a user preference" rule, made faithful by keying on the stable
    /// per-pane ``PaneID`` instead of a single global Bool.
    public static func isComposerPinned(paneID: PaneID) -> Bool {
        Defaults[.composerPinnedPaneIDs].contains(paneID.raw.uuidString)
    }

    /// PERSISTS the per-pane Composer PIN (E12 WI-6) so a pinned Composer survives an app relaunch and
    /// re-pins exactly the pane that was pinned. Adds / removes the pane's ``PaneID`` UUID in the persisted
    /// set. Idempotent — a no-op write leaves the set (and `Defaults`) untouched. Wired to
    /// ``ComposerModel/onPinnedChange`` by the owning ``LivePaneSession``.
    public static func setComposerPinned(_ pinned: Bool, paneID: PaneID) {
        let token = paneID.raw.uuidString
        var ids = Set(Defaults[.composerPinnedPaneIDs])
        if pinned { ids.insert(token) } else { ids.remove(token) }
        let sorted = ids.sorted()
        guard sorted != Defaults[.composerPinnedPaneIDs] else { return }
        Defaults[.composerPinnedPaneIDs] = sorted
    }

    /// The default kind for a generic "New Pane" (toolbar primary action / empty state), default
    /// `.terminal`. The ⌥⌘N per-kind shortcut is unaffected. A stale persisted `"claudeCode"` value (the
    /// kind retired in W11) is not a valid raw value here → falls back to `.terminal`, exactly right
    /// (the `RawRepresentableBridge` returns the key default when the stored raw value no longer maps).
    public static var defaultPaneKind: PaneKind { Defaults[.defaultPaneKind] }

    /// Where a new tab opens in the active session's tab bar (otty `new-tab-position`), default `.auto`
    /// (= append, byte-identical to the pre-E3 behaviour). A stale / invalid persisted raw value falls back
    /// to `.auto` via the `RawRepresentableBridge`. Read at the ⌘T fire-site.
    public static var newTabPosition: NewTabPosition { Defaults[.newTabPosition] }

    /// The persisted sidebar tab grouping (otty "Group By", E6), default ``TabGrouping/none``. A stale /
    /// invalid persisted raw value repairs to `.none` via the `RawRepresentableBridge`. Read at store init.
    public static var tabGrouping: TabGrouping { Defaults[.tabGrouping] }

    /// The persisted within-section tab sort (otty "Sort By", E6), default ``TabSort/created``. A stale /
    /// invalid persisted raw value repairs to `.created`. Read at store init.
    public static var tabSort: TabSort { Defaults[.tabSort] }

    /// When the vertical TABS panel is shown (otty `auto-hide-tabs-panel`, E19/A18), default
    /// ``AutoHideTabsPanelMode/default`` (always shown). A stale / invalid persisted raw value repairs to
    /// `.default` via the `RawRepresentableBridge`. Read by the view-side auto-hide glue (WI-7), which feeds it
    /// to ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)``.
    public static var autoHideTabsPanel: AutoHideTabsPanelMode { Defaults[.autoHideTabsPanel] }

    /// The working-directory policy applied when a NEW WINDOW opens (otty `working-directory`), default
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

    /// The close-confirmation policy applied to a TAB / PANE close (otty close-confirmation), default
    /// ``CloseConfirmationPolicy/process``. A stale / invalid persisted raw value repairs to `.process` (via
    /// ``CloseConfirmationPolicy/init(rawValue:)`` + the `RawRepresentableBridge`). Read at fire-time.
    public static var closeConfirmTab: CloseConfirmationPolicy { Defaults[.closeConfirmTab] }

    /// The close-confirmation policy applied to a WINDOW close (mapped to the active ``Session`` — see
    /// `docs/DECISIONS.md`), default ``CloseConfirmationPolicy/process``. Read at fire-time.
    public static var closeConfirmWindow: CloseConfirmationPolicy { Defaults[.closeConfirmWindow] }

    /// The otty `On Launch` behaviour applied when the app opens (O1), default
    /// ``OnLaunchBehavior/restoreLastSession`` (the existing launch behaviour — the store already restores
    /// the persisted tree). A stale / invalid persisted raw value repairs to `.restoreLastSession` (via the
    /// policy's own non-failable ``OnLaunchBehavior/init(rawValue:)`` + the `RawRepresentableBridge`). Read
    /// by the app-launch path via ``WorkspacePersistence/launchTree(behavior:persistence:)`` (a `.newWindow`
    /// value seeds a fresh single-pane session instead of restoring the persisted tree).
    public static var onLaunch: OnLaunchBehavior { Defaults[.onLaunch] }

    // MARK: E19/A29 window-size (otty `window-size` — read once per window open by the macOS NSWindow glue)

    /// How a new window decides its initial dimensions (otty `window-size`), default
    /// ``WindowSizeMode/remember`` (restore the autosaved frame). A stale / invalid persisted raw value
    /// repairs to `.remember` via the `RawRepresentableBridge`. Read by the macOS `NSWindow` glue (WI-4),
    /// which resolves the content size through ``WindowSizeMath/resolvedContentSize(mode:cols:rows:widthPx:heightPx:cell:visible:chromeInsets:)``.
    public static var windowSize: WindowSizeMode { Defaults[.windowSize] }

    /// The persisted `grid`-mode column count (otty `window-cols`), default `80`. The RAW value — the
    /// sizing math clamps it via ``WindowSizeMath/clampCols(_:)``.
    public static var windowCols: Int { Defaults[.windowCols] }

    /// The persisted `grid`-mode row count (otty `window-rows`), default `24`. The RAW value — clamped by
    /// ``WindowSizeMath/clampRows(_:)``.
    public static var windowRows: Int { Defaults[.windowRows] }

    /// The persisted `frame`-mode width in px (otty `window-width-px`), default `1000`. The RAW value —
    /// clamped by ``WindowSizeMath/clampPx(_:)``.
    public static var windowWidthPx: Int { Defaults[.windowWidthPx] }

    /// The persisted `frame`-mode height in px (otty `window-height-px`), default `600`. The RAW value —
    /// clamped by ``WindowSizeMath/clampPx(_:)``.
    public static var windowHeightPx: Int { Defaults[.windowHeightPx] }

    // MARK: E16 Recipes (Command Replay modes + at-prompt snippet auto-expand)

    /// The replay mode for INTERNALLY-saved recipes (otty Command Replay, E16), default
    /// ``RecipeReplayMode/auto`` (a recipe you saved yourself replays automatically). A stale / invalid
    /// persisted raw value repairs to `.auto` via the `RawRepresentableBridge`. Read by the recipe-open path.
    public static var replayModeSaved: RecipeReplayMode { Defaults[.replayModeSaved] }

    /// The replay mode for externally-opened `.ottyrecipe` FILES (otty Command Replay, E16), default
    /// ``RecipeReplayMode/askOnce`` (an unfamiliar file shows its commands first). A stale / invalid persisted
    /// raw value repairs to `.askOnce`. Read by the recipe-open path.
    public static var replayModeFiles: RecipeReplayMode { Defaults[.replayModeFiles] }

    /// Whether typing a snippet alias at the shell prompt auto-expands it (otty E16 ES-E16-4), default OFF
    /// (opt-in). RESERVED accessor for the **pinned-deferred** at-prompt expansion path — no live reader yet;
    /// the shipped expansion path is the explicit command-palette run (honesty over a typing-corruption bug).
    public static var snippetAutoExpandEnabled: Bool { Defaults[.snippetAutoExpand] }

    // MARK: Controls / scroll / copy (E8-owned behaviour — declared + persisted here)

    /// Whether the selection is copied to the pasteboard as soon as it is made (otty `copy-on-select`),
    /// default OFF. **E8 owns the behaviour**; declared + persisted here so the Controls picker round-trips.
    public static var copyOnSelectEnabled: Bool { Defaults[.copyOnSelect] }

    /// Whether trailing whitespace is trimmed from each copied line (otty `clipboard-trim-trailing-spaces`),
    /// default ON. **E8 owns the behaviour.**
    public static var trimTrailingSpacesOnCopyEnabled: Bool { Defaults[.trimTrailingSpacesOnCopy] }

    /// Whether pasting text with a newline / control char prompts a confirmation (otty
    /// `clipboard-paste-protection`), default ON. **E8 owns the behaviour.**
    public static var pasteProtectionEnabled: Bool { Defaults[.pasteProtection] }

    /// Whether the mouse pointer hides while typing (otty `mouse-hide-while-typing`), default ON. **E8 owns
    /// the behaviour.**
    public static var mouseHideWhileTypingEnabled: Bool { Defaults[.mouseHideWhileTyping] }

    /// Whether focus follows the mouse pointer without a click (otty `focus-follows-mouse`), default OFF.
    /// **E8 owns the behaviour.**
    public static var focusFollowsMouseEnabled: Bool { Defaults[.focusFollowsMouse] }

    /// Whether the viewport scrolls to the bottom on new output (otty `scroll-on-output`), default ON.
    /// **E8 owns the behaviour.**
    public static var scrollOnOutputEnabled: Bool { Defaults[.scrollOnOutput] }

    /// The scroll-wheel delta multiplier (otty `mouse-scroll-multiplier`), default `1.0`. **E8 owns the
    /// behaviour.**
    public static var scrollMultiplierValue: Double { Defaults[.scrollMultiplier] }

    // MARK: E8 WI-1: the remaining Controls / Mouse / Scroll knobs (fire-time accessors)

    /// Whether the selection clears when the user types (otty `selection-clear-on-typing`), default ON.
    public static var clearSelectionOnTypingEnabled: Bool { Defaults[.clearSelectionOnTyping] }

    /// Whether the selection clears after an explicit copy (otty `selection-clear-on-copy`), default OFF.
    public static var clearSelectionOnCopyEnabled: Bool { Defaults[.clearSelectionOnCopy] }

    /// Whether Backspace deletes the whole prompt-line selection (otty backspace-deletes-selection, I7),
    /// default **OFF — not yet functional**: the pinned libghostty fork exposes no selection-geometry C API,
    /// so even ON it cannot faithfully delete the run (it degrades to a single-character Backspace,
    /// indistinguishable from OFF). Read by `BackspaceSelectionPolicy` (WI-10); see docs/DECISIONS.md.
    public static var backspaceDeletesSelectionEnabled: Bool { Defaults[.backspaceDeletesSelection] }

    /// Whether ⇧+arrows drive native selection (otty "Shift+Arrow Select", I2), default ON.
    public static var shiftArrowSelectEnabled: Bool { Defaults[.shiftArrowSelect] }

    /// Whether a bracketed paste is treated as safe (otty `clipboard-paste-bracketed-safe`), default ON.
    public static var pasteBracketedSafeEnabled: Bool { Defaults[.pasteBracketedSafe] }

    /// Whether programs may capture mouse events (otty `mouse-reporting`, Allow Mouse Capture), default ON.
    public static var allowMouseCaptureEnabled: Bool { Defaults[.allowMouseCapture] }

    /// Whether clicking in the prompt moves the shell cursor (otty `cursor-click-to-move`), default ON.
    public static var clickToMoveEnabled: Bool { Defaults[.clickToMove] }

    /// Whether smooth (pixel-granularity) scrolling is on (otty "Smooth Scroll"), default ON.
    public static var smoothScrollEnabled: Bool { Defaults[.smoothScroll] }

    /// Whether ⌘Z at the prompt emits the readline undo (otty undo-at-prompt, I18), default ON.
    public static var undoAtPromptEnabled: Bool { Defaults[.undoAtPrompt] }

    /// Whether macOS Secure Keyboard Entry engages AUTOMATICALLY on a host no-echo password prompt (otty
    /// `auto-secure-input`, E17 ES-E17-4), default ON. Read fire-time by ``SecureKeyboardEntryController`` +
    /// ``TerminalViewModel/secureInputActive``. macOS-only behaviour (the controller is inert off macOS).
    public static var autoSecureInputEnabled: Bool { Defaults[.autoSecureInput] }

    /// Whether the `🛡 SECURE INPUT` pill is shown while secure input is active (otty secure-input indicator,
    /// E17 ES-E17-4), default ON. Read fire-time by the leaf's pill gate. macOS-only (the pill never lights
    /// on iOS — ``TerminalViewModel/secureInputActive`` is always `false` there).
    public static var secureInputIndicatorEnabled: Bool { Defaults[.secureInputIndicator] }

    /// The OSC-52 clipboard-WRITE access gate (otty `clipboard-write`), default ``ClipboardAccess/allow``.
    /// A stale / invalid persisted raw value repairs to `.allow` via the `RawRepresentableBridge`.
    public static var clipboardWrite: ClipboardAccess { Defaults[.clipboardWrite] }

    /// The OSC-52 clipboard-READ access gate (otty `clipboard-read`), default ``ClipboardAccess/ask``.
    /// A stale / invalid persisted raw value repairs to `.ask` via the `RawRepresentableBridge`.
    public static var clipboardRead: ClipboardAccess { Defaults[.clipboardRead] }

    // MARK: E14/K11-K12 privilege surface (title + OSC-52 master switch)

    /// otty "Title — Shell Controlled" — whether a remote `OSC 0` / `OSC 2` may set the tab/window title
    /// (default ON). Read fire-time by ``TerminalViewModel`` at the `.title` event (OFF drops the update).
    public static var titleShellControlledEnabled: Bool { Defaults[.titleShellControlled] }

    /// otty "Title Report" — whether apps may read the window title back via `OSC 21` / XTWINOPS (default
    /// OFF). **CEILING:** persists/surfaces but does not yet actuate (the libghostty fork owns XTWINOPS with
    /// no enable hook — docs/DECISIONS.md E14 WI-7). Read fire-time for forward-compatibility.
    public static var titleReportEnabled: Bool { Defaults[.titleReport] }

    /// otty "Clipboard — Shell Controlled" — the master switch gating the whole `OSC 52` path (default ON).
    /// When OFF, ``TerminalControls/from(defaults:)`` resolves read + write to ``ClipboardAccess/deny``.
    public static var clipboardShellControlledEnabled: Bool { Defaults[.clipboardShellControlled] }

    /// Whether ⇧ bypasses a program's mouse capture (otty `mouse-shift-capture`, Allow Shift with Mouse
    /// Click), default ``MouseShiftCapture/enabled``. A stale / invalid raw value repairs to `.enabled`.
    public static var allowShiftClick: MouseShiftCapture { Defaults[.allowShiftClick] }

    /// What a bare right-click does in the viewport (otty `mouse.rightClickAction`), default
    /// ``RightClickAction/contextMenu``. A stale / invalid raw value repairs to `.contextMenu`.
    public static var rightClickAction: RightClickAction { Defaults[.rightClickAction] }

    /// Overscroll past the last content row (otty "Scroll Past Last Line"), default ``ScrollPastLast/disabled``.
    /// A stale / invalid raw value repairs to `.disabled`. The render policy suppresses it on the alt screen.
    public static var scrollPastLastLine: ScrollPastLast { Defaults[.scrollPastLastLine] }

    /// Overscroll past the first scrollback row (otty "Scroll Past First Line"), default
    /// ``ScrollPastFirst/disabled``. A stale / invalid raw value repairs to `.disabled`.
    public static var scrollPastFirstLine: ScrollPastFirst { Defaults[.scrollPastFirstLine] }

    // MARK: E10 link interaction (declared + persisted here; E10 WI-5/6/8/9 own the behaviour)

    /// Whether path / URL link detection is on (otty `link-detection`), default ON. Read fire-time by the
    /// ⌘-hold underline overlay + the click / context-menu / Jump-To / Hint paths.
    public static var linkDetectionEnabled: Bool { Defaults[.linkDetection] }

    /// What a ⌘click on a detected link does (otty `link-cmd-click`), default ``LinkCmdClick/open``. A stale /
    /// invalid persisted raw value repairs to `.open` via the `RawRepresentableBridge`.
    public static var linkCmdClick: LinkCmdClick { Defaults[.linkCmdClick] }

    /// What a ⌘⇧click on a detected link does (otty `link-cmd-shift-click`), default
    /// ``LinkCmdShiftClick/revealFinder``. A stale / invalid raw value repairs to `.revealFinder`.
    public static var linkCmdShiftClick: LinkCmdShiftClick { Defaults[.linkCmdShiftClick] }

    /// Which URL schemes are auto-detected (otty "Auto-Detect Link Schemes"), default
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

    /// The resolved user Hint Mode patterns (E10 WI-9) — zips the persisted parallel `hint-pattern` /
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

// MARK: - Typed Defaults keys (the single source the accessors + `@Default(.key)` views read)

/// The typed ``Defaults`` keys for the global app-flag namespace. Names reuse the ``SettingsKey`` string
/// constants so the wire strings stay the one source of truth (pinned by `SettingsKeyTests`, shared with
/// every `@Default`/`@AppStorage` consumer). All `.standard`-backed — the per-instance-injectable
/// ``PreferencesStore`` deliberately stays on its own `UserDefaults` (test isolation), not these.
public extension Defaults.Keys {
    static let oscNotifications = Key<Bool>(SettingsKey.oscNotifications, default: true)
    static let longCommandNotifications = Key<Bool>(SettingsKey.longCommandNotifications, default: true)
    // E14/K9 notification policy (notification-setting.png). Fire-time flags, never folded into a typed prefs
    // model → golden-safe. The enum-valued `notifyWhileForeground` stores the bare rawValue via the
    // `RawRepresentableBridge` (repairing a stale value to `.off`, like `closeConfirmTab`).
    static let notifyOnFinish = Key<Bool>(SettingsKey.notifyOnFinish, default: false)
    static let notifyOnError = Key<Bool>(SettingsKey.notifyOnError, default: true)
    static let notifyOnWatchFinish = Key<Bool>(SettingsKey.notifyOnWatchFinish, default: true)
    static let notifyWhileForeground = Key<NotifyWhileForeground>(
        SettingsKey.notifyWhileForegroundKey,
        default: .off,
    )
    static let bounceDockIcon = Key<Bool>(SettingsKey.bounceDockIcon, default: true)
    static let soundShellControlled = Key<Bool>(SettingsKey.soundShellControlled, default: true)
    static let soundOnErrorExit = Key<Bool>(SettingsKey.soundOnErrorExit, default: false)
    static let agentNotifyTaskComplete = Key<Bool>(SettingsKey.agentNotifyTaskComplete, default: true)
    static let agentNotifyAwaitInput = Key<Bool>(SettingsKey.agentNotifyAwaitInput, default: true)
    // E13/WI-3 agent badge gates (agents__agents-overview.md "Agent Behaviour"). Fire-time flags, never folded
    // into a typed prefs model → golden-safe. All default ON (every agent badge shows, byte-identical to the
    // pre-E13 rail). Consumed via `SettingsKey.agentBadgeGates` → `AgentBadgeGates.gated` in `RailRowsBuilder`.
    static let agentBadgeWhileProcessing = Key<Bool>(SettingsKey.agentBadgeWhileProcessing, default: true)
    static let agentBadgeWhenComplete = Key<Bool>(SettingsKey.agentBadgeWhenComplete, default: true)
    static let agentBadgeWhenAwaitingInput = Key<Bool>(SettingsKey.agentBadgeWhenAwaitingInput, default: true)
    static let systemDialogPanes = Key<Bool>(SettingsKey.systemDialogPanes, default: true)
    static let autoSwitchLayouts = Key<Bool>(SettingsKey.autoSwitchLayouts, default: true)
    static let redactSecrets = Key<Bool>(SettingsKey.redactSecrets, default: true)
    static let recordClipboardHistory = Key<Bool>(SettingsKey.recordClipboardHistory, default: true)
    // E14/K2: the otty "Auto Progress-Bar Commands" list. Fire-time `[String]` key (never folded into a
    // typed prefs model → golden-safe, like `customLinkSchemes`). Default = the built-in slow-command
    // list; the host enforces its own copy from `AISLOPDESK_AUTO_PROGRESS_COMMANDS`.
    static let autoProgressCommands = Key<[String]>(
        SettingsKey.autoProgressCommands,
        default: SettingsKey.autoProgressCommandsBuiltIn,
    )
    // E14/K13: the IPC guards on the agent-control ctl socket. Fire-time flags (never folded into a typed
    // prefs model → golden-safe). Both default OFF (conservative — mutation/sensitive access is opt-in); the
    // host enforces its own copy via AISLOPDESK_IPC_ALLOW_SEND_KEYS / _SENSITIVE on the next launch.
    static let ipcAllowSendKeys = Key<Bool>(SettingsKey.ipcAllowSendKeys, default: false)
    static let ipcAllowSensitiveSessions = Key<Bool>(SettingsKey.ipcAllowSensitiveSessions, default: false)
    static let hideStatusBar = Key<Bool>(SettingsKey.hideStatusBar, default: false)
    static let showBlockDividers = Key<Bool>(SettingsKey.showBlockDividers, default: true)
    // E14/K5/K8 Dock-icon toggles (macOS-only NSDockTile; the keys compile + round-trip on iOS, inert there).
    // Fire-time flags, never folded into a typed prefs model → golden-safe. Animate default OFF, error-tint ON.
    static let dockIconAnimateProgress = Key<Bool>(SettingsKey.dockIconAnimateProgress, default: false)
    static let dockIconErrorBadge = Key<Bool>(SettingsKey.dockIconErrorBadge, default: true)
    // E12 Composer / Prompt Queue — fire-time flags, never folded into the env overlay / sidecar (golden-safe).
    // The max-height default mirrors `TerminalPreferences.defaultComposerMaxHeightFraction` (one source).
    static let composerMaxHeight = Key<Double>(
        SettingsKey.composerMaxHeight,
        default: TerminalPreferences.defaultComposerMaxHeightFraction,
    )
    static let composerPinnedPaneIDs = Key<[String]>(SettingsKey.composerPinnedPaneIDs, default: [])
    static let defaultPaneKind = Key<PaneKind>(SettingsKey.defaultPaneKindKey, default: .terminal)
    static let newTabPosition = Key<NewTabPosition>(SettingsKey.newTabPositionKey, default: .auto)
    // Sidebar tab grouping / sort (otty sort-hamburger, E6) stored as the bare enum rawValue. Group default
    // `.none` (one flat list); sort default `.created` (= `session.tabs` array order) — both byte-identical
    // to the pre-E6 rail. The WorkspaceStore owns the read/write; these are the persisted backing.
    static let tabGrouping = Key<TabGrouping>(SettingsKey.tabGroupingKey, default: .none)
    static let tabSort = Key<TabSort>(SettingsKey.tabSortKey, default: .created)
    // E19/A18 vertical-sidebar auto-hide (otty `auto-hide-tabs-panel`). Stores the bare `AutoHideTabsPanelMode`
    // rawValue via the `RawRepresentableBridge` (the `PreferRawRepresentable` conformance below), repairing a
    // stale value to `.default`. Default `.default` (always shown — byte-identical to the pre-E19 sidebar).
    static let autoHideTabsPanel = Key<AutoHideTabsPanelMode>(SettingsKey.autoHideTabsPanelKey, default: .default)
    // Working-directory policies stored as the `WorkingDirectoryPolicy.rawConfig` String (otty config value).
    // New window defaults to `home` (login cwd); new tab / split default to `inherit` (active pane's cwd).
    static let workingDirectoryNewWindow = Key<String>(SettingsKey.workingDirectoryNewWindowKey, default: "home")
    static let workingDirectoryNewTab = Key<String>(SettingsKey.workingDirectoryNewTabKey, default: "inherit")
    static let workingDirectoryNewSplit = Key<String>(SettingsKey.workingDirectoryNewSplitKey, default: "inherit")
    // Close-confirmation policies stored as the `CloseConfirmationPolicy` rawValue (otty config value). Both
    // default to `process` (confirm only on a running child process — the pre-E3 busy-shell guard).
    static let closeConfirmTab = Key<CloseConfirmationPolicy>(SettingsKey.closeConfirmTabKey, default: .process)
    static let closeConfirmWindow = Key<CloseConfirmationPolicy>(SettingsKey.closeConfirmWindowKey, default: .process)
    // On-Launch behaviour stored as the `OnLaunchBehavior` rawValue (otty `On Launch`); default
    // `.restoreLastSession` (the existing launch behaviour — the store already restores the persisted tree).
    static let onLaunch = Key<OnLaunchBehavior>(SettingsKey.onLaunchKey, default: .restoreLastSession)
    // E19/A29 window-size (otty `window-size`). A new `window.*` namespace, CLIENT-side only (touchesWire:false).
    // The mode stores the bare `WindowSizeMode` rawValue via the `RawRepresentableBridge` (the
    // `PreferRawRepresentable` conformance below), repairing a stale value to `.remember`; the cols/rows/px
    // are native `Int`s. Defaults mirror the otty config values (80×24 grid, 1000×600 frame).
    static let windowSize = Key<WindowSizeMode>(SettingsKey.windowSizeKey, default: .remember)
    static let windowCols = Key<Int>(SettingsKey.windowColsKey, default: 80)
    static let windowRows = Key<Int>(SettingsKey.windowRowsKey, default: 24)
    static let windowWidthPx = Key<Int>(SettingsKey.windowWidthPxKey, default: 1000)
    static let windowHeightPx = Key<Int>(SettingsKey.windowHeightPxKey, default: 600)
    // E16 Recipes — Command Replay modes + at-prompt snippet auto-expand. Fire-time flags (never folded into a
    // typed prefs model → golden-safe; recipes are 100% client-side). The replay modes store the bare
    // `RecipeReplayMode` rawValue via the `RawRepresentableBridge` (the conformance below), repairing a stale
    // value to the default; auto-expand is a native Bool defaulting OFF (opt-in). Defaults mirror the spec
    // replay-mode table: a SELF-saved recipe auto-replays (`auto`); an opened FILE asks once (`askOnce`).
    static let replayModeSaved = Key<RecipeReplayMode>(SettingsKey.replayModeSavedKey, default: .auto)
    static let replayModeFiles = Key<RecipeReplayMode>(SettingsKey.replayModeFilesKey, default: .askOnce)
    static let snippetAutoExpand = Key<Bool>(SettingsKey.snippetAutoExpand, default: false)
    // Controls / scroll / copy (otty Controls). FIRE-TIME flags only — never folded into a typed prefs model
    // (so they never reach the env overlay / sidecar → golden-safe). E8 owns the behaviour; these persist
    // the user's choice and round-trip today.
    static let copyOnSelect = Key<Bool>(SettingsKey.copyOnSelect, default: false)
    static let trimTrailingSpacesOnCopy = Key<Bool>(SettingsKey.trimTrailingSpacesOnCopy, default: true)
    static let pasteProtection = Key<Bool>(SettingsKey.pasteProtection, default: true)
    static let mouseHideWhileTyping = Key<Bool>(SettingsKey.mouseHideWhileTyping, default: true)
    static let focusFollowsMouse = Key<Bool>(SettingsKey.focusFollowsMouse, default: false)
    static let scrollOnOutput = Key<Bool>(SettingsKey.scrollOnOutput, default: true)
    static let scrollMultiplier = Key<Double>(SettingsKey.scrollMultiplier, default: 1.0)
    // E8 WI-1: the remaining Controls / Mouse / Scroll knobs. Same fire-time-only discipline (never folded
    // into a typed prefs model → golden-safe). The enum-valued keys store the bare enum rawValue via the
    // `RawRepresentableBridge` (the `Defaults.PreferRawRepresentable` conformances below), repairing a stale
    // value to the default exactly like `closeConfirmTab` / `onLaunch`.
    static let clearSelectionOnTyping = Key<Bool>(SettingsKey.clearSelectionOnTyping, default: true)
    static let clearSelectionOnCopy = Key<Bool>(SettingsKey.clearSelectionOnCopy, default: false)
    // Default OFF — NOT YET FUNCTIONAL: the pinned libghostty fork exposes no set-selection / cursor-geometry
    // C API, so a faithful "Backspace deletes the whole selection wherever it sits" cannot be actuated (a
    // blind DEL run would delete the WRONG characters for a mid-line selection — default-on data loss). With
    // the toggle ON the behaviour is INDISTINGUISHABLE from OFF (one character deleted + selection cleared),
    // so it ships OFF rather than as a default-ON toggle that does nothing. See `BackspaceSelectionPolicy`
    // and docs/DECISIONS.md (E8 WI-10) — the policy stays wired for a future libghostty geometry API.
    static let backspaceDeletesSelection = Key<Bool>(SettingsKey.backspaceDeletesSelection, default: false)
    static let shiftArrowSelect = Key<Bool>(SettingsKey.shiftArrowSelect, default: true)
    static let pasteBracketedSafe = Key<Bool>(SettingsKey.pasteBracketedSafe, default: true)
    static let allowMouseCapture = Key<Bool>(SettingsKey.allowMouseCapture, default: true)
    static let clickToMove = Key<Bool>(SettingsKey.clickToMove, default: true)
    static let smoothScroll = Key<Bool>(SettingsKey.smoothScroll, default: true)
    static let undoAtPrompt = Key<Bool>(SettingsKey.undoAtPrompt, default: true)
    // Secure input (E17 ES-E17-4 / WI-7) — both default ON (macOS-only behaviour; the keys still compile +
    // round-trip on iOS, where the feature is inert). Fire-time flags, never folded into the env overlay.
    static let autoSecureInput = Key<Bool>(SettingsKey.autoSecureInput, default: true)
    static let secureInputIndicator = Key<Bool>(SettingsKey.secureInputIndicator, default: true)
    static let clipboardWrite = Key<ClipboardAccess>(SettingsKey.clipboardWriteKey, default: .allow)
    static let clipboardRead = Key<ClipboardAccess>(SettingsKey.clipboardReadKey, default: .ask)
    // E14/K11-K12 privilege surface (terminal-features__notifications.md → Settings → Advanced). Fire-time
    // flags, never folded into a typed prefs model → golden-safe. Title — Shell Controlled + Clipboard —
    // Shell Controlled default ON; Title Report defaults OFF (the conservative exfiltration-safe default, and
    // it cannot yet actuate — see docs/DECISIONS.md E14 WI-7).
    static let titleShellControlled = Key<Bool>(SettingsKey.titleShellControlled, default: true)
    static let titleReport = Key<Bool>(SettingsKey.titleReport, default: false)
    static let clipboardShellControlled = Key<Bool>(SettingsKey.clipboardShellControlled, default: true)
    static let allowShiftClick = Key<MouseShiftCapture>(SettingsKey.allowShiftClickKey, default: .enabled)
    static let rightClickAction = Key<RightClickAction>(SettingsKey.rightClickActionKey, default: .contextMenu)
    static let scrollPastLastLine = Key<ScrollPastLast>(SettingsKey.scrollPastLastLineKey, default: .disabled)
    static let scrollPastFirstLine = Key<ScrollPastFirst>(SettingsKey.scrollPastFirstLineKey, default: .disabled)
    // E10 (Path/link detection — otty Settings → Controls → Open With / Link Schemes). Fire-time flags, never
    // folded into a typed prefs model → golden-safe. The enum keys store the bare enum rawValue via the
    // `RawRepresentableBridge` (repairing a stale value to the default exactly like `rightClickAction`); the
    // list keys store a native `[String]` (like `composerPinnedPaneIDs`).
    static let linkDetection = Key<Bool>(SettingsKey.linkDetection, default: true)
    static let linkCmdClick = Key<LinkCmdClick>(SettingsKey.linkCmdClickKey, default: .open)
    static let linkCmdShiftClick = Key<LinkCmdShiftClick>(SettingsKey.linkCmdShiftClickKey, default: .revealFinder)
    static let autoDetectLinkSchemes = Key<AutoDetectLinkSchemes>(
        SettingsKey.autoDetectLinkSchemesKey,
        default: .all,
    )
    static let customLinkSchemes = Key<[String]>(SettingsKey.customLinkSchemes, default: [])
    static let hintPatterns = Key<[String]>(SettingsKey.hintPatterns, default: [])
    static let hintPatternActions = Key<[String]>(SettingsKey.hintPatternActions, default: [])
}

/// Store ``PaneKind`` as its bare `String` rawValue (not JSON-wrapped) so the value stays wire-compatible
/// with the existing direct-string writes + the `defaultPaneKindKey` `@AppStorage`/`@Default` consumers;
/// `PreferRawRepresentable` selects `RawRepresentableBridge`, which also yields the key default for a
/// retired/invalid raw value (e.g. the W11 `"claudeCode"`).
extension PaneKind: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``NewTabPosition`` as its bare `String` rawValue (`auto`/`end`/`after-current`) so the persisted
/// `new-tab-position` setting round-trips with the otty config value; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`, which yields the key default (`.auto`) for a stale / invalid raw value.
extension NewTabPosition: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``TabGrouping`` / ``TabSort`` as their bare `String` rawValue so the persisted sidebar
/// grouping/sort round-trips compactly; `PreferRawRepresentable` selects the `RawRepresentableBridge`,
/// which yields the key default (`.none` / `.created`) for a stale / invalid raw value (E6).
extension TabGrouping: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension TabSort: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``AutoHideTabsPanelMode`` as its bare `String` rawValue (`default`/`always`/`auto`) so the persisted
/// otty `auto-hide-tabs-panel` setting (E19/A18) round-trips with the otty config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`, which yields the key default (`.default`) for a stale / invalid raw
/// value — the same shape as ``NewTabPosition`` / ``WindowSizeMode``.
extension AutoHideTabsPanelMode: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``CloseConfirmationPolicy`` as its bare `String` rawValue (`process`/`always`/`multiple_tabs`) so
/// the persisted close-confirmation setting round-trips with the otty config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`. A stale / invalid raw value repairs to `.process` via the policy's
/// own non-failable ``CloseConfirmationPolicy/init(rawValue:)`` (and the key default is also `.process`).
extension CloseConfirmationPolicy: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``OnLaunchBehavior`` as its bare `String` rawValue (`restore-last-session`/`new-window`) so the
/// persisted `On Launch` setting round-trips with the otty config value; `PreferRawRepresentable` selects
/// the `RawRepresentableBridge`. A stale / invalid raw value repairs to `.restoreLastSession` via the enum's
/// own non-failable ``OnLaunchBehavior/init(rawValue:)`` (and the key default is also `.restoreLastSession`).
extension OnLaunchBehavior: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``WindowSizeMode`` as its bare `String` rawValue (`remember`/`grid`/`frame`) so the persisted
/// otty `window-size` setting (E19/A29) round-trips with the otty config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`, which yields the key default (`.remember`) for a stale / invalid
/// raw value — the same shape as ``NewTabPosition`` / ``OnLaunchBehavior``.
extension WindowSizeMode: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``RecipeReplayMode`` as its bare `String` rawValue (`auto`/`askOnce`/`manually`/`skip`) so the
/// persisted otty Command Replay setting (E16) round-trips compactly; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`, which yields the key default (`.auto` for saved recipes / `.askOnce` for files)
/// for a stale / invalid raw value — the same shape as ``NewTabPosition`` / ``OnLaunchBehavior``.
extension RecipeReplayMode: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``NotifyWhileForeground`` as its bare `String` rawValue (`off`/`always`/`tab-unfocused`) so the
/// persisted otty "Notify While Foreground" setting round-trips with the otty config value (E14/K9);
/// `PreferRawRepresentable` selects the `RawRepresentableBridge`, which yields the key default (`.off`) for a
/// stale / invalid raw value — the same shape as ``CloseConfirmationPolicy``.
extension NotifyWhileForeground: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store the E8 Controls / Mouse / Scroll enums as their bare `String` rawValue (the otty / aislopdesk
/// config tokens) so each persisted setting round-trips compactly; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`. Each enum's own non-failable ``init(rawValue:)`` repairs a stale / hostile
/// persisted string to its default (`.ask` / `.contextMenu` / `.disabled` / `.enabled`), so a future-version
/// value can never trap the bridge — the same shape as ``CloseConfirmationPolicy`` / ``OnLaunchBehavior``.
extension ClipboardAccess: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension RightClickAction: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension ScrollPastLast: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension ScrollPastFirst: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension MouseShiftCapture: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store the E10 link-interaction enums as their bare `String` rawValue (the otty / aislopdesk config
/// tokens) so each persisted link setting round-trips compactly; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`. Each enum's own non-failable ``init(rawValue:)`` repairs a stale / hostile
/// persisted string to its default (`.open` / `.revealFinder` / `.all`), so a future-version value can never
/// trap the bridge — the same shape as ``RightClickAction`` / ``ScrollPastLast``.
extension LinkCmdClick: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension LinkCmdShiftClick: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension AutoDetectLinkSchemes: Defaults.Serializable, Defaults.PreferRawRepresentable {}
