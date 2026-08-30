//! One hardware key press → what a device panel sends for it.
//!
//! Both panels ask the same question in the same order — *does this key have a character of its
//! own?* — and answer it differently only at the last step, where the Android bridge wants a
//! `KeyEvent` keycode and the simulator's WebSocket wants a `KeyboardEvent.code` string. So the
//! question lives here once and each panel's vocabulary hangs off the answer.
//!
//! ## The four tables that were two
//!
//! The Swift this replaces held FOUR maps: each panel had one keyed by macOS virtual keycode and
//! one keyed by USB HID usage, because a Mac reports the first and an iPad reports the second. Two
//! of those four never needed to exist. [`crate`]'s sibling `slopdesk-workspace` already answers
//! *which macOS keycode is this HID usage* for the remote-desktop path, and composing that with
//! the keycode table below reproduces the HID tables row for row — I checked all fourteen. Keeping
//! them was the two-spellings shape `docs/55` §8 catalogues, one join removed.
//!
//! What is left is one table per QUESTION: which functional key a macOS keycode is, what the
//! simulator calls it, and what Android numbers it. Neither of the last two can be derived — they
//! are the two servers' own vocabularies — but neither is written twice either.
//!
//! ## Why the run stops where it does
//!
//! Only the keys that produce NO character are here. Everything printable rides the panel's text
//! path using the event's own characters, which costs nothing to maintain and respects whatever
//! layout the user actually has: a Vietnamese, French or Dvorak keyboard produces the right letter
//! without this module knowing those layouts exist. Adding a printable key here would be a silent
//! regression for every non-US layout.

use slopdesk_video::input_event::InputModifiers;

/// A key that produces no character of its own, under the panels' shared vocabulary.
///
/// Both Returns are [`FunctionalKey::Enter`]: neither server's table has a keypad variant, and a
/// text field that told them apart would be wrong on every keyboard with a numeric pad.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FunctionalKey {
    /// Return, and the keypad's Enter.
    Enter = 0,
    /// Backspace — the key macOS calls Delete.
    Backspace = 1,
    /// Forward delete.
    ForwardDelete = 2,
    /// Tab.
    Tab = 3,
    /// Escape.
    Escape = 4,
    /// ←.
    ArrowLeft = 5,
    /// →.
    ArrowRight = 6,
    /// ↑.
    ArrowUp = 7,
    /// ↓.
    ArrowDown = 8,
    /// Home.
    Home = 9,
    /// End.
    End = 10,
    /// Page Up.
    PageUp = 11,
    /// Page Down.
    PageDown = 12,
    /// Space.
    ///
    /// ⚠️ In the run because the SIMULATOR names it; Android deliberately has no keycode for it
    /// (see [`FunctionalKey::android_keycode`]), so a space still travels as text there.
    Space = 13,
}

impl FunctionalKey {
    /// Every key in the run, for a caller that has to prove it covers them.
    pub const ALL: [Self; 14] = [
        Self::Enter,
        Self::Backspace,
        Self::ForwardDelete,
        Self::Tab,
        Self::Escape,
        Self::ArrowLeft,
        Self::ArrowRight,
        Self::ArrowUp,
        Self::ArrowDown,
        Self::Home,
        Self::End,
        Self::PageUp,
        Self::PageDown,
        Self::Space,
    ];

