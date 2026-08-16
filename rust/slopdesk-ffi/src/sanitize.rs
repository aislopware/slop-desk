//! The scrollback REPLAY transform, in C.
//!
//! One entry point over [`slopdesk_sanitize::sanitize`], under the crate's pure convention: bytes
//! in, bytes out, nothing remembered. The replay handle calls the same function internally on a
//! cold reattach; this exists for the caller's OTHER user of it — the detached-window backlog,
//! which is compacted outside the ring.
//!
//! It replaces a socket. The transform was a screend verb, so reaching it meant an `AF_UNIX` round
//! trip carrying the whole retained history in each direction, and an absent daemon meant the
//! history replayed RAW — which is not merely uglier: raw history can transiently arm a client's
//! input reporting until the shell's next prompt. A pure function has no lifetime that wants a
//! daemon, so it is linked, and the degraded path stopped existing.

use core::ffi::c_uchar;

use slopdesk_sanitize::{Options, inputmode, plaintext, sanitize};

use crate::{borrow, deliver};

/// The replay transform's answer, under §4's convention.
///
/// `distill` selects the line-editor collapse — the one pass a caller may decline. The other six
/// always run. `reassert_input_modes` re-appends the stream's NET final input-mode state after the
/// passes: the live ring wants it, so a session still inside a TUI keeps that TUI's modes across a
/// cold reattach, and the disk journal must not, because after a daemon restart there is no TUI to
/// serve.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_sanitize(
    bytes: *const c_uchar,
    len: usize,
    distill: bool,
    reassert_input_modes: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let input = unsafe { borrow(bytes, len) };
    let answer = sanitize(input, Options {
        distill,
        reassert_input_modes,
    });
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

/// PTY bytes as the plain text a pattern is matched against.
///
/// Not the replay transform. That one keeps a faithful terminal stream and removes only churn;
/// this removes every sequence and every private-use glyph, because the caller is a regex and a
/// pane's text is all it wants.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_plaintext_strip(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe { deliver(&plaintext::strip(borrow(bytes, len)), out, cap) }
}

/// Where a chunk's trailing INCOMPLETE sequence begins, so a caller feeding one chunk at a time can
/// hold that tail back until its continuation arrives.
///
/// `len` means nothing is held. The same grammar [`slopdesk_plaintext_strip`] reads, asked the
/// other way — the two used to be hand-rolled Swift machines whose doc comments promised each other
/// they matched.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_plaintext_holdback(bytes: *const c_uchar, len: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    unsafe { plaintext::holdback_start(borrow(bytes, len)) }
}

/// The bytes that put a terminal back to a known-quiet input state.
///
/// The backstop a restore appends when the passes did not run — a raw journal tail, or a run with
/// the transform disabled. Built from the same array [`slopdesk_sanitize`] strips by, so a mode
/// added there cannot be silently missing here.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_input_mode_reset(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&inputmode::reset_suffix(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{
        slopdesk_input_mode_reset, slopdesk_plaintext_holdback, slopdesk_plaintext_strip, slopdesk_sanitize,
    };

    /// The passes run, and the answer fits the convention: a closed alt-screen segment is dropped
    /// and the history either side of it survives.
    #[test]
    fn a_closed_segment_is_stripped_and_its_neighbours_are_not() {
        let mut raw = b"before\n".to_vec();
        raw.extend_from_slice(b"\x1b[?1049h");
        raw.extend_from_slice(b"a whole TUI redrawing itself\n");
        raw.extend_from_slice(b"\x1b[?1049l");
        raw.extend_from_slice(b"after\n");
        let mut out = [0_u8; 256];
        // SAFETY: both buffers are live locals.
        let written =
            unsafe { slopdesk_sanitize(raw.as_ptr(), raw.len(), true, false, out.as_mut_ptr(), out.len()) };
        let text = String::from_utf8_lossy(out.get(..written).unwrap_or(&[])).into_owned();
        assert!(text.contains("before"), "{text:?}");
        assert!(text.contains("after"), "{text:?}");
        assert!(!text.contains("redrawing"), "{text:?}");
    }

    /// A buffer too small writes NOTHING and reports what it needed, so the caller's retry is a
    /// clean second call rather than a truncated screen.
    #[test]
    fn an_undersized_buffer_writes_nothing_and_asks_again() {
        let raw = b"plain history with no churn in it at all\n";
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: both buffers are live locals.
        let needed = unsafe {
            slopdesk_sanitize(
                raw.as_ptr(),
                raw.len(),
                true,
                false,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert!(needed > tiny.len(), "the answer outgrew the buffer");
        assert_eq!(tiny, [0xAA; 4], "and nothing was written into it");
    }

    /// The plaintext doors answer under the same convention, and the two agree about the grammar.
    #[test]
    fn the_plaintext_doors_measure_then_fill_and_name_the_cut() {
        let input = b"\x1b[1mready\x1b[0m";
        let needed =
            unsafe { slopdesk_plaintext_strip(input.as_ptr(), input.len(), core::ptr::null_mut(), 0) };
        assert_eq!(needed, 5, "the measure names the text without writing it");
        let mut room = vec![0_u8; needed];
        let written =
            unsafe { slopdesk_plaintext_strip(input.as_ptr(), input.len(), room.as_mut_ptr(), room.len()) };
        assert_eq!(written, needed);
        assert_eq!(room, b"ready".to_vec());

        let cut = b"ok\x1b[3";
        assert_eq!(
            unsafe { slopdesk_plaintext_holdback(cut.as_ptr(), cut.len()) },
            2,
            "an unfinished CSI waits for its final byte"
        );
        assert_eq!(
            unsafe { slopdesk_plaintext_holdback(input.as_ptr(), input.len()) },
            input.len(),
            "and a whole buffer holds nothing back"
        );
    }

    /// The reset the near side used to spell out, byte for byte.
    #[test]
    fn the_reset_backstop_is_the_bytes_the_near_side_carried() {
        let needed = unsafe { slopdesk_input_mode_reset(core::ptr::null_mut(), 0) };
        let mut room = vec![0_u8; needed];
        let written = unsafe { slopdesk_input_mode_reset(room.as_mut_ptr(), room.len()) };
        assert_eq!(written, needed);
        assert_eq!(
            room,
            b"\x1b[?1049l\x1b[?1l\x1b[?9l\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l\x1b[?1004l\
              \x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?2031l\x1b[?2048l\
              \x1b[<32u\x1b[=0;1u\x1b[0m\x1b[?25h\r\n"
                .to_vec(),
            "the same resets, in the order the tracked set is written in"
        );
    }
}
