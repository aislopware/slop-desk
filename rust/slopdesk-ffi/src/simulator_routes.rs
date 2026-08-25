//! Every URL the simulator panel builds, in C.
//!
//! The rules are `slopdesk_devicepanel::sim_routes`'s. ONE door rather than a dozen, because the
//! routes differ only in which of a fixed set of parts they use: a verb, a device, a value, a
//! nonce, two capture flags. Twelve entry points would be twelve places for a caller to reach the
//! wrong one; a kind plus a record is a table lookup the caller cannot mis-spell.
//!
//! Zero back is a REFUSAL, not an empty answer: a URL is never empty, and a degenerate endpoint —
//! no host, or port zero — is the phase machine's "not ready" rather than a URL that would fail
//! later and further from the cause.

use core::ffi::c_uchar;

use slopdesk_devicepanel::sim_routes;

use crate::{borrow, deliver};

/// `GET` the device set.
pub const SLOPDESK_SIM_ROUTE_DEVICE_LIST: u32 = 0;
/// `POST` to start the device.
pub const SLOPDESK_SIM_ROUTE_BOOT: u32 = 1;
/// `POST` to stop the device.
pub const SLOPDESK_SIM_ROUTE_SHUTDOWN: u32 = 2;
/// `GET` the device's physical body, in viewport-relative percentages.
pub const SLOPDESK_SIM_ROUTE_DEFINITION: u32 = 3;
/// `POST` to override or clear the status bar.
pub const SLOPDESK_SIM_ROUTE_STATUS_BAR: u32 = 4;
/// `POST` to pin the simulated GPS position; `DELETE` to restore live values.
pub const SLOPDESK_SIM_ROUTE_LOCATION: u32 = 5;
/// `POST` to set the interface orientation — the value rides `arg`.
pub const SLOPDESK_SIM_ROUTE_ORIENTATION: u32 = 6;
/// `GET` one JPEG of the current screen — the nonce and both capture flags apply.
pub const SLOPDESK_SIM_ROUTE_SCREENSHOT: u32 = 7;
/// The console websocket — the level rides `arg`.
pub const SLOPDESK_SIM_ROUTE_LOGS: u32 = 8;
/// `POST` raw file bytes — the name rides `arg`.
pub const SLOPDESK_SIM_ROUTE_FILES: u32 = 9;
/// The frame + input websocket.
pub const SLOPDESK_SIM_ROUTE_STREAM: u32 = 10;
/// Resolve a reference the SERVER handed back — the reference rides `arg`.
pub const SLOPDESK_SIM_ROUTE_RESOLVE: u32 = 11;

/// Which route to build, and every part any of them needs.
///
/// A record rather than a dozen arguments because most routes ignore most fields: a caller building
/// a boot URL sets three of these, and the rest are read by nobody. Fields it does not use are not
/// its to get right.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SlopDeskSimRoute {
    /// One of the `SLOPDESK_SIM_ROUTE_*` codes above.
    pub kind: u32,
    /// The server's mesh address. Empty is a refusal.
    pub host: *const c_uchar,
    /// `host`'s length in bytes.
    pub host_len: usize,
    /// The server's port. Zero is a refusal.
    pub port: u16,
    /// The device this route is about, escaped as a path component on the way in. Ignored by the
    /// device-list and resolve routes.
    pub udid: *const c_uchar,
    /// `udid`'s length in bytes.
    pub udid_len: usize,
    /// The one free value this route carries: an orientation, a log level, a file name, or a
    /// reference. Ignored by every route that has no such part.
    pub arg: *const c_uchar,
    /// `arg`'s length in bytes.
    pub arg_len: usize,
    /// The screenshot cache-buster, ignored by every other route.
    pub nonce: u64,
    /// The screenshot's integer downscale divisor. `1` — the default — is omitted from the query.
    pub scale: i32,
    /// The screenshot's JPEG quality, `0`–`1`. Omitted from the query unless `has_quality`.
    pub quality: f64,
    /// Whether `quality` was set at all.
    pub has_quality: bool,
}

