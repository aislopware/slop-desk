//! The editor-like command prompt — `docs/68` §5.4, the half of the Warp-class terminal that is not
//! blocks.
//!
//! A shell's own prompt is `readline`: one line, one history, no selection, no undo worth the name,
//! and a cursor counted in bytes. Everything above the shell in this app already assumes better —
//! `slopdesk-termrender` lays out blocks with variable heights, and a block's header is a native
//! view. This module is what puts a real editor in front of them: multi-line text, a grapheme
//! cursor, UAX #29 words, selection, undo with coalescing, history with prefix search and ⌃R, fuzzy
//! completion, shell-aware highlighting, and the inline autosuggestion a `zsh` user installs a
//! plugin for.
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
pub mod validity;

use core::ops::Range;

use crate::prompt::buffer::{Granularity, Motion, TextBuffer};
use crate::prompt::complete::{CandidateProvider, HistoryProvider, Ranked};
use crate::prompt::history::{CommandHistory, HistoryWalk, Recalled, suggestion_word_len};
use crate::prompt::syntax::{Lexed, SyntaxSpan, Unterminated, lex};
use crate::prompt::undo::{EditKind, UndoStack};
use crate::prompt::validity::CommandValidity;

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

/// A live ⌃R session — which is now nothing but the query.
///
/// The searched line is NOT put into the buffer while the search runs. bash and zsh both show the
/// hit on a separate `(reverse-i-search)` line, and keeping the buffer untouched means cancelling
/// costs nothing and the undo stack never sees a step per keystroke of the query.
///
/// ⚠️ **THE RESULTS ARE THE CANDIDATE LIST**, and that invariant is what this type does not hold:
/// while a session is up, [`CommandEditor::candidates`] holds
/// [`complete::search_history`]'s ranked entries and [`CommandEditor::selected_candidate`] is the
/// row the user is on. That is not a shortcut — a ⌃R hit and a completion candidate are the same
/// record down to the field (text, what it inserts, the whole range it replaces, the matched
/// positions the underline draws), so a second list would be the same shape crossing the FFI
/// through a second set of doors and drawn by a second copy of the panel code. What follows from
/// it: the search methods below are the ONLY writers of that list while a session is up, and
/// [`CommandEditor::complete`] refuses outright rather than racing them.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SearchSession {
    query: String,
    matched: usize,
}

impl SearchSession {
    /// The query typed so far.
    #[must_use]
    pub fn query(&self) -> &str {
        &self.query
    }

