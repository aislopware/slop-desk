//! Where `slopdesk-screend` listens, where its binary is, and where its log goes.
//!
//! The port of hostd's Swift screend path resolution plus the one service-path function it
//! called. Both were deleted in `docs/60` Batch B.
//!
//! ## The address is not decided here
//! [`request_socket`] resolves two environment variables and hands them to
//! [`slopdesk_screenwire::socket_path`], which is where the PRECEDENCE, the emptiness filter and
//! the last-resort directory live. That split is not tidiness: the Swift original resolved the
//! directory itself, through `NSTemporaryDirectory()`, which on Darwin answers
//! `confstr(_CS_DARWIN_USER_TEMP_DIR)` and ignores `$TMPDIR` entirely — so any process whose
//! `TMPDIR` pointed elsewhere had a daemon binding one path and its client dialling another, with
//! "screend appears not to be running" as the only symptom.
//!
//! ## The binary is NOT decided here any more
//! [`binary`] WAS the whole of `RustServicePaths.locate`, kept here because there was one caller
//! and lifting it before a second existed would have been guessing at the shape that second caller
//! wanted. There are six now — dropd's face, inspectord's face, the bridge daemon's locator and,
//! twice over, the version audit — and they all want a crate name and an override variable. So the
//! rule moved to [`slopdesk_sidecars::paths`], beside the audit that asks where a binary IS, and
//! what is left here is this crate's name and its two environment variables.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// Points this process at a screend other than the login session's. The test fixture uses it to run
/// a private daemon; nothing else should.
pub const SOCKET_ENV_KEY: &str = "SLOPDESK_SCREEND_SOCKET";

/// Overrides which `slopdesk-screend` binary gets started when none is listening.
///
/// Re-exported rather than re-spelled: the audit needs the same variable for the same daemon, and
/// two spellings of it is the drift the lift was for.
pub const BINARY_ENV_KEY: &str = slopdesk_sidecars::paths::SCREEND_BIN_ENV_KEY;

/// The daemon's crate name, which is also its executable name and its cargo target directory.
const CRATE: &str = "slopdesk-screend";

/// screend's request socket — `slopdesk-screend.sock`, under whichever directory the rule picks.
///
/// `$TMPDIR` on macOS is already a per-user, `0700` directory, which is what makes an un-suffixed
/// name safe — and a name with no pid in it is the point: a restarted screend must answer at the
/// address its clients already hold.
#[must_use]
pub fn request_socket(socket_override: Option<&OsStr>, tmpdir: Option<&OsStr>) -> PathBuf {
    slopdesk_screenwire::socket_path(socket_override, tmpdir)
}

/// [`request_socket`] against this process's environment.
#[must_use]
pub fn request_socket_from_env() -> PathBuf {
    request_socket(
        std::env::var_os(SOCKET_ENV_KEY).as_deref(),
        std::env::var_os("TMPDIR").as_deref(),
    )
}

/// The installed copy of screend, out of the build tree so a `cargo clean` cannot strand a running
/// host.
#[must_use]
pub fn installed(home: &Path) -> PathBuf {
    slopdesk_sidecars::paths::installed(home, CRATE)
}

/// Locates the `slopdesk-screend` executable, or `None` when this machine has none.
///
/// Four candidates in order — the override, the installed copy, the directory the running
/// executable sits in, then the crate's cargo target directories found by walking up. The order and
/// every reason for it are [`slopdesk_sidecars::paths::locate`]'s; what this adds is the crate
/// name.
#[must_use]
pub fn binary(
    binary_override: Option<&OsStr>,
    home: Option<&Path>,
    executable: Option<&Path>,
) -> Option<PathBuf> {
    slopdesk_sidecars::paths::locate(CRATE, binary_override.and_then(OsStr::to_str), home, executable)
}

/// [`binary`] against this process's environment and this process's executable.
#[must_use]
pub fn binary_from_env() -> Option<PathBuf> {
    slopdesk_sidecars::paths::locate_from_env(CRATE)
}

