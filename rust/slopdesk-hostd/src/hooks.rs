//! The agent-hook listener's half of a hook route: one socket, many panes.
//!
//! ## hostd binds nothing, and that is the whole reason this shape exists
//! superd owns the `AF_UNIX` listener (`docs/51` §1), because its address is baked into every
//! agent's environment at `execve` and can never be corrected afterwards — so it has to outlive
//! hostd's pid. superd accepts and hands each connection over `SCM_RIGHTS`, reading none of it.
//! Everything that makes a hook record MEAN something is here, in the process that may be rebuilt.
//!
//! ## Keyed by the ENV-BAKED pane id, never a composite
//! The agent POSTs the id that was in its environment when it started. A per-reattach key could
//! never route, and would leak one dead sink per wifi flap for the daemon's life.
//!
//! ## Two serial queues, and neither may be merged with the other
//! - The DRAIN reads one accepted connection, in the order superd accepted them, which is the order
//!   the agent produced them.
//! - The DELIVERY routes, off the drain. Serial for the same reason and a stronger one: hook events
//!   are a state machine per pane (`UserPromptSubmit` → `PreToolUse` → `Stop`), and arrival order
//!   is the only thing keeping that machine honest.
//!
//! Separate, because a slow FOLD must not stall the next connection's drain.
//!
//! ## Nothing here may park on the peer
//! The peer is Claude Code's hook binary, which BLOCKS its agent until the record is taken. A
//! wedged sender — connected, wrote nothing, never closed — would park the drain for ever, so the
//! read carries a timeout and the record carries a cap, and a connection that violates either is
//! dropped rather than waited on.
//!
//! ## The decode is the LISTENER's
//! `PaneSession::fold_hook` takes a decoded event, and says why: the bytes→event mapping is
//! `slopdesk_hookevent`'s reader plus one match, and that match exists once, in
//! `slopdesk_agent::signal::hook_event_of`. The parse belongs to whoever owns the socket, and this
//! is that.

use std::collections::BTreeMap;
use std::io::Read as _;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use slopdesk_hostserver::Pane;
use slopdesk_hostserver::channel::HookRoutes;
use slopdesk_hostsession::ResolveExecutor;
use slopdesk_muxsession::hook_record;

use crate::resolve::SerialResolve;

/// Hard cap on one hook record — validate-then-drop a runaway sender.
///
/// A real record is a few kilobytes; the ceiling exists so that a hostile one has an end. The fold
/// caps its own label besides, so nothing downstream depends on this number being generous.
const MAX_RECORD_BYTES: usize = 64 * 1024;

/// How long one connection may go without producing bytes before it is dropped.
///
/// A hook record is one small write from a local process, so seconds is already generous. The point
/// is that the ceiling EXISTS: without it the whole host's hook path parks on one wedged peer.
const READ_TIMEOUT: Duration = Duration::from_secs(2);

/// How much is read per syscall. One record fits in one of these on every real path.
const CHUNK_BYTES: usize = 4096;

/// `pane id → the pane its hooks fold into`, and the two queues that get them there.
#[derive(Debug)]
pub struct HookTable {
    routes: Mutex<BTreeMap<String, Arc<dyn Pane>>>,
    /// Where one accepted connection is read. See the module note for why this is not `delivery`.
    drain: SerialResolve,
    /// Where the routing runs, off the drain, in arrival order.
    delivery: SerialResolve,
    /// Whether superd accepted this hostd's claim on the hook listener.
    ///
    /// Nothing is bound here, so there is nothing to fail — this records what the `listen` verb
    /// answered, which is the difference between "hooks installed" and "hooks actually flowing".
    serving: AtomicBool,
}

impl Default for HookTable {
    fn default() -> Self {
        Self::new()
    }
}

impl HookTable {
    /// An empty table, with both queues idle until the first connection arrives.
    #[must_use]
    pub fn new() -> Self {
        Self {
            routes: Mutex::new(BTreeMap::new()),
            drain: SerialResolve::new("hook-drain"),
            delivery: SerialResolve::new("hook-delivery"),
            serving: AtomicBool::new(false),
        }
    }

