//! The repository, read once.
//!
//! Every rule in this crate asks questions of the same few thousand source files. The shell gate
//! this replaces asked them by spawning `grep`, which meant each question re-opened and re-read the
//! files it touched — 891 times over, for a tree that fits in a few tens of megabytes. Here the
//! walk happens once, the text stays resident, and a rule is a function over `&Tree`.
//!
//! ## Two views of every file, and why the second is not a convenience
//!
//! A gate that bans a call has to tell a CALL from a SENTENCE ABOUT ONE. The prose above these
//! rules names the very things they forbid — that is the point of the prose — so a rule that
//! greps raw text fires on its own explanation. [`Source::code`] is the file with its comment
//! lines removed, computed once and cached, and it is what a ban reads.
//!
//! It is line-based, not a lexer: a `//` inside a string literal keeps its line, and a block
//! comment's interior does not. Both are deliberate. The shell's stripper was `grep -vE '^
//! *(///|//|\*)'` and every rule was written against that behaviour, so matching it exactly is what
//! makes the port checkable against the original rather than merely similar.
//!
//! It is also per-LANGUAGE, and that is not a refinement of the shell — it is the shell's behaviour
//! written down. `#` opens a comment in shell and Python and opens an ATTRIBUTE in Rust, so one
//! stripper across both would eat `#[cfg(test)]` from every Rust file. Several rules stop reading a
//! Rust file AT that attribute — a test asserting an absence has to spell the banned thing — and a
//! stripper that removed the line would silently hand them the test module too.
//!
//! ## Per-language goes one level deeper than `#` versus `//`
//! [`Source::statements`] is the view every POSITIVE claim reads, and the only one that cannot be
//! answered by prose. It was one scanner over `.swift`, `.rs` and `.h` alike, and three divergences
//! were measured against it — a Rust LIFETIME that opened a character literal and let the trailing
//! comment through, a Swift `"""` literal read as one quote, and an interpolated literal that ended
//! the one holding it. All three end the same way: the scanner loses the literal and blanks CODE,
//! which is the one direction that hides what a ban is looking for. So `Slashes` carries a [`Lang`]
//! now, and the differences it holds are in [`blank_comments`].
//!
//! Two of the three came from seeding the input and reading the output. The third came from
//! `tree::tests::no_source_in_this_tree_leaves_the_scanner_inside_a_literal`, which asks the
//! property of every file that ships rather than of the shapes someone thought to write down.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// What opens a whole-line comment in a given file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommentStyle {
    /// Swift, Rust, C headers: `//`, `///`, `//!`, and `*` for a block comment's continuation.
    ///
    /// It carries WHICH of the three, because [`Source::code`] does not care and
    /// [`Source::statements`] cannot work without it: the three disagree about what a `'` is, about
    /// whether a block comment nests, and about how a raw string is spelled. A scanner that guessed
    /// one answer for all three is what [`blank_comments`]' header is about.
    Slashes(Lang),
    /// Shell, Python, TOML: `#`.
    Hash,
    /// Markdown and JSON: nothing is a comment, so `code()` is the file.
    None,
}

/// One slash-commented language, by its literal and comment rules.
///
/// The same three `slopdesk-devtools`' FFI stamp lexes, and for the same reason: those are the
/// source languages this repository is written in. See [`blank_comments`] for the divergences that
/// are not cosmetic.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lang {
    /// Nesting block comments, `#"…"#` raw strings, `"""` multiline, `\(…)` interpolation, and no
    /// character literal at all — so `'` is ordinary punctuation.
    Swift,
    /// Nesting block comments, `r#"…"#` raw strings, and a `'` that opens a character literal or
    /// names a LIFETIME.
    Rust,
    /// Flat block comments, `'x'` character literals, no raw strings and no interpolation.
    C,
}

impl Lang {
    /// Whether a `/*` inside a block comment opens a second one that must also be closed.
    const fn nests(self) -> bool {
        matches!(self, Self::Swift | Self::Rust)
    }
}

impl CommentStyle {
    fn of(path: &Path) -> Self {
        match path.extension().and_then(|ext| ext.to_str()) {
            Some("swift") => Self::Slashes(Lang::Swift),
            Some("rs") => Self::Slashes(Lang::Rust),
            Some("h") => Self::Slashes(Lang::C),
            Some("sh" | "py" | "toml" | "rb") => Self::Hash,
            _ => Self::None,
        }
    }

    fn opens(self, trimmed: &str) -> bool {
        match self {
            Self::Slashes(_) => trimmed.starts_with("//") || trimmed.starts_with('*'),
            Self::Hash => trimmed.starts_with('#'),
            Self::None => false,
        }
    }
}

/// One file, with the two views every rule reads.
pub struct Source {
    /// The file verbatim.
    pub text: String,
    /// What a comment looks like here.
    pub style: CommentStyle,
    /// The file with whole-line comments removed. Lazily built, because most files are read only
    /// by a rule that wants the raw text.
    code: OnceLock<String>,
    /// The file with EVERY comment blanked by a tokenizer that knows a string literal from a slash
    /// pair. Lazily built, because only the token bans ask for it.
    statements: OnceLock<String>,
}

