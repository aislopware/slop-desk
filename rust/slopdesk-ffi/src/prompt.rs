//! The editor-like command prompt: one handle over [`slopdesk_terminal::prompt::CommandEditor`].
//!
//! `docs/68` §5.4 asks for a prompt that behaves like an editor rather than like a line —
//! multi-line documents, selections, undo, syntax colour, history recall, the ⌃R panel and
//! completion. All of that is decided in Rust and has been since the module landed; this file is
//! the door, and it is the FIRST caller. Nothing here holds a rule of its own.
//!
//! ## Why one handle and not a family
//! The editor's own header says it: "Typing has to abandon a history walk, dismiss the completion
//! list AND coalesce into the undo step; a caller wiring those four together itself would get one
//! of them wrong per platform." Exporting the buffer, the undo stack, the history and the
//! completion list as four handles would put exactly that wiring on the far side, in two languages.
//! They cross as one interior.
//!
//! ## Why the derived answers are rebuilt per call, not parked
//! [`slopdesk_prompt_spans`], [`slopdesk_prompt_candidates`] and their arenas are pure functions of
//! the editor's current state, so each one recomputes rather than reading a slot. That is what
//! makes the `(out, cap)` retry of `docs/55` §4 safe here: a caller that lent too small a buffer
//! calls again over an editor nobody moved and gets byte-identical offsets. A cache would need
//! invalidation on every one of the thirty mutating doors, and the first one missed would hand back
//! spans that index a document that no longer exists.
//!
//! The three slots that DO exist — the clipboard, the submitted command — park the result of a
//! one-shot mutation, which by definition cannot be recomputed. Same shape and same reason as
//! [`crate::input_box`]'s render slot.
//!
//! ## What stays outside
//! Composition (`NSTextInputClient` / `UITextInput`), key NAMING and the candidate list's
//! appearance. `docs/68` §10 keeps those in the view, and the rule that follows from it is about
//! the MUTATING doors: a motion crosses as `SLOPDESK_PROMPT_MOTION_*`, never as a key — nothing
//! here moves a caret because a key was pressed. Deciding WHICH verb a press names is the other
//! half of that split and it is Rust's, which is what [`slopdesk_prompt_key_action`] answers for
//! the one platform whose framework does not answer it. The completion SOURCES also stay outside —
//! reading a directory or an environment is I/O, and [`slopdesk_terminal::prompt::complete`] does
//! none; the caller seeds what it found and this door ranks it.

use core::ffi::c_uchar;

use slopdesk_terminal::prompt::buffer::{Direction, Motion};
use slopdesk_terminal::prompt::complete::{
    Candidate, CandidateKind, CandidateProvider, CommandProvider, CommandSpec, PathEntry, PathProvider,
    ShellGroup, ShellProvider, ShellSuggestion, VariableProvider,
};
use slopdesk_terminal::prompt::keys::{
    ControlAction, EditAction, Key, KeyContext, Mods, control_action, edit_action, over_suggestion,
};
use slopdesk_terminal::prompt::syntax::{TokenKind, Unterminated};
use slopdesk_terminal::prompt::{CommandEditor, SearchSession, Submission};

use crate::{
    SlopDeskByteSpan, TextArena, arena_text, borrow, deliver, lent, records_of, saturating_u32, spill,
};

/// One grapheme cluster toward the start of the document.
pub const SLOPDESK_PROMPT_MOTION_GRAPHEME_BACKWARD: u8 = 0;
/// One grapheme cluster toward the end.
pub const SLOPDESK_PROMPT_MOTION_GRAPHEME_FORWARD: u8 = 1;
/// To the far edge of the previous UAX #29 word.
pub const SLOPDESK_PROMPT_MOTION_WORD_BACKWARD: u8 = 2;
/// To the far edge of the next word.
pub const SLOPDESK_PROMPT_MOTION_WORD_FORWARD: u8 = 3;
/// To the start of the current logical line.
pub const SLOPDESK_PROMPT_MOTION_LINE_START: u8 = 4;
/// To the end of the current logical line.
pub const SLOPDESK_PROMPT_MOTION_LINE_END: u8 = 5;
/// One logical line up, keeping the goal column.
pub const SLOPDESK_PROMPT_MOTION_LINE_UP: u8 = 6;
/// One logical line down, keeping the goal column.
pub const SLOPDESK_PROMPT_MOTION_LINE_DOWN: u8 = 7;
/// To the start of the whole document.
pub const SLOPDESK_PROMPT_MOTION_DOC_START: u8 = 8;
/// To the end of the whole document.
pub const SLOPDESK_PROMPT_MOTION_DOC_END: u8 = 9;

/// The first word of a command.
pub const SLOPDESK_PROMPT_TOKEN_COMMAND_NAME: u32 = 0;
/// A bare word in argument position.
pub const SLOPDESK_PROMPT_TOKEN_ARGUMENT: u32 = 1;
/// An argument beginning with `-`.
pub const SLOPDESK_PROMPT_TOKEN_FLAG: u32 = 2;
/// An argument that looks like a path, and every redirection target.
pub const SLOPDESK_PROMPT_TOKEN_PATH: u32 = 3;
/// A quoted run, its quotes included.
pub const SLOPDESK_PROMPT_TOKEN_QUOTED: u32 = 4;
/// `$NAME`, `${…}`, or a special parameter.
pub const SLOPDESK_PROMPT_TOKEN_VARIABLE: u32 = 5;
/// A control operator.
pub const SLOPDESK_PROMPT_TOKEN_OPERATOR: u32 = 6;
/// A redirection.
pub const SLOPDESK_PROMPT_TOKEN_REDIRECTION: u32 = 7;
/// `#` to end of line.
pub const SLOPDESK_PROMPT_TOKEN_COMMENT: u32 = 8;

/// Everything is closed — the submit key runs it.
pub const SLOPDESK_PROMPT_OPEN_NOTHING: u32 = 0;
/// A `'` with no partner.
pub const SLOPDESK_PROMPT_OPEN_SINGLE_QUOTE: u32 = 1;
/// A `"` with no partner.
pub const SLOPDESK_PROMPT_OPEN_DOUBLE_QUOTE: u32 = 2;
/// The document ends with an unescaped `\`.
pub const SLOPDESK_PROMPT_OPEN_BACKSLASH: u32 = 3;
/// A `$(` with no `)`.
pub const SLOPDESK_PROMPT_OPEN_SUBSTITUTION: u32 = 4;
/// An odd number of `` ` ``.
pub const SLOPDESK_PROMPT_OPEN_BACKTICK: u32 = 5;
/// A `${` with no `}`.
pub const SLOPDESK_PROMPT_OPEN_VARIABLE: u32 = 6;
/// A `(` with no `)`, outside a substitution.
pub const SLOPDESK_PROMPT_OPEN_GROUP: u32 = 7;

/// A subcommand of the command already typed.
pub const SLOPDESK_PROMPT_CANDIDATE_SUBCOMMAND: u32 = 0;
/// A flag of that command.
pub const SLOPDESK_PROMPT_CANDIDATE_FLAG: u32 = 1;
/// A directory.
pub const SLOPDESK_PROMPT_CANDIDATE_DIRECTORY: u32 = 2;
/// A file.
pub const SLOPDESK_PROMPT_CANDIDATE_PATH: u32 = 3;
/// An environment variable name.
pub const SLOPDESK_PROMPT_CANDIDATE_VARIABLE: u32 = 4;
/// A whole command line from the history.
pub const SLOPDESK_PROMPT_CANDIDATE_HISTORY: u32 = 5;

/// The document was closed and the command was taken — read the submitted slot.
pub const SLOPDESK_PROMPT_SUBMISSION_RUN: u8 = 0;
/// Something was still open, so the key inserted a newline instead. The submitted slot is empty and
/// [`SlopDeskPromptState::unterminated`] names what needs closing.
pub const SLOPDESK_PROMPT_SUBMISSION_CONTINUED: u8 = 1;

/// The control press is the editor's; no byte reaches the shell.
pub const SLOPDESK_PROMPT_CONTROL_EDITOR: u8 = 0;
/// The control press is the shell's: send the byte, leave the editor's text alone.
pub const SLOPDESK_PROMPT_CONTROL_FORWARD: u8 = 1;
/// The control press is the shell's AND it abandons the line: send the byte, then clear the editor.
pub const SLOPDESK_PROMPT_CONTROL_FORWARD_AND_CLEAR: u8 = 2;

