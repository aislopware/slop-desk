//! Which control keys the editor may NOT have.
//!
//! With the app's editor owning the command line, a press at an idle prompt goes to
//! [`super::CommandEditor`] and the shell sees nothing until Enter. That is the point, and it is
//! wrong for a handful of keys: `readline` never owned them either. `⌃C` abandons the line at the
//! SHELL, which prints `^C` and a fresh prompt; `⌃D` on an empty line is EOF and is how a shell is
//! exited; `⌃Z` is the job-control signal; `⌃L` clears the SCREEN, which the editor does not own.
//! Swallow any of those and the terminal has a state the user cannot get out of.
//!
//! This is a rule and not a table lookup in the view because two views ask it — `docs/68` §10 puts
//! key NAMING in the platform view and the decision here, and the phone will ask the same question
//! with a `UIKeyCommand` instead of an `NSEvent`.
//!
//! ## Why the byte is not in the answer
//!
//! A control letter's byte is `letter & 0x1F` and always has been; the caller already holds the
//! letter. Answering the byte too would put the ASCII arithmetic on this side of a door for no
//! decision — and a caller that got it wrong would be sending the wrong byte either way.

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

#[cfg(test)]
mod tests {
    use super::{ControlAction, control_action};

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
}