impl Source {
    const fn new(text: String, style: CommentStyle) -> Self {
        Self {
            text,
            style,
            code: OnceLock::new(),
            statements: OnceLock::new(),
        }
    }

    /// The file with every line whose first non-blank characters open a comment removed.
    #[must_use]
    pub fn code(&self) -> &str {
        if self.style == CommentStyle::None {
            return &self.text;
        }
        self.code.get_or_init(|| {
            let mut out = String::with_capacity(self.text.len());
            for line in self.text.lines() {
                if self.style.opens(line.trim_start()) {
                    continue;
                }
                out.push_str(line);
                out.push('\n');
            }
            out
        })
    }

    /// The file with every comment blanked, string literals intact and line numbering preserved.
    ///
    /// [`Source::code`] is line-based and cannot see a TRAILING comment, which is the whole gap the
    /// token bans fall into: `let x = 1 // never call .addingProduct(` reads as a call to a ban
    /// that strips whole lines. Nor can a regex close that gap — three separate silent failures
    /// came out of trying, and all three were the shape of the tool rather than the pattern:
    ///
    /// * a `//` stripper mangles `https://…` inside a string literal;
    /// * a ban's own failure MESSAGE is a string literal, so a raw read reports the gate itself;
    /// * a `/* … */` spanning lines has no line-wise spelling at all.
    ///
    /// So this is a scanner, not a pattern. String and character literals SURVIVE — a ban that
    /// erased them would miss a token spelled inside one, and this repo has bans that want exactly
    /// that. Newlines survive too, so a report can still cite a line number.
    ///
    /// Rust raw strings are handled by their hash count: `r##"…"##` ends only at a quote followed
    /// by two hashes, which is why an ordinary scanner walking for the next `"` cuts them in
    /// half.
    ///
    /// And it is per-LANGUAGE, for the reason [`blank_comments`] gives: one scanner across three
    /// dialects gets two of them wrong in the direction that hides a ban.
    #[must_use]
    pub fn statements(&self) -> &str {
        match self.style {
            CommentStyle::None => &self.text,
            // A hash language keeps the LINE-based answer, because a trailing `#` inside a quoted
            // shell word is common enough that blanking it would be the URL bug wearing the other
            // hat. What differs from `code()` is that the comment line is BLANKED rather than
            // dropped: this view promises line numbering, and a rule reporting `path:line:` on a
            // shell script has to be able to trust it.
            CommentStyle::Hash => {
                self.statements.get_or_init(|| {
                    let mut out = String::with_capacity(self.text.len());
                    for line in self.text.lines() {
                        if !line.trim_start().starts_with('#') {
                            out.push_str(line);
                        }
                        out.push('\n');
                    }
                    out
                })
            },
            CommentStyle::Slashes(lang) => self.statements.get_or_init(|| blank_comments(&self.text, lang)),
        }
    }
}

/// Every comment in a slash-commented source, replaced by spaces; newlines and literals kept.
///
/// ## The one direction that must never happen
/// A blank that swallows CODE hides whatever a ban was looking for, and a ban that cannot see its
/// subject passes. That is the failure this function is written against, and it is why every
/// ambiguity below resolves toward keeping bytes rather than blanking them.
///
/// ## Three dialects, because one scanner got two of them wrong
/// The scanner this replaces was written once and applied to `.swift`, `.rs` and `.h` alike. Two
/// divergences were MEASURED against it, each in the forbidden direction, each found by seeding the
/// input and reading the output rather than by reading the code:
///
/// * `let s: &'static str = "x"; // addingProduct` — the `'` of a Rust LIFETIME opened a character
///   literal, which ran to the end of the line, so the trailing comment came through verbatim and a
///   token ban read prose as a call. Rust's own rule is asked here instead: a `'` opens a literal
///   only when what follows is an escape, or exactly one character and then a closing `'`. `&'a
///   str` fails that and is punctuation.
/// * A Swift `"""` literal was read as one quote and closed at the next, so the scanner re-entered
///   CODE inside the literal, treated its contents as comment openers and blanked to the end of the
///   file. A multiline opener is recognised by Swift's own rule — three quotes that are the last
///   thing on their line.
///
/// The rest are dialect facts the single scanner had no way to hold: Swift and Rust block comments
/// NEST and C's do not, so `/* /* */ */` is one comment in two of the three and ends early in the
/// third; Swift raw strings put their hashes BEFORE the quote and Rust's after an `r`, and Rust's
/// zero-hash `r"…"` is raw while Swift's bare `"…"` is not; Swift has no character literal, so `'`
/// there is only ever punctuation.
///
/// The twin of this lexer is `slopdesk-devtools`' `gates::code_text`, which answers a DIFFERENT
/// question — what a content stamp should hash, so it drops comments and normalises whitespace,
/// where this one blanks in place to keep line numbers and byte offsets. Two readers, two outputs;
/// merging them would mean one of the two callers stops getting what it needs. What is shared is
/// the dialect knowledge, and that is carried in prose in both headers rather than in a dependency
/// edge, because this crate's gate is `cargo test` over the TREE and may not take an edge onto the
/// gate runners.
fn blank_comments(text: &str, lang: Lang) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < bytes.len() {
        let rest = &text[index..];
        if let Some(width) = string_width(rest, lang) {
            out.push_str(&rest[..width]);
            index += width;
        } else if let Some(width) = char_width(rest, lang) {
            out.push_str(&rest[..width]);
            index += width;
        } else if rest.starts_with("//") {
            let width = rest.find('\n').unwrap_or(rest.len());
            out.extend(std::iter::repeat_n(' ', width));
            index += width;
        } else if rest.starts_with("/*") {
            let width = block_comment_width(rest, lang.nests());
            for character in rest[..width].chars() {
                out.push(if character == '\n' { '\n' } else { ' ' });
            }
            index += width;
        } else {
            let character = rest.chars().next().unwrap_or('\n');
            out.push(character);
            index += character.len_utf8();
        }
    }
    out
}

