//! What a running `slopdesk-hostd` publishes about how it was started.
//!
//! ## Why this exists
//! `docs/51` made a hostd restart cheap: superd holds the panes, the child-facing sockets and the
//! panel backends, so stopping hostd costs a reconnect rather than the afternoon's work. What was
//! left was the ritual around it — find the process, hope `pkill` matched the right thing and only
//! the right thing, wait long enough, then retype the flags. A restart that is *technically* free
//! but *manually* fiddly still gets postponed, which is the behaviour the whole subsystem set out
//! to change. So hostd states its own launch and `slopdesk-ops restart-hostd` reads it. Nothing
//! parses `ps` output, guesses a port or infers a flag.
//!
//! ## Why the PROCESS writes it rather than whatever started it
//! Two fields cannot be known from outside. [`LaunchRecord::port`] is the port the listener
//! actually BOUND, which under `--port 0` is an OS-chosen ephemeral one that differs from what was
//! asked for; and [`LaunchRecord::environment`] is what this process actually resolved, which the
//! shell that launched it may no longer have. Anything a script reconstructed would be a second,
//! worse answer.
//!
//! That is also why [`current`] takes only TWO arguments. The bound port and the build version are
//! the daemon's to tell; the pid, the argv, the cwd, the environment and the executable are the
//! PROCESS's, and asking the process directly is both shorter and impossible to get wrong across a
//! language boundary.
//!
//! ## Not a pid path
//! The pid is CONTENT here, re-read on every use and never baked into a name a child remembers —
//! the distinction `docs/51` §1 turns on. The file's own name is fixed, one per container.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::{env, fs};

use serde::{Deserialize, Serialize};

use crate::stamp;

/// The variable that moves the whole container. Set it and no file below can reach the real one.
pub const APP_SUPPORT_DIR_ENV: &str = "SLOPDESK_APP_SUPPORT_DIR";

/// The container's own name inside whatever base holds it.
pub const CONTAINER_NAME: &str = "SlopDesk";

/// The record's file name, fixed, one per container.
pub const FILE_NAME: &str = "hostd-launch.json";

/// The prefix that decides which variables are CONFIGURATION and which are the launching shell's
/// business.
///
/// The filter is also what keeps this file safe to read: `SlopDesk` has no app-layer credentials
/// (`CLAUDE.md` — security is the `WireGuard` mesh), so a `SLOPDESK_*` value is configuration and
/// nothing else lands here.
const CONFIG_PREFIX: &str = "SLOPDESK_";

/// What a report field says when the record did not carry it.
fn unknown() -> String {
    "?".to_owned()
}

/// The launch a running hostd published for itself.
///
/// The fields are declared in the order their JSON keys SORT, which is not cosmetic: the Swift
/// original encoded with `.sortedKeys` because a person reads this file to answer "what flags is my
/// host running?", and `serde` emits declaration order. Declaring them sorted is what keeps the
/// port from quietly reordering a document somebody greps.
///
/// The four REQUIRED fields are the four a restart cannot proceed without; the rest carry
/// `#[serde(default)]` because they are report-only, and refusing to read a record over a missing
/// version string would turn a cosmetic gap into "there is no hostd". That split is the reader's
/// contract, not a convenience — a missing `pid` is an error, never a zero, because signalling pid
/// 0 signals a process GROUP.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchRecord {
    /// `argv` after `argv[0]`.
    #[serde(default)]
    pub arguments: Vec<String>,
    /// The absolute, symlink-free path of the binary that is running.
    ///
    /// A `.build/debug` and a `.build/release` hostd are different daemons and a restart must not
    /// silently swap one for the other. Symlinks are resolved because the identity check on the
    /// other side needs an exact match: `.build/release` is a symlink to
    /// `.build/arm64-apple-macosx/release`, and `lsof -d txt` — the only way to ask what pid N is
    /// actually running — reports the physical path. Two spellings of one file would read as two
    /// different daemons.
    pub binary: PathBuf,
    /// The `SLOPDESK_*` variables this process resolved, and only those.
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    /// The running daemon's pid. Content, deliberately — see the module note.
    pub pid: i32,
    /// The port the listener actually BOUND, which `--port 0` makes different from the request.
    pub port: u16,
    /// ISO-8601, UTC. A string rather than an instant so the file reads the same to a person and to
    /// `jq`, and so no decoding strategy has to be agreed with whatever reads it next.
    #[serde(default = "unknown")]
    pub started_at: String,
    /// The daemon's build version at launch, so a restart can report what changed.
    #[serde(default = "unknown")]
    pub version: String,
    /// The daemon's cwd, because a relative `--transcript` resolves against it.
    pub working_directory: PathBuf,
}

