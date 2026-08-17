//! The intent applier: one client's requested topology change, decided in Rust.
//!
//! ## Why this is a door rather than a shape
//! `slopdesk_wire::document::apply` is the DECISION — what a split does, which tab takes focus
//! after a close, whether a proposed id is already in use. It is the one function both ends run:
//! the host to decide what the document becomes, the client to build its optimistic overlay. Two
//! implementations of it would drift, and the drift would look exactly like a sync bug, which is
//! precisely why it may not exist twice.
//!
//! ## Everything crosses as the document's OWN encoding
//! The applier takes a topology and answers a topology, and a `WorkspaceTopology` is a split tree —
//! not a shape that flattens into a `#[repr(C)]` struct without inventing a second grammar for it.
//! It does not have to: the topology already HAS a byte encoding, the one every client decodes off
//! the socket. So the caller hands over the document's cells in `slopdesk_ws_encode_snapshot`'s
//! flat `(CEntry, blob)` form, and the answer comes back as an encoded snapshot of the RESULT's
//! cells, which the caller decodes with the same `slopdesk_ws_decode_snapshot` it already uses for
//! a host's push. Nothing here is a grammar anyone has to keep in step — it is the document's.
//!
//! `rust/slopdesk-ffi/tests/snapshot_codec_parity.rs` is what makes that safe to say: the encoder
//! the caller reaches through `slopdesk_ws_encode_snapshot` (`slopdesk_workspace::state_codec`) and
//! the one this module decodes with (`slopdesk_wire::document::codec`) are two crates that do not
//! depend on each other, and that test is where they are held to the same bytes.
//!
//! ## The two callbacks flatten, for the reason every callback here flattens
//! `apply` takes a project-key lookup and an identity source. Neither trampolines back into Swift:
//! the project keys arrive as `(pane, span)` pairs into the SAME blob the entries span, and the
//! identities as a small pool of pre-minted UUIDs. One pointer set, one lifetime, one scope.

use core::ffi::c_uchar;

use slopdesk_wire::WorkspaceIntentStatus;
use slopdesk_wire::document::apply::{self, IntentOutcome};
use slopdesk_wire::document::state::{HostWorkspaceState, WorkspaceEntry, WorkspaceKey};
use slopdesk_wire::document::{codec as wire_codec, intent, liveness, topology};
use slopdesk_workspace::identity::{IdSource, SessionId};
use slopdesk_workspace::{PaneId, SplitNodeId, TabId};

use crate::deliver;
use crate::workspace::{CEntry, KeyedPane, Uuid, borrow_array, text_of};

/// How many pre-minted identities one intent can consume.
///
/// Two: a reattach takes a tab for the case where the pane's origin tab is gone, and a split for
/// the case where it is still there. No other op takes more than one. The constant is exported
/// rather than transcribed so a caller sizes its pool from the crate that spends it — a pool one
/// short would not fail, it would REPEAT an identity, and two tabs sharing an id is the kind of
/// wrong that surfaces days later as a tab that will not close.
pub const MINTED_IDS_PER_INTENT: usize = 2;

/// The caller's pool of pre-minted identities, handed out in order.
///
/// One cursor across all four kinds rather than four: an op that takes a tab and a split takes them
/// in that order and wants two DIFFERENT ids, which one cursor gives and four would not. A pool
/// that runs dry repeats its last entry rather than panicking — the caller's obligation is
/// [`MINTED_IDS_PER_INTENT`], and repeating is what an FFI boundary owes a caller who got their own
/// arithmetic wrong: a refusal it can see, not a process it cannot.
struct Pool<'a> {
    ids: &'a [Uuid],
    next: usize,
}

impl Pool<'_> {
    fn take(&mut self) -> [u8; 16] {
        let picked = self.ids.get(self.next).or_else(|| self.ids.last());
        self.next += 1;
        picked.map_or([0; 16], |id| id.bytes)
    }
}

