//! What one key event is CALLED, for the two surfaces that key bindings on it.
//!
//! A chord is looked up twice in this app: the dispatcher resolves a live keystroke against the
//! binding table, and the Settings recorder captures one to persist. Both start from the same two
//! signals — a hardware key code and the characters the layout produces with ⌘⌥⌃ folded out — and
//! both must land on the SAME name, or a rebind captured in Settings never matches the chord the
//! dispatcher builds. That is why the table lives here once instead of beside each caller.
//!
//! ## The names are the config file's names
//!
//! [`NamedKey::canonical`] returns exactly the spellings `slopdesk_terminal::keybind` stores, so a
//! chord captured in the recorder is a chord the config grammar can express. Nothing here depends
//! on that crate — the agreement is pinned by a test where both are visible, in `slopdesk-ffi`.
//!
//! ## Two callers, two acceptance rules, on purpose
//!
//! Space is a NAMED key for the dispatcher and no key at all for the recorder: ⌃⇧Space enters Vi
//! mode, while a bare Space is typing that must reach the terminal — and a recorder that offered
//! Space would let the user bind the space bar itself. And the recorder is stricter about printable
//! characters than the dispatcher, because its answer is PERSISTED: a key it cannot spell back is a
//! config line nobody can read, where the dispatcher merely fails to match this keystroke.

use crate::key_capture::is_escape;

/// `kVK_Delete` — Backspace, which CLEARS a binding rather than recording one.
pub const KEY_CODE_DELETE: u16 = 51;
/// `kVK_ForwardDelete` — the other clear key.
pub const KEY_CODE_FORWARD_DELETE: u16 = 117;

/// A non-printable key the workspace binds by name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamedKey {
    /// Return, and the keypad's Enter with it — one name for one intent.
    Return,
    /// Tab.
    Tab,
    /// The space bar, which only the dispatcher ever names.
    Space,
    /// ←.
    Left,
    /// →.
    Right,
    /// ↑.
    Up,
    /// ↓.
    Down,
    /// Page Up.
    PageUp,
    /// Page Down.
    PageDown,
    /// Home.
    Home,
    /// End.
    End,
}

impl NamedKey {
    /// The ONE spelling this key is stored under — `slopdesk_terminal::keybind`'s canonical form.
    #[must_use]
    pub const fn canonical(self) -> &'static str {
        match self {
            Self::Return => "return",
            Self::Tab => "tab",
            Self::Space => "space",
            Self::Left => "left",
            Self::Right => "right",
            Self::Up => "up",
            Self::Down => "down",
            Self::PageUp => "pageup",
            Self::PageDown => "pagedown",
            Self::Home => "home",
            Self::End => "end",
        }
    }

    /// The case index the boundary carries, so a caller that already has its own enum can rebuild
    /// it without the text.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Return => 0,
            Self::Tab => 1,
            Self::Space => 2,
            Self::Left => 3,
            Self::Right => 4,
            Self::Up => 5,
            Self::Down => 6,
            Self::PageUp => 7,
            Self::PageDown => 8,
            Self::Home => 9,
            Self::End => 10,
        }
    }
}

/// The named key a hardware code is, EXCLUDING the space bar.
///
/// Return and keypad Enter fold onto one name: they are the same intent, and a binding made on one
/// keyboard has to fire on the other.
#[must_use]
pub const fn named_key(key_code: u16) -> Option<NamedKey> {
    match key_code {
        36 | 76 => Some(NamedKey::Return),
        48 => Some(NamedKey::Tab),
        123 => Some(NamedKey::Left),
        124 => Some(NamedKey::Right),
        126 => Some(NamedKey::Up),
        125 => Some(NamedKey::Down),
        116 => Some(NamedKey::PageUp),
        121 => Some(NamedKey::PageDown),
        115 => Some(NamedKey::Home),
        119 => Some(NamedKey::End),
        _ => None,
    }
}

