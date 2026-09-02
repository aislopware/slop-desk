//! The escape-sequence skimmer the replay-hygiene passes share.
//!
//! Every pass in [`crate::sanitize`] walks the same stream the same way: find `ESC`, decide what
//! kind of sequence it introduces, and skip to its end without interpreting the body. The Swift
//! originals hand-rolled this four times over — a deliberate "mirror, don't share" convention for
//! small VT machines in a language where sharing them meant a cross-file dependency for thirty
//! lines. Inside one Rust module there is no such trade: it is one implementation, and a bug in the
//! CSI parameter ranges is fixable in one place instead of four.
//!
//! Nothing here interprets a sequence. It answers only "where does this end", which is what makes
//! it safe to share between a pass that DROPS queries and one that COUNTS alt-screen segments.

// A VT scanner is a byte cursor, and `bytes[i]` is bounded by the `while` head that let control
// reach it — `i < n` is the check, tested once per step rather than re-asked at every read. The
// `get(i)` rewrite would replace one panic that cannot fire with a silent `None` arm that swallows
// a real off-by-one, so the opt-out is per scanner file and stops at its edge.
#![expect(clippy::indexing_slicing, reason = "the loop head bounds every cursor read")]

/// The escape introducer.
pub const ESC: u8 = 0x1B;
/// `BEL`, which terminates an `OSC` (but not a `DCS`/`SOS`/`PM`/`APC`).
pub const BEL: u8 = 0x07;
/// The 8-bit `ST`, which only a true 8-bit stream carries — in UTF-8 this byte is a continuation.
pub const C1_ST: u8 = 0x9C;
/// `CAN`, which aborts any escape or control string mid-body (VT500, and ghostty follows it).
pub const CAN: u8 = 0x18;
/// `SUB`, which aborts a string body exactly as `CAN` does.
pub const SUB: u8 = 0x1A;
/// Carriage return.
pub const CR: u8 = 0x0D;
/// Line feed.
pub const LF: u8 = 0x0A;

/// One parsed `CSI`, borrowing the scanned buffer.
///
/// The parameter and intermediate ranges are the ECMA-48 ones: parameters are `0x30..=0x3F`
/// (digits, `;`, `:`, `<`, `=`, `>`, `?`), intermediates `0x20..=0x2F`, and the final byte
/// `0x40..=0x7E`. Slices rather than owned buffers because `SGR` (`m`) dominates every real stream
/// and must not allocate.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Csi<'a> {
    /// `0x30..=0x3F` — digits, `;`, `:`, and the private markers `<`, `=`, `>`, `?`.
    pub params: &'a [u8],
    /// `0x20..=0x2F`, e.g. the `$` of `DECRQM` or the space of `DECSCUSR`.
    pub intermediates: &'a [u8],
    /// `0x40..=0x7E`.
    pub final_byte: u8,
    /// Index just past the final byte.
    pub end: usize,
}

/// Parses the `CSI` introduced at `start` (which must hold `ESC` `[`).
///
/// `None` when the buffer ends before a final byte — a ring head-cut artifact, which every caller
/// passes through verbatim rather than guessing at.
#[must_use]
pub fn parse_csi(bytes: &[u8], start: usize) -> Option<Csi<'_>> {
    let mut j = start.checked_add(2)?;
    let params_start = j;
    while j < bytes.len() && (0x30..=0x3F).contains(&bytes[j]) {
        j += 1;
    }
    let inters_start = j;
    while j < bytes.len() && (0x20..=0x2F).contains(&bytes[j]) {
        j += 1;
    }
    let final_byte = *bytes.get(j)?;
    if !(0x40..=0x7E).contains(&final_byte) {
        return None;
    }
    Some(Csi {
        params: bytes.get(params_start..inters_start)?,
        intermediates: bytes.get(inters_start..j)?,
        final_byte,
        end: j + 1,
    })
}

/// Where a string sequence's body and the sequence itself end.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct StringSequence {
    /// Index just past the last body byte (exclusive of the terminator).
    pub body_end: usize,
    /// Index just past the terminator — or AT the `CAN`/`SUB` that aborted the body, which is left
    /// for the outer scanner to read as the plain C0 byte it is.
    pub seq_end: usize,
}

/// Which bytes end a string sequence, for a caller that has a reason to differ.
///
/// `ESC \\` always terminates, and `CAN`/`SUB` always abort (see [`string_sequence_end`]). The rest
/// is a policy, and two callers want opposite things for the same right reason. A replay-hygiene
/// pass reads a stream it may have cut mid-sequence, so an unterminated body is a HEAD-CUT
/// ARTIFACT it passes through verbatim rather than guessing at. A pass that renders text for
/// matching has no next chunk to wait for, so it must treat a malformed body as ended rather than
/// swallow the rest of the output.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Terminators {
    /// Whether `BEL` ends the body. True for `OSC`, false for `DCS`/`SOS`/`PM`/`APC`.
    pub bel: bool,
    /// Whether the 8-bit `ST` (`0x9C`) ends it. Only a caller reading a true 8-bit stream should
    /// say yes: in UTF-8 that byte is a continuation, and a pass that walks codepoints has already
    /// consumed it.
    pub c1_st: bool,
    /// Whether an `ESC` NOT followed by `\\` ends it, malformed. The runaway guard: without it, one
    /// corrupt introducer swallows every byte after it.
    pub bare_esc: bool,
}

