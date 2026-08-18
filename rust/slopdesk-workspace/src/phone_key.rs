//! What the phone's keyboard SENDS, and which of the two paths a press takes to send it.
//!
//! A Mac terminal has one input path: the view is the first responder, `keyDown` arrives, and the
//! surface encodes it. A phone cannot have that. `UIKit` will deliver a hardware key press through
//! `pressesBegan` and a composed text commit through a `UITextInput` proxy, and putting both on the
//! same view breaks multi-stage CJK — the responder order between them is undefined. So the phone
//! splits: control-ish presses are ENCODED here and written to the pane, everything else is left to
//! the proxy so a composition can run to its commit. [`route`] is that split, and it is the first
//! question the responder asks about every press.
//!
//! ## Why this is not [`crate::send_keys`]
//!
//! Both turn a key into PTY bytes and they must never disagree about what a key MEANS, but they are
//! asked by different things. `send_keys` reads a NAME a human wrote — `<C-c>`, `Enter` — out of a
//! preset, a template or a CLI flag, where the vocabulary is the config file's. This reads a live
//! `UIKit` press, whose vocabulary is the four private-use arrow scalars and a modifier flag word,
//! and whose answer has to account for the mode the far-side program put the terminal in. A press
//! has no spelling and a token has no `DECCKM` state; folding them into one table would mean
//! inventing both.
//!
//! ## The mode is threaded, never remembered
//!
//! Cursor-key mode (`DECCKM`, `ESC [ ? 1 h`) changes the introducer of every arrow from CSI to SS3,
//! and the program that set it is on the far side of the PTY. Nothing here holds that bit: the
//! caller reads it off the live terminal model and passes it in. A remembered copy would be one
//! parse behind the screen the user is looking at, which is exactly how arrows go dead in vim.
//!
//! ## What crosses out
//!
//! Bytes and a chord. The chord is the same [`crate`]-neutral shape the binding table is keyed by,
//! so the phone's ⌘⇧P resolves against the SAME user-overridable table the Mac's dispatcher reads
//! rather than against a second list that would drift the first time someone rebinds anything.

/// `UIKeyCommand.inputUpArrow` — the private-use scalar `UIKit` reports for ↑.
pub const ARROW_UP: char = '\u{F700}';
/// `UIKeyCommand.inputDownArrow` — ↓.
pub const ARROW_DOWN: char = '\u{F701}';
/// `UIKeyCommand.inputLeftArrow` — ←.
pub const ARROW_LEFT: char = '\u{F702}';
/// `UIKeyCommand.inputRightArrow` — →.
pub const ARROW_RIGHT: char = '\u{F703}';

/// The escape byte every control sequence here opens with.
const ESC: u8 = 0x1B;
/// The CSI introducer — `ESC [`, cursor-key mode RESET.
const CSI: u8 = 0x5B;
/// The SS3 introducer — `ESC O`, cursor-key mode SET (`DECCKM`).
const SS3: u8 = 0x4F;

/// ⇧, as the binding table's modifier bit.
pub const MOD_SHIFT: u8 = 1 << 0;
/// ⌃.
pub const MOD_CONTROL: u8 = 1 << 1;
/// ⌥.
pub const MOD_OPTION: u8 = 1 << 2;
/// ⌘.
pub const MOD_COMMAND: u8 = 1 << 3;

