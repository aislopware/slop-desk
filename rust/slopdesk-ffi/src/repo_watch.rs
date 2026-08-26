//! When a repo's git line is worth re-reading — the doors over
//! [`slopdesk_muxsession::repo_watch`].
//!
//! ## What replaced what
//! `Sources/SlopDeskHost/RepoStatusWatcher.swift`'s queue-confined state: the owner refcounts, the
//! debounce generation, the one-reading-in-flight guard with its single re-arm, and the dirty guard
//! that keeps identical output from waking every attached client. What stays on the Swift side is
//! `FSEvents`, the two dispatch queues, the clock the debounce is measured on and the filesystem
//! walk that reads the status — frameworks and threads, none of which decides anything.
//!
//! ## A mutator answers by STASHING, because a re-ask would act twice
//! Three of these doors both change the fold and hand back a list. The two-call length protocol at
//! the top of the header — ask with a small buffer, grow, ask again — is sound only for a PURE
//! answer, so those three do not take `(out, cap)` at all: each returns the size of its answer and
//! holds it, and [`slopdesk_repo_watch_answer`] delivers it as many times as the caller likes. It
//! is the [`crate::video_packetizer`] shape, and the reason is the same one: a door that acted
//! twice would silently cancel a stream it had already cancelled, or fail to create one it had
//! already created.
//!
//! ## A handle, because the fold is not a fold
//! Every other rule in this crate is a function of its arguments. This one is not: a verdict about
//! one edge depends on every edge before it, and the state it depends on is a set of maps that
//! would cost more to marshal per call than the rule costs to run. So it is `docs/55` §4's handle
//! shape — one [`slopdesk_repo_watch_new`] per watcher, one [`slopdesk_repo_watch_free`], and no
//! two calls on the same handle at once.
//!
//! The no-overlap obligation is free here rather than a burden: the caller confines every one of
//! these calls to a single serial dispatch queue, which is what made the Swift original lock-free
//! too. A second caller would be a change to that design, not to this door.
//!
//! ## The status crosses as its fields, and equality is the rules module's
//! The dirty guard asks "is this reading the same as the last one I pushed", and the answer must be
//! the same answer the client would give looking at the two messages. So the ten fields cross flat
//! and the comparison is [`ProjectGitStatus`]'s own derived equality — the type the wire codec
//! already encodes — rather than a fingerprint either side computes for itself. A fingerprint is a
//! second definition of "the same status", and the failure it buys is silent: two different
//! readings that hash alike stop the git line updating with nothing anywhere to say so.

use core::ffi::c_uchar;

use slopdesk_muxsession::repo_watch::{DEBOUNCE_SECONDS, ProbeVerdict, RepoWatch};
use slopdesk_wire::message::ProjectGitStatus;

use crate::{deliver, lent, push_text};

/// [`slopdesk_repo_watch_debounce_fired`]: a newer edge already re-armed this repo, its last owner
/// left, or the watcher stopped. Nothing happens.
pub const SLOPDESK_REPO_WATCH_STALE: u8 = 0;
/// [`slopdesk_repo_watch_debounce_fired`]: no client is attached, so the reading is skipped.
pub const SLOPDESK_REPO_WATCH_NO_AUDIENCE: u8 = 1;
/// [`slopdesk_repo_watch_debounce_fired`]: a reading is already in flight; one follow-up is armed.
pub const SLOPDESK_REPO_WATCH_DEFERRED: u8 = 2;
/// [`slopdesk_repo_watch_debounce_fired`]: read the status now.
pub const SLOPDESK_REPO_WATCH_PROBE: u8 = 3;

/// An opaque repo-watch fold. Created by [`slopdesk_repo_watch_new`], destroyed by
/// [`slopdesk_repo_watch_free`].
#[derive(Debug, Default)]
pub struct SlopDeskRepoWatch {
    /// The rules module's state — see [`slopdesk_muxsession::repo_watch`].
    fold: RepoWatch,
    /// The last mutator's answer, held until the caller drains it with
    /// [`slopdesk_repo_watch_answer`]. Draining does not clear it: a buffer the caller sized wrong
    /// is a buffer it asks for again, and asking must not be what loses the answer.
    answer: Vec<u8>,
}

