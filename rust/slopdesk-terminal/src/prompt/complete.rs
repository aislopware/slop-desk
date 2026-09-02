//! Completion: source-agnostic candidates, ranked by the repo's one fuzzy matcher.
//!
//! ## The ranking is `slopdesk-fuzzy`'s, and writing a second one would be the bug
//!
//! `rust/slopdesk-fuzzy` is fzf's own `FuzzyMatchV2`, vendored rather than approximated precisely
//! so that every search field in this app orders candidates the same way — its own header calls the
//! order "muscle memory". A prompt is the fifth such field. Ranking it with anything else would
//! mean `gc` puts `git commit` first in the palette and somewhere else here, which is the one
//! difference a user would feel and never be able to explain. So this module contributes no scoring
//! of its own: it decides what the CANDIDATES and the QUERY are, and [`slopdesk_fuzzy::score`]
//! decides the order.
//!
//! ## Every candidate carries the range it replaces, and that is what makes the sources agnostic
//!
//! A path candidate replaces the word under the caret. A history candidate replaces the whole line.
//! A flag candidate replaces the word. If the engine owned one replacement rule, history could not
//! be a source at all — and a Warp-class prompt's best suggestion is usually the whole line you ran
//! yesterday. So the range comes from the candidate, and the QUERY falls out of it: whatever the
//! candidate would replace, up to the caret, is what it is matched against. One rule, and the
//! sources stop needing to agree about anything.
//!
//! ## Providers do no I/O, because this crate does none
//!
//! `lib.rs` guarantees "no clock and no I/O" — every answer here is a fold over bytes, so a
//! mis-completion is reproducible from a transcript. A provider that called `read_dir` would break
//! that for the whole crate. [`PathProvider`] therefore ranks over entries the CALLER supplies; the
//! directory read is the host's, on the host's thread, and what crosses is a list of names. The
//! trait is public so a caller can add a source this crate has never heard of without one appearing
//! here.

use core::ops::Range;

use crate::prompt::history::CommandHistory;
use crate::prompt::syntax::{Lexed, Unterminated, Word, WordRole, lex};

/// How many ranked candidates [`complete`] answers by default.
pub const LIMIT: usize = 50;

/// Whether the caret is inside a quote, which changes both the query and the candidate.
///
/// Completing inside `"my dir/fi` has to match against `my dir/fi` — the `"` is punctuation the
/// user typed to get a space, not a character of the filename — while the candidate it inserts has
/// to keep the quote, because the replacement covers the whole word including the opening one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Quoting {
    /// The caret is in a bare word.
    #[default]
    None,
    /// Inside `'…`.
    Single,
    /// Inside `"…`.
    Double,
}

impl Quoting {
    /// The quoting in force at the end of `typed`.
    ///
    /// Derived by lexing rather than by counting quotes, so it agrees with the highlight and with
    /// the submit rule — one scanner, one answer about what is open (see
    /// [`crate::prompt::syntax`]).
    #[must_use]
    pub fn of(typed: &str) -> Self {
        match lex(typed).unterminated {
            Unterminated::SingleQuote => Self::Single,
            Unterminated::DoubleQuote => Self::Double,
            _ => Self::None,
        }
    }

    /// `text` written so it survives this quoting context, opening quote included.
    ///
    /// The opening quote is part of it because the replacement range starts at the word's start,
    /// which is where that quote is — a candidate without it would delete the user's `"` and leave
    /// the closing one dangling.
    #[must_use]
    pub fn wrap(self, text: &str) -> String {
        match self {
            // A bare word only needs quoting when it holds something a shell would split on, and
            // the idiom for that is `slopdesk-ids`' — the one this app's every generated `cd` uses.
            Self::None => slopdesk_ids::shell_quoting::shlex_quoted(text),
            Self::Single => format!("'{}'", text.replace('\'', "'\\''")),
            // FOUR characters stay special inside double quotes, not two: a file literally named
            // `a$b` inserted with only `\` and `"` escaped would EXPAND when the line runs, and
            // one named ``a`b`` would substitute a command. This is the whole reason the
            // single-quote form is the default everywhere else in this app.
            Self::Double => {
                let escaped = text
                    .replace('\\', "\\\\")
                    .replace('"', "\\\"")
                    .replace('$', "\\$")
                    .replace('`', "\\`");
                format!("\"{escaped}\"")
            },
        }
    }
}

/// `typed` with its shell quoting removed — what a candidate is actually matched against.
///
/// Not a shell parser: it drops unescaped quotes and takes the character after a backslash
/// literally, which is exactly the transformation that turns what the user typed back into the
/// filename they mean.
#[must_use]
pub fn dequote(typed: &str) -> String {
    let mut out = String::with_capacity(typed.len());
    let mut chars = typed.chars();
    let mut single = false;
    let mut double = false;
    while let Some(ch) = chars.next() {
        match ch {
            '\'' if !double => single = !single,
            '"' if !single => double = !double,
            '\\' if !single => {
                if let Some(next) = chars.next() {
                    out.push(next);
                }
            },
            _ => out.push(ch),
        }
    }
    out
}

