//! The ⌘⇧O picker: its taxonomy, its measurements, its draw order, its chords and its verbs.
//!
//! The picker is the modal surface with the most decision per pixel, because it is six sources, a
//! ranked and sectioned list over them, a per-row verb, and a searchable ⌘K action table under
//! every row — and every one of those is an answer rather than an arrangement.
//!
//! What lives here:
//!
//! * the two vocabularies — which pills exist, what each says, which chord jumps to it, and what
//!   each row KIND is called and drawn with;
//! * the card's measurements and its ⇞/⇟ stride;
//! * the flattening of sections into draw order — the header/row interleave and, with it, the
//!   selectable index the keyboard counts by, which is the one thing a half that paired them itself
//!   would get off by one the moment a section header appeared mid-list;
//! * the honest empty line, the footer's hints and the ↩ verb, which change per source;
//! * the per-row ⌘K ACTION TABLE, and the default action ↩ runs. Those are the largest piece and
//!   the least layout-like of all: which verbs a folder row offers, that Reopen Tab addresses its
//!   own LIFO index rather than popping the newest, that a Current command row gets the re-run pair
//!   instead of the shared jump-to table. Written twice they would diverge on the first new verb.
//!
//! What each half keeps is the arrangement and the event shape: a lazy stack and key presses on the
//! phone, a stack view in a scroll view and a field editor's editing commands on the Mac.

/// The picker's filter pills.
///
/// The ring is All / Opened / Recent / Folders / Agents / Current. SSH and Recipes are NOT pills,
/// and the cut is structural — no case exists for either, so nothing can route to one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Filter {
    /// The merged, section-headered list of every source — the ⌘⇧O default.
    All,
    /// Every currently-open pane.
    Opened,
    /// Recently-closed tabs from this or the previous session.
    Recent,
    /// Frequently-visited folders, frecency-ranked.
    Folders,
    /// Agent sessions for the current project.
    Agents,
    /// The focused pane's detected links plus its command and prompt index.
    Current,
}

impl Filter {
    /// The pill order rendered in the filter bar — Tab and ⇧Tab cycle this ring.
    pub const PILLS: [Self; 6] = [
        Self::All,
        Self::Opened,
        Self::Recent,
        Self::Folders,
        Self::Agents,
        Self::Current,
    ];

    /// The section order the merged list assembles in: every pill EXCEPT [`Filter::All`], in pill
    /// order. `All` itself is never a section — it is the merged view of these.
    pub const SECTIONS: [Self; 5] = [
        Self::Opened,
        Self::Recent,
        Self::Folders,
        Self::Agents,
        Self::Current,
    ];

    /// The pill a code names, or [`None`] for one no pill has.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::All),
            1 => Some(Self::Opened),
            2 => Some(Self::Recent),
            3 => Some(Self::Folders),
            4 => Some(Self::Agents),
            5 => Some(Self::Current),
            _ => None,
        }
    }

    /// This pill's own code, which is also its place in the ring.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::All => 0,
            Self::Opened => 1,
            Self::Recent => 2,
            Self::Folders => 3,
            Self::Agents => 4,
            Self::Current => 5,
        }
    }

    /// The pill's display label, which is also where its section header comes from.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::All => "All",
            Self::Opened => "Opened",
            Self::Recent => "Recent",
            Self::Folders => "Folders",
            Self::Agents => "Agents",
            Self::Current => "Current",
        }
    }

    /// The ALL-CAPS group header this source renders under in the merged list.
    #[must_use]
    pub fn section_header(self) -> String {
        self.label().to_uppercase()
    }

    /// The pill's leading silhouette, as a symbol name.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::All => "square.grid.2x2",
            Self::Opened => "rectangle.stack",
            Self::Recent => "clock.arrow.circlepath",
            Self::Folders => "folder",
            Self::Agents => "sparkles",
            Self::Current => "scope",
        }
    }

    /// The bare character of the picker-LOCAL ⌘-chord that jumps straight to this pill.
    ///
    /// Handled by the panel's own key monitor, NEVER registered globally — see [`command_chord`].
    #[must_use]
    pub const fn chord_key(self) -> char {
        match self {
            Self::All => '0',
            Self::Opened => 'w',
            Self::Recent => 'r',
            Self::Folders => 'z',
            Self::Agents => 'g',
            Self::Current => 'j',
        }
    }

    /// The honest empty-state line this source shows when it has no rows.
    #[must_use]
    pub const fn empty_message(self) -> &'static str {
        match self {
            Self::All => "No results",
            Self::Opened => "No open panes",
            Self::Recent => "No recently closed tabs",
            Self::Folders => "No folders yet",
            Self::Agents => "No agent sessions",
            Self::Current => "Nothing detected in this pane",
        }
    }
}

