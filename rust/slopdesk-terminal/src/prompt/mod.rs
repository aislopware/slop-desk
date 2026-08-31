//! The editor-like command prompt — `docs/68` §5.4, the half of the Warp-class terminal that is not
//! blocks.
//!
//! A shell's own prompt is `readline`: one line, one history, no selection, no undo worth the name,
//! and a cursor counted in bytes. Everything above the shell in this app already assumes better —
//! `slopdesk-termrender` lays out blocks with variable heights, and a block's header is a native
//! view. This module is what puts a real editor in front of them: multi-line text, a grapheme
//! cursor, UAX #29 words, selection, undo with coalescing, history with prefix search and ⌃R, fuzzy
//! completion, and shell-aware highlighting.
//!
//! ## What this owns, and what it refuses to own
//!
//! **The editor owns MEANING.** What the text is, where the caret is, what is selected, what is one
//! undo step, what would complete here, what colour each byte should be, and — the one rule that
//! decides whether Enter runs anything — whether the document is syntactically closed.
//!
//! **THE VIEW owns PLACE.** Where the text wraps, where the caret rectangle is in device pixels,
//! which colour a [`syntax::TokenKind`] maps to, and how the candidate list is drawn.
//!
//! ⚠️ THIS PARAGRAPH USED TO NAME `slopdesk-termrender`, and it was describing an architecture that
//! was never chosen. `docs/68` §5.4 puts the prompt inside the external input BOX — a sibling view
//! below the grid, doing its own text layout — and §10 puts "the candidate list's appearance" in
//! the view with the rest of the composition work. The renderer draws the terminal GRID; the prompt
//! is not on it, so there is no caret rectangle for the renderer to answer and no prompt layout for
//! it to grow. Corrected 2026-09-01 at the mount; `docs/DECISIONS.md` records why the inline
//! reading lost.
//!
//! The one thing that crosses is a byte offset, and the one conversion this module offers —
//! [`buffer::LineColumn`] — is in display CELLS through the same [`crate::link::text_cells`] every
//! other overlay measures with, so the caret and a link badge on one row cannot disagree about a
//! column.
//!
//! **The shell owns EXECUTION.** [`CommandEditor::submit`] answers a `String`; it does not write to
//! a PTY, does not know a PTY exists, and takes no view of what the command means. The bytes go out
//! through the same door they always did.
//!
//! ## Why this did not grow out of `InputBoxModel`, and why that is not a second implementation
//!
//! `docs/68` §5.4 reads "the Warp-class prompt is `ShellCommand` grown up", and the shape that
//! sentence suggests — bolt the editor onto [`crate::inputbox::InputBoxModel`] — is the wrong one.
//! [`crate::inputbox::InputAffordance::ShellCommand`] is a LABEL: it answers *which box to show*,
//! from the alt-screen tracker and nothing else. This module is the box's *contents*. They share no
//! state and no logic, so keeping them apart duplicates nothing; folding them together would make
//! one type answer "am I at a prompt" and "what is my third undo step", and every FFI caller of the
//! first would drag the second across the boundary with it.
//!
//! What the affordance still decides is which of this editor's faculties are live: under
//! [`crate::inputbox::InputAffordance::TuiCompose`] a fullscreen program owns the screen, so the
//! text is prose for an agent rather than a command line — the buffer, the undo stack and the
//! selection all apply, and the shell tokenizer does not. That is a caller's choice about which
//! methods to call, not a second mode inside the model.
//!
//! ## Guarantees
//!
//! No `unsafe` (the crate forbids it), no clock, no I/O, no panics on hostile input, and no floats
//! at all — a completion score is fzf's `i32`, so the repo's bit-exactness rule has nothing to bite
//! on here. A 10 MB paste, a line of 100 000 combining marks, and 100 000 nested `$(` are all
//! covered by tests in the modules that would break on them.

pub mod buffer;
pub mod complete;
pub mod history;
pub mod keys;
pub mod syntax;
pub mod undo;

use crate::prompt::buffer::{Motion, TextBuffer};
use crate::prompt::complete::{CandidateProvider, HistoryProvider, Ranked};
use crate::prompt::history::{CommandHistory, HistoryWalk, Recalled, ReverseSearch, SearchHit};
use crate::prompt::syntax::{Lexed, Unterminated, lex};
use crate::prompt::undo::{EditKind, UndoStack};

