//! What the phone's keyboard SENDS, and which of the two paths a press takes to send it.
//!
//! A Mac terminal has one input path: the view is the first responder, `keyDown` arrives, and the
//! surface encodes it. A phone cannot have that. Some presses a terminal needs RAW — `⌃C` is 0x03,
//! not the letter c — and some are the visible half of a composition that has not finished yet, a
//! Pinyin candidate being three keystrokes before it is one character. So the phone splits:
//! control-ish presses are ENCODED here and written to the pane, everything else is left to
//! `UIKit`'s own text input so a composition can run to its commit. [`route`] is that split, and it
//! is the first question `SlopDeskClientUI.TerminalInputHost` asks about every press — before it
//! decides whether to pass the press on down the responder chain, which is what makes the order
//! ours rather than the platform's.
//!
//! ## A key is identified by its HID usage, never by what it committed
//!
//! `UIKey.keyCode` is a USB HID keyboard usage, and it is the only signal on a press that means the
//! same thing under every layout, every input method and every modifier. Reading the key's IDENTITY
//! out of `UIKey.characters` instead — the way this module first did, and the way the deleted Swift
//! original did before it — costs the nav block outright: Home, End, Page Up/Down, Insert, forward
//! Delete and F1–F12 commit either nothing or a private-use scalar nobody can name, so a
//! characters-keyed table silently drops all nineteen of them (`docs/29` #7). Off the usage they
//! are one table row each. The only string this reads is `base`, and only for the two questions
//! that are genuinely about the layout: which C0 byte a ⌃-chord folds to, and which character a
//! binding is keyed by.
//!
//! ## Why this is not [`crate::send_keys`]
//!
//! Both turn a key into PTY bytes and they must never disagree about what a key MEANS, but they are
//! asked by different things. `send_keys` reads a NAME a human wrote — `<C-c>`, `Enter` — out of a
//! preset, a template or a CLI flag, where the vocabulary is the config file's. This reads a live
//! `UIKit` press, whose vocabulary is a HID usage and a modifier flag word, and whose answer has to
//! account for the mode the far-side program put the terminal in. A press has no spelling and a
//! token has no `DECCKM` state; folding them into one table would mean inventing both. What keeps
//! them honest is a test rather than a call: `send_keys_agrees_on_every_special` asserts every key
//! here encodes byte-for-byte what `send_keys::key_token` gives its name, in the mode-reset form.
//!
//! ## The mode is threaded, never remembered
//!
//! Cursor-key mode (`DECCKM`, `ESC [ ? 1 h`) changes the introducer of the arrows and of Home/End
//! from CSI to SS3, and the program that set it is on the far side of the PTY. Nothing here holds
//! that bit: the caller reads it off the live terminal model and passes it in. A remembered copy
//! would be one parse behind the screen the user is looking at, which is exactly how arrows go dead
//! in vim.
//!
//! ## What crosses out
//!
//! Bytes and a chord. The chord is the same [`crate`]-neutral shape the binding table is keyed by,
//! so the phone's ⌘⇧P resolves against the SAME user-overridable table the Mac's dispatcher reads
//! rather than against a second list that would drift the first time someone rebinds anything.

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

/// The HID usage of a press that has none — a synthesized commit, or a key `UIKit` did not code.
/// Usage 0 is the HID keyboard page's own "no event", so it is the sentinel the page already has.
pub const HID_NONE: u16 = 0;

/// One physical key press, as the responder reads it off a `UIKey`.
///
/// A usage and one string. The usage says WHICH key, under every layout; `base`
/// (`charactersIgnoringModifiers`) says what that key produces under this one, which is what a ⌃
/// fold and a binding lookup are about. What the key COMMITTED (`UIKey.characters`) is deliberately
/// absent: for a special key it is noise, and for a printable one the proxy — not this — is what
/// inserts it.
#[expect(
    clippy::struct_excessive_bools,
    reason = "four of them are the platform's four modifiers, which combine rather than exclude"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyPress<'a> {
    /// `UIKey.charactersIgnoringModifiers` — this key under this layout, with ⌘⌥⌃ folded out, so
    /// `⌃C` still reads as `c` and `⌥b` still reads as `b` rather than as `∫`.
    pub base: &'a str,
    /// `UIKey.keyCode` — the USB HID keyboard usage, or [`HID_NONE`].
    pub hid_usage: u16,
    /// Whether ⌃ is held.
    pub control: bool,
    /// Whether ⌥ (Alt) is held.
    pub option: bool,
    /// Whether ⌘ is held.
    pub command: bool,
    /// Whether ⇧ is held. Deliberately NOT read by [`route`] — a shifted letter is still typing —
    /// only by the encoder, where it is the one thing that tells a back-tab from a forward one.
    pub shift: bool,
}

