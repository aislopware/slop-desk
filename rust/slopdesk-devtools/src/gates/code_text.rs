//! What a content stamp should hash when the file is source: the CODE, not the bytes.
//!
//! ## The measurement this exists for
//! `Sources/SlopDeskVideoProtocol` sits deep in both app graphs, so a one-word edit to a doc
//! comment there invalidated [`super::stamp`] and cost fifteen minutes of `xcodebuild` across the
//! two triples — for a change that cannot move one instruction. This tree's edits are heavily
//! doc-comment, so that was not a rare shape; it was the common one.
//!
//! The fix is not to weaken the gate. It is to stamp what the compiler actually reads. A comment is
//! removed by the lexer before a single declaration is parsed, and whitespace between two tokens is
//! significant only in that it EXISTS — and, across a line break, that it was a line break. Hash
//! that, and a comment-only edit leaves the stamp exactly where it was, which is the truth.
//!
//! ## The one direction that must never happen
//! A stripper bug that classifies CODE as a comment leaves a warm stamp over a real change — a
//! green the gate never earned, and the failure this module is written to make impossible. The
//! other direction, keeping something it could have dropped, costs a rebuild nobody needed and is
//! therefore the direction every ambiguity resolves toward.
//!
//! That is why the string handling here is a real lexer rather than a regex. A `/*` inside a string
//! literal is not a comment, so `let marker = "/*"` must not swallow the rest of the file; and
//! because Swift interpolation can nest a whole expression — including another string — inside a
//! literal, the state has to be a STACK. `"\(names["/*"])"` is the case that decides the shape.
//!
//! ## Two dialects, and why the difference is not cosmetic
//! Swift block comments NEST, so `/* /* */ */` is one comment; C's do not, so the same text ends at
//! the first `*/` and the trailing `*/` is code. Stripping C with Swift's rule would eat that code
//! — the forbidden direction — so the nesting rule is per-dialect rather than shared. C is here at
//! all because the FFI header is generated FROM Rust doc comments and is in the same stamp: without
//! this a Rust doc edit rebuilds both app triples through a regenerated `.h`.
//!
//! Swift has no character literal, so `'` is ordinary punctuation there; C does, and `'"'` would
//! otherwise open a string that never closes. Each dialect gets exactly the delimiters it has.

use std::path::Path;

/// The comment and literal rules of one source language.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dialect {
    /// Nesting block comments, `#`-delimited raw strings, `"""` multiline, `\(…)` interpolation.
    Swift,
    /// Flat block comments, `'x'` character literals, no raw strings and no interpolation.
    C,
}

impl Dialect {
    /// The dialect for `path`, or `None` when its bytes are not source this module understands.
    ///
    /// Anything absent from this match is hashed RAW by the caller, which is the conservative
    /// answer: a `.plist` or a `project.yml` has no comment syntax worth guessing at, and guessing
    /// wrong on one of them is the failure direction the module note rules out.
    #[must_use]
    pub fn of(path: &Path) -> Option<Self> {
        match path.extension().and_then(|value| value.to_str()) {
            Some("swift") => Some(Self::Swift),
            Some("h") => Some(Self::C),
            _ => None,
        }
    }

    /// Whether a `/*` inside a block comment opens a second one that must also be closed.
    const fn nests(self) -> bool {
        matches!(self, Self::Swift)
    }
}

/// What the lexer is inside of, innermost last.
///
/// A stack rather than a flag because interpolation re-enters CODE inside a literal, and the code
/// it re-enters can open another literal. The parenthesis depth is carried per interpolation so
/// that a `)` belonging to a call inside the interpolation does not close it.
#[derive(Debug, Clone, Copy)]
enum Ctx {
    /// Inside a string literal. `hashes` is the raw-string delimiter count, `multi` a `"""`
    /// literal.
    Str { hashes: usize, multi: bool },
    /// Inside `\(…)` — code again, until this many parentheses have closed.
    Interp { depth: usize },
}

