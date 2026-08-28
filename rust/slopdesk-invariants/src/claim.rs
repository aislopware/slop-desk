//! The seven shapes 178 shell sections were written in, as data.
//!
//! Reading the whole gate through once, almost every section is one of a handful of assertions
//! wearing a different pattern and a different sentence. Written as bespoke Rust each would be
//! twenty lines of the same `if let Some(source) = … { report.fail_if(…) }`, and the thing a reader
//! wants — the pattern, the exemptions and the sentence — would be buried in it.
//!
//! So a section is a [`Claim`]: a value naming what must hold and what to say when it does not. The
//! prose that justified the rule stays where it always was, as a comment directly above the entry,
//! and the entry itself is short enough that the comment is the bulk of what a reader sees. That is
//! the same ratio the shell had, minus the machinery.
//!
//! ## The one thing a claim may not be
//! Vacuous. Every shape that reads a named file fails when the file is missing, and every shape
//! that extracts a set fails when the set is empty. Both were live failure modes in the shell —
//! `grep -q` over a renamed file is a silent pass, and `sed -n …p` over one is an empty string that
//! compares equal to another empty string — and they are the only bugs in a gate that cannot be
//! noticed by reading its output.

use std::collections::{BTreeMap, BTreeSet};

use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// Which view of a file a claim reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum View {
    /// The file verbatim. For a claim about what a file SAYS — a doc citation, a declaration.
    Raw,
    /// The file with whole-line comments stripped. For a BAN, because the prose above a ban names
    /// the thing it forbids and a raw read would fire on the explanation.
    Code,
    /// Comment-stripped, and only up to the first `#[cfg(test)]`. For a ban whose proof is a test
    /// that must spell the banned thing.
    CodeBeforeTests,
    /// Every comment blanked by a tokenizer, string literals intact. For a TOKEN ban, where the
    /// banned spelling can appear at the end of a line of real code.
    Statements,
}

impl View {
    fn of(self, source: &crate::tree::Source) -> std::borrow::Cow<'_, str> {
        match self {
            Self::Raw => std::borrow::Cow::Borrowed(&source.text),
            Self::Code => std::borrow::Cow::Borrowed(source.code()),
            Self::CodeBeforeTests => {
                std::borrow::Cow::Owned(text::before(source.code(), r"#\[cfg\(test\)\]"))
            },
            Self::Statements => std::borrow::Cow::Borrowed(source.statements()),
        }
    }
}

/// Where a value or a set is read from, and how.
///
/// This is `awk '/start/, /end/' file | sed -n 's/…/\\1/p'` as a value. The shell wrote that
/// pipeline out per comparison, which is why so many of them were subtly different — one stripped
/// comments, the next did not; one scoped to a struct, the next read the whole file and picked up a
/// second declaration by accident. Here the scoping is a field, so a reader can see at a glance
/// which extractions are scoped and which are not.
#[derive(Clone, Copy)]
pub struct Extract {
    /// Repo-relative path.
    pub path: &'static str,
    /// Which view of the file to read.
    pub view: View,
    /// An `awk` range to narrow to first, inclusive of both ends.
    pub within: Option<(&'static str, &'static str)>,
    /// The pattern whose first capture group is the value.
    pub pattern: &'static str,
    /// Further patterns whose captures join the same set — the `sed -n -e … -e …` shape, for a
    /// side that spells the same alphabet two ways.
    ///
    /// These read the UN-narrowed view, because that is what the `{ awk …; sed …; } | sort -u`
    /// braces meant: the second command was a separate pass over the whole file. `BlockMetadata`'s
    /// `kind` is the case in point — it is declared as a `CodingKey` enum nowhere near the struct.
    pub also: &'static [&'static str],
    /// Read serde field names instead of `pattern`, preferring a `#[serde(rename)]` when the field
    /// carries one.
    ///
    /// A shape rather than a pattern because it needs STATE: the rename is on the line above the
    /// field, so what crosses the wire cannot be read by a stateless match. The shell wrote this
    /// out as a six-line awk program, once, for the one struct that mixes renamed and plain fields.
    pub serde_fields: bool,
}

impl Extract {
    /// The whole file, comment-stripped, matched by one pattern — the common case.
    #[must_use]
    pub const fn code(path: &'static str, pattern: &'static str) -> Self {
        Self {
            path,
            view: View::Code,
            within: None,
            pattern,
            also: &[],
            serde_fields: false,
        }
    }

    /// The whole file verbatim, matched by one pattern.
    #[must_use]
    pub const fn raw(path: &'static str, pattern: &'static str) -> Self {
        Self {
            path,
            view: View::Raw,
            within: None,
            pattern,
            also: &[],
            serde_fields: false,
        }
    }

    /// Narrowed to an `awk` range before matching.
    #[must_use]
    pub const fn within(mut self, start: &'static str, end: &'static str) -> Self {
        self.within = Some((start, end));
        self
    }

    /// A second pattern feeding the same set, read over the whole file.
    #[must_use]
    pub const fn also(mut self, patterns: &'static [&'static str]) -> Self {
        self.also = patterns;
        self
    }

    /// Read serde field names, rename-first. `pattern` is ignored.
    #[must_use]
    pub const fn serde_fields(mut self) -> Self {
        self.serde_fields = true;
        self
    }

    /// Reads the set this extraction names, or `None` when the file is absent.
    fn set(self, tree: &Tree, report: &mut Report) -> Option<BTreeSet<String>> {
        let source = report.source(tree, self.path, "one side of a comparison lives there")?;
        let view = self.view.of(source);
        let haystack = match self.within {
            Some((start, end)) => text::range(&view, start, end),
            None => view.clone().into_owned(),
        };
        let mut set = if self.serde_fields {
            serde_field_names(&haystack)
        } else {
            text::capture_set(&haystack, self.pattern)
        };
        for pattern in self.also {
            set.extend(text::capture_set(&view, pattern));
        }
        Some(set)
    }

    /// Counts the LINES this extraction matches — the shell's `sed -n '/a/,/b/p' | grep -c`.
    fn count(self, tree: &Tree, report: &mut Report) -> Option<usize> {
        let source = report.source(tree, self.path, "one side of a census lives there")?;
        let view = self.view.of(source);
        let haystack = match self.within {
            Some((start, end)) => std::borrow::Cow::Owned(text::range(&view, start, end)),
            None => view,
        };
        Some(text::count_lines(&haystack, self.pattern))
    }

    /// Reads the single value this extraction names — the first match, whitespace removed, which is
    /// the shell's `| head -1 | tr -d ' '`.
    fn value(self, tree: &Tree, report: &mut Report) -> Option<String> {
        let source = report.source(tree, self.path, "one side of a comparison lives there")?;
        let view = self.view.of(source);
        let haystack = match self.within {
            Some((start, end)) => std::borrow::Cow::Owned(text::range(&view, start, end)),
            None => view,
        };
        Some(text::capture_first(&haystack, self.pattern)?.replace(' ', ""))
    }
}

/// The names a serde struct's fields cross the wire under, rename-first.
///
/// A field with `#[serde(rename = "x")]` above it crosses as `x` and its Rust name never does; one
/// without crosses as itself. Reading only the renames misses the plain fields, and reading only
/// the field names misses that a rename happened — either way the comparison against the other
/// language is against a set that is not the wire.
fn serde_field_names(haystack: &str) -> BTreeSet<String> {
    let rename = text::cached(r#"rename = "([a-zA-Z_]+)""#);
    let field = text::cached(r"^ *pub ([a-z_0-9]+):");
    let mut out = BTreeSet::new();
    let mut pending: Option<String> = None;
    for line in haystack.lines() {
        if let Some(caps) = rename.captures(line) {
            pending = caps.get(1).map(|m| m.as_str().to_owned());
        }
        if let Some(caps) = field.captures(line) {
            let name = pending
                .take()
                .or_else(|| caps.get(1).map(|m| m.as_str().to_owned()));
            if let Some(name) = name {
                out.insert(name);
            }
        }
    }
    out
}

/// One side of a [`Claim::SameSetUnder`]: a directory, read file by file, through one pattern.
///
/// Separate from [`Extract`] because the subject is a TARGET rather than a file. "Both video halves
/// accept the same seam sinks" is true of the half wherever in it the sinks are declared, and
/// pinning it to one file would make an ordinary split of a big adapter look like a divergence.
#[derive(Clone, Copy)]
pub struct Corpus {
    /// The directory to read, recursively.
    pub root: &'static str,
    /// Only files with one of these extensions are read.
    pub extensions: &'static [&'static str],
    /// The pattern whose first capture group joins the set.
    pub pattern: &'static str,
    /// Which view of each file to read.
    pub view: View,
}

impl Corpus {
    /// Every first-capture-group under this root, deduplicated.
    fn set(self, tree: &Tree) -> BTreeSet<String> {
        tree.under(self.root)
            .filter(|(path, _)| {
                path.extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| self.extensions.contains(&ext))
            })
            .flat_map(|(_, source)| text::capture_set(&self.view.of(source), self.pattern))
            .collect()
    }
}

/// One side of a [`Claim::SameByteMap`]: an enum's `case -> byte` switch, inside a marker range.
///
/// Separate from [`Extract`] because it reads TWO capture groups rather than one, and because the
/// marker is a `sed` address whose UNIQUENESS is part of the claim. A range restarts every time its
/// opening address matches again, so a second occurrence below the first — including one inside a
/// doc comment, which the range reader cannot tell from code — APPENDS a second enum's rows to the
/// first, and the comparison then holds one enum's cases against two enums' numbering. Red is the
/// lucky outcome; the unlucky one is a sibling whose body contributes no rows at all, which stays
/// green while covering nothing.
///
/// Read [`View::Raw`] by default, and that is deliberate: one of these markers IS a doc line.
#[derive(Clone, Copy)]
pub struct ByteMap {
    /// Repo-relative path.
    pub path: &'static str,
    /// The line that opens the switch. Must match exactly once in the file.
    pub marker: &'static str,
    /// The line that closes it.
    pub end: &'static str,
    /// The pattern whose first two capture groups are the case NAME and its byte.
    pub pattern: &'static str,
    /// Which view of the file to read.
    pub view: View,
}

