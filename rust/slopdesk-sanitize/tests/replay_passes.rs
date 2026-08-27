//! The six byte passes of the scrollback replay transform, pinned against FIELD SHAPES.
//!
//! Every case here came over from the Swift suites that were deleted when the passes moved
//! (`TerminalInputModeStripperTests`, `AltScreenSegmentStripperTests`,
//! `SyncUpdateFrameCollapserTests`, `ScrollbackDistillerTests`, `TerminalQueryStripperTests`,
//! `PromptEOLMarkStripperTests`). The unit tests beside each module cover the rules one at a time;
//! what is here is the other half — the exact byte shapes captured from live sessions (nvim's mode
//! churn, ghostty's query/response set, Claude Code's spinner frames, zsh's `PROMPT_SP` cluster),
//! plus the two exact-byte corpus pins that fail on a single changed output byte.
//!
//! What did NOT come over is the WIRING: that the host's transform actually reaches these passes,
//! in this order, with no env kill switch. Those claims are about Swift and stayed there
//! (`ScrollbackReplayTransformTests.swift`).

use slopdesk_sanitize::sanitize::{Options, sanitize};
use slopdesk_sanitize::{altscreen, distill, inputmode, prompteol, query, syncframe};

/// Compares as text when both sides are UTF-8 — an escape-dense diff is unreadable as `[u8]`.
#[track_caller]
fn same(actual: &[u8], expected: &[u8], what: &str) {
    assert_eq!(
        String::from_utf8_lossy(actual),
        String::from_utf8_lossy(expected),
        "{what}"
    );
}

// ===========================================================================================
// Input modes — replayed history must never arm the client's input reporting.
// ===========================================================================================

/// The reattach-garbage shape from the field: nvim enables mouse + in-band resize + kitty event
/// reporting at its start and disables them megabytes later. BOTH ends go — the replay must not
/// even TRANSIENTLY arm the modes (`?2048h` makes the client emit a size report the instant it is
/// processed; mouse/kitty leak any mid-replay user input).
#[test]
fn balanced_tui_mode_churn_vanishes_entirely() {
    let raw = "$ vi .\r\n\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[?2048h\x1b[>3uEDITOR \
               CONTENT\x1b[<u\x1b[?2048l\x1b[?1006l\x1b[?1002l\x1b[?1049l$ done\r\n";
    let (out, state) = inputmode::strip(raw.as_bytes());
    same(
        &out,
        b"$ vi .\r\n\x1b[?1049hEDITOR CONTENT\x1b[?1049l$ done\r\n",
        "only the alt-screen switch survives",
    );
    assert!(state.is_neutral(), "everything nets to fresh-terminal defaults");
    assert!(state.reassert_sequence().is_empty());
}

/// A session that ends INSIDE a TUI nets to that TUI's modes: the stream is stripped, and the
/// re-assert re-creates exactly the enabled set (+ the kitty stack) so a live `vim` keeps mouse
/// reporting across a cold reattach.
#[test]
fn unbalanced_enables_net_into_the_reassert_sequence() {
    let (out, state) = inputmode::strip(b"\x1b[?1002h\x1b[?1006h\x1b[?2048h\x1b[>3uTUI");
    same(&out, b"TUI", "every enable is stripped");
    assert!(!state.is_neutral());
    same(
        &state.reassert_sequence(),
        b"\x1b[?1002h\x1b[?1006h\x1b[?2048h\x1b[>3u",
        "the net-on set, ascending, kitty last",
    );
}

/// A trailing unmatched reset is stripped and re-asserts nothing — a fresh terminal is already off.
#[test]
fn net_off_modes_reassert_nothing() {
    let (out, state) = inputmode::strip(b"a\x1b[?1003l\x1b[?1000h\x1b[?1000lb");
    same(&out, b"ab", "");
    assert!(state.is_neutral());
}

/// A `DECSET` carrying tracked AND untracked params in one `CSI` (`?1049;2004h` — real) is
/// REWRITTEN: the alt-screen param survives for the replay's rendering, the bracketed-paste param
/// is tracked and removed.
#[test]
fn a_mixed_param_decset_is_rewritten() {
    let (out, state) = inputmode::strip(b"\x1b[?1049;2004hX\x1b[?2004;1049lY");
    same(&out, b"\x1b[?1049hX\x1b[?1049lY", "");
    assert!(state.is_neutral());
}

/// Display-state modes pass through untouched: alt screen, cursor visibility, autowrap,
/// synchronized output. ANSI (non-`?`) `SM`/`RM` and `CSI`s with intermediates are never touched.
#[test]
fn display_modes_and_foreign_csis_pass_through() {
    let kept = b"\x1b[?1049h\x1b[?25l\x1b[?7h\x1b[?2026h\x1b[?2026l\x1b[4h\x1b[2 q\x1b[?1002$p";
    let (out, state) = inputmode::strip(kept);
    same(&out, kept, "");
    assert!(state.is_neutral());
}

/// Kitty pop on an empty stack is a no-op; a pop count covers several entries; `=` mutates the top
/// entry (or the base with an empty stack) with set/or/clear semantics.
#[test]
fn the_kitty_stack_is_simulated_not_just_counted() {
    let (out, state) = inputmode::strip(b"\x1b[<u\x1b[>1u\x1b[>8u\x1b[=3;2u\x1b[<2u\x1b[=2;1uZ");
    same(&out, b"Z", "");
    same(
        &state.reassert_sequence(),
        b"\x1b[=2;1u",
        "the final `=2;1u` lands on the emptied stack's base",
    );
}

/// The kitty-flags QUERY (`CSI ? u`) is the query pass's business — this one keeps it.
#[test]
fn the_kitty_query_belongs_to_the_other_pass() {
    let (out, _) = inputmode::strip(b"a\x1b[?ub");
    same(&out, b"a\x1b[?ub", "");
}

