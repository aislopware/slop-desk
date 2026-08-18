//! Every client-side setting, as a ROW: its key, its words, its default and where it is edited.
//!
//! This is the other half of what a settings page is made of. [`crate::settings_catalog`] answers
//! "what can this be set TO"; this answers "what IS this, and what does it say about itself" — one
//! entry per configuration key slopdesk understands, carrying the monospace key, the human label,
//! the one-line description, the default rendered after it, and whether the row is edited inline or
//! defers to a richer control on a dedicated section.
//!
//! ## Why it left Swift, and what that fixed
//!
//! It was already a headless Swift table, lifted out of the view for the right reason. What the
//! lift did not notice is that the words were lifted TWICE. `AllSettingsCatalog` held
//! `"Copy on Select"` / `"Copy the selection to the pasteboard as soon as it is made."` for the
//! searchable list, and the Controls page's own toggle row held the same two strings again, byte
//! for byte, in a different target. Thirty-one labels and fifteen descriptions were duplicated that
//! way — not drifted yet, but with nothing anywhere that would notice when they did. A row's label
//! is the same sentence wherever the row appears, so it is one string, and this is where it lives.
//!
//! ## What did NOT cross
//!
//! The KEYS are `SettingsKey` constants on the Swift side, because they are `Defaults.Key` names
//! and a `UserDefaults` binding cannot leave Swift. They are quoted here for the same reason the
//! option tokens are: they are already on disk. `AllSettingsCatalogTests` is what pins the two
//! spellings together — every key here must be a surfaced `SettingsKey`, and every surfaced
//! `SettingsKey` must have a row — which needs the Swift namespace and therefore stays a Swift
//! test.
//!
//! Likewise [`Bucket::HasDedicatedTab`]'s `target_section` is a section id rather than a typed
//! section: this table names where to jump, and the near side's dispatch enum is what turns an id
//! into a view.
//!
//! ## The one row whose default is not a constant
//!
//! `follow-session-focus` defaults ON for a desktop and OFF for a phone (docs/45 §8.2) — a phone
//! attaches to LOOK at one session, a desktop attaches to WORK and expects the host's focus to
//! lead. That is a compile-time platform fact on both sides of the boundary, and the boundary is
//! compiled once per slice, so [`FOLLOW_SESSION_FOCUS_DEFAULT`] answers it with `cfg` exactly as
//! `DevicePreferences.platformDefaultFollowSessionFocus` does with `#if`. The two must agree, and a
//! Swift test asserts they do rather than a comment asking them to.

/// How a row is EDITED — the distinction between an expert key with an inline control and a key
/// whose real control lives on a dedicated section.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bucket {
    /// No richer section control (or a simple flag): render an inline editor bound to the key.
    ///
    /// This is a RENDERING hint, not a reset scope. Many rows rendered inline also have a dedicated
    /// section control and are therefore preserved by an advanced-only reset; conflating the two is
    /// the mistake the Swift original warned about, and the warning is kept here.
    AdvancedOnly,
    /// A richer control lives on a section: render the current value plus a jump to
    /// [`SettingRow::target_section`].
    HasDedicatedTab,
}

impl Bucket {
    /// The case index a bucket crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::AdvancedOnly => 0,
            Self::HasDedicatedTab => 1,
        }
    }
}

/// One row in the all-settings list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SettingRow {
    /// The monospace configuration key — a `SettingsKey` constant, or a config-style render-field
    /// name like `font-family` for a typed model field that is not a `UserDefaults` entry.
    pub key: &'static str,
    /// The human label as the flat INDEX shows it — standalone, and qualified where it needs to be,
    /// because the all-settings list has no section header above it to supply the context.
    /// Searched.
    pub label: &'static str,
    /// The label a PAGE shows, where a page header already supplies what [`SettingRow::label`] has
    /// to spell out. Empty means the two are the same string, which is the common case.
    ///
    /// This is the same register split as the description (see the module doc), reaching the label
    /// for the minority of rows where it does. Under a `Close Confirmation` header,
    /// `Close Confirmation · Tab` stutters and `Closing a tab` is the row's name; in a list of
    /// fifty-seven keys with no header, the second one names nothing. Read it through
    /// [`SettingRow::page_label`], never directly — a renderer that reads the field sees an empty
    /// string for most rows.
    pub page_label: &'static str,
    /// The one-line description, rendered under the key. Searched.
    pub description: &'static str,
    /// The default, rendered after the description.
    pub default_text: &'static str,
    /// How the row is edited.
    pub bucket: Bucket,
    /// For [`Bucket::HasDedicatedTab`], the section id to jump to. Empty otherwise.
    pub target_section: &'static str,
    /// Extra searchable text — synonyms that are in neither the label nor the description.
    pub keywords: &'static str,
    /// Whether the all-settings list renders a real inline editor for this row.
    ///
    /// Only meaningful for [`Bucket::AdvancedOnly`]. It is the contract the near side's
    /// `inlineControl(for:)` switch must cover: a row marked here with no case in that switch falls
    /// to its default arm, which is a dead value label with no control, and a row NOT marked here
    /// that the switch handles is a control nobody reaches.
    pub inline_editable: bool,
}

