//! Which typed command words the shell can actually find — the answer that turns a typo red.
//!
//! ## The fact is the HOST's, and this crate does no I/O
//!
//! `lib.rs` guarantees no clock and no I/O, and "is `gst` a command" is a question only the user's
//! own shell can answer: it is an alias their plugin manager installed, or a function in their rc,
//! or a builtin, or nothing at all. So this module holds no resolver. It holds the ANSWERS — a
//! small cache the host fills through one door — and the two derivations that make the cache
//! useful: which words are still unanswered, and what colour a span therefore is.
//!
//! ## Why the cache is dropped whenever a command RUNS
//!
//! A verdict is a fact about the machine, and the one thing that reliably changes that machine is a
//! command. `cargo install ripgrep` makes `rg` resolve; `unalias gst` makes `gst` stop. Expiring by
//! time would paint a stale colour for however long the timer was, and re-asking every keystroke
//! would spend a round trip on `g`, `gi` and `git` for ever. Dropping the whole table at the one
//! moment the environment could have moved is both cheaper and more correct than either, and it
//! keeps the table naturally small: it only ever holds the words of the lines typed since the last
//! one ran.
//!
//! It is also what makes a table keyed by WORD ALONE safe. A verdict is only true for the directory
//! it was asked from — `./deploy` resolves in one repository and not in the one next to it — and
//! nothing here records a directory. It does not have to: the only way a shell's directory moves is
//! by running `cd`, and running anything empties this table. The key can stay one string because
//! the invalidation already covers the other half of the question.
//!
//! ## Why the verdict collapses to a bit here
//!
//! The wire carries zsh's own vocabulary — `alias`, `function`, `builtin`, `reserved`, `command`,
//! `hashed`, `none` — because the host's job is to report what the shell said, not to pre-decide
//! how a client draws it. This crate paints exactly one distinction, so it stores exactly one bit.
//! A future detail column that wants "alias" reads it from the wire answer; it does not need the
//! editor to have been hoarding it.

use crate::prompt::syntax::{Lexed, SyntaxSpan, TokenKind, WordRole};

/// How many verdicts are kept before the oldest is dropped.
///
/// A prompt sees a handful of distinct command words between two runs — the words of the lines
/// typed since the last Enter, plus the prefixes of each as it was being typed. This is roomy for
/// that and small enough that the linear scan below is cheaper than a hash.
pub const CAPACITY: usize = 128;

/// What the host has said about the command words typed so far.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CommandValidity {
    /// Insertion-ordered, so the oldest verdict is the one evicted. A [`Vec`] rather than a map
    /// because [`CAPACITY`] entries is a scan of a few hundred bytes and a map would be a second
    /// structure to keep in step with the eviction order.
    known: Vec<(String, bool)>,
    /// Which round of questions the table is currently answering. See [`CommandValidity::record`].
    generation: u64,
}

impl CommandValidity {
    /// An empty table — every word unanswered, so nothing is painted as a typo.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            known: Vec::new(),
            generation: 0,
        }
    }

    /// Which round of questions this table is answering. A caller quotes it when it ASKS and hands
    /// it back with the answer.
    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    /// Records that the shell can (or cannot) find `word`, if `generation` is still the current
    /// one.
    ///
    /// ⚠️ **The generation is the whole reason a stale answer cannot un-invalidate the table.** The
    /// canonical case is the one the module doc opens with: `cargo install ripgrep` is typed, `rg`
    /// is asked about and comes back unresolved, and the answer lands AFTER the install ran.
    /// Without the guard that late answer refills the table the run had just emptied, and `rg`
    /// stays red until something else runs. With it, the answer belongs to a generation that no
    /// longer exists and is dropped — the caller re-asks against the empty table and gets the
    /// truth.
    ///
    /// A repeat answer for a word already held REPLACES it in place and keeps its position, so a
    /// re-ask cannot walk an entry to the front and evict something newer.
    pub fn record(&mut self, word: &str, resolves: bool, generation: u64) {
        if generation != self.generation {
            return;
        }
        if let Some(held) = self.known.iter_mut().find(|(held, _verdict)| held == word) {
            held.1 = resolves;
            return;
        }
        if self.known.len() >= CAPACITY {
            self.known.remove(0);
        }
        self.known.push((word.to_owned(), resolves));
    }

    /// What the host said about `word`, or `None` while nothing has.
    #[must_use]
    pub fn verdict(&self, word: &str) -> Option<bool> {
        self.known
            .iter()
            .find(|(held, _verdict)| held == word)
            .map(|&(_, verdict)| verdict)
    }

    /// Forgets everything and opens a new generation. See the module doc: this is what a command
    /// RUNNING does.
    ///
    /// The bump is not separable from the clear — a table emptied without one would accept the
    /// answers to the questions it just threw away — so there is one method and not two.
    pub fn clear(&mut self) {
        self.known.clear();
        self.generation = self.generation.wrapping_add(1);
    }
}

/// The command-position words of `document`, deduped, in the order they appear.
///
/// Every command position, not just the first: `git log | grep foo && ll` runs four things, and a
/// prompt that only checked the first would paint the other three as fine whatever they were.
/// [`crate::prompt::syntax`] already marks them all, including the one inside `$(…)`.
#[must_use]
pub fn command_words(document: &str, lexed: &Lexed) -> Vec<String> {
    let mut words: Vec<String> = Vec::new();
    for word in &lexed.words {
        if word.role != WordRole::Command {
            continue;
        }
        let Some(text) = document.get(word.range()) else {
            continue;
        };
        // A word that is not a plain literal is not a name the shell could be asked about:
        // `$EDITOR` and `"my cmd"` resolve only after an expansion this crate does not do,
        // and asking about the text as typed would paint a perfectly good line red.
        if text.is_empty() || !is_plain(text) || words.iter().any(|held| held == text) {
            continue;
        }
        words.push(text.to_owned());
    }
    words
}

