//! Replay hygiene: no width-stale zsh `PROMPT_SP` fills.
//!
//! Strips zsh's `PROMPT_SP` end-of-line-mark clusters from a scrollback REPLAY stream.
//!
//! ## Why
//! Before every prompt, zsh (`PROMPT_SP` + `PROMPT_CR`, both default-on) emits the
//! `PROMPT_EOL_MARK` — captured live as `\e[1m\e[7m%\e[27m\e[1m\e[0m` — followed by a
//! `COLUMNS`-wide run of spaces and a `CR` (plus an anti-xenl ` \r` tick). At the width it was
//! emitted for, the fill lands exactly on the wrap boundary: from column 0 the prompt overprints
//! the mark (invisible); mid-line it wraps once and leaves the mark on the partial line. The trick
//! is WIDTH-DEPENDENT: replayed into a grid narrower than the recording width (the pane was
//! resized/split since, or history spans several widths) the fill wraps for real and every prompt
//! in the restored transcript grows a stray `%` line — the stray-`%`-character bug seen on
//! reconnect.
//!
//! ## What
//! A cluster is matched ONLY when it immediately precedes the shim's `133;D` / `133;A` `OSC` (zsh's
//! `preprompt` runs right before the precmd hooks, so on this wire the cluster always abuts them)
//! AND the mark carries `SGR` wrapping on BOTH sides (`%B%S` before, the `%s%b` + reset cleanup
//! after — zsh's `promptexpand` always emits both on a capable `TERM`). The two-sided `SGR`
//! requirement is the false-positive guard for sessions that `unsetopt PROMPT_SP`: there the
//! pre-anchor bytes are real command output, and the ordinary `progress: 100%␣␣␣␣\r` pad-to-clear
//! idiom must never match (its `%` is plain text, not `SGR`-wrapped). A bare dumb-`TERM` mark is a
//! deliberate MISS.
//!
//! Replacement is width-independent, and always re-asserts the `SGR` reset the swallowed cluster
//! ended with — the match consumes every `SGR` abutting the mark, which can include one the COMMAND
//! wrote (e.g. its final `\e[0m`); emitting a reset reproduces the exact post-cluster live state
//! either way, so no colour can bleed into the replayed prompt:
//! - **Column 0** (the previous write ended with a newline, looked through zero-width sequences
//!   like `SGR` / `EL` / `DECSCUSR` / `OSC`): the live render was invisible → the cluster becomes
//!   `\e[0m`.
//! - **Mid-line** (empty-Enter / Ctrl-C at the prompt, a genuine partial output line): the live
//!   render moved the prompt to a fresh line → the cluster becomes `\e[0m` + `CRLF`. The partial
//!   line survives verbatim; only the mark and the stale fill go.
//!
//! ## Where it runs
//! LAST in [`crate::sanitize`], after the distiller and the query pass, which only improve its
//! cluster→`133;D`/`133;A` adjacency anchor. Also on its own, over one captured command block's
//! output tail (the `last-output` ctl verb), where the segmenter has already stripped the marks and
//! the caller re-appends a synthetic `D` anchor to restore the adjacency this keys on.

use crate::altscreen::is_alt_mode;
use crate::vtscan::{BEL, CR, ESC, LF};

/// Minimum fill length accepted as a `PROMPT_SP` space run (`COLUMNS - markwidth - 1`).
///
/// Real terminals are ≥ 20 columns wide; 8 keeps narrow panes covered without ever matching
/// ordinary aligned output.
const MIN_FILL_SPACES: usize = 8;

/// Byte budget for the backward column-0 classification walk.
///
/// A wrong bail-out just downgrades an excision to the safe `CRLF` replacement, never corrupts.
const ZERO_WIDTH_WALK_BYTE_BUDGET: usize = 4096;
/// Sequence budget for the same walk.
const ZERO_WIDTH_WALK_SEQUENCE_BUDGET: usize = 64;

const SPACE: u8 = 0x20;

/// One matched cluster: the range to excise and how it rendered live.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Edit {
    start: usize,
    end: usize,
    column_zero: bool,
}

