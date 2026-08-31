//! Which keys the editor may NOT have, and which verb every other one names.
//!
//! With the app's editor owning the command line, a press at an idle prompt goes to
//! [`super::CommandEditor`] and the shell sees nothing until Enter. That is the point, and it is
//! wrong for a handful of keys: `readline` never owned them either. `⌃C` abandons the line at the
//! SHELL, which prints `^C` and a fresh prompt; `⌃D` on an empty line is EOF and is how a shell is
//! exited; `⌃Z` is the job-control signal; `⌃L` clears the SCREEN, which the editor does not own.
//! Swallow any of those and the terminal has a state the user cannot get out of.
//!
//! This is a rule and not a table lookup in the view because two views ask it — `docs/68` §10 puts
//! key NAMING in the platform view and the decision here.
//!
//! ## Why the whole chord table lives here and not only the four
//!
//! The Mac never needed one. `AppKit`'s standard key-binding table already names `⌥←`, `⌃A`, `⇧⌘→`,
//! `fn⌫` and the rest, and `doCommand(by:)` delivers each as a SELECTOR — so
//! `MacTerminalRendererView` maps selectors, never keys, and inherits every layout and every user's
//! `DefaultKeyBinding.dict` for free. `UIKit` has no counterpart: there is no `doCommand(by:)`, and
//! `UITextInput` supplies none of it. The phone therefore has to name the chords itself, and naming
//! them here rather than in a Swift table is what keeps the two platforms ONE editor instead of two
//! that happen to agree when someone reads them side by side.
//!
//! ## Why the byte is not in the answer
//!
//! A control letter's byte is `letter & 0x1F` and always has been; the caller already holds the
//! letter. Answering the byte too would put the ASCII arithmetic on this side of a door for no
//! decision — and a caller that got it wrong would be sending the wrong byte either way.

use super::buffer::{Direction, Motion};

/// What a control press does when the editor is armed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlAction {
    /// The editor's own. No byte reaches the shell.
    Editor,
    /// The shell's. Send the control byte; the editor's text is untouched.
    Forward,
    /// The shell's, AND it abandons the line: send the byte, then empty the editor.
    ///
    /// Only `⌃C`. The shell answers it by printing `^C` and drawing a fresh prompt, so an editor
    /// that kept its text would show a line the shell has already thrown away — and the next Enter
    /// would run a command the user believes they cancelled.
    ForwardAndClear,
}

/// What a `⌃`-modified letter does at an armed prompt.
///
/// `letter` is the lowercase ASCII letter the platform reports, so `⌃C` arrives as `b'c'`. Anything
/// that is not one of the four named keys is the editor's — including `⌃A`/`⌃E`/`⌃K`/`⌃W`, which
/// are `readline` motions the editor implements better and which no longer need to reach a shell
/// that is not doing the editing.
///
/// `buffer_empty` decides `⌃D` alone, and that is the historical rule exactly: on an empty line it
/// is EOF, and on any other it is delete-forward.
#[must_use]
pub const fn control_action(letter: u8, buffer_empty: bool) -> ControlAction {
    match letter {
        b'c' => ControlAction::ForwardAndClear,
        b'd' if buffer_empty => ControlAction::Forward,
        b'z' | b'l' => ControlAction::Forward,
        _ => ControlAction::Editor,
    }
}

/// A key named the way a platform that has no hardware code can name it.
///
/// ⚠️ NOT A KEYCODE. `UIKit` hands a press over as characters plus a small set of named keys, and
/// `docs/68` §10's rule reads the same either way: a motion crosses as a case, never as a key. The
/// named arms cover what a character cannot express; [`Key::Char`] carries the lowercase ASCII
/// letter for the chords that are letters, and `0` for anything outside ASCII — a Vietnamese letter
/// is text, and text never resolves to an editing verb.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// ←
    Left,
    /// →
    Right,
    /// ↑
    Up,
    /// ↓
    Down,
    /// Home
    Home,
    /// End
    End,
    /// Page Up
    PageUp,
    /// Page Down
    PageDown,
    /// ⌫
    Backspace,
    /// ⌦, the forward delete
    Delete,
    /// ⇥
    Tab,
    /// ↩
    Return,
    /// ⎋
    Escape,
    /// A letter or digit, lowercased ASCII. `0` for anything that is not ASCII.
    Char(u8),
}

