//! The accept loop: sockets in, [`MuxEvent`]s out, and a [`Host`] told about each one.
//!
//! ## The one piece that was never its own thing
//! Every other part of this port had a Swift original to read. This did not: it was the body of
//! `HostServer.start()`, interleaved with the bind, the retry, the task nursery and the actor hops
//! around all three. Written down on its own it is small, and the reason it is small is that both
//! sides of it were finished first — `slopdesk-hostnet` pairs two sockets and `slopdesk-muxnet`
//! turns the pair into a stream of events,
//! `slopdesk-hostserver` turns an event into a decision, and nothing in between needs to decide
//! anything.
//!
//! ## Threads, not a runtime
//! `docs/60` §3. One thread per connection, parked in [`Receiver::recv`], which is a blocking read
//! on a channel two link threads feed. It ends when the connection's event sender drops, which
//! happens when both link threads have returned — so the thread's lifetime IS the connection's, and
//! there is no cancellation to get wrong.
//!
//! ## Why the link-down handling looks asymmetric
//! [`MuxEvent::Closed`] carries a channel id and [`MuxEvent::LinkDown`] carries a list of them, and
//! only the first is turned into a key. That is deliberate, and it is the composition's rule rather
//! than this file's: a CLOSE is a decision about one channel, so the pane behind that channel is
//! over; a LINK DOWN is an accident that says nothing about any one channel, so every pane on the
//! connection is a DETACH candidate and [`Host::handle_link_down`] decides each one's fate against
//! the retention rules. Feeding the reported ids in one at a time would be exactly the mistake the
//! two variants exist to prevent.

use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::thread;

use slopdesk_hostnet::listener::{Listener, ListenerHandle};
use slopdesk_hostserver::{Host, Peer};
use slopdesk_muxnet::connection::{MuxConnection, MuxEvent, PairedConnection};
use slopdesk_muxsession::registry::Key;
use slopdesk_wire::mux::admission::Role;

use crate::peer::ConnectionPeer;

/// How long a link may sit unpaired before the listener reaps it.
///
/// A mux client dials TWICE — control then data — and the pair is completed by a preamble on each.
/// A single socket that arrives and never gets its partner is a half-open connection holding an fd,
/// and on a mesh link that is a routine consequence of a phone walking out of range mid-dial.
const PARTNER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// A bound listener, its accept thread, and the handle that stops both.
#[derive(Debug)]
pub struct Listening {
    handle: ListenerHandle,
    bound_port: u16,
}

impl Listening {
    /// Binds `port`, starts accepting, and serves every completed pair to `host`.
    ///
    /// The accept thread is spawned here rather than returned, because there is nothing a caller
    /// could usefully do with it: it ends when the listener's pair stream closes, and the ONLY
    /// thing that closes that stream is [`Self::stop`].
    ///
    /// # Errors
    /// Whatever `bind` or `listen` reported. A daemon that cannot bind has no service to offer, so
    /// this is the one failure in the whole start-up that is fatal.
    pub fn start(port: u16, host: &Arc<Host>) -> std::io::Result<Self> {
        let listener = Listener::bind_with(port, PARTNER_TIMEOUT)?;
        let bound_port = listener.bound_port();
        let (pairs, handle) = listener.serve();
        let accepting = Arc::clone(host);
        // A named thread, because this one shows up in every crash report and `sample` output the
        // host ever produces, and "thread 7" is not an answer to which loop wedged.
        let spawned = thread::Builder::new()
            .name("slopdesk-accept".to_owned())
            .spawn(move || accept_loop(&pairs, &accepting));
        if let Err(why) = spawned {
            // Nothing has been served yet, so the listener is stopped rather than left accepting
            // into a queue with no reader — a client that connected would otherwise sit through the
            // preamble and then wait for ever.
            handle.stop();
            return Err(why);
        }
        Ok(Self { handle, bound_port })
    }

    /// The port actually bound — the caller's answer when it asked for `0`.
    #[must_use]
    pub const fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Stops accepting. Live connections are NOT touched: ending them is [`Host::stop`]'s ladder,
    /// and it has an order this call must not pre-empt.
    pub fn stop(&self) {
        self.handle.stop();
    }
}

/// Serves each completed pair until the listener stops.
fn accept_loop(pairs: &Receiver<PairedConnection>, host: &Arc<Host>) {
    // `recv` ends only when the listener's sender drops, which is `ListenerHandle::stop`. A `for`
    // over the receiver says exactly that and cannot accidentally grow a second exit.
    while let Ok(pair) = pairs.recv() {
        serve_connection(pair, host);
    }
}

/// Adopts one paired connection and gives its events a thread.
fn serve_connection(pair: PairedConnection, host: &Arc<Host>) {
    let (connection, events, threads) = MuxConnection::serve(pair, Role::Host);
    let peer: Arc<dyn Peer> = Arc::new(ConnectionPeer::new(Arc::clone(&connection)));
    // Filed BEFORE the event thread starts. The composition's stop drains its peers to close them,
    // and a connection that were served first could take a channel, be counted by the workspace
    // fan-out, and still not be in the set the stop closes.
    host.note_peer(&peer);
    let serving = Arc::clone(host);
    let spawned = thread::Builder::new()
        .name("slopdesk-connection".to_owned())
        .spawn(move || {
            drain(&events, &serving, &peer);
            // The link threads have returned by now — the event sender they share is what `drain`
            // parked on. Joining is what makes "this connection is over" true of its THREADS as
            // well as its sockets, which is the difference `live_thread_count` measures.
            threads.join();
        });
    if spawned.is_err() {
        // A process too exhausted to make a thread cannot serve this client, and a connection whose
        // events nobody drains is worse than a refused one: the peer waits for an ack that no code
        // path will ever send. Close it, and let the client's own reconnect decide when to try
        // again.
        //
        // The two link threads are not joined on this path, because `threads` went into the closure
        // that would not spawn and was dropped with it. That is the right outcome rather than a
        // leak: closing the connection is what ends both loops, and a detached `JoinHandle` still
        // reclaims its thread when the thread returns. The only thing given up is knowing WHEN,
        // which is a fact nobody on this path has a use for.
        connection.close();
    }
}

/// Turns one connection's events into calls on the composition, until the connection ends.
fn drain(events: &Receiver<MuxEvent>, host: &Arc<Host>, peer: &Arc<dyn Peer>) {
    let connection = peer.connection();
    while let Ok(event) = events.recv() {
        match event {
            MuxEvent::Opened(open) => host.open_channel(open, peer),
            MuxEvent::Closed { channel_id, .. } => {
                // The REASON is the peer's explanation and it is deliberately dropped here: what a
                // close means to a pane is decided by the retention rules, not by what the client
                // said about its own intent. The reason travels the other way — see
                // [`Peer::close_channel`].
                host.close_channel(Key::new(connection, channel_id));
            },
            // The channel list is not walked; see the module note. `failed` is not read either, for
            // the same reason: whether the link died or said goodbye changes nothing about which
            // panes are now unattached, and the retention rules already distinguish the cases that
            // matter.
            MuxEvent::LinkDown { .. } => host.handle_link_down(connection),
        }
    }
    // The stream ended, so both link threads have. Unconditional, and idempotent on purpose: a
    // clean FIN arrives as a `LinkDown` event AND closes the stream, while a decoder fault can
    // close the stream with no event at all. Running it twice detaches nothing the first pass
    // left, and the connection is forgotten and its peer closed inside the same call — which is
    // why there is no `forget_connection` here to pair with it.
    host.handle_link_down(connection);
}
