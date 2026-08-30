//! The client instance a gate launches, and the shipping socket it asks what that instance is
//! rendering.
//!
//! ## Why the observation comes off the CLIENT and needs no test seam
//! The claim these gates make is about a client's VIEW, so the observation has to come off the
//! client. Three honest options were weighed when the multi-client gate was written, out loud, in
//! its header: read the host's `workspace-state.json` — rejected, that is the HOST's copy and "the
//! host applied it" is the premise rather than the claim; diff screenshots — rejected as the
//! assertion and kept as evidence, because two windows of one app with anti-aliased text have no
//! mechanical comparison that is not brittle; or ask the client. Asking won, and it costs nothing:
//! `slopdesk --socket … windows|tabs|panes` is served by `WorkspaceControlBackend`, which reads
//! `WorkspaceStore.tree` — the projection of `workspaceMirror.topology`, the exact value the window
//! paints.
//!
//! ## What a signature deliberately leaves out
//! TOPOLOGY only: pane ids, their owning tab, pane kind, tab order, per-tab pane count. Titles, cwd
//! and focus are excluded because `docs/45` §4.1 files them as LIVENESS, pushed on a pane's own
//! control channel, and §8.2 makes focus device-overridable on purpose. Topology is what Phase 5b
//! makes host-owned, and topology is what these gates pin.
//!
//! ## What the port changed
//! The shell concatenated three JSON documents into one pipe and had `python3` pull them apart with
//! a `raw_decode` loop over the byte offset. Each verb is asked and decoded separately here, so a
//! malformed answer names the VERB that produced it — and `serde` rejects a field that changed type
//! where the old reader would have raised a `KeyError` inside a heredoc and printed nothing at all.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::{fmt, fs};

use serde::Deserialize;

use super::Suite;

/// The variable the SHIPPING app reads to bind a named `UserDefaults` suite instead of the standard
/// domain.
///
/// It is spelled here and in `SettingsKey.defaultsSuiteEnvKey`, and nowhere else. The two cannot be
/// one constant: this crate is its OWN workspace with no `path =` edge into the app graph — see the
/// manifest header for why — so neither side can link the other's, and a gate that launches the
/// shipping bundle has no door to ask through. `slopdesk-invariants`' `defaults-suite-env-key`
/// ratchets the two spellings against each other instead, which is what `docs/55`'s "across a
/// socket, the two spellings are ratcheted" prescribes for exactly this shape.
pub const DEFAULTS_SUITE_ENV: &str = "SLOPDESK_DEFAULTS_SUITE";

/// One window (a "session", on the wire) as the client reports it.
#[derive(Debug, Clone, Deserialize)]
pub struct WindowRow {
    /// The session id.
    pub id: String,
    /// How many tabs it holds.
    #[serde(rename = "tabCount")]
    pub tab_count: u32,
}

/// One tab as the client reports it.
#[derive(Debug, Clone, Deserialize)]
pub struct TabRow {
    /// The tab id.
    pub id: String,
    /// The session it belongs to.
    #[serde(rename = "windowId")]
    pub window_id: String,
    /// How many panes it holds.
    #[serde(rename = "paneCount")]
    pub pane_count: u32,
}

/// One pane as the client reports it.
#[derive(Debug, Clone, Deserialize)]
pub struct PaneRow {
    /// The pane id.
    pub id: String,
    /// The tab it belongs to.
    #[serde(rename = "tabId")]
    pub tab_id: String,
    /// `terminal`, `desktop`, and the rest of the pane kinds.
    pub kind: String,
}

/// Everything one client says it is rendering, at one instant.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Projection {
    /// The canonical, order-preserving lines a gate compares.
    pub lines: Vec<String>,
    /// How many tabs the client reports.
    pub tabs: usize,
    /// How many panes the client reports.
    pub panes: usize,
    /// The pane ids, UPPERCASED and sorted — identity and membership, without DFS order.
    pub pane_ids: Vec<String>,
}

impl fmt::Display for Projection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for line in &self.lines {
            writeln!(formatter, "    {line}")?;
        }
        Ok(())
    }
}

/// A client instance addressed by its own control socket.
#[derive(Debug, Clone)]
pub struct Control {
    /// The `slopdesk` CLI, which is how every question here is asked.
    pub cli: PathBuf,
    /// This instance's `SLOPDESK_CLIENT_SOCKET`.
    pub socket: PathBuf,
}