/// What a `⌃`-modified letter does while the editor is armed.
///
/// The rule is [`slopdesk_terminal::prompt::keys::control_action`], and its header is why four keys
/// are carved out at all: `⌃C`, `⌃D` on an empty line, `⌃Z` and `⌃L` were never `readline`'s
/// either, and an editor that swallowed them would leave the terminal in a state with no way out.
///
/// `letter` is the LOWERCASE ASCII letter; a caller that passes `b'C'` gets
/// [`SLOPDESK_PROMPT_CONTROL_EDITOR`], which is the safe answer but not the one it meant.
///
/// A free function rather than a method on the handle: it asks nothing of the editor except whether
/// its buffer is empty, which the caller already has out of [`SlopDeskPromptState`], and a door
/// that took the handle would invite the view to call it while holding no prompt at all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_prompt_control_action(letter: u8, buffer_empty: bool) -> u8 {
    match control_action(letter, buffer_empty) {
        ControlAction::Editor => SLOPDESK_PROMPT_CONTROL_EDITOR,
        ControlAction::Forward => SLOPDESK_PROMPT_CONTROL_FORWARD,
        ControlAction::ForwardAndClear => SLOPDESK_PROMPT_CONTROL_FORWARD_AND_CLEAR,
    }
}

/// The press is TEXT — nothing here names it, so the caller inserts its characters.
pub const SLOPDESK_PROMPT_ACTION_NONE: u8 = 0;
/// Move the caret, or extend the selection. Read `motion` and `extend`.
pub const SLOPDESK_PROMPT_ACTION_MOVE: u8 = 1;
/// Delete at `motion`'s granularity.
pub const SLOPDESK_PROMPT_ACTION_DELETE: u8 = 2;
/// Scroll the VIEWPORT by `pages`. Negative reveals older output.
pub const SLOPDESK_PROMPT_ACTION_SCROLL_PAGES: u8 = 3;
/// Walk to an older command, if the caret is on the document's first line.
pub const SLOPDESK_PROMPT_ACTION_HISTORY_PREVIOUS: u8 = 4;
/// Walk to a newer one, if the caret is on the last.
pub const SLOPDESK_PROMPT_ACTION_HISTORY_NEXT: u8 = 5;
/// Run it, accept a candidate, or take the search's hit.
pub const SLOPDESK_PROMPT_ACTION_SUBMIT: u8 = 6;
/// A second line of the same command.
pub const SLOPDESK_PROMPT_ACTION_INSERT_NEWLINE: u8 = 7;
/// Complete, or step to the next candidate.
pub const SLOPDESK_PROMPT_ACTION_COMPLETE_FORWARD: u8 = 8;
/// Step to the previous candidate.
pub const SLOPDESK_PROMPT_ACTION_COMPLETE_BACKWARD: u8 = 9;
/// Dismiss what is up, innermost first. Never clears the text.
pub const SLOPDESK_PROMPT_ACTION_CANCEL: u8 = 10;
/// Select the whole document.
pub const SLOPDESK_PROMPT_ACTION_SELECT_ALL: u8 = 11;
/// Paste the system clipboard.
pub const SLOPDESK_PROMPT_ACTION_PASTE: u8 = 12;
/// Copy the selection.
pub const SLOPDESK_PROMPT_ACTION_COPY: u8 = 13;
/// Cut the selection.
pub const SLOPDESK_PROMPT_ACTION_CUT: u8 = 14;
/// Take back one edit.
pub const SLOPDESK_PROMPT_ACTION_UNDO: u8 = 15;
/// Put one back.
pub const SLOPDESK_PROMPT_ACTION_REDO: u8 = 16;
/// Open a reverse search, or step its panel one row down.
pub const SLOPDESK_PROMPT_ACTION_SEARCH: u8 = 17;
/// The press is the SHELL's: send its control byte, leave the editor's text alone.
pub const SLOPDESK_PROMPT_ACTION_FORWARD: u8 = 18;
/// The shell's AND it abandons the line: send the byte, then clear the editor.
pub const SLOPDESK_PROMPT_ACTION_FORWARD_AND_CLEAR: u8 = 19;
/// Take the whole autosuggestion into the document — a forward motion over a live ghost.
pub const SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION: u8 = 20;
/// Take one word of it — ⌥→ over a live ghost.
pub const SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION_WORD: u8 = 21;

/// The press names a character rather than a named key — read `letter`.
pub const SLOPDESK_PROMPT_KEY_CHAR: u8 = 0;
/// ←
pub const SLOPDESK_PROMPT_KEY_LEFT: u8 = 1;
/// →
pub const SLOPDESK_PROMPT_KEY_RIGHT: u8 = 2;
/// ↑
pub const SLOPDESK_PROMPT_KEY_UP: u8 = 3;
/// ↓
pub const SLOPDESK_PROMPT_KEY_DOWN: u8 = 4;
/// Home
pub const SLOPDESK_PROMPT_KEY_HOME: u8 = 5;
/// End
pub const SLOPDESK_PROMPT_KEY_END: u8 = 6;
/// Page Up
pub const SLOPDESK_PROMPT_KEY_PAGE_UP: u8 = 7;
/// Page Down
pub const SLOPDESK_PROMPT_KEY_PAGE_DOWN: u8 = 8;
/// ⌫
pub const SLOPDESK_PROMPT_KEY_BACKSPACE: u8 = 9;
/// ⌦, the forward delete
pub const SLOPDESK_PROMPT_KEY_DELETE: u8 = 10;
/// ⇥
pub const SLOPDESK_PROMPT_KEY_TAB: u8 = 11;
/// ↩
pub const SLOPDESK_PROMPT_KEY_RETURN: u8 = 12;
/// ⎋
pub const SLOPDESK_PROMPT_KEY_ESCAPE: u8 = 13;

/// ⇧ was held.
pub const SLOPDESK_PROMPT_MOD_SHIFT: u8 = 1;
/// ⌃ was held.
pub const SLOPDESK_PROMPT_MOD_CONTROL: u8 = 2;
/// ⌥ was held.
pub const SLOPDESK_PROMPT_MOD_OPTION: u8 = 4;
/// ⌘ was held.
pub const SLOPDESK_PROMPT_MOD_COMMAND: u8 = 8;

/// The verb one press names at an armed prompt.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskPromptKeyAction {
    /// One of the `SLOPDESK_PROMPT_ACTION_*` values.
    pub kind: u8,
    /// One of the `SLOPDESK_PROMPT_MOTION_*` values. Meaningless unless `kind` is
    /// [`SLOPDESK_PROMPT_ACTION_MOVE`] or [`SLOPDESK_PROMPT_ACTION_DELETE`].
    pub motion: u8,
    /// Whether the selection's anchor stays put. Meaningless unless `kind` is
    /// [`SLOPDESK_PROMPT_ACTION_MOVE`].
    pub extend: bool,
    /// How many pages, signed. Meaningless unless `kind` is
    /// [`SLOPDESK_PROMPT_ACTION_SCROLL_PAGES`].
    pub pages: i32,
}

