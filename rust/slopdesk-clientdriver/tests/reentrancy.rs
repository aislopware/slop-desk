//! What happens when the near side calls the driver from inside the driver's own callback.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.5. No Swift suite this replaces: the actor made the
//! hazard unreachable by making every call `await`, and paid for it with the reentrancy the actor
//! model has instead — a suspension point at which another task could interleave. One thread and a
//! mailbox trade that away for the opposite hazard, so it is pinned here.
//!
//! The hazard is narrow and entirely mechanical. `Retry`, `GaveUp`, `Disconnected`, `Reconnected`
//! and `Log` are emitted BY the supervisor, so a consumer that reacts to one by calling a method
//! that waits on the supervisor would be waiting on the thread it is standing in. That the near
//! side here is the FFI door, and the consumer a view controller reacting to a drop, is
//! exactly why it must not be a documented rule: a rule that is only written down fails as a frozen
//! pane in the field, with no diagnostic and no way back.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

mod common;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant};

use common::{GENEROUS, Harness, OpenPolicy, PORT, endpoint_host, quiet_config};
use slopdesk_clientdriver::event::{Event, Observer};
use slopdesk_clientdriver::{ConnectError, PaneDriver};

/// The door hands this handle to a UI thread and to its own callbacks alike, so a `PaneDriver` that
/// were not both would not be usable through it at all. Stated here rather than left to the door,
/// because it is the driver's property to keep.
const _: fn() = || {
    const fn both<T: Send + Sync>() {}
    both::<PaneDriver>();
};

/// A consumer that does, from inside the callback, exactly what the supervisor cannot serve.
struct Meddler {
    /// Weak so the observer does not keep the driver it observes alive.
    driver: Mutex<Weak<PaneDriver>>,
    /// What the reentrant connect answered, once it has answered.
    refusal: Mutex<Option<ConnectError>>,
    /// Set only after the reentrant `close()` RETURNS, which is the half a deadlock would fail.
    returned: AtomicBool,
}

impl Observer for Meddler {
    fn event(&self, event: &Event<'_>) {
        if !matches!(*event, Event::Disconnected { .. }) {
            return;
        }
        let Some(driver) = self.driver.lock().ok().and_then(|held| held.upgrade()) else {
            return;
        };
        let refused = driver
            .connect(endpoint_host(), PORT, GENEROUS)
            .expect_err("a dial from inside the callback that would service it");
        if let Ok(mut slot) = self.refusal.lock() {
            *slot = Some(refused);
        }
        driver.close();
        self.returned.store(true, Ordering::SeqCst);
    }

    fn output_ready(&self) {}
}

/// Both halves of the contract, in the one situation that produces them: the link dies, the
/// supervisor announces it, and the consumer reacts by asking for two more things.
///
/// The connect is REFUSED, because its answer is the dial's outcome and there is no thread left to
/// produce one — a `Reentrant` is the only honest answer and it names the caller's bug. The close
/// is QUEUED, because its answer is nothing and the caller's actual want is the effect: the pane is
/// retired one turn of the loop later, in the order it was asked, and the callback returns at once.
#[test]
fn a_callback_that_calls_back_is_answered_rather_than_deadlocked() {
    let harness = Harness::new(OpenPolicy::Accept(0));
    let meddler = Arc::new(Meddler {
        driver: Mutex::new(Weak::new()),
        refusal: Mutex::new(None),
        returned: AtomicBool::new(false),
    });
    let driver = Arc::new(
        PaneDriver::new(
            Arc::clone(&harness.registry),
            Arc::<Meddler>::clone(&meddler),
            quiet_config(),
        )
        .expect("the supervisor thread starts"),
    );
    if let Ok(mut held) = meddler.driver.lock() {
        *held = Arc::downgrade(&driver);
    }
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");
    let host = harness.host(0);
    host.wait_opens(1);

    host.cut_the_link();

    // The deadline is the assertion. A driver without the guard hangs here for the full ten seconds
    // and fails on the timeout rather than on a value, which is the correct report: the observed
    // symptom of the bug IS the pane never coming back.
    let deadline = Instant::now() + GENEROUS;
    while !meddler.returned.load(Ordering::SeqCst) {
        assert!(
            Instant::now() < deadline,
            "the callback never returned — a reentrant call parked on its own thread"
        );
        thread::sleep(Duration::from_millis(2));
    }

    let refusal = meddler.refusal.lock().expect("the refusal slot").take();
    assert!(
        matches!(refusal, Some(ConnectError::Reentrant)),
        "a reentrant dial names itself rather than failing as a dead link: {refusal:?}"
    );

    while !driver.is_closed() {
        assert!(
            Instant::now() < deadline,
            "the queued close was dropped rather than run"
        );
        thread::sleep(Duration::from_millis(2));
    }
}