/// What kind of thing a candidate is — the tie-break when two score the same, and the icon a
/// renderer draws.
///
/// The declaration order IS the tie-break order: the more specific a source is about what belongs
/// at the caret, the earlier it sorts. A subcommand the caller declared beats a filename that
/// happens to fuzzy-match as well.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum CandidateKind {
    /// A subcommand of the command already typed — `commit` after `git`.
    Subcommand,
    /// A flag of that command.
    Flag,
    /// A directory.
    Directory,
    /// A file.
    Path,
    /// An environment variable name.
    Variable,
    /// A whole command line from the history.
    History,
}

/// One thing that could go at the caret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// What the candidate IS — the filename, the flag, the command line. Shown in the list, matched
    /// against, and what [`Ranked::positions`] indexes into.
    pub text: String,
    /// What actually replaces [`Candidate::replace`], which is [`Candidate::text`] written so a
    /// shell reads it back: `my file.txt` inserts as `'my file.txt'`.
    ///
    /// A separate field rather than a quoting pass at the insertion site, because the caret's
    /// quoting context is the PROVIDER's to know — it is the one that decided the range — and a
    /// consumer re-deriving it would be a second quoting implementation, which is the bug
    /// [`crate::prompt::syntax`]'s header exists to prevent.
    pub insert: String,
    /// What it is.
    pub kind: CandidateKind,
    /// An optional right-hand column — a flag's summary, a file's size, a history entry's exit
    /// code. Never matched against, only shown.
    pub detail: Option<String>,
    /// The byte range of the document this candidate would replace.
    pub replace: Range<usize>,
}

impl Candidate {
    /// A candidate that needs no quoting: it inserts exactly what it says.
    #[must_use]
    pub fn plain(text: String, kind: CandidateKind, replace: Range<usize>) -> Self {
        Self {
            insert: text.clone(),
            text,
            kind,
            detail: None,
            replace,
        }
    }
}

/// A candidate with its place in the order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ranked {
    /// The candidate.
    pub candidate: Candidate,
    /// fzf's score. Only ever compared, never interpreted.
    pub score: i32,
    /// Which scalars of [`Candidate::text`] the query matched, for the underline.
    pub positions: Vec<u32>,
}

/// Everything a provider is told about the caret.
///
/// A borrowed view rather than owned copies: a provider is called once per keystroke over a
/// document that may be megabytes, and cloning the line to ask a question about six characters of
/// it is the allocation that shows up in a latency trace.
#[derive(Debug, Clone)]
pub struct CompletionRequest<'a> {
    /// The whole document.
    pub text: &'a str,
    /// The caret's byte offset.
    pub cursor: usize,
    /// The shell word the caret is in, or an empty range at the caret when it is in whitespace.
    pub word: Range<usize>,
    /// That word's text.
    pub word_text: &'a str,
    /// What the word is doing — a command name, an argument, a redirection target.
    pub role: WordRole,
    /// The command name this word belongs to, when one has been typed. `git` for the caret in
    /// `git comm|`, `None` when the caret IS the command name.
    pub command: Option<&'a str>,
    /// Which quote, if any, the caret is inside — what a candidate has to be written to survive.
    pub quoting: Quoting,
}

impl CompletionRequest<'_> {
    /// The part of the word before the caret, verbatim — quotes and backslashes included.
    #[must_use]
    pub fn typed(&self) -> &str {
        self.text
            .get(self.word.start..self.cursor.max(self.word.start))
            .unwrap_or("")
    }

    /// The same run with its shell quoting removed — what the user MEANS, and what a
    /// prefix-shaped source filters on.
    #[must_use]
    pub fn typed_literal(&self) -> String {
        dequote(self.typed())
    }
}

/// A source of candidates.
///
/// `Debug` is a supertrait because the editor holds providers in its own `Debug` state and this
/// crate denies `missing_debug_implementations` — a provider that could not be printed would make
/// the whole editor unprintable.
pub trait CandidateProvider: core::fmt::Debug {
    /// The candidates this source offers at the caret, unranked and in any order.
    fn candidates(&self, request: &CompletionRequest<'_>) -> Vec<Candidate>;
}

/// Ranks every provider's candidates for the caret and answers the best `limit` of them.
///
/// The query is derived per candidate — the text it would replace, up to the caret — which is what
/// lets a whole-line history candidate and a one-word path candidate compete in the same list
/// without either source knowing about the other.
#[must_use]
pub fn complete(
    text: &str,
    cursor: usize,
    providers: &[&dyn CandidateProvider],
    limit: usize,
) -> Vec<Ranked> {
    let lexed = lex(text);
    let request = request_for(text, cursor, &lexed);
    let mut ranked: Vec<Ranked> = Vec::new();
    for provider in providers {
        for candidate in provider.candidates(&request) {
            // The query is what the candidate would replace, up to the caret, with its shell
            // quoting taken back off — `"my fi` matches `my file.txt` rather than failing on the
            // quote the user typed to get a space.
            let raw = text
                .get(candidate.replace.start..cursor.max(candidate.replace.start))
                .unwrap_or("");
            let query = dequote(raw);
            let Some(found) = slopdesk_fuzzy::score(&query, &candidate.text) else {
                continue;
            };
            // A candidate identical to what is already typed is not a suggestion.
            if candidate.text == query {
                continue;
            }
            ranked.push(Ranked {
                candidate,
                score: found.score,
                positions: found.positions,
            });
        }
    }
    ranked.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then(left.candidate.kind.cmp(&right.candidate.kind))
            .then_with(|| left.candidate.text.cmp(&right.candidate.text))
    });
    ranked.dedup_by(|left, right| {
        left.candidate.text == right.candidate.text && left.candidate.replace == right.candidate.replace
    });
    ranked.truncate(limit);
    ranked
}