impl ByteMap {
    /// The `name -> byte` map this switch declares, lower-cased so `centerHorizontal` and
    /// `CenterHorizontal` are the same claim spelled two ways.
    fn read(self, tree: &Tree, report: &mut Report, label: &str) -> Option<BTreeMap<String, String>> {
        let source = report.source(tree, self.path, "one side of a byte map lives there")?;
        let view = self.view.of(source);
        let marks = text::count_lines(&view, self.marker);
        if marks != 1 {
            report.fail(format!(
                "{label}: the marker in {} matches {marks} times, not once — a range restarts on every \
                 match and APPENDS a second enum's rows to the first (docs/55)",
                self.path,
            ));
            return None;
        }
        let mut map = BTreeMap::new();
        for caps in text::cached(self.pattern).captures_iter(&text::range(&view, self.marker, self.end)) {
            let (Some(name), Some(byte)) = (caps.get(1), caps.get(2)) else {
                continue;
            };
            map.insert(name.as_str().to_lowercase(), byte.as_str().to_owned());
        }
        Some(map)
    }
}

/// One assertion about the tree.
///
/// Every variant carries the sentence it prints. That sentence is the rule's interface — it names
/// the doc section that explains why the rule exists — so it is written out per claim rather than
/// generated from the pattern.
pub enum Claim {
    /// A file must exist. The shape every ban implicitly needs and none of them stated.
    Exists {
        /// Repo-relative path.
        path: &'static str,
        /// What its absence means.
        message: &'static str,
    },
    /// A path must NOT exist. The shape of every "this Swift stayed deleted" rule.
    Absent {
        /// Repo-relative path.
        path: &'static str,
        /// What its return means.
        message: &'static str,
    },
    /// A path must be a SYMLINK, resolving to a named file, with that file's contents.
    ///
    /// Three facts rather than one, because each fails differently and only the first is visible in
    /// a diff. The repo has TWO test trees and one list of test-lint relaxations; the second tree
    /// gets the list by link. A COPY is two lists that drift, and the drift is silent in the worst
    /// direction — one tree quietly enforcing different rules than the other, discovered whenever
    /// somebody edits one and not the other. A link that resolves to nothing is worse still: the
    /// bundle lints under the SOURCE rules, so every fixture force-unwrap turns red at once and the
    /// obvious fix is to add the relaxations back as a copy.
    ///
    /// Read off the FILESYSTEM, not the tree: a dotfile is not walked, and the question is about
    /// the directory entry rather than the bytes behind it.
    Symlink {
        /// Repo-relative path, which must be a link.
        path: &'static str,
        /// Repo-relative path it must resolve to.
        target: &'static str,
        /// Why the link is a link.
        message: &'static str,
    },
    /// A file must call every one of these FFI doors.
    ///
    /// The commonest shape in the whole gate: a Swift file that used to hold an implementation is
    /// now a face over a Rust one, and the way to say so is that it still calls each door. A door
    /// it stopped calling is an implementation that came back.
    Doors {
        /// Repo-relative path.
        path: &'static str,
        /// Each entry point, named without its parenthesis.
        entries: &'static [&'static str],
        /// The sentence, with `{entry}` where the door's name goes.
        message: &'static str,
    },
    /// A file must MENTION every one of these names — the same shape as [`Claim::Doors`] without
    /// the call parenthesis.
    ///
    /// Half the metadata and workspace doors cross as a function REFERENCE into a shared helper
    /// (`decode: slopdesk_metadata_decode_ports`), so demanding a `(` after the name would report
    /// every one of them as gone.
    Mentions {
        /// Repo-relative path.
        path: &'static str,
        /// Each name, as a literal.
        names: &'static [&'static str],
        /// The sentence, with `{entry}` where the name goes.
        message: &'static str,
    },
    /// SOME file under `root` must mention every one of these names — the shell's
    /// `grep -rq "$name" Sources/Some/Dir/`.
    ///
    /// Separate from [`Claim::Mentions`] because the claim is about the HALF, not the file: "the
    /// Mac's navigator reads `SidebarSections`" is true wherever in that column it is read, and
    /// pinning it to one file would make an ordinary split of a big view look like a regression.
    /// A corpus that strips to nothing fails rather than passing, for the reason
    /// [`Claim::NoneUnder`] refuses one: a drained directory satisfies "no file mentions it" and
    /// "some file mentions it" cannot be answered at all.
    MentionsUnder {
        /// The directory to read, recursively.
        root: &'static str,
        /// Each name, as a literal.
        names: &'static [&'static str],
        /// The sentence, with `{entry}` where the name goes.
        message: &'static str,
    },
    /// A file must match a pattern at least `minimum` times.
    ///
    /// For a rule that cannot name what it is looking for: "every tunable falls back to a field of
    /// the door's defaults, never to a literal". Counting the fallbacks is what catches a knob
    /// added later with a hand-written default beside it — the one drift no test can see,
    /// because both languages stay internally consistent.
    AtLeast {
        /// Repo-relative path.
        path: &'static str,
        /// The pattern to count LINES of.
        pattern: &'static str,
        /// The floor.
        minimum: usize,
        /// The sentence, with `{found}` where the count goes.
        message: &'static str,
    },
    /// A file must match a pattern EXACTLY this many times.
    ///
    /// [`Claim::AtLeast`]'s stricter sibling, and the difference is the whole rule where it is
    /// used: the phone's code poll is one `.task(id:)` OUTSIDE the state switch, and the first
    /// draft hung one on three of the four branches. Three reads correctly and cancels the poll
    /// on every transition the poll itself caused. A floor of one would have passed it.
    Exactly {
        /// Repo-relative path.
        path: &'static str,
        /// The pattern to count LINES of.
        pattern: &'static str,
        /// How many there must be.
        count: usize,
        /// Which view to read.
        view: View,
        /// The sentence, with `{found}` where the count goes.
        message: &'static str,
    },
    /// A file may match a pattern at most `maximum` times — [`Claim::AtLeast`] from the other side.
    ///
    /// A CEILING rather than a ban, for the one shape a ban cannot state: a memo's own miss path
    /// has to read the expensive thing, so the rule is not "nobody reads it" but "only the memo
    /// does, and only where it must". `HostWorkspaceMirror.topology` copies the whole entry map
    /// and re-projects every cell; `mirroredTopology` memoizes it against
    /// `workspaceMirrorRevision`, and its miss path is the two reads that are allowed. A third
    /// puts the projection back on some caller's path with green tests and no compile error.
    AtMost {
        /// Repo-relative path.
        path: &'static str,
        /// The pattern to count LINES of.
        pattern: &'static str,
        /// The ceiling.
        maximum: usize,
        /// Which view to read.
        view: View,
        /// The sentence, with `{found}` where the count goes.
        message: &'static str,
    },
    /// A file must contain a literal — a declaration, a call through a door, a doc citation.
    Names {
        /// Repo-relative path.
        path: &'static str,
        /// The literal, not a pattern: a claim that something is SPELLED wants no regex semantics.
        needle: &'static str,
        /// What its absence means.
        message: &'static str,
    },
    /// A file must match a pattern.
    Matches {
        /// Repo-relative path.
        path: &'static str,
        /// The pattern.
        pattern: &'static str,
        /// Which view to read.
        view: View,
        /// What a non-match means.
        message: &'static str,
    },
    /// A file must NOT match a pattern — a ban, read comment-stripped by default.
    Lacks {
        /// Repo-relative path.
        path: &'static str,
        /// The pattern.
        pattern: &'static str,
        /// Which view to read.
        view: View,
        /// What a match means.
        message: &'static str,
    },
    /// No NAMED file may match a pattern — the shell's `grep -qE … file1 file2 file3`.
    ///
    /// Separate from [`Claim::NoneUnder`] because the scope is an explicit LIST rather than a tree
    /// walk: these are the bans that say "this law lives in one crate, and these three faces over
    /// it may not respell it". Naming the files is the point — a root would sweep in the next
    /// face somebody adds, and whether that face is covered is a decision, not a default.
    NoneOf {
        /// Repo-relative paths, all of which must exist.
        paths: &'static [&'static str],
        /// The pattern.
        pattern: &'static str,
        /// Which view to read.
        view: View,
        /// What a match means.
        message: &'static str,
    },
    /// No LINE in any file under `roots` may match, except in the files named in `exempt`.
    ///
    /// Line-based, not file-based, because the shell's were: `grep -rn … | grep -v …` filters one
    /// line at a time, and a file-level version of it would exempt a whole file for one benign
    /// mention. `all` is the `grep | grep` chain — every pattern must hit the SAME line — and
    /// `unless` is the `grep -v` that follows it.
    ///
    /// The exemptions are a LIST rather than a pattern on purpose: an exemption is a decision on
    /// the record, and one that a glob could silently widen is not one.
    NoneUnder {
        /// Path prefixes to scan.
        roots: &'static [&'static str],
        /// Only files with one of these extensions are read.
        extensions: &'static [&'static str],
        /// The pattern a line must match to be an offender.
        pattern: &'static str,
        /// Further patterns the same line must ALSO match.
        all: &'static [&'static str],
        /// Patterns that excuse a line that would otherwise match.
        unless: &'static [&'static str],
        /// Which view to read.
        view: View,
        /// Paths that may match, each because somebody decided so.
        ///
        /// An entry ending in `/` exempts a DIRECTORY. That is not a glob smuggled back in: the
        /// bans that need it say "this operation lives in one crate", and a crate is a directory —
        /// naming its files instead would mean the exemption stops covering the crate the moment
        /// somebody splits a module out of it, which is the widening this list exists to prevent,
        /// arriving from the other side.
        exempt: &'static [&'static str],
        /// The sentence, with `{files}` where the offenders go.
        message: &'static str,
    },
    /// No FILE under `roots` may match `pattern` — unless it also matches `rescued_by`.
    ///
    /// The file-level sibling of [`Claim::NoneUnder`], and the two are not interchangeable. A ban
    /// on "this file is macOS-only" cannot be asked line-wise: the offending shape is one line
    /// PRESENT and another line ABSENT, which no single line can carry. Where `NoneUnder`'s
    /// `unless` excuses a line, this excuses a FILE.
    NoFileUnder {
        /// Path prefixes to scan.
        roots: &'static [&'static str],
        /// Only files with one of these extensions are read.
        extensions: &'static [&'static str],
        /// The pattern that makes a file an offender.
        pattern: &'static str,
        /// The pattern that excuses one, if any.
        rescued_by: Option<&'static str>,
        /// Which view to read.
        view: View,
        /// Paths that may match, each because somebody decided so.
        exempt: &'static [&'static str],
        /// The sentence, with `{files}` where the offenders go.
        message: &'static str,
    },
    /// At most `maximum` files under `roots` may match `pattern` — a RATCHET, not a ban.
    ///
    /// [`Claim::NoFileUnder`] with the ceiling raised off zero, and the difference is a migration.
    /// A ban states a law the tree already satisfies. This states a law the tree is on its way to:
    /// the shape is here today, it is going to zero, and the only thing that must never happen in
    /// between is that it spreads. The count is the pin, so the rule is green the day it is written
    /// and gets STRICTER for free — every file that crosses lowers the ceiling in the same commit
    /// that earned it, and a rule left un-lowered is a rule that stopped meaning anything, so the
    /// ceiling is checked from BOTH sides: an actual count below the pin fails too, naming the new
    /// number to write down.
    ///
    /// Two rules use it, both from the phone's UIKit campaign (docs/62): the count of design-system
    /// files carrying BOTH spellings, and the count of phone files that still `import SwiftUI`.
    /// Neither can be a ban while a SwiftUI screen still mounts the component — deleting the half
    /// early does not simplify anything, it stops the app compiling — and neither may be left to a
    /// promise, because "we will delete it later" is the one claim a codebase cannot keep by itself.
    CeilingUnder {
        /// Path prefixes to scan.
        roots: &'static [&'static str],
        /// Only files with one of these extensions are read.
        extensions: &'static [&'static str],
        /// The pattern that makes a file count.
        pattern: &'static str,
        /// Which view to read.
        view: View,
        /// The pinned count: how many carry it today, and the number that may only fall.
        maximum: usize,
        /// The sentence for a RISE, with `{found}`, `{maximum}` and `{files}`.
        message: &'static str,
        /// The sentence for a FALL — the ceiling is stale and wants lowering. Same placeholders.
        lowered: &'static str,
    },
    /// No BODY may appear under both of two roots — a clone detector, with a debt list.
    ///
    /// Every other ban here forbids a shape somebody wrote down. This one forbids a coincidence: a
    /// helper, a copy string or a constant that is in the RIGHT target on both sides of the UI
    /// split and spelled twice. No import is missing, no platform gate is wrong, and nothing
    /// fails to build — the two copies agree, so nothing disagrees with them, which is exactly
    /// how a duplicated bug hides. It stayed hidden nine times over.
    ///
    /// A file is normalised to its SUBSTANTIVE lines first: trailing `//` comments cut, indentation
    /// dropped, and lines that are only punctuation or that open with `import` / `@` / `#if` thrown
    /// away. A reformat and a re-worded comment therefore cannot hide a clone, a lone `}` cannot
    /// manufacture one, and two view files importing the same six modules — a coincidence of the
    /// split rather than a duplicated decision — is not a finding.
    ///
    /// `window` is EIGHT, and the reason is in the debt list's absence rather than its contents. At
    /// six the rule fired on thin forwarders, three one-line bodies each calling the SAME shared
    /// floor type, which is the FIX rendering as a violation. At eight only real blocks survive.
    ///
    /// `known` IS A DEBT LIST, NOT A CARVE-OUT. Each pair is a clone still in the tree, named so
    /// the rule can be green about everything else; a pair leaves by being deduplicated, never
    /// by being tolerated. It is checked BOTH ways, like every ledger here: a pair that has
    /// stopped being a clone is a line that has stopped excusing anything, and leaving it would
    /// let the clone grow back under its own permission.
    NoCloneAcross {
        /// One root, by path prefix.
        left: &'static str,
        /// The other.
        right: &'static str,
        /// Only files with one of these extensions are read.
        extensions: &'static [&'static str],
        /// How many consecutive substantive lines make a clone.
        window: usize,
        /// File pairs that are still clones, as `(left path, right path)`.
        known: &'static [(&'static str, &'static str)],
        /// The floor under each side's file count.
        floor: usize,
        /// The sentence, with `{pairs}` where the offending sites go.
        message: &'static str,
    },
    /// No line under `roots` may quote one of a set of strings READ OUT OF the tree.
    ///
    /// Every other ban here forbids a pattern written in this crate. This one forbids a list that
    /// only exists in the tree: the labels in `settings_rows.rs`, the group titles in
    /// `settings_layout.rs`. The rule is "a view may not re-type a word the table already holds",
    /// and the words are the table's — writing them down here would be the third copy, and the one
    /// nobody would remember to update.
    ///
    /// `template` is a LITERAL with `{needle}` in it, so a rule can demand the surrounding syntax
    /// (`slateFormSection("{needle}")`) rather than the bare string. No regex: a label is prose and
    /// prose is full of characters a pattern would read as syntax.
    NoneQuoting {
        /// Path prefixes to scan.
        roots: &'static [&'static str],
        /// Only files with one of these extensions are read.
        extensions: &'static [&'static str],
        /// Where the forbidden strings are read from. An empty reading fails.
        needles: Extract,
        /// The literal to look for, with `{needle}` where the string goes.
        template: &'static str,
        /// Which view to read.
        view: View,
        /// Paths that may quote, each because somebody decided so.
        exempt: &'static [&'static str],
        /// The sentence, with `{files}` where the offenders go.
        message: &'static str,
    },
    /// Every renderer PRESENT must answer every rung of an enum READ OUT OF the tree.
    ///
    /// [`Claim::NoneQuoting`]'s positive twin, and the shape of the whole named-ink family: an enum
    /// is a NAME in the logic floor because its resolution is a `Color`, `Color` belongs to the
    /// design layer, and the design layer sits ABOVE the floor — so the BRANCH descends and the
    /// LOOKUP stays in each renderer, one small `switch` per framework. Nothing in either language
    /// makes the two switches cover the same cases, so a third rung added to the enum compiles
    /// everywhere and ships inked correctly in one framework only.
    ///
    /// The rungs are READ, never listed here, for the reason the shell's own comment gives: a check
    /// that NAMES the symbols it watches goes quietly blind the day one is renamed, and nobody
    /// re-reads a regex. An empty reading fails, and so does a table no present file renders — both
    /// are the vacuous pass this shape exists to make impossible.
    ///
    /// A half that is ABSENT is skipped rather than failed. That is deliberate and is what makes it
    /// worth writing a row ahead of the renderer it names: the Mac twin of a given surface may not
    /// exist yet, and the row is here so that the day it lands it is already obliged to answer the
    /// same rungs instead of inventing its own.
    Resolved {
        /// What the table is called in the diagnostic.
        label: &'static str,
        /// Where the rungs are read from. An empty reading fails.
        needles: Extract,
        /// Every renderer that resolves the table. Absent ones are skipped.
        halves: &'static [&'static str],
        /// The pattern each half must match, with `{needle}` where the rung's name goes.
        template: &'static str,
        /// Which view of each half to read.
        view: View,
        /// The sentence, with `{half}` and `{needle}` where the file and the rung go.
        message: &'static str,
    },
    /// EVERY file under `roots` must match each pattern exactly the stated number of times.
    ///
    /// A per-file shape, which no ban and no whole-corpus count can state. The rule it exists for
    /// is "a phone UI file carries the one whole-file `#if os(iOS)` and nothing else": two
    /// directives in total, one of them the opening gate, one of them the `#endif`. Any other
    /// arrangement — a second gate, an inner `#else`, a file with no gate at all — is dead
    /// scaffolding around code that now always runs.
    ///
    /// ⚠️ THIS REPLACED A PER-FILE COUNT OF ONE THING, and the reason is worth keeping. Increment
    /// 58 pinned "exactly one `#if os(` in `SettingsControls.swift`" because `Half.current` was
    /// the shared target's single admission that it drew both halves. Increment 63 dissolved
    /// that admission, and the count STILL READ 1 — the whole-file guard had taken the slot. A
    /// rule stated as a COUNT of a thing cannot tell you WHICH thing it counted, so this one
    /// names every shape it wants and how many of each.
    PerFileCounts {
        /// Path prefixes to scan.
        roots: &'static [&'static str],
        /// Only files with one of these extensions are read.
        extensions: &'static [&'static str],
        /// Each pattern and the number of LINES that must match it.
        expect: &'static [(&'static str, usize)],
        /// Which view to read.
        view: View,
        /// Paths that may differ, each because somebody decided so.
        exempt: &'static [&'static str],
        /// The sentence, with `{files}` where the offenders and their readings go.
        message: &'static str,
    },
    /// A pattern must appear between two other patterns — the shell's `awk '/a/,/b/'` with a `grep`
    /// inside it.
    ///
    /// For the handful of rules whose subject is ORDER, which no type can express. The one this was
    /// written for: `clearSecureInput` releases the process-global `EnableSecureEventInput` FIRST
    /// and only then reaches for the model, so the teardown line must sit ABOVE the guard. Below
    /// it, the release is skipped for exactly the pane that needs it most — one whose model has
    /// already gone — and the lock outlives the app's own window, taking the keyboard out of
    /// every other app.
    Within {
        /// Repo-relative path.
        path: &'static str,
        /// The line the range opens on.
        start: &'static str,
        /// The line it closes on.
        end: &'static str,
        /// What must appear inside it.
        pattern: &'static str,
        /// Which view to read.
        view: View,
        /// What an absence means.
        message: &'static str,
    },
    /// A pattern may NOT appear between two other patterns — [`Claim::Within`] negated.
    ///
    /// The shell's `grep -A 2 'x' | grep -q '#if'`, and it is a range rather than a file ban
    /// because the thing forbidden is ordinary everywhere else in the same file. `Half.current`
    /// is the case: `#if os(macOS)` is perfectly normal Swift, and normal in that file, and a
    /// compile-time fork INSIDE that one property is the gate the settings table was written to
    /// delete.
    ///
    /// An empty range fails rather than passing. A ban over a declaration that has been renamed
    /// away has nothing left to ban.
    LacksWithin {
        /// Repo-relative path.
        path: &'static str,
        /// The line the range opens on.
        start: &'static str,
        /// The line it closes on.
        end: &'static str,
        /// What may not appear inside it.
        pattern: &'static str,
        /// Which view to read.
        view: View,
        /// What a match means.
        message: &'static str,
    },
    /// One pattern's first match must come BEFORE another's, in the same file.
    ///
    /// Order, stated directly, which [`Claim::Within`] can only imply. A tear-off is two steps:
    /// `PaneCanvasDragController` records the drop placement on the drag coordinator and only THEN
    /// asks the store to detach, because `detachedPanes` changes SYNCHRONOUSLY inside that call and
    /// the satellite-window coordinator reads the placement as it opens the window. Reversed, the
    /// window still opens — it just opens at the centre-cascade instead of under the cursor, and
    /// only when the reader wins the race. An occasional wrong-place window is the worst
    /// failure shape there is, and no type in either language can hold the ordering.
    ///
    /// Either pattern going unmatched fails: a file that stopped spelling one of the two steps has
    /// not satisfied the order, it has stopped having one.
    Before {
        /// Repo-relative path.
        path: &'static str,
        /// The pattern whose first match must come first.
        first: &'static str,
        /// The pattern whose first match must come second.
        second: &'static str,
        /// Which view to read.
        view: View,
        /// What the wrong order means.
        message: &'static str,
    },
    /// These roots must together hold at least `minimum` files of these extensions.
    ///
    /// The floor under a ban, and it exists because this gate has died quietly three times by
    /// resolving to an empty file list. A ban over nothing passes; a ban over nothing that SAYS so
    /// is a ban. Written as a separate claim rather than folded into [`Claim::NoneUnder`] because
    /// the number is a judgement — "well clear of what these directories hold today" — and it
    /// belongs beside the rule that needs it rather than defaulted for every rule that does not.
    Populated {
        /// Path prefixes to count under.
        roots: &'static [&'static str],
        /// Only files with one of these extensions are counted.
        extensions: &'static [&'static str],
        /// The floor.
        minimum: usize,
        /// The sentence, with `{found}` where the count goes.
        message: &'static str,
    },
    /// A file's FIRST line of code may not be one of these.
    ///
    /// "Wrapped whole in `#if os(macOS)`" is a claim about position, not presence: a gate INSIDE
    /// the file is ordinary per-platform code, and a gate as the opening line is the wrapper
    /// that makes the whole file compile to nothing on the other platform — a green build over
    /// a missing feature. Only the opening line can tell those apart.
    Opening {
        /// Repo-relative path.
        path: &'static str,
        /// The lines that may not open the file, compared after trimming.
        forbidden: &'static [&'static str],
        /// What an opening match means.
        message: &'static str,
    },
    /// Two sets, extracted from two places, must be equal.
    SameSet {
        /// What the two sets are called in the diagnostic.
        label: &'static str,
        /// The Swift side.
        swift: Extract,
        /// The Rust side.
        rust: Extract,
    },
    /// Every member of one extracted set must be a member of another — the shell's
    /// `comm -23 <(a) <(b)`.
    ///
    /// ONE DIRECTION, which is the whole reason this is not [`Claim::SameSet`]. Three of the
    /// settings comparisons are honestly asymmetric: eleven `SettingsKey` constants are
    /// internal state with no row by design, and the config bridge covers the terminal keys and
    /// not the video ones. A two-way gate over either would need an allowlist of the
    /// exceptions, and an allowlist is the thing that goes stale. One direction still catches a
    /// typo on EITHER side — the two spellings stop being equal, so the subject's member stops
    /// being found.
    Subset {
        /// What the relation is called in the diagnostic.
        label: &'static str,
        /// The side every member of which must be found.
        subject: Extract,
        /// The side that must hold them.
        universe: Extract,
        /// Why an orphan matters, with `{orphans}` where the missing members go.
        message: &'static str,
    },
    /// Every member a DIRECTORY sends must be held by one file's table.
    ///
    /// [`Claim::Subset`] with a [`Corpus`] on the sending side, for the shape where the senders are
    /// spread over a target and the server is one switch. The Android panel is the case: three
    /// connection types each write their own `op`s, and pinning the subject to whichever file
    /// happens to hold most of them would make an ordinary split of a connection look like a new
    /// verb appearing.
    ///
    /// The `floor` is the staleness guard the directory form needs and [`Claim::Subset`]'s
    /// emptiness check cannot give: a corpus reads a set per FILE and unions them, so one file
    /// whose extraction went stale is invisible — the union is still non-empty because the others
    /// answered. A count is what notices.
    SubsetUnder {
        /// What the relation is called in the diagnostic.
        label: &'static str,
        /// The directory every member of which must be served.
        subject: Corpus,
        /// The one file that must serve them.
        universe: Extract,
        /// The fewest members the corpus may read before the extraction is presumed stale.
        floor: usize,
        /// Why an orphan matters, with `{orphans}` where the unserved members go.
        message: &'static str,
    },
    /// Two enums must map the same CASE NAME to the same byte, in both languages.
    ///
    /// The shape a case COUNT cannot state, and counting is what this was for a long time. A count
    /// is blind to a reorder, and blind to a case added correctly to both enums and forgotten in
    /// the shim's decoder. Four of these cross as a bare discriminant, so a case meaning 4 on one
    /// side and 5 on the other sends focus the wrong way or decodes a frame cleanly as the WRONG
    /// message — with every test green, because each side is self-consistent.
    SameByteMap {
        /// What the enum is called in the diagnostic.
        label: &'static str,
        /// The Swift switch, which is what goes out on the wire.
        swift: ByteMap,
        /// The Rust switch, the same claim spelled a second time.
        rust: ByteMap,
    },
    /// Two extracted sets may OVERLAP in at most `mark` members — a ratchet, failing both ways.
    ///
    /// The shell's `comm -12 <(a) <(b) | grep -c`, against a high-water mark that only ever goes
    /// down. Neither [`Claim::Subset`] nor [`Claim::SameSet`] can state it: the two sides are not
    /// supposed to agree at all, and the rule is about how much of one has not yet left the other.
    ///
    /// FAILING BELOW THE MARK is the half that makes it a ratchet rather than a ceiling. A count
    /// that has fallen is ground gained, and a gate that accepts it silently lets the same ground
    /// be lost again next week without anyone noticing; the failure says "lower the mark". At a
    /// mark of zero that arm is unreachable by construction — a count cannot be negative — and
    /// it is kept anyway, because the mark is the thing that moves.
    ///
    /// Both sides are floored non-empty first. At a mark of zero an EMPTY intersection is the
    /// expected answer, so an extraction that broke would read exactly like success.
    Overlap {
        /// What the two sets are called in the diagnostic.
        label: &'static str,
        /// One side.
        left: Extract,
        /// The other.
        right: Extract,
        /// How many members may still be in both. Lower it whenever one goes; never raise it.
        mark: usize,
        /// Why an overlap matters, with `{shared}` where the common members go.
        message: &'static str,
    },
    /// Two DIRECTORIES may share at most `ceiling` members — [`Claim::Overlap`] over corpora.
    ///
    /// The ceiling that keeps a named ban from only catching what it already knows. Naming the
    /// sentences that must not be typed twice is exact and says WHERE each one lives, but it can
    /// only ever forbid the duplicates somebody has already found; a COUNT of how much
    /// vocabulary the two sides still share makes every NEW duplicate a failure without anyone
    /// having to predict which sentence it will be.
    ///
    /// ONE-WAY, unlike [`Claim::Overlap`], and that is the deliberate difference between them. The
    /// overlap here is dozens rather than nought, and it moves under every ordinary edit to either
    /// side — a rename on one half alone drops it — so a downward arm would fire on work that is
    /// not a regression and would train its reader to re-pin without reading. Re-pin after a
    /// deliberate merge; never raise to make a change fit.
    OverlapUnder {
        /// What the two sets are called in the diagnostic.
        label: &'static str,
        /// One side.
        left: Corpus,
        /// The other.
        right: Corpus,
        /// How many members may be spelled under both.
        ceiling: usize,
        /// The floor under each side's own reading, so a broken pattern cannot read as agreement.
        floor: usize,
        /// The sentence, with `{found}`, `{ceiling}` and `{shared}`.
        message: &'static str,
    },
    /// Every member of an extracted set must match a pattern.
    ///
    /// The classifier under a [`Claim::Subset`], and it exists because the subset above it reads
    /// HALF a set: the dotted `UserDefaults` keys, not the dashed config names. That split is a
    /// convention nothing enforces, so a key carrying both notations or neither would silently drop
    /// out of the comparison — the half being read would still be a valid half, just no longer the
    /// whole of what it claims to cover.
    EachMatches {
        /// What the set is called in the diagnostic.
        label: &'static str,
        /// Where to read it.
        from: Extract,
        /// The shape every member must have.
        pattern: &'static str,
        /// Why, with `{members}` where the offenders go.
        message: &'static str,
    },
    /// Two DIRECTORIES must name the same set, minus a ledger of exceptions that FAILS BOTH WAYS.
    ///
    /// The one real cost of duplicating an adapter across the UI split: two lists of a dozen-odd
    /// closures that can drift, and a sink wired on one half and forgotten on the other is
    /// invisible until somebody uses the feature on the platform that lost it.
    ///
    /// `left_only` is the asymmetry that is genuinely a platform floor, and it is checked in BOTH
    /// directions: an entry the left no longer holds is a line that has stopped excusing anything,
    /// and an entry the right has since GROWN is a divergence that was fixed while the ledger went
    /// on reading as a standing decision. A ledger that only fails on regression is half a
    /// ledger — two of this rule's original entries left because the gate caught the FIX, not
    /// the break.
    ///
    /// The floor is on the left reading alone, because the left is the side the exceptions are
    /// measured against: an extraction that goes stale there compares an empty set to an empty set
    /// and reports agreement.
    SameSetUnder {
        /// What the two sets are called in the diagnostic.
        label: &'static str,
        /// The side allowed to hold the exceptions.
        left: Corpus,
        /// The side that must hold everything else.
        right: Corpus,
        /// Names the left may hold and the right must not.
        left_only: &'static [&'static str],
        /// The floor under the left reading.
        floor: usize,
    },
    /// Two single values, extracted from two places, must agree — the shell's `same`.
    SameValue {
        /// What the value is called in the diagnostic.
        label: &'static str,
        /// The Swift side.
        swift: Extract,
        /// The Rust side.
        rust: Extract,
    },
    /// One extracted value must equal a literal — a one-sided pin, for a number that is the WIRE
    /// rather than a copy of anything.
    Pinned {
        /// What the value is called in the diagnostic.
        label: &'static str,
        /// Where to read it.
        from: Extract,
        /// The value, with whitespace removed before comparison.
        expect: &'static str,
    },
    /// A case list COUNTED on one side must equal a count DECLARED on the other.
    ///
    /// The shell's `sed -n '/^enum X/,/^}/p' | grep -c '^    case '` against
    /// `pub const ALL: [Self; N]`. Separate from [`Claim::SameSet`] because the two sides share no
    /// vocabulary — one is a list of Swift case names, the other is an array LENGTH — so the only
    /// thing comparable is how many. Both readings are checked for emptiness in their own right: a
    /// rename that breaks BOTH extractions leaves two zeros, which agree, and a gate that passes
    /// having compared nothing is worse than no gate.
    Census {
        /// What the two counts are called in the diagnostic.
        label: &'static str,
        /// Where the cases are; the pattern matches ONE case line.
        cases: Extract,
        /// Where the count is declared; the first capture group is the number.
        declared: Extract,
    },
    /// A `Package.swift` target must keep a dependency edge.
    ///
    /// The shell asked this as `grep -A 24 'name: "X"' | grep -q Y`, which is a WINDOW: a target
    /// whose dependency list grew past the window would report the edge missing, and one whose
    /// neighbour declared it would report it present. This reads the target's own block instead —
    /// see [`target_block`] for the two ways a naive range gets that wrong.
    Depends {
        /// The target's name, as spelled in the manifest.
        target: &'static str,
        /// The dependency's name.
        dependency: &'static str,
        /// Why the edge exists.
        message: &'static str,
    },
    /// A `Package.swift` target must NOT keep a dependency edge — [`Claim::Depends`] inverted.
    ///
    /// The manifest edge is cut for the reason the source one is: an import census is a convention,
    /// a missing dependency is a compile error. Without this, deleting the two imports leaves the
    /// phone half sitting in the Mac test target's `dependencies:`, and the next rig that wants one
    /// `some View` gets it back with a one-line import that builds.
    NotDepends {
        /// The target's name, as spelled in the manifest.
        target: &'static str,
        /// The dependency that must be gone.
        dependency: &'static str,
        /// Why the edge was cut.
        message: &'static str,
    },
    /// A set extracted from one place must equal a literal set — for an alphabet that is the wire
    /// and has no second spelling to compare against.
    PinnedSet {
        /// What the set is called in the diagnostic.
        label: &'static str,
        /// Where to read it.
        from: Extract,
        /// The members, in any order.
        expect: &'static [&'static str],
    },
}