/// The byte width of the block comment at the head of `rest`, nesting or not.
///
/// An UNTERMINATED one ends the file, which is what the compiler does with it too.
fn block_comment_width(rest: &str, nests: bool) -> usize {
    let bytes = rest.as_bytes();
    let mut index = 2;
    let mut depth = 1_usize;
    while index < bytes.len() {
        if bytes[index] == b'*' && bytes.get(index + 1) == Some(&b'/') {
            depth -= 1;
            index += 2;
            if depth == 0 {
                return index;
            }
            continue;
        }
        if nests && bytes[index] == b'/' && bytes.get(index + 1) == Some(&b'*') {
            depth += 1;
            index += 2;
            continue;
        }
        index += 1;
    }
    rest.len()
}

/// The byte width of the string literal at the head of `rest`, or `None` when there is not one.
///
/// Every form the three dialects spell, resolved to the same three facts: how many bytes the opener
/// takes, how many `#` the closer must carry, and whether a backslash is an ESCAPE. Raw is carried
/// rather than inferred from the hash count, because Rust's `r"…"` is raw with none — infer it and
/// `r"a\"` reads as holding an escaped quote, the literal stays open past its real end, and the
/// code after it is scanned as string data.
fn string_width(rest: &str, lang: Lang) -> Option<usize> {
    let bytes = rest.as_bytes();
    let (opener, hashes, multi, raw) = match lang {
        Lang::Rust => {
            // The `b`/`c` prefix and the `r` are prefixes only at the head of a token, and this
            // scanner is only ever called at one: everything before `index` has been consumed as
            // code, a literal or a comment. `for r in v` still has to answer `None`, and it does —
            // the byte after its `r` is a space, not a quote or a hash.
            let mut opener = usize::from(
                matches!(bytes.first(), Some(b'b' | b'c')) && matches!(bytes.get(1), Some(b'r' | b'"')),
            );
            let mut raw = false;
            if bytes.get(opener) == Some(&b'r') {
                raw = true;
                opener += 1;
            }
            let hashes = if raw {
                bytes[opener..].iter().take_while(|byte| **byte == b'#').count()
            } else {
                0
            };
            (opener + hashes + 1, hashes, false, raw)
        },
        Lang::Swift => {
            let hashes = bytes.iter().take_while(|byte| **byte == b'#').count();
            // THREE quotes are not enough to make it multiline: `#"""#` is a raw literal holding
            // one quote character. Swift's rule is that a multiline opener is the LAST
            // thing on its line, so that is the test — read it wrong and the scanner
            // hunts a closer that is not there and blanks the rest of the file.
            let multi = bytes.get(hashes + 1) == Some(&b'"')
                && bytes.get(hashes + 2) == Some(&b'"')
                && rest_of_line_is_blank(&rest[hashes + 3..]);
            (hashes + if multi { 3 } else { 1 }, hashes, multi, hashes > 0)
        },
        Lang::C => (1, 0, false, false),
    };
    // The opener has to END in the quotes it claimed, or this is not a literal at all: an `r` in an
    // identifier, a lone `#`, a `b` before an ordinary word. It also has to FIT — a file whose last
    // byte is `r` or `#` claims an opener one past the end, and indexing there panicked the whole
    // gate rather than answering `None`. Nothing in the tree ends that way today, because every
    // formatter here writes a trailing newline, so the ask is of `get` rather than of the tree.
    let quotes = if multi { 3 } else { 1 };
    let claimed = opener
        .checked_sub(quotes)
        .and_then(|start| bytes.get(start..opener))?;
    if !claimed.iter().all(|byte| *byte == b'"') {
        return None;
    }
    let mut index = opener;
    while index < bytes.len() {
        // A Swift escape is a backslash followed by the literal's own hash count — the bare `\` in
        // a plain literal, `\#` in a `#"…"#` one. In a RAW Rust literal a backslash is
        // data.
        let escapes = match lang {
            Lang::Swift => has_hashes(bytes, index + 1, hashes),
            Lang::Rust | Lang::C => !raw,
        };
        if bytes[index] == b'\\' && escapes {
            // `\(` re-enters CODE, and the code it re-enters can open another literal:
            // `"\(m["x"])"` is one literal, not two, and a scanner that read its inner
            // quote as the outer's closer would resume INSIDE the string and blank
            // whatever followed. The interpolation is consumed whole, literals and all,
            // so this loop resumes at the byte after its `)`.
            if lang == Lang::Swift && bytes.get(index + 1 + hashes) == Some(&b'(') {
                index = index + 1 + hashes + interpolation_width(&rest[index + 1 + hashes..], lang);
                continue;
            }
            index += 2 + if lang == Lang::Swift { hashes } else { 0 };
            continue;
        }
        if bytes[index] == b'"'
            && bytes[index..].len() >= quotes
            && bytes[index..index + quotes].iter().all(|byte| *byte == b'"')
            && has_hashes(bytes, index + quotes, hashes)
        {
            return Some(index + quotes + hashes);
        }
        index += 1;
    }
    Some(rest.len())
}

