//! What a pane drop would commit, in C.
//!
//! The rules are `slopdesk_workspace::drop_register`; what is here is the marshalling.
//!
//! Both doors answer a MARK and a SENTENCE in ONE delivery, and that is not only §6's grouping
//! argument — it is a correctness one. The canvas destination's label is deliberately EMPTY (the
//! in-canvas overlay is the affordance there, and a floating twin would print the same words
//! twice), so a words-only door would answer `0` for it and be indistinguishable from "no such
//! destination". With the mark byte in front the delivery is never empty, and `0` keeps its one
//! meaning.
//!
//! Both are called from a drag's live tracking, so both are hot: a chip re-reads its sentence
//! whenever the cursor crosses a zone boundary.

use core::ffi::c_uchar;

use slopdesk_workspace::drop_register::{Destination, Origin, Zone};

use crate::{borrow, deliver, push_text};

/// The title behind a `(ptr, len)` pair, or `None` when the caller has no name for the pane.
///
/// # Safety
/// `title` must be null, or point to `len` live bytes for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's string IS the boundary this module documents"
)]
unsafe fn title_of<'a>(
    title: *const c_uchar,
    len: usize,
    present: bool,
) -> Option<std::borrow::Cow<'a, str>> {
    if !present {
        return None;
    }
    // SAFETY: the caller's obligation, restated at each door; the borrow dies with this call.
    Some(String::from_utf8_lossy(unsafe { borrow(title, len) }))
}

/// The in-canvas chip for the zone `(kind, edge)` names, in one delivery.
///
/// ```text
/// [u8 mark_code]
/// 1 × [u32 length][UTF-8 bytes]   // the chip's sentence
/// ```
///
/// `kind` is `1` swap, `2` re-split, `3` dock, anything else the cancel; `edge` is the near side's
/// own drop-edge byte and is read only by the two split kinds. `title` is the DRAGGED pane's.
///
/// # Safety
/// `title` must be null or `title_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_drop_zone(
    kind: u8,
    edge: u8,
    title: *const c_uchar,
    title_len: usize,
    has_title: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let zone = Zone::from_parts(kind, edge);
    // SAFETY: the caller's obligation, restated above.
    let title = unsafe { title_of(title, title_len, has_title) };
    let mut blob = vec![zone.mark().code()];
    push_text(&mut blob, &zone.label(title.as_deref()));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The floating chip for the destination `kind` names, in one delivery.
///
/// ```text
/// [u8 mark_code]
/// 1 × [u32 length][UTF-8 bytes]   // the chip's sentence, EMPTY over a canvas
/// ```
///
/// `kind` is `0` canvas, `1` a sidebar row, `2` a new tab, `3` a tear-off, anything else the
/// cancel. `title` is the pane the cursor is OVER, not the dragged one — off the canvas the
/// sentence is about where the pane is going. `detached` says the drag started in a satellite
/// window, which is what picks "merge beside" over "move beside".
///
/// # Safety
/// `title` must be null or `title_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_drop_destination(
    kind: u8,
    detached: bool,
    title: *const c_uchar,
    title_len: usize,
    has_title: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let destination = Destination::from_byte(kind);
    let origin = if detached { Origin::Detached } else { Origin::Tree };
    // SAFETY: the caller's obligation, restated above.
    let title = unsafe { title_of(title, title_len, has_title) };
    let mut blob = vec![destination.mark().code()];
    push_text(&mut blob, &destination.label(title.as_deref(), origin));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::drop_register::{Destination, Origin, Zone};

    use super::{slopdesk_ws_drop_destination, slopdesk_ws_drop_zone};
    use crate::testing::{delivered, runs};

    /// Crosses one zone and cuts the delivery back into `(mark, sentence)`.
    fn zone(kind: u8, edge: u8, title: Option<&str>) -> (u8, String) {
        let bytes = title.unwrap_or_default().as_bytes().to_vec();
        let blob = delivered(|out, cap| {
            // SAFETY: `bytes` and `out` are live locals for the call.
            unsafe {
                slopdesk_ws_drop_zone(kind, edge, bytes.as_ptr(), bytes.len(), title.is_some(), out, cap)
            }
        });
        let (code, rest) = blob
            .split_first()
            .map_or((0xFF, [].as_slice()), |(code, rest)| (*code, rest));
        (code, runs(rest, 1).first().cloned().unwrap_or_default())
    }

    /// EVERY zone byte, with and without an edge and with and without a name, says what the crate
    /// says — a parity sweep, not a probe.
    #[test]
    fn every_zone_crosses_unchanged() {
        for kind in 0..6_u8 {
            for edge in 0..5_u8 {
                for title in [None, Some("editor"), Some("   ")] {
                    let expected = Zone::from_parts(kind, edge);
                    assert_eq!(
                        zone(kind, edge, title),
                        (expected.mark().code(), expected.label(title)),
                        "kind {kind}, edge {edge}, title {title:?}",
                    );
                }
            }
        }
    }

    /// EVERY destination byte, both origins, with and without a name.
    #[test]
    fn every_destination_crosses_unchanged() {
        for kind in 0..6_u8 {
            for detached in [false, true] {
                for title in [None, Some("logs")] {
                    let bytes = title.unwrap_or_default().as_bytes().to_vec();
                    let blob = delivered(|out, cap| {
                        // SAFETY: `bytes` and `out` are live locals for the call.
                        unsafe {
                            slopdesk_ws_drop_destination(
                                kind,
                                detached,
                                bytes.as_ptr(),
                                bytes.len(),
                                title.is_some(),
                                out,
                                cap,
                            )
                        }
                    });
                    let expected = Destination::from_byte(kind);
                    let origin = if detached { Origin::Detached } else { Origin::Tree };
                    let (code, rest) = blob
                        .split_first()
                        .map_or((0xFF, [].as_slice()), |(code, rest)| (*code, rest));
                    assert_eq!(code, expected.mark().code(), "kind {kind}");
                    assert_eq!(
                        runs(rest, 1).first().map(String::as_str),
                        Some(expected.label(title, origin).as_str()),
                        "kind {kind}, detached {detached}",
                    );
                }
            }
        }
    }

    /// The canvas chip's sentence is empty AND its delivery is not — the reason the mark leads.
    #[test]
    fn an_empty_sentence_is_not_an_absent_answer() {
        let mut out = [0_u8; 64];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe {
            slopdesk_ws_drop_destination(0, false, core::ptr::null(), 0, false, out.as_mut_ptr(), out.len())
        };
        assert_eq!(needed, 5, "one mark byte and one empty length prefix");
        assert_eq!(out.get(1..5), Some([0, 0, 0, 0].as_slice()));
    }
}
