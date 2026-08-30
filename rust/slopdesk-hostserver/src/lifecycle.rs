//! How a pane, a link and the daemon END — `docs/60` **D.6.5**.
//!
//! Four ways out, and the whole module is the finding that they are FOUR rather than one:
//!
//! | what ended | who hears | the shell |
//! | --- | --- | --- |
//! | one client left a shared pane ([`Host::leave_channel`]) | nobody else | keeps running |
//! | the link dropped ([`Host::handle_link_down`]) | the other clients | keeps running, PARKED |
//! | the topology stopped placing the pane ([`Host::reap_panes`]) | every subscriber | dies |
//! | the daemon stopped ([`Host::stop`]) | nobody — it is going too | keeps running, LET GO |
//!
//! The first and the last are the two that were once the same code path, and collapsing them is the
//! product change `docs/51` is about: "this daemon is going away" is not "these panes are over".
//!
//! ## Refcounted, not reference-free
//!
//! Under a fan-out one pane is named by N keys. A `channelClose` is therefore only ever ONE client
//! leaving, and reaping on it would take down another client's running agent — the over-reap
//! `docs/45` §8.6 rules out. So every departure here goes through
//! [`Pane::remove_subscriber`](crate::Pane::remove_subscriber) first and reaps only on the `true`
//! it returns. The one departure that is refcount-BLIND is the topology reap, and it is blind on
//! purpose: `closePane` is a layout fact, not a socket event, and leaving a shell alive there would
//! be the ORPHAN the same section rules out. Both halves of that pair are load-bearing, which is
//! why they are two functions rather than one with a flag.
//!
//! ## The stop's order is the module's real content
//!
//! [`Host::stop`] is seven steps and the ORDER of every one of them is a decision — see its own
//! doc. Two are worth naming here because nothing else in the crate would explain them:
//!
//! - **the note goes first.** [`Host::mark_stopping`] then
//!   [`LetGo::note`](crate::adopt::LetGo::note) — before ANY drain, because the note is an
//!   enumeration of the live tables and a drained table enumerates to nothing.
//! - **the relinquish is parallel AND joined.** N panes are let go on N threads, and `stop` does
//!   not return until the last one is done: hostd's duplicate of every master must be closed before
//!   the process calls `exit(0)`, or a half-torn-down pane's last bytes never reach its journal.

use core::time::Duration;
use std::collections::BTreeSet;
use std::sync::{Arc, mpsc};
use std::time::Instant;

use slopdesk_ids::uuid_text;
use slopdesk_muxsession::registry::{Key, Subscriber, Uuid};
use slopdesk_wire::mux::envelope::MuxCloseReason;

use crate::host::Host;
use crate::pane::Pane;

/// How long the stop waits for the panes it is letting go.
///
/// Bounded rather than open-ended, and the bound is the same one [`crate::Relinquished::wait`]
/// documents for the parked half: a relinquish can spend seconds waiting for input-quiet, and a
/// pane whose teardown wedges must not be able to hold the daemon open for ever. Long enough that
/// the ordinary case never reaches it, short enough that a wedged one is a pause and not a hang.
const LETTING_GO_GRACE: Duration = Duration::from_secs(5);

impl Host {
    // ------------------------------------------------------------------- one client leaving

    /// A peer `channelClose` on a PANE channel: a refcounted LEAVE.
    ///
    /// The LAST member leaving reaps the pane exactly as a close always has
    /// ([`Host::close_channel`] — kill the shell, delete the journal). An earlier one just stops
    /// watching. Idempotent: a key already gone is a no-op.
    ///
    /// This is the function the receive loop's close verb must call, NOT `close_channel` — a
    /// fan-out closed through the unrefcounted door takes the other client's agent with it. The
    /// child-exit route is the other way round on purpose: a dead shell ends the pane for everyone,
    /// so [`crate::channel::CloseOnExit`] keeps pointing at `close_channel`.
    pub fn leave_channel(&self, key: Key) {
        let (pane, subscriber) = {
            let sessions = self.sessions();
            (sessions.pane(key).map(Arc::clone), sessions.subscriber_of(key))
        };
        let Some(pane) = pane else {
            return;
        };
        if pane.remove_subscriber(subscriber) {
            self.close_channel(key);
            return;
        }
        // Somebody else is still holding the pane: drop only THIS client's registration. Guarded by
        // identity, so a stale close cannot unfile a same-key successor.
        let _unfiled = self.sessions().detach_if_names(key, &pane);
        self.emit_connection_count();
        self.workspace().fact_changed();
        self.observer().log(&format!(
            "mux channel {} (conn {}): left shared pane",
            key.channel,
            uuid_text(key.connection)
        ));
    }

