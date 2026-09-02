//! The four RUNTIME gates that drive a real macOS window, and the substrate all four share.
//!
//! ## Where the line with [`crate::gates`] and [`crate::ops`] falls
//! [`crate::gates`] answers a yes/no about the TREE by spawning a toolchain, and `just check` runs
//! every one of them. Nothing here is in `just check` and nothing here can be: each needs an
//! unlocked Aqua login session, some need Screen-Recording or Accessibility TCC, and every one
//! opens windows on the developer's own display for a minute or more. They are gates by output —
//! the exit status IS the verdict, and each assertion is machine-checked rather than eyeballed —
//! and operator harnesses by cost. Run them by hand, after touching what they cover.
//!
//! | was | is | what only it can prove |
//! | --- | --- | --- |
//! | `check-macos.sh` | [`macos`] | the app builds, WINDOWS, mounts a scene; `--connect` types a command that EXECUTES |
//! | `check-video.sh` | [`video`] | capture → HEVC → UDP → decode → a Metal drawable |
//! | `check-multiclient.sh` | [`multiclient`] | two clients, one layout, a real menu gesture crossing between them |
//! | `check-launch-restore.sh` | [`launchrestore`] | the launch a USER performs — restore from disk, offer, reattach |
//!
//! ## Why they are one family and not four programs
//! The four shells shared a substrate they could not share: each spelled the throwaway container,
//! the `UserDefaults` suite and its removal, the SIGTERM-then-verify-then-SIGKILL reap, the
//! poll-an-observable loop and the pty-versus-helper child census in its own words, and the
//! comments admit it — three of them cite a fourth by name for a trap it hit first. Every one of
//! those is a function here, with the argument in ONE place and a test under it.
//!
//! ## What stopped being a dependency
//! `python3` (six heredocs: the scene count, the topology signature, the fixture reader, the
//! divergent-uuid rewrite, the crash-report summary and the child census — [`serde_json`] and
//! plain Rust now), `swiftc` (the window census is `rust/slopdesk-apple-cgwindow`'s own bin),
//! `awk`, `sed`, `xxd` and `comm`. `xcodegen`, `xcodebuild`, `swift`, `lsof`, `pgrep`,
//! `osascript`, `screencapture` and `defaults` stay — each is something a compiled program
//! genuinely cannot do itself, which is the line [`crate::proc`] already draws.
//!
//! ## The rules every launch in this family obeys, because a direct exec is a SECOND instance
//! - **`-ApplePersistenceIgnoreState YES`, always.** Launching the bundle binary on `AppKit`'s
//!   persistence path brings the app up with ZERO windows. No window ⇒ no scene ⇒ not one scene
//!   `.task` runs: no auto-connect, no control socket, no workspace document. The process sits in
//!   its run loop with no UI and no sockets, and every gate here would then assert nothing while
//!   printing green. (HW-confirmed 2026-07-28: with the flag, a window every time; without it, zero
//!   windows every time.)
//! - **The bundle BINARY, never `open`.** `LaunchServices` forwards no environment, and every seam
//!   these gates read is a `SLOPDESK_*` variable. `open` carries argv and has no flag that carries
//!   an environment, so an `open`-launched app is one no gate here can address.
//! - **A container and a throwaway defaults suite on every launch.** `CFFIXED_USER_HOME` moves
//!   `NSHomeDirectory()` and Application Support; it does NOT move `UserDefaults`, because cfprefsd
//!   resolves the account record whatever the environment says. So both are needed, and the suite
//!   is removed COMPLETELY on the way out — `defaults delete` empties the domain and leaves a
//!   42-byte plist, and the `XCTest` side of that same mistake put 55,003
//!   `slopdesk.tests.pid*.plist` files in this machine's `~/Library/Preferences`.
//!
//! [`crate::ops::container`] is the daemon half of the same rule, and these gates call it rather
//! than spelling the four variables again.

pub mod control;
pub mod launchrestore;
pub mod macos;
pub mod multiclient;
pub mod video;

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use std::{fs, thread};

use nix::sys::signal::{self, Signal};
use nix::unistd::{Pid, getsid};

use crate::proc;

/// The loopback port each gate's `slopdesk-hostd` binds.
///
/// One ledger, because the four ran back to back in a loop long before they were one program and a
/// shared port makes the second run of a pair fail to bind — with a message about an address in
/// use, three steps away from the gate that actually leaked it.
pub mod port {
    /// [`super::macos`]' `--connect` daemon.
    pub const MACOS: u16 = 47420;
    /// [`super::video`]'s TERMINAL daemon — the one that owns the workspace document.
    pub const VIDEO: u16 = 47421;
    /// [`super::multiclient`]'s single daemon, serving both instances.
    pub const MULTICLIENT: u16 = 47422;
    /// [`super::launchrestore`]'s daemon, which starts with no workspace of its own.
    pub const LAUNCH_RESTORE: u16 = 47423;
}

/// How long a daemon may take to honour its `SIGTERM` before [`reap`] stops asking, in
/// half-seconds.
///
/// `slopdesk-videohostd`'s own wedge watchdog force-exits at five seconds, so the window has to be
/// longer than that or the escalation would fire on a daemon that was about to stop by itself.
const REAP_PATIENCE: u32 = 16;

/// The interval every poll in this family waits between samples.
pub const TICK: Duration = Duration::from_millis(500);

/// Where superd puts its sockets — `slopdesk_superwire::DIRECTORY_ENV_KEY`, spelled out.
///
/// A literal rather than a path dependency for the reason this whole crate is its own workspace:
/// nothing here links anything that ships, and one `pub const` is not worth an edge into
/// `rust/Cargo.toml`'s profile. It is the same call [`crate::ops::container`] already makes for the
/// other four `SLOPDESK_*` container variables, and superd's `paths.rs` reads it back.
const SUPERD_DIRECTORY_ENV_KEY: &str = "SLOPDESK_SUPERD_DIR";