/// One physical key press, as the responder reads it off a `UIKey`.
///
/// Two strings rather than one because the two questions want different ones. What the key SENDS is
/// `characters` — the layout's committed output, which is where the arrows' private-use scalars and
/// the `\r` / `\t` / `\u{7F}` of the named keys show up. What the key IS, for a binding lookup or a
/// control fold, is `base` (`charactersIgnoringModifiers`) — the same physical key with ⌘⌥⌃ folded
/// out, so `⌃C` still reads as `c`.
#[expect(
    clippy::struct_excessive_bools,
    reason = "four of them are the platform's four modifiers, which combine rather than exclude"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyPress<'a> {
    /// `UIKey.characters` — what the layout committed for this press.
    pub characters: &'a str,
    /// `UIKey.charactersIgnoringModifiers` — the same key with ⌘⌥⌃ folded out.
    pub base: &'a str,
    /// Whether ⌃ is held.
    pub control: bool,
    /// Whether ⌥ (Alt) is held.
    pub option: bool,
    /// Whether ⌘ is held.
    pub command: bool,
    /// Whether ⇧ is held. Deliberately NOT read by [`route`] — a shifted letter is still typing —
    /// only by the encoder, because `UIKit` reports the same `characters` for Tab with and without
    /// it, so this flag is the only thing that tells a back-tab from a forward one.
    pub shift: bool,
    /// Whether this is a non-printable key: an arrow, Esc, Tab, Return, Delete, a function key.
    pub is_special: bool,
}

/// Which of the phone's two input paths a press takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// Encode it here and write the bytes to the pane, bypassing the text proxy.
    KeyEncoding,
    /// Leave it to the hidden `UITextInput` proxy, so a marked-text composition can run to commit.
    ImeProxy,
}

/// Which path this press takes.
///
/// A special key, or any of ⌃⌥⌘, goes to the encoder — the proxy would swallow or mis-compose all
/// of them. Everything else is typing, and typing is the proxy's, ⇧ included.
#[must_use]
pub const fn route(press: &KeyPress<'_>) -> Route {
    if press.is_special || press.control || press.option || press.command {
        Route::KeyEncoding
    } else {
        Route::ImeProxy
    }
}

/// The C0 control byte a scalar folds to under ⌃.
///
/// The whole C0 range, not just the letters: `⌃[` is the ESC that vim and readline users press
/// constantly, `⌃\` `⌃]` `⌃^` `⌃_` are the rest of the range, `⌃@` and `⌃Space` are both NUL, and
/// `⌃?` is DEL. Folding only the letters and passing everything else through would send `⌃[` as a
/// literal `[`, which is Escape not working at all.
#[must_use]
pub fn control_code(scalar: char) -> u8 {
    let value = u32::from(scalar);
    // The mask leaves seven bits, so the narrowing is exact for every scalar.
    let low = (value & 0x7F) as u8;
    match value {
        0x61..=0x7A => low - 0x60, // a–z → 1…26
        0x41..=0x5A => low - 0x40, // A–Z → 1…26
        0x40..=0x5F => low & 0x1F, // @ [ \ ] ^ _ → NUL, 0x1B…0x1F
        0x20 => 0x00,              // ⌃Space → NUL
        0x3F => 0x7F,              // ⌃? → DEL
        _ => low,
    }
}

/// The split of a soft-keyboard text commit when the accessory bar's ⌃ is ARMED: the first scalar
/// folds to its control byte, and the rest stays text. `None` when the text is empty — send it as
/// it came.
///
/// The byte-offset second half rather than a copied string: the caller already holds the text, and
/// the remainder is a suffix of it.
#[must_use]
pub fn fold_armed_control(text: &str) -> Option<(u8, usize)> {
    let first = text.chars().next()?;
    Some((control_code(first), first.len_utf8()))
}

/// The three bytes an arrow sends, or `None` for a press that is not one.
///
/// `application_cursor_keys` is the live `DECCKM` bit: reset gives the CSI form every line editor
/// reads as a cursor move, set gives the SS3 form vim, less and htop ask for. The final letter is
/// the same either way.
#[must_use]
pub fn arrow_bytes(press: &KeyPress<'_>, application_cursor_keys: bool) -> Option<[u8; 3]> {
    let final_byte = match single_char(press.characters)? {
        ARROW_UP => b'A',
        ARROW_DOWN => b'B',
        ARROW_RIGHT => b'C',
        ARROW_LEFT => b'D',
        _ => return None,
    };
    Some([ESC, introducer(application_cursor_keys), final_byte])
}

