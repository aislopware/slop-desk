//! Running somebody else's program and keeping what it said, without trusting it about how much.
//!
//! Everything here is best-effort by contract: a missing binary, a non-zero exit, output that is
//! not UTF-8 — each answers `None` or an empty result, never an error the operator is asked to
//! resolve. The metadata RPC has a defined reply for "could not tell" and it is the same reply for
//! all of them, so distinguishing the causes would only be a distinction the caller then discards.

use std::io::Read as _;
use std::process::{Command, Stdio};

/// The source-side read budget for an opaque answer (a `git diff`, a session transcript).
///
/// It MIRRORS the Swift builder's 15 MiB opaque cap on purpose, and the reads here pull at most
/// `cap + 1` bytes: the builder's own `cappedOpaque()` then trims an already-bounded tail and its
/// "was truncated" signal survives, instead of a pathological diff spiking per-request memory
/// before any cap applies.
pub const MAX_OPAQUE_READ_BYTES: usize = 15 * 1024 * 1024;

/// Whether `accumulated` captured bytes have passed the budget.
///
/// `cap` → false, `cap + 1` → true, so the drain loop stops exactly one byte past the cap and the
/// truncation is still visible downstream.
#[must_use]
pub const fn opaque_budget_exceeded(accumulated: usize) -> bool {
    accumulated > MAX_OPAQUE_READ_BYTES
}

/// Runs `program arguments` and returns its stdout bytes; `None` when it could not be spawned.
///
/// stdout is drained in CHUNKS before the wait, for the reason every drain-before-wait exists: a
/// child filling the pipe buffer blocks on its write while a waiter blocks on its exit, and neither
/// moves again. Once the captured bytes pass the budget the child is killed and reading stops — the
/// read is bounded at the SOURCE, not after the fact.
#[must_use]
pub fn capture(program: &str, arguments: &[&str]) -> Option<Vec<u8>> {
    let mut child = Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut captured = Vec::new();
    if let Some(mut stdout) = child.stdout.take() {
        // Heap, not stack: a 64 KiB frame is most of a small thread's stack, and this program's
        // whole job is to be forked cheaply.
        let mut chunk = vec![0_u8; 64 * 1024];
        loop {
            match stdout.read(&mut chunk) {
                // EOF — the child closed its stdout, the normal case.
                Ok(0) | Err(_) => break,
                Ok(read) => {
                    captured.extend_from_slice(chunk.get(..read).unwrap_or_default());
                    if opaque_budget_exceeded(captured.len()) {
                        // Past the budget: a blocked write is interrupted by the kill, so the wait
                        // below cannot wedge. The bounded buffer is the answer, as-is.
                        let _unused = child.kill();
                        break;
                    }
                },
            }
        }
    }
    let _unused = child.wait();
    Some(captured)
}

/// [`capture`] decoded as UTF-8, lossily.
///
/// Lossy rather than strict because every caller here is parsing a LINE FORMAT, and one invalid
/// byte in a filename should cost that filename its exact spelling rather than cost the whole
/// listing. The Swift this replaces dropped the entire output instead, which is the worse failure:
/// a repo with one undecodable path reported as having no changes at all.
#[must_use]
pub fn capture_text(program: &str, arguments: &[&str]) -> Option<String> {
    capture(program, arguments).map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_binary_is_an_answer_of_none_rather_than_a_failure() {
        assert!(capture("/nonexistent/definitely-not-here", &[]).is_none());
    }

    #[test]
    fn stdout_comes_back_whole() {
        let out = capture("/bin/echo", &["hello"]).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "hello\n");
    }

    #[test]
    fn a_non_zero_exit_still_yields_what_it_managed_to_say() {
        // `false` prints nothing and exits 1 — an empty answer, not a missing one. The distinction
        // matters: the callers read "no output" as "no repo", never as "the probe broke".
        assert_eq!(capture("/usr/bin/false", &[]), Some(Vec::new()));
    }

    #[test]
    fn stderr_never_reaches_the_answer() {
        let out = capture("/bin/sh", &["-c", "echo out; echo err >&2"]).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "out\n");
    }

    #[test]
    fn more_than_one_pipe_buffer_does_not_deadlock() {
        // 4 MiB is many times any pipe buffer: a wait-then-read would hang here forever.
        let out = capture("/bin/dd", &["if=/dev/zero", "bs=1048576", "count=4"]).unwrap();
        assert_eq!(out.len(), 4 * 1024 * 1024);
    }

    #[test]
    fn the_budget_stops_one_byte_past_the_cap() {
        assert!(!opaque_budget_exceeded(MAX_OPAQUE_READ_BYTES));
        assert!(opaque_budget_exceeded(MAX_OPAQUE_READ_BYTES + 1));
    }

    #[test]
    fn undecodable_bytes_cost_a_character_not_the_whole_answer() {
        let text = capture_text("/bin/sh", &["-c", "printf 'a\\xffb'"]).unwrap();
        assert!(text.starts_with('a') && text.ends_with('b'));
    }
}