/// What the providers are told, derived from one lex of the document.
fn request_for<'a>(text: &'a str, cursor: usize, lexed: &Lexed) -> CompletionRequest<'a> {
    let word = lexed.word_at(cursor).map_or(cursor..cursor, Word::range);
    let role = lexed.role_at(cursor);
    // The command this word belongs to is the nearest Command-role word at or before the caret,
    // and only when it is not the word being completed.
    let command = lexed
        .words
        .iter()
        .rev()
        .find(|candidate| {
            candidate.role == WordRole::Command && candidate.end <= word.start && candidate.start < word.start
        })
        .and_then(|found| text.get(found.range()));
    let typed = text.get(word.start..cursor.max(word.start)).unwrap_or("");
    CompletionRequest {
        text,
        cursor,
        word_text: text.get(word.clone()).unwrap_or(""),
        word,
        role,
        command,
        quoting: Quoting::of(typed),
    }
}

/// Whole command lines from the history, replacing the line up to and including the caret's tail.
///
/// The replacement is the WHOLE document, not the word: accepting `cargo test --lib` after typing
/// `car` should not leave a stray `go test` behind. That also makes the query the whole typed line,
/// which is why `car t` finds `cargo test` — fzf matches out of order, and a shell history is the
/// one place that is what you want.
#[derive(Debug, Clone, Copy)]
pub struct HistoryProvider<'a> {
    history: &'a CommandHistory,
}

impl<'a> HistoryProvider<'a> {
    /// Offers `history`'s entries, newest first.
    #[must_use]
    pub const fn new(history: &'a CommandHistory) -> Self {
        Self { history }
    }
}

/// What a ⌃R query found: the rows that fit, and how many there were.
///
/// The two are separate because they answer different questions and only one of them can be seen.
/// `ranked` is capped so a thousand-entry history cannot cross the FFI on every keystroke;
/// `matched` is the total, which the panel's own row prints precisely BECAUSE the panel cannot show
/// it. A truncated list looks exactly like a complete one, so a count taken from `ranked.len()`
/// would report the cap back to the user as if it were the answer.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HistorySearch {
    /// The best `limit` matches, best first.
    pub ranked: Vec<Ranked>,
    /// How many entries matched at all, `ranked.len()` or more.
    pub matched: usize,
}

/// The ⌃R panel: every history entry `query` matches, best first, at most `limit` of them.
///
/// **Not a [`CandidateProvider`], and not [`complete`] with one source.** Both of those are
/// functions of the CARET — the query is what the candidate would replace up to the cursor — and a
/// reverse search has no caret in it at all: the query is typed into the search, the document is
/// untouched while it runs, and the whole line is what an accept replaces. Routing it through
/// [`complete`] would mean lying about the cursor to get the right query out.
///
/// What it DOES share is the scorer, which is the part that matters: `gc` orders `git commit`
/// against `git checkout` here exactly as it does in the completion list and in the command
/// palette. The records are [`Ranked`] for the same reason — the panel is drawn by the same view
/// code, and the `positions` are the same underline.
///
/// **The query is `fzf`'s EXTENDED-SEARCH syntax, and this is the one place in the app that reads
/// it.** `git !push ^g` means what it looks like — see [`slopdesk_fuzzy::Pattern`]. It belongs here
/// and not in [`complete`] because a search field is a place to write a QUERY, while a completion's
/// query is real shell text in which `^`, `$`, `!` and `|` already mean four other things.
///
/// **The tie-break is RECENCY, and that is the one place this diverges from [`complete`].** Equal
/// scores keep the order they arrive in — `sort_by` is stable — and they arrive newest-first, so
/// two commands that match a query equally well are offered most-recent-first. [`complete`] breaks
/// the same tie alphabetically, which is right for a list of filenames and wrong for a history: a
/// shell history's second axis is time, and `zsh`'s own `HIST_IGNORE_ALL_DUPS` order (see
/// [`CommandHistory::record`]) exists to make it so.
///
/// An empty query answers the newest `limit` entries rather than nothing: it parses to a `Pattern`
/// with no term sets at all, and a pattern that demands nothing matches everything at score 0 with
/// no positions. So a freshly opened ⌃R is the recent-commands panel `fzf` and `atuin` both open
/// with, and it falls out of the same code path rather than being a special case here.
/// `document_len` is how much an accept replaces — the whole draft, always, because a history entry
/// is a whole command line and there is no caret in a search to anchor anything narrower.
#[must_use]
pub fn search_history(
    history: &CommandHistory,
    query: &str,
    limit: usize,
    document_len: usize,
) -> HistorySearch {
    // Parsed ONCE for the whole history, which is the split [`slopdesk_fuzzy::Pattern`] exists for:
    // every ⌃R keystroke re-ranks every entry, and a parse per entry would be the same tiny work
    // done a thousand times over.
    let pattern = slopdesk_fuzzy::Pattern::parse(query);
    let mut ranked: Vec<Ranked> = history
        .entries()
        .iter()
        .rev()
        .filter_map(|entry| {
            let found = pattern.score(entry)?;
            Some(Ranked {
                // A history entry is quoted the way the user wrote it, so it inserts verbatim —
                // `HistoryProvider`'s rule, for its reason.
                candidate: Candidate::plain(entry.clone(), CandidateKind::History, 0..document_len),
                score: found.score,
                positions: found.positions,
            })
        })
        .collect();
    // By the NEGATED score rather than `sort_by`, so the stable sort keeps the newest-first
    // order equal scores arrived in — which is the recency tie-break this function exists for.
    ranked.sort_by_key(|hit| -hit.score);
    // Counted BEFORE the cut, which is the whole reason the count is carried separately.
    let matched = ranked.len();
    ranked.truncate(limit);
    HistorySearch { ranked, matched }
}

