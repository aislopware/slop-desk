//! The two passes a LOADER runs: the repair a document gets on the way in, and the client's
//! `workspace.json` itself.
//!
//! Both answer the same question from opposite ends — what a file that this build did not write is
//! allowed to become — so the minting pool the repair needs and the decoder the file needs sit
//! together rather than naming each other across a module line.

use core::ffi::c_uchar;

use slopdesk_ids::identity::{IdSource, SessionId};
use slopdesk_ids::{PaneId, SplitNodeId, TabId};
use slopdesk_tree::workspace::TreeWorkspace;
use slopdesk_tree::{PaneKind, tree_ops, workspace};
use slopdesk_wire::document::codec as wire_codec;
use slopdesk_wire::document::state::HostWorkspaceState;
use slopdesk_wire::document::topology::WorkspaceTopology;
use slopdesk_workspace::persist;

use super::codec::CEntry;
use super::{Uuid, borrow_array};
use crate::workspace_state_file::{write_status, write_version};
use crate::{borrow, deliver};

// MARK: The repair pass a loader runs
//
// ## Why this door exists at all
// `TreeWorkspace::normalized` ran in BOTH languages until 2026-08-20, and the two did not shadow
// each other because they fired on different events: the Swift copy on file load, the Rust one on
// every intent. So launch-time repair and gesture-time repair reached different trees for the same
// input, and a workspace that closed cleanly came back subtly different after a relaunch. Four
// disagreements were live — which panes count as VIDEO (`kind == .desktop` against
// `PaneKind::is_video`), how one is REMOVED (a close intent per id against pruning the tree), where
// a re-seeded identity comes from, and which leaf a dangling focus falls back to. `docs/55` §8 is
// the row this closes.
//
// ## It rides the document's own bytes, as the intent applier does
// A `TreeWorkspace` is a split tree, and §4b's argument applies unchanged: there is no `#[repr(C)]`
// flattening of one that is not a second grammar to keep in step. It does not need one — the
// topology already HAS a byte encoding, so the cells go in as the flat `(CEntry, blob)` pairs
// `slopdesk_ws_encode_snapshot` takes and the repaired tree comes back as an encoded snapshot the
// caller reads with `slopdesk_ws_decode_snapshot`.
//
// ## The one shape that encoding cannot carry, stated out loud
// A session with NO usable tab is dropped by the document ingest, on BOTH sides
// (`WorkspaceTopology::from_document` here, `WorkspaceTopology.init?(entries:)` in Swift) —
// rightly, because a host push naming a tabless session is describing nothing, and minting a tab
// there would invent a workspace the host never published. A REPAIR wants the opposite answer: the
// session's name and its detached panes are still worth keeping, so `normalizing_active` re-seeds
// it a tab. That case therefore cannot reach this door, and the caller repairs it before encoding.
// It is the only part of the pass that did not cross, it is named in `docs/55` §8 and pinned by
// `slopdesk-invariants`, and the fix that removes it is a whole-`TreeWorkspace` codec in
// `slopdesk_workspace::persist` — which `derived_split_id`'s `## Owed` note is already headed for.
//
// A document with no workspace in it AT ALL does cross, and answers the re-seeded default: that is
// `normalizing_active`'s own `sessions.is_empty()` branch, reached by handing it an empty
// workspace, rather than a default this shim decided on.

/// The caller's pool of pre-minted identities, handed out in order.
///
/// This crate holds no entropy and [`slopdesk_ids::identity`] explains why — every repair
/// here has to be replayable, so the runtime that owns the randomness supplies the ids and a test
/// supplies a counter. One cursor across all four kinds rather than four, so a pass that takes a
/// tab and a split gets two DIFFERENT ids.
///
/// A pool that runs dry repeats its last entry rather than panicking. The caller's obligation is
/// [`slopdesk_ws_normalize_minted_ids`], and repeating is what this boundary owes a caller who got
/// their own arithmetic wrong: a refusal they can see in the tree, not a process that is gone.
pub(crate) struct MintedPool<'a> {
    pub(crate) ids: &'a [Uuid],
    pub(crate) next: usize,
}

impl MintedPool<'_> {
    pub(crate) fn take(&mut self) -> [u8; 16] {
        let picked = self.ids.get(self.next).or_else(|| self.ids.last());
        self.next += 1;
        picked.map_or([0; 16], |id| id.bytes)
    }
}

impl IdSource for MintedPool<'_> {
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

