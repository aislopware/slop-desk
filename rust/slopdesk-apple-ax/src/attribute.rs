//! One attribute of one element, read or written, with the framework's rules named once each.
//!
//! Every typed reader and writer in the crate goes through [`copy`] or [`set`], which is the point:
//! the AX attribute API is a COPY-rule out-parameter in one direction and a `CFTypeRef` of an
//! attribute-specific class in the other, and stating either obligation more than once is how a
//! reviewer stops checking it.

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2_application_services::{AXError, AXUIElement, AXValue, AXValueType};
use objc2_core_foundation::{CFArray, CFBoolean, CFNumber, CFRetained, CFString, CFType, CGPoint, CGSize};

/// The value of `attribute` on `element`, or `None` when the read did not produce one.
///
/// `None` is every failure at once, deliberately: the attribute is unsupported on this element, the
/// app is unresponsive and the messaging timeout fired, accessibility is off, the element is stale,
/// or the value is simply absent. Not one caller in this crate distinguishes them — each has the
/// same fallback — and an error type they all discard would be a type that lies about being read.
///
/// # Safety
/// `AXUIElementCopyAttributeValue` takes a pointer to a caller-owned slot and, on success, stores a
/// `CFTypeRef` in it under the **Copy rule** — the caller owns a reference and must release it.
/// `CFRetained::from_raw` is that release, moved into the type system, and it is applied to exactly
/// the pointer the framework just stored and only after the call reported success. The slot is a
/// live local of the declared type for the whole call; on any non-success the framework leaves it
/// untouched, and the null it was initialised to is checked before anything is claimed from it.
#[expect(
    unsafe_code,
    reason = "the AX attribute read is a Copy-rule out-parameter; docs/57 §2 admits this shape"
)]
pub(crate) fn copy(element: &AXUIElement, attribute: &str) -> Option<CFRetained<CFType>> {
    let name = CFString::from_str(attribute);
    let mut slot: *const CFType = core::ptr::null();
    // SAFETY: framework rule, above — the out-parameter's slot is live and correctly typed.
    let status = unsafe { element.copy_attribute_value(&name, NonNull::from(&mut slot)) };
    if status != AXError::Success {
        return None;
    }
    let value = NonNull::new(slot.cast_mut())?;
    // SAFETY: framework rule, above — the Copy rule made this reference ours to release.
    Some(unsafe { CFRetained::from_raw(value) })
}

/// Writes `value` to `attribute` on `element`; answers whether the framework accepted it.
///
/// # Safety
/// `AXUIElementSetAttributeValue` requires the value to be of the class the attribute expects, and
/// every caller in this crate pairs a name with the type the Accessibility header documents for it:
/// `AXPosition` with a `CGPoint` `AXValue`, `AXSize` with a `CGSize` one, `AXMinimized` with a
/// `CFBoolean`, `AXMainWindow`/`AXFocusedWindow` with an `AXUIElement`. A window that does not
/// accept the write answers `kAXErrorAttributeUnsupported`, which is a value, not a fault.
#[expect(
    unsafe_code,
    reason = "the binding cannot check a value's class against an attribute name; the header can"
)]
pub(crate) fn set(element: &AXUIElement, attribute: &str, value: &CFType) -> bool {
    let name = CFString::from_str(attribute);
    // SAFETY: framework rule, above — name and class are paired at every call site.
    unsafe { element.set_attribute_value(&name, value) == AXError::Success }
}

