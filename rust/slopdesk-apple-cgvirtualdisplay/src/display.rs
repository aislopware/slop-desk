//! The owner: one virtual display, held registered for as long as this value lives.
//!
//! ## What the reference means
//!
//! The `Retained<CGVirtualDisplay>` in [`State::display`] IS the registration. Releasing the last
//! one unregisters the display through the same synchronous `WindowServer` IPC that created it,
//! which is why every release here goes through the main queue, and why the identifier is cleared
//! BEFORE the object is given up: a reader that saw a live id for an object already on its way out
//! would park a window on a display that is about to stop existing.
//!
//! ## The termination race, which is the hard part
//!
//! `WindowServer` can terminate the display at any moment — sleep/wake, GPU reset, fast user
//! switch, a display reconfiguration — and it says so by invoking a BLOCK on a queue of its own.
//! That block and this owner's teardown can therefore run at the same time, on two threads, and the
//! three orders that matter are all no-ops after the first:
//!
//! - `destroy` twice,
//! - `destroy` and then a termination,
//! - a termination and then `destroy`.
//!
//! One `Mutex<Option<…>>` decides all three: whoever TAKES the display out is the one that acts.
//!
//! Three further rules make that safe rather than merely correct:
//!
//! 1. The block holds a `Weak`, never a strong reference and never a raw handle pointer. A strong
//!    one would keep the owner alive forever; a raw one would outlive it.
//! 2. Teardown NEUTRALISES the descriptor before dropping anything, so `WindowServer` has nothing
//!    left to call, and the owner keeps its own reference to the block so neutralising cannot free
//!    a block that is running.
//! 3. The descriptor, the queue and the block are dropped ON THE DELIVERY QUEUE, and teardown WAITS
//!    for that drop. The queue is serial, so waiting is what turns "the drop is ordered after any
//!    handler already in flight" into "no handler is in flight once teardown returns" — the one
//!    guarantee that lets a caller free what its termination callback reads the moment
//!    [`VirtualDisplay::destroy`] (or the drop) comes back.
//!
//! ⚠️ A termination callback must not call [`VirtualDisplay::destroy`]: it runs ON the delivery
//! queue, and teardown orders itself against that queue.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant};

use dispatch2::{DispatchQueue, DispatchRetained};
use objc2::msg_send;
use objc2::rc::{Allocated, Retained};
use objc2::runtime::AnyObject;
use slopdesk_video::geometry::VideoRect;
use slopdesk_video::virtual_display::{Geometry, origin_to_right};

use crate::apply::apply_with_timeout;
use crate::classes::{Classes, classes};
use crate::descriptor::{self, HeldBlock};
use crate::extend::{ExtendOutcome, extend};
use crate::mainhop::{Ferried, on_main, release_on_main};
use crate::settings;

/// How long to wait for `WindowServer` to publish the new display in the online list.
///
/// `applySettings:` returning an id and the display being ENUMERABLE are two events, and the
/// reconfigure below is a no-op against a display the list does not have yet.
const ONLINE_POLL_LIMIT: Duration = Duration::from_secs(1);
/// One step of that poll.
const ONLINE_POLL_STEP: Duration = Duration::from_millis(50);
/// A settle before the reconfigure: `WindowServer` can still be mid-reconfigure of its own right
/// after `applySettings:`, and a transaction opened into that loses to it.
const SETTLE_BEFORE_EXTEND: Duration = Duration::from_millis(200);

/// The callback fired when `WindowServer` terminates the display out from under this process.
type TerminationCallback = Arc<dyn Fn() + Send + Sync>;

