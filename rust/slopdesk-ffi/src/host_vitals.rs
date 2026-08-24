//! The machine's pulse, in C — `Sources/SlopDeskHost/HostMetadataProbe.swift`.
//!
//! The rules and the readings are [`slopdesk_panecensus::vitals`]; what is here is the marshalling.
//!
//! ## Why this one is a HANDLE and not a function
//! A CPU percent is a delta, so an answer needs a BASELINE that outlives the request. hostd builds
//! a fresh metadata probe per request while the reading is host-global, which is why the Swift
//! version was a process-wide singleton behind a lock. Passing the baseline across the boundary per
//! call would work — it is two ticks and an instant — but it would put "when may a baseline be
//! reused" back on the near side, and that rule is the whole module. So the state stays in Rust and
//! Swift holds a token, the same bargain [`crate::replay`] makes and under the same three
//! obligations: exactly one free per new, no overlapping calls on one handle, and nothing allocated
//! on one side and freed on the other.
//!
//! ## Why the clock crosses
//! [`slopdesk_panecensus::vitals::Sampler`] takes `now`. Reading a clock inside would make the
//! staleness and minimum-window rules untestable without sleeping, which is exactly the kind of
//! test the hang-safety rule keeps out of the suite. Swift already holds a monotonic instant.
//!
//! macOS only, and gated in `lib.rs` rather than here: every reading is a Mach or `sysctl` call
//! about the machine hostd is running on, and no client asks this of itself.

use core::ffi::c_uchar;

use slopdesk_panecensus::vitals::Sampler;

use crate::borrow;

/// One host-vitals reading, as the metadata responder encodes it.
///
/// `disk_free_present` rather than the wire's `u32::MAX` sentinel: the sentinel is the ENCODER's
/// business, and a door that handed it over would make every Swift caller responsible for knowing
/// which magic number means "unreadable".
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskHostVitals {
    /// All-core CPU busy percent, `0..=100`.
    pub cpu_percent: u8,
    /// Physical memory in use percent, `0..=100`.
    pub memory_percent: u8,
    /// The kernel's memory-pressure level as the wire byte: 0 normal, 1 warn, 2 critical.
    pub pressure_byte: u8,
    /// Free MiB on the volume asked about. Meaningless unless `disk_free_present`.
    pub disk_free_mib: u32,
    /// Whether `disk_free_mib` is a reading at all.
    pub disk_free_present: bool,
}

/// The opaque sampler handle: the CPU baseline and the last published reading.
#[derive(Debug)]
#[expect(
    missing_copy_implementations,
    reason = "the contents ARE copyable and that is exactly why this type must not be: a handle is owned by \
              one Swift object and freed once, and a `Copy` handle type is one that can be duplicated into \
              a second owner that will free it again"
)]
pub struct SlopDeskHostVitalsSampler {
    sampler: Sampler,
}

/// Builds a sampler with no baseline. Its first [`slopdesk_host_vitals_sample`] banks one and
/// reports nothing.
///
/// # Safety
/// Nothing is borrowed — the function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_vitals_new() -> *mut SlopDeskHostVitalsSampler {
    Box::into_raw(Box::new(SlopDeskHostVitalsSampler {
        sampler: Sampler::new(),
    }))
}

/// Releases a sampler. Null is a no-op; anything else must have come from
/// [`slopdesk_host_vitals_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_host_vitals_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_vitals_free(handle: *mut SlopDeskHostVitalsSampler) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `Box::into_raw` in
    // `slopdesk_host_vitals_new` and has not been freed, so reclaiming the box is sound.
    drop(unsafe { Box::from_raw(handle) });
}

/// Drops the baseline and the cache, so the next sample primes afresh.
///
/// # Safety
/// `handle` must be null or a live, unfreed pointer from [`slopdesk_host_vitals_new`], with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_vitals_reset(handle: *mut SlopDeskHostVitalsSampler) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    unsafe { (*handle).sampler.reset() };
}

