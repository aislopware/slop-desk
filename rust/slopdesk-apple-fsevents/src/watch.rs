//! The stream: create, arm, deliver, tear down.

use core::ffi::c_void;
use core::ptr::{self, NonNull};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use dispatch2::{DispatchQueue, DispatchRetained};
use objc2_core_foundation::{CFArray, CFString};
use objc2_core_services::{
    ConstFSEventStreamRef, FSEventStreamCreate, FSEventStreamEventFlags, FSEventStreamEventId,
    FSEventStreamInvalidate, FSEventStreamRef, FSEventStreamRelease, FSEventStreamSetDispatchQueue,
    FSEventStreamStart, FSEventStreamStop, kFSEventStreamCreateFlagNoDefer, kFSEventStreamEventIdSinceNow,
};

/// The kernel-side coalescing window, in seconds.
///
/// A first coalesce UNDER the caller's own debounce rather than a second policy: a build that
/// touches a thousand files costs a handful of wake-ups here instead of a thousand, and every one
/// of them still lands inside `repo_watch`'s debounce and collapses to one reading. Carried from
/// the Swift verbatim, which took it from Apple's own recommendation for a non-interactive watcher.
const LATENCY_SECONDS: f64 = 0.25;

/// What the callback is allowed to do: nothing but tell somebody.
type Listener = Arc<dyn Fn() + Send + Sync + 'static>;

/// Every live stream, keyed by the ADDRESS of the `FSEventStreamRef` the framework minted for it.
///
/// Process-wide because the callback is a plain `extern "C-unwind"` function with no state of its
/// own — see the crate doc on why the context pointer is not used. The key is an address and never
/// a pointer that is followed: `usize` rather than `*const _` in the type so that is not a promise
/// this file has to keep, it is one the compiler keeps.
fn live() -> &'static Mutex<HashMap<usize, Listener>> {
    static LIVE: OnceLock<Mutex<HashMap<usize, Listener>>> = OnceLock::new();
    LIVE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A recursive `FSEvents` subscription to one directory, torn down when it drops.
///
/// Not `Clone`: the teardown order below is run exactly once, and "once" is a property of the type
/// rather than of a comment, the same way `slopdesk-apple-power` holds its assertion's balance.
#[derive(Debug)]
pub struct Watch {
    /// The framework's handle. A raw pointer because that is what `FSEvents` deals in — it is not a
    /// Core Foundation object `objc2` models, so there is no `CFRetained` to hold it in and no
    /// admission from §2 being spent.
    stream: FSEventStreamRef,
    /// The delivery target, kept alive for the stream's whole life. `FSEventStreamSetDispatchQueue`
    /// retains the queue itself, so this is belt-and-braces rather than load-bearing — but a
    /// borrowed queue would put a lifetime on `Watch` that every caller would then have to thread.
    _queue: DispatchRetained<DispatchQueue>,
}

// SAFETY-adjacent, and it is a claim about FSEvents rather than about this struct: an
// `FSEventStreamRef` may be created on one thread and stopped from another, which is the whole
// point of `FSEventStreamSetDispatchQueue`, and the only operations this type performs on it are
// the four teardown calls. `DispatchQueue` is itself `Send + Sync`.
//
// It is spelled with `unsafe impl` because Rust cannot see either fact through a raw pointer.
#[expect(
    unsafe_code,
    reason = "the FSEvents contract is that a stream is stopped from wherever it was scheduled; only the \
              raw handle makes Rust doubt it"
)]
// SAFETY: the handle is only ever passed back to FSEvents, which documents its own calls as
// callable from any thread once the stream has a dispatch queue.
unsafe impl Send for Watch {}

#[expect(
    unsafe_code,
    reason = "see the `Send` impl above — the same one framework rule covers both"
)]
// SAFETY: `&Watch` exposes no operation at all; every method that touches the handle takes `&mut`
// or `self`.
unsafe impl Sync for Watch {}