/// Everything one registration owns, dropped together and in one place.
#[derive(Debug)]
struct Registration {
    /// The descriptor, kept only so its handler can be neutralised at teardown.
    descriptor: Ferried,
    /// The delivery queue, kept so teardown can be ORDERED against an in-flight handler.
    queue: DispatchRetained<DispatchQueue>,
    /// This side's own reference to the block, so neutralising cannot free a running one. Never
    /// read — being held is the whole of its job, and it is dropped with the rest of this struct.
    #[expect(
        dead_code,
        reason = "the reference IS the point: holding it is what keeps a running block alive"
    )]
    block: HeldBlock,
}

/// The scale a host with no virtual display captures at: the real display's own, 1:1.
const NO_DISPLAY_SCALE: u32 = 1;

/// The shared interior. The public handle is a thin `Arc` over this, and the termination block
/// holds a `Weak` to it.
struct State {
    /// The registration object. Its presence is what "there is a live display" means.
    display: Mutex<Option<Ferried>>,
    /// What built it, kept for teardown.
    registration: Mutex<Option<Registration>>,
    /// The live `CGDirectDisplayID`, or `0`. Atomic because it is read on every pane mint while a
    /// create may be running for another pane.
    id: AtomicU32,
    /// The backing scale of the live display, or `1`.
    scale: AtomicU32,
    /// What to run when `WindowServer` terminates the display.
    terminated: Mutex<Option<TerminationCallback>>,
}

impl Default for State {
    /// Hand-written for ONE field: with no display the scale is 1×, not zero. A zero would make a
    /// caller compute a zero-pixel capture rect the first time it asked before a create.
    fn default() -> Self {
        Self {
            display: Mutex::default(),
            registration: Mutex::default(),
            id: AtomicU32::new(0),
            scale: AtomicU32::new(NO_DISPLAY_SCALE),
            terminated: Mutex::default(),
        }
    }
}

impl core::fmt::Debug for State {
    /// Hand-written because the termination callback is a closure, and a closure has no `Debug`.
    /// What a reader needs from a state dump is whether there IS a display and what its id is.
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("State")
            .field("id", &self.id)
            .field("scale", &self.scale)
            .finish_non_exhaustive()
    }
}

impl State {
    /// Takes the display out, if it is still there. `Some` means THIS call owns the teardown.
    fn claim(&self) -> Option<Ferried> {
        self.display.lock().ok().and_then(|mut slot| slot.take())
    }

    /// `WindowServer` terminated the display. Clears the identifier first so nothing keeps
    /// targeting it, releases the registration on the main thread, then notifies once.
    ///
    /// Deliberately does NOT dismantle the descriptor: this runs INSIDE the block the descriptor
    /// owns, and dropping it here would free the code that is running.
    fn handle_termination(&self) {
        self.id.store(0, Ordering::SeqCst);
        self.scale.store(NO_DISPLAY_SCALE, Ordering::SeqCst);
        let Some(display) = self.claim() else {
            return; // `destroy` got there first; a termination after it is a no-op.
        };
        release_on_main(display.0);
        let callback = self
            .terminated
            .lock()
            .ok()
            .and_then(|slot| slot.as_ref().map(Arc::clone));
        if let Some(callback) = callback {
            callback();
        }
    }

    /// Releases the display and everything that built it. Idempotent, and safe to call from any
    /// thread except the delivery queue.
    fn dismantle(&self) {
        self.id.store(0, Ordering::SeqCst);
        self.scale.store(NO_DISPLAY_SCALE, Ordering::SeqCst);
        let registration = self.registration.lock().ok().and_then(|mut slot| slot.take());
        if let Some(registration) = registration {
            // 1. Nothing left for WindowServer to call. Safe because `registration.block` still
            //    holds the block that the property is about to release.
            descriptor::neutralise(&registration.descriptor.0);
            // 2. Give the descriptor, the queue and the block up on the DELIVERY queue, and WAIT
            //    for that drop. The queue is serial, so waiting turns "ordered after any handler
            //    already in flight" into "no handler is in flight once this returns" — which is the
            //    term the FFI door above states to its caller: the context a termination callback
            //    reads may be released once teardown has RETURNED. Dropping asynchronously would
            //    let teardown return while a handler was still inside the caller's function
            //    pointer.
            //
            //    It cannot deadlock: a handler never reaches here (`handle_termination`
            // deliberately    does not dismantle), and everything a handler itself
            // dispatches is asynchronous.
            let queue = registration.queue.clone();
            queue.exec_sync(move || drop(registration));
        }
        // 3. Only now the display itself, on the main thread, because its `-dealloc` is the
        //    unregistering IPC.
        if let Some(display) = self.claim() {
            release_on_main(display.0);
        }
    }
}

