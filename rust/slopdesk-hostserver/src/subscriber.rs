//! One subscribed connection's view of the workspace document.
//!
//! The LADDER — what this subscriber may be sent next, against which base, and which retained
//! states are still worth keeping — is [`slopdesk_workspace::sync_ladder`], and the payloads it
//! retains are held by [`Retention`] rather than filed under a slot the caller must remember to
//! free. What is HERE is what no pure function can be: the channel, the pump thread, and the
//! depth-1 pending slot in front of it.
//!
//! **The send queue is depth-1 and COALESCING, and it is not the control sub-channel's own queue.**
//! A pending update is DISCARDED AND RECOMPUTED, never queued, so host memory is O(clients × state)
//! no matter how slow a client is. A sleeping iPhone is free. Queueing instead would mean a shed
//! snapshot leaving a client pinned at `stateNum 0` with no retry trigger anywhere — a silent,
//! permanent blank workspace.
//!
//! **Every diff is computed from the ACKED base, never the last SENT base** (`docs/45` §5.5, mosh
//! SSP). Because a diff assigns rather than mutates, `apply(d, apply(d, s)) == apply(d, s)` holds
//! by construction — duplicates and reorders are no-ops with no extra machinery — and a client four
//! hours offline costs exactly one diff, bounded by the SIZE of the tree rather than the DURATION
//! of its absence. There is no retransmit path on either side, and none is needed: this rides the
//! mux CONTROL sub-channel, which is TCP and unwindowed, so delivery is reliable and in-order. A
//! link that dies takes the channel with it and the client resubscribes.
//!
//! **One lock, and the ladder is under it.** It guards the inbox, the presence record, the roster
//! projection and the retention together, and it is a leaf — nothing nests beneath it, and no send
//! happens while it is held. The send is what can block: a document offer is built under the lock,
//! the lock is released, and only then do the bytes go out. That ordering is why the pump is a
//! THREAD rather than an inline call, and why [`WorkspaceSubscriber::drain`] is public to this
//! crate: the suite drives the same function the pump does, so what it asserts is what ships.

use std::fmt;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

use slopdesk_hostnet::subchannel::SubChannel;
use slopdesk_wire::document::{HostWorkspaceState, codec};
use slopdesk_wire::message::{RawUuid, WireMessage};
use slopdesk_wire::workspace::{
    WorkspaceEventKind, WorkspaceIntentResult, WorkspacePresenceRoster, WorkspacePresenceUpdate,
    WorkspaceRosterClient, WorkspaceSubscribe,
};
use slopdesk_workspace::sync_ladder::{Planned, Presence, Retention};

use crate::channel::{HostObserver, Offload};

/// Where a subscriber's frames go.
///
/// A seam rather than [`SubChannel`] by name for the reason every seam in this crate has one: the
/// suite has to see the exact bytes a ladder decision produced, and a real sub-channel would need a
/// socket, a link thread and a peer to say anything at all.
pub trait EventSink: Send + Sync + fmt::Debug {
    /// Sends one frame. `false` means the link is gone and the subscriber is finished.
    fn send(&self, message: &WireMessage) -> bool;
}

impl EventSink for SubChannel {
    fn send(&self, message: &WireMessage) -> bool {
        Self::send(self, message).is_ok()
    }
}

/// The freshest document this subscriber has been offered.
#[derive(Debug, Clone)]
struct Offer {
    epoch: RawUuid,
    state_num: i64,
    state: Arc<HostWorkspaceState>,
}

/// Everything one drain reads, under one lock.
#[derive(Debug)]
struct Inner {
    /// The client's own identity from `subscribe`. Presence is keyed by this, not by the
    /// subscriber id: two windows of one app are two connections and two identities, exactly as
    /// intended.
    client_instance_id: RawUuid,
    client_kind: u8,
    label: String,
    retention: Retention<Arc<HostWorkspaceState>>,
    /// Depth-1: an unsent prior offer is DISCARDED, not queued.
    pending_state: Option<Offer>,
    /// Presence is a FULL REPLACE and never diffed, so it coalesces the same way.
    pending_roster: Option<WorkspacePresenceRoster>,
    pending_subscribe: Option<WorkspaceSubscribe>,
    /// NOT coalesced: each one answers a distinct client-minted intent id, and a dropped one leaves
    /// that client's optimistic patch waiting for a timeout that need not happen. The list is
    /// bounded by in-flight intents, which the client itself bounds.
    pending_results: Vec<WorkspaceIntentResult>,
    closed: bool,
    /// Whether a pump thread is parked on the condvar.
    pumping: bool,
}

