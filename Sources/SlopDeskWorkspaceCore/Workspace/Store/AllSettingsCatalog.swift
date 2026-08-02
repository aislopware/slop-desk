import Foundation
import SlopDeskWorkspaceModel

// MARK: - AllSettingsCatalog (headless source for the Advanced "All Settings" list)

/// The pure, headless catalog the Advanced → **All Settings** list iterates (see
/// `customization__advanced-settings.md`). It enumerates every client-side configuration key slopdesk
/// understands — the orphan + new fire-time `SettingsKey` toggles, the Shell/General pickers, and the
/// typed-model render fields (font / cursor / theme) that have a richer dedicated tab — together with the
/// metadata each row renders: a monospace `key`, a human `label`, a short `description`, the `defaultText`,
/// the rendering `bucket`, and a free-text `keywords` blob the search field matches.
///
/// PURE / no SwiftUI: this lives in `SlopDeskWorkspaceCore` so `AllSettingsCatalogTests` can pin the
/// filter, the full-coverage anti-drift, and the buckets with NO view. The view layer
/// (`AllSettingsListView`) owns the actual `Defaults.Key` bindings + the cross-tab jump; this only describes
/// WHAT to render, never HOW.
///
/// GOLDEN-SAFE: the catalog is metadata only — it never reads/writes a value, never touches the wire codecs
/// or the env overlay. The `key` strings reuse the ``SettingsKey`` namespace constants (the one source of
/// truth) so a rename that would split-brain the list from the fire-sites fails the catalog tests.
public enum AllSettingsCatalog {
    /// One row in the All Settings list.
    public struct SettingEntry: Equatable, Identifiable, Sendable {
        /// How the row is edited — the distinction between an inline-editable expert key and a key with
        /// a richer dedicated tab control.
        public enum Bucket: Equatable, Sendable {
            /// No richer tab UI (or a simple flag) — render an INLINE control (toggle / stepper / picker)
            /// bound to the key. Edits apply live, identical to hand-editing the config.
            ///
            /// NOTE: this bucket is a pure RENDERING hint for the All-Settings list ("inline editor vs
            /// jump-to-tab button") — it is NOT a "reset bucket". Many `.advancedOnly`-rendered keys (e.g.
            /// `copyOnSelect`, `oscNotifications`, `newTabPosition`) ALSO have a dedicated tab and are
            /// therefore tab-reachable, so they are PRESERVED by ``PreferencesStore/resetAdvancedOnly()``.
            /// Do not conflate "rendered inline here" with "is an advanced-only key" — the reset scope lives
            /// in ``PreferencesStore``, not in this bucket.
            case advancedOnly
            /// A richer control lives on a dedicated tab — render the current value + a ✎ button that jumps
            /// to that tab (the destination is ``SettingEntry/targetSection``).
            case hasDedicatedTab
        }

        /// The monospace config key shown in the row (an slopdesk ``SettingsKey`` constant, or an
        /// config-style render-pref name like `font-family` for a typed-model field).
        public let key: String
        /// The human-readable label (search-matched).
        public let label: String
        /// A one-line description (search-matched; rendered gray beneath the key).
        public let description: String
        /// The default value rendered as `· Default: …` after the description.
        public let defaultText: String
        /// Whether the row is inline-editable or jumps to a dedicated tab.
        public let bucket: Bucket
        /// For ``Bucket/hasDedicatedTab``: the `SettingsSection` rawValue to jump to (e.g. `"editor"`). `nil`
        /// for ``Bucket/advancedOnly`` (kept as a String so this headless catalog never imports the UI's
        /// `SettingsSection`).
        public let targetSection: String?
        /// Extra free-text the search field matches against (synonyms not in the label/description).
        public let keywords: String

        public var id: String { key }

        public init(
            key: String,
            label: String,
            description: String,
            defaultText: String,
            bucket: Bucket,
            targetSection: String? = nil,
            keywords: String = "",
        ) {
            self.key = key
            self.label = label
            self.description = description
            self.defaultText = defaultText
            self.bucket = bucket
            self.targetSection = targetSection
            self.keywords = keywords
        }
    }

