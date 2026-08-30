//! Replay hygiene: closed TUI screens contribute nothing.
//!
//! Removes CLOSED alternate-screen segments (`?1049h … ?1049l`, plus the `?47`/`?1047` variants)
//! from a scrollback REPLAY stream.
//!
//! ## Why
//! A TUI's alt-screen drawing is meaningless as replayed scrollback: `?1049l` discards the alt
//! screen and restores the main screen, so a segment that CLOSED contributes zero cells to the
//! final display. What it does contribute is cost — a long `vim` session records tens of MiB of
//! cursor-relative redraw churn, and a cold reattach replays every byte of it through the wire and
//! the client terminal: seconds of the pane visibly "stuck inside vim" re-rendering stale frames at
//! the recording-time geometry, plus a wide window for the transient-arming leaks the sibling
//! passes exist to close.
//!
//! A segment still OPEN at end-of-stream is the live TUI's visible screen — it is kept verbatim
//! (entering the alt screen included), because replaying it is exactly how the reattaching client
//! repaints a still-running `vim`.
//!
//! ## Semantics
//! - A `DECSET` whose params include 47/1047/1049 OPENS a segment; the matching `DECRST` CLOSES it.
//!   Both ends and the interior are dropped for a closed segment. Mixed-param `CSI`s keep their
//!   non-alt params (`?1049;12h` → `?12h`, emitted outside the drop).
//! - An alt-`DECSET` while already inside a segment is interior (dropped with it); an alt-`DECRST`
//!   with no open segment passes through (defensive resets are real, keep them).
//! - String-sequence bodies are skipped opaquely — an embedded `?1049l` in a `DCS` body must not
//!   close a segment.
//! - Title changes and queries inside a dropped segment vanish with it — titles are re-asserted by
//!   the type-21 control truth on reattach, queries would be stripped later anyway.
//!
//! ## Where it runs
//! In [`crate::sanitize`] after [`crate::inputmode`] (which needs the raw stream for net-state
//! order, and normalises the mixed-param `DECSET`s it tracks) and before the sync-frame pass. The
//! un-acked live tail is NEVER touched (byte-exact resume).

// A VT scanner is a byte cursor, and `bytes[i]` is bounded by the `while` head that let control
// reach it — `i < n` is the check, tested once per step rather than re-asked at every read. The
// `get(i)` rewrite would replace one panic that cannot fire with a silent `None` arm that swallows
// a real off-by-one, so the opt-out is per scanner file and stops at its edge.
#![expect(clippy::indexing_slicing, reason = "the loop head bounds every cursor read")]

use crate::vtscan::{
    Csi, ESC, PrivateMarker, Terminators, param_fields, parse_csi, string_introducer, string_sequence_end,
};

/// DEC private modes that switch to the alternate screen.
pub const ALT_MODES: [i64; 3] = [47, 1047, 1049];

/// Whether `mode` switches to the alternate screen.
#[must_use]
pub fn is_alt_mode(mode: i64) -> bool {
    ALT_MODES.contains(&mode)
}

/// Which way an alt-screen `DECSET`/`DECRST` goes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Transition {
    Enter,
    Leave,
}

/// Returns `bytes` with closed alt-screen segments removed.
///
/// A truncated trailing sequence passes through unchanged (or is swallowed into an open segment,
/// which is then flushed verbatim at end-of-stream).
#[must_use]
pub fn strip(bytes: &[u8]) -> Vec<u8> {
    let n = bytes.len();
    let mut out = Vec::with_capacity(n);
    let mut i = 0;
    // Start offset of the currently OPEN segment (its opening CSI included), `None` when on the
    // main screen. While open, nothing is emitted — on close the whole range is dropped; at
    // end-of-stream the range is flushed verbatim (live TUI).
    let mut open_segment_start: Option<usize> = None;

    while i < n {
        if bytes[i] != ESC || i + 1 >= n {
            if open_segment_start.is_none() {
                out.push(bytes[i]);
            }
            i += 1;
            continue;
        }
        let introducer = bytes[i + 1];
        if introducer == b'[' {
            let Some(csi) = parse_csi(bytes, i) else {
                // Truncated trailing CSI — passthrough (or swallow into an open segment).
                if open_segment_start.is_none() {
                    out.extend_from_slice(&bytes[i..]);
                }
                i = n;
                continue;
            };
            match alt_transition(&csi) {
                Some(Transition::Enter) => {
                    if open_segment_start.is_none() {
                        open_segment_start = Some(i);
                        // Non-alt params of the opening CSI survive OUTSIDE the segment.
                        if let Some(rewritten) = rewrite_dropping_alt_params(&csi) {
                            out.extend_from_slice(&rewritten);
                        }
                    }
                    // An alt-enter while already open is interior — dropped with the segment.
                },
                Some(Transition::Leave) => {
                    if open_segment_start.is_some() {
                        open_segment_start = None; // drop [start, csi.end) — nothing was emitted
                        if let Some(rewritten) = rewrite_dropping_alt_params(&csi) {
                            out.extend_from_slice(&rewritten);
                        }
                    } else {
                        out.extend_from_slice(&bytes[i..csi.end]); // defensive reset — keep
                    }
                },
                None => {
                    if open_segment_start.is_none() {
                        out.extend_from_slice(&bytes[i..csi.end]);
                    }
                },
            }
            i = csi.end;
        } else if let Some(bel_terminates) = string_introducer(introducer) {
            let Some(seq) = string_sequence_end(bytes, i + 2, Terminators::replay(bel_terminates)) else {
                if open_segment_start.is_none() {
                    out.extend_from_slice(&bytes[i..]);
                }
                i = n;
                continue;
            };
            if open_segment_start.is_none() {
                out.extend_from_slice(&bytes[i..seq.seq_end]);
            }
            i = seq.seq_end;
        } else {
            if open_segment_start.is_none() {
                out.extend_from_slice(&bytes[i..(i + 2).min(n)]);
            }
            i += 2;
        }
    }
    // End-of-stream inside an OPEN segment: the live TUI's screen — flush verbatim.
    if let Some(start) = open_segment_start {
        out.extend_from_slice(&bytes[start..]);
    }
    out
}

