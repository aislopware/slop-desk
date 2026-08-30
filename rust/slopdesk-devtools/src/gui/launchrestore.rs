//! The launch a USER performs, which no other gate can reach.
//!
//! ## Why it exists
//! [`super::macos`]' `--connect`, [`super::video`] and [`super::multiclient`] all set
//! `SLOPDESK_AUTOCONNECT_HOST` or its video twin, so `hasAutomationEnvironment()` is true in all
//! three and the app takes the AUTOMATION branch at launch: `persistence` is nil (no
//! `workspace.json` is read or written), `bootstrapFromEnvironment()` REPLACES the layout with a
//! lone synthetic terminal, `pendingLaunchAdopt` is cleared, and the auto-reconnect task is skipped
//! in favour of an explicit connect. Every one of those is the opposite of what a real launch does.
//!
//! So the shipping launch — restore the saved tree from disk, offer it to the host, silently
//! re-connect to the MRU host — had never had a gate. The commit that fixed its first-connect churn
//! said so in its own message: "the launch-adopt path itself is proven headlessly only: no gate can
//! reach it, because both force the automation bootstrap." That bug blanked every restored terminal
//! on first connect and left a PTY running on the host with nobody attached. This is what would
//! have caught it.
//!
//! ## The three phases
//! - **A — a cold launch against a PRISTINE host.** The client restores the committed fixture (2
//!   tabs, 3 panes) and PROJECTS it: the pane ids it renders are the fixture's OWN ids, not
//!   replacements. The host spawns exactly one shell per restored pane. And it STAYS that way — the
//!   counts are re-read every second for a full watch window, so a churn one turn wide (materialize
//!   → host frame lands → tear down → re-materialize) cannot hide behind a settle. The layout the
//!   app then autosaves still carries those same ids.
//! - **B — a relaunch against the SAME host, now NON-pristine.** `adoptWorkspace` is refused as
//!   stale and the client projects host truth, which is the same layout with the same ids. The
//!   three shells are REATTACHED, not respawned: zero new attach lines and the very same PTY pids.
//!   A relaunch that respawns is a relaunch that abandoned three agents mid-run.
//! - **C — a relaunch whose saved layout names panes this host has never seen.** The case A and B
//!   cannot reach, because in both the client and the host agree on the ids. A client's
//!   `workspace.json` can name panes a host has never heard of: a schema bump that decode-failed to
//!   the default, a layout restored from a backup, the same client meeting a second host. The
//!   client shows it optimistically, offers it, is refused — and the host must spawn NOTHING for
//!   the divergent ids. Not "the fixture's panes were not respawned": the whole log's attach count
//!   must still be three. Measured before this existed: three panes on screen, SIX shells, three of
//!   them abandoned, each having run a real login shell — rc files, Starship, agent `SessionStart`
//!   hooks — before it was killed.
//!
//! ## How it reaches the shipping path with NO new client seam
//! The temptation is an env pair that seeds a layout and fires the reconnect. That would be a
//! second automation bootstrap, and the whole point is that this drives the path a user drives.
//! Everything below is a FIXTURE — state a returning user already has, placed where the shipping
//! code already looks:
//! - the LAYOUT is a `workspace.json` in the client's own Application Support directory, which
//!   `CFFIXED_USER_HOME` redirects per instance,
//! - the SAVED HOST is `connection.recentTargets` in the ARGUMENT DOMAIN. Cocoa parses `-key value`
//!   argv pairs into `NSArgumentDomain`, which outranks the persistent domain, and an old-style
//!   plist `<hex>` value arrives as `Data` — exactly what `AppConnection.loadRecentTargets` reads.
//!   Load-bearing for DETERMINISM: `CFFIXED_USER_HOME` does not redirect `UserDefaults`, so without
//!   an override this would dial whatever the persistent MRU happened to hold. The throwaway suite
//!   empties that MRU as well, and the argument domain still outranks a suite — verified with a
//!   real bundled app.
//! - `firstLaunch.completed`, seeded into the run's own suite, is the same kind of fixture: a user
//!   with a saved layout AND a saved host has by definition finished the first-launch sheet.
//!
//! No `SLOPDESK_AUTOCONNECT_*` is set anywhere, so `hasAutomationEnvironment()` is FALSE and the
//! app runs `WorkspacePersistence.launchTree` + `connectIfSavedTarget()` — the daily-driver pair.
//! That is also self-proving: under the automation branch the restored tree is replaced by a
//! ONE-pane shape, so the 3-pane assertion can only pass on the restore path.
//!
//! ## What the port changed
//! The divergent layout was derived with `uuid5`, which is SHA-1. The derivation here is SHA-256
//! of the same "namespace + original id" pair, formatted as a UUID — the property that matters is
//! that it is STABLE and DISJOINT, both of which are asserted rather than assumed, and neither
//! depends on which digest produced the bytes.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, SystemTime};
use std::{fs, thread};

use regex::Regex;
use serde_json::Value;
use sha2::{Digest as _, Sha256};

use super::control::{Control, Launch, Projection};
use super::{
    Hostd, Log, Suite, alive, banner, build_app, build_cli, complain, daemon_children, dump_children,
    kill_matching, poll, port, pty_pids, reap, say, screenshot, work_dir,
};

/// How long each phase holds its whole claim, re-reading everything each second.
///
/// A churn on this path is ONE TURN wide — a host frame lands, the projection drives the registry,
/// the adopt lands a turn later — so it resolves in well under a second. But it is triggered by a
/// wire round trip, and the point of WATCHING rather than settling is that a late one cannot slip
/// in behind the assertion.
const WATCH_SECONDS: u32 = 30;

/// The saved layout a returning user already has on disk.
const LAYOUT_FIXTURE: &str = "scripts/fixtures/launch-restore-workspace.json";

/// The saved HOST a returning user already has, as `AppConnection.loadRecentTargets` reads it.
///
/// A committed file rather than a `format!` in this module, and that is the one thing keeping both
/// halves of the claim honest. The decode is Swift's — `[ConnectionTarget]`, through `JSONDecoder`
/// — and a `CodingKey` that moved fails SILENTLY: `recentTargets` becomes `[]`,
/// `connectIfSavedTarget()` returns without dialling, and this gate hangs until it times out with
/// no hint of the cause. `LaunchRestoreGateContractTests` decodes this exact file through the
/// shipping type in milliseconds, so the drift is caught in `swift test` rather than eight minutes
/// into a hardware run.
///
/// It is a shared FIXTURE, not a cross-language mirror: neither side reads the other's source, both
/// read this.
const MRU_FIXTURE: &str = "scripts/fixtures/launch-restore-mru.json";

