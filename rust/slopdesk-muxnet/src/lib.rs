//! PATH-1's mux over two sockets: the association preamble, the socket options, one byte link, one
//! sub-channel, and the connection that demultiplexes frames into channels.
//!
//! `docs/60-hostd-in-rust.md` stages A and B wrote all of this as `slopdesk-hostnet`, and
//! `docs/63-client-transport-in-rust.md` stage G.1 split it here. The split's test was one question
//! asked of each file: does it say HOST anywhere. Two of seven did — the accept loop and the map of
//! half-paired links — and they stayed. The five here did not, and the reason is not tidiness: the
//! iOS client links this crate, and a crate that carried an accept loop would ship the phone a
//! listener it can never call.
//!
//! There is no `objc2` here, no Apple binding, no `Network.framework` and no TLS — plain TCP with
//! `noDelay` and a keepalive ladder, `forbid(unsafe_code)` on the crate.
//!
//! ## The shape
//!
//! ```text
//!   two sockets, same 16-byte id ─▶ PairedConnection ─▶ MuxConnection ─┬─▶ SubChannel (control)
//!                                                             │        └─▶ SubChannel (data)
//!                                                             └─▶ MuxEvent: opened · closed · down
//! ```
//!
//! Where the pair came from is deliberately absent: `slopdesk-hostnet` accepts two sockets into
//! one, `slopdesk-clientnet` dials two into one, and from [`connection::PairedConnection`] onwards
//! the two are the same program.
//!
//! - [`preamble`] — the 17 bytes each socket opens with, and nothing else about the wire. Both
//!   [`encode`](preamble::encode) and [`decode`](preamble::decode) are here: the dialler writes
//!   what the listener reads, and one module owning both is what keeps them the same 17 bytes.
//! - [`params`] — the four sockopts, and why `tls: nil` ports to no call at all. The keepalive
//!   ladder itself is `slopdesk_wire::transport`'s, because the two ends must agree on it.
//! - [`link`] — write bytes, read bytes, hang up. One `send`, because a blocking write is already
//!   both of Swift's two.
//! - [`subchannel`] — one logical channel: its framing, its two credit windows, and the park that
//!   waits on the send one.
//! - [`connection`] — two link threads, the tables they share, and the events they report.
//!
//! ## What this crate does not decide, and the role is the sharpest case
//!
//! Whether a frame is admitted, where it routes, what a channel's ending reaches, and every
//! flow-control number are `slopdesk_wire::mux`'s. So is the whole client/host asymmetry: the mux
//! is asymmetric on purpose — the client allocates ids and initiates every open, the host only
//! responds — and that asymmetry is stated once, in
//! [`admission`](slopdesk_wire::mux::admission), as a function of
//! [`Role`](slopdesk_wire::mux::admission::Role). [`connection::MuxConnection`] carries its role as
//! a field and passes it to that ladder; it does not branch on it. A connection at
//! [`Role::Client`](slopdesk_wire::mux::admission::Role::Client) never emits
//! [`MuxEvent::Opened`](connection::MuxEvent::Opened) because `admit` drops an open arriving at the
//! initiator, not because there is a second `if` here saying so.
//!
//! ## And it decides nothing about panes
//!
//! There is no PTY here, no session, no detach policy. [`connection::MuxConnection`] reports that a
//! channel opened, that the peer closed one, or that a link died and which channels were on it;
//! what any of that MEANS is its owner's — `slopdesk-hostserver`'s on one end, the client's session
//! layer on the other. That is why `detachShellsOnLinkDrop` — a field on the Swift connection, with
//! a branch in its teardown that must remember not to run the kill loop — has no equivalent here.
//!
//! ## No app-layer crypto, restated where it would be added
//!
//! `NWParameters(tls: nil, tcp:)` is the Swift spelling of a decision `CLAUDE.md` states as an
//! invariant: security is the `WireGuard` mesh, and there is no pairing, no token and no handshake
//! secret. The Rust spelling is that no TLS crate is in the dependency list. If one ever appears
//! here, that is the thing to question, not the code using it.

pub mod connection;
pub mod link;
pub mod params;
pub mod preamble;
pub mod subchannel;