/// A key with no printable output, named by its HID usage.
///
/// Every one of these is a key the text path cannot represent: it either commits nothing at all or
/// commits a scalar that is not what the terminal wants. That is the same set [`route`] sends to
/// the encoder, which is why one table answers both questions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpecialKey {
    /// Esc.
    Escape,
    /// Tab, and with ⇧ the back-tab.
    Tab,
    /// Return, and the keypad's Enter with it.
    Return,
    /// Backspace — the key labelled Delete on an Apple keyboard.
    Backspace,
    /// Forward Delete.
    ForwardDelete,
    /// Insert.
    Insert,
    /// ↑.
    Up,
    /// ↓.
    Down,
    /// ←.
    Left,
    /// →.
    Right,
    /// Home.
    Home,
    /// End.
    End,
    /// Page Up.
    PageUp,
    /// Page Down.
    PageDown,
    /// F1.
    F1,
    /// F2.
    F2,
    /// F3.
    F3,
    /// F4.
    F4,
    /// F5.
    F5,
    /// F6.
    F6,
    /// F7.
    F7,
    /// F8.
    F8,
    /// F9.
    F9,
    /// F10.
    F10,
    /// F11.
    F11,
    /// F12.
    F12,
}

impl SpecialKey {
    /// Every special key, for the tests that must cover all of them.
    pub const ALL: [Self; 26] = [
        Self::Escape,
        Self::Tab,
        Self::Return,
        Self::Backspace,
        Self::ForwardDelete,
        Self::Insert,
        Self::Up,
        Self::Down,
        Self::Left,
        Self::Right,
        Self::Home,
        Self::End,
        Self::PageUp,
        Self::PageDown,
        Self::F1,
        Self::F2,
        Self::F3,
        Self::F4,
        Self::F5,
        Self::F6,
        Self::F7,
        Self::F8,
        Self::F9,
        Self::F10,
        Self::F11,
        Self::F12,
    ];

    /// The [`crate::send_keys`] token name for this key — the spelling a preset or `--key` would
    /// use. Only the agreement test reads it, and that is the point: it is the join column between
    /// the two tables.
    #[must_use]
    pub const fn token_name(self) -> &'static str {
        match self {
            Self::Escape => "escape",
            Self::Tab => "tab",
            Self::Return => "enter",
            Self::Backspace => "bspace",
            Self::ForwardDelete => "delete",
            Self::Insert => "insert",
            Self::Up => "up",
            Self::Down => "down",
            Self::Left => "left",
            Self::Right => "right",
            Self::Home => "home",
            Self::End => "end",
            Self::PageUp => "pageup",
            Self::PageDown => "pagedown",
            Self::F1 => "f1",
            Self::F2 => "f2",
            Self::F3 => "f3",
            Self::F4 => "f4",
            Self::F5 => "f5",
            Self::F6 => "f6",
            Self::F7 => "f7",
            Self::F8 => "f8",
            Self::F9 => "f9",
            Self::F10 => "f10",
            Self::F11 => "f11",
            Self::F12 => "f12",
        }
    }
}

/// The special key a HID usage names, or `None` for a key that types.
///
/// Return and the keypad's Enter fold onto one case: they are the same intent, and the PTY has one
/// byte for it. The function block is contiguous in the HID page, so it is one range rather than
/// twelve rows.
#[must_use]
pub const fn special_key(hid_usage: u16) -> Option<SpecialKey> {
    let key = match hid_usage {
        HID_ESCAPE => SpecialKey::Escape,
        HID_TAB => SpecialKey::Tab,
        HID_RETURN | HID_KEYPAD_ENTER => SpecialKey::Return,
        HID_BACKSPACE => SpecialKey::Backspace,
        HID_FORWARD_DELETE => SpecialKey::ForwardDelete,
        HID_INSERT => SpecialKey::Insert,
        HID_UP => SpecialKey::Up,
        HID_DOWN => SpecialKey::Down,
        HID_LEFT => SpecialKey::Left,
        HID_RIGHT => SpecialKey::Right,
        HID_HOME => SpecialKey::Home,
        HID_END => SpecialKey::End,
        HID_PAGE_UP => SpecialKey::PageUp,
        HID_PAGE_DOWN => SpecialKey::PageDown,
        HID_F1 => SpecialKey::F1,
        HID_F2 => SpecialKey::F2,
        HID_F3 => SpecialKey::F3,
        HID_F4 => SpecialKey::F4,
        HID_F5 => SpecialKey::F5,
        HID_F6 => SpecialKey::F6,
        HID_F7 => SpecialKey::F7,
        HID_F8 => SpecialKey::F8,
        HID_F9 => SpecialKey::F9,
        HID_F10 => SpecialKey::F10,
        HID_F11 => SpecialKey::F11,
        HID_F12 => SpecialKey::F12,
        _ => return None,
    };
    Some(key)
}