impl CandidateProvider for HistoryProvider<'_> {
    fn candidates(&self, request: &CompletionRequest<'_>) -> Vec<Candidate> {
        // A caret in the middle of a line is editing, not composing: replacing the whole document
        // from there would throw away the tail the user deliberately left.
        if request.cursor < request.text.len() {
            return Vec::new();
        }
        // Every entry is handed over unscored, clone and all, and that is deliberate rather than
        // a missed `search_history`: the query a candidate is matched against is derived by
        // [`complete`] from the span it replaces (`dequote` of the text up to the caret), so a
        // pre-filter here would be a second spelling of that rule — and the ranker scores every
        // survivor anyway, so it would run the DP twice per entry to save a clone the DP already
        // dwarfs. `search_history` scores `&str` first because it IS the ranker for ⌃R.
        self.history
            .entries()
            .iter()
            .rev()
            // A history entry is a whole command line, already quoted the way the user wrote it, so
            // it inserts verbatim — quoting it again would run `'ls -la'` as one program.
            .map(|entry| Candidate::plain(entry.clone(), CandidateKind::History, 0..request.text.len()))
            .collect()
    }
}

/// One entry of a directory the caller already read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathEntry {
    /// The file's name, without any directory part.
    pub name: String,
    /// Whether it is a directory — which decides both the kind and the trailing slash.
    pub directory: bool,
}

/// Filesystem names, ranked against the word under the caret.
///
/// `base` is the leading part of the word that names the directory the entries came from — `src/`
/// for a caret in `src/ma`. It is prepended to every candidate so the replacement is the whole word
/// and the caller never has to splice two halves back together.
#[derive(Debug, Clone, Copy)]
pub struct PathProvider<'a> {
    base: &'a str,
    entries: &'a [PathEntry],
}

impl<'a> PathProvider<'a> {
    /// Offers `entries`, read by the caller from the directory `base` names.
    #[must_use]
    pub const fn new(base: &'a str, entries: &'a [PathEntry]) -> Self {
        Self { base, entries }
    }
}

impl CandidateProvider for PathProvider<'_> {
    fn candidates(&self, request: &CompletionRequest<'_>) -> Vec<Candidate> {
        self.entries
            .iter()
            .map(|entry| {
                let mut text = self.base.to_owned();
                text.push_str(&entry.name);
                if entry.directory {
                    text.push('/');
                }
                Candidate {
                    insert: request.quoting.wrap(&text),
                    text,
                    kind: if entry.directory {
                        CandidateKind::Directory
                    } else {
                        CandidateKind::Path
                    },
                    detail: None,
                    replace: request.word.clone(),
                }
            })
            .collect()
    }
}

/// What a caller knows about one command: its name, its subcommands and its flags.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CommandSpec {
    /// The command's name, matched against the word in command position.
    pub name: String,
    /// Its subcommands, offered for the word right after it.
    pub subcommands: Vec<String>,
    /// Its flags, offered for any word beginning with `-`.
    pub flags: Vec<String>,
}

/// Command names, their subcommands and their flags, from a table the caller owns.
///
/// A table rather than a `--help` scrape for the same reason [`PathProvider`] takes entries:
/// running anything is I/O, and this crate does none. The host may build the table however it
/// likes.
#[derive(Debug, Clone, Copy)]
pub struct CommandProvider<'a> {
    specs: &'a [CommandSpec],
}

impl<'a> CommandProvider<'a> {
    /// Offers the commands in `specs`.
    #[must_use]
    pub const fn new(specs: &'a [CommandSpec]) -> Self {
        Self { specs }
    }
}

impl CandidateProvider for CommandProvider<'_> {
    fn candidates(&self, request: &CompletionRequest<'_>) -> Vec<Candidate> {
        if request.role == WordRole::Command {
            return self
                .specs
                .iter()
                .map(|spec| {
                    Candidate::plain(spec.name.clone(), CandidateKind::Subcommand, request.word.clone())
                })
                .collect();
        }
        let Some(spec) = request
            .command
            .and_then(|name| self.specs.iter().find(|spec| spec.name == name))
        else {
            return Vec::new();
        };
        // A word that already starts with `-` is asking for flags and nothing else; anything else
        // gets the subcommands. Offering both always is how a list of forty flags buries the two
        // subcommands anybody wanted.
        let wants_flags = request.typed_literal().starts_with('-');
        let source = if wants_flags {
            &spec.flags
        } else {
            &spec.subcommands
        };
        let kind = if wants_flags {
            CandidateKind::Flag
        } else {
            CandidateKind::Subcommand
        };
        source
            .iter()
            .map(|text| Candidate::plain(text.clone(), kind, request.word.clone()))
            .collect()
    }
}

