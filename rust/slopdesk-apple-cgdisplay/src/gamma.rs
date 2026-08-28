//! The one EFFECT in this area: a display's gamma transfer table.
//!
//! Zeroing that table is the driver-free way to darken a Mac's own panel while a capture of it
//! keeps streaming — the encoder reads the framebuffer, which the table never touches, so the
//! remote client still sees the desktop the bystander no longer can. Whether a session WANTS that
//! is `slopdesk-video`'s rule; this file only turns the wish into the framework call.

use objc2_core_graphics::{
    CGDirectDisplayID, CGDisplayRestoreColorSyncSettings, CGError, CGGammaValue, CGGetDisplayTransferByTable,
    CGSetDisplayTransferByFormula, CGSetDisplayTransferByTable,
};

/// `kCGNullDirectDisplay`, refused by both doors before the framework ever sees it.
///
/// Measured 2026-08-28 on Darwin 25.5: this is NOT an inert sentinel. Passing it to
/// `CGSetDisplayTransferByTable` answers `kCGErrorSuccess` and blacks the MAIN display, which is
/// exactly the accident a caller holding "no display yet" in a `u32` would have. Refusing it here
/// is translating the framework's own constant, the same way [`crate::bounds_of`] documents the
/// zero rect it answers for an id that names nothing.
const NO_DISPLAY: CGDirectDisplayID = 0;

/// How many samples a read-back asks for. 1024 is the capacity every panel on this machine
/// reports, and a display with a bigger table is still judged on its first 1024 entries — a ramp
/// that is zero across all of those is dark whatever the tail says.
const READBACK_SAMPLES: usize = 1024;

/// Drives a display's gamma ramp to zero: every input level maps to no light.
///
/// Answers whether the framework took it. `false` for an id that names no display, for
/// `kCGNullDirectDisplay`, and for any `CGError` — a caller that reads it as "not blanked" is
/// right, because the screen is untouched in all three cases.
///
/// The inverse is [`restore_gamma`], and it MUST be called: measured 2026-08-28 on Darwin 25.5, a
/// zeroed table survives the exit of the process that set it. There is no operating system
/// underneath this cleaning up after a crash.
#[must_use]
pub fn set_gamma_black(display: CGDirectDisplayID) -> bool {
    if display == NO_DISPLAY {
        return false;
    }
    let zero: CGGammaValue = 0.0;
    let table = &raw const zero;
    let error = {
        // SAFETY: framework rule. `CGSetDisplayTransferByTable`'s header states that each table
        // holds `tableSize` entries in the interval [0, 1], that the tables are interpolated as
        // needed, and that THE SAME TABLE MAY BE PASSED for the red, green and blue channels.
        // `table` names one fully initialised `CGGammaValue` local that outlives the call and
        // `tableSize` is exactly 1, so reading "`tableSize` entries from each table" cannot leave
        // it, and aliasing all three parameters onto it is the header's own allowance rather than
        // something inferred. Every parameter is `const`: nothing is written back on this side.
        #[expect(
            unsafe_code,
            reason = "the gamma setter takes three table pointers; objc2 cannot generate it safe"
        )]
        unsafe {
            CGSetDisplayTransferByTable(display, 1, table, table, table)
        }
    };
    error == CGError::Success
}

/// Gives a display its ramp back, undoing [`set_gamma_black`].
///
/// ## Two steps, and why the second one exists
///
/// 1. `CGDisplayRestoreColorSyncSettings` — the documented inverse, which restores every system
///    display's table from the user's `ColorSync` profile. It is a global call, so the id is not
///    its argument; it is made first because when it works it restores the CALIBRATED ramp,
///    including a display profile and Night Shift, which step 2 cannot reconstruct.
/// 2. A linear identity ramp for THIS display, but only if the table read back is still fully dark.
///    Measured 2026-08-28 on Darwin 25.5: step 1 did not undo a table set through
///    `CGSetDisplayTransferByTable` — probed twice, with an all-zero table and with a half-scale
///    formula, and the override survived the call both times. Without step 2 this door would black
///    a host's screen permanently, which is worse than the privacy feature is worth.
///
/// The read-back is what keeps step 2 from being a downgrade: on a macOS where step 1 DOES work,
/// the table is no longer dark by the time it is checked and the calibrated ramp the restore just
/// installed is left alone. A read-back that fails says nothing about the display, and writing
/// identity on the strength of an unanswered question would clobber a caller's profile for no
/// evidence — so that case writes nothing.
pub fn restore_gamma(display: CGDirectDisplayID) {
    // Generated safe: no arguments, no return value.
    CGDisplayRestoreColorSyncSettings();
    if display == NO_DISPLAY || !is_dark(display) {
        return;
    }
    // Generated safe: ten scalars in, a `CGError` out. Min 0, max 1, gamma 1 on each channel is
    // the identity ramp — the nominal state a display with no profile loaded already has.
    let _forced = CGSetDisplayTransferByFormula(display, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0);
}

