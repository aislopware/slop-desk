//! PTY bytes as the plain text a pattern is matched against.
//!
//! The agent-control `wait --until` predicate runs a regex over a pane's output, and the `read`
//! verbs hand an agent that output as a string. Neither wants the escape sequences: a cursor move
//! between two words would break a pattern that spans them, and an `OSC 133` prompt mark is not
//! something an agent should have to know about.
//!
//! ## Not a replay pass
//!
//! [`crate::sanitize`]'s seven passes remove CHURN and keep a faithful terminal stream — colours
//! survive, because the client renders them. This removes EVERY sequence and keeps only text,
//! because a regex is not a terminal. So it lives beside them and shares their scanner, but it is
//! not one of them and `sanitize` does not call it.
//!
//! ## Two answers over one grammar
//!
//! [`strip`] renders a whole buffer. [`holdback_start`] answers where a buffer's trailing
//! INCOMPLETE sequence begins, so a caller feeding a chunk at a time can hold that tail back until
//! its continuation arrives rather than rendering half a sequence as text. They are one grammar
//! read two ways, and were previously two hand-rolled Swift machines whose doc comments promised
//! each other they matched.
//!
//! ## The terminator policy
//!
//! Unlike a replay pass, neither answer may run away: there is no next chunk to wait for once the
//! caller's budget is spent, so a malformed body ends at the bare `ESC` that broke it
//! ([`Terminators::lenient`]). `holdback_start` is the one place an unterminated body is still
//! undecidable — that is exactly what it reports.

// A VT scanner is a byte cursor, and `bytes[i]` is bounded by the `while` head that let control
// reach it — `i < n` is the check, tested once per step rather than re-asked at every read. The
// `get(i)` rewrite would replace one panic that cannot fire with a silent `None` arm that swallows
// a real off-by-one, so the opt-out is per scanner file and stops at its edge.
#![expect(clippy::indexing_slicing, reason = "the loop head bounds every cursor read")]

use crate::vtscan::{ESC, Terminators, parse_csi, string_sequence_end};

/// `CSI` as its 8-bit C1 byte, which only a true 8-bit stream carries.
const C1_CSI: u8 = 0x9B;
/// `OSC` as its 8-bit C1 byte.
const C1_OSC: u8 = 0x9D;

/// The private-use ranges a Nerd Font or a Powerline theme draws its glyphs from — the ONE
/// spelling.
///
/// They are valid UTF-8 and a byte scanner passes them through, but they are decoration: one
/// visible glyph that makes an agent's reading of the output unclean. So the sanitizer drops them,
/// and the chrome — which has the opposite job, splicing the bundled face in over exactly these
/// runs — reads the same table through [`private_use_ranges`] rather than typing it again.
///
/// ⚠️ IT WAS TYPED TWICE, AND THE TWO DISAGREED. `Sources/SlopDeskFontFaces/NerdSymbolFont.swift`
/// carried the correct three ranges while this carried two, wrong at both ends:
///
/// * **Plane 16 was missing entirely** (`U+100000–U+10FFFD`, Supplementary Private Use Area-B). The
///   material-design icon set lives up there, so a title carrying one reached an agent as a glyph
///   the strip exists to remove — the exact failure, in the plane nobody checked.
/// * **The plane-15 end ran two codepoints too far.** `U+FFFFE` and `U+FFFFF` are NONCHARACTERS,
///   permanently reserved and never private use; a supplementary plane's private-use block stops at
///   `…FFFD`. Stripping them is harmless in practice and wrong in principle, and the principle is
///   what a second copy of a table gets wrong first.
///
/// Neither side was reachable from the other, so neither had a test that could have said so. This
/// is the shape `CLAUDE.md`'s "one implementation, never two languages" names: not two behaviours
/// that drifted, but one FACT about Unicode written down twice.
const PRIVATE_USE: [(u32, u32); 3] = [(0xE000, 0xF8FF), (0xF_0000, 0xF_FFFD), (0x10_0000, 0x10_FFFD)];

