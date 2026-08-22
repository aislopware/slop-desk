//! The three enumerators and the one lookup.

use core::ptr;

use objc2_core_foundation::CGPoint;
use objc2_core_graphics::{
    CGDirectDisplayID, CGDisplayBounds, CGError, CGGetActiveDisplayList, CGGetDisplaysWithPoint,
    CGGetOnlineDisplayList,
};
use slopdesk_video::geometry::{VideoPoint, VideoRect};

/// One display: the id the capture path needs to name it, and where it sits.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Display {
    /// The `CGDirectDisplayID`. `SCShareableContent` and the virtual-display code both key on it.
    pub id: u32,
    /// The bounds in CG global points, top-left origin.
    pub bounds: VideoRect,
}

/// One display's bounds. An id that names no display answers a zero rect, which is CoreGraphics's
/// own answer and what every caller here already treats as "no clamp".
#[must_use]
pub fn bounds_of(display: CGDirectDisplayID) -> VideoRect {
    let rect = CGDisplayBounds(display);
    VideoRect::xywh(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

/// The two-call enumeration both display lists use: ask for the count, lend a buffer of exactly
/// that size, then read back no more than the buffer holds.
///
/// `list` is the framework enumerator, wrapped by its caller so that the whole `unsafe` obligation
/// is stated at ONE site per enumerator rather than repeated here.
fn enumerate(list: impl Fn(u32, *mut CGDirectDisplayID, *mut u32) -> CGError) -> Vec<Display> {
    let mut count: u32 = 0;
    if list(0, ptr::null_mut(), &raw mut count) != CGError::Success || count == 0 {
        return Vec::new();
    }
    let mut ids: Vec<CGDirectDisplayID> = vec![0; count as usize];
    let capacity = count;
    let mut reported: u32 = 0;
    if list(capacity, ids.as_mut_ptr(), &raw mut reported) != CGError::Success {
        return Vec::new();
    }
    // Clamped, not trusted: a framework that over-reported would otherwise index past the buffer.
    ids.truncate(reported.min(capacity) as usize);
    ids.into_iter()
        .map(|id| {
            Display {
                id,
                bounds: bounds_of(id),
            }
        })
        .collect()
}

/// Every ACTIVE display's bounds, in CG global points.
///
/// Active means drawable — a mirrored secondary is online but not active. `[]` on any query
/// failure, which every caller reads as "do not clamp and do not reposition" rather than guessing.
#[must_use]
pub fn active() -> Vec<Display> {
    enumerate(|max, ids, count| {
        // SAFETY: framework rule. `ids` is either null — which this enumerator documents as legal,
        // and which is what the counting call passes — or the start of a `Vec<u32>` of exactly
        // `max` initialised elements, so writing "at most `max_displays` ids" cannot leave the
        // allocation. `count` points at an initialised local that outlives the call. Nothing is
        // read back through either pointer here; the `Vec` is read by safe code afterwards.
        #[expect(
            unsafe_code,
            reason = "the display enumerators report through out-pointers; objc2 cannot generate them safe"
        )]
        unsafe {
            CGGetActiveDisplayList(max, ids, count)
        }
    })
}

/// Every ONLINE display's bounds, in CG global points — including mirrored and sleeping ones.
///
/// The parked-window restore wants this rather than [`active`]: a window on a display that
/// is merely asleep is not stranded, and restoring it would move a window the user never lost.
#[must_use]
pub fn online() -> Vec<Display> {
    enumerate(|max, ids, count| {
        // SAFETY: framework rule, identical to `active`'s — same signature, same contract,
        // same fully initialised buffer and count.
        #[expect(
            unsafe_code,
            reason = "the display enumerators report through out-pointers; objc2 cannot generate them safe"
        )]
        unsafe {
            CGGetOnlineDisplayList(max, ids, count)
        }
    })
}

/// The bounds of the display under `point`, or `None` when the point is off every display.
///
/// One id is asked for and one is read: where displays overlap — which mirroring makes possible —
/// CoreGraphics reports the main one first, and the callers here want a display to anchor to, not
/// the whole set.
#[must_use]
pub fn under(point: VideoPoint) -> Option<Display> {
    let mut display: CGDirectDisplayID = 0;
    let mut count: u32 = 0;
    let error = {
        // SAFETY: framework rule. Both pointers name initialised locals that outlive the call, and
        // the lent capacity is 1 for a buffer of exactly one id, so "write at most `max_displays`"
        // cannot leave it. Nothing is dereferenced on this side.
        #[expect(
            unsafe_code,
            reason = "the display enumerators report through out-pointers; objc2 cannot generate them safe"
        )]
        unsafe {
            CGGetDisplaysWithPoint(
                CGPoint::new(point.x, point.y),
                1,
                &raw mut display,
                &raw mut count,
            )
        }
    };
    (error == CGError::Success && count > 0).then(|| {
        Display {
            id: display,
            bounds: bounds_of(display),
        }
    })
}

#[cfg(test)]
mod tests {
    use slopdesk_video::geometry::VideoPoint;

    use super::{active, online, under};

    /// Nothing in this crate holds a CoreFoundation object, so the leak this file could have is a
    /// HANDLE one: an enumerator that opened something per call would, ten thousand calls in, start
    /// failing and answering an empty list. Asking the same question that many times and getting
    /// the same answer every time is the check that matters here.
    #[test]
    fn ten_thousand_enumerations_answer_the_same_thing_as_the_first() {
        let first = active();
        for _ in 0..10_000 {
            assert_eq!(active(), first);
        }
    }

    /// Every rect is standardised — CoreGraphics never answers a negative extent for a display, and
    /// a caller clamping a window to one would silently produce an empty region if it did.
    ///
    /// Vacuous on a headless runner with no displays at all, which is the honest state of it: this
    /// pins the shape of a real answer, not the existence of one.
    #[test]
    fn every_display_answers_a_standardised_rect() {
        for display in active().iter().chain(online().iter()) {
            let rect = display.bounds;
            assert!(rect.size.width >= 0.0, "negative width: {rect:?}");
            assert!(rect.size.height >= 0.0, "negative height: {rect:?}");
        }
    }

    /// A display's own centre resolves back to that display. The lookup and the enumeration have to
    /// agree about the coordinate space, and this is where a y-flip would show.
    #[test]
    fn the_centre_of_a_display_resolves_to_that_display() {
        for display in active() {
            let rect = display.bounds;
            let centre = VideoPoint::new(
                rect.origin.x + rect.size.width / 2.0,
                rect.origin.y + rect.size.height / 2.0,
            );
            assert_eq!(under(centre), Some(display));
        }
    }

    /// Active displays are a subset of online ones, so there can never be more of them.
    #[test]
    fn there_are_never_more_active_displays_than_online_ones() {
        assert!(active().len() <= online().len());
    }

    /// A point no display can contain answers nothing rather than the main display.
    #[test]
    fn a_point_off_every_display_answers_nothing() {
        assert_eq!(under(VideoPoint::new(-1.0e9, -1.0e9)), None);
    }
}
