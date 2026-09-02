//! The `docs/45` headline claim on real hardware: TWO clients, ONE layout.
//!
//! ## Why it exists
//! `docs/45-multi-client-state-sync.md` ends Phase 5b with "nobody has yet watched two real clients
//! converge on one layout. That is the open item." Everything under it — the host-owned topology,
//! the intent ops, the optimistic patch, the projection — exists to make one sentence true: a
//! gesture on one client shows up on the other. The headless suite proves each link
//! (`WorkspaceConvergenceTests` two mirrors byte-identical, `WorkspaceDocumentReconcileTests` a
//! document change reconciling the registry, `AutomationBootstrapLaunchTests` a refused adopt
//! snapping back to host truth) and NOTHING composes them in two real processes. This does.
//!
//! ## What it proves
//! - one `slopdesk-hostd` serves TWO macOS client instances, each with its own container,
//! - both open a workspace-document channel (`channelClass 1`),
//! - the second client ABANDONS the layout it minted at launch — its `adoptWorkspace` is refused
//!   against a host that already has one — and projects host truth instead,
//! - a REAL menu gesture on client A (Split Right, New Tab, Close Tab) reaches client B's own
//!   projection, in BOTH directions: a pane appearing and a tab disappearing,
//! - the pane inventory is exact: N panes in the layout ⇒ N live shells on the host,
//! - and no pane was ever minted a SECOND shell — a live census can be waited out, a duplicated
//!   `attached for pane <uuid>` line cannot.
//!
//! ## Why the gesture is a real menu click
//! `Panes ▸ Split Right` is the path a human takes, and driving it proves the command → intent →
//! host → fan-out → projection chain end to end where an env seam would prove only the tail. That
//! makes **Accessibility TCC** a hard requirement for whatever terminal runs this, and the gate
//! says so rather than failing as a mystery.
//!
//! ⚠️ MUST run from a real, unlocked GUI login session. It opens two app windows, raises them and
//! screenshots the screen — Accessibility TCC for the gesture and the arrangement, Screen Recording
//! for the picture.

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

use super::control::{Control, Launch, Projection};
use super::{
    DaemonChild, Hostd, Log, Suite, alive, banner, build_app, build_cli, complain, daemon_children,
    dump_children, is_frontmost, kill_matching, poll, port, pty_pids, raise, reap, say, screenshot, work_dir,
};

/// How long the live-shell count must be REACHED within, in half-seconds.
///
/// The settle covers ONE thing: the host kills a reaped pane's PTY child before it broadcasts the
/// diff a convergence check waits on, so a census can still see a child the kernel has not
/// collected yet. That is milliseconds, not a round trip, and the budget is sized for a loaded
/// machine rather than for a churn — a re-dial is caught by the attach-line check, which no amount
/// of waiting can satisfy.
const LIVE_SHELL_SETTLE: u32 = 8;

/// How long it must be HELD for afterwards, in seconds. A shell that appears LATE must not slip in
/// behind the assertion.
const LIVE_SHELL_HOLD: u32 = 6;

/// One launched instance, addressable and reaped.
#[derive(Debug)]
struct Instance {
    name: &'static str,
    child: Child,
    control: Control,
    log: Log,
}

impl Drop for Instance {
    fn drop(&mut self) {
        reap(self.child.id(), "SlopDesk");
        let _ignored = self.child.wait();
        self.control.unlink();
    }
}