impl Inner {
    /// Whether a drain would do anything.
    const fn has_work(&self) -> bool {
        self.pending_state.is_some()
            || self.pending_roster.is_some()
            || self.pending_subscribe.is_some()
            || !self.pending_results.is_empty()
    }
}

/// One subscriber: its ladder, its inbox, and the channel both feed.
#[derive(Debug)]
pub struct WorkspaceSubscriber {
    /// Identity of this SUBSCRIBER — one per workspace channel, minted by the host.
    id: RawUuid,
    channel: Arc<dyn EventSink>,
    observer: Arc<dyn HostObserver>,
    inner: Mutex<Inner>,
    woken: Condvar,
}

impl WorkspaceSubscriber {
    /// A subscriber for the client that just sent `request`, holding nothing and owed a snapshot.
    #[must_use]
    pub fn new(
        id: RawUuid,
        channel: Arc<dyn EventSink>,
        request: &WorkspaceSubscribe,
        observer: Arc<dyn HostObserver>,
    ) -> Self {
        Self {
            id,
            channel,
            observer,
            inner: Mutex::new(Inner {
                client_instance_id: request.client_instance_id,
                client_kind: request.client_kind,
                label: request.label.clone(),
                retention: Retention::new(request.contributes_size(), request.follows_focus()),
                pending_state: None,
                pending_roster: None,
                pending_subscribe: None,
                pending_results: Vec::new(),
                closed: false,
                pumping: false,
            }),
            woken: Condvar::new(),
        }
    }

    /// This subscriber's id — the key the document files it under.
    #[must_use]
    pub const fn id(&self) -> RawUuid {
        self.id
    }

    /// Which CLIENT this subscriber speaks for — the instance id it subscribed under, and the one
    /// a pane's attachment is named by in the roster.
    ///
    /// Read off the mutable half rather than latched at construction: a re-subscribe carries the
    /// id again, and a client that reconnected under a new instance must be named by the new one.
    #[must_use]
    pub fn client_instance_id(&self) -> RawUuid {
        self.lock().client_instance_id
    }

    /// Starts the single pump thread, which drains until the subscriber closes.
    ///
    /// Separate from [`Self::new`] so the document can register the subscriber before the first
    /// frame can possibly ship. Idempotent: a second call finds the pump already running.
    pub fn start(self: &Arc<Self>, offload: &Arc<dyn Offload>) {
        let mut inner = self.lock();
        if inner.pumping || inner.closed {
            return;
        }
        inner.pumping = true;
        drop(inner);
        let pump = Arc::clone(self);
        offload.run(Box::new(move || pump.run()));
    }

    /// Stops the pump and drops every pending frame. Idempotent.
    pub fn close(&self) {
        let mut inner = self.lock();
        if inner.closed {
            return;
        }
        inner.closed = true;
        inner.pending_state = None;
        inner.pending_roster = None;
        inner.pending_subscribe = None;
        inner.pending_results = Vec::new();
        // The retained documents go with it: a subscriber that will never send again has no base to
        // diff against, and holding them would keep one whole workspace per retained frame alive
        // for the life of the daemon.
        inner.retention.clear();
        drop(inner);
        self.woken.notify_all();
    }