/// The named key the DISPATCHER sees, which is the table above plus a modified Space.
///
/// A bare or ⇧-only Space is normal typing and must reach the terminal; with ⌃, ⌥ or ⌘ held it is
/// the Vi-mode chord instead. Anything else about the space bar would either steal the space
/// character or make ⌃⇧Space unbindable.
#[must_use]
pub const fn dispatch_named_key(key_code: u16, non_shift_modifier_held: bool) -> Option<NamedKey> {
    match key_code {
        49 if non_shift_modifier_held => Some(NamedKey::Space),
        49 => None,
        code => named_key(code),
    }
}

/// The printable base character a keystroke carries, for the DISPATCHER.
///
/// One character, lower-cased so ⇧ lives in the modifier set rather than in the key, and never a
/// whitespace or control scalar — those are typing, and a chord that swallowed them would eat the
/// terminal's own input. A ⌃-letter still reports its printable base, which is what makes ⌃B a
/// chord.
#[must_use]
pub fn dispatch_base_character(characters_ignoring_modifiers: &str) -> Option<char> {
    let mut chars = characters_ignoring_modifiers.chars();
    let first = chars.next()?;
    if chars.next().is_some() || first.is_whitespace() || is_control(first) {
        return None;
    }
    lowercased(first)
}

/// The printable base character the RECORDER will persist.
///
/// Stricter than the dispatcher's by one clause: the character must be ASCII or a letter. The
/// recorder's answer is written to a config file and read back by the chord grammar, so a key it
/// cannot spell has to be refused at capture time rather than stored as a chord nobody can type.
#[must_use]
pub fn capture_base_character(characters_ignoring_modifiers: &str) -> Option<char> {
    let first = dispatch_base_character(characters_ignoring_modifiers)?;
    (first.is_ascii() || first.is_alphabetic()).then_some(first)
}

/// What capturing one keystroke in the chord recorder means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CaptureOutcome {
    /// Escape — stop recording and change nothing.
    Cancel,
    /// Backspace or Forward-Delete — CLEAR the binding, restoring the registry default.
    Clear,
    /// A pure modifier, a dead key, or anything unspellable: keep recording.
    #[default]
    Ignore,
    /// Record this keystroke's base key as the override.
    Bind,
}

/// What one captured keystroke does to the binding being recorded.
///
/// The clear keys are checked BEFORE the printable base: Backspace's characters are the DEL scalar,
/// which is neither whitespace nor a control character by every naive test, so a recorder that
/// asked for the base key first would store `\u{7f}` as a chord instead of clearing the binding.
#[must_use]
pub fn capture_outcome(key_code: u16, characters_ignoring_modifiers: &str) -> CaptureOutcome {
    if is_escape(key_code) {
        return CaptureOutcome::Cancel;
    }
    if key_code == KEY_CODE_DELETE || key_code == KEY_CODE_FORWARD_DELETE {
        return CaptureOutcome::Clear;
    }
    if capture_base_key(key_code, characters_ignoring_modifiers).is_some() {
        CaptureOutcome::Bind
    } else {
        CaptureOutcome::Ignore
    }
}

/// The base key a captured keystroke would be stored under, or `None` when there is nothing to
/// store.
#[must_use]
pub fn capture_base_key(key_code: u16, characters_ignoring_modifiers: &str) -> Option<String> {
    named_key(key_code).map_or_else(
        || capture_base_character(characters_ignoring_modifiers).map(String::from),
        |named| Some(named.canonical().to_owned()),
    )
}

/// Whether a character is a C0 control or DEL — never a base key, however printable it looks.
const fn is_control(character: char) -> bool {
    let value = character as u32;
    value < 0x20 || value == 0x7F
}

/// A character's lowercase form, when it HAS a single-character one.
///
/// A multi-character lowering (`İ` lowers to two scalars) is not a base key: it could not be typed
/// back as one, so it is refused rather than truncated.
fn lowercased(character: char) -> Option<char> {
    let mut lower = character.to_lowercase();
    let first = lower.next()?;
    lower.next().is_none().then_some(first)
}

