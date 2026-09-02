//! The macOS runtime gate: build → launch → assert WINDOWED → screenshot, and `--connect` on top.
//!
//! ## Why it exists
//! `swift test` proves the headless logic, `check-ios.sh` type-checks the iOS slice, and maestro
//! screenshots the iOS Simulator. The one gap is the macOS GUI app AT RUNTIME — maestro cannot
//! drive a native macOS app, it only targets iOS, Android and web. This closes that gap with the
//! toolchain every Mac already has.
//!
//! ## Two modes
//! - **default** — build the committed app, launch, assert alive AND windowed AND mounted,
//!   screenshot.
//! - **`--connect`** — the same PLUS a real end-to-end check: a live `slopdesk-hostd`, an app that
//!   auto-connects on launch, an ESTABLISHED TCP session, and — the part a live socket cannot vouch
//!   for — a command auto-typed through the real keystroke chain that the remote shell EXECUTES.
//!   The marker is COMPUTED (`$((6*7))` → 42), so an echo of the literal keystrokes cannot satisfy
//!   it.
//!
//! There used to be a THIRD, `--renderer`, and with it a spec guard: the terminal conformer linked
//! a gitignored xcframework, joined the app by a text insert into the committed spec, and was
//! compiled by no `Package.swift` target — so "does the renderer app launch" was a different build
//! from "does the app launch", and the gate had to make one before it could ask. It caught a real
//! failure that way, a ~3 s launch crash from an off-main `MainActor.assumeIsolated` in
//! libghostty's wakeup/write/resize callbacks, fired from its own renderer and io threads. Both the
//! fork and the second build are gone (`docs/68` §10): the conformer is a package source, every
//! mode below builds it, and the concurrency shape that produced that crash is ours now rather than
//! an engine's.
//!
//! Requires a logged-in GUI session: it drives a real window, so it is not headless.

use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::Duration;
use std::{fs, thread};

use super::control::{Control, Launch};
use super::{
    Hostd, Log, Suite, alive, banner, build_app, build_cli, complain, kill_matching, poll, port, raise, reap,
    say, screenshot, window_census_binary, window_count, work_dir,
};

/// Which of the two modes to run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Build the committed app and ask it what it mounted.
    Launch,
    /// The same, plus a live host and the typed-command round trip.
    Connect,
}

impl Mode {
    /// Read a mode off the command line, the way the shell's `case` did.
    ///
    /// # Errors
    /// When the flag is not the one there is.
    pub fn parse(flag: Option<&str>) -> Result<Self, String> {
        match flag {
            None | Some("") => Ok(Self::Launch),
            Some("--connect") => Ok(Self::Connect),
            Some(other) => {
                Err(format!(
                    "unknown flag {other} — usage: slopdesk-guigate macos [--connect]"
                ))
            },
        }
    }

    /// How long the app gets to settle before it is asked anything.
    ///
    /// `--connect` needs more: it is a build, a TCP connect and a first render rather than a
    /// launch.
    #[must_use]
    pub const fn settle(self) -> Duration {
        match self {
            Self::Connect => Duration::from_secs(7),
            Self::Launch => Duration::from_secs(4),
        }
    }
}

/// The auto-typed command, and the proof only its EXECUTION can produce.
///
/// `ESTABLISHED` proves a live socket and nothing more. This proves the round trip: the app types a
/// command through the real OUT path (`terminal.sendInput` → the ordered drain →
/// `SlopDeskClient.sendInput` → the host PTY), the host shell RUNS it, and the shell computes 42.
/// The `$((6*7))` is what makes an echo of the literal keystrokes unable to satisfy the check — a
/// marker the client could have produced itself would prove only that the client can type.
#[derive(Debug)]
struct OutProof {
    /// Where the remote shell writes.
    file: PathBuf,
    /// The string only an executing shell can produce.
    expect: String,
    /// What `SLOPDESK_AUTOTYPE` carries.
    command: String,
}

