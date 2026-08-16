//! The scrollback REPLAY transform: seven passes, one call.
//!
//! What a cold-reattaching client receives is not the pane's byte history — it is that history with
//! everything removed whose only effect on a REPLAY is to be wrong. Each pass has its own module
//! and its own reasons; this one fixes the ORDER, which is load-bearing, and hands the caller a
//! single verb so the whole chain crosses the socket once instead of seven times.
//!
//! ## The order, and why it is the order
//! 1. [`crate::inputmode`] — mouse / kitty-keyboard / in-band-resize mode changes, so replayed
//!    history can never transiently arm the client's input reporting (the reattach `zsh: command
//!    not found: 18M65…` garbage). Runs FIRST, on the RAW stream: the net final state must be
//!    computed in true chronological order, and the distiller REORDERS bytes — an open B→C span
//!    (where zsh toggles `?2004` per prompt) is flushed out of sequence or replaced outright by the
//!    committed command line.
//! 2. [`crate::altscreen`] — CLOSED alt-screen segments, which contribute nothing to the final
//!    display and cost tens of MiB that render as a pane "stuck inside vim".
//! 3. [`crate::syncframe`] — synchronized-output frames that repaint in place: the INLINE-TUI
//!    counterpart of pass 2, which cannot see churn that never enters the alt screen. After the
//!    alt-screen strip (only inline + live-segment churn left to chew), before the distiller.
//! 4. [`crate::overprint`] — superseded revisions of a `CR`-overprinted line (`git push`, `swift
//!    build`, `npm`, `docker pull`). The third churn pass, for output that is neither alt-screen
//!    nor sync-framed and so invisible to both siblings; before the distiller (megabytes less to
//!    scan) and leaving every line carrying an `OSC 133` mark verbatim, so the distiller's anchors
//!    all survive.
//! 5. [`crate::distill`] — the B→C line-editor collapse. The one OPTIONAL pass
//!    ([`Options::distill`], gated host-side by `SLOPDESK_SCROLLBACK_DISTILL`).
//! 6. [`crate::query`] — terminal queries, echoed responses and stale colour state (the reattach
//!    "garbage input" fix).
//! 7. [`crate::prompteol`] — zsh `PROMPT_SP` clusters, whose width-dependent overprint trick
//!    surfaces stray `%` lines at a different grid width. Runs LAST: every earlier pass only
//!    improves its cluster→`133;D`/`133;A` adjacency anchor.
//!
//! Passes 1–4, 6 and 7 are UNCONDITIONAL. Six env opt-outs used to exist host-side; nobody wants
//! the garbage back, and six flags for "do not show garbage" is six ways to break a reattach with
//! no way to notice.
//!
//! ## The chunk boundary is handled here too
//! A PTY read can cut one escape sequence in half, so this starts by holding that half back
//! ([`crate::boundary`]) and ends by re-attaching it AFTER the reassert —
//! `[transformed][reassert][dangling][live tail]`, with the two halves of the split sequence
//! adjacent. It used to be the caller's job, on the theory that the boundary was the host's
//! bookkeeping; it is not, and leaving it there made the ordering a convention two call sites had
//! to remember rather than an invariant of this reply.

use crate::{altscreen, boundary, distill, inputmode, overprint, prompteol, query, syncframe};

/// The two bits of the pipeline a caller chooses.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Options {
    /// Re-append the NET final input-mode state after the last pass, so a session still inside a
    /// TUI keeps that TUI's modes across a cold reattach.
    ///
    /// The RING path (a live session) re-asserts; the JOURNAL path (a fresh shell after a daemon
    /// restart) must NOT — there is no TUI to serve, and the restored bytes front a NEW shell that
    /// has to start with every mode off.
    pub reassert_input_modes: bool,
    /// Run pass 5, the B→C line-editor collapse.
    pub distill: bool,
}