/// The identity pool one repair can spend over a workspace of that shape, exported rather than
/// transcribed.
///
/// A pool one short does not fail — it REPEATS an identity, and two tabs born with one id surfaces
/// days later as a tab that will not close. So the arithmetic lives in the crate that spends the
/// ids, and a caller asks.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_normalize_minted_ids(sessions: usize, detached: usize) -> usize {
    tree_ops::RepairPass::minted_ids(sessions, detached)
}

/// How many repair passes there are, so a caller can neither name one this build lacks nor miss one
/// it grew.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_normalize_pass_count() -> usize {
    tree_ops::RepairPass::ALL.len()
}

/// Runs one repair pass over a document's topology, answering the repaired cells as an encoded
/// snapshot.
///
/// `pass` is [`tree_ops::RepairPass`]'s arm order: 0 the spec table, 1 the selections, 2 both in
/// the order a load applies them, 3 the whole launch restore. A byte naming no pass answers 0 — a
/// refusal, never a silently different repair, because "specs only" and "the launch restore" differ
/// by whether a detached pane comes back.
///
/// `entries`/`blob` are the document in `slopdesk_ws_encode_snapshot`'s flat form. `minted` is the
/// identity pool, sized by [`slopdesk_ws_normalize_minted_ids`].
///
/// The return is the encoded snapshot's byte count under §4's convention — write nothing when it
/// does not fit, answer what was needed. `0` is the refusal above and nothing else: every pass over
/// every document answers a workspace, because a document with none in it is answered with the
/// re-seeded default rather than with silence.
///
/// # Safety
/// `entries` must be null or point to `entry_count` live [`CEntry`]s; `blob` null or to `blob_len`
/// live bytes; `minted` null or to `minted_count` live [`Uuid`]s; `out` null or writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_normalize(
    pass: c_uchar,
    entries: *const CEntry,
    entry_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    minted: *const Uuid,
    minted_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(pass) = tree_ops::RepairPass::from_byte(pass) else {
        return 0;
    };
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes, pool) = unsafe {
        (
            borrow_array(entries, entry_count),
            borrow(blob, blob_len),
            borrow_array(minted, minted_count),
        )
    };
    let mut ids = MintedPool { ids: pool, next: 0 };
    let state = crate::workspace_intent::document(cells, bytes);
    // No workspace in the document is not an error and not an empty answer: it is the input
    // `normalizing_active` re-seeds from, so it is handed over as one rather than answered here.
    let mut topology = state
        .topology()
        .unwrap_or_else(|| WorkspaceTopology::new(TreeWorkspace::new(Vec::new(), None)));
    topology.tree = tree_ops::repaired(&topology.tree, pass, &mut ids);
    let answer = wire_codec::encode_snapshot(&HostWorkspaceState::from_entries(topology.entries()));
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

/// Whether a `pane/kind` byte names a VIDEO pane — one that rides the shared UDP flow, counts
/// against the live-video cap, and never restores across a relaunch.
///
/// A predicate rather than a case list because it is what the launch restore DROPS by, and a second
/// spelling of it is exactly the drift `docs/55` §8 records: Swift asked `kind == .desktop` where
/// this crate asks `PaneKind::is_video`, which selects the same panes today and would stop the day
/// a third video-ish kind is added on one side only. A byte this build has no kind for reads as a
/// terminal — the degradation `WorkspacePaneKindTag` already picks — so an unknown kind is a
/// degraded pane rather than a stream opened for a window that will never exist.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_kind_is_video(kind: c_uchar) -> bool {
    PaneKind::from_byte(kind).is_video()
}

/// How many pane kinds there are.
///
/// Exported so a caller can WALK the vocabulary rather than name its members: a test that iterates
/// `0..count` against [`slopdesk_ws_pane_kind_is_video`] fails the day a third kind lands on one
/// side only, which counting Swift's cases against this crate's cannot see.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_kind_count() -> usize {
    PaneKind::ALL.len()
}

/// The title a re-seeded pane takes, §4-shaped.
///
/// Asked for rather than transcribed for the reason every constant here is: a caller comparing
/// against its own copy passes on a default this crate stopped producing, and the fresh-workspace
/// shape test is precisely a comparison against this string.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_default_pane_title(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(workspace::DEFAULT_PANE_TITLE.as_bytes(), out, cap) }
}

/// The name a fresh workspace's first session takes, §4-shaped. Asked for
/// [`slopdesk_ws_default_pane_title`]'s reason.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_default_session_name(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(workspace::DEFAULT_SESSION_NAME.as_bytes(), out, cap) }
}