/// Where a screend this client STARTS writes its stdout and stderr.
///
/// A file, never the parent's stdio: a screend that outlives its parent while holding the write end
/// of an inherited pipe is how a test harness hangs reading for an EOF that cannot arrive. The
/// fallback is the temp directory rather than `/dev/null`, because a screend that failed to start
/// says why on the channel this names, and losing that is losing the diagnosis.
#[must_use]
pub fn log_file(home: Option<&Path>) -> PathBuf {
    if let Some(home) = home {
        let directory = home.join("Library/Logs/SlopDesk");
        if std::fs::create_dir_all(&directory).is_ok() {
            return directory.join("screend.log");
        }
    }
    std::env::temp_dir().join("slopdesk-screend.log")
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use std::ffi::OsStr;
    use std::os::unix::fs::PermissionsExt as _;
    use std::path::{Path, PathBuf};

    use super::{binary, installed, log_file, request_socket};

    /// A private directory under the temp dir, named for the test that asked.
    fn scratch(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("slopdesk-screenclient-paths-{name}"));
        let _ignored = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    fn touch_executable(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn the_socket_rule_is_the_wire_crates_and_not_a_second_opinion() {
        assert_eq!(
            request_socket(Some(OsStr::new("/tmp/pinned.sock")), Some(OsStr::new("/nope"))),
            PathBuf::from("/tmp/pinned.sock"),
        );
        assert_eq!(
            request_socket(None, Some(OsStr::new("/var/folders/x"))),
            PathBuf::from("/var/folders/x/slopdesk-screend.sock"),
        );
    }

    #[test]
    fn a_non_empty_override_wins_before_anything_is_stat_ed() {
        // Deliberately a path that does not exist: the override is not probed, because the caller
        // that set it is aiming this client and a probe would silently ignore the aim.
        assert_eq!(
            binary(Some(OsStr::new("/nowhere/screend")), None, None),
            Some(PathBuf::from("/nowhere/screend")),
        );
        assert_eq!(binary(Some(OsStr::new("")), None, None), None);
    }

    #[test]
    fn the_installed_copy_beats_the_one_beside_the_executable() {
        let root = scratch("installed");
        let home = root.join("home");
        let bin = root.join("bin");
        touch_executable(&installed(&home));
        touch_executable(&bin.join("slopdesk-screend"));
        assert_eq!(
            binary(None, Some(&home), Some(&bin.join("slopdesk-hostd"))),
            Some(installed(&home)),
        );
    }

    #[test]
    fn a_flat_directory_of_binaries_resolves_which_is_what_a_brew_install_is() {
        let root = scratch("beside");
        let beside = root.join("slopdesk-screend");
        touch_executable(&beside);
        assert_eq!(
            binary(
                None,
                Some(&root.join("no-home")),
                Some(&root.join("slopdesk-hostd"))
            ),
            Some(beside),
        );
    }

    #[test]
    fn the_walk_finds_a_per_crate_target_directory_several_levels_up() {
        let root = scratch("walk");
        let target = root.join("rust/slopdesk-screend/target/debug/slopdesk-screend");
        touch_executable(&target);
        let deep = root.join(".build/arm64-apple-macosx/debug/slopdesk-hostd");
        std::fs::create_dir_all(deep.parent().unwrap()).unwrap();
        assert_eq!(binary(None, None, Some(&deep)), Some(target));
    }

    #[test]
    fn release_wins_over_debug_at_the_same_level() {
        let root = scratch("profile");
        let release = root.join("rust/slopdesk-screend/target/release/slopdesk-screend");
        touch_executable(&release);
        touch_executable(&root.join("rust/slopdesk-screend/target/debug/slopdesk-screend"));
        assert_eq!(
            binary(None, None, Some(&root.join("slopdesk-hostd"))),
            Some(release)
        );
    }

    #[test]
    fn a_machine_with_no_screend_answers_none_rather_than_a_plausible_path() {
        let root = scratch("absent");
        assert_eq!(
            binary(None, Some(&root), Some(&root.join("slopdesk-hostd"))),
            None
        );
    }

    #[test]
    fn the_log_lands_under_the_home_that_was_named() {
        let root = scratch("log");
        assert_eq!(
            log_file(Some(&root)),
            root.join("Library/Logs/SlopDesk/screend.log")
        );
        assert!(log_file(None).is_absolute());
    }
}