/// The code of `text`, with comments removed and inter-token whitespace normalised.
///
/// Whitespace collapses to ONE byte, and to `\n` whenever the run it replaces contained a newline:
/// Swift terminates statements at a line break, so folding a newline into a space would make two
/// different programs hash the same — the forbidden direction again, in the one place it is easy to
/// miss. A stripped comment leaves the same separator behind for the same reason: `a/**/b` is two
/// tokens and must not become one.
///
/// String literals are emitted VERBATIM, whitespace and all. Their bytes are program data.
#[must_use]
pub fn code_only(text: &[u8], dialect: Dialect) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::with_capacity(text.len());
    let mut stack: Vec<Ctx> = Vec::new();
    // Pending inter-token whitespace, flushed as one byte the moment code follows it. Trailing
    // whitespace is therefore dropped entirely, which is the same normalisation one byte later.
    let mut space = false;
    let mut newline = false;
    let mut index = 0;

    // Emits the one byte a run of whitespace or a comment collapsed to.
    macro_rules! flush {
        ($out:expr) => {
            if space || newline {
                $out.push(if newline { b'\n' } else { b' ' });
                space = false;
                newline = false;
            }
        };
    }

    while index < text.len() {
        let byte = text[index];

        // ── Inside a string literal ────────────────────────────────────────────────────────────
        if let Some(&Ctx::Str { hashes, multi }) = stack.last() {
            // An escape is a backslash followed by exactly the literal's own hash count. In a raw
            // string with no hashes that is the bare backslash; with hashes, `\#(`.
            if byte == b'\\' && dialect == Dialect::Swift && has_hashes(text, index + 1, hashes) {
                let after = index + 1 + hashes;
                if text.get(after) == Some(&b'(') {
                    out.extend_from_slice(&text[index..=after]);
                    index = after + 1;
                    stack.push(Ctx::Interp { depth: 1 });
                    continue;
                }
                // Any other escape consumes its escapee, so a `\"` cannot close the literal.
                let end = (after + 1).min(text.len());
                out.extend_from_slice(&text[index..end]);
                index = end;
                continue;
            }
            if byte == b'\\' && dialect == Dialect::C {
                let end = (index + 2).min(text.len());
                out.extend_from_slice(&text[index..end]);
                index = end;
                continue;
            }
            if let Some(len) = closes_string(text, index, hashes, multi) {
                out.extend_from_slice(&text[index..index + len]);
                index += len;
                stack.pop();
                continue;
            }
            out.push(byte);
            index += 1;
            continue;
        }

        // ── Code, at the top level or inside an interpolation ──────────────────────────────────
        if byte == b'/' && text.get(index + 1) == Some(&b'/') {
            while index < text.len() && text[index] != b'\n' {
                index += 1;
            }
            space = true;
            continue;
        }
        if byte == b'/' && text.get(index + 1) == Some(&b'*') {
            let (end, crossed) = block_comment_end(text, index, dialect.nests());
            newline |= crossed;
            space = true;
            index = end;
            continue;
        }
        if byte.is_ascii_whitespace() {
            newline |= byte == b'\n';
            space = true;
            index += 1;
            continue;
        }

        if let Some((len, hashes, multi)) = opens_string(text, index, dialect) {
            flush!(out);
            out.extend_from_slice(&text[index..index + len]);
            index += len;
            stack.push(Ctx::Str { hashes, multi });
            continue;
        }
        if dialect == Dialect::C && byte == b'\'' {
            // A character literal, emitted whole so that `'"'` cannot open a string. The escape is
            // consumed with its escapee for the same reason `'\''` must not end at its middle
            // quote.
            flush!(out);
            let end = char_literal_end(text, index);
            out.extend_from_slice(&text[index..end]);
            index = end;
            continue;
        }

        if let Some(Ctx::Interp { depth }) = stack.last_mut() {
            if byte == b'(' {
                *depth += 1;
            } else if byte == b')' {
                *depth -= 1;
                if *depth == 0 {
                    flush!(out);
                    out.push(byte);
                    index += 1;
                    stack.pop();
                    continue;
                }
            }
        }

        flush!(out);
        out.push(byte);
        index += 1;
    }

    out
}

