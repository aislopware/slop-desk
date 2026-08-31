//! Two gates that must mean one thing by a marker, and three bytes no door could pin.
//!
//! Ported from the deleted `check-supervisor.sh`. Both rules exist because the alternative was
//! tried and could not work: the marker could not be a shared constant while two SHELL scripts
//! wrote it independently, and the liveness bytes cannot come from a door at all. The liveness arms
//! read both sides as TEXT and refuse two empties, because an extraction that stopped matching
//! would otherwise print the healthiest result this gate can print — and the marker rule, whose two
//! spellings became one Rust constant, now pins the thing that keeps them one.

use crate::claim::{Claim, Extract, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// Where the green-tree marker, its FFI half and the tested-inputs list are DECLARED.
const PRE_PUSH: &str = "rust/slopdesk-devtools/src/gates/prepush.rs";
/// The fast loop, which must reach all three through the module above rather than re-spell them.
const TOUCHED: &str = "rust/slopdesk-devtools/src/gates/touched.rs";
/// The frozen bytes' Rust half.
const WIRE_FIELDS: &str = "rust/slopdesk-wire/src/document/fields.rs";
/// Their Swift half.
const MODEL_FIELDS: &str = "Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift";

/// The green-tree marker has ONE writer and ONE definition of clean
///
/// Two gates record `.build/pre-push-green-tree`: the pre-push run and a FULL fast-loop run. Each
/// may only record it over a tree that carries no change to the inputs `swift test` consumes, and
/// the marker is read back as a promise about content — so it stays a promise about the SAME
/// content only while the two agree about what "clean" means.
///
/// As two shell scripts that was one list spelled twice, and this rule compared the two spellings:
/// `scripts/` was missing from both for as long as both existed, while the fast loop's SELECTION
/// already attributed a scripts edit to the suites that open `scripts/*.sh` off disk at run time.
/// The list knew about the input in one place and not the other two.
///
/// Ported to Rust the duplication was said to be gone — `prepush` declaring the list and both
/// markers, `touched` reaching all three through it — so the old comparison would compare a
/// constant with itself and pass forever. Two of the three were true. `touched` reached both
/// MARKERS and spelled its own `PATHSPEC`, and this rule could not see it: the list was checked for
/// existing, never for being the one in use. The two copies disagreed in both directions the whole
/// time — `Package.resolved` in the fast loop and not in the declaration, `Apps` the other way
/// round.
///
/// So what this pins is the property that MAKES the tautology: the fast loop may not grow its own
/// `git status` pathspec, its own marker path, or its own list of paths. The day it does, the two
/// spellings are back and this fails, which is the same failure the shell version caught.
#[must_use]
pub fn the_green_tree_marker_means_one_thing(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(declaring) = report.source(tree, PRE_PUSH, "the marker would have no declaration") else {
        return report;
    };
    for (constant, what) in [
        ("TESTED_INPUTS", "the tested-inputs list"),
        ("TREE_MARKER", "the green-tree marker"),
        ("FFI_MARKER", "its FFI half"),
    ] {
        report.fail_if(
            !declaring.text.contains(&format!("pub const {constant}")),
            format!("{PRE_PUSH}: {what} is no longer declared as `{constant}` — this rule is blind"),
        );
    }

    let Some(fast) = report.source(tree, TOUCHED, "there would be no second writer to check") else {
        return report;
    };
    report.fail_if(
        fast.text.contains("status") && fast.text.contains("--porcelain"),
        format!(
            "{TOUCHED}: the fast loop spells its own `git status --porcelain` — clean must come from \
             {PRE_PUSH}, or the two gates disagree about what the marker promises"
        ),
    );
    report.fail_if(
        fast.text.contains(".build/pre-push-"),
        format!(
            "{TOUCHED}: the fast loop names a marker path directly — it must reach both through {PRE_PUSH}, \
             whatever they are called this week"
        ),
    );
    // The third thing this rule's own note claimed was already single, and was not. Both markers
    // were pinned from the day of the port; the LIST was pinned only for its existence, so the fast
    // loop went on carrying a `PATHSPEC` of its own — and the two disagreed in both directions,
    // `Package.resolved` in one and `Apps` in the other, for as long as they coexisted. A rule that
    // checks two of the three things it names is the shape it was written to catch.
    report.fail_if(
        !fast.text.contains("TESTED_INPUTS"),
        format!(
            "{TOUCHED}: the fast loop no longer reaches {PRE_PUSH}'s tested-inputs list — a second spelling \
             of what the suite consumes is two answers to one question"
        ),
    );
    report.fail_if(
        fast.text.contains(": &[&str] = &["),
        format!(
            "{TOUCHED}: the fast loop declares a path list of its own — the scope of the diff is \
             {PRE_PUSH}'s `TESTED_INPUTS`, widened only by trees the package graph cannot own"
        ),
    );
    report
}

/// The liveness bytes, which no door can pin
///
/// `pane/liveness` carries a frozen byte per state, and BOTH languages spell the three arms:
/// `slopdesk-wire`'s `PaneLivenessState` and `SlopDeskWorkspaceModel`'s enum of the same name.
///
/// A door was tried for exactly this and could not work, which is why the check is here instead. It
/// exported "the byte for arm N" so the Swift side would never transcribe a frozen number — but a
/// Swift enum's raw values must be COMPILE-TIME constants, so no call can supply them. The door was
/// uncallable by construction, sat dead behind `ffi-doors-are-opened`, and the transcription it was
/// written to prevent happened anyway one file over. A ratchet can do what the door could not:
/// compare the two arm lists before either is compiled.
///
/// One claim per arm rather than one over the joined list, which is the one deliberate change from
/// the shell. The shell folded case and pasted the three arms into a single string so that it could
/// compare Rust's `Attached = 0` against Swift's `case attached = 0` at all; per arm, each side's
/// own spelling captures the same thing — the BYTE — and a disagreement names which state moved
/// instead of printing two lists for the reader to diff.
#[must_use]
pub fn the_liveness_bytes_agree(tree: &Tree) -> Report {
    /// Each arm, as Rust spells it and as Swift does.
    const ARMS: &[(&str, &str, &str)] = &[
        (
            "attached",
            r"^\s+Attached = ([0-9]+),",
            r"^\s+case attached = ([0-9]+)",
        ),
        (
            "detached",
            r"^\s+Detached = ([0-9]+),",
            r"^\s+case detached = ([0-9]+)",
        ),
        ("dead", r"^\s+Dead = ([0-9]+),", r"^\s+case dead = ([0-9]+)"),
    ];

    let claims: Vec<Claim> = ARMS
        .iter()
        .map(|(label, rust, swift)| {
            Claim::SameValue {
                label,
                swift: Extract::statements(MODEL_FIELDS, swift)
                    .within(r"^public enum PaneLivenessState", r"^\}"),
                rust: Extract::statements(WIRE_FIELDS, rust)
                    .within(r"^pub enum PaneLivenessState \{", r"^\}"),
            }
        })
        .collect();
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// One declaring module, and a fast loop that reaches everything through it.
    fn writers(fixture: &Fixture) {
        fixture.write(
            super::PRE_PUSH,
            "pub const TREE_MARKER: &str = \".build/pre-push-green-tree\";\npub const FFI_MARKER: &str = \
             \".build/pre-push-green-ffi\";\npub const TESTED_INPUTS: &[&str] = &[\"Package.swift\", \
             \"Sources\", \"scripts\"];\n",
        );
        fixture.write(
            super::TOUCHED,
            "use super::prepush;\nfn go() { let scope = prepush::TESTED_INPUTS; \
             prepush::record_green(root); }\n",
        );
    }

    #[test]
    fn a_second_spelling_of_clean_is_red() {
        let fixture = Fixture::new("marker-writers");
        writers(&fixture);
        assert!(super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());

        // The fast loop deciding for itself what a clean tree is — the shell's original bug, back.
        fixture.write(
            super::TOUCHED,
            "fn go() { proc::ask(\"git\", &[\"status\", \"--porcelain\", \"--\", \"Sources\"], root); }\n",
        );
        assert!(!super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());

        // And a marker path written out a second time, whatever it is called this week.
        writers(&fixture);
        fixture.write(
            super::TOUCHED,
            "fn go() { fs::write(root.join(\".build/pre-push-green-ffi-stamp\"), stamp); }\n",
        );
        assert!(!super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());
    }

    /// The list, which this rule watched only for EXISTENCE while the fast loop carried a second
    /// copy that disagreed with it in both directions.
    #[test]
    fn a_second_spelling_of_the_tested_inputs_is_red() {
        let fixture = Fixture::new("marker-pathspec");
        writers(&fixture);
        assert!(super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());

        // The shape that shipped: its own list, near enough to look right and not the same.
        fixture.write(
            super::TOUCHED,
            "use super::prepush;\nconst PATHSPEC: &[&str] = &[\"Package.swift\", \"Sources\"];\nfn go() { \
             let scope = prepush::TESTED_INPUTS; }\n",
        );
        assert!(!super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());

        // And the reach removed outright, which is the same divergence one step earlier.
        fixture.write(super::TOUCHED, "fn go() { let scope = [\"Sources\"]; }\n");
        assert!(!super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());
    }

    /// A rule that cannot see its own subject must say so, not pass.
    #[test]
    fn a_renamed_declaration_blinds_the_rule_loudly() {
        let fixture = Fixture::new("marker-blind");
        writers(&fixture);
        fixture.write(
            super::PRE_PUSH,
            "pub const TREE_MARKER: &str = \".build/pre-push-green-tree\";\npub const FFI_MARKER: &str = \
             \".build/pre-push-green-ffi\";\nconst INPUTS: &[&str] = &[\"Sources\"];\n",
        );
        assert!(!super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());
    }

    /// Three arms, spelled once in each language.
    fn liveness(fixture: &Fixture, dead: u8) {
        fixture
            .write(
                super::WIRE_FIELDS,
                "pub enum PaneLivenessState {\n    Attached = 0,\n    Detached = 1,\n\x20   Dead = 2,\n}\n",
            )
            .write(
                super::MODEL_FIELDS,
                &format!(
                    "public enum PaneLivenessState: UInt8 {{\n    case attached = 0\n\x20   case detached = \
                     1\n    case dead = {dead}\n}}\n"
                ),
            );
    }

    #[test]
    fn a_transcribed_liveness_byte_is_red() {
        let fixture = Fixture::new("liveness-bytes");
        liveness(&fixture, 2);
        assert!(super::the_liveness_bytes_agree(&fixture.tree()).is_clean());

        // The transcription the uncallable door was written to prevent, happening one file over.
        liveness(&fixture, 3);
        assert!(!super::the_liveness_bytes_agree(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_liveness_half_that_stopped_reading_is_red() {
        // Two empties agree, which is why the claim refuses them; its own fixture, because writes
        // accumulate.
        let fixture = Fixture::new("liveness-stale");
        fixture
            .write(super::WIRE_FIELDS, "pub enum Liveness {\n    Attached = 0,\n}\n")
            .write(
                super::MODEL_FIELDS,
                "public enum Liveness: UInt8 {\n    case attached = 0\n}\n",
            );
        assert!(!super::the_liveness_bytes_agree(&fixture.tree()).is_clean());
    }
}