/// Returns `bytes` with every `PROMPT_SP` cluster normalised. Everything else passes through
/// verbatim.
#[must_use]
pub fn strip(bytes: &[u8]) -> Vec<u8> {
    if bytes.is_empty() {
        return Vec::new();
    }
    let n = bytes.len();

    // Non-overlapping by construction: a cluster ends at its anchor's `ESC`, and a backward match
    // from the NEXT anchor stops at this anchor's terminator (`BEL`/`ST` is not `CR`).
    let mut edits: Vec<Edit> = Vec::new();
    let mut i = 0;
    while i + 6 < n {
        // Anchor: `ESC ] 1 3 3 ;` with subcommand A or D (prompt start / command finished).
        let is_anchor = bytes[i] == ESC
            && bytes[i + 1] == b']'
            && &bytes[i + 2..i + 6] == b"133;"
            && (bytes[i + 6] == b'A' || bytes[i + 6] == b'D');
        if !is_anchor {
            i += 1;
            continue;
        }
        if let Some(start) = cluster_ending_at(i, bytes) {
            edits.push(Edit {
                start,
                end: i,
                column_zero: column_zero(start, bytes),
            });
        }
        i += 7;
    }
    if edits.is_empty() {
        return bytes.to_vec();
    }

    let mut out = Vec::with_capacity(n);
    let mut cursor = 0;
    for edit in &edits {
        out.extend_from_slice(&bytes[cursor..edit.start]);
        // Re-assert the reset the cluster's own `SGR` cleanup ended with — the match consumed every
        // `SGR` abutting the mark (possibly including one the command wrote), and the live
        // post-cluster state was reset either way.
        out.extend_from_slice(b"\x1b[0m");
        if !edit.column_zero {
            out.push(CR);
            out.push(LF);
        }
        cursor = edit.end;
    }
    out.extend_from_slice(&bytes[cursor..]);
    out
}

/// Matches `SGR* mark SGR* SP{≥8} CR (SP CR){0,2}` ending exactly at `anchor` (the `ESC` of the
/// `133;D`/`133;A` `OSC`). Returns the cluster's start index.
fn cluster_ending_at(anchor: usize, bytes: &[u8]) -> Option<usize> {
    let mut j = anchor;
    // PROMPT_CR, newest-last: an optional anti-xenl ` \r` tick (observed once; tolerate two), then
    // the mandatory `CR` that ends the space fill.
    if j == 0 || bytes[j - 1] != CR {
        return None;
    }
    j -= 1;
    let mut ticks = 0;
    while ticks < 2 && j >= 2 && bytes[j - 1] == SPACE && bytes[j - 2] == CR {
        j -= 2;
        ticks += 1;
    }
    // The COLUMNS-wide space fill.
    let fill_end = j;
    while j > 0 && bytes[j - 1] == SPACE {
        j -= 1;
    }
    if fill_end - j < MIN_FILL_SPACES {
        return None;
    }
    // `SGR` run after the mark (`%s%b` + reset), the mark itself (`%` — or `#` for a root shell), and
    // the `SGR` run before it (`%B%S`). BOTH runs must be non-empty — the false-positive guard: a
    // plain-text `%`/`#` at the end of real command output (a session that `unsetopt PROMPT_SP`,
    // followed by a pad-to-clear + `CR`) has no `SGR` wrapping, while zsh's `promptexpand` always
    // emits both sides on a capable `TERM`. A bare dumb-`TERM` mark is a deliberate miss.
    let suffix_end = j;
    while let Some(start) = sgr_start(j, bytes) {
        j = start;
    }
    if j >= suffix_end {
        return None;
    }
    if j == 0 || (bytes[j - 1] != b'%' && bytes[j - 1] != b'#') {
        return None;
    }
    j -= 1;
    let prefix_end = j;
    while let Some(start) = sgr_start(j, bytes) {
        j = start;
    }
    if j >= prefix_end {
        return None;
    }
    Some(j)
}

/// Matches an `SGR` (`ESC [ params m`) ending exactly at `end`; returns its `ESC` index.
fn sgr_start(end: usize, bytes: &[u8]) -> Option<usize> {
    if end < 3 || bytes[end - 1] != b'm' {
        return None;
    }
    let mut i = end - 2;
    let floor = end.saturating_sub(24); // SGR params are short; bound the scan
    while i > floor && (0x30..=0x3B).contains(&bytes[i]) {
        i -= 1;
    }
    (i >= 1 && bytes[i] == b'[' && bytes[i - 1] == ESC).then(|| i - 1)
}