impl Claim {
    /// Checks this claim, appending any violation to `report`.
    ///
    /// One `match` over every shape, deliberately: the arms are each a handful of lines and reading
    /// them side by side is how a reader confirms that none of them can pass vacuously.
    #[expect(
        clippy::too_many_lines,
        reason = "one arm per claim shape; splitting them hides that they share the no-vacuous-pass rule"
    )]
    pub fn check(&self, tree: &Tree, report: &mut Report) {
        match self {
            Self::Exists { path, message } => {
                report.fail_if(!tree.has(path), format!("{path} is gone — {message}"));
            },
            Self::Absent { path, message } => {
                // The FILESYSTEM, not the index: several of these name a DIRECTORY (`CSlopDeskSIMD`
                // was a whole C target), and a directory has no extension for the walk to keep.
                report.fail_if(
                    tree.root().join(path).exists(),
                    format!("{path} is back — {message}"),
                );
            },
            Self::Symlink {
                path,
                target,
                message,
            } => {
                let link = tree.root().join(path);
                let Ok(entry) = std::fs::symlink_metadata(&link) else {
                    report.fail(format!("{path} is gone — {message}"));
                    return;
                };
                if !entry.file_type().is_symlink() {
                    report.fail(format!("{path} is not a symlink — {message}"));
                    return;
                }
                // Resolved through the link, which is what makes a dangling one reportable: the
                // read fails where a `has`-style check would see a directory entry and agree.
                let (Ok(linked), Ok(source)) = (
                    std::fs::read_to_string(&link),
                    std::fs::read_to_string(tree.root().join(target)),
                ) else {
                    report.fail(format!(
                        "{path} is a symlink that resolves to nothing — {message}"
                    ));
                    return;
                };
                report.fail_if(
                    linked != source,
                    format!("{path} resolves somewhere other than {target} — {message}"),
                );
            },
            Self::Doors {
                path,
                entries,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    for entry in *entries {
                        report.fail_if(
                            !source.text.contains(&format!("{entry}(")),
                            fill(message, "entry", entry),
                        );
                    }
                }
            },
            Self::Mentions { path, names, message } => {
                if let Some(source) = report.source(tree, path, message) {
                    for name in *names {
                        report.fail_if(!source.text.contains(*name), fill(message, "entry", name));
                    }
                }
            },
            Self::MentionsUnder { root, names, message } => {
                let corpus: Vec<_> = tree.under(root).collect();
                if corpus.is_empty() {
                    report.fail(format!(
                        "{root} holds no files — a drained directory cannot answer {message}"
                    ));
                    return;
                }
                for name in *names {
                    let read = corpus.iter().any(|(_, source)| source.text.contains(*name));
                    report.fail_if(!read, fill(message, "entry", name));
                }
            },
            Self::AtLeast {
                path,
                pattern,
                minimum,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let found = text::count_lines(source.code(), pattern);
                    report.fail_if(found < *minimum, fill(message, "found", &found.to_string()));
                }
            },
            Self::Exactly {
                path,
                pattern,
                count,
                view,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let found = text::count_lines(&view.of(source), pattern);
                    report.fail_if(found != *count, fill(message, "found", &found.to_string()));
                }
            },
            Self::AtMost {
                path,
                pattern,
                maximum,
                view,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let found = text::count_lines(&view.of(source), pattern);
                    report.fail_if(found > *maximum, fill(message, "found", &found.to_string()));
                }
            },
            Self::Names {
                path,
                needle,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    report.fail_if(!source.text.contains(*needle), (*message).to_owned());
                }
            },
            Self::Matches {
                path,
                pattern,
                view,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let haystack = view.of(source);
                    report.fail_if(!text::matches(&haystack, pattern), (*message).to_owned());
                }
            },
            Self::Lacks {
                path,
                pattern,
                view,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let haystack = view.of(source);
                    // A haystack that stripped to nothing passes every ban. Say so rather than
                    // reporting the healthiest-looking result this gate can print.
                    report.fail_if(
                        haystack.trim().is_empty(),
                        format!(
                            "{path} stripped to nothing — the ban below reads an empty haystack and passes",
                        ),
                    );
                    report.fail_if(text::matches_line(&haystack, pattern), (*message).to_owned());
                }
            },
            Self::NoneOf {
                paths,
                pattern,
                view,
                message,
            } => {
                // Every named file is read, so one that was renamed away is reported rather than
                // quietly dropping its share of the ban.
                let mut offenders = Vec::new();
                for path in *paths {
                    if let Some(source) = report.source(tree, path, message) {
                        let haystack = view.of(source);
                        report.fail_if(
                            haystack.trim().is_empty(),
                            format!(
                                "{path} stripped to nothing — the ban below reads an empty haystack and \
                                 passes",
                            ),
                        );
                        if text::matches_line(&haystack, pattern) {
                            offenders.push(*path);
                        }
                    }
                }
                report.fail_if(
                    !offenders.is_empty(),
                    fill(message, "files", &offenders.join(", ")),
                );
            },
            Self::NoneUnder {
                roots,
                extensions,
                pattern,
                all,
                unless,
                view,
                exempt,
                message,
            } => {
                let mut offenders = BTreeSet::new();
                for root in *roots {
                    for (path, source) in tree.under(root) {
                        let display = path.to_string_lossy().into_owned();
                        let excused = exempt.iter().any(|entry| {
                            *entry == display || (entry.ends_with('/') && display.starts_with(*entry))
                        });
                        if excused {
                            continue;
                        }
                        let matching_extension = path
                            .extension()
                            .and_then(|ext| ext.to_str())
                            .is_some_and(|ext| extensions.contains(&ext));
                        if !matching_extension {
                            continue;
                        }
                        let haystack = view.of(source);
                        // The whole-file match first, as a filter. It cannot be narrower than the
                        // line-wise scan — a pattern matching some line matches the join of every
                        // line — so a `false` here is a conclusive `false`, which is the answer
                        // every file gives in the passing case. It is the same argument
                        // `text::matches_line` makes, spent the other way: there to be CORRECT,
                        // here to skip a per-line regex over the whole Swift tree per ban.
                        if !text::matches(&haystack, pattern) {
                            continue;
                        }
                        for line in haystack.lines() {
                            if !text::matches(line, pattern) {
                                continue;
                            }
                            if !all.iter().all(|extra| text::matches(line, extra)) {
                                continue;
                            }
                            if unless.iter().any(|excuse| text::matches(line, excuse)) {
                                continue;
                            }
                            offenders.insert(display.clone());
                            break;
                        }
                    }
                }
                if !offenders.is_empty() {
                    let named: Vec<&str> = offenders.iter().map(String::as_str).collect();
                    report.fail(fill(message, "files", &named.join(", ")));
                }
            },
            Self::NoFileUnder {
                roots,
                extensions,
                pattern,
                rescued_by,
                view,
                exempt,
                message,
            } => {
                let mut offenders = BTreeSet::new();
                for root in *roots {
                    for (path, source) in tree.under(root) {
                        let display = path.to_string_lossy().into_owned();
                        let excused = exempt.iter().any(|entry| {
                            *entry == display || (entry.ends_with('/') && display.starts_with(*entry))
                        });
                        let matching_extension = path
                            .extension()
                            .and_then(|ext| ext.to_str())
                            .is_some_and(|ext| extensions.contains(&ext));
                        if excused || !matching_extension {
                            continue;
                        }
                        let haystack = view.of(source);
                        if !text::matches(&haystack, pattern) {
                            continue;
                        }
                        if rescued_by.is_some_and(|rescue| text::matches(&haystack, rescue)) {
                            continue;
                        }
                        offenders.insert(display);
                    }
                }
                if !offenders.is_empty() {
                    let named: Vec<&str> = offenders.iter().map(String::as_str).collect();
                    report.fail(fill(message, "files", &named.join(", ")));
                }
            },
            Self::CeilingUnder {
                roots,
                extensions,
                pattern,
                view,
                maximum,
                message,
                lowered,
            } => {
                let mut carriers = BTreeSet::new();
                for root in *roots {
                    for (path, source) in tree.under(root) {
                        let matching_extension = path
                            .extension()
                            .and_then(|ext| ext.to_str())
                            .is_some_and(|ext| extensions.contains(&ext));
                        if !matching_extension {
                            continue;
                        }
                        if text::matches(&view.of(source), pattern) {
                            carriers.insert(path.to_string_lossy().into_owned());
                        }
                    }
                }
                // Both directions, and the FALL is the one that earns the claim its name. A ratchet
                // whose pin is never lowered is a ban on a number nobody re-reads; failing on the
                // way down is what turns "delete one more" into a line somebody has to write.
                let found = carriers.len();
                if found != *maximum {
                    let named: Vec<&str> = carriers.iter().map(String::as_str).collect();
                    let sentence = if found > *maximum { message } else { lowered };
                    report.fail(fill(
                        &fill(
                            &fill(sentence, "found", &found.to_string()),
                            "maximum",
                            &maximum.to_string(),
                        ),
                        "files",
                        &named.join(", "),
                    ));
                }
            },
            Self::NoCloneAcross {
                left,
                right,
                extensions,
                window,
                known,
                floor,
                message,
            } => {
                let (ours, theirs) = (
                    shingles(tree, left, extensions, *window),
                    shingles(tree, right, extensions, *window),
                );
                if ours.files < *floor || theirs.files < *floor {
                    report.fail(format!(
                        "only {}/{} files globbed under {left} and {right} (floor {floor}) — this claim \
                         would pass by reading nothing",
                        ours.files, theirs.files,
                    ));
                    return;
                }
                // Grouped by FILE PAIR rather than reported per shingle: the debt list is kept at
                // that grain, and one clone spans as many windows as it has lines.
                let mut pairs: std::collections::BTreeMap<(&str, &str), (&str, &str)> =
                    std::collections::BTreeMap::new();
                for (body, here) in &ours.windows {
                    let Some(there) = theirs.windows.get(body) else {
                        continue;
                    };
                    pairs
                        .entry((here.path.as_str(), there.path.as_str()))
                        .or_insert((here.site.as_str(), there.site.as_str()));
                }
                let strangers: Vec<String> = pairs
                    .iter()
                    .filter(|(pair, _)| !known.contains(pair))
                    .map(|(_, (here, there))| format!("{here} == {there}"))
                    .collect();
                report.fail_if(
                    !strangers.is_empty(),
                    fill(message, "pairs", &strangers.join(", ")),
                );
                for pair in *known {
                    report.fail_if(
                        !pairs.contains_key(pair),
                        format!(
                            "the clone ledger names {} and {}, which no longer share a body — the debt is \
                             PAID, so drop the entry rather than leaving it to excuse the clone growing \
                             back (docs/56 §3)",
                            pair.0, pair.1,
                        ),
                    );
                }
            },
            Self::NoneQuoting {
                roots,
                extensions,
                needles,
                template,
                view,
                exempt,
                message,
            } => {
                let Some(words) = needles.set(tree, report) else {
                    return;
                };
                if words.is_empty() {
                    report.fail(format!(
                        "no strings parsed out of {} — {message} would pass by forbidding nothing",
                        needles.path
                    ));
                    return;
                }
                let quotations: Vec<String> =
                    words.iter().map(|word| fill(template, "needle", word)).collect();
                let mut offenders = BTreeSet::new();
                for root in *roots {
                    for (path, source) in tree.under(root) {
                        let display = path.to_string_lossy().into_owned();
                        let excused = exempt.iter().any(|entry| {
                            *entry == display || (entry.ends_with('/') && display.starts_with(*entry))
                        });
                        let matching_extension = path
                            .extension()
                            .and_then(|ext| ext.to_str())
                            .is_some_and(|ext| extensions.contains(&ext));
                        if excused || !matching_extension {
                            continue;
                        }
                        let haystack = view.of(source);
                        if quotations.iter().any(|quoted| haystack.contains(quoted)) {
                            offenders.insert(display);
                        }
                    }
                }
                if !offenders.is_empty() {
                    let named: Vec<&str> = offenders.iter().map(String::as_str).collect();
                    report.fail(fill(message, "files", &named.join(", ")));
                }
            },
            Self::Resolved {
                label,
                needles,
                halves,
                template,
                view,
                message,
            } => {
                let Some(rungs) = needles.set(tree, report) else {
                    return;
                };
                if rungs.is_empty() {
                    report.fail(format!(
                        "no {label} rungs parsed out of {} — this claim would pass by demanding nothing of \
                         anybody",
                        needles.path
                    ));
                    return;
                }
                let present: Vec<&&str> = halves.iter().filter(|half| tree.has(half)).collect();
                if present.is_empty() {
                    report.fail(format!(
                        "not one of the {} renderers of {label} is in the tree — the table is resolved by \
                         nobody and this claim reads as green",
                        halves.len()
                    ));
                    return;
                }
                for half in present {
                    let Some(source) = tree.get(half) else {
                        continue;
                    };
                    let haystack = view.of(source);
                    for rung in &rungs {
                        let pattern = fill(template, "needle", rung);
                        report.fail_if(
                            !text::matches(&haystack, &pattern),
                            fill(&fill(message, "half", half), "needle", rung),
                        );
                    }
                }
            },
            Self::PerFileCounts {
                roots,
                extensions,
                expect,
                view,
                exempt,
                message,
            } => {
                let mut offenders = BTreeSet::new();
                for root in *roots {
                    for (path, source) in tree.under(root) {
                        let display = path.to_string_lossy().into_owned();
                        let excused = exempt.iter().any(|entry| {
                            *entry == display || (entry.ends_with('/') && display.starts_with(*entry))
                        });
                        let matching_extension = path
                            .extension()
                            .and_then(|ext| ext.to_str())
                            .is_some_and(|ext| extensions.contains(&ext));
                        if excused || !matching_extension {
                            continue;
                        }
                        let haystack = view.of(source);
                        let readings: Vec<String> = expect
                            .iter()
                            .map(|(pattern, _)| text::count_lines(&haystack, pattern).to_string())
                            .collect();
                        let agrees = expect
                            .iter()
                            .zip(&readings)
                            .all(|((_, want), got)| got == &want.to_string());
                        if !agrees {
                            offenders.insert(format!("{display} ({})", readings.join("/")));
                        }
                    }
                }
                if !offenders.is_empty() {
                    let named: Vec<&str> = offenders.iter().map(String::as_str).collect();
                    report.fail(fill(message, "files", &named.join(", ")));
                }
            },
            Self::Within {
                path,
                start,
                end,
                pattern,
                view,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let block = text::range(&view.of(source), start, end);
                    report.fail_if(!text::matches(&block, pattern), message.to_owned());
                }
            },
            Self::Before {
                path,
                first,
                second,
                view,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let haystack = view.of(source);
                    // Line numbers rather than byte offsets, which is what the shell compared and
                    // what a diagnostic can be read against.
                    let line_of = |pattern: &str| {
                        let regex = text::cached(pattern);
                        haystack.lines().position(|line| regex.is_match(line))
                    };
                    let (Some(early), Some(late)) = (line_of(first), line_of(second)) else {
                        report.fail(format!(
                            "{path} no longer spells both halves of an ordered pair — {message}"
                        ));
                        return;
                    };
                    report.fail_if(early >= late, (*message).to_owned());
                }
            },
            Self::LacksWithin {
                path,
                start,
                end,
                pattern,
                view,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let block = text::range(&view.of(source), start, end);
                    if block.trim().is_empty() {
                        report.fail(format!(
                            "{path} no longer holds {start} — {message} is a ban over nothing"
                        ));
                        return;
                    }
                    report.fail_if(text::matches_line(&block, pattern), message.to_owned());
                }
            },
            Self::Populated {
                roots,
                extensions,
                minimum,
                message,
            } => {
                let found = roots
                    .iter()
                    .flat_map(|root| tree.under(root))
                    .filter(|(path, _)| {
                        path.extension()
                            .and_then(|ext| ext.to_str())
                            .is_some_and(|ext| extensions.contains(&ext))
                    })
                    .count();
                report.fail_if(found < *minimum, fill(message, "found", &found.to_string()));
            },
            Self::Opening {
                path,
                forbidden,
                message,
            } => {
                if let Some(source) = report.source(tree, path, message) {
                    let opens = source
                        .text
                        .lines()
                        .map(str::trim)
                        .find(|line| !line.is_empty() && !line.starts_with("//"));
                    report.fail_if(
                        opens.is_some_and(|line| forbidden.contains(&line)),
                        message.to_owned(),
                    );
                }
            },
            Self::SameSet { label, swift, rust } => {
                let (Some(left), Some(right)) = (swift.set(tree, report), rust.set(tree, report)) else {
                    return;
                };
                report.same_set(label, &left, &right);
            },
            Self::Overlap {
                label,
                left,
                right,
                mark,
                message,
            } => {
                let (Some(ours), Some(theirs)) = (left.set(tree, report), right.set(tree, report)) else {
                    return;
                };
                if ours.is_empty() || theirs.is_empty() {
                    report.fail(format!(
                        "the {label} overlap read EMPTY ({} of {}, {} of {}) — this claim would pass \
                         vacuously",
                        ours.len(),
                        left.path,
                        theirs.len(),
                        right.path,
                    ));
                    return;
                }
                let mut shared: Vec<&str> = ours
                    .iter()
                    .filter(|m| theirs.contains(*m))
                    .map(String::as_str)
                    .collect();
                shared.sort_unstable();
                let found = shared.len();
                if found > *mark {
                    report.fail(fill(
                        &fill(message, "shared", &shared.join(" ")),
                        "found",
                        &found.to_string(),
                    ));
                } else if found < *mark {
                    report.fail(format!(
                        "the {label} overlap is down to {found} from {mark} — lower the mark to {found} so \
                         the ground gained is held"
                    ));
                }
            },
            Self::Subset {
                label,
                subject,
                universe,
                message,
            } => {
                // Both sides are read before either is judged, so a diagnostic names every missing
                // file rather than the first one.
                let (Some(members), Some(holder)) = (subject.set(tree, report), universe.set(tree, report))
                else {
                    return;
                };
                if members.is_empty() || holder.is_empty() {
                    report.fail(format!(
                        "the {label} comparison read EMPTY ({} of {}, {} of {}) — this claim has stopped \
                         checking anything",
                        members.len(),
                        subject.path,
                        holder.len(),
                        universe.path,
                    ));
                    return;
                }
                let orphans: Vec<&str> = members
                    .iter()
                    .filter(|member| !holder.contains(*member))
                    .map(String::as_str)
                    .collect();
                report.fail_if(!orphans.is_empty(), fill(message, "orphans", &orphans.join(" ")));
            },
            Self::SubsetUnder {
                label,
                subject,
                universe,
                floor,
                message,
            } => {
                let members = subject.set(tree);
                let Some(holder) = universe.set(tree, report) else {
                    return;
                };
                if members.len() < *floor {
                    report.fail(format!(
                        "only {} {label} found under {} (floor {floor}) — this extraction has gone stale \
                         and is now checking nothing",
                        members.len(),
                        subject.root,
                    ));
                    return;
                }
                if holder.is_empty() {
                    report.fail(format!(
                        "{} serves no {label} at all — this claim has stopped checking anything",
                        universe.path,
                    ));
                    return;
                }
                let orphans: Vec<&str> = members
                    .iter()
                    .filter(|member| !holder.contains(*member))
                    .map(String::as_str)
                    .collect();
                report.fail_if(!orphans.is_empty(), fill(message, "orphans", &orphans.join(" ")));
            },
            Self::OverlapUnder {
                label,
                left,
                right,
                ceiling,
                floor,
                message,
            } => {
                let (ours, theirs) = (left.set(tree), right.set(tree));
                if ours.len() < *floor || theirs.len() < *floor {
                    report.fail(format!(
                        "only {}/{} {label} read under {} and {} (floor {floor}) — this ceiling would hold \
                         by reading nothing",
                        ours.len(),
                        theirs.len(),
                        left.root,
                        right.root,
                    ));
                    return;
                }
                let shared: Vec<&str> = ours
                    .iter()
                    .filter(|m| theirs.contains(*m))
                    .map(String::as_str)
                    .collect();
                let found = shared.len();
                report.fail_if(
                    found > *ceiling,
                    fill(
                        &fill(
                            &fill(message, "found", &found.to_string()),
                            "ceiling",
                            &ceiling.to_string(),
                        ),
                        "shared",
                        &shared.join(", "),
                    ),
                );
            },
            Self::EachMatches {
                label,
                from,
                pattern,
                message,
            } => {
                let Some(members) = from.set(tree, report) else {
                    return;
                };
                if members.is_empty() {
                    report.fail(format!(
                        "the {label} set read EMPTY out of {} — this claim has stopped checking anything",
                        from.path
                    ));
                    return;
                }
                let regex = text::cached(pattern);
                let stray: Vec<&str> = members
                    .iter()
                    .filter(|member| !regex.is_match(member))
                    .map(String::as_str)
                    .collect();
                report.fail_if(!stray.is_empty(), fill(message, "members", &stray.join(" ")));
            },
            Self::SameSetUnder {
                label,
                left,
                right,
                left_only,
                floor,
            } => {
                let (mut mine, theirs) = (left.set(tree), right.set(tree));
                if mine.len() < *floor {
                    report.fail(format!(
                        "only {} {label} found under {} (floor {floor}) — this extraction has gone stale \
                         and is now checking nothing",
                        mine.len(),
                        left.root,
                    ));
                    return;
                }
                for excused in *left_only {
                    report.fail_if(
                        !mine.contains(*excused),
                        format!(
                            "the {label} ledger names {excused}, which {} no longer holds either — the \
                             asymmetry is gone, so delete the entry",
                            left.root,
                        ),
                    );
                    report.fail_if(
                        theirs.contains(*excused),
                        format!(
                            "the {label} ledger excuses {excused}, but {} now holds it — delete the entry",
                            right.root,
                        ),
                    );
                    mine.remove(*excused);
                }
                report.same_set(label, &mine, &theirs);
            },
            Self::SameValue { label, swift, rust } => {
                // Both sides are read even when the first is absent, so a diagnostic names every
                // missing file rather than the first one.
                let (left, right) = (swift.value(tree, report), rust.value(tree, report));
                report.same(label, left.as_deref(), right.as_deref());
            },
            Self::Pinned { label, from, expect } => {
                let found = from.value(tree, report);
                report.same(label, found.as_deref(), Some(&expect.replace(' ', "")));
            },
            Self::Census {
                label,
                cases,
                declared,
            } => {
                // Both readings are checked for emptiness BEFORE they are compared, and a reading
                // that matched nothing at all is as empty as one that counted zero. An early
                // `return` on a `None` here is what a vacuous pass looks like: a renamed constant
                // stops matching, the claim compares nothing, and the gate stays green.
                let counted = cases.count(tree, report);
                let text = declared.value(tree, report);
                let stated = text.as_ref().and_then(|value| value.parse::<usize>().ok());
                if counted.is_none_or(|n| n == 0) || stated.is_none_or(|n| n == 0) {
                    report.fail(format!(
                        "the {label} census read EMPTY (counted={counted:?} declared={text:?}) — this claim \
                         has stopped checking anything"
                    ));
                    return;
                }
                report.same(
                    label,
                    counted.map(|n| n.to_string()).as_deref(),
                    stated.map(|n| n.to_string()).as_deref(),
                );
            },
            Self::Depends {
                target,
                dependency,
                message,
            } => {
                if let Some(source) = report.source(tree, "Package.swift", message) {
                    let manifest = View::Code.of(source);
                    let block = target_block(&manifest, target);
                    report.fail_if(
                        block.is_empty() || !block.contains(dependency),
                        format!("{target} dropped {dependency} — {message}"),
                    );
                }
            },
            Self::NotDepends {
                target,
                dependency,
                message,
            } => {
                if let Some(source) = report.source(tree, "Package.swift", message) {
                    let manifest = View::Code.of(source);
                    let block = target_block(&manifest, target);
                    // An empty block is a target that has been renamed away, which is a stale ledger
                    // rather than a satisfied ban.
                    report.fail_if(
                        block.is_empty(),
                        format!(
                            "Package.swift no longer declares {target} — {message} is a ban over nothing"
                        ),
                    );
                    report.fail_if(
                        block.contains(dependency),
                        format!("{target} depends on {dependency} again — {message}"),
                    );
                }
            },
            Self::SameByteMap { label, swift, rust } => {
                // Both sides are read before either is judged, so a marker that lost its uniqueness
                // on one side is reported alongside whatever the other side says.
                let (ours, theirs) = (swift.read(tree, report, label), rust.read(tree, report, label));
                let (Some(ours), Some(theirs)) = (ours, theirs) else {
                    return;
                };
                if ours.is_empty() || theirs.is_empty() {
                    report.fail(format!(
                        "{label}: one side's byte map read as EMPTY ({} of {}, {} of {}) — the switch moved \
                         or changed shape, so this claim stopped checking anything (docs/55)",
                        ours.len(),
                        swift.path,
                        theirs.len(),
                        rust.path,
                    ));
                    return;
                }
                let disagreeing: Vec<String> = ours
                    .iter()
                    .filter(|(name, byte)| theirs.get(*name) != Some(*byte))
                    .chain(
                        theirs
                            .iter()
                            .filter(|(name, byte)| ours.get(*name) != Some(*byte)),
                    )
                    .map(|(name, byte)| format!("{name}={byte}"))
                    .collect();
                report.fail_if(
                    !disagreeing.is_empty(),
                    format!(
                        "{label}: the two languages disagree about which byte a case crosses as — {} \
                         (docs/55)",
                        disagreeing.join(" "),
                    ),
                );
            },
            Self::PinnedSet { label, from, expect } => {
                let Some(found) = from.set(tree, report) else {
                    return;
                };
                let want: BTreeSet<String> = expect.iter().map(|member| (*member).to_owned()).collect();
                report.same_set(label, &found, &want);
            },
        }
    }
}

