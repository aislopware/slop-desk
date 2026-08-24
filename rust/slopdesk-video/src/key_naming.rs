//! What one key event is CALLED, for the dispatcher that keys bindings on it.
//!
//! A live keystroke arrives as two signals — a hardware key code and the characters the layout
//! produces with ⌘⌥⌃ folded out — and has to land on the name the binding table is keyed by. That
//! table lives here once instead of beside each caller.
//!
//! ## The names are the config file's names
//!
//! [`NamedKey::canonical`] returns exactly the spellings `slopdesk_terminal::keybind` stores, so a
//! chord the dispatcher builds is a chord a `keybind` line in the config file can name. Nothing
//! here depends on that crate — the agreement is pinned by a test where both are visible, in
//! `slopdesk-ffi`.
//!
//! ## The space bar is the one conditional row
//!
//! A bare or ⇧-only Space is typing that must reach the terminal; with ⌃, ⌥ or ⌘ held it is the
//! Vi-mode chord instead. That is the whole of why [`dispatch_named_key`] takes a modifier flag
//! where [`named_key`] does not.

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
    /// Every named key, in case-index order.
    pub const ALL: [Self; 11] = [
        Self::Return,
        Self::Tab,
        Self::Space,
        Self::Left,
        Self::Right,
        Self::Up,
        Self::Down,
        Self::PageUp,
        Self::PageDown,
        Self::Home,
        Self::End,
    ];

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

    /// The key a case index names, or `None` for an index no case has — a caller whose own enum has
    /// fewer cases than this one, which must not be guessed at.
    #[must_use]
    pub fn from_index(index: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|key| key.index() == index)
    }

    /// The key a canonical spelling names, or `None` for anything else — a single character, an
    /// alias the config grammar folds, or a token nothing produces.
    #[must_use]
    pub fn from_canonical(text: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|key| key.canonical() == text)
    }
}

/// The named key a hardware code is, before the space bar's conditional row.
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
    use super::{NamedKey, dispatch_base_character, dispatch_named_key, named_key};

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
        assert_eq!(named_key(49), None, "the unconditional table has no space row");
    }

    #[test]
    fn the_case_indexes_are_dense_and_distinct() {
        for (position, key) in NamedKey::ALL.iter().enumerate() {
            assert_eq!(usize::from(key.index()), position);
            assert!(!key.canonical().is_empty());
        }
    }

    #[test]
    fn both_lookups_are_the_inverses_they_claim_to_be() {
        for key in NamedKey::ALL {
            assert_eq!(NamedKey::from_index(key.index()), Some(key));
            assert_eq!(NamedKey::from_canonical(key.canonical()), Some(key));
        }
        assert_eq!(
            NamedKey::from_index(11),
            None,
            "an index this build has no case for"
        );
        assert_eq!(
            NamedKey::from_canonical("pgup"),
            None,
            "an alias is not a spelling"
        );
        assert_eq!(NamedKey::from_canonical("d"), None);
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
    fn a_glyph_no_config_line_could_spell_still_reaches_the_dispatcher() {
        // The dispatcher does not have to REFUSE what the config grammar cannot write: a chord
        // nobody can spell in `config.toml` is a chord nothing binds, so it simply fails to match.
        assert_eq!(dispatch_base_character("→"), Some('→'));
        assert_eq!(dispatch_base_character("é"), Some('é'));
    }
}
