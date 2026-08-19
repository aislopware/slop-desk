//! The set of logical channels on one mux connection: the id allocator and the close state machine.
//!
//! `rust/slopdesk-wire`'s `mux::channels` owns both. This is the door.
//!
//! ## Why a handle
//! Unlike [`crate::mux_flow`]'s policies, a table is a map plus an eviction ring — state that
//! cannot cross in a call without copying every entry. So it is a handle, on [`crate::replay`]'s
//! convention: one free per new, and no overlapping calls on one handle.
//!
//! ## The states
//! A [`ChannelState`] crosses as its ordinal, and `4` means the id is UNKNOWN — never allocated or
//! already evicted. That is a distinction the caller has to keep: an unknown id's frame is dropped,
//! where a closed id's is a late frame on a channel that really existed.
//!
//! ## The rule, not just the state
//! [`slopdesk_channel_table_route`] is the demux decision itself, and it is here rather than in
//! Swift because it is six reads and writes of THIS table in one breath. Spelled on the far side it
//! was a rule living apart from the state it reasons about, which is the arrangement that lets one
//! of them be edited alone. The PAYLOAD never crosses: the decision names a channel, and the bytes
//! stay with whoever decoded them.

use core::ffi::c_uint;

use slopdesk_wire::mux::{ChannelState, ChannelTable, DropReason, FrameKind, RoutingDecision};

/// The handle's name at the boundary. An alias rather than a newtype: the door adds nothing to the
/// table, and a wrapper would only be a second name to keep in step.
pub type SlopDeskChannelTable = ChannelTable;

/// The id was never allocated or registered, or its entry has been evicted. Distinct from
/// [`STATE_CLOSED`], which is a channel that existed and finished.
pub const STATE_UNKNOWN: u32 = 4;