/// The private-use ranges, as inclusive `(low, high)` pairs.
///
/// Handed out rather than re-typed: the chrome's splice and this strip are opposite operations over
/// the same set, and a set spelled on both sides of a door is the drift the door exists to remove.
/// The caller reads this ONCE and keeps the table — the classification is per-scalar on a title
/// redrawn every keystroke, which is not a rate anything should cross a boundary at.
#[must_use]
pub const fn private_use_ranges() -> &'static [(u32, u32)] {
    &PRIVATE_USE
}

/// `bytes` with every escape sequence and private-use glyph removed.
///
/// Multi-byte UTF-8 passes through whole: the leading byte's length is read first, so a `0x9B` or
/// `0x9C` that is a CONTINUATION byte can never be mistaken for the C1 introducer it looks like.
/// That is the one subtlety the two Swift machines each got right separately.
#[must_use]
pub fn strip(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if let Some(width) = utf8_width(byte) {
            let end = bytes.len().min(index + width);
            copy_codepoint(&mut out, &bytes[index..end]);
            index = end;
            continue;
        }
        if is_plain(byte) {
            // The common case is a run of ASCII between two sequences; it is copied as one slice
            // rather than a byte at a time, and a plain byte introduces nothing, so the run cannot
            // hide a sequence start.
            let end = bytes[index..]
                .iter()
                .position(|&candidate| !is_plain(candidate))
                .map_or(bytes.len(), |offset| index + offset);
            out.extend_from_slice(&bytes[index..end]);
            index = end;
            continue;
        }
        if let Some(end) = sequence_end(bytes, index) {
            index = end;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    out
}

/// Whether a byte is copied through untouched wherever it appears: not a multi-byte lead, and not
/// one of the three bytes [`introducer`] reads as the start of a sequence.
///
/// Every other byte — a continuation with no lead, an invalid lead, a C0 control — is passed
/// through as well, but one at a time by the loop above, exactly as before this fast path existed.
const fn is_plain(byte: u8) -> bool {
    !matches!(byte, ESC | C1_CSI | C1_OSC) && utf8_width(byte).is_none()
}

/// The index from which the tail of `bytes` must be HELD BACK into the next chunk.
///
/// A trailing escape sequence that has not terminated yet, or a trailing truncated multi-byte
/// codepoint: either can only be rendered once its continuation arrives, and rendering it now would
/// put half a sequence into the text a pattern is matched against. `bytes.len()` means nothing is
/// held.
#[must_use]
pub fn holdback_start(bytes: &[u8]) -> usize {
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if let Some(width) = utf8_width(byte) {
            if index + width > bytes.len() {
                return index;
            }
            index += width;
            continue;
        }
        match complete_sequence_end(bytes, index) {
            Ok(Some(end)) => index = end,
            // Not a sequence at all: ordinary text, which is always ready.
            Ok(None) => index += 1,
            // A sequence whose continuation has not arrived. Everything from here waits.
            Err(()) => return index,
        }
    }
    bytes.len()
}

/// How many bytes the codepoint led by `byte` occupies, or `None` when it leads nothing.
///
/// `0xC0`/`0xC1` are the overlong leads, which are never valid, and `0x80..=0xBF` are continuations
/// that a caller only reaches when a lead was already consumed — both fall through to the sequence
/// scanner, which passes them along as the raw bytes they are.
const fn utf8_width(byte: u8) -> Option<usize> {
    match byte {
        0xC2..=0xDF => Some(2),
        0xE0..=0xEF => Some(3),
        0xF0..=0xF7 => Some(4),
        _ => None,
    }
}

/// Appends one whole codepoint, unless it is a private-use glyph.
fn copy_codepoint(out: &mut Vec<u8>, codepoint: &[u8]) {
    if let Ok(text) = core::str::from_utf8(codepoint)
        && text.chars().any(private_use)
    {
        return;
    }
    out.extend_from_slice(codepoint);
}

/// Whether a character is drawn from a private-use plane.
fn private_use(character: char) -> bool {
    let value = u32::from(character);
    PRIVATE_USE
        .iter()
        .any(|&(low, high)| value >= low && value <= high)
}

