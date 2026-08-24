//! The Open Quickly picker's vocabulary, its measurements and its two tables, in C.
//!
//! The rules are `slopdesk_workspace::open_quickly`; what is here is the marshalling.
//!
//! ## The ROWS never cross
//!
//! Nothing below takes a row. `draw_order` takes section SIZES and answers the interleave; the
//! action table takes a row's four facts and answers verbs. What a row IS — its title, its
//! subtitle, the thing it opens — stays in the caller's own storage, so the picker's list is never
//! copied across the boundary on the way to being drawn.

use core::ffi::c_uchar;

use slopdesk_workspace::open_quickly::{self, Act, Chord, Filter, Kind, Line, Table, Verb, Word};

use crate::{borrow, deliver, push_text, records_of, saturating_u32};

/// The picker's four fixed lengths, by value.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct COpenQuicklyMetrics {
    /// The card's fixed width.
    pub panel_width: f64,
    /// The tallest the results viewport may be.
    pub results_max_height: f64,
    /// How wide a row's subtitle may run before it truncates.
    pub subtitle_max_width: f64,
    /// The action sheet's width.
    pub actions_width: f64,
}

/// One drawn line, by value: a header, or a row and the two indices it lives at.
///
/// `is_header` picks which of the other fields mean anything — a header carries only its section.
/// A record rather than a byte, unlike the sidebar menu's entry codes, because a row genuinely has
/// three numbers and packing three of them into one integer is the transcription `docs/55` §6 warns
/// about.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct COpenQuicklyLine {
    /// Whether this line is a section header.
    pub is_header: bool,
    /// The section it belongs to, in the caller's own order.
    pub section: usize,
    /// Its place inside that section. `0` on a header.
    pub item: usize,
    /// Its place among the rows a user can land on. `0` on a header.
    pub selectable: usize,
}

/// The picker's four fixed lengths.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_open_quickly_metrics() -> COpenQuicklyMetrics {
    COpenQuicklyMetrics {
        panel_width: open_quickly::PANEL_WIDTH,
        results_max_height: open_quickly::RESULTS_MAX_HEIGHT,
        subtitle_max_width: open_quickly::SUBTITLE_MAX_WIDTH,
        actions_width: open_quickly::ACTIONS_WIDTH,
    }
}

/// One ⇞/⇟ stride, in rows. A row height of zero strides one row rather than none.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_open_quickly_page_stride(row_height: f64) -> usize {
    open_quickly::page_stride(row_height)
}

/// Every fixed word the card says, in one delivery.
///
/// ```text
/// 8 × [u32 length][UTF-8 bytes]   // `Word::ALL`'s own order
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in Word::ALL {
        push_text(&mut blob, word.text());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// One pill's five readings, in one delivery. `0` for a code naming no pill.
///
/// ```text
/// [u8 chord key, ASCII]
/// 4 × [u32 length][UTF-8 bytes]   // its label, its section header, its symbol, its empty message
/// ```
///
/// The chord key leads as a flag byte for the reason the find bar's underline does: it is the
/// pill's own decoration, and a caller that received it as text would parse its way back to a
/// character.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_pill(code: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(pill) = Filter::from_code(code) else {
        return 0;
    };
    let chord = u8::try_from(u32::from(pill.chord_key())).unwrap_or(0);
    let mut blob = vec![chord];
    push_text(&mut blob, pill.label());
    push_text(&mut blob, &pill.section_header());
    push_text(&mut blob, pill.symbol());
    push_text(&mut blob, pill.empty_message());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Which pills are PILLS and which head SECTIONS, as two bitmasks over the pill's own code.
///
/// The low 16 bits are the pill row, the high 16 the section headers. Two masks in one answer
/// because the sets differ by exactly one member — All is a pill and heads nothing — and a caller
/// walking one list wants both facts per entry.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_open_quickly_pill_sets() -> u32 {
    let mask = |set: &[Filter]| set.iter().fold(0_u32, |bits, pill| bits | 1 << pill.code());
    mask(&Filter::PILLS) | (mask(&Filter::SECTIONS) << 16)
}