impl Watch {
    /// Watches `path` recursively, calling `on_change` on `queue` when anything under it moves.
    ///
    /// `None` when the framework refuses to create the stream — an unreadable path, a volume that
    /// does not support events, a process out of resources — or when it refuses to start one. Both
    /// are the same answer to a caller: this directory will never report, so treat it as unwatched.
    /// Nothing is left registered in either case.
    #[must_use]
    pub fn watching<F>(path: &str, queue: &DispatchQueue, on_change: F) -> Option<Self>
    where
        F: Fn() + Send + Sync + 'static,
    {
        let watched = CFString::from_str(path);
        let paths = CFArray::from_retained_objects(&[watched]);

        #[expect(
            unsafe_code,
            reason = "FSEvents' four entry points are generated `unsafe extern`; each call below names the \
                      framework rule it satisfies"
        )]
        // SAFETY: `FSEventStreamCreate`'s stated obligations are that the callback is implemented
        // correctly, the context is a valid pointer OR NULL, and the path array holds `CFString`s.
        // The callback dereferences nothing (see the crate doc); the context is NULL by design; the
        // array was just built from one `CFString` and outlives the call.
        let stream = unsafe {
            FSEventStreamCreate(
                None,
                Some(on_events),
                ptr::null_mut(),
                paths.as_opaque(),
                kFSEventStreamEventIdSinceNow,
                LATENCY_SECONDS,
                kFSEventStreamCreateFlagNoDefer,
            )
        };
        if stream.is_null() {
            return None;
        }

        // Registered BETWEEN create and start, which is the only window where it can matter: no
        // callback can be dispatched before the stream is started, and none may be dispatched after
        // this without a row to find.
        let listener: Listener = Arc::new(on_change);
        live()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(stream.addr(), listener);

        #[expect(
            unsafe_code,
            reason = "the arming pair, same generated-`unsafe` reason as the create above"
        )]
        // SAFETY: `stream` is the non-null handle `FSEventStreamCreate` just returned and has been
        // handed to nobody else; the queue outlives the call and is retained by the framework for
        // the stream's life. Both calls document "must be a valid pointer" and nothing more.
        let started = unsafe {
            FSEventStreamSetDispatchQueue(stream, Some(queue));
            FSEventStreamStart(stream)
        };
        if !started {
            // The framework accepted the stream and then refused to run it. Unwind in the same
            // order `Drop` would, minus the stop a stream that never started cannot need.
            live()
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&stream.addr());

            #[expect(
                unsafe_code,
                reason = "the failed-start unwind, same generated-`unsafe` reason as the create"
            )]
            // SAFETY: same handle, still valid, still exclusively ours. Invalidate-then-release is
            // the order `FSEvents.h` requires for a scheduled stream.
            unsafe {
                FSEventStreamInvalidate(stream);
                FSEventStreamRelease(stream);
            }
            return None;
        }

        Some(Self {
            stream,
            _queue: DispatchRetained::from(queue),
        })
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        #[expect(
            unsafe_code,
            reason = "the teardown triple, same generated-`unsafe` reason as the create"
        )]
        // SAFETY: `self.stream` is the handle this `Watch` has owned exclusively since
        // `watching` returned, and `Watch` is neither `Clone` nor `Copy`, so this runs once.
        // Stop → invalidate → release is the order `FSEvents.h` requires, and after
        // `FSEventStreamInvalidate` returns the framework dispatches no further callbacks.
        unsafe {
            FSEventStreamStop(self.stream);
            FSEventStreamInvalidate(self.stream);
            FSEventStreamRelease(self.stream);
        }
        // AFTER the invalidate, deliberately. A callback already sitting on the queue when the
        // invalidate ran may still execute; it then finds no row and does nothing, which is the
        // whole of the race. Removing first would only make that window bigger.
        live()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&self.stream.addr());
    }
}

/// The framework's callback, defined SAFE and coerced to the `unsafe extern` pointer `FSEvents`
/// wants.
///
/// Every argument but the first is ignored — see the crate doc on why the event detail is not this
/// crate's to decode. The first is used as an ADDRESS and never followed, which is what keeps this
/// function free of the raw-pointer dereference §2 bars.
///
/// The listener is cloned OUT of the table before it is called, so a callback cannot hold the lock
/// while running caller code — a listener that itself dropped a `Watch` would otherwise deadlock
/// against this very map.
extern "C-unwind" fn on_events(
    stream: ConstFSEventStreamRef,
    _info: *mut c_void,
    _count: usize,
    _paths: NonNull<c_void>,
    _flags: NonNull<FSEventStreamEventFlags>,
    _ids: NonNull<FSEventStreamEventId>,
) {
    let listener = live()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&stream.addr())
        .map(Arc::clone);
    if let Some(listener) = listener {
        listener();
    }
}

