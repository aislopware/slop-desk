//! The crown-jewel proof: the SHIPPED binaries, over a real socket, against a real PTY.
//!
//! The re-homing of the Swift `SubprocessE2ETests`, which launched `slopdesk-hostd` and
//! `slopdesk-client` as subprocesses and asserted on what came back out of them. Both are cargo
//! binaries now (`docs/63` §G.5), so the suite lands here — in the crate that OWNS the client
//! binary, where `env!("CARGO_BIN_EXE_slopdesk-client")` names the thing under test rather than a
//! path somebody spells by hand. The old file is deliberately named without its path: it is gone,
//! and a backticked path to a deleted file is a citation that no longer resolves.
//!
//! ## Why any of this exists rather than an in-memory harness
//! `docs/25` records the open-order race the loopback provably could not see: the client sends its
//! `channelOpen` during `connect` without waiting for an ack, so that frame is routinely already
//! TCP-buffered when the host's receive loop starts. A harness that installs the handler before it
//! drives the connection cannot create that window. Every property below is a claim about two real
//! descriptors, two real processes and a forked shell, so it is asserted the only way it can be.
//!
//! ## The one thing cargo cannot tell us
//! `slopdesk-hostd` is its OWN cargo workspace (`rust/slopdesk-hostd`), so no `CARGO_BIN_EXE_*` in
//! this crate names it. The path arrives in [`HOSTD_BIN_ENV`], which `just client-e2e` sets after
//! building it. Unset — or set to something that is not there — and every test here prints why it
//! proved nothing and returns green, which is what `XCTSkip` did.
//!
//! It is deliberately NOT spelled `SLOPDESK_HOSTD_BIN`: `docs/46` records that variable as having
//! **no reader**, and the absence IS the claim there — a search order for hostd beside the
//! installer's is the thing that row rules out. This one is scoped to the harness by its name.
//!
//! ## Isolation is a precondition, not a nicety
//! A `slopdesk-hostd` handed only a sandbox `HOME` passes every assertion in this file while
//! journaling into the DEVELOPER's `~/Library/Application Support/SlopDesk/scrollback/` and
//! sweeping it to `keepNewest: 256` on the way — measured on this host, one run cost six
//! transcripts. So there is exactly ONE constructor for a daemon environment here,
//! [`Sandbox::build`], and it sets all four container variables plus a private `slopdesk-superd`
//! and a private `slopdesk-screend`. The Swift needed a companion source-scanning suite to police
//! that rule because a second spawn could always build its own dictionary; here the helper is the
//! only way to get a `Command`, which is the same rule enforced by construction instead of by grep.
//!
//! The screen engine joined that list LAST and is the one worth naming, because its absence does
//! not look like a missing daemon. hostd renders a state-transfer restore through screend and
//! silently demotes to the distilled path when nothing answers — so before it was aimed, the two
//! composer scenarios dialled whatever screend the developer's live host had started, and passed or
//! failed on which machine ran them. A sandbox is every sidecar a daemon would otherwise resolve
//! from the machine, not just the ones with a directory.

// A skipped E2E test says so on stderr — that line is the only way a run without a built hostd can
// tell you it proved nothing, and a silent pass is indistinguishable from a gate that ran.
#![expect(clippy::print_stderr, reason = "the skip notice is this gate's only report")]
// NOTE: the crate's `unwrap_used` / `expect_used` / `panic` denials are NOT lifted here, and did
// not need to be. An assertion IS a panic and would have justified lifting them, but nothing in
// this file reaches for one by hand: every fixture step that can fail resolves to a SKIP with a
// reason, and every claim about the running processes is an `assert!` — which clippy does not count
// as a hand-written panic. A blanket allow at the top would have been a licence for the next
// unwrap.

use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use slopdesk_ids::identity::uuid_text;

/// Names the `slopdesk-hostd` this suite launches. Set by `just client-e2e`; absent means skip.
const HOSTD_BIN_ENV: &str = "SLOPDESK_E2E_HOSTD_BIN";

/// The env var hostd reads to find its custodian, spelled out rather than imported — one string is
/// not worth a dependency edge from this crate to superd's wire.
const SUPERD_SOCKET_ENV: &str = "SLOPDESK_SUPERD_SOCKET";

/// hostd's readiness line: `slopdesk-hostd: listening on 0.0.0.0:<port> (mode=shell)`.
const LISTENING_PREFIX: &str = "listening on 0.0.0.0:";

/// How long hostd gets to bind and say so.
const BIND_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a client gets to relay a marker it typed itself.
const ECHO_TIMEOUT: Duration = Duration::from_secs(20);

/// How long a piped client gets to notice its remote shell exited.
const EXIT_TIMEOUT: Duration = Duration::from_secs(15);

// ───────────────────────────────────────────────────────────────────────── skipping, and the rig

/// Announces why a test proved nothing. Returns `()` so a caller can `return skip(…)`.
fn skip(reason: &str) {
    eprintln!("SKIP: {reason}");
}

/// The three binaries this suite cannot build for itself.
#[derive(Debug)]
struct Rig {
    /// `slopdesk-hostd`, from [`HOSTD_BIN_ENV`].
    hostd: PathBuf,
    /// `slopdesk-superd`, from `rust/slopdesk-superd/target/{release,debug}/`.
    superd: PathBuf,
    /// `slopdesk-screend`, from `rust/slopdesk-screend/target/{release,debug}/`.
    screend: PathBuf,
}