/// `Data` as an old-style plist literal, which is the only form the argument domain carries.
fn hex(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 2);
    for byte in text.bytes() {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// The MRU fixture must name the port THIS gate's daemon binds.
///
/// Two gates on one port is a flake with no relation to either claim — whichever binds second
/// fails, or worse, this client dials another gate's daemon and proves nothing about either. The
/// fixture spells a literal because Swift has to decode it without running any of this; the check
/// is what keeps that literal tied to [`port::LAUNCH_RESTORE`].
///
/// # Errors
/// When the fixture is unreadable as JSON, names no host, or names another gate's port.
fn check_mru_names_this_gates_port(json: &str) -> Result<(), String> {
    let targets: Value = serde_json::from_str(json).map_err(|error| format!("{MRU_FIXTURE}: {error}"))?;
    let port = targets
        .get(0)
        .and_then(|first| first.get("port"))
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("{MRU_FIXTURE} names no saved host with a port"))?;
    if port == u64::from(port::LAUNCH_RESTORE) {
        Ok(())
    } else {
        Err(format!(
            "{MRU_FIXTURE} points the client at :{port}, but this gate's daemon binds :{} — the client \
             would dial somewhere else entirely",
            port::LAUNCH_RESTORE
        ))
    }
}

/// The launch this gate performs, as a value — free of the running daemon a [`Gate`] holds.
///
/// A free function rather than a method so the negative half of this gate's premise is checkable in
/// `cargo test` without spawning anything: it must set NO `SLOPDESK_AUTOCONNECT_*`, because any one
/// of them flips `hasAutomationEnvironment()` and takes the app down a branch where none of the
/// three phases mean anything. A gate that quietly lost its premise still answers its control
/// socket and still screenshots a window, so nothing about the run would name the cause.
fn launch_spec<'a>(
    binary: &'a Path,
    container: PathBuf,
    suite: &'a Suite,
    socket: &'a Path,
    log: PathBuf,
    mru: &str,
) -> Launch<'a> {
    Launch {
        binary,
        container,
        suite,
        socket: Some(socket),
        log,
        // The whole point. Not one seam here, on purpose — see the module note.
        environment: Vec::new(),
        // The MRU arrives through the ARGUMENT DOMAIN, which is determinism rather than style:
        // `CFFIXED_USER_HOME` does not redirect `UserDefaults`, and the argument domain outranks
        // both the persistent domain and the throwaway suite — so the fixture stays the only host
        // this client can dial, whichever gate ran last.
        arguments: vec!["-connection.recentTargets".to_owned(), mru.to_owned()],
    }
}

/// The committed fixture, read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fixture {
    /// The pane ids, in the tree's own DFS order.
    pub panes: Vec<String>,
    /// How many tabs across all sessions.
    pub tabs: usize,
}

impl Fixture {
    /// The projection this fixture demands: counts, and the pane ids as a sorted uppercase set.
    ///
    /// Identity and membership, deliberately — DFS order is already pinned by the counts, and the
    /// fixture spells its uuids in upper case while the client answers in lower.
    #[must_use]
    pub fn wanted(&self) -> (usize, usize, Vec<String>) {
        let mut ids: Vec<String> = self.panes.iter().map(|pane| pane.to_uppercase()).collect();
        ids.sort();
        (self.tabs, self.panes.len(), ids)
    }

    /// Whether a projection IS this fixture.
    #[must_use]
    pub fn matches(&self, projection: &Projection) -> bool {
        let (tabs, panes, ids) = self.wanted();
        projection.tabs == tabs && projection.panes == panes && projection.pane_ids == ids
    }
}

/// Read a workspace document's pane ids and tab count.
///
/// # Errors
/// When the file is not readable as a workspace tree — which is what a schema drift looks like from
/// out here, and it must fail loudly rather than arrive downstream as a mystery one-pane default.
pub fn read_fixture(text: &str) -> Result<Fixture, String> {
    let document: Value = serde_json::from_str(text).map_err(|error| format!("not JSON: {error}"))?;
    let sessions = document
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or_else(|| "no `sessions` array".to_owned())?;
    let mut panes = Vec::new();
    let mut tabs = 0;
    for session in sessions {
        let session_tabs = session
            .get("tabs")
            .and_then(Value::as_array)
            .ok_or_else(|| "a session with no `tabs` array".to_owned())?;
        tabs += session_tabs.len();
        for tab in session_tabs {
            let root = tab.get("root").ok_or_else(|| "a tab with no `root`".to_owned())?;
            leaves(root, &mut panes);
        }
    }
    if panes.is_empty() {
        return Err("the tree has no leaf panes".to_owned());
    }
    Ok(Fixture { panes, tabs })
}

/// Collect a node's leaf pane ids, in DFS order — the shipping encoder's own shape.
fn leaves(node: &Value, into: &mut Vec<String>) {
    if let Some(raw) = node
        .get("leaf")
        .and_then(|leaf| leaf.get("raw"))
        .and_then(Value::as_str)
    {
        into.push(raw.to_owned());
        return;
    }
    let Some(children) = node
        .get("split")
        .and_then(|split| split.get("children"))
        .and_then(Value::as_array)
    else {
        return;
    };
    for child in children {
        if let Some(inner) = child.get("node") {
            leaves(inner, into);
        }
    }
}

/// The namespace the divergent derivation is keyed by — a constant, so a run is reproducible.
const DIVERGENCE_NAMESPACE: &str = "slopdesk/launch-restore/divergent/1";

/// Rewrite every UUID in a document through a stable derivation.
///
/// Derived rather than committed alongside the fixture, and that is deliberate: the claim is "the
/// SAME shape under ids this host has never seen", so it must track the fixture automatically. A
/// second checked-in file would be a second thing to keep in step, and the day it drifted this gate
/// would go on passing while testing a different shape.
///
/// # Errors
/// When the document carries no UUID at all — there would be nothing to diverge.
pub fn diverge(text: &str) -> Result<String, String> {
    let Ok(uuid) = Regex::new(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    else {
        return Err("the uuid pattern did not compile".to_owned());
    };
    let mut seen: BTreeMap<String, String> = BTreeMap::new();
    let rewritten = uuid.replace_all(text, |found: &regex::Captures<'_>| {
        let original = found
            .get(0)
            .map_or_else(String::new, |whole| whole.as_str().to_owned());
        seen.entry(original.clone())
            .or_insert_with(|| derive_uuid(&original))
            .clone()
    });
    if seen.is_empty() {
        return Err("the fixture carries no UUIDs — nothing to diverge".to_owned());
    }
    Ok(rewritten.into_owned())
}

/// One derived id: SHA-256 over the namespace and the original, laid out as a UUID.
///
/// The version and variant nibbles are set so the result is a well-formed UUID rather than merely a
/// hyphenated digest — the client decodes these with a real UUID parser, and a string it rejects
/// would make phase C fail at the seed instead of at the claim.
fn derive_uuid(original: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(DIVERGENCE_NAMESPACE.as_bytes());
    hasher.update(b"\0");
    hasher.update(original.as_bytes());
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(32);
    for byte in digest.iter().take(16) {
        let _ = write!(hex, "{byte:02X}");
    }
    let nibble = |from: usize, to: usize| hex.get(from..to).unwrap_or("0").to_owned();
    format!(
        "{}-{}-4{}-8{}-{}",
        nibble(0, 8),
        nibble(8, 12),
        nibble(13, 16),
        nibble(17, 20),
        nibble(20, 32)
    )
}

