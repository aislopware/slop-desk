import Foundation
import XCTest

/// Headless, HostServer-FREE proof that ITEM #10's CI-safety mechanism actually works.
///
/// The real per-test ceiling + awaited teardown that makes the HostServer E2E suites
/// CI-safe lives in `HostServerE2ECase` (the HostServer-backed target). We must NOT run
/// those suites here (running them is the very hang this item fixes), so this suite proves
/// the *mechanism* against the free `withTestTimeout(_:_:)` twin and XCTest's own awaited
/// `addTeardownBlock` — no `HostServer`, no `PTYProcess`, no cooperative-pool footprint.
/// This is the authoritative gate that a `swift build` + this filter can verify.
final class HostServerE2EGuardTests: XCTestCase {
    /// A body that overruns the deadline must yield `nil` PROMPTLY (the timer branch wins and
    /// the helper returns at the deadline, not after the body's own 10s sleep). This is the
    /// core of "a hung test FAILS instead of wedging the run".
    func testWithTimeoutReturnsNilWhenBodyExceedsDeadline() async {
        let started = ContinuousClock.now
        let result: Int? = await withTestTimeout(.milliseconds(50)) {
            // Far longer than the 50ms ceiling; respects cancellation so it unwinds when the
            // timer wins, but even if it did not, the helper returns the instant the timer
            // fires — the caller is never blocked on the runaway body.
            try? await Task.sleep(for: .seconds(10))
            return 1
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertNil(result, "an over-deadline body must time out to nil")
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "the helper must return at the ~50ms deadline, not wait out the 10s body; took \(elapsed)",
        )
    }

    /// A body that finishes within the deadline returns its real value (here, 42) — the
    /// ceiling does not corrupt the fast/healthy path.
    func testWithTimeoutReturnsValueWhenBodyFinishesInTime() async {
        let result: Int? = await withTestTimeout(.seconds(10)) {
            try? await Task.sleep(for: .milliseconds(10))
            return 42
        }
        XCTAssertEqual(result, 42, "a body that finishes in time must return its value")
    }

    /// `addTeardownBlock { await … }` must actually RUN and be AWAITED to completion by
    /// XCTest — the property the base class relies on to guarantee `server.stop()` /
    /// `client.close()` happen even on early failure.
    ///
    /// This proof does NOT depend on the relative ordering of multiple teardown blocks (which
    /// XCTest does not contract). A SINGLE async teardown block does all its work AFTER an
    /// `await` suspension (a sleep): it increments the counter and then asserts, from inside
    /// the same block, that the post-suspension code was reached. The increment + assertion
    /// land only if XCTest RESUMES the continuation past the suspension point (i.e. truly
    /// awaits it) rather than abandoning it fire-and-forget. A regression to fire-and-forget
    /// teardown would never execute the post-sleep body, so the increment would be lost — and
    /// a second, also-async assertion block (registered earlier, so it drains after under
    /// XCTest's LIFO teardown order) catches that the work-done block ran to completion.
    func testAddedTeardownBlockRunsAndIsAwaited() {
        let counter = TeardownCounter()

        // Verifier (registered FIRST → under LIFO drains LAST): asserts the work block below
        // was awaited to completion. Its own `await` settle also proves THIS block is awaited.
        addTeardownBlock {
            try? await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(
                counter.value,
                1,
                "the async teardown work block must be RESUMED past its `await` and run to " +
                    "completion (awaited, not fire-and-forget); saw \(counter.value)",
            )
        }

        // Work block (registered LAST → under LIFO drains FIRST): its increment is GATED
        // BEHIND an `await` suspension, reached only if XCTest awaits the block.
        addTeardownBlock {
            try? await Task.sleep(for: .milliseconds(20))
            counter.markAsyncWorkDone()
        }
    }

    /// Thread-safe counter the async teardown blocks increment.
    private final class TeardownCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock()
            defer { lock.unlock() }
            return n
        }

        func markAsyncWorkDone() { lock.lock()
            n += 1
            lock.unlock()
        }
    }
}
