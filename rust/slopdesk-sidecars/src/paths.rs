//! Where THIS tree's own daemons are — the one search order the five of them share.
//!
//! The port of the half of `Sources/SlopDeskSupervisor/RustServicePaths.swift` that every sidecar
//! manager called, and the answer to the note
//! `slopdesk_screenclient::paths` left behind: *"there is one caller today, and lifting it into a
//! shared crate before a second one exists would be guessing at the shape that second caller
//! wants."* There are six now — screend's client, dropd's face, inspectord's face, the bridge
//! daemon's locator and, twice over, the version audit — and they want exactly the shape the Swift
//! already had: a crate name and an override variable.
//!
//! ## Why this is NOT `locate_tool`
//! `slopdesk_androidd::toolchain::locate_tool` searches the vendored prefix, then
//! `PATH`, then Homebrew, because the programs it finds — `code-server`, `baguette`, `adb` — are
//! somebody else's, which an operator may reasonably have installed anywhere. These five are OURS:
//! they ship with this checkout, they speak a wire pinned to it, and a same-named binary on a
//! `PATH` must never become one. So there is no `PATH` rung here at all, and that absence is the
//! rule rather than an omission.
//!
//! ## Why it lives beside the audit and not beside a daemon
//! The audit's whole question is "what version does the binary that WOULD be spawned answer", so it
//! must resolve a path by the same rule the spawn does or it compares against a binary nobody
//! runs. Any other home would leave the audit importing a daemon crate to ask where a THIRD
//! daemon is.

use std::path::{Path, PathBuf};

use nix::unistd::{AccessFlags, access};

/// Levels walked up from the running executable before giving up.
///
/// A build tree is a handful of levels deep, and an unbounded walk from an executable somewhere
/// else entirely would stat its way to `/` for nothing. It is a WALK rather than a fixed depth
/// because `SwiftPM`'s `.build/debug` is a symlink to `.build/<triple>/debug`, so a binary found
/// next to a test bundle sits one level deeper than `swift run`'s — and a fixed count silently
/// resolves to nothing for one of them, which reads as "this machine has no screen engine".
const WALK_LIMIT: usize = 6;

/// Overrides which `slopdesk-superd` the audit reads a version off.
pub const SUPERD_BIN_ENV_KEY: &str = "SLOPDESK_SUPERD_BIN";

/// Overrides which `slopdesk-screend` gets started when none is listening.
pub const SCREEND_BIN_ENV_KEY: &str = "SLOPDESK_SCREEND_BIN";

/// Names the `slopdesk-dropd` to run. The E2E harness points it at its own build.
pub const DROPD_BIN_ENV_KEY: &str = "SLOPDESK_DROPD_BIN";

/// Names the `slopdesk-inspectord` to run. The E2E harness points it at its own build.
pub const INSPECTORD_BIN_ENV_KEY: &str = "SLOPDESK_INSPECTORD_BIN";

/// Names the `slopdesk-androidd` to run. The hardware gate points it at its own build.
pub const ANDROIDD_BIN_ENV_KEY: &str = "SLOPDESK_ANDROIDD_BIN";

/// The variable that overrides where `tool`'s binary is, by its `MANIFEST.json` name.
///
/// Spelled out rather than derived, and the Swift's own reason stands: `SLOPDESK_<X>_BIN` happens
/// to be the pattern today, and a derivation would go on quietly resolving to a variable nobody set
/// the day one of them is named differently.
///
/// `None` for the seven shipped programs that are not daemons — the CLI, the hook, the probe, the
/// seeder — because nothing overrides where they are and nothing asks. A caller that gets `None`
/// has asked about something this rule does not locate, which is not the same as a machine that
/// lacks it.
#[must_use]
pub fn binary_env_key(tool: &str) -> Option<&'static str> {
    match tool {
        "slopdesk-superd" => Some(SUPERD_BIN_ENV_KEY),
        "slopdesk-screend" => Some(SCREEND_BIN_ENV_KEY),
        "slopdesk-dropd" => Some(DROPD_BIN_ENV_KEY),
        "slopdesk-inspectord" => Some(INSPECTORD_BIN_ENV_KEY),
        "slopdesk-androidd" => Some(ANDROIDD_BIN_ENV_KEY),
        _ => None,
    }
}

