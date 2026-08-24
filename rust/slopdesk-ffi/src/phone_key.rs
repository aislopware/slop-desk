//! The phone's key path, in C.
//!
//! The rules are `slopdesk_workspace::phone_key`; what is here is the marshalling. A press crosses
//! as its HID usage, its base string and one flag word, because that is exactly what a `UIKey`
//! carries and rebuilding it on this side would mean the responder deciding, per field, what
//! `UIKit` meant.
//!
//! ## The flag word IS the binding table's
//!
//! Bits 0–3 are `MOD_SHIFT`/`CONTROL`/`OPTION`/`COMMAND`, the same values `KeyChord.Modifiers`
//! carries, so a chord's modifiers cross back out UNTRANSLATED. Nothing above them is a modifier:
//! which keys are special is a rule, not a fact the responder is allowed to assert, and it is
//! answered on the far side from `hid_usage`.
//!
//! Bits 4–5 are the one thing that IS the responder's to assert, and they are not a modifier at all
//! — they are `controls.optionAsAlt`, a property of the keyboard rather than of the press, and the
//! only setting either door reads. See [`PHONE_KEY_OPTION_AS_ALT_MASK`] for why `BOTH` is the zero.
//!
//! ## Two answers that are legitimately empty, and how each says so
//!
//! [`slopdesk_phone_key_encode`] answers with a length, and a press that sends nothing — a bare ⌘
//! combination — is `0`. That is unambiguous here because no key this encoder resolves sends zero
//! bytes. [`slopdesk_phone_key_chord`] cannot do the same: every field of a chord is a legitimate
//! zero, so it answers with a `bool` and writes through only when that is `true`.
//!
//! ## The floating cursor carries its own accumulator
//!
//! One `f64` in and out rather than a handle. The remainder IS the whole state, the caller already
//! owns a view to hang it on, and a handle would be an allocation freed on a gesture end that a
//! dropped view can skip.

use core::ffi::c_uchar;

use slopdesk_video::key_naming::NamedKey;
use slopdesk_workspace::phone_key::{
    self, ChordKey, FloatingCursor, KeyPress, NamedChordKey, OptionAsAlt, Route,
};

use crate::{borrow, deliver};

/// ⇧ — `KeyChord.Modifiers.shift`.
pub const PHONE_KEY_SHIFT: u32 = 1 << 0;
/// ⌃.
pub const PHONE_KEY_CONTROL: u32 = 1 << 1;
/// ⌥.
pub const PHONE_KEY_OPTION: u32 = 1 << 2;
/// ⌘.
pub const PHONE_KEY_COMMAND: u32 = 1 << 3;

/// Bits 4–5, where `controls.optionAsAlt` crosses.
///
/// A bit-pair on the word that already crossed, rather than a fifth parameter on two doors: the
/// mode is a property of the KEYBOARD the press came from, the way `base` is a property of its
/// layout, and widening the word costs the boundary nothing while a new parameter changes every
/// caller of `slopdesk_phone_key_encode`.
///
/// [`PHONE_KEY_OPTION_AS_ALT_BOTH`] is ZERO on purpose, and it is the one value in this header that
/// is not free to be reordered: these bits are an EXTENSION of a word that already had four, so an
/// absent pair has to read as what the door did before the pair existed — which was to treat ⌥ as
/// Alt unconditionally. Making `OFF` the zero would silently withdraw meta from every caller that
/// had not yet learnt to set the bits.
pub const PHONE_KEY_OPTION_AS_ALT_MASK: u32 = 0b11 << 4;
/// Both Option keys are Alt/Meta — and the value an unset bit-pair reads as.
pub const PHONE_KEY_OPTION_AS_ALT_BOTH: u32 = 0 << 4;
/// Neither is; ⌥ is left to compose accented characters.
pub const PHONE_KEY_OPTION_AS_ALT_OFF: u32 = 1 << 4;
/// The left Option key alone.
pub const PHONE_KEY_OPTION_AS_ALT_LEFT: u32 = 2 << 4;
/// The right Option key alone.
pub const PHONE_KEY_OPTION_AS_ALT_RIGHT: u32 = 3 << 4;

/// The `named` value for a chord whose key is a printable character rather than a named one.
pub const PHONE_KEY_NAMED_NONE: u8 = 0xFF;