    /// The case index this key crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        self as u8
    }

    /// The key an index names, or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Enter),
            1 => Some(Self::Backspace),
            2 => Some(Self::ForwardDelete),
            3 => Some(Self::Tab),
            4 => Some(Self::Escape),
            5 => Some(Self::ArrowLeft),
            6 => Some(Self::ArrowRight),
            7 => Some(Self::ArrowUp),
            8 => Some(Self::ArrowDown),
            9 => Some(Self::Home),
            10 => Some(Self::End),
            11 => Some(Self::PageUp),
            12 => Some(Self::PageDown),
            13 => Some(Self::Space),
            _ => None,
        }
    }

    /// The simulator server's `KeyboardEvent.code`. The server's own spelling, cut once.
    #[must_use]
    pub const fn simulator_code(self) -> &'static str {
        match self {
            Self::Enter => "Enter",
            Self::Backspace => "Backspace",
            Self::ForwardDelete => "Delete",
            Self::Tab => "Tab",
            Self::Escape => "Escape",
            Self::ArrowLeft => "ArrowLeft",
            Self::ArrowRight => "ArrowRight",
            Self::ArrowUp => "ArrowUp",
            Self::ArrowDown => "ArrowDown",
            Self::Home => "Home",
            Self::End => "End",
            Self::PageUp => "PageUp",
            Self::PageDown => "PageDown",
            Self::Space => "Space",
        }
    }

    /// Android's `KeyEvent.KEYCODE_*`, or `None` for a key Android would rather receive as text.
    ///
    /// [`FunctionalKey::Space`] is the only `None`, and it is deliberate: `KEYCODE_SPACE` exists,
    /// but a space is a character, and sending it as a keycode would take it off the text path that
    /// every other character uses — the one place a layout gets to have an opinion.
    #[must_use]
    pub const fn android_keycode(self) -> Option<u32> {
        match self {
            Self::Enter => Some(66),
            Self::Backspace => Some(67),
            Self::ForwardDelete => Some(112),
            Self::Tab => Some(61),
            Self::Escape => Some(111),
            Self::ArrowLeft => Some(21),
            Self::ArrowRight => Some(22),
            Self::ArrowUp => Some(19),
            Self::ArrowDown => Some(20),
            Self::Home => Some(122),
            Self::End => Some(123),
            Self::PageUp => Some(92),
            Self::PageDown => Some(93),
            Self::Space => None,
        }
    }
}

/// The functional key a macOS virtual keycode is, or `None` for one that types something.
///
/// LITERALS rather than `kVK_*`, because `kVK_*` lives in `Carbon.HIToolbox`, which the iOS triple
/// does not have — and this is the panels' shared floor, not a macOS-only one. The numbering is the
/// one thing about a Mac keyboard that has never moved, and the Swift suite still pins every row
/// against the real SDK constant on the half that has it.
#[must_use]
pub const fn functional_key(virtual_key_code: u16) -> Option<FunctionalKey> {
    match virtual_key_code {
        36 | 76 => Some(FunctionalKey::Enter),
        51 => Some(FunctionalKey::Backspace),
        117 => Some(FunctionalKey::ForwardDelete),
        48 => Some(FunctionalKey::Tab),
        53 => Some(FunctionalKey::Escape),
        123 => Some(FunctionalKey::ArrowLeft),
        124 => Some(FunctionalKey::ArrowRight),
        126 => Some(FunctionalKey::ArrowUp),
        125 => Some(FunctionalKey::ArrowDown),
        115 => Some(FunctionalKey::Home),
        119 => Some(FunctionalKey::End),
        116 => Some(FunctionalKey::PageUp),
        121 => Some(FunctionalKey::PageDown),
        49 => Some(FunctionalKey::Space),
        _ => None,
    }
}

/// The same question for a key numbered as a USB HID usage — what an iPad's `UIKey` reports.
///
/// DERIVED, not tabulated. `hid_virtual_key` already carries the positional map the remote-desktop
/// path uses, so this is that map composed with [`functional_key`] — which is exactly what a second
/// HID-keyed table would have spelled, and cannot drift from it.
#[must_use]
pub fn functional_key_for_hid(hid_usage: u16) -> Option<FunctionalKey> {
    slopdesk_workspace::hid_virtual_key::virtual_key(hid_usage).and_then(functional_key)
}

/// What the Android panel should do about one key-down.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AndroidResolution {
    /// Send nothing. A chord the panel cannot name, or a press with no printable output.
    Nothing,
    /// Send this `KeyEvent` keycode with this meta state.
    Keycode {
        /// `KeyEvent.KEYCODE_*`.
        keycode: u32,
        /// `KeyEvent`'s `META_*` bitmask.
        meta_state: u32,
    },
    /// Type this text.
    Text(String),
}

/// Android's `META_*` bits, which are Android's own numbering and not the wire's.
mod meta {
    /// `META_ALT_ON`.
    pub(super) const ALT: u32 = 0x02;
    /// `META_CTRL_ON`.
    pub(super) const CONTROL: u32 = 0x1000;
    /// `META_META_ON` — ⌘.
    pub(super) const META: u32 = 0x1_0000;
}