/// The classification of one picker row — what drives its leading icon and trailing type badge.
///
/// A superset of the sources: panes, folders, agents, recently-closed tabs, and the four
/// jump-derived rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// An open pane.
    Pane,
    /// A frecent folder.
    Folder,
    /// An agent session.
    Agent,
    /// A recently-closed tab.
    RecentTab,
    /// A command from the focused pane's index.
    Command,
    /// A prompt from it.
    Prompt,
    /// A detected path.
    Path,
    /// A detected URL.
    Url,
    /// A detected `file://` URL.
    FileUrl,
}

impl Kind {
    /// Every kind, in code order.
    pub const ALL: [Self; 9] = [
        Self::Pane,
        Self::Folder,
        Self::Agent,
        Self::RecentTab,
        Self::Command,
        Self::Prompt,
        Self::Path,
        Self::Url,
        Self::FileUrl,
    ];

    /// The kind a code names, or [`None`] for one no kind has.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::Pane),
            1 => Some(Self::Folder),
            2 => Some(Self::Agent),
            3 => Some(Self::RecentTab),
            4 => Some(Self::Command),
            5 => Some(Self::Prompt),
            6 => Some(Self::Path),
            7 => Some(Self::Url),
            8 => Some(Self::FileUrl),
            _ => None,
        }
    }

    /// This kind's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Pane => 0,
            Self::Folder => 1,
            Self::Agent => 2,
            Self::RecentTab => 3,
            Self::Command => 4,
            Self::Prompt => 5,
            Self::Path => 6,
            Self::Url => 7,
            Self::FileUrl => 8,
        }
    }

    /// The trailing type badge the row renders flush-right.
    #[must_use]
    pub const fn badge(self) -> &'static str {
        match self {
            Self::Pane => "Pane",
            Self::Folder => "Folder",
            Self::Agent => "Agent",
            Self::RecentTab => "Tab",
            Self::Command => "Cmd",
            Self::Prompt => "Prompt",
            Self::Path => "Path",
            Self::Url => "URL",
            Self::FileUrl => "File",
        }
    }

    /// The leading icon, as a symbol name.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::Pane => "rectangle.split.2x1",
            Self::Folder => "folder",
            Self::Agent => "sparkles",
            Self::RecentTab => "clock.arrow.circlepath",
            Self::Command => "terminal",
            Self::Prompt => "text.bubble",
            Self::Path => "doc.text",
            Self::Url => "link",
            Self::FileUrl => "doc",
        }
    }

    /// The ↩ verb for a row of this kind, for the footer hint.
    ///
    /// It is the ROW's, not the picker's: ↩ on an opened pane switches to it, on a closed tab
    /// reopens it, on a folder changes directory, on an agent resumes a session. A footer that said
    /// "Open" for all four would be wrong three times.
    #[must_use]
    pub const fn default_action_label(kind: Option<Self>) -> &'static str {
        match kind {
            Some(Self::Pane) => "Switch to",
            Some(Self::RecentTab) => "Reopen",
            Some(Self::Folder) => "Change Directory",
            Some(Self::Agent) => "Resume",
            Some(Self::Command | Self::Prompt) => "Jump to",
            Some(Self::Path | Self::Url | Self::FileUrl) | None => "Open",
        }
    }

    /// Which Jump-To kind a reconstructed item takes.
    ///
    /// Cosmetic — the shared jump table keys only on the act and the title — so a kind that never
    /// reaches here reads as a path rather than as a case anyone has to keep in sync. The four
    /// codes are the near side's `JumpToItemKind` order.
    #[must_use]
    pub const fn jump_to_code(self) -> u8 {
        match self {
            Self::Url => 1,
            Self::FileUrl => 2,
            Self::Command => 3,
            Self::Prompt => 4,
            Self::Pane | Self::Folder | Self::Agent | Self::RecentTab | Self::Path => 0,
        }
    }
}