/// Whether `bytes[at..]` begins with exactly `count` `#` bytes.
fn has_hashes(bytes: &[u8], at: usize, count: usize) -> bool {
    (0..count).all(|offset| bytes.get(at + offset) == Some(&b'#'))
}

/// The byte width of the `(…)` of a Swift interpolation, from its opening parenthesis.
///
/// The depth is counted so that a `)` belonging to a CALL inside the interpolation does not close
/// it, and a literal inside is consumed by [`string_width`] so that its parentheses — and its
/// quotes — are data rather than structure. An unterminated one ends the file, like every other
/// unclosed construct here.
fn interpolation_width(rest: &str, lang: Lang) -> usize {
    let bytes = rest.as_bytes();
    let mut index = 1;
    let mut depth = 1_usize;
    while index < bytes.len() {
        if let Some(width) = string_width(&rest[index..], lang) {
            index += width;
            continue;
        }
        match bytes[index] {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return index + 1;
                }
            },
            _ => {},
        }
        index += 1;
    }
    rest.len()
}

/// The byte width of the character literal at the head of `rest`, or `None` when there is not one.
///
/// Swift has no character literal, so a `'` there is punctuation and this always answers `None`.
/// Rust spells a LIFETIME with the same byte, so the question is asked rather than assumed: `&'a
/// str` holds one character and does not close, so it falls through to be emitted as punctuation —
/// read as a literal it would consume every byte to the next `'` in the file, and `<'a, 'b>` would
/// lose the code between the two.
fn char_width(rest: &str, lang: Lang) -> Option<usize> {
    let bytes = rest.as_bytes();
    if bytes.first() != Some(&b'\'') || lang == Lang::Swift {
        return None;
    }
    if bytes.get(1) == Some(&b'\\') {
        // `'\u{10FFFF}'` is the longest escape either dialect spells, at eleven bytes. The escapee
        // is consumed WITH its backslash, so the scan starts past both and `'\''` ends at its LAST
        // quote rather than the one it escapes. Past that window it is not a literal, and scanning
        // on is how a stray tick would swallow a file.
        let limit = 14.min(bytes.len());
        return (3..limit)
            .find(|index| bytes[*index] == b'\'')
            .map(|index| index + 1);
    }
    let width = rest[1..].chars().next()?.len_utf8();
    (bytes.get(1 + width) == Some(&b'\'')).then_some(width + 2)
}

/// Whether everything up to the next line break is horizontal whitespace.
fn rest_of_line_is_blank(rest: &str) -> bool {
    rest.bytes()
        .take_while(|byte| *byte != b'\n')
        .all(|byte| byte == b' ' || byte == b'\t' || byte == b'\r')
}

/// The repository as a map from repo-relative path to contents.
pub struct Tree {
    root: PathBuf,
    files: BTreeMap<PathBuf, Source>,
}

