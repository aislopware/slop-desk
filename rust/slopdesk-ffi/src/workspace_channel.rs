//! The workspace channel's payloads — what rides inside `workspaceRequest` (17) and
//! `workspaceEvent` (37).
//!
//! `rust/slopdesk-wire`'s `workspace` module owns every layout. This is the door.
//!
//! ## Three shapes, picked by what the payload is
//! - **By value** where the payload is fixed-size: a presence update and an intent result are a
//!   handful of scalars and two ids, so the record IS the crossing and nothing is interned.
//! - **Record plus arena** where a payload carries text: a subscribe's label, a roster client's
//!   label. The text is an `(offset, length)` into a byte pool passed alongside, so no record makes
//!   the caller own a lifetime.
//! - **Eliding** for the one field that is opaque and unbounded here: an intent's arguments. The
//!   decode answers WHERE they sit in the caller's own payload rather than copying them into an
//!   arena the caller would immediately copy out of again.
//!
//! ## The roster is three arrays, not a tree
//! A roster is panes each holding attachments, which cannot cross as a nest without a pointer per
//! pane. Instead the attachments are ONE flat array and each pane names its run `(offset, count)`
//! into it — the same trick the arena plays for text, on records instead of bytes.
//!
//! ## Sizing takes no probing call
//! Every count is bounded by the payload's own length divided by the smallest a record of that kind
//! can be, and the arena can never exceed the payload. [`slopdesk_workspace_constant`] vends those
//! divisors so the caller never respells them.

use core::ffi::c_uchar;

use slopdesk_wire::workspace::{
    ROSTER_ATTACHMENT_BYTES, ROSTER_CLIENT_MIN_BYTES, ROSTER_PANE_MIN_BYTES, WorkspaceIntent,
    WorkspaceIntentResult, WorkspacePresenceRoster, WorkspacePresenceUpdate, WorkspaceRosterAttachment,
    WorkspaceRosterClient, WorkspaceRosterPane, WorkspaceSubscribe,
};

use crate::wire_message::{WIRE_DECODE_AGAIN, WIRE_DECODE_OK, verdict};
use crate::workspace::Uuid;
use crate::{TextArena, arena_text, borrow, deliver, lend, records_of};

/// A text field, as an `(offset, length)` pair into the call's arena.
///
/// The one exception is [`SlopDeskWorkspaceIntent::args`], whose offsets are into the caller's
/// PAYLOAD — see that field.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceText {
    /// Where the field starts.
    pub offset: u32,
    /// How long it is, in bytes.
    pub length: u32,
}

/// A run of records inside the flat attachment array a roster crossing carries.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceRun {
    /// The index of the first record.
    pub offset: u32,
    /// How many records the run holds.
    pub count: u32,
}

/// `subscribe` — verb 0.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceSubscribe {
    /// The client's per-connection identity.
    pub client_instance_id: Uuid,
    /// The epoch this client believes it holds.
    pub known_epoch: Uuid,
    /// The state number this client believes it holds.
    pub known_state_num: i64,
    /// The client's device name, into the arena.
    pub label: SlopDeskWorkspaceText,
    /// The far end's device class as a raw byte.
    pub client_kind: u8,
    /// The subscribe flags.
    pub flags: u8,
}

/// `presence` — verb 2.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspacePresence {
    /// The client's monotone presence clock.
    pub presence_clock: i64,
    /// The tab this client is looking at.
    pub viewing_tab_id: Uuid,
    /// The pane this client is looking at.
    pub viewing_pane_id: Uuid,
    /// The client's viewport width in cells.
    pub cols: u16,
    /// The client's viewport height in cells.
    pub rows: u16,
    /// The same bits a subscribe carries.
    pub flags: u8,
}

/// `intent` — verb 3, with the arguments left where they lie.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceIntent {
    /// The client-minted id the result will name.
    pub intent_id: Uuid,
    /// Where the arguments sit in the caller's PAYLOAD — not in any arena, because an intent's
    /// arguments are opaque here and run to the frame cap.
    pub args: SlopDeskWorkspaceText,
    /// Which mutation, carried raw.
    pub op: u8,
}

