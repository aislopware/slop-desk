//! Which host command-block record describes which laid-out block.
//!
//! ## Why this exists at all
//!
//! A header can always show what the rows in front of it say. What it cannot show, without help, is
//! the thing a reader actually scrolls back FOR: did that command succeed, and how long did it
//! take. Those live in the host's segmenter, which stamps every block an `exit_code`, a
//! `duration_ms` and a 1-based `prompt_ordinal` — the count of OSC 133 `A` marks it had seen — and
//! ships all three to the client on wire type 28. The layout, meanwhile, segments the engine's own
//! rows by their per-row `RowSemantic::Prompt` flag and knows nothing about ordinals.
//!
//! So both halves are already here and on the same machine; nothing ties them together. This module
//! is that tie, and it is a pure decision over two lists so it can be tested without a pty, a host
//! or a frame.
//!
//! ⚠️ An earlier reading of this gap (docs/68 §5.3) called it upstream-blocked — "closing it means
//! carrying the ordinal in the mark itself, a shell-integration change". That was wrong, and wrong
//! in the expensive direction: it parked a closable feature behind someone else's release. The
//! ordinal never needed to be in the mark, because the host already derives it and sends it.
//!
//! ## Why an ANCHOR and not a per-block match
//!
//! The obvious join — match each block to the record whose `command_text` equals its prompt row —
//! is ambiguous exactly when a terminal is most ordinary: run `ls` three times and three records
//! tie. Ordinals are unique, so the join is really one question, asked once: **which ordinal does
//! the LAST prompt-bearing block hold?** Every other block counts backwards from it.
//!
//! The anchor is not simply "the newest record", because a prompt row is born from PTY BYTES while
//! its record arrives as a CONTROL MESSAGE, and those two do not order against each other (the same
//! race `docs/DECISIONS.md` line ~763 exists for). In the window between a shell printing its
//! prompt and the host reporting the block, the frame holds one more prompt than the records
//! account for, and an anchor of "newest record" would shift EVERY header by one — printing the
//! previous command's exit code under this one. That is the ghost-text failure mode again: a wrong
//! answer confidently placed is worse than no answer, because the reader has already believed it.
//!
//! So the anchor is GUESSED and then VERIFIED against the prompt text, and a join that cannot be
//! verified draws nothing.

/// The part of a host command-block record this join needs.
///
/// Deliberately not the whole record: the join decides identity, and identity is the ordinal plus
/// the text that confirms it. What a confirmed block then DISPLAYS is the caller's business.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Record<'a> {
    /// The segmenter's 1-based count of OSC 133 `A` marks at this block's start.
    ///
    /// Zero means the host stamped none — a mid-stream join, where the client attached partway
    /// through a session and the count is not knowable. [`blocks::jump_plan`] already refuses
    /// those; so does this.
    ///
    /// [`blocks::jump_plan`]: https://docs.rs/slopdesk-terminal
    pub ordinal: u32,
    /// The command the host recorded for it, used only to confirm the anchor.
    pub command_text: &'a str,
}

/// How many anchors to try before giving up.
///
/// Two: the records are current, or they are one behind because the newest prompt's record has not
/// landed yet. A third would be a second command started while the first's record was still in
/// flight, which the host cannot produce — it stamps a block at the prompt that opens it, so the
/// records cannot fall two behind the prompts without the pty also being two ahead, and the pty is
/// what draws the prompts. Bounding this is what keeps a mismatch cheap: an unbounded search over
/// offsets would eventually find a spurious agreement on a session where every command is `ls`.
const MAX_LAG: u32 = 1;

