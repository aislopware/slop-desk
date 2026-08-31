import CSlopDeskFFI
import Defaults
import Foundation
import SlopDeskVideoProtocol
import SlopDeskWorkspaceModel

// `SettingsKey`: the one place the app asks what a setting is.
//
// Every accessor below reads ``AppConfig/current`` — the config FILE resolved against the Rust key
// table — and nothing here holds a default of its own. There is no settings window and no way for
// the app to WRITE a setting: a setting written by a program is one the user cannot see in their
// own file, which is exactly the state the old 78-key `UserDefaults` namespace kept ending up in.
//
// `UserDefaults` survives for STATE, which is a different thing wearing the same storage. A window
// frame, a sidebar width, the set of projects whose workbench is open — those are things the app
// LEARNED, not things the user chose, and writing them back is the whole point. Four keys, all
// written by the app, none of them offered to the user as a preference.
//
// No view framework imported — headless.
public enum SettingsKey {
    /// The ONE `UserDefaults` suite backing the four state keys below.
    ///
    /// In the app this IS `.standard`. Under XCTest it is a per-PROCESS suite, wiped at creation and
    /// removed at exit: `swift test --parallel` runs many xctest processes that all share ONE
    /// standard domain through cfprefsd, so state written in one worker races a read in another, and
    /// a crashed run's mutations persist into the next run. Tests must mutate state via
    /// `SettingsKey.store` — a write to `UserDefaults.standard` is invisible to the keys in a test
    /// process.
    ///
    /// `SLOPDESK_DEFAULTS_SUITE` names a suite for the SHIPPING app, and exists for one reason: the
    /// GUI gates exec this bundle's binary directly, and `CFFIXED_USER_HOME` — which moves their
    /// Application Support container — does NOT move `UserDefaults`. cfprefsd resolves the real home
    /// whatever the environment says, so every gate that connects has been writing its own loopback
    /// port into the developer's `connection.recentTargets`, five entries deep, evicting the host
    /// they actually use. A suite isolates BOTH directions: a suite-backed `UserDefaults` cannot see
    /// this bundle's own persistent domain, and `NSArgumentDomain` still outranks it — which is what
    /// keeps `slopdesk-guigate launch-restore`'s `-connection.recentTargets` fixture driving the real
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
        // and SEEDS it. `slopdesk-guigate launch-restore` drives the returning-user launch path, and a
        // returning user is precisely someone whose state is not empty — wiping here would erase
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
    /// state read; a caller that beats it there installs the hook itself.
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

    /// The environment variable an automation run sets to keep its writes off the developer's domain.
    public static let defaultsSuiteEnvKey = "SLOPDESK_DEFAULTS_SUITE"

    // MARK: - The four STATE keys (things the app learned, not things the user chose)

    /// Whether the RIGHT code panel is collapsed, default `true` — a fresh install hides it. Written
    /// on every manual toggle, read once into ``WorkspaceChromeState`` at init.
    public static let codeSidebarCollapsedKey = "shell.codeSidebarCollapsed"

    /// The RIGHT code panel's last dragged width in points, default `0` = never dragged (the panel
    /// opens at its minimum). Written when a code-divider drag settles; without it the panel forgot
    /// its width across relaunch, because the split item's thickness is session state AppKit never
    /// persists.
    public static let codeSidebarWidthKey = "shell.codeSidebarWidth"

    /// The project roots admitted through the code panel's open gate, default empty. Written on
    /// every gate admit, so a relaunch does not re-gate a project the user already opened and pay a
    /// cold workbench boot for it.
    public static let openedCodeProjectsKey = "shell.openedCodeProjects"