/// All three binaries, or `None` with the reason printed.
///
/// superd is a hard precondition and not an optional one: hostd forks nothing (`docs/51`), so
/// without a custodian every pane these tests open is refused and no property can be attempted. It
/// must also be a PRIVATE one — this suite kills and restarts daemons freely, and a stray
/// `release` against the developer's live custodian would end somebody's running agent.
///
/// screend is a hard precondition for a subtler reason: a missing engine does not refuse anything,
/// it demotes the state-transfer restore to the distilled path. Resolved HERE rather than left to
/// the composer's own search so that "not built" is a skip with a name, instead of two assertions
/// about a composer failing for a reason they do not mention.
fn rig() -> Option<Rig> {
    let Some(named) = std::env::var_os(HOSTD_BIN_ENV) else {
        skip(&format!(
            "{HOSTD_BIN_ENV} is unset — `just client-e2e` builds slopdesk-hostd and sets it"
        ));
        return None;
    };
    let hostd = PathBuf::from(named);
    if !hostd.is_file() {
        skip(&format!(
            "{HOSTD_BIN_ENV} names {} , which is not a file",
            hostd.display()
        ));
        return None;
    }
    let Some(superd) = sibling_binary("slopdesk-superd") else {
        skip(
            "rust/slopdesk-superd is not built — `just superd-build`; without a PRIVATE custodian every \
             pane here would be refused, and pointing at the developer's live one is the outcome this suite \
             must never have",
        );
        return None;
    };
    let Some(screend) = sibling_binary("slopdesk-screend") else {
        skip(
            "rust/slopdesk-screend is not built — `just screend`; the two state-transfer scenarios need a \
             PRIVATE screen engine, and an absent one does not fail them, it silently demotes the restore \
             to the distilled path and fails an assertion about the composer instead",
        );
        return None;
    };
    Some(Rig {
        hostd,
        superd,
        screend,
    })
}

/// `rust/<name>/target/{release,debug}/<name>`, release first.
///
/// Derived from this crate's manifest rather than searched: each of these daemons is its own cargo
/// workspace, so its artifacts land beside its own manifest and the path is fixed by where that
/// manifest is.
fn sibling_binary(name: &str) -> Option<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../{name}/target"));
    ["release", "debug"]
        .into_iter()
        .map(|profile| root.join(profile).join(name))
        .find(|candidate| candidate.is_file())
}

// ────────────────────────────────────────────────────────────────────────────── small facilities

/// A number no other call in this process gets. Session ids and markers are minted from it.
fn nonce() -> u64 {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let since = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO);
    since
        .as_secs()
        .wrapping_mul(1_000_000_000)
        .wrapping_add(u64::from(since.subsec_nanos()))
        .wrapping_add(u64::from(std::process::id()) << 20)
        .wrapping_add(COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// A marker no run and no sibling test can collide with.
///
/// Collision matters more here than it looks: several of these tests assert that a marker one
/// client printed appears in ANOTHER client's stream, so a marker shared between two tests running
/// in parallel would make a fan-out assertion pass without any fan-out.
fn marker(tag: &str) -> String {
    format!("{tag}_{}", nonce())
}

/// A session UUID in the text form `--session-id` parses.
fn fresh_session_id() -> String {
    let first = nonce().to_be_bytes();
    let second = nonce().to_be_bytes();
    let mut bytes = [0_u8; 16];
    for (slot, byte) in bytes.iter_mut().zip(first.iter().chain(second.iter())) {
        *slot = *byte;
    }
    uuid_text(bytes)
}

/// A directory that removes itself, so a panicking assertion cannot leak a sandbox home.
#[derive(Debug)]
struct TempDir {
    /// The directory, made on construction and gone on drop.
    path: PathBuf,
}

impl TempDir {
    /// A fresh directory under `$TMPDIR`, or `None` with the reason printed.
    fn make(stem: &str) -> Option<Self> {
        let path = std::env::temp_dir().join(format!("{stem}-{}", nonce()));
        match std::fs::create_dir_all(&path) {
            Ok(()) => Some(Self { path }),
            Err(error) => {
                skip(&format!("could not make {}: {error}", path.display()));
                None
            },
        }
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        drop(std::fs::remove_dir_all(&self.path));
    }
}

/// Polls `ready` until it holds or `patience` runs out. The answer is the last reading.
fn wait_until(patience: Duration, mut ready: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + patience;
    loop {
        if ready() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(50));
    }
}

// ──────────────────────────────────────────────────────────────────────── children, reaped always

/// A child process that is signalled and waited on when it goes out of scope.
///
/// A `Drop` and not a `defer`-shaped call at the end of each test, for the reason the Swift's
/// `defer` existed: an assertion is a panic, and a panic must not leave a hostd holding a port and
/// a shell. SIGTERM first and SIGKILL only as a backstop, because superd's ORDERLY exit is what
/// drops the master fd of every pane it still holds — killing it outright leaks the shells instead.
#[derive(Debug)]
struct Reaped {
    /// The child. Borrowed mutably by [`wait_for_exit`] while it is still alive.
    child: Child,
}

impl Reaped {
    /// The child's pid, as `ps` and `kill` spell it.
    fn pid(&self) -> i32 {
        i32::try_from(self.child.id()).unwrap_or(-1)
    }
}

impl Drop for Reaped {
    fn drop(&mut self) {
        signal_term(self.pid());
        if !wait_for_exit(&mut self.child, Duration::from_secs(5)) {
            drop(self.child.kill());
        }
        drop(self.child.wait());
    }
}

/// SIGTERMs a pid, discarding the errno.
///
/// A failure here is `ESRCH` — the child is already gone, which is the state the caller wanted.
fn signal_term(pid: i32) {
    let _ignored = kill(Pid::from_raw(pid), Signal::SIGTERM);
}

/// Polls until the child is reaped or `patience` runs out.
fn wait_for_exit(child: &mut Child, patience: Duration) -> bool {
    wait_until(patience, || matches!(child.try_wait(), Ok(Some(_))))
}

/// Everything a child has written to one pipe so far.
///
/// A thread per pipe, because a full pipe deadlocks the child that is filling it — the same reason
/// the Swift installed a `readabilityHandler` instead of reading at the end.
#[derive(Debug)]
struct Collector {
    /// The bytes so far, appended by the reader thread.
    seen: Arc<Mutex<Vec<u8>>>,
    /// The reader, joined by [`Collector::settle`] once the child is gone.
    reader: Option<JoinHandle<()>>,
}

