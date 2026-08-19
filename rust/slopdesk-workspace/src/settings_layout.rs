//! The SHAPE of a settings page: which groups it shows, in what order, what each row is, and which
//! platform each of those belongs to.
//!
//! [`settings_catalog`](crate::settings_catalog) says what a control OFFERS and
//! [`settings_rows`](crate::settings_rows) says what a setting IS. Neither says where it appears.
//! That was 2100 lines of `SwiftUI` body, and page structure is the last thing in Settings that was
//! still a fact spelled in a view.
//!
//! ## A platform gate is DATA
//!
//! This is the reason the module exists, more than the de-duplication. "The Dock icon group is
//! macOS-only" is a fact about the group, and it was spelled thirty-seven times as `#if os(macOS)`
//! scattered through one file — a form of conditional the two UI halves cannot share, cannot test,
//! and cannot even see the total of. As a [`Platform`] field on a group it is a value: the Mac
//! renderer asks for [`Platform::Mac`] rows, the phone renderer asks for [`Platform::Phone`] rows,
//! and NEITHER carries a gate. That is what lets `SlopDeskMacUI` hold its "not one `#if os(...)`"
//! rule while still drawing the macOS-only groups (docs/56 §3).
//!
//! ## What does NOT cross, and why
//!
//! A row names its setting by KEY; it does not carry a binding. `@Default(.onLaunch)` is a Swift
//! property wrapper over `UserDefaults`, so the key → binding step stays in each renderer as a
//! `switch`, exactly as `AllSettingsListView.inlineControl(for:)` already does. A row's LABEL does
//! not cross either — it is already in [`settings_rows`](crate::settings_rows), keyed by the same
//! string, and saying it twice here is what this whole port exists to stop.
//!
//! GOLDEN-SAFE: metadata only. Nothing here reads or writes a value or touches a wire codec.

use crate::settings_catalog::{ApplyTiming, Group, Ladder, Section, Stepper};

/// Which UI half draws a group or a row.
///
/// `Both` is the default and the common case; the two others are the settings whose BACKING is
/// absent on the other platform — a Dock, `LaunchServices` deep-links and `NSSound` on one side,
/// nothing on the other. A row is never hidden because a small screen is crowded: docs/56 §3 says
/// layout diverges and capability does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    /// Drawn by both halves.
    Both,
    /// macOS only — the backing API does not exist on iOS.
    Mac,
    /// iOS only.
    Phone,
}

impl Platform {
    /// The case index a platform crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Both => 0,
            Self::Mac => 1,
            Self::Phone => 2,
        }
    }

    /// Whether a half that identifies as `mac` draws this.
    #[must_use]
    pub const fn shown_on(self, mac: bool) -> bool {
        match self {
            Self::Both => true,
            Self::Mac => mac,
            Self::Phone => !mac,
        }
    }
}

/// What a row DRAWS. The renderer maps this to its framework's widget; the choice of widget for a
/// given setting is a design decision and belongs here rather than in whichever half was written
/// first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    /// A switch, with the leading SF Symbol the group's icon rail runs through.
    Toggle {
        /// The leading SF Symbol.
        glyph: &'static str,
    },
    /// A one-line pop-up menu over a [`Group`]'s options.
    ///
    /// The alternative is [`Control::Cards`], and the rule for picking is a MEASUREMENT of the
    /// longest label: a card is a fixed-width tile, so a group whose longest option is a sentence
    /// ("Only when source tab is unfocused") cannot use one.
    Menu {
        /// The options the menu lists.
        group: Group,
        /// The leading SF Symbol, when the group runs an icon rail through this row.
        glyph: Option<&'static str>,
    },
    /// A row of selectable cards over a [`Group`]'s options — art per option, chosen when the
    /// options differ in a way a word cannot show (a caret shape, a window size).
    Cards {
        /// The options the cards stand for.
        group: Group,
    },
    /// A slider with preset stops over a [`Ladder`].
    Slider {
        /// The scale, its stops and its readout.
        ladder: Ladder,
    },
    /// A plus/minus numeric field over a [`Stepper`] range.
    ///
    /// The sibling of [`Control::Slider`], and the choice between them is whether the useful values
    /// are a handful of magnitudes or a literal count — see [`Stepper`].
    Stepper {
        /// The ends, the granularity and the readout.
        range: Stepper,
    },
    /// A free-text field.
    Text {
        /// The leading SF Symbol, when the group runs an icon rail through this row.
        glyph: Option<&'static str>,
    },
    /// Prose that belongs to the group rather than to a setting — a footnote explaining why a
    /// choice the reader might expect is not offered. The words are the row's `subtitle`; a
    /// note has no label and no key, because it edits nothing.
    Note,
    /// A group the renderer draws itself, named by id.
    ///
    /// The escape hatch, and it is deliberately NARROW: it is for a group that is not a list of
    /// settings at all — a permission prompt, an install card with a privileged step, a live status
    /// readout. Reaching for it to avoid describing a plain toggle would put the row's words back
    /// in a view, which is the thing this module removes.
    Bespoke {
        /// What the renderer switches on to draw it.
        id: &'static str,
    },
}

impl Control {
    /// The case index a control crosses as.
    #[must_use]
    pub const fn kind(self) -> u8 {
        match self {
            Self::Toggle { .. } => 0,
            Self::Menu { .. } => 1,
            Self::Cards { .. } => 2,
            Self::Slider { .. } => 3,
            Self::Stepper { .. } => 4,
            Self::Text { .. } => 5,
            Self::Note => 6,
            Self::Bespoke { .. } => 7,
        }
    }

    /// The [`Group`], [`Ladder`] or [`Stepper`] index this control draws over, if it draws over
    /// one.
    ///
    /// One accessor for all three because no control carries two, and a renderer that has already
    /// read [`Control::kind`] knows which of them it is holding.
    #[must_use]
    pub const fn argument(self) -> Option<u8> {
        match self {
            Self::Menu { group, .. } | Self::Cards { group } => Some(group.index()),
            Self::Slider { ladder } => Some(ladder.index()),
            Self::Stepper { range } => Some(range.index()),
            Self::Toggle { .. } | Self::Text { .. } | Self::Note | Self::Bespoke { .. } => None,
        }
    }

    /// The leading SF Symbol, where the control has one.
    #[must_use]
    pub const fn glyph(self) -> Option<&'static str> {
        match self {
            Self::Toggle { glyph } => Some(glyph),
            Self::Menu { glyph, .. } | Self::Text { glyph } => glyph,
            Self::Cards { .. }
            | Self::Slider { .. }
            | Self::Stepper { .. }
            | Self::Note
            | Self::Bespoke { .. } => None,
        }
    }

    /// What the renderer switches on for a [`Control::Bespoke`] group, empty for every other kind.
    #[must_use]
    pub const fn bespoke_id(self) -> &'static str {
        match self {
            Self::Bespoke { id } => id,
            Self::Toggle { .. }
            | Self::Menu { .. }
            | Self::Cards { .. }
            | Self::Slider { .. }
            | Self::Stepper { .. }
            | Self::Text { .. }
            | Self::Note => "",
        }
    }
}

