//! What the Peek & Reply card SENDS, and what it shows above the field it was typed in.
//!
//! The card answers a blocked agent in a pane the person is not looking at, so everything here is
//! about a line of text on its way to somebody else's PTY. Which PANE it goes to is not here — that
//! is `slopdesk_agent::attention`, beside the ordering the jump chord already walks, so the counter
//! on the card and the chain it counts can never disagree about what "waiting" means.
//!
//! ## Every reply ends in exactly one newline
//!
//! Both the agent and the shell on the other side read a LINE. The newline is appended here rather
//! than at the sink for the same reason the trimming is: a caller that appended its own would
//! double it the first time a text field handed back the newline the Return key put there, and
//! "yes\n\n" answers a prompt twice.
//!
//! ## The bang is not a privilege
//!
//! A leading `!` sends the rest as a shell line, and that is bytes to the SAME shell the agent is
//! running in — no escalation, no second process, no different user. It exists because the answer
//! to "may I edit this file?" is often "wait, let me look", and looking should not cost a context
//! switch to another pane.

/// The text to send for a typed reply, or `None` when there is nothing to send.
///
/// Three shapes, one answer:
///
/// - a `!`-prefixed line sends the rest as a shell line — `"!ls"` becomes `"ls\n"`;
/// - any other non-empty line sends itself;
/// - an empty, whitespace-only, or bare-`!` field sends nothing, and the caller no-ops.
///
/// Whitespace around the WHOLE field is trimmed and interior spacing is kept: the field is a text
/// input, so a trailing space is an artefact of typing, and the spaces inside `git  log` are not.
/// The bang is trimmed on BOTH sides of itself, so `"  !  git status "` reaches the shell as
/// `"git status\n"` rather than with the gap a person left while thinking.
#[must_use]
pub fn reply(field: &str) -> Option<String> {
    let trimmed = field.trim();
    if trimmed.is_empty() {
        return None;
    }
    let line = trimmed.strip_prefix('!').map_or(trimmed, str::trim);
    // A bare `!` is an empty shell line, which is the same nothing as an empty field — the caller
    // must not be handed a lone newline to type into a prompt that is waiting for an answer.
    if line.is_empty() {
        return None;
    }
    Some(format!("{line}\n"))
}

/// The text a quick-answer DIGIT sends, or `None` for a key that is not one.
///
/// The commonest thing a blocked agent asks is a numbered multiple choice, so `1`–`9` typed into an
/// EMPTY field fire immediately instead of waiting for Return. A separate entry point rather than a
/// path through [`reply`], because the two are asked at different moments — this one on a key
/// press, that one on submit — and folding them would make a stray `5` in the middle of a sentence
/// send the sentence.
///
/// `0` is not an answer: a numbered prompt starts at one, and a `0` is far more likely to be the
/// beginning of a number the person is still typing.
#[must_use]
pub fn quick_answer(digit: i32) -> Option<String> {
    (1..=9).contains(&digit).then(|| format!("{digit}\n"))
}

/// The `limit` newest command blocks as one line each, oldest-first — the card's "recent output".
///
/// A stand-in for a scrollback tail, and deliberately a cheap one: it reads the per-pane block
/// mirror rather than the renderer, so a card can be drawn for a pane whose surface is not on
/// screen — which is the entire point of answering a pane you are not looking at.
///
/// `commands` and `statuses` are PARALLEL: entry `i` of one is entry `i` of the other. A ragged
/// pair is read to the shorter of the two rather than refused, because the pair is assembled by the
/// caller and a card with one line missing is a better failure than a card with none.
///
/// A block with an empty command line — one still forming, before the shell has echoed anything —
/// prints its status ALONE, with no leading separator dangling off nothing.
#[must_use]
pub fn recent_lines(commands: &[&str], statuses: &[&str], limit: usize) -> Vec<String> {
    if limit == 0 {
        return Vec::new();
    }
    let pairs: Vec<(&&str, &&str)> = commands.iter().zip(statuses.iter()).collect();
    // The NEWEST `limit`, kept in their own order so the block reads top-to-bottom like a
    // transcript tail rather than a most-recent-first feed.
    let kept = pairs.len().saturating_sub(limit);
    pairs
        .into_iter()
        .skip(kept)
        .map(|(command, status)| {
            let command = command.trim();
            if command.is_empty() {
                (*status).to_owned()
            } else {
                format!("{command} \u{b7} {status}")
            }
        })
        .collect()
}

/// The tallest either of the card's scrolling blocks — the expanded pending-tool input, the recent
/// output tail — may grow to before it scrolls instead.
///
/// ONE number for both, because a card with two scroll wells of different heights reads as two
/// unrelated panels rather than as one card.
pub const SCROLL_MAX_HEIGHT: f64 = 132.0;

/// The trailing caption when there is no queue to count — the card's name, standing where the
/// counter would.
pub const TITLE: &str = "Peek & Reply";

/// The zero-state card's line, for the near-impossible race where the host clears the last status
/// while the card is up.
pub const ALL_CAUGHT_UP: &str = "Nothing needs your reply.";

/// What the question block prints when the agent reported no question of its own.
///
/// A pane with no reported question still gets a card — the status said it was blocked — so the
/// block prints this in the supporting ink rather than going blank.
pub const MISSING_QUESTION: &str = "The agent is waiting for your input.";

