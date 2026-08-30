//! The re-run byte encoder, in C —
//! `Sources/SlopDeskWorkspaceCore/Terminal/BlockReRunEncoder.swift`.
//!
//! The rule is [`slopdesk_terminal::blocks::rerun_bytes`]; what is here is the marshalling. One
//! door, because the question is one question: given the text of a command that already ran, what
//! exactly should be typed into the pane to run it again — or should nothing be.
//!
//! ## Why `0` is allowed to mean "send nothing" here
//!
//! §4 spells "there is no answer" as a return of `0`, and that collides with a real answer wherever
//! an empty delivery is legal. It cannot collide here, and the reason is a property of the rule
//! rather than a convention: **a non-`None` answer always ends in the `0x0A` that executes the
//! command**, so it is never shorter than one byte. The wrapped crate's own suite pins that over a
//! corpus rather than asserting it once, in the case whose name says an empty answer is impossible,
//! because a property a sentinel rests on has to be held still on the side that can see it — which
//! is the same argument `docs/55` §4 makes for `slopdesk_fuzzy_rank`'s `-1`, read one convention
//! over.
//!
//! ## Why the command crosses as bytes and comes back as bytes
//!
//! Both directions are the pane's own UTF-8 and neither is a value with a shape. What goes in is a
//! captured `commandText`; what comes out is the exact keystroke payload, which is that text minus
//! its trailing newline run plus one newline. Nothing is parsed, nothing is escaped and nothing is
//! interpreted, which is the whole security argument of the rule: a captured command may literally
//! contain `<Enter>`, and a door that handed the near side anything other than raw bytes would be
//! inviting it to interpret them.

use core::ffi::c_uchar;

use slopdesk_terminal::blocks;

use crate::{borrow, deliver};

/// The bytes to inject to RE-RUN a captured command, or `0` for a command with nothing in it.
///
/// A return larger than `cap` means nothing was written — ask again at that size. A return of `0`
/// means the command was empty or whitespace-only and NOTHING should be sent; it cannot be confused
/// with a short answer, because every real answer ends in the newline that executes it.
///
/// Bytes that are not UTF-8 also answer `0`, which is the fail-CLOSED arm and is deliberate. The
/// one caller is Swift, whose `String.utf8` cannot be invalid, so the arm is unreachable from the
/// near side; if it is ever reached, the input is a command this door could not read, and injecting
/// keystrokes derived from bytes nothing could read is the one outcome worse than doing nothing.
///
/// # Safety
/// `(command, command_len)` must be readable for `command_len` bytes, or `command` must be null
/// with `command_len` 0; `(out, cap)` must be writable for `cap` bytes, or `out` must be null with
/// `cap` 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both buffers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_block_rerun_bytes(
    command: *const c_uchar,
    command_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's contract, discharged by Swift's `withUnsafeBufferPointer`, whose scope
    // is exactly this call.
    let bytes = unsafe { borrow(command, command_len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return 0;
    };
    let Some(answer) = blocks::rerun_bytes(text) else {
        return 0;
    };
    // SAFETY: the caller's contract.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::slopdesk_block_rerun_bytes;

    fn rerun(command: &str) -> Option<Vec<u8>> {
        let mut buffer = [0_u8; 64];
        // SAFETY: both buffers are live locals for the duration of the call.
        let needed = unsafe {
            slopdesk_block_rerun_bytes(command.as_ptr(), command.len(), buffer.as_mut_ptr(), buffer.len())
        };
        if needed == 0 {
            return None;
        }
        buffer.get(..needed).map(<[u8]>::to_vec)
    }

    #[test]
    fn a_command_comes_back_verbatim_with_one_newline_on_the_end() {
        assert_eq!(rerun("ls -la").as_deref(), Some(b"ls -la\n".as_slice()));
        assert_eq!(
            rerun("echo \"<Enter>\"").as_deref(),
            Some(b"echo \"<Enter>\"\n".as_slice()),
            "the literal token crosses as text, not as a control byte",
        );
    }

    #[test]
    fn a_trailing_newline_run_does_not_become_a_second_execution() {
        assert_eq!(rerun("make\n").as_deref(), Some(b"make\n".as_slice()));
        assert_eq!(rerun("make\r\n").as_deref(), Some(b"make\n".as_slice()));
    }

    #[test]
    fn nothing_to_run_answers_zero_and_zero_cannot_be_a_real_answer() {
        assert_eq!(rerun(""), None);
        assert_eq!(rerun("   "), None);
        assert_eq!(rerun(" \t\r\n "), None);
        // SAFETY: the null/zero pair is what `borrow` documents as empty.
        let needed = unsafe { slopdesk_block_rerun_bytes(core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(needed, 0, "a null command is an empty one");
    }

    #[test]
    fn a_short_output_buffer_reports_its_size_and_writes_nothing() {
        let mut tiny = [0xAA_u8; 3];
        let command = "make release";
        // SAFETY: both buffers are live locals.
        let needed = unsafe {
            slopdesk_block_rerun_bytes(command.as_ptr(), command.len(), tiny.as_mut_ptr(), tiny.len())
        };
        assert_eq!(needed, command.len() + 1);
        assert_eq!(tiny, [0xAA; 3], "an overflow leaves the caller's buffer alone");
    }

    #[test]
    fn the_sizing_call_is_a_null_output_and_the_answer_fits_the_arithmetic_bound() {
        for command in ["ls", "for i in 1 2\ndo echo $i\ndone", "make\r\n\r\n"] {
            // SAFETY: `(null, 0)` is the documented way to ask for the length before allocating.
            let needed = unsafe {
                slopdesk_block_rerun_bytes(command.as_ptr(), command.len(), core::ptr::null_mut(), 0)
            };
            assert!(
                needed > 0 && needed <= command.len() + 1,
                "{command:?} answered {needed}, outside the caller's arithmetic bound",
            );
        }
    }
}