/// `intentResult` — kind 3.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceIntentResult {
    /// The intent this answers.
    pub intent_id: Uuid,
    /// The outcome as a raw byte.
    pub status: u8,
}

/// One client in the presence roster — kind 2.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceRosterClient {
    /// The client's per-connection identity.
    pub client_instance_id: Uuid,
    /// The tab it is looking at.
    pub viewing_tab_id: Uuid,
    /// The pane it is looking at.
    pub viewing_pane_id: Uuid,
    /// Its device name, into the arena.
    pub label: SlopDeskWorkspaceText,
    /// Its viewport width in cells.
    pub cols: u16,
    /// Its viewport height in cells.
    pub rows: u16,
    /// Its device class as a raw byte.
    pub client_kind: u8,
    /// The same bits a subscribe carries.
    pub flags: u8,
}

/// One client attached to a pane.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceRosterAttachment {
    /// Which client.
    pub client_instance_id: Uuid,
    /// The width it asks for.
    pub cols: u16,
    /// The height it asks for.
    pub rows: u16,
    /// Whether it participates in the size fold.
    pub contributes: bool,
}

/// One pane in the roster, naming its run of the flat attachment array.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceRosterPane {
    /// Which pane.
    pub pane_id: Uuid,
    /// This pane's attachments, as a run of the attachment array.
    pub attachments: SlopDeskWorkspaceRun,
    /// The width the fold resolved.
    pub resolved_cols: u16,
    /// The height the fold resolved.
    pub resolved_rows: u16,
}

/// Interns `bytes` and answers where they landed.
fn intern(pool: &mut TextArena, bytes: &[u8]) -> SlopDeskWorkspaceText {
    let (offset, length) = pool.intern(bytes);
    SlopDeskWorkspaceText { offset, length }
}

/// Reads a text field out of the CALLER's arena.
///
/// Lossy on purpose: these bytes are the caller's, so a bad sequence is not something this crate
/// refused — unlike a decode, where invalid UTF-8 is malformed.
fn text(arena: &[u8], field: SlopDeskWorkspaceText) -> String {
    arena_text(arena, field.offset, field.length)
}

/// Writes one record into the caller's slot, when there is one.
///
/// # Safety
/// `out` must be null, or writable for one `T`.
#[expect(
    unsafe_code,
    reason = "writing the caller's single out-record IS the boundary this module documents"
)]
unsafe fn place<T>(out: *mut T, record: T) -> u32 {
    if out.is_null() {
        return WIRE_DECODE_AGAIN;
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one `T` for this call.
    unsafe { out.write(record) };
    WIRE_DECODE_OK
}

/// Writes a count into an out-parameter that may be null.
///
/// # Safety
/// `out` must be null, or writable for one `usize`.
#[expect(
    unsafe_code,
    reason = "an optional out-count is part of the §4 shape: a caller may size before it fills"
)]
const unsafe fn count_into(out: *mut usize, value: usize) {
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for this call.
        unsafe { out.write(value) };
    }
}

/// Copies records into the caller's array, when they fit.
///
/// # Safety
/// `slots` must be null, or writable for `cap` records.
#[expect(
    unsafe_code,
    reason = "writing the caller's record array IS the boundary this module documents"
)]
unsafe fn place_all<T: Copy>(built: &[T], slots: *mut T, cap: usize) -> bool {
    if built.len() > cap || (slots.is_null() && !built.is_empty()) {
        return false;
    }
    for (slot, record) in built.iter().enumerate() {
        // SAFETY: `built.len() <= cap` was just checked and `slots` is writable for `cap`.
        unsafe { slots.add(slot).write(*record) };
    }
    true
}

// ---------------------------------------------------------------------------------------------- //
// subscribe — verb 0
// ---------------------------------------------------------------------------------------------- //