/// The index just past the sequence introduced at `start`, or `None` when nothing is.
///
/// Lenient throughout: a body that never terminates ends at the buffer, because this answer is
/// rendered now and there is no later chunk to revise it with.
fn sequence_end(bytes: &[u8], start: usize) -> Option<usize> {
    let Some(introduced) = introducer(bytes, start) else {
        // A trailing lone ESC introduces something whose name never arrived. It is consumed rather
        // than emitted: half a sequence is not text, and there is no next chunk to complete it.
        return (bytes[start] == ESC).then_some(bytes.len());
    };
    match introduced {
        Introduced::Csi { body } => Some(csi_end(bytes, body)),
        Introduced::String { body } => {
            Some(
                string_sequence_end(bytes, body, Terminators::lenient())
                    .map_or(bytes.len(), |sequence| sequence.seq_end),
            )
        },
        Introduced::Charset { designator } => Some(bytes.len().min(designator + 1)),
        Introduced::Escaped { end } => Some(end),
    }
}

/// The index just past a COMPLETE sequence at `start`, `Ok(None)` when nothing is introduced, and
/// `Err` when a sequence is introduced but its end has not arrived yet.
fn complete_sequence_end(bytes: &[u8], start: usize) -> Result<Option<usize>, ()> {
    let Some(introduced) = introducer(bytes, start) else {
        // A lone trailing ESC is undecidable: the next byte names the sequence.
        return if bytes[start] == ESC { Err(()) } else { Ok(None) };
    };
    match introduced {
        Introduced::Csi { body } => complete_csi_end(bytes, body).map(Some).ok_or(()),
        Introduced::String { body } => {
            string_sequence_end(bytes, body, Terminators::lenient())
            // A trailing lone ESC inside a body is undecidable too — it may be the first byte of
            // an `ST` whose backslash has not arrived.
            .filter(|sequence| sequence.seq_end <= bytes.len() && !cut_escape(bytes, *sequence))
            .map(|sequence| Some(sequence.seq_end))
            .ok_or(())
        },
        Introduced::Charset { designator } => {
            if designator < bytes.len() {
                Ok(Some(designator + 1))
            } else {
                Err(())
            }
        },
        Introduced::Escaped { end } => Ok(Some(end)),
    }
}

/// Whether a lenient terminator landed on a trailing `ESC` that may yet become an `ST`.
fn cut_escape(bytes: &[u8], sequence: crate::vtscan::StringSequence) -> bool {
    bytes.get(sequence.body_end) == Some(&ESC) && sequence.seq_end == bytes.len()
}

/// What the byte at `start` introduces.
enum Introduced {
    /// A `CSI`, whose parameter run begins at `body`.
    Csi { body: usize },
    /// An `OSC`/`DCS`/`SOS`/`PM`/`APC`, whose body begins at `body`.
    String { body: usize },
    /// A charset designation, whose one designator byte sits at `designator`.
    Charset { designator: usize },
    /// A two-byte escape, already complete, ending at `end`.
    Escaped { end: usize },
}

/// What the byte at `start` introduces, or `None` when it is text.
fn introducer(bytes: &[u8], start: usize) -> Option<Introduced> {
    match bytes[start] {
        C1_CSI => return Some(Introduced::Csi { body: start + 1 }),
        C1_OSC => return Some(Introduced::String { body: start + 1 }),
        ESC => {},
        _ => return None,
    }

    match *bytes.get(start + 1)? {
        b'[' => Some(Introduced::Csi { body: start + 2 }),
        // `ESC ( ) * +` designate a character set into G0..G3 and take ONE designator byte. Every
        // zsh theme emits `ESC ( B`, so a two-byte skip here leaves a stray `B` in the text.
        b'(' | b')' | b'*' | b'+' => {
            Some(Introduced::Charset {
                designator: start + 2,
            })
        },
        byte => {
            match crate::vtscan::string_introducer(byte) {
                Some(_) => Some(Introduced::String { body: start + 2 }),
                None => Some(Introduced::Escaped { end: start + 2 }),
            }
        },
    }
}

