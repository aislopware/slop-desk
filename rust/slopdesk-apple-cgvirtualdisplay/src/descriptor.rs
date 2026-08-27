//! The `CGVirtualDisplayDescriptor` — everything `WindowServer` is told BEFORE the display exists.
//!
//! A descriptor is inert: building one sends no IPC and registers nothing, which is why this module
//! is fully testable while the two modules on either side of it are not.
//!
//! Two of the twelve properties are load-bearing in a way their names do not show:
//!
//! - `vendorID` must be NON-ZERO. A zero vendor makes `initWithDescriptor:` answer `nil`, with no
//!   other diagnostic anywhere.
//! - the colour primaries must be the CACHED sRGB ones. A custom profile makes `WindowServer` ask
//!   `colorsyncd` to build one, and that request can deadlock against `WindowServer`'s own render
//!   threads while this process is blocked in `initWithDescriptor:`.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use block2::{Block, RcBlock};
use dispatch2::{DispatchQueue, DispatchRetained};
use objc2::msg_send;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Sel};
use objc2_core_foundation::{CGPoint, CGSize};
use objc2_foundation::{NSNumber, NSString};
use slopdesk_video::virtual_display::{DEFAULT_TARGET_PPI, Geometry};

use crate::classes::Classes;

/// The block the `terminationHandler` property holds: `void (^)(id, id)`.
///
/// Both arguments are IGNORED and never dereferenced. `WindowServer` passes a display object and a
/// reason object whose types are as undocumented as the classes themselves, and the only thing the
/// daemon does with a termination is drop the display it already knows about.
pub(crate) type TerminationBlock = Block<dyn Fn(*mut AnyObject, *mut AnyObject)>;

/// The owner's OWN reference to the termination block.
///
/// The descriptor copies the block into its `terminationHandler` property, so the descriptor is
/// normally its only owner — which would make [`neutralise`] free a block that may be RUNNING on
/// the delivery queue at that moment. Keeping a second reference beside the descriptor for the
/// whole life of the registration is what makes teardown safe to start from any thread.
pub(crate) struct HeldBlock(
    #[expect(
        dead_code,
        reason = "the reference IS the point: holding it is what keeps a running block alive"
    )]
    pub(crate) RcBlock<dyn Fn(*mut AnyObject, *mut AnyObject)>,
);

// SAFETY: framework rule. A block on the heap is a reference-counted Objective-C object, and
// `Block_copy`/`Block_release` are the runtime's own thread-safe refcount operations — so MOVING a
// strong reference between threads is supported. This wrapper only ever moves one; the block's own
// body is what runs concurrently, and it is `Fn` over a `Weak`, which is `Send + Sync` in its own
// right. `Sync` is not claimed, because nothing shares this wrapper.
#[expect(
    unsafe_code,
    reason = "objc2 cannot promise thread-safety for a block whose captures it cannot see; this is that \
              judgement"
)]
#[expect(
    clippy::non_send_fields_in_send_ty,
    reason = "the field is a heap block; the promise is the runtime's"
)]
unsafe impl Send for HeldBlock {}

impl core::fmt::Debug for HeldBlock {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.debug_struct("HeldBlock").finish_non_exhaustive()
    }
}

/// An arbitrary non-zero vendor. Zero is the one value `initWithDescriptor:` rejects outright.
const VENDOR_ID: u32 = 0xEEEE;
/// The product, cosmetic — it only reaches the display's Info panel.
const PRODUCT_ID: u32 = 0x0001;
/// The serial, cosmetic, and set only when the running class admits to a setter for it.
const SERIAL: u32 = 0x0001;

/// CIE xy of the sRGB (IEC 61966-2.1) D65 white point.
const WHITE_POINT: CGPoint = CGPoint { x: 0.3127, y: 0.3290 };
/// CIE xy of the sRGB red primary.
const RED_PRIMARY: CGPoint = CGPoint { x: 0.6400, y: 0.3300 };
/// CIE xy of the sRGB green primary.
const GREEN_PRIMARY: CGPoint = CGPoint { x: 0.3000, y: 0.6000 };
/// CIE xy of the sRGB blue primary.
const BLUE_PRIMARY: CGPoint = CGPoint { x: 0.1500, y: 0.0600 };