impl LaunchRecord {
    /// The record as the bytes that go on disk: pretty, and key-sorted by construction.
    ///
    /// # Errors
    /// Only if a field will not serialise, which no field here can.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// Write the record, creating the container if it is not there yet.
    ///
    /// Best-effort by design, and the `bool` says so: a host that cannot write this file is a host
    /// that still serves every client. Losing it costs one convenience — the restart path falls
    /// back to asking.
    ///
    /// The write is ATOMIC via a same-directory temporary and a rename, because the restart path
    /// may read this at any moment and half a JSON object is worse than none: it reads as a corrupt
    /// record rather than as an absent one.
    #[must_use]
    pub fn write(&self, path: &Path) -> bool {
        let Ok(json) = self.to_json() else { return false };
        if let Some(parent) = path.parent() {
            drop(fs::create_dir_all(parent));
        }
        let staging = path.with_extension("json.tmp");
        if fs::write(&staging, json).is_err() {
            return false;
        }
        if fs::rename(&staging, path).is_err() {
            drop(fs::remove_file(&staging));
            return false;
        }
        true
    }
}

/// Read a record from JSON text.
///
/// # Errors
/// When the text is not JSON, or a required field is missing or of the wrong shape.
pub fn parse(text: &str) -> Result<LaunchRecord, String> {
    serde_json::from_str(text).map_err(|error| format!("launch record is not readable: {error}"))
}

/// Read the record at `path`, or `None` when it is absent or unreadable.
#[must_use]
pub fn read(path: &Path) -> Option<LaunchRecord> {
    parse(&fs::read_to_string(path).ok()?).ok()
}

/// Delete the record.
///
/// Called on the orderly shutdown, so an absent file means "no hostd" and a present one whose pid
/// is gone means "hostd died badly" — two states worth telling apart.
pub fn remove(path: &Path) {
    drop(fs::remove_file(path));
}

/// The container every `SlopDesk` sidecar lands in: `override_dir` when it names one, else
/// [`CONTAINER_NAME`] inside `base`.
///
/// An EMPTY override is treated as unset: the shell idiom `FOO="${BAR}"` with `BAR` unset is the
/// usual way this variable arrives empty, and silently writing to `/` would be worse than writing
/// to the real container. The override is read FIRST, so a redirected run still answers on a
/// machine with no base at all — `None` means "nowhere to fall back to", never "the redirect was
/// ignored".
///
/// ## Why the base is a parameter
/// The callers resolve it differently and neither answer is right for the other. A daemon has
/// `HOME`. An app has Foundation's Application-Support URL, which `HOME` does NOT move — Core
/// Foundation reads the user's home from the account record unless `CFFIXED_USER_HOME` is set — so
/// an app that derived its base from `HOME` would keep writing to the developer's own container
/// while believing it had been redirected. That is a bug this repository has already paid for,
/// which is why the RULE lives here and the base does not.
#[must_use]
pub fn app_support_dir_in(base: Option<&Path>, override_dir: Option<&OsStr>) -> Option<PathBuf> {
    match override_dir {
        Some(dir) if !dir.is_empty() => Some(PathBuf::from(dir)),
        _ => Some(base?.join(CONTAINER_NAME)),
    }
}