/// The installed copy of `crate_name`, out of the build tree so a `cargo clean` cannot strand a
/// running host.
#[must_use]
pub fn installed(home: &Path, crate_name: &str) -> PathBuf {
    home.join("Library/Application Support/SlopDesk/bin")
        .join(crate_name)
}

/// Locates one of this tree's daemons, or `None` when this machine has none.
///
/// Four candidates in order: the override, the installed copy, the directory the running executable
/// sits in, then the crate's cargo target directories found by walking up from `executable`.
///
/// The third candidate is what makes a PACKAGED host work. A release tarball is one flat directory
/// of binaries — the formula's `bin.install` puts hostd and every daemon side by side under
/// `/opt/homebrew/bin` — and there is no cargo target tree within six levels of it and no
/// `~/Library/Application Support/SlopDesk/bin` unless somebody hand-made one. It sits AFTER the
/// installed copy so a deliberate hand-install still wins, and BEFORE the walk so a checkout's
/// staged copy beats a stale per-crate `target/`.
///
/// The walk looks under `rust/<crate>/target/` rather than `rust/target/` because every daemon in
/// this tree is EXCLUDED from the root cargo workspace and has one of its own, which is where its
/// output lands.
///
/// An OVERRIDE is not probed, deliberately: the caller that set it is aiming this locator, and a
/// probe would silently ignore the aim on the day the binary is momentarily being replaced by a
/// build. An empty override is no override, which is what an unset variable exported as `""` is.
#[must_use]
pub fn locate(
    crate_name: &str,
    binary_override: Option<&str>,
    home: Option<&Path>,
    executable: Option<&Path>,
) -> Option<PathBuf> {
    if let Some(value) = binary_override.filter(|value| !value.is_empty()) {
        return Some(PathBuf::from(value));
    }
    if let Some(home) = home {
        let candidate = installed(home, crate_name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    let mut directory = executable?.parent()?.to_path_buf();
    let beside = directory.join(crate_name);
    if is_executable(&beside) {
        return Some(beside);
    }
    for _ in 0..WALK_LIMIT {
        for profile in ["release", "debug"] {
            let candidate = directory
                .join("rust")
                .join(crate_name)
                .join("target")
                .join(profile)
                .join(crate_name);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }
        let Some(parent) = directory.parent() else {
            break;
        };
        if parent == directory {
            break;
        }
        directory = parent.to_path_buf();
    }
    None
}

/// [`locate`] against this process's environment and this process's executable.
///
/// The environment is read per CALL rather than once, deliberately: a host that installs the daemon
/// while hostd runs starts finding it on the next round, which is the same self-healing the
/// lifecycle's crash-drop gives.
#[must_use]
pub fn locate_from_env(crate_name: &str) -> Option<PathBuf> {
    let key = binary_env_key(crate_name)?;
    let override_value = std::env::var(key).ok();
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let executable = std::env::current_exe().ok();
    locate(
        crate_name,
        override_value.as_deref(),
        home.as_deref(),
        executable.as_deref(),
    )
}

/// `access(2)` with `X_OK`, which is the question `FileManager.isExecutableFile` asked and NOT the
/// question `mode & 0o111` answers.
///
/// The two disagree in both directions — a file whose mode bit is set on a filesystem mounted
/// `noexec`, a file this uid cannot traverse to — and `slopdesk-ffi/src/tool_path.rs` carries the
/// long version of why that mattered enough to write down. The port keeps the syscall the original
/// asked, so a machine that resolved a binary before still resolves it.
fn is_executable(path: &Path) -> bool {
    access(path, AccessFlags::X_OK).is_ok()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use std::os::unix::fs::PermissionsExt as _;
    use std::path::{Path, PathBuf};

    use super::{binary_env_key, installed, is_executable, locate};

    const CRATE: &str = "slopdesk-dropd";

    /// A private directory under the temp dir, named for the test that asked.
    fn scratch(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("slopdesk-sidecars-paths-{name}"));
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
    fn a_non_empty_override_wins_before_anything_is_stat_ed() {
        // Deliberately a path that does not exist: the override is not probed, because the caller
        // that set it is aiming this locator and a probe would silently ignore the aim.
        assert_eq!(
            locate(CRATE, Some("/nowhere/dropd"), None, None),
            Some(PathBuf::from("/nowhere/dropd")),
        );
        assert_eq!(locate(CRATE, Some(""), None, None), None);
    }

    #[test]
    fn the_installed_copy_beats_the_one_beside_the_executable() {
        let root = scratch("installed");
        let home = root.join("home");
        let bin = root.join("bin");
        touch_executable(&installed(&home, CRATE));
        touch_executable(&bin.join(CRATE));
        assert_eq!(
            locate(CRATE, None, Some(&home), Some(&bin.join("slopdesk-hostd"))),
            Some(installed(&home, CRATE)),
        );
    }

    #[test]
    fn a_flat_directory_of_binaries_resolves_which_is_what_a_brew_install_is() {
        let root = scratch("beside");
        let beside = root.join(CRATE);
        touch_executable(&beside);
        assert_eq!(
            locate(
                CRATE,
                None,
                Some(&root.join("no-home")),
                Some(&root.join("slopdesk-hostd")),
            ),
            Some(beside),
        );
    }

    #[test]
    fn the_walk_finds_a_per_crate_target_directory_several_levels_up() {
        let root = scratch("walk");
        let target = root.join("rust/slopdesk-dropd/target/debug/slopdesk-dropd");
        touch_executable(&target);
        let deep = root.join(".build/arm64-apple-macosx/debug/slopdesk-hostd");
        std::fs::create_dir_all(deep.parent().unwrap()).unwrap();
        assert_eq!(locate(CRATE, None, None, Some(&deep)), Some(target));
    }

    #[test]
    fn release_wins_over_debug_at_the_same_level() {
        let root = scratch("profile");
        let release = root.join("rust/slopdesk-dropd/target/release/slopdesk-dropd");
        touch_executable(&release);
        touch_executable(&root.join("rust/slopdesk-dropd/target/debug/slopdesk-dropd"));
        assert_eq!(
            locate(CRATE, None, None, Some(&root.join("slopdesk-hostd"))),
            Some(release),
        );
    }

    #[test]
    fn a_copy_reachable_only_through_path_is_not_one_of_ours() {
        // The rung `locate_tool` has and this deliberately does not. A `slopdesk-dropd` in some
        // directory that happens to be on `PATH` — the shape of an accident, and of an attack —
        // must never become the daemon hostd spawns. Asserted by absence: the only copy in this
        // tree sits in a directory none of the four rungs names, and the answer is `None`.
        let root = scratch("path");
        touch_executable(&root.join("somewhere-on-path").join(CRATE));
        assert_eq!(
            locate(
                CRATE,
                None,
                Some(&root.join("no-home")),
                Some(&root.join("bin/slopdesk-hostd")),
            ),
            None,
        );
    }

    #[test]
    fn a_machine_with_none_answers_none_rather_than_a_plausible_path() {
        let root = scratch("absent");
        assert_eq!(
            locate(CRATE, None, Some(&root), Some(&root.join("slopdesk-hostd"))),
            None,
        );
    }

    #[test]
    fn every_daemon_has_an_override_and_nothing_else_does() {
        for daemon in [
            "slopdesk-superd",
            "slopdesk-screend",
            "slopdesk-dropd",
            "slopdesk-inspectord",
            "slopdesk-androidd",
        ] {
            let key = binary_env_key(daemon).unwrap();
            assert!(key.starts_with("SLOPDESK_"), "{daemon} → {key}");
            assert!(key.ends_with("_BIN"), "{daemon} → {key}");
        }
        for resident_nowhere in ["slopdesk", "slopdesk-ctl", "slopdesk-hook", "slopdesk-hostd"] {
            assert_eq!(binary_env_key(resident_nowhere), None, "{resident_nowhere}");
        }
    }

    #[test]
    fn a_file_without_the_bit_is_not_executable() {
        let root = scratch("mode");
        let plain = root.join("plain");
        std::fs::write(&plain, b"data").unwrap();
        assert!(!is_executable(&plain));
        touch_executable(&plain);
        assert!(is_executable(&plain));
    }
}