/// The directories a rule may ask about, and the extensions worth holding in memory.
///
/// Deliberately NOT the whole repository: `.build`, `target`, `.git` and the rest of `ThirdParty`
/// are together larger than everything a rule reads, and walking them would trade the win this
/// crate exists for. A rule that needs a file outside these reads it with [`Tree::read`], which is
/// the escape hatch and says so at the call site.
///
/// There used to be an exception, `ThirdParty/ghostty/integration`, and it was walked for the one
/// reason worth making an exception for: four files of OUR Swift that no `Package.swift` target
/// compiled, holding the only registrar of the terminal seam. docs/68 deleted the fork and that
/// code is `Sources/SlopDeskTerminal/` now, so `ThirdParty` is once again pruned whole — which is
/// what the paragraph above wants and what makes the list below eight entries of nothing vendored.
///
/// `packaging` is two Ruby files. It is walked because the install side is half of a contract whose
/// other half is in Rust: the formula's `post_install` records the manifest the NEXT upgrade plan
/// diffs against, and a formula that stopped recording leaves every upgrade reading as a first
/// install (`docs/49`).
const ROOTS: [&str; 8] = [
    "Sources",
    "Tests",
    "Apps",
    "rust",
    "scripts",
    "docs",
    "golden",
    "packaging",
];

/// Extensions held in memory. A file outside this set is still WALKED — its path is known, so a
/// rule can assert that it exists — but its bytes are not read until asked for.
const TEXT_EXTENSIONS: [&str; 12] = [
    "swift", "rs", "sh", "py", "md", "h", "toml", "json", "plist", "rb", "awk", "pin",
];

impl Tree {
    /// Walks the repository rooted at `root` and reads every source file under [`ROOTS`].
    ///
    /// # Errors
    /// Returns the first I/O error that stops the walk. A file that exists but cannot be read as
    /// UTF-8 is skipped rather than fatal — the tree holds a vendored fixture or two that is not
    /// text, and no rule asks about them.
    pub fn load(root: &Path) -> std::io::Result<Self> {
        let mut files = BTreeMap::new();
        for name in ROOTS {
            let dir = root.join(name);
            if dir.is_dir() {
                walk(root, &dir, &mut files)?;
            }
        }
        // The top-level files rules ask about by name. They are outside ROOTS because they are not
        // directories, and naming them is cheaper than a whole extra walk of the repo root.
        for name in ["justfile", "Package.swift", "CLAUDE.md", "DESIGN.md", "README.md"] {
            let path = root.join(name);
            if let Ok(text) = fs::read_to_string(&path) {
                let relative = PathBuf::from(name);
                // The justfile has no extension and `#` is its comment, so it is named rather than
                // derived — the one file in the tree whose style a suffix cannot answer.
                let style = if name == "justfile" {
                    CommentStyle::Hash
                } else {
                    CommentStyle::of(&relative)
                };
                files.insert(relative, Source::new(text, style));
            }
        }
        splice_quoted_includes(&mut files)?;
        Ok(Self {
            root: root.to_path_buf(),
            files,
        })
    }

    /// The repository root every path in this tree is relative to.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// One file's contents, or `None` when it is not in the tree.
    ///
    /// A rule that asserts a file EXISTS asks this and reports the `None`; a rule that reads a file
    /// it assumes exists should say what its absence means, because `None` silently satisfies a
    /// "must not contain" ban and that is the one failure this crate cannot afford.
    #[must_use]
    pub fn get(&self, path: &str) -> Option<&Source> {
        self.files.get(Path::new(path))
    }

    /// Whether a path is present in the tree.
    #[must_use]
    pub fn has(&self, path: &str) -> bool {
        self.files.contains_key(Path::new(path))
    }

    /// Every path in the tree, in sorted order — so a rule that scans is deterministic.
    pub fn paths(&self) -> impl Iterator<Item = &Path> {
        self.files.keys().map(PathBuf::as_path)
    }

    /// Every file under `prefix`, path and contents, in sorted order.
    pub fn under<'a>(&'a self, prefix: &'a str) -> impl Iterator<Item = (&'a Path, &'a Source)> {
        self.files
            .iter()
            .filter(move |(path, _)| path.starts_with(prefix))
            .map(|(path, source)| (path.as_path(), source))
    }

    /// Reads a file the walk did not hold — the escape hatch for the handful of rules that ask
    /// about something outside [`ROOTS`].
    ///
    /// # Errors
    /// Whatever [`fs::read_to_string`] returns.
    pub fn read(&self, path: &str) -> std::io::Result<String> {
        fs::read_to_string(self.root.join(path))
    }
}

