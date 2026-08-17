//! `slopdesk-androidd` — the Android panel's bridge, dialled by the client and not relayed by
//! hostd.
//!
//! The panel's right-hand Android tab needs three things from a host: a list of what is attached or
//! installable, the lifecycle verbs to boot and shut one down, and a live mirror of a screen. All
//! three run through `adb`, and `adb forward` binds `127.0.0.1` with no option not to — so the
//! device's frames land on a loopback socket ON THE HOST while the client is somewhere else on the
//! mesh. This binary is what carries them across.
//!
//! ## What moved, and why
//!
//! The relay itself is not new; where it RUNS is. It used to be a listener inside hostd, which
//! meant an H.264 stream at a few megabits was pumped by the same process that owns every
//! keystroke, on threads competing with the terminal wire — and `make host-restart` took every live
//! mirror down with it. The client already dialled the bridge port directly (it learns it from
//! metadata verb 22), so nothing about the WIRE had to change: only the process behind the port
//! did. hostd now spawns it under superd as `service:androidd` and re-learns the port from the
//! child's own announce line.
//!
//! Per the tree's standing rule this is a separate binary — never FFI — so `swift build` stays
//! headless and cargo-free.
//!
//! ## The shape
//!
//! | module | what it owns |
//! | --- | --- |
//! | [`catalog`] | parsing what `adb`, the console and `config.ini` say into device rows |
//! | [`toolchain`] | finding `adb`, `emulator` and the scrcpy jar, and running them with a deadline |
//! | [`console`] | the emulator's own telnet control channel |
//! | [`scrcpy`] | launching the device-side server and completing its handshake |
//! | [`stream`] | the scrcpy stream's CLIENT end — framing in, access units out |
//! | [`net`] | the blocking socket primitives, and why they are blocking |
//! | [`protocol`] | the one-line request protocol and the pure per-op decisions |
//! | [`error`] | the sentences the panel renders |
//! | [`server`] | the accept loop and the seven operations |
//!
//! ## What it refuses
//!
//! Validate-then-drop throughout, because every one of these strings reaches an argument vector: a
//! request line that does not decode is answered and closed, an empty string field reads as absent,
//! a logcat level outside logcat's own six letters falls back to `I`, a codec outside the server's
//! three is ignored, and a mirror size outside the range the server accepts falls back to the
//! default rather than refusing the session.
//!
//! **No credential.** Same invariant as every other port this project opens: security is the
//! `WireGuard` mesh (`docs/DECISIONS.md`).

pub mod catalog;
pub mod console;
pub mod error;
pub mod net;
pub mod protocol;
pub mod scrcpy;
pub mod server;
pub mod stream;
pub mod toolchain;

pub use catalog::{Device, Listing};
pub use error::BridgeError;
pub use protocol::Request;
pub use scrcpy::{Codec, Options, Session};
pub use server::{ANNOUNCE_PREFIX, Bridge, announce, bind, locate_toolchain, serve};
pub use stream::{Message, StreamParser, decodable_codec};
pub use toolchain::Toolchain;
