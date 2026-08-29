//! The driver half of one pane's client session: the threads, the inbox and the campaign.
//!
//! `docs/63-client-transport-in-rust.md` stage G.5. What was `Sources/SlopDeskClient` — an actor,
//! four background tasks, a multicast event hub, a retry supervisor and a bounded input pipe —
//! becomes one supervisor thread, one lock and one observer.
//!
//! ## One thread is the design, not an implementation detail
//!
//! The Swift this replaces spent roughly a third of its lines defending against its own actor's
//! reentrancy. A `connectGeneration` counter existed because two overlapping `connect`s could both
//! reach `self.transport = transport` across an `await`; a `tearingDownDepth` counter existed
//! because two overlapping teardowns could clobber each other's suppression window; a
//! post-handshake re-check and a post-adoption re-check existed because the actor yielded at four
//! more awaits before the pumps started.
//!
//! None of those situations can arise here. [`PaneDriver::connect`], [`PaneDriver::pause`],
//! [`PaneDriver::resume`], [`PaneDriver::close`] and every retry are COMMANDS on one channel, run
//! to completion by one thread in the order they were posted. The near side still blocks on each
//! one, so the calling convention is unchanged; what is gone is the possibility of two of them
//! being half-done at once.
//!
//! Two of the four adoption conditions survive that, and only two, because they are not about
//! reentrancy: a `close` or a `pause` posted while a dial is in flight is a real event that a
//! ten-second `connect_timeout` is long enough to contain. They are read as atomics at the moment
//! of adoption, through [`slopdesk_clientsession::gates::adopts`], so the rule stays where the rule
//! lives. The other two — a newer connect, and a cancelled task — cannot happen and are passed as
//! `false` with that stated at the call.
//!
//! ## What does NOT go through the supervisor
//!
//! Inbound. A decoded message arrives on one of the two forwarder threads
//! [`slopdesk_clientnet::transport::ChannelTransport`] spawned, and it is folded THERE: the dedup
//! and the inbox append happen under the state lock on the thread that decoded it. Routing a PTY
//! payload through the command channel would buy a thread hop and a second copy of every byte the
//! session exists to carry, in exchange for a serialisation the state lock already provides.
//!
//! The one thing a forwarder may not do is END the channel, because closing a
//! [`ChannelTransport`](slopdesk_clientnet::transport::ChannelTransport) joins the forwarder
//! threads and one of them is the caller. So [`event::Observer`]-visible ends are posted as
//! commands, and the supervisor does the closing.
//!
//! ## What the near side is left holding
//!
//! An opaque pointer and two callbacks. Every decision is
//! [`slopdesk_clientsession`]'s, every frame is [`slopdesk_wire`]'s, every socket is
//! [`slopdesk_clientnet`]'s, and what is here is the ladder that puts them in an order.

#![forbid(unsafe_code)]

pub mod driver;
pub mod event;
pub mod reply;
mod state;

pub use driver::{ConnectError, DriverConfig, PaneDriver, ResumeSeed};
pub use event::{Event, Observer};
