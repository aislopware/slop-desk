//! hostd's PATH-1 transport: a TCP listener, and the map that pairs two sockets into one
//! connection.
//!
//! `docs/60-hostd-in-rust.md` stage A wrote this crate; `docs/63-client-transport-in-rust.md` stage
//! G.1 took most of it away. What left is everything that never said HOST — the preamble, the
//! socket options, the byte link, the sub-channel and the connection — and it lives in
//! [`slopdesk_muxnet`], which the client links too. What is left here is the two files that DID:
//! accepting sockets, and holding a half-pair until its partner arrives. Neither has a client
//! counterpart, because a client dials rather than accepts and its two halves are made together.
//!
//! The Swift this replaces was built on `NWListener`/`NWConnection`, which `docs/59` §6 recorded as
//! the floor "for as long as hostd is a Swift process". Read for what they ASK FOR rather than what
//! they were written in, they are plain TCP — `noDelay`, keepalive 10/5/3, `tls: nil` — so the
//! floor was a framework nobody needed rather than a framework nobody can replace. There is no
//! `objc2` here, no Apple binding, and `forbid(unsafe_code)` on the crate.
//!
//! ## The shape
//!
//! ```text
//!   client dials twice ──▶ [0x03│id] CONTROL ─┐
//!                          [0x04│id] DATA ────┴─▶ PendingLinks ──▶ PairedConnection ──▶ MuxConnection
//! ```
//!
//! - [`pending`] — the half-pair map: the only thing here that owns a file descriptor.
//! - [`listener`] — three threads: accept, one handshake per arrival, one reaper.
//!
//! Everything to the right of the arrow is [`slopdesk_muxnet`]'s, starting at
//! [`PairedConnection`](slopdesk_muxnet::connection::PairedConnection) — which is why this crate
//! can be the host's alone without either end owning a copy of the mux.
//!
//! ## What this crate does not decide
//!
//! Whether an arriving half completes a pair, and whether a parked one has waited too long, are
//! `slopdesk_muxsession::pairing`'s — already Rust, with its whole state space pinned by a test
//! table. Everything about a FRAME is `slopdesk_wire::mux`'s and reaches this crate not at all: no
//! module here decodes one. This crate owns the fds and the threads up to the moment a pair is
//! complete, and obeys.
//!
//! ## And it decides nothing about panes
//!
//! There is no PTY here, no session, no detach policy. A completed pair is published and this crate
//! is done with it; what a channel on it MEANS for a shell is stage C's and stage D's.
//!
//! ## No app-layer crypto, restated where it would be added
//!
//! `NWParameters(tls: nil, tcp:)` is the Swift spelling of a decision `CLAUDE.md` states as an
//! invariant: security is the `WireGuard` mesh, and there is no pairing, no token and no handshake
//! secret. The Rust spelling is that no TLS crate is in the dependency list. If one ever appears
//! here, that is the thing to question, not the code using it.

pub mod listener;
pub mod pending;
