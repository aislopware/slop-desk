import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// `workspace-cache.json` — the picture of the host's document this device carries between launches
/// (docs/45 §7.3).
///
/// The facts it holds used to live on `PaneSpec` and travel in `workspace.json`. They are document
/// facts now, and a document a disconnected client cannot remember is a document it does not have:
/// the shell respawns in `$HOME` instead of the project, the rail titles six rows "Terminal", and
/// By-Project collapses into one bucket. Every test here is one of those three.
@MainActor
final class WorkspaceDocumentCacheTests: XCTestCase {
    private let hostKey = "mac-studio:7420"
    private let project = "/Volumes/Lacie/Workspace/oss/slop-desk"

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheStore(in dir: URL) -> WorkspaceCacheStore {
        WorkspaceCacheStore(fileURL: dir.appendingPathComponent("workspace-cache.json"))
    }

    /// A one-session, one-tab, one-pane tree with a KNOWN pane id.
    private func tree(pane: PaneID) -> TreeWorkspace {
        let tab = Tab(id: TabID(), title: "one", root: .leaf(pane), activePane: pane)
        let session = Session(
            id: SessionID(),
            name: "Local",
            tabs: [tab],
            specs: [pane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    /// Records every materialization the store asks for, so the `spawnCwd` handed to the session
    /// factory — the value that becomes `channelOpen.initialCwd` — is assertable with no socket.
    private final class MaterializationLog {
        private(set) var seeds: [PaneMaterialization] = []
        func record(_ seed: PaneMaterialization) { seeds.append(seed) }
        func spawnCwd(for id: PaneID) -> String? { seeds.last { $0.id == id }?.spawnCwd }
    }

    // MARK: - The spawn directory survives the process

    /// Quit the client, restart hostd, reopen: the pane's shell comes back in its PROJECT, not `$HOME`.
    ///
    /// The pane has no live shell to ask on launch and no PTY left to reattach to, so the whole
    /// answer is what this device remembered. `spawnCwd == nil` is not a cosmetic miss: it becomes an
    /// empty `channelOpen.initialCwd`, and `PTYProcess.resolveCwd(nil, home:)` starts the shell at
    /// `$HOME` — wrong prompt, wrong git line, wrong By-Project section.
    func testARestoredPaneRespawnsInTheDirectoryItWasCreatedIn() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        let pane = PaneID()

        // Session one: the pane is created with a spawn directory and the store is asked to persist.
        let first = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: hostKey,
        )
        first.setSpawnCwd(project, for: pane)
        first.saveImmediately()

        // Session two: a brand-new process, same tree off disk, nothing live anywhere.
        let log = MaterializationLog()
        _ = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { seed in
                log.record(seed)
                return FakePaneSession(seed.spec)
            },
            documentCache: cache,
            cacheHostKey: hostKey,
        )

        XCTAssertEqual(
            log.spawnCwd(for: pane), project,
            "the restored pane materialized with no spawn directory — its shell starts at $HOME",
        )
    }

    /// A picture of host A is never painted over host B.
    func testACacheFromAnotherHostIsDiscarded() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        let pane = PaneID()

