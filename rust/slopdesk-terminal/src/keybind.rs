//! The grammar for one `keybind` line of `~/.config/slopdesk/config.toml`.
//!
//! A user authors bindings as `keybind = <chord>:<action>`. This parses the right-hand side into a
//! chord plus a typed action: the literal-byte forms (`text:` / `csi:` / `esc:`) carry the bytes
//! already resolved, ready to be written to a pane; a named action carries a stable id and optional
//! argument for the registry; `unbind:<chord>` suppresses a default.
//!
//! ## Validate then drop
//!
//! Config text is untrusted the way a datagram is. Every entry point answers `None` on a malformed
//! token — an empty key, an unknown modifier, a multi-character key with no named spelling, a
//! missing payload, a `goto_tab` argument that is not a number — and nothing here panics, indexes
//! past an end, or unwraps. A `\xNN` escape has its two digits BOUNDED before a byte is appended,
//! so a payload ending in `\x` is refused rather than read past.
//!
//! ## Two deliberate rejections
//!
//! A `>` anywhere in a chord is refused: `cmd+b>cmd+v` is a SEQUENCE, and accepting it here would
//! silently bind only its first half. And `escape`, `delete`, `backspace` and `forwarddelete` are
//! refused as base keys even though a user might reasonably write them: the dispatcher has no case
//! for any of them, so such a binding would parse, store, and then never fire. Refusing it is what
//! makes the failure visible.
//!
//! `space` was in that second list and should not have been — the dispatcher names it (⌃⇧Space
//! enters Vi mode), so refusing it withheld a chord the app can actually deliver. That is the
//! failure mode a list kept by hand has, and why the named keys are now ONE table: the spellings
//! this grammar accepts and the spelling each one is stored under are read off the same rows.

use slopdesk_sanitize::escape;

/// The ESCAPE control byte — the lead byte of an `esc:` or `csi:` sequence.
pub const ESC: u8 = 0x1B;

/// The CSI introducer that follows `ESC` in a `csi:` sequence.
pub const CSI_INTRODUCER: u8 = 0x5B;

/// A chord: a base key plus the modifiers held with it.
///
/// Four flags, because the platform has four modifier keys and any combination of them is a chord a
/// user can hold. They are not a state with four states, so an enum would have to enumerate sixteen
/// of them, and a mask would make every reader translate.
#[expect(
    clippy::struct_excessive_bools,
    reason = "the four are the platform's four modifiers, which combine rather than exclude"
)]
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Chord {
    /// The base key, lowercased — a single character, or a named key such as `pageup`.
    pub key: String,
    /// Whether ⌘ is held.
    pub command: bool,
    /// Whether ⇧ is held.
    pub shift: bool,
    /// Whether ⌥ is held.
    pub option: bool,
    /// Whether ⌃ is held.
    pub control: bool,
}

/// The typed right-hand side of one binding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// `text:<s>` — the literal bytes of `<s>`.
    Text(Vec<u8>),
    /// `csi:<p>` — `ESC [` followed by `<p>`'s bytes.
    Csi(Vec<u8>),
    /// `esc:<p>` — `ESC` followed by `<p>`'s bytes.
    Esc(Vec<u8>),
    /// A named registry action with an optional argument, as in `goto_tab:1`.
    Named {
        /// The action id.
        id: String,
        /// The argument, when the line carried one.
        arg: Option<String>,
    },
    /// `unbind:<chord>` — suppress the default action on the chord.
    Unbind,
}

/// One parsed line: the chord it fires on, and what it does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Binding {
    /// The chord. For an unbind, the chord being suppressed.
    pub chord: Chord,
    /// The action.
    pub action: Action,
}

/// Parses one binding line — `<chord>:<action>`, or the `unbind:<chord>` special form.
///
/// The leading token decides the split: a line that STARTS with `unbind:` is the special form and
/// everything after the colon is the chord. Otherwise the FIRST colon separates chord from action,
/// so `cmd+1:goto_tab:1` splits as `cmd+1` and `goto_tab:1`, and the action then splits its own.
#[must_use]
pub fn parse_line(raw: &str) -> Option<Binding> {
    let line = trim_config_spaces(raw);
    if line.is_empty() {
        return None;
    }
    if let Some(chord_text) = line.strip_prefix("unbind:") {
        return Some(Binding {
            chord: parse_chord(chord_text)?,
            action: Action::Unbind,
        });
    }
    let (chord_text, action_text) = line.split_once(':')?;
    Some(Binding {
        chord: parse_chord(chord_text)?,
        action: parse_action(action_text)?,
    })
}

