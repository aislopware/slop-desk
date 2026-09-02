//! Cargo build products stay OUTSIDE the checkout, and every crate says so the same way.
//!
//! ## Why this is a ratchet and not a preference
//!
//! Both app specs declare the `SwiftPM` package as `path: ../..` — the REPO ROOT. Xcode enumerates
//! that whole tree on every invocation, single-threaded, one `lstat` per file
//! (`IDEContainer _locateFileReferencesRecursivelyInGroup:` → `DVTFilePath
//! _locked_vnodeKnownDoesNotExist:`). With the 73 cargo target directories in place the root held
//! 3.1M files against 679 Swift and 1,286 Rust sources, and a `slopdesk-gate ios` that compiled
//! NOTHING took 987 s. Moved out: 22 s. Both directions measured 2026-08-31, with `sample` naming
//! the frames.
//!
//! So the cost of a crate that quietly builds in-tree again is not a few gigabytes of disk — it is
//! the inner loop going back to sixteen minutes, silently, for everyone. Nothing else notices: the
//! crate compiles, its tests pass, `just lint` is green, and the only symptom is that the Xcode
//! gates get slower. That is exactly the shape a ratchet is for.
//!
//! ## The two halves, and why BOTH are checked
//!
//! * `.cargo/config.toml` — committed, and the half that makes cargo WRITE outside. ⚠️ cargo
//!   discovers config from the CWD, not from the manifest, so `cargo --manifest-path
//!   rust/X/Cargo.toml` run from the repo root reads `rust/.cargo/config.toml` and NOT the crate's.
//!   That is why the root workspace's config is required here too rather than treated as one more
//!   crate: it is the backstop for every invocation that is not `cd`'d into a crate.
//! * `rust/<crate>/target` — a SYMLINK, gitignored, rebuilt by `just relink-targets`. It is the
//!   READ half: ten production files, three justfile sites and one Swift test resolve a daemon as
//!   `<crate>/target/release/<name>`, and `cargo clean` removes a link rather than its contents.
//!
//! A crate with the config but no link builds correctly and cannot be LOCATED; a crate with the
//! link but no config writes through it into the shared tree, which is right by accident and stops
//! being right the moment someone runs cargo from a different directory. Neither half is redundant.

use std::fs;
use std::path::Path;

use crate::report::Report;
use crate::tree::Tree;

/// Where the artifacts live, as a sibling of the checkout.
///
/// A sibling rather than an absolute path, because `.cargo/config.toml` is COMMITTED: an absolute
/// `target-dir` would bake this checkout's location into the repository and break every other
/// machine and every second worktree. Relative is resolved against the config's own directory, so
/// the same three-`..` spelling works from any crate.
const OUTSIDE: &str = "slopdesk-targets";

/// The one crate directory under `rust/` that is not a crate.
///
/// `slopdesk-ffi/rust` is a nested checkout artefact rather than a workspace member.
const NOT_A_CRATE: [&str; 1] = ["rust"];

/// The root workspace's `members`, which own no target directory of their own.
///
/// A MEMBER builds into the workspace's `rust/target`, so it has neither a `.cargo/config.toml` nor
/// a `target` link and asking it for either would be asking about a directory cargo never creates.
/// Every other crate under `rust/` is its own workspace root — the root manifest `exclude`s them
/// for the reason its own comment gives (profiles are workspace-global and `panic`/`lto` cannot be
/// overridden per package) — and each of those does own one.
///
/// Read out of the manifest rather than listed here, because a list would be a second copy of
/// `members` to keep in step, and the day it drifted this rule would demand a config from a crate
/// that must not have one.
fn workspace_members(root: &Path) -> Vec<String> {
    let Ok(manifest) = fs::read_to_string(root.join("rust/Cargo.toml")) else {
        return Vec::new();
    };
    let Some(tail) = manifest.split_once("members = [").map(|(_, tail)| tail) else {
        return Vec::new();
    };
    let Some((list, _)) = tail.split_once(']') else {
        return Vec::new();
    };
    list.split(',')
        .map(|entry| entry.trim().trim_matches('"').to_owned())
        .filter(|entry| !entry.is_empty())
        .collect()
}

