//! Every setting slopdesk understands, as one table.
//!
//! This is the whole configuration surface: one row per key, carrying the dotted path it is written
//! under, what it may be set to, what it is when nobody sets it, and the one sentence that says
//! what it does. Nothing else in the tree may declare a setting — a value that is not here is not a
//! setting, it is a literal somebody typed.
//!
//! ## Why the table and not a Settings window
//!
//! There was a Settings window, four thousand lines of it, and a first-launch flow in front of it.
//! Both are gone. What a good default IS was already decided here — every row below already
//! carried its default — so the window was asking the user to re-decide it, and the onboarding was
//! asking them to decide it before they had ever seen a terminal. The install is the setup; the
//! file is for the reader who wants a different answer.
//!
//! ## What a row does NOT carry
//!
//! No label, no page, no glyph, no keywords, no "which control draws this". Those were columns of
//! the same table when a window read it, and every one of them was a rendering fact. What is left
//! is the contract: path, domain, default, sentence — which is exactly what a JSON Schema needs, so
//! [`crate::config::schema`] writes one out of these rows rather than out of a second list.
//!
//! ## The tokens are not spelled here twice
//!
//! Where a choice already has a vocabulary in `slopdesk-terminal` — the clipboard gates, the mouse
//! and link verbs — the options array is built from that crate's `token()`, in const context. A
//! second spelling would be a settings file that accepts a word the terminal has never heard of.

use slopdesk_terminal::controls::{
    ClipboardAccess, MouseShiftCapture, OptionAsAlt, RightClickAction, SchemeDetection,
};
use slopdesk_terminal::link_action::{CmdClick, CmdShiftClick};

/// What a key may be set to, and what it is when it is not.
///
/// A `None` default is not "no default" — it is a value the DAEMON decides when the file is silent,
/// and the number is deliberately not repeated here. The video flags are read once at process start
/// out of the environment; writing `26` beside `qp-sharp` would pin the encoder's operating point
/// to whatever it was the day this line was typed, which is the failure the video model already
/// documents at length.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    /// A boolean.
    Flag {
        /// What it is when unset, or `None` when the reader decides.
        default: Option<bool>,
    },
    /// A whole number inside an inclusive range.
    Int {
        /// What it is when unset, or `None` when the reader decides.
        default: Option<i64>,
        /// The smallest accepted value.
        min: i64,
        /// The largest accepted value.
        max: i64,
    },
    /// A real number inside an inclusive range.
    Float {
        /// What it is when unset, or `None` when the reader decides.
        default: Option<f64>,
        /// The smallest accepted value.
        min: f64,
        /// The largest accepted value.
        max: f64,
    },
    /// One token out of a closed set.
    Choice {
        /// What it is when unset, or `None` when the reader decides.
        default: Option<&'static str>,
        /// Every accepted token, in reading order.
        options: &'static [&'static str],
    },
    /// Free text. An empty default means "follow whatever is underneath" at every one of these
    /// keys — an unset colour follows the theme, an unset face follows the family.
    Text {
        /// What it is when unset.
        default: &'static str,
    },
    /// A list of strings, empty when unset.
    List,
    /// A named stop OR a raw multiplier — the one key that takes either.
    Scale {
        /// The token used when the key is unset.
        default: &'static str,
        /// The named stops.
        options: &'static [&'static str],
        /// The smallest accepted raw multiplier.
        min: f64,
        /// The largest accepted raw multiplier.
        max: f64,
    },
}

/// One configuration key.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Key {
    /// The dotted path it is written under, kebab-cased at every segment.
    pub path: &'static str,
    /// Its domain and its default.
    pub kind: Kind,
    /// The one sentence a schema, a validator and a reader all show.
    pub doc: &'static str,
}

/// The clipboard gates, as the terminal spells them.
const CLIPBOARD: &[&str] = &[
    ClipboardAccess::Ask.token(),
    ClipboardAccess::Allow.token(),
    ClipboardAccess::Deny.token(),
];