/// Click one menu item on one instance, by unix id.
///
/// The menu bar belongs to the FRONTMOST app, so the raise has to have LANDED before the click —
/// waited on, not slept through: an app that is still coming forward has the other instance's menu
/// bar, and the click would drive the wrong client.
///
/// # Errors
/// When the instance cannot be raised, never becomes frontmost, or the item does not click — each
/// of which is, on this machine, most likely a missing Accessibility grant, and the message says
/// so.
fn click_menu(pid: u32, menu: &str, item: &str) -> Result<(), String> {
    if !raise(pid) {
        return Err(format!(
            "cannot raise pid {pid} via System Events. This gate drives a REAL menu gesture, so the \
             terminal running it needs Accessibility TCC (System Settings ▸ Privacy & Security ▸ \
             Accessibility)."
        ));
    }
    poll(&format!("pid {pid} to become frontmost"), 20, || {
        is_frontmost(pid)
    })?;
    let script = format!(
        "tell application \"System Events\" to tell (first process whose unix id is {pid}) to click (first \
         menu item of menu 1 of menu bar item \"{menu}\" of menu bar 1 whose name starts with \"{item}\")"
    );
    let clicked = Command::new("/usr/bin/osascript")
        .args(["-e", &script])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if !clicked {
        return Err(format!(
            "the '{menu} ▸ {item}' menu item did not click on pid {pid} — either the menu lost the item, or \
             this terminal lacks Accessibility TCC."
        ));
    }
    say("multiclient", &format!("clicked '{menu} ▸ {item}' on pid {pid}"));
    Ok(())
}

/// Wait until BOTH instances report the SAME projection AND it carries the expected counts.
///
/// The counts are the structural predicate, and they are not decoration: without them "both clients
/// still show the OLD layout" satisfies an equality check perfectly.
///
/// # Errors
/// On timeout, printing both projections — what they disagree on is the whole point of the gate.
fn converge(
    what: &str,
    a: &Instance,
    b: &Instance,
    want_tabs: usize,
    want_panes: usize,
) -> Result<(), String> {
    let mut last: (Option<Projection>, Option<Projection>) = (None, None);
    for _ in 0..40 {
        let sig_a = a.control.projection();
        let sig_b = b.control.projection();
        if let (Some(one), Some(other)) = (&sig_a, &sig_b)
            && one == other
            && one.tabs == want_tabs
            && one.panes == want_panes
        {
            say(
                "multiclient",
                &format!(
                    "{what}: both clients project {want_tabs} tab(s) / {want_panes} pane(s), identically ✅"
                ),
            );
            return Ok(());
        }
        last = (sig_a, sig_b);
        thread::sleep(super::TICK);
    }
    for (name, projection) in [("A", &last.0), ("B", &last.1)] {
        complain(&format!("==> client {name} projects:"));
        match projection {
            Some(seen) => complain(&format!("{seen}")),
            None => complain("    (it did not answer its control socket)"),
        }
    }
    Err(format!(
        "{what}: the two clients did not converge on {want_tabs} tab(s) / {want_panes} pane(s)"
    ))
}