/// Encodes a subscribe.
///
/// # Safety
/// `record` must point to one live record; `arena` must describe live memory for the call; `out`
/// must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_encode_subscribe(
    record: *const SlopDeskWorkspaceSubscribe,
    arena: *const c_uchar,
    arena_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let Some(record) = records_of(record, 1).first().copied() else {
            return 0;
        };
        let payload = WorkspaceSubscribe {
            client_instance_id: record.client_instance_id.bytes,
            client_kind: record.client_kind,
            known_epoch: record.known_epoch.bytes,
            known_state_num: record.known_state_num,
            flags: record.flags,
            label: text(borrow(arena, arena_len), record.label),
        };
        lend(out, cap, |writer| payload.encode_into(writer))
    }
}

/// Decodes a subscribe, interning its label at the front of `arena`.
///
/// # Safety
/// `payload` must describe live memory for the call; `out` must point to one writable record;
/// `arena` must be null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_decode_subscribe(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskWorkspaceSubscribe,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let decoded = match WorkspaceSubscribe::decode(borrow(payload, payload_len)) {
            Ok(decoded) => decoded,
            Err(error) => return verdict(&error),
        };
        let mut pool = TextArena::default();
        let record = SlopDeskWorkspaceSubscribe {
            client_instance_id: Uuid {
                bytes: decoded.client_instance_id,
            },
            known_epoch: Uuid {
                bytes: decoded.known_epoch,
            },
            known_state_num: decoded.known_state_num,
            label: intern(&mut pool, decoded.label.as_bytes()),
            client_kind: decoded.client_kind,
            flags: decoded.flags,
        };
        if pool.0.len() > arena_cap {
            return WIRE_DECODE_AGAIN;
        }
        deliver(&pool.0, arena, arena_cap);
        place(out, record)
    }
}

// ---------------------------------------------------------------------------------------------- //
// presence — verb 2
// ---------------------------------------------------------------------------------------------- //

/// Encodes a presence update.
///
/// # Safety
/// `record` must point to one live record; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_encode_presence(
    record: *const SlopDeskWorkspacePresence,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let Some(record) = records_of(record, 1).first().copied() else {
            return 0;
        };
        let payload = WorkspacePresenceUpdate {
            presence_clock: record.presence_clock,
            viewing_tab_id: record.viewing_tab_id.bytes,
            viewing_pane_id: record.viewing_pane_id.bytes,
            cols: record.cols,
            rows: record.rows,
            flags: record.flags,
        };
        lend(out, cap, |writer| payload.encode_into(writer))
    }
}

/// Decodes a presence update.
///
/// # Safety
/// `payload` must describe live memory for the call; `out` must point to one writable record.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_decode_presence(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskWorkspacePresence,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let decoded = match WorkspacePresenceUpdate::decode(borrow(payload, payload_len)) {
            Ok(decoded) => decoded,
            Err(error) => return verdict(&error),
        };
        place(out, SlopDeskWorkspacePresence {
            presence_clock: decoded.presence_clock,
            viewing_tab_id: Uuid {
                bytes: decoded.viewing_tab_id,
            },
            viewing_pane_id: Uuid {
                bytes: decoded.viewing_pane_id,
            },
            cols: decoded.cols,
            rows: decoded.rows,
            flags: decoded.flags,
        })
    }
}

// ---------------------------------------------------------------------------------------------- //
// intent — verb 3
// ---------------------------------------------------------------------------------------------- //

/// Encodes an intent whose arguments the caller lends.
///
/// # Safety
/// `intent_id` must point to one live id; `args` must describe live memory for the call; `out` must
/// be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_encode_intent(
    intent_id: *const Uuid,
    op: u8,
    args: *const c_uchar,
    args_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let Some(id) = records_of(intent_id, 1).first().copied() else {
            return 0;
        };
        let args = borrow(args, args_len);
        lend(out, cap, |writer| {
            WorkspaceIntent::encode_parts_into(writer, &id.bytes, op, args);
        })
    }
}

