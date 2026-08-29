//! The pre-push unit-test gate: a green-tree cache, and the two things that invalidate it.
//!
//! ## Why a cache
//! `swift test` costs ~60-90 s per push, and most pushes happen on a tree that was ALREADY tested
//! green — a `just check`, a manual run, a previous push attempt minutes earlier. So the gate keys
//! on the exact content under test and skips the run when that key matches the last green.
//! Invalidation is automatic: any new commit changes the tree hash.
//!
//! ## The key is a PAIR, and the second half is why
//! The Swift suite links `SlopDeskFFI.xcframework`, and the git tree cannot see it change: `rust/`
//! is untracked, so `HEAD^{tree}` is byte-identical before and after a Rust edit. On a clean tree
//! that made the cache answer "already tested green" for a suite that had never run against the
//! artifact `just ffi` had rebuilt a minute earlier — the linked port's stale-artifact failure
//! mode, one level above the `--check` gate that exists for it. `sources.sha256` is the right
//! witness and already exists.
//!
//! It lives in its OWN marker rather than being concatenated onto the tree hash, because
//! [`super::touched`] reads the tree marker as a git REF — a marker with a suffix stops being an
//! object id and sends that gate to the full suite forever.
//!
//! ## Clean means the inputs the suite CONSUMES
//! Not just what it compiles. `LaunchRestoreGateContractTests` and `GuiGateLaunchContractTests`
//! open `scripts/*.sh` and `scripts/fixtures/` off DISK at run time, so a scripts-only edit changes
//! what the suite asserts while leaving every compiled input untouched. A green recorded over a
//! dirty `scripts/` is a green about text nobody ran.
//!
//! ## The sidecars must EXIST before the suite runs
//! A Swift suite that starts a real daemon `XCTSkip`s by name when its binary is missing. That is
//! right inside a test and wrong for a GATE: `swift build` never sees cargo, so nothing in the
//! Swift graph builds those binaries, and a push on a tree that has not had `just test` against it
//! reports green over exactly the surface a daemon is needed to reach. The list is DERIVED from the
//! fixtures rather than written here, so a new suite booting a new daemon is covered the day it
//! lands.
//!
//! What this covers has NARROWED, and the derivation is why that is safe rather than silent. It
//! once read superd, screend and dropd out of eighteen suites; `docs/60` and `docs/63` ported all
//! but one of those to Rust, and today it derives `dropd` alone, from `DropdE2ETests`. The Rust
//! replacements are not this gate's business: cargo builds a test's own crate, `just client-e2e`
//! builds the host and superd it then starts, and neither can be reached by a `swift test` that
//! skipped. The moment Swift boots a daemon again the derivation sees it, which is the property
//! worth keeping — a hand-written list would have gone stale in the other, dangerous direction.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use regex::Regex;

use crate::proc;

/// The recorded tree of the last full green run. A git object id, and nothing else.
pub const TREE_MARKER: &str = ".build/pre-push-green-tree";

/// The recorded FFI source stamp of that same run.
pub const FFI_MARKER: &str = ".build/pre-push-green-ffi";

/// What `build-ffi` writes: the hash of every Rust input plus its own text.
pub const FFI_STAMP: &str = "ThirdParty/slopdesk-ffi/sources.sha256";

/// The inputs `swift test` actually consumes — compiled and read-at-runtime alike.
///
/// Both gates that write the markers use this exact list: a disagreement about what counts as clean
/// is a disagreement about what the marker MEANS.
pub const TESTED_INPUTS: &[&str] = &["Package.swift", "Sources", "Tests", "Apps", "golden", "scripts"];

/// The FFI source stamp, or an empty string on a tree that has never built it.
#[must_use]
pub fn ffi_stamp(root: &Path) -> String {
    fs::read_to_string(root.join(FFI_STAMP))
        .unwrap_or_default()
        .trim()
        .to_owned()
}

