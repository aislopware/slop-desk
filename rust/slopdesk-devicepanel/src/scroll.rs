//! A scroll wheel or a trackpad becomes ONE continuous finger on the device.
//!
//! Both panels do this, for reasons that start out different and end up the same.
//!
//! ## The simulator: a verb that costs 275 milliseconds
//!
//! The simulator panel used to bank scroll travel and fire a discrete `swipe` every 24 points.
//! Measured 2026-08-04 by feeding `baguette input` back-to-back envelopes and timing its
//! per-envelope acks:
//!
//! ```text
//! swipe (duration 0.01)   275.3 ms      touch1-down    0.1 ms
//! swipe (duration 0.05)   281.3 ms      touch1-move    0.0 ms
//! swipe (duration 0.25)   743.7 ms      touch1-up      0.0 ms
//! tap   (duration 0.05)    73.3 ms      touch2-move   25.2 ms
//! ```
//!
//! The 275 ms is a FIXED cost — it barely moves between a 10 ms and a 50 ms nominal duration — and
//! it is the server's main actor, so nothing else gets serviced while it runs. A single trackpad
//! flick banks enough travel for ten of them, which is nearly three seconds of backlog for a
//! gesture that took a fifth of a second to make.
//!
//! ## Android: a wheel verb that exists and is still the wrong one
//!
//! `scrcpy` has `INJECT_SCROLL_EVENT`, and using it would be the mistake. `ACTION_SCROLL` reaches a
//! `RecyclerView` as a discrete wheel notch: it scrolls, and that is all it does — no over-scroll
//! stretch, no edge glow, no fling, no rubber band. Every piece of feedback Android gives a
//! scrolling list comes from the touch path. Momentum is computed by `VelocityTracker` from the
//! touch HISTORY at the moment of lift, and a stream of notches has none.
//!
//! ## So: a real finger
//!
//! Plant one contact, move it with the wheel, lift it when the gesture ends, and the platform's own
//! scroll view gets exactly the input it was built for — inertia included, because the device
//! computes it.
//!
//! RE-GRIPPING. A trackpad gesture can travel further than the device is tall, and a finger cannot
//! leave the screen and keep scrolling. When the virtual finger reaches the edge this lifts it and
//! plants it again at the far side, which is what a hand does — and it is why the edge margin
//! exists: planting ON the boundary would put the next contact inside the platform's own
//! system-gesture band, where it is a Back or a Home rather than a scroll.
//!
//! ## What stays outside
//!
//! The contacts come out in the FITTED rect's own space, as phases and points. What each becomes on
//! the wire is the panel's: the simulator sends the fitted rect's own coordinates with the surface
//! size beside them, and the Android lane converts to the video's pixel grid because the server
//! DROPS a mismatched pair rather than rescaling it. Those are different protocols, and this is the
//! part that is not.

use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

use crate::geometry::{planted, regrip, scroll_vector, unrotated};

/// Where a scroll event sits in its gesture.
///
/// Trackpads report this; a classic wheel does not, which is what [`Wheel`](Self::Wheel) is for —
/// the caller arms an idle timer and calls [`ScrollGesture::lift`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ScrollPhase {
    /// The gesture began, or the first change of one that began off-view.
    Began = 0,
    /// The gesture continues.
    Changed = 1,
    /// The fingers left the trackpad — ended or cancelled.
    Ended = 2,
    /// A classic wheel notch. No phases exist, so the gesture is opened on the first one and closed
    /// by the caller's idle timer.
    Wheel = 3,
}

/// What the virtual finger does, in the fitted rect's own space.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Action {
    /// Plant the contact.
    Down = 0,
    /// Move the contact that is already down.
    Move = 1,
    /// Lift the contact.
    Up = 2,
}

/// One thing to send, in the order it must be sent.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Contact {
    /// What the finger does.
    pub action: Action,
    /// Where it does it, in the fitted rect's own space.
    pub point: VideoPoint,
}

/// The virtual finger, and everything remembered between scroll events.
///
/// Holds no view, no socket and no timer, so the whole machine is testable from deltas and phases
/// alone.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ScrollGesture {
    finger: Option<VideoPoint>,
}

impl ScrollGesture {
    /// A gesture with no contact down.
    #[must_use]
    pub const fn new() -> Self {
        Self { finger: None }
    }

    /// The finger's position in the fitted rect's own space, or `None` when no contact is down.
    #[must_use]
    pub const fn finger(&self) -> Option<VideoPoint> {
        self.finger
    }