/// A file's identity AND its age — inode and modification time together.
///
/// `WorkspacePersistence.save` writes `.atomic`, which is write-aside-then-rename, so a real
/// autosave changes the INODE as well as the mtime. That stays honest even if the fixture is one
/// day regenerated from the app's own encoder and the two files' BYTES coincide.
#[must_use]
fn file_stamp(path: &Path) -> String {
    fs::metadata(path).map_or_else(
        |_| "missing".to_owned(),
        |meta| {
            let modified = meta
                .modified()
                .ok()
                .and_then(|when| when.duration_since(SystemTime::UNIX_EPOCH).ok())
                .map_or(0, |since| since.as_nanos());
            format!("{}:{modified}", meta.ino())
        },
    )
}

/// The client instance one phase launched, reaped whatever the gate does next.
#[derive(Debug)]
struct ClientProcess {
    child: Child,
}

impl Drop for ClientProcess {
    fn drop(&mut self) {
        reap(self.child.id(), "SlopDesk");
        let _ = self.child.wait();
    }
}

/// Everything one run needs to make a claim, in one place.
struct Gate<'a> {
    work: PathBuf,
    app: super::AppBundle,
    suite: &'a Suite,
    control: Control,
    hostd: Hostd,
    fixture: Fixture,
    divergent: Fixture,
    /// The client's own `workspace.json`, where a returning user's layout lives.
    seeded: PathBuf,
    client_log: Log,
    /// A file whose mtime IS this run's start, so a crash-report sweep has something to be newer
    /// than (BSD `find` has no `-newermt`, and neither does anything else worth spawning).
    started: SystemTime,
    /// The MRU entry the auto-reconnect reads, as an argument-domain `Data`.
    mru: String,
}