    /// Records that superd accepted this hostd's claim on the hook listener.
    pub fn mark_serving(&self, serving: bool) {
        self.serving.store(serving, Ordering::Release);
    }

    /// Whether superd is accepting hook connections on this hostd's behalf.
    #[must_use]
    pub fn is_listening(&self) -> bool {
        self.serving.load(Ordering::Acquire)
    }

    /// Takes ownership of one connection superd accepted, and drains it.
    ///
    /// Returns at once: the read happens on the drain queue. That matters because the caller is the
    /// supervisor client's single reader thread, which also carries every pane's output — blocking
    /// it for the two seconds a wedged peer is allowed would stall every terminal in the host.
    pub fn serve(self: &Arc<Self>, connection: UnixStream) {
        let table = Arc::clone(self);
        self.drain.submit(Box::new(move || table.consume(connection)));
    }

    /// Drops every route. There is no socket to close — superd owns it.
    pub fn stop(&self) {
        self.routes.lock().unwrap_or_else(PoisonError::into_inner).clear();
        self.mark_serving(false);
    }

    /// Reads one connection to EOF and hands its record to the delivery queue.
    fn consume(self: &Arc<Self>, mut connection: UnixStream) {
        // A socket that will not take a timeout is one whose reads could park for ever, and the
        // whole point of the bound is that it cannot be skipped — so refuse the connection instead.
        if connection.set_read_timeout(Some(READ_TIMEOUT)).is_err() {
            return;
        }
        let mut record = Vec::with_capacity(CHUNK_BYTES);
        let mut chunk = [0_u8; CHUNK_BYTES];
        // EOF, error, or the read timeout expiring all end the drain the same way: with whatever
        // arrived. A partial record fails the split or the parse below and is dropped there, which
        // is one refusal path rather than two.
        while let Ok(read) = connection.read(&mut chunk) {
            let Some(arrived) = chunk.get(..read) else {
                break;
            };
            if arrived.is_empty() {
                break;
            }
            record.extend_from_slice(arrived);
            if record.len() > MAX_RECORD_BYTES {
                break;
            }
        }
        // The `printf '…\n'` framing. One newline, because the JSON body may legitimately end in
        // one of its own and a greedy trim would eat it.
        if record.last() == Some(&b'\n') {
            record.pop();
        }
        if record.is_empty() {
            return;
        }
        let table = Arc::clone(self);
        self.delivery.submit(Box::new(move || table.route(&record)));
    }

    /// Routes one received record to its pane.
    ///
    /// Validate-then-drop at all three steps — no pane header, no route for that id, or a body this
    /// build has no case for — because every one of them is something a stranger can cause.
    fn route(&self, record: &[u8]) {
        let (pane_id, body) = hook_record::parts(record);
        let Some(pane_id) = pane_id else { return };
        let pane = self
            .routes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(pane_id)
            .map(Arc::clone);
        let Some(pane) = pane else { return };
        let Some(parsed) = slopdesk_hookevent::parse(body) else {
            return;
        };
        let event = slopdesk_agent::signal::hook_event_of(
            parsed.hook,
            parsed.notification,
            parsed.session_id,
            parsed.tool,
            parsed.tool_use_id,
            parsed.label,
        );
        // Called OUTSIDE the routes lock. The fold reaches the pane's detector, which takes locks
        // of its own and calls status observers that reach back into the composition;
        // holding this one across it would make every hook a lock-order hazard for every
        // bind.
        pane.fold_hook(event, parsed.kind_byte, parsed.prompt.as_deref());
    }

    /// How many routes are live — the leak pin for the stable-key contract: one route per live
    /// session, across any number of detach/reattach cycles.
    #[must_use]
    pub fn len(&self) -> usize {
        self.routes.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Whether nothing is routed. `len`'s companion, because clippy asks for the pair.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Drives the real router without a socket — the seam the suite folds records through.
    pub fn route_record(&self, record: &[u8]) {
        self.route(record);
    }
}

impl HookRoutes for HookTable {
    fn bind(&self, pane_id: &str, pane: &Arc<dyn Pane>) {
        self.routes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(pane_id.to_owned(), Arc::clone(pane));
    }

    fn unbind(&self, pane_id: &str) {
        self.routes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(pane_id);
    }
}
