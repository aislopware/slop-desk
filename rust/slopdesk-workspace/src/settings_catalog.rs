//! What Settings OFFERS: the sections, the choices in each group, and the scalar ladders.
//!
//! A settings page is two things stacked. One is a control — a card grid, a menu row, a slider —
//! which is a view and belongs to whichever framework is drawing. The other is the ANSWER to "what
//! can this be set to, what is each choice called, and what does the number read as", which is the
//! same on a phone as on a Mac and is not a view at all. This is the second thing.
//!
//! ## Why it left Swift
//!
//! It was already lifted once, out of view bodies into a Swift catalog, for the reason stated
//! there: a `Picker`'s choices written as inline `Text("…").tag(…)` children are unreachable to a
//! test and drift from the enum they tag. That argument does not stop at the view boundary. The
//! catalog is a table of strings and numbers with no framework in it, which by the repo's own rule
//! means nothing keeps it in Swift — and the two halves of the UI split are about to read it from
//! two different frameworks, which is exactly the shape where one table beats two.
//!
//! ## What did NOT cross, and why
//!
//! The EXHAUSTIVENESS pin. Every list here must cover every case of the Swift enum it tags, because
//! a dropped option is invisible in a card grid — there is no "…" to hint at what is missing. That
//! assertion needs the Swift enum's `allCases`, so it stays a Swift test reading these tokens. What
//! crosses is the token, not the enum: each option names the value the store PERSISTS, and the
//! Swift side rebuilds its own enum from it with the `RawRepresentable` init it already has. A
//! catalog that carried case indices instead would break silently the first time a case was
//! inserted.
//!
//! ## A token is ON DISK, so it is not spelled — it is quoted
//!
//! These tokens are not names this module chose. Each one is already written into a user's config
//! and into `UserDefaults`, so it is whatever it has been since it was first persisted: mostly
//! hyphen-cased (`after-current`, `copy-or-paste`, `restore-last-session`), except `multiple_tabs`
//! and `block_hollow`, which are not, because they were not. Renaming one to look like its
//! neighbours would silently reset that setting on every machine that had it set.
//!
//! Two of the enums behind these — [`crate::session::NewTabPosition`] is not among them — repair
//! rather than fail: their Swift `init(rawValue:)` is NON-FAILABLE and falls back to a default. So
//! a token misspelled here does not vanish, which would at least be visible as a missing card; it
//! becomes a SECOND card writing the default, indistinguishable on screen from the real one. That
//! is why `SettingsOptionCatalogTests` asserts a group has no duplicate values as well as no
//! missing ones — the duplicate is the only trace a misspelling leaves.
//!
//! ## Captions are the honesty channel
//!
//! Where a choice is deferred, aliased or caveated, the caveat rides the option's caption rather
//! than a paragraph elsewhere on the page — `auto` new-tab position IS `end` today, so its card
//! says so. A card hangs the caption under the label; a menu folds it in after an en dash, which is
//! [`OptionRow::menu_label`].

/// One choice in a settings group, as data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OptionRow {
    /// The value the store persists — the Swift enum's `rawValue`, which is what lets the near side
    /// rebuild its own type without this table knowing what that type is.
    pub token: &'static str,
    /// What the choice is called.
    pub label: &'static str,
    /// A short qualifier on the label, where a choice needs to be honest about a caveat. Empty for
    /// the common case.
    pub caption: &'static str,
}

impl OptionRow {
    /// One row, with no caveat.
    const fn plain(token: &'static str, label: &'static str) -> Self {
        Self {
            token,
            label,
            caption: "",
        }
    }

    /// One row that has to be honest about something.
    const fn noted(token: &'static str, label: &'static str, caption: &'static str) -> Self {
        Self {
            token,
            label,
            caption,
        }
    }

    /// The one-line form a menu shows: the label, with the caveat folded in after an en dash. A
    /// menu item has no second line to hang a caption on, and dropping the caption would drop
    /// the honesty it carries.
    #[must_use]
    pub fn menu_label(&self) -> String {
        if self.caption.is_empty() {
            return self.label.to_owned();
        }
        format!("{} — {}", self.label, self.caption)
    }
}