    /// The last window frame — an `NSWindow.frameDescriptor` string the macOS glue writes on
    /// resize-end / move / quit and re-applies via `setFrame(from:)` once per window open.
    ///
    /// App-owned persistence, NOT `setFrameAutosaveName`.
    ///
    /// ⚠️ THE ORIGINAL REASON WAS SWIFTUI'S, AND IT IS GONE. SwiftUI asserted its own type-derived autosave
    /// name on the scene window — a name containing a per-launch `(unknown context at $…)` address — so
    /// AppKit's autosave machinery saved under a key that changed every launch and could never restore.
    /// The AppKit shell owns its `NSWindow` outright and no longer has that collision, so the ban on
    /// `setFrameAutosaveName` is now a preference, not a constraint. It was NOT re-litigated during the
    /// rebuild: this key already restores correctly and the glue that writes it is three lines, so the
    /// swap would be churn for churn's sake — but a reader should not be told a dead framework forbids it.
    public static let windowSavedFrameKey = "window.savedFrame"

    /// The persisted window frame. The one settable accessor in this file, and state rather than a
    /// setting: `window.size = "remember"` is the user's choice, and THIS is what got remembered.
    public static var savedWindowFrame: String {
        get { Defaults[.savedWindowFrame] }
        set { Defaults[.savedWindowFrame] = newValue }
    }

    // MARK: - General

    /// What the app does when it opens (`general.on-launch`), default restore-the-last-session. Read
    /// by the launch path via ``WorkspacePersistence/launchTree(behavior:persistence:)``.
    public static var onLaunch: OnLaunchBehavior {
        AppConfig.current.choice("general.on-launch", OnLaunchBehavior.restoreLastSession)
    }

    /// Whether likely secrets (access keys, bearer tokens, `PASSWORD=…`) are masked out of window
    /// titles and notification bodies before they reach the sidebar / pill / Notification Center
    /// (`general.redact-secrets`), default ON — security by default. Read at fire-time.
    public static var redactSecretsEnabled: Bool { AppConfig.current.flag("general.redact-secrets") }

    /// Whether copied text is archived into the clipboard-history ring behind the pill's "Paste
    /// Recent" submenu (`general.record-clipboard-history`), default ON. OFF stops the monitor
    /// retaining any copied string — the privacy escape hatch for someone who copies secrets into
    /// sudo / SSH prompts.
    public static var recordClipboardHistoryEnabled: Bool {
        AppConfig.current.flag("general.record-clipboard-history")
    }

    /// Whether this device follows the host's session focus (`general.follow-session-focus`, docs/45
    /// §8.2): ON for macOS, OFF for iOS. A phone attaches to LOOK at one session; a desktop attaches
    /// to WORK, and expects the host's focus to lead. The per-platform default is the TABLE's — this
    /// side does not know which way it goes.
    public static var followSessionFocus: Bool {
        AppConfig.current.flag("general.follow-session-focus")
    }

    // MARK: - Notifications

    /// Whether explicit OSC 9 / 777 notifications post (`notifications.osc`), default ON, and the
    /// master the whole ``notificationSettings`` bundle hangs off.
    public static var oscNotificationsEnabled: Bool { AppConfig.current.flag("notifications.osc") }

    /// Whether the long-command completion notification posts (`notifications.long-command`),
    /// default ON.
    public static var longCommandNotificationsEnabled: Bool {
        AppConfig.current.flag("notifications.long-command")
    }

    /// Fire when a command exits 0 (`notifications.on-finish`), default OFF.
    public static var notifyOnFinishEnabled: Bool { AppConfig.current.flag("notifications.on-finish") }

    /// Fire when a command exits non-zero (`notifications.on-error`), default ON.
    public static var notifyOnErrorEnabled: Bool { AppConfig.current.flag("notifications.on-error") }

    /// Fire when an `slopdesk watch`-wrapped command finishes (`notifications.on-watch-finish`),
    /// default ON.
    public static var notifyOnWatchFinishEnabled: Bool {
        AppConfig.current.flag("notifications.on-watch-finish")
    }

    /// Banner behaviour while the app is frontmost (`notifications.while-foreground`), default
    /// ``NotifyWhileForeground/off``.
    public static var notifyWhileForeground: NotifyWhileForeground {
        AppConfig.current.choice("notifications.while-foreground", NotifyWhileForeground.off)
    }

