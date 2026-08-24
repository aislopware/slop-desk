//! When a change in the host's echo state is worth telling the client about.
//!
//! The host samples a pane's PTY line discipline (`slopdesk_posix::pty::echo_enabled`) far more
//! often than it changes — right after every client keystroke, plus a low-rate poll — and turns the
//! samples into type-31 `inputEcho` messages on the CONTROL channel. This is the rule that decides
//! which samples become messages.
//!
//! ## Why the anchor is `true` and not "unknown"
//! Echo-on is the canonical default and the client assumes it too, so a detector anchored there is
//! SILENT in the common case: it emits only when a child actually clears `ECHO` for a hidden-
//! password prompt, and again when it restores. The CONTROL stream stays byte-identical to the
//! pre-feature one on a pane that never sees a password prompt. That is a deliberate divergence
//! from the agent detector next door, which first-emits from a `None` anchor — there the initial
//! value is news, here it is noise.
//!
//! ## Why the caller keeps the state
//! One bool, and it belongs to the pane. Handing it back as an argument rather than holding it
//! behind a handle keeps the rule a pure function of two values — which is what lets the reattach
//! path re-anchor by simply passing `true` again, with no reset call and no second state to keep in
//! step. See `docs/20-wire-protocol.md` type 31 and `docs/DECISIONS.md` (WI-6).

/// Is this sample an EDGE against the last state the caller emitted?
///
/// `true` means emit `inputEcho(sample)` and remember `sample` as the new last-emitted. `false`
/// means say nothing — re-feeding an unchanged sample is absorbed, so the caller may probe as often
/// as it likes without chattering.
#[must_use]
pub const fn is_edge(sample: bool, last_emitted: bool) -> bool {
    sample != last_emitted
}

#[cfg(test)]
mod tests {
    use super::is_edge;

    /// The steady state is silent, in both directions. A pane that never sees a password prompt
    /// emits nothing at all.
    #[test]
    fn an_unchanged_sample_is_absorbed() {
        assert!(!is_edge(true, true));
        assert!(!is_edge(false, false));
    }

    /// Both edges are news: the prompt going up, and the prompt coming down.
    #[test]
    fn both_directions_are_edges() {
        assert!(is_edge(false, true), "a password prompt went up");
        assert!(is_edge(true, false), "the password prompt came down");
    }

    /// Idempotent under repetition, which is the property the two probe sites lean on: the input
    /// task and the foreground poll can both sample the same instant and only one message results.
    #[test]
    fn a_run_of_samples_emits_only_on_the_transitions() {
        let mut last = true;
        let mut emitted = Vec::new();
        for sample in [true, true, false, false, false, true, true, false] {
            if is_edge(sample, last) {
                emitted.push(sample);
                last = sample;
            }
        }
        assert_eq!(emitted, [false, true, false]);
    }
}
