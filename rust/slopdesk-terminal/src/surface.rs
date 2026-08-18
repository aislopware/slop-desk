//! What a gesture at the terminal surface MEANS before anything is sent.
//!
//! Five decisions the embedder makes between an `NSEvent` and libghostty, kept together because
//! they share one shape and one hazard. The shape: each is a small guard ladder whose safe rung is
//! "do nothing local", so a case nobody thought about degrades to the behaviour that was already
//! there. The hazard is what makes them worth writing down at all — every one of them guards a way
//! the terminal could do something the user did not ask for.
//!
//! ## Who owns the click, and who owns the screen
//!
//! Two facts run through all of it. A mouse-reporting program owns the pointer, and a full-screen
//! program owns the screen; when either is true the local rule steps aside, because the bytes it
//! would inject belong to something else. That is why a cut inside `vim` copies without deleting,
//! why a right-click inside a TUI is never stolen for a paste, and why undo at the prompt is the
//! only place undo is intercepted at all.
//!
//! The surfaces that read these are compile-only behind `#if canImport(CGhostty)` on the near
//! side, which is exactly why the decisions are here: the actuator cannot be tested, so nothing
//! that can be decided is left in it.

/// What the embedder does when libghostty asks it to WRITE the pasteboard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipboardWrite {
    /// Write it now — the program is allowed (`clipboard-write = allow`).
    Write,
    /// Ask first (`clipboard-write = ask`), and write only on approval.
    Confirm,
    /// Nothing to write.
    Drop,
}

/// What a clipboard WRITE should do.
///
/// libghostty enforces `deny` and `allow` itself; `ask` is DELEGATED — it calls the write callback
/// with `confirm` set and trusts the embedder to gate. A callback that ignored that flag would make
/// "Ask" behave as "Allow", so any remote OSC 52 could overwrite the clipboard silently. That is
/// the whole reason this is a decision rather than a write.
#[must_use]
pub const fn clipboard_write(confirm_requested: bool, text: &str) -> ClipboardWrite {
    if text.is_empty() {
        return ClipboardWrite::Drop;
    }
    if confirm_requested {
        ClipboardWrite::Confirm
    } else {
        ClipboardWrite::Write
    }
}

/// What ⌘X does on the terminal surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cut {
    /// Nothing is selected.
    None,
    /// Copy, but never delete — read-only scrollback, or a program owns the screen.
    CopyOnly,
    /// Copy, and delete the selected run if its geometry can be proven.
    CopyAndDelete,
}

/// What a Cut (⌘X / Edit ▸ Cut) should do.
///
/// A full-screen program owning the screen is checked BEFORE the prompt zone: the delete bytes
/// would be that program's input, and corrupting it is worse than not cutting.
#[must_use]
pub const fn cut_action(has_selection: bool, alternate_screen: bool, prompt_zone: bool) -> Cut {
    if !has_selection {
        return Cut::None;
    }
    if alternate_screen || !prompt_zone {
        return Cut::CopyOnly;
    }
    Cut::CopyAndDelete
}

/// How many DEL (`0x7F`) bytes the delete half of a cut sends.
///
/// DEL always erases the characters immediately BEFORE the cursor, so it erases the SELECTED run
/// only when that run ends at the cursor. The pinned libghostty fork exposes no selection geometry,
/// so the embedder cannot prove it — and an optimistic pre-send over a mid-line selection would
/// delete the wrong characters, which is silent data loss. Hence a count only when the caller can
/// PROVE both facts, and `0` otherwise, which degrades the cut to a copy.
///
/// The full length rather than one less: unlike a Backspace keystroke there is no fall-through key
/// for ⌘X, so nothing else erases a character.
#[must_use]
pub fn cut_delete_count(selection: &str, selection_ends_at_cursor: bool) -> usize {
    if !selection_ends_at_cursor || selection.is_empty() {
        return 0;
    }
    if selection.contains('\n') || selection.contains('\r') {
        return 0;
    }
    selection.chars().count()
}

