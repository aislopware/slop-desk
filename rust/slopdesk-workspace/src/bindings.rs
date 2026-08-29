//! The workspace command surface: every keybinding row, entire.
//!
//! ## What this replaces
//!
//! This module used to be [`crate::binding_rows`], and it held ONE column — which half lists a row.
//! The other six columns (title, category, chord, symbol, keywords, and the action itself) were a
//! Swift array literal in `WorkspaceBindingRegistry.swift`, and `rust/slopdesk-invariants` held the
//! two id lists equal with a `SameSet` claim over a regex on each side. That is a join maintained
//! by hand across a language boundary — the cross-language mirror `CLAUDE.md` forbids by name — and
//! the `SameSet` was the tell rather than the safeguard. docs/64 is the campaign; this module is
//! its whole data half.
//!
//! ## The defect the platform column exists to close
//!
//! The palette table ([`crate::palette_rows`]) closed three rows that were listed and inert. The
//! registry those rows mirror listed the same three verbs: *Detach Pane into Window* on ⌥⌘P,
//! *Reattach All Panes*, and *Pin Window*. The registry is not one surface — it is the cheat sheet,
//! the keybindings editor, the `ctl` verb list and the CHORD TABLE the keyboard dispatcher resolves
//! against. So on a phone ⌥⌘P was swallowed by a binding that routed to a macOS-only `#if` with
//! nothing in the `#else`, and the keybindings editor offered to REBIND a chord onto an action that
//! half cannot perform.
//!
//! The chord table is the part that made this worse than a cosmetic row. A bound chord does not
//! reach the terminal: ⌥⌘P was taken away from the PTY to run nothing. Dropping the row drops the
//! chord, so the key falls through to the pane, which is what an unbound chord is supposed to do.
//!
//! ## Why a SECOND table and not one shared with the palette
//!
//! Because they are two id spaces over two vocabularies, and the overlap is partial in both
//! directions. The palette files verbs as `action.detachPane`; the registry files the same verb as
//! `pane.detach`, and it also carries ~45 rows with no palette entry at all (every focus move,
//! every resize nudge, every scroll jump) plus rows the palette has and the registry does not
//! (`action.connect`, `action.copyPath`). A table keyed by one spelling could not answer for the
//! other's rows, and a table keyed by both would be a join maintained by hand.
//!
//! ## What is still Swift, and why it is not a mirror
//!
//! [`Action`] names the same vocabulary `WorkspaceAction` does, and that enum stays Swift because
//! the UI `switch`es over it to reach a store op. It crosses as this tag, mapped at ONE typed site,
//! with the case-for-tag parity pinned — the sanctioned "constant typed in both languages", not a
//! second table. The nine `pane.select.1`…`pane.select.9` rows stay a `(1...9).map` in Swift: a
//! loop over a formula has no twin here to drift from. Every DERIVED table (`chordTable`,
//! `byAction`, `groupedForDisplay`, the override merge) is Swift too, was never duplicated, and
//! keeps the per-keystroke path a hash lookup with no door on it — this table is walked once,
//! building a `static let`, and never again.
//!
//! GOLDEN-SAFE: metadata only. Nothing here reads or writes a value or touches a wire codec.

use crate::platform::Platform;

/// The action a row runs — the tag half of Swift's `WorkspaceAction`.
///
/// The discriminants ARE that enum's case order, so the parity rule can read both as positions
/// rather than as a name mapping anyone maintains. [`Action::ApplyLayout`] is the one case with no
/// row in [`ROWS`]: the five named layout presets are menu/palette only, reached with a payload
/// this table has no column for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u16)]
pub enum Action {
    /// ⌘D — split the active pane into a side-by-side column.
    SplitRight = 0,
    /// ⌘⇧D — split the active pane into a stacked row.
    SplitDown = 1,
    /// ⌘⌥D — split, inserting the new pane on the LEADING (left) side.
    SplitLeft = 2,
    /// ⌘⌥⇧D — split, inserting the new pane on the LEADING (top) side.
    SplitUp = 3,
    /// ⌘W — close the active pane, cascading the tab and the session.
    ClosePane = 4,
    /// Rename the active TAB from the inline tab-strip field.
    RenamePane = 5,
    /// ⌃⌘T — eject the active pane into a new tab.
    BreakPaneToTab = 6,
    /// ⌥⌘P — pop the active pane into its OWN macOS window; the session survives.
    DetachPane = 7,
    /// Fold every detached pane back into its tab.
    ReattachAllPanes = 8,
    /// ⌥⌘⇧← — swap the active pane with its left neighbour.
    MovePaneLeft = 9,
    /// ⌥⌘⇧→ — swap the active pane with its right neighbour.
    MovePaneRight = 10,
    /// ⌥⌘⇧↑ — swap the active pane with the one above.
    MovePaneUp = 11,
    /// ⌥⌘⇧↓ — swap the active pane with the one below.
    MovePaneDown = 12,
    /// ⌃⌘⇧← — nudge the divider left, shrinking the active pane.
    ResizePaneLeft = 13,
    /// ⌃⌘⇧→ — nudge the divider right, growing the active pane.
    ResizePaneRight = 14,
    /// ⌃⌘⇧↑ — nudge the divider up, shrinking the active pane.
    ResizePaneUp = 15,
    /// ⌃⌘⇧↓ — nudge the divider down, growing the active pane.
    ResizePaneDown = 16,
    /// ⌃⌘= — reset the active tab's split weights to equal (tmux even-layout).
    BalancePanes = 17,
    /// ⌃⌘L — step through the algorithmic re-tile presets.
    CycleLayout = 18,
    /// Carries a `LayoutPreset` on the Swift side; menu/palette only, so no row declares it.
    ApplyLayout = 19,
    /// ⌃⌘← — move the keyboard to the pane on the left.
    FocusLeft = 20,
    /// ⌃⌘→ — move the keyboard to the pane on the right.
    FocusRight = 21,
    /// ⌃⌘↑ — move the keyboard to the pane above.
    FocusUp = 22,
    /// ⌃⌘↓ — move the keyboard to the pane below.
    FocusDown = 23,
    /// ⌘] — focus the NEXT pane in DFS order, wrapping.
    CyclePaneNext = 24,
    /// ⌘[ — focus the PREVIOUS pane in DFS order, wrapping.
    CyclePanePrev = 25,
    /// ⌘⇧↩ — maximize or restore the active pane (render-only).
    ToggleZoom = 26,
    /// ⌘⇧P — show or hide the command palette.
    CommandPalette = 27,
    /// ⌘/ — show or hide the keyboard cheat sheet.
    CheatSheet = 28,
    /// ⌘F — show or hide the find bar over the active pane.
    Find = 29,
    /// ⌘G — advance to the next match, opening the find bar if closed.
    FindNext = 30,
    /// ⇧⌘G — step to the previous match, opening the find bar if closed.
    FindPrev = 31,
    /// ⇧⌘F — show or hide the cross-tab Global Search surface.
    GlobalSearch = 32,
    /// ⌘⇧C (+ ⌃⇧Space) — enter modal vi / copy-mode over the active pane.
    ToggleCopyMode = 33,
    /// Toggle the active pane's `⌘/` vi key-hint bar.
    ToggleViKeyHints = 34,
    /// Toggle the active pane's read-only input gate.
    ToggleReadOnly = 35,
    /// The MANUAL toggle for macOS process-global secure event input.
    SecureKeyboardEntry = 36,
    /// Synthesize key-up and mouse-up for a remote pane whose host is stuck.
    ReleaseStuckInput = 37,
    /// ⌥⌘L — freeze the active remote pane's edge-hover auto-pan.
    ToggleViewportLock = 38,
    /// Fit the active remote pane's viewport to the pane.
    FitViewportToPane = 39,
    /// Return the active remote pane's viewport to actual size.
    ResetViewportZoom = 40,
    /// ⌥⌘V — type the LOCAL clipboard into the host as paced per-key events.
    PasteAsKeystrokes = 41,
    /// ⌘⇧L — show or hide the sessions sidebar.
    ToggleSidebar = 42,
    /// ⌘⇧R — show or hide the embedded editor panel.
    ToggleCodeSidebar = 43,
    /// ⌥⌘R — move the keyboard between the terminal and the editor, and back.
    FocusCodePanel = 44,
    /// Keep the window floating above every other app's windows.
    PinWindow = 45,
    /// ⌘⇧O — open the fuzzy file / symbol switcher.
    OpenQuickly = 46,
    /// ⌘J — open the Jump-To panel over the active pane's links and prompts.
    JumpTo = 47,
    /// ⌘⇧J — label every target in the viewport, then open the one typed.
    HintToOpen = 48,
    /// ⌘⇧Y — label every target, then copy the one typed to the clipboard.
    HintToCopy = 49,
    /// Label every target, then reveal the one typed in Finder on the host.
    HintToReveal = 50,
    /// ⇧`PageUp` — scroll the active pane one page toward older scrollback.
    ScrollPageUp = 51,
    /// ⇧`PageDown` — scroll the active pane one page toward newer output.
    ScrollPageDown = 52,
    /// ⇧Home — jump the viewport to the top of the scrollback buffer.
    ScrollToTop = 53,
    /// ⇧End — jump the viewport to the newest output.
    ScrollToBottom = 54,
    /// ⌘`PageUp` — jump to the previous shell prompt.
    CommandJumpPrev = 55,
    /// ⌘`PageDown` — jump to the next shell prompt.
    CommandJumpNext = 56,
    /// ⌘= (+ ⌘+) — grow the render font, reflowing the remote grid.
    IncreaseFontSize = 57,
    /// ⌘- — shrink the render font, reflowing the remote grid.
    DecreaseFontSize = 58,
    /// ⌘0 — return the render font to the configured default.
    ResetFontSize = 59,
    /// ⌃⌘O — show or hide the searchable recent-blocks navigator.
    CommandNavigator = 60,
    /// ⌃⌘[ — jump the viewport to the previous OSC-133 prompt.
    JumpPreviousBlock = 61,
    /// ⌃⌘] — jump the viewport to the next OSC-133 prompt.
    JumpNextBlock = 62,
    /// ⌃⌘R — re-inject the pane's latest captured command, verbatim.
    ReRunLastCommand = 63,
    /// ⌃⌘⇧[ — jump to the previous FAILED block.
    JumpPreviousFailed = 64,
    /// ⌃⌘⇧] — jump to the next FAILED block.
    JumpNextFailed = 65,
    /// ⌘T — open a new tab.
    NewTab = 66,
    /// ⌥⌘N — reveal or mint the remote-desktop WINDOW (the name is historical).
    NewDesktopTab = 67,
    /// ⌘⇧] — cycle forward through the session's tabs.
    NextTab = 68,
    /// ⌘⇧[ — cycle back through the session's tabs.
    PrevTab = 69,
    /// Carries the 1-based pane number on the Swift side.
    SelectPane = 70,
    /// ⌃⇥ — the press-and-hold MRU switcher, owned by each platform's responder.
    PaneSwitcher = 71,
    /// Close the active tab and all its panes.
    CloseTab = 72,
    /// ⌘⇧W — close the active window, which is a session.
    CloseWindow = 73,
    /// ⌘⇧T — reopen the most recently closed pane.
    ReopenClosed = 74,
    /// ⌘⇧I — broadcast keystrokes to every other pane in the tab.
    ToggleSyncInput = 75,
    /// ⌘⇧U — focus the oldest pane needing attention.
    JumpToAttention = 76,
    /// ⌘⌥J — answer the oldest blocked pane inline, without a context switch.
    PeekAndReply = 77,
}