/// The index just past a `CSI` body, ending at the buffer when no final byte arrived.
///
/// A byte that is neither a parameter, an intermediate nor a final ends the sequence
/// malformed-but-consumed, so one corrupt `CSI` cannot swallow the rest of the output.
fn csi_end(bytes: &[u8], body: usize) -> usize {
    let mut index = body;
    while index < bytes.len() && (0x30..=0x3F).contains(&bytes[index]) {
        index += 1;
    }
    while index < bytes.len() && (0x20..=0x2F).contains(&bytes[index]) {
        index += 1;
    }
    match bytes.get(index) {
        Some(&byte) if (0x40..=0x7E).contains(&byte) => index + 1,
        _ => index,
    }
}

/// The index just past a COMPLETE `CSI`, or `None` when its final byte has not arrived.
///
/// The parse is [`parse_csi`]'s, one byte earlier than its introducer because this walks a body a
/// C1 `CSI` can open too; a body that ended malformed is complete, because no continuation makes it
/// a `CSI` again.
fn complete_csi_end(bytes: &[u8], body: usize) -> Option<usize> {
    let end = csi_end(bytes, body);
    if end < bytes.len() {
        return Some(end);
    }
    // The body ran to the buffer's end. It is complete only if a final byte was the last thing in
    // it — which `parse_csi` decides, given the introducer it expects two bytes before the body.
    let start = body.checked_sub(2)?;
    parse_csi(bytes, start).map(|csi| csi.end)
}

#[cfg(test)]
mod tests {
    use super::{copy_codepoint, holdback_start, sequence_end, strip, utf8_width};

    /// The loop `strip` ran before the plain-run fast path: one byte at a time, no slice copy.
    /// Kept as the oracle the fast path is measured against — over a byte soup that mixes runs,
    /// every introducer, truncated leads and private-use glyphs, the two must agree byte for byte.
    fn strip_one_byte_at_a_time(bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(bytes.len());
        let mut index = 0;
        while index < bytes.len() {
            let byte = bytes[index];
            if let Some(width) = utf8_width(byte) {
                let end = bytes.len().min(index + width);
                copy_codepoint(&mut out, &bytes[index..end]);
                index = end;
                continue;
            }
            if let Some(end) = sequence_end(bytes, index) {
                index = end;
            } else {
                out.push(byte);
                index += 1;
            }
        }
        out
    }

    #[test]
    fn the_plain_run_fast_path_matches_the_byte_loop_over_a_byte_soup() {
        // A deterministic generator, so a failure names its seed rather than a moment.
        let mut state = 0x9E37_79B9_7F4A_7C15_u64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        let alphabet: [&[u8]; 12] = [
            b"plain text ",
            b"\x1b[31m",
            b"\x1b]0;title\x07",
            b"\x9b1;2H",
            b"\x9dmalformed",
            b"\x1b(B",
            b"\xe6\xbc\xa2",
            b"\xee\x80\x80",
            b"\xc2",
            b"\x80\xff",
            b"\r\n\t\x07",
            b"\x1b",
        ];
        for round in 0..256_u32 {
            let mut soup = Vec::new();
            for _ in 0..64 {
                let pick = usize::try_from(next() % 12).unwrap_or_default();
                soup.extend_from_slice(alphabet[pick]);
            }
            assert_eq!(
                strip(&soup),
                strip_one_byte_at_a_time(&soup),
                "round {round}: {soup:?}"
            );
        }
    }

    /// The stripped text of an input written the way a terminal writes it. Empty for an answer that
    /// is not whole UTF-8, which is a failure the assertions report rather than a panic.
    fn text(bytes: &[u8]) -> String {
        String::from_utf8(strip(bytes)).unwrap_or_default()
    }

    #[test]
    fn plain_text_is_its_own_answer() {
        assert_eq!(text(b"hello world"), "hello world");
        assert_eq!(text("nghiêng quá\n".as_bytes()), "nghiêng quá\n");
        assert_eq!(text(b""), "");
    }