impl Gate<'_> {
    /// Launch the client with NO autoconnect env — that is the entire point.
    ///
    /// # Errors
    /// When the container cannot be made or the binary cannot be spawned.
    fn launch(&self, phase: &str) -> Result<ClientProcess, String> {
        let child = self.launch_spec().spawn_reusing()?;
        say(
            "launch-restore",
            &format!(
                "{phase}: launched the client (pid {}) with NO autoconnect env",
                child.id()
            ),
        );
        Ok(ClientProcess { child })
    }

    /// What [`Self::launch`] execs, without execing it.
    ///
    /// Split out so the negative half of this gate's premise is checkable in `cargo test`: it must
    /// set NO `SLOPDESK_AUTOCONNECT_*`, because any one of them flips `hasAutomationEnvironment()`
    /// and takes the app down a branch where none of the three phases below mean anything. A gate
    /// that quietly lost its premise still answers its control socket and still screenshots a
    /// window, so nothing about the run would name the cause.
    fn launch_spec(&self) -> Launch<'_> {
        launch_spec(
            &self.app.binary,
            self.container(),
            self.suite,
            &self.control.socket,
            self.client_log.path.clone(),
            &self.mru,
        )
    }

    /// The client's container — ONE across all three phases, because the whole point is that the
    /// same returning user relaunches into the same saved state.
    fn container(&self) -> PathBuf {
        self.work.join("client-home")
    }

    /// How many shells the host has spawned for the fixture's panes, per pane.
    fn spawns_per_fixture_pane(&self) -> Vec<(String, usize)> {
        self.fixture
            .panes
            .iter()
            .map(|pane| {
                (
                    pane.clone(),
                    self.hostd.log.count(&format!("attached for pane {pane}")),
                )
            })
            .collect()
    }

    /// EVERY fixture pane spawned exactly ONE shell — not "the panes spawned three between them".
    ///
    /// The distinction is the whole claim, and the sum alone does not make it. Three over three
    /// panes is equally satisfied by 2 + 1 + 0: one pane torn down and re-dialled with its first
    /// PTY abandoned, while another never got a shell at all. That is precisely the churn this gate
    /// exists to catch, passing the gate's own spawn check — and it then surfaces downstream as the
    /// uninterpretable "3 pane(s) in the layout but 2 live shell(s)", with nothing in the output
    /// saying which pane got two and which got none. Proven against a hand-built log: the old sum
    /// check answered 3 and accepted it.
    fn one_shell_per_pane(&self) -> bool {
        self.spawns_per_fixture_pane()
            .iter()
            .all(|(_, spawns)| *spawns == 1)
    }

    /// How many shells the host has spawned for ANY pane.
    ///
    /// Distinct from the per-fixture-pane count, and phase C is the reason: a client dialling ids
    /// the host has never seen spawns a PTY per id, and every one of those is invisible to a
    /// per-fixture count. This is the number that went to six.
    fn total_spawns(&self) -> usize {
        self.hostd.log.count("attached for pane")
    }

    /// The per-pane breakdown, which is the only form of this number worth printing on a failure:
    /// the sum says a count is wrong, the breakdown says which pane it is wrong FOR.
    fn dump_spawns(&self) {
        complain("==> shells the host spawned, per restored pane:");
        for (pane, spawns) in self.spawns_per_fixture_pane() {
            complain(&format!("    {pane}: {spawns}"));
        }
    }

    /// How many times the host has parked each fixture pane, right now.
    ///
    /// Snapshotted immediately BEFORE a client is stopped and compared against immediately after,
    /// and the baseline is the whole point. The log is never truncated mid-run — the spawn counts
    /// are CUMULATIVE by design — so a bare "has the host parked these?" is satisfied FOR EVER by
    /// the first phase's parking, and every later phase's wait returns on its first poll having
    /// proven nothing. A relaunch that then dials while the previous phase's sessions are still
    /// bound is answered `already attached on another connection`: the panes come up on screen with
    /// DEAD terminals, and not one assertion downstream can see it — they read the workspace
    /// document, which is host truth whether or not anything is attached to it, plus a live-PTY
    /// count the refusal leaves untouched.
    fn detach_counts(&self) -> Vec<(String, usize)> {
        self.fixture
            .panes
            .iter()
            .map(|pane| {
                (
                    pane.clone(),
                    self.hostd.log.count(&format!("detached session {pane}")),
                )
            })
            .collect()
    }

    /// Every fixture pane parked at least once MORE than the baseline recorded — i.e. the host has
    /// observed THIS phase's link go down, not some earlier one's.
    fn detached_since(&self, baseline: &[(String, usize)]) -> bool {
        baseline
            .iter()
            .all(|(pane, before)| self.hostd.log.count(&format!("detached session {pane}")) > *before)
    }

    /// Every fixture pane was REATTACHED — asserted per pane, positively. "No new spawns" alone is
    /// also satisfied by a client that never picked its panes back up at all.
    fn reattached_all(&self) -> bool {
        self.fixture
            .panes
            .iter()
            .all(|pane| self.hostd.log.has(&format!("reattached session {pane}")))
    }

    /// Whether the autosaved layout has become HOST TRUTH.
    ///
    /// Content alone is the whole verdict in phase C, and it cannot be tautological the way phase
    /// A's is: this file was seeded with the DIVERGENT ids, so naming the fixture's three and none
    /// of the divergent three is a state only the app can have written. A client that shows host
    /// truth but keeps offering its refused layout from disk relaunches into the same refusal for
    /// ever.
    fn autosaved_host_truth(&self) -> bool {
        let Ok(saved) = fs::read_to_string(&self.seeded) else {
            return false;
        };
        let lowered = saved.to_lowercase();
        self.fixture
            .panes
            .iter()
            .all(|pane| lowered.contains(&pane.to_lowercase()))
            && self
                .divergent
                .panes
                .iter()
                .all(|pane| !lowered.contains(&pane.to_lowercase()))
    }

    /// Hold the whole claim steady for [`WATCH_SECONDS`], re-reading everything each second.
    ///
    /// The assertion a settle-then-check cannot make: the defect class here is a REPLACEMENT that
    /// lands a wire round trip after the panes are already up and looking right.
    ///
    /// # Errors
    /// When any of the five reads leaves its expected value, naming which one and when.
    fn hold_steady(&self, label: &str, want: usize, client: &ClientProcess) -> Result<(), String> {
        for second in 1..=WATCH_SECONDS {
            // A read that FAILED is a different fact from a projection that CHANGED, and the two
            // are not distinguishable downstream. An unanswered socket used to take the branch
            // below and print "the projection left the restored layout Ns in" above an EMPTY list —
            // the wrong sentence for that state, and unfalsifiable, which is the one message a
            // human cannot act on. Named for what it is instead. Still FATAL, and still on the
            // first sample: the client is supposed to answer, and a gate that waits out its own
            // subject proves nothing.
            let Some(projection) = self.control.projection() else {
                if alive(client.child.id()) {
                    return Err(format!(
                        "{label}: the client is alive but stopped answering its control socket {} {second}s \
                         in. Nothing is known about what it projects — this is NOT a projection that moved.",
                        self.control.socket.display()
                    ));
                }
                return Err(format!("{label}: the client died {second}s in"));
            };
            if !self.fixture.matches(&projection) {
                complain(&format!("==> at second {second} the client projects:"));
                complain(&format!("{projection}"));
                complain("==> the restored layout is:");
                for pane in &self.fixture.panes {
                    complain(&format!("    pane {} kind=terminal", pane.to_uppercase()));
                }
                return Err(format!(
                    "{label}: the projection left the restored layout {second}s in"
                ));
            }
            // Read ONCE per sample: interpolating a helper twice into one message can print two
            // different numbers for one observation, which reads as a gate that cannot count.
            let per_pane: usize = self.spawns_per_fixture_pane().iter().map(|(_, n)| n).sum();
            if per_pane != want || !self.one_shell_per_pane() {
                self.dump_spawns();
                return Err(format!(
                    "{label}: the host had one shell per restored pane and now has {per_pane} across {want} \
                     pane(s) — a restored pane was torn down and re-dialled {second}s in, abandoning its PTY"
                ));
            }
            // …and the count over EVERY pane id, which is strictly stronger: a shell spawned for an
            // id that is not one of the fixture's is invisible to the line above, and that is
            // exactly what a divergent-id launch produces.
            let total = self.total_spawns();
            if total != want {
                complain("==> every pane the host has spawned for:");
                for (pane, spawns) in self.spawns_per_fixture_pane() {
                    complain(&format!("    {spawns} {pane}"));
                }
                return Err(format!(
                    "{label}: the host has spawned {total} shell(s) in total for {want} pane(s) {second}s \
                     in — it was asked for a session id that is not in the layout on screen"
                ));
            }
            // …and the LIVE count, which fails differently again: a churn that re-dials without
            // spawning — a JOIN onto sessions the previous client still holds — leaves the
            // cumulative count untouched while the shells belong to somebody else.
            let census = daemon_children(self.hostd.superd_pid());
            let live = pty_pids(&census).len();
            if live != want {
                dump_children(&census);
                self.report_missing_shell_cause();
                return Err(format!(
                    "{label}: {want} pane(s) in the layout but {live} live shell(s) {second}s in — the \
                     panes are still on screen and their terminals are dead"
                ));
            }
            if !alive(client.child.id()) {
                return Err(format!("{label}: the client died {second}s in"));
            }
            thread::sleep(Duration::from_secs(1));
        }
        say(
            "launch-restore",
            &format!("{label}: layout, spawn count and live shells held for {WATCH_SECONDS}s ✅"),
        );
        Ok(())
    }

    /// WHY a pane has no shell — the gate's most informative red, and on its own its most opaque.
    ///
    /// "3 pane(s) in the layout but 2 live shell(s)" says nothing about the cause, because the host
    /// logs `attached for pane` even for a pane whose child died between `fork()` and `execve()`:
    /// the daemon's own log says everything went fine. What the missing shell leaves behind is a
    /// CRASH REPORT — filed under `slopdesk-hostd`, not under the app, because the corpse is the
    /// forked child and it still carries the parent's name. So all four report directories are
    /// swept, and each report is reduced to the four fields that name a cause. That is the
    /// difference between "two rounds unexplained" and one line naming `PTYProcess.spawn`.
    fn report_missing_shell_cause(&self) {
        let mut out = String::from(
            "======== A PANE HAS NO SHELL — hostd crash reports since this run started ========\n",
        );
        let home = crate::ops::home();
        let mut found = false;
        for directory in [
            home.join("Library/Logs/DiagnosticReports"),
            home.join("Library/Logs/DiagnosticReports/Retired"),
            PathBuf::from("/Library/Logs/DiagnosticReports"),
            PathBuf::from("/Library/Logs/DiagnosticReports/Retired"),
        ] {
            let Ok(entries) = fs::read_dir(&directory) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if !path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("slopdesk-hostd"))
                {
                    continue;
                }
                let newer = entry
                    .metadata()
                    .and_then(|meta| meta.modified())
                    .is_ok_and(|when| when > self.started);
                if !newer {
                    continue;
                }
                found = true;
                let _ = writeln!(out, "  {}", path.display());
                out.push_str(&summarize_crash_report(&path));
            }
        }
        if !found {
            out.push_str(
                "  (none — the shell is missing for some reason OTHER than a child that died pre-exec)\n",
            );
        }
        out.push_str(
            "--- the host's own tail (it logs 'attached for pane' even for a child that never exec'd) ---\n",
        );
        out.push_str(&self.hostd.log.tail(40));
        out.push_str(
            "\n==================================================================================\n",
        );
        let _ = fs::write(self.work.join("missing-shell.txt"), &out);
        complain(&out);
    }
}