/// A group of choices — one control's worth.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    /// Appearance → Cursor → Style.
    CursorStyle,
    /// Appearance → Tabs → New tab position.
    NewTabPosition,
    /// Appearance → Theme → Density.
    Density,
    /// Appearance → Window → Window size. macOS-only at the call site.
    WindowSize,
    /// Appearance → Window → Remote desktop opens. macOS-only at the call site.
    DesktopPresentation,
    /// Controls → Keyboard → Option as Alt.
    OptionAsAlt,
    /// Controls → Mouse → Right-click action.
    RightClickAction,
    /// General → On launch.
    OnLaunch,
    /// General → Close confirmation, the WINDOW row.
    CloseConfirmation,
    /// General → Close confirmation, the TAB row.
    CloseConfirmationTab,
    /// Shell → Notification → Banner behaviour while slopdesk is frontmost.
    NotifyWhileForeground,
    /// Shell → Working Directory, shared by the window / tab / split rows.
    WorkingDirectory,
    /// Controls → Open With → what ⌘-click does on a link.
    LinkCmdClick,
    /// Controls → Open With → what ⌘⇧-click does on a link.
    LinkCmdShiftClick,
    /// Controls → Link Schemes → which schemes are detected at all.
    AutoDetectLinkSchemes,
    /// Appearance → Tabs → when the tabs panel hides itself.
    AutoHideTabsPanel,
    /// Appearance → Cursor → Blink.
    CursorBlink,
    /// Advanced → Privileges → what OSC 52 may do, per direction.
    ClipboardAccess,
}

impl Group {
    /// Every group, in case-index order — the numbering the boundary carries.
    pub const ALL: [Self; 18] = [
        Self::CursorStyle,
        Self::NewTabPosition,
        Self::Density,
        Self::WindowSize,
        Self::DesktopPresentation,
        Self::OptionAsAlt,
        Self::RightClickAction,
        Self::OnLaunch,
        Self::CloseConfirmation,
        Self::CloseConfirmationTab,
        Self::NotifyWhileForeground,
        Self::WorkingDirectory,
        Self::LinkCmdClick,
        Self::LinkCmdShiftClick,
        Self::AutoDetectLinkSchemes,
        Self::AutoHideTabsPanel,
        Self::CursorBlink,
        Self::ClipboardAccess,
    ];

    /// The case index a group crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::CursorStyle => 0,
            Self::NewTabPosition => 1,
            Self::Density => 2,
            Self::WindowSize => 3,
            Self::DesktopPresentation => 4,
            Self::OptionAsAlt => 5,
            Self::RightClickAction => 6,
            Self::OnLaunch => 7,
            Self::CloseConfirmation => 8,
            Self::CloseConfirmationTab => 9,
            Self::NotifyWhileForeground => 10,
            Self::WorkingDirectory => 11,
            Self::LinkCmdClick => 12,
            Self::LinkCmdShiftClick => 13,
            Self::AutoDetectLinkSchemes => 14,
            Self::AutoHideTabsPanel => 15,
            Self::CursorBlink => 16,
            Self::ClipboardAccess => 17,
        }
    }

    /// The group a case index names, or `None` for an index no case has.
    #[must_use]
    pub fn from_index(index: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|group| group.index() == index)
    }
}

/// The persisted token for the comfortable theme density.
pub const DENSITY_COMFORTABLE: &str = "comfortable";
/// The persisted token for the compact one.
pub const DENSITY_COMPACT: &str = "compact";

/// Appearance → Cursor → Style. Four styles told apart by silhouette rather than by their names.
const CURSOR_STYLES: &[OptionRow] = &[
    OptionRow::plain("block", "Block"),
    OptionRow::plain("block_hollow", "Hollow"),
    OptionRow::plain("bar", "Bar"),
    OptionRow::plain("underline", "Underline"),
];

/// Appearance → Tabs → New tab position. `auto` carries the alias caption because it resolves to
/// the same append as `end` today.
const NEW_TAB_POSITIONS: &[OptionRow] = &[
    OptionRow::noted("auto", "Automatic", "Appends, like End"),
    OptionRow::plain("end", "End"),
    OptionRow::plain("after-current", "After current"),
];

/// Appearance → Theme → Density. More rows, tighter, is what compact BUYS.
const DENSITIES: &[OptionRow] = &[
    OptionRow::plain(DENSITY_COMFORTABLE, "Comfortable"),
    OptionRow::plain(DENSITY_COMPACT, "Compact"),
];