/// The one character a string holds, or `None` when it holds none or more than one.
fn single_char(text: &str) -> Option<char> {
    let mut scalars = text.chars();
    let first = scalars.next()?;
    scalars.next().is_none().then_some(first)
}

/// CSI or SS3, by the live cursor-key mode.
const fn introducer(application_cursor_keys: bool) -> u8 {
    if application_cursor_keys { SS3 } else { CSI }
}

/// The bytes for a special key that needs no mode to resolve — Esc, Tab, back-tab, Return, Delete.
/// Arrows are mode-dependent and answered by [`arrow_bytes`].
#[must_use]
pub fn character_special_bytes(press: &KeyPress<'_>) -> Option<&'static [u8]> {
    match press.characters {
        "\u{1B}" => Some(&[ESC]),
        // `UIKit` reports the same "\t" with and without ⇧, so the flag is the only discriminator:
        // ⇧Tab is back-tab (CBT, `ESC [ Z`), plain Tab stays forward TAB.
        "\t" => Some(if press.shift { &[ESC, CSI, b'Z'] } else { &[0x09] }),
        "\r" | "\n" => Some(&[0x0D]),
        "\u{7F}" | "\u{08}" => Some(&[0x7F]),
        _ => None,
    }
}

/// The raw bytes a press sends, or `None` for a press that sends nothing — a bare modifier, or a ⌘
/// combination, which is an app shortcut rather than terminal input.
///
/// ⌥ on ANY of these takes the xterm meta prefix: `ESC` then the bytes the key would have sent
/// alone. That is one rule covering `⌥Backspace` (delete-previous-word), `⌥Return`, `⌥←` and `⌥b`
/// alike, and it is what makes word-wise shell editing work from a phone at all. ⌃ on a special key
/// deliberately does NOT take it — that form needs a parameterised CSI (`ESC [ 1 ; 5 D`), which is
/// a different sequence, not a prefix.
#[must_use]
pub fn encode(press: &KeyPress<'_>, application_cursor_keys: bool) -> Option<Vec<u8>> {
    if press.is_special {
        let bytes = character_special_bytes(press).map_or_else(
            || arrow_bytes(press, application_cursor_keys).map(|arrow| arrow.to_vec()),
            |special| Some(special.to_vec()),
        );
        if let Some(bytes) = bytes {
            return Some(meta_prefixed(press.option, bytes));
        }
    }
    let scalar = press.base.chars().next()?;
    if press.control {
        return Some(meta_prefixed(press.option, vec![control_code(scalar)]));
    }
    if press.option {
        return Some(meta_prefixed(true, press.base.as_bytes().to_vec()));
    }
    None
}

/// `ESC` in front of `bytes` when ⌥ was held, `bytes` untouched otherwise.
fn meta_prefixed(option: bool, bytes: Vec<u8>) -> Vec<u8> {
    if !option {
        return bytes;
    }
    let mut prefixed = Vec::with_capacity(bytes.len() + 1);
    prefixed.push(ESC);
    prefixed.extend_from_slice(&bytes);
    prefixed
}

/// A non-printable key the binding table names. The six a phone's keyboard can report — the table
/// has more, but no `UIKey` this responder sees carries them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamedChordKey {
    /// Return, and the keypad's Enter with it.
    Return,
    /// Tab.
    Tab,
    /// ←.
    Left,
    /// →.
    Right,
    /// ↑.
    Up,
    /// ↓.
    Down,
}

/// The base key of a chord: one of the named keys, or a printable character.
///
/// The two arms are three bytes apart because a `char` is four and a named key is one. Spelling the
/// character out beside a flag instead would close that gap by making an invalid state
/// representable — a named key with a stray character in the next field — which is a worse trade at
/// eight bytes total.
#[expect(
    variant_size_differences,
    reason = "a char is four bytes and a named key is one; flattening them would make an invalid state \
              representable"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChordKey {
    /// A key the table names.
    Named(NamedChordKey),
    /// A printable character, as the layout produced it. The binding table lower-cases it — ⇧ is
    /// carried in the modifiers, not in the character — and that folding is the table's, not this
    /// function's, so there is one of it.
    Character(char),
}

