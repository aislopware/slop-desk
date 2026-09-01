//! The arithmetic this module does NOT hand to a caller, exercised where it is decided.
//!
//! ⚠️ NO TEST HERE OPENS A SURFACE, and that is the hang-safety rule rather than an omission —
//! the reason is stated in full where the door tests begin.

use slopdesk_vterm::{Mods, Rgb};

use super::blocks::{num_to_i32, settled_scroll, spill_rows};
use super::doors::{
    narrow_f32, rgb, slopdesk_term_surface_draw, slopdesk_term_surface_feed, slopdesk_term_surface_free,
    slopdesk_term_surface_key, slopdesk_term_surface_layer, slopdesk_term_surface_mouse,
    slopdesk_term_surface_scroll, slopdesk_term_surface_set_focus, slopdesk_term_surface_set_geometry,
    slopdesk_term_surface_set_option_as_alt, slopdesk_term_surface_set_theme,
};
use super::pointer::{
    slopdesk_term_shift_arrow_edge, slopdesk_term_surface_autoscroll_direction,
    slopdesk_term_surface_click_to_move, slopdesk_term_surface_line_range,
    slopdesk_term_surface_logical_lines, slopdesk_term_surface_screen_row,
    slopdesk_term_surface_select_autoscroll, slopdesk_term_surface_select_drag,
    slopdesk_term_surface_select_press, slopdesk_term_surface_select_release,
    slopdesk_term_surface_selection_text, slopdesk_term_surface_selection_verb,
    slopdesk_term_surface_set_selection, slopdesk_term_surface_viewport_info,
};
use super::reading::{
    slopdesk_term_surface_binding_action, slopdesk_term_surface_cell_metrics, slopdesk_term_surface_modes,
    slopdesk_term_surface_viewport_rows,
};
use super::*;

/// The float comparison this file's neighbours use — `slopdesk-termrender`'s block tests assert
/// the same way, because these are exact arithmetic on whole pixels and an epsilon is the
/// clippy-shaped spelling of `==`, not a tolerance anyone needs.
fn is(had: f64, want: f64) {
    assert!((had - want).abs() < f64::EPSILON, "had {had}, wanted {want}");
}

#[test]
fn a_flick_past_the_top_keeps_going_older_in_the_engine() {
    // The bug this pins: the block list absorbs "older" by DECREASING its offset, so what
    // spills out the top is negative — and `Scroll::Delta` spells older negative too. A
    // negation anywhere in that chain makes one flick reverse at the seam.
    assert_eq!(spill_rows(-42.0, 14.0), -3);
    // And the far end: overshooting the bottom spills toward the newest row.
    assert_eq!(spill_rows(42.0, 14.0), 3);
    // Less than a row buys nothing, and a degenerate cell height cannot divide.
    assert_eq!(spill_rows(-13.0, 14.0), 0);
    assert_eq!(spill_rows(-42.0, 0.0), 0);
    assert_eq!(spill_rows(0.0, 14.0), 0);
    // Not finite, not a row count.
    assert_eq!(spill_rows(f64::NAN, 14.0), 0);
}

#[test]
fn a_list_that_fits_has_nowhere_to_scroll() {
    is(settled_scroll(0.0, 400.0, 900.0, false), 0.0);
    // Following a list shorter than its viewport still means the top.
    is(settled_scroll(0.0, 400.0, 900.0, true), 0.0);
}

#[test]
fn the_chrome_overflow_is_exactly_what_can_be_scrolled() {
    // Nine hundred pixels of drawable holding a thousand of blocks: the hundred the headers and
    // gaps added is the whole scroll range, and the grid keeps every row it was sized for.
    is(settled_scroll(0.0, 1000.0, 900.0, true), 100.0);
    is(settled_scroll(40.0, 1000.0, 900.0, false), 40.0);
}

#[test]
fn an_offset_past_the_end_is_clamped_rather_than_kept() {
    // What a collapse does: the list shrinks under a scroll that was valid a frame ago.
    is(settled_scroll(500.0, 1000.0, 900.0, false), 100.0);
    is(settled_scroll(-20.0, 1000.0, 900.0, false), 0.0);
}

#[test]
fn the_pin_moves_the_offset_as_the_list_grows() {
    let after_one_command = settled_scroll(100.0, 1000.0, 900.0, true);
    // New output stays on screen without the user chasing it.
    is(settled_scroll(after_one_command, 1200.0, 900.0, true), 300.0);
}