/// Whether a hover should claim the workspace focus.
///
/// libghostty's own `focus-follows-mouse` only relays focus inside ITS split tree, and a slopdesk
/// pane is a separate surface tiled by the client, so the cross-pane relay has to be ours.
///
/// The `!already_focused` term is load-bearing rather than an optimisation: the hover fires on
/// every pointer motion, so without it a focused pane would re-request focus on each one, redrawing
/// the title bar for as long as the mouse moves.
#[must_use]
pub const fn focus_follows_mouse(setting: bool, already_focused: bool) -> bool {
    setting && !already_focused
}

/// Apple's function-key Private Use Area. `NSEvent.h` names F700–F747; the block Apple reserves —
/// and upstream Ghostty filters — is the whole F700–F8FF.
const FUNCTION_KEY_PUA: core::ops::RangeInclusive<u32> = 0xF700..=0xF8FF;

/// Whether a key event's `characters` may be handed to libghostty's key encoder as text.
///
/// Two payloads must never be, and each one silently broke something:
///
/// * A **function-key placeholder**. `AppKit` reports every named key — arrows, `Home`/`End`,
///   F1–F20 — as a PUA codepoint. Under the kitty keyboard protocol the encoder has a printable
///   fast path, and U+F700 passes its printability check, so every arrow press typed raw bytes into
///   the application instead of `CSI A`.
/// * A **control-led payload**. The encoder subtracts consumed modifiers whenever text is present,
///   and the macOS heuristic consumes everything but Ctrl and Cmd — so forwarding `\t` or `\r`
///   erased Shift from the binding mods and collapsed Shift+Tab to a bare tab, Shift+Enter to a
///   bare return. Upstream sets text only when the first byte is ≥ 0x20; this is that guard, and
///   DEL (0x7F) passes it in both.
///
/// Only a SINGLE-scalar string can be a placeholder: a longer one is real text, composed or from an
/// IME, even in the unlikely case it embeds a PUA scalar.
#[must_use]
pub fn forwards_encoder_text(characters: &str) -> bool {
    let mut scalars = characters.chars();
    if let (Some(only), None) = (scalars.next(), scalars.next())
        && FUNCTION_KEY_PUA.contains(&(only as u32))
    {
        return false;
    }
    !matches!(characters.as_bytes().first(), Some(&byte) if byte < 0x20)
}

/// The readline UNDO control byte: Ctrl-`_`, the underscore masked to its C0 code. GNU readline and
/// zsh-zle both bind it to `undo`, so sending it at the prompt rolls back the last line edit.
pub const READLINE_UNDO: u8 = 0x1F;

/// The byte an undo/redo gesture sends to the PTY, if any.
///
/// Redo is recognised and deliberately unanswered: readline binds `C-_` and `C-x C-u` to undo and
/// exposes no inverse, so there is no portable redo to send. Recognising it here rather than in the
/// actuator is what keeps the view from inventing a byte for it.
///
/// Off the editable prompt the gesture belongs to whatever program is running — `vim` and `less`
/// keep their own undo history — so nothing is intercepted there.
#[must_use]
pub const fn prompt_edit_byte(undo: bool, redo: bool, in_prompt_zone: bool) -> Option<u8> {
    if !in_prompt_zone || redo || !undo {
        return None;
    }
    Some(READLINE_UNDO)
}

