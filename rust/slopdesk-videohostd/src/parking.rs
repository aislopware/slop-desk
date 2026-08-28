//! Windows parked on the virtual display: the accessibility half, and the crash journal.
//!
//! The Swift host's window-parking manager and the sidecar beside it. The bookkeeping those two
//! leaned on is [`slopdesk_video::window_parking`] — a refcount that is pure and unit-tested where
//! no window server exists. What is left here is what only a daemon can do: move a real window, put
//! it back, and write down what it moved so the NEXT launch can finish the job if this one is
//! killed.
//!
//! ## Why anything is written to disk at all
//! A parked window has been shrunk and moved onto a display that is not physically there. The
//! clean-shutdown drain restores it; `SIGKILL` does not, and the user is then left hunting for a
//! window that is nowhere on any screen they own. So every change to the parked SET is mirrored to
//! a JSON sidecar, and [`run_launch_hygiene`] reads whatever the last run left behind. It is a
//! crash journal, not state: a clean exit leaves no file.
//!
//! The file format is the one the previous release wrote, down to the `windowID` spelling, and the
//! schema version with it. That is not a cross-language mirror — the Swift is gone — it is the
//! recognition that the first launch of this daemon may well be the launch that has to recover the
//! LAST one's crash, and a format change would silently strand exactly the windows this file exists
//! to rescue. A version mismatch decodes to nothing to restore, never to a migration.
//!
//! ## The two locks, and what is never held across an accessibility call
//! [`Parking::ledger`] is taken to DECIDE and to COMMIT, and is dropped in between. Every write to
//! another process's window goes through the accessibility API, which answers on that process's
//! schedule — a hung app costs [`crate::windowplace::TIMEOUT`] per call — and a lane asking
//! [`Parking::parked_channel_ids`] while another lane waits out a beachball would otherwise wait
//! with it.
//!
//! What that split gives up, [`Parking::effects`] takes back: it serialises the accessibility
//! PHASES, so two lanes that both decided [`ParkDecision::NeedsMove`] for the same window cannot
//! both move it. The Swift got this from `@MainActor` and paid for it everywhere; here the cost is
//! confined to the calls that actually touch a window.
//!
//! ⚠️ GUI + TCC ONLY. Every effect below needs Accessibility, so none of it is reachable from a
//! test — which is why the decisions are not here.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use serde::{Deserialize, Serialize};
use slopdesk_video::geometry::{VideoRect, VideoSize};
use slopdesk_video::window_parking::{ParkDecision, ParkingLedger, RestoreTarget};
use slopdesk_video::window_restore;

use crate::windowplace::{self, ResolvesWindows};

/// The crash journal's file name, beside `video-prefs.json` in the same Application Support
/// directory the launch record already owns.
pub const SIDECAR_NAME: &str = "parked-windows.json";

/// The schema this daemon writes and the only one it reads.
///
/// Bumped on ANY shape change, at which point an older file decodes to `None` and is ignored
/// rather than migrated — see the module note on why the format is pinned at all.
pub const SCHEMA_VERSION: u32 = 1;

/// Where the crash journal lives, or `None` when there is no Application Support directory to put
/// it in — which on macOS means the environment override names nothing and `HOME` is unset.
#[must_use]
pub fn default_sidecar() -> Option<PathBuf> {
    slopdesk_hostlaunch::record::app_support_dir().map(|dir| dir.join(SIDECAR_NAME))
}

/// One parked window, as it is written down.
///
/// Explicit fields rather than a nested rect: the file is meant to be readable by a person looking
/// for the window they lost, and a flat row is what they can grep.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
struct Row {
    /// The window-server id, under the spelling the format was first written with.
    #[serde(rename = "windowID")]
    window_id: u32,
    /// The process that owned the window when it was parked. Checked on restore, because window
    /// ids are per-boot and reusable.
    pid: i32,
    /// The pre-park global frame's left edge, in top-left points.
    #[serde(rename = "originalX")]
    original_x: f64,
    /// Its top edge.
    #[serde(rename = "originalY")]
    original_y: f64,
    /// Its width.
    #[serde(rename = "originalWidth")]
    original_width: f64,
    /// Its height.
    #[serde(rename = "originalHeight")]
    original_height: f64,
}

