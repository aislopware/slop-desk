//! Every path dependency of the FFI shim is NAMED by a source file in the shim.
//!
//! ## Why this is a ratchet and not a review comment
//!
//! `slopdesk-gate ffi` builds its content stamp by walking `rust/slopdesk-ffi/Cargo.toml`'s
//! `path = "../…"` graph TRANSITIVELY (`slopdesk-devtools` `gates/ffi.rs` `input_crates`,
//! `docs/55` §3). That is the property the whole linked-artifact boundary rests on: a wrapped crate
//! is covered by its edge to the shim, not by a list anyone maintains, so a NEON edit two crates
//! down cannot ship against yesterday's archive.
//!
//! The cost lands on the other side of the same mechanism. An edge no source names contributes no
//! object to `libslopdesk_ffi.a` — the linker never sees the crate — so a change to it cannot make
//! the shipped artifact stale, and its only effect is to re-run the most expensive gate in the tree
//! for a crate the artifact does not contain.
//!
//! Fourteen such edges were found at once in 2026-08-31's sweep, and NONE was added by mistake:
//! every one was named by a door in the shim until the commit that retired that door — `d7e2acb5`
//! (the GUI video host), `62264bb6` and `10fcb58a` (the Swift host and its FFI half). Deleting a
//! door takes its `use` lines with it and leaves the manifest line standing. That is the shape a
//! ratchet catches and a reviewer does not: nothing breaks, every test passes, and the gate just
//! gets slower.
//!
//! ## Why "named", and not "in the archive"
//!
//! The DIRECT question is whether the crate is an `ar t` member of the built archive. Asking it
//! here would mean building the shim inside `just lint`, which the artifact/stamp split exists to
//! avoid. The textual answer is the cheap one and it is sound in the direction that matters: an
//! edge no source names is the only way an unlinked crate gets in, because a named one is either
//! linked or `cfg`-ed out by target — and a `cfg`-ed-out crate is still named.
//!
//! The looseness runs the other way: a crate mentioned only in a doc-comment reads as named. That
//! matches `lint-reach`'s standard and is the safe direction — the rule never demands the deletion
//! of an edge that is carrying weight.

use std::fs;
use std::path::Path;

use crate::report::Report;
use crate::tree::Tree;

/// The shim whose manifest is the stamp's root. There is exactly one.
const SHIM: &str = "rust/slopdesk-ffi";

/// Every `path = "../<sibling>"` dependency of the shim is named by one of its sources
///
/// See the module note. Read line-wise, the way `gates/ffi.rs` `path_dependencies` reads it, so the
/// `[target.'cfg(…)'.dependencies]` sections are covered too — nine of the fourteen lived there.
#[must_use]
pub fn every_ffi_edge_is_named_by_a_source(tree: &Tree) -> Report {
    let mut report = Report::new();
    let root = tree.root();
    let Ok(manifest) = fs::read_to_string(root.join(SHIM).join("Cargo.toml")) else {
        report.fail(format!(
            "{SHIM}/Cargo.toml is not readable — this gate cannot see what the ffi content stamp walks"
        ));
        return report;
    };

    let edges = sibling_path_dependencies(&manifest);
    if edges.is_empty() {
        report.fail(format!(
            "{SHIM}/Cargo.toml declares no sibling path dependencies — the ffi content stamp would cover \
             the shim alone, and every crate it wraps could go stale under it (docs/55 §3)"
        ));
        return report;
    }

    let sources = source_text(&root.join(SHIM));
    for edge in edges {
        let named = edge.replace('-', "_");
        if !sources.contains(&named) {
            report.fail(format!(
                "{SHIM} declares `{edge}` but no source here names `{named}` — an edge no source names \
                 contributes no object to `libslopdesk_ffi.a`, so it cannot make the artifact stale and \
                 only re-runs the most expensive gate in the tree. Either call it, or delete the line \
                 (docs/55 §3)"
            ));
        }
    }
    report
}

/// The manifest's `name = { … path = "../<sibling>" … }` lines, as crate names.
///
/// Deliberately the same line-wise shape as `gates/ffi.rs` `path_dependencies`: this rule is only
/// worth anything if it sees exactly the set the stamp walks, and a TOML parser that disagreed with
/// that function about one line would be a rule checking a different graph.
fn sibling_path_dependencies(manifest: &str) -> Vec<String> {
    let mut found = Vec::new();
    for line in manifest.lines() {
        let trimmed = line.trim_start();
        let Some((name, rest)) = trimmed.split_once('=') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty()
            || !name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        {
            continue;
        }
        let rest = rest.trim_start();
        if !rest.starts_with('{') {
            continue;
        }
        let Some(after) = rest
            .split_once("path")
            .and_then(|(_, tail)| tail.trim_start().strip_prefix('='))
        else {
            continue;
        };
        let Some(value) = after
            .trim_start()
            .strip_prefix('"')
            .and_then(|tail| tail.split('"').next())
        else {
            continue;
        };
        if let Some(sibling) = value.strip_prefix("../")
            && !sibling.contains('/')
            && !found.iter().any(|seen: &String| seen == name)
        {
            found.push(name.to_owned());
        }
    }
    found
}