/// The ordinal each prompt-bearing block holds, or `None` for one this cannot prove.
///
/// `prompts` is the rendered text of each prompt-bearing block's prompt rows, oldest first, exactly
/// as the layout ordered them. `records` is what the host has said about this pane, in any order.
///
/// The answer is positional against `prompts`, so a caller zips the two and never has to reconcile
/// two orderings. Every element is `None` when nothing verifies — the honest whole-frame answer,
/// and the one that makes a header degrade to what it could always show.
#[must_use]
pub fn join(prompts: &[&str], records: &[Record<'_>]) -> Vec<Option<u32>> {
    let none = vec![None; prompts.len()];
    if prompts.is_empty() || records.is_empty() {
        return none;
    }
    // A zero ordinal is a mid-stream attach, and it must not be allowed to anchor anything: it
    // would claim to be the newest while naming no position at all.
    let Some(newest) = records
        .iter()
        .map(|record| record.ordinal)
        .filter(|&o| o > 0)
        .max()
    else {
        return none;
    };

    for lag in 0..=MAX_LAG {
        let anchor = newest.saturating_add(lag);
        let assigned = assign(prompts.len(), anchor);
        if verifies(prompts, &assigned, records) {
            return assigned;
        }
    }
    none
}

/// Counts backwards from `anchor`, one ordinal per block, oldest first.
///
/// A block whose ordinal would fall at or below zero is `None` rather than wrapping: the frame can
/// hold more prompts than the session has ordinals only when the host attached late, and inventing
/// an ordinal 0 there would collide with the mid-stream sentinel.
fn assign(count: usize, anchor: u32) -> Vec<Option<u32>> {
    let mut out = vec![None; count];
    for (back, slot) in out.iter_mut().rev().enumerate() {
        let Ok(back) = u32::try_from(back) else { break };
        *slot = anchor.checked_sub(back).filter(|&ordinal| ordinal > 0);
    }
    out
}

/// Whether `assigned` agrees with every record it can be checked against.
///
/// The check is one-sided on purpose. A block whose ordinal names no record proves nothing — the
/// ring is bounded (64 entries) and an old block's record is simply gone, which is not evidence the
/// anchor is wrong. So an assignment verifies when it CONTRADICTS nothing and is confirmed by at
/// least one block; requiring only the first would let an empty overlap pass, and requiring all
/// would refuse every scrolled-back frame.
fn verifies(prompts: &[&str], assigned: &[Option<u32>], records: &[Record<'_>]) -> bool {
    let mut confirmed = 0usize;
    for (prompt, ordinal) in prompts.iter().zip(assigned) {
        let Some(ordinal) = ordinal else { continue };
        let Some(record) = records.iter().find(|record| record.ordinal == *ordinal) else {
            continue;
        };
        if matches(prompt, record.command_text) {
            confirmed += 1;
        } else {
            return false;
        }
    }
    confirmed > 0
}

/// Whether a rendered prompt row is showing `command`.
///
/// `ends_with` rather than equality, because the row carries the shell's PS1 in front of the
/// command — a `❯ `, a path, a git branch, whatever the user has set — and the host records only
/// the command itself. Both sides are trimmed: the row is padded to the grid's width, so it arrives
/// with a tail of spaces that no record will ever have.
///
/// An empty command matches nothing. A bare prompt with no command typed yet is a real block, and
/// every row on earth ends with an empty string — so treating it as a match would confirm any
/// anchor at all, which is the one thing this function exists to prevent.
fn matches(prompt: &str, command: &str) -> bool {
    let command = command.trim();
    !command.is_empty() && prompt.trim_end().ends_with(command)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(ordinal: u32, command_text: &str) -> Record<'_> {
        Record {
            ordinal,
            command_text,
        }
    }

    /// The ordinary case: the records are current, so the last block is the newest ordinal.
    #[test]
    fn counts_back_from_the_newest_record() {
        let prompts = ["❯ cargo build", "❯ ls -la", "❯ git status"];
        let records = [
            record(7, "cargo build"),
            record(8, "ls -la"),
            record(9, "git status"),
        ];
        assert_eq!(join(&prompts, &records), vec![Some(7), Some(8), Some(9)]);
    }

    /// ⚠️ THE RACE. A prompt has been printed whose record has not arrived, so the frame holds one
    /// more block than the records know about. Anchoring on the newest record would slide every
    /// header up one and print `ls -la`'s exit code under `git status`.
    #[test]
    fn a_prompt_whose_record_has_not_landed_shifts_the_anchor_not_the_answers() {
        let prompts = ["❯ cargo build", "❯ ls -la", "❯ git status", "❯ "];
        let records = [
            record(7, "cargo build"),
            record(8, "ls -la"),
            record(9, "git status"),
        ];
        assert_eq!(join(&prompts, &records), vec![
            Some(7),
            Some(8),
            Some(9),
            Some(10)
        ]);
    }

    /// A frame scrolled back past the ring's reach: the oldest block's record has been evicted.
    ///
    /// It still gets its ordinal, because the anchor is carried by the blocks that DO have records
    /// and counting backwards needs no record of its own. Refusing the whole frame because one
    /// record aged out would put the feature on a timer.
    ///
    /// ⚠️ The eviction is at the OLD end, and that direction is the whole reason the anchor is
    /// taken from `max(ordinal)`: the ring keeps the newest 64, so the newest block is the one
    /// always covered. The mirror image — a record for the oldest block only — is not a case to
    /// support but an impossible one, and an earlier version of this test asserted it and was
    /// wrong.
    #[test]
    fn an_evicted_record_does_not_refuse_the_join() {
        let prompts = ["❯ make", "❯ ls", "❯ git status"];
        let records = [record(42, "ls"), record(43, "git status")];
        assert_eq!(join(&prompts, &records), vec![Some(41), Some(42), Some(43)]);
    }

    /// Nothing overlaps, so nothing is confirmed, so nothing is claimed.
    ///
    /// The alternative — trusting an anchor no block corroborates — is what would print a stale
    /// exit code after a reattach, when records for a previous session are still in the ring.
    #[test]
    fn an_unconfirmable_anchor_answers_nothing() {
        let prompts = ["❯ make", "❯ ls"];
        let records = [record(41, "totally different")];
        assert_eq!(join(&prompts, &records), vec![None, None]);
    }

    /// A mid-stream attach stamps ordinal 0, which names no position and must never anchor.
    #[test]
    fn a_zero_ordinal_never_anchors() {
        let prompts = ["❯ ls"];
        assert_eq!(join(&prompts, &[record(0, "ls")]), vec![None]);
    }

    /// A bare prompt confirms nothing, because every string ends with an empty one.
    #[test]
    fn an_empty_command_is_not_a_confirmation() {
        let prompts = ["❯ "];
        assert_eq!(join(&prompts, &[record(3, "   ")]), vec![None]);
    }

    /// More blocks on screen than the session has ordinals — a late attach. The overflow is `None`
    /// rather than a wrapped ordinal 0, which is the mid-stream sentinel.
    #[test]
    fn blocks_older_than_ordinal_one_are_unnamed() {
        let prompts = ["❯ old", "❯ ls", "❯ make"];
        let records = [record(2, "make")];
        assert_eq!(join(&prompts, &records), vec![None, Some(1), Some(2)]);
    }

    /// No records at all — a pane that has reported nothing yet.
    #[test]
    fn no_records_answers_nothing() {
        assert_eq!(join(&["❯ ls"], &[]), vec![None]);
    }

    /// ⚠️ THE ONE SHAPE THIS FUNCTION CANNOT DEFEND AGAINST, pinned here so the reason the caller
    /// must clear its records on a fresh shell is written down beside the code that needs it.
    ///
    /// A dead session left records in the forties; the shell that replaced it counts from one. The
    /// anchor is the newest ordinal HELD, so the new shell's blocks are counted back from 43 — and
    /// because everyday commands repeat, the text check confirms rather than rejects it. The
    /// verification is one-sided by design (an unmatched prompt proves nothing), so there is no
    /// evidence inside this input that would let the join say no.
    ///
    /// The fix is upstream and not here: `slopdesk_term_surface_forget_blocks`, called from the
    /// same edge that drops the client's own block list. Asserting the wrong answer is the point —
    /// if a later change makes this return `None`, the guard has moved and this test should be
    /// rewritten, not deleted.
    #[test]
    fn stale_records_from_a_dead_session_confirm_a_wrong_anchor() {
        let prompts = ["❯ ls", "❯ make"];
        let records = [record(42, "ls"), record(43, "make")];
        assert_eq!(join(&prompts, &records), vec![Some(42), Some(43)]);
    }
}
