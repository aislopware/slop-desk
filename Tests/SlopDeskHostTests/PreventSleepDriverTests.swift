import Foundation
import XCTest
@testable import SlopDeskHost

/// E13 WI-3 (ES-E13-3): the prevent-sleep DRIVER's apply-under-lock invariant. ``PreventSleepDriver`` is fed
/// by the host agent-status fan-out, which calls its observers OUTSIDE its own lock and from MULTIPLE threads
/// (foreground-poll + the mux teardown fan). If the driver applied the assertion OUTSIDE its own lock, two
/// interleaved `note()` calls could push a STALE state — leaving the assertion HELD while no pane works (a
/// leaked `IOPMAssertion` that keeps the Mac awake forever). These pin that the apply happens UNDER the lock,
/// using a fake ``PreventSleepAsserting`` sink (NEVER a real `IOPMAssertion` — the hang-safety posture).
final class PreventSleepDriverTests: XCTestCase {
    /// A fake assertion sink that records the held state and can run a ONE-SHOT hook MID-APPLY (inside
    /// `setAsserted`, before recording the value) so a test can deterministically interleave a concurrent
    /// `note()` while the driver is applying. `@unchecked Sendable`: all state is lock-guarded.
    private final class FakeAsserter: PreventSleepAsserting, @unchecked Sendable {
        private let lock = NSLock()
        private var heldFlag = false
        private var onceHook: (() -> Void)?

        var held: Bool {
            lock.lock()
            defer { lock.unlock() }
            return heldFlag
        }

        func installOneShotHook(_ hook: @escaping () -> Void) {
            lock.lock()
            onceHook = hook
            lock.unlock()
        }

        @discardableResult
        func setAsserted(_ desired: Bool) -> Bool {
            // Grab + clear the one-shot hook under our OWN lock, then run it OUTSIDE (it re-enters the driver
            // from another thread). The driver's lock — not this one — is what must be held across this call.
            lock.lock()
            let hook = onceHook
            onceHook = nil
            lock.unlock()
            hook?()
            lock.lock()
            heldFlag = desired
            lock.unlock()
            return desired
        }
    }

    /// Two panes finish concurrently: thread A removes "a" while thread B removes the LAST working pane "b".
    /// The driver MUST apply the assertion under its lock, so B's whole `note()` cannot run during A's apply —
    /// which is exactly what prevents A from later applying a stale `true` over B's correct `false` (the leak).
    /// PRE-FIX (apply outside the lock) B completes mid-apply and A leaks the assertion held over an empty set.
    func testConcurrentNoteAppliesUnderLockAndNeverLeaks() {
        let asserter = FakeAsserter()
        let driver = PreventSleepDriver(enabled: true, asserter: asserter)

        driver.note(paneId: "a", working: true)
        driver.note(paneId: "b", working: true)
        XCTAssertTrue(asserter.held, "two working panes ⇒ the assertion is held")

        let started = DispatchSemaphore(value: 0)
        let bFinished = DispatchSemaphore(value: 0)
        let flagLock = NSLock()
        var bReturned = false // guarded by flagLock (written by thread B, read by thread A)
        // Read after `bFinished` on the test thread (thread A — the hook runs synchronously inside A's apply).
        nonisolated(unsafe) var concurrentNoteCompletedDuringApply = false

        // Fire on thread A's NEXT apply (its `note("a", false)` below): launch thread B (removes the last
        // working pane "b") and check whether B's full `note()` can COMPLETE while A is mid-apply.
        asserter.installOneShotHook {
            DispatchQueue.global().async {
                started.signal()
                driver.note(paneId: "b", working: false)
                flagLock.lock()
                bReturned = true
                flagLock.unlock()
                bFinished.signal()
            }
            started.wait() // B is definitely running now (no dispatch-latency flakiness)
            // Give B up to 0.5s to COMPLETE its note() WHILE A is mid-apply, polling a flag (so the single
            // `bFinished` signal is reserved for the outer wait). If B finishes here, the driver applied
            // OUTSIDE its lock; post-fix B BLOCKS on the driver lock A holds, so the flag never flips in time.
            let deadline = Date().addingTimeInterval(0.5)
            var returned = false
            while Date() < deadline {
                flagLock.lock()
                returned = bReturned
                flagLock.unlock()
                if returned { break }
                usleep(2000)
            }
            concurrentNoteCompletedDuringApply = returned
        }

        driver.note(paneId: "a", working: false) // thread A
        bFinished.wait() // ensure B has fully completed regardless of interleaving (single signal, consumed here)

        XCTAssertFalse(
            concurrentNoteCompletedDuringApply,
            "the driver applied the assertion OUTSIDE its lock — a concurrent note() ran during apply, the "
                + "interleaving that leaks a held IOPMAssertion over an empty working set",
        )
        XCTAssertFalse(
            asserter.held,
            "assertion LEAKED: held while no pane is working (the Mac would never sleep)",
        )
    }

    /// Sanity: with the feature disabled the driver never holds the assertion, regardless of working panes.
    func testDisabledNeverHolds() {
        let asserter = FakeAsserter()
        let driver = PreventSleepDriver(enabled: false, asserter: asserter)
        driver.note(paneId: "a", working: true)
        XCTAssertFalse(asserter.held, "disabled ⇒ never hold, even while a pane works")
    }

    /// The balanced transition: hold on the first working pane, release when the last one finishes.
    func testHoldsThenReleasesAcrossPanes() {
        let asserter = FakeAsserter()
        let driver = PreventSleepDriver(enabled: true, asserter: asserter)
        driver.note(paneId: "a", working: true)
        XCTAssertTrue(asserter.held)
        driver.note(paneId: "b", working: true)
        XCTAssertTrue(asserter.held)
        driver.note(paneId: "a", working: false)
        XCTAssertTrue(asserter.held, "still held while pane b works")
        driver.note(paneId: "b", working: false)
        XCTAssertFalse(asserter.held, "released when no pane works")
    }
}