/// One `UIKey`, flattened.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskPhoneKeyPress {
    /// `UIKey.charactersIgnoringModifiers` as UTF-8.
    pub base: *const c_uchar,
    /// Its length in bytes.
    pub base_len: usize,
    /// `UIKey.keyCode` — a USB HID keyboard usage, or `0` for a press that has none.
    pub hid_usage: u16,
    /// `PHONE_KEY_*` bits.
    pub flags: u32,
}

/// Rebuilds the borrowed press.
///
/// # Safety
/// `(base, base_len)` must be null or describe that many live bytes for the call.
#[expect(
    unsafe_code,
    reason = "rebuilding the borrowed press from its `(ptr, len)` pair is the marshalling itself"
)]
unsafe fn press_of(raw: &SlopDeskPhoneKeyPress) -> KeyPress<'_> {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own. Text that is not
    // UTF-8 cannot have come from a `UIKey`, and reads as no characters rather than as a refusal —
    // the press then falls through to the proxy, which is the harmless half of the split.
    let base = core::str::from_utf8(unsafe { borrow(raw.base, raw.base_len) }).unwrap_or("");
    KeyPress {
        base,
        hid_usage: raw.hid_usage,
        control: raw.flags & PHONE_KEY_CONTROL != 0,
        option: raw.flags & PHONE_KEY_OPTION != 0,
        command: raw.flags & PHONE_KEY_COMMAND != 0,
        shift: raw.flags & PHONE_KEY_SHIFT != 0,
        option_as_alt: option_as_alt_of(raw.flags),
    }
}

/// The `controls.optionAsAlt` mode bits 4–5 carry.
///
/// Total rather than fallible: the pair has four values and the enum has four cases, so there is no
/// unrecognised bit pattern for a door to have to refuse — which is why the mode is a pair and not
/// a token.
const fn option_as_alt_of(flags: u32) -> OptionAsAlt {
    match flags & PHONE_KEY_OPTION_AS_ALT_MASK {
        PHONE_KEY_OPTION_AS_ALT_OFF => OptionAsAlt::Off,
        PHONE_KEY_OPTION_AS_ALT_LEFT => OptionAsAlt::Left,
        PHONE_KEY_OPTION_AS_ALT_RIGHT => OptionAsAlt::Right,
        _ => OptionAsAlt::Both,
    }
}

/// Whether this press is ENCODED rather than passed on to `UIKit`'s text input.
///
/// # Safety
/// `press` must point to a live record whose `(ptr, len)` pair is live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_phone_key_routes_to_encoding(press: *const SlopDeskPhoneKeyPress) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { press.as_ref() }) else {
        return false;
    };
    // SAFETY: as above.
    matches!(phone_key::route(&unsafe { press_of(raw) }), Route::KeyEncoding)
}

/// The bytes this press sends, written through `(out, cap)`, with the length returned.
///
/// `0` means the press sends nothing — a bare modifier, or a ⌘ combination, which is an app
/// shortcut. A `needed` above `cap` writes nothing and is the caller's cue to retry bigger.
///
/// # Safety
/// `press` must point to a live record whose `(ptr, len)` pair is live for the call, and
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_phone_key_encode(
    press: *const SlopDeskPhoneKeyPress,
    application_cursor_keys: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { press.as_ref() }) else {
        return 0;
    };
    // SAFETY: as above.
    let Some(bytes) = phone_key::encode(&unsafe { press_of(raw) }, application_cursor_keys) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&bytes, out, cap) }
}

/// The chord this press makes, if the binding table could be keyed by it.
///
/// Writes `named` — a `KeyChord.Key` case index, or [`PHONE_KEY_NAMED_NONE`] when the key is the
/// printable scalar in `character` — and `modifiers` as `PHONE_KEY_*` bits 0–3. `false` means the
/// press is not a chord and the three out-parameters are untouched.
///
/// # Safety
/// `press` must point to a live record whose `(ptr, len)` pair is live for the call, and each
/// non-null out-parameter must be writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_phone_key_chord(
    press: *const SlopDeskPhoneKeyPress,
    named: *mut u8,
    character: *mut u32,
    modifiers: *mut u8,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { press.as_ref() }) else {
        return false;
    };
    // SAFETY: as above.
    let Some(chord) = phone_key::key_chord(&unsafe { press_of(raw) }) else {
        return false;
    };
    let (index, scalar) = match chord.key {
        ChordKey::Named(key) => (named_index(key), 0),
        ChordKey::Character(scalar) => (PHONE_KEY_NAMED_NONE, u32::from(scalar)),
    };
    // SAFETY: the caller's obligation; each write is guarded by its own null check.
    unsafe {
        if let Some(slot) = named.as_mut() {
            *slot = index;
        }
        if let Some(slot) = character.as_mut() {
            *slot = scalar;
        }
        if let Some(slot) = modifiers.as_mut() {
            *slot = chord.modifiers;
        }
    }
    true
}