/// What to do when a reading returns.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskRepoWatchFinish {
    /// Whether this reading is news worth sending to the attached clients.
    pub push: bool,
    /// Whether `rearm` names a generation, i.e. whether a follow-up debounce is owed.
    pub has_rearm: bool,
    /// The generation a follow-up debounce must carry back, when `has_rearm` is set.
    pub rearm: u64,
}

/// How long after the LAST event of a burst the status is re-read, in seconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_repo_watch_debounce_seconds() -> f64 {
    DEBOUNCE_SECONDS
}

/// Creates a repo-watch fold. Exactly one [`slopdesk_repo_watch_free`] per call; see `docs/55` §4b.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_repo_watch_new() -> *mut SlopDeskRepoWatch {
    Box::into_raw(Box::new(SlopDeskRepoWatch {
        fold: RepoWatch::new(),
        answer: Vec::new(),
    }))
}

/// Frees a repo-watch fold. Null is a no-op.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_repo_watch_new`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_free(handle: *mut SlopDeskRepoWatch) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from `Box::into_raw` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Whether [`slopdesk_repo_watch_note_project_key`] would do anything.
///
/// The caller's cue to run the filesystem test that answers `is_repo_root`, which is a `stat` it
/// would otherwise pay per prompt edge. A null handle answers `false`, which asks for no work.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight; `key` must be null or
/// point to `key_len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_wants_key(
    handle: *const SlopDeskRepoWatch,
    owner: u64,
    key: *const c_uchar,
    key_len: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: the caller's obligations, restated above; `lent` states its own.
    unsafe { (*handle).fold.wants_key(owner, lent(key, key_len)) }
}

/// An owner latched a By-Project key.
///
/// Stashes TWO length-prefixed runs for [`slopdesk_repo_watch_answer`] — the repo whose stream to
/// cancel, then the repo to start one for, each EMPTY when there is none, since a repo path never
/// is — and returns their size.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight; `key` must be null or
/// point to `key_len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_note_project_key(
    handle: *mut SlopDeskRepoWatch,
    owner: u64,
    key: *const c_uchar,
    key_len: usize,
    is_repo_root: bool,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let effects = (*handle)
            .fold
            .note_project_key(owner, lent(key, key_len), is_repo_root);
        let mut blob: Vec<u8> = Vec::new();
        push_text(&mut blob, effects.cancel.as_deref().unwrap_or_default());
        push_text(&mut blob, effects.create.as_deref().unwrap_or_default());
        (*handle).answer = blob;
        (*handle).answer.len()
    }
}

/// An owner ended. Stashes the repo whose stream to cancel — RAW, not run-framed, because there is
/// at most one — or nothing when this was not its last owner, and returns its size.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_drop_owner(handle: *mut SlopDeskRepoWatch, owner: u64) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above.
    unsafe {
        let cancelled = (*handle).fold.drop_owner(owner).unwrap_or_default();
        (*handle).answer = cancelled.into_bytes();
        (*handle).answer.len()
    }
}

/// The daemon stopped. Stashes one length-prefixed run per stream the caller must cancel and
/// latches the fold so nothing is armed, created or pushed again, then returns the answer's size.
///
/// The run count is not carried: a run costs at least its four-byte prefix, so `len / 4` is a sound
/// upper bound for the walk and a run that would read past the end ends it — which is the same stop
/// condition `ffiRuns` already applies to every other list this crate delivers.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_shutdown(handle: *mut SlopDeskRepoWatch) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `push_text` states its own.
    unsafe {
        let mut blob: Vec<u8> = Vec::new();
        for repo in (*handle).fold.shutdown() {
            push_text(&mut blob, &repo);
        }
        (*handle).answer = blob;
        (*handle).answer.len()
    }
}

/// Delivers the answer the last mutator stashed, as many times as asked.
///
/// Pure: it neither changes the fold nor consumes the answer, which is what makes the header's
/// grow-and-ask-again protocol sound for it where it is not sound for the mutators themselves.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight; `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_answer(
    handle: *const SlopDeskRepoWatch,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `deliver` states its own.
    unsafe { deliver(&(*handle).answer, out, cap) }
}