/// What pressing the submit key did.
///
/// Two outcomes rather than a `bool` plus a getter, because the caller has to do something
/// different with each: run the string, or draw the fact that the line grew instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Submission {
    /// The document was closed, so this is the command to run. Already recorded in the history, and
    /// the editor is empty again.
    Run(String),
    /// Something was still open, so the key inserted a newline. This is what is open — a quote, a
    /// `$(`, a trailing `\` — which is exactly what a hint under the prompt should name.
    Continued(Unterminated),
}

/// A live ⌃R session.
///
/// The searched line is NOT put into the buffer while the search runs. bash and zsh both show the
/// hit on a separate `(reverse-i-search)` line, and keeping the buffer untouched means cancelling
/// costs nothing and the undo stack never sees a step per keystroke of the query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchSession {
    search: ReverseSearch,
    hit: Option<SearchHit>,
}

impl SearchSession {
    /// The query typed so far.
    #[must_use]
    pub fn query(&self) -> &str {
        self.search.query()
    }

    /// The entry currently found, or `None` when nothing matches.
    #[must_use]
    pub const fn hit(&self) -> Option<&SearchHit> {
        self.hit.as_ref()
    }
}

/// The whole prompt: the text, its history, its undo stack and everything derived from them.
///
/// One type rather than five loose pieces because the interactions are the product. Typing has to
/// abandon a history walk, dismiss the completion list AND coalesce into the undo step; a caller
/// wiring those four together itself would get one of them wrong per platform.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandEditor {
    buffer: TextBuffer,
    undo: UndoStack,
    history: CommandHistory,
    walk: HistoryWalk,
    search: Option<SearchSession>,
    /// The lex of the current document, refreshed on every mutation.
    ///
    /// Eager rather than lazy: the highlighter asks for it on every frame anyway, so a cached copy
    /// is one scan per keystroke either way — and an eager one keeps every reader a `&self` method
    /// instead of forcing `&mut self` on a question as innocent as "what colour is this".
    lexed: Lexed,
    completion: Vec<Ranked>,
    selected: usize,
}

impl Default for CommandEditor {
    fn default() -> Self {
        Self::new()
    }
}

impl CommandEditor {
    /// An empty prompt with an empty history.
    #[must_use]
    pub fn new() -> Self {
        Self {
            buffer: TextBuffer::new(),
            undo: UndoStack::new(),
            history: CommandHistory::new(),
            walk: HistoryWalk::new(),
            search: None,
            lexed: lex(""),
            completion: Vec::new(),
            selected: 0,
        }
    }

    /// An empty prompt over a restored history.
    #[must_use]
    pub fn with_history(history: CommandHistory) -> Self {
        Self {
            history,
            ..Self::new()
        }
    }

    // ------------------------------------------------------------------ reading

    /// The document.
    #[must_use]
    pub fn text(&self) -> &str {
        self.buffer.text()
    }

    /// The text, caret and selection.
    #[must_use]
    pub const fn buffer(&self) -> &TextBuffer {
        &self.buffer
    }

    /// The caret's byte offset.
    #[must_use]
    pub const fn cursor(&self) -> usize {
        self.buffer.cursor()
    }

    /// The selected byte range, or `None`.
    #[must_use]
    pub const fn selection(&self) -> Option<core::ops::Range<usize>> {
        self.buffer.selection()
    }

    /// The highlight spans and shell words for the current document.
    #[must_use]
    pub const fn lexed(&self) -> &Lexed {
        &self.lexed
    }

    /// What the document currently leaves open — `Nothing` when Enter would run it.
    #[must_use]
    pub const fn unterminated(&self) -> Unterminated {
        self.lexed.unterminated
    }

    /// Whether the submit key would run the command rather than add a line.
    #[must_use]
    pub const fn would_run(&self) -> bool {
        self.lexed.unterminated.submits()
    }

    /// The command history, for a caller persisting it or building a [`HistoryProvider`].
    #[must_use]
    pub const fn history(&self) -> &CommandHistory {
        &self.history
    }