/// Appearance → Window → Window size.
const WINDOW_SIZES: &[OptionRow] = &[
    OptionRow::noted("remember", "Remember", "Last size"),
    OptionRow::noted("grid", "Grid", "Cols × rows"),
    OptionRow::noted("frame", "Frame", "Pixels"),
];

/// Appearance → Window → Remote desktop opens.
const DESKTOP_PRESENTATIONS: &[OptionRow] = &[
    OptionRow::plain("window", "Window"),
    OptionRow::noted("fullscreen", "Fullscreen", "Captures ⌘Tab"),
    OptionRow::noted("borderless", "Borderless", "Covers the Space"),
];

/// Controls → Keyboard → Option as Alt. Four prose labels that read almost identically become four
/// distinct key-row silhouettes when they are drawn.
const OPTION_AS_ALT: &[OptionRow] = &[
    OptionRow::noted("off", "Off", "Accents"),
    OptionRow::plain("both", "Both"),
    OptionRow::plain("left", "Left only"),
    OptionRow::plain("right", "Right only"),
];

/// Controls → Mouse → Right-click action. Five actions with no shared geometry to diagram, told
/// apart by their verb. `Ctrl`+right-click always opens the menu regardless, which is the row's
/// subtitle rather than anything per option.
const RIGHT_CLICK_ACTIONS: &[OptionRow] = &[
    OptionRow::plain("context-menu", "Context menu"),
    OptionRow::plain("copy", "Copy"),
    OptionRow::plain("paste", "Paste"),
    OptionRow::plain("copy-or-paste", "Copy or paste"),
    OptionRow::plain("ignore", "Ignore"),
];

/// General → On launch. Two behaviours, distinguished by their sentence.
const ON_LAUNCH: &[OptionRow] = &[
    OptionRow::plain("restore-last-session", "Restore session"),
    OptionRow::plain("new-window", "New window"),
];

/// General → Close confirmation, the WINDOW row. The full policy set: a window is the only unit
/// that can hold more than one tab, so it is the only one `multiple_tabs` can speak about.
const CLOSE_CONFIRMATION: &[OptionRow] = &[
    OptionRow::noted("process", "Running process", "only if busy"),
    OptionRow::plain("always", "Always"),
    OptionRow::plain("multiple_tabs", "Multiple tabs"),
];

/// Shell → Notification → banner behaviour while slopdesk is the foreground app.
///
/// Stays a MENU rather than cards: its longest label is a whole sentence, and a card is a
/// fixed-width tile.
const NOTIFY_WHILE_FOREGROUND: &[OptionRow] = &[
    OptionRow::plain("off", "Off"),
    OptionRow::plain("always", "Always"),
    OptionRow::plain("tab-unfocused", "Only when source tab is unfocused"),
];

/// Shell → Working Directory, for a new window, a new tab and a new split alike.
///
/// TWO choices for a setting that persists MORE: a custom path is a real value of
/// `WorkingDirectoryPolicy`, set from the config file or the all-settings editor, and it reads as
/// `home` here. The picker is deliberately not a third, path-shaped control — the row says which of
/// the two policies is in force and the raw editor is where a path is typed.
const WORKING_DIRECTORY: &[OptionRow] = &[
    OptionRow::plain("inherit", "Same as Current"),
    OptionRow::plain("home", "Home Directory"),
];

/// Controls → Open With → ⌘-click. A file or folder opens ON THE HOST and a URL in the client's
/// browser, which is why the first option is "Open in the best handler" rather than naming an app.
const LINK_CMD_CLICK: &[OptionRow] = &[
    OptionRow::plain("open", "Open"),
    OptionRow::plain("copy", "Copy"),
    OptionRow::plain("nothing", "Do Nothing"),
];

/// Controls → Open With → ⌘⇧-click. Both actions happen on the HOST, where the file is.
const LINK_CMD_SHIFT_CLICK: &[OptionRow] = &[
    OptionRow::plain("reveal-finder", "Reveal in Finder"),
    OptionRow::plain("open-system-default", "Open with System Default"),
];