/// Every `.rs` file under the shim, concatenated — `src`, `tests` and a `build.rs` alike.
///
/// All of them, because a crate named only by a test is still named: the test links it, so a change
/// to it can turn the suite red and the edge is carrying weight.
fn source_text(crate_dir: &Path) -> String {
    let mut text = String::new();
    collect(crate_dir, &mut text);
    text
}

/// Appends every `.rs` file under `dir`, recursively. Skips `target`, which is a symlink to the
/// build products and holds a copy of half the tree's sources under `registry`.
fn collect(dir: &Path, into: &mut String) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') || name == "target" {
            continue;
        }
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => collect(&path, into),
            Ok(kind) if kind.is_file() && path.extension().is_some_and(|ext| ext == "rs") => {
                if let Ok(body) = fs::read_to_string(&path) {
                    into.push_str(&body);
                    into.push('\n');
                }
            },
            _ => {},
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A shim whose every edge is called by a source, including one behind a `cfg` gate — which is
    /// where nine of the fourteen lived.
    fn shim(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture.write(
            "rust/slopdesk-ffi/Cargo.toml",
            "[dependencies]\nslopdesk-wire = { path = \"../slopdesk-wire\" }\nserde = { version = \"1\", \
             features = [\"derive\"] }\nvendored = { path = \"../../ThirdParty/thing\" \
             }\n\n[target.'cfg(target_os = \"macos\")'.dependencies]\nslopdesk-git = { path = \
             \"../slopdesk-git\" }\n",
        );
        fixture.write(
            "rust/slopdesk-ffi/src/lib.rs",
            "use slopdesk_wire::Frame;\n#[cfg(target_os = \"macos\")]\nuse slopdesk_git::Status;\n",
        );
        fixture
    }

    #[test]
    fn a_shim_whose_edges_are_all_called_is_clean() {
        let fixture = shim("ffi-edges-clean");
        let report = super::every_ffi_edge_is_named_by_a_source(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
    }

    /// The break-test: the exact drift the sweep found — a door retired, its `use` gone with it,
    /// the manifest line left standing.
    #[test]
    fn an_edge_no_source_names_is_caught() {
        let fixture = shim("ffi-edges-orphan");
        assert!(
            super::every_ffi_edge_is_named_by_a_source(&fixture.tree()).is_clean(),
            "the fixture must start clean, or this proves nothing"
        );

        fixture.write("rust/slopdesk-ffi/src/lib.rs", "use slopdesk_wire::Frame;\n");
        let report = super::every_ffi_edge_is_named_by_a_source(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("declares `slopdesk-git` but no source here names")),
            "{report:?}"
        );
    }

    /// A crate named only by a TEST is named: the test links it, so the edge carries weight.
    #[test]
    fn an_edge_named_only_by_a_test_is_kept() {
        let fixture = shim("ffi-edges-test-only");
        fixture.write("rust/slopdesk-ffi/src/lib.rs", "use slopdesk_wire::Frame;\n");
        fixture.write(
            "rust/slopdesk-ffi/tests/git.rs",
            "#[test]\nfn reads() { let _ = slopdesk_git::Status::default(); }\n",
        );
        let report = super::every_ffi_edge_is_named_by_a_source(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
    }

    /// A registry dependency and a non-sibling path are not this rule's business: neither is in the
    /// set `gates/ffi.rs` walks, so demanding a `use` for either would be a rule about a different
    /// graph. The fixture carries one of each.
    #[test]
    fn a_registry_or_nested_dependency_is_not_asked_for_a_use() {
        let fixture = shim("ffi-edges-registry");
        let report = super::every_ffi_edge_is_named_by_a_source(&fixture.tree());
        assert!(
            !report
                .violations()
                .iter()
                .any(|violation| violation.contains("serde") || violation.contains("vendored")),
            "{report:?}"
        );
    }

    /// A manifest with NO sibling edges is the opposite failure, and the worse one: the stamp would
    /// cover the shim alone and every crate it wraps could go stale under it.
    #[test]
    fn a_shim_with_no_edges_at_all_is_caught() {
        let fixture = shim("ffi-edges-none");
        fixture.write("rust/slopdesk-ffi/Cargo.toml", "[dependencies]\nserde = \"1\"\n");
        let report = super::every_ffi_edge_is_named_by_a_source(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("declares no sibling path dependencies")),
            "{report:?}"
        );
    }
}
