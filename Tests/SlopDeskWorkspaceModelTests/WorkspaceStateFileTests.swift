import XCTest
@testable import SlopDeskWorkspaceModel

/// What survives a host restart — and, far more importantly, what must not.
///
/// `DetachedSessionStore` is in-process, so no live process crosses a restart. A document that
/// restored `commandRunning`, `agentState` or `liveness: attached` would come back as a wall of
/// fake-live rows: busy dots spinning for children that exited weeks ago, on every client at once.
///
/// **These are the BOUNDARY's tests now.** The rule moved to `rust/slopdesk-wire`'s
/// `document::state_file`, which carries its own suite over the same properties; what is left here
/// is what only this side can ask — that the filter, the round trip and every arm of the refusal
/// survive a crossing through `slopdesk_ws_state_file_*` and arrive as the Swift vocabulary a
/// `catch` reads. Every case below was written against the deleted Swift implementation and is
/// unchanged, which is the evidence the port is behaviour-identical (`docs/55` §6).
final class WorkspaceStateFileTests: XCTestCase {
    private func paneState(_ paneID: UUID) -> HostWorkspaceState {
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(
            tree: TreeWorkspace(
                sessions: [Session(
                    name: "s",
                    tabs: [Tab(root: .leaf(PaneID(raw: paneID)), activePane: PaneID(raw: paneID))],
                    specs: [PaneID(raw: paneID): PaneSpec(kind: .terminal, title: "nvim", userRenamed: true)],
                )],
                activeSessionID: nil,
            ),
            hostDisplayName: "mac-studio",
        ))
        state.merge(paneLiveness: PaneLiveness(
            paneID: paneID,
            liveness: .attached,
            liveTitle: "main.swift - NVIM",
            titleFresh: true,
            cwd: "/Volumes/Lacie/Workspace",
            projectKey: "/Volumes/Lacie/Workspace",
            foregroundProcess: "nvim",
            runningCommand: "make check",
            agentState: PaneLiveness.AgentState(state: 2, kind: 1),
            commandRunning: true,
            grid: PaneLiveness.Grid(cols: 120, rows: 40),
            completionEpoch: 7,
        ))
        return state
    }

    // MARK: - The filter

    /// The point of the whole file. A pane comes back as a PLACE, never as a running process.
    func testNoLivingProcessSurvivesTheFilter() {
        let paneID = UUID()
        let saved = WorkspaceStateFile.persisting(paneState(paneID))

        for field in [
            WorkspacePaneField.liveness, WorkspacePaneField.commandRunning, WorkspacePaneField.agentState,
            WorkspacePaneField.foregroundProcess, WorkspacePaneField.runningCommand,
            WorkspacePaneField.liveTitle, WorkspacePaneField.titleFresh, WorkspacePaneField.grid,
            WorkspacePaneField.completionEpoch,
        ] {
            XCTAssertNil(saved[WorkspaceKey(.pane, paneID, field)], "field \(field) must not survive a restart")
        }
    }

    /// …but the two liveness fields that describe a PLACE do, or the By-Project sidebar re-buckets
    /// visibly on the first live edge after every restart.
    func testTheTwoPlaceFieldsSurvive() {
        let paneID = UUID()
        let saved = WorkspaceStateFile.persisting(paneState(paneID))

        XCTAssertEqual(
            saved.string(WorkspaceKey(.pane, paneID, WorkspacePaneField.cwd)),
            "/Volumes/Lacie/Workspace",
        )
        XCTAssertEqual(
            saved.string(WorkspaceKey(.pane, paneID, WorkspacePaneField.projectKey)),
            "/Volumes/Lacie/Workspace",
        )
    }

    /// The arrangement itself survives whole — that is what a restart is supposed to keep.
    func testTheTopologySurvivesTheFilterIntact() throws {
        let paneID = UUID()
        let saved = WorkspaceStateFile.persisting(paneState(paneID))
        let topology = try XCTUnwrap(saved.topology)

        XCTAssertEqual(topology.tree.sessions.count, 1)
        XCTAssertEqual(topology.tree.sessions[0].specs[PaneID(raw: paneID)]?.title, "nvim")
        XCTAssertTrue(topology.tree.sessions[0].specs[PaneID(raw: paneID)]?.userRenamed ?? false)
        XCTAssertEqual(topology.hostDisplayName, "mac-studio")
    }

    /// A project's PATH survives; its git summary does not. FSEvents re-derives the summary within a
    /// tick, and a restored one describes a working tree that has since moved on.
    func testAProjectKeepsItsPathButNotItsGitSummary() {
        var state = HostWorkspaceState()
        let project = UUID()
        state.set(
            WorkspaceKey(.project, project, WorkspaceProjectField.key),
            WorkspaceStateCodec.encodeString("/repo"),
        )
        state.set(WorkspaceKey(.project, project, WorkspaceProjectField.gitSummary), Data([1, 2, 3]))

        let saved = WorkspaceStateFile.persisting(state)

        XCTAssertEqual(saved.string(WorkspaceKey(.project, project, WorkspaceProjectField.key)), "/repo")
        XCTAssertNil(saved[WorkspaceKey(.project, project, WorkspaceProjectField.gitSummary)])
    }

    /// A kind from a NEWER build is dropped rather than carried. Keeping bytes this build can
    /// neither read nor reap would leave ghost objects with nothing able to remove them — and the
    /// standing rule is that stale data degrades, not that it is migrated.
    func testAnUnknownKindDoesNotSurvive() {
        var state = HostWorkspaceState()
        state.set(WorkspaceKey(kind: 200, objectID: UUID(), field: 0), Data([9]))
        XCTAssertTrue(WorkspaceStateFile.persisting(state).isEmpty)
    }

    // MARK: - Round trip

    func testTheFilteredStateSurvivesTheFileRoundTrip() throws {
        let saved = WorkspaceStateFile.persisting(paneState(UUID()))
        let decoded = try WorkspaceStateFile.decode(WorkspaceStateFile.encode(saved))
        XCTAssertEqual(decoded, saved)
    }

    /// Two saves of one value must be byte-identical, or the file churns on every write and its
    /// diffs stop being reviewable.
    func testTheEncodingIsDeterministic() {
        let saved = WorkspaceStateFile.persisting(paneState(UUID()))
        XCTAssertEqual(WorkspaceStateFile.encode(saved), WorkspaceStateFile.encode(saved))
    }

    /// A zero-length value is how a field is RETIRED. It has to stay distinct from an absent row all
    /// the way through the file, or a title an agent gave up comes back on the next start.
    func testAZeroLengthValueIsNotAnAbsentOne() throws {
        var state = HostWorkspaceState()
        let paneID = UUID()
        state.set(WorkspaceKey(.pane, paneID, WorkspacePaneField.title), Data())

        let decoded = try WorkspaceStateFile.decode(WorkspaceStateFile.encode(state))

        XCTAssertEqual(decoded[WorkspaceKey(.pane, paneID, WorkspacePaneField.title)], Data())
    }

    // MARK: - Refusal

    /// A file from a different shape of this store is REFUSED, not migrated. The caller's answer is
    /// the default document plus the old file kept aside.
    func testAVersionMismatchIsRefused() {
        let data = Data(#"{"version":99,"entries":[]}"#.utf8)
        XCTAssertThrowsError(try WorkspaceStateFile.decode(data)) { error in
            XCTAssertEqual(error as? WorkspaceStateFile.FileError, .versionMismatch(99))
        }
    }

    /// One bad row fails the whole load on purpose. A partially-restored workspace is a workspace
    /// with holes in it, and the user would have to work out which half is real.
    func testOneMalformedRowFailsTheWholeLoad() {
        let json = #"{"version":1,"entries":[{"kind":2,"id":"not-a-uuid","field":0,"value":""}]}"#
        let data = Data(json.utf8)
        XCTAssertThrowsError(try WorkspaceStateFile.decode(data)) { error in
            XCTAssertEqual(error as? WorkspaceStateFile.FileError, .malformedRow)
        }
    }

    /// Bytes that are not this document at all get an arm of their own. They used to arrive as a raw
    /// Foundation `DecodingError` — the refusal a truncated or hand-mangled file most often produces
    /// was the one the Swift taxonomy could not name, while the crate had named it all along.
    func testBytesThatAreNotThisDocumentAreMalformed() {
        for hostile in [
            Data("not json at all".utf8),
            Data("{}".utf8),
            Data(#"{"version":1}"#.utf8),
            Data([0xFF, 0xFE, 0xFD]),
            Data(),
        ] {
            XCTAssertThrowsError(try WorkspaceStateFile.decode(hostile)) { error in
                XCTAssertEqual(error as? WorkspaceStateFile.FileError, .malformed)
            }
        }
    }

    /// A file holding NO surviving cells is a load that worked, not a refusal. The two answers reach
    /// the caller down different paths — one mints the default and keeps the file aside, the other
    /// does not — and across the door they differ only by the status byte.
    func testAnEmptyDocumentDecodesRatherThanRefusing() throws {
        let decoded = try WorkspaceStateFile.decode(WorkspaceStateFile.encode(HostWorkspaceState()))
        XCTAssertTrue(decoded.isEmpty)
    }

    /// The filter runs on the way IN as well as out. This file is the one input a user can edit by
    /// hand, and a hand-set `liveness: attached` would produce exactly the fake-live render the
    /// filter exists to prevent.
    func testAHandEditedLivenessRowIsRefiltered() throws {
        let paneID = UUID()
        var state = HostWorkspaceState()
        state.set(WorkspaceKey(.pane, paneID, WorkspacePaneField.title), WorkspaceStateCodec.encodeString("a"))
        state.set(WorkspaceKey(.pane, paneID, WorkspacePaneField.liveness), WorkspaceStateCodec.encodeU8(0))
        // Encoded WITHOUT the filter — as a hand edit would be.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rows = state.sortedEntries.map {
            [
                "kind": "\($0.key.kind)", "id": $0.key.objectID.uuidString,
                "field": "\($0.key.field)", "value": $0.value.base64EncodedString(),
            ]
        }
        let json = """
        {"version":1,"entries":[\(rows.map {
            "{\"kind\":\($0["kind"] ?? ""),\"id\":\"\($0["id"] ?? "")\",\"field\":\($0["field"] ?? ""),"
                + "\"value\":\"\($0["value"] ?? "")\"}"
        }.joined(separator: ","))]}
        """

        let decoded = try WorkspaceStateFile.decode(Data(json.utf8))

        XCTAssertEqual(decoded.string(WorkspaceKey(.pane, paneID, WorkspacePaneField.title)), "a")
        XCTAssertNil(decoded[WorkspaceKey(.pane, paneID, WorkspacePaneField.liveness)])
    }
}
