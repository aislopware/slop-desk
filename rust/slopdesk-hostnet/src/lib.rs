//! hostd's PATH-1 transport: a TCP listener, the association preamble, the map that pairs two
//! sockets into one connection, and the mux that runs over them.
//!
//! `docs/60-hostd-in-rust.md` stages A and B. The Swift this replaces was built on
//! `NWListener`/`NWConnection`, which `docs/59` §6 recorded as the floor "for as long as hostd is a
//! Swift process". Read for what they ASK FOR rather than what they were written in, they are plain
//! TCP — `noDelay`, keepalive 10/5/3, `tls: nil` — so the floor was a framework nobody needed
//! rather than a framework nobody can replace. There is no `objc2` here, no Apple binding, and
//! `forbid(unsafe_code)` on the crate.
//!
//! ## The shape
//!
//! ```text
//!   client dials twice ──▶ [0x03│id] CONTROL ─┐                      ┌─▶ SubChannel (control)
//!                          [0x04│id] DATA ────┴─▶ PairedConnection ──┤
//!                                                 └─▶ MuxConnection ─┴─▶ SubChannel (data)
//!                                                        │
//!                                                        └─▶ MuxEvent: opened · closed · link down
//! ```
//!
//! - [`preamble`] — the 17 bytes each socket opens with, and nothing else about the wire.
//! - [`params`] — the four sockopts, and why `tls: nil` ports to no call at all. The keepalive
//!   ladder itself is `slopdesk_wire::transport`'s, because the dialler must agree with it.
//! - [`link`] — write bytes, read bytes, hang up. One `send`, because a blocking write is already
//!   both of Swift's two.
//! - [`pending`] — the half-pair map: the only thing here that owns a file descriptor.
//! - [`listener`] — three threads: accept, one handshake per arrival, one reaper.
//! - [`subchannel`] — one logical channel: its framing, its two credit windows, and the park that
//!   waits on the send one.
//! - [`connection`] — two link threads, the tables they share, and the events they report.
//!
//! ## What this crate does not decide
//!
//! Whether an arriving half completes a pair, and whether a parked one has waited too long, are
//! `slopdesk_muxsession::pairing`'s — already Rust, with its whole state space pinned by a test
//! table. Whether a frame is admitted, where it routes, what a channel's ending reaches, and every
//! flow-control number are `slopdesk_wire::mux`'s. This crate owns the fds and the threads, and
//! obeys.
//!
//! ## And it decides nothing about panes
//!
//! There is no PTY here, no session, no detach policy. [`connection::MuxConnection`] reports that a
//! channel opened, that the peer closed one, or that a link died and which channels were on it;
//! what any of that MEANS for a shell is stage C's and stage D's. That is why
//! `detachShellsOnLinkDrop` — a field on the Swift connection, with a branch in its teardown that
//! must remember not to run the kill loop — has no equivalent here.
//!
//! ## No app-layer crypto, restated where it would be added
//!
//! `NWParameters(tls: nil, tcp:)` is the Swift spelling of a decision `CLAUDE.md` states as an
//! invariant: security is the `WireGuard` mesh, and there is no pairing, no token and no handshake
//! secret. The Rust spelling is that no TLS crate is in the dependency list. If one ever appears
//! here, that is the thing to question, not the code using it.

pub mod connection;
pub mod link;
pub mod listener;
pub mod params;
pub mod pending;
pub mod preamble;
pub mod subchannel;