impl OutProof {
    fn mint(work: &Path) -> Self {
        // Unique per RUN, not merely per process: the pid alone repeats within a boot, and a stale
        // proof file left by a killed run under the same pid would be read as this run's success.
        // The clock is the second half, and it need not be random for that — nothing here is a
        // secret, only a name nothing else has.
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.subsec_nanos());
        let nonce = format!("{}_{stamp}", std::process::id());
        let file = work.join(format!("out-proof-{nonce}.txt"));
        let _ignored = fs::remove_file(&file);
        Self {
            expect: format!("SLOPDESK_OUT_{nonce}_42_END"),
            // `$((6*7))` reaches the REMOTE shell unexpanded, which is the whole point: this
            // process must not compute the 42, or the marker would prove nothing about the host.
            command: format!(
                "echo SLOPDESK_OUT_{nonce}_$((6*7))_END > '{}'; echo SLOPDESK_OUT_{nonce}_$((6*7))_END",
                file.display()
            ),
            file,
        }
    }

    fn landed(&self) -> bool {
        fs::read_to_string(&self.file).is_ok_and(|text| text.contains(&self.expect))
    }
}

/// The key→ingest latency samples the `SLOPDESK_ECHO_PROBE` seam prints on the app's stderr.
///
/// Informational, never a failure: the smoothness-work A/B number, not a gate. The shell took four
/// passes of `grep`/`awk` over the same file to reach it and had to guard every one of them,
/// because a `grep` that matches nothing exits 1 and `set -e` would have taken the whole run down
/// one step before the screenshot.
#[must_use]
fn echo_latency(log: &Log) -> Option<(usize, f64, f64)> {
    let text = log.text();
    let mut samples: Vec<f64> = text
        .lines()
        .filter_map(|line| line.split_once("key→ingest "))
        .filter_map(|(_, rest)| rest.split_once("ms"))
        .filter_map(|(number, _)| number.trim().parse::<f64>().ok())
        .collect();
    if samples.is_empty() {
        return None;
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let count = samples.len();
    // The shell's own index arithmetic, kept: `a[int((NR+1)/2)]` over a 1-based array is the lower
    // median of an even sample, and `int(NR*0.95)` with a floor of 1 is its p95.
    let median = samples.get(count.div_ceil(2) - 1).copied().unwrap_or_default();
    // `int(NR*0.95)` in integers rather than in floats: `count * 95 / 100` IS that floor, exactly,
    // and it cannot round a sample count of 20 to 19.999999999999996 the way the double does.
    #[expect(clippy::integer_division, reason = "the floor is the index being computed")]
    let ninety_fifth_index = (count * 95 / 100).max(1);
    let ninety_fifth = samples.get(ninety_fifth_index - 1).copied().unwrap_or_default();
    Some((count, median, ninety_fifth))
}

/// The launched app, reaped whatever the gate does next.
#[derive(Debug)]
struct App {
    child: Child,
}

impl Drop for App {
    fn drop(&mut self) {
        reap(self.child.id(), "SlopDesk");
        let _ignored = self.child.wait();
    }
}

/// Run the gate.
///
/// # Errors
/// When the build fails, the app dies within the settle window, it comes up with NO window, it
/// mounts nothing, or — under `--connect` — no session is established, the typed command never
/// executes, or one auto-connect attaches anything but exactly one shell.
#[expect(
    clippy::too_many_lines,
    reason = "one gate is one narrative; splitting it hides which assertion follows which"
)]
#[expect(clippy::print_stdout, reason = "the banner is this gate's report")]
pub fn run(root: &Path, mode: Mode) -> Result<(), String> {
    let work = work_dir(root, "macos-verify")?;
    let suite = Suite::for_gate("macos");
    let control = Control::new(root, "macos");
    control.unlink();

    say("macos", "building SlopDesk.app (Debug, unsigned)");
    // [`build_app`] regenerates the project from the committed spec first, which is what keeps the
    // `.xcodeproj` in step. This gate used to have a second, INJECTED spec to build from and a
    // guard to put the committed one back afterwards; the fork that needed the injection is gone.
    let app = build_app(root, &work, "DerivedData")?;
    say("macos", &format!("build OK: {}", app.binary.display()));

    // Built in EVERY mode, because every mode launches a scene and every mode asks it what it
    // mounted.
    say("macos", "building the slopdesk client CLI (the scene observer)");
    build_cli(root)?;
    let census = window_census_binary(root)?;

    let app_log = Log::at(work.join("app-stderr.log"));
    app_log.truncate()?;

    let mut environment = vec![
        // Kept, and now the SECOND lock on the same door. It was the only one:
        // `connection.recentTargets` was the DEVELOPER's, and `connectIfSavedTarget()` — the scene
        // task that runs precisely when `isAutomation` is false — dials whatever host is at the top
        // of it. That host is their live `slopdesk-hostd`, which OWNS the workspace layout, so an
        // automation instance connecting to it reshapes the layout they are working in and no
        // client-side file isolation protects against that. HW-observed 2026-07-28: a decoy
        // listener on the MRU entry took 17 bytes from a default-mode launch, and 0 with this set.
        ("SLOPDESK_SKIP_AUTO_RECONNECT".to_owned(), "1".to_owned()),
    ];

    let connected = if mode == Mode::Connect {
        say(
            "macos",
            &format!("building + starting slopdesk-hostd on 127.0.0.1:{}", port::MACOS),
        );
        crate::hostbin::build(root, false)?;
        let daemon = Hostd::start(root, &work, port::MACOS)?;
        say("macos", &format!("hostd up (pid {})", daemon.pid()));
        let out = OutProof::mint(&work);
        environment.extend([
            ("SLOPDESK_AUTOCONNECT_HOST".to_owned(), "127.0.0.1".to_owned()),
            ("SLOPDESK_AUTOCONNECT_PORT".to_owned(), port::MACOS.to_string()),
            ("SLOPDESK_AUTOTYPE".to_owned(), out.command.clone()),
            ("SLOPDESK_ECHO_PROBE".to_owned(), "1".to_owned()),
        ]);
        Some((daemon, out))
    } else {
        None
    };
    let (hostd, proof) = connected.map_or((None, None), |(daemon, out)| (Some(daemon), Some(out)));

    kill_matching("macos-verify/DerivedData.*MacOS/SlopDesk");
    suite.seed_first_launch()?;
    let app_process = App {
        child: Launch {
            binary: &app.binary,
            container: work.join("client-home"),
            suite: &suite,
            socket: Some(&control.socket),
            log: app_log.path.clone(),
            environment,
            arguments: Vec::new(),
        }
        .spawn()?,
    };
    let pid = app_process.child.id();
    say(
        "macos",
        &format!("launched (pid {pid}); settling {}s", mode.settle().as_secs()),
    );

    // ── the app survived the settle window ──────────────────────────────────────────────────
    thread::sleep(mode.settle());
    if !alive(pid) {
        if let Some(daemon) = &hostd {
            daemon.log.dump("hostd log", 0);
        }
        app_log.dump("app stderr", 40);
        return Err(format!(
            "the app died within {}s of launch (likely a launch/connect crash)",
            mode.settle().as_secs()
        ));
    }
    say("macos", &format!("alive after {}s ✅", mode.settle().as_secs()));

    // ── it has a WINDOW, asserted off the window server, in every mode ──────────────────────
    // The default mode has NOTHING else to say: it carries no auto-connect, so every check below
    // it never runs. Without this it printed `alive after Ns ✅` and screenshotted the bare
    // desktop.
    say(
        "macos",
        &format!("counting the app's on-screen windows (CGWindowList, pid {pid})…"),
    );
    let mut windows = 0;
    let mut seen = String::new();
    let _ignored = poll("a window on screen", 40, || {
        if !alive(pid) {
            return true;
        }
        let (count, diagnosis) = window_count(&census, pid);
        windows = count;
        seen = diagnosis;
        count >= 1
    });
    if windows < 1 {
        complain(&format!(
            "==> FAIL: the app is running with NO window (the window server reports {windows} for pid \
             {pid})."
        ));
        complain(
            "    No window means no scene, and every scene .task seam is dead with it: the auto-connect,",
        );
        complain(
            "    the workspace document, the control socket. A screenshot past this point proves nothing.",
        );
        complain("--- windows the server does attribute to this pid ---");
        complain(if seen.trim().is_empty() {
            "  (none at all)"
        } else {
            &seen
        });
        app_log.dump("app stderr", 40);
        if let Some(daemon) = &hostd {
            daemon.log.dump("hostd log", 0);
        }
        return Err("the app came up with no window".to_owned());
    }
    say(
        "macos",
        &format!("the window server attributes {windows} on-screen window(s) to pid {pid} ✅"),
    );

    // ── …and its SCENE mounted, which is a separate claim ───────────────────────────────────
    // A window is the app's UI; this is the app's STATE. Kept distinct on purpose: it is what the
    // multi-client and launch-restore gates assert their whole projection on, and conflating the
    // two is what made the window check unable to fail.
    say(
        "macos",
        &format!("asking the app what it mounted ({})…", control.socket.display()),
    );
    let mut sessions = 0;
    let _ignored = poll("the control socket to answer", 40, || {
        if !alive(pid) {
            return true;
        }
        sessions = control.windows().map_or(0, |rows| rows.len());
        sessions >= 1
    });
    if sessions < 1 {
        complain(&format!(
            "==> FAIL: the app has a window but mounted nothing ({sessions} sessions over {}).",
            control.socket.display()
        ));
        complain(
            "    Either the control socket never bound — it is a scene .task — or the store came up with",
        );
        complain(
            "    no session at all. Every projection this and the other GUI gates read is dead with it.",
        );
        app_log.dump("app stderr", 40);
        if let Some(daemon) = &hostd {
            daemon.log.dump("hostd log", 0);
        }
        return Err("the app mounted no session".to_owned());
    }
    say(
        "macos",
        &format!("the app mounted {sessions} session(s) and answers on its control socket ✅"),
    );

    if let (Some(daemon), Some(out)) = (&hostd, &proof) {
        connected_half(daemon, out, &app_log)?;
    }

    // ── the picture ─────────────────────────────────────────────────────────────────────────
    // Best-effort: the raise wants Accessibility TCC, no assertion depends on it, and every claim
    // above was read off a socket or off the window server.
    let _ = raise(pid);
    thread::sleep(Duration::from_secs(1));
    let shot = work.join("macos-shot.png");
    screenshot(&shot);
    let mut lines = vec![format!("screenshot: {}", shot.display())];
    if mode == Mode::Connect {
        lines.push(
            "PASS also needs the picture: the terminal renderer showing a LIVE remote shell — prompt,"
                .to_owned(),
        );
        lines.push("ANSI colours, nerd-font glyphs.".to_owned());
    } else {
        lines.push("PASS also needs the picture: the rendered window.".to_owned());
    }
    println!("{}", banner(&lines));
    Ok(())
}