/// Parses a chord — `cmd+shift+h`, `ctrl+a`, `cmd+pageup`.
///
/// Modifiers are `cmd`/`command`, `ctrl`/`control`, `alt`/`opt`/`option` and `shift`, joined by
/// `+`; the LAST segment is the base key. Empty segments are kept rather than collapsed, so a stray
/// `cmd+`, `+h` or `cmd++h` surfaces as a malformed modifier instead of quietly parsing.
#[must_use]
pub fn parse_chord(raw: &str) -> Option<Chord> {
    let text = trim_config_spaces(raw).to_lowercase();
    if text.is_empty() || text.contains('>') {
        return None;
    }
    let segments: Vec<&str> = text.split('+').collect();
    let (key, modifiers) = segments.split_last()?;
    let mut chord = Chord {
        key: (*key).to_owned(),
        ..Chord::default()
    };
    for modifier in modifiers {
        match *modifier {
            "cmd" | "command" => chord.command = true,
            "ctrl" | "control" => chord.control = true,
            "alt" | "opt" | "option" => chord.option = true,
            "shift" => chord.shift = true,
            // An empty segment is malformed, and so is anything unrecognised.
            _ => return None,
        }
    }
    is_valid_base_key(&chord.key).then_some(chord)
}

/// Parses an action — one of the three literal-byte prefixes, or a named action with an optional
/// `:arg`.
#[must_use]
pub fn parse_action(raw: &str) -> Option<Action> {
    let text = trim_config_spaces(raw);
    if text.is_empty() {
        return None;
    }
    if let Some(payload) = text.strip_prefix("text:") {
        return non_empty(literal_bytes(payload)?).map(Action::Text);
    }
    if let Some(payload) = text.strip_prefix("csi:") {
        let bytes = non_empty(literal_bytes(payload)?)?;
        return Some(Action::Csi(prefixed(&[ESC, CSI_INTRODUCER], &bytes)));
    }
    if let Some(payload) = text.strip_prefix("esc:") {
        let bytes = non_empty(literal_bytes(payload)?)?;
        return Some(Action::Esc(prefixed(&[ESC], &bytes)));
    }
    // A named action, optionally `id:arg`. The FIRST colon splits; the argument keeps the rest.
    if let Some((id, arg)) = text.split_once(':') {
        if id.is_empty() || arg.is_empty() {
            return None;
        }
        // Bound the one parameterised action there is: `goto_tab` takes a base-ten integer.
        if id == "goto_tab" && arg.parse::<i64>().is_err() {
            return None;
        }
        return Some(Action::Named {
            id: id.to_owned(),
            arg: Some(arg.to_owned()),
        });
    }
    Some(Action::Named {
        id: text.to_owned(),
        arg: None,
    })
}

/// The bytes a `text:` / `csi:` / `esc:` payload spells.
///
/// The payload is its own UTF-8, with a small escape vocabulary so a user can author control bytes
/// a config file cannot hold literally: `\n`, `\r`, `\t`, `\e` (ESC), `\0`, `\\` and `\:`, plus
/// `\xNN` for an arbitrary byte. A dangling backslash, an unknown escape, or an `\x` with fewer
/// than two hex digits refuses the WHOLE payload — a partially decoded escape would put bytes on a
/// pane that the user never wrote.
#[must_use]
pub fn literal_bytes(payload: &str) -> Option<Vec<u8>> {
    let chars: Vec<char> = payload.chars().collect();
    let mut out = Vec::with_capacity(payload.len());
    let mut index = 0;
    while let Some(&current) = chars.get(index) {
        if current != '\\' {
            let mut buffer = [0u8; 4];
            out.extend_from_slice(current.encode_utf8(&mut buffer).as_bytes());
            index += 1;
            continue;
        }
        // An escape needs at least one character after the backslash.
        let next = *chars.get(index + 1)?;
        let byte = match next {
            'n' => 0x0A,
            'r' => 0x0D,
            't' => 0x09,
            'e' => ESC,
            '0' => 0x00,
            '\\' => 0x5C,
            ':' => 0x3A,
            'x' | 'X' => {
                // Both digits are bounded BEFORE either is read, so a payload ending in `\x` is
                // refused rather than walked past.
                let byte = hex_byte(*chars.get(index + 2)?, *chars.get(index + 3)?)?;
                out.push(byte);
                index += 4;
                continue;
            },
            // An unknown escape is malformed.
            _ => return None,
        };
        out.push(byte);
        index += 2;
    }
    Some(out)
}