/// The whole journal: a version, and every window this daemon has moved and not yet put back.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Snapshot {
    /// See [`SCHEMA_VERSION`].
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    /// One row per DISTINCT window. The refcount is a live-only concern: a crash restore puts each
    /// window back exactly once however many lanes were holding it.
    entries: Vec<Row>,
}

/// The parked-window manager: the ledger's decisions, carried out.
#[derive(Debug)]
pub struct Parking<T: ResolvesWindows> {
    /// The accessibility tree every move and restore is written through.
    tree: T,
    /// Where the crash journal is mirrored, or `None` to keep no journal — which is what a test
    /// wants and what a host with nowhere to write gets.
    sidecar: Option<PathBuf>,
    /// The pure bookkeeping. Taken to decide and to commit; never held across an effect.
    ledger: Mutex<ParkingLedger>,
    /// Serialises the accessibility phases. See the module note on the two locks.
    effects: Mutex<()>,
}

impl<T: ResolvesWindows> Parking<T> {
    /// A manager over `tree`, mirroring its parked set to `sidecar`.
    #[must_use]
    pub const fn new(tree: T, sidecar: Option<PathBuf>) -> Self {
        Self {
            tree,
            sidecar,
            ledger: Mutex::new(ParkingLedger::new()),
            effects: Mutex::new(()),
        }
    }

    /// Parks `window_id` for `channel_id` on the display at `display`, answering the size the
    /// window ACTUALLY took — which is what the session captures and acknowledges at.
    ///
    /// `None` means the window did not move, and the caller then captures it in place at the host's
    /// own scale. That is a degraded picture, never a failure: a window that refuses an
    /// accessibility write, an app that is hung, and a display that has just been torn down all
    /// land here, and a pane that streams softly is better than a pane that does not stream.
    ///
    /// The ACHIEVED size is answered rather than the requested one because an app may clamp a
    /// resize it accepts. A session that acknowledged the size it asked for would over-crop the
    /// capture and desynchronise the client's input-mapping denominator.
    pub fn park(&self, channel_id: u32, window_id: u32, pid: i32, display: VideoRect) -> Option<VideoSize> {
        // One park at a time, for the whole decide-move-commit sequence: two lanes naming the same
        // window would otherwise both be told to move it, and the second move would record the
        // FIRST move's result as the window's original frame — a window that can never be put back.
        let _phase = self.locked_effects();

        let decision = {
            let mut ledger = self.locked_ledger();
            let decision = ledger.park(channel_id, window_id);
            // A retarget released the channel's previous window inside that call. Draining the
            // obligation here — before the new window is touched — is what stops the old one from
            // staying parked for the rest of the daemon's life.
            let released = ledger.take_pending_retarget_restore();
            drop(ledger);
            if let Some(target) = released {
                self.put_back(target);
                // The parked SET changed, so the journal must too — a retarget is the one path
                // that shrinks it without going through `unpark`.
                self.persist();
            }
            decision
        };

        match decision {
            ParkDecision::Reuse(achieved) => Some(achieved),
            ParkDecision::NeedsMove => {
                let parked = windowplace::park(&self.tree, window_id, pid, display)?;
                let achieved = VideoSize::new(parked.achieved_width, parked.achieved_height);
                self.locked_ledger()
                    .record_move(channel_id, window_id, pid, parked.original, achieved);
                self.persist();
                Some(achieved)
            },
        }
    }

