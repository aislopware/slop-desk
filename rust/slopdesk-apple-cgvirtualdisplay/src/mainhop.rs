//! The main-thread hop, and the main-thread release.
//!
//! Two of this area's operations are pinned to the main thread by `WindowServer`, not by Rust:
//! `initWithDescriptor:` (a synchronous Mach round-trip) and `-dealloc` of the registration object
//! (the same round-trip, in reverse). Everything else in the crate deliberately runs off it.
//!
//! Both helpers take the fast path when the caller ALREADY is the main thread, because
//! `dispatch_sync` onto the queue you are running on deadlocks. `MainThreadMarker::new()` is the
//! check, and it is an `Option` rather than an assertion precisely so this can branch on it.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use dispatch2::DispatchQueue;
use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;

/// An Objective-C object being carried across a queue boundary.
///
/// `Retained<AnyObject>` is deliberately not `Send`, because `objc2` makes no blanket promise for
/// every Objective-C class. This wrapper is the per-class judgement `objc2` cannot make: it is only
/// ever constructed around one of the four `CGVirtualDisplay*` objects, and the only thing done to
/// it on the far side is a message send or a release.
pub(crate) struct Ferried(pub(crate) Retained<AnyObject>);

// SAFETY: framework rule. Objective-C reference counting is atomic — `objc_retain`/`objc_release`
// are documented as thread-safe for every object — so MOVING a strong reference between threads is
// exactly what the runtime supports. What is NOT thread-safe for this area is WindowServer's
// registration IPC, and that is why this wrapper exists at all: it carries the object TO the main
// thread, where the sends that need it happen. Nothing here shares the object between threads at
// the same time, which is why only `Send` is claimed and `Sync` is not.
#[expect(
    unsafe_code,
    reason = "objc2 cannot promise thread-safety for a class it has no bindings for; this is that per-class \
              judgement"
)]
#[expect(
    clippy::non_send_fields_in_send_ty,
    reason = "the field is a framework object; the promise is the framework's"
)]
unsafe impl Send for Ferried {}

impl core::fmt::Debug for Ferried {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.debug_tuple("Ferried").field(&self.0).finish()
    }
}

/// Runs `work` on the main thread and returns its answer, or `None` if the main queue never ran it.
///
/// The answer must be `Send` because it comes back across the hop; an Objective-C object comes back
/// inside a [`Ferried`]. On the main thread already, `work` runs inline — dispatching to the queue
/// you are on would deadlock, which is the failure this branch prevents.
pub(crate) fn on_main<R, F>(work: F) -> Option<R>
where
    R: Send,
    F: Send + FnOnce() -> R,
{
    if MainThreadMarker::new().is_some() {
        return Some(work());
    }
    let mut answer: Option<R> = None;
    let slot = &mut answer;
    DispatchQueue::main().exec_sync(move || {
        *slot = Some(work());
    });
    answer
}

/// Releases `object` on the main thread.
///
/// `CGVirtualDisplay`'s `-dealloc` unregisters the display through the same synchronous
/// `WindowServer` IPC that created it, so the last release must not happen on an arbitrary thread.
/// This is asynchronous on purpose: teardown must not block the caller behind a wedged
/// `WindowServer`, and there is nothing left to wait for once the reference is handed over.
pub(crate) fn release_on_main(object: Retained<AnyObject>) {
    if MainThreadMarker::new().is_some() {
        drop(object);
        return;
    }
    let ferried = Ferried(object);
    DispatchQueue::main().exec_async(move || drop(ferried));
}