/// String-sequence bodies are opaque: an embedded mode-set is neither stripped nor tracked.
/// Truncated trailing sequences pass through (a ring head-cut).
#[test]
fn string_bodies_are_opaque_and_truncation_passes_through() {
    let dcs = b"\x1bPq#0;\x1b[?1002h#\x1b\\";
    let (out, state) = inputmode::strip(dcs);
    same(&out, dcs, "");
    assert!(state.is_neutral());

    let (out, _) = inputmode::strip(b"tail\x1b[?100");
    same(&out, b"tail\x1b[?100", "");
    let (out, _) = inputmode::strip(b"tail\x1b");
    same(&out, b"tail\x1b", "");
}

/// A raw `?1000s … ?1000r` pair replayed verbatim re-arms mouse reporting (restore brings the saved
/// ON back) — the same garbage-input class, through the save/restore door. Both are stripped AND
/// simulated, so the net state lands where a real terminal executing the raw stream would have.
#[test]
fn the_xtsave_restore_door_is_stripped_and_tracked() {
    let (out, state) = inputmode::strip(b"\x1b[?1000h\x1b[?1000s\x1b[?1000l\x1b[?1000rTUI");
    same(&out, b"TUI", "save/restore must be stripped like set/reset");
    same(
        &state.reassert_sequence(),
        b"\x1b[?1000h",
        "restore re-applies the value saved while ON",
    );
}

/// `XTRESTORE` with no prior save restores the initial (fresh-terminal) value — off.
#[test]
fn an_xtrestore_without_a_save_nets_off() {
    let (out, state) = inputmode::strip(b"\x1b[?1000h\x1b[?1000rX");
    same(&out, b"X", "");
    assert!(
        state.is_neutral(),
        "restore-without-save yields the initial value"
    );
}

/// Mixed tracked/untracked params rewrite, and the NON-`?` finals stay untouched: bare `r` is
/// DECSTBM (scroll region), bare `s` is SCOSC/DECSLRM — display state the replay needs.
#[test]
fn a_mixed_param_save_is_rewritten_and_decstbm_is_kept() {
    let (out, state) = inputmode::strip(b"\x1b[?1049;1000sX\x1b[2;24rY\x1b[sZ");
    same(&out, b"\x1b[?1049sX\x1b[2;24rY\x1b[sZ", "");
    assert!(state.is_neutral());
}

/// `final_state` answers what `strip` would have reported, without building the stripped copy —
/// the compose path asks only this question.
#[test]
fn final_state_agrees_with_strip_on_the_field_shapes() {
    for raw in [
        &b"\x1b[?1002h\x1b[?1006h\x1b[?2048h\x1b[>3uTUI"[..],
        &b"\x1b[?1000h\x1b[?1000s\x1b[?1000l\x1b[?1000rTUI"[..],
        &b"\x1b[<u\x1b[>1u\x1b[>8u\x1b[=3;2u\x1b[<2u\x1b[=2;1uZ"[..],
        &b"$ vi .\r\n\x1b[?1049h\x1b[?1002h\x1b[>3uEDIT\x1b[<u\x1b[?1002l\x1b[?1049l"[..],
    ] {
        let (_, stripped) = inputmode::strip(raw);
        same(
            &inputmode::final_state(raw).reassert_sequence(),
            &stripped.reassert_sequence(),
            "the two entry points must not drift",
        );
    }
}

// ===========================================================================================
// Alt screen — a closed TUI screen contributes nothing; an open one IS the live repaint.
// ===========================================================================================

/// The field shape: an exited vim session — enter, megabytes of drawing, leave — vanishes entirely
/// and the surrounding transcript joins seamlessly.
#[test]
fn a_closed_segment_is_dropped_whole() {
    same(
        &altscreen::strip(b"$ vi .\r\n\x1b[?1049hTUI DRAWING\x1b[2J\x1b[H\x1b[?1049l$ done\r\n"),
        b"$ vi .\r\n$ done\r\n",
        "",
    );
}

/// Only the LAST (open) segment survives when earlier ones closed.
#[test]
fn earlier_closed_segments_drop_even_with_a_live_tail() {
    same(
        &altscreen::strip(b"a\x1b[?1049hOLD\x1b[?1049lb\x1b[?1049hLIVE"),
        b"ab\x1b[?1049hLIVE",
        "",
    );
}

/// A segment opened by one variant closes on ANY of them — the segment is the state, not the mode
/// number — and an alt-enter inside an open segment is interior.
#[test]
fn the_variant_modes_open_and_close_one_shared_segment() {
    same(
        &altscreen::strip(b"x\x1b[?47hDRAW\x1b[?1049hMORE\x1b[?1047ly"),
        b"xy",
        "",
    );
}

/// Mixed-param `DECSET`/`DECRST` keep their non-alt params outside the dropped segment (`?1049;12h`
/// sets blink globally — that survives even though the screen switch is cut).
#[test]
fn mixed_params_survive_outside_the_segment() {
    same(
        &altscreen::strip(b"a\x1b[?1049;12hDRAW\x1b[?1049;25lb"),
        b"a\x1b[?12h\x1b[?25lb",
        "",
    );
}

/// An embedded `?1049l` inside a `DCS` body must not close the segment; string sequences outside a
/// segment pass through whole; truncated trailing sequences pass through.
#[test]
fn string_bodies_are_opaque_to_the_segmenter() {
    same(
        &altscreen::strip(b"a\x1b[?1049hX\x1bPq##\x1b[?1049l##\x1b\\Y\x1b[?1049lb"),
        b"ab",
        "",
    );
    let osc = b"a\x1b]0;title\x07b";
    same(&altscreen::strip(osc), osc, "");
    same(&altscreen::strip(b"tail\x1b[?10"), b"tail\x1b[?10", "");
}

