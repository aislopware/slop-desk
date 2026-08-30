//! The client's shared UDP flow: one media socket and one cursor socket per host, N lanes.
//!
//! ## What is here and what is not
//!
//! Every RULE this flow obeys is `slopdesk-video`'s already and is called, never restated: the
//! datagram framing is [`slopdesk_video::mux_header`], the re-arm and its backoff ladder are
//! [`slopdesk_video::mux_flow`], and which panes share a flow is
//! [`slopdesk_video::mux_client_pool`]. What is here is the part that could not be: two sockets,
//! two reader threads, and the lane table a datagram is admitted against.
//!
//! ## Plain UDP, not `NWConnection` — the same three simplifications the host recorded
//!
//! `rust/slopdesk-videohostd`'s `mux_transport` wrote this list for the listener; the client half
//! inherits it, plus one of its own:
//!
//! * **A bind failure is synchronous.** [`Flow::open`] answers `io::Error`. The Swift flow's
//!   `start(queue:)` returned nothing and surfaced a real failure only through a state handler.
//! * **A flow never fails on its own.** UDP gives a shared socket no per-peer signal, so liveness
//!   is the caller's teardown flag and nothing else — which is what [`mux_flow::should_rearm`] has
//!   always been asked.
//! * **There is no send-path state, so there is no send-path POLICY.** `UDPSendPathPolicy` existed
//!   because `Network.framework` parks a `.waiting` connection's datagrams in-process with the
//!   completion deferred indefinitely, so a client that kept firing its 20 Hz stats reports into a
//!   dead wifi path accumulated them. A `sendto` on a raw socket has no such queue: it fails, now,
//!   with `ENETDOWN`/`EHOSTUNREACH`/`ENETUNREACH`. [`Flow::is_send_path_viable`] is therefore the
//!   LAST SEND's answer rather than a state machine's, and it is a strictly better signal — it
//!   reports the path the datagrams actually took.
//! * **A teardown is bounded, not instant.** `UdpSocket` has no `shutdown`, so a reader parked in
//!   `recv` is woken by its own read timeout rather than by the close. Dropping a [`Flow`] can
//!   therefore take up to [`flow::TEARDOWN_LATENCY`] to join, and no callback runs after it.
//!
//! ## Threads, not an async runtime
//!
//! Two sockets, each with one reader parked in `recv`, is two threads. This library is linked into
//! the app (`docs/55`), and a runtime would be a scheduler for a multiplexing problem that does not
//! exist here — the same ruling `slopdesk-devicelink` records.

pub mod flow;