/// A header that `#include "…"`s its siblings is held as the TRANSLATION UNIT, parts spliced in.
///
/// `rust/slopdesk-ffi/include/slopdesk_ffi.h` is the one such file in the tree and the reason this
/// exists: it was 12 344 lines, it is sixteen parts behind an umbrella now, and eight rules across
/// six modules name that umbrella's path to ask what the FFI declares. Every one of them is asking
/// about the header the compiler assembles, not about the include list — so the splice happens
/// here, once, and no rule and no break-test fixture has to know the file was ever divided. A
/// fixture that writes the umbrella with no `#include "…"` in it gets exactly what it wrote back.
///
/// The parts stay in the map under their own paths as well, deliberately: a generic ban that sweeps
/// every `.h` under `rust/` must still see them. Nothing in this crate COUNTS occurrences across
/// files, so the doubling is free — and the alternative, hiding the parts, would move real code out
/// from under every rule that never names the header at all.
///
/// A quoted include naming a file the walk did not find is a hard error rather than a line left
/// alone: that is a rule reading a header with a hole in it, which is the silently-vacuous failure
/// this whole crate is written against. One level, no recursion — nothing else in the tree quotes
/// an include, and a part that started including a part would be a nesting the umbrella exists to
/// prevent.
///
/// Line numbering does not survive, and no rule reading this file reports one: what they report is
/// a door NAME that is present or missing. A rule that wanted `header:line:` would have to read the
/// part directly, which is what the parts being in the map keeps possible.
fn splice_quoted_includes(files: &mut BTreeMap<PathBuf, Source>) -> std::io::Result<()> {
    let umbrellas: Vec<PathBuf> = files
        .iter()
        .filter(|(path, source)| {
            path.extension().and_then(|ext| ext.to_str()) == Some("h")
                && source.text.lines().any(|line| quoted_include(line).is_some())
        })
        .map(|(path, _)| path.clone())
        .collect();
    for path in umbrellas {
        let directory = path.parent().unwrap_or_else(|| Path::new("")).to_path_buf();
        let mut spliced = String::with_capacity(files[&path].text.len());
        for line in files[&path].text.lines() {
            let Some(name) = quoted_include(line) else {
                spliced.push_str(line);
                spliced.push('\n');
                continue;
            };
            let target = directory.join(name);
            let Some(part) = files.get(&target) else {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    format!(
                        "{} includes {}, which the walk did not find — every rule that reads that header \
                         would go quietly vacuous",
                        path.display(),
                        target.display()
                    ),
                ));
            };
            spliced.push_str(&part.text);
        }
        let style = files[&path].style;
        files.insert(path, Source::new(spliced, style));
    }
    Ok(())
}

/// The file name of a `#include "…"`, or `None` for anything else — a `#include <…>` included.
///
/// Shared with `rules::gate_health`, which reads the umbrella's include list off DISK to ask the
/// question this function's caller cannot: whether a part file exists that the list forgot. Two
/// readers of one grammar, so the grammar is written once.
pub(crate) fn quoted_include(line: &str) -> Option<&str> {
    line.trim_start()
        .strip_prefix("#include")?
        .trim_start()
        .strip_prefix('"')?
        .split('"')
        .next()
        .filter(|name| !name.is_empty())
}