/// Run the gate.
///
/// # Errors
/// When a build fails, a client dies, either never opens a workspace channel, the two projections
/// ever disagree, a gesture never lands, or the shell count does not match the layout.
#[expect(
    clippy::too_many_lines,
    reason = "one gate is one narrative; splitting it hides which assertion follows which"
)]
#[expect(clippy::print_stdout, reason = "the census is this gate's report")]
pub fn run(root: &Path) -> Result<(), String> {
    let work = work_dir(root, "multiclient-verify")?;
    let suite = Suite::for_gate("multiclient");

    say("multiclient", "building slopdesk-hostd + the slopdesk client CLI");
    crate::hostbin::build(root, false)?;
    build_cli(root)?;
    say(
        "multiclient",
        "generating + building SlopDesk.app (Debug, unsigned)",
    );
    let app = build_app(root, &work, "DD")?;

    let app_pattern = "multiclient-verify/DD.*MacOS/SlopDesk";
    kill_matching(app_pattern);
    let hostd = Hostd::start(root, &work, port::MULTICLIENT)?;
    say("multiclient", &format!("hostd up (pid {})", hostd.pid()));
    suite.seed_first_launch()?;

    // A first, and its DOCUMENT CHANNEL live, before B exists at all. That ordering is what puts
    // A's `adoptWorkspace` in front of B's: the client stages the adopt as soon as its channel goes
    // live, the host serialises intents on one actor, and at this instant B has no connection to
    // race with. So A's layout is the one the host keeps, and B arrives at a host that ALREADY has
    // one — the real second-device shape, and the case where the refusal path has to work.
    let a = launch(&app, &suite, &work, root, "A")?;
    await_answering(&a)?;
    poll("client A's workspace document channel", 40, || {
        hostd.accepted_channels() == 1
    })?;
    let b = launch(&app, &suite, &work, root, "B")?;
    await_answering(&b)?;

    say(
        "multiclient",
        &format!(
            "waiting for TWO workspace document channels on :{}…",
            port::MULTICLIENT
        ),
    );
    let _ignored = poll("two workspace channels", 40, || hostd.accepted_channels() == 2);
    let channels = hostd.accepted_channels();
    if channels != 2 {
        hostd.log.dump("hostd log", 0);
        return Err(format!(
            "expected 2 accepted workspace channels (one per client); saw {channels}"
        ));
    }
    say(
        "multiclient",
        "both clients hold a workspace document channel (channelClass 1) ✅",
    );

    // B launched with the same automation bootstrap as A, so it minted its own session, tab and
    // pane and mounted them before any document existed. Its `adoptWorkspace` then met a host that
    // already had one and came back `rejectedStale`. Agreeing here means B threw its own ids away
    // and took A's — convergence from two DIFFERENT starting layouts, which is a stronger claim
    // than starting empty.
    converge("baseline", &a, &b, 1, 1).map_err(|error| fail(&hostd, &a, &b, &error))?;

    // A SPLIT: a pane only client A's gesture could have created must appear in B's projection.
    click_menu(a.child.id(), "Panes", "Split Right").map_err(|error| fail(&hostd, &a, &b, &error))?;
    converge("after A splits", &a, &b, 1, 2).map_err(|error| fail(&hostd, &a, &b, &error))?;
    // A NEW TAB: a whole tab object, minted client-side and accepted by the host.
    click_menu(a.child.id(), "Tabs", "New Tab").map_err(|error| fail(&hostd, &a, &b, &error))?;
    converge("after A opens a tab", &a, &b, 2, 3).map_err(|error| fail(&hostd, &a, &b, &error))?;
    // A CLOSE: convergence has to work in the REMOVING direction too, and a close is the op that
    // has to agree on a SUCCESSOR as well as on the set (the shared MRU ring).
    click_menu(a.child.id(), "Tabs", "Close Tab").map_err(|error| fail(&hostd, &a, &b, &error))?;
    converge("after A closes that tab", &a, &b, 1, 2).map_err(|error| fail(&hostd, &a, &b, &error))?;

    // ── N panes ⇒ N shells ──────────────────────────────────────────────────────────────────
    // Counted as LIVE children of the daemon rather than as log lines: the cumulative attach count
    // also includes the pane B minted at launch and the pane the closed tab took with it, both of
    // which were reaped — a leak is a shell that is still THERE.
    let Some(final_projection) = a.control.projection() else {
        return Err(fail(
            &hostd,
            &a,
            &b,
            "client A stopped answering before the census",
        ));
    };
    let panes = final_projection.panes;
    let live = |census: &[DaemonChild]| pty_pids(census).len();
    let _ignored = poll(
        "the live shell count to reach the pane count",
        LIVE_SHELL_SETTLE,
        || live(&daemon_children(hostd.superd_pid())) == panes,
    );
    // REACHED, then HELD — never a single read the instant `converge` returns.
    let census = daemon_children(hostd.superd_pid());
    if live(&census) != panes {
        #[expect(
            clippy::integer_division,
            reason = "the settle is an even count of whole seconds"
        )]
        let half_settle = LIVE_SHELL_SETTLE / 2;
        return Err(census_failed(
            &hostd,
            &census,
            panes,
            &format!("and stayed there for {half_settle}s — that is a leak, not a churn"),
        ));
    }
    for second in 1..=LIVE_SHELL_HOLD {
        thread::sleep(Duration::from_secs(1));
        let census = daemon_children(hostd.superd_pid());
        if live(&census) != panes {
            return Err(census_failed(
                &hostd,
                &census,
                panes,
                &format!("{second}s after the counts matched — a pane was re-dialled behind the check"),
            ));
        }
    }
    say(
        "multiclient",
        &format!(
            "{panes} pane(s) in the layout, {panes} live shell(s) on the host, held {LIVE_SHELL_HOLD}s ✅"
        ),
    );

    // ── ONE pane, ONE shell, EVER — the assertion a churn cannot outlive ────────────────────
    // The census above counts what is ALIVE, so anything that spawns and dies inside the settle is
    // invisible to it. That is exactly the shape of the bug this keeps closed: the tab close made
    // client B re-dial the dying pane in the window between the host's `channelClose` and the
    // document diff removing it, and a pane channel naming a session the host no longer has is a
    // SPAWN — a whole login shell, rc files and all, for a pane the user had just closed. It was
    // transient, so a live count could only ever be told to wait it out.
    //
    // `attached for pane <uuid>` is the host's own line for MINTING a shell, one per pane per
    // lifetime; a second client fanning onto the same pane logs `joined live session … as
    // subscriber` instead. So the same uuid appearing twice is a second shell for one pane, it is
    // written down permanently, and no settle can make it go away.
    let doubled = panes_minted_twice(&hostd.log);
    if !doubled.is_empty() {
        complain("--- panes the host minted a shell for more than once ---");
        for line in hostd
            .log
            .text()
            .lines()
            .filter(|line| line.contains("attached for pane "))
        {
            complain(line);
        }
        return Err(fail(
            &hostd,
            &a,
            &b,
            &format!(
                "{} pane(s) got a SECOND shell — a pane was re-dialled after the host retired its channel: \
                 {}",
                doubled.len(),
                doubled.join(" ")
            ),
        ));
    }
    say(
        "multiclient",
        &format!(
            "{} shell mint(s), no pane minted twice ✅",
            hostd.log.count("attached for pane ")
        ),
    );

    // ── PTY fan-out — a SEPARATE claim, and UNCONDITIONAL ───────────────────────────────────
    // Asserted POSITIVELY, per pane. A negative — counting refusals and expecting none — is
    // satisfied by a second client that never tried to attach at all, and by a host that has no
    // refusal to log. Only the positive distinguishes "both clients hold this PTY" from "nothing
    // happened". There is no mode in which this is skipped: sharing a pane is what the host does,
    // so a run that did not observe it observed a broken host.
    for line in &final_projection.lines {
        let Some(pane) = line.strip_prefix("pane ").and_then(|rest| rest.split(' ').next()) else {
            continue;
        };
        if !hostd
            .log
            .has(&format!("joined live session {pane} as subscriber"))
        {
            return Err(fail(
                &hostd,
                &a,
                &b,
                &format!("no second subscriber ever joined pane {pane} — the JOIN route did not run for it"),
            ));
        }
    }
    say(
        "multiclient",
        &format!("fan-out: all {panes} pane(s) took a second subscriber ✅"),
    );

    // ── the picture a human reads ───────────────────────────────────────────────────────────
    arrange_and_shoot(&work, &a, &b);
    println!(
        "{}",
        banner(&[
            "the two-client claim is ASSERTED above, not eyeballed. What is left is the picture.".to_owned(),
            format!("read  {}", work.join("both-clients.png").display()),
            format!("      {}", work.join("client-A.png").display()),
            format!("      {}", work.join("client-B.png").display()),
            "PASS = both windows show the SAME tab rail and the SAME split — one layout, two clients."
                .to_owned(),
            format!("hostd log:  {}", hostd.log.path.display()),
        ])
    );
    Ok(())
}