/// What one press does while the editor is armed.
///
/// ⚠️ THIS DOOR TAKES A KEY, AND THAT IS NOT THE RULE BEING BROKEN. The module header's "a motion
/// crosses as `SLOPDESK_PROMPT_MOTION_*`, never as a key" is about the MUTATING doors, and it still
/// holds: nothing here moves anything. `docs/68` §10 splits key NAMING from the decision — the view
/// turns a `UIKey` into one of the `SLOPDESK_PROMPT_KEY_*` values, which is a normalisation no
/// platform-independent side could do, and the decision comes back.
///
/// The Mac never calls it. `AppKit`'s standard key-binding table already names `⌥←`, `⌃A` and `⇧⌘→`
/// and `doCommand(by:)` delivers each as a selector, so `MacTerminalRendererView` maps SELECTORS
/// and inherits every layout and every user's `DefaultKeyBinding.dict` for free. `UIKit` has no
/// counterpart at all — no `doCommand(by:)`, and `UITextInput` supplies none of it — so without
/// this the phone's editing semantics would be a hand-kept Swift table, which is the second
/// implementation the whole prompt was built in Rust to avoid.
///
/// `letter` is read only when `key` is [`SLOPDESK_PROMPT_KEY_CHAR`], and must be the LOWERCASE
/// ASCII letter; `0` for anything non-ASCII, which is text and names no verb.
///
/// A free function for [`slopdesk_prompt_control_action`]'s reason: it asks nothing of the editor
/// except the two bits of state a key's meaning turns on, and the caller already holds both out of
/// [`SlopDeskPromptState`] — `buffer_empty` for `⌃D`, `has_suggestion` for every forward motion.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_prompt_key_action(
    key: u8,
    letter: u8,
    mods: u8,
    buffer_empty: bool,
    has_suggestion: bool,
) -> SlopDeskPromptKeyAction {
    let named = match key {
        SLOPDESK_PROMPT_KEY_LEFT => Key::Left,
        SLOPDESK_PROMPT_KEY_RIGHT => Key::Right,
        SLOPDESK_PROMPT_KEY_UP => Key::Up,
        SLOPDESK_PROMPT_KEY_DOWN => Key::Down,
        SLOPDESK_PROMPT_KEY_HOME => Key::Home,
        SLOPDESK_PROMPT_KEY_END => Key::End,
        SLOPDESK_PROMPT_KEY_PAGE_UP => Key::PageUp,
        SLOPDESK_PROMPT_KEY_PAGE_DOWN => Key::PageDown,
        SLOPDESK_PROMPT_KEY_BACKSPACE => Key::Backspace,
        SLOPDESK_PROMPT_KEY_DELETE => Key::Delete,
        SLOPDESK_PROMPT_KEY_TAB => Key::Tab,
        SLOPDESK_PROMPT_KEY_RETURN => Key::Return,
        SLOPDESK_PROMPT_KEY_ESCAPE => Key::Escape,
        // Every other value, `SLOPDESK_PROMPT_KEY_CHAR` and any byte a future caller invents alike.
        // A key nobody named is a letter nobody typed, which is text, which names no verb.
        _ => Key::Char(letter),
    };
    let mods = Mods {
        shift: mods & SLOPDESK_PROMPT_MOD_SHIFT != 0,
        control: mods & SLOPDESK_PROMPT_MOD_CONTROL != 0,
        option: mods & SLOPDESK_PROMPT_MOD_OPTION != 0,
        command: mods & SLOPDESK_PROMPT_MOD_COMMAND != 0,
    };
    let context = KeyContext {
        buffer_empty,
        has_suggestion,
    };
    let Some(action) = edit_action(named, mods, context) else {
        return SlopDeskPromptKeyAction::default();
    };
    let plain = |kind| {
        SlopDeskPromptKeyAction {
            kind,
            ..SlopDeskPromptKeyAction::default()
        }
    };
    match action {
        EditAction::Move { motion, extend } => {
            SlopDeskPromptKeyAction {
                kind: SLOPDESK_PROMPT_ACTION_MOVE,
                motion: motion_code(motion),
                extend,
                pages: 0,
            }
        },
        EditAction::Delete(motion) => {
            SlopDeskPromptKeyAction {
                kind: SLOPDESK_PROMPT_ACTION_DELETE,
                motion: motion_code(motion),
                extend: false,
                pages: 0,
            }
        },
        EditAction::ScrollPages(pages) => {
            SlopDeskPromptKeyAction {
                kind: SLOPDESK_PROMPT_ACTION_SCROLL_PAGES,
                motion: 0,
                extend: false,
                pages,
            }
        },
        EditAction::HistoryPrevious => plain(SLOPDESK_PROMPT_ACTION_HISTORY_PREVIOUS),
        EditAction::HistoryNext => plain(SLOPDESK_PROMPT_ACTION_HISTORY_NEXT),
        EditAction::Submit => plain(SLOPDESK_PROMPT_ACTION_SUBMIT),
        EditAction::InsertNewline => plain(SLOPDESK_PROMPT_ACTION_INSERT_NEWLINE),
        EditAction::CompleteForward => plain(SLOPDESK_PROMPT_ACTION_COMPLETE_FORWARD),
        EditAction::CompleteBackward => plain(SLOPDESK_PROMPT_ACTION_COMPLETE_BACKWARD),
        EditAction::Cancel => plain(SLOPDESK_PROMPT_ACTION_CANCEL),
        EditAction::SelectAll => plain(SLOPDESK_PROMPT_ACTION_SELECT_ALL),
        EditAction::Paste => plain(SLOPDESK_PROMPT_ACTION_PASTE),
        EditAction::Copy => plain(SLOPDESK_PROMPT_ACTION_COPY),
        EditAction::Cut => plain(SLOPDESK_PROMPT_ACTION_CUT),
        EditAction::Undo => plain(SLOPDESK_PROMPT_ACTION_UNDO),
        EditAction::Redo => plain(SLOPDESK_PROMPT_ACTION_REDO),
        EditAction::Search => plain(SLOPDESK_PROMPT_ACTION_SEARCH),
        EditAction::AcceptSuggestion => plain(SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION),
        EditAction::AcceptSuggestionWord => plain(SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION_WORD),
        EditAction::Control(ControlAction::Forward) => plain(SLOPDESK_PROMPT_ACTION_FORWARD),
        EditAction::Control(ControlAction::ForwardAndClear) => {
            plain(SLOPDESK_PROMPT_ACTION_FORWARD_AND_CLEAR)
        },
        // `ControlAction::Editor` never reaches here: `edit_action` resolves it into a motion or
        // into `None`, which is what makes "the editor's" mean something on this side of the door.
        EditAction::Control(ControlAction::Editor) => SlopDeskPromptKeyAction::default(),
    }
}

/// The `SLOPDESK_PROMPT_MOTION_*` value for one motion — the inverse of [`motion_of`].
const fn motion_code(motion: Motion) -> u8 {
    match motion {
        Motion::Grapheme(Direction::Backward) => SLOPDESK_PROMPT_MOTION_GRAPHEME_BACKWARD,
        Motion::Grapheme(Direction::Forward) => SLOPDESK_PROMPT_MOTION_GRAPHEME_FORWARD,
        Motion::Word(Direction::Backward) => SLOPDESK_PROMPT_MOTION_WORD_BACKWARD,
        Motion::Word(Direction::Forward) => SLOPDESK_PROMPT_MOTION_WORD_FORWARD,
        Motion::LineEdge(Direction::Backward) => SLOPDESK_PROMPT_MOTION_LINE_START,
        Motion::LineEdge(Direction::Forward) => SLOPDESK_PROMPT_MOTION_LINE_END,
        Motion::Line(Direction::Backward) => SLOPDESK_PROMPT_MOTION_LINE_UP,
        Motion::Line(Direction::Forward) => SLOPDESK_PROMPT_MOTION_LINE_DOWN,
        Motion::DocEdge(Direction::Backward) => SLOPDESK_PROMPT_MOTION_DOC_START,
        Motion::DocEdge(Direction::Forward) => SLOPDESK_PROMPT_MOTION_DOC_END,
    }
}

/// Everything the prompt view reads between edits, in one record.
///
/// One call rather than a dozen getters, for [`crate::input_box`]'s reason: they are answers to the
/// same question — "what does the prompt look like now" — and a caller reading them one at a time
/// could interleave a keystroke and pair a cursor from before it with a selection from after.
///
/// Byte offsets throughout, into the UTF-8 [`slopdesk_prompt_text`] answers. Never scalar or
/// grapheme indices: the editor's own vocabulary is bytes, and converting here would put a second
/// index space on the wire for the view to convert back.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskPromptState {
    /// How many bytes [`slopdesk_prompt_text`] would answer.
    pub text_len: usize,
    /// The caret's byte offset.
    pub cursor: usize,
    /// The end the next extend-selection leaves alone. Meaningless without `has_selection`.
    pub selection_anchor: usize,
    /// The end the next extend-selection moves. Meaningless without `has_selection`.
    pub selection_head: usize,
    /// Whether the two selection ends mean anything — an empty selection is not a selection.
    pub has_selection: bool,
    /// One of the `SLOPDESK_PROMPT_OPEN_*` values.
    pub unterminated: u32,
    /// Whether the submit key would run the document rather than extend it.
    pub would_run: bool,
    /// Whether ↑/↓ are walking the history rather than moving the caret.
    pub walking_history: bool,
    /// Whether a reverse search is open.
    ///
    /// Its ROWS are the candidate list — `candidate_count` and `selected_candidate` describe the
    /// ⌃R panel while this is set. The `search_has_hit` field this replaced answered a question the
    /// panel makes visible: an empty `candidate_count` IS "nothing matched".
    pub searching: bool,
    /// How many history entries the ⌃R query matched, INCLUDING the ones that did not fit. `0` with
    /// no session up.
    ///
    /// The one search number the candidate doors cannot carry, because they carry what fits: the
    /// list is capped before it crosses, so `candidate_count` reports the cap and not the answer
    /// once a query matches more than that. What the panel's query row prints, and the only reason
    /// this field exists rather than a second list.
    pub search_matches: usize,
    /// Whether there is an undo step to take.
    pub can_undo: bool,
    /// Whether there is a redo step to take.
    pub can_redo: bool,
    /// How many records [`slopdesk_prompt_spans`] would answer.
    pub span_count: usize,
    /// How many records [`slopdesk_prompt_candidates`] would answer.
    pub candidate_count: usize,
    /// Which candidate is highlighted. Meaningless with no candidates.
    pub selected_candidate: usize,
    /// How many entries the history holds.
    pub history_count: usize,
    /// How many bytes [`slopdesk_prompt_suggestion`] would answer. `0` means no ghost is showing.
    ///
    /// A LENGTH rather than a `bool`, so the one read serves both callers: the band draws the
    /// suggestion and the key table asks only whether there is one, and a second door answering the
    /// same question could be read a keystroke apart from this one.
    pub suggestion_len: usize,
}