/// The label of the queue `WindowServer` delivers the termination handler on.
const TERMINATION_QUEUE: &str = "slopdesk.video.vd.termination";

/// Builds a fully populated descriptor for `geometry`, named `name`, delivering termination to
/// `on_terminated`.
///
/// Answers the descriptor AND the queue `WindowServer` will deliver on. The caller keeps the queue
/// because teardown has to be ordered against it: it is SERIAL, so anything enqueued on it runs
/// after an in-flight handler has returned, and that is the only way to free the block without
/// racing an invocation of it.
pub(crate) fn build(
    classes: Classes,
    geometry: &Geometry,
    name: &str,
    on_terminated: &RcBlock<dyn Fn(*mut AnyObject, *mut AnyObject)>,
) -> (Retained<AnyObject>, DispatchRetained<DispatchQueue>) {
    // A degenerate request is answered on the side that also decides what it means for the
    // pixel-limit guard; `try_from` here is the WIDTH conversion, and it cannot fail for a geometry
    // that passed that guard.
    let pixels_wide = u32::try_from(geometry.pixel_width()).unwrap_or(0);
    let pixels_high = u32::try_from(geometry.pixel_height()).unwrap_or(0);
    let (width_mm, height_mm) = geometry.size_in_millimeters(DEFAULT_TARGET_PPI);
    let millimetres = CGSize {
        width: width_mm,
        height: height_mm,
    };
    let label = NSString::from_str(name);
    let queue = DispatchQueue::new(TERMINATION_QUEUE, None);

    // SAFETY: Objective-C runtime rule. `classes.descriptor` is `CGVirtualDisplayDescriptor` as the
    // runtime itself resolved it, `+new` is `NSObject`'s and the class declares `-init`, and every
    // selector below is a property setter of that class with the argument type its declaration
    // gives: `unsigned int` for the three ids and the two pixel counts, `NSString *` for the name,
    // `CGSize`/`CGPoint` by value for the metrics and the primaries, and the two object properties
    // for the queue and the handler. No pointer is created, read or reinterpreted on this side.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    let descriptor: Retained<AnyObject> = unsafe { msg_send![classes.descriptor, new] };

    // SAFETY: as above — one selector per declared property, one argument of its declared type.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    unsafe {
        let _: () = msg_send![&*descriptor, setVendorID: VENDOR_ID];
        let _: () = msg_send![&*descriptor, setProductID: PRODUCT_ID];
        let _: () = msg_send![&*descriptor, setName: &*label];
        let _: () = msg_send![&*descriptor, setMaxPixelsWide: pixels_wide];
        let _: () = msg_send![&*descriptor, setMaxPixelsHigh: pixels_high];
        let _: () = msg_send![&*descriptor, setSizeInMillimeters: millimetres];
        let _: () = msg_send![&*descriptor, setWhitePoint: WHITE_POINT];
        let _: () = msg_send![&*descriptor, setRedPrimary: RED_PRIMARY];
        let _: () = msg_send![&*descriptor, setGreenPrimary: GREEN_PRIMARY];
        let _: () = msg_send![&*descriptor, setBluePrimary: BLUE_PRIMARY];
        let _: () = msg_send![&*descriptor, setQueue: &*queue];
        let _: () = msg_send![&*descriptor, setTerminationHandler: &**on_terminated];
    }
    set_serial_if_possible(&descriptor, SERIAL);
    (descriptor, queue)
}