    #[test]
    fn every_sequence_shape_is_removed_and_the_text_around_it_survives() {
        assert_eq!(text(b"\x1b[31mfoo\x1b[0m"), "foo", "a CSI, colour and all");
        assert_eq!(text(b"a\x1b]0;title\x07b"), "ab", "an OSC ended by BEL");
        assert_eq!(text(b"a\x1b]0;title\x1b\\b"), "ab", "and by ST");
        assert_eq!(text(b"a\x1bP+q544e\x1b\\b"), "ab", "a DCS body is opaque");
        assert_eq!(
            text(b"a\x1b(B\x1b)0b"),
            "ab",
            "a charset designator takes its byte with it"
        );
        assert_eq!(text(b"a\x1b=b"), "ab", "and a two-byte escape is two bytes");
    }

    #[test]
    fn a_c1_introducer_is_read_only_in_a_stream_that_has_one() {
        assert_eq!(text(b"a\x9b31mb"), "ab", "a raw 8-bit CSI");
        assert_eq!(text(b"a\x9d0;t\x07b"), "ab", "and a raw 8-bit OSC");
        assert_eq!(
            text("a\u{9b}b".as_bytes()),
            "a\u{9b}b",
            "but U+009B in UTF-8 is two bytes the codepoint walk consumes whole"
        );
    }

    #[test]
    fn a_malformed_body_ends_rather_than_swallowing_the_output() {
        assert_eq!(
            text(b"\x1b]0;title\x1bXtail"),
            "Xtail",
            "a bare ESC ends the body, and only the ESC is consumed with it"
        );
        assert_eq!(
            text(b"\x1b[31\ndone"),
            "\ndone",
            "and so does a byte no CSI grammar allows, which stays as the text it is"
        );
        assert_eq!(
            text(b"before\x1b]0;never ends"),
            "before",
            "an unterminated body eats its tail"
        );
        assert_eq!(
            text(b"hello\x1b"),
            "hello",
            "and a trailing lone ESC is not text either"
        );
    }

    #[test]
    fn private_use_glyphs_go_and_ordinary_symbols_stay() {
        assert_eq!(
            text("\u{e0b0} branch".as_bytes()),
            " branch",
            "a Powerline separator"
        );
        assert_eq!(
            text("\u{f0001}x".as_bytes()),
            "x",
            "and a supplementary-plane icon"
        );
        assert_eq!(text("→ ✓".as_bytes()), "→ ✓", "arrows and ticks are text");
    }

    #[test]
    fn a_whole_buffer_holds_nothing_back() {
        assert_eq!(holdback_start(b"hello"), 5);
        assert_eq!(holdback_start(b"\x1b[31mred"), 8);
        assert_eq!(holdback_start(b"\x1b]0;t\x07"), 6);
        assert_eq!(holdback_start("é".as_bytes()), 2);
        assert_eq!(holdback_start(b""), 0);
    }

    #[test]
    fn a_cut_sequence_is_held_back_from_where_it_starts() {
        assert_eq!(holdback_start(b"ok\x1b"), 2, "a lone ESC names nothing yet");
        assert_eq!(holdback_start(b"ok\x1b[31"), 2, "a CSI with no final byte");
        assert_eq!(holdback_start(b"ok\x1b]0;title"), 2, "an OSC with no terminator");
        assert_eq!(
            holdback_start(b"ok\x1b]0;t\x1b"),
            2,
            "an ESC that may yet become ST"
        );
        assert_eq!(holdback_start(b"ok\x1b("), 2, "a designator that has not arrived");
        assert_eq!(holdback_start(b"ok\x9b31"), 2, "and an 8-bit CSI, the same way");
    }

    #[test]
    fn a_cut_codepoint_is_held_back_whole() {
        let two = "é".as_bytes();
        assert_eq!(holdback_start(&two[..1]), 0, "a lead with no continuation");
        let four = "🙂".as_bytes();
        assert_eq!(holdback_start(&four[..3]), 0);
        assert_eq!(
            holdback_start(b"ok\xf0\x9f"),
            2,
            "and the text before it is ready"
        );
    }