    /// Bounce the Dock when a notification arrives and the app is not focused
    /// (`notifications.bounce-dock`), default ON. macOS-only behaviour — the Dock tile is
    /// process-global.
    public static var bounceDockIconEnabled: Bool { AppConfig.current.flag("notifications.bounce-dock") }

    /// Whether a `BEL` rings the system beep (`notifications.sound-shell-controlled`), default ON.
    /// Read by ``BellPolicy``.
    public static var soundShellControlledEnabled: Bool {
        AppConfig.current.flag("notifications.sound-shell-controlled")
    }

    /// Beep when a command exits non-zero (`notifications.sound-on-error-exit`), default OFF. Read by
    /// ``ErrorSoundPolicy``.
    public static var soundOnErrorExitEnabled: Bool {
        AppConfig.current.flag("notifications.sound-on-error-exit")
    }

    /// Notify when the agent goes idle (`notifications.agent-task-complete`), default ON.
    public static var agentNotifyTaskCompleteEnabled: Bool {
        AppConfig.current.flag("notifications.agent-task-complete")
    }

    /// Notify when the agent needs approval or input (`notifications.agent-await-input`), default ON.
    public static var agentNotifyAwaitInputEnabled: Bool {
        AppConfig.current.flag("notifications.agent-await-input")
    }

    /// A sound cue on a finished agent turn, focused pane included
    /// (`notifications.agent-sound-task-complete`), default ON. Read by ``AgentSoundPolicy``, which
    /// decides RING or SILENT; the Mac spends the verdict on `NSSound("Submarine")` and the phone on
    /// the banner's own sound.
    public static var agentSoundTaskCompleteEnabled: Bool {
        AppConfig.current.flag("notifications.agent-sound-task-complete")
    }

    /// A sound cue when the agent blocks on input (`notifications.agent-sound-await-input`), default
    /// ON. `Glass` on the Mac, the banner sound on the phone.
    public static var agentSoundAwaitInputEnabled: Bool {
        AppConfig.current.flag("notifications.agent-sound-await-input")
    }

    /// The resolved ``NotificationSettings`` bundle the pure ``NotificationPolicy`` consumes — the
    /// ONE seam the poster (``CommandCompletionNotifier``, on both triples) reads, so the toggles are
    /// applied in exactly one place.
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

    // MARK: - Badges

    /// Show the agent THINKING spinner (`badges.agent-processing`), default OFF. Gates ONLY the
    /// agent's own spinner — a program's busy / OSC 9;4 progress spinner is never silenced by it.
    public static var agentBadgeWhileProcessingEnabled: Bool {
        AppConfig.current.flag("badges.agent-processing")
    }

    /// Show the completed-checkmark badge (`badges.agent-complete`), default ON.
    public static var agentBadgeWhenCompleteEnabled: Bool { AppConfig.current.flag("badges.agent-complete") }

    /// Show the awaiting-input hand badge (`badges.agent-awaiting-input`), default ON.
    public static var agentBadgeWhenAwaitingInputEnabled: Bool {
        AppConfig.current.flag("badges.agent-awaiting-input")
    }

    /// The resolved GLOBAL ``AgentBadgeGates`` the pure gating consumes — the ONE seam
    /// ``RailRowsBuilder`` reads (via ``WorkspaceStore/agentBadgeGates(for:)``, which prefers a
    /// per-pane override), so the three badge toggles are applied in exactly one place.
    public static var agentBadgeGates: AgentBadgeGates {
        AgentBadgeGates(
            badgeWhileProcessing: agentBadgeWhileProcessingEnabled,
            badgeWhenComplete: agentBadgeWhenCompleteEnabled,
            badgeWhenAwaitingInput: agentBadgeWhenAwaitingInputEnabled,
        )
    }

    /// Show the completed badge for a clean command exit (`badges.command-finish`), default ON.
    /// Distinct from the agent gate above: command and agent badges are chosen independently.
    public static var tabBadgeOnCommandFinishEnabled: Bool { AppConfig.current.flag("badges.command-finish") }

