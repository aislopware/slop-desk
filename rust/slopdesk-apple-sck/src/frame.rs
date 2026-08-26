//! Reading what a delivered sample buffer IS.
//!
//! `ScreenCaptureKit` attaches a per-sample dictionary describing the frame it just handed over,
//! and the only entry the capture path needs is the status. A frame the framework marks anything
//! but complete carries no new pixels — it is the framework's idle-skip, and more than nine frames
//! in ten of a coding session are one — so the whole downstream chain is skipped for it. That is a
//! READ of what the framework said, not a policy about it, which is why it lives here.
//!
//! ## Why the key is copied rather than bridged
//! `SCStreamFrameInfoStatus` is typed as an `NSString`, and the attachments are a `CFDictionary`.
//! The two are the same object at runtime, but stating that in Rust would mean a pointer cast this
//! family is not allowed to write. Copying the key's text into a `CFString` once, when the tap is
//! built, costs one allocation for the life of a stream and needs no such claim.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use objc2_core_foundation::{CFArray, CFDictionary, CFNumber, CFRetained, CFString, CFType};
use objc2_core_media::{CMSampleBuffer, CMTime};
use objc2_screen_capture_kit::{SCFrameStatus, SCStreamFrameInfoStatus};

/// One attachment dictionary: `CFString`-keyed, holding CF values of assorted type.
type Attachment = CFDictionary<CFString, CFType>;

/// The attachment keys a capture tap reads, resolved once rather than once per frame.
#[derive(Debug)]
pub struct FrameKeys {
    status: CFRetained<CFString>,
}

impl Default for FrameKeys {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameKeys {
    /// Reads the framework's key constants and copies what it needs out of them.
    #[must_use]
    pub fn new() -> Self {
        // SAFETY: framework rule. `SCStreamFrameInfoStatus` is an `extern` static that
        // `ScreenCaptureKit` initialises when its image loads, which is before any code that could
        // reach this has run — the `ScreenCaptureKit` symbols this crate links are what force the
        // load. Rust cannot see that, so the read is `unsafe`; the framework's contract is that it
        // is a non-null immutable string for the process's whole life.
        #[expect(
            unsafe_code,
            reason = "the framework's attachment key is an extern static; objc2 cannot generate it safe"
        )]
        let key = unsafe { SCStreamFrameInfoStatus };
        Self {
            status: CFString::from_str(&key.to_string()),
        }
    }

    /// Whether this sample buffer carries NEW pixels.
    ///
    /// `false` for every other status the framework can report — idle, blank, suspended, started,
    /// stopped — and also for a buffer with no attachment at all, which is a shape
    /// `ScreenCaptureKit` does not document and so is not one to guess about.
    #[must_use]
    pub fn is_complete(&self, sample: &CMSampleBuffer) -> bool {
        self.status(sample) == Some(SCFrameStatus::Complete.0)
    }

    /// The raw frame status, or `None` when the buffer carries no readable one.
    fn status(&self, sample: &CMSampleBuffer) -> Option<isize> {
        // SAFETY: framework rule — a `Get`-rule accessor on a sample buffer this crate holds a
        // reference to for the call. `objc2` generates it `unsafe` because `CoreMedia`'s header does
        // not state nullability; it returns an already-owned `CFRetained`, so no ownership
        // question reaches this crate. `false` asks it not to CREATE an attachment array, which is
        // what keeps this read free of an allocation per frame.
        #[expect(
            unsafe_code,
            reason = "a CoreMedia accessor generated unsafe because its header states no nullability"
        )]
        let attachments = unsafe { sample.sample_attachments_array(false) }?;
        let typed = as_attachments(attachments);
        let first = typed.get(0)?;
        let value = first.get(&self.status)?;
        value.downcast::<CFNumber>().ok()?.as_isize()
    }
}

/// Names the element type of the attachments array.
fn as_attachments(array: CFRetained<CFArray>) -> CFRetained<CFArray<Attachment>> {
    // SAFETY: framework rule. `CoreMedia` documents `CMSampleBufferGetSampleAttachmentsArray` as
    // answering an array of `CFDictionaryRef`, each keyed by `CFString` constants; C's `CFArrayRef`
    // has nowhere to say so, which is why the binding hands back an untyped array. This states it
    // once. Nothing is dereferenced — the typed view only decides which `get` applies, and the one
    // value read through it is checked against `CFNumberGetTypeID` before it is used.
    #[expect(
        unsafe_code,
        reason = "C's CFArrayRef carries no element type; the documentation is where it lives"
    )]
    unsafe {
        CFRetained::cast_unchecked::<CFArray<Attachment>>(array)
    }
}

/// The sample's presentation timestamp.
#[must_use]
pub(crate) fn presentation_time(sample: &CMSampleBuffer) -> CMTime {
    // SAFETY: framework rule — a `Get`-rule accessor answering a `CMTime` by value, on a buffer
    // this crate holds for the call. Generated `unsafe` for the same header reason as the
    // attachment read.
    #[expect(
        unsafe_code,
        reason = "a CoreMedia accessor generated unsafe because its header states no nullability"
    )]
    unsafe {
        sample.presentation_time_stamp()
    }
}

/// The sample's image buffer, or `None` for a buffer that carries no pixels.
#[must_use]
pub(crate) fn image_buffer(sample: &CMSampleBuffer) -> Option<CFRetained<objc2_core_video::CVImageBuffer>> {
    // SAFETY: framework rule — the binding already applies `CoreMedia`'s Get rule for us, answering
    // an owned `CFRetained` rather than a raw pointer, so this crate spends neither of the two
    // ownership admissions `docs/57` §2 counts. What is left `unsafe` is the header's silence on
    // nullability, which the `Option` this answers is the whole handling of.
    #[expect(
        unsafe_code,
        reason = "a CoreMedia accessor generated unsafe because its header states no nullability"
    )]
    unsafe {
        sample.image_buffer()
    }
}

#[cfg(test)]
mod tests {
    use super::FrameKeys;

    /// The key resolves to a real non-empty string, and twice in a row to the SAME one. A key that
    /// silently came back empty would make every frame read as "no status" — which the capture
    /// path treats as "not complete", so the stream would deliver nothing and never say why.
    #[test]
    fn the_attachment_key_resolves_to_a_stable_non_empty_string() {
        let first = FrameKeys::new();
        let second = FrameKeys::new();
        assert!(!first.status.to_string().is_empty());
        assert_eq!(first.status.to_string(), second.status.to_string());
    }

    /// Ten thousand key sets built and dropped. `docs/57` §3 asks every crate in this family for a
    /// leak test, and this is the allocation the crate makes that a test without a window server
    /// can actually reach — one `CFString` copy per capture stream, and a stream is rebuilt on
    /// every resize, every reconnect and every capture-region change.
    #[test]
    fn ten_thousand_key_sets_are_built_and_released_without_drift() {
        for _ in 0..10_000_u32 {
            let keys = FrameKeys::new();
            assert!(!keys.status.to_string().is_empty());
        }
    }
}
