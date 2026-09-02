//! Bringing a capture stream up, reconfiguring it in place, and taking it down.
//!
//! ## Why a live reconfigure exists at all
//! `startCapture` costs about 120 ms of spin-up, and both things that change about a running
//! capture — the window moved, the pane resized — change only the configuration. Rewriting it in
//! place keeps the stream, the filter and the encoder session alive across a title-bar drag or an
//! agent resizing its own window; restarting would blank the pane for a fifth of a second every
//! time.

use std::fmt;
use std::sync::Arc;

use block2::RcBlock;
use dispatch2::DispatchQueue;
use objc2::AllocAnyThread;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_core_media::{CMSampleBuffer, CMTime};
use objc2_core_video::CVImageBuffer;
use objc2_foundation::NSError;
use objc2_screen_capture_kit::{
    SCContentFilter, SCStream, SCStreamConfiguration, SCStreamOutput, SCStreamOutputType,
};
use slopdesk_video::capture_config::{
    CaptureMode, CaptureSpec, can_resize_in_place, display_local_origin, mode_for_region, origin_moved,
    pinned_source_rect,
};
use slopdesk_video::geometry::{VideoPoint, VideoRect};

use crate::config::{configuration, set_source_rect, source_rect};
use crate::content::ShareableContent;
use crate::filter::{desktop_independent_window, display_excluding_nothing, display_including_window};
use crate::handoff::Handoff;
use crate::own::borrowed;
use crate::tap::Tap;

/// Everything went the way it was asked to.
pub const NO_ERROR: i32 = 0;

/// A framework handler never answered inside the crate's wait limit.
///
/// The three sentinels below are small negatives on purpose: `ScreenCaptureKit`'s own
/// `SCStreamError` codes live in the −3800s, and `CoreMedia`'s in the −12000s, so a caller that
/// logs whatever it is handed can tell one of ours from one of theirs by magnitude alone.
pub const TIMED_OUT: i32 = -1;

/// The window server answered no shareable content — no Screen-Recording grant, or no window
/// server.
pub const NO_CONTENT: i32 = -2;

/// The window or display asked for is not in the content the window server just described. A window
/// that closed between being enumerated and being captured is the ordinary way to get this.
pub const NO_TARGET: i32 = -3;

/// The stream is not display-anchored, or its crop is a poller-owned union — either way there is no
/// configuration here for an in-place change to rewrite, and the caller restarts instead.
pub const NOT_RECONFIGURABLE: i32 = -4;

/// The change was a no-op: the window moved less than half a point, so the crop would land on the
/// same pixels. Positive, because nothing failed.
pub const UNCHANGED: i32 = 1;

/// Where a capture stream's deliveries go.
///
/// Every method is called on the queue its output was added with, and must return promptly: the
/// surface behind a frame goes back to the framework's pool when the call ends, and holding it past
/// `minimumFrameInterval × (queueDepth − 1)` stalls the next capture. Copy what you need to keep.
pub trait CaptureSink: Send + Sync {
    /// A frame carrying NEW pixels, lent for the duration of the call.
    fn frame(&self, image: &CVImageBuffer, presentation: CMTime);

    /// An audio buffer, lent for the duration of the call.
    fn audio(&self, sample: &CMSampleBuffer);

    /// The stream stopped ITSELF — the shared window closed, the display was unplugged, the
    /// Screen-Recording grant was revoked, the window server reset. Never called for a deliberate
    /// [`CaptureStream::stop`].
    fn stopped(&self);
}

/// An explicit display-anchored crop, spanning more than the window's own frame.
///
/// The dialog-expand case: a window and the sheet it put up are two windows, and a crop pinned to
/// the first would cut the second in half. The union rectangle is computed by
/// `slopdesk_video::capture_region` and pinned here, which is also why a stream carrying one
/// refuses an in-place re-anchor — the poller that computed it re-targets instead.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptureRegion {
    /// The display the rectangle is local to.
    pub display_id: u32,
    /// The rectangle in that display's local points.
    pub display_local: VideoRect,
}

/// What to point a capture stream at.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CaptureTarget {
    /// One window, resolved FRESH by id — see [`crate::content`] for why that matters.
    Window {
        /// The `CGWindowID`.
        window_id: u32,
        /// Which filter to build. Decided by
        /// [`slopdesk_video::capture_config::resolve_capture_mode`].
        mode: CaptureMode,
        /// An explicit crop, or `None` to crop to the live window frame.
        region: Option<CaptureRegion>,
    },
    /// A whole display — the full-desktop pane. A display never moves, so no anchor state is kept.
    Display {
        /// The `CGDirectDisplayID`.
        display_id: u32,
    },
}

