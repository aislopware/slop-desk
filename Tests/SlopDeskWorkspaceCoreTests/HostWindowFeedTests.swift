import XCTest
@testable import SlopDeskWorkspaceCore

/// The host-windows feed store (docs/45 §7): structural-vs-volatile publication discipline,
/// position-stable ordering, liveness transitions, sectioning/filter purity, and the renewal loop's
/// lifecycle gating (a collapsed rail = ZERO wire traffic — the 200 GB wifi-flap lesson).
/// Headless — the seam is a fake; no video module, no sockets.
@MainActor
final class HostWindowFeedTests: XCTestCase {
    override func tearDown() {
        HostWindowFeedQuery.shared = nil
        super.tearDown()
    }

    private func window(
        id: UInt32,
        app: String = "Ghostty",
        bundle: String = "com.ghostty",
        title: String = "zsh",
        onScreen: Bool = true,
        focused: Bool = false,
    ) -> HostWindowInfo {
        HostWindowInfo(
            windowID: id, bundleID: bundle, appName: app, title: title, widthPt: 800, heightPt: 600,
            isOnScreen: onScreen, isFocused: focused,
        )
    }

    private func feed(
        active: Bool = true, connected: Bool = true,
        renewalGap: Duration = .milliseconds(5), idleGap: Duration = .milliseconds(5),
    ) -> HostWindowFeed {
        HostWindowFeed(
            isActive: { active }, isConnected: { connected },
            renewalGap: renewalGap, idleGap: idleGap,
        )
    }

    // MARK: apply() — structure

    func testFirstSnapshotSeedsInReceivedOrder() {
        let f = feed()
        f.apply([window(id: 3), window(id: 1), window(id: 2)], generation: 1)
        XCTAssertEqual(f.structure.map(\.windowID), [3, 1, 2], "seed = host z-order, verbatim")
        XCTAssertTrue(f.hasEverLoaded)
        XCTAssertTrue(f.isLive)
        XCTAssertEqual(f.knownGeneration, 1)
    }

    func testPositionsFreezeAcrossReorderedSnapshots() {
        let f = feed()
        f.apply([window(id: 1), window(id: 2)], generation: 1)
        let before = f.structure
        // The host's z-order flipped (⌘Tab) — the rail's geography must NOT move (docs/45 §1).
        f.apply([window(id: 2), window(id: 1)], generation: 2)
        XCTAssertEqual(f.structure, before, "focus flips restyle, never reorder")
    }

    func testRemovalDropsInPlaceAndNewWindowsAppend() {
        let f = feed()
        f.apply([window(id: 1), window(id: 2), window(id: 3)], generation: 1)
        f.apply([window(id: 3), window(id: 4), window(id: 1)], generation: 2)
        XCTAssertEqual(
            f.structure.map(\.windowID), [1, 3, 4],
            "survivors keep frozen positions; the new window appends",
        )
    }

    func testUnchangedSnapshotPublishesNoStructuralChange() {
        let f = feed()
        f.apply([window(id: 1)], generation: 1)
        let before = f.structure
        f.apply([window(id: 1)], generation: 2)
        // Same value ⇒ the diff-before-publish guard skipped the write (Equatable identity is the
        // observable's currency; pinning the ARRAY VALUE is what the guard promises).
        XCTAssertEqual(f.structure, before)
    }

    // MARK: apply() — volatile fields

    func testTitleChangeUpdatesTitlesButNotStructure() {
        let f = feed()
        f.apply([window(id: 1, title: "make")], generation: 1)
        let structureBefore = f.structure
        f.apply([window(id: 1, title: "make test")], generation: 2)
        XCTAssertEqual(f.structure, structureBefore, "title is volatile — never structural")
        XCTAssertEqual(f.titles[1], "make test")
    }

    func testFrontmostTracksTheFocusedFlag() {
        let f = feed()
        f.apply([window(id: 1), window(id: 2, focused: true)], generation: 1)
        XCTAssertEqual(f.frontmostWindowID, 2)
        f.apply([window(id: 1, focused: true), window(id: 2)], generation: 2)
        XCTAssertEqual(f.frontmostWindowID, 1)
        f.apply([window(id: 1), window(id: 2)], generation: 3)
        XCTAssertNil(f.frontmostWindowID)
    }

    // MARK: fold() — liveness