#[cfg(test)]
mod tests {
    use super::{
        CaptureOutcome, NamedKey, capture_base_character, capture_base_key, capture_outcome,
        dispatch_base_character, dispatch_named_key, named_key,
    };

    #[test]
    fn the_two_surfaces_read_the_same_table() {
        for code in [36, 76, 48, 123, 124, 126, 125, 116, 121, 115, 119] {
            assert_eq!(
                named_key(code),
                dispatch_named_key(code, false),
                "only the space bar may differ between the two"
            );
        }
        assert_eq!(named_key(36), Some(NamedKey::Return));
        assert_eq!(named_key(76), Some(NamedKey::Return), "keypad Enter is Return");
    }

    #[test]
    fn the_space_bar_is_a_chord_only_with_a_non_shift_modifier() {
        assert_eq!(dispatch_named_key(49, true), Some(NamedKey::Space));
        assert_eq!(dispatch_named_key(49, false), None, "a bare space is typing");
        assert_eq!(named_key(49), None, "the recorder never offers the space bar");
    }

    #[test]
    fn the_case_indexes_are_dense_and_distinct() {
        let all = [
            NamedKey::Return,
            NamedKey::Tab,
            NamedKey::Space,
            NamedKey::Left,
            NamedKey::Right,
            NamedKey::Up,
            NamedKey::Down,
            NamedKey::PageUp,
            NamedKey::PageDown,
            NamedKey::Home,
            NamedKey::End,
        ];
        for (position, key) in all.iter().enumerate() {
            assert_eq!(usize::from(key.index()), position);
            assert!(!key.canonical().is_empty());
        }
    }

    #[test]
    fn a_base_character_is_one_printable_lower_case_key() {
        assert_eq!(dispatch_base_character("D"), Some('d'));
        assert_eq!(dispatch_base_character("]"), Some(']'));
        assert_eq!(dispatch_base_character(""), None);
        assert_eq!(dispatch_base_character("ab"), None, "two keys are not a key");
        assert_eq!(dispatch_base_character(" "), None, "whitespace is typing");
        assert_eq!(dispatch_base_character("\u{7f}"), None, "DEL is not printable");
        assert_eq!(dispatch_base_character("\u{2}"), None, "nor is a C0 control");
    }

    #[test]
    fn the_recorder_refuses_what_it_could_not_spell_back() {
        assert_eq!(capture_base_character("é"), Some('é'), "a letter is spellable");
        assert_eq!(capture_base_character("→"), None, "an arrow glyph is not");
        assert_eq!(
            dispatch_base_character("→"),
            Some('→'),
            "the dispatcher merely fails to match it, so it need not refuse it"
        );
    }

    #[test]
    fn backspace_clears_before_its_characters_are_ever_read() {
        // The bug this ordering exists for: DEL is ASCII and not whitespace, so a base-key-first
        // recorder stored it as a junk chord instead of clearing the binding.
        assert_eq!(capture_outcome(51, "\u{7f}"), CaptureOutcome::Clear);
        assert_eq!(capture_outcome(117, "\u{7f}"), CaptureOutcome::Clear);
        assert_eq!(capture_outcome(53, ""), CaptureOutcome::Cancel);
    }

    #[test]
    fn a_keystroke_with_nothing_to_store_keeps_recording() {
        assert_eq!(capture_outcome(999, ""), CaptureOutcome::Ignore);
        assert_eq!(capture_outcome(49, " "), CaptureOutcome::Ignore, "the space bar");
        assert_eq!(capture_outcome(0, "a"), CaptureOutcome::Bind);
        assert_eq!(capture_base_key(0, "A").as_deref(), Some("a"));
        assert_eq!(capture_base_key(36, "\r").as_deref(), Some("return"));
        assert_eq!(capture_base_key(999, "\u{7f}"), None);
    }
}
