//! Two scripts that must mean one thing by a marker, and three bytes no door could pin.
//!
//! Ported from `scripts/check-supervisor.sh`. Both rules compare two spellings of one fact, and both
//! exist because the alternative was tried and could not work: the marker cannot be a shared
//! constant while two scripts write it independently, and the liveness bytes cannot come from a door
//! at all. Every arm reads the two sides as TEXT and refuses two empties, because an extraction that
//! stopped matching would otherwise print the healthiest result this gate can print.

use crate::claim::{Claim, Extract, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The pre-push writer of the green-tree marker.
const PRE_PUSH: &str = "scripts/pre-push-test.sh";
/// The fast-loop writer of the same marker.
const TOUCHED: &str = "scripts/test-touched.sh";
/// The frozen bytes' Rust half.
const WIRE_FIELDS: &str = "rust/slopdesk-wire/src/document/fields.rs";
/// Their Swift half.
const MODEL_FIELDS: &str = "Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift";

/// The two writers of the green-tree marker must mean the same thing by it
///
/// `pre-push-test.sh` and `test-touched.sh` both WRITE `.build/pre-push-green-tree`, and each decides
/// whether it may from a `git status --porcelain --` pathspec naming the inputs `swift test`
/// consumes. That is one list spelled twice: a path added to one only is a marker the other records
/// over a tree it would itself have called dirty, and the marker is read back as a promise about
/// content. It stays a promise about the SAME content only while the two agree.
///
/// `scripts/` was missing from both for as long as both existed, while the fast loop's SELECTION
/// already attributed a scripts edit to the suite that owns those tests — they open `scripts/*.sh`
/// off disk at run time. The list knew about the input in one place and not the other two.
///
/// The marker NAMES are compared as SETS rather than as a spelled-out pair. The first draft asked
/// `grep -qF pre-push-green-ffi` of each script, which a rename to `pre-push-green-ffi-stamp` passes
/// by substring — a check that survives the edit it exists to catch. Both files must name the same
/// markers, whatever they are called this week.
///
/// The two `Extract` sides are labelled `swift` and `rust` because that is what the claim's fields
/// are called; here they are simply the two shells, and the comparison is the same one.
#[must_use]
pub fn the_green_tree_marker_means_one_thing(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            Claim::SameValue {
                label: "tested-inputs pathspec",
                swift: Extract::raw(PRE_PUSH, r"git status --porcelain -- (.*?) 2> */dev/null"),
                rust: Extract::raw(TOUCHED, r"git status --porcelain -- (.*?) 2> */dev/null"),
            },
            Claim::SameSet {
                label: "green-tree markers",
                swift: Extract::raw(PRE_PUSH, r"(\.build/pre-push-[a-z0-9-]+)"),
                rust: Extract::raw(TOUCHED, r"(\.build/pre-push-[a-z0-9-]+)"),
            },
        ],
    )
}

/// The liveness bytes, which no door can pin
///
/// `pane/liveness` carries a frozen byte per state, and BOTH languages spell the three arms:
/// `slopdesk-wire`'s `PaneLivenessState` and `SlopDeskWorkspaceModel`'s enum of the same name.
///
/// A door was tried for exactly this and could not work, which is why the check is here instead. It
/// exported "the byte for arm N" so the Swift side would never transcribe a frozen number — but a
/// Swift enum's raw values must be COMPILE-TIME constants, so no call can supply them. The door was
/// uncallable by construction, sat dead behind `check-ffi-doors.py`, and the transcription it was
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
        ("attached", r"^\s+Attached = ([0-9]+),", r"^\s+case attached = ([0-9]+)"),
        ("detached", r"^\s+Detached = ([0-9]+),", r"^\s+case detached = ([0-9]+)"),
        ("dead", r"^\s+Dead = ([0-9]+),", r"^\s+case dead = ([0-9]+)"),
    ];

    let claims: Vec<Claim> = ARMS
        .iter()
        .map(|(label, rust, swift)| Claim::SameValue {
            label,
            swift: Extract::raw(MODEL_FIELDS, swift)
                .within(r"^public enum PaneLivenessState", r"^\}"),
            rust: Extract::raw(WIRE_FIELDS, rust)
                .within(r"^pub enum PaneLivenessState \{", r"^\}"),
        })
        .collect();
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// Both writers agreeing on the pathspec and on the two marker names.
    fn writers(fixture: &Fixture, pathspec: &str, markers: &str) {
        for script in [super::PRE_PUSH, super::TOUCHED] {
            fixture.write(
                script,
                &format!(
                    "if [[ -z \"$(git status --porcelain -- {pathspec} 2> /dev/null)\" ]]; then\n\
                     {markers}\nfi\n"
                ),
            );
        }
    }

    #[test]
    fn two_writers_that_disagree_are_red() {
        let fixture = Fixture::new("marker-writers");
        writers(
            &fixture,
            "Package.swift Sources Tests Apps golden scripts",
            "  : > .build/pre-push-green-tree\n  : > .build/pre-push-green-ffi",
        );
        assert!(super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());

        // A path added to one only records a green over a tree the other would have called dirty.
        fixture.write(
            super::TOUCHED,
            "if [[ -z \"$(git status --porcelain -- Package.swift Sources Tests Apps golden 2> /dev/null)\" ]]; then\n\
             \x20 : > .build/pre-push-green-tree\n  : > .build/pre-push-green-ffi\nfi\n",
        );
        assert!(!super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());

        // And a rename that a substring check would have passed.
        writers(
            &fixture,
            "Package.swift Sources Tests Apps golden scripts",
            "  : > .build/pre-push-green-tree\n  : > .build/pre-push-green-ffi",
        );
        fixture.write(
            super::TOUCHED,
            "if [[ -z \"$(git status --porcelain -- Package.swift Sources Tests Apps golden scripts 2> /dev/null)\" ]]; then\n\
             \x20 : > .build/pre-push-green-tree\n  : > .build/pre-push-green-ffi-stamp\nfi\n",
        );
        assert!(!super::the_green_tree_marker_means_one_thing(&fixture.tree()).is_clean());
    }

    /// Three arms, spelled once in each language.
    fn liveness(fixture: &Fixture, dead: u8) {
        fixture
            .write(
                super::WIRE_FIELDS,
                "pub enum PaneLivenessState {\n    Attached = 0,\n    Detached = 1,\n\
                 \x20   Dead = 2,\n}\n",
            )
            .write(
                super::MODEL_FIELDS,
                &format!(
                    "public enum PaneLivenessState: UInt8 {{\n    case attached = 0\n\
                     \x20   case detached = 1\n    case dead = {dead}\n}}\n"
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