/// The title a minted desktop pane takes, §4-shaped.
///
/// The third of the seeded names, and the one with two minters: the client makes a desktop pane on
/// a gesture and the wire crate makes one while applying a document. Both take the word from here,
/// so a rename cannot leave a session holding two differently-titled desktop panes that the user
/// made the same way.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_default_desktop_pane_title(
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(workspace::DEFAULT_DESKTOP_PANE_TITLE.as_bytes(), out, cap) }
}

// MARK: The client's workspace FILE
//
// ## Why this is a door rather than a shape
// `slopdesk_workspace::persist` is a complete repairing decoder for `workspace.json`, and it sat
// with 22 tests and no caller while `SplitNode+Codable.swift` and four `Codable` conformances ran
// instead. They had already drifted, and in the direction that costs a person something they can
// see: an id-less split is DERIVED here from its place in the tree, where Swift's `??
// SplitNodeID()` minted a fresh uuid on every load — so a `splitNode/<id>/weight` cell written
// before a relaunch was orphaned after it, and every divider the person had dragged went back to
// the default with nothing logged. `docs/55` §8's `derived_split_id` row is what this closes.
//
// ## It rides the document's own bytes, as its two neighbours do
// The same arrangement `slopdesk_ws_apply_intent`, `slopdesk_ws_state_file_*` and
// `slopdesk_ws_normalize` use, for the same reason: a `TreeWorkspace` is a split tree and there is
// no `#[repr(C)]` flattening of one that is not a second grammar to keep in step. So the workspace
// goes IN as the flat `(CEntry, blob)` cells `slopdesk_ws_encode_snapshot` already takes, and a
// decoded file comes back OUT as an encoded snapshot the caller reads with
// `slopdesk_ws_decode_snapshot`. Nothing new travels in either direction.
//
// ## The decode REPAIRS before it answers, and that is forced rather than chosen
// The document's cell encoding cannot spell a session with no tab or a leaf with no spec — its
// ingest drops the first and invents the second, on both sides, because a host push naming a
// tabless session is describing nothing. A file can hold both. So the decode ends where
// `TreeWorkspace::normalized` ends, which is where the launch path already ended, and the shape the
// crossing cannot carry never reaches the crossing. That is also what `slopdesk_ws_normalize`'s own
// note says will remove `withTheDocumentsBlindSpotsClosed` from the FILE path.
//
// ## No id is minted on this side, and the two kinds are minted differently on purpose
// The identities a repair spends come from the caller's pool, sized by
// `slopdesk_ws_workspace_file_minted_ids` — a PaneId is the join to the registry that owns a
// process, so a name derived from the file's own contents is one two launches could both produce.
// A SplitNodeId is the opposite case and is derived inside the crate, because it names a divider
// group and a persisted weight cell only keeps pointing at its seam if the name is stable. Both
// rules live in `persist.rs`; neither is decided here.

/// The identities a decode of these bytes can spend.
///
/// Asked rather than transcribed for the reason every pool size in this crate is: a pool one short
/// does not fail, it REPEATS an identity, and two panes sharing one is a pane that reattaches to a
/// process it never opened. This one takes the FILE rather than a shape, because the shape is
/// exactly what the caller does not know yet.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_minted_ids(bytes: *const c_uchar, len: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let input = unsafe { borrow(bytes, len) };
    persist::minted_ids_for(input)
}

/// Whether these bytes are the THROWAWAY DEFAULT a `New Window` launch autosaves.
///
/// The FILE goes in rather than a decoded shape, and that is what the door buys: the caller's
/// alternative was to decode on its own side and compare the two seed names against literals, which
/// is the second spelling `slopdesk_ws_default_session_name` and `slopdesk_ws_default_pane_title`
/// exist to prevent — a copy of either would keep answering `true` for a default this build had
/// stopped writing.
///
/// `false` is "not PROVABLY the default": unreadable bytes, a foreign `schemaVersion` and an
/// over-large file all land there, so a file this build cannot read is preserved aside rather than
/// skipped. It is not a claim that the file holds a real session.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_is_default_shape(
    bytes: *const c_uchar,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let input = unsafe { borrow(bytes, len) };
    persist::is_default_file_shape(input)
}

