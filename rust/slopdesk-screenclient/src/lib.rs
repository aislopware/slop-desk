//! hostd's end of the `slopdesk-screend` socket: connect, pool, autostart, ten verbs.
//!
//! `docs/60-hostd-in-rust.md` stage C.2 calls this C.0's shape a second time, and it is: the
//! MESSAGE set is [`slopdesk_screenwire`]'s already and shared with screend by construction, so
//! what was left in `Sources/SlopDeskScreen/ScreenClient.swift` was the CONNECTION. That is this
//! crate.
//!
//! Three modules, and the split is what each one is allowed to know:
//!
//! * [`client`] — the client, its pool and its autostart. Knows about sockets and about verbs.
//! * [`transport`] — one request out, one reply in, and [`ClientError`]. Knows about bytes.
//! * [`paths`] — where screend listens, where its binary is, where its log goes. Knows about the
//!   filesystem and the environment, and about the address rule only enough to ASK the wire crate.
//!
//! What none of them knows is the screen ENGINE. Linking `slopdesk-screend` to reach a struct
//! definition would pull `regex`, `toml` and a per-byte grid into hostd — the exact inversion the
//! socket was drawn to prevent — which is why [`slopdesk_screenwire::Snapshot`] and
//! [`slopdesk_screenwire::Verdict`] live with the framing instead.

pub mod client;
pub mod paths;
pub mod transport;

pub use client::{DetectFlags, ScreenClient, shared};
pub use slopdesk_screenwire::{Snapshot, State, Status, Verdict};
pub use transport::ClientError;
