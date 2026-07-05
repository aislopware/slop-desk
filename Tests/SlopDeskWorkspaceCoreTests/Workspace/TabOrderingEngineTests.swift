import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``TabOrderingEngine`` — the PURE engine (E6 plan WI-3) that derives the rendered sidebar
/// sections from the tab list + the grouping/sort preference. Headless: no SwiftUI, no clock (the caller
/// passes `now`), no socket — `groups(...)` is a pure static over plain values.
///
/// Pins the contract the store-backed hamburger (ES-E6-4/ES-E6-5) leans on: Created/Manual preserve array
/// order, Updated is a stable recency-desc sort with nil-last, and grouping buckets deterministically
/// (none / byProject + Other / byDate Today-Yesterday-Earlier). Each assertion fails before the engine
/// exists (revert-to-confirm-fail = the type is absent → compile failure).
final class TabOrderingEngineTests: XCTestCase {
    // MARK: Fixtures

    /// A single-leaf tab whose `activePane` is the leaf id (so `projectKey(tab.activePane)` resolves).
    private func makeTab() -> (Tab, PaneID) {
        let pane = PaneID()
        return (Tab(root: .leaf(pane), activePane: pane), pane)
    }

    /// Build N single-leaf tabs, returning the tabs + their (tabID, paneID) tuples in array order.
    private func makeTabs(_ count: Int) -> (tabs: [Tab], tabIDs: [TabID], paneIDs: [PaneID]) {
        var tabs: [Tab] = []
        var tabIDs: [TabID] = []
        var paneIDs: [PaneID] = []
        for _ in 0..<count {
            let (tab, pane) = makeTab()
            tabs.append(tab)
            tabIDs.append(tab.id)
            paneIDs.append(pane)
        }
        return (tabs, tabIDs, paneIDs)
    }

    private func noProjectKey(_: PaneID) -> String? { nil }
    private func noRecency(_: TabID) -> Date? { nil }

    // MARK: - Sort: Created / Manual == array order

