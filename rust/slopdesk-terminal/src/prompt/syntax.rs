//! One shell lexer, three consumers — which is the whole argument for this module's shape.
//!
//! A Warp-class prompt needs three answers about the text in it, and every one of them is a
//! question about quoting:
//!
//! 1. **What colour is this run?** — the highlight spans.
//! 2. **What would completion replace?** — the shell WORD the cursor sits in, and whether that word
//!    is a command name, an argument or a redirection target.
//! 3. **Does Enter run this, or add a line?** — whether a quote, a `$(`, a backtick or a trailing
//!    backslash is still open.
//!
//! Written as three passes they would be three quoting implementations, and they would disagree the
//! first time someone typed `echo "it's fine"` — the highlighter calling `'` an open quote, the
//! submit rule calling it closed. So there is one scan, and the three answers are three fields of
//! [`Lexed`]. A quoting bug is then one bug, visible in the colours, rather than a silent one in
//! the submit rule.
//!
//! ## Not a shell parser, and the line is drawn on purpose
//!
//! This resolves nothing: no expansion, no alias, no word splitting, no arithmetic. It knows where
//! quotes start and end, where `$VAR`/`${VAR}`/`$(…)`/`` `…` `` are, which byte runs are operators,
//! and where one shell word stops and the next begins. That is exactly what the three consumers
//! need and no more, and the smaller surface is what keeps it total.
//!
//! **Heredocs are deliberately out.** `<<EOF` needs the *terminator word* to decide where the body
//! ends, which makes the line's state depend on a line the user has not typed yet — an editor that
//! guessed would refuse to run a correct command. `<<` lexes as an ordinary redirection, and the
//! submit rule ignores it: a heredoc at this prompt is typed the way it is typed into `bash`, with
//! the body following the newline the user asked for.
//!
//! ## Hostile input
//!
//! Nesting is an explicit [`Vec`] stack, never recursion — 100 000 nested `$(` is a `Vec` push, not
//! a blown call stack — and the stack is capped at [`MAX_NESTING`], past which a `$(` is scanned as
//! ordinary text. Every unterminated construct spans to end of input and is REPORTED rather than
//! dropped, and the scanner's loop advances by at least one scalar on every iteration whatever the
//! byte was, so no input can wedge it.

use core::ops::Range;

/// How deep `$(`/`` ` ``/`(` may nest before the scanner stops tracking.
///
/// Past this the opener lexes as an operator and its closer matches nothing. That is a defined,
/// slightly-wrong highlight for input no human wrote, and the alternative — an unbounded stack
/// driven by untrusted paste — is a memory fault for the same input.
pub const MAX_NESTING: usize = 128;

/// What the renderer should colour a run of bytes as.
///
/// Deliberately about ROLE rather than about syntax class: `main.rs` and `--verbose` are both bare
/// words to the shell, and a terminal that paints them the same is the one thing a prompt is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TokenKind {
    /// The first word of a command — `ls` in `ls -la`, and `date` inside `$(date)`.
    CommandName,
    /// A bare word in argument position.
    Argument,
    /// An argument beginning with `-`.
    Flag,
    /// An argument that looks like a filesystem path, and every redirection target.
    Path,
    /// A quoted run, its quotes included. Interrupted by [`TokenKind::Variable`] inside `"…"`,
    /// because a variable in a double-quoted string still expands and still deserves its colour.
    Quoted,
    /// `$NAME`, `${…}`, or one of the special parameters (`$?`, `$@`, `$1`, …).
    Variable,
    /// A control operator — `|`, `||`, `&&`, `;`, `&`, a newline, `(`/`)`, and the `$(`/`` ` ``
    /// that open a substitution.
    Operator,
    /// A redirection — `>`, `>>`, `<`, `>&`, and the `<<` of a heredoc.
    Redirection,
    /// `#` to end of line, when the `#` began a word.
    Comment,
}

/// One coloured run of the document, in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyntaxSpan {
    /// Byte offset of the first byte.
    pub start: usize,
    /// Byte offset one past the last.
    pub end: usize,
    /// What to paint it as.
    pub kind: TokenKind,
}

impl SyntaxSpan {
    /// The span as a byte range, for slicing the document.
    #[must_use]
    pub const fn range(self) -> Range<usize> {
        self.start..self.end
    }

    /// Whether `offset` falls inside the span.
    #[must_use]
    pub const fn contains(self, offset: usize) -> bool {
        offset >= self.start && offset < self.end
    }
}

