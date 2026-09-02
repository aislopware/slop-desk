//! A text spelling for a run of keystrokes, so that "what the user typed" can be written down.
//!
//! This exists for one reason: a recorded terminal session is only an honest test of the INPUT path
//! if the bytes in it were produced by [`crate::VtSession::encode_key`] rather than typed out by
//! hand. A recorder needs to say "press ⌃C" in a file; the replay needs to say the same thing and
//! get the same bytes. Spelling the press twice — once in the recorder, once in the test — would be
//! two vocabularies to keep in step, so the spelling lives here and both sides parse it.
//!
//! ## The grammar
//!
//! A script is text. Every character stands for itself and is sent as an IME-style text event, the
//! way a keyboard layout hands one over. `<` opens a named key: `<Enter>`, `<Tab>`, `<Escape>`,
//! `<Space>`, `<Backspace>`, `<Delete>`, `<Up>`, `<Down>`, `<Left>`, `<Right>`, `<Home>`, `<End>`,
//! `<PageUp>`, `<PageDown>`, `<F1>`…`<F12>`. A named key may carry modifier prefixes: `<C-c>`,
//! `<A-x>`, `<S-Tab>`, `<C-S-a>`, where `C` is Control, `A` is Alt/Option, `S` is Shift and `D` is
//! Command. `<lt>` is a literal `<`.
//!
//! ## What it does NOT decide
//!
//! Timing. A script says what was pressed and in what order, never how long the gap was — a
//! recording carries the pty reads between presses, and those are the only ordering that matters to
//! a terminal. Nothing here sleeps.

pub use libghostty_vt::key::Key;

use crate::input::{KeyAction, KeyPress, Mods};

/// Why a script could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScriptError {
    /// A `<` was opened and the script ended before its `>`.
    Unterminated {
        /// Byte offset of the `<` that was never closed.
        at: usize,
    },
    /// A `<…>` named something this vocabulary does not have.
    UnknownKey {
        /// The name between the angle brackets.
        name: String,
        /// Byte offset of the opening `<`.
        at: usize,
    },
}

impl core::fmt::Display for ScriptError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Unterminated { at } => write!(f, "unterminated `<` at byte {at}"),
            Self::UnknownKey { name, at } => write!(f, "unknown key `<{name}>` at byte {at}"),
        }
    }
}

impl core::error::Error for ScriptError {}

/// One keystroke, owning its text so that a parsed script outlives the string it came from.
///
/// [`KeyPress`] borrows its text, which is right on the hot path and wrong for a parsed script that
/// a caller wants to hold. [`KeyEvent::press`] is the conversion, and it is where the borrow
/// starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEvent {
    /// The logical key, when the spelling named one.
    pub key: Option<Key>,
    /// Everything held.
    pub mods: Mods,
    /// The text a layout would have produced, for the events that carry text.
    pub text: Option<String>,
    /// What the key produces unmodified.
    pub unshifted: Option<char>,
    /// The modifiers a layout already spent producing [`Self::text`].
    pub consumed_mods: Mods,
}

impl KeyEvent {
    /// The borrowed press this event stands for.
    #[must_use]
    pub fn press(&self) -> KeyPress<'_> {
        KeyPress {
            key: self.key,
            action: KeyAction::Press,
            mods: self.mods,
            consumed_mods: self.consumed_mods,
            text: self.text.as_deref(),
            unshifted: self.unshifted,
            composing: false,
        }
    }
}

/// Reads a script into the presses it spells.
///
/// # Errors
/// [`ScriptError`] for an unterminated or unknown `<…>`. Ordinary characters cannot fail.
pub fn parse(script: &str) -> Result<Vec<KeyEvent>, ScriptError> {
    let mut events = Vec::new();
    let mut rest = script;
    let mut offset = 0_usize;

    while let Some(ch) = rest.chars().next() {
        let width = ch.len_utf8();
        if ch != '<' {
            events.push(text_event(ch));
            rest = rest.get(width..).unwrap_or_default();
            offset += width;
            continue;
        }

        let body_start = rest.get(width..).unwrap_or_default();
        let Some(end) = body_start.find('>') else {
            return Err(ScriptError::Unterminated { at: offset });
        };
        let name = body_start.get(..end).unwrap_or_default();
        events.push(named_event(name, offset)?);
        rest = body_start.get(end.saturating_add(1)..).unwrap_or_default();
        offset += width.saturating_add(end).saturating_add(1);
    }

    Ok(events)
}

