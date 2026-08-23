//! One [`CaptureSpec`] becomes one `SCStreamConfiguration`, field for field.
//!
//! Nothing is decided here. Every number arrives already clamped by
//! [`slopdesk_video::capture_config`]; what is left is which property each one is spelled as, and
//! the handful of properties that are constants rather than knobs.
//!
//! ## The constants, and what each one buys
//! * **NV12** — the pixel format the compressor takes directly, so the captured surface reaches the
//!   encoder with no colour conversion at all. Which of the two NV12 variants is the range knob,
//!   and it is the CAPTURE side that decides it: the compressor reads the format back to stamp the
//!   `video_full_range_flag` into the stream's parameter sets. Both variants share a plane layout,
//!   so a client's texture creation is unaffected either way.
//! * **No cursor, no click ripple** — the cursor is composited by the client from a side channel,
//!   at the client's own frame rate, so a cursor burnt into the pixels would be a second one
//!   lagging the first. The ripple only applies to BGRA capture and is set for intent.
//! * **sRGB** — the colour space every client assumes.
//! * **No shadow, no global clip** — either would pad the captured rect past the window's own frame
//!   and the pin below would then be cropping the padding.
//!
//! ## Two properties are version-gated in Objective-C and not here
//! `ignoreShadowsSingleWindow` and `ignoreGlobalClipSingleWindow` arrived in macOS 14,
//! `includeChildWindows` in 14.2. The Swift this replaces guarded each with an availability check;
//! this crate does not, because the host's own deployment target is past all three. A property that
//! did not exist would be an unrecognised selector, which is a crash rather than a silent
//! misconfiguration — so the guard would be protecting a build that cannot happen.

use objc2::rc::Retained;
use objc2_core_graphics::kCGColorSpaceSRGB;
use objc2_core_media::CMTime;
use objc2_core_video::{
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
};
use objc2_screen_capture_kit::SCStreamConfiguration;
use slopdesk_video::capture_config::CaptureSpec;
use slopdesk_video::geometry::VideoRect;

/// The `CMTime` flag that marks a time valid. Every timestamp this crate builds carries it; a
/// configuration whose minimum frame interval was not flagged valid is silently ignored.
const TIME_IS_VALID: u32 = 1;

/// Builds the stream configuration a [`CaptureSpec`] describes.
///
/// ⚠️ Allocates an Objective-C object, so it needs the Objective-C runtime but NOT a window server
/// — this is the one part of the capture path a headless test could exercise, and the crate's leak
/// test does.
#[must_use]
pub(crate) fn configuration(spec: &CaptureSpec) -> Retained<SCStreamConfiguration> {
    // SAFETY: framework rule — `new` on a plain `NSObject` subclass with no initialiser
    // requirements. `objc2` generates every `ScreenCaptureKit` method `unsafe` because the framework's
    // header states no nullability and no thread affinity; `SCStreamConfiguration` is a value
    // holder the documentation shows being built on whatever queue the caller is on.
    #[expect(
        unsafe_code,
        reason = "allocating a configuration; ScreenCaptureKit's header states no nullability so objc2 \
                  generates it unsafe"
    )]
    let config = unsafe { SCStreamConfiguration::new() };

    // SAFETY: framework rule — a run of property writes on an object this crate just allocated and
    // holds the only reference to. Each takes a scalar or a `CFString` constant, none escapes, and
    // the object is not yet attached to a stream, so no concurrent reader exists.
    #[expect(
        unsafe_code,
        reason = "property writes on a freshly allocated configuration; generated unsafe for the same \
                  header reason"
    )]
    unsafe {
        config.setPixelFormat(if spec.full_range {
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        } else {
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        });
        config.setShowsCursor(false);
        config.setShowMouseClicks(false);
        config.setMinimumFrameInterval(CMTime {
            value: 1,
            timescale: spec.capture_hz.max(1),
            flags: objc2_core_media::CMTimeFlags(TIME_IS_VALID),
            epoch: 0,
        });
        config.setQueueDepth(isize::try_from(spec.queue_depth).unwrap_or(0));
        config.setWidth(usize::try_from(spec.pixel_width).unwrap_or(0));
        config.setHeight(usize::try_from(spec.pixel_height).unwrap_or(0));
        config.setIgnoreShadowsSingleWindow(true);
        config.setIgnoreGlobalClipSingleWindow(true);
        config.setIncludeChildWindows(spec.include_child_windows);
        if spec.captures_audio() {
            config.setCapturesAudio(true);
            config.setExcludesCurrentProcessAudio(true);
            config.setSampleRate(isize::try_from(spec.audio_sample_rate).unwrap_or(0));
            config.setChannelCount(isize::try_from(spec.audio_channel_count).unwrap_or(0));
        }
    }

    // SAFETY: framework rule — reading the sRGB colour-space name. It is an `extern` static that
    // CoreGraphics initialises at image load, before any code that could reach this has run; Rust
    // cannot see that, so the read is `unsafe` and the setter that takes it is too.
    #[expect(
        unsafe_code,
        reason = "kCGColorSpaceSRGB is an extern static; objc2 cannot generate it safe"
    )]
    unsafe {
        config.setColorSpaceName(kCGColorSpaceSRGB);
    }

    set_source_rect(&config, spec.source_rect);
    config
}

/// Rewrites the sampled region of a configuration.
///
/// Separate from [`configuration`] because a live re-anchor changes only this: a window that moved
/// keeps its size, its format and its audio tap, and rebuilding the rest would ask the framework to
/// re-validate properties that did not change.
pub(crate) fn set_source_rect(config: &SCStreamConfiguration, rect: VideoRect) {
    // SAFETY: framework rule — one property write taking a `CGRect` by value, on a configuration
    // owned by this crate. Safe to do on a LIVE configuration too, which is what the re-anchor
    // path relies on: the framework re-reads the property when `updateConfiguration:` is called
    // and not before.
    #[expect(
        unsafe_code,
        reason = "a property write taking a CGRect by value; generated unsafe for the header reason"
    )]
    unsafe {
        config.setSourceRect(objc2_core_foundation::CGRect {
            origin: objc2_core_foundation::CGPoint {
                x: rect.origin.x,
                y: rect.origin.y,
            },
            size: objc2_core_foundation::CGSize {
                width: rect.size.width,
                height: rect.size.height,
            },
        });
    }
}

/// The sampled region a configuration currently names, in points.
pub(crate) fn source_rect(config: &SCStreamConfiguration) -> VideoRect {
    // SAFETY: framework rule — the read half of [`set_source_rect`], answering a `CGRect` by value.
    #[expect(unsafe_code, reason = "a property read answering a CGRect by value")]
    let rect = unsafe { config.sourceRect() };
    VideoRect::xywh(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}
