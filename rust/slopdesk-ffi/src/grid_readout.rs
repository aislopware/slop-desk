//! What a terminal pane says about a grid it did not choose, in C.
//!
//! The rules are `slopdesk_workspace::grid_readout`; what is here is the marshalling.
//!
//! ## Two doors, and the caller's own lookup between them
//!
//! [`slopdesk_ws_grid_clamped_by`] is the roster's third join and it crosses the way the two next
//! door do: a client is a dense `u32` token the caller minted, an offer is that token beside the
//! size it stands for, and the answer is a CODE plus a POSITION into the array the caller still
//! holds. No `UUID` and no roster of labels crosses.
//!
//! [`slopdesk_ws_grid_readout`] then prints the sentence, and it takes exactly ONE label — the one
//! the join already picked, which the near side read out of a map it was already holding. Folding
//! the two into a single door would mean crossing every client's label to print one of them, which
//! is the allocation `docs/55` ranks against. Every literal in the readout is on the far side,
//! including the word for a client nothing can name.
//!
//! `0` back from the readout means the host has resolved NO grid, and it cannot collide with a real
//! answer: a published grid always prints at least `1×1`, so the empty string is not something this
//! door can otherwise say.

use core::ffi::c_uchar;

use slopdesk_workspace::grid_readout::{self, Attribution, Offer};
use slopdesk_workspace::mirror_fold::RosterClient;

use crate::mirror_fold::SlopDeskWsPresenceClient;
use crate::{borrow, deliver, optional_of};

/// One attachment's standing offer, as the join needs to see it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsGridOffer {
    /// The dense token the caller minted for this attachment's client instance id.
    pub token: u32,
    /// The columns this attachment stands for.
    pub cols: u32,
    /// The rows this attachment stands for.
    pub rows: u32,
    /// Whether this attachment votes in the pane's `min` fold at all.
    pub contributes: bool,
}

/// Who the pane's resolved grid is attributed to: `0` the host has published none · `1` the grid
/// alone · `2` the client at the position written to `position` · `3` a client nothing names.
///
/// `position` is written ONLY for `2`, so a caller that read it on any other code would be reading
/// whatever it left there — the verdict is the code, and the position is the part of it that only
/// one arm has.
///
/// `has_own` is false for a client with no workspace channel of its own, which is then not in the
/// roster to be excluded from it.
///
/// # Safety
/// Both input arrays must be readable for their declared lengths for the whole call, and `position`
/// must be null or writable for one `uint32_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_grid_clamped_by(
    resolved_cols: u32,
    resolved_rows: u32,
    offers: *const SlopDeskWsGridOffer,
    offers_len: usize,
    clients: *const SlopDeskWsPresenceClient,
    clients_len: usize,
    has_own: bool,
    own: u32,
    position: *mut u32,
) -> c_uchar {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent_offers = unsafe { borrow(offers, offers_len) };
    // SAFETY: as above.
    let lent_clients = unsafe { borrow(clients, clients_len) };
    let standing: Vec<Offer> = lent_offers.iter().map(|offer| offer_of(*offer)).collect();
    let roster: Vec<RosterClient> = lent_clients.iter().map(|client| seat_of(*client)).collect();
    let verdict = grid_readout::clamped_by(
        resolved_cols,
        resolved_rows,
        &standing,
        &roster,
        optional_of(has_own, own),
    );
    if let (Some(found), false) = (verdict.position(), position.is_null()) {
        // SAFETY: non-null and writable for one `u32` by the caller's obligation above.
        unsafe {
            position.write(found);
        }
    }
    verdict.code()
}

/// The pane's readout — `120×40 · sized by MacBook Pro` — for the verdict the join answered.
///
/// `attribution` is that verdict's code, and `label` is read only for code `2`. An empty label
/// under `2` prints the unnamed word rather than a sentence that trails off: an empty label is
/// exactly what the join filters out, and the honest answer beats the dangling one.
///
/// Returns `0` when the host has resolved no grid, which is the only way this door says nothing.
///
/// # Safety
/// `(label, label_len)` must be readable for the call, and `out` null or writable for `capacity`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_grid_readout(
    cols: u32,
    rows: u32,
    attribution: c_uchar,
    label: *const c_uchar,
    label_len: usize,
    out: *mut c_uchar,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let named = String::from_utf8_lossy(unsafe { borrow(label, label_len) });
    let answer =
        grid_readout::text(cols, rows, Attribution::from_code(attribution, &named)).unwrap_or_default();
    // SAFETY: `out` is null or writable for `capacity` bytes by the caller's obligation.
    unsafe { deliver(answer.as_bytes(), out, capacity) }
}

/// One lent offer, as the rules know it.
const fn offer_of(offer: SlopDeskWsGridOffer) -> Offer {
    Offer {
        token: offer.token,
        contributes: offer.contributes,
        cols: offer.cols,
        rows: offer.rows,
    }
}