/// The press an ordinary character stands for.
///
/// Text rather than a keycode is what a layout actually hands a terminal: the platform has already
/// resolved the layout, the dead keys and the shift level, and the key identity is only there so
/// that the kitty protocol has something to report. An uppercase letter therefore says Shift was
/// held AND spent, which is what stops the encoder reporting a modifier the text already contains.
fn text_event(ch: char) -> KeyEvent {
    let lowered = ch.to_lowercase().next().unwrap_or(ch);
    let shifted = ch != lowered;
    KeyEvent {
        key: key_for_char(lowered),
        mods: if shifted { Mods::SHIFT } else { Mods::NONE },
        text: Some(ch.to_string()),
        unshifted: Some(lowered),
        consumed_mods: if shifted { Mods::SHIFT } else { Mods::NONE },
    }
}

/// The press a `<…>` stands for, modifier prefixes included.
fn named_event(name: &str, at: usize) -> Result<KeyEvent, ScriptError> {
    let mut mods = Mods::NONE;
    let mut rest = name;
    while let Some((prefix, tail)) = rest.split_once('-') {
        let held = match prefix {
            "C" => Mods::CTRL,
            "A" | "M" => Mods::ALT,
            "S" => Mods::SHIFT,
            "D" => Mods::SUPER,
            _ => break,
        };
        // A bare `-` is a key, not an empty modifier: `<C-->` is Control and the minus key.
        if tail.is_empty() {
            break;
        }
        mods = mods.union(held);
        rest = tail;
    }

    if rest == "lt" && mods == Mods::NONE {
        return Ok(text_event('<'));
    }

    let key = key_for_name(rest).ok_or_else(|| {
        ScriptError::UnknownKey {
            name: name.to_owned(),
            at,
        }
    })?;

    // A modified key carries no text. That is not a shortcut: the platform does not produce text
    // for ⌃C either, and forwarding some would make the encoder subtract the very modifier the
    // sequence is about.
    Ok(KeyEvent {
        key: Some(key),
        mods,
        text: None,
        unshifted: single_char(rest),
        consumed_mods: Mods::NONE,
    })
}

/// The one character a name stands for, when it is one character.
fn single_char(name: &str) -> Option<char> {
    let mut chars = name.chars();
    let first = chars.next()?;
    chars.next().is_none().then_some(first)
}

/// The key identity behind an ordinary character, where there is one.
///
/// `None` is a normal answer and not a gap: a character with no key on a US layout is still text,
/// and text is what the event carries.
const fn key_for_char(ch: char) -> Option<Key> {
    Some(match ch {
        'a' => Key::A,
        'b' => Key::B,
        'c' => Key::C,
        'd' => Key::D,
        'e' => Key::E,
        'f' => Key::F,
        'g' => Key::G,
        'h' => Key::H,
        'i' => Key::I,
        'j' => Key::J,
        'k' => Key::K,
        'l' => Key::L,
        'm' => Key::M,
        'n' => Key::N,
        'o' => Key::O,
        'p' => Key::P,
        'q' => Key::Q,
        'r' => Key::R,
        's' => Key::S,
        't' => Key::T,
        'u' => Key::U,
        'v' => Key::V,
        'w' => Key::W,
        'x' => Key::X,
        'y' => Key::Y,
        'z' => Key::Z,
        '0' => Key::Digit0,
        '1' => Key::Digit1,
        '2' => Key::Digit2,
        '3' => Key::Digit3,
        '4' => Key::Digit4,
        '5' => Key::Digit5,
        '6' => Key::Digit6,
        '7' => Key::Digit7,
        '8' => Key::Digit8,
        '9' => Key::Digit9,
        ' ' => Key::Space,
        '-' => Key::Minus,
        '=' => Key::Equal,
        '[' => Key::BracketLeft,
        ']' => Key::BracketRight,
        '\\' => Key::Backslash,
        ';' => Key::Semicolon,
        '\'' => Key::Quote,
        ',' => Key::Comma,
        '.' => Key::Period,
        '/' => Key::Slash,
        '`' => Key::Backquote,
        _ => return None,
    })
}

