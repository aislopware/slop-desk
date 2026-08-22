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
    /// Appearance → Font → Text → Line height.
    LineHeight,
    /// Appearance → Font → Ligatures.
    FontLigatures,
    /// Appearance → Font → Style & Rendering, shared by the Bold and Italic rows.
    FontStyleMode,
    /// Appearance → Font → Style & Rendering → Blending.
    FontBlending,
    /// Advanced → Video · Pacer → how a decoded frame is scheduled for presentation.
    VideoPacer,
}

impl Group {
    /// Every group, in case-index order — the numbering the boundary carries.
    const ALL: [Self; 23] = [
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
        Self::LineHeight,
        Self::FontLigatures,
        Self::FontStyleMode,
        Self::FontBlending,
        Self::VideoPacer,
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
            Self::LineHeight => 18,
            Self::FontLigatures => 19,
            Self::FontStyleMode => 20,
            Self::FontBlending => 21,
            Self::VideoPacer => 22,
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

/// Appearance → Font → Text → Line height. The multipliers ride the labels because a reader picking
/// between "Compact" and "Loose" is picking a NUMBER; `custom` opens the slider that names its own.
const LINE_HEIGHTS: &[OptionRow] = &[
    OptionRow::plain("default", "Default"),
    OptionRow::plain("compact", "Compact (1.0×)"),
    OptionRow::plain("loose", "Loose (1.2×)"),
    OptionRow::plain("custom", "Custom"),
];

/// Appearance → Font → Ligatures. `off` is not the absence of a setting — a font that ships `calt`
/// enables it itself, so turning ligatures off means emitting the DISABLING features.
const FONT_LIGATURES: &[OptionRow] = &[
    OptionRow::plain("off", "Off"),
    OptionRow::noted("calt", "Standard", "calt"),
    OptionRow::noted("dlig", "Discretionary", "dlig"),
];

/// Appearance → Font → Style & Rendering → Bold and Italic, which offer the same four modes.
const FONT_STYLE_MODES: &[OptionRow] = &[
    OptionRow::plain("auto", "Auto"),
    OptionRow::plain("off", "Off"),
    OptionRow::noted("primary-only", "Primary Only", "never borrows a face"),
    OptionRow::noted("synthetic", "Synthetic", "thickened or slanted"),
];

/// Appearance → Font → Style & Rendering → Blending.
const FONT_BLENDINGS: &[OptionRow] = &[
    OptionRow::plain("default", "Default"),
    OptionRow::noted("macos-like", "macOS-like", "thickens the stroke"),
];

/// Advanced → Video · Pacer. Two ways to schedule a decoded frame: hold it to a smoothness-tuned
/// deadline, or show it the moment it lands.
///
/// The tokens are `VideoPreferences.Pacer`'s raw values, which are already in `video-prefs.json`.
/// The model holds the field as an OPTIONAL and unset means present-on-arrival, so there is no
/// third "Default" choice here — a menu that offered one would have two items doing the same thing
/// and no way for a reader to tell which one was in force.
const VIDEO_PACERS: &[OptionRow] = &[
    OptionRow::noted("arrival", "On arrival", "Lowest latency"),
    OptionRow::noted("deadline", "Deadline", "Smoothest"),
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
        Group::LineHeight => LINE_HEIGHTS,
        Group::FontLigatures => FONT_LIGATURES,
        Group::FontStyleMode => FONT_STYLE_MODES,
        Group::FontBlending => FONT_BLENDINGS,
        Group::VideoPacer => VIDEO_PACERS,
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

    /// The section a case index names.
    #[must_use]
    pub fn from_index(index: usize) -> Option<Self> {
        Self::ALL.get(index).copied()
    }

    /// Which sections a settings search field shows for `needle` — indices into [`Self::ALL`],
    /// ascending, so the answer is already in the order both lists render. An empty or
    /// whitespace-only needle is the zero state and shows everything.
    ///
    /// The taxonomy crossed the boundary long before this did, which is the whole reason it is
    /// here: the near side held the sections but wrote its own containment rule over them, so
    /// the list and the search over the list lived in different languages. Matching is ASCII
    /// case-insensitive over [`Self::title`], which is sound BECAUSE every title in `ALL` is
    /// ASCII — see the test that pins that, since the moment one is not, this rule and a
    /// locale-folding one stop agreeing.
    #[must_use]
    pub fn matching(needle: &str) -> Vec<u32> {
        let needle = needle.trim();
        Self::ALL
            .iter()
            .zip(0_u32..)
            .filter(|(section, _)| contains_ascii_case_insensitive(section.title(), needle))
            .map(|(_, index)| index)
            .collect()
    }
}

/// Whether `haystack` holds `needle`, folding ASCII case and nothing else. An empty needle is held
/// by everything, which is what makes a search field's zero state its whole list.
///
/// Deliberately NOT a Unicode fold, and the difference is not the one usually named. The near
/// side's `localizedCaseInsensitiveContains` is NOT diacritic-insensitive — probed 2026-08-22,
/// `Café` does not hold `cafe`, and only `localizedStandardContains` folds that far. What it does
/// do is normalise and case-FOLD: `ﬁle` holds `file`, `straße` holds `strasse`, and NFC agrees with
/// NFD. This rule does none of those. The two therefore agree on ASCII and only on ASCII. Every
/// caller here searches ASCII labels, so the cheaper rule is the same rule, and saying so out loud
/// is what keeps someone from pointing this at user text where the difference would be a bug.
fn contains_ascii_case_insensitive(haystack: &str, needle: &str) -> bool {
    let (hay, want) = (haystack.as_bytes(), needle.as_bytes());
    if want.is_empty() {
        return true;
    }
    want.len() <= hay.len()
        && hay
            .windows(want.len())
            .any(|slice| slice.eq_ignore_ascii_case(want))
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
    /// Advanced → Video · Client render → unsharp-mask strength on the luma channel.
    VideoSharpen,
}

impl Ladder {
    /// Every ladder, in case-index order — for the tests that must cover all of them.
    ///
    /// `cfg(test)` because [`index`](Self::index) and [`from_index`](Self::from_index) are
    /// hand-written matches that never read this table; only the round-trip test does.
    #[cfg(test)]
    pub(crate) const ALL: [Self; 4] = [
        Self::Scrollback,
        Self::ScrollMultiplier,
        Self::BusyDelay,
        Self::VideoSharpen,
    ];

    /// The case index a ladder crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Scrollback => 0,
            Self::ScrollMultiplier => 1,
            Self::BusyDelay => 2,
            Self::VideoSharpen => 3,
        }
    }