/// One row on a settings page.
#[derive(Debug, Clone, Copy)]
pub struct LayoutRow {
    /// The setting this row edits — a `SettingsKey` name, or a
    /// [`settings_rows`](crate::settings_rows) key for a render field. The row's LABEL is looked up
    /// from that table by this key, so it is never spelled twice.
    ///
    /// Empty for a [`Control::Bespoke`] group, which edits no single setting.
    pub key: &'static str,
    /// The gray line under the label, in the register of a page that has already named its section.
    /// Deliberately NOT the flat index's description — docs/56 §18.
    pub subtitle: &'static str,
    /// What the row draws.
    pub control: Control,
    /// Which half draws it.
    pub platform: Platform,
}

/// One titled group of rows on a settings page.
#[derive(Debug, Clone, Copy)]
pub struct LayoutGroup {
    /// The page this group sits on.
    pub section: Section,
    /// The group header, or EMPTY for a self-drawing group.
    ///
    /// An empty title says the group supplies its own header — it is a whole surface rather than a
    /// list of rows, so the renderer places it without a section wrapper of its own. Reserved for a
    /// group whose single row is [`Control::Bespoke`]; anything with rows to list has a name for
    /// them.
    pub title: &'static str,
    /// The rows, in reading order.
    pub rows: &'static [LayoutRow],
    /// The footer that tells the reader when an edit here takes effect.
    pub timing: ApplyTiming,
    /// Which half draws the group at all.
    pub platform: Platform,
}