/// Where one window of a body was first seen.
struct Site {
    /// The file, repo-relative.
    path: String,
    /// That file and the line the window opens on, as `path:line`.
    site: String,
}

/// Every window of substantive lines under one root, and how many files it read.
struct Shingles {
    /// The file count, for the vacuity floor.
    files: usize,
    /// Each normalised window, against the FIRST place it was seen.
    windows: std::collections::BTreeMap<String, Site>,
}

/// Every `window`-line body under `root`, normalised so only a real duplicate collides.
///
/// The normalisation is the whole rule: a trailing `//` comment is cut, indentation goes, and a
/// line that is only punctuation is dropped. Without those a reformat hides a clone and a run of
/// closing braces manufactures one. `import`, `@attribute` and `#if` lines go too — two view files
/// legitimately import the same six modules, and that is a coincidence of the split rather than a
/// duplicated decision.
///
/// The first sighting wins, so the diagnostic names where a body was introduced rather than
/// wherever the walk happened to end.
fn shingles(tree: &Tree, root: &str, extensions: &[&str], window: usize) -> Shingles {
    let noise = text::cached(r"^[^\p{L}\p{N}]*$");
    let carried = text::cached(r"^(import|@|#(if|else|elseif|endif))");
    let comment = text::cached(r"//.*$");
    let mut out = Shingles {
        files: 0,
        windows: std::collections::BTreeMap::new(),
    };
    for (path, source) in tree.under(root) {
        let matching_extension = path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| extensions.contains(&ext));
        if !matching_extension {
            continue;
        }
        out.files += 1;
        let display = path.to_string_lossy().into_owned();
        let body: Vec<(usize, String)> = source
            .text
            .lines()
            .enumerate()
            .map(|(index, line)| (index + 1, comment.replace(line, "").trim().to_owned()))
            .filter(|(_, line)| !noise.is_match(line) && !carried.is_match(line))
            .collect();
        for start in 0..(body.len() + 1).saturating_sub(window.max(1)) {
            let joined = body[start..start + window]
                .iter()
                .map(|(_, line)| line.as_str())
                .collect::<Vec<_>>()
                .join(" ~ ");
            out.windows.entry(joined).or_insert_with(|| {
                Site {
                    path: display.clone(),
                    site: format!("{display}:{}", body[start].0),
                }
            });
        }
    }
    out
}

