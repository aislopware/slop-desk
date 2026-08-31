//! The operator harnesses: the things a developer runs BY HAND, on their own machine, on purpose.
//!
//! ## Where the line with [`crate::gates`] falls
//! A gate answers a yes/no about the tree and a `just` target runs it. Nothing here does. These
//! install a `LaunchAgent`, restart a live daemon, regenerate an `.xcodeproj`, re-sync a
//! vendor's theme resources, or drive an eighty-second soak — every one of them CHANGES the
//! machine or the working tree, which is exactly why none of them is in `just check` and why each
//! prints what it is about to do before it does it.
//!
//! ## What was here before
//! Ten shell scripts:
//!
//! | was | is |
//! | --- | --- |
//! | `restart-hostd.sh` | [`hostd`] |
//! | `install-superd.sh` · `install-screend.sh` | [`launchd`] — one installer, two agents |
//! | `enable-macos-renderer.sh` · `enable-ios-renderer.sh` | GONE — see [`xcodegen`] |
//! | `monokai-sync.sh` | [`monokai`] |
//! | `herdr-sync.sh` | [`herdr`] |
//! | `measure-code-server-start.sh` | [`codeserver`] |
//! | `video-input-test.sh` | [`videoinput`] |
//! | `soak-fanout-laggard.sh` | [`soak`] |
//!
//! Four of those ten came in PAIRS that differed only in a table — two `LaunchAgent` plists, two
//! `project.yml` anchor sets — and shell had no way to share the logic without a third file to
//! `source`. The pairs are one function and two constants here, which is the whole reason the
//! ported line count is under half the shell's.
//!
//! ## The pair that stopped existing
//! The two renderer injectors are gone with the libghostty fork they wired in (`docs/68` §10). They
//! existed because the terminal conformer was compiled by NO `Package.swift` target — it joined the
//! Xcode app by a text insert into a committed spec, on demand, because the xcframework it linked
//! was gitignored and xcodegen resolves a framework path at GENERATE time. The conformer is a
//! package source now, `swift build` compiles it, and a spec that names no un-buildable artifact
//! needs no injector. What is LEFT of that pair is the half that was never about the fork:
//! [`xcodegen`], the one place this crate shells out to regenerate a `.xcodeproj`.
//!
//! ## What stopped being a dependency
//! `jq` (the launch record is [`serde_json`]), `python3` (the timestamps, the JSON transform and
//! the theme rewrite are all in-process) and `awk`/`sed` (the log scrapes are [`regex`] or plain
//! `str` splits). `curl`, `unzip`, `git`, `swift`, `cargo`, `xcodegen`, `launchctl` and `lsof`
//! stay — each is a thing a compiled program genuinely cannot do itself, which is the same line
//! [`crate::proc`] draws for the release.
//!
//! ## The one rule every daemon launch here obeys
//! A daemon this family starts gets its OWN container — `SLOPDESK_APP_SUPPORT_DIR`,
//! `SLOPDESK_SCROLLBACK_DIR`, `SLOPDESK_FILE_DROP_DIR`, `SLOPDESK_WORKSPACE_STATE_DIR` — because
//! `HOME` moves none of the four. [`container`] is the one place that set is spelled, and the
//! reason it is a function rather than four lines per call site is that the shell wrote it out
//! per script and one of the four scripts got it wrong for months.

pub mod codeserver;
pub mod herdr;
pub mod hostd;
pub mod launchd;
pub mod monokai;
pub mod soak;
pub mod videoinput;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::proc;

/// The `SLOPDESK_*` pairs that give a daemon a container of its own, with the directories made.
///
/// Four variables and not one, because each answers a different question and `HOME` answers none
/// of them: Core Foundation reads the account record for `NSHomeDirectory()` unless
/// `CFFIXED_USER_HOME` is set, and `CFFIXED_USER_HOME` is the wrong tool for a daemon anyway — it
/// also relocates the home a pane takes its default working directory from.
///
/// What an un-contained daemon does to the developer, all four observed on this host: it sweeps
/// their scrollback journals to the newest 256 on its FIRST loop iteration, it rewrites the
/// `workspace-state.json` of the layout they are working in, it resolves their `~/Downloads` as
/// its file-drop directory, and — for `slopdesk-videohostd` — it reads and then UNLINKS the
/// `parked-windows.json` crash journal belonging to their own running host.
///
/// # Errors
/// When a directory cannot be made.
pub fn container(state: &Path) -> Result<Vec<(String, String)>, String> {
    let scrollback = state.join("scrollback");
    let drop = state.join("drop");
    for directory in [state, &scrollback, &drop] {
        fs::create_dir_all(directory).map_err(|error| format!("{}: {error}", directory.display()))?;
    }
    Ok(vec![
        ("SLOPDESK_APP_SUPPORT_DIR".to_owned(), state.display().to_string()),
        (
            "SLOPDESK_SCROLLBACK_DIR".to_owned(),
            scrollback.display().to_string(),
        ),
        ("SLOPDESK_FILE_DROP_DIR".to_owned(), drop.display().to_string()),
        (
            "SLOPDESK_WORKSPACE_STATE_DIR".to_owned(),
            state.display().to_string(),
        ),
    ])
}