/// What position a shell word occupies, which is what decides both its colour and what may complete
/// it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum WordRole {
    /// The first word of a command — the thing that gets executed.
    Command,
    /// Anything after it.
    #[default]
    Argument,
    /// The word after a redirection operator, which is always a path even when it has no slash.
    RedirectTarget,
}

/// One shell word: the run a completion would replace.
///
/// A word is the *adjacent* run of bare text, quotes and variables, so `foo"bar"$BAZ` is one word
/// and `foo bar` is two. That adjacency rule is what makes tab-completing inside `"my dir/fi`
/// replace the whole thing rather than the four letters after the slash.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Word {
    /// Byte offset of the first byte.
    pub start: usize,
    /// Byte offset one past the last.
    pub end: usize,
    /// What the word is doing there.
    pub role: WordRole,
}

impl Word {
    /// The word as a byte range.
    #[must_use]
    pub const fn range(self) -> Range<usize> {
        self.start..self.end
    }

    /// Whether the cursor at `offset` is inside the word or resting on either edge.
    ///
    /// Both edges count, and that is the point: a cursor at the end of `ls` is completing `ls`, and
    /// a cursor at the start of it is too.
    #[must_use]
    pub const fn touches(self, offset: usize) -> bool {
        offset >= self.start && offset <= self.end
    }
}

/// The one construct the document left open, innermost first.
///
/// Innermost rather than outermost because that is what the user is typing INTO: inside `$(echo '`
/// the thing that needs closing is the quote, and telling them about the `$(` would name the wrong
/// key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Unterminated {
    /// Everything is closed — Enter runs it.
    #[default]
    Nothing,
    /// A `'` with no partner.
    SingleQuote,
    /// A `"` with no partner.
    DoubleQuote,
    /// The document ends with an unescaped `\` — the classic line continuation.
    Backslash,
    /// A `$(` with no `)`.
    Substitution,
    /// An odd number of `` ` ``.
    Backtick,
    /// A `${` with no `}`.
    Variable,
    /// A `(` with no `)`, outside a substitution.
    Group,
}

impl Unterminated {
    /// Whether the document is complete enough to run.
    ///
    /// This is the SUBMIT RULE, and it lives here rather than in the editor because it is a fact
    /// about quoting and the quoting is scanned exactly once.
    #[must_use]
    pub const fn submits(self) -> bool {
        matches!(self, Self::Nothing)
    }
}

/// Everything one scan of the document answers.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Lexed {
    /// The coloured runs, ascending and non-overlapping. Adjacent runs of the same kind are merged,
    /// so a renderer draws one rect where the scanner saw three atoms.
    pub spans: Vec<SyntaxSpan>,
    /// The shell words, ascending. Zero-length words are never emitted.
    pub words: Vec<Word>,
    /// What the document left open.
    pub unterminated: Unterminated,
    /// Role transitions: from this byte offset onward, a word STARTING there would take this role.
    ///
    /// Private because it only exists to answer [`Lexed::role_at`], which is the question a cursor
    /// in whitespace asks: `ls | ` has no word under the cursor, but the next thing typed there is
    /// a command name and completion has to know that before it is typed.
    marks: Vec<(usize, WordRole)>,
}

impl Lexed {
    /// The word the cursor is in or resting against, if any.
    ///
    /// Later words win a tie, so a cursor between `a` and `b` in `a b`… cannot happen — there is a
    /// space there — but a cursor at the junction of two words that touch is completing the second.
    #[must_use]
    pub fn word_at(&self, cursor: usize) -> Option<Word> {
        self.words.iter().rev().copied().find(|word| word.touches(cursor))
    }

    /// The role a word at `cursor` has, whether or not one is typed there yet.
    #[must_use]
    pub fn role_at(&self, cursor: usize) -> WordRole {
        if let Some(word) = self.word_at(cursor) {
            return word.role;
        }
        self.marks
            .iter()
            .rev()
            .find(|(at, _)| *at <= cursor)
            .map_or(WordRole::Command, |(_, role)| *role)
    }

    /// The span covering `offset`, for a renderer asking what one cell is.
    #[must_use]
    pub fn span_at(&self, offset: usize) -> Option<SyntaxSpan> {
        self.spans.iter().copied().find(|span| span.contains(offset))
    }
}

/// What the scanner is inside of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Open {
    Double,
    Substitution,
    Backtick,
    Group,
}

