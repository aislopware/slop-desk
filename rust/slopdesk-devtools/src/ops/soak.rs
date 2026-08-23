//! The PTY fan-out under a REAL slow subscriber (`docs/45` §8.6, §10 Q2).
//!
//! Real processes only: one `slopdesk-hostd`, several `slopdesk-client`s, a real PTY, and a laggard
//! made slow the way a backgrounded phone is slow — SIGSTOP, so it stops reading its socket AND
//! stops acking at the same instant. Nothing here is mocked or in-memory: the in-memory loopback
//! provably misses the open-order and credit-window races this exists to catch.
//!
//! Four properties, in order:
//!
//! | | |
//! | --- | --- |
//! | P1 retention | a laggard under the threshold loses NOTHING — both members receive every line exactly once, in order, when the slow one resumes |
//! | P2 eviction | a laggard past `SLOPDESK_SUB_LAG_BYTES` is evicted, and it is the LAGGARD that goes, not the session: the fast member keeps every byte and the shell survives |
//! | P3 no head-of-line | the fast member receives the whole stream WHILE the slow one is frozen, so neither the drain nor the read loop is serialised behind the laggard |
//! | P4 producer bound | a pane that fanned out and then shrank back to ONE member still backpressures the PTY when that member stops consuming, exactly like a pane that never fanned out — run as an A/B in one host process, so both shells must still be blocked at the end |
//!
//! Deterministic enough to gate: every assertion is a count or a liveness check, not a timing
//! threshold. It is NOT a CI gate — it needs a real PTY and ~80 seconds of wall clock. Run it after
//! touching the fan-out, the subscriber set, the out-FIFO, the queue gate, or the retention buffer.
//!
//! ## What the port changed, and the one thing it could not
//! The FIFO-plus-`sleep 100000` dance is gone: a client's stdin is a pipe this process holds open
//! for the whole run, which is what the FIFO was imitating. The pid FILE is gone too — it existed
//! because `start_client` was called through command substitution, so a shell-array append inside
//! it landed in a subshell and the parent's cleanup missed every client.
//!
//! What could not be ported is the `trap … INT TERM`: a client left stopped by `SIGSTOP` that
//! outlives this process keeps a port and a shell alive, and Rust reaches signal disposition only
//! through `libc`, which this crate forbids. So the cleanup moved OUT — [`reap`] is this same
//! binary re-executed as a child holding one pipe, and that pipe closing is what starts the reap.
//! It closes when this process exits for ANY reason, which is strictly more than a trap covers: a
//! bash EXIT trap does not run under an untrapped signal, and no trap at all runs under `SIGKILL`.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};
use std::{fs, thread};

use regex::Regex;

use super::{container, say};
use crate::proc;

/// `"L%07d"` + 64 dots + CR + LF, as the PTY emits it.
const LINE_BYTES: u64 = 74;
/// The default lag threshold when `SLOPDESK_SUB_LAG_BYTES` is unset. The SHIPPED default is 32 MiB;
/// this is the soak's, chosen so a run costs ~80 seconds rather than ten minutes.
pub const DEFAULT_THRESHOLD: u64 = 4 * 1024 * 1024;
/// P4 only has to exceed the 64 KiB queue bound by a lot. A CORRECT host finishes none of it, so
/// the assertion is "the generator is still alive", not a byte count.
const BOUND_LINES: u64 = 600_000;

/// How many lines each phase generates, for a given threshold.
///
/// P2 wants ~4× the threshold, so eviction is reached with margin rather than by a lucky rounding.
/// P1 wants comfortably UNDER it, so it exercises retention and not eviction.
#[must_use]
pub const fn lines_for(threshold: u64) -> (u64, u64) {
    ((threshold / 4) / LINE_BYTES, (threshold * 4) / LINE_BYTES)
}

// ─────────────────────────────────────────────────────────────────── what the harness reads back

