//! The decision half of one pane's CLIENT session.
//!
//! `SlopDeskClient` owns a transport, four background tasks, an output inbox and a multicast event
//! hub. None of that is here. What is here is what it DECIDES — which output seq is new, what may
//! be acked, whether a connection may be opened or adopted, whether a stream end is a real drop,
//! how long the next retry waits and when the retries stop — expressed over small integers so each
//! can be exercised without a socket, a task or a runloop.
//!
//! The split is the one the rest of the tree makes. `rust/slopdesk-muxsession` is this crate's
//! opposite number: the policy half of one HOSTD pane session, where the PTY and the relay tasks
//! stay behind and the fold that chose their arguments comes out. This is the same carve from the
//! other end of the wire.
//!
//! ## Why the decisions and not the driver
//! Everything here is about a number the near side already holds, and every failure it prevents is
//! silent rather than visible: a duplicate seq accepted prints the last screen twice, a mark reset
//! at the wrong moment eats the first one, an adopted-anyway transport leaks two sockets and their
//! pumps for the life of the process, and an announced self-inflicted teardown queues a retry
//! campaign nobody asked for. None of those are caught by looking at the pane. All of them are one
//! table of cases.
//!
//! ## What crosses
//! [`seq::Session`] is four numbers and a flag, and it crosses WHOLE, by value, in and out of every
//! call (`docs/55` §4b): the near side reads all of it, and there is nothing to own. Every verdict
//! comes back as a code. No `Data`, no session id and no host name crosses — the bytes stay in the
//! inbox they were appended to, and the identity stays where the handshake put it.

#![forbid(unsafe_code)]

pub mod backoff;
pub mod gates;
pub mod rtt;
pub mod seq;