#[test]
fn a_scroll_count_is_whole_and_fenced() {
    assert_eq!(num_to_i32(3.9), Some(3));
    assert_eq!(num_to_i32(-3.9), Some(-3));
    assert_eq!(num_to_i32(f64::INFINITY), None);
    assert_eq!(num_to_i32(f64::NAN), None);
    assert_eq!(
        num_to_i32(1e30),
        Some(i32::MAX),
        "a flick past the scrollback asks for its end, which is what the clamp gives"
    );
}

// ⚠️ NO TEST HERE OPENS A SURFACE, and that is the hang-safety rule rather than an omission:
// `Renderer::new` takes the system default Metal device, which under `swift test` / a headless
// `cargo test` is either absent or a software device that blocks on `nextDrawable`. What CAN be
// tested is every pure conversion the doors do around it, and each of those is a real defect
// this file would otherwise own alone.

#[test]
#[expect(
    unsafe_code,
    reason = "asserting the null contract means CALLING the doors, which are unsafe by definition"
)]
fn a_null_handle_is_inert_at_every_door() {
    // The one property every door shares, asserted once: a failed `new` must not become a crash
    // in `deinit`, so NULL answers rather than dereferences.
    let null: *mut SlopDeskTerminalSurface = core::ptr::null_mut();
    let mut out = [0_u8; 8];
    // SAFETY: a null handle is explicitly legal at every door.
    unsafe {
        slopdesk_term_surface_free(null);
        slopdesk_term_surface_feed(null, out.as_ptr(), 0);
        slopdesk_term_surface_set_focus(null, true, true);
        slopdesk_term_surface_set_theme(null, 0, 0, 0);
        slopdesk_term_surface_scroll(null, 0, 1);
        slopdesk_term_surface_set_option_as_alt(null, 1);
        slopdesk_term_surface_select_release(null, 0.0, 0.0);
        assert!(slopdesk_term_surface_layer(null).is_null());
        assert!(!slopdesk_term_surface_draw(null));
        assert_eq!(slopdesk_term_surface_set_geometry(null, 100.0, 100.0, 2.0), 0);
        assert_eq!(
            slopdesk_term_surface_key(null, 0, 0, 0, 0, out.as_ptr(), 0, false, out.as_mut_ptr(), 8),
            0
        );
        assert_eq!(
            slopdesk_term_surface_mouse(null, 0, 0, 0, 0.0, 0.0, out.as_mut_ptr(), 8),
            0
        );
        assert!(!slopdesk_term_surface_select_press(null, 0.0, 0.0, 0.0, 0.5, 3.0));
        assert!(!slopdesk_term_surface_select_drag(null, 0.0, 0.0, false));
        assert!(!slopdesk_term_surface_select_autoscroll(null, 0.0, 0.0, false));
        assert_eq!(slopdesk_term_surface_autoscroll_direction(null), 0);
        assert!(!slopdesk_term_surface_selection_verb(null, 1));
        assert_eq!(
            slopdesk_term_surface_selection_text(null, 0, out.as_mut_ptr(), 8),
            0
        );
        assert_eq!(slopdesk_term_surface_viewport_rows(null, out.as_mut_ptr(), 8), 0);
        assert_eq!(slopdesk_term_surface_cell_metrics(null, out.as_mut_ptr(), 8), 0);
        assert_eq!(slopdesk_term_surface_modes(null), 0);
        assert_eq!(slopdesk_term_surface_viewport_info(null, out.as_mut_ptr(), 8), 0);
        assert!(!slopdesk_term_surface_set_selection(null, 0, 0, 0, 0, false));
        assert_eq!(slopdesk_term_surface_screen_row(null, 0, out.as_mut_ptr(), 8), 0);
        assert_eq!(slopdesk_term_surface_line_range(null, 0, out.as_mut_ptr(), 8), 0);
        assert_eq!(slopdesk_term_surface_logical_lines(null, out.as_mut_ptr(), 8), 0);
        assert!(!slopdesk_term_surface_binding_action(null, out.as_ptr(), 0));
        assert_eq!(
            slopdesk_term_surface_click_to_move(null, 0, 0, out.as_mut_ptr(), 8),
            0
        );
    }
}