/// Reads the machine and folds one vitals answer into `out`, returning whether there was one.
///
/// `false` — with `out` untouched — is the normal first call, a refused `HOST_CPU_LOAD_INFO`, or a
/// baseline the module's own rules will not average across. The verb replies `.error` and the
/// client asks again on its next poll.
///
/// `home` names the path whose VOLUME the free-space figure describes. It is passed rather than
/// read here because `$HOME` is a dictionary lookup the caller already has, the way
/// [`crate::tool_path`] leaves its three environment reads on the near side.
///
/// # Safety
/// `handle` must be null or a live, unfreed pointer from [`slopdesk_host_vitals_new`] with no other
/// call on it in flight; `home` must be null or point to `home_len` live bytes; `out` must be null
/// or point to one writable [`SlopDeskHostVitals`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_vitals_sample(
    handle: *mut SlopDeskHostVitalsSampler,
    home: *const c_uchar,
    home_len: usize,
    now_nanos: u64,
    out: *mut SlopDeskHostVitals,
) -> bool {
    if handle.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation above is `borrow`'s.
    let home = String::from_utf8_lossy(unsafe { borrow(home, home_len) }).into_owned();
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    let Some(vitals) = (unsafe { (*handle).sampler.sample(&home, now_nanos) }) else {
        return false;
    };
    // SAFETY: non-null and writable for one struct by the caller's obligation above.
    unsafe {
        *out = SlopDeskHostVitals {
            cpu_percent: vitals.cpu_percent,
            memory_percent: vitals.memory_percent,
            pressure_byte: vitals.pressure_byte,
            disk_free_mib: vitals.disk_free_mib.unwrap_or_default(),
            disk_free_present: vitals.disk_free_mib.is_some(),
        };
    }
    true
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "the tests drive the same C entry points every caller does"
)]
mod tests {
    use super::{
        SlopDeskHostVitals, slopdesk_host_vitals_free, slopdesk_host_vitals_new, slopdesk_host_vitals_reset,
        slopdesk_host_vitals_sample,
    };

    #[test]
    fn a_null_handle_answers_nothing_and_touches_no_buffer() {
        let mut out = SlopDeskHostVitals {
            cpu_percent: 42,
            ..SlopDeskHostVitals::default()
        };
        // SAFETY: a null handle is what the door's own contract admits.
        assert!(!unsafe {
            slopdesk_host_vitals_sample(std::ptr::null_mut(), std::ptr::null(), 0, 0, &raw mut out)
        });
        assert_eq!(out.cpu_percent, 42, "an untouched buffer stays untouched");
        // SAFETY: freeing and resetting null are both no-ops by contract.
        unsafe {
            slopdesk_host_vitals_free(std::ptr::null_mut());
            slopdesk_host_vitals_reset(std::ptr::null_mut());
        }
    }

    #[test]
    fn the_first_sample_primes_the_baseline_and_the_handle_frees_once() {
        // SAFETY: the handle is used and freed exactly once, with no overlapping call.
        unsafe {
            let handle = slopdesk_host_vitals_new();
            assert!(!handle.is_null());
            let home = "/";
            let mut out = SlopDeskHostVitals::default();
            assert!(
                !slopdesk_host_vitals_sample(handle, home.as_ptr(), home.len(), 0, &raw mut out),
                "the first poll banks a baseline"
            );
            slopdesk_host_vitals_reset(handle);
            assert!(!slopdesk_host_vitals_sample(
                handle,
                home.as_ptr(),
                home.len(),
                0,
                &raw mut out
            ));
            slopdesk_host_vitals_free(handle);
        }
    }

    #[test]
    fn a_null_out_refuses_rather_than_writing_nowhere() {
        // SAFETY: the handle is used and freed exactly once; the out pointer is null by design.
        unsafe {
            let handle = slopdesk_host_vitals_new();
            assert!(!slopdesk_host_vitals_sample(
                handle,
                std::ptr::null(),
                0,
                0,
                std::ptr::null_mut()
            ));
            slopdesk_host_vitals_free(handle);
        }
    }
}