/// Sets the serial through whichever key the RUNNING class exposes, and skips it when neither is
/// there.
///
/// The property name diverges across macOS releases — the canonical class dump has `serialNum`,
/// later bridging headers have `serialNumber` — and sending a setter a class does not implement
/// raises `unrecognized selector`, which is a crash, not an error. The serial is cosmetic, so the
/// right answer to "neither exists" is to leave it unset.
fn set_serial_if_possible(descriptor: &AnyObject, value: u32) {
    for (key, setter) in [
        ("serialNum", c"setSerialNum:"),
        ("serialNumber", c"setSerialNumber:"),
    ] {
        let selector = Sel::register(setter);
        // SAFETY: Objective-C runtime rule. `-respondsToSelector:` is `NSObject`'s own, declared for
        // every root-class descendant, and takes exactly one `SEL` by value; asking it is the
        // documented way to find out whether the send below is legal.
        #[expect(
            unsafe_code,
            reason = "`respondsToSelector:` is NSObject's, and asking it is what makes the next send safe"
        )]
        let responds: bool = unsafe { msg_send![descriptor, respondsToSelector: selector] };
        if !responds {
            continue;
        }
        let number = NSNumber::numberWithUnsignedInt(value);
        let key = NSString::from_str(key);
        // SAFETY: Objective-C runtime rule. `-setValue:forKey:` is `NSObject`'s key-value coding
        // entry point, declared `(id, NSString *)`; the key names a property the class was just
        // observed to implement a setter for, and KVC unboxes the `NSNumber` into its `unsigned int`
        // for us.
        #[expect(
            unsafe_code,
            reason = "key-value coding is NSObject's, and the key was just proven to exist"
        )]
        unsafe {
            let _: () = msg_send![descriptor, setValue: &*number, forKey: &*key];
        }
        return;
    }
}

/// Drops the descriptor's termination handler, so `WindowServer` has nothing left to call.
///
/// This is the FIRST step of teardown, and the order matters: the block holds a weak reference to
/// state the caller is about to dismantle, and a handler still installed when that happens is the
/// one race this area has.
pub(crate) fn neutralise(descriptor: &AnyObject) {
    let none: Option<&TerminationBlock> = None;
    // SAFETY: Objective-C runtime rule. The same declared setter as in `build`, given the null the
    // property's `nullable` declaration admits.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    unsafe {
        let _: () = msg_send![descriptor, setTerminationHandler: none];
    }
}

/// The handler the descriptor currently holds, or `None` when it holds nothing.
///
/// It exists so "neutralised" is an observable fact rather than a claim about a send nobody
/// checked.
#[cfg(test)]
fn termination_handler(descriptor: &AnyObject) -> Option<Retained<AnyObject>> {
    // SAFETY: Objective-C runtime rule. `-terminationHandler` is the declared getter of a `copy`
    // block property, so it answers a live block (or nil) at +0, and `Retained` is what `msg_send!`
    // uses to say "retain it before I look at it" — blocks respond to `retain`.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    unsafe {
        msg_send![descriptor, terminationHandler]
    }
}

/// The retain count of an object this crate believes it solely owns.
///
/// Used only by the leak tests: a build that handed back an object someone else also holds is a
/// leak whether or not the process's footprint moved.
#[cfg(test)]
fn retain_count(object: &AnyObject) -> usize {
    // SAFETY: Objective-C runtime rule. `-retainCount` is `NSObject`'s, answers `NSUInteger`, and is
    // read here only as a same-thread ownership assertion — nothing schedules on this object.
    #[expect(
        unsafe_code,
        reason = "`retainCount` is NSObject's own, and a leak test is exactly its one honest use"
    )]
    unsafe {
        msg_send![object, retainCount]
    }
}