/// The words of `document` that nothing has answered for yet — what to ask the host about.
#[must_use]
pub fn unanswered(document: &str, lexed: &Lexed, known: &CommandValidity) -> Vec<String> {
    command_words(document, lexed)
        .into_iter()
        .filter(|word| known.verdict(word).is_none())
        .collect()
}

/// `lexed`'s spans with every command name the shell could not find re-kinded to
/// [`TokenKind::UnknownCommand`].
///
/// An OVERLAY and not a lex: [`crate::prompt::syntax::lex`] stays a pure function of the text, and
/// the one kind that depends on a fact from off the machine is applied here, where that fact lives.
/// A word with no verdict yet is left alone — a prompt that flashed red for the 3 ms before the
/// answer landed would be worse than one that never coloured at all.
#[must_use]
pub fn overlaid(document: &str, lexed: &Lexed, known: &CommandValidity) -> Vec<SyntaxSpan> {
    let mut spans = lexed.spans.clone();
    for span in &mut spans {
        if span.kind != TokenKind::CommandName {
            continue;
        }
        let Some(text) = document.get(span.range()) else {
            continue;
        };
        if is_plain(text) && known.verdict(text) == Some(false) {
            span.kind = TokenKind::UnknownCommand;
        }
    }
    spans
}

/// Whether `word` is a literal name rather than something a shell would expand first.
///
/// Deliberately a refusal list and not an acceptance one: a filename may hold nearly anything, and
/// the characters that make a word NOT a plain name are the small closed set the shell acts on.
fn is_plain(word: &str) -> bool {
    !word.contains(['$', '`', '"', '\'', '\\', '*', '?', '~', '='])
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a test that asserts a span's shape has nothing to assert if the list is short"
    )]

    use super::{CAPACITY, CommandValidity, command_words, overlaid, unanswered};
    use crate::prompt::syntax::{TokenKind, lex};

    #[test]
    fn every_command_position_is_asked_about_not_just_the_first() {
        let line = "git log | grep foo && ll";
        let words = command_words(line, &lex(line));
        assert_eq!(
            words,
            vec!["git", "grep", "ll"],
            "three commands, `foo` is an argument"
        );
    }

    #[test]
    fn a_command_inside_a_substitution_counts_too() {
        let line = "echo $(date)";
        let words = command_words(line, &lex(line));
        assert!(words.contains(&"date".to_owned()), "`$(date)` runs `date`");
    }

    #[test]
    fn a_word_the_shell_would_expand_is_never_asked_about() {
        for line in ["$EDITOR file", "\"my cmd\" x", "~/bin/tool", "FOO=1"] {
            assert!(
                command_words(line, &lex(line)).is_empty(),
                "`{line}` has no literal command name to ask about",
            );
        }
    }

    #[test]
    fn the_same_word_twice_is_one_question() {
        let line = "git add . && git commit";
        assert_eq!(command_words(line, &lex(line)), vec!["git"]);
    }

    #[test]
    fn only_the_words_with_no_answer_are_asked_about() {
        let line = "git log | nope";
        let mut known = CommandValidity::new();
        known.record("git", true, known.generation());
        assert_eq!(unanswered(line, &lex(line), &known), vec!["nope"]);
    }

    #[test]
    fn only_a_word_the_shell_could_not_find_is_repainted() {
        let line = "git log | nope";
        let lexed = lex(line);
        let mut known = CommandValidity::new();
        known.record("git", true, known.generation());
        // `nope` has no verdict yet, so nothing is red while the answer is in flight.
        let waiting = overlaid(line, &lexed, &known);
        assert!(
            !waiting.iter().any(|span| span.kind == TokenKind::UnknownCommand),
            "an unanswered word is not a typo yet",
        );
        known.record("nope", false, known.generation());
        let answered = overlaid(line, &lexed, &known);
        let unknown: Vec<_> = answered
            .iter()
            .filter(|span| span.kind == TokenKind::UnknownCommand)
            .collect();
        assert_eq!(unknown.len(), 1, "exactly the one the shell could not find");
        assert_eq!(&line[unknown[0].range()], "nope");
    }

    #[test]
    fn a_repeat_answer_replaces_rather_than_re_queues() {
        let mut known = CommandValidity::new();
        known.record("first", false, known.generation());
        for index in 0..CAPACITY - 1 {
            known.record(&format!("filler{index}"), true, known.generation());
        }
        known.record("first", true, known.generation());
        // One more entry evicts the OLDEST, which is still `first` — the re-answer did not move it.
        known.record("last", true, known.generation());
        assert_eq!(
            known.verdict("first"),
            None,
            "the oldest went, re-answered or not"
        );
        assert_eq!(known.verdict("last"), Some(true));
    }

    #[test]
    fn a_run_forgets_everything_because_the_machine_may_have_moved() {
        let mut known = CommandValidity::new();
        known.record("rg", false, known.generation());
        known.clear();
        assert_eq!(known.verdict("rg"), None, "so the next line asks again");
    }

    #[test]
    fn an_answer_to_a_question_asked_before_the_run_is_dropped() {
        let mut known = CommandValidity::new();
        // `rg` was asked about while `cargo install ripgrep` was still being typed.
        let asked = known.generation();
        // …the install ran…
        known.clear();
        // …and only then did the answer land.
        known.record("rg", false, asked);
        assert_eq!(known.verdict("rg"), None, "the machine moved under that answer");
        known.record("rg", true, known.generation());
        assert_eq!(
            known.verdict("rg"),
            Some(true),
            "the re-ask is the one that counts"
        );
    }
}