impl IdSource for Pool<'_> {
    fn pane(&mut self) -> PaneId {
        PaneId::from_bytes(self.take())
    }

    fn tab(&mut self) -> TabId {
        TabId::from_bytes(self.take())
    }

    fn session(&mut self) -> SessionId {
        SessionId::from_bytes(self.take())
    }

    fn split(&mut self) -> SplitNodeId {
        SplitNodeId::from_bytes(self.take())
    }
}

/// The status byte an outcome reports — [`WorkspaceIntentStatus`]'s numbering, which is the wire's.
///
/// The same byte the host puts in an `intentResult` frame, so a caller that already switches on
/// that enum needs no second vocabulary for the local answer.
const fn status_of(outcome: &IntentOutcome) -> WorkspaceIntentStatus {
    match outcome {
        IntentOutcome::Applied(_) => WorkspaceIntentStatus::Applied,
        IntentOutcome::RejectedStale => WorkspaceIntentStatus::RejectedStale,
        IntentOutcome::RejectedInvalid => WorkspaceIntentStatus::RejectedInvalid,
        IntentOutcome::RejectedNotFound => WorkspaceIntentStatus::RejectedNotFound,
        IntentOutcome::UnknownOp => WorkspaceIntentStatus::UnknownOp,
    }
}

/// Builds the document the applier decides from, out of the caller's flat cells.
///
/// A span the blob cannot back reads as an EMPTY value rather than trapping — the same bounds
/// discipline `slopdesk_ws_encode_snapshot` applies, for the same reason: the arithmetic came from
/// another process.
fn document(entries: &[CEntry], blob: &[u8]) -> HostWorkspaceState {
    HostWorkspaceState::from_entries(
        entries
            .iter()
            .map(|entry| {
                let value = entry
                    .value
                    .offset
                    .checked_add(entry.value.len)
                    .and_then(|end| blob.get(entry.value.offset..end))
                    .unwrap_or_default();
                WorkspaceEntry::new(
                    WorkspaceKey {
                        kind: entry.kind,
                        object_id: entry.object.bytes,
                        field: entry.field,
                    },
                    value.to_vec(),
                )
            })
            .collect(),
    )
}

/// Applies one intent, answering the resulting topology's cells as an encoded snapshot.
///
/// `entries`/`blob` are the document the intent applies to, in `slopdesk_ws_encode_snapshot`'s flat
/// form. `project_keys` are the by-project keys the close ops read, spanning the SAME `blob`; a
/// pane absent from that array has no key, which puts it in the unsectioned group. `minted` is the
/// identity pool, [`MINTED_IDS_PER_INTENT`] entries. `pristine` is whether the document is still
/// the untouched default — only the bootstrap op reads it.
///
/// `status` receives the [`WorkspaceIntentStatus`] byte, written on EVERY path including the
/// refusals, so a caller that only wants the verdict passes a null `out` and reads it there.
///
/// The return is the encoded snapshot's byte count under §4's convention — write nothing when it
/// does not fit, answer what was needed. A refusal answers 0 bytes, which is not the same as the
/// four bytes an empty snapshot encodes to: there is no document to decode, so there are none to
/// hand back.
///
/// # Safety
/// `args` must be null or point to `args_len` live bytes; `entries` null or to `entry_count` live
/// [`CEntry`]s; `project_keys` null or to `project_key_count` live [`KeyedPane`]s; `blob` null or
/// to `blob_len` live bytes; `minted` null or to `minted_count` live [`Uuid`]s; `status` null or
/// writable for one byte; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_apply_intent(
    op: c_uchar,
    args: *const c_uchar,
    args_len: usize,
    entries: *const CEntry,
    entry_count: usize,
    project_keys: *const KeyedPane,
    project_key_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    minted: *const Uuid,
    minted_count: usize,
    pristine: bool,
    status: *mut c_uchar,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (payload, cells, keys, bytes, pool) = unsafe {
        (
            crate::borrow(args, args_len),
            borrow_array(entries, entry_count),
            borrow_array(project_keys, project_key_count),
            crate::borrow(blob, blob_len),
            borrow_array(minted, minted_count),
        )
    };

    let state = document(cells, bytes);
    let Some(topology) = state.topology() else {
        // No workspace to change, told apart from a refusal on the merits so a caller can
        // distinguish "you asked about a document that is not there" from "the document says no".
        // SAFETY: null or, by the caller's obligation, writable for one byte.
        unsafe { write_status(status, WorkspaceIntentStatus::RejectedNotFound) };
        return 0;
    };

    let lookup = |pane: PaneId| -> Option<String> {
        keys.iter()
            .find(|keyed| keyed.id.bytes == pane.bytes())
            .and_then(|keyed| text_of(keyed.key, bytes))
            .map(str::to_owned)
    };
    let mut ids = Pool { ids: pool, next: 0 };
    let outcome = apply::apply(op, payload, &topology, &mut ids, pristine, &lookup);

    // SAFETY: null or, by the caller's obligation, writable for one byte.
    unsafe { write_status(status, status_of(&outcome)) };
    let Some(next) = outcome.topology() else {
        return 0;
    };
    let answer = wire_codec::encode_snapshot(&HostWorkspaceState::from_entries(next.entries()));
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(&answer, out, cap) }
}