impl Action {
    /// Every action, in case order. The parity rule walks this against the Swift enum.
    pub const ALL: [Self; 78] = [
        Self::SplitRight,
        Self::SplitDown,
        Self::SplitLeft,
        Self::SplitUp,
        Self::ClosePane,
        Self::RenamePane,
        Self::BreakPaneToTab,
        Self::DetachPane,
        Self::ReattachAllPanes,
        Self::MovePaneLeft,
        Self::MovePaneRight,
        Self::MovePaneUp,
        Self::MovePaneDown,
        Self::ResizePaneLeft,
        Self::ResizePaneRight,
        Self::ResizePaneUp,
        Self::ResizePaneDown,
        Self::BalancePanes,
        Self::CycleLayout,
        Self::ApplyLayout,
        Self::FocusLeft,
        Self::FocusRight,
        Self::FocusUp,
        Self::FocusDown,
        Self::CyclePaneNext,
        Self::CyclePanePrev,
        Self::ToggleZoom,
        Self::CommandPalette,
        Self::CheatSheet,
        Self::Find,
        Self::FindNext,
        Self::FindPrev,
        Self::GlobalSearch,
        Self::ToggleCopyMode,
        Self::ToggleViKeyHints,
        Self::ToggleReadOnly,
        Self::SecureKeyboardEntry,
        Self::ReleaseStuckInput,
        Self::ToggleViewportLock,
        Self::FitViewportToPane,
        Self::ResetViewportZoom,
        Self::PasteAsKeystrokes,
        Self::ToggleSidebar,
        Self::ToggleCodeSidebar,
        Self::FocusCodePanel,
        Self::PinWindow,
        Self::OpenQuickly,
        Self::JumpTo,
        Self::HintToOpen,
        Self::HintToCopy,
        Self::HintToReveal,
        Self::ScrollPageUp,
        Self::ScrollPageDown,
        Self::ScrollToTop,
        Self::ScrollToBottom,
        Self::CommandJumpPrev,
        Self::CommandJumpNext,
        Self::IncreaseFontSize,
        Self::DecreaseFontSize,
        Self::ResetFontSize,
        Self::CommandNavigator,
        Self::JumpPreviousBlock,
        Self::JumpNextBlock,
        Self::ReRunLastCommand,
        Self::JumpPreviousFailed,
        Self::JumpNextFailed,
        Self::NewTab,
        Self::NewDesktopTab,
        Self::NextTab,
        Self::PrevTab,
        Self::SelectPane,
        Self::PaneSwitcher,
        Self::CloseTab,
        Self::CloseWindow,
        Self::ReopenClosed,
        Self::ToggleSyncInput,
        Self::JumpToAttention,
        Self::PeekAndReply,
    ];

    /// The tag this action crosses as.
    #[must_use]
    pub const fn tag(self) -> u16 {
        self as u16
    }

    /// The action `tag` names, or `None` for a tag this build does not know.
    #[must_use]
    pub fn from_tag(tag: u16) -> Option<Self> {
        Self::ALL.get(usize::from(tag)).copied()
    }

    /// Whether running this action requires an active pane — so the palette can omit it on an empty
    /// shell and the menu can grey it out.
    ///
    /// Per ACTION, not per row, which is why it is a function rather than a column:
    /// [`Action::ApplyLayout`] has no row and still has an answer.
    ///
    /// The `true` set is two families that read differently and decide the same. The first
    /// genuinely cannot run without a pane — a split has nothing to split, a focus move nothing
    /// to move from. The second targets the active TERMINAL pane and degrades gracefully (a
    /// no-pane shell just no-ops): find, the block jumps, scroll, font size, hint mode, and the
    /// remote-GUI viewport verbs. They are still `true` because the palette listing them on an
    /// empty shell would offer a row that cannot do anything — the same defect the platform
    /// column closes, one scope in.
    #[must_use]
    pub const fn requires_active_pane(self) -> bool {
        match self {
            Self::SplitRight
            | Self::SplitDown
            | Self::SplitLeft
            | Self::SplitUp
            | Self::ClosePane
            | Self::RenamePane
            | Self::BreakPaneToTab
            | Self::DetachPane
            | Self::MovePaneLeft
            | Self::MovePaneRight
            | Self::MovePaneUp
            | Self::MovePaneDown
            | Self::ResizePaneLeft
            | Self::ResizePaneRight
            | Self::ResizePaneUp
            | Self::ResizePaneDown
            | Self::BalancePanes
            | Self::CycleLayout
            | Self::ApplyLayout
            | Self::FocusLeft
            | Self::FocusRight
            | Self::FocusUp
            | Self::FocusDown
            | Self::CyclePaneNext
            | Self::CyclePanePrev
            | Self::ToggleZoom
            | Self::Find
            | Self::FindNext
            | Self::FindPrev
            | Self::ToggleCopyMode
            | Self::ToggleViKeyHints
            | Self::ToggleReadOnly
            | Self::SecureKeyboardEntry
            | Self::ReleaseStuckInput
            | Self::ToggleViewportLock
            | Self::FitViewportToPane
            | Self::ResetViewportZoom
            | Self::PasteAsKeystrokes
            | Self::CommandNavigator
            | Self::JumpTo
            | Self::HintToOpen
            | Self::HintToCopy
            | Self::HintToReveal
            | Self::JumpPreviousBlock
            | Self::JumpNextBlock
            | Self::ReRunLastCommand
            | Self::JumpPreviousFailed
            | Self::JumpNextFailed
            | Self::ScrollPageUp
            | Self::ScrollPageDown
            | Self::ScrollToTop
            | Self::ScrollToBottom
            | Self::CommandJumpPrev
            | Self::CommandJumpNext
            | Self::IncreaseFontSize
            | Self::DecreaseFontSize
            | Self::ResetFontSize => true,
            // Window / session / global scope: the palette, the cheat sheet, a cross-tab results
            // surface, tab and window verbs, the two supervision jumps, and the chrome toggles. Each
            // acts on something larger than the focused pane, so an empty shell is not a reason to
            // hide it.
            Self::CommandPalette
            | Self::CheatSheet
            | Self::GlobalSearch
            | Self::NewTab
            | Self::NewDesktopTab
            | Self::NextTab
            | Self::PrevTab
            | Self::SelectPane
            | Self::PaneSwitcher
            | Self::CloseTab
            | Self::CloseWindow
            | Self::ReopenClosed
            | Self::ToggleSidebar
            | Self::ToggleCodeSidebar
            | Self::FocusCodePanel
            | Self::PinWindow
            | Self::OpenQuickly
            | Self::ToggleSyncInput
            | Self::JumpToAttention
            | Self::PeekAndReply
            | Self::ReattachAllPanes => false,
        }
    }
}

/// The display category the cheat sheet groups by (and the menu / palette sections mirror).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Category {
    /// Splits, moves, resizes and the pane lifecycle.
    Panes = 0,
    /// Tabs, the window, and the two supervision jumps.
    Tabs = 1,
    /// Moving the keyboard between panes, and into the editor.
    Focus = 2,
    /// Everything that changes what a pane SHOWS rather than which one is live.
    View = 3,
}

/// A non-printable key, by the case index [`KeyChord.Key`] already crosses as.
///
/// The eleven positions are that Swift enum's own case order, which `slopdesk_video::key_naming`
/// also spells — so a chord crosses as an INDEX rather than as a name, and nothing here restates a
/// vocabulary that already has one owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i16)]
pub enum NamedKey {
    /// ↩
    Return = 0,
    /// ⇥
    Tab = 1,
    /// the Space bar as a NAMED key (keyCode 49), never a character
    Space = 2,
    /// ←
    LeftArrow = 3,
    /// →
    RightArrow = 4,
    /// ↑
    UpArrow = 5,
    /// ↓
    DownArrow = 6,
    /// `PageUp`
    PageUp = 7,
    /// `PageDown`
    PageDown = 8,
    /// Home
    Home = 9,
    /// End
    End = 10,
}