/// Launch one instance with a container and a control socket of its own.
///
/// `CFFIXED_USER_HOME` gives each its own Application Support container, so the two do not share
/// `workspace-cache.json` or `device-prefs.json`. It does NOT redirect `UserDefaults`, so both read
/// one domain — which is why nothing here depends on a per-instance default, and why the throwaway
/// suite is SHARED between them on purpose: the pair are meant to agree, and what is being kept out
/// is the developer's own `connection.recentTargets`.
///
/// # Errors
/// When the instance cannot be spawned.
fn launch(
    app: &super::AppBundle,
    suite: &Suite,
    work: &Path,
    root: &Path,
    name: &'static str,
) -> Result<Instance, String> {
    say("multiclient", &format!("launching client {name}"));
    let control = Control::new(root, &name.to_lowercase());
    control.unlink();
    let log = Log::at(work.join(format!("client-{name}.log")));
    log.truncate()?;
    let child = Launch {
        binary: &app.binary,
        container: work.join(format!("client-{name}-home")),
        suite,
        socket: Some(&control.socket),
        log: log.path.clone(),
        environment: vec![
            ("SLOPDESK_AUTOCONNECT_HOST".to_owned(), "127.0.0.1".to_owned()),
            (
                "SLOPDESK_AUTOCONNECT_PORT".to_owned(),
                port::MULTICLIENT.to_string(),
            ),
        ],
        arguments: Vec::new(),
    }
    .spawn()?;
    Ok(Instance {
        name,
        child,
        control,
        log,
    })
}