/// The scanner's intermediate unit: a run of bytes with one lexical kind, before word roles are
/// known.
///
/// Two phases rather than one because a bare word's COLOUR depends on the whole word — `-v` is a
/// flag and `src/x` is a path — and the whole word is not known until the run after it ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AtomKind {
    Bare,
    Quoted,
    Variable,
    SubstOpen,
    SubstClose,
    Operator,
    Redirection,
    Comment,
    Space,
}

impl AtomKind {
    /// Whether this atom is part of a shell word rather than a thing between words.
    const fn is_word(self) -> bool {
        matches!(self, Self::Bare | Self::Quoted | Self::Variable)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Atom {
    start: usize,
    end: usize,
    kind: AtomKind,
}

/// Scans `text` once and answers the highlight spans, the words and the open construct.
///
/// Total: every `&str` has a lex, including the empty one and one made entirely of `$(`.
#[must_use]
pub fn lex(text: &str) -> Lexed {
    let mut scan = Scan {
        text,
        at: 0,
        atoms: Vec::new(),
        stack: Vec::new(),
        pending: None,
        unterminated: Unterminated::Nothing,
        word_start: true,
    };
    scan.run();
    let pass = resolve_words(&scan.atoms);
    Lexed {
        spans: paint(text, &scan.atoms, &pass.roles, &pass.words),
        words: pass.words,
        unterminated: scan.unterminated,
        marks: pass.marks,
    }
}

/// The single-pass byte scanner. Its whole job is producing [`Atom`]s; nothing here knows what a
/// command name is.
struct Scan<'a> {
    text: &'a str,
    at: usize,
    atoms: Vec<Atom>,
    stack: Vec<Open>,
    /// An open run of one kind, extended byte by byte and flushed when the kind changes.
    pending: Option<(usize, AtomKind)>,
    unterminated: Unterminated,
    /// Whether the next byte would begin a word — the only thing that makes `#` a comment.
    word_start: bool,
}

impl Scan<'_> {
    fn run(&mut self) {
        while let Some(ch) = self.char_at(self.at) {
            let before = self.at;
            if matches!(self.stack.last(), Some(Open::Double)) {
                self.step_double(ch);
            } else {
                self.step_normal(ch);
            }
            // Belt and braces: no byte may leave the cursor where it was, whatever the branch did.
            if self.at <= before {
                self.at = before.saturating_add(ch.len_utf8());
            }
        }
        self.flush();
        if self.unterminated == Unterminated::Nothing {
            self.unterminated = match self.stack.last() {
                Some(Open::Double) => Unterminated::DoubleQuote,
                Some(Open::Substitution) => Unterminated::Substitution,
                Some(Open::Backtick) => Unterminated::Backtick,
                Some(Open::Group) => Unterminated::Group,
                None => Unterminated::Nothing,
            };
        }
    }

    fn char_at(&self, at: usize) -> Option<char> {
        self.text.get(at..).and_then(|rest| rest.chars().next())
    }

    /// Closes the open run at the current cursor.
    fn flush(&mut self) {
        if let Some((start, kind)) = self.pending.take()
            && self.at > start
        {
            self.atoms.push(Atom {
                start,
                end: self.at,
                kind,
            });
        }
    }

    /// Extends the open run by `len` bytes, starting a new one if the kind changed.
    fn extend(&mut self, kind: AtomKind, len: usize) {
        if !matches!(self.pending, Some((_, open)) if open == kind) {
            self.flush();
            self.pending = Some((self.at, kind));
        }
        self.at = self.at.saturating_add(len).min(self.text.len());
    }

    /// Emits a standalone atom of `len` bytes, closing whatever run was open first.
    fn emit(&mut self, kind: AtomKind, len: usize) {
        self.flush();
        let start = self.at;
        let end = start.saturating_add(len).min(self.text.len());
        if end > start {
            self.atoms.push(Atom { start, end, kind });
        }
        self.at = end;
    }

    /// Pushes a nesting level, or drops it on the floor once [`MAX_NESTING`] is reached.
    fn push_open(&mut self, open: Open) {
        if self.stack.len() < MAX_NESTING {
            self.stack.push(open);
        }
    }

