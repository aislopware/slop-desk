//! hostd's composition, in Rust: which pane a channel names, which parked pane a returning client
//! may take, and what happens to both when the daemon stops.
//!
//! This is stage D of `docs/60-hostd-in-rust.md`, and the shape of it is the finding that scoped
//! the stage: **stage D has no engine left to write.** Every decision the three thousand lines of
//! `HostServer` and its neighbours reach for is already Rust somewhere else — the session table is
//! [`slopdesk_muxsession::registry`], the retention rules are
//! [`slopdesk_muxsession::detach_retention`], the service lifecycles and the log splitter are
//! `slopdesk-sidecars`', the metadata bodies are `slopdesk-probe`'s and `slopdesk-git`'s, and one
//! pane is `slopdesk-hostsession`'s. What is left is COMPOSITION, and composition is the one thing
//! that cannot live inside any of the crates it composes.
//!
//! ## What D.1 landed
//!
//! [`sessions`] — the table, [`slopdesk_muxsession::registry::Registry`] plus the objects it names,
//! with no lock of its own because the server's ladders need the two mutated together.
//! [`detached`] — the parked-pane store, with a lock of its own because its exclusive hand-off is a
//! removal and a timer cancellation in ONE critical section. [`deadline`] — the timer wheel that
//! hand-off cancels against. [`pane`] and [`live`] — the six-method surface those two need of a
//! pane, and the real one behind it.
//!
//! ## What D.2 landed
//!
//! [`service`] — the two lifecycles every lazily-spawned panel backend runs on, the
//! OS-picks-the-port one and the hostd-picks-the-port one. [`serviceproc`] — the backend itself,
//! forked and held by superd so a hostd rebuild costs no Node boot. [`code`] — the workbench, and
//! the four one-shot gates in front of its spawn.
//!
//! ## What D.3 landed
//!
//! [`bridge`] — the socket the workbench's extension dials back on, which is the only half of that
//! channel that was not already Rust. Every decision on it is
//! [`slopdesk_muxsession::bridge_router`]'s and always was.
//!
//! ## What D.4 landed
//!
//! [`metadata`] — the pane's metadata reducer, as a COMPOSITE.
//! [`slopdesk_muxsession::metadata_admission::performer`] already routes every verb off the wire's
//! own enum, so the split was read off the routing table rather than argued: the TEN verbs that
//! land on `Performer::Builder` are answered here, and the other twelve cross to an injected
//! delegate untouched. There was no engine here either — the confinement is
//! [`slopdesk_probe::path_confine`], the encoders are `slopdesk-wire`'s, the queries are
//! `slopdesk-panecensus`', `slopdesk-git`'s and `slopdesk-probe`'s. What moved is the ORDER around
//! them, behind a [`metadata::HostQuerying`] door so the suite can assert the thing that matters:
//! that a REFUSED request never reached the query at all.
//!
//! ## What it does not DELETE, and why
//!
//! Nothing. `docs/60` §5's carve-out is the reason and it has not changed: stages A–E cannot obey
//! "one implementation, never two languages" literally, because hostd is a Swift process until the
//! cutover at stage F. `HostSessionRegistry` and `DetachedSessionStore` stand until then, and F is
//! what takes them.

//! ## What D.6 landed
//!
//! [`host`] — the eleven agent-control verbs answered out of the LIVE tables, and the cross-pane
//! status fan-out that had no Rust at all before it. [`channel`] — the four ladders a `channelOpen`
//! resolves to, the close that ends one, and the ONE critical section that makes the first four
//! indivisible. Neither had an engine either: the precedence between the outcomes is
//! [`slopdesk_muxsession::open_route`]'s and always was. [`adopt`] — the surviving-pane ladder a
//! restarted daemon runs against superd, over one new verdict table in the same crate.
//! [`workspace`], [`subscriber`] and [`wsserve`] — the document every client mirrors, one
//! subscriber's send path over `slopdesk_workspace::sync_ladder`, and the channel that carries it.
//! The engine was already Rust there too; what moved is the version rule, the coalescing, and the
//! retention that makes a leaked document impossible rather than unlikely. [`lifecycle`] — the four
//! ways a pane, a link and the daemon end, and the ORDER the last of them runs in.

//! ## What stage E landed here
//!
//! Three FOLDS, each with a door it does not itself implement. Two are of the six named metadata
//! performers `docs/60` §4 left as Swift: [`pathaction`] — the tilde expansion, the absolute-path
//! refusal and the existence check in front of ⌘click's open and reveal — and [`clipsync`] — the
//! image-before-text preference, the codec's cap, the file-copy refusal and the echo guard in front
//! of the two clipboard verbs. The Apple halves are `slopdesk-apple-app`'s two new `NSWorkspace`
//! verbs and the new `slopdesk-apple-pasteboard`; both doors here are three lines over them. The
//! third is [`repowatch`], `RepoStatusWatcher`'s machinery: the live-watch table, the debounce and
//! the thread a reading runs on, over `slopdesk-apple-fsevents`.
//!
//! NONE of the three is reached by anything shipping, and that is §5's carve-out rather than an
//! omission. `HostMetadata`'s own module doc argues it for the three verbs it could already serve:
//! the pasteboard and the Finder are host-GLOBAL, so a second performer over them would be two
//! implementations of one machine's clipboard for as long as the Swift hostd runs. [`repowatch`] is
//! a lifecycle rather than a route, so it has nothing to be wired into at all — hostd starts one,
//! or it does not. Stage F retires that hostd and starts all three; until then they are linked by
//! nothing shipping, exactly as §5 says.

pub mod adopt;
pub mod bridge;
pub mod channel;
pub mod clipsync;
pub mod code;
pub mod control;
pub mod ctlserve;
mod deadline;
mod detached;
pub mod host;
pub mod lifecycle;
mod live;
pub mod metadata;
mod pane;
pub mod pathaction;
pub mod repowatch;
pub mod service;
mod serviceproc;
mod sessions;
pub mod subscriber;
pub mod workspace;
pub mod wsserve;

pub use adopt::{Adopted, LetGo, NoSurvivors, Survivors, owner_identity};
pub use channel::{
    Fresh, HookRoutes, HostObserver, NoHooks, NoWorkspace, Offload, Peer, Restored, Silent, Threads,
    WorkspaceChannels,
};
pub use deadline::Deadlines;
pub use detached::{
    Claim, DetachedStore, DetachedTeardown, EvictionObserver, IgnoreEvictions, InlineTeardown, Relinquished,
    TeardownExecutor,
};
pub use host::{
    Host, HostEnv, HostParts, NoTranscripts, SessionIds, Spawner, Standalone, SystemIds, Transcripts,
};
pub use live::LivePane;
pub use pane::{Pane, Wires, same_pane};
pub use serviceproc::{ServiceProcess, pane_id_for};
pub use sessions::{Held, Sessions};
pub use subscriber::{EventSink, WorkspaceSubscriber};
pub use workspace::{NoPanes, NoStore, Panes, WorkspaceDocument, WorkspaceStore, topology_pane_ids};
pub use wsserve::WorkspaceService;
