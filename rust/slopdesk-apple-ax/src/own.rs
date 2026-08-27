//! The crate's ONE Copy/Create-rule claim, and the only place a raw Core Foundation pointer becomes
//! an owned value.
//!
//! `docs/57` §2 admits `CFRetained::from_raw` at a single site per crate, so that every typed
//! reader is a CALLER of that site rather than a second obligation a reviewer has to check again.
//! Two entry points in this crate hand their result back through an out-parameter —
//! `AXUIElementCopyAttributeValue` (Copy rule) and `AXObserverCreate` (Create rule) — and Apple's
//! naming convention is what says both leave a +1 retain behind. That sentence is written once,
//! here.

// Same lint conflict `attribute` records: these items are the crate's internal vocabulary and no
// part of its API, so `pub(crate)` is the accurate visibility and `unreachable_pub` refuses the
// `pub` this nursery lint asks for.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use core::ptr::NonNull;

use objc2_core_foundation::{CFRetained, Type};

/// Takes ownership of the reference a Copy/Create-rule out-parameter left in `slot`.
///
/// `None` for a null slot, which is what every one of these entry points leaves behind when it
/// declines to write — the callers below check the framework's own status first, and this is the
/// second gate rather than the only one.
///
/// # Safety
/// The call that wrote `slot` must be one Core Foundation's naming convention covers — its name
/// carries `Copy` or `Create` — and must have REPORTED SUCCESS, because on any other result the
/// framework leaves the slot untouched and whatever it was initialised to is not a reference.
/// `slot` must hold null or a live pointer of type `T` that this call stored and nobody else has
/// claimed; claiming it twice would release it twice.
#[expect(
    unsafe_code,
    reason = "docs/57 §2's Copy/Create-rule admission, at this crate's one site"
)]
pub(crate) unsafe fn claimed<T: ?Sized + Type>(slot: *mut T) -> Option<CFRetained<T>> {
    let value = NonNull::new(slot)?;
    // SAFETY: the caller's obligation, above — a Copy/Create-rule reference, reported written, and
    // claimed exactly once.
    Some(unsafe { CFRetained::from_raw(value) })
}