/// Which modifiers a press carried.
///
/// Four `bool`s and not the state machine clippy asks for: these are FOUR INDEPENDENT physical keys
/// and every combination of them is a chord somebody presses, so there is no state to collapse —
/// the enum that lint wants would have sixteen variants naming nothing.
#[expect(
    clippy::struct_excessive_bools,
    reason = "the four modifier keys are independent and all sixteen combinations are reachable"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mods {
    /// ⇧
    pub shift: bool,
    /// ⌃
    pub control: bool,
    /// ⌥
    pub option: bool,
    /// ⌘
    pub command: bool,
}

/// What one press does at an armed prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditAction {
    /// Move the caret, or extend the selection to where it would have gone.
    Move {
        /// Where to.
        motion: Motion,
        /// Whether the anchor stays put — ⇧ held.
        extend: bool,
    },
    /// Delete at a granularity. ⌫ with a selection deletes the selection, which is the editor's own
    /// rule rather than a case here: only the granularity crosses.
    Delete(Motion),
    /// The VIEWPORT's, not the line's — negative reveals OLDER output.
    ///
    /// Kept apart from [`EditAction::Move`] for the reason the Mac keeps its own two tables apart:
    /// these read the scrollback, which the editor does not own and has no opinion about. An editor
    /// that swallowed `PageUp` would take a terminal feature away by existing.
    ScrollPages(i32),
    /// ↑ from the first line: an older command.
    HistoryPrevious,
    /// ↓ from the last line: a newer one.
    HistoryNext,
    /// ↩ — run it, accept a candidate, or take the search's hit.
    Submit,
    /// ⌥↩ / ⇧↩ — a second line of the same command.
    InsertNewline,
    /// ⇥
    CompleteForward,
    /// ⇧⇥
    CompleteBackward,
    /// ⎋ — dismiss what is up, innermost first. Never clears the text.
    Cancel,
    /// ⌘A
    SelectAll,
    /// ⌘V, and `⌃Y`.
    Paste,
    /// ⌘C
    Copy,
    /// ⌘X
    Cut,
    /// ⌘Z
    Undo,
    /// ⇧⌘Z / ⌘Y
    Redo,
    /// ⌃R — open a reverse search, or step it.
    Search,
    /// A `⌃` letter [`control_action`] says is not the editor's.
    Control(ControlAction),
}

/// The editing verb one press names at an armed prompt, or `None` when the press is TEXT.
///
/// `None` is the common answer and the important one: everything this function does not name is
/// inserted as characters by the caller, which is what keeps a Telex composition — the case
/// `docs/68` §5.1 puts on the critical path — out of a chord table it has no business in.
///
/// ⚠️ THE ORDER OF THE ARMS IS THE RULE. `⌃` letters are asked before anything else because
/// [`control_action`] hands four of them to the shell, and a `⌃A` resolved as a motion first would
/// never reach that question. `⌘` chords come next: they are app shortcuts everywhere else, and the
/// ones this editor claims are exactly the ones a text field claims. The named keys are last, where
/// a `readline` would have them.
///
/// `buffer_empty` is [`control_action`]'s, and reaches it unchanged.
#[must_use]
pub fn edit_action(key: Key, mods: Mods, buffer_empty: bool) -> Option<EditAction> {
    if mods.control
        && !mods.command
        && let Key::Char(letter) = key
    {
        // ⌃R is the one editor chord `AppKit`'s table does not name either, which is why it is
        // spelled on both sides rather than inherited on one.
        if letter == b'r' {
            return Some(EditAction::Search);
        }
        return match control_action(letter, buffer_empty) {
            ControlAction::Editor => control_motion(letter, mods.shift),
            action => Some(EditAction::Control(action)),
        };
    }
    if mods.command && !mods.control && !mods.option {
        return command_action(key, mods.shift);
    }
    named_action(key, mods)
}