/// The card's fixed width.
///
/// It does not track the window, for the palette's reason: a picker stretched across a full-screen
/// workspace puts its badges a screen from its titles. Wider than the palette's sibling numbers on
/// purpose — six filter pills across the top and a trailing cwd + badge column on every row need
/// the room, and a card that wrapped its pill ring would read as two rows of chrome above one row
/// of content.
pub const PANEL_WIDTH: f64 = 640.0;

/// The tallest the results viewport may be. Past this the list scrolls instead of the card growing.
pub const RESULTS_MAX_HEIGHT: f64 = 360.0;

/// The widest a row's trailing subtitle may be before it truncates.
///
/// The title has the rest, because the title is what the user is reading down the list.
pub const SUBTITLE_MAX_WIDTH: f64 = 240.0;

/// The ⌘K action sheet's width.
///
/// Narrower than the card by design — it is a menu ABOUT one row, and one as wide as the card would
/// read as a second list rather than as that row's verbs.
pub const ACTIONS_WIDTH: f64 = 240.0;

/// One ⇞/⇟ stride: the rows one full viewport shows.
///
/// Derived from the SAME number that sizes the viewport, so re-tuning the card re-tunes the page
/// rather than leaving a stride that no longer matches what the eye just skipped. The row height is
/// the caller's because only the caller knows what it actually drew.
#[must_use]
pub fn page_stride(row_height: f64) -> usize {
    if row_height <= 0.0 {
        return 1;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the quotient of two positive bounded lengths, floored, is a small row count"
    )]
    let rows = (RESULTS_MAX_HEIGHT / row_height) as usize;
    rows.max(1)
}

/// One line of the picker, in draw order: a section header, or a row paired with the index the
/// KEYBOARD knows it by.
///
/// The two indices differ, which is the whole reason this type exists — the drawn list interleaves
/// headers, while the selection counts only rows a user can land on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Line {
    /// A section's header, naming which source it heads.
    Header {
        /// The section's place in the caller's own list.
        section: usize,
    },
    /// A row.
    Row {
        /// The section it came from.
        section: usize,
        /// Its place inside that section.
        item: usize,
        /// Its place among the rows a user can land on — what the arrows count.
        selectable: usize,
    },
}

/// Flattens sections into draw order.
///
/// Headers appear only under the ALL pill: on a specific pill the pill IS the label, and a header
/// repeating it would be the same word twice in eight points of space. An EMPTY section grows no
/// header either — a caption over nothing is a section that looks like it failed to load.
///
/// The caller passes only the section SIZES, because the rows themselves never have to cross: what
/// it gets back is the interleave and the two index spaces, which is the part it would otherwise
/// pair by hand.
#[must_use]
pub fn draw_order(section_sizes: &[usize], filter: Filter) -> Vec<Line> {
    let show_headers = filter == Filter::All;
    let mut out = Vec::new();
    let mut selectable = 0;
    for (section, size) in section_sizes.iter().copied().enumerate() {
        if show_headers && size > 0 {
            out.push(Line::Header { section });
        }
        for item in 0..size {
            out.push(Line::Row {
                section,
                item,
                selectable,
            });
            selectable += 1;
        }
    }
    out
}

/// The zero-state line for the active pill.
///
/// Three answers, in the order that keeps each of them HONEST: a typed query that matched nothing
/// says so about the QUERY; an Agents fetch still in flight says it is LOADING rather than that
/// there are none; anything else is the source's own empty message.
#[must_use]
pub fn empty_message(query: &str, filter: Filter, agents_loading: bool) -> &'static str {
    if !query.trim().is_empty() {
        return Word::NoMatches.text();
    }
    if filter == Filter::Agents && agents_loading {
        return "Loading agents\u{2026}";
    }
    filter.empty_message()
}

