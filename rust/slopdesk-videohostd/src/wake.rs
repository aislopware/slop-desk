//! Keeping the HOST's display lit for as long as a desktop stream is being watched.
//!
//! A client watching the desktop must never have the picture go dark because the host's
//! display-sleep timer fired mid-session: the stream is not "user activity" as far as the window
//! server is concerned, because nobody is touching that Mac's keyboard. So the host has to say so,
//! and this is where it says it.
//!
//! ## What it owns, and what it asks
//! It owns exactly what the Swift host's display wake owned after its rules had already moved out:
//! the ONE process-wide holder, and the thread that makes the count and the apply a single
//! statement. Everything else it asks for — [`DisplayWake`] is the refcount rule (saturating up,
//! clamping at zero) and [`SleepAssertion`] is the `IOPMAssertion` itself, created on a false→true
//! edge and released on the reverse.
//!
//! ## The count and the assertion move together, on ONE thread
//! This is the whole reason the pair lives behind one object rather than two. Two sessions ending
//! on two threads: the first computes "still held" because the second is live, the second computes
//! "release" because it is the last one out, and then the first applies its stale `true`. That
//! leaves an assertion held over an empty count — which does not self-heal, and keeps the screen
//! lit until the daemon dies.
//!
//! The Swift bought that property with a lock across both objects. This buys it with OWNERSHIP, the
//! way `slopdesk-hostd`'s `sleep` module already does: one thread holds the pair and nothing else
//! can name either, so the update and the apply are not merely adjacent, they are unreachable from
//! anywhere the order could be broken. A channel carries the edges, and a channel is FIFO, so the
//! thread sees them in the order the sessions published them.
//!
//! ## Confinement is not a preference here
//! [`SleepAssertion`] holds a `CFString` and is therefore neither `Send` nor `Sync`, so it cannot
//! live in the `static` [`HostDisplayWake::shared`] hands out — and this crate may not `unsafe
//! impl` its way past that, being `forbid(unsafe_code)`. Widening the assertion instead, by keeping
//! the reason as a `String` and rebuilding the `CFString` per edge, would cost the leak check that
//! type carries: its retain-count reader can only count a string the type OWNS. So the assertion
//! stays on the thread that built it, which is the answer the language was pointing at.
//!
//! ## Why the edges BLOCK here, where hostd's do not
//! [`HostDisplayWake::acquire`] and [`HostDisplayWake::release`] wait for the owner thread's reply.
//! The state they answer is documented as diagnostic, but a diagnostic that reports the state from
//! BEFORE the edge is not a weaker answer, it is a wrong one — and the round trip is the only way
//! this side can state the resolved value at all, now that the count lives on the far side of a
//! channel. The cost is bounded and tiny: two edges per session lifetime, against an owner thread
//! whose whole body is a synchronous `IOPMAssertion` registration with no callback and no wait.
//!
//! `slopdesk-hostd`'s `KeepAwake` chose the other way for a reason that does not hold here: its
//! edges arrive from the agent-status fan-out, one per pane transition on whichever producer thread
//! published it, so a caller that waited would serialise every pane's transitions behind one power
//! call. A session start and a session end are not that.
//!
//! ## Window-target sessions never hold
//! The desktop stream is the one a person is actively LOOKING at; a background window feed keeping
//! a Mac's screen lit all night is a bug. That choice is the CALLER's — it acquires or it does
//! not — because which target a session has is the session's own state and not this holder's.
//!
//! ## What it replaces on the other side of the boundary
//! `slopdesk-ffi`'s `power` module is the same pairing behind a C door, for a Swift caller that no
//! longer exists once `HostDisplayWake.swift` is deleted. The doors go with it; the rule and the
//! assertion, which are the two halves worth keeping, are the same two this module asks.

use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::thread::{self, JoinHandle};

use slopdesk_apple_power::{SleepAssertion, SleepKind};
use slopdesk_video::display_wake::DisplayWake;

/// The name `pmset -g assertions` shows for the desktop-stream assertion.
///
/// Spelled here rather than derived, because an operator reading that list is the only consumer and
/// a computed one would be unsearchable.
const DISPLAY_REASON: &str = "slopdesk: remote desktop session attached";

/// Which way a caller is moving the count.
///
/// The verb rather than the verdict: what the count becomes is [`DisplayWake`]'s to decide, and it
/// decides it on the owner thread, where the answer cannot be stale by the time it is applied.
#[derive(Clone, Copy, Debug)]
enum Step {
    /// One more streaming desktop session.
    Acquire,
    /// One streaming desktop session ended.
    Release,
}

/// One edge, and the one-shot channel the owner thread answers the resolved state on.
///
/// The reply channel is per CALL rather than shared, so two sessions ending at once each read the
/// state resolved for their own edge instead of racing for whichever answer arrived first.
type Edge = (Step, Sender<bool>);