    /// Whether this subscriber has been closed.
    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.lock().closed
    }

    // MARK: - Inputs, called from the document — never blocking on a send

    /// Offers the freshest document.
    pub fn deliver_state(&self, epoch: RawUuid, state_num: i64, state: Arc<HostWorkspaceState>) {
        let mut inner = self.lock();
        if inner.closed {
            return;
        }
        inner.pending_state = Some(Offer {
            epoch,
            state_num,
            state,
        });
        drop(inner);
        self.woken.notify_all();
    }

    /// Offers the freshest roster.
    pub fn deliver_roster(&self, roster: WorkspacePresenceRoster) {
        let mut inner = self.lock();
        if inner.closed {
            return;
        }
        inner.pending_roster = Some(roster);
        drop(inner);
        self.woken.notify_all();
    }

    /// Queues one intent's answer.
    pub fn deliver_result(&self, result: WorkspaceIntentResult) {
        let mut inner = self.lock();
        if inner.closed {
            return;
        }
        inner.pending_results.push(result);
        drop(inner);
        self.woken.notify_all();
    }

    /// Records a client's ack. Highest wins; the ladder applies it at the next drain.
    pub fn note_ack(&self, state_num: i64) {
        let mut inner = self.lock();
        if inner.closed {
            return;
        }
        inner.retention.note_ack(state_num);
        drop(inner);
        self.woken.notify_all();
    }

    /// Records the client's view.
    ///
    /// Presence is per-CONNECTION and dies with the link, so the connection itself is the TTL — a
    /// timer could only ever fire after the subscriber was already gone.
    ///
    /// Returns `false` when the update is IGNORED because its clock is not newer. Newest wins with
    /// no merge: a client reconnecting with a stale clock must not resurrect a view it has since
    /// left.
    pub fn note_presence(&self, update: &WorkspacePresenceUpdate) -> bool {
        let mut inner = self.lock();
        if inner.closed {
            return false;
        }
        inner.retention.note_presence(Presence {
            presence_clock: update.presence_clock,
            viewing_tab_id: update.viewing_tab_id,
            viewing_pane_id: update.viewing_pane_id,
            cols: update.cols,
            rows: update.rows,
            contributes_size: update.contributes_size(),
            follows_focus: update.flags & WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS != 0,
        })
    }

    /// A repeat `subscribe` IS the resync verb — there is deliberately no separate "resend".
    pub fn note_resubscribe(&self, request: WorkspaceSubscribe) {
        let mut inner = self.lock();
        if inner.closed {
            return;
        }
        inner.pending_subscribe = Some(request);
        drop(inner);
        self.woken.notify_all();
    }

    /// This subscriber as the host describes it to everyone else.
    ///
    /// The view, the viewport and the folded flags are the ladder's; the identity half is this
    /// side's, because a UUID and a string are what a roster record is FOR.
    #[must_use]
    pub fn roster_record(&self) -> WorkspaceRosterClient {
        let inner = self.lock();
        let view = inner.retention.roster_view();
        let mut flags = 0_u8;
        if view.contributes_size {
            flags |= WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE;
        }
        if view.follows_focus {
            flags |= WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS;
        }
        WorkspaceRosterClient {
            client_instance_id: inner.client_instance_id,
            client_kind: inner.client_kind,
            flags,
            viewing_tab_id: view.viewing_tab_id,
            viewing_pane_id: view.viewing_pane_id,
            cols: view.cols,
            rows: view.rows,
            label: inner.label.clone(),
        }
    }

    /// How many document payloads this subscriber is still holding.
    ///
    /// The one failure a wire assertion could not catch: a retained state the ladder stopped
    /// needing but nothing dropped is a whole workspace document leaked per frame, per subscriber,
    /// for ever.
    #[must_use]
    pub fn retained_count(&self) -> usize {
        self.lock().retention.held()
    }

    // MARK: - Drain

    /// Sends everything the inbox holds, and keeps going until it is empty.
    ///
    /// A loop rather than one frame per call: an offer that arrives WHILE a send is in flight has
    /// already consumed its single wake, so without this the freshest state would sit in the
    /// pending slot until the next unrelated event.
    ///
    /// Returns `false` when the subscriber is finished — closed, or the link died mid-send.
    pub fn drain(&self) -> bool {
        loop {
            let Some(inbox) = self.take_inbox() else {
                return false;
            };

            // Causal order: a resubscribe resets the base, an ack advances it, and only then does a
            // frame get built against it.
            if let Some(request) = inbox.subscribe {
                self.apply_resubscribe(request);
            }
            self.lock().retention.apply_pending_ack();

            // Presence and intent results are epoch-independent — the client's apply rules never
            // check the epoch for kinds 2 and 3 — so before any snapshot has shipped they ride the
            // all-zero sentinel rather than a fabricated UUID.
            let loose = self.lock().retention.loose_epoch();
            let mut did_send = false;
            for result in &inbox.results {
                did_send = true;
                if !self.send(WorkspaceEventKind::IntentResult, loose, 0, 0, result.encode()) {
                    return false;
                }
            }
            if let Some(roster) = inbox.roster {
                did_send = true;
                if !self.send(WorkspaceEventKind::Presence, loose, 0, 0, roster.encode()) {
                    return false;
                }
            }
            if let Some(offer) = inbox.offer {
                match self.plan(&offer) {
                    // The far side HOLDS: a frame is in flight, nothing was changed, and the offer
                    // stays pending so it coalesces with whatever arrives next.
                    Planned::Hold => {},
                    planned => {
                        self.claim_pending_state();
                        did_send = true;
                        if !self.send_document(&offer, planned) {
                            return false;
                        }
                    },
                }
            }
            if !did_send {
                return true;
            }
        }
    }

    /// The pump thread's whole body: park, drain, repeat.
    fn run(self: &Arc<Self>) {
        loop {
            let mut inner = self.lock();
            while !inner.closed && !inner.has_work() {
                inner = self.woken.wait(inner).unwrap_or_else(PoisonError::into_inner);
            }
            let stop = inner.closed;
            drop(inner);
            if stop || !self.drain() {
                self.lock().pumping = false;
                return;
            }
        }
    }

    /// Everything the inbox held at one instant, or `None` when the subscriber is closed.
    ///
    /// A value, so the lock is released before any send.
    fn take_inbox(&self) -> Option<Inbox> {
        let mut inner = self.lock();
        if inner.closed {
            return None;
        }
        Some(Inbox {
            subscribe: inner.pending_subscribe.take(),
            roster: inner.pending_roster.take(),
            results: std::mem::take(&mut inner.pending_results),
            // The document offer is PEEKED, not taken: an offer the ladder turns out to HOLD must
            // stay pending so it coalesces with whatever arrives next, rather than being dropped on
            // the floor with no retry anywhere. The ack is not peeked at all — it lives in the
            // ladder, where the highest one wins until it is asked to apply it.
            offer: inner.pending_state.clone(),
        })
    }

    fn claim_pending_state(&self) {
        self.lock().pending_state = None;
    }

    fn apply_resubscribe(&self, request: WorkspaceSubscribe) {
        let mut inner = self.lock();
        inner.client_instance_id = request.client_instance_id;
        inner.client_kind = request.client_kind;
        inner.label = request.label;
        inner.retention.resubscribe(
            request.known_epoch,
            request.known_state_num,
            request.flags & WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE != 0,
            request.flags & WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS != 0,
        );
    }

    fn plan(&self, offer: &Offer) -> Planned<Arc<HostWorkspaceState>> {
        self.lock().retention.plan(offer.epoch)
    }

    /// Builds the planned frame and ships it, committing only if bytes actually went out.
    fn send_document(&self, offer: &Offer, planned: Planned<Arc<HostWorkspaceState>>) -> bool {
        let (kind, base_state_num, payload) = match planned {
            Planned::Hold => return true,
            Planned::Snapshot { reset_first } => {
                // A new epoch means a different document with an unrelated `stateNum` sequence.
                // Reset FIRST so no stale delta can ever be accepted, then snapshot — which is
                // self-contained and therefore epoch-independent, so a post-restart client
                // converges in ONE frame after it.
                if reset_first && !self.send(WorkspaceEventKind::Reset, offer.epoch, 0, 0, Vec::new()) {
                    return false;
                }
                (
                    WorkspaceEventKind::Snapshot,
                    0,
                    codec::encode_snapshot(&offer.state),
                )
            },
            Planned::Diff { base_state_num, base } => {
                let diff = offer.state.diff_from(&base);
                // Nothing changed since the acked base — say nothing. An empty diff still costs a
                // frame and an ack, and an idle host must be silent. Not committing is what leaves
                // the ladder exactly where it was.
                if diff.is_empty() {
                    return true;
                }
                (
                    WorkspaceEventKind::Diff,
                    base_state_num,
                    codec::encode_diff(&diff),
                )
            },
        };
        if !self.send(kind, offer.epoch, base_state_num, offer.state_num, payload) {
            return false;
        }
        self.lock()
            .retention
            .commit(offer.state_num, Arc::clone(&offer.state));
        true
    }

    /// Sends one frame. `false` means the channel is gone — the caller stops draining.
    ///
    /// A dead link is not an error to recover from here: the mux tears the channel down and the
    /// client resubscribes.
    fn send(&self, kind: WorkspaceEventKind, epoch: RawUuid, base: i64, new: i64, payload: Vec<u8>) -> bool {
        let sent = self.channel.send(&WireMessage::WorkspaceEvent {
            kind: kind.as_byte(),
            epoch,
            base_state_num: base,
            new_state_num: new,
            payload,
        });
        if !sent {
            self.observer.log(&format!(
                "workspace channel {}: send failed — subscriber dropped",
                slopdesk_ids::uuid_text(self.id),
            ));
            self.close();
        }
        sent
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// One drain's worth of inbox, taken as a value so nothing is held across a send.
#[derive(Debug)]
struct Inbox {
    subscribe: Option<WorkspaceSubscribe>,
    roster: Option<WorkspacePresenceRoster>,
    results: Vec<WorkspaceIntentResult>,
    offer: Option<Offer>,
}
