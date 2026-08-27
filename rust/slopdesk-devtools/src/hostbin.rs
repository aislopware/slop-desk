//! Where `slopdesk-hostd` is, and how to build it. ONE answer, for every caller in this crate.
//!
//! Six places used to spell the host binary by hand — four `swift_build(root, "slopdesk-hostd")`
//! calls in the GUI probes, a `root.join(".build/debug/slopdesk-hostd")` beside two of them, and
//! another in the soak runner. That was survivable while the path was a constant nobody touched.
//! `docs/60` stage F moved it, and six independent spellings of a path that just moved is six
//! chances to leave one behind — the probe that still builds nothing and then runs a binary from
//! last week, green, is the failure this module exists to make impossible.
//!
//! ## The crate is its OWN cargo workspace, so this is a `cd` and not a `-p`
//! `rust/Cargo.toml` cannot reach `slopdesk-hostd`, which means the build runs with the crate
//! directory as its cwd and the artifacts land in `rust/slopdesk-hostd/target/` rather than the
//! shared `rust/target/`. That is also why [`binary`] does not go looking: the layout is fixed by
//! where the manifest is, so the path is derived once here rather than searched for.
//!
//! ## `slopdesk-client` is NOT here
//! It is still a `SwiftPM` product under `.build/`, and it stays one until the client campaign. A
//! helper that answered for both would be the place someone later "fixed" the client path to match
//! the host's and broke every soak run.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The crate directory, which is also the cwd every `cargo` invocation for it needs.
#[must_use]
pub fn crate_dir(root: &Path) -> PathBuf {
    root.join("rust/slopdesk-hostd")
}

/// Where a `cargo build` for `release` puts the daemon.
///
/// The two configurations are DIFFERENT DAEMONS and the launch record says which one is running
/// (`slopdesk_hostlaunch::record`), so nothing here guesses: the caller states which it built.
#[must_use]
pub fn binary(root: &Path, release: bool) -> PathBuf {
    let configuration = if release { "release" } else { "debug" };
    crate_dir(root)
        .join("target")
        .join(configuration)
        .join("slopdesk-hostd")
}

/// Build the daemon, quietly.
///
/// # Errors
/// When `cargo` cannot be run at all, or the build fails.
pub fn build(root: &Path, release: bool) -> Result<(), String> {
    let mut command = Command::new("cargo");
    command.arg("build");
    if release {
        command.arg("--release");
    }
    let status = command
        .current_dir(crate_dir(root))
        .stdout(Stdio::null())
        .status()
        .map_err(|error| format!("cargo: {error}"))?;
    if status.success() {
        return Ok(());
    }
    Err(format!(
        "cargo build{} in rust/slopdesk-hostd failed",
        if release { " --release" } else { "" }
    ))
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    /// The two configurations are two paths, and neither is under `.build/`.
    ///
    /// The last clause is the one worth pinning. `.build/` is where the `SwiftPM` host lived, and
    /// `ops::hostd::is_swiftpm_artifact` REFUSES a launch record naming it — a helper that answered
    /// with a `.build/` path would make the probes build one binary and the restart refuse the
    /// other, which reads as a broken machine rather than as a wrong constant.
    #[test]
    fn the_two_configurations_are_two_paths_under_the_crates_own_target() {
        let root = Path::new("/r");
        assert_eq!(
            super::binary(root, true),
            Path::new("/r/rust/slopdesk-hostd/target/release/slopdesk-hostd")
        );
        assert_eq!(
            super::binary(root, false),
            Path::new("/r/rust/slopdesk-hostd/target/debug/slopdesk-hostd")
        );
        for release in [true, false] {
            assert!(
                !crate::ops::hostd::is_swiftpm_artifact(&super::binary(root, release)),
                "release={release}"
            );
        }
    }

    /// The build runs from the crate directory, because the crate is its own workspace.
    #[test]
    fn the_build_runs_from_the_crate_directory() {
        assert_eq!(
            super::crate_dir(Path::new("/r")),
            Path::new("/r/rust/slopdesk-hostd")
        );
    }
}
