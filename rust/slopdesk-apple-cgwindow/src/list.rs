//! The one decode of a `CGWindowListCopyWindowInfo` answer, and the three reads built on it.

use objc2_core_foundation::{CFArray, CFDictionary, CFNumber, CFRetained, CFString, CFType, Type};
use objc2_core_graphics::{
    CGWindowID, CGWindowListCopyWindowInfo, CGWindowListOption, kCGNullWindowID, kCGWindowAlpha,
    kCGWindowBounds, kCGWindowLayer, kCGWindowNumber, kCGWindowOwnerPID,
};
use slopdesk_video::geometry::VideoRect;
use slopdesk_video::window_list::{FrontmostCandidate, elected_owner_pid};

/// One window, as the `WindowServer` describes it. A record that cannot answer every field here is
/// never built — see the module note on what a missing field means.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowRecord {
    /// The `CGWindowID`. Per-boot and REUSABLE, so it identifies a window only together with
    /// [`Self::owner_pid`].
    pub window_id: u32,
    /// The owning process.
    pub owner_pid: i32,
    /// The CG window level: `0` is an ordinary app window, `101` a pop-up menu, `24` the menu bar.
    pub layer: i32,
    /// The frame in CG global points, top-left origin — the space `kCGWindowBounds`,
    /// `CGDisplayBounds` and the Accessibility API all share, and the one the client maps from.
    pub bounds: VideoRect,
}

/// One `CFDictionary` whose keys are `CFString`s and whose values are CF objects of assorted type —
/// the shape both a window record and its bounds sub-record have.
type Info = CFDictionary<CFString, CFType>;

/// The `kCGWindow*` key constants, read once per call rather than once per field.
struct Keys {
    number: &'static CFString,
    layer: &'static CFString,
    bounds: &'static CFString,
    alpha: &'static CFString,
    owner_pid: &'static CFString,
}

/// Reads the five `kCGWindow*` constants this crate needs.
fn keys() -> Keys {
    // SAFETY: framework rule. These are `extern` statics that CoreGraphics initialises when its
    // image loads, which is before any code that could call this has run — the CoreGraphics symbols
    // this crate links are what force the load. Rust cannot see that, so the read is `unsafe`; the
    // framework's contract is that they are non-null immutable `CFStringRef`s for the process's
    // whole life, which is exactly what `&'static CFString` claims.
    #[expect(
        unsafe_code,
        reason = "the framework's key constants are extern statics; objc2 cannot generate them safe"
    )]
    unsafe {
        Keys {
            number: kCGWindowNumber,
            layer: kCGWindowLayer,
            bounds: kCGWindowBounds,
            alpha: kCGWindowAlpha,
            owner_pid: kCGWindowOwnerPID,
        }
    }
}

/// Views a CF value as a `CFString`-keyed dictionary, having first CHECKED that it is a dictionary
/// at all.
fn as_info(value: &CFType) -> Option<CFRetained<Info>> {
    let dict = value.downcast_ref::<CFDictionary>()?;
    // SAFETY: framework rule, and half of it is already checked above — `downcast_ref` compared the
    // value against `CFDictionaryGetTypeID`, so this IS a dictionary. What remains is the element
    // types, which C's `CFDictionaryRef` cannot carry: CoreGraphics documents every window record
    // and every `CGRect` dictionary representation as `CFString`-keyed, and `CFType` is the
    // supertype of every value a CF dictionary built with the type callbacks can hold. Nothing is
    // dereferenced here — the typed view only changes which `get` overload applies, and every read
    // through it goes on to check its own type id via `downcast`.
    #[expect(
        unsafe_code,
        reason = "C's CFDictionaryRef carries no element type; the documentation is where it lives"
    )]
    Some(unsafe { CFRetained::cast_unchecked::<Info>(dict.retain()) })
}

/// The number stored at `key`, or `None` when the field is absent or is not a number.
fn number(info: &Info, key: &CFString) -> Option<CFRetained<CFNumber>> {
    info.get(key)?.downcast::<CFNumber>().ok()
}