/// What a right-click does.
const RIGHT_CLICK: &[&str] = &[
    RightClickAction::ContextMenu.token(),
    RightClickAction::Copy.token(),
    RightClickAction::Paste.token(),
    RightClickAction::CopyOrPaste.token(),
    RightClickAction::Ignore.token(),
];

/// Whether ⇧-click extends the selection or reaches the program.
const SHIFT_CLICK: &[&str] = &[
    MouseShiftCapture::Enabled.token(),
    MouseShiftCapture::Disabled.token(),
    MouseShiftCapture::Always.token(),
    MouseShiftCapture::Never.token(),
];

/// Which ⌥ keys send ESC.
const OPTION_AS_ALT: &[&str] = &[
    OptionAsAlt::Off.token(),
    OptionAsAlt::Both.token(),
    OptionAsAlt::Left.token(),
    OptionAsAlt::Right.token(),
];

/// What ⌘-click does to a link.
const CMD_CLICK: &[&str] = &[
    CmdClick::Open.token(),
    CmdClick::Copy.token(),
    CmdClick::Nothing.token(),
];

/// What ⌘⇧-click does to a link.
const CMD_SHIFT_CLICK: &[&str] = &[
    CmdShiftClick::RevealFinder.token(),
    CmdShiftClick::OpenSystemDefault.token(),
];

/// Which schemes are detected at all.
const LINK_SCHEMES: &[&str] = &[SchemeDetection::All.token(), SchemeDetection::Custom.token()];

/// When a close is confirmed. The tab row is this list's first two: closing ONE tab can never lose
/// more than one, so the third stop would be a policy that never fires.
const CLOSE_CONFIRMATION: &[&str] = &["process", "always", "multiple-tabs"];

/// The tab row's stops.
const CLOSE_CONFIRMATION_TAB: &[&str] = &["process", "always"];

/// The `follow-session-focus` default, as the slice it is compiled for reads it: a phone attaches
/// to LOOK at one session, a desktop attaches to WORK and expects the host's focus to lead
/// (docs/45 §8.2).
#[cfg(target_os = "ios")]
pub const FOLLOW_SESSION_FOCUS_DEFAULT: bool = false;
/// See the iOS arm.
#[cfg(not(target_os = "ios"))]
pub const FOLLOW_SESSION_FOCUS_DEFAULT: bool = true;