    /// Releases `channel_id`'s hold, restoring the window if this was its last lane.
    ///
    /// Idempotent, and deliberately silent about a channel that never parked anything: the 1×
    /// fallback path calls this on every pane close too, and having it distinguish the two would
    /// mean every caller had to remember which kind of pane it was closing.
    pub fn unpark(&self, channel_id: u32) {
        let _phase = self.locked_effects();
        let target = self.locked_ledger().unpark(channel_id);
        if let Some(target) = target {
            self.put_back(target);
            self.persist();
        }
    }

    /// Puts every parked window back and empties the ledger.
    ///
    /// The shutdown drain, and the virtual display's own termination drain. Both must run while the
    /// window's ORIGINAL display still exists, which is the whole reason this is a separate step
    /// from tearing the display down rather than something the teardown does on its way out.
    pub fn restore_all(&self) {
        let _phase = self.locked_effects();
        let targets = self.locked_ledger().drain_all();
        for target in targets {
            self.put_back(target);
        }
        self.persist();
    }

    /// The lanes currently holding a parked window — the input to the termination policy, which
    /// intersects them with the lanes that are live.
    #[must_use]
    pub fn parked_channel_ids(&self) -> BTreeSet<u32> {
        self.locked_ledger().parked_channel_ids()
    }

    /// One restore, best-effort. A window whose app has since quit is simply gone, and there is
    /// nothing better to do about it than the nothing this does.
    fn put_back(&self, target: RestoreTarget) {
        let _restored = windowplace::restore(&self.tree, target.window_id, target.pid, target.original);
    }

    /// Mirrors the parked set to the journal, or deletes the journal when nothing is parked.
    ///
    /// Best-effort throughout: a park that succeeded must not be undone by a disk that is full, and
    /// the cost of a missing journal is one manual window move after a crash that may never happen.
    ///
    /// The holder count is DROPPED on the way out, and that is the file's meaning rather than an
    /// omission: a next-launch restore puts each window back exactly once however many lanes were
    /// holding it, because none of those lanes exists any more.
    fn persist(&self) {
        let Some(path) = self.sidecar.as_ref() else {
            return;
        };
        let entries: Vec<Row> = self
            .locked_ledger()
            .entries()
            .into_iter()
            .map(|(window_id, parked)| {
                Row {
                    window_id,
                    pid: parked.pid,
                    original_x: parked.original.origin.x,
                    original_y: parked.original.origin.y,
                    original_width: parked.original.size.width,
                    original_height: parked.original.size.height,
                }
            })
            .collect();
        if entries.is_empty() {
            // Nothing parked means nothing to recover, and a stale file that says otherwise would
            // have the next launch move windows the user has since re-homed themselves.
            let _removed = std::fs::remove_file(path);
            return;
        }
        let snapshot = Snapshot {
            schema_version: SCHEMA_VERSION,
            entries,
        };
        let Ok(text) = serde_json::to_string_pretty(&snapshot) else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _created = std::fs::create_dir_all(parent);
        }
        let _written = std::fs::write(path, text);
    }

    /// The ledger, through the poison a daemon cannot be helped by refusing to serve.
    ///
    /// A panic mid-update leaves the bookkeeping as it stood, and the next park is decided from
    /// there. Refusing every later park instead would leave every window this daemon has already
    /// moved parked for good, which is the one outcome this whole file exists to prevent.
    fn locked_ledger(&self) -> MutexGuard<'_, ParkingLedger> {
        self.ledger.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The effects phase, through the same poison discipline as [`Self::locked_ledger`].
    fn locked_effects(&self) -> MutexGuard<'_, ()> {
        self.effects.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Puts back the windows a CRASHED previous daemon left stranded, and answers how many moved.
