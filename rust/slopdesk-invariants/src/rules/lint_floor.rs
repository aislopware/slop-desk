//! Every crate manifest carries the SAME lint tables as the root workspace.
//!
//! Seventy-odd crates each sit in their own workspace, because the root `exclude`s them
//! (`docs/46`) — so there is no `[lints] workspace = true` for most of them to inherit, and the
//! maximal policy the root states is copied into each manifest by hand. A copy drifts: a group left
//! at `warn`, a restriction lint missing, a level typed as `"deny"` where the root has `"forbid"`.
//! None of that is a compile error, and `-D warnings` only hardens what the table names — a lint
//! the table forgot is not warned about at all.
//!
//! The rule reads the root's two tables as the floor and requires every other manifest to state
//! them EXACTLY, entry for entry. The only tolerated difference is the one `docs/55` §5 already
//! licenses: a crate allowed to write `unsafe` says `unsafe_code = "deny"` and adds
//! `unsafe_op_in_unsafe_fn = "deny"`, where the floor says `forbid`. Which crates may say that is
//! [`crate::rules::crate_policy::unsafe_policy`]'s question, not this one's.

use std::collections::BTreeSet;

use crate::report::Report;
use crate::rules::crate_policy::{ROOT_MANIFEST, crate_name_of, manifests, root_members};
use crate::tree::Tree;

/// The one line an unsafe-writing crate replaces in the floor's rust table.
const FORBID: &str = r#"unsafe_code = "forbid""#;
/// The two lines it states instead (`docs/55` §5).
const DENY: [&str; 2] = [r#"unsafe_code = "deny""#, r#"unsafe_op_in_unsafe_fn = "deny""#];

/// The entries of one `[header]` table: every non-blank, non-comment line up to the next header.
fn table(text: &str, header: &str) -> BTreeSet<String> {
    let mut entries = BTreeSet::new();
    let mut inside = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            inside = trimmed == header;
            continue;
        }
        if inside && !trimmed.is_empty() && !trimmed.starts_with('#') {
            entries.insert(trimmed.to_owned());
        }
    }
    entries
}

/// Every crate's lint tables agree with the root workspace's
///
/// The floor is `[workspace.lints.rust]` and `[workspace.lints.clippy]` in `rust/Cargo.toml`. A
/// root MEMBER inherits it through `[lints] workspace = true` and is not compared. Any other
/// manifest either states `[lints.rust]`/`[lints.clippy]` itself or — a nested workspace with its
/// own members — restates the floor as its own `[workspace.lints.*]` and inherits that; both are
/// compared entry for entry, and a missing table is an empty one, which fails.
#[must_use]
pub fn lint_floor_agrees(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(root) = report.source(tree, ROOT_MANIFEST, "its lint tables are the floor") else {
        return report;
    };
    let floor_rust = table(&root.text, "[workspace.lints.rust]");
    let floor_clippy = table(&root.text, "[workspace.lints.clippy]");
    report.fail_if(
        !floor_rust.contains(FORBID) || floor_clippy.is_empty(),
        format!(
            "{ROOT_MANIFEST} no longer states the maximal lint floor — every other manifest is compared \
             against it (docs/46)"
        ),
    );
    let members = root_members(tree, &mut report);

    let mut drifted: Vec<String> = Vec::new();
    for manifest in manifests(tree) {
        if manifest == ROOT_MANIFEST || members.contains(&crate_name_of(&manifest)) {
            continue;
        }
        let Some(source) = tree.get(&manifest) else {
            continue;
        };
        let inherits = table(&source.text, "[lints]").contains("workspace = true");
        let (rust, clippy) = if inherits {
            (
                table(&source.text, "[workspace.lints.rust]"),
                table(&source.text, "[workspace.lints.clippy]"),
            )
        } else {
            (
                table(&source.text, "[lints.rust]"),
                table(&source.text, "[lints.clippy]"),
            )
        };

        let mut expected_rust = floor_rust.clone();
        if rust.contains(DENY[0]) {
            expected_rust.remove(FORBID);
            expected_rust.extend(DENY.iter().map(|line| (*line).to_owned()));
        }
        let missing_rust: Vec<&String> = expected_rust.difference(&rust).collect();
        let extra_rust: Vec<&String> = rust.difference(&expected_rust).collect();
        let missing_clippy: Vec<&String> = floor_clippy.difference(&clippy).collect();
        let extra_clippy: Vec<&String> = clippy.difference(&floor_clippy).collect();
        if missing_rust.is_empty()
            && extra_rust.is_empty()
            && missing_clippy.is_empty()
            && extra_clippy.is_empty()
        {
            continue;
        }
        let mut detail: Vec<String> = Vec::new();
        for (label, entries) in [
            ("rust lacks", missing_rust),
            ("rust adds", extra_rust),
            ("clippy lacks", missing_clippy),
            ("clippy adds", extra_clippy),
        ] {
            if !entries.is_empty() {
                let listed: Vec<&str> = entries.iter().map(|entry| entry.as_str()).collect();
                detail.push(format!("{label} `{}`", listed.join("`, `")));
            }
        }
        drifted.push(format!("{manifest} ({})", detail.join("; ")));
    }
    if !drifted.is_empty() {
        report.fail(format!(
            "a manifest states a lint table that differs from {ROOT_MANIFEST}'s — the floor is copied by \
             hand into every excluded workspace, and a copy that drifts is a crate linted below the policy \
             (docs/46): {}",
            drifted.join("; ")
        ));
    }
    report
}