/// One `.ips` crash report, reduced to the four fields that name a cause.
///
/// The signal/exception pair, the termination namespace, the `asi` diagnostic strings — this is
/// where "crashed on child side of fork pre-exec" and the libplatform lock messages live — and the
/// faulting thread's top frames. The file is a JSON header LINE followed by a JSON body, which is
/// Apple's own shape and the reason a plain `serde_json::from_str` over the whole file fails.
#[must_use]
fn summarize_crash_report(path: &Path) -> String {
    let Ok(raw) = fs::read_to_string(path) else {
        return "      (unreadable)\n".to_owned();
    };
    let (head, body) = raw.split_once('\n').unwrap_or((raw.as_str(), ""));
    let meta: Value = serde_json::from_str(head).unwrap_or(Value::Null);
    let mut out = format!(
        "      app={} ts={}\n",
        meta.get("app_name").and_then(Value::as_str).unwrap_or("?"),
        meta.get("timestamp").and_then(Value::as_str).unwrap_or("?")
    );
    let Ok(document) = serde_json::from_str::<Value>(body) else {
        out.push_str("      (the body is not JSON — read the file itself)\n");
        return out;
    };
    for field in ["exception", "termination", "asi"] {
        let _ = writeln!(
            out,
            "      {field}={}",
            document
                .get(field)
                .map_or_else(|| "null".to_owned(), Value::to_string)
        );
    }
    let images = document.get("usedImages").and_then(Value::as_array);
    let faulting = document.get("faultingThread").and_then(Value::as_u64);
    if let (Some(threads), Some(index)) = (document.get("threads").and_then(Value::as_array), faulting)
        && let Some(frames) = threads
            .get(usize::try_from(index).unwrap_or(usize::MAX))
            .and_then(|thread| thread.get("frames"))
            .and_then(Value::as_array)
    {
        for frame in frames.iter().take(14) {
            let which = frame.get("imageIndex").and_then(Value::as_u64);
            let name = which
                .and_then(|at| images?.get(usize::try_from(at).ok()?))
                .and_then(|image| image.get("name"))
                .and_then(Value::as_str)
                .unwrap_or("?");
            let _ = writeln!(
                out,
                "        {name} +{} {}",
                frame
                    .get("imageOffset")
                    .map_or_else(String::new, std::string::ToString::to_string),
                frame.get("symbol").and_then(Value::as_str).unwrap_or_default()
            );
        }
    }
    out
}

