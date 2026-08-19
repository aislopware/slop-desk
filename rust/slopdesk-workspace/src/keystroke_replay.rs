//! A clipboard, as the KEY EVENTS a host presses to type it — the one paste a password field takes.
//!
//! macOS's secure event input drops synthetic UNICODE events: a `CGEvent` carrying a string never
//! reaches a `sudo` prompt or a `SecurityAgent` field. A `CGEvent` carrying a virtual KEY CODE
//! does. So the only way to paste into the field a person most wants to paste into is to spell the
//! text back out as the keys a US-QWERTY keyboard would have pressed to produce it, and press them
//! one at a time.
//!
//! That inversion is layout-dependent by construction, and this one assumes US-QWERTY. It is not a
//! guess: the injection is `kVK_ANSI_*` codes into a `CGEventTap`, which the far side interprets
//! under whatever layout it has loaded, and the only layout this table can be right about is the
//! one it was written from.
//!
//! ## ⚠️ A character is a GRAPHEME CLUSTER, and this is a password field
//!
//! The unit walked here is the extended grapheme cluster (UAX-29), never the scalar, and the
//! difference is the whole reason [`unicode_segmentation`] is a dependency of this crate.
//!
//! A decomposed `é` is TWO scalars — `e` (U+0065) followed by a combining acute (U+0301) — and
//! macOS hands out decomposed text on every path that has touched a filesystem name. Walked as
//! scalars, the `e` maps to a key, the combining mark does not, and the encoder types a bare `e`
//! and reports one skip. That is not a degraded paste; it is a DIFFERENT string typed into a field
//! that shows dots, and the person watching has no way to see it happen. Walked as clusters,
//! `"e\u{301}"` is one cluster whose bytes are not one ASCII byte, so it is skipped WHOLE and
//! counted — and the caller's "typed 3, skipped 1" banner is the truth.
//!
//! The rule the tables below encode is therefore stated once, in [`stroke`]: **a cluster maps only
//! when it is exactly one ASCII byte.** Anything longer is somebody's accent, emoji, or script, and
//! the answer to all three is the same refusal.
//!
//! ## What is deliberately NOT here
//!
//! The typing. Pacing between strokes, the down/up pair, folding Shift into both edges, and
//! re-reading the injector each iteration so a pane going read-only mid-paste stops the rest — all
//! of that is the caller's, because all of it is about a live sink over time. What crosses is the
//! SEQUENCE, and how much of the clipboard never made it into one.

use std::borrow::Cow;

use unicode_segmentation::UnicodeSegmentation;

/// The largest clipboard payload that will be replayed as keystrokes.
///
/// A ceiling on the CAPABILITY, not on the text: past this a paste stops being a password and
/// starts being a multi-megabyte typing storm aimed at whatever field happens to have focus. A
/// password is never this long, and an accidental paste of a whole file is the real risk.
///
/// It is measured in CLUSTERS, like everything else here, so the cap a user hits is the one they
/// can count on screen rather than a byte length their alphabet happens to inflate.
pub const MAX_LENGTH: usize = 4096;

/// One synthetic keystroke: a macOS virtual key code (`kVK_ANSI_*`) and whether Shift is held.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stroke {
    /// The `kVK_*` virtual key code the host posts.
    pub key_code: u16,
    /// Whether Shift is held for both edges of the press.
    pub shift: bool,
}

impl Stroke {
    /// The key alone.
    const fn plain(key_code: u16) -> Self {
        Self {
            key_code,
            shift: false,
        }
    }

    /// The key with Shift.
    const fn shifted(key_code: u16) -> Self {
        Self {
            key_code,
            shift: true,
        }
    }
}

/// What one clipboard encoded to: the strokes to press, and how much of it never mapped.
///
/// `skipped` is not a diagnostic — it is the number a caller puts in front of a person before the
/// keys are pressed, because a paste that silently dropped four characters of a credential is
/// worse than one that refused.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Encoded {
    /// The presses, in order.
    pub strokes: Vec<Stroke>,
    /// Clusters that had no US-QWERTY key, plus every cluster past [`MAX_LENGTH`].
    pub skipped: usize,
}