/// Every crate under `rust/` writes its build products outside the checkout, and can be located
///
/// See the module note for the measurement. Both halves are checked per crate: the committed
/// `.cargo/config.toml` that makes cargo write outside, and the `target` symlink that lets the
/// runtime locators still resolve `<crate>/target/release/<name>`.
#[must_use]
pub fn build_products_live_outside_the_checkout(tree: &Tree) -> Report {
    let mut report = Report::new();
    let root = tree.root();
    let Ok(entries) = fs::read_dir(root.join("rust")) else {
        report.fail("rust/ is not readable — this gate cannot see whether the target dirs moved out");
        return report;
    };

    let members = workspace_members(root);
    let mut crates: Vec<String> = entries
        .flatten()
        .filter(|entry| entry.path().join("Cargo.toml").is_file())
        .filter_map(|entry| entry.file_name().to_str().map(str::to_owned))
        .filter(|name| !NOT_A_CRATE.contains(&name.as_str()))
        .filter(|name| !members.contains(name))
        .collect();
    crates.sort();

    if crates.is_empty() {
        report.fail("rust/ holds no crate manifests — the walk is looking in the wrong place");
        return report;
    }

    // The ROOT workspace config is the backstop for every `--manifest-path` invocation, which reads
    // config from the CWD and would otherwise miss each crate's own. See the module note.
    check_config(&mut report, root, "", "_workspace", "../..");
    check_link(&mut report, root, "rust/target");

    for name in &crates {
        check_config(&mut report, root, name, name, "../../..");
        check_link(&mut report, root, &format!("rust/{name}/target"));
    }
    report
}

/// One crate's committed `.cargo/config.toml` names the sibling tree.
///
/// `hops` differs between the root workspace (`rust/.cargo/` is two levels down) and a crate
/// (`rust/<crate>/.cargo/` is three), and it is spelled per call rather than derived so a wrong
/// answer is a wrong LITERAL here rather than an off-by-one nobody reads.
fn check_config(report: &mut Report, root: &Path, crate_dir: &str, slice: &str, hops: &str) {
    let relative = if crate_dir.is_empty() {
        "rust/.cargo/config.toml".to_owned()
    } else {
        format!("rust/{crate_dir}/.cargo/config.toml")
    };
    let Ok(text) = fs::read_to_string(root.join(&relative)) else {
        report.fail(format!(
            "{relative} is missing — this crate would build into the checkout, and 3.1M artifacts under the \
             SwiftPM package root cost the iOS gate 987 s of lstat (docs/46, `just relink-targets`)"
        ));
        return;
    };
    let want = format!("{hops}/{OUTSIDE}/{slice}");
    if !text.contains(&want) {
        report.fail(format!(
            "{relative} does not name `{want}` as its target-dir — a config that points somewhere else puts \
             the artifacts back under the package root (docs/46)"
        ));
    }
}

/// How many files a single non-dot directory under the repo root may hold before it is a gate cost.
///
/// Measured rather than picked: seeding 200,000 files into a non-dot directory at the root took a
/// bare `-showBuildSettings` from 15 s to 54 s, so the walk costs roughly 5 ms per thousand files.
/// The ceiling here is where a tree starts being worth a second of every Xcode gate, which is far
/// below anything a source tree reaches — `Sources` is 768 files and `ThirdParty` 98 once its two
/// DOT-directories are discounted.
const WALKED_FILE_CEILING: usize = 20_000;

/// How deep to look for one. A generated tree announces itself in the first level or two.
const WALK_DEPTH: usize = 2;