    func testCurrentAckKeepsLivenessAndUnansweredRoundsDropIt() {
        let f = feed()
        f.apply([window(id: 1)], generation: 5)
        f.fold(.current(generation: 5))
        XCTAssertTrue(f.isLive)
        f.fold(nil)
        XCTAssertTrue(f.isLive, "one lost round is UDP weather, not an outage")
        f.fold(nil)
        XCTAssertFalse(f.isLive, "two consecutive unanswered rounds dim the rail")
        // The next answered round restores liveness.
        f.fold(.snapshot(generation: 6, windows: [window(id: 1)]))
        XCTAssertTrue(f.isLive)
    }

    func testMismatchedCurrentAckDoesNotMarkLive() {
        let f = feed()
        f.apply([window(id: 1)], generation: 5)
        f.fold(nil)
        f.fold(nil)
        XCTAssertFalse(f.isLive)
        // A stale/duplicated ack for a DIFFERENT generation is not confirmation of what we hold.
        f.fold(.current(generation: 4))
        XCTAssertFalse(f.isLive)
        f.fold(.current(generation: 5))
        XCTAssertTrue(f.isLive)
    }

    // MARK: Sectioning + filter (pure)

    func testSectionsAlphabeticalCaseInsensitiveRowsFirstSeen() {
        let f = feed()
        f.apply([
            window(id: 1, app: "zed", bundle: "dev.zed"),
            window(id: 2, app: "Ghostty"),
            window(id: 3, app: "zed", bundle: "dev.zed"),
        ], generation: 1)
        let sections = HostWindowFeed.sectioned(f.structure)
        XCTAssertEqual(sections.map(\.appName), ["Ghostty", "zed"], "alphabetical, case-insensitive")
        XCTAssertEqual(sections[1].rows.map(\.windowID), [1, 3], "rows keep first-seen order")
    }

    func testFilterIsTokenANDOverTitleAndAppName() {
        let structure = [
            HostWindowIdentity(windowID: 1, bundleID: "b", appName: "Ghostty"),
            HostWindowIdentity(windowID: 2, bundleID: "b", appName: "Safari"),
        ]
        let titles: [UInt32: String] = [1: "make test — slop-desk", 2: "slop-desk PR"]
        XCTAssertEqual(
            HostWindowFeed.filtered(structure, titles: titles, query: "slop ghost").map(\.windowID),
            [1],
            "every token must match in title OR app name",
        )
        XCTAssertEqual(
            HostWindowFeed.filtered(structure, titles: titles, query: " ").map(\.windowID),
            [1, 2],
            "a blank query matches everything",
        )
    }

    // MARK: run() — lifecycle gating

    func testLoopIdlesWithZeroQueriesWhileInactive() async {
        let counter = QueryCounter()
        HostWindowFeedQuery.shared = { _, _, _, _ in
            counter.count += 1
            return .current(generation: 0)
        }
        let f = feed(active: false)
        let task = Task { await f.run() }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value
        XCTAssertEqual(counter.count, 0, "a collapsed rail costs the host 0 Hz — no wire traffic at all")
    }

    func testLoopRenewsWhileActiveAndAppliesSnapshots() async {
        let counter = QueryCounter()
        HostWindowFeedQuery.shared = { [self] _, _, _, known in
            counter.count += 1
            return known == 7 ? .current(generation: 7)
                : .snapshot(generation: 7, windows: [window(id: 1)])
        }
        let f = feed()
        let task = Task { await f.run() }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        _ = await task.value
        XCTAssertGreaterThanOrEqual(counter.count, 2, "renewals keep flowing on the gap cadence")
        XCTAssertEqual(f.structure.map(\.windowID), [1])
        XCTAssertEqual(f.knownGeneration, 7)
        XCTAssertTrue(f.isLive)
    }

    func testLoopMarksStaleWhenGatesClose() async {
        let gate = Gate()
        HostWindowFeedQuery.shared = { [self] _, _, _, _ in
            .snapshot(generation: 1, windows: [window(id: 1)])
        }
        let f = HostWindowFeed(
            isActive: { gate.open }, isConnected: { true },
            renewalGap: .milliseconds(5), idleGap: .milliseconds(5),
        )
        let task = Task { await f.run() }
        try? await Task.sleep(for: .milliseconds(40))
        gate.open = false
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        _ = await task.value
        XCTAssertTrue(f.hasEverLoaded)
        XCTAssertFalse(f.isLive, "closed gates dim the rail (cached rows stay for instant reveal)")
        XCTAssertEqual(f.structure.map(\.windowID), [1], "cached rows survive the gate closing")
    }
}

/// Main-actor mutable capture boxes for the loop tests (Swift 6: no captured vars in @Sendable).
@MainActor
private final class QueryCounter { var count = 0 }
@MainActor
private final class Gate { var open = true }