    /// The history, mutably — for a session restoring one entry at a time.
    pub const fn history_mut(&mut self) -> &mut CommandHistory {
        &mut self.history
    }

    /// The undo stack, for a menu that greys out its items.
    #[must_use]
    pub const fn undo_stack(&self) -> &UndoStack {
        &self.undo
    }

    /// The ⌃R session, if one is up.
    #[must_use]
    pub const fn search(&self) -> Option<&SearchSession> {
        self.search.as_ref()
    }

    /// The ranked candidates from the last [`CommandEditor::complete`], best first.
    #[must_use]
    pub fn candidates(&self) -> &[Ranked] {
        &self.completion
    }

    /// Which candidate is highlighted.
    #[must_use]
    pub const fn selected_candidate(&self) -> usize {
        self.selected
    }

    // ------------------------------------------------------------------ editing

    /// Types text at the caret, replacing the selection if there is one.
    ///
    /// One call per keystroke or per composed IME commit; the undo stack decides on its own whether
    /// that is a new step (see [`crate::prompt::undo`]).
    pub fn insert_text(&mut self, text: &str) {
        let kind = if self.buffer.selection().is_some() {
            EditKind::Replace
        } else {
            EditKind::Insert
        };
        let edit = self.buffer.insert(text);
        self.after_user_edit(edit, kind);
    }

    /// Inserts a newline WITHOUT submitting — the shift-Enter / option-Enter key.
    ///
    /// Separate from [`CommandEditor::submit`] rather than a flag on it, because they are different
    /// keys with different meanings and a caller that had to pass `submit(false)` would eventually
    /// pass the wrong one.
    pub fn insert_newline(&mut self) {
        self.insert_text("\n");
    }

    /// Drops a clipboard payload in. Always one undo step, however large.
    ///
    /// The DANGER question — would this run something the user cannot see — is
    /// [`crate::paste::should_warn`]'s, asked before this is called and never here. Two reasons it
    /// stays there: it is a question about the terminal's state (an alt screen, a bracketed-paste
    /// program) that this editor does not hold, and its answer is a confirmation sheet, which is
    /// `AppKit`. Nothing arrives at this door that the caller has not already decided to accept.
    pub fn paste(&mut self, text: &str) {
        let edit = self.buffer.insert(text);
        self.after_user_edit(edit, EditKind::Paste);
    }

    /// Deletes the selection, or the run between the caret and `motion`'s landing.
    ///
    /// Takes the same [`Motion`] as a movement so a word-deletion cannot disagree with a
    /// word-motion about where a word ends.
    pub fn delete(&mut self, motion: Motion) {
        let had_selection = self.buffer.selection().is_some();
        let Some(edit) = self.buffer.delete(motion) else {
            return;
        };
        let kind = if had_selection {
            EditKind::Replace
        } else {
            EditKind::Delete
        };
        self.after_user_edit(edit, kind);
    }

    /// Replaces a byte range outright — the door a completion acceptance and a spelling correction
    /// both go through. One undo step.
    pub fn replace_range(&mut self, range: core::ops::Range<usize>, text: &str) {
        let edit = self.buffer.replace_range(range, text);
        self.after_user_edit(edit, EditKind::Paste);
    }

    /// Empties the prompt, forgetting the undo history with it.
    ///
    /// The undo stack goes because its steps are offsets into a document that no longer exists —
    /// see [`crate::prompt::undo`] for why an operation cannot outlive its buffer.
    pub fn clear(&mut self) {
        self.buffer = TextBuffer::new();
        self.undo.clear();
        self.walk.reset();
        self.search = None;
        self.dismiss_completion();
        self.refresh();
    }

    // ------------------------------------------------------------------ moving

    /// Moves the caret, dropping the selection.
    pub fn move_to(&mut self, motion: Motion) {
        self.buffer.move_by(motion);
        self.after_navigation();
    }

    /// Moves the caret, keeping the anchor — a shift-arrow.
    pub fn extend_to(&mut self, motion: Motion) {
        self.buffer.extend_by(motion);
        self.after_navigation();
    }

    /// Puts the caret at a byte offset, snapped to a grapheme boundary. A click.
    pub fn set_cursor(&mut self, offset: usize) {
        self.buffer.set_cursor(offset);
        self.after_navigation();
    }