    fn step_normal(&mut self, ch: char) {
        match ch {
            '\n' => {
                self.emit(AtomKind::Operator, 1);
                self.word_start = true;
            },
            _ if ch.is_whitespace() => {
                self.extend(AtomKind::Space, ch.len_utf8());
                self.word_start = true;
            },
            '#' if self.word_start => {
                let rest = self.text.get(self.at..).unwrap_or("");
                let len = rest.find('\n').unwrap_or(rest.len());
                self.emit(AtomKind::Comment, len);
            },
            '\\' => self.escape(AtomKind::Bare),
            '\'' => self.single_quote(),
            '"' => {
                self.push_open(Open::Double);
                self.extend(AtomKind::Quoted, 1);
                self.word_start = false;
            },
            '`' => self.backtick(),
            '$' => self.dollar(AtomKind::Bare),
            '|' | '&' | ';' => {
                let len = self.run_of(|c| matches!(c, '|' | '&' | ';'));
                self.emit(AtomKind::Operator, len);
                self.word_start = true;
            },
            '<' | '>' => {
                let len = self.run_of(|c| matches!(c, '<' | '>' | '&'));
                self.emit(AtomKind::Redirection, len);
                self.word_start = true;
            },
            '(' => {
                self.push_open(Open::Group);
                self.emit(AtomKind::Operator, 1);
                self.word_start = true;
            },
            ')' => {
                let closing = self.stack.last().copied();
                if matches!(closing, Some(Open::Substitution)) {
                    self.stack.pop();
                    self.emit(AtomKind::SubstClose, 1);
                } else {
                    if matches!(closing, Some(Open::Group)) {
                        self.stack.pop();
                    }
                    self.emit(AtomKind::Operator, 1);
                }
                self.word_start = true;
            },
            _ => {
                self.extend(AtomKind::Bare, ch.len_utf8());
                self.word_start = false;
            },
        }
    }

    /// Inside `"…"`: the quote and the literal text are one run, but `$…` and `` ` `` still mean
    /// what they mean — which is why a double quote is a stack frame and a single quote is not.
    fn step_double(&mut self, ch: char) {
        match ch {
            '"' => {
                self.extend(AtomKind::Quoted, 1);
                self.flush();
                self.stack.pop();
                self.word_start = false;
            },
            '\\' => self.escape(AtomKind::Quoted),
            '$' => self.dollar(AtomKind::Quoted),
            '`' => self.backtick(),
            _ => self.extend(AtomKind::Quoted, ch.len_utf8()),
        }
    }

    /// How many bytes of the run starting at the cursor satisfy `keep`.
    fn run_of(&self, keep: impl Fn(char) -> bool) -> usize {
        let rest = self.text.get(self.at..).unwrap_or("");
        rest.chars().take_while(|c| keep(*c)).map(char::len_utf8).sum()
    }

    /// `\X` swallows both bytes; a `\` at end of input is the line continuation, and only outside a
    /// quote — inside one, the quote is the thing that is open and naming the backslash would send
    /// the user after the wrong key.
    fn escape(&mut self, kind: AtomKind) {
        if let Some(next) = self.char_at(self.at.saturating_add(1)) {
            self.extend(kind, 1_usize.saturating_add(next.len_utf8()));
        } else {
            self.extend(kind, 1);
            if kind == AtomKind::Bare {
                self.unterminated = Unterminated::Backslash;
            }
        }
        self.word_start = false;
    }

    /// `'…'` is opaque: nothing inside expands, so it is scanned in one reach rather than pushed.
    fn single_quote(&mut self) {
        let body = self.text.get(self.at.saturating_add(1)..).unwrap_or("");
        if let Some(offset) = body.find('\'') {
            self.extend(AtomKind::Quoted, offset.saturating_add(2));
        } else {
            let len = self.text.len().saturating_sub(self.at);
            self.extend(AtomKind::Quoted, len);
            self.unterminated = Unterminated::SingleQuote;
        }
        self.word_start = false;
    }

    fn backtick(&mut self) {
        if matches!(self.stack.last(), Some(Open::Backtick)) {
            self.stack.pop();
            self.emit(AtomKind::SubstClose, 1);
            self.word_start = false;
        } else {
            self.push_open(Open::Backtick);
            self.emit(AtomKind::SubstOpen, 1);
            self.word_start = true;
        }
    }