    /// Feed one scroll event. Answers the contacts to send, in order.
    ///
    /// `pointer` is where the cursor is, in the fitted rect's space — the contact is planted there,
    /// so a scroll acts on whatever is under the cursor, exactly as it does on a Mac.
    ///
    /// `angle` un-rotates the delta for a panel whose frame is DRAWN turned while its framebuffer
    /// is not: a delta arrives in screen space, never having passed through the view's
    /// geometry, so on a device held sideways the two disagree by a quarter turn. Zero for a
    /// panel that rotates on the device instead, where the frame is always already the right
    /// way up.
    pub fn accept(
        &mut self,
        delta: VideoSize,
        is_precise: bool,
        phase: ScrollPhase,
        pointer: VideoPoint,
        fitted: VideoRect,
        angle: f64,
    ) -> Vec<Contact> {
        if fitted.size.width <= 0.0 || fitted.size.height <= 0.0 {
            return Vec::new();
        }
        if phase == ScrollPhase::Ended {
            return self.lift();
        }

        let mut contacts = Vec::new();
        if self.finger.is_none() {
            let start = planted(pointer, fitted);
            contacts.push(Contact {
                action: Action::Down,
                point: start,
            });
            self.finger = Some(start);
        }
        // Planted immediately above when it was absent, so the `else` is unreachable; answering the
        // contacts built so far rather than asserting keeps a `deny(panic)` crate honest.
        let Some(mut point) = self.finger else {
            return contacts;
        };

        let travel = unrotated(scroll_vector(delta, is_precise), angle);
        let target = VideoPoint::new(point.x + travel.width, point.y + travel.height);
        let clamped = planted(target, fitted);
        if clamped == target {
            point = clamped;
            contacts.push(Contact {
                action: Action::Move,
                point,
            });
        } else {
            // Out of room. Lift at the boundary, plant again as far the other way as the margin
            // allows, and let the same event's remaining travel apply from there.
            contacts.push(Contact {
                action: Action::Move,
                point: clamped,
            });
            contacts.push(Contact {
                action: Action::Up,
                point: clamped,
            });
            point = regrip(travel, fitted);
            contacts.push(Contact {
                action: Action::Down,
                point,
            });
        }
        self.finger = Some(point);
        contacts
    }

    /// Close a gesture the caller's idle timer has decided is over. Empty with no contact down.
    pub fn lift(&mut self) -> Vec<Contact> {
        self.finger
            .take()
            .map(|point| {
                vec![Contact {
                    action: Action::Up,
                    point,
                }]
            })
            .unwrap_or_default()
    }