/// Whether the byte stream is provably at column 0 when the cluster starts.
///
/// The nearest preceding NON-zero-width byte is a newline / `CR`, or the stream start. Zero-width
/// writes — `SGR`, `EL` (`ESC [ K`), `DECSCUSR` (`ESC [ n SP q`), any `OSC` — are looked through
/// (the captured `cd ~` cycle interposes `\e[0 q` between the `CRLF` and the cluster). Anything
/// unrecognised (cursor motion, alt-screen exit, plain text) ends the walk: text ⇒ mid-line;
/// unknown control ⇒ the column is unknowable, and "not column 0" (`CRLF` replacement) is the safe
/// answer — a spare newline, never an overprinted line.
fn column_zero(start: usize, bytes: &[u8]) -> bool {
    let mut i = start;
    let mut budget = ZERO_WIDTH_WALK_SEQUENCE_BUDGET;
    let floor = start.saturating_sub(ZERO_WIDTH_WALK_BYTE_BUDGET);
    while i > floor && budget > 0 {
        // A bare `CHA` (`ESC [ G` / `ESC [ 1 G`) parks the cursor at column 1 — direct proof,
        // regardless of what came before it (the captured inline-TUI `\e[13A\e[G` epilogue).
        if column_one_cha_ends_at(i, bytes) {
            return true;
        }
        let Some(start) = zero_width_sequence_start(i, floor, bytes) else {
            break;
        };
        i = start;
        budget -= 1;
    }
    if i == 0 {
        return true;
    }
    if i <= floor {
        return false; // budget exhausted mid-walk — unknown
    }
    bytes[i - 1] == LF || bytes[i - 1] == CR
}

/// Whether a column-1 `CHA` (`ESC [ G` or `ESC [ 1 G`) ends exactly at `end`.
const fn column_one_cha_ends_at(end: usize, bytes: &[u8]) -> bool {
    if end < 3 || bytes[end - 1] != b'G' {
        return false;
    }
    let mut i = end - 2;
    if bytes[i] == b'1' {
        i -= 1;
    }
    i >= 1 && bytes[i] == b'[' && bytes[i - 1] == ESC
}