    /// Retires ONE laggard member of a live pane: it stops watching, and its channel is closed with
    /// the reason that says the pane is still there.
    ///
    /// The eviction itself is decided far below — a member parked on an exhausted credit window —
    /// and this is the server half of it. `SubscriberEvicted` is the ONE place the difference from
    /// a topology reap survives on the wire: the pane, its shell and its other members are all
    /// still here, so the evicted client is looking at something it may reattach to. The close
    /// frame is the only thing it will ever be told — nothing removes the pane from its topology —
    /// so the reason has to ride it.
    pub fn evict_subscriber(&self, pane: &Arc<dyn Pane>, subscriber: Subscriber) {
        let Some(key) = self.sessions().key_of(pane, subscriber) else {
            return;
        };
        self.leave_channel(key);
        if let Some(peer) = self.peer(key.connection) {
            peer.close_channel(key.channel, MuxCloseReason::SubscriberEvicted);
        }
    }

    // -------------------------------------------------------------------- the topology reap

    /// Tears down every live pane the topology stopped naming: one `channelClose` to EVERY
    /// subscriber holding it, then the unconditional teardown.
    ///
    /// The UNCONDITIONAL half of the close story, and it is driven by the DOCUMENT rather than by a
    /// socket: `closePane` / `closeTab` are topology deletes applied host-side, so "this pane is
    /// gone" is a layout fact. [`Host::close_channel`] drops every key that aliases the pane, so
    /// the loop is idempotent — the first reap of a fanned-out pane takes all of its channels
    /// with it.
    ///
    /// The frames go out BEFORE the teardown, so a client is told why its rows are about to stop
    /// rather than inferring it from a silent pane.
    pub fn reap_panes(&self, gone: &BTreeSet<Uuid>) {
        if gone.is_empty() {
            return;
        }
        let doomed: Vec<Key> = {
            let sessions = self.sessions();
            gone.iter()
                .filter_map(|id| sessions.pane_for_session(*id))
                .flat_map(|pane| sessions.keys_naming(pane))
                .collect()
        };
        for key in &doomed {
            if let Some(peer) = self.peer(key.connection) {
                // `Retired`: the pane is leaving the layout, so the session id this channel names
                // is about to stop existing. A client that re-opens it gets a
                // SPAWN.
                peer.close_channel(key.channel, MuxCloseReason::Retired);
            }
        }
        for key in doomed {
            self.close_channel(key);
        }
    }

    /// Re-decides whether every pane already open on `connection` votes in its size fold.
    ///
    /// Addressed to the SUBSCRIBER this connection rides, never to the pane's primary: under a
    /// fan-out one pane is named by N keys, and a phone subscribing would otherwise mark the MAC's
    /// contribution passive and hand the phone the vote it was denied.
    pub fn resolve_size_passivity(&self, connection: Uuid, passive: bool) {
        self.set_size_passive(connection, passive);
        let members = self.sessions().members_on(connection);
        for member in members {
            member.pane.add_resize_contributor(member.subscriber, passive);
        }
    }

    // ------------------------------------------------------------------------- the link drop

    /// A physical link drop: park every pane this connection was watching, then reap the
    /// connection.
    ///
    /// Retires each of THIS connection's members and parks the pane only when its LAST one is gone.
    /// Detaching per key would let one client closing its lid engage the offline gate — which
    /// pauses the PTY drain — while the other client is still watching: its pane goes
    /// dead-quiet while the shell keeps producing.
    ///
    /// With no detached store there is nowhere to park, so [`Host::park`] ends the pane instead —
    /// a fallback rather than a policy, and it is what a host with retention off has always done.
    pub fn handle_link_down(self: &Arc<Self>, connection: Uuid) {
        // ONE acquisition: a racing `channelOpen` must not see these as "already live" between the
        // read and the removal.
        let leaving = self.sessions().detach_all_on(connection);
        if !leaving.is_empty() {
            self.emit_connection_count();
        }
        for member in &leaving {
            if member.pane.remove_subscriber(member.subscriber) {
                self.park(member.key, &member.pane);
            }
        }
        // `attached` → `detached` is a visible fact: the remaining clients render the pane as
        // running with nobody watching, rather than as still held by the client that just died.
        // ONCE, not per member — N kicks would cost N reconciles for one event.
        if !leaving.is_empty() {
            self.workspace().fact_changed();
        }
        // Always, even with nothing leaving: a connection that never opened a pane still holds a
        // socket pair and two receive loops, and its workspace subscriber expires with its link.
        self.workspace().drop_connection(connection);
        if let Some(peer) = self.forget_connection(connection) {
            peer.close();
        }
    }

