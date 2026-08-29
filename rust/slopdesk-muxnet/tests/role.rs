//! The one property the G.1 split is FOR: this crate is role-generic, and the asymmetry it obeys is
//! `slopdesk_wire::mux::admission`'s rather than its own.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.1. Everything else about a `MuxConnection` was
//! already covered by `slopdesk-hostnet`'s suite, which drives the whole host stack on real
//! sockets. What that suite cannot check is the half that did not exist before the split: that the
//! SAME type, served at [`Role::Client`], answers the asymmetric questions the other way — and that
//! it does so with no branch of its own, which is why each test below names the `admission` rule it
//! is the visible consequence of rather than a line of `connection.rs`.
//!
//! The one guard that IS a branch — a responder refusing to initiate an open — is `initiator.rs`'s,
//! beside the send path it guards.

#![expect(
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::sync::mpsc::RecvTimeoutError;

use slopdesk_muxnet::connection::MuxEvent;
use slopdesk_wire::MuxFrame;
use slopdesk_wire::mux::admission::Role;

mod common;

use common::{GENEROUS, SETTLE, Wired, write_all};

/// A peer-initiated open. Only this file writes one: at a client it is the frame that must be
/// ignored, at a host it is the frame that mints a pane.
fn open_frame(channel_id: u32) -> Vec<u8> {
    MuxFrame::ChannelOpen {
        channel_id,
        session_id: [1; 16],
        last_received_seq: 0,
        channel_class: 0,
        initial_cwd: None,
    }
    .encode()
}

/// `Admission::Drop(Ignored::OpenAtInitiator)`, seen from outside.
///
/// The client is the only side that INITIATES an open, so one arriving at a client is spurious or
/// hostile. It must not mint a channel, because a client that answered it would hand its owner a
/// pane the host has never heard of — and there is nobody legitimate to send a refusal to either,
/// so nothing goes back on the wire.
#[test]
fn an_open_arriving_at_a_client_mints_nothing_and_is_answered_with_nothing() {
    let wired = Wired::up(Role::Client);
    write_all(&wired.peer_data, &open_frame(1));

    match wired.events.recv_timeout(SETTLE) {
        Err(RecvTimeoutError::Timeout) => {},
        Err(RecvTimeoutError::Disconnected) => panic!("the connection tore itself down"),
        Ok(event) => panic!("a client minted a channel for an inbound open: {event:?}"),
    }
    assert_eq!(
        wired.connection.live_channel_count(),
        0,
        "the open registered a channel on the side that never registers one"
    );
    wired.down();
}

/// The same frame at the host, so the test above is proving a ROLE difference rather than a
/// mis-encoded frame or a link that was never read.
#[test]
fn the_same_open_arriving_at_a_host_does_mint_one() {
    let wired = Wired::up(Role::Host);
    write_all(&wired.peer_data, &open_frame(1));

    match wired.events.recv_timeout(GENEROUS) {
        Ok(MuxEvent::Opened(open)) => assert_eq!(open.channel_id, 1),
        other => panic!("the host did not report the open: {other:?}"),
    }
    assert_eq!(wired.connection.live_channel_count(), 1);
    wired.down();
}

/// A link ending is an accident at either role, and both ends must hear about it — the client's
/// session layer reconnects on it exactly as the host's reaps on it.
#[test]
fn a_dead_link_reports_link_down_at_either_role() {
    for role in [Role::Client, Role::Host] {
        let wired = Wired::up(role);
        drop(wired.peer_control);

        match wired.events.recv_timeout(GENEROUS) {
            Ok(MuxEvent::LinkDown { channels, .. }) => {
                assert!(channels.is_empty(), "no channel was ever opened");
            },
            other => panic!("{role:?} did not report the dead link: {other:?}"),
        }
        wired.connection.close();
        drop(wired.peer_data);
        wired.threads.join();
    }
}