/// The `readline` verbs a `⌃` letter names once [`control_action`] has left it to the editor.
///
/// These are the ones every shell has had since `readline`: `⌃A`/`⌃E` to the line's edges,
/// `⌃B`/`⌃F` by a grapheme, `⌃P`/`⌃N` through the history, `⌃K`/`⌃U` cutting to an edge, `⌃W`
/// cutting a word and `⌃Y` putting it back. The Mac gets the same set from `AppKit`'s own table.
const fn control_motion(letter: u8, shift: bool) -> Option<EditAction> {
    let motion = match letter {
        b'a' => Motion::LineEdge(Direction::Backward),
        b'e' => Motion::LineEdge(Direction::Forward),
        b'b' => Motion::Grapheme(Direction::Backward),
        b'f' => Motion::Grapheme(Direction::Forward),
        b'p' => return Some(EditAction::HistoryPrevious),
        b'n' => return Some(EditAction::HistoryNext),
        b'y' => return Some(EditAction::Paste),
        b'k' => return Some(EditAction::Delete(Motion::LineEdge(Direction::Forward))),
        b'u' => return Some(EditAction::Delete(Motion::LineEdge(Direction::Backward))),
        b'w' => return Some(EditAction::Delete(Motion::Word(Direction::Backward))),
        b'h' => return Some(EditAction::Delete(Motion::Grapheme(Direction::Backward))),
        b'd' => return Some(EditAction::Delete(Motion::Grapheme(Direction::Forward))),
        _ => return None,
    };
    Some(EditAction::Move {
        motion,
        extend: shift,
    })
}

/// The `⌘` chords the editor claims, which are exactly the ones any text field claims.
fn command_action(key: Key, shift: bool) -> Option<EditAction> {
    let edge = |motion| {
        Some(EditAction::Move {
            motion,
            extend: shift,
        })
    };
    match key {
        // ⌘← / ⌘→ are the line's edges and ⌘↑ / ⌘↓ the document's — the same reading a Mac gives
        // them, where `moveToBeginningOfDocument:` is the EDITOR's because on a multi-line command
        // the document in question is the one being typed.
        Key::Left => edge(Motion::LineEdge(Direction::Backward)),
        Key::Right => edge(Motion::LineEdge(Direction::Forward)),
        Key::Up => edge(Motion::DocEdge(Direction::Backward)),
        Key::Down => edge(Motion::DocEdge(Direction::Forward)),
        Key::Backspace => Some(EditAction::Delete(Motion::LineEdge(Direction::Backward))),
        Key::Char(b'a') => Some(EditAction::SelectAll),
        Key::Char(b'c') => Some(EditAction::Copy),
        Key::Char(b'x') => Some(EditAction::Cut),
        Key::Char(b'v') => Some(EditAction::Paste),
        // ⌘Y ignores ⇧, exactly as the Mac's own reading does. Two spellings of one chord
        // disagreeing about a modifier is drift nobody finds by using the app.
        Key::Char(b'y') => Some(EditAction::Redo),
        Key::Char(b'z') => Some(if shift { EditAction::Redo } else { EditAction::Undo }),
        _ => None,
    }
}

