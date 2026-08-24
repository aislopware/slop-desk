//! What a sidebar row draws, says and offers, in C.
//!
//! The rules are `slopdesk_workspace::sidebar_row`; what is here is the marshalling.
//!
//! The BADGE this row wears is not resolved here — that is `slopdesk_agent_tab_badge`, and its
//! answer is what the doors below take as their `badge` argument, `-1` for an all-clear row.

use core::ffi::c_uchar;

use slopdesk_agent::badge::TabBadge;
use slopdesk_workspace::sidebar_row::{self, Entry, Switch, Verb};

use crate::workspace::{Span, text_of};
use crate::{borrow, deliver, push_text, records_of, saturating_u32};

/// A badge discriminant back to its variant. `-1`, and anything naming no badge, is an all-clear
/// row.
fn badge_from(badge: i8) -> Option<TabBadge> {
    u8::try_from(badge)
        .ok()
        .and_then(|index| TabBadge::ALL.get(index as usize).copied())
}

/// One row's title INK and its WEIGHT, packed into one answer.
///
/// The ink is the low byte, the weight the next one up: both are asked on every redraw of every
/// row, they share every input, and two doors would let a row take an urgent hue at a resting
/// weight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_sidebar_row_title(badge: i8, active: bool, working: bool) -> u16 {
    let badge = badge_from(badge);
    let ink = sidebar_row::title_ink(badge, active, working).code();
    let weight = sidebar_row::title_weight(badge, active).code();
    u16::from(ink) | (u16::from(weight) << 8)
}

/// What `VoiceOver` reads for a row's state, in one delivery, or `0` when the row says nothing.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// A row whose only news is that it is BUSY says nothing: busy is not a state anyone is waiting on.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_sidebar_row_spoken_state(
    badge: i8,
    working: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(state) = sidebar_row::spoken_state(badge_from(badge), working) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, state);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Who else is on this pane, and the row's whole hover, in one delivery.
///
/// ```text
/// [u32 presence_line_count]
/// presence_line_count × [u32 length][UTF-8 bytes]   // the fan-out lines, viewers first
/// 1 × [u32 length][UTF-8 bytes]                     // the joined presence sentence, empty for none
/// 1 × [u32 length][UTF-8 bytes]                     // the whole tooltip, empty for none
/// ```
///
/// The presence lines are a CUT of the tooltip and not a second reading — the rule writes them once
/// and both spenders splice the SAME strings — which is exactly why they cross together: a door per
/// spender would be the two-readings drift the rule exists to prevent.
///
/// `viewers` and `holders` are spans into `blob`, viewers first for `viewer_count` entries and
/// holders after. `cwd`, `detail` and `last_command` are spans too; an ABSENT span is the caller's
/// `nil`, and a PRESENT empty one is dropped by the rule the same way.
///
/// # Safety
/// `(blob, blob_len)` must be readable for the call; `names` must be null or point to
/// `viewer_count + holder_count` initialised [`Span`]s; `(out, cap)` must be writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_sidebar_row_hover(
    cwd: Span,
    detail: Span,
    last_command: Span,
    names: *const Span,
    viewer_count: usize,
    holder_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; both borrows die with this call.
    let (lent, names) = unsafe {
        (
            borrow(blob, blob_len),
            records_of(names, viewer_count.saturating_add(holder_count)),
        )
    };
    let resolved: Vec<&str> = names.iter().filter_map(|span| text_of(*span, lent)).collect();
    let split = viewer_count.min(resolved.len());
    let (viewers, holders) = resolved.split_at(split);
    let lines = sidebar_row::presence_lines(viewers, holders);
    let mut answer = saturating_u32(lines.len()).to_be_bytes().to_vec();
    for line in &lines {
        push_text(&mut answer, line);
    }
    push_text(
        &mut answer,
        sidebar_row::presence(viewers, holders).as_deref().unwrap_or(""),
    );
    let tooltip = sidebar_row::tooltip(
        text_of(cwd, lent),
        text_of(detail, lent),
        text_of(last_command, lent),
        viewers,
        holders,
    );
    push_text(&mut answer, tooltip.as_deref().unwrap_or(""));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

/// The tooltip's last-command line, in one delivery, or `0` for a block with nothing to say.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `(blob, blob_len)` must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_sidebar_row_command_line(
    command: Span,
    duration_label: Span,
    status_label: Span,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(blob, blob_len) };
    let Some(line) = sidebar_row::command_line(
        text_of(command, lent).unwrap_or(""),
        text_of(duration_label, lent),
        text_of(status_label, lent),
    ) else {
        return 0;
    };
    let mut answer = Vec::new();
    push_text(&mut answer, &line);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