/// The lines of one `Package.swift` target's declaration, dependency list and all.
///
/// A target is found by the line that names it ALONE — `name: "SlopDeskProtocol",` on its own line,
/// the way every multi-line `.target(…)` in this manifest is written. Matching the name anywhere
/// would find the single-line `.library(name: "SlopDeskProtocol", targets: […])` first, and a
/// library declaration names no dependencies at all, so every edge would read as dropped.
///
/// The block ends at the next line that names something — again alone, so a nested
/// `.product(name: "X", package: "y")` inside the dependency list does not close the block it is
/// part of. That was the other half of the same bug.
fn target_block(manifest: &str, target: &str) -> String {
    let names_alone = |line: &str| {
        let trimmed = line.trim();
        trimmed.starts_with(r#"name: ""#) && trimmed.ends_with(',')
    };
    let opens = format!(r#"name: "{target}","#);
    manifest
        .lines()
        .skip_while(|line| line.trim() != opens)
        .skip(1)
        .take_while(|line| !names_alone(line))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Substitutes one `{name}` placeholder in a claim's sentence.
///
/// Written out rather than inlined because a `"…{entry}…".replace(…)` reads to clippy as a
/// formatting string that lost its macro — which it is not: the placeholder is filled at CHECK
/// time, from a value the claim does not have when it is written down.
fn fill(message: &str, placeholder: &str, value: &str) -> String {
    message.replace(&format!("{{{placeholder}}}"), value)
}

/// Checks a table of claims, one report for the lot.
#[must_use]
pub fn check_all(tree: &Tree, claims: &[Claim]) -> Report {
    let mut report = Report::new();
    for claim in claims {
        claim.check(tree, &mut report);
    }
    report
}

/// The extensions a source-code ban reads. Named once because every `NoneUnder` over `Sources/`
/// wants exactly this and a claim that forgot one would go quietly narrow.
pub const SWIFT: &[&str] = &["swift"];
/// Rust sources.
pub const RUST: &[&str] = &["rs"];

/// Where this gate's own rule tables live, exempted from every tree-wide ban that reads `rust/`.
///
/// A ban has to WRITE DOWN the thing it forbids, so the file stating "no second base64 alphabet"
/// contains a base64 alphabet. The shell never had to say this: it searched `rust/*/src` and its
/// own text was in `scripts/`. Moving the rules into a crate under `rust/` brought the gate inside
/// its own corpus, and a gate that reports itself reports nothing anybody can act on.
///
/// This is narrow on purpose — the RULES directory, not the crate. `claim.rs`, `text.rs` and
/// `tree.rs` are ordinary Rust that scans bytes for a living, and they stay inside every ban.
pub const GATE_RULES: &str = "rust/slopdesk-invariants/src/rules/";

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use super::{Claim, Extract, RUST, SWIFT, View, check_all};
    use crate::tree::Tree;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("slopdesk-claim-{name}"));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).expect("fixture root");
            Self(root)
        }

        fn write(&self, path: &str, contents: &str) -> &Self {
            let full = self.0.join(path);
            fs::create_dir_all(full.parent().expect("parent")).expect("dirs");
            fs::write(full, contents).expect("write");
            self
        }

        fn tree(&self) -> Tree {
            Tree::load(&self.0).expect("tree")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// The failure a gate cannot notice by reading its own output: a ban whose file was renamed.
    #[test]
    fn a_ban_over_a_missing_file_fails_instead_of_passing() {
        let fixture = Fixture::new("missing");
        fixture.write("Sources/Other.swift", "let x = 1\n");
        let claims = [Claim::Lacks {
            path: "Sources/Gone.swift",
            pattern: "banned",
            view: View::Code,
            message: "the ban's file must exist",
        }];
        let report = check_all(&fixture.tree(), &claims);
        assert!(
            report.violations().iter().any(|v| v.contains("is gone")),
            "{report:?}"
        );
    }

    /// A corpus subset unions its senders, so the floor — not emptiness — is what notices a
    /// half-stale extraction: one file that stopped answering leaves the union non-empty.
    #[test]
    fn a_corpus_subset_reads_every_sender_and_floors_the_union() {
        let fixture = Fixture::new("subset-under");
        let claims = |floor| {
            [Claim::SubsetUnder {
                label: "bridge ops",
                subject: super::Corpus {
                    root: "Sources/Panel",
                    extensions: SWIFT,
                    pattern: r#""op": "([a-z]+)""#,
                    view: View::Code,
                },
                universe: Extract::code("rust/d/src/server.rs", r#"^ *"([a-z]+)" =>"#),
                floor,
                message: "the panel sends {orphans} with no arm serving it",
            }]
        };
        fixture
            .write("Sources/Panel/Stream.swift", "let a = [\"op\": \"boot\"]\n")
            .write("Sources/Panel/Log.swift", "let b = [\"op\": \"logcat\"]\n")
            .write(
                "rust/d/src/server.rs",
                "match op {\n    \"boot\" => go(),\n    \"logcat\" => tail(),\n    _ => bad(),\n}\n",
            );
        assert!(check_all(&fixture.tree(), &claims(2)).is_clean());

        // The second sender's op has no arm — named, not counted.
        fixture.write("Sources/Panel/Log.swift", "let b = [\"op\": \"screenshot\"]\n");
        let report = check_all(&fixture.tree(), &claims(2));
        assert!(
            report.violations().iter().any(|v| v.contains("screenshot")),
            "{report:?}"
        );

        // And the union that fell below its floor says the extraction went stale, not that the
        // daemon is fine — which is what it would say if only emptiness were checked.
        fixture.write("Sources/Panel/Log.swift", "let b = [Op.screenshot]\n");
        let report = check_all(&fixture.tree(), &claims(2));
        assert!(
            report.violations().iter().any(|v| v.contains("floor 2")),
            "{report:?}"
        );
    }

    /// The other one: a file that became all comment reads as satisfying every ban.
    #[test]
    fn a_file_that_stripped_to_nothing_says_so() {
        let fixture = Fixture::new("all-comment");
        fixture.write("Sources/Empty.swift", "// only prose, naming banned\n");
        let claims = [Claim::Lacks {
            path: "Sources/Empty.swift",
            pattern: "banned",
            view: View::Code,
            message: "banned must not appear",
        }];
        let report = check_all(&fixture.tree(), &claims);
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stripped to nothing")),
            "{report:?}"
        );
    }

    #[test]
    fn an_exemption_is_honoured_and_everything_else_is_named() {
        let fixture = Fixture::new("exempt");
        fixture
            .write("Sources/Allowed.swift", "CGWindowListCopyWindowInfo()\n")
            .write("Sources/Banned.swift", "CGWindowListCopyWindowInfo()\n")
            .write("Sources/Fine.swift", "let y = 2\n");
        let claims = [Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "CGWindowListCopyWindowInfo",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/Allowed.swift"],
            message: "these decode a window record themselves: {files}",
        }];
        let report = check_all(&fixture.tree(), &claims);
        assert_eq!(report.violations().len(), 1);
        assert!(
            report.violations()[0].ends_with("Sources/Banned.swift"),
            "{report:?}"
        );
    }

    /// A ban over Rust sources reads past `#[cfg(test)]` only when asked to, because the test that
    /// proves the absence has to spell the banned thing.
    #[test]
    fn a_rust_ban_can_stop_at_the_test_module() {
        let fixture = Fixture::new("cfg-test");
        fixture.write(
            "rust/a/src/lib.rs",
            "pub fn f() {}\n#[cfg(test)]\nmod tests {\n    // asserts getpid() is absent\n    fn t() { let \
             _ = \"getpid\"; }\n}\n",
        );
        let stops = [Claim::Lacks {
            path: "rust/a/src/lib.rs",
            pattern: "getpid",
            view: View::CodeBeforeTests,
            message: "a pid reached the path",
        }];
        assert!(check_all(&fixture.tree(), &stops).is_clean());

        let reads_all = [Claim::Lacks {
            path: "rust/a/src/lib.rs",
            pattern: "getpid",
            view: View::Code,
            message: "a pid reached the path",
        }];
        assert!(!check_all(&fixture.tree(), &reads_all).is_clean());
        let _ = RUST;
    }

    /// One file per shell, plus the padding a corpus floor needs.
    fn shells(fixture: &Fixture, left: &str, right: &str) {
        for (root, body) in [("Left", left), ("Right", right)] {
            fixture.write(&format!("Sources/{root}/Leaf.swift"), body);
            for index in 0..6 {
                fixture.write(
                    &format!("Sources/{root}/Filler{index}.swift"),
                    &format!("struct Filler{index} {{ let n = {index} }}\n"),
                );
            }
        }
    }

    /// Four substantive lines, tail included, under a comment and an import that are both dropped.
    fn body(tail: &str) -> String {
        format!(
            "import SwiftUI\n// a re-worded comment cannot hide a clone\nlet a = 1\nlet b = 2\nlet c = \
             3\n{tail}\n"
        )
    }

    /// The clone ledger is a debt list, so it fails BOTH ways.
    #[test]
    fn a_paid_clone_debt_must_leave_the_ledger() {
        const LEDGER: &[(&str, &str)] = &[("Sources/Left/Leaf.swift", "Sources/Right/Leaf.swift")];

        let fixture = Fixture::new("clone-ledger");
        let claims = |known| {
            [Claim::NoCloneAcross {
                left: "Sources/Left/",
                right: "Sources/Right/",
                extensions: SWIFT,
                window: 4,
                known,
                floor: 5,
                message: "a body is written twice: {pairs}",
            }]
        };

        // Ledgered, and still a clone: green, because the debt is on the record.
        shells(&fixture, &body("let d = 4"), &body("let d = 4"));
        assert!(check_all(&fixture.tree(), &claims(LEDGER)).is_clean());

        // The same clone with no ledger entry is the finding this claim exists for.
        let report = check_all(&fixture.tree(), &claims(&[]));
        assert!(
            report.violations().iter().any(|v| v.contains("written twice")),
            "{report:?}"
        );

        // Deduplicated, and the ledger entry left behind: the debt is PAID, and an entry that has
        // stopped excusing anything would go on excusing the clone growing back.
        shells(&fixture, &body("let d = 4"), "let z = 9\n");
        let report = check_all(&fixture.tree(), &claims(LEDGER));
        assert!(
            report.violations().iter().any(|v| v.contains("debt is PAID")),
            "{report:?}"
        );
    }

    /// A reformat and a re-worded comment cannot hide a clone; a run of braces cannot make one.
    #[test]
    fn normalisation_survives_a_reformat_and_refuses_punctuation() {
        let fixture = Fixture::new("clone-normalise");
        let claims = [Claim::NoCloneAcross {
            left: "Sources/Left/",
            right: "Sources/Right/",
            extensions: SWIFT,
            window: 4,
            known: &[],
            floor: 5,
            message: "a body is written twice: {pairs}",
        }];

        // Re-indented, re-commented, and with a different import list — still the same body.
        shells(
            &fixture,
            &body("let d = 4"),
            "import Combine\nimport SwiftUI\n// entirely different prose\n    let a = 1\n\x20 let b = \
             2\n\tlet c = 3\nlet d = 4\n",
        );
        assert!(!check_all(&fixture.tree(), &claims).is_clean());

        // Four lines of closing punctuation on each side, which is not a duplicated decision.
        shells(&fixture, "let p = 1\n}\n}\n)\n]\n", "let q = 2\n}\n}\n)\n]\n");
        assert!(check_all(&fixture.tree(), &claims).is_clean());
    }

    #[test]
    fn a_pinned_number_ignores_spacing_but_not_value() {
        let fixture = Fixture::new("pinned");
        fixture.write("rust/a/src/lib.rs", "pub const CAP: usize = 4 * 1024 * 1024;\n");
        let ok = [Claim::Pinned {
            label: "cap",
            from: Extract::code("rust/a/src/lib.rs", r"CAP: usize = (.*);"),
            expect: "4*1024*1024",
        }];
        assert!(check_all(&fixture.tree(), &ok).is_clean());

        let wrong = [Claim::Pinned {
            label: "cap",
            from: Extract::code("rust/a/src/lib.rs", r"CAP: usize = (.*);"),
            expect: "8*1024*1024",
        }];
        assert!(!check_all(&fixture.tree(), &wrong).is_clean());
    }
}
