//! Which `TERM` this host can actually honour — the door over [`slopdesk_probe::terminfo`].
//!
//! ## What this replaced, and why the fork went with it
//! A Swift `TerminfoResolver` asked the SAME rule through a forked `slopdesk-probe terminfo`, and a
//! Swift `ClaudeCodeProfile` held the two names it asked with as an enum. Both are gone;
//! `slopdesk-invariants`' `deleted_host_swift` is what keeps them gone.
//!
//! The fork was the right shape when the answer had to be discovered — `docs/DECISIONS.md` stage 25
//! moved the search order, the two on-disk layouts and the `infocmp` authority into the probe
//! precisely because they were untestable in Swift. What it was never right about is the LIFETIME:
//! `resolve` is a pure function of a name and an environment, it remembers nothing, and nothing has
//! to outlive its caller. `CLAUDE.md`'s own rule says such a port ships as a linked library, and
//! `ScrollbackReplayTransform` reversed the same placement for the same reason. So the rule stays
//! exactly where it was and hostd stops paying a `posix_spawn` to reach it.
//!
//! The probe's `terminfo` SUBCOMMAND went with the fork, because nothing was left to call it — the
//! module it wrapped is right here, one call away, and a CLI arm with no caller is the dead code
//! the `probe-one-alphabet` ratchet exists to notice. The module itself stays in `slopdesk-probe`:
//! that crate is where this process asks the machine about itself, and the question has not
//! changed.
//!
//! ## The two names are the CALLER's
//! Nothing here knows them. The caller asks "resolve `requested`, and if you cannot, say
//! `fallback`" — so the decision is about two strings rather than about an enum a second language
//! would have to keep in step.

use core::ffi::c_uchar;

use slopdesk_probe::terminfo;

use crate::{borrow, deliver};

/// The effective `TERM` to advertise into a spawned PTY.
///
/// Writes `fell_back` — whether getting to the answer meant giving up on `requested` — and answers
/// the `TERM` itself under §4's convention. A `requested` that IS the `fallback` short-circuits the
/// search: the request is authoritative and there is nothing to fall back from.
///
/// A `requested` or `fallback` that is not UTF-8 answers 0 with `fell_back` untouched, which the
/// caller reads as "no answer" — the same shape every other refusal in this crate has.
///
/// # Safety
/// `requested` and `fallback` must be null or point to their stated lengths of initialised bytes
/// live for the call; `fell_back` must be null or writable for the call; `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminfo_resolve(
    requested: *const c_uchar,
    requested_len: usize,
    fallback: *const c_uchar,
    fallback_len: usize,
    fell_back: *mut bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let (requested, fallback) = unsafe {
        (
            core::str::from_utf8(borrow(requested, requested_len)),
            core::str::from_utf8(borrow(fallback, fallback_len)),
        )
    };
    let (Ok(requested), Ok(fallback)) = (requested, fallback) else {
        return 0;
    };
    let (term, gave_up) = terminfo::resolve(requested, fallback, &terminfo::process_environment());
    if !fell_back.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for this call.
        unsafe { fell_back.write(gave_up) };
    }
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(term.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::slopdesk_terminfo_resolve;

    /// The short-circuit is the one answer that needs no host at all: a request that IS the
    /// fallback is authoritative, and asking `infocmp` about it would spawn a process to be told
    /// so.
    #[test]
    fn a_request_that_is_the_fallback_never_falls_back() {
        let name = "xterm-256color";
        let mut fell_back = true;
        let mut out = [0_u8; 32];
        let written = unsafe {
            slopdesk_terminfo_resolve(
                name.as_ptr(),
                name.len(),
                name.as_ptr(),
                name.len(),
                &raw mut fell_back,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(&out[..written], name.as_bytes());
        assert!(!fell_back);
    }

    /// A `TERM` no host has an entry for lands on the fallback and SAYS so — that flag is what gets
    /// the substitution into the log instead of silently degrading every TUI app.
    #[test]
    fn an_unresolvable_request_lands_on_the_fallback_and_reports_it() {
        let requested = "xterm-nothing-ships-this";
        let fallback = "xterm-256color";
        let mut fell_back = false;
        let mut out = [0_u8; 32];
        let written = unsafe {
            slopdesk_terminfo_resolve(
                requested.as_ptr(),
                requested.len(),
                fallback.as_ptr(),
                fallback.len(),
                &raw mut fell_back,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(&out[..written], fallback.as_bytes());
        assert!(fell_back);
    }

    /// §4: an undersized buffer writes nothing and reports what it needed.
    #[test]
    fn an_undersized_buffer_writes_nothing_and_asks_again() {
        let name = "xterm-256color";
        let needed = unsafe {
            slopdesk_terminfo_resolve(
                name.as_ptr(),
                name.len(),
                name.as_ptr(),
                name.len(),
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, name.len());
    }
}
