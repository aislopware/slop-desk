//! Where the two host daemons are, and how to build them. ONE answer, for every caller in this
//! crate.
//!
//! Six places used to spell the host binary by hand — four `swift_build(root, "slopdesk-hostd")`
//! calls in the GUI probes, a `root.join(".build/debug/slopdesk-hostd")` beside two of them, and
//! another in the soak runner. That was survivable while the path was a constant nobody touched.
//! `docs/60` stage F moved it, and six independent spellings of a path that just moved is six
//! chances to leave one behind — the probe that still builds nothing and then runs a binary from
//! last week, green, is the failure this module exists to make impossible.
//!
//! `slopdesk-videohostd` joined it for the same reason and on the same day it moved: `docs/61`
//! deleted `Sources/SlopDeskVideoHost` and with it the `SwiftPM` product, so the GUI video page's
//! `swift_build` + `.build/debug/…` pair and the video-input runner's `.build/release/…` were three
//! more spellings of a path that had just changed shape.
//!
//! ## Each crate is its OWN cargo workspace, so this is a `cd` and not a `-p`
//! `rust/Cargo.toml` cannot reach either daemon, which means the build runs with the crate
//! directory as its cwd and the artifacts land in `rust/<crate>/target/` rather than the shared
//! `rust/target/`. That is also why [`binary`] does not go looking: the layout is fixed by where
//! the manifest is, so the path is derived once here rather than searched for.
//!
//! ## `slopdesk-client` is NOT here
//! It is still a `SwiftPM` product under `.build/`, and it stays one until the client campaign. A
//! helper that answered for both would be the place someone later "fixed" the client path to match
//! the host's and broke every soak run.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Which daemon a caller is asking about.
///
/// A two-variant enum rather than a `&str`, because the whole point of this module is that the
/// crate name and the binary name are spelled ONCE — a string parameter would have let the third
/// caller pass `"videohostd"` and get a path that exists nowhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Daemon {
    /// The terminal host — `rust/slopdesk-hostd`, `docs/60`.
    Host,
    /// The GUI video host — `rust/slopdesk-videohostd`, `docs/61`.
    Video,
}

impl Daemon {
    /// The crate directory's name, which is also the binary's.
    const fn name(self) -> &'static str {
        match self {
            Self::Host => "slopdesk-hostd",
            Self::Video => "slopdesk-videohostd",
        }
    }
}

/// The crate directory, which is also the cwd every `cargo` invocation for it needs.
#[must_use]
pub fn crate_dir_of(root: &Path, daemon: Daemon) -> PathBuf {
    root.join("rust").join(daemon.name())
}

/// The terminal host's crate directory.
#[must_use]
pub fn crate_dir(root: &Path) -> PathBuf {
    crate_dir_of(root, Daemon::Host)
}

/// Where a `cargo build` for `release` puts `daemon`.
///
/// The two configurations are DIFFERENT DAEMONS and the launch record says which one is running
/// (`slopdesk_hostlaunch::record`), so nothing here guesses: the caller states which it built.
#[must_use]
pub fn binary_of(root: &Path, daemon: Daemon, release: bool) -> PathBuf {
    let configuration = if release { "release" } else { "debug" };
    crate_dir_of(root, daemon)
        .join("target")
        .join(configuration)
        .join(daemon.name())
}

/// Where a `cargo build` for `release` puts the terminal host.
#[must_use]
pub fn binary(root: &Path, release: bool) -> PathBuf {
    binary_of(root, Daemon::Host, release)
}

/// Build `daemon`, quietly.
///
/// # Errors
/// When `cargo` cannot be run at all, or the build fails.
pub fn build_of(root: &Path, daemon: Daemon, release: bool) -> Result<(), String> {
    let mut command = Command::new("cargo");
    command.arg("build");
    if release {
        command.arg("--release");
    }
    let status = command
        .current_dir(crate_dir_of(root, daemon))
        .stdout(Stdio::null())
        .status()
        .map_err(|error| format!("cargo: {error}"))?;
    if status.success() {
        return Ok(());
    }
    Err(format!(
        "cargo build{} in rust/{} failed",
        if release { " --release" } else { "" },
        daemon.name(),
    ))
}

/// Build the terminal host, quietly.
///
/// # Errors
/// When `cargo` cannot be run at all, or the build fails.
pub fn build(root: &Path, release: bool) -> Result<(), String> {
    build_of(root, Daemon::Host, release)
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

    /// The video daemon answers under its OWN crate, not the terminal host's and not `.build/`.
    ///
    /// The `.build/` clause is the one that matters here: `slopdesk-videohostd` WAS a `SwiftPM`
    /// product, and the failure this pins out is a caller that kept the old path and then ran a
    /// stale Swift binary — or nothing at all — while reporting green.
    #[test]
    fn the_video_daemon_is_its_own_crate_and_never_under_dot_build() {
        let root = Path::new("/r");
        assert_eq!(
            super::crate_dir_of(root, super::Daemon::Video),
            Path::new("/r/rust/slopdesk-videohostd")
        );
        assert_eq!(
            super::binary_of(root, super::Daemon::Video, true),
            Path::new("/r/rust/slopdesk-videohostd/target/release/slopdesk-videohostd")
        );
        assert_eq!(
            super::binary_of(root, super::Daemon::Video, false),
            Path::new("/r/rust/slopdesk-videohostd/target/debug/slopdesk-videohostd")
        );
        for release in [true, false] {
            let path = super::binary_of(root, super::Daemon::Video, release);
            assert!(!path.to_string_lossy().contains(".build/"), "release={release}");
        }
    }
}