impl SlopDeskPromptState {
    /// The state a fresh editor starts in, and the answer to a null handle.
    const FRESH: Self = Self {
        text_len: 0,
        cursor: 0,
        selection_anchor: 0,
        selection_head: 0,
        has_selection: false,
        unterminated: SLOPDESK_PROMPT_OPEN_NOTHING,
        would_run: true,
        walking_history: false,
        searching: false,
        search_matches: 0,
        can_undo: false,
        can_redo: false,
        span_count: 0,
        candidate_count: 0,
        selected_candidate: 0,
        history_count: 0,
        suggestion_len: 0,
    };

    /// Reads the editor's current state out.
    fn of(editor: &CommandEditor) -> Self {
        let selection = editor.selection();
        Self {
            text_len: editor.text().len(),
            cursor: editor.cursor(),
            selection_anchor: selection.as_ref().map_or(0, |range| range.start),
            selection_head: selection.as_ref().map_or(0, |range| range.end),
            has_selection: selection.is_some(),
            unterminated: open_index(editor.unterminated()),
            would_run: editor.would_run(),
            walking_history: editor.is_walking_history(),
            searching: editor.search().is_some(),
            search_matches: editor.search().map_or(0, SearchSession::matched),
            can_undo: editor.undo_stack().can_undo(),
            can_redo: editor.undo_stack().can_redo(),
            span_count: editor.lexed().spans.len(),
            candidate_count: editor.candidates().len(),
            selected_candidate: editor.selected_candidate(),
            history_count: editor.history().len(),
            suggestion_len: editor.suggestion().map_or(0, str::len),
        }
    }
}

/// One coloured run of the document.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskPromptSpan {
    /// Byte offset of the first byte.
    pub start: u32,
    /// Byte offset one past the last.
    pub end: u32,
    /// One of the `SLOPDESK_PROMPT_TOKEN_*` values.
    pub kind: u32,
}

/// One ranked completion candidate, its text living in the arena.
///
/// The spans index [`slopdesk_prompt_candidate_arena`] and the match positions index
/// [`slopdesk_prompt_candidate_positions`], so a caller takes three deliveries and needs no
/// per-candidate call. `docs/55` §4's record shape, with this crate's `(offset, length)` arena
/// convention doing the variable-length half.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskPromptCandidate {
    /// What the candidate IS — shown in the list, and what `positions` indexes into.
    pub text: SlopDeskByteSpan,
    /// What actually replaces the document's `replace` range, quoted by the provider.
    pub insert: SlopDeskByteSpan,
    /// The optional right-hand column. Empty when `has_detail` is false.
    pub detail: SlopDeskByteSpan,
    /// Whether `detail` means anything — a present-but-empty detail is not the same fact as none.
    pub has_detail: bool,
    /// One of the `SLOPDESK_PROMPT_CANDIDATE_*` values.
    pub kind: u32,
    /// Byte offset in the document where the replacement starts.
    pub replace_start: u32,
    /// Byte offset in the document one past where it ends.
    pub replace_end: u32,
    /// Where this candidate's matched positions start in the positions array.
    pub positions: SlopDeskByteSpan,
}

/// The opaque handle: the editor, the completion sources the caller seeded, and two one-shot slots.
///
/// The sources live here rather than being passed per call because they are I/O results with a
/// lifetime of their own — a directory listing survives many keystrokes — and re-lending them on
/// every completion would copy the whole listing per character typed.
#[derive(Debug, Default)]
pub struct SlopDeskPrompt {
    editor: CommandEditor,
    /// The leading part of the caret's word that names the directory `entries` came from.
    path_base: String,
    path_entries: Vec<PathEntry>,
    variables: Vec<String>,
    commands: Vec<CommandSpec>,
    /// The last answer from the user's own shell. Held across keystrokes like every other source
    /// here, and for one extra reason: it arrives LATE, so between asking and answering the local
    /// sources are the whole list and the shell's candidates simply join it when they land.
    shell: Vec<ShellGroup>,
    /// What the last copy or cut yielded. Held until the next one.
    clipboard: Vec<u8>,
    /// What the last submit took. Empty when it continued instead.
    submitted: Vec<u8>,
}

impl SlopDeskPrompt {
    /// Ranks the seeded sources at the caret and keeps the list on the editor.
    fn complete(&mut self, limit: usize) -> usize {
        let paths = PathProvider::new(&self.path_base, &self.path_entries);
        let variables = VariableProvider::new(&self.variables);
        let commands = CommandProvider::new(&self.commands);
        // Cloned rather than borrowed because the provider owns its groups, and the clone is one
        // shell answer — bounded by `slopdesk-zshcomplete`'s own cap, and paid once per completion
        // rather than once per keystroke.
        let shell = ShellProvider::new(self.shell.clone());
        let sources: [&dyn CandidateProvider; 4] = [&paths, &variables, &commands, &shell];
        self.editor.complete(&sources, limit)
    }

    /// Projects the candidate list into records plus the arena their spans index.
    ///
    /// One function for both readbacks so the two can never disagree about an offset, which is the
    /// whole reason this is recomputed rather than parked.
    fn projected_candidates(&self) -> (Vec<SlopDeskPromptCandidate>, TextArena) {
        let mut arena = TextArena::default();
        let mut records = Vec::with_capacity(self.editor.candidates().len());
        let mut position_cursor: u32 = 0;
        for ranked in self.editor.candidates() {
            let candidate: &Candidate = &ranked.candidate;
            let (text_offset, text_length) = arena.intern(candidate.text.as_bytes());
            let (insert_offset, insert_length) = arena.intern(candidate.insert.as_bytes());
            let detail = candidate.detail.as_deref();
            let (detail_offset, detail_length) = arena.intern(detail.unwrap_or_default().as_bytes());
            let count = saturating_u32(ranked.positions.len());
            records.push(SlopDeskPromptCandidate {
                text: SlopDeskByteSpan {
                    offset: text_offset,
                    length: text_length,
                },
                insert: SlopDeskByteSpan {
                    offset: insert_offset,
                    length: insert_length,
                },
                detail: SlopDeskByteSpan {
                    offset: detail_offset,
                    length: detail_length,
                },
                has_detail: detail.is_some(),
                kind: candidate_index(candidate.kind),
                replace_start: saturating_u32(candidate.replace.start),
                replace_end: saturating_u32(candidate.replace.end),
                positions: SlopDeskByteSpan {
                    offset: position_cursor,
                    length: count,
                },
            });
            position_cursor = position_cursor.saturating_add(count);
        }
        (records, arena)
    }
}