/// The meta state for a set of held modifiers.
///
/// ⚠️ **Shift is not in it.** The platform has already applied shift — the characters arriving with
/// the event are already upper case — so folding it in as well would ask the device to apply it
/// twice. That is the double-application trap `docs/47` records for scroll direction, in a
/// different channel: when the near side has already resolved something, passing the raw flag along
/// re-resolves it.
#[must_use]
pub const fn android_meta_state(modifiers: InputModifiers) -> u32 {
    let mut state = 0;
    if modifiers.contains(InputModifiers::OPTION) {
        state |= meta::ALT;
    }
    if modifiers.contains(InputModifiers::CONTROL) {
        state |= meta::CONTROL;
    }
    if modifiers.contains(InputModifiers::COMMAND) {
        state |= meta::META;
    }
    state
}

/// One key-down resolved, after the platform's numbering has been resolved away.
///
/// `characters` is what the near side's own layout produced — option-composed output, dead-key
/// resolution, the input method's answer — and `bare` is the same press with the layout's modifier
/// handling stripped. Both arrive as values, so this rule is one implementation for every UI half.
#[must_use]
pub fn resolve_android(
    functional: Option<FunctionalKey>,
    characters: Option<&str>,
    bare: Option<&str>,
    modifiers: InputModifiers,
) -> AndroidResolution {
    if let Some(keycode) = functional.and_then(FunctionalKey::android_keycode) {
        return AndroidResolution::Keycode {
            keycode,
            meta_state: android_meta_state(modifiers),
        };
    }
    // A chord with a real modifier has to reach the device AS a chord, so it would have to go as a
    // keycode; but the panel cannot know the device's layout, so only the chords with an
    // unambiguous keycode are forwarded and the rest are dropped rather than typed as stray
    // letters.
    if modifiers.contains(InputModifiers::COMMAND) || modifiers.contains(InputModifiers::CONTROL) {
        return AndroidResolution::Nothing;
    }
    let Some(bare) = bare.filter(|text| !text.is_empty()) else {
        return AndroidResolution::Nothing;
    };
    // `characters`, not `bare`, is what carries the layout's own resolution.
    let typed = characters.unwrap_or(bare);
    // Control characters would be inserted literally; there is nothing useful to type.
    let printable: String = typed.chars().filter(|scalar| !is_control(*scalar)).collect();
    if printable.is_empty() {
        AndroidResolution::Nothing
    } else {
        AndroidResolution::Text(printable)
    }
}