/// Decodes an intent, leaving its arguments in the caller's payload.
///
/// # Safety
/// `payload` must describe live memory for the call; `out` must point to one writable record.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_decode_intent(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskWorkspaceIntent,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let (intent_id, op, args) = match WorkspaceIntent::decode_leaving_args(borrow(payload, payload_len)) {
            Ok(parts) => parts,
            Err(error) => return verdict(&error),
        };
        place(out, SlopDeskWorkspaceIntent {
            intent_id: Uuid { bytes: intent_id },
            args: SlopDeskWorkspaceText {
                offset: u32::try_from(args.start).unwrap_or(u32::MAX),
                length: u32::try_from(args.len()).unwrap_or(u32::MAX),
            },
            op,
        })
    }
}

// ---------------------------------------------------------------------------------------------- //
// intentResult — kind 3
// ---------------------------------------------------------------------------------------------- //

/// Encodes an intent result.
///
/// # Safety
/// `record` must point to one live record; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_encode_intent_result(
    record: *const SlopDeskWorkspaceIntentResult,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let Some(record) = records_of(record, 1).first().copied() else {
            return 0;
        };
        let payload = WorkspaceIntentResult {
            intent_id: record.intent_id.bytes,
            status: record.status,
        };
        lend(out, cap, |writer| payload.encode_into(writer))
    }
}

/// Decodes an intent result.
///
/// # Safety
/// `payload` must describe live memory for the call; `out` must point to one writable record.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_decode_intent_result(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskWorkspaceIntentResult,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let decoded = match WorkspaceIntentResult::decode(borrow(payload, payload_len)) {
            Ok(decoded) => decoded,
            Err(error) => return verdict(&error),
        };
        place(out, SlopDeskWorkspaceIntentResult {
            intent_id: Uuid {
                bytes: decoded.intent_id,
            },
            status: decoded.status,
        })
    }
}

// ---------------------------------------------------------------------------------------------- //
// presence roster — kind 2
// ---------------------------------------------------------------------------------------------- //

/// Encodes a presence roster from three flat arrays and one arena.
///
/// # Safety
/// Each array must be null or describe its declared count of live records; `arena` must describe
/// live memory for the call; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_encode_roster(
    clients: *const SlopDeskWorkspaceRosterClient,
    client_count: usize,
    panes: *const SlopDeskWorkspaceRosterPane,
    pane_count: usize,
    attachments: *const SlopDeskWorkspaceRosterAttachment,
    attachment_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let arena = borrow(arena, arena_len);
        let all_attachments = records_of(attachments, attachment_count);
        let roster = WorkspacePresenceRoster {
            clients: records_of(clients, client_count)
                .iter()
                .map(|record| {
                    WorkspaceRosterClient {
                        client_instance_id: record.client_instance_id.bytes,
                        client_kind: record.client_kind,
                        flags: record.flags,
                        viewing_tab_id: record.viewing_tab_id.bytes,
                        viewing_pane_id: record.viewing_pane_id.bytes,
                        cols: record.cols,
                        rows: record.rows,
                        label: text(arena, record.label),
                    }
                })
                .collect(),
            panes: records_of(panes, pane_count)
                .iter()
                .map(|record| {
                    let start = record.attachments.offset as usize;
                    let end = start.saturating_add(record.attachments.count as usize);
                    WorkspaceRosterPane {
                        pane_id: record.pane_id.bytes,
                        resolved_cols: record.resolved_cols,
                        resolved_rows: record.resolved_rows,
                        attachments: all_attachments
                            .get(start..end)
                            .unwrap_or(&[])
                            .iter()
                            .map(|attachment| {
                                WorkspaceRosterAttachment {
                                    client_instance_id: attachment.client_instance_id.bytes,
                                    contributes: attachment.contributes,
                                    cols: attachment.cols,
                                    rows: attachment.rows,
                                }
                            })
                            .collect(),
                    }
                })
                .collect(),
        };
        lend(out, cap, |writer| roster.encode_into(writer))
    }
}