        let first = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: hostKey,
        )
        first.setSpawnCwd(project, for: pane)
        first.saveImmediately()

        let log = MaterializationLog()
        let second = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { seed in
                log.record(seed)
                return FakePaneSession(seed.spec)
            },
            documentCache: cache,
            cacheHostKey: "other-mac:7420",
        )
        XCTAssertNil(log.spawnCwd(for: pane), "another host's folders must not seed this one")
        XCTAssertNil(second.paneCwd(for: pane))
    }

    /// With no host known yet there is nothing to gate a paint on, so nothing is painted — and
    /// nothing is written either, because a file no load can ever match only grows.
    func testAnEmptyHostKeyNeitherReadsNorWrites() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        let pane = PaneID()

        let store = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
        )
        store.setSpawnCwd(project, for: pane)
        store.saveImmediately()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.fileURL.path),
            "a cache with no host on it can never be shown to the right one",
        )
        XCTAssertTrue(cache.load(hostKey: "").isEmpty)
    }

    /// Switching hosts mid-session stops the cache being written, rather than blending two machines.
    ///
    /// Every fact in it is an absolute path on ONE filesystem. After a switch the mirror holds some
    /// of each, and writing that under either name would seed the next launch with directories that
    /// do not exist on the host it paints them for.
    func testConnectingToADifferentHostStopsTheCacheBeingWritten() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        let pane = PaneID()

        let store = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: hostKey,
        )
        store.setLastKnownCwd(project, for: pane)
        store.saveImmediately()
        XCTAssertFalse(cache.load(hostKey: hostKey).isEmpty, "the seed host's picture is written")

        store.commitConnectionTarget(ConnectionTarget(host: "macbook", port: 7420))
        store.setLastKnownCwd("/Users/me/elsewhere", for: pane)
        store.saveImmediately()

        let row = try XCTUnwrap(
            cache.load(hostKey: hostKey)[WorkspaceKey(.pane, pane.raw, WorkspacePaneField.cwd)],
        )
        XCTAssertEqual(
            WorkspaceStateCodec.decodeString(row), project,
            "the second host's directory was filed under the first host's name",
        )
    }

    // MARK: - The cold sidebar

    /// A launch with the host unreachable still names the folders and their projects.
    ///
    /// `rowTitle` resolves `cwdFolderName(cwd)` first and `paneProjectKey` sections by
    /// `pane/projectKey`; with both `nil` every row reads "Terminal" and every section collapses into
    /// one "Other". Neither repairs while the host is down.
    func testACwdAndProjectKeySurviveIntoTheNextLaunch() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        let pane = PaneID()

        let first = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: hostKey,
        )
        first.setLastKnownCwd(project, for: pane)
        first.setProjectKey(project, for: pane)
        first.saveImmediately()

        let second = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: hostKey,
        )
        XCTAssertEqual(second.paneCwd(for: pane), project, "the row has no folder name to show")
        XCTAssertEqual(second.projectKey(for: pane), project, "By-Project collapses to one bucket")
    }

    /// The cached cwd is a PICTURE, not a source: the first host frame that supplies the key wins,
    /// and the seeded value is erased rather than promoted.
    func testHostTruthOverridesTheSeededCwd() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        let pane = PaneID()

        let first = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: hostKey,
        )
        first.setLastKnownCwd(project, for: pane)
        first.saveImmediately()

        let second = WorkspaceStore(
            restoringTree: tree(pane: pane),
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: hostKey,
        )
        XCTAssertEqual(second.paneCwd(for: pane), project)

        // A host frame carrying a different cwd for the same pane.
        second.workspaceMirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: UUID(),
            baseStateNum: 0,
            newStateNum: 1,
            payload: WorkspaceStateCodec.encodeSnapshot(HostWorkspaceState([WorkspaceEntry(
                key: WorkspaceKey(.pane, pane.raw, WorkspacePaneField.cwd),
                value: WorkspaceStateCodec.encodeString("/elsewhere"),
            )])),
        )
        XCTAssertEqual(
            second.paneCwd(for: pane), "/elsewhere",
            "the cached picture outlived the fact it was a picture of",
        )
    }

    // MARK: - The reopen ring

    /// ⇧⌘T brings the pane back where it was.
    ///
    /// The reopen ring keeps the original `PaneID`s, so reaping a closed pane's facts on the close
    /// edge means the reopened pane comes back with none. It is also the rule the HOST's applier
    /// already follows — `WorkspaceIntentApplier.pruned` unions the closed-tab ring into its live set
    /// — and one document with two answers is the whole failure mode.
    func testAReopenedTabsPaneKeepsItsSpawnDirectory() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneID()
        var seeded = tree(pane: pane)
        // A second tab, so closing the first leaves a live session behind to reopen into.
        let other = PaneID()
        seeded.sessions[0].tabs.append(Tab(id: TabID(), title: "two", root: .leaf(other), activePane: other))
        seeded.sessions[0].specs[other] = PaneSpec(kind: .terminal, title: "Terminal")

        let log = MaterializationLog()
        let store = WorkspaceStore(
            restoringTree: seeded,
            liveModel: .tree,
            makeSession: { seed in
                log.record(seed)
                return FakePaneSession(seed.spec)
            },
        )
        store.setSpawnCwd(project, for: pane)
        let closing = try XCTUnwrap(store.tree.tab(containing: pane))
        store.closeTab(closing.1)
        XCTAssertFalse(store.tree.contains(pane), "the tab really closed")

        store.reopenClosedTab(at: 0)
        XCTAssertTrue(store.tree.contains(pane), "the tab really came back")
        XCTAssertEqual(
            log.spawnCwd(for: pane), project,
            "the reopened pane lost its spawn directory and its shell restarts at $HOME",
        )
    }

    // MARK: - The file itself

    /// A hand-edited file claiming a live process must not paint a fake-live row.
    func testLivenessRowsAreRefusedOnTheWayIn() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        let pane = UUID()

        var state = HostWorkspaceState()
        state.set(WorkspaceKey(.pane, pane, WorkspacePaneField.cwd), WorkspaceStateCodec.encodeString(project))
        state.set(WorkspaceKey(.pane, pane, WorkspacePaneField.commandRunning), WorkspaceStateCodec.encodeBool(true))
        state.set(WorkspaceKey(.pane, pane, WorkspacePaneField.liveness), Data([PaneLivenessState.attached.rawValue]))
        try cache.save(state, hostKey: hostKey)

        let loaded = cache.load(hostKey: hostKey)
        XCTAssertNotNil(loaded[WorkspaceKey(.pane, pane, WorkspacePaneField.cwd)], "a place survives")
        XCTAssertNil(
            loaded[WorkspaceKey(.pane, pane, WorkspacePaneField.liveness)],
            "a restored `attached` liveness is the fake-live render, not a cache hit",
        )
        XCTAssertNil(loaded[WorkspaceKey(.pane, pane, WorkspacePaneField.commandRunning)])
    }

    /// Corrupt bytes cost one RTT of "connecting", never a launch.
    func testACorruptCacheLoadsAsEmpty() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = cacheStore(in: dir)
        try Data("{ not json at all".utf8).write(to: cache.fileURL)
        XCTAssertTrue(cache.load(hostKey: hostKey).isEmpty)
    }
}
