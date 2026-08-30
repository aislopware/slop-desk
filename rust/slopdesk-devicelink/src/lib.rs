//! The two sockets the device panels hold open.
//!
//! Everything the panels DECIDE is `slopdesk-devicepanel`'s and stays there. What is here is the
//! part that could not be pure: a TCP connection, a reader thread, and the rules that keep a
//! callback from outliving the handle that owns it.
//!
//! ## The layers, and the line between them
//!
//! [`ws::handshake`] and [`ws::frame`] are PURE — bytes in, bytes out, no socket — and that is
//! where the protocol tests live, because a websocket bug is a framing bug about nine times in ten
//! and none of those nine need a server to reproduce. [`session`] is the thread and the teardown.
//! [`ws::lane`] and [`bridge`] are each one protocol wired onto that session, and neither is more
//! than a read loop.
//!
//! ## Blocking, on threads, by the same argument the rest of the tree makes
//!
//! There is no async runtime here and there is none anywhere in this tree. A device panel holds at
//! most three sockets — a frame stream, a console and a bridge call — and each wants exactly one
//! thread parked in `read`. An executor would buy multiplexing that nothing needs and cost the
//! whole tokio tree in a library that Swift links into the app.
//!
//! ## Plain `ws://`, never `wss://`
//!
//! The project's security invariant: there is no app-layer auth and the boundary is the `WireGuard`
//! mesh. TLS on this link would add a certificate-trust problem to a hop that is already private,
//! which is the same ruling `slopdesk_devicepanel::sim_routes` records for the URLs themselves. A
//! `wss://` URL is refused rather than silently downgraded.

pub mod bridge;
pub mod session;
pub mod ws;
