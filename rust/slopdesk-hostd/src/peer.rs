//! The composition's [`Peer`], over a real mux connection.
//!
//! Four methods, each one call across. That is not a sign the door was unnecessary — it is the
//! point of it: [`slopdesk_hostserver`] decides WHAT to tell a client and never how, so its whole
//! suite drives the open ladder over a recording fake and asserts on the answers rather than on a
//! socket. This file is where the answers become frames, and it is the only place in the tree that
//! knows both vocabularies.
//!
//! ## The id crosses as bytes, not as a conversion
//! [`ConnectionId`] is sixteen wire bytes and [`Uuid`] is `[u8; 16]`, so the "conversion" is a copy
//! of the same sixteen bytes in the same order. Spelling it out here rather than giving either
//! crate a `From` for the other keeps the dependency edge one-way: the transport does not know the
//! registry exists, and the registry does not know a socket does.

use std::fmt;
use std::sync::Arc;

use slopdesk_hostserver::Peer;
use slopdesk_muxnet::connection::MuxConnection;
use slopdesk_muxsession::registry::Uuid;
use slopdesk_wire::mux::envelope::MuxCloseReason;

/// One client connection, as the composition sees it.
pub struct ConnectionPeer {
    connection: Arc<MuxConnection>,
    /// The same sixteen bytes as [`MuxConnection::connection_id`], kept here so
    /// [`Peer::connection`] is a field read on the tables' hot path rather than a call and a
    /// copy per lookup.
    id: Uuid,
}

impl fmt::Debug for ConnectionPeer {
    /// The id and nothing else. The connection itself holds two link handles and a table of live
    /// sub-channels, and a `Debug` that walked them would take the table's lock from whatever
    /// thread happened to be logging — including, on the teardown path, one that already holds
    /// it.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ConnectionPeer")
            .field("id", &self.id)
            .finish_non_exhaustive()
    }
}

impl ConnectionPeer {
    /// Wraps `connection` as the peer its channels will be answered on.
    #[must_use]
    pub fn new(connection: Arc<MuxConnection>) -> Self {
        let id = *connection.connection_id().as_bytes();
        Self { connection, id }
    }

    /// The connection this peer speaks for — the accept loop's own handle back to it.
    ///
    /// Named `link` rather than `connection` on purpose: [`Peer::connection`] answers an ID, this
    /// answers the transport, and two methods one letter apart that return different things is how
    /// a teardown ends up closing an id.
    #[must_use]
    pub const fn link(&self) -> &Arc<MuxConnection> {
        &self.connection
    }
}

impl Peer for ConnectionPeer {
    fn connection(&self) -> Uuid {
        self.id
    }

    fn ack(&self, channel: u32, accepted: bool, resume_from: i64) {
        self.connection.send_open_ack(channel, accepted, resume_from);
    }

    fn close_channel(&self, channel: u32, reason: MuxCloseReason) {
        self.connection.close_channel(channel, reason);
    }

    fn close(&self) {
        self.connection.close();
    }
}
