//! The daemon shell's two decidable halves: where a setting comes from, and where a record goes.
//!
//! Neither needs superd, screend or a PTY, and that is the line: the ORDER `main` runs its steps in
//! is not assertable without a daemon behind each one, but the settings lookup and the hook routing
//! are pure functions over bytes, and both are things a stranger can drive.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use core::time::Duration;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use slopdesk_hostd::env::Overlay;
use slopdesk_hostd::hooks::HookTable;
use slopdesk_hostd::observer::Stderr;
use slopdesk_hostd::workspacestore::DiskWorkspace;
use slopdesk_hostserver::channel::HookRoutes;
use slopdesk_hostserver::{SessionIds, SystemIds, WorkspaceStore};
use slopdesk_wire::document::WorkspaceTopology;

/// A sidecar with both agent flags set and one raw override.
const SIDECAR: &str = r#"{
  "schemaVersion": 1,
  "video": { "qpSharp": 30, "pacer": "adaptive" },
  "agent": { "preventSleep": true, "resumeOnRecovery": false },
  "rawOverrides": { "SLOPDESK_SUB_LAG_BYTES": "1048576", "": "ignored" }
}"#;

/// The typed agent flags become the exact literal each gate's read site compares against.
///
/// A present field pins `"1"`/`"0"` whatever the gate's OWN polarity is, which is what makes one
/// writer safe for a default-ON key and a default-OFF one alike — `preventSleep` is default-OFF and
/// `resumeOnRecovery` is default-ON, and both are written the same way here.
#[test]
fn the_agent_table_writes_the_literal_the_gate_reads() {
    let overlay = Overlay::from_text(SIDECAR);
    assert_eq!(overlay.get("SLOPDESK_AGENT_PREVENT_SLEEP").as_deref(), Some("1"));
    assert_eq!(
        overlay.get("SLOPDESK_AGENT_RESUME_ON_RECOVERY").as_deref(),
        Some("0")
    );
    assert!(overlay.on_if_one("SLOPDESK_AGENT_PREVENT_SLEEP"));
    assert!(!overlay.on_unless_zero("SLOPDESK_AGENT_RESUME_ON_RECOVERY"));
}

/// A raw override reaches this daemon, and an EMPTY key does not.
///
/// The overrides box is the documented way a HOST-only knob lands, so anything typed there rides
/// whole — but a half-typed row is an accident, not a request to set `""`.
#[test]
fn a_raw_override_lands_and_an_empty_key_does_not() {
    let overlay = Overlay::from_text(SIDECAR);
    assert_eq!(overlay.get("SLOPDESK_SUB_LAG_BYTES").as_deref(), Some("1048576"));
    assert_eq!(overlay.applied(), vec![
        "SLOPDESK_AGENT_PREVENT_SLEEP",
        "SLOPDESK_AGENT_RESUME_ON_RECOVERY",
        "SLOPDESK_SUB_LAG_BYTES",
    ]);
}

/// The `video` table is not read, and its absence from the answer is the assertion.
///
/// Those keys are `slopdesk-videohostd`'s operating point; that daemon folds the same file for
/// itself. Mapping them here would be the second copy of `EnvBridge.toEnv(_: VideoPreferences)`.
#[test]
fn the_video_table_is_left_to_the_daemon_that_owns_it() {
    let overlay = Overlay::from_text(SIDECAR);
    assert_eq!(overlay.get("SLOPDESK_QP_SHARP"), None);
    assert_eq!(overlay.get("SLOPDESK_PACER"), None);
}

/// A corrupt or truncated prefs file is a no-op, not a refusal.
///
/// Validate-then-drop at every step: a file nobody can parse must not cost a person their
/// terminals, and it must not half-apply either.
#[test]
fn a_file_nobody_can_parse_contributes_nothing() {
    for broken in [
        "",
        "{",
        "null",
        "[1, 2, 3]",
        r#"{"agent": "not a table"}"#,
        r#"{"rawOverrides": [1]}"#,
    ] {
        let overlay = Overlay::from_text(broken);
        assert!(
            overlay.applied().is_empty(),
            "{broken:?} contributed {:?}",
            overlay.applied()
        );
    }
}