/// The row menu, as one entry code per row, in menu order.
///
/// ```text
/// [u32 count]
/// count × [u8 entry code]     // the kind in the high nibble, the member in the low one
/// ```
///
/// A byte per entry rather than a record per entry: the whole menu is seven of them and a
/// caller walks the list once, so a crossing per row of a context menu opening under a finger is
/// the cost the shape exists to avoid.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_sidebar_row_menu(out: *mut c_uchar, cap: usize) -> usize {
    let entries = sidebar_row::menu();
    let mut answer = saturating_u32(entries.len()).to_be_bytes().to_vec();
    answer.extend(entries.iter().map(|entry| entry.code()));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

/// Every menu member's title, in one delivery — the two verbs, then the three switches.
///
/// ```text
/// 5 × [u32 length][UTF-8 bytes]   // `Verb::ALL` then `Switch::ALL`, each in its own order
/// ```
///
/// One delivery rather than a lookup per entry code, because a menu is built whole.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_sidebar_row_menu_titles(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for verb in Verb::ALL {
        push_text(&mut blob, verb.title());
    }
    for switch in Switch::ALL {
        push_text(&mut blob, switch.title());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The code a separator crosses as, so no caller has to spell the nibble scheme itself.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_sidebar_row_separator_code() -> u8 {
    Entry::Separator.code()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
    #![expect(
        clippy::indexing_slicing,
        reason = "these blobs are the test's own, and a panic in a test is the failure report"
    )]

    use slopdesk_agent::badge::TabBadge;
    use slopdesk_workspace::sidebar_row::{self, Entry, Switch, Verb};

    use super::{
        slopdesk_ws_sidebar_row_command_line, slopdesk_ws_sidebar_row_hover, slopdesk_ws_sidebar_row_menu,
        slopdesk_ws_sidebar_row_menu_titles, slopdesk_ws_sidebar_row_separator_code,
        slopdesk_ws_sidebar_row_spoken_state, slopdesk_ws_sidebar_row_title,
    };
    use crate::testing::{delivered, runs};
    use crate::workspace::Span;

    /// A badge's discriminant, or `-1`.
    fn code(badge: Option<TabBadge>) -> i8 {
        badge.map_or(-1, |badge| {
            i8::try_from(
                TabBadge::ALL
                    .iter()
                    .position(|other| *other == badge)
                    .unwrap_or(0),
            )
            .unwrap_or(-1)
        })
    }

    #[test]
    fn a_rows_ink_and_weight_cross_together_and_agree_with_the_rules() {
        let cases = TabBadge::ALL.map(Some).into_iter().chain([None]);
        for badge in cases {
            for active in [false, true] {
                for working in [false, true] {
                    let packed = slopdesk_ws_sidebar_row_title(code(badge), active, working);
                    assert_eq!(
                        u8::try_from(packed & 0xFF).unwrap_or(0),
                        sidebar_row::title_ink(badge, active, working).code(),
                        "{badge:?} {active} {working}",
                    );
                    assert_eq!(
                        u8::try_from(packed >> 8).unwrap_or(0),
                        sidebar_row::title_weight(badge, active).code(),
                        "{badge:?} {active}",
                    );
                }
            }
        }
    }

    #[test]
    fn a_busy_row_speaks_no_state_and_an_unread_one_speaks_its_word() {
        for (badge, working) in [(Some(TabBadge::CommandBusy), false), (None, false)] {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_sidebar_row_spoken_state(code(badge), working, out, cap) }
            });
            assert!(blob.is_empty(), "{badge:?}");
        }
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe {
                slopdesk_ws_sidebar_row_spoken_state(code(Some(TabBadge::AwaitingInput)), false, out, cap)
            }
        });
        assert_eq!(
            runs(&blob, 1).first().map(String::as_str),
            Some(TabBadge::AwaitingInput.label()),
        );
    }

    /// Crosses one hover and reads its three parts back.
    fn hover(
        cwd: Option<&str>,
        detail: Option<&str>,
        last_command: Option<&str>,
        viewers: &[&str],
        holders: &[&str],
    ) -> (Vec<String>, String, String) {
        let mut arena: Vec<u8> = Vec::new();
        let span = |text: Option<&str>, arena: &mut Vec<u8>| {
            text.map_or(
                Span {
                    offset: 0,
                    len: 0,
                    present: false,
                },
                |text| {
                    let offset = arena.len();
                    arena.extend_from_slice(text.as_bytes());
                    Span {
                        offset,
                        len: arena.len() - offset,
                        present: true,
                    }
                },
            )
        };
        let cwd_span = span(cwd, &mut arena);
        let detail_span = span(detail, &mut arena);
        let command_span = span(last_command, &mut arena);
        let names: Vec<Span> = viewers
            .iter()
            .chain(holders)
            .map(|name| span(Some(name), &mut arena))
            .collect();
        let blob = delivered(|out, cap| {
            // SAFETY: every pointer is a live local for the call.
            unsafe {
                slopdesk_ws_sidebar_row_hover(
                    cwd_span,
                    detail_span,
                    command_span,
                    names.as_ptr(),
                    viewers.len(),
                    holders.len(),
                    arena.as_ptr(),
                    arena.len(),
                    out,
                    cap,
                )
            }
        });
        let count = u32::from_be_bytes([blob[0], blob[1], blob[2], blob[3]]) as usize;
        let read = runs(&blob[4..], count + 2);
        (
            read[..count].to_vec(),
            read[count].clone(),
            read[count + 1].clone(),
        )
    }

    #[test]
    fn the_presence_lines_the_hover_splices_are_the_same_strings_it_hands_back() {
        let (lines, sentence, tooltip) = hover(Some("~/slopdesk"), None, Some("make check"), &["ana"], &[
            "bo", "cy",
        ]);
        assert_eq!(lines, sidebar_row::presence_lines(&["ana"], &["bo", "cy"]));
        assert_eq!(
            Some(sentence.as_str()),
            sidebar_row::presence(&["ana"], &["bo", "cy"]).as_deref(),
        );
        assert_eq!(
            Some(tooltip.as_str()),
            sidebar_row::tooltip(Some("~/slopdesk"), None, Some("make check"), &["ana"], &[
                "bo", "cy"
            ])
            .as_deref(),
        );
        for line in &lines {
            assert!(
                tooltip.contains(line.as_str()),
                "the cut must be of the same string"
            );
        }
    }

    #[test]
    fn a_row_with_nothing_to_hover_crosses_as_empties_rather_than_a_short_delivery() {
        let (lines, sentence, tooltip) = hover(None, None, None, &[], &[]);
        assert!(lines.is_empty());
        assert_eq!(sentence, "");
        assert_eq!(tooltip, "");
    }

    /// A viewer count past the array is the caller's mistake, and must not read past.
    #[test]
    fn a_name_count_past_the_end_takes_only_what_is_there() {
        let arena = b"ana".to_vec();
        let names = [Span {
            offset: 0,
            len: 3,
            present: true,
        }];
        let absent = Span {
            offset: 0,
            len: 0,
            present: false,
        };
        let blob = delivered(|out, cap| {
            // SAFETY: every pointer is a live local for the call.
            unsafe {
                slopdesk_ws_sidebar_row_hover(
                    absent,
                    absent,
                    absent,
                    names.as_ptr(),
                    99,
                    99,
                    arena.as_ptr(),
                    arena.len(),
                    out,
                    cap,
                )
            }
        });
        let count = u32::from_be_bytes([blob[0], blob[1], blob[2], blob[3]]) as usize;
        assert_eq!(count, sidebar_row::presence_lines(&["ana"], &[]).len());
    }

    #[test]
    fn the_command_line_crosses_or_declines() {
        let arena = b"make check12s".to_vec();
        let present = |offset: usize, len: usize| {
            Span {
                offset,
                len,
                present: true,
            }
        };
        let absent = Span {
            offset: 0,
            len: 0,
            present: false,
        };
        let blob = delivered(|out, cap| {
            // SAFETY: `arena` and `out` are live locals for the call.
            unsafe {
                slopdesk_ws_sidebar_row_command_line(
                    present(0, 10),
                    present(10, 3),
                    absent,
                    arena.as_ptr(),
                    arena.len(),
                    out,
                    cap,
                )
            }
        });
        assert_eq!(
            runs(&blob, 1).first().cloned(),
            sidebar_row::command_line("make check", Some("12s"), None),
        );
        let none = delivered(|out, cap| {
            // SAFETY: `arena` and `out` are live locals for the call.
            unsafe {
                slopdesk_ws_sidebar_row_command_line(
                    absent,
                    absent,
                    absent,
                    arena.as_ptr(),
                    arena.len(),
                    out,
                    cap,
                )
            }
        });
        assert!(none.is_empty(), "a block with nothing to say has no line");
    }

    #[test]
    fn the_menu_crosses_as_the_codes_the_rule_writes() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_sidebar_row_menu(out, cap) }
        });
        let count = u32::from_be_bytes([blob[0], blob[1], blob[2], blob[3]]) as usize;
        let expected = sidebar_row::menu();
        assert_eq!(count, expected.len());
        let codes: Vec<u8> = expected.iter().map(|entry| entry.code()).collect();
        assert_eq!(blob[4..], codes[..]);
        assert_eq!(slopdesk_ws_sidebar_row_separator_code(), Entry::Separator.code());
    }

    #[test]
    fn every_menu_title_crosses_in_verbs_then_switches_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_sidebar_row_menu_titles(out, cap) }
        });
        let titles = runs(&blob, Verb::ALL.len() + Switch::ALL.len());
        for (index, verb) in Verb::ALL.into_iter().enumerate() {
            assert_eq!(titles.get(index).map(String::as_str), Some(verb.title()));
        }
        for (index, switch) in Switch::ALL.into_iter().enumerate() {
            assert_eq!(
                titles.get(Verb::ALL.len() + index).map(String::as_str),
                Some(switch.title()),
            );
        }
    }
}