    /// The config-style name the shared-focus row (``DevicePreferences/followSessionFocus``, docs/45 §8.2)
    /// is filed under. NOT a ``SettingsKey``: the value lives in `device-prefs.json`, not `UserDefaults`,
    /// so it is named here the way the typed render fields (`font-family`, `cursor-style`) are — and named
    /// ONCE, so the catalog row and the view that renders the real control cannot split-brain.
    public static let followSessionFocusKey = "follow-session-focus"

    /// The advertised rows that persist OUTSIDE `UserDefaults` — the DEVICE-LOCAL facts in
    /// `device-prefs.json` (docs/45 §7.3), owned by ``WorkspaceStore``.
    ///
    /// `Defaults.reset(_:)` cannot reach them, and no typed model in ``PreferencesStore`` holds them
    /// either, so a Reset All restores them through ``WorkspaceStore/resetDeviceLocalSettings()`` —
    /// which is what ``PreferencesStore/resetEverySetting(deviceLocal:)`` calls. Named here, beside
    /// the rows themselves, so `AllSettingsCatalogTests` can bind the three reset surfaces to the one
    /// list of advertised keys: a row that belongs to none of them fails there rather than quietly
    /// outliving the reset the panel just promised.
    public static let deviceLocalKeys: Set<String> = [followSessionFocusKey]

    /// The advertised rows ``PreferencesStore/resetAll()`` restores WITHOUT a global `Defaults.Key`,
    /// so they can never appear in either reset key set. Two kinds:
    ///
    /// - the typed RENDER FIELDS — `resetAll()` replaces ``PreferencesStore/terminal`` and
    ///   ``PreferencesStore/appearance`` wholesale, and `font-family` and friends come back with the
    ///   model. They are config-style pseudo-keys exactly as they render: they name a field, not a
    ///   `UserDefaults` entry;
    /// - `appearance.density`, which `resetAll()` clears BY NAME from the store's own injected
    ///   defaults suite (the per-instance store that keeps tests isolated).
    ///
    /// `AllSettingsCatalogTests` uses this to tell "restored by `PreferencesStore` another way" apart
    /// from "restored by nobody".
    public static let modelBackedKeys: Set<String> = [
        "font-family", "font-size", "scrollback-limit",
        "cursor-style", "cursor-style-blink", "theme",
        SettingsKey.density,
    ]