    /// Selects a byte range. A drag, or a double-click's word.
    pub fn set_selection(&mut self, anchor: usize, head: usize) {
        self.buffer.set_selection(anchor, head);
        self.after_navigation();
    }

    /// Selects everything.
    pub fn select_all(&mut self) {
        self.buffer.select_all();
        self.after_navigation();
    }

    // ------------------------------------------------------------------ clipboard

    /// The selected text, for the caller to put on the pasteboard.
    ///
    /// The editor does not touch a pasteboard: that is an Apple framework, this crate has no
    /// `unsafe` and no I/O, and the same selection has to reach an `NSPasteboard` on macOS and a
    /// `UIPasteboard` on iOS. `None` when nothing is selected — copy with an empty selection must
    /// not blank the clipboard.
    #[must_use]
    pub fn copy(&self) -> Option<String> {
        self.buffer
            .selection()
            .map(|_| self.buffer.selected_text().to_owned())
    }

    /// The selected text, removed. One undo step.
    pub fn cut(&mut self) -> Option<String> {
        let taken = self.copy()?;
        self.delete(Motion::Grapheme(buffer::Direction::Forward));
        Some(taken)
    }

    // ------------------------------------------------------------------ undo

    /// Walks one step back. `false` when there was nothing to undo.
    pub fn undo(&mut self) -> bool {
        let moved = self.undo.undo(&mut self.buffer);
        if moved {
            self.walk.reset();
            self.dismiss_completion();
            self.refresh();
        }
        moved
    }

    /// Replays one undone step. `false` when there was nothing to redo.
    pub fn redo(&mut self) -> bool {
        let moved = self.undo.redo(&mut self.buffer);
        if moved {
            self.walk.reset();
            self.dismiss_completion();
            self.refresh();
        }
        moved
    }

    // ------------------------------------------------------------------ history

    /// ↑ — the previous history entry whose start matches the text before the caret.
    ///
    /// `false` when there is no older match, so the caller can pass the key to the surface instead
    /// of swallowing it in a prompt that did not move.
    pub fn history_previous(&mut self) -> bool {
        let text = self.buffer.text().to_owned();
        let cursor = self.buffer.cursor();
        let Some(recalled) = self.walk.previous(&self.history, &text, cursor) else {
            return false;
        };
        self.apply_recall(&recalled);
        true
    }

    /// ↓ — the next match, and past the newest, the draft the walk was started from.
    pub fn history_next(&mut self) -> bool {
        let Some(recalled) = self.walk.next(&self.history) else {
            return false;
        };
        self.apply_recall(&recalled);
        true
    }

    /// Whether ↑ has been pressed and ↓ still owes a draft.
    #[must_use]
    pub const fn is_walking_history(&self) -> bool {
        self.walk.is_walking()
    }

    /// A recall replaces the whole document, and is recorded as an ordinary edit.
    ///
    /// Recorded rather than silent because an undo step is an offset into the document it was taken
    /// against: leaving the stack alone while the text was swapped underneath it would make the
    /// next undo splice bytes at an offset that means something else now.
    fn apply_recall(&mut self, recalled: &Recalled) {
        let edit = self.buffer.replace_range(0..self.buffer.len(), recalled.text());
        self.undo.push(edit, EditKind::Paste);
        self.dismiss_completion();
        self.refresh();
    }

    // ------------------------------------------------------------------ reverse search

    /// Opens a ⌃R session with an empty query, which shows the newest command.
    pub fn begin_reverse_search(&mut self) {
        let mut search = ReverseSearch::new();
        let hit = search.refine(&self.history, "");
        self.search = Some(SearchSession { search, hit });
        self.walk.reset();
        self.dismiss_completion();
    }

    /// Adds to the ⌃R query and re-searches from the newest entry. A no-op when no session is up.
    pub fn reverse_search_type(&mut self, text: &str) {
        let Some(session) = self.search.as_mut() else {
            return;
        };
        let mut query = session.search.query().to_owned();
        query.push_str(text);
        session.hit = session.search.refine(&self.history, &query);
    }

    /// Removes the last grapheme of the ⌃R query and re-searches.
    pub fn reverse_search_backspace(&mut self) {
        let Some(session) = self.search.as_mut() else {
            return;
        };
        let query = session.search.query();
        let shortened = query
            .get(..buffer::prev_grapheme(query, query.len()))
            .unwrap_or("")
            .to_owned();
        session.hit = session.search.refine(&self.history, &shortened);
    }