/// The table the whole app is configured by, in the order the schema and the commented starter file
/// print it.
pub const KEYS: &[Key] = &[
    // ---- general ------------------------------------------------------------------------------
    Key {
        path: "general.on-launch",
        kind: Kind::Choice {
            default: Some("restore-last-session"),
            options: &["restore-last-session", "new-window"],
        },
        doc: "Restore the last session or open a fresh window when the app starts.",
    },
    Key {
        path: "general.redact-secrets",
        kind: Kind::Flag { default: Some(true) },
        doc: "Mask likely secrets in window titles and notification bodies.",
    },
    Key {
        path: "general.record-clipboard-history",
        kind: Kind::Flag { default: Some(true) },
        doc: "Keep the clipboard ring the pane's paste history reads.",
    },
    Key {
        path: "general.follow-session-focus",
        kind: Kind::Flag {
            default: Some(FOLLOW_SESSION_FOCUS_DEFAULT),
        },
        doc: "Follow the host's focused pane when another client moves it (docs/45 §8.2).",
    },
    // ---- shell --------------------------------------------------------------------------------
    Key {
        path: "shell.close-confirm-tab",
        kind: Kind::Choice {
            default: Some("process"),
            options: CLOSE_CONFIRMATION_TAB,
        },
        doc: "When to confirm before closing a tab.",
    },
    Key {
        path: "shell.close-confirm-window",
        kind: Kind::Choice {
            default: Some("process"),
            options: CLOSE_CONFIRMATION,
        },
        doc: "When to confirm before closing a window.",
    },
    Key {
        path: "shell.new-tab-position",
        kind: Kind::Choice {
            default: Some("auto"),
            options: &["auto", "end", "after-current"],
        },
        doc: "Where a new tab lands in the strip.",
    },
    Key {
        path: "shell.auto-hide-tabs-panel",
        kind: Kind::Choice {
            default: Some("default"),
            options: &["default", "always", "auto"],
        },
        doc: "Whether the layout may take the tabs panel away when it is tight.",
    },
    Key {
        path: "shell.working-directory-new-window",
        kind: Kind::Text { default: "home" },
        doc: "Where a new WINDOW opens: `inherit`, `home`, or an absolute path.",
    },
    Key {
        path: "shell.working-directory-new-tab",
        kind: Kind::Text { default: "inherit" },
        doc: "Where a new TAB opens: `inherit`, `home`, or an absolute path.",
    },
    Key {
        path: "shell.working-directory-new-split",
        kind: Kind::Text { default: "inherit" },
        doc: "Where a new SPLIT opens: `inherit`, `home`, or an absolute path.",
    },
    // ---- notifications ------------------------------------------------------------------------
    Key {
        path: "notifications.osc",
        kind: Kind::Flag { default: Some(true) },
        doc: "Post the explicit OSC 9 / OSC 777 notifications a program asks for.",
    },
    Key {
        path: "notifications.long-command",
        kind: Kind::Flag { default: Some(true) },
        doc: "Post when a long-running command finishes.",
    },
    Key {
        path: "notifications.on-finish",
        kind: Kind::Flag { default: Some(false) },
        doc: "Post when any command exits cleanly.",
    },
    Key {
        path: "notifications.on-error",
        kind: Kind::Flag { default: Some(true) },
        doc: "Post when a command exits non-zero.",
    },
    Key {
        path: "notifications.on-watch-finish",
        kind: Kind::Flag { default: Some(true) },
        doc: "Post when an `slopdesk watch`-wrapped command finishes.",
    },
    Key {
        path: "notifications.while-foreground",
        kind: Kind::Choice {
            default: Some("off"),
            options: &["off", "always", "tab-unfocused"],
        },
        doc: "Whether a banner shows while slopdesk itself is frontmost.",
    },
    Key {
        path: "notifications.bounce-dock",
        kind: Kind::Flag { default: Some(true) },
        doc: "Bounce the Dock icon when a notification arrives and the app is not focused.",
    },
    Key {
        path: "notifications.sound-shell-controlled",
        kind: Kind::Flag { default: Some(true) },
        doc: "Let a `BEL` ring the system beep.",
    },
    Key {
        path: "notifications.sound-on-error-exit",
        kind: Kind::Flag { default: Some(false) },
        doc: "Beep when a command exits non-zero.",
    },
    Key {
        path: "notifications.agent-task-complete",
        kind: Kind::Flag { default: Some(true) },
        doc: "Post when a code agent finishes its task.",
    },
    Key {
        path: "notifications.agent-await-input",
        kind: Kind::Flag { default: Some(true) },
        doc: "Post when a code agent stops to ask something.",
    },
    Key {
        path: "notifications.agent-sound-task-complete",
        kind: Kind::Flag { default: Some(true) },
        doc: "Play a sound when a code agent finishes its task.",
    },
    Key {
        path: "notifications.agent-sound-await-input",
        kind: Kind::Flag { default: Some(true) },
        doc: "Play a sound when a code agent stops to ask something.",
    },
    // ---- badges -------------------------------------------------------------------------------
    Key {
        path: "badges.command-finish",
        kind: Kind::Flag { default: Some(true) },
        doc: "Badge the tab when a command exits cleanly.",
    },
    Key {
        path: "badges.command-fail",
        kind: Kind::Flag { default: Some(true) },
        doc: "Badge the tab when a command exits non-zero.",
    },
    Key {
        path: "badges.command-await-input",
        kind: Kind::Flag { default: Some(true) },
        doc: "Badge the tab when a command stops at an interactive prompt.",
    },
    Key {
        path: "badges.busy-delay-seconds",
        kind: Kind::Float {
            default: Some(1.0),
            min: 0.0,
            max: 60.0,
        },
        doc: "Seconds a command must run before the busy dot shows. 0 shows it immediately.",
    },
    Key {
        path: "badges.agent-processing",
        kind: Kind::Flag { default: Some(false) },
        doc: "Badge a pane while its code agent is working.",
    },
    Key {
        path: "badges.agent-complete",
        kind: Kind::Flag { default: Some(true) },
        doc: "Badge a pane when its code agent finishes.",
    },
    Key {
        path: "badges.agent-awaiting-input",
        kind: Kind::Flag { default: Some(true) },
        doc: "Badge a pane when its code agent is waiting on an answer.",
    },
    // ---- controls -----------------------------------------------------------------------------
    Key {
        path: "controls.pane-switcher-preview",
        kind: Kind::Flag { default: Some(true) },
        doc: "Show the live pane preview while the switcher is held open.",
    },
    Key {
        path: "controls.copy-on-select",
        kind: Kind::Flag { default: Some(false) },
        doc: "Copy the selection to the pasteboard as soon as it is made.",
    },
    Key {
        path: "controls.trim-trailing-spaces",
        kind: Kind::Flag { default: Some(true) },
        doc: "Drop trailing spaces from each copied line.",
    },
    Key {
        path: "controls.paste-protection",
        kind: Kind::Flag { default: Some(true) },
        doc: "Confirm before pasting text that carries a newline or a control byte.",
    },
    Key {
        path: "controls.mouse-hide-while-typing",
        kind: Kind::Flag { default: Some(true) },
        doc: "Hide the pointer while typing until the mouse moves again.",
    },
    Key {
        path: "controls.focus-follows-mouse",
        kind: Kind::Flag { default: Some(false) },
        doc: "Focus the pane under the pointer without a click.",
    },
    Key {
        path: "controls.scroll-multiplier",
        kind: Kind::Float {
            default: Some(1.0),
            min: 0.1,
            max: 10.0,
        },
        doc: "Multiplier applied to every scroll delta the terminal receives.",
    },
    Key {
        path: "controls.clear-selection-on-typing",
        kind: Kind::Flag { default: Some(true) },
        doc: "Clear the selection as soon as a key is typed.",
    },
    Key {
        path: "controls.clear-selection-on-copy",
        kind: Kind::Flag { default: Some(false) },
        doc: "Clear the selection once it has been copied.",
    },
    Key {
        path: "controls.shift-arrow-select",
        kind: Kind::Flag { default: Some(true) },
        doc: "Let ⇧+arrow extend a selection instead of reaching the program.",
    },
    Key {
        path: "controls.paste-bracketed-safe",
        kind: Kind::Flag { default: Some(true) },
        doc: "Strip the bracketed-paste terminators a pasted payload tries to smuggle in.",
    },
    Key {
        path: "controls.clipboard-read",
        kind: Kind::Choice {
            default: Some(ClipboardAccess::Ask.token()),
            options: CLIPBOARD,
        },
        doc: "What a program may do when it READS the clipboard through OSC 52.",
    },
    Key {
        path: "controls.clipboard-write",
        kind: Kind::Choice {
            default: Some(ClipboardAccess::Allow.token()),
            options: CLIPBOARD,
        },
        doc: "What a program may do when it WRITES the clipboard through OSC 52.",
    },
    Key {
        path: "controls.allow-mouse-capture",
        kind: Kind::Flag { default: Some(true) },
        doc: "Let a program take the mouse (vim, tmux) instead of the terminal keeping it.",
    },
    Key {
        path: "controls.shift-click",
        kind: Kind::Choice {
            default: Some(MouseShiftCapture::Enabled.token()),
            options: SHIFT_CLICK,
        },
        doc: "Whether ⇧-click extends the selection or reaches the program that captured the mouse.",
    },
    Key {
        path: "controls.click-to-move",
        kind: Kind::Flag { default: Some(true) },
        doc: "Move the shell's cursor to a click on the prompt line.",
    },
    Key {
        path: "controls.auto-secure-input",
        kind: Kind::Flag { default: Some(true) },
        doc: "Turn on macOS secure input while a password prompt is on screen.",
    },
    Key {
        path: "controls.secure-input-indicator",
        kind: Kind::Flag { default: Some(true) },
        doc: "Show the lock while secure input is on.",
    },
    Key {
        path: "controls.undo-at-prompt",
        kind: Kind::Flag { default: Some(true) },
        doc: "Let ⌘Z undo the last edit on the prompt line.",
    },
    Key {
        path: "controls.right-click-action",
        kind: Kind::Choice {
            default: Some(RightClickAction::ContextMenu.token()),
            options: RIGHT_CLICK,
        },
        doc: "What a plain right-click does. ⌃+right-click always opens the menu.",
    },
    Key {
        path: "controls.option-as-alt",
        kind: Kind::Choice {
            default: Some(OptionAsAlt::Off.token()),
            options: OPTION_AS_ALT,
        },
        doc: "Which ⌥ keys send ESC rather than composing a character.",
    },
    Key {
        path: "controls.link-detection",
        kind: Kind::Flag { default: Some(true) },
        doc: "Underline URLs, paths and issue references under the pointer.",
    },
    Key {
        path: "controls.link-cmd-click",
        kind: Kind::Choice {
            default: Some(CmdClick::Open.token()),
            options: CMD_CLICK,
        },
        doc: "What ⌘-click does to a detected link.",
    },
    Key {
        path: "controls.link-cmd-shift-click",
        kind: Kind::Choice {
            default: Some(CmdShiftClick::RevealFinder.token()),
            options: CMD_SHIFT_CLICK,
        },
        doc: "What ⌘⇧-click does to a detected link. Both actions happen on the HOST.",
    },
    Key {
        path: "controls.auto-detect-link-schemes",
        kind: Kind::Choice {
            default: Some(SchemeDetection::All.token()),
            options: LINK_SCHEMES,
        },
        doc: "Whether every scheme is detected or only the custom list below.",
    },
    Key {
        path: "controls.custom-link-schemes",
        kind: Kind::List,
        doc: "The schemes detected when `auto-detect-link-schemes` is `custom`.",
    },
    Key {
        path: "controls.hint-patterns",
        kind: Kind::List,
        doc: "Extra regular expressions the hint overlay offers as jump targets.",
    },
    Key {
        path: "controls.hint-pattern-actions",
        kind: Kind::List,
        doc: "What each `hint-patterns` entry does when it is chosen, positionally.",
    },
    Key {
        path: "controls.title-shell-controlled",
        kind: Kind::Flag { default: Some(true) },
        doc: "Let a program set the pane title through OSC 0 / OSC 2.",
    },
    Key {
        path: "controls.clipboard-shell-controlled",
        kind: Kind::Flag { default: Some(true) },
        doc: "Let a program reach the clipboard through OSC 52 at all.",
    },
    // ---- window -------------------------------------------------------------------------------
    Key {
        path: "window.size",
        kind: Kind::Choice {
            default: Some("remember"),
            options: &["remember", "grid", "frame"],
        },
        doc: "Open at the remembered frame, at a cell grid, or at a pixel frame.",
    },
    Key {
        path: "window.cols",
        kind: Kind::Int {
            default: Some(80),
            min: 20,
            max: 1000,
        },
        doc: "How many columns a window opens at while `window.size` is `grid`.",
    },
    Key {
        path: "window.rows",
        kind: Kind::Int {
            default: Some(24),
            min: 5,
            max: 500,
        },
        doc: "How many rows a window opens at while `window.size` is `grid`.",
    },
    Key {
        path: "window.width-px",
        kind: Kind::Int {
            default: Some(1000),
            min: 200,
            max: 20_000,
        },
        doc: "Width in points a `frame` window opens at.",
    },
    Key {
        path: "window.height-px",
        kind: Kind::Int {
            default: Some(600),
            min: 200,
            max: 20_000,
        },
        doc: "Height in points a `frame` window opens at.",
    },
    Key {
        path: "window.desktop-presentation",
        kind: Kind::Choice {
            default: Some("window"),
            options: &["window", "fullscreen", "borderless"],
        },
        doc: "How a remote desktop window opens: in a window, fullscreen or borderless.",
    },
    Key {
        path: "window.satellite-background-pointer",
        kind: Kind::Flag { default: Some(true) },
        doc: "Let a satellite window move the remote pointer while it is not the key window.",
    },
    // ---- appearance ---------------------------------------------------------------------------
    Key {
        path: "appearance.density",
        kind: Kind::Choice {
            default: Some(crate::config::DENSITY_COMFORTABLE),
            options: &[crate::config::DENSITY_COMFORTABLE, crate::config::DENSITY_COMPACT],
        },
        doc: "How much room the chrome takes. Compact buys more rows.",
    },
    Key {
        path: "appearance.dock-icon-animate-progress",
        kind: Kind::Flag { default: Some(false) },
        doc: "Animate the Dock tile while a command runs.",
    },
    Key {
        path: "appearance.dock-icon-error-badge",
        kind: Kind::Flag { default: Some(true) },
        doc: "Badge the Dock tile when a command fails.",
    },
    // ---- terminal -----------------------------------------------------------------------------
    Key {
        path: "terminal.font-family",
        kind: Kind::Text {
            default: slopdesk_terminal::config::FACTORY_FONT_FAMILY,
        },
        doc: "The primary monospace family.",
    },
    Key {
        path: "terminal.font-family-fallback",
        kind: Kind::Text { default: "" },
        doc: "Comma-separated families tried when the primary lacks a glyph.",
    },
    Key {
        path: "terminal.font-family-bold",
        kind: Kind::Text { default: "" },
        doc: "Explicit bold face. Only read when `auto-match-weight-style` is off.",
    },
    Key {
        path: "terminal.font-family-italic",
        kind: Kind::Text { default: "" },
        doc: "Explicit italic face. Only read when `auto-match-weight-style` is off.",
    },
    Key {
        path: "terminal.font-family-bold-italic",
        kind: Kind::Text { default: "" },
        doc: "Explicit bold-italic face. Only read when `auto-match-weight-style` is off.",
    },
    Key {
        path: "terminal.auto-match-weight-style",
        kind: Kind::Flag { default: Some(true) },
        doc: "Pick the family's own bold / italic faces automatically.",
    },
    Key {
        path: "terminal.font-size",
        kind: Kind::Float {
            default: Some(slopdesk_terminal::config::FACTORY_FONT_SIZE),
            min: 4.0,
            max: 96.0,
        },
        doc: "Point size of the primary face.",
    },
    Key {
        path: "terminal.font-weight",
        kind: Kind::Text {
            default: slopdesk_terminal::config::FACTORY_FONT_WEIGHT,
        },
        doc: "Weight token applied to the primary face, e.g. regular or bold.",
    },
    Key {
        path: "terminal.line-height",
        kind: Kind::Scale {
            default: "default",
            options: &["default", "compact", "loose"],
            min: 0.5,
            max: 3.0,
        },
        doc: "Cell height: a named stop, or a raw multiplier like 1.15.",
    },
    Key {
        path: "terminal.ligatures",
        kind: Kind::Choice {
            default: Some("off"),
            options: &["off", "calt", "dlig"],
        },
        doc: "Which ligature features are enabled for the primary face.",
    },
    Key {
        path: "terminal.ligatures-alphabet",
        kind: Kind::Flag { default: Some(false) },
        doc: "Extend ligation to alphabetic sequences.",
    },
    Key {
        path: "terminal.bold",
        kind: Kind::Choice {
            default: Some("auto"),
            options: &["auto", "off", "primary-only", "synthetic"],
        },
        doc: "How bold text is drawn when the family has no real bold face.",
    },
    Key {
        path: "terminal.italic",
        kind: Kind::Choice {
            default: Some("auto"),
            options: &["auto", "off", "primary-only", "synthetic"],
        },
        doc: "How italic text is drawn when the family has no real italic face.",
    },
    Key {
        path: "terminal.blending",
        kind: Kind::Choice {
            default: Some("default"),
            options: &["default", "macos-like"],
        },
        doc: "Glyph anti-aliasing blend mode used when text is drawn.",
    },
    Key {
        path: "terminal.theme",
        kind: Kind::Text { default: "" },
        doc: "A libghostty theme name. Empty means the explicit colours below are the theme.",
    },
    Key {
        path: "terminal.background",
        kind: Kind::Text {
            default: slopdesk_terminal::config::FACTORY_BACKGROUND,
        },
        doc: "Terminal background, six hex digits.",
    },
    Key {
        path: "terminal.foreground",
        kind: Kind::Text {
            default: slopdesk_terminal::config::FACTORY_FOREGROUND,
        },
        doc: "Terminal text colour, six hex digits.",
    },
    Key {
        path: "terminal.cursor-style",
        kind: Kind::Choice {
            default: Some("block"),
            options: &["block", "block_hollow", "bar", "underline"],
        },
        doc: "Cursor silhouette: block, hollow block, bar or underline.",
    },
    Key {
        path: "terminal.cursor-blink",
        kind: Kind::Choice {
            default: Some("default"),
            options: &["default", "on", "off"],
        },
        doc: "Whether the cursor blinks. `default` leaves it to the program (DEC mode 12).",
    },
    Key {
        path: "terminal.cursor-color",
        kind: Kind::Text { default: "" },
        doc: "Cursor body colour as six hex digits. Empty follows the foreground.",
    },
    Key {
        path: "terminal.cursor-text-color",
        kind: Kind::Text { default: "" },
        doc: "Colour of the glyph under the cursor. Empty follows the background.",
    },
    Key {
        path: "terminal.cursor-opacity",
        kind: Kind::Float {
            default: Some(slopdesk_terminal::config::FACTORY_CURSOR_OPACITY),
            min: 0.0,
            max: 1.0,
        },
        doc: "Cursor body opacity, 0 transparent through 1 opaque.",
    },
    Key {
        path: "terminal.scrollback-limit",
        kind: Kind::Int {
            default: Some(slopdesk_terminal::config::FACTORY_SCROLLBACK_LINES),
            min: 0,
            max: 10_000_000,
        },
        doc: "How many lines are kept above the viewport for scrollback.",
    },
    // ---- agent --------------------------------------------------------------------------------
    Key {
        path: "agent.prevent-sleep",
        kind: Kind::Flag { default: None },
        doc: "Hold a sleep assertion on the HOST while any agent is working. Applies on reconnect.",
    },
    Key {
        path: "agent.resume-on-recovery",
        kind: Kind::Flag { default: None },
        doc: "Re-arm a detached agent session when the connection recovers. Applies on reconnect.",
    },
    // ---- video --------------------------------------------------------------------------------
    Key {
        path: "video.qp-sharp",
        kind: Kind::Int {
            default: None,
            min: 1,
            max: 51,
        },
        doc: "Sharpest constant QP on a clean link. Unset leaves the encoder's own. Reconnect.",
    },
    Key {
        path: "video.qp-coarse",
        kind: Kind::Int {
            default: None,
            min: 1,
            max: 51,
        },
        doc: "Coarsest QP under congestion. Unset leaves the encoder's own. Reconnect.",
    },
    Key {
        path: "video.qp-decouple",
        kind: Kind::Flag { default: None },
        doc: "Let min and max QP move apart so a static sidebar stays crisp. Reconnect.",
    },
    Key {
        path: "video.fec-m",
        kind: Kind::Int {
            default: None,
            min: 1,
            max: 32,
        },
        doc: "Reed–Solomon parity count. Must match on BOTH ends. Reconnect.",
    },
    Key {
        path: "video.fec-k",
        kind: Kind::Int {
            default: None,
            min: 1,
            max: 64,
        },
        doc: "Reed–Solomon group size, read only when `fec-m` is 2 or more. Both ends. Reconnect.",
    },
    Key {
        path: "video.pacer",
        kind: Kind::Choice {
            default: None,
            options: &["arrival", "deadline"],
        },
        doc: "Present a decoded frame on arrival or hold it to a smoothness deadline. Reconnect.",
    },
    Key {
        path: "video.playout-ms",
        kind: Kind::Float {
            default: None,
            min: 0.0,
            max: 500.0,
        },
        doc: "Fixed playout buffer in ms. Setting it leaves adaptive playout. Reconnect.",
    },
    Key {
        path: "video.capture-scale",
        kind: Kind::Float {
            default: None,
            min: 0.25,
            max: 2.0,
        },
        doc: "Downscale factor applied to the captured desktop. Reconnect.",
    },
    Key {
        path: "video.display-capture",
        kind: Kind::Choice {
            default: None,
            options: &["window", "display", "include"],
        },
        doc: "Which SCStream filter the host captures with. Reconnect.",
    },
    Key {
        path: "video.virtual-display",
        kind: Kind::Flag { default: None },
        doc: "Render the remote desktop onto a HiDPI virtual display. Reconnect.",
    },
    Key {
        path: "video.sharpen",
        kind: Kind::Float {
            default: None,
            min: 0.0,
            max: 2.0,
        },
        doc: "Unsharp-mask strength on the luma channel, client side. 0 is off.",
    },
];