/// Environment variable names, offered for a word the caret has typed a `$` into.
#[derive(Debug, Clone, Copy)]
pub struct VariableProvider<'a> {
    names: &'a [String],
}

impl<'a> VariableProvider<'a> {
    /// Offers `names`, which the caller reads from the environment it is about to run in.
    #[must_use]
    pub const fn new(names: &'a [String]) -> Self {
        Self { names }
    }
}

impl CandidateProvider for VariableProvider<'_> {
    fn candidates(&self, request: &CompletionRequest<'_>) -> Vec<Candidate> {
        // The `$` is found in what has been TYPED, not in the whole word: `$HO|ME` completes `$HO`.
        let typed = request.typed();
        let Some(dollar) = typed.rfind('$') else {
            return Vec::new();
        };
        let start = request.word.start.saturating_add(dollar);
        self.names
            .iter()
            // A `$NAME` inserts verbatim: quoting it would be exactly wrong, since single quotes
            // are what STOP the shell expanding it.
            .map(|name| {
                Candidate::plain(
                    format!("${name}"),
                    CandidateKind::Variable,
                    start..request.word.end,
                )
            })
            .collect()
    }
}

// MARK: - The user's own shell

/// One thing the user's own shell completion would insert.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ShellSuggestion {
    /// The literal that would replace its group's prefix and suffix, affixes already composed in.
    pub text: String,
    /// The right-hand column the completion function offered, if it offered one.
    pub detail: Option<String>,
    /// Whether the text already carries its own shell quoting.
    pub verbatim: bool,
}

/// One `compadd` call's worth of suggestions, and the text they replace.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ShellGroup {
    /// The text BEFORE the caret that accepting one of these replaces.
    pub prefix: String,
    /// The text AFTER the caret that it replaces.
    pub suffix: String,
    /// What the call offered.
    pub suggestions: Vec<ShellSuggestion>,
}

/// The candidates the user's OWN shell reported, seeded by whoever ran the round trip.
///
/// This crate does no IO by contract, and the shell bridge is the most IO a source in this app has:
/// a captive interactive zsh, a pty, a deadline. So the split is the same one every other source
/// here makes — the caller does the asking, this ranks the answer — except that the answer arrives
/// LATE, after the keystroke that provoked it. That is what the group's `prefix` is for.
///
/// ## Staleness is checked, never assumed
/// A group is offered only when the live document still ENDS in the prefix the shell answered
/// about. A round trip is tens of milliseconds and a fast typist moves in that window, so the
/// alternative — trusting an offset the host computed against a buffer that has since changed —
/// deletes characters the user typed after asking. Skipping the group instead costs one stale
/// list, which the next keystroke replaces anyway.
#[derive(Debug, Default)]
pub struct ShellProvider {
    groups: Vec<ShellGroup>,
}

impl ShellProvider {
    /// Ranks `groups`, which is one shell answer.
    #[must_use]
    pub const fn new(groups: Vec<ShellGroup>) -> Self {
        Self { groups }
    }

    /// What kind of thing the shell reported, read off its SHAPE.
    ///
    /// zsh does not label its matches — a completion function's answers are strings, and the
    /// function that produced them knows what they are but does not say. The shape is what is left,
    /// and it decides only the icon and the tie-break between two equal scores, never what gets
    /// inserted. Guessing wrong costs a wrong glyph.
    fn kind_of(text: &str) -> CandidateKind {
        if text.starts_with('-') {
            CandidateKind::Flag
        } else if text.ends_with('/') {
            CandidateKind::Directory
        } else if text.contains('/') {
            CandidateKind::Path
        } else {
            CandidateKind::Subcommand
        }
    }
}