/// Wait for an instance to answer on its control socket — the app is up AND its scene has mounted.
///
/// # Errors
/// When it dies during launch, or never answers.
fn await_answering(instance: &Instance) -> Result<(), String> {
    let pid = instance.child.id();
    let mut died = false;
    let waited = poll(
        &format!("client {} to answer its control socket", instance.name),
        40,
        || {
            if !alive(pid) {
                died = true;
                return true;
            }
            instance.control.answers()
        },
    );
    if died {
        instance.log.dump(&format!("client {} stderr", instance.name), 40);
        return Err(format!("client {} (pid {pid}) died during launch", instance.name));
    }
    waited?;
    say(
        "multiclient",
        &format!(
            "client {} up (pid {pid}), answering on {} ✅",
            instance.name,
            instance.control.socket.display()
        ),
    );
    Ok(())
}

/// Every pane id the host minted a shell for MORE than once.
///
/// A pure read of the log, so the trap it guards can be stated as a test rather than as a comment.
#[must_use]
fn panes_minted_twice(log: &Log) -> Vec<String> {
    let mut counts: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for line in log.text().lines() {
        if let Some((_, pane)) = line.split_once("attached for pane ") {
            let id = pane.split_whitespace().next().unwrap_or_default();
            if !id.is_empty() {
                *counts.entry(id.to_owned()).or_default() += 1;
            }
        }
    }
    counts
        .into_iter()
        .filter_map(|(pane, seen)| (seen > 1).then_some(pane))
        .collect()
}

/// Dump the evidence every failure path shares, and hand back the message.
///
/// One place, so a red run never needs a second one to diagnose.
fn fail(hostd: &Hostd, a: &Instance, b: &Instance, why: &str) -> String {
    complain(&format!("==> FAIL: {why}"));
    hostd.log.dump("hostd log", 0);
    a.log.dump("client A stderr", 40);
    b.log.dump("client B stderr", 40);
    why.to_owned()
}

/// Report a census that went red FROM THAT SAMPLE, never from a fresh read.
///
/// A helper lives for tens of milliseconds, so a re-read prints a different set of children than
/// the one the count was made from.
fn census_failed(hostd: &Hostd, census: &[DaemonChild], panes: usize, when: &str) -> String {
    dump_children(census);
    let why = format!(
        "the layout has {panes} pane(s) but the host is running {} shell(s) {when}",
        pty_pids(census).len()
    );
    complain(&format!("==> FAIL: {why}"));
    hostd.log.dump("hostd log", 0);
    why
}

