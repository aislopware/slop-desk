//! The responsive switch and the video ceiling, in C, and where a new pane starts.
//!
//! The rules are `slopdesk_workspace::responsive` and `slopdesk_workspace::workdir`; what is here
//! is the marshalling. Only the config string crosses through a buffer, and only in one direction.
//!
//! ## Nothing is copied to be chosen between
//!
//! The working-directory door answers with a NAME — the configured path, the active pane's cwd, or
//! neither — rather than with the text. Every caller already holds both strings; handing one back
//! would be a copy made only to be compared with the one it came from.

use core::ffi::c_uchar;

use slopdesk_workspace::responsive::{self, DeviceClass};
use slopdesk_workspace::workdir::{self, Kind, Policy, Source};

use crate::{borrow, deliver};

/// Whether to use the compact projection.
///
/// `window_width` is read only when `window_width_present` is set: the two geometries are compared
/// against DIFFERENT thresholds, so an absent window is not the same as a window of the detail's
/// width, and collapsing them would resolve compact for one frame on every macOS launch.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_is_compact(
    size_class_compact: bool,
    detail_width: f64,
    window_width: f64,
    window_width_present: bool,
) -> bool {
    responsive::is_compact(
        size_class_compact,
        detail_width,
        window_width_present.then_some(window_width),
    )
}

/// The device class behind the platform signals: `0` phone · `1` pad · `2` mac.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_video_device_class(
    is_mac: bool,
    size_class_compact: bool,
    idiom_pad: bool,
) -> u8 {
    match responsive::device_class(is_mac, size_class_compact, idiom_pad) {
        DeviceClass::Phone => 0,
        DeviceClass::Pad => 1,
        DeviceClass::Mac => 2,
    }
}

/// The concurrent live-video ceiling for a device class. An unrecognised class reads as the phone
/// tier, which is the conservative floor.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_video_cap(device_class: u8) -> usize {
    responsive::cap(match device_class {
        1 => DeviceClass::Pad,
        2 => DeviceClass::Mac,
        _ => DeviceClass::Phone,
    })
}

/// Parses a stored `working-directory` config string.
///
/// Returns the KIND — `0` inherit · `1` home · `2` a path — and writes the trimmed path through
/// `(out, cap)`, with `needed` set to its length. The kind is the return because the path's length
/// is legitimately zero for two of the three answers, which would otherwise be indistinguishable
/// from §4's "no answer". A short buffer writes nothing and still reports both.
///
/// # Safety
/// `(raw, len)` must be null or describe `len` live bytes; `(out, cap)` must be writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_workdir_parse(
    raw: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
    needed: *mut usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let text = String::from_utf8_lossy(unsafe { borrow(raw, len) });
    let policy = Policy::parse(&text);
    let path = match &policy {
        Policy::Path(path) => path.as_str(),
        Policy::Inherit | Policy::Home => "",
    };
    if let Some(needed) = unsafe { needed.as_mut() } {
        *needed = path.len();
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(path.as_bytes(), out, cap) };
    match policy.kind() {
        Kind::Inherit => 0,
        Kind::Home => 1,
        Kind::Path => 2,
    }
}

/// The stored config string for a keyword kind — the parse door's inverse.
///
/// `0` for [`Kind::Path`], whose config string is the path the caller already holds; the keywords
/// themselves never leave the crate that reads them, so the two directions cannot drift.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_workdir_keyword(kind: u8, out: *mut c_uchar, cap: usize) -> usize {
    let policy = match kind {
        0 => Policy::Inherit,
        1 => Policy::Home,
        _ => return 0,
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(policy.raw_config().as_bytes(), out, cap) }
}

