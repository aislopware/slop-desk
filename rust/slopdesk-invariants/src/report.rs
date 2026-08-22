//! What a rule says when it is unhappy, and the two primitives that decide when it is.
//!
//! The shell had `fail` and `same`. `fail` printed and bumped a counter; `same` compared two
//! strings and — crucially — treated EITHER side reading empty as a failure rather than as
//! agreement, because both sides were `sed` extractions and `sed` exits 0 on no match. That rule is
//! the single most load-bearing line in the whole gate: without it, a constant renamed on both
//! sides in one commit produces `"" == ""` and the healthiest-looking pass this gate can print.
//!
//! Both survive here with their semantics intact. What changes is that a [`Report`] is a VALUE a
//! rule returns rather than a global counter it mutates, which is what lets rules run in parallel
//! and lets a break-test be a unit test.

use std::fmt::Write as _;

use crate::tree::{Source, Tree};

/// One rule's verdict: the violations it found, in the order it found them.
#[derive(Debug, Default)]
pub struct Report {
    violations: Vec<String>,
}

impl Report {
    /// A fresh, passing report.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            violations: Vec::new(),
        }
    }

    /// Records a violation — the shell's `fail`.
    pub fn fail(&mut self, message: impl Into<String>) {
        self.violations.push(message.into());
    }

    /// Records a violation only when `condition` holds.
    pub fn fail_if(&mut self, condition: bool, message: impl Into<String>) {
        if condition {
            self.fail(message);
        }
    }

    /// Compares one value that is spelled in both languages — the shell's `same`.
    ///
    /// Either side reading as `None` (a stale extraction) fails LOUDLY rather than comparing two
    /// absences and calling them equal. See the module note.
    pub fn same(&mut self, label: &str, swift: Option<&str>, rust: Option<&str>) {
        match (swift, rust) {
            (None, _) | (_, None) => {
                self.fail(format!(
                    "{label}: one side read as EMPTY — the extraction in this gate has gone stale and \
                     stopped comparing anything",
                ));
            },
            (Some(swift), Some(rust)) if swift != rust => {
                self.fail(format!(
                    "{label} disagrees — Swift has '{swift}', Rust has '{rust}'",
                ));
            },
            _ => {},
        }
    }

    /// Compares two SETS spelled in both languages, naming what each side has that the other does
    /// not — which is the diagnostic the shell could only approximate by printing both lists.
    ///
    /// An empty set on either side is the same staleness [`Report::same`] refuses.
    pub fn same_set(
        &mut self,
        label: &str,
        swift: &std::collections::BTreeSet<String>,
        rust: &std::collections::BTreeSet<String>,
    ) {
        if swift.is_empty() || rust.is_empty() {
            self.fail(format!(
                "{label}: one side read as EMPTY — the extraction in this gate has gone stale and stopped \
                 comparing anything",
            ));
            return;
        }
        if swift == rust {
            return;
        }
        let mut message = format!("{label} disagrees —");
        let only_swift: Vec<_> = swift.difference(rust).cloned().collect();
        let only_rust: Vec<_> = rust.difference(swift).cloned().collect();
        if !only_swift.is_empty() {
            let _ = write!(message, " Swift alone has {}", only_swift.join(" "));
        }
        if !only_rust.is_empty() {
            let _ = write!(message, " Rust alone has {}", only_rust.join(" "));
        }
        self.fail(message);
    }

    /// Reads a file the rule assumes exists, failing when it does not.
    ///
    /// This is the shape that stops the crate's worst failure: a "must not contain" ban over a file
    /// that has been renamed passes vacuously, forever. Asking through this makes the absence the
    /// violation.
    #[must_use]
    pub fn source<'a>(&mut self, tree: &'a Tree, path: &str, why: &str) -> Option<&'a Source> {
        let found = tree.get(path);
        if found.is_none() {
            self.fail(format!("{path} is gone — {why}"));
        }
        found
    }

    /// Every violation recorded, in order.
    #[must_use]
    pub fn violations(&self) -> &[String] {
        &self.violations
    }

    /// Whether the rule passed.
    #[must_use]
    pub const fn is_clean(&self) -> bool {
        self.violations.is_empty()
    }

    /// Folds another report's violations in — how a rule built from sub-checks reports as one.
    pub fn absorb(&mut self, other: Self) {
        self.violations.extend(other.violations);
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::Report;

    /// The load-bearing one. Two stale extractions must not read as agreement.
    #[test]
    fn an_empty_side_fails_rather_than_agreeing_with_the_other_empty_side() {
        let mut report = Report::new();
        report.same("protocol major", None, None);
        assert_eq!(report.violations().len(), 1);
        assert!(report.violations()[0].contains("EMPTY"));
    }

    #[test]
    fn a_present_side_against_an_absent_one_still_fails() {
        let mut report = Report::new();
        report.same("protocol minor", Some("7"), None);
        assert!(!report.is_clean());
    }

    #[test]
    fn equal_values_say_nothing() {
        let mut report = Report::new();
        report.same("notification id", Some("0"), Some("0"));
        assert!(report.is_clean());
    }

    #[test]
    fn a_set_difference_names_which_side_has_the_extra() {
        let swift: BTreeSet<String> = ["agent", "hook"].iter().map(|s| (*s).to_owned()).collect();
        let rust: BTreeSet<String> = std::iter::once("agent".to_owned()).collect();
        let mut report = Report::new();
        report.same_set("listener kinds", &swift, &rust);
        assert_eq!(report.violations().len(), 1);
        assert!(report.violations()[0].contains("Swift alone has hook"));
    }
}
