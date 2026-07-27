import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskHost

/// The workspace document's home on disk, and the answer a host with none gives.
///
/// The second half is the one that cannot be got wrong. Once client-side tree persistence is gone, a
/// host that cannot mint a workspace leaves every client on a blank window with no way to create the
/// first pane — a cold start that dead-ends rather than degrades.
final class HostWorkspaceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("slopdesk-workspace-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(debounce: Duration = .milliseconds(1)) -> HostWorkspaceStore {
        HostWorkspaceStore(
            fileURL: directory.appendingPathComponent("workspace-state.json"),
            hostDisplayName: "mac-studio",
            debounce: debounce,
        )
    }

    private var fileURL: URL { directory.appendingPathComponent("workspace-state.json") }

    private func asideFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != "workspace-state.json" }
            .sorted()
    }

    // MARK: - Bootstrap

    /// A host with no file publishes a real workspace, not nothing. One session, one tab, one pane —
    /// enough to type into.
    func testAHostWithNoFileMintsAUsableWorkspace() async throws {
        let loaded = await makeStore().load()
        let topology = try XCTUnwrap(loaded.topology)

        XCTAssertEqual(topology.tree.sessions.count, 1)
        XCTAssertEqual(topology.tree.sessions[0].tabs.count, 1)
        XCTAssertEqual(topology.tree.sessions[0].allPaneIDs().count, 1)
        XCTAssertEqual(topology.hostDisplayName, "mac-studio")
        XCTAssertTrue(topology.tree.isInvariantHeld())
    }

    /// Minting must not leave a file behind. A default that persisted itself would make the very
    /// first `load()` indistinguishable from a restore, and the adopt-a-legacy-tree bootstrap turns
    /// on exactly that distinction.
    func testMintingTheDefaultDoesNotWriteAFile() async {
        _ = await makeStore().load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Round trip

    func testAWorkspaceSurvivesSaveAndReload() async throws {
        let store = makeStore()
        var state = await store.load()
        let paneID = try XCTUnwrap(state.topology?.tree.allPaneIDs().first)
        state.set(
            WorkspaceKey(.pane, paneID.raw, WorkspacePaneField.title),
            WorkspaceStateCodec.encodeString("build"),
        )
        await store.scheduleSave(state)
        await store.flush()

        let loaded = await makeStore().load()
        let reloaded = try XCTUnwrap(loaded.topology)
        XCTAssertEqual(reloaded.tree.sessions[0].specs[paneID]?.title, "build")
    }

    /// The debounce coalesces: a burst of intents costs one write, and the LAST value is the one on
    /// disk. Depth-1 everywhere in this document, for the same reason.
    func testABurstOfSavesWritesOnlyTheLastValue() async throws {
        let store = makeStore(debounce: .milliseconds(30))
        var state = await store.load()
        let paneID = try XCTUnwrap(state.topology?.tree.allPaneIDs().first)
        for title in ["one", "two", "three"] {
            state.set(
                WorkspaceKey(.pane, paneID.raw, WorkspacePaneField.title),
                WorkspaceStateCodec.encodeString(title),
            )
            await store.scheduleSave(state)
        }
        await store.flush()

        let loaded = await makeStore().load()
        let reloaded = try XCTUnwrap(loaded.topology)
        XCTAssertEqual(reloaded.tree.sessions[0].specs[paneID]?.title, "three")
    }

    /// A debounce that outlives the process is a debounce that loses the last thing the user did.
    /// `flush()` is the daemon-shutdown path and must write without waiting one out.
    func testFlushWritesWithoutWaitingOutTheDebounce() async {
        let store = makeStore(debounce: .seconds(3600))
        let initial = await store.load()
        await store.scheduleSave(initial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        await store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Corruption

    /// A corrupt file must degrade to a usable workspace, never brick the daemon. This is a NEW class
    /// of failure: on the client a bad workspace file cost one device its layout; here it would cost
    /// every client at once.
    func testACorruptFileDegradesToTheDefaultAndIsKeptAside() async throws {
        try Data("{ this is not json".utf8).write(to: fileURL)

        let loaded = await makeStore().load()
        let topology = try XCTUnwrap(loaded.topology)

        XCTAssertEqual(topology.tree.sessions.count, 1)
        let aside = try asideFiles()
        XCTAssertEqual(aside.count, 1, "the bad bytes are kept, not overwritten")
        XCTAssertTrue(aside[0].hasPrefix("workspace-state.corrupt-"))
    }

    /// A file that decodes but holds no workspace is the same failure wearing a different hat.
    /// Publishing it would hand every client an empty window — worse than the default, because it
    /// looks deliberate.
    func testAFileWithNoWorkspaceDegradesToTheDefault() async throws {
        try Data(#"{"version":1,"entries":[]}"#.utf8).write(to: fileURL)

        let loaded = await makeStore().load()
        let topology = try XCTUnwrap(loaded.topology)

        XCTAssertEqual(topology.tree.sessions.count, 1)
        XCTAssertEqual(try asideFiles().count, 1)
    }

    /// A version bump forces a decode-fail rather than a migration — the standing no-backcompat
    /// rule — and that path has to keep the old bytes too.
    func testAFileFromAnotherVersionIsKeptAsideNotMigrated() async throws {
        try Data(#"{"version":99,"entries":[]}"#.utf8).write(to: fileURL)

        _ = await makeStore().load()

        XCTAssertEqual(try asideFiles().count, 1)
    }

    // MARK: - Location

    /// The file is a SIBLING of `scrollback/`, not a resident of it. `sweep(maxAge:keepNewest:)`
    /// walks only `*.scrollback` there, so it would not see this file either way — but a workspace
    /// living inside a directory something else prunes is the arrangement that survives until the
    /// day it does not.
    func testTheFileIsASiblingOfTheScrollbackDirectory() async throws {
        let store = try XCTUnwrap(HostWorkspaceStore.make(
            environment: ["SLOPDESK_WORKSPACE_STATE_DIR": directory.path],
            hostDisplayName: "mac-studio",
        ))
        let url = await store.fileURLForTesting
        XCTAssertEqual(url.lastPathComponent, "workspace-state.json")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    }
}
