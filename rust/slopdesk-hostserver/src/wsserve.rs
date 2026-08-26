//! The workspace-document channel (`channelClass == 1`, `docs/45` §5.1) — accept, serve, reconcile,
//! and apply what clients ask for.
//!
//! The traffic is asymmetric on purpose. The host publishes a whole document and diffs against what
//! each subscriber acked; a client sends only INTENTS — never state — so there is exactly one place
//! the topology changes and no merge function anywhere.
//!
//! ## Only the CONTROL sub-channel is used
//!
//! The DATA sub-channel the open also creates stays idle, and that asymmetry is deliberate: the
//! document is small, latency-sensitive control traffic, and CONTROL is unwindowed, so a workspace
//! frame can never be stalled behind a PTY output flood waiting on flow-control credit.
//!
//! ## A malformed body is DROPPED, never a teardown
//!
//! Tearing the channel down on one bad frame would hand a peer a trivial way to blank every other
//! client's workspace, and these bytes carry no authentication of any kind — security is the
//! `WireGuard` mesh, not this layer. The only frames that get no answer at all are the ones with no
//! `intentID` to answer to; every DECODABLE intent gets a definite verdict, including a refusal, so
//! a client's optimistic patch is rolled back at once instead of waiting out a timeout.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, PoisonError, Weak};

use slopdesk_hostnet::connection::ChannelOpen;
use slopdesk_ids::uuid_text;
use slopdesk_wire::document::codec;
use slopdesk_wire::message::{RawUuid, WireMessage};
use slopdesk_wire::workspace::{
    WorkspaceClientKind, WorkspaceIntent, WorkspaceIntentResult, WorkspaceIntentStatus,
    WorkspacePresenceUpdate, WorkspaceRequestVerb, WorkspaceSubscribe,
};

use crate::channel::{HostObserver, Offload, Peer, WorkspaceChannels};
use crate::host::SessionIds;
use crate::subscriber::{EventSink, WorkspaceSubscriber};
use crate::workspace::WorkspaceDocument;

/// hostd's workspace channel class: one subscriber per connection, serving one document.
#[derive(Debug)]
pub struct WorkspaceService {
    document: Arc<WorkspaceDocument>,
    offload: Arc<dyn Offload>,
    observer: Arc<dyn HostObserver>,
    ids: Arc<dyn SessionIds>,
    /// Connection → the subscriber behind it. A connection appears here only once its `subscribe`
    /// has landed, which is what makes the open's refusal test the right one — see [`Self::open`].
    subscribed: Mutex<BTreeMap<RawUuid, Arc<WorkspaceSubscriber>>>,
    /// This service, as the receive loop must hold it.
    ///
    /// A loop that outlives the `open` call needs an owning handle, and `&self` cannot recover one
    /// — so the handle is minted with the value. WEAK, because the strong edge runs the other way:
    /// [`crate::Host`] holds this service, and a strong self-reference would keep every daemon
    /// alive for ever.
    me: Weak<Self>,
}

impl WorkspaceService {
    /// The service around `document`.
    #[must_use]
    pub fn new(
        document: Arc<WorkspaceDocument>,
        offload: Arc<dyn Offload>,
        observer: Arc<dyn HostObserver>,
        ids: Arc<dyn SessionIds>,
    ) -> Arc<Self> {
        Arc::new_cyclic(|me| {
            Self {
                document,
                offload,
                observer,
                ids,
                subscribed: Mutex::new(BTreeMap::new()),
                me: me.clone(),
            }
        })
    }

    /// The document this service publishes.
    #[must_use]
    pub const fn document(&self) -> &Arc<WorkspaceDocument> {
        &self.document
    }

    /// One type-17 request off a connection's control sub-channel.
    ///
    /// Public to the crate so the suite drives the same dispatch the receive loop does.
    pub fn handle(&self, connection: RawUuid, verb: u8, payload: &[u8], sink: &Arc<dyn EventSink>) {
        match WorkspaceRequestVerb::from_byte(verb) {
            Some(WorkspaceRequestVerb::Subscribe) => {
                let Ok(request) = WorkspaceSubscribe::decode(payload) else {
                    self.observer.log(&format!(
                        "workspace channel (conn {}): malformed subscribe dropped",
                        uuid_text(connection)
                    ));
                    return;
                };
                self.apply_subscribe(connection, request, sink);
            },

            Some(WorkspaceRequestVerb::Ack) => {
                // `[i64 BE stateNum]`, and nothing else — a body of any other length is a framing
                // bug, not a value to salvage.
                let Some(state_num) = codec::decode_i64(payload) else {
                    return;
                };
                if let Some(subscriber) = self.subscriber(connection) {
                    self.document.note_ack(subscriber.id(), state_num);
                }
            },

            Some(WorkspaceRequestVerb::Presence) => {
                let Ok(update) = WorkspacePresenceUpdate::decode(payload) else {
                    return;
                };
                let Some(subscriber) = self.subscriber(connection) else {
                    return;
                };
                // An older clock is IGNORED, never merged: a client reconnecting with a stale clock
                // must not resurrect a view it has since left.
                if subscriber.note_presence(&update) {
                    self.document.broadcast_roster();
                }
            },

            Some(WorkspaceRequestVerb::Intent) => {
                // A malformed envelope is dropped in silence — there is no `intentID` to answer to.
                let Ok(intent) = WorkspaceIntent::decode(payload) else {
                    return;
                };
                let Some(subscriber) = self.subscriber(connection) else {
                    return;
                };
                let (status, gone) = self.document.apply_intent(intent.op, &intent.args);
                subscriber.deliver_result(WorkspaceIntentResult {
                    intent_id: intent.intent_id,
                    status: status.as_byte(),
                });
                if status == WorkspaceIntentStatus::Applied {
                    // `closePane` / `closeTab` run HOST-side, so the DOCUMENT is where "this pane is
                    // gone" is decided — a `channelClose` is only ever one client leaving, and under
                    // a fan-out reaping on it would take down the other client's running agent.
                    if let Some(panes) = self.document.panes() {
                        panes.reap(&gone);
                    }
                    // The topology moved, so the pane inventory may have too — a close reaps, a
                    // spawn wants its liveness published before the client's optimistic patch
                    // retires.
                    self.document.reconcile_now();
                }
            },

            None => {
                self.observer.log(&format!(
                    "workspace channel (conn {}): unknown verb {verb} dropped",
                    uuid_text(connection)
                ));
            },
        }
    }

