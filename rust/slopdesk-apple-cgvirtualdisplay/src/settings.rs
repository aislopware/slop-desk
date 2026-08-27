//! The `CGVirtualDisplaySettings` — the modes `WindowServer` is told about AFTER the display
//! exists.
//!
//! The `HiDPI` rule these two fields encode: a `CGVirtualDisplayMode`'s width and height are
//! POINTS, the descriptor's `maxPixelsWide/High` are `points × scale`, and `hiDPI = 1` is what
//! makes the OS back the point grid with those pixels. All three together are a true Retina
//! display; any one of them alone is a soft upscale, which is the whole reason this area is used at
//! all.
//!
//! Which rates to advertise is `slopdesk-video`'s `refresh_rates`, and the answer is not "the
//! encode rate": the capture has to be able to oversample without beating against the commit.
//! Building one is inert — no IPC leaves the process until `applySettings:`.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use objc2::msg_send;
use objc2::rc::{Allocated, Retained};
use objc2::runtime::AnyObject;
use objc2_foundation::NSArray;
use slopdesk_video::virtual_display::{Geometry, refresh_rates};

use crate::classes::Classes;

/// `hiDPI = 1` asks for a scaled backing; `0` asks for none.
const HIDPI_ON: u32 = 1;
/// The `hiDPI` value for a 1× display.
const HIDPI_OFF: u32 = 0;
/// The scale at which a backing store stops being 1:1 with the point grid.
const RETINA_SCALE: i32 = 2;

/// Builds the settings object for `geometry`, advertising the modes that cover `fps`.
pub(crate) fn build(classes: Classes, geometry: &Geometry, fps: i32) -> Retained<AnyObject> {
    let hidpi = if geometry.scale() >= RETINA_SCALE {
        HIDPI_ON
    } else {
        HIDPI_OFF
    };
    // POINTS, not pixels. `unsigned int`, NOT `NSUInteger`: the class-dump header this port
    // replaced declared these two as `NSUInteger`, and the RUNNING class disagrees — its method
    // signature says `I`. `objc2` verifies the encoding on every send in debug, which is how the
    // divergence surfaced at all; the old Objective-C shim would have passed 64 bits into a 32-bit
    // parameter in silence.
    let width = u32::try_from(geometry.point_width()).unwrap_or(0);
    let height = u32::try_from(geometry.point_height()).unwrap_or(0);
    let modes: Vec<Retained<AnyObject>> = refresh_rates(fps)
        .into_iter()
        .map(|rate| mode(classes, width, height, rate))
        .collect();
    let advertised = NSArray::from_retained_slice(&modes);

    // SAFETY: Objective-C runtime rule. `classes.settings` is `CGVirtualDisplaySettings` as the
    // runtime resolved it, `+new` is `NSObject`'s and the class declares `-init`, and the two
    // selectors are its declared property setters with their declared argument types —
    // `unsigned int` for `hiDPI`, `NSArray *` for `modes`.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    let settings: Retained<AnyObject> = unsafe { msg_send![classes.settings, new] };
    // SAFETY: as above.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    unsafe {
        let _: () = msg_send![&*settings, setHiDPI: hidpi];
        let _: () = msg_send![&*settings, setModes: &*advertised];
    }
    settings
}

/// One advertised mode: a POINT grid at one refresh rate.
fn mode(classes: Classes, width: u32, height: u32, refresh_rate: f64) -> Retained<AnyObject> {
    // SAFETY: Objective-C runtime rule. `+alloc` is `NSObject`'s, and
    // `-initWithWidth:height:refreshRate:` is `CGVirtualDisplayMode`'s only initialiser, whose
    // RUNTIME signature is `(unsigned int, unsigned int, double)` — which is what is passed, by
    // value, in that order. The
    // `init` family transfers ownership, which is what `Retained` here states.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    unsafe {
        let allocated: Allocated<AnyObject> = msg_send![classes.mode, alloc];
        msg_send![allocated, initWithWidth: width, height: height, refreshRate: refresh_rate]
    }
}

#[cfg(test)]
mod tests {
    use objc2::msg_send;
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2_foundation::NSArray;
    use slopdesk_video::virtual_display::{Geometry, refresh_rates};

    use super::{HIDPI_OFF, HIDPI_ON, build};
    use crate::classes::{classes, skipped};

    /// Reads the `modes` array back off a settings object.
    fn modes_of(settings: &AnyObject) -> Retained<NSArray<AnyObject>> {
        // SAFETY: Objective-C runtime rule. `-modes` is the declared getter of a `retain` property
        // holding an `NSArray *`; `Retained` states the retain `msg_send!` performs before use.
        #[expect(
            unsafe_code,
            reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
        )]
        unsafe {
            msg_send![settings, modes]
        }
    }

    /// Reads the `hiDPI` flag back off a settings object.
    fn hidpi_of(settings: &AnyObject) -> u32 {
        // SAFETY: Objective-C runtime rule. `-hiDPI` is the declared getter of an `unsigned int`
        // property, taking no arguments.
        #[expect(
            unsafe_code,
            reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
        )]
        unsafe {
            msg_send![settings, hiDPI]
        }
    }

    /// The settings object must carry EXACTLY the rates `slopdesk-video` decided, and the `HiDPI`
    /// flag the scale implies. A settings object built with a mode list of its own, or with
    /// `hiDPI` off on a 2× geometry, produces a display that looks right in the log and
    /// captures soft.
    #[test]
    fn the_modes_and_the_hidpi_flag_come_from_the_geometry() {
        let Some(classes) = classes() else {
            skipped("the_modes_and_the_hidpi_flag_come_from_the_geometry");
            return;
        };
        let retina = Geometry::new(1920, 1080, 2, 8192);
        let settings = build(classes, &retina, 60);
        assert_eq!(hidpi_of(&settings), HIDPI_ON, "a 2× geometry is HiDPI");
        assert_eq!(
            modes_of(&settings).len(),
            refresh_rates(60).len(),
            "one mode per rate the rule answered, and no more",
        );

        let plain = Geometry::new(1920, 1080, 1, 8192);
        let settings = build(classes, &plain, 60);
        assert_eq!(hidpi_of(&settings), HIDPI_OFF, "a 1× geometry is not HiDPI");
    }
}
