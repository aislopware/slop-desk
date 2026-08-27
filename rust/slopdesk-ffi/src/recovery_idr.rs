//! The `SLOPDESK_IDR_*` half of the recovery-keyframe law's tuning, in C —
//! `Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift`.
//!
//! [`crate::rate_control`] already carries the law itself (the policy handle) and its untuned
//! defaults ([`slopdesk_idr_config_default`]). What was missing was the step between them: the
//! three environment knobs the host applies on top of those defaults. They were spelled in Swift —
//! a raw `ProcessInfo.processInfo.environment` read, three parses, three clamps and one
//! millis→rate inversion — which is a second spelling of a rule that already exists, beside the
//! law, as `slopdesk_video::recovery_idr::{KEYS, RecoveryIdrConfig::from_env}`. This module is the
//! door over that constructor, and nothing else.
//!
//! ## Two entry points, for the reason `host_gates` has two
//!
//! [`slopdesk_idr_gate_keys`] hands over the NAMES; the caller looks each one up through
//! `EnvConfig.string` — the env → settings-overlay precedence of `docs/58`, which is a lookup rule
//! and not a tuning rule, and which a `std::env::var` on this side would silently stop honouring —
//! and [`slopdesk_idr_config_from_env`] takes the resolved texts back and answers the whole tuned
//! config at once. The names therefore stay spelled ONCE, over here, beside the law they tune.
//!
//! ## Why the texts cross as pairs and not as a blob list
//!
//! `host_gates` has thirty-three of them and its caller lives in `SlopDeskVideoProtocol`, where the
//! blob-list codec is; this has three, and its caller is in `SlopDeskVideoHost`, where that codec
//! is `internal` and out of reach. Three `(ptr, len)` pairs are the plain §4 shape, they need no
//! codec on either side, and they cannot fail to decode — so unlike the gate table this door has no
//! refusal arm and can answer by value. One pair per key is checked by a test, so a fourth key
//! cannot be added over there without this door failing to build a case for it here.
//!
//! Nothing here holds state, so nothing here is reachable from two threads in any sense that
//! matters: both entry points are pure functions of their arguments (`docs/55` §4b).

use core::ffi::c_uchar;

use slopdesk_video::recovery_idr::{KEYS, RecoveryIdrConfig};

use crate::rate_control::SlopDeskIdrConfig;
use crate::{deliver, lent};

/// The crate's tuned config as it crosses.
///
/// Written out field by field rather than reusing `rate_control`'s own private conversion: the
/// literal is exhaustive, so a field added to either side fails to compile here rather than
/// crossing as a stale default.
const fn crossing(config: RecoveryIdrConfig) -> SlopDeskIdrConfig {
    SlopDeskIdrConfig {
        grace_fraction: config.grace_fraction,
        grace_floor_seconds: config.grace_floor_seconds,
        grace_ceil_seconds: config.grace_ceil_seconds,
        bucket_capacity: config.bucket_capacity,
        refill_tokens_per_second: config.refill_tokens_per_second,
        grant_pending_timeout: config.grant_pending_timeout,
        keyframe_ring_capacity: config.keyframe_ring_capacity,
    }
}

/// One resolved text as [`RecoveryIdrConfig::from_env`] reads it: ABSENT, or the text.
///
/// A null pair is a key the caller could not resolve and an empty pair is a key set to nothing;
/// both fold to absent here, and folding them is safe precisely because none of these three keys is
/// a PRESENCE gate — every one of them is a number, so an empty text would fail to parse and leave
/// the field at its default anyway. Reading the two apart would let this door answer differently
/// from `from_env`, which is the drift it exists to prevent.
///
/// # Safety
/// `bytes` must be null, or name `len` initialised bytes that stay live for the whole call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C pointer/length pair becoming a str"
)]
unsafe fn set<'a>(bytes: *const c_uchar, len: usize) -> Option<&'a str> {
    // SAFETY: the caller's obligation, restated above; `lent` states its own.
    let text = unsafe { lent(bytes, len) };
    (!text.is_empty()).then_some(text)
}

