//! Where screend listens, in C — `Sources/SlopDeskScreen/ScreenPaths.swift`.
//!
//! The rule is [`slopdesk_screenwire::socket_path`]; what is here is the marshalling.
//!
//! ## Why an address needed a door at all
//!
//! Because a rendezvous address is the one part of a protocol that cannot be negotiated — the
//! client has to FIND the socket before it can say `hello`, so there is no message in which the
//! daemon could tell it — and both sides had therefore written the resolution out. The Swift note
//! above the copy argued that this was safe: "a rendezvous address cannot be learned from the thing
//! it addresses, so the two ends necessarily agree on it by construction. This is a name, not a
//! policy."
//!
//! Half of that was true. The NAME is shared by construction. Which DIRECTORY the name sits in is a
//! policy, it was written twice, and the two spellings were not the same policy:
//!
//! ```text
//! screend      $SLOPDESK_SCREEND_SOCKET → $TMPDIR/… → /tmp/…
//! the client   $SLOPDESK_SCREEND_SOCKET → NSTemporaryDirectory()/…
//! ```
//!
//! and on Darwin `NSTemporaryDirectory()` does not read `$TMPDIR` at all — it answers
//! `confstr(_CS_DARWIN_USER_TEMP_DIR)` whatever the environment holds. Measured, not reasoned: a
//! process with `TMPDIR=/tmp/anything` still gets `/var/folders/…/T/` out of it. So every process
//! whose `TMPDIR` was not the per-user directory that call returns had a daemon binding one path
//! and a client dialling another, with nothing on either side able to say so — the daemon simply
//! looked like it was not running. The pair agreed in practice only because launchd sets `TMPDIR`
//! to exactly the directory `confstr` answers, and the test fixture sets the override, so both of
//! the paths anyone exercised were the two where the disagreement cancels.
//!
//! ## Why the environment is READ on the near side
//!
//! The crate could have called `std::env::var_os` itself and taken no arguments. It does not,
//! because `ScreenPaths.requestSocket(environment:)` takes its environment as a parameter and its
//! tests pass dictionaries in — a door that read the real process environment would make every one
//! of those tests untestable, and testability of the resolution is most of what the port is worth.
//! The lookup is two dictionary reads; the RULE, which is the precedence and the emptiness filter
//! and the fallback, is all on the far side.

use core::ffi::c_uchar;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;

use slopdesk_screenwire::socket_path;

use crate::{borrow, deliver};

/// screend's request socket, given what the caller's environment holds for the two variables that
/// decide it.
///
/// Either pair may be `(NULL, 0)`, and an EMPTY pair is the same answer as an absent one — an
/// exported-but-blank variable is a shell accident, not a request to bind nothing. That is why
/// neither input carries the presence flag `crate::panel_key`'s text pairs do: there, absent and
/// empty mean different things, and here they do not.
///
/// The answer is always non-empty, so a `0` return cannot happen and nothing reads it as a
/// sentinel; a return larger than `cap` means nothing was written — ask again at that size.
///
/// # Safety
/// `(socket_override, socket_override_len)` and `(tmpdir, tmpdir_len)` must be readable for their
/// lengths, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and all three buffers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_screen_socket_path(
    socket_override: *const c_uchar,
    socket_override_len: usize,
    tmpdir: *const c_uchar,
    tmpdir_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's contract, one pair at a time.
    let (over, temp) = unsafe {
        (
            borrow(socket_override, socket_override_len),
            borrow(tmpdir, tmpdir_len),
        )
    };
    let path = socket_path(Some(OsStr::from_bytes(over)), Some(OsStr::from_bytes(temp)));
    // SAFETY: the caller's contract.
    unsafe { deliver(path.as_os_str().as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::slopdesk_screen_socket_path;

    fn address(socket_override: &str, tmpdir: &str) -> String {
        let mut buffer = [0_u8; 128];
        // SAFETY: every pair is a live local.
        let needed = unsafe {
            slopdesk_screen_socket_path(
                socket_override.as_ptr(),
                socket_override.len(),
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
        assert_eq!(address("/run/private.sock", "/tmp/x"), "/run/private.sock");
        assert_eq!(address("", "/tmp/x"), "/tmp/x/slopdesk-screend.sock");
        assert_eq!(address("", ""), "/tmp/slopdesk-screend.sock");
    }

    /// The case the near side used to answer differently: a `TMPDIR` that is not the per-user
    /// directory `NSTemporaryDirectory()` returns. The client now lands where the daemon binds.
    #[test]
    fn a_tmpdir_the_caller_chose_is_honoured_rather_than_ignored() {
        assert_eq!(
            address("", "/var/folders/zz/T"),
            "/var/folders/zz/T/slopdesk-screend.sock"
        );
    }

    #[test]
    fn an_overflow_reports_the_size_it_needs_and_writes_nothing() {
        let tiny_source = "";
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: the buffer and the empty pairs are live locals.
        let needed = unsafe {
            slopdesk_screen_socket_path(
                tiny_source.as_ptr(),
                0,
                tiny_source.as_ptr(),
                0,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert_eq!(needed, "/tmp/slopdesk-screend.sock".len());
        assert_eq!(tiny, [0xAA; 4], "an overflow leaves the caller's buffer alone");
    }
}