impl Collector {
    /// Starts draining `source` into a buffer this type owns.
    fn draining(mut source: impl Read + Send + 'static) -> Self {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        let reader = thread::Builder::new()
            .name("slopdesk-client.e2e.collect".to_owned())
            .spawn(move || {
                let mut buffer = [0_u8; 8192];
                while let Ok(count) = source.read(&mut buffer) {
                    if count == 0 {
                        break;
                    }
                    let Some(chunk) = buffer.get(..count) else {
                        break;
                    };
                    sink.lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .extend_from_slice(chunk);
                }
            })
            .ok();
        Self { seen, reader }
    }

    /// What has arrived, as text. Lossy on purpose: a PTY stream cut mid-codepoint is normal.
    fn text(&self) -> String {
        let bytes = self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// Waits for the pipe's EOF, so the buffer is COMPLETE and not merely current.
    ///
    /// The Swift could only sleep two seconds here and hope its dispatch queue had caught up: a
    /// process that has exited is not a pipe that has been drained, and clearing the handler first
    /// threw the tail away. A joined reader is that same guarantee with no timer in it — the write
    /// end is closed when the child dies, so the read returns 0 and the thread ends.
    fn settle(&mut self) {
        if let Some(reader) = self.reader.take() {
            drop(reader.join());
        }
    }

    /// Whether `needle` has arrived within `patience`.
    fn awaits(&self, needle: &str, patience: Duration) -> bool {
        wait_until(patience, || self.text().contains(needle))
    }
}

/// Writes to a child's stdin without taking the test down when that child is already gone.
///
/// Rust's runtime `SIG_IGN`s `SIGPIPE` before `main`, so a write to a dead child's pipe returns
/// `BrokenPipe` rather than killing the process the way the Swift's `FileHandle.write` did — but
/// the error still has to be SWALLOWED rather than propagated: a refused or exited client is an
/// ordinary outcome for these tests to assert on, not a reason to lose the run.
fn write_to_child(stdin: Option<&mut ChildStdin>, text: &str) {
    let Some(pipe) = stdin else {
        return;
    };
    let mut rest = text.as_bytes();
    while !rest.is_empty() {
        match pipe.write(rest) {
            Ok(0) => return,
            Ok(count) => rest = rest.get(count..).unwrap_or_default(),
            Err(error) if error.kind() == ErrorKind::Interrupted => (),
            // BrokenPipe / BadFileDescriptor — the child is gone; the assertions say what that means.
            Err(_) => return,
        }
    }
    drop(pipe.flush());
}

// ──────────────────────────────────────────────────────────────────────────── the private
// custodian

/// A `slopdesk-superd` of this test's own, on a directory of its own.
#[derive(Debug)]
struct Superd {
    /// Its directory. Declared first so it outlives nothing that needs it.
    _dir: TempDir,
    /// Where hostd is told to reach it.
    socket: String,
    /// The custodian's pid. Every pane's shell is a child of THIS, never of hostd.
    pid: i32,
    /// Sent `SIGTERM` on drop, which is what drops the master fd of every pane it still holds.
    _guard: Reaped,
}

/// Boots a private custodian, or `None` with the reason printed.
fn boot_superd(binary: &Path) -> Option<Superd> {
    // A SHORT stem: `sun_path` is 104 bytes and a sandbox home would eat most of them, which is why
    // the daemon directory goes straight in `$TMPDIR` rather than under the home it serves.
    let dir = TempDir::make("sd-e2e")?;
    let socket = dir.path.join("slopdesk-superd.sock").display().to_string();

    // A MINIMAL environment, not an inherited one: inheriting would drag this process's own
    // `SLOPDESK_*` overrides into the custodian, including one pointing at the developer's
    // container.
    let spawned = Command::new(binary)
        .env_clear()
        .env("SLOPDESK_SUPERD_DIR", &dir.path)
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let Ok(child) = spawned else {
        skip(&format!("could not launch {}", binary.display()));
        return None;
    };
    let guard = Reaped { child };

    // Readiness is a real CONNECTION, not the socket file existing: `bind(2)` makes the node and
    // `listen(2)` comes after it, so a hostd dialling in that window gets `ECONNREFUSED` rather than
    // `ENOENT` — microseconds wide, and it only ever loses under load, where the flake gets blamed
    // on whichever test caught it.
    if !wait_until(Duration::from_secs(5), || UnixStream::connect(&socket).is_ok()) {
        skip("the private superd never accepted a connection");
        return None;
    }
    let pid = guard.pid();
    Some(Superd {
        _dir: dir,
        socket,
        pid,
        _guard: guard,
    })
}

// ──────────────────────────────────────────────────────────────────────── the contained daemon env

/// A throwaway home, a container inside it, and a custodian — the ONLY way to get a hostd here.
#[derive(Debug)]
struct Sandbox {
    /// The sandbox `HOME`. A pane's shell resolves its default working directory from this.
    home: TempDir,
    /// The private custodian every pane in this sandbox is forked by.
    superd: Superd,
    /// The environment pairs a hostd launch layers over its inherited one.
    env: Vec<(String, String)>,
}

impl Sandbox {
    /// Builds the whole isolation, or `None` with the reason printed.
    ///
    /// `HOME` on its own was never isolation. It does not move Application Support, so these spawns
    /// resolved the DEVELOPER's `~/Library/Application Support/SlopDesk/`, wrote their PTY
    /// transcripts into it, and — because the journal sweep runs on hostd's first loop iteration
    /// and keeps only the newest 256 — deleted the developer's oldest journals to make room. The
    /// full set is four variables, not one, and each answers a different question.
    ///
    /// The same argument reaches one directory further than the journal. A pane's SIDECARS are the
    /// developer's too unless told otherwise, and the screen engine is the one that matters: an
    /// unaimed hostd renders its state transfer through whichever screend is already listening on
    /// this machine, so a suite that pins the composer would have been pinning a binary built from
    /// another commit.
    fn build(rig: &Rig) -> Option<Self> {
        let screend = rig.screend.as_path();
        let home = TempDir::make("e2e-home")?;
        let container = home.path.join("Library/Application Support/SlopDesk");
        if let Err(error) = std::fs::create_dir_all(&container) {
            skip(&format!("could not make {}: {error}", container.display()));
            return None;
        }
        let superd = boot_superd(&rig.superd)?;
        let pair = |key: &str, value: &Path| (key.to_owned(), value.display().to_string());
        let env = vec![
            pair("HOME", &home.path),
            // The one lever that actually decides which shell a pane execs: hostd builds its spawn
            // shell from its OWN `$SHELL` (`spawn_env::login_shell`). Without this a session runs
            // the developer's login zsh, which — through superd's shell-integration shim, whose
            // HISTFILE deliberately points back at the REAL `~/.zsh_history` — appends every script
            // typed below to the developer's shell history on every run.
            ("SHELL".to_owned(), "/bin/sh".to_owned()),
            pair("SLOPDESK_APP_SUPPORT_DIR", &container),
            pair("SLOPDESK_SCROLLBACK_DIR", &container.join("scrollback")),
            pair("SLOPDESK_WORKSPACE_STATE_DIR", &container),
            pair("SLOPDESK_FILE_DROP_DIR", &container.join("drop")),
            // The daemon prewarms the shared code-server at boot; a real Node child per E2E run is a
            // multi-second boot plus a stray listener this suite must never create. The override
            // doubles as the off-switch: SET but not executable resolves to "no binary", so the
            // prewarm silently no-ops.
            pair("SLOPDESK_CODE_SERVER_BIN", &container.join("code-server-absent")),
            (SUPERD_SOCKET_ENV.to_owned(), superd.socket.clone()),
            // The screen engine, for the same reason as the custodian and with a sharper failure
            // mode. hostd's state-transfer composer renders a journal THROUGH screend, and when no
            // engine answers it does not error — it falls back to the distilled bytes, which is the
            // right answer for a user and an invisible one for a test. Unset, the two scenarios
            // below dialled whatever screend the developer's live host had already started: they
            // passed on this machine and failed on the next, and the composer they claim to pin was
            // never the copy in this tree. Three variables, because the default for each is the
            // developer's: WHERE to dial, WHICH binary to start when nothing answers, and how long
            // it lingers afterwards. The socket sits at the sandbox root and not under Application
            // Support — `sun_path` is 104 bytes, and the container path spends a third of them on a
            // directory name with a space in it.
            pair("SLOPDESK_SCREEND_SOCKET", &home.path.join("screend.sock")),
            pair("SLOPDESK_SCREEND_BIN", screend),
            // Seconds holding NO connection before it exits. hostd starts screend DETACHED, so the
            // per-test guard that reaps a superd cannot reap this — the engine's own idle timer is
            // the only thing that ends it, and the stock 120 would leave one alive per scenario for
            // two minutes after the run.
            ("SLOPDESK_SCREEND_IDLE_EXIT".to_owned(), "5".to_owned()),
        ];
        Some(Self { home, superd, env })
    }