/// The `KeyChord.Key` case index a named key crosses as.
///
/// Read off `slopdesk_video::key_naming`, which is where the app's ONE numbering of named keys
/// lives — the dispatcher and the config grammar both resolve against it, and a second numbering
/// here would let a phone chord miss a binding a `keybind` line makes.
const fn named_index(key: NamedChordKey) -> u8 {
    match key {
        NamedChordKey::Return => NamedKey::Return.index(),
        NamedChordKey::Tab => NamedKey::Tab.index(),
        NamedChordKey::Space => NamedKey::Space.index(),
        NamedChordKey::Left => NamedKey::Left.index(),
        NamedChordKey::Right => NamedKey::Right.index(),
        NamedChordKey::Up => NamedKey::Up.index(),
        NamedChordKey::Down => NamedKey::Down.index(),
        NamedChordKey::PageUp => NamedKey::PageUp.index(),
        NamedChordKey::PageDown => NamedKey::PageDown.index(),
        NamedChordKey::Home => NamedKey::Home.index(),
        NamedChordKey::End => NamedKey::End.index(),
    }
}

/// The modal key one HID usage is — a `PHONE_MODAL_*` index, or [`PHONE_MODAL_NONE`].
///
/// A usage rather than a whole press, because nothing about this answer reads the layout: a mode
/// asks "is this key a command", and every press it says no to reaches the mode as its character,
/// which the caller already holds. Passing the record would have made the door look like it read
/// the modifiers, which it must not — `⌃v` in copy mode is the visual-block key, not an Escape.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_phone_modal_key(hid_usage: u16) -> u8 {
    match phone_key::modal_key(hid_usage) {
        Some(key) => key.index(),
        None => PHONE_MODAL_NONE,
    }
}

/// The answer for a press no mode reads as a command — it reaches the mode as its character.
pub const PHONE_MODAL_NONE: u8 = 0xFF;

/// The accessory bar's ⌃ fold: the first scalar's control byte through `code`, and the byte offset
/// its remainder starts at through `rest`. `false` for empty text — send it as it came.
///
/// # Safety
/// `(text, len)` must be null or describe `len` live bytes, and each non-null out-parameter must be
/// writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_phone_key_fold_control(
    text: *const c_uchar,
    len: usize,
    code: *mut u8,
    rest: *mut usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let Ok(text) = core::str::from_utf8(unsafe { borrow(text, len) }) else {
        return false;
    };
    let Some((byte, offset)) = phone_key::fold_armed_control(text) else {
        return false;
    };
    // SAFETY: the caller's obligation; each write is guarded by its own null check.
    unsafe {
        if let Some(slot) = code.as_mut() {
            *slot = byte;
        }
        if let Some(slot) = rest.as_mut() {
            *slot = offset;
        }
    }
    true
}

/// The keyboard height at which the on-screen keyboard is the software one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_phone_accessory_threshold() -> f64 {
    phone_key::SOFTWARE_KEYBOARD_THRESHOLD
}

/// Whether the accessory row is worth its space for a keyboard of this height.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_phone_shows_accessory_bar(keyboard_height: f64, threshold: f64) -> bool {
    phone_key::shows_accessory_bar(keyboard_height, threshold)
}

/// The travel one floating-cursor arrow is worth.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_phone_floating_cursor_threshold() -> f64 {
    phone_key::FLOATING_CURSOR_THRESHOLD
}

/// The most bytes one [`slopdesk_phone_floating_cursor_feed`] can answer with.
///
/// A caller sizes its buffer at this and never travels the retry. It is a door rather than a number
/// the near side multiplies out because the product is the arrow cap times the escape width, and
/// both are the far side's to tune.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_phone_floating_cursor_run_capacity() -> usize {
    phone_key::MAX_FLOATING_CURSOR_RUN_BYTES
}

