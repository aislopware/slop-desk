import CSlopDeskFFI
import XCTest
@testable import SlopDeskWorkspaceModel

/// The repair pass, held against the OTHER door that runs it.
///
/// **This is the repo's first differential suite, and `docs/55` §8 is why it exists.** Every
/// cross-language bug this project has found has one shape: a decision implemented twice, where the
/// two disagree, and the disagreement is invisible because only one side is on the hot path.
/// `slopdesk-invariants` pins names and numbers, which is exactly what such a pair never differs
/// in — the eight known instances are all BEHAVIOURAL. So the pin has to be behavioural too: same
/// input, both doors, same output.
///
/// `TreeWorkspace.normalized` was the fourth row of that table. It ran in both languages and the two
/// did not shadow each other, because they fired on different events — the Swift copy on file load,
/// the crate's on every intent — so launch-time repair and gesture-time repair reached different
/// trees for the same input and a workspace that closed cleanly came back subtly different after a
/// relaunch. The Swift copy is gone (2026-08-20). What is left is TWO DOORS onto one rule:
/// `slopdesk_ws_normalize`, which a load runs, and `slopdesk_ws_apply_intent`, which a gesture runs
/// and which ends in the same pass. Every case below drives both and asserts they land on one tree.
///
/// The video-kind walk is the case that matters most and it is deliberately not written as a list of
/// kinds. `PaneKind` has two cases today, so `kind == .desktop` and `PaneKind::is_video` select the
/// same panes and a test naming them would agree forever while the predicate quietly stopped being
/// one. It walks the vocabulary the crate exports instead, so a third video-ish kind fails here
/// rather than in a user's restored workspace.
final class TreeWorkspaceRepairDifferentialTests: XCTestCase {
    // MARK: - Fixtures

    /// Deliberately NOT titled `"Terminal"`: the re-seed's own title is
    /// ``TreeWorkspaceDefaults/paneTitle``, and a fixture that happened to spell the same word would
    /// make every "did this get re-seeded?" assertion below pass whether it did or not.
    private func terminal(_ title: String = "shell") -> PaneSpec {
        PaneSpec(kind: .terminal, title: title)
    }