    /// A `subscribe`, which is both the FIRST one and the resync verb.
    fn apply_subscribe(&self, connection: RawUuid, request: WorkspaceSubscribe, sink: &Arc<dyn EventSink>) {
        if let Some(existing) = self.subscriber(connection) {
            // A repeat subscribe IS the resync verb — and it may carry a different kind than the
            // first one did, so the fold is re-settled here too.
            self.resolve_size_passivity(connection, request.client_kind);
            self.document.note_resubscribe(existing.id(), request);
            return;
        }
        let Some(id) = self.ids.mint() else {
            self.observer.log(&format!(
                "workspace channel (conn {}): refused — no subscriber id could be minted",
                uuid_text(connection)
            ));
            return;
        };
        let subscriber = Arc::new(WorkspaceSubscriber::new(
            id,
            Arc::clone(sink),
            &request,
            Arc::clone(&self.observer),
        ));
        self.subscribed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(connection, Arc::clone(&subscriber));
        subscriber.start(&self.offload);
        // The subscribe is where this connection's DEVICE KIND becomes known, and the size fold's
        // predicate depends on it. Panes opened on this connection before the subscribe landed were
        // resolved against a workspace channel that did not exist yet — settle them now, before the
        // document broadcasts a roster that would describe the old verdict.
        self.resolve_size_passivity(connection, request.client_kind);
        self.document.add_subscriber(&subscriber);
        // First subscribe: publish what is true RIGHT NOW rather than waiting up to a tick for the
        // reconciler. A client that has just connected is precisely the one with nothing.
        self.document.reconcile_now();
    }

    /// Retires this connection's subscriber. Clean close and error land here alike: either way the
    /// subscriber is gone.
    pub fn drop_subscriber(&self, connection: RawUuid) {
        let gone = self
            .subscribed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&connection);
        if let Some(subscriber) = gone {
            self.document.remove_subscriber(subscriber.id());
        }
    }

    /// Tells the server whether this connection's panes vote in their size fold.
    ///
    /// **An unknown kind CONTRIBUTES.** That is the shipped `slopdesk-client` CLI, which only ever
    /// opens class 0 or 2 — defaulting a device the host cannot name to passive would leave it
    /// unable to size its own pane. Only the kind the host can positively identify as a phone is
    /// denied the vote, because a phone must never crush a Mac.
    fn resolve_size_passivity(&self, connection: RawUuid, client_kind: u8) {
        let passive = WorkspaceClientKind::from_byte(client_kind) == Some(WorkspaceClientKind::Ios);
        if let Some(panes) = self.document.panes() {
            panes.resolve_size_passivity(connection, passive);
        }
    }

    fn subscriber(&self, connection: RawUuid) -> Option<Arc<WorkspaceSubscriber>> {
        self.subscribed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&connection)
            .map(Arc::clone)
    }
}

impl WorkspaceChannels for WorkspaceService {
    fn open(&self, open: Box<ChannelOpen>, peer: &Arc<dyn Peer>) -> bool {
        let connection = peer.connection();
        let channel = open.channel_id;
        if self.subscriber(connection).is_some() {
            // Two subscribers behind one link would each keep their own acked base for the same
            // viewer, and the roster would show one device twice.
            self.observer.log(&format!(
                "workspace channel {channel} (conn {}): refused — already open",
                uuid_text(connection)
            ));
            return false;
        }
        let Some(service) = self.me.upgrade() else {
            // The service is being dropped; a channel accepted now would be served by nobody.
            return false;
        };
        peer.ack(channel, true, 0);
        let sink: Arc<dyn EventSink> = open.control;
        let inbound = open.control_inbound;
        self.observer.log(&format!(
            "workspace channel {channel} (conn {}) accepted",
            uuid_text(connection)
        ));
        // The receive loop outlives this call and ends only when the link does, so it is the one
        // piece of this ladder that cannot run inline.
        self.offload.run(Box::new(move || {
            for message in inbound {
                if let WireMessage::WorkspaceRequest {
                    verb, ref payload, ..
                } = message
                {
                    service.handle(connection, verb, payload, &sink);
                }
            }
            // Clean close OR error: either way the subscriber is gone.
            service.drop_subscriber(connection);
        }));
        true
    }

    fn fact_changed(&self) {
        self.document.kick_reconcile();
    }

    fn drop_connection(&self, connection: RawUuid) {
        self.drop_subscriber(connection);
    }

    fn shutdown(&self) {
        // The debounce first: a write still sitting in it when the process exits loses the last
        // thing the user did, and nothing below makes it land any sooner.
        self.document.flush_store();
        self.document.shutdown();
        // The document's own teardown already closed every subscriber; this clears the MAP, so a
        // Start→Stop→Start cycle does not refuse the returning client's channel as a duplicate.
        self.subscribed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
    }
}