/// A filesystem event burst landed: (re)arm the debounce, latest edge wins.
///
/// Writes the generation the caller must hand back when its timer expires and answers `true`;
/// answers `false` — writing nothing — when this repo is not watched.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight; `repo` must be null or
/// point to `repo_len` initialised bytes live for the call; `generation` must be null or point to a
/// live, writable value for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_source_event(
    handle: *mut SlopDeskRepoWatch,
    repo: *const c_uchar,
    repo_len: usize,
    generation: *mut u64,
) -> bool {
    if handle.is_null() || generation.is_null() {
        return false;
    }
    // SAFETY: the caller's obligations, restated above; `lent` states its own.
    unsafe {
        let Some(armed) = (*handle).fold.source_event(lent(repo, repo_len)) else {
            return false;
        };
        generation.write(armed);
        true
    }
}

/// The debounce armed at `generation` expired. Answers one of the four `SLOPDESK_REPO_WATCH_*`
/// verdicts; a null handle answers [`SLOPDESK_REPO_WATCH_STALE`], which asks for nothing.
///
/// `has_audience` is the caller's answer to "is any client attached", read one step earlier than
/// the reading it gates — a boolean the caller already holds, against a filesystem walk it might
/// not have to make.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight; `repo` must be null or
/// point to `repo_len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_debounce_fired(
    handle: *mut SlopDeskRepoWatch,
    repo: *const c_uchar,
    repo_len: usize,
    generation: u64,
    has_audience: bool,
) -> u8 {
    if handle.is_null() {
        return SLOPDESK_REPO_WATCH_STALE;
    }
    // SAFETY: the caller's obligations, restated above; `lent` states its own.
    let verdict = unsafe {
        (*handle)
            .fold
            .debounce_fired(lent(repo, repo_len), generation, has_audience)
    };
    match verdict {
        ProbeVerdict::Stale => SLOPDESK_REPO_WATCH_STALE,
        ProbeVerdict::NoAudience => SLOPDESK_REPO_WATCH_NO_AUDIENCE,
        ProbeVerdict::Deferred => SLOPDESK_REPO_WATCH_DEFERRED,
        ProbeVerdict::Probe => SLOPDESK_REPO_WATCH_PROBE,
    }
}