    /// ⌃R again — one match older. `false` at the oldest, which holds rather than wrapping.
    pub fn reverse_search_again(&mut self) -> bool {
        let Some(session) = self.search.as_mut() else {
            return false;
        };
        match session.search.again(&self.history) {
            Some(found) => {
                session.hit = Some(found);
                true
            },
            None => false,
        }
    }

    /// Accepts the current ⌃R hit into the buffer and closes the session.
    ///
    /// `false` when there is no session or no hit, in which case the buffer is untouched.
    pub fn reverse_search_accept(&mut self) -> bool {
        let Some(session) = self.search.take() else {
            return false;
        };
        let Some(hit) = session.hit else {
            return false;
        };
        let edit = self.buffer.replace_range(0..self.buffer.len(), &hit.text);
        self.undo.push(edit, EditKind::Paste);
        self.refresh();
        true
    }

    /// Closes a ⌃R session without touching the buffer.
    pub fn reverse_search_cancel(&mut self) {
        self.search = None;
    }

    // ------------------------------------------------------------------ completion

    /// Ranks `providers`' candidates for the caret, plus this editor's own history, and keeps the
    /// list.
    ///
    /// The history provider is supplied here rather than by the caller because the history is the
    /// editor's; a caller assembling it would have to borrow the editor immutably while calling a
    /// `&mut` method on it.
    pub fn complete(&mut self, providers: &[&dyn CandidateProvider], limit: usize) -> usize {
        let history = HistoryProvider::new(&self.history);
        let mut sources: Vec<&dyn CandidateProvider> = Vec::with_capacity(providers.len() + 1);
        sources.push(&history);
        sources.extend_from_slice(providers);
        let ranked = complete::complete(self.buffer.text(), self.buffer.cursor(), &sources, limit);
        self.completion = ranked;
        self.selected = 0;
        self.completion.len()
    }

    /// Highlights the next candidate, wrapping. A no-op with no candidates.
    ///
    /// Wrapping here and NOT in ⌃R is deliberate: a completion list is on screen with a visible
    /// end, so coming back round is obvious, where a reverse search's position is invisible.
    pub const fn select_next_candidate(&mut self) {
        if self.completion.is_empty() {
            return;
        }
        self.selected = self.selected.saturating_add(1) % self.completion.len();
    }

    /// Highlights the previous candidate, wrapping.
    pub const fn select_previous_candidate(&mut self) {
        let Some(last) = self.completion.len().checked_sub(1) else {
            return;
        };
        self.selected = if self.selected == 0 {
            last
        } else {
            self.selected - 1
        };
    }

    /// Applies the highlighted candidate over the range it declared. `false` with no candidates.
    pub fn accept_completion(&mut self) -> bool {
        let Some(chosen) = self
            .completion
            .get(self.selected)
            .map(|hit| hit.candidate.clone())
        else {
            return false;
        };
        self.replace_range(chosen.replace, &chosen.insert);
        true
    }

    /// Drops the candidate list.
    pub fn dismiss_completion(&mut self) {
        self.completion.clear();
        self.selected = 0;
    }

    // ------------------------------------------------------------------ submit

    /// The submit key.
    ///
    /// Runs the command when the document is syntactically closed, and otherwise inserts a newline
    /// and reports what is still open. The rule is [`syntax::Unterminated::submits`] and lives in
    /// the lexer, so the colours on screen and the decision this key makes come from the same scan
    /// — an unterminated quote that is painted as a string is one that will not run, always.
    pub fn submit(&mut self) -> Submission {
        let open = self.lexed.unterminated;
        if !open.submits() {
            self.insert_newline();
            return Submission::Continued(open);
        }
        let command = self.buffer.text().to_owned();
        self.history.record(&command);
        self.clear();
        Submission::Run(command)
    }

    // ------------------------------------------------------------------ interior

    /// Every path that changed the document lands here: the walk is abandoned, the candidate list
    /// is stale, and the lex has to be retaken.
    fn after_user_edit(&mut self, edit: undo::Edit, kind: EditKind) {
        self.walk.reset();
        self.dismiss_completion();
        self.undo.push(edit, kind);
        self.refresh();
    }

