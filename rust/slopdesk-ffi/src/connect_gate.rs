//! The connect gate, in C.
//!
//! The rules are `slopdesk_workspace::connect_gate`; what is here is the marshalling.
//!
//! ## Why the keystroke bytes do not appear in this file
//!
//! [`slopdesk_ws_out_batch_plan`] is the only door here on the latency path, and it takes no bytes
//! and answers none. The rule reads LENGTHS — merging two adjacent inputs is addition, splitting an
//! oversized one is division, and the barrier is the event's kind — so a boundary that copied the
//! payloads across would be copying them for nothing. What crosses instead is a side-table of
//! [`SlopDeskWsOutEvent`], one fixed-width record per buffered event, and what comes back is
//! [`SlopDeskWsOutFrame`] naming `(offset, length)` slices of the caller's OWN concatenated blob.
//!
//! `docs/55` §4's "the answer that is an OFFSET, not a copy", and the test the `decode_admission`
//! pair states for it: *the test is not how big the value is, it is whether the far side READS the
//! part that is big.* A pasted megabyte crosses as the same handful of records a keystroke does.
//!
//! [`slopdesk_ws_connect_gate_parse`] takes the same shape for the same reason: the only thing the
//! parse does to the host is TRIM it, so the answer is a span into the bytes the caller lent rather
//! than a copy of a string it is already holding.
//!
//! ## No `Error` crosses, and no `Date` either
//!
//! [`slopdesk_ws_failure_reason`] takes the two strings the near side can get out of a thrown
//! error, never the error. [`slopdesk_ws_reconnect_fold`] takes the status DISCRIMINANT and neither
//! the attempt count nor the next-retry instant — they are the caller's payload for a status it
//! adopts, and the rule reads neither.

use core::ffi::c_uchar;

use slopdesk_workspace::connect_gate::{self, Endpoint, Frame, Hint, OutEvent, Reconnect, Target};
use slopdesk_workspace::connection::StatusKind;

use crate::workspace::{Span, text_of};
use crate::{borrow, deliver, records_of, spill};

/// The kind byte an OUT event carries: keystrokes bound for the PTY.
pub const SLOPDESK_WS_OUT_INPUT: c_uchar = 0;
/// The kind byte an OUT event carries: a grid size bound for `TIOCSWINSZ`.
pub const SLOPDESK_WS_OUT_RESIZE: c_uchar = 1;

/// One event the caller buffered on its way OUT to the host.
///
/// `length` is how many bytes an input event contributes to the caller's concatenated blob; the
/// bytes themselves stay on the near side. `cols`/`rows` are read only for a resize, and `length`
/// only for an input — a kind byte this build cannot name contributes NEITHER, and is dropped.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsOutEvent {
    /// Input only: how many bytes this event puts in the batch's blob.
    pub length: usize,
    /// Resize only: columns.
    pub cols: u16,
    /// Resize only: rows.
    pub rows: u16,
    /// [`SLOPDESK_WS_OUT_INPUT`] or [`SLOPDESK_WS_OUT_RESIZE`].
    pub kind: c_uchar,
}

/// One frame the caller should actually send, in send order.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsOutFrame {
    /// Input only: where in the caller's blob this frame starts.
    pub offset: usize,
    /// Input only: how many bytes it runs for. Never zero.
    pub length: usize,
    /// Resize only: columns.
    pub cols: u16,
    /// Resize only: rows.
    pub rows: u16,
    /// [`SLOPDESK_WS_OUT_INPUT`] or [`SLOPDESK_WS_OUT_RESIZE`].
    pub kind: c_uchar,
}

/// One entry in the gate's recent-hosts menu: the host, as a span into the blob passed alongside,
/// and the terminal-mux port. Together they are the entry's IDENTITY.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SlopDeskWsRecentTarget {
    /// The machine, into the blob passed alongside.
    pub host: Span,
    /// Its terminal-mux port.
    pub port: u16,
}