/// Feeds one floating-cursor delta and writes the arrow bytes it earned through `(out, cap)`.
///
/// `accumulated` is read AND written: it carries the sub-threshold remainder from one call to the
/// next, which is what makes a slow drag of many small deltas total correctly. Returns the byte
/// length, `0` when the delta bought no whole threshold.
///
/// # Safety
/// `accumulated` must be null or writable, and `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_phone_floating_cursor_feed(
    accumulated: *mut f64,
    threshold: f64,
    delta_x: f64,
    application_cursor_keys: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let carried = unsafe { accumulated.as_ref() }.copied().unwrap_or(0.0);
    let mut cursor = FloatingCursor::resumed(threshold, carried);
    let arrows = cursor.feed(delta_x);
    // SAFETY: as above.
    if let Some(slot) = unsafe { accumulated.as_mut() } {
        *slot = cursor.accumulated();
    }
    let bytes = phone_key::floating_cursor_run(&arrows, application_cursor_keys);
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&bytes, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::*;

    fn raw(base: &str, hid_usage: u16, flags: u32) -> SlopDeskPhoneKeyPress {
        SlopDeskPhoneKeyPress {
            base: base.as_ptr(),
            base_len: base.len(),
            hid_usage,
            flags,
        }
    }

    #[test]
    fn the_flag_word_is_the_binding_table_s_own() {
        assert_eq!(u32::from(phone_key::MOD_SHIFT), PHONE_KEY_SHIFT);
        assert_eq!(u32::from(phone_key::MOD_CONTROL), PHONE_KEY_CONTROL);
        assert_eq!(u32::from(phone_key::MOD_OPTION), PHONE_KEY_OPTION);
        assert_eq!(u32::from(phone_key::MOD_COMMAND), PHONE_KEY_COMMAND);
    }

    /// The four modes cross intact, and the ABSENT pair reads as the behaviour the door had before
    /// the pair existed — which is what makes bits 4–5 an extension rather than a break.
    #[test]
    fn the_option_as_alt_pair_crosses_and_its_zero_is_the_old_behaviour() {
        let bytes = |flags: u32| {
            let mut out = [0_u8; 8];
            let press = raw("e", 0, PHONE_KEY_OPTION | flags);
            // SAFETY: `press` borrows a live `&str` and `out` is writable for its whole length.
            let written =
                unsafe { slopdesk_phone_key_encode(&raw const press, false, out.as_mut_ptr(), out.len()) };
            out.get(..written).map(<[u8]>::to_vec)
        };
        assert_eq!(bytes(PHONE_KEY_OPTION_AS_ALT_BOTH), Some(vec![0x1B, b'e']));
        assert_eq!(
            bytes(0),
            Some(vec![0x1B, b'e']),
            "an absent pair is BOTH, not OFF"
        );
        assert_eq!(bytes(PHONE_KEY_OPTION_AS_ALT_LEFT), Some(vec![0x1B, b'e']));
        assert_eq!(bytes(PHONE_KEY_OPTION_AS_ALT_RIGHT), Some(vec![0x1B, b'e']));
        assert_eq!(
            bytes(PHONE_KEY_OPTION_AS_ALT_OFF),
            Some(Vec::new()),
            "OFF leaves ⌥e to the text path, so the door writes nothing",
        );
        // The pair sits ABOVE the four modifier bits and never collides with them.
        assert_eq!(
            PHONE_KEY_OPTION_AS_ALT_MASK
                & (PHONE_KEY_SHIFT | PHONE_KEY_CONTROL | PHONE_KEY_OPTION | PHONE_KEY_COMMAND),
            0,
        );
    }

    #[test]
    fn every_named_key_the_phone_reports_has_a_table_index() {
        for (key, expected) in [
            (NamedChordKey::Return, NamedKey::Return),
            (NamedChordKey::Tab, NamedKey::Tab),
            (NamedChordKey::Space, NamedKey::Space),
            (NamedChordKey::Left, NamedKey::Left),
            (NamedChordKey::Right, NamedKey::Right),
            (NamedChordKey::Up, NamedKey::Up),
            (NamedChordKey::Down, NamedKey::Down),
            (NamedChordKey::PageUp, NamedKey::PageUp),
            (NamedChordKey::PageDown, NamedKey::PageDown),
            (NamedChordKey::Home, NamedKey::Home),
            (NamedChordKey::End, NamedKey::End),
        ] {
            assert_eq!(named_index(key), expected.index());
            assert_eq!(NamedKey::from_index(named_index(key)), Some(expected));
        }
        // The sentinel is outside the table, so no named key can ever be mistaken for it.
        assert_eq!(NamedKey::from_index(PHONE_KEY_NAMED_NONE), None);
    }

    /// Every key BOTH dispatchers can be asked about resolves to the same NAME, keyed by its own
    /// vocabulary on each side — a HID usage here, a macOS virtual key code there. This is the
    /// pairing that would drift silently: the two tables are written in different crates, neither
    /// of which can see the other, and a chord that resolved to `pageup` on one and nothing on the
    /// other would make one `keybind` line fire on only half the clients.
    #[test]
    fn the_two_dispatchers_agree_on_every_key_both_can_name() {
        use slopdesk_video::key_naming;
        // (HID usage, macOS key code, the base the key reports).
        for (usage, key_code, base) in [
            (phone_key::HID_ESCAPE, 53_u16, "\u{1b}"),
            (phone_key::HID_BACKSPACE, 51, "\u{7f}"),
            (phone_key::HID_FORWARD_DELETE, 117, "\u{7f}"),
            (phone_key::HID_RETURN, 36, ""),
            (phone_key::HID_KEYPAD_ENTER, 76, ""),
            (phone_key::HID_TAB, 48, "\t"),
            (phone_key::HID_LEFT, 123, ""),
            (phone_key::HID_RIGHT, 124, ""),
            (phone_key::HID_UP, 126, ""),
            (phone_key::HID_DOWN, 125, ""),
            (phone_key::HID_PAGE_UP, 116, ""),
            (phone_key::HID_PAGE_DOWN, 121, ""),
            (phone_key::HID_HOME, 115, ""),
            (phone_key::HID_END, 119, ""),
            // The space bar: named by both, and only because a modifier is held.
            (phone_key::HID_SPACE, 49, " "),
            // And an ordinary letter, which neither table names and both resolve as a character.
            (phone_key::HID_NONE, 35, "p"),
        ] {
            let press = raw(base, usage, PHONE_KEY_CHORD_MODIFIER);
            let mut named = PHONE_KEY_NAMED_NONE;
            let mut character = 0_u32;
            let mut modifiers = 0_u8;
            // SAFETY: the record and each out-parameter are live locals.
            let mine = unsafe {
                slopdesk_phone_key_chord(
                    &raw const press,
                    &raw mut named,
                    &raw mut character,
                    &raw mut modifiers,
                )
            };
            let theirs = key_naming::dispatch_named_key(key_code, true).map_or_else(
                || {
                    key_naming::dispatch_base_character(base)
                        .map(|scalar| scalar.to_string())
                        .unwrap_or_default()
                },
                |key| key.canonical().to_owned(),
            );
            assert_eq!(
                mine,
                !theirs.is_empty(),
                "usage {usage} / key code {key_code}: one half calls it a chord and the other does not"
            );
            if !mine {
                continue;
            }
            // A chord must also land on the same NAME, or a `keybind` line binds it on one client
            // and not the other.
            let spelling = NamedKey::from_index(named).map_or_else(
                || {
                    char::from_u32(character)
                        .map(|scalar| scalar.to_lowercase().to_string())
                        .unwrap_or_default()
                },
                |key| key.canonical().to_owned(),
            );
            assert_eq!(spelling, theirs, "usage {usage} / key code {key_code}");
        }
    }

    /// ⌘, held for every row of the agreement table — the space bar needs a non-⇧ modifier to be
    /// named at all, and a chord is what a held modifier makes.
    const PHONE_KEY_CHORD_MODIFIER: u32 = PHONE_KEY_COMMAND;

    #[test]
    fn a_control_letter_encodes_and_a_command_one_does_not() {
        let mut out = [0_u8; 8];
        let press = raw("c", phone_key::HID_NONE, PHONE_KEY_CONTROL);
        // SAFETY: the string and the buffer are live locals.
        let written =
            unsafe { slopdesk_phone_key_encode(&raw const press, false, out.as_mut_ptr(), out.len()) };
        assert_eq!(written, 1);
        assert_eq!(out.first(), Some(&0x03));

        let press = raw("k", phone_key::HID_NONE, PHONE_KEY_COMMAND);
        // SAFETY: as above.
        let written =
            unsafe { slopdesk_phone_key_encode(&raw const press, false, out.as_mut_ptr(), out.len()) };
        assert_eq!(written, 0);
    }

    #[test]
    fn the_usage_and_the_cursor_mode_reach_the_door() {
        let mut out = [0_u8; 8];
        // No characters at all — the key is named by its usage, which is the whole point.
        let press = raw("", phone_key::HID_UP, 0);
        // SAFETY: the string and the buffer are live locals.
        let written =
            unsafe { slopdesk_phone_key_encode(&raw const press, true, out.as_mut_ptr(), out.len()) };
        assert_eq!(out.get(..written), Some([0x1B, 0x4F, b'A'].as_slice()));

        // And the nav block a characters-keyed record could not carry (`docs/29` #7).
        let press = raw("", phone_key::HID_PAGE_UP, 0);
        // SAFETY: as above.
        let written =
            unsafe { slopdesk_phone_key_encode(&raw const press, false, out.as_mut_ptr(), out.len()) };
        assert_eq!(out.get(..written), Some([0x1B, 0x5B, b'5', b'~'].as_slice()));
    }

    #[test]
    fn a_chord_crosses_as_an_index_or_a_scalar() {
        let (mut named, mut character, mut modifiers) = (0_u8, 0_u32, 0_u8);
        let press = raw("", phone_key::HID_RETURN, PHONE_KEY_COMMAND);
        // SAFETY: the record and all three out-parameters are live locals.
        let found = unsafe {
            slopdesk_phone_key_chord(
                &raw const press,
                &raw mut named,
                &raw mut character,
                &raw mut modifiers,
            )
        };
        assert!(found);
        assert_eq!(named, NamedKey::Return.index());
        assert_eq!(modifiers, phone_key::MOD_COMMAND);

        let press = raw("P", phone_key::HID_NONE, PHONE_KEY_COMMAND | PHONE_KEY_SHIFT);
        // SAFETY: as above.
        let found = unsafe {
            slopdesk_phone_key_chord(
                &raw const press,
                &raw mut named,
                &raw mut character,
                &raw mut modifiers,
            )
        };
        assert!(found);
        assert_eq!(named, PHONE_KEY_NAMED_NONE);
        assert_eq!(character, u32::from('P'));
        assert_eq!(modifiers, phone_key::MOD_COMMAND | phone_key::MOD_SHIFT);
    }

    #[test]
    fn a_null_record_is_an_answer_rather_than_a_crash() {
        // SAFETY: a null record is exactly what the door's own guard is for.
        assert!(!unsafe { slopdesk_phone_key_routes_to_encoding(core::ptr::null()) });
        // SAFETY: as above.
        assert_eq!(
            unsafe { slopdesk_phone_key_encode(core::ptr::null(), false, core::ptr::null_mut(), 0) },
            0
        );
    }

    #[test]
    fn the_accumulator_survives_the_round_trip() {
        let mut carried = 0.0_f64;
        let mut out = [0_u8; 16];
        // SAFETY: both the accumulator and the buffer are live locals.
        let written = unsafe {
            slopdesk_phone_floating_cursor_feed(
                &raw mut carried,
                phone_key::FLOATING_CURSOR_THRESHOLD,
                4.0,
                false,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, 0);
        assert!((carried - 4.0).abs() < 1e-9);
        // SAFETY: as above.
        let written = unsafe {
            slopdesk_phone_floating_cursor_feed(
                &raw mut carried,
                phone_key::FLOATING_CURSOR_THRESHOLD,
                2.0,
                false,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(out.get(..written), Some([0x1B, 0x5B, b'C'].as_slice()));
        assert!((carried - 1.0).abs() < 1e-9);
    }

    #[test]
    fn the_bar_and_its_threshold_agree() {
        let threshold = slopdesk_phone_accessory_threshold();
        assert!(!slopdesk_phone_shows_accessory_bar(threshold - 1.0, threshold));
        assert!(slopdesk_phone_shows_accessory_bar(threshold, threshold));
    }

    #[test]
    fn the_fold_reports_where_the_rest_begins() {
        let (mut code, mut rest) = (0_u8, 0_usize);
        let text = "cd ..";
        // SAFETY: the text and both out-parameters are live locals.
        let folded = unsafe {
            slopdesk_phone_key_fold_control(text.as_ptr(), text.len(), &raw mut code, &raw mut rest)
        };
        assert!(folded);
        assert_eq!(code, 0x03);
        assert_eq!(text.get(rest..), Some("d .."));
        // SAFETY: an empty span is the door's own guard.
        assert!(!unsafe {
            slopdesk_phone_key_fold_control(core::ptr::null(), 0, &raw mut code, &raw mut rest)
        });
    }
}