/// The integer stored at `key`.
fn int(info: &Info, key: &CFString) -> Option<i64> {
    number(info, key)?.as_i64()
}

/// The double stored at `key`.
fn float(info: &Info, key: &CFString) -> Option<f64> {
    number(info, key)?.as_f64()
}

/// The `CGRect` dictionary representation stored at `key`. Its four keys are the literals
/// `CGRectCreateDictionaryRepresentation` writes, which is why they are built here rather than read
/// from a constant: CoreGraphics exports no symbol for them.
fn rect(info: &Info, key: &CFString) -> Option<VideoRect> {
    let value = info.get(key)?;
    let bounds = as_info(&value)?;
    Some(VideoRect::xywh(
        float(&bounds, &CFString::from_str("X"))?,
        float(&bounds, &CFString::from_str("Y"))?,
        float(&bounds, &CFString::from_str("Width"))?,
        float(&bounds, &CFString::from_str("Height"))?,
    ))
}

/// The whole record, or nothing.
fn decode(info: &Info, keys: &Keys) -> Option<WindowRecord> {
    Some(WindowRecord {
        window_id: u32::try_from(int(info, keys.number)?).ok()?,
        owner_pid: i32::try_from(int(info, keys.owner_pid)?).ok()?,
        layer: i32::try_from(int(info, keys.layer)?).ok()?,
        bounds: rect(info, keys.bounds)?,
    })
}

/// Asks the `WindowServer`, and names the element type of what it answers.
fn query(option: CGWindowListOption, relative_to: CGWindowID) -> Option<CFRetained<CFArray<Info>>> {
    let list = CGWindowListCopyWindowInfo(option, relative_to)?;
    // SAFETY: framework rule. `CGWindowListCopyWindowInfo` is documented to answer "an array of
    // `CFDictionaryRef` types", each keyed by the `kCGWindow*` `CFString` constants; C's
    // `CFArrayRef` has nowhere to say so, which is why the binding hands back an untyped array.
    // This states it once. Nothing is dereferenced — the typed view only decides which `get`
    // applies, and each element is checked against `CFDictionaryGetTypeID` before it is read.
    #[expect(
        unsafe_code,
        reason = "C's CFArrayRef carries no element type; the documentation is where it lives"
    )]
    Some(unsafe { CFRetained::cast_unchecked::<CFArray<Info>>(list) })
}

/// The frontmost app's pid, fresh from the `WindowServer`. `None` when the query fails or no
/// normal-level window is on screen at all — login/lock screen, bare desktop, display asleep.
///
/// Fresh is the whole point. `NSWorkspace.shared.frontmostApplication` is a per-process SNAPSHOT
/// that populates on first access and then updates only through `AppKit` run-loop machinery a
/// daemon never pumps, so in `slopdesk-videohostd` every later read answered the FIRST app forever.
/// This needs no run loop and is covered by the TCC the capture daemon already holds.
///
/// Decodes one record at a time and stops at the first elected pid: the swipe-nav kicker calls this
/// at 4 Hz for the daemon's whole life, and the frontmost window sits at the head of the
/// front-to-back list past a handful of overlay layers.
#[must_use]
pub fn frontmost_pid() -> Option<i32> {
    let keys = keys();
    let list = query(
        CGWindowListOption::OptionOnScreenOnly | CGWindowListOption::ExcludeDesktopElements,
        kCGNullWindowID,
    )?;
    list.iter().find_map(|info| {
        elected_owner_pid(FrontmostCandidate {
            layer: int(&info, keys.layer).and_then(|value| i32::try_from(value).ok()),
            owner_pid: int(&info, keys.owner_pid).and_then(|value| i32::try_from(value).ok()),
            alpha: float(&info, keys.alpha),
        })
    })
}