/// One `HiDPI` virtual display, for the lifetime of this value.
///
/// `Send + Sync`: every field is behind a lock or an atomic, and the identifier readers use is an
/// `AtomicU32` precisely so a pane mint can ask for it while another pane's create is in flight.
#[derive(Debug)]
pub struct VirtualDisplay {
    /// The shared interior; the termination block holds a `Weak` to the same allocation.
    state: Arc<State>,
}

impl Default for VirtualDisplay {
    fn default() -> Self {
        Self::new()
    }
}

impl VirtualDisplay {
    /// An owner with no display yet. Creates nothing and touches no framework.
    #[must_use]
    pub fn new() -> Self {
        Self {
            state: Arc::new(State::default()),
        }
    }

    /// The live `CGDirectDisplayID`, or `0` when there is no display.
    ///
    /// One atomic read, no message send — so it is answerable while a create is running on another
    /// thread, which is the whole reason it is an atomic.
    #[must_use]
    pub fn display_id(&self) -> u32 {
        self.state.id.load(Ordering::SeqCst)
    }

    /// The live display's backing scale, or `1`.
    #[must_use]
    pub fn scale(&self) -> u32 {
        self.state.scale.load(Ordering::SeqCst)
    }

    /// Registers `callback` to run when `WindowServer` terminates the display.
    ///
    /// It runs on the delivery queue, NOT the main thread, and by the time it runs the identifier
    /// is already cleared — so a concurrent mint fails soft to 1× instead of parking onto a
    /// dead display. It must not call [`Self::destroy`].
    pub fn on_terminated(&self, callback: Box<dyn Fn() + Send + Sync>) {
        if let Ok(mut slot) = self.state.terminated.lock() {
            *slot = Some(Arc::from(callback));
        }
    }

    /// Creates the display and returns its `CGDirectDisplayID`, or `None` on ANY failure.
    ///
    /// Failure is never a crash and never a partial display: the private classes being absent, an
    /// over-budget framebuffer, `WindowServer` refusing the descriptor, `applySettings:` failing or
    /// exceeding its ceiling, and an identifier that stayed zero all answer `None`, and the caller
    /// falls back to capturing a real display at 1×.
    ///
    /// ⚠️ BLOCKS for as long as `WindowServer` takes, up to the apply ceiling plus about 1.2
    /// seconds of polling and settling. ⚠️ MUST NOT be called from the main thread: it hops to
    /// main twice inside itself, and `dispatch_sync` onto the queue you are already on
    /// deadlocks.
    #[must_use]
    pub fn create(&self, geometry: &Geometry, name: &str, fps: i32) -> Option<u32> {
        let classes = classes()?;
        if geometry.exceeds_pixel_limit() {
            return None;
        }
        // Snapshot the physical displays BEFORE the virtual one exists, so the reconfigure can pin
        // each at the origin it already had and place the new one past the rightmost edge.
        // ONLINE, not active: a sleeping or mirrored display still owns its origin, and pinning
        // only the drawable ones would let WindowServer reflow the rest.
        let physical = slopdesk_apple_cgdisplay::online();
        let bounds: Vec<VideoRect> = physical.iter().map(|display| display.bounds).collect();
        let vd_origin = origin_to_right(&bounds);

        let weak = Arc::downgrade(&self.state);
        let block = block_for(weak);
        let (descriptor, queue) = descriptor::build(classes, geometry, name, &block);
        let registration = Registration {
            descriptor: Ferried(descriptor),
            queue,
            block: HeldBlock(block),
        };
        let (registration, display) = init_on_main(classes, registration)?;
        // WindowServer refused the descriptor. Nothing was registered, so nothing can fire.
        let display = display?;

        let settings = settings::build(classes, geometry, fps);
        let applied =
            apply_with_timeout(&display.0, &settings).filter(|applied| applied.ok && applied.display_id != 0);
        let Some(applied) = applied else {
            // The display exists but is unusable. Give BOTH halves up in the teardown order, so an
            // apply that returns after the ceiling finds nothing left to call.
            abandon(registration, display);
            return None;
        };
        let id = applied.display_id;

        // Publication lags the identifier. A reconfigure aimed at a display the online list does
        // not have yet is a silent no-op, which shows up as an auto-mirrored capture much later.
        wait_until_online(id);
        thread::sleep(SETTLE_BEFORE_EXTEND);
        // A still-mirrored display captures the wrong content, but it IS a display: the caller gets
        // it either way. A failed transaction leaves WindowServer's own arrangement, also usable.
        let _outcome: ExtendOutcome = on_main(move || extend(id, vd_origin, &physical))
            .unwrap_or(ExtendOutcome::Failed(objc2_core_graphics::CGError::Failure));

        self.store(display, registration, id, geometry);
        Some(id)
    }