    /// Show the error badge for a non-zero command exit (`badges.command-fail`), default ON. Gates
    /// only the COMMAND-exit badge; an OSC 9;4;2 program progress error has no opt-out.
    public static var tabBadgeOnCommandFailEnabled: Bool { AppConfig.current.flag("badges.command-fail") }

    /// Show the awaiting-input hand for a plain command stopped at an interactive prompt
    /// (`badges.command-await-input`), default ON. The host-side detector that would DRIVE it is
    /// deferred (see `docs/DECISIONS.md`); the gate is wired so the future signal needs no code change.
    public static var tabBadgeOnCommandAwaitInputEnabled: Bool {
        AppConfig.current.flag("badges.command-await-input")
    }

    /// Seconds a foreground command must have been running before the plain busy dot is shown
    /// (`badges.busy-delay-seconds`), default 3; 0 is immediate. Keeps a fast `ls` / `cd` from
    /// flashing the rail. The table's own minimum is 0, so no clamp is needed here.
    public static var tabBadgeBusyDelaySecondsValue: Double {
        AppConfig.current.double("badges.busy-delay-seconds")
    }

    /// The resolved GLOBAL ``CommandBadgeGates`` the pure gating consumes — the ONE seam
    /// ``RailRowsBuilder`` and the control backend read alongside ``agentBadgeGates``. Command badges
    /// have no per-pane override.
    public static var commandBadgeGates: CommandBadgeGates {
        CommandBadgeGates(
            whenCommandFinishes: tabBadgeOnCommandFinishEnabled,
            whenCommandFails: tabBadgeOnCommandFailEnabled,
            whenCommandAwaitsInput: tabBadgeOnCommandAwaitInputEnabled,
        )
    }

    // MARK: - Shell

    /// Where a new tab is inserted in the active session's tab bar (`shell.new-tab-position`),
    /// default `.auto` (append). Read at the ⌘T fire-site.
    public static var newTabPosition: NewTabPosition {
        AppConfig.current.choice("shell.new-tab-position", NewTabPosition.auto)
    }

    /// When the vertical TABS panel is shown (`shell.auto-hide-tabs-panel`), default `.default`
    /// (always). Only `.auto` auto-hides when the active session has a single tab — the decision
    /// lives in `slopdesk_settings::chrome`, reached through `WorkspaceChromePolicy.applyAutoHide`.
    public static var autoHideTabsPanel: AutoHideTabsPanelMode {
        AppConfig.current.choice("shell.auto-hide-tabs-panel", AutoHideTabsPanelMode.default)
    }

