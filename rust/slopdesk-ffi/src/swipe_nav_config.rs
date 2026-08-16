//! The host's swipe-navigation operating point —
//! `Sources/SlopDeskVideoHost/SwipeNavHostConfig.swift`.
//!
//! ONE parse of the environment family, shared by the path that fires the chord and by the status
//! push that tells the client what the host will actually do. Two parses could drift, and then the
//! client's feedback would LIE: a committed chip and its haptic for a fire the host swallows.
//!
//! ## Why this one is a HANDLE
//!
//! The operating point holds an allowlist EXTENSION — a set of bundle ids read out of the
//! environment — so it cannot fold into a record of scalars the way the ledger and the accumulator
//! do (`docs/55` §4b). Its owner is a process-lifetime namespace that never copies it, which is the
//! other half of that rule: a handle is safe exactly when nothing duplicates it. Parsed once at
//! start-up and asked its questions for the life of the host.

use core::ffi::c_uchar;

use slopdesk_video::swipe_nav::SwipeNavStatusMessage;
use slopdesk_video::swipe_nav_config::{NavHistoryFlags, SwipeNavHostConfig};

use crate::borrow;
use crate::metadata_wire::SlopDeskSwipeNavStatus;

/// An opaque parsed operating point.
#[derive(Debug)]
pub struct SlopDeskSwipeNavConfig {
    /// The parsed value.
    inner: SwipeNavHostConfig,
}

/// The handle as a reference, or `None` for null.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_swipe_nav_config_parse`].
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskSwipeNavConfig) -> Option<&'a SlopDeskSwipeNavConfig> {
    // SAFETY: by the caller's obligation this is a live allocation from `parse`.
    unsafe { handle.as_ref() }
}

/// One environment value, or `None` when the variable is absent.
///
/// # Safety
/// `raw` must be null or point to `len` readable bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
unsafe fn setting<'a>(raw: *const c_uchar, len: usize) -> Option<&'a str> {
    if raw.is_null() {
        return None;
    }
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let bytes = unsafe { borrow(raw, len) };
    // A `SLOPDESK_*` value that is not UTF-8 reads as ABSENT, which is the same answer an unset
    // variable gives and the one every switch here defaults to.
    core::str::from_utf8(bytes).ok()
}

/// Parses the operating point from the raw environment values.
///
/// Each value is a `(pointer, length)` pair where a NULL pointer means the variable is unset — not
/// an empty string, which is a value a user can actually set and which the parse treats as one.
///
/// # Safety
/// Every pointer must be null or point to its stated number of readable bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_parse(
    enabled: *const c_uchar,
    enabled_len: usize,
    apps: *const c_uchar,
    apps_len: usize,
    travel: *const c_uchar,
    travel_len: usize,
    slow: *const c_uchar,
    slow_len: usize,
    history: *const c_uchar,
    history_len: usize,
) -> *mut SlopDeskSwipeNavConfig {
    // SAFETY: the caller's obligation on each pair, discharged by Swift's `withUnsafeBytes`.
    let inner = unsafe {
        SwipeNavHostConfig::from_env(
            setting(enabled, enabled_len),
            setting(apps, apps_len),
            setting(travel, travel_len),
            setting(slow, slow_len),
            setting(history, history_len),
        )
    };
    Box::into_raw(Box::new(SlopDeskSwipeNavConfig { inner }))
}

/// Frees a parsed operating point. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_swipe_nav_config_parse`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_free(handle: *mut SlopDeskSwipeNavConfig) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `parse` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// The lift-fire travel threshold in points, already clamped.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_fire_travel(handle: *const SlopDeskSwipeNavConfig) -> f64 {
    // SAFETY: the caller's obligation.
    unsafe { held(handle) }.map_or(0.0, |config| config.inner.fire_travel)
}

/// Whether the slow tier is accepted.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_slow_tier(handle: *const SlopDeskSwipeNavConfig) -> bool {
    // SAFETY: the caller's obligation.
    unsafe { held(handle) }.is_some_and(|config| config.inner.slow_tier)
}

/// Whether the history read gates the push at all. Off means every push reports the state as
/// unknown and the client fails open.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_history_gate(
    handle: *const SlopDeskSwipeNavConfig,
) -> bool {
    // SAFETY: the caller's obligation.
    unsafe { held(handle) }.is_some_and(|config| config.inner.history_gate)
}

/// The master switch.
///
/// Asked only where the fire path exits BEFORE it knows a target app — the eligibility question
/// already carries this, and asking it a second time next to a bundle id would be the drift this
/// module exists to prevent.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_enabled(handle: *const SlopDeskSwipeNavConfig) -> bool {
    // SAFETY: the caller's obligation.
    unsafe { held(handle) }.is_some_and(|config| config.inner.enabled)
}