// ===========================================================================================
// Synchronized-output frames — the inline-TUI churn pass.
// ===========================================================================================

const BEGIN: &str = "\x1b[?2026h";
const END: &str = "\x1b[?2026l";

/// The Claude Code shape: absolute-anchored spinner repaints with no LF. All but the LAST frame
/// drop; surrounding plain output is untouched.
#[test]
fn static_repaint_frames_drop_and_the_last_one_is_kept() {
    let frame = |glyph: &str| {
        format!("{BEGIN}\x1b[?25l\x1b[H\r\x1b[40B\x1b[38;2;1;2;3m{glyph}\x1b[46;1H\x1b[?25h{END}")
    };
    let input = format!("before\r\n{}{}{}after", frame("A"), frame("B"), frame("C"));
    let expected = format!("before\r\n{}after", frame("C"));
    same(&syncframe::collapse(input.as_bytes()), expected.as_bytes(), "");
}

/// A frame that scrolls content into history (LF) survives even mid-stream.
#[test]
fn a_scroll_bearing_frame_survives() {
    let quiet = format!("{BEGIN}\x1b[H\x1b[2Kspin{END}");
    let scrolls = format!("{BEGIN}\x1b[Hline one\r\nline two\r\n{END}");
    let last = format!("{BEGIN}\x1b[H\x1b[2Ktick{END}");
    let input = format!("{quiet}{scrolls}{last}");
    same(
        &syncframe::collapse(input.as_bytes()),
        format!("{scrolls}{last}").as_bytes(),
        "",
    );
}

/// `IND` / `NEL` / `RI` / `RIS` two-byte escapes force a keep (scroll / global reset effects).
#[test]
fn index_and_reset_escapes_keep_their_frame() {
    for escape in ["\x1bD", "\x1bE", "\x1bM", "\x1bc"] {
        let special = format!("{BEGIN}x{escape}y{END}");
        let last = format!("{BEGIN}z{END}");
        let input = format!("{special}{last}");
        same(
            &syncframe::collapse(input.as_bytes()),
            input.as_bytes(),
            "a frame containing a scroll/reset escape must survive",
        );
    }
}

/// `CSI S`/`T` (scroll), `ED 2`/`3` and DECSTBM force a keep; the churn's own erases do not.
#[test]
fn scroll_region_and_full_clear_csis_keep_their_frame() {
    for kept in ["\x1b[2S", "\x1b[T", "\x1b[2J", "\x1b[3J", "\x1b[1;20r"] {
        let special = format!("{BEGIN}x{kept}y{END}");
        let last = format!("{BEGIN}z{END}");
        let input = format!("{special}{last}");
        same(&syncframe::collapse(input.as_bytes()), input.as_bytes(), "");
    }
    let churn = format!("{BEGIN}\x1b[2K\x1b[J\x1b[0J\x1b[1J{END}");
    let last = format!("{BEGIN}z{END}");
    let input = format!("{churn}{last}");
    same(&syncframe::collapse(input.as_bytes()), last.as_bytes(), "");
}

/// An alt-screen transition inside a frame must survive — the segmenter and the live TUI's screen
/// switch both depend on it.
#[test]
fn an_alt_screen_transition_keeps_its_frame() {
    for mode in ["\x1b[?1049h", "\x1b[?1049l", "\x1b[?47h", "\x1b[?1047l"] {
        let input = format!("{BEGIN}{mode}draw{END}{BEGIN}z{END}");
        same(&syncframe::collapse(input.as_bytes()), input.as_bytes(), "");
    }
}

/// An `OSC 133;` prompt mark inside a frame anchors the distiller — keep. Title churn does not.
#[test]
fn a_prompt_mark_keeps_its_frame_and_a_title_does_not() {
    let marked = format!("{BEGIN}\x1b]133;A\x07prompt{END}");
    let titled = format!("{BEGIN}\x1b]0;spinner tick\x07\x1b[H.{END}");
    let last = format!("{BEGIN}z{END}");
    let input = format!("{marked}{titled}{last}");
    same(
        &syncframe::collapse(input.as_bytes()),
        format!("{marked}{last}").as_bytes(),
        "",
    );
}

/// Inter-frame bytes (title updates, charset selects) survive even when both neighbours drop.
#[test]
fn inter_frame_bytes_survive_their_neighbours() {
    let title = "\x1b]0;⠐ working\x07";
    let last = format!("{BEGIN}\x1b[Hc{END}");
    let input = format!("{BEGIN}\x1b[Ha{END}{title}{BEGIN}\x1b[Hb{END}{last}");
    same(
        &syncframe::collapse(input.as_bytes()),
        format!("{title}{last}").as_bytes(),
        "",
    );
}

/// A truncated trailing `CSI` (a chunk cut mid-sequence) passes through unchanged.
#[test]
fn a_truncated_trailing_csi_passes_through() {
    let input = format!("{BEGIN}\x1b[Ha{END}tail\x1b[38;5");
    same(&syncframe::collapse(input.as_bytes()), input.as_bytes(), "");
}

/// Real-shape volume guard: thousands of spinner frames collapse to just the last one.
#[test]
fn spinner_churn_collapses_in_bulk() {
    let mut input = String::from("prompt$ claude\r\n");
    for i in 0..2000 {
        use std::fmt::Write as _;
        let _ = write!(
            input,
            "{BEGIN}\x1b[?25l\x1b[H\r\x1b[40B tick {}\x1b[46;1H\x1b[?25h{END}",
            i % 10
        );
    }
    let out = syncframe::collapse(input.as_bytes());
    let text = String::from_utf8_lossy(&out);
    assert!(text.starts_with("prompt$ claude\r\n"));
    assert!(text.contains("tick 9"), "the last frame is kept");
    assert!(
        out.len() < 200,
        "churn collapsed to the final frame: {} bytes",
        out.len()
    );
}