/// Run the gate.
///
/// # Errors
/// When a build fails, the client dies, it never answers its control socket, it projects anything
/// but the restored layout, the shell count ever leaves the pane count, the autosaved layout loses
/// the restored pane ids, a relaunch respawns a shell instead of reattaching, or a relaunch with
/// divergent ids puts one of them on the wire.
#[expect(
    clippy::too_many_lines,
    reason = "three phases in sequence ARE this gate; splitting them hides which follows which"
)]
pub fn run(root: &Path) -> Result<(), String> {
    let work = work_dir(root, "launch-restore-verify")?;
    let suite = Suite::for_gate("launchrestore");
    let started = SystemTime::now();

    // ── what the fixture says the launch must restore ───────────────────────────────────────
    let fixture_path = root.join(LAYOUT_FIXTURE);
    let fixture_text = fs::read_to_string(&fixture_path).map_err(|error| {
        format!(
            "the committed layout fixture is missing: {} ({error})",
            fixture_path.display()
        )
    })?;
    let fixture = read_fixture(&fixture_text).map_err(|error| {
        format!(
            "the layout fixture {} is not a workspace tree: {error}",
            fixture_path.display()
        )
    })?;
    // The shape this gate is ABOUT: more than one tab, so a pane in a tab the window is not showing
    // must still get its shell; and more than one pane per tab, so a restored SPLIT must survive.
    // Pinned here as well as in `LaunchRestoreGateContractTests`, because a fixture is the easiest
    // thing in the tree to weaken.
    if fixture.panes.len() != 3 || fixture.tabs != 2 {
        return Err(format!(
            "the layout fixture must be 3 panes across 2 tabs (a split plus a second tab); it is {} pane(s) \
             across {} tab(s). Update this gate's assertions deliberately.",
            fixture.panes.len(),
            fixture.tabs
        ));
    }
    say(
        "launch-restore",
        &format!(
            "fixture: {} panes across {} tabs",
            fixture.panes.len(),
            fixture.tabs
        ),
    );

    let divergent_text = diverge(&fixture_text)?;
    let divergent = read_fixture(&divergent_text)?;
    // Self-check: a derivation that quietly produced the SAME ids would make phase C assert
    // nothing.
    let shares_an_id = divergent.panes.iter().any(|pane| {
        fixture
            .panes
            .iter()
            .any(|original| original.eq_ignore_ascii_case(pane))
    });
    if shares_an_id {
        return Err(
            "the divergent layout shares a pane id with the fixture — phase C would test nothing".to_owned(),
        );
    }
    if divergent.panes.len() != fixture.panes.len() {
        return Err(format!(
            "the divergent layout must have the same {} panes as the fixture",
            fixture.panes.len()
        ));
    }
    say(
        "launch-restore",
        &format!("divergent layout derived: {}", divergent.panes.join(" ")),
    );

    say(
        "launch-restore",
        "building slopdesk-hostd + the slopdesk client CLI",
    );
    crate::hostbin::build(root, false)?;
    build_cli(root)?;
    say(
        "launch-restore",
        "generating + building SlopDesk.app (Debug, unsigned)",
    );
    let app = build_app(root, &work, "DD")?;

    let app_pattern = "launch-restore-verify/DD.*MacOS/SlopDesk";
    kill_matching(app_pattern);
    // The daemon starts with NO workspace of its own — phase A's whole claim is that a PRISTINE
    // host takes the layout this client restored, and `adoptWorkspace` answers `rejectedStale` to a
    // host that already has one. A reused directory would silently turn phase A into phase B.
    let hostd = Hostd::start(root, &work, port::LAUNCH_RESTORE)?;
    say(
        "launch-restore",
        &format!(
            "hostd up (pid {}), with no workspace document of its own",
            hostd.pid()
        ),
    );

    let control = Control::new(root, "lr");
    control.unlink();
    let client_log = Log::at(work.join("client.log"));
    client_log.truncate()?;

    let mru_path = root.join(MRU_FIXTURE);
    let mru_json = fs::read_to_string(&mru_path)
        .map_err(|error| format!("{}: {error}", mru_path.display()))?
        .trim()
        .to_owned();
    check_mru_names_this_gates_port(&mru_json)?;
    let mru_hex = hex(&mru_json);

    let gate = Gate {
        work: work.clone(),
        app,
        suite: &suite,
        control,
        hostd,
        seeded: work.join("client-home/Library/Application Support/SlopDesk/workspace.json"),
        fixture,
        divergent,
        client_log,
        started,
        mru: format!("<{mru_hex}>"),
    };

    // ── a returning user's container ────────────────────────────────────────────────────────
    super::fresh(&gate.container())?;
    let parent = gate.seeded.parent().ok_or_else(|| "no parent".to_owned())?;
    fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
    fs::write(&gate.seeded, &fixture_text).map_err(|error| format!("{}: {error}", gate.seeded.display()))?;
    let seeded_stamp = file_stamp(&gate.seeded);
    say(
        "launch-restore",
        &format!("seeded the saved layout at {}", gate.seeded.display()),
    );
    suite.seed_first_launch()?;

    // ── PHASE A — a cold launch against a pristine host ─────────────────────────────────────
    let panes = gate.fixture.panes.len();
    let mut client = gate.launch("phase A")?;
    await_answering(&gate, &client)?;
    // The projection is the claim, and it is also the proof that this is the RESTORE path: the
    // automation bootstrap replaces the tree with a ONE-pane shape, so three fixture-owned pane ids
    // can only come from `workspace.json`.
    await_projection(
        &gate,
        &client,
        "phase A: the client never projected the layout it restored from disk",
    )?;
    say(
        "launch-restore",
        "phase A: the client projects the layout it restored from disk ✅",
    );
    await_spawns(&gate, &client)?;
    say(
        "launch-restore",
        &format!("phase A: the host spawned exactly one shell for each of the {panes} restored panes ✅"),
    );
    gate.hold_steady("phase A", panes, &client)?;

    let census_a = daemon_children(gate.hostd.superd_pid());
    let pids_a = pty_pids(&census_a);
    if pids_a.len() != panes {
        dump_children(&census_a);
        gate.report_missing_shell_cause();
        return Err(format!(
            "phase A: {panes} restored panes but {} live shell(s) on the host",
            pids_a.len()
        ));
    }
    say(
        "launch-restore",
        &format!(
            "phase A: {} live shells for {panes} panes (pids: {pids_a:?}) ✅",
            pids_a.len()
        ),
    );

    // THE OBSERVATION HAS TO MOVE FIRST. Reading the pane ids alone proves nothing here: this file
    // was copied from the fixture, so it ALREADY names all three, and a build whose restore path
    // never autosaves at all leaves the byte-identical fixture on disk and every check below still
    // matches. That build ships a client that loses every layout edit the user makes, under a gate
    // printing ✅. So the app must be shown to have REPLACED the file — a different inode at a
    // later mtime, which is what `.atomic` write-aside-then-rename produces.
    poll(
        "the client to autosave over the layout this gate seeded",
        80,
        || file_stamp(&gate.seeded) != seeded_stamp,
    )?;
    say(
        "launch-restore",
        &format!(
            "phase A: the client REWROTE workspace.json itself ({seeded_stamp} → {}) ✅",
            file_stamp(&gate.seeded)
        ),
    );
    let saved = fs::read_to_string(&gate.seeded)
        .unwrap_or_default()
        .to_lowercase();
    for pane in &gate.fixture.panes {
        if !saved.contains(&pane.to_lowercase()) {
            return Err(format!(
                "phase A: the autosaved layout no longer names restored pane {pane} — the client kept the \
                 SHAPE but replaced the panes, so every reattach after this is a respawn"
            ));
        }
    }
    say(
        "launch-restore",
        &format!("phase A: the layout the client autosaved still names all {panes} restored panes ✅"),
    );

    // ── PHASE B — a relaunch against the same, now NON-pristine, host ───────────────────────
    say("launch-restore", "phase B: stopping the client");
    let baseline = gate.detach_counts();
    drop(client);
    kill_matching(app_pattern);
    gate.control.unlink();
    // Waited on the HOST's own observation of the dropped link, not slept through: until hostd
    // parks the sessions they are still "attached on another connection" and the relaunch's
    // reattach would be refused — a race that would make this gate flaky for a reason that has
    // nothing to do with the claim.
    poll(&format!("the host to park all {panes} sessions"), 60, || {
        gate.detached_since(&baseline)
    })?;
    say(
        "launch-restore",
        &format!("phase B: the host parked all {panes} sessions ✅"),
    );

    client = gate.launch("phase B")?;
    await_answering(&gate, &client)?;
    await_projection(
        &gate,
        &client,
        "phase B: the relaunched client never projected host truth",
    )?;
    say(
        "launch-restore",
        "phase B: the client projects the same layout, now from host truth ✅",
    );
    poll("every parked session to be reattached", 80, || {
        gate.reattached_all()
    })?;
    say(
        "launch-restore",
        &format!("phase B: all {panes} sessions reattached ✅"),
    );
    gate.hold_steady("phase B", panes, &client)?;

    let census_b = daemon_children(gate.hostd.superd_pid());
    let pids_b = pty_pids(&census_b);
    if pids_b != pids_a {
        dump_children(&census_b);
        return Err(format!(
            "phase B: the relaunch did not keep the SAME shells.\n    phase A pids: {pids_a:?}\n    phase B \
             pids: {pids_b:?}"
        ));
    }
    say(
        "launch-restore",
        &format!("phase B: the very same {panes} shells (pids: {pids_b:?}) ✅"),
    );

    // ── PHASE C — a relaunch whose saved layout names panes this host has never seen ────────
    say("launch-restore", "phase C: stopping the client");
    let baseline = gate.detach_counts();
    drop(client);
    kill_matching(app_pattern);
    gate.control.unlink();
    poll(
        &format!("the host to park all {panes} sessions again"),
        60,
        || gate.detached_since(&baseline),
    )?;
    fs::write(&gate.seeded, &divergent_text)
        .map_err(|error| format!("{}: {error}", gate.seeded.display()))?;
    say(
        "launch-restore",
        "phase C: seeded a layout whose panes the host has never seen",
    );

    client = gate.launch("phase C")?;
    await_answering(&gate, &client)?;
    await_projection(
        &gate,
        &client,
        "phase C: the client never projected host truth over its divergent layout",
    )?;
    say(
        "launch-restore",
        "phase C: the client projects HOST truth, not the ids it restored ✅",
    );

    // The assertion this phase exists for, stated per divergent id so a failure names the pane. A
    // single attach line for one of these is a login shell the host forked, ran and then killed for
    // a pane the user never sees.
    for pane in &gate.divergent.panes {
        if gate.hostd.log.has(&format!("attached for pane {pane}")) {
            complain("==> every pane the host has spawned for:");
            for (pane, spawns) in gate.spawns_per_fixture_pane() {
                complain(&format!("    {spawns} {pane}"));
            }
            return Err(format!(
                "phase C: the host spawned a shell for {pane} — an id that is not in any layout on screen. \
                 The client dialled a pane the document was about to replace, and that PTY is abandoned."
            ));
        }
    }
    say(
        "launch-restore",
        &format!("phase C: not one of the {panes} divergent ids reached the host ✅"),
    );
    gate.hold_steady("phase C", panes, &client)?;

    poll(
        "the client to autosave host truth over the divergent layout",
        80,
        || gate.autosaved_host_truth(),
    )?;
    say(
        "launch-restore",
        &format!("phase C: the autosaved layout is now HOST truth — the {panes} divergent ids are gone ✅"),
    );

    let census_c = daemon_children(gate.hostd.superd_pid());
    let pids_c = pty_pids(&census_c);
    if pids_c != pids_a {
        dump_children(&census_c);
        return Err(format!(
                "phase C: the divergent relaunch did not keep the SAME shells.\n    phase A pids: \
                 {pids_a:?}\n    phase C pids: {pids_c:?}"
            ));
    }
    say(
        "launch-restore",
        &format!("phase C: still the very same {panes} shells (pids: {pids_c:?}) ✅"),
    );

    // ── the evidence a human reads ──────────────────────────────────────────────────────────
    // The client's own final projection, read back off the shipping control socket: the value the
    // window paints, in text. Unlike a screenshot it is the same thing the assertions compared.
    println!("\n==> the layout the client reports rendering, at the end:");
    if let Some(projection) = gate.control.projection() {
        print!("{projection}");
    }
    // A full-screen grab as a bonus, labelled for what it actually is. This gate deliberately does
    // NOT raise the client window: coming to the front at launch is automation-only behaviour,
    // faking it would need Accessibility TCC, and no assertion depends on it — so the window is
    // wherever the window manager left it, quite possibly behind everything else. Calling it "the
    // restored window" would be the kind of small lie that makes a gate's output stop being read.
    let shot = work.join("desktop-at-exit.png");
    screenshot(&shot);
    println!(
        "{}",
        banner(&[
            "the shipping launch path is ASSERTED above, not eyeballed.".to_owned(),
            format!(
                "A cold launch restored {panes} panes across {} tabs, the pristine host took that layout and",
                gate.fixture.tabs
            ),
            format!(
                "gave it {panes} shells, a relaunch against the now non-pristine host picked the SAME \
                 {panes}"
            ),
            format!(
                "PTYs back up rather than respawning them, and a relaunch whose saved layout named {panes}"
            ),
            "panes the host has never seen put none of them on the wire.".to_owned(),
            format!(
                "Desktop grab (window NOT raised — see above):  {}",
                shot.display()
            ),
            format!("hostd log:  {}", gate.hostd.log.path.display()),
        ])
    );
    Ok(())
}

