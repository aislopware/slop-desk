import XCTest
@testable import AislopdeskClientUI

/// Drives the ``KeyRepeater`` cadence with the deterministic ``ManualRepeatScheduler`` (virtual
/// time, no wall clock): initial fire is immediate, then +350ms, then +50ms (20Hz), stopping
/// on release. The whole point of the scheduler seam is making this assertable to the exact ms.
final class KeyRepeaterTests: XCTestCase {
    /// A thread-safe sink for the keys the repeater fired.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ s: String) { lock.lock()
            values.append(s)
            lock.unlock()
        }

        var all: [String] { lock.lock()
            defer { lock.unlock() }
            return values
        }

        var count: Int { all.count }
    }

    func testImmediateFireOnKeyDown() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("→")
        // The keypress itself fires synchronously, before any time advances.
        XCTAssertEqual(sink.all, ["→"])
        XCTAssertTrue(repeater.isRepeating)
    }

    func testInitialDelayThenRepeatCadence() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("a") // immediate fire (1)
        XCTAssertEqual(sink.count, 1)

        // Before the 350ms initial delay elapses: no repeat.
        scheduler.advance(by: .milliseconds(349))
        XCTAssertEqual(sink.count, 1, "no repeat before the 350ms initial delay")

        // Crossing 350ms total: the first repeat fires (2).
        scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(sink.count, 2, "first repeat at the 350ms initial delay")

        // Then 50ms (20Hz) cadence: +50ms → (3), +50ms → (4), +50ms → (5).
        scheduler.advance(by: .milliseconds(50))
        XCTAssertEqual(sink.count, 3)
        scheduler.advance(by: .milliseconds(50))
        XCTAssertEqual(sink.count, 4)
        scheduler.advance(by: .milliseconds(150)) // three 50ms intervals at once
        XCTAssertEqual(sink.count, 7, "a large advance fans out the right number of 50ms repeats")

        XCTAssertEqual(Set(sink.all), ["a"], "every fire re-emits the held key")
    }

    func testStopOnKeyUp() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("x") // (1)
        scheduler.advance(by: .milliseconds(350)) // (2) first repeat
        scheduler.advance(by: .milliseconds(50)) // (3)
        XCTAssertEqual(sink.count, 3)

        repeater.keyUp("x")
        XCTAssertFalse(repeater.isRepeating)

        // No further fires after release, regardless of how much time passes.
        scheduler.advance(by: .seconds(10))
        XCTAssertEqual(sink.count, 3, "release stops the repeat")
        XCTAssertEqual(scheduler.pendingCount, 0, "no timer left armed after release")
    }

    /// R10: the software-keyboard Backspace one-shot — a `keyDown` IMMEDIATELY followed by its `keyUp`
    /// (before the 350ms initial delay) must fire EXACTLY ONCE and leave NO armed timer. This is the
    /// semantics `IMEProxyTextView.deleteBackward()` relies on to avoid a 20Hz DEL flood (a software
    /// Backspace has no paired `UIPress` release, so it emits the press+release pair itself).
    func testKeyDownThenImmediateKeyUpFiresExactlyOnce() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("\u{7F}") // fires one DEL synchronously + arms the 350ms timer
        repeater.keyUp("\u{7F}") // immediate release cancels the timer before it can repeat
        XCTAssertEqual(sink.all, ["\u{7F}"], "exactly one DEL fired")
        XCTAssertFalse(repeater.isRepeating)
        XCTAssertEqual(scheduler.pendingCount, 0, "no timer left armed → no 20Hz DEL flood")

        scheduler.advance(by: .seconds(10))
        XCTAssertEqual(sink.count, 1, "a one-shot stays one — never repeats")
    }

    func testKeyUpForUnheldKeyIsIgnored() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("a")
        scheduler.advance(by: .milliseconds(350)) // a repeating
        XCTAssertEqual(sink.count, 2)

        // A stale keyUp for a different key must NOT cancel the active repeat.
        repeater.keyUp("b")
        XCTAssertTrue(repeater.isRepeating)
        scheduler.advance(by: .milliseconds(50))
        XCTAssertEqual(sink.count, 3, "unrelated keyUp did not stop repeating 'a'")
    }

    func testLastKeyWinsOnNewKeyDown() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("→") // immediate "→"
        scheduler.advance(by: .milliseconds(350)) // repeat "→"
        XCTAssertEqual(sink.all, ["→", "→"])

        // Press a different key: it supersedes, fires immediately, and the old repeat is gone.
        repeater.keyDown("←")
        XCTAssertEqual(repeater.currentKey, "←")
        XCTAssertEqual(sink.all.last, "←")

        scheduler.advance(by: .milliseconds(350)) // repeat the NEW key only
        XCTAssertEqual(sink.all.suffix(2), ["←", "←"])
    }

    /// Integration test against the PRODUCTION ``DispatchRepeatScheduler`` (real
    /// `DispatchSourceTimer` on its background queue) — the one that actually ships, and the
    /// one ``ManualRepeatScheduler`` does NOT exercise. Asserts the real one-shot→repeating
    /// handle handoff fires at least twice within a bounded window, and that `keyUp` stops it
    /// (zero further fires). The repeater's `heldKey`/`handle` are read/reassigned from the
    /// scheduler's background queue here while `keyDown`/`keyUp` run on the test thread, so
    /// running this under ThreadSanitizer surfaces any unsynchronised access to that state.
    /// Uses an `XCTestExpectation` (await fulfillment, not `sleep`).
    func testDispatchSchedulerFiresAndStopsOnRelease() {
        // Short cadence so the test is fast but still crosses the real timer twice.
        let timing = KeyRepeater<String>.Timing(initialDelay: .milliseconds(30), repeatInterval: .milliseconds(20))
        let scheduler = DispatchRepeatScheduler()
        let sink = Sink()

        let gotTwo = expectation(description: "at least two fires via the real DispatchSourceTimer")
        gotTwo.assertForOverFulfill = false
        let repeater = KeyRepeater<String>(timing: timing, scheduler: scheduler) { key in
            sink.append(key)
            if sink.count >= 2 { gotTwo.fulfill() } // immediate + ≥1 timer fire
        }

        repeater.keyDown("→") // immediate fire (1) + arms the initial-delay timer
        wait(for: [gotTwo], timeout: 2.0)
        XCTAssertGreaterThanOrEqual(sink.count, 2, "real timer produced repeats")

        repeater.keyUp("→")
        XCTAssertFalse(repeater.isRepeating)
        let afterRelease = sink.count

        // No further fires after release. Drain the queue with a flush expectation rather than
        // a fixed sleep: schedule a marker on the SAME serial queue and wait for it; by the
        // time it runs, any in-flight timer fire has already been observed.
        let drained = expectation(description: "queue drained after release")
        DispatchQueue(label: "aislopdesk.keyrepeat").asyncAfter(deadline: .now() + 0.12) { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
        XCTAssertEqual(sink.count, afterRelease, "release stops the real repeating timer — no fires after keyUp")
    }

    func testSameKeyDownIsIdempotent() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("a") // fires once
        repeater.keyDown("a") // already repeating — no extra immediate fire, no new timer
        XCTAssertEqual(sink.count, 1)
        XCTAssertEqual(scheduler.pendingCount, 1, "still exactly one armed timer")
    }

    /// Regression for the iOS modifier-release-first RUNAWAY repeat (round-2 [1]). The repeat key is a
    /// modifier-INDEPENDENT physical identity carrying the modifier-laden press as payload (see
    /// `TerminalInputHost.RepeatKey`). A `keyUp` whose PAYLOAD differs — the modifier was released
    /// BEFORE the letter, so the letter's release classifies as a plain key — but whose IDENTITY
    /// matches the held key MUST stop the repeat. Without identity-equality the held Ctrl+letter would
    /// repeat forever (a 20Hz control-code flood). This proves the equality contract the fix relies on.
    func testKeyUpMatchingByIdentityNotPayloadStopsRunawayRepeat() {
        struct IdKey: Hashable {
            let identity: String
            let payload: String
            static func == (a: Self, b: Self) -> Bool { a.identity == b.identity }
            func hash(into h: inout Hasher) { h.combine(identity) }
        }
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<IdKey>(scheduler: scheduler) { sink.append($0.payload) }

        // Hold "Ctrl+L": identity "l", payload encodes the control combo.
        repeater.keyDown(IdKey(identity: "l", payload: "ctrl-l"))
        XCTAssertEqual(sink.all, ["ctrl-l"])
        scheduler.advance(by: .milliseconds(350))
        XCTAssertEqual(sink.count, 2, "repeating the control combo")

        // Modifier released first → the letter's keyUp arrives as a PLAIN "l" (different payload,
        // SAME identity). It must stop the repeat.
        repeater.keyUp(IdKey(identity: "l", payload: "plain-l"))
        XCTAssertFalse(repeater.isRepeating, "keyUp matched by identity (not payload) must stop the repeat")

        let after = sink.count
        scheduler.advance(by: .milliseconds(500))
        XCTAssertEqual(sink.count, after, "no runaway flood after the identity-matched release")
    }
}