/// Whether a scalar is one a text field would show as nothing, or as a box.
const fn is_control(scalar: char) -> bool {
    (scalar as u32) < 0x20 || scalar as u32 == 0x7F
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hid_numbering_reaches_exactly_the_keys_the_keycode_numbering_does() {
        // The invariant the two deleted HID tables used to assert about themselves. It survives the
        // deletion because it is now a property of the composition rather than of a second table:
        // every functional key must be reachable from SOME HID usage, or an iPad cannot press it.
        let from_hid: Vec<FunctionalKey> = (0..=0xFF_u16).filter_map(functional_key_for_hid).collect();
        for key in FunctionalKey::ALL {
            assert!(
                from_hid.contains(&key),
                "{key:?} is unreachable from an iPad's numbering"
            );
        }
        let from_keycode: Vec<FunctionalKey> = (0..=0xFF_u16).filter_map(functional_key).collect();
        for key in from_hid {
            assert!(
                from_keycode.contains(&key),
                "{key:?} is reachable from an iPad but not a Mac"
            );
        }
    }

    #[test]
    fn the_two_returns_are_one_key_in_both_numberings() {
        assert_eq!(functional_key(36), Some(FunctionalKey::Enter));
        assert_eq!(functional_key(76), Some(FunctionalKey::Enter));
        assert_eq!(functional_key_for_hid(40), Some(FunctionalKey::Enter));
        assert_eq!(functional_key_for_hid(88), Some(FunctionalKey::Enter));
    }

    #[test]
    fn every_hid_row_the_deleted_table_held_still_answers_the_same_key() {
        // The fourteen rows the Swift `hidFunctionalKeys`/`byHIDUsage` maps spelled, asserted
        // against the composition that replaced them. This is the whole argument for deleting them.
        let rows: [(u16, FunctionalKey); 15] = [
            (40, FunctionalKey::Enter),
            (88, FunctionalKey::Enter),
            (42, FunctionalKey::Backspace),
            (76, FunctionalKey::ForwardDelete),
            (43, FunctionalKey::Tab),
            (41, FunctionalKey::Escape),
            (80, FunctionalKey::ArrowLeft),
            (79, FunctionalKey::ArrowRight),
            (82, FunctionalKey::ArrowUp),
            (81, FunctionalKey::ArrowDown),
            (74, FunctionalKey::Home),
            (77, FunctionalKey::End),
            (75, FunctionalKey::PageUp),
            (78, FunctionalKey::PageDown),
            (44, FunctionalKey::Space),
        ];
        for (usage, key) in rows {
            assert_eq!(functional_key_for_hid(usage), Some(key), "HID {usage}");
        }
    }

    #[test]
    fn a_printable_key_is_no_functional_key_in_either_numbering() {
        assert_eq!(functional_key(0), None, "kVK_ANSI_A types a letter");
        assert_eq!(functional_key_for_hid(4), None, "HID 4 is the same letter");
        assert_eq!(functional_key(56), None, "shift is held, not pressed");
    }

    #[test]
    fn the_index_round_trips_for_every_key_and_stops_at_the_end() {
        for key in FunctionalKey::ALL {
            assert_eq!(FunctionalKey::from_index(key.index()), Some(key));
        }
        assert_eq!(FunctionalKey::from_index(14), None);
    }

    #[test]
    fn space_is_the_simulators_key_and_androids_text() {
        assert_eq!(FunctionalKey::Space.simulator_code(), "Space");
        assert_eq!(FunctionalKey::Space.android_keycode(), None);
        assert_eq!(
            resolve_android(
                functional_key(49),
                Some(" "),
                Some(" "),
                InputModifiers::default()
            ),
            AndroidResolution::Text(" ".to_owned()),
            "a space still rides the path every other character rides",
        );
    }

    #[test]
    fn shift_is_not_a_meta_state_but_the_other_three_are() {
        assert_eq!(android_meta_state(InputModifiers::SHIFT), 0);
        assert_eq!(
            android_meta_state(InputModifiers::SHIFT.union(InputModifiers::OPTION)),
            meta::ALT,
        );
        assert_eq!(
            android_meta_state(InputModifiers::CONTROL.union(InputModifiers::COMMAND)),
            meta::CONTROL | meta::META,
        );
    }

    #[test]
    fn a_command_chord_is_dropped_rather_than_typed_as_a_stray_letter() {
        assert_eq!(
            resolve_android(None, Some("a"), Some("a"), InputModifiers::COMMAND),
            AndroidResolution::Nothing,
        );
        assert_eq!(
            resolve_android(None, Some("a"), Some("a"), InputModifiers::CONTROL),
            AndroidResolution::Nothing,
        );
    }

    #[test]
    fn a_control_character_carries_nothing_worth_typing() {
        assert_eq!(
            resolve_android(None, Some("\u{1}"), Some("a"), InputModifiers::default()),
            AndroidResolution::Nothing,
        );
    }

    #[test]
    fn the_layouts_own_answer_wins_over_the_stripped_one() {
        assert_eq!(
            resolve_android(None, Some("é"), Some("e"), InputModifiers::OPTION),
            AndroidResolution::Text("é".to_owned()),
        );
    }

    #[test]
    fn an_absent_character_falls_back_where_an_empty_one_does_not() {
        // The one place `None` and `Some("")` part company, which is why the flag crosses the
        // boundary rather than an empty buffer standing in for both.
        assert_eq!(
            resolve_android(None, None, Some("e"), InputModifiers::default()),
            AndroidResolution::Text("e".to_owned()),
        );
        assert_eq!(
            resolve_android(None, Some(""), Some("e"), InputModifiers::default()),
            AndroidResolution::Nothing,
        );
    }

    #[test]
    fn a_functional_key_beats_every_modifier_rule_above_it() {
        assert_eq!(
            resolve_android(
                functional_key(36),
                Some("\r"),
                Some("\r"),
                InputModifiers::COMMAND
            ),
            AndroidResolution::Keycode {
                keycode: 66,
                meta_state: meta::META
            },
            "⌘↩ is a chord the panel CAN name, so it is not dropped",
        );
    }
}