/// Runs the whole transform over `bytes`.
///
/// The reassert sequence, when asked for, is appended after every pass — because it describes the
/// state the stream ENDS in, and any pass running over it afterwards would strip it back out (pass
/// 1 exists to remove exactly those bytes). The dangling half of a cut escape sequence is appended
/// after THAT, so nothing this function adds can land mid-sequence.
///
/// Only the escape split applies here: this reply is spliced ahead of a raw live tail that the
/// terminal will consume byte-wise, and a partial UTF-8 scalar reunites with its continuation
/// there. The composing verbs, which hand a PARSER the head, hold that back too.
#[must_use]
pub fn sanitize(bytes: &[u8], options: Options) -> Vec<u8> {
    let (head, dangling) = boundary::split_trailing_incomplete_escape(bytes);
    let (stripped, state) = inputmode::strip(head);
    let mut out = altscreen::strip(&stripped);
    out = syncframe::collapse(&out);
    out = overprint::collapse(&out);
    if options.distill {
        out = distill::distill(&out);
    }
    out = query::strip(&out);
    out = prompteol::strip(&out);
    if options.reassert_input_modes {
        out.extend_from_slice(&state.reassert_sequence());
    }
    out.extend_from_slice(dangling);
    out
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::{Options, sanitize};

    const ALL_OFF: Options = Options {
        reassert_input_modes: false,
        distill: false,
    };

    #[test]
    fn ordinary_output_rides_through_every_pass_unchanged() {
        let stream = b"hello\r\nworld\r\n";
        assert_eq!(sanitize(stream, ALL_OFF), stream);
    }

    /// The reattach garbage fix: no mode toggle may survive a replay.
    #[test]
    fn armed_input_modes_never_survive() {
        let out = sanitize(b"\x1b[?1000h\x1b[?2004hprompt", ALL_OFF);
        assert_eq!(out, b"prompt");
    }

    /// A session still inside a TUI keeps its modes — but only once, and only at the end.
    #[test]
    fn the_reassert_lands_last_and_only_when_asked() {
        let raw = b"\x1b[?1002h\x1b[?1006hdrawing";
        let bare = sanitize(raw, ALL_OFF);
        assert_eq!(bare, b"drawing");
        let kept = sanitize(raw, Options {
            reassert_input_modes: true,
            distill: false,
        });
        assert!(kept.starts_with(b"drawing"), "{kept:?}");
        let tail = kept.get(b"drawing".len()..).expect("a tail");
        assert_eq!(tail, b"\x1b[?1002h\x1b[?1006h");
    }

    /// A mode turned on and back off is neutral: nothing to re-assert.
    #[test]
    fn a_neutral_net_state_re_asserts_nothing() {
        let out = sanitize(b"\x1b[?1000hx\x1b[?1000l", Options {
            reassert_input_modes: true,
            distill: false,
        });
        assert_eq!(out, b"x");
    }

    #[test]
    fn a_closed_alt_screen_segment_is_gone_and_an_open_one_stays() {
        assert_eq!(sanitize(b"a\x1b[?1049hvim\x1b[?1049lb", ALL_OFF), b"ab");
        let live = b"a\x1b[?1049hstill in vim";
        assert_eq!(sanitize(live, ALL_OFF), live);
    }

    /// The buffer's OPENING revision always survives — nothing says the cursor started at column 0.
    #[test]
    fn overprinted_progress_revisions_collapse_to_the_last_one() {
        let out = sanitize(b"go\r\n10%\r50%\r100%\r\n", ALL_OFF);
        // The kept revision keeps the `CR` that opens it — it still has to paint from column 0.
        assert_eq!(out, b"go\r\n\r100%\r\n");
    }

    #[test]
    fn terminal_queries_and_their_echoed_answers_are_stripped() {
        let out = sanitize(b"before\x1b[6n\x1b]11;?\x07after", ALL_OFF);
        assert_eq!(out, b"beforeafter");
    }

    /// The distiller is the one pass a caller can decline.
    #[test]
    fn the_distill_flag_gates_the_line_editor_collapse() {
        let raw = b"\x1b]133;B\x07l\x08ls\x1b]133;C;cmd=ls\x07\r\noutput\r\n";
        let without = sanitize(raw, ALL_OFF);
        let with = sanitize(raw, Options {
            reassert_input_modes: false,
            distill: true,
        });
        assert_ne!(without, with, "the flag must actually do something");
        assert!(with.windows(2).any(|w| w == b"ls"), "{with:?}");
    }

    /// Pass 7 keys on adjacency the earlier passes preserve.
    #[test]
    fn a_prompt_sp_cluster_is_normalised_after_the_earlier_passes_run() {
        let mut raw = b"out\r\n\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m".to_vec();
        raw.extend(std::iter::repeat_n(b' ', 79));
        raw.extend_from_slice(b"\r\x1b]133;A\x07");
        let out = sanitize(&raw, ALL_OFF);
        assert!(!out.contains(&b'%'), "the stray mark must be gone: {out:?}");
        assert!(out.ends_with(b"\x1b[0m\x1b]133;A\x07"), "{out:?}");
    }

    #[test]
    fn an_empty_stream_stays_empty_under_every_flag() {
        for options in [ALL_OFF, Options {
            reassert_input_modes: true,
            distill: true,
        }] {
            assert_eq!(sanitize(b"", options), b"");
        }
    }
}