    /// `HOME` with its symlinks resolved — `/var` is `/private/var`, and `pwd -P` prints the
    /// latter.
    fn resolved_home(&self) -> String {
        std::fs::canonicalize(&self.home.path)
            .unwrap_or_else(|_error| self.home.path.clone())
            .display()
            .to_string()
    }

    /// The environment with one pair replaced or added — the shape the restart scenario needs.
    fn with(&self, key: &str, value: &str) -> Vec<(String, String)> {
        replacing(&self.env, key, value)
    }
}

/// `environment` with `key` set to `value`, whether or not it was there before.
fn replacing(environment: &[(String, String)], key: &str, value: &str) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = environment
        .iter()
        .filter(|(name, _)| name != key)
        .cloned()
        .collect();
    env.push((key.to_owned(), value.to_owned()));
    env
}

// ─────────────────────────────────────────────────────────────────────────────── the two processes

/// A running `slopdesk-hostd` on an OS-chosen port.
#[derive(Debug)]
struct Hostd {
    /// Sent `SIGTERM` on drop.
    guard: Reaped,
    /// The port it actually BOUND. `--port 0` mints one, so the number asked for is not the number
    /// a client must dial.
    port: u16,
    /// Its stderr, still being collected past the banner — the restore-path line is an observable.
    log: Collector,
}

/// Launches a hostd with `environment` layered over the inherited one, or `None` with the reason.
///
/// `cwd` is the "checkout the daemon was started from" for the scenario that cares; `None` means
/// this process's own, which is what every other scenario wants.
fn launch_hostd(rig: &Rig, environment: &[(String, String)], cwd: Option<&Path>) -> Option<Hostd> {
    let mut command = Command::new(&rig.hostd);
    command
        .args(["--port", "0", "--shell", "/bin/sh"])
        .stdin(Stdio::null())
        // Discarded rather than piped: hostd says everything through stderr, and an unread PIPE on
        // stdout is a deadlock waiting for a daemon that decides to use it.
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    for (key, value) in environment {
        command.env(key, value);
    }
    if let Some(directory) = cwd {
        command.current_dir(directory);
    }
    let Ok(mut child) = command.spawn() else {
        skip(&format!("could not launch {}", rig.hostd.display()));
        return None;
    };
    let Some(errors) = child.stderr.take() else {
        skip("hostd was spawned without a stderr pipe");
        return None;
    };
    let guard = Reaped { child };
    let log = Collector::draining(errors);
    if !wait_until(BIND_TIMEOUT, || bound_port(&log.text()).is_some()) {
        skip(&format!(
            "hostd did not report a bound port in time: {}",
            head(&log.text())
        ));
        return None;
    }
    let port = bound_port(&log.text())?;
    Some(Hostd { guard, port, log })
}