/// Both windows side by side in one frame, plus one full-screen grab per client with that client
/// raised — so the proof survives a window arrangement that did not take.
fn arrange_and_shoot(work: &Path, a: &Instance, b: &Instance) {
    // Guarded rather than trusted: Finder scripting is a separate TCC grant, and an unparseable
    // answer must not take the arithmetic — and with it the whole gate — down after every assertion
    // has passed.
    let screen_width = crate::proc::ask(
        "/usr/bin/osascript",
        &[
            "-e",
            "tell application \"Finder\" to get item 3 of (get bounds of window of desktop)",
        ],
        Path::new("/"),
    )
    .and_then(|answer| answer.trim().parse::<i64>().ok())
    .unwrap_or(1920);
    #[expect(clippy::integer_division, reason = "a window width is whole points")]
    let half = (screen_width / 2 - 30).max(600);

    let mut x = 20;
    for instance in [a, b] {
        for script in [
            format!(
                "tell application \"System Events\" to tell (first process whose unix id is {}) to set \
                 position of window 1 to {{{x}, 60}}",
                instance.child.id()
            ),
            format!(
                "tell application \"System Events\" to tell (first process whose unix id is {}) to set size \
                 of window 1 to {{{half}, 760}}",
                instance.child.id()
            ),
        ] {
            let _ignored = Command::new("/usr/bin/osascript")
                .args(["-e", &script])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        x += half + 20;
    }
    thread::sleep(Duration::from_secs(1));
    screenshot(&work.join("both-clients.png"));
    for instance in [a, b] {
        let _ = raise(instance.child.id());
        thread::sleep(Duration::from_millis(800));
        screenshot(&work.join(format!("client-{}.png", instance.name)));
    }
}

#[cfg(test)]
mod tests {
    #![expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
    use std::path::PathBuf;

    /// A scratch log holding `text`, at a path NO other test in this binary can be writing.
    ///
    /// The pid alone is not enough and the miss is a genuine flake: cargo runs a module's tests as
    /// parallel THREADS of one process, so every caller here resolved to the same
    /// `slopdesk-mc-<pid>/hostd.log` and each write raced the others' reads. It failed as
    /// `a_second_subscriber_is_not_a_second_shell` reading a double-mint fixture — the one test in
    /// the file whose subject is that a double-mint is NOT reported.
    fn log_of(text: &str) -> super::Log {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let seat = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("slopdesk-mc-{}-{seat}", std::process::id()));
        std::fs::create_dir_all(&root).expect("the scratch directory is creatable");
        let path = root.join("hostd.log");
        std::fs::write(&path, text).expect("the log is writable");
        super::Log::at(path)
    }

    /// One pane minted twice is named, and a pane minted once is not.
    #[test]
    fn a_pane_the_host_gave_two_shells_is_named() {
        let log = log_of(
            "slopdesk-hostd: shell 1 attached for pane AAAA\nslopdesk-hostd: shell 2 attached for pane \
             BBBB\nslopdesk-hostd: shell 3 attached for pane AAAA\n",
        );
        assert_eq!(super::panes_minted_twice(&log), ["AAAA"]);
    }

    /// A JOIN is not a mint. A second client fanning onto a pane logs `joined live session … as
    /// subscriber`, and reading that as a second shell would fail the gate on the very behaviour it
    /// asserts one section later.
    #[test]
    fn a_second_subscriber_is_not_a_second_shell() {
        let log = log_of(
            "slopdesk-hostd: shell 1 attached for pane AAAA\nslopdesk-hostd: joined live session AAAA as \
             subscriber\nslopdesk-hostd: joined live session AAAA as subscriber\n",
        );
        assert!(super::panes_minted_twice(&log).is_empty());
    }

    /// A log with no attach line at all is not a double-mint — it is the failure the LIVE census
    /// reports, and this check must not claim it first.
    #[test]
    fn a_host_that_minted_nothing_reports_no_duplicates() {
        assert!(super::panes_minted_twice(&super::Log::at(PathBuf::from("/nonexistent"))).is_empty());
    }
}