/// The daemon's display-wake holder: acquire while a desktop session streams, release when it ends.
///
/// Not `Clone` and not `Copy`, and the reason is the same one [`SleepAssertion`] gives: two holders
/// each counting their own sessions would each drive their own assertion, and the second one's
/// release would say nothing about the first one's count.
#[derive(Debug)]
pub struct HostDisplayWake {
    /// `None` once the holder has been dropped. Taking it is what closes the channel, and closing
    /// the channel is what ends the owner thread — and with it, the assertion.
    edges: Mutex<Option<Sender<Edge>>>,
    /// `None` if the thread could not be spawned at all, in which case the receiver went down with
    /// the closure and every edge answers `false` at the send.
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl HostDisplayWake {
    /// A holder with no sessions and nothing asserted, and the thread that owns its assertion.
    ///
    /// Private: the count is only meaningful if every session in the process reaches the SAME one,
    /// so [`Self::shared`] is the door and this is what it builds. The tests below construct their
    /// own, which is exactly the case that must not be reachable from the running daemon.
    fn new() -> Self {
        let (sender, inbox) = channel::<Edge>();
        let worker = thread::Builder::new()
            .name("slopdesk-display-wake".to_owned())
            .spawn(move || hold_loop(&inbox))
            .ok();
        Self {
            edges: Mutex::new(Some(sender)),
            worker: Mutex::new(worker),
        }
    }

    /// The one holder every session in this process shares.
    ///
    /// A `static` never drops, so the assertion is not released by a destructor at exit — the
    /// kernel reclaims a process's `IOPMAssertion`s when it dies, which is the same guarantee the
    /// Swift `static let shared` had and the reason neither needs a teardown path. The owner thread
    /// this one starts is likewise never joined, for the same reason and to the same effect. What
    /// must still balance is every LIVE session's pair, and that is [`Self::acquire`] against
    /// [`Self::release`].
    #[must_use]
    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<HostDisplayWake> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    /// One more streaming desktop session. The first holder raises the assertion.
    ///
    /// Answers whether the assertion is held now. Diagnostic rather than load-bearing — the Swift
    /// this replaces deliberately exposed no `isHolding` reader, because the count is this side's
    /// to keep — so a caller is free to ignore it, and none of them is expected to remember it.
    pub fn acquire(&self) -> bool {
        drive(&self.edges, Step::Acquire)
    }

    /// One streaming desktop session ended.
    ///
    /// An unbalanced release clamps at zero rather than underflowing: a teardown path that releases
    /// twice, or one that releases a session which never acquired, must not land the count
    /// somewhere no balanced pair can bring back down. That is the failure that holds the display
    /// awake until the daemon dies, and it is the one a `usize` that wrapped would have caused. The
    /// clamp is [`DisplayWake`]'s, applied on the owner thread.
    pub fn release(&self) -> bool {
        drive(&self.edges, Step::Release)
    }
}

impl Drop for HostDisplayWake {
    /// Closes the channel, then WAITS for the thread that owns the assertion to let go of it.
    ///
    /// The join is not optional. A holder dropped while still asserting is the teardown path a
    /// crashed session takes, and without the wait a caller could drop a thousand of them before
    /// the first thread had run its destructor — a thousand live threads, and a thousand
    /// assertions outstanding against a table that is not unbounded. Waiting costs one edge.
    ///
    /// `&mut self` here is what makes this safe against a blocked [`Self::acquire`]: no caller can
    /// hold a `&self` while this runs. The shared holder never reaches this at all.
    fn drop(&mut self) {
        drop(self.edges.lock().unwrap_or_else(PoisonError::into_inner).take());
        let worker = self.worker.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(worker) = worker {
            drop(worker.join());
        }
    }
}

/// Sends one edge to the owner thread and waits for the state it resolved.
///
/// A free function over the channel rather than a method, so the two ways an edge can fail to reach
/// anyone are reachable from a test without a holder that has to be broken first.
///
/// Every one of those ways answers `false`, which is the honest report: a holder whose thread is
/// gone is a holder that asserts nothing, and the assertion it used to hold was released by that
/// thread's own destructor on the way out. Never blocks forever — the reply channel dies with the
/// thread, so a wedged wait is not one of the shapes this can take.
fn drive(edges: &Mutex<Option<Sender<Edge>>>, step: Step) -> bool {
    // Cloned out from under the guard rather than used under it: holding the lock across the round
    // trip would serialise every session's edges behind whichever one the owner thread is mid-way
    // through applying, and waiting is the whole point of the call.
    let sender = edges.lock().unwrap_or_else(PoisonError::into_inner).clone();
    let Some(sender) = sender else {
        return false;
    };
    let (reply, answer) = channel();
    if sender.send((step, reply)).is_err() {
        return false;
    }
    // Unreachable in practice: the owner thread answers every edge it takes, and nothing in its
    // body can panic. `false` rather than a retry, because an edge that was applied and lost its
    // answer must not be applied twice.
    answer.recv().unwrap_or(false)
}

/// The thread that owns the count and the assertion, from the first edge to the channel's close.
///
/// Every framework object in this module lives inside this function. It ends when the channel
/// disconnects — which is [`HostDisplayWake`]'s `Drop` taking the sender, and nothing else.
fn hold_loop(inbox: &Receiver<Edge>) {
    // Both live and die HERE. Nothing outside this function can name either, which is what makes
    // the count-then-apply pair unbreakable rather than merely careful. The assertion is built
    // eagerly because construction is free and cannot fail: it tells the system nothing until an
    // edge says so.
    let mut fold = DisplayWake::new();
    let mut assertion = SleepAssertion::new(SleepKind::Display, DISPLAY_REASON);
    while let Ok((step, reply)) = inbox.recv() {
        let hold = match step {
            Step::Acquire => fold.acquire(),
            Step::Release => fold.release(),
        };
        // ONE statement: the verdict is computed from the count this iteration just moved, and
        // applied before the next edge can be taken off the channel. A refused create is not
        // remembered — the next edge retries, which is the whole recovery story for a system that
        // said no once. The reply is dropped if the caller has gone, which no caller does.
        let _ = reply.send(assertion.set_asserted(hold));
    }
    // The channel closed: the holder is going away. `assertion` drops here and releases anything
    // still held.
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;
    use std::sync::mpsc::channel;

    use super::{Edge, HostDisplayWake, Step, drive};

    /// The refcount's whole shape, driven through the real `IOKit` assertion rather than a fake.
    ///
    /// Real calls are deliberate, and `slopdesk-apple-power`'s own suite is the precedent: the
    /// hang-safety rule this tree keeps is about resources that BLOCK — a capture stream, an
    /// encoder, a PTY read — and a power assertion is a synchronous registration with no callback
    /// and no wait. A fake here would be the cross-language mirror the tree forbids, one language
    /// further along.
    ///
    /// It is also what pins the waiting edge: every assertion below reads the state the owner
    /// thread resolved for that call, which a fire-and-forget edge could not have reported yet.
    #[test]
    fn the_first_holder_lights_the_display_and_the_last_one_out_lets_it_sleep() {
        let wake = HostDisplayWake::new();
        assert!(wake.acquire());
        assert!(wake.acquire());
        assert!(wake.release(), "one session is still streaming");
        assert!(!wake.release());
    }

    /// A stray release must not strand the count below zero, because everything after it would then
    /// be a session that streams with the screen free to sleep.
    #[test]
    fn an_unbalanced_release_clamps_at_zero() {
        let wake = HostDisplayWake::new();
        assert!(!wake.release());
        assert!(!wake.release());
        assert!(wake.acquire(), "a later session still lights it");
        assert!(!wake.release());
    }

    /// Every session in the process must reach the SAME count. Two holders would each be right
    /// about their own sessions and wrong about the display.
    #[test]
    fn the_shared_holder_is_one_object() {
        assert!(core::ptr::eq(
            HostDisplayWake::shared(),
            HostDisplayWake::shared()
        ));
    }

    /// A holder dropped while still asserting lets go of the assertion — the teardown path a
    /// crashed session takes. If it did not, the assertion table would fill up and the acquire at
    /// the end would be the one that failed.
    ///
    /// Also the reason `Drop` joins: a thousand holders that only closed their channels would be a
    /// thousand threads still holding a thousand assertions when the last one is built.
    #[test]
    fn a_holder_dropped_while_asserting_lets_go() {
        for _ in 0..1_000 {
            let wake = HostDisplayWake::new();
            assert!(wake.acquire());
        }
        let after = HostDisplayWake::new();
        assert!(after.acquire());
    }

    /// The one failure the owner thread introduces that a lock never could: an edge with nobody
    /// left to apply it.
    ///
    /// It must answer that nothing is held rather than hang or panic, and it must answer that
    /// whether the thread went away after the sender was made or was never started at all. Both are
    /// true reports: the assertion a departed thread held was released by its own destructor, and a
    /// thread that never started never asserted anything.
    #[test]
    fn an_edge_that_cannot_reach_the_owner_thread_answers_that_nothing_is_held() {
        let (sender, inbox) = channel::<Edge>();
        drop(inbox);
        let departed = Mutex::new(Some(sender));
        assert!(
            !drive(&departed, Step::Acquire),
            "there is nobody left to light the display"
        );
        assert!(!drive(&departed, Step::Release));
        assert!(
            !drive(&Mutex::new(None), Step::Acquire),
            "a holder whose thread never spawned holds nothing either"
        );
    }
}
