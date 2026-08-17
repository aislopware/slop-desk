//! What the sidebar shows, in what order, under which labels.
//!
//! The rules are `slopdesk_workspace::rail_list`; what is here is the marshalling. Every string
//! arrives as a span into ONE blob for the reason [`workspace`](crate::workspace)'s title doors
//! give — one pointer, one lifetime, one scope, where a `(ptr, len)` per field would mean four
//! nested borrows per row per frame, on a list that is rebuilt whenever anything in it ticks.
//!
//! Both list doors answer in the caller's own indices. A rail row on the near side is an id, a
//! kind, a badge, a selection flag and half a dozen strings; almost none of that decides where it
//! goes, so the answer names rows rather than carrying them, and the near side reorders the array
//! it already holds.

use core::ffi::c_uchar;

use slopdesk_workspace::rail_list::{self, Label, PlanRow, RowFields};

use crate::deliver;
use crate::workspace::{Span, borrow_array, text_of};

/// The four fields the search field reads, spanning the blob passed alongside.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRailRowFields {
    /// The row's visible title.
    pub title: Span,
    /// The row's visible subtitle.
    pub subtitle: Span,
    /// The pane's working directory — never drawn, always searchable.
    pub cwd: Span,
    /// The foreground process — likewise.
    pub process_label: Span,
}

/// One row as the sectioning reads it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRailPlanRow {
    /// The pane's OWN project key, spanning the blob passed alongside.
    pub project_key: Span,
    /// Where the row's tab sits in the display order; [`usize::MAX`] for a tab that is not in it.
    pub tab_rank: usize,
}

/// Where one row ends up.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRailPlacement {
    /// The row's index in the array the caller passed in.
    pub row_index: usize,
    /// Which section it landed in, counting from the first section drawn.
    pub section: usize,
}

/// A label that may collide with an identical one, and the path it came from.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRailLabel {
    /// What is shown now — a row's title, or a section's header.
    pub text: Span,
    /// The path it was derived from: the pane's cwd, or the section's project key.
    pub source: Span,
}

/// Whether a row survives the search field.
///
/// # Safety
/// `strings` must be null or point to `strings_len` initialised bytes, and `query` null or point to
/// `query_len` initialised bytes; both live for the call. Every span in `fields` is bounds-checked
/// against `strings` rather than trusted.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_rail_row_matches(
    fields: CRailRowFields,
    strings: *const c_uchar,
    strings_len: usize,
    query: *const c_uchar,
    query_len: usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = crate::borrow(strings, strings_len);
        let needle = core::str::from_utf8(crate::borrow(query, query_len)).unwrap_or_default();
        rail_list::row_matches(
            RowFields {
                title: text_of(fields.title, blob).unwrap_or_default(),
                subtitle: text_of(fields.subtitle, blob),
                cwd: text_of(fields.cwd, blob),
                process_label: text_of(fields.process_label, blob),
            },
            needle,
        )
    }
}

/// Every row's place in the drawn list, written to `out` in draw order.
///
/// Returns how many placements there ARE, which is always `count` — the rail draws what it is
/// given. A caller whose `cap` is short gets nothing written and the same number back, so the one
/// retry it needs is the §4 retry it already writes for text.
///
/// # Safety
/// `rows` must be null or point to `count` live [`CRailPlanRow`]s; `strings` null or `strings_len`
/// initialised bytes; `out` null or writable for `cap` [`CRailPlacement`]s. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_rail_plan(
    rows: *const CRailPlanRow,
    count: usize,
    strings: *const c_uchar,
    strings_len: usize,
    out: *mut CRailPlacement,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = crate::borrow(strings, strings_len);
        let held: Vec<PlanRow<'_>> = borrow_array(rows, count)
            .iter()
            .map(|row| {
                PlanRow {
                    project_key: text_of(row.project_key, blob),
                    tab_rank: row.tab_rank,
                }
            })
            .collect();
        let placements = rail_list::plan(&held);
        if out.is_null() || cap < placements.len() {
            return placements.len();
        }
        for (index, place) in placements.iter().enumerate() {
            // SAFETY: `index` is below `placements.len()`, which is at most `cap`.
            out.add(index).write(CRailPlacement {
                row_index: place.row_index,
                section: place.section,
            });
        }
        placements.len()
    }
}