/// ⇧, as a modifier bit.
pub const SHIFT: u8 = 1 << 0;
/// ⌃, as a modifier bit.
pub const CONTROL: u8 = 1 << 1;
/// ⌥, as a modifier bit.
pub const OPTION: u8 = 1 << 2;
/// ⌘, as a modifier bit.
pub const COMMAND: u8 = 1 << 3;

/// A keyboard chord: a key plus its modifier set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chord {
    /// The named key, or `None` for a printable one — read [`Chord::character`] then.
    pub named: Option<NamedKey>,
    /// The printable key, lower-cased. Meaningless when [`Chord::named`] is set.
    pub character: char,
    /// [`SHIFT`] · [`CONTROL`] · [`OPTION`] · [`COMMAND`].
    pub modifiers: u8,
}

/// A printable-character chord. The character is written lower-case here rather than lowered at
/// runtime, so the table reads as what the key delivers.
#[expect(
    clippy::unnecessary_wraps,
    reason = "a row's chord field is Option<Chord> because a chord-less row spells None; a               \
              constructor that answered Chord would put Some( ) on seventy rows to save it on none"
)]
const fn ch(character: char, modifiers: u8) -> Option<Chord> {
    Some(Chord {
        named: None,
        character,
        modifiers,
    })
}

/// A named-key chord.
#[expect(
    clippy::unnecessary_wraps,
    reason = "the same field type as `ch`, spelled the same way so the table's two chord columns read alike"
)]
const fn key(named: NamedKey, modifiers: u8) -> Option<Chord> {
    Some(Chord {
        named: Some(named),
        character: '\0',
        modifiers,
    })
}

/// Which of the three sets a row belongs to.
///
/// One table, three views: the registry filters `Declared` into its display list, and lifts
/// `Representative` out separately because the cheat sheet appends it AFTER the platform filter
/// while the palette catalog and the menu omit it entirely.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    /// A row of the shipped table, in display order.
    Declared = 0,
    /// The collapsed ⌘1…⌘9 stand-in — display only; the nine real chords are generated in Swift.
    Representative = 1,
}

/// One binding row, entire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Binding {
    /// The stable `<noun>.<verb>` id — the dedup, rebind and override key.
    pub id: &'static str,
    /// The action the row runs.
    pub action: Action,
    /// The payload the action carries, or `0`. Only [`Action::SelectPane`] uses it.
    pub arg: i32,
    /// The menu / palette / cheat-sheet title.
    pub title: &'static str,
    /// The cheat-sheet group.
    pub category: Category,
    /// The default chord, or `None` for a row surfaced only in the palette / menu.
    pub chord: Option<Chord>,
    /// SF Symbol for the menu / palette row.
    pub symbol: &'static str,
    /// Extra non-displayed fuzzy-match terms — folded into the palette haystack, never rendered.
    pub keywords: Option<&'static str>,
    /// Which half lists the row, and therefore which half BINDS its chord.
    pub platform: Platform,
    /// Which of the three sets it belongs to.
    pub kind: Kind,
}

/// One row. Positional on purpose — a struct literal per row would triple the table's height and
/// bury the data under field names that never vary.
#[expect(
    clippy::too_many_arguments,
    reason = "a row IS its columns; naming them at each of 77 call sites is the alternative"
)]
const fn row(
    id: &'static str,
    action: Action,
    title: &'static str,
    category: Category,
    chord: Option<Chord>,
    symbol: &'static str,
    keywords: Option<&'static str>,
    platform: Platform,
) -> Binding {
    Binding {
        id,
        action,
        arg: 0,
        title,
        category,
        chord,
        symbol,
        keywords,
        platform,
        kind: Kind::Declared,
    }
}