/// Decodes a presence roster into three flat arrays and one arena.
///
/// Every count is written before any array is filled, so a caller that under-sized is told all
/// three sizes at once rather than one per retry.
///
/// # Safety
/// `payload` must describe live memory for the call; each array must be null or writable for its
/// declared capacity; each out-count must be null or writable for one `usize`; `arena` must be null
/// or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_decode_roster(
    payload: *const c_uchar,
    payload_len: usize,
    clients: *mut SlopDeskWorkspaceRosterClient,
    clients_cap: usize,
    out_client_count: *mut usize,
    panes: *mut SlopDeskWorkspaceRosterPane,
    panes_cap: usize,
    out_pane_count: *mut usize,
    attachments: *mut SlopDeskWorkspaceRosterAttachment,
    attachments_cap: usize,
    out_attachment_count: *mut usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let decoded = match WorkspacePresenceRoster::decode(borrow(payload, payload_len)) {
            Ok(decoded) => decoded,
            Err(error) => return verdict(&error),
        };
        let mut pool = TextArena::default();
        let built_clients: Vec<SlopDeskWorkspaceRosterClient> = decoded
            .clients
            .iter()
            .map(|client| {
                SlopDeskWorkspaceRosterClient {
                    client_instance_id: Uuid {
                        bytes: client.client_instance_id,
                    },
                    viewing_tab_id: Uuid {
                        bytes: client.viewing_tab_id,
                    },
                    viewing_pane_id: Uuid {
                        bytes: client.viewing_pane_id,
                    },
                    label: intern(&mut pool, client.label.as_bytes()),
                    cols: client.cols,
                    rows: client.rows,
                    client_kind: client.client_kind,
                    flags: client.flags,
                }
            })
            .collect();
        let mut built_attachments: Vec<SlopDeskWorkspaceRosterAttachment> = Vec::new();
        let built_panes: Vec<SlopDeskWorkspaceRosterPane> = decoded
            .panes
            .iter()
            .map(|pane| {
                let offset = u32::try_from(built_attachments.len()).unwrap_or(u32::MAX);
                built_attachments.extend(pane.attachments.iter().map(|attachment| {
                    SlopDeskWorkspaceRosterAttachment {
                        client_instance_id: Uuid {
                            bytes: attachment.client_instance_id,
                        },
                        cols: attachment.cols,
                        rows: attachment.rows,
                        contributes: attachment.contributes,
                    }
                }));
                SlopDeskWorkspaceRosterPane {
                    pane_id: Uuid { bytes: pane.pane_id },
                    attachments: SlopDeskWorkspaceRun {
                        offset,
                        count: u32::try_from(pane.attachments.len()).unwrap_or(u32::MAX),
                    },
                    resolved_cols: pane.resolved_cols,
                    resolved_rows: pane.resolved_rows,
                }
            })
            .collect();
        count_into(out_client_count, built_clients.len());
        count_into(out_pane_count, built_panes.len());
        count_into(out_attachment_count, built_attachments.len());
        if pool.0.len() > arena_cap
            || !place_all(&built_clients, clients, clients_cap)
            || !place_all(&built_panes, panes, panes_cap)
            || !place_all(&built_attachments, attachments, attachments_cap)
        {
            return WIRE_DECODE_AGAIN;
        }
        deliver(&pool.0, arena, arena_cap);
        WIRE_DECODE_OK
    }
}