    /// Every client-side configuration key, in a readable section order (General → Shell → Controls →
    /// Editor → Appearance → Agents, then the typed render fields). The list is the single source the All
    /// Settings view iterates; `AllSettingsCatalogTests.testCatalogCoversEveryClientSettingsKey` pins that no
    /// surfaced ``SettingsKey`` is dropped.
    public static let entries: [SettingEntry] = [
        // MARK: General

        SettingEntry(
            key: SettingsKey.onLaunchKey,
            label: "On Launch",
            description: "Restore the last session or open a fresh window when the app starts.",
            defaultText: "Restore Last Session",
            bucket: .advancedOnly,
            keywords: "launch startup restore session new window open",
        ),
        SettingEntry(
            key: SettingsKey.redactSecrets,
            label: "Redact Secrets",
            description: "Mask likely secrets in window titles and notification bodies.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "privacy secret redact mask token password api key",
        ),
        SettingEntry(
            key: SettingsKey.closeConfirmTabKey,
            label: "Close Confirmation · Tab",
            description: "When to confirm before closing a tab. ⌘W closes a pane and only asks mid-command.",
            defaultText: "Running Process",
            bucket: .advancedOnly,
            keywords: "close confirm tab pane prompt quit running process always",
        ),
        SettingEntry(
            key: SettingsKey.closeConfirmWindowKey,
            label: "Close Confirmation · Window",
            description: "When to confirm before closing a window.",
            defaultText: "Running Process",
            bucket: .advancedOnly,
            keywords: "close confirm window prompt quit running process always",
        ),
        // Device-local, not a `Defaults.Key` — it persists in `device-prefs.json` and is written through
        // `WorkspaceStore.setFollowSessionFocus(_:)`. So it is `.hasDedicatedTab`: the row advertises the
        // key + its live value and JUMPS to General → Shared Focus, where the one real control lives.
        SettingEntry(
            key: followSessionFocusKey,
            label: "Follow the Shared Focus",
            description: "Whether switching tab or pane on this device moves every device that follows, "
                + "or only this one's own view.",
            defaultText: DevicePreferences.platformDefaultFollowSessionFocus ? "On" : "Off",
            bucket: .hasDedicatedTab,
            targetSection: "general",
            keywords: "focus follow shared device local multi client mirror sync tab pane independent",
        ),

        // MARK: Shell (notifications — notification-setting.png — + working directory — window-tab-split spec)

        SettingEntry(
            key: SettingsKey.oscNotifications,
            label: "Explicit Notifications",
            description: "Post OSC 9 / OSC 777 notifications emitted by the terminal.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "notification osc bell alert badge shell",
        ),
        SettingEntry(
            key: SettingsKey.longCommandNotifications,
            label: "Long-Command Notification",
            description: "Notify when a long-running command finishes in an unfocused pane.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "notification command complete long running done shell",
        ),

        // Fire-time toggles; the pure NotificationPolicy reads the resolved `notificationSettings`
        // bundle. The rich navigator panel surfaces these too; declared here so the searchable All
        // Settings list is complete + round-trips.
        SettingEntry(
            key: SettingsKey.notifyOnFinish,
            label: "Notify on Command Finish",
            description: "Notify when a background command finishes.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "notification command finish complete exit success shell background",
        ),
        SettingEntry(
            key: SettingsKey.notifyOnError,
            label: "Notify on Error Exit",
            description: "Notify when a command fails (exits non-zero).",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "notification command error fail exit non-zero shell",
        ),
        SettingEntry(
            key: SettingsKey.notifyOnWatchFinish,
            label: "Notify on Watch Finish",
            description: "Notify when an `slopdesk watch`-wrapped command finishes.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "notification watch finish command wrapped shell",
        ),
        SettingEntry(
            key: SettingsKey.notifyWhileForegroundKey,
            label: "Notify While Foreground",
            description: "Banner behavior while the app is the foreground app — off, always, or only when "
                + "the source tab is unfocused.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "notification foreground banner frontmost tab unfocused while active",
        ),
        SettingEntry(
            key: SettingsKey.bounceDockIcon,
            label: "Bounce Dock Icon",
            description: "Bounce the Dock icon when a notification arrives and the app isn't focused.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "notification dock bounce attention macos icon request",
        ),
        SettingEntry(
            key: SettingsKey.soundShellControlled,
            label: "Sound — Shell Controlled",
            description: "Let shell apps ring the terminal bell (BEL) as the system alert sound.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "sound bell beep audio shell controlled alert nssound",
        ),
        SettingEntry(
            key: SettingsKey.soundOnErrorExit,
            label: "Sound on Error Exit",
            description: "Beep when a command exits non-zero (requires shell integration).",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "sound error exit beep non-zero fail shell integration",
        ),
        SettingEntry(
            key: SettingsKey.agentNotifyTaskComplete,
            label: "Code Agent — Notify When Task Completes",
            description: "Notify when a coding agent finishes a task and goes idle.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "agent claude notification task complete done idle code",
        ),
        SettingEntry(
            key: SettingsKey.agentNotifyAwaitInput,
            label: "Code Agent — Notify When Awaiting Input",
            description: "Notify when a coding agent needs approval or input.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "agent claude notification awaiting input approval permission code",
        ),
        SettingEntry(
            key: SettingsKey.agentSoundTaskComplete,
            label: "Code Agent — Sound When Task Completes",
            description: "Play a sound when a coding agent finishes in an unfocused pane.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "agent claude sound task complete done finish submarine audio macos code",
        ),
        SettingEntry(
            key: SettingsKey.agentSoundAwaitInput,
            label: "Code Agent — Sound When Awaiting Input",
            description: "Play a sound when a coding agent needs approval or input.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "agent claude sound awaiting input approval permission glass audio macos code",
        ),

        SettingEntry(
            key: SettingsKey.workingDirectoryNewWindowKey,
            label: "Working Directory · New Window",
            description: "Where a new window opens — the home directory or the active pane's directory.",
            defaultText: "Home Directory",
            bucket: .advancedOnly,
            keywords: "working directory cwd folder window home inherit same",
        ),
        SettingEntry(
            key: SettingsKey.workingDirectoryNewTabKey,
            label: "Working Directory · New Tab",
            description: "Where a new tab opens — the home directory or the active pane's directory.",
            defaultText: "Same as Current",
            bucket: .advancedOnly,
            keywords: "working directory cwd folder tab home inherit same",
        ),
        SettingEntry(
            key: SettingsKey.workingDirectoryNewSplitKey,
            label: "Working Directory · New Split",
            description: "Where a new split opens — the home directory or the active pane's directory.",
            defaultText: "Same as Current",
            bucket: .advancedOnly,
            keywords: "working directory cwd folder split home inherit same",
        ),

        // MARK: Controls (copy / paste / mouse / scroll fire-time flags)

        SettingEntry(
            key: SettingsKey.paneSwitcherPreview,
            label: "Preview While Switching Panes",
            description: "As ⌃⇥ walks the pane list, show each pane underneath the switcher.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "pane tab switcher control ctrl preview follow highlight cycle mru",
        ),
        SettingEntry(
            key: SettingsKey.copyOnSelect,
            label: "Copy on Select",
            description: "Copy the selection to the pasteboard as soon as it is made.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "copy select clipboard pasteboard mouse selection",
        ),
        SettingEntry(
            key: SettingsKey.trimTrailingSpacesOnCopy,
            label: "Trim Trailing Spaces on Copy",
            description: "Strip trailing whitespace from each copied line.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "copy trim trailing whitespace space clipboard",
        ),
        SettingEntry(
            key: SettingsKey.pasteProtection,
            label: "Paste Protection",
            description: "Warn before pasting text that contains a newline or control character.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "paste protection clipboard safety bracketed newline",
        ),
        SettingEntry(
            key: SettingsKey.mouseHideWhileTyping,
            label: "Hide Mouse While Typing",
            description: "Hide the pointer while typing into a pane.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "mouse hide typing pointer",
        ),
        SettingEntry(
            key: SettingsKey.focusFollowsMouse,
            label: "Focus Follows Mouse",
            description: "Focus the pane the pointer is over without a click.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "focus follows mouse hover pane pointer",
        ),
        SettingEntry(
            key: SettingsKey.scrollMultiplier,
            label: "Scroll Multiplier",
            description: "Multiply the scroll-wheel delta.",
            defaultText: "1.00×",
            bucket: .advancedOnly,
            keywords: "scroll multiplier wheel speed mouse sensitivity",
        ),

        // The remaining Controls / Mouse / Scroll knobs; declared here so the Advanced list is complete
        // and the keys round-trip today.
        SettingEntry(
            key: SettingsKey.clearSelectionOnTyping,
            label: "Clear Selection on Typing",
            description: "Clear the selection when the user starts typing.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "selection clear typing keyboard input",
        ),
        SettingEntry(
            key: SettingsKey.clearSelectionOnCopy,
            label: "Clear Selection on Copy",
            description: "Clear the selection after an explicit copy.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "selection clear copy clipboard",
        ),
        SettingEntry(
            key: SettingsKey.shiftArrowSelect,
            label: "Shift+Arrow Select",
            description: "Use Shift+arrows to drive native selection instead of forwarding arrow escapes.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "shift arrow select selection keyboard extend",
        ),
        SettingEntry(
            key: SettingsKey.pasteBracketedSafe,
            label: "Paste Bracketed Safe",
            description: "Treat a bracketed paste as safe, skipping the warning when the program supports it.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "paste bracketed safe protection clipboard",
        ),
        SettingEntry(
            key: SettingsKey.clipboardReadKey,
            label: "Clipboard Read (OSC 52)",
            description: "Whether a program may READ the clipboard via OSC 52.",
            defaultText: "Ask",
            bucket: .advancedOnly,
            keywords: "clipboard read osc 52 access allow deny ask paste",
        ),
        SettingEntry(
            key: SettingsKey.clipboardWriteKey,
            label: "Clipboard Write (OSC 52)",
            description: "Whether a program may WRITE the clipboard via OSC 52.",
            defaultText: "Allow",
            bucket: .advancedOnly,
            keywords: "clipboard write osc 52 access allow deny ask copy",
        ),
        SettingEntry(
            key: SettingsKey.allowMouseCapture,
            label: "Allow Mouse Capture",
            description: "Allow shell apps to capture mouse events (e.g. vim, tmux).",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "mouse capture reporting vim tmux htop program",
        ),
        SettingEntry(
            key: SettingsKey.allowShiftClickKey,
            label: "Allow Shift with Mouse Click",
            description: "Hold Shift to select text even when the running app captures the mouse.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "shift mouse click capture selection bypass",
        ),
        SettingEntry(
            key: SettingsKey.clickToMove,
            label: "Cursor Click-to-Move",
            description: "Click in the prompt to move the shell cursor, across soft-wrapped rows.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "cursor click move prompt arrow keys soft wrap",
        ),
        SettingEntry(
            key: SettingsKey.undoAtPrompt,
            label: "Undo at Prompt",
            description: "Cmd-Z at the shell prompt emits the readline undo sequence.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "undo prompt readline cmd z line edit",
        ),
        SettingEntry(
            key: SettingsKey.rightClickActionKey,
            label: "Right-Click Action",
            description: "What right-click does in the viewport (Ctrl+right-click always opens the menu).",
            defaultText: "Context Menu",
            bucket: .advancedOnly,
            keywords: "right click action menu copy paste ignore mouse",
        ),
        SettingEntry(
            key: SettingsKey.optionAsAltKey,
            label: "Option as Alt",
            description: "Treat the macOS Option key as Alt/Meta so terminal apps see Esc-prefixed sequences; "
                + "off keeps Option free for accented characters.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "option alt meta esc keyboard macos key word jump emacs vim readline accented",
        ),

        // Path/link detection (Settings → Controls → Open With / Link Schemes). Declared here so
        // the Advanced "All Settings" list is complete.
        SettingEntry(
            key: SettingsKey.linkDetection,
            label: "Detect Links & Paths",
            description: "Detect paths and URLs in terminal output and underline them on Cmd-hover.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "link path url detect underline hover open clickable hyperlink osc 8",
        ),
        SettingEntry(
            key: SettingsKey.linkCmdClickKey,
            label: "Cmd-Click on Link",
            description: "What Cmd+click on a detected link does — open in the best handler, copy, or nothing.",
            defaultText: "Open",
            bucket: .advancedOnly,
            keywords: "link cmd click open copy nothing url path open with handler",
        ),
        SettingEntry(
            key: SettingsKey.linkCmdShiftClickKey,
            label: "Cmd-Shift-Click on Link",
            description: "What Cmd+Shift+click on a detected link does — reveal on the host, or open with the "
                + "system default.",
            defaultText: "Reveal in Finder",
            bucket: .advancedOnly,
            keywords: "link cmd shift click reveal finder open system default host",
        ),
        SettingEntry(
            key: SettingsKey.autoDetectLinkSchemesKey,
            label: "Auto-Detect Link Schemes",
            description: "Which URL schemes are underlined and clickable. All detects any scheme://; Custom "
                + "restricts to your list. http(s), file, and mailto are always detected.",
            defaultText: "All",
            bucket: .advancedOnly,
            keywords: "link scheme url detect custom all http https file mailto codex ssh vscode",
        ),
        SettingEntry(
            key: SettingsKey.customLinkSchemes,
            label: "Custom Link Schemes",
            description: "Extra URL schemes to detect when Auto-Detect is set to Custom (e.g. codex, ssh, "
                + "vscode).",
            defaultText: "None",
            bucket: .advancedOnly,
            keywords: "custom link scheme url codex ssh vscode additional detect",
        ),
        // Auto Progress-Bar Commands (terminal-features__progress-state.md). Advanced list key;
        // the host enforces its own copy via the SLOPDESK_AUTO_PROGRESS_COMMANDS env bridge.

        // Privilege surface (terminal-features__notifications.md → Settings → Advanced). The
        // OSC-52 read/write tri-state pickers (clipboardReadKey/clipboardWriteKey, above) are gated by the
        // Clipboard — Shell Controlled master; Title — Shell Controlled gates OSC 0/2; Title Report is a
        // documented ceiling (persists/surfaces but does not yet actuate — see docs/DECISIONS.md).
        SettingEntry(
            key: SettingsKey.titleShellControlled,
            label: "Title — Shell Controlled",
            description: "Allow programs to set the tab and window title via OSC 0 / OSC 2.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "title shell controlled osc 0 2 window tab name privilege",
        ),
        SettingEntry(
            key: SettingsKey.clipboardShellControlled,
            label: "Clipboard — Shell Controlled",
            description: "Master switch for OSC 52 clipboard access. When off, both clipboard read and write "
                + "are denied regardless of the per-direction setting.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "clipboard shell controlled osc 52 master read write privilege deny",
        ),

        // IPC guards on the agent-control ctl socket (privilege surface → Settings → Advanced). The
        // ENFORCEMENT is HOST-side (the guard runs on the host's NDJSON ctl socket); these client toggles are
        // the edit surface and re-drive the host via the SLOPDESK_IPC_ALLOW_* env bridge on the next launch.

        // MARK: Appearance (New Tab Position + chrome orphan toggles)

        // New Tab Position lives under **Appearance** in a TABS group (`tab-setting.png`), NOT Shell.
        SettingEntry(
            key: SettingsKey.newTabPositionKey,
            label: "New Tab Position",
            description: "Where a new tab is inserted in the active session's tab bar.",
            defaultText: "Automatic",
            bucket: .advancedOnly,
            keywords: "tab position new placement order end after current appearance",
        ),
        // The DOCK ICON group lives under **Appearance** (terminal-features__progress-state.md). macOS-only
        // NSDockTile behaviour (inert on iOS); the live toggles live under Appearance → Dock Icon, so the
        // searchable All Settings rows JUMP there (`hasDedicatedTab` → `appearance`) rather than rendering
        // a duplicate inline control. The keys round-trip on both platforms.
        SettingEntry(
            key: SettingsKey.dockIconAnimateProgress,
            label: "Animate Dock Icon During Progress",
            description: "Animate the macOS Dock icon while any session reports OSC 9;4 progress.",
            defaultText: "Off",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "dock icon animate progress macos appearance osc 9 4 spinner",
        ),
        SettingEntry(
            key: SettingsKey.dockIconErrorBadge,
            label: "Red Icon on Error",
            description: "Tint the macOS Dock icon red on a non-zero exit; clicking jumps to the next failing tab.",
            defaultText: "On",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "dock icon red error badge tint exit failing tab macos appearance",
        ),

        // MARK: Agents behaviour toggles

        SettingEntry(
            key: SettingsKey.autoSwitchLayouts,
            label: "Auto-Switch Layouts",
            description: "Switch to a layout when its trigger app launches on the host.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "layout switch trigger app auto agent",
        ),
        SettingEntry(
            key: SettingsKey.recordClipboardHistory,
            label: "Record Clipboard History",
            description: "Archive copied text into the clipboard-history ring.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "clipboard history record paste recent ring",
        ),

        // MARK: Typed render fields with a richer dedicated tab (jump-to-tab)

        // FONT FAMILY + the CURSOR group live under **Appearance**
        // (`docs/ui-shell/screenshots/font-setting.png`, `cursor-style.png`); SCROLLBACK lives under
        // **Controls → Scroll** (`spec/terminal-features__scroll.md`). There is no Editor section — slopdesk
        // has no built-in file editor, so nothing routes there.
        SettingEntry(
            key: "font-family",
            label: "Font Family",
            description: "The terminal font family.",
            defaultText: "SF Mono",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "font family typeface monospace appearance",
        ),
        SettingEntry(
            key: "font-size",
            label: "Font Size",
            description: "The terminal font point size.",
            defaultText: "13",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "font size point appearance zoom",
        ),
        SettingEntry(
            key: "scrollback-limit",
            label: "Scrollback Lines",
            description: "The terminal scrollback buffer size, in lines.",
            defaultText: "10000",
            bucket: .hasDedicatedTab,
            targetSection: "controls",
            keywords: "scrollback lines buffer history controls scroll",
        ),
        SettingEntry(
            key: "cursor-style",
            label: "Cursor Style",
            description: "The terminal cursor style.",
            defaultText: "Block",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "cursor style block hollow bar underline appearance",
        ),
        SettingEntry(
            key: "cursor-style-blink",
            label: "Cursor Blink",
            description: "Whether the terminal cursor blinks. Default defers to DEC mode 12.",
            defaultText: "Default",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "cursor blink appearance",
        ),
        SettingEntry(
            key: "theme",
            label: "Theme",
            description: "The client chrome and terminal colour theme.",
            defaultText: "System",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "theme appearance colour color palette monokai dark light",
        ),
        SettingEntry(
            key: SettingsKey.density,
            label: "Density",
            description: "The UI density tier.",
            defaultText: "Comfortable",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "density appearance compact comfortable spacing tier",
        ),
    ]

