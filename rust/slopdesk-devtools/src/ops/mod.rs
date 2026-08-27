//! The operator harnesses: the things a developer runs BY HAND, on their own machine, on purpose.
//!
//! ## Where the line with [`crate::gates`] falls
//! A gate answers a yes/no about the tree and a `just` target runs it. Nothing here does. These
//! install a `LaunchAgent`, restart a live daemon, rewrite a generated `project.yml`, re-sync a
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
//! | `enable-macos-renderer.sh` · `enable-ios-renderer.sh` | [`renderer`] — one injector, two specs |
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
pub mod renderer;
pub mod soak;
pub mod videoinput;

use std::fs;
use std::path::{Path, PathBuf};

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
}
