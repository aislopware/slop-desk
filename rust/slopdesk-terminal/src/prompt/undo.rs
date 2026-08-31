//! Undo as OPERATIONS, and the rule for when a run of them is one step.
//!
//! ## Why not snapshots
//!
//! The easy undo stack is a `Vec<String>` of whole documents. It is also the one that cannot
//! survive this product's own worst case: a 10 MB paste into a prompt, backspaced a character at a
//! time, would keep a 10 MB copy per keystroke. An operation keeps only the bytes that CHANGED — a
//! backspace step is one grapheme wide however large the document is — so the stack's cost tracks
//! what the user did rather than what they are looking at.
//!
//! The cost of that choice is that a step is only reversible against the document it came from, so
//! the stack and the buffer have to move together. [`UndoStack::undo`] takes the buffer for exactly
//! that reason: there is no way to hold half of the pair.
//!
//! ## Coalescing, stated as a rule rather than a timer
//!
//! Every editor coalesces typing, and most do it on a 300 ms timer. A timer is untestable without a
//! clock, and this crate has none by contract (`lib.rs`). So the rule is structural instead, and it
//! is the one users actually feel:
//!
//! * A run of typed graphemes is ONE step while each lands where the last one left off.
//! * A run of deletions is ONE step while each is adjacent to the last, in the same direction.
//! * A paste is ALWAYS its own step — the point of undoing a paste is getting rid of all of it.
//! * Typing over a selection is ALWAYS its own step, because it destroyed something.
//! * A newline closes the typing run, so undo walks back a line at a time rather than swallowing a
//!   whole multi-line command in one press.
//! * ANY other action — a movement, a history recall, a completion, a submit — closes the run.
//!   [`UndoStack::break_run`] is that door, and the editor calls it rather than the stack guessing.
//!
//! Redo is cleared by the first new edit after an undo, which is the linear model every text field
//! in the platform uses.

use crate::prompt::buffer::TextBuffer;

/// How many steps the stack keeps.
///
/// Bounded because a paste is unbounded: without a cap, a session that pastes a megabyte a hundred
/// times holds a hundred megabytes of history nobody will ever walk back to. The oldest step is
/// dropped, so the recent past — which is all anyone undoes — is always intact.
pub const CAPACITY: usize = 512;

/// One reversible change: what was there, what replaced it, and where the caret was on both sides.
///
/// The caret is part of the operation rather than derived from it because undo has to put the caret
/// back where the user was looking, and the offset that produced a deletion is not recoverable from
/// the deletion alone — a backspace and a forward-delete remove the same bytes from different
/// carets.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Edit {
    /// Byte offset the change starts at.
    pub at: usize,
    /// The text that was removed, empty for a pure insertion.
    pub removed: String,
    /// The text that was inserted, empty for a pure deletion.
    pub inserted: String,
    /// Where the caret was before.
    pub cursor_before: usize,
    /// Where the selection's anchor was before, so undoing a replace-on-type restores the
    /// selection it consumed.
    pub anchor_before: usize,
    /// Where the caret ended up.
    pub cursor_after: usize,
}

impl Edit {
    /// Whether the edit changed nothing at all — a caller can skip pushing it.
    #[must_use]
    pub const fn is_noop(&self) -> bool {
        self.removed.is_empty() && self.inserted.is_empty()
    }
}

/// What produced an edit, which is the whole of what decides coalescing.
///
/// Named after the GESTURE rather than after the result: a paste and a burst of typing both insert
/// text, and the difference between them is the only thing that makes them one step or two.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EditKind {
    /// One or more graphemes typed at the caret.
    Insert,
    /// A backspace or forward-delete with no selection.
    Delete,
    /// A clipboard drop, a completion acceptance, a history recall — one gesture, one step.
    Paste,
    /// Typing (or pasting) over a selection.
    Replace,
}

impl EditKind {
    /// Whether a run of this kind may absorb the next edit at all.
    const fn runs(self) -> bool {
        matches!(self, Self::Insert | Self::Delete)
    }
}