/// The target the connect form's four fields parse to, or the refusal they earn.
///
/// `hint` is the guard: a non-zero code means every other field is meaningless, which is the
/// `Result` the rule answers, flattened for a caller that has no such type. The refused case leaves
/// the rest zeroed rather than undefined, so a near side that forgets the guard dials nothing
/// instead of dialling something arbitrary.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsConnectTarget {
    /// Where the TRIMMED host starts in the `host` bytes the caller lent.
    pub host_offset: usize,
    /// How many bytes it runs for.
    pub host_length: usize,
    /// The terminal-mux port.
    pub port: u16,
    /// The video media port.
    pub media_port: u16,
    /// The cursor-overlay port.
    pub cursor_port: u16,
    /// `0` when the four fields parse; otherwise the code
    /// [`slopdesk_ws_connect_gate_hint`] turns into words.
    pub hint: c_uchar,
}

/// The frames one drained OUT batch should be sent as, in send order.
///
/// Returns the count NEEDED. A short or null `out` is written nothing and told the length, the same
/// contract every other counted door here keeps. The first guess worth lending is the arithmetic
/// bound: one frame per resize, plus `ceil(total_input_bytes / max_input_frame_bytes)`.
///
/// A `max_input_frame_bytes` of zero is clamped by the rule rather than refused — see its header.
///
/// # Safety
/// `(events, count)` must be readable for the call, and `out` writable for `capacity`
/// [`SlopDeskWsOutFrame`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_out_batch_plan(
    events: *const SlopDeskWsOutEvent,
    count: usize,
    max_input_frame_bytes: usize,
    out: *mut SlopDeskWsOutFrame,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { records_of(events, count) };
    let batch: Vec<OutEvent> = lent
        .iter()
        .filter_map(|event| {
            match event.kind {
                SLOPDESK_WS_OUT_INPUT => Some(OutEvent::Input(event.length)),
                SLOPDESK_WS_OUT_RESIZE => {
                    Some(OutEvent::Resize {
                        cols: event.cols,
                        rows: event.rows,
                    })
                },
                // A kind this build cannot name is DROPPED, which is the only degradation that cannot
                // skew the answer: the offsets are derived from input lengths alone, so an event that
                // contributes no length leaves every frame after it naming the same bytes it would
                // have named anyway.
                _ => None,
            }
        })
        .collect();
    let frames: Vec<SlopDeskWsOutFrame> = connect_gate::plan(&batch, max_input_frame_bytes)
        .into_iter()
        .map(|frame| {
            match frame {
                Frame::Input { offset, len } => {
                    SlopDeskWsOutFrame {
                        offset,
                        length: len,
                        cols: 0,
                        rows: 0,
                        kind: SLOPDESK_WS_OUT_INPUT,
                    }
                },
                Frame::Resize { cols, rows } => {
                    SlopDeskWsOutFrame {
                        offset: 0,
                        length: 0,
                        cols,
                        rows,
                        kind: SLOPDESK_WS_OUT_RESIZE,
                    }
                },
            }
        })
        .collect();
    // SAFETY: `out` is the caller's, writable for `capacity` records by the obligation above, and
    // `frames` was allocated inside this call, so the two cannot overlap.
    unsafe { spill(&frames, out, capacity) }
}

/// The recent-hosts menu after one successful connect, as positions into a VIRTUAL list where `0`
/// is the candidate and `i + 1` is `entries[i]`.
///
/// Returns the count NEEDED — at most `limit`, so `limit` is the buffer worth lending. The virtual
/// index is what lets one answer carry the dedupe, the push-front and the cap at once: position `0`
/// is the caller's own new value, so an entry it replaced comes back as the NEW target's ports
/// rather than the stale ones it matched on.
///
/// `host` and every entry's host are spans into `(blob, blob_len)`. A span that does not resolve —
/// out of range, or not UTF-8 — reads as an empty host, which is the reading that cannot silently
/// match a real one.
///
/// # Safety
/// `(entries, count)` and `(blob, blob_len)` must be readable for the call, and `out` writable for
/// `capacity` `u32`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_recent_targets_push(
    host: Span,
    port: u16,
    entries: *const SlopDeskWsRecentTarget,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    limit: usize,
    out: *mut u32,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let lent = unsafe { records_of(entries, count) };
    // SAFETY: as above.
    let bytes = unsafe { borrow(blob, blob_len) };
    let existing: Vec<Endpoint<'_>> = lent
        .iter()
        .map(|entry| {
            Endpoint {
                host: text_of(entry.host, bytes).unwrap_or_default(),
                port: entry.port,
            }
        })
        .collect();
    let candidate = Endpoint {
        host: text_of(host, bytes).unwrap_or_default(),
        port,
    };
    let order = connect_gate::push_recent(candidate, &existing, limit);
    // SAFETY: `out` is the caller's, writable for `capacity` `u32`s by the obligation above, and
    // `order` was allocated inside this call.
    unsafe { spill(&order, out, capacity) }
}