/// One fixed word the card says, in the near side's own declaration order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Word {
    /// The zero state for a query that matched nothing.
    NoMatches,
    /// The footer's ⌘ hint.
    QuickSelectHint,
    /// The cap beside it.
    QuickSelectGlyph,
    /// The footer's ⌘K hint.
    ActionsHint,
    /// The cap beside it.
    ActionsGlyph,
    /// The ⌘K sheet's own zero state, when its filter narrowed past every verb.
    NoActionsMessage,
    /// The ⌘K sheet's filter placeholder.
    ActionsPrompt,
    /// The picker's own search prompt.
    SearchPrompt,
}

impl Word {
    /// Every word, in index order — the order one delivery carries them in.
    pub const ALL: [Self; 8] = [
        Self::NoMatches,
        Self::QuickSelectHint,
        Self::QuickSelectGlyph,
        Self::ActionsHint,
        Self::ActionsGlyph,
        Self::NoActionsMessage,
        Self::ActionsPrompt,
        Self::SearchPrompt,
    ];

    /// What it says.
    ///
    /// The two CAPS ride here beside the words they sit next to. They were literals at both call
    /// sites while the words were already shared — which is the shape that lets a rebind change the
    /// key on one platform's footer and leave the other advertising the old one.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::NoMatches => "No matches",
            Self::QuickSelectHint => "Quick Select",
            Self::QuickSelectGlyph => "\u{2318}",
            Self::ActionsHint => "Actions",
            Self::ActionsGlyph => "\u{2318}K",
            Self::NoActionsMessage => "No actions",
            Self::ActionsPrompt => "Filter actions\u{2026}",
            Self::SearchPrompt => "Search tabs, windows\u{2026}",
        }
    }
}

/// What a ⌘-modified key means INSIDE the picker.
///
/// ⚠️ Picker-LOCAL, never globally registered: while the picker is up the app yields the whole
/// keyboard to it, so ⌘W here picks a pill rather than closing the focused pane. That yield is what
/// makes this table safe to state at all.
///
/// Only the ⌘ table is shared. The arrows, ⇞/⇟, Home/End, Tab and ↩ are NOT, and deliberately: on
/// the phone they arrive as a key press, on the Mac as a field editor's editing command, and a
/// shared enum over two event shapes that different would be a translation layer pretending to be a
/// decision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Chord {
    /// ⌘1–9: run the Nth visible row outright. Carries the 1-BASED digit, as typed.
    QuickPick(u8),
    /// ⌘K: open or close the selected row's action sheet.
    ToggleActions,
    /// A pill chord: jump straight to that pill.
    SelectPill(Filter),
}

/// Reads one ⌘-modified character. [`None`] ⇒ the picker does not claim it.
///
/// The digit branch comes FIRST because a pill chord is matched case-insensitively over letters and
/// a digit could never be one — checking the pills first would only cost every ⌘1–9 a lookup. ⌘0 is
/// a pill and reaches the second walk, which is why the digit branch is bounded at 1.
#[must_use]
pub fn command_chord(character: char) -> Option<Chord> {
    if let Some(digit) = character.to_digit(10)
        && (1..=9).contains(&digit)
    {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the range guard above bounds this to 1..=9"
        )]
        return Some(Chord::QuickPick(digit as u8));
    }
    if character == 'k' || character == 'K' {
        return Some(Chord::ToggleActions);
    }
    let lowered = character.to_lowercase().next()?;
    Filter::PILLS
        .into_iter()
        .find(|pill| pill.chord_key() == lowered)
        .map(Chord::SelectPill)
}

