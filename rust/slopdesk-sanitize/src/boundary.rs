//! Splitting a trailing INCOMPLETE sequence off a chunk-cut stream.
//!
//! ## Why every replay verb starts here
//! A PTY read returns whatever bytes had arrived, at an arbitrary offset. So the edge a replay runs
//! up to — the scrollback-ring / un-acked-tail boundary, or a journal that stopped when the daemon
//! did — can sit in the MIDDLE of one escape sequence or one UTF-8 scalar. The live tail that
//! follows begins with the continuation bytes.
//!
//! Two things then go wrong, and they are different:
//!
//! - **Anything appended after the split half lands mid-sequence.** The input-mode reassert is
//!   appended by every replay verb that takes one, so on a reattach into a live TUI the terminal
//!   aborts the split sequence — losing its toggle — and prints the tail's continuation as literal
//!   text. That is the `zsh: command not found: 18M65…` class of reattach garbage.
//! - **A parser DROPS the partial scalar.** The screen model consumes a lead byte whose
//!   continuations never came and discards it; the tail's continuation bytes then render as garbage
//!   on their own.
//!
//! Both are fixed by holding the incomplete half back, running the passes over the head, and
//! re-attaching the dangling bytes LAST — `[transformed][reassert][dangling][live tail]`, with the
//! two halves adjacent. The transcript verb DROPS the dangling half instead: that stream ended with
//! the process, so no continuation will ever follow it.
//!
//! ## Why this is here and not in the caller
//! It used to be host-side, on the theory that the boundary is the host's bookkeeping. It is not —
//! every rule below is read out of the bytes themselves, and none of it needs to know where the
//! chunk came from. Keeping it at the caller meant the ordering constraint ("append the reassert
//! before the dangling half") was a convention two Swift call sites had to remember, and a byte
//! machine over untrusted PTY output living where no other byte machine does.

/// Backward-scan bound for the trailing-escape check.
///
/// Real dangling artifacts are short — a mid-CSI chunk cut. An unterminated string sequence whose
/// opener sits further back than this is left alone, which is passthrough: the alternative is
/// holding back an unbounded tail because somebody emitted a lone `ESC ]` a megabyte ago.
pub const TRAILING_ESCAPE_SCAN_BYTES: usize = 4096;

const ESC: u8 = 0x1B;
const BEL: u8 = 0x07;

/// Splits `bytes` into `(head, dangling)` where `dangling` is a trailing escape sequence the buffer
/// ends MID-WAY through — no final byte, no string terminator. Empty when it ends clean.
///
/// Ambiguity errs toward "no dangling": holding back bytes that were in fact complete delays them
/// behind a tail that may never arrive, which is the worse failure of the two.
#[must_use]
pub fn split_trailing_incomplete_escape(bytes: &[u8]) -> (&[u8], &[u8]) {
    let n = bytes.len();
    if n == 0 {
        return (bytes, &[]);
    }
    // The LAST ESC within the window is the only possible opener of an unterminated sequence: an
    // earlier one would have to be terminated for this one to exist.
    let floor = n.saturating_sub(TRAILING_ESCAPE_SCAN_BYTES);
    let Some(open) = bytes
        .iter()
        .enumerate()
        .skip(floor)
        .rev()
        .find_map(|(index, byte)| (*byte == ESC).then_some(index))
    else {
        return (bytes, &[]);
    };

    let incomplete = if open == n - 1 {
        true // a lone trailing ESC
    } else {
        match bytes.get(open + 1).copied().unwrap_or(0) {
            // CSI: parameters, then intermediates, then a final byte in 0x40–0x7E.
            b'[' => {
                let mut cursor = open + 2;
                while matches!(bytes.get(cursor), Some(0x30..=0x3F)) {
                    cursor += 1;
                }
                while matches!(bytes.get(cursor), Some(0x20..=0x2F)) {
                    cursor += 1;
                }
                !matches!(bytes.get(cursor), Some(0x40..=0x7E))
            },
            // OSC: BEL terminates. ST cannot — its own ESC would be a LATER ESC, and this one is
            // the last, so reaching the end means the body ran off it.
            b']' => !bytes.get(open + 2..).unwrap_or_default().contains(&BEL),
            // DCS / SOS / PM / APC: only ST terminates, and the same argument applies.
            b'P' | b'X' | b'^' | b'_' => true,
            // ESC + intermediate(s) + a final byte — charset designators and friends.
            0x20..=0x2F => {
                let mut cursor = open + 1;
                while matches!(bytes.get(cursor), Some(0x20..=0x2F)) {
                    cursor += 1;
                }
                cursor >= n
            },
            // A two-byte ESC pair, complete.
            _ => false,
        }
    };

    if incomplete {
        bytes.split_at(open)
    } else {
        (bytes, &[])
    }
}