/// The workspace channel's bounds, by index, so no caller respells one.
///
/// | index | constant |
/// | --- | --- |
/// | 0 | the label cap |
/// | 1 | the per-list record cap |
/// | 2 | the smallest a roster client record can be |
/// | 3 | the smallest a roster pane record can be |
/// | 4 | the exact size of a roster attachment record |
/// | 5 | `subscribe`'s CONTRIBUTES-SIZE flag bit |
/// | 6 | `subscribe`'s FOLLOWS-FOCUS flag bit |
///
/// The last two are a MASK rather than a length, and they are here for the reason the lengths are:
/// the byte is on the wire, the near side ANDs against it, and it was spelled `1 << 0` on both
/// sides two lines from a caller of this very door. A bit position a peer disagrees about is a
/// client that silently stops contributing to the PTY size fold — no error, no decode failure, just
/// a window that no longer counts.
///
/// An unknown index answers `-1`, which is neither a length nor a mask any of these could be.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_workspace_constant(index: u32) -> i64 {
    let value = match index {
        0 => WorkspaceSubscribe::MAX_LABEL_BYTES,
        1 => WorkspacePresenceRoster::MAX_RECORDS,
        2 => ROSTER_CLIENT_MIN_BYTES,
        3 => ROSTER_PANE_MIN_BYTES,
        4 => ROSTER_ATTACHMENT_BYTES,
        5 => usize::from(WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE),
        6 => usize::from(WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS),
        _ => return -1,
    };
    i64::try_from(value).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "the tests drive the same C entry points every caller does"
    )]
    #![expect(
        clippy::indexing_slicing,
        reason = "a test that slices its own fixture out of range has already failed"
    )]
    #![expect(
        clippy::unwrap_used,
        reason = "the fixtures are built inline and known-good, so `unwrap` IS the assertion"
    )]
    #![expect(
        clippy::borrow_as_ptr,
        reason = "a `&mut record` at a C entry point is exactly what Swift's `&record` compiles to"
    )]

    use super::*;

    /// A distinguishable id: every byte is `seed`, which no other fixture here uses twice.
    fn id(seed: u8) -> Uuid {
        Uuid { bytes: [seed; 16] }
    }

    /// Encodes through the door, sizing the way §4 says to.
    fn sized(mut call: impl FnMut(*mut c_uchar, usize) -> usize) -> Vec<u8> {
        let needed = call(core::ptr::null_mut(), 0);
        let mut out = vec![0u8; needed];
        let written = call(out.as_mut_ptr(), needed);
        assert_eq!(written, needed, "the door sized differently than it wrote");
        out
    }

    #[test]
    fn a_subscribe_round_trips_through_the_door() {
        let label = "Mac Studio";
        let record = SlopDeskWorkspaceSubscribe {
            client_instance_id: id(0x11),
            known_epoch: id(0x22),
            known_state_num: -9,
            label: SlopDeskWorkspaceText {
                offset: 0,
                length: u32::try_from(label.len()).unwrap(),
            },
            client_kind: 1,
            flags: WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS,
        };
        let bytes = sized(|out, cap| unsafe {
            slopdesk_workspace_encode_subscribe(&record, label.as_ptr(), label.len(), out, cap)
        });
        assert_eq!(bytes, WorkspaceSubscribe::decode(&bytes).unwrap().encode());

        let mut back = SlopDeskWorkspaceSubscribe::default();
        let mut arena = [0u8; 64];
        let verdict = unsafe {
            slopdesk_workspace_decode_subscribe(
                bytes.as_ptr(),
                bytes.len(),
                &mut back,
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(back.client_instance_id, id(0x11));
        assert_eq!(back.known_epoch, id(0x22));
        assert_eq!(back.known_state_num, -9);
        assert_eq!(back.client_kind, 1);
        assert_eq!(back.flags, WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS);
        assert_eq!(text(&arena, back.label), label);
    }

    #[test]
    fn a_subscribe_whose_arena_is_too_small_is_told_to_call_again() {
        let payload = WorkspaceSubscribe {
            label: "a name that does not fit".to_owned(),
            ..WorkspaceSubscribe::default()
        }
        .encode();
        let mut back = SlopDeskWorkspaceSubscribe::default();
        let mut arena = [0u8; 4];
        let verdict = unsafe {
            slopdesk_workspace_decode_subscribe(
                payload.as_ptr(),
                payload.len(),
                &mut back,
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(verdict, WIRE_DECODE_AGAIN);
    }

    #[test]
    fn a_presence_update_crosses_by_value() {
        let record = SlopDeskWorkspacePresence {
            presence_clock: 7,
            viewing_tab_id: id(0x33),
            viewing_pane_id: id(0x44),
            cols: 120,
            rows: 40,
            flags: WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE,
        };
        let bytes = sized(|out, cap| unsafe { slopdesk_workspace_encode_presence(&record, out, cap) });
        let mut back = SlopDeskWorkspacePresence::default();
        let verdict = unsafe { slopdesk_workspace_decode_presence(bytes.as_ptr(), bytes.len(), &mut back) };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(back.presence_clock, 7);
        assert_eq!(back.viewing_tab_id, id(0x33));
        assert_eq!(back.viewing_pane_id, id(0x44));
        assert_eq!(back.cols, 120);
        assert_eq!(back.rows, 40);
        assert_eq!(back.flags, WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE);
    }

    #[test]
    fn an_intent_leaves_its_arguments_in_the_payload() {
        let args = vec![9u8; 4096];
        let bytes = sized(|out, cap| unsafe {
            slopdesk_workspace_encode_intent(&id(0x55), 12, args.as_ptr(), args.len(), out, cap)
        });
        let mut back = SlopDeskWorkspaceIntent::default();
        let verdict = unsafe { slopdesk_workspace_decode_intent(bytes.as_ptr(), bytes.len(), &mut back) };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(back.intent_id, id(0x55));
        assert_eq!(back.op, 12);
        // 16 id bytes + one op byte + a u32 length: the args start at 21, in the PAYLOAD.
        assert_eq!(back.args.offset, 21);
        assert_eq!(back.args.length, 4096);
        let start = back.args.offset as usize;
        assert_eq!(&bytes[start..start + 4096], args.as_slice());
    }

    #[test]
    fn an_intent_result_crosses_by_value() {
        let record = SlopDeskWorkspaceIntentResult {
            intent_id: id(0x66),
            status: 4,
        };
        let bytes = sized(|out, cap| unsafe { slopdesk_workspace_encode_intent_result(&record, out, cap) });
        let mut back = SlopDeskWorkspaceIntentResult::default();
        let verdict =
            unsafe { slopdesk_workspace_decode_intent_result(bytes.as_ptr(), bytes.len(), &mut back) };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(back.intent_id, id(0x66));
        assert_eq!(back.status, 4);
    }

    /// Two clients, two panes, three attachments — enough that the flat attachment array has to be
    /// split back into runs correctly rather than by luck.
    fn roster_fixture() -> WorkspacePresenceRoster {
        WorkspacePresenceRoster {
            clients: vec![
                WorkspaceRosterClient {
                    client_instance_id: [0x77; 16],
                    client_kind: 0,
                    flags: 1,
                    viewing_tab_id: [0x78; 16],
                    viewing_pane_id: [0x79; 16],
                    cols: 100,
                    rows: 30,
                    label: "studio".to_owned(),
                },
                WorkspaceRosterClient {
                    client_instance_id: [0x7A; 16],
                    client_kind: 1,
                    flags: 0,
                    viewing_tab_id: [0x7B; 16],
                    viewing_pane_id: [0x7C; 16],
                    cols: 80,
                    rows: 24,
                    label: "phone".to_owned(),
                },
            ],
            panes: vec![
                WorkspaceRosterPane {
                    pane_id: [0x81; 16],
                    resolved_cols: 80,
                    resolved_rows: 24,
                    attachments: vec![
                        WorkspaceRosterAttachment {
                            client_instance_id: [0x77; 16],
                            contributes: true,
                            cols: 100,
                            rows: 30,
                        },
                        WorkspaceRosterAttachment {
                            client_instance_id: [0x7A; 16],
                            contributes: false,
                            cols: 80,
                            rows: 24,
                        },
                    ],
                },
                WorkspaceRosterPane {
                    pane_id: [0x82; 16],
                    resolved_cols: 60,
                    resolved_rows: 20,
                    attachments: vec![WorkspaceRosterAttachment {
                        client_instance_id: [0x7A; 16],
                        contributes: true,
                        cols: 60,
                        rows: 20,
                    }],
                },
            ],
        }
    }

    #[test]
    fn a_roster_crosses_as_three_arrays_and_one_arena() {
        let payload = roster_fixture().encode();

        let mut clients = [SlopDeskWorkspaceRosterClient::default(); 8];
        let mut panes = [SlopDeskWorkspaceRosterPane::default(); 8];
        let mut attachments = [SlopDeskWorkspaceRosterAttachment::default(); 8];
        let mut arena = [0u8; 256];
        let (mut client_count, mut pane_count, mut attachment_count) = (0usize, 0usize, 0usize);
        let verdict = unsafe {
            slopdesk_workspace_decode_roster(
                payload.as_ptr(),
                payload.len(),
                clients.as_mut_ptr(),
                clients.len(),
                &mut client_count,
                panes.as_mut_ptr(),
                panes.len(),
                &mut pane_count,
                attachments.as_mut_ptr(),
                attachments.len(),
                &mut attachment_count,
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!((client_count, pane_count, attachment_count), (2, 2, 3));
        assert_eq!(text(&arena, clients[0].label), "studio");
        assert_eq!(text(&arena, clients[1].label), "phone");
        assert_eq!(panes[0].attachments.offset, 0);
        assert_eq!(panes[0].attachments.count, 2);
        assert_eq!(panes[1].attachments.offset, 2);
        assert_eq!(panes[1].attachments.count, 1);
        assert!(attachments[0].contributes);
        assert!(!attachments[1].contributes);

        // And back out the same way, which is the shape the host encodes from.
        let round = sized(|out, cap| unsafe {
            slopdesk_workspace_encode_roster(
                clients.as_ptr(),
                client_count,
                panes.as_ptr(),
                pane_count,
                attachments.as_ptr(),
                attachment_count,
                arena.as_ptr(),
                arena.len(),
                out,
                cap,
            )
        });
        assert_eq!(round, payload);
    }

    #[test]
    fn a_roster_that_does_not_fit_is_told_all_three_sizes_at_once() {
        let roster = WorkspacePresenceRoster {
            clients: vec![WorkspaceRosterClient::default(); 3],
            panes: vec![WorkspaceRosterPane {
                attachments: vec![WorkspaceRosterAttachment::default(); 2],
                ..WorkspaceRosterPane::default()
            }],
        };
        let payload = roster.encode();
        let (mut client_count, mut pane_count, mut attachment_count) = (0usize, 0usize, 0usize);
        let verdict = unsafe {
            slopdesk_workspace_decode_roster(
                payload.as_ptr(),
                payload.len(),
                core::ptr::null_mut(),
                0,
                &mut client_count,
                core::ptr::null_mut(),
                0,
                &mut pane_count,
                core::ptr::null_mut(),
                0,
                &mut attachment_count,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(verdict, WIRE_DECODE_AGAIN);
        assert_eq!((client_count, pane_count, attachment_count), (3, 1, 2));
    }

    #[test]
    fn a_truncated_payload_is_refused_rather_than_guessed_at() {
        let mut back = SlopDeskWorkspacePresence::default();
        let short = [0u8; 3];
        let verdict = unsafe { slopdesk_workspace_decode_presence(short.as_ptr(), short.len(), &mut back) };
        assert_ne!(verdict, WIRE_DECODE_OK);
    }

    #[test]
    fn the_constants_are_the_crate_s_own() {
        assert_eq!(
            slopdesk_workspace_constant(0),
            i64::try_from(WorkspaceSubscribe::MAX_LABEL_BYTES).unwrap()
        );
        assert_eq!(
            slopdesk_workspace_constant(1),
            i64::try_from(WorkspacePresenceRoster::MAX_RECORDS).unwrap()
        );
        assert_eq!(
            slopdesk_workspace_constant(2),
            i64::try_from(ROSTER_CLIENT_MIN_BYTES).unwrap()
        );
        assert_eq!(
            slopdesk_workspace_constant(3),
            i64::try_from(ROSTER_PANE_MIN_BYTES).unwrap()
        );
        assert_eq!(
            slopdesk_workspace_constant(4),
            i64::try_from(ROSTER_ATTACHMENT_BYTES).unwrap()
        );
        assert_eq!(slopdesk_workspace_constant(99), -1);
    }
}
