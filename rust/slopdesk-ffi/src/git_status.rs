//! The repository behind a pane's cwd, read IN PROCESS — the one door that opens a file on disk.
//!
//! `rust/slopdesk-git` owns every question and the answer's encoding. This is the door.
//!
//! ## macOS only, on purpose
//!
//! Behind this door is `libgit2`, vendored and compiled — a C library the size of the rest of this
//! archive put together. Only hostd asks the question: a client, on either platform, receives the
//! answer as a metadata reply and never computes it, so building the library into the two iOS
//! slices would cost every phone build the compile and every phone archive the bytes, for a door
//! nothing on that platform can reach. The `cfg` here, the `TARGET_OS_OSX` guard in
//! `slopdesk_ffi.h`, and the macOS-only region `scripts/build-ffi.sh` reads out of that header are
//! three spellings of this one fact, and the script fails if the library and the header disagree
//! about it on ANY slice.
//!
//! ## The answer crosses ENCODED
//!
//! Not as a record and an arena, which is what every payload in [`crate::metadata`] does. Those
//! doors exist to let Swift build or inspect a payload field by field; this one produces a payload
//! that hostd's responder forwards VERBATIM, so the fields would be unpacked on one side of the
//! call and packed again on the other. The watcher that does need the fields already has
//! `MetadataCodec.decodeGitStatus`, which is the same decoder every client runs.

use core::ffi::c_uchar;

use crate::{borrow, deliver};

/// The git status of `path`'s repository, as the metadata reply's own payload bytes.
///
/// Answers the one-byte "no repository" payload for a path outside a repository, for an
/// unreadable one, and for a repository that vanished mid-answer — the same degraded rendering the
/// missing-binary case has always produced. `0` means only that `path` was not UTF-8.
///
/// # Safety
/// `path` must be null or point to `len` initialised bytes live for the call; `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_git_status(
    path: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow`/`deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(path, len)) else {
            return 0;
        };
        deliver(&slopdesk_git::encoded_of_path(text), out, cap)
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the door is the point"
)]
mod tests {
    use slopdesk_wire::metadata::decode_git_status;

    use super::slopdesk_git_status;

    /// The door, against the repository this crate lives in — the one repository a test can be sure
    /// exists. It asserts the SHAPE rather than any field's value, because the fields are whatever
    /// the working tree happens to be when the suite runs.
    #[test]
    fn the_door_answers_a_payload_the_wire_decoder_reads() {
        let path = env!("CARGO_MANIFEST_DIR").as_bytes();
        // SAFETY: `path` is a live slice for the call, and the output is asked for by length first.
        let needed = unsafe { slopdesk_git_status(path.as_ptr(), path.len(), core::ptr::null_mut(), 0) };
        assert!(needed > 0, "this crate lives in a repository");
        let mut room = vec![0_u8; needed];
        // SAFETY: as above, with a buffer of exactly the length just asked for.
        let written =
            unsafe { slopdesk_git_status(path.as_ptr(), path.len(), room.as_mut_ptr(), room.len()) };
        assert_eq!(written, needed);
        let status = decode_git_status(&room).expect("the door emits what the wire decoder reads");
        assert!(status.has_repo);
        assert!(!status.repo_root.is_empty(), "a worktree has a toplevel");
    }

    /// The §4 convention: an undersized buffer writes NOTHING and reports what it needed.
    #[test]
    fn an_undersized_buffer_is_told_the_length_and_given_no_bytes() {
        let path = env!("CARGO_MANIFEST_DIR").as_bytes();
        let mut room = [0xAA_u8; 2];
        // SAFETY: a live path and a two-byte output buffer, which is smaller than any real answer.
        let needed = unsafe { slopdesk_git_status(path.as_ptr(), path.len(), room.as_mut_ptr(), room.len()) };
        assert!(needed > room.len());
        assert_eq!(room, [0xAA, 0xAA], "nothing was written");
    }

    /// A path that is not UTF-8 is the ONE case that answers `0`. Everything else — no repository,
    /// an unreadable one, one that vanished — is the one-byte "no repo" payload, which is an
    /// answer.
    #[test]
    fn a_non_utf8_path_is_the_only_zero() {
        let path = [0xFF_u8, 0xFE];
        // SAFETY: a live two-byte slice and no output buffer.
        let needed = unsafe { slopdesk_git_status(path.as_ptr(), path.len(), core::ptr::null_mut(), 0) };
        assert_eq!(needed, 0);

        let outside = b"/";
        // SAFETY: a live slice for the call; `/` is a real path in no repository.
        let root = unsafe { slopdesk_git_status(outside.as_ptr(), outside.len(), core::ptr::null_mut(), 0) };
        assert_eq!(root, 1, "no repo is a one-byte answer, not an absent one");
    }
}