/// The `CGPoint` stored at `attribute`, or `None` when it is absent or is not one.
///
/// # Safety
/// `AXValueGetValue` copies the encoded structure into the caller's slot only when the value's own
/// encoded type matches the one asked for, and reports which happened — so the slot's type and the
/// [`AXValueType`] are what must agree, and here both say `CGPoint`. The slot is a live local that
/// outlives the call, and it is read only when the framework reports it wrote.
#[expect(unsafe_code, reason = "AXValueGetValue writes through a caller-owned slot")]
pub(crate) fn point(element: &AXUIElement, attribute: &str) -> Option<CGPoint> {
    let value = copy(element, attribute)?.downcast::<AXValue>().ok()?;
    let mut point = CGPoint::ZERO;
    // SAFETY: framework rule, above — the slot is a live `CGPoint` and `CGPoint` is what is asked.
    let wrote = unsafe { value.value(AXValueType::CGPoint, NonNull::from(&mut point).cast::<c_void>()) };
    wrote.then_some(point)
}

/// The `CGSize` stored at `attribute`, or `None` when it is absent or is not one.
///
/// # Safety
/// [`point`]'s, with `CGSize` in both places instead of `CGPoint`.
#[expect(unsafe_code, reason = "AXValueGetValue writes through a caller-owned slot")]
pub(crate) fn size(element: &AXUIElement, attribute: &str) -> Option<CGSize> {
    let value = copy(element, attribute)?.downcast::<AXValue>().ok()?;
    let mut size = CGSize::ZERO;
    // SAFETY: framework rule, above — the slot is a live `CGSize` and `CGSize` is what is asked.
    let wrote = unsafe { value.value(AXValueType::CGSize, NonNull::from(&mut size).cast::<c_void>()) };
    wrote.then_some(size)
}

/// The boolean stored at `attribute`, or `None` when it is absent or is not one.
pub(crate) fn flag(element: &AXUIElement, attribute: &str) -> Option<bool> {
    Some(copy(element, attribute)?.downcast::<CFBoolean>().ok()?.value())
}

/// The string stored at `attribute`, or `None` when it is absent or is not one.
///
/// A `String` rather than a borrow, because the `CFString` is released when this returns and every
/// caller compares the value against a literal — the copy is one small allocation per node of a
/// walk that is already paying for out-of-process IPC at each one.
pub(crate) fn text(element: &AXUIElement, attribute: &str) -> Option<String> {
    Some(copy(element, attribute)?.downcast::<CFString>().ok()?.to_string())
}

/// The integer stored at `attribute`, widened to `i64`, or `None` when it is absent or is not one.
///
/// `CFNumber` does not remember which C type it was built from, so asking for the widest signed one
/// is the reading that cannot truncate whatever the framework chose.
pub(crate) fn number(element: &AXUIElement, attribute: &str) -> Option<i64> {
    copy(element, attribute)?.downcast::<CFNumber>().ok()?.as_i64()
}

/// The single element stored at `attribute`, stamped with `timeout_seconds`.
///
/// The stamp is the point of doing this here. An element that arrives as an attribute VALUE carries
/// the framework's ~6 second default rather than the element it was read from — the cap is a
/// per-reference client-side property, not an inherited one — so a walk that skipped this would
/// have exactly one uncapped reference per level.
pub(crate) fn element(
    element: &AXUIElement,
    attribute: &str,
    timeout_seconds: f32,
) -> Option<CFRetained<AXUIElement>> {
    let found = copy(element, attribute)?.downcast::<AXUIElement>().ok()?;
    stamp(&found, timeout_seconds);
    Some(found)
}

/// The elements stored at `attribute`, each stamped with `timeout_seconds`.
///
/// Empty covers a real absence and a refusal alike: no such attribute, no children, a pid that is
/// gone, accessibility not granted. Every caller's next step is the same, so the distinction has no
/// reader.
///
/// # Safety
/// The Accessibility header documents `AXWindows`, `AXChildren` and the menu attributes as arrays
/// of `AXUIElementRef`. C's `CFArrayRef` has nowhere to say so, which is why the read hands back an
/// untyped array; this states it once for every caller. Nothing is dereferenced — the typed view
/// only decides which `get` applies, and `to_vec` retains each element it hands out.
#[expect(
    unsafe_code,
    reason = "C's CFArrayRef carries no element type; the Accessibility header is where it lives"
)]
pub(crate) fn elements(
    element: &AXUIElement,
    attribute: &str,
    timeout_seconds: f32,
) -> Vec<CFRetained<AXUIElement>> {
    let Some(array) = copy(element, attribute).and_then(|value| value.downcast::<CFArray>().ok()) else {
        return Vec::new();
    };
    // SAFETY: framework rule, above — the Accessibility header documents these as element arrays.
    let typed = unsafe { CFRetained::cast_unchecked::<CFArray<AXUIElement>>(array) };
    let found = typed.to_vec();
    for one in &found {
        stamp(one, timeout_seconds);
    }
    found
}

