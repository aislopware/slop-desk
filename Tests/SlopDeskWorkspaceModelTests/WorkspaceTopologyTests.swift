import XCTest
@testable import SlopDeskWorkspaceModel

/// The topology half of the workspace document: the arrangement a client did not make, rendered from
/// the host alone.
///
/// Phase 4 shipped the per-pane FACTS. Those repair a degraded row, but two clients still held two
/// separate trees — so a tab opened on the Mac simply did not exist on the phone. This is the layer
/// that makes the layout one value, and every test here is about a way that value could quietly stop
/// meaning the same thing on both ends.
final class WorkspaceTopologyTests: XCTestCase {
    // MARK: - Fixtures

    /// Two sessions: one with a nested split and a detached pane, one plain. Built with every field
    /// the document does NOT carry left at its post-round-trip value, so `==` is a real assertion
    /// about the carried fields rather than a comparison rigged to pass.
    private func fixture() -> WorkspaceTopology {
        let a = PaneID(), b = PaneID(), c = PaneID(), detached = PaneID(), lone = PaneID()
        let closed = PaneID()
        let inner = SplitNodeID(), outer = SplitNodeID()
        let tab1 = Tab(
            id: TabID(),
            title: "build",
            root: .split(id: outer, axis: .horizontal, children: [
                WeightedChild(weight: .flex(2), node: .leaf(a)),
                WeightedChild(weight: .flex(1), node: .split(id: inner, axis: .vertical, children: [
                    WeightedChild(weight: .flex(1), node: .leaf(b)),
                    WeightedChild(weight: .fixed(220), node: .leaf(c)),
                ])),
            ]),
            activePane: b,
            zoomedPane: c,
        )
        let tab2 = Tab(id: TabID(), title: "", root: .leaf(lone), activePane: lone)
        let session = Session(
            name: "slop-desk",
            tabs: [tab1, tab2],
            activeTabIndex: 1,
            specs: [
                a: PaneSpec(kind: .terminal, title: "nvim", userRenamed: true),
                b: PaneSpec(kind: .terminal, title: "Terminal"),
                c: PaneSpec(
                    kind: .desktop,
                    title: "Display 1",
                    video: VideoEndpoint(windowID: 0, title: "Display 1", appName: "", displayID: 1),
                ),
                lone: PaneSpec(kind: .terminal, title: "logs"),
                detached: PaneSpec(kind: .terminal, title: "htop"),
            ],
            detached: [DetachedPane(pane: detached, originTab: tab1.id)],
        )
        let other = Session.singlePane(name: "notes", spec: PaneSpec(kind: .terminal, title: "Terminal"))
        return WorkspaceTopology(
            tree: TreeWorkspace(
                sessions: [session, other],
                activeSessionID: other.id,
            ),
            syncInputTabs: [tab1.id],
            focusMRU: [session.id: [tab2.id, tab1.id]],
            closedTabs: [WorkspaceTopology.ClosedTab(
                sessionID: session.id,
                tab: Tab(id: TabID(), title: "gone", root: .leaf(closed), activePane: closed),
                specs: [closed: PaneSpec(kind: .terminal, title: "was here")],
            )],
            unattachedSessionID: other.id,
            hostDisplayName: "mac-studio",
            spawnCwd: [a: "/Volumes/Lacie/Workspace"],
        )
    }

    private func state(_ topology: WorkspaceTopology) -> HostWorkspaceState {
        HostWorkspaceState(topology.entries())
    }

    // MARK: - Round trip

    func testAWholeWorkspaceSurvivesTheRoundTrip() throws {
        let original = fixture()
        let decoded = try XCTUnwrap(state(original).topology)
        XCTAssertEqual(decoded, original)
    }

    /// Through the actual snapshot BYTES, not just the entry map — the wire is what the two clients
    /// share, and a codec that round-trips a Dictionary but mis-frames the payload converges on
    /// nothing.
    func testTheRoundTripHoldsThroughTheEncodedSnapshot() throws {
        let original = fixture()
        let payload = WorkspaceStateCodec.encodeSnapshot(state(original))
        let decoded = try XCTUnwrap(WorkspaceStateCodec.decodeSnapshot(payload).topology)
        XCTAssertEqual(decoded, original)
    }

    /// Deterministic bytes are what make a golden vector stable and a diff free of dictionary-order
    /// churn. Two projections of one value must be byte-identical.
    func testTheProjectionIsByteDeterministic() {
        let topology = fixture()
        XCTAssertEqual(
            WorkspaceStateCodec.encodeSnapshot(state(topology)),
            WorkspaceStateCodec.encodeSnapshot(state(topology)),
        )
    }

