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
    /// No file under any of `roots` may match, except the ones named in `exempt`.
    ///
    /// The exemptions are a LIST rather than a pattern on purpose: an exemption is a decision on
    /// the record, and one that a glob could silently widen is not one.
    NoneUnder {
        /// Path prefixes to scan.
        roots: &'static [&'static str],
        /// Only files with one of these extensions are read.
        extensions: &'static [&'static str],
        /// The pattern.
        pattern: &'static str,
        /// Which view to read.
        view: View,
        /// Paths that may match, each because somebody decided so.
        exempt: &'static [&'static str],
        /// The sentence, with `{files}` where the offenders go.
        message: &'static str,
    },
    /// Two sets, extracted from two files, must be equal.
    SameSet {
        /// What the two sets are called in the diagnostic.
        label: &'static str,
        /// The Swift side's file and extraction.
        swift: (&'static str, &'static str),
        /// The Rust side's file and extraction.
        rust: (&'static str, &'static str),
    },
    /// Two single values, extracted from two files, must agree — the shell's `same`.
    SameValue {
        /// What the value is called in the diagnostic.
        label: &'static str,
        /// The Swift side's file and extraction.
        swift: (&'static str, &'static str),
        /// The Rust side's file and extraction.
        rust: (&'static str, &'static str),
    },
    /// One extracted value must equal a literal — a one-sided pin, for a number that is the WIRE
    /// rather than a copy of anything.
    Pinned {
        /// What the value is called in the diagnostic.
        label: &'static str,
        /// The file and extraction.
        from: (&'static str, &'static str),
        /// The value, with whitespace removed before comparison.
        expect: &'static str,
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
                    report.fail_if(text::matches(&haystack, pattern), (*message).to_owned());
                }
            },
            Self::NoneUnder {
                roots,
                extensions,
                pattern,
                view,
                exempt,
                message,
            } => {
                let mut offenders = Vec::new();
                for root in *roots {
                    for (path, source) in tree.under(root) {
                        let display = path.to_string_lossy().into_owned();
                        if exempt.contains(&display.as_str()) {
                            continue;
                        }
                        let matching_extension = path
                            .extension()
                            .and_then(|ext| ext.to_str())
                            .is_some_and(|ext| extensions.contains(&ext));
                        if !matching_extension {
                            continue;
                        }
                        if text::matches(&view.of(source), pattern) {
                            offenders.push(display);
                        }
                    }
                }
                if !offenders.is_empty() {
                    offenders.sort_unstable();
                    report.fail(message.replace("{files}", &offenders.join(", ")));
                }
            },
            Self::SameSet { label, swift, rust } => {
                let (Some(left), Some(right)) = (
                    report.source(tree, swift.0, "one side of a set comparison lives there"),
                    report.source(tree, rust.0, "one side of a set comparison lives there"),
                ) else {
                    return;
                };
                let left: BTreeSet<String> = text::capture_set(&left.text, swift.1);
                let right: BTreeSet<String> = text::capture_set(&right.text, rust.1);
                report.same_set(label, &left, &right);
            },
            Self::SameValue { label, swift, rust } => {
                let (Some(left), Some(right)) = (
                    report.source(tree, swift.0, "one side of a value comparison lives there"),
                    report.source(tree, rust.0, "one side of a value comparison lives there"),
                ) else {
                    return;
                };
                report.same(
                    label,
                    text::capture_first(&left.text, swift.1)
                        .map(|value| value.replace(' ', ""))
                        .as_deref(),
                    text::capture_first(&right.text, rust.1)
                        .map(|value| value.replace(' ', ""))
                        .as_deref(),
                );
            },
            Self::Pinned { label, from, expect } => {
                let Some(source) = report.source(tree, from.0, "a pinned value lives there") else {
                    return;
                };
                report.same(
                    label,
                    text::capture_first(&source.text, from.1)
                        .map(|value| value.replace(' ', ""))
                        .as_deref(),
                    Some(&expect.replace(' ', "")),
                );
            },
        }
    }
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

    use super::{Claim, RUST, SWIFT, View, check_all};
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
            from: ("rust/a/src/lib.rs", r"CAP: usize = (.*);"),
            expect: "4*1024*1024",
        }];
        assert!(check_all(&fixture.tree(), &ok).is_clean());

        let wrong = [Claim::Pinned {
            label: "cap",
            from: ("rust/a/src/lib.rs", r"CAP: usize = (.*);"),
            expect: "8*1024*1024",
        }];
        assert!(!check_all(&fixture.tree(), &wrong).is_clean());
    }
}