    /// `$(`, `${…}`, `$NAME` and the special parameters. A `$` in front of anything else is a
    /// literal dollar, which is what `echo 5$` has to stay.
    fn dollar(&mut self, literal: AtomKind) {
        match self.char_at(self.at.saturating_add(1)) {
            Some('(') => {
                self.push_open(Open::Substitution);
                self.emit(AtomKind::SubstOpen, 2);
                self.word_start = true;
            },
            Some('{') => {
                let body = self.text.get(self.at.saturating_add(2)..).unwrap_or("");
                if let Some(offset) = body.find('}') {
                    self.emit(AtomKind::Variable, offset.saturating_add(3));
                } else {
                    let len = self.text.len().saturating_sub(self.at);
                    self.emit(AtomKind::Variable, len);
                    self.unterminated = Unterminated::Variable;
                }
                self.word_start = false;
            },
            Some(next) if next.is_alphanumeric() || next == '_' => {
                let rest = self.text.get(self.at.saturating_add(1)..).unwrap_or("");
                let name: usize = rest
                    .chars()
                    .take_while(|c| c.is_alphanumeric() || *c == '_')
                    .map(char::len_utf8)
                    .sum();
                self.emit(AtomKind::Variable, name.saturating_add(1));
                self.word_start = false;
            },
            Some(next) if matches!(next, '?' | '#' | '@' | '*' | '$' | '!' | '-') => {
                self.emit(AtomKind::Variable, 1_usize.saturating_add(next.len_utf8()));
                self.word_start = false;
            },
            _ => {
                self.extend(literal, 1);
                self.word_start = false;
            },
        }
    }
}

/// Everything the word pass rolls forward, and its three outputs.
///
/// A struct rather than seven `&mut` parameters threaded through two helpers: every field is read
/// AND written by the same step, so a signature listing them was both unreadable and one reorder
/// away from a silent bug.
#[derive(Debug)]
struct WordPass {
    /// The words, in order.
    words: Vec<Word>,
    /// Role transitions — see [`Lexed::marks`].
    marks: Vec<(usize, WordRole)>,
    /// Parallel to the atoms: which word role each atom belongs to, or `None` between words. It is
    /// what lets [`paint`] colour a bare run without searching the word list.
    roles: Vec<Option<WordRole>>,
    /// Whether the next word would be a command name.
    expect_command: bool,
    /// Whether the next word is a redirection's target.
    redirect_next: bool,
    /// The atoms of the word being accumulated, as indices into the atom slice.
    open: Vec<usize>,
}

impl WordPass {
    fn new(atom_count: usize) -> Self {
        Self {
            words: Vec::new(),
            marks: vec![(0, WordRole::Command)],
            roles: vec![None; atom_count],
            expect_command: true,
            redirect_next: false,
            open: Vec::new(),
        }
    }

    /// The role a word starting now would take.
    ///
    /// A redirection target outranks a command position, because `> out ls` puts the redirection
    /// first and `out` is still a file — reading the flags the other way round would paint it as
    /// the command.
    const fn role(&self) -> WordRole {
        if self.redirect_next {
            WordRole::RedirectTarget
        } else if self.expect_command {
            WordRole::Command
        } else {
            WordRole::Argument
        }
    }

    fn mark(&mut self, at: usize) {
        let role = self.role();
        if self.marks.last().is_some_and(|(_, last)| *last == role) {
            return;
        }
        self.marks.push((at, role));
    }

    /// Closes the word being accumulated, if there is one.
    fn close(&mut self, atoms: &[Atom]) {
        if self.open.is_empty() {
            return;
        }
        let start = self
            .open
            .first()
            .and_then(|index| atoms.get(*index))
            .map_or(0, |atom| atom.start);
        let end = self
            .open
            .last()
            .and_then(|index| atoms.get(*index))
            .map_or(start, |atom| atom.end);
        let role = self.role();
        for index in &self.open {
            if let Some(slot) = self.roles.get_mut(*index) {
                *slot = Some(role);
            }
        }
        self.words.push(Word { start, end, role });
        self.open.clear();

        // A redirection target does NOT satisfy the command position: `> out ls` still runs `ls`.
        if role != WordRole::RedirectTarget {
            self.expect_command = false;
        }
        self.redirect_next = false;
        self.mark(end);
    }
}