/// No large GENERATED tree sits where Xcode's package walk can see it
///
/// The companion to [`build_products_live_outside_the_checkout`], and the general form of the same
/// defect. Xcode enumerates the `SwiftPM` package root — this repository — on every invocation, and
/// its walk SKIPS dot-directories and walks every other one. That is the whole reason the root can
/// still hold 552 K files and cost nothing: `.build`, `.work`, `.git` and
/// `ThirdParty/tools/.prefix` — the provisioned runtime deps, which since docs/68 also hold the
/// terminal engine's source at its pinned commit — are all invisible to it.
///
/// So the invariant is not about cargo. It is that any large generated tree under the root must be
/// either DOT-PREFIXED or outside the checkout — and a new one that is neither costs every Xcode
/// gate proportionally, silently, with everything still compiling. See `docs/46`.
#[must_use]
pub fn no_generated_tree_sits_in_the_package_walk(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut offenders: Vec<(String, usize)> = Vec::new();
    collect_heavy(tree.root(), tree.root(), WALK_DEPTH, &mut offenders);
    offenders.sort();
    for (path, count) in offenders {
        report.fail(format!(
            "{path} holds {count} files where Xcode's package walk can see them — the walk skips \
             DOT-directories and walks every other one, at roughly 5 ms per thousand files on EVERY \
             invocation of every Xcode gate. Dot-prefix it or move it outside the checkout (docs/46)"
        ));
    }
    report
}

/// Every non-dot directory within `depth` of the root that is over the ceiling, and its count.
///
/// A directory over the ceiling is reported and NOT descended into: the offender is the tree, and
/// naming its children as well would bury the one line a reader needs.
fn collect_heavy(root: &Path, dir: &Path, depth: usize, into: &mut Vec<(String, usize)>) {
    if depth == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        // A DOT-directory is invisible to the walk, and a SYMLINK is a leaf to it — `lstat` does
        // not follow one. Neither costs the gate anything, which is what makes both a
        // legitimate home for a generated tree.
        if name.starts_with('.') || !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let count = count_files(&path);
        if count > WALKED_FILE_CEILING {
            let display = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .into_owned();
            into.push((display, count));
            continue;
        }
        collect_heavy(root, &path, depth - 1, into);
    }
}

/// Files under `dir`, counted the way the walk sees them: dot-directories and symlinks are leaves.
fn count_files(dir: &Path) -> usize {
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    let mut total = 0;
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => total += count_files(&entry.path()),
            Ok(_) => total += 1,
            Err(_) => {},
        }
    }
    total
}

/// One crate's `target` is a symlink, so the runtime locators still resolve it.
///
/// A missing link is reported as such rather than as a broken one: `cargo clean` takes the LINK
/// out, and "run `just relink-targets`" is the fix for both.
fn check_link(report: &mut Report, root: &Path, relative: &str) {
    let path = root.join(relative);
    let Ok(entry) = fs::symlink_metadata(&path) else {
        report.fail(format!(
            "{relative} is gone — ten production files and one Swift test resolve a daemon as \
             `<crate>/target/release/…` and `cargo clean` removes the link, not its contents; run `just \
             relink-targets`"
        ));
        return;
    };
    if !entry.file_type().is_symlink() {
        report.fail(format!(
            "{relative} is a real directory — the artifacts are back inside the checkout, which is the 987 \
             s the measurement in docs/46 names; run `just relink-targets`"
        ));
        return;
    }
    if !path.is_dir() {
        report.fail(format!(
            "{relative} is a symlink that resolves to nothing — the sibling `{OUTSIDE}` tree is missing its \
             slice; run `just relink-targets`"
        ));
    }
}

#[cfg(test)]
mod tests {
    #![expect(clippy::expect_used, reason = "a panic in a test is the failure report")]

    use std::fs;

    use crate::tests::Fixture;

    /// Seeds `count` files under `dir`, flat — enough to cross the ceiling without a deep tree.
    fn seed(dir: &std::path::Path, count: usize) {
        fs::create_dir_all(dir).expect("seed dir");
        for index in 0..count {
            fs::write(dir.join(format!("f{index}")), b"").expect("seed file");
        }
    }

