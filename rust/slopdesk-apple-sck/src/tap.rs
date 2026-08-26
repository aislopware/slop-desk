//! The Objective-C object `ScreenCaptureKit` calls back into.
//!
//! One class serves both protocols. `SCStreamOutput` is sent a sample buffer per delivery — screen
//! on one queue, audio on another — and `SCStreamDelegate` is sent one message when the stream dies
//! on its own. They are the same object because the framework's own contract ties them together: a
//! stream holds its delegate weakly and its outputs strongly, so a separate delegate would have to
//! be kept alive by hand, and the one that already survives for the outputs' sake is the honest
//! place to put it.
//!
//! ## Why the whole module carries ONE `unsafe` exemption
//! `define_class!` writes the Objective-C class pair, the method thunks and the protocol
//! conformances, and every one of those is `unsafe` inside the macro's own expansion. A per-site
//! `#[expect]` cannot reach into a macro body, so the exemption sits on the module and the
//! obligations are stated here instead, once each:
//!
//! * **The superclass.** `NSObject` imposes no subclassing requirements, and this class implements
//!   no `Drop`, which is what `#[unsafe(super(NSObject))]` asserts.
//! * **The protocol conformances.** Each `unsafe impl` claims the methods below really do implement
//!   the protocol they are declared under, with the selector and signature the framework will send.
//!   Both selectors are copied from the generated bindings above them.
//! * **The thread kind.** Neither protocol is main-thread-only — `ScreenCaptureKit` delivers on the
//!   queue the caller named when adding the output — so the class takes `objc2`'s default, which
//!   allows allocation from any thread.
//!
//! ## What the callbacks do NOT do
//! Nothing that could block. A delivery hands the sink a borrowed buffer and returns, because the
//! surface behind it must go back to the framework's pool inside
//! `minimumFrameInterval × (queueDepth − 1)` or the next capture stalls waiting for it. Everything
//! the sink wants to keep, it copies.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]
#![expect(
    unsafe_code,
    reason = "define_class! expands to unsafe impls a per-site #[expect] cannot reach; the module header \
              states each obligation"
)]

use std::sync::Arc;

use objc2::rc::Retained;
use objc2::runtime::NSObject;
use objc2::{AllocAnyThread, DefinedClass, define_class, msg_send};
use objc2_core_media::CMSampleBuffer;
use objc2_foundation::{NSError, NSObjectProtocol};
use objc2_screen_capture_kit::{SCStream, SCStreamDelegate, SCStreamOutput, SCStreamOutputType};

use crate::frame::{FrameKeys, image_buffer, presentation_time};
use crate::stream::CaptureSink;

/// What the tap holds for the life of a stream.
pub(crate) struct TapIvars {
    /// Where deliveries go. `Arc` rather than a borrow because the framework may call back at any
    /// point between `startCapture` answering and `stopCapture` returning, and a borrow would tie
    /// that window to a Rust lifetime the framework does not respect.
    sink: Arc<dyn CaptureSink>,
    /// The attachment key, resolved once. See [`crate::frame`].
    keys: FrameKeys,
}

define_class!(
    // SAFETY:
    // - `NSObject` imposes no subclassing requirements.
    // - `Tap` implements no `Drop`.
    #[unsafe(super(NSObject))]
    #[name = "SlopDeskCaptureTap"]
    #[ivars = TapIvars]
    pub(crate) struct Tap;

    unsafe impl NSObjectProtocol for Tap {}

    // SAFETY: the method below carries the selector and signature `SCStreamOutput` declares, copied
    // from the generated binding.
    unsafe impl SCStreamOutput for Tap {
        #[unsafe(method(stream:didOutputSampleBuffer:ofType:))]
        fn did_output(&self, _stream: &SCStream, sample: &CMSampleBuffer, kind: SCStreamOutputType) {
            let ivars = self.ivars();
            if kind == SCStreamOutputType::Audio {
                ivars.sink.audio(sample);
                return;
            }
            if kind != SCStreamOutputType::Screen || !ivars.keys.is_complete(sample) {
                return;
            }
            if let Some(image) = image_buffer(sample) {
                ivars.sink.frame(&image, presentation_time(sample));
            }
        }
    }

    // SAFETY: the method below carries the selector and signature `SCStreamDelegate` declares,
    // copied from the generated binding.
    unsafe impl SCStreamDelegate for Tap {
        #[unsafe(method(stream:didStopWithError:))]
        fn did_stop(&self, _stream: &SCStream, _error: &NSError) {
            self.ivars().sink.stopped();
        }
    }
);

impl Tap {
    /// Builds a tap around a sink.
    pub(crate) fn new(sink: Arc<dyn CaptureSink>) -> Retained<Self> {
        let this = Self::alloc().set_ivars(TapIvars {
            sink,
            keys: FrameKeys::new(),
        });
        // SAFETY: `NSObject`'s `init` on a freshly allocated instance whose ivars are set, which is
        // the shape `define_class!` documents for a class with no initialiser of its own.
        unsafe { msg_send![super(this), init] }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use objc2_core_media::{CMSampleBuffer, CMTime};
    use objc2_core_video::CVImageBuffer;

    use super::Tap;
    use crate::stream::CaptureSink;

    /// A sink that only counts, so a test can assert the wiring rather than the pixels.
    #[derive(Debug, Default)]
    struct Counting {
        stopped: AtomicUsize,
    }

    impl CaptureSink for Counting {
        fn frame(&self, _image: &CVImageBuffer, _presentation: CMTime) {}

        fn audio(&self, _sample: &CMSampleBuffer) {}

        fn stopped(&self) {
            self.stopped.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// The class registers, allocates and deallocates. A stream cannot be created headlessly, but
    /// the class pair can — and a mis-declared protocol conformance or a bad ivar layout fails
    /// HERE rather than on the one machine with a Screen-Recording grant.
    #[test]
    fn the_tap_class_registers_and_allocates() {
        let counting = Arc::new(Counting::default());
        let tap = Tap::new(counting.clone());
        drop(tap);
        assert_eq!(counting.stopped.load(Ordering::Relaxed), 0);
    }

    /// Ten thousand taps built and dropped. The leak test `docs/57` §3 asks for, taken over the
    /// object that holds a stream's whole callback state: if `set_ivars` and the `Retained` drop
    /// did not pair, this would exhaust rather than merely mis-count.
    #[test]
    fn ten_thousand_taps_are_built_and_released_without_drift() {
        let counting = Arc::new(Counting::default());
        for _ in 0..10_000_u32 {
            let tap = Tap::new(counting.clone());
            drop(tap);
        }
        assert_eq!(
            Arc::strong_count(&counting),
            1,
            "every tap released the sink it was built around",
        );
    }
}