/// `controls.shift-arrow-select`'s recognition step. The LOCK and SIDE bits are the whole test:
/// a right-shift press carries `SHIFT | RIGHT_SHIFT` and Caps Lock rides along on every press
/// while it is on, so a bare `== SHIFT` would refuse a right-handed typist and everyone with
/// Caps Lock on — a setting that works for some people, which is worse than one that does not.
#[test]
#[expect(
    unsafe_code,
    reason = "calling an exported door, which is unsafe by definition in edition 2024"
)]
fn a_shift_arrow_names_its_edge_through_the_locks_and_the_sides() {
    // SAFETY: a pure rule with no pointers; the `unsafe` is edition 2024's on `extern "C"`.
    unsafe {
        let shift = Mods::SHIFT.bits();
        for (keycode, edge) in [(0x7E_u16, 0), (0x7D, 1), (0x7B, 2), (0x7C, 3)] {
            assert_eq!(slopdesk_term_shift_arrow_edge(keycode, shift), edge);
            assert_eq!(
                slopdesk_term_shift_arrow_edge(
                    keycode,
                    shift | Mods::RIGHT_SHIFT.bits() | Mods::CAPS_LOCK.bits() | Mods::NUM_LOCK.bits(),
                ),
                edge,
                "the right shift key and the locks are the same press",
            );
            // ⌥, ⌃ and ⌘ are NOT masked: ⇧⌥→ is a word-wise selection the program still gets.
            assert_eq!(
                slopdesk_term_shift_arrow_edge(keycode, shift | Mods::ALT.bits()),
                -1
            );
            // And an arrow with no shift at all is just an arrow.
            assert_eq!(slopdesk_term_shift_arrow_edge(keycode, Mods::NONE.bits()), -1);
        }
        // A key that is not an arrow names no edge however it is held.
        assert_eq!(slopdesk_term_shift_arrow_edge(0x00, shift), -1);
        assert_eq!(slopdesk_term_shift_arrow_edge(0xFFFF, shift), -1);
    }
}

/// The executor, driven through the real grammar with no surface — the whole point of splitting
/// [`perform`] out of the door is that every decision it makes is reachable without Metal.
mod actions {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::surface_action::{SelectionEdge, SurfaceAction};
    use slopdesk_vterm::VtSession;

    use super::super::reading::{page_lines, perform, run};

    fn session() -> VtSession {
        let mut vt = VtSession::new(8, 3, 20, 40).unwrap();
        vt.feed(b"\x1b]133;A\x07one\r\nfill\r\n\x1b]133;A\x07two\r\nfill\r\nthree\r\n");
        vt
    }

    /// ⚠️ The failure this seam exists to prevent: a spelling nobody recognises must be
    /// answered by doing NOTHING, and must SAY it did nothing.
    #[test]
    fn an_unknown_spelling_does_nothing_and_admits_it() {
        let mut vt = session();
        let before = vt.viewport_info().unwrap();
        assert!(!run(&mut vt, "scroll_page_lines"));
        assert!(!run(&mut vt, "teleport:3"));
        assert!(!run(&mut vt, ""));
        assert_eq!(vt.viewport_info().unwrap(), before);
    }

