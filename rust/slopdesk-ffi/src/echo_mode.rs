//! The host's PTY-echo signal, in C.
//!
//! macOS only, gated in `lib.rs`: both doors are about a PTY master this process owns, and the
//! client end of the feature is a wire message rather than a call.
//!
//! Two doors because there are two questions and the callers ask them separately. The steady path
//! probes and folds; the REATTACH path already has a probed value in hand and needs the fold
//! re-anchored against it, so a single combined door would have to grow a mode flag to serve both.
//!
//! Together they are all of the deleted `EchoModeWatcher.swift`. What is left on the near side is
//! one `Bool` per pane — the last state that pane emitted — which is state the pane owns and not a
//! decision anybody takes.

use core::ffi::c_int;

/// Does this PTY master's line discipline mean a person can SEE what they are typing?
///
/// `false` means a hidden-password prompt is up and the client should engage Secure Keyboard Entry.
/// A negative descriptor, a descriptor that is not a terminal, or a `tcgetattr` that declines all
/// read as `true`: a probe error must never spuriously lock a user's keyboard.
///
/// The rule is NOT "`ECHO` is cleared" — a line editor and every full-screen TUI clear it too and
/// do their own echoing. See `slopdesk_posix::pty::echo_on` for the discrimination and the
/// empirical pinning behind it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pty_echo_enabled(master_fd: c_int) -> bool {
    slopdesk_posix::pty::echo_enabled(master_fd)
}

/// Is this sample worth a type-31 `inputEcho`, given the last state the caller emitted?
///
/// `true` means send `inputEcho(sample)` and remember `sample`. `false` means say nothing, so a
/// caller may probe as often as it likes without chattering — which both probe sites rely on, since
/// the input task and the foreground poll can sample the same instant.
///
/// Re-anchoring is passing `true` as `last_emitted` again: that is what the reattach path does, so
/// a no-echo prompt still up across a client's return produces a fresh message for a client whose
/// own mirror reset to echo-on.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pty_echo_edge(sample: bool, last_emitted: bool) -> bool {
    slopdesk_terminal::echo::is_edge(sample, last_emitted)
}

#[cfg(test)]
mod tests {
    use super::{slopdesk_pty_echo_edge, slopdesk_pty_echo_enabled};

    /// The door answers the module's rule, both directions, and absorbs a repeat.
    #[test]
    fn the_edge_door_emits_only_on_a_transition() {
        assert!(slopdesk_pty_echo_edge(false, true));
        assert!(slopdesk_pty_echo_edge(true, false));
        assert!(!slopdesk_pty_echo_edge(true, true));
        assert!(!slopdesk_pty_echo_edge(false, false));
    }

    /// Every descriptor the probe cannot read is echo-on, which is the one direction the default
    /// has to be safe in: a bad fd must not lock a keyboard.
    #[test]
    fn an_unreadable_descriptor_is_echo_on() {
        assert!(slopdesk_pty_echo_enabled(-1));
        assert!(slopdesk_pty_echo_enabled(i32::MAX));
    }
}