impl SettingRow {
    /// The label to render on a settings PAGE — the page form where the row has one, the index form
    /// otherwise.
    #[must_use]
    pub const fn page_label(&self) -> &'static str {
        if self.page_label.is_empty() {
            self.label
        } else {
            self.page_label
        }
    }
}

/// The `follow-session-focus` default, as the slice it is compiled for reads it.
#[cfg(target_os = "ios")]
pub const FOLLOW_SESSION_FOCUS_DEFAULT: &str = "Off";
/// The `follow-session-focus` default, as the slice it is compiled for reads it.
#[cfg(not(target_os = "ios"))]
pub const FOLLOW_SESSION_FOCUS_DEFAULT: &str = "On";

/// The key the shared-focus row is filed under. NOT a `SettingsKey`: the value lives in
/// `device-prefs.json`, not `UserDefaults`, so it is named the way the typed render fields are.
pub const FOLLOW_SESSION_FOCUS_KEY: &str = "follow-session-focus";

/// The advertised rows that persist OUTSIDE `UserDefaults` — the device-local facts a global
/// defaults reset cannot reach, restored through the workspace store instead.
pub const DEVICE_LOCAL_KEYS: &[&str] = &[FOLLOW_SESSION_FOCUS_KEY];

/// The advertised rows a reset restores WITHOUT a global defaults key.
///
/// The typed render fields come back with the model they belong to, and the density token is
/// cleared by name from the store's own injected suite. Neither can appear in a reset key set, and
/// a row in neither those sets nor this one is a row nothing restores.
pub const MODEL_BACKED_KEYS: &[&str] = &[
    "agent-prevent-sleep",
    "agent-resume-on-recovery",
    "font-family",
    "font-family-bold",
    "font-family-italic",
    "font-family-bold-italic",
    "font-family-fallback",
    "font-auto-match-weight-style",
    "font-size",
    "font-line-height",
    "font-ligatures",
    "font-ligatures-alphabet",
    "font-bold",
    "font-italic",
    "font-blending",
    "scrollback-limit",
    "cursor-style",
    "cursor-style-blink",
    "appearance.density",
];