/// Controls → Link Schemes. `http(s)`, `file` and `mailto` are detected under either choice; this
/// only decides what happens to everything else.
const AUTO_DETECT_LINK_SCHEMES: &[OptionRow] = &[
    OptionRow::plain("all", "All"),
    OptionRow::plain("custom", "Custom"),
];

/// Appearance → Tabs → when the tabs panel hides itself. `default` and `always` both keep the panel
/// up; they differ in whether the layout may take it away, which is why `auto` needs a caption and
/// the other two do not.
const AUTO_HIDE_TABS_PANEL: &[OptionRow] = &[
    OptionRow::plain("default", "Default"),
    OptionRow::plain("always", "Always"),
    OptionRow::noted("auto", "Auto", "Hides at one tab"),
];

/// Appearance → Cursor → Blink. `default` is not "no opinion" but a real third behaviour — the
/// program decides through DEC mode 12 — which is why it is an option rather than an absent one.
const CURSOR_BLINKS: &[OptionRow] = &[
    OptionRow::noted("default", "Default", "DEC mode 12"),
    OptionRow::plain("on", "On"),
    OptionRow::plain("off", "Off"),
];

/// Advanced → Privileges → what a program may do to the clipboard through OSC 52, per direction.
/// `ask` leads because it is the default and the conservative one — an unrecognised persisted value
/// repairs to it rather than trapping.
const CLIPBOARD_ACCESS: &[OptionRow] = &[
    OptionRow::plain("ask", "Ask"),
    OptionRow::plain("allow", "Allow"),
    OptionRow::plain("deny", "Deny"),
];

/// The choices in a group, in the order they render.
///
/// The tab close-confirmation row is the window row MINUS `multiple_tabs`, taken as a PREFIX rather
/// than written out again: closing one tab loses exactly one tab, so "ask when this would lose more
/// than one tab" can never fire there and offering it would be a control that does nothing. Sharing
/// the prefix is what keeps the two rows' wording identical.
#[must_use]
pub const fn group(group: Group) -> &'static [OptionRow] {
    match group {
        Group::CursorStyle => CURSOR_STYLES,
        Group::NewTabPosition => NEW_TAB_POSITIONS,
        Group::Density => DENSITIES,
        Group::WindowSize => WINDOW_SIZES,
        Group::DesktopPresentation => DESKTOP_PRESENTATIONS,
        Group::OptionAsAlt => OPTION_AS_ALT,
        Group::RightClickAction => RIGHT_CLICK_ACTIONS,
        Group::OnLaunch => ON_LAUNCH,
        Group::CloseConfirmation => CLOSE_CONFIRMATION,
        Group::CloseConfirmationTab => CLOSE_CONFIRMATION.split_at(2).0,
        Group::NotifyWhileForeground => NOTIFY_WHILE_FOREGROUND,
        Group::WorkingDirectory => WORKING_DIRECTORY,
        Group::LinkCmdClick => LINK_CMD_CLICK,
        Group::LinkCmdShiftClick => LINK_CMD_SHIFT_CLICK,
        Group::AutoDetectLinkSchemes => AUTO_DETECT_LINK_SCHEMES,
        Group::AutoHideTabsPanel => AUTO_HIDE_TABS_PANEL,
        Group::CursorBlink => CURSOR_BLINKS,
        Group::ClipboardAccess => CLIPBOARD_ACCESS,
    }
}

/// One row of a group, or `None` past its end.
#[must_use]
pub fn option(group_id: Group, index: usize) -> Option<&'static OptionRow> {
    group(group_id).get(index)
}

// ---------------------------------------------------------------------------------------------
// The taxonomy
// ---------------------------------------------------------------------------------------------

/// A settings section — one row in the Mac's navigator, one row in the phone's list.
///
/// Order and glyphs mirror `docs/ui-shell/screenshots/all-settings.png`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Section {
    /// General.
    General,
    /// Shell.
    Shell,
    /// Controls.
    Controls,
    /// Editor — reserved, deferred.
    Editor,
    /// Agents.
    Agents,
    /// Appearance.
    Appearance,
    /// Key Bindings.
    Keybindings,
    /// Advanced.
    Advanced,
}

impl Section {
    /// Every section, in the order both lists render them.
    pub const ALL: [Self; 8] = [
        Self::General,
        Self::Shell,
        Self::Controls,
        Self::Editor,
        Self::Agents,
        Self::Appearance,
        Self::Keybindings,
        Self::Advanced,
    ];