    #[test]
    fn the_scroll_verbs_move_the_viewport() {
        let mut vt = session();
        assert!(run(&mut vt, "scroll_to_top"));
        assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 0);
        assert!(run(&mut vt, "scroll_to_bottom"));
        assert!(vt.viewport_info().unwrap().is_at_bottom());
        assert!(run(&mut vt, "scroll_to_row:1"));
        assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 1);
        assert!(run(&mut vt, "scroll_page_lines:-1"));
        assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 0);
    }

    /// A hop with no prompt in that direction must fall through rather than swallow the key.
    #[test]
    fn a_prompt_hop_answers_false_when_there_is_nowhere_to_go() {
        let mut vt = session();
        assert!(run(&mut vt, "scroll_to_top"));
        assert!(!run(&mut vt, "jump_to_prompt:-1"));
    }

    #[test]
    fn a_prompt_hop_lands_on_a_prompt() {
        let mut vt = session();
        assert!(run(&mut vt, "jump_to_prompt:-1"));
        assert_eq!(
            vt.screen_row_text(vt.viewport_info().unwrap().viewport_top_row)
                .unwrap()
                .as_deref(),
            Some("two")
        );
    }

    #[test]
    fn the_search_verbs_run_navigate_and_end() {
        let mut vt = session();
        assert!(run(&mut vt, "search:fill"));
        assert_eq!(vt.search_matches().len(), 2);
        assert!(run(&mut vt, "navigate_search:next"));
        assert!(run(&mut vt, "navigate_search:previous"));
        assert!(run(&mut vt, "end_search"));
        assert!(vt.search_matches().is_empty());
        // Nothing to navigate once the find is closed.
        assert!(!run(&mut vt, "navigate_search:next"));
    }

    #[test]
    fn adjusting_a_selection_needs_one_to_adjust() {
        let mut vt = session();
        assert!(!run(&mut vt, "adjust_selection:right"));
        assert!(run(&mut vt, "search:fill"));
        assert!(run(&mut vt, "adjust_selection:right"));
    }

    /// Every spelling the grammar can produce reaches an arm of [`perform`] — a variant added
    /// to the enum without a case here would silently do nothing at runtime.
    #[test]
    fn every_spelling_the_grammar_produces_is_understood() {
        for action in [
            SurfaceAction::Search { needle: "fill" },
            SurfaceAction::NavigateSearch { forward: true },
            SurfaceAction::EndSearch,
            SurfaceAction::ScrollToRow(0),
            SurfaceAction::ScrollLines(-1),
            SurfaceAction::ScrollFraction(-0.9),
            SurfaceAction::ScrollToTop,
            SurfaceAction::ScrollToBottom,
            SurfaceAction::JumpToPrompt(-1),
            SurfaceAction::AdjustSelection(SelectionEdge::Right),
        ] {
            let spelling = action.spell();
            assert!(
                SurfaceAction::parse(&spelling).is_some(),
                "the executor cannot parse its own spelling {spelling:?}"
            );
        }
    }

    /// ⚠️ A page motion must never round DOWN to nothing: in a one-row pane, 0.9 of a page is
    /// 0.9 rows, and a page-down that moves zero rows reads as a dead key.
    #[test]
    fn a_page_motion_moves_at_least_one_row() {
        assert_eq!(page_lines(0.9, 1), 1);
        assert_eq!(page_lines(-0.9, 1), -1);
        assert_eq!(page_lines(0.9, 40), 36);
        assert_eq!(page_lines(-0.9, 40), -36);
        // A viewport of nothing still owes the caller a direction.
        assert_eq!(page_lines(0.9, 0), 1);
    }

    /// The executor never sees a non-finite fraction — the grammar refuses one — but the guard
    /// is asserted here because the arithmetic would otherwise produce a wrapped row count.
    #[test]
    fn a_non_finite_fraction_never_reaches_the_arithmetic() {
        for spelling in [
            "scroll_page_fractional:NaN",
            "scroll_page_fractional:inf",
            "scroll_page_fractional:-inf",
        ] {
            assert!(SurfaceAction::parse(spelling).is_none(), "{spelling} parsed");
        }
    }

    #[test]
    fn a_needle_carrying_a_colon_survives_the_split() {
        let mut vt = VtSession::new(16, 3, 20, 40).unwrap();
        vt.feed(b"error: bad\r\n");
        assert!(run(&mut vt, "search:error: bad"));
        assert_eq!(vt.search_matches().len(), 1);
    }

    #[test]
    fn perform_is_the_only_decision_point() {
        let mut vt = session();
        // Reached directly rather than through a spelling, so the two paths are known to agree.
        assert!(perform(&mut vt, SurfaceAction::ScrollToTop));
        assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 0);
    }
}

#[test]
fn a_colour_word_drops_its_high_byte_rather_than_reading_it_as_alpha() {
    assert_eq!(rgb(0x00FF_8040), Rgb {
        r: 255,
        g: 128,
        b: 64
    });
    // The high byte is ignored, so an opaque `0xFF……` and a bare `0x00……` are the same colour.
    assert_eq!(rgb(0xFFFF_8040), rgb(0x00FF_8040));
}

#[test]
fn a_pixel_measurement_never_narrows_to_zero_or_wraps() {
    assert_eq!(round_px(8.4), 8);
    assert_eq!(round_px(8.6), 9);
    // A cell can never be zero pixels: `libghostty-vt`'s geometry forbids it and the pointer's
    // division would be a NaN.
    assert_eq!(round_px(0.0), 1);
    assert_eq!(round_px(-40.0), 1);
    assert_eq!(round_px(f64::NAN), 1);
    // The positive guard is what fences the cast, so a value past `u32::MAX` saturates rather
    // than wrapping to a small number.
    assert_eq!(narrow_u32(f64::INFINITY), u32::MAX);
    assert_eq!(narrow_u32(f64::NAN), 0);
}

#[test]
fn a_nan_coordinate_becomes_the_origin_rather_than_a_cell() {
    // The trap `slopdesk_vterm::selection`'s `axis` names, at the other end of the same path: a
    // NaN that reached the encoder would RESOLVE to a cell instead of being refused.
    // Bit-compared rather than `==`, which for a NaN input is the whole question: a test
    // written with `==` would pass on the very value it exists to rule out.
    assert_eq!(narrow_f32(f64::NAN).to_bits(), 0.0_f32.to_bits());
    assert!((narrow_f32(12.5) - 12.5).abs() < f32::EPSILON);
}