/// Every row the registry writes out, in display order (panes, tabs, focus, view), with the
/// collapsed select-pane representative last.
///
/// Every chord is ⌘- or ⌥-prefixed — the load-bearing §5 conflict rule: a bare key or a ⌃-letter
/// falls through to the focused terminal — and no two rows share a chord. Both are pinned, in Rust
/// by this module's tests and in Swift by `TreeCommandRoutingTests` over the assembled face. The
/// one exemption is the ⇧-prefixed NAMED keys (⇧`PageUp` / ⇧`Home` / ⇧`End`), which cannot steal a
/// printable terminal letter.
///
/// The `Mac` entries are the same features the palette's are, in this table's spelling: an
/// own-window satellite, a window level, the `AppKit` secure-input call and the window close.
/// Everything else is `Both`, including rows a phone reaches through a gesture rather than a chord
/// — docs/56 §3 is explicit that layout diverges and capability does not, and a row here is a
/// CAPABILITY even when the phone has no keyboard attached to fire it.
pub const ROWS: [Binding; 77] = [
    // ── Panes ──────────────────────────────────────────────────────────────────────────────────
    row(
        "pane.splitRight",
        Action::SplitRight,
        "Split Right",
        Category::Panes,
        ch('d', COMMAND),
        "rectangle.split.2x1",
        Some("split column side vertical divider new pane"),
        Platform::Both,
    ),
    row(
        "pane.splitDown",
        Action::SplitDown,
        "Split Down",
        Category::Panes,
        ch('d', COMMAND | SHIFT),
        "rectangle.split.1x2",
        Some("split row stacked horizontal divider new pane below"),
        Platform::Both,
    ),
    // Split-left / split-up: ⌥+ the ⌘D / ⌘⇧D split chords, inserting the new pane on the LEADING side
    // (left of a horizontal split / above a vertical one) and focusing it. ⌘⌥D / ⌘⌥⇧D are FREE (⌥ is
    // in no other `d` chord; ⌘D right, ⌘⇧D down).
    row(
        "pane.splitLeft",
        Action::SplitLeft,
        "Split Left",
        Category::Panes,
        ch('d', COMMAND | OPTION),
        "rectangle.split.2x1",
        Some("split column side vertical divider new pane left leading"),
        Platform::Both,
    ),
    row(
        "pane.splitUp",
        Action::SplitUp,
        "Split Up",
        Category::Panes,
        ch('d', COMMAND | OPTION | SHIFT),
        "rectangle.split.1x2",
        Some("split row stacked horizontal divider new pane above leading"),
        Platform::Both,
    ),
    row(
        "pane.close",
        Action::ClosePane,
        "Close Pane",
        Category::Panes,
        ch('w', COMMAND),
        "xmark",
        Some("quit kill end terminate remove"),
        Platform::Both,
    ),
    // Rename has NO default chord — title menu / context menu / palette only; `None` surfaces the row
    // without binding a key. Pinned chord-less by `E1KeymapParityTests`.
    row(
        "pane.rename",
        Action::RenamePane,
        "Rename Tab",
        Category::Panes,
        None,
        "pencil",
        Some("title label name tab"),
        Platform::Both,
    ),
    row(
        "pane.breakToTab",
        Action::BreakPaneToTab,
        "Break Pane to Tab",
        Category::Panes,
        ch('t', CONTROL | COMMAND),
        "rectangle.portrait.and.arrow.right",
        Some("eject move detach pop out promote"),
        Platform::Both,
    ),
    // The satellite pair — `action.detachPane` / `action.reattachAllPanes` in the palette's spelling.
    // `pane.detach` pops the active pane into its own `NSWindow` on ⌥⌘P ("Pop out"); `p` is in no
    // other ⌘ chord (⌘⇧P is the palette; modifiers differ). The session / PTY / stream survives, and
    // closing the satellite window reattaches. A shell with no such window would strand the pane out
    // of every tab with nothing rendering it, which is why its ROUTING arm was a macOS-only `#if`
    // with an empty else and its chord was taken from the PTY for nothing. `pane.reattachAll` is the
    // same feature read backwards — on a shell that cannot detach, the set it folds back is always
    // empty — and is chord-less because each satellite's close button reattaches just itself.
    row(
        "pane.detach",
        Action::DetachPane,
        "Detach Pane into Window",
        Category::Panes,
        ch('p', OPTION | COMMAND),
        "macwindow.on.rectangle",
        Some("detach pop out float window satellite separate monitor"),
        Platform::Mac,
    ),
    row(
        "pane.reattachAll",
        Action::ReattachAllPanes,
        "Reattach All Panes",
        Category::Panes,
        None,
        "macwindow.and.cursorarrow",
        Some("reattach dock fold return window satellite"),
        Platform::Mac,
    ),
    // Move pane (Zellij "move pane" — swap with the geometric neighbour). ⌥⌘⇧+arrows: the ⌥ modifier
    // (vs ⌃) keeps them distinct from focus (⌃⌘arrows) and the ⌃⌘⇧arrow divider chords below, so a
    // move never collides with a focus move or a divider nudge.
    row(
        "pane.moveLeft",
        Action::MovePaneLeft,
        "Move Pane Left",
        Category::Panes,
        key(NamedKey::LeftArrow, OPTION | COMMAND | SHIFT),
        "arrow.left.square",
        Some("swap reorder shift pane left"),
        Platform::Both,
    ),
    row(
        "pane.moveRight",
        Action::MovePaneRight,
        "Move Pane Right",
        Category::Panes,
        key(NamedKey::RightArrow, OPTION | COMMAND | SHIFT),
        "arrow.right.square",
        Some("swap reorder shift pane right"),
        Platform::Both,
    ),
    row(
        "pane.moveUp",
        Action::MovePaneUp,
        "Move Pane Up",
        Category::Panes,
        key(NamedKey::UpArrow, OPTION | COMMAND | SHIFT),
        "arrow.up.square",
        Some("swap reorder shift pane up"),
        Platform::Both,
    ),
    row(
        "pane.moveDown",
        Action::MovePaneDown,
        "Move Pane Down",
        Category::Panes,
        key(NamedKey::DownArrow, OPTION | COMMAND | SHIFT),
        "arrow.down.square",
        Some("swap reorder shift pane down"),
        Platform::Both,
    ),
    // Move divider (keyboard divider nudge). "Move divider up/down/left/right" = ⌃⌘⇧arrows
    // (spec/reference__keybindings.md:86-89, customization__custom-keybindings.md:78-81) — distinct
    // from focus (⌃⌘arrows). Grows the active pane toward the arrow (right/down) or shrinks it.
    row(
        "pane.resizeLeft",
        Action::ResizePaneLeft,
        "Move Divider Left",
        Category::Panes,
        key(NamedKey::LeftArrow, CONTROL | COMMAND | SHIFT),
        "arrow.left.and.line.vertical.and.arrow.right",
        Some("resize shrink narrower width divider move"),
        Platform::Both,
    ),
    row(
        "pane.resizeRight",
        Action::ResizePaneRight,
        "Move Divider Right",
        Category::Panes,
        key(NamedKey::RightArrow, CONTROL | COMMAND | SHIFT),
        "arrow.right.and.line.vertical.and.arrow.left",
        Some("resize grow wider width divider move"),
        Platform::Both,
    ),
    row(
        "pane.resizeUp",
        Action::ResizePaneUp,
        "Move Divider Up",
        Category::Panes,
        key(NamedKey::UpArrow, CONTROL | COMMAND | SHIFT),
        "arrow.up.and.line.horizontal.and.arrow.down",
        Some("resize shrink shorter height divider move"),
        Platform::Both,
    ),
    row(
        "pane.resizeDown",
        Action::ResizePaneDown,
        "Move Divider Down",
        Category::Panes,
        key(NamedKey::DownArrow, CONTROL | COMMAND | SHIFT),
        "arrow.down.and.line.horizontal.and.arrow.up",
        Some("resize grow taller height divider move"),
        Platform::Both,
    ),
    // Balance (tmux even-layout): reset the active tab's split weights to equal. ⌃⌘= is otherwise
    // unbound.
    row(
        "pane.balance",
        Action::BalancePanes,
        "Balance Panes",
        Category::Panes,
        ch('=', CONTROL | COMMAND),
        "rectangle.split.2x2",
        Some("even equal distribute reset layout balance tile"),
        Platform::Both,
    ),
    // Layouts (tmux/zellij select-layout): ⌃⌘L cycles the algorithmic re-tile presets
    // (even-horizontal/vertical, main-vertical/horizontal, tiled). Parallels ⌃⌘= Balance
    // ("L = Layout"); ⌃⌘L is otherwise unbound (`l` in NO other chord). This binding fires ONLY via
    // its menu item (no NSEvent monitor — same as sync-input), so the Pane menu's "Layouts ▸ Cycle
    // Layout" item is what dispatches ⌃⌘L. The five NAMED presets are menu/palette only
    // (`Action::ApplyLayout`, no chord and no row).
    row(
        "pane.cycleLayout",
        Action::CycleLayout,
        "Cycle Layout",
        Category::Panes,
        ch('l', CONTROL | COMMAND),
        "rectangle.3.group",
        Some("layout retile arrange tile even main select-layout cycle zellij tmux"),
        Platform::Both,
    ),
    // ── Tabs ───────────────────────────────────────────────────────────────────────────────────
    row(
        "tab.new",
        Action::NewTab,
        "New Tab",
        Category::Tabs,
        ch('t', COMMAND),
        "plus.rectangle.on.rectangle",
        Some("add open create tab"),
        Platform::Both,
    ),
    // REMOTE DESKTOP (⌥⌘N): the dedicated desktop WINDOW — reveal-or-mint, never a tab
    // (docs/DECISIONS.md 2026-07-22). ⌥⌘N is FREE (`n` appears in no other live chord) and echoes the
    // dead canvas table's "⌥⌘N = new remote pane" precedent. The id + action keep their historical
    // names (keybinding schemas persist them).
    row(
        "tab.newDesktop",
        Action::NewDesktopTab,
        "Remote Desktop",
        Category::Tabs,
        ch('n', COMMAND | OPTION),
        "display",
        Some("desktop display screen full remote stream monitor window"),
        Platform::Both,
    ),
    // Tab cycling lives on ⌘⇧]/⌘⇧[ (see DECISIONS), NOT plain ⌘]/⌘[ — those drive sequential PANE
    // cycling instead (`focus.cycleNext`/`focus.cyclePrev`), per the reference table; the Muxy tab
    // parity on bare ⌘]/⌘[ is intentionally not followed here. Pinned by `E1KeymapParityTests`.
    row(
        "tab.next",
        Action::NextTab,
        "Next Tab",
        Category::Tabs,
        ch(']', COMMAND | SHIFT),
        "arrow.forward.square",
        Some("cycle forward switch tab next"),
        Platform::Both,
    ),
    row(
        "tab.prev",
        Action::PrevTab,
        "Previous Tab",
        Category::Tabs,
        ch('[', COMMAND | SHIFT),
        "arrow.backward.square",
        Some("cycle back previous switch tab"),
        Platform::Both,
    ),
    // The ⌃⇥ switcher. Chord-less — the ⌃⇥ gesture is RESPONDER-owned on both platforms
    // (`WorkspaceKeyDispatcher.consumePaneSwitcher` on macOS, `TerminalInputHost.takesPaneSwitcherKey`
    // on iOS), and registering ⌃⇥ here would both misdescribe it (one row cannot mean
    // open/step/commit, and the walk's Esc / Return / arrows have no row at all) and put a ⌃-only
    // chord in a table whose §5 invariant is "every chord carries ⌘ or ⌥". A row would also cost the
    // `unbind: ctrl+tab` escape hatch its meaning: that unbind hands the GESTURE back, which only
    // works while the gesture is the thing above the table rather than a row inside it. The glyph
    // rides the keywords instead — the established idiom for a chord-less row whose key is worth
    // advertising (cf. `view.viKeyHints` carrying ⌘/). This row exists so the switcher is
    // DISCOVERABLE and openable without a keyboard.
    row(
        "pane.switcher",
        Action::PaneSwitcher,
        "Pane Switcher",
        Category::Panes,
        None,
        "square.stack",
        Some("⌃⇥ ctrl tab pane switcher recent recently used mru last previous quick switch alt-tab"),
        Platform::Both,
    ),
    // Close Tab has NO default chord (see DECISIONS): ⌘⇧W is Close WINDOW and ⌘W already cascades
    // pane → tab → window, so a dedicated Close-Tab chord is unnecessary. Chord-less keeps the row in
    // the palette / menu; tab close stays reachable via the ⌘W cascade.
    row(
        "tab.close",
        Action::CloseTab,
        "Close Tab",
        Category::Tabs,
        None,
        "xmark.rectangle",
        Some("close end terminate tab all panes"),
        Platform::Both,
    ),
    // Close Window ⌘⇧W — the reference default (spec/user-interface__window-tab-split.md:99/103/104).
    // A window maps to a slopdesk `Session` (DECISIONS.md), so routing to `requestCloseWindow()` parks
    // the close behind the `closeConfirmWindow` policy / busy-shell guard. Close Tab (above) is
    // deliberately left chord-less so ⌘⇧W stays collision-free for this binding. Its routing arm is
    // not an empty closure but a FALLBACK: `requestCloseWindow()` parks `pendingWindowClose` for the
    // Mac's `windowShouldClose` gate to resolve, and the phone's close-confirmation alert reads the
    // pane and tab parks only — so on that half the chord either parked a flag nothing observes or
    // cleared it and returned. Dropping the row hands ⌘⇧W back to the pane.
    row(
        "window.close",
        Action::CloseWindow,
        "Close Window",
        Category::Tabs,
        ch('w', COMMAND | SHIFT),
        "macwindow.badge.minus",
        Some("close window session end terminate all tabs quit"),
        Platform::Mac,
    ),
    // Reopen the most recently closed pane (the browser "reopen tab" idiom, beside ⌘T new / ⌘⇧W
    // close). ⌘⇧T is FREE on the tree shell (the only other `t` chords are ⌘T new tab + ⌃⌘T
    // break-pane). The route runs `reopenLastClosedPane()`, which stages intent 20 with LIFO index 0 —
    // a pinned wire op with a golden vector — and Open Quickly addresses the same stack by index.
    row(
        "tab.reopenClosed",
        Action::ReopenClosed,
        "Reopen Closed Pane",
        Category::Tabs,
        ch('t', COMMAND | SHIFT),
        "arrow.uturn.backward",
        Some("reopen restore undo closed pane tab last recently"),
        Platform::Both,
    ),
    row(
        "tab.syncInput",
        Action::ToggleSyncInput,
        "Sync Input to All Panes",
        Category::Tabs,
        ch('i', COMMAND | SHIFT),
        "keyboard.badge.ellipsis",
        Some("sync broadcast input panes tab synchronize mirror zellij"),
        Platform::Both,
    ),
    // Supervision: jump to the oldest pane needing attention (needsPermission first, then done) — a
    // global action across all tabs/sessions, so it lives in the Tabs group beside sync-input. ⌘⇧U is
    // FREE (no other binding uses `u`).
    row(
        "view.jumpToAttention",
        Action::JumpToAttention,
        "Jump to Pane Needing Attention",
        Category::Tabs,
        ch('u', COMMAND | SHIFT),
        "bell.badge",
        Some("jump unread attention needs permission blocked done next pane supervise oldest"),
        Platform::Both,
    ),
    // Supervision: ⌘⌥J opens the Peek & Reply overlay over the oldest pane needing attention so the
    // human can ANSWER a blocked agent INLINE — no full tab/context switch. Partner of ⌘⇧U (jump TO
    // the pane): "J" = jump-in-and-reply, kept on `j`. Bound to ⌘⌥J, not ⌘⇧J, because Hint Mode owns
    // ⌘⇧J for Hint to Open (`view.hintOpen`); ⌘⌥J is free. Menu/palette-surfaced, so there is no
    // muscle-memory cost to this choice (DECISIONS.md). This chord fires ONLY via its menu item, so
    // the Pane menu carries the matching "Peek & Reply" item.
    row(
        "view.peekReply",
        Action::PeekAndReply,
        "Peek & Reply to Blocked Pane",
        Category::Tabs,
        ch('j', COMMAND | OPTION),
        "bubble.left.and.text.bubble.right",
        Some("peek reply answer respond blocked needs permission inline quick supervise prompt"),
        Platform::Both,
    ),
    // ── Focus ──────────────────────────────────────────────────────────────────────────────────
    // Focus pane up/down/left/right — the documented default ⌃⌘arrows
    // (spec/reference__keybindings.md:82-85, customization__custom-keybindings.md:74-77). The single
    // most load-bearing pane-navigation chord set; the divider-move family sits on ⌃⌘⇧arrows above.
    row(
        "focus.left",
        Action::FocusLeft,
        "Focus Left",
        Category::Focus,
        key(NamedKey::LeftArrow, CONTROL | COMMAND),
        "arrow.left",
        Some("move navigate pane"),
        Platform::Both,
    ),
    row(
        "focus.right",
        Action::FocusRight,
        "Focus Right",
        Category::Focus,
        key(NamedKey::RightArrow, CONTROL | COMMAND),
        "arrow.right",
        Some("move navigate pane"),
        Platform::Both,
    ),
    row(
        "focus.up",
        Action::FocusUp,
        "Focus Up",
        Category::Focus,
        key(NamedKey::UpArrow, CONTROL | COMMAND),
        "arrow.up",
        Some("move navigate pane"),
        Platform::Both,
    ),
    row(
        "focus.down",
        Action::FocusDown,
        "Focus Down",
        Category::Focus,
        key(NamedKey::DownArrow, CONTROL | COMMAND),
        "arrow.down",
        Some("move navigate pane"),
        Platform::Both,
    ),
    // Sequential pane cycle: ⌘]/⌘[ step focus through the active tab's panes in DFS order (wrapping).
    // These chords were FREED from tab cycling, which moved to ⌘⇧]/⌘⇧[ (see the `tab.next` re-point +
    // DECISIONS). Distinct from ⌃⌘]/⌃⌘[ (block jump) and ⌘⇧]/⌘⇧[ (tab cycle).
    row(
        "focus.cycleNext",
        Action::CyclePaneNext,
        "Cycle to Next Pane",
        Category::Focus,
        ch(']', COMMAND),
        "arrow.forward",
        Some("cycle next pane focus sequential rotate"),
        Platform::Both,
    ),
    row(
        "focus.cyclePrev",
        Action::CyclePanePrev,
        "Cycle to Previous Pane",
        Category::Focus,
        ch('[', COMMAND),
        "arrow.backward",
        Some("cycle previous pane focus sequential rotate back"),
        Platform::Both,
    ),
    // ── View ───────────────────────────────────────────────────────────────────────────────────
    // Zoom / unzoom split — the documented default ⌘⇧↩ (spec/reference__keybindings.md:78,
    // customization__custom-keybindings.md:70). Toggles a single pane to fill the tab.
    row(
        "view.zoom",
        Action::ToggleZoom,
        "Maximize Pane",
        Category::View,
        key(NamedKey::Return, COMMAND | SHIFT),
        "arrow.up.left.and.arrow.down.right",
        Some("fullscreen full screen zoom expand enlarge"),
        Platform::Both,
    ),
    // Command Palette ⌘⇧P — the documented default (spec/reference__keybindings.md:42,
    // spec/user-interface__command-palette.md:5/9/35 "Opened with ⌘⇧P from anywhere"). ⌘⇧P is FREE
    // (no other `p` chord). Pinned by `E1KeymapParityTests`; the reassignment history is in DECISIONS.
    row(
        "view.palette",
        Action::CommandPalette,
        "Command Palette",
        Category::View,
        ch('p', COMMAND | SHIFT),
        "command",
        Some("search run quickly open actions"),
        Platform::Both,
    ),
    row(
        "view.cheatSheet",
        Action::CheatSheet,
        "Keyboard Shortcuts",
        Category::View,
        ch('/', COMMAND),
        "keyboard",
        Some("shortcuts cheat sheet help keys reference"),
        Platform::Both,
    ),
    row(
        "view.find",
        Action::Find,
        "Find…",
        Category::View,
        ch('f', COMMAND),
        "magnifyingglass",
        Some("search scrollback grep locate text in terminal"),
        Platform::Both,
    ),
    // Find Next / Previous: ⌘G advances, ⇧⌘G steps back through the active pane's find matches — and
    // OPENS the find bar when it is closed (faithful "find next opens find"). ⌘G / ⇧⌘G are FREE (`g`
    // appears in NO other chord).
    row(
        "view.findNext",
        Action::FindNext,
        "Find Next",
        Category::View,
        ch('g', COMMAND),
        "chevron.down",
        Some("next find search again forward match"),
        Platform::Both,
    ),
    row(
        "view.findPrev",
        Action::FindPrev,
        "Find Previous",
        Category::View,
        ch('g', COMMAND | SHIFT),
        "chevron.up",
        Some("previous find search back backward match"),
        Platform::Both,
    ),
    // Global Search: ⇧⌘F searches every tab's scrollback and shows a grouped results surface.
    row(
        "view.globalSearch",
        Action::GlobalSearch,
        "Global Search…",
        Category::View,
        ch('f', COMMAND | SHIFT),
        "magnifyingglass.circle",
        Some("global search all tabs scrollback grep cross pane find"),
        Platform::Both,
    ),
    // Vi Mode: modal keyboard scrollback navigation ("Vi Mode" / tmux-zellij copy-mode). The
    // documented entry chord is ⌃⇧Space; slopdesk's canonical DISPLAY chord stays the pre-existing
    // ⌘⇧C (muscle memory / menu glyph unchanged), with ⌃⇧Space folded in as a SECOND resolving chord
    // via [`ALIASES`] (no extra display row — the ⌘+ font-increase idiom). Title "Vi Mode", "copy
    // mode" kept in keywords so palette search for the old name still finds it. ⌘⇧C is FREE (`c` in NO
    // other binding) and does not collide with the system plain ⌘C copy (different modifier set,
    // handled by the terminal's own copy responder).
    row(
        "view.copyMode",
        Action::ToggleCopyMode,
        "Vi Mode",
        Category::View,
        ch('c', COMMAND | SHIFT),
        "doc.on.clipboard",
        Some(
            "vi mode copy mode scrollback keyboard navigate select yank visual control shift space tmux \
             zellij",
        ),
        Platform::Both,
    ),
    // Vi Mode Key Hints: the `⌘/` reference-card toggle, surfaced as a DISCOVERABLE palette / menu
    // command (not only the contextual `⌘/` firing in vi mode). Chord-less — the live `⌘/` is
    // `view.cheatSheet`'s (double duty: cheat sheet normally, this hint bar in vi mode), so a second
    // registered chord would collide. Toggles the active pane's hint bar (no-op outside vi mode, where
    // the bar is gated off). The glyph `⌘/` is in the keywords for discovery.
    row(
        "view.viKeyHints",
        Action::ToggleViKeyHints,
        "Vi Mode Key Hints",
        Category::View,
        None,
        "keyboard.badge.eye",
        Some("vi mode key hints reference card cheat shortcuts copy mode command slash toggle bar"),
        Platform::Both,
    ),
    // Read-Only mode: toggle the active pane's input gate. No default chord — reachable via the View
    // menu (the app ships no Shell menu) + the command palette ("Read Only", also `readonly` / `lock`
    // / `freeze` / `view only` — the spec's accepted terms). Chord-less surfaces the row WITHOUT
    // binding a key; the user may bind it in Settings → Keybindings.
    row(
        "view.readOnly",
        Action::ToggleReadOnly,
        "Read Only",
        Category::View,
        None,
        "lock",
        Some("read only readonly lock freeze view only locked viewer input gate protect"),
        Platform::Both,
    ),
    // Secure Keyboard Entry: the MANUAL toggle for macOS process-global secure event input over the
    // active pane (the AUTO path engages on a host no-echo password prompt; this is the explicit
    // override). `EnableSecureEventInput` is `AppKit`'s and process-global;
    // `TerminalViewModel.refreshSecureInput()` is `let value = false` off macOS, so on a phone this
    // flipped a flag whose only listener is a `nil` closure and left the SECURE INPUT pill dark. The
    // row is chord-LESS, so what it cost the phone was not a key: it was a cheat-sheet line and a
    // keybindings editor offering to bind a chord onto it.
    row(
        "view.secureKeyboardEntry",
        Action::SecureKeyboardEntry,
        "Secure Keyboard Entry",
        Category::View,
        None,
        "lock.shield",
        Some("secure input keyboard entry password sudo protect eavesdrop sniff secure event input"),
        Platform::Mac,
    ),
    // Release Stuck Input: the remote-GUI escape hatch — synthesize key-up for ALL modifiers +
    // mouse-up for all buttons on the active video pane when the host is left holding input (every
    // release datagram of the loss-resilient burst lost). Chord-less; palette/menu, bindable in
    // Settings → Keybindings. A no-op for a non-video / read-only / not-streaming active pane.
    row(
        "view.releaseStuckInput",
        Action::ReleaseStuckInput,
        "Release Stuck Input",
        Category::View,
        None,
        "keyboard.badge.ellipsis",
        Some(
            "release stuck input modifier key mouse button unstick reset keyboard command shift remote \
             window video",
        ),
        Platform::Both,
    ),
    // Lock Viewport Position: ⌥⌘L freezes the active remote-GUI pane's edge-hover auto-pan (the
    // viewport stays put as the pointer nudges the pane edges — e.g. reaching for a control that sits
    // near an edge of an overflowing window). ⌥⌘L is FREE (`l` is otherwise only ⌘⇧L Toggle Tabs Panel
    // + ⌃⌘L Cycle Layout — different modifier sets) and ⌘-prefixed (§5). Mirrors the footer lock
    // button 1:1 (both flip `RemoteWindowModel.viewportLocked`). A graceful no-op off a streaming
    // video pane. A pure client compositor gate — it never touches the host.
    row(
        "view.lockViewport",
        Action::ToggleViewportLock,
        "Lock Viewport Position",
        Category::View,
        ch('l', COMMAND | OPTION),
        "lock.rectangle",
        Some("lock viewport position freeze edge pan auto pan hold pin content remote window video unlock"),
        Platform::Both,
    ),
    // Fit Viewport to Pane / Actual Size: discoverability twins of the footer [fit]/[1×] buttons —
    // reachable ONLY via that small control-bar icon cluster before this (docs audit finding #37).
    // Chord-less; bindable in Settings → Keybindings. A graceful no-op off a streaming video pane, or
    // while the viewport is LOCKED (mirrors the footer buttons' own disabled-while-locked gate).
    row(
        "view.fitViewportToPane",
        Action::FitViewportToPane,
        "Fit to Pane",
        Category::View,
        None,
        "rectangle.arrowtriangle.2.inward",
        Some("fit window pane zoom shrink grow whole visible remote video"),
        Platform::Both,
    ),
    row(
        "view.resetViewportZoom",
        Action::ResetViewportZoom,
        "Actual Size",
        Category::View,
        None,
        "1.magnifyingglass",
        Some("actual size reset zoom 1x one to one native remote video"),
        Platform::Both,
    ),
    // Paste as Keystrokes: ⌥⌘V types the LOCAL clipboard into the active remote-GUI pane's host
    // window as paced per-key CGEvents — the path that reaches a sudo / SecurityAgent secure field,
    // since a plain ⌘V forwards a raw Cmd+V that pastes the HOST clipboard. ⌥⌘V is FREE (`v` in NO
    // other chord — plain ⌘V / ⌘⇧V never enter the registry, they belong to the terminal's paste
    // responder) and ⌘-prefixed (§5) so it is intercepted before a focused terminal. A no-op for a
    // terminal (own paste pipeline) / empty / read-only pane.
    row(
        "view.pasteAsKeystrokes",
        Action::PasteAsKeystrokes,
        "Paste as Keystrokes",
        Category::View,
        ch('v', COMMAND | OPTION),
        "keyboard",
        Some(
            "paste keystrokes type clipboard local password sudo securityagent remote window video field \
             secure",
        ),
        Platform::Both,
    ),
    // Toggle Tabs Panel ⌘⇧L — the reference default (spec/reference__keybindings.md:66; line 201
    // "⌘⇧L … map to sidebar … toggles"). Deliberately NOT ⌘B: that chord only reaches
    // `store.toggleSidebarCollapsed()`, a flag the native split shell never reads (macOS collapse is
    // driven by `WorkspaceChromeState.sidebarCollapsed`) — binding ⌘B here would be a dead chord. ⌘⇧L
    // routes through a `toggleSidebar` shell closure onto the live chrome flag; the titlebar's own
    // toggle button actuates that SAME closure rather than binding ⌘⇧L a second time (single owner).
    // ⌘⇧L is FREE (no other `l` chord; ⌃⌘L is Cycle Layout). Pinned by `E1KeymapParityTests`.
    row(
        "view.toggleSidebar",
        Action::ToggleSidebar,
        "Toggle Tabs Panel",
        Category::View,
        ch('l', COMMAND | SHIFT),
        "sidebar.left",
        Some("sidebar sessions tabs panel rail hide show collapse"),
        Platform::Both,
    ),
    // Toggle Code Panel ⌘⇧R — the RIGHT sidebar (project-scoped embedded VS Code, a code-server
    // WKWebView; all panes of one project share the one instance at that project's root). ⌘⇧R mirrors
    // ⌘⇧L (the two panels flank the content column). ⌘⇧R is FREE: the historical "reserved for Toggle
    // Details" claim died with the Details column, and no other `r` chord is registered. Routed
    // through a `toggleCodeSidebar` view-closure onto the live `WorkspaceChromeState
    // .codeSidebarCollapsed` (like the left panel — there is no store flag to fall back to). iOS HAS
    // the code panel: `WorkspaceRootViewController` mounts the same `CodePanelSurfaces` full-screen. A
    // sidebar on the Mac, a cover on the phone, is the layout difference the split exists for; the
    // capability is on both. Pinned by `E1KeymapParityTests`.
    row(
        "view.toggleCodeSidebar",
        Action::ToggleCodeSidebar,
        "Toggle Code Panel",
        Category::View,
        ch('r', COMMAND | SHIFT),
        "chevron.left.forwardslash.chevron.right",
        Some("code panel vscode editor ide right sidebar hide show collapse code-server"),
        Platform::Both,
    ),
    // Switch Editor / Terminal Focus ⌥⌘R — the keyboard's way INTO the embedded editor and back out
    // (⌘⇧R only shows/hides the panel). It reads as one gesture in both directions, which is why the
    // title names the switch rather than one end of it. ⌥⌘R is FREE: `r` carries ⌘⇧R (this panel's
    // toggle) and ⌃⌘R (Re-run Last Command) only. `Focus` category — it moves the keyboard, exactly
    // like the ⌃⌘arrow family. Until this existed the editor could only be reached by CLICKING it: the
    // panel's focus policy refuses every claim that is not a mouse-down inside the webview, which is
    // what keeps VS Code's own aggressive autofocus from stealing the keyboard mid-keystroke. A chord
    // is app-directed, not page-directed, so it rides the same explicitly-armed path the pool's
    // warm-swap restore uses and leaves that guarantee intact. Inside the editor ⌃` and ⌘` reach the
    // same action without appearing in this table — see `WorkspaceKeyDispatcher.codePanelLocalAction`.
    row(
        "focus.codePanel",
        Action::FocusCodePanel,
        "Switch Editor / Terminal Focus",
        Category::Focus,
        ch('r', COMMAND | OPTION),
        "keyboard",
        Some("focus code panel editor vscode keyboard type into back terminal switch"),
        Platform::Both,
    ),
    // Pin Window ("View ▸ Pin Window" — `spec/user-interface__window-tab-split.md:14` "keeps the
    // window floating above all other apps' windows"). Chord-less; bindable in Settings →
    // Keybindings. The live macOS app flips `WorkspaceChromeState.pinned` → `NSWindow.level =
    // .floating`. A phone has one window and no z-order among apps, so the routing closure no phone
    // root binds stays nil and the row stays off the phone's list rather than answering a chord with
    // nothing.
    row(
        "view.pinWindow",
        Action::PinWindow,
        "Pin Window",
        Category::View,
        None,
        "pin",
        Some("pin window float floating always on top above keep front level stay topmost pip"),
        Platform::Mac,
    ),
    // Blocks: the Command Navigator toggle + jump-to-block prev/next. ⌃⌘O / ⌃⌘[ / ⌃⌘] are all
    // ⌘-prefixed (the §5 conflict rule) and collision-free against the rest of the table (tab cycling
    // is ⌘[/], focus is ⌃⌘arrows — neither uses ⌃⌘bracket). They target the active terminal pane.
    row(
        "view.commandNavigator",
        Action::CommandNavigator,
        "Command Navigator",
        Category::View,
        ch('o', CONTROL | COMMAND),
        "list.bullet.rectangle",
        Some("blocks commands history recent navigator output jump warp"),
        Platform::Both,
    ),
    // Jump-To (`user-interface__outline.md`): ⌘J opens the floating Jump-To panel over the active pane
    // — detected paths/URLs over scrollback + its OSC-133 command/prompt index, fuzzy-filterable, ↩
    // acts / ⌘K opens the per-row actions popover. ⌘J is FREE (`j` is otherwise only ⌘⇧J hint-open /
    // ⌘⌥J peek-reply). A VIEW overlay (OverlayCoordinator), routed via a passed-in toggle closure like
    // Global Search.
    row(
        "view.jumpTo",
        Action::JumpTo,
        "Jump To…",
        Category::View,
        ch('j', COMMAND),
        "scope",
        Some("jump to outline quick switch goto navigate command url path link prompt current"),
        Platform::Both,
    ),
    // Hint Mode (`terminal-features__hint-mode`): overlay 2-letter Vimium labels on every detected
    // target in the active pane's viewport; type the label to run the action — no mouse. ⌘⇧J Open +
    // ⌘⇧Y Copy are the documented defaults — ⌘⇧J is free for Hint Mode to own because `.peekAndReply`
    // is bound to ⌘⌥J instead (see `view.peekReply`); `y` is in NO other chord. Hint to Reveal is
    // CHORD-LESS (palette/menu + an in-overlay action switch while hint mode is up; bindable in
    // Settings). Each targets the active terminal pane (a no-op off-terminal).
    row(
        "view.hintOpen",
        Action::HintToOpen,
        "Hint to Open",
        Category::View,
        ch('j', COMMAND | SHIFT),
        "cursorarrow.rays",
        Some("hint mode open vimium label link path url file follow keyboard jump target"),
        Platform::Both,
    ),
    row(
        "view.hintCopy",
        Action::HintToCopy,
        "Hint to Copy",
        Category::View,
        ch('y', COMMAND | SHIFT),
        "doc.on.doc",
        Some("hint mode copy vimium label yank clipboard link path url text keyboard target"),
        Platform::Both,
    ),
    row(
        "view.hintReveal",
        Action::HintToReveal,
        "Hint to Reveal in Finder",
        Category::View,
        None,
        "folder",
        Some("hint mode reveal finder vimium label path file host keyboard target show"),
        Platform::Both,
    ),
    row(
        "view.jumpPreviousBlock",
        Action::JumpPreviousBlock,
        "Jump to Previous Block",
        Category::View,
        ch('[', CONTROL | COMMAND),
        "chevron.up.circle",
        Some("previous prompt block command back up jump scroll osc133"),
        Platform::Both,
    ),
    row(
        "view.jumpNextBlock",
        Action::JumpNextBlock,
        "Jump to Next Block",
        Category::View,
        ch(']', CONTROL | COMMAND),
        "chevron.down.circle",
        Some("next prompt block command forward down jump scroll osc133"),
        Platform::Both,
    ),
    // Re-run last command + jump-to-failed prev/next. ⌃⌘R / ⌃⌘⇧[ / ⌃⌘⇧] are all ⌘-prefixed (§5) and
    // collision-free: ⌃⌘R is otherwise unbound; ⌃⌘⇧[ / ⌃⌘⇧] add ⇧ to the block-jump chords, so they
    // are distinct from both ⌃⌘[ / ⌃⌘] (block jump) and ⌘[ / ⌘] (pane cycling).
    row(
        "view.reRunLastCommand",
        Action::ReRunLastCommand,
        "Re-run Last Command",
        Category::View,
        ch('r', CONTROL | COMMAND),
        "arrow.clockwise",
        Some("rerun repeat replay again last command block execute"),
        Platform::Both,
    ),
    row(
        "view.jumpPreviousFailed",
        Action::JumpPreviousFailed,
        "Jump to Previous Failed",
        Category::View,
        ch('[', CONTROL | COMMAND | SHIFT),
        "chevron.up.2",
        Some("previous failed error nonzero exit block jump back up"),
        Platform::Both,
    ),
    row(
        "view.jumpNextFailed",
        Action::JumpNextFailed,
        "Jump to Next Failed",
        Category::View,
        ch(']', CONTROL | COMMAND | SHIFT),
        "chevron.down.2",
        Some("next failed error nonzero exit block jump forward down"),
        Platform::Both,
    ),
    // Viewport scroll: the named-key chords ⇧PageUp/PageDown (page scroll) + ⇧Home/End (buffer ends).
    // These are the ONE exemption to the §5 "every chord ⌘/⌥-prefixed" rule — a ⇧-prefixed NAMED key
    // (PageUp/Home/End) cannot steal a printable terminal letter. Distinct from copy-mode's half-page
    // scroll. Target the active terminal pane.
    row(
        "view.scrollPageUp",
        Action::ScrollPageUp,
        "Scroll Page Up",
        Category::View,
        key(NamedKey::PageUp, SHIFT),
        "arrow.up.to.line",
        Some("scroll page up viewport scrollback older terminal"),
        Platform::Both,
    ),
    row(
        "view.scrollPageDown",
        Action::ScrollPageDown,
        "Scroll Page Down",
        Category::View,
        key(NamedKey::PageDown, SHIFT),
        "arrow.down.to.line",
        Some("scroll page down viewport scrollback newer terminal"),
        Platform::Both,
    ),
    row(
        "view.scrollTop",
        Action::ScrollToTop,
        "Scroll to Top",
        Category::View,
        key(NamedKey::Home, SHIFT),
        "arrow.up.to.line.compact",
        Some("scroll top buffer beginning start scrollback terminal"),
        Platform::Both,
    ),
    row(
        "view.scrollBottom",
        Action::ScrollToBottom,
        "Scroll to Bottom",
        Category::View,
        key(NamedKey::End, SHIFT),
        "arrow.down.to.line.compact",
        Some("scroll bottom buffer end newest scrollback terminal"),
        Platform::Both,
    ),
    // Command jumps: ⌘PageUp/PageDown jump the viewport to the previous / next shell prompt — they
    // REUSE the OSC-133 command-jump (`jumpToBlockInActivePane(∓1)`), NOT raw scroll.
    row(
        "view.cmdJumpPrev",
        Action::CommandJumpPrev,
        "Jump to Previous Command",
        Category::View,
        key(NamedKey::PageUp, COMMAND),
        "chevron.up.circle",
        Some("jump previous command prompt block osc133 up"),
        Platform::Both,
    ),
    row(
        "view.cmdJumpNext",
        Action::CommandJumpNext,
        "Jump to Next Command",
        Category::View,
        key(NamedKey::PageDown, COMMAND),
        "chevron.down.circle",
        Some("jump next command prompt block osc133 down"),
        Platform::Both,
    ),
    // Font size: ⌘= bumps, ⌘- shrinks, ⌘0 resets. ⌘0 is FREE (select-pane digits start at ⌘1). The `+`
    // glyph (⌘+) does NOT fold onto `=` for free — on a US/ANSI layout ⌘+ arrives as `+`+⇧ (or keypad
    // `+`), which `charactersIgnoringModifiers` keys as a DISTINCT chord — so [`ALIASES`] adds those
    // two spellings. A font-size step resizes the cell box, so FEWER/MORE cells fit and the remote PTY
    // grid REFLOWS (SIGWINCH) — NOT a glyph-only rescale. Target the active terminal pane.
    row(
        "view.fontIncrease",
        Action::IncreaseFontSize,
        "Increase Font Size",
        Category::View,
        ch('=', COMMAND),
        "textformat.size.larger",
        Some("font size increase bigger larger zoom in plus text"),
        Platform::Both,
    ),
    row(
        "view.fontDecrease",
        Action::DecreaseFontSize,
        "Decrease Font Size",
        Category::View,
        ch('-', COMMAND),
        "textformat.size.smaller",
        Some("font size decrease smaller minus text zoom out"),
        Platform::Both,
    ),
    row(
        "view.fontReset",
        Action::ResetFontSize,
        "Reset Font Size",
        Category::View,
        ch('0', COMMAND),
        "textformat.size",
        Some("font size reset default actual original zero text"),
        Platform::Both,
    ),
    // Open Quickly: ⌘⇧O fuzzy file/symbol switcher. ⌘⇧O is FREE (the only other `o` chord is ⌃⌘O
    // Command Navigator). A routable stub for now — never a dead chord.
    row(
        "view.openQuickly",
        Action::OpenQuickly,
        "Open Quickly…",
        Category::View,
        ch('o', COMMAND | SHIFT),
        "magnifyingglass.circle",
        Some("open quickly fuzzy file symbol switcher jump goto"),
        Platform::Both,
    ),
    // ── The collapsed ⌘1…⌘9 representative ─────────────────────────────────────────────────────
    // Display only — the nine real per-digit chords are `pane.select.1`…`pane.select.9`, minted from a
    // loop in Swift and undeclared here (a formula has no data to drift). `Action::SelectPane` with
    // `arg: 1` is a stand-in; the glyph range is hand-rendered into the TITLE because one chord cannot
    // represent a range, and no chord keeps the cheat sheet from drawing a single-chord hint chip.
    Binding {
        id: "pane.selectN",
        action: Action::SelectPane,
        arg: 1,
        title: "Select Pane (⌘1…⌘9)",
        category: Category::Panes,
        chord: None,
        symbol: "number.square",
        keywords: Some("switch jump pane tab number digit 1 2 3 4 5 6 7 8 9"),
        platform: Platform::Both,
        kind: Kind::Representative,
    },
];