/// Whether `text[at..]` begins with exactly `count` `#` bytes.
fn has_hashes(text: &[u8], at: usize, count: usize) -> bool {
    (0..count).all(|offset| text.get(at + offset) == Some(&b'#'))
}

/// The delimiter opening a string literal at `at`, as `(length, hashes, multiline)`.
///
/// Swift's raw form is `#`-prefixed and its multiline form is `"""`, so the two combine as `#"""`;
/// the closing delimiter mirrors the same counts, which is what [`closes_string`] rebuilds.
fn opens_string(text: &[u8], at: usize, dialect: Dialect) -> Option<(usize, usize, bool)> {
    let mut hashes = 0;
    if dialect == Dialect::Swift {
        while text.get(at + hashes) == Some(&b'#') {
            hashes += 1;
        }
    }
    if text.get(at + hashes) != Some(&b'"') {
        return None;
    }
    // THREE quotes are not enough to make it multiline, and the difference is not academic: `#"""#`
    // is a raw literal holding one quote character, and reading its `"""` as a multiline opener
    // sends the lexer hunting a closing delimiter that is not there — it swallows the rest of the
    // file as string data, which is the forbidden direction. Swift's actual rule is that a
    // multiline literal's opening delimiter is the LAST thing on its line, so that is the test.
    let multi = dialect == Dialect::Swift
        && text.get(at + hashes + 1) == Some(&b'"')
        && text.get(at + hashes + 2) == Some(&b'"')
        && rest_of_line_is_blank(text, at + hashes + 3);
    let quotes = if multi { 3 } else { 1 };
    Some((hashes + quotes, hashes, multi))
}

/// Whether everything from `at` to the next line break is horizontal whitespace.
fn rest_of_line_is_blank(text: &[u8], at: usize) -> bool {
    let mut index = at;
    while let Some(&byte) = text.get(index) {
        match byte {
            b'\n' => return true,
            b' ' | b'\t' | b'\r' => index += 1,
            _ => return false,
        }
    }
    true
}

/// The length of the delimiter closing a literal at `at`, or `None` when this is not one.
fn closes_string(text: &[u8], at: usize, hashes: usize, multi: bool) -> Option<usize> {
    let quotes = if multi { 3 } else { 1 };
    if !(0..quotes).all(|offset| text.get(at + offset) == Some(&b'"')) {
        return None;
    }
    has_hashes(text, at + quotes, hashes).then_some(quotes + hashes)
}

/// The index just past the block comment starting at `at`, and whether it spanned a newline.
///
/// An UNTERMINATED comment ends the file, which is what the compiler does with it too.
fn block_comment_end(text: &[u8], at: usize, nests: bool) -> (usize, bool) {
    let mut index = at + 2;
    let mut depth = 1_usize;
    let mut crossed = false;
    while index < text.len() {
        if text[index] == b'\n' {
            crossed = true;
        }
        if text[index] == b'*' && text.get(index + 1) == Some(&b'/') {
            depth -= 1;
            index += 2;
            if depth == 0 {
                return (index, crossed);
            }
            continue;
        }
        if nests && text[index] == b'/' && text.get(index + 1) == Some(&b'*') {
            depth += 1;
            index += 2;
            continue;
        }
        index += 1;
    }
    (text.len(), crossed)
}