/// Whether a token can be a chord's base key.
///
/// A single character, or one of the named keys the dispatcher can actually resolve. A multi-
/// character token that is not named is refused rather than stored as a chord nothing will match.
///
/// The single-character test counts SCALARS. A base key built from a combining sequence would be
/// one character to a reader and several here, and is refused — which is the same answer the
/// dispatcher would eventually give it, arrived at earlier.
#[must_use]
pub fn is_valid_base_key(key: &str) -> bool {
    let mut scalars = key.chars();
    if scalars.next().is_some() && scalars.next().is_none() {
        return true;
    }
    folded(key).is_some()
}

/// The named keys, each paired with the ONE spelling it is stored under.
///
/// A canonical spelling is its own row, so the set a chord may be WRITTEN in and the set it is
/// STORED under are read off one table instead of being kept in step by hand. That is the whole
/// point: a spelling this parser accepts but nothing folds binds under a key no keystroke ever
/// produces — the binding is accepted, persisted, and silently never fires.
/// `space` is here because the dispatcher PRODUCES it: a ⌘Space keystroke arrives as the token
/// `space`, so a table without it accepts no config line that could ever match one.
const NAMED_KEYS: [(&str, &str); 18] = [
    ("space", "space"),
    ("return", "return"),
    ("enter", "return"),
    ("tab", "tab"),
    ("left", "left"),
    ("leftarrow", "left"),
    ("right", "right"),
    ("rightarrow", "right"),
    ("up", "up"),
    ("uparrow", "up"),
    ("down", "down"),
    ("downarrow", "down"),
    ("pageup", "pageup"),
    ("pgup", "pageup"),
    ("pagedown", "pagedown"),
    ("pgdn", "pagedown"),
    ("home", "home"),
    ("end", "end"),
];

/// The spelling a named key is stored under, or `None` when this is not a named key.
fn folded(key: &str) -> Option<&'static str> {
    NAMED_KEYS
        .iter()
        .find(|(spelling, _)| *spelling == key)
        .map(|(_, canonical)| *canonical)
}

/// The ONE spelling a base key is stored under: lowercased, with every alias folded.
///
/// A single printable character is already its own canonical form. An unnamed multi-character token
/// is left alone — it matches no keystroke either way, and inventing a spelling for it would only
/// hide that.
#[must_use]
pub fn canonical_base_key(key: &str) -> String {
    let lower = key.to_lowercase();
    folded(&lower).map_or(lower, str::to_owned)
}

/// The chord written back out: modifiers in a fixed order, then the base key, joined by `+`.
///
/// The order is fixed so that two chords that are the same chord produce the same text — it is an
/// identity, which is what makes it usable as a conflict key. It lives beside [`parse_chord`]
/// because it is that function's inverse: every token written here is a token read there, and a
/// writer that drifted from its reader would emit a chord the config file cannot express.
#[must_use]
pub fn canonical_chord(chord: &Chord) -> String {
    let mut text = String::new();
    for (held, token) in [
        (chord.control, "ctrl"),
        (chord.option, "opt"),
        (chord.shift, "shift"),
        (chord.command, "cmd"),
    ] {
        if held {
            text.push_str(token);
            text.push('+');
        }
    }
    text.push_str(&canonical_base_key(&chord.key));
    text
}

/// A payload that decoded to nothing is not a payload.
fn non_empty(bytes: Vec<u8>) -> Option<Vec<u8>> {
    (!bytes.is_empty()).then_some(bytes)
}

/// The lead bytes, then the payload.
fn prefixed(lead: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(lead.len() + payload.len());
    bytes.extend_from_slice(lead);
    bytes.extend_from_slice(payload);
    bytes
}

/// Trims the whitespace a config line may carry around a token.
///
/// The set is the config reader's, not the language's: horizontal space only — a tab and the
/// Unicode space separators. A newline is NOT trimmed, because a payload that ends in one asked for
/// it.
pub(crate) fn trim_config_spaces(text: &str) -> &str {
    text.trim_matches(|character: char| {
        character == '\u{9}'
            || character == '\u{20}'
            || character == '\u{a0}'
            || character == '\u{1680}'
            || ('\u{2000}'..='\u{200a}').contains(&character)
            || character == '\u{202f}'
            || character == '\u{205f}'
            || character == '\u{3000}'
    })
}

