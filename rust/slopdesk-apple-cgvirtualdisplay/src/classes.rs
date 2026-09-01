//! The four private classes, resolved ONCE through the Objective-C runtime.
//!
//! This is the ONLY file in the repository that spells a `CGVirtualDisplay*` class name;
//! `rust/slopdesk-invariants`' `apple_floors` rule pins that, so a second home for the area cannot
//! grow quietly. Every other module here takes a resolved [`Classes`] and sends messages to it.
//!
//! Resolution is all-or-nothing on purpose: a process that found three of the four would build a
//! descriptor and then fail at the message send that matters, which is exactly the late crash the
//! runtime lookup exists to prevent.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use std::sync::LazyLock;

use objc2::runtime::AnyClass;

/// The four `CGVirtualDisplay*` classes, all present or none of them.
///
/// `Copy` because it is four `'static` class pointers and callers pass it down by value; the
/// Objective-C runtime owns the classes for the process lifetime.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Classes {
    /// `CGVirtualDisplay` — the registration object.
    pub(crate) display: &'static AnyClass,
    /// `CGVirtualDisplayDescriptor` — what `WindowServer` is told before the display exists.
    pub(crate) descriptor: &'static AnyClass,
    /// `CGVirtualDisplaySettings` — what it is told after.
    pub(crate) settings: &'static AnyClass,
    /// `CGVirtualDisplayMode` — one advertised point grid at one refresh rate.
    pub(crate) mode: &'static AnyClass,
}

impl Classes {
    /// Looks the four up by name, answering `None` the moment one is missing.
    ///
    /// `objc_getClass` is a pure lookup: it neither loads a library nor instantiates anything, so
    /// calling it on a machine whose `CoreGraphics` dropped the area is inert.
    fn resolve() -> Option<Self> {
        Some(Self {
            display: AnyClass::get(c"CGVirtualDisplay")?,
            descriptor: AnyClass::get(c"CGVirtualDisplayDescriptor")?,
            settings: AnyClass::get(c"CGVirtualDisplaySettings")?,
            mode: AnyClass::get(c"CGVirtualDisplayMode")?,
        })
    }
}

/// The one resolution, cached for the process lifetime — including a cached FAILURE, so an OS
/// without the area pays four `objc_getClass` calls once rather than on every mint.
static CLASSES: LazyLock<Option<Classes>> = LazyLock::new(Classes::resolve);

/// The resolved classes, or `None` on an OS that no longer has all four.
pub(crate) fn classes() -> Option<Classes> {
    *CLASSES
}

/// Whether this process can create a virtual display at all.
///
/// Answering `false` is the documented degradation: the caller falls back to capturing a real
/// display at 1×. Nothing is instantiated, and the answer is cached, so it is safe to ask on every
/// pane mint.
#[must_use]
pub fn private_classes_available() -> bool {
    classes().is_some()
}

/// Says which law went unchecked when the four classes are absent, rather than letting a test pass
/// silently and read as coverage.
#[cfg(test)]
#[expect(
    clippy::print_stderr,
    reason = "a skipped hardware-gated test must say so out loud"
)]
pub(crate) fn skipped(law: &str) {
    eprintln!("skipped `{law}`: this OS's CoreGraphics has no CGVirtualDisplay* classes");
}

#[cfg(test)]
mod tests {
    use super::{classes, private_classes_available, skipped};

    /// The cache is a cache: a second ask must not re-enter the runtime and must not hand back a
    /// different class object. If the `LazyLock` were dropped for a plain call, two mints could
    /// build a descriptor from one resolution and a display from another.
    #[test]
    fn resolving_the_classes_twice_returns_the_same_pointers() {
        let (Some(first), Some(second)) = (classes(), classes()) else {
            skipped("resolving_the_classes_twice_returns_the_same_pointers");
            return;
        };
        assert!(core::ptr::eq(first.display, second.display), "display class");
        assert!(
            core::ptr::eq(first.descriptor, second.descriptor),
            "descriptor class",
        );
        assert!(core::ptr::eq(first.settings, second.settings), "settings class");
        assert!(core::ptr::eq(first.mode, second.mode), "mode class");
    }

    /// The public gate and the private resolution are one answer, not two: if they could disagree,
    /// a caller could be told the area exists and then be handed `None` at the first send.
    #[test]
    fn the_gate_agrees_with_the_resolution() {
        assert_eq!(private_classes_available(), classes().is_some());
    }
}