/// Groups atoms into words, assigns each word its role, and records the role transitions.
fn resolve_words(atoms: &[Atom]) -> WordPass {
    let mut pass = WordPass::new(atoms.len());

    for (index, atom) in atoms.iter().enumerate() {
        if atom.kind.is_word() {
            let adjacent = pass
                .open
                .last()
                .and_then(|last| atoms.get(*last))
                .is_some_and(|previous| previous.end == atom.start);
            if !adjacent {
                pass.close(atoms);
            }
            pass.open.push(index);
            continue;
        }

        pass.close(atoms);
        match atom.kind {
            AtomKind::Operator | AtomKind::SubstOpen => {
                pass.expect_command = true;
                pass.redirect_next = false;
            },
            AtomKind::SubstClose => {
                pass.expect_command = false;
                pass.redirect_next = false;
            },
            AtomKind::Redirection => pass.redirect_next = true,
            AtomKind::Bare | AtomKind::Quoted | AtomKind::Variable | AtomKind::Comment | AtomKind::Space => {
            },
        }
        pass.mark(atom.end);
    }
    pass.close(atoms);
    pass
}

/// Turns atoms plus word roles into the merged, ascending highlight spans.
fn paint(text: &str, atoms: &[Atom], roles: &[Option<WordRole>], words: &[Word]) -> Vec<SyntaxSpan> {
    let mut spans: Vec<SyntaxSpan> = Vec::with_capacity(atoms.len());
    for (index, atom) in atoms.iter().enumerate() {
        let kind = match atom.kind {
            AtomKind::Space => continue,
            AtomKind::Quoted => TokenKind::Quoted,
            AtomKind::Variable => TokenKind::Variable,
            AtomKind::SubstOpen | AtomKind::SubstClose | AtomKind::Operator => TokenKind::Operator,
            AtomKind::Redirection => TokenKind::Redirection,
            AtomKind::Comment => TokenKind::Comment,
            AtomKind::Bare => {
                let role = roles.get(index).copied().flatten().unwrap_or_default();
                let word = words
                    .iter()
                    .find(|word| word.start <= atom.start && word.end >= atom.end);
                bare_kind(text, word.map_or(atom.start..atom.end, |word| word.range()), role)
            },
        };
        // Merge into the run before it when they are the same kind and touch, so a renderer draws
        // one rect where the scanner saw three atoms.
        if let Some(last) = spans.last_mut()
            && last.kind == kind
            && last.end == atom.start
        {
            last.end = atom.end;
            continue;
        }
        spans.push(SyntaxSpan {
            start: atom.start,
            end: atom.end,
            kind,
        });
    }
    spans
}