///
/// The journal is deleted FIRST and unconditionally. Hygiene that crashed halfway through would
/// otherwise be repeated on every launch for ever, against a window list that gets less true each
/// time — one shot, and a failure costs the user the manual move they already faced.
///
/// A recorded window is moved only when it still EXISTS under the same owning process — window ids
/// are per-boot and reusable, so a stale row must never be allowed to move an unrelated window —
/// and only when [`slopdesk_video::window_restore::should_restore`] agrees it is still stranded.
/// That predicate is why this is not simply "put everything in the file back": a user who has
/// already dragged their window somewhere they can see it would otherwise have it yanked away by
/// the daemon that lost it.
///
/// Run BEFORE this launch creates its own virtual display, or the new display's own off-screen
/// bounds count as somewhere a window can legitimately be and every genuinely stranded window is
/// left where it is.
pub fn run_launch_hygiene<T, F>(tree: &T, path: &Path, displays: &[VideoRect], frame_of: F) -> usize
where
    T: ResolvesWindows,
    F: Fn(u32, i32) -> Option<VideoRect>,
{
    let Ok(text) = std::fs::read_to_string(path) else {
        return 0;
    };
    let _removed = std::fs::remove_file(path);
    let Ok(snapshot) = serde_json::from_str::<Snapshot>(&text) else {
        return 0;
    };
    if snapshot.schema_version != SCHEMA_VERSION {
        return 0;
    }
    let mut restored = 0;
    for row in snapshot.entries {
        let original = VideoRect::xywh(
            row.original_x,
            row.original_y,
            row.original_width,
            row.original_height,
        );
        let Some(current) = frame_of(row.window_id, row.pid) else {
            continue;
        };
        if !window_restore::should_restore(current, original.origin.x, original.origin.y, displays) {
            continue;
        }
        if windowplace::restore(tree, row.window_id, row.pid, original) {
            restored += 1;
        }
    }
    restored
}

