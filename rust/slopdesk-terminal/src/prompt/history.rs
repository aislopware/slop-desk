//! Command history: the store, the up/down walk, and the three readings that search it.
//!
//! Two types rather than one, because they have two lifetimes. [`CommandHistory`] outlives the
//! prompt and is what a session restores. [`HistoryWalk`] lives for as long as the user holds ↑ and
//! is thrown away the moment they type. Folding them together is how a draft gets lost: the draft
//! belongs to the walk, and clearing the walk has to be the same act as dropping it.
//!
//! ⌃R used to be a third — a `ReverseSearch` holding a query and a walk position — and it is gone.
//! See the ⌃R section below for what replaced it and why.
//!
//! ## Dedup is most-recent-wins, not first-wins
//!
//! Re-running `cargo test` moves it to the top rather than leaving it buried where it was first
//! typed. That is the behaviour of `zsh`'s `HIST_IGNORE_ALL_DUPS` and of every shell people
//! actually configure, and the alternative — keeping the older position — makes ↑ walk past
//! commands in an order that has nothing to do with when they were used.
//!
//! ## Prefix search is anchored at the CARET, not at the line
//!
//! ↑ from `git ` searches for commands starting `git `; ↑ from an empty line walks everything. The
//! prefix is the text BEFORE the caret, which makes the empty-prefix case fall out of the same rule
//! rather than being a special case, and lets a user park the caret mid-line to search by a prefix
//! shorter than what they typed. This is `zsh`'s `history-beginning-search-backward`, and the
//! difference from plain ↑ is exactly the one people notice when a shell does not have it.
//!
//! ## The autosuggestion is a FOURTH reading of the same store, and it holds no state
//!
//! The prior art was read before this was written, and two of its decisions are taken verbatim.
//! `zsh-autosuggestions` offers three strategies — `history` (the most recent match), `completion`
//! (what tab-completion would say) and `match_prev_cmd` — and ships `history` as the default;
//! [`CommandHistory::suggestion`] is that one, and the `completion` strategy would be a second
//! reading of [`crate::prompt::complete`], which already draws its own inline preview. `fish` puts
//! the accept on the INPUT FUNCTION rather than on the key — "`forward-char`: move one character to
//! the right; or if at the end of the commandline, accept" — which is exactly why
//! [`crate::prompt::keys::over_suggestion`] translates a MOTION and not a keystroke, and why `→`,
//! `End`, `⌃E` and `⌘→` all accept without any of them being named.
//!
//! [`CommandHistory::suggestion`] is what `zsh-autosuggestions` and `fish` draw past the caret, and
//! it is a plain function of (store, line) rather than a session like the two above it. That is the
//! whole reason it can be shown *unasked*: there is nothing to start, nothing to abandon, and no
//! position for an edit to invalidate — every keystroke simply asks again. A stateful suggestion
//! would have to be reset from every editing path, which is exactly the bug [`HistoryWalk`] exists
//! to contain, and there is no reason to pay it twice.
//!
//! ## ⌃R is a RANKED PANEL, and the substring walk it replaced is gone
//!
//! ⚠️ **THIS SECTION USED TO SAY THE OPPOSITE**, and the reversal is worth reading because the old
//! reason was sound about a thing that is no longer true. It read: "Completion ranks with fzf;
//! reverse search does not. ⌃R is thirty years of muscle memory for stepping back through the
//! commands containing this, where each press moves exactly one match older — a fuzzy re-rank would
//! reorder the walk under the user's fingers between two presses of the same key." That objection
//! is about re-ranking BETWEEN PRESSES, and it is fatal to fuzzy ranking behind a bash-style
//! `(reverse-i-search)` line, where one hit is visible and its neighbours are not: the list moves
//! and the user cannot see that it moved.
//!
//! A PANEL dissolves it. The ranking changes when the QUERY changes and at no other time; ⌃R and
//! the arrows move a selection down a list that is on screen, so nothing reorders under anyone's
//! fingers. And with the list visible, ranking is the whole value — `fzf`'s ⌃R, `atuin` and
//! `fish`'s own pager (3.6.0, whose 4.0 `git*HEAD` glob is out-of-order matching by another
//! spelling) all present ranked rows rather than one hit at a time, because the second-best match
//! is the one you wanted about as often as the best.
//!
//! So ⌃R now ranks with `slopdesk_fuzzy` through [`crate::prompt::complete::search_history`] — the
//! SAME scorer completion uses, which is what keeps this one implementation and not two searches
//! that disagree about case. Three consequences fell out of that and each deleted code:
//!  * `SearchHit` and its single matched `Range` are gone — a fuzzy match is a SET of scalar
//!    positions, which is what the candidate records already carry for the completion underline;
//!  * `ReverseSearch`, the walk position, is gone — the selected index in the panel is the
//!    position;
//!  * `find_smart_case` and its case-fold length arithmetic are gone — `slopdesk_fuzzy` folds 1:1
//!    by scalar precisely so a matched position stays valid against the original, which is the same
//!    problem solved once instead of twice.

