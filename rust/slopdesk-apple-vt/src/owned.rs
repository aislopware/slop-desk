//! The two Core Foundation ownership rules, each applied in exactly ONE place in this crate.
//!
//! `docs/57` §2 gives this family two counted admissions — `CFRetained::from_raw` for the
//! Copy/Create rule and `CFRetained::retain` for the Get rule — and caps each at one site per
//! crate. The cap is the whole reason they are admissions rather than holes: one site means the
//! crate has exactly one place where a framework pointer becomes an owned value, and every typed
//! reader is a caller of it.
//!
//! This module IS that place. It exists because the crate grew a second framework area: compression
//! took one Create-rule out-parameter and one Get-rule callback pointer, and decompression takes
//! four and one. Written inline that would have been ten sites and a §2 violation; written here it
//! is two, and the count `apple-family` enforces reads the same as the count a reviewer would want.
//!
//! ## Why a generic helper is the RIGHT reading of the cap rather than a way around it
//! The rule's own words are "the crate has exactly one place where a Copy-rule pointer becomes an
//! owned value and every typed reader is a caller of that helper". A per-call-site `from_raw` makes
//! the obligation ten separate arguments, each of which a reviewer must re-derive from the callee's
//! name. Here the argument is made once — Apple's naming convention, and what the two halves of it
//! mean — and each call site's job shrinks to the one thing a reviewer can actually check by
//! reading the line: *does this function's name contain `Copy` or `Create`?*
//!
//! Neither helper is `unsafe` to CALL, and that is deliberate. Both take a raw pointer that the
//! framework just wrote or handed over, and both answer `None` for null, so the only way to misuse
//! one is to hand it a pointer of the wrong PROVENANCE — which is a question about the callee's
//! name, not about the pointer's validity, and is therefore stated at each call site as a `#
//! Safety` note naming the framework rule that provenance came from.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use core::ptr::NonNull;

use objc2_core_foundation::{CFRetained, Type};

/// Takes ownership of a **Create-rule** pointer: one the framework just handed over at +1.
///
/// The Copy/Create rule says a Core Foundation function whose name contains `Copy` or `Create`
/// returns a reference the caller owns and must release. Several of them deliver it through an
/// out-parameter rather than as a return value — `VTCompressionSessionCreate`,
/// `VTDecompressionSessionCreate`, `CMVideoFormatDescriptionCreateFromHEVCParameterSets`,
/// `CMBlockBufferCreateWithMemoryBlock`, `CMSampleBufferCreateReady` — and `objc2` generates those
/// as a raw slot, because the ownership is stated by Apple's naming convention and not by the C
/// signature.
///
/// Answers `None` for null, which is what the frameworks write into the slot when they fail. A
/// caller that checked only the `OSStatus` and trusted the pointer would be one framework bug away
/// from a null dereference; checking the pointer is cheaper than deciding whether to trust it.
///
/// # Safety
/// The caller must have obtained `raw` from a function whose name contains `Copy` or `Create`, into
/// a live slot of the declared type, and must not use `raw` afterwards. Not marked `unsafe` because
/// the obligation is about the CALLEE'S NAME rather than about the pointer — see the module header.
pub(crate) fn created<T: Type>(raw: *mut T) -> Option<CFRetained<T>> {
    // SAFETY: framework rule — the Copy/Create rule made this reference the caller's to release, and
    // the null check above is what the frameworks use to report that they wrote nothing at all.
    #[expect(
        unsafe_code,
        reason = "the Create-rule out-parameter; docs/57 §2 admits this shape, at ONE site"
    )]
    NonNull::new(raw).map(|ptr| unsafe { CFRetained::from_raw(ptr) })
}

/// Takes a reference of this crate's own to a **Get-rule** pointer: one borrowed for a call.
///
/// The other half of the same convention. A function whose name contains neither `Copy` nor
/// `Create` — and every callback argument, which is the case that matters here — hands back a +0
/// reference valid only for the duration of the call. `objc2` generates those as bare `*mut T`,
/// because again the C signature says nothing. A holder that wants the object past the call retains
/// it, and `CFRetained::retain` is that retain with the release attached.
///
/// Answers `None` for null. Both callbacks that reach this treat null as a real, documented outcome
/// rather than an error: a compression handler with no sample buffer is a dropped frame, and a
/// decompression handler with no image buffer is a frame the decoder declined to emit.
///
/// # Safety
/// The caller must have obtained `raw` as a borrowed +0 reference of the declared type, live for
/// the duration of the current call. Not marked `unsafe` for the reason [`created`] gives.
pub(crate) fn borrowed<T: Type>(raw: *mut T) -> Option<CFRetained<T>> {
    // SAFETY: framework rule — the Get rule says this reference is live for the call and that a
    // holder retains, which is exactly what `CFRetained::retain` does and undoes.
    #[expect(
        unsafe_code,
        reason = "the Get-rule borrowed pointer; docs/57 §2 admits this shape, at ONE site"
    )]
    NonNull::new(raw).map(|ptr| unsafe { CFRetained::retain(ptr) })
}

#[cfg(test)]
mod tests {
    use objc2_core_foundation::{CFArray, CFRetained, CFString, CFType};

    use super::{borrowed, created};

    /// A real heap object to count references on. NOT a `CFString`: `CFGetRetainCount` is
    /// documented as answering `usize::MAX` for the small-string and tagged-number
    /// optimisations, so a leak test built on one would pass whether or not the retain was ever
    /// released.
    fn subject() -> CFRetained<CFArray<CFType>> {
        let member = CFString::from_str("slopdesk");
        CFArray::from_objects(&[&**member])
    }

    /// Null is the frameworks' own "I wrote nothing", on both rules.
    #[test]
    fn a_null_pointer_is_an_absence_under_both_rules() {
        assert!(created::<CFString>(core::ptr::null_mut()).is_none());
        assert!(borrowed::<CFString>(core::ptr::null_mut()).is_none());
    }

    /// A hundred thousand round trips through the Get-rule helper against ONE object. If `retain`
    /// were not paired with the `CFRetained` drop, this would leave the array at `+100_000` and the
    /// assertion below — which reads the count the runtime actually holds — would say so.
    ///
    /// This is the crate's leak test for the admissions themselves, which `docs/57` §3 asks every
    /// family crate for. The sessions they guard cannot be created headlessly; the ownership can.
    #[test]
    fn a_hundred_thousand_get_rule_retains_leave_the_count_where_they_found_it() {
        let held = subject();
        let raw = CFRetained::as_ptr(&held).as_ptr();
        let before = held.retain_count();
        for _ in 0..100_000_u32 {
            let taken = borrowed(raw);
            assert!(taken.is_some(), "a live pointer is not null");
            assert_eq!(taken.map(|array| array.len()), Some(1));
        }
        assert_eq!(
            held.retain_count(),
            before,
            "every retain was released by its scope"
        );
    }

    /// The Create-rule helper's own round trip, built from a real +1: `CFArray::from_objects`
    /// answers an owned reference, and handing its raw pointer to `created` transfers exactly
    /// that ownership rather than adding one. A hundred thousand times, so a double-take would
    /// exhaust rather than merely mis-count.
    #[test]
    fn a_create_rule_pointer_is_taken_over_rather_than_retained_again() {
        for _ in 0..100_000_u32 {
            let raw = CFRetained::into_raw(subject());
            let taken = created(raw.as_ptr());
            assert!(taken.is_some(), "a live pointer is not null");
            assert_eq!(
                taken.map(|array| array.retain_count()),
                Some(1),
                "the +1 moved rather than doubling",
            );
        }
    }
}