/// The key a `<…>` name stands for.
fn key_for_name(name: &str) -> Option<Key> {
    if let Some(key) = single_char(name).and_then(key_for_char) {
        return Some(key);
    }
    Some(match name {
        "Enter" | "CR" | "Return" => Key::Enter,
        "Tab" => Key::Tab,
        "Escape" | "Esc" => Key::Escape,
        "Space" => Key::Space,
        "Backspace" | "BS" => Key::Backspace,
        "Delete" | "Del" => Key::Delete,
        "Insert" => Key::Insert,
        "Up" => Key::ArrowUp,
        "Down" => Key::ArrowDown,
        "Left" => Key::ArrowLeft,
        "Right" => Key::ArrowRight,
        "Home" => Key::Home,
        "End" => Key::End,
        "PageUp" => Key::PageUp,
        "PageDown" => Key::PageDown,
        "F1" => Key::F1,
        "F2" => Key::F2,
        "F3" => Key::F3,
        "F4" => Key::F4,
        "F5" => Key::F5,
        "F6" => Key::F6,
        "F7" => Key::F7,
        "F8" => Key::F8,
        "F9" => Key::F9,
        "F10" => Key::F10,
        "F11" => Key::F11,
        "F12" => Key::F12,
        _ => return None,
    })
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{Key, Mods, ScriptError, parse};

    #[test]
    fn plain_characters_are_text_events() {
        let events = parse("hi").expect("parse");
        assert_eq!(events.len(), 2);
        assert_eq!(events.first().and_then(|e| e.key), Some(Key::H));
        assert_eq!(events.first().and_then(|e| e.text.as_deref()), Some("h"));
        assert_eq!(events.first().map(|e| e.mods), Some(Mods::NONE));
    }

    #[test]
    fn an_uppercase_letter_spends_the_shift_it_holds() {
        let events = parse("H").expect("parse");
        let event = events.first().expect("one event");
        assert_eq!(event.text.as_deref(), Some("H"));
        assert_eq!(event.mods, Mods::SHIFT);
        // Held AND consumed: the text already contains the shift, so the encoder must not report
        // it a second time.
        assert_eq!(event.consumed_mods, Mods::SHIFT);
        assert_eq!(event.unshifted, Some('h'));
    }

    #[test]
    fn a_modified_key_carries_no_text() {
        let events = parse("<C-c>").expect("parse");
        let event = events.first().expect("one event");
        assert_eq!(event.key, Some(Key::C));
        assert_eq!(event.mods, Mods::CTRL);
        assert_eq!(event.text, None);
    }

    #[test]
    fn modifiers_stack() {
        let events = parse("<C-S-a>").expect("parse");
        let event = events.first().expect("one event");
        assert_eq!(event.mods, Mods::CTRL.union(Mods::SHIFT));
        assert_eq!(event.key, Some(Key::A));
    }

    #[test]
    fn a_bare_minus_is_a_key_not_an_empty_modifier() {
        let events = parse("<C-->").expect("parse");
        let event = events.first().expect("one event");
        assert_eq!(event.mods, Mods::CTRL);
        assert_eq!(event.key, Some(Key::Minus));
    }

    #[test]
    fn lt_is_the_literal_bracket() {
        let events = parse("<lt>").expect("parse");
        assert_eq!(events.first().and_then(|e| e.text.as_deref()), Some("<"));
    }

    #[test]
    fn named_keys_and_text_interleave() {
        let events = parse("ls<Enter>").expect("parse");
        assert_eq!(events.len(), 3);
        assert_eq!(events.get(2).and_then(|e| e.key), Some(Key::Enter));
    }

    #[test]
    fn an_unterminated_bracket_names_its_offset() {
        assert_eq!(parse("ab<Ent"), Err(ScriptError::Unterminated { at: 2 }));
    }

    #[test]
    fn an_unknown_name_is_an_error_rather_than_a_silent_drop() {
        let Err(ScriptError::UnknownKey { name, at }) = parse("<Nope>") else {
            panic!("expected an unknown-key error");
        };
        assert_eq!(name, "Nope");
        assert_eq!(at, 0);
    }

    #[test]
    fn multibyte_text_keeps_its_offsets() {
        // The offset arithmetic is in bytes; a script that starts with a 3-byte character and then
        // fails must still name the byte the `<` sits on.
        assert_eq!(parse("界<Ent"), Err(ScriptError::Unterminated { at: 3 }));
    }
}