/// Wait for the client to answer its control socket, or say how it died.
///
/// A client that exits cleanly writes no crash report and no stderr, so "the client died" alone
/// cannot be told apart from a crash or from something else killing it — and those three want three
/// different investigations.
///
/// # Errors
/// When it dies during launch, or never answers.
fn await_answering(gate: &Gate<'_>, client: &ClientProcess) -> Result<(), String> {
    let pid = client.child.id();
    let mut died = false;
    let waited = poll("the client to answer its control socket", 60, || {
        if !alive(pid) {
            died = true;
            return true;
        }
        gate.control.answers()
    });
    if died {
        gate.client_log.dump("client stderr", 40);
        return Err(format!("the client (pid {pid}) died during launch"));
    }
    waited?;
    say(
        "launch-restore",
        &format!("client answering on {} ✅", gate.control.socket.display()),
    );
    Ok(())
}

/// Wait for the projection, and on timeout say WHAT it saw instead.
///
/// A bare timeout here would report the least useful sentence available: every interesting failure
/// on this path — the host's default pane projected instead, a fourth pane, panes with fresh ids —
/// arrives as a signature that is simply not this one.
///
/// # Errors
/// When the client dies, or never projects the restored layout.
fn await_projection(gate: &Gate<'_>, client: &ClientProcess, what: &str) -> Result<(), String> {
    let pid = client.child.id();
    let mut died = false;
    let waited = poll(what, 80, || {
        if !alive(pid) {
            died = true;
            return true;
        }
        gate.control
            .projection()
            .is_some_and(|projection| gate.fixture.matches(&projection))
    });
    if died {
        gate.client_log.dump("client stderr", 40);
        return Err(format!("{what}: the client died before it projected anything"));
    }
    if waited.is_err() {
        complain("==> the client projects:");
        match gate.control.projection() {
            Some(projection) => complain(&format!("{projection}")),
            None => complain("    (it did not answer)"),
        }
        complain("==> the restored layout is:");
        for pane in &gate.fixture.panes {
            complain(&format!("    pane {} kind=terminal", pane.to_uppercase()));
        }
        return Err(what.to_owned());
    }
    Ok(())
}