/// The port `hostd --port 0` bound, from its stderr.
#[must_use]
pub fn bound_port(stderr: &str) -> Option<String> {
    let pattern = Regex::new(r"listening on 0\.0\.0\.0:(\d+) \(shell").ok()?;
    pattern.captures(stderr).map(|found| found[1].to_owned())
}

/// The pid of the `/bin/sh` serving `pane`, from the host's stderr.
#[must_use]
pub fn shell_pid_for(stderr: &str, pane: &str) -> Option<String> {
    let pattern = Regex::new(&format!(
        r"shell /bin/sh \(pid (\d+)\) attached for pane {}",
        regex::escape(pane)
    ))
    .ok()?;
    pattern.captures(stderr).map(|found| found[1].to_owned())
}

/// Every `PREFIX0000123` sequence number in a client's capture, in arrival order.
#[must_use]
pub fn sequence(capture: &str, prefix: &str) -> Vec<u64> {
    let Ok(pattern) = Regex::new(&format!(r"{}(\d{{7}})", regex::escape(prefix))) else {
        return Vec::new();
    };
    pattern
        .captures_iter(capture)
        .filter_map(|found| found[1].parse::<u64>().ok())
        .collect()
}

/// A capture holds exactly `count` lines of `prefix`, contiguous from `first`, with no duplicates.
///
/// A gap is a LOST byte; a duplicate is a byte delivered twice. Neither is allowed, and the two are
/// reported apart because they mean opposite things about the retention buffer.
///
/// # Errors
/// With the count, the duplicate or the gap named.
pub fn check_stream(capture: &str, prefix: &str, first: u64, count: u64) -> Result<String, String> {
    let got = sequence(capture, prefix);
    let seen = u64::try_from(got.len()).unwrap_or(u64::MAX);
    if seen != count {
        return Err(format!("expected {count} lines, got {seen}"));
    }
    let mut unique = got.clone();
    unique.sort_unstable();
    unique.dedup();
    let kept = u64::try_from(unique.len()).unwrap_or(u64::MAX);
    if kept != count {
        return Err(format!(
            "{} DUPLICATE line(s) — a subscriber received a byte twice",
            count - kept
        ));
    }
    for (offset, number) in got.iter().enumerate() {
        let wanted = first + u64::try_from(offset).unwrap_or(0);
        if *number != wanted {
            return Err(format!(
                "the sequence has a GAP at {number} (expected {wanted}) — a subscriber lost a byte"
            ));
        }
    }
    Ok(format!("{count} lines, contiguous from {first}, no duplicates"))
}

/// The shell command that makes a pane emit `count` numbered lines and then announce it is done.
#[must_use]
pub fn generator(prefix: &str, first: u64, count: u64) -> String {
    let dots = ".".repeat(64);
    // `\\n` here is a literal backslash-n on the wire, which is what awk needs to see in its own
    // format string. The pane runs this; nothing in this process interprets it.
    format!(
        "awk 'BEGIN{{for(i={first};i<{end};i++) printf \"{prefix}%07d%s\\n\", i, \"{dots}\"}}'; echo \
         {prefix}_DONE\n",
        end = first + count
    )
}

// ─────────────────────────────────────────────────────────────────────────── the live processes