/// Build one URL. Answers the bytes NEEDED, or `0` for a route that cannot be built.
///
/// # Safety
/// Each of `host`, `udid` and `arg` must be readable for its stated length for the duration of the
/// call, and `out` writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading caller-owned buffers is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_route(
    route: *const SlopDeskSimRoute,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if route.is_null() {
        return 0;
    }
    // SAFETY: `route` was just checked non-null and is a live record by the caller's obligation.
    let route = unsafe { route.read() };
    // SAFETY: each span is readable for its stated length by the caller's obligation, and each is
    // borrowed only for the duration of this call.
    let host = String::from_utf8_lossy(unsafe { borrow(route.host, route.host_len) });
    // SAFETY: as above.
    let udid = String::from_utf8_lossy(unsafe { borrow(route.udid, route.udid_len) });
    // SAFETY: as above.
    let arg = String::from_utf8_lossy(unsafe { borrow(route.arg, route.arg_len) });

    let port = route.port;
    let url = match route.kind {
        SLOPDESK_SIM_ROUTE_DEVICE_LIST => sim_routes::device_list(&host, port),
        SLOPDESK_SIM_ROUTE_BOOT => sim_routes::boot(&host, port, &udid),
        SLOPDESK_SIM_ROUTE_SHUTDOWN => sim_routes::shutdown(&host, port, &udid),
        SLOPDESK_SIM_ROUTE_DEFINITION => sim_routes::definition(&host, port, &udid),
        SLOPDESK_SIM_ROUTE_STATUS_BAR => sim_routes::status_bar(&host, port, &udid),
        SLOPDESK_SIM_ROUTE_LOCATION => sim_routes::location(&host, port, &udid),
        SLOPDESK_SIM_ROUTE_ORIENTATION => sim_routes::orientation(&host, port, &udid, &arg),
        SLOPDESK_SIM_ROUTE_SCREENSHOT => {
            sim_routes::screenshot(
                &host,
                port,
                &udid,
                route.nonce,
                route.scale,
                route.has_quality.then_some(route.quality),
            )
        },
        SLOPDESK_SIM_ROUTE_LOGS => sim_routes::logs(&host, port, &udid, &arg),
        SLOPDESK_SIM_ROUTE_FILES => sim_routes::files(&host, port, &udid, &arg),
        SLOPDESK_SIM_ROUTE_STREAM => sim_routes::stream(&host, port, &udid),
        SLOPDESK_SIM_ROUTE_RESOLVE => sim_routes::resolve(&arg, &host, port),
        // A code this build does not know builds NOTHING. The alternative — falling through to some
        // route — is a request sent to an endpoint the caller did not ask for.
        _ => None,
    };
    let Some(url) = url else { return 0 };
    // SAFETY: `url` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(url.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::{
        SLOPDESK_SIM_ROUTE_BOOT, SLOPDESK_SIM_ROUTE_DEVICE_LIST, SLOPDESK_SIM_ROUTE_RESOLVE,
        SLOPDESK_SIM_ROUTE_SCREENSHOT, SLOPDESK_SIM_ROUTE_STREAM, SlopDeskSimRoute, slopdesk_sim_route,
    };

    /// The parts a capture route needs beyond the four every route takes.
    #[derive(Clone, Copy, Default)]
    struct Capture {
        nonce: u64,
        scale: i32,
        quality: Option<f64>,
    }

    fn build(kind: u32, host: &str, port: u16, udid: &str, arg: &str) -> Option<String> {
        build_capture(kind, host, port, udid, arg, Capture {
            scale: 1,
            ..Capture::default()
        })
    }

    fn build_capture(
        kind: u32,
        host: &str,
        port: u16,
        udid: &str,
        arg: &str,
        capture: Capture,
    ) -> Option<String> {
        let record = SlopDeskSimRoute {
            kind,
            host: host.as_ptr(),
            host_len: host.len(),
            port,
            udid: udid.as_ptr(),
            udid_len: udid.len(),
            arg: arg.as_ptr(),
            arg_len: arg.len(),
            nonce: capture.nonce,
            scale: capture.scale,
            quality: capture.quality.unwrap_or_default(),
            has_quality: capture.quality.is_some(),
        };
        let mut out = [0_u8; 256];
        // SAFETY: every span in `record` is a live local for the call, as is `out`.
        let written = unsafe { slopdesk_sim_route(&raw const record, out.as_mut_ptr(), out.len()) };
        (written > 0).then(|| String::from_utf8_lossy(&out[..written]).into_owned())
    }

    /// Each code builds ITS route. A kind that fell through to a neighbour would send a request to
    /// an endpoint the caller never asked for, which is the failure this table exists to prevent.
    #[test]
    fn each_code_builds_its_own_route() {
        assert_eq!(
            build(SLOPDESK_SIM_ROUTE_DEVICE_LIST, "h", 9, "", "").as_deref(),
            Some("http://h:9/simulators.json")
        );
        assert_eq!(
            build(SLOPDESK_SIM_ROUTE_BOOT, "h", 9, "U-1", "").as_deref(),
            Some("http://h:9/simulators/U-1/boot")
        );
        assert_eq!(
            build(SLOPDESK_SIM_ROUTE_STREAM, "h", 9, "U-1", "").as_deref(),
            Some("ws://h:9/simulators/U-1/stream?format=avcc&version=v2")
        );
    }

    /// The free value reaches the route that carries one, and the reference route reads it as the
    /// whole reference rather than as a device.
    #[test]
    fn the_free_value_reaches_the_route_that_uses_it() {
        assert_eq!(
            build(SLOPDESK_SIM_ROUTE_RESOLVE, "h", 9, "", "bezel.png?buttons=false").as_deref(),
            Some("http://h:9/bezel.png?buttons=false")
        );
    }

    /// Both capture flags cross as their own fields, and both stay out of the query at their
    /// defaults, so a full-resolution capture builds the URL it always did.
    #[test]
    fn the_capture_flags_cross_only_when_set() {
        assert_eq!(
            build_capture(SLOPDESK_SIM_ROUTE_SCREENSHOT, "h", 9, "U", "", Capture {
                nonce: 7,
                scale: 1,
                quality: None
            },)
            .as_deref(),
            Some("http://h:9/simulators/U/screenshot.jpg?t=7")
        );
        assert_eq!(
            build_capture(SLOPDESK_SIM_ROUTE_SCREENSHOT, "h", 9, "U", "", Capture {
                nonce: 7,
                scale: 4,
                quality: Some(0.5)
            },)
            .as_deref(),
            Some("http://h:9/simulators/U/screenshot.jpg?t=7&scale=4&quality=0.5")
        );
    }

    /// Zero back is a refusal, and both halves of "could never connect" reach it — as does a code
    /// from a future build, which must not fall through to some route.
    #[test]
    fn nothing_buildable_answers_zero() {
        assert_eq!(build(SLOPDESK_SIM_ROUTE_BOOT, "", 9, "U", ""), None);
        assert_eq!(build(SLOPDESK_SIM_ROUTE_BOOT, "h", 0, "U", ""), None);
        assert_eq!(build(9999, "h", 9, "U", ""), None);
        // SAFETY: the record pointer is null, which the door checks before reading it.
        let written = unsafe { slopdesk_sim_route(core::ptr::null(), core::ptr::null_mut(), 0) };
        assert_eq!(written, 0);
    }
}