/// A key press as the binding table sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chord {
    /// The base key.
    pub key: ChordKey,
    /// `MOD_*` bits.
    pub modifiers: u8,
}

/// The chord a press makes, or `None` for a press the table could not be keyed by — which the
/// responder then routes normally rather than swallowing.
///
/// Named keys first, by the characters `UIKit` commits for them. Otherwise a SINGLE printable base
/// character: whitespace and control scalars are refused, so ordinary typing falls through to the
/// proxy while a `⌃`-letter — which still reports its printable base — stays classifiable.
#[must_use]
pub fn key_chord(press: &KeyPress<'_>) -> Option<Chord> {
    let mut modifiers = 0_u8;
    if press.shift {
        modifiers |= MOD_SHIFT;
    }
    if press.control {
        modifiers |= MOD_CONTROL;
    }
    if press.option {
        modifiers |= MOD_OPTION;
    }
    if press.command {
        modifiers |= MOD_COMMAND;
    }

    if let Some(named) = named_chord_key(press.characters) {
        return Some(Chord {
            key: ChordKey::Named(named),
            modifiers,
        });
    }

    let first = single_char(press.base)?;
    if first.is_whitespace() || u32::from(first) < 0x20 {
        return None;
    }
    Some(Chord {
        key: ChordKey::Character(first),
        modifiers,
    })
}

/// The named key a committed string spells, if it spells one.
fn named_chord_key(characters: &str) -> Option<NamedChordKey> {
    match characters {
        "\r" | "\n" => Some(NamedChordKey::Return),
        "\t" => Some(NamedChordKey::Tab),
        "\u{F702}" => Some(NamedChordKey::Left),
        "\u{F703}" => Some(NamedChordKey::Right),
        "\u{F700}" => Some(NamedChordKey::Up),
        "\u{F701}" => Some(NamedChordKey::Down),
        _ => None,
    }
}

/// The keyboard-frame height (points) at or above which the on-screen keyboard is the SOFTWARE one.
///
/// A hardware keyboard leaves only a thin shortcut bar, a software one takes hundreds of points,
/// and the accessory row of ⌃/Esc/Tab/arrows is only worth its space in the second case — with a
/// hardware keyboard the user already has those keys.
pub const SOFTWARE_KEYBOARD_THRESHOLD: f64 = 150.0;

/// Whether to show the accessory row for a keyboard of `keyboard_height` points. A hidden keyboard
/// reports zero, which is below every positive threshold and therefore already `false`.
#[must_use]
pub fn shows_accessory_bar(keyboard_height: f64, threshold: f64) -> bool {
    keyboard_height >= threshold
}

/// Travel (points) per arrow emitted by the floating cursor. `SwiftTerm`'s verified figure.
pub const FLOATING_CURSOR_THRESHOLD: f64 = 5.0;

/// The most arrows one feed may emit.
///
/// A real drag is bounded by the screen, so this sits far above any gesture a finger can make. What
/// it bounds is a degenerate `UITextInput` point: an enormous-but-finite coordinate whose travel
/// would otherwise be worth more arrows than the process has time to send.
pub const MAX_FLOATING_CURSOR_ARROWS: usize = 256;

/// The direction one floating-cursor step moves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arrow {
    /// ←.
    Left,
    /// →.
    Right,
}

/// The floating cursor's travel accumulator.
///
/// On a phone with no hardware keyboard, long-pressing the space bar and dragging is the ONLY way
/// to move the terminal cursor. iOS reports that drag as a stream of positions; this turns it into
/// arrow keys, quantised rather than rounded: whole thresholds are consumed and the sub-threshold
/// remainder is carried, so a slow drag of many small deltas still totals correctly.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FloatingCursor {
    threshold: f64,
    accumulated: f64,
}