impl Terminators {
    /// An `OSC` body as a replay pass reads it: `BEL` or `ST`, and unterminated means unterminated.
    #[must_use]
    pub const fn osc() -> Self {
        Self {
            bel: true,
            c1_st: false,
            bare_esc: false,
        }
    }

    /// A `DCS`/`SOS`/`PM`/`APC` body as a replay pass reads it: `ST` only.
    #[must_use]
    pub const fn st_only() -> Self {
        Self {
            bel: false,
            c1_st: false,
            bare_esc: false,
        }
    }

    /// The whole terminator set, for a caller that cannot wait for a continuation.
    #[must_use]
    pub const fn lenient() -> Self {
        Self {
            bel: true,
            c1_st: true,
            bare_esc: true,
        }
    }

    /// The replay policy for an introducer, given whether `BEL` ends it.
    #[must_use]
    pub const fn replay(bel_terminates: bool) -> Self {
        if bel_terminates {
            Self::osc()
        } else {
            Self::st_only()
        }
    }
}

/// Scans a string sequence's body from `body_start` to its terminator.
///
/// `None` when the buffer ends before any terminator in the policy — which for a replay pass is a
/// head-cut artifact rather than a decision, and for a lenient caller cannot happen unless the body
/// runs to the very end of the buffer.
///
/// `CAN` and `SUB` abort the body under EVERY policy, as the VT500 state machine has them do: the
/// terminal the stream is replayed into stops reading the string there, so a scanner that kept
/// going would hand a `;rgb:…` reply back as text and the terminal would not. The aborting byte is
/// not consumed — `seq_end == body_end` — so the outer scanner sees it as a plain C0.
#[must_use]
pub fn string_sequence_end(
    bytes: &[u8],
    body_start: usize,
    terminators: Terminators,
) -> Option<StringSequence> {
    let mut j = body_start;
    while j < bytes.len() {
        let byte = bytes[j];
        if byte == CAN || byte == SUB {
            return Some(StringSequence {
                body_end: j,
                seq_end: j,
            });
        }
        if (terminators.bel && byte == BEL) || (terminators.c1_st && byte == C1_ST) {
            return Some(StringSequence {
                body_end: j,
                seq_end: j + 1,
            });
        }
        if byte == ESC {
            if bytes.get(j + 1) == Some(&b'\\') {
                return Some(StringSequence {
                    body_end: j,
                    seq_end: j + 2,
                });
            }
            if terminators.bare_esc {
                // Malformed, and ended: the ESC itself is consumed, whatever followed it is text.
                return Some(StringSequence {
                    body_end: j,
                    seq_end: j + 1,
                });
            }
        }
        j += 1;
    }
    None
}

/// Whether `byte` introduces a string sequence whose body must be skipped opaquely, and whether
/// `BEL` terminates it.
///
/// An embedded `ESC ] 133 ; …` inside a `DCS` body must never be read as a prompt mark, and an
/// embedded `?1049l` must never close an alt-screen segment — which is the whole reason every pass
/// skips these bodies without looking inside.
#[must_use]
pub const fn string_introducer(byte: u8) -> Option<bool> {
    match byte {
        b']' => Some(true),                       // OSC — BEL or ST
        b'P' | b'X' | b'^' | b'_' => Some(false), // DCS / SOS / PM / APC — ST only
        _ => None,
    }
}

/// The `CSI`'s numeric parameter fields.
///
/// `private_marker` says whether a leading `?` should be dropped before splitting. Two callers want
/// different things and both are right: the alt-screen pass only ever inspects private modes, while
/// the sync-frame pass also reads plain `CSI 2 J`, where the first byte is a digit and dropping it
/// would read `2` as nothing. Non-numeric fields are skipped, matching the Swift
/// `compactMap(Int.init)`.
#[must_use]
pub fn param_fields(csi: &Csi<'_>, private_marker: PrivateMarker) -> Vec<i64> {
    let params = match private_marker {
        PrivateMarker::AlwaysDropFirst => csi.params.get(1..).unwrap_or_default(),
        PrivateMarker::DropWhenPresent => {
            if csi.params.first() == Some(&b'?') {
                csi.params.get(1..).unwrap_or_default()
            } else {
                csi.params
            }
        },
    };
    params
        .split(|&b| b == b';')
        .filter_map(|field| std::str::from_utf8(field).ok()?.parse::<i64>().ok())
        .collect()
}