// ===========================================================================================
// The distiller — B→C line-editor churn collapses to the committed command.
// ===========================================================================================

fn mark(body: &str) -> String {
    format!("\x1b]133;{body}\x07")
}

/// `ESC ] 133 ; <body> ESC \` — the ST-terminated spelling of the same mark.
fn mark_st(body: &str) -> String {
    format!("\x1b]133;{body}\x1b\\")
}

/// The prompt (A→B) is kept, the B→C editing region is dropped and replaced by the `133;E` command
/// text + CRLF, the C→D output is kept verbatim. The `133;A` prompt mark is RE-EMITTED — libghostty
/// counts prompts by it, so cold-reattach block jumps still anchor.
#[test]
fn a_command_span_collapses_to_the_committed_command() {
    let input = format!(
        "{}~/proj ❯ {}ggii...garbage-echo...{}{}On branch main\n{}",
        mark("A"),
        mark("B"),
        mark("E;git status"),
        mark("C"),
        mark("D;0")
    );
    let expected = format!("{}~/proj ❯ git status\r\nOn branch main\n", mark("A"));
    same(&distill::distill(input.as_bytes()), expected.as_bytes(), "");
}

/// A tab-completion menu drawn inside B→C — newlines, cursor motion, the clear — all goes.
#[test]
fn a_tab_completion_menu_is_dropped_with_the_rest_of_the_span() {
    let menu = "git ch\n  checkout  cherry  cherry-pick\x1b[2A\x1b[J";
    let input = format!(
        "{}$ {}{menu}{}{}Switched to branch 'main'\n{}",
        mark("A"),
        mark("B"),
        mark("E;git checkout main"),
        mark("C"),
        mark("D;0")
    );
    let expected = format!("{}$ git checkout main\r\nSwitched to branch 'main'\n", mark("A"));
    same(&distill::distill(input.as_bytes()), expected.as_bytes(), "");
}

/// A B→C span with NO `133;E`: the raw editing bytes pass through verbatim — never lost, never
/// invented. Byte-identical to the pre-distiller replay for a non-shim shell.
#[test]
fn a_span_with_no_committed_command_falls_back_to_verbatim() {
    let input = format!(
        "{}$ {}ls -la\r\n{}total 0\n{}",
        mark("A"),
        mark("B"),
        mark("C"),
        mark("D;0")
    );
    let expected = format!("{}$ ls -la\r\ntotal 0\n", mark("A"));
    same(&distill::distill(input.as_bytes()), expected.as_bytes(), "");
}

/// A re-fired `B` (a zle reset-prompt redraw) discards the partial bytes captured so far.
#[test]
fn a_prompt_redraw_resets_the_input_buffer() {
    let input = format!(
        "{}$ {}par{}partial-echo{}{}ok\n{}",
        mark("A"),
        mark("B"),
        mark("B"),
        mark("E;make test"),
        mark("C"),
        mark("D;0")
    );
    same(
        &distill::distill(input.as_bytes()),
        format!("{}$ make test\r\nok\n", mark("A")).as_bytes(),
        "",
    );
}

/// The shim escapes `;`, `\`, ESC, BEL, CR, LF as `\xNN`; the mark may close with ST instead of
/// BEL.
#[test]
fn the_committed_command_is_unescaped_under_either_terminator() {
    let input = format!(
        "{}$ {}z{}{}a;b\n{}",
        mark("A"),
        mark("B"),
        mark("E;echo a\\x3bb"),
        mark("C"),
        mark("D;0")
    );
    same(
        &distill::distill(input.as_bytes()),
        format!("{}$ echo a;b\r\na;b\n", mark("A")).as_bytes(),
        "",
    );

    let st = format!(
        "{}$ {}w{}{}Mon\n{}",
        mark_st("A"),
        mark_st("B"),
        mark_st("E;date"),
        mark_st("C"),
        mark_st("D;0")
    );
    same(
        &distill::distill(st.as_bytes()),
        format!("{}$ date\r\nMon\n", mark_st("A")).as_bytes(),
        "",
    );
}

/// An empty-Enter line: `B`, the accept-line `\r\n` echo, then precmd's `D;0` with no `E`/`C`. The
/// buffered `\r\n` must be FLUSHED on the `D` — else consecutive prompts jam onto one line.
#[test]
fn an_empty_enter_span_is_flushed_on_the_d_mark() {
    let input = format!(
        "{}~ ❯ {}\r\n{}{}~ ❯ ",
        mark("A"),
        mark("B"),
        mark("D;0"),
        mark("A")
    );
    let expected = format!("{}~ ❯ \r\n{}~ ❯ ", mark("A"), mark("A"));
    same(&distill::distill(input.as_bytes()), expected.as_bytes(), "");
}

/// A typed-then-Ctrl-C'd line closed directly by the NEXT prompt's `A`: the echo must survive
/// rather than vanish and concatenate the two prompts.
#[test]
fn a_ctrl_c_span_is_flushed_on_the_closing_a_mark() {
    let input = format!("{}$ {}sleep 99^C\r\n{}$ ", mark("A"), mark("B"), mark("A"));
    let expected = format!("{}$ sleep 99^C\r\n{}$ ", mark("A"), mark("A"));
    same(&distill::distill(input.as_bytes()), expected.as_bytes(), "");
}

/// A `133;C`-looking substring inside a non-133 `OSC` is that `OSC`'s payload, not a mark.
#[test]
fn an_embedded_133_inside_a_title_does_not_segment() {
    let input = b"\x1b]0;prompt 133;C here\x07visible";
    same(&distill::distill(input), input, "");
}

