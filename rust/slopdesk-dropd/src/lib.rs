//! `slopdesk-dropd` — the file-DROP service, PATH 4 of the four paths.
//!
//! A client that drags a file onto the desktop window dials THIS process directly, on
//! `terminalPort + 2`. hostd is not in the byte path and never was on the wire — but it used to be
//! the process doing the receiving, which meant a multi-GiB upload streamed through the daemon that
//! also owns every keystroke, and a host restart took the upload with it.
//!
//! BOTH ends are here. [`protocol`] decodes what [`client`] encodes and encodes what it decodes —
//! a protocol's two ends, which is the only duplication the one-implementation rule allows — and
//! [`upload`] is the initiating end's SEQUENCE, the law that says which frame follows which. What
//! is left in Swift is a face over one door: the drop handler hands `AppKit`'s URLs over and reads
//! progress back, and decides nothing.
//!
//! The daemon is a separate binary — never FFI — so `swift build` stays headless and cargo-free.
//! The client half is LINKED instead, through `rust/slopdesk-ffi`, for `docs/55` §1's reason: the
//! iOS client cannot host a sidecar, and a drop on the phone must reach the same driver.
//!
//! ## What it refuses
//! Everything a peer on the tunnel could try. Validate-then-drop throughout: a frame longer than
//! the cap is refused before it allocates, a name that is not a plain leaf is rejected rather than
//! sanitised into something surprising, a body that overruns its offer aborts the transfer, and a
//! partially received file never appears under its final name.

pub mod client;
pub mod name;
pub mod protocol;
pub mod receive;
pub mod server;
pub mod sink;
pub mod upload;

pub use client::{
    CHUNK_BYTE_COUNT, FrameError, ReplyFrameDecoder, chunk_frame_len, decode_reply_payload,
    encode_request_frame, write_chunk_frame,
};
pub use name::sanitize;
pub use protocol::{DecodeError, Reply, Request, decode_request, encode_reply_frame};
pub use receive::{Effect, ReceiveLogic};
pub use server::serve;
pub use sink::{DiskSink, SinkError};
pub use upload::Progress;
