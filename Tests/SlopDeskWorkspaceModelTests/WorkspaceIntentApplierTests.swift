import XCTest
@testable import SlopDeskWorkspaceModel

/// The 21 topology changes a client may ASK for — and, mostly, the ways it may not.
///
/// `WorkspaceTreeOps` has been in production for a long time against a caller that could not supply
/// nonsense: the client's own `@MainActor` store, with local input. An intent hands the same ops a
/// NETWORK PEER. Every test here is one way that difference could bite.
final class WorkspaceIntentApplierTests: XCTestCase {
    // MARK: - Fixtures

    private struct Fixture {
        var topology: WorkspaceTopology
        var session: SessionID
        var tabA: TabID
        var tabB: TabID
        var paneA: PaneID
        var paneB: PaneID
    }

    private func fixture() -> Fixture {
        let paneA = PaneID(), paneB = PaneID()
        let tabA = Tab(id: TabID(), title: "one", root: .leaf(paneA), activePane: paneA)
        let tabB = Tab(id: TabID(), title: "two", root: .leaf(paneB), activePane: paneB)
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [tabA, tabB],
            activeTabIndex: 0,
            specs: [
                paneA: PaneSpec(kind: .terminal, title: "Terminal"),
                paneB: PaneSpec(kind: .terminal, title: "Terminal"),
            ],
        )
        return Fixture(
            topology: WorkspaceTopology(tree: TreeWorkspace(
                sessions: [session], activeSessionID: session.id,
                layoutPresets: [], launchPresets: [], sessionTemplates: [],
            )),
            session: session.id,
            tabA: tabA.id,
            tabB: tabB.id,
            paneA: paneA,
            paneB: paneB,
        )
    }

    private func apply(
        _ op: WorkspaceIntentOp,
        _ args: Data,
        to topology: WorkspaceTopology,
        pristine: Bool = false,
    ) -> WorkspaceIntentOutcome {
        WorkspaceIntentApplier.apply(
            op: op.rawValue, args: args, to: topology, documentIsPristine: pristine,
        )
    }

    // MARK: - The happy paths

    func testRenamingAPaneMarksItAuthored() throws {
        let f = fixture()
        let outcome = apply(.renamePane, WorkspaceIntentArgs.encode(id: f.paneA.raw, name: "build"), to: f.topology)
        let next = try XCTUnwrap(outcome.topology)

        let spec = try XCTUnwrap(next.tree.spec(for: f.paneA))
        XCTAssertEqual(spec.title, "build")
        XCTAssertTrue(
            spec.userRenamed,
            "without the flag the next OSC title overwrites what the user typed",
        )
    }

    func testSplittingAPaneUsesTheIdTheClientProposed() throws {
        let f = fixture()
        let proposed = PaneID()
        let outcome = apply(.splitPane, WorkspaceIntentArgs.encode(
            target: f.paneA.raw, axis: .horizontal, before: false, newPane: proposed, spawnCwd: "/tmp",
        ), to: f.topology)
        let next = try XCTUnwrap(outcome.topology)

        XCTAssertTrue(next.tree.contains(proposed), "a host-minted id would cost a round trip to learn")
        XCTAssertEqual(next.spawnCwd[proposed], "/tmp")
        XCTAssertTrue(next.tree.isInvariantHeld())
    }

    func testSpawningAPaneTargetsATabRatherThanAPane() throws {
        let f = fixture()
        let proposed = PaneID()
        let outcome = apply(.spawnPane, WorkspaceIntentArgs.encode(
            target: f.tabB.raw, axis: .vertical, before: false, newPane: proposed, spawnCwd: "",
        ), to: f.topology)
        let next = try XCTUnwrap(outcome.topology)

        XCTAssertEqual(next.tree.tab(containing: proposed)?.1, f.tabB)
    }

    func testSpawningATabSelectsItsSession() throws {
        let f = fixture()
        let proposed = PaneID()
        let outcome = apply(.spawnTab, WorkspaceIntentArgs.encode(
            session: f.session, newPane: proposed, position: .end, spawnCwd: "/repo",
        ), to: f.topology)
        let next = try XCTUnwrap(outcome.topology)

        XCTAssertEqual(next.tree.sessions[0].tabs.count, 3)
        XCTAssertEqual(next.tree.activeSessionID, f.session)
        XCTAssertEqual(next.spawnCwd[proposed], "/repo")
    }

    func testReorderingTabsFollowsTheTabNotTheSlot() throws {
        let f = fixture()
        let outcome = apply(
            .reorderTabs,
            WorkspaceIntentArgs.encode(session: f.session, tabOrder: [f.tabB, f.tabA]),
            to: f.topology,
        )
        let next = try XCTUnwrap(outcome.topology)

        XCTAssertEqual(next.tree.sessions[0].tabs.map(\.id), [f.tabB, f.tabA])
        XCTAssertEqual(
            next.tree.sessions[0].tabs[next.tree.sessions[0].activeTabIndex].id, f.tabA,
            "the selection moved with the tab, not with the index",
        )
    }

    /// Assignment, never a toggle. A toggle over shared state resolves differently depending on how
    /// many clients sent it — the class of bug an idempotent assignment cannot have.
    func testZoomIsAssignedNotToggled() throws {
        let f = fixture()
        var topology = f.topology
        for _ in 0..<3 {
            let outcome = apply(.setZoom, WorkspaceIntentArgs.encode(id: f.paneA.raw, flag: true), to: topology)
            topology = try XCTUnwrap(outcome.topology)
        }
        XCTAssertEqual(topology.tree.sessions[0].tabs[0].zoomedPane, f.paneA)

        let off = apply(.setZoom, WorkspaceIntentArgs.encode(id: f.paneA.raw, flag: false), to: topology)
        XCTAssertNil(try XCTUnwrap(off.topology).tree.sessions[0].tabs[0].zoomedPane)
    }

    /// A satisfied request that changed nothing is still satisfied. Reporting `rejected` would make
    /// every client roll back a patch it never made — and it is what makes a duplicated intent free.
    func testAnIntentThatChangesNothingIsStillApplied() {
        let f = fixture()
        let args = WorkspaceIntentArgs.encode(pane: f.paneA)
        guard case .applied = apply(.focusPane, args, to: f.topology) else {
            XCTFail("focusing the already-focused pane is a satisfied request")
            return
        }
    }

    // MARK: - The shared MRU ring

    /// The reason the ring is host-owned. Two clients computing successors from two LOCAL rings pick
    /// two different tabs, and the index clamp underneath then reintroduces the cross-project jump
    /// `ed76f137` fixed.
    func testClosingATabSelectsTheSharedMostRecentSuccessor() throws {
        let f = fixture()
        var topology = f.topology
        // Visit B, then a third tab, so the ring says B is the most recent survivor.
        let third = PaneID()
        topology = try XCTUnwrap(apply(.spawnTab, WorkspaceIntentArgs.encode(
            session: f.session, newPane: third, position: .end, spawnCwd: "",
        ), to: topology).topology)
        topology = try XCTUnwrap(apply(.focusTab, WorkspaceIntentArgs.encode(tab: f.tabB), to: topology).topology)
        let thirdTab = try XCTUnwrap(topology.tree.tab(containing: third)?.1)
        topology = try XCTUnwrap(apply(.focusTab, WorkspaceIntentArgs.encode(tab: thirdTab), to: topology).topology)

        let after = try XCTUnwrap(apply(.closeTab, WorkspaceIntentArgs.encode(tab: thirdTab), to: topology).topology)

        let session = after.tree.sessions[0]
        XCTAssertEqual(session.tabs[session.activeTabIndex].id, f.tabB)
    }

    /// A dead tab left in the ring sends every client to a tab that is not there.
    func testTheRingDropsTabsThatAreGone() throws {
        let f = fixture()
        var topology = try XCTUnwrap(apply(
            .focusTab, WorkspaceIntentArgs.encode(tab: f.tabB), to: f.topology,
        ).topology)
        XCTAssertEqual(topology.focusMRU[f.session], [f.tabB])

        topology = try XCTUnwrap(apply(.closeTab, WorkspaceIntentArgs.encode(tab: f.tabB), to: topology).topology)

        XCTAssertFalse(topology.focusMRU[f.session]?.contains(f.tabB) ?? false)
    }

    // MARK: - ⇧⌘T

    /// A `TabID` alone cannot rebuild a tab. The ring keeps the split tree and every pane's spec, or
    /// reopen puts back an empty rectangle.
    func testAClosedTabComesBackWithItsPanesAndTitle() throws {
        let f = fixture()
        let closed = try XCTUnwrap(apply(.closeTab, WorkspaceIntentArgs.encode(tab: f.tabB), to: f.topology).topology)
        XCTAssertEqual(closed.tree.sessions[0].tabs.count, 1)
        XCTAssertEqual(closed.closedTabs.count, 1)

        let reopened = try XCTUnwrap(apply(.reopenClosedTab, Data(), to: closed).topology)

        let tab = try XCTUnwrap(reopened.tree.sessions[0].tabs.first { $0.id == f.tabB })
        XCTAssertEqual(tab.title, "two")
        XCTAssertTrue(tab.contains(f.paneB))
        XCTAssertNotNil(reopened.tree.spec(for: f.paneB))
        XCTAssertTrue(reopened.closedTabs.isEmpty)
        XCTAssertTrue(reopened.tree.isInvariantHeld())
    }

    /// The ring survives the document round trip — it rides as ordinary entries, so a client that
    /// reconnects can still reopen what it closed before the link dropped.
    func testTheClosedRingSurvivesTheDocumentRoundTrip() throws {
        let f = fixture()
        let closed = try XCTUnwrap(apply(.closeTab, WorkspaceIntentArgs.encode(tab: f.tabB), to: f.topology).topology)

        var state = HostWorkspaceState()
        state.write(topology: closed)
        let decoded = try XCTUnwrap(state.topology)

        XCTAssertEqual(decoded.closedTabs.count, 1)
        XCTAssertEqual(decoded.closedTabs[0].tab.title, "two")
        XCTAssertEqual(decoded.closedTabs[0].sessionID, f.session)
        XCTAssertNotNil(decoded.closedTabs[0].specs[f.paneB])
    }

    /// ⇧⌘T with nothing to reopen is a satisfied request, not an error.
    func testReopeningAnEmptyRingChangesNothing() throws {
        let f = fixture()
        let outcome = apply(.reopenClosedTab, Data(), to: f.topology)
        XCTAssertEqual(try XCTUnwrap(outcome.topology), f.topology)
    }

    /// The ring is capped, or every pane the user ever closed stays alive in the document forever, on
    /// every client.
    func testTheClosedRingIsCapped() throws {
        var topology = fixture().topology
        let session = topology.tree.sessions[0].id
        for _ in 0..<(WorkspaceTopology.closedTabRingCap + 5) {
            let pane = PaneID()
            topology = try XCTUnwrap(apply(.spawnTab, WorkspaceIntentArgs.encode(
                session: session, newPane: pane, position: .end, spawnCwd: "",
            ), to: topology).topology)
            let tab = try XCTUnwrap(topology.tree.tab(containing: pane)?.1)
            topology = try XCTUnwrap(apply(.closeTab, WorkspaceIntentArgs.encode(tab: tab), to: topology).topology)
        }
        XCTAssertEqual(topology.closedTabs.count, WorkspaceTopology.closedTabRingCap)
    }

    // MARK: - Bootstrap

    /// The legacy one-shot. A client uploads its tree to a host whose document is still the untouched
    /// default; the host takes ownership but keeps its OWN identity.
    func testAdoptTakesTheUploadedTreeButKeepsTheHostsIdentity() throws {
        let f = fixture()
        var host = WorkspaceTopology(tree: .defaultWorkspace(), hostDisplayName: "mac-studio")
        host.unattachedSessionID = SessionID()
        var uploaded = HostWorkspaceState()
        uploaded.write(topology: f.topology)

        let outcome = apply(.adoptWorkspace, WorkspaceStateCodec.encodeSnapshot(uploaded), to: host, pristine: true)
        let next = try XCTUnwrap(outcome.topology)

        XCTAssertEqual(next.tree.sessions.map(\.id), [f.session])
        XCTAssertEqual(next.hostDisplayName, "mac-studio")
        XCTAssertEqual(next.unattachedSessionID, host.unattachedSessionID)
    }

    /// A bootstrap, not a migration. The loser is TOLD so — its tree is the only copy of a layout
    /// somebody built, and silent data loss is not acceptable even once.
    func testAdoptIsRefusedOnceTheHostHasAWorkspace() {
        let f = fixture()
        var uploaded = HostWorkspaceState()
        uploaded.write(topology: f.topology)
        let host = WorkspaceTopology(tree: .defaultWorkspace())

        let outcome = apply(
            .adoptWorkspace, WorkspaceStateCodec.encodeSnapshot(uploaded), to: host, pristine: false,
        )
        XCTAssertEqual(outcome, .rejectedStale)
    }

    // MARK: - Refusals

    func testAnUnknownOpIsAnswered() {
        XCTAssertEqual(
            WorkspaceIntentApplier.apply(op: 250, args: Data(), to: fixture().topology),
            .unknownOp,
            "silence would leave the client's patch waiting out a timeout it need not",
        )
    }

    /// Every referenced id must already be in the document — the discipline the tree ops have never
    /// needed, because they have never had a network peer for a caller.
    func testAReferenceToSomethingThatIsNotThereIsNotFound() {
        let f = fixture()
        let cases: [(WorkspaceIntentOp, Data)] = [
            (.renamePane, WorkspaceIntentArgs.encode(id: UUID(), name: "x")),
            (.renameTab, WorkspaceIntentArgs.encode(id: UUID(), name: "x")),
            (.renameSession, WorkspaceIntentArgs.encode(id: UUID(), name: "x")),
            (.closePane, WorkspaceIntentArgs.encode(pane: PaneID())),
            (.closeTab, WorkspaceIntentArgs.encode(tab: TabID())),
            (.focusTab, WorkspaceIntentArgs.encode(tab: TabID())),
            (.focusPane, WorkspaceIntentArgs.encode(pane: PaneID())),
            (.setSyncInput, WorkspaceIntentArgs.encode(id: UUID(), flag: true)),
            (.setZoom, WorkspaceIntentArgs.encode(id: UUID(), flag: true)),
            (.detachPane, WorkspaceIntentArgs.encode(pane: PaneID())),
            (.reattachPane, WorkspaceIntentArgs.encode(pane: PaneID())),
            (.closeSession, WorkspaceIntentArgs.encode(session: SessionID())),
            (.splitPane, WorkspaceIntentArgs.encode(
                target: UUID(), axis: .horizontal, before: false, newPane: PaneID(), spawnCwd: "",
            )),
            (.setDividerWeight, WorkspaceIntentArgs.encode(
                split: SplitNodeID(), leadingIndex: 0, leadingWeight: 0.5,
            )),
        ]
        for (op, args) in cases {
            XCTAssertEqual(apply(op, args, to: f.topology), .rejectedNotFound, "\(op)")
        }
    }

    /// A proposed pane id already in use would alias two panes onto one PTY the moment the channel
    /// opens — the exact hazard the mux's own exclusivity check exists for.
    func testAProposedIdAlreadyInUseIsRefused() {
        let f = fixture()
        XCTAssertEqual(
            apply(.splitPane, WorkspaceIntentArgs.encode(
                target: f.paneA.raw, axis: .horizontal, before: false, newPane: f.paneB, spawnCwd: "",
            ), to: f.topology),
            .rejectedInvalid,
        )
    }

    /// …including an id parked in the closed-tab ring, which is still a real pane the reopen will
    /// bring back.
    func testAProposedIdParkedInTheClosedRingIsRefused() throws {
        let f = fixture()
        let closed = try XCTUnwrap(apply(.closeTab, WorkspaceIntentArgs.encode(tab: f.tabB), to: f.topology).topology)

        XCTAssertEqual(
            apply(.splitPane, WorkspaceIntentArgs.encode(
                target: f.paneA.raw, axis: .horizontal, before: false, newPane: f.paneB, spawnCwd: "",
            ), to: closed),
            .rejectedInvalid,
        )
    }

    /// A partial order would silently drop the tabs it left out. Reorder is the one op where "some of
    /// it applied" is indistinguishable from a close.
    func testAPartialTabOrderIsRefused() {
        let f = fixture()
        XCTAssertEqual(
            apply(.reorderTabs, WorkspaceIntentArgs.encode(session: f.session, tabOrder: [f.tabA]), to: f.topology),
            .rejectedInvalid,
        )
        XCTAssertEqual(
            apply(
                .reorderTabs,
                WorkspaceIntentArgs.encode(session: f.session, tabOrder: [f.tabA, f.tabB, TabID()]),
                to: f.topology,
            ),
            .rejectedInvalid,
        )
    }

    /// A weight that is not a finite positive number starves a pane to nothing. Checked here rather
    /// than left to the solver's clamp, so the DOCUMENT never carries the nonsense.
    func testAStarvingOrNonFiniteDividerWeightIsRefused() throws {
        let f = fixture()
        let split = SplitNodeID()
        var topology = f.topology
        topology.tree.sessions[0].tabs[0].root = .split(id: split, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(f.paneA)),
            WeightedChild(weight: .flex(1), node: .leaf(PaneID())),
        ])
        let extra = try XCTUnwrap(topology.tree.sessions[0].tabs[0].allPaneIDs().last)
        topology.tree.sessions[0].specs[extra] = PaneSpec(kind: .terminal, title: "Terminal")

        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertEqual(
                apply(
                    .setDividerWeight,
                    WorkspaceIntentArgs.encode(split: split, leadingIndex: 0, leadingWeight: bad),
                    to: topology,
                ),
                .rejectedInvalid,
                "\(bad)",
            )
        }
        guard case .applied = apply(
            .setDividerWeight,
            WorkspaceIntentArgs.encode(split: split, leadingIndex: 0, leadingWeight: 0.7),
            to: topology,
        ) else {
            XCTFail("a legitimate drag must still land")
            return
        }
    }

    // MARK: - Hostile payloads

    /// Truncated, over-long and trailing-garbage payloads are all a DROP. None may trap, over-allocate
    /// or half-apply — these bytes arrived on a socket with no authentication of any kind.
    func testMalformedPayloadsAreRefusedNotTrapped() {
        let f = fixture()
        let payloads: [Data] = [
            Data(),
            Data([0x01]),
            Data(repeating: 0xFF, count: 15),
            // A well-formed uuid followed by a length that over-declares what follows.
            WorkspaceStateCodec.encodeUUID(f.paneA.raw) + Data([0xFF, 0xFF]),
            // A well-formed rename with garbage glued on: trailing bytes mean a framing bug, and
            // salvaging the prefix would hide it behind a plausible value.
            WorkspaceIntentArgs.encode(id: f.paneA.raw, name: "x") + Data([0x00]),
        ]
        for op in WorkspaceIntentOp.allCases where op != .reopenClosedTab && op != .adoptWorkspace {
            for payload in payloads {
                let outcome = apply(op, payload, to: f.topology)
                XCTAssertNotEqual(outcome, .applied(f.topology), "\(op) accepted \(payload.count) hostile bytes")
                XCTAssertNil(outcome.topology, "\(op) applied a malformed payload")
            }
        }
    }

    /// A name longer than the cap is malformed, never clamped. Silently truncating a field a peer
    /// over-declared hides a framing bug behind a value that looks fine.
    func testAnOverLongNameIsRefused() {
        let f = fixture()
        var payload = WorkspaceStateCodec.encodeUUID(f.paneA.raw)
        let length = WorkspaceIntentArgs.maxNameBytes + 1
        payload.append(Data([UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)]))
        payload.append(Data(repeating: 0x61, count: length))

        XCTAssertEqual(apply(.renamePane, payload, to: f.topology), .rejectedInvalid)
    }

    /// A `reorderTabs` list declaring more entries than the bytes can back must cost nothing —
    /// checked before any capacity is reserved.
    func testAnAbsurdTabCountCostsNothing() {
        let f = fixture()
        var payload = WorkspaceStateCodec.encodeUUID(f.session.raw)
        payload.append(Data([0xFF, 0xFF]))
        XCTAssertEqual(apply(.reorderTabs, payload, to: f.topology), .rejectedInvalid)
    }

    /// The depth cap is the STACK-SAFETY mechanism for a hand-rolled decoder, so a structure that
    /// breaches it must never reach the document: the next round trip would truncate the over-deep
    /// tail and lose a leaf — which is a live pane.
    func testASplitPastTheDepthCapIsRefused() throws {
        var topology = fixture().topology
        var pane = try XCTUnwrap(topology.tree.sessions[0].tabs[0].allPaneIDs().first)
        var axis = SplitAxis.horizontal
        var accepted = 0
        // Alternate the axis so each split nests instead of flattening into its parent.
        for _ in 0..<(SplitNode.maxDepth + 6) {
            let next = PaneID()
            let outcome = apply(.splitPane, WorkspaceIntentArgs.encode(
                target: pane.raw, axis: axis, before: false, newPane: next, spawnCwd: "",
            ), to: topology)
            guard let grown = outcome.topology else {
                XCTAssertEqual(outcome, .rejectedInvalid)
                XCTAssertLessThanOrEqual(topology.tree.sessions[0].tabs[0].root.depth, SplitNode.maxDepth)
                XCTAssertGreaterThan(accepted, 1, "the cap must not be hit on the first split")
                return
            }
            topology = grown
            pane = next
            axis = axis == .horizontal ? .vertical : .horizontal
            accepted += 1
        }
        XCTFail("the depth cap never fired")
    }

    // MARK: - Convergence

    /// The property the whole document rests on: two clients issuing interleaved intents converge on
    /// BYTE-IDENTICAL state, because there is exactly one place the ops run and the last write to a
    /// cell wins by arrival there.
    func testInterleavedIntentsFromTwoClientsConvergeByteIdentically() throws {
        let f = fixture()
        var host = f.topology
        let extra = PaneID()

        // A plausible interleaving: client A splits and renames, client B reorders and zooms.
        let script: [(WorkspaceIntentOp, Data)] = [
            (.splitPane, WorkspaceIntentArgs.encode(
                target: f.paneA.raw, axis: .horizontal, before: false, newPane: extra, spawnCwd: "/repo",
            )),
            (.reorderTabs, WorkspaceIntentArgs.encode(session: f.session, tabOrder: [f.tabB, f.tabA])),
            (.renamePane, WorkspaceIntentArgs.encode(id: extra.raw, name: "logs")),
            (.setZoom, WorkspaceIntentArgs.encode(id: extra.raw, flag: true)),
            (.setSyncInput, WorkspaceIntentArgs.encode(id: f.tabA.raw, flag: true)),
            (.focusTab, WorkspaceIntentArgs.encode(tab: f.tabB)),
        ]
        for (op, args) in script {
            host = try XCTUnwrap(apply(op, args, to: host).topology, "\(op)")
        }

        // Both clients see the same snapshot bytes, and rebuilding from them reproduces the value.
        var state = HostWorkspaceState()
        state.write(topology: host)
        let payload = WorkspaceStateCodec.encodeSnapshot(state)
        let clientA = try XCTUnwrap(WorkspaceStateCodec.decodeSnapshot(payload).topology)
        let clientB = try XCTUnwrap(WorkspaceStateCodec.decodeSnapshot(payload).topology)

        XCTAssertEqual(clientA, clientB)
        XCTAssertEqual(clientA, host)
        var reprojected = HostWorkspaceState()
        reprojected.write(topology: clientA)
        XCTAssertEqual(WorkspaceStateCodec.encodeSnapshot(reprojected), payload)
    }

    /// A duplicated intent is free. The applier is not idempotent by accident — every op is an
    /// assignment or a validated structural change, and applying one twice lands in the same place.
    func testApplyingTheSameIntentTwiceLandsInTheSamePlace() throws {
        let f = fixture()
        let cases: [(WorkspaceIntentOp, Data)] = [
            (.renamePane, WorkspaceIntentArgs.encode(id: f.paneA.raw, name: "build")),
            (.renameTab, WorkspaceIntentArgs.encode(id: f.tabA.raw, name: "one")),
            (.focusTab, WorkspaceIntentArgs.encode(tab: f.tabB)),
            (.focusPane, WorkspaceIntentArgs.encode(pane: f.paneB)),
            (.setSyncInput, WorkspaceIntentArgs.encode(id: f.tabA.raw, flag: true)),
            (.setZoom, WorkspaceIntentArgs.encode(id: f.paneA.raw, flag: true)),
            (.reorderTabs, WorkspaceIntentArgs.encode(session: f.session, tabOrder: [f.tabB, f.tabA])),
        ]
        for (op, args) in cases {
            let once = try XCTUnwrap(apply(op, args, to: f.topology).topology, "\(op)")
            let twice = try XCTUnwrap(apply(op, args, to: once).topology, "\(op)")
            XCTAssertEqual(once, twice, "\(op) is not idempotent")
        }
    }

    /// Every op leaves the specs == leafIDs invariant standing. It is the property every tree op
    /// assumes of its input, so one op that breaks it corrupts every op after.
    func testEveryAcceptedIntentLeavesTheInvariantStanding() throws {
        let f = fixture()
        let extra = PaneID()
        var topology = try XCTUnwrap(apply(.splitPane, WorkspaceIntentArgs.encode(
            target: f.paneA.raw, axis: .horizontal, before: false, newPane: extra, spawnCwd: "",
        ), to: f.topology).topology)

        let script: [(WorkspaceIntentOp, Data)] = [
            (.detachPane, WorkspaceIntentArgs.encode(pane: extra)),
            (.reattachPane, WorkspaceIntentArgs.encode(pane: extra)),
            (.closePane, WorkspaceIntentArgs.encode(pane: extra)),
            (.closeTab, WorkspaceIntentArgs.encode(tab: f.tabB)),
            (.reopenClosedTab, Data()),
            (.newSession, WorkspaceIntentArgs.encode(newSession: SessionID(), newPane: PaneID(), name: "notes")),
        ]
        for (op, args) in script {
            topology = try XCTUnwrap(apply(op, args, to: topology).topology, "\(op)")
            XCTAssertTrue(topology.tree.isInvariantHeld(), "\(op) broke the specs invariant")
        }
    }
}
