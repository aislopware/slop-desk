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

use std::collections::BTreeSet;

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
}

impl View {
    fn of(self, source: &crate::tree::Source) -> std::borrow::Cow<'_, str> {
        match self {
            Self::Raw => std::borrow::Cow::Borrowed(&source.text),
            Self::Code => std::borrow::Cow::Borrowed(source.code()),
            Self::CodeBeforeTests => {
                std::borrow::Cow::Owned(text::before(source.code(), r"#\[cfg\(test\)\]"))
            },
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
    /// Two sets, extracted from two places, must be equal.
    SameSet {
        /// What the two sets are called in the diagnostic.
        label: &'static str,
        /// The Swift side.
        swift: Extract,
        /// The Rust side.
        rust: Extract,
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
            Self::SameSet { label, swift, rust } => {
                let (Some(left), Some(right)) = (swift.set(tree, report), rust.set(tree, report)) else {
                    return;
                };
                report.same_set(label, &left, &right);
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