    func testCreatedSortPreservesArrayOrderInOneFlatGroup() {
        let (tabs, ids, _) = makeTabs(3)
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .none, sort: .created,
            projectKey: noProjectKey, lastActiveAt: noRecency, now: Date(),
        )
        XCTAssertEqual(groups.count, 1, ".none ⇒ exactly one group")
        XCTAssertNil(groups[0].header, "the ungrouped group has no header chrome")
        XCTAssertEqual(groups[0].tabIDs, ids, "Created preserves the tabs array order")
    }

    func testManualSortPreservesArrayOrderEvenWithRecency() {
        let (tabs, ids, _) = makeTabs(3)
        // Even with recency present, Manual must IGNORE it and keep array order.
        let recency: [TabID: Date] = [
            ids[0]: Date(timeIntervalSinceReferenceDate: 1),
            ids[2]: Date(timeIntervalSinceReferenceDate: 9),
        ]
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .none, sort: .manual,
            projectKey: noProjectKey, lastActiveAt: { recency[$0] }, now: Date(),
        )
        XCTAssertEqual(groups[0].tabIDs, ids, "Manual preserves array order, ignoring recency")
    }

    // MARK: - Sort: Updated == recency desc, nil last, stable ties

    func testUpdatedSortIsRecencyDescendingWithNilLast() {
        let (tabs, ids, _) = makeTabs(3)
        // id0 oldest, id2 newest, id1 has NO stamp ⇒ nil sorts last.
        let recency: [TabID: Date] = [
            ids[0]: Date(timeIntervalSinceReferenceDate: 100),
            ids[2]: Date(timeIntervalSinceReferenceDate: 900),
        ]
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .none, sort: .updated,
            projectKey: noProjectKey, lastActiveAt: { recency[$0] }, now: Date(),
        )
        XCTAssertEqual(
            groups[0].tabIDs,
            [ids[2], ids[0], ids[1]],
            "Updated: newest first, then older, then the unstamped (nil) tab last",
        )
    }

    func testUpdatedSortIsStableOnEqualTimestamps() {
        let (tabs, ids, _) = makeTabs(3)
        // id0 and id1 share the SAME timestamp; a stable sort keeps their array order; id2 is nil → last.
        let same = Date(timeIntervalSinceReferenceDate: 500)
        let recency: [TabID: Date] = [ids[0]: same, ids[1]: same]
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .none, sort: .updated,
            projectKey: noProjectKey, lastActiveAt: { recency[$0] }, now: Date(),
        )
        XCTAssertEqual(
            groups[0].tabIDs,
            [ids[0], ids[1], ids[2]],
            "equal timestamps preserve array order (stable); nil sorts last",
        )
    }

    // MARK: - Grouping: By Project (buckets + Other + first-appearance order + headers)

    func testByProjectBucketsByKeyWithOtherAndFirstAppearanceOrder() {
        let (tabs, ids, panes) = makeTabs(4)
        // foo, bar, foo (again), <none> ⇒ buckets foo[0,2], bar[1], Other[3]; group order = first appearance.
        let keys: [PaneID: String] = [
            panes[0]: "/Users/me/foo",
            panes[1]: "/Users/me/bar",
            panes[2]: "/Users/me/foo",
            // panes[3] has no key ⇒ Other
        ]
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .byProject, sort: .created,
            projectKey: { keys[$0] }, lastActiveAt: noRecency, now: Date(),
        )
        XCTAssertEqual(
            groups.map(\.header),
            ["foo", "bar", "Other"],
            "headers = last path component; keyless ⇒ Other; order = first appearance",
        )
        XCTAssertEqual(groups[0].tabIDs, [ids[0], ids[2]], "the foo bucket holds both foo tabs in array order")
        XCTAssertEqual(groups[1].tabIDs, [ids[1]])
        XCTAssertEqual(groups[2].tabIDs, [ids[3]], "the keyless tab lands in Other")
    }

    func testByProjectTreatsEmptyKeyAsOther() {
        let (tabs, _, _) = makeTabs(1)
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .byProject, sort: .created,
            projectKey: { _ in "   " }, lastActiveAt: noRecency, now: Date(),
        )
        XCTAssertEqual(groups.map(\.header), ["Other"], "a whitespace-only key is treated as absent ⇒ Other")
    }

    // MARK: - Grouping: By Date (Today / Yesterday / Earlier against a fixed now)

    func testByDateBucketsTodayYesterdayEarlierAgainstFixedNow() {
        let calendar = Calendar.current
        // Noon today (relative to a fixed reference) → a 12h margin keeps the deltas squarely in each bucket
        // regardless of the test machine's timezone.
        let now = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 700_000_000))
            .addingTimeInterval(12 * 3600)
        let (tabs, ids, _) = makeTabs(4)
        let recency: [TabID: Date] = [
            ids[0]: now, // Today
            ids[1]: now.addingTimeInterval(-24 * 3600), // Yesterday (noon yesterday)
            ids[2]: now.addingTimeInterval(-72 * 3600), // Earlier (3 days ago)
            // ids[3] has no stamp ⇒ Earlier
        ]
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .byDate, sort: .created,
            projectKey: noProjectKey, lastActiveAt: { recency[$0] }, now: now,
        )
        XCTAssertEqual(
            groups.map(\.header),
            ["Today", "Yesterday", "Earlier"],
            "fixed Today → Yesterday → Earlier order, empty buckets omitted",
        )
        XCTAssertEqual(groups[0].tabIDs, [ids[0]])
        XCTAssertEqual(groups[1].tabIDs, [ids[1]])
        XCTAssertEqual(
            groups[2].tabIDs,
            [ids[2], ids[3]],
            "the 3-days-ago tab and the unstamped tab both land in Earlier",
        )
    }

    func testByDateOmitsEmptyBuckets() {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 700_000_000))
            .addingTimeInterval(12 * 3600)
        let (tabs, ids, _) = makeTabs(1)
        let groups = TabOrderingEngine.groups(
            tabs: tabs, grouping: .byDate, sort: .created,
            projectKey: noProjectKey, lastActiveAt: { _ in now }, now: now,
        )
        XCTAssertEqual(groups.map(\.header), ["Today"], "only the non-empty Today bucket is emitted")
        XCTAssertEqual(groups[0].tabIDs, [ids[0]])
    }

    // MARK: - Determinism

    func testEmptyTabsYieldsOneEmptyGroupForNone() {
        let groups = TabOrderingEngine.groups(
            tabs: [], grouping: .none, sort: .created,
            projectKey: noProjectKey, lastActiveAt: noRecency, now: Date(),
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tabIDs, [])
    }
}