    /// The persisted / routed identifier.
    #[must_use]
    pub const fn id(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Shell => "shell",
            Self::Controls => "controls",
            Self::Editor => "editor",
            Self::Agents => "agents",
            Self::Appearance => "appearance",
            Self::Keybindings => "keybindings",
            Self::Advanced => "advanced",
        }
    }

    /// The row label.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::General => "General",
            Self::Shell => "Shell",
            Self::Controls => "Controls",
            Self::Editor => "Editor",
            Self::Agents => "Agents",
            Self::Appearance => "Appearance",
            Self::Keybindings => "Key Bindings",
            Self::Advanced => "Advanced",
        }
    }

    /// The row glyph, as an SF Symbol name. Controls is the pointer glyph, which is what sits
    /// beside "Controls" in the screenshot — its settings are input, scroll and pointer.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::General => "exclamationmark.circle",
            Self::Shell => "terminal",
            Self::Controls => "cursorarrow",
            Self::Editor => "doc.text",
            Self::Agents => "powerplug",
            Self::Appearance => "paintpalette",
            Self::Keybindings => "bolt",
            Self::Advanced => "wrench",
        }
    }

    /// Whether the compact list drops this section entirely.
    ///
    /// Only Key Bindings qualifies, and for a reason about capture rather than about screen size:
    /// recording a chord is an `NSEvent` monitor with no touch equivalent, so the page would offer
    /// a field nothing can fill. Advanced's macOS-HOST-only ROWS are gated inside that section
    /// instead, so the section itself still reaches the phone.
    #[must_use]
    pub const fn is_mac_only(self) -> bool {
        matches!(self, Self::Keybindings)
    }

    /// The section a case index names.
    #[must_use]
    pub fn from_index(index: usize) -> Option<Self> {
        Self::ALL.get(index).copied()
    }
}

/// When a setting takes effect — a DATA attribute so the distinction can be a chip rather than
/// prose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyTiming {
    /// Applies immediately — a terminal reload, a theme, a republished keybinding, a fire-time key.
    Live,
    /// A HOST-read flag shipped over the sidecar, which applies on the next host connection.
    Reconnect,
}

impl ApplyTiming {
    /// The chip's text.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Live => "Applies now",
            Self::Reconnect => "Applies on reconnect",
        }
    }

    /// The chip's glyph.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::Live => "bolt.fill",
            Self::Reconnect => "arrow.triangle.2.circlepath",
        }
    }

    /// The case index a timing crosses as — the inverse of [`ApplyTiming::from_index`].
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Live => 0,
            Self::Reconnect => 1,
        }
    }

    /// The timing a case index names.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Live),
            1 => Some(Self::Reconnect),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The scalar ladders
// ---------------------------------------------------------------------------------------------

/// A slider with magnitude stops on it.
///
/// The stops are the point. A `Stepper` over scrollback depth took ninety-nine clicks to cross its
/// own range, so the top of the range was unreachable in practice; stops are the values a user
/// actually picks — a shallow buffer, the default, the deep ones — rather than an even subdivision.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LadderBounds {
    /// The lowest settable value.
    pub min: f64,
    /// The highest.
    pub max: f64,
    /// The slider's granularity.
    pub step: f64,
}

/// One magnitude stop.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LadderPreset {
    /// What the stop is called.
    pub label: &'static str,
    /// What it sets.
    pub value: f64,
}

/// Which ladder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ladder {
    /// Controls → Scroll → Scrollback depth, in lines.
    Scrollback,
    /// Controls → Scroll → Scroll multiplier.
    ScrollMultiplier,
    /// Shell → Tab Badge → Busy reveal delay, in seconds.
    BusyDelay,
}

impl Ladder {
    /// Every ladder, in case-index order.
    pub const ALL: [Self; 3] = [Self::Scrollback, Self::ScrollMultiplier, Self::BusyDelay];