/// Every verb a picker row can offer.
///
/// It is one enum's worth of product decision, and it is here rather than in either view because
/// the two halves would otherwise each carry a copy — and a copy of a verb table does not fail
/// loudly when it drifts, it just offers one surface a verb the other does not have.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verb {
    /// Close the row's pane, through the busy-shell guard rather than around it.
    ClosePane,
    /// Reveal the row's cwd in the host Finder.
    RevealCwd,
    /// Copy that cwd.
    CopyCwdPath,
    /// Open a fresh terminal split to the right, rooted at the folder.
    SplitRight,
    /// The same, below.
    SplitDown,
    /// `cd` the focused pane into the folder.
    ChangeDirectoryHere,
    /// Reveal the folder in the host Finder.
    RevealInFinder,
    /// Copy the folder's path.
    CopyPath,
    /// Drop the folder from the frecency list.
    ForgetFolder,
    /// Resume the agent session.
    ResumeSession,
    /// Copy the session's project path.
    CopyProjectPath,
    /// Copy the session's id.
    CopySessionId,
    /// Reopen exactly this row's closed tab.
    ReopenTab,
    /// Re-run this command in the focused pane.
    ReRunInCurrentPane,
    /// Copy the command's text.
    CopyCommand,
}

impl Verb {
    /// Every verb, in code order.
    pub const ALL: [Self; 15] = [
        Self::ClosePane,
        Self::RevealCwd,
        Self::CopyCwdPath,
        Self::SplitRight,
        Self::SplitDown,
        Self::ChangeDirectoryHere,
        Self::RevealInFinder,
        Self::CopyPath,
        Self::ForgetFolder,
        Self::ResumeSession,
        Self::CopyProjectPath,
        Self::CopySessionId,
        Self::ReopenTab,
        Self::ReRunInCurrentPane,
        Self::CopyCommand,
    ];

    /// This verb's own code — what the near side switches on to actuate it.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::ClosePane => 0,
            Self::RevealCwd => 1,
            Self::CopyCwdPath => 2,
            Self::SplitRight => 3,
            Self::SplitDown => 4,
            Self::ChangeDirectoryHere => 5,
            Self::RevealInFinder => 6,
            Self::CopyPath => 7,
            Self::ForgetFolder => 8,
            Self::ResumeSession => 9,
            Self::CopyProjectPath => 10,
            Self::CopySessionId => 11,
            Self::ReopenTab => 12,
            Self::ReRunInCurrentPane => 13,
            Self::CopyCommand => 14,
        }
    }

    /// Its row title.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::ClosePane => "Close Pane",
            Self::RevealCwd => "Reveal CWD in Finder",
            Self::CopyCwdPath => "Copy CWD Path",
            Self::SplitRight => "Split Right",
            Self::SplitDown => "Split Down",
            Self::ChangeDirectoryHere => "Change Directory Here",
            Self::RevealInFinder => "Reveal in Finder",
            Self::CopyPath => "Copy Path",
            Self::ForgetFolder => "Forget This Folder",
            Self::ResumeSession => "Resume Session",
            Self::CopyProjectPath => "Copy Project Path",
            Self::CopySessionId => "Copy Session ID",
            Self::ReopenTab => "Reopen Tab",
            Self::ReRunInCurrentPane => "Re-Run in Current Pane",
            Self::CopyCommand => "Copy Command",
        }
    }

    /// Its silhouette, as a symbol name.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::ClosePane => "xmark",
            Self::RevealCwd | Self::RevealInFinder => "folder",
            Self::CopyCwdPath | Self::CopyPath | Self::CopyProjectPath | Self::CopyCommand => "doc.on.doc",
            Self::SplitRight => "rectangle.split.2x1",
            Self::SplitDown => "rectangle.split.1x2",
            Self::ChangeDirectoryHere => "arrow.turn.down.right",
            Self::ForgetFolder => "trash",
            Self::ResumeSession => "play",
            Self::CopySessionId => "number",
            Self::ReopenTab => "arrow.uturn.left",
            Self::ReRunInCurrentPane => "arrow.clockwise",
        }
    }
}

/// What firing a row DOES — the shape the near side already carries on every item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Act {
    /// Focus an open pane.
    FocusPane,
    /// `cd` into a folder.
    OpenFolder,
    /// Resume an agent session.
    ResumeAgent,
    /// Reopen a closed tab by its own LIFO index.
    ReopenRecentTab,
    /// Hand the row to the shared jump-to table.
    JumpTo,
}