/// One lent roster row, as the rules know it.
const fn seat_of(client: SlopDeskWsPresenceClient) -> RosterClient {
    RosterClient {
        token: client.token,
        labelled: client.labelled,
        viewing: client.viewing,
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::grid_readout::{self, Attribution};

    use super::{SlopDeskWsGridOffer, slopdesk_ws_grid_clamped_by, slopdesk_ws_grid_readout};
    use crate::mirror_fold::SlopDeskWsPresenceClient;
    use crate::testing::delivered;

    /// The three clients every case joins against: two named, one that published no label.
    fn clients() -> [SlopDeskWsPresenceClient; 3] {
        [
            SlopDeskWsPresenceClient {
                token: 1,
                labelled: true,
                viewing: false,
            },
            SlopDeskWsPresenceClient {
                token: 2,
                labelled: true,
                viewing: false,
            },
            SlopDeskWsPresenceClient {
                token: 3,
                labelled: false,
                viewing: false,
            },
        ]
    }

    /// A contributing offer at the size beside it.
    const fn offer(token: u32, cols: u32, rows: u32) -> SlopDeskWsGridOffer {
        SlopDeskWsGridOffer {
            token,
            cols,
            rows,
            contributes: true,
        }
    }

    /// Asks the door, and reports the code beside whatever position it chose to write.
    fn clamp(cols: u32, rows: u32, offers: &[SlopDeskWsGridOffer], has_own: bool, own: u32) -> (u8, u32) {
        let seats = clients();
        let mut position = u32::MAX;
        // SAFETY: both arrays and the out-slot are live locals for the call.
        let code = unsafe {
            slopdesk_ws_grid_clamped_by(
                cols,
                rows,
                offers.as_ptr(),
                offers.len(),
                seats.as_ptr(),
                seats.len(),
                has_own,
                own,
                &raw mut position,
            )
        };
        (code, position)
    }

    /// Every arm of the join crosses as the rule decides it, and the POSITION is written for the
    /// named arm alone — the one mistake a code-plus-out-parameter shape invites.
    #[test]
    fn every_arm_crosses_and_only_the_named_one_writes_a_position() {
        assert_eq!(clamp(0, 40, &[offer(1, 0, 40)], false, 0), (0, u32::MAX));
        assert_eq!(clamp(120, 40, &[offer(1, 200, 60)], false, 0), (1, u32::MAX));
        assert_eq!(clamp(120, 40, &[offer(2, 120, 40)], false, 0), (2, 1));
        assert_eq!(clamp(120, 40, &[offer(3, 120, 40)], false, 0), (3, u32::MAX));
        assert_eq!(
            clamp(120, 40, &[offer(1, 120, 40)], true, 1),
            (1, u32::MAX),
            "a client that chose the grid needs no explanation of it"
        );
    }

    /// An empty offer list is a legal roster state — a pane whose attachments have all gone —
    /// and it must answer the grid alone rather than reading a null array.
    #[test]
    fn an_empty_offer_list_answers_the_grid_alone() {
        assert_eq!(clamp(120, 40, &[], false, 0), (1, u32::MAX));
    }

    /// A null out-slot is honoured: the code is still the answer, and nothing is written.
    #[test]
    fn a_null_position_slot_still_answers() {
        let seats = clients();
        let offers = [offer(2, 120, 40)];
        // SAFETY: both arrays are live locals; a null out-slot is the documented way to skip it.
        let code = unsafe {
            slopdesk_ws_grid_clamped_by(
                120,
                40,
                offers.as_ptr(),
                offers.len(),
                seats.as_ptr(),
                seats.len(),
                false,
                0,
                core::ptr::null_mut(),
            )
        };
        assert_eq!(code, 2);
    }

    /// The sentence crosses verbatim for every attribution the join can answer.
    #[test]
    fn the_readout_crosses_verbatim() {
        let say = |cols: u32, rows: u32, code: u8, label: &str| {
            let blob = delivered(|out, cap| {
                // SAFETY: the label and `out` are live locals for the call.
                unsafe { slopdesk_ws_grid_readout(cols, rows, code, label.as_ptr(), label.len(), out, cap) }
            });
            String::from_utf8_lossy(&blob).into_owned()
        };
        assert_eq!(say(120, 40, 2, "MacBook Pro"), "120×40 · sized by MacBook Pro");
        assert_eq!(say(120, 40, 1, "MacBook Pro"), "120×40");
        assert_eq!(say(120, 40, 3, ""), "120×40 · sized by another client");
        assert_eq!(say(120, 40, 2, ""), "120×40 · sized by another client");
        assert_eq!(
            say(120, 40, 2, "MacBook Pro"),
            grid_readout::text(120, 40, Attribution::Named("MacBook Pro")).unwrap_or_default()
        );
    }

    /// An unpublished grid is the door's ONE silence, on either axis — and `0` back cannot be
    /// mistaken for a real answer, because a published grid always prints at least `1×1`.
    #[test]
    fn an_unpublished_grid_is_the_only_silence() {
        for (cols, rows) in [(0_u32, 0_u32), (0, 40), (120, 0)] {
            // SAFETY: a null label with a zero length is an empty borrow, and `out` is null with a
            // zero capacity, which is the documented way to ask for the length.
            let needed = unsafe {
                slopdesk_ws_grid_readout(cols, rows, 2, core::ptr::null(), 0, core::ptr::null_mut(), 0)
            };
            assert_eq!(needed, 0, "{cols}×{rows}");
        }
        let smallest = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_grid_readout(1, 1, 1, core::ptr::null(), 0, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&smallest), "1×1");
    }

    /// A short buffer is told the length and written nothing — §4's retry contract.
    #[test]
    fn a_short_buffer_is_told_the_length_and_left_untouched() {
        let label = "MacBook Pro";
        let mut out = [0xAA_u8; 4];
        // SAFETY: the label and `out` are live locals for the call.
        let needed = unsafe {
            slopdesk_ws_grid_readout(
                120,
                40,
                2,
                label.as_ptr(),
                label.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert!(needed > out.len());
        assert_eq!(out, [0xAA; 4], "nothing was written");
    }
}
