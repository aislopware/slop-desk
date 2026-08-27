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
//! | [`env`] | `video-prefs.json` → the launch-time overlay every gate resolves through |

pub mod args;
pub mod env;