    /// Forget the contact without sending anything — the socket went away, so an `up` has nowhere
    /// to go and the device's touch state is moot.
    pub const fn abandon(&mut self) {
        self.finger = None;
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

    use super::{Action, ScrollGesture, ScrollPhase};
    use crate::geometry::EDGE_MARGIN;

    const FITTED: VideoRect = VideoRect {
        origin: VideoPoint { x: 0.0, y: 0.0 },
        size: VideoSize {
            width: 200.0,
            height: 400.0,
        },
    };

    fn actions(contacts: &[super::Contact]) -> Vec<Action> {
        contacts.iter().map(|contact| contact.action).collect()
    }

    /// The first event PLANTS, and it plants under the cursor: a scroll acts on whatever is beneath
    /// the pointer, which is the whole reason the pointer travels with the event.
    #[test]
    fn the_first_event_plants_the_finger_under_the_cursor() {
        let mut gesture = ScrollGesture::new();
        let contacts = gesture.accept(
            VideoSize::new(0.0, -1.0),
            true,
            ScrollPhase::Began,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            0.0,
        );

        assert_eq!(actions(&contacts), [Action::Down, Action::Move]);
        assert_eq!(contacts.first().map(|contact| contact.point.x), Some(100.0));
        assert_eq!(gesture.finger().map(|point| point.y), Some(199.0));
    }

    /// A continuing gesture does NOT re-plant. Each fresh contact would start a new drag, which is
    /// exactly the discrete-swipe behaviour the continuous finger exists to end.
    #[test]
    fn a_continuing_gesture_moves_the_same_contact() {
        let mut gesture = ScrollGesture::new();
        gesture.accept(
            VideoSize::new(0.0, -1.0),
            true,
            ScrollPhase::Began,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            0.0,
        );
        let contacts = gesture.accept(
            VideoSize::new(0.0, -1.0),
            true,
            ScrollPhase::Changed,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            0.0,
        );

        assert_eq!(actions(&contacts), [Action::Move]);
        assert_eq!(gesture.finger().map(|point| point.y), Some(198.0));
    }

    /// A wheel NOTCH is worth many points — a line taken as a point is a movement under the
    /// platform's own touch slop, which the device discards, and the panel looks like it eats
    /// scrolls.
    #[test]
    fn a_wheel_notch_travels_further_than_a_trackpad_point() {
        let travel = |is_precise: bool| {
            let mut gesture = ScrollGesture::new();
            gesture.accept(
                VideoSize::new(0.0, -1.0),
                is_precise,
                ScrollPhase::Wheel,
                VideoPoint::new(100.0, 200.0),
                FITTED,
                0.0,
            );
            gesture.finger().map(|point| point.y)
        };

        assert_eq!(travel(true), Some(199.0));
        assert_eq!(travel(false), Some(200.0 - crate::geometry::POINTS_PER_LINE));
    }

    /// Out of room, the finger RE-GRIPS: lift at the boundary, plant again at the far side. A hand
    /// does this, and a contact that simply stopped at the edge would freeze the scroll there.
    #[test]
    fn a_finger_out_of_room_lifts_and_plants_again() {
        let mut gesture = ScrollGesture::new();
        gesture.accept(
            VideoSize::new(0.0, -1.0),
            true,
            ScrollPhase::Began,
            VideoPoint::new(100.0, EDGE_MARGIN + 1.0),
            FITTED,
            0.0,
        );
        let contacts = gesture.accept(
            VideoSize::new(0.0, -50.0),
            true,
            ScrollPhase::Changed,
            VideoPoint::new(100.0, 0.0),
            FITTED,
            0.0,
        );

        assert_eq!(actions(&contacts), [Action::Move, Action::Up, Action::Down]);
        // The re-grip lands inside the margin, never on it: the boundary is the system-gesture
        // band.
        let replanted = gesture.finger().map(|point| point.y);
        assert_eq!(replanted, Some(FITTED.size.height - EDGE_MARGIN));
    }

    /// The end of the gesture lifts exactly once, and a second end sends nothing: the contact is
    /// already gone, and an extra `up` is a tap the user did not make.
    #[test]
    fn the_end_lifts_once_and_only_once() {
        let mut gesture = ScrollGesture::new();
        gesture.accept(
            VideoSize::new(0.0, -1.0),
            true,
            ScrollPhase::Began,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            0.0,
        );

        let ended = gesture.accept(
            VideoSize::new(0.0, 0.0),
            true,
            ScrollPhase::Ended,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            0.0,
        );
        assert_eq!(actions(&ended), [Action::Up]);
        assert_eq!(gesture.finger(), None);

        let again = gesture.accept(
            VideoSize::new(0.0, 0.0),
            true,
            ScrollPhase::Ended,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            0.0,
        );
        assert!(again.is_empty());
        assert!(gesture.lift().is_empty());
    }

    /// Abandoning sends NOTHING. The socket went away, so an `up` has nowhere to go — and the next
    /// gesture must still plant rather than resume a contact the device forgot.
    #[test]
    fn abandoning_sends_nothing_and_still_forgets_the_contact() {
        let mut gesture = ScrollGesture::new();
        gesture.accept(
            VideoSize::new(0.0, -1.0),
            true,
            ScrollPhase::Began,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            0.0,
        );

        gesture.abandon();
        assert_eq!(gesture.finger(), None);

        let contacts = gesture.accept(
            VideoSize::new(0.0, -1.0),
            true,
            ScrollPhase::Changed,
            VideoPoint::new(50.0, 60.0),
            FITTED,
            0.0,
        );
        assert_eq!(actions(&contacts), [Action::Down, Action::Move]);
    }

    /// A quarter turn moves the travel to the other axis. This is the whole difference between the
    /// two panels' calls, and the bug it fixes is a sideways device that scrolls the wrong way.
    #[test]
    fn a_rotated_frame_un_rotates_the_travel() {
        let mut gesture = ScrollGesture::new();
        gesture.accept(
            VideoSize::new(0.0, -10.0),
            true,
            ScrollPhase::Began,
            VideoPoint::new(100.0, 200.0),
            FITTED,
            90.0,
        );

        let finger = gesture.finger();
        assert_eq!(finger.map(|point| point.y), Some(200.0));
        assert_ne!(finger.map(|point| point.x), Some(100.0));
    }

    /// A panel with nothing drawn in it sends nothing: a message built from a zero surface is one
    /// the device discards anyway, and planting in it would strand a contact.
    #[test]
    fn a_panel_with_no_frame_in_it_sends_nothing() {
        let empty = VideoRect {
            origin: VideoPoint { x: 0.0, y: 0.0 },
            size: VideoSize {
                width: 0.0,
                height: 0.0,
            },
        };
        let mut gesture = ScrollGesture::new();

        assert!(
            gesture
                .accept(
                    VideoSize::new(0.0, -1.0),
                    true,
                    ScrollPhase::Began,
                    VideoPoint::new(0.0, 0.0),
                    empty,
                    0.0,
                )
                .is_empty()
        );
        assert_eq!(gesture.finger(), None);
    }
}
