import Foundation
import SlopDeskWorkspaceModel
import XCTest

/// What survives a save and a load of the client's `workspace.json`, and what a hostile one costs.
///
/// This was `SplitNodeCodableTests` — the decode-repair suite for `SplitNode+Codable.swift`, pinning
/// each repair the plan enumerates: drop empty splits, collapse single-child splits, flatten a
/// same-axis child (the Zellij merge), re-mint duplicate `PaneID`s, clamp non-finite weights, cap
/// depth. That file is gone and so is its subject: `rust/slopdesk-workspace` is the only decoder now,
/// reached through ``WorkspaceFile``, and every one of those repairs is pinned in the crate — by
/// `split_tree`'s `normalized` tests and `persist`'s own. Re-asserting them here in Swift would be a
/// cross-language mirror fixture, which is the thing the one-implementation rule exists to prevent.
///
/// So what is left is what only THIS side can say: that the door round-trips a real arrangement
/// whole, that two saves of one value are byte-identical, and that a file no reader can make sense of
/// fails SOFT — a thrown refusal `WorkspacePersistence.loadTree()` turns into the default workspace
/// plus a `.corrupt` sidecar, never a trap and never a stack overflow.
final class WorkspaceFileRoundTripTests: XCTestCase {
    // ``PaneID``/``SplitNodeID`` are `{ raw: UUID }` structs, so they persist as `{"raw":"<uuid>"}` —
    // these helpers build fixture JSON in exactly the shape the file actually contains.
    private func idJSON(_ uuid: UUID = UUID()) -> String { "{\"raw\":\"\(uuid.uuidString)\"}" }
    private func leafJSON(_ uuid: UUID) -> String { "{\"leaf\":\(idJSON(uuid))}" }

    /// A whole file around one tab root — the only shape the door reads.
    private func fileJSON(root: String) -> Data {
        Data("""
        {"schemaVersion":\(TreeWorkspace.currentSchemaVersion),"sessions":[
          {"id":\(idJSON()),"name":"work","activeTabIndex":0,
           "tabs":[{"id":\(idJSON()),"title":"","root":\(root)}],
           "specs":[]}
        ]}
        """.utf8)
    }

    // MARK: Round-trip

    func testAHealthyWorkspaceSurvivesTheFileWhole() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let root = SplitNode.split(
            id: SplitNodeID(),
            axis: .horizontal,
            children: [
                WeightedChild(weight: .flex(1), node: .leaf(a)),
                WeightedChild(weight: .flex(2), node: .split(
                    id: SplitNodeID(),
                    axis: .vertical,
                    children: [
                        WeightedChild(weight: .flex(1), node: .leaf(b)),
                        WeightedChild(weight: .flex(1), node: .leaf(c)),
                    ],
                )),
            ],
        )
        let session = Session(
            name: "work",
            tabs: [Tab(root: root, activePane: a)],
            specs: [
                a: PaneSpec(kind: .terminal, title: "one"),
                b: PaneSpec(kind: .terminal, title: "two"),
                c: PaneSpec(kind: .terminal, title: "three"),
            ],
        )
        let original = TreeWorkspace(sessions: [session], activeSessionID: session.id)

        let data = WorkspaceFile.encode(original)
        let back = try WorkspaceFile.decode(data)
        XCTAssertEqual(back, original, "a well-formed workspace must survive save→load unchanged")
        XCTAssertEqual(
            WorkspaceFile.encode(back), data,
            "two saves of one arrangement are byte-identical, or the file churns on every autosave",
        )
    }

    func testALoneLeafSurvivesToo() throws {
        let pane = PaneID()
        let session = Session(
            name: "work",
            tabs: [Tab(root: .leaf(pane), activePane: pane)],
            specs: [pane: PaneSpec(kind: .terminal, title: "one")],
        )
        let original = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        XCTAssertEqual(try WorkspaceFile.decode(WorkspaceFile.encode(original)), original)
    }

    // MARK: Failing soft

    /// A node with neither discriminator describes no arrangement, so it is a clean refusal the
    /// persistence layer catches — never a trap.
    func testGarbageDoesNotTrap() {
        XCTAssertThrowsError(try WorkspaceFile.decode(fileJSON(root: "{\"bogus\":42}"))) { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }

    /// The stack-safety contract, whose guard MOVED with the decoder. It used to be `JSONDecoder`'s
    /// own ~512-level container bound; it is now `slopdesk_workspace::json`'s explicit depth cap,
    /// which exists for exactly this reason and is documented as inheriting the job. A file nested
    /// thousands deep is refused by the parser before any recursion can get pathological.
    func testPathologicallyDeepJSONFailsSoftWithoutStackOverflow() {
        func nested(_ depth: Int) -> String {
            if depth == 0 { return leafJSON(UUID()) }
            return """
            {"split":{"axis":"horizontal","id":\(idJSON()),"children":[
              {"weight":{"flex":1},"node":\(nested(depth - 1))}
            ]}}
            """
        }
        XCTAssertThrowsError(
            try WorkspaceFile.decode(fileJSON(root: nested(2000))),
            "JSON nested past the parser's depth cap is refused, never a stack overflow",
        ) { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }

    /// A file this build cannot read names the version it could not read, so the caller can say
    /// something about it rather than reporting corruption.
    func testAForeignSchemaVersionNamesItselfRatherThanReadingAsCorruption() {
        let pane = UUID()
        let foreign = Data("""
        {"schemaVersion":\(TreeWorkspace.currentSchemaVersion + 7),"sessions":[
          {"id":\(idJSON()),"name":"work","activeTabIndex":0,
           "tabs":[{"id":\(idJSON()),"title":"","root":\(leafJSON(pane))}],
           "specs":[]}
        ]}
        """.utf8)
        XCTAssertThrowsError(try WorkspaceFile.decode(foreign)) { error in
            XCTAssertEqual(
                error as? WorkspaceFile.FileError,
                .versionMismatch(TreeWorkspace.currentSchemaVersion + 7),
            )
        }
    }
}
