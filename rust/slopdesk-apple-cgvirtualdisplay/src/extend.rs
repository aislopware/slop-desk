//! The extend-and-pin transaction: making the new display a SEPARATE desktop, without moving the
//! user's real ones.
//!
//! macOS sometimes brings a new display up MIRRORED. A mirrored virtual display captures the
//! physical display's content, so the pane would show the user's own desktop back at them — a
//! failure that looks like a working capture. Stopping the mirror is
//! `CGConfigureDisplayMirrorOfDisplay` with a null master.
//!
//! The other half is why every real display is named in the same transaction. macOS resolves an
//! overlap between displays by REFLOWING them, and a reflow rearranges the user's physical monitor
//! layout for real. Pinning each one at the origin it already had, and putting the virtual display
//! past the rightmost edge where it cannot overlap anything, makes the reflow impossible rather
//! than unlikely — and doing it in ONE transaction means the resolver never sees an intermediate
//! state.
//!
//! Nothing in this module is private API. The decision it encodes — which display goes where — is
//! [`pins`], which is pure and tested; the transaction is the same list handed to `CoreGraphics`.

use objc2_core_graphics::{
    CGBeginDisplayConfiguration, CGCancelDisplayConfiguration, CGCompleteDisplayConfiguration,
    CGConfigureDisplayMirrorOfDisplay, CGConfigureDisplayOrigin, CGConfigureOption, CGDisplayConfigRef,
    CGDisplayIsInMirrorSet, CGError, kCGNullDirectDisplay,
};
use slopdesk_apple_cgdisplay::Display;
use slopdesk_video::geometry::VideoPoint;

/// Where one display is pinned for the duration of the transaction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pin {
    /// The `CGDirectDisplayID` being pinned.
    pub display: u32,
    /// Its global x, in points, rounded to the integer `CoreGraphics` takes.
    pub x: i32,
    /// Its global y, in points, rounded the same way.
    pub y: i32,
}

/// How the transaction ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExtendOutcome {
    /// Committed, and the virtual display is its own desktop.
    Extended,
    /// Committed, but the virtual display is STILL in a mirror set — the capture would show the
    /// wrong content, and the caller cannot otherwise tell.
    StillMirrored,
    /// Not committed. The display layout is whatever `WindowServer` chose on its own.
    Failed(CGError),
}

/// The full pin list for the transaction: every physical display at the origin it already had,
/// then the virtual display at `vd_origin`.
///
/// The virtual display comes LAST because its placement is the one that has to win: pinning it
/// before the real ones would let a later pin push it back into an overlap.
#[must_use]
pub fn pins(vd_id: u32, vd_origin: VideoPoint, physical: &[Display]) -> Vec<Pin> {
    let mut list: Vec<Pin> = physical
        .iter()
        .map(|display| {
            Pin {
                display: display.id,
                x: rounded(display.bounds.min_x()),
                y: rounded(display.bounds.min_y()),
            }
        })
        .collect();
    list.push(Pin {
        display: vd_id,
        x: rounded(vd_origin.x),
        y: rounded(vd_origin.y),
    });
    list
}

/// Rounds a global point coordinate to the `int32_t` `CGConfigureDisplayOrigin` takes, saturating
/// rather than wrapping.
///
/// A coordinate outside `i32` cannot come from a real display; saturating means a garbage value
/// pins something absurd instead of silently pinning its wrapped opposite.
fn rounded(value: f64) -> i32 {
    let rounded = value.round();
    if rounded <= f64::from(i32::MIN) {
        return i32::MIN;
    }
    if rounded >= f64::from(i32::MAX) {
        return i32::MAX;
    }
    // SAFETY note is not needed — this is safe code. The cast cannot truncate: both bounds were
    // just checked, and `round` cannot produce NaN from a finite input (a NaN input takes the
    // `>=` branch's `false` and the `<=` branch's `false`, landing on zero below).
    #[expect(
        clippy::cast_possible_truncation,
        reason = "both i32 bounds are checked immediately above"
    )]
    if rounded.is_nan() { 0 } else { rounded as i32 }
}

/// Stops any mirror on `vd_id`, pins every display at [`pins`]' answer, and commits.
///
/// `kCGConfigureForAppOnly` is DELIBERATE: it scopes the arrangement change to this process, so it
/// reverts when the daemon exits OR crashes — matching the virtual display's own lifetime — with no
/// restore path to get wrong. A session-scoped or permanent commit would leave the user's display
/// arrangement changed after a crash.
///
/// ⚠️ Must run on the main thread. `CGCompleteDisplayConfiguration` is a synchronous `WindowServer`
/// round-trip, the same one the registration uses.
#[must_use]
pub fn extend(vd_id: u32, vd_origin: VideoPoint, physical: &[Display]) -> ExtendOutcome {
    let mut config: CGDisplayConfigRef = core::ptr::null_mut();
    // SAFETY: framework rule. `CGBeginDisplayConfiguration` is documented to write the new
    // transaction handle through the pointer it is given; it is given the address of a fully
    // initialised local, so there is nothing uninitialised for it to find and nothing dereferenced
    // on this side.
    #[expect(
        unsafe_code,
        reason = "the transaction handle is reported through an out-pointer; the local it writes to is \
                  initialised"
    )]
    let begun = unsafe { CGBeginDisplayConfiguration(&raw mut config) };
    if begun != CGError::Success {
        return ExtendOutcome::Failed(begun);
    }
    if config.is_null() {
        return ExtendOutcome::Failed(CGError::Failure);
    }

    // A null master is how CoreGraphics spells "stop mirroring", which is what "extend" means.
    // SAFETY: framework rule. Every call below takes the handle `CGBeginDisplayConfiguration` just
    // produced and mutates only the pending transaction it names — none of them touches the live
    // display arrangement, which is what `CGCompleteDisplayConfiguration` is for.
    #[expect(
        unsafe_code,
        reason = "the display-configuration transaction is named by an opaque handle CoreGraphics owns"
    )]
    let failure = unsafe {
        let mut failure: Option<CGError> = None;
        let unmirrored = CGConfigureDisplayMirrorOfDisplay(config, vd_id, kCGNullDirectDisplay);
        if unmirrored != CGError::Success {
            failure = Some(unmirrored);
        }
        for pin in pins(vd_id, vd_origin, physical) {
            let pinned = CGConfigureDisplayOrigin(config, pin.display, pin.x, pin.y);
            if pinned != CGError::Success && failure.is_none() {
                failure = Some(pinned);
            }
        }
        failure
    };

    // SAFETY: framework rule. The commit consumes the handle; on the error path the handle is
    // handed to `CGCancelDisplayConfiguration` instead, which is the documented way to give it back
    // unspent. Neither is called twice.
    #[expect(
        unsafe_code,
        reason = "the display-configuration transaction is named by an opaque handle CoreGraphics owns"
    )]
    let committed = unsafe { CGCompleteDisplayConfiguration(config, CGConfigureOption::ForAppOnly) };
    if committed != CGError::Success {
        cancel(config);
        return ExtendOutcome::Failed(committed);
    }
    if let Some(error) = failure {
        return ExtendOutcome::Failed(error);
    }
    // SAFETY: framework rule. `CGDisplayIsInMirrorSet` is generated safe — an id in, a `bool` out.
    if CGDisplayIsInMirrorSet(vd_id) {
        return ExtendOutcome::StillMirrored;
    }
    ExtendOutcome::Extended
}