/// A reading returned. `has_status == false` means the path is not a repository any more, which is
/// not news to push.
///
/// The ten status fields cross flat rather than through a record, because they are scalars and two
/// strings and the caller already holds every one of them as a separate stored property — a record
/// would be a struct definition both languages have to agree about for no fewer bytes.
///
/// # Safety
/// `handle` must be null, or a live fold with no other call on it in flight; `repo`, `repo_root`
/// and `branch` must be null or point to their stated lengths of initialised bytes live for the
/// call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_repo_watch_probe_finished(
    handle: *mut SlopDeskRepoWatch,
    repo: *const c_uchar,
    repo_len: usize,
    has_status: bool,
    repo_root: *const c_uchar,
    repo_root_len: usize,
    branch: *const c_uchar,
    branch_len: usize,
    ahead: i32,
    behind: i32,
    stash_count: i32,
    staged: u32,
    modified: u32,
    untracked: u32,
    conflicted: u32,
    changed_count: u32,
) -> SlopDeskRepoWatchFinish {
    if handle.is_null() {
        return SlopDeskRepoWatchFinish::default();
    }
    // SAFETY: the caller's obligations, restated above; `lent` states its own.
    let verdict = unsafe {
        let status = has_status.then(|| {
            ProjectGitStatus {
                repo_root: lent(repo_root, repo_root_len).to_owned(),
                branch: lent(branch, branch_len).to_owned(),
                ahead,
                behind,
                stash_count,
                staged,
                modified,
                untracked,
                conflicted,
                changed_count,
            }
        });
        (*handle)
            .fold
            .probe_finished(lent(repo, repo_len), status.as_ref())
    };
    SlopDeskRepoWatchFinish {
        push: verdict.push,
        has_rearm: verdict.rearm.is_some(),
        rearm: verdict.rearm.unwrap_or_default(),
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::integer_division,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::{
        SLOPDESK_REPO_WATCH_DEFERRED, SLOPDESK_REPO_WATCH_NO_AUDIENCE, SLOPDESK_REPO_WATCH_PROBE,
        SLOPDESK_REPO_WATCH_STALE, SlopDeskRepoWatch, slopdesk_repo_watch_answer,
        slopdesk_repo_watch_debounce_fired, slopdesk_repo_watch_debounce_seconds,
        slopdesk_repo_watch_drop_owner, slopdesk_repo_watch_free, slopdesk_repo_watch_new,
        slopdesk_repo_watch_note_project_key, slopdesk_repo_watch_probe_finished,
        slopdesk_repo_watch_shutdown, slopdesk_repo_watch_source_event, slopdesk_repo_watch_wants_key,
    };

    /// Drains a mutator's stashed answer the way the Swift caller does: the size the mutator
    /// returned, then one pure read. Asks with a deliberately short buffer first, because a caller
    /// that guessed wrong must still get the same bytes — that is the whole point of the split.
    fn answer(handle: *mut SlopDeskRepoWatch, needed: usize) -> Vec<u8> {
        if needed == 0 {
            return Vec::new();
        }
        let mut stingy = vec![0_u8; 1];
        assert_eq!(
            unsafe { slopdesk_repo_watch_answer(handle, stingy.as_mut_ptr(), stingy.len()) },
            needed,
            "a short read must report the size and write nothing"
        );
        assert_eq!(stingy[0], 0, "a short read must not have written");
        let mut out = vec![0_u8; needed];
        let written = unsafe { slopdesk_repo_watch_answer(handle, out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        out
    }

    /// The Swift `ffiRuns` walk, so the two halves of the framing are exercised together.
    fn runs(blob: &[u8], count: usize) -> Vec<String> {
        let mut walked = Vec::with_capacity(count);
        let mut cursor = 0_usize;
        for _ in 0..count {
            if cursor + 4 > blob.len() {
                break;
            }
            let length = usize::try_from(u32::from_be_bytes([
                blob[cursor],
                blob[cursor + 1],
                blob[cursor + 2],
                blob[cursor + 3],
            ]))
            .unwrap_or(usize::MAX);
            cursor += 4;
            if cursor + length > blob.len() {
                break;
            }
            walked.push(String::from_utf8_lossy(&blob[cursor..cursor + length]).into_owned());
            cursor += length;
        }
        walked
    }

    fn note(handle: *mut SlopDeskRepoWatch, owner: u64, key: &str, is_repo_root: bool) -> Vec<String> {
        let needed = unsafe {
            slopdesk_repo_watch_note_project_key(handle, owner, key.as_ptr(), key.len(), is_repo_root)
        };
        runs(&answer(handle, needed), 2)
    }

    #[test]
    fn the_whole_arc_crosses_the_boundary() {
        let handle = slopdesk_repo_watch_new();
        let repo = "/repo";

        assert!(unsafe { slopdesk_repo_watch_wants_key(handle, 1, repo.as_ptr(), repo.len()) });
        assert_eq!(note(handle, 1, repo, true), vec![
            String::new(),
            "/repo".to_owned()
        ]);
        assert!(!unsafe { slopdesk_repo_watch_wants_key(handle, 1, repo.as_ptr(), repo.len()) });

        let mut generation = 0_u64;
        assert!(unsafe {
            slopdesk_repo_watch_source_event(handle, repo.as_ptr(), repo.len(), &raw mut generation)
        });
        assert_eq!(
            unsafe {
                slopdesk_repo_watch_debounce_fired(handle, repo.as_ptr(), repo.len(), generation, true)
            },
            SLOPDESK_REPO_WATCH_PROBE
        );

        let branch = "main";
        let finish = unsafe {
            slopdesk_repo_watch_probe_finished(
                handle,
                repo.as_ptr(),
                repo.len(),
                true,
                repo.as_ptr(),
                repo.len(),
                branch.as_ptr(),
                branch.len(),
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                1,
            )
        };
        assert!(finish.push);
        assert!(!finish.has_rearm);

        let needed = unsafe { slopdesk_repo_watch_drop_owner(handle, 1) };
        assert_eq!(String::from_utf8_lossy(&answer(handle, needed)), "/repo");
        unsafe { slopdesk_repo_watch_free(handle) };
    }

    /// The re-arm generation survives the crossing — the number a deferred edge comes back with
    /// must be the one the fold armed, or the follow-up reads as stale and the git line stops
    /// updating.
    #[test]
    fn a_deferred_edge_comes_back_with_a_live_generation() {
        let handle = slopdesk_repo_watch_new();
        let repo = "/repo";
        note(handle, 1, repo, true);

        let mut generation = 0_u64;
        unsafe { slopdesk_repo_watch_source_event(handle, repo.as_ptr(), repo.len(), &raw mut generation) };
        unsafe { slopdesk_repo_watch_debounce_fired(handle, repo.as_ptr(), repo.len(), generation, true) };
        unsafe { slopdesk_repo_watch_source_event(handle, repo.as_ptr(), repo.len(), &raw mut generation) };
        assert_eq!(
            unsafe {
                slopdesk_repo_watch_debounce_fired(handle, repo.as_ptr(), repo.len(), generation, true)
            },
            SLOPDESK_REPO_WATCH_DEFERRED
        );

        let finish = unsafe {
            slopdesk_repo_watch_probe_finished(
                handle,
                repo.as_ptr(),
                repo.len(),
                false,
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            )
        };
        assert!(!finish.push, "no repository is not news");
        assert!(finish.has_rearm);
        assert_eq!(
            unsafe {
                slopdesk_repo_watch_debounce_fired(handle, repo.as_ptr(), repo.len(), finish.rearm, true)
            },
            SLOPDESK_REPO_WATCH_PROBE
        );
        unsafe { slopdesk_repo_watch_free(handle) };
    }

    #[test]
    fn shutdown_hands_back_every_stream_and_the_gate_reads_as_a_verdict() {
        let handle = slopdesk_repo_watch_new();
        note(handle, 1, "/repo", true);
        note(handle, 2, "/other", true);

        let mut generation = 0_u64;
        let repo = "/repo";
        unsafe { slopdesk_repo_watch_source_event(handle, repo.as_ptr(), repo.len(), &raw mut generation) };
        assert_eq!(
            unsafe {
                slopdesk_repo_watch_debounce_fired(handle, repo.as_ptr(), repo.len(), generation, false)
            },
            SLOPDESK_REPO_WATCH_NO_AUDIENCE
        );

        let needed = unsafe { slopdesk_repo_watch_shutdown(handle) };
        let blob = answer(handle, needed);
        assert_eq!(runs(&blob, blob.len() / 4), vec![
            "/other".to_owned(),
            "/repo".to_owned()
        ]);
        assert_eq!(note(handle, 3, "/repo", true), vec![String::new(), String::new()]);
        unsafe { slopdesk_repo_watch_free(handle) };
    }

    /// A null handle is an answer at every door rather than a crash, and freeing null is a no-op.
    #[test]
    fn a_null_handle_asks_for_nothing() {
        let repo = "/repo";
        assert!(!unsafe { slopdesk_repo_watch_wants_key(core::ptr::null(), 1, repo.as_ptr(), repo.len()) });
        assert_eq!(
            unsafe {
                slopdesk_repo_watch_debounce_fired(core::ptr::null_mut(), repo.as_ptr(), repo.len(), 1, true)
            },
            SLOPDESK_REPO_WATCH_STALE
        );
        assert_eq!(unsafe { slopdesk_repo_watch_shutdown(core::ptr::null_mut()) }, 0);
        assert_eq!(
            unsafe { slopdesk_repo_watch_answer(core::ptr::null(), core::ptr::null_mut(), 0) },
            0
        );
        unsafe { slopdesk_repo_watch_free(core::ptr::null_mut()) };
        assert!(slopdesk_repo_watch_debounce_seconds() > 0.0);
    }
}
