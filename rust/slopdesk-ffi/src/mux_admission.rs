//! Whether an arriving mux frame is admissible, and what a channel-ending event tears down.
//!
//! `rust/slopdesk-wire`'s `mux::admission` owns both rules. This is the door.
//!
//! ## Why by value and why stateless
//! Neither question reads any state this side keeps: the four facts the ladder is a function of are
//! ones the caller already has in hand at the moment it asks (a role, a link, a type byte, two
//! counts it maintains anyway), and a teardown is a function of two enums. So there is nothing to
//! allocate, nothing to free, and no handle whose lifetime could be got wrong —
//! [`crate::mux_flow`]'s convention rather than [`crate::mux_channels`]'s.
//!
//! ## What crosses and what does not
//! No payload and no channel id. The caller knows which channel it is asking about; what comes back
//! is an instruction about the pair of sub-channels it is already holding. That keeps this door off
//! the allocation ledger docs/55 §4c ranks doors by: it runs once per inbound frame, and it
//! materializes nothing on either side.
//!
//! ## The absent state is a value, not a sentinel of the caller's choosing
//! [`crate::mux_channels::STATE_UNKNOWN`] is the ordinal a table answers for an id it has never
//! heard of, and this door reads the same one. Spelling a second "no state" here would be two
//! readings of one distinction across two doors that are asked in the same breath.

use slopdesk_wire::mux::admission::{
    Admission, Arrival, Ignored, Link, Refusal, Role, TableStep, Teardown, admit, peer_close, poisoned,
};
use slopdesk_wire::mux::{ChannelState, FrameKind};

use crate::mux_channels::STATE_UNKNOWN;

/// Hand the frame to the router.
pub const ADMISSION_PROCEED: u32 = 0;
/// Refuse the open with `accepted: false` — the connection is at its channel cap.
pub const ADMISSION_REFUSE_OVER_CAP: u32 = 1;
/// Refuse the open with `accepted: false` — the id already reached a terminal state.
pub const ADMISSION_REFUSE_REOPEN: u32 = 2;
/// Drop it: an open never rides the CONTROL link.
pub const ADMISSION_DROP_OPEN_ON_CONTROL: u32 = 3;
/// Drop it: an open never arrives at the side that initiates opens.
pub const ADMISSION_DROP_OPEN_AT_INITIATOR: u32 = 4;

/// What one [`slopdesk_mux_teardown`] decided.
///
/// The two table fields carry a [`TableStep`] ordinal: `0` hold, `1` local close, `2` remote close.
/// `hold` is the router's own step already applied, not an absence.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMuxTeardown {
    /// Unregister the DATA sub-channel and drop its receive-window accounting.
    pub drop_data: bool,
    /// Unregister the CONTROL sub-channel.
    pub drop_control: bool,
    /// Fire, or buffer, the host's close hook. Never true on the client.
    pub reap: bool,
    /// How the DATA table advances.
    pub data_table: u8,
    /// How the CONTROL table advances.
    pub control_table: u8,
}

/// The role an ordinal names, defaulting to the responder for a byte no role claims.
///
/// Fails to `Host` rather than to `Client` because the host's ladder is the STRICTER of the two: a
/// garbled ordinal that read as a client would skip the cap and the reopen refusal, which are the
/// two guards that bound memory and forks.
const fn role_of(ordinal: u32) -> Role {
    if ordinal == 0 { Role::Client } else { Role::Host }
}

/// The link an ordinal names, defaulting to CONTROL.
///
/// Same reasoning inverted: an open on CONTROL is dropped, so a garbled link cannot open anything.
const fn link_of(ordinal: u32) -> Link {
    if ordinal == 1 { Link::Data } else { Link::Control }
}