    /// A divider drag must survive as the exact Double the solver computed. `1/3` re-parsed through a
    /// decimal comes back a different number, and two clients would then lay the same split out
    /// differently forever.
    func testADividerWeightSurvivesBitExact() throws {
        let left = PaneID(), right = PaneID()
        let split = SplitNodeID()
        let odd = 1.0 / 3.0
        let tab = Tab(root: .split(id: split, axis: .horizontal, children: [
            WeightedChild(weight: .flex(odd), node: .leaf(left)),
            WeightedChild(weight: .flex(1 - odd), node: .leaf(right)),
        ]), activePane: left)
        let session = Session(
            name: "s", tabs: [tab], specs: [
                left: PaneSpec(kind: .terminal, title: "a"),
                right: PaneSpec(kind: .terminal, title: "b"),
            ],
        )
        let topology = WorkspaceTopology(tree: TreeWorkspace(
            sessions: [session], activeSessionID: session.id,
        ))

        let decoded = try XCTUnwrap(state(topology).topology)
        guard case let .split(_, _, children) = decoded.tree.sessions[0].tabs[0].root,
              case let .flex(first) = children[0].weight
        else {
            XCTFail("the split did not survive as a split")
            return
        }
        XCTAssertEqual(first.bitPattern, odd.bitPattern, "a re-parsed decimal is a different number")
    }

    // MARK: - Identity, not position

    /// The bug `ed76f137` fixed, one layer up. If the active tab crossed as an INDEX, a reorder on
    /// another client would silently make that integer name a different tab — and no decoder could
    /// tell.
    func testTheActiveTabCrossesAsIdentityNotPosition() throws {
        var topology = fixture()
        let session = topology.tree.sessions[0]
        let wanted = session.tabs[1].id
        XCTAssertEqual(session.activeTabIndex, 1)

        // Another client reorders the tabs. The active tab's POSITION changes; the tab does not.
        topology.tree.sessions[0].tabs.reverse()
        topology.tree.sessions[0].activeTabIndex = 0

        let decoded = try XCTUnwrap(state(topology).topology)
        let after = decoded.tree.sessions[0]
        XCTAssertEqual(after.tabs[after.activeTabIndex].id, wanted)
        XCTAssertEqual(after.activeTabIndex, 0, "the index is derived from the id, not carried")
    }

    // MARK: - What must not cross

    /// A future build's presets must survive a topology write rather than being reaped by it.
    /// `write(topology:)` DELETES every topology key the projection did not supply, so a root field
    /// this build does not produce has to be excluded from that sweep by name.
    func testATopologyWriteDoesNotReapTheReservedPresetFields() {
        var state = HostWorkspaceState()
        let reserved = WorkspaceKey.root(WorkspaceRootField.launchPresets)
        state.set(reserved, Data([1, 2, 3]))

        state.write(topology: fixture())

        XCTAssertEqual(state[reserved], Data([1, 2, 3]))
    }

    // MARK: - Removal

    /// Closing a tab has to TAKE ITS ENTRIES WITH IT. An incremental merge would leave the closed tab
    /// in the document forever, rendered by every client — the mirror image of the bug this document
    /// exists to end.
    func testClosingATabRemovesItsEntries() {
        var topology = fixture()
        var state = HostWorkspaceState()
        state.write(topology: topology)
        let doomed = topology.tree.sessions[0].tabs[0].id
        XCTAssertNotNil(state[WorkspaceKey(.tab, doomed.raw, WorkspaceTabField.layoutStructure)])

        topology.tree.sessions[0].tabs.removeFirst()
        topology.tree.sessions[0].activeTabIndex = 0
        state.write(topology: topology)

        XCTAssertTrue(
            state.keys(ofKind: WorkspaceObjectKind.tab.rawValue, objectID: doomed.raw).isEmpty,
            "every field of the closed tab is gone, not just its structure",
        )
    }

    /// The two halves of a pane live one field byte apart under the same objectID. A topology write
    /// must not disturb the liveness half, or every rename would blank the row it renamed.
    func testATopologyWriteLeavesPaneLivenessAlone() {
        let topology = fixture()
        let paneID = topology.tree.sessions[0].tabs[0].allPaneIDs()[0]
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(
            paneID: paneID.raw, liveness: .attached, liveTitle: "main.swift - NVIM", titleFresh: true,
        ))

