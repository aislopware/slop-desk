//! hostd: the process the three host crates are finally joined in.
//!
//! `docs/60` stage F. Everything below stage D was built to be assembled somewhere, and until this
//! crate existed nothing in the tree linked `slopdesk-hostnet`, `slopdesk-hostserver` and
//! `slopdesk-hostpane` together — each had a suite, none had a caller. This is the caller.
//!
//! ## What is here, and why each piece could not be anywhere else
//! Every module implements a door that [`slopdesk_hostserver`] or [`slopdesk_hostsession`]
//! deliberately left as a trait, and each one is here because this is the FIRST place both halves
//! are in scope:
//!
//! | module | the door | the other half |
//! | --- | --- | --- |
//! | [`peer`] | `Peer` | a mux connection |
//! | [`spawn`] | `Spawner` | superd's fork, and the session around its master |
//! | [`transcripts`] | `Transcripts` | superd's journal, and the chain that renders it |
//! | [`screen`] | `SnapshotPolicy`, `ScreenOracle` | screend |
//! | [`resolve`] | `ResolveExecutor` | a thread |
//! | [`keys`] | `KeyObserver` | the repo-watch refcounts |
//! | [`evict`] | `EvictionSeam` | the composition that closes a channel |
//!
//! Plus [`serve`], the accept loop — the one piece of the host that was never its own thing in
//! either language, because it was the body of `HostServer.start()`.
//!
//! ## The rule this crate exists to keep
//! It is the ONLY host crate allowed to read the process: argv, the environment, the rlimit, the
//! signals. Stage D left `slopdesk-hostserver` with no `main` precisely so its composition stayed
//! drivable by a suite with no PTY, no superd and no listener, and the moment a ladder in there
//! reaches for `std::env` that property is gone. Everything environmental is resolved here, once,
//! and handed down as a value — which is why [`spawn::Recipe`] is a struct of facts rather than a
//! set of lookups.

pub mod evict;
pub mod keys;
pub mod peer;
pub mod resolve;
pub mod screen;
pub mod serve;
pub mod spawn;
pub mod transcripts;

pub use evict::{HostEviction, LateHost};
pub use keys::{ProjectKeySink, WatchKeys};
pub use peer::ConnectionPeer;
pub use resolve::SerialResolve;
pub use screen::{ScreendOracle, ScreendSnapshot};
pub use serve::Listening;
pub use spawn::{PaneSpawner, Recipe};
pub use transcripts::DiskTranscripts;