/// The prior DATA-table state an ordinal names, or `None` for [`STATE_UNKNOWN`] and anything past
/// it.
///
/// The threshold is read from [`crate::mux_channels`] rather than respelled: the two doors are
/// asked in the same breath, and a second reading of "no state" is the drift that would let one of
/// them call a terminal id unknown.
const fn prior_state_of(ordinal: u32) -> Option<ChannelState> {
    if ordinal >= STATE_UNKNOWN {
        return None;
    }
    match ordinal {
        0 => Some(ChannelState::Idle),
        1 => Some(ChannelState::Open),
        2 => Some(ChannelState::HalfClosed),
        3 => Some(ChannelState::Closed),
        _ => None,
    }
}

/// Decides what the connection does with one arriving frame before the routing decision runs.
///
/// `role` is 0 client / 1 host; `link` is 0 control / 1 data; `frame_type` is the mux envelope's
/// own type byte. A `frame_type` no kind claims answers [`ADMISSION_PROCEED`] — the routing
/// decision below is where an unknown type is dropped, and duplicating that judgement here would be
/// a second copy of the frame vocabulary.
///
/// Returns one of the five `ADMISSION_*` constants.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_mux_admit(
    role: u32,
    link: u32,
    frame_type: u8,
    registered: bool,
    live_channels: u32,
    prior_data_state: u32,
) -> u32 {
    let Some(kind) = FrameKind::from_wire(frame_type) else {
        return ADMISSION_PROCEED;
    };
    let arrival = Arrival {
        role: role_of(role),
        link: link_of(link),
        kind,
        registered,
        live_channels: live_channels as usize,
        prior_data_state: prior_state_of(prior_data_state),
    };
    match admit(&arrival) {
        Admission::Proceed => ADMISSION_PROCEED,
        Admission::Refuse(Refusal::OverCap) => ADMISSION_REFUSE_OVER_CAP,
        Admission::Refuse(Refusal::Reopen) => ADMISSION_REFUSE_REOPEN,
        Admission::Drop(Ignored::OpenOnControlLink) => ADMISSION_DROP_OPEN_ON_CONTROL,
        Admission::Drop(Ignored::OpenAtInitiator) => ADMISSION_DROP_OPEN_AT_INITIATOR,
    }
}

/// The ordinal a table step crosses as.
const fn step_ordinal(step: TableStep) -> u8 {
    match step {
        TableStep::Hold => 0,
        TableStep::Local => 1,
        TableStep::Remote => 2,
    }
}

/// Flattens a verdict for the boundary.
const fn crossed(verdict: Teardown) -> SlopDeskMuxTeardown {
    SlopDeskMuxTeardown {
        drop_data: verdict.drop_data,
        drop_control: verdict.drop_control,
        reap: verdict.reap,
        data_table: step_ordinal(verdict.data_table),
        control_table: step_ordinal(verdict.control_table),
    }
}

/// What a sub-channel's own inner decode fault tears down.
///
/// `role` is 0 client / 1 host; `link` is 0 control / 1 data.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_mux_teardown_poisoned(role: u32, link: u32) -> SlopDeskMuxTeardown {
    crossed(poisoned(role_of(role), link_of(link)))
}

/// What a peer's close on one link tears down.
///
/// `role` is 0 client / 1 host; `link` is 0 control / 1 data. The arriving link's own table is
/// reported as `hold`: the router advanced it already, and that is what produced the lifecycle
/// decision this call answers.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_mux_teardown_peer_close(role: u32, link: u32) -> SlopDeskMuxTeardown {
    crossed(peer_close(role_of(role), link_of(link)))
}

#[cfg(test)]
mod tests {
    use super::{
        ADMISSION_DROP_OPEN_AT_INITIATOR, ADMISSION_DROP_OPEN_ON_CONTROL, ADMISSION_PROCEED,
        ADMISSION_REFUSE_OVER_CAP, ADMISSION_REFUSE_REOPEN, STATE_UNKNOWN, slopdesk_mux_admit,
        slopdesk_mux_teardown_peer_close, slopdesk_mux_teardown_poisoned,
    };

