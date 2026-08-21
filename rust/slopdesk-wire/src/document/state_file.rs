//! What of the workspace document survives a host restart, and in what shape on disk.
//!
//! **JSON here is deliberate and is not a contradiction of the manual-binary rule — that rule is
//! about the WIRE.** This file is read once at start by the process that wrote it; determinism and
//! reviewability matter, latency does not. [`slopdesk_workspace::json`] carries the format and the
//! reasoning.
//!
//! The interesting half is not the encoding but the FILTER. Serializing the entry map wholesale
//! would restore `command_running = 1`, `agent_state = working` and a liveness of `attached` for a
//! pane whose child exited weeks ago — a workspace of fake-live rows, busy dots spinning for
//! nothing. The detached-session store is in-process, so no live process survives a restart and the
//! document must come back saying exactly that.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use slopdesk_workspace::identity::{parse_uuid, uuid_text};
use slopdesk_workspace::json::{self, Json};

use crate::document::fields::{pane, project};
use crate::document::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};

/// Bumped when the on-disk shape changes.
///
/// It exists to force a decode-fail, not to migrate: the standing rule is that stale data degrades
/// to the default rather than being carried forward, and the caller's answer to a failed decode is
/// the default document plus the old file kept aside.
pub const VERSION: i64 = 1;

/// The pane fields that survive a restart.
///
/// Deliberately NOT the topology half: `cwd` and `project_key` are liveness — the host re-derives
/// them from a live shell — yet they persist, because a restored pane has no shell to ask and the
/// By-Project sidebar would otherwise re-bucket visibly on the first live edge. They are the only
/// two liveness fields that describe a PLACE rather than a running process, which is exactly why
/// they are safe to restore and the rest are not.
///
/// Spelled out rather than derived from [`crate::document::liveness::TOPOLOGY_FIELDS`] because a
/// `const` cannot iterate, and `the_persisted_set_is_the_topology_half_plus_exactly_two` is the
/// ratchet that keeps the two lists from drifting — a new topology field that nobody adds here
/// fails that test rather than silently failing to survive a restart.
const PERSISTED_PANE_FIELDS: [u8; 7] = [
    pane::KIND,
    pane::TITLE,
    pane::USER_RENAMED,
    pane::VIDEO_TARGET,
    pane::SPAWN_CWD,
    pane::CWD,
    pane::PROJECT_KEY,
];

/// Whether one cell survives a restart.
///
/// An unknown kind tag — a file written by a NEWER build — is dropped rather than carried. That is
/// the no-migration directive, not an oversight: keeping bytes this build can neither read nor reap
/// would leave ghost objects in the document with nothing able to remove them.
#[must_use]
pub fn is_persisted(key: &WorkspaceKey) -> bool {
    match WorkspaceObjectKind::from_byte(key.kind) {
        Some(
            WorkspaceObjectKind::Root
            | WorkspaceObjectKind::Session
            | WorkspaceObjectKind::Tab
            | WorkspaceObjectKind::SplitNode,
        ) => true,
        Some(WorkspaceObjectKind::Pane) => PERSISTED_PANE_FIELDS.contains(&key.field),
        // The path survives; the git summary does not. The filesystem watcher re-derives it within a
        // tick, and a restored summary would describe a working tree that has moved on.
        Some(WorkspaceObjectKind::Project) => key.field == project::KEY,
        None => false,
    }
}

/// The state reduced to what belongs on disk.
#[must_use]
pub fn persisting(state: &HostWorkspaceState) -> HostWorkspaceState {
    let mut out = HostWorkspaceState::default();
    for entry in state.sorted_entries() {
        if is_persisted(&entry.key) {
            out.set(entry.key, entry.value);
        }
    }
    out
}

/// What a load can refuse with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileError {
    /// The bytes are not the document this build writes.
    Malformed,
    /// The file is from a different shape of this store. Not migrated — the caller mints a default
    /// and keeps the old file aside.
    VersionMismatch(i64),
    /// A row this build cannot make sense of.
    ///
    /// One bad row fails the whole load ON PURPOSE: a partially-restored workspace is a workspace
    /// with holes in it, and the person would have to work out which half is real.
    MalformedRow,
}

/// The byte a load that did NOT refuse reports.
///
/// Zero, so a caller reading one out-parameter on every path can tell a load that worked from one
/// that did not without a second flag beside it. No [`FileError`] answers it — that is the property
/// `every_refusal_has_its_own_byte_and_none_of_them_is_ok` pins.
pub const NO_REFUSAL: u8 = 0;