/// The file's bytes for a workspace, under §4's convention.
///
/// `entries`/`blob` are the document's cells in `slopdesk_ws_encode_snapshot`'s flat form. Only the
/// topology half is read — the file is the client's LAYOUT, and liveness has no business on a disk
/// that outlives the process it describes. Encoding cannot fail, so there is no status here.
///
/// The answer is UTF-8 JSON with sorted keys and a trailing newline, so two saves of one value are
/// byte-identical and the file diffs cleanly.
///
/// `schema_version` is passed rather than derived, and that is the whole reason it is a parameter:
/// the cells carry a SHAPE, and a version is a property of the FILE, so a tree rebuilt from them
/// wears whatever [`TreeWorkspace::new`] stamps — today's `CURRENT_SCHEMA_VERSION`. Deriving it
/// here would make every save quietly re-stamp a workspace as the schema this build happens to
/// read, which is precisely the claim the load path's version check exists to be able to
/// disbelieve.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s; `blob` null or to `blob_len` live
/// bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_encode(
    entries: *const CEntry,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    schema_version: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes) = unsafe { (borrow_array(entries, count), borrow(blob, blob_len)) };
    let state = crate::workspace_intent::document(cells, bytes);
    // A document with no workspace in it writes an empty one rather than nothing at all: the file
    // has to be a file, and the load path answers its own default for one that names no session.
    let mut tree = state
        .topology()
        .map_or_else(|| TreeWorkspace::new(Vec::new(), None), |topology| topology.tree);
    tree.schema_version = schema_version;
    let text = persist::encode_file(&tree);
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// Reads a file back, answering the REPAIRED workspace as an encoded snapshot.
///
/// `bytes` is the file exactly as it came off disk. `minted` is the identity pool, sized by
/// [`slopdesk_ws_workspace_file_minted_ids`] over those same bytes. `status` receives the refusal
/// byte on EVERY path — `persist::NO_REFUSAL` when the load worked — so a caller that only wants
/// the verdict may pass a null `out` and read it there. `version` receives the version the file
/// CLAIMED, and only on the version-mismatch path; it is left untouched otherwise, because every
/// `i64` is a version somebody could have typed in and none of them could have meant "not about a
/// version".
///
/// The return is the encoded snapshot's byte count under §4's convention. A refusal answers 0, and
/// so nothing else does: the repair runs before the answer is written, and it re-seeds a workspace
/// that named nothing, so every load that got past the refusal has at least one session to encode.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `minted` null or to `minted_count` live
/// [`Uuid`]s; `status` null or writable for one byte; `version` null or writable for one `int64_t`;
/// `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_decode(
    bytes: *const c_uchar,
    len: usize,
    minted: *const Uuid,
    minted_count: usize,
    status: *mut c_uchar,
    version: *mut i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (input, pool) = unsafe { (borrow(bytes, len), borrow_array(minted, minted_count)) };
    let mut ids = MintedPool { ids: pool, next: 0 };
    match persist::decode_file(input, &mut ids) {
        Ok(tree) => {
            // SAFETY: null or, by the caller's obligation, writable for one byte.
            unsafe { write_status(status, persist::NO_REFUSAL) };
            let cells = HostWorkspaceState::from_entries(WorkspaceTopology::new(tree).entries());
            let answer = wire_codec::encode_snapshot(&cells);
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
/// `0` is the load that worked, then [`persist::FileError`]'s own arm order — malformed, version
/// mismatch, too many panes. An index past the last answers the malformed byte, which refuses
/// rather than admits.
///
/// Exported rather than transcribed: a caller that wrote `case malformed = 1` beside this would be
/// a second copy of the numbering, and the arm it drifted on would turn a version this build cannot
/// read into a file kept aside under the wrong name — or not kept aside at all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_workspace_file_status(index: c_uchar) -> c_uchar {
    match index {
        0 => persist::NO_REFUSAL,
        2 => persist::FileError::VersionMismatch(0).code(),
        3 => persist::FileError::TooManyPanes.code(),
        _ => persist::FileError::Malformed.code(),
    }
}

/// How many panes one workspace file may name before [`slopdesk_ws_workspace_file_decode`] refuses
/// it with index 3 of [`slopdesk_ws_workspace_file_status`].
///
/// Asked for rather than spelled twice, the rule every in-process cap in this header follows
/// (`slopdesk_ws_topology_ring_cap` carries the long version). This one is a REFUSAL threshold, so
/// the two copies drifting does not read as a disagreement: the near side would build a file it
/// believes fits, the far side would refuse it, and the user would meet a workspace reset to the
/// default with nothing anywhere saying why.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_workspace_file_max_panes() -> usize {
    persist::MAX_PANES
}