/// Every group, page by page, in the order each page renders them.
///
/// Order here IS the rendered order, which is why this is one flat slice rather than a map: a map
/// would need a second list to say the order, and the two would drift.
pub const GROUPS: &[LayoutGroup] = &[
    // ── General ────────────────────────────────────────────────────────────────────────────────
    LayoutGroup {
        section: Section::General,
        title: "General",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "general.onLaunch",
            subtitle: "What a cold start opens.",
            control: Control::Menu {
                group: Group::OnLaunch,
                glyph: None,
            },
            platform: Platform::Both,
        }],
    },
    // The tab row drops `multiple_tabs` (a tab close loses exactly one tab, so the policy could
    // never fire) but otherwise shares the window row's wording — `CloseConfirmationTab`'s options
    // are a prefix of `CloseConfirmation`'s, so the two rows cannot describe one policy differently.
    LayoutGroup {
        section: Section::General,
        title: "Close Confirmation",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "shell.closeConfirm.tab",
                subtitle: "When to ask before a tab goes away. ⌘W closes a pane and only ever asks \
                           mid-command.",
                control: Control::Menu {
                    group: Group::CloseConfirmationTab,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "shell.closeConfirm.window",
                subtitle: "When to ask before a window goes away.",
                control: Control::Menu {
                    group: Group::CloseConfirmation,
                    glyph: None,
                },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::General,
        title: "Privacy & New Panes",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "features.redactSecrets",
            subtitle: "Mask token- and key-shaped runs in tab titles so a screen share can't leak them.",
            control: Control::Toggle { glyph: "eye.slash" },
            platform: Platform::Both,
        }],
    },
    // The one device-local knob on this page (docs/45 §8.2), and the one whose DEFAULT differs by
    // platform — which is exactly why it needs a control on both. `Platform::Both`, emphatically.
    LayoutGroup {
        section: Section::General,
        title: "Shared Focus",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "follow-session-focus",
            subtitle: "Switching tab or pane here moves every device that follows. Off keeps this device's \
                       view to itself — the others still see where it is looking.",
            control: Control::Toggle { glyph: "viewfinder" },
            platform: Platform::Both,
        }],
    },
    // macOS-only: `DefaultTerminalIntegration` is LaunchServices plus a System-Settings deep-link,
    // and iOS has neither. It reuses the first-launch sheet's actions so the buttons stay REACHABLE
    // after "Skip Setup", which is the bug that put it on this page.
    LayoutGroup {
        section: Section::General,
        title: "OS Integration",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "os-integration" },
            platform: Platform::Mac,
        }],
    },
    // ── Shell ──────────────────────────────────────────────────────────────────────────────────
    // The notification groups live on Shell, not General (`notification-setting.png`), and each is
    // backed by the pure `NotificationPolicy` engine rather than by a deferred stub.
    LayoutGroup {
        section: Section::Shell,
        title: "Notification",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "",
                subtitle: "",
                control: Control::Bespoke {
                    id: "notification-permission",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.osc",
                subtitle: "Allow shell apps to send system notifications (OSC 9 / 777 / 99).",
                control: Control::Toggle { glyph: "bell" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.onFinish",
                subtitle: "Notify when a background command finishes (exit 0).",
                control: Control::Toggle {
                    glyph: "checkmark.circle",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.onError",
                subtitle: "Notify when a command fails (exits non-zero).",
                control: Control::Toggle {
                    glyph: "xmark.octagon",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.onWatchFinish",
                subtitle: "Notify when an `slopdesk watch`-wrapped command finishes.",
                control: Control::Toggle { glyph: "eye" },
                platform: Platform::Both,
            },
            // A menu, not cards: its longest option is a whole sentence, which no fixed-width tile
            // carries. It still takes the group's leading glyph so the icon rail runs unbroken.
            LayoutRow {
                key: "notifications.whileForeground",
                subtitle: "Banner behavior while slopdesk is the foreground app.",
                control: Control::Menu {
                    group: Group::NotifyWhileForeground,
                    glyph: Some("app.badge"),
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.longCommand",
                subtitle: "Also notify when a slow command finishes in an unfocused pane.",
                control: Control::Toggle { glyph: "hourglass" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.bounceDock",
                subtitle: "Bounce the Dock icon when a notification arrives and slopdesk isn't focused.",
                control: Control::Toggle {
                    glyph: "arrow.up.doc",
                },
                platform: Platform::Mac,
            },
        ],
    },
    // The three COMMAND-driven badges, distinct from the Agents page's agent badges so the two kinds
    // stay independent. "When Command Awaits Input" ships ahead of its signal — the host detector
    // behind it is a deferred ceiling (docs/DECISIONS.md).
    LayoutGroup {
        section: Section::Shell,
        title: "Tab Badge",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "tabBadge.onCommandFinish",
                subtitle: "Badge the tab when a command exits successfully.",
                control: Control::Toggle {
                    glyph: "checkmark.circle",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "tabBadge.onCommandFail",
                subtitle: "Badge the tab when a command exits non-zero.",
                control: Control::Toggle {
                    glyph: "xmark.octagon",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "tabBadge.onCommandAwaitInput",
                subtitle: "Badge the tab when a command stops at an interactive prompt.",
                control: Control::Toggle {
                    glyph: "questionmark.circle",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "tabBadge.busyDelaySeconds",
                subtitle: "How long a command must run before its row shows as busy — a fast `ls` never \
                           flashes the rail.",
                control: Control::Slider {
                    ladder: Ladder::BusyDelay,
                },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Shell,
        title: "Sound",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "notifications.soundShellControlled",
                subtitle: "Let shell apps ring the terminal bell (BEL) as the system alert sound.",
                control: Control::Toggle {
                    glyph: "speaker.wave.2",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.soundOnErrorExit",
                subtitle: "Beep when a command exits non-zero (requires shell integration).",
                control: Control::Toggle {
                    glyph: "speaker.wave.3",
                },
                platform: Platform::Both,
            },
        ],
    },
    // Claude-only, and IPC-driven, so it needs no shell integration. The SOUND halves are macOS-only
    // (`NSSound` plus the system-sound library); iOS omits them rather than showing dead toggles.
    LayoutGroup {
        section: Section::Shell,
        title: "Code Agent",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "notifications.agentTaskComplete",
                subtitle: "Notify when a coding agent finishes a task and goes idle.",
                control: Control::Toggle { glyph: "sparkles" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.agentAwaitInput",
                subtitle: "Notify when a coding agent needs approval or input.",
                control: Control::Toggle { glyph: "hand.raised" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "notifications.agentSoundTaskComplete",
                subtitle: "Play a sound when a coding agent finishes a turn.",
                control: Control::Toggle {
                    glyph: "speaker.wave.2",
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "notifications.agentSoundAwaitInput",
                subtitle: "Play a sound when a coding agent needs approval or input.",
                control: Control::Toggle {
                    glyph: "speaker.wave.3",
                },
                platform: Platform::Mac,
            },
        ],
    },
    // Working Directory's home is Shell, per `spec/user-interface__window-tab-split.md` and
    // `open-option.png`.
    LayoutGroup {
        section: Section::Shell,
        title: "Working Directory",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "shell.workingDirectory.newWindow",
                subtitle: "",
                control: Control::Menu {
                    group: Group::WorkingDirectory,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "shell.workingDirectory.newTab",
                subtitle: "",
                control: Control::Menu {
                    group: Group::WorkingDirectory,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "shell.workingDirectory.newSplit",
                subtitle: "",
                control: Control::Menu {
                    group: Group::WorkingDirectory,
                    glyph: None,
                },
                platform: Platform::Both,
            },
        ],
    },
    // macOS-only: the `/usr/local/bin` symlink and its admin escalation have no iOS form, so the
    // phone omits the card rather than offering an install that cannot happen.
    LayoutGroup {
        section: Section::Shell,
        title: "SlopDesk CLI",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "cli-install" },
            platform: Platform::Mac,
        }],
    },
    // ── Controls ───────────────────────────────────────────────────────────────────────────────
    LayoutGroup {
        section: Section::Controls,
        title: "Selection",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "controls.shiftArrowSelect",
                subtitle: "Use Shift+arrows to drive a native selection instead of forwarding the arrow \
                           escapes.",
                control: Control::Toggle {
                    glyph: "character.cursor.ibeam",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.clearSelectionOnTyping",
                subtitle: "Drop the selection the moment any key is sent to the program.",
                control: Control::Toggle { glyph: "keyboard" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.clearSelectionOnCopy",
                subtitle: "Drop the highlight after an explicit copy (does not apply when Copy on Select \
                           fires).",
                control: Control::Toggle { glyph: "doc.on.doc" },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Controls,
        title: "Copy & Paste",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "controls.copyOnSelect",
                subtitle: "Copy the selection to the pasteboard as soon as it is made.",
                control: Control::Toggle { glyph: "doc.on.doc" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.trimTrailingSpaces",
                subtitle: "Strip trailing whitespace from each copied line.",
                control: Control::Toggle { glyph: "scissors" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.pasteProtection",
                subtitle: "Warn before pasting multi-line, trailing-newline, sudo/su, or control-character \
                           text.",
                control: Control::Toggle { glyph: "shield" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.pasteBracketedSafe",
                subtitle: "Skip the paste warning when the receiving program advertises bracketed-paste \
                           support.",
                control: Control::Toggle {
                    glyph: "shield.lefthalf.filled",
                },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Controls,
        title: "Scroll",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            // The stops name the values that MEAN something (half speed, the 1× identity, double,
            // triple), so "put it back to normal" is one tap rather than a drag hunt for exactly 1.00.
            LayoutRow {
                key: "controls.scrollMultiplier",
                subtitle: "Scales every scroll gesture's distance.",
                control: Control::Slider {
                    ladder: Ladder::ScrollMultiplier,
                },
                platform: Platform::Both,
            },
            // Was a stepper at 1 000 lines a click, so crossing its own range took 99 clicks and the
            // deep end was unreachable. The magnitude stops make every useful depth one tap.
            LayoutRow {
                key: "scrollback-limit",
                subtitle: "How much history each pane keeps. Deeper buffers cost host memory per pane.",
                control: Control::Slider {
                    ladder: Ladder::Scrollback,
                },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Controls,
        title: "Mouse",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "controls.focusFollowsMouse",
                subtitle: "Focus the pane under the mouse cursor automatically.",
                control: Control::Toggle {
                    glyph: "pointer.arrow.rays",
                },
                platform: Platform::Both,
            },
            // A MENU, not cards: five actions with no shared geometry to draw. Their difference is
            // the verb, and a glyph standing in for a verb adds a picture frame, not information.
            LayoutRow {
                key: "controls.rightClickAction",
                subtitle: "What right-click does in the terminal viewport (Ctrl+right-click always opens \
                           the menu).",
                control: Control::Menu {
                    group: Group::RightClickAction,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.mouseHideWhileTyping",
                subtitle: "Hide the mouse cursor while the keyboard is in use.",
                control: Control::Toggle {
                    glyph: "pointer.arrow.slash",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.allowShiftClick",
                subtitle: "Hold Shift to select text even when the running app captures the mouse.",
                control: Control::Toggle {
                    glyph: "pointer.arrow.click",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.clickToMove",
                subtitle: "Click in the prompt to move the shell cursor — sends arrow keys across \
                           soft-wrapped rows.",
                control: Control::Toggle {
                    glyph: "pointer.arrow.motionlines",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.allowMouseCapture",
                subtitle: "Allow shell apps to capture mouse events (e.g. vim, tmux).",
                control: Control::Toggle {
                    glyph: "rectangle.and.hand.point.up.left",
                },
                platform: Platform::Both,
            },
        ],
    },
    // The HONESTY CEILING (docs/DECISIONS.md): a per-target "Open Files / Folders With → [app]"
    // surrogate needs a LOCAL file pane slopdesk cannot offer for a REMOTE host. So instead of dead
    // Browser / Finder target pickers, the actionable keys are surfaced and the rest is the footnote.
    LayoutGroup {
        section: Section::Controls,
        title: "Open With",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "controls.linkDetection",
                subtitle: "Underline paths and URLs in terminal output on Cmd-hover so they are clickable.",
                control: Control::Toggle { glyph: "" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.linkCmdClick",
                subtitle: "Open in the best handler (files / folders open on the host, URLs in your \
                           browser), copy the path / URL, or do nothing.",
                control: Control::Menu {
                    group: Group::LinkCmdClick,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.linkCmdShiftClick",
                subtitle: "Reveal the path in the host Finder, or open it with the host's system-default \
                           app.",
                control: Control::Menu {
                    group: Group::LinkCmdShiftClick,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "",
                subtitle: "Files and folders live on the remote host, so per-target \u{201C}Open \
                           in…\u{201D} file / folder panes are not available here — paths reveal or open on \
                           the host and URLs open in your client browser.",
                control: Control::Note,
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Controls,
        title: "Link Schemes",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "controls.autoDetectLinkSchemes",
                subtitle: "Which URL schemes get underlined on Cmd-hover and made clickable. All detects \
                           any scheme://; Custom restricts to the schemes you list. http(s), file, and \
                           mailto are always detected.",
                control: Control::Menu {
                    group: Group::AutoDetectLinkSchemes,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            // Drawn only while the mode above is Custom. That is a condition on another setting's
            // VALUE, which is dynamic rather than layout, so it stays with the renderer.
            LayoutRow {
                key: "controls.customLinkSchemes",
                subtitle: "Comma-separated extra schemes to additionally detect (e.g. codex, ssh, vscode).",
                control: Control::Text { glyph: None },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Controls,
        title: "Keyboard",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "controls.undoAtPrompt",
                subtitle: "Press Cmd-Z at the shell prompt to emit the readline undo sequence.",
                control: Control::Toggle {
                    glyph: "arrow.uturn.backward",
                },
                platform: Platform::Both,
            },
            // Four labels that read almost identically as prose become four distinct key-row
            // silhouettes — the lit ⌥ caps ARE the setting, which is what a card can show and a menu
            // cannot.
            LayoutRow {
                key: "controls.optionAsAlt",
                subtitle: "Treat the macOS Option key as Alt/Meta so terminal apps see Esc-prefixed \
                           sequences (Emacs, Vim word-jumps, readline). Off keeps Option free for accented \
                           characters.",
                control: Control::Cards {
                    group: Group::OptionAsAlt,
                },
                platform: Platform::Both,
            },
        ],
    },
    // macOS-only: `EnableSecureEventInput` is process-global and has no iOS form. The keys still
    // compile and round-trip on both, so the all-settings list advertises them either way.
    LayoutGroup {
        section: Section::Controls,
        title: "Secure Input",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[
            LayoutRow {
                key: "controls.autoSecureInput",
                subtitle: "Automatically engage macOS Secure Keyboard Entry when the remote shell shows a \
                           hidden password prompt (sudo, ssh, read -s), so no other app can read your \
                           keystrokes.",
                control: Control::Toggle { glyph: "lock.shield" },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "controls.secureInputIndicator",
                subtitle: "Show the SECURE INPUT pill in the pane while secure keyboard entry is active.",
                control: Control::Toggle {
                    glyph: "eye.trianglebadge.exclamationmark",
                },
                platform: Platform::Mac,
            },
        ],
    },
    // ── Editor ─────────────────────────────────────────────────────────────────────────────────
    // RESERVED. slopdesk has no file editor, so this page has no settings and says so — an empty
    // state, not a list of dead rows. That it is empty is still a fact about the page, so it is
    // described rather than left for each renderer to discover by finding no groups: a page with no
    // groups at all is indistinguishable from a page this build predates.
    LayoutGroup {
        section: Section::Editor,
        title: "Editor",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "editor-empty" },
            platform: Platform::Both,
        }],
    },
    // ── Agents ─────────────────────────────────────────────────────────────────────────────────
    // CLAUDE CODE ONLY. `MetadataCodec::AgentKind::Codex` is documented-dead and never rendered, so
    // there is no second card to describe.
    //
    // The two NOTIFY toggles that used to sit under Agent Behaviour are gone from this page. They
    // edit `notifications.agentTaskComplete` and `notifications.agentAwaitInput`, which the Shell
    // page's Code Agent group already edits — two live controls over one value, which the table
    // forbids and which is exactly the kind of thing describing a page finds.
    LayoutGroup {
        section: Section::Agents,
        title: "Claude Code",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "claude-hooks" },
            platform: Platform::Both,
        }],
    },
    // Greyed until an integration is installed — a condition on the CONTROLLER's live state, not on
    // another setting, so it is the renderer's to apply.
    LayoutGroup {
        section: Section::Agents,
        title: "Agent Behaviour",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "agents.badgeWhileProcessing",
                subtitle: "Ring the tab while the agent is working.",
                control: Control::Toggle {
                    glyph: "circle.dashed",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "agents.badgeWhenComplete",
                subtitle: "Mark the tab when the agent goes idle.",
                control: Control::Toggle {
                    glyph: "checkmark.circle",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "agents.badgeWhenAwaitingInput",
                subtitle: "Mark the tab when the agent needs approval.",
                control: Control::Toggle { glyph: "hand.raised" },
                platform: Platform::Both,
            },
            // Drawn only while the group is greyed, which is the renderer's to decide — but the
            // WORDS are the group's, so they are here with the rest of the page's.
            LayoutRow {
                key: "",
                subtitle: "Install an integration above to configure agent behaviour.",
                control: Control::Note,
                platform: Platform::Both,
            },
        ],
    },
    // The HOST half of the same idea, and the reason it is a group of its own rather than two more
    // rows above: these ride the sidecar, so they apply on reconnect and the footer has to say so.
    LayoutGroup {
        section: Section::Agents,
        title: "Agent Behaviour (host)",
        timing: ApplyTiming::Reconnect,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "agent-prevent-sleep",
                subtitle: "Keep the host awake while an agent is working.",
                control: Control::Toggle { glyph: "zzz" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "agent-resume-on-recovery",
                subtitle: "Re-arm a detached agent session when the connection comes back.",
                control: Control::Toggle {
                    glyph: "arrow.clockwise",
                },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Agents,
        title: "Behaviour",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "features.recordClipboardHistory",
            subtitle: "Archive copied text into the clipboard-history ring.",
            control: Control::Toggle {
                glyph: "doc.on.clipboard",
            },
            platform: Platform::Both,
        }],
    },
    // ── Appearance ─────────────────────────────────────────────────────────────────────────────
    // There is no LAYOUT selector (Vertical Tabs / Tabs Top / Tabs Bottom) and no THEME gallery, and
    // neither absence is a gap to backfill: slopdesk is vertical-tabs-only and ships ONE appearance
    // (user-directed 2026-08-08), so both would be controls with a single actuatable state.
    LayoutGroup {
        section: Section::Appearance,
        title: "Tabs",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            // Cards, because the choice is a POSITION in a column and the diagram draws the incoming
            // row at the slot the policy inserts it — which three words cannot.
            LayoutRow {
                key: "shell.newTabPosition",
                subtitle: "Where a new tab lands in the sidebar.",
                control: Control::Cards {
                    group: Group::NewTabPosition,
                },
                platform: Platform::Both,
            },
            // Filed under Tabs rather than Keyboard: what it changes is what the WORKSPACE does while
            // the chord is held, not what the chord is.
            LayoutRow {
                key: "controls.paneSwitcherPreview",
                subtitle: "As ⌃⇥ walks the pane list, show each pane underneath the switcher.",
                control: Control::Toggle {
                    glyph: "rectangle.on.rectangle",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "shell.autoHideTabsPanel",
                subtitle: "When to show the tabs panel in Sidebar layout.",
                control: Control::Menu {
                    group: Group::AutoHideTabsPanel,
                    glyph: None,
                },
                platform: Platform::Both,
            },
        ],
    },
    // macOS-only: a window's initial dimensions, a dedicated desktop window and background-pointer
    // key semantics are all `NSWindow` concepts, and iOS has no resizable window to size.
    LayoutGroup {
        section: Section::Appearance,
        title: "Window",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[
            // Each card draws the UNIT its mode measures in — a dashed ghost of the remembered frame,
            // actual cells for the grid, the two pixel rules for the frame.
            LayoutRow {
                key: "window.size",
                subtitle: "How new windows decide their initial dimensions. Applied once per window opened, \
                           so a later manual resize is never fought.",
                control: Control::Cards {
                    group: Group::WindowSize,
                },
                platform: Platform::Mac,
            },
            // The four fields below are drawn in pairs, and which pair depends on the value of the
            // row above. That is a condition on another setting's VALUE — dynamic, not layout — so
            // the rows are here and the choosing stays with the renderer.
            LayoutRow {
                key: "window.cols",
                subtitle: "",
                control: Control::Stepper {
                    range: Stepper::WindowCells,
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "window.rows",
                subtitle: "",
                control: Control::Stepper {
                    range: Stepper::WindowCells,
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "window.widthPx",
                subtitle: "",
                control: Control::Stepper {
                    range: Stepper::WindowPixels,
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "window.heightPx",
                subtitle: "",
                control: Control::Stepper {
                    range: Stepper::WindowPixels,
                },
                platform: Platform::Mac,
            },
            // Fullscreen is the Parsec model; borderless is the Parallels one, where the LOCAL menu
            // bar needs a top-edge dwell because a bare touch there reaches the REMOTE menu bar.
            LayoutRow {
                key: "desktopWindow.presentation",
                subtitle: "Fullscreen captures system shortcuts (⌘Tab) for the host while it lasts. \
                           Borderless keeps the local menu bar away until the pointer dwells at the top \
                           edge.",
                control: Control::Cards {
                    group: Group::DesktopPresentation,
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "satelliteWindow.backgroundPointer",
                subtitle: "Point, click and scroll in a remote desktop window without focusing it — typing \
                           stays in the window you are working in.",
                control: Control::Toggle {
                    glyph: "hand.point.up.left",
                },
                platform: Platform::Mac,
            },
        ],
    },
    LayoutGroup {
        section: Section::Appearance,
        title: "Appearance",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "appearance.density",
            subtitle: "How much air each sidebar row gets.",
            control: Control::Cards {
                group: Group::Density,
            },
            platform: Platform::Both,
        }],
    },
    // The FAMILY group stays bespoke: it is a pair of scope tabs over two different bodies — the
    // primary family with its three derived faces, or the ordered fallback list — plus an "Aa"
    // specimen field. A scope tab is a control whose choice picks which OTHER controls exist, which
    // no row here describes. The three sections after it are ordinary lists and are described as
    // such, which is what took their four option lists out of inline `Text(…).tag(…)` children.
    LayoutGroup {
        section: Section::Appearance,
        title: "Font Family",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "font-family" },
            platform: Platform::Both,
        }],
    },
    LayoutGroup {
        section: Section::Appearance,
        title: "Text",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "font-size",
                subtitle: "",
                control: Control::Stepper {
                    range: Stepper::FontPoints,
                },
                platform: Platform::Both,
            },
            // Picking `custom` opens a multiplier slider and a note about the reflow it causes. Both
            // are conditioned on this row's VALUE, so they belong to the renderer the same way the
            // window steppers and the custom link schemes do.
            LayoutRow {
                key: "font-line-height",
                subtitle: "",
                control: Control::Menu {
                    group: Group::LineHeight,
                    glyph: None,
                },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Appearance,
        title: "Ligatures",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "font-ligatures",
                subtitle: "",
                control: Control::Menu {
                    group: Group::FontLigatures,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "font-ligatures-alphabet",
                subtitle: "Ligate letter runs too, not only punctuation.",
                control: Control::Toggle {
                    glyph: "textformat.abc",
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "",
                subtitle: "Requires a font with ligatures (e.g. Fira Code, JetBrains Mono); the default SF \
                           Mono has none.",
                control: Control::Note,
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::Appearance,
        title: "Style & Rendering",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "font-bold",
                subtitle: "",
                control: Control::Menu {
                    group: Group::FontStyleMode,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "font-italic",
                subtitle: "",
                control: Control::Menu {
                    group: Group::FontStyleMode,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "font-blending",
                subtitle: "",
                control: Control::Menu {
                    group: Group::FontBlending,
                    glyph: None,
                },
                platform: Platform::Both,
            },
        ],
    },
    // ONE caret surface, both halves: the live preview card, the two colour wells, the opacity
    // slider, the style cards and the blink menu. This was two groups sharing a title — the Mac's
    // bespoke surface and a phone reduced to `cursor-style` + `cursor-style-blink` as plain rows —
    // on the stated grounds that the preview is AppKit. It never was: `CursorPreviewView` is pure
    // SwiftUI down to `Color.resolve(in:)`, with no `NSColor` anywhere in the file. The gate cost the
    // phone the cursor colour, the text-under colour and the opacity outright, which is a capability
    // difference, not a drawing one — and docs/56 §3 lets only the drawing diverge.
    LayoutGroup {
        section: Section::Appearance,
        title: "Cursor",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "cursor-preview" },
            platform: Platform::Both,
        }],
    },
    // macOS-only for the plainest reason there is: iOS has no Dock. Both toggles actuate
    // `DockProgressController` through the pure `DockTintPolicy`, so neither is dead UI.
    LayoutGroup {
        section: Section::Appearance,
        title: "Dock Icon",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[
            LayoutRow {
                key: "appearance.dockIconAnimateProgress",
                subtitle: "Fill the Dock tile as a running command progresses.",
                control: Control::Toggle {
                    glyph: "chart.bar.fill",
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "appearance.dockIconErrorBadge",
                subtitle: "Tint the Dock tile when a command exits non-zero.",
                control: Control::Toggle {
                    glyph: "exclamationmark.octagon",
                },
                platform: Platform::Mac,
            },
        ],
    },
    // ── Key Bindings ───────────────────────────────────────────────────────────────────────────
    // The chord editor is one surface with sections of its own — the search field, the action list,
    // the recorder — so the table claims no header for it. Cross-platform: a phone with a hardware
    // keyboard attached runs the same bindings, and the LIST is readable with none.
    LayoutGroup {
        section: Section::Keybindings,
        title: "",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "keybindings" },
            platform: Platform::Both,
        }],
    },
    // ── Advanced ───────────────────────────────────────────────────────────────────────────────
    // The privilege surface is CROSS-PLATFORM on purpose: these gate what a REMOTE escape sequence
    // may do on the client, and a phone attached to the same host is exposed to the same sequences.
    LayoutGroup {
        section: Section::Advanced,
        title: "Privileges",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "controls.titleShellControlled",
                subtitle: "Allow programs to set the tab and window title via OSC 0 / OSC 2.",
                control: Control::Toggle { glyph: "textformat" },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.clipboardShellControlled",
                subtitle: "Master switch for OSC 52 clipboard access. When off, clipboard read and write \
                           are denied.",
                control: Control::Toggle {
                    glyph: "doc.on.clipboard",
                },
                platform: Platform::Both,
            },
            // Both are drawn disabled while the master above is off — a condition on another
            // setting's VALUE, so it is dynamic rather than layout.
            LayoutRow {
                key: "controls.clipboardRead",
                subtitle: "Whether a program may READ the clipboard via OSC 52.",
                control: Control::Menu {
                    group: Group::ClipboardAccess,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "controls.clipboardWrite",
                subtitle: "Whether a program may WRITE the clipboard via OSC 52.",
                control: Control::Menu {
                    group: Group::ClipboardAccess,
                    glyph: None,
                },
                platform: Platform::Both,
            },
        ],
    },
    // The raw `SLOPDESK_*` box is a HOST-side concern, so the phone omits it rather than offering an
    // editor over flags the device it runs on never reads.
    LayoutGroup {
        section: Section::Advanced,
        title: "Raw overrides",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "raw-overrides" },
            platform: Platform::Mac,
        }],
    },
    // The video flags, in four groups because they land at three different times and on two
    // different machines. They were ONE bespoke surface, on the stated grounds that a
    // `VideoPreferences` field has an unset state and no control kind here describes one. The
    // premise was true and the conclusion did not follow: unset means "the value the daemon would
    // have picked anyway", which is a DEFAULT, and a row that reads its default through a named
    // constant is what every other sidecar-backed row already does (`agent-prevent-sleep`). The
    // hatch cost these six rows their place in the all-settings index — a search for `FEC` matched
    // nothing — which is the thing the index exists to prevent.
    LayoutGroup {
        section: Section::Advanced,
        title: "Video · Quality (host)",
        timing: ApplyTiming::Reconnect,
        platform: Platform::Mac,
        rows: &[
            LayoutRow {
                key: "video-qp-sharp",
                subtitle: "The sharpest quantiser on a clean link. Lower is crisper and costlier.",
                control: Control::Stepper {
                    range: Stepper::VideoQp,
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "video-qp-coarse",
                subtitle: "The coarsest quantiser under congestion. Higher trades detail for pace.",
                control: Control::Stepper {
                    range: Stepper::VideoQp,
                },
                platform: Platform::Mac,
            },
        ],
    },
    LayoutGroup {
        section: Section::Advanced,
        title: "Video · Forward Error Correction",
        timing: ApplyTiming::Reconnect,
        platform: Platform::Mac,
        rows: &[
            LayoutRow {
                key: "video-fec-m",
                subtitle: "Parity shards per group. Two or more repairs multi-packet loss.",
                control: Control::Stepper {
                    range: Stepper::VideoFecParity,
                },
                platform: Platform::Mac,
            },
            LayoutRow {
                key: "video-fec-k",
                subtitle: "Data shards one parity group covers. Read only once parity is 2 or more.",
                control: Control::Stepper {
                    range: Stepper::VideoFecGroup,
                },
                platform: Platform::Mac,
            },
            // The warning was a hand-placed `HStack` with a triangle glyph inside the surface. It
            // is prose about the group rather than about either row, which is what a note is.
            LayoutRow {
                key: "",
                subtitle: "Both ends must agree: set these IDENTICALLY on the host and the client, or the \
                           two disagree about how to rebuild a lost packet.",
                control: Control::Note,
                platform: Platform::Mac,
            },
        ],
    },
    LayoutGroup {
        section: Section::Advanced,
        title: "Video · Pacer",
        timing: ApplyTiming::Reconnect,
        platform: Platform::Mac,
        rows: &[LayoutRow {
            key: "video-pacer",
            subtitle: "Whether a decoded frame waits for a smoothness deadline or shows on arrival.",
            control: Control::Menu {
                group: Group::VideoPacer,
                glyph: None,
            },
            platform: Platform::Mac,
        }],
    },
    // The one video row a phone reaches. The other five are read by the host daemon off a sidecar
    // file on the machine hostd runs on, so a phone editing them would write a file nothing opens;
    // this one is `MetalVideoRenderer`'s own unsharp pass, in the client, on whichever device is
    // doing the looking — and a phone screen at a 1x stream is exactly where it earns its keep.
    LayoutGroup {
        section: Section::Advanced,
        title: "Video · Client render",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "video-sharpen",
            subtitle: "Unsharp-mask strength on the luma channel. Crisps text, cannot restore detail.",
            control: Control::Slider {
                ladder: Ladder::VideoSharpen,
            },
            platform: Platform::Both,
        }],
    },
    // The config file lives under `~/.config`, which iOS has no path to.
    LayoutGroup {
        section: Section::Advanced,
        title: "Config File",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "config-file" },
            platform: Platform::Mac,
        }],
    },
    // The searchable list of every setting, plus the two resets. It draws its own header and its own
    // search field, and it is the one surface on this page both halves need.
    LayoutGroup {
        section: Section::Advanced,
        title: "",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "all-settings" },
            platform: Platform::Both,
        }],
    },
];