/// The index just past the C character literal starting at `at`.
const fn char_literal_end(text: &[u8], at: usize) -> usize {
    let mut index = at + 1;
    while index < text.len() {
        match text[index] {
            b'\\' => index += 2,
            b'\'' => return index + 1,
            _ => index += 1,
        }
    }
    text.len()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{Dialect, code_only};

    /// `code_only` over Swift, as a string, for readable assertions.
    fn swift(text: &str) -> String {
        String::from_utf8(code_only(text.as_bytes(), Dialect::Swift)).unwrap()
    }

    fn c(text: &str) -> String {
        String::from_utf8(code_only(text.as_bytes(), Dialect::C)).unwrap()
    }

    /// The property the whole module is for, stated as one assertion.
    #[test]
    fn a_comment_only_edit_leaves_the_code_identical() {
        let before = "/// The door.\nfunc open() -> Int { 1 }\n";
        let after = "/// The door, rewritten at length for the reader.\nfunc open() -> Int { 1 }\n";
        assert_eq!(swift(before), swift(after));
        assert_eq!(swift(before).trim(), "func open() -> Int { 1 }");
    }

    #[test]
    fn a_real_edit_still_moves_it() {
        assert_ne!(
            swift("func open() -> Int { 1 }"),
            swift("func open() -> Int { 2 }"),
            "the stamp must still see a changed literal"
        );
    }

    /// The case that decides the string handling: a comment opener as string DATA.
    #[test]
    fn a_comment_opener_inside_a_literal_is_data() {
        assert_eq!(swift(r#"let a = "/*"; let b = 1"#), r#"let a = "/*"; let b = 1"#);
        assert_eq!(swift(r#"let a = "//"; let b = 1"#), r#"let a = "//"; let b = 1"#);
    }

    /// And the case that decides the stack: a literal nested inside an interpolation.
    #[test]
    fn a_string_inside_an_interpolation_does_not_end_the_outer_one() {
        let text = r#"let s = "\(names["/*"]) done"; let after = 1"#;
        assert_eq!(swift(text), text, "the outer literal ends at its own quote");
    }

    #[test]
    fn a_raw_literal_closes_only_on_its_own_hash_count() {
        assert_eq!(
            swift(r##"let s = #"a "b" /*"#; let t = 1"##),
            r##"let s = #"a "b" /*"#; let t = 1"##
        );
    }

    #[test]
    fn a_raw_literals_backslash_is_not_an_escape_without_its_hashes() {
        // In `#"…"#` a bare `\` is data, so `\"` does NOT escape and the literal ends at the quote.
        assert_eq!(
            swift(r##"let s = #"a\"#; let t = "/*" "##.trim_end()),
            r##"let s = #"a\"#; let t = "/*""##
        );
    }

    #[test]
    fn an_escaped_quote_does_not_close_the_literal() {
        assert_eq!(
            swift(r#"let s = "a\"/*b"; let t = 1"#),
            r#"let s = "a\"/*b"; let t = 1"#
        );
    }

    /// The shape the tree canary caught: `#"""#` is one quote character, not a multiline opener.
    #[test]
    fn three_quotes_that_do_not_end_the_line_are_not_a_multiline_opener() {
        let text = r##"let q = #"""#; /* gone */ let t = 1"##;
        assert_eq!(swift(text).trim(), r##"let q = #"""#; let t = 1"##);
    }

    #[test]
    fn a_multiline_literal_keeps_its_own_whitespace() {
        let text = "let s = \"\"\"\n  a\n\n  b\n  \"\"\"\nlet t = 1";
        assert_eq!(
            swift(text),
            text,
            "a literal's bytes are program data, not layout"
        );
    }

    #[test]
    fn swift_block_comments_nest() {
        assert_eq!(
            swift("let a = 1 /* outer /* inner */ still */ ; let b = 2").trim(),
            "let a = 1 ; let b = 2"
        );
    }

    /// The dialect split, in the direction that would otherwise EAT code.
    #[test]
    fn c_block_comments_do_not_nest() {
        assert_eq!(c("int a; /* outer /* inner */ int b;").trim(), "int a; int b;");
    }

    #[test]
    fn a_c_character_literal_holding_a_quote_opens_no_string() {
        assert_eq!(
            c(r#"char q = '"'; /* gone */ int b;"#).trim(),
            r#"char q = '"'; int b;"#
        );
        assert_eq!(c(r"char e = '\''; int b;").trim(), r"char e = '\''; int b;");
    }

    /// A stripped comment must still SEPARATE the tokens it stood between.
    #[test]
    fn a_stripped_comment_leaves_a_separator() {
        assert_eq!(swift("a/**/b").trim(), "a b");
        assert_eq!(swift("a//x\nb").trim(), "a\nb");
    }

    /// Swift ends statements at a line break, so a newline may not collapse into a space.
    #[test]
    fn a_newline_survives_as_a_newline() {
        assert_ne!(swift("return\nx"), swift("return x"));
        assert_eq!(swift("return   \n  \n x").trim(), "return\nx");
        assert_eq!(swift("let  a  =  1").trim(), "let a = 1");
    }

    /// A block comment that spanned lines separates as a NEWLINE, for the same reason.
    #[test]
    fn a_multiline_block_comment_separates_as_a_line_break() {
        assert_eq!(swift("return/* a\nb */x").trim(), "return\nx");
        assert_eq!(swift("return/* a */x").trim(), "return x");
    }

    #[test]
    fn an_unterminated_comment_ends_the_file_rather_than_looping() {
        assert_eq!(swift("let a = 1 /* and then nothing").trim(), "let a = 1");
        assert_eq!(
            swift(r#"let a = "unterminated"#).trim(),
            r#"let a = "unterminated"#
        );
    }

    /// The canary, run over the REAL tree: no file may leave the lexer inside a literal.
    ///
    /// Every hand-written case above is a shape someone thought of. This one is the shape nobody
    /// did: if any source in this repo mis-tracks — an unpaired quote, an interpolation the stack
    /// lost, a raw delimiter counted wrong — the lexer ends the file still inside a string, and
    /// everything appended after it is swallowed as literal data instead of being read as code.
    /// That is EXACTLY the forbidden direction, so it is asserted directly: append a comment and a
    /// statement to each file and require that the comment goes and the statement stays.
    #[test]
    fn no_source_in_this_tree_leaves_the_lexer_inside_a_literal() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut checked = 0_usize;
        for dir in ["Sources", "Apps", "Tests", "ThirdParty/slopdesk-ffi"] {
            let mut files = Vec::new();
            walk(&root.join(dir), &mut files);
            for file in files {
                let dialect = Dialect::of(&file).unwrap();
                let tail: &[u8] = match dialect {
                    Dialect::Swift => b"\n/* canary */\nlet canary = 1\n",
                    Dialect::C => b"\n/* canary */\nint canary = 1;\n",
                };
                let mut bytes = std::fs::read(&file).unwrap();
                bytes.extend_from_slice(tail);
                let code = String::from_utf8_lossy(&code_only(&bytes, dialect)).into_owned();
                assert!(
                    code.contains("canary = 1") && !code.contains("canary */"),
                    "{} left the lexer inside a literal",
                    file.display()
                );
                checked += 1;
            }
        }
        assert!(
            checked > 500,
            "the walk found only {checked} sources — it is not reaching the tree"
        );
    }

    /// Every source this module normalises under `dir`, recursively.
    fn walk(dir: &Path, into: &mut Vec<std::path::PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, into);
            } else if Dialect::of(&path).is_some() {
                into.push(path);
            }
        }
    }

    #[test]
    fn only_the_two_source_extensions_are_normalised() {
        assert_eq!(Dialect::of(Path::new("A.swift")), Some(Dialect::Swift));
        assert_eq!(Dialect::of(Path::new("a.h")), Some(Dialect::C));
        assert_eq!(Dialect::of(Path::new("project.yml")), None);
        assert_eq!(Dialect::of(Path::new("Info.plist")), None);
        assert_eq!(Dialect::of(Path::new("shader.metal")), None);
        assert_eq!(Dialect::of(Path::new("module.modulemap")), None);
    }
}
