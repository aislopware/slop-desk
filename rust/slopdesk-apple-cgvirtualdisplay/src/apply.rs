//! `applySettings:` under a ceiling.
//!
//! This is the one call in the area that can take seconds: it hands the modes to `WindowServer`
//! over the same Mach link `initWithDescriptor:` used, and the first one on a cold link is slow. It
//! must NOT run on the main thread — the opposite constraint from its neighbour two lines up the
//! sequence — and it must not be able to hang daemon bring-up when `WindowServer` is wedged.
//!
//! The shape is `slopdesk-apple-sck`'s handoff: a slot, a condition variable and a ten-second
//! ceiling. What is different here is the ABANDONED path. When the ceiling wins, the worker is
//! still inside `applySettings:` holding a strong reference; when it finally returns it must give
//! that reference back on the MAIN queue, because releasing the last one unregisters the display
//! through synchronous IPC. The clone the worker carries exists for exactly that.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use objc2::msg_send;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;

use crate::mainhop::{Ferried, release_on_main};

/// How long a caller waits for `WindowServer` before deciding it is not coming back.
///
/// Ten seconds is `slopdesk-apple-sck`'s ceiling for the same link, and the same reasoning: long
/// enough that a cold, honest first call is never cut off, short enough that daemon bring-up stays
/// bounded when the link is wedged.
const WAIT_LIMIT: Duration = Duration::from_secs(10);

/// What `applySettings:` answered.
///
/// `display_id` is read ON the worker thread, right after `applySettings:` returned, so the caller
/// never sends a message to a display object that may still be mutating on the abandoned path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Applied {
    /// Whether `applySettings:` answered `YES`.
    pub(crate) ok: bool,
    /// The `CGDirectDisplayID` the display was given, or `0` when it was not given one.
    pub(crate) display_id: u32,
}

/// The slot the worker delivers into, and the flag that says the waiter has gone.
#[derive(Debug, Default)]
struct Shared {
    /// The answer, once there is one.
    answer: Option<Applied>,
    /// Set by the waiter when the ceiling expired; tells the worker it owns the display now.
    abandoned: bool,
}

/// A one-shot handoff from the apply worker to the caller.
#[derive(Debug, Default)]
struct Handoff {
    /// The slot and the abandonment flag, under one lock so they cannot disagree.
    shared: Mutex<Shared>,
    /// Signalled once, when the answer lands.
    ready: Condvar,
}

impl Handoff {
    /// Delivers `applied`, answering `false` when the waiter already gave up — in which case the
    /// worker, not the caller, owns what it was working on.
    fn deliver(&self, applied: Applied) -> bool {
        let Ok(mut shared) = self.shared.lock() else {
            return false;
        };
        if shared.abandoned {
            return false;
        }
        shared.answer = Some(applied);
        self.ready.notify_all();
        true
    }

    /// Waits up to `limit` for the answer, marking the handoff abandoned if it does not arrive.
    fn take(&self, limit: Duration) -> Option<Applied> {
        let Ok(mut shared) = self.shared.lock() else {
            return None;
        };
        let deadline = Instant::now().checked_add(limit)?;
        while shared.answer.is_none() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                shared.abandoned = true;
                return None;
            }
            let Ok((waited, _)) = self.ready.wait_timeout(shared, remaining) else {
                return None;
            };
            shared = waited;
        }
        shared.answer.take()
    }
}

/// The two objects the worker carries across the thread boundary.
#[derive(Debug)]
struct Work {
    /// The display whose settings are being applied.
    display: Ferried,
    /// The settings being applied to it.
    settings: Ferried,
}

/// Runs `applySettings:` off this thread and waits up to ten seconds for it.
///
/// Answers `None` when the ceiling expired, when the thread could not be started, or when the lock
/// was poisoned — every one of which the caller treats the same way: no display, fall back to 1×.
///
/// ⚠️ The caller must release its OWN reference through [`release_on_main`] on the failure path.
/// Whichever of the two references is dropped last is the one that unregisters, and both must
/// therefore be given up on the main queue.
pub(crate) fn apply_with_timeout(
    display: &Retained<AnyObject>,
    settings: &Retained<AnyObject>,
) -> Option<Applied> {
    let handoff = Arc::new(Handoff::default());
    let worker = Arc::clone(&handoff);
    let work = Work {
        display: Ferried(display.clone()),
        settings: Ferried(settings.clone()),
    };
    let spawned = thread::Builder::new()
        .name("slopdesk-vd-apply".to_owned())
        .spawn(move || {
            let work = work;
            let applied = perform(&work);
            if !worker.deliver(applied) {
                // The ceiling won while we were inside WindowServer. We are the abandoned apply, so
                // this reference is now the one that might be last: hand it to the main queue.
                let Work { display, settings } = work;
                drop(settings);
                release_on_main(display.0);
            }
        });
    if spawned.is_err() {
        return None;
    }
    handoff.take(WAIT_LIMIT)
}

/// The blocking call itself, plus the `displayID` read that is only meaningful after it.
fn perform(work: &Work) -> Applied {
    // SAFETY: Objective-C runtime rule. `-applySettings:` is `CGVirtualDisplay`'s declared method,
    // taking one `CGVirtualDisplaySettings *` and answering `BOOL`, and `-displayID` is its
    // declared `CGDirectDisplayID` getter. Both are sent to the object the class's own
    // initialiser produced. The framework's threading contract for `-applySettings:` is "not
    // the main thread", which is why this runs on a thread of its own.
    #[expect(
        unsafe_code,
        reason = "sending a message to a class the runtime resolved is what reaching a private class IS"
    )]
    unsafe {
        let ok: bool = msg_send![&*work.display.0, applySettings: &*work.settings.0];
        let display_id: u32 = if ok {
            msg_send![&*work.display.0, displayID]
        } else {
            0
        };
        Applied { ok, display_id }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::{Applied, Handoff};

    /// An answer that arrives before the ceiling is handed straight through — the ordinary path,
    /// and the one a broken condvar would turn into a ten-second stall on every mint.
    #[test]
    fn an_answer_before_the_ceiling_is_handed_through() {
        let handoff = Arc::new(Handoff::default());
        let worker = Arc::clone(&handoff);
        let spawned = thread::spawn(move || {
            worker.deliver(Applied {
                ok: true,
                display_id: 7,
            })
        });
        let taken = handoff.take(Duration::from_secs(5));
        assert!(spawned.join().unwrap_or(false), "the waiter was still there");
        assert_eq!(
            taken,
            Some(Applied {
                ok: true,
                display_id: 7,
            }),
        );
    }

    /// The ceiling must actually expire, and it must leave the handoff marked abandoned so a late
    /// worker learns it now owns the display. Without the flag the worker would drop its reference
    /// on its own thread, and a `CGVirtualDisplay` deallocated off the main thread unregisters
    /// through IPC from the wrong place.
    #[test]
    fn the_ceiling_expires_and_hands_ownership_to_a_late_worker() {
        let handoff = Arc::new(Handoff::default());
        let started = Instant::now();
        assert_eq!(handoff.take(Duration::from_millis(50)), None);
        assert!(started.elapsed() >= Duration::from_millis(50));
        assert!(
            !handoff.deliver(Applied {
                ok: true,
                display_id: 7,
            }),
            "a delivery after the ceiling must be refused, not accepted",
        );
    }
}