    /// The case index a ladder crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Scrollback => 0,
            Self::ScrollMultiplier => 1,
            Self::BusyDelay => 2,
        }
    }

    /// The ladder a case index names.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Scrollback),
            1 => Some(Self::ScrollMultiplier),
            2 => Some(Self::BusyDelay),
            _ => None,
        }
    }

    /// This ladder's range and granularity.
    #[must_use]
    pub const fn bounds(self) -> LadderBounds {
        match self {
            Self::Scrollback => {
                LadderBounds {
                    min: 1000.0,
                    max: 100_000.0,
                    step: 1000.0,
                }
            },
            Self::ScrollMultiplier => {
                LadderBounds {
                    min: 0.25,
                    max: 5.0,
                    step: 0.25,
                }
            },
            Self::BusyDelay => {
                LadderBounds {
                    min: 0.0,
                    max: 10.0,
                    step: 0.5,
                }
            },
        }
    }

    /// This ladder's magnitude stops, in order.
    #[must_use]
    pub const fn presets(self) -> &'static [LadderPreset] {
        match self {
            Self::Scrollback => SCROLLBACK_PRESETS,
            Self::ScrollMultiplier => SCROLL_MULTIPLIER_PRESETS,
            Self::BusyDelay => BUSY_DELAY_PRESETS,
        }
    }

    /// What the slider's current value reads as.
    ///
    /// Each ladder's readout is about its own unit, not about a shared number format. Scrollback is
    /// grouped because five digits are illegible ungrouped; the multiplier carries two decimals
    /// because that is the slider's own granularity; the delay says `Instant` at zero because the
    /// BEHAVIOUR is what changes there — `0.0s` reads as a delay that happens to be short.
    #[must_use]
    pub fn readout(self, value: f64) -> String {
        match self {
            Self::Scrollback => format!("{} lines", grouped(round_to_i64(value))),
            Self::ScrollMultiplier => format!("{value:.2}×"),
            Self::BusyDelay if value == 0.0 => "Instant".to_owned(),
            Self::BusyDelay => format!("{value:.1}s"),
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The stepper ranges
// ---------------------------------------------------------------------------------------------

/// A plus/minus numeric field's range.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StepperBounds {
    /// The lowest settable value.
    pub min: i64,
    /// The highest.
    pub max: i64,
    /// How far one click moves it.
    pub step: i64,
}

/// Which numeric field.
///
/// The counterpart to [`Ladder`], and the rule for picking between them is whether the useful
/// values are a HANDFUL. Scrollback depth has four magnitudes anyone actually wants, so it is a
/// ladder with stops; a window's column count is a literal the reader already knows the meaning of
/// ("80 columns"), and every number in the range is as reasonable as its neighbour.
///
/// A range is named for the UNIT it counts, not for the setting, because the four window fields are
/// two pairs sharing two ranges. What tells Columns from Rows is the row's label, which lives in
/// [`settings_rows`](crate::settings_rows) with every other label.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stepper {
    /// Appearance → Window → the grid mode's columns and rows, in terminal cells.
    WindowCells,
    /// Appearance → Window → the frame mode's width and height, in pixels.
    WindowPixels,
}

impl Stepper {
    /// Every range, in case-index order.
    pub const ALL: [Self; 2] = [Self::WindowCells, Self::WindowPixels];

    /// The case index a range crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::WindowCells => 0,
            Self::WindowPixels => 1,
        }
    }

    /// The range a case index names.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::WindowCells),
            1 => Some(Self::WindowPixels),
            _ => None,
        }
    }

    /// This range's ends and granularity.
    ///
    /// The pixel step is fifty because one pixel at a time across sixteen thousand is a control
    /// that cannot reach its own far end — the same reasoning that turned scrollback into a
    /// ladder.
    #[must_use]
    pub const fn bounds(self) -> StepperBounds {
        match self {
            Self::WindowCells => {
                StepperBounds {
                    min: 1,
                    max: 1000,
                    step: 1,
                }
            },
            Self::WindowPixels => {
                StepperBounds {
                    min: 64,
                    max: 16384,
                    step: 50,
                }
            },
        }
    }

    /// What the value reads as after the row's label — `80` for cells, `1000 px` for pixels.
    #[must_use]
    pub fn readout(self, value: i64) -> String {
        match self {
            Self::WindowCells => value.to_string(),
            Self::WindowPixels => format!("{value} px"),
        }
    }
}