/// Encodes `text` into the strokes that type it, counting everything that could not be typed.
///
/// Overflow past [`MAX_LENGTH`] counts as skipped rather than being dropped quietly, so a caller
/// reporting "typed N, skipped M" says the same thing about a truncated paste as about an
/// unmappable one — in both cases the field will not hold what the clipboard did.
#[must_use]
pub fn encode(text: &str) -> Encoded {
    // ⚠️ CRLF FIRST, before anything counts clusters. `"\r\n"` is ONE cluster under UAX-29 — the
    // one multi-scalar cluster whose parts are both ASCII — and its bytes are two, so the rule
    // below would skip it. A Windows, web or Git-for-Windows clipboard would then lose every line
    // break and arrive as one long line, silently. A lone `\r` or `\n` already maps to Return; only
    // the pair needs this.
    let normalized = if text.contains("\r\n") {
        Cow::Owned(text.replace("\r\n", "\n"))
    } else {
        Cow::Borrowed(text)
    };

    let mut strokes = Vec::new();
    let mut skipped = 0_usize;
    for (index, cluster) in normalized.graphemes(true).enumerate() {
        if index >= MAX_LENGTH {
            skipped = skipped.saturating_add(1);
            continue;
        }
        match stroke(cluster) {
            Some(press) => strokes.push(press),
            None => skipped = skipped.saturating_add(1),
        }
    }
    Encoded { strokes, skipped }
}

/// The stroke one grapheme CLUSTER types, or `None` when US-QWERTY has no key for it.
///
/// ⚠️ The single-byte test is the grapheme rule, not an ASCII shortcut. A `&str` is valid UTF-8, so
/// a one-byte cluster is an ASCII scalar standing alone — nothing combined onto it, nothing it
/// combined onto. Every longer cluster is refused whole: `"e\u{301}"`, `"😀"`, `"न्"` and `"\r\n"`
/// all fail here for the same reason and produce the same honest skip, where a per-scalar walk
/// would have typed the `e` out of the first one.
#[must_use]
pub fn stroke(cluster: &str) -> Option<Stroke> {
    match cluster.as_bytes() {
        [byte] => ascii_stroke(*byte),
        _ => None,
    }
}

/// The stroke one ASCII byte types.
const fn ascii_stroke(byte: u8) -> Option<Stroke> {
    match byte {
        // Letters share a key; case is Shift. The lower-case form is the lookup, so the table is
        // written once instead of twice.
        b'a'..=b'z' => {
            match letter_key(byte) {
                Some(key) => Some(Stroke::plain(key)),
                None => None,
            }
        },
        b'A'..=b'Z' => {
            match letter_key(byte.to_ascii_lowercase()) {
                Some(key) => Some(Stroke::shifted(key)),
                None => None,
            }
        },
        _ => symbol_stroke(byte),
    }
}

/// A lower-case letter's `kVK_ANSI_*` code.
///
/// A `match` and not a map: it is a fixed table of 26 entries read once per character of a paste,
/// and a `match` is the form a reviewer can check against `Carbon/HIToolbox/Events.h` by eye.
const fn letter_key(lower: u8) -> Option<u16> {
    Some(match lower {
        b'a' => 0,
        b'b' => 11,
        b'c' => 8,
        b'd' => 2,
        b'e' => 14,
        b'f' => 3,
        b'g' => 5,
        b'h' => 4,
        b'i' => 34,
        b'j' => 38,
        b'k' => 40,
        b'l' => 37,
        b'm' => 46,
        b'n' => 45,
        b'o' => 31,
        b'p' => 35,
        b'q' => 12,
        b'r' => 15,
        b's' => 1,
        b't' => 17,
        b'u' => 32,
        b'v' => 9,
        b'w' => 13,
        b'x' => 7,
        b'y' => 16,
        b'z' => 6,
        _ => return None,
    })
}