#[cfg(test)]
mod tests {
    use super::lint_floor_agrees;
    use crate::tests::Fixture;

    const ROOT: &str = "[workspace]\nmembers = [\"slopdesk-hook\"]\n\n[workspace.lints.rust]\nunsafe_code = \
                        \"forbid\"\nmissing_docs = \"deny\"\n\n[workspace.lints.clippy]\nall = { level = \
                        \"deny\", priority = -1 }\nunwrap_used = \"deny\"\n";
    const MEMBER: &str = "[package]\nname = \"slopdesk-hook\"\n\n[lints]\nworkspace = true\n";
    const OWN: &str = "[workspace]\n\n[package]\nname = \"slopdesk-wire\"\n\n[lints.rust]\nunsafe_code = \
                       \"forbid\"\nmissing_docs = \"deny\"\n\n[lints.clippy]\nall = { level = \"deny\", \
                       priority = -1 }\nunwrap_used = \"deny\"\n";
    const UNSAFE: &str = "[workspace]\n\n[package]\nname = \"slopdesk-posix\"\n\n[lints.rust]\nunsafe_code \
                          = \"deny\"\nunsafe_op_in_unsafe_fn = \"deny\"\nmissing_docs = \
                          \"deny\"\n\n[lints.clippy]\nall = { level = \"deny\", priority = -1 \
                          }\nunwrap_used = \"deny\"\n";
    const NESTED: &str = "[workspace]\nmembers = [\"seed\"]\n\n[package]\nname = \
                          \"slopdesk-codeseed\"\n\n[lints]\nworkspace = \
                          true\n\n[workspace.lints.rust]\nunsafe_code = \"forbid\"\nmissing_docs = \
                          \"deny\"\n\n[workspace.lints.clippy]\nall = { level = \"deny\", priority = -1 \
                          }\nunwrap_used = \"deny\"\n";

    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write("rust/Cargo.toml", ROOT)
            .write("rust/slopdesk-hook/Cargo.toml", MEMBER)
            .write("rust/slopdesk-wire/Cargo.toml", OWN)
            .write("rust/slopdesk-posix/Cargo.toml", UNSAFE)
            .write("rust/slopdesk-codeseed/Cargo.toml", NESTED);
        fixture
    }

    #[test]
    fn a_tree_whose_every_table_matches_the_floor_passes() {
        let fixture = seeded("lint-floor-agrees");
        assert!(lint_floor_agrees(&fixture.tree()).violations().is_empty());
    }

    #[test]
    fn a_manifest_missing_one_floor_entry_fails() {
        let fixture = seeded("lint-floor-lacks");
        fixture.write(
            "rust/slopdesk-wire/Cargo.toml",
            &OWN.replace("unwrap_used = \"deny\"\n", ""),
        );
        let violations = lint_floor_agrees(&fixture.tree()).violations().to_vec();
        assert!(
            violations.iter().any(|v| v.contains("differs from")),
            "{violations:?}"
        );
    }

    #[test]
    fn a_manifest_lowering_a_level_fails() {
        let fixture = seeded("lint-floor-lowers");
        fixture.write(
            "rust/slopdesk-wire/Cargo.toml",
            &OWN.replace("missing_docs = \"deny\"", "missing_docs = \"warn\""),
        );
        assert!(!lint_floor_agrees(&fixture.tree()).violations().is_empty());
    }

    #[test]
    fn a_manifest_with_no_table_at_all_fails() {
        let fixture = seeded("lint-floor-absent");
        fixture.write(
            "rust/slopdesk-wire/Cargo.toml",
            "[workspace]\n\n[package]\nname = \"slopdesk-wire\"\n",
        );
        assert!(!lint_floor_agrees(&fixture.tree()).violations().is_empty());
    }

    #[test]
    fn an_unsafe_crate_that_forgot_unsafe_op_in_unsafe_fn_fails() {
        let fixture = seeded("lint-floor-unsafe-op");
        fixture.write(
            "rust/slopdesk-posix/Cargo.toml",
            &UNSAFE.replace("unsafe_op_in_unsafe_fn = \"deny\"\n", ""),
        );
        assert!(!lint_floor_agrees(&fixture.tree()).violations().is_empty());
    }

    #[test]
    fn a_nested_workspace_whose_restated_floor_drifts_fails() {
        let fixture = seeded("lint-floor-nested");
        fixture.write(
            "rust/slopdesk-codeseed/Cargo.toml",
            &NESTED.replace("unwrap_used = \"deny\"\n", ""),
        );
        assert!(!lint_floor_agrees(&fixture.tree()).violations().is_empty());
    }

    #[test]
    fn a_root_that_lost_its_floor_fails() {
        let fixture = seeded("lint-floor-root");
        fixture.write("rust/Cargo.toml", "[workspace]\nmembers = [\"slopdesk-hook\"]\n");
        assert!(!lint_floor_agrees(&fixture.tree()).violations().is_empty());
    }
}