impl Default for FloatingCursor {
    fn default() -> Self {
        Self::new(FLOATING_CURSOR_THRESHOLD)
    }
}

impl FloatingCursor {
    /// An accumulator at rest. A non-positive `threshold` would make every delta an infinite run,
    /// so it falls back to the verified default rather than trapping.
    #[must_use]
    pub fn new(threshold: f64) -> Self {
        let threshold = if threshold > 0.0 {
            threshold
        } else {
            FLOATING_CURSOR_THRESHOLD
        };
        Self {
            threshold,
            accumulated: 0.0,
        }
    }

    /// Rebuilds an accumulator the caller has been carrying across calls itself.
    #[must_use]
    pub fn resumed(threshold: f64, accumulated: f64) -> Self {
        let mut cursor = Self::new(threshold);
        if accumulated.is_finite() {
            cursor.accumulated = accumulated;
        }
        cursor
    }

    /// The travel not yet spent on an arrow, signed.
    #[must_use]
    pub const fn accumulated(&self) -> f64 {
        self.accumulated
    }

    /// Feeds a horizontal delta (points, positive is rightward) and returns the arrows the whole
    /// thresholds it completed are worth.
    ///
    /// A non-finite delta is DROPPED rather than accumulated: `+∞` never falls back below the
    /// threshold and `NaN` compares false against everything, so either one wedges the accumulator
    /// permanently. The running total is then held inside [`MAX_FLOATING_CURSOR_ARROWS`] worth of
    /// travel, which bounds the run without losing the sign the gesture had.
    ///
    /// The whole thresholds are DIVIDED out rather than subtracted one at a time: the count is the
    /// same, the remainder is one rounding instead of a chain of them, and no loop's trip count
    /// depends on a float the caller chose.
    pub fn feed(&mut self, delta_x: f64) -> Vec<Arrow> {
        if !delta_x.is_finite() {
            return Vec::new();
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "a three-digit constant is exact in f64"
        )]
        let span = self.threshold * (MAX_FLOATING_CURSOR_ARROWS as f64);
        self.accumulated = (self.accumulated + delta_x).clamp(-span, span);
        let steps = (self.accumulated / self.threshold).trunc();
        self.accumulated -= steps * self.threshold;
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "the clamp above holds the total to MAX arrows, so the magnitude is a whole number in \
                      range"
        )]
        let count = steps.abs() as usize;
        vec![if steps < 0.0 { Arrow::Left } else { Arrow::Right }; count]
    }

    /// Clears the carried remainder — the drag ended.
    pub const fn reset(&mut self) {
        self.accumulated = 0.0;
    }
}

/// The three bytes one floating-cursor arrow sends, under the live cursor-key mode.
#[must_use]
pub const fn floating_cursor_bytes(arrow: Arrow, application_cursor_keys: bool) -> [u8; 3] {
    let final_byte = match arrow {
        Arrow::Right => b'C',
        Arrow::Left => b'D',
    };
    [ESC, introducer(application_cursor_keys), final_byte]
}