impl CandidateProvider for ShellProvider {
    fn candidates(&self, request: &CompletionRequest<'_>) -> Vec<Candidate> {
        let before = request.text.get(..request.cursor).unwrap_or("");
        let after = request.text.get(request.cursor..).unwrap_or("");
        let mut out = Vec::new();
        for group in &self.groups {
            // The staleness gate. An empty prefix matches every document, which is correct: it is
            // what a caret at a word boundary reports, and there is nothing there to have changed.
            if !before.ends_with(&group.prefix) {
                continue;
            }
            let start = request.cursor.saturating_sub(group.prefix.len());
            // The suffix is honoured only when it is actually still there. zsh reports it as the
            // text an accept would swallow, and swallowing text the document no longer has would
            // eat whatever moved into its place.
            let end = if after.starts_with(&group.suffix) {
                request.cursor.saturating_add(group.suffix.len())
            } else {
                request.cursor
            };
            for suggestion in &group.suggestions {
                // `-Q` says the shell would insert this verbatim, and it says so for a BARE caret —
                // that is the context a completion function writes its escapes for. Inside a quote
                // the replacement range starts at the opening quote, so the candidate has to carry
                // one, and this crate's quoter is the only thing that knows which.
                let insert = if suggestion.verbatim && request.quoting == Quoting::None {
                    suggestion.text.clone()
                } else {
                    request.quoting.wrap(&suggestion.text)
                };
                out.push(Candidate {
                    kind: Self::kind_of(&suggestion.text),
                    text: suggestion.text.clone(),
                    insert,
                    detail: suggestion.detail.clone(),
                    replace: start..end,
                });
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        CandidateKind, CandidateProvider, CommandProvider, CommandSpec, HistoryProvider, PathEntry,
        PathProvider, ShellGroup, ShellProvider, ShellSuggestion, VariableProvider, complete,
    };
    use crate::prompt::history::CommandHistory;

    fn entries(names: &[(&str, bool)]) -> Vec<PathEntry> {
        names
            .iter()
            .map(|(name, directory)| {
                PathEntry {
                    name: (*name).to_owned(),
                    directory: *directory,
                }
            })
            .collect()
    }

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    fn git() -> Vec<CommandSpec> {
        vec![
            CommandSpec {
                name: "git".to_owned(),
                subcommands: strings(&["commit", "checkout", "status"]),
                flags: strings(&["--amend", "--all"]),
            },
            CommandSpec {
                name: "grep".to_owned(),
                subcommands: Vec::new(),
                flags: strings(&["--color"]),
            },
        ]
    }

    #[test]
    fn a_path_candidate_replaces_the_word_and_a_history_one_replaces_the_line() {
        let mut history = CommandHistory::new();
        history.record("cargo test --lib");
        let files = entries(&[("target", true)]);

        let line = "cargo t";
        let found = complete(
            line,
            line.len(),
            &[&HistoryProvider::new(&history), &PathProvider::new("", &files)],
            10,
        );

        let history_hit = found
            .iter()
            .find(|hit| hit.candidate.kind == CandidateKind::History)
            .unwrap();
        assert_eq!(history_hit.candidate.replace, 0..line.len());
        let path_hit = found
            .iter()
            .find(|hit| hit.candidate.kind == CandidateKind::Directory)
            .unwrap();
        assert_eq!(path_hit.candidate.replace, 6..7, "just the word `t`");
    }

    #[test]
    fn a_path_candidate_carries_the_directory_it_came_from() {
        let files = entries(&[("main.rs", false), ("bin", true)]);
        let line = "cat src/ma";
        let found = complete(line, line.len(), &[&PathProvider::new("src/", &files)], 10);

        assert_eq!(found[0].candidate.text, "src/main.rs");
        assert_eq!(
            found[0].candidate.replace,
            4..10,
            "the whole word, slash included"
        );
        assert_eq!(found[0].candidate.kind, CandidateKind::Path);
        // `src/bin/` does not contain the subsequence `src/ma`, so fzf drops it entirely — which
        // is the point of ranking with a real matcher rather than a prefix test.
        assert!(found.iter().all(|hit| hit.candidate.text != "src/bin/"));
    }

    #[test]
    fn the_command_position_offers_commands_and_the_next_word_offers_subcommands() {
        let specs = git();
        let provider = CommandProvider::new(&specs);

        let found = complete("gi", 2, &[&provider], 10);
        assert_eq!(found[0].candidate.text, "git");
        assert_eq!(found[0].candidate.replace, 0..2);

        let found = complete("git comm", 8, &[&provider], 10);
        assert_eq!(found[0].candidate.text, "commit");
        assert_eq!(found[0].candidate.replace, 4..8);
        assert_eq!(found[0].candidate.kind, CandidateKind::Subcommand);
    }

    #[test]
    fn a_word_starting_with_a_dash_gets_flags_and_nothing_else() {
        let specs = git();
        let found = complete("git --am", 8, &[&CommandProvider::new(&specs)], 10);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].candidate.text, "--amend");
        assert_eq!(found[0].candidate.kind, CandidateKind::Flag);
    }

    #[test]
    fn the_command_a_word_belongs_to_is_the_one_before_it_not_the_word_itself() {
        let specs = git();
        // The caret is on `git` itself, so the subcommands must NOT fire.
        let found = complete("git", 3, &[&CommandProvider::new(&specs)], 10);
        assert!(found.iter().all(|hit| hit.candidate.text != "commit"));
        // Inside a pipeline the nearest command wins.
        let found = complete("git status | gre", 16, &[&CommandProvider::new(&specs)], 10);
        assert_eq!(found[0].candidate.text, "grep");
    }

    #[test]
    fn a_variable_replaces_from_its_dollar_not_from_the_word() {
        let names = strings(&["HOME", "HOSTNAME"]);
        let line = "echo x$HO";
        let found = complete(line, line.len(), &[&VariableProvider::new(&names)], 10);

        assert_eq!(found[0].candidate.text, "$HOME");
        assert_eq!(found[0].candidate.replace, 6..9, "from the `$`, keeping the `x`");
        assert_eq!(found[1].candidate.text, "$HOSTNAME");
    }

    #[test]
    fn a_word_with_no_dollar_offers_no_variables() {
        let names = strings(&["HOME"]);
        assert!(complete("echo HO", 7, &[&VariableProvider::new(&names)], 10).is_empty());
    }