/// Splits a trailing INCOMPLETE UTF-8 scalar off `bytes`.
///
/// That is a lead byte whose continuations have not all arrived. Empty `dangling` when the buffer
/// ends on a complete scalar, on ASCII, or on something that is not a valid lead at all.
#[must_use]
pub fn split_trailing_incomplete_utf8(bytes: &[u8]) -> (&[u8], &[u8]) {
    let n = bytes.len();
    if n == 0 {
        return (bytes, &[]);
    }
    // Four bytes is the longest scalar, so a lead further back than that cannot be waiting on
    // anything inside this buffer.
    let window = bytes.get(n.saturating_sub(4)..).unwrap_or_default();
    let continuations = window
        .iter()
        .rev()
        .take_while(|byte| *byte & 0xC0 == 0x80)
        .count();
    if continuations >= window.len() || continuations >= 4 {
        // Nothing but continuation bytes in the window — a stray tail, not a scalar we can
        // complete.
        return (bytes, &[]);
    }
    let lead = window.get(window.len() - continuations - 1).copied().unwrap_or(0);
    let expected = match lead {
        0xC0..=0xDF => 1,
        0xE0..=0xEF => 2,
        0xF0..=0xF7 => 3,
        // ASCII is already complete; anything else is a stray continuation byte or an invalid lead,
        // and inventing a length for one of those would hold back bytes on a guess. Same answer,
        // and it is the same answer on purpose: neither is waiting for anything.
        _ => return (bytes, &[]),
    };
    if continuations >= expected {
        return (bytes, &[]); // the scalar is complete
    }
    bytes.split_at(n - (continuations + 1))
}