    /// The `.advancedOnly` keys that `AllSettingsListView` renders with a real INLINE editor (toggle /
    /// picker / stepper / live summary) — the contract the view's `inlineControl(for:)` switch must cover.
    /// Kept in lockstep with that switch (any key listed here has a case; any `.advancedOnly` catalog row
    /// missing from here would fall to the view's `default:` arm = a DEAD static default-value label with no
    /// control). `AllSettingsCatalogTests.testEveryAdvancedOnlyRowHasInlineControl` pins that this set covers
    /// EVERY `.advancedOnly` entry, so a newly-added advanced row without an inline control fails the gate.
    /// Lives here (pure, headless) so the contract is testable without instantiating the SwiftUI view.
    public static let inlineEditableKeys: Set<String> = [
        // General
        SettingsKey.onLaunchKey, SettingsKey.redactSecrets,
        SettingsKey.closeConfirmTabKey, SettingsKey.closeConfirmWindowKey,
        // Shell — notifications / sounds / agent-notify
        SettingsKey.oscNotifications, SettingsKey.longCommandNotifications,
        SettingsKey.notifyOnFinish, SettingsKey.notifyOnError, SettingsKey.notifyOnWatchFinish,
        SettingsKey.notifyWhileForegroundKey, SettingsKey.bounceDockIcon,
        SettingsKey.soundShellControlled, SettingsKey.soundOnErrorExit,
        SettingsKey.agentNotifyTaskComplete, SettingsKey.agentNotifyAwaitInput,
        SettingsKey.agentSoundTaskComplete, SettingsKey.agentSoundAwaitInput,
        // Shell — working directory
        SettingsKey.workingDirectoryNewWindowKey, SettingsKey.workingDirectoryNewTabKey,
        SettingsKey.workingDirectoryNewSplitKey,
        // Controls — selection / copy / paste
        SettingsKey.copyOnSelect, SettingsKey.trimTrailingSpacesOnCopy, SettingsKey.pasteProtection,
        SettingsKey.pasteBracketedSafe, SettingsKey.clearSelectionOnTyping, SettingsKey.clearSelectionOnCopy,
        SettingsKey.shiftArrowSelect,
        // Controls — mouse / scroll
        SettingsKey.mouseHideWhileTyping, SettingsKey.focusFollowsMouse, SettingsKey.scrollMultiplier,
        SettingsKey.paneSwitcherPreview,
        SettingsKey.allowMouseCapture, SettingsKey.allowShiftClickKey, SettingsKey.clickToMove,
        SettingsKey.rightClickActionKey, SettingsKey.optionAsAltKey, SettingsKey.undoAtPrompt,
        // Controls — links
        SettingsKey.linkDetection, SettingsKey.linkCmdClickKey, SettingsKey.linkCmdShiftClickKey,
        SettingsKey.autoDetectLinkSchemesKey, SettingsKey.customLinkSchemes,
        // Advanced — privilege gates + OSC-52 master + read/write
        SettingsKey.clipboardReadKey, SettingsKey.clipboardWriteKey, SettingsKey.titleShellControlled,
        SettingsKey.clipboardShellControlled,
        // Appearance + Agents
        SettingsKey.newTabPositionKey,
        SettingsKey.autoSwitchLayouts, SettingsKey.recordClipboardHistory,
    ]

    /// Filter the catalog by a search query, matching (case-insensitively) against the key, label,
    /// description, and keywords (a substring filter, not fuzzy; the spec narrows on `cursor` / `scrollback`
    /// / `blink`). An empty / whitespace query returns ALL entries (order-preserving); a no-match query
    /// returns `[]`.
    public static func filter(_ query: String) -> [SettingEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            entry.key.lowercased().contains(needle)
                || entry.label.lowercased().contains(needle)
                || entry.description.lowercased().contains(needle)
                || entry.keywords.lowercased().contains(needle)
        }
    }
}
