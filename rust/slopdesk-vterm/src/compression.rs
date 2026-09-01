//! Idle compression of the scrollback the session retains.
//!
//! The engine can compress fully historical pages — the ones behind the viewport that nothing is
//! drawing — and restore them transparently the moment anything reads them. Text-heavy history
//! compresses to roughly a tenth of its page memory, and the cost is paid only where the terminal
//! is otherwise doing nothing.
//!
//! ⚠️ **The split is ghostty's, and it is the reason this module is so small.** The engine decides
//! what is compressible and does the work; the embedder decides only WHEN, because only the
//! embedder knows whether the user is watching a `yes` flood or has walked away. ghostty's renderer
//! thread does that with a one-shot timer it postpones on every wake
//! (`renderer/Thread.zig`'s `Compression`, 250 ms idle / 1 ms step). This crate holds the same
//! policy — the intervals below ARE ghostty's numbers — so the Swift half owns a timer and nothing
//! else: [`VtSession::compress_step`] answers how long to wait before it should call again.
//!
//! ⚠️ **Not a background thread, and not one that could be.** The engine's own documentation says
//! compression must be serialized with writes, rendering and searches; a [`VtSession`] is neither
//! `Send` nor `Sync`, so every caller is already on the one thread that touches it and the
//! serialization is free. A step is bounded — that is what `Incremental` means — so running it on
//! the main thread costs a fraction of a frame.

use libghostty_vt::terminal::{CompressionMode, CompressionResult};

use crate::session::VtSession;

/// What the caller should do after one call to [`VtSession::compress_step`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompressionStep {
    /// The scrollback moved since the last step, so nothing was compressed. Wait out the idle
    /// interval again — pages a program is still writing are not the ones worth compressing.
    Postponed,
    /// A bounded step ran and more work remains. Step again promptly.
    More,
    /// Nothing is left to do until the scrollback changes again. Stop stepping; the next feed is
    /// what starts this over.
    Done,
}

impl CompressionStep {
    /// How long to wait before the next [`VtSession::compress_step`], or `None` when there is
    /// nothing to wait for.
    ///
    /// ghostty's two intervals, unchanged: a quarter second of quiet before compression starts, and
    /// as little as possible between the steps of a pass already under way.
    #[must_use]
    pub const fn delay_ms(self) -> Option<u64> {
        match self {
            Self::Postponed => Some(IDLE_INTERVAL_MS),
            Self::More => Some(STEP_INTERVAL_MS),
            Self::Done => None,
        }
    }
}

/// The quiet a scrollback must hold before its pages are worth compressing.
pub const IDLE_INTERVAL_MS: u64 = 250;

/// The gap between the steps of a pass already under way — as short as a timer can be asked for.
pub const STEP_INTERVAL_MS: u64 = 1;

impl VtSession {
    /// Compresses a bounded slice of the retained scrollback, and says when to call again.
    ///
    /// Call it from a one-shot timer armed [`IDLE_INTERVAL_MS`] after a feed, then re-arm at
    /// whatever [`CompressionStep::delay_ms`] answers until it answers `None`. Calling it more
    /// often than that is not wrong, only wasteful: a step that finds the scrollback still moving
    /// does no work and says [`CompressionStep::Postponed`].
    ///
    /// ⚠️ **The engine's activity token is what makes this cheap, and it is compared HERE rather
    /// than by the caller.** The token changes whenever something happened that compression would
    /// care about, which is not the same question as "did a byte arrive" — a program repainting its
    /// own screen churns the viewport without touching a historical page, and a caller that armed
    /// off feeds alone would compress under a `yes` flood and back off under a full-screen editor,
    /// which is exactly backwards.
    ///
    /// Nothing about the terminal's CONTENTS changes: a compressed page decompresses the instant a
    /// scan, a search or a scroll reads it, so no caller of this crate needs to know it happened.
    /// A target with no compression support answers [`CompressionStep::Done`] forever, at the cost
    /// of one engine call per idle period.
    pub fn compress_step(&mut self) -> CompressionStep {
        let Ok(activity) = self.terminal.compression_activity() else {
            return CompressionStep::Done;
        };
        if self.compression_activity != Some(activity) {
            self.compression_activity = Some(activity);
            return CompressionStep::Postponed;
        }
        match self.terminal.compress(CompressionMode::Incremental) {
            Ok(CompressionResult::Pending) => CompressionStep::More,
            Ok(CompressionResult::Complete | CompressionResult::Unsupported) | Err(_) => {
                CompressionStep::Done
            },
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CompressionStep, IDLE_INTERVAL_MS, STEP_INTERVAL_MS};
    use crate::session::VtSession;

    /// A session deep enough to hold every line the tests below feed it.
    fn session() -> VtSession {
        let mut session = VtSession::new(80, 24, 8, 16).unwrap();
        session.set_scrollback_rows(10_000).unwrap();
        session
    }

    /// `lines` numbered rows in ONE feed. Short rows and one call: the engine costs by the BYTE, so
    /// a test that wanted rows and wrote sentences would spend ten seconds buying them.
    fn fill(session: &mut VtSession, lines: usize) {
        use std::fmt::Write as _;

        let mut output = String::new();
        for line in 0..lines {
            let _ = writeln!(output, "{line}\r");
        }
        session.feed(output.as_bytes());
    }

    #[test]
    fn the_first_step_after_output_only_postpones() {
        let mut session = session();
        fill(&mut session, 2_000);
        assert_eq!(
            session.compress_step(),
            CompressionStep::Postponed,
            "a scrollback that just moved is one a program may still be writing"
        );
    }

    #[test]
    fn a_pass_terminates_and_leaves_the_history_byte_for_byte() {
        let mut session = session();
        fill(&mut session, 2_000);
        let oldest = session.screen_row_text(0).unwrap().unwrap();

        // Bounded by construction: the loop is the caller's contract, and a pass that never said
        // `Done` would be a hang in the app rather than a failure here.
        let mut steps = 0;
        while session.compress_step() != CompressionStep::Done {
            steps += 1;
            assert!(steps < 100_000, "an incremental pass has to end");
        }

        assert_eq!(
            session.screen_row_text(0).unwrap(),
            Some(oldest),
            "compression is a storage change; reading a compressed page restores it"
        );
    }

    #[test]
    fn the_delays_are_the_ones_ghostty_waits() {
        assert_eq!(CompressionStep::Postponed.delay_ms(), Some(IDLE_INTERVAL_MS));
        assert_eq!(CompressionStep::More.delay_ms(), Some(STEP_INTERVAL_MS));
        assert_eq!(
            CompressionStep::Done.delay_ms(),
            None,
            "the timer is disarmed rather than re-armed at zero"
        );
    }

    #[test]
    fn output_after_a_finished_pass_starts_the_next_one() {
        let mut session = session();
        fill(&mut session, 2_000);
        while session.compress_step() != CompressionStep::Done {}

        fill(&mut session, 2_000);
        assert_eq!(
            session.compress_step(),
            CompressionStep::Postponed,
            "the activity token is what re-arms the pass, and new output moves it"
        );
    }
}
