//! # aislopdesk-core
//!
//! The portable, side-effect-free core of Aislopdesk and the **single source of truth**
//! for its logic: the wire codecs, forward-error correction, packetizer/reassembler,
//! the realtime-media controllers, the pure host server-logic (the session / mux /
//! routing brain), and the terminal/PTY protocol (see [`terminal`]) — all in 100% safe
//! Rust.
//!
//! ## Why this crate exists
//!
//! This crate *defines* the algorithms. The macOS/iOS app is the platform shell that
//! either calls into this core over the C ABI, or — for the surfaces still implemented
//! natively in Swift for performance — keeps a copy that **tracks this core** (held in
//! agreement with it, never the reverse). The same core lets a future Android client
//! link the exact same algorithms over the C ABI / JNI boundary (the ALVR pattern:
//! Rust owns reassembly/FEC/jitter/ABR/recovery and the server brain; the platform
//! shell owns capture, the socket, and the hardware codec).
//!
//! Cross-language agreement is *proven*, not assumed: the `golden_parity` integration
//! test asserts this core reproduces the checked-in golden corpus byte-for-byte and
//! bit-for-bit; regenerating that corpus with the Swift `aislopdesk-corevectors` dumper
//! confirms the native Swift copies still track the core.
//!
//! ## Invariants
//!
//! * **No `unsafe`.** Enforced crate-wide by [`forbid(unsafe_code)`]. The FFI lives in the
//!   separate `aislopdesk-ffi` crate at the boundary — the one place `unsafe` is allowed.
//! * **No dependencies.** The shipped library pulls in nothing; auditability and a
//!   minimal Android footprint are the point.
//! * **Never panics on untrusted input.** Every decoder of network bytes returns
//!   [`error::Result`]; a corrupt datagram is dropped, never a crash.

#![forbid(unsafe_code)]

pub mod adaptive_fec;
pub mod adaptive_playout;
pub mod adaptive_qp;
pub mod bytes;
pub mod capture_region;
pub mod coordinate_mapping;
pub mod cursor;
pub mod decode_frontier;
pub mod decode_gate;
pub mod decode_sequencer;
pub mod error;
pub mod fec;
pub mod fps_governor;
pub mod fragment;
pub mod frame_hash;
pub mod geometry;
pub mod gf256;
pub mod host_output_sniffer;
pub mod idle_reap_decider;
pub mod input_button_balance;
pub mod input_event;
pub mod input_motion_coalescer;
pub mod input_router;
pub mod interleaver;
pub mod keepalive;
pub mod live_bitrate_policy;
pub mod live_congestion_controller;
pub mod ltr_controller;
pub mod mux_header;
pub mod nal_unit;
pub mod network_estimate;
pub mod owd_late_detector;
pub mod pacer_depth_policy;
pub mod reassembler;
pub mod recovery;
pub mod recovery_idr_policy;
pub mod recovery_policy;
pub mod recovery_request_deduper;
pub mod recovery_router;
pub mod rs_matrix;
pub mod scroll_reprojection;
pub mod scroll_shift;
pub mod seq;
pub mod static_idr_decider;
pub mod system_dialog_detector;
pub mod terminal;
pub mod terminal_mode_tracker;
pub mod trendline_estimator;
pub mod udp_receive_loop_policy;
pub mod video_control;
pub mod video_mux_router;
pub mod video_session;
pub mod virtual_display_geometry;
pub mod window_geometry;
pub mod window_parking_ledger;
pub mod window_placement;
pub mod ycbcr;

pub use error::{Result, VideoProtocolError};

/// Wire protocol version for the video path (bumped on any breaking change). The Swift
/// shell's `AislopdeskVideoProtocol.version` tracks this.
pub const VIDEO_PROTOCOL_VERSION: u16 = 1;