    // ---------------------------------------------------------------------------- the stop

    /// Stops the daemon: every live pane is LET GO, every detached one too, and every link closed.
    ///
    /// Seven steps, and each one's position is a decision:
    ///
    /// 1. **[`Host::mark_stopping`]** — first, so a `channelOpen` racing this shutdown is refused
    ///    rather than forking a shell that would be minted after the drain and outlive the daemon.
    ///    The accepted connections' receive loops keep running past a listener cancel.
    /// 2. **[`Host::note_panes_let_go`]** — before any drain, because the note is an enumeration of
    ///    the live tables. See `docs/60` D.6.3: it is written there because that is where the
    ///    note's writer lives, and called here because this is where the enumeration still exists.
    /// 3. **drain the tables** — panes and control panes, deduped, under the registry's own lock. A
    ///    fan-out's N keys name ONE pane and returning it N times would relinquish it N times.
    /// 4. **relinquish, in parallel, JOINED** — see the module doc. RELINQUISH, not shut down: the
    ///    shell is left running under superd and the next hostd adopts it back.
    /// 5. **the workspace half** — flush the store, end the document, clear the subscriber map.
    /// 6. **let the detached panes go too** — the ones whose client already left. Killing exactly
    ///    these on a daemon stop was the sharpest edge of the old behaviour: nobody was watching
    ///    them, so nobody could object.
    /// 7. **close every link** — including the ones carrying no channel, which is the half that
    ///    makes this a fix for the `EMFILE` drift rather than for its visible part.
    ///
    /// What it deliberately does NOT do: terminate the code-server, simulator or Android backends,
    /// or drop superd's client connection. Those are objects this host does not own — they are the
    /// Swift stop's, until stage F takes the process itself.
    pub fn stop(self: &Arc<Self>) {
        self.mark_stopping();
        self.note_panes_let_go();

        let live = {
            let mut sessions = self.sessions();
            let mut live = sessions.drain_panes();
            live.extend(sessions.drain_control());
            live
        };
        // The map is now empty → report 0 distinct client connections.
        self.observer().connection_count(0);
        self.let_every_pane_go(live);

        self.workspace().shutdown();

        if let Some(store) = self.detached()
            && !store.relinquish_all().wait(LETTING_GO_GRACE)
        {
            self.observer()
                .log("stop: a parked pane did not finish being let go in time");
        }

        for peer in self.drain_peers() {
            peer.close();
        }
    }

    /// Relinquishes `panes` off this thread, and returns once every one of them is done.
    ///
    /// The join is the whole point, and a channel is how it is done without a handle to join: each
    /// worker drops its end when it finishes, and the receiver counts to N. Two ways out other than
    /// the count, and both END the wait rather than parking on it — a stop that cannot finish is
    /// worse than a stop that finished without one pane's last bytes. A disconnect means the
    /// [`Offload`](crate::Offload) refused a thread and dropped the closure; a timeout means a
    /// relinquish wedged, and it is bounded by the same [`LETTING_GO_GRACE`] the parked half uses.
    fn let_every_pane_go(&self, panes: Vec<Arc<dyn Pane>>) {
        if panes.is_empty() {
            return;
        }
        let expected = panes.len();
        let (done, joined) = mpsc::channel::<()>();
        for pane in panes {
            let done = done.clone();
            self.offload().run(Box::new(move || {
                pane.relinquish();
                drop(done);
            }));
        }
        // The sender this scope holds would keep the channel open for ever.
        drop(done);
        // ONE deadline for the whole set rather than one per pane: the relinquishes run
        // concurrently, so N × the grace would be a bound that describes nothing.
        let deadline = Instant::now() + LETTING_GO_GRACE;
        for _finished in 0..expected {
            let left = deadline.saturating_duration_since(Instant::now());
            if joined.recv_timeout(left).is_err() {
                self.observer()
                    .log("stop: a live pane did not finish being let go in time");
                return;
            }
        }
    }
}