/// The `SLOPDESK_PROMPT_OPEN_*` value for one lexer verdict.
const fn open_index(open: Unterminated) -> u32 {
    match open {
        Unterminated::Nothing => SLOPDESK_PROMPT_OPEN_NOTHING,
        Unterminated::SingleQuote => SLOPDESK_PROMPT_OPEN_SINGLE_QUOTE,
        Unterminated::DoubleQuote => SLOPDESK_PROMPT_OPEN_DOUBLE_QUOTE,
        Unterminated::Backslash => SLOPDESK_PROMPT_OPEN_BACKSLASH,
        Unterminated::Substitution => SLOPDESK_PROMPT_OPEN_SUBSTITUTION,
        Unterminated::Backtick => SLOPDESK_PROMPT_OPEN_BACKTICK,
        Unterminated::Variable => SLOPDESK_PROMPT_OPEN_VARIABLE,
        Unterminated::Group => SLOPDESK_PROMPT_OPEN_GROUP,
    }
}

/// The `SLOPDESK_PROMPT_TOKEN_*` value for one highlight class.
const fn token_index(kind: TokenKind) -> u32 {
    match kind {
        TokenKind::CommandName => SLOPDESK_PROMPT_TOKEN_COMMAND_NAME,
        TokenKind::Argument => SLOPDESK_PROMPT_TOKEN_ARGUMENT,
        TokenKind::Flag => SLOPDESK_PROMPT_TOKEN_FLAG,
        TokenKind::Path => SLOPDESK_PROMPT_TOKEN_PATH,
        TokenKind::Quoted => SLOPDESK_PROMPT_TOKEN_QUOTED,
        TokenKind::Variable => SLOPDESK_PROMPT_TOKEN_VARIABLE,
        TokenKind::Operator => SLOPDESK_PROMPT_TOKEN_OPERATOR,
        TokenKind::Redirection => SLOPDESK_PROMPT_TOKEN_REDIRECTION,
        TokenKind::Comment => SLOPDESK_PROMPT_TOKEN_COMMENT,
    }
}

/// The `SLOPDESK_PROMPT_CANDIDATE_*` value for one candidate class.
const fn candidate_index(kind: CandidateKind) -> u32 {
    match kind {
        CandidateKind::Subcommand => SLOPDESK_PROMPT_CANDIDATE_SUBCOMMAND,
        CandidateKind::Flag => SLOPDESK_PROMPT_CANDIDATE_FLAG,
        CandidateKind::Directory => SLOPDESK_PROMPT_CANDIDATE_DIRECTORY,
        CandidateKind::Path => SLOPDESK_PROMPT_CANDIDATE_PATH,
        CandidateKind::Variable => SLOPDESK_PROMPT_CANDIDATE_VARIABLE,
        CandidateKind::History => SLOPDESK_PROMPT_CANDIDATE_HISTORY,
    }
}

/// The [`Motion`] one `SLOPDESK_PROMPT_MOTION_*` value names.
///
/// An unknown index reads as one grapheme forward rather than as a panic: the index is untrusted
/// input on this side of the boundary, and a caller that sent a value from a newer header should
/// get a defined nudge rather than a crashed process.
const fn motion_of(index: u8) -> Motion {
    match index {
        SLOPDESK_PROMPT_MOTION_GRAPHEME_BACKWARD => Motion::Grapheme(Direction::Backward),
        SLOPDESK_PROMPT_MOTION_WORD_BACKWARD => Motion::Word(Direction::Backward),
        SLOPDESK_PROMPT_MOTION_WORD_FORWARD => Motion::Word(Direction::Forward),
        SLOPDESK_PROMPT_MOTION_LINE_START => Motion::LineEdge(Direction::Backward),
        SLOPDESK_PROMPT_MOTION_LINE_END => Motion::LineEdge(Direction::Forward),
        SLOPDESK_PROMPT_MOTION_LINE_UP => Motion::Line(Direction::Backward),
        SLOPDESK_PROMPT_MOTION_LINE_DOWN => Motion::Line(Direction::Forward),
        SLOPDESK_PROMPT_MOTION_DOC_START => Motion::DocEdge(Direction::Backward),
        SLOPDESK_PROMPT_MOTION_DOC_END => Motion::DocEdge(Direction::Forward),
        _ => Motion::Grapheme(Direction::Forward),
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_prompt_new`] that has not been freed, and no
/// other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskPrompt) -> Option<&'a mut SlopDeskPrompt> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one object per prompt, driven by one main-actor path.
    Some(unsafe { &mut *handle })
}

/// Builds an empty prompt with an empty history, no seeded sources and empty slots.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_new() -> *mut SlopDeskPrompt {
    Box::into_raw(Box::new(SlopDeskPrompt::default()))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_prompt_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_prompt_new`] not yet freed, with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_free(handle: *mut SlopDeskPrompt) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Reads the current state. A null handle answers the state a fresh editor starts in.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_state(handle: *mut SlopDeskPrompt) -> SlopDeskPromptState {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskPromptState::FRESH;
    };
    SlopDeskPromptState::of(&state.editor)
}

/// Copies the document's UTF-8 bytes out, answering the length either way.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_text(
    handle: *mut SlopDeskPrompt,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation.
    unsafe { deliver(state.editor.text().as_bytes(), out, cap) }
}

/// Copies the highlight spans out, answering the count NEEDED.
///
/// Ascending, non-overlapping, and adjacent runs of one kind already merged — the caller draws one
/// rect per record.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap`
/// records.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_spans(
    handle: *mut SlopDeskPrompt,
    out: *mut SlopDeskPromptSpan,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let spans: Vec<SlopDeskPromptSpan> = state
        .editor
        .lexed()
        .spans
        .iter()
        .map(|span| {
            SlopDeskPromptSpan {
                start: saturating_u32(span.start),
                end: saturating_u32(span.end),
                kind: token_index(span.kind),
            }
        })
        .collect();
    // SAFETY: `out` is null or writable for `cap` records by the caller's obligation, and `spans`
    // was allocated inside this call so it cannot overlap.
    unsafe { spill(&spans, out, cap) }
}

/// Inserts text at the caret, replacing any selection.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_insert(
    handle: *mut SlopDeskPrompt,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let text = unsafe { lent(bytes, len) };
    state.editor.insert_text(text);
}

/// Inserts a newline — the continuation key, distinct from submit.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_insert_newline(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.insert_newline();
    }
}

/// Pastes text, which coalesces into the undo stack as ONE step however long it is.
///
/// A separate door from [`slopdesk_prompt_insert`] because that is the difference the undo stack
/// keys on, and a view that used insert for both would make ⌘Z walk a pasted paragraph one
/// character at a time.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_paste(
    handle: *mut SlopDeskPrompt,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let text = unsafe { lent(bytes, len) };
    state.editor.paste(text);
}

/// Deletes the selection, or one `SLOPDESK_PROMPT_MOTION_*` granularity when there is none.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_delete(handle: *mut SlopDeskPrompt, motion: u8) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.delete(motion_of(motion));
    }
}

/// Replaces a byte range with text. Out-of-bounds or non-boundary offsets are the editor's to
/// clamp.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_replace_range(
    handle: *mut SlopDeskPrompt,
    start: usize,
    end: usize,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let text = unsafe { lent(bytes, len) };
    state.editor.replace_range(start..end, text);
}

/// Empties the document, keeping the history.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_clear(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.clear();
    }
}

/// Moves the caret, collapsing any selection.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_move(handle: *mut SlopDeskPrompt, motion: u8) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.move_to(motion_of(motion));
    }
}

/// Moves the selection's head, leaving the anchor — the shift-arrow half.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_extend(handle: *mut SlopDeskPrompt, motion: u8) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.extend_to(motion_of(motion));
    }
}

/// Puts the caret at a byte offset, collapsing any selection — the click.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_set_cursor(handle: *mut SlopDeskPrompt, offset: usize) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.set_cursor(offset);
    }
}

/// Sets both selection ends at once — the drag, and the only way to say which end is the head.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_set_selection(
    handle: *mut SlopDeskPrompt,
    anchor: usize,
    head: usize,
) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.set_selection(anchor, head);
    }
}

/// Selects the whole document.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_select_all(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.select_all();
    }
}

/// Parks the selected text in the clipboard slot and answers its length. Zero with no selection.
///
/// A slot rather than an `(out, cap)` answer for the same reason as
/// [`slopdesk_prompt_cut`], which shares it: the two doors must be indistinguishable to the view
/// apart from the deletion, and only one of them can be re-run safely.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_copy(handle: *mut SlopDeskPrompt) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.clipboard = state.editor.copy().unwrap_or_default().into_bytes();
    state.clipboard.len()
}

/// Deletes the selection, parks it in the clipboard slot and answers its length.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_cut(handle: *mut SlopDeskPrompt) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.clipboard = state.editor.cut().unwrap_or_default().into_bytes();
    state.clipboard.len()
}

