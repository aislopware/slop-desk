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

// `SWIFT_ROOTS` is the Swift that may call a door. Tests count: a door called only from a test is
// still a door somebody reaches, which is where this differs from the constant pass. This rule asked
// that question first and held its own copy of the list; it is `claim`'s now, because two copies of
// "every Swift root" is the drift this crate exists to catch.
use crate::claim::{GATE_RULES, SWIFT_ROOTS};
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// The header every door is declared in — the artifact Swift links against.
const HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
/// This crate's own sources — where an exemption spelled as a `const` is declared.
const CRATE_SRC: &str = "rust/slopdesk-invariants/src/";

/// A door with no Swift caller, and the reason it stays.
///
/// The rule is not "delete every uncalled door". It is "an uncalled door is a DECISION, written
/// down" — deleting one of these is a design change, not a cleanup, so a bare name added here is
/// the failure this rule exists to prevent.
const DELIBERATE: [(&str, &str); 1] = [(
    "slopdesk_zoom_reset_policy_free",
    "the destructor for a handle whose only shipped owner is a process-lifetime `static let` — \
     PinchZeroPolicy parses once and never frees it, which is a singleton and not a leak. A constructor \
     whose ABI offers no destructor is what makes the NEXT owner — one that is per-window rather than \
     per-process — leak for real.",
)];

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
/// person to touch `slopdesk_block_status` has to work out whether it is the way to ask, a second
/// way to ask, or a way nobody asks. The audit that found the first four had to answer that
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
    for &root in SWIFT_ROOTS {
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

/// Every `exempt:` in every rule names a path the tree still has.
///
/// The same unfulfilled-expectation rule as `DELIBERATE` above, generalised to the carve-out every
/// [`crate::claim::Claim::NoneUnder`] can carry. A ban's exemption is the one place in this crate
/// where being WRONG is silent in both directions: the exempted path is not asserted to exist, not
/// asserted to match, and a ban that carves out nothing is a ban that reports clean.
///
/// It has happened four times. The first three were found by hand rather than by anything running:
///
/// * `transport_lanes` exempted `Sources/SlopDeskTTY/` from two bans after the whole target crossed
///   to Rust in `a9fd1833` — so "one Swift write loop is allowed" named a directory with no files;
/// * `phone_parity` exempted `Panel/DevicePanelChrome.swift` after the `UIKit` crossing folded that
///   file into `PhoneDevicePanelParts.swift`;
/// * `device_law` and `chrome_split` carried four carve-outs over paths that still EXIST but had
///   long stopped typing the shape being banned.
///
/// The fourth is the one this rule found itself, the moment it learned to read a list spelled as a
/// `const`: `client_layers`'s `DOMAIN_VIEW_FRAMEWORK_SEAMS` named `TerminalRenderingView.swift`,
/// deleted weeks earlier, alongside two files that had stopped importing any view framework at all.
///
/// This rule closes the half where the path is simply GONE, because that is decidable from the tree
/// alone and needs no judgement. The other half — a path that exists but no longer types the banned
/// shape — is NOT mechanised, and that is a measured decision rather than an omission. Making
/// `Claim::NoneUnder` record which exempt entries it actually matched is exact and needs no text
/// parsing at all; it was written, and it reddened 21 tests. Two were findings worth having. The
/// other nineteen were break-test fixtures that had never seeded their own exempted path, which is
/// a tax on authoring every future ban rather than a defect in any of them. So whether an exemption
/// that carves out nothing TODAY is drift or a home standing empty between two commits stays a
/// reading, and this crate's answer to a reading is a comment at the site. What this catches is the
/// case where there is nothing left to read.
///
/// Only the source BEFORE `#[cfg(test)]` is scanned, because a break-test fixture writes rule text
/// as a string literal and [`crate::tree::Source::code`] leaves string literals intact — this rule
/// would otherwise report its own fixtures.
///
/// A `const` used as an exemption must resolve to a plain string literal somewhere in this crate.
/// An unresolvable one is reported rather than skipped: a name this rule cannot follow is a
/// carve-out nobody can check, which is the same failure one indirection further out.
///
/// ⚠️ BOTH SPELLINGS OF THE CARVE-OUT ARE READ, and reading only one is how this rule was blind on
/// the day it landed. A `Claim::NoneUnder` takes `exempt: &[&str]`, which is written two ways: an
/// inline `exempt: &["…"]`, and a bare `exempt: NAMED_LIST` over a `const NAME: &[&str] = &[…]`
/// declared beside the rule. The first version of this rule matched `exempt: &\[…\]` only, so the
/// FOUR longest lists in the crate — the ones an exemption is most likely to rot inside, because a
/// list nobody counts is a list nobody rereads — were invisible to it. It found nothing in them and
/// said so as a pass. `DOMAIN_VIEW_FRAMEWORK_SEAMS` was naming a file deleted weeks earlier the
/// whole time.
#[must_use]
pub fn every_exemption_names_a_path_the_tree_has(tree: &Tree) -> Report {
    let mut report = Report::new();

    // `const NAME: &str = "…";` and `const NAME: &[&str] = &[…];` anywhere in the crate. Names are
    // unique across it, so the last `::` segment of a qualified use resolves here without tracking
    // modules. The slice form is read line-wise rather than by one `(?s)` regex because these lists
    // carry paragraphs of prose between entries, and a lazy match to `];` is a bet on no `]` in it.
    let mut literals: BTreeSet<(String, String)> = BTreeSet::new();
    let mut lists: Vec<(String, Vec<String>)> = Vec::new();
    for (path, source) in tree.under(CRATE_SRC) {
        if path.extension().is_none_or(|extension| extension != "rs") {
            continue;
        }
        let code = source.code();
        for (name, value) in text::capture_pairs(code, r#"const ([A-Z][A-Z0-9_]*): &str = "([^"]*)";"#) {
            literals.insert((name, value));
        }
        let mut open: Option<(String, Vec<String>)> = None;
        for line in code.lines() {
            if let Some((name, entries)) = open.as_mut() {
                entries.extend(text::capture_all(line, r#""([^"]*)""#));
                if line.trim_start().starts_with("];") {
                    lists.push((name.clone(), std::mem::take(entries)));
                    open = None;
                }
                continue;
            }
            // A DECLARATION starts its line. `code()` leaves string literals intact, and one
            // break-test in this crate writes `"const SUBCOMMANDS: &[&str] = &[…]"` as
            // a fixture — reading that as a declaration would open a list here and
            // swallow every line after it.
            if !line.trim_start().starts_with("const ") && !line.trim_start().starts_with("pub const ") {
                continue;
            }
            let Some(name) = text::capture_all(line, r"const ([A-Z][A-Z0-9_]*): &\[&str\] = &\[")
                .into_iter()
                .next()
            else {
                continue;
            };
            let entries = text::capture_all(line, r#""([^"]*)""#);
            if line.trim_end().ends_with("];") {
                lists.push((name, entries));
            } else {
                open = Some((name, entries));
            }
        }
    }
    let resolve = |name: &str| -> Option<Vec<String>> {
        literals
            .iter()
            .find(|(known, _)| known == name)
            .map(|(_, value)| vec![value.clone()])
            .or_else(|| {
                lists
                    .iter()
                    .find(|(known, _)| known == name)
                    .map(|(_, values)| values.clone())
            })
    };

    let mut checked = 0_usize;
    for (path, source) in tree.under(GATE_RULES) {
        if path.extension().is_none_or(|extension| extension != "rs") {
            continue;
        }
        let shipped = text::before(source.code(), r"#\[cfg\(test\)\]");
        let inline = text::capture_all(&shipped, r"(?s)exempt: &\[(.*?)\]");
        let named = text::capture_all(&shipped, r"exempt: ([A-Za-z][A-Za-z0-9_:]*),");
        for list in inline.iter().chain(named.iter()) {
            for entry in list.split(',').map(str::trim).filter(|entry| !entry.is_empty()) {
                let carved = if entry.starts_with('"') {
                    vec![entry.trim_matches('"').to_owned()]
                } else if let Some(values) = resolve(entry.rsplit("::").next().unwrap_or(entry)) {
                    values
                } else {
                    report.fail(format!(
                        "{}: the exemption `{entry}` resolves to no string constant in this crate — a \
                         carve-out nobody can follow is one nobody can check",
                        path.display()
                    ));
                    continue;
                };
                for path_carved in carved {
                    checked += 1;
                    let held = if path_carved.ends_with('/') {
                        tree.under(&path_carved).next().is_some()
                    } else {
                        tree.has(&path_carved)
                    };
                    if !held {
                        report.fail(format!(
                            "{}: exempts `{path_carved}`, which the tree does not have — the ban carves out \
                             nothing and reads as a licence for a copy that has no home left",
                            path.display()
                        ));
                    }
                }
            }
        }
    }

    // The vacuity floor this rule owes for the same reason every ban here owes one: a renamed rules
    // directory, or an `exempt:` spelled some new way, would leave this reading nothing and saying
    // so was fine.
    if checked < 20 {
        report.fail(format!(
            "only {checked} exemptions parsed out of {GATE_RULES} — this rule is reading an empty set"
        ));
    }
    report
}

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;

    use super::{every_exemption_names_a_path_the_tree_has, every_ffi_door_is_opened_or_declared_deliberate};
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

        // The green half declares the deliberate face as well, because an allowlist entry for a
        // door that is not in the header is itself a finding — see the next test.
        let opened = Fixture::new("ffi-doors-opened");
        opened.write(
            "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            "void slopdesk_ws_min_weight(void);\nvoid slopdesk_zoom_reset_policy_free(void);\n",
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
            "void slopdesk_zoom_reset_policy_free(void);\n",
        );
        fixture.write("Sources/A/Call.swift", "slopdesk_zoom_reset_policy_free()\n");
        assert!(!every_ffi_door_is_opened_or_declared_deliberate(&fixture.tree()).is_clean());
    }

    /// A rules tree with enough live exemptions to clear the floor, plus the one under test.
    ///
    /// Twenty-four is the floor plus room: the floor exists so a renamed rules directory cannot
    /// make this rule read nothing and say so, and a fixture that could not clear it would be
    /// asserting against the floor rather than against the exemptions.
    fn exemptions(fixture: &Fixture, last: &str) -> String {
        let mut body = String::new();
        for index in 0..24 {
            let path = format!("Sources/A/Live{index}.swift");
            fixture.write(&path, "let x = 1\n");
            let _ = writeln!(body, "            exempt: &[\"{path}\"],");
        }
        body.push_str(last);
        body
    }

    #[test]
    fn an_exemption_over_a_deleted_path_is_red() {
        let fixture = Fixture::new("gate-exemptions");
        let live = exemptions(&fixture, "            exempt: &[],\n");
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &format!("pub fn a(tree: &Tree) -> Report {{\n{live}}}\n"),
        );
        assert!(every_exemption_names_a_path_the_tree_has(&fixture.tree()).is_clean());

        // The `a9fd1833` shape: a whole target crossed to Rust and the carve-out kept its name.
        let gone = exemptions(&fixture, "            exempt: &[\"Sources/SlopDeskTTY/\"],\n");
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &format!("pub fn a(tree: &Tree) -> Report {{\n{gone}}}\n"),
        );
        let found = every_exemption_names_a_path_the_tree_has(&fixture.tree());
        assert!(found.violations().iter().any(|line| line.contains("SlopDeskTTY")));
    }

    /// A `const` exemption is followed, and one that cannot be followed is itself the finding.
    #[test]
    fn a_named_exemption_is_resolved_or_reported() {
        let fixture = Fixture::new("gate-exemption-consts");
        let named = exemptions(&fixture, "            exempt: &[CHROME],\n");
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &format!("const CHROME: &str = \"Sources/A/Chrome.swift\";\npub fn a() {{\n{named}}}\n"),
        );
        fixture.write("Sources/A/Chrome.swift", "let x = 1\n");
        assert!(every_exemption_names_a_path_the_tree_has(&fixture.tree()).is_clean());

        // The const survives and the FILE does not — the `DevicePanelChrome.swift` shape.
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &format!("const CHROME: &str = \"Sources/A/Deleted.swift\";\npub fn a() {{\n{named}}}\n"),
        );
        let found = every_exemption_names_a_path_the_tree_has(&fixture.tree());
        assert!(found.violations().iter().any(|line| line.contains("Deleted")));

        // And a name this rule cannot follow at all.
        let unknown = exemptions(&fixture, "            exempt: &[NOWHERE],\n");
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &format!("pub fn a() {{\n{unknown}}}\n"),
        );
        let found = every_exemption_names_a_path_the_tree_has(&fixture.tree());
        assert!(found.violations().iter().any(|line| line.contains("NOWHERE")));
    }

    /// A carve-out spelled as a `const NAME: &[&str]` is followed into the list.
    ///
    /// THE HOLE THIS RULE SHIPPED WITH. Four of the crate's exemption lists are declared beside
    /// their rule and referenced bare — `exempt: DOMAIN_VIEW_FRAMEWORK_SEAMS` — and the first
    /// version matched `exempt: &[…]` only, so the four longest carve-outs in the crate were the
    /// four it could not see. One of them had been naming a deleted file for weeks. Both the
    /// multi-line declaration and the one-liner are seeded, because the parser handles them on
    /// different paths.
    #[test]
    fn a_carve_out_spelled_as_a_list_const_is_followed() {
        let fixture = Fixture::new("gate-exemption-list-consts");
        let named = exemptions(&fixture, "            exempt: SEAMS,\n");
        let declare = |body: &str| format!("const SEAMS: &[&str] = &[\n{body}];\npub fn a() {{\n{named}}}\n");
        fixture.write("Sources/A/Seam.swift", "let x = 1\n");
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &declare("    \"Sources/A/Seam.swift\",\n"),
        );
        assert!(every_exemption_names_a_path_the_tree_has(&fixture.tree()).is_clean());

        // The `TerminalRenderingView.swift` shape: the list outlives one of its files.
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &declare(
                "    \"Sources/A/Seam.swift\",\n    // an argued-for entry\n    \"Sources/A/Gone.swift\",\n",
            ),
        );
        let found = every_exemption_names_a_path_the_tree_has(&fixture.tree());
        assert!(
            found.violations().iter().any(|line| line.contains("Gone")),
            "{found:?}"
        );

        // The one-line declaration, which closes on the same line it opens.
        fixture.write(
            "rust/slopdesk-invariants/src/rules/example.rs",
            &format!("const SEAMS: &[&str] = &[\"Sources/A/Vanished.swift\"];\npub fn a() {{\n{named}}}\n"),
        );
        let found = every_exemption_names_a_path_the_tree_has(&fixture.tree());
        assert!(
            found.violations().iter().any(|line| line.contains("Vanished")),
            "{found:?}"
        );
    }

    /// A rules directory that reads as empty fails rather than passing.
    #[test]
    fn no_exemptions_at_all_is_red() {
        let fixture = Fixture::new("gate-exemptions-drained");
        fixture.write("rust/slopdesk-invariants/src/rules/example.rs", "pub fn a() {}\n");
        assert!(!every_exemption_names_a_path_the_tree_has(&fixture.tree()).is_clean());
    }
}
