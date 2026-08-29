//! How the simulator panel ASKS, in C — `Sources/SlopDeskDevicePanels/Simulator/
//! SimulatorControlClient.swift`.
//!
//! The rules are [`slopdesk_devicepanel::sim_control`]'s; what is here is the marshalling.
//! [`crate::simulator_routes`] is the other half of one request: that door answers WHERE it goes
//! and these answer everything else about it.
//!
//! ## What did NOT move, and why `URLSession` is still Swift
//!
//! `docs/55` §1 picks by lifetime, and a session and its tasks are the caller's — they outlive the
//! call, complete on their own queue, and are cancelled by the view model that owns them. So what
//! crosses is a PLAN, and the near side performs it. That is the same split
//! [`crate::android_bridge`] already makes for a socket: the two ends of the request, and nothing
//! in between.
//!
//! ## Why the plan is a blob rather than a `#[repr(C)]` record
//!
//! Two of its four fields are STRINGS the caller does not already hold — the method and the content
//! type — and §4's "answers, not identities" rule turns on exactly that. A kind byte per field
//! would put `"DELETE"` and `"application/octet-stream"` back on the near side, which is where they
//! were, and the whole point of the table is that no call site spells one. There is one crossing
//! per request, against a poll that runs every couple of seconds; the doors it replaces were eleven
//! inline `URLRequest` builders.

use core::ffi::c_uchar;

use slopdesk_devicepanel::sim_control;

use crate::{deliver, push_text};

/// The plan for one operation: `[u8 ignores_cache][f64 BE timeout seconds][method][content type]`.
///
/// `operation` is `0` devices · `1` boot · `2` shutdown · `3` chrome · `4` resource ·
/// `5` orientation · `6` screenshot · `7` thumbnail · `8` status bar · `9` files · `10` location.
/// `has_payload` is read by the status bar and the location only — the two routes with a SET form
/// and a CLEAR form — and ignored by every other operation.
///
/// The content type is the EMPTY run for a request that carries no body: absent rather than empty,
/// since sending the header without a body would describe bytes that are not there.
///
/// The timeout crosses as eight big-endian bytes of the `f64`'s bit pattern rather than as a
/// decimal, for [`crate::simulator_decode`]'s reason: it is compared with `==` on the near side
/// against the constant it came from, and only a bit round trip makes that hold.
///
/// Zero back is a REFUSAL, and it can only be an operation code no build of this crate wrote — a
/// real plan is never empty, because every request has a verb. Falling through to a neighbouring
/// operation would send the wrong verb to the right URL, which the server answers with a `405`
/// nobody reads as a client bug.
///
/// # Safety
/// `out` must be writable for `cap` bytes for the duration of the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_control_plan(
    operation: u32,
    has_payload: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(operation) = sim_control::Operation::from_code(operation) else {
        return 0;
    };
    let plan = sim_control::plan(operation, has_payload);
    let mut blob = Vec::new();
    blob.push(u8::from(plan.ignores_cache));
    blob.extend_from_slice(&plan.timeout_seconds.to_bits().to_be_bytes());
    push_text(&mut blob, plan.method.as_str());
    push_text(&mut blob, plan.content_type.unwrap_or_default());
    // SAFETY: `blob` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(&blob, out, cap) }
}

/// Whether the server's status line means the request succeeded.
///
/// A scalar door whose answer is a `bool`, so there is no `0` to mistake for a size: a non-2xx
/// answer is a failure even when the body parses, because a refused boot is reported that way and
/// treating it as success leaves the panel claiming a device is starting when nothing happened.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_sim_control_status_ok(status: u16) -> bool {
    sim_control::status_is_ok(status)
}

/// The integer downscale divisor a device-list card is captured at.
///
/// Its own door rather than a member of an indexed family, for the reason `docs/55` gives about
/// types: it and the quality beside it are an `int32_t` and a `double`, and a family has to agree
/// on one.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_sim_thumbnail_scale() -> i32 {
    sim_control::THUMBNAIL_SCALE
}

/// The JPEG quality a device-list card is captured at, `0`–`1`.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_sim_thumbnail_quality() -> f64 {
    sim_control::THUMBNAIL_QUALITY
}

/// The status-bar override body — Apple's marketing status bar, as the route takes it.
///
/// Never empty, so `0` can only mean the caller's buffer was measured wrong. The preset is written
/// on this side of the boundary because the server rejects the WHOLE body on one bad field: it is
/// eight pairs that have to be right together, and a dictionary assembled by the near side and
/// re-encoded here would be the same eight pairs spelled twice.
///
/// # Safety
/// `out` must be writable for `cap` bytes for the duration of the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_status_bar_body(out: *mut c_uchar, cap: usize) -> usize {
    let body = sim_control::status_bar_body();
    // SAFETY: `body` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(body.as_bytes(), out, cap) }
}