/// Whether a stream with this handle address is still registered — the leak test's only window
/// onto the table.
///
/// `cfg(test)` because it is an assertion about an implementation detail, not a door: a caller that
/// wanted to know whether its `Watch` is alive can look at whether it still holds one.
#[cfg(test)]
fn is_registered(stream: FSEventStreamRef) -> bool {
    live()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .contains_key(&stream.addr())
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use super::{Arc, DispatchQueue, DispatchRetained, Watch, is_registered};

    /// A serial queue, the way the caller at stage F will build one.
    fn queue() -> DispatchRetained<DispatchQueue> {
        DispatchQueue::new("slopdesk.test.fsevents", None)
    }

    /// The leak test §3 asks every crate in this family for: what the watch retains, it lets go of.
    #[test]
    fn a_dropped_watch_lets_go_of_everything_it_held() {
        let seen = Arc::new(AtomicUsize::new(0));
        let held = Arc::clone(&seen);
        let queue = queue();

        let watch = Watch::watching(&std::env::temp_dir().to_string_lossy(), &queue, move || {
            held.fetch_add(1, Ordering::SeqCst);
        })
        .expect("the system temp directory must be watchable");

        // Two: the one this test holds and the one the table holds for the listener.
        assert_eq!(
            Arc::strong_count(&seen),
            2,
            "the table must hold the listener while the watch lives"
        );

        drop(watch);
        assert_eq!(
            Arc::strong_count(&seen),
            1,
            "dropping the watch must release the listener — a retained closure is the leak this test exists \
             for",
        );
    }

    /// The table is not a second lifetime: a watch that ends is forgotten by it.
    #[test]
    fn a_dropped_watch_leaves_no_row_behind() {
        let queue = queue();
        let watch = Watch::watching(&std::env::temp_dir().to_string_lossy(), &queue, || {})
            .expect("the system temp directory must be watchable");
        let handle = watch.stream;
        assert!(
            is_registered(handle),
            "a live watch must be findable by the callback"
        );
        drop(watch);
        assert!(
            !is_registered(handle),
            "a dead watch must leave no row for a later stream to collide with"
        );
    }

    /// `FSEvents` refuses nothing, and the balance holds anyway.
    ///
    /// `FSEventStreamCreate` does not validate its path list — an empty string is accepted and the
    /// stream simply never reports. That is the framework's answer, so it is this crate's answer
    /// too: §2 does not let a wrapper invent a refusal the framework does not make. What the test
    /// pins is that the inert watch is still balanced, which is the property the create-failure arm
    /// exists to preserve and which no test can reach directly (that arm is an allocation failure).
    #[test]
    fn a_watch_the_framework_will_never_report_on_is_still_balanced() {
        let seen = Arc::new(AtomicUsize::new(0));
        let held = Arc::clone(&seen);
        let queue = queue();
        let watch = Watch::watching("", &queue, move || {
            held.fetch_add(1, Ordering::SeqCst);
        })
        .expect("the framework validates no path, so even an empty one yields a stream");
        assert_eq!(
            Arc::strong_count(&seen),
            2,
            "the table holds the listener while the watch lives"
        );

        drop(watch);
        assert_eq!(
            Arc::strong_count(&seen),
            1,
            "an inert watch must release its listener like any other — this is the balance the Swift kept \
             by hand with `box.release()`",
        );
        assert_eq!(seen.load(Ordering::SeqCst), 0, "and it must never have fired");
    }

    /// The stream actually delivers: a write under the watched directory reaches the listener.
    ///
    /// The only test here that waits on the world. It waits on a CONDITION with a ceiling rather
    /// than on a fixed sleep, so a fast machine finishes fast and a loaded one still passes.
    #[test]
    fn a_change_under_the_watched_directory_reaches_the_listener() {
        let root = std::env::temp_dir().join("slopdesk-fsevents-probe");
        std::fs::create_dir_all(&root).expect("the probe directory must be creatable");
        let seen = Arc::new(AtomicUsize::new(0));
        let held = Arc::clone(&seen);
        let queue = queue();

        let watch = Watch::watching(&root.to_string_lossy(), &queue, move || {
            held.fetch_add(1, Ordering::SeqCst);
        })
        .expect("a directory that exists must be watchable");

        std::fs::write(root.join("touched"), b"x").expect("the probe file must be writable");

        let mut waited = Duration::ZERO;
        let step = Duration::from_millis(25);
        let ceiling = Duration::from_secs(10);
        while seen.load(Ordering::SeqCst) == 0 && waited < ceiling {
            std::thread::sleep(step);
            waited += step;
        }
        assert!(
            seen.load(Ordering::SeqCst) > 0,
            "a write under the root must wake the listener"
        );

        drop(watch);
        drop(std::fs::remove_dir_all(&root));
    }
}