/// Cap every later message to `element` at `timeout_seconds`.
///
/// # Safety
/// `AXUIElementSetMessagingTimeout` accepts any non-negative float and treats zero as "restore the
/// default". The value is the caller's and is passed through unexamined, because a caller asking
/// for no cap is asking for the framework's own behaviour. This is a local client-side property
/// set: no IPC, and nothing to fail.
#[expect(
    unsafe_code,
    reason = "objc2 generates the bare AX entry points unsafe; the cap has no other obligation"
)]
pub(crate) fn stamp(element: &AXUIElement, timeout_seconds: f32) {
    // SAFETY: framework rule, above — any non-negative float is a legal cap.
    let _ = unsafe { element.set_messaging_timeout(timeout_seconds) };
}

/// Writes a `CGPoint` to `attribute`; answers whether the framework accepted it.
///
/// # Safety
/// `AXValueCreate` copies the structure the pointer names, choosing how many bytes by the
/// [`AXValueType`] it is told — so the two must agree, and here both say `CGPoint`. The local
/// outlives the call, and `AXValueCreate` copies rather than borrows, so nothing escapes it.
#[expect(
    unsafe_code,
    reason = "AXValueCreate reads a caller-owned struct through a pointer"
)]
pub(crate) fn set_point(element: &AXUIElement, attribute: &str, point: CGPoint) -> bool {
    let mut point = point;
    // SAFETY: framework rule, above — a live `CGPoint` described as a `CGPoint`.
    let value = unsafe { AXValue::new(AXValueType::CGPoint, NonNull::from(&mut point).cast::<c_void>()) };
    value.is_some_and(|value| set(element, attribute, &value))
}

/// Writes a `CGSize` to `attribute`; answers whether the framework accepted it.
///
/// # Safety
/// [`set_point`]'s, with `CGSize` in both places instead of `CGPoint`.
#[expect(
    unsafe_code,
    reason = "AXValueCreate reads a caller-owned struct through a pointer"
)]
pub(crate) fn set_size(element: &AXUIElement, attribute: &str, size: CGSize) -> bool {
    let mut size = size;
    // SAFETY: framework rule, above — a live `CGSize` described as a `CGSize`.
    let value = unsafe { AXValue::new(AXValueType::CGSize, NonNull::from(&mut size).cast::<c_void>()) };
    value.is_some_and(|value| set(element, attribute, &value))
}

/// Writes a boolean to `attribute`; answers whether the framework accepted it.
pub(crate) fn set_flag(element: &AXUIElement, attribute: &str, flag: bool) -> bool {
    set(element, attribute, CFBoolean::new(flag))
}

/// Performs `action` on `element`; answers whether the framework accepted it.
///
/// # Safety
/// `AXUIElementPerformAction` requires an action name the element actually publishes, and the one
/// caller passes `AXRaise`, which every window element publishes. An element that does not answers
/// `kAXErrorActionUnsupported`, and a stale one `kAXErrorInvalidUIElement` — both are values here,
/// which is the property that lets a cached element be used without first re-validating it.
#[expect(
    unsafe_code,
    reason = "the binding cannot check an action name against an element"
)]
pub(crate) fn perform(element: &AXUIElement, action: &str) -> bool {
    let name = CFString::from_str(action);
    // SAFETY: framework rule, above.
    unsafe { element.perform_action(&name) == AXError::Success }
}