    /// Publishes the finished registration: the object and what built it first, then the
    /// identifier, so no reader can see an identifier whose object is not yet held.
    fn store(&self, display: Ferried, registration: Registration, id: u32, geometry: &Geometry) {
        if let Ok(mut slot) = self.state.display.lock() {
            *slot = Some(display);
        }
        if let Ok(mut slot) = self.state.registration.lock() {
            *slot = Some(registration);
        }
        self.state.scale.store(
            u32::try_from(geometry.scale()).unwrap_or(NO_DISPLAY_SCALE),
            Ordering::SeqCst,
        );
        self.state.id.store(id, Ordering::SeqCst);
    }

    /// Releases the display. Idempotent, and a no-op once `WindowServer` has terminated it.
    ///
    /// Call it AFTER every capture stream targeting the display has stopped and AFTER parked
    /// windows have been restored — the display each window came from must still exist.
    pub fn destroy(&self) {
        self.state.dismantle();
    }
}

impl Drop for VirtualDisplay {
    /// The registration cannot outlive its owner: an abandoned `CGVirtualDisplay` stays registered
    /// with `WindowServer` for the life of the process.
    fn drop(&mut self) {
        self.state.dismantle();
    }
}

/// Builds the termination block over a `Weak` to the owner.
///
/// `Weak`, not `Arc`: the descriptor holds the block and the owner holds the descriptor, so a
/// strong reference here would be a cycle that keeps the display registered forever. And never a
/// raw handle pointer, which would be a dangling one the moment the owner went.
fn block_for(state: Weak<State>) -> block2::RcBlock<dyn Fn(*mut AnyObject, *mut AnyObject)> {
    block2::RcBlock::new(move |_display: *mut AnyObject, _reason: *mut AnyObject| {
        // Both arguments are ignored and neither is dereferenced: WindowServer's display and reason
        // objects say nothing this side acts on, and the owner already knows which display it is.
        if let Some(state) = state.upgrade() {
            state.handle_termination();
        }
    })
}