/// Gives a transaction handle back to `CoreGraphics` after a commit refused it.
///
/// Split out so the one `unsafe` call has one place; the commit path above is its only caller.
fn cancel(config: CGDisplayConfigRef) {
    // SAFETY: framework rule. The documented way to release a transaction that will not be
    // committed, called at most once per handle.
    #[expect(
        unsafe_code,
        reason = "the display-configuration transaction is named by an opaque handle CoreGraphics owns"
    )]
    unsafe {
        let _ = CGCancelDisplayConfiguration(config);
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_apple_cgdisplay::Display;
    use slopdesk_video::geometry::{VideoPoint, VideoRect};
    use slopdesk_video::virtual_display::origin_to_right;

    use super::{Pin, pins};

    /// A display at a known place, for the decision table.
    fn display(id: u32, x: f64, y: f64, width: f64, height: f64) -> Display {
        Display {
            id,
            bounds: VideoRect::xywh(x, y, width, height),
        }
    }

    /// The transaction pins EVERY physical display at the origin it already had, and the virtual
    /// display at the rule's answer, in that order.
    ///
    /// This is the whole decision the transaction encodes. Dropping a physical display from the
    /// list lets `WindowServer` reflow it; putting the virtual display anywhere but
    /// `origin_to_right`'s answer lets it overlap a real one, which reflows all of them.
    #[test]
    fn the_pin_list_holds_every_physical_origin_and_the_rule_s_virtual_one() {
        let physical = [
            display(1, 0.0, 0.0, 1920.0, 1080.0),
            display(2, 1920.0, -200.0, 2560.0, 1440.0),
        ];
        let bounds: Vec<VideoRect> = physical.iter().map(|one| one.bounds).collect();
        let origin = origin_to_right(&bounds);
        assert_eq!(pins(99, origin, &physical), vec![
            Pin {
                display: 1,
                x: 0,
                y: 0
            },
            Pin {
                display: 2,
                x: 1920,
                y: -200
            },
            // Past the rightmost edge, at y = 0 — `origin_to_right`'s answer, and LAST.
            Pin {
                display: 99,
                x: 4480,
                y: 0
            },
        ],);
    }

    /// The pin list must agree with `slopdesk-video`'s rule for ANY arrangement, including the
    /// single-display host and the empty one, because the rule is what the golden corpus pins.
    #[test]
    fn the_virtual_pin_never_diverges_from_the_rule() {
        for physical in [vec![], vec![display(1, 0.0, 0.0, 1440.0, 900.0)], vec![
            display(1, -2560.0, 0.0, 2560.0, 1440.0),
            display(2, 0.0, 0.0, 1512.0, 982.0),
        ]] {
            let bounds: Vec<VideoRect> = physical.iter().map(|one| one.bounds).collect();
            let origin: VideoPoint = origin_to_right(&bounds);
            let list = pins(99, origin, &physical);
            assert_eq!(list.len(), physical.len() + 1, "one pin per display, plus one");
            assert_eq!(
                list.last(),
                Some(&Pin {
                    display: 99,
                    x: rounded_for_test(origin.x),
                    y: rounded_for_test(origin.y),
                }),
            );
        }
    }

    /// The same rounding the pin list uses, spelled from the outside so the assertion above is a
    /// claim about the ANSWER rather than a second call to the function under test.
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the fixtures are display origins; none is near the i32 bounds"
    )]
    fn rounded_for_test(value: f64) -> i32 {
        value.round() as i32
    }

    /// A coordinate no real display could report saturates instead of wrapping. Wrapping would turn
    /// a far-right origin into a far-LEFT one, placing the virtual display on top of a real
    /// desktop.
    #[test]
    fn an_absurd_origin_saturates_rather_than_wrapping() {
        let list = pins(99, VideoPoint::new(f64::from(i32::MAX) * 4.0, f64::NAN), &[]);
        assert_eq!(
            list.last(),
            // A NaN coordinate pins at the origin, not at a wrapped one.
            Some(&Pin {
                display: 99,
                x: i32::MAX,
                y: 0
            }),
        );
    }
}