/// The key at `path`, or `None` when nothing declares it.
#[must_use]
pub fn key(path: &str) -> Option<&'static Key> {
    KEYS.iter().find(|declared| declared.path == path)
}

/// Every top-level section, in table order and without repeats.
#[must_use]
pub fn sections() -> Vec<&'static str> {
    let mut seen: Vec<&'static str> = Vec::new();
    for declared in KEYS {
        let section = declared.path.split('.').next().unwrap_or(declared.path);
        if !seen.contains(&section) {
            seen.push(section);
        }
    }
    seen
}

#[cfg(test)]
mod tests {
    use super::{KEYS, Kind, key, sections};

    #[test]
    fn every_path_is_kebab_dotted_and_unique() {
        let mut seen: Vec<&str> = Vec::new();
        for declared in KEYS {
            assert!(
                !seen.contains(&declared.path),
                "{} is declared twice",
                declared.path
            );
            seen.push(declared.path);
            assert_eq!(
                declared.path.split('.').count(),
                2,
                "{} must be section.key",
                declared.path
            );
            assert!(
                declared
                    .path
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte == b'-' || byte == b'.'),
                "{} is not kebab-cased",
                declared.path
            );
        }
    }

    #[test]
    fn every_default_is_inside_its_own_domain() {
        for declared in KEYS {
            match declared.kind {
                Kind::Int { default, min, max } => {
                    if let Some(value) = default {
                        assert!((min..=max).contains(&value), "{}", declared.path);
                    }
                },
                Kind::Float { default, min, max } => {
                    if let Some(value) = default {
                        assert!(value >= min && value <= max, "{}", declared.path);
                    }
                },
                Kind::Choice { default, options } => {
                    if let Some(value) = default {
                        assert!(options.contains(&value), "{}", declared.path);
                    }
                    assert!(!options.is_empty(), "{}", declared.path);
                },
                Kind::Scale { default, options, .. } => {
                    assert!(options.contains(&default), "{}", declared.path);
                },
                Kind::Flag { .. } | Kind::Text { .. } | Kind::List => {},
            }
        }
    }

    #[test]
    fn every_row_says_what_it_does() {
        for declared in KEYS {
            assert!(declared.doc.len() > 20, "{} says too little", declared.path);
            assert!(declared.doc.ends_with('.'), "{}", declared.path);
        }
    }

    #[test]
    fn a_declared_path_is_found_and_an_undeclared_one_is_not() {
        assert!(key("controls.copy-on-select").is_some());
        assert!(key("controls.copyOnSelect").is_none());
    }

    #[test]
    fn the_sections_are_the_tables_the_file_is_written_in() {
        assert_eq!(sections().first().copied(), Some("general"));
        assert!(sections().contains(&"terminal"));
        assert_eq!(sections().len(), 10);
    }
}
