//! `slopdesk-dropd` — the file-DROP service, PATH 4 of the four paths.
//!
//! A client that drags a file onto the desktop window dials THIS process directly, on
//! `terminalPort + 2`. hostd is not in the byte path and never was on the wire — but it used to be
//! the process doing the receiving, which meant a multi-GiB upload streamed through the daemon that
//! also owns every keystroke, and a host restart took the upload with it.
//!
//! What moved is only the receiving END. The client end stays in Swift
//! (`Sources/SlopDeskFileTransfer`), because it is driven by `AppKit`'s drop handler and reports
//! into `SwiftUI`. A protocol's two ends are what the one-implementation rule allows: hostd's
//! client encodes a request and decodes a reply, dropd does the mirror, one implementation each.
//!
//! Per the tree's standing rule, this is a separate binary — never FFI — so `swift build` stays
//! headless and cargo-free.
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

pub use client::{
    CHUNK_BYTE_COUNT, FrameError, ReplyFrameDecoder, chunk_frame_len, decode_reply_payload,
    encode_request_frame, write_chunk_frame,
};
pub use name::sanitize;
pub use protocol::{DecodeError, Reply, Request, decode_request, encode_reply_frame};
pub use receive::{Effect, ReceiveLogic};
pub use server::serve;
pub use sink::{DiskSink, SinkError};