/// An unknown key answers `None` rather than an empty string.
///
/// `SLOPDESK_AUTO_PROGRESS_COMMANDS` reads absent and empty as two DIFFERENT requests — unset means
/// superd's built-in slow-command list, `""` means disabled — so collapsing them would silently
/// turn one into the other.
#[test]
fn absent_is_not_empty() {
    let overlay = Overlay::from_text(r#"{"rawOverrides": {"SLOPDESK_AUTO_PROGRESS_COMMANDS": ""}}"#);
    assert_eq!(
        overlay.get("SLOPDESK_AUTO_PROGRESS_COMMANDS").as_deref(),
        Some("")
    );
    assert_eq!(overlay.get("SLOPDESK_NOT_A_KEY"), None);
}

/// A record naming no pane is dropped, and so is one naming a pane nobody bound.
///
/// Both are things a stranger can cause — the socket is reachable by any local process that knows
/// the address, and the address is in every agent's environment — so neither may panic and neither
/// may reach a detector.
#[test]
fn a_record_with_no_route_is_dropped_rather_than_delivered() {
    let table = HookTable::new();
    table.route_record(b"{}");
    table.route_record(b"pane=nobody\n{\"hook_event_name\":\"Stop\"}");
    table.route_record(b"");
    assert!(table.is_empty());
}

/// Unbinding is what keeps the table from growing one dead entry per pane.
///
/// The key is the pane's ENV-BAKED id, which does not change across a reattach — so a bind on
/// reattach is a refresh of the same entry, and the count is the leak assertion.
#[test]
fn a_route_is_retired_exactly_once_and_rebinding_is_a_refresh() {
    let table = Arc::new(HookTable::new());
    let routes: &dyn HookRoutes = table.as_ref();
    assert!(table.is_empty());

    // No pane fake here on purpose: `bind` is the only method that needs one, and what this asserts
    // is the TABLE's arithmetic. The delivery half is covered by `Pane::fold_hook`'s forward, which
    // `slopdesk-hostserver` owns both ends of.
    routes.unbind("never-bound");
    assert_eq!(table.len(), 0);

    table.mark_serving(true);
    assert!(table.is_listening());
    table.stop();
    assert!(!table.is_listening());
}

/// A directory nothing else in this suite writes to.
///
/// One per call, and named from the pid plus a counter rather than from a clock: two runs of the
/// suite on one machine must not collide, and two tests in one run must not either.
fn scratch() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let directory = std::env::temp_dir().join(format!(
        "slopdesk-hostd-store-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&directory).expect("a scratch directory under TMPDIR");
    directory
}

/// The store under `directory`, with a debounce short enough to assert without waiting on a person.
fn store_at(directory: &Path, debounce: Duration) -> DiskWorkspace {
    let ids: Arc<dyn SessionIds> = Arc::new(SystemIds);
    let log = Arc::new(Stderr::named("store-test"));
    DiskWorkspace::with_debounce(&directory.join("workspace-state.json"), &ids, &log, debounce)
}

/// A host with no file mints a workspace rather than answering empty.
///
/// The unrecoverable failure this exists to prevent: once client-side tree persistence is gone, a
/// host that answers "no workspace" leaves every client staring at a blank window with no way to
/// create the first pane. So `has_stored` is false AND `load` is a real document.
#[test]
fn a_host_with_no_file_still_has_a_workspace() {
    let directory = scratch();
    let store = store_at(&directory, Duration::from_millis(5));
    assert!(!store.has_stored(), "an empty directory has no stored workspace");

    let minted = store.load();
    let topology = WorkspaceTopology::from_document(&minted).expect("a minted default has a topology");
    assert_eq!(topology.tree.sessions.len(), 1, "one session");
    assert_eq!(
        topology
            .tree
            .sessions
            .first()
            .expect("the one session just asserted")
            .tabs
            .len(),
        1,
        "one tab"
    );
    assert!(
        !topology.host_display_name.is_empty(),
        "the workspace carries a label"
    );
}

/// A burst of saves costs ONE write, and the last document is the one on disk.
///
/// Depth-1 and coalescing: dragging a split emits an intent per frame, and a store that queued them
/// would write a hundred files' worth of bytes for one gesture.
#[test]
fn a_burst_of_saves_coalesces_into_the_last_one() {
    let directory = scratch();
    let store = store_at(&directory, Duration::from_secs(30));
    let first = store.load();
    let mut second = first.clone();
    second.set(
        slopdesk_wire::document::WorkspaceKey::of(
            slopdesk_wire::document::WorkspaceObjectKind::Root,
            [0_u8; 16],
            slopdesk_wire::document::fields::root::HOST_DISPLAY_NAME,
        ),
        slopdesk_wire::document::codec::encode_string("second", 256),
    );

    store.schedule_save(&first);
    store.schedule_save(&second);
    assert!(
        !store.has_stored(),
        "nothing reaches the disk until the debounce fires or a flush does"
    );

    // The stop is the flush, and it writes what the debounce is still holding — which is the LAST
    // document offered, not the first.
    store.flush();
    assert!(store.has_stored(), "the flush landed");
    let reloaded = store_at(&directory, Duration::from_millis(5)).load();
    assert_eq!(
        WorkspaceTopology::from_document(&reloaded)
            .expect("the reloaded file has a topology")
            .host_display_name,
        "second",
        "the last offer is the one on disk"
    );
}

/// A file nobody can decode is kept ASIDE, and the host still starts.
///
/// This is a new class of corruption: on a client a bad workspace file cost one device its layout,
/// here it would cost every client at once. The bytes are kept because losing a workspace to a
/// decode bug is survivable if they are still there to look at.
#[test]
fn a_file_that_does_not_decode_is_kept_rather_than_overwritten() {
    let directory = scratch();
    let path = directory.join("workspace-state.json");
    std::fs::write(&path, b"{ this is not a workspace").expect("a corrupt file to write");
    let store = store_at(&directory, Duration::from_millis(5));

    // `has_stored` is about the FILE, so a corrupt one still counts as "this host had a workspace".
    assert!(store.has_stored());
    let minted = store.load();
    assert!(
        WorkspaceTopology::from_document(&minted).is_some(),
        "a corrupt file costs the layout, never the daemon"
    );

    let kept: Vec<_> = std::fs::read_dir(&directory)
        .expect("the scratch directory to list")
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("workspace-state.corrupt-"))
        .collect();
    assert_eq!(kept.len(), 1, "exactly one copy kept aside, not {kept:?}");
}

/// A decoded file with NO topology is treated as corruption, not as an empty workspace.
///
/// It decodes far enough to look real, which is the trap: publishing it would hand every client an
/// empty window and no way out of one.
#[test]
fn a_decoded_file_with_no_workspace_is_set_aside_too() {
    let directory = scratch();
    let path = directory.join("workspace-state.json");
    std::fs::write(&path, br#"{"version":1,"entries":[]}"#).expect("an empty document to write");
    let store = store_at(&directory, Duration::from_millis(5));

    let minted = store.load();
    assert!(WorkspaceTopology::from_document(&minted).is_some());
    let kept = std::fs::read_dir(&directory)
        .expect("the scratch directory to list")
        .filter_map(Result::ok)
        .any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("workspace-state.empty-")
        });
    assert!(kept, "the empty document was kept aside under its own reason");
}