    /// Every path that moved the caret without changing a byte. It closes the undo run — typing,
    /// clicking elsewhere, then typing again is two steps, not one — and drops the candidate list,
    /// whose replacement ranges were computed for the old caret.
    fn after_navigation(&mut self) {
        self.undo.break_run();
        self.dismiss_completion();
    }

    fn refresh(&mut self) {
        self.lexed = lex(self.buffer.text());
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CommandEditor, Submission};
    use crate::prompt::buffer::Direction::{Backward, Forward};
    use crate::prompt::buffer::Motion;
    use crate::prompt::complete::{CandidateProvider, PathEntry, PathProvider};
    use crate::prompt::syntax::{TokenKind, Unterminated};

    fn typed(text: &str) -> CommandEditor {
        let mut editor = CommandEditor::new();
        for ch in text.chars() {
            editor.insert_text(&ch.to_string());
        }
        editor
    }

    #[test]
    fn a_closed_line_runs_and_lands_in_the_history() {
        let mut editor = typed("ls -la");
        assert!(editor.would_run());
        assert_eq!(editor.submit(), Submission::Run("ls -la".to_owned()));
        assert!(editor.text().is_empty());
        assert_eq!(editor.history().entries(), ["ls -la"]);
        assert!(!editor.undo_stack().can_undo(), "the new prompt has no past");
    }

    #[test]
    fn an_open_quote_grows_a_line_instead_of_running() {
        let mut editor = typed("echo 'hello");
        assert!(!editor.would_run());
        assert_eq!(editor.submit(), Submission::Continued(Unterminated::SingleQuote));
        assert_eq!(editor.text(), "echo 'hello\n");
        // Closing it makes the very next Enter run the whole thing, newline and all.
        editor.insert_text("world'");
        assert_eq!(editor.submit(), Submission::Run("echo 'hello\nworld'".to_owned()));
    }

    #[test]
    fn a_trailing_backslash_continues_the_line() {
        let mut editor = typed("ls \\");
        assert_eq!(editor.submit(), Submission::Continued(Unterminated::Backslash));
        assert_eq!(editor.text(), "ls \\\n");
        editor.insert_text("-la");
        assert!(editor.would_run());
    }

    #[test]
    fn an_open_substitution_continues_and_shift_enter_never_submits() {
        let mut editor = typed("echo $(date");
        assert_eq!(editor.submit(), Submission::Continued(Unterminated::Substitution));
        editor.insert_text(")");
        assert!(editor.would_run());
        // The explicit newline key adds a line even when the document would have run.
        editor.insert_newline();
        assert_eq!(editor.text(), "echo $(date\n)\n");
    }

    #[test]
    fn a_blank_submit_runs_nothing_and_records_nothing() {
        let mut editor = CommandEditor::new();
        assert_eq!(editor.submit(), Submission::Run(String::new()));
        assert!(editor.history().is_empty());
    }

    #[test]
    fn the_highlight_follows_the_text_without_being_asked() {
        let mut editor = typed("git commit");
        assert_eq!(editor.lexed().spans[0].kind, TokenKind::CommandName);
        editor.insert_text(" --amend");
        let spans = &editor.lexed().spans;
        assert_eq!(spans[spans.len() - 1].kind, TokenKind::Flag);
    }

    #[test]
    fn typing_is_one_undo_step_and_a_click_between_two_bursts_makes_two() {
        let mut editor = typed("hello");
        assert!(editor.undo());
        assert!(editor.text().is_empty());
        assert!(editor.redo());
        assert_eq!(editor.text(), "hello");

        editor.set_cursor(0);
        editor.insert_text("X");
        assert!(editor.undo());
        assert_eq!(editor.text(), "hello", "only the second burst went");
    }

    #[test]
    fn undo_after_a_history_recall_gives_the_typed_line_back() {
        let mut editor = typed("first");
        editor.submit();
        let mut editor = CommandEditor::with_history(editor.history().clone());
        editor.insert_text("fi");
        assert!(editor.history_previous());
        assert_eq!(editor.text(), "first");
        assert!(editor.undo());
        assert_eq!(editor.text(), "fi", "the recall was an edit like any other");
    }

