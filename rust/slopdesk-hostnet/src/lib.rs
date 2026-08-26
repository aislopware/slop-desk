//! hostd's PATH-1 socket: a TCP listener, the association preamble, and the map that pairs two
//! sockets into one shared mux connection.
//!
//! `docs/60-hostd-in-rust.md` stage A. The Swift this replaces was four files built on
//! `NWListener`/`NWConnection`, which `docs/59` §6 recorded as the floor "for as long as hostd is a
//! Swift process". Read for what they ASK FOR rather than what they were written in, they are plain
//! TCP — `noDelay`, keepalive 10/5/3, `tls: nil` — so the floor was a framework nobody needed
//! rather than a framework nobody can replace. There is no `objc2` here, no Apple binding, and
//! `forbid(unsafe_code)` on the crate.
//!
//! ## The shape
//!
//! ```text
//!   client dials twice ──▶ [0x03│id] CONTROL ─┐
//!                          [0x04│id] DATA ────┴─▶ PendingLinks ─▶ PairedConnection
//! ```
//!
//! - [`preamble`] — the 17 bytes each socket opens with, and nothing else about the wire.
//! - [`params`] — the four sockopts, and why `tls: nil` ports to no call at all. The keepalive
//!   ladder itself is `slopdesk_wire::transport`'s, because the dialler must agree with it.
//! - [`link`] — write bytes, read bytes, hang up. One `send`, because a blocking write is already
//!   both of Swift's two.
//! - [`pending`] — the half-pair map: the only thing here that owns a file descriptor.
//! - [`listener`] — three threads: accept, one handshake per arrival, one reaper.
//!
//! ## What this crate does not decide
//!
//! Whether an arriving half completes a pair, and whether a parked one has waited too long, are
//! `slopdesk_muxsession::pairing`'s — already Rust, with its whole state space pinned by a test
//! table. What rides the links afterwards is `slopdesk_wire::mux`'s. This crate owns the fds and
//! obeys.
//!
//! ## No app-layer crypto, restated where it would be added
//!
//! `NWParameters(tls: nil, tcp:)` is the Swift spelling of a decision `CLAUDE.md` states as an
//! invariant: security is the `WireGuard` mesh, and there is no pairing, no token and no handshake
//! secret. The Rust spelling is that no TLS crate is in the dependency list. If one ever appears
//! here, that is the thing to question, not the code using it.

pub mod link;
pub mod listener;
pub mod params;
pub mod pending;
pub mod preamble;