/// A run of arrows as one buffer, for one write to the pane.
#[must_use]
pub fn floating_cursor_run(arrows: &[Arrow], application_cursor_keys: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(arrows.len() * 3);
    for arrow in arrows {
        out.extend_from_slice(&floating_cursor_bytes(*arrow, application_cursor_keys));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(characters: &str) -> KeyPress<'_> {
        KeyPress {
            characters,
            base: characters,
            control: false,
            option: false,
            command: false,
            shift: false,
            is_special: false,
        }
    }

    fn special(characters: &str) -> KeyPress<'_> {
        KeyPress {
            is_special: true,
            ..press(characters)
        }
    }

    #[test]
    fn typing_goes_to_the_proxy_and_everything_else_to_the_encoder() {
        assert_eq!(route(&press("a")), Route::ImeProxy);
        assert_eq!(
            route(&KeyPress {
                shift: true,
                ..press("A")
            }),
            Route::ImeProxy
        );
        assert_eq!(
            route(&KeyPress {
                control: true,
                ..press("c")
            }),
            Route::KeyEncoding
        );
        assert_eq!(
            route(&KeyPress {
                option: true,
                ..press("b")
            }),
            Route::KeyEncoding
        );
        assert_eq!(
            route(&KeyPress {
                command: true,
                ..press("k")
            }),
            Route::KeyEncoding
        );
        assert_eq!(route(&special("\u{1B}")), Route::KeyEncoding);
    }

    #[test]
    fn the_whole_c0_range_folds() {
        assert_eq!(control_code('a'), 0x01);
        assert_eq!(control_code('z'), 0x1A);
        assert_eq!(control_code('A'), 0x01);
        assert_eq!(control_code('Z'), 0x1A);
        assert_eq!(control_code('@'), 0x00);
        assert_eq!(control_code('['), 0x1B);
        assert_eq!(control_code('\\'), 0x1C);
        assert_eq!(control_code(']'), 0x1D);
        assert_eq!(control_code('^'), 0x1E);
        assert_eq!(control_code('_'), 0x1F);
        assert_eq!(control_code(' '), 0x00);
        assert_eq!(control_code('?'), 0x7F);
        assert_eq!(control_code('1'), 0x31);
    }

    #[test]
    fn an_armed_bar_folds_only_the_first_scalar() {
        assert_eq!(fold_armed_control("cd"), Some((0x03, 1)));
        assert_eq!(fold_armed_control(""), None);
        assert_eq!(fold_armed_control("走c"), Some((control_code('走'), 3)));
    }

    #[test]
    fn the_cursor_mode_picks_the_introducer() {
        let up = special("\u{F700}");
        assert_eq!(arrow_bytes(&up, false), Some([0x1B, 0x5B, b'A']));
        assert_eq!(arrow_bytes(&up, true), Some([0x1B, 0x4F, b'A']));
        assert_eq!(arrow_bytes(&special("\u{F702}"), false), Some([0x1B, 0x5B, b'D']));
        assert_eq!(arrow_bytes(&special("q"), false), None);
    }

    #[test]
    fn shift_is_the_only_thing_that_tells_back_tab_from_tab() {
        assert_eq!(character_special_bytes(&special("\t")), Some(&[0x09][..]));
        assert_eq!(
            character_special_bytes(&KeyPress {
                shift: true,
                ..special("\t")
            }),
            Some(&[0x1B, 0x5B, b'Z'][..]),
        );
    }

    #[test]
    fn option_prefixes_every_key_it_is_held_with() {
        assert_eq!(
            encode(
                &KeyPress {
                    option: true,
                    ..special("\u{7F}")
                },
                false
            ),
            Some(vec![0x1B, 0x7F])
        );
        assert_eq!(
            encode(
                &KeyPress {
                    option: true,
                    ..special("\r")
                },
                false
            ),
            Some(vec![0x1B, 0x0D])
        );
        assert_eq!(
            encode(
                &KeyPress {
                    option: true,
                    ..special("\u{F702}")
                },
                false
            ),
            Some(vec![0x1B, 0x1B, 0x5B, b'D']),
        );
        assert_eq!(
            encode(
                &KeyPress {
                    option: true,
                    ..press("b")
                },
                false
            ),
            Some(vec![0x1B, b'b'])
        );
        assert_eq!(
            encode(
                &KeyPress {
                    control: true,
                    option: true,
                    ..press("c")
                },
                false
            ),
            Some(vec![0x1B, 0x03]),
        );
    }

    #[test]
    fn a_command_combination_sends_nothing() {
        assert_eq!(
            encode(
                &KeyPress {
                    command: true,
                    ..press("k")
                },
                false
            ),
            None
        );
        assert_eq!(encode(&press(""), false), None);
    }

    #[test]
    fn control_letters_fold_and_specials_resolve() {
        assert_eq!(
            encode(
                &KeyPress {
                    control: true,
                    ..press("c")
                },
                false
            ),
            Some(vec![0x03])
        );
        assert_eq!(encode(&special("\u{1B}"), false), Some(vec![0x1B]));
        assert_eq!(encode(&special("\r"), false), Some(vec![0x0D]));
        assert_eq!(encode(&special("\u{F701}"), true), Some(vec![0x1B, 0x4F, b'B']));
    }

    #[test]
    fn named_keys_beat_the_printable_path() {
        assert_eq!(
            key_chord(&special("\r")),
            Some(Chord {
                key: ChordKey::Named(NamedChordKey::Return),
                modifiers: 0
            }),
        );
        assert_eq!(
            key_chord(&KeyPress {
                shift: true,
                command: true,
                ..special("\u{F700}")
            }),
            Some(Chord {
                key: ChordKey::Named(NamedChordKey::Up),
                modifiers: MOD_SHIFT | MOD_COMMAND,
            }),
        );
    }

    #[test]
    fn a_printable_base_carries_its_modifiers_beside_it() {
        assert_eq!(
            key_chord(&KeyPress {
                command: true,
                shift: true,
                ..press("P")
            }),
            Some(Chord {
                key: ChordKey::Character('P'),
                modifiers: MOD_SHIFT | MOD_COMMAND
            }),
        );
        assert_eq!(key_chord(&press(" ")), None);
        assert_eq!(key_chord(&press("ab")), None);
        assert_eq!(key_chord(&press("")), None);
    }

    #[test]
    fn the_bar_shows_only_for_a_software_keyboard() {
        assert!(!shows_accessory_bar(0.0, SOFTWARE_KEYBOARD_THRESHOLD));
        assert!(!shows_accessory_bar(55.0, SOFTWARE_KEYBOARD_THRESHOLD));
        assert!(shows_accessory_bar(150.0, SOFTWARE_KEYBOARD_THRESHOLD));
        assert!(shows_accessory_bar(336.0, SOFTWARE_KEYBOARD_THRESHOLD));
    }

    #[test]
    fn the_floating_cursor_carries_its_remainder() {
        let mut cursor = FloatingCursor::default();
        assert!(cursor.feed(4.0).is_empty());
        assert_eq!(cursor.feed(2.0), vec![Arrow::Right]);
        assert!((cursor.accumulated() - 1.0).abs() < 1e-9);
        assert_eq!(cursor.feed(-12.0), vec![Arrow::Left, Arrow::Left]);
        cursor.reset();
        assert!((cursor.accumulated()).abs() < 1e-9);
    }

    #[test]
    fn a_degenerate_delta_neither_wedges_nor_spins() {
        let mut cursor = FloatingCursor::default();
        assert!(cursor.feed(f64::NAN).is_empty());
        assert!(cursor.feed(f64::INFINITY).is_empty());
        assert!((cursor.accumulated()).abs() < 1e-9);
        assert_eq!(cursor.feed(f64::MAX).len(), MAX_FLOATING_CURSOR_ARROWS);
    }

    #[test]
    fn a_run_is_one_buffer_in_the_live_mode() {
        let arrows = [Arrow::Left, Arrow::Right];
        assert_eq!(floating_cursor_run(&arrows, false), vec![
            0x1B, 0x5B, b'D', 0x1B, 0x5B, b'C'
        ]);
        assert_eq!(floating_cursor_run(&arrows, true), vec![
            0x1B, 0x4F, b'D', 0x1B, 0x4F, b'C'
        ]);
        assert!(floating_cursor_run(&[], false).is_empty());
    }
}