/// What a bare run is called, judged over the WHOLE word it belongs to.
///
/// Whole-word rather than per-atom because `--out="$X"` is one flag, and asking the `--out=` atom
/// on its own would answer flag while asking `"$X"` answered string — two colours across one token.
fn bare_kind(text: &str, word: Range<usize>, role: WordRole) -> TokenKind {
    if role == WordRole::RedirectTarget {
        return TokenKind::Path;
    }
    let body = text.get(word).unwrap_or("");
    if role != WordRole::Command && body.starts_with('-') {
        return TokenKind::Flag;
    }
    if body.contains('/') || body.starts_with('~') || body == "." || body == ".." {
        return TokenKind::Path;
    }
    match role {
        WordRole::Command => TokenKind::CommandName,
        WordRole::Argument | WordRole::RedirectTarget => TokenKind::Argument,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{TokenKind, Unterminated, WordRole, lex};

    /// The spans as `(text, kind)` pairs, which is what a colour assertion actually cares about.
    fn painted(text: &str) -> Vec<(&str, TokenKind)> {
        lex(text)
            .spans
            .iter()
            .map(|span| (&text[span.range()], span.kind))
            .collect()
    }

    fn words(text: &str) -> Vec<(&str, WordRole)> {
        lex(text)
            .words
            .iter()
            .map(|word| (&text[word.range()], word.role))
            .collect()
    }

    #[test]
    fn a_command_its_flag_and_its_path_get_three_colours() {
        assert_eq!(painted("ls -la src/main.rs"), vec![
            ("ls", TokenKind::CommandName),
            ("-la", TokenKind::Flag),
            ("src/main.rs", TokenKind::Path),
        ]);
    }

    #[test]
    fn a_bare_argument_is_neither_a_flag_nor_a_path() {
        assert_eq!(painted("git status"), vec![
            ("git", TokenKind::CommandName),
            ("status", TokenKind::Argument),
        ]);
    }

    #[test]
    fn an_apostrophe_inside_a_double_quote_does_not_open_anything() {
        let lexed = lex("echo \"it's fine\"");
        assert_eq!(lexed.unterminated, Unterminated::Nothing);
        assert!(lexed.unterminated.submits());
        assert_eq!(
            painted("echo \"it's fine\"")[1],
            ("\"it's fine\"", TokenKind::Quoted)
        );
    }

    #[test]
    fn a_double_quote_inside_a_single_quote_does_not_open_anything() {
        assert_eq!(lex("echo 'say \"hi\"'").unterminated, Unterminated::Nothing);
    }

    #[test]
    fn a_variable_inside_a_double_quote_keeps_its_own_colour() {
        assert_eq!(painted("echo \"a $HOME b\""), vec![
            ("echo", TokenKind::CommandName),
            ("\"a ", TokenKind::Quoted),
            ("$HOME", TokenKind::Variable),
            (" b\"", TokenKind::Quoted),
        ]);
    }

    #[test]
    fn a_variable_inside_a_single_quote_does_not() {
        assert_eq!(painted("echo '$HOME'"), vec![
            ("echo", TokenKind::CommandName),
            ("'$HOME'", TokenKind::Quoted),
        ]);
    }

    #[test]
    fn the_three_variable_spellings_all_lex() {
        assert_eq!(painted("echo $A ${B} $?"), vec![
            ("echo", TokenKind::CommandName),
            ("$A", TokenKind::Variable),
            ("${B}", TokenKind::Variable),
            ("$?", TokenKind::Variable),
        ]);
    }

    #[test]
    fn a_lone_dollar_is_literal_text() {
        assert_eq!(painted("echo 5$"), vec![
            ("echo", TokenKind::CommandName),
            ("5$", TokenKind::Argument),
        ]);
    }

    #[test]
    fn a_substitution_opens_a_fresh_command_position() {
        assert_eq!(words("echo $(date -u)"), vec![
            ("echo", WordRole::Command),
            ("date", WordRole::Command),
            ("-u", WordRole::Argument),
        ]);
    }

    #[test]
    fn a_pipe_and_a_semicolon_both_reopen_the_command_position() {
        assert_eq!(words("ls | wc -l; pwd"), vec![
            ("ls", WordRole::Command),
            ("wc", WordRole::Command),
            ("-l", WordRole::Argument),
            ("pwd", WordRole::Command),
        ]);
    }

    #[test]
    fn a_redirection_target_is_a_path_even_without_a_slash() {
        assert_eq!(painted("ls > out"), vec![
            ("ls", TokenKind::CommandName),
            (">", TokenKind::Redirection),
            ("out", TokenKind::Path),
        ]);
        // And it does not consume the command position: `> out ls` still runs `ls`.
        assert_eq!(words("> out ls"), vec![
            ("out", WordRole::RedirectTarget),
            ("ls", WordRole::Command),
        ]);
    }

    #[test]
    fn a_fd_redirection_keeps_its_digit_with_the_word_before_it() {
        assert_eq!(painted("cmd 2>&1"), vec![
            ("cmd", TokenKind::CommandName),
            ("2", TokenKind::Argument),
            (">&", TokenKind::Redirection),
            ("1", TokenKind::Path),
        ]);
    }

    #[test]
    fn a_comment_only_starts_at_a_word_boundary() {
        assert_eq!(painted("ls # note"), vec![
            ("ls", TokenKind::CommandName),
            ("# note", TokenKind::Comment),
        ]);
        assert_eq!(painted("ls a#b"), vec![
            ("ls", TokenKind::CommandName),
            ("a#b", TokenKind::Argument),
        ]);
    }

    #[test]
    fn adjacent_quotes_and_bare_text_are_one_word() {
        assert_eq!(words("cp foo\"bar\"$BAZ dst"), vec![
            ("cp", WordRole::Command),
            ("foo\"bar\"$BAZ", WordRole::Argument),
            ("dst", WordRole::Argument),
        ]);
    }

    #[test]
    fn every_unterminated_construct_is_named_rather_than_dropped() {
        assert_eq!(lex("echo 'oops").unterminated, Unterminated::SingleQuote);
        assert_eq!(lex("echo \"oops").unterminated, Unterminated::DoubleQuote);
        assert_eq!(lex("echo \\").unterminated, Unterminated::Backslash);
        assert_eq!(lex("echo $(date").unterminated, Unterminated::Substitution);
        assert_eq!(lex("echo `date").unterminated, Unterminated::Backtick);
        assert_eq!(lex("echo ${HOME").unterminated, Unterminated::Variable);
        assert_eq!(lex("(cd /tmp").unterminated, Unterminated::Group);
        assert_eq!(lex("echo hi").unterminated, Unterminated::Nothing);
    }

    #[test]
    fn the_innermost_open_construct_is_the_one_reported() {
        // Inside `$(` there is an open quote; the quote is the key the user has to press.
        assert_eq!(lex("echo $(grep 'x").unterminated, Unterminated::SingleQuote);
    }

    #[test]
    fn an_escaped_quote_does_not_open_one_and_a_trailing_backslash_continues() {
        assert_eq!(lex("echo \\'").unterminated, Unterminated::Nothing);
        assert_eq!(lex("echo a \\").unterminated, Unterminated::Backslash);
        // Inside a quote the quote is what is open, not the backslash.
        assert_eq!(lex("echo \"a \\").unterminated, Unterminated::DoubleQuote);
    }

    #[test]
    fn a_line_continuation_keeps_the_next_line_in_the_same_command() {
        assert_eq!(words("ls \\\n-la"), vec![
            ("ls", WordRole::Command),
            // The escape swallowed the newline, so the second line is still arguments.
            ("\\\n-la", WordRole::Argument),
        ]);
    }

    #[test]
    fn a_bare_newline_starts_a_new_command() {
        assert_eq!(words("ls\npwd"), vec![
            ("ls", WordRole::Command),
            ("pwd", WordRole::Command)
        ]);
    }

    #[test]
    fn the_word_under_the_cursor_is_found_from_either_edge() {
        let lexed = lex("git commit");
        assert_eq!(lexed.word_at(0).unwrap().range(), 0..3);
        assert_eq!(lexed.word_at(3).unwrap().range(), 0..3);
        assert_eq!(lexed.word_at(4).unwrap().range(), 4..10);
        assert_eq!(lexed.word_at(10).unwrap().range(), 4..10);
    }

    #[test]
    fn a_cursor_in_empty_space_still_knows_what_would_go_there() {
        let lexed = lex("ls | ");
        assert_eq!(lexed.role_at(5), WordRole::Command);
        let lexed = lex("ls ");
        assert_eq!(lexed.role_at(3), WordRole::Argument);
        let lexed = lex("ls > ");
        assert_eq!(lexed.role_at(5), WordRole::RedirectTarget);
        assert_eq!(lex("").role_at(0), WordRole::Command);
    }

    #[test]
    fn deep_nesting_is_a_vec_push_rather_than_a_call() {
        let hostile = "$(".repeat(100_000);
        let lexed = lex(&hostile);
        assert_eq!(lexed.unterminated, Unterminated::Substitution);
        assert!(!lexed.spans.is_empty());
    }

    #[test]
    fn unterminated_everything_still_terminates() {
        for hostile in [
            "'",
            "\"",
            "`",
            "$(",
            "${",
            "\\",
            "$",
            "#",
            "|||",
            ">>>",
            "()",
            "$($($(",
            "\"'`$(${\\",
            "\u{0}\u{1}\u{7f}",
            "日本語 'ん",
            "a\u{301}\u{301}\u{301}",
        ] {
            let lexed = lex(hostile);
            // Every span is inside the text and ascending — the contract a renderer slices with.
            let mut previous = 0;
            for span in &lexed.spans {
                assert!(span.start >= previous, "spans out of order in {hostile:?}");
                assert!(span.end <= hostile.len(), "span past the end in {hostile:?}");
                assert!(
                    hostile.get(span.range()).is_some(),
                    "span off a boundary in {hostile:?}"
                );
                previous = span.end;
            }
        }
    }

    #[test]
    fn a_ten_megabyte_paste_lexes_without_blowing_up() {
        let paste = "echo ".to_owned() + &"x".repeat(10 * 1024 * 1024);
        let lexed = lex(&paste);
        assert_eq!(lexed.unterminated, Unterminated::Nothing);
        assert_eq!(lexed.words.len(), 2);
    }

    #[test]
    fn every_span_is_reachable_and_non_overlapping() {
        let text = "ls -la ~/src | grep 'x' > out.txt # done";
        let lexed = lex(text);
        let mut previous = 0;
        for span in &lexed.spans {
            assert!(span.start >= previous);
            previous = span.end;
        }
        assert_eq!(lexed.span_at(0).unwrap().kind, TokenKind::CommandName);
        assert_eq!(lexed.span_at(text.len() - 1).unwrap().kind, TokenKind::Comment);
        assert!(lexed.span_at(text.len()).is_none());
    }
}