/// A key a MODE reads as a command rather than as input.
///
/// Copy mode and Hint mode are the two places a press is not typing: while either is armed the pane
/// answers keys instead of forwarding them, and the six rows here are every press whose meaning is
/// its KEY rather than its character — leave, confirm, undo a letter, and the four motions. A key
/// that types is deliberately absent: its meaning IS its character, and the mode's own vocabulary
/// (`TerminalViewModel.handleCopyModeKey` / `handleHintKey`) is what reads it.
///
/// A projection of [`special_key`], never a second HID table. The modes want six of the twenty-six
/// special keys, and a table that listed the usages again would be the row that drifts the first
/// time the HID page grows one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModalKey {
    /// Esc — peel one modal layer.
    Escape,
    /// Return, and the keypad's Enter with it — confirm.
    Enter,
    /// Backspace — undo the last typed label letter (Hint mode's only editing key).
    Backspace,
    /// ↑.
    Up,
    /// ↓.
    Down,
    /// ←.
    Left,
    /// →.
    Right,
}

impl ModalKey {
    /// Every modal key, in case-index order.
    pub const ALL: [Self; 7] = [
        Self::Escape,
        Self::Enter,
        Self::Backspace,
        Self::Up,
        Self::Down,
        Self::Left,
        Self::Right,
    ];

    /// The case index the boundary carries, so a caller that already has its own enum can rebuild
    /// one without the text.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Escape => 0,
            Self::Enter => 1,
            Self::Backspace => 2,
            Self::Up => 3,
            Self::Down => 4,
            Self::Left => 5,
            Self::Right => 6,
        }
    }
}

/// The modal key a HID usage is, or `None` for a press a mode reads as its character.
///
/// Tab, the editing block, the page keys and the function block are special keys that no mode
/// binds, so they answer `None` and reach the mode as an unmatched character — which both modes
/// already swallow. That is the same shape the Mac's adapter has: its `default` arm collapses every
/// unrecognised key onto a character, and the mode's `default` swallows it.
#[must_use]
pub const fn modal_key(hid_usage: u16) -> Option<ModalKey> {
    let key = match special_key(hid_usage) {
        Some(SpecialKey::Escape) => ModalKey::Escape,
        Some(SpecialKey::Return) => ModalKey::Enter,
        Some(SpecialKey::Backspace) => ModalKey::Backspace,
        Some(SpecialKey::Up) => ModalKey::Up,
        Some(SpecialKey::Down) => ModalKey::Down,
        Some(SpecialKey::Left) => ModalKey::Left,
        Some(SpecialKey::Right) => ModalKey::Right,
        _ => return None,
    };
    Some(key)
}

/// `UIKeyboardHIDUsage.keyboardReturnOrEnter`.
pub const HID_RETURN: u16 = 40;
/// `UIKeyboardHIDUsage.keyboardEscape`.
pub const HID_ESCAPE: u16 = 41;
/// `UIKeyboardHIDUsage.keyboardDeleteOrBackspace`.
pub const HID_BACKSPACE: u16 = 42;
/// `UIKeyboardHIDUsage.keyboardTab`.
pub const HID_TAB: u16 = 43;
/// `UIKeyboardHIDUsage.keyboardSpacebar`.
pub const HID_SPACE: u16 = 44;
/// `UIKeyboardHIDUsage.keyboardF1`. F1 to F12 are contiguous from here.
pub const HID_F1: u16 = 58;
/// `UIKeyboardHIDUsage.keyboardF2`.
pub const HID_F2: u16 = 59;
/// `UIKeyboardHIDUsage.keyboardF3`.
pub const HID_F3: u16 = 60;
/// `UIKeyboardHIDUsage.keyboardF4`.
pub const HID_F4: u16 = 61;
/// `UIKeyboardHIDUsage.keyboardF5`.
pub const HID_F5: u16 = 62;
/// `UIKeyboardHIDUsage.keyboardF6`.
pub const HID_F6: u16 = 63;
/// `UIKeyboardHIDUsage.keyboardF7`.
pub const HID_F7: u16 = 64;
/// `UIKeyboardHIDUsage.keyboardF8`.
pub const HID_F8: u16 = 65;
/// `UIKeyboardHIDUsage.keyboardF9`.
pub const HID_F9: u16 = 66;
/// `UIKeyboardHIDUsage.keyboardF10`.
pub const HID_F10: u16 = 67;
/// `UIKeyboardHIDUsage.keyboardF11`.
pub const HID_F11: u16 = 68;
/// `UIKeyboardHIDUsage.keyboardF12`.
pub const HID_F12: u16 = 69;
/// `UIKeyboardHIDUsage.keyboardInsert`.
pub const HID_INSERT: u16 = 73;
/// `UIKeyboardHIDUsage.keyboardHome`.
pub const HID_HOME: u16 = 74;
/// `UIKeyboardHIDUsage.keyboardPageUp`.
pub const HID_PAGE_UP: u16 = 75;
/// `UIKeyboardHIDUsage.keyboardDeleteForward`.
pub const HID_FORWARD_DELETE: u16 = 76;
/// `UIKeyboardHIDUsage.keyboardEnd`.
pub const HID_END: u16 = 77;
/// `UIKeyboardHIDUsage.keyboardPageDown`.
pub const HID_PAGE_DOWN: u16 = 78;
/// `UIKeyboardHIDUsage.keyboardRightArrow`.
pub const HID_RIGHT: u16 = 79;
/// `UIKeyboardHIDUsage.keyboardLeftArrow`.
pub const HID_LEFT: u16 = 80;
/// `UIKeyboardHIDUsage.keyboardDownArrow`.
pub const HID_DOWN: u16 = 81;
/// `UIKeyboardHIDUsage.keyboardUpArrow`.
pub const HID_UP: u16 = 82;
/// `UIKeyboardHIDUsage.keypadEnter`.
pub const HID_KEYPAD_ENTER: u16 = 88;

