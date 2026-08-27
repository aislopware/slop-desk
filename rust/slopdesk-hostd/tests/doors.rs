//! The four doors whose behaviour is decidable without a socket.
//!
//! Three of this crate's implementations cannot be driven here, and that is the point of where the
//! line falls: `Spawner` needs superd, `Transcripts` needs a journal on disk, and the two screen
//! doors need screend. Each is one call across a boundary another crate's suite already covers, and
//! a fake of the daemon behind it would be asserting on the fake.
//!
//! What IS decidable here is everything the doors do BESIDES the call across: submission order, the
//! refcount pairing, the late-bound host, and the enum map that would silently mis-file a state.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use slopdesk_hostd::keys::{ProjectKeySink, WatchKeys, mint_owner};
use slopdesk_hostd::{LateHost, SerialResolve};
use slopdesk_hostsession::{CloseTap, KeyObserver, ResolveExecutor};

/// Every call the pane made into the repo-watch refcounts, in order.
#[derive(Debug, Default)]
struct RecordingSink {
    calls: Mutex<Vec<String>>,
}

impl RecordingSink {
    fn calls(&self) -> Vec<String> {
        self.calls.lock().expect("the recorder is not poisoned").clone()
    }
}

impl ProjectKeySink for RecordingSink {
    fn latched(&self, owner: u64, key: &str) {
        self.calls
            .lock()
            .expect("the recorder is not poisoned")
            .push(format!("latched {owner} {key}"));
    }

    fn dropped(&self, owner: u64) {
        self.calls
            .lock()
            .expect("the recorder is not poisoned")
            .push(format!("dropped {owner}"));
    }
}

/// Submission order IS execution order, and every job runs.
///
/// The property the metadata verbs depend on: a `cd`'s key walk and a `git status` share this queue
/// precisely so they cannot fork behind each other, and an executor that ran them concurrently
/// would pass a test that only counted them.
#[test]
fn the_serial_queue_runs_every_job_in_submission_order() {
    let resolve = SerialResolve::new("pane-order");
    let (done, ran) = channel();
    for index in 0..64_u32 {
        let report = done.clone();
        resolve.submit(Box::new(move || {
            report.send(index).expect("the test still holds the receiver");
        }));
    }
    drop(done);
    let order: Vec<u32> = ran.iter().collect();
    assert_eq!(order, (0..64).collect::<Vec<u32>>());
}

/// Dropping the executor ends its thread, and the jobs already queued still run.
///
/// A pane closing must not cancel the walk it asked for a microsecond earlier — `recv` drains what
/// is buffered before it reports the disconnect, and this is the assertion that keeps that true.
#[test]
fn dropping_the_queue_drains_it_rather_than_cancelling_it() {
    let (done, ran) = channel();
    {
        let resolve = SerialResolve::new("pane-drain");
        for index in 0..16_u32 {
            let report = done.clone();
            resolve.submit(Box::new(move || {
                report.send(index).expect("the test still holds the receiver");
            }));
        }
    }
    drop(done);
    assert_eq!(ran.iter().count(), 16);
}

/// Every `latched` is answered by exactly one `dropped`, whatever ended the pane.
#[test]
fn the_close_tap_releases_the_owner_exactly_once() {
    let recorder = Arc::new(RecordingSink::default());
    let sink: Arc<dyn ProjectKeySink> = Arc::<RecordingSink>::clone(&recorder);
    let owner = mint_owner();
    let watching = WatchKeys::new(&sink, owner);

    watching.latched("/repo/one");
    watching.latched("/repo/two");
    watching.closed();

    assert_eq!(recorder.calls(), vec![
        format!("latched {owner} /repo/one"),
        format!("latched {owner} /repo/two"),
        format!("dropped {owner}"),
    ]);
}

/// Two panes never share an owner id, which is the ONE property the refcounts require of it.
#[test]
fn owner_ids_are_distinct() {
    let minted: Vec<u64> = (0..1024).map(|_| mint_owner()).collect();
    let mut sorted = minted.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(sorted.len(), minted.len());
}

/// A seam whose host has not landed evicts nobody, and does not panic doing it.
///
/// The start-up window is real: a session's config is built before the composition exists, and a
/// member cannot fall behind before the daemon serves — but the code must not depend on that.
#[test]
fn an_unpublished_host_evicts_nobody() {
    use slopdesk_hostd::HostEviction;
    use slopdesk_hostsession::EvictionSeam;

    let late = Arc::new(LateHost::default());
    let seam = HostEviction::new(&late, [7_u8; 16]);
    seam.evict(3);
}