/// Whether a qualifying swipe aimed at this app would be translated right now.
///
/// A NULL bundle id is an unidentified app, which is never navigable.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `bundle_id` must be null or point to
/// `bundle_len` readable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_eligible(
    handle: *const SlopDeskSwipeNavConfig,
    bundle_id: *const c_uchar,
    bundle_len: usize,
) -> bool {
    // SAFETY: the caller's obligation on both.
    unsafe { held(handle) }.is_some_and(|config| {
        // SAFETY: the caller's obligation.
        config.inner.eligible(unsafe { setting(bundle_id, bundle_len) })
    })
}

/// WINDOW-scoped eligibility: the pane's app must be navigable AND actually frontmost.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and each bundle id must be null or point to its
/// stated number of readable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_window_eligible(
    handle: *const SlopDeskSwipeNavConfig,
    pane_bundle_id: *const c_uchar,
    pane_len: usize,
    frontmost_bundle_id: *const c_uchar,
    frontmost_len: usize,
) -> bool {
    // SAFETY: the caller's obligation on all three.
    unsafe { held(handle) }.is_some_and(|config| {
        // SAFETY: the caller's obligation.
        let (pane, frontmost) = unsafe {
            (
                setting(pane_bundle_id, pane_len),
                setting(frontmost_bundle_id, frontmost_len),
            )
        };
        config.inner.eligible_window_target(pane, frontmost)
    })
}

/// The status message describing this operating point for one target app.
///
/// The history read crosses as a value plus a presence flag: `has_history == false` is the UNKNOWN
/// that makes the client fail open rather than show a dark chip, and it is not any pair of bits.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `bundle_id` must be null or point to
/// `bundle_len` readable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_status(
    handle: *const SlopDeskSwipeNavConfig,
    bundle_id: *const c_uchar,
    bundle_len: usize,
    has_history: bool,
    can_go_back: bool,
    can_go_forward: bool,
) -> SlopDeskSwipeNavStatus {
    // SAFETY: the caller's obligation on both.
    unsafe { held(handle) }.map_or_else(SlopDeskSwipeNavStatus::default, |config| {
        // SAFETY: the caller's obligation.
        let bundle = unsafe { setting(bundle_id, bundle_len) };
        crossing(
            config
                .inner
                .status(bundle, history(has_history, can_go_back, can_go_forward)),
        )
    })
}

/// The status message for one WINDOW-scoped session.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and each bundle id must be null or point to its
/// stated number of readable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_config_window_status(
    handle: *const SlopDeskSwipeNavConfig,
    pane_bundle_id: *const c_uchar,
    pane_len: usize,
    frontmost_bundle_id: *const c_uchar,
    frontmost_len: usize,
    has_history: bool,
    can_go_back: bool,
    can_go_forward: bool,
) -> SlopDeskSwipeNavStatus {
    // SAFETY: the caller's obligation on all three.
    unsafe { held(handle) }.map_or_else(SlopDeskSwipeNavStatus::default, |config| {
        // SAFETY: the caller's obligation.
        let (pane, frontmost) = unsafe {
            (
                setting(pane_bundle_id, pane_len),
                setting(frontmost_bundle_id, frontmost_len),
            )
        };
        crossing(config.inner.window_status(
            pane,
            frontmost,
            history(has_history, can_go_back, can_go_forward),
        ))
    })
}

/// The history read as the crate takes it: absent, or a pair of flags.
const fn history(has_history: bool, can_go_back: bool, can_go_forward: bool) -> Option<NavHistoryFlags> {
    if has_history {
        Some(NavHistoryFlags {
            can_go_back,
            can_go_forward,
        })
    } else {
        None
    }
}