/// A `DCS` body containing `ESC ] 133 ; B` must NOT flip the distiller into input suppression:
/// without the string-consume state the embedded `B` orphans the real output and the `D` drops it.
#[test]
fn a_dcs_body_cannot_spoof_a_mark() {
    let input = format!("\x1bP\x1b]133;B\x07REALOUTPUT\x1b\\{}", mark("D;0"));
    same(
        &distill::distill(input.as_bytes()),
        b"\x1bP\x1b]133;B\x07REALOUTPUT\x1b\\",
        "the body is opaque; only the trailing real mark is consumed",
    );
}

/// A B→C span larger than the fallback cap overflows to passthrough — a giant editing span will not
/// collapse cleanly, and is never dropped.
#[test]
fn an_oversized_input_span_falls_back_to_passthrough() {
    let big = "x".repeat(300 * 1024);
    let input = format!(
        "{}$ {}{big}{}{}out\n{}",
        mark("A"),
        mark("B"),
        mark("E;huge"),
        mark("C"),
        mark("D;0")
    );
    let out = distill::distill(input.as_bytes());
    let text = String::from_utf8_lossy(&out);
    assert!(text.contains(&big), "the oversized span passes through verbatim");
    assert!(text.ends_with("out\n"));
}

/// EXACT-BYTE pin over a nasty corpus, expected output constructed by hand from the documented
/// semantics: idle verbatim, `A` re-emitted, B→C collapsed to the `E` command + CRLF, C→D output
/// verbatim including every control sequence, `B`/`E`/`C`/`D` zero-width, a no-`E` span verbatim, a
/// trailing broken escape flushed. Any refactor of the byte loop that changes ONE output byte fails
/// here. Covers SGR-heavy output, `OSC`/`DCS` query bytes riding the OUTPUT span (the distiller
/// must NOT strip them — that is the query pass's job), an `APC` body with an embedded fake `133`
/// mark, raw multi-byte UTF-8, and `\xNN` command unescaping.
#[test]
fn the_distiller_nasty_corpus_is_pinned_byte_for_byte() {
    let pre = "…mid-stream tail ✓ \x1b[31mred\x1b[0m\n";
    let prompt = "\x1b[1;32m~/proj\x1b[0m ❯ ";
    let churn = "g\x1b[90mit statu\x1b[0m\rgit status\x1b[K\t\nmenu a b c\x1b[2A\x1b[J";
    let output = "\x1b[01;34mdir\x1b[0m tệp ✓\n\
                  \x1b]8;;http://x\x1b\\L\x1b]8;;\x1b\\\
                  \x1bP+q544e\x1b\\\
                  \x1b_G\x1b]133;B;fake\x1b\\real tail\n";
    let post = "after\n";
    let trailing = "\x1b]0;unterminated";

    let input = format!(
        "{pre}{}{prompt}{}{churn}{}{}{output}{}{}$ {}ls -l\r\n{}total 0\n{}{post}{trailing}",
        mark("A"),
        mark("B"),
        mark("E;echo a\\x3bb"),
        mark("C"),
        mark("D;0"),
        mark("A"),
        mark("B"),
        mark("C"),
        mark("D;1")
    );
    let expected = format!(
        "{pre}{}{prompt}echo a;b\r\n{output}{}$ ls -l\r\ntotal 0\n{post}{trailing}",
        mark("A"),
        mark("A")
    );
    same(&distill::distill(input.as_bytes()), expected.as_bytes(), "");
}

// ===========================================================================================
// Queries — replayed history must never make the client ANSWER a prior life's questions.
// ===========================================================================================

/// The exact query set whose ANSWERS made up the reported garbage: `OSC 11` background probe, DA1,
/// XTVERSION, DECRQM 2026. Interleaved with real output — only the output survives.
#[test]
fn the_prompt_startup_query_set_vanishes() {
    same(
        &query::strip(b"PROMPT>\x1b]11;?\x07\x1b[c\x1b[>0q\x1b[?2026$p\x1b[6n$ sleep 300\r\n"),
        b"PROMPT>$ sleep 300\r\n",
        "",
    );
}

/// Echoed RESPONSES already recorded into a poisoned transcript — the garbage itself — go too, so
/// an already-polluted journal renders clean on its next restore.
#[test]
fn echoed_responses_are_stripped_with_their_queries() {
    let poisoned = b"ok\x1b]11;rgb:2d2d/2a2a/2e2e\x07\x1b[?62;22;52c\
                     \x1bP>|ghostty 1.3.1-merge\x1b\\\x1b[?2026;2$y\x1b[24;80Rdone";
    same(&query::strip(poisoned), b"okdone", "");
}

#[test]
fn every_remaining_query_form_is_covered() {
    for (raw, what) in [
        (&b"a\x1b[5nb"[..], "DSR status query"),
        (&b"a\x1b[=0cb"[..], "DA3"),
        (&b"a\x1b[?ub"[..], "kitty keyboard-flags query"),
        (&b"a\x1b[14tb"[..], "window pixel-size report request"),
        (&b"a\x1b[18tb"[..], "text-area size report request"),
        (&b"a\x1b[21tb"[..], "title report request"),
        (&b"a\x1bZb"[..], "DECID"),
        (&b"a\x1bP+q544e\x1b\\b"[..], "XTGETTCAP"),
        (&b"a\x1bP$qm\x1b\\b"[..], "DECRQSS"),
        (&b"a\x1b]52;c;?\x07b"[..], "OSC 52 clipboard query"),
        (&b"a\x1b]4;1;?\x07b"[..], "OSC 4 palette query"),
        (&b"a\x1bP1$rm\x1b\\b"[..], "DECRQSS hit response"),
        (&b"a\x1bP0$r\x1b\\b"[..], "DECRQSS miss response"),
        (&b"a\x1bP1+r524742=3838\x1b\\b"[..], "XTGETTCAP hit response"),
        (&b"a\x1bP0+r\x1b\\b"[..], "XTGETTCAP miss response"),
        (&b"a\x1b]21;foreground=?\x07b"[..], "OSC 21 kitty colour query"),
        (&b"a\x1b]21;foreground=rgb:aa/bb/cc\x1b\\b"[..], "OSC 21 response"),
        (&b"a\x1b]11;rgb:1111/2222/3333\x1b\\b"[..], "OSC 11 set (ST)"),
        (&b"a\x1b]10;#ffffff\x07b"[..], "OSC 10 set"),
        (&b"a\x1b]104\x07b"[..], "palette reset"),
    ] {
        same(&query::strip(raw), b"ab", what);
    }
}