/// Whether a bare right-click must be intercepted as a paste rather than forwarded.
///
/// The bare-right-click dispatch is libghostty's, through `right-click-action`, and its own paste
/// gate only flags a newline or a bracketed-paste end. The four-danger analysis this codebase runs
/// on ⌘V — a single-line `sudo`, control characters, a trailing newline, multiple lines — is
/// therefore unreachable from a right-click unless the embedder takes the click first.
///
/// `action` is the config token, the same spelling the config file carries, so there is no second
/// vocabulary to keep in step. An unrecognised token does not intercept.
#[must_use]
pub fn right_click_intercepts_as_paste(action: &str, has_selection: bool, mouse_captured: bool) -> bool {
    if mouse_captured {
        return false;
    }
    match action {
        "paste" => true,
        // Copy-or-Paste pastes only when there is nothing selected to copy. The selection is read
        // BEFORE the click is forwarded, so it is the genuine pre-click one rather than a
        // word-select libghostty injected.
        "copy-or-paste" => !has_selection,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ClipboardWrite, Cut, READLINE_UNDO, clipboard_write, cut_action, cut_delete_count,
        focus_follows_mouse, forwards_encoder_text, prompt_edit_byte, right_click_intercepts_as_paste,
    };

    #[test]
    fn an_ask_write_confirms_and_an_empty_one_is_dropped() {
        assert_eq!(clipboard_write(true, "x"), ClipboardWrite::Confirm);
        assert_eq!(clipboard_write(false, "x"), ClipboardWrite::Write);
        assert_eq!(
            clipboard_write(true, ""),
            ClipboardWrite::Drop,
            "nothing to write is not something to ask about"
        );
    }

    #[test]
    fn a_program_owning_the_screen_downgrades_a_cut_to_a_copy() {
        assert_eq!(cut_action(true, false, true), Cut::CopyAndDelete);
        assert_eq!(
            cut_action(true, true, true),
            Cut::CopyOnly,
            "the alt screen wins over the prompt zone"
        );
        assert_eq!(cut_action(true, false, false), Cut::CopyOnly);
        assert_eq!(cut_action(false, false, true), Cut::None);
    }

    #[test]
    fn a_delete_run_is_counted_only_when_its_geometry_is_proven() {
        assert_eq!(cut_delete_count("make", true), 4);
        assert_eq!(
            cut_delete_count("make", false),
            0,
            "unproven geometry deletes nothing rather than the wrong characters"
        );
        assert_eq!(cut_delete_count("a\nb", true), 0);
        assert_eq!(cut_delete_count("a\rb", true), 0);
        assert_eq!(cut_delete_count("", true), 0);
        assert_eq!(cut_delete_count("héllo", true), 5, "characters, not bytes");
    }

    #[test]
    fn an_already_focused_pane_does_not_re_request_focus() {
        assert!(focus_follows_mouse(true, false));
        assert!(!focus_follows_mouse(true, true));
        assert!(!focus_follows_mouse(false, false));
    }

    #[test]
    fn a_function_key_placeholder_and_a_control_payload_never_become_text() {
        assert!(!forwards_encoder_text("\u{F700}"), "the up arrow");
        assert!(!forwards_encoder_text("\u{F8FF}"), "the end of the block");
        assert!(!forwards_encoder_text("\t"));
        assert!(!forwards_encoder_text("\r"));
        assert!(forwards_encoder_text("a"));
        assert!(forwards_encoder_text("\u{7F}"), "DEL is 0x7F, above the guard");
        assert!(forwards_encoder_text("こんにちは"), "IME output is real text");
        assert!(
            forwards_encoder_text("\u{F700}x"),
            "a longer string is text even where it embeds a placeholder"
        );
    }

    #[test]
    fn undo_is_intercepted_only_at_the_prompt_and_redo_never_is() {
        assert_eq!(prompt_edit_byte(true, false, true), Some(READLINE_UNDO));
        assert_eq!(prompt_edit_byte(true, false, false), None);
        assert_eq!(
            prompt_edit_byte(false, true, true),
            None,
            "there is no portable readline redo to send"
        );
        assert_eq!(prompt_edit_byte(false, false, true), None);
    }

    #[test]
    fn a_captured_pointer_keeps_its_right_click() {
        assert!(right_click_intercepts_as_paste("paste", false, false));
        assert!(!right_click_intercepts_as_paste("paste", false, true));
        assert!(right_click_intercepts_as_paste("copy-or-paste", false, false));
        assert!(
            !right_click_intercepts_as_paste("copy-or-paste", true, false),
            "with a selection it copies, which needs no protection"
        );
        for action in ["context-menu", "copy", "ignore", "not-an-action"] {
            assert!(!right_click_intercepts_as_paste(action, false, false));
        }
    }
}
