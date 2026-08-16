//! Process-wide signal dispositions, for the ones `nix` cannot state safely.

/// Makes `SIGPIPE` non-fatal for the whole process.
///
/// Rust's runtime already sets `SIG_IGN` before `main`, so this is usually a no-op — and it is
/// worth one syscall anyway. A daemon whose entire promise is that it outlives its clients should
/// not rest that promise on an implementation detail of the standard library's startup, and a write
/// to a socket whose peer has just gone is the single most ordinary event in its life.
///
/// Call before any thread exists: a disposition is process-wide, and setting one while other
/// threads are running is a race about which of them sees which.
#[expect(unsafe_code, reason = "signal(2) has no safe wrapper for SIG_IGN")]
pub fn ignore_sigpipe() {
    // SAFETY: `SIG_IGN` is a valid disposition for SIGPIPE, and the documented contract above is
    // that no other thread exists yet, so there is nothing to race with.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
}