impl Control {
    /// Address an instance.
    ///
    /// `AF_UNIX` paths cap at about 104 bytes and a gate's work directory is already long, so the
    /// socket lives in `/tmp` keyed by this process and by a per-instance tag. Per-run, never the
    /// Application Support default: THAT one is the developer's own running app, and asking it
    /// would answer about a process the gate never launched.
    #[must_use]
    pub fn new(root: &Path, tag: &str) -> Self {
        Self {
            cli: super::cli_binary(root),
            socket: PathBuf::from(format!("/tmp/slopdesk-gate-{}-{tag}.sock", std::process::id())),
        }
    }

    /// Remove the socket file, which a killed instance leaves behind.
    pub fn unlink(&self) {
        let _ = fs::remove_file(&self.socket);
    }

    /// Ask one verb and take its raw JSON, or `None` when the instance does not answer.
    #[must_use]
    fn ask(&self, verb: &str) -> Option<String> {
        let output = Command::new(&self.cli)
            .args(["--socket", &self.socket.to_string_lossy(), verb, "--json"])
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        String::from_utf8(output.stdout).ok()
    }

    /// Whether the instance answers at all — the app is up AND its scene has mounted.
    ///
    /// The bind is a scene `.task`, so an answer means the scene came up far enough to bind the
    /// socket and the store has something to describe.
    #[must_use]
    pub fn answers(&self) -> bool {
        self.windows().is_some()
    }

    /// The sessions the client mounted.
    #[must_use]
    pub fn windows(&self) -> Option<Vec<WindowRow>> {
        serde_json::from_str(&self.ask("windows")?).ok()
    }

    /// The tabs the client is rendering.
    #[must_use]
    pub fn tabs(&self) -> Option<Vec<TabRow>> {
        serde_json::from_str(&self.ask("tabs")?).ok()
    }

    /// The panes the client is rendering.
    #[must_use]
    pub fn panes(&self) -> Option<Vec<PaneRow>> {
        serde_json::from_str(&self.ask("panes")?).ok()
    }

    /// One canonical projection, or `None` when any of the three verbs did not answer.
    ///
    /// `None` and an EMPTY projection are different facts and must stay that way: a read that
    /// FAILED is not a projection that CHANGED, and the launch-restore gate prints a different —
    /// and differently actionable — sentence for each.
    #[must_use]
    pub fn projection(&self) -> Option<Projection> {
        let (windows, tabs, panes) = (self.windows()?, self.tabs()?, self.panes()?);
        let mut lines = Vec::new();
        for window in &windows {
            lines.push(format!("window {} tabs={}", window.id, window.tab_count));
        }
        for tab in &tabs {
            lines.push(format!(
                "tab {} window={} panes={}",
                tab.id, tab.window_id, tab.pane_count
            ));
        }
        for pane in &panes {
            lines.push(format!("pane {} tab={} kind={}", pane.id, pane.tab_id, pane.kind));
        }
        let mut pane_ids: Vec<String> = panes.iter().map(|pane| pane.id.to_uppercase()).collect();
        pane_ids.sort();
        Some(Projection {
            lines,
            tabs: tabs.len(),
            panes: panes.len(),
            pane_ids,
        })
    }
}

/// The environment and the argv every client launch in this family carries.
#[derive(Debug)]
pub struct Launch<'a> {
    /// The bundle binary — never `open`, for the reason in the family's module note.
    pub binary: &'a Path,
    /// This instance's `CFFIXED_USER_HOME` / `HOME`.
    pub container: PathBuf,
    /// The throwaway defaults suite.
    pub suite: &'a Suite,
    /// The control socket to bind, if this instance is to be addressed.
    pub socket: Option<&'a Path>,
    /// Where its stderr goes — the echo probe prints its timing lines there.
    pub log: PathBuf,
    /// The seams this particular gate needs, on top of the four above.
    pub environment: Vec<(String, String)>,
    /// Extra argv AFTER the persistence flag — the launch-restore gate's argument-domain MRU.
    pub arguments: Vec<String>,
}

