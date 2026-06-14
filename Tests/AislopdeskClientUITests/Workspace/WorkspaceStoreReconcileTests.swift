import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the load-bearing **reconcile** contract of ``WorkspaceStore`` (docs/22 §2.3, §8): the diff
/// that keeps the `[PaneID: any PaneSessionHandle]` table of liveness 1:1 with the panes of the pure
/// single ``Canvas`` of intent after **every** mutation. This is what guarantees there is exactly one
/// ``LivePaneSession`` (hence one ordered-OUT stream, one events consumer, one `ReconnectManager`) per
/// pane — the four byte-pipeline invariants by construction.
///
/// The whole suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` so it exercises
/// the store's materialize / teardown / id-adoption logic **without ever building a `AislopdeskClient` or a
/// `HostServer`** (forbidden — the latter deadlocks the pool). The assertions are deterministic:
///
/// - **The registry invariant** `Set(registry.keys) == Set(canvas.allIDs())` AND `handle.id == paneID`
///   holds synchronously the instant any mutation returns (init / addPane / closePane / focus / move /
///   toggleZoom / resizePane / updateSpec / group ops / bootstrap).
/// - **Materialization** mints exactly one new idle handle per new pane and ``adopt(id:)``s it to the
///   pane id (`.adopt(paneID)` is the handle's first recorded event — the `.id(PaneID)` identity hazard).
/// - **Teardown** of an orphaned pane runs `teardown()` EXACTLY ONCE, after `quiesce()` (teardown is
///   async, reconcile is synchronous: the registry already excludes the orphan, but the teardown work
///   only completes once the tracked task runs).
/// - **Idempotency** — a no-op-shaped mutation (focusing the already-focused pane) leaves `allSessions`
///   unchanged (no extra makeSession / teardown).
/// - **Group ops are metadata-only** — adding / renaming / removing / assigning / reordering groups
///   never touches the pane set, so the registry is untouched.
/// - **View-only projection** — `updateSolvedLayout(...)`, the only view→store geometry report, never
///   touches the registry (a compact ↔ regular flip does NOT reconcile).
///
/// `WorkspaceStore` is `@MainActor`, so the whole suite is `@MainActor`. The close paths are async
/// (the teardown fan-out is awaited via `quiesce()`); everything else is synchronous.
@MainActor
final class WorkspaceStoreReconcileTests: XCTestCase {
    // MARK: - Fixtures

    /// Builds a store with the ``FakePaneSession`` seam (NEVER a real client/host). `restoring` lets a
    /// test pin a known canvas; default is the one-terminal-pane default workspace.
    private func makeStore(restoring: Workspace? = nil, liveVideoCap: Int = 2) -> WorkspaceStore {
        WorkspaceStore(
            restoring: restoring,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: liveVideoCap,
        )
    }

