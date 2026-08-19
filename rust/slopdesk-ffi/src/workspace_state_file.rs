//! The workspace state FILE: which half of the document survives a restart, and its on-disk shape.
//!
//! ## Why this is a door rather than a shape
//! `slopdesk_wire::document::state_file` is the POLICY. Not the JSON — the JSON is the boring half
//! — but the FILTER: which cells may touch the disk at all. Serializing the entry map wholesale
//! would restore `command_running = 1`, `agent_state = working` and a liveness of `attached` for a
//! pane whose child exited weeks ago, so every client would paint a wall of busy dots for processes
//! that are gone. That rule was written twice, once here and once in Swift, until this module
//! existed — and a filter that disagrees with itself does not fail, it renders.
//!
//! ## Everything crosses as the document's OWN encoding
//! The same arrangement [`crate::workspace_intent`] uses, for the same reason. The state is a flat
//! cell map, so it goes IN as the `(CEntry, blob)` pairs `slopdesk_ws_encode_snapshot` already
//! takes, and a decoded file comes back OUT as an encoded snapshot the caller reads with
//! `slopdesk_ws_decode_snapshot`. No grammar is invented in either direction, and
//! `rust/slopdesk-ffi/tests/snapshot_codec_parity.rs` is what lets that be said out loud: the
//! encoder the caller reaches (`slopdesk_workspace::state_codec`) and the one this module answers
//! with (`slopdesk_wire::document::codec`) are two crates that do not depend on each other.
//!
//! ## The taxonomy crosses as bytes the ARMS own
//! A load can refuse three ways and the caller's answer differs for each: "these bytes are not our
//! file" and "this is our file from another shape of the store" both mint the default and keep the
//! old file aside, while "one bad row" says a file this build CAN read has something in it nobody
//! should silently drop. So the refusal crosses as `FileError::code()` — a number the enum's own
//! arms carry — and never as a mapping written here, which is the one thing `docs/55` §5 says a
//! door may not hold.
//!
//! ## Why the filter is a PREDICATE and not a whole-state crossing
//! `slopdesk_ws_state_file_is_persisted` answers one `(kind, field)` pair, exactly as its neighbour
//! `slopdesk_ws_key_is_topology` does, because the rule reads nothing else — not the object id, not
//! the value, not the rest of the document. Handing the whole state over to have it handed back
//! minus some rows would marshal every byte of a document twice to ask a question about two bytes.
//! The near side's loop is not a decision; every branch inside it is on this side of the door.

use core::ffi::c_uchar;

use slopdesk_wire::document::codec as wire_codec;
use slopdesk_wire::document::state::WorkspaceKey;
use slopdesk_wire::document::state_file::{self, FileError, NO_REFUSAL};

use crate::deliver;
use crate::workspace::{CEntry, borrow_array};
use crate::workspace_intent::document;

/// Whether one document cell survives a restart.
///
/// The rule reads a KIND and a FIELD and nothing else: three kinds are wholly persisted, a pane
/// splits by field — its `title` survives and its `liveness` must not, one byte apart under the
/// same object id — a project keeps its path and drops its git summary, and a kind this build does
/// not know is dropped rather than carried, because bytes nothing can read and nothing can reap
/// would leave ghost objects in the document forever.
///
/// Two answers to this do not conflict, they RENDER: the wider one brings a pane back as attached
/// with no process behind it, and the narrower one loses the arrangement the person made. That is
/// why it is asked rather than transcribed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_state_file_is_persisted(kind: c_uchar, field: c_uchar) -> bool {
    state_file::is_persisted(&WorkspaceKey {
        kind,
        object_id: [0; 16],
        field,
    })
}

