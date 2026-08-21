//! Where superd listens, in C — `Sources/SlopDeskSupervisor/SupervisorPaths.swift`.
//!
//! The rule is [`slopdesk_superwire::control_socket_path`]; what is here is the marshalling.
//!
//! ## The same bug as [`crate::screen_paths`], one rung worse
//!
//! superd's control socket is the one address hostd cannot be told, because it is the address hostd
//! says `hello` TO. So both ends resolved it, and the Swift note above the copy made the usual
//! argument: a rendezvous address is "a name, not a policy". The name was shared. The directory the
//! name sits in is a policy, and the two spellings were not the same policy:
//!
//! ```text
//! superd   $SLOPDESK_SUPERD_SOCKET → $SLOPDESK_SUPERD_DIR → $TMPDIR → /tmp
//! hostd    $SLOPDESK_SUPERD_SOCKET → NSTemporaryDirectory()
//! ```
//!
//! Two divergences, not one. `NSTemporaryDirectory()` on Darwin ignores `$TMPDIR` and answers
//! `confstr(_CS_DARWIN_USER_TEMP_DIR)`, so a process with a `TMPDIR` of its own had superd binding
//! one path and hostd dialling another — measured, not reasoned. And hostd had never heard of
//! `SLOPDESK_SUPERD_DIR` at all, so the gate script's private daemon was reachable by nothing. Both
//! cancel only in the case anyone exercises: launchd sets `TMPDIR` to exactly the directory that
//! call returns, and the test fixtures set the outright override.
//!
//! ## Why the environment is READ on the near side
//!
//! Same reason as `screen_paths`: `SupervisorPaths.controlSocket(environment:)` takes its
//! environment as a parameter and its tests pass dictionaries in. Three dictionary reads stay
//! there; the precedence, the emptiness filter and the last-resort directory are all over here.

use core::ffi::c_uchar;

use slopdesk_superwire::control_socket_path;

use crate::{borrow, deliver};

/// superd's control socket, given what the caller's environment holds for the three variables that
/// decide it.
///
/// Any pair may be `(NULL, 0)`, and an EMPTY pair is the same answer as an absent one — an
/// exported-but-blank variable is a shell accident, not a request to bind nothing. A pair that is
/// not UTF-8 is also read as unset, which is not a shrug: superd resolves the same variables with
/// `std::env::var`, and that answers `Err(NotUnicode)` for exactly those bytes. Landing on the
/// fallback together is the point; dialling a lossily-mangled path would be the bug this door
/// exists to close.
///
/// The answer is always non-empty, so a `0` return cannot happen and nothing reads it as a
/// sentinel; a return larger than `cap` means nothing was written — ask again at that size.
///
/// # Safety
/// Each `(ptr, len)` input must be readable for its length, and `(out, cap)` writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every buffer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_supervisor_control_socket(
    socket_override: *const c_uchar,
    socket_override_len: usize,
    directory: *const c_uchar,
    directory_len: usize,
    tmpdir: *const c_uchar,
    tmpdir_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's contract, one pair at a time.
    let (over, dir, temp) = unsafe {
        (
            borrow(socket_override, socket_override_len),
            borrow(directory, directory_len),
            borrow(tmpdir, tmpdir_len),
        )
    };
    let text = |bytes| core::str::from_utf8(bytes).unwrap_or("");
    let path = control_socket_path(Some(text(over)), Some(text(dir)), Some(text(temp)));
    // SAFETY: the caller's contract.
    unsafe { deliver(path.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::slopdesk_supervisor_control_socket;

    fn address(socket_override: &str, directory: &str, tmpdir: &str) -> String {
        let mut buffer = [0_u8; 128];
        // SAFETY: every pair is a live local.
        let needed = unsafe {
            slopdesk_supervisor_control_socket(
                socket_override.as_ptr(),
                socket_override.len(),
                directory.as_ptr(),
                directory.len(),
                tmpdir.as_ptr(),
                tmpdir.len(),
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        let Some(bytes) = buffer.get(..needed) else {
            return String::new();
        };
        String::from_utf8_lossy(bytes).into_owned()
    }

    #[test]
    fn the_door_carries_the_whole_ladder_rather_than_half_of_it() {
        assert_eq!(address("/run/private.sock", "/d", "/tmp/x"), "/run/private.sock");
        assert_eq!(address("", "/d", "/tmp/x"), "/d/slopdesk-superd.sock");
        assert_eq!(address("", "", "/tmp/x"), "/tmp/x/slopdesk-superd.sock");
        assert_eq!(address("", "", ""), "/tmp/slopdesk-superd.sock");
    }

    /// The two rungs the near side got wrong: a `TMPDIR` it ignored outright, and a directory
    /// override it had never heard of. Both now reach hostd.
    #[test]
    fn the_two_rungs_swift_answered_differently_now_cross() {
        assert_eq!(
            address("", "", "/var/folders/zz/T"),
            "/var/folders/zz/T/slopdesk-superd.sock"
        );
        assert_eq!(
            address("", "/tmp/gate-superd", ""),
            "/tmp/gate-superd/slopdesk-superd.sock"
        );
    }

    /// Non-UTF-8 is unset, because `std::env::var` on the daemon's side calls it unset too. Both
    /// ends land on the fallback rather than on two different manglings of the same bytes.
    #[test]
    fn a_directory_that_is_not_text_is_read_as_absent() {
        let invalid = [0xFF_u8, 0xFE];
        let mut buffer = [0_u8; 64];
        // SAFETY: both buffers are live locals.
        let needed = unsafe {
            slopdesk_supervisor_control_socket(
                core::ptr::null(),
                0,
                invalid.as_ptr(),
                invalid.len(),
                core::ptr::null(),
                0,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        assert_eq!(
            buffer.get(..needed).map(String::from_utf8_lossy).as_deref(),
            Some("/tmp/slopdesk-superd.sock")
        );
    }

    #[test]
    fn an_overflow_reports_the_size_it_needs_and_writes_nothing() {
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: the buffer is a live local and every input pair is empty.
        let needed = unsafe {
            slopdesk_supervisor_control_socket(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert_eq!(needed, "/tmp/slopdesk-superd.sock".len());
        assert_eq!(tiny, [0xAA; 4], "an overflow leaves the caller's buffer alone");
    }
}