    #[test]
    fn the_two_answers_agree_about_where_a_sequence_ends() {
        // Everything a whole buffer holds back nothing of must strip to the same text whether it
        // arrives at once or one byte at a time — which is the promise the two Swift machines made
        // to each other in a doc comment.
        let stream = b"\x1b[1mbold\x1b[0m \x1b]0;title\x07done\x1b(B\xc3\xa9";
        let whole = strip(stream);
        let mut fed = Vec::new();
        let mut carry: Vec<u8> = Vec::new();
        for byte in stream {
            carry.push(*byte);
            let cut = holdback_start(&carry);
            fed.extend_from_slice(&strip(&carry[..cut]));
            carry.drain(..cut);
        }
        fed.extend_from_slice(&strip(&carry));
        assert_eq!(fed, whole, "byte at a time renders what the whole buffer does");
    }

    /// Every BOUNDARY of the private-use table, from both sides.
    ///
    /// A range table is wrong at its ends or not at all, and both ends is exactly what the second
    /// copy of this table got wrong — so the cases are the four edges of each range plus the
    /// noncharacters that used to be swept in. Written as `char` LITERALS rather than as a loop
    /// over `PRIVATE_USE`, because a loop over the table would be the table checking itself; the
    /// compiler validates each escape, so there is no fallible conversion to unwrap either.
    #[test]
    fn the_private_use_table_is_right_at_every_edge() {
        for character in [
            '\u{E000}',
            '\u{F8FF}', // the BMP block
            '\u{F0000}',
            '\u{FFFFD}', // plane 15
            '\u{100000}',
            '\u{10FFFD}', // plane 16 — the one the second copy was missing entirely
        ] {
            assert!(
                super::private_use(character),
                "U+{:04X} is private use and must strip",
                u32::from(character),
            );
        }
        // `U+DFFF`, the scalar directly below the BMP block, is a SURROGATE and not a `char` at
        // all — unreachable through this scanner, since a surrogate cannot survive UTF-8 decoding.
        // `U+D7FF` is the nearest codepoint below it that a stream can actually carry.
        for character in [
            '\u{D7FF}',
            '\u{F900}', // below and above the BMP block
            '\u{EFFFF}',
            '\u{10000}', // below plane 15's start, and a plain supplementary char
        ] {
            assert!(
                !super::private_use(character),
                "U+{:04X} is outside every private-use range and must survive",
                u32::from(character),
            );
        }
        // ⚠️ NONCHARACTERS, not private use. `U+FFFFE`/`U+FFFFF` and `U+10FFFE`/`U+10FFFF` are
        // permanently reserved; the old table's `…FFFF` upper bound swept the first pair in.
        for character in ['\u{FFFFE}', '\u{FFFFF}', '\u{10FFFE}', '\u{10FFFF}'] {
            assert!(
                !super::private_use(character),
                "U+{:04X} is a noncharacter, not private use",
                u32::from(character),
            );
        }
    }

    /// The table is handed out, so a caller cannot be reading a different one.
    #[test]
    fn the_ranges_handed_out_are_the_ranges_used() {
        let handed = super::private_use_ranges();
        assert_eq!(handed.len(), 3, "the BMP block plus planes 15 and 16");
        for &(low, high) in handed {
            assert!(low <= high, "a range runs upward");
            for scalar in [low, high] {
                // Both halves in one claim: a bound that is not a `char` (a surrogate, or past
                // `U+10FFFF`) fails here exactly as a bound the strip disagrees with would.
                assert!(
                    char::from_u32(scalar).is_some_and(super::private_use),
                    "U+{scalar:04X} is a bound of a handed-out range, so the strip must agree",
                );
            }
        }
    }

    /// The whole point of the fix, end to end: a plane-16 glyph in a stream now goes.
    #[test]
    fn a_plane_16_glyph_strips_like_every_other_private_use_one() {
        let mut stream = b"repo ".to_vec();
        stream.extend_from_slice('\u{100000}'.to_string().as_bytes());
        stream.extend_from_slice(b" ok");
        assert_eq!(strip(&stream), b"repo  ok");
    }
}