    #[test]
    fn up_searches_by_the_typed_prefix_and_down_restores_the_draft() {
        let mut editor = CommandEditor::new();
        for command in ["git status", "ls -la", "git commit"] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.insert_text("git");
        assert!(editor.history_previous());
        assert_eq!(editor.text(), "git commit");
        assert!(editor.history_previous());
        assert_eq!(editor.text(), "git status", "`ls -la` does not match the prefix");
        assert!(!editor.history_previous(), "and the oldest match is a wall");

        assert!(editor.history_next());
        assert_eq!(editor.text(), "git commit");
        assert!(editor.history_next());
        assert_eq!(editor.text(), "git", "the draft is back");
        assert!(!editor.is_walking_history());
    }

    #[test]
    fn typing_abandons_the_walk_so_down_no_longer_owes_a_draft() {
        let mut editor = CommandEditor::new();
        editor.insert_text("one");
        editor.submit();
        editor.insert_text("dr");
        editor.history_previous();
        editor.insert_text("x");
        assert!(!editor.is_walking_history());
        assert!(!editor.history_next());
    }

    #[test]
    fn reverse_search_walks_without_touching_the_buffer_until_it_is_accepted() {
        let mut editor = CommandEditor::new();
        for command in ["cargo build", "ls", "cargo test"] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.insert_text("draft");

        editor.begin_reverse_search();
        assert_eq!(editor.search().unwrap().hit().unwrap().text, "cargo test");
        editor.reverse_search_type("cargo");
        assert_eq!(editor.search().unwrap().hit().unwrap().text, "cargo test");
        assert!(editor.reverse_search_again());
        assert_eq!(editor.search().unwrap().hit().unwrap().text, "cargo build");
        assert!(!editor.reverse_search_again(), "the oldest match holds");
        assert_eq!(editor.text(), "draft", "the line is untouched while searching");

        assert!(editor.reverse_search_accept());
        assert_eq!(editor.text(), "cargo build");
        assert!(editor.search().is_none());
        assert!(editor.undo(), "and it is one undo step");
        assert_eq!(editor.text(), "draft");
    }

    #[test]
    fn a_cancelled_reverse_search_leaves_the_line_alone() {
        let mut editor = CommandEditor::new();
        editor.insert_text("ls");
        editor.submit();
        editor.insert_text("draft");
        editor.begin_reverse_search();
        editor.reverse_search_type("l");
        editor.reverse_search_cancel();
        assert_eq!(editor.text(), "draft");
        assert!(editor.search().is_none());
        // And the doors are all no-ops with no session up.
        editor.reverse_search_type("x");
        editor.reverse_search_backspace();
        assert!(!editor.reverse_search_again());
        assert!(!editor.reverse_search_accept());
    }

    #[test]
    fn backspacing_the_search_query_widens_it_again() {
        let mut editor = CommandEditor::new();
        for command in ["make all", "make docs"] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.begin_reverse_search();
        editor.reverse_search_type("make d");
        assert_eq!(editor.search().unwrap().hit().unwrap().text, "make docs");
        editor.reverse_search_backspace();
        editor.reverse_search_backspace();
        assert_eq!(editor.search().unwrap().query(), "make");
        assert_eq!(editor.search().unwrap().hit().unwrap().text, "make docs");
    }

    #[test]
    fn accepting_a_completion_replaces_exactly_the_range_it_declared() {
        let files = vec![PathEntry {
            name: "main.rs".to_owned(),
            directory: false,
        }];
        let provider = PathProvider::new("src/", &files);
        let providers: [&dyn CandidateProvider; 1] = [&provider];

        let mut editor = typed("cat src/ma");
        assert!(editor.complete(&providers, 10) > 0);
        assert_eq!(editor.candidates()[0].candidate.text, "src/main.rs");
        assert!(editor.accept_completion());
        assert_eq!(editor.text(), "cat src/main.rs");
        assert_eq!(editor.cursor(), 15);
        assert!(editor.candidates().is_empty(), "accepting dismisses the list");
        assert!(editor.undo(), "and it is one undo step");
        assert_eq!(editor.text(), "cat src/ma");
    }

