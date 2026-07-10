import Foundation
import Observation
import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// The STORE half of the host-computed By-Project key (wire type 34, 2026-07-10 re-scope — replaces the
/// deleted grouping/sort hamburger suite `TabSortStoreTests`): ``WorkspaceStore/setProjectKey(_:for:)`` is
/// the guarded write sink the connection layer funnels host pushes into, and
/// ``WorkspaceStore/paneProjectKey(_:)`` is the read the sidebar sectioning derives from
/// (host key → `lastKnownCwd` fallback → `nil`/"Other").
/// Drives a LIVE `.tree` store through the `FakePaneSession` seam — never a real socket.
@MainActor
final class ProjectKeyStoreTests: XCTestCase {
    // MARK: - Fixtures

    /// A one-session `.tree` store with three single-pane tabs carrying distinct cwds. `seedProjectKeys`
    /// lands pre-persisted ``PaneSpec/projectKey`` values (keyed by tab index) in the restoring tree —
    /// the "read a poisoned/pre-existing spec from disk" seam that bypasses the write guard.
    private func makeStore(seedProjectKeys: [Int: String] = [:]) -> (WorkspaceStore, [TabID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        let cwds = ["/Users/me/alpha", "/Users/me/beta", "/Users/me/gamma"]
        for i in 0..<3 {
            let pane = PaneID()
            var spec = PaneSpec(kind: .terminal, title: "T\(i)")
            spec.lastKnownCwd = cwds[i]
            spec.projectKey = seedProjectKeys[i]
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = spec
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
        return (store, tabs.map(\.id))
    }

    private func activePane(_ store: WorkspaceStore, tab index: Int) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.tabs[index].activePane, "tab \(index) has an active pane")
    }

    // MARK: - setProjectKey persists into the spec; paneProjectKey prefers it over the cwd

