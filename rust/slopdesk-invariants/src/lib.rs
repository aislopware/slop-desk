//! The cross-language contract ratchets, as rules over one in-memory tree.
//!
//! ## What a rule is
//! A function `fn(&Tree) -> Report`. It reads source text and records violations; it does not
//! print, does not exit, and does not know whether anything else ran. That shape is what makes the
//! three things this crate exists for possible at once: rules run in parallel because none of them
//! shares mutable state, a rule's break-test is a unit test because a [`Report`] is a value, and
//! the whole set can be diffed against the shell it replaces because the violations are strings the
//! shell also printed.
//!
//! ## What survived the port unchanged, on purpose
//! Every rule keeps its original diagnostic wording, including the `docs/…` citation. The message
//! is the interface: it is what a reader sees on the day the rule fires, and it names the section
//! that explains why the rule exists. Rewording them would have made the differential mode — run
//! both, diff the violation sets — compare nothing.
//!
//! ## Reading order
//! [`tree`] is the index, [`text`] is the four extraction shapes the shell had, [`report`] is
//! `fail` and `same`, and [`rules`] is one module per section of the gate this replaces.

pub mod claim;
pub mod paths;
pub mod report;
pub mod rules;
pub mod text;
pub mod tree;
pub mod vocabulary;

pub use report::Report;
pub use tree::{Source, Tree};

/// One named invariant.
pub struct Rule {
    /// What the rule is called on the command line and in `--only`.
    pub name: &'static str,
    /// The section of the shell gate, or the doc, this rule came from — printed with a violation so
    /// a reader lands in the right place.
    pub origin: &'static str,
    /// The check itself.
    pub check: fn(&Tree) -> Report,
}

/// Every rule, in the order the shell ran them.
///
/// The order is cosmetic — rules are independent and rayon runs them in whatever order it likes —
/// but the OUTPUT is sorted back into it, because a gate whose failures move around between runs is
/// one nobody can diff.
#[must_use]
pub fn all_rules() -> Vec<Rule> {
    rules::registry()
}

/// Runs every rule (or the subset whose name contains `filter`) over `tree`, in parallel.
///
/// Returns the violations, each prefixed with its rule's name, in registry order.
#[must_use]
pub fn run(tree: &Tree, filter: Option<&str>) -> Vec<String> {
    use rayon::prelude::*;

    let rules = all_rules();
    let selected: Vec<&Rule> = rules
        .iter()
        .filter(|rule| filter.is_none_or(|needle| rule.name.contains(needle)))
        .collect();
    selected
        .par_iter()
        .map(|rule| {
            let report = (rule.check)(tree);
            report
                .violations()
                .iter()
                .map(|violation| format!("{}: {violation}", rule.name))
                .collect::<Vec<_>>()
        })
        .flatten()
        .collect()
}

#[cfg(test)]
pub(crate) mod tests {
    //! A scratch tree, so every rule's break-test can seed exactly the drift it was written for.
    //!
    //! Shared rather than per-module because the fixtures overlap: a rule about superd's protocol
    //! and a rule about superd's bodies want the same two files present, and a second copy of this
    //! helper is a second set of paths to keep in step with the real tree.

    use std::fs;
    use std::path::PathBuf;

    use crate::tree::Tree;

    /// A temp directory that removes itself, written into as if it were the repository.
    pub struct Fixture(PathBuf);

    impl Fixture {
        /// A fresh, empty tree. `name` must be unique per test — they run concurrently.
        #[must_use]
        pub fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("slopdesk-invariants-{name}"));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).expect("fixture root");
            Self(root)
        }

        /// Writes one file, creating its parents. Returns `self` so writes chain.
        pub fn write(&self, path: &str, contents: &str) -> &Self {
            let full = self.0.join(path);
            fs::create_dir_all(full.parent().expect("fixture parent")).expect("fixture dirs");
            fs::write(full, contents).expect("fixture file");
            self
        }

        /// Adds a line to a file already written, leaving what satisfied the rule in place.
        ///
        /// A break-test for a BAN needs the offending line to arrive in a file that still passes
        /// everything else — a `write` would take the doors out with it, and the rule would then
        /// fail for the reason the test was not asking about.
        pub fn append(&self, path: &str, contents: &str) -> &Self {
            let full = self.0.join(path);
            let mut held = fs::read_to_string(&full).unwrap_or_default();
            held.push_str(contents);
            self.write(path, &held)
        }

        /// Takes a file back out, so a break-test for an ABSENT claim can seed the file and then
        /// restore the tree that satisfied the rule.
        pub fn remove(&self, path: &str) -> &Self {
            let _ = fs::remove_file(self.0.join(path));
            self
        }

        /// Links one path at another, so a break-test for [`crate::claim::Claim::Symlink`] can seed
        /// the fact that claim asserts rather than a file that merely has the right bytes.
        ///
        /// `target` is spelled the way `ln -s` takes it — RELATIVE TO THE LINK, not to the root —
        /// because that is what the repository holds and a break-test that seeded an absolute one
        /// would be green on a link no clone could resolve. Any existing entry is taken out first:
        /// the drift these tests seed is a link REPLACED by a copy, so the two directions have to
        /// be writable over each other.
        pub fn link(&self, path: &str, target: &str) -> &Self {
            let full = self.0.join(path);
            fs::create_dir_all(full.parent().expect("fixture parent")).expect("fixture dirs");
            let _ = fs::remove_file(&full);
            std::os::unix::fs::symlink(target, &full).expect("fixture link");
            self
        }

        /// Indexes what has been written so far.
        #[must_use]
        pub fn tree(&self) -> Tree {
            Tree::load(&self.0).expect("fixture tree")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}