/// What a caller asks for, in one value.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StartRequest {
    /// What to capture.
    pub target: CaptureTarget,
    /// Output buffer width in pixels.
    pub pixel_width: i32,
    /// Output buffer height in pixels.
    pub pixel_height: i32,
    /// Window points × this = the output buffer's pixels. The source rect is point-space, so this
    /// is what divides the two back apart.
    pub capture_scale: f64,
    /// The delivery ceiling in Hz.
    pub capture_hz: i32,
    /// How many surfaces the framework may hold.
    pub queue_depth: i32,
    /// Capture the full-range NV12 variant.
    pub full_range: bool,
    /// The audio tap's sample rate, or `0` for no tap.
    pub audio_sample_rate: i32,
    /// The audio tap's channel count.
    pub audio_channel_count: i32,
}

/// A live capture stream and the state an in-place reconfigure needs.
pub struct CaptureStream {
    stream: Retained<SCStream>,
    /// Kept alive for the stream's whole life, and never read: `SCStream` holds its delegate
    /// WEAKLY, so dropping this would silence the capture-death callback without silencing
    /// anything else — the pane would freeze on its last frame and nothing would say why. The
    /// field IS the fix, which is why it is only ever written.
    #[expect(
        dead_code,
        reason = "holding the weakly-referenced delegate alive is the whole job"
    )]
    tap: Retained<Tap>,
    config: Retained<SCStreamConfiguration>,
    spec: CaptureSpec,
    capture_scale: f64,
    /// The display bounds the crop is anchored to, or `None` in per-window mode.
    anchor: Option<VideoRect>,
    /// Whether the crop is a poller-owned union region.
    union_owned: bool,
}

// SAFETY: framework rule. `ScreenCaptureKit` documents an `SCStream` as usable from any queue —
// `startCapture`, `stopCapture` and `updateConfiguration` all take completion handlers precisely
// because none of them is tied to a thread — and the configuration behind it is a value holder the
// framework snapshots. `Retained` is not `Send` on its own because `objc2` makes no blanket promise
// for every Objective-C class, which is exactly the per-class judgement this impl is. The one field
// with no framework promise behind it, the tap, is never touched after construction.
#[expect(
    unsafe_code,
    reason = "the framework documents the stream as queue-agnostic; Rust cannot see that"
)]
#[expect(
    clippy::non_send_fields_in_send_ty,
    reason = "the fields are framework objects; the promise is the framework's"
)]
unsafe impl Send for CaptureStream {}
// SAFETY: as above. Every method here takes `&self` and either reads a copied scalar or sends one
// message to an object the framework serialises itself.
#[expect(
    unsafe_code,
    reason = "the framework documents the stream as queue-agnostic; Rust cannot see that"
)]
unsafe impl Sync for CaptureStream {}

impl fmt::Debug for CaptureStream {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CaptureStream")
            .field("spec", &self.spec)
            .field("capture_scale", &self.capture_scale)
            .field("anchor", &self.anchor)
            .field("union_owned", &self.union_owned)
            .finish_non_exhaustive()
    }
}

