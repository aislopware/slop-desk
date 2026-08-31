//! Command history: the store, the up/down walk, and reverse-incremental search.
//!
//! Three types rather than one, because they have three lifetimes. [`CommandHistory`] outlives the
//! prompt and is what a session restores. [`HistoryWalk`] lives for as long as the user holds ↑ and
//! is thrown away the moment they type. [`ReverseSearch`] lives for as long as ⌃R is up. Folding
//! them together is how a draft gets lost: the draft belongs to the walk, and clearing the walk has
//! to be the same act as dropping it.
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
//! ## ⌃R is a SUBSTRING match, and deliberately not the fuzzy matcher
//!
//! Completion ranks with fzf (see [`crate::prompt::complete`]); reverse search does not. ⌃R is
//! thirty years of muscle memory for "step back through the commands containing this", where each
//! press moves exactly one match older and the highlight sits on the literal run. A fuzzy re-rank
//! would reorder the walk under the user's fingers between two presses of the same key. Smart case
//! is the one modern concession: a lowercase query ignores case, an uppercase one does not.

use core::ops::Range;

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

/// A ⌃R hit: which entry, and where in it the query matched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    /// The entry's index in the store.
    pub index: usize,
    /// The entry's text.
    pub text: String,
    /// The matched byte run inside `text`, for the highlight.
    pub matched: Range<usize>,
}

/// An in-progress reverse-incremental search.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReverseSearch {
    query: String,
    /// Where the walk has got to. `None` before the first hit.
    index: Option<usize>,
}

impl ReverseSearch {
    /// A search with an empty query, which matches the newest entry.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            query: String::new(),
            index: None,
        }
    }

    /// The query so far.
    #[must_use]
    pub fn query(&self) -> &str {
        &self.query
    }

    /// Whether the query is empty, in which case the search shows the newest command rather than
    /// nothing.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.query.is_empty()
    }

    /// Sets the query and re-searches from the NEWEST entry.
    ///
    /// From the newest rather than from where the walk was, because the query changed: an
    /// incremental search that kept its position would skip matches the new query just made
    /// eligible, and the user would see the list jump backwards as they typed.
    pub fn refine(&mut self, history: &CommandHistory, query: &str) -> Option<SearchHit> {
        self.query.clear();
        self.query.push_str(query);
        self.index = None;
        self.step(history, history.len())
    }

    /// ⌃R again — one match older than the current one.
    ///
    /// `None` at the oldest match, which holds the current hit rather than wrapping. Wrapping is
    /// the one behaviour that makes a long search feel broken: the same command comes back and it
    /// is not obvious that it is the same one.
    pub fn again(&mut self, history: &CommandHistory) -> Option<SearchHit> {
        let from = self.index.unwrap_or(history.len());
        self.step(history, from)
    }

    /// The newest match strictly older than `before`.
    fn step(&mut self, history: &CommandHistory, before: usize) -> Option<SearchHit> {
        let found = (0..before).rev().find_map(|index| {
            let text = history.get(index)?;
            let matched = find_smart_case(text, &self.query)?;
            Some(SearchHit {
                index,
                text: text.to_owned(),
                matched,
            })
        })?;
        self.index = Some(found.index);
        Some(found)
    }
}

/// Where `needle` sits in `haystack`, case-insensitively unless the needle carries an uppercase
/// scalar — fzf's smart-case rule, so the one thing the two searches DO share is the case rule.
///
/// An empty needle matches at the start, which is what makes a fresh ⌃R show the newest command.
#[must_use]
pub fn find_smart_case(haystack: &str, needle: &str) -> Option<Range<usize>> {
    if needle.is_empty() {
        return Some(0..0);
    }
    if needle.chars().any(char::is_uppercase) {
        return haystack
            .find(needle)
            .map(|at| at..at.saturating_add(needle.len()));
    }
    // The search runs over the ORIGINAL bytes rather than over a lowercased copy, because folding
    // can change a string's length — `İ` folds to two scalars — and an offset found in the copy has
    // no exact preimage in the original. Highlighting the wrong run is the visible failure.
    haystack.char_indices().find_map(|(start, _)| {
        let tail = haystack.get(start..).unwrap_or("");
        folded_match_len(tail, needle).map(|len| start..start.saturating_add(len))
    })
}

