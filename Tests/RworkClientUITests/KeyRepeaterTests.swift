import XCTest
@testable import RworkClientUI

/// Drives the ``KeyRepeater`` cadence with the deterministic ``ManualRepeatScheduler`` (virtual
/// time, no wall clock): initial fire is immediate, then +350ms, then +50ms (20Hz), stopping
/// on release. The whole point of the scheduler seam is making this assertable to the exact ms.
final class KeyRepeaterTests: XCTestCase {

    /// A thread-safe sink for the keys the repeater fired.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ s: String) { lock.lock(); values.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
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

        repeater.keyDown("a")            // immediate fire (1)
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

        repeater.keyDown("x")                  // (1)
        scheduler.advance(by: .milliseconds(350)) // (2) first repeat
        scheduler.advance(by: .milliseconds(50))  // (3)
        XCTAssertEqual(sink.count, 3)

        repeater.keyUp("x")
        XCTAssertFalse(repeater.isRepeating)

        // No further fires after release, regardless of how much time passes.
        scheduler.advance(by: .seconds(10))
        XCTAssertEqual(sink.count, 3, "release stops the repeat")
        XCTAssertEqual(scheduler.pendingCount, 0, "no timer left armed after release")
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

        repeater.keyDown("→")                  // immediate "→"
        scheduler.advance(by: .milliseconds(350)) // repeat "→"
        XCTAssertEqual(sink.all, ["→", "→"])

        // Press a different key: it supersedes, fires immediately, and the old repeat is gone.
        repeater.keyDown("←")
        XCTAssertEqual(repeater.currentKey, "←")
        XCTAssertEqual(sink.all.last, "←")

        scheduler.advance(by: .milliseconds(350)) // repeat the NEW key only
        XCTAssertEqual(sink.all.suffix(2), ["←", "←"])
    }

    func testSameKeyDownIsIdempotent() {
        let scheduler = ManualRepeatScheduler()
        let sink = Sink()
        let repeater = KeyRepeater<String>(scheduler: scheduler) { sink.append($0) }

        repeater.keyDown("a")  // fires once
        repeater.keyDown("a")  // already repeating — no extra immediate fire, no new timer
        XCTAssertEqual(sink.count, 1)
        XCTAssertEqual(scheduler.pendingCount, 1, "still exactly one armed timer")
    }
}