#[test]
fn rendering_sequences_survive_verbatim() {
    for kept in [
        "plain text với tiếng Việt ✓".as_bytes(),
        &b"\x1b[31mred\x1b[0m"[..],
        &b"\x1b[?2004h\x1b[?2004l"[..],
        &b"\x1b[?1049h\x1b[?1049l"[..],
        &b"\x1b[2 q"[..],
        &b"\x1b[!p"[..],
        &b"\x1b[22;0t\x1b[23;0t"[..],
        &b"\x1b]0;title\x07"[..],
        &b"\x1b]133;A\x07\x1b]133;B\x07"[..],
        &b"\x1b]7;file://host/tmp\x1b\\"[..],
        &b"\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\"[..],
        &b"\x1b[1;5H\x1b[2J"[..],
        &b"\x1b(B\x1b="[..],
        &b"abc\x1b["[..],
        &b"abc\x1b]11;rgb:11"[..],
        &b"abc\x1b"[..],
        // An `ESC[` embedded in a DCS body must not be parsed as a CSI.
        &b"a\x1bPq#0;2;0;0;0\x1b[c-not-a-query\x1b\\b"[..],
    ] {
        same(&query::strip(kept), kept, "must pass through verbatim");
    }
}

/// EXACT-BYTE pin over a representative nasty corpus: every piece is tagged kept/stripped at
/// construction time and the expected output is the concatenation of the KEPT pieces — so any
/// internal refactor that changes a single output byte or a single strip decision fails here.
#[test]
fn the_query_nasty_corpus_is_pinned_byte_for_byte() {
    // (piece, keep) — keep ⇒ the piece must appear VERBATIM in the output.
    let pieces: [(&str, bool); 51] = [
        ("plain ASCII text 123\r\n", true),
        ("\x1b[c", false),                                             // DA1 query
        ("tiếng Việt — ✓ 日本語\n", true),                             // raw multi-byte UTF-8
        ("\x1b[?62;22;52c", false),                                    // echoed DA1 response
        ("\x1b[1;38;5;196mR\x1b[0m\x1b[38;2;10;20;30mT\x1b[m", true),  // SGR heavy
        ("\x1b[>0c", false),                                           // DA2 query
        ("\x1b[?2004h\x1b[?2004l\x1b[?1049h", true),                   // mode set/reset
        ("\x1b[5n", false),                                            // DSR status query
        ("\x1b[6n", false),                                            // CPR request
        ("\x1b[?6n", false),                                           // DEC CPR request
        ("\x1b[0n", false),                                            // DSR response
        ("\x1b[24;80R", false),                                        // echoed CPR response
        ("\x1b[2 q", true),                                            // DECSCUSR (SP intermediate)
        ("\x1b[x", false),                                             // DECREQTPARM query
        ("\x1b[2;1;1;120;120;1;0x", false),                            // DECREQTPARM response
        ("\x1b[!p", true),                                             // DECSTR (no $)
        ("\x1b[?2026$p", false),                                       // DECRQM query
        ("\x1b[?2026;2$y", false),                                     // echoed DECRPM response
        ("\x1b[1;1;10;10$z", true),                                    // DECERA — $ but kept final
        ("\x1b[>0q", false),                                           // XTVERSION query
        ("\x1b[>1u", true),                                            // kitty keyboard push
        ("\x1b[?u", false),                                            // kitty flags query
        ("\x1b[8;24;80t", true),                                       // resize — op 8 is no report
        ("\x1b[14t", false),                                           // window pixel-size request
        ("\x1b[18t", false),                                           // text-area size request
        ("\x1b[21;0t", false),                                         // title report request
        ("\x1b[22;0t\x1b[23;0t", true),                                // title push/pop
        ("\x1bZ", false),                                              // DECID
        ("\x1b]0;title — nasty ;; body\x07", true),                    // OSC title
        ("\x1b]11;?\x07", false),                                      // OSC 11 query
        ("\x1b]10;#ffffff\x07", false),                                // OSC 10 set
        ("\x1b]4;1;?\x07", false),                                     // palette query
        ("\x1b]52;c;?\x07", false),                                    // clipboard query
        ("\x1b]104\x07", false),                                       // palette reset
        ("\x1b]112\x07", false),                                       // cursor-colour reset
        ("\x1b]21;foreground=?\x07", false),                           // OSC 21 query
        ("\x1b]21;foreground=rgb:aa/bb/cc\x1b\\", false),              // OSC 21 response (ST)
        ("\x1b]133;A\x07\x1b]133;B\x07", true),                        // OSC 133 marks
        ("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\", true), // hyperlink
        ("\x1bPq#0;2;0;0;0~~\x1b[c~~\x1b\\", true),                    // sixel DCS, CSI swallowed
        ("\x1bP+q544e\x1b\\", false),                                  // XTGETTCAP query
        ("\x1bP$qm\x1b\\", false),                                     // DECRQSS query
        ("\x1bP>|ghostty 1.3.1\x1b\\", false),                         // echoed XTVERSION response
        ("\x1bP1$rm\x1b\\", false),                                    // DECRQSS hit response
        ("\x1bP0$r\x1b\\", false),                                     // DECRQSS miss response
        ("\x1bP1+r524742=3838\x1b\\", false),                          // XTGETTCAP hit response
        ("\x1bP0+r\x1b\\", false),                                     // XTGETTCAP miss response
        ("\x1b_Gf=100;payload\x1b\\", true),                           // APC kept whole
        ("\x1b(B\x1b=\x1bM", true),                                    // 2-byte ESC pairs
        ("\x1b[1;5H\x1b[2J\x1b[0K", true),                             // cursor move / clears
        ("tail\x1b[38;5", true),                                       // truncated CSI — must be LAST
    ];
    let input: String = pieces.iter().map(|(piece, _)| *piece).collect();
    let expected: String = pieces
        .iter()
        .filter_map(|(piece, keep)| keep.then_some(*piece))
        .collect();
    same(&query::strip(input.as_bytes()), expected.as_bytes(), "");
}

// ===========================================================================================
// zsh PROMPT_SP clusters — the stray-`%`-on-reconnect bug.
// ===========================================================================================

/// The captured mark bytes: bold+standout `%`, standout-off, bold, reset.
const MARK: &str = "\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m";
/// The captured tail: `PROMPT_CR` + the anti-xenl ` \r` tick.
const TAIL: &str = "\r \r";
const D_MARK: &str = "\x1b]133;D;0\x07";
const A_MARK: &str = "\x1b]133;A\x07";
/// Every replacement re-asserts the `SGR` reset the swallowed cluster ended with.
const RESET: &str = "\x1b[0m";

fn cluster() -> String {
    format!("{MARK}{}{TAIL}", " ".repeat(121))
}

#[test]
fn a_column_zero_cluster_before_either_anchor_is_excised() {
    let input = format!("ls output\r\n{}{D_MARK}{A_MARK}prompt", cluster());
    same(
        &prompteol::strip(input.as_bytes()),
        format!("ls output\r\n{RESET}{D_MARK}{A_MARK}prompt").as_bytes(),
        "a cluster at column 0 renders invisibly live — replay carries only the state reset",
    );
    // Post-distill shape: the distiller consumes `133;D`, so the cluster abuts `133;A`.
    let input = format!("ls output\r\n{}{A_MARK}prompt", cluster());
    same(
        &prompteol::strip(input.as_bytes()),
        format!("ls output\r\n{RESET}{A_MARK}prompt").as_bytes(),
        "",
    );
    // First prompt of a session — preprompt fires before anything else was written.
    let input = format!("{}{A_MARK}prompt", cluster());
    same(
        &prompteol::strip(input.as_bytes()),
        format!("{RESET}{A_MARK}prompt").as_bytes(),
        "",
    );
}

/// Each of these interposed runs is captured from a live journal, and each is zero-width: the walk
/// must look through all of them to the newline behind.
#[test]
fn the_captured_zero_width_epilogues_still_read_as_column_zero() {
    for (prefix, what) in [
        ("cd ~\r\n\x1b[0 q", "DECSCUSR after the CRLF (the `cd ~` shape)"),
        (
            "done\r\n\x1b[2m\x1b[22m\x1b[?25h",
            "SGR pair + cursor-show (the claude-exit shape)",
        ),
        (
            "ok.\r\n\x1b[0 q\x1b[?2026l\x1b[?7h",
            "DECSCUSR + sync-end + autowrap (the inline-TUI epilogue)",
        ),
        (
            "tail\r\x1b[J\x1b[?25h",
            "CR + erase-below + cursor-show (the prompt redraw)",
        ),
        (
            "row\n\x1b[G\n\x1b[G\x1b[13A\x1b[G",
            "CUU + a bare CHA — direct column-1 proof",
        ),
        ("x\r\n\x1b[3A", "CUU moves rows, never columns"),
    ] {
        let input = format!("{prefix}{}{A_MARK}", cluster());
        same(
            &prompteol::strip(input.as_bytes()),
            format!("{prefix}{RESET}{A_MARK}").as_bytes(),
            what,
        );
    }
}

/// Each of these ends the walk at an unknowable column, where the safe answer is the mid-line
/// `CRLF` — a spare newline, never an overprinted line.
#[test]
fn an_unknowable_column_takes_the_safe_answer() {
    for (prefix, what) in [
        ("x\r\n\x1b[5G", "a CHA to another column"),
        ("x\r\n\x1b[24D", "CUB changes the column by a relative amount"),
        ("x\r\n\x1b[?1049l", "an alt-screen switch restores a SAVED cursor"),
        (
            "x\r\n\x1b[4h",
            "ANSI SM (no `?`) is not in the looked-through set",
        ),
    ] {
        let input = format!("{prefix}{}{A_MARK}", cluster());
        same(
            &prompteol::strip(input.as_bytes()),
            format!("{prefix}{RESET}\r\n{A_MARK}").as_bytes(),
            what,
        );
    }
}

/// Mid-line — an empty Enter, a Ctrl-C at the prompt, a genuine partial output line: the live
/// render moved the prompt to a fresh line, so the replacement must too.
#[test]
fn a_mid_line_cluster_becomes_a_reset_plus_crlf() {
    let input = format!("partial{}{D_MARK}{A_MARK}prompt", cluster());
    same(
        &prompteol::strip(input.as_bytes()),
        format!("partial{RESET}\r\n{D_MARK}{A_MARK}prompt").as_bytes(),
        "the partial line survives on its own line; the prompt starts at column 0; no mark",
    );

    // The captured empty-Enter shape: prompt tail + `133;B` + EL, then the cluster.
    let prompt_tail = "\u{2AB}\x1b[0m \x1b]133;B\x07\x1b[K";
    let input = format!("{prompt_tail}{}{D_MARK}{A_MARK}", cluster());
    same(
        &prompteol::strip(input.as_bytes()),
        format!("{prompt_tail}{RESET}\r\n{D_MARK}{A_MARK}").as_bytes(),
        "",
    );
}

#[test]
fn a_root_shells_hash_mark_is_handled_like_the_percent() {
    let root = "\x1b[1m\x1b[7m#\x1b[27m\x1b[1m\x1b[0m";
    let input = format!("out\r\n{root}{}\r \r{A_MARK}", " ".repeat(79));
    same(
        &prompteol::strip(input.as_bytes()),
        format!("out\r\n{RESET}{A_MARK}").as_bytes(),
        "",
    );
}

/// The two-sided `SGR` requirement is the false-positive guard: a plain `%` + fill + `CR` abutting
/// the anchor is REAL command output whenever the session `unsetopt PROMPT_SP` (the pad-to-clear
/// progress idiom). The dumb-`TERM` bare mark is the price.
#[test]
fn user_output_that_merely_looks_like_a_cluster_is_never_touched() {
    for (input, what) in [
        (
            format!("Build: 100%{}\r{D_MARK}{A_MARK}PS1 ", " ".repeat(20)),
            "plain-text % before the anchor is user output",
        ),
        (
            format!("\x1b[32mBuild: 100%\x1b[0m{}\r{D_MARK}", " ".repeat(20)),
            "a coloured progress line satisfies only the suffix side",
        ),
        (
            format!("x%   \r{A_MARK}"),
            "a <8-space run is regular content, not PROMPT_SP fill",
        ),
        (
            format!("x\r\n{}plain text, no mark", cluster()),
            "only clusters abutting 133;D/133;A are zsh preprompt output",
        ),
        (
            format!("x\r\nZ{}\r{A_MARK}", " ".repeat(79)),
            "a non-mark character is not a mark",
        ),
        (
            format!("x\r\n%{}{A_MARK}", " ".repeat(79)),
            "spaces without a trailing CR are not a fill",
        ),
        (
            format!("x\r\n{}\x1b]133;C\x07", cluster()),
            "other OSC 133 subcommands are not anchors",
        ),
        ("hello world".to_owned(), "plain text"),
    ] {
        same(&prompteol::strip(input.as_bytes()), input.as_bytes(), what);
    }
}

/// The prefix walk swallows a reset the COMMAND wrote right before the cluster; the emitted
/// replacement reset re-establishes the exact post-cluster live state, so the command's colour can
/// never bleed into the replayed prompt.
#[test]
fn a_commands_trailing_reset_cannot_bleed_colour_into_the_prompt() {
    let input = format!("\x1b[31mred\x1b[0m{}{D_MARK}{A_MARK}PS1 ", cluster());
    same(
        &prompteol::strip(input.as_bytes()),
        format!("\x1b[31mred{RESET}\r\n{D_MARK}{A_MARK}PS1 ").as_bytes(),
        "swallowed user SGRs are replaced by an equivalent reset before the anchor",
    );
}

#[test]
fn every_prompt_cycle_in_a_transcript_is_cleaned_and_the_pass_is_idempotent() {
    let block = format!("output line\r\n{}{D_MARK}{A_MARK}PS1 \u{2AB} ", cluster());
    let input = block.repeat(3);
    let expected = format!("output line\r\n{RESET}{D_MARK}{A_MARK}PS1 \u{2AB} ").repeat(3);
    same(&prompteol::strip(input.as_bytes()), expected.as_bytes(), "");

    let mixed = format!("a\r\n{}{D_MARK}mid{}{A_MARK}p", cluster(), cluster());
    let once = prompteol::strip(mixed.as_bytes());
    same(&prompteol::strip(&once), &once, "a second pass changes nothing");
}

// ===========================================================================================
// The whole chain — the end-to-end claims that used to run through the Swift transform.
// ===========================================================================================

/// The production composition over a full captured-shape prompt cycle: no fill run, no stray mark,
/// and the `133;A` anchor still there (cold-reattach block jumps count by it).
#[test]
fn the_chain_removes_a_captured_prompt_cycle_whole() {
    let input = format!("ls output\r\n{}{D_MARK}{A_MARK}PS1 ", cluster());
    let out = sanitize(input.as_bytes(), Options {
        reassert_input_modes: false,
        distill: true,
    });
    let text = String::from_utf8_lossy(&out);
    assert!(
        !text.contains("       "),
        "the COLUMNS-wide fill must not survive: {text:?}"
    );
    assert!(
        !text.contains("\x1b[7m%"),
        "the standout mark must not survive: {text:?}"
    );
    assert!(
        text.contains(A_MARK),
        "the 133;A prompt anchor must survive: {text:?}"
    );
}

/// A transcript whose TUI exited replays with no mode churn and no alt-screen drawing at all; one
/// still inside a TUI keeps the open segment AND gets the net modes re-asserted as the last bytes.
#[test]
fn an_exited_tui_replays_clean_and_a_live_one_keeps_its_screen() {
    let exited = sanitize(
        b"$ vi\r\n\x1b[?1049h\x1b[?1002hDRAW\x1b[?1002l\x1b[?1049l$ ok\r\n",
        Options {
            reassert_input_modes: true,
            distill: true,
        },
    );
    same(&exited, b"$ vi\r\n$ ok\r\n", "");

    let live = sanitize(b"$ vi\r\n\x1b[?1002h\x1b[?1049hFRAME", Options {
        reassert_input_modes: true,
        distill: true,
    });
    same(&live, b"$ vi\r\n\x1b[?1049hFRAME\x1b[?1002h", "");
}

/// The journal path asks for no reassert: a journal cut mid-TUI restores mode-free, because its
/// bytes front a NEW shell that must start with every TUI mode off.
#[test]
fn without_the_reassert_flag_a_mid_tui_cut_restores_mode_free() {
    let out = sanitize(b"$ vi\x1b[?1002h\x1b[?2048hEDIT", Options {
        reassert_input_modes: false,
        distill: true,
    });
    same(&out, b"$ viEDIT", "");
}