/// A SECOND chord for an action that already has a display row.
///
/// An alias fires the action without minting a row, so the cheat sheet / palette / menu still show
/// the ONE canonical binding. Folded into the chord table the dispatcher resolves, but never into
/// the display set — the chord-uniqueness guard runs over the rows, and an alias is intentionally
/// outside it (it shares its ACTION, not its chord, with the canonical row).
///
/// The font-increase chord is canonically ⌘= (no ⇧), but the muscle-memory chord is the `+` glyph.
/// On a US/ANSI layout `+` IS Shift-`=`, and `charactersIgnoringModifiers` ignores ⌘/⌥/⌃ but NOT ⇧
/// — so pressing ⌘+ delivers `"+"` with ⇧ set, NOT ⌘=. Without this alias that chord is unbound and
/// ⌘+ leaks to the PTY (the font never grows). BOTH spellings the OS can deliver are aliased: the
/// shifted main-row `+` and the unshifted keypad `+`.
///
/// The documented Vi Mode entry chord is ⌃⇧Space, and `view.copyMode` DISPLAYS ⌘⇧C, so ⌃⇧Space is
/// folded in as a second resolving chord onto the same action. Space is the NAMED key (the macOS
/// normalizer maps keyCode 49 → `.space` only with a non-shift modifier, so a bare Space still
/// types); ⌃⇧Space is otherwise unbound.
pub const ALIASES: [(Chord, Action); 3] = [
    // ⌘+ = ⌘⇧= on a US/ANSI layout.
    (
        Chord {
            named: None,
            character: '+',
            modifiers: COMMAND | SHIFT,
        },
        Action::IncreaseFontSize,
    ),
    // Keypad +, which reports no ⇧.
    (
        Chord {
            named: None,
            character: '+',
            modifiers: COMMAND,
        },
        Action::IncreaseFontSize,
    ),
    // ⌃⇧Space — the documented Vi Mode entry, an alias of ⌘⇧C.
    (
        Chord {
            named: Some(NamedKey::Space),
            character: '\0',
            modifiers: CONTROL | SHIFT,
        },
        Action::ToggleCopyMode,
    ),
];