/// The container for a process that resolves its base from `HOME` — every daemon in this tree.
///
/// `None` when there is neither an override nor a home directory to fall back to.
#[must_use]
pub fn app_support_dir() -> Option<PathBuf> {
    let base = env::var_os("HOME").map(|home| PathBuf::from(home).join("Library/Application Support"));
    app_support_dir_in(base.as_deref(), env::var_os(APP_SUPPORT_DIR_ENV).as_deref())
}

/// Where the record lives: `<Application Support>/SlopDesk/hostd-launch.json`.
///
/// One per container, so a test — or a second host on the same machine — gets its own without a
/// second name having to be invented.
#[must_use]
pub fn path() -> Option<PathBuf> {
    Some(app_support_dir()?.join(FILE_NAME))
}

/// Describe the CURRENT process, given the two facts only the daemon knows.
///
/// `bound_port` is the port the listener actually bound and `version` is the build string; the
/// other six fields are read off this process. See the module note for why that split is the whole
/// design rather than an ergonomic choice.
#[must_use]
pub fn current(bound_port: u16, version: &str) -> LaunchRecord {
    LaunchRecord {
        arguments: env::args_os()
            .skip(1)
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect(),
        binary: running_executable(),
        environment: config_variables(),
        // A pid does not fit `i32` only on a platform SlopDesk does not run on. `-1` rather than a
        // panic, and rather than `0`: it is not a pid anything will signal.
        pid: i32::try_from(std::process::id()).unwrap_or(-1),
        port: bound_port,
        started_at: stamp::now_iso8601(),
        version: version.to_owned(),
        working_directory: env::current_dir().unwrap_or_default(),
    }
}

/// The `SLOPDESK_*` subset of this process's environment.
///
/// `vars_os` rather than `vars`: the latter PANICS on a variable that is not UTF-8, and a daemon
/// must not fail to publish its launch because some unrelated variable in the shell that started it
/// held a stray byte. A non-UTF-8 `SLOPDESK_*` value is carried lossily, which is strictly more
/// than the alternative.
fn config_variables() -> BTreeMap<String, String> {
    env::vars_os()
        .filter_map(|(key, value)| {
            let key = key.to_string_lossy().into_owned();
            key.starts_with(CONFIG_PREFIX)
                .then(|| (key, value.to_string_lossy().into_owned()))
        })
        .collect()
}