/// Wait for exactly one shell per restored pane, and on timeout say what the host actually DID.
///
/// The interesting failure here is an OVERSHOOT, not an absence: a restored pane that is torn down
/// and re-dialled gets a SECOND shell while the first is abandoned, and a bare timeout cannot tell
/// that apart from a client that never connected.
///
/// # Errors
/// When the client dies, or the spawn counts never become one-each.
fn await_spawns(gate: &Gate<'_>, client: &ClientProcess) -> Result<(), String> {
    let pid = client.child.id();
    let mut died = false;
    let waited = poll("one shell per restored pane", 80, || {
        if !alive(pid) {
            died = true;
            return true;
        }
        gate.one_shell_per_pane()
    });
    if died {
        gate.client_log.dump("client stderr", 40);
        return Err("the client died before its panes had shells".to_owned());
    }
    if waited.is_err() {
        gate.dump_spawns();
        gate.report_missing_shell_cause();
        let total: usize = gate.spawns_per_fixture_pane().iter().map(|(_, n)| n).sum();
        return Err(format!(
            "the host must spawn exactly ONE shell for EACH restored pane; it spawned {total} across {} \
             pane(s), unevenly. More than one for a pane means that pane was torn down and re-dialled — the \
             first PTY left running on the host with nobody attached; none for a pane means that pane is on \
             screen with no terminal behind it.",
            gate.fixture.panes.len()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    const TREE: &str = r#"{
      "sessions": [
        { "tabs": [
            { "root": { "split": { "children": [
                { "node": { "leaf": { "raw": "11111111-1111-4111-8111-111111111111" } } },
                { "node": { "leaf": { "raw": "22222222-2222-4222-8222-222222222222" } } }
            ] } } },
            { "root": { "leaf": { "raw": "33333333-3333-4333-8333-333333333333" } } }
        ] }
      ]
    }"#;

    /// The fixture is read as a TREE: a split's leaves in DFS order, and a bare leaf as itself.
    #[test]
    fn a_split_and_a_bare_leaf_both_yield_their_panes() {
        let fixture = super::read_fixture(TREE).expect("the tree reads");
        assert_eq!(fixture.tabs, 2);
        assert_eq!(fixture.panes, [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333",
        ]);
    }

    /// A document that is not a workspace tree fails LOUDLY. A schema drift arriving as a mystery
    /// one-pane default is the failure mode this replaces.
    #[test]
    fn a_document_that_is_not_a_tree_is_an_error_rather_than_an_empty_layout() {
        assert!(super::read_fixture("{}").is_err());
        assert!(super::read_fixture(r#"{"sessions":[]}"#).is_err());
        assert!(super::read_fixture("not json at all").is_err());
    }

    /// The divergence is STABLE — the same input twice gives the same ids, so a run is reproducible
    /// and a red can be reproduced with the same file.
    #[test]
    fn the_divergent_layout_is_the_same_every_time() {
        let once = super::diverge(TREE).expect("the fixture diverges");
        let twice = super::diverge(TREE).expect("the fixture diverges");
        assert_eq!(once, twice);
    }

    /// …and DISJOINT, which is the property phase C rests on: a derivation that quietly produced
    /// the same ids would make the whole phase assert nothing.
    #[test]
    fn the_divergent_layout_shares_no_pane_id_with_the_fixture() {
        let fixture = super::read_fixture(TREE).expect("the tree reads");
        let divergent = super::read_fixture(&super::diverge(TREE).expect("it diverges")).expect("it reads");
        assert_eq!(divergent.panes.len(), fixture.panes.len(), "the SAME shape");
        assert_eq!(divergent.tabs, fixture.tabs);
        for pane in &divergent.panes {
            assert!(
                !fixture
                    .panes
                    .iter()
                    .any(|original| original.eq_ignore_ascii_case(pane)),
                "{pane} is one of the fixture's own"
            );
        }
    }

    /// Every derived id is a WELL-FORMED uuid. The client decodes these with a real parser, so a
    /// string it rejects would fail phase C at the seed rather than at the claim.
    #[test]
    fn every_derived_id_is_a_parseable_uuid() {
        let shape = regex::Regex::new(r"^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-8[0-9A-F]{3}-[0-9A-F]{12}$")
            .expect("the shape compiles");
        let divergent = super::read_fixture(&super::diverge(TREE).expect("it diverges")).expect("it reads");
        for pane in &divergent.panes {
            assert!(shape.is_match(pane), "{pane} is not a uuid");
        }
    }

    /// The COMMITTED fixture is the shape this gate is about: more than one tab, so a pane in a tab
    /// the window is not showing must still get its shell, and more than one pane in a tab, so a
    /// restored SPLIT must survive. `run` refuses to proceed on any other shape; this makes the
    /// same refusal a `cargo test` failure, because a fixture is the easiest thing in the tree
    /// to weaken and a gate that has already built an app is an expensive place to find out.
    #[test]
    fn the_committed_fixture_is_three_panes_across_two_tabs() {
        let root = crate::repo::root(None).expect("the tests run inside the tree");
        let text =
            std::fs::read_to_string(root.join(super::LAYOUT_FIXTURE)).expect("the fixture is committed");
        let fixture = super::read_fixture(&text).expect("the committed fixture is a workspace tree");
        assert_eq!(fixture.tabs, 2);
        assert_eq!(fixture.panes.len(), 3);
        // …and it diverges into the same shape, which is the half phase C rests on.
        let divergent = super::read_fixture(&super::diverge(&text).expect("it diverges")).expect("it reads");
        assert_eq!((divergent.tabs, divergent.panes.len()), (2, 3));
        for pane in &divergent.panes {
            assert!(
                !fixture
                    .panes
                    .iter()
                    .any(|original| original.eq_ignore_ascii_case(pane))
            );
        }
    }

    /// A document with no uuid in it has nothing to diverge, and says so.
    #[test]
    fn a_document_with_no_uuids_cannot_diverge() {
        assert!(super::diverge(r#"{"sessions":[]}"#).is_err());
    }

    /// The wanted projection is counts plus a SORTED, UPPERCASED id set — the fixture spells its
    /// uuids in upper case and the client answers in lower, and identity is the claim.
    #[test]
    fn the_wanted_projection_is_case_folded_and_sorted() {
        let fixture = super::Fixture {
            panes: vec!["bbbb".to_owned(), "aaaa".to_owned()],
            tabs: 1,
        };
        let (tabs, panes, ids) = fixture.wanted();
        assert_eq!((tabs, panes), (1, 2));
        assert_eq!(ids, ["AAAA", "BBBB"]);
    }

    /// The MRU fixture names the port this gate's daemon binds, and nobody else's.
    ///
    /// The committed file carries a LITERAL, because Swift decodes it through `[ConnectionTarget]`
    /// without running any of this. This is the tie between that literal and the ledger — and it
    /// runs in `cargo test`, so a port moved in [`port`] alone is red in milliseconds rather than
    /// eight minutes into a hardware run where the client silently dialled another gate's daemon.
    #[test]
    fn the_committed_mru_fixture_points_at_this_gates_own_port() {
        let root = crate::repo::root(None).expect("the repo root");
        let text = std::fs::read_to_string(root.join(super::MRU_FIXTURE)).expect("the MRU fixture");
        super::check_mru_names_this_gates_port(text.trim()).expect("the fixture names :47423");

        // …and the check is not vacuous.
        let wrong = super::check_mru_names_this_gates_port(
            r#"[{"host":"127.0.0.1","port":47420,"mediaPort":9000,"cursorPort":9001}]"#,
        );
        assert!(wrong.is_err(), "another gate's port must be rejected");
        assert!(
            super::check_mru_names_this_gates_port("[]").is_err(),
            "an empty MRU dials nothing"
        );
    }

    /// Every gate in this family binds a port of its own.
    ///
    /// Two gates on one port is a flake with no relation to either claim: whichever binds second
    /// fails, or the second gate's client dials the first gate's daemon and "proves" its layout.
    /// This used to be four scripts each grepped for the other three's `CONNECT_PORT=`; the ledger
    /// is one `mod` now, so the rule is a set comparison.
    #[test]
    fn the_four_gates_never_share_a_port() {
        let ports = [
            super::port::MACOS,
            super::port::VIDEO,
            super::port::MULTICLIENT,
            super::port::LAUNCH_RESTORE,
        ];
        let mut sorted = ports.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), ports.len(), "two gates share a port: {ports:?}");
    }

    /// This gate sets NO autoconnect seam — that is the whole of why it exists.
    ///
    /// `SLOPDESK_AUTOCONNECT_HOST` (or its video twin) flips `hasAutomationEnvironment()`, and with
    /// it the app drops persistence entirely, replaces the restored tree with a synthetic one-pane
    /// layout, clears `pendingLaunchAdopt` and skips `connectIfSavedTarget()` — every single thing
    /// this gate exercises. It would still answer its control socket and still screenshot a window,
    /// so nothing about a red run would name the cause. Same for `SLOPDESK_SKIP_AUTO_RECONNECT`,
    /// which disables the reconnect this gate exists to drive.
    #[test]
    fn the_launch_carries_no_automation_seam() {
        let suite = super::Suite {
            name: "slopdesk.gate.pin".to_owned(),
        };
        let launch = super::launch_spec(
            std::path::Path::new("/tmp/SlopDesk.app/Contents/MacOS/SlopDesk"),
            std::path::PathBuf::from("/tmp/pin/client-home"),
            &suite,
            std::path::Path::new("/tmp/pin.sock"),
            std::path::PathBuf::from("/tmp/pin/client.log"),
            "<00>",
        );
        let environment = launch.env_overrides();
        let names: Vec<&str> = environment.iter().map(|(name, _)| name.as_str()).collect();
        for banned in [
            "SLOPDESK_AUTOCONNECT_HOST",
            "SLOPDESK_AUTOCONNECT_PORT",
            "SLOPDESK_VIDEO_AUTOCONNECT_HOST",
            "SLOPDESK_SKIP_AUTO_RECONNECT",
        ] {
            assert!(
                !names.contains(&banned),
                "this gate sets {banned}, so the app takes the AUTOMATION branch: no workspace.json, a \
                 synthetic one-pane tree, no auto-reconnect. It would be check-macos twice over."
            );
        }

        // The MRU arrives through the ARGUMENT DOMAIN, and that is determinism rather than style:
        // `CFFIXED_USER_HOME` does not redirect `UserDefaults`, and the argument domain outranks
        // both the persistent domain and the throwaway suite — so the fixture stays the only host
        // this client can dial, whichever gate ran last.
        assert_eq!(launch.argv(), [
            "-ApplePersistenceIgnoreState",
            "YES",
            "-connection.recentTargets",
            "<00>"
        ]);
    }

    /// `Data` in an old-style plist is lower-case hex with no separators, and nothing else decodes.
    #[test]
    fn the_mru_is_carried_as_a_plist_data_literal() {
        assert_eq!(super::hex("[]"), "5b5d");
        assert_eq!(super::hex("~\u{7f}"), "7e7f");
    }
}