    /// All pane ids on the single canvas, in z-order (the reconcile diff domain) — the source of truth
    /// the registry is asserted against.
    private func paneIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.workspace.canvas.allIDs()
    }

    /// The set of ids the registry currently holds, surfaced via the only public registry windows
    /// (`allSessions` — order unspecified, hence a Set).
    private func registryIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.allSessions.map(\.id))
    }

    /// The fake handle for `id` (downcast for the recorded-lifecycle accessors), or `nil`.
    private func fake(_ store: WorkspaceStore, _ id: PaneID) -> FakePaneSession? {
        store.handle(for: id) as? FakePaneSession
    }

    /// THE invariant, asserted after every op: the registry keys are exactly the canvas's pane ids, AND
    /// every materialized handle has adopted its pane id (so `handle(for:)` round-trips by identity).
    private func assertInvariant(
        _ store: WorkspaceStore,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let panes = Set(paneIDs(store))
        XCTAssertEqual(registryIDs(store), panes, "registry.keys != canvas.allIDs() \(message)", file: file, line: line)
        XCTAssertEqual(
            store.allSessions.count,
            panes.count,
            "registry has duplicate/extra handles \(message)",
            file: file,
            line: line,
        )
        for id in panes {
            let handle = store.handle(for: id)
            XCTAssertNotNil(handle, "no handle for pane \(id) \(message)", file: file, line: line)
            XCTAssertEqual(handle?.id, id, "handle.id != its pane id (adopt failed) \(message)", file: file, line: line)
        }
    }

    // MARK: - init materializes the default/restored panes

    /// `init` calls `reconcile()` so the default workspace's single terminal pane is materialized
    /// immediately — the registry is non-empty before any mutation, and the invariant already holds.
    func testInitMaterializesDefaultWorkspaceLeaf() {
        let store = makeStore()
        XCTAssertEqual(store.allSessions.count, 1, "default workspace = one terminal pane, materialized at init")
        assertInvariant(store, "after init(default)")

        let pane = paneIDs(store)[0]
        let handle = fake(store, pane)
        XCTAssertEqual(handle?.kind, .terminal, "the materialized session mirrors the pane spec kind")
        XCTAssertEqual(handle?.id, pane, "init adopted the pane id")
        // adopt() is the first thing reconcile does to a fresh handle → first recorded event.
        XCTAssertEqual(
            handle?.events.first,
            .adopt(pane),
            "reconcile re-points identity via adopt(id:) at materialization",
        )
    }

    /// Restoring a multi-pane canvas materializes EVERY pane at init (shape + intent only —
    /// sessions are idle, never connected).
    func testInitMaterializesAllRestoredLeavesAcrossTabs() {
        // Three panes on one canvas: two terminals and a claudeCode.
        let a0 = PaneID(), a1 = PaneID(), b0 = PaneID()
        let restored = Workspace.make(
            panes: [
                (a0, PaneSpec(kind: .terminal, title: "a0")),
                (a1, PaneSpec(kind: .terminal, title: "a1")),
                (b0, PaneSpec(kind: .claudeCode, title: "b0")),
            ],
            focused: a0,
        )

        let store = makeStore(restoring: restored)

        XCTAssertEqual(store.allSessions.count, 3, "all three panes on the canvas materialized at init")
        assertInvariant(store, "after init(restored 3-pane canvas)")
        XCTAssertEqual(fake(store, b0)?.kind, .claudeCode, "pane spec kind preserved through materialization")
        // No connect/video at materialization — sessions are idle.
        XCTAssertEqual(fake(store, b0)?.isVideoActive, false, "materialized session is idle (no video)")
        XCTAssertEqual(fake(store, b0)?.pauseCount, 0, "materialized session is not paused")
    }

    // MARK: - addPane materializes exactly one new pane, focuses it, keeps the originals

    /// Adding a pane makes EXACTLY one new key, preserving the original pane's session by identity
    /// (no churn). `isOnlyLeaf` drives the chrome close-button label: true for the sole pane of a
    /// single-pane canvas, false for every pane once there are two, false for an unknown id.
    func testIsOnlyLeafTracksTabLeafCount() {
        let store = makeStore()
        let solo = paneIDs(store)[0]
        XCTAssertTrue(store.isOnlyLeaf(solo), "the lone pane of a single-pane canvas is the only pane")

        store.addPane(kind: .terminal)
        let panes = paneIDs(store)
        XCTAssertEqual(panes.count, 2)
        for id in panes {
            XCTAssertFalse(store.isOnlyLeaf(id), "with two panes, neither is the only pane (close = close pane)")
        }
        XCTAssertFalse(store.isOnlyLeaf(PaneID()), "an id not on the canvas is not the only pane")
    }

    /// addPane preserves the existing pane's identity (no churn), focuses the new pane, and tears down
    /// nothing.
    func testSplitMaterializesExactlyOneNewLeafAndKeepsOriginal() async throws {
        let store = makeStore()
        let original = paneIDs(store)[0]
        let originalHandle = fake(store, original)

        store.addPane(kind: .terminal)

        let panes = paneIDs(store)
        XCTAssertEqual(panes.count, 2, "addPane goes from 1 → 2 panes")
        assertInvariant(store, "after addPane")

        // The original pane's SAME handle instance survives (identity-stable — not rebuilt).
        XCTAssertTrue(originalHandle === fake(store, original), "addPane does not churn the existing pane's session")

        // Exactly one new key, focused, and never torn down.
        let newPane = panes.first { $0 != original }
        XCTAssertNotNil(newPane, "a new pane id appeared")
        XCTAssertEqual(
            try fake(store, XCTUnwrap(newPane))?.events.first,
            try .adopt(XCTUnwrap(newPane)),
            "new handle adopted the new pane id",
        )
        XCTAssertTrue(try store.isFocused(XCTUnwrap(newPane)), "addPane() focuses the new pane")

        await store.quiesce()
        XCTAssertEqual(originalHandle?.teardownCount, 0, "the surviving original pane is never torn down by an addPane")
    }

    /// Two successive addPanes grow the canvas to three panes: the registry tracks all three and only
    /// ever materializes the two genuinely-new ones.
    func testRepeatedSameAxisSplitMaterializesEachNewLeafOnce() async throws {
        let store = makeStore()
        let l0 = paneIDs(store)[0]

        store.addPane(kind: .terminal)
        let afterFirst = Set(paneIDs(store))
        let l1 = try XCTUnwrap(afterFirst.subtracting([l0]).first)
        assertInvariant(store, "after first addPane")

        store.addPane(kind: .terminal)
        let afterSecond = paneIDs(store)
        XCTAssertEqual(afterSecond.count, 3, "two addPanes grow the canvas to three panes")
        assertInvariant(store, "after second addPane")

        // The first two handles are untouched (no re-materialize, no teardown).
        await store.quiesce()
        XCTAssertEqual(fake(store, l0)?.teardownCount, 0)
        XCTAssertEqual(fake(store, l1)?.teardownCount, 0)
        let l2 = try XCTUnwrap(Set(afterSecond).subtracting([l0, l1]).first)
        XCTAssertEqual(
            fake(store, l2)?.events.first,
            .adopt(l2),
            "only the genuinely-new pane is materialized + adopted",
        )
    }

    // MARK: - closePane tears down the orphan EXACTLY ONCE and removes it

    /// Closing a non-last pane removes its key from the registry SYNCHRONOUSLY (the invariant holds on
    /// return), and after `quiesce()` the orphan's `teardown()` has run EXACTLY ONCE.
    func testClosePaneRemovesKeySynchronouslyAndTearsDownExactlyOnce() async throws {
        let store = makeStore()
        let original = paneIDs(store)[0]
        store.addPane(kind: .terminal)
        let panes = paneIDs(store)
        let victim = try XCTUnwrap(panes.first { $0 != original })
        let survivor = original
        let victimHandle = try XCTUnwrap(fake(store, victim))

        store.closePane(victim)

        // Synchronous: the orphan is gone the instant closePane returns.
        XCTAssertNil(store.handle(for: victim), "orphan removed from the registry synchronously")
        XCTAssertNotNil(store.handle(for: survivor), "the surviving pane stays live")
        XCTAssertEqual(paneIDs(store), [survivor], "canvas collapsed to the survivor")
        assertInvariant(store, "after closePane (pre-quiesce)")
        // teardown is async — it has NOT necessarily run yet, but the registry is already correct.

        await store.quiesce()
        XCTAssertEqual(victimHandle.teardownCount, 1, "the orphaned session's teardown() runs exactly once")
        assertInvariant(store, "after closePane (post-quiesce)")
        // quiesce is idempotent — a second await drives no further teardown.
        await store.quiesce()
        XCTAssertEqual(victimHandle.teardownCount, 1, "quiesce is idempotent; no double teardown")
    }

    /// Closing the LAST pane of the canvas empties the workspace: the registry drains to empty and
    /// that one session is torn down once.
    func testCloseLastLeafEmptiesRegistry() async throws {
        let store = makeStore()
        let only = paneIDs(store)[0]
        let onlyHandle = try XCTUnwrap(fake(store, only))

        store.closePane(only)

        XCTAssertTrue(store.allSessions.isEmpty, "closing the last pane empties the registry")
        XCTAssertTrue(store.workspace.canvas.allIDs().isEmpty, "and empties the canvas")
        XCTAssertNil(store.workspace.focusedPane, "an empty canvas has no focus")
        assertInvariant(store, "after closing the only pane")

        await store.quiesce()
        XCTAssertEqual(onlyHandle.teardownCount, 1, "the lone session is torn down once")
    }

    // MARK: - closing multiple panes tears down each session once

    /// Closing several panes in turn tears down EACH session exactly once, leaving the survivor intact.
    func testCloseTabTearsDownAllItsSessions() async throws {
        // Three panes on one canvas; close two and keep one.
        let a0 = PaneID(), a1 = PaneID(), b0 = PaneID()
        let store = makeStore(restoring: Workspace.make(
            panes: [
                (a0, PaneSpec(kind: .terminal, title: "a0")),
                (a1, PaneSpec(kind: .terminal, title: "a1")),
                (b0, PaneSpec(kind: .terminal, title: "b0")),
            ],
            focused: a0,
        ))

        let a0Handle = try XCTUnwrap(fake(store, a0))
        let a1Handle = try XCTUnwrap(fake(store, a1))
        let b0Handle = try XCTUnwrap(fake(store, b0))

        store.closePane(a0)
        store.closePane(a1)

        // Both closed panes are gone from the registry synchronously; the survivor stays.
        XCTAssertNil(store.handle(for: a0))
        XCTAssertNil(store.handle(for: a1))
        XCTAssertNotNil(store.handle(for: b0))
        XCTAssertEqual(paneIDs(store), [b0], "only the survivor remains")
        assertInvariant(store, "after closing two panes")

        await store.quiesce()
        XCTAssertEqual(a0Handle.teardownCount, 1, "pane a0 torn down once")
        XCTAssertEqual(a1Handle.teardownCount, 1, "pane a1 torn down once")
        XCTAssertEqual(b0Handle.teardownCount, 0, "the surviving session is untouched")
    }

    // MARK: - addPane(inGroup:) materializes its pane and assigns membership

    /// `addPane(inGroup:)` adds a fresh pane inside an existing group and materializes its session —
    /// exactly one new key, the rest of the registry unchanged, and the new pane is a group member.
    func testAddTabMaterializesItsLeaf() throws {
        let store = makeStore()
        let before = registryIDs(store)
        let group = store.addGroup(name: "Work")
        XCTAssertEqual(registryIDs(store), before, "addGroup is metadata-only — no new session")

        store.addPane(kind: .claudeCode, inGroup: group)

        let after = registryIDs(store)
        XCTAssertEqual(after.count, before.count + 1, "addPane materializes exactly one new pane")
        XCTAssertTrue(before.isSubset(of: after), "existing sessions are untouched")
        assertInvariant(store, "after addPane(inGroup:)")

        let newPane = try XCTUnwrap(after.subtracting(before).first)
        XCTAssertEqual(fake(store, newPane)?.kind, .claudeCode, "new pane materialized with its kind")
        XCTAssertEqual(store.workspace.group(ofPane: newPane)?.id, group, "the new pane joined the group")
        XCTAssertTrue(
            store.workspace.canvas.ids(inGroup: group).contains(newPane),
            "the canvas tags the new pane with the group",
        )
    }

    // MARK: - Group arithmetic is pure metadata — registry untouched (add/rename/remove/assign/move)

    /// The group ops (addGroup / renameGroup / removeGroup / assignPane / moveGroup) are pure metadata
    /// on the SAME pane set: each leaves the registry byte-for-byte unchanged (no makeSession, no
    /// teardown), while mutating only the group model / membership.
    func testGroupArithmeticIsMetadataOnly() async {
        let store = makeStore()
        store.addPane(kind: .terminal)
        let panes = paneIDs(store)
        XCTAssertEqual(panes.count, 2)
        let before = store.allSessions.map { ObjectIdentifier($0) }
        assertInvariant(store, "two panes, no groups")

        // addGroup — appends a group; pane set unchanged.
        let g1 = store.addGroup(name: "Alpha")
        XCTAssertEqual(store.workspace.group(g1)?.name, "Alpha", "addGroup added a named group")
        assertInvariant(store, "after addGroup")

        let g2 = store.addGroup(name: "Beta")
        XCTAssertEqual(store.workspace.groupIndex(of: g2), 1, "second group appended after the first")

        // assignPane — moves a pane into a group (disjoint membership).
        store.assignPane(panes[0], toGroup: g1)
        XCTAssertEqual(store.workspace.group(ofPane: panes[0])?.id, g1, "pane joined group Alpha")
        XCTAssertEqual(store.workspace.canvas.ids(inGroup: g1), [panes[0]], "canvas reflects the membership")
        XCTAssertEqual(store.workspace.canvas.ids(inGroup: nil), [panes[1]], "the other pane is still ungrouped")
        assertInvariant(store, "after assignPane")

        // renameGroup — pure relabel.
        store.renameGroup(g1, "Alpha Renamed")
        XCTAssertEqual(store.workspace.group(g1)?.name, "Alpha Renamed", "renameGroup relabels in place")
        assertInvariant(store, "after renameGroup")

        // moveGroup — reorder; both groups survive.
        store.moveGroup(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.workspace.groups.first?.id, g2, "moveGroup reordered the groups")
        assertInvariant(store, "after moveGroup")

        // removeGroup — group gone, but its member pane SURVIVES (now ungrouped).
        store.removeGroup(g1)
        XCTAssertNil(store.workspace.group(g1), "removeGroup deleted the group")
        XCTAssertNil(store.workspace.group(ofPane: panes[0]), "its member pane survives ungrouped")
        XCTAssertTrue(store.workspace.canvas.contains(panes[0]), "removeGroup never closes a pane")
        assertInvariant(store, "after removeGroup")

        // The registry never changed across ANY group op.
        let after = store.allSessions.map { ObjectIdentifier($0) }
        XCTAssertEqual(Set(before), Set(after), "group arithmetic materializes nothing and tears nothing down")
        await store.quiesce()
        for handle in store.allSessions {
            XCTAssertEqual((handle as? FakePaneSession)?.teardownCount, 0, "no spurious teardown from group ops")
        }
    }

    /// `centerOnGroup` only pans the camera over the group's bounding box — a view-only camera move that
    /// leaves the pane set (and hence the registry) untouched.
    func testCenterOnGroupIsViewOnly() {
        let g1 = PaneID(), g2 = PaneID()
        let group = PaneGroup(name: "Cluster")
        let store = makeStore(restoring: Workspace.make(
            panes: [
                (g1, PaneSpec(kind: .terminal, title: "g1")),
                (g2, PaneSpec(kind: .terminal, title: "g2")),
            ],
            focused: g1,
            groups: [group],
        ))
        store.assignPane(g1, toGroup: group.id)
        store.assignPane(g2, toGroup: group.id)
        let before = store.allSessions.map { ObjectIdentifier($0) }

        store.centerOnGroup(group.id)

        XCTAssertEqual(
            Set(store.allSessions.map { ObjectIdentifier($0) }),
            Set(before),
            "centerOnGroup is a camera pan — registry untouched",
        )
        assertInvariant(store, "after centerOnGroup")
    }

    // MARK: - Whole-API invariant sweep (addPane / close / group / move / zoom / focus)

    /// Drives a representative sequence of EVERY mutation and asserts the registry invariant holds the
    /// instant each one returns — the docs/22 §2.3 "holds after any sequence of ops" claim.
    func testInvariantHoldsAfterEveryMutationInASequence() async {
        let store = makeStore()
        assertInvariant(store, "init")

        // addPane (creates a second pane) — needed before move/zoom/focus have neighbours.
        store.addPane(kind: .terminal)
        assertInvariant(store, "addPane #1")
        store.addPane(kind: .terminal)
        assertInvariant(store, "addPane #2")
        let panes = paneIDs(store)
        XCTAssertEqual(panes.count, 3)

        // addGroup + assignPane (metadata only — pane set unchanged → registry unchanged)
        let group = store.addGroup(name: "G")
        assertInvariant(store, "addGroup")
        store.assignPane(panes[0], toGroup: group)
        assertInvariant(store, "assignPane")

        // focus (pure focus change — pane set unchanged → registry unchanged)
        store.focus(panes[0])
        assertInvariant(store, "focus")

        // move(.next) cycles focus (pre-order cycle; no layout reported)
        store.move(.next)
        assertInvariant(store, "move(.next)")

        // toggleZoom (presentation flag — no canvas surgery)
        store.toggleZoom()
        assertInvariant(store, "toggleZoom on")
        store.toggleZoom()
        assertInvariant(store, "toggleZoom off")

        // resizePane (canvas geometry only — pane set unchanged → registry no-op)
        store.resizePane(panes[0], to: CGRect(x: 0, y: 0, width: 800, height: 500))
        assertInvariant(store, "resizePane")

        // updateSpec (rename a pane — pane set unchanged, session not rebuilt)
        let handleBefore = store.handle(for: panes[0]) as AnyObject
        store.updateSpec(panes[0]) { $0.title = "renamed" }
        assertInvariant(store, "updateSpec")
        XCTAssertTrue(
            handleBefore === (store.handle(for: panes[0]) as AnyObject),
            "updateSpec does NOT rebuild the live session under the user",
        )

        // moveGroup (reorder — pane set unchanged)
        store.moveGroup(from: IndexSet(integer: 0), to: 0)
        assertInvariant(store, "moveGroup")

        // removeGroup (members survive — pane set unchanged)
        store.removeGroup(group)
        assertInvariant(store, "removeGroup")

        // closePane one of the panes (orphan teardown)
        store.closePane(panes[1])
        assertInvariant(store, "closePane")

        // close the remaining panes down to empty
        store.closePane(panes[0])
        assertInvariant(store, "closePane #2")
        store.closePane(panes[2])
        assertInvariant(store, "closePane #3 (empty)")

        await store.quiesce()
        assertInvariant(store, "post-quiesce")
    }

    // MARK: - Idempotency (no public reconcile; assert via no-op-shaped mutations)

    /// There is no public `reconcile()`; instead, a no-op-shaped mutation (re-assigning a pane to the
    /// group it already belongs to) leaves the registry byte-for-byte unchanged — same handle instances,
    /// no new makeSession call, no teardown. (reconcile twice with an unchanged pane set is a no-op.)
    func testSelectingAlreadyActiveTabDoesNotChangeRegistry() async {
        let store = makeStore()
        store.addPane(kind: .terminal) // now 2 panes
        let pane = paneIDs(store)[0]
        let group = store.addGroup(name: "G")
        store.assignPane(pane, toGroup: group)
        let before = store.allSessions.map { ObjectIdentifier($0) }

        store.assignPane(pane, toGroup: group) // already in this group → no-op-shaped

        let after = store.allSessions.map { ObjectIdentifier($0) }
        XCTAssertEqual(
            Set(before),
            Set(after),
            "re-assigning to the same group materializes nothing new and tears nothing down",
        )
        XCTAssertEqual(store.allSessions.count, before.count)
        assertInvariant(store, "after re-assigning to the same group")

        await store.quiesce()
        for handle in store.allSessions {
            XCTAssertEqual(
                (handle as? FakePaneSession)?.teardownCount,
                0,
                "no spurious teardown on a no-op-shaped mutation",
            )
        }
    }

    /// Focusing the already-focused pane is likewise a no-op for the registry: the pane set is
    /// unchanged, so reconcile materializes nothing and tears nothing down.
    func testFocusingAlreadyFocusedPaneDoesNotChangeRegistry() async throws {
        let store = makeStore()
        let focused = try XCTUnwrap(store.focusedPane)
        let handleBefore = store.handle(for: focused) as AnyObject

        store.focus(focused) // already focused → no-op-shaped

        XCTAssertEqual(store.allSessions.count, 1)
        XCTAssertTrue(handleBefore === (store.handle(for: focused) as AnyObject), "the same session instance survives")
        assertInvariant(store, "after focusing the already-focused pane")

        await store.quiesce()
        XCTAssertEqual(fake(store, focused)?.teardownCount, 0)
    }

    // MARK: - View-only projection does NOT reconcile (compact ↔ regular flip)

    /// `updateSolvedLayout(...)` is the ONLY view→store geometry report and is view-only: a simulated
    /// compact ↔ regular projection flip (which only changes how the SAME canvas is rendered, via
    /// ``WorkspaceLayout/isCompact(horizontalSizeClassCompact:width:)``) must not touch the registry.
    func testCompactRegularProjectionFlipDoesNotReconcile() async {
        let store = makeStore()
        store.addPane(kind: .terminal)
        let before = store.allSessions.map { ObjectIdentifier($0) }
        assertInvariant(store, "pre-flip")

        // Sanity-pin the projection helper so the "flip" is real, then report each layout to the store.
        XCTAssertTrue(WorkspaceLayout.isCompact(horizontalSizeClassCompact: true, width: 400), "narrow → compact")
        XCTAssertFalse(WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, width: 1200), "wide → regular")
        // The breakpoint is a DETAIL-area width: the macOS minimum window's detail (~500pt with the
        // ideal sidebar) must resolve REGULAR, not compact — the threshold (460) sits below it.
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, width: 500),
            "macOS min-window detail (~500pt) → regular",
        )
        // The size-class path is unchanged: an iPhone-class detail is compact regardless of width.
        XCTAssertTrue(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: true, width: 500),
            "size-class compact → compact even at 500pt",
        )

        // A regular-mode solved layout, then a compact-mode (empty-frames) one — the view→store report.
        let panes = paneIDs(store)
        let regular = SolvedLayout(
            frames: [
                panes[0]: CGRect(x: 0, y: 0, width: 600, height: 400),
                panes[1]: CGRect(x: 600, y: 0, width: 600, height: 400),
            ],
        )
        store.updateSolvedLayout(regular)
        assertInvariant(store, "after reporting regular layout")
        XCTAssertEqual(
            Set(store.allSessions.map { ObjectIdentifier($0) }),
            Set(before),
            "regular layout report changed no sessions",
        )

        let compact = SolvedLayout.empty // compact carousel solves no multi-pane rects
        store.updateSolvedLayout(compact)
        assertInvariant(store, "after reporting compact layout")
        XCTAssertEqual(
            Set(store.allSessions.map { ObjectIdentifier($0) }),
            Set(before),
            "a compact↔regular projection flip is view-only — registry untouched",
        )

        await store.quiesce()
        for handle in store.allSessions {
            XCTAssertEqual((handle as? FakePaneSession)?.teardownCount, 0, "projection flip tears nothing down")
        }
    }

    // MARK: - Teardown ordering across multiple orphans (single serialized task)

    /// Closing several panes at once orphans MULTIPLE sessions; reconcile drives their `teardown()` in
    /// ONE dedicated task in registry-removal order. Each runs exactly once (no fire-and-forget double-run).
    func testClosingMultiLeafTabTearsDownEachOrphanExactlyOnce() async {
        let a0 = PaneID(), a1 = PaneID(), a2 = PaneID(), b0 = PaneID()
        let store = makeStore(restoring: Workspace.make(
            panes: [
                (a0, PaneSpec(kind: .terminal, title: "a0")),
                (a1, PaneSpec(kind: .terminal, title: "a1")),
                (a2, PaneSpec(kind: .terminal, title: "a2")),
                (b0, PaneSpec(kind: .terminal, title: "b0")),
            ],
            focused: a0,
        ))

        let handles = [a0, a1, a2].map { fake(store, $0)! }
        store.closePane(a0)
        store.closePane(a1)
        store.closePane(a2)
        assertInvariant(store, "after closing three panes")

        await store.quiesce()
        for (i, handle) in handles.enumerated() {
            XCTAssertEqual(handle.teardownCount, 1, "orphan a\(i) torn down exactly once")
            XCTAssertEqual(
                handle.events,
                [.adopt(handle.id), .teardown],
                "orphan a\(i) recorded only adopt-then-teardown (no spurious lifecycle calls)",
            )
        }
        XCTAssertEqual(fake(store, b0)?.teardownCount, 0, "the survivor was never torn down")
    }

    // MARK: - in-flight video-cap accounting does not perturb the registry invariant (ITEM #3)

    /// The ITEM #3 in-flight-teardown video accounting (`tearingDownVideo`) is a SEPARATE bookkeeping
    /// set from the registry: closing a live `.remoteGUI` pane removes its key from the registry
    /// SYNCHRONOUSLY (the invariant `registry.keys == canvas.allIDs()` holds the instant `closePane`
    /// returns) even while its teardown — and hence its in-flight cap slot — is still parked. The cap
    /// accounting must never leak into or perturb the registry/pane-set invariant.
    func testInFlightVideoAccountingDoesNotPerturbRegistryInvariant() async throws {
        // A single remoteGUI canvas grown to two panes.
        let rootID = PaneID()
        let spec = PaneSpec(kind: .remoteGUI, title: "Remote window")
        let store = makeStore(restoring: Workspace.make(panes: [(rootID, spec)], focused: rootID))
        store.addPane(kind: .remoteGUI)
        let ids = paneIDs(store)
        XCTAssertEqual(ids.count, 2)
        assertInvariant(store, "two remoteGUI panes")

        // Park the close-victim's teardown so its in-flight cap slot is held across the assertions.
        let gate = FakeTeardownGate()
        fake(store, ids[0])?.teardownGate = gate
        XCTAssertTrue(store.activateVideo(ids[0]), "ids[0] holds a live video stack")

        store.closePane(ids[0])

        // The registry invariant holds SYNCHRONOUSLY even though ids[0]'s teardown (and its in-flight
        // cap slot) is still parked: the registry excludes the orphan the instant closePane returns.
        XCTAssertNil(store.handle(for: ids[0]), "orphan removed from the registry synchronously")
        assertInvariant(store, "registry invariant holds while teardown (and its cap slot) is in flight")

        // Release + drain: the invariant still holds, and now no teardown / in-flight slot is pending.
        gate.release()
        await store.quiesce()
        assertInvariant(store, "registry invariant holds after the in-flight teardown completes")
        XCTAssertEqual(try XCTUnwrap(fake(store, ids[1])?.teardownCount), 0, "the survivor was never torn down")
    }

    // MARK: - quiesce awaits a teardown task spawned DURING its own drain (BUG-J)

    /// BUG-J: a teardown task spawned by a `reconcile()` that runs WHILE `quiesce()` is awaiting an
    /// earlier teardown must still be awaited — `quiesce()` loops to a fixpoint rather than snapshotting
    /// once. We park the first close's teardown on a gate, start `quiesce()` (it suspends awaiting that
    /// task), then — while it is suspended — close a SECOND pane (spawning a new teardown task), release
    /// the gate, and confirm BOTH teardowns completed once `quiesce()` returns. A single-snapshot drain
    /// would have dropped the second task.
    func testQuiesceAwaitsTeardownSpawnedDuringDrain() async throws {
        // Three terminal panes on one canvas so we can close two of them independently and keep a survivor.
        let a0 = PaneID(), a1 = PaneID(), a2 = PaneID()
        let store = makeStore(restoring: Workspace.make(
            panes: [
                (a0, PaneSpec(kind: .terminal, title: "a0")),
                (a1, PaneSpec(kind: .terminal, title: "a1")),
                (a2, PaneSpec(kind: .terminal, title: "a2")),
            ],
            focused: a0,
        ))
        let gate0 = FakeTeardownGate()
        let h0 = try XCTUnwrap(fake(store, a0))
        let h1 = try XCTUnwrap(fake(store, a1))
        h0.teardownGate = gate0 // the first close's teardown will park here

        // First close → spawns teardown task #1, which parks on gate0.
        store.closePane(a0)
        XCTAssertNil(store.handle(for: a0))

        // Start quiesce; it will suspend awaiting task #1 (parked on gate0). Run it as a child task so
        // the test body can interleave a second close while quiesce is mid-drain.
        let quiesced = Task { @MainActor in await store.quiesce() }

        // Wait until task #1's teardown body has actually entered (and parked on) the gate, so quiesce is
        // genuinely suspended mid-drain before we spawn the second teardown (no fixed-sleep race).
        let entered = await waitUntil { gate0.waiterCount == 1 }
        XCTAssertTrue(entered, "the first teardown parked on the gate — quiesce is suspended mid-drain")

        // While quiesce is suspended, close a SECOND pane → spawns teardown task #2 (no gate → it will
        // complete immediately once it runs). With a single-snapshot drain this task would be dropped.
        store.closePane(a1)
        XCTAssertNil(store.handle(for: a1))

        // Release the first teardown; quiesce's loop must now re-check teardownTasks, find task #2, and
        // await it too before returning.
        gate0.release()
        await quiesced.value

        XCTAssertEqual(h0.teardownCount, 1, "the gated first teardown ran exactly once")
        XCTAssertEqual(
            h1.teardownCount,
            1,
            "the teardown spawned DURING quiesce's drain was still awaited (BUG-J fixpoint loop)",
        )
        // After the fixpoint loop, nothing is pending: a second quiesce is a no-op.
        await store.quiesce()
        XCTAssertEqual(h0.teardownCount, 1)
        XCTAssertEqual(h1.teardownCount, 1)
        XCTAssertEqual(fake(store, a2)?.teardownCount, 0, "the survivor was never torn down")
    }

    // MARK: - Helpers

    /// Polls a `@MainActor` predicate until true or the deadline passes (avoids fixed sleeps). Mirrors
    /// the `waitUntil` used by `ScenePhaseFanOutTests` / the connection tests.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @MainActor () -> Bool,
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