/// Copies the parked clipboard bytes out. The slot is NOT cleared, so a caller that got its size
/// wrong retries rather than losing the cut.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_take_clipboard(
    handle: *mut SlopDeskPrompt,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap` bytes, and the slot cannot overlap it.
    unsafe { deliver(&state.clipboard, out, cap) }
}

/// Takes one undo step. `false` when there was none.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_undo(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.undo()
}

/// Takes one redo step. `false` when there was none.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_redo(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.redo()
}

/// Walks one entry back through the history, keeping what was typed as the prefix. `false` at the
/// end.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_history_previous(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.history_previous()
}

/// Walks one entry forward, back toward the draft. `false` when not walking.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_history_next(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.history_next()
}

/// Appends one command to the history — the door a restore from disk replays entry by entry.
///
/// One call per entry rather than a framed blob because the ring's own `record` is what dedupes and
/// caps, and a bulk door would either skip that or restate it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_history_record(
    handle: *mut SlopDeskPrompt,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let command = unsafe { lent(bytes, len) };
    state.editor.history_mut().record(command);
}

/// Copies one history entry out, oldest first. Answers 0 for an index past the end.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_history_entry(
    handle: *mut SlopDeskPrompt,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let entry = state.editor.history().get(index).unwrap_or_default();
    // SAFETY: `out` is null or writable for `cap` bytes, and `entry` cannot overlap it.
    unsafe { deliver(entry.as_bytes(), out, cap) }
}

/// Opens a reverse search over the history.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_begin(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.begin_reverse_search();
    }
}

/// Appends to the reverse-search query and re-runs it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_type(
    handle: *mut SlopDeskPrompt,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let text = unsafe { lent(bytes, len) };
    state.editor.reverse_search_type(text);
}

/// Drops the query's last grapheme and re-runs it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_backspace(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.reverse_search_backspace();
    }
}

/// Steps to the next older hit. `false` when there is none.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_again(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.reverse_search_again()
}

/// Takes the selected row into the document and closes the search. `false` with no rows.
///
/// It does not RUN the command — see `CommandEditor::reverse_search_accept` for why the submit key
/// keeps that, against a line the user can see.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_accept(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.reverse_search_accept()
}

/// Closes the search, leaving the document as it was.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_cancel(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.reverse_search_cancel();
    }
}

/// Copies the reverse-search query out. Empty when no search is open.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_query(
    handle: *mut SlopDeskPrompt,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let query = state.editor.search().map_or("", |session| session.query());
    // SAFETY: `out` is null or writable for `cap` bytes, and `query` cannot overlap it.
    unsafe { deliver(query.as_bytes(), out, cap) }
}

/// ⌃S / ↑ — one row back UP the ⌃R panel, wrapping. `false` with no session or no rows.
///
/// ⚠️ **This replaced `slopdesk_prompt_search_hit`.** That door existed because the search showed
/// exactly one match and the buffer is deliberately not touched while it runs, so a single string
/// was the only way the band could show a result at all. The panel makes every match visible
/// through the candidate doors, so what is missing is not a way to READ the hit but a way to move
/// backwards through the ones on screen — `fish`'s pager binds ⌃S to it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_search_back(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.reverse_search_back()
}

/// Replaces the filesystem source: the directory prefix, and the names read from it.
///
/// The two arrive together because a base without its entries would rank the previous directory's
/// names under the new prefix — a candidate list that names files that are not there.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `(base, base_len)` must describe live memory, and
/// `names` must describe `count` live spans into `(arena, arena_len)`, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_set_paths(
    handle: *mut SlopDeskPrompt,
    base: *const c_uchar,
    base_len: usize,
    names: *const SlopDeskByteSpan,
    directories: *const bool,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: each pair is live for the call or null, which borrows as empty.
    let (prefix, spans, flags, bytes) = unsafe {
        (
            lent(base, base_len),
            records_of(names, count),
            records_of(directories, count),
            borrow(arena, arena_len),
        )
    };
    prefix.clone_into(&mut state.path_base);
    state.path_entries = spans
        .iter()
        .zip(flags)
        .map(|(span, &directory)| {
            PathEntry {
                name: arena_text(bytes, span.offset, span.length),
                directory,
            }
        })
        .collect();
}

/// Replaces the environment-variable source.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `names` must describe `count` live spans into
/// `(arena, arena_len)` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_set_variables(
    handle: *mut SlopDeskPrompt,
    names: *const SlopDeskByteSpan,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: each pair is live for the call or null, which borrows as empty.
    let (spans, bytes) = unsafe { (records_of(names, count), borrow(arena, arena_len)) };
    state.variables = spans
        .iter()
        .map(|span| arena_text(bytes, span.offset, span.length))
        .collect();
}

/// Replaces the shell-completion source with one verb-23 answer, as its RAW response payload.
///
/// The payload rather than an arena of records, and that is the whole design of this door: the
/// answer is already a wire body, and the alternative — spanning three levels of nesting into a
/// flat arena — would invent a second framing for a shape `slopdesk-wire` already frames. So the
/// caller hands the bytes straight through and the decode stays where every other metadata decode
/// in this app is. A body this door cannot decode CLEARS the source rather than keeping the
/// previous answer, because a stale list under a new caret is the one thing worse than none.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `(payload, payload_len)` must describe live
/// memory for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_set_shell_candidates(
    handle: *mut SlopDeskPrompt,
    payload: *const c_uchar,
    payload_len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let body = unsafe { borrow(payload, payload_len) };
    state.shell = slopdesk_wire::metadata::codec::decode_shell_complete(body)
        .unwrap_or_default()
        .into_iter()
        .map(|group| {
            ShellGroup {
                prefix: group.prefix,
                suffix: group.suffix,
                suggestions: group
                    .candidates
                    .into_iter()
                    .map(|candidate| {
                        ShellSuggestion {
                            text: candidate.text,
                            // The flag is what carries "there is no description" — an empty string
                            // that WAS offered is a different fact, and reading emptiness instead
                            // would silently drop one.
                            detail: candidate.has_detail.then_some(candidate.detail),
                            verbatim: candidate.verbatim,
                        }
                    })
                    .collect(),
            }
        })
        .collect();
}

/// Appends one command to the command/subcommand/flag table, or clears it when `name` is empty.
///
/// Appending one at a time because a `CommandSpec` is three lists deep, and flattening a table of
/// them into one arena delivery would invent a framing that only this door speaks. The table is
/// built once at launch, not per keystroke.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and every `(ptr, len)` and span array must describe
/// live memory for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_add_command(
    handle: *mut SlopDeskPrompt,
    name: *const c_uchar,
    name_len: usize,
    subcommands: *const SlopDeskByteSpan,
    subcommand_count: usize,
    flags: *const SlopDeskByteSpan,
    flag_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: each pair is live for the call or null, which borrows as empty.
    let (command, subs, flagged, bytes) = unsafe {
        (
            lent(name, name_len),
            records_of(subcommands, subcommand_count),
            records_of(flags, flag_count),
            borrow(arena, arena_len),
        )
    };
    if command.is_empty() {
        state.commands.clear();
        return;
    }
    let read = |spans: &[SlopDeskByteSpan]| -> Vec<String> {
        spans
            .iter()
            .map(|span| arena_text(bytes, span.offset, span.length))
            .collect()
    };
    state.commands.push(CommandSpec {
        name: command.to_owned(),
        subcommands: read(subs),
        flags: read(flagged),
    });
}

/// Ranks every seeded source plus the history at the caret and answers how many candidates
/// survived.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_complete(handle: *mut SlopDeskPrompt, limit: usize) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.complete(limit)
}

/// Copies the candidate records out, answering the count NEEDED.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap`
/// records.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_candidates(
    handle: *mut SlopDeskPrompt,
    out: *mut SlopDeskPromptCandidate,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let (records, _arena) = state.projected_candidates();
    // SAFETY: `out` is null or writable for `cap` records, and `records` was allocated inside this
    // call so it cannot overlap.
    unsafe { spill(&records, out, cap) }
}

/// Copies the arena the candidate records' spans index into.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_candidate_arena(
    handle: *mut SlopDeskPrompt,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let (_records, arena) = state.projected_candidates();
    // SAFETY: `out` is null or writable for `cap` bytes, and the arena was allocated inside this
    // call so it cannot overlap.
    unsafe { deliver(&arena.0, out, cap) }
}