    /// The ladder a case index names.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Scrollback),
            1 => Some(Self::ScrollMultiplier),
            2 => Some(Self::BusyDelay),
            3 => Some(Self::VideoSharpen),
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
            // The renderer clamps above 4 and treats anything at or below 0 as off, so the settable
            // band stops well inside both ends: past ~2 an unsharp pass rings rather than crisps.
            Self::VideoSharpen => {
                LadderBounds {
                    min: 0.0,
                    max: 2.0,
                    step: 0.1,
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
            Self::VideoSharpen => VIDEO_SHARPEN_PRESETS,
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
            Self::VideoSharpen if value == 0.0 => "Off".to_owned(),
            Self::VideoSharpen => format!("{value:.1}×"),
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
    /// Appearance → Font → Text → the terminal font size, in points.
    FontPoints,
    /// Advanced → Video · Quality → an H.264 quantiser, shared by the sharp and coarse ends.
    VideoQp,
    /// Advanced → Video · FEC → Reed–Solomon parity shards per group.
    VideoFecParity,
    /// Advanced → Video · FEC → how many data shards a parity group covers.
    VideoFecGroup,
}

impl Stepper {
    /// Every range, in case-index order — for the tests that must cover all of them.
    ///
    /// `cfg(test)` for [`Ladder::ALL`]'s reason: [`index`](Self::index) and
    /// [`from_index`](Self::from_index) are hand-written matches that never read this table, and a
    /// door for a count nothing outside a test would call is a door with no caller. What the table
    /// buys is that the round trip below is not a list of cases someone has to remember to extend —
    /// a seventh range that nobody gives an index fails here rather than in a settings pane, where
    /// it would read as a stepper stuck at zero with no range at all.
    #[cfg(test)]
    pub(crate) const ALL: [Self; 6] = [
        Self::WindowCells,
        Self::WindowPixels,
        Self::FontPoints,
        Self::VideoQp,
        Self::VideoFecParity,
        Self::VideoFecGroup,
    ];

    /// The case index a range crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::WindowCells => 0,
            Self::WindowPixels => 1,
            Self::FontPoints => 2,
            Self::VideoQp => 3,
            Self::VideoFecParity => 4,
            Self::VideoFecGroup => 5,
        }
    }