/// # Safety
/// `status` must be null or writable for one byte.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing one byte through a C out-parameter"
)]
unsafe fn write_status(status: *mut c_uchar, verdict: WorkspaceIntentStatus) {
    if !status.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one byte.
        unsafe { *status = verdict.as_byte() };
    }
}

/// The status byte for one outcome, by [`IntentOutcome`]'s own arm order: applied, stale, invalid,
/// not-found, unknown-op. An index past the last answers the unknown-op byte.
///
/// Exported rather than transcribed. The numbering itself is [`WorkspaceIntentStatus`]'s, which is
/// the WIRE's and therefore golden-pinned — a caller that wrote `case applied = 0` beside it would
/// be a second copy of a frozen number, and the one place that number is allowed to live is the
/// crate the frames are built in.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_intent_status(index: c_uchar) -> c_uchar {
    let verdict = match index {
        0 => WorkspaceIntentStatus::Applied,
        1 => WorkspaceIntentStatus::RejectedStale,
        2 => WorkspaceIntentStatus::RejectedInvalid,
        3 => WorkspaceIntentStatus::RejectedNotFound,
        _ => WorkspaceIntentStatus::UnknownOp,
    };
    verdict.as_byte()
}

/// The pool size a caller must supply, exported rather than transcribed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_minted_ids_per_intent() -> usize {
    MINTED_IDS_PER_INTENT
}

/// One of the topology's two RING caps, by index: 0 the closed-tab ring, 1 the per-session focus
/// MRU. An unknown index answers 0, which no caller can mistake for a ring.
///
/// Exported rather than transcribed for the reason every cap here is. These are REAPING
/// thresholds, and the host is the one that reaps: a client holding the larger number renders a
/// ring whose tail the host already deleted, and a client holding the smaller one hides tabs
/// ⇧⌘T would still reopen. Neither shows an error — the ring is just quietly the wrong length,
/// which is exactly the class of drift the whole document exists to end.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_topology_ring_cap(index: c_uchar) -> usize {
    match index {
        0 => topology::CLOSED_TAB_RING_CAP,
        1 => topology::FOCUS_MRU_CAP,
        _ => 0,
    }
}

/// One of the intent grammar's argument caps, by index.
///
/// `0` a name's byte cap, `1` a `reorderTabs` list's length cap, `2` the cap on a blob carrying a
/// whole sub-payload. An unknown index answers 0, which refuses everything rather than admitting
/// anything.
///
/// These are the bounds the HOST validates against before it allocates, so a client that encodes to
/// a transcribed larger copy builds intents the host silently drops, and one holding a smaller copy
/// truncates a rename the host would have taken whole. Either way the client believes it sent
/// something the document never received.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_intent_limit(index: c_uchar) -> usize {
    match index {
        0 => intent::MAX_NAME_BYTES,
        1 => intent::MAX_TAB_COUNT,
        2 => intent::MAX_BLOB_BYTES,
        _ => 0,
    }
}