/// The three assertions only `--connect` can make.
///
/// # Errors
/// When no session is established, the typed command never executes, or one auto-connect attaches
/// anything but exactly one shell.
fn connected_half(hostd: &Hostd, proof: &OutProof, app_log: &Log) -> Result<(), String> {
    if super::has_flow(&["-nP", &format!("-iTCP:{}", port::MACOS), "-sTCP:ESTABLISHED"]) {
        say(
            "macos",
            &format!("client↔host session ESTABLISHED on :{} ✅", port::MACOS),
        );
    } else {
        hostd.log.dump("hostd log", 0);
        return Err(format!(
            "no ESTABLISHED session on :{} (the auto-connect did not land)",
            port::MACOS
        ));
    }

    say(
        "macos",
        "waiting for the OUT-path proof (the auto-typed command must EXECUTE on the host)…",
    );
    if poll("the typed command to execute", 24, || proof.landed()).is_err() {
        hostd.log.dump("hostd log", 0);
        return Err(format!(
            "the auto-typed command never executed on the host (no {} in {})",
            proof.expect,
            proof.file.display()
        ));
    }
    say(
        "macos",
        &format!(
            "OUT-path PROVEN: keystrokes → host PTY → shell EXECUTED (computed 42 → {}) ✅",
            proof.expect
        ),
    );

    // ONE auto-connect spawns ONE shell. The terminal autoconnect shape is a LONE terminal pane, so
    // exactly one shell may ever attach; a second means the client mounted a pane, gave it a PTY,
    // and then let the workspace document replace it — the first shell abandoned on the host.
    // Asserted DIRECTLY rather than inferred from the proof above: that used to fail as a side
    // effect of the same bug, because the autotype latch was spent by the pane that got torn down,
    // and the seam now re-arms and rides the replacement pane's connect edge. Nothing else here
    // would have noticed. Read AFTER the proof, so a second attach during the polling still counts.
    let shells = hostd.attached_shells();
    if shells != 1 {
        hostd.log.dump("hostd log", 0);
        return Err(format!(
            "one auto-connect must attach exactly 1 shell; saw {shells}"
        ));
    }
    say("macos", "exactly one shell attached for one auto-connect ✅");

    if let Some((count, median, ninety_fifth)) = echo_latency(app_log) {
        say(
            "macos",
            &format!(
                "echo latency (n={count}): median {median:.1}ms, p95 {ninety_fifth:.1}ms (key→render-feed, \
                 loopback)"
            ),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #![expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
    use super::Mode;

    /// The two spellings that survive, and nothing else.
    ///
    /// `--renderer` was the third, and it is deliberately NOT accepted as a synonym for the
    /// default: it named a second build of a fork that no longer exists, and a flag silently
    /// meaning something else is how a gate goes on reporting green over a thing it stopped doing.
    #[test]
    fn the_modes_are_the_two_that_are_left() {
        assert_eq!(Mode::parse(None), Ok(Mode::Launch));
        assert_eq!(Mode::parse(Some("--connect")), Ok(Mode::Connect));
        assert!(Mode::parse(Some("--renderer")).is_err());
        assert!(Mode::parse(Some("--connect=1")).is_err());
    }

    /// The connect settle is longer, because it covers a TCP connect and a first render rather
    /// than a launch.
    #[test]
    fn connect_settles_longer_than_a_bare_launch() {
        assert!(Mode::Connect.settle() > Mode::Launch.settle());
    }

    /// The OUT-path marker leaves the `$((6*7))` UNEXPANDED — this process must not compute the
    /// 42, or the proof would say nothing about the host. What the file must eventually contain is
    /// the computed form, and the two must not be the same string.
    #[test]
    fn the_typed_command_leaves_the_arithmetic_for_the_remote_shell() {
        let proof = super::OutProof::mint(std::path::Path::new("/tmp"));
        assert!(
            proof.command.contains("$((6*7))"),
            "the arithmetic reaches the remote shell unevaluated: {}",
            proof.command
        );
        assert!(
            !proof.command.contains(&proof.expect),
            "an echo cannot satisfy the proof"
        );
        assert!(proof.expect.contains("_42_END"));
    }

    /// The latency read is one pass and answers a lower median and a p95, on the shell's own index
    /// arithmetic — and an app that printed no timing line at all is `None` rather than zero.
    #[test]
    fn the_echo_probe_reads_a_median_and_a_p95_in_one_pass() {
        let root = std::env::temp_dir().join(format!("slopdesk-gui-echo-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("the scratch directory is creatable");
        let path = root.join("app.log");
        std::fs::write(
            &path,
            "echo-probe armed\nkey→ingest 4.0ms\nkey→ingest 1.0ms\nkey→ingest 3.0ms\nkey→ingest 2.0ms\n",
        )
        .expect("the log is writable");
        let (count, median, ninety_fifth) =
            super::echo_latency(&super::Log::at(path)).expect("four samples were printed");
        assert_eq!(count, 4);
        assert!(
            (median - 2.0).abs() < f64::EPSILON,
            "the lower median of 1,2,3,4 is 2"
        );
        assert!((ninety_fifth - 3.0).abs() < f64::EPSILON);

        let silent = root.join("silent.log");
        std::fs::write(&silent, "echo-probe armed\n").expect("the log is writable");
        assert!(
            super::echo_latency(&super::Log::at(silent)).is_none(),
            "a probe that announced itself and printed nothing is not a sample of zero"
        );
        let _ignored = std::fs::remove_dir_all(&root);
    }
}