/// Whether this thread is the main one — the leak tests must not touch anything that hops.
#[cfg(test)]
fn on_main_thread() -> bool {
    objc2::MainThreadMarker::new().is_some()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use slopdesk_video::virtual_display::Geometry;

    use super::{build, neutralise, on_main_thread, retain_count, termination_handler};
    use crate::classes::{classes, skipped};
    use crate::settings;

    /// The geometry every test here builds from — a 2× 1920×1080-point display, which is the shape
    /// the daemon actually mints.
    fn geometry() -> Geometry {
        Geometry::new(1920, 1080, 2, 8192)
    }

    /// A handler that records nothing, for the tests that only care that one is installed.
    fn inert() -> RcBlock<dyn Fn(*mut AnyObject, *mut AnyObject)> {
        RcBlock::new(|_display: *mut AnyObject, _reason: *mut AnyObject| {})
    }

    /// Building a descriptor, a settings object and its modes must consume nothing that is not
    /// handed back. Every mint builds all three, and a virtual display is re-minted on every
    /// `WindowServer` termination, so a per-build residue is unbounded over a session.
    ///
    /// The assertion is ownership rather than footprint: each object comes back at retain count
    /// one, meaning the twelve property sets, the block, the queue and the mode array left no
    /// extra reference behind. A retain-count of two would be a leak the process size takes
    /// hours to show.
    ///
    /// Nothing here hops to the main queue — `initWithDescriptor:` is the first call that does, and
    /// it is deliberately below this line.
    #[test]
    fn descriptor_settings_and_modes_do_not_leak() {
        let Some(classes) = classes() else {
            skipped("descriptor_settings_and_modes_do_not_leak");
            return;
        };
        assert!(
            !on_main_thread(),
            "this test must stay off the main thread; nothing it calls may hop",
        );
        let geometry = geometry();
        for iteration in 0..1000 {
            let handler = inert();
            let (descriptor, _queue) = build(classes, &geometry, "SlopDesk Remote", &handler);
            assert_eq!(
                retain_count(&descriptor),
                1,
                "descriptor over-retained on iteration {iteration}",
            );
            let settings = settings::build(classes, &geometry, 60);
            assert_eq!(
                retain_count(&settings),
                1,
                "settings over-retained on iteration {iteration}",
            );
        }
    }

    /// The termination block must die with the descriptor that copied it. It captures state the
    /// owner tears down, so a block outliving its descriptor is the crash this crate's teardown
    /// order exists to prevent — and a block that never dies is a per-mint leak of everything it
    /// captured.
    #[test]
    fn the_block_is_dropped_when_the_descriptor_is() {
        let Some(classes) = classes() else {
            skipped("the_block_is_dropped_when_the_descriptor_is");
            return;
        };
        let captured = Arc::new(AtomicUsize::new(0));
        let held = Arc::clone(&captured);
        let handler = RcBlock::new(move |_display: *mut AnyObject, _reason: *mut AnyObject| {
            held.fetch_add(1, Ordering::Relaxed);
        });
        let (descriptor, _queue) = build(classes, &geometry(), "SlopDesk Remote", &handler);
        assert!(
            Arc::strong_count(&captured) > 1,
            "the block must still hold its capture while the descriptor does",
        );
        drop(handler);
        drop(descriptor);
        assert_eq!(
            Arc::strong_count(&captured),
            1,
            "the descriptor's copy of the block outlived it",
        );
    }

    /// A neutralised handler never fires because there is nothing left to call: `neutralise` sets
    /// the property to nil, so `WindowServer`'s termination path finds no block. Asserting the
    /// property is the only way to check this without a `WindowServer` — and the pre-condition is
    /// asserted too, so the test would fail if `build` quietly stopped installing one.
    #[test]
    fn a_neutralised_handler_never_fires() {
        let Some(classes) = classes() else {
            skipped("a_neutralised_handler_never_fires");
            return;
        };
        let handler = inert();
        let (descriptor, _queue) = build(classes, &geometry(), "SlopDesk Remote", &handler);
        assert!(
            termination_handler(&descriptor).is_some(),
            "build must install a handler, or neutralising one proves nothing",
        );
        neutralise(&descriptor);
        assert!(
            termination_handler(&descriptor).is_none(),
            "the descriptor still holds a handler after neutralise",
        );
    }
}