/// True when nothing staged, modified or untracked sits among [`TESTED_INPUTS`].
#[must_use]
pub fn tested_inputs_clean(root: &Path) -> bool {
    let mut arguments: Vec<String> = vec!["status".to_owned(), "--porcelain".to_owned(), "--".to_owned()];
    arguments.extend(TESTED_INPUTS.iter().map(|path| (*path).to_owned()));
    proc::ask("git", &arguments, root).is_some_and(|status| status.trim().is_empty())
}

/// `HEAD^{tree}` — the content the suite would be testing.
///
/// # Errors
/// When this is not a git tree, or HEAD has no commit.
pub fn head_tree(root: &Path) -> Result<String, String> {
    proc::capture("git", &["rev-parse", "HEAD^{tree}"], root)
}

/// Record a green run in BOTH markers, or in neither.
///
/// Called by this gate and by [`super::touched`] after a FULL run: the tree marker alone would
/// claim a green that the artifact half then denies.
///
/// # Errors
/// When `.build/` cannot be created or a marker cannot be written.
pub fn record_green(root: &Path) -> Result<(), String> {
    if !tested_inputs_clean(root) {
        return Ok(());
    }
    let tree = head_tree(root)?;
    let build = root.join(".build");
    fs::create_dir_all(&build).map_err(|error| format!("{}: {error}", build.display()))?;
    fs::write(root.join(TREE_MARKER), format!("{tree}\n"))
        .map_err(|error| format!("{TREE_MARKER}: {error}"))?;
    fs::write(root.join(FFI_MARKER), format!("{}\n", ffi_stamp(root)))
        .map_err(|error| format!("{FFI_MARKER}: {error}"))
}

/// A marker's recorded value, trimmed, or an empty string when it is absent.
#[must_use]
pub fn recorded(root: &Path, marker: &str) -> String {
    fs::read_to_string(root.join(marker))
        .unwrap_or_default()
        .trim()
        .to_owned()
}

/// The daemons the Swift fixtures look for, derived from the fixtures themselves.
///
/// Each fixture spells `rust/slopdesk-<name>/target` and then looks for
/// `{release,debug}/slopdesk-<name>`. The REPO-ROOT-relative spelling is what makes this scan
/// possible and it is not a coincidence: a Swift test bundle's working directory is not the
/// package root, so a fixture has to resolve from the root anyway. A Rust test writes
/// `../slopdesk-<name>/target` off `CARGO_MANIFEST_DIR` instead and is deliberately NOT matched —
/// cargo builds that crate's own binaries, so there is nothing here to guard.
///
/// # Errors
/// When `Tests/` cannot be walked.
pub fn expected_daemons(root: &Path) -> Result<BTreeSet<String>, String> {
    let pattern = Regex::new(r"rust/(slopdesk-[a-z]+)/target").map_err(|error| error.to_string())?;
    let mut found = BTreeSet::new();
    let mut swift = Vec::new();
    collect_swift(&root.join("Tests"), &mut swift)?;
    for file in swift {
        let text = fs::read_to_string(&file).unwrap_or_default();
        for capture in pattern.captures_iter(&text) {
            found.insert(capture[1].to_owned());
        }
    }
    Ok(found)
}

/// Those daemons with no built binary, in either profile.
///
/// # Errors
/// When `Tests/` cannot be walked.
pub fn missing_daemons(root: &Path) -> Result<Vec<String>, String> {
    Ok(expected_daemons(root)?
        .into_iter()
        .filter(|daemon| {
            !["release", "debug"].iter().any(|profile| {
                root.join(format!("rust/{daemon}/target/{profile}/{daemon}"))
                    .is_file()
            })
        })
        .collect())
}