/// How many commands the store keeps.
///
/// Bounded for the same reason [`crate::blocks`]'s ring is: an unbounded list grows for as long as
/// the session lives, and nobody has ever walked back past a thousand.
pub const CAPACITY: usize = 1000;

/// The commands that have been run, oldest first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandHistory {
    entries: Vec<String>,
    capacity: usize,
}

impl Default for CommandHistory {
    fn default() -> Self {
        Self::new()
    }
}

impl CommandHistory {
    /// An empty history holding up to [`CAPACITY`] commands.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            entries: Vec::new(),
            capacity: CAPACITY,
        }
    }

    /// An empty history with a different bound, for a caller that knows its own.
    ///
    /// A capacity of zero is honoured: nothing is ever recorded, which is the "private session"
    /// behaviour without a second flag to check everywhere.
    #[must_use]
    pub const fn bounded(capacity: usize) -> Self {
        Self {
            entries: Vec::new(),
            capacity,
        }
    }

    /// Restores a history, oldest first, applying the same dedup and bound a live session would.
    #[must_use]
    pub fn restored(entries: &[String], capacity: usize) -> Self {
        let mut history = Self::bounded(capacity);
        for entry in entries {
            history.record(entry);
        }
        history
    }

    /// The commands, oldest first.
    #[must_use]
    pub fn entries(&self) -> &[String] {
        &self.entries
    }

    /// How many there are.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether there are none.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The command at `index`, oldest first.
    #[must_use]
    pub fn get(&self, index: usize) -> Option<&str> {
        self.entries.get(index).map(String::as_str)
    }

    /// Records a command as the newest, moving an earlier copy rather than duplicating it.
    ///
    /// Blank commands are dropped: a bare Enter is not a command, and putting one in the history
    /// makes ↑ stop on nothing.
    pub fn record(&mut self, command: &str) {
        if command.trim().is_empty() || self.capacity == 0 {
            return;
        }
        if let Some(seen) = self.entries.iter().position(|entry| entry == command) {
            self.entries.remove(seen);
        }
        self.entries.push(command.to_owned());
        while self.entries.len() > self.capacity {
            self.entries.remove(0);
        }
    }

    /// Forgets everything.
    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// What the newest command starting with `line` would ADD to it — the autosuggestion.
    ///
    /// `zsh-autosuggestions`' and `fish`'s default strategy, and the reason it is a PREFIX match
    /// while ⌃R is a substring one and completion is fuzzy: this suggestion is shown *inline, at
    /// the caret, unasked*, so it has to be the one continuation the user could have predicted.
    /// A fuzzy hit rewrites what they already typed, and a substring hit puts text before the
    /// caret; either would make every keystroke move ink the user did not ask to move.
    ///
    /// Three refusals, each of which would otherwise draw a ghost that says nothing:
    ///  * an empty `line` — every entry matches, so the ghost would be "the last command you ran",
    ///    parked over an empty prompt that the user has not started;
    ///  * an entry EQUAL to `line` — there is nothing left to add, and `↹` on it inserts nothing;
    ///  * no match at all.
    ///
    /// Newest-first, so re-running a command promotes its own suggestion — the same
    /// most-recent-wins rule [`CommandHistory::record`] applies, read from the other end.
    ///
    /// The split is a char boundary by construction: `starts_with` matched, so `line.len()` is
    /// exactly where the matched prefix ends.
    ///
    /// ⚠️ **The length guard is FIRST, and that is what makes this affordable on a huge buffer.**
    /// `zsh-autosuggestions` needs a `ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE` knob (recommended 20) to
    /// stay out of the way of a long line; this needs none, because an entry shorter than
    /// `line` is rejected on a `usize` comparison and never reaches the byte-for-byte
    /// `starts_with`. A 10 MB paste therefore costs one comparison per entry rather than one
    /// per byte, which is why there is no maximum here to configure or to get wrong.
    #[must_use]
    pub fn suggestion(&self, line: &str) -> Option<&str> {
        if line.is_empty() {
            return None;
        }
        self.entries
            .iter()
            .rev()
            .find(|entry| entry.len() > line.len() && entry.starts_with(line))
            .and_then(|entry| entry.get(line.len()..))
    }
}