/// The user-facing reason for a thrown connect error: the localized description when it has words,
/// else the readable payload behind it.
///
/// An `Error` cannot cross a C ABI, so what crosses is what the near side can get out of one — a
/// `LocalizedError`'s `errorDescription` and `String(describing:)`. A payload that is not UTF-8
/// cannot have come from a Swift `String` and reads as absent.
///
/// # Safety
/// Both input pairs must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_failure_reason(
    localized: *const c_uchar,
    localized_len: usize,
    fallback: *const c_uchar,
    fallback_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let described = unsafe { text(localized, localized_len) };
    // SAFETY: as above.
    let raw = unsafe { text(fallback, fallback_len) };
    // SAFETY: `deliver` writes at most `cap` bytes into the caller's buffer.
    unsafe { deliver(connect_gate::failure_reason(described, raw).as_bytes(), out, cap) }
}

/// The target the connect form's four fields parse to, or the first refusal they earn.
///
/// One verdict for both readings the near side needs — whether the Connect button is live, and
/// what the hint under it says — because they are one fact. See the rule's header.
///
/// A field that is not UTF-8 reads as empty, which for the host is [`Hint::Host`] and for a port is
/// the same refusal a non-numeric one earns.
///
/// # Safety
/// All four input pairs must be readable for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_connect_gate_parse(
    host: *const c_uchar,
    host_len: usize,
    port: *const c_uchar,
    port_len: usize,
    media_port: *const c_uchar,
    media_port_len: usize,
    cursor_port: *const c_uchar,
    cursor_port_len: usize,
) -> SlopDeskWsConnectTarget {
    // SAFETY: the caller's obligation, restated above; every borrow dies with this call.
    let parsed = unsafe {
        connect_gate::parse_target(
            text(host, host_len),
            text(port, port_len),
            text(media_port, media_port_len),
            text(cursor_port, cursor_port_len),
        )
    };
    match parsed {
        Ok(Target {
            host_offset,
            host_len: length,
            port: mux,
            media_port: media,
            cursor_port: cursor,
        }) => {
            SlopDeskWsConnectTarget {
                host_offset,
                host_length: length,
                port: mux,
                media_port: media,
                cursor_port: cursor,
                hint: 0,
            }
        },
        Err(hint) => {
            SlopDeskWsConnectTarget {
                hint: hint.code(),
                ..SlopDeskWsConnectTarget::default()
            }
        },
    }
}

/// What a refusal code says, for the hint under the Connect button.
///
/// `0` — no refusal — delivers nothing, which is the ABI's own "no answer". A code this build
/// cannot name delivers nothing too: a hint with no words is a hint the near side does not draw,
/// and inventing one would put a second vocabulary beside the rule's.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_connect_gate_hint(
    code: c_uchar,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let words = Hint::from_code(code).map_or("", Hint::text);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(words.as_bytes(), out, cap) }
}

/// What one reconnect-campaign callback does to the status it lands on: `0` leave it alone,
/// `1` adopt reconnecting, `2` adopt unreachable.
///
/// `status` is a `SLOPDESK_CONNECTION_STATUS_*` code — the same vocabulary every other connection
/// door takes, so the near side passes the one it already computes. A code this build cannot name
/// reads as disconnected, per `StatusKind::from_byte`, which is the state that promises the least;
/// the campaign is allowed to move it, which is the right answer for a link nobody can name.
///
/// The attempt count and the next-retry instant deliberately do not cross. They are the caller's
/// payload for the status it adopts, and the rule reads neither.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_reconnect_fold(
    status: u32,
    deliberately_closed: bool,
    gave_up: bool,
) -> c_uchar {
    let kind = StatusKind::from_byte(u8::try_from(status).unwrap_or(u8::MAX));
    match connect_gate::reconnect_fold(kind, deliberately_closed, gave_up) {
        Reconnect::Leave => 0,
        Reconnect::Reconnecting => 1,
        Reconnect::Unreachable => 2,
    }
}