/// Digits, punctuation, their shifted symbols, and whitespace.
///
/// Each shifted symbol names the SAME key code as the character it shares a key with — `!` is
/// key 18 with Shift, exactly as `1` is key 18 without it — so the pair is written adjacently and
/// a transposition is visible rather than plausible.
const fn symbol_stroke(byte: u8) -> Option<Stroke> {
    Some(match byte {
        // The digit row, and the symbols that ride it.
        b'0' => Stroke::plain(29),
        b')' => Stroke::shifted(29),
        b'1' => Stroke::plain(18),
        b'!' => Stroke::shifted(18),
        b'2' => Stroke::plain(19),
        b'@' => Stroke::shifted(19),
        b'3' => Stroke::plain(20),
        b'#' => Stroke::shifted(20),
        b'4' => Stroke::plain(21),
        b'$' => Stroke::shifted(21),
        b'5' => Stroke::plain(23),
        b'%' => Stroke::shifted(23),
        b'6' => Stroke::plain(22),
        b'^' => Stroke::shifted(22),
        b'7' => Stroke::plain(26),
        b'&' => Stroke::shifted(26),
        b'8' => Stroke::plain(28),
        b'*' => Stroke::shifted(28),
        b'9' => Stroke::plain(25),
        b'(' => Stroke::shifted(25),
        // Punctuation, and the symbols that ride it.
        b'-' => Stroke::plain(27),
        b'_' => Stroke::shifted(27),
        b'=' => Stroke::plain(24),
        b'+' => Stroke::shifted(24),
        b'[' => Stroke::plain(33),
        b'{' => Stroke::shifted(33),
        b']' => Stroke::plain(30),
        b'}' => Stroke::shifted(30),
        b'\\' => Stroke::plain(42),
        b'|' => Stroke::shifted(42),
        b';' => Stroke::plain(41),
        b':' => Stroke::shifted(41),
        b'\'' => Stroke::plain(39),
        b'"' => Stroke::shifted(39),
        b',' => Stroke::plain(43),
        b'<' => Stroke::shifted(43),
        b'.' => Stroke::plain(47),
        b'>' => Stroke::shifted(47),
        b'/' => Stroke::plain(44),
        b'?' => Stroke::shifted(44),
        b'`' => Stroke::plain(50),
        b'~' => Stroke::shifted(50),
        // Whitespace. Both line endings are Return: a PTY takes one, and a field takes one.
        b' ' => Stroke::plain(49),
        b'\t' => Stroke::plain(48),
        b'\n' | b'\r' => Stroke::plain(36),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::{Encoded, MAX_LENGTH, Stroke, encode, stroke};

    /// One encode, as `(key_code, shift)` pairs — the shape a reader can check by eye.
    fn pairs(text: &str) -> (Vec<(u16, bool)>, usize) {
        let Encoded { strokes, skipped } = encode(text);
        (strokes.iter().map(|s| (s.key_code, s.shift)).collect(), skipped)
    }

    #[test]
    fn case_is_shift_on_one_shared_key() {
        assert_eq!(pairs("a"), (vec![(0, false)], 0));
        assert_eq!(pairs("A"), (vec![(0, true)], 0));
        assert_eq!(pairs("z"), (vec![(6, false)], 0));
        assert_eq!(pairs("Z"), (vec![(6, true)], 0));
    }

    #[test]
    fn a_shifted_symbol_names_the_key_it_shares() {
        for (plain, shifted) in [
            ("0", ")"),
            ("1", "!"),
            ("2", "@"),
            ("3", "#"),
            ("4", "$"),
            ("5", "%"),
            ("6", "^"),
            ("7", "&"),
            ("8", "*"),
            ("9", "("),
            ("-", "_"),
            ("=", "+"),
            ("[", "{"),
            ("]", "}"),
            ("\\", "|"),
            (";", ":"),
            ("'", "\""),
            (",", "<"),
            (".", ">"),
            ("/", "?"),
            ("`", "~"),
        ] {
            let (unshifted, _) = pairs(plain);
            let (held, _) = pairs(shifted);
            assert_eq!(unshifted.len(), 1, "{plain} is one stroke");
            assert_eq!(held.len(), 1, "{shifted} is one stroke");
            assert_eq!(
                unshifted.first().map(|pair| pair.0),
                held.first().map(|pair| pair.0),
                "{plain} and {shifted} ride the same key"
            );
            assert_eq!(unshifted.first().map(|pair| pair.1), Some(false), "{plain}");
            assert_eq!(held.first().map(|pair| pair.1), Some(true), "{shifted}");
        }
    }

    #[test]
    fn whitespace_types_space_tab_and_return() {
        assert_eq!(pairs(" "), (vec![(49, false)], 0));
        assert_eq!(pairs("\t"), (vec![(48, false)], 0));
        assert_eq!(pairs("\n"), (vec![(36, false)], 0));
        assert_eq!(pairs("\r"), (vec![(36, false)], 0));
    }

    /// The CRLF normalization, which is the difference between a multi-line paste and one line.
    #[test]
    fn a_windows_line_break_types_return_rather_than_vanishing() {
        let (strokes, skipped) = pairs("ab\r\ncd");
        assert_eq!(strokes, vec![
            (0, false),  // a
            (11, false), // b
            (36, false), // Return, from the pair
            (8, false),  // c
            (2, false),  // d
        ]);
        assert_eq!(skipped, 0, "the newline was typed, not dropped");
        // Without the normalization the pair reaches the cluster rule and is refused whole, which
        // is what makes the normalization load-bearing rather than tidy.
        assert_eq!(stroke("\r\n"), None);
    }

    /// ⚠️ The trap this module exists to not fall into: a decomposed accent must be skipped WHOLE,
    /// never typed as its ASCII base. A `chars()` walk answers `(vec![(14, false)], 1)` here — an
    /// `e` typed into a password field, and a skip count that looks like a rounding error.
    #[test]
    fn a_decomposed_accent_is_refused_whole_and_never_typed_as_its_base() {
        assert_eq!(stroke("e\u{301}"), None, "e + combining acute is one cluster");
        assert_eq!(pairs("e\u{301}"), (vec![], 1));
        assert_eq!(
            pairs("caf\u{65}\u{301}"),
            (vec![(8, false), (0, false), (3, false)], 1)
        );
        // The precomposed form reaches the same answer by the same rule — two bytes, not one.
        assert_eq!(pairs("caf\u{e9}"), (vec![(8, false), (0, false), (3, false)], 1));
    }

    #[test]
    fn emoji_and_other_scripts_are_skipped_and_counted() {
        assert_eq!(pairs("a\u{e9}\u{1f600}b"), (vec![(0, false), (11, false)], 2));
        // A ZWJ family is ONE cluster and therefore ONE skip, not five.
        assert_eq!(pairs("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}"), (vec![], 1));
    }

    #[test]
    fn a_realistic_password_maps_with_nothing_dropped() {
        let (strokes, skipped) = pairs("Tr0ub4dor&3");
        assert_eq!(skipped, 0);
        assert_eq!(strokes.len(), 11);
        assert_eq!(strokes.first(), Some(&(17, true)), "T is Shift+t");
        assert_eq!(strokes.last(), Some(&(20, false)), "3");
    }

    #[test]
    fn the_overflow_past_the_cap_counts_as_skipped() {
        let big = "a".repeat(MAX_LENGTH + 17);
        let encoded = encode(&big);
        assert_eq!(encoded.strokes.len(), MAX_LENGTH);
        assert_eq!(encoded.skipped, 17);
    }

    /// The cap counts CLUSTERS, so an alphabet that costs four bytes a letter is not punished for
    /// it — and neither is one that costs two.
    #[test]
    fn the_cap_counts_clusters_and_not_bytes() {
        let big = "\u{1f600}".repeat(MAX_LENGTH + 3);
        let encoded = encode(&big);
        assert!(encoded.strokes.is_empty(), "none of them map");
        assert_eq!(encoded.skipped, MAX_LENGTH + 3, "each emoji is one cluster");
    }

    #[test]
    fn an_empty_clipboard_is_no_strokes_and_no_skips() {
        assert_eq!(encode(""), Encoded::default());
    }

    /// Every printable ASCII character has a key. A gap here is a character a user would watch
    /// disappear out of a password with no explanation.
    #[test]
    fn every_printable_ascii_character_maps() {
        for byte in 0x20_u8..=0x7E {
            let text = String::from(char::from(byte));
            assert!(stroke(&text).is_some(), "{text:?} (0x{byte:02x}) has no key");
        }
    }

    /// A control character other than tab and the two line endings has no key, and must not
    /// accidentally collide with one that does.
    #[test]
    fn control_characters_other_than_tab_and_return_have_no_key() {
        for byte in 0x00_u8..0x20 {
            if matches!(byte, b'\t' | b'\n' | b'\r') {
                continue;
            }
            let text = String::from(char::from(byte));
            assert_eq!(stroke(&text), None, "0x{byte:02x} must not type anything");
        }
        assert_eq!(stroke("\u{7f}"), None, "DEL");
    }

    /// No two distinct characters may share a `(key, shift)` press — two that did would mean one of
    /// them types the other, which in a password field is unrecoverable and invisible.
    #[test]
    fn no_two_characters_type_the_same_press() {
        let mut seen: Vec<(Stroke, u8)> = Vec::new();
        for byte in 0x00_u8..=0x7F {
            // The two line endings are the ONE deliberate collision: both are Return.
            if matches!(byte, b'\r') {
                continue;
            }
            let text = String::from(char::from(byte));
            let Some(press) = stroke(&text) else { continue };
            assert!(
                !seen.iter().any(|(other, _)| *other == press),
                "0x{byte:02x} collides with {:?}",
                seen.iter().find(|(other, _)| *other == press)
            );
            seen.push((press, byte));
        }
    }
}