/// The `N of M` triage counter, or `None` when this is not a queue.
///
/// A pass-through of the attention chain's own answer into the one place the two halves both read
/// it from — the counter REPLACES the static [`TITLE`] on the queue edge, a hard cut, never both at
/// once.
#[must_use]
pub fn counter(position: Option<(u32, u32)>) -> Option<String> {
    let (position, total) = position?;
    Some(format!("{position} of {total}"))
}

/// The question block's text, and whether it is the card's own note rather than the agent's.
///
/// The caller reads the flag to know which ink to print it in; the two are answered together
/// because a caller that derived the flag from the text would have to compare against
/// [`MISSING_QUESTION`], and an agent that happened to ask that exact question would be drawn as a
/// placeholder.
#[must_use]
pub const fn question(question: Option<&str>) -> (&str, bool) {
    match question {
        Some(text) => (text, false),
        None => (MISSING_QUESTION, true),
    }
}

#[cfg(test)]
mod tests {
    use super::{MISSING_QUESTION, counter, question, quick_answer, recent_lines, reply};

    #[test]
    fn a_plain_line_sends_itself_with_one_newline() {
        assert_eq!(reply("yes").as_deref(), Some("yes\n"));
        assert_eq!(
            reply("  approve the edit  ").as_deref(),
            Some("approve the edit\n")
        );
    }

    /// Interior spacing survives; only the ends are the typist's.
    #[test]
    fn the_trim_is_of_the_field_and_not_of_the_sentence() {
        assert_eq!(
            reply("  git  log --oneline  ").as_deref(),
            Some("git  log --oneline\n")
        );
    }

    #[test]
    fn a_bang_sends_the_rest_as_a_shell_line() {
        assert_eq!(reply("!ls -la").as_deref(), Some("ls -la\n"));
        assert_eq!(reply("  ! git status ").as_deref(), Some("git status\n"));
    }

    #[test]
    fn nothing_typed_sends_nothing() {
        assert_eq!(reply(""), None);
        assert_eq!(reply("   "), None);
        assert_eq!(reply("!"), None, "a bare bang is an empty shell line");
        assert_eq!(reply("  !  "), None);
    }

    /// A newline the text field handed back is trimmed rather than doubled — the failure this
    /// module's "exactly one newline" rule exists to stop.
    #[test]
    fn a_field_that_returns_its_own_newline_still_sends_one() {
        assert_eq!(reply("yes\n").as_deref(), Some("yes\n"));
        assert_eq!(reply("\nyes\n\n").as_deref(), Some("yes\n"));
    }

    #[test]
    fn the_quick_answers_are_one_through_nine() {
        assert_eq!(quick_answer(1).as_deref(), Some("1\n"));
        assert_eq!(quick_answer(9).as_deref(), Some("9\n"));
        for outside in [i32::MIN, -1, 0, 10, 42, i32::MAX] {
            assert_eq!(quick_answer(outside), None, "{outside} is not a choice");
        }
    }

    #[test]
    fn the_newest_blocks_are_kept_in_reading_order() {
        let commands = ["make", "swift build", "swift test"];
        let statuses = ["exit 0", "exit 1", "running\u{2026}"];
        assert_eq!(recent_lines(&commands, &statuses, 2), vec![
            "swift build \u{b7} exit 1".to_owned(),
            "swift test \u{b7} running\u{2026}".to_owned(),
        ]);
    }

    #[test]
    fn a_block_with_no_command_prints_its_status_alone() {
        assert_eq!(recent_lines(&["   "], &["running\u{2026}"], 4), vec![
            "running\u{2026}".to_owned()
        ]);
    }

    #[test]
    fn no_blocks_and_no_room_are_both_no_lines() {
        assert!(recent_lines(&[], &[], 4).is_empty());
        assert!(recent_lines(&["x"], &["exit 0"], 0).is_empty());
    }

    /// A limit past the end keeps everything rather than padding.
    #[test]
    fn a_limit_larger_than_the_history_keeps_the_history() {
        assert_eq!(recent_lines(&["a", "b"], &["exit 0", "exit 1"], 99).len(), 2);
    }

    /// A ragged pair reads to the shorter side — a card with one line is better than a trap.
    #[test]
    fn a_ragged_pair_reads_to_the_shorter_side() {
        assert_eq!(recent_lines(&["a", "b"], &["exit 0"], 4), vec![
            "a \u{b7} exit 0".to_owned()
        ]);
        assert!(recent_lines(&[], &["exit 0", "exit 1"], 4).is_empty());
    }

    /// The counter and the title are a hard cut: one or the other stands in that slot.
    #[test]
    fn the_counter_answers_only_for_a_queue() {
        assert_eq!(counter(Some((2, 5))), Some("2 of 5".to_owned()));
        assert_eq!(counter(None), None);
    }

    /// The flag rides WITH the text, so an agent that asks the placeholder's own question is still
    /// drawn as having asked it.
    #[test]
    fn a_missing_question_is_flagged_rather_than_recognised_by_its_words() {
        assert_eq!(question(None), (MISSING_QUESTION, true));
        assert_eq!(question(Some("may I edit?")), ("may I edit?", false));
        assert_eq!(question(Some(MISSING_QUESTION)), (MISSING_QUESTION, false));
    }
}