/// Scrollback stops: a shallow buffer, the default, and the deep ones.
const SCROLLBACK_PRESETS: &[LadderPreset] = &[
    LadderPreset {
        label: "1k",
        value: 1000.0,
    },
    LadderPreset {
        label: "10k",
        value: 10000.0,
    },
    LadderPreset {
        label: "25k",
        value: 25000.0,
    },
    LadderPreset {
        label: "50k",
        value: 50000.0,
    },
    LadderPreset {
        label: "100k",
        value: 100_000.0,
    },
];

/// Multiplier stops: half speed, the identity, double, triple — so "back to normal" is one tap
/// rather than a drag hunt.
const SCROLL_MULTIPLIER_PRESETS: &[LadderPreset] = &[
    LadderPreset {
        label: "0.5×",
        value: 0.5,
    },
    LadderPreset {
        label: "1×",
        value: 1.0,
    },
    LadderPreset {
        label: "2×",
        value: 2.0,
    },
    LadderPreset {
        label: "3×",
        value: 3.0,
    },
];

/// Delay stops: the three real intentions — immediate, a beat, or only for genuinely slow work.
const BUSY_DELAY_PRESETS: &[LadderPreset] = &[
    LadderPreset {
        label: "Instant",
        value: 0.0,
    },
    LadderPreset {
        label: "1s",
        value: 1.0,
    },
    LadderPreset {
        label: "3s",
        value: 3.0,
    },
    LadderPreset {
        label: "5s",
        value: 5.0,
    },
];

/// The widest magnitude a readout will print. Exactly representable in `f64` and far inside `i64`,
/// so the narrowing below is total — and twelve orders of magnitude above the deepest scrollback
/// any slider here offers, so it bounds only a value no slider produced.
const READOUT_CEILING: f64 = 1e15;

/// A slider value as a whole number. A degenerate value reads as zero rather than trapping: a
/// readout is a label, and a label that panics is worse than a label that says `0`.
fn round_to_i64(value: f64) -> i64 {
    if !value.is_finite() {
        return 0;
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the clamp is well inside i64, so the narrowing is total"
    )]
    let narrowed = value.round().clamp(-READOUT_CEILING, READOUT_CEILING) as i64;
    narrowed
}