/// One window's current bounds. `None` when the window is gone, or — when `expected_pid` is given —
/// when its owner is not that process.
///
/// The owner check is not optional politeness: `CGWindowID`s are per-boot and REUSABLE, so a stale
/// id can name a window belonging to an unrelated app, and the parked-window restore would then
/// move it.
#[must_use]
pub fn bounds_of(window_id: u32, expected_pid: Option<i32>) -> Option<VideoRect> {
    let keys = keys();
    let list = query(CGWindowListOption::OptionIncludingWindow, window_id)?;
    let first = list.get(0)?;
    let record = decode(&first, &keys)?;
    match expected_pid {
        Some(pid) if record.owner_pid != pid => None,
        _ => Some(record.bounds),
    }
}

/// Every on-screen window strictly IN FRONT of `window_id`, front-to-back.
///
/// `CGWindowListCopyWindowInfo` orders on-screen windows front-to-back, so the answer is the prefix
/// of the list before the tracked window. A window id of `0` names nothing and answers empty.
#[must_use]
pub fn windows_in_front_of(window_id: u32) -> Vec<WindowRecord> {
    if window_id == kCGNullWindowID {
        return Vec::new();
    }
    let keys = keys();
    let Some(list) = query(CGWindowListOption::OptionOnScreenOnly, kCGNullWindowID) else {
        return Vec::new();
    };
    let mut in_front = Vec::new();
    for info in list.iter() {
        // Read the id BEFORE the rest: the tracked window ends the scan whether or not its own
        // record is complete, and a record with no id cannot be the tracked one.
        let number = int(&info, keys.number)
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(kCGNullWindowID);
        if number == window_id {
            break;
        }
        if let Some(record) = decode(&info, &keys) {
            in_front.push(record);
        }
    }
    in_front
}

#[cfg(test)]
#[expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
mod tests {
    use objc2_core_foundation::{CFDictionary, CFNumber, CFRetained, CFString, CFType};
    use slopdesk_video::geometry::VideoRect;

    use super::{Info, Keys, decode, keys, rect};

    /// Values go in as `&CFType`, so every builder below hands its retained object's supertype
    /// reference over — the same shape CoreFoundation itself stores.
    fn dict(pairs: &[(&CFString, &CFType)]) -> CFRetained<Info> {
        let names: Vec<&CFString> = pairs.iter().map(|(name, _)| *name).collect();
        let values: Vec<&CFType> = pairs.iter().map(|(_, value)| *value).collect();
        CFDictionary::from_slices(&names, &values)
    }

    /// A `CGRect` dictionary representation, built the way CoreGraphics writes one.
    fn bounds_dict(x: f64, y: f64, width: f64, height: f64) -> CFRetained<Info> {
        let names = ["X", "Y", "Width", "Height"].map(CFString::from_str);
        let numbers = [x, y, width, height].map(CFNumber::new_f64);
        let pairs: Vec<(&CFString, &CFType)> = names
            .iter()
            .zip(numbers.iter())
            .map(|(name, value)| (&**name, value.as_ref()))
            .collect();
        dict(&pairs)
    }

    /// A whole window record, with every field present.
    fn window_dict(keys: &Keys, id: i64, pid: i64, layer: i64) -> CFRetained<Info> {
        let bounds = bounds_dict(10.0, 20.5, 300.0, 400.25);
        let id = CFNumber::new_i64(id);
        let pid = CFNumber::new_i64(pid);
        let layer = CFNumber::new_i64(layer);
        let alpha = CFNumber::new_f64(1.0);
        dict(&[
            (keys.number, id.as_ref()),
            (keys.owner_pid, pid.as_ref()),
            (keys.layer, layer.as_ref()),
            (keys.alpha, alpha.as_ref()),
            (keys.bounds, bounds.as_ref()),
        ])
    }