    const CLIENT: u32 = 0;
    const HOST: u32 = 1;
    const CONTROL: u32 = 0;
    const DATA: u32 = 1;
    const OPEN_FRAME: u8 = 1;
    const DATA_FRAME: u8 = 3;
    const CAP: u32 = 256;

    #[test]
    fn the_five_verdicts_reach_the_boundary() {
        assert_eq!(
            slopdesk_mux_admit(HOST, DATA, OPEN_FRAME, false, 0, STATE_UNKNOWN),
            ADMISSION_PROCEED,
        );
        assert_eq!(
            slopdesk_mux_admit(HOST, DATA, OPEN_FRAME, false, CAP, STATE_UNKNOWN),
            ADMISSION_REFUSE_OVER_CAP,
        );
        assert_eq!(
            slopdesk_mux_admit(HOST, DATA, OPEN_FRAME, false, 0, 3),
            ADMISSION_REFUSE_REOPEN,
        );
        assert_eq!(
            slopdesk_mux_admit(HOST, CONTROL, OPEN_FRAME, false, 0, STATE_UNKNOWN),
            ADMISSION_DROP_OPEN_ON_CONTROL,
        );
        assert_eq!(
            slopdesk_mux_admit(CLIENT, DATA, OPEN_FRAME, false, 0, STATE_UNKNOWN),
            ADMISSION_DROP_OPEN_AT_INITIATOR,
        );
    }

    #[test]
    fn a_frame_type_no_kind_claims_proceeds_to_the_router_that_owns_the_drop() {
        for byte in [0_u8, 6, 0xFF] {
            assert_eq!(
                slopdesk_mux_admit(HOST, DATA, byte, false, CAP, 3),
                ADMISSION_PROCEED,
                "{byte}",
            );
        }
    }

    #[test]
    fn a_garbled_role_or_link_takes_the_stricter_reading() {
        // Neither can be produced by the face, which spells both from an enum; the point is that a
        // corrupted one cannot buy a peer a shell.
        assert_eq!(
            slopdesk_mux_admit(9, DATA, OPEN_FRAME, false, CAP, STATE_UNKNOWN),
            ADMISSION_REFUSE_OVER_CAP,
        );
        assert_eq!(
            slopdesk_mux_admit(HOST, 9, OPEN_FRAME, false, 0, STATE_UNKNOWN),
            ADMISSION_DROP_OPEN_ON_CONTROL,
        );
    }

    #[test]
    fn a_state_ordinal_past_the_table_reads_as_unknown_rather_than_as_terminal() {
        for ordinal in [STATE_UNKNOWN, 99] {
            assert_eq!(
                slopdesk_mux_admit(HOST, DATA, OPEN_FRAME, false, 0, ordinal),
                ADMISSION_PROCEED,
                "{ordinal}",
            );
        }
    }

    #[test]
    fn a_non_open_frame_is_admitted_whatever_else_is_true() {
        assert_eq!(
            slopdesk_mux_admit(HOST, DATA, DATA_FRAME, false, CAP, 3),
            ADMISSION_PROCEED,
        );
    }

    #[test]
    fn the_two_teardowns_cross_as_the_rule_answers_them() {
        let poisoned_host = slopdesk_mux_teardown_poisoned(HOST, CONTROL);
        assert!(poisoned_host.drop_data && poisoned_host.drop_control && poisoned_host.reap);
        assert_eq!((poisoned_host.data_table, poisoned_host.control_table), (1, 1));

        let closed_host = slopdesk_mux_teardown_peer_close(HOST, DATA);
        assert!(closed_host.drop_data && closed_host.drop_control && closed_host.reap);
        assert_eq!((closed_host.data_table, closed_host.control_table), (0, 2));

        let closed_client = slopdesk_mux_teardown_peer_close(CLIENT, DATA);
        assert!(closed_client.drop_data);
        assert!(!closed_client.drop_control && !closed_client.reap);
        assert_eq!((closed_client.data_table, closed_client.control_table), (0, 0));
    }
}