    /// The range a case index names.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::WindowCells),
            1 => Some(Self::WindowPixels),
            2 => Some(Self::FontPoints),
            3 => Some(Self::VideoQp),
            4 => Some(Self::VideoFecParity),
            5 => Some(Self::VideoFecGroup),
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
            // The ends are `PreferencesStore.fontSizeRange`, which is what ⌘± already clamps to, so
            // the field and the shortcut cannot disagree about how small a terminal may get.
            Self::FontPoints => {
                StepperBounds {
                    min: 8,
                    max: 32,
                    step: 1,
                }
            },
            // H.264's whole quantiser range. Both ends are offered because which one is useful
            // depends on the link, and a band narrowed to "sensible" here would be a second opinion
            // fighting the encoder's own.
            Self::VideoQp => {
                StepperBounds {
                    min: 1,
                    max: 51,
                    step: 1,
                }
            },
            // One parity shard is "detect only"; two is where Reed–Solomon starts repairing, and
            // past eight the overhead costs more bandwidth than the loss it covers.
            Self::VideoFecParity => {
                StepperBounds {
                    min: 1,
                    max: 8,
                    step: 1,
                }
            },
            Self::VideoFecGroup => {
                StepperBounds {
                    min: 1,
                    max: 32,
                    step: 1,
                }
            },
        }
    }

    /// What follows the number in the readout — `" px"` for pixels, nothing for a bare count.
    ///
    /// Internal to [`Self::readout`] now. It used to cross on its own, on the argument that not
    /// every stepper's value is an integer — font size is a `Double` a raw edit may set to `13.5` —
    /// so "either side composes the readout from the value it actually has". Both sides then did,
    /// and the near side's composition grew a rule this one did not have (a whole value prints
    /// without its fraction). Handing over a `f64` costs nothing and leaves one composition.
    #[must_use]
    const fn unit(self) -> &'static str {
        match self {
            Self::WindowCells
            | Self::FontPoints
            | Self::VideoQp
            | Self::VideoFecParity
            | Self::VideoFecGroup => "",
            Self::WindowPixels => " px",
        }
    }

    /// What the value reads as after the row's label — `80` for cells, `1000 px` for pixels.
    ///
    /// A WHOLE value prints as a whole number, so `13.0` reads `13`; a fractional one prints as it
    /// is rather than rounding, so a size typed as `13.5` in the flat index does not read back as a
    /// value nothing holds. Without a locale formatter on purpose: this is a number, not a
    /// quantity, and it has to match the token the config bridge parses.
    ///
    /// A degenerate value reads as `0` rather than as `NaN`, for [`round_to_i64`]'s reason — a
    /// readout is a label, and a label that says `nan` is a bug report the user cannot file.
    #[must_use]
    pub fn readout(self, value: f64) -> String {
        let unit = self.unit();
        if !value.is_finite() {
            return format!("0{unit}");
        }
        // Whole is an EXACT question, not a near one: `fract()` is zero for exactly the values that
        // print without a fraction, so a tolerance would round a `13.0001` a raw edit really holds
        // down to a readout nothing holds.
        if value.fract() == 0.0 {
            return format!("{}{unit}", round_to_i64(value));
        }
        format!("{value}{unit}")
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

/// Sharpen stops: off, the two strengths that read well at a 1x stream, and the ceiling.
const VIDEO_SHARPEN_PRESETS: &[LadderPreset] = &[
    LadderPreset {
        label: "Off",
        value: 0.0,
    },
    LadderPreset {
        label: "0.5x",
        value: 0.5,
    },
    LadderPreset {
        label: "1x",
        value: 1.0,
    },
    LadderPreset {
        label: "2x",
        value: 2.0,
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
fn grouped(value: i64) -> String {
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
        // Past the end, derived rather than spelled, so adding a ladder does not need this line
        // rewritten to keep asserting the same thing.
        let past_the_end = u8::try_from(Ladder::ALL.len()).ok();
        assert_eq!(past_the_end.and_then(Ladder::from_index), None);
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
        assert_eq!(Stepper::WindowPixels.readout(f64::NAN), "0 px");
    }

    /// The `Ladder` round trip had a test and the `Stepper` one did not, which is the asymmetry
    /// this covers. The index is what crosses `slopdesk_settings_stepper` and
    /// `slopdesk_settings_stepper_readout`, so a case that gained an index without a `from_index`
    /// arm — or two cases that both claim 3 — would answer a NEIGHBOUR's bounds: a font size field
    /// offering 1…51, silently, with nothing on either side of the boundary able to notice.
    #[test]
    fn every_stepper_survives_the_index_it_crosses_as() {
        for stepper in Stepper::ALL {
            assert_eq!(
                Stepper::from_index(stepper.index()),
                Some(stepper),
                "{stepper:?} does not come back from its own index"
            );
            let bounds = stepper.bounds();
            assert!(bounds.min < bounds.max, "{stepper:?} has an empty range");
            assert!(bounds.step > 0, "{stepper:?} has no granularity");
        }
        // Each index is claimed ONCE. A duplicate passes the round trip above — both cases map to
        // whichever arm `from_index` lists first only if they also map back — so the collision has
        // to be asked about separately.
        let mut indices: Vec<u8> = Stepper::ALL.iter().map(|stepper| stepper.index()).collect();
        indices.sort_unstable();
        indices.dedup();
        assert_eq!(indices.len(), Stepper::ALL.len(), "two ranges share one index");
        // Past the end, derived rather than spelled, so adding a range does not need this line
        // rewritten to keep asserting the same thing. `None` is the documented fallback, and the
        // doors turn it into `found: false` and an empty readout rather than a panic.
        let past_the_end = u8::try_from(Stepper::ALL.len()).ok();
        assert_eq!(past_the_end.and_then(Stepper::from_index), None);
        assert_eq!(Stepper::from_index(u8::MAX), None);
    }

    /// A stepper's readout keeps its unit AND drops a fraction nobody typed. Both halves were
    /// composed on the near side too until 2026-08-20, and the two spellings had already stopped
    /// agreeing: only the Swift one knew that `13.0` must read `13`.
    #[test]
    fn a_stepper_reads_whole_where_it_is_whole_and_fractional_where_it_is_not() {
        assert_eq!(Stepper::WindowCells.readout(80.0), "80");
        assert_eq!(Stepper::WindowPixels.readout(1000.0), "1000 px");
        assert_eq!(Stepper::FontPoints.readout(13.0), "13");
        assert_eq!(Stepper::FontPoints.readout(13.5), "13.5");
    }

    /// The search a settings field runs, in the order the list already renders.
    #[test]
    fn a_section_search_folds_ascii_case_and_keeps_taxonomy_order() {
        let titles = |needle: &str| -> Vec<&'static str> {
            Section::matching(needle)
                .into_iter()
                .filter_map(|index| Section::from_index(index as usize))
                .map(Section::title)
                .collect()
        };
        assert_eq!(titles("key"), ["Key Bindings"]);
        assert_eq!(titles("KEY"), ["Key Bindings"]);
        // Every title but "Controls" carries an `e`, and they come back in taxonomy order.
        assert_eq!(titles("e"), [
            "General",
            "Shell",
            "Editor",
            "Agents",
            "Appearance",
            "Key Bindings",
            "Advanced"
        ]);
        assert_eq!(titles("nothing here"), Vec::<&str>::new());
        // A blank needle is the ZERO STATE, not a miss — the same list, in the same order, which is
        // what lets a search field render one code path whether or not anything is typed.
        assert_eq!(titles("").len(), Section::ALL.len());
        assert_eq!(titles("   ").len(), Section::ALL.len());
    }

    /// The ASCII fold is only equivalent to the near side's while every title is ASCII. This is the
    /// assertion that turns that sentence into something that fails the day it stops being true,
    /// rather than a comment above a rule that quietly started matching the wrong rows.
    #[test]
    fn every_section_title_is_ascii_which_is_what_makes_the_ascii_fold_sound() {
        for section in Section::ALL {
            assert!(
                section.title().is_ascii(),
                "{} is not ASCII — `matching` folds ASCII case only, so it and the near side's normalising \
                 case-fold no longer agree on this title",
                section.title()
            );
        }
        // The cases the two rules actually disagree on, pinned as facts about THIS one. They are NOT
        // the case usually reached for: `localizedCaseInsensitiveContains` does not fold diacritics
        // either (probed 2026-08-22 — `Café` does not hold `cafe`; only `localizedStandardContains`
        // goes that far), so a diacritic proves nothing about the difference. What the near side
        // DOES fold is the ligature, the sharp s and the normal form — and this rule folds none of
        // the three, which is exactly why it may only be pointed at ASCII.
        assert!(
            !contains_ascii_case_insensitive("ﬁle", "file"),
            "no ligature folding"
        );
        assert!(
            !contains_ascii_case_insensitive("straße", "strasse"),
            "no sharp-s expansion"
        );
        assert!(
            !contains_ascii_case_insensitive("Cafe\u{0301}", "Café"),
            "no NFD/NFC normalising"
        );
        // And the half that IS shared: ASCII case, in both directions.
        assert!(contains_ascii_case_insensitive("Key Bindings", "KEY BIND"));
        assert!(contains_ascii_case_insensitive("ADVANCED", "advanced"));
    }
}