/// The whole gate: refuse an unbuilt tree, consult the cache, run, record.
///
/// # Errors
/// When a sidecar is missing, `swift test` fails, or git cannot answer.
pub fn run(root: &Path) -> Result<(), String> {
    let missing = missing_daemons(root)?;
    if !missing.is_empty() {
        let names = missing.join(" ");
        // The just recipe drops the `slopdesk-` prefix: the binary is `slopdesk-superd`, the recipe
        // is `superd`. Both spellings appear in the fixtures' own skip messages.
        let recipes = missing
            .iter()
            .map(|daemon| daemon.trim_start_matches("slopdesk-"))
            .collect::<Vec<_>>()
            .join(" ");
        eprintln!(
            "pre-push: these sidecars are not built, so the suites that boot them would XCTSkip and this"
        );
        eprintln!("          gate would pass without running them: {names}");
        eprintln!("          run: just {recipes}  (or 'just test', which does it and then runs this)");
        eprintln!("          A fixture may still be pointed elsewhere with its SLOPDESK_*_BIN override.");
        return Err("pre-push: unbuilt sidecars".to_owned());
    }

    let tree = head_tree(root)?;
    let stamp = ffi_stamp(root);
    if tested_inputs_clean(root) && recorded(root, TREE_MARKER) == tree && recorded(root, FFI_MARKER) == stamp
    {
        let short: String = tree.chars().take(12).collect();
        println!("pre-push: tree {short} already tested green — skipping swift test");
        return Ok(());
    }

    proc::run("swift", &["test", "--parallel"], root)?;
    record_green(root)
}

/// Every `.swift` under `dir`.
fn collect_swift(dir: &Path, into: &mut Vec<std::path::PathBuf>) -> Result<(), String> {
    if !dir.is_dir() {
        return Ok(());
    }
    let entries = fs::read_dir(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    for entry in entries {
        let path = entry.map_err(|error| error.to_string())?.path();
        if path.is_dir() {
            collect_swift(&path, into)?;
        } else if path.extension().and_then(|value| value.to_str()) == Some("swift") {
            into.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{TESTED_INPUTS, expected_daemons, missing_daemons};

    fn fixture(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("slopdesk-prepush-{name}-{}", std::process::id()));
        let _ignored = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("Tests/Deep")).unwrap();
        root
    }

    /// The list is derived, so a nineteenth suite booting a new daemon is covered the day it lands.
    #[test]
    fn the_daemon_set_comes_off_the_fixtures() {
        let root = fixture("derive");
        fs::write(
            root.join("Tests/Superd.swift"),
            "let dir = \"rust/slopdesk-superd/target/release/slopdesk-superd\"\n",
        )
        .unwrap();
        fs::write(
            root.join("Tests/Deep/Screend.swift"),
            "// rust/slopdesk-screend/target is where it looks\n",
        )
        .unwrap();
        let found = expected_daemons(&root).unwrap();
        assert!(found.contains("slopdesk-superd"), "{found:?}");
        assert!(found.contains("slopdesk-screend"), "{found:?}");
        assert_eq!(found.len(), 2, "{found:?}");
    }

    #[test]
    fn a_daemon_built_in_either_profile_is_not_missing() {
        let root = fixture("profiles");
        fs::write(root.join("Tests/A.swift"), "rust/slopdesk-dropd/target\n").unwrap();
        assert_eq!(missing_daemons(&root).unwrap(), vec!["slopdesk-dropd".to_owned()]);

        fs::create_dir_all(root.join("rust/slopdesk-dropd/target/debug")).unwrap();
        fs::write(
            root.join("rust/slopdesk-dropd/target/debug/slopdesk-dropd"),
            "bin",
        )
        .unwrap();
        assert!(missing_daemons(&root).unwrap().is_empty());
    }

    /// `scripts/` is a tested input because two suites READ it; dropping it would let a
    /// scripts-only edit record a green about text nobody ran.
    #[test]
    fn the_tested_inputs_include_what_the_suite_only_reads() {
        assert!(TESTED_INPUTS.contains(&"scripts"));
        assert!(TESTED_INPUTS.contains(&"golden"));
    }
}
