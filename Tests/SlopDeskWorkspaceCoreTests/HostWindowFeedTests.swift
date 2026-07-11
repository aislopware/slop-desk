import XCTest
@testable import SlopDeskWorkspaceCore

/// The host-windows feed store (docs/45 §7): structural-vs-volatile publication discipline,
/// position-stable ordering, liveness transitions, sectioning/filter purity, and the renewal loop's
/// lifecycle gating (a collapsed rail = ZERO wire traffic — the 200 GB wifi-flap lesson).
/// Headless — the seam is a fake; no video module, no sockets.
@MainActor
final class HostWindowFeedTests: XCTestCase {
    override func tearDown() {
        HostWindowFeedQuery.openLink = nil
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
            renewalGap: renewalGap, firstAnswerGap: .milliseconds(5), idleGap: idleGap,
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

    func testPushedSnapshotsApplyLikeRenewalReplies() {
        // Phase 2: a push is just an unsolicited answer on the held lane — same fold path.
        let f = feed()
        f.fold(.snapshot(generation: 5, windows: [window(id: 1)]))
        XCTAssertTrue(f.isLive)
        XCTAssertEqual(f.knownGeneration, 5)
        f.fold(.snapshot(generation: 6, windows: [window(id: 1), window(id: 2)]))
        XCTAssertEqual(f.structure.map(\.windowID), [1, 2])
        XCTAssertEqual(f.knownGeneration, 6)
    }

    func testMismatchedCurrentAckDoesNotMarkLive() {
        let f = feed()
        f.apply([window(id: 1)], generation: 5)
        // Force the dimmed state via the loop-side gate closing, then probe the ack rule directly.
        f.fold(.current(generation: 4))
        XCTAssertTrue(f.isLive, "an ack never DROPS liveness")
        let g = feed()
        g.apply([window(id: 1)], generation: 5)
        // A stale/duplicated ack for a DIFFERENT generation is not confirmation of what we hold:
        // it must not RESTORE liveness once lost.
        g.setLiveForTesting(false)
        g.fold(.current(generation: 4))
        XCTAssertFalse(g.isLive)
        g.fold(.current(generation: 5))
        XCTAssertTrue(g.isLive)
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

    // MARK: run() — lifecycle gating over the persistent link

    func testLoopOpensNoLinkWhileInactive() async {
        let tracker = LinkTracker()
        HostWindowFeedQuery.openLink = { _, _, _, onAnswer in tracker.open(onAnswer: onAnswer) }
        let f = feed(active: false)
        let task = Task { await f.run() }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value
        XCTAssertEqual(tracker.opened, 0, "a collapsed rail costs the host 0 Hz — no lane, no traffic")
    }

    func testLoopHoldsOneLinkRenewsAndReceivesPushes() async {
        let tracker = LinkTracker()
        HostWindowFeedQuery.openLink = { _, _, _, onAnswer in tracker.open(onAnswer: onAnswer) }
        let f = feed()
        let task = Task { await f.run() }
        try? await Task.sleep(for: .milliseconds(40))
        // The host answers the renewal…
        tracker.push(.snapshot(generation: 7, windows: [window(id: 1)]))
        try? await Task.sleep(for: .milliseconds(20))
        // …and later PUSHES a bump between renewals (Phase 2) — no send required.
        tracker.push(.snapshot(generation: 8, windows: [window(id: 1), window(id: 2)]))
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value
        XCTAssertEqual(tracker.opened, 1, "ONE persistent lane per active stretch, never per renewal")
        XCTAssertGreaterThanOrEqual(tracker.sends, 2, "renewals keep flowing on the gap cadence")
        XCTAssertEqual(f.structure.map(\.windowID), [1, 2], "the push applied without a renewal")
        XCTAssertEqual(f.knownGeneration, 8)
        XCTAssertTrue(f.isLive)
    }

    func testLoopClosesLinkAndDimsWhenGatesClose() async {
        let tracker = LinkTracker()
        let gate = Gate()
        HostWindowFeedQuery.openLink = { _, _, _, onAnswer in tracker.open(onAnswer: onAnswer) }
        let f = HostWindowFeed(
            isActive: { gate.open }, isConnected: { true },
            renewalGap: .milliseconds(5), firstAnswerGap: .milliseconds(5), idleGap: .milliseconds(5),
        )
        let task = Task { await f.run() }
        try? await Task.sleep(for: .milliseconds(30))
        tracker.push(.snapshot(generation: 1, windows: [window(id: 1)]))
        try? await Task.sleep(for: .milliseconds(20))
        gate.open = false
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        _ = await task.value
        XCTAssertTrue(f.hasEverLoaded)
        XCTAssertFalse(f.isLive, "closed gates dim the rail (cached rows stay for instant reveal)")
        XCTAssertEqual(f.structure.map(\.windowID), [1], "cached rows survive the gate closing")
        XCTAssertEqual(tracker.closed, 1, "the lane is released the moment the gates close")
    }
}

/// Fake lane factory for the loop tests: counts opens/sends/closes and lets the test PUSH answers
/// (the Phase-2 shape). Main-actor (Swift 6: no captured vars in @Sendable).
@MainActor
private final class LinkTracker {
    private(set) var opened = 0
    private(set) var sends = 0
    private(set) var closed = 0
    private var sink: (@MainActor (HostWindowFeedAnswer) -> Void)?

    func open(onAnswer: @escaping @MainActor (HostWindowFeedAnswer) -> Void) -> any HostWindowFeedLink {
        opened += 1
        sink = onAnswer
        return FakeLink(tracker: self)
    }

    func push(_ answer: HostWindowFeedAnswer) { sink?(answer) }

    /// Each renewal is acked `.current` like a real quiet host, so liveness never times out
    /// mid-test between the explicit pushes.
    func noteSend(knownGeneration: UInt32) {
        sends += 1
        sink?(.current(generation: knownGeneration))
    }

    func noteClose() {
        closed += 1
        sink = nil
    }

    private final class FakeLink: HostWindowFeedLink {
        private let tracker: LinkTracker
        init(tracker: LinkTracker) { self.tracker = tracker }
        func send(knownGeneration: UInt32) { tracker.noteSend(knownGeneration: knownGeneration) }
        func close() { tracker.noteClose() }
    }
}

@MainActor
private final class Gate { var open = true }
