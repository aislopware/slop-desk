//! Two gates about the gates: a door nothing opens, and a filter that stopped filtering.
//!
//! Ported from the `check-ffi-doors.py` and `check-ban-union.py` that used to sit in `scripts/`.
//! Neither was ever about the product — each watches a mechanism this repo relies on to watch
//! something else, and both failures are silent in the same way: the log says the check ran.

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
/// A linked port has a failure mode a socket port does not, and `build-ffi.sh --check` catches one
/// of them: an artifact older than its sources. This catches the other, which is quieter — a door
/// that NOTHING calls. It costs nothing at runtime and everything at read time: the next person to
/// touch `slopdesk_replay_result_count` has to work out whether it is the way to ask, a second way
/// to ask, or a way nobody asks. The audit that found the first four had to answer that question by
/// hand four times.
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

/// The shell gate that still holds the one-walk ban filter.
const GATE: &str = "scripts/check-supervisor.sh";

/// `DELETED_SWIFT_UNION` really is the union of every ban that filters through it.
///
/// `check-supervisor.sh` walks `Sources/` ONCE for its "this Swift must stay deleted" bans: a union
/// grep collects the candidate files, and each ban then re-greps only those. That is only sound
/// while the union is a SUPERSET of every ban. Drop one ban's pattern out of it and that ban stops
/// seeing its own violation — and it reports success, because an empty candidate list is exactly
/// what passing looks like.
///
/// That is the failure mode the shell has a whole section about ("No gate may die quietly"): a
/// check that cannot fail is worse than one that is missing, because the log says it ran.
///
/// The check is textual on purpose. Deciding regex-superset in general is not something to attempt
/// in a lint gate; every ban is spliced into the union verbatim as `(pattern)`, so verbatim
/// containment is both the rule and the whole story. A ban written some other way fails this and
/// should — it means the splice convention was broken, which is when the reasoning above stops
/// holding.
///
/// This rule dies with the last ban: when no `among_deleted` call is left, the union goes with it
/// and so does this. Until then it is the thing that keeps the shell's remaining bans honest, which
/// is why it moved into the crate rather than being deleted alongside its two Python neighbours.
#[must_use]
pub fn the_ban_union_contains_every_ban(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(gate) = report.source(tree, GATE, "the one-walk ban filter lives there") else {
        return report;
    };
    let Some(union) = text::capture_first(&gate.text, r"^DELETED_SWIFT_UNION='(.*)'$") else {
        report.fail(
            "no DELETED_SWIFT_UNION in the gate. If the one-walk filter was removed, remove this rule with \
             it; if it was renamed, rename it here.",
        );
        return report;
    };

    let bans = text::capture_all(&gate.text, r"^\s*[a-z_]+=\$\(among_deleted '(.*)'\)$");
    if bans.is_empty() {
        report.fail(
            "the union exists but nothing filters through it, so the walk is dead weight and the bans are \
             somewhere else.",
        );
        return report;
    }

    let missing: Vec<&str> = bans
        .iter()
        .filter(|ban| !union.contains(&format!("({ban})")))
        .map(String::as_str)
        .collect();
    if !missing.is_empty() {
        report.fail(format!(
            "these bans filter through a union that does not contain them, so each one PASSES on a file it \
             should catch: {} — splice each into DELETED_SWIFT_UNION as `(pattern)`, joined by `|`.",
            missing.join(", ")
        ));
    }
    report
}

#[cfg(test)]
mod tests {
    use super::{every_ffi_door_is_opened_or_declared_deliberate, the_ban_union_contains_every_ban};
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

    #[test]
    fn a_ban_missing_from_the_union_is_red() {
        let fixture = Fixture::new("ban-union");
        fixture.write(
            "scripts/check-supervisor.sh",
            "DELETED_SWIFT_UNION='(Alpha)|(Beta)'\n  a=$(among_deleted 'Alpha')\n  b=$(among_deleted \
             'Gamma')\n",
        );
        assert!(!the_ban_union_contains_every_ban(&fixture.tree()).is_clean());

        let whole = Fixture::new("ban-union-whole");
        whole.write(
            "scripts/check-supervisor.sh",
            "DELETED_SWIFT_UNION='(Alpha)|(Beta)'\n  a=$(among_deleted 'Alpha')\n  b=$(among_deleted \
             'Beta')\n",
        );
        assert!(the_ban_union_contains_every_ban(&whole.tree()).is_clean());
    }

    /// A union with no bans left means the walk is dead weight — and the rule says so rather than
    /// passing on an empty list.
    #[test]
    fn a_union_nothing_filters_through_is_red() {
        let fixture = Fixture::new("ban-union-empty");
        fixture.write("scripts/check-supervisor.sh", "DELETED_SWIFT_UNION='(Alpha)'\n");
        assert!(!the_ban_union_contains_every_ban(&fixture.tree()).is_clean());
    }
}
