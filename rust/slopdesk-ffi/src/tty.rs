//! The LOCAL terminal's doors — raw mode, its restore, its size, and the byte-mover under it.
//!
//! `rust/slopdesk-posix`'s [`rawmode`](slopdesk_posix::rawmode) and
//! [`fdio`](slopdesk_posix::fdio) hold the syscalls and every obligation around them; this is the
//! door and holds no decision. Even the flattening of a transfer outcome into one integer is
//! `slopdesk-posix`'s — [`Transfer::code`](slopdesk_posix::fdio::Transfer::code) — because what a
//! caller that cannot see the enum is TOLD is a choice, and this file makes none.
//!
//! ## Why two subjects in one module
//! Because they were one Swift target. `Sources/SlopDeskTTY` was "the leaf that owns a raw
//! descriptor on the Swift side": `TerminalRawMode.swift` and `FileDescriptorIO.swift`, the
//! `termios` save/restore and the `write(2)`-until-done loop. Splitting them across two doors files
//! would put the two halves of one deleted target in two places for no gain.
//!
//! ## macOS only
//! `slopdesk-posix` is a `cfg(target_os = "macos")` edge of this crate — an ungated one would drag
//! `fork`/`openpty`/Mach host statistics into an iOS slice that has no use for any of them. So
//! these doors sit inside `slopdesk_ffi.h`'s `MACOS-ONLY` region, which is honest about their
//! audience: the raw-mode trio is `slopdesk-client`'s, a macOS command-line binary, and the local
//! terminal it puts into raw mode is a macOS terminal.
//!
//! ## The door that is deliberately absent
//! [`slopdesk_posix::rawmode::is_raw`] has no door. Nothing on the Swift side ever asked — the CLI
//! enters, restores, and lets the handlers do the rest — and a door nothing calls is a second
//! spelling of the protocol that compiles, tests green, and drifts. The crate function stays for
//! the tests and for a caller that one day has a reason.
//!
//! ## What this replaced
//! `Sources/SlopDeskTTY/TerminalRawMode.swift` (264 lines) and `FileDescriptorIO.swift` (108), and
//! with them the last Swift that spoke `termios` about the machine it runs on.

use core::ffi::c_uchar;

use crate::deliver;

/// Puts a terminal into raw mode, remembering what it looked like. `0` on success, else the errno.
///
/// The saved attributes are not handed back: the only caller restores through
/// [`slopdesk_tty_restore`] and the signal handlers, and a copy on the Swift side would be a second
/// place the truth lives.
///
/// Entering twice is idempotent and keeps the FIRST entry's saved attributes — see
/// [`slopdesk_posix::rawmode::enter`] for why that is not the same as what the Swift did.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_tty_enter_raw(terminal: i32) -> i32 {
    match slopdesk_posix::rawmode::enter(terminal) {
        Ok(_saved) => 0,
        Err(errno) => errno as i32,
    }
}

/// Writes the saved attributes back. Idempotent, and a no-op when raw mode was never entered.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_tty_restore() {
    slopdesk_posix::rawmode::restore();
}

/// Installs the `SIGINT`/`SIGTERM`/`SIGQUIT`/`SIGHUP` handlers that restore the terminal and then
/// die of the signal.
///
/// Call it BEFORE [`slopdesk_tty_enter_raw`]: the handler is a no-op until raw mode is engaged, and
/// installing first closes the window where a signal landing after the raw attributes took effect
/// but before a handler existed would kill the process with the terminal broken.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_tty_install_restore_on_signals() {
    slopdesk_posix::rawmode::restore_on_signals();
}

/// A terminal's window size as EIGHT bytes — `cols`, `rows`, `pxWidth`, `pxHeight`, each a
/// little-endian `uint16`.
///
/// `0` — §4's `Option::None` — when the descriptor is not a terminal, which is exactly what the
/// `nil` the Swift answered meant. Four scalars rather than four doors because they are read
/// together on every resize and a torn pair would send the host a geometry that never existed.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_tty_window_size(terminal: i32, out: *mut c_uchar, cap: usize) -> usize {
    let Ok(size) = slopdesk_posix::pty::window_size(terminal) else {
        return 0;
    };
    let mut answer = [0_u8; 8];
    let (slots, _remainder) = answer.as_chunks_mut::<2>();
    for (slot, value) in slots
        .iter_mut()
        .zip([size.ws_col, size.ws_row, size.ws_xpixel, size.ws_ypixel])
    {
        *slot = value.to_le_bytes();
    }
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