/// The environment key names, `\0`-joined, in the order [`slopdesk_idr_config_from_env`] takes
/// their values.
///
/// The §4 size-then-read shape: a null `out` (or one too small) writes nothing and answers the
/// byte count needed. The caller splits on `\0` and gets the key list back, so the three names are
/// never re-typed on the Swift side — which is the whole failure this door prevents, because a
/// mistyped key name is invisible: the knob simply stops working and every test still passes.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_idr_gate_keys(out: *mut c_uchar, cap: usize) -> usize {
    let answer = KEYS.join("\0");
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The recovery-keyframe tuning with the three knobs above applied to
/// [`slopdesk_idr_config_default`]'s answer.
///
/// Each pair is the resolved text of the key at the matching position in
/// [`slopdesk_idr_gate_keys`], null for a key that is not set. Every default, every clamp and the
/// millis→rate inversion belong to `slopdesk_video::recovery_idr`; an unparseable or non-finite
/// text leaves its own field alone and touches no other, so a typo in one knob cannot silently
/// retune the rest.
///
/// Answers by value, and cannot refuse: with no list to decode there is no malformed input, and a
/// caller that resolved nothing gets exactly the defaults.
///
/// # Safety
/// Each pointer must be null, or name its length in initialised bytes, live for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the three pairs are the caller's to keep live"
)]
pub unsafe extern "C" fn slopdesk_idr_config_from_env(
    tokens: *const c_uchar,
    tokens_len: usize,
    refill_millis: *const c_uchar,
    refill_millis_len: usize,
    grace_millis: *const c_uchar,
    grace_millis_len: usize,
) -> SlopDeskIdrConfig {
    // SAFETY: the caller's obligation, restated above; `set` states its own.
    let values = unsafe {
        [
            set(tokens, tokens_len),
            set(refill_millis, refill_millis_len),
            set(grace_millis, grace_millis_len),
        ]
    };
    crossing(RecoveryIdrConfig::from_env(&values))
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use slopdesk_video::recovery_idr::KEYS;

    use super::{slopdesk_idr_config_from_env, slopdesk_idr_gate_keys};
    use crate::rate_control::{SlopDeskIdrConfig, slopdesk_idr_config_default};

    /// Resolves through the door the way the host does: a value per key, in key order, absent
    /// spelled as a null pair.
    fn resolve(values: [Option<&str>; 3]) -> SlopDeskIdrConfig {
        let lend =
            |value: Option<&str>| value.map_or((core::ptr::null(), 0), |text| (text.as_ptr(), text.len()));
        let (tokens, tokens_len) = lend(values[0]);
        let (refill, refill_len) = lend(values[1]);
        let (grace, grace_len) = lend(values[2]);
        // SAFETY: every non-null pointer is into a `&str` that outlives this call, with its own
        // length; the rest are null, which the door reads as absent.
        unsafe { slopdesk_idr_config_from_env(tokens, tokens_len, refill, refill_len, grace, grace_len) }
    }

    /// The names cross whole and in order, so a caller that splits on `\0` gets the key list back.
    #[test]
    fn the_key_list_crosses_in_order() {
        // SAFETY: a null `out` with a zero cap asks for the size, which is the door's own contract.
        let needed = unsafe { slopdesk_idr_gate_keys(core::ptr::null_mut(), 0) };
        let mut buffer = vec![0u8; needed];
        // SAFETY: `buffer` is live and exactly `needed` bytes long.
        let written = unsafe { slopdesk_idr_gate_keys(buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, needed);
        let text = String::from_utf8_lossy(&buffer);
        let names: Vec<&str> = text.split('\0').collect();
        assert_eq!(names, KEYS.to_vec());
    }

    /// An undersized buffer writes NOTHING and asks again, rather than handing back a truncated key
    /// name that would still split into plausible-looking names.
    #[test]
    fn an_undersized_buffer_is_refused_whole() {
        let mut buffer = [0xAB_u8; 4];
        // SAFETY: `buffer` is live for the length given, which is smaller than the answer.
        let needed = unsafe { slopdesk_idr_gate_keys(buffer.as_mut_ptr(), buffer.len()) };
        assert!(needed > buffer.len());
        assert_eq!(buffer, [0xAB; 4], "a short buffer is left untouched");
    }

    /// One pair per key. The door spells its parameters out, so a key added beside the law needs a
    /// pair here and a slot in the caller — this is the assertion that says so out loud.
    #[test]
    fn the_door_carries_one_pair_per_key() {
        assert_eq!(
            KEYS.len(),
            3,
            "slopdesk_idr_config_from_env takes one (ptr, len) pair per key",
        );
    }

    /// Nothing resolved is the untuned law: the door adds no default of its own.
    #[test]
    fn an_unset_environment_is_the_doors_own_defaults() {
        assert_eq!(resolve([None, None, None]), slopdesk_idr_config_default());
    }

    /// The burst allowance is clamped at both ends — a hand-typed 99 would re-open the keyframe
    /// storm the bucket exists to cap, and a 0 would wedge the recovery path shut.
    #[test]
    fn the_burst_allowance_is_clamped_at_both_ends() {
        let ceiling = resolve([Some("99"), None, None]);
        assert!((ceiling.bucket_capacity - 4.0).abs() < f64::EPSILON);
        let floor = resolve([Some("0"), None, None]);
        assert!((floor.bucket_capacity - 1.0).abs() < f64::EPSILON);
        let taken = resolve([Some("3"), None, None]);
        assert!((taken.bucket_capacity - 3.0).abs() < f64::EPSILON);
    }

    /// The refill key is a SPACING in milliseconds and the field is a RATE, so the door inverts it
    /// — and clamps the spacing BEFORE inverting, which is the only order that bounds the rate.
    #[test]
    fn the_refill_spacing_is_clamped_then_inverted() {
        let taken = resolve([None, Some("250"), None]);
        assert!((taken.refill_tokens_per_second - 4.0).abs() < f64::EPSILON);
        let floor = resolve([None, Some("10"), None]);
        assert!(
            (floor.refill_tokens_per_second - 10.0).abs() < f64::EPSILON,
            "a 10 ms spelling is held at the 100 ms floor, not inverted into 100 tokens/s",
        );
        let ceiling = resolve([None, Some("999999"), None]);
        assert!((ceiling.refill_tokens_per_second - 1000.0 / 5000.0).abs() < f64::EPSILON);
    }

    /// The grace key PINS the window: it sets floor and ceiling to the same value, so the fraction
    /// of round-trip is out of the picture entirely and the operator gets the window they asked
    /// for.
    #[test]
    fn the_grace_key_pins_the_window_at_both_ends() {
        let taken = resolve([None, None, Some("120")]);
        assert!((taken.grace_floor_seconds - 0.120).abs() < 1e-12);
        assert!((taken.grace_ceil_seconds - 0.120).abs() < 1e-12);
        let ceiling = resolve([None, None, Some("4000")]);
        assert!((ceiling.grace_ceil_seconds - 1.0).abs() < f64::EPSILON);
        let floor = resolve([None, None, Some("-5")]);
        assert!(floor.grace_floor_seconds.abs() < f64::EPSILON);
    }

    /// A text that is not a finite number leaves ITS field alone and no other — a typo in one knob
    /// must not retune the two beside it.
    #[test]
    fn an_unreadable_text_leaves_only_its_own_field_alone() {
        let defaults = slopdesk_idr_config_default();
        for spelling in ["", "off", "nan", "inf"] {
            let config = resolve([Some(spelling), Some("250"), None]);
            assert!(
                (config.bucket_capacity - defaults.bucket_capacity).abs() < f64::EPSILON,
                "{spelling:?} left the burst allowance alone",
            );
            assert!(
                (config.refill_tokens_per_second - 4.0).abs() < f64::EPSILON,
                "{spelling:?} did not disturb the key beside it",
            );
        }
    }

    /// All three at once, because the host sets them together: each reaches its own field, and the
    /// four knobs no key carries keep the law's own numbers.
    #[test]
    fn every_key_reaches_its_own_field() {
        let defaults = slopdesk_idr_config_default();
        let config = resolve([Some("1"), Some("500"), Some("40")]);
        assert!((config.bucket_capacity - 1.0).abs() < f64::EPSILON);
        assert!((config.refill_tokens_per_second - 2.0).abs() < f64::EPSILON);
        assert!((config.grace_floor_seconds - 0.040).abs() < 1e-12);
        assert!((config.grace_ceil_seconds - 0.040).abs() < 1e-12);
        assert!((config.grace_fraction - defaults.grace_fraction).abs() < f64::EPSILON);
        assert!((config.grant_pending_timeout - defaults.grant_pending_timeout).abs() < f64::EPSILON);
        assert_eq!(config.keyframe_ring_capacity, defaults.keyframe_ring_capacity);
    }
}