        state.write(topology: topology)

        XCTAssertEqual(
            state.string(WorkspaceKey(.pane, paneID.raw, WorkspacePaneField.liveTitle)),
            "main.swift - NVIM",
        )
        XCTAssertEqual(state.string(WorkspaceKey(.pane, paneID.raw, WorkspacePaneField.title)), "nvim")
    }

    /// …and the mirror of it: a liveness recapture must not delete the persisted title.
    func testALivenessMergeLeavesPaneTopologyAlone() {
        let topology = fixture()
        let paneID = topology.tree.sessions[0].tabs[0].allPaneIDs()[0]
        var state = HostWorkspaceState()
        state.write(topology: topology)

        state.merge(paneLiveness: PaneLiveness(paneID: paneID.raw, liveness: .detached))

        XCTAssertEqual(state.string(WorkspaceKey(.pane, paneID.raw, WorkspacePaneField.title)), "nvim")
        XCTAssertTrue(state.bool(WorkspaceKey(.pane, paneID.raw, WorkspacePaneField.userRenamed)))
    }

    // MARK: - Hostile input

    /// A tab named in `tabOrder` with no structure is SKIPPED. Defaulting it to an empty tab would
    /// invent a phantom every client then renders — inventing state is strictly worse than dropping
    /// state the host can re-send.
    func testATabWithNoLayoutIsSkippedNotInvented() throws {
        var state = state(fixture())
        let session = try XCTUnwrap(state.topology).tree.sessions[0]
        let doomed = session.tabs[0].id
        state[WorkspaceKey(.tab, doomed.raw, WorkspaceTabField.layoutStructure)] = nil

        let decoded = try XCTUnwrap(state.topology)
        XCTAssertEqual(decoded.tree.sessions[0].tabs.count, 1)
        XCTAssertFalse(decoded.tree.sessions[0].tabs.contains { $0.id == doomed })
    }

    /// A zoom or focus naming a pane the tab does not contain is dropped rather than rendered — a
    /// zoom on a foreign pane would black the tab out on the client that decoded it.
    func testAZoomNamingAForeignPaneIsDropped() throws {
        var state = state(fixture())
        let tabID = try XCTUnwrap(state.topology).tree.sessions[0].tabs[0].id
        state.set(
            WorkspaceKey(.tab, tabID.raw, WorkspaceTabField.zoomedPaneID),
            WorkspaceStateCodec.encodeUUID(UUID()),
        )

        let decoded = try XCTUnwrap(state.topology)
        XCTAssertNil(decoded.tree.sessions[0].tabs[0].zoomedPane)
    }

    /// A weight cell whose arity does not match the split it names degrades to an EVEN share. Half a
    /// weight list applied to the wrong children is a mis-sized layout with no way to notice; an even
    /// split is exactly the solver's default and is visibly ordinary.
    func testAWeightCellOfTheWrongArityDegradesToAnEvenShare() throws {
        var state = state(fixture())
        let root = try XCTUnwrap(state.topology).tree.sessions[0].tabs[0].root
        guard case let .split(splitID, _, _) = root else {
            XCTFail("fixture lost its split")
            return
        }
        state.set(
            WorkspaceKey(.splitNode, splitID.raw, WorkspaceSplitNodeField.weight),
            WorkspaceStateCodec.encodeWeights([.flex(9)]),
        )

        let decoded = try XCTUnwrap(state.topology)
        guard case let .split(_, _, children) = decoded.tree.sessions[0].tabs[0].root else {
            XCTFail("the split did not survive")
            return
        }
        XCTAssertEqual(children.map(\.weight), [.flex(1), .flex(1)])
    }

    /// A hostile weight of zero would starve a pane to nothing. The decoder repairs rather than
    /// trusts — the same `repaired()` floor the persisted decoder applies.
    func testAStarvingWeightIsRepairedNotTrusted() throws {
        var state = state(fixture())
        let root = try XCTUnwrap(state.topology).tree.sessions[0].tabs[0].root
        guard case let .split(splitID, _, _) = root else {
            XCTFail("fixture lost its split")
            return
        }
        state.set(
            WorkspaceKey(.splitNode, splitID.raw, WorkspaceSplitNodeField.weight),
            WorkspaceStateCodec.encodeWeights([.flex(0), .flex(.nan)]),
        )

        let decoded = try XCTUnwrap(state.topology)
        guard case let .split(_, _, children) = decoded.tree.sessions[0].tabs[0].root,
              case let .flex(first) = children[0].weight, case let .flex(second) = children[1].weight
        else {
            XCTFail("the split did not survive")
            return
        }
        XCTAssertEqual(first, SplitWeight.minWeight)
        XCTAssertEqual(second, SplitWeight.minWeight)
    }

    /// A detached pane that is ALSO a tree leaf breaks the specs invariant in both directions at
    /// once. Tree membership wins, matching `normalizingSpecs()`.
    func testADetachedPaneShadowedByATreeLeafIsDropped() throws {
        var state = state(fixture())
        let topology = try XCTUnwrap(state.topology)
        let session = topology.tree.sessions[0]
        let leaf = session.tabs[0].allPaneIDs()[0]
        state.set(
            WorkspaceKey(.session, session.id.raw, WorkspaceSessionField.detachedPanes),
            WorkspaceStateCodec.encodeDetachedPanes([(leaf.raw, nil)]),
        )

        let decoded = try XCTUnwrap(state.topology)
        XCTAssertTrue(decoded.tree.sessions[0].detached.isEmpty)
        XCTAssertTrue(decoded.tree.isInvariantHeld())
    }

    /// The specs == leafIDs invariant the whole tree model rests on, asserted on the DECODED value —
    /// the ops preserve it, and a decoder that quietly breaks it hands every op a corrupt input.
    func testTheSpecsInvariantHoldsAfterIngestion() throws {
        let decoded = try XCTUnwrap(state(fixture()).topology)
        XCTAssertTrue(decoded.tree.isInvariantHeld())
    }

    /// No sessions is "I have no document", not an empty workspace. The distinction matters: the host
    /// answers the first by minting a default, and would answer the second by publishing a blank
    /// window to every client at once.
    func testAnEmptyDocumentHasNoTopology() {
        XCTAssertNil(HostWorkspaceState().topology)
    }

    /// A document holding only pane LIVENESS — every Phase 4 host, before this phase ships — has no
    /// topology either. It must not read as a workspace with zero sessions.
    func testALivenessOnlyDocumentHasNoTopology() {
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(paneID: UUID(), liveness: .attached))
        XCTAssertNil(state.topology)
    }
}