/// How much of `suggestion` one "accept a word" takes — its leading whitespace and the run after
/// it.
///
/// `fish`'s ⌥→, and the reason the whitespace goes WITH the word rather than before it: accepting a
/// word from ` --release --locked` has to land `` --release`` and leave the caret ready for the
/// next one, so the space that separates them belongs to the word being taken, not to the one
/// after.
///
/// A suggestion that is nothing but whitespace is taken whole — there is no word after it to stop
/// at, and answering zero would make the key dead on input that has something to give.
#[must_use]
pub fn suggestion_word_len(suggestion: &str) -> usize {
    let after_space = suggestion
        .char_indices()
        .find(|(_, ch)| !ch.is_whitespace())
        .map_or(suggestion.len(), |(at, _)| at);
    let rest = suggestion.get(after_space..).unwrap_or("");
    let word = rest
        .char_indices()
        .find(|(_, ch)| ch.is_whitespace())
        .map_or(rest.len(), |(at, _)| at);
    after_space.saturating_add(word)
}

/// What one step of the up/down walk answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Recalled {
    /// A history entry to put in the buffer.
    Entry {
        /// Its index in the store.
        index: usize,
        /// Its text.
        text: String,
    },
    /// The end of the walk: the half-typed line the user had before ↑, handed back verbatim.
    Draft(String),
}

impl Recalled {
    /// The text to put in the buffer either way.
    #[must_use]
    pub fn text(&self) -> &str {
        match self {
            Self::Entry { text, .. } | Self::Draft(text) => text,
        }
    }
}

/// The state of one ↑/↓ walk: the prefix it is filtered by, the draft it will restore, and where it
/// has got to.
///
/// `index == None` means no walk is in progress, which is the state every edit returns it to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HistoryWalk {
    prefix: String,
    draft: Option<String>,
    index: Option<usize>,
}

