//! The one responsive switch, and the ceiling that scales with the device behind it.
//!
//! Two decisions the app makes about the machine it is running on: whether to show the whole split
//! tree or one leaf at a time, and how many live video panes that machine can decode at once. They
//! sit together because they read the same three signals — the size class, the idiom, and a width.
//!
//! ## Two geometries, two thresholds, never collapsed into one
//!
//! The projection is measured against the OUTER WINDOW where one is known and against the DETAIL
//! column where one is not, and each is compared with its OWN threshold. Folding them into a single
//! `window.unwrap_or(detail) < 680` reads the macOS floor window's ~500pt detail against the window
//! threshold — a one-frame compact carousel every time the window reader has not fired yet — and
//! quietly moves the iPad detail fallback from 460 to 680.

/// The DETAIL-column width below which a regular layout collapses to compact.
///
/// At the 720pt macOS window floor the detail is about 500pt (720 minus the ~220 ideal sidebar), so
/// this sits a hair below that: the floor window resolves REGULAR, and only a truly phone-narrow
/// detail falls back.
const COMPACT_WIDTH_THRESHOLD: f64 = 460.0;

/// The OUTER-WINDOW width below which a regular layout collapses to compact.
///
/// Just below the 720pt macOS minimum-window floor, so that floor resolves regular and only a
/// genuinely sub-floor window — a future smaller-minimum platform, or a transient pre-constraint
/// frame — falls back.
const COMPACT_WINDOW_WIDTH_THRESHOLD: f64 = 680.0;

/// Whether to use the compact projection: one leaf at a time rather than the full split tree.
///
/// The size class is the PRIMARY signal and short-circuits everything else; iOS decides on it
/// alone, passing no window width. macOS has no size class, so it decides on geometry — and on the
/// WINDOW's, which is authoritative, rather than the detail column's, which a `GeometryReader` can
/// report half-laid-out mid-resize.
#[must_use]
pub fn is_compact(size_class_compact: bool, detail_width: f64, window_width: Option<f64>) -> bool {
    if size_class_compact {
        return true;
    }
    window_width.map_or(detail_width < COMPACT_WIDTH_THRESHOLD, |window| {
        window < COMPACT_WINDOW_WIDTH_THRESHOLD
    })
}

/// The device class the live-video ceiling is keyed on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DeviceClass {
    /// An iPhone, or any compact iOS projection.
    #[default]
    Phone,
    /// An iPad in a regular projection.
    Pad,
    /// A Mac.
    Mac,
}

/// A phone decodes one live video window at a time.
const PHONE_CAP: usize = 1;
/// An iPad in a regular projection, two.
const PAD_CAP: usize = 2;
/// A Mac, three.
const MAC_CAP: usize = 3;

/// The concurrent live-video ceiling for a device class.
///
/// A video pane's stack is two UDP sockets, a decompression session and a display link, so the safe
/// count follows the machine's decode and compositing headroom. The tiers are monotone on purpose.
#[must_use]
pub const fn cap(device_class: DeviceClass) -> usize {
    match device_class {
        DeviceClass::Phone => PHONE_CAP,
        DeviceClass::Pad => PAD_CAP,
        DeviceClass::Mac => MAC_CAP,
    }
}

/// The device class behind the platform signals.
///
/// A compact size class forces the phone tier even on a pad idiom — an iPad in slide-over has a
/// phone's worth of room and should carry a phone's worth of video. Anything unrecognised lands on
/// the phone tier, which is the conservative floor rather than an optimistic guess.
#[must_use]
pub const fn device_class(is_mac: bool, size_class_compact: bool, idiom_pad: bool) -> DeviceClass {
    if is_mac {
        return DeviceClass::Mac;
    }
    if idiom_pad && !size_class_compact {
        return DeviceClass::Pad;
    }
    DeviceClass::Phone
}

#[cfg(test)]
mod tests {
    use super::{
        COMPACT_WIDTH_THRESHOLD, COMPACT_WINDOW_WIDTH_THRESHOLD, DeviceClass, MAC_CAP, PAD_CAP, PHONE_CAP,
        cap, device_class, is_compact,
    };

    #[test]
    fn the_size_class_short_circuits_every_geometry() {
        assert!(is_compact(true, 10_000.0, Some(10_000.0)));
    }

    #[test]
    fn each_geometry_is_read_against_its_own_threshold() {
        // The macOS floor window: a ~500pt detail inside a 720pt window resolves REGULAR. Read
        // against the window threshold the detail would collapse, which is the bug this shape
        // avoids.
        assert!(!is_compact(false, 500.0, Some(720.0)));
        assert!(
            is_compact(false, 500.0, Some(600.0)),
            "a sub-floor window is compact"
        );
        // No window yet: the detail decides, against the smaller threshold.
        assert!(!is_compact(false, 500.0, None));
        assert!(is_compact(false, 400.0, None));
    }

    #[test]
    fn a_width_exactly_on_its_threshold_is_regular() {
        assert!(!is_compact(false, COMPACT_WIDTH_THRESHOLD, None));
        assert!(!is_compact(false, 0.0, Some(COMPACT_WINDOW_WIDTH_THRESHOLD)));
    }

    #[test]
    fn the_tiers_are_distinct_and_monotone() {
        const { assert!(PHONE_CAP <= PAD_CAP) }
        const { assert!(PAD_CAP <= MAC_CAP) }
        const { assert!(PHONE_CAP < MAC_CAP) }
        assert_eq!(cap(DeviceClass::Phone), PHONE_CAP);
        assert_eq!(cap(DeviceClass::Pad), PAD_CAP);
        assert_eq!(cap(DeviceClass::Mac), MAC_CAP);
    }

    #[test]
    fn a_pad_in_slide_over_carries_a_phones_worth_of_video() {
        assert_eq!(device_class(false, true, true), DeviceClass::Phone);
        assert_eq!(device_class(false, false, true), DeviceClass::Pad);
        assert_eq!(device_class(false, true, false), DeviceClass::Phone);
        assert_eq!(device_class(false, false, false), DeviceClass::Phone);
    }

    #[test]
    fn a_mac_outranks_both_other_signals() {
        assert_eq!(device_class(true, true, true), DeviceClass::Mac);
        assert_eq!(device_class(true, false, false), DeviceClass::Mac);
    }
}