/// Copies the concatenated match positions the candidates' `positions` spans index into.
///
/// Scalar indices into each candidate's `text`, for the underline that shows WHY a candidate
/// matched.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` `u32`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_candidate_positions(
    handle: *mut SlopDeskPrompt,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let positions: Vec<u32> = state
        .editor
        .candidates()
        .iter()
        .flat_map(|ranked| ranked.positions.iter().copied())
        .collect();
    // SAFETY: `out` is null or writable for `cap` records, and `positions` was allocated inside
    // this call so it cannot overlap.
    unsafe { spill(&positions, out, cap) }
}

/// Highlights the next candidate, wrapping.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_select_next_candidate(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.select_next_candidate();
    }
}

/// Highlights the previous candidate, wrapping.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_select_previous_candidate(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.select_previous_candidate();
    }
}

/// Applies the highlighted candidate. `false` with no candidates.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_accept_completion(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.accept_completion()
}

/// Which accept a non-extending MOTION becomes while a ghost is live — the Mac's half of the rule.
///
/// Answers [`SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION`],
/// [`SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION_WORD`], or [`SLOPDESK_PROMPT_ACTION_NONE`] for a
/// motion the ghost does not claim.
///
/// ⚠️ **This exists so the two platforms do not each own a list of forward keys.** The phone gets
/// the accept out of [`slopdesk_prompt_key_action`] because `UIKit` hands it a key; the Mac never
/// sees a key at all — `AppKit`'s binding table has already turned the press into a selector, which
/// `MacTerminalRendererView` has already turned into a motion — so it asks the same question one
/// step further along. Both answers come out of `keys::over_suggestion`, which is what makes
/// `⌃F`, `→`, `End`, `⌘→` and a user's own `DefaultKeyBinding.dict` entry behave alike.
///
/// A free function: it reads no editor state, and whether there is a suggestion to take is
/// [`slopdesk_prompt_accept_suggestion`]'s own answer.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub const extern "C" fn slopdesk_prompt_suggestion_accept_for_motion(motion: u8) -> u8 {
    let action = EditAction::Move {
        motion: motion_of(motion),
        extend: false,
    };
    match over_suggestion(action) {
        Some(EditAction::AcceptSuggestion) => SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION,
        Some(EditAction::AcceptSuggestionWord) => SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION_WORD,
        _ => SLOPDESK_PROMPT_ACTION_NONE,
    }
}

/// Copies the inline autosuggestion out — what the newest matching history entry would ADD past
/// the caret — answering its length either way. `0` means there is nothing to propose.
///
/// A READ, asked once per frame beside the spans, which is why it is a copy rather than a
/// subscription: the answer is a prefix scan over the history the editor already holds, and a
/// caller that cached it would have to be told about every keystroke, every ⌃R and every
/// completion — the five states [`CommandEditor::suggestion`] suppresses on.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_suggestion(
    handle: *mut SlopDeskPrompt,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let rest = state.editor.suggestion().unwrap_or("");
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation.
    unsafe { deliver(rest.as_bytes(), out, cap) }
}

/// Takes the whole suggestion into the document — `→` / `⌃E` / `End` at the end of the line.
///
/// ⚠️ **The `false` is the point of the door.** Both shells call this BEFORE the motion those keys
/// otherwise carry and fall through on `false`, so "is there a suggestion to accept" is decided
/// once, in Rust, rather than once per platform — the Mac reaches the prompt through `AppKit`
/// selectors and the phone through `slopdesk_prompt_key_action`, and a predicate spelled on the
/// Swift side would be spelled twice.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_accept_suggestion(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.accept_suggestion()
}

/// Takes one word of the suggestion — `⌥→`. `false` under the whole-accept's rule, for its reason.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_accept_suggestion_word(handle: *mut SlopDeskPrompt) -> bool {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.editor.accept_suggestion_word()
}

/// Drops the candidate list.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_dismiss_completion(handle: *mut SlopDeskPrompt) {
    // SAFETY: the caller's obligation, as above.
    if let Some(state) = unsafe { held(handle) } {
        state.editor.dismiss_completion();
    }
}

/// The submit key. Answers a `SLOPDESK_PROMPT_SUBMISSION_*` value.
///
/// On `RUN` the document was recorded in the history, the command is parked in the submitted slot
/// and the prompt is empty. On `CONTINUED` a newline was inserted instead and
/// [`SlopDeskPromptState::unterminated`] names what is still open.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_submit(handle: *mut SlopDeskPrompt) -> u8 {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return SLOPDESK_PROMPT_SUBMISSION_CONTINUED;
    };
    match state.editor.submit() {
        Submission::Run(command) => {
            state.submitted = command.into_bytes();
            SLOPDESK_PROMPT_SUBMISSION_RUN
        },
        Submission::Continued(_open) => {
            state.submitted.clear();
            SLOPDESK_PROMPT_SUBMISSION_CONTINUED
        },
    }
}

