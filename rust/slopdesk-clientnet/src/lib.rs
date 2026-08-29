//! PATH-1 from the initiator's end: dial two sockets into one mux connection, and pool it.
//!
//! `docs/63-client-transport-in-rust.md` stage G.2. The mirror of `slopdesk-hostnet`, and the two
//! are small for the same reason: everything a mux does once the two sockets exist is
//! [`slopdesk_muxnet`]'s, shared by both ends.
//!
//! ## The shape
//!
//! ```text
//!   Endpoint ─▶ dial ─┬─▶ [0x03│id] CONTROL ─┐
//!                     └─▶ [0x04│id] DATA ────┴─▶ PairedConnection ─▶ MuxConnection (Role::Client)
//!                                                                          ▲
//!                                          ConnectionRegistry ─────────────┘  one per endpoint
//! ```
//!
//! - [`dial`] — the two sockets, the parameters and the preambles. No pairing map: the dialler
//!   CHOSE the connection id, so there is no half-pair to park and nothing to expire.
//! - [`registry`] — the refcounted pool. Every pane to one host rides one mux; the connection
//!   outlives each of them and is torn down when the last releases.
//!
//! ## What is not here
//!
//! Opening a CHANNEL. It mutates the connection's own tables, dispatch maps and allocator, so it is
//! [`MuxConnection::open_channel`](slopdesk_muxnet::connection::MuxConnection::open_channel) — the
//! mirror of the `send_open_ack` already there. This crate calls it and refcounts the result.
//!
//! And every rule: admission, routing, flow control and the client/host asymmetry are
//! `slopdesk_wire::mux`'s. [`Role::Client`](slopdesk_wire::mux::admission::Role::Client) is spelled
//! at exactly one call in this crate, where a dialled pair becomes a served connection.
//!
//! ## No app-layer crypto, restated where it would be added
//!
//! `NWParameters(tls: nil, tcp:)` is the Swift spelling of a decision `CLAUDE.md` states as an
//! invariant: security is the `WireGuard` mesh, and there is no pairing, no token and no handshake
//! secret. A dialler is where one would be added, so it is worth saying here twice: the 17 bytes
//! this crate writes before any frame are a tag and an id, and nothing else is exchanged before the
//! mux begins. The Rust spelling of the rest is that no TLS crate is in the dependency list.

pub mod dial;
pub mod registry;
pub mod transport;