/// Whether a `(kind, field)` pair belongs to the TOPOLOGY half — the half an intent writes and a
/// host restart restores.
///
/// This is the predicate a wholesale topology write REAPS by, so the two ends disagreeing does not
/// produce a conflict: the side holding the wider answer deletes a cell the other persisted, and
/// the side holding the narrower one leaves behind a cell nothing will ever clear. A pane splits by
/// FIELD — its `title` is topology and its `liveTitle` is not, one byte apart under the same object
/// id — which is exactly the kind of line no second transcription of it stays on.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_key_is_topology(kind: c_uchar, field: c_uchar) -> bool {
    topology::is_topology(&WorkspaceKey {
        kind,
        object_id: [0; 16],
        field,
    })
}

/// One HALF of the pane field vocabulary, §4-shaped: `0` the liveness fields, `1` the topology
/// fields. An unknown half answers 0, which is not a half.
///
/// The two lists PARTITION the vocabulary and must keep doing so — a field in neither is written by
/// nobody and reaped by nobody, and a field in both makes a liveness recapture silently delete a
/// persisted title. That property is only worth asserting about the lists the reaping actually
/// uses, so both ends read these rather than each holding a copy that partitions on its own.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_pane_fields(
    half: c_uchar,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let fields: &[u8] = match half {
        0 => &liveness::LIVENESS_FIELDS,
        1 => &liveness::TOPOLOGY_FIELDS,
        _ => &[],
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(fields, out, cap) }
}