impl FileError {
    /// The byte this refusal crosses a C boundary as.
    ///
    /// The numbering lives on the ARMS rather than in the shim that exports it. `docs/55` §5
    /// forbids a door to map an error onto a different error, and a door that invented these
    /// bytes would be doing exactly that — as well as being the second place this taxonomy is
    /// written down, which is what the whole file exists to avoid. A caller that must tell "not
    /// our file" from "wrong shape of our file" from "one bad row" reads these and nothing
    /// else.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Malformed => 1,
            Self::VersionMismatch(_) => 2,
            Self::MalformedRow => 3,
        }
    }

    /// The version the file CLAIMED, for the one arm that names one.
    ///
    /// An `Option` rather than a number with a reserved absence, because every `i64` is a version
    /// somebody could have typed into the file by hand — including `0` — so no in-band value could
    /// have meant "this refusal is not about a version".
    #[must_use]
    pub const fn claimed_version(self) -> Option<i64> {
        match self {
            Self::VersionMismatch(version) => Some(version),
            Self::Malformed | Self::MalformedRow => None,
        }
    }
}

/// Renders the state as the file's bytes.
///
/// Sorted keys and canonical entry order, so two saves of one value are byte-identical and the file
/// diffs cleanly. Indented for the same reason the client's workspace file is: a persistence file
/// nobody can read is a persistence file nobody can debug.
#[must_use]
pub fn encode(state: &HostWorkspaceState) -> String {
    let rows: Vec<Json> = state
        .sorted_entries()
        .into_iter()
        .map(|entry| {
            json::object([
                ("kind", Json::Integer(i64::from(entry.key.kind))),
                ("id", Json::String(uuid_text(entry.key.object_id))),
                ("field", Json::Integer(i64::from(entry.key.field))),
                // Base64. A zero-length value encodes as `""` and stays distinct from an absent row
                // — an empty value is how a field is RETIRED, and conflating the two would resurrect
                // a title the agent gave up.
                ("value", Json::String(base64_encode(&entry.value))),
            ])
        })
        .collect();
    json::to_pretty_string(&json::object([
        ("version", Json::Integer(VERSION)),
        ("entries", Json::Array(rows)),
    ]))
}

/// Reads a file back into a state.
///
/// # Errors
/// [`FileError::Malformed`] for bytes that are not this document at all,
/// [`FileError::VersionMismatch`] for another shape of it, [`FileError::MalformedRow`] for a row
/// whose id or value will not decode.
pub fn decode(text: &str) -> Result<HostWorkspaceState, FileError> {
    let document = json::parse(text).map_err(|_ignored| FileError::Malformed)?;
    let Some(version) = document.get("version").and_then(Json::integer) else {
        return Err(FileError::Malformed);
    };
    if version != VERSION {
        return Err(FileError::VersionMismatch(version));
    }
    let Some(rows) = document.get("entries").and_then(Json::array) else {
        return Err(FileError::Malformed);
    };
    let mut state = HostWorkspaceState::default();
    for row in rows {
        let (Some(kind), Some(field)) = (
            row.get("kind").and_then(Json::integer),
            row.get("field").and_then(Json::integer),
        ) else {
            return Err(FileError::MalformedRow);
        };
        let (Ok(kind), Ok(field)) = (u8::try_from(kind), u8::try_from(field)) else {
            return Err(FileError::MalformedRow);
        };
        let (Some(id), Some(value)) = (
            row.get("id").and_then(Json::string).and_then(parse_uuid),
            row.get("value").and_then(Json::string).and_then(base64_decode),
        ) else {
            return Err(FileError::MalformedRow);
        };
        let key = WorkspaceKey::new(kind, id, field);
        // Re-filtered on the way IN as well as out. A hand-edited file could otherwise restore a
        // pane as attached with no process behind it, which is the exact render the filter exists to
        // prevent — and the file is the one input a person can edit by hand.
        if is_persisted(&key) {
            state.set(key, value);
        }
    }
    Ok(state)
}

/// Reads a file's raw BYTES back into a state.
///
/// The same load as [`decode`], for a caller holding bytes rather than a `str` — which is every
/// caller that just read a file off disk, and the FFI door in particular, since a C boundary has no
/// `str`. Bytes that are not UTF-8 are [`FileError::Malformed`] for the same reason a stray brace
/// is: they are not this document. Deciding that HERE rather than in the shim is the point — a door
/// that mapped a UTF-8 fault onto a file error would be holding a decision `docs/55` §5 says it may
/// not hold.
///
/// # Errors
/// As [`decode`], plus [`FileError::Malformed`] for bytes that are not UTF-8 at all.
pub fn decode_bytes(bytes: &[u8]) -> Result<HostWorkspaceState, FileError> {
    let text = core::str::from_utf8(bytes).map_err(|_ignored| FileError::Malformed)?;
    decode(text)
}