/// How many bytes of `tail` a case-folded `needle` covers, or `None` if it does not start there.
///
/// A character whose fold is only PARTLY consumed by the needle is included whole, the same rule
/// [`crate::prompt::buffer::snap_up`] applies to a clipped cluster: a highlight over half of `İ` is
/// not a thing a renderer can draw.
fn folded_match_len(tail: &str, needle: &str) -> Option<usize> {
    let mut wanted = needle.chars().flat_map(char::to_lowercase);
    let mut next_wanted = wanted.next();
    let mut end = 0_usize;
    for (offset, ch) in tail.char_indices() {
        if next_wanted.is_none() {
            break;
        }
        for folded in ch.to_lowercase() {
            match next_wanted {
                None => break,
                Some(want) if want == folded => next_wanted = wanted.next(),
                Some(_) => return None,
            }
        }
        end = offset.saturating_add(ch.len_utf8());
    }
    next_wanted.is_none().then_some(end)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CommandHistory, HistoryWalk, Recalled, ReverseSearch, find_smart_case};

    fn seeded(commands: &[&str]) -> CommandHistory {
        let mut history = CommandHistory::new();
        for command in commands {
            history.record(command);
        }
        history
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
    fn reverse_search_steps_one_match_older_per_press() {
        let history = seeded(&["cargo build", "ls", "cargo test", "cargo test --lib"]);
        let mut search = ReverseSearch::new();

        let hit = search.refine(&history, "cargo").unwrap();
        assert_eq!(hit.text, "cargo test --lib");
        assert_eq!(hit.matched, 0..5);
        assert_eq!(search.again(&history).unwrap().text, "cargo test");
        assert_eq!(search.again(&history).unwrap().text, "cargo build");
        assert!(
            search.again(&history).is_none(),
            "the oldest match holds rather than wrapping"
        );
    }

    #[test]
    fn refining_the_query_restarts_from_the_newest() {
        let history = seeded(&["make all", "cargo test", "make docs"]);
        let mut search = ReverseSearch::new();
        search.refine(&history, "make").unwrap();
        search.again(&history).unwrap();
        // Typing another letter re-searches from the top rather than continuing the walk.
        let hit = search.refine(&history, "make d").unwrap();
        assert_eq!(hit.text, "make docs");
    }

    #[test]
    fn reverse_search_matches_a_substring_anywhere_not_a_prefix() {
        let history = seeded(&["git commit --amend"]);
        let mut search = ReverseSearch::new();
        let hit = search.refine(&history, "amend").unwrap();
        assert_eq!(&hit.text[hit.matched.clone()], "amend");
    }

    #[test]
    fn an_empty_query_shows_the_newest_command() {
        let history = seeded(&["a", "b"]);
        let mut search = ReverseSearch::new();
        assert!(search.is_empty());
        assert_eq!(search.refine(&history, "").unwrap().text, "b");
    }

    #[test]
    fn reverse_search_is_smart_case() {
        let history = seeded(&["Cargo test", "cargo build"]);
        let mut search = ReverseSearch::new();
        assert_eq!(search.refine(&history, "cargo").unwrap().text, "cargo build");
        assert_eq!(
            search.again(&history).unwrap().text,
            "Cargo test",
            "lowercase reaches both"
        );
        assert_eq!(
            search.refine(&history, "Cargo").unwrap().text,
            "Cargo test",
            "uppercase narrows"
        );
        assert!(search.again(&history).is_none());
    }

    #[test]
    fn a_case_fold_that_changes_length_still_reports_a_range_in_the_original() {
        // `İ` (U+0130) lowercases to two scalars, so a naive offset would be off by one byte.
        let found = find_smart_case("aİb", "i\u{307}").unwrap();
        assert_eq!(&"aİb"[found], "İ");
        assert!(find_smart_case("abc", "").unwrap().is_empty());
        assert!(find_smart_case("abc", "zz").is_none());
    }

    #[test]
    fn searching_an_empty_history_answers_nothing() {
        let history = CommandHistory::new();
        let mut search = ReverseSearch::new();
        assert!(search.refine(&history, "x").is_none());
        assert!(search.again(&history).is_none());
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