// MARK: - The partition

/// ``PaneLiveness/livenessFields()`` and ``PaneLiveness/topologyFields()`` must partition
/// ``WorkspacePaneField``. The two lists drive a delete-then-write on the same objectID from two
/// independent producers, so an overlap makes a recapture eat a persisted title and a gap makes a
/// field nobody ever writes or reaps.
final class PaneLivenessFieldPartitionTests: XCTestCase {
    /// Every field byte the vocabulary declares, read off the declarations rather than re-typed — a
    /// list re-typed here would agree with itself while disagreeing with the wire.
    private let declared: Set<UInt8> = [
        WorkspacePaneField.kind, WorkspacePaneField.title, WorkspacePaneField.userRenamed,
        WorkspacePaneField.liveTitle, WorkspacePaneField.titleFresh, WorkspacePaneField.cwd,
        WorkspacePaneField.projectKey, WorkspacePaneField.foregroundProcess,
        WorkspacePaneField.runningCommand, WorkspacePaneField.agentState, WorkspacePaneField.agentLabel,
        WorkspacePaneField.agentIntent, WorkspacePaneField.progress, WorkspacePaneField.commandRunning,
        WorkspacePaneField.lastExitCode, WorkspacePaneField.lastDurationMS, WorkspacePaneField.grid,
        WorkspacePaneField.liveness, WorkspacePaneField.completionEpoch, WorkspacePaneField.lastActivityMS,
        WorkspacePaneField.videoTarget, WorkspacePaneField.spawnCwd,
    ]

    func testTheTwoHalvesDoNotOverlap() {
        let liveness = Set(PaneLiveness.livenessFields())
        let topology = Set(PaneLiveness.topologyFields())
        XCTAssertTrue(liveness.isDisjoint(with: topology))
    }

    func testTheTwoHalvesCoverEveryDeclaredField() {
        let covered = Set(PaneLiveness.livenessFields()).union(PaneLiveness.topologyFields())
        XCTAssertEqual(covered, declared)
    }

    /// The field numbers are wire values, frozen the moment a golden vector carries one. `22` is the
    /// next free byte; a field that renumbers under an existing build decodes cleanly into the wrong
    /// meaning, because every value is length-prefixed.
    func testTheFieldNumbersAreContiguousFromZero() {
        XCTAssertEqual(declared.sorted(), Array(0...21))
    }
}
