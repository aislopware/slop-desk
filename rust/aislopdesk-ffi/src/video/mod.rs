//! Video-path C ABI: the scalar realtime policies and small-buffer codecs from
//! `aislopdesk_core`'s video modules.
//!
//! Same memory / error contract as the crate root (see `lib.rs`): scalars cross by value;
//! any [`crate::AisdBytes`] returned owns a Rust allocation freed with [`crate::aisd_bytes_free`];
//! borrowed input buffers (`cap == 0`) are copied, never freed. The pure scalar functions here
//! take no pointers and cannot fail.

use crate::{AISD_ERR_MALFORMED, AISD_ERR_TRUNCATED, AisdStatus};
use aislopdesk_core::error::VideoProtocolError;

/// The borrowed-input-buffer primitive, re-exported from the crate's thin unsafe layer so the
/// video submodules keep reaching it as `super::slice_in`.
pub(crate) use crate::slice_in;

mod adaptive_fec;
mod capture_region;
mod coordinate_mapping;
mod cursor;
mod decode_gate;
mod fec;
mod frame_hash;
mod input_button_balance;
mod input_event;
mod live_bitrate_policy;
mod mux_header;
mod owd_late_detector;
mod pacer_depth_policy;
mod packetizer;
mod reassembler;
mod recovery;
mod recovery_idr_policy;
mod recovery_policy;
mod recovery_request_deduper;
mod scroll_reprojection;
mod static_idr_decider;
mod system_dialog_detector;
mod video_control;
mod video_mux_router;
mod virtual_display_geometry;
mod window_geometry;
mod window_placement;
mod ycbcr;

pub use adaptive_fec::*;
pub use capture_region::*;
pub use coordinate_mapping::*;
pub use cursor::*;
pub use decode_gate::*;
pub use fec::*;
pub use frame_hash::*;
pub use input_button_balance::*;
pub use input_event::*;
pub use live_bitrate_policy::*;
pub use mux_header::*;
pub use owd_late_detector::*;
pub use pacer_depth_policy::*;
pub use packetizer::*;
pub use reassembler::*;
pub use recovery::*;
pub use recovery_idr_policy::*;
pub use recovery_policy::*;
pub use recovery_request_deduper::*;
pub use scroll_reprojection::*;
pub use static_idr_decider::*;
pub use system_dialog_detector::*;
pub use video_control::*;
pub use video_mux_router::*;
pub use virtual_display_geometry::*;
pub use window_geometry::*;
pub use window_placement::*;
pub use ycbcr::*;

/// Maps a core video decode error to its boundary status code (shared by the video codecs).
pub(crate) const fn status_for_video_error(error: &VideoProtocolError) -> AisdStatus {
    match error {
        VideoProtocolError::Truncated => AISD_ERR_TRUNCATED,
        VideoProtocolError::Malformed(_) => AISD_ERR_MALFORMED,
    }
}