/// One kind's three readings, in one delivery. `0` for a code naming no kind.
///
/// ```text
/// [u8 jump-to code]
/// 3 × [u32 length][UTF-8 bytes]   // its badge, its symbol, the default action label it earns
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_kind(code: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(kind) = Kind::from_code(code) else {
        return 0;
    };
    let mut blob = vec![kind.jump_to_code()];
    push_text(&mut blob, kind.badge());
    push_text(&mut blob, kind.symbol());
    push_text(&mut blob, Kind::default_action_label(Some(kind)));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The default action label for a row that names NO kind — the one reading the kind door cannot
/// answer, in one delivery.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_default_action(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    push_text(&mut blob, Kind::default_action_label(None));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Every verb's title and symbol, in one delivery.
///
/// ```text
/// 30 × [u32 length][UTF-8 bytes]   // `Verb::ALL`'s order, each verb's title then its symbol
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_verbs(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for verb in Verb::ALL {
        push_text(&mut blob, verb.title());
        push_text(&mut blob, verb.symbol());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The zero-state line for the active pill, in one delivery.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// Three answers in one, and the ORDER keeps each honest: a typed query blames the query, an
/// in-flight Agents fetch says loading rather than none, everything else is the source's own line.
///
/// # Safety
/// `(query, query_len)` must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_empty_message(
    query: *const c_uchar,
    query_len: usize,
    filter: u8,
    agents_loading: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(filter) = Filter::from_code(filter) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let query = String::from_utf8_lossy(unsafe { borrow(query, query_len) });
    let mut blob = Vec::new();
    push_text(
        &mut blob,
        open_quickly::empty_message(&query, filter, agents_loading),
    );
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The ⌘-chord a character names: `0` for none, else the chord's kind in the high nibble.
///
/// ```text
/// 0x00        the picker does not claim it
/// 0x1<digit>  ⌘1-9: run the Nth visible row, the digit 1-BASED as typed
/// 0x20        ⌘K: toggle the selected row's action sheet
/// 0x3<code>   a pill chord, carrying that pill's own code
/// ```
///
/// `character` is a UNICODE SCALAR, not a byte: the near side reads one from its own event, and
/// narrowing it here would make ⌘é a chord it could not describe.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_open_quickly_chord(character: u32) -> u8 {
    let Some(character) = char::from_u32(character) else {
        return 0;
    };
    match open_quickly::command_chord(character) {
        None => 0,
        Some(Chord::QuickPick(digit)) => 0x10 | digit,
        Some(Chord::ToggleActions) => 0x20,
        Some(Chord::SelectPill(pill)) => 0x30 | pill.code(),
    }
}

/// The picker's draw order for a list of section sizes.
///
/// Returns how many LINES there are, writing them into `out` when they fit — the positions shape
/// `slopdesk_ws_binding_row_matches` uses, for the same reason: the answer is a list the near side
/// walks once, and `needed > cap` means nothing was written.
///
/// # Safety
/// `sizes` must be null or point to `size_count` initialised `usize`s, and `(out, cap)` must be
/// writable for `cap` entries.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_draw_order(
    sizes: *const usize,
    size_count: usize,
    filter: u8,
    out: *mut COpenQuicklyLine,
    cap: usize,
) -> usize {
    let Some(filter) = Filter::from_code(filter) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let sizes = unsafe { records_of(sizes, size_count) };
    let lines = open_quickly::draw_order(sizes, filter);
    if lines.len() > cap || out.is_null() {
        return lines.len();
    }
    for (slot, line) in lines.iter().enumerate() {
        let record = match *line {
            Line::Header { section } => {
                COpenQuicklyLine {
                    is_header: true,
                    section,
                    item: 0,
                    selectable: 0,
                }
            },
            Line::Row {
                section,
                item,
                selectable,
            } => {
                COpenQuicklyLine {
                    is_header: false,
                    section,
                    item,
                    selectable,
                }
            },
        };
        // SAFETY: `slot < lines.len() <= cap`, and the caller promised `cap` writable entries.
        unsafe { out.add(slot).write(record) };
    }
    lines.len()
}

/// The code the SHARED jump-to table crosses as, in place of a verb list.
///
/// A sentinel rather than an empty list, because "this row offers nothing of its own" and "this row
/// defers to the table the near side already owns" are different answers and only one of them draws
/// a sheet.
pub const SHARED_JUMP_TO: u8 = 0xFF;

/// A row's ⌘K action table, as one verb code per entry.
///
/// ```text
/// [u32 count]
/// count × [u8 verb code]
/// ```
///
/// A count of 1 whose single byte is [`SHARED_JUMP_TO`] is the shared table; every other answer is
/// this row's own verbs, in table order.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_open_quickly_row_actions(
    act: u8,
    kind: u8,
    has_subtitle: bool,
    cwd_empty: bool,
    folders_backed: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let (Some(act), Some(kind)) = (Act::from_code(act), Kind::from_code(kind)) else {
        return 0;
    };
    let codes: Vec<u8> = match open_quickly::row_actions(act, kind, has_subtitle, cwd_empty, folders_backed) {
        Table::SharedJumpTo => vec![SHARED_JUMP_TO],
        Table::Verbs(verbs) => verbs.iter().map(|verb| verb.code()).collect(),
    };
    let mut blob = saturating_u32(codes.len()).to_be_bytes().to_vec();
    blob.extend(codes);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
    #![expect(
        clippy::indexing_slicing,
        reason = "these blobs are the test's own, and a panic in a test is the failure report"
    )]

    use slopdesk_workspace::open_quickly::{self, Act, Chord, Filter, Kind, Line, Table, Verb, Word};

    use super::{
        COpenQuicklyLine, SHARED_JUMP_TO, slopdesk_ws_open_quickly_chord,
        slopdesk_ws_open_quickly_default_action, slopdesk_ws_open_quickly_draw_order,
        slopdesk_ws_open_quickly_empty_message, slopdesk_ws_open_quickly_kind,
        slopdesk_ws_open_quickly_metrics, slopdesk_ws_open_quickly_page_stride,
        slopdesk_ws_open_quickly_pill, slopdesk_ws_open_quickly_pill_sets,
        slopdesk_ws_open_quickly_row_actions, slopdesk_ws_open_quickly_verbs, slopdesk_ws_open_quickly_words,
    };
    use crate::testing::{delivered, runs};

    #[test]
    fn the_four_lengths_and_the_stride_cross_unchanged() {
        let metrics = slopdesk_ws_open_quickly_metrics();
        assert!((metrics.panel_width - open_quickly::PANEL_WIDTH).abs() < f64::EPSILON);
        assert!((metrics.results_max_height - open_quickly::RESULTS_MAX_HEIGHT).abs() < f64::EPSILON);
        assert!((metrics.subtitle_max_width - open_quickly::SUBTITLE_MAX_WIDTH).abs() < f64::EPSILON);
        assert!((metrics.actions_width - open_quickly::ACTIONS_WIDTH).abs() < f64::EPSILON);
        for height in [0.0_f64, 1.0, 28.0, 1_000.0] {
            assert_eq!(
                slopdesk_ws_open_quickly_page_stride(height),
                open_quickly::page_stride(height),
            );
        }
    }

    #[test]
    fn every_word_crosses_in_its_own_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_open_quickly_words(out, cap) }
        });
        let words = runs(&blob, Word::ALL.len());
        for (index, word) in Word::ALL.into_iter().enumerate() {
            assert_eq!(
                words.get(index).map(String::as_str),
                Some(word.text()),
                "{word:?}"
            );
        }
    }

    #[test]
    fn every_pill_crosses_with_its_chord_and_its_four_words() {
        for pill in Filter::PILLS {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_open_quickly_pill(pill.code(), out, cap) }
            });
            assert_eq!(char::from(blob[0]), pill.chord_key(), "{pill:?}");
            let words = runs(&blob[1..], 4);
            assert_eq!(words[0], pill.label());
            assert_eq!(words[1], pill.section_header());
            assert_eq!(words[2], pill.symbol());
            assert_eq!(words[3], pill.empty_message());
        }
        let mut none = [0xAA_u8; 8];
        // SAFETY: `none` is a live local for the call.
        let needed = unsafe { slopdesk_ws_open_quickly_pill(200, none.as_mut_ptr(), none.len()) };
        assert_eq!(needed, 0);
        assert_eq!(none, [0xAA; 8], "no answer means nothing was written");
    }

    /// The one asymmetry the two masks exist for: All is a pill and heads no section.
    #[test]
    fn the_pill_row_and_the_section_headers_differ_by_exactly_all() {
        let sets = slopdesk_ws_open_quickly_pill_sets();
        for pill in Filter::PILLS {
            assert_ne!(sets & 1 << pill.code(), 0, "{pill:?}");
        }
        for pill in Filter::SECTIONS {
            assert_ne!(sets >> 16 & 1 << pill.code(), 0, "{pill:?}");
        }
        assert_eq!(sets >> 16 & 1 << Filter::All.code(), 0);
    }

    #[test]
    fn every_kind_crosses_with_its_jump_target_and_its_three_words() {
        for kind in Kind::ALL {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_open_quickly_kind(kind.code(), out, cap) }
            });
            assert_eq!(blob[0], kind.jump_to_code(), "{kind:?}");
            let words = runs(&blob[1..], 3);
            assert_eq!(words[0], kind.badge());
            assert_eq!(words[1], kind.symbol());
            assert_eq!(words[2], Kind::default_action_label(Some(kind)));
        }
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_open_quickly_default_action(out, cap) }
        });
        assert_eq!(
            runs(&blob, 1).first().map(String::as_str),
            Some(Kind::default_action_label(None)),
        );
    }

    #[test]
    fn every_verb_crosses_as_its_title_and_its_symbol() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_open_quickly_verbs(out, cap) }
        });
        let words = runs(&blob, Verb::ALL.len() * 2);
        for (index, verb) in Verb::ALL.into_iter().enumerate() {
            assert_eq!(words[index * 2], verb.title(), "{verb:?}");
            assert_eq!(words[index * 2 + 1], verb.symbol(), "{verb:?}");
        }
    }

    #[test]
    fn the_zero_state_keeps_its_three_answers_apart() {
        for (query, filter, loading) in [
            ("needle", Filter::All, false),
            ("", Filter::Agents, true),
            ("", Filter::Agents, false),
            ("   ", Filter::Folders, false),
        ] {
            let bytes = query.as_bytes().to_vec();
            let blob = delivered(|out, cap| {
                // SAFETY: `bytes` and `out` are live locals for the call.
                unsafe {
                    slopdesk_ws_open_quickly_empty_message(
                        bytes.as_ptr(),
                        bytes.len(),
                        filter.code(),
                        loading,
                        out,
                        cap,
                    )
                }
            });
            assert_eq!(
                runs(&blob, 1).first().map(String::as_str),
                Some(open_quickly::empty_message(query, filter, loading)),
                "{query:?} {filter:?} {loading}",
            );
        }
    }

    #[test]
    fn every_chord_crosses_as_its_kind_and_its_member() {
        for character in ['1', '9', 'k', 'K', '0', 'z', '\u{e9}'] {
            let crossed = slopdesk_ws_open_quickly_chord(u32::from(character));
            match open_quickly::command_chord(character) {
                None => assert_eq!(crossed, 0, "{character:?}"),
                Some(Chord::QuickPick(digit)) => assert_eq!(crossed, 0x10 | digit),
                Some(Chord::ToggleActions) => assert_eq!(crossed, 0x20),
                Some(Chord::SelectPill(pill)) => assert_eq!(crossed, 0x30 | pill.code()),
            }
        }
        assert_eq!(slopdesk_ws_open_quickly_chord(0x11_0000), 0, "not a scalar");
    }

    #[test]
    fn the_draw_order_crosses_with_both_index_spaces_intact() {
        let sizes = [2_usize, 0, 3];
        for filter in Filter::PILLS {
            let expected = open_quickly::draw_order(&sizes, filter);
            // SAFETY: `sizes` is a live local, and a null `out` is the size-asking call.
            let needed = unsafe {
                slopdesk_ws_open_quickly_draw_order(
                    sizes.as_ptr(),
                    sizes.len(),
                    filter.code(),
                    core::ptr::null_mut(),
                    0,
                )
            };
            assert_eq!(needed, expected.len(), "{filter:?}");
            let mut lines = vec![
                COpenQuicklyLine {
                    is_header: false,
                    section: usize::MAX,
                    item: usize::MAX,
                    selectable: usize::MAX,
                };
                needed
            ];
            // SAFETY: both pointers are live locals for the call.
            let written = unsafe {
                slopdesk_ws_open_quickly_draw_order(
                    sizes.as_ptr(),
                    sizes.len(),
                    filter.code(),
                    lines.as_mut_ptr(),
                    lines.len(),
                )
            };
            assert_eq!(written, needed);
            for (line, drawn) in lines.iter().zip(&expected) {
                match *drawn {
                    Line::Header { section } => {
                        assert!(line.is_header);
                        assert_eq!(line.section, section);
                    },
                    Line::Row {
                        section,
                        item,
                        selectable,
                    } => {
                        assert!(!line.is_header);
                        assert_eq!(
                            (line.section, line.item, line.selectable),
                            (section, item, selectable)
                        );
                    },
                }
            }
        }
    }

    /// A buffer too small writes NOTHING, which is what makes the size-then-read retry safe.
    #[test]
    fn a_short_buffer_leaves_the_caller_s_lines_alone() {
        let sizes = [4_usize];
        let mut lines = [COpenQuicklyLine {
            is_header: true,
            section: 7,
            item: 7,
            selectable: 7,
        }];
        // SAFETY: both pointers are live locals for the call.
        let needed = unsafe {
            slopdesk_ws_open_quickly_draw_order(
                sizes.as_ptr(),
                sizes.len(),
                Filter::All.code(),
                lines.as_mut_ptr(),
                lines.len(),
            )
        };
        assert!(needed > lines.len());
        assert_eq!(lines[0].section, 7, "a short answer wrote nothing");
    }

    #[test]
    fn every_action_table_crosses_as_its_verbs_or_as_the_shared_sentinel() {
        for act in Act::ALL {
            for kind in Kind::ALL {
                let blob = delivered(|out, cap| {
                    // SAFETY: `out` is a live local for the call.
                    unsafe {
                        slopdesk_ws_open_quickly_row_actions(
                            act.code(),
                            kind.code(),
                            true,
                            false,
                            true,
                            out,
                            cap,
                        )
                    }
                });
                let count = u32::from_be_bytes([blob[0], blob[1], blob[2], blob[3]]) as usize;
                let codes = &blob[4..];
                assert_eq!(codes.len(), count);
                match open_quickly::row_actions(act, kind, true, false, true) {
                    Table::SharedJumpTo => assert_eq!(codes, [SHARED_JUMP_TO]),
                    Table::Verbs(verbs) => {
                        let expected: Vec<u8> = verbs.iter().map(|verb| verb.code()).collect();
                        assert_eq!(codes, expected, "{act:?} {kind:?}");
                    },
                }
            }
        }
    }

    /// The sentinel must not be a verb, or the shared table would read as one.
    #[test]
    fn no_verb_wears_the_shared_tables_code() {
        for verb in Verb::ALL {
            assert_ne!(verb.code(), SHARED_JUMP_TO, "{verb:?}");
        }
    }
}