/// Which of the phone's two input paths a press takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// Encode it here and write the bytes to the pane, never passing it on down the chain.
    KeyEncoding,
    /// Pass it on, so `UIKit`'s own text input can compose it and commit through `insertText`.
    ImeProxy,
}

/// Which path this press takes.
///
/// A special key, or any of ⌃⌥⌘, goes to the encoder — the proxy would swallow or mis-compose all
/// of them. Everything else is typing, and typing is the proxy's, ⇧ included.
#[must_use]
pub const fn route(press: &KeyPress<'_>) -> Route {
    if special_key(press.hid_usage).is_some() || press.control || press.option || press.command {
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

/// The bytes a special key sends.
///
/// Three families. The cursor block — the four arrows and Home/End — takes the live introducer,
/// because `DECCKM` is exactly the mode that moves them between CSI and SS3. The editing block
/// (Insert, forward Delete, the page keys) and F5 upward are `CSI n ~`, which no mode rewrites. F1
/// to F4 are SS3 unconditionally: their SS3 forms are what every terminfo entry carries, so there
/// is no CSI spelling to prefer.
///
/// `shift` is read by exactly one key. `UIKit` reports Tab's usage with and without it, so the flag
/// is the only thing that separates a back-tab (`CBT`) from a forward one.
#[must_use]
pub fn special_bytes(key: SpecialKey, shift: bool, application_cursor_keys: bool) -> Vec<u8> {
    let cursor = |final_byte: u8| vec![ESC, introducer(application_cursor_keys), final_byte];
    let tilde = |digits: &str| {
        let mut bytes = vec![ESC, CSI];
        bytes.extend_from_slice(digits.as_bytes());
        bytes.push(b'~');
        bytes
    };
    match key {
        SpecialKey::Escape => vec![ESC],
        SpecialKey::Tab if shift => vec![ESC, CSI, b'Z'],
        SpecialKey::Tab => vec![0x09],
        SpecialKey::Return => vec![0x0D],
        SpecialKey::Backspace => vec![0x7F],
        SpecialKey::Up => cursor(b'A'),
        SpecialKey::Down => cursor(b'B'),
        SpecialKey::Right => cursor(b'C'),
        SpecialKey::Left => cursor(b'D'),
        SpecialKey::Home => cursor(b'H'),
        SpecialKey::End => cursor(b'F'),
        SpecialKey::Insert => tilde("2"),
        SpecialKey::ForwardDelete => tilde("3"),
        SpecialKey::PageUp => tilde("5"),
        SpecialKey::PageDown => tilde("6"),
        SpecialKey::F1 => vec![ESC, SS3, b'P'],
        SpecialKey::F2 => vec![ESC, SS3, b'Q'],
        SpecialKey::F3 => vec![ESC, SS3, b'R'],
        SpecialKey::F4 => vec![ESC, SS3, b'S'],
        SpecialKey::F5 => tilde("15"),
        SpecialKey::F6 => tilde("17"),
        SpecialKey::F7 => tilde("18"),
        SpecialKey::F8 => tilde("19"),
        SpecialKey::F9 => tilde("20"),
        SpecialKey::F10 => tilde("21"),
        SpecialKey::F11 => tilde("23"),
        SpecialKey::F12 => tilde("24"),
    }
}

/// The raw bytes a press sends, or `None` for a press that sends nothing.
///
/// A ⌘ combination is `None` before anything else is asked: on both platforms ⌘ is the
/// application's modifier, so ⌘K is the palette and ⌘← is a shortcut that missed, never terminal
/// input. Bare typing is `None` too — that press belongs to the proxy, and the responder never
/// asks.
///
/// ⌥ on anything that does encode takes the xterm meta prefix: `ESC` then the bytes the key would
/// have sent alone. That is one rule covering `⌥Backspace` (delete-previous-word), `⌥Return`, `⌥←`
/// and `⌥b` alike, and it is what makes word-wise shell editing work from a phone at all. ⌃ on a
/// special key deliberately does NOT take it — that form needs a parameterised CSI
/// (`ESC [ 1 ; 5 D`), which is a different sequence, not a prefix.
#[must_use]
pub fn encode(press: &KeyPress<'_>, application_cursor_keys: bool) -> Option<Vec<u8>> {
    if press.command {
        return None;
    }
    if let Some(key) = special_key(press.hid_usage) {
        let bytes = special_bytes(key, press.shift, application_cursor_keys);
        return Some(meta_prefixed(press.option, bytes));
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

/// A non-printable key the binding table names — the eleven `slopdesk_video::key_naming::NamedKey`
/// cases, in that order, so the boundary can rebuild one from a case index without the text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamedChordKey {
    /// Return, and the keypad's Enter with it.
    Return,
    /// Tab.
    Tab,
    /// The space bar, which is a chord only with a non-⇧ modifier held.
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
/// Named keys first, off the HID usage. Otherwise a SINGLE printable base character: whitespace and
/// control scalars are refused, so ordinary typing falls through to the proxy while a `⌃`-letter —
/// which still reports its printable base — stays classifiable.
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

    if let Some(named) = named_chord_key(press.hid_usage, modifiers) {
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

/// What capturing one press in the Settings chord recorder means.
///
/// The same four answers `slopdesk_video::key_naming::CaptureOutcome` gives the Mac's recorder, in
/// the same order, because the two recorders write into ONE override map: a phone that answered
/// differently would let the same physical key mean "rebind" on one half and "clear" on the other.
/// The agreement is pinned in `slopdesk-ffi`, which is the crate that can see both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CaptureVerdict {
    /// Esc — stop recording and change nothing.
    Cancel,
    /// Backspace or Forward Delete — CLEAR the binding, restoring the registry default.
    Clear,
    /// A pure modifier, a dead key, or a key the recorder cannot spell back: keep recording.
    #[default]
    Ignore,
    /// Record this chord as the binding's override.
    Bind(Chord),
}

/// The chord the RECORDER would persist for this press, or `None` when there is nothing to store.
///
/// Stricter than [`key_chord`] in exactly the two ways the Mac's recorder is stricter than its
/// dispatcher, and for the same reasons. The space bar is no key at all here — a recorder that
/// offered it would let the user bind the space bar itself — and a printable base must be ASCII or
/// a letter, because this answer is written to a config file and read back by the chord grammar, so
/// a key that cannot be spelled back is refused at capture time rather than stored as a chord
/// nobody can type.
#[must_use]
pub fn capture_chord(press: &KeyPress<'_>) -> Option<Chord> {
    let chord = key_chord(press)?;
    match chord.key {
        ChordKey::Named(NamedChordKey::Space) => None,
        ChordKey::Named(_) => Some(chord),
        ChordKey::Character(base) => (base.is_ascii() || base.is_alphabetic()).then_some(chord),
    }
}

/// What one captured press does to the binding being recorded.
///
/// The clear keys are checked BEFORE the chord, which is the ordering the Mac's recorder documents
/// and for the same reason: Backspace's own base character is the DEL scalar, and a recorder that
/// asked for the chord first would store it as a binding instead of clearing one.
#[must_use]
pub fn capture_verdict(press: &KeyPress<'_>) -> CaptureVerdict {
    match press.hid_usage {
        HID_ESCAPE => CaptureVerdict::Cancel,
        HID_BACKSPACE | HID_FORWARD_DELETE => CaptureVerdict::Clear,
        _ => capture_chord(press).map_or(CaptureVerdict::Ignore, CaptureVerdict::Bind),
    }
}

/// The named key a HID usage is, for the dispatcher.
///
/// Space is the one conditional row, and it is the same rule
/// `slopdesk_video::key_naming::dispatch_named_key` applies to the Mac's key code: a bare or ⇧-only
/// Space is typing that must reach the terminal, while with ⌃, ⌥ or ⌘ held it is the Vi-mode chord.
/// Anything else about the space bar would either steal the space character or make ⌃⇧Space
/// unbindable.
const fn named_chord_key(hid_usage: u16, modifiers: u8) -> Option<NamedChordKey> {
    let key = match hid_usage {
        HID_RETURN | HID_KEYPAD_ENTER => NamedChordKey::Return,
        HID_TAB => NamedChordKey::Tab,
        HID_SPACE if modifiers & !MOD_SHIFT != 0 => NamedChordKey::Space,
        HID_LEFT => NamedChordKey::Left,
        HID_RIGHT => NamedChordKey::Right,
        HID_UP => NamedChordKey::Up,
        HID_DOWN => NamedChordKey::Down,
        HID_PAGE_UP => NamedChordKey::PageUp,
        HID_PAGE_DOWN => NamedChordKey::PageDown,
        HID_HOME => NamedChordKey::Home,
        HID_END => NamedChordKey::End,
        _ => return None,
    };
    Some(key)
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

/// The bytes one arrow sends — the width of [`floating_cursor_bytes`]' answer, which is declared in
/// terms of this so the two cannot disagree.
pub const FLOATING_CURSOR_ARROW_BYTES: usize = 3;

/// The most bytes one [`FloatingCursor::feed`] can be worth.
///
/// A caller sizing a buffer for [`floating_cursor_run`] asks for THIS rather than multiplying the
/// two constants itself: a product spelled at a call site is the same number written twice, and the
/// second spelling is the one nobody updates.
pub const MAX_FLOATING_CURSOR_RUN_BYTES: usize = MAX_FLOATING_CURSOR_ARROWS * FLOATING_CURSOR_ARROW_BYTES;

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

/// The bytes one floating-cursor arrow sends, under the live cursor-key mode.
#[must_use]
pub const fn floating_cursor_bytes(
    arrow: Arrow,
    application_cursor_keys: bool,
) -> [u8; FLOATING_CURSOR_ARROW_BYTES] {
    let final_byte = match arrow {
        Arrow::Right => b'C',
        Arrow::Left => b'D',
    };
    [ESC, introducer(application_cursor_keys), final_byte]
}

/// A run of arrows as one buffer, for one write to the pane.
#[must_use]
pub fn floating_cursor_run(arrows: &[Arrow], application_cursor_keys: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(arrows.len() * FLOATING_CURSOR_ARROW_BYTES);
    for arrow in arrows {
        out.extend_from_slice(&floating_cursor_bytes(*arrow, application_cursor_keys));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::send_keys::key_token;

    fn press(base: &str) -> KeyPress<'_> {
        KeyPress {
            base,
            hid_usage: HID_NONE,
            control: false,
            option: false,
            command: false,
            shift: false,
        }
    }

    fn special(hid_usage: u16) -> KeyPress<'static> {
        KeyPress {
            hid_usage,
            ..press("")
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
        // The space bar types; the encoder must never see a bare one.
        assert_eq!(
            route(&KeyPress {
                hid_usage: HID_SPACE,
                ..press(" ")
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
        assert_eq!(route(&special(HID_ESCAPE)), Route::KeyEncoding);
        // The nav block a characters-keyed table used to drop whole (`docs/29` #7).
        for usage in [
            HID_HOME,
            HID_END,
            HID_PAGE_UP,
            HID_PAGE_DOWN,
            HID_INSERT,
            HID_FORWARD_DELETE,
            HID_F5,
        ] {
            assert_eq!(route(&special(usage)), Route::KeyEncoding, "usage {usage}");
        }
    }

    /// The join between the two tables. Every special key must encode exactly what its
    /// `send_keys` token name does, in the cursor-key-RESET form — that is the mode `send_keys`
    /// itself documents emitting, and the only one it has.
    #[test]
    fn send_keys_agrees_on_every_special() {
        for key in SpecialKey::ALL {
            assert_eq!(
                Some(special_bytes(key, false, false)),
                key_token(key.token_name()),
                "{} disagrees with <{}>",
                key.token_name(),
                key.token_name(),
            );
        }
    }

    #[test]
    fn every_special_usage_maps_and_nothing_else_does() {
        for key in SpecialKey::ALL {
            assert!(!special_bytes(key, false, false).is_empty());
        }
        assert_eq!(special_key(HID_NONE), None);
        assert_eq!(special_key(HID_SPACE), None, "the space bar types");
        assert_eq!(special_key(4), None, "the letter a");
        assert_eq!(special_key(HID_KEYPAD_ENTER), Some(SpecialKey::Return));
        assert_eq!(special_key(HID_F12), Some(SpecialKey::F12));
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

    /// `DECCKM` moves the cursor block and nothing else.
    #[test]
    fn the_cursor_mode_picks_the_introducer() {
        assert_eq!(special_bytes(SpecialKey::Up, false, false), vec![
            0x1B, 0x5B, b'A'
        ]);
        assert_eq!(special_bytes(SpecialKey::Up, false, true), vec![0x1B, 0x4F, b'A']);
        assert_eq!(special_bytes(SpecialKey::Home, false, true), vec![
            0x1B, 0x4F, b'H'
        ]);
        assert_eq!(special_bytes(SpecialKey::End, false, true), vec![
            0x1B, 0x4F, b'F'
        ]);
        for key in [
            SpecialKey::Escape,
            SpecialKey::PageUp,
            SpecialKey::F5,
            SpecialKey::ForwardDelete,
        ] {
            assert_eq!(
                special_bytes(key, false, true),
                special_bytes(key, false, false),
                "{} is not a cursor key",
                key.token_name(),
            );
        }
    }

    #[test]
    fn shift_is_the_only_thing_that_tells_back_tab_from_tab() {
        assert_eq!(special_bytes(SpecialKey::Tab, false, false), vec![0x09]);
        assert_eq!(special_bytes(SpecialKey::Tab, true, false), vec![
            0x1B, 0x5B, b'Z'
        ]);
        // And ⇧ changes nothing anywhere else.
        assert_eq!(special_bytes(SpecialKey::Up, true, false), vec![0x1B, 0x5B, b'A']);
    }

    #[test]
    fn option_prefixes_every_key_it_is_held_with() {
        let meta = |usage: u16| {
            encode(
                &KeyPress {
                    option: true,
                    ..special(usage)
                },
                false,
            )
        };
        assert_eq!(meta(HID_BACKSPACE), Some(vec![0x1B, 0x7F]));
        assert_eq!(meta(HID_RETURN), Some(vec![0x1B, 0x0D]));
        assert_eq!(meta(HID_LEFT), Some(vec![0x1B, 0x1B, 0x5B, b'D']));
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

    /// ⌘ is the application's modifier on both platforms, so it never reaches the PTY — not even on
    /// a special key, where the identity table would otherwise happily answer.
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
        assert_eq!(
            encode(
                &KeyPress {
                    command: true,
                    ..special(HID_LEFT)
                },
                false
            ),
            None
        );
        assert_eq!(encode(&press(""), false), None);
        assert_eq!(encode(&press("a"), false), None, "typing is the proxy's");
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
        assert_eq!(encode(&special(HID_ESCAPE), false), Some(vec![0x1B]));
        assert_eq!(encode(&special(HID_RETURN), false), Some(vec![0x0D]));
        assert_eq!(encode(&special(HID_DOWN), true), Some(vec![0x1B, 0x4F, b'B']));
        assert_eq!(
            encode(&special(HID_PAGE_DOWN), false),
            Some(vec![0x1B, 0x5B, b'6', b'~'])
        );
        // ⌃Space is NUL, which is the one press whose base is whitespace and still encodes.
        assert_eq!(
            encode(
                &KeyPress {
                    control: true,
                    hid_usage: HID_SPACE,
                    ..press(" ")
                },
                false
            ),
            Some(vec![0x00]),
        );
    }

    #[test]
    fn named_keys_beat_the_printable_path() {
        assert_eq!(
            key_chord(&special(HID_RETURN)),
            Some(Chord {
                key: ChordKey::Named(NamedChordKey::Return),
                modifiers: 0
            }),
        );
        assert_eq!(
            key_chord(&KeyPress {
                shift: true,
                command: true,
                ..special(HID_UP)
            }),
            Some(Chord {
                key: ChordKey::Named(NamedChordKey::Up),
                modifiers: MOD_SHIFT | MOD_COMMAND,
            }),
        );
        assert_eq!(
            key_chord(&special(HID_PAGE_UP)),
            Some(Chord {
                key: ChordKey::Named(NamedChordKey::PageUp),
                modifiers: 0
            }),
        );
    }

    /// The space bar is a chord only once a non-⇧ modifier is held — the Vi-mode rule the Mac's
    /// dispatcher applies to its own key code.
    #[test]
    fn space_is_a_chord_only_with_a_real_modifier() {
        let bare = KeyPress {
            hid_usage: HID_SPACE,
            ..press(" ")
        };
        assert_eq!(key_chord(&bare), None);
        assert_eq!(
            key_chord(&KeyPress { shift: true, ..bare }),
            None,
            "⇧Space is still a space",
        );
        assert_eq!(
            key_chord(&KeyPress {
                control: true,
                shift: true,
                ..bare
            }),
            Some(Chord {
                key: ChordKey::Named(NamedChordKey::Space),
                modifiers: MOD_SHIFT | MOD_CONTROL,
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

    /// Esc and the two clear keys are answered by their USAGE, before anything asks what they
    /// spell — which is the whole reason Backspace clears a binding instead of recording the DEL
    /// scalar as one.
    #[test]
    fn the_recorder_answers_escape_and_the_clear_keys_by_usage() {
        assert_eq!(capture_verdict(&special(HID_ESCAPE)), CaptureVerdict::Cancel);
        assert_eq!(
            capture_verdict(&KeyPress {
                command: true,
                ..special(HID_ESCAPE)
            }),
            CaptureVerdict::Cancel,
            "a modifier does not turn Esc into a chord",
        );
        assert_eq!(capture_verdict(&special(HID_BACKSPACE)), CaptureVerdict::Clear);
        assert_eq!(
            capture_verdict(&special(HID_FORWARD_DELETE)),
            CaptureVerdict::Clear
        );
        assert_eq!(
            capture_verdict(&KeyPress {
                base: "\u{7f}",
                ..special(HID_BACKSPACE)
            }),
            CaptureVerdict::Clear,
            "the DEL scalar Backspace reports is never stored as a chord",
        );
    }

    /// What the recorder will and will not persist. The space bar is the one key the dispatcher
    /// names and the recorder refuses, and a base it cannot spell back is refused with it.
    #[test]
    fn the_recorder_persists_only_a_chord_the_grammar_can_spell() {
        assert_eq!(
            capture_verdict(&KeyPress {
                command: true,
                shift: true,
                ..press("P")
            }),
            CaptureVerdict::Bind(Chord {
                key: ChordKey::Character('P'),
                modifiers: MOD_SHIFT | MOD_COMMAND,
            }),
        );
        assert_eq!(
            capture_verdict(&KeyPress {
                command: true,
                ..special(HID_PAGE_UP)
            }),
            CaptureVerdict::Bind(Chord {
                key: ChordKey::Named(NamedChordKey::PageUp),
                modifiers: MOD_COMMAND,
            }),
        );
        let space = KeyPress {
            hid_usage: HID_SPACE,
            control: true,
            shift: true,
            ..press(" ")
        };
        assert!(key_chord(&space).is_some(), "the dispatcher names ⌃⇧Space");
        assert_eq!(
            capture_verdict(&space),
            CaptureVerdict::Ignore,
            "the recorder does not let the space bar be bound",
        );
        assert_eq!(
            capture_verdict(&KeyPress {
                command: true,
                ..press("→")
            }),
            CaptureVerdict::Ignore,
            "a base that is neither ASCII nor a letter cannot be spelled back",
        );
        assert_eq!(capture_verdict(&press("")), CaptureVerdict::Ignore);
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

    /// The six keys a mode reads as commands, off the SAME usages the encoder resolves — so a
    /// keyboard whose Escape reaches the encoder cannot fail to reach copy mode's Escape.
    #[test]
    fn a_mode_reads_six_keys_as_commands() {
        assert_eq!(modal_key(HID_ESCAPE), Some(ModalKey::Escape));
        assert_eq!(modal_key(HID_RETURN), Some(ModalKey::Enter));
        assert_eq!(modal_key(HID_KEYPAD_ENTER), Some(ModalKey::Enter));
        assert_eq!(modal_key(HID_BACKSPACE), Some(ModalKey::Backspace));
        assert_eq!(modal_key(HID_UP), Some(ModalKey::Up));
        assert_eq!(modal_key(HID_DOWN), Some(ModalKey::Down));
        assert_eq!(modal_key(HID_LEFT), Some(ModalKey::Left));
        assert_eq!(modal_key(HID_RIGHT), Some(ModalKey::Right));
    }

    /// Everything else reaches the mode as its character — a key that types, and equally a special
    /// key no mode binds. Tab is the one that would be tempting to fold onto something; it is not.
    #[test]
    fn every_other_key_reaches_the_mode_as_its_character() {
        assert_eq!(modal_key(HID_NONE), None);
        assert_eq!(modal_key(HID_TAB), None);
        assert_eq!(modal_key(HID_FORWARD_DELETE), None);
        assert_eq!(modal_key(HID_PAGE_UP), None);
        assert_eq!(modal_key(HID_F1), None);
        assert_eq!(modal_key(HID_SPACE), None);
    }

    /// The case indices the boundary carries are a permutation of `ALL` — the near side rebuilds
    /// its own enum from one, so a duplicated or skipped index is a key that silently reads as
    /// another.
    #[test]
    fn every_modal_index_is_its_own() {
        let mut seen = std::collections::BTreeSet::new();
        for key in ModalKey::ALL {
            assert!(seen.insert(key.index()), "{key:?} repeats an index");
        }
        assert_eq!(seen.len(), ModalKey::ALL.len());
        assert!(seen.iter().all(|index| *index < 0xFF));
    }

    /// The number a caller sizes its buffer at is the number the worst feed actually produces. A
    /// caller that multiplied the two constants itself would be spelling this product a second
    /// time, in another language, where nothing could compare them.
    #[test]
    fn the_advertised_run_capacity_holds_the_longest_run() {
        let mut cursor = FloatingCursor::default();
        let arrows = cursor.feed(f64::MAX);
        assert_eq!(arrows.len(), MAX_FLOATING_CURSOR_ARROWS);
        assert_eq!(
            floating_cursor_run(&arrows, false).len(),
            MAX_FLOATING_CURSOR_RUN_BYTES
        );
    }
}
