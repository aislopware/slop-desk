//! One attribute of one element, read or written, with the framework's rules named once each.
//!
//! Every typed reader and writer in the crate goes through [`copy`] or [`set`], which is the point:
//! the AX attribute API is a COPY-rule out-parameter in one direction and a `CFTypeRef` of an
//! attribute-specific class in the other, and stating either obligation more than once is how a
//! reviewer stops checking it.

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2_application_services::{AXError, AXUIElement, AXValue, AXValueType};
use objc2_core_foundation::{CFBoolean, CFRetained, CFString, CFType, CGPoint, CGSize};

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
