//! Which window a crashed daemon left stranded, and may therefore be moved back.
//!
//! A clean shutdown un-parks every window it borrowed. A SIGKILL does not, so the next launch reads
//! the sidecar the dead run wrote and puts the recorded windows back — but only the ones that are
//! still demonstrably lost. Between the crash and this launch the user may have moved a window, and
//! `WindowServer` re-homes anything left on a display that disappeared, so "the sidecar names it"
//! is not evidence: the window's CURRENT frame is.
//!
//! Two things count as evidence that nothing is wrong, and either one alone stops the move:
//!
//! - it already sits at the recorded origin, within the drift an AX read costs; or
//! - it touches a display that exists, so somebody can see it and reach it.
//!
//! An EMPTY display list is not the second one — it is the enumeration having failed, and this rule
//! fails soft there rather than treating "no displays" as "on no display". The cost of not moving a
//! stranded window is a window the user drags back once; the cost of moving a window that was fine
//! is yanking it out from under them, so every uncertainty resolves to "leave it".

use crate::geometry::VideoRect;

/// The drift between a recorded origin and the one read back that still counts as "already home".
///
/// AX and `CGWindowList` disagree in the sub-point digits, and a window nudged by a point was not
/// stranded by a crash. Two points is below anything a human would call a move.
pub const RESTORE_TOLERANCE: f64 = 2.0;

/// Whether launch hygiene should move `current` back to the origin the dead run recorded for it.
///
/// `current` is the window's live frame and `displays` the bounds of every display that exists now,
/// both in the caller's global top-left space and both standardised — `CGWindowBounds` and
/// `CGDisplayBounds` are, and this rule reads their extents as given rather than taking absolute
/// values of its own.
#[must_use]
pub fn should_restore(current: VideoRect, original_x: f64, original_y: f64, displays: &[VideoRect]) -> bool {
    let drifted_x = current.min_x() - original_x;
    let drifted_y = current.min_y() - original_y;
    if drifted_x.abs() <= RESTORE_TOLERANCE && drifted_y.abs() <= RESTORE_TOLERANCE {
        return false;
    }
    !displays.is_empty() && !displays.iter().any(|display| display.intersects(&current))
}

#[cfg(test)]
mod tests {
    use super::should_restore;
    use crate::geometry::VideoRect;

    const MAIN: VideoRect = VideoRect::xywh(0.0, 0.0, 2560.0, 1440.0);
    const SIDE: VideoRect = VideoRect::xywh(2560.0, 0.0, 1920.0, 1080.0);
    const ORIGINAL_X: f64 = 120.0;
    const ORIGINAL_Y: f64 = 80.0;

    #[test]
    fn a_window_still_sitting_where_the_dead_display_was_goes_home() {
        let stranded = VideoRect::xywh(4480.0, 0.0, 1440.0, 900.0);
        assert!(should_restore(stranded, ORIGINAL_X, ORIGINAL_Y, &[MAIN, SIDE]));
    }

    #[test]
    fn a_window_already_at_its_recorded_origin_is_left_alone() {
        let home = VideoRect::xywh(ORIGINAL_X, ORIGINAL_Y, 1024.0, 768.0);
        assert!(!should_restore(home, ORIGINAL_X, ORIGINAL_Y, &[MAIN]));
        let nudged = VideoRect::xywh(ORIGINAL_X + 1.0, ORIGINAL_Y - 1.0, 1024.0, 768.0);
        assert!(
            !should_restore(nudged, ORIGINAL_X, ORIGINAL_Y, &[MAIN]),
            "a point of AX drift is not a crash"
        );
    }

    #[test]
    fn a_window_anyone_can_still_see_is_left_alone() {
        let re_homed = VideoRect::xywh(300.0, 200.0, 1024.0, 768.0);
        assert!(!should_restore(re_homed, ORIGINAL_X, ORIGINAL_Y, &[MAIN, SIDE]));
        let half_off = VideoRect::xywh(2500.0, 100.0, 800.0, 600.0);
        assert!(
            !should_restore(half_off, ORIGINAL_X, ORIGINAL_Y, &[MAIN]),
            "overlapping one edge is reachable enough"
        );
    }

    #[test]
    fn an_empty_display_list_moves_nothing() {
        let stranded = VideoRect::xywh(9000.0, 0.0, 800.0, 600.0);
        assert!(
            !should_restore(stranded, ORIGINAL_X, ORIGINAL_Y, &[]),
            "an enumeration that failed is not a display that vanished"
        );
    }
}
