//! One gate about the gates: a door nothing opens.
//!
//! Ported from the `check-ffi-doors.py` that used to sit in `scripts/`. It was never about the
//! product — it watches a mechanism this repo relies on to watch something else, and its failure is
//! silent in the familiar way: the log says the check ran.
//!
//! Its neighbour `the_ban_union_contains_every_ban` is GONE, as its own doc said it would be. It
//! kept `check-supervisor.sh`'s one-walk `DELETED_SWIFT_UNION` honest — a filter that stopped being
//! a superset made every ban behind it pass on a file it should catch. The shell is deleted and the
//! bans are `Claim::NoneUnder`s in `rules::deleted_host_swift` and `rules::screend_wire`, which
//! scan a root directly, so there is no filter left to be wrong about.

use std::collections::BTreeSet;

use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// The header every door is declared in — the artifact Swift links against.
const HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
/// The Swift that may call one. Tests count: a door called only from a test is still a door
/// somebody reaches, which is where this differs from the constant pass.
const SWIFT_ROOTS: [&str; 3] = ["Sources", "Tests", "Apps"];

/// A door with no Swift caller, and the reason it stays.
///
/// The rule is not "delete every uncalled door". It is "an uncalled door is a DECISION, written
/// down" — deleting one of these is a design change, not a cleanup, so a bare name added here is
/// the failure this rule exists to prevent.
const DELIBERATE: [(&str, &str); 2] = [
    (
        "slopdesk_swipe_nav_config_free",
        "the destructor for a handle whose only shipped owner is a process-lifetime `static let`. A \
         constructor whose ABI offers no destructor is what makes the NEXT owner — one that is per-window \
         rather than per-process — leak for real.",
    ),
    (
        "slopdesk_zoom_reset_policy_free",
        "same as slopdesk_swipe_nav_config_free: PinchZeroPolicy parses once into a `static let` and never \
         frees it, which is a singleton and not a leak.",
    ),
];

/// What to do with a door nothing calls, which differs by which of three things it is.
const GUIDANCE: &str = "Each is one of three things, and the fix differs: a SECOND way to ask something a \
                        live door already answers — delete it, and say in its place what the one way is; a \
                        hook held open for a test in the other language — delete it and assert natively, \
                        which is the cross-language mirror fixture the one-implementation rule bans; or a \
                        deliberate face — add it to DELIBERATE WITH the reason, which is the review.";

/// Every door in the FFI header is called from Swift, or is named a deliberate face.
///
/// A linked port has a failure mode a socket port does not, and `slopdesk-gate ffi --check` catches
/// one of them: an artifact older than its sources. This catches the other, which is quieter — a
/// door that NOTHING calls. It costs nothing at runtime and everything at read time: the next
/// person to touch `slopdesk_replay_result_count` has to work out whether it is the way to ask, a
/// second way to ask, or a way nobody asks. The audit that found the first four had to answer that
/// question by hand four times.
#[must_use]
pub fn every_ffi_door_is_opened_or_declared_deliberate(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(header) = report.source(tree, HEADER, "there would be no doors to read") else {
        return report;
    };
    let doors = text::capture_set(&header.text, r"\b(slopdesk_[a-z0-9_]+)\s*\(");
    if doors.is_empty() {
        report.fail(format!(
            "{HEADER}: no doors parsed out of the header — this rule is blind"
        ));
        return report;
    }

    let mut called: BTreeSet<String> = BTreeSet::new();
    for root in SWIFT_ROOTS {
        for (path, source) in tree.under(root) {
            if path.extension().is_some_and(|extension| extension == "swift") {
                called.extend(text::capture_set(&source.text, r"\b(slopdesk_[a-z0-9_]+)\b"));
            }
        }
    }

    let uncalled: Vec<&String> = doors.difference(&called).collect();
    let unexplained: Vec<&str> = uncalled
        .iter()
        .map(|door| door.as_str())
        .filter(|door| !DELIBERATE.iter().any(|(named, _)| named == door))
        .collect();
    if !unexplained.is_empty() {
        report.fail(format!(
            "these doors are exported and NOTHING in Swift calls them: {} — {GUIDANCE}",
            unexplained.join(", ")
        ));
        return report;
    }

    // An allowlist entry for a door that IS called, or that no longer exists, is stale — the same
    // unfulfilled-expectation rule clippy's `#[expect]` carries.
    let stale: Vec<&str> = DELIBERATE
        .iter()
        .map(|(door, _)| *door)
        .filter(|door| !doors.contains(*door) || called.contains(*door))
        .collect();
    if !stale.is_empty() {
        report.fail(format!(
            "DELIBERATE names a door that is now called, or is gone: {} — drop it from the allowlist, an \
             unfulfilled exemption is itself the bug",
            stale.join(", ")
        ));
    }
    report
}

#[cfg(test)]
mod tests {
    use super::every_ffi_door_is_opened_or_declared_deliberate;
    use crate::tests::Fixture;

    /// A header with a door and a Swift tree that never names it.
    #[test]
    fn a_door_nobody_opens_is_red() {
        let fixture = Fixture::new("ffi-doors");
        fixture.write(
            "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            "void slopdesk_ws_min_weight(void);\nvoid slopdesk_ghost_door(void);\n",
        );
        fixture.write("Sources/A/Call.swift", "let w = slopdesk_ws_min_weight()\n");
        assert!(!every_ffi_door_is_opened_or_declared_deliberate(&fixture.tree()).is_clean());

        // The green half declares the two deliberate faces as well, because an allowlist entry
        // for a door that is not in the header is itself a finding — see the next test.
        let opened = Fixture::new("ffi-doors-opened");
        opened.write(
            "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            "void slopdesk_ws_min_weight(void);\nvoid slopdesk_swipe_nav_config_free(void);\nvoid \
             slopdesk_zoom_reset_policy_free(void);\n",
        );
        opened.write("Sources/A/Call.swift", "let w = slopdesk_ws_min_weight()\n");
        assert!(every_ffi_door_is_opened_or_declared_deliberate(&opened.tree()).is_clean());
    }

    /// An allowlisted door that came back to life is the same bug wearing the other hat.
    #[test]
    fn an_allowlisted_door_that_is_now_called_is_red() {
        let fixture = Fixture::new("ffi-doors-stale");
        fixture.write(
            "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            "void slopdesk_swipe_nav_config_free(void);\nvoid slopdesk_zoom_reset_policy_free(void);\n",
        );
        fixture.write("Sources/A/Call.swift", "slopdesk_swipe_nav_config_free()\n");
        assert!(!every_ffi_door_is_opened_or_declared_deliberate(&fixture.tree()).is_clean());
    }
}