impl CaptureStream {
    /// Resolves the target, builds a filter and a configuration for it, and starts capturing.
    ///
    /// ⚠️ BLOCKS until `ScreenCaptureKit` answers, and requires a window server plus a
    /// Screen-Recording grant — no test can call this.
    ///
    /// # Errors
    /// A `ScreenCaptureKit` error code, or one of this module's own sentinels when the failure was
    /// upstream of the framework: nothing shareable, nothing matching, or no answer at all.
    pub fn start(
        request: StartRequest,
        sink: Arc<dyn CaptureSink>,
        frame_queue: &DispatchQueue,
        audio_queue: &DispatchQueue,
    ) -> Result<Self, i32> {
        let content = ShareableContent::current(false, false).ok_or(NO_CONTENT)?;
        let mut spec = CaptureSpec {
            pixel_width: request.pixel_width,
            pixel_height: request.pixel_height,
            capture_hz: request.capture_hz,
            queue_depth: request.queue_depth,
            source_rect: pinned_source_rect(request.pixel_width, request.pixel_height, request.capture_scale),
            full_range: request.full_range,
            include_child_windows: false,
            audio_sample_rate: request.audio_sample_rate,
            audio_channel_count: request.audio_channel_count,
        };
        let mut anchor = None;
        let mut union_owned = false;

        let filter = match request.target {
            CaptureTarget::Display { display_id } => {
                let display = content.display(display_id).ok_or(NO_TARGET)?;
                display_excluding_nothing(&display)
            },
            CaptureTarget::Window {
                window_id,
                mode,
                region,
            } => {
                let window = content.window(window_id).ok_or(NO_TARGET)?;
                let frame = window.frame();
                // A region spans the window AND the dialog it put up, and only the including
                // filter composites both — so it overrides whatever mode was asked for.
                let mode = mode_for_region(mode, region.is_some());
                // Every display-anchored shape wants the display the window is ON, and a region
                // carries its own. A window mode wants neither, and a display-anchored mode that
                // cannot find a display falls back to the per-window compositor rather than
                // failing: a capture with a nudged origin beats no capture at all.
                let display = match (mode, region) {
                    (CaptureMode::Window, _) => None,
                    (_, Some(region)) => content.display(region.display_id),
                    (_, None) => content.display_under(VideoPoint::new(frame.mid_x(), frame.mid_y())),
                };
                let size = spec.source_rect.size;
                display.map_or_else(
                    || desktop_independent_window(&window),
                    |display| {
                        let bounds = display.bounds();
                        spec.source_rect = region.map_or_else(
                            || VideoRect::new(display_local_origin(frame.origin, bounds.origin), size),
                            |region| region.display_local,
                        );
                        anchor = Some(bounds);
                        union_owned = region.is_some();
                        if mode == CaptureMode::DisplayExcluding {
                            display_excluding_nothing(&display)
                        } else {
                            spec.include_child_windows = true;
                            display_including_window(&display, &window)
                        }
                    },
                )
            },
        };

        let config = configuration(&spec);
        let tap = Tap::new(sink);
        let stream = new_stream(&filter, &config, &tap);
        add_output(&stream, &tap, SCStreamOutputType::Screen, frame_queue)?;
        if spec.captures_audio() {
            add_output(&stream, &tap, SCStreamOutputType::Audio, audio_queue)?;
        }
        match start_capture(&stream) {
            NO_ERROR => {
                Ok(Self {
                    stream,
                    tap,
                    config,
                    spec,
                    capture_scale: request.capture_scale,
                    anchor,
                    union_owned,
                })
            },
            status => Err(status),
        }
    }

    /// Whether the crop is anchored to a display rather than to the window's own backing store.
    #[must_use]
    pub const fn is_display_anchored(&self) -> bool {
        self.anchor.is_some()
    }

    /// Whether the crop is a poller-owned union region.
    #[must_use]
    pub const fn is_union_anchored(&self) -> bool {
        self.union_owned
    }

    /// Re-origins a display-anchored crop after the window moved.
    ///
    /// Answers [`UNCHANGED`] for a move under half a point, [`NOT_RECONFIGURABLE`] when there is no
    /// anchor to rewrite or the crop is a union, [`NO_ERROR`] when the live stream took the new
    /// crop, and a framework status when it refused. The caller forces a keyframe after a success:
    /// the crop jump lands mid-GOP as a whole-frame delta, and an anchor right after it is what
    /// keeps a late-joining client from decoding half of each.
    #[must_use]
    pub fn reanchor(&self, window_origin: VideoPoint) -> i32 {
        let Some(bounds) = self.anchor.filter(|_| !self.union_owned) else {
            return NOT_RECONFIGURABLE;
        };
        let current = source_rect(&self.config);
        let wanted = display_local_origin(window_origin, bounds.origin);
        if !origin_moved(current.origin, wanted) {
            return UNCHANGED;
        }
        set_source_rect(&self.config, VideoRect::new(wanted, current.size));
        update_configuration(&self.stream, &self.config)
    }

    /// Resizes a display-anchored capture in place, keeping the crop's origin.
    ///
    /// Rebuilds the configuration at the new pixel size — width, height and the point-space crop
    /// all move together — and hands it to the live stream. The filter is untouched: the same
    /// window on the same display, sampled differently.
    ///
    /// Answers [`NOT_RECONFIGURABLE`] for a stream this is not allowed on, [`NO_ERROR`] on success,
    /// and a framework status when the stream refused — in which case it keeps running at the OLD
    /// size rather than dying.
    #[must_use]
    pub fn resize(&mut self, pixel_width: i32, pixel_height: i32) -> i32 {
        if !can_resize_in_place(true, self.is_display_anchored(), self.union_owned) {
            return NOT_RECONFIGURABLE;
        }
        let origin = source_rect(&self.config).origin;
        let sized = pinned_source_rect(pixel_width, pixel_height, self.capture_scale);
        let spec = CaptureSpec {
            pixel_width,
            pixel_height,
            source_rect: VideoRect::new(origin, sized.size),
            ..self.spec
        };
        let config = configuration(&spec);
        let status = update_configuration(&self.stream, &config);
        if status == NO_ERROR {
            self.config = config;
            self.spec = spec;
        }
        status
    }