/// The split every replay verb starts with: an incomplete escape first, and only when the buffer
/// ends clean of one, an incomplete UTF-8 scalar.
///
/// The order matters and the fallthrough is deliberate. A dangling escape sequence may legitimately
/// carry high bytes in its body (an OSC title), so running the scalar check over a buffer that
/// already ends inside a sequence would split the SAME tail twice and interleave the halves.
#[must_use]
pub fn split_trailing_incomplete(bytes: &[u8]) -> (&[u8], &[u8]) {
    let (head, dangling) = split_trailing_incomplete_escape(bytes);
    if dangling.is_empty() {
        split_trailing_incomplete_utf8(head)
    } else {
        (head, dangling)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_buffer_that_ends_clean_holds_nothing_back() {
        assert_eq!(
            split_trailing_incomplete_escape(b"hello\r\n"),
            (b"hello\r\n".as_slice(), b"".as_slice(),)
        );
        assert_eq!(
            split_trailing_incomplete_escape(b""),
            (b"".as_slice(), b"".as_slice())
        );
    }

    #[test]
    fn a_csi_cut_before_its_final_byte_is_held_back() {
        // `ESC [ 1 ; 2` — parameters, then the buffer ends. The final byte is in the live tail.
        let (head, dangling) = split_trailing_incomplete_escape(b"ok\x1b[1;2");
        assert_eq!(head, b"ok");
        assert_eq!(dangling, b"\x1b[1;2");
    }

    #[test]
    fn a_complete_csi_is_not_held_back() {
        let (head, dangling) = split_trailing_incomplete_escape(b"ok\x1b[1;2H");
        assert_eq!(head, b"ok\x1b[1;2H");
        assert!(dangling.is_empty());
    }

    #[test]
    fn a_lone_trailing_escape_is_held_back() {
        assert_eq!(
            split_trailing_incomplete_escape(b"ok\x1b"),
            (b"ok".as_slice(), b"\x1b".as_slice(),)
        );
    }

    #[test]
    fn an_osc_is_held_back_until_its_bel() {
        let (head, dangling) = split_trailing_incomplete_escape(b"a\x1b]0;title");
        assert_eq!(head, b"a");
        assert_eq!(dangling, b"\x1b]0;title");
        // With the BEL it is complete and nothing is held.
        let (head, dangling) = split_trailing_incomplete_escape(b"a\x1b]0;title\x07");
        assert_eq!(head, b"a\x1b]0;title\x07");
        assert!(dangling.is_empty());
    }

    #[test]
    fn a_string_sequence_runs_to_the_end_by_definition() {
        // DCS/SOS/PM/APC end only at ST, whose ESC would be a LATER ESC than this opener.
        for opener in *b"PX^_" {
            let mut stream = b"a\x1b".to_vec();
            stream.push(opener);
            stream.extend_from_slice(b"body");
            let (head, dangling) = split_trailing_incomplete_escape(&stream);
            assert_eq!(head, b"a", "ESC {} should hold back", char::from(opener));
            assert_eq!(dangling.len(), 6);
        }
    }

    #[test]
    fn a_charset_designator_missing_its_final_byte_is_held_back() {
        // `ESC ( ` — an intermediate with no final. `ESC ( B` is complete.
        assert_eq!(
            split_trailing_incomplete_escape(b"a\x1b("),
            (b"a".as_slice(), b"\x1b(".as_slice(),)
        );
        let (_, dangling) = split_trailing_incomplete_escape(b"a\x1b(B");
        assert!(dangling.is_empty());
    }

    #[test]
    fn a_two_byte_escape_pair_is_complete() {
        // `ESC M` (reverse index) has no final byte to wait for.
        let (head, dangling) = split_trailing_incomplete_escape(b"a\x1bM");
        assert_eq!(head, b"a\x1bM");
        assert!(dangling.is_empty());
    }

    #[test]
    fn an_opener_beyond_the_scan_window_is_left_alone() {
        // Passthrough by design: an unbounded hold-back is worse than a rare unsplit tail.
        let mut stream = b"\x1b]0;".to_vec();
        stream.extend(std::iter::repeat_n(b'x', TRAILING_ESCAPE_SCAN_BYTES + 10));
        let (head, dangling) = split_trailing_incomplete_escape(&stream);
        assert_eq!(head.len(), stream.len());
        assert!(dangling.is_empty());
    }

    #[test]
    fn a_scalar_cut_between_its_bytes_is_held_back() {
        // "é" is C3 A9. Cut after the lead.
        assert_eq!(
            split_trailing_incomplete_utf8(b"a\xc3"),
            (b"a".as_slice(), b"\xc3".as_slice(),)
        );
        // Cut inside a three-byte scalar (E2 82 AC = "€"), one continuation short.
        assert_eq!(
            split_trailing_incomplete_utf8(b"a\xe2\x82"),
            (b"a".as_slice(), b"\xe2\x82".as_slice(),)
        );
    }

    #[test]
    fn a_complete_scalar_is_not_held_back() {
        for complete in ["a", "é", "€", "😀"] {
            let (head, dangling) = split_trailing_incomplete_utf8(complete.as_bytes());
            assert_eq!(head, complete.as_bytes(), "{complete} should stay whole");
            assert!(dangling.is_empty());
        }
    }

    #[test]
    fn a_stray_continuation_or_invalid_lead_is_left_alone() {
        // Nothing here can be completed by more bytes, so holding any back would strand them.
        assert!(split_trailing_incomplete_utf8(b"a\x80").1.is_empty());
        assert!(split_trailing_incomplete_utf8(b"\x80\x80\x80\x80").1.is_empty());
        assert!(split_trailing_incomplete_utf8(b"a\xf8").1.is_empty());
    }

    #[test]
    fn the_escape_split_wins_and_the_scalar_check_does_not_run_over_it() {
        // An OSC body carrying a multi-byte title, cut mid-sequence. Splitting twice would
        // interleave the halves of one tail.
        let stream = b"a\x1b]0;caf\xc3\xa9";
        let (head, dangling) = split_trailing_incomplete(stream);
        assert_eq!(head, b"a");
        assert_eq!(dangling, b"\x1b]0;caf\xc3\xa9");
    }

    #[test]
    fn the_scalar_check_runs_when_no_escape_dangles() {
        let (head, dangling) = split_trailing_incomplete(b"\x1b[0ma\xe2\x82");
        assert_eq!(head, b"\x1b[0ma");
        assert_eq!(dangling, b"\xe2\x82");
    }

    #[test]
    fn the_two_halves_always_reconstruct_the_input() {
        // The property that makes any of this safe: nothing is dropped or duplicated.
        for stream in [
            b"".as_slice(),
            b"plain",
            b"a\x1b[1;2",
            b"a\x1b",
            b"a\xe2\x82",
            b"a\x1b]0;t\x07",
            "😀".as_bytes(),
        ] {
            let (head, dangling) = split_trailing_incomplete(stream);
            let mut rejoined = head.to_vec();
            rejoined.extend_from_slice(dangling);
            assert_eq!(rejoined, stream);
        }
    }
}