    /// A tree whose only heavy directories are DOT-prefixed costs the walk nothing.
    #[test]
    fn a_dot_directory_may_be_as_heavy_as_it_likes() {
        let fixture = Fixture::new("walk-dotted");
        let root = fixture.tree();
        let root = root.root().to_path_buf();
        seed(&root.join(".build"), super::WALKED_FILE_CEILING + 10);
        let report = super::no_generated_tree_sits_in_the_package_walk(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
    }

    /// The same tree without its dot is the regression this rule exists for.
    #[test]
    fn a_heavy_non_dot_directory_is_caught() {
        let fixture = Fixture::new("walk-undotted");
        let root = fixture.tree();
        let root = root.root().to_path_buf();
        seed(&root.join("generated"), super::WALKED_FILE_CEILING + 10);
        let report = super::no_generated_tree_sits_in_the_package_walk(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("generated holds")),
            "{report:?}"
        );
    }

    /// A SYMLINK is a leaf to the walk — `lstat` does not follow one — so its weight is not
    /// counted. This is the fact the whole cargo migration rests on.
    #[test]
    fn a_symlink_to_a_heavy_tree_is_not_counted() {
        let fixture = Fixture::new("walk-linked");
        let root = fixture.tree();
        let root = root.root().to_path_buf();
        let outside = root.join("../slopdesk-invariants-walk-linked-outside");
        seed(&outside, super::WALKED_FILE_CEILING + 10);
        fixture.link("linked", "../slopdesk-invariants-walk-linked-outside");
        let report = super::no_generated_tree_sits_in_the_package_walk(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
        let _ignored = fs::remove_dir_all(&outside);
    }

    /// An ordinary source tree is nowhere near the ceiling, so the rule is silent on the real tree.
    #[test]
    fn a_source_tree_is_far_below_the_ceiling() {
        let fixture = Fixture::new("walk-sources");
        let root = fixture.tree();
        let root = root.root().to_path_buf();
        seed(&root.join("Sources"), 800);
        let report = super::no_generated_tree_sits_in_the_package_walk(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
    }

    /// A tree that satisfies the rule: two crates, each with a config and a link, plus the root.
    ///
    /// ⚠️ The sibling artifact tree is named PER TEST. These run concurrently and the real
    /// spelling — a plain `slopdesk-targets` beside the root — would be one shared directory that
    /// every fixture creates and the dangling-link test deletes out from under the others. The
    /// CONFIG text still carries the real spelling, which is what the rule reads; only the link's
    /// referent is made unique, and the rule asks of a link whether it resolves, not where to.
    fn linked(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        let root = fixture.tree();
        let root = root.root().to_path_buf();
        let outside = root.join(format!("../slopdesk-invariants-{name}-targets"));
        fixture.write(
            "rust/Cargo.toml",
            "[workspace]\nmembers = [\"slopdesk-member\"]\n",
        );
        // A root-workspace MEMBER: it builds into `rust/target` and owns neither half, so the rule
        // must not ask it for either. See `workspace_members`.
        fixture.write("rust/slopdesk-member/Cargo.toml", "[package]\n");
        fixture.write(
            "rust/.cargo/config.toml",
            "[build]\ntarget-dir = \"../../slopdesk-targets/_workspace\"\n",
        );
        for crate_name in ["slopdesk-one", "slopdesk-two"] {
            fixture.write(&format!("rust/{crate_name}/Cargo.toml"), "[package]\n");
            fixture.write(
                &format!("rust/{crate_name}/.cargo/config.toml"),
                &format!("[build]\ntarget-dir = \"../../../slopdesk-targets/{crate_name}\"\n"),
            );
            fs::create_dir_all(outside.join(crate_name)).ok();
            fixture.link(
                &format!("rust/{crate_name}/target"),
                &format!("../../../slopdesk-invariants-{name}-targets/{crate_name}"),
            );
        }
        fs::create_dir_all(outside.join("_workspace")).ok();
        fixture.link(
            "rust/target",
            &format!("../../slopdesk-invariants-{name}-targets/_workspace"),
        );
        fixture
    }

    /// The per-test sibling tree, which `Fixture`'s own `Drop` cannot reach.
    fn clean_up(name: &str) {
        let _ignored =
            fs::remove_dir_all(std::env::temp_dir().join(format!("slopdesk-invariants-{name}-targets")));
    }

    #[test]
    fn a_tree_whose_crates_all_build_outside_is_clean() {
        let fixture = linked("targets-clean");
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
        clean_up("targets-clean");
    }

    /// The commonest drift: a crate added without the config, which builds in-tree silently.
    #[test]
    fn a_crate_without_its_config_is_caught() {
        let fixture = linked("targets-no-config");
        assert!(super::build_products_live_outside_the_checkout(&fixture.tree()).is_clean());

        fixture.remove("rust/slopdesk-two/.cargo/config.toml");
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("rust/slopdesk-two/.cargo/config.toml is missing")),
            "{report:?}"
        );
        clean_up("targets-no-config");
    }