    /// Where a NEW WINDOW starts (`shell.working-directory-new-window`), default `home` — a fresh
    /// window opens at the shell's login cwd. `inherit`, `home`, or an absolute path.
    public static var workingDirectoryNewWindow: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: AppConfig.current.text("shell.working-directory-new-window"))
    }

    /// Where a ⌘T tab starts (`shell.working-directory-new-tab`), default `inherit` — the active
    /// pane's last-known cwd.
    public static var workingDirectoryNewTab: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: AppConfig.current.text("shell.working-directory-new-tab"))
    }

    /// Where a split starts (`shell.working-directory-new-split`), default `inherit`.
    public static var workingDirectoryNewSplit: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: AppConfig.current.text("shell.working-directory-new-split"))
    }

    /// When a TAB or PANE close asks first (`shell.close-confirm-tab`), default `process` — only
    /// when a child process is running.
    public static var closeConfirmTab: CloseConfirmationPolicy {
        AppConfig.current.choice("shell.close-confirm-tab", CloseConfirmationPolicy.process)
    }

    /// When a WINDOW close asks first (`shell.close-confirm-window`), default `process`.
    public static var closeConfirmWindow: CloseConfirmationPolicy {
        AppConfig.current.choice("shell.close-confirm-window", CloseConfirmationPolicy.process)
    }

    // MARK: - Window

    /// How a new window decides its initial dimensions (`window.size`), default `.remember` (restore
    /// the saved frame). Read once per window open by the macOS `NSWindow` glue, which resolves the
    /// content size through ``WindowSizeMath``.
    public static var windowSize: WindowSizeMode {
        AppConfig.current.choice("window.size", WindowSizeMode.remember)
    }

    /// The `grid`-mode column count (`window.cols`), default 80. The RAW value — the sizing math
    /// clamps it via ``WindowSizeMath/clampCols(_:)``.
    public static var windowCols: Int { AppConfig.current.int("window.cols") }

    /// The `grid`-mode row count (`window.rows`), default 24. Clamped by ``WindowSizeMath/clampRows(_:)``.
    public static var windowRows: Int { AppConfig.current.int("window.rows") }

    /// The `frame`-mode width in px (`window.width-px`), default 1000. Clamped by ``WindowSizeMath/clampPx(_:)``.
    public static var windowWidthPx: Int { AppConfig.current.int("window.width-px") }

    /// The `frame`-mode height in px (`window.height-px`), default 600. Clamped by ``WindowSizeMath/clampPx(_:)``.
    public static var windowHeightPx: Int { AppConfig.current.int("window.height-px") }

    /// How the dedicated remote-desktop window presents when it opens (`window.desktop-presentation`),
    /// default ``DesktopWindowPresentation/window``. A `.fullscreen` value enters native fullscreen
    /// right after the window fronts.
    public static var desktopWindowPresentation: DesktopWindowPresentation {
        AppConfig.current.choice("window.desktop-presentation", DesktopWindowPresentation.window)
    }

    /// Whether SATELLITE windows (the dedicated remote desktop and the ⌥⌘P pop-out panes) keep taking
    /// POINTER input while NOT key (`window.satellite-background-pointer`), default ON: hover /
    /// scroll / click forward to the host and a click leaves the window un-activated, so typing stays
    /// in the window the user is working in.
    public static var satelliteBackgroundPointerEnabled: Bool {
        AppConfig.current.flag("window.satellite-background-pointer")
    }

    // MARK: - Appearance

    /// The chrome DENSITY tier (`appearance.density`), one of two tokens, `standard` or `compact`.
    public static var density: String { AppConfig.current.text("appearance.density") }

    /// Animate the macOS Dock tile while any session reports an OSC 9;4 in-progress state
    /// (`appearance.dock-icon-animate-progress`), default OFF. macOS-only; inert on iOS.
    public static var dockIconAnimateProgressEnabled: Bool {
        AppConfig.current.flag("appearance.dock-icon-animate-progress")
    }

    /// Tint the macOS Dock tile red when any session reports a non-zero exit or an OSC 9;4;2 error
    /// (`appearance.dock-icon-error-badge`), default ON. macOS-only; inert on iOS.
    public static var dockIconErrorBadgeEnabled: Bool {
        AppConfig.current.flag("appearance.dock-icon-error-badge")
    }

    // MARK: - Controls

    /// Show each pane as the ⌃⇥ switcher's highlight walks over it (`controls.pane-switcher-preview`),
    /// default ON — a switcher you can SEE through is the point of holding the key. OFF is a
    /// legitimate mode: the preview flips a video pane's UDP/VT/Metal pipeline on and off as the walk
    /// passes, and some people want the workspace to hold still.
    public static var paneSwitcherPreviewEnabled: Bool {
        AppConfig.current.flag("controls.pane-switcher-preview")
    }

    /// Copy the selection to the pasteboard as soon as it is made (`controls.copy-on-select`),
    /// default OFF.
    public static var copyOnSelectEnabled: Bool { AppConfig.current.flag("controls.copy-on-select") }

    /// Strip trailing whitespace from each copied line (`controls.trim-trailing-spaces`), default ON.
    public static var trimTrailingSpacesOnCopyEnabled: Bool {
        AppConfig.current.flag("controls.trim-trailing-spaces")
    }

    /// Warn before pasting text containing a newline or control character
    /// (`controls.paste-protection`), default ON.
    public static var pasteProtectionEnabled: Bool { AppConfig.current.flag("controls.paste-protection") }

    /// Hide the mouse pointer while typing (`controls.mouse-hide-while-typing`), default ON.
    public static var mouseHideWhileTypingEnabled: Bool {
        AppConfig.current.flag("controls.mouse-hide-while-typing")
    }

    /// Focus the pane the pointer is over without a click (`controls.focus-follows-mouse`), default
    /// OFF. Read live by the terminal surface's `mouseMoved` via ``FocusFollowsMousePolicy``.
    public static var focusFollowsMouseEnabled: Bool { AppConfig.current.flag("controls.focus-follows-mouse") }

    /// The scroll-wheel delta multiplier (`controls.scroll-multiplier`), default 1.
    public static var scrollMultiplierValue: Double { AppConfig.current.double("controls.scroll-multiplier") }

    /// Clear the selection when the user types (`controls.clear-selection-on-typing`), default ON.
    public static var clearSelectionOnTypingEnabled: Bool {
        AppConfig.current.flag("controls.clear-selection-on-typing")
    }

    /// Clear the selection after an explicit copy (`controls.clear-selection-on-copy`), default OFF.
    public static var clearSelectionOnCopyEnabled: Bool {
        AppConfig.current.flag("controls.clear-selection-on-copy")
    }

    /// ⇧+arrows drive native selection instead of forwarding the arrow escapes
    /// (`controls.shift-arrow-select`), default ON. Emits the four `adjust_selection` keybinds.
    public static var shiftArrowSelectEnabled: Bool { AppConfig.current.flag("controls.shift-arrow-select") }

    /// Treat a bracketed paste as safe, skipping the warning when the program advertised `?2004h`
    /// (`controls.paste-bracketed-safe`), default ON.
    public static var pasteBracketedSafeEnabled: Bool {
        AppConfig.current.flag("controls.paste-bracketed-safe")
    }

    /// Allow programs to capture mouse events (`controls.allow-mouse-capture`), default ON.
    public static var allowMouseCaptureEnabled: Bool { AppConfig.current.flag("controls.allow-mouse-capture") }

    /// Click in the prompt to move the shell cursor (`controls.click-to-move`), default ON.
    public static var clickToMoveEnabled: Bool { AppConfig.current.flag("controls.click-to-move") }

    /// ⌘Z at the prompt emits the readline undo (`controls.undo-at-prompt`), default ON. Read live by
    /// the terminal surface's `keyDown` via ``PromptEditPolicy``.
    public static var undoAtPromptEnabled: Bool { AppConfig.current.flag("controls.undo-at-prompt") }

    /// Engage macOS Secure Keyboard Entry automatically while the remote shell is at a no-echo prompt
    /// (`controls.auto-secure-input`), default ON. macOS-only behaviour.
    public static var autoSecureInputEnabled: Bool { AppConfig.current.flag("controls.auto-secure-input") }

    /// Show the `🛡 SECURE INPUT` pill while secure input is active
    /// (`controls.secure-input-indicator`), default ON. macOS-only.
    public static var secureInputIndicatorEnabled: Bool {
        AppConfig.current.flag("controls.secure-input-indicator")
    }

    /// The OSC-52 clipboard-WRITE access gate (`controls.clipboard-write`), default
    /// ``ClipboardAccess/allow``, with the ``clipboardShellControlledEnabled`` master switch already
    /// folded in.
    public static var clipboardWrite: ClipboardAccess { clipboardGates.write }

    /// The clipboard-READ access gate (`controls.clipboard-read`), default ``ClipboardAccess/ask``,
    /// with the master switch already folded in.
    public static var clipboardRead: ClipboardAccess { clipboardGates.read }

    /// Both directions in ONE crossing, resolved by `slopdesk_terminal::controls`.
    ///
    /// ⚠️ THE MASTER SWITCH IS FOLDED IN HERE AND NOWHERE ELSE, which is what makes it enforceable.
    /// It used to be folded by the fire-time control bundle — a value only the deleted config builder
    /// read — while the live OSC-52 path asked for `controls.clipboard-write` on its own and never
    /// saw the switch at all. Answering the RESOLVED gate from the accessor every caller already uses
    /// means a caller cannot forget it, and the precedence (master switch ahead of the per-direction
    /// choice) stays stated once, in Rust.
    ///
    /// Both directions together rather than one door each: a master switch honoured in one direction
    /// and not the other is precisely the failure this is guarding against.
    private static var clipboardGates: (read: ClipboardAccess, write: ClipboardAccess) {
        let packed = slopdesk_terminal_clipboard_gates(
            AppConfig.current.flag("controls.clipboard-shell-controlled"),
            UInt8(AppConfig.current.choice("controls.clipboard-read", ClipboardAccess.ask).index),
            UInt8(AppConfig.current.choice("controls.clipboard-write", ClipboardAccess.allow).index),
        )
        let all = ClipboardAccess.allCases
        return (read: all[Int(packed & 0xFF)], write: all[Int(packed >> 8)])
    }

    /// Whether a remote `OSC 0` / `OSC 2` may set the tab or window title
    /// (`controls.title-shell-controlled`), default ON. Read fire-time by ``TerminalViewModel`` at
    /// the `.title` event: OFF drops the update.
    public static var titleShellControlledEnabled: Bool {
        AppConfig.current.flag("controls.title-shell-controlled")
    }

    /// The master switch gating the whole `OSC 52` path (`controls.clipboard-shell-controlled`),
    /// default ON. When OFF, ``TerminalControls/from(config:)`` resolves BOTH read and write to
    /// ``ClipboardAccess/deny`` ahead of the per-direction gate.
    public static var clipboardShellControlledEnabled: Bool {
        AppConfig.current.flag("controls.clipboard-shell-controlled")
    }

    /// Whether ⇧ bypasses a program's mouse capture (`controls.shift-click`), default
    /// ``MouseShiftCapture/enabled``.
    public static var allowShiftClick: MouseShiftCapture {
        AppConfig.current.choice("controls.shift-click", MouseShiftCapture.enabled)
    }

    /// What a bare right-click does in the viewport (`controls.right-click-action`), default
    /// ``RightClickAction/contextMenu``.
    public static var rightClickAction: RightClickAction {
        AppConfig.current.choice("controls.right-click-action", RightClickAction.contextMenu)
    }

    /// How the macOS Option key is treated (`controls.option-as-alt`), default ``OptionAsAlt/off``.
    /// Emitted by the config builder as libghostty `macos-option-as-alt`.
    public static var optionAsAlt: OptionAsAlt {
        AppConfig.current.choice("controls.option-as-alt", OptionAsAlt.off)
    }

    // MARK: - The command prompt

    /// Whether the app's own editor owns the command line at a shell prompt
    /// (`controls.command-prompt`), default ON.
    ///
    /// ⚠️ THE ONE SETTING THAT TAKES THE KEYBOARD AWAY FROM THE SHELL, which is why it exists at all:
    /// with it on, a keystroke at an idle prompt edits ``CommandPrompt`` and the shell sees nothing
    /// until Enter sends the whole line. Off, every press goes straight through and `readline` is the
    /// editor again — the behaviour every other terminal has, and the escape hatch for a shell whose
    /// own line editor the user would rather keep (vi-mode zsh, a custom ZLE widget set).
    ///
    /// It gates ARMING only. A prompt that is already mid-edit when the setting flips keeps its text
    /// until it is submitted or cleared, because dropping a half-typed command to honour a preference
    /// is a worse answer than finishing it.
    public static var commandPromptEnabled: Bool { AppConfig.current.flag("controls.command-prompt") }

    // MARK: - Links

    /// Detect paths and URLs in terminal output and underline them on ⌘-hover
    /// (`controls.link-detection`), default ON. Turn OFF when a TUI's mouse reporting conflicts with
    /// the detection overlay.
    public static var linkDetectionEnabled: Bool { AppConfig.current.flag("controls.link-detection") }

    /// What a ⌘click on a detected link does (`controls.link-cmd-click`), default ``LinkCmdClick/open``.
    public static var linkCmdClick: LinkCmdClick {
        AppConfig.current.choice("controls.link-cmd-click", LinkCmdClick.open)
    }

    /// What a ⌘⇧click on a detected link does (`controls.link-cmd-shift-click`), default
    /// ``LinkCmdShiftClick/revealFinder``.
    public static var linkCmdShiftClick: LinkCmdShiftClick {
        AppConfig.current.choice("controls.link-cmd-shift-click", LinkCmdShiftClick.revealFinder)
    }

    /// Which URL schemes are underlined and clickable (`controls.auto-detect-link-schemes`), default
    /// ``AutoDetectLinkSchemes/all``. `http(s)` / `file` / `mailto` are always detected.
    public static var autoDetectLinkSchemes: AutoDetectLinkSchemes {
        AppConfig.current.choice("controls.auto-detect-link-schemes", AutoDetectLinkSchemes.all)
    }

    /// The resolved ``LinkSchemePolicy`` the detector consumes — bridges the mode and the custom list
    /// into the detector's richer policy. The ONE seam the ⌘-hold underline / Jump-To / Hint Mode
    /// read, so the scheme setting is applied in exactly one place.
    public static var linkSchemePolicy: LinkSchemePolicy {
        switch autoDetectLinkSchemes {
        case .all: .all
        case .custom: .custom(AppConfig.current.list("controls.custom-link-schemes"))
        }
    }

    /// The resolved user Hint Mode patterns — the parallel `controls.hint-patterns` /
    /// `controls.hint-pattern-actions` lists, zipped by
    /// ``PreferenceRules/hintPatterns(_:actions:)``, which is where the three cases the file's shape
    /// cannot express live. The ONE seam Hint Mode reads.
    public static var hintPatternList: [HintPattern] {
        PreferenceRules.hintPatterns(
            AppConfig.current.list("controls.hint-patterns"),
            actions: AppConfig.current.list("controls.hint-pattern-actions"),
        )
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
///
/// The PRECEDENCE is ``PreferenceRules/stateSuite(testProcess:environment:)``: the XCTest per-pid
/// suite first (a stray `SLOPDESK_DEFAULTS_SUITE` in the environment must never put parallel xctest
/// workers back on one domain), then the environment, then nothing — and an empty environment value
/// is unset, because `FOO="${BAR}"` with `BAR` unset is how a shell delivers one by accident and
/// `UserDefaults(suiteName: "")` is not a store anybody meant to name.
private let resolvedSuiteName: String? = PreferenceRules.stateSuite(
    testProcess: testProcessSuiteName,
    environment: ProcessInfo.processInfo.environment[SettingsKey.defaultsSuiteEnvKey],
)

private extension Defaults.Key {
    /// Builds every SlopDesk state key against ``SettingsKey/store`` (`.standard` in the app; a
    /// per-process wiped suite under XCTest) so no key can silently bind a different suite.
    convenience init(slopDesk name: String, default defaultValue: Value) {
        self.init(name, default: defaultValue, suite: SettingsKey.store)
    }
}

// MARK: - The four typed STATE keys

/// The typed ``Defaults`` keys for the app's own persisted state. Four, all written by the app: the
/// window frame it last had, the code panel's collapse and width, and the projects whose workbench
/// the user already opened. Nothing here is a user PREFERENCE — those live in `config.toml`, which
/// the app never writes.
public extension Defaults.Keys {
    static let codeSidebarCollapsed = Key<Bool>(slopDesk: SettingsKey.codeSidebarCollapsedKey, default: true)
    static let codeSidebarWidth = Key<Double>(slopDesk: SettingsKey.codeSidebarWidthKey, default: 0)
    static let openedCodeProjects = Key<Set<String>>(slopDesk: SettingsKey.openedCodeProjectsKey, default: [])
    static let savedWindowFrame = Key<String>(slopDesk: SettingsKey.windowSavedFrameKey, default: "")
}