/// One line of narration, prefixed by the gate that is speaking.
#[expect(clippy::print_stdout, reason = "narration is stdout by convention")]
pub fn say(gate: &str, what: &str) {
    println!("==> [{gate}] {what}");
}

/// One line of narration on stderr — what a red run is read off.
#[expect(clippy::print_stderr, reason = "a red run is read off stderr")]
pub fn complain(what: &str) {
    eprintln!("{what}");
}

/// `<root>/.work/<name>`, made.
///
/// # Errors
/// When the directory cannot be made.
pub fn work_dir(root: &Path, name: &str) -> Result<PathBuf, String> {
    let work = root.join(".work").join(name);
    fs::create_dir_all(&work).map_err(|error| format!("{}: {error}", work.display()))?;
    Ok(work)
}

/// Empty a directory and make it again — the "FRESH per run" every gate needs.
///
/// Fresh is correctness here and not hygiene: `adoptWorkspace` answers `rejectedStale` against a
/// host that already has a workspace, so a reused state directory silently turns a cold-launch
/// claim into a relaunch claim, and a reused scrollback directory replays a previous run's
/// transcripts into a session that never had them.
///
/// # Errors
/// When the directory cannot be removed or made.
pub fn fresh(directory: &Path) -> Result<(), String> {
    let _ignored = fs::remove_dir_all(directory);
    fs::create_dir_all(directory).map_err(|error| format!("{}: {error}", directory.display()))
}

/// True while a process exists — `kill -0`, which asks the kernel and starts nothing.
#[must_use]
pub fn alive(pid: u32) -> bool {
    i32::try_from(pid).is_ok_and(|raw| signal::kill(Pid::from_raw(raw), None).is_ok())
}

/// SIGTERM, then VERIFY, then SIGKILL.
///
/// `kill` only ASKS. `slopdesk-videohostd` answers a termination signal with an orderly drain — bye
/// to every client, stop the `SCStream`, restore parked windows — and that drain can WEDGE on a
/// leaked continuation; its own watchdog force-exits five seconds later, which is long after a
/// shell would have returned to its caller. The run then LOOKS finished while `:9000` is still
/// bound, and the NEXT run's host fails to bind against a phantom. So wait for the process to
/// actually be gone, and escalate if it is not: a gate that leaves daemons behind costs more than
/// the one it just failed.
pub fn reap(pid: u32, name: &str) {
    let Ok(raw) = i32::try_from(pid) else { return };
    let target = Pid::from_raw(raw);
    if signal::kill(target, Signal::SIGTERM).is_err() {
        return; // already gone
    }
    for _ in 0..REAP_PATIENCE {
        if !alive(pid) {
            return;
        }
        thread::sleep(TICK);
    }
    complain(&format!(
        "==> {name} (pid {pid}) did not stop on SIGTERM — SIGKILL"
    ));
    let _ = signal::kill(target, Signal::SIGKILL);
}