    /// Stops the capture and waits for the framework to confirm.
    ///
    /// A stream that already died stops with an error, which is reported rather than hidden — but
    /// the caller's teardown is the same either way, and this crate's own contract is that the
    /// capture-death callback has already fired for that case.
    #[must_use]
    pub fn stop(&self) -> i32 {
        let handoff = Handoff::<i32>::new();
        let filler = Arc::clone(&handoff);
        let completion = RcBlock::new(move |error: *mut NSError| filler.deliver(error_code(error)));
        // SAFETY: framework rule — `stopCaptureWithCompletionHandler:` on a live stream this crate
        // owns, taking a copyable heap block. The block outlives this call by design and holds only
        // an `Arc`; the stream is documented as safe to stop from any queue.
        #[expect(
            unsafe_code,
            reason = "an SCStream lifecycle method; generated unsafe because the header states no \
                      nullability"
        )]
        unsafe {
            self.stream.stopCaptureWithCompletionHandler(Some(&completion));
        }
        handoff.take().unwrap_or(TIMED_OUT)
    }
}

impl Drop for CaptureStream {
    /// A stream that is merely let go is stopped, not leaked. The window server keeps a capture
    /// running for as long as nobody says otherwise, and once the `Retained<SCStream>` is gone
    /// there is no handle left in this process to say it with — so the type says it, rather than
    /// trusting every owner to. Fire-and-forget: a drop has nobody to report to, and a stream the
    /// owner already stopped answers the second stop with an error nobody is reading. The one
    /// owner today (`slopdesk-videohostd`'s `Capturer`) does stop first, so on the ordinary path
    /// this is the framework declining a repeat.
    fn drop(&mut self) {
        // SAFETY: framework rule — `stopCaptureWithCompletionHandler:` on a live stream this crate
        // owns, with no handler; the stream is documented as safe to stop from any queue, and a
        // repeated stop is an error reply, not a fault.
        #[expect(
            unsafe_code,
            reason = "an SCStream lifecycle method; generated unsafe because the header states no \
                      nullability"
        )]
        unsafe {
            self.stream.stopCaptureWithCompletionHandler(None);
        }
    }
}

/// Builds the stream. Split out so the `unsafe` obligation is stated once, next to the two
/// arguments it is about.
fn new_stream(
    filter: &SCContentFilter,
    config: &SCStreamConfiguration,
    tap: &Retained<Tap>,
) -> Retained<SCStream> {
    let delegate = ProtocolObject::from_ref(&**tap);
    // SAFETY: framework rule — `initWithFilter:configuration:delegate:` on a fresh allocation. The
    // filter and the configuration are copied by the stream (`ScreenCaptureKit` documents the
    // configuration as a value it snapshots, which is why `updateConfiguration:` exists at all),
    // and the delegate is held WEAKLY — which is why the caller keeps the tap alive rather than
    // trusting the stream to.
    #[expect(
        unsafe_code,
        reason = "an SCStream initialiser; generated unsafe because the header states no nullability"
    )]
    unsafe {
        SCStream::initWithFilter_configuration_delegate(SCStream::alloc(), filter, config, Some(delegate))
    }
}

/// Adds one output on one queue.
fn add_output(
    stream: &SCStream,
    tap: &Retained<Tap>,
    kind: SCStreamOutputType,
    queue: &DispatchQueue,
) -> Result<(), i32> {
    let output: &ProtocolObject<dyn SCStreamOutput> = ProtocolObject::from_ref(&**tap);
    // SAFETY: framework rule — `addStreamOutput:type:sampleHandlerQueue:error:` before
    // `startCapture`, which is the only point `ScreenCaptureKit` documents it as valid. The stream
    // retains both the output and the queue; the queue is the caller's, and `slopdesk-ffi` is where
    // its liveness for this call is argued.
    #[expect(
        unsafe_code,
        reason = "an SCStream lifecycle method; generated unsafe because the header states no nullability"
    )]
    let added = unsafe { stream.addStreamOutput_type_sampleHandlerQueue_error(output, kind, Some(queue)) };
    added.map_err(|error| code_of(&error))
}

