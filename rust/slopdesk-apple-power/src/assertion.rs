//! The one held assertion, and the two types this repository raises.

use objc2_core_foundation::{CFRetained, CFString};
use objc2_io_kit::{
    IOPMAssertionCreateWithName, IOPMAssertionID, IOPMAssertionRelease, kIOPMAssertionLevelOn,
    kIOReturnSuccess,
};

/// Which idle timer the assertion holds off.
///
/// Two, because this repository raises two and neither is a substitute for the other: an agent
/// working through the night must not let the MACHINE sleep, and a client watching the desktop must
/// not let the SCREEN go dark, but an agent working with nobody watching should still let the
/// screen go dark. The `CFSTR` type names are spelled here because they are `#define`s in
/// `IOPMLib.h` — a macro has no symbol for a binding generator to export, so this is the one place
/// in the crate where a string comes from the header by hand rather than from the metadata.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SleepKind {
    /// `kIOPMAssertionTypePreventUserIdleSystemSleep` — the Mac stays awake; the display may still
    /// sleep on its own timer.
    System,
    /// `kIOPMAssertionTypePreventUserIdleDisplaySleep` — the display stays lit, which implies the
    /// machine stays awake too.
    Display,
}

impl SleepKind {
    /// The assertion-type string `IOPMLib.h` documents for this kind.
    const fn type_name(self) -> &'static str {
        match self {
            Self::System => "PreventUserIdleSystemSleep",
            Self::Display => "PreventUserIdleDisplaySleep",
        }
    }
}

/// A SINGLE power assertion, driven to a desired state and strictly balanced.
///
/// Not `Clone` and not `Copy` by construction: two owners of one id would each release it, and the
/// second release is the double-free `IOPMLib.h` warns about. `&mut self` on the one mutating call
/// is what makes "no overlapping calls" a compiler property here rather than a caller's obligation.
#[derive(Debug)]
pub struct SleepAssertion {
    kind: SleepKind,
    /// The name shown in `pmset -g assertions`. Diagnostic only, and retained once at construction
    /// rather than rebuilt per edge — a `CFString` allocation on every transition would be the kind
    /// of per-call cost this whole boundary exists to avoid.
    reason: CFRetained<CFString>,
    /// `Some` exactly while the assertion is held. The single copy of the id, by design.
    held: Option<IOPMAssertionID>,
}

impl SleepAssertion {
    /// A released assertion of `kind`, named `reason` for `pmset -g assertions`.
    ///
    /// Nothing is asserted yet: construction is free and cannot fail, so a caller can hold one for
    /// the process lifetime and let the edges decide when the system is actually told anything.
    #[must_use]
    pub fn new(kind: SleepKind, reason: &str) -> Self {
        Self {
            kind,
            reason: CFString::from_str(reason),
            held: None,
        }
    }

    /// Whether the assertion is currently held.
    #[must_use]
    pub const fn is_held(&self) -> bool {
        self.held.is_some()
    }

    /// Drives the assertion to `desired` and answers the state it actually reached.
    ///
    /// Idempotent in both steady states. A create that the system refuses answers `false` and
    /// leaves nothing held, so the next false→true edge tries again — the alternative,
    /// remembering a failure, turns one refused call into a session that never keeps the Mac
    /// awake.
    pub fn set_asserted(&mut self, desired: bool) -> bool {
        match (desired, self.held) {
            (true, None) => {
                let mut id: IOPMAssertionID = 0;
                let name = CFString::from_static_str(self.kind.type_name());
                // SAFETY: framework rule. `IOPMAssertionCreateWithName` documents that on success
                // it writes ONE unique reference through `AssertionID`; `id` is a
                // fully initialised local that outlives the call, and nothing on
                // this side reads through the pointer. Both `CFString` arguments
                // are live for the duration of the call — `name` is a local binding
                // held across it, and `reason` is owned by `self`.
                #[expect(
                    unsafe_code,
                    reason = "the assertion create reports its new id through an out-pointer; objc2 cannot \
                              generate it safe"
                )]
                let result = unsafe {
                    IOPMAssertionCreateWithName(
                        Some(&name),
                        kIOPMAssertionLevelOn,
                        Some(&self.reason),
                        &raw mut id,
                    )
                };
                // Validate-then-default: `id` is only trusted on the return code the header names.
                if result == kIOReturnSuccess {
                    self.held = Some(id);
                }
            },
            (false, Some(id)) => {
                // Cleared BEFORE the release, not after: if the release ever unwound, a retained
                // `Some(id)` would let `drop` release the same id a second time. `objc2` generates
                // the release SAFE — it takes the id by value and dereferences nothing — so the
                // once-per-create rule is kept by this type owning the only copy of `id`, not by an
                // `unsafe` block claiming it.
                self.held = None;
                let _ = IOPMAssertionRelease(id);
            },
            // Already in the desired state: the system is told nothing, which is the whole reason
            // the caller may drive this on every edge without counting.
            _ => {},
        }
        self.is_held()
    }
}