/// `write(2)` until the whole of `(bytes, len)` is out.
///
/// `0` every byte moved · `-1` the peer closed still owing bytes · otherwise the positive errno.
/// The REACTION stays with the caller, which is the whole reason the three answers are kept apart:
/// a control reply to a client that has gone is dropped, and a frame half-written is reported.
///
/// # Safety
/// `bytes` must be null, or point to `len` initialised bytes that stay live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_fd_write_all(fd: i32, bytes: *const c_uchar, len: usize) -> i32 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let payload = unsafe { crate::borrow(bytes, len) };
    slopdesk_posix::fdio::write_all(fd, payload).code()
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::io::Read as _;
    use std::os::fd::AsRawFd as _;
    use std::os::unix::net::UnixStream;

    use super::{
        slopdesk_fd_write_all, slopdesk_tty_enter_raw, slopdesk_tty_restore, slopdesk_tty_window_size,
    };

    /// A descriptor that is not a terminal answers nothing rather than a zeroed size a caller would
    /// go on to send as a resize.
    #[test]
    fn a_non_terminal_has_no_window_size() {
        let (left, _right) = UnixStream::pair().unwrap();
        let mut out = [0_u8; 8];
        // SAFETY: `out` is a live local, writable for its own length for the call.
        assert_eq!(
            unsafe { slopdesk_tty_window_size(left.as_raw_fd(), out.as_mut_ptr(), out.len()) },
            0
        );
    }

    /// A null buffer is SIZED rather than written through — the two-call shape of §4.
    #[test]
    fn a_null_buffer_is_sized_rather_than_written_through() {
        // SAFETY: null is one of the two shapes the door documents.
        assert_eq!(
            unsafe { slopdesk_tty_window_size(-1, core::ptr::null_mut(), 0) },
            0
        );
    }

    /// Raw mode on something that is not a terminal is refused with `ENOTTY`, and the flag stays
    /// down — a door that reported success here would leave the CLI believing it had to restore a
    /// terminal it never touched.
    #[test]
    fn entering_raw_mode_on_a_socket_is_refused() {
        let (left, _right) = UnixStream::pair().unwrap();
        // Differential against the crate under the door: the integer that crosses IS the errno the
        // syscall answered, not a code this file invented.
        let refusal = slopdesk_posix::rawmode::attributes(left.as_raw_fd())
            .err()
            .map_or(0, |errno| errno as i32);
        assert!(refusal > 0, "a socket is not a terminal");
        assert_eq!(slopdesk_tty_enter_raw(left.as_raw_fd()), refusal);
        assert!(!slopdesk_posix::rawmode::is_raw());
        slopdesk_tty_restore();
        assert!(!slopdesk_posix::rawmode::is_raw());
    }

    /// The write door moves every byte and says so with `0`.
    #[test]
    fn the_write_door_moves_the_whole_buffer() {
        let (mut left, right) = UnixStream::pair().unwrap();
        let payload = b"{\"id\":\"1\",\"ok\":true}\n";
        // SAFETY: `payload` is a live local, initialised for its own length for the call.
        let code = unsafe { slopdesk_fd_write_all(right.as_raw_fd(), payload.as_ptr(), payload.len()) };
        assert_eq!(code, 0);
        drop(right);

        let mut received = Vec::new();
        left.read_to_end(&mut received).unwrap();
        assert_eq!(received, payload);
    }

    /// A null pair is an empty write, which is complete — the same reading every other door here
    /// gives an absent `(ptr, len)`.
    #[test]
    fn a_null_payload_is_an_empty_write() {
        // SAFETY: null is one of the two shapes `borrow` documents.
        assert_eq!(unsafe { slopdesk_fd_write_all(-1, core::ptr::null(), 0) }, 0);
    }

    /// A descriptor that cannot be written to answers its errno, positive and distinguishable from
    /// both the complete and peer-closed sentinels.
    #[test]
    fn a_bad_descriptor_answers_a_positive_errno() {
        let payload = b"x";
        // SAFETY: `payload` is a live local, initialised for its own length for the call.
        let code = unsafe { slopdesk_fd_write_all(-1, payload.as_ptr(), payload.len()) };
        let expected = slopdesk_posix::fdio::write_all(-1, payload).code();
        assert!(expected > 0, "an errno must not collide with either sentinel");
        assert_eq!(code, expected);
    }
}