/// The row `id` is filed under, if this table declares one.
#[must_use]
fn row_at(id: &str) -> Option<Binding> {
    ROWS.iter().copied().find(|row| row.id == id)
}

/// Whether the half that identifies as `mac` lists `id` — and therefore binds its chord.
///
/// An id no row declares is SHOWN. Failing closed here would let a typo unbind a chord in silence,
/// which is a worse version of the defect this module exists to close; `rust/slopdesk-invariants`
/// is what makes an undeclared id impossible in the first place. The nine generated `pane.select.N`
/// ids take this path on purpose — they are `Both`, and a loop declares no row.
#[must_use]
pub fn shown(id: &str, mac: bool) -> bool {
    row_at(id).is_none_or(|row| row.platform.shown_on(mac))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::unwrap_used,
        clippy::indexing_slicing,
        clippy::panic,
        reason = "a panic in a test is the failure report, and every index here is into this module's own \
                  table"
    )]
    use super::{ALIASES, Action, Category, Chord, Kind, NamedKey, ROWS, SHIFT, row_at, shown};
    use crate::palette_rows;
    use crate::platform::Platform;

    #[test]
    fn every_id_is_declared_once_and_reads_as_a_registry_id() {
        let mut seen = std::collections::BTreeSet::new();
        for row in ROWS {
            assert!(seen.insert(row.id), "{} is declared twice", row.id);
            assert!(
                row.id
                    .split_once('.')
                    .is_some_and(|(noun, verb)| !noun.is_empty() && !verb.is_empty()),
                "{} is not a noun.verb registry id",
                row.id
            );
            assert!(
                !row.id.starts_with("action."),
                "{} is a PALETTE id — the two tables keep their own spellings",
                row.id
            );
        }
    }

    #[test]
    fn every_action_is_claimed_by_at_most_one_row_and_only_apply_layout_by_none() {
        let mut seen = std::collections::BTreeSet::new();
        for row in ROWS {
            assert!(
                seen.insert(row.action),
                "{:?} is claimed by two rows — `binding(for:)` would answer with whichever came first",
                row.action
            );
        }
        let unclaimed: Vec<Action> = Action::ALL.into_iter().filter(|a| !seen.contains(a)).collect();
        assert_eq!(
            unclaimed,
            vec![Action::ApplyLayout],
            "the five named layout presets are the ONE action with no row; anything else here is a verb \
             that reaches no surface",
        );
    }

    #[test]
    fn the_tag_and_the_position_are_the_same_number() {
        for (position, action) in Action::ALL.into_iter().enumerate() {
            let tag = u16::try_from(position).expect("78 actions fit a u16");
            assert_eq!(action.tag(), tag, "{action:?} is out of case order");
            assert_eq!(Action::from_tag(tag), Some(action));
        }
        assert_eq!(Action::from_tag(u16::try_from(Action::ALL.len()).unwrap()), None);
    }

    /// The §5 conflict rule: a chord that carries neither ⌘ nor ⌥ falls through to the focused
    /// terminal, so binding one steals a key the shell is typing into. The exemption is a
    /// ⇧-prefixed NAMED key, which has no printable letter to steal.
    #[test]
    fn every_chord_carries_command_or_option_unless_it_is_a_named_key() {
        for row in ROWS {
            let Some(chord) = row.chord else { continue };
            if chord.modifiers & (super::COMMAND | super::OPTION) != 0 {
                continue;
            }
            assert!(
                chord.named.is_some() && chord.modifiers == SHIFT,
                "{} binds {chord:?} with neither ⌘ nor ⌥ and is not a ⇧named-key",
                row.id,
            );
        }
    }

    #[test]
    fn no_two_rows_share_a_chord_and_no_alias_shadows_one() {
        let mut bound: std::collections::BTreeMap<(Option<i16>, char, u8), &str> =
            std::collections::BTreeMap::new();
        for row in ROWS {
            let Some(chord) = row.chord else { continue };
            let key = (chord.named.map(|n| n as i16), chord.character, chord.modifiers);
            if let Some(previous) = bound.insert(key, row.id) {
                panic!("{} and {previous} both bind {chord:?}", row.id);
            }
        }
        for (chord, action) in ALIASES {
            let key = (chord.named.map(|n| n as i16), chord.character, chord.modifiers);
            assert!(
                !bound.contains_key(&key),
                "the {action:?} alias {chord:?} shadows {}",
                bound[&key],
            );
        }
    }

    #[test]
    fn a_printable_chord_is_lower_case_and_a_named_one_carries_no_character() {
        for row in ROWS {
            let Some(chord) = row.chord else { continue };
            match chord.named {
                Some(_) => assert_eq!(chord.character, '\0', "{} names a key AND a character", row.id),
                None => {
                    assert!(
                        !chord.character.is_uppercase(),
                        "{} binds an upper-case character — ⇧ belongs in the modifiers",
                        row.id,
                    );
                },
            }
        }
    }

    #[test]
    fn exactly_one_row_is_the_collapsed_representative_and_it_is_last() {
        let representatives: Vec<&str> = ROWS
            .iter()
            .filter(|row| row.kind == Kind::Representative)
            .map(|row| row.id)
            .collect();
        assert_eq!(representatives, vec!["pane.selectN"]);
        assert_eq!(ROWS[ROWS.len() - 1].kind, Kind::Representative);
        assert!(
            ROWS[ROWS.len() - 1].chord.is_none(),
            "the collapsed row must draw no hint chip"
        );
    }

    #[test]
    fn every_row_carries_a_title_and_a_symbol() {
        for row in ROWS {
            assert!(!row.title.is_empty(), "{} has no title", row.id);
            assert!(!row.symbol.is_empty(), "{} has no SF Symbol", row.id);
            assert!(
                row.keywords.is_none_or(|words| !words.is_empty()),
                "{} carries empty keywords — say `None` instead",
                row.id,
            );
        }
    }

    #[test]
    fn only_the_rows_with_an_appkit_backing_are_the_macs_alone() {
        let mac: Vec<&str> = ROWS
            .iter()
            .filter(|row| row.platform == Platform::Mac)
            .map(|row| row.id)
            .collect();
        assert_eq!(mac, vec![
            "pane.detach",
            "pane.reattachAll",
            "window.close",
            "view.secureKeyboardEntry",
            "view.pinWindow"
        ]);
        assert!(
            !ROWS.iter().any(|row| row.platform == Platform::Phone),
            "no binding is the phone's alone — a smaller screen is not a smaller product",
        );
    }

    /// The two tables spell the same three verbs differently and must still WITHHOLD the same
    /// three. A verb hidden from the palette but bound to a chord (or the reverse) is the drift
    /// that having two id spaces invites, and this is the only place both are in scope at once.
    #[test]
    fn the_two_tables_withhold_the_same_feature() {
        for (binding, verb) in [
            ("pane.detach", "action.detachPane"),
            ("pane.reattachAll", "action.reattachAllPanes"),
            ("window.close", "action.closeWindow"),
            ("view.secureKeyboardEntry", "action.secureKeyboardEntry"),
            ("view.pinWindow", "action.pinWindow"),
        ] {
            for mac in [true, false] {
                assert_eq!(
                    shown(binding, mac),
                    palette_rows::shown(verb, mac),
                    "{binding} and {verb} are one feature and disagreed for mac={mac}",
                );
            }
        }
    }

    #[test]
    fn a_mac_row_is_hidden_only_from_the_phone() {
        assert!(shown("pane.detach", true));
        assert!(!shown("pane.detach", false));
        assert!(shown("pane.close", true) && shown("pane.close", false));
    }

    #[test]
    fn the_generated_select_pane_slots_are_shown_by_falling_open() {
        assert!(row_at("pane.select.4").is_none());
        assert!(shown("pane.select.4", false));
        assert!(shown("nobody.declaredThis", false));
    }

    /// The display order the cheat sheet groups by. Category order is panes → tabs → focus → view,
    /// and the rows inside each group keep table order, so the table IS the display.
    #[test]
    fn every_category_has_rows_and_the_representative_is_a_pane_row() {
        for category in [Category::Panes, Category::Tabs, Category::Focus, Category::View] {
            assert!(
                ROWS.iter().any(|row| row.category == category),
                "{category:?} would render as an empty cheat-sheet section",
            );
        }
        assert_eq!(
            ROWS.iter()
                .find(|row| row.kind == Kind::Representative)
                .map(|row| row.category),
            Some(Category::Panes),
        );
    }

    #[test]
    fn an_action_that_needs_no_pane_is_window_or_session_scope() {
        assert!(Action::SplitRight.requires_active_pane());
        assert!(
            Action::ApplyLayout.requires_active_pane(),
            "a preset re-tiles the active tab"
        );
        assert!(!Action::CommandPalette.requires_active_pane());
        assert!(
            !Action::SelectPane.requires_active_pane(),
            "a digit names a pane, it does not need one"
        );
        assert!(!Action::ReattachAllPanes.requires_active_pane());
    }

    #[test]
    fn the_aliases_target_actions_a_row_already_carries() {
        for (_, action) in ALIASES {
            assert!(
                ROWS.iter().any(|row| row.action == action),
                "{action:?} is aliased from a second chord but has no canonical row to display",
            );
        }
    }

    #[test]
    fn the_named_key_indices_are_the_swift_case_order() {
        // The eleven positions `KeyChord.Key.namedIndex` crosses as. A gap or a re-order here
        // silently rebinds every named-key chord on the other side.
        for (position, named) in [
            NamedKey::Return,
            NamedKey::Tab,
            NamedKey::Space,
            NamedKey::LeftArrow,
            NamedKey::RightArrow,
            NamedKey::UpArrow,
            NamedKey::DownArrow,
            NamedKey::PageUp,
            NamedKey::PageDown,
            NamedKey::Home,
            NamedKey::End,
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(
                named as i16,
                i16::try_from(position).unwrap(),
                "{named:?} is out of case order"
            );
        }
    }

    #[test]
    fn a_chord_is_copy_and_comparable_so_the_face_can_key_on_it() {
        let one = Chord {
            named: None,
            character: 'd',
            modifiers: super::COMMAND,
        };
        let two = one;
        assert_eq!(one, two);
    }
}