    /// One session, one tab, two leaves under a split — enough shape for a focus fallback to have
    /// somewhere wrong to land.
    private func twoLeaves() -> (TreeWorkspace, PaneID, PaneID) {
        let left = PaneID(), right = PaneID()
        let root = SplitNode.split(
            id: SplitNodeID(),
            axis: .horizontal,
            children: [.init(weight: .flex(1), node: .leaf(left)), .init(weight: .flex(1), node: .leaf(right))],
        )
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [Tab(id: TabID(), title: "one", root: root, activePane: left)],
            activeTabIndex: 0,
            specs: [left: terminal(), right: terminal()],
        )
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), left, right)
    }

    private func apply(_ op: WorkspaceIntentOp, _ args: Data, to tree: TreeWorkspace) -> TreeWorkspace? {
        WorkspaceIntentApplier.apply(op: op.rawValue, args: args, to: WorkspaceTopology(tree: tree))
            .topology?.tree
    }

    // MARK: - The video predicate, walked rather than named

    func testEveryPaneKindClassifiesTheSameWayOnBothSidesOfTheBoundary() {
        // The kind COUNT comes from the crate, so this loop grows the day the crate does. A third
        // video-ish kind added there would make `WorkspacePaneKindTag.kind(for:)` answer `.terminal`
        // for its byte while the crate answers "video" — which is precisely the silent divergence
        // `docs/55` §8 records, and it fails right here instead.
        let count = slopdesk_ws_pane_kind_count()
        XCTAssertGreaterThan(count, 0, "the crate reports no pane kinds at all")
        for raw in 0..<count {
            let byte = UInt8(raw)
            let kind = WorkspacePaneKindTag.kind(for: byte)
            XCTAssertEqual(
                WorkspacePaneKindTag.byte(for: kind), byte,
                "byte \(byte) does not round-trip through this side's kind vocabulary — the crate grew a kind",
            )
            XCTAssertEqual(
                kind.isVideo, slopdesk_ws_pane_kind_is_video(byte),
                "the two sides disagree about whether kind \(byte) is video",
            )
        }
        XCTAssertFalse(
            slopdesk_ws_pane_kind_is_video(200),
            "a kind byte no build knows must degrade to a terminal, not open a stream",
        )
    }

    func testTheLaunchRestoreDropsExactlyTheKindsTheCrateCallsVideo() {
        // The behavioural half of the walk above: the predicate is only worth pinning where it
        // DECIDES something, and what it decides is whether a persisted satellite comes back.
        for raw in 0..<slopdesk_ws_pane_kind_count() {
            let byte = UInt8(raw)
            let kind = WorkspacePaneKindTag.kind(for: byte)
            var (tree, left, _) = twoLeaves()
            let satellite = PaneID()
            tree.sessions[0].specs[satellite] = PaneSpec(kind: kind, title: "satellite")
            tree.sessions[0].detached = [DetachedPane(pane: satellite, originTab: tree.sessions[0].tabs[0].id)]

            let restored = tree.redockingDetachedPanes()

            XCTAssertEqual(
                restored.contains(satellite) == false && restored.spec(for: satellite) == nil,
                slopdesk_ws_pane_kind_is_video(byte),
                "kind \(byte) survived the restore iff the crate calls it video",
            )
            XCTAssertTrue(restored.contains(left), "the tiled panes are untouched by the drop")
            XCTAssertTrue(restored.isInvariantHeld())
        }
    }

    func testATabHoldingOnlyVideoPanesIsDroppedRatherThanReSeeded() throws {
        // The REMOVAL disagreement, pinned as behaviour. The deleted Swift ran a `closePane` intent
        // per id, which fires the whole close cascade — refocus, tab drop, session drop, a re-seed
        // when the last pane goes. The crate prunes the tree instead and drops a tab that held
        // nothing but streams, because such a tab is not a place the person put anything.
        var (tree, left, _) = twoLeaves()
        let streamTab = Tab(id: TabID(), root: .leaf(PaneID()))
        let stream = try XCTUnwrap(streamTab.root.allPaneIDs().first)
        tree.sessions[0].tabs.append(streamTab)
        tree.sessions[0].specs[stream] = PaneSpec(kind: .desktop, title: "Display")

        let restored = tree.redockingDetachedPanes()

        XCTAssertEqual(restored.sessions[0].tabs.count, 1, "the stream-only tab went with its pane")
        XCTAssertNil(restored.spec(for: stream), "no stream is opened for a pane no window shows")
        XCTAssertTrue(restored.contains(left))
        XCTAssertTrue(restored.isInvariantHeld())
    }

    // MARK: - The two doors, on one input

    func testTheLoadDoorAndTheIntentDoorRepairTheSameInputTheSameWay() throws {
        // The defect this port closed, stated as a property: it must not matter whether a broken
        // tree is repaired at LAUNCH and then gestured on, or gestured on and repaired by the
        // gesture. `closePane` ends in the same pass `normalized()` is, so the two orders converge —
        // and they only converge because there is one pass. Two would differ by exactly the four
        // rows in the table above.
        var (tree, left, right) = twoLeaves()
        tree.sessions[0].specs[PaneID()] = terminal("orphan")
        tree.sessions[0].tabs[0].activePane = PaneID()
        tree.sessions[0].tabs[0].zoomedPane = PaneID()
        tree.sessions[0].activeTabIndex = 42
        tree.activeSessionID = SessionID()

        let repairedThenClosed = try XCTUnwrap(
            apply(.closePane, WorkspaceIntentArgs.encode(pane: right), to: tree.normalized()),
        )
        let closedThenRepaired = try XCTUnwrap(
            apply(.closePane, WorkspaceIntentArgs.encode(pane: right), to: tree),
        ).normalized()

        XCTAssertEqual(repairedThenClosed, closedThenRepaired, "launch-time and gesture-time repair diverged")
        XCTAssertEqual(repairedThenClosed.allPaneIDs(), [left])
        XCTAssertTrue(repairedThenClosed.isInvariantHeld())
    }

    func testRepairingATreeTwiceChangesNothingTheFirstPassDidNotAlreadyDo() {
        var (tree, _, _) = twoLeaves()
        tree.sessions[0].specs[PaneID()] = terminal("orphan")
        tree.sessions[0].activeTabIndex = 9

        let once = tree.normalized()
        XCTAssertEqual(once, once.normalized(), "the repair is not idempotent, so it is not a repair")
        XCTAssertTrue(once.isInvariantHeld())
    }

    // MARK: - The individual repairs, each against the disagreement it settled

    func testADanglingFocusFallsBackToThePreOrderFirstLeaf() {
        // `allPaneIDs().first` against `first_leaf_id()`: two spellings that agree today. A nested
        // tree is where they would stop, so the assertion is written against the walk rather than
        // against a pane the fixture happens to know.
        var (tree, left, _) = twoLeaves()
        tree.sessions[0].tabs[0].activePane = PaneID()
        tree.sessions[0].tabs[0].zoomedPane = PaneID()

        let repaired = tree.normalizingActive()

        let tab = repaired.sessions[0].tabs[0]
        XCTAssertEqual(tab.activePane, tab.root.allPaneIDs().first)
        XCTAssertEqual(tab.activePane, left)
        XCTAssertNil(tab.zoomedPane, "a zoom on an absent pane is simply dropped, never re-pointed")
    }

    /// The specs-vs-leaves invariant, in both directions at once.
    ///
    /// Worth knowing where the repair actually happens now, because it is not where the name says:
    /// the document keys a spec by its pane, so `read_session` rebuilds specs from the tab's LEAVES
    /// and an orphan simply has nowhere to land, while a spec-less leaf is filled by `read_spec`
    /// from `DEFAULT_PANE_TITLE`. `normalizing_specs` then finds nothing left to do. That is fine —
    /// this test pins the OUTCOME, which is the thing a caller can observe — but it is why the
    /// assertion below reads the title from ``TreeWorkspaceDefaults`` rather than spelling it: the
    /// transport's default and the repair's default are one constant, and a copy here would be a
    /// third.
    func testAnOrphanSpecIsDroppedAndASpecLessLeafIsReSeededFromTheCratesOwnDefault() {
        var (tree, left, right) = twoLeaves()
        let orphan = PaneID()
        tree.sessions[0].specs[orphan] = terminal("orphan")
        tree.sessions[0].specs.removeValue(forKey: right)

        let repaired = tree.normalizingSpecs()

        XCTAssertNil(repaired.spec(for: orphan), "a spec naming no leaf is not a pane")
        XCTAssertEqual(repaired.spec(for: right)?.title, TreeWorkspaceDefaults.paneTitle)
        XCTAssertEqual(repaired.spec(for: right)?.kind, .terminal)
        XCTAssertEqual(repaired.spec(for: left)?.title, "shell", "a leaf that HAD a spec keeps it verbatim")
        XCTAssertTrue(repaired.isInvariantHeld())
    }

    func testAnEmptyWorkspaceIsReSeededWithFreshIdentitiesRatherThanDerivedOnes() throws {
        // The identity DECISION, pinned. A re-seeded pane is a pane the file did not contain, so
        // nothing persisted is keyed by it and there is nothing for a stable name to keep pointing
        // at — which is the whole property `persist.rs`'s `derived_split_id` exists to preserve for
        // a divider, and the property that is absent here. A `PaneID` is also the join to the
        // live-session registry, so a name derived from the file's own contents is one two launches
        // could both produce, and reconcile would hand a fresh pane a process it did not open. So
        // the ids are MINTED, and two repairs of one input are deliberately not equal.
        let empty = TreeWorkspace(sessions: [], activeSessionID: nil)

        let first = empty.normalized(), second = empty.normalized()

        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.allPaneIDs().count, 1)
        XCTAssertEqual(first.sessions[0].name, TreeWorkspaceDefaults.sessionName)
        XCTAssertEqual(try first.spec(for: XCTUnwrap(first.allPaneIDs().first))?.title, TreeWorkspaceDefaults.paneTitle)
        XCTAssertNotEqual(
            first.allPaneIDs(), second.allPaneIDs(),
            "a re-seeded pane took a DERIVED identity — two launches would then share one process",
        )
        XCTAssertTrue(first.isInvariantHeld())
    }

    func testASessionThatLostItsTabsKeepsItsNameAndItsSatellites() throws {
        // The one shape that could not cross, and the reason it is repaired on this side: the
        // document ingest drops a session with no usable tab, on BOTH sides, rightly — a host push
        // naming one describes nothing. A REPAIR wants the opposite answer, because the session
        // still has a name and may still own detached panes. What is pinned is that the repair here
        // produces exactly what the crate's own re-seed does.
        var (tree, _, _) = twoLeaves()
        let satellite = PaneID()
        tree.sessions[0].specs[satellite] = terminal("satellite")
        tree.sessions[0].detached = [DetachedPane(pane: satellite, originTab: nil)]
        tree.sessions[0].tabs = []
        let name = tree.sessions[0].name
        let id = tree.sessions[0].id

        let repaired = tree.normalized()

        XCTAssertEqual(repaired.sessions.map(\.id), [id], "the session was dropped rather than repaired")
        XCTAssertEqual(repaired.sessions[0].name, name)
        XCTAssertEqual(repaired.sessions[0].tabs.count, 1, "a fresh tab, exactly one")
        let seeded = try XCTUnwrap(repaired.sessions[0].tabs[0].root.allPaneIDs().first)
        XCTAssertEqual(repaired.sessions[0].tabs[0].activePane, seeded, "focus on the re-seeded tab's only leaf")
        XCTAssertEqual(repaired.spec(for: seeded)?.title, TreeWorkspaceDefaults.paneTitle)
        XCTAssertTrue(repaired.isDetached(satellite), "the satellite the session owns survived with it")
        XCTAssertTrue(repaired.isInvariantHeld())
    }

    func testADetachedPaneWithNoSpecIsDroppedRatherThanInventedAsATerminal() {
        // The second blind spot, and the one with teeth. `read_spec` is TOTAL — a pane with no
        // `pane/title` cell gets the default title rather than a refusal — so an entry that survived
        // the crossing would come back a real satellite and open a window for a pane the file never
        // described. `normalizing_specs` drops it, so the drop has to happen before the door.
        //
        // The two neighbouring corruptions are here to pin what is NOT repaired on this side: an
        // entry shadowing a live tree leaf and a duplicate of a valid one both cross, and the ingest
        // resolves them the way the crate's rule does. Repairing them here too would be a second
        // implementation of a rule that already works, which is the whole defect class.
        var (tree, left, right) = twoLeaves()
        let specless = PaneID()
        tree.sessions[0].detached = [
            DetachedPane(pane: right),
            DetachedPane(pane: right),
            DetachedPane(pane: left),
            DetachedPane(pane: specless),
        ]

        let repaired = tree.normalizingSpecs()

        XCTAssertEqual(
            repaired.sessions[0].detached.map(\.pane), [],
            "every entry here is a tree leaf or has nothing to materialize from",
        )
        XCTAssertNil(repaired.spec(for: specless), "a satellite the file never described is not invented")
        XCTAssertTrue(repaired.contains(left), "the tree leaves the shadowing entries named are untouched")
        XCTAssertTrue(repaired.contains(right))
        XCTAssertTrue(repaired.isInvariantHeld())
    }

    func testTheLaunchRestoreFoldsASatelliteBackWithoutStealingTheSavedSelection() throws {
        var (tree, left, _) = twoLeaves()
        let originTab = tree.sessions[0].tabs[0].id
        let satellite = PaneID()
        tree.sessions[0].tabs.append(Tab(id: TabID(), title: "two", root: .leaf(PaneID())))
        let secondLeaf = try XCTUnwrap(tree.sessions[0].tabs[1].root.allPaneIDs().first)
        tree.sessions[0].specs[secondLeaf] = terminal()
        tree.sessions[0].specs[satellite] = terminal("satellite")
        tree.sessions[0].detached = [DetachedPane(pane: satellite, originTab: originTab)]
        tree.sessions[0].activeTabIndex = 1

        let restored = tree.redockingDetachedPanes()

        XCTAssertTrue(restored.contains(satellite), "the satellite came back into a tab")
        XCTAssertFalse(restored.isDetached(satellite))
        XCTAssertEqual(restored.tab(containing: satellite)?.1, originTab, "back into its ORIGIN tab")
        XCTAssertEqual(restored.sessions[0].activeTabIndex, 1, "the persisted selection survived the fold")
        XCTAssertTrue(restored.contains(left))
        XCTAssertTrue(restored.isInvariantHeld())
    }

    // MARK: - What the crossing must not quietly change

    func testTheSchemaVersionIsCarriedAcrossRatherThanReset() {
        // The document has no `schemaVersion` — it is a property of the client's FILE, not of the
        // shape — so a repair that let the round trip decide it would silently claim a version the
        // value never had, and the load path's "a version this build does not speak resets aside"
        // rule would stop being able to see the difference.
        var (tree, _, _) = twoLeaves()
        tree.schemaVersion = 3
        XCTAssertEqual(tree.normalized().schemaVersion, 3)
        XCTAssertEqual(TreeWorkspace.defaultWorkspace().normalized().schemaVersion, TreeWorkspace.currentSchemaVersion)
    }

    func testTheReSeedDefaultsAreAskedForRatherThanSpelledHere() {
        // Both strings come from the crate that spends them. A copy on this side would not fail
        // loudly: a pane would simply be called one thing when a gesture made it and another when a
        // launch repaired it.
        XCTAssertFalse(TreeWorkspaceDefaults.paneTitle.isEmpty)
        XCTAssertFalse(TreeWorkspaceDefaults.sessionName.isEmpty)
        let fresh = TreeWorkspace.defaultWorkspace()
        XCTAssertEqual(fresh.sessions.first?.name, TreeWorkspaceDefaults.sessionName)
        XCTAssertEqual(fresh.sessions.first?.specs.values.first?.title, TreeWorkspaceDefaults.paneTitle)
    }

    // MARK: - The pass vocabulary, walked rather than named

    /// The half `slopdesk-invariants` structurally cannot check.
    ///
    /// Its `compare_abi_enum "RepairPass"` holds the two byte MAPS against each other, which catches
    /// a reorder and a renumber. It cannot catch a pass the crate ADDS, because a map this side never
    /// grew still agrees with itself perfectly — the gate reads four rows on both sides and passes.
    /// The failure that hides behind it is not a crash: `repaired(_:)` would keep asking for the four
    /// it knows, and whichever document-shaping rule the fifth pass carries would simply never run on
    /// a load, exactly the launch-vs-gesture split this whole port closed.
    func testSwiftKnowsEveryRepairPassTheCrateCanRun() {
        let crate = slopdesk_ws_normalize_pass_count()
        XCTAssertEqual(
            RepairPass.allCases.count, crate,
            "the crate runs \(crate) repair passes and this side spells \(RepairPass.allCases.count)",
        )
        // And the bytes are the vocabulary itself: contiguous from zero, one case each. A gap or a
        // duplicate would let two passes share a byte, which the name-to-name map cannot see either.
        XCTAssertEqual(
            Set(RepairPass.allCases.map(\.ffiByte)), Set(
                (0..<crate).map { UInt8($0) },
            ),
            "the pass bytes are not exactly 0..<\(crate)",
        )
    }
}
