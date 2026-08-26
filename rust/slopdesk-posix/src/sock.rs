//! Socket options `nix` does not wrap for a bare descriptor.

use std::os::fd::RawFd;

/// Widens a socket's send AND receive buffers to `bytes`.
///
/// Best-effort on purpose: a kernel that refuses the size keeps its own and every protocol above
/// stays correct — this buys headroom on a byte path, it does not carry a guarantee. Both
/// directions, because callers use both.
///
/// The reason it is ever needed: `AF_UNIX` defaults to 8 KB on macOS where TCP gets 128 KB, so a
/// single 32 KiB output frame does not fit and the writer parks mid-frame the instant its reader is
/// a beat behind.
#[expect(unsafe_code, reason = "SO_SNDBUF has no nix wrapper taking a bare RawFd")]
pub fn widen_buffers(socket: RawFd, bytes: libc::c_int) {
    let size = bytes;
    let length = u32::try_from(size_of::<libc::c_int>()).unwrap_or(4);
    for option in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
        // SAFETY: `size` outlives the call and is exactly `length` bytes wide, which is the pair
        // `setsockopt` requires; a closed or non-socket descriptor is answered with an errno.
        let _ignored = unsafe {
            libc::setsockopt(
                socket,
                libc::SOL_SOCKET,
                option,
                (&raw const size).cast::<libc::c_void>(),
                length,
            )
        };
    }
}

/// Turns a write to a hung-up peer into `EPIPE` instead of a signal.
///
/// Darwin has no `MSG_NOSIGNAL`, so the only way to say this is per-socket and at setup time. It is
/// needed wherever a descriptor is written to by a thread that did not create it and may not know
/// the peer has gone — an accepted connection held in a table, above all.
///
/// It is not made redundant by the Rust runtime's `SIG_IGN`. That disposition is installed by the
/// `main` shim, and a crate LINKED INTO a foreign process — every `.xcframework` this repo ships,
/// and hostd until the stage F cutover — never runs one. In such a process `SIGPIPE` still has its
/// default disposition, and one write to a departed workbench window would end the host.
///
/// Best-effort, like [`widen_buffers`]: a descriptor that is not a socket is answered with an errno
/// and ignored, because every caller treats this as setup rather than as a precondition.
#[expect(unsafe_code, reason = "SO_NOSIGPIPE has no nix wrapper taking a bare RawFd")]
pub fn set_nosigpipe(socket: RawFd) {
    let on: libc::c_int = 1;
    let length = u32::try_from(size_of::<libc::c_int>()).unwrap_or(4);
    // SAFETY: `on` outlives the call and is exactly `length` bytes wide, which is the pair
    // `setsockopt` requires; a closed or non-socket descriptor is answered with an errno.
    let _ignored = unsafe {
        libc::setsockopt(
            socket,
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&raw const on).cast::<libc::c_void>(),
            length,
        )
    };
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::os::fd::AsRawFd as _;
    use std::os::unix::net::UnixStream;

    use super::{set_nosigpipe, widen_buffers};

    /// Reads one `SOL_SOCKET` integer option back, so the tests below assert on the KERNEL's answer
    /// rather than on the call having returned.
    #[expect(unsafe_code, reason = "the read-back half of the setter under test")]
    fn socket_flag(socket: std::os::fd::RawFd, option: libc::c_int) -> Option<libc::c_int> {
        let mut value: libc::c_int = 0;
        let mut length = u32::try_from(size_of::<libc::c_int>()).unwrap_or(4);
        // SAFETY: `value` and `length` outlive the call, and `length` names `value`'s real width —
        // the pair `getsockopt` requires. A non-socket descriptor is answered with an errno.
        let read = unsafe {
            libc::getsockopt(
                socket,
                libc::SOL_SOCKET,
                option,
                (&raw mut value).cast::<libc::c_void>(),
                &raw mut length,
            )
        };
        (read == 0).then_some(value)
    }

    /// The buffer really grows — a call that silently did nothing would leave the writer parking
    /// mid-frame with every test still green.
    #[test]
    fn widening_raises_the_send_buffer() {
        let (left, _right) = UnixStream::pair().unwrap();
        let before = nix::sys::socket::getsockopt(&left, nix::sys::socket::sockopt::SndBuf).unwrap();
        widen_buffers(left.as_raw_fd(), 256 * 1024);
        let after = nix::sys::socket::getsockopt(&left, nix::sys::socket::sockopt::SndBuf).unwrap();
        assert!(after > before, "{before} -> {after}");
    }

    /// Best-effort means best-effort: a descriptor that is not a socket must not panic or abort,
    /// because the callers treat this as advice and carry on.
    #[test]
    fn a_non_socket_descriptor_is_ignored() {
        let file = std::fs::File::open("/dev/null").unwrap();
        widen_buffers(file.as_raw_fd(), 256 * 1024);
    }

    /// The flag really lands. A no-op setter would leave every test green and end the host the
    /// first time a workbench window closed while a line was being written to it.
    #[test]
    fn a_socket_stops_raising_the_signal() {
        let (left, _right) = UnixStream::pair().unwrap();
        assert_eq!(socket_flag(left.as_raw_fd(), libc::SO_NOSIGPIPE), Some(0));
        set_nosigpipe(left.as_raw_fd());
        assert_ne!(socket_flag(left.as_raw_fd(), libc::SO_NOSIGPIPE), Some(0));
    }

    /// The same tolerance the widener has, for the same reason: callers call this at setup and
    /// carry on.
    #[test]
    fn a_non_socket_descriptor_raises_nothing_either() {
        let file = std::fs::File::open("/dev/null").unwrap();
        set_nosigpipe(file.as_raw_fd());
    }
}