    #[test]
    fn ranking_is_fzfs_so_a_subsequence_beats_a_late_substring() {
        let specs = vec![
            CommandSpec {
                name: "getConfig".to_owned(),
                subcommands: Vec::new(),
                flags: Vec::new(),
            },
            CommandSpec {
                name: "gymnastic".to_owned(),
                subcommands: Vec::new(),
                flags: Vec::new(),
            },
        ];
        let found = complete("gc", 2, &[&CommandProvider::new(&specs)], 10);
        assert_eq!(
            found[0].candidate.text, "getConfig",
            "the camel boundary wins, as in fzf"
        );
    }

    #[test]
    fn a_candidate_identical_to_what_is_typed_is_not_offered() {
        let specs = git();
        let found = complete("git", 3, &[&CommandProvider::new(&specs)], 10);
        assert!(found.iter().all(|hit| hit.candidate.text != "git"));
    }

    #[test]
    fn a_caret_in_the_middle_of_a_line_gets_no_whole_line_history() {
        let mut history = CommandHistory::new();
        history.record("cargo test");
        // The caret is before ` --lib`, which the user typed on purpose.
        assert!(complete("car --lib", 3, &[&HistoryProvider::new(&history)], 10).is_empty());
    }

    #[test]
    fn an_empty_line_offers_everything_a_source_has() {
        let mut history = CommandHistory::new();
        history.record("ls -la");
        history.record("pwd");
        let found = complete("", 0, &[&HistoryProvider::new(&history)], 10);
        assert_eq!(
            found.len(),
            2,
            "an empty query matches everything, in source order"
        );
    }

    #[test]
    fn the_limit_is_honoured() {
        let names: Vec<String> = (0..200).map(|index| format!("VAR{index}")).collect();
        let found = complete("$V", 2, &[&VariableProvider::new(&names)], 7);
        assert_eq!(found.len(), 7);
    }

    #[test]
    fn completion_inside_a_quote_matches_the_unquoted_text_and_reinserts_the_quote() {
        let files = entries(&[("my file.txt", false)]);
        let line = "cat \"my fi";
        let found = complete(line, line.len(), &[&PathProvider::new("", &files)], 10);

        assert_eq!(found[0].candidate.replace, 4..10, "the quote is part of the word");
        assert_eq!(
            found[0].candidate.text, "my file.txt",
            "matched without the quote"
        );
        assert_eq!(found[0].candidate.insert, "\"my file.txt\"", "reinserted with it");
    }

    #[test]
    fn a_bare_name_with_a_space_is_quoted_on_the_way_in_and_a_safe_one_is_not() {
        let files = entries(&[("my file.txt", false), ("plain.txt", false)]);
        let found = complete("cat ", 4, &[&PathProvider::new("", &files)], 10);

        let spaced = found
            .iter()
            .find(|hit| hit.candidate.text == "my file.txt")
            .unwrap();
        assert_eq!(spaced.candidate.insert, "'my file.txt'");
        let plain = found
            .iter()
            .find(|hit| hit.candidate.text == "plain.txt")
            .unwrap();
        assert_eq!(plain.candidate.insert, "plain.txt", "nothing a shell splits on");
    }

    #[test]
    fn a_backslash_escaped_space_reads_as_part_of_the_name() {
        let files = entries(&[("my file.txt", false)]);
        let line = "cat my\\ fi";
        let found = complete(line, line.len(), &[&PathProvider::new("", &files)], 10);
        assert_eq!(found[0].candidate.text, "my file.txt");
        assert_eq!(super::dequote("my\\ fi"), "my fi");
        assert_eq!(
            super::dequote("'a\"b'"),
            "a\"b",
            "a quote inside the other kind is literal"
        );
        assert_eq!(
            super::dequote("'a\\b'"),
            "a\\b",
            "and a backslash in single quotes is too"
        );
    }

    #[test]
    fn a_double_quoted_candidate_escapes_everything_the_shell_would_still_read() {
        // A name is DATA. Inside `"…"` a shell still expands `$` and still substitutes a backtick,
        // so a candidate that only escaped `\` and `"` would hand the user a line that runs
        // something when they press Enter — the completion writing the command, not the user.
        assert_eq!(super::Quoting::Double.wrap("a$b"), "\"a\\$b\"");
        assert_eq!(super::Quoting::Double.wrap("a`b`c"), "\"a\\`b\\`c\"");
        assert_eq!(super::Quoting::Double.wrap("a\"b"), "\"a\\\"b\"");
        assert_eq!(
            super::Quoting::Double.wrap("a\\$b"),
            "\"a\\\\\\$b\"",
            "the backslash is escaped first, so it does not eat the dollar's new one"
        );
        // The other two contexts have nothing to expand: single quotes are literal, and a bare word
        // gets the app's one shared quoter rather than a second opinion.
        assert_eq!(super::Quoting::Single.wrap("a$b"), "'a$b'");
        assert_eq!(
            super::Quoting::None.wrap("a$b"),
            slopdesk_ids::shell_quoting::shlex_quoted("a$b")
        );
    }