    /// A root-workspace MEMBER builds into `rust/target` and owns neither half — demanding a config
    /// from one would be demanding a directory cargo never creates.
    #[test]
    fn a_root_workspace_member_is_not_asked_for_its_own_target_dir() {
        let fixture = linked("targets-member");
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(
            !report
                .violations()
                .iter()
                .any(|violation| violation.contains("slopdesk-member")),
            "{report:?}"
        );
        clean_up("targets-member");
    }

    /// A config pointing INSIDE the checkout is the same defect wearing the right filename.
    #[test]
    fn a_config_naming_an_in_tree_target_is_caught() {
        let fixture = linked("targets-wrong-dir");
        fixture.write(
            "rust/slopdesk-one/.cargo/config.toml",
            "[build]\ntarget-dir = \"target\"\n",
        );
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("does not name")),
            "{report:?}"
        );
        clean_up("targets-wrong-dir");
    }

    /// ⚠️ The ROOT config is not one crate among many: cargo reads config from the CWD, so a
    /// `--manifest-path` run from the repo root reads THIS one and no crate's.
    #[test]
    fn the_root_workspace_config_is_required_too() {
        let fixture = linked("targets-no-root");
        fixture.remove("rust/.cargo/config.toml");
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("rust/.cargo/config.toml is missing")),
            "{report:?}"
        );
        clean_up("targets-no-root");
    }

    /// A REAL directory where the link belongs is the artifacts back inside the package root.
    #[test]
    fn a_real_target_directory_is_caught() {
        let fixture = linked("targets-real-dir");
        let root = fixture.tree();
        let path = root.root().join("rust/slopdesk-one/target");
        fs::remove_file(&path).expect("take the link out");
        fs::create_dir_all(&path).expect("put a real directory there");
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("is a real directory")),
            "{report:?}"
        );
        clean_up("targets-real-dir");
    }

    /// `cargo clean` removes the LINK, not its contents — and then nothing can locate the daemon.
    #[test]
    fn a_missing_link_is_caught() {
        let fixture = linked("targets-no-link");
        let root = fixture.tree();
        fs::remove_file(root.root().join("rust/slopdesk-two/target")).expect("take the link out");
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("rust/slopdesk-two/target is gone")),
            "{report:?}"
        );
        clean_up("targets-no-link");
    }

    /// A link into a slice that does not exist resolves to nothing, and a locator walking it finds
    /// no daemon — which reads as "not built" rather than as "not linked".
    #[test]
    fn a_dangling_link_is_caught() {
        let fixture = linked("targets-dangling");
        assert!(super::build_products_live_outside_the_checkout(&fixture.tree()).is_clean());

        fs::remove_dir_all(
            std::env::temp_dir().join("slopdesk-invariants-targets-dangling-targets/slopdesk-one"),
        )
        .expect("take the slice out from under the link");
        let report = super::build_products_live_outside_the_checkout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("resolves to nothing")),
            "{report:?}"
        );
        clean_up("targets-dangling");
    }
}