/// The file's bytes for a document, under §4's convention.
///
/// `entries`/`blob` are the cells in `slopdesk_ws_encode_snapshot`'s flat form — the whole
/// document, unfiltered: what belongs on disk is the caller's own pass through
/// [`slopdesk_ws_state_file_is_persisted`], exactly as the wrapped module's `encode` takes whatever
/// `persisting` handed it. Encoding cannot fail, so there is no status here and no refusal to read.
///
/// The answer is UTF-8 JSON with sorted keys and canonical entry order, so two saves of one value
/// are byte-identical and the file diffs cleanly.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s; `blob` null or to `blob_len` live
/// bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_state_file_encode(
    entries: *const CEntry,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes) = unsafe { (borrow_array(entries, count), crate::borrow(blob, blob_len)) };
    let text = state_file::encode(&document(cells, bytes));
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// Reads a file back, answering the surviving cells as an encoded snapshot.
///
/// `bytes` is the file exactly as it came off disk. `status` receives the refusal byte on EVERY
/// path — [`NO_REFUSAL`] when the load worked — so a caller that only wants the verdict may pass a
/// null `out` and read it there. `version` receives the version the file CLAIMED, and only on the
/// version-mismatch path; it is left untouched otherwise, because every `i64` is a version somebody
/// could have typed in and none of them could have meant "this refusal is not about a version".
///
/// The return is the encoded snapshot's byte count under §4's convention. A refusal answers 0
/// bytes, which is not the four an EMPTY document encodes to: a file that decoded to no surviving
/// cells is a real answer and the caller's next question about it — is there a workspace in here —
/// is a different one from "was this a file at all".
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `status` null or writable for one byte;
/// `version` null or writable for one `int64_t`; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_state_file_decode(
    bytes: *const c_uchar,
    len: usize,
    status: *mut c_uchar,
    version: *mut i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let input = unsafe { crate::borrow(bytes, len) };
    match state_file::decode_bytes(input) {
        Ok(state) => {
            // SAFETY: null or, by the caller's obligation, writable for one byte.
            unsafe { write_status(status, NO_REFUSAL) };
            let answer = wire_codec::encode_snapshot(&state);
            // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
            unsafe { deliver(&answer, out, cap) }
        },
        Err(refusal) => {
            // SAFETY: each pointer is null or, by the caller's obligation, writable for its width.
            unsafe {
                write_status(status, refusal.code());
                write_version(version, refusal.claimed_version());
            }
            0
        },
    }
}

/// The refusal byte for one outcome, by index.
///
/// `0` is the load that worked, then [`FileError`]'s own arm order — malformed, version mismatch,
/// malformed row. An index past the last answers the malformed byte, which refuses rather than
/// admits.
///
/// Exported rather than transcribed for the reason the taxonomy exists at all: a caller that wrote
/// `case malformed = 1` beside this would be a second copy of the numbering, and the arm it drifted
/// on would turn a corrupt row into a mint-the-default — the file kept aside under the wrong name,
/// or not kept aside at all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_state_file_status(index: c_uchar) -> c_uchar {
    match index {
        0 => NO_REFUSAL,
        2 => FileError::VersionMismatch(0).code(),
        3 => FileError::MalformedRow.code(),
        _ => FileError::Malformed.code(),
    }
}

/// # Safety
/// `status` must be null or writable for one byte.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing one byte through a C out-parameter"
)]
unsafe fn write_status(status: *mut c_uchar, code: u8) {
    if !status.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one byte.
        unsafe { *status = code };
    }
}