/// The absolute, symlink-free path of the binary this process is running.
///
/// NOT `argv[0]`. That is whatever the caller typed — `.build/release/slopdesk-hostd` is the usual
/// spelling and a bare name found on `PATH` is another — and a restart from a different directory
/// would resolve it somewhere else or not at all. `current_exe` is the kernel's answer to the same
/// question (`_NSGetExecutablePath` on macOS) and cannot be wrong.
///
/// `argv[0]` remains the fallback, for a platform or a test where the dyld call declines.
fn running_executable() -> PathBuf {
    if let Ok(reported) = env::current_exe() {
        return reported.canonicalize().unwrap_or(reported);
    }
    let launched = env::args_os()
        .next()
        .map_or_else(|| PathBuf::from("slopdesk-hostd"), PathBuf::from);
    let absolute = if launched.is_absolute() {
        launched
    } else {
        env::current_dir().unwrap_or_default().join(launched)
    };
    absolute.canonicalize().unwrap_or(absolute)
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::collections::BTreeMap;
    use std::ffi::OsStr;
    use std::path::{Path, PathBuf};

    use super::{CONTAINER_NAME, LaunchRecord, app_support_dir_in, current, parse, path, read, remove};

    /// A record with the one shape that made the shell version reach for `jq @sh` + `eval`: an
    /// environment value holding a space and a quote.
    fn sample() -> LaunchRecord {
        LaunchRecord {
            arguments: vec![
                "--port".to_owned(),
                "7420".to_owned(),
                "--shell".to_owned(),
                "/bin/zsh".to_owned(),
            ],
            binary: PathBuf::from("/repo/.build/release/slopdesk-hostd"),
            environment: BTreeMap::from([
                ("SLOPDESK_SHELL_ARGS".to_owned(), "-l -c 'echo hi'".to_owned()),
                ("SLOPDESK_VIDEO_DEBUG".to_owned(), "1".to_owned()),
            ]),
            pid: 4242,
            port: 7420,
            started_at: "2026-08-24T00:00:00Z".to_owned(),
            version: "0.4.1".to_owned(),
            working_directory: PathBuf::from("/repo"),
        }
    }

    /// A scratch directory that removes itself, so a write test leaves nothing behind.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("slopdesk-hostlaunch-{name}"));
            drop(std::fs::remove_dir_all(&dir));
            std::fs::create_dir_all(&dir).expect("a scratch directory");
            Self(dir)
        }

        fn file(&self) -> PathBuf {
            self.0.join("hostd-launch.json")
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            drop(std::fs::remove_dir_all(&self.0));
        }
    }

    /// Every field survives the trip, including the environment value with a space and a quote in
    /// it — the case a naive split would corrupt.
    #[test]
    fn a_record_reads_back_field_for_field() {
        let scratch = Scratch::new("round-trip");
        let original = sample();
        assert!(original.write(&scratch.file()));
        assert_eq!(read(&scratch.file()), Some(original));
    }

    /// The KEY ORDER on disk, which is a property a person greps and not a formatting detail. The
    /// Swift original encoded `.sortedKeys` for exactly this; `serde` emits declaration order, so
    /// the fields are declared sorted and this is what says so.
    #[test]
    fn the_keys_are_written_in_sorted_order() {
        let json = sample().to_json().expect("a serialisable record");
        // Exactly two spaces, so a nested `SLOPDESK_*` key four deep is not read as a top-level one.
        let keys: Vec<&str> = json
            .lines()
            .filter_map(|line| line.strip_prefix("  \""))
            .filter_map(|rest| rest.split_once("\":"))
            .map(|(key, _)| key)
            .collect();
        assert_eq!(keys, [
            "arguments",
            "binary",
            "environment",
            "pid",
            "port",
            "startedAt",
            "version",
            "workingDirectory"
        ]);
        let mut sorted = keys.clone();
        sorted.sort_unstable();
        assert_eq!(keys, sorted, "declaration order stopped matching sorted order");
    }

    /// The four fields a restart cannot proceed without are REQUIRED, and the report-only ones are
    /// not. A record missing `pid` is an error rather than a zero: signalling pid 0 signals a
    /// group.
    #[test]
    fn the_required_fields_are_required_and_the_report_fields_are_not() {
        assert!(parse(r#"{"port": 1}"#).is_err());
        assert!(parse("not json at all").is_err());

        let bare = parse(r#"{"pid": 7, "port": 1, "binary": "/b", "workingDirectory": "/w"}"#)
            .expect("the four required fields are enough");
        assert_eq!(bare.version, "?");
        assert_eq!(bare.started_at, "?");
        assert!(bare.arguments.is_empty());
        assert!(bare.environment.is_empty());
    }

    /// An absent record reads as `None` rather than as an error, and a removed one goes back to
    /// absent — the two states `remove` exists to tell apart.
    #[test]
    fn an_absent_record_is_absent_and_a_removed_one_goes_back_to_it() {
        let scratch = Scratch::new("absent");
        assert_eq!(read(&scratch.file()), None);
        assert!(sample().write(&scratch.file()));
        assert!(read(&scratch.file()).is_some());
        remove(&scratch.file());
        assert_eq!(read(&scratch.file()), None);
        // Removing what is not there is not an error — the orderly shutdown runs unconditionally.
        remove(&scratch.file());
    }

    /// Corrupt bytes read as absent rather than as a half record, which is the failure the atomic
    /// write exists to prevent from ever being written in the first place.
    #[test]
    fn a_truncated_record_reads_as_no_record() {
        let scratch = Scratch::new("truncated");
        std::fs::write(scratch.file(), r#"{"pid": 4242, "port": 74"#).expect("a scratch write");
        assert_eq!(read(&scratch.file()), None);
    }

    /// The write leaves the staging file behind under no outcome — a `hostd-launch.json.tmp` in the
    /// container would be read by nothing and cleaned by nobody.
    #[test]
    fn the_atomic_write_leaves_no_staging_file() {
        let scratch = Scratch::new("staging");
        assert!(sample().write(&scratch.file()));
        let leftovers: Vec<_> = std::fs::read_dir(&scratch.0)
            .expect("a readable scratch directory")
            .filter_map(Result::ok)
            .map(|entry| entry.file_name())
            .filter(|name| name != "hostd-launch.json")
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    /// The six fields the PROCESS answers for itself, which is the half that does not cross the
    /// language boundary. The binary is the test runner here, not hostd, and that is the point:
    /// what is asserted is that the process was asked at all.
    #[test]
    fn the_current_process_answers_for_every_field_the_daemon_does_not() {
        let record = current(65_000, "0.0.0-test");
        assert_eq!(record.port, 65_000);
        assert_eq!(record.version, "0.0.0-test");
        assert_eq!(record.pid, i32::try_from(std::process::id()).expect("a pid"));
        assert!(record.binary.is_absolute(), "{:?}", record.binary);
        assert!(record.binary.is_file(), "{:?}", record.binary);
        assert_eq!(record.working_directory, std::env::current_dir().expect("a cwd"));
        assert_eq!(record.started_at.len(), 20, "{}", record.started_at);
        assert!(
            record.environment.keys().all(|key| key.starts_with("SLOPDESK_")),
            "a non-config variable was captured: {:?}",
            record.environment.keys().collect::<Vec<_>>()
        );
    }

    /// The container is the one the override names, and the file name inside it is fixed.
    #[test]
    fn the_record_path_ends_in_the_one_file_name() {
        let resolved = path().expect("a home or an override");
        assert!(resolved.ends_with("hostd-launch.json"), "{resolved:?}");
    }

    /// The override moves the WHOLE container, base or no base.
    #[test]
    fn the_override_names_the_container_outright() {
        let base = Path::new("/Users/nobody/Library/Application Support");
        assert_eq!(
            app_support_dir_in(Some(base), Some(OsStr::new("/tmp/slopdesk-gate-container"))),
            Some(PathBuf::from("/tmp/slopdesk-gate-container")),
        );
        assert_eq!(
            app_support_dir_in(None, Some(OsStr::new("/tmp/slopdesk-gate-container"))),
            Some(PathBuf::from("/tmp/slopdesk-gate-container")),
            "a redirected run answers even where the base could not be resolved",
        );
    }

    /// `FOO="${BAR}"` with `BAR` unset is how a shell hands over an empty value by accident.
    /// Writing to `/` would be a worse answer than writing to the real container.
    #[test]
    fn an_empty_override_is_unset() {
        let base = Path::new("/Users/nobody/Library/Application Support");
        assert_eq!(
            app_support_dir_in(Some(base), Some(OsStr::new(""))),
            Some(base.join("SlopDesk")),
        );
    }

    /// With nothing to redirect it, the container is the one name inside the base it was handed —
    /// and there is no container at all when neither was supplied.
    #[test]
    fn with_no_override_it_is_the_container_name_inside_the_base() {
        let base = Path::new("/Users/nobody/Library/Application Support");
        assert_eq!(
            app_support_dir_in(Some(base), None),
            Some(base.join(CONTAINER_NAME)),
        );
        assert_eq!(app_support_dir_in(None, None), None);
    }
}
