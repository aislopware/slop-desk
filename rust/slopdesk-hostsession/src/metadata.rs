//! The pane's metadata RPC: admit it, run it off the control loop, always answer it.
//!
//! Twenty-two verbs arrive on the SAME unwindowed control sub-channel this pane's resizes, acks and
//! pings ride, and every one of them can block — a `git status` on a cold repository, an `lsof`
//! over a process tree, a `stat` walk into a wedged mount. Three rules follow, and this module is
//! all three:
//!
//! 1. **Never on the control loop.** The work goes to the pane's serial executor, which is the SAME
//!    one the project-key walk uses ([`ResolveExecutor`]) — one queue per pane, so a `cd`'s resolve
//!    and a metadata probe cannot fork subprocesses behind each other's back or answer out of the
//!    order they were asked in.
//! 2. **Bounded, and refused rather than deferred at the bound.** The control channel applies no
//!    back-pressure, so a peer streaming back-to-back tiny requests would otherwise queue an
//!    unbounded pile of work items, each retaining its payload. [`Admission`] is the only bound.
//! 3. **Always replies.** Every path out of here — admitted, refused, unknown verb, failed probe —
//!    ends in exactly one type-30 for the request id, because the client's pending-request registry
//!    resolves on the answer and nothing else times it out but its own five seconds.
//!
//! ## Why the performer is injected
//!
//! Nine of the verbs actuate on host-global state: the Finder, `~/.claude/settings.json`, the
//! pasteboard, a lazily-spawned workbench child. Those are still Swift under `docs/60` §5's
//! carve-out, and stage F is what takes them. What is NOT deferred is the routing — [`performer`]
//! already decides whose verb it is, in Rust, off the wire's own enum — so what crosses the
//! boundary is one call with the routing already done, not a chain of "not mine" answers.
//!
//! ## The one thing that crosses as a raw number, and what closes it
//!
//! [`MetadataRequest::master_fd`] hands the performer the PTY master's descriptor number, because
//! three read verbs resolve the pane's foreground group from it. That is the one place a pane's fd
//! escapes `PtyProcess`'s hold, and it is a real seam: a request that raced a teardown could probe
//! a number the kernel has already handed to the next `openpty`. It is the seam Swift has today —
//! `serveMetadata` captures `pty.masterFD` before its `async` — and it closes at stage F, when the
//! builder is Rust and can take the hold for the microsecond `tcgetpgrp` without holding it for the
//! `git` fork behind it. Until then it is documented rather than hidden.
//!
//! [`ResolveExecutor`]: crate::ResolveExecutor
//! [`Admission`]: slopdesk_muxsession::metadata_admission::Admission
//! [`performer`]: slopdesk_muxsession::metadata_admission::performer

use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_muxsession::fanout::SubscriberId;
use slopdesk_muxsession::metadata_admission::{Admission, Performer, performer};
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::message::WireMessage;

use crate::project::ResolveExecutor;
use crate::shared::Shared;

/// One metadata request, as the performer needs it.
#[derive(Debug)]
pub struct MetadataRequest<'call> {
    /// The correlation key the answer must echo.
    pub request_id: u32,
    /// The raw verb byte, un-narrowed: a byte this build does not serve is the performer's to
    /// answer [`MetadataStatus::UnsupportedVerb`] to, and narrowing it here would put a second
    /// place in the tree that decides what "unknown" means.
    pub verb: u8,
    /// The verb-specific request body, opaque to this envelope.
    pub payload: &'call [u8],
    /// Who the routing table says owns this verb.
    pub performer: Performer,
    /// The PTY master's descriptor — see the module note on the seam this is.
    pub master_fd: i32,
    /// The pane's shell pid, or `0` when superd has not answered with one.
    pub shell_pid: i32,
}

/// What a performer answers with.
///
/// A status and a body rather than a [`WireMessage`], so a performer cannot answer with the wrong
/// KIND of message: the envelope is built here, once, and the "exactly one type-30 per request id"
/// contract is a property of this module rather than a rule every performer has to remember.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetadataAnswer {
    /// The raw status byte — `0` ok · `1` notFound · `2` error · `3` unsupportedVerb.
    pub status: u8,
    /// The verb-specific response body.
    pub payload: Vec<u8>,
}

impl MetadataAnswer {
    /// A successful answer carrying `payload`.
    #[must_use]
    pub const fn ok(payload: Vec<u8>) -> Self {
        Self {
            status: MetadataStatus::Ok.as_byte(),
            payload,
        }
    }

    /// The standard failure: the shape every refused, unknown or broken verb answers with.
    #[must_use]
    pub const fn failed() -> Self {
        Self {
            status: MetadataStatus::Error.as_byte(),
            payload: Vec::new(),
        }
    }
}

/// Who runs a metadata verb once it has been admitted and routed.
///
/// Called on the pane's serial executor, never the control loop, so an implementation MAY block.
/// It may not, however, call back into the session — the executor is also where the project-key
/// walk runs, and a re-entrant verb would deadlock behind itself.
pub trait MetadataPerformer: Send + Sync + core::fmt::Debug {
    /// The answer for `request`. Returning is mandatory; there is no "not mine" — the routing is
    /// already done and an implementation that does not serve a verb answers
    /// [`MetadataStatus::UnsupportedVerb`].
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer;
}