/// Every online display's bounds — the [`run_launch_hygiene`] input.
///
/// ONLINE and not active, deliberately: a window on a display that is merely asleep is not
/// stranded, and restoring it would move a window the user never lost. An empty answer fails the
/// predicate SOFT, so a CoreGraphics failure moves nothing rather than moving everything.
#[must_use]
pub fn online_display_bounds() -> Vec<VideoRect> {
    slopdesk_apple_cgdisplay::online()
        .into_iter()
        .map(|display| display.bounds)
        .collect()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::{Mutex, PoisonError};

    use slopdesk_video::geometry::VideoRect;

    use super::{Parking, Row, SCHEMA_VERSION, Snapshot, run_launch_hygiene};
    use crate::windowplace::{ActsOnWindow, FocusesWindow, ResolvesWindows};

    /// A window that accepts every write and reports the frame it was last given.
    #[derive(Debug)]
    struct Fake {
        frame: Mutex<VideoRect>,
    }

    impl ActsOnWindow for Fake {
        fn frame(&self) -> Option<VideoRect> {
            Some(*self.frame.lock().unwrap_or_else(PoisonError::into_inner))
        }
        fn set_origin(&self, x: f64, y: f64) -> bool {
            let mut frame = self.frame.lock().unwrap_or_else(PoisonError::into_inner);
            *frame = VideoRect::xywh(x, y, frame.size.width, frame.size.height);
            true
        }
        fn set_size(&self, width: f64, height: f64) -> bool {
            let mut frame = self.frame.lock().unwrap_or_else(PoisonError::into_inner);
            *frame = VideoRect::xywh(frame.origin.x, frame.origin.y, width, height);
            true
        }
        fn minimized(&self) -> Option<bool> {
            Some(false)
        }
        fn set_minimized(&self, _minimized: bool) -> bool {
            true
        }
    }

    /// A tree holding ONE window, so a test can read where it ended up.
    #[derive(Debug)]
    struct OneWindow {
        frame: VideoRect,
    }

    /// The application half of a resolution. Records nothing: no sequence under test focuses.
    #[derive(Debug)]
    struct NoApp;

    impl FocusesWindow for NoApp {
        type Window = Fake;
        fn focus(&self, _window: &Self::Window) {}
    }

    impl ResolvesWindows for OneWindow {
        type Window = Fake;
        type App = NoApp;
        fn resolve(
            &self,
            pid: i32,
            _window_id: u32,
            _fallback: VideoRect,
            _timeout: f32,
        ) -> Option<(NoApp, Fake)> {
            (pid > 0).then(|| {
                (NoApp, Fake {
                    frame: Mutex::new(self.frame),
                })
            })
        }
    }

    /// The park moves the window onto the display and answers the size it took there.
    #[test]
    fn park_answers_the_achieved_size() {
        let tree = OneWindow {
            frame: VideoRect::xywh(100.0, 100.0, 800.0, 600.0),
        };
        let parking = Parking::new(tree, None);
        let display = VideoRect::xywh(3000.0, 0.0, 1920.0, 1080.0);
        let achieved = parking
            .park(7, 42, 99, display)
            .expect("the window accepts every write");
        // Bit-exact on purpose: an accepted park must hand back the very numbers it was given,
        // and a tolerance here would pass a placement that quietly rounded the window.
        #[expect(clippy::float_cmp, reason = "the park is exact or it is not the park")]
        {
            assert_eq!(achieved.width, 800.0);
            assert_eq!(achieved.height, 600.0);
        }
        assert_eq!(parking.parked_channel_ids(), std::iter::once(7).collect());
    }

    /// A hold released is a hold forgotten, whether or not the restore itself lands.
    #[test]
    fn unpark_releases_the_hold() {
        let tree = OneWindow {
            frame: VideoRect::xywh(100.0, 100.0, 800.0, 600.0),
        };
        let parking = Parking::new(tree, None);
        let _achieved = parking.park(7, 42, 99, VideoRect::xywh(3000.0, 0.0, 1920.0, 1080.0));
        parking.unpark(7);
        assert!(parking.parked_channel_ids().is_empty());
    }

    /// A window the caller cannot resolve does not move, and nothing is recorded against it.
    #[test]
    fn a_refused_park_records_nothing() {
        let tree = OneWindow {
            frame: VideoRect::xywh(100.0, 100.0, 800.0, 600.0),
        };
        let parking = Parking::new(tree, None);
        // A non-positive pid is the one refusal `windowplace` answers without touching the tree.
        assert!(
            parking
                .park(7, 42, 0, VideoRect::xywh(3000.0, 0.0, 1920.0, 1080.0))
                .is_none()
        );
        assert!(parking.parked_channel_ids().is_empty());
    }

    /// The journal round-trips through the format the previous release wrote.
    #[test]
    fn the_journal_decodes_what_it_encodes() {
        let snapshot = Snapshot {
            schema_version: SCHEMA_VERSION,
            entries: vec![Row {
                window_id: 42,
                pid: 99,
                original_x: 100.0,
                original_y: 120.0,
                original_width: 800.0,
                original_height: 600.0,
            }],
        };
        let text = serde_json::to_string(&snapshot).expect("the snapshot encodes");
        assert!(
            text.contains("\"windowID\""),
            "the pinned spelling survives: {text}"
        );
        let read: Snapshot = serde_json::from_str(&text).expect("the snapshot decodes");
        assert_eq!(read, snapshot);
    }

    /// Hygiene deletes the journal even when it cannot use it, so a bad file cannot loop.
    #[test]
    fn hygiene_deletes_a_journal_it_refuses() {
        let path = std::env::temp_dir().join(format!("slopdesk-parking-{}.json", std::process::id()));
        std::fs::write(&path, "{\"schemaVersion\":9999,\"entries\":[]}").expect("the file is written");
        let tree = OneWindow {
            frame: VideoRect::xywh(0.0, 0.0, 1.0, 1.0),
        };
        let restored = run_launch_hygiene(&tree, &path, &[], |_id, _pid| None);
        assert_eq!(restored, 0);
        assert!(
            !path.exists(),
            "a journal this daemon cannot read is still consumed"
        );
    }
}