impl Act {
    /// Every act, in code order.
    pub const ALL: [Self; 5] = [
        Self::FocusPane,
        Self::OpenFolder,
        Self::ResumeAgent,
        Self::ReopenRecentTab,
        Self::JumpTo,
    ];

    /// The act a code names, or [`None`] for one no act has.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::FocusPane),
            1 => Some(Self::OpenFolder),
            2 => Some(Self::ResumeAgent),
            3 => Some(Self::ReopenRecentTab),
            4 => Some(Self::JumpTo),
            _ => None,
        }
    }

    /// This act's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::FocusPane => 0,
            Self::OpenFolder => 1,
            Self::ResumeAgent => 2,
            Self::ReopenRecentTab => 3,
            Self::JumpTo => 4,
        }
    }
}

/// What a row offers under ⌘K, and what stands in when it offers nothing of its own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Table {
    /// This row's own verbs, in table order.
    Verbs(Vec<Verb>),
    /// A Current row that is not a command: the SHARED jump-to table answers, which the near side
    /// already owns because a link opened from the picker and the same link opened from a renderer
    /// must take exactly one path.
    SharedJumpTo,
}

/// The row's ⌘K action table.
///
/// Two omissions are DELIBERATE rather than dead rows: "Move Tab to New Window" and "Open in New
/// Window" are N/A in the single-window vertical-rail model, and "Re-Run in New Tab" waits on a
/// store hook that does not exist. "Switch to Pane" is dropped for a different reason — ↩ already
/// does it.
///
/// `has_subtitle` is whether the row carries a cwd to act on, `cwd_empty` whether an agent row's
/// project path is blank, and `folders_backed` whether a frecency store backs the list — Forget
/// This Folder appears only when there is something to forget it FROM.
#[must_use]
pub fn row_actions(act: Act, kind: Kind, has_subtitle: bool, cwd_empty: bool, folders_backed: bool) -> Table {
    match act {
        // A Current COMMAND row gets the verbatim re-run pair, NOT the generic jump-to the shared
        // table returns: the row IS a command that already ran, and the thing you want from one is
        // to run it again. Prompt / path / url / file rows keep the shared table.
        Act::JumpTo if kind == Kind::Command => {
            Table::Verbs(vec![Verb::ReRunInCurrentPane, Verb::CopyCommand])
        },
        Act::JumpTo => Table::SharedJumpTo,
        Act::FocusPane => {
            let mut verbs = vec![Verb::ClosePane];
            if has_subtitle {
                verbs.push(Verb::RevealCwd);
                verbs.push(Verb::CopyCwdPath);
            }
            Table::Verbs(verbs)
        },
        Act::OpenFolder => {
            let mut verbs = vec![
                Verb::SplitRight,
                Verb::SplitDown,
                Verb::ChangeDirectoryHere,
                Verb::RevealInFinder,
                Verb::CopyPath,
            ];
            if folders_backed {
                verbs.push(Verb::ForgetFolder);
            }
            Table::Verbs(verbs)
        },
        Act::ResumeAgent => {
            let mut verbs = vec![Verb::ResumeSession];
            if !cwd_empty {
                verbs.push(Verb::CopyProjectPath);
            }
            verbs.push(Verb::CopySessionId);
            Table::Verbs(verbs)
        },
        Act::ReopenRecentTab => {
            let mut verbs = vec![Verb::ReopenTab];
            if has_subtitle {
                verbs.push(Verb::CopyCwdPath);
            }
            Table::Verbs(verbs)
        },
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a table of the wrong shape has nothing left to assert on"
    )]

    use super::{
        Act, Chord, Filter, Kind, Line, RESULTS_MAX_HEIGHT, Table, Verb, Word, command_chord, draw_order,
        empty_message, page_stride, row_actions,
    };

    #[test]
    fn every_pill_and_kind_round_trips_through_its_code() {
        for pill in Filter::PILLS {
            assert_eq!(Filter::from_code(pill.code()), Some(pill));
            assert!(!pill.label().is_empty());
            assert!(!pill.symbol().is_empty());
            assert!(!pill.empty_message().is_empty());
        }
        assert_eq!(Filter::from_code(6), None);
        for kind in Kind::ALL {
            assert_eq!(Kind::from_code(kind.code()), Some(kind));
            assert!(!kind.badge().is_empty());
            assert!(!kind.symbol().is_empty());
        }
        assert_eq!(Kind::from_code(9), None);
        for act in Act::ALL {
            assert_eq!(Act::from_code(act.code()), Some(act));
        }
        assert_eq!(Act::from_code(5), None);
    }

    /// `All` is the merged view of the others, never a section of its own.
    #[test]
    fn the_merged_pill_is_not_one_of_the_sections_it_merges() {
        assert!(!Filter::SECTIONS.contains(&Filter::All));
        assert_eq!(Filter::SECTIONS.len() + 1, Filter::PILLS.len());
        assert_eq!(Filter::Opened.section_header(), "OPENED");
    }

    #[test]
    fn no_two_pills_share_a_chord_key() {
        let mut keys: Vec<char> = Filter::PILLS.iter().map(|pill| pill.chord_key()).collect();
        keys.sort_unstable();
        let count = keys.len();
        keys.dedup();
        assert_eq!(keys.len(), count);
    }

    /// The one thing a half pairing these itself would get off by one.
    #[test]
    fn the_selectable_index_counts_rows_and_never_headers() {
        let lines = draw_order(&[2, 0, 1], Filter::All);
        assert_eq!(lines, vec![
            Line::Header { section: 0 },
            Line::Row {
                section: 0,
                item: 0,
                selectable: 0
            },
            Line::Row {
                section: 0,
                item: 1,
                selectable: 1
            },
            Line::Header { section: 2 },
            Line::Row {
                section: 2,
                item: 0,
                selectable: 2
            },
        ],);
    }

    /// On a specific pill the pill IS the label; a header would say the same word twice.
    #[test]
    fn only_the_merged_pill_grows_headers() {
        let lines = draw_order(&[2, 1], Filter::Folders);
        assert!(lines.iter().all(|line| matches!(line, Line::Row { .. })));
        assert_eq!(lines.len(), 3);
        assert!(draw_order(&[], Filter::All).is_empty());
        assert!(
            draw_order(&[0, 0], Filter::All).is_empty(),
            "a caption over nothing reads as a section that failed to load",
        );
    }

    /// Three answers, each honest about a different reason the list is empty.
    #[test]
    fn the_zero_state_blames_the_query_the_fetch_or_the_source() {
        assert_eq!(
            empty_message("needle", Filter::Agents, true),
            Word::NoMatches.text()
        );
        assert_eq!(
            empty_message("  ", Filter::Agents, true),
            "Loading agents\u{2026}"
        );
        assert_eq!(
            empty_message("", Filter::Agents, false),
            Filter::Agents.empty_message()
        );
        assert_eq!(
            empty_message("", Filter::Opened, true),
            Filter::Opened.empty_message()
        );
    }

    #[test]
    fn the_stride_follows_the_viewport_it_pages() {
        assert_eq!(page_stride(36.0), 10);
        assert_eq!(page_stride(RESULTS_MAX_HEIGHT), 1);
        assert_eq!(page_stride(RESULTS_MAX_HEIGHT * 2.0), 1, "never a stride of zero");
        assert_eq!(page_stride(0.0), 1);
        assert_eq!(page_stride(-4.0), 1);
    }

    /// The digit branch must not eat ⌘0, which is a pill.
    #[test]
    fn the_chord_table_reads_digits_then_actions_then_pills() {
        assert_eq!(command_chord('1'), Some(Chord::QuickPick(1)));
        assert_eq!(command_chord('9'), Some(Chord::QuickPick(9)));
        assert_eq!(command_chord('0'), Some(Chord::SelectPill(Filter::All)));
        assert_eq!(command_chord('k'), Some(Chord::ToggleActions));
        assert_eq!(command_chord('K'), Some(Chord::ToggleActions));
        assert_eq!(command_chord('W'), Some(Chord::SelectPill(Filter::Opened)));
        assert_eq!(command_chord('j'), Some(Chord::SelectPill(Filter::Current)));
        assert_eq!(command_chord('q'), None);
    }

    #[test]
    fn a_footer_verb_is_the_rows_and_not_the_pickers() {
        assert_eq!(Kind::default_action_label(Some(Kind::Pane)), "Switch to");
        assert_eq!(Kind::default_action_label(Some(Kind::RecentTab)), "Reopen");
        assert_eq!(Kind::default_action_label(Some(Kind::Folder)), "Change Directory");
        assert_eq!(Kind::default_action_label(Some(Kind::Agent)), "Resume");
        assert_eq!(Kind::default_action_label(Some(Kind::Command)), "Jump to");
        assert_eq!(Kind::default_action_label(Some(Kind::Url)), "Open");
        assert_eq!(Kind::default_action_label(None), "Open");
    }

    /// A command row is the one Current row that does NOT get the shared table.
    #[test]
    fn a_command_row_offers_the_rerun_pair_and_every_other_jump_row_shares() {
        assert_eq!(
            row_actions(Act::JumpTo, Kind::Command, false, true, false),
            Table::Verbs(vec![Verb::ReRunInCurrentPane, Verb::CopyCommand]),
        );
        for kind in [Kind::Prompt, Kind::Path, Kind::Url, Kind::FileUrl] {
            assert_eq!(
                row_actions(Act::JumpTo, kind, false, true, false),
                Table::SharedJumpTo,
                "{kind:?}",
            );
        }
    }

    /// Every conditional row is absent rather than dead when nothing backs it.
    #[test]
    fn a_verb_with_nothing_to_act_on_is_not_offered() {
        assert_eq!(
            row_actions(Act::FocusPane, Kind::Pane, false, true, false),
            Table::Verbs(vec![Verb::ClosePane]),
        );
        assert_eq!(
            row_actions(Act::FocusPane, Kind::Pane, true, true, false),
            Table::Verbs(vec![Verb::ClosePane, Verb::RevealCwd, Verb::CopyCwdPath]),
        );
        let Table::Verbs(unbacked) = row_actions(Act::OpenFolder, Kind::Folder, false, true, false) else {
            panic!("a folder row has its own verbs");
        };
        assert!(!unbacked.contains(&Verb::ForgetFolder));
        let Table::Verbs(backed) = row_actions(Act::OpenFolder, Kind::Folder, false, true, true) else {
            panic!("a folder row has its own verbs");
        };
        assert!(backed.contains(&Verb::ForgetFolder));
        let Table::Verbs(blank) = row_actions(Act::ResumeAgent, Kind::Agent, false, true, false) else {
            panic!("an agent row has its own verbs");
        };
        assert_eq!(blank, vec![Verb::ResumeSession, Verb::CopySessionId]);
    }

    /// The whole reason the table crosses: a copy of it diverges on the first new verb.
    #[test]
    fn every_verb_has_a_distinct_code_and_a_distinct_title() {
        let mut codes: Vec<u8> = Verb::ALL.iter().map(|verb| verb.code()).collect();
        codes.sort_unstable();
        let count = codes.len();
        codes.dedup();
        assert_eq!(codes.len(), count);

        let mut titles: Vec<&str> = Verb::ALL.iter().map(|verb| verb.title()).collect();
        for title in &titles {
            assert!(!title.is_empty());
        }
        titles.sort_unstable();
        let count = titles.len();
        titles.dedup();
        assert_eq!(titles.len(), count);

        for verb in Verb::ALL {
            assert!(!verb.symbol().is_empty(), "{verb:?}");
        }
        for word in Word::ALL {
            assert!(!word.text().is_empty(), "{word:?}");
        }
    }

    /// A tab is reopened by its OWN index — not by popping the newest, which is a different verb.
    #[test]
    fn a_recent_tab_row_reopens_itself() {
        assert_eq!(
            row_actions(Act::ReopenRecentTab, Kind::RecentTab, true, true, false),
            Table::Verbs(vec![Verb::ReopenTab, Verb::CopyCwdPath]),
        );
    }
}