/// One step of the history.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Step {
    edit: Edit,
    kind: EditKind,
}

/// The undo and redo stacks, and whether the top step is still absorbing.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UndoStack {
    done: Vec<Step>,
    undone: Vec<Step>,
    /// Whether the newest step may still coalesce. Cleared by [`UndoStack::break_run`] and by every
    /// undo or redo.
    open: bool,
}

impl UndoStack {
    /// An empty stack.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            done: Vec::new(),
            undone: Vec::new(),
            open: false,
        }
    }

    /// How many steps an undo could walk back.
    #[must_use]
    pub const fn depth(&self) -> usize {
        self.done.len()
    }

    /// Whether there is anything to undo.
    #[must_use]
    pub const fn can_undo(&self) -> bool {
        !self.done.is_empty()
    }

    /// Whether there is anything to redo.
    #[must_use]
    pub const fn can_redo(&self) -> bool {
        !self.undone.is_empty()
    }

    /// Ends the current run, so the next edit starts a step of its own.
    ///
    /// Called by the editor on every non-editing action. Explicit rather than inferred because the
    /// stack cannot see a cursor movement, and a stack that guessed would be wrong exactly when the
    /// user moved the caret and kept typing.
    pub const fn break_run(&mut self) {
        self.open = false;
    }

    /// Records an edit, merging it into the open step when the rule above allows.
    pub fn push(&mut self, edit: Edit, kind: EditKind) {
        if edit.is_noop() {
            return;
        }
        self.undone.clear();
        if self.open && kind.runs() && self.absorb(&edit, kind) {
            return;
        }
        // A newline never leaves the run open: undo walks back a line at a time rather than
        // swallowing a whole multi-line command in one press.
        self.open = kind.runs() && !edit.inserted.contains('\n');
        self.done.push(Step { edit, kind });
        if self.done.len() > CAPACITY {
            self.done.remove(0);
        }
    }

    /// Tries to fold `edit` into the newest step. `false` means it has to stand alone.
    fn absorb(&mut self, edit: &Edit, kind: EditKind) -> bool {
        let Some(top) = self.done.last_mut() else {
            return false;
        };
        if top.kind != kind {
            return false;
        }
        match kind {
            EditKind::Insert => {
                // Typing only continues a run when it lands exactly where the run left off, and a
                // newline closes it so undo walks back a line at a time.
                if !top.edit.removed.is_empty()
                    || !edit.removed.is_empty()
                    || edit.inserted.contains('\n')
                    || top.edit.at.saturating_add(top.edit.inserted.len()) != edit.at
                {
                    return false;
                }
                top.edit.inserted.push_str(&edit.inserted);
                top.edit.cursor_after = edit.cursor_after;
                true
            },
            EditKind::Delete => {
                if !top.edit.inserted.is_empty() || !edit.inserted.is_empty() {
                    return false;
                }
                if edit.at.saturating_add(edit.removed.len()) == top.edit.at {
                    // Backspace: the run grows leftward and the caret follows it.
                    let mut grown = edit.removed.clone();
                    grown.push_str(&top.edit.removed);
                    top.edit.removed = grown;
                    top.edit.at = edit.at;
                    top.edit.cursor_after = edit.cursor_after;
                    true
                } else if edit.at == top.edit.at {
                    // Forward-delete: the run grows rightward and the caret stays put.
                    top.edit.removed.push_str(&edit.removed);
                    top.edit.cursor_after = edit.cursor_after;
                    true
                } else {
                    false
                }
            },
            EditKind::Paste | EditKind::Replace => false,
        }
    }

    /// Reverses the newest step against `buffer`, restoring the caret and any selection it ate.
    ///
    /// `false` when there was nothing to undo, so a caller can pass the key on rather than swallow
    /// it.
    pub fn undo(&mut self, buffer: &mut TextBuffer) -> bool {
        self.open = false;
        let Some(step) = self.done.pop() else {
            return false;
        };
        let end = step.edit.at.saturating_add(step.edit.inserted.len());
        buffer.splice(step.edit.at..end, &step.edit.removed);
        buffer.place(step.edit.cursor_before, step.edit.anchor_before);
        self.undone.push(step);
        true
    }

    /// Replays the newest undone step, leaving the caret where the edit originally left it.
    pub fn redo(&mut self, buffer: &mut TextBuffer) -> bool {
        self.open = false;
        let Some(step) = self.undone.pop() else {
            return false;
        };
        let end = step.edit.at.saturating_add(step.edit.removed.len());
        buffer.splice(step.edit.at..end, &step.edit.inserted);
        buffer.place(step.edit.cursor_after, step.edit.cursor_after);
        self.done.push(step);
        true
    }

    /// Forgets everything — a new session, or a submitted command.
    pub fn clear(&mut self) {
        self.done.clear();
        self.undone.clear();
        self.open = false;
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CAPACITY, EditKind, UndoStack};
    use crate::prompt::buffer::Direction::{Backward, Forward};
    use crate::prompt::buffer::{Motion, TextBuffer};

    /// Types `text` one grapheme at a time, the way a keyboard delivers it.
    fn type_text(buffer: &mut TextBuffer, stack: &mut UndoStack, text: &str) {
        for grapheme in text.chars() {
            let edit = buffer.insert(&grapheme.to_string());
            stack.push(edit, EditKind::Insert);
        }
    }

    #[test]
    fn a_run_of_typed_characters_is_one_step() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        type_text(&mut buffer, &mut stack, "hello");
        assert_eq!(stack.depth(), 1);
        assert!(stack.undo(&mut buffer));
        assert_eq!(buffer.text(), "");
        assert_eq!(buffer.cursor(), 0);
    }

    #[test]
    fn a_movement_between_two_characters_splits_the_run() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        type_text(&mut buffer, &mut stack, "ab");
        stack.break_run();
        type_text(&mut buffer, &mut stack, "cd");
        assert_eq!(stack.depth(), 2);
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "ab");
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "");
    }

    #[test]
    fn typing_somewhere_else_starts_a_new_step_even_without_a_break() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        type_text(&mut buffer, &mut stack, "ab");
        buffer.set_cursor(0);
        // The editor would have broken the run; the stack refuses to merge anyway, because the
        // insert did not land where the last one left off.
        let edit = buffer.insert("Z");
        stack.push(edit, EditKind::Insert);
        assert_eq!(stack.depth(), 2);
    }

    #[test]
    fn a_newline_closes_the_typing_run() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        type_text(&mut buffer, &mut stack, "one");
        let edit = buffer.insert("\n");
        stack.push(edit, EditKind::Insert);
        type_text(&mut buffer, &mut stack, "two");
        assert_eq!(stack.depth(), 3);
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "one\n");
    }

    #[test]
    fn a_run_of_backspaces_is_one_step() {
        let mut buffer = TextBuffer::seeded("hello world");
        let mut stack = UndoStack::new();
        for _ in 0..5 {
            let edit = buffer.delete(Motion::Grapheme(Backward)).unwrap();
            stack.push(edit, EditKind::Delete);
        }
        assert_eq!(buffer.text(), "hello ");
        assert_eq!(stack.depth(), 1);
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "hello world");
        assert_eq!(
            buffer.cursor(),
            11,
            "the caret is back where the deleting started"
        );
    }

    #[test]
    fn deletions_on_both_sides_of_one_caret_stay_one_step() {
        let mut buffer = TextBuffer::seeded("abcdef");
        let mut stack = UndoStack::new();
        buffer.set_cursor(3);
        for _ in 0..2 {
            let edit = buffer.delete(Motion::Grapheme(Forward)).unwrap();
            stack.push(edit, EditKind::Delete);
        }
        assert_eq!(buffer.text(), "abcf");
        assert_eq!(stack.depth(), 1);
        // A backspace from the same caret is not adjacent in the same direction, so it merges
        // leftward into the same run — which is what a user deleting around a caret expects.
        let edit = buffer.delete(Motion::Grapheme(Backward)).unwrap();
        stack.push(edit, EditKind::Delete);
        assert_eq!(buffer.text(), "abf");
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "abcdef");
    }

    #[test]
    fn a_paste_is_always_its_own_step() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        for _ in 0..3 {
            let edit = buffer.insert("xyz");
            stack.push(edit, EditKind::Paste);
        }
        assert_eq!(stack.depth(), 3);
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "xyzxyz");
    }

    #[test]
    fn typing_over_a_selection_is_its_own_step_and_undo_gives_the_selection_back() {
        let mut buffer = TextBuffer::seeded("hello world");
        let mut stack = UndoStack::new();
        buffer.set_selection(6, 11);
        let edit = buffer.insert("there");
        stack.push(edit, EditKind::Replace);
        assert_eq!(buffer.text(), "hello there");
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "hello world");
        assert_eq!(
            buffer.selection(),
            Some(6..11),
            "the selection it ate is restored"
        );
    }

    #[test]
    fn a_replace_never_absorbs_the_typing_that_follows_it() {
        let mut buffer = TextBuffer::seeded("abc");
        let mut stack = UndoStack::new();
        buffer.select_all();
        let edit = buffer.insert("Z");
        stack.push(edit, EditKind::Replace);
        type_text(&mut buffer, &mut stack, "yz");
        assert_eq!(stack.depth(), 2);
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "Z");
        stack.undo(&mut buffer);
        assert_eq!(buffer.text(), "abc");
    }

    #[test]
    fn redo_replays_a_whole_coalesced_step() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        type_text(&mut buffer, &mut stack, "hello");
        stack.undo(&mut buffer);
        assert!(stack.can_redo());
        assert!(stack.redo(&mut buffer));
        assert_eq!(buffer.text(), "hello");
        assert_eq!(buffer.cursor(), 5);
        assert!(!stack.can_redo());
    }

    #[test]
    fn a_new_edit_after_an_undo_drops_the_redo_branch() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        type_text(&mut buffer, &mut stack, "abc");
        stack.undo(&mut buffer);
        assert!(stack.can_redo());
        type_text(&mut buffer, &mut stack, "z");
        assert!(!stack.can_redo());
        assert_eq!(buffer.text(), "z");
    }

    #[test]
    fn undoing_an_empty_stack_reports_it_rather_than_panicking() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        assert!(!stack.undo(&mut buffer));
        assert!(!stack.redo(&mut buffer));
        assert!(!stack.can_undo());
    }

    #[test]
    fn a_noop_edit_is_never_recorded() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        let edit = buffer.insert("");
        stack.push(edit, EditKind::Insert);
        assert_eq!(stack.depth(), 0);
    }

    #[test]
    fn the_stack_is_bounded_and_drops_the_oldest() {
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        for _ in 0..(CAPACITY + 40) {
            let edit = buffer.insert("x");
            stack.push(edit, EditKind::Paste);
        }
        assert_eq!(stack.depth(), CAPACITY);
        while stack.undo(&mut buffer) {}
        assert_eq!(
            buffer.text().len(),
            40,
            "the 40 oldest steps are gone, their text is not"
        );
    }

    #[test]
    fn a_multi_megabyte_paste_costs_one_copy_not_one_per_keystroke() {
        let paste = "x".repeat(4 * 1024 * 1024);
        let mut buffer = TextBuffer::new();
        let mut stack = UndoStack::new();
        let edit = buffer.insert(&paste);
        stack.push(edit, EditKind::Paste);
        // Backspacing over it keeps one step whose removed text grows a grapheme at a time.
        for _ in 0..10 {
            let edit = buffer.delete(Motion::Grapheme(Backward)).unwrap();
            stack.push(edit, EditKind::Delete);
        }
        assert_eq!(stack.depth(), 2);
        stack.undo(&mut buffer);
        assert_eq!(buffer.len(), paste.len());
        stack.undo(&mut buffer);
        assert!(buffer.is_empty());
    }
}