/// How [`param_fields`] should treat the leading byte.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrivateMarker {
    /// The caller has already established the `CSI` is private (`?`-led) — drop the first byte.
    AlwaysDropFirst,
    /// The `CSI` may or may not be private — drop a `?` if there is one, otherwise keep everything.
    DropWhenPresent,
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::{
        Csi, PrivateMarker, Terminators, param_fields, parse_csi, string_introducer, string_sequence_end,
    };

    #[test]
    fn a_csi_splits_into_params_intermediates_and_final() {
        let bytes = b"\x1b[?2026$p rest";
        let csi = parse_csi(bytes, 0).expect("parses");
        assert_eq!(csi.params, b"?2026");
        assert_eq!(csi.intermediates, b"$");
        assert_eq!(csi.final_byte, b'p');
        assert_eq!(csi.end, 9, "one past the final byte");
    }

    #[test]
    fn a_csi_with_no_final_byte_is_none_rather_than_a_guess() {
        // A ring head-cut mid-sequence: every caller passes these through verbatim.
        assert_eq!(parse_csi(b"\x1b[?2026", 0), None);
        assert_eq!(parse_csi(b"\x1b[", 0), None);
        // A byte outside the final range where a final belongs.
        assert_eq!(parse_csi(b"\x1b[1\x7f", 0), None);
    }

    #[test]
    fn a_bare_csi_has_empty_params_and_intermediates() {
        let csi = parse_csi(b"\x1b[m", 0).expect("parses");
        assert_eq!(csi, Csi {
            params: b"",
            intermediates: b"",
            final_byte: b'm',
            end: 3,
        });
    }

    #[test]
    fn an_osc_ends_at_bel_or_st_and_a_dcs_only_at_st() {
        let osc =
            string_sequence_end(b"\x1b]0;title\x07tail", 2, Terminators::osc()).expect("bel terminates");
        assert_eq!(osc.body_end, 9);
        assert_eq!(osc.seq_end, 10);

        let st =
            string_sequence_end(b"\x1b]0;title\x1b\\tail", 2, Terminators::osc()).expect("st terminates");
        assert_eq!(st.body_end, 9);
        assert_eq!(st.seq_end, 11);

        // In a DCS the BEL is an ordinary body byte.
        let dcs = string_sequence_end(b"\x1bP+q\x07more\x1b\\", 2, Terminators::st_only()).expect("st only");
        assert_eq!(dcs.seq_end, 11);
    }

    #[test]
    fn can_and_sub_abort_a_string_body_under_every_policy_without_being_consumed() {
        let reply = b"\x1b]11\x18;rgb:1111/2222/3333\x07";
        for policy in [Terminators::osc(), Terminators::st_only(), Terminators::lenient()] {
            let aborted = string_sequence_end(reply, 2, policy).expect("CAN aborts");
            assert_eq!(aborted.body_end, 4, "the body stops at the CAN");
            assert_eq!(aborted.seq_end, 4, "the CAN is left for the outer scanner");
        }
        let sub =
            string_sequence_end(b"\x1bP+q\x1amore\x1b\\", 2, Terminators::st_only()).expect("SUB aborts");
        assert_eq!((sub.body_end, sub.seq_end), (4, 4));
    }

    #[test]
    fn an_unterminated_string_sequence_is_none() {
        assert_eq!(string_sequence_end(b"\x1b]0;never", 2, Terminators::osc()), None);
    }

    #[test]
    fn the_string_introducers_are_the_five_that_carry_opaque_bodies() {
        assert_eq!(string_introducer(b']'), Some(true));
        for byte in *b"PX^_" {
            assert_eq!(string_introducer(byte), Some(false));
        }
        assert_eq!(string_introducer(b'['), None);
        assert_eq!(string_introducer(b'D'), None);
    }

    /// The two marker policies exist because `CSI 2 J` and `CSI ? 1049 h` both need reading, and a
    /// single rule gets one of them wrong.
    #[test]
    fn the_param_marker_policy_decides_whether_a_leading_digit_survives() {
        let private = parse_csi(b"\x1b[?1049;12h", 0).expect("parses");
        assert_eq!(param_fields(&private, PrivateMarker::AlwaysDropFirst), vec![
            1049, 12
        ]);
        assert_eq!(param_fields(&private, PrivateMarker::DropWhenPresent), vec![
            1049, 12
        ]);

        let plain = parse_csi(b"\x1b[2J", 0).expect("parses");
        assert_eq!(param_fields(&plain, PrivateMarker::DropWhenPresent), vec![2]);
    }

    #[test]
    fn a_non_numeric_param_field_is_skipped_not_zeroed() {
        let csi = parse_csi(b"\x1b[?1;;2h", 0).expect("parses");
        assert_eq!(param_fields(&csi, PrivateMarker::AlwaysDropFirst), vec![1, 2]);
    }
}