/// The named keys, under whatever modifiers are left.
fn named_action(key: Key, mods: Mods) -> Option<EditAction> {
    let extend = mods.shift;
    let motion = |motion| Some(EditAction::Move { motion, extend });
    let by_word = |word, plain| if mods.option { word } else { plain };
    match key {
        Key::Left => {
            motion(by_word(
                Motion::Word(Direction::Backward),
                Motion::Grapheme(Direction::Backward),
            ))
        },
        Key::Right => {
            motion(by_word(
                Motion::Word(Direction::Forward),
                Motion::Grapheme(Direction::Forward),
            ))
        },
        // ⇧↑ is unambiguously a selection gesture, so it never walks the history — a walk that also
        // selected something would be nonsense. Whether a BARE arrow really walks is the caller's,
        // because only that side knows if the caret is on the document's first or last line.
        Key::Up if !extend => Some(EditAction::HistoryPrevious),
        Key::Down if !extend => Some(EditAction::HistoryNext),
        Key::Up => motion(Motion::Line(Direction::Backward)),
        Key::Down => motion(Motion::Line(Direction::Forward)),
        Key::Home => motion(Motion::LineEdge(Direction::Backward)),
        Key::End => motion(Motion::LineEdge(Direction::Forward)),
        Key::PageUp => Some(EditAction::ScrollPages(-1)),
        Key::PageDown => Some(EditAction::ScrollPages(1)),
        Key::Backspace => {
            Some(EditAction::Delete(by_word(
                Motion::Word(Direction::Backward),
                Motion::Grapheme(Direction::Backward),
            )))
        },
        Key::Delete => {
            Some(EditAction::Delete(by_word(
                Motion::Word(Direction::Forward),
                Motion::Grapheme(Direction::Forward),
            )))
        },
        Key::Tab if extend => Some(EditAction::CompleteBackward),
        Key::Tab => Some(EditAction::CompleteForward),
        // ⌥↩ and ⇧↩ both open a line; a bare ↩ runs what is there. Two spellings because the
        // keyboards a phone meets disagree about which one an editor uses.
        Key::Return if mods.option || extend => Some(EditAction::InsertNewline),
        Key::Return => Some(EditAction::Submit),
        Key::Escape => Some(EditAction::Cancel),
        Key::Char(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{ControlAction, Direction, EditAction, Key, Mods, Motion, control_action, edit_action};

    /// No modifier at all — the state a bare press arrives in.
    const NONE: Mods = Mods {
        shift: false,
        control: false,
        option: false,
        command: false,
    };
    const CTRL: Mods = Mods {
        control: true,
        ..NONE
    };
    const CMD: Mods = Mods {
        command: true,
        ..NONE
    };
    const SHIFT: Mods = Mods { shift: true, ..NONE };
    const OPTION: Mods = Mods { option: true, ..NONE };

    #[test]
    fn ctrl_c_abandons_the_line_at_the_shell() {
        assert_eq!(control_action(b'c', false), ControlAction::ForwardAndClear);
        assert_eq!(control_action(b'c', true), ControlAction::ForwardAndClear);
    }

    #[test]
    fn ctrl_d_is_eof_only_on_an_empty_line() {
        assert_eq!(control_action(b'd', true), ControlAction::Forward);
        assert_eq!(control_action(b'd', false), ControlAction::Editor);
    }

    #[test]
    fn the_signal_and_the_screen_are_never_the_editors() {
        assert_eq!(control_action(b'z', false), ControlAction::Forward);
        assert_eq!(control_action(b'l', false), ControlAction::Forward);
    }

    /// The readline motions the editor now owns: reaching a shell that is not editing would move a
    /// cursor nobody can see.
    #[test]
    fn the_line_edit_letters_stay_with_the_editor() {
        for letter in *b"aekwuyrbfpn" {
            assert_eq!(control_action(letter, false), ControlAction::Editor, "{letter}");
        }
    }

    #[test]
    fn an_unknown_byte_is_the_editors() {
        assert_eq!(control_action(0, false), ControlAction::Editor);
        assert_eq!(
            control_action(b'C', false),
            ControlAction::Editor,
            "callers lowercase first"
        );
    }

    #[test]
    fn a_plain_letter_is_text_and_names_no_verb() {
        assert_eq!(edit_action(Key::Char(b'a'), NONE, false), None);
        assert_eq!(
            edit_action(Key::Char(0), NONE, false),
            None,
            "a Vietnamese letter is text, and text never resolves to a verb"
        );
    }

    #[test]
    fn the_shell_control_keys_still_reach_the_shell() {
        for (letter, expected) in [
            (b'c', ControlAction::ForwardAndClear),
            (b'z', ControlAction::Forward),
            (b'l', ControlAction::Forward),
        ] {
            assert_eq!(
                edit_action(Key::Char(letter), CTRL, false),
                Some(EditAction::Control(expected)),
                "{letter}"
            );
        }
    }

    /// ⌃D is the one whose answer depends on the line, and it must keep depending on it.
    #[test]
    fn ctrl_d_stays_eof_on_an_empty_line_through_the_resolver() {
        assert_eq!(
            edit_action(Key::Char(b'd'), CTRL, true),
            Some(EditAction::Control(ControlAction::Forward)),
        );
        assert_eq!(
            edit_action(Key::Char(b'd'), CTRL, false),
            Some(EditAction::Delete(Motion::Grapheme(Direction::Forward))),
        );
    }

    #[test]
    fn the_readline_verbs_are_the_editors() {
        assert_eq!(
            edit_action(Key::Char(b'a'), CTRL, false),
            Some(EditAction::Move {
                motion: Motion::LineEdge(Direction::Backward),
                extend: false,
            }),
        );
        assert_eq!(
            edit_action(Key::Char(b'w'), CTRL, false),
            Some(EditAction::Delete(Motion::Word(Direction::Backward))),
        );
        assert_eq!(edit_action(Key::Char(b'y'), CTRL, false), Some(EditAction::Paste));
    }

    /// ⌃R is asked before [`control_action`], which would otherwise call it the editor's and lose
    /// it into the motion table, where it names nothing.
    #[test]
    fn ctrl_r_opens_the_reverse_search() {
        assert_eq!(
            edit_action(Key::Char(b'r'), CTRL, false),
            Some(EditAction::Search)
        );
        assert_eq!(control_action(b'r', false), ControlAction::Editor);
    }

    #[test]
    fn the_four_editing_chords_are_the_ones_a_text_field_claims() {
        assert_eq!(
            edit_action(Key::Char(b'a'), CMD, false),
            Some(EditAction::SelectAll)
        );
        assert_eq!(edit_action(Key::Char(b'c'), CMD, false), Some(EditAction::Copy));
        assert_eq!(edit_action(Key::Char(b'x'), CMD, false), Some(EditAction::Cut));
        assert_eq!(edit_action(Key::Char(b'v'), CMD, false), Some(EditAction::Paste));
    }

    #[test]
    fn undo_and_its_two_spellings_of_redo() {
        let shifted = Mods {
            command: true,
            shift: true,
            ..NONE
        };
        assert_eq!(edit_action(Key::Char(b'z'), CMD, false), Some(EditAction::Undo));
        assert_eq!(
            edit_action(Key::Char(b'z'), shifted, false),
            Some(EditAction::Redo)
        );
        assert_eq!(edit_action(Key::Char(b'y'), CMD, false), Some(EditAction::Redo));
        assert_eq!(
            edit_action(Key::Char(b'y'), shifted, false),
            Some(EditAction::Redo),
            "⌘Y ignores shift on both platforms or it is two chords"
        );
    }

    #[test]
    fn option_widens_an_arrow_to_a_word() {
        assert_eq!(
            edit_action(Key::Left, NONE, false),
            Some(EditAction::Move {
                motion: Motion::Grapheme(Direction::Backward),
                extend: false,
            }),
        );
        assert_eq!(
            edit_action(Key::Left, OPTION, false),
            Some(EditAction::Move {
                motion: Motion::Word(Direction::Backward),
                extend: false,
            }),
        );
        assert_eq!(
            edit_action(Key::Backspace, OPTION, false),
            Some(EditAction::Delete(Motion::Word(Direction::Backward))),
        );
    }

    /// The bare arrows are the history's; the shifted ones are the document's.
    #[test]
    fn shift_turns_a_history_walk_into_a_selection() {
        assert_eq!(
            edit_action(Key::Up, NONE, false),
            Some(EditAction::HistoryPrevious)
        );
        assert_eq!(edit_action(Key::Down, NONE, false), Some(EditAction::HistoryNext));
        assert_eq!(
            edit_action(Key::Up, SHIFT, false),
            Some(EditAction::Move {
                motion: Motion::Line(Direction::Backward),
                extend: true,
            }),
        );
    }

    #[test]
    fn the_command_arrows_reach_both_edges() {
        assert_eq!(
            edit_action(Key::Left, CMD, false),
            Some(EditAction::Move {
                motion: Motion::LineEdge(Direction::Backward),
                extend: false,
            }),
        );
        assert_eq!(
            edit_action(Key::Up, CMD, false),
            Some(EditAction::Move {
                motion: Motion::DocEdge(Direction::Backward),
                extend: false,
            }),
        );
    }

    /// The keys that were never the line's: an editor that swallowed them would take the scrollback
    /// away by existing.
    #[test]
    fn the_pages_belong_to_the_viewport() {
        assert_eq!(
            edit_action(Key::PageUp, NONE, false),
            Some(EditAction::ScrollPages(-1))
        );
        assert_eq!(
            edit_action(Key::PageDown, NONE, false),
            Some(EditAction::ScrollPages(1))
        );
    }

    #[test]
    fn return_runs_it_and_the_two_openers_add_a_line() {
        assert_eq!(edit_action(Key::Return, NONE, false), Some(EditAction::Submit));
        assert_eq!(
            edit_action(Key::Return, OPTION, false),
            Some(EditAction::InsertNewline),
        );
        assert_eq!(
            edit_action(Key::Return, SHIFT, false),
            Some(EditAction::InsertNewline)
        );
    }

    #[test]
    fn tab_completes_and_shift_tab_walks_back() {
        assert_eq!(
            edit_action(Key::Tab, NONE, false),
            Some(EditAction::CompleteForward)
        );
        assert_eq!(
            edit_action(Key::Tab, SHIFT, false),
            Some(EditAction::CompleteBackward)
        );
        assert_eq!(edit_action(Key::Escape, NONE, false), Some(EditAction::Cancel));
    }
}
