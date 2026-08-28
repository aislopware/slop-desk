//! The GUI video path (PATH 2) host daemon: capture, encode, packetize, serve, inject.
//!
//! One UDP flow per host, N panes. The daemon binds ONE shared media + cursor pair of sockets and
//! mints a per-channel session from each client `hello`'s own `windowID` — the `docs/01` §2
//! asymmetry, where two panes watch different windows over one flow. Each session captures that
//! window through `ScreenCaptureKit`, encodes HEVC through `VideoToolbox`, packetizes with FEC,
//! serves the result, and injects what comes back.
//!
//! ⚠️ GUI + TCC ONLY. The capture needs a real window-server session and a Screen-Recording grant;
//! the injection needs Accessibility and Post-Event. Both HANG or fail headlessly, so nothing in
//! this crate that touches a framework can be reached by a test — which is exactly why every
//! DECISION it takes lives in [`slopdesk_video`] and is tested there instead.
//!
//! ## What this crate is allowed to be
//! Effects and ordering. It opens sockets, starts streams, owns threads and queues, and holds the
//! lifetimes. Every verdict it needs it ASKS for: the packetizer, the FEC ladder, the mux header
//! and routing, the congestion controller, the QP ladder, the LTR machine, the FPS governor, the
//! capture gates and the geometry are all [`slopdesk_video`]'s, already written and already pinned
//! by `golden/golden_vectors.json`. If something here starts to look like a rule, it belongs there.
//!
//! ## The port it replaces
//! `Sources/SlopDeskVideoHost` and `Sources/slopdesk-videohostd`. Those were already faces — 33 of
//! the 47 files reached their decisions through `CSlopDeskFFI` — and what was genuinely Swift was
//! the threading: the actor, the dispatch queues, the `NWConnection`. A Rust daemon calls
//! `slopdesk-apple-sck` and `slopdesk-apple-vt` NATIVELY, so this port removes FFI doors rather
//! than adding them. `docs/60` is the ledger for the host half of the same campaign.
//!
//! ## The module map
//! Each entry lands with the piece it names; the map is here from the start so the pieces do not
//! have to invent a shape one at a time.
//!
//! | Module | What it owns |
//! | --- | --- |
//! | [`args`] | the argv grammar and the one environment knob that overrides it |
//! | [`diag`] | the one line on stderr, and the name every one of them is prefixed with |
//! | [`env`] | `video-prefs.json` → the launch-time overlay every gate resolves through |
//! | [`list`] | `--list`: what this host will share, in an order a person can read |
//! | [`mux_transport`] | the two UDP sockets, the three threads, and the one mux lock |
//! | [`mux_peers`] | which peer a flow id names — all `NWListener` ever contributed |
//! | [`mux_sink`] | the lane → session sink table a mint registers into, synchronously |
//! | [`mux_lane`] | one lane of the shared flow, seen as a whole transport by its session |
//! | [`mux_registry`] | one shared flow into N sessions: mint on the first hello, per lane |
//! | [`discovery`] | the answers that mint nothing: window and display lists, and the feed's |
//! | [`capture`] | the `SCStream` and its backlog: what reaches the encoder, and what is dropped |
//! | [`encode`] | the HEVC session's lifetime, and the four ways a frame reaches it |
//! | [`audio`] | the second stream `ScreenCaptureKit` already delivers, on its own channel |
//! | [`windowsource`] | the desktop census → one streamable-window row per window, in z-order |
//! | [`windowprobe`] | the budgeted accessibility sweep that tells a minimized window from a ghost |
//! | [`feed`] | the window feed: the TTL cache, the subscriber roster, and the differ's tick |
//! | [`windowplace`] | park, restore, un-minimize, resize — four orders that are load-bearing |
//! | [`windowgeometry`] | the 30 Hz drag poll, and the every-fifth DIALOG-EXPAND region sample |
//! | [`session_wiring`] | the session's own STATE: the controller set, the live set, the counters |
//! | [`sendlane`] | the paced drain, the retransmit ring, and the one send the wire ever sees |
//! | [`packetize`] | one encoded frame into datagrams, FEC and all, on the lane's own budget |
//! | [`cursor`] | the cursor's own channel: sampled, deduplicated, and never on the video clock |
//! | [`privacy`] | the host-side blank, which is a CAPTURE decision and not a client one |
//! | [`wake`] | the assertion a full-desktop session holds so the host does not sleep under it |
//! | [`vdisplay`] | the virtual display a parked window lives on, and its teardown order |
//! | [`session`] | one client's session: the composition, the lifetime, and the order it comes up in |
//! | [`session_actuate`] | a folded report into framework writes, planned under the lock, applied after |
//! | [`session_capture`] | the session's bring-up and teardown: 12 steps up, 6 down, each one ordered |
//! | [`session_inbound`] | what the client sends back: feedback, control, input — and the one fold |
//! | [`session_pump`] | a captured frame to the encoder, and an encoded frame to the wire — no queue |
//! | [`session_resize`] | one client resize: the window, the rebuild under it, and what survives both |
//! | [`minter`] | one hello into one running session: what is resolved before a session exists |
//! | [`parking`] | windows moved onto the virtual display, and the journal that survives a crash |
//! | [`rescue`] | the off-screen mint rescue: a window nobody can see is still a window to serve |
//! | [`injector`] | remote input's last stop: the raise chain, the resampler's pump, the chord |
//! | [`navhistory`] | can the frontmost app go back and forward — one accessibility read, cached |
//! | [`navstatus`] | one 4 Hz beat for the whole daemon, fanned out to every live session |

pub mod args;
pub mod audio;
pub mod capture;
pub mod cursor;
pub mod diag;
pub mod discovery;
pub mod encode;
pub mod env;
pub mod feed;
pub mod injector;
pub mod list;
pub mod minter;
pub mod mux_lane;
pub mod mux_peers;
pub mod mux_registry;
pub mod mux_sink;
pub mod mux_transport;
pub mod navhistory;
pub mod navstatus;
pub mod packetize;
pub mod parking;
pub mod privacy;
pub mod rescue;
pub mod sendlane;
pub mod session;
pub mod session_actuate;
pub mod session_capture;
pub mod session_inbound;
pub mod session_pump;
pub mod session_resize;
pub mod session_wiring;
pub mod shareable;
pub mod vdisplay;
pub mod wake;
pub mod windowgeometry;
pub mod windowplace;
pub mod windowprobe;
pub mod windowsource;