/// Group an integer in thousands with a NARROW NO-BREAK SPACE (U+202F).
///
/// Not a locale comma: the value sits in a monospaced-digit readout, where a comma reads as a
/// decimal point in half the world. A negative value keeps its sign outside the grouping, which no
/// ladder here produces but which a shared helper should not get wrong.
#[must_use]
pub fn grouped(value: i64) -> String {
    let negative = value.is_negative();
    let digits = value.unsigned_abs().to_string();
    // One separator per group of three, plus the sign — an upper bound, not an exact count.
    let mut out = String::with_capacity(digits.len() * 2 + 1);
    if negative {
        out.push('-');
    }
    for (offset, character) in digits.chars().enumerate() {
        if offset > 0 && (digits.len() - offset).is_multiple_of(3) {
            out.push('\u{202F}');
        }
        out.push(character);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tab_row_is_the_window_row_without_the_tab_count_policy() {
        let window = group(Group::CloseConfirmation);
        let tab = group(Group::CloseConfirmationTab);
        assert_eq!(window.len(), 3);
        assert_eq!(tab.len(), 2);
        assert_eq!(
            window.get(..2),
            Some(tab),
            "the wording must be shared, not copied"
        );
        assert!(
            !tab.iter().any(|row| row.token == "multiple_tabs"),
            "closing one tab can never lose more than one",
        );
    }

    #[test]
    fn every_group_is_non_empty_and_its_tokens_are_unique() {
        for id in Group::ALL {
            let rows = group(id);
            assert!(!rows.is_empty(), "{id:?} is empty");
            for (offset, row) in rows.iter().enumerate() {
                assert!(!row.token.is_empty(), "{id:?}[{offset}] has no token");
                assert!(!row.label.is_empty(), "{id:?}[{offset}] has no label");
                assert!(
                    rows.iter().filter(|other| other.token == row.token).count() == 1,
                    "{id:?} repeats the token {}",
                    row.token,
                );
            }
            assert_eq!(Group::from_index(id.index()), Some(id));
        }
        assert_eq!(
            Group::from_index(Group::ALL.len().try_into().unwrap_or(u8::MAX)),
            None
        );
    }

    #[test]
    fn a_caveat_folds_into_a_menu_label_and_a_plain_row_does_not() {
        let auto = option(Group::NewTabPosition, 0).copied();
        assert_eq!(
            auto.map(|row| row.menu_label()),
            Some("Automatic — Appends, like End".to_owned())
        );
        let end = option(Group::NewTabPosition, 1).copied();
        assert_eq!(end.map(|row| row.menu_label()), Some("End".to_owned()));
        assert_eq!(option(Group::NewTabPosition, 99), None);
    }

    #[test]
    fn the_taxonomy_is_eight_sections_in_one_order() {
        let ids: Vec<&str> = Section::ALL.iter().map(|section| section.id()).collect();
        assert_eq!(ids, vec![
            "general",
            "shell",
            "controls",
            "editor",
            "agents",
            "appearance",
            "keybindings",
            "advanced",
        ]);
        for (index, section) in Section::ALL.iter().enumerate() {
            assert_eq!(Section::from_index(index), Some(*section));
            assert!(!section.title().is_empty());
            assert!(!section.symbol().is_empty());
        }
        assert_eq!(Section::from_index(Section::ALL.len()), None);
    }

    /// Only Key Bindings is dropped from the compact list, and for a reason about CAPTURE rather
    /// than about screen size. A second mac-only section would be a feature the phone silently
    /// lacks.
    #[test]
    fn key_bindings_is_the_only_section_the_phone_drops() {
        let dropped: Vec<&str> = Section::ALL
            .iter()
            .filter(|section| section.is_mac_only())
            .map(|section| section.id())
            .collect();
        assert_eq!(dropped, vec!["keybindings"]);
    }

    #[test]
    fn the_timing_chip_says_which_way_it_applies() {
        assert_eq!(ApplyTiming::Live.label(), "Applies now");
        assert_eq!(ApplyTiming::Reconnect.label(), "Applies on reconnect");
        assert_eq!(ApplyTiming::from_index(0), Some(ApplyTiming::Live));
        assert_eq!(ApplyTiming::from_index(1), Some(ApplyTiming::Reconnect));
        assert_eq!(ApplyTiming::from_index(2), None);
    }

    #[test]
    fn every_preset_sits_inside_its_own_range() {
        for ladder in Ladder::ALL {
            let bounds = ladder.bounds();
            assert!(bounds.min < bounds.max, "{ladder:?} has an empty range");
            assert!(bounds.step > 0.0, "{ladder:?} has no granularity");
            let presets = ladder.presets();
            assert!(!presets.is_empty(), "{ladder:?} has no stops");
            for preset in presets {
                assert!(
                    preset.value >= bounds.min && preset.value <= bounds.max,
                    "{ladder:?} stop {} is outside its range",
                    preset.label,
                );
                assert!(!preset.label.is_empty());
            }
            assert_eq!(Ladder::from_index(ladder.index()), Some(ladder));
        }
        assert_eq!(Ladder::from_index(3), None);
    }

    #[test]
    fn a_five_digit_depth_is_grouped_with_a_narrow_space() {
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(999), "999");
        assert_eq!(grouped(1000), "1\u{202F}000");
        assert_eq!(grouped(50000), "50\u{202F}000");
        assert_eq!(grouped(100_000), "100\u{202F}000");
        assert_eq!(grouped(-1500), "-1\u{202F}500");
        assert_eq!(Ladder::Scrollback.readout(50000.0), "50\u{202F}000 lines");
    }

    #[test]
    fn each_readout_is_about_its_own_unit() {
        assert_eq!(Ladder::ScrollMultiplier.readout(1.0), "1.00×");
        assert_eq!(Ladder::ScrollMultiplier.readout(1.25), "1.25×");
        // Zero is the BEHAVIOUR changing, not a short delay.
        assert_eq!(Ladder::BusyDelay.readout(0.0), "Instant");
        assert_eq!(Ladder::BusyDelay.readout(0.5), "0.5s");
        assert_eq!(Ladder::BusyDelay.readout(3.0), "3.0s");
    }

    /// A slider that somehow reports a degenerate value must still print something.
    #[test]
    fn a_degenerate_value_reads_as_zero_rather_than_trapping() {
        assert_eq!(Ladder::Scrollback.readout(f64::NAN), "0 lines");
        assert_eq!(Ladder::Scrollback.readout(f64::INFINITY), "0 lines");
    }
}