/// `Enter`/`Leave` when the `CSI` is a `DECSET`/`DECRST` whose params include an alt-screen mode.
fn alt_transition(csi: &Csi<'_>) -> Option<Transition> {
    if !csi.intermediates.is_empty()
        || (csi.final_byte != b'h' && csi.final_byte != b'l')
        || csi.params.first() != Some(&b'?')
    {
        return None;
    }
    if !param_fields(csi, PrivateMarker::AlwaysDropFirst)
        .into_iter()
        .any(is_alt_mode)
    {
        return None;
    }
    Some(if csi.final_byte == b'h' {
        Transition::Enter
    } else {
        Transition::Leave
    })
}

/// The `CSI` minus its alt-screen params (`?1049;12h` → `?12h`), or `None` when nothing remains.
fn rewrite_dropping_alt_params(csi: &Csi<'_>) -> Option<Vec<u8>> {
    let kept: Vec<&[u8]> = csi.params[1..]
        .split(|&b| b == b';')
        .filter(|field| {
            std::str::from_utf8(field)
                .ok()
                .and_then(|text| text.parse::<i64>().ok())
                .is_none_or(|mode| !is_alt_mode(mode))
        })
        .collect();
    if kept.is_empty() {
        return None;
    }
    let mut out = b"\x1b[?".to_vec();
    out.extend_from_slice(&kept.join(&b';'));
    out.push(csi.final_byte);
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::strip;

    #[test]
    fn a_closed_segment_and_its_interior_vanish() {
        let stream = b"before\x1b[?1049hvim drawing\x1b[?1049lafter";
        assert_eq!(strip(stream), b"beforeafter");
    }

    /// The whole point of the pass: an OPEN segment is the live TUI's visible screen.
    #[test]
    fn an_open_segment_survives_verbatim_to_end_of_stream() {
        let stream = b"before\x1b[?1049hstill inside vim";
        assert_eq!(strip(stream), stream);
    }

    #[test]
    fn the_older_forty_seven_variants_segment_too() {
        assert_eq!(strip(b"a\x1b[?47hdraw\x1b[?47lb"), b"ab");
        assert_eq!(strip(b"a\x1b[?1047hdraw\x1b[?1047lb"), b"ab");
    }

    #[test]
    fn a_mixed_param_opener_and_closer_keep_their_other_params() {
        assert_eq!(
            strip(b"\x1b[?1049;12hinside\x1b[?1049;12l"),
            b"\x1b[?12h\x1b[?12l"
        );
    }

    #[test]
    fn a_defensive_reset_on_the_main_screen_is_kept() {
        assert_eq!(strip(b"\x1b[?1049lplain"), b"\x1b[?1049lplain");
    }

    /// Nested enters are interior noise: one segment, not two.
    #[test]
    fn an_alt_enter_inside_an_open_segment_is_interior() {
        assert_eq!(strip(b"a\x1b[?1049hx\x1b[?1049hy\x1b[?1049lb"), b"ab");
    }

    #[test]
    fn an_embedded_alt_reset_inside_a_string_body_cannot_close_a_segment() {
        // The DCS body contains the bytes of a DECRST; they are opaque here.
        let stream = b"a\x1b[?1049h\x1bP\x1b[?1049l\x1b\\still\x1b[?1049lb";
        assert_eq!(strip(stream), b"ab");
    }

    #[test]
    fn ordinary_display_state_passes_through() {
        let stream = b"\x1b[31mred\x1b[0m\x1b[?25l\x1b[H";
        assert_eq!(strip(stream), stream);
    }

    #[test]
    fn a_truncated_trailing_sequence_passes_through_verbatim() {
        assert_eq!(strip(b"text\x1b[?104"), b"text\x1b[?104");
        assert_eq!(strip(b"text\x1b]0;open"), b"text\x1b]0;open");
    }

    /// A head-cut mid-segment: the truncated CSI is swallowed, then the open range is flushed.
    #[test]
    fn a_truncated_sequence_inside_an_open_segment_is_flushed_with_it() {
        let stream = b"a\x1b[?1049hdraw\x1b[?10";
        assert_eq!(strip(stream), stream);
    }

    #[test]
    fn an_empty_stream_stays_empty() {
        assert_eq!(strip(b""), b"");
    }
}