/// The groups one page shows on one half, in render order.
#[must_use]
pub fn groups(section: Section, mac: bool) -> Vec<&'static LayoutGroup> {
    GROUPS
        .iter()
        .filter(|group| group.section == section && group.platform.shown_on(mac))
        .collect()
}

/// The rows one group shows on one half, in render order.
#[must_use]
pub fn rows(group: &'static LayoutGroup, mac: bool) -> Vec<&'static LayoutRow> {
    group
        .rows
        .iter()
        .filter(|row| row.platform.shown_on(mac))
        .collect()
}

/// The group at a flat position, filtered to one half — the indexing the boundary carries.
#[must_use]
pub fn group_at(section: Section, mac: bool, index: usize) -> Option<&'static LayoutGroup> {
    groups(section, mac).get(index).copied()
}

/// The row at a flat position within a filtered group.
#[must_use]
pub fn row_at(
    section: Section,
    mac: bool,
    group_index: usize,
    row_index: usize,
) -> Option<&'static LayoutRow> {
    rows(group_at(section, mac, group_index)?, mac)
        .get(row_index)
        .copied()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings_rows;

    /// Every row names a setting the row table also carries, because the row table is where the
    /// LABEL comes from. A key with no row renders a header with no words under it.
    #[test]
    fn every_row_names_a_setting_that_has_a_label() {
        for group in GROUPS {
            for row in group.rows {
                if matches!(row.control, Control::Bespoke { .. } | Control::Note) {
                    assert!(
                        row.key.is_empty(),
                        "{} draws itself, so it names no single key",
                        group.title
                    );
                    continue;
                }
                assert!(
                    settings_rows::row(row.key).is_some(),
                    "{} → {} names no row, so it has no label to render",
                    group.title,
                    row.key,
                );
            }
        }
    }

    /// A row is never MORE available than the group that contains it — a `Both` row inside a `Mac`
    /// group is a row the phone can never reach, written as though it could.
    #[test]
    fn a_row_is_never_wider_than_its_group() {
        for group in GROUPS {
            for row in group.rows {
                assert!(
                    group.platform == Platform::Both || row.platform == group.platform,
                    "{} is {:?} but a row inside it claims {:?}",
                    group.title,
                    group.platform,
                    row.platform,
                );
            }
        }
    }

    /// The video flags split by WHICH MACHINE READS THEM, not by which page they sit on.
    ///
    /// Five are folded into `video-prefs.json` and read by the host daemon at launch, so a phone
    /// editing one would write a file nothing on that device opens. `video-sharpen` is
    /// `MetalVideoRenderer`'s unsharp pass, in the client, on whichever device is looking — and a
    /// phone at a 1x stream is where it earns its keep. Asserted per key rather than per group so
    /// moving one between groups cannot quietly move it between platforms.
    #[test]
    fn only_the_client_side_video_row_reaches_the_phone() {
        let reachable = |mac: bool| -> Vec<&'static str> {
            groups(Section::Advanced, mac)
                .iter()
                .flat_map(|group| rows(group, mac))
                .map(|row| row.key)
                .filter(|key| key.starts_with("video-"))
                .collect()
        };
        assert_eq!(
            reachable(false),
            ["video-sharpen"],
            "the phone reaches exactly the row its own renderer reads",
        );
        for key in [
            "video-qp-sharp",
            "video-qp-coarse",
            "video-fec-m",
            "video-fec-k",
            "video-pacer",
            "video-sharpen",
        ] {
            assert!(reachable(true).contains(&key), "the Mac lost {key}");
        }
    }

    /// Every group has at least one row on the half that draws it. An empty group is a header with
    /// nothing under it, which is what a badly-placed platform gate produces.
    #[test]
    fn no_half_ever_draws_an_empty_group() {
        for mac in [true, false] {
            for section in Section::ALL {
                for group in groups(section, mac) {
                    assert!(
                        !rows(group, mac).is_empty(),
                        "{} draws empty on {}",
                        group.title,
                        if mac { "macOS" } else { "iOS" },
                    );
                }
            }
        }
    }

    /// Every section the navigator lists is described here for both halves. A page that resolves to
    /// no groups reads to a renderer exactly like a page whose groups this build predates, so
    /// "nothing to show" is stated — the reserved Editor page says its own emptiness — rather than
    /// left as an absence.
    #[test]
    fn every_page_the_navigator_lists_is_described_for_both_halves() {
        for mac in [true, false] {
            for section in Section::ALL {
                assert!(
                    !groups(section, mac).is_empty(),
                    "{} describes nothing on {}",
                    section.id(),
                    if mac { "macOS" } else { "iOS" },
                );
            }
        }
    }

    /// A group with no header of its own draws ITSELF — the escape hatch for a surface that is not
    /// a list of rows at all. Anything with rows to list has a name for them, so the empty
    /// title is only ever paired with a single bespoke row.
    #[test]
    fn a_group_without_a_header_is_one_that_draws_itself() {
        for group in GROUPS {
            if !group.title.is_empty() {
                continue;
            }
            assert_eq!(
                group.rows.len(),
                1,
                "a headerless group on {} lists rows nothing names",
                group.section.id(),
            );
            for row in group.rows {
                assert!(
                    matches!(row.control, Control::Bespoke { .. }),
                    "a headerless group on {} holds a described row, which would render unlabelled",
                    group.section.id(),
                );
            }
        }
    }

    /// No page repeats a group header ON ONE HALF, and no group repeats a key.
    ///
    /// The qualifier is the interesting half of it: the rule is about what ONE reader sees on ONE
    /// page, so two groups sharing a title is only a fault when their platforms overlap. No pair in
    /// the table takes that allowance today — the cursor group did until it turned out to be one
    /// group with a gate on it — and a new one would have to argue for itself, since a title is the
    /// only handle a reader has on a group. A headerless group is identified by its bespoke id
    /// instead, which is what the near side keys it by.
    #[test]
    fn a_group_is_named_once_and_edits_each_setting_once() {
        let mut seen_titles: Vec<(&str, &str, Platform)> = Vec::new();
        let mut seen_keys = Vec::new();
        for group in GROUPS {
            let name = if group.title.is_empty() {
                group.rows.first().map_or("", |row| row.control.bespoke_id())
            } else {
                group.title
            };
            assert!(
                !seen_titles.iter().any(|&(section, seen, platform)| {
                    section == group.section.id()
                        && seen == name
                        && [true, false]
                            .iter()
                            .any(|&mac| platform.shown_on(mac) && group.platform.shown_on(mac))
                }),
                "{name} appears twice on one half of {}",
                group.section.id(),
            );
            seen_titles.push((group.section.id(), name, group.platform));
            for row in group.rows {
                if row.key.is_empty() {
                    continue;
                }
                assert!(
                    !seen_keys.contains(&row.key),
                    "{} is edited twice on this page — two controls over one value",
                    row.key,
                );
                seen_keys.push(row.key);
            }
        }
    }

    /// The macOS-only groups really are the ones with no iOS backing, and the phone still gets
    /// every group that has one. Stated as a COUNT so removing a gate is a visible edit here.
    #[test]
    fn the_general_page_differs_by_exactly_the_groups_ios_cannot_back() {
        let on_mac: Vec<_> = groups(Section::General, true).iter().map(|g| g.title).collect();
        let on_phone: Vec<_> = groups(Section::General, false).iter().map(|g| g.title).collect();
        assert_eq!(on_mac, [
            "General",
            "Close Confirmation",
            "Privacy & New Panes",
            "Shared Focus",
            "OS Integration"
        ]);
        assert_eq!(on_phone, [
            "General",
            "Close Confirmation",
            "Privacy & New Panes",
            "Shared Focus"
        ]);
    }

    /// Appearance is the page where the platform gate earns its place as data: two groups the phone
    /// omits because iOS has nothing behind them (Window, Dock Icon), and seven both halves draw
    /// from the same rows — including Cursor, whose bespoke preview surface is pure `SwiftUI` and
    /// so belongs to both.
    #[test]
    fn the_appearance_page_diverges_by_group_and_by_row() {
        let titled = |mac: bool| -> Vec<&'static str> {
            groups(Section::Appearance, mac)
                .iter()
                .map(|group| group.title)
                .filter(|title| !title.is_empty())
                .collect()
        };
        assert_eq!(titled(true), [
            "Tabs",
            "Window",
            "Appearance",
            "Font Family",
            "Text",
            "Ligatures",
            "Style & Rendering",
            "Cursor",
            "Dock Icon"
        ]);
        assert_eq!(titled(false), [
            "Tabs",
            "Appearance",
            "Font Family",
            "Text",
            "Ligatures",
            "Style & Rendering",
            "Cursor"
        ]);

        // The caret surface is reachable on BOTH, and by the SAME row — the property the omitted
        // groups above are allowed to break and this one is not. Asserted per half rather than once
        // so a gate re-appearing on either side fails here.
        for mac in [true, false] {
            assert!(
                groups(Section::Appearance, mac)
                    .iter()
                    .flat_map(|group| rows(group, mac))
                    .any(|row| row.control.bespoke_id() == "cursor-preview"),
                "the cursor preview vanished from the {} half",
                if mac { "Mac" } else { "phone" },
            );
        }
    }

    /// Positional lookup agrees with the filtered list it indexes into — the property the boundary
    /// relies on, since it crosses a count and then asks for each position.
    #[test]
    fn a_position_resolves_to_the_group_the_filtered_list_holds() {
        for mac in [true, false] {
            for section in Section::ALL {
                let listed = groups(section, mac);
                for (index, group) in listed.iter().enumerate() {
                    assert_eq!(group_at(section, mac, index).map(|g| g.title), Some(group.title));
                    for (row_index, row) in rows(group, mac).iter().enumerate() {
                        assert_eq!(
                            row_at(section, mac, index, row_index).map(|r| r.key),
                            Some(row.key),
                            "{} row {row_index}",
                            group.title,
                        );
                    }
                }
                assert!(
                    group_at(section, mac, listed.len()).is_none(),
                    "one past the end is not a group"
                );
            }
        }
    }

    /// Each control's accessors agree with the variant they read. This is the shape the boundary
    /// carries — a kind plus at most one numeric and one string payload — and the assertion is that
    /// the flattening loses nothing: a `Menu` always names a group, a `Bespoke` always names an id
    /// and never a glyph, and nothing carries a payload its kind cannot use.
    #[test]
    fn a_control_flattens_without_losing_what_it_carries() {
        for group in GROUPS {
            for row in group.rows {
                let control = row.control;
                match control {
                    Control::Toggle { glyph } => {
                        assert_eq!(control.kind(), 0);
                        assert_eq!(control.glyph(), Some(glyph));
                        assert!(control.argument().is_none() && control.bespoke_id().is_empty());
                    },
                    Control::Menu { group: options, .. } | Control::Cards { group: options } => {
                        assert!(control.kind() == 1 || control.kind() == 2);
                        assert_eq!(control.argument(), Some(options.index()));
                        assert!(control.bespoke_id().is_empty());
                    },
                    Control::Slider { ladder } => {
                        assert_eq!(control.kind(), 3);
                        assert_eq!(control.argument(), Some(ladder.index()));
                        assert!(control.glyph().is_none() && control.bespoke_id().is_empty());
                    },
                    Control::Stepper { range } => {
                        assert_eq!(control.kind(), 4);
                        assert_eq!(control.argument(), Some(range.index()));
                        assert!(control.glyph().is_none() && control.bespoke_id().is_empty());
                    },
                    Control::Text { glyph } => {
                        assert_eq!(control.kind(), 5);
                        assert_eq!(control.glyph(), glyph);
                        assert!(control.argument().is_none() && control.bespoke_id().is_empty());
                    },
                    Control::Note => {
                        assert_eq!(control.kind(), 6);
                        assert!(row.key.is_empty(), "a note edits nothing, so it names no key");
                        assert!(
                            !row.subtitle.is_empty(),
                            "a note with no words is an empty paragraph"
                        );
                        assert!(control.argument().is_none() && control.glyph().is_none());
                        assert!(control.bespoke_id().is_empty());
                    },
                    Control::Bespoke { id } => {
                        assert_eq!(control.kind(), 7);
                        assert_eq!(control.bespoke_id(), id);
                        assert!(!id.is_empty(), "a bespoke group with no id names nothing to draw");
                        assert!(control.argument().is_none() && control.glyph().is_none());
                    },
                }
            }
        }
    }

    /// A platform crosses as its own index, and `shown_on` is the only reading of it.
    #[test]
    fn a_platform_crosses_by_index_and_answers_one_question() {
        assert_eq!(
            [
                Platform::Both.index(),
                Platform::Mac.index(),
                Platform::Phone.index()
            ],
            [0, 1, 2]
        );
        assert!(Platform::Both.shown_on(true) && Platform::Both.shown_on(false));
        assert!(Platform::Mac.shown_on(true) && !Platform::Mac.shown_on(false));
        assert!(!Platform::Phone.shown_on(true) && Platform::Phone.shown_on(false));
    }
}
