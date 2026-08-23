//! `ScreenCaptureKit` — asking the window server for pixels, and nothing about what to do with
//! them.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything. This crate turns an
//! instruction into a live capture stream and each delivered sample buffer into values. It decides
//! nothing: the delivery ceiling, the surface depth, which content filter a parked window wants,
//! where a moved window's crop belongs, whether a resize may happen in place — all of that is
//! `slopdesk_video`'s [`capture_config`](slopdesk_video::capture_config), which `forbid`s `unsafe`
//! and is exercised headless.
//!
//! ## The three things a caller does
//! [`ShareableContent::current`] asks what exists. [`CaptureStream::start`] builds a filter and a
//! configuration from a [`CaptureSpec`](slopdesk_video::capture_config::CaptureSpec) and brings a
//! stream up against them. [`CaptureStream::stop`] takes it down. In between,
//! [`CaptureStream::reconfigure`] rewrites the live configuration — a moved window's crop, a
//! resized pane's buffer — without the ~120 ms restart a fresh stream costs.
//!
//! ## Why every entry point BLOCKS
//! `ScreenCaptureKit`'s lifecycle is all completion handlers, and the caller on the other side of
//! the FFI door is Swift `async` code that is already off the main queue. A door that took a
//! callback per lifecycle step would push a state machine across the boundary for no gain, so each
//! one waits on its handler instead and answers a status. The handlers run on the framework's own
//! queues, never on the caller's, which is what makes the wait safe — and the wait is bounded, so a
//! framework that never answers costs a timeout rather than a wedged daemon.
//!
//! ## Why the delivery queues come from the CALLER
//! `addStreamOutput:type:sampleHandlerQueue:` names the queue each output delivers on, and this
//! crate never makes one. The frame queue is the same serial queue the host's static-IDR timer runs
//! on: that sharing IS the discipline that lets the capture callback and the timer touch one cached
//! frame with no lock, and a queue made here would silently break it. The audio queue is a second
//! one so a slow synchronous encode cannot delay a 10 ms audio buffer.
//!
//! ## What a sample buffer becomes
//! A frame the framework marks anything but complete carries no new pixels, and this crate drops it
//! rather than reporting it — that read is the framework telling us what it just handed over, not a
//! policy. What reaches the sink is a live image buffer, its presentation timestamp, and nothing
//! else.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod config;
#[cfg(target_os = "macos")]
mod content;
#[cfg(target_os = "macos")]
mod filter;
#[cfg(target_os = "macos")]
mod frame;
#[cfg(target_os = "macos")]
mod handoff;
#[cfg(target_os = "macos")]
mod stream;
#[cfg(target_os = "macos")]
mod tap;

#[cfg(target_os = "macos")]
pub use content::{Display, ShareableContent, Window};
#[cfg(target_os = "macos")]
pub use dispatch2::DispatchQueue;
#[cfg(target_os = "macos")]
pub use frame::FrameKeys;
#[cfg(target_os = "macos")]
pub use objc2_core_media::{CMSampleBuffer, CMTime};
#[cfg(target_os = "macos")]
pub use objc2_core_video::CVImageBuffer;
#[cfg(target_os = "macos")]
pub use stream::{
    CaptureRegion, CaptureSink, CaptureStream, CaptureTarget, NO_CONTENT, NO_ERROR, NO_TARGET,
    NOT_RECONFIGURABLE, StartRequest, TIMED_OUT, UNCHANGED,
};