    /// The host push wins over the cwd fallback AND lands in the persisted spec (so a cold relaunch
    /// renders the final sections from disk). FAILS pre-change (no `PaneSpec.projectKey` — won't compile).
    func testSetProjectKeyPersistsIntoSpecAndWinsOverCwd() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/alpha",
            "before any push the cwd is the fallback key",
        )

        store.setProjectKey("/repo/root", for: pane)
        XCTAssertEqual(
            store.tree.activeSession?.specs[pane]?.projectKey, "/repo/root",
            "the push is PERSISTED into the pane spec (not a runtime-only mirror)",
        )
        XCTAssertEqual(
            store.paneProjectKey(pane), "/repo/root",
            "the host-pushed key takes precedence over the cwd fallback",
        )
    }

    /// The lastKnownCwd fallback stands until the first push lands — By-Project groups by cwd immediately,
    /// the host key is never a hard dependency.
    func testPaneProjectKeyFallsBackToCwdUntilFirstPush() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 1)
        XCTAssertNil(store.tree.activeSession?.specs[pane]?.projectKey, "no push yet")
        XCTAssertEqual(store.paneProjectKey(pane), "/Users/me/beta", "cwd fallback until the host pushes")
    }

    // MARK: - Transient plugin-cache dirs never become a By-Project key

    /// WRITE guard: a host push that raced a zinit turbo `builtin cd` (the resolver read the PLUGIN's repo
    /// root) is DROPPED, never persisted — the pane keeps its real cwd key, no phantom
    /// `zsh-users---zsh-autosuggestions` section. FAILS on an unguarded `setProjectKey`.
    func testTransientPluginProjectKeyPushIsDropped() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)
        let poison = "/Users/me/.local/share/zinit/plugins/zsh-users---zsh-autosuggestions"

        store.setProjectKey(poison, for: pane)
        XCTAssertNil(
            store.tree.activeSession?.specs[pane]?.projectKey,
            "a plugin-cache push is dropped at the write sink, never persisted",
        )
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/alpha",
            "the pane keeps its real cwd key, not the raced plugin repo root",
        )
    }

    /// READ guard (the backstop): even a poisoned value already IN the spec (persisted before the write
    /// guard existed — seeded through the restoring tree, past `setProjectKey`) is never returned —
    /// `paneProjectKey` falls through to the cwd. FAILS on a read that trusts any non-empty spec key.
    func testPaneProjectKeySkipsPluginKeySeededInSpec() throws {
        let (store, _) = makeStore(seedProjectKeys: [0: "/x/.zinit/plugins/romkatv---powerlevel10k"])
        let pane = try activePane(store, tab: 0)
        XCTAssertEqual(
            store.tree.activeSession?.specs[pane]?.projectKey,
            "/x/.zinit/plugins/romkatv---powerlevel10k",
            "precondition: the poisoned value IS in the spec (seeded past the write guard)",
        )
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/alpha",
            "a plugin-cache key is skipped at read time ⇒ the cwd fallback wins",
        )
    }

    /// READ guard for a persisted-poison cwd fallback (pre-guard file): a plugin-looking `lastKnownCwd` is
    /// treated as absent → the "Other" bucket, never a phantom plugin section.
    func testPaneProjectKeySkipsPluginCwdFallback() {
        let a = PaneID()
        let poison = "/Users/me/.local/share/zinit/plugins/zsh-users---zsh-autosuggestions"
        var spec = PaneSpec(kind: .terminal, title: "A")
        spec.lastKnownCwd = poison
        let session = Session(
            name: "Local", tabs: [Tab(root: .leaf(a), activePane: a)], activeTabIndex: 0, specs: [a: spec],
        )
        let store = WorkspaceStore(
            restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            liveModel: .tree, makeSession: { FakePaneSession($0) }, liveVideoCap: 2, persistence: nil,
        )
        XCTAssertNil(store.paneProjectKey(a), "a plugin-looking cwd is not a project key ⇒ Other bucket")
    }

    /// An EMPTY push is meaningless (the host always sends a path — the cwd at minimum) and must not erase
    /// or shadow anything.
    func testEmptyProjectKeyPushIsDropped() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)
        store.setProjectKey("", for: pane)
        XCTAssertNil(store.tree.activeSession?.specs[pane]?.projectKey, "an empty push is dropped")
        XCTAssertEqual(store.paneProjectKey(pane), "/Users/me/alpha", "the cwd fallback stands")
    }

    // MARK: - Dirty guard: an unchanged push spends nothing

    /// A thread-safe flag box for the `withObservationTracking` onChange (a `@Sendable` closure — it may
    /// not capture a plain local `var`). The willSet actually fires synchronously on the main actor here,
    /// so the unchecked conformance is safe in practice.
    private final class MutationFlag: @unchecked Sendable {
        var fired = false
    }

    /// The host RE-ASSERTS the latched key on every reattach — an UNCHANGED re-assert must short-circuit
    /// before `updateSpecLive` (no tree write ⇒ no reconcile ⇒ no save churn). Pinned via Observation:
    /// the store's `tree` registers no mutation for the idempotent push, but does for a genuine change.
    /// FAILS on an unguarded write (updateSpecLive always reassigns `tree`, firing willSet).
    func testUnchangedProjectKeyPushDoesNotChurnTheTree() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)
        store.setProjectKey("/repo/root", for: pane)

        let mutated = MutationFlag()
        withObservationTracking {
            _ = store.tree
        } onChange: {
            mutated.fired = true
        }
        store.setProjectKey("/repo/root", for: pane) // the reattach re-assert: same value
        XCTAssertFalse(mutated.fired, "an unchanged push must not touch the tree (dirty guard)")

        store.setProjectKey("/repo/other", for: pane) // a genuine change writes through
        XCTAssertTrue(mutated.fired, "a changed push writes the spec (the guard only blocks no-ops)")
        XCTAssertEqual(store.paneProjectKey(pane), "/repo/other")
    }

    // MARK: - A cwd change does NOT clobber the host key (the host re-derives and re-pushes)

    /// The host owns the key: a later `cd` updates `lastKnownCwd` (the fallback) but the persisted host key
    /// keeps winning until the host pushes a new one — no client-side invalidation heuristics remain.
    func testCwdChangeLeavesHostKeyStanding() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)
        store.setProjectKey("/repo/root", for: pane)
        store.setLastKnownCwd("/Users/me/delta", for: pane)
        XCTAssertEqual(
            store.paneProjectKey(pane), "/repo/root",
            "the host-pushed key stands across a cwd edge; the host re-pushes on its own change edge",
        )
        store.setProjectKey("/Users/me/delta", for: pane) // the host's follow-up push
        XCTAssertEqual(store.paneProjectKey(pane), "/Users/me/delta")
    }
}