/// A performer that serves nothing.
///
/// The default, and the honest one for a session built without a host behind it: every verb is
/// answered [`MetadataStatus::UnsupportedVerb`] at once, so a test's client resolves rather than
/// waiting out its registry timeout.
#[derive(Debug, Clone, Copy)]
pub struct UnservedMetadata;

impl MetadataPerformer for UnservedMetadata {
    fn perform(&self, _request: &MetadataRequest<'_>) -> MetadataAnswer {
        MetadataAnswer {
            status: MetadataStatus::UnsupportedVerb.as_byte(),
            payload: Vec::new(),
        }
    }
}

/// One request as it ARRIVES, before anything has been decided about it.
///
/// A struct rather than five parameters because it travels as a unit and is built at exactly one
/// call site; splitting it back out would only put the pane's descriptor and the verb byte in an
/// argument list long enough to get their order swapped.
#[derive(Debug)]
pub(crate) struct Asked {
    /// The correlation key the answer must echo.
    pub(crate) request_id: u32,
    /// The raw verb byte.
    pub(crate) verb: u8,
    /// The request body, MOVED: it was decoded into a `Vec` already and the work item owns it next.
    pub(crate) payload: Vec<u8>,
    /// The PTY master's descriptor number — see the module note on the seam this is.
    pub(crate) master_fd: i32,
    /// The pane's shell pid, or `0`.
    pub(crate) shell_pid: i32,
}

/// The pane's metadata surface: the bound, the queue and the performer behind it.
#[derive(Debug)]
pub(crate) struct Metadata {
    /// The per-session bound. Its own lock, and a small one — every use is `admit` or `release`,
    /// and nothing waits on anything while holding it. Shared with the guard that returns a slot,
    /// which outlives this type in the pathological case: a work item still running while the pane
    /// tears down.
    admission: Arc<Mutex<Admission>>,
    executor: Arc<dyn ResolveExecutor>,
    performer: Arc<dyn MetadataPerformer>,
}

impl Metadata {
    /// A surface over `executor`, serving verbs through `performer`.
    pub(crate) fn new(executor: Arc<dyn ResolveExecutor>, performer: Arc<dyn MetadataPerformer>) -> Self {
        Self {
            admission: Arc::new(Mutex::new(Admission::default())),
            executor,
            performer,
        }
    }

    /// Serves one request, answering `id` exactly once.
    ///
    /// Takes the payload by VALUE: it was decoded out of the frame into a `Vec` already, and the
    /// work item has to own it anyway, so moving it across is the copy that does not happen.
    pub(crate) fn serve(&self, shared: &Arc<Shared>, id: SubscriberId, asked: Asked) {
        let Asked {
            request_id,
            verb,
            payload,
            master_fd,
            shell_pid,
        } = asked;
        if !self.admit() {
            // Refused, not deferred, and answered IMMEDIATELY with the standard failure — the exact
            // shape any failed verb replies with, so "always replies" survives the flood that
            // caused the refusal.
            reply(shared, id, request_id, MetadataAnswer::failed());
            return;
        }
        let slot = SlotGuard {
            admission: Arc::clone(&self.admission),
        };
        let shared = Arc::clone(shared);
        let performer = Arc::clone(&self.performer);
        self.executor.submit(Box::new(move || {
            let answer = performer.perform(&MetadataRequest {
                request_id,
                verb,
                payload: &payload,
                performer: routed(verb),
                master_fd,
                shell_pid,
            });
            reply(&shared, id, request_id, answer);
            drop(slot);
        }));
    }

    /// Takes a slot, or answers that there is none.
    fn admit(&self) -> bool {
        self.admission
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .admit()
    }

    /// How many admitted work items are unfinished — the flood test's window on the bound.
    pub(crate) fn in_flight(&self) -> u32 {
        self.admission
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .in_flight()
    }
}

/// A taken slot, returned when the work item is dropped.
///
/// A guard rather than a `release()` at the end of the closure, because the closure is somebody
/// else's executor's to run: one that panics, or one an executor drops without running, would
/// otherwise leak a slot for the session's life and shrink the bound by one per incident until the
/// pane refuses everything.
#[derive(Debug)]
struct SlotGuard {
    admission: Arc<Mutex<Admission>>,
}

impl Drop for SlotGuard {
    fn drop(&mut self) {
        self.admission
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .release();
    }
}

/// The routing answer for `verb`, named here so the call site reads as one thing.
const fn routed(verb: u8) -> Performer {
    performer(verb)
}

/// Sends one type-30 to `id`, or drops it when that subscriber has already left.
///
/// A departed subscriber is the ONE case where an answer goes nowhere, and it has to be: the
/// request was that connection's, and broadcasting a correlation key nobody else minted would land
/// a stray response in every other client's registry.
fn reply(shared: &Shared, id: SubscriberId, request_id: u32, answer: MetadataAnswer) {
    let Some(member) = shared.member(id) else {
        return;
    };
    member.enqueue_control(vec![WireMessage::MetadataResponse {
        request_id,
        status: answer.status,
        payload: answer.payload,
    }]);
}
