//! What is running in one terminal pane — the metadata RPC's three pane-anchored verbs.
//!
//! `rust/slopdesk-panecensus` answers all three; these are the doors and hold no decision. Which
//! pid's cwd wins, what a process is called, which of the machine's processes belong to this pane,
//! how `lsof`'s field output becomes a port — every one of those is that crate's, under
//! `forbid(unsafe_code)`.
//!
//! ## What this replaced
//! `Sources/SlopDeskHost/HostMetadataProbe.swift`'s OS half: `proc_listpids` over every live pid,
//! `proc_pidinfo` per pid, `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the cwd, `ptsname` + `stat`
//! for the pane's device number, a `Foundation.Process` running `lsof` with its own
//! drain-before-wait loop, and a hand-rolled field-format parser. That file carried a standing note
//! that it was compiled and code-reviewed ONLY, never unit-tested, because every one of those needs
//! a live PTY and a real subprocess. Behind these doors the parse is a function over a string.
//!
//! ## Two of the three answer ENCODED bytes
//! For [`crate::git_status`]' reason: hostd's responder forwards a process list and a port list to
//! the client verbatim, so unpacking them here would only mean packing them again there. The
//! working directory is the exception because hostd genuinely uses it — it is the confinement root
//! every path-carrying verb is checked against.
//!
//! ## macOS only
//! Every reading behind these is a Darwin `proc_*` call or `lsof`, and the only caller is hostd.
//! The `cfg` in `lib.rs`, the `TARGET_OS_OSX` guard in `slopdesk_ffi.h` and the `MACOS-ONLY` region
//! `scripts/build-ffi.sh` reads out of that header are the three spellings that keep it true —
//! `docs/57` §3.

use core::ffi::c_uchar;

use crate::deliver;

/// The pane's working directory — the foreground group leader's, or `shell_pid`'s when the terminal
/// has no foreground group.
///
/// `0` — §4's `Option::None` — when neither resolves. That is not a degraded answer the caller may
/// paper over: every path-carrying metadata verb refuses outright on it, because a request confined
/// against a GUESSED root is a request confined against the wrong directory.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_working_directory(
    master_fd: i32,
    shell_pid: i32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(directory) = slopdesk_panecensus::working_directory(master_fd, shell_pid) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(directory.as_bytes(), out, cap) }
}

/// The pane's processes, already encoded as the metadata reply's own payload — the layout
/// `slopdesk_metadata_decode_process_list` reads.
///
/// `now_unix` is the CALLER's clock so the whole census shares one instant. Reading it here instead
/// would be a smaller signature and a worse answer: two processes started in the same second would
/// show different ages, because each row's `now` would be a few microseconds later than the last.
///
/// Never `0`: a pane whose PTY is gone encodes an EMPTY list, which is a valid answer the client
/// already renders. There is no "could not census" reply, because there is nothing a caller would
/// do differently with one.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_process_list(
    master_fd: i32,
    now_unix: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&slopdesk_panecensus::process_list(master_fd, now_unix), out, cap) }
}

/// The ports the pane's processes are listening on, already encoded as the metadata reply's own
/// payload — the layout `slopdesk_metadata_decode_port_list` reads.
///
/// Never `0`, for [`slopdesk_pane_process_list`]'s reason. An empty list is the COMMON answer here,
/// not an edge case: most panes are listening on nothing, and the client says so.
///
/// This is the one door in the file that spawns. It runs `lsof` twice — TCP with `-sTCP:LISTEN`,
/// then UDP, which cannot take that flag — scoped to the pane's own pids, through the same bounded
/// drain-before-wait capture the forked probe uses.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_port_list(master_fd: i32, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&slopdesk_panecensus::port_list(master_fd), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{slopdesk_pane_port_list, slopdesk_pane_process_list, slopdesk_pane_working_directory};

    /// A descriptor that is not a PTY has no pane behind it. The two list doors must still answer
    /// an ENCODED empty list rather than `0`: `0` means "no answer", and a caller reading it as one
    /// would reply `.error` to a request whose honest answer is "nothing is running here".
    #[test]
    fn a_descriptor_that_is_not_a_pty_answers_an_empty_list_rather_than_nothing() {
        let mut out = [0u8; 64];
        // SAFETY: `out` is a live local, writable for its own length for each call.
        unsafe {
            assert_eq!(
                slopdesk_pane_process_list(-1, 1_000, out.as_mut_ptr(), out.len()),
                2
            );
            assert_eq!(out.get(..2), Some([0x00, 0x00].as_slice()));
            assert_eq!(slopdesk_pane_port_list(-1, out.as_mut_ptr(), out.len()), 2);
            assert_eq!(out.get(..2), Some([0x00, 0x00].as_slice()));
        }
    }

    /// The cwd door is the one that DOES answer nothing, and must, because its caller refuses the
    /// request rather than confining a path against a directory it had to guess.
    #[test]
    fn a_pane_with_no_resolvable_root_answers_nothing() {
        let mut out = [0u8; 64];
        // SAFETY: `out` is a live local, writable for its own length for the call.
        assert_eq!(
            unsafe { slopdesk_pane_working_directory(-1, 0, out.as_mut_ptr(), out.len()) },
            0
        );
    }

    /// The cwd door answers for a REAL pid, and answers the directory this process is actually in
    /// — the shell-pid fallback arm, which is the one production takes between commands.
    #[test]
    fn the_shell_pid_fallback_answers_that_processs_own_directory() {
        let mut out = [0u8; 4096];
        let own = i32::try_from(std::process::id()).unwrap_or(-1);
        // SAFETY: `out` is a live local, writable for its own length for the call.
        let needed = unsafe { slopdesk_pane_working_directory(-1, own, out.as_mut_ptr(), out.len()) };
        assert!(needed > 0 && needed <= out.len(), "needed {needed}");
        let read = String::from_utf8_lossy(out.get(..needed).unwrap_or_default()).into_owned();
        let expected = std::env::current_dir().unwrap_or_default();
        assert_eq!(
            std::fs::canonicalize(&read).ok(),
            std::fs::canonicalize(&expected).ok(),
            "the door must answer the directory std reports"
        );
    }

    /// A null buffer is SIZED rather than written through — the two-call shape of §4, which every
    /// caller here depends on because a process list's length is unknowable in advance.
    #[test]
    fn a_null_buffer_is_sized_rather_than_written_through() {
        // SAFETY: null is one of the two shapes each door documents.
        unsafe {
            assert_eq!(slopdesk_pane_process_list(-1, 0, core::ptr::null_mut(), 0), 2);
            assert_eq!(slopdesk_pane_port_list(-1, core::ptr::null_mut(), 0), 2);
        }
    }
}