/// Two hex characters as the byte they spell.
///
/// Delegated rather than spelled: the `try_from` is what carries the `char` grammar into the byte
/// one, and a non-ASCII character is not a hex digit either way.
fn hex_byte(high: char, low: char) -> Option<u8> {
    escape::hex_byte(u8::try_from(high).ok()?, u8::try_from(low).ok()?)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        Action, Chord, ESC, NAMED_KEYS, canonical_base_key, canonical_chord, is_valid_base_key,
        literal_bytes, parse_action, parse_chord, parse_line,
    };

    #[expect(
        clippy::fn_params_excessive_bools,
        reason = "the four are the chord's four modifier flags, in the order the struct declares them"
    )]
    fn chord(key: &str, command: bool, shift: bool, option: bool, control: bool) -> Chord {
        Chord {
            key: key.to_owned(),
            command,
            shift,
            option,
            control,
        }
    }

    #[test]
    fn a_chord_reads_its_modifiers_by_any_of_their_spellings() {
        assert_eq!(
            parse_chord("cmd+shift+h"),
            Some(chord("h", true, true, false, false))
        );
        assert_eq!(parse_chord("OPT+d"), Some(chord("d", false, false, true, false)));
        assert_eq!(parse_chord("option+d"), parse_chord("alt+d"));
        assert_eq!(parse_chord("control+a"), parse_chord("ctrl+a"));
        assert_eq!(
            parse_chord("cmd+pageup"),
            Some(chord("pageup", true, false, false, false))
        );
    }

    #[test]
    fn a_malformed_chord_is_dropped_rather_than_guessed_at() {
        assert_eq!(parse_chord(""), None);
        assert_eq!(parse_chord("hyper+h"), None, "an unknown modifier");
        assert_eq!(parse_chord("cmd++h"), None, "an empty segment is not a modifier");
        assert_eq!(parse_chord("+h"), None);
        assert_eq!(parse_chord("cmd+"), None, "no base key");
        assert_eq!(parse_chord("cmd+notakey"), None, "multi-character, not named");
        assert_eq!(
            parse_chord("cmd+b>cmd+v"),
            None,
            "a sequence is not a chord, and half of one is worse"
        );
    }

    #[test]
    fn the_keys_the_dispatcher_cannot_resolve_are_refused_here() {
        for key in ["escape", "esc", "delete", "backspace", "forwarddelete"] {
            assert!(!is_valid_base_key(key), "{key} would parse and then never fire");
            assert_eq!(parse_chord(key), None);
        }
        assert!(is_valid_base_key("a"));
        assert!(is_valid_base_key("pgdn"));
    }

    #[test]
    fn the_literal_forms_carry_their_lead_bytes_already_resolved() {
        assert_eq!(parse_action("text:hi"), Some(Action::Text(b"hi".to_vec())));
        assert_eq!(parse_action("csi:17~"), Some(Action::Csi(b"\x1b[17~".to_vec())));
        assert_eq!(parse_action("esc:O"), Some(Action::Esc(vec![ESC, b'O'])));
        assert_eq!(parse_action("text:"), None, "an empty payload is not a payload");
    }

    #[test]
    fn an_escape_decodes_or_the_whole_payload_is_refused() {
        assert_eq!(literal_bytes(r"a\nb"), Some(vec![b'a', 0x0A, b'b']));
        assert_eq!(literal_bytes(r"\e\0\\\:"), Some(vec![ESC, 0x00, 0x5C, 0x3A]));
        assert_eq!(literal_bytes(r"\x41\x7f"), Some(vec![0x41, 0x7F]));
        assert_eq!(literal_bytes(r"\xAb"), Some(vec![0xAB]), "either case of digit");
        assert_eq!(literal_bytes(r"\"), None, "a dangling backslash");
        assert_eq!(literal_bytes(r"\x4"), None, "one digit is not two");
        assert_eq!(literal_bytes(r"\xzz"), None, "not hex");
        assert_eq!(literal_bytes(r"\q"), None, "an unknown escape");
        assert_eq!(literal_bytes("héllo"), Some("héllo".as_bytes().to_vec()));
    }

    #[test]
    fn a_named_action_keeps_its_argument_and_goto_tab_bounds_one() {
        assert_eq!(
            parse_action("new_tab"),
            Some(Action::Named {
                id: "new_tab".to_owned(),
                arg: None
            })
        );
        assert_eq!(
            parse_action("goto_tab:1"),
            Some(Action::Named {
                id: "goto_tab".to_owned(),
                arg: Some("1".to_owned())
            })
        );
        assert_eq!(parse_action("goto_tab:x"), None, "not a number");
        assert_eq!(parse_action("goto_tab:"), None, "no argument at all");
        assert_eq!(parse_action(":1"), None, "no id");
    }

    #[test]
    fn a_line_splits_on_its_first_colon_and_the_action_splits_on_its_own() {
        let binding = parse_line("cmd+1:goto_tab:1").expect("a binding");
        assert_eq!(binding.chord, chord("1", true, false, false, false));
        assert_eq!(binding.action, Action::Named {
            id: "goto_tab".to_owned(),
            arg: Some("1".to_owned())
        });
        let text = parse_line("cmd+shift+h:text:hi").expect("a binding");
        assert_eq!(text.action, Action::Text(b"hi".to_vec()));
    }

    #[test]
    fn an_unbind_names_the_chord_it_suppresses() {
        let binding = parse_line("unbind:cmd+q").expect("a binding");
        assert_eq!(binding.chord, chord("q", true, false, false, false));
        assert_eq!(binding.action, Action::Unbind);
        assert_eq!(parse_line("unbind:"), None);
        assert_eq!(parse_line("unbind:badmod+q"), None);
        assert_eq!(
            parse_line("unbind:escape"),
            None,
            "a refused base key refuses the line"
        );
    }

    #[test]
    fn half_a_line_is_no_line() {
        assert_eq!(parse_line(""), None);
        assert_eq!(parse_line("   "), None);
        assert_eq!(parse_line("cmd+h"), None, "no action");
        assert_eq!(
            parse_line("cmd+h:text:"),
            None,
            "a malformed action drops the line"
        );
        assert_eq!(parse_line("badmod+h:text:hi"), None);
        assert_eq!(parse_line("cmd+escape:text:hi"), None);
    }

    #[test]
    fn a_payload_keeps_the_newline_it_asked_for() {
        assert_eq!(
            parse_line("cmd+h:text:hi\n").map(|binding| binding.action),
            Some(Action::Text(b"hi\n".to_vec())),
            "trailing horizontal space is trimmed; a newline is content"
        );
        assert_eq!(
            parse_line("  cmd+h:text:hi  ").map(|binding| binding.action),
            Some(Action::Text(b"hi".to_vec()))
        );
    }

    #[test]
    fn every_spelling_this_parser_accepts_folds_to_one_a_keystroke_produces() {
        for (spelling, canonical) in NAMED_KEYS {
            assert!(is_valid_base_key(spelling), "{spelling}");
            assert_eq!(canonical_base_key(spelling), canonical, "{spelling}");
            // The spelling it folds to is itself a spelling, and folding it again changes nothing.
            assert!(is_valid_base_key(canonical), "{canonical}");
            assert_eq!(canonical_base_key(canonical), canonical, "{canonical}");
        }
    }

    #[test]
    fn a_chord_the_dispatcher_can_produce_is_a_chord_the_file_can_bind() {
        // Every spelling a live keystroke turns into, per the reverse bridge in WorkspaceCore.
        for token in [
            "space", "tab", "return", "left", "right", "up", "down", "pageup", "pagedown", "home", "end",
        ] {
            assert!(is_valid_base_key(token), "{token}");
            assert_eq!(canonical_base_key(token), token, "{token}");
        }
    }

    #[test]
    fn a_key_is_folded_however_the_file_spelled_it() {
        assert_eq!(canonical_base_key("PGUP"), "pageup");
        assert_eq!(canonical_base_key("Enter"), "return");
        assert_eq!(canonical_base_key("D"), "d");
        // Not a named key, so nothing is invented for it.
        assert_eq!(canonical_base_key("f13"), "f13");
    }

    #[test]
    fn a_chord_written_out_is_a_chord_this_file_can_read_back() {
        for key in ["h", "pgup", "leftarrow", "1"] {
            for bits in 0..16_u8 {
                let chord = Chord {
                    key: key.to_owned(),
                    control: bits & 1 != 0,
                    option: bits & 2 != 0,
                    shift: bits & 4 != 0,
                    command: bits & 8 != 0,
                };
                let text = canonical_chord(&chord);
                let read = parse_chord(&text).expect(&text);
                assert_eq!(canonical_chord(&read), text, "{text}");
                assert_eq!(read.key, canonical_base_key(key), "{text}");
            }
        }
    }

    #[test]
    fn the_modifier_order_is_the_identity_two_equal_chords_share() {
        let chord = Chord {
            key: "d".to_owned(),
            command: true,
            shift: true,
            option: false,
            control: false,
        };
        assert_eq!(canonical_chord(&chord), "shift+cmd+d");
        assert_eq!(
            canonical_chord(&parse_chord("CMD+SHIFT+D").expect("parses")),
            canonical_chord(&chord)
        );
    }
}
