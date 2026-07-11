import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// PURE Phase-2 push-feed rules (docs/45 §6): subscriber TTL/reap/bounds, structural-vs-volatile
/// classification, coalesce gates, and burst cadence. Headless.
final class WindowFeedPushLogicTests: XCTestCase {
    // MARK: Subscriber table

    func testRenewalRefreshesAndTTLReaps() {
        var table = WindowFeedSubscriberTable(ttl: 6, capacity: 8)
        table.renew(1, now: 100)
        table.renew(2, now: 102)
        // Subscriber 1 keeps renewing; 2 goes silent.
        table.renew(1, now: 104)
        XCTAssertEqual(table.reapExpired(now: 108.5), [2], "3 missed renewals reap the silent one")
        XCTAssertEqual(table.subscribers(now: 108.5), [1])
        XCTAssertEqual(table.reapExpired(now: 120), [1], "everyone silent → table empties")
        XCTAssertTrue(table.isEmpty)
    }

    func testTableIsBoundedAndRefusesFreshOverflow() {
        var table = WindowFeedSubscriberTable(ttl: 6, capacity: 2)
        XCTAssertTrue(table.renew(1, now: 100))
        XCTAssertTrue(table.renew(2, now: 100))
        XCTAssertFalse(table.renew(3, now: 100.5), "full of fresh subscribers → a new id is refused")
        XCTAssertTrue(table.renew(3, now: 107), "stale entries prune to admit the newcomer")
    }

    // MARK: Classification

    private func record(
        id: UInt32, w: UInt16 = 800, title: String = "t",
        flags: HostWindowFlags = [.onScreen],
    ) -> HostWindowRecord {
        HostWindowRecord(
            windowID: id, widthPt: w, heightPt: 600, flags: flags, displayIndex: 0,
            bundleID: "b", appName: "a", title: title,
        )
    }

    func testClassifyStructuralOnSetVisibilityAndSize() {
        let base = [record(id: 1), record(id: 2)]
        XCTAssertEqual(WindowFeedPushPolicy.classify(old: base, new: base), .none)
        XCTAssertEqual(
            WindowFeedPushPolicy.classify(old: base, new: [record(id: 1)]),
            .structural, "a closed window is structural",
        )
        XCTAssertEqual(
            WindowFeedPushPolicy.classify(old: base, new: [record(id: 1), record(id: 2, flags: [])]),
            .structural, "a visibility flip (minimize/hide/Space) is structural",
        )
        XCTAssertEqual(
            WindowFeedPushPolicy.classify(old: base, new: [record(id: 1, w: 900), record(id: 2)]),
            .structural, "a resize is structural",
        )
    }

    func testClassifyVolatileForTitleFocusAndOrder() {
        let base = [record(id: 1), record(id: 2)]
        XCTAssertEqual(
            WindowFeedPushPolicy.classify(old: base, new: [record(id: 1, title: "make"), record(id: 2)]),
            .volatileOnly(titleChanged: true),
        )
        XCTAssertEqual(
            WindowFeedPushPolicy.classify(
                old: base,
                new: [record(id: 1, flags: [.onScreen, .frontmostApp, .focusedWindow]), record(id: 2)],
            ),
            .volatileOnly(titleChanged: false), "focus bits are volatile — a ⌘Tab never bursts",
        )
        XCTAssertEqual(
            WindowFeedPushPolicy.classify(old: base, new: [record(id: 2), record(id: 1)]),
            .volatileOnly(titleChanged: false), "z-order shuffles are volatile",
        )
    }

    // MARK: Fold gates + burst cadence

    func testStructuralFoldsImmediatelyAndOpensBurst() {
        var policy = WindowFeedPushPolicy()
        XCTAssertEqual(policy.tickInterval(now: 100), WindowFeedPushPolicy.idleTick)
        XCTAssertTrue(policy.shouldFold(.structural, now: 100))
        XCTAssertEqual(policy.tickInterval(now: 100.1), WindowFeedPushPolicy.burstTick, "4 Hz inside the burst")
        XCTAssertEqual(policy.tickInterval(now: 103.1), WindowFeedPushPolicy.idleTick, "burst ends after 3 s")
    }

    func testTitleChurnCoalescesAtTwoSeconds() {
        var policy = WindowFeedPushPolicy()
        XCTAssertTrue(policy.shouldFold(.volatileOnly(titleChanged: true), now: 100))
        XCTAssertFalse(policy.shouldFold(.volatileOnly(titleChanged: true), now: 101))
        XCTAssertFalse(policy.shouldFold(.volatileOnly(titleChanged: true), now: 101.9))
        XCTAssertTrue(policy.shouldFold(.volatileOnly(titleChanged: true), now: 102), "≥2 s gate")
        XCTAssertEqual(
            policy.tickInterval(now: 102), WindowFeedPushPolicy.idleTick,
            "title churn NEVER enters burst mode",
        )
    }

    func testFocusOnlyCoalescesAtOneSecond() {
        var policy = WindowFeedPushPolicy()
        XCTAssertTrue(policy.shouldFold(.volatileOnly(titleChanged: false), now: 100))
        XCTAssertFalse(policy.shouldFold(.volatileOnly(titleChanged: false), now: 100.5))
        XCTAssertTrue(policy.shouldFold(.volatileOnly(titleChanged: false), now: 101))
    }

    func testNoneNeverFolds() {
        var policy = WindowFeedPushPolicy()
        XCTAssertFalse(policy.shouldFold(.none, now: 100))
    }
}
