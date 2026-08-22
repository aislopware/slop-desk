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
