//! The pane's ONE serial queue: where a project-key ancestor walk and a `git status` take turns.
//!
//! ## Why the session refused to own this
//! [`slopdesk_hostsession`] ships [`InlineResolve`](slopdesk_hostsession::InlineResolve), which
//! runs the walk on whoever asked. In a suite that is exactly right — the walk still happens, in
//! order, and the only thing given up is the guarantee a hung mount cannot stall the caller. In a
//! daemon that guarantee is the point: the caller is the control relay, and a `cd` into an
//! unresponsive network mount would otherwise park the thread that carries every keystroke.
//!
//! ## One thread per pane, and it starts when the pane first needs it
//! Forty idle panes should cost forty threads only if forty panes resolve. So the thread is spawned
//! on the FIRST submission and lives until the executor drops — which is the session dropping,
//! which is the pane ending. The `Sender` going with it is what tells the thread to return; there
//! is no stop flag, and therefore no way to leave one set.
//!
//! ## Serial is a requirement, not an implementation detail
//! `SessionConfig::metadata` runs its verbs on this same executor deliberately: the key walk a `cd`
//! triggers and the `git status` a metadata request triggers both touch the same working tree, and
//! two of them forking behind each other is how a pane ends up answering with the previous
//! directory's repository. An mpsc queue drained by one thread IS submission order, so nothing here
//! has to keep it.

use std::sync::mpsc::{Sender, channel};
use std::sync::{Mutex, PoisonError};
use std::thread;

use slopdesk_hostsession::ResolveExecutor;

/// One unit of off-thread work.
type Job = Box<dyn FnOnce() + Send>;

/// A pane's serial queue, started on demand.
#[derive(Debug)]
pub struct SerialResolve {
    /// `None` until the first submission, and again never: the thread is started once and the
    /// handle to it kept for the executor's life.
    queue: Mutex<Option<Sender<Job>>>,
    /// What the thread is called in a crash report. Per pane, because "which pane wedged" is the
    /// first question a stalled walk raises.
    name: String,
}

impl SerialResolve {
    /// A queue for the pane superd knows as `pane_id`, not yet running.
    #[must_use]
    pub fn new(pane_id: &str) -> Self {
        Self {
            queue: Mutex::new(None),
            name: format!("slopdesk-resolve-{pane_id}"),
        }
    }

    /// The live sender, starting the thread if this is the first ask.
    ///
    /// `None` means the process could not make a thread. The caller then runs the walk inline,
    /// which is [`InlineResolve`](slopdesk_hostsession::InlineResolve)'s behaviour — the
    /// degraded answer, and still the right one: a project key resolved on the calling thread
    /// is a project key.
    fn sender(&self) -> Option<Sender<Job>> {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(ref live) = *queue {
            return Some(live.clone());
        }
        let (submit, jobs) = channel::<Job>();
        let started = thread::Builder::new().name(self.name.clone()).spawn(move || {
            // Ends when the sender drops, which is this executor being dropped. Every job that was
            // queued before that still runs: `recv` drains what is buffered before it reports the
            // disconnect, so a pane closing does not cancel the walk it just asked for.
            while let Ok(job) = jobs.recv() {
                job();
            }
        });
        if started.is_err() {
            return None;
        }
        *queue = Some(submit.clone());
        // Released before returning rather than at the end of the scope: the caller's next act is a
        // `send`, and holding the queue lock across it would serialise every submitter behind
        // whichever one is currently touching the channel.
        drop(queue);
        Some(submit)
    }
}

impl ResolveExecutor for SerialResolve {
    fn submit(&self, walk: Job) {
        let Some(submit) = self.sender() else {
            walk();
            return;
        };
        // A send can only fail if the receiving thread is gone, and the only thing that ends it is
        // this executor's own drop — which cannot be in flight while a `&self` method runs. Running
        // the walk inline is nonetheless what to do if it ever does, for the same reason a thread
        // that would not spawn does.
        if let Err(returned) = submit.send(walk) {
            returned.0();
        }
    }
}