impl Launch<'_> {
    /// The argv this launch execs, WITHOUT argv[0].
    ///
    /// Split out of [`Self::spawn_reusing`] so the one thing every launch in this family must carry
    /// is checkable without a screen: `-ApplePersistenceIgnoreState YES`, always, first.
    ///
    /// It is load-bearing and its absence is silent. Without it `AppKit` brings the app up on its
    /// persistence path with ZERO windows — no window means no scene, and every seam these four
    /// gates depend on is a scene `.task`: the auto-connect, the workspace-document channel, the
    /// video pane. The process sits in its run loop with no UI, no TCP and no UDP, and the gate
    /// then "proves" whatever the desktop happened to look like. HW-confirmed 2026-07-28: `YES`
    /// ⇒ window + session + frames; omitted or `NO` ⇒ 0 windows, every time.
    ///
    /// It comes FIRST because the launch-restore gate's argument-domain MRU follows it, and Cocoa
    /// reads `-key value` pairs positionally into `NSArgumentDomain`.
    #[must_use]
    pub fn argv(&self) -> Vec<String> {
        let mut argv = vec!["-ApplePersistenceIgnoreState".to_owned(), "YES".to_owned()];
        argv.extend(self.arguments.iter().cloned());
        argv
    }

    /// The environment this launch overrides, in the order it is applied.
    ///
    /// The first three are the isolation every instance in this family gets and none may opt out
    /// of: a container of its own (so it cannot read the developer's Application Support), and
    /// a throwaway defaults suite (because `CFFIXED_USER_HOME` moves Application Support but
    /// NOT `UserDefaults` — cfprefsd resolves the account record, not `HOME`).
    #[must_use]
    pub fn env_overrides(&self) -> Vec<(String, String)> {
        let container = self.container.to_string_lossy().into_owned();
        let mut environment = vec![
            ("CFFIXED_USER_HOME".to_owned(), container.clone()),
            ("HOME".to_owned(), container),
            (DEFAULTS_SUITE_ENV.to_owned(), self.suite.name().to_owned()),
        ];
        if let Some(socket) = self.socket {
            environment.push((
                "SLOPDESK_CLIENT_SOCKET".to_owned(),
                socket.to_string_lossy().into_owned(),
            ));
        }
        environment.extend(self.environment.iter().cloned());
        environment
    }

    /// Exec the bundle binary, appending to the instance's log.
    ///
    /// Appending rather than truncating: a gate that relaunches the same instance three times wants
    /// one transcript, and the phase that truncates does it deliberately.
    ///
    /// # Errors
    /// When the container cannot be made or the binary cannot be spawned.
    pub fn spawn(&self) -> Result<Child, String> {
        super::fresh(&self.container)?;
        self.spawn_reusing()
    }

    /// The same launch, leaving whatever is already in the container ALONE.
    ///
    /// [`super::launchrestore`] is the reason it exists: its whole subject is a RETURNING user, so
    /// its three phases relaunch into one container holding a `workspace.json` the gate seeded and
    /// the app then rewrites. Emptying it between phases would delete the state under test.
    ///
    /// # Errors
    /// When the container cannot be made or the binary cannot be spawned.
    pub fn spawn_reusing(&self) -> Result<Child, String> {
        fs::create_dir_all(&self.container)
            .map_err(|error| format!("{}: {error}", self.container.display()))?;
        let sink = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log)
            .map_err(|error| format!("{}: {error}", self.log.display()))?;
        let errors = sink
            .try_clone()
            .map_err(|error| format!("{}: {error}", self.log.display()))?;

        let mut command = Command::new(self.binary);
        command
            .args(self.argv())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(errors));
        drop(sink);
        for (key, value) in self.env_overrides() {
            command.env(key, value);
        }
        command
            .spawn()
            .map_err(|error| format!("{}: {error}", self.binary.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULTS_SUITE_ENV, PaneRow, Projection, TabRow, WindowRow};

    fn projection_of(windows: &[WindowRow], tabs: &[TabRow], panes: &[PaneRow]) -> Projection {
        let mut lines = Vec::new();
        for window in windows {
            lines.push(format!("window {} tabs={}", window.id, window.tab_count));
        }
        for tab in tabs {
            lines.push(format!(
                "tab {} window={} panes={}",
                tab.id, tab.window_id, tab.pane_count
            ));
        }
        for pane in panes {
            lines.push(format!("pane {} tab={} kind={}", pane.id, pane.tab_id, pane.kind));
        }
        let mut pane_ids: Vec<String> = panes.iter().map(|pane| pane.id.to_uppercase()).collect();
        pane_ids.sort();
        Projection {
            lines,
            tabs: tabs.len(),
            panes: panes.len(),
            pane_ids,
        }
    }

    /// The wire's own key spellings. `tabCount` / `windowId` / `paneCount` are what
    /// `WorkspaceControlBackend` emits, and a rename on either side must fail HERE rather than as a
    /// projection that mysteriously reads zero tabs.
    #[test]
    fn the_three_verbs_decode_the_keys_the_client_actually_emits() {
        let windows: Vec<WindowRow> =
            serde_json::from_str(r#"[{"id":"W1","tabCount":2}]"#).expect("the windows verb decodes");
        let tabs: Vec<TabRow> = serde_json::from_str(r#"[{"id":"T1","windowId":"W1","paneCount":2}]"#)
            .expect("the tabs verb decodes");
        let panes: Vec<PaneRow> = serde_json::from_str(r#"[{"id":"p1","tabId":"T1","kind":"terminal"}]"#)
            .expect("the panes verb decodes");
        assert_eq!(windows[0].tab_count, 2);
        assert_eq!(tabs[0].window_id, "W1");
        assert_eq!(panes[0].kind, "terminal");
    }

    /// A projection keeps tab and DFS pane ORDER in its lines — the order IS the layout, and two
    /// clients showing the same panes in different tabs are not showing the same layout.
    #[test]
    fn a_projection_is_order_preserving() {
        let windows = [WindowRow {
            id: "W".to_owned(),
            tab_count: 1,
        }];
        let tabs = [TabRow {
            id: "T".to_owned(),
            window_id: "W".to_owned(),
            pane_count: 2,
        }];
        let panes = [
            PaneRow {
                id: "b".to_owned(),
                tab_id: "T".to_owned(),
                kind: "terminal".to_owned(),
            },
            PaneRow {
                id: "a".to_owned(),
                tab_id: "T".to_owned(),
                kind: "terminal".to_owned(),
            },
        ];
        let projection = projection_of(&windows, &tabs, &panes);
        assert_eq!(projection.lines, [
            "window W tabs=1",
            "tab T window=W panes=2",
            "pane b tab=T kind=terminal",
            "pane a tab=T kind=terminal",
        ]);
        // …and the id SET is sorted and uppercased, which is the other half: the launch-restore
        // gate's claim is identity and membership, and the fixture spells its uuids in upper case
        // while the client answers in lower.
        assert_eq!(projection.pane_ids, ["A", "B"]);
    }

    /// Two clients with different pane ORDERS do not agree, however equal their id sets are.
    #[test]
    fn two_projections_that_differ_only_in_order_are_not_equal() {
        let window = [WindowRow {
            id: "W".to_owned(),
            tab_count: 1,
        }];
        let tab = [TabRow {
            id: "T".to_owned(),
            window_id: "W".to_owned(),
            pane_count: 2,
        }];
        let pane = |id: &str| {
            PaneRow {
                id: id.to_owned(),
                tab_id: "T".to_owned(),
                kind: "terminal".to_owned(),
            }
        };
        let one = projection_of(&window, &tab, &[pane("a"), pane("b")]);
        let other = projection_of(&window, &tab, &[pane("b"), pane("a")]);
        assert_ne!(one, other);
    }

    /// A launch fixture with nothing gate-specific on it — the FLOOR every instance gets.
    fn bare_launch(suite: &super::Suite) -> super::Launch<'_> {
        super::Launch {
            binary: std::path::Path::new("/tmp/SlopDesk.app/Contents/MacOS/SlopDesk"),
            container: std::path::PathBuf::from("/tmp/gate-container"),
            suite,
            socket: None,
            log: std::path::PathBuf::from("/tmp/gate.log"),
            environment: Vec::new(),
            arguments: Vec::new(),
        }
    }

    /// `-ApplePersistenceIgnoreState YES` is on EVERY launch, and it is FIRST.
    ///
    /// The one contract of this family that is silent when broken: without the flag `AppKit` brings
    /// the app up with zero windows, so no scene mounts and no scene `.task` runs — no
    /// auto-connect, no workspace-document channel, no video pane — while the process sits in
    /// its run loop looking alive. RED before the fix: `check-video.sh` omitted it and the
    /// first hardware run after the docs/45 cutover produced no client window, no session, no
    /// UDP flow and an empty client log, while still printing DONE.
    ///
    /// This pin used to be twenty text-level assertions over `scripts/*.sh` in Swift, because a
    /// shell script has no seam to check. There is exactly ONE launch construction site now and it
    /// is [`super::Launch::argv`], so the net collapses to reading it.
    #[test]
    fn every_launch_carries_the_persistence_flag_first() {
        let suite = super::Suite {
            name: "slopdesk.gate.pin".to_owned(),
        };
        let bare = bare_launch(&suite);
        assert_eq!(bare.argv(), ["-ApplePersistenceIgnoreState", "YES"]);

        // …and a gate's own argv comes AFTER it, never in front: Cocoa reads `-key value` pairs
        // positionally into `NSArgumentDomain`, and the launch-restore gate seeds its MRU that way.
        let mut seeded = bare_launch(&suite);
        seeded.arguments = vec!["-connection.recentTargets".to_owned(), "<hex>".to_owned()];
        assert_eq!(seeded.argv(), [
            "-ApplePersistenceIgnoreState",
            "YES",
            "-connection.recentTargets",
            "<hex>",
        ]);
    }

    /// Every launch is isolated from the developer's own app, on BOTH of the two axes that matter.
    ///
    /// `CFFIXED_USER_HOME`/`HOME` move Application Support; they do NOT move `UserDefaults`,
    /// because cfprefsd resolves the account record rather than `HOME`. The throwaway suite is
    /// the other half, and a launch carrying only one of the two reads a live app's state on
    /// the axis it missed.
    #[test]
    fn every_launch_is_isolated_on_both_axes() {
        let suite = super::Suite {
            name: "slopdesk.gate.pin".to_owned(),
        };
        let environment = bare_launch(&suite).env_overrides();
        let value = |key: &str| {
            environment
                .iter()
                .find(|(name, _)| name == key)
                .map(|(_, value)| value.clone())
        };
        assert_eq!(value("CFFIXED_USER_HOME").as_deref(), Some("/tmp/gate-container"));
        assert_eq!(value("HOME").as_deref(), Some("/tmp/gate-container"));
        assert_eq!(value(DEFAULTS_SUITE_ENV).as_deref(), Some(suite.name()));
        // No socket asked for, so none is bound: an instance nobody addresses must not squat a
        // path.
        assert_eq!(value("SLOPDESK_CLIENT_SOCKET"), None);
    }

    /// A gate's own seams are applied LAST, so a gate can override a default this family sets — and
    /// the socket arrives only when one was asked for.
    #[test]
    fn gate_seams_are_applied_after_the_isolation_floor() {
        let suite = super::Suite {
            name: "slopdesk.gate.pin".to_owned(),
        };
        let socket = std::path::PathBuf::from("/tmp/pin.sock");
        let mut launch = bare_launch(&suite);
        launch.socket = Some(&socket);
        launch.environment = vec![("SLOPDESK_AUTOCONNECT_HOST".to_owned(), "127.0.0.1".to_owned())];
        let environment = launch.env_overrides();
        let names: Vec<&str> = environment.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(names, [
            "CFFIXED_USER_HOME",
            "HOME",
            DEFAULTS_SUITE_ENV,
            "SLOPDESK_CLIENT_SOCKET",
            "SLOPDESK_AUTOCONNECT_HOST",
        ]);
    }

    /// Two instances of one gate never share a socket path, and neither ever collides with the
    /// Application Support default the developer's own app is listening on.
    #[test]
    fn each_instance_gets_a_socket_of_its_own_under_tmp() {
        let root = std::path::Path::new("/nonexistent-repo-root");
        let a = super::Control::new(root, "a");
        let b = super::Control::new(root, "b");
        assert_ne!(a.socket, b.socket);
        assert!(a.socket.starts_with("/tmp"), "AF_UNIX paths cap at ~104 bytes");
        // 104 is the cap; the check is on the full path a `connect(2)` would carry.
        assert!(a.socket.to_string_lossy().len() < 104);
    }
}