    #[test]
    fn a_history_candidate_is_never_re_quoted() {
        let mut history = CommandHistory::new();
        history.record("ls -la 'my dir'");
        let found = complete("ls", 2, &[&HistoryProvider::new(&history)], 10);
        assert_eq!(found[0].candidate.insert, "ls -la 'my dir'");
    }

    #[test]
    fn a_variable_is_never_quoted_because_quoting_is_what_stops_it_expanding() {
        let names = strings(&["HOME"]);
        let found = complete("echo $H", 7, &[&VariableProvider::new(&names)], 10);
        assert_eq!(found[0].candidate.insert, "$HOME");
    }

    #[test]
    fn a_provider_that_offers_nothing_is_not_an_error() {
        let empty: Vec<PathEntry> = Vec::new();
        let providers: [&dyn CandidateProvider; 1] = [&PathProvider::new("", &empty)];
        assert!(complete("ls ", 3, &providers, 10).is_empty());
    }

    #[test]
    fn a_caret_past_the_end_of_the_document_does_not_panic() {
        let names = strings(&["HOME"]);
        let found = complete("echo $H", 9_999, &[&VariableProvider::new(&names)], 10);
        assert!(found.iter().all(|hit| hit.candidate.replace.end <= 7));
    }

    /// One suggestion, spelled the way the shell reported it.
    fn suggestion(text: &str, verbatim: bool) -> ShellSuggestion {
        ShellSuggestion {
            text: String::from(text),
            detail: None,
            verbatim,
        }
    }

    /// The whole reason the group carries a PREFIX rather than an offset. The answer is late by
    /// construction, and the document it describes may no longer be the one on screen — offering
    /// against a stale range would delete the characters typed while waiting.
    #[test]
    fn a_shell_answer_for_a_document_that_has_moved_on_offers_nothing() {
        let groups = vec![ShellGroup {
            prefix: String::from("com"),
            suffix: String::new(),
            suggestions: vec![suggestion("commit", false)],
        }];
        let provider = ShellProvider::new(groups);
        // Still true of the live document: offered, and against the range the prefix names.
        let ranked = complete("git com", 7, &[&provider], 8);
        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].candidate.text, "commit");
        assert_eq!(ranked[0].candidate.replace, 4..7);
        // The user typed on. The prefix no longer describes the caret, so the group is dropped
        // rather than applied to a range that would swallow `commi`.
        assert!(complete("git commi", 9, &[&provider], 8).is_empty());
    }

    /// `-Q` is the shell saying the text already carries its escaping FOR A BARE CARET. Inside a
    /// quote the replacement covers the opening one, so the candidate has to carry a quote back —
    /// and this crate's quoter is the only thing that knows which quote that is.
    #[test]
    fn a_verbatim_suggestion_goes_in_untouched_at_a_bare_caret_and_is_requoted_inside_one() {
        let bare = ShellProvider::new(vec![ShellGroup {
            prefix: String::from("a"),
            suffix: String::new(),
            suggestions: vec![suggestion("a\\ b", true)],
        }]);
        let ranked = complete("ls a", 4, &[&bare], 8);
        assert_eq!(ranked[0].candidate.insert, "a\\ b");

        let quoted = ShellProvider::new(vec![ShellGroup {
            prefix: String::from("'a"),
            suffix: String::new(),
            suggestions: vec![suggestion("a b", true)],
        }]);
        let ranked = complete("ls 'a", 5, &[&quoted], 8);
        assert_eq!(ranked[0].candidate.insert, "'a b'");
    }

    /// The suffix is what an accept would swallow AFTER the caret, and it is honoured only while it
    /// is still there — otherwise the accept eats whatever moved into its place.
    #[test]
    fn a_suffix_that_is_no_longer_at_the_caret_is_not_swallowed() {
        let provider = ShellProvider::new(vec![ShellGroup {
            prefix: String::from("sl"),
            suffix: String::from("ing"),
            suggestions: vec![suggestion("sliding", false)],
        }]);
        let ranked = complete("sling", 2, &[&provider], 8);
        assert_eq!(ranked[0].candidate.replace, 0..5);
        // The tail changed under it: the replacement stops at the caret rather than reaching past.
        let ranked = complete("slate", 2, &[&provider], 8);
        assert_eq!(ranked[0].candidate.replace, 0..2);
    }

    /// zsh does not label its matches, so the icon is read off the shape. It decides the glyph and
    /// the tie-break and never what gets inserted.
    #[test]
    fn a_suggestions_kind_is_read_off_its_shape() {
        let provider = ShellProvider::new(vec![ShellGroup {
            prefix: String::new(),
            suffix: String::new(),
            suggestions: vec![
                suggestion("--color", false),
                suggestion("src/", false),
                suggestion("src/main.rs", false),
                suggestion("commit", false),
            ],
        }]);
        let request = complete("", 0, &[&provider], 8);
        let kinds: Vec<CandidateKind> = ["--color", "src/", "src/main.rs", "commit"]
            .into_iter()
            .map(|text| {
                request
                    .iter()
                    .find(|ranked| ranked.candidate.text == text)
                    .map_or(CandidateKind::History, |ranked| ranked.candidate.kind)
            })
            .collect();
        assert_eq!(kinds, [
            CandidateKind::Flag,
            CandidateKind::Directory,
            CandidateKind::Path,
            CandidateKind::Subcommand
        ]);
    }
}
