//! The pre-push unit-test gate: a green-tree cache, and the two things that invalidate it.
//!
//! ## Why a cache
//! `swift test` costs ~60-90 s per push, and most pushes happen on a tree that was ALREADY tested
//! green — a `just check`, a manual run, a previous push attempt minutes earlier. So the gate keys
//! on the exact content under test and skips the run when that key matches the last green.
//! Invalidation is automatic: any new commit changes the tree hash.
//!
//! ## The key is a PAIR, and the second half is why
//! The Swift suite links `SlopDeskFFI.xcframework`, and the git tree cannot see it change. TWO
//! independent reasons, and this note claimed a third that is not true: `rust/` is TRACKED, 1 367
//! files of it, so a COMMITTED crate edit does move `HEAD^{tree}`. What does not move it is an
//! UNCOMMITTED one — a tree hash is a commit's tree, and `just ffi` builds from the working tree —
//! and the artifact itself is outside git entirely, `.gitignore` ignoring all of
//! `ThirdParty/slopdesk-ffi/`, `sources.sha256` included. Either way the cache answered "already
//! tested green" on a clean tree for a suite that had never run against the artifact `just ffi`
//! rebuilt a minute earlier — the linked port's stale-artifact failure mode, one level above the
//! `--check` gate that exists for it. `sources.sha256` is the right witness and already exists.
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

#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "the skip notice and the stale-fixture warning are this gate's report"
)]

use std::collections::{BTreeMap, BTreeSet};
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
/// Both gates that write the markers use this exact list, and the fast loop SELECTS against it: a
/// disagreement about what counts as clean is a disagreement about what the marker MEANS.
///
/// It was two lists that disagreed. [`super::touched`] spelled its own `PATHSPEC` while a ratchet
/// in `slopdesk-invariants` recorded that the duplication had been removed in the port — it had
/// been removed for the two MARKERS and not for this. They differed in both directions.
/// `Package.resolved` was in the fast loop's copy and not here, and it is the one that mattered:
/// `swift test` compiles against the versions that file pins, `swift test` reads it from the
/// WORKING tree, and a green recorded while it was dirty promised the committed tree had passed
/// with pins the run never used. `Apps` was here and not there, in the harmless direction and with
/// a real cost — no `SwiftPM` target compiles a byte of it and no suite opens it at run time, so
/// every push while an app shell was dirty re-ran ninety seconds the cache had already earned. The
/// xcodegen shells are the two xcode gates' business, and those carry their own stamp.
pub const TESTED_INPUTS: &[&str] = &[
    "Package.swift",
    "Package.resolved",
    "Sources",
    "Tests",
    "golden",
    "scripts",
];

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
    Ok(daemon_consumers(root)?.into_keys().collect())
}

/// The same scan, keeping WHICH suite spells each daemon.
///
/// [`super::touched`] needs the edge and this gate needs only the names, so the scan is written
/// once and reduced twice: a second walk with the same regex would be two answers to one question,
/// and the day one of them learned a new spelling the other would still be right about the old one.
///
/// The key is the crate, the values are test TARGET names — the directory under `Tests/`, which is
/// what `swift test --filter` matches and what the package description calls the target.
///
/// A `.swift` directly in `Tests/` still contributes its CRATE and no target: `SwiftPM` compiles
/// nothing outside a target directory, so such a file boots no daemon at test time and can name no
/// suite, while this gate's own question — is the binary built — is answered by the name alone.
/// There is no such file today; the entry exists so that the reduction below stays what it was.
///
/// # Errors
/// When `Tests/` cannot be walked.
pub fn daemon_consumers(root: &Path) -> Result<BTreeMap<String, BTreeSet<String>>, String> {
    let pattern = Regex::new(r"rust/(slopdesk-[a-z]+)/target").map_err(|error| error.to_string())?;
    let mut found: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let tests = root.join("Tests");
    let mut swift = Vec::new();
    collect_swift(&tests, &mut swift)?;
    for file in swift {
        let text = fs::read_to_string(&file).unwrap_or_default();
        let target = file
            .parent()
            .filter(|parent| *parent != tests.as_path())
            .and_then(|_| file.strip_prefix(&tests).ok())
            .and_then(|relative| relative.iter().next())
            .and_then(|name| name.to_str());
        for capture in pattern.captures_iter(&text) {
            let suites = found.entry(capture[1].to_owned()).or_default();
            if let Some(name) = target {
                suites.insert(name.to_owned());
            }
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
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]
    use std::collections::BTreeSet;
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

    /// The two entries the fast loop's second copy of this list disagreed about, in both
    /// directions.
    #[test]
    fn the_tested_inputs_are_the_suites_inputs_and_only_those() {
        assert!(
            TESTED_INPUTS.contains(&"Package.resolved"),
            "the suite compiles against the versions it pins, and reads it from the working tree"
        );
        assert!(
            !TESTED_INPUTS.contains(&"Apps"),
            "no SwiftPM target compiles the xcodegen shells — the two xcode gates stamp them"
        );
    }

    /// The scan keeps WHICH suite spells each daemon, so the fast loop can select it.
    #[test]
    fn a_fixture_names_the_suite_that_boots_it() {
        let root = fixture("consumers");
        fs::create_dir_all(root.join("Tests/SlopDeskFileTransferTests")).unwrap();
        fs::write(
            root.join("Tests/SlopDeskFileTransferTests/DropdE2ETests.swift"),
            "let dir = \"rust/slopdesk-dropd/target\"\n",
        )
        .unwrap();
        // Directly under `Tests/`: a crate with no suite, because SwiftPM compiles no such file.
        fs::write(root.join("Tests/Loose.swift"), "rust/slopdesk-superd/target\n").unwrap();
        let found = super::daemon_consumers(&root).unwrap();
        assert_eq!(
            found
                .get("slopdesk-dropd")
                .map(|suites| suites.iter().cloned().collect::<Vec<_>>()),
            Some(vec!["SlopDeskFileTransferTests".to_owned()])
        );
        assert!(
            found.get("slopdesk-superd").is_some_and(BTreeSet::is_empty),
            "the loose fixture must still count as a daemon this gate checks for: {found:?}"
        );
    }
}