// ---------------------------------------------------------------------------------------------- //
// Base64
// ---------------------------------------------------------------------------------------------- //

/// The standard alphabet WITH padding, which is what Swift's `base64EncodedString()` wrote and
/// what every state file on disk therefore carries. `STANDARD` is the engine that spells exactly
/// that, and `RequireCanonical` padding is what makes the decoder refuse the shapes a truncated or
/// spliced file would present: unpadded tails, padding in the middle, two payloads concatenated.
fn base64_encode(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

/// `None` for a string that is not standard padded base64. Strict on purpose — half-decoding a
/// file somebody truncated turns it into a plausible-looking short one.
fn base64_decode(text: &str) -> Option<Vec<u8>> {
    STANDARD.decode(text).ok()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a refused decode in a round-trip test has nothing to return"
    )]

    use super::{
        FileError, NO_REFUSAL, PERSISTED_PANE_FIELDS, VERSION, base64_decode, base64_encode, decode,
        decode_bytes, encode, is_persisted, persisting,
    };
    use crate::document::fields::{pane, project};
    use crate::document::liveness::{LIVENESS_FIELDS, TOPOLOGY_FIELDS};
    use crate::document::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};

    fn pane_key(field: u8) -> WorkspaceKey {
        WorkspaceKey::new(WorkspaceObjectKind::Pane as u8, [7; 16], field)
    }

    fn pane_state() -> HostWorkspaceState {
        let mut state = HostWorkspaceState::default();
        for field in 0..=pane::SPAWN_CWD {
            state.set(pane_key(field), vec![field, 0xFF]);
        }
        state
    }

    #[test]
    fn a_running_process_does_not_come_back_from_the_dead() {
        let saved = persisting(&pane_state());
        for field in LIVENESS_FIELDS {
            if field == pane::CWD || field == pane::PROJECT_KEY {
                continue;
            }
            assert!(
                saved.get(&pane_key(field)).is_none(),
                "field {field} would render a busy dot for a process that exited weeks ago",
            );
        }
    }

    #[test]
    fn the_place_fields_survive_so_the_sidebar_does_not_re_bucket_on_load() {
        let saved = persisting(&pane_state());
        assert!(saved.get(&pane_key(pane::CWD)).is_some());
        assert!(saved.get(&pane_key(pane::PROJECT_KEY)).is_some());
        for field in TOPOLOGY_FIELDS {
            assert!(
                saved.get(&pane_key(field)).is_some(),
                "the arrangement is the point"
            );
        }
    }

    #[test]
    fn the_persisted_set_is_the_topology_half_plus_exactly_two() {
        let mut expected: Vec<u8> = TOPOLOGY_FIELDS.to_vec();
        expected.push(pane::CWD);
        expected.push(pane::PROJECT_KEY);
        let mut have = PERSISTED_PANE_FIELDS.to_vec();
        have.sort_unstable();
        expected.sort_unstable();
        assert_eq!(have, expected);
    }

    #[test]
    fn a_git_summary_is_dropped_but_the_project_path_is_kept() {
        let kind = WorkspaceObjectKind::Project as u8;
        assert!(is_persisted(&WorkspaceKey::new(kind, [1; 16], project::KEY)));
        assert!(!is_persisted(&WorkspaceKey::new(
            kind,
            [1; 16],
            project::GIT_SUMMARY
        )));
    }

    #[test]
    fn a_kind_this_build_does_not_know_is_dropped_rather_than_carried() {
        assert!(!is_persisted(&WorkspaceKey::new(0xEE, [1; 16], 0)));
    }

    #[test]
    fn a_save_round_trips_and_two_saves_are_byte_identical() {
        let saved = persisting(&pane_state());
        let text = encode(&saved);
        assert_eq!(
            text,
            encode(&saved),
            "a file that churns is a file nobody can diff"
        );
        let Ok(back) = decode(&text) else {
            panic!("what this module wrote, it reads");
        };
        assert_eq!(back.sorted_entries(), saved.sorted_entries());
    }

    #[test]
    fn a_zero_length_value_stays_distinct_from_an_absent_row() {
        let mut state = HostWorkspaceState::default();
        state.set(pane_key(pane::TITLE), Vec::new());
        let Ok(back) = decode(&encode(&state)) else {
            panic!("an empty value is how a field is retired");
        };
        assert_eq!(back.get(&pane_key(pane::TITLE)), Some([].as_slice()));
    }

    #[test]
    fn a_file_from_another_shape_of_this_store_names_its_version() {
        let text = encode(&persisting(&pane_state())).replace("\"version\" : 1", "\"version\" : 99");
        assert_eq!(decode(&text), Err(FileError::VersionMismatch(99)));
    }

    #[test]
    fn one_bad_row_fails_the_whole_load() {
        let text = encode(&persisting(&pane_state())).replacen("\"id\" : \"", "\"id\" : \"zz", 1);
        assert_eq!(decode(&text), Err(FileError::MalformedRow));
    }

    #[test]
    fn bytes_that_are_not_this_document_are_malformed_rather_than_a_panic() {
        assert_eq!(decode("not json at all"), Err(FileError::Malformed));
        assert_eq!(decode("{}"), Err(FileError::Malformed));
        assert_eq!(
            decode(&format!("{{\"version\" : {VERSION}}}")),
            Err(FileError::Malformed)
        );
    }

    #[test]
    fn a_hand_edited_file_cannot_restore_a_pane_as_live() {
        let mut hostile = HostWorkspaceState::default();
        hostile.set(pane_key(pane::AGENT_STATE), vec![2, 0]);
        // Written straight, bypassing the outbound filter, exactly as a person with an editor would.
        let rows = encode(&hostile);
        assert!(rows.contains("\"entries\""));
        let Ok(back) = decode(&rows) else {
            panic!("the row is well-formed; it is the POLICY that refuses it");
        };
        assert!(back.get(&pane_key(pane::AGENT_STATE)).is_none());
    }

    #[test]
    fn every_refusal_has_its_own_byte_and_none_of_them_is_ok() {
        // The whole taxonomy's reason for existing is that a caller can TELL these apart, and across
        // a C boundary it can only tell them apart by these bytes. Two arms sharing one would make
        // "not our file" and "one bad row" the same report, which is the difference between minting
        // a default and hunting a corrupt row.
        let bytes: Vec<u8> = [
            FileError::Malformed,
            FileError::VersionMismatch(99),
            FileError::MalformedRow,
        ]
        .iter()
        .map(|refusal| refusal.code())
        .collect();
        let mut unique = bytes.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), bytes.len(), "two refusals share one byte");
        assert!(
            !bytes.contains(&NO_REFUSAL),
            "a refusal reads as the load that worked"
        );
    }

    #[test]
    fn only_the_version_arm_names_a_version() {
        assert_eq!(FileError::VersionMismatch(99).claimed_version(), Some(99));
        // Zero is a version somebody can type into the file, so it cannot double as "no version".
        assert_eq!(FileError::VersionMismatch(0).claimed_version(), Some(0));
        assert_eq!(FileError::Malformed.claimed_version(), None);
        assert_eq!(FileError::MalformedRow.claimed_version(), None);
    }

    #[test]
    fn bytes_that_are_not_utf8_are_not_this_document() {
        // What a caller holding a file gets: raw bytes. A truncated multi-byte scalar is the shape a
        // half-written file presents, and it must land on the same answer a stray brace does.
        assert_eq!(decode_bytes(&[0xFF, 0xFE, 0xFD]), Err(FileError::Malformed));
        let text = encode(&persisting(&pane_state()));
        let Ok(back) = decode_bytes(text.as_bytes()) else {
            panic!("what this module wrote, it reads as bytes too");
        };
        assert_eq!(back.sorted_entries(), persisting(&pane_state()).sorted_entries());
    }

    #[test]
    fn base64_round_trips_at_every_length_remainder() {
        for length in 0..=32_usize {
            #[expect(
                clippy::cast_possible_truncation,
                reason = "the mask is what makes this a byte"
            )]
            let bytes: Vec<u8> = (0..length).map(|index| (index * 7 + 3) as u8).collect();
            let text = base64_encode(&bytes);
            assert!(
                text.len().is_multiple_of(4),
                "padding keeps the length a multiple of four"
            );
            assert_eq!(base64_decode(&text), Some(bytes), "at length {length}");
        }
    }

    #[test]
    fn base64_matches_the_known_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64_decode("Zm9vYmFy"), Some(b"foobar".to_vec()));
        assert_eq!(base64_encode(&[0xFB, 0xFF, 0xFE]), "+//+");
    }

    #[test]
    fn base64_that_is_not_base64_is_refused_rather_than_guessed_at() {
        for hostile in ["Zg=", "Zg", "Z g==", "Z===", "====", "Zm9v!", "=Zm9"] {
            assert_eq!(base64_decode(hostile), None, "{hostile:?} is not base64");
        }
    }
}
