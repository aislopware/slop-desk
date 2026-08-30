//! This crate's ONE Get-rule claim, and the only place a borrowed framework pointer becomes an
//! owned value.
//!
//! `docs/57` §2 admits the Get-rule retain at a single site per crate — `CFRetained::retain` for a
//! Core Foundation type, and `Retained::retain` for the Objective-C twin, which is what
//! `ScreenCaptureKit` hands over. Both spellings are the same convention: a function whose name
//! contains neither `Copy` nor `Create`, and every completion-handler argument, is a +0 reference
//! valid only for the duration of the call, and a holder that wants it afterwards retains.
//!
//! This crate reaches that shape TWICE — `getShareableContent…`'s content object and the `NSError`
//! every lifecycle handler carries — and `objc2` generates both as a bare `*mut T` because the C
//! block signature says nothing about ownership. Written inline that is two sites and a §2
//! violation; written here it is one, and the argument for it is made once instead of twice.
//!
//! Not `unsafe` to CALL, for the reason `slopdesk-apple-vt`'s `owned` module states in full: the
//! helper answers `None` for null, so the only way to misuse it is to hand it a pointer of the
//! wrong PROVENANCE — a question about which framework wrote it, answered at the call site by the
//! `# Safety` note naming the rule, not a question about the pointer's validity.

// A lint CONFLICT rather than a preference, the same one the vt and ax modules record: these items
// are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the only accurate
// visibility, and this nursery lint asks for the `pub` that the denied `unreachable_pub` refuses.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use objc2::Message;
use objc2::rc::Retained;

/// Takes a reference of this crate's own to a **Get-rule** pointer: one borrowed for a call.
///
/// Answers `None` for null, and null is a real outcome at both call sites rather than a bug: a
/// content query that failed hands the handler no content, and a lifecycle step that succeeded
/// hands it no error. Neither is a case for a status code — the frameworks state the outcome BY
/// the null, and reading it here is what makes the two call sites total functions.
///
/// # Safety
/// The caller must have obtained `raw` as a borrowed +0 reference of the declared type, live for
/// the duration of the current call. Not marked `unsafe` because the obligation is about the
/// pointer's PROVENANCE rather than about the pointer — see the module header.
pub(crate) fn borrowed<T: Message>(raw: *mut T) -> Option<Retained<T>> {
    // SAFETY: framework rule — the Get rule says this reference is live for the call and that a
    // holder takes one of its own, which is exactly what `Retained::retain` does and undoes.
    #[expect(
        unsafe_code,
        reason = "the Get-rule borrowed pointer; docs/57 §2 admits this shape, at ONE site"
    )]
    unsafe {
        Retained::retain(raw)
    }
}

#[cfg(test)]
mod tests {
    use objc2::rc::Retained;
    use objc2_foundation::{NSError, NSString};

    use super::borrowed;

    #[test]
    fn a_null_pointer_is_the_frameworks_own_answer_rather_than_a_retain_of_nothing() {
        assert!(borrowed(core::ptr::null_mut::<NSError>()).is_none());
    }

    /// The retain has to be a real one — a helper that handed back a reference without taking
    /// ownership would read identically at both call sites and die at the end of the block.
    #[test]
    fn a_live_object_survives_the_borrow_and_the_original_release() {
        let original = NSString::from_str("shareable");
        let taken = borrowed(Retained::as_ptr(&original).cast_mut());
        drop(original);
        assert_eq!(
            taken.map(|taken| taken.to_string()),
            Some(String::from("shareable"))
        );
    }
}