/// The `root` field numbers a topology write must NOT reap, §4-shaped.
///
/// Reserved for config that does not cross (`docs/45` §5.3). A write that reaped them would delete
/// whatever a future build had put there, and a client that transcribed the wrong three would reap
/// exactly the fields it was meant to leave alone — a data loss with no error and no symptom until
/// the build that reads them ships.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_reserved_root_fields(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&topology::RESERVED_ROOT_FIELDS, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "calling the C entry point through its own signature IS what these pin"
    )]
    #![expect(
        clippy::expect_used,
        reason = "a door that refuses its own fixture IS the report"
    )]

    use slopdesk_wire::WorkspaceIntentStatus;
    use slopdesk_wire::document::codec as wire_codec;
    use slopdesk_wire::document::fields::pane as pane_field;
    use slopdesk_wire::document::intent::{WorkspaceIntentOp, encode_identity, encode_name};
    use slopdesk_wire::document::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};
    use slopdesk_wire::document::topology::WorkspaceTopology;
    use slopdesk_workspace::identity::{PaneId, SessionId, TabId};
    use slopdesk_workspace::session::{PaneKind, PaneSpec};
    use slopdesk_workspace::workspace::TreeWorkspace;

    use super::{IntentOutcome, MINTED_IDS_PER_INTENT, slopdesk_ws_apply_intent};
    use crate::workspace::{CEntry, KeyedPane, Span, Uuid};

    /// The document's cells in the flat `(CEntry, blob)` form the door takes, plus the project keys
    /// spanning the SAME blob — which is the encoding under test as much as anything else.
    struct Flat {
        cells: Vec<CEntry>,
        keys: Vec<KeyedPane>,
        blob: Vec<u8>,
    }

    impl Flat {
        fn of(state: &HostWorkspaceState, project_keys: &[(PaneId, &str)]) -> Self {
            let mut blob = Vec::new();
            let cells = state
                .sorted_entries()
                .into_iter()
                .map(|entry| {
                    let offset = blob.len();
                    blob.extend_from_slice(&entry.value);
                    CEntry {
                        kind: entry.key.kind,
                        field: entry.key.field,
                        object: Uuid {
                            bytes: entry.key.object_id,
                        },
                        value: Span {
                            offset,
                            len: blob.len() - offset,
                            present: true,
                        },
                    }
                })
                .collect();
            let keys = project_keys
                .iter()
                .map(|(pane, key)| {
                    let offset = blob.len();
                    blob.extend_from_slice(key.as_bytes());
                    KeyedPane {
                        id: Uuid { bytes: pane.bytes() },
                        key: Span {
                            offset,
                            len: blob.len() - offset,
                            present: true,
                        },
                    }
                })
                .collect();
            Self { cells, keys, blob }
        }
    }

    /// One call through the C signature, sized the way §4 says to: probe, grow, call again.
    fn call(flat: &Flat, op: WorkspaceIntentOp, args: &[u8], pristine: bool) -> (u8, Vec<u8>) {
        let minted: Vec<Uuid> = (0..MINTED_IDS_PER_INTENT)
            .map(|index| {
                Uuid {
                    bytes: [0xA0 + u8::try_from(index).unwrap_or(0); 16],
                }
            })
            .collect();
        let mut status = 0xFF_u8;
        let mut out = vec![0_u8; 8];
        let mut needed = unsafe {
            slopdesk_ws_apply_intent(
                op.as_byte(),
                args.as_ptr(),
                args.len(),
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.keys.as_ptr(),
                flat.keys.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
                minted.as_ptr(),
                minted.len(),
                pristine,
                &raw mut status,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        if needed > out.len() {
            assert!(
                out.iter().all(|byte| *byte == 0),
                "a probe that did not fit still wrote"
            );
            out = vec![0_u8; needed];
            needed = unsafe {
                slopdesk_ws_apply_intent(
                    op.as_byte(),
                    args.as_ptr(),
                    args.len(),
                    flat.cells.as_ptr(),
                    flat.cells.len(),
                    flat.keys.as_ptr(),
                    flat.keys.len(),
                    flat.blob.as_ptr(),
                    flat.blob.len(),
                    minted.as_ptr(),
                    minted.len(),
                    pristine,
                    &raw mut status,
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
        }
        out.truncate(needed);
        (status, out)
    }

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn one_pane() -> WorkspaceTopology {
        WorkspaceTopology::new(TreeWorkspace::single_pane(
            SessionId::from_bytes([1; 16]),
            TabId::from_bytes([1; 16]),
            pane(1),
            PaneSpec::new(PaneKind::Terminal, "Terminal"),
        ))
    }

    fn document() -> HostWorkspaceState {
        HostWorkspaceState::from_entries(one_pane().entries())
    }

    fn topology_of(bytes: &[u8]) -> WorkspaceTopology {
        let state = wire_codec::decode_snapshot(bytes).expect("the door answered a snapshot");
        state.topology().expect("with a topology in it")
    }

    #[test]
    fn an_applied_intent_answers_the_next_topologys_cells() {
        let flat = Flat::of(&document(), &[]);
        let (status, bytes) = call(
            &flat,
            WorkspaceIntentOp::RenamePane,
            &encode_name(&pane(1).bytes(), "renamed"),
            false,
        );
        assert_eq!(status, WorkspaceIntentStatus::Applied.as_byte());
        let next = topology_of(&bytes);
        let session = next.tree.sessions.first().expect("one session");
        assert_eq!(
            session.specs.get(&pane(1)).map(|spec| spec.title.as_str()),
            Some("renamed"),
        );
    }

    #[test]
    fn a_refusal_answers_its_own_byte_and_no_cells() {
        let flat = Flat::of(&document(), &[]);
        for (op, args, expected) in [
            (
                WorkspaceIntentOp::RenamePane,
                encode_name(&pane(9).bytes(), "nobody"),
                WorkspaceIntentStatus::RejectedNotFound,
            ),
            (
                WorkspaceIntentOp::RenamePane,
                Vec::new(),
                WorkspaceIntentStatus::RejectedInvalid,
            ),
        ] {
            let (status, bytes) = call(&flat, op, &args, false);
            assert_eq!(status, expected.as_byte());
            assert!(bytes.is_empty(), "a refusal handed back cells");
        }
    }

    #[test]
    fn an_op_byte_this_build_does_not_know_is_its_own_verdict() {
        let flat = Flat::of(&document(), &[]);
        let mut status = 0xFF_u8;
        let needed = unsafe {
            slopdesk_ws_apply_intent(
                250,
                core::ptr::null(),
                0,
                flat.cells.as_ptr(),
                flat.cells.len(),
                core::ptr::null(),
                0,
                flat.blob.as_ptr(),
                flat.blob.len(),
                core::ptr::null(),
                0,
                false,
                &raw mut status,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(status, WorkspaceIntentStatus::UnknownOp.as_byte());
        assert_eq!(needed, 0);
    }

    #[test]
    fn a_document_with_no_workspace_in_it_is_not_found_rather_than_refused() {
        let flat = Flat::of(&HostWorkspaceState::from_entries(Vec::new()), &[]);
        let (status, bytes) = call(
            &flat,
            WorkspaceIntentOp::FocusPane,
            &encode_identity(&pane(1).bytes()),
            false,
        );
        assert_eq!(status, WorkspaceIntentStatus::RejectedNotFound.as_byte());
        assert!(bytes.is_empty());
    }

    #[test]
    fn the_pristine_flag_is_what_decides_a_bootstrap() {
        let mut fresh = one_pane();
        fresh.host_display_name = "studio".to_owned();
        let args = wire_codec::encode_snapshot(&HostWorkspaceState::from_entries(fresh.entries()));
        let flat = Flat::of(&document(), &[]);
        assert_eq!(
            call(&flat, WorkspaceIntentOp::AdoptWorkspace, &args, false).0,
            WorkspaceIntentStatus::RejectedStale.as_byte(),
            "a bootstrap onto a touched document",
        );
        assert_eq!(
            call(&flat, WorkspaceIntentOp::AdoptWorkspace, &args, true).0,
            WorkspaceIntentStatus::Applied.as_byte(),
            "the same bootstrap onto an untouched one",
        );
    }

    #[test]
    fn the_project_keys_cross_as_spans_into_the_same_blob() {
        // The close rule keeps focus inside the closed tab's section, so the key a pane carries is
        // observable through it. What is pinned here is that the SPANS arrive at all: the keys sit
        // in the blob AFTER every entry value, which is the arithmetic a second blob would have
        // hidden.
        let state = document();
        let flat = Flat::of(&state, &[(pane(1), "/work/slopdesk")]);
        assert!(
            flat.blob.ends_with(b"/work/slopdesk"),
            "the key was not appended to the entries' own blob"
        );
        let (status, bytes) = call(
            &flat,
            WorkspaceIntentOp::RenamePane,
            &encode_name(&pane(1).bytes(), "keyed"),
            false,
        );
        assert_eq!(status, WorkspaceIntentStatus::Applied.as_byte());
        assert!(!bytes.is_empty());
    }

    #[test]
    fn a_span_the_blob_cannot_back_reads_as_an_empty_value() {
        // Not a hypothetical: the offsets are arithmetic done in another process. A cell whose span
        // runs off the end must read as empty rather than trap, which for a pane TITLE means the
        // pane is still there under an empty name — a document that renders, not one that crashes.
        let mut flat = Flat::of(&document(), &[]);
        for cell in &mut flat.cells {
            if cell.kind == WorkspaceObjectKind::Pane.as_byte() && cell.field == pane_field::TITLE {
                cell.value.offset = usize::MAX - 1;
            }
        }
        let (status, bytes) = call(
            &flat,
            WorkspaceIntentOp::RenamePane,
            &encode_name(&pane(1).bytes(), "recovered"),
            false,
        );
        assert_eq!(status, WorkspaceIntentStatus::Applied.as_byte());
        let next = topology_of(&bytes);
        assert_eq!(
            next.tree
                .sessions
                .first()
                .and_then(|session| session.specs.get(&pane(1)))
                .map(|spec| spec.title.as_str()),
            Some("recovered"),
        );
    }

    #[test]
    fn the_status_is_written_even_when_the_caller_wants_no_cells() {
        let flat = Flat::of(&document(), &[]);
        let args = encode_name(&pane(1).bytes(), "sized");
        let mut status = 0xFF_u8;
        let needed = unsafe {
            slopdesk_ws_apply_intent(
                WorkspaceIntentOp::RenamePane.as_byte(),
                args.as_ptr(),
                args.len(),
                flat.cells.as_ptr(),
                flat.cells.len(),
                core::ptr::null(),
                0,
                flat.blob.as_ptr(),
                flat.blob.len(),
                core::ptr::null(),
                0,
                false,
                &raw mut status,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(status, WorkspaceIntentStatus::Applied.as_byte());
        assert!(needed > 0, "a null out must still answer what it needed");
    }

    #[test]
    fn the_exported_status_order_is_the_one_the_door_answers() {
        // The index order is the only thing a caller transcribes, so it is the only thing that can
        // drift. Each index is checked against the byte an outcome of that arm ACTUALLY produces,
        // not against a second list of bytes.
        for (index, outcome) in [
            IntentOutcome::Applied(Box::new(one_pane())),
            IntentOutcome::RejectedStale,
            IntentOutcome::RejectedInvalid,
            IntentOutcome::RejectedNotFound,
            IntentOutcome::UnknownOp,
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(
                super::slopdesk_ws_intent_status(u8::try_from(index).unwrap_or(u8::MAX)),
                super::status_of(&outcome).as_byte(),
            );
        }
        assert_eq!(
            super::slopdesk_ws_intent_status(200),
            WorkspaceIntentStatus::UnknownOp.as_byte(),
            "an index past the last is the verdict for a byte nobody knows",
        );
    }

    #[test]
    fn the_pool_hands_out_two_distinct_identities() {
        // A reattach takes a tab AND a split. One cursor across both kinds is what keeps them
        // apart; four separate cursors would hand the same first entry to each, and two objects
        // born with one id is the failure this pins against.
        let mut pool = super::Pool {
            ids: &[Uuid { bytes: [1; 16] }, Uuid { bytes: [2; 16] }],
            next: 0,
        };
        let tab = slopdesk_workspace::identity::IdSource::tab(&mut pool);
        let split = slopdesk_workspace::identity::IdSource::split(&mut pool);
        assert_ne!(tab.bytes(), split.bytes());
        // Dry repeats rather than panics — a caller who under-sized their pool gets a refusal they
        // can see, not a process that is gone.
        let third = slopdesk_workspace::identity::IdSource::split(&mut pool);
        assert_eq!(third.bytes(), split.bytes());
    }

    #[test]
    fn a_key_that_names_no_pane_is_simply_not_asked_for() {
        let flat = Flat::of(&document(), &[(pane(200), "/elsewhere")]);
        let (status, _) = call(
            &flat,
            WorkspaceIntentOp::FocusPane,
            &encode_identity(&pane(1).bytes()),
            false,
        );
        assert_eq!(status, WorkspaceIntentStatus::Applied.as_byte());
    }

    #[test]
    fn the_answer_is_the_documents_own_encoding_and_nothing_else() {
        // The door's whole premise: what comes back is a snapshot, decodable by the same codec the
        // caller already runs on a host's push. If this ever needed its own reader, the encoding
        // would have become a second grammar to keep in step.
        let flat = Flat::of(&document(), &[]);
        let (_, bytes) = call(
            &flat,
            WorkspaceIntentOp::RenameTab,
            &encode_name(&[1; 16], "titled"),
            false,
        );
        let state = wire_codec::decode_snapshot(&bytes).expect("a snapshot");
        assert_eq!(
            state.get(&WorkspaceKey {
                kind: WorkspaceObjectKind::Tab.as_byte(),
                object_id: [1; 16],
                field: slopdesk_wire::document::fields::tab::TITLE,
            }),
            Some(b"titled".as_slice()),
        );
    }
}