/// Writes the claimed version, and only where there is one.
///
/// An absent version leaves the caller's `int64_t` ALONE rather than zeroing it, because zero is a
/// version a hand-edited file can claim: a door that wrote it would have invented a report the
/// wrapped module never made.
///
/// # Safety
/// `version` must be null or writable for one `i64`.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing one word through a C out-parameter"
)]
unsafe fn write_version(version: *mut i64, claimed: Option<i64>) {
    let (false, Some(claimed)) = (version.is_null(), claimed) else {
        return;
    };
    // SAFETY: non-null and, by the caller's obligation, writable for one `i64`.
    unsafe { *version = claimed };
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

    use slopdesk_wire::document::fields::{pane, project};
    use slopdesk_wire::document::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};
    use slopdesk_wire::document::state_file::{self, FileError, NO_REFUSAL};
    use slopdesk_workspace::state_codec as ws_codec;

    use super::{
        slopdesk_ws_state_file_decode, slopdesk_ws_state_file_encode, slopdesk_ws_state_file_is_persisted,
        slopdesk_ws_state_file_status,
    };
    use crate::workspace::{CEntry, Span, Uuid};

    /// The document's cells in the flat `(CEntry, blob)` form the encode door takes.
    struct Flat {
        cells: Vec<CEntry>,
        blob: Vec<u8>,
    }

    impl Flat {
        fn of(state: &HostWorkspaceState) -> Self {
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
            Self { cells, blob }
        }
    }

    fn pane_key(field: u8) -> WorkspaceKey {
        WorkspaceKey::new(WorkspaceObjectKind::Pane.as_byte(), [7; 16], field)
    }

    fn pane_state() -> HostWorkspaceState {
        let mut state = HostWorkspaceState::default();
        for field in 0..=pane::SPAWN_CWD {
            state.set(pane_key(field), vec![field, 0xFF]);
        }
        state
    }

    /// One encode through the C signature, sized the way §4 says to: probe, grow, call again.
    fn encode(state: &HostWorkspaceState) -> Vec<u8> {
        let flat = Flat::of(state);
        let mut out = vec![0_u8; 8];
        let mut needed = unsafe {
            slopdesk_ws_state_file_encode(
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
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
                slopdesk_ws_state_file_encode(
                    flat.cells.as_ptr(),
                    flat.cells.len(),
                    flat.blob.as_ptr(),
                    flat.blob.len(),
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
        }
        out.truncate(needed);
        out
    }

    /// One decode through the C signature: the status byte, the claimed version, the snapshot.
    fn decode(bytes: &[u8]) -> (u8, i64, Vec<u8>) {
        let mut status = 0xEE_u8;
        // A sentinel this door must not overwrite except on the one arm that names a version.
        let mut version = i64::MIN;
        let mut out = vec![0_u8; 8];
        let mut needed = unsafe {
            slopdesk_ws_state_file_decode(
                bytes.as_ptr(),
                bytes.len(),
                &raw mut status,
                &raw mut version,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        if needed > out.len() {
            out = vec![0_u8; needed];
            needed = unsafe {
                slopdesk_ws_state_file_decode(
                    bytes.as_ptr(),
                    bytes.len(),
                    &raw mut status,
                    &raw mut version,
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
        }
        out.truncate(needed);
        (status, version, out)
    }

    /// The cells a decode answered, read the way the Swift caller reads them.
    fn cells_of(snapshot: &[u8]) -> HostWorkspaceState {
        let entries = ws_codec::decode_snapshot(snapshot).expect("the door answered a snapshot");
        let mut state = HostWorkspaceState::default();
        for entry in entries {
            state.set(
                WorkspaceKey::new(entry.kind, entry.object, entry.field),
                entry.value.to_vec(),
            );
        }
        state
    }

    #[test]
    fn what_the_door_writes_the_door_reads() {
        let saved = state_file::persisting(&pane_state());
        let text = encode(&saved);
        let (status, version, snapshot) = decode(&text);
        assert_eq!(status, NO_REFUSAL);
        assert_eq!(version, i64::MIN, "a load that worked named a version");
        assert_eq!(cells_of(&snapshot).sorted_entries(), saved.sorted_entries());
    }

    #[test]
    fn the_bytes_are_the_wrapped_modules_own() {
        // The door may not have an encoding of its own. If this ever drifts, the file on disk stopped
        // being the one `state_file` describes and the module's tests stopped covering it.
        let saved = state_file::persisting(&pane_state());
        assert_eq!(encode(&saved), state_file::encode(&saved).into_bytes());
    }

    #[test]
    fn an_empty_document_is_four_bytes_and_a_refusal_is_none() {
        // The distinction the whole `status` out-parameter exists for. A well-formed file holding no
        // surviving cells encodes to a snapshot with a zero count in it; bytes that are not a file
        // answer nothing at all, and only the status tells the two apart.
        let (status, _, snapshot) = decode(&encode(&HostWorkspaceState::default()));
        assert_eq!(status, NO_REFUSAL);
        assert_eq!(snapshot.len(), 4, "an empty snapshot is its count and nothing");
        let (refused, _, none) = decode(b"not a file");
        assert_eq!(refused, FileError::Malformed.code());
        assert!(none.is_empty(), "a refusal handed back cells");
    }

    #[test]
    fn each_refusal_crosses_as_its_own_byte() {
        let text = state_file::encode(&state_file::persisting(&pane_state()));
        for (bytes, expected) in [
            (b"not json at all".to_vec(), FileError::Malformed),
            (b"{}".to_vec(), FileError::Malformed),
            (
                text.replace("\"version\" : 1", "\"version\" : 99").into_bytes(),
                FileError::VersionMismatch(99),
            ),
            (
                text.replacen("\"id\" : \"", "\"id\" : \"zz", 1).into_bytes(),
                FileError::MalformedRow,
            ),
        ] {
            let (status, _, answer) = decode(&bytes);
            assert_eq!(status, expected.code(), "{expected:?} lost its own byte");
            assert!(answer.is_empty());
        }
    }

    #[test]
    fn the_version_arrives_and_only_that_arm_writes_it() {
        let text = state_file::encode(&state_file::persisting(&pane_state()));
        let mismatched = text.replace("\"version\" : 1", "\"version\" : 99");
        let (status, version, _) = decode(mismatched.as_bytes());
        assert_eq!(status, FileError::VersionMismatch(99).code());
        assert_eq!(version, 99, "the caller cannot log a shape it was not told");
        // Every other arm leaves the caller's word alone: zero is a version a hand edit can claim.
        let (_, untouched, _) = decode(b"{}");
        assert_eq!(untouched, i64::MIN);
    }

    #[test]
    fn a_null_out_still_answers_the_status_and_the_size() {
        let text = encode(&state_file::persisting(&pane_state()));
        let mut status = 0xEE_u8;
        let needed = unsafe {
            slopdesk_ws_state_file_decode(
                text.as_ptr(),
                text.len(),
                &raw mut status,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(status, NO_REFUSAL);
        assert!(needed > 0, "a null out must still answer what it needed");
    }

    #[test]
    fn a_hand_edited_liveness_row_does_not_survive_the_crossing() {
        // The filter runs on the way IN as well as out, and the FILE is the one input a person can
        // edit. A row that came back live here would be the fake-live render the whole module exists
        // to prevent, arriving through the door rather than around it.
        let mut hostile = HostWorkspaceState::default();
        hostile.set(pane_key(pane::AGENT_STATE), vec![2, 0]);
        hostile.set(pane_key(pane::TITLE), b"kept".to_vec());
        let (status, _, snapshot) = decode(&encode(&hostile));
        assert_eq!(status, NO_REFUSAL);
        let back = cells_of(&snapshot);
        assert_eq!(back.get(&pane_key(pane::TITLE)), Some(b"kept".as_slice()));
        assert!(back.get(&pane_key(pane::AGENT_STATE)).is_none());
    }

    #[test]
    fn a_zero_length_value_stays_distinct_from_an_absent_row() {
        // An empty value is how a field is RETIRED. Two encodings and a snapshot crossing sit between
        // the write and the read, and each of them has a way to lose the distinction.
        let mut state = HostWorkspaceState::default();
        state.set(pane_key(pane::TITLE), Vec::new());
        let (status, _, snapshot) = decode(&encode(&state));
        assert_eq!(status, NO_REFUSAL);
        assert_eq!(
            cells_of(&snapshot).get(&pane_key(pane::TITLE)),
            Some([].as_slice())
        );
    }

    #[test]
    fn the_predicate_answers_the_wrapped_rule_at_every_pair() {
        // Exhaustive rather than sampled: the door's whole job is to have no opinion, and the pairs
        // it could disagree on are the ones nobody would think to write a case for.
        for kind in 0..=u8::MAX {
            for field in 0..=u8::MAX {
                assert_eq!(
                    slopdesk_ws_state_file_is_persisted(kind, field),
                    state_file::is_persisted(&WorkspaceKey {
                        kind,
                        object_id: [0; 16],
                        field,
                    }),
                    "kind {kind} field {field}",
                );
            }
        }
        // The two the rule is most often asked about, spelled out so a reader sees the shape.
        let project_kind = WorkspaceObjectKind::Project.as_byte();
        assert!(slopdesk_ws_state_file_is_persisted(project_kind, project::KEY));
        assert!(!slopdesk_ws_state_file_is_persisted(
            project_kind,
            project::GIT_SUMMARY
        ));
    }

    #[test]
    fn the_exported_status_order_is_the_one_the_door_answers() {
        // The index order is the only thing a caller transcribes, so it is the only thing that can
        // drift. Each index is checked against the byte the arm ACTUALLY produces.
        assert_eq!(slopdesk_ws_state_file_status(0), NO_REFUSAL);
        assert_eq!(slopdesk_ws_state_file_status(1), FileError::Malformed.code());
        assert_eq!(
            slopdesk_ws_state_file_status(2),
            FileError::VersionMismatch(0).code()
        );
        assert_eq!(slopdesk_ws_state_file_status(3), FileError::MalformedRow.code());
        assert_eq!(
            slopdesk_ws_state_file_status(200),
            FileError::Malformed.code(),
            "an index past the last refuses rather than admits",
        );
    }

    #[test]
    fn a_null_input_is_a_refusal_rather_than_an_empty_document() {
        // Null and empty are the same thing to this ABI, and empty bytes are not a file. The answer
        // must be the refusal, never the empty document a caller would then adopt.
        let mut status = 0xEE_u8;
        let needed = unsafe {
            slopdesk_ws_state_file_decode(
                core::ptr::null(),
                0,
                &raw mut status,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(status, FileError::Malformed.code());
        assert_eq!(needed, 0);
    }

    #[test]
    fn a_span_the_blob_cannot_back_encodes_as_an_empty_value() {
        // The offsets are arithmetic done in another process. A cell whose span runs off the end must
        // read as empty rather than trap — the file still writes, with one retired field in it.
        let mut flat = Flat::of(&state_file::persisting(&pane_state()));
        for cell in &mut flat.cells {
            if cell.field == pane::TITLE {
                cell.value.offset = usize::MAX - 1;
            }
        }
        let needed = unsafe {
            slopdesk_ws_state_file_encode(
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert!(needed > 0, "a hostile span took the file with it");
    }
}