/// Gives up a display that was created but never published, in the same order teardown uses:
/// neutralise the handler, hand the descriptor to the delivery queue and WAIT, release the display
/// on main.
///
/// The WAIT is not symmetry for its own sake. A callback can be registered BEFORE the first create
/// — the daemon arms one at bring-up and re-creates lazily on the same handle after a
/// `WindowServer` termination — so a create that fails HERE can be racing a handler that is inside
/// the caller's function pointer right now. Dropping asynchronously would leave that handler
/// running past a later teardown, which finds nothing left to wait on, and the door's promise about
/// when a context box may be released would be false on exactly this path.
///
/// Runs on the create caller's thread, never on the delivery queue, so the wait cannot deadlock.
fn abandon(registration: Registration, display: Ferried) {
    descriptor::neutralise(&registration.descriptor.0);
    let queue = registration.queue.clone();
    queue.exec_sync(move || drop(registration));
    release_on_main(display.0);
}

/// `-initWithDescriptor:`, on the main thread because it is a synchronous `WindowServer`
/// round-trip.
///
/// Takes the registration and hands it back, because the descriptor has to cross the hop and come
/// home again. The display is `None` when the main queue never ran the send, or when `WindowServer`
/// refused the descriptor — which it does by answering `nil`, with no other diagnostic.
fn init_on_main(classes: Classes, registration: Registration) -> Option<(Registration, Option<Ferried>)> {
    on_main(move || {
        let made = init_with_descriptor(classes, &registration.descriptor);
        (registration, made)
    })
}

/// The `nil`-able initialiser itself.
fn init_with_descriptor(classes: Classes, descriptor: &Ferried) -> Option<Ferried> {
    // SAFETY: Objective-C runtime rule. `+alloc` is `NSObject`'s, and `-initWithDescriptor:` is
    // `CGVirtualDisplay`'s declared initialiser taking one `CGVirtualDisplayDescriptor *`. It is
    // `nullable`, which is why the answer is an `Option`. The `init` family transfers ownership,
    // which is what `Retained` states.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    let made: Option<Retained<AnyObject>> = unsafe {
        let allocated: Allocated<AnyObject> = msg_send![classes.display, alloc];
        msg_send![allocated, initWithDescriptor: &*descriptor.0]
    };
    made.map(Ferried)
}

/// Polls the online list until `id` appears, or the limit expires.
///
/// The reconfigure that follows is only meaningful once `WindowServer` has published the display;
/// timing out is not fatal, it just means the transaction may find nothing to configure.
fn wait_until_online(id: u32) {
    let deadline = Instant::now().checked_add(ONLINE_POLL_LIMIT);
    loop {
        if slopdesk_apple_cgdisplay::online()
            .iter()
            .any(|display| display.id == id)
        {
            return;
        }
        match deadline {
            Some(deadline) if Instant::now() < deadline => thread::sleep(ONLINE_POLL_STEP),
            _ => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::VirtualDisplay;

    /// An owner that never created a display must tear down clean, and must be able to be torn down
    /// twice. This is the path a host takes on every machine where the private classes are absent
    /// or the create failed, so it is the most-travelled one in the whole crate — and every mutex
    /// it touches holds `None`, which is exactly where an `unwrap` would hide.
    ///
    /// Fully headless: nothing here resolves a class, sends a message or hops a queue.
    #[test]
    fn an_unused_handle_frees_clean() {
        let display = VirtualDisplay::new();
        assert_eq!(display.display_id(), 0);
        assert_eq!(display.scale(), 1, "no display means no scale but 1×");
        display.destroy();
        display.destroy();
        assert_eq!(display.display_id(), 0);
        drop(display);
    }

    /// A registered callback on an owner with no display is never fired by teardown. `destroy` is
    /// the caller ASKING for the display to go; reporting that as a `WindowServer` termination
    /// would make the daemon disconnect every session on an orderly shutdown.
    #[test]
    fn destroying_never_reports_a_termination() {
        let fired = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&fired);
        let display = VirtualDisplay::new();
        display.on_terminated(Box::new(move || {
            counted.fetch_add(1, Ordering::SeqCst);
        }));
        display.destroy();
        drop(display);
        assert_eq!(fired.load(Ordering::SeqCst), 0);
    }
}