/// What `items[index]` should be CALLED once identical labels have been told apart.
///
/// `0` is "keep the label you have" — a qualified label is never empty, so the two cannot collide.
/// The whole list is passed on every call because a collision is a fact about the list, not about
/// one member; at rail lengths the repeated walk is cheaper than a second answer channel.
///
/// # Safety
/// `items` must be null or point to `count` live [`CRailLabel`]s; `strings` null or `strings_len`
/// initialised bytes; `out` null or writable for `cap` bytes. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_rail_disambiguated_label(
    items: *const CRailLabel,
    count: usize,
    strings: *const c_uchar,
    strings_len: usize,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = crate::borrow(strings, strings_len);
        let held: Vec<Label<'_>> = borrow_array(items, count)
            .iter()
            .map(|item| {
                Label {
                    text: text_of(item.text, blob).unwrap_or_default(),
                    source: text_of(item.source, blob),
                }
            })
            .collect();
        let Some(label) = rail_list::disambiguated_label(&held, index) else {
            return 0;
        };
        deliver(label.as_bytes(), out, cap)
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        CRailLabel, CRailPlacement, CRailPlanRow, CRailRowFields, slopdesk_ws_rail_disambiguated_label,
        slopdesk_ws_rail_plan, slopdesk_ws_rail_row_matches,
    };
    use crate::workspace::Span;

    /// A blob builder: the near side's `WsStrings`, in the words the tests need.
    #[derive(Default)]
    struct Blob {
        bytes: Vec<u8>,
    }

    impl Blob {
        fn span(&mut self, text: Option<&str>) -> Span {
            let Some(text) = text else {
                return Span {
                    offset: 0,
                    len: 0,
                    present: false,
                };
            };
            let offset = self.bytes.len();
            self.bytes.extend_from_slice(text.as_bytes());
            Span {
                offset,
                len: text.len(),
                present: true,
            }
        }
    }

    #[test]
    fn a_hidden_field_matches_through_the_door() {
        let mut blob = Blob::default();
        let fields = CRailRowFields {
            title: blob.span(Some("api")),
            subtitle: blob.span(None),
            cwd: blob.span(Some("/w/myapp/api")),
            process_label: blob.span(None),
        };
        let matched = |query: &str| {
            // SAFETY: two live local buffers, borrowed for the duration of the call.
            unsafe {
                slopdesk_ws_rail_row_matches(
                    fields,
                    blob.bytes.as_ptr(),
                    blob.bytes.len(),
                    query.as_ptr(),
                    query.len(),
                )
            }
        };
        assert!(matched("MYAPP"), "the path, folded");
        assert!(matched(""), "a blank query keeps the row");
        assert!(!matched("nowhere"));
    }

    #[test]
    fn a_short_buffer_asks_for_the_full_count_and_writes_nothing() {
        let mut blob = Blob::default();
        let rows = [
            CRailPlanRow {
                project_key: blob.span(Some("/w/zeta")),
                tab_rank: 0,
            },
            CRailPlanRow {
                project_key: blob.span(Some("/w/alpha")),
                tab_rank: 1,
            },
        ];
        let mut out = [CRailPlacement {
            row_index: 9,
            section: 9,
        }; 1];
        // SAFETY: three live local buffers, borrowed for the duration of the call.
        let needed = unsafe {
            slopdesk_ws_rail_plan(
                rows.as_ptr(),
                rows.len(),
                blob.bytes.as_ptr(),
                blob.bytes.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(needed, 2, "the answer is as long as the list");
        assert_eq!(out[0].row_index, 9, "a short buffer is left untouched");

        let mut out = [CRailPlacement {
            row_index: 0,
            section: 0,
        }; 2];
        // SAFETY: as above, with a buffer the answer fits in.
        unsafe {
            slopdesk_ws_rail_plan(
                rows.as_ptr(),
                rows.len(),
                blob.bytes.as_ptr(),
                blob.bytes.len(),
                out.as_mut_ptr(),
                out.len(),
            );
        }
        assert_eq!(
            (out[0].row_index, out[0].section, out[1].row_index, out[1].section),
            (1, 0, 0, 1),
            "alpha's row draws first, in its own section"
        );
    }

    #[test]
    fn a_colliding_label_answers_and_a_lone_one_answers_nothing() {
        let mut blob = Blob::default();
        let items = [
            CRailLabel {
                text: blob.span(Some("src")),
                source: blob.span(Some("/w/api/src")),
            },
            CRailLabel {
                text: blob.span(Some("src")),
                source: blob.span(Some("/w/web/src")),
            },
            CRailLabel {
                text: blob.span(Some("docs")),
                source: blob.span(Some("/w/api/docs")),
            },
        ];
        let label = |index: usize| {
            let mut out = [0_u8; 64];
            // SAFETY: three live local buffers, borrowed for the duration of the call.
            let written = unsafe {
                slopdesk_ws_rail_disambiguated_label(
                    items.as_ptr(),
                    items.len(),
                    blob.bytes.as_ptr(),
                    blob.bytes.len(),
                    index,
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            String::from_utf8_lossy(out.get(..written).unwrap_or_default()).into_owned()
        };
        assert_eq!(label(0), "api/src");
        assert_eq!(label(1), "web/src");
        assert_eq!(label(2), "", "nothing else is called docs");
    }
}