/// `pkill -f` — free whatever a killed previous run left behind.
///
/// Every gate opens with one. A gate that assumes it is the first thing to run today asserts
/// against a daemon it did not start.
pub fn kill_matching(pattern: &str) {
    let _ignored = Command::new("/usr/bin/pkill")
        .args(["-f", pattern])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Poll an observable until it holds, or say what was waited for.
///
/// Every wait in this family is a real observable rather than a `sleep` long enough to usually
/// work, because a settle that is usually long enough is how a gate starts passing for the wrong
/// reason — and how it starts failing on a loaded machine for no reason at all.
///
/// # Errors
/// When `tries` samples pass without the condition holding.
pub fn poll<F>(what: &str, tries: u32, mut ready: F) -> Result<(), String>
where
    F: FnMut() -> bool,
{
    for _ in 0..tries {
        if ready() {
            return Ok(());
        }
        thread::sleep(TICK);
    }
    Err(format!("timed out waiting for {what}"))
}

/// A log file, read the way every gate reads one: by counting a line it knows.
#[derive(Debug, Clone)]
pub struct Log {
    /// Where the daemon or the app is writing.
    pub path: PathBuf,
}

impl Log {
    /// Name a log without creating it.
    #[must_use]
    pub const fn at(path: PathBuf) -> Self {
        Self { path }
    }

    /// Truncate it — a gate that counts CUMULATIVE lines must start from its own zero.
    ///
    /// # Errors
    /// When the file cannot be created.
    pub fn truncate(&self) -> Result<(), String> {
        fs::File::create(&self.path).map_err(|error| format!("{}: {error}", self.path.display()))?;
        Ok(())
    }

    /// Everything written so far, or the empty string if there is nothing yet.
    #[must_use]
    pub fn text(&self) -> String {
        fs::read_to_string(&self.path).unwrap_or_default()
    }

    /// How many lines contain `needle` — `grep -c`, without the subprocess or its exit-1-on-zero.
    #[must_use]
    pub fn count(&self, needle: &str) -> usize {
        self.text().lines().filter(|line| line.contains(needle)).count()
    }

    /// How many lines contain ALL of `needles`, in any order.
    ///
    /// The shape every claim in this family is actually made of, because a bare substring is not
    /// one. `workspace channel …` is also the prefix hostd uses for every REFUSAL on that channel,
    /// and `shell …` prefixes lines that are not an attach — so the needle has to be the pair.
    #[must_use]
    pub fn count_all(&self, needles: &[&str]) -> usize {
        self.text()
            .lines()
            .filter(|line| needles.iter().all(|needle| line.contains(needle)))
            .count()
    }

    /// Whether any line contains `needle`.
    #[must_use]
    pub fn has(&self, needle: &str) -> bool {
        self.text().contains(needle)
    }

    /// The last `lines` lines, for a failure that wants the tail rather than the file.
    #[must_use]
    pub fn tail(&self, lines: usize) -> String {
        let text = self.text();
        let all: Vec<&str> = text.lines().collect();
        all.split_at(all.len().saturating_sub(lines)).1.join("\n")
    }

    /// Dump it to stderr under a label, or say it is empty.
    ///
    /// Every failure path in these gates dumps the same evidence, so a red run never needs a second
    /// one to diagnose. Saying "empty or missing" rather than printing nothing is the half the
    /// shell got wrong first: `2> /dev/null >&2` applies left to right, so fd2 was already
    /// `/dev/null` by the time `>&2` cloned it, and three whole sections printed blank.
    pub fn dump(&self, label: &str, lines: usize) {
        complain(&format!("--- {label} ---"));
        let text = if lines > 0 { self.tail(lines) } else { self.text() };
        if text.trim().is_empty() {
            complain(&format!("(empty or missing: {})", self.path.display()));
        } else {
            complain(&text);
        }
    }
}

/// The throwaway `UserDefaults` suite one gate run writes into.
///
/// `CFFIXED_USER_HOME` moves Application Support and NOT `UserDefaults`: cfprefsd resolves the real
/// home whatever the environment says, which is the entire reason a suite is needed. Without one,
/// `AppConnection.recordRecentTarget` pushes `127.0.0.1:4742x` into the DEVELOPER's
/// `connection.recentTargets` on every connect — a five-slot recent-hosts menu, of which three were
/// measured to be gate ports before this existed.
///
/// It isolates READS too, which is a stronger guarantee than skipping the auto-reconnect: the MRU
/// `connectIfSavedTarget()` consults is now EMPTY rather than merely unread.
#[derive(Debug)]
pub struct Suite {
    /// The domain name, keyed by this process so two gates never share one.
    name: String,
}

impl Suite {
    /// Mint a suite for `gate`, and delete anything a killed previous run left under the name.
    #[must_use]
    pub fn for_gate(gate: &str) -> Self {
        let suite = Self {
            name: format!("slopdesk.gate.{gate}.{}", std::process::id()),
        };
        suite.remove();
        suite
    }

    /// The domain name, which is what `SLOPDESK_DEFAULTS_SUITE` carries.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Seed `firstLaunch.completed`, because an empty defaults domain is a FRESH INSTALL.
    ///
    /// `FirstLaunchModel.shouldPresent` is true whenever the flag is unset and no
    /// `SLOPDESK_AUTOCONNECT_*` makes `hasAutomationEnvironment()` true, and the guided sheet would
    /// then open over the very window a gate is about to photograph. Seeded on EVERY launch rather
    /// than only where it is load-bearing, so no gate's evidence depends on which environment
    /// variable happens to suppress the welcome sheet today.
    ///
    /// It has to be a typed Bool: an argv `-key YES` pair arrives as the STRING `"YES"`, which a
    /// `Defaults` Bool read does not accept, which is why the old argv spelling never did anything.
    ///
    /// # Errors
    /// When `defaults write` fails.
    pub fn seed_first_launch(&self) -> Result<(), String> {
        let status = Command::new("/usr/bin/defaults")
            .args(["write", &self.name, "firstLaunch.completed", "-bool", "YES"])
            .status()
            .map_err(|error| format!("defaults: {error}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("defaults write {} exited non-zero", self.name))
        }
    }

    /// Take the suite away COMPLETELY — the domain AND the file it lives in.
    ///
    /// `defaults delete` empties the domain and leaves a 42-byte plist behind, so a gate that stops
    /// there costs the developer one file per run. The home here is the DEVELOPER's, deliberately:
    /// cfprefsd resolved it whatever `CFFIXED_USER_HOME` said, so the plist is in their
    /// `Preferences` directory and nowhere else.
    pub fn remove(&self) {
        let _ignored = Command::new("/usr/bin/defaults")
            .args(["delete", &self.name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let plist = crate::ops::home().join(format!("Library/Preferences/{}.plist", self.name));
        let _ignored = fs::remove_file(plist);
    }
}

impl Drop for Suite {
    /// The app is killed by the gate's own cleanup, so its `atexit` suite removal never runs. This
    /// is the one that does, and it runs on the error paths too — which a trailing call would not.
    fn drop(&mut self) {
        self.remove();
    }
}

/// The client app bundle a gate builds and then execs.
#[derive(Debug, Clone)]
pub struct AppBundle {
    /// The binary inside the bundle — what every launch in this family runs directly.
    pub binary: PathBuf,
}

/// Generate the `.xcodeproj` from the committed spec and build the app, unsigned.
///
/// The build log goes to a FILE, not to `/dev/null`. It used to go to `/dev/null`, and the day the
/// app stopped building the gate said only `** BUILD FAILED **` with nothing above it — the actual
/// line was `error: Multiple commands produce …/module.modulemap`, and reading it took a hand-run
/// of the same invocation. A gate that knows why it failed and does not say is barely better than
/// one that does not run.
///
/// # Errors
/// When `xcodegen` or `xcodebuild` fails, naming the compiler's own words.
pub fn build_app(root: &Path, work: &Path, derived_data_name: &str) -> Result<AppBundle, String> {
    let spec = root.join("Apps/ClientApp-macOS/project.yml");
    let project = root.join("Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj");
    let derived = work.join(derived_data_name);
    crate::ops::xcodegen(root, &spec)?;

    let log = work.join("xcodebuild.log");
    let sink = fs::File::create(&log).map_err(|error| format!("{}: {error}", log.display()))?;
    let errors = sink
        .try_clone()
        .map_err(|error| format!("{}: {error}", log.display()))?;
    let status = Command::new("xcodebuild")
        .args([
            "-project",
            &project.to_string_lossy(),
            "-scheme",
            "ClientApp-macOS",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=arm64",
            "-derivedDataPath",
            &derived.to_string_lossy(),
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "build",
        ])
        .current_dir(root)
        .stdout(Stdio::from(sink))
        .stderr(Stdio::from(errors))
        .status()
        .map_err(|error| format!("xcodebuild: {error}"))?;
    if !status.success() {
        complain("==> FAIL: the app did not build. The compiler's own words:");
        let text = fs::read_to_string(&log).unwrap_or_default();
        let mut seen = std::collections::BTreeSet::new();
        for line in text.lines() {
            if line.contains("error: ") || line.contains("Multiple commands produce") {
                seen.insert(line.trim());
            }
        }
        for line in seen.iter().take(40) {
            complain(&format!("    {line}"));
        }
        return Err(format!("xcodebuild failed — full log: {}", log.display()));
    }
    Ok(AppBundle {
        binary: derived.join("Build/Products/Debug/SlopDesk.app/Contents/MacOS/SlopDesk"),
    })
}

/// `swift build --product <name>` at the repo root, quietly.
///
/// # Errors
/// When the build fails.
pub fn swift_build(root: &Path, product: &str) -> Result<(), String> {
    let status = Command::new("swift")
        .args(["build", "--product", product])
        .current_dir(root)
        .stdout(Stdio::null())
        .status()
        .map_err(|error| format!("swift: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("swift build --product {product} failed"))
    }
}

/// Where a debug `cargo build` puts the `slopdesk` CLI.
///
/// `rust/target/`, not `.build/`: the CLI process is a root workspace member since the port out of
/// Swift, so it shares the one cargo target directory with `slopdesk-ctl` and the rest.
#[must_use]
pub fn cli_binary(root: &Path) -> PathBuf {
    root.join("rust/target/debug/slopdesk")
}

/// `cargo build -p slopdesk-cli` from `rust/`, quietly, and where it landed.
///
/// The gates that drive a running app ask every question through this binary, so it is built by
/// name rather than assumed present — a gate that ran before the port would otherwise find the
/// stale `SwiftPM` one and answer about code this tree no longer contains.
///
/// # Errors
/// When the build fails.
pub fn build_cli(root: &Path) -> Result<PathBuf, String> {
    proc::run(
        "cargo",
        &["build", "--quiet", "-p", "slopdesk-cli"],
        &root.join("rust"),
    )?;
    Ok(cli_binary(root))
}

/// The window census, built if it is not there yet.
///
/// It lives in `rust/slopdesk-apple-cgwindow`, which is a workspace of its own linking the `objc2`
/// family — so it is SPAWNED, exactly as `lsof` and `osascript` are, rather than linked into a
/// gate binary that is `forbid(unsafe_code)`.
///
/// # Errors
/// When the census cannot be built.
pub fn window_census_binary(root: &Path) -> Result<PathBuf, String> {
    let crate_dir = root.join("rust/slopdesk-apple-cgwindow");
    let binary = crate_dir.join("target/release/window-census");
    if !binary.is_file() {
        proc::run(
            "cargo",
            &["build", "--release", "--quiet", "--bin", "window-census"],
            &crate_dir,
        )?;
    }
    Ok(binary)
}

/// How many real on-screen windows the `WindowServer` attributes to `pid`, and what it saw.
///
/// "The process is alive" is not "the app came up", and the two cheaper answers are lies in
/// independent ways — both HW-observed on this host. `slopdesk … windows --json` is answered off
/// `WorkspaceStore.tree.sessions`, a value the App's `init()` builds before any scene exists, so it
/// is a SESSION count with no window information in it; and the control socket does not carry the
/// claim either, because `ClientControlServer.start()` hands its listener to a detached thread that
/// nothing ever stops, so a bound socket outlives the scene. Proven red: with the app's window
/// CLOSED and the process still alive, `windows --json` answered 1 for as long as it ran while this
/// census answered 0.
#[must_use]
pub fn window_count(census: &Path, pid: u32) -> (u32, String) {
    let Ok(output) = Command::new(census).arg(pid.to_string()).output() else {
        return (0, "(the census could not be run)".to_owned());
    };
    let seen = String::from_utf8_lossy(&output.stderr).into_owned();
    let count = String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u32>()
        .unwrap_or(0);
    (count, seen)
}

/// One live child of a daemon, and whether it is a pane's shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaemonChild {
    /// The child's pid.
    pub pid: i32,
    /// True when the child is a session LEADER **running a login shell** — see [`daemon_children`]
    /// for why the second half of that is not redundant.
    pub pty: bool,
    /// `argv[0]` as `ps` reports it, kept from the SAMPLE so a dump names what the count counted.
    pub command: String,
}

/// Census `parent`'s live children, each labelled pty or helper.
///
/// ⚠️ `parent` IS SUPERD, NEVER HOSTD. superd forks and holds every pane (`docs/51` §1) — that is
/// the whole point of it — so hostd's own children are `slopdesk-screend` and a scattering of
/// transient probes, and a pty count taken of hostd is STRUCTURALLY zero. It was hostd here until
/// this was written, which is why every live-shell assertion in this family read 0 against a host
/// whose log said it had attached three shells. Each gate now starts a superd of its own
/// ([`Superd`]) and censuses THAT.
///
/// **A bare child count is wrong**, and it is what made two of these gates flaky — 2 of 8 runs red
/// on a clean tree, 3 of 3 under an `FSEvents` burst. The daemon forks non-PTY helpers as well as
/// shells: the TERM resolution runs `/usr/bin/infocmp`, `HostMetadataProbe` runs `/usr/bin/git` and
/// `/usr/sbin/lsof`, superd's shim probes `$ZDOTDIR` with a `--norcs` zsh. Each is a child for as
/// long as it lives, and one fires REPEATEDLY inside a watch window: a gate's own work directory is
/// under this repo, so the daemon's home is too, so a pane's project key resolves to slop-desk
/// itself — and appending to a log inside that repo is an `FSEvents` burst, which arms
/// `RepoStatusWatcher`'s debounced `git` probe. A settle cannot help: the helper is TRANSIENT, so a
/// count that catches one is red for a reason no amount of waiting addresses.
///
/// The first discriminator is what `PTYProcess` does and `Foundation.Process` does not: the shell
/// is forked with `login_tty(slave)`, i.e. `setsid()`, so it is a session leader —
/// `getsid(pid) == pid`. A `Process()` child gets its own process GROUP but stays in the daemon's
/// session, so it is not. Demonstrated with two children of one parent that are the SAME binary
/// (`/bin/sleep`), one spawned and one `forkpty`'d: `pgrep -P` counts 2, this counts 1 pty and
/// 1 helper.
///
/// The second one is needed only because the parent moved. A SERVICE pane — `code-server`,
/// `slopdesk-dropd`, `slopdesk-androidd` — is a pane like any other and therefore a session leader
/// on a pty of its own, so session-leadership alone counts 2 to 3 daemons as shells and every
/// `== panes` assertion fails from ABOVE. `argv[0]` separates them without a table to maintain:
/// superd `execve`s a service by absolute path and a pane's shell as a LOGIN shell, which is the
/// leading `-` on `-sh`. That is the same convention `getlogin`-era tooling has read for forty
/// years, and it is what `ps` prints.
#[must_use]
pub fn daemon_children(parent: u32) -> Vec<DaemonChild> {
    // `pgrep` exits 1 when it matches NOTHING, and the shell's `|| true` around it was load-bearing
    // rather than defensive: without it the single most important observation this can make — "the
    // daemon has no shells at all" — killed the run with no line saying why. Here a failed spawn
    // and an empty match are the same empty vector, which is the honest reading of both.
    let listing = Command::new("/usr/bin/pgrep")
        .args(["-P", &parent.to_string()])
        .stderr(Stdio::null())
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
        .unwrap_or_default();
    listing
        .lines()
        .filter_map(|line| line.trim().parse::<i32>().ok())
        .filter_map(|pid| {
            // A child that exited between the `pgrep` and this call is not live, and `getsid`
            // answering `ESRCH` is how that arrives — skipped, never counted as a helper.
            getsid(Some(Pid::from_raw(pid))).ok().map(|session| {
                let command = proc::ask(
                    "/bin/ps",
                    &["-o", "command=", "-p", &pid.to_string()],
                    Path::new("/"),
                )
                .unwrap_or_default()
                .trim()
                .to_owned();
                DaemonChild {
                    pty: is_pane_shell(session.as_raw() == pid, &command),
                    pid,
                    command,
                }
            })
        })
        .collect()
}

/// Both halves of the discriminator [`daemon_children`] states, as a value.
///
/// `session_leader` alone was the whole rule while the census was taken of hostd, where the only
/// leaders were shells. Taken of superd it also sees the SERVICE panes — `code-server`,
/// `slopdesk-dropd`, `slopdesk-androidd` — each a real pane on a real pty, and counting those makes
/// a three-pane layout answer 5. superd `execve`s a service by absolute path and a pane's shell as
/// a LOGIN shell, so `argv[0]`'s leading `-` separates them with no list of service names to keep
/// in step.
#[must_use]
fn is_pane_shell(session_leader: bool, command: &str) -> bool {
    session_leader && command.starts_with('-')
}

/// The pty pids out of ONE census sample, ascending.
///
/// Sorted so two samples taken at different moments compare as sets rather than as spawn orders.
#[must_use]
pub fn pty_pids(census: &[DaemonChild]) -> Vec<i32> {
    let mut pids: Vec<i32> = census
        .iter()
        .filter(|child| child.pty)
        .map(|child| child.pid)
        .collect();
    pids.sort_unstable();
    pids
}

/// What a census sample SAW — helpers included, labelled, named.
///
/// Takes the SAMPLE, never a fresh read: the helper that inflates a count lives for tens of
/// milliseconds, so a re-read prints a different set of children than the one the count was made
/// from. Three separate reds printed that self-contradiction and none of them named the culprit.
pub fn dump_children(census: &[DaemonChild]) {
    complain(
        "--- the children of the daemon this census read (pty = a shell, helper = git/lsof/infocmp/…) ---",
    );
    for child in census {
        complain(&format!(
            "    {} {} {}",
            child.pid,
            if child.pty { "pty" } else { "helper" },
            child.command
        ));
    }
}

/// Raise a process by unix id, best-effort.
///
/// BY PID, never by name. With two instances there are two processes called `SlopDesk`, and
/// `first process whose name is "SlopDesk"` picks whichever the window server happens to answer
/// with — so a name-matched raise photographs one client twice and calls it two.
///
/// Raised through System Events and never by `open`ing the bundle: `open` on an app that is ALREADY
/// running with zero windows makes `AppKit` RE-OPEN one, so a bring-to-front like that repairs the
/// exact failure a gate asserts, one line before the screenshot, and hands the human a picture of a
/// healthy window.
#[must_use]
pub fn raise(pid: u32) -> bool {
    Command::new("/usr/bin/osascript")
        .args([
            "-e",
            &format!(
                "tell application \"System Events\" to set frontmost of (first process whose unix id is \
                 {pid}) to true"
            ),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Whether System Events says `pid` is frontmost.
///
/// The menu bar belongs to the FRONTMOST app, so a gesture gate has to wait on this rather than
/// sleep through it: an app that is still coming forward has the other instance's menu bar, and the
/// click would drive the wrong client.
#[must_use]
pub fn is_frontmost(pid: u32) -> bool {
    proc::ask(
        "/usr/bin/osascript",
        &[
            "-e",
            &format!(
                "tell application \"System Events\" to get frontmost of (first process whose unix id is \
                 {pid})"
            ),
        ],
        Path::new("/"),
    )
    .is_some_and(|answer| answer.trim() == "true")
}

/// A full-screen grab, for the half of a gate a human reads.
pub fn screenshot(path: &Path) {
    let _ignored = Command::new("/usr/sbin/screencapture")
        .args(["-x", &path.to_string_lossy()])
        .stderr(Stdio::null())
        .status();
}

/// Whether anything holds a flow to `port` over `protocol` — `lsof`, which is the only thing that
/// knows.
#[must_use]
pub fn has_flow(args: &[&str]) -> bool {
    Command::new("/usr/sbin/lsof")
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Whether `pid` holds a UDP flow on `port`.
///
/// Asserted per-PID rather than by counting sockets on the port: the host's own bound socket lives
/// there too, so a total is not a per-client fact, and a count must not pass because ONE client
/// holds two flows.
#[must_use]
pub fn holds_udp(pid: u32, port: u16) -> bool {
    proc::ask(
        "/usr/sbin/lsof",
        &["-nP", "-iUDP", "-a", "-p", &pid.to_string()],
        Path::new("/"),
    )
    .is_some_and(|listing| listing.contains(&format!(":{port}")))
}

/// A `slopdesk-superd` private to ONE gate run, and the directory its sockets live in.
///
/// **Why a gate may not share the developer's superd.** superd is a `LaunchAgent`, held across
/// logins, and it owns every pane on the machine — including the ones the developer is typing in.
/// Three things follow, and all three were observed:
///
///  1. `launch-restore`'s fixture uses FIXED pane uuids (`1111…`, `2222…`, `3333…`), because the
///     `workspace.json` it seeds has to name them. A run that ends in `SIGKILL` — which is how
///     every one of these gates ends, by design — leaves those panes supervised, so the NEXT run's
///     first dial is answered `refused("pane 1111… is already supervised")` and the gate reports "0
///     shells" for a host that was never allowed to spawn one. Red for the life of the machine, and
///     green again only after a superd restart nobody would think to do.
///  2. Every run leaked its shells into the developer's daemon. Nine were parked there when this
///     was written, one per gate run since boot.
///  3. A pane census has to be taken of SOME superd, and "the one `pgrep` finds" is not an answer
///     on a machine with a real one running.
///
/// Owning the daemon answers all three: the registry starts empty, the leak is bounded by [`Drop`],
/// and the pid is known rather than searched for.
///
/// The socket directory is `/tmp/slopdesk-gate-<port>-sd`, keyed by the gate's own port so two
/// gates cannot collide, and SHORT because `sockaddr_un.sun_path` is 104 bytes on Darwin and
/// `bind(2)` truncates silently rather than failing — a work-directory path under this repo is
/// already 73 of them before the socket's own name.
#[derive(Debug)]
pub struct Superd {
    /// The running daemon.
    child: Child,
    /// `$SLOPDESK_SUPERD_DIR` — its control, hook and agent sockets, and its lock.
    directory: PathBuf,
    /// Where it is writing.
    pub log: Log,
}

impl Superd {
    /// Build and start a superd of this gate's own, and wait for its control socket.
    ///
    /// # Errors
    /// When the daemon cannot be built or spawned, or does not bind in time.
    pub fn start(root: &Path, work: &Path, port: u16) -> Result<Self, String> {
        let crate_dir = root.join("rust/slopdesk-superd");
        proc::run("cargo", &["build", "--release", "--quiet"], &crate_dir)?;
        let binary = crate_dir.join("target/release/slopdesk-superd");

        // The full RELEASE PATH, never the bare name: the developer's own superd is the same
        // binary under `~/Library/Application Support/SlopDesk/bin`, it holds every live pane on
        // this machine, and a `pkill slopdesk-superd` would take all of them down. The path is the
        // discriminator, and it is the only thing standing between a leaked gate daemon and that.
        kill_matching(&binary.display().to_string());
        thread::sleep(TICK);

        let directory = PathBuf::from(format!("/tmp/slopdesk-gate-{port}-sd"));
        fresh(&directory)?;

        let log = Log::at(work.join("superd.log"));
        log.truncate()?;
        let sink = fs::File::create(&log.path).map_err(|error| format!("{}: {error}", log.path.display()))?;
        let errors = sink
            .try_clone()
            .map_err(|error| format!("{}: {error}", log.path.display()))?;

        let child = Command::new(&binary)
            .env(SUPERD_DIRECTORY_ENV_KEY, &directory)
            .stdin(Stdio::null())
            .stdout(Stdio::from(sink))
            .stderr(Stdio::from(errors))
            .spawn()
            .map_err(|error| format!("slopdesk-superd: {error}"))?;
        let superd = Self {
            child,
            directory,
            log,
        };

        // The SOCKET, not the log line: hostd's first act is to connect to it, and a daemon that
        // has printed "listening" has not necessarily returned from `bind` yet.
        poll("slopdesk-superd to bind its control socket", 20, || {
            superd.socket().exists()
        })
        .inspect_err(|_| superd.log.dump("superd log", 0))?;
        Ok(superd)
    }

    /// The daemon's pid — what a PANE census is taken of.
    #[must_use]
    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    /// `$SLOPDESK_SUPERD_DIR`, for hostd's environment.
    #[must_use]
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// The control socket hostd dials.
    #[must_use]
    fn socket(&self) -> PathBuf {
        self.directory.join("slopdesk-superd.sock")
    }
}

impl Drop for Superd {
    fn drop(&mut self) {
        // SIGKILL, and NOT [`reap`]'s ask-then-escalate. superd's whole job is to outlive the thing
        // that signalled it — it is a `LaunchAgent` held across logins, and a hostd stopping is the
        // ordinary case it must survive — so it does not stop on SIGTERM and [`reap`] spends its
        // full eight-second patience finding that out, once per gate, under a line that reads like
        // a daemon misbehaving. Taking its panes down with it is precisely what is wanted here: a
        // shell that outlives the run is the leak this type exists to stop.
        if let Ok(raw) = i32::try_from(self.child.id()) {
            let _ = signal::kill(Pid::from_raw(raw), Signal::SIGKILL);
        }
        let _ignored = self.child.wait();
        let _ignored = fs::remove_dir_all(&self.directory);
    }
}

/// A `slopdesk-hostd` a gate started, with the container and the logs that go with it.
#[derive(Debug)]
pub struct Hostd {
    /// The running daemon.
    child: Child,
    /// The private supervisor this daemon's panes hang off. Declared AFTER `child` so it is
    /// dropped after it: hostd relinquishes to a superd that is still listening.
    superd: Superd,
    /// Where it is writing.
    pub log: Log,
}

impl Hostd {
    /// Start a `slopdesk-hostd` on `port`, contained, with a fresh workspace state directory.
    ///
    /// The container is not hygiene. An un-contained daemon sweeps the developer's scrollback
    /// journals to the newest 256 on its FIRST loop iteration — and the live-writer exemption is no
    /// protection, because it consults the SWEEPING process's own map, so a file the developer's
    /// live hostd holds an open fd on is unlinked underneath it. `HOME` moves none of that; it
    /// sandboxes the spawned shell's history file and nothing else. `CFFIXED_USER_HOME` is the
    /// wrong tool for a daemon even though it would move the paths: it also relocates the home a
    /// pane takes its default working directory from, and pointing a hostd at one made the
    /// launch-restore gate flake three runs in five.
    ///
    /// `--shell /bin/sh` rather than the developer's login zsh: superd's shell-integration shim
    /// points `HISTFILE` at the real `~/.zsh_history`, so a typed proof command would be appended
    /// there on every run.
    ///
    /// `--port` stays FIRST so the `pkill -f` pattern that frees a leaked daemon keeps matching.
    ///
    /// # Errors
    /// When the daemon cannot be spawned, or does not stay up long enough to bind its port.
    pub fn start(root: &Path, work: &Path, port: u16) -> Result<Self, String> {
        kill_matching(&format!("slopdesk-hostd --port {port}"));
        thread::sleep(TICK);

        let home = work.join("hostd-home");
        let state = work.join("hostd-state");
        let workspace = work.join("hostd-workspace");
        fresh(&state)?;
        fresh(&workspace)?;
        fs::create_dir_all(&home).map_err(|error| format!("{}: {error}", home.display()))?;
        let environment = crate::ops::container(&state)?;
        let superd = Superd::start(root, work, port)?;

        let log = Log::at(work.join("hostd.log"));
        log.truncate()?;
        let sink = fs::File::create(&log.path).map_err(|error| format!("{}: {error}", log.path.display()))?;
        let errors = sink
            .try_clone()
            .map_err(|error| format!("{}: {error}", log.path.display()))?;

        let mut command = Command::new(crate::hostbin::binary(root, false));
        command
            .args(["--port", &port.to_string(), "--shell", "/bin/sh"])
            .env("HOME", &home)
            // The workspace directory is the ONE container variable this overrides: the daemon's
            // document has to be its own, and `container` points every path at one state directory.
            .env("SLOPDESK_WORKSPACE_STATE_DIR", &workspace)
            // The fifth container variable, and the one `ops::container` cannot supply: it is
            // keyed to a SOCKET path, which has 103 bytes to live in, and the state directory it
            // builds the other four from is nowhere near short enough. See [`Superd`] for what
            // sharing the developer's supervisor costs.
            .env(SUPERD_DIRECTORY_ENV_KEY, superd.directory())
            .stdin(Stdio::null())
            .stdout(Stdio::from(sink))
            .stderr(Stdio::from(errors));
        for (key, value) in &environment {
            if key != "SLOPDESK_WORKSPACE_STATE_DIR" {
                command.env(key, value);
            }
        }
        let child = command
            .spawn()
            .map_err(|error| format!("slopdesk-hostd: {error}"))?;
        let hostd = Self { child, superd, log };

        let pid = hostd.pid();
        let bound = poll(&format!("slopdesk-hostd to bind :{port}"), 20, || {
            hostd.log.has(&format!(":{port}")) && hostd.log.has("listening on")
        });
        if bound.is_err() || !alive(pid) {
            hostd.log.dump("hostd log", 0);
            return Err(format!("slopdesk-hostd did not come up on :{port}"));
        }
        Ok(hostd)
    }

    /// The daemon's pid.
    #[must_use]
    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    /// The pid a PANE census is taken of — this run's private supervisor, NOT hostd. See
    /// [`daemon_children`].
    #[must_use]
    pub fn superd_pid(&self) -> u32 {
        self.superd.pid()
    }

    /// How many workspace-document channels the daemon has ACCEPTED.
    ///
    /// Matched on the accept word specifically. `workspace channel …` is also the prefix hostd uses
    /// for every refusal and error on that channel — `refused — already open`, `receive ended`,
    /// `malformed subscribe dropped`, `unknown verb dropped` — and the first of those is logged
    /// with no accept at all, so a substring match would print "accepted ✅" for a channel the host
    /// turned away.
    #[must_use]
    pub fn accepted_channels(&self) -> usize {
        self.log.count_all(&["workspace channel ", " accepted"])
    }

    /// How many shells the daemon has MINTED, cumulatively.
    ///
    /// `shell … attached` is the host's own line for giving a pane a PTY. Cumulative by design: a
    /// live-child count cannot see a pane that was materialized, dialled, torn down and re-dialled,
    /// and that churn is what several of these gates exist to catch.
    #[must_use]
    pub fn attached_shells(&self) -> usize {
        self.log.count_all(&["shell ", " attached"])
    }
}

impl Drop for Hostd {
    fn drop(&mut self) {
        reap(self.child.id(), "slopdesk-hostd");
        let _ignored = self.child.wait();
    }
}

/// The banner a gate closes with, so the artefacts a human reads are in one place.
#[must_use]
pub fn banner(lines: &[String]) -> String {
    let rule = "=".repeat(80);
    let mut out = format!("\n{rule}\n");
    for line in lines {
        let _ = writeln!(out, " {line}");
    }
    let _ = write!(out, "{rule}");
    out
}

#[cfg(test)]
mod tests {
    #![expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
    use std::path::PathBuf;

    /// The four gates hold four DIFFERENT ports. They ran back to back long before they were one
    /// program, and a shared port makes the second of a pair fail to bind with a message about an
    /// address in use, three steps from the gate that leaked it.
    #[test]
    fn no_two_gates_bind_the_same_port() {
        let ports = [
            super::port::MACOS,
            super::port::VIDEO,
            super::port::MULTICLIENT,
            super::port::LAUNCH_RESTORE,
        ];
        let unique: std::collections::BTreeSet<u16> = ports.iter().copied().collect();
        assert_eq!(unique.len(), ports.len(), "each gate binds a port of its own");
    }

    /// A log that is not there yet reads as empty rather than as a failure — a gate polls the
    /// daemon's log before the daemon has written its first line, every single run.
    #[test]
    fn a_log_that_does_not_exist_yet_counts_zero() {
        let log = super::Log::at(PathBuf::from("/nonexistent/slopdesk-gate.log"));
        assert_eq!(log.count("anything"), 0);
        assert!(!log.has("anything"));
        assert_eq!(log.tail(10), "");
    }

    /// `count` is `grep -c`: LINES that contain the needle, not occurrences of it.
    #[test]
    fn a_line_with_the_needle_twice_counts_once() {
        let root = std::env::temp_dir().join(format!("slopdesk-gui-log-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("the scratch directory is creatable");
        let path = root.join("hostd.log");
        std::fs::write(
            &path,
            "attached for pane A attached for pane B\nattached for pane C\nidle\n",
        )
        .expect("the log is writable");
        let log = super::Log::at(path);
        assert_eq!(log.count("attached for pane"), 2);
        assert_eq!(log.tail(1), "idle");
        let _ignored = std::fs::remove_dir_all(&root);
    }

    /// A census sample's pty pids come back ASCENDING, so two samples taken at different moments
    /// compare as sets — the launch-restore gate asserts phase B holds the very same shells as
    /// phase A, and a spawn-order comparison would fail on a reattach that is entirely correct.
    #[test]
    fn the_pty_pids_of_a_census_are_sorted_and_exclude_helpers() {
        let census = [
            child(900, true, "-sh"),
            child(100, false, "/usr/bin/git"),
            child(500, true, "-sh"),
        ];
        assert_eq!(super::pty_pids(&census), [500, 900]);
    }

    /// A SERVICE pane is a session leader on a pty of its own — `code-server` and `slopdesk-dropd`
    /// both are, verified with `ps -o sess` against a live superd — so leadership alone counts them
    /// as shells and every `== panes` assertion fails from ABOVE. The login-shell `-` tells them
    /// apart, and it is a rule with no table of service names to keep in step.
    #[test]
    fn a_service_pane_is_not_a_pane_shell() {
        assert!(super::is_pane_shell(true, "-sh"));
        assert!(!super::is_pane_shell(
            true,
            "/…/code-server/lib/node /…/code-server --auth none"
        ));
        assert!(!super::is_pane_shell(true, "/…/slopdesk-dropd --port 47425"));
        // A helper stays a helper whatever it is called: `git` is in the daemon's own session.
        assert!(!super::is_pane_shell(false, "-sh"));
    }

    /// The shape `daemon_children` builds, as a literal — `pty` is its verdict, not an input.
    fn child(pid: i32, pty: bool, command: &str) -> super::DaemonChild {
        super::DaemonChild {
            pid,
            pty,
            command: command.to_owned(),
        }
    }

    /// A suite names the gate AND this process, so two gates run back to back never share a domain
    /// — and a killed run's leftovers are deleted at mint time rather than inherited.
    #[test]
    fn a_suite_is_keyed_by_gate_and_process() {
        let suite = super::Suite::for_gate("unittest");
        assert!(suite.name().starts_with("slopdesk.gate.unittest."));
        assert!(suite.name().ends_with(&std::process::id().to_string()));
    }

    /// This process is alive and pid 0 is not a process a gate can wait on.
    #[test]
    fn liveness_is_read_off_the_kernel() {
        assert!(super::alive(std::process::id()));
        assert!(!super::alive(u32::MAX));
    }

    /// A poll that never comes true names WHAT was waited for. "timed out" alone is the least
    /// useful sentence a gate can print.
    #[test]
    fn a_poll_that_times_out_names_its_subject() {
        let waited = super::poll("the thing that never happens", 1, || false);
        assert_eq!(
            waited,
            Err("timed out waiting for the thing that never happens".to_owned())
        );
    }
}