/// Every row, in the reading order the list renders: General → Shell → Controls → Appearance →
/// Advanced, then the typed render fields.
pub const ROWS: &[SettingRow] = &[
    SettingRow {
        key: "general.onLaunch",
        label: "On Launch",
        page_label: "",
        description: "Restore the last session or open a fresh window when the app starts.",
        default_text: "Restore Last Session",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "launch startup restore session new window open",
        inline_editable: true,
    },
    SettingRow {
        key: "features.redactSecrets",
        label: "Redact Secrets",
        page_label: "",
        description: "Mask likely secrets in window titles and notification bodies.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "privacy secret redact mask token password api key",
        inline_editable: true,
    },
    SettingRow {
        key: "shell.closeConfirm.tab",
        label: "Close Confirmation · Tab",
        page_label: "Closing a tab",
        description: "When to confirm before closing a tab. ⌘W closes a pane and only asks mid-command.",
        default_text: "Running Process",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "close confirm tab pane prompt quit running process always",
        inline_editable: true,
    },
    SettingRow {
        key: "shell.closeConfirm.window",
        label: "Close Confirmation · Window",
        page_label: "Closing a window",
        description: "When to confirm before closing a window.",
        default_text: "Running Process",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "close confirm window prompt quit running process always",
        inline_editable: true,
    },
    SettingRow {
        key: "follow-session-focus",
        label: "Follow the Shared Focus",
        page_label: "",
        description: "Whether switching tab or pane on this device moves every device that follows, or only \
                      this one's own view.",
        default_text: FOLLOW_SESSION_FOCUS_DEFAULT,
        bucket: Bucket::HasDedicatedTab,
        target_section: "general",
        keywords: "focus follow shared device local multi client mirror sync tab pane independent",
        inline_editable: false,
    },
    SettingRow {
        key: "notifications.osc",
        label: "Explicit Notifications",
        page_label: "",
        description: "Post OSC 9 / OSC 777 notifications emitted by the terminal.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "notification osc bell alert badge shell",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.longCommand",
        label: "Long-Command Notification",
        page_label: "",
        description: "Notify when a long-running command finishes in an unfocused pane.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "notification command complete long running done shell",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.onFinish",
        label: "Notify on Command Finish",
        page_label: "",
        description: "Notify when a background command finishes.",
        default_text: "Off",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "notification command finish complete exit success shell background",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.onError",
        label: "Notify on Error Exit",
        page_label: "",
        description: "Notify when a command fails (exits non-zero).",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "notification command error fail exit non-zero shell",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.onWatchFinish",
        label: "Notify on Watch Finish",
        page_label: "",
        description: "Notify when an `slopdesk watch`-wrapped command finishes.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "notification watch finish command wrapped shell",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.whileForeground",
        label: "Notify While Foreground",
        page_label: "",
        description: "Banner behavior while the app is the foreground app — off, always, or only when the \
                      source tab is unfocused.",
        default_text: "Off",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "notification foreground banner frontmost tab unfocused while active",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.bounceDock",
        label: "Bounce Dock Icon",
        page_label: "",
        description: "Bounce the Dock icon when a notification arrives and the app isn't focused.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "notification dock bounce attention macos icon request",
        inline_editable: true,
    },
    // The three COMMAND-driven tab badges and the delay before a running command counts as busy.
    // Advertised here because they are settings a user goes looking for by name; the CONTROL is on
    // Shell, so the list shows the value and a jump rather than a second editor.
    SettingRow {
        key: "tabBadge.onCommandFinish",
        label: "Tab Badge · Command Finishes",
        page_label: "When Command Finishes",
        description: "Badge the tab when a command exits successfully.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "shell",
        keywords: "tab badge command finish success exit zero sidebar mark",
        inline_editable: false,
    },
    SettingRow {
        key: "tabBadge.onCommandFail",
        label: "Tab Badge · Command Fails",
        page_label: "When Command Fails",
        description: "Badge the tab when a command exits non-zero.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "shell",
        keywords: "tab badge command fail error exit non-zero sidebar mark",
        inline_editable: false,
    },
    SettingRow {
        key: "tabBadge.onCommandAwaitInput",
        label: "Tab Badge · Command Awaits Input",
        page_label: "When Command Awaits Input",
        description: "Badge the tab when a command stops at an interactive prompt.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "shell",
        keywords: "tab badge command await input prompt interactive sidebar mark",
        inline_editable: false,
    },
    SettingRow {
        key: "tabBadge.busyDelaySeconds",
        label: "Tab Badge · Busy Reveal Delay",
        page_label: "Busy reveal delay",
        description: "How long a command must run before its row shows as busy.",
        default_text: "1s",
        bucket: Bucket::HasDedicatedTab,
        target_section: "shell",
        keywords: "tab badge busy delay reveal running spinner ring seconds instant",
        inline_editable: false,
    },
    SettingRow {
        key: "notifications.soundShellControlled",
        label: "Sound · Shell Controlled",
        page_label: "",
        description: "Let shell apps ring the terminal bell (BEL) as the system alert sound.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "sound bell beep audio shell controlled alert nssound",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.soundOnErrorExit",
        label: "Sound on Error Exit",
        page_label: "",
        description: "Beep when a command exits non-zero (requires shell integration).",
        default_text: "Off",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "sound error exit beep non-zero fail shell integration",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.agentTaskComplete",
        label: "Code Agent · Notify When Task Completes",
        page_label: "",
        description: "Notify when a coding agent finishes a task and goes idle.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "agent claude notification task complete done idle code",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.agentAwaitInput",
        label: "Code Agent · Notify When Awaiting Input",
        page_label: "",
        description: "Notify when a coding agent needs approval or input.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "agent claude notification awaiting input approval permission code",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.agentSoundTaskComplete",
        label: "Code Agent · Sound When Task Completes",
        page_label: "",
        description: "Play a sound when a coding agent finishes in an unfocused pane.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "agent claude sound task complete done finish submarine audio macos code",
        inline_editable: true,
    },
    SettingRow {
        key: "notifications.agentSoundAwaitInput",
        label: "Code Agent · Sound When Awaiting Input",
        page_label: "",
        description: "Play a sound when a coding agent needs approval or input.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "agent claude sound awaiting input approval permission glass audio macos code",
        inline_editable: true,
    },
    SettingRow {
        key: "shell.workingDirectory.newWindow",
        label: "Working Directory · New Window",
        page_label: "",
        description: "Where a new window opens — the home directory or the active pane's directory.",
        default_text: "Home Directory",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "working directory cwd folder window home inherit same",
        inline_editable: true,
    },
    SettingRow {
        key: "shell.workingDirectory.newTab",
        label: "Working Directory · New Tab",
        page_label: "",
        description: "Where a new tab opens — the home directory or the active pane's directory.",
        default_text: "Same as Current",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "working directory cwd folder tab home inherit same",
        inline_editable: true,
    },
    SettingRow {
        key: "shell.workingDirectory.newSplit",
        label: "Working Directory · New Split",
        page_label: "",
        description: "Where a new split opens — the home directory or the active pane's directory.",
        default_text: "Same as Current",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "working directory cwd folder split home inherit same",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.paneSwitcherPreview",
        label: "Preview While Switching Panes",
        page_label: "",
        description: "As ⌃⇥ walks the pane list, show each pane underneath the switcher.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "pane tab switcher control ctrl preview follow highlight cycle mru",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.copyOnSelect",
        label: "Copy on Select",
        page_label: "",
        description: "Copy the selection to the pasteboard as soon as it is made.",
        default_text: "Off",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "copy select clipboard pasteboard mouse selection",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.trimTrailingSpaces",
        label: "Trim Trailing Spaces on Copy",
        page_label: "",
        description: "Strip trailing whitespace from each copied line.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "copy trim trailing whitespace space clipboard",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.pasteProtection",
        label: "Paste Protection",
        page_label: "",
        description: "Warn before pasting text that contains a newline or control character.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "paste protection clipboard safety bracketed newline",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.mouseHideWhileTyping",
        label: "Hide Mouse While Typing",
        page_label: "",
        description: "Hide the pointer while typing into a pane.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "mouse hide typing pointer",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.focusFollowsMouse",
        label: "Focus Follows Mouse",
        page_label: "",
        description: "Focus the pane the pointer is over without a click.",
        default_text: "Off",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "focus follows mouse hover pane pointer",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.scrollMultiplier",
        label: "Scroll Multiplier",
        page_label: "",
        description: "Multiply the scroll-wheel delta.",
        default_text: "1.00×",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "scroll multiplier wheel speed mouse sensitivity",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.clearSelectionOnTyping",
        label: "Clear Selection on Typing",
        page_label: "",
        description: "Clear the selection when the user starts typing.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "selection clear typing keyboard input",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.clearSelectionOnCopy",
        label: "Clear Selection on Copy",
        page_label: "",
        description: "Clear the selection after an explicit copy.",
        default_text: "Off",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "selection clear copy clipboard",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.shiftArrowSelect",
        label: "Shift+Arrow Select",
        page_label: "",
        description: "Use Shift+arrows to drive native selection instead of forwarding arrow escapes.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "shift arrow select selection keyboard extend",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.pasteBracketedSafe",
        label: "Paste Bracketed Safe",
        page_label: "",
        description: "Treat a bracketed paste as safe, skipping the warning when the program supports it.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "paste bracketed safe protection clipboard",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.clipboardRead",
        label: "Clipboard Read (OSC 52)",
        page_label: "",
        description: "Whether a program may READ the clipboard via OSC 52.",
        default_text: "Ask",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "clipboard read osc 52 access allow deny ask paste",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.clipboardWrite",
        label: "Clipboard Write (OSC 52)",
        page_label: "",
        description: "Whether a program may WRITE the clipboard via OSC 52.",
        default_text: "Allow",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "clipboard write osc 52 access allow deny ask copy",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.allowMouseCapture",
        label: "Allow Mouse Capture",
        page_label: "",
        description: "Allow shell apps to capture mouse events (e.g. vim, tmux).",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "mouse capture reporting vim tmux htop program",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.allowShiftClick",
        label: "Allow Shift with Mouse Click",
        page_label: "",
        description: "Hold Shift to select text even when the running app captures the mouse.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "shift mouse click capture selection bypass",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.clickToMove",
        label: "Cursor Click-to-Move",
        page_label: "",
        description: "Click in the prompt to move the shell cursor, across soft-wrapped rows.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "cursor click move prompt arrow keys soft wrap",
        inline_editable: true,
    },
    // macOS-only in the UI (`EnableSecureEventInput` is process-global and has no iOS form), but the
    // keys compile and round-trip on both, so both are advertised — the LIST is a key index, not a
    // second copy of the page's platform rules.
    SettingRow {
        key: "controls.autoSecureInput",
        label: "Secure Input · Automatic",
        page_label: "Auto Secure Input",
        description: "Engage macOS Secure Keyboard Entry when the remote shell shows a hidden password \
                      prompt.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "controls",
        keywords: "secure input keyboard entry password sudo ssh read hidden prompt keylog",
        inline_editable: false,
    },
    SettingRow {
        key: "controls.secureInputIndicator",
        label: "Secure Input · Indicator",
        page_label: "Show Secure Input Indicator",
        description: "Show the SECURE INPUT pill in the pane while secure keyboard entry is active.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "controls",
        keywords: "secure input indicator pill badge keyboard entry visible",
        inline_editable: false,
    },
    SettingRow {
        key: "controls.undoAtPrompt",
        label: "Undo at Prompt",
        page_label: "",
        description: "Cmd-Z at the shell prompt emits the readline undo sequence.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "undo prompt readline cmd z line edit",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.rightClickAction",
        label: "Right-Click Action",
        page_label: "",
        description: "What right-click does in the viewport (Ctrl+right-click always opens the menu).",
        default_text: "Context Menu",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "right click action menu copy paste ignore mouse",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.optionAsAlt",
        label: "Option as Alt",
        page_label: "",
        description: "Treat the macOS Option key as Alt/Meta so terminal apps see Esc-prefixed sequences; \
                      off keeps Option free for accented characters.",
        default_text: "Off",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "option alt meta esc keyboard macos key word jump emacs vim readline accented",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.linkDetection",
        label: "Detect Links & Paths",
        page_label: "",
        description: "Detect paths and URLs in terminal output and underline them on Cmd-hover.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "link path url detect underline hover open clickable hyperlink osc 8",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.linkCmdClick",
        label: "Cmd-Click on Link",
        page_label: "",
        description: "What Cmd+click on a detected link does — open in the best handler, copy, or nothing.",
        default_text: "Open",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "link cmd click open copy nothing url path open with handler",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.linkCmdShiftClick",
        label: "Cmd-Shift-Click on Link",
        page_label: "",
        description: "What Cmd+Shift+click on a detected link does — reveal on the host, or open with the \
                      system default.",
        default_text: "Reveal in Finder",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "link cmd shift click reveal finder open system default host",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.autoDetectLinkSchemes",
        label: "Auto-Detect Link Schemes",
        page_label: "",
        description: "Which URL schemes are underlined and clickable. All detects any scheme://; Custom \
                      restricts to your list. http(s), file, and mailto are always detected.",
        default_text: "All",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "link scheme url detect custom all http https file mailto codex ssh vscode",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.customLinkSchemes",
        label: "Custom Link Schemes",
        page_label: "",
        description: "Extra URL schemes to detect when Auto-Detect is set to Custom (e.g. codex, ssh, \
                      vscode).",
        default_text: "None",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "custom link scheme url codex ssh vscode additional detect",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.titleShellControlled",
        label: "Title · Shell Controlled",
        page_label: "",
        description: "Allow programs to set the tab and window title via OSC 0 / OSC 2.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "title shell controlled osc 0 2 window tab name privilege",
        inline_editable: true,
    },
    SettingRow {
        key: "controls.clipboardShellControlled",
        label: "Clipboard · Shell Controlled",
        page_label: "",
        description: "Master switch for OSC 52 clipboard access. When off, both clipboard read and write \
                      are denied regardless of the per-direction setting.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "clipboard shell controlled osc 52 master read write privilege deny",
        inline_editable: true,
    },
    SettingRow {
        key: "shell.newTabPosition",
        label: "New Tab Position",
        page_label: "",
        description: "Where a new tab is inserted in the active session's tab bar.",
        default_text: "Automatic",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "tab position new placement order end after current appearance",
        inline_editable: true,
    },
    SettingRow {
        key: "shell.autoHideTabsPanel",
        label: "Auto Hide Tabs Panel",
        page_label: "",
        description: "When the tabs panel hides itself in Sidebar layout. Auto collapses it while the \
                      active session has one tab.",
        default_text: "Default",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "tabs panel sidebar auto hide collapse appearance layout",
        inline_editable: false,
    },
    // The four `window.*` numbers below are a PAIR OF PAIRS, each pair live only in the mode that
    // measures in its unit — so each is qualified by the mode row it belongs to rather than left as a
    // bare `Columns` in a list of fifty-seven keys.
    SettingRow {
        key: "window.size",
        label: "Window Size",
        page_label: "",
        description: "How a new window decides its initial dimensions — the remembered frame, a cell grid, \
                      or a pixel frame.",
        default_text: "Remember",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "window size initial dimensions remember grid frame cols rows pixels appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "window.cols",
        label: "Window Size · Columns",
        page_label: "Columns",
        description: "The column count a new window opens at in Grid mode.",
        default_text: "80",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "window columns cols grid width cells appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "window.rows",
        label: "Window Size · Rows",
        page_label: "Rows",
        description: "The row count a new window opens at in Grid mode.",
        default_text: "24",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "window rows grid height cells appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "window.widthPx",
        label: "Window Size · Width",
        page_label: "Width",
        description: "The width a new window opens at in Frame mode, in pixels.",
        default_text: "1000 px",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "window width pixels px frame appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "window.heightPx",
        label: "Window Size · Height",
        page_label: "Height",
        description: "The height a new window opens at in Frame mode, in pixels.",
        default_text: "600 px",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "window height pixels px frame appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "desktopWindow.presentation",
        label: "Remote Desktop Opens",
        page_label: "",
        description: "How the dedicated remote-desktop window opens — a regular window, native fullscreen, \
                      or a borderless cover of the current Space.",
        default_text: "Window",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "remote desktop window fullscreen borderless space presentation appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "satelliteWindow.backgroundPointer",
        label: "Background Interaction",
        page_label: "",
        description: "Point, click and scroll in an unfocused remote-desktop window without taking the \
                      keyboard from the window you are typing in.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "background interaction pointer satellite desktop window focus click scroll appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "appearance.dockIconAnimateProgress",
        label: "Animate Dock Icon During Progress",
        page_label: "",
        description: "Animate the macOS Dock icon while any session reports OSC 9;4 progress.",
        default_text: "Off",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "dock icon animate progress macos appearance osc 9 4 spinner",
        inline_editable: false,
    },
    SettingRow {
        key: "appearance.dockIconErrorBadge",
        label: "Red Icon on Error",
        page_label: "",
        description: "Tint the macOS Dock icon red on a non-zero exit; clicking jumps to the next failing \
                      tab.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "dock icon red error badge tint exit failing tab macos appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "agents.badgeWhileProcessing",
        label: "Badge While Processing",
        page_label: "",
        description: "Ring the tab while a coding agent is working.",
        default_text: "Off",
        bucket: Bucket::HasDedicatedTab,
        target_section: "agents",
        keywords: "agent claude badge processing working ring tab spinner",
        inline_editable: false,
    },
    SettingRow {
        key: "agents.badgeWhenComplete",
        label: "Badge When Task Completes",
        page_label: "",
        description: "Mark the tab when a coding agent goes idle.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "agents",
        keywords: "agent claude badge complete done idle mark tab",
        inline_editable: false,
    },
    SettingRow {
        key: "agents.badgeWhenAwaitingInput",
        label: "Badge When Awaiting Input",
        page_label: "",
        description: "Mark the tab when a coding agent needs approval.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "agents",
        keywords: "agent claude badge awaiting input approval permission mark tab",
        inline_editable: false,
    },
    // The two HOST-read agent flags. They ride the `video-prefs.json` sidecar rather than
    // `UserDefaults`, so they are keyed the way the typed render fields are and restored with the
    // model they belong to.
    SettingRow {
        key: "agent-prevent-sleep",
        label: "Prevent Sleep While Processing",
        page_label: "",
        description: "Hold a system-sleep assertion on the host while any agent is working.",
        default_text: "Off",
        bucket: Bucket::HasDedicatedTab,
        target_section: "agents",
        keywords: "agent claude prevent sleep assertion host processing caffeinate power",
        inline_editable: false,
    },
    SettingRow {
        key: "agent-resume-on-recovery",
        label: "Resume on Recovery",
        page_label: "",
        description: "Re-arm a detached agent session when the connection recovers.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "agents",
        keywords: "agent claude resume recovery reconnect detached re-arm session host",
        inline_editable: false,
    },
    SettingRow {
        key: "features.recordClipboardHistory",
        label: "Record Clipboard History",
        page_label: "",
        description: "Archive copied text into the clipboard-history ring.",
        default_text: "On",
        bucket: Bucket::AdvancedOnly,
        target_section: "",
        keywords: "clipboard history record paste recent ring",
        inline_editable: true,
    },
    SettingRow {
        key: "font-family",
        label: "Font Family",
        page_label: "",
        description: "The terminal font family.",
        default_text: "SF Mono",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font family typeface monospace appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-family-bold",
        label: "Font Family · Bold",
        page_label: "Bold",
        description: "An explicit bold face family, used only while auto-match is off.",
        default_text: "Auto",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font family bold face weight appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-family-italic",
        label: "Font Family · Italic",
        page_label: "Italic",
        description: "An explicit italic face family, used only while auto-match is off.",
        default_text: "Auto",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font family italic face slant appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-family-bold-italic",
        label: "Font Family · Bold Italic",
        page_label: "Bold Italic",
        description: "An explicit bold-italic face family, used only while auto-match is off.",
        default_text: "Auto",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font family bold italic face appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-family-fallback",
        label: "Font Family · Fallback",
        page_label: "Fallback",
        description: "The families tried, in order, when the primary font lacks a glyph.",
        default_text: "None",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font family fallback cjk nerd glyph missing appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-auto-match-weight-style",
        label: "Auto-Match Weight & Style",
        page_label: "",
        description: "Derive the bold and italic faces from the primary family automatically.",
        default_text: "On",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font auto match weight style bold italic derive appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-size",
        label: "Font Size",
        page_label: "",
        description: "The terminal font point size.",
        default_text: "13",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font size point appearance zoom",
        inline_editable: false,
    },
    SettingRow {
        key: "font-line-height",
        label: "Line Height",
        page_label: "",
        description: "The terminal cell height, as a multiple of the font's natural height.",
        default_text: "Default",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "line height leading spacing cell density appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-ligatures",
        label: "Ligatures",
        page_label: "",
        description: "Which ligature features the terminal asks the font for.",
        default_text: "Off",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "ligatures calt dlig font arrows appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-ligatures-alphabet",
        label: "Ligatures · Alphabetic Sequences",
        page_label: "Extend to Alphabetic Sequences",
        description: "Ligate letter runs too, not only punctuation.",
        default_text: "Off",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "ligatures alphabet letters words font appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-bold",
        label: "Font Style · Bold",
        page_label: "Bold",
        description: "What the terminal draws when a program asks for bold.",
        default_text: "Auto",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font bold style synthetic weight sgr appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-italic",
        label: "Font Style · Italic",
        page_label: "Italic",
        description: "What the terminal draws when a program asks for italic.",
        default_text: "Auto",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font italic style synthetic slant sgr appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "font-blending",
        label: "Font Blending",
        page_label: "",
        description: "How glyph coverage is blended into the cell background.",
        default_text: "Default",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "font blending thicken antialias gamma render appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "scrollback-limit",
        label: "Scrollback Lines",
        page_label: "",
        description: "The terminal scrollback buffer size, in lines.",
        default_text: "10000",
        bucket: Bucket::HasDedicatedTab,
        target_section: "controls",
        keywords: "scrollback lines buffer history controls scroll",
        inline_editable: false,
    },
    SettingRow {
        key: "cursor-style",
        label: "Cursor Style",
        page_label: "",
        description: "The terminal cursor style.",
        default_text: "Block",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "cursor style block hollow bar underline appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "cursor-style-blink",
        label: "Cursor Blink",
        page_label: "",
        description: "Whether the terminal cursor blinks. Default defers to DEC mode 12.",
        default_text: "Default",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "cursor blink appearance",
        inline_editable: false,
    },
    SettingRow {
        key: "appearance.density",
        label: "Density",
        page_label: "",
        description: "The UI density tier.",
        default_text: "Comfortable",
        bucket: Bucket::HasDedicatedTab,
        target_section: "appearance",
        keywords: "density appearance compact comfortable spacing tier",
        inline_editable: false,
    },
];