impl HistoryWalk {
    /// A walk that has not started.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            prefix: String::new(),
            draft: None,
            index: None,
        }
    }

    /// Whether ↑ has been pressed and ↓ still owes the user their draft back.
    #[must_use]
    pub const fn is_walking(&self) -> bool {
        self.index.is_some()
    }

    /// The prefix the walk is filtered by, for a UI that wants to show it.
    #[must_use]
    pub fn prefix(&self) -> &str {
        &self.prefix
    }

    /// Abandons the walk and the draft with it. Called by every edit — once the user has typed, the
    /// line they typed IS the draft.
    pub fn reset(&mut self) {
        self.prefix.clear();
        self.draft = None;
        self.index = None;
    }

    /// ↑ — one match older, capturing the draft and the prefix on the first press.
    ///
    /// `None` when there is no older match, which leaves the buffer exactly as it is: ↑ at the end
    /// of the history is a no-op, not a jump to nowhere.
    pub fn previous(&mut self, history: &CommandHistory, text: &str, cursor: usize) -> Option<Recalled> {
        if self.index.is_none() {
            text.get(..cursor).unwrap_or(text).clone_into(&mut self.prefix);
            self.draft = Some(text.to_owned());
        }
        let from = self.index.unwrap_or(history.len());
        let found = (0..from).rev().find(|index| self.matches(history, *index))?;
        self.index = Some(found);
        Some(Recalled::Entry {
            index: found,
            text: history.get(found).unwrap_or_default().to_owned(),
        })
    }

    /// ↓ — one match newer, and past the newest, the draft.
    ///
    /// `None` when no walk is in progress, so ↓ on a line nobody recalled does nothing rather than
    /// blanking it.
    pub fn next(&mut self, history: &CommandHistory) -> Option<Recalled> {
        let from = self.index?;
        let found = (from.saturating_add(1)..history.len()).find(|index| self.matches(history, *index));
        if let Some(index) = found {
            self.index = Some(index);
            return Some(Recalled::Entry {
                index,
                text: history.get(index).unwrap_or_default().to_owned(),
            });
        }
        let draft = self.draft.take().unwrap_or_default();
        self.reset();
        Some(Recalled::Draft(draft))
    }

    fn matches(&self, history: &CommandHistory, index: usize) -> bool {
        history
            .get(index)
            .is_some_and(|entry| entry.starts_with(&self.prefix))
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CommandHistory, HistoryWalk, Recalled, suggestion_word_len};

    fn seeded(commands: &[&str]) -> CommandHistory {
        let mut history = CommandHistory::new();
        for command in commands {
            history.record(command);
        }
        history
    }

    #[test]
    fn the_suggestion_is_the_newest_completion_of_what_is_typed() {
        let history = seeded(&["cargo build --release", "ls -la", "cargo test --lib"]);
        assert_eq!(history.suggestion("car"), Some("go test --lib"), "newest wins");
        assert_eq!(history.suggestion("cargo b"), Some("uild --release"));
        assert_eq!(history.suggestion("ls"), Some(" -la"));
        assert_eq!(history.suggestion("git"), None, "no entry starts that way");
    }

    /// The three refusals, each of which would draw a ghost that says nothing.
    #[test]
    fn a_suggestion_is_refused_when_it_would_add_nothing() {
        let history = seeded(&["ls -la"]);
        assert_eq!(
            history.suggestion(""),
            None,
            "an empty line is not a prefix worth matching"
        );
        assert_eq!(
            history.suggestion("ls -la"),
            None,
            "an exact hit has nothing left to add"
        );
        assert!(CommandHistory::new().suggestion("ls").is_none());
    }

    /// The split is taken at `line.len()`, so a multi-byte prefix must not cut a scalar.
    #[test]
    fn a_multibyte_prefix_splits_on_a_boundary() {
        let history = seeded(&["echo 'ước lượng'"]);
        assert_eq!(history.suggestion("echo 'ước"), Some(" lượng'"));
    }

    /// `zsh-autosuggestions` needs a buffer-size knob to survive this; the length guard is the
    /// knob.
    #[test]
    fn a_ten_megabyte_line_is_one_comparison_per_entry_not_one_per_byte() {
        let history = seeded(&["ls -la", "cargo test", "git status"]);
        let line = "x".repeat(10 * 1024 * 1024);
        assert_eq!(history.suggestion(&line), None);
    }

    #[test]
    fn one_word_of_a_suggestion_takes_the_space_in_front_of_it() {
        assert_eq!(suggestion_word_len(" --release --locked"), " --release".len());
        assert_eq!(suggestion_word_len("test --lib"), "test".len());
        // Nothing but whitespace is taken whole rather than answering a dead zero.
        assert_eq!(suggestion_word_len("   "), 3);
        assert_eq!(suggestion_word_len(""), 0);
    }

    #[test]
    fn a_repeat_moves_to_the_top_rather_than_duplicating() {
        let history = seeded(&["ls", "cargo test", "ls"]);
        assert_eq!(history.entries(), ["cargo test", "ls"]);
    }

    #[test]
    fn a_blank_command_is_never_recorded() {
        let history = seeded(&["", "   ", "\n", "ls"]);
        assert_eq!(history.entries(), ["ls"]);
    }

    #[test]
    fn the_store_is_bounded_and_drops_the_oldest() {
        let mut history = CommandHistory::bounded(2);
        for command in ["a", "b", "c"] {
            history.record(command);
        }
        assert_eq!(history.entries(), ["b", "c"]);
        // A zero capacity records nothing at all.
        let mut none = CommandHistory::bounded(0);
        none.record("a");
        assert!(none.is_empty());
    }

    #[test]
    fn up_walks_backwards_and_down_returns_the_draft() {
        let history = seeded(&["one", "two", "three"]);
        let mut walk = HistoryWalk::new();

        // The caret is at 0, so the prefix is empty and the walk sees everything.
        assert_eq!(walk.previous(&history, "dr", 0).unwrap().text(), "three");
        assert_eq!(walk.previous(&history, "ignored", 0).unwrap().text(), "two");
        assert_eq!(walk.previous(&history, "ignored", 0).unwrap().text(), "one");
        assert!(
            walk.previous(&history, "ignored", 0).is_none(),
            "the oldest is a wall"
        );

        assert_eq!(walk.next(&history).unwrap().text(), "two");
        assert_eq!(walk.next(&history).unwrap().text(), "three");
        assert_eq!(walk.next(&history), Some(Recalled::Draft("dr".to_owned())));
        assert!(!walk.is_walking());
        assert!(walk.next(&history).is_none(), "and down again does nothing");
    }

    #[test]
    fn up_from_a_partial_line_searches_by_that_prefix_and_gives_it_back() {
        let history = seeded(&["git status", "ls -la", "git commit"]);
        let mut walk = HistoryWalk::new();

        assert_eq!(walk.previous(&history, "git", 3).unwrap().text(), "git commit");
        assert_eq!(
            walk.previous(&history, "", 0).unwrap().text(),
            "git status",
            "`ls -la` is skipped"
        );
        assert!(walk.previous(&history, "", 0).is_none());
        assert_eq!(walk.next(&history).unwrap().text(), "git commit");
        assert_eq!(walk.next(&history), Some(Recalled::Draft("git".to_owned())));
    }

    #[test]
    fn the_prefix_is_the_text_before_the_caret_not_the_whole_line() {
        let history = seeded(&["git status", "gh pr list"]);
        let mut walk = HistoryWalk::new();
        // Caret after `g`, with ` status` still to its right: the search is by `g`.
        assert_eq!(
            walk.previous(&history, "g status", 1).unwrap().text(),
            "gh pr list"
        );
        assert_eq!(walk.prefix(), "g");
        // And the draft that comes back is the WHOLE line, not the prefix.
        walk.previous(&history, "", 0);
        walk.next(&history);
        assert_eq!(walk.next(&history), Some(Recalled::Draft("g status".to_owned())));
    }

    #[test]
    fn an_edit_abandons_the_walk_and_the_draft_with_it() {
        let history = seeded(&["one", "two"]);
        let mut walk = HistoryWalk::new();
        walk.previous(&history, "draft", 5);
        walk.reset();
        assert!(!walk.is_walking());
        assert!(walk.next(&history).is_none());
    }

    #[test]
    fn a_prefix_matching_nothing_leaves_the_line_alone() {
        let history = seeded(&["ls", "pwd"]);
        let mut walk = HistoryWalk::new();
        assert!(walk.previous(&history, "zzz", 3).is_none());
    }

    #[test]
    fn walking_an_empty_history_answers_nothing() {
        let history = CommandHistory::new();
        let mut walk = HistoryWalk::new();
        assert!(walk.previous(&history, "", 0).is_none());
    }

    #[test]
    fn a_restored_history_applies_the_same_rules_as_a_live_one() {
        let restored = CommandHistory::restored(
            &["a".to_owned(), "b".to_owned(), "a".to_owned(), String::new()],
            8,
        );
        assert_eq!(restored.entries(), ["b", "a"]);
    }
}