/// One caller-lent `(ptr, len)` as text, treating anything that is not UTF-8 as empty.
///
/// Every producer is a Swift `String`, which cannot be invalid UTF-8; the fallback is what keeps a
/// door total against a caller that is not the one this ABI was written for.
///
/// # Safety
/// `(ptr, len)` must be readable for the duration of the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's buffer IS the boundary this module documents"
)]
unsafe fn text<'a>(ptr: *const c_uchar, len: usize) -> &'a str {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    core::str::from_utf8(unsafe { borrow(ptr, len) }).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::connect_gate::{self, Endpoint, Frame, Hint, OutEvent, Reconnect};
    use slopdesk_workspace::connection::StatusKind;

    use super::{
        SLOPDESK_WS_OUT_INPUT, SLOPDESK_WS_OUT_RESIZE, SlopDeskWsConnectTarget, SlopDeskWsOutEvent,
        SlopDeskWsOutFrame, SlopDeskWsRecentTarget, slopdesk_ws_connect_gate_hint,
        slopdesk_ws_connect_gate_parse, slopdesk_ws_failure_reason, slopdesk_ws_out_batch_plan,
        slopdesk_ws_recent_targets_push, slopdesk_ws_reconnect_fold,
    };
    use crate::testing::delivered;
    use crate::workspace::Span;

    /// The record an input event crosses as.
    const fn input(length: usize) -> SlopDeskWsOutEvent {
        SlopDeskWsOutEvent {
            length,
            cols: 0,
            rows: 0,
            kind: SLOPDESK_WS_OUT_INPUT,
        }
    }

    /// The record a resize crosses as, sized square so one number names it.
    const fn resize(size: u16) -> SlopDeskWsOutEvent {
        SlopDeskWsOutEvent {
            length: 0,
            cols: size,
            rows: size,
            kind: SLOPDESK_WS_OUT_RESIZE,
        }
    }

    /// Runs the plan door with the retry `docs/55` §4 describes and returns what it delivered.
    fn planned(events: &[SlopDeskWsOutEvent], ceiling: usize) -> Vec<SlopDeskWsOutFrame> {
        let mut frames = vec![SlopDeskWsOutFrame::default(); 8];
        // SAFETY: both arrays are live locals for the call.
        let mut needed = unsafe {
            slopdesk_ws_out_batch_plan(
                events.as_ptr(),
                events.len(),
                ceiling,
                frames.as_mut_ptr(),
                frames.len(),
            )
        };
        if needed > frames.len() {
            frames = vec![SlopDeskWsOutFrame::default(); needed];
            // SAFETY: as above.
            needed = unsafe {
                slopdesk_ws_out_batch_plan(
                    events.as_ptr(),
                    events.len(),
                    ceiling,
                    frames.as_mut_ptr(),
                    frames.len(),
                )
            };
        }
        frames.truncate(needed);
        frames
    }

    /// The rule's own answer, in the shape the door delivers it — the differential's other half.
    fn native(events: &[SlopDeskWsOutEvent], ceiling: usize) -> Vec<SlopDeskWsOutFrame> {
        let batch: Vec<OutEvent> = events
            .iter()
            .filter_map(|event| {
                match event.kind {
                    SLOPDESK_WS_OUT_INPUT => Some(OutEvent::Input(event.length)),
                    SLOPDESK_WS_OUT_RESIZE => {
                        Some(OutEvent::Resize {
                            cols: event.cols,
                            rows: event.rows,
                        })
                    },
                    _ => None,
                }
            })
            .collect();
        connect_gate::plan(&batch, ceiling)
            .into_iter()
            .map(|frame| {
                match frame {
                    Frame::Input { offset, len } => {
                        SlopDeskWsOutFrame {
                            offset,
                            length: len,
                            cols: 0,
                            rows: 0,
                            kind: SLOPDESK_WS_OUT_INPUT,
                        }
                    },
                    Frame::Resize { cols, rows } => {
                        SlopDeskWsOutFrame {
                            offset: 0,
                            length: 0,
                            cols,
                            rows,
                            kind: SLOPDESK_WS_OUT_RESIZE,
                        }
                    },
                }
            })
            .collect()
    }

    /// Every batch shape the plan can be asked about crosses to the same frames the rule gives
    /// directly — the differential the boundary exists to keep true.
    #[test]
    fn every_plan_crosses_verbatim() {
        let alphabet = [input(1), input(9), input(0), resize(80), resize(90)];
        for first in alphabet {
            for second in alphabet {
                for third in alphabet {
                    for ceiling in [0_usize, 1, 4, 4096] {
                        let batch = [first, second, third];
                        assert_eq!(
                            planned(&batch, ceiling),
                            native(&batch, ceiling),
                            "{batch:?} at {ceiling}"
                        );
                    }
                }
            }
        }
    }

    /// The headline fix, over the boundary: a drag burst collapses to its final size.
    #[test]
    fn a_drag_burst_crosses_as_one_resize() {
        let burst: Vec<SlopDeskWsOutEvent> = (59..=145).map(resize).collect();
        let frames = planned(&burst, 4096);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames.first().map(|frame| frame.cols), Some(145));
    }

    /// The offsets name slices of the caller's own blob, contiguously and in order.
    #[test]
    fn the_frames_name_the_callers_blob() {
        let batch = [input(3), input(2), resize(80), input(10)];
        let frames = planned(&batch, 4);
        assert_eq!(
            frames
                .iter()
                .filter(|frame| frame.kind == SLOPDESK_WS_OUT_INPUT)
                .map(|frame| (frame.offset, frame.length))
                .collect::<Vec<_>>(),
            vec![(0, 4), (4, 1), (5, 4), (9, 4), (13, 2)],
            "the split frames partition [0, 15) in order"
        );
    }

    /// A kind byte this build cannot name is dropped, and the offsets after it are unchanged.
    #[test]
    fn an_unnamed_kind_byte_is_dropped_without_skewing_the_offsets() {
        let strange = SlopDeskWsOutEvent {
            length: 500,
            cols: 7,
            rows: 7,
            kind: 200,
        };
        let batch = [input(2), strange, input(2)];
        assert_eq!(planned(&batch, 4096), planned(&[input(2), input(2)], 4096));
    }

    /// A short or null `out` is written nothing and told the count.
    #[test]
    fn a_short_and_a_null_buffer_are_both_told_the_count() {
        let batch = [input(10)];
        let mut short = [SlopDeskWsOutFrame::default(); 1];
        // SAFETY: both arrays are live locals for the call.
        let needed =
            unsafe { slopdesk_ws_out_batch_plan(batch.as_ptr(), batch.len(), 1, short.as_mut_ptr(), 1) };
        assert_eq!(needed, 10, "a short buffer is told the length");
        assert_eq!(short, [SlopDeskWsOutFrame::default()], "and written nothing");

        // SAFETY: `batch` is a live local, and a null `out` is the documented short case.
        let counted = unsafe {
            slopdesk_ws_out_batch_plan(batch.as_ptr(), batch.len(), 1, core::ptr::null_mut(), usize::MAX)
        };
        assert_eq!(counted, 10);
    }

    /// An empty batch is zero, and a null `events` is answered rather than dereferenced.
    #[test]
    fn an_empty_batch_and_a_null_input_are_both_inert() {
        // SAFETY: a zero-length read of a dangling-but-aligned pointer, and `out` is never touched.
        let empty = unsafe {
            slopdesk_ws_out_batch_plan(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                4096,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(empty, 0);
        // SAFETY: a null `events` with a non-zero count is the documented degradation.
        let nulled =
            unsafe { slopdesk_ws_out_batch_plan(core::ptr::null(), 4, 4096, core::ptr::null_mut(), 0) };
        assert_eq!(nulled, 0);
    }

    // ---- the recent-hosts menu --------------------------------------------------------------

    /// Builds a blob and the spans over it, then runs the MRU door.
    fn pushed(candidate: (&str, u16), entries: &[(&str, u16)], limit: usize) -> Vec<u32> {
        let mut blob = Vec::new();
        let mut span = |text: &str| {
            let offset = blob.len();
            blob.extend_from_slice(text.as_bytes());
            Span {
                offset,
                len: text.len(),
                present: true,
            }
        };
        let host = span(candidate.0);
        let records: Vec<SlopDeskWsRecentTarget> = entries
            .iter()
            .map(|entry| {
                SlopDeskWsRecentTarget {
                    host: span(entry.0),
                    port: entry.1,
                }
            })
            .collect();
        let mut out = vec![0_u32; limit.max(1)];
        // SAFETY: every array is a live local for the call.
        let needed = unsafe {
            slopdesk_ws_recent_targets_push(
                host,
                candidate.1,
                records.as_ptr(),
                records.len(),
                blob.as_ptr(),
                blob.len(),
                limit,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert!(needed <= out.len(), "the answer is capped at the limit");
        out.truncate(needed);
        out
    }

    /// The menu crosses to the same virtual positions the rule gives directly.
    #[test]
    fn every_menu_push_crosses_verbatim() {
        let entries = [("a", 1_u16), ("b", 2), ("a", 1), ("c", 3)];
        for candidate in [("a", 1_u16), ("b", 2), ("z", 9)] {
            for limit in [0_usize, 1, 3, 5, 9] {
                let existing: Vec<Endpoint<'_>> = entries
                    .iter()
                    .map(|entry| {
                        Endpoint {
                            host: entry.0,
                            port: entry.1,
                        }
                    })
                    .collect();
                let native = connect_gate::push_recent(
                    Endpoint {
                        host: candidate.0,
                        port: candidate.1,
                    },
                    &existing,
                    limit,
                );
                assert_eq!(
                    pushed(candidate, &entries, limit),
                    native,
                    "{candidate:?} at {limit}"
                );
            }
        }
    }

    /// A span that does not resolve reads as an empty host rather than matching a real one.
    #[test]
    fn an_unresolvable_span_reads_as_an_empty_host() {
        let blob = b"mac-studio";
        let entries = [SlopDeskWsRecentTarget {
            host: Span {
                offset: 900,
                len: 4,
                present: true,
            },
            port: 7420,
        }];
        let host = Span {
            offset: 0,
            len: blob.len(),
            present: true,
        };
        let mut out = [0_u32; 4];
        // SAFETY: every array is a live local for the call.
        let needed = unsafe {
            slopdesk_ws_recent_targets_push(
                host,
                7420,
                entries.as_ptr(),
                entries.len(),
                blob.as_ptr(),
                blob.len(),
                5,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(needed, 2, "the unreadable entry did not match the candidate");
    }

    /// An empty menu answers the candidate alone, and a limit of zero answers nothing.
    #[test]
    fn an_empty_menu_and_a_zero_limit_are_both_answered() {
        assert_eq!(pushed(("a", 1), &[], 5), vec![0]);
        assert!(pushed(("a", 1), &[("b", 2)], 0).is_empty());
    }

    // ---- the failure reason -----------------------------------------------------------------

    /// Runs the reason door with the §4 retry.
    fn reason(localized: &str, fallback: &str) -> String {
        let bytes = delivered(|out, cap| {
            // SAFETY: every buffer is a live local for the call.
            unsafe {
                slopdesk_ws_failure_reason(
                    localized.as_ptr(),
                    localized.len(),
                    fallback.as_ptr(),
                    fallback.len(),
                    out,
                    cap,
                )
            }
        });
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[test]
    fn every_reason_crosses_verbatim() {
        for localized in ["", "Connection timed out — host unreachable?"] {
            for fallback in ["", "invalidState(\"resume before first connect\")"] {
                assert_eq!(
                    reason(localized, fallback),
                    connect_gate::failure_reason(localized, fallback),
                    "{localized:?} / {fallback:?}"
                );
            }
        }
    }

    /// A null pair is an absent string, not a crash.
    #[test]
    fn a_null_localized_description_falls_back() {
        let fallback = "timedOut";
        let bytes = delivered(|out, cap| {
            // SAFETY: a null input pair is the documented absent case.
            unsafe {
                slopdesk_ws_failure_reason(core::ptr::null(), 9, fallback.as_ptr(), fallback.len(), out, cap)
            }
        });
        assert_eq!(String::from_utf8_lossy(&bytes), "timedOut");
    }

    // ---- the form ---------------------------------------------------------------------------

    /// Runs the parse door over four `&str` fields.
    fn parse(host: &str, port: &str, media: &str, cursor: &str) -> SlopDeskWsConnectTarget {
        // SAFETY: every string is a live local for the call.
        unsafe {
            slopdesk_ws_connect_gate_parse(
                host.as_ptr(),
                host.len(),
                port.as_ptr(),
                port.len(),
                media.as_ptr(),
                media.len(),
                cursor.as_ptr(),
                cursor.len(),
            )
        }
    }

    /// Every field combination crosses to the same verdict the rule gives directly.
    #[test]
    fn every_parse_crosses_verbatim() {
        let hosts = ["", "  ", "mac-studio", " mac-studio\n"];
        let ports = ["", "0", "7420", "abc", "65536"];
        for host in hosts {
            for port in ports {
                for media in ports {
                    for cursor in ports {
                        let crossed = parse(host, port, media, cursor);
                        let native = connect_gate::parse_target(host, port, media, cursor);
                        match native {
                            Ok(target) => {
                                assert_eq!(crossed.hint, 0);
                                assert_eq!(crossed.host_offset, target.host_offset);
                                assert_eq!(crossed.host_length, target.host_len);
                                assert_eq!(crossed.port, target.port);
                                assert_eq!(crossed.media_port, target.media_port);
                                assert_eq!(crossed.cursor_port, target.cursor_port);
                            },
                            Err(hint) => {
                                assert_eq!(crossed.hint, hint.code());
                                assert_eq!(
                                    crossed,
                                    SlopDeskWsConnectTarget {
                                        hint: hint.code(),
                                        ..SlopDeskWsConnectTarget::default()
                                    },
                                    "a refused verdict is zeroed, not arbitrary"
                                );
                            },
                        }
                    }
                }
            }
        }
    }

    /// The host span names the caller's own bytes.
    #[test]
    fn the_host_span_names_the_callers_own_bytes() {
        let typed = "  mac-studio\t";
        let crossed = parse(typed, "7420", "9000", "9001");
        assert_eq!(crossed.hint, 0);
        assert_eq!(
            typed.get(crossed.host_offset..crossed.host_offset + crossed.host_length),
            Some("mac-studio")
        );
    }

    /// Every hint's words cross, and neither `0` nor an unnamed code has any.
    #[test]
    fn every_hint_crosses_and_the_unnamed_codes_are_silent() {
        for hint in Hint::ALL {
            let bytes = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_connect_gate_hint(hint.code(), out, cap) }
            });
            assert_eq!(String::from_utf8_lossy(&bytes), hint.text(), "{hint:?}");
        }
        for code in [0_u8, 5, 200, 255] {
            let bytes = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_connect_gate_hint(code, out, cap) }
            });
            assert!(bytes.is_empty(), "{code}");
        }
    }

    /// A null field pair reads as empty, which for the host is the blank-host refusal.
    #[test]
    fn a_null_host_is_the_blank_host_refusal() {
        let port = "7420";
        // SAFETY: a null input pair is the documented absent case.
        let crossed = unsafe {
            slopdesk_ws_connect_gate_parse(
                core::ptr::null(),
                12,
                port.as_ptr(),
                port.len(),
                port.as_ptr(),
                port.len(),
                port.as_ptr(),
                port.len(),
            )
        };
        assert_eq!(crossed.hint, Hint::Host.code());
    }

    // ---- the reconnect fold -----------------------------------------------------------------

    /// Every status and both flags cross to the same verdict the rule gives directly.
    #[test]
    fn every_fold_crosses_verbatim() {
        for status in StatusKind::ALL {
            for deliberately_closed in [false, true] {
                for gave_up in [false, true] {
                    let crossed =
                        slopdesk_ws_reconnect_fold(u32::from(status.as_byte()), deliberately_closed, gave_up);
                    let expected = match connect_gate::reconnect_fold(status, deliberately_closed, gave_up) {
                        Reconnect::Leave => 0,
                        Reconnect::Reconnecting => 1,
                        Reconnect::Unreachable => 2,
                    };
                    assert_eq!(crossed, expected, "{status:?}");
                }
            }
        }
    }

    /// An unnamed status code reads as disconnected, which the campaign is allowed to move.
    #[test]
    fn an_unnamed_status_code_reads_as_disconnected() {
        assert_eq!(slopdesk_ws_reconnect_fold(9_999, false, false), 1);
        assert_eq!(slopdesk_ws_reconnect_fold(9_999, false, true), 2);
        assert_eq!(slopdesk_ws_reconnect_fold(9_999, true, false), 0);
    }
}