/// Send a signal by name, the one thing this crate cannot do in-process.
///
/// `Child::kill` is SIGKILL and nothing else, and SIGSTOP is the entire point of this harness —
/// it is what makes a subscriber slow the way a backgrounded phone is slow, stopping its reads and
/// its acks at the same instant, rather than the way a `sleep` in a test double is slow.
fn signal(name: &str, pid: u32) {
    let _ = Command::new("/bin/kill")
        .args([name, &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// A property held, on the harness's own stdout.
fn ok(what: &str) {
    println!("ok   {what}");
}

/// One shipped client, with its stdin held open for the whole run.
struct Member {
    name: String,
    pid: u32,
    child: Child,
    stdin: ChildStdin,
    out: PathBuf,
}

impl Member {
    /// Write to the pane, unbuffered — the harness's next step depends on the shell seeing it.
    fn feed(&mut self, text: &str) -> Result<(), String> {
        self.stdin
            .write_all(text.as_bytes())
            .and_then(|()| self.stdin.flush())
            .map_err(|error| format!("{}: {error}", self.name))
    }

    /// Everything the client has printed so far.
    fn capture(&self) -> String {
        fs::read_to_string(&self.out).unwrap_or_default()
    }

    /// Wait (bounded) for `text` to appear in this client's capture.
    fn await_text(&self, text: &str, patience: Duration) -> bool {
        let started = Instant::now();
        loop {
            if self.capture().contains(text) {
                return true;
            }
            if started.elapsed() >= patience {
                return false;
            }
            thread::sleep(Duration::from_millis(250));
        }
    }
}

/// The whole run: its scratch directory, its host, its clients, and the reaper that outlives it.
struct Soak {
    work: PathBuf,
    root: PathBuf,
    client: PathBuf,
    port: String,
    hostd: Child,
    pidfile: PathBuf,
    failures: u32,
    /// Held open on purpose: [`reap`] starts when this closes. Never read.
    _reaper: Reaper,
}

/// The child that cleans up when this process's write end of its stdin closes.
struct Reaper {
    child: Child,
}

impl Drop for Reaper {
    fn drop(&mut self) {
        // Closing the pipe is the signal; the child does the rest, including after a SIGKILL here.
        let _ = self.child.wait();
    }
}

impl Soak {
    fn fail(&mut self, what: &str) {
        println!("FAIL {what}");
        self.failures += 1;
    }

    /// Record a pid the reaper must account for, before anything can go wrong with it.
    fn remember(&self, pid: u32) -> Result<(), String> {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.pidfile)
            .map_err(|error| format!("{}: {error}", self.pidfile.display()))?;
        writeln!(file, "{pid}").map_err(|error| format!("{}: {error}", self.pidfile.display()))
    }

    /// The host's stderr so far — where the joins, the evictions and the shell pids are logged.
    fn host_log(&self) -> String {
        fs::read_to_string(self.work.join("hostd.err")).unwrap_or_default()
    }

    /// Launch one shipped client on `session`.
    ///
    /// # Errors
    /// When the client cannot be spawned or its capture files cannot be made.
    fn start_client(&self, name: &str, session: &str) -> Result<Member, String> {
        let out = self.work.join(format!("{name}.out"));
        let sink = fs::File::create(&out).map_err(|error| format!("{}: {error}", out.display()))?;
        let errors = fs::File::create(self.work.join(format!("{name}.err")))
            .map_err(|error| format!("{name}.err: {error}"))?;
        let mut child = Command::new(&self.client)
            .args([
                "--host",
                "127.0.0.1",
                "--port",
                &self.port,
                "--no-raw",
                "--session-id",
                session,
            ])
            .env("HOME", self.work.join("home"))
            .stdin(Stdio::piped())
            .stdout(Stdio::from(sink))
            .stderr(Stdio::from(errors))
            .spawn()
            .map_err(|error| format!("{}: {error}", self.client.display()))?;
        let pid = child.id();
        self.remember(pid)?;
        let stdin = child.stdin.take().ok_or_else(|| format!("{name}: no stdin"))?;
        Ok(Member {
            name: name.to_owned(),
            pid,
            child,
            stdin,
            out,
        })
    }

    /// The pid of the generator still running under the shell serving `pane`, if any.
    fn generator_pid(&self, pane: &str) -> Option<String> {
        let shell = shell_pid_for(&self.host_log(), pane)?;
        proc::ask("/usr/bin/pgrep", &["-P", &shell, "awk"], &self.root)
            .and_then(|found| found.lines().next().map(str::to_owned))
            .filter(|pid| !pid.is_empty())
    }

    /// Assert a member's capture, reporting under `label`.
    fn assert_stream(&mut self, label: &str, member: &Member, prefix: &str, first: u64, count: u64) {
        match check_stream(&member.capture(), prefix, first, count) {
            Ok(what) => ok(&format!("{label}: {what}")),
            Err(why) => self.fail(&format!("{label}: {why}")),
        }
    }
}

/// Run the soak.
///
/// # Errors
/// When the build products are missing, or the harness cannot get to the point of asserting
/// anything — a host that never binds, a pane that never comes up. A property that FAILS is not an
/// error: it is counted, printed, and reported in the exit status, so one failing property does not
/// hide the other three.
#[allow(
    clippy::too_many_lines,
    reason = "the shape IS the four properties, in the order they run"
)]
pub fn run(root: &Path, threshold: u64) -> Result<u32, String> {
    let hostd_bin = root.join(".build/debug/slopdesk-hostd");
    let client_bin = root.join(".build/debug/slopdesk-client");
    for binary in [&hostd_bin, &client_bin] {
        if !binary.is_file() {
            return Err(format!(
                "build products missing under {}/.build/debug — run 'swift build' first",
                root.display()
            ));
        }
    }
    let (hold_lines, evict_lines) = lines_for(threshold);

    let work = std::env::temp_dir().join(format!("slopdesk-soak.{}", std::process::id()));
    let _ = fs::remove_dir_all(&work);
    let state = work.join("state");
    let environment = container(&state)?;
    fs::create_dir_all(work.join("home")).map_err(|error| format!("{}: {error}", work.display()))?;
    let pidfile = work.join("pids");
    fs::write(&pidfile, "").map_err(|error| format!("{}: {error}", pidfile.display()))?;

    let reaper = spawn_reaper(&pidfile, &work)?;
    say(
        "soak",
        &format!("== fan-out laggard soak: SLOPDESK_SUB_LAG_BYTES={threshold} =="),
    );

    // `HOME` is not the container and never was: it moves neither Application Support nor
    // `NSHomeDirectory()`. This soak pushes megabytes through several sessions by design, and
    // without the redirect all of it was journaled into the developer's own scrollback directory,
    // where the journal sweep then unlinked their oldest transcripts to hold it at 256.
    let stdout = fs::File::create(work.join("hostd.out")).map_err(|error| format!("hostd.out: {error}"))?;
    let stderr = fs::File::create(work.join("hostd.err")).map_err(|error| format!("hostd.err: {error}"))?;
    let mut command = Command::new(&hostd_bin);
    command
        .args(["--port", "0", "--shell", "/bin/sh"])
        .env("HOME", work.join("home"))
        .env("SLOPDESK_SUB_LAG_BYTES", threshold.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    for (key, value) in &environment {
        command.env(key, value);
    }
    let hostd = command
        .spawn()
        .map_err(|error| format!("{}: {error}", hostd_bin.display()))?;
    let hostd_pid = hostd.id();
    fs::write(&pidfile, format!("{hostd_pid}\n"))
        .map_err(|error| format!("{}: {error}", pidfile.display()))?;

    let mut soak = Soak {
        work,
        root: root.to_path_buf(),
        client: client_bin,
        port: String::new(),
        hostd,
        pidfile,
        failures: 0,
        _reaper: reaper,
    };

    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(15) {
        if let Some(port) = bound_port(&soak.host_log()) {
            soak.port = port;
            break;
        }
        thread::sleep(Duration::from_millis(250));
    }
    if soak.port.is_empty() {
        print!("{}", soak.host_log());
        return Err("hostd never reported a bound port".to_owned());
    }
    say("soak", &format!("hostd pid {hostd_pid} on port {}", soak.port));

    // ───────────────────────────────────────────── P1 / P2 / P3: the shared pane

    let shared = proc::capture("uuidgen", &[] as &[&str], root)?;
    let mut fast = soak.start_client("fast", &shared)?;
    thread::sleep(Duration::from_secs(2));
    let slow = soak.start_client("slow", &shared)?;
    thread::sleep(Duration::from_secs(3));
    fast.feed("stty -echo; PS1=\"\"\n")?;
    thread::sleep(Duration::from_secs(1));
    fast.feed("echo JOINED\n")?;
    if !fast.await_text("JOINED", Duration::from_secs(25)) {
        return Err("the fast client never saw its own echo".to_owned());
    }
    if !slow.await_text("JOINED", Duration::from_secs(25)) {
        return Err("the slow client never joined the live pane".to_owned());
    }
    if !soak.host_log().contains("joined live session") {
        return Err("the host never logged a JOIN — a second client on a live pane must join it".to_owned());
    }
    say(
        "soak",
        &format!(
            "two clients share pane {shared} (fast {}, slow {})",
            fast.pid, slow.pid
        ),
    );

    println!("-- P1 retention: a laggard under the threshold loses nothing");
    signal("-STOP", slow.pid);
    fast.feed(&generator("L", 1, hold_lines))?;
    if !fast.await_text("L_DONE", Duration::from_secs(120)) {
        soak.fail("P1: the generator never finished for the fast member");
    }
    signal("-CONT", slow.pid);
    if !slow.await_text("L_DONE", Duration::from_secs(120)) {
        soak.fail("P1: the resumed laggard never caught up");
    }
    soak.assert_stream("P1 fast member", &fast, "L", 1, hold_lines);
    soak.assert_stream("P1 laggard", &slow, "L", 1, hold_lines);

    println!("-- P2 eviction + P3 no head-of-line: a laggard past the threshold goes, the pane does not");
    signal("-STOP", slow.pid);
    fast.feed(&generator("M", 1_000_000, evict_lines))?;
    if !fast.await_text("M_DONE", Duration::from_secs(300)) {
        soak.fail("P3: the fast member was starved while the laggard was frozen");
    }
    soak.assert_stream("P3 fast member", &fast, "M", 1_000_000, evict_lines);

    let log = soak.host_log();
    if let Some(line) = log.lines().find(|line| line.contains("evicted — more than")) {
        let what = line.split_once("hostd: ").map_or(line, |(_, rest)| rest);
        ok(&format!("P2: the host evicted a laggard ({what})"));
    } else {
        soak.fail(&format!(
            "P2: nothing was evicted after {} bytes past a {threshold} threshold",
            evict_lines * LINE_BYTES
        ));
    }
    if log.contains("pane subscriber 1: evicted") {
        ok("P2: the member evicted is the LAGGARD (subscriber 1), not the fast one");
    } else {
        let seen: Vec<&str> = log.lines().filter(|line| line.contains("evicted")).collect();
        soak.fail(&format!(
            "P2: the evicted member is not the laggard: {}",
            seen.join(" / ")
        ));
    }

    fast.feed("echo SURVIVED\n")?;
    if fast.await_text("SURVIVED", Duration::from_secs(30)) {
        ok("P2: the shell survives its laggard's eviction and still answers the fast member");
    } else {
        soak.fail("P2: the pane died with its laggard — eviction took the session, not the subscriber");
    }
    signal("-CONT", slow.pid);

    // ───────────────────────────────────────── P4: the producer bound after a shrink

    println!("-- P4 producer bound: a pane that shrank back to one member still backpressures the PTY");
    let control = proc::capture("uuidgen", &[] as &[&str], root)?;
    let test = proc::capture("uuidgen", &[] as &[&str], root)?;
    let mut c1 = soak.start_client("c1", &control)?;
    thread::sleep(Duration::from_secs(2));
    let mut t1 = soak.start_client("t1", &test)?;
    thread::sleep(Duration::from_secs(2));
    let t2 = soak.start_client("t2", &test)?;
    thread::sleep(Duration::from_secs(3));
    c1.feed("stty -echo; PS1=\"\"\n")?;
    t1.feed("stty -echo; PS1=\"\"\n")?;
    thread::sleep(Duration::from_secs(1));
    c1.feed("echo READY\n")?;
    t1.feed("echo READY\n")?;
    if !c1.await_text("READY", Duration::from_secs(25)) {
        return Err("the control pane never came up".to_owned());
    }
    if !t1.await_text("READY", Duration::from_secs(25)) {
        return Err("the test pane never came up".to_owned());
    }

    // The test pane SHRINKS back to one member while LIVE — a second client closing its lid, or the
    // laggard eviction above. The control pane never fanned out at all.
    signal("-TERM", t2.pid);
    thread::sleep(Duration::from_secs(4));

    // The leading `sleep 4` gives the harness time to freeze both clients before either generator
    // produces a byte, so the two panes are frozen at the SAME point in their streams.
    c1.feed("sleep 4; ")?;
    t1.feed("sleep 4; ")?;
    c1.feed(&generator("B", 1, BOUND_LINES))?;
    t1.feed(&generator("B", 1, BOUND_LINES))?;
    thread::sleep(Duration::from_secs(1));
    signal("-STOP", c1.pid);
    signal("-STOP", t1.pid);
    thread::sleep(Duration::from_secs(45));

    if let Some(pid) = soak.generator_pid(&control) {
        ok(&format!(
            "P4 control (never fanned out): the shell is still blocked on a full PTY (awk {pid})"
        ));
    } else {
        soak.fail(&format!(
            "P4 control: the never-fanned-out pane swallowed {} bytes with nobody reading",
            BOUND_LINES * LINE_BYTES
        ));
    }
    if let Some(pid) = soak.generator_pid(&test) {
        ok(&format!(
            "P4 test (fanned out, then shrank to one): the shell is still blocked on a full PTY (awk {pid})"
        ));
    } else {
        soak.fail(&format!(
            "P4 test: a pane that shrank back to one member buffered {} bytes into host RAM — the queue \
             gate stopped bounding the producer",
            BOUND_LINES * LINE_BYTES
        ));
    }

    println!();
    if soak.failures == 0 {
        println!("== soak PASSED ==");
    } else {
        println!("== soak FAILED ({}) ==", soak.failures);
        println!("-- hostd log --");
        print!("{}", soak.host_log());
    }

    // Resumed before the reaper ever sees them: a stopped process cannot act on a SIGTERM.
    for member in [&c1, &t1, &fast, &slow] {
        signal("-CONT", member.pid);
    }
    for mut member in [c1, t1, t2, fast, slow] {
        let _ = member.child.kill();
        let _ = member.child.wait();
    }
    let _ = soak.hostd.kill();
    let _ = soak.hostd.wait();
    Ok(soak.failures)
}

/// Re-execute this binary as the reaper, holding one pipe open for the rest of the run.
///
/// # Errors
/// When this executable's own path is unknown, or the child cannot be spawned.
fn spawn_reaper(pidfile: &Path, work: &Path) -> Result<Reaper, String> {
    let me = std::env::current_exe().map_err(|error| format!("current_exe: {error}"))?;
    let child = Command::new(me)
        .args([
            "soak-reap",
            "--pidfile",
            &pidfile.to_string_lossy(),
            "--work",
            &work.to_string_lossy(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| format!("reaper: {error}"))?;
    Ok(Reaper { child })
}

/// The reaper: wait for stdin to close, then make sure nothing this run spawned outlives it.
///
/// `SIGCONT` before `SIGTERM`, always — a stopped process cannot act on a termination request, and
/// a frozen client holding a port and a shell is exactly what this exists to prevent.
///
/// # Errors
/// Never; the signature matches the other verbs so the dispatcher stays one table.
pub fn reap(pidfile: &Path, work: &Path) -> Result<(), String> {
    use std::io::Read;

    let mut sink = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut sink);

    let pids: Vec<u32> = fs::read_to_string(pidfile)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .collect();
    for pid in &pids {
        signal("-CONT", *pid);
        signal("-TERM", *pid);
    }
    thread::sleep(Duration::from_secs(1));
    for pid in &pids {
        signal("-KILL", *pid);
    }
    let _ = fs::remove_dir_all(work);
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;

    /// A capture of `count` numbered lines, the way a client's stdout holds them.
    fn numbered(prefix: &str, first: u64, count: u64) -> String {
        (first..first + count).fold(String::new(), |mut text, index| {
            let _ = writeln!(text, "{prefix}{index:07}....");
            text
        })
    }

    /// P1 stays under the threshold and P2 clears it with margin — the two are not the same number.
    #[test]
    fn the_two_phases_sit_on_opposite_sides_of_the_threshold() {
        let threshold = 4 * 1024 * 1024;
        let (hold, evict) = super::lines_for(threshold);
        assert!(hold * super::LINE_BYTES < threshold, "P1 must not reach eviction");
        assert!(
            evict * super::LINE_BYTES > threshold * 3,
            "P2 must clear it with margin"
        );
    }

    /// The bound port is read from the line the host prints, not from a record file.
    #[test]
    fn the_bound_port_comes_off_the_listen_line() {
        let log = "hostd: starting\nhostd: listening on 0.0.0.0:53219 (shell /bin/sh)\n";
        assert_eq!(super::bound_port(log).as_deref(), Some("53219"));
        assert_eq!(super::bound_port("hostd: listening on 0.0.0.0:53219\n"), None);
        assert_eq!(super::bound_port("hostd: starting\n"), None);
    }

    /// A pane's shell is found by the pane's OWN id, never by whichever shell logged last.
    #[test]
    fn a_shell_pid_belongs_to_the_pane_that_asked() {
        let log = "hostd: shell /bin/sh (pid 111) attached for pane AAAA\nhostd: shell /bin/sh (pid 222) \
                   attached for pane BBBB\n";
        assert_eq!(super::shell_pid_for(log, "BBBB").as_deref(), Some("222"));
        assert_eq!(super::shell_pid_for(log, "AAAA").as_deref(), Some("111"));
        assert_eq!(super::shell_pid_for(log, "CCCC"), None);
    }

    /// A pane id is a UUID, whose hyphens must not be read as a regex range.
    #[test]
    fn a_pane_id_is_matched_literally() {
        let log = "hostd: shell /bin/sh (pid 9) attached for pane 8B2F.-A1\n";
        assert_eq!(super::shell_pid_for(log, "8B2F.-A1").as_deref(), Some("9"));
        assert_eq!(
            super::shell_pid_for(log, "8B2FXA1"),
            None,
            "the dot is a dot, not any-char"
        );
    }

    /// A clean stream passes; the three ways it can be dirty are told apart.
    #[test]
    fn a_stream_is_checked_for_count_duplicates_and_gaps() {
        let clean = numbered("L", 1, 5);
        assert!(super::check_stream(&clean, "L", 1, 5).is_ok());

        let short = numbered("L", 1, 4);
        let why = super::check_stream(&short, "L", 1, 5).expect_err("four is not five");
        assert!(why.contains("got 4"), "{why}");

        let doubled = format!("{clean}L0000003....\n");
        let why = super::check_stream(&doubled, "L", 1, 6).expect_err("a repeat is a duplicate");
        assert!(why.contains("DUPLICATE"), "{why}");

        let gapped = "L0000001..\nL0000002..\nL0000004..\nL0000005..\nL0000006..\n";
        let why = super::check_stream(gapped, "L", 1, 5).expect_err("a missing 3 is a gap");
        assert!(why.contains("GAP"), "{why}");
    }

    /// A stream may start anywhere — P2 starts at a million so its prefix cannot alias P1's.
    #[test]
    fn a_stream_need_not_start_at_one() {
        let capture = numbered("M", 1_000_000, 3);
        assert!(super::check_stream(&capture, "M", 1_000_000, 3).is_ok());
    }

    /// The generator emits the awk escape as a BACKSLASH-n, which is what awk must see.
    #[test]
    fn the_generator_sends_awk_an_escape_and_not_a_newline() {
        let command = super::generator("L", 1, 10);
        assert!(command.contains(r"%07d%s\n"), "{command}");
        assert!(command.contains("for(i=1;i<11;i++)"), "{command}");
        assert!(command.ends_with("echo L_DONE\n"), "{command}");
        assert_eq!(
            command.matches('\n').count(),
            1,
            "only the trailing newline is real"
        );
    }
}