/// Which string a new pane's cwd comes from.
///
/// `0` neither · `1` the configured path · `2` the active pane's cwd. `kind` is the parse door's
/// answer; an unrecognised one reads as home, which names no directory.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_workdir_source(kind: u8, active_cwd_known: bool) -> u8 {
    let kind = match kind {
        0 => Kind::Inherit,
        2 => Kind::Path,
        _ => Kind::Home,
    };
    match workdir::source(kind, active_cwd_known) {
        Source::None => 0,
        Source::ConfiguredPath => 1,
        Source::ActivePaneCwd => 2,
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        slopdesk_ws_is_compact, slopdesk_ws_video_cap, slopdesk_ws_video_device_class,
        slopdesk_ws_workdir_keyword, slopdesk_ws_workdir_parse, slopdesk_ws_workdir_source,
    };

    #[test]
    fn an_absent_window_is_not_a_window_of_the_detail_width() {
        // The macOS floor: a 500pt detail inside a 720pt window is REGULAR, but the same detail with
        // no window yet is measured against the smaller threshold and is regular too. Swap the
        // thresholds and the first of these flips.
        assert!(!slopdesk_ws_is_compact(false, 500.0, 720.0, true));
        assert!(!slopdesk_ws_is_compact(false, 500.0, 0.0, false));
        assert!(slopdesk_ws_is_compact(false, 500.0, 600.0, true));
        assert!(slopdesk_ws_is_compact(true, 5000.0, 5000.0, true));
    }

    #[test]
    fn the_case_indexes_are_the_ones_the_header_names() {
        assert_eq!(slopdesk_ws_video_device_class(true, true, true), 2);
        assert_eq!(slopdesk_ws_video_device_class(false, false, true), 1);
        assert_eq!(slopdesk_ws_video_device_class(false, true, true), 0);
        assert_eq!(slopdesk_ws_video_cap(0), 1);
        assert_eq!(slopdesk_ws_video_cap(1), 2);
        assert_eq!(slopdesk_ws_video_cap(2), 3);
        assert_eq!(slopdesk_ws_video_cap(200), 1, "an unknown class is the floor");
    }

    #[test]
    fn the_parse_answers_its_kind_even_where_the_path_is_empty() {
        let mut out = [0_u8; 64];
        let mut needed = 0;
        // SAFETY: two live buffers, borrowed for the call.
        let parse = |raw: &str, out: &mut [u8], needed: &mut usize| unsafe {
            slopdesk_ws_workdir_parse(raw.as_ptr(), raw.len(), out.as_mut_ptr(), out.len(), needed)
        };
        assert_eq!(parse("inherit", &mut out, &mut needed), 0);
        assert_eq!(needed, 0, "inherit names no path, which is not a refusal");
        assert_eq!(parse("  \n", &mut out, &mut needed), 1, "blank is home");
        assert_eq!(parse("  /Users/me \n", &mut out, &mut needed), 2);
        assert_eq!(needed, "/Users/me".len());
        assert_eq!(out.get(..needed), Some(b"/Users/me".as_slice()), "trimmed");
    }

    #[test]
    fn a_short_buffer_reports_the_size_and_writes_nothing() {
        let raw = "/Users/me";
        let mut out = [b'x'; 2];
        let mut needed = 0;
        // SAFETY: two live buffers, borrowed for the call.
        let kind = unsafe {
            slopdesk_ws_workdir_parse(
                raw.as_ptr(),
                raw.len(),
                out.as_mut_ptr(),
                out.len(),
                &raw mut needed,
            )
        };
        assert_eq!(kind, 2, "the kind is an answer even when the text did not fit");
        assert_eq!(needed, raw.len());
        assert_eq!(out, [b'x'; 2]);
    }

    #[test]
    fn a_keyword_round_trips_through_the_two_doors() {
        let mut out = [0_u8; 16];
        let mut needed = 0;
        for kind in [0_u8, 1] {
            // SAFETY: one live buffer, borrowed for the call.
            let written = unsafe { slopdesk_ws_workdir_keyword(kind, out.as_mut_ptr(), out.len()) };
            // SAFETY: the keyword just written, and two live buffers.
            let parsed = unsafe {
                slopdesk_ws_workdir_parse(out.as_ptr(), written, core::ptr::null_mut(), 0, &raw mut needed)
            };
            assert_eq!(parsed, kind, "the keyword parses back to the kind it names");
        }
        // SAFETY: one live buffer, borrowed for the call.
        let path = unsafe { slopdesk_ws_workdir_keyword(2, out.as_mut_ptr(), out.len()) };
        assert_eq!(path, 0, "a path's config string is the caller's own");
    }

    #[test]
    fn the_source_is_named_rather_than_copied() {
        assert_eq!(
            slopdesk_ws_workdir_source(0, true),
            2,
            "inherit takes the active cwd"
        );
        assert_eq!(slopdesk_ws_workdir_source(0, false), 0);
        assert_eq!(slopdesk_ws_workdir_source(1, true), 0, "home names no directory");
        assert_eq!(slopdesk_ws_workdir_source(2, false), 1);
        assert_eq!(
            slopdesk_ws_workdir_source(200, true),
            0,
            "an unknown kind is home"
        );
    }
}