    /// How many history entries the query matched — including the ones the panel's cap cut.
    ///
    /// The one number the candidate list cannot carry, and so the one thing this type holds beyond
    /// the query: [`CommandEditor::candidates`] holds what FITS, and a list truncated at
    /// [`complete::LIMIT`] is indistinguishable from a complete one.
    #[must_use]
    pub const fn matched(&self) -> usize {
        self.matched
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
    /// What the host has said about the command words typed since the last run — the one colour
    /// this editor cannot derive from the text. See [`validity`].
    validity: CommandValidity,
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
            validity: CommandValidity::new(),
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
    pub const fn selection(&self) -> Option<Range<usize>> {
        self.buffer.selection()
    }

    /// The highlight spans and shell words for the current document, as the LEXER read them.
    ///
    /// The raw scan. What a view should paint is [`CommandEditor::spans`], which is this plus the
    /// one fact the lexer cannot know.
    #[must_use]
    pub const fn lexed(&self) -> &Lexed {
        &self.lexed
    }

    /// What to PAINT: [`CommandEditor::lexed`]'s spans with every command name the host said the
    /// shell cannot find re-kinded to [`syntax::TokenKind::UnknownCommand`].
    ///
    /// Same count, same boundaries, same order as `lexed().spans` — the overlay only ever rewrites
    /// a kind — so a caller that already sized a buffer from the span count does not resize.
    #[must_use]
    pub fn spans(&self) -> Vec<SyntaxSpan> {
        validity::overlaid(self.buffer.text(), &self.lexed, &self.validity)
    }

    /// The command words of the current document that nothing has answered for yet — what to ask
    /// the host about, empty when there is nothing to ask.
    #[must_use]
    pub fn unanswered_commands(&self) -> Vec<String> {
        validity::unanswered(self.buffer.text(), &self.lexed, &self.validity)
    }

    /// The generation to quote when asking, and to hand back with the answer.
    #[must_use]
    pub const fn verdict_generation(&self) -> u64 {
        self.validity.generation()
    }

    /// Takes one answer from the host: the shell can (or cannot) find `word`.
    ///
    /// Dropped unless `generation` is still [`CommandEditor::verdict_generation`] — see
    /// [`validity::CommandValidity::record`] for why an answer that outlived its question is worse
    /// than no answer.
    pub fn record_verdict(&mut self, word: &str, resolves: bool, generation: u64) {
        self.validity.record(word, resolves, generation);
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
    pub fn replace_range(&mut self, range: Range<usize>, text: &str) {
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

    /// Places the caret or selects a run from a pointer gesture — a click, a drag, a double- or
    /// triple-click, all through one door.
    ///
    /// ⚠️ **A pointer landing in the document CANCELS an open ⌃R session.** That is `fish`'s rule —
    /// touching the command line closes the pager — and it is the only coherent one here: the
    /// document under an open search is the DRAFT, not the row the user is reading, so a caret
    /// placed in it while the panel stayed up would point at text the next Enter was going to
    /// replace. [`CommandEditor::reverse_search_cancel`] hands the draft back untouched, so the
    /// click costs the search and nothing else.
    ///
    /// The candidate list goes the same way every other navigation takes it — see
    /// [`CommandEditor::after_navigation`], whose replacement ranges were computed for the old
    /// caret. A click on a candidate ROW must therefore never come through here; that is
    /// [`CommandEditor::select_candidate`], which leaves the list alone.
    pub fn pointer_select(&mut self, anchor: usize, head: usize, granularity: Granularity) {
        self.reverse_search_cancel();
        let anchor = buffer::snap(self.buffer.text(), anchor);
        let head = buffer::snap(self.buffer.text(), head);
        // Each end is expanded to its OWN unit and the union taken, which is what makes dragging
        // back past the press keep the pressed word whole rather than shrinking it to the byte
        // under the pointer. `Caret`'s unit is the empty range, so a click needs no special case:
        // it is a drag of length nought through the same arithmetic.
        let from = self.unit(anchor, granularity);
        let to = self.unit(head, granularity);
        let (anchor, head) = if head >= anchor {
            (from.start.min(to.start), to.end.max(from.end))
        } else {
            (from.end.max(to.end), to.start.min(from.start))
        };
        self.buffer.set_selection(anchor, head);
        self.after_navigation();
    }

    /// What a `granularity` gesture at `offset` selects a whole one of.
    ///
    /// ⚠️ **A word is the SHELL's word, not UAX #29's**, and that is the one place this prompt
    /// should beat a general-purpose text field. On a command line the thing the user pointed at is
    /// the argument: `--oneline` is a flag and not `--` plus `oneline`, `~/src/main.rs` is a path
    /// and not five segments, and `"two words"` is one quoted argument. The lex that colours those
    /// runs already knows where each one starts and ends, so a double-click asks IT — no second
    /// definition of a word, and no "word characters" preference of the kind `Terminal.app` makes
    /// people configure.
    ///
    /// [`buffer::Granularity::unit`] answers for every offset the lex has no word at: whitespace,
    /// an operator, and prose under [`crate::inputbox::InputAffordance::TuiCompose`], where UAX #29
    /// is the right rule because there is no shell syntax to respect.
    fn unit(&self, offset: usize, granularity: Granularity) -> Range<usize> {
        if let Some(word) = self
            .lexed
            .words
            .iter()
            .find(|word| granularity == Granularity::Word && word.start <= offset && offset < word.end)
        {
            return word.range();
        }
        granularity.unit(self.buffer.text(), offset)
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

    /// Opens a ⌃R session with an empty query, which lists the most recent commands.
    ///
    /// The panel opens FULL rather than empty — an empty query matches everything (see
    /// [`complete::search_history`]) — which is what `fzf`'s ⌃R and `atuin` both do and is the
    /// whole difference from the `(reverse-i-search)` line this replaced: the first press
    /// already shows the answer for the common case, "the thing I ran a minute ago".
    pub fn begin_reverse_search(&mut self) {
        self.search = Some(SearchSession::default());
        self.walk.reset();
        self.research();
    }

    /// Adds to the ⌃R query and re-ranks. A no-op when no session is up.
    pub fn reverse_search_type(&mut self, text: &str) {
        let Some(session) = self.search.as_mut() else {
            return;
        };
        session.query.push_str(text);
        self.research();
    }

    /// Removes the last grapheme of the ⌃R query and re-ranks.
    pub fn reverse_search_backspace(&mut self) {
        let Some(session) = self.search.as_mut() else {
            return;
        };
        let end = buffer::prev_grapheme(&session.query, session.query.len());
        session.query.truncate(end);
        self.research();
    }

    /// ⌃R again — one row further down the panel, wrapping. `false` when no session is up or the
    /// query matched nothing.
    ///
    /// ⚠️ **IT WRAPS NOW, and the sentence that used to forbid it argued for this.**
    /// [`CommandEditor::select_next_candidate`] reads "wrapping here and NOT in ⌃R is deliberate: a
    /// completion list is on screen with a visible end, so coming back round is obvious, where a
    /// reverse search's position is invisible." The ⌃R position is on screen now, so the rule that
    /// sentence states puts it on the same side as the completion list rather than the other one.
    pub const fn reverse_search_again(&mut self) -> bool {
        if self.search.is_none() || self.completion.is_empty() {
            return false;
        }
        self.select_next_candidate();
        true
    }

    /// ⌃R backwards — one row up the panel, wrapping. The `fish` pager's ⌃S, and what ↑ does while
    /// the panel is up.
    pub const fn reverse_search_back(&mut self) -> bool {
        if self.search.is_none() || self.completion.is_empty() {
            return false;
        }
        self.select_previous_candidate();
        true
    }

    /// Accepts the selected row into the buffer. **Closes the session either way**, and answers
    /// whether the buffer changed — `false` also means it was left alone.
    ///
    /// Closing on an empty panel is deliberate. The alternative leaves Enter inert until the user
    /// finds Esc, and a key that visibly does nothing reads as a wedged prompt; a query that
    /// matched nothing has already told the user everything it can, so the useful thing left to
    /// do with it is get out of the way and hand back the draft, untouched. It is also what the
    /// single-hit search this replaced did, so the reversal changed the panel and not this.
    ///
    /// ⚠️ **IT DOES NOT RUN THE COMMAND**, and that is a decision rather than an omission. `fish`'s
    /// pager puts the entry on the command line for a second Enter; `atuin` runs it outright and
    /// makes people configure that back (its own docs offer `enter = return-selection` for exactly
    /// this). This crate's bridge header already states the tie-break — "a missing candidate costs
    /// a completion, and a wrong one writes the user's command line for them" — and a wrong one
    /// RUN is strictly worse than a wrong one written. So `Run` stays the submit key's, pressed
    /// against a line the user can see.
    pub fn reverse_search_accept(&mut self) -> bool {
        if self.search.take().is_none() {
            return false;
        }
        if self.accept_completion() {
            return true;
        }
        self.dismiss_completion();
        false
    }

    /// Closes a ⌃R session without touching the buffer, taking its panel with it.
    pub fn reverse_search_cancel(&mut self) {
        self.search = None;
        self.dismiss_completion();
    }

    /// Re-ranks the open session's query into the candidate list. The one writer of that list while
    /// a search is up, which is the invariant [`SearchSession`] documents.
    fn research(&mut self) {
        // Taken and put back rather than borrowed, so the query can be read while the editor's own
        // history is — and so the total lands on the session in the same statement it is computed.
        let Some(mut session) = self.search.take() else {
            return;
        };
        let found =
            complete::search_history(&self.history, &session.query, complete::LIMIT, self.buffer.len());
        session.matched = found.matched;
        self.completion = found.ranked;
        self.selected = 0;
        self.search = Some(session);
    }

    // ------------------------------------------------------------------ completion

    /// Ranks `providers`' candidates for the caret, plus this editor's own history, and keeps the
    /// list.
    ///
    /// The history provider is supplied here rather than by the caller because the history is the
    /// editor's; a caller assembling it would have to borrow the editor immutably while calling a
    /// `&mut` method on it.
    ///
    /// ⚠️ **Refuses outright while a ⌃R session is up**, answering the panel's own row count. The
    /// list belongs to the search then (see [`SearchSession`]), and a caller that recompletes on a
    /// redraw — which both platforms do — would otherwise replace the search's rows with candidates
    /// for a caret nobody moved, halfway through a query. The guard is here rather than at the two
    /// call sites for the reason every other rule in this module is: spelled twice in Swift, it
    /// would eventually be spelled differently.
    pub fn complete(&mut self, providers: &[&dyn CandidateProvider], limit: usize) -> usize {
        if self.search.is_some() {
            return self.completion.len();
        }
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
    /// Wrapping because the list is ON SCREEN with a visible end, so coming back round is obvious.
    /// ⌃R used to be the counter-example — its position was invisible, so it stopped at the oldest
    /// match rather than wrapping — and it is not one any more: the panel it draws now is this
    /// list, and [`CommandEditor::reverse_search_again`] is this method.
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

    /// Highlights the candidate at `index` — a click on a row. `false` when there is no such row.
    ///
    /// One method for both panels, with no fork on whether a ⌃R session is up, because there is one
    /// list: [`CommandEditor::research`] writes `self.completion` while a search is open exactly as
    /// [`CommandEditor::complete`] writes it while one is not, and `self.selected` indexes
    /// whichever wrote it. What differs is only what ACCEPTING does, which is already two doors
    /// ([`CommandEditor::accept_completion`] and [`CommandEditor::reverse_search_accept`]) chosen
    /// by the same `searching` flag the state record already carries to the view.
    pub const fn select_candidate(&mut self, index: usize) -> bool {
        if index >= self.completion.len() {
            return false;
        }
        self.selected = index;
        true
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

    // ------------------------------------------------------------------ suggestion

    /// What the newest matching history entry would ADD past the caret — the inline autosuggestion.
    ///
    /// `zsh-autosuggestions` in one method, and unlike that plugin it costs the shell nothing: the
    /// history is already here, so this is a prefix scan over at most
    /// [`history::CAPACITY`] strings and no state at all — see the module header for why holding a
    /// position would only give every editing path something new to forget to reset.
    ///
    /// **Five suppressions, and every one of them is a case where the ghost would be a lie about
    /// where the text would go.** The ghost is drawn AT the caret and accepted by appending, so it
    /// is only ever truthful when appending is what an accept would do:
    ///  * a ⌃R session is up — that row is already showing a history entry, and a second one
    ///    proposed from the line underneath it would be two answers to one question;
    ///  * a candidate list is open — its own inline preview owns the caret, and the two ghosts
    ///    would overprint;
    ///  * something is selected — an accept would replace it, not extend it;
    ///  * the caret is not at the end of the document — the text would land mid-line, in front of
    ///    bytes the ghost was drawn after;
    ///  * the document has more than one line — the suggestion is a whole-COMMAND affordance, and
    ///    matching a multi-line document against a single-line history entry can only ever fail
    ///    once the newline is typed, so refusing early is the honest version of the same answer.
    ///
    /// ⚠️ A history WALK is not on that list, and deliberately: ↑ puts a real entry in the buffer,
    /// and [`CommandHistory::suggestion`] refuses an exact hit, so the walk suppresses itself for
    /// the entry it landed on. Where it does not — an older entry that EXTENDS the recalled one —
    /// the ghost is exactly as true as it is at any other caret, and hiding it would make ↑ turn a
    /// working affordance off for no reason a reader could see.
    #[must_use]
    pub fn suggestion(&self) -> Option<&str> {
        if self.search.is_some() || !self.completion.is_empty() || self.buffer.selection().is_some() {
            return None;
        }
        let text = self.buffer.text();
        if self.buffer.cursor() != text.len() || text.contains('\n') {
            return None;
        }
        self.history.suggestion(text)
    }

    /// Takes the whole suggestion into the document — `→` / `⌃E` / `End` at the end of the line.
    ///
    /// `false` when there is nothing to accept, which is what makes the key fall THROUGH to its
    /// ordinary motion at both call sites. That boolean is the whole reason this is one Rust method
    /// rather than a rule each platform writes for itself: the Mac reaches the prompt through
    /// `AppKit` selectors and the phone through [`keys::edit_action`], so a predicate spelled in
    /// Swift would be spelled twice, and `→` would come to mean two things.
    ///
    /// ⚠️ Goes through [`CommandEditor::replace_range`] — the completion accept's own door — and
    /// NOT through [`CommandEditor::insert_text`], which is what this was written as first. Typed
    /// insertions COALESCE (see [`crate::prompt::undo`]), so an accept spelled that way merged into
    /// the burst the user typed to summon it, and the ⌘Z that should have taken back thirteen
    /// borrowed characters emptied the line instead. A suggestion accepted by reflex has to be
    /// exactly as cheap to reject, which means it is its own step.
    pub fn accept_suggestion(&mut self) -> bool {
        let Some(rest) = self.suggestion().map(str::to_owned) else {
            return false;
        };
        let at = self.buffer.cursor();
        self.replace_range(at..at, &rest);
        true
    }

    /// Takes one word of the suggestion — `⌥→`, `fish`'s partial accept.
    ///
    /// The word is [`suggestion_word_len`]'s, so the space in front of it comes too and the caret
    /// lands ready for the next press. `false` for nothing to accept, under
    /// [`CommandEditor::accept_suggestion`]'s rule and for its reason.
    pub fn accept_suggestion_word(&mut self) -> bool {
        let Some(word) = self
            .suggestion()
            .and_then(|rest| rest.get(..suggestion_word_len(rest)))
            .filter(|word| !word.is_empty())
            .map(str::to_owned)
        else {
            return false;
        };
        let at = self.buffer.cursor();
        self.replace_range(at..at, &word);
        true
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
        // The one moment the machine could have moved under every verdict held: see [`validity`].
        // It also opens a new generation, so an answer to a question asked before this line ran
        // cannot land afterwards and refill the table.
        self.validity.clear();
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
    use crate::prompt::buffer::{Granularity, Motion};
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

    /// A seeded editor whose history holds `commands`, newest last.
    fn recalling(commands: &[&str]) -> CommandEditor {
        let mut history = crate::prompt::history::CommandHistory::new();
        for command in commands {
            history.record(command);
        }
        CommandEditor::with_history(history)
    }

    #[test]
    fn the_suggestion_appears_as_you_type_and_the_accept_is_one_undo_step() {
        let mut editor = recalling(&["cargo test --lib"]);
        assert_eq!(editor.suggestion(), None, "nothing typed, nothing proposed");
        editor.insert_text("car");
        assert_eq!(editor.suggestion(), Some("go test --lib"));
        assert!(editor.accept_suggestion());
        assert_eq!(editor.text(), "cargo test --lib");
        assert_eq!(
            editor.suggestion(),
            None,
            "the exact entry has nothing left to add"
        );
        assert!(editor.undo());
        assert_eq!(editor.text(), "car", "one ⌘Z takes back a reflex accept");
    }

    #[test]
    fn one_word_of_the_suggestion_lands_at_a_time() {
        let mut editor = recalling(&["cargo test --lib --release"]);
        editor.insert_text("cargo");
        assert!(editor.accept_suggestion_word());
        assert_eq!(editor.text(), "cargo test");
        assert!(editor.accept_suggestion_word());
        assert_eq!(editor.text(), "cargo test --lib");
    }

    /// The four states where the ghost would be drawn somewhere an accept would not write.
    #[test]
    fn the_suggestion_stands_down_wherever_an_accept_would_not_append() {
        let mut editor = recalling(&["cargo test --lib"]);
        editor.insert_text("cargo");
        assert!(
            editor.suggestion().is_some(),
            "the baseline this test moves away from"
        );

        // The caret away from the end: the text would land in front of bytes the ghost sits after.
        editor.move_to(Motion::LineEdge(Backward));
        assert_eq!(editor.suggestion(), None);
        assert!(!editor.accept_suggestion(), "and the key falls through");
        editor.move_to(Motion::LineEdge(Forward));

        // A selection: an accept would replace it rather than extend it.
        editor.select_all();
        assert_eq!(editor.suggestion(), None);
        editor.move_to(Motion::LineEdge(Forward));

        // A second line: the suggestion is a whole-COMMAND affordance.
        editor.insert_newline();
        assert_eq!(editor.suggestion(), None);
        assert!(editor.undo());

        // ⌃R owns the history row while it is up.
        editor.begin_reverse_search();
        assert_eq!(editor.suggestion(), None);
        editor.reverse_search_cancel();
        assert!(editor.suggestion().is_some(), "and comes back when ⌃R closes");
    }

    /// The completion list's own inline preview owns the caret; two ghosts would overprint.
    #[test]
    fn an_open_candidate_list_takes_the_ghost_back() {
        let mut editor = recalling(&["cargo test --lib"]);
        editor.insert_text("car");
        assert!(editor.suggestion().is_some());
        let entries = [PathEntry {
            name: "cargo-thing".to_owned(),
            directory: false,
        }];
        let paths = PathProvider::new("", &entries);
        let providers: [&dyn CandidateProvider; 1] = [&paths];
        assert!(editor.complete(&providers, 6) > 0, "the list is genuinely open");
        assert_eq!(editor.suggestion(), None);
        editor.dismiss_completion();
        assert!(editor.suggestion().is_some());
    }

    #[test]
    fn typing_is_one_undo_step_and_a_click_between_two_bursts_makes_two() {
        let mut editor = typed("hello");
        assert!(editor.undo());
        assert!(editor.text().is_empty());
        assert!(editor.redo());
        assert_eq!(editor.text(), "hello");

        editor.pointer_select(0, 0, Granularity::Caret);
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

    /// The row the panel is on, for a test that does not care how it got there.
    fn selected_row(editor: &CommandEditor) -> &str {
        &editor.candidates()[editor.selected_candidate()].candidate.text
    }

    #[test]
    fn reverse_search_ranks_a_panel_without_touching_the_buffer_until_it_is_accepted() {
        let mut editor = CommandEditor::new();
        for command in ["cargo build", "ls", "cargo test"] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.insert_text("draft");

        // An empty query opens FULL — the recent-commands panel, newest first.
        editor.begin_reverse_search();
        assert_eq!(editor.candidates().len(), 3);
        assert_eq!(selected_row(&editor), "cargo test");

        // The query narrows the panel rather than stepping a hidden walk.
        editor.reverse_search_type("cargo");
        assert_eq!(editor.candidates().len(), 2, "`ls` is out");
        assert_eq!(selected_row(&editor), "cargo test");
        assert!(editor.reverse_search_again());
        assert_eq!(selected_row(&editor), "cargo build");
        assert!(
            editor.reverse_search_again(),
            "and it wraps, because the end is visible"
        );
        assert_eq!(selected_row(&editor), "cargo test");
        assert!(editor.reverse_search_back());
        assert_eq!(selected_row(&editor), "cargo build", "⌃S goes back up");
        assert_eq!(editor.text(), "draft", "the line is untouched while searching");

        assert!(editor.reverse_search_accept());
        assert_eq!(editor.text(), "cargo build");
        assert!(editor.search().is_none());
        assert!(editor.candidates().is_empty(), "the panel goes with the session");
        assert!(editor.undo(), "and it is one undo step");
        assert_eq!(editor.text(), "draft");
    }

    /// Out-of-order matching is the whole reason ⌃R ranks rather than walks — `fzf`'s ⌃R and
    /// `fish` 4.0's `git*HEAD` by another spelling.
    #[test]
    fn the_search_matches_out_of_order_and_ranks_by_score_then_recency() {
        let mut editor = CommandEditor::new();
        for command in ["git reset --hard HEAD", "ls", "git log HEAD"] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.begin_reverse_search();
        editor.reverse_search_type("gitHEAD");
        assert_eq!(editor.candidates().len(), 2, "`ls` matches neither run");
        assert_eq!(selected_row(&editor), "git log HEAD", "the tighter match wins");
    }

    /// ⌃R reads `fzf`'s extended-search syntax, and this is the reach test for it: the panel, not a
    /// unit of the scorer.
    ///
    /// One query carrying three of the sigils, against a history built so that each one is doing
    /// work — drop the `!` and `git push` returns, drop the `^` and `sudo git log` does.
    #[test]
    fn the_reverse_search_reads_fzfs_extended_syntax() {
        let mut editor = CommandEditor::new();
        for command in [
            "git push origin",
            "sudo git log",
            "git log --oneline",
            "git commit",
        ] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.begin_reverse_search();
        editor.reverse_search_type("^git !push");
        // `sudo git log` fails the `^`, `git push origin` fails the `!` — one sigil each.
        assert_eq!(
            editor.candidates().len(),
            2,
            "the two that open with `git` and carry no push"
        );
        editor.reverse_search_type(" log$");
        assert_eq!(
            editor.candidates().len(),
            0,
            "and `--oneline` is not how either line ENDS"
        );
    }

    /// The sigils stay OUT of the completion list, where they are shell text: `$HOME` is a variable
    /// and `!!` is a history expansion, not a suffix anchor and a negation.
    #[test]
    fn tab_completion_reads_the_sigils_as_text() {
        let mut editor = CommandEditor::new();
        editor.insert_text("echo $HOME");
        editor.submit();
        editor.insert_text("echo $HO");
        assert!(
            editor.complete(&[], 10) > 0,
            "the draft's own history entry is offered"
        );
    }

    /// A redraw that recompletes must not replace the search's rows with caret candidates.
    #[test]
    fn completing_while_a_search_is_open_leaves_the_panel_alone() {
        let mut editor = CommandEditor::new();
        editor.insert_text("cargo test --lib");
        editor.submit();
        editor.insert_text("car");
        editor.begin_reverse_search();
        editor.reverse_search_type("lib");
        let rows = editor.candidates().to_vec();
        assert_eq!(editor.complete(&[], 10), rows.len());
        assert_eq!(editor.candidates(), rows, "the search still owns the list");
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
        assert!(editor.candidates().is_empty(), "and the panel with it");
        // And the doors are all no-ops with no session up.
        editor.reverse_search_type("x");
        editor.reverse_search_backspace();
        assert!(!editor.reverse_search_again());
        assert!(!editor.reverse_search_back());
        assert!(!editor.reverse_search_accept());
    }

    /// Enter on a query that matched nothing gets OUT, and says it wrote nothing.
    ///
    /// The two halves are one decision (see [`CommandEditor::reverse_search_accept`]) and neither
    /// is safe alone: a `true` here would have the platforms treat an untouched draft as an
    /// accepted row, and leaving the session open would make Enter do nothing at all until the
    /// user found Esc. Pinned because it is the branch a rewrite silently flips — it has no
    /// visible output beyond the session going away.
    #[test]
    fn accepting_a_search_that_matched_nothing_still_closes_it() {
        let mut editor = CommandEditor::new();
        editor.insert_text("ls");
        editor.submit();
        editor.insert_text("draft");
        editor.begin_reverse_search();
        editor.reverse_search_type("zzz");
        assert!(editor.candidates().is_empty(), "the query matched nothing");
        assert!(!editor.reverse_search_accept(), "and so wrote nothing");
        assert!(editor.search().is_none(), "but the session is gone");
        assert_eq!(editor.text(), "draft", "with the draft handed back untouched");
    }

    /// The panel's count is what MATCHED, not what fits — the cap must not be reported as the
    /// total.
    ///
    /// The one number a reader cannot check against the screen, so a `ranked.len()` here would read
    /// as correct forever: every row it names is really there, and only the last two digits lie.
    #[test]
    fn the_search_counts_past_the_row_the_panel_stops_at() {
        let mut editor = CommandEditor::new();
        let total = super::complete::LIMIT + 7;
        for index in 0..total {
            editor.insert_text(&format!("cargo test --lib {index}"));
            editor.submit();
        }
        editor.begin_reverse_search();
        editor.reverse_search_type("cargo");
        assert_eq!(
            editor.candidates().len(),
            super::complete::LIMIT,
            "the list is capped"
        );
        assert_eq!(editor.search().unwrap().matched(), total, "the count is not");
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
        assert_eq!(editor.candidates().len(), 1);
        assert_eq!(selected_row(&editor), "make docs");
        editor.reverse_search_backspace();
        editor.reverse_search_backspace();
        assert_eq!(editor.search().unwrap().query(), "make");
        assert_eq!(editor.candidates().len(), 2, "both are back");
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
        editor.pointer_select(6, 11, Granularity::Caret);
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
        editor.pointer_select(0, 5, Granularity::Caret);
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
    fn a_double_click_takes_the_shell_word_and_not_the_unicode_segment() {
        // ⌥→ from `--` crosses it in one press and UAX #29 splits it into two `-` segments. The lex
        // says it is one flag, so a double-click takes the flag.
        let mut editor = typed("git log --oneline");
        editor.pointer_select(9, 9, Granularity::Word);
        assert_eq!(editor.selection(), Some(8..17), "`--oneline` whole");

        editor.pointer_select(5, 5, Granularity::Word);
        assert_eq!(editor.selection(), Some(4..7), "and `log` is still just `log`");
    }

    #[test]
    fn a_double_click_inside_a_quoted_argument_takes_the_argument() {
        let mut editor = typed("echo \"two words\"");
        editor.pointer_select(10, 10, Granularity::Word);
        assert_eq!(
            editor.selection(),
            Some(5..16),
            "the quotes are part of the argument the lexer found"
        );
    }

    #[test]
    fn a_double_click_off_any_word_falls_back_to_the_unicode_rule() {
        let mut editor = typed("echo hi");
        // The space between the two words is in neither of them.
        editor.pointer_select(4, 4, Granularity::Word);
        assert_eq!(editor.selection(), Some(4..5), "the whitespace run itself");
    }

    #[test]
    fn a_triple_click_takes_the_logical_line_without_its_newline() {
        let mut editor = CommandEditor::new();
        editor.paste("first\nsecond\nthird");
        editor.pointer_select(8, 8, Granularity::Line);
        assert_eq!(editor.selection(), Some(6..12), "`second` alone");
    }

    #[test]
    fn dragging_back_past_the_press_keeps_the_pressed_words_far_edge() {
        let mut editor = typed("alpha beta gamma");
        // Press in `beta`, drag left into `alpha`: both whole, caret leading on the left.
        editor.pointer_select(8, 2, Granularity::Word);
        assert_eq!(editor.selection(), Some(0..10), "`alpha beta`");
        assert_eq!(editor.cursor(), 0, "the head led the drag");
    }

    #[test]
    fn a_caret_gesture_is_a_drag_of_length_nought_through_the_same_door() {
        let mut editor = typed("hello world");
        editor.pointer_select(3, 3, Granularity::Caret);
        assert_eq!(editor.selection(), None, "a click places the caret");
        assert_eq!(editor.cursor(), 3);
        editor.pointer_select(3, 8, Granularity::Caret);
        assert_eq!(
            editor.selection(),
            Some(3..8),
            "a drag selects exactly what it crossed"
        );
    }

    #[test]
    fn a_pointer_offset_inside_a_cluster_snaps_rather_than_splitting_it() {
        let mut editor = CommandEditor::new();
        editor.paste("ae\u{301}b");
        editor.pointer_select(2, 2, Granularity::Caret);
        assert_eq!(editor.cursor(), 1, "back to the cluster's start");
        editor.pointer_select(0, 99, Granularity::Caret);
        assert_eq!(editor.cursor(), editor.text().len(), "and past the end clamps");
    }

    #[test]
    fn a_click_in_the_document_closes_an_open_search_and_hands_the_draft_back() {
        let mut editor = CommandEditor::new();
        editor.insert_text("echo hi");
        editor.submit();
        editor.insert_text("draft text");
        editor.begin_reverse_search();
        editor.reverse_search_type("echo");
        assert!(editor.search().is_some(), "the panel is up");
        assert!(!editor.candidates().is_empty(), "with a row in it");

        editor.pointer_select(6, 6, Granularity::Caret);

        assert!(
            editor.search().is_none(),
            "clicking the line closes the pager, as in fish"
        );
        assert!(editor.candidates().is_empty(), "and takes its rows with it");
        assert_eq!(editor.text(), "draft text", "the draft is handed back untouched");
        assert_eq!(editor.cursor(), 6, "and the caret is where the click landed");
    }

    #[test]
    fn a_click_on_a_row_picks_it_without_dismissing_the_list_the_click_came_from() {
        let mut editor = CommandEditor::new();
        for command in ["cargo build", "cargo test"] {
            editor.insert_text(command);
            editor.submit();
        }
        editor.insert_text("cargo");
        let rows = editor.complete(&[], 10);
        assert!(rows >= 2, "two history entries share the prefix");

        assert!(editor.select_candidate(1), "the second row is clickable");
        assert_eq!(editor.selected_candidate(), 1);
        assert_eq!(
            editor.candidates().len(),
            rows,
            "and the list it came from is still up"
        );

        assert!(!editor.select_candidate(rows), "one past the end is not a row");
        assert_eq!(editor.selected_candidate(), 1, "and a miss moves nothing");
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