#[cfg(test)]
impl SleepAssertion {
    /// The reference count on the reason string, for §3's leak check. Test-only: nothing in the
    /// running system has a use for it, and exposing it would invite one.
    fn reason_retain_count(&self) -> usize {
        self.reason.retain_count()
    }
}

impl Drop for SleepAssertion {
    /// The final balance: a daemon teardown that forgot to release must not leave the Mac awake.
    fn drop(&mut self) {
        self.set_asserted(false);
    }
}

#[cfg(test)]
mod tests {
    use super::{SleepAssertion, SleepKind};

    /// Half of §3's LEAK test — the KERNEL half. A real assertion is created and released ten
    /// thousand times; if the generated binding got the create/release pairing wrong, the
    /// kernel-side assertion table for this process grows without bound and the create eventually
    /// starts failing, so a run that ends still able to assert is the evidence that every one of
    /// the previous ones let go. The Core Foundation half is
    /// [`the_reason_string_is_not_retained_by_the_edges`] below; neither covers the other, because
    /// the two resources this crate touches leak independently.
    ///
    /// Real `IOKit` calls are deliberate. The hang-safety rule this repository keeps is about
    /// resources that BLOCK — a capture stream, a video encoder, a PTY read — and a power assertion
    /// is a synchronous registration with no callback and no wait. A fake here would be the
    /// cross-language mirror the tree forbids, one language further along.
    #[test]
    fn ten_thousand_balanced_cycles_can_still_assert_at_the_end() {
        let mut assertion = SleepAssertion::new(SleepKind::System, "slopdesk: leak test");
        for _ in 0..10_000 {
            assert!(assertion.set_asserted(true));
            assert!(!assertion.set_asserted(false));
        }
        assert!(assertion.set_asserted(true));
        assert!(assertion.is_held());
    }

    /// Ten thousand assertions each created and DROPPED still held — the same leak, reached through
    /// the destructor instead of an edge. This is the path a daemon teardown takes.
    #[test]
    fn ten_thousand_dropped_while_held_do_not_exhaust_the_assertion_table() {
        for _ in 0..10_000 {
            let mut assertion = SleepAssertion::new(SleepKind::Display, "slopdesk: drop test");
            assert!(assertion.set_asserted(true));
        }
        let mut after = SleepAssertion::new(SleepKind::Display, "slopdesk: drop test");
        assert!(after.set_asserted(true));
    }

    /// Driving to the state already held is a no-op that reports the truth — the property that lets
    /// the folds upstream call this on every transition without tracking edges themselves.
    #[test]
    fn redundant_drives_are_no_ops_that_still_report_the_state() {
        let mut assertion = SleepAssertion::new(SleepKind::System, "slopdesk: idempotence test");
        assert!(!assertion.is_held());
        assert!(!assertion.set_asserted(false));
        assert!(assertion.set_asserted(true));
        assert!(assertion.set_asserted(true));
        assert!(assertion.is_held());
        assert!(!assertion.set_asserted(false));
        assert!(!assertion.set_asserted(false));
        assert!(!assertion.is_held());
    }

    /// The other half of §3's LEAK test — the CORE FOUNDATION one, and the reason the kernel checks
    /// above do not stand in for it: an assertion table that keeps balance says nothing about the
    /// `CFString` this type owns. `IOPMAssertionCreateWithName` is handed `reason` on every
    /// false→true edge, and if the binding retained it without a matching release — or if `IOKit`
    /// itself kept a reference past the release — the count would climb once per edge while every
    /// other test in this module stayed green. Counted rather than measured as a footprint for
    /// `slopdesk-apple-cgevent`'s reason: on macOS the resident size is the malloc zone's
    /// high-water mark and does not fall when a CF object is released.
    #[test]
    fn the_reason_string_is_not_retained_by_the_edges() {
        let mut assertion = SleepAssertion::new(SleepKind::System, "slopdesk: cf retain test");
        let before = assertion.reason_retain_count();
        assert_eq!(before, 1, "create rule: one reference, freshly built");
        for _ in 0..1_000 {
            assert!(assertion.set_asserted(true));
            assert!(!assertion.set_asserted(false));
        }
        assert_eq!(
            assertion.reason_retain_count(),
            before,
            "a thousand edges left references behind on the reason string"
        );
    }

    /// The two kinds are two assertions, not one shared registration: holding the system one must
    /// not report the display one as held, which is the confusion a single global flag would
    /// invite.
    #[test]
    fn the_two_kinds_are_independent_assertions() {
        let mut system = SleepAssertion::new(SleepKind::System, "slopdesk: system");
        let display = SleepAssertion::new(SleepKind::Display, "slopdesk: display");
        assert!(system.set_asserted(true));
        assert!(!display.is_held());
    }
}