    #[test]
    fn completion_offers_the_editors_own_history_without_being_handed_it() {
        let mut editor = CommandEditor::new();
        editor.insert_text("cargo test --lib");
        editor.submit();
        editor.insert_text("car");
        assert!(editor.complete(&[], 10) > 0);
        assert_eq!(editor.candidates()[0].candidate.text, "cargo test --lib");
        assert!(editor.accept_completion());
        assert_eq!(editor.text(), "cargo test --lib");
    }

    #[test]
    fn the_candidate_selection_wraps_in_both_directions() {
        let mut editor = CommandEditor::new();
        for command in ["a1", "a2", "a3"] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.insert_text("a");
        assert_eq!(editor.complete(&[], 10), 3);
        assert_eq!(editor.selected_candidate(), 0);
        editor.select_previous_candidate();
        assert_eq!(editor.selected_candidate(), 2, "wrapped backwards");
        editor.select_next_candidate();
        assert_eq!(editor.selected_candidate(), 0, "and forwards");
    }

    #[test]
    fn selecting_a_candidate_with_an_empty_list_does_nothing() {
        let mut editor = CommandEditor::new();
        editor.select_next_candidate();
        editor.select_previous_candidate();
        assert_eq!(editor.selected_candidate(), 0);
        assert!(!editor.accept_completion());
    }

    #[test]
    fn typing_dismisses_a_stale_candidate_list() {
        let mut editor = CommandEditor::new();
        editor.insert_text("ls -la");
        editor.submit();
        editor.insert_text("l");
        assert!(editor.complete(&[], 10) > 0);
        editor.insert_text("s");
        assert!(editor.candidates().is_empty());
    }

    #[test]
    fn selection_survives_a_copy_and_is_consumed_by_a_cut() {
        let mut editor = typed("hello world");
        editor.set_selection(6, 11);
        assert_eq!(editor.copy().as_deref(), Some("world"));
        assert_eq!(editor.text(), "hello world", "copy changes nothing");
        assert_eq!(editor.cut().as_deref(), Some("world"));
        assert_eq!(editor.text(), "hello ");
        assert_eq!(editor.copy(), None, "and there is nothing selected now");
        assert!(editor.undo());
        assert_eq!(editor.text(), "hello world");
        assert_eq!(editor.selection(), Some(6..11), "the cut selection comes back");
    }

    #[test]
    fn typing_over_a_selection_replaces_it_in_one_step() {
        let mut editor = typed("hello world");
        editor.set_selection(0, 5);
        editor.insert_text("bye");
        assert_eq!(editor.text(), "bye world");
        assert!(editor.undo());
        assert_eq!(editor.text(), "hello world");
    }

    #[test]
    fn multi_line_editing_moves_by_line_and_by_word() {
        let mut editor = typed("one two");
        editor.insert_newline();
        editor.insert_text("three four");
        assert_eq!(editor.buffer().line_count(), 2);
        editor.move_to(Motion::DocEdge(Backward));
        editor.move_to(Motion::Line(Forward));
        assert_eq!(editor.buffer().caret().line, 1);
        editor.move_to(Motion::LineEdge(Forward));
        editor.delete(Motion::Word(Backward));
        assert_eq!(editor.text(), "one two\nthree ");
    }

    #[test]
    fn a_ten_megabyte_paste_is_one_step_and_leaves_the_editor_usable() {
        let paste = "x".repeat(10 * 1024 * 1024);
        let mut editor = typed("echo ");
        editor.paste(&paste);
        assert_eq!(editor.text().len(), 5 + paste.len());
        assert!(editor.would_run());
        assert_eq!(editor.lexed().words.len(), 2);
        assert!(editor.undo());
        assert_eq!(editor.text(), "echo ");
    }

    #[test]
    fn hostile_text_never_wedges_the_editor() {
        for hostile in ["$(".repeat(1000), "\"'`\\".to_owned(), "\u{0}\u{7f}".to_owned()] {
            let mut editor = CommandEditor::new();
            editor.paste(&hostile);
            let _submission = editor.submit();
            editor.move_to(Motion::Word(Forward));
            editor.move_to(Motion::Word(Backward));
            editor.delete(Motion::Word(Backward));
            assert!(editor.undo() || editor.text().is_empty());
        }
    }
}