/// The row a key names, or `None` for a key no row has.
#[must_use]
pub fn row(key: &str) -> Option<&'static SettingRow> {
    ROWS.iter().find(|row| row.key == key)
}

/// One row by position, for a caller walking the list across a boundary.
#[must_use]
pub fn row_at(index: usize) -> Option<&'static SettingRow> {
    ROWS.get(index)
}

/// The rows a query matches, as POSITIONS in [`ROWS`].
///
/// A case-insensitive SUBSTRING match over the key, the label, the description and the keywords —
/// not the fuzzy ranking every other search field uses, and deliberately: this list is read by
/// someone who already knows the name of the knob they want, so `cursor` must narrow to the cursor
/// rows rather than order all fifty-seven by how cursor-ish they are. An empty or whitespace query
/// matches everything, in order.
///
/// Positions rather than rows because that is what survives the boundary: the near side asks for
/// indices and then asks each one for its fields, the same idiom every list here uses.
#[must_use]
pub fn matches(query: &str) -> Vec<usize> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return (0..ROWS.len()).collect();
    }
    ROWS.iter()
        .enumerate()
        .filter(|(_, row)| row.matches(&needle))
        .map(|(index, _)| index)
        .collect()
}

impl SettingRow {
    /// Whether this row matches an ALREADY-lowercased, already-trimmed needle.
    fn matches(&self, needle: &str) -> bool {
        self.key.to_lowercase().contains(needle)
            || self.label.to_lowercase().contains(needle)
            || self.description.to_lowercase().contains(needle)
            || self.keywords.to_lowercase().contains(needle)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What an index label puts between a group's name and a row's own.
    const QUALIFIER: &str = " · ";

    /// A page label exists exactly where the index label is QUALIFIED, and never anywhere else.
    ///
    /// That is the whole rule, and it is worth stating as a rule rather than as a count. The index
    /// has no header above it, so a row that shares its name with siblings has to carry the group's
    /// name too: `Tab Badge · Command Fails`. A page has already printed `Tab Badge` as a header,
    /// so the same row is `When Command Fails` there. Every override is therefore a qualified
    /// label with its qualifier removed — a row needing a second string for any OTHER reason
    /// means the two registers have started DRIFTING rather than diverging, which is what this
    /// catches.
    #[test]
    fn a_page_label_exists_only_where_the_index_label_is_qualified() {
        for row in ROWS {
            if row.page_label.is_empty() {
                continue;
            }
            assert_ne!(
                row.page_label, row.label,
                "{} sets a page label identical to its index label — drop it and let it fall back",
                row.key,
            );
            assert!(
                row.label.contains(QUALIFIER),
                "{} overrides an UNQUALIFIED label — the page and the index have started drifting",
                row.key,
            );
            assert!(
                !row.page_label.contains(QUALIFIER),
                "{} keeps the qualifier on the page, where the header already prints it",
                row.key,
            );
        }
    }

    /// One separator for the one job, so the rule above can be checked at all. The table carried
    /// both ` · ` and an em dash for the same thing until the layout port made the two meet.
    #[test]
    fn a_qualifier_is_written_one_way() {
        for row in ROWS {
            assert!(
                !row.label.contains(" — "),
                "{} qualifies with an em dash; the separator is {QUALIFIER:?}",
                row.key,
            );
        }
    }

    /// The fallback is the whole contract: every row has a page label, whether or not it set one.
    #[test]
    fn every_row_has_a_page_label() {
        for row in ROWS {
            assert!(
                !row.page_label().is_empty(),
                "{} renders nameless on a page",
                row.key
            );
        }
    }

    #[test]
    fn every_key_is_unique() {
        let mut keys: Vec<&str> = ROWS.iter().map(|row| row.key).collect();
        keys.sort_unstable();
        let count = keys.len();
        keys.dedup();
        assert_eq!(
            keys.len(),
            count,
            "a key listed twice is a row that renders twice"
        );
    }

    #[test]
    fn every_row_says_something() {
        for row in ROWS {
            assert!(!row.key.is_empty(), "a row with no key");
            assert!(!row.label.is_empty(), "{} has no label", row.key);
            assert!(!row.description.is_empty(), "{} has no description", row.key);
            assert!(!row.default_text.is_empty(), "{} has no default", row.key);
            assert!(
                row.description.ends_with('.'),
                "{}'s description is a sentence, so it ends like one",
                row.key,
            );
        }
    }

    #[test]
    fn a_jump_names_a_section_and_an_inline_row_does_not() {
        for row in ROWS {
            match row.bucket {
                Bucket::HasDedicatedTab => {
                    assert!(
                        !row.target_section.is_empty(),
                        "{} jumps nowhere — a ✎ button with no destination",
                        row.key,
                    );
                },
                Bucket::AdvancedOnly => {
                    assert!(
                        row.target_section.is_empty(),
                        "{} renders inline, so a jump target would be a second edit path",
                        row.key,
                    );
                },
            }
        }
    }

    #[test]
    fn only_an_inline_row_claims_an_inline_editor() {
        for row in ROWS.iter().filter(|row| row.bucket == Bucket::HasDedicatedTab) {
            assert!(
                !row.inline_editable,
                "{} defers to a section control, so it cannot also claim an inline one",
                row.key,
            );
        }
        let inline = ROWS.iter().filter(|row| row.inline_editable).count();
        assert_eq!(
            inline, 48,
            "every advanced row must have an inline editor behind it"
        );
        assert_eq!(
            inline,
            ROWS.iter()
                .filter(|row| row.bucket == Bucket::AdvancedOnly)
                .count(),
            "an advanced row with no inline editor is a dead value label",
        );
    }

    #[test]
    fn a_jump_target_names_a_real_section() {
        for row in ROWS.iter().filter(|row| !row.target_section.is_empty()) {
            assert!(
                crate::settings_catalog::Section::ALL
                    .iter()
                    .any(|section| section.id() == row.target_section),
                "{} jumps to {}, which is not a section",
                row.key,
                row.target_section,
            );
        }
    }

    #[test]
    fn an_empty_query_is_the_whole_list_in_order() {
        assert_eq!(matches(""), (0..ROWS.len()).collect::<Vec<usize>>());
        assert_eq!(matches("   \n "), (0..ROWS.len()).collect::<Vec<usize>>());
    }

    #[test]
    fn a_query_narrows_by_substring_across_all_four_fields() {
        let by_label = matches("copy on select");
        assert_eq!(by_label.len(), 1);
        assert_eq!(
            by_label.first().and_then(|i| row_at(*i)).map(|row| row.key),
            Some("controls.copyOnSelect")
        );
        // The keyword blob is what makes a synonym findable — "pasteboard" is in neither this row's
        // label nor its description.
        assert!(
            matches("pasteboard")
                .iter()
                .filter_map(|i| row_at(*i))
                .any(|row| row.key == "controls.copyOnSelect"),
        );
        // By KEY, which is what an expert reading a config file searches by.
        assert!(
            matches("features.redact")
                .iter()
                .filter_map(|i| row_at(*i))
                .any(|row| row.key == "features.redactSecrets"),
        );
        assert!(matches("CURSOR").len() >= 2, "the match is case-insensitive");
        assert!(matches("no such setting anywhere").is_empty());
    }

    #[test]
    fn the_shared_focus_row_carries_the_slices_own_default() {
        let shared = row(FOLLOW_SESSION_FOCUS_KEY);
        assert_eq!(
            shared.map(|row| row.default_text),
            Some(FOLLOW_SESSION_FOCUS_DEFAULT),
            "the row must carry the default this slice was compiled with",
        );
        assert!(
            matches!(FOLLOW_SESSION_FOCUS_DEFAULT, "On" | "Off"),
            "the default reads as a boolean, whichever slice this is",
        );
        assert_eq!(
            shared.map(|row| row.bucket),
            Some(Bucket::HasDedicatedTab),
            "its one real control is on General",
        );
    }

    #[test]
    fn every_named_key_set_names_advertised_rows() {
        for key in DEVICE_LOCAL_KEYS.iter().chain(MODEL_BACKED_KEYS) {
            assert!(
                row(key).is_some(),
                "{key} is restored by name but advertised by nobody"
            );
        }
    }
}
