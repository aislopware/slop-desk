//! The side panel's four-tab strip, in C.
//!
//! The rules are `slopdesk_workspace::panel_tabs`; what is here is the marshalling.
//!
//! `docs/55` §6's two shapes again — one tab's mark and four sentences cross as a GROUP, and the
//! width ladder crosses as arithmetic: the renderer measures what its own type costs, this side
//! decides what the measurement means. The near side never sees a `Color` or a loaded image; a MARK
//! is a kind, and which glyph stands for it is the renderer's business.

use core::ffi::c_uchar;

use slopdesk_workspace::panel_tabs::{self, Mark, Surface};

use crate::{borrow, deliver, push_text};

/// The symbol name a symbol-backed mark carries, or the empty string for the drawn one.
///
/// `Mark::Android` has no `SFSymbol` — it is a shape the client draws itself — so it crosses as its
/// own code with no name beside it, rather than as a name the near side would have to recognise as
/// a sentinel.
const fn symbol_of(mark: Mark) -> &'static str {
    match mark {
        Mark::Symbol(name) => name,
        Mark::Android => "",
    }
}

/// The code for `mark`: `0` a symbol, `1` the drawn Android silhouette.
const fn mark_code(mark: Mark) -> u8 {
    match mark {
        Mark::Symbol(_) => 0,
        Mark::Android => 1,
    }
}

/// One tab, in one delivery.
///
/// ```text
/// [u8 mark_code]
/// 4 × [u32 length][UTF-8 bytes]   // symbol name, label, help, accessibility hint
/// ```
///
/// The accessibility LABEL is the label — the rules crate says so, and repeating it here would be
/// a fifth run that can drift from the first.
///
/// `0` is "there is no such tab"; a real tab always has a label.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_panel_tab(index: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(tab) = Surface::from_index(index).and_then(panel_tabs::tab) else {
        return 0;
    };
    let mut blob = vec![mark_code(tab.mark)];
    push_text(&mut blob, symbol_of(tab.mark));
    push_text(&mut blob, tab.label);
    push_text(&mut blob, tab.help);
    push_text(&mut blob, tab.accessibility_hint());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Which rung a strip of `available` points can afford: `0` every name, `1` the selected tab's name
/// only, `2` no names at all.
///
/// `named` is the renderer's own measurement of what each tab costs WITH its name, in `ALL`'s
/// order; `cell` is what a bare tab costs and `gap` what sits between two of them. Extra entries
/// past the fourth are ignored rather than rejected — the ladder reads exactly as many as the strip
/// has tabs, and a caller that measured more has measured something this rule does not place.
///
/// # Safety
/// `named` must be null, or point to `count` live `double`s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `named` is the caller's array"
)]
pub unsafe extern "C" fn slopdesk_ws_panel_tab_labelling(
    available: f64,
    cell: f64,
    gap: f64,
    named: *const f64,
    count: usize,
    selected: u8,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; the slice dies with this call.
    let named = unsafe { borrow(named, count) };
    let selected = Surface::from_index(selected).unwrap_or(Surface::Code);
    panel_tabs::labelling(available, cell, gap, named, selected).code()
}

/// Whether the tab `surface` prints its name at `rung`, given which tab is selected.
///
/// The rung is asked once per strip and this is asked once per tab, which is the shape a renderer
/// wants: the expensive question — the measurement — happens on layout, and the cheap one happens
/// where the answer is used.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_panel_tab_names(rung: u8, surface: u8, selected: u8) -> bool {
    let (Some(surface), Some(selected)) = (Surface::from_index(surface), Surface::from_index(selected))
    else {
        return false;
    };
    panel_tabs::Labelling::from_code(rung).names(surface, selected)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::panel_tabs::{self, Labelling, Mark, Surface};

    use super::{
        slopdesk_ws_panel_tab, slopdesk_ws_panel_tab_labelling, slopdesk_ws_panel_tab_names, symbol_of,
    };
    use crate::testing::{delivered, runs};

    #[test]
    fn every_tab_crosses_with_its_mark_and_its_four_sentences() {
        for tab in panel_tabs::ALL {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_panel_tab(tab.surface.index(), out, cap) }
            });
            let (code, rest) = blob
                .split_first()
                .map_or((0xFF, [].as_slice()), |(code, rest)| (*code, rest));
            assert_eq!(
                code,
                u8::from(matches!(tab.mark, Mark::Android)),
                "{:?}",
                tab.surface
            );
            let words = runs(rest, 4);
            assert_eq!(words.first().map(String::as_str), Some(symbol_of(tab.mark)));
            assert_eq!(words.get(1).map(String::as_str), Some(tab.label));
            assert_eq!(words.get(2).map(String::as_str), Some(tab.help));
            assert_eq!(words.get(3).map(String::as_str), Some(tab.accessibility_hint()));
        }
    }

    /// Only the Android tab is drawn rather than named, and it is the only one with a blank name.
    #[test]
    fn exactly_one_tab_draws_its_own_mark() {
        let drawn: Vec<Surface> = panel_tabs::ALL
            .into_iter()
            .filter(|tab| symbol_of(tab.mark).is_empty())
            .map(|tab| tab.surface)
            .collect();
        assert_eq!(drawn, vec![Surface::Android]);
    }

    #[test]
    fn the_ladder_crosses_unchanged() {
        let named = [40.0_f64, 62.0, 55.0, 58.0];
        for available in [0.0, 120.0, 200.0, 320.0, 400.0, 1000.0] {
            // SAFETY: `named` is a live local for the call.
            let crossed = unsafe {
                slopdesk_ws_panel_tab_labelling(available, 28.0, 6.0, named.as_ptr(), named.len(), 0)
            };
            assert_eq!(
                crossed,
                panel_tabs::labelling(available, 28.0, 6.0, &named, Surface::Code).code(),
                "at {available}",
            );
        }
    }

    /// A null measurement array is a strip nobody measured, not a crash.
    #[test]
    fn an_absent_measurement_still_answers() {
        // SAFETY: the null case is exactly what `borrow` documents.
        let crossed = unsafe { slopdesk_ws_panel_tab_labelling(400.0, 28.0, 6.0, core::ptr::null(), 0, 0) };
        assert_eq!(
            crossed,
            Labelling::All.code(),
            "no names cost nothing, so all of them fit"
        );
    }

    #[test]
    fn each_tab_asks_the_rung_about_itself() {
        for rung in 0..3_u8 {
            for tab in panel_tabs::ALL {
                let crossed = slopdesk_ws_panel_tab_names(rung, tab.surface.index(), 1);
                assert_eq!(
                    crossed,
                    Labelling::from_code(rung).names(tab.surface, Surface::Simulators),
                    "rung {rung}, {:?}",
                    tab.surface,
                );
            }
        }
    }

    #[test]
    fn nothing_is_read_past_the_end() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_ws_panel_tab(9, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
        assert!(!slopdesk_ws_panel_tab_names(0, 9, 0));
    }
}