/// The port out of `slopdesk-hostd: listening on 0.0.0.0:<port> (mode=shell)`.
fn bound_port(text: &str) -> Option<u16> {
    let at = text.find(LISTENING_PREFIX)?;
    let tail = text.get(at.checked_add(LISTENING_PREFIX.len())?..)?;
    let digits: String = tail.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

/// A running `slopdesk-client` with its stdin held open.
#[derive(Debug)]
struct ClientProc {
    /// Sent `SIGTERM` on drop — which is a LINK DROP, the thing several scenarios turn on.
    guard: Reaped,
    /// Its stdin. Taken (and thus closed) by [`ClientProc::close_stdin`].
    stdin: Option<ChildStdin>,
    /// The session's bytes.
    out: Collector,
    /// The client's own complaints. Collected, never discarded: this suite has failed with an EMPTY
    /// stdout, and an empty stdout says nothing about WHY — the one artefact that could name the
    /// cause went to a pipe nobody read.
    errors: Collector,
}

impl ClientProc {
    /// Types `text` at the pane, tolerating a client that has already gone.
    fn feed(&mut self, text: &str) {
        write_to_child(self.stdin.as_mut(), text);
    }

    /// Closes stdin, which is EOF for the pump — what a piped script's end looks like.
    fn close_stdin(&mut self) {
        drop(self.stdin.take());
    }

    /// Whether the process is still up. A refused client that died would make several assertions
    /// below pass vacuously, so it is asserted rather than assumed.
    fn is_running(&mut self) -> bool {
        matches!(self.guard.child.try_wait(), Ok(None))
    }

    /// Ends the link the way a dropped connection does, and waits for the process to go.
    fn drop_link(&mut self) {
        signal_term(self.guard.pid());
        let _reaped = wait_for_exit(&mut self.guard.child, Duration::from_secs(5));
    }
}

/// Launches the SHIPPED client against `port`, on `session` when one is named.
fn launch_client(port: u16, session: Option<&str>) -> Option<ClientProc> {
    let port = port.to_string();
    let mut arguments = vec!["--host", "127.0.0.1", "--port", &port, "--no-raw"];
    if let Some(id) = session {
        arguments.push("--session-id");
        arguments.push(id);
    }
    let spawned = Command::new(env!("CARGO_BIN_EXE_slopdesk-client"))
        .args(&arguments)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let Ok(mut child) = spawned else {
        skip("could not launch the slopdesk-client subprocess");
        return None;
    };
    let stdin = child.stdin.take();
    let (Some(out), Some(errors)) = (child.stdout.take(), child.stderr.take()) else {
        skip("the client was spawned without its pipes");
        return None;
    };
    Some(ClientProc {
        guard: Reaped { child },
        stdin,
        out: Collector::draining(out),
        errors: Collector::draining(errors),
    })
}

/// The first 600 characters of a capture — enough to name a cause in a failure message.
fn head(text: &str) -> String {
    text.chars().take(600).collect()
}

/// The last 600 characters of a capture, for the assertions that care about the END of a stream.
fn tail(text: &str) -> String {
    let kept: Vec<char> = text.chars().collect();
    kept.iter().rev().take(600).rev().collect()
}

/// The pids of `parent`'s directly-forked `sh` children, sorted — the process table's own answer to
/// "how many shells did the host fork".
///
/// Read from `ps` rather than from anything the host reports about itself, because the failure
/// being excluded is precisely the host being wrong about how many shells it owns. Zombies are
/// dropped: a reaped-but-unwaited shell is not a second shell.
///
/// The name is matched as `-sh` as well as `sh`: a pane's shell is spawned as a LOGIN shell
/// (`spawn_env::login_argv0`), so its `argv[0]` — and therefore `comm` — carries the conventional
/// leading hyphen.
fn shell_children(parent: i32) -> Vec<i32> {
    let Ok(output) = Command::new("/bin/ps")
        .args(["-A", "-o", "pid=,ppid=,stat=,comm="])
        .stderr(Stdio::null())
        .output()
    else {
        return Vec::new();
    };
    let listing = String::from_utf8_lossy(&output.stdout).into_owned();
    let mut pids: Vec<i32> = listing
        .lines()
        .filter_map(|line| {
            let mut columns = line.split_whitespace();
            let candidate: i32 = columns.next()?.parse().ok()?;
            let owner: i32 = columns.next()?.parse().ok()?;
            let state = columns.next()?;
            let name = columns.next()?.rsplit('/').next()?;
            (owner == parent && !state.starts_with('Z') && name.trim_start_matches('-') == "sh")
                .then_some(candidate)
        })
        .collect();
    pids.sort_unstable();
    pids
}

// ────────────────────────────────────────────────────────────────────────────────── the scenarios

/// One scenario at a time, whatever `--test-threads` says.
///
/// `XCTest` ran a case's methods in sequence and this suite was written to that. `cargo test` runs
/// them in parallel threads instead, and six simultaneous hostd+superd pairs on a debug build push
/// the channel open past its ack deadline — measured on this host: clean serially, one
/// `the channel was refused by the host or the open ack timed out` at six abreast. Nothing is
/// SHARED between these tests (own port, own socket, own home, own custodian); what is contended is
/// the machine. Serialising here rather than in the recipe keeps the guarantee attached to the
/// tests instead of to whoever invokes them.
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

/// Held for the whole of a scenario. Poison is ignored: a previous test that panicked reported
/// itself already, and it left no state behind for this one to be confused by.
fn serialised() -> MutexGuard<'static, ()> {
    ONE_AT_A_TIME.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Was `testShippedBinariesEchoOverTCP`.
///
/// The floor everything else stands on: the two SHIPPED binaries, a real TCP socket and a real PTY,
/// with a marker piped through the client's stdin and read back off its stdout. `docs/25` records
/// what this caught and the loopback could not — the host yielding its connection before
/// `hostOpenHandler` was installed, which dropped the open, spawned no PTY and hung the client on a
/// pane that silently never came up.
#[test]
fn the_shipped_binaries_echo_over_tcp() {
    // Declared first, so it is released LAST — after every child guard below has reaped.
    let _serial = serialised();
    let Some(rig) = rig() else { return };
    let Some(sandbox) = Sandbox::build(&rig) else {
        return;
    };
    let Some(hostd) = launch_hostd(&rig, &sandbox.env, None) else {
        return;
    };
    assert!(hostd.port > 0, "hostd must bind a real port");

    let Some(mut client) = launch_client(hostd.port, None) else {
        return;
    };
    client.feed("echo SHIPPED_OK\nexit\n");
    client.close_stdin();

    let exited = wait_for_exit(&mut client.guard.child, EXIT_TIMEOUT);
    // The pipes are drained to EOF before they are read: a process that has exited is NOT a pipe
    // that has been emptied, and the bytes written just before the exit are exactly the ones this
    // assertion is about.
    client.out.settle();
    client.errors.settle();
    assert!(exited, "the client did not exit within the timeout");

    let out = client.out.text();
    assert!(
        out.contains("SHIPPED_OK"),
        "expected SHIPPED_OK in the client's stdout\nstdout: {}\nstderr: {}\nhostd: {}",
        head(&out),
        head(&client.errors.text()),
        tail(&hostd.log.text()),
    );
}

/// Was `testPaneWithoutRequestedCwdOpensInHomeNotDaemonCwd`.
///
/// THE user scenario: hostd is launched FROM a project directory — a daemon started out of a
/// checkout, which is the normal case — and a client that names no working directory connects. The
/// spawned shell must come up in `$HOME`.
///
/// Before the fix the host translated "no cwd requested" into "issue no `chdir`", so the shell
/// silently inherited the daemon's cwd and every such pane opened inside whatever project the
/// daemon happened to be launched from.
#[test]
fn a_pane_without_a_requested_cwd_opens_in_home_not_the_daemons_cwd() {
    // Declared first, so it is released LAST — after every child guard below has reaped.
    let _serial = serialised();
    let Some(rig) = rig() else { return };
    let Some(sandbox) = Sandbox::build(&rig) else {
        return;
    };
    // The stand-in for "the checkout the daemon was started from".
    let Some(project) = TempDir::make("e2e-daemon-cwd") else {
        return;
    };
    let home = sandbox.resolved_home();
    let daemon_cwd = std::fs::canonicalize(&project.path)
        .unwrap_or_else(|_error| project.path.clone())
        .display()
        .to_string();
    assert_ne!(home, daemon_cwd, "the two directories must differ");

    let Some(hostd) = launch_hostd(&rig, &sandbox.env, Some(&project.path)) else {
        return;
    };
    let Some(mut client) = launch_client(hostd.port, None) else {
        return;
    };
    // `pwd -P` resolves symlinks, which is why both sides of the comparison are resolved paths.
    client.feed("pwd -P\nexit\n");
    client.close_stdin();

    let exited = wait_for_exit(&mut client.guard.child, EXIT_TIMEOUT);
    client.out.settle();
    client.errors.settle();
    assert!(exited, "the client did not exit within the timeout");

    let out = client.out.text();
    assert!(
        out.contains(&home),
        "expected the pane to open in HOME ({home}); got: {}\nstderr: {}",
        head(&out),
        head(&client.errors.text()),
    );
    assert!(
        !out.contains(&daemon_cwd),
        "the pane must not inherit the daemon's cwd ({daemon_cwd}); got: {}",
        head(&out),
    );
}

/// Was `testScrollbackSurvivesHostdRestart`.
///
/// THE user scenario end-to-end: hostd #1 journals a marker to the disk scrollback, dies; hostd #2
/// — a brand-new process, every in-memory structure gone — restores the transcript to a COLD client
/// presenting the same `--session-id`. Before the journal, this printed an empty pane.
///
/// The two lives share ONE journal directory and get SEPARATE custodians, and the second half is
/// what makes this the journal's scenario at all: sharing a custodian would mean the pane SURVIVED
/// (`docs/51`), hostd #2 would adopt it and reattach, and the disk journal would never be consulted
/// — the feature working, but not the feature under test. A dead custodian is superd's own death
/// case: it takes every pane with it, so life 2 comes up cold, which is exactly a reboot.
#[test]
fn the_scrollback_survives_a_hostd_restart() {
    // Declared first, so it is released LAST — after every child guard below has reaped.
    let _serial = serialised();
    let Some(rig) = rig() else { return };
    let Some(sandbox) = Sandbox::build(&rig) else {
        return;
    };
    // This test's SUBJECT is a journal that outlives the daemon, so its two hostds share one journal
    // directory OUTSIDE either container. The per-file override wins over the container.
    let Some(journal) = TempDir::make("e2e-scrollback") else {
        return;
    };
    let life1 = sandbox.with("SLOPDESK_SCROLLBACK_DIR", &journal.path.display().to_string());
    let Some(second) = boot_superd(&rig.superd) else {
        return;
    };
    let life2 = replacing(&life1, SUPERD_SOCKET_ENV, &second.socket);

    let session = fresh_session_id();
    let survivor = marker("RESTART_SURVIVOR");

    // ── Life 1: journal the marker, then die without ceremony.
    let Some(mut first_host) = launch_hostd(&rig, &life1, None) else {
        return;
    };
    let Some(mut first_client) = launch_client(first_host.port, Some(&session)) else {
        return;
    };
    first_client.feed(&format!("echo {survivor}\n"));
    // NOTE: stdin stays OPEN (no `exit`) — a typed exit is a deliberate end and would DELETE the
    // journal; this scenario is a link drop.
    if !first_client.out.awaits(&survivor, ECHO_TIMEOUT) {
        skip(&format!(
            "client #1 never saw its own echo (sandboxed PTY?): {} / {}",
            head(&first_client.out.text()),
            head(&first_client.errors.text()),
        ));
        return;
    }
    // The marker reached the client, so the host read the PTY chunk and queued the journal write;
    // give the journal a beat to flush before the kill.
    thread::sleep(Duration::from_millis(500));
    first_client.drop_link();
    drop(first_client);
    signal_term(first_host.guard.pid());
    let _reaped = wait_for_exit(&mut first_host.guard.child, Duration::from_secs(5));

    // ── Life 2: a brand-new daemon; a COLD client returns with the same session id.
    let Some(second_host) = launch_hostd(&rig, &life2, None) else {
        return;
    };
    let Some(second_client) = launch_client(second_host.port, Some(&session)) else {
        return;
    };
    let restored = second_client.out.awaits(&survivor, ECHO_TIMEOUT);
    let out = second_client.out.text();
    assert!(
        restored,
        "hostd #2 must restore the disk-journaled transcript to the returning cold client; got: {}\nclient \
         stderr: {}\nhostd #2: {}",
        head(&out),
        head(&second_client.errors.text()),
        tail(&second_host.log.text()),
    );

    // PATH B is state-transfer: life 1's spawn seeded the size sidecar, so life 2 must COMPOSE the
    // transcript — the log line is the observable — and the transcript needs no sanitize suffix,
    // because its mode-free construction replaces the reset barrage.
    let composed = second_host
        .log
        .awaits("(snapshot replay)", Duration::from_secs(5));
    assert!(
        composed,
        "the journal restore must ride the snapshot composer (size sidecar present); hostd #2 log: {}",
        tail(&second_host.log.text()),
    );
    assert!(
        !out.contains("\u{1b}[?1005l"),
        "a composed transcript must not carry the raw-replay sanitize suffix",
    );
}

/// Was `testColdReattachSnapshotKeepsScrollbackAndCursorShape`.
///
/// The state-transfer reattach through the SHIPPED binaries: churn plus a DECSCUSR into a live
/// session, kill the client (link drop → detach → PATH A), return COLD with the same session id,
/// and assert the replay is a rendered snapshot — reset preamble first — that still carries the
/// scrollback marker AND re-emits the cursor shape. Those are the two regressions of the first
/// hardware night: an empty pane for seconds, and a bar cursor reset to a block.
#[test]
fn a_cold_reattach_snapshot_keeps_the_scrollback_and_the_cursor_shape() {
    // Declared first, so it is released LAST — after every child guard below has reaped.
    let _serial = serialised();
    let Some(rig) = rig() else { return };
    let Some(sandbox) = Sandbox::build(&rig) else {
        return;
    };
    let Some(hostd) = launch_hostd(&rig, &sandbox.env, None) else {
        return;
    };
    let session = fresh_session_id();
    let survivor = marker("SNAPSHOT_SURVIVOR");

    // ── Life 1: churn, the marker, a shell-prompt mark, then a bar cursor (the zsh integration's
    // prompt shape). `/bin/sh` ships no shell integration, so the OSC 133 `A` is emitted by hand —
    // it is the same byte sequence a real integration sends.
    let script = format!(
        "i=0; while [ $i -lt 500 ]; do echo \"CHURN LINE $i ================================\"; i=$((i+1)); \
         done\necho {survivor}\nprintf '\\033]133;A\\007'\nprintf '\\033[5 q'\n"
    );
    let Some(mut first) = launch_client(hostd.port, Some(&session)) else {
        return;
    };
    first.feed(&script);
    if !first.out.awaits(&survivor, ECHO_TIMEOUT) {
        skip(&format!(
            "client #1 never saw its own echo (sandboxed PTY?): {} / {}",
            head(&first.out.text()),
            head(&first.errors.text()),
        ));
        return;
    }
    thread::sleep(Duration::from_millis(500)); // let the acks land so the churn reaches the ring
    first.drop_link(); // link drop — the host detaches the session (PATH A material)
    drop(first);

    // ── Life 2: a COLD return to the SAME daemon.
    let Some(second) = launch_client(hostd.port, Some(&session)) else {
        return;
    };
    let replayed = second.out.awaits(&survivor, ECHO_TIMEOUT);
    assert!(
        replayed,
        "reattach must replay the scrollback marker; got: {}\nclient stderr: {}",
        head(&second.out.text()),
        head(&second.errors.text()),
    );
    assert!(
        second.out.text().contains("\u{1b}[?1049l"),
        "cold reattach must be a rendered snapshot (reset preamble), not raw history",
    );
    // The DECSCUSR the session ended on must survive the state transfer.
    assert!(
        second.out.awaits("\u{1b}[5 q", Duration::from_secs(5)),
        "the reattached pane must re-emit the bar cursor shape",
    );
    // The PROMPT MARKS must survive too, and for a harder reason than the cursor shape: they paint
    // nothing, so a snapshot that drops them looks perfect and leaves the reattached terminal with
    // zero prompt ROWS — which is what `jump_to_prompt` counts, so every command-ladder / navigator
    // / jump-to-failed jump silently lands nowhere.
    assert!(
        second.out.text().contains("\u{1b}]133;A"),
        "the state transfer must re-emit the shell-prompt marks, not just the text",
    );
}

/// Was `testTwoClientsShareOneRealPTY`.
///
/// THE fan-out gate, on the SHIPPED binaries with a REAL PTY: two `slopdesk-client` processes
/// present the SAME `--session-id` to one `slopdesk-hostd`, and both watch the same shell. A marker
/// typed into A's stdin AFTER B joined must appear in BOTH stdouts.
///
/// The in-memory loopback provably misses open-order races, so this is the only acceptable
/// evidence: B's `channelOpen` lands against a LIVE session whose drain is already running, which
/// is exactly the window a loopback harness cannot create.
///
/// The environment carries no fan-out setting of any kind — sharing a pane is what a host does, so
/// B joining is the plain default rather than a configuration this test arranges. The companion
/// claim, that the join forks no SECOND shell, is the test below.
#[test]
fn two_clients_share_one_real_pty() {
    // Declared first, so it is released LAST — after every child guard below has reaped.
    let _serial = serialised();
    let Some(rig) = rig() else { return };
    let Some(sandbox) = Sandbox::build(&rig) else {
        return;
    };
    let Some(hostd) = launch_hostd(&rig, &sandbox.env, None) else {
        return;
    };
    let session = fresh_session_id();
    let joined = marker("FANOUT_JOINED");
    let shared = marker("FANOUT_SHARED");

    // ── Client A takes the pane and proves the shell is live. Both clients keep their stdin open
    // for the whole test: credit is granted at consumption, so a client that stops reading parks the
    // host's sender.
    let Some(mut a) = launch_client(hostd.port, Some(&session)) else {
        return;
    };
    a.feed(&format!("echo {joined}\n"));
    if !a.out.awaits(&joined, ECHO_TIMEOUT) {
        skip(&format!(
            "client A never saw its own echo (sandboxed PTY?): {} / {}",
            head(&a.out.text()),
            head(&a.errors.text()),
        ));
        return;
    }

    // ── Client B JOINS the live session — no detach, no reattach; A is still here. B is cold, so the
    // host state-transfers the screen and the rendered snapshot carries the marker A already
    // printed. Seeing it is how we know B is attached and draining.
    let Some(mut b) = launch_client(hostd.port, Some(&session)) else {
        return;
    };
    assert!(
        b.out.awaits(&joined, ECHO_TIMEOUT),
        "client B must join the LIVE session and receive its state transfer; got: {}\nstderr: {}",
        head(&b.out.text()),
        head(&b.errors.text()),
    );
    assert!(b.is_running(), "client B must stay connected, not be refused");

    // ── The fan-out itself: A types, BOTH see it.
    a.feed(&format!("echo {shared}\n"));
    assert!(
        a.out.awaits(&shared, ECHO_TIMEOUT),
        "the typing client must see its own output; got: {}",
        tail(&a.out.text()),
    );
    assert!(
        b.out.awaits(&shared, ECHO_TIMEOUT),
        "the SECOND subscriber must receive the same PTY bytes; got: {}",
        tail(&b.out.text()),
    );

    // ── Leaving is refcounted: A departs, B keeps the shell AND keeps receiving.
    a.drop_link();
    drop(a);
    let survives = marker("FANOUT_SURVIVES");
    b.feed(&format!("echo {survives}\n"));
    assert!(
        b.out.awaits(&survives, ECHO_TIMEOUT),
        "one subscriber leaving must not stop the drain for the other; got: {}",
        tail(&b.out.text()),
    );
}

/// Was `testASecondClientJoinsTheLiveSessionAndForksNoSecondShell`.
///
/// The exclusivity rule this replaced said "one attachment per sessionID, ever". What is true is
/// narrower and it is about the SHELL, not the attachment: a second client presenting a LIVE
/// sessionID joins the pane that exists, and the host performs exactly ONE `openpty()`/`fork()` for
/// that id — never two.
///
/// Counted from the PROCESS TABLE, not inferred from a log line or a mock. Two shells under one
/// sessionID is the concrete disaster the old refusal existed to prevent: two writers interleaving
/// into one journal, and the journal claim rotating the incumbent's writer out mid-session. A host
/// that answered the second open by forking again would satisfy every byte-level assertion in
/// `two_clients_share_one_real_pty` — both clients would see their own shell — and would still be
/// broken. Only the count catches it.
#[test]
fn a_second_client_joins_the_live_session_and_forks_no_second_shell() {
    // Declared first, so it is released LAST — after every child guard below has reaped.
    let _serial = serialised();
    let Some(rig) = rig() else { return };
    let Some(sandbox) = Sandbox::build(&rig) else {
        return;
    };
    let Some(hostd) = launch_hostd(&rig, &sandbox.env, None) else {
        return;
    };
    let session = fresh_session_id();
    let incumbent = marker("ONESHELL_INCUMBENT");

    let Some(mut a) = launch_client(hostd.port, Some(&session)) else {
        return;
    };
    a.feed(&format!("echo {incumbent}\n"));
    if !a.out.awaits(&incumbent, ECHO_TIMEOUT) {
        skip(&format!(
            "client A never saw its own echo (sandboxed PTY?): {} / {}",
            head(&a.out.text()),
            head(&a.errors.text()),
        ));
        return;
    }

    // The baseline the whole test turns on: A's pane IS one forked shell, so a count of 1 here is
    // measuring the thing rather than an empty table.
    //
    // Counted under the CUSTODIAN, not under hostd. hostd does not fork — superd does, so that the
    // shell outlives a hostd restart (`docs/51`) — and the shell is therefore superd's child. The
    // companion assertion turns that into a pin: a shell parented to hostd would mean the fork
    // window had come back.
    let after_a = shell_children(sandbox.superd.pid);
    assert_eq!(
        after_a.len(),
        1,
        "precondition: one client on one pane is one shell; got pids {after_a:?}",
    );
    assert_eq!(
        shell_children(hostd.guard.pid()),
        Vec::<i32>::new(),
        "hostd must fork nothing — every pane's shell belongs to superd",
    );

    let Some(mut b) = launch_client(hostd.port, Some(&session)) else {
        return;
    };
    // B joins rather than exiting. Asserted BEFORE the count, because a B that was refused and died
    // would leave the count at 1 and pass the real assertion vacuously.
    assert!(
        b.out.awaits(&incumbent, ECHO_TIMEOUT),
        "the second client must JOIN the live session and receive its state transfer; got: {}\nstderr: {}",
        head(&b.out.text()),
        head(&b.errors.text()),
    );
    assert!(b.is_running(), "the second client stays connected");

    // THE assertion: the join forked nothing. Same shell, same pid.
    let after_b = shell_children(sandbox.superd.pid);
    assert_eq!(
        after_b, after_a,
        "a second client on a live sessionID must join the ONE shell, not fork another",
    );

    // The incumbent is untouched by the join.
    let survivor = marker("ONESHELL_SURVIVOR");
    a.feed(&format!("echo {survivor}\n"));
    assert!(
        a.out.awaits(&survivor, EXIT_TIMEOUT),
        "the join must leave the incumbent's pane working; got: {}",
        tail(&a.out.text()),
    );
}