    /// The `kCGWindow*` statics resolve, and resolve to the strings the documentation names. If the
    /// `extern` read in `keys` were wrong, this is where it would show as garbage rather than as a
    /// window that quietly never decodes.
    #[test]
    fn every_key_constant_reads_as_the_name_the_framework_documents() {
        let keys = keys();
        assert_eq!(keys.number.to_string(), "kCGWindowNumber");
        assert_eq!(keys.layer.to_string(), "kCGWindowLayer");
        assert_eq!(keys.bounds.to_string(), "kCGWindowBounds");
        assert_eq!(keys.alpha.to_string(), "kCGWindowAlpha");
        assert_eq!(keys.owner_pid.to_string(), "kCGWindowOwnerPID");
    }

    /// A complete record decodes to exactly what went in, bounds included.
    #[test]
    fn a_complete_record_decodes_field_for_field() {
        let keys = keys();
        let record = decode(&window_dict(&keys, 42, 9001, 0), &keys).expect("a complete record");
        assert_eq!(record.window_id, 42);
        assert_eq!(record.owner_pid, 9001);
        assert_eq!(record.layer, 0);
        assert_eq!(record.bounds, VideoRect::xywh(10.0, 20.5, 300.0, 400.25));
    }

    /// The rule the four Swift decodes each spelled differently: a record missing ANY field is
    /// dropped, never defaulted. Dropping one key at a time is the whole statement.
    #[test]
    fn a_record_missing_any_field_is_dropped_rather_than_defaulted() {
        let keys = keys();
        let bounds = bounds_dict(0.0, 0.0, 1.0, 1.0);
        let id = CFNumber::new_i64(7);
        let pid = CFNumber::new_i64(70);
        let layer = CFNumber::new_i64(0);
        let complete: [(&CFString, &CFType); 4] = [
            (keys.number, id.as_ref()),
            (keys.owner_pid, pid.as_ref()),
            (keys.layer, layer.as_ref()),
            (keys.bounds, bounds.as_ref()),
        ];
        assert!(decode(&dict(&complete), &keys).is_some());
        for dropped in 0..complete.len() {
            let partial: Vec<(&CFString, &CFType)> = complete
                .iter()
                .enumerate()
                .filter(|(index, _)| *index != dropped)
                .map(|(_, pair)| *pair)
                .collect();
            assert!(
                decode(&dict(&partial), &keys).is_none(),
                "a record without field {dropped} must not decode"
            );
        }
    }

    /// A field of the wrong CF type is a missing field, not a panic — `downcast` is what decides,
    /// so a string where a number belongs simply fails to elect.
    #[test]
    fn a_field_of_the_wrong_type_is_read_as_absent() {
        let keys = keys();
        let bounds = bounds_dict(0.0, 0.0, 1.0, 1.0);
        let text = CFString::from_str("not a number");
        let pid = CFNumber::new_i64(70);
        let layer = CFNumber::new_i64(0);
        let malformed = dict(&[
            (keys.number, text.as_ref()),
            (keys.owner_pid, pid.as_ref()),
            (keys.layer, layer.as_ref()),
            (keys.bounds, bounds.as_ref()),
        ]);
        assert!(decode(&malformed, &keys).is_none());
    }

    /// A bounds value that is not a dictionary at all also reads as absent — `as_info` checks the
    /// type id BEFORE it names the element types, which is what makes that cast sound.
    #[test]
    fn a_bounds_field_that_is_not_a_dictionary_is_read_as_absent() {
        let keys = keys();
        let number = CFNumber::new_i64(3);
        let malformed = dict(&[(keys.bounds, number.as_ref())]);
        assert!(rect(&malformed, keys.bounds).is_none());
    }

    /// The leak test §3 requires. Every object the decode touches is borrowed from the dictionary
    /// and retained only for as long as the read, so ten thousand decodes must leave the record's
    /// retain count exactly where it started — a decode that leaked one `CFRetained` per field
    /// would show here as a count climbing by forty thousand.
    #[test]
    fn ten_thousand_decodes_leave_the_record_owned_exactly_as_it_was() {
        let keys = keys();
        let record = window_dict(&keys, 1, 2, 0);
        let before = record.retain_count();
        for _ in 0..10_000 {
            assert!(decode(&record, &keys).is_some());
        }
        assert_eq!(record.retain_count(), before);
    }
}