/// A state's ordinal on the wire between the two languages.
const fn ordinal(state: ChannelState) -> u32 {
    match state {
        ChannelState::Idle => 0,
        ChannelState::Open => 1,
        ChannelState::HalfClosed => 2,
        ChannelState::Closed => 3,
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_channel_table_new`] that has not been freed, and
/// no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskChannelTable) -> Option<&'a mut SlopDeskChannelTable> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    Some(unsafe { &mut *handle })
}

/// Builds an empty table.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_new() -> *mut SlopDeskChannelTable {
    Box::into_raw(Box::new(SlopDeskChannelTable::new()))
}

/// Frees a table. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_channel_table_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_channel_table_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_free(handle: *mut SlopDeskChannelTable) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Allocates the next unused ODD channel id and records it as idle.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_allocate(handle: *mut SlopDeskChannelTable) -> c_uint {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe { held(handle).map_or(0, ChannelTable::allocate) }
}

/// Marks `id` open, registering it if the peer chose it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_open(handle: *mut SlopDeskChannelTable, id: c_uint) {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe {
        if let Some(table) = held(handle) {
            table.open(id);
        }
    }
}

/// Records a refused open and answers the resulting state's ordinal.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_reject(handle: *mut SlopDeskChannelTable, id: c_uint) -> u32 {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe { held(handle).map_or(ordinal(ChannelState::Closed), |table| ordinal(table.reject(id))) }
}

/// Records that THIS side closed `id` and answers the resulting state's ordinal.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_local_close(
    handle: *mut SlopDeskChannelTable,
    id: c_uint,
) -> u32 {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe {
        held(handle).map_or(ordinal(ChannelState::Closed), |table| {
            ordinal(table.local_close(id))
        })
    }
}

/// Records that the PEER closed `id` and answers the resulting state's ordinal.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_remote_close(
    handle: *mut SlopDeskChannelTable,
    id: c_uint,
) -> u32 {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe {
        held(handle).map_or(ordinal(ChannelState::Closed), |table| {
            ordinal(table.remote_close(id))
        })
    }
}

/// The current state's ordinal, or [`STATE_UNKNOWN`] for an id the table has no entry for.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_state(handle: *mut SlopDeskChannelTable, id: c_uint) -> u32 {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe {
        held(handle).map_or(STATE_UNKNOWN, |table| {
            table.state_of(id).map_or(STATE_UNKNOWN, ordinal)
        })
    }
}

/// Total retained entries, live and closed — the diagnostic that asserts hostile open/close spam
/// cannot grow the table without bound.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_state_count(handle: *mut SlopDeskChannelTable) -> usize {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe { held(handle).map_or(0, |table| table.state_count()) }
}

/// Writes the ids that are not fully closed into `out`, and returns HOW MANY there are — the §4
/// convention, so a count larger than `cap` wrote nothing and says how much room to bring.
///
/// The order is unspecified: the caller's own type is a set.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be writable for `cap` ids.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_live(
    handle: *mut SlopDeskChannelTable,
    out: *mut c_uint,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's; the write below is covered by `cap`.
    unsafe {
        let Some(table) = held(handle) else {
            return 0;
        };
        let live = table.live_channel_ids();
        if live.len() > cap || out.is_null() {
            return live.len();
        }
        for (slot, id) in live.iter().enumerate() {
            out.add(slot).write(*id);
        }
        live.len()
    }
}

/// A routing verdict, flattened for the boundary.
///
/// A C enum with a payload is not a thing, so the discriminant and every field it could carry
/// travel together and the caller reads the ones its verdict names.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SlopDeskMuxRouting {
    /// `0` deliver, `1` lifecycle, `2` drop.
    pub verdict: u32,
    /// The channel the frame named, always meaningful.
    pub channel_id: u32,
    /// The resulting state's ordinal — for [`VERDICT_LIFECYCLE`] only; [`STATE_UNKNOWN`] otherwise.
    pub state: u32,
    /// Which drop situation — for [`VERDICT_DROP`] only; `0` otherwise.
    pub reason: u32,
}

/// Feed the frame's payload to `channel_id`.
pub const VERDICT_DELIVER: u32 = 0;
/// A lifecycle frame was applied; `state` is the channel's resulting state.
pub const VERDICT_LIFECYCLE: u32 = 1;
/// The frame was dropped; `reason` says which situation it was.
pub const VERDICT_DROP: u32 = 2;

/// The channel exists but is not fully open — a late frame on a real channel.
pub const DROP_NON_OPEN: u32 = 0;
/// No entry for the id at all — never allocated, or long since evicted.
pub const DROP_UNKNOWN: u32 = 1;

/// A verdict for a call that could not reach a table at all.
///
/// A null handle drops rather than delivers, and calls the id unknown, because that is the honest
/// reading: with no table there is no channel, and delivering bytes to one nobody described is the
/// single outcome this rule exists to prevent.
const fn unrouted(id: c_uint) -> SlopDeskMuxRouting {
    SlopDeskMuxRouting {
        verdict: VERDICT_DROP,
        channel_id: id,
        state: STATE_UNKNOWN,
        reason: DROP_UNKNOWN,
    }
}

/// Applies the demux rule to one frame and answers what to do with it, advancing the table exactly
/// as the frame requires.
///
/// `kind` is the mux envelope's own type byte. A byte no kind claims is refused the same way a null
/// handle is — dropped as unknown — because an unrecognised mux type is not a frame the rule can
/// reason about, and guessing would route bytes on a channel nobody described.
///
/// `accepted` is read for the open-ack kind alone; every other kind ignores it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_table_route(
    handle: *mut SlopDeskChannelTable,
    kind: u8,
    id: c_uint,
    accepted: bool,
) -> SlopDeskMuxRouting {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe {
        let (Some(table), Some(kind)) = (held(handle), FrameKind::from_wire(kind)) else {
            return unrouted(id);
        };
        match table.route(kind, id, accepted) {
            RoutingDecision::DeliverData { channel_id } => {
                SlopDeskMuxRouting {
                    verdict: VERDICT_DELIVER,
                    channel_id,
                    state: STATE_UNKNOWN,
                    reason: 0,
                }
            },
            RoutingDecision::Lifecycle { channel_id, state } => {
                SlopDeskMuxRouting {
                    verdict: VERDICT_LIFECYCLE,
                    channel_id,
                    state: ordinal(state),
                    reason: 0,
                }
            },
            RoutingDecision::Drop { channel_id, reason } => {
                SlopDeskMuxRouting {
                    verdict: VERDICT_DROP,
                    channel_id,
                    state: STATE_UNKNOWN,
                    reason: match reason {
                        DropReason::NonOpenChannel => DROP_NON_OPEN,
                        DropReason::UnknownChannel => DROP_UNKNOWN,
                    },
                }
            },
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "the tests drive the same C entry points every caller does"
    )]

    use super::{
        DROP_NON_OPEN, DROP_UNKNOWN, STATE_UNKNOWN, VERDICT_DELIVER, VERDICT_DROP, VERDICT_LIFECYCLE,
        slopdesk_channel_table_allocate, slopdesk_channel_table_free, slopdesk_channel_table_live,
        slopdesk_channel_table_local_close, slopdesk_channel_table_new, slopdesk_channel_table_open,
        slopdesk_channel_table_remote_close, slopdesk_channel_table_route, slopdesk_channel_table_state,
        slopdesk_channel_table_state_count,
    };

    /// The close symmetry and the unknown-vs-closed distinction, through the door: an id that was
    /// never registered must answer UNKNOWN, and a close for it must create no entry.
    #[test]
    fn the_close_handshake_and_the_unknown_id_both_cross_intact() {
        let table = unsafe { slopdesk_channel_table_new() };
        let id = unsafe { slopdesk_channel_table_allocate(table) };
        assert_eq!(id, 1, "the first id is odd and is 1");
        unsafe { slopdesk_channel_table_open(table, id) };
        assert_eq!(unsafe { slopdesk_channel_table_state(table, id) }, 1);
        assert_eq!(unsafe { slopdesk_channel_table_local_close(table, id) }, 2);
        assert_eq!(unsafe { slopdesk_channel_table_remote_close(table, id) }, 3);

        assert_eq!(unsafe { slopdesk_channel_table_state(table, 99) }, STATE_UNKNOWN);
        assert_eq!(unsafe { slopdesk_channel_table_remote_close(table, 99) }, 3);
        assert_eq!(
            unsafe { slopdesk_channel_table_state(table, 99) },
            STATE_UNKNOWN,
            "a close for an unknown id must not create an entry",
        );
        assert_eq!(unsafe { slopdesk_channel_table_state_count(table) }, 1);
        unsafe { slopdesk_channel_table_free(table) };
    }

    /// The live set crosses under the §4 convention, so a caller that brought too small a buffer is
    /// told the size rather than handed a truncated set.
    #[test]
    fn the_live_set_is_sized_before_it_is_written() {
        let table = unsafe { slopdesk_channel_table_new() };
        for _ in 0..3 {
            let id = unsafe { slopdesk_channel_table_allocate(table) };
            unsafe { slopdesk_channel_table_open(table, id) };
        }
        let mut small = [0u32; 2];
        assert_eq!(
            unsafe { slopdesk_channel_table_live(table, small.as_mut_ptr(), small.len()) },
            3,
        );
        assert_eq!(small, [0, 0], "a refusal must not write a partial set");

        let mut room = [0u32; 3];
        assert_eq!(
            unsafe { slopdesk_channel_table_live(table, room.as_mut_ptr(), room.len()) },
            3,
        );
        room.sort_unstable();
        assert_eq!(room, [1, 3, 5]);
        unsafe { slopdesk_channel_table_free(table) };
    }

    /// The three verdicts cross intact, and the flattened struct only ever means what its verdict
    /// says it means.
    #[test]
    fn each_verdict_crosses_with_the_fields_it_claims() {
        let table = unsafe { slopdesk_channel_table_new() };
        let id = unsafe { slopdesk_channel_table_allocate(table) };
        unsafe { slopdesk_channel_table_open(table, id) };

        let deliver = unsafe { slopdesk_channel_table_route(table, 3, id, false) };
        assert_eq!(deliver.verdict, VERDICT_DELIVER);
        assert_eq!(deliver.channel_id, id);

        let dropped = unsafe { slopdesk_channel_table_route(table, 3, 404, false) };
        assert_eq!(dropped.verdict, VERDICT_DROP);
        assert_eq!(dropped.reason, DROP_UNKNOWN);

        let closed = unsafe { slopdesk_channel_table_route(table, 4, id, false) };
        assert_eq!(closed.verdict, VERDICT_LIFECYCLE);
        assert_eq!(closed.state, 2, "the first close half-closes");

        let late = unsafe { slopdesk_channel_table_route(table, 3, id, false) };
        assert_eq!(late.verdict, VERDICT_DROP);
        assert_eq!(
            late.reason, DROP_NON_OPEN,
            "a known channel that is not open is not unknown"
        );
        unsafe { slopdesk_channel_table_free(table) };
    }

    /// A frame the rule cannot name, and a call with no table at all, both DROP. Failing open here
    /// would route bytes on a channel nobody described, which is the one outcome the rule exists to
    /// prevent — the opposite default from the platform tables elsewhere in this crate.
    #[test]
    fn an_unknown_type_byte_and_a_null_handle_both_drop() {
        let table = unsafe { slopdesk_channel_table_new() };
        let id = unsafe { slopdesk_channel_table_allocate(table) };
        unsafe { slopdesk_channel_table_open(table, id) };

        let bogus = unsafe { slopdesk_channel_table_route(table, 9, id, false) };
        assert_eq!(bogus.verdict, VERDICT_DROP);
        assert_eq!(bogus.reason, DROP_UNKNOWN);
        assert_eq!(
            unsafe { slopdesk_channel_table_state(table, id) },
            1,
            "an unroutable byte must not have touched the table",
        );

        let nowhere = unsafe { slopdesk_channel_table_route(core::ptr::null_mut(), 3, 7, false) };
        assert_eq!(nowhere.verdict, VERDICT_DROP);
        assert_eq!(nowhere.channel_id, 7);
        assert_eq!(nowhere.state, STATE_UNKNOWN);
        unsafe { slopdesk_channel_table_free(table) };
    }
}