/// Copies the submitted command out. The slot is NOT cleared, so a caller that got its size wrong
/// retries rather than losing the command it was about to run.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prompt_take_submitted(
    handle: *mut SlopDeskPrompt,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap` bytes, and the slot cannot overlap it.
    unsafe { deliver(&state.submitted, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SLOPDESK_PROMPT_CANDIDATE_PATH, SLOPDESK_PROMPT_MOTION_WORD_BACKWARD,
        SLOPDESK_PROMPT_OPEN_SINGLE_QUOTE, SLOPDESK_PROMPT_SUBMISSION_CONTINUED,
        SLOPDESK_PROMPT_SUBMISSION_RUN, SLOPDESK_PROMPT_TOKEN_COMMAND_NAME, SlopDeskPrompt,
        SlopDeskPromptCandidate, SlopDeskPromptSpan, slopdesk_prompt_accept_completion,
        slopdesk_prompt_candidate_arena, slopdesk_prompt_candidates, slopdesk_prompt_complete,
        slopdesk_prompt_delete, slopdesk_prompt_free, slopdesk_prompt_history_entry,
        slopdesk_prompt_history_previous, slopdesk_prompt_insert, slopdesk_prompt_new,
        slopdesk_prompt_search_accept, slopdesk_prompt_search_again, slopdesk_prompt_search_back,
        slopdesk_prompt_search_begin, slopdesk_prompt_search_type, slopdesk_prompt_select_all,
        slopdesk_prompt_set_paths, slopdesk_prompt_spans, slopdesk_prompt_state, slopdesk_prompt_submit,
        slopdesk_prompt_take_clipboard, slopdesk_prompt_take_submitted, slopdesk_prompt_text,
        slopdesk_prompt_undo,
    };
    use crate::{SlopDeskByteSpan, arena_text};

    /// Types text the way the Swift face does.
    fn type_text(handle: *mut SlopDeskPrompt, text: &str) {
        unsafe { slopdesk_prompt_insert(handle, text.as_bytes().as_ptr(), text.len()) };
    }

    /// Reads the document back through the two-attempt convention.
    fn read_text(handle: *mut SlopDeskPrompt) -> String {
        let needed = unsafe { slopdesk_prompt_text(handle, std::ptr::null_mut(), 0) };
        let mut bytes = vec![0_u8; needed];
        let written = unsafe { slopdesk_prompt_text(handle, bytes.as_mut_ptr(), bytes.len()) };
        assert_eq!(written, needed, "the door answered a size it would not fill");
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// The panel row the ⌃R selection is on, read the way the band reads it — through the candidate
    /// records and their arena, which is the whole point of the search having no doors of its own.
    fn read_selected_row(handle: *mut SlopDeskPrompt) -> String {
        let state = unsafe { slopdesk_prompt_state(handle) };
        let count = state.candidate_count;
        let mut records = vec![SlopDeskPromptCandidate::default(); count];
        let _written = unsafe { slopdesk_prompt_candidates(handle, records.as_mut_ptr(), count) };
        let needed = unsafe { slopdesk_prompt_candidate_arena(handle, std::ptr::null_mut(), 0) };
        let mut bytes = vec![0_u8; needed];
        let _filled = unsafe { slopdesk_prompt_candidate_arena(handle, bytes.as_mut_ptr(), needed) };
        let row = records.get(state.selected_candidate).copied().unwrap_or_default();
        arena_text(&bytes, row.text.offset, row.text.length)
    }

    #[test]
    fn a_fresh_handle_is_empty_and_would_run() {
        let handle = unsafe { slopdesk_prompt_new() };
        let state = unsafe { slopdesk_prompt_state(handle) };
        assert_eq!(state.text_len, 0);
        assert!(state.would_run, "an empty document closes nothing");
        assert!(!state.can_undo);
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn typing_lands_in_the_document_and_colours_the_command_name() {
        let handle = unsafe { slopdesk_prompt_new() };
        type_text(handle, "git status");
        assert_eq!(read_text(handle), "git status");
        let state = unsafe { slopdesk_prompt_state(handle) };
        let mut spans = vec![SlopDeskPromptSpan::default(); state.span_count];
        let written = unsafe { slopdesk_prompt_spans(handle, spans.as_mut_ptr(), spans.len()) };
        assert_eq!(written, state.span_count);
        let first = spans.first().copied().unwrap_or_default();
        assert_eq!(first.kind, SLOPDESK_PROMPT_TOKEN_COMMAND_NAME);
        assert_eq!((first.start, first.end), (0, 3));
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn an_unterminated_quote_continues_instead_of_running() {
        let handle = unsafe { slopdesk_prompt_new() };
        type_text(handle, "echo 'hi");
        let verdict = unsafe { slopdesk_prompt_submit(handle) };
        assert_eq!(verdict, SLOPDESK_PROMPT_SUBMISSION_CONTINUED);
        let state = unsafe { slopdesk_prompt_state(handle) };
        assert_eq!(state.unterminated, SLOPDESK_PROMPT_OPEN_SINGLE_QUOTE);
        assert!(!state.would_run);
        assert_eq!(read_text(handle), "echo 'hi\n", "the key inserted a newline");
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn a_closed_document_submits_empties_and_records_itself() {
        let handle = unsafe { slopdesk_prompt_new() };
        type_text(handle, "ls -la");
        let verdict = unsafe { slopdesk_prompt_submit(handle) };
        assert_eq!(verdict, SLOPDESK_PROMPT_SUBMISSION_RUN);
        let needed = unsafe { slopdesk_prompt_take_submitted(handle, std::ptr::null_mut(), 0) };
        let mut taken = vec![0_u8; needed];
        let _written = unsafe { slopdesk_prompt_take_submitted(handle, taken.as_mut_ptr(), needed) };
        assert_eq!(taken, b"ls -la");
        let state = unsafe { slopdesk_prompt_state(handle) };
        assert_eq!(state.text_len, 0, "the prompt cleared itself");
        assert_eq!(state.history_count, 1);
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn the_history_walks_back_to_what_was_submitted() {
        let handle = unsafe { slopdesk_prompt_new() };
        type_text(handle, "cargo test");
        let _ran = unsafe { slopdesk_prompt_submit(handle) };
        assert!(unsafe { slopdesk_prompt_history_previous(handle) });
        assert_eq!(read_text(handle), "cargo test");
        assert!(unsafe { slopdesk_prompt_state(handle) }.walking_history);
        let needed = unsafe { slopdesk_prompt_history_entry(handle, 0, std::ptr::null_mut(), 0) };
        let mut entry = vec![0_u8; needed];
        let _written = unsafe { slopdesk_prompt_history_entry(handle, 0, entry.as_mut_ptr(), needed) };
        assert_eq!(entry, b"cargo test");
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn an_undo_takes_back_a_word_deletion() {
        let handle = unsafe { slopdesk_prompt_new() };
        type_text(handle, "make release");
        unsafe { slopdesk_prompt_delete(handle, SLOPDESK_PROMPT_MOTION_WORD_BACKWARD) };
        assert_eq!(read_text(handle), "make ");
        assert!(unsafe { slopdesk_prompt_undo(handle) });
        assert_eq!(read_text(handle), "make release");
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn a_select_all_then_cut_parks_the_whole_document() {
        let handle = unsafe { slopdesk_prompt_new() };
        type_text(handle, "rm -rf /tmp/x");
        unsafe { slopdesk_prompt_select_all(handle) };
        let needed = unsafe { super::slopdesk_prompt_cut(handle) };
        let mut cut = vec![0_u8; needed];
        let _written = unsafe { slopdesk_prompt_take_clipboard(handle, cut.as_mut_ptr(), needed) };
        assert_eq!(cut, b"rm -rf /tmp/x");
        assert_eq!(unsafe { slopdesk_prompt_state(handle) }.text_len, 0);
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn a_seeded_directory_completes_the_word_under_the_caret() {
        let handle = unsafe { slopdesk_prompt_new() };
        let arena = b"README.md";
        let names = [SlopDeskByteSpan { offset: 0, length: 9 }];
        let directories = [false];
        unsafe {
            slopdesk_prompt_set_paths(
                handle,
                std::ptr::null(),
                0,
                names.as_ptr(),
                directories.as_ptr(),
                names.len(),
                arena.as_ptr(),
                arena.len(),
            );
        }
        type_text(handle, "cat READ");
        let count = unsafe { slopdesk_prompt_complete(handle, 8) };
        assert!(count > 0, "the seeded name ranks against the caret's word");
        let mut records = vec![SlopDeskPromptCandidate::default(); count];
        let written = unsafe { slopdesk_prompt_candidates(handle, records.as_mut_ptr(), records.len()) };
        assert_eq!(written, count);
        let needed = unsafe { slopdesk_prompt_candidate_arena(handle, std::ptr::null_mut(), 0) };
        let mut bytes = vec![0_u8; needed];
        let _filled = unsafe { slopdesk_prompt_candidate_arena(handle, bytes.as_mut_ptr(), needed) };
        let first = records.first().copied().unwrap_or_default();
        assert_eq!(first.kind, SLOPDESK_PROMPT_CANDIDATE_PATH);
        let text = arena_text(&bytes, first.text.offset, first.text.length);
        assert_eq!(text, "README.md");
        assert!(unsafe { slopdesk_prompt_accept_completion(handle) });
        assert_eq!(read_text(handle), "cat README.md");
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn a_reverse_search_ranks_a_panel_and_takes_the_row_it_is_on() {
        let handle = unsafe { slopdesk_prompt_new() };
        for command in ["cargo build --release", "ls", "cargo test"] {
            type_text(handle, command);
            let _ran = unsafe { slopdesk_prompt_submit(handle) };
        }
        unsafe { slopdesk_prompt_search_begin(handle) };
        // An empty query opens the recent-commands panel rather than one hit.
        assert_eq!(unsafe { slopdesk_prompt_state(handle) }.candidate_count, 3);
        let query = b"cargo";
        unsafe { slopdesk_prompt_search_type(handle, query.as_ptr(), query.len()) };
        let state = unsafe { slopdesk_prompt_state(handle) };
        assert_eq!(state.candidate_count, 2, "`ls` is out");
        assert!(state.searching);
        assert_eq!(state.search_matches, 2, "and the count agrees below the cap");
        // The rows cross through the CANDIDATE doors — the search has none of its own.
        assert_eq!(read_selected_row(handle), "cargo test");
        assert!(unsafe { slopdesk_prompt_search_again(handle) });
        assert_eq!(read_selected_row(handle), "cargo build --release");
        assert!(unsafe { slopdesk_prompt_search_back(handle) });
        assert_eq!(read_selected_row(handle), "cargo test");
        assert_eq!(read_text(handle), "", "the buffer is untouched while searching");
        assert!(unsafe { slopdesk_prompt_search_accept(handle) });
        assert_eq!(read_text(handle), "cargo test");
        let state = unsafe { slopdesk_prompt_state(handle) };
        assert!(!state.searching);
        assert_eq!(state.search_matches, 0, "and the count goes with the session");
        unsafe { slopdesk_prompt_free(handle) };
    }

    #[test]
    fn a_null_handle_answers_rather_than_faults() {
        let state = unsafe { slopdesk_prompt_state(std::ptr::null_mut()) };
        assert!(state.would_run);
        assert_eq!(state.text_len, 0);
        let length = unsafe { slopdesk_prompt_text(std::ptr::null_mut(), std::ptr::null_mut(), 0) };
        assert_eq!(length, 0);
        assert!(!unsafe { slopdesk_prompt_undo(std::ptr::null_mut()) });
        unsafe { slopdesk_prompt_free(std::ptr::null_mut()) };
    }
}