/// The developer's own home, which is where `launchctl`, `cfprefsd` and the log directory live.
///
/// Deliberately NOT a container: these tools act on the machine the developer is sitting at, and
/// a redirected `HOME` here would install the agent somewhere `launchd` never looks.
#[must_use]
pub fn home() -> PathBuf {
    std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from)
}

/// `~/Library/Logs/SlopDesk`, made — where every daemon this family starts writes.
///
/// # Errors
/// When the directory cannot be made.
pub fn log_dir() -> Result<PathBuf, String> {
    let directory = home().join("Library/Logs/SlopDesk");
    fs::create_dir_all(&directory).map_err(|error| format!("{}: {error}", directory.display()))?;
    Ok(directory)
}

/// One line of narration, prefixed by the tool that is speaking.
pub fn say(tool: &str, what: &str) {
    println!("{tool}: {what}");
}

/// The two client apps whose `.xcodeproj` is generated, by the name the CLI spells.
///
/// A table rather than two verbs, for the same reason [`launchd`]'s agents are one: the pair
/// differs in a path and in nothing else, and the shell's answer to that was a second 170-line
/// file.
const SPECS: &[(&str, &str)] = &[
    ("macos", "Apps/ClientApp-macOS/project.yml"),
    ("ios", "Apps/ClientApp-iOS/project.yml"),
];

/// The spec a target name selects, relative to the repo root.
///
/// # Errors
/// When the name is neither of the two.
pub fn spec_for(name: &str) -> Result<&'static str, String> {
    SPECS
        .iter()
        .find(|(known, _)| *known == name)
        .map(|(_, spec)| *spec)
        .ok_or_else(|| format!("unknown app: {name} (macos | ios)"))
}

/// Regenerate a spec's `.xcodeproj`, with `xcodegen`'s own chatter swallowed.
///
/// Two callers, and they are shared rather than each spawning their own because they must agree on
/// what "generated" means: the `regenerate` verb, and [`crate::gui`]'s `build_app`, which every GUI
/// gate goes through. A generated project that has drifted from its spec fails to build with no
/// hint at the cause — the failure names a missing FILE, never the stale `.xcodeproj` that still
/// lists it — so both regenerate before they build rather than trusting what the last run left.
///
/// [`crate::release`] deliberately does NOT come through here: it spawns `xcodegen --quiet` under
/// its own `proc::run`, so every command a release issues appears in the release's own step log.
/// That is one narrative a caller should not be able to opt out of.
///
/// # Errors
/// When `xcodegen` is missing or fails.
pub fn xcodegen(root: &Path, spec: &Path) -> Result<(), String> {
    if !proc::on_path("xcodegen") {
        return Err("xcodegen not found on PATH (install: brew install xcodegen)".to_owned());
    }
    say("xcodegen", &format!("generate --spec {}", spec.display()));
    let status = Command::new("xcodegen")
        .args(["generate", "--spec", &spec.to_string_lossy()])
        .current_dir(root)
        .stdout(std::process::Stdio::null())
        .status()
        .map_err(|error| format!("xcodegen: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("xcodegen exited {}", status.code().unwrap_or(-1)))
    }
}

#[cfg(test)]
mod tests {
    /// All four variables, and the two sub-directories actually made.
    #[test]
    fn a_container_names_four_directories_and_creates_them() {
        let root = std::env::temp_dir().join(format!("slopdesk-ops-container-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let pairs = super::container(&root).expect("the container is creatable");

        let names: Vec<&str> = pairs.iter().map(|(key, _)| key.as_str()).collect();
        assert_eq!(names, [
            "SLOPDESK_APP_SUPPORT_DIR",
            "SLOPDESK_SCROLLBACK_DIR",
            "SLOPDESK_FILE_DROP_DIR",
            "SLOPDESK_WORKSPACE_STATE_DIR"
        ]);
        assert!(root.join("scrollback").is_dir(), "the journal directory is made");
        assert!(root.join("drop").is_dir(), "the file-drop directory is made");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Both app names resolve, and a third is refused rather than guessed at.
    #[test]
    fn only_the_two_apps_that_exist_resolve() {
        assert_eq!(
            super::spec_for("macos").expect("macos"),
            "Apps/ClientApp-macOS/project.yml"
        );
        assert_eq!(
            super::spec_for("ios").expect("ios"),
            "Apps/ClientApp-iOS/project.yml"
        );
        assert!(super::spec_for("tvos").is_err());
    }
}