/// The message flattened into the record it crosses as.
const fn crossing(message: SwipeNavStatusMessage) -> SlopDeskSwipeNavStatus {
    SlopDeskSwipeNavStatus {
        fire_travel: message.fire_travel,
        eligible: message.eligible,
        slow_tier: message.slow_tier,
        can_go_back: message.can_go_back,
        can_go_forward: message.can_go_forward,
        history_known: message.history_known,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{
        SlopDeskSwipeNavConfig, slopdesk_swipe_nav_config_eligible, slopdesk_swipe_nav_config_free,
        slopdesk_swipe_nav_config_history_gate, slopdesk_swipe_nav_config_parse,
        slopdesk_swipe_nav_config_slow_tier, slopdesk_swipe_nav_config_status,
        slopdesk_swipe_nav_config_window_status,
    };

    /// The operating point parsed from the values a caller may or may not have.
    fn parse(apps: Option<&str>, off: bool) -> *mut SlopDeskSwipeNavConfig {
        let zero = b"0";
        let (switch, switch_len) = if off {
            (zero.as_ptr(), zero.len())
        } else {
            (core::ptr::null(), 0)
        };
        let (apps_ptr, apps_len) = apps.map_or((core::ptr::null(), 0), |raw| (raw.as_ptr(), raw.len()));
        unsafe {
            slopdesk_swipe_nav_config_parse(
                switch,
                switch_len,
                apps_ptr,
                apps_len,
                core::ptr::null(),
                0,
                switch,
                switch_len,
                switch,
                switch_len,
            )
        }
    }

    fn status_for(handle: *mut SlopDeskSwipeNavConfig, bundle: &str, has_history: bool) -> (bool, bool) {
        let status = unsafe {
            slopdesk_swipe_nav_config_status(handle, bundle.as_ptr(), bundle.len(), has_history, true, true)
        };
        (status.eligible, status.history_known)
    }

    /// Every switch is on unless the environment says exactly zero.
    #[test]
    fn every_switch_is_on_unless_the_environment_says_zero() {
        let on = parse(None, false);
        assert!(unsafe { slopdesk_swipe_nav_config_slow_tier(on) });
        assert!(unsafe { slopdesk_swipe_nav_config_history_gate(on) });
        let off = parse(None, true);
        assert!(!unsafe { slopdesk_swipe_nav_config_slow_tier(off) });
        assert!(!unsafe { slopdesk_swipe_nav_config_history_gate(off) });
        unsafe {
            slopdesk_swipe_nav_config_free(on);
            slopdesk_swipe_nav_config_free(off);
        }
    }

    /// The allowlist EXTENSION is why this crosses as a handle at all.
    #[test]
    fn an_app_named_only_by_the_environment_is_navigable() {
        let handle = parse(Some("com.example.reader"), false);
        let named = "com.example.reader";
        assert!(unsafe { slopdesk_swipe_nav_config_eligible(handle, named.as_ptr(), named.len()) });
        let stranger = "com.example.stranger";
        assert!(!unsafe { slopdesk_swipe_nav_config_eligible(handle, stranger.as_ptr(), stranger.len()) });
        assert!(
            !unsafe { slopdesk_swipe_nav_config_eligible(handle, core::ptr::null(), 0) },
            "an unidentified app is never navigable",
        );
        unsafe { slopdesk_swipe_nav_config_free(handle) };
    }

    /// An INELIGIBLE push zeroes the history bits, so "ineligible" is byte-identical whatever the
    /// read happened to say — and an unknown read is never reported as known.
    #[test]
    fn an_ineligible_push_carries_no_history_at_all() {
        let handle = parse(Some("com.example.reader"), false);
        assert_eq!(status_for(handle, "com.example.reader", true), (true, true));
        assert_eq!(
            status_for(handle, "com.example.reader", false),
            (true, false),
            "an unread history fails OPEN, it is not reported as known",
        );
        assert_eq!(
            status_for(handle, "com.example.stranger", true),
            (false, false),
            "an ineligible push zeroes the bits it was handed",
        );
        unsafe { slopdesk_swipe_nav_config_free(handle) };
    }

    /// A window session's chip goes dark unless the pane's own app is frontmost.
    #[test]
    fn a_window_push_is_eligible_only_while_the_pane_is_frontmost() {
        let handle = parse(Some("com.example.reader"), false);
        let pane = "com.example.reader";
        let other = "com.example.stranger";
        let eligible = |frontmost: &str| {
            unsafe {
                slopdesk_swipe_nav_config_window_status(
                    handle,
                    pane.as_ptr(),
                    pane.len(),
                    frontmost.as_ptr(),
                    frontmost.len(),
                    true,
                    true,
                    true,
                )
            }
            .eligible
        };
        assert!(eligible(pane));
        assert!(
            !eligible(other),
            "the affordance must not promise a fire the host swallows"
        );
        unsafe { slopdesk_swipe_nav_config_free(handle) };
    }

    /// A null handle answers the way an ineligible one does, rather than reaching for memory.
    #[test]
    fn a_null_handle_is_an_ineligible_answer() {
        let status = unsafe {
            slopdesk_swipe_nav_config_status(core::ptr::null(), core::ptr::null(), 0, true, true, true)
        };
        assert!(!status.eligible);
        assert!(!status.history_known);
        unsafe { slopdesk_swipe_nav_config_free(core::ptr::null_mut()) };
    }
}