/// Matches one zero-width sequence ending exactly at `end`; returns its start (the `ESC`).
fn zero_width_sequence_start(end: usize, floor: usize, bytes: &[u8]) -> Option<usize> {
    if end < 3 {
        return None;
    }
    let last = bytes[end - 1];
    // `CSI` finals that never change the COLUMN (this walk classifies the column only): `SGR` `m`,
    // `EL` `K`, `DECSCUSR` `SP q`, and `CUU`/`CUD` `A`/`B` (rows move, columns do not).
    if matches!(last, b'm' | b'K' | b'q' | b'A' | b'B') {
        let mut i = end - 2;
        if last == b'q' {
            if bytes[i] != SPACE {
                return None; // DECSCUSR's intermediate
            }
            i -= 1;
        }
        while i > floor && (0x30..=0x3B).contains(&bytes[i]) {
            i -= 1;
        }
        return (i >= 1 && bytes[i] == b'[' && bytes[i - 1] == ESC).then(|| i - 1);
    }
    // `DECSET`/`DECRST` (`ESC [ ? … h/l`) never move the cursor — cursor-show `?25h`, autowrap
    // `?7h`, sync-frame `?2026h/l`, bracketed-paste `?2004h` all interpose between a prompt cycle's
    // `CRLF` and its cluster. The EXCEPTION is the alt-screen trio (47/1047/1049): those switch grids
    // and restore a SAVED cursor, so the column is unknowable across them — end the walk. `ED`
    // (`ESC [ … J`) erases without ever moving the cursor. ANSI `SM`/`RM` (no `?`) are out of scope:
    // unrecognised ⇒ the safe mid-line answer.
    if matches!(last, b'h' | b'l' | b'J') {
        let mut i = end - 2;
        while i > floor && (0x30..=0x3B).contains(&bytes[i]) {
            i -= 1;
        }
        let is_private = bytes[i] == b'?';
        let params_start = i + 1;
        if is_private {
            i -= 1;
        }
        if i < 1 || bytes[i] != b'[' || bytes[i - 1] != ESC {
            return None;
        }
        if last == b'J' {
            return Some(i - 1);
        }
        if !is_private {
            return None;
        }
        let touches_alt = bytes
            .get(params_start..end - 1)
            .unwrap_or_default()
            .split(|&b| b == b';')
            .filter_map(|field| std::str::from_utf8(field).ok()?.parse::<i64>().ok())
            .any(is_alt_mode);
        if touches_alt {
            return None;
        }
        return Some(i - 1);
    }
    // `OSC` (title set, hyperlink, a 133 mark…), `BEL`- or `ST`-terminated: scan back to `ESC ]`.
    let body_end = if last == BEL {
        end - 1
    } else if last == b'\\' && bytes[end - 2] == ESC {
        end - 2
    } else {
        return None;
    };
    let mut i = body_end.checked_sub(1)?;
    while i > floor {
        let byte = bytes[i];
        if byte == ESC {
            return (bytes.get(i + 1) == Some(&b']')).then_some(i);
        }
        if byte == BEL || byte == LF || byte == CR {
            return None; // crossed another terminator/line
        }
        i -= 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::strip;

    /// The live capture: `%B%S` + `%` + `%s%b` + reset, then the COLUMNS fill and `CR`.
    fn cluster() -> Vec<u8> {
        let mut out = b"\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m".to_vec();
        out.extend(std::iter::repeat_n(b' ', 79));
        out.push(b'\r');
        out
    }

    fn anchor() -> &'static [u8] {
        b"\x1b]133;A\x07"
    }

    #[test]
    fn a_cluster_at_column_zero_becomes_a_bare_reset() {
        let mut stream = b"output\r\n".to_vec();
        stream.extend_from_slice(&cluster());
        stream.extend_from_slice(anchor());
        assert_eq!(strip(&stream), b"output\r\n\x1b[0m\x1b]133;A\x07");
    }

    /// Mid-line the live render moved the prompt down; the replacement must too.
    #[test]
    fn a_cluster_mid_line_becomes_a_reset_plus_crlf() {
        let mut stream = b"partial line".to_vec();
        stream.extend_from_slice(&cluster());
        stream.extend_from_slice(anchor());
        assert_eq!(strip(&stream), b"partial line\x1b[0m\r\n\x1b]133;A\x07");
    }

    #[test]
    fn the_command_finished_mark_anchors_it_too() {
        let mut stream = b"out\r\n".to_vec();
        stream.extend_from_slice(&cluster());
        stream.extend_from_slice(b"\x1b]133;D;0\x07");
        assert_eq!(strip(&stream), b"out\r\n\x1b[0m\x1b]133;D;0\x07");
    }

    /// The false-positive guard: a plain-text `%` with no SGR wrapping is real output.
    #[test]
    fn an_unwrapped_percent_pad_to_clear_is_never_matched() {
        let mut stream = b"progress: 100%".to_vec();
        stream.extend(std::iter::repeat_n(b' ', 79));
        stream.push(b'\r');
        stream.extend_from_slice(anchor());
        assert_eq!(strip(&stream), stream);
    }

    /// A dumb-TERM mark carries no SGR on either side — a deliberate miss.
    #[test]
    fn a_mark_with_sgr_on_only_one_side_is_a_miss() {
        let mut stream = b"x\x1b[1m%".to_vec();
        stream.extend(std::iter::repeat_n(b' ', 79));
        stream.push(b'\r');
        stream.extend_from_slice(anchor());
        assert_eq!(strip(&stream), stream);
    }

    #[test]
    fn a_root_shells_hash_mark_matches_like_the_percent() {
        let mut stream = b"out\r\n\x1b[1m\x1b[7m#\x1b[0m".to_vec();
        stream.extend(std::iter::repeat_n(b' ', 79));
        stream.push(b'\r');
        stream.extend_from_slice(anchor());
        assert_eq!(strip(&stream), b"out\r\n\x1b[0m\x1b]133;A\x07");
    }

    #[test]
    fn a_fill_shorter_than_the_minimum_is_not_a_prompt_sp_run() {
        let mut stream = b"out\r\n\x1b[1m\x1b[7m%\x1b[0m".to_vec();
        stream.extend(std::iter::repeat_n(b' ', 3));
        stream.push(b'\r');
        stream.extend_from_slice(anchor());
        assert_eq!(strip(&stream), stream);
    }

    /// The anti-xenl tick: zsh emits ` \r` after the fill, sometimes twice.
    #[test]
    fn the_anti_xenl_ticks_are_consumed_with_the_cluster() {
        for ticks in 0..=2 {
            let mut stream = b"out\r\n".to_vec();
            stream.extend_from_slice(&cluster());
            for _ in 0..ticks {
                stream.extend_from_slice(b" \r");
            }
            stream.extend_from_slice(anchor());
            assert_eq!(
                strip(&stream),
                b"out\r\n\x1b[0m\x1b]133;A\x07",
                "{ticks} ticks must be consumed"
            );
        }
    }

    /// Zero-width sequences between the newline and the cluster must not hide column 0.
    #[test]
    fn the_column_walk_looks_through_zero_width_sequences() {
        for interposed in [
            &b"\x1b[0 q"[..],
            &b"\x1b[K"[..],
            &b"\x1b[31m"[..],
            &b"\x1b[?25h"[..],
            &b"\x1b[?2004h"[..],
            &b"\x1b[2J"[..],
            &b"\x1b]0;title\x07"[..],
        ] {
            let mut stream = b"out\r\n".to_vec();
            stream.extend_from_slice(interposed);
            stream.extend_from_slice(&cluster());
            stream.extend_from_slice(anchor());
            let out = strip(&stream);
            // Column 0 ⇒ a bare reset; the mid-line answer would be `\x1b[0m\r\n` instead.
            assert!(
                out.ends_with(b"\x1b[0m\x1b]133;A\x07"),
                "{interposed:?} should still read as column 0: {out:?}"
            );
        }
    }

    /// A bare `CHA` is direct proof of column 1 whatever preceded it.
    #[test]
    fn a_column_one_cha_proves_column_zero_on_its_own() {
        for cha in [&b"\x1b[G"[..], &b"\x1b[1G"[..]] {
            let mut stream = b"mid line text".to_vec();
            stream.extend_from_slice(cha);
            stream.extend_from_slice(&cluster());
            stream.extend_from_slice(anchor());
            let out = strip(&stream);
            assert!(
                out.ends_with(b"\x1b[0m\x1b]133;A\x07"),
                "{cha:?} must prove column 0: {out:?}"
            );
        }
    }

    /// Across an alt-screen switch the column is unknowable — take the safe answer.
    #[test]
    fn an_alt_screen_switch_ends_the_walk_at_the_safe_answer() {
        let mut stream = b"out\r\n\x1b[?1049l".to_vec();
        stream.extend_from_slice(&cluster());
        stream.extend_from_slice(anchor());
        let out = strip(&stream);
        assert!(out.ends_with(b"\x1b[0m\r\n\x1b]133;A\x07"), "{out:?}");
    }

    #[test]
    fn a_cluster_at_the_very_start_of_the_stream_is_column_zero() {
        let mut stream = cluster();
        stream.extend_from_slice(anchor());
        assert_eq!(strip(&stream), b"\x1b[0m\x1b]133;A\x07");
    }

    #[test]
    fn several_prompts_each_get_their_own_excision() {
        let mut stream = Vec::new();
        for _ in 0..3 {
            stream.extend_from_slice(b"out\r\n");
            stream.extend_from_slice(&cluster());
            stream.extend_from_slice(anchor());
        }
        let out = strip(&stream);
        assert_eq!(out.windows(4).filter(|w| *w == b"\x1b[0m").count(), 3);
        assert!(!out.contains(&b'%'));
    }

    #[test]
    fn a_stream_with_no_anchor_is_returned_unchanged() {
        let mut stream = b"out\r\n".to_vec();
        stream.extend_from_slice(&cluster());
        assert_eq!(strip(&stream), stream);
    }

    #[test]
    fn ordinary_output_rides_through() {
        let stream = b"nothing to see \x1b[31mhere\x1b[0m\r\n";
        assert_eq!(strip(stream), stream);
    }

    #[test]
    fn an_empty_stream_stays_empty() {
        assert_eq!(strip(b""), b"");
    }
}