fn walk(root: &Path, dir: &Path, files: &mut BTreeMap<PathBuf, Source>) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        // Build output and version control are the bulk of the bytes under `rust/` and none of the
        // meaning. `.build` is SwiftPM's, `target` is cargo's, and both hold copies of sources that
        // would otherwise answer a ban twice.
        if name == "target" || name == ".build" || name == ".git" || name.starts_with('.') {
            continue;
        }
        if entry.file_type()?.is_dir() {
            walk(root, &path, files)?;
            continue;
        }
        let keep = path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| TEXT_EXTENSIONS.contains(&ext));
        if !keep {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(relative) = path.strip_prefix(root) else {
            continue;
        };
        let style = CommentStyle::of(relative);
        files.insert(relative.to_path_buf(), Source::new(text, style));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{CommentStyle, Lang, Source, blank_comments};

    #[test]
    fn a_comment_line_is_stripped_and_a_trailing_comment_is_not() {
        let source = Source::new(
            "// a ban's own explanation names CGWindowListCopyWindowInfo\n/// and so does its doc \
             comment\nlet x = 1 // this line is CODE, comment and all\n* a block continuation\n"
                .to_owned(),
            CommentStyle::Slashes(Lang::Rust),
        );
        assert_eq!(source.code(), "let x = 1 // this line is CODE, comment and all\n");
    }

    /// The reason the stripper is per-language. `#` opens a comment in shell and an ATTRIBUTE in
    /// Rust, and several rules stop reading a Rust file exactly AT `#[cfg(test)]` — a stripper that
    /// ate the line would hand them the test module, whose whole job is to spell what they ban.
    #[test]
    fn a_rust_attribute_survives_the_stripper_that_eats_a_shell_comment() {
        let rust = Source::new(
            "#[cfg(test)]\nmod tests {}\n".to_owned(),
            CommentStyle::Slashes(Lang::Rust),
        );
        assert!(rust.code().starts_with("#[cfg(test)]"));

        let shell = Source::new("# a comment\nls\n".to_owned(), CommentStyle::Hash);
        assert_eq!(shell.code(), "ls\n");
    }

    /// Indentation does not save a comment from the stripper, which is what makes the rules that
    /// read `code()` insensitive to how the prose above them happens to be laid out.
    #[test]
    fn an_indented_comment_is_still_a_comment() {
        let source = Source::new(
            "    // indented\n\tlet y = 2\n".to_owned(),
            CommentStyle::Slashes(Lang::Rust),
        );
        assert_eq!(source.code(), "\tlet y = 2\n");
    }

    /// `statements`, as a string, for readable assertions.
    fn blanked(text: &str, lang: Lang) -> String {
        Source::new(text.to_owned(), CommentStyle::Slashes(lang))
            .statements()
            .to_owned()
    }

    /// The first measured divergence: a Rust LIFETIME opened a character literal.
    ///
    /// It ran to the end of the line, so the trailing comment came through verbatim and every token
    /// ban reading this view saw prose as a call. `&'static str` is the common spelling, and
    /// `<'a, 'b>` is the one where reading the tick as a literal eats the code BETWEEN two of them.
    #[test]
    fn a_lifetime_does_not_open_a_literal_that_swallows_the_comment_after_it() {
        assert!(
            !blanked("let s: &'static str = \"x\"; // addingProduct\n", Lang::Rust).contains("addingProduct")
        );
        assert!(!blanked("fn f<'a, 'b>(x: &'a str) {} // fma\n", Lang::Rust).contains("fma"));
        // And the half that must NOT regress: a real character literal is still data.
        assert!(blanked("let q = '\"'; // gone\n", Lang::Rust).contains("let q = '\"';"));
        assert!(blanked("let e = '\\''; // gone\n", Lang::Rust).contains("let e = '\\'';"));
        assert!(!blanked("let q = '\"'; // gone\n", Lang::Rust).contains("gone"));
    }

    /// The second: a Swift `"""` literal read as one quote, closed at the next, and the scanner
    /// re-entered CODE inside it — blanking to the end of the file, ban and all.
    #[test]
    fn a_multiline_literal_does_not_blank_the_code_after_it() {
        let text = "let s = \"\"\"\n  a // x\n  \"\"\"\nlet after = addingProduct\n";
        assert!(blanked(text, Lang::Swift).contains("let after = addingProduct"));
        // A raw literal holding ONE quote is not a multiline opener, which is the shape that makes
        // the rule "last thing on its line" rather than "three quotes".
        assert!(
            blanked("let q = #\"\"\"#; let t = addingProduct\n", Lang::Swift)
                .contains("let t = addingProduct")
        );
    }

    /// The third divergence, and the one the live-tree canary below found rather than a person.
    ///
    /// Swift interpolation re-enters CODE inside a literal, and the code it re-enters can open
    /// another literal — `"raw string for \(value ?? "unset")"` is ONE literal, and the scanner
    /// that read its inner quote as the outer's closer resumed inside the string and blanked to
    /// the end of the file. The scanner this replaces survived it only by accident: its
    /// literals stopped at the newline, so it resynchronised one line later and nobody saw the
    /// hole.
    #[test]
    fn an_interpolated_literal_does_not_end_the_one_holding_it() {
        let text = "let s = \"a \\(v ?? \"unset\") b\"\nlet after = addingProduct\n";
        assert!(blanked(text, Lang::Swift).contains("let after = addingProduct"));
        // A `)` belonging to a CALL inside the interpolation does not close it either.
        let nested = "let s = \"\\(f(g(x)))\"\nlet after = addingProduct\n";
        assert!(blanked(nested, Lang::Swift).contains("let after = addingProduct"));
        // And in a raw literal the escape needs the hashes, so `\(` there is DATA, not code.
        let raw = "let s = #\"\\(not code)\"#\nlet after = addingProduct\n";
        assert!(blanked(raw, Lang::Swift).contains("let after = addingProduct"));
    }

    /// A file whose last byte is a literal PREFIX does not take the gate down with it.
    ///
    /// `r` and `#` each claim an opener that ends one byte past the end of the file, and the check
    /// that the opener really ends in quotes used to read that byte. Every source in the tree ends
    /// in a newline, so this never fired — and a panic in the shared scanner is every rule at once,
    /// which is the loudest failure this crate has.
    #[test]
    fn a_literal_prefix_at_end_of_file_is_not_a_literal() {
        assert_eq!(blanked("bar", Lang::Rust), "bar");
        assert_eq!(blanked("let x = br", Lang::Rust), "let x = br");
        assert_eq!(blanked("let x = r#", Lang::Rust), "let x = r#");
        assert_eq!(blanked("x#", Lang::Swift), "x#");
    }

    /// Block comments nest in two of the three dialects, and the difference EATS code in C.
    #[test]
    fn only_swift_and_rust_block_comments_nest() {
        assert!(!blanked("let a = 1 /* o /* i */ still */ let b = 2\n", Lang::Swift).contains("still"));
        assert!(blanked("int a; /* o /* i */ int b = 2;\n", Lang::C).contains("int b = 2;"));
    }

    /// A raw string closes on its own hash count, in both spellings — and Rust's zero-hash `r"…"`
    /// is raw, so its backslash is data and the literal ends at the quote that follows it.
    #[test]
    fn a_raw_literal_closes_only_on_its_own_delimiter() {
        assert!(blanked("let s = r#\"a \"b\" /*\"#; let t = 1\n", Lang::Rust).contains("let t = 1"));
        assert!(blanked("let s = #\"a \"b\" /*\"#; let t = 1\n", Lang::Swift).contains("let t = 1"));
        let zero_hash = blanked("let s = r\"a\\\"; /* gone */ let t = 1\n", Lang::Rust);
        assert!(zero_hash.contains("let t = 1") && !zero_hash.contains("gone"));
    }

    /// The contract every caller of this view depends on: same length, same newlines.
    ///
    /// `View::Statements` promises line numbering, and several rules report `path:line:` off it. A
    /// blank that shortened the text or dropped a newline would move every line after it.
    #[test]
    fn blanking_preserves_length_and_line_numbering() {
        for (text, lang) in [
            ("let a = 1 // c\nlet b = 2\n", Lang::Rust),
            (
                "let s = \"\"\"\n  a\n  \"\"\"\n/* b\nc */\nlet t = 1\n",
                Lang::Swift,
            ),
            ("int a; /* b\nc */ int d;\n", Lang::C),
        ] {
            let out = blanked(text, lang);
            assert_eq!(out.len(), text.len(), "{text:?}");
            assert_eq!(out.lines().count(), text.lines().count(), "{text:?}");
        }
    }

    /// The canary, run over the REAL tree: no source may leave the scanner inside a literal.
    ///
    /// Every case above is a shape someone thought of; this is the shape nobody did. Both measured
    /// divergences had the same end state — the scanner lost track and blanked code — and both
    /// would have been caught here, so the property is asserted directly rather than case by
    /// case: append a comment and a statement to each file, and require that the comment goes
    /// and the statement stays. A rule looking for that statement is exactly a ban looking for
    /// its subject.
    #[test]
    fn no_source_in_this_tree_leaves_the_scanner_inside_a_literal() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let tree = super::Tree::load(&root).unwrap();
        let mut checked = 0_usize;
        // Assembled rather than written: this file is one of the sources the walk reads, and a
        // marker spelled whole here would find itself and fail on every run.
        let mark = format!("{}{}", "SCANNER-", "CANARY");
        for (path, source) in tree.under("") {
            let CommentStyle::Slashes(lang) = source.style else {
                continue;
            };
            let kept = "PROBE_KEPT_4242";
            let text = format!("{}\n/* {mark} */\n{kept}\n", source.text);
            let blanked = blank_comments(&text, lang);
            assert!(
                blanked.contains(kept) && !blanked.contains(&mark),
                "{} left the scanner inside a literal",
                path.display()
            );
            checked += 1;
        }
        assert!(
            checked > 1000,
            "the walk found only {checked} slash-commented sources — it is not reaching the tree"
        );
    }

    /// One entry per path, and asking for the umbrella hands back what the compiler assembles.
    ///
    /// The rule this protects is every rule that names `slopdesk_ffi.h`: none of them knows the
    /// file is sixteen parts now, and none of them should have to.
    #[test]
    fn an_umbrella_header_is_held_as_the_translation_unit_and_its_parts_stay_visible() {
        let mut files = std::collections::BTreeMap::new();
        for (path, text) in [
            ("inc/u.h", "#ifndef U\n#include \"p.h\"\n#endif\n"),
            ("inc/p.h", "size_t slopdesk_door(void);\n"),
        ] {
            files.insert(
                std::path::PathBuf::from(path),
                Source::new(text.to_owned(), CommentStyle::Slashes(Lang::C)),
            );
        }
        super::splice_quoted_includes(&mut files).unwrap();
        let umbrella = &files[std::path::Path::new("inc/u.h")].text;
        assert!(umbrella.contains("slopdesk_door") && umbrella.contains("#ifndef U"));
        assert!(files.contains_key(std::path::Path::new("inc/p.h")));
    }

    /// A part the umbrella names and the walk cannot find is a header with a HOLE in it, and every
    /// rule reading it would pass by seeing nothing. That is the one failure this crate cannot
    /// afford, so it stops the load rather than the rule.
    #[test]
    fn a_part_the_umbrella_names_and_the_tree_does_not_hold_fails_the_load() {
        let mut files = std::collections::BTreeMap::new();
        files.insert(
            std::path::PathBuf::from("inc/u.h"),
            Source::new(
                "#include \"gone.h\"\n#include <stdint.h>\n".to_owned(),
                CommentStyle::Slashes(Lang::C),
            ),
        );
        let error = super::splice_quoted_includes(&mut files).unwrap_err();
        assert!(error.to_string().contains("inc/gone.h"), "{error}");
    }

    /// The view is computed once. Rules ask for it in parallel, so the second asker must get the
    /// first one's answer rather than racing to build a second copy.
    #[test]
    fn the_code_view_is_built_once_and_reused() {
        let source = Source::new("let z = 3\n".to_owned(), CommentStyle::Slashes(Lang::Rust));
        let first: *const str = source.code();
        let second: *const str = source.code();
        assert!(std::ptr::eq(first, second));
    }
}