/// Whether every channel of this display's ramp reads back as no light at all — the exact
/// fingerprint [`set_gamma_black`] leaves, and nothing a calibrated profile ever produces.
///
/// `false` whenever the answer is not certain: a failed read, or a display that reported no
/// samples. The caller acts on `true` alone, so an uncertain answer has to be the harmless one.
fn is_dark(display: CGDirectDisplayID) -> bool {
    let mut red: [CGGammaValue; READBACK_SAMPLES] = [0.0; READBACK_SAMPLES];
    let mut green: [CGGammaValue; READBACK_SAMPLES] = [0.0; READBACK_SAMPLES];
    let mut blue: [CGGammaValue; READBACK_SAMPLES] = [0.0; READBACK_SAMPLES];
    let capacity = u32::try_from(red.len()).unwrap_or(0);
    let mut reported: u32 = 0;
    let error = {
        // SAFETY: framework rule. `CGGetDisplayTransferByTable`'s header states that it writes no
        // more than `capacity` entries into each table and reports through `sampleCount` how many
        // it actually wrote. All three arrays are FULLY INITIALISED locals of exactly
        // `READBACK_SAMPLES` elements that outlive the call, `capacity` is exactly that length, and
        // `sampleCount` points at an initialised local — so the framework's own bound is satisfied
        // by construction and nothing here is uninitialised on either side of the call.
        #[expect(
            unsafe_code,
            reason = "the gamma getter reports through out-pointers; objc2 cannot generate it safe"
        )]
        unsafe {
            CGGetDisplayTransferByTable(
                display,
                capacity,
                red.as_mut_ptr(),
                green.as_mut_ptr(),
                blue.as_mut_ptr(),
                &raw mut reported,
            )
        }
    };
    // Clamped, not trusted, for the same reason the enumerators clamp their counts: a framework
    // that over-reported would otherwise have this reading past what it actually wrote.
    let samples = usize::try_from(reported).unwrap_or(0).min(red.len());
    if error != CGError::Success || samples == 0 {
        return false;
    }
    [&red, &green, &blue]
        .into_iter()
        .all(|channel| channel.iter().take(samples).all(|&sample| sample <= 0.0))
}

#[cfg(test)]
mod tests {
    use objc2_core_graphics::CGDirectDisplayID;

    use super::{NO_DISPLAY, restore_gamma, set_gamma_black};

    /// ⚠️ EVERY display id in this file is `u32::MAX`, and every new test here must use it too.
    ///
    /// Measured 2026-08-28 on Darwin 25.5: `CGSetDisplayTransferByTable` answers
    /// `kCGErrorIllegalArgument` (1001) for this id and touches nothing, where a small integer is a
    /// REAL display on somebody's Mac — a test that reached for one would black the screen of
    /// whoever ran the suite, and the gamma override outlives the test process that set it.
    const NO_SUCH_DISPLAY: CGDirectDisplayID = u32::MAX;

    /// An id that names no display is refused, so a caller that lost track of its target darkens
    /// nothing rather than something.
    #[test]
    fn an_id_that_names_no_display_is_refused() {
        assert!(!set_gamma_black(NO_SUCH_DISPLAY));
    }

    /// `kCGNullDirectDisplay` never reaches the framework. This is the one the measurement caught:
    /// CoreGraphics accepts it and blacks the main display, so "no display" has to be answered
    /// here or the safest-looking id in the type becomes the most destructive one.
    #[test]
    fn the_null_display_is_refused_before_the_framework_sees_it() {
        assert!(!set_gamma_black(NO_DISPLAY));
    }

    /// The family's handle-leak test, in this file's terms. Nothing here holds a CoreFoundation
    /// object, so the leak this door could have is a window-server one: a setter that opened
    /// something per call would, ten thousand refusals in, start answering differently. Only the
    /// REFUSED path is looped — a loop that actually set a table would be looping over the host's
    /// own screen.
    #[test]
    fn ten_thousand_refused_blanks_answer_the_same_thing_as_the_first() {
        for _ in 0..10_000 {
            assert!(!set_gamma_black(NO_SUCH_DISPLAY));
        }
    }

    /// Restoring a display that does not exist is a no-op that answers nothing and does not
    /// panic — the arm a teardown takes when its session never engaged a blank at all.
    ///
    /// Bounded to a handful rather than ten thousand on purpose: step 1 of [`restore_gamma`] is
    /// GLOBAL, and on a machine where it works, hammering it would re-clear the runner's own
    /// Night Shift ten thousand times to prove nothing this loop is about.
    #[test]
    fn restoring_a_display_that_does_not_exist_changes_nothing() {
        for _ in 0..8 {
            restore_gamma(NO_SUCH_DISPLAY);
        }
    }

    /// The null display short-circuits the restore's second step too, so the identity ramp cannot
    /// be forced onto the main display through the same id that blacks it.
    #[test]
    fn restoring_the_null_display_never_reaches_the_identity_ramp() {
        restore_gamma(NO_DISPLAY);
    }
}