/// The location body for a pinned position, `{"latitude":…,"longitude":…}`.
///
/// The six-decimal rounding is applied HERE, so the body and the readout the header echoes cannot
/// disagree about what was sent. Never empty, so `0` can only mean a mis-measured buffer.
///
/// # Safety
/// `out` must be writable for `cap` bytes for the duration of the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_location_body(
    latitude: f64,
    longitude: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let body = sim_control::location_body(latitude, longitude);
    // SAFETY: `body` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(body.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use slopdesk_devicepanel::sim_control;

    use super::{
        slopdesk_sim_control_plan, slopdesk_sim_control_status_ok, slopdesk_sim_location_body,
        slopdesk_sim_status_bar_body, slopdesk_sim_thumbnail_quality, slopdesk_sim_thumbnail_scale,
    };
    use crate::testing::delivered;

    /// One plan, read the way the near side reads it.
    ///
    /// The timeout is kept as its BIT PATTERN rather than as an `f64`: it crossed as one, and a
    /// comparison on the bits is the assertion — a tolerance would pass on exactly the drift the
    /// framing exists to prevent.
    type Read = (String, String, u64, bool);

    /// The near side's cursor over one plan.
    struct Cursor<'a> {
        blob: &'a [u8],
        at: usize,
    }

    impl<'a> Cursor<'a> {
        const fn new(blob: &'a [u8]) -> Self {
            Self { blob, at: 0 }
        }

        fn byte(&mut self) -> u8 {
            let byte = self.blob.get(self.at).copied().unwrap_or_default();
            self.at += 1;
            byte
        }

        fn length(&mut self) -> usize {
            let mut length = 0_usize;
            for _ in 0..4 {
                length = length << 8 | usize::from(self.byte());
            }
            length
        }

        fn bits(&mut self) -> u64 {
            let mut bits = 0_u64;
            for _ in 0..8 {
                bits = bits << 8 | u64::from(self.byte());
            }
            bits
        }

        fn text(&mut self) -> String {
            let length = self.length();
            let text = self
                .blob
                .get(self.at..self.at + length)
                .map(|span| String::from_utf8_lossy(span).into_owned())
                .unwrap_or_default();
            self.at += length;
            text
        }
    }

    fn plan(operation: u32, has_payload: bool) -> Option<Read> {
        let blob = delivered(|out, cap| {
            // SAFETY: the buffer is a live local for the duration of the call.
            unsafe { slopdesk_sim_control_plan(operation, has_payload, out, cap) }
        });
        if blob.is_empty() {
            return None;
        }
        let mut cursor = Cursor::new(&blob);
        let ignores_cache = cursor.byte() == 1;
        let timeout = cursor.bits();
        let method = cursor.text();
        let content_type = cursor.text();
        assert_eq!(cursor.at, blob.len(), "the layout must consume the delivery");
        Some((method, content_type, timeout, ignores_cache))
    }

    /// Every plan the wrapped crate makes crosses as itself, for both settings of the payload flag.
    #[test]
    fn every_plan_crosses_as_the_crates_own() {
        for code in 0..=10_u32 {
            for has_payload in [false, true] {
                let expected = sim_control::Operation::from_code(code).map(|operation| {
                    let plan = sim_control::plan(operation, has_payload);
                    (
                        plan.method.as_str().to_owned(),
                        plan.content_type.unwrap_or_default().to_owned(),
                        plan.timeout_seconds.to_bits(),
                        plan.ignores_cache,
                    )
                });
                assert_eq!(
                    plan(code, has_payload),
                    expected,
                    "operation {code}/{has_payload}"
                );
            }
        }
    }

    /// An operation code no build wrote answers NOTHING rather than falling through to a
    /// neighbour, which would send the wrong verb to the right URL.
    #[test]
    fn an_operation_this_build_does_not_know_answers_zero() {
        assert!(plan(11, false).is_none());
        assert!(plan(u32::MAX, true).is_none());
    }

    /// The two verbs that are a measured decision reach the near side as words, not as a flag it
    /// would have to translate.
    #[test]
    fn the_clear_form_of_both_two_verb_routes_crosses_as_delete() {
        for route in [8_u32, 10] {
            assert_eq!(
                plan(route, false).map(|(method, content_type, ..)| (method, content_type)),
                Some(("DELETE".to_owned(), String::new())),
                "route {route}"
            );
            assert_eq!(
                plan(route, true).map(|(method, content_type, ..)| (method, content_type)),
                Some(("POST".to_owned(), "application/json".to_owned())),
                "route {route}"
            );
        }
    }

    /// The scalars are the wrapped crate's, reached through the ABI.
    #[expect(
        clippy::float_cmp,
        reason = "a constant that crosses by value must be the SAME value, and a tolerance would hide the \
                  drift the door exists to prevent"
    )]
    #[test]
    fn the_scalars_are_the_crates() {
        assert!(slopdesk_sim_control_status_ok(200));
        assert!(slopdesk_sim_control_status_ok(201));
        assert!(!slopdesk_sim_control_status_ok(404));
        assert_eq!(slopdesk_sim_thumbnail_scale(), sim_control::THUMBNAIL_SCALE);
        assert_eq!(slopdesk_sim_thumbnail_quality(), sim_control::THUMBNAIL_QUALITY);
    }

    /// Both bodies cross verbatim, so the bytes on the wire are the ones the crate's own test pins.
    #[test]
    fn both_bodies_cross_verbatim() {
        let status_bar = delivered(|out, cap| {
            // SAFETY: the buffer is a live local for the duration of the call.
            unsafe { slopdesk_sim_status_bar_body(out, cap) }
        });
        assert_eq!(
            String::from_utf8_lossy(&status_bar),
            sim_control::status_bar_body()
        );
        let location = delivered(|out, cap| {
            // SAFETY: the buffer is a live local for the duration of the call.
            unsafe { slopdesk_sim_location_body(37.334_886_123_4, -122.008_988_123_4, out, cap) }
        });
        assert_eq!(
            String::from_utf8_lossy(&location),
            r#"{"latitude":37.334886,"longitude":-122.008988}"#
        );
    }

    /// An undersized buffer writes NOTHING and reports what it needed — `docs/55` §4's retry, which
    /// every door here must honour.
    #[test]
    fn an_undersized_buffer_is_a_size_report() {
        let mut probe = [0_u8; 4];
        // SAFETY: the buffer is a live local, and four bytes is smaller than any plan.
        let needed = unsafe { slopdesk_sim_control_plan(0, false, probe.as_mut_ptr(), probe.len()) };
        assert!(needed > probe.len());
        assert_eq!(probe, [0, 0, 0, 0]);
    }
}