/// Starts the capture and waits.
fn start_capture(stream: &SCStream) -> i32 {
    let handoff = Handoff::<i32>::new();
    let filler = Arc::clone(&handoff);
    let completion = RcBlock::new(move |error: *mut NSError| filler.deliver(error_code(error)));
    // SAFETY: framework rule — `startCaptureWithCompletionHandler:` on a stream whose outputs are
    // already added, taking a copyable heap block that holds only an `Arc`.
    #[expect(
        unsafe_code,
        reason = "an SCStream lifecycle method; generated unsafe because the header states no nullability"
    )]
    unsafe {
        stream.startCaptureWithCompletionHandler(Some(&completion));
    }
    handoff.take().unwrap_or(TIMED_OUT)
}

/// Hands a rewritten configuration to a running stream and waits.
fn update_configuration(stream: &SCStream, config: &SCStreamConfiguration) -> i32 {
    let handoff = Handoff::<i32>::new();
    let filler = Arc::clone(&handoff);
    let completion = RcBlock::new(move |error: *mut NSError| filler.deliver(error_code(error)));
    // SAFETY: framework rule — `updateConfiguration:completionHandler:` is documented as valid on a
    // RUNNING stream, which is the whole reason this path exists. The configuration is snapshotted
    // by the framework; the block holds only an `Arc`.
    #[expect(
        unsafe_code,
        reason = "an SCStream lifecycle method; generated unsafe because the header states no nullability"
    )]
    unsafe {
        stream.updateConfiguration_completionHandler(config, Some(&completion));
    }
    handoff.take().unwrap_or(TIMED_OUT)
}

/// The code an error object carries, or [`NO_ERROR`] for the null the frameworks use to mean
/// success.
fn error_code(error: *mut NSError) -> i32 {
    // SAFETY: framework rule — the completion handler's argument is a borrowed +0 reference valid
    // for the call, and taking one of our own is how it is read at all. Null is the frameworks' own
    // "nothing went wrong", and `borrowed` answers `None` for it.
    borrowed(error).as_deref().map_or(NO_ERROR, code_of)
}

/// One error object's code, narrowed to the width an FFI door carries.
fn code_of(error: &NSError) -> i32 {
    i32::try_from(error.code()).unwrap_or(TIMED_OUT)
}

#[cfg(test)]
mod tests {
    use slopdesk_video::capture_config::CaptureMode;
    use slopdesk_video::geometry::VideoRect;

    use super::{
        CaptureRegion, CaptureTarget, NO_CONTENT, NO_ERROR, NO_TARGET, NOT_RECONFIGURABLE, TIMED_OUT,
        UNCHANGED,
    };

    /// The sentinels are distinct, and every failure is negative while the one success-that-did-
    /// nothing is positive. A caller switching on the sign is the shape the doors above use.
    #[test]
    fn every_sentinel_is_distinct_and_signed_the_way_a_caller_reads_it() {
        let failures = [TIMED_OUT, NO_CONTENT, NO_TARGET, NOT_RECONFIGURABLE];
        for (index, first) in failures.iter().enumerate() {
            assert!(*first < 0, "a failure is negative");
            for second in failures.iter().skip(index + 1) {
                assert_ne!(first, second, "two failures cannot share a code");
            }
        }
        assert_eq!(NO_ERROR, 0);
        const { assert!(UNCHANGED > 0, "nothing failed, so it is not a failure code") }
    }

    /// The sentinels stay clear of `ScreenCaptureKit`'s own error range, which is what lets a log
    /// line tell one of ours from one of theirs. `SCStreamError` codes are in the −3800s.
    #[test]
    fn the_sentinels_cannot_be_mistaken_for_a_framework_code() {
        for sentinel in [TIMED_OUT, NO_CONTENT, NO_TARGET, NOT_RECONFIGURABLE] {
            assert!(
                sentinel > -1000,
                "a sentinel is a small negative, not a framework code"
            );
        }
    }

    /// A target is a plain value, so the FFI door can build one without touching the framework —
    /// which is the only part of `start` a test can reach.
    #[test]
    fn a_target_carries_everything_the_start_path_needs_to_resolve_it() {
        let plain = CaptureTarget::Window {
            window_id: 42,
            mode: CaptureMode::Window,
            region: None,
        };
        let expanded = CaptureTarget::Window {
            window_id: 42,
            mode: CaptureMode::DisplayIncluding,
            region: Some(CaptureRegion {
                display_id: 7,
                display_local: VideoRect::xywh(10.0, 20.0, 800.0, 600.0),
            }),
        };
        assert_ne!(plain, expanded);
        assert_ne!(plain, CaptureTarget::Display { display_id: 7 });
    }
}
