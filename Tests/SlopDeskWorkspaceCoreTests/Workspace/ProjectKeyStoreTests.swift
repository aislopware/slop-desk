import Foundation
import Observation
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The STORE half of the host-computed By-Project key (wire type 34): ``WorkspaceStore/setProjectKey(_:for:)`` is
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
        var panes: [PaneID] = []
        for i in 0..<3 {
            let pane = PaneID()
            panes.append(pane)
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = PaneSpec(kind: .terminal, title: "T\(i)")
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
            persistence: nil,
        )
        store.attachLoopbackWorkspaceDocument()
        // The per-pane FACTS ride the mirror, not the spec — seeded here the way the control push does.
        for (i, pane) in panes.enumerated() {
            store.workspaceMirror.writeFastPath(
                pane: pane.raw, field: WorkspacePaneField.cwd, string: cwds[i],
            )
            if let key = seedProjectKeys[i] {
                store.workspaceMirror.writeFastPath(
                    pane: pane.raw, field: WorkspacePaneField.projectKey, string: key,
                )
            }
        }
        return (store, tabs.map(\.id))
    }

    private func activePane(_ store: WorkspaceStore, tab index: Int) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.tabs[index].activePane, "tab \(index) has an active pane")
    }

    // MARK: - setProjectKey persists into the spec; paneProjectKey prefers it over the cwd

    /// The host push wins over the cwd fallback AND lands in the mirror, where every reader looks.
    func testSetProjectKeyLandsInTheMirrorAndWinsOverCwd() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/alpha",
            "before any push the cwd is the fallback key",
        )

        store.setProjectKey("/repo/root", for: pane)
        XCTAssertEqual(
            store.projectKey(for: pane), "/repo/root",
            "the push is PERSISTED into the pane spec (not a runtime-only mirror)",
        )
        XCTAssertEqual(
            store.paneProjectKey(pane), "/repo/root",
            "the host-pushed key takes precedence over the cwd fallback",
        )
    }

    /// The code panel's ensure gate (``WorkspaceStore/hostPushedProjectKey(_:)``): `nil` while the
    /// pane rides its cwd fallback — a client-side guess must never spawn a host code-server — and
    /// the pushed key verbatim once type 34 lands.
    func testHostPushedProjectKeyIsNilUntilThePushLands() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)

        XCTAssertNil(
            store.hostPushedProjectKey(pane),
            "the cwd fallback must not leak out of the pushed-only accessor",
        )
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/alpha",
            "…while the sectioning read still tolerates it (the waiting-surface distinction)",
        )

        store.setProjectKey("/repo/root", for: pane)
        XCTAssertEqual(store.hostPushedProjectKey(pane), "/repo/root")
    }

    /// The lastKnownCwd fallback stands until the first push lands — By-Project groups by cwd immediately,
    /// the host key is never a hard dependency.
    func testPaneProjectKeyFallsBackToCwdUntilFirstPush() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 1)
        XCTAssertNil(store.projectKey(for: pane), "no push yet")
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
            store.projectKey(for: pane),
            "a plugin-cache push is dropped at the write sink, never persisted",
        )
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/alpha",
            "the pane keeps its real cwd key, not the raced plugin repo root",
        )
    }

    /// READ guard (the backstop): even a poisoned value already IN the spec (persisted before the write
    /// guard existed — seeded past `setProjectKey`) is never returned —
    /// `paneProjectKey` falls through to the cwd. FAILS on a read that trusts any non-empty spec key.
    func testPaneProjectKeySkipsAPluginKeyThatSlippedPastTheWriteGuard() throws {
        let (store, _) = makeStore(seedProjectKeys: [0: "/x/.zinit/plugins/romkatv---powerlevel10k"])
        let pane = try activePane(store, tab: 0)
        XCTAssertEqual(
            store.projectKey(for: pane),
            "/x/.zinit/plugins/romkatv---powerlevel10k",
            "precondition: the poisoned value IS in the mirror (seeded past the write guard)",
        )
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/alpha",
            "a plugin-cache key is skipped at read time ⇒ the cwd fallback wins",
        )
    }

    /// READ guard for a poisoned cwd fallback: a plugin-looking `pane/cwd` is
    /// treated as absent → the "Other" bucket, never a phantom plugin section.
    func testPaneProjectKeySkipsPluginCwdFallback() {
        let a = PaneID()
        let poison = "/Users/me/.local/share/zinit/plugins/zsh-users---zsh-autosuggestions"
        let session = Session(
            name: "Local", tabs: [Tab(root: .leaf(a), activePane: a)], activeTabIndex: 0,
            specs: [a: PaneSpec(kind: .terminal, title: "A")],
        )
        let store = WorkspaceStore(
            restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            liveModel: .tree, makeSession: { seed in FakePaneSession(seed.spec) }, liveVideoCap: 2, persistence: nil,
        )
        store.attachLoopbackWorkspaceDocument()
        // Past the write guard, the way a pre-guard persisted value would have arrived.
        store.workspaceMirror.writeFastPath(pane: a.raw, field: WorkspacePaneField.cwd, string: poison)
        XCTAssertNil(store.paneProjectKey(a), "a plugin-looking cwd is not a project key ⇒ Other bucket")
    }

    /// An EMPTY push is meaningless (the host always sends a path — the cwd at minimum) and must not erase
    /// or shadow anything.
    func testEmptyProjectKeyPushIsDropped() throws {
        let (store, _) = makeStore()
        let pane = try activePane(store, tab: 0)
        store.setProjectKey("", for: pane)
        XCTAssertNil(store.projectKey(for: pane), "an empty push is dropped")
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
            _ = store.workspaceMirrorRevision
        } onChange: {
            mutated.fired = true
        }
        store.setProjectKey("/repo/root", for: pane) // the reattach re-assert: same value
        XCTAssertFalse(mutated.fired, "an unchanged push must not repaint anything (dirty guard)")

        store.setProjectKey("/repo/other", for: pane) // a genuine change writes through
        XCTAssertTrue(mutated.fired, "a changed push moves the mirror (the guard only blocks no-ops)")
        XCTAssertEqual(store.paneProjectKey(pane), "/repo/other")
    }

    // MARK: - A cwd change does NOT clobber the host key (the host re-derives and re-pushes)

    /// The host owns the key: a later `cd` updates `pane/cwd` (the fallback) but the host key
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

    // MARK: - New split/tab/window panes inherit the parent's RESOLVED key with the cwd

    /// A split from a pane whose cwd is a repo SUBDIRECTORY must land in the parent's section on the
    /// FIRST frame: the new spec inherits the parent's host-pushed key alongside the cwd. Without the
    /// seed the new pane sections by its raw subdir cwd until the host's own type-34 round-trip lands
    /// — the "split tears off into a section named after the subdir" symptom.
    func testSplitSeedsParentHostKeyWithInheritedCwd() throws {
        let (store, _) = makeStore()
        let parent = try activePane(store, tab: 0)
        store.setProjectKey("/repo/root", for: parent)
        store.setLastKnownCwd("/repo/root/packages/api", for: parent)

        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let child = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane, "the split lands focused")
        XCTAssertNotEqual(child, parent, "a new leaf exists and is active")
        XCTAssertEqual(
            store.paneCwd(for: child), "/repo/root/packages/api",
            "precondition: the split inherited the parent's cwd",
        )
        XCTAssertEqual(
            store.paneProjectKey(child), "/repo/root",
            "the child sections under the parent's resolved key immediately — no host round-trip flash",
        )
    }

    /// Same seed on the new-tab path; the new-WINDOW path's default policy resolves `home` (not the
    /// parent cwd — `docs/DECISIONS.md`), so its subtree guard correctly seeds nothing there.
    func testNewTabSeedsParentHostKeyAndNewWindowPolicyDoesNot() throws {
        let (store, _) = makeStore()
        let parent = try activePane(store, tab: 0)
        store.setProjectKey("/repo/root", for: parent)
        store.setLastKnownCwd("/repo/root/sub", for: parent)

        store.newTab(kind: .terminal)
        let tabChild = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertEqual(store.paneProjectKey(tabChild), "/repo/root", "new tab seeds the parent key")

        store.newSession(name: "Second", kind: .terminal)
        let windowChild = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNil(
            store.projectKey(for: windowChild),
            "the default new-window policy opens at HOME — outside the parent key's subtree, so the "
                + "guard seeds nothing and the host resolves the child's own key",
        )
    }

    /// The seed is guarded by SUBTREE COVERAGE: when the inherited cwd is NOT inside the parent
    /// key's subtree (a stale key across an un-re-pushed `cd`, or a working-directory policy that
    /// resolves a fixed dir), seeding would file the child under the WRONG project — leave the key
    /// to the host.
    func testSplitDoesNotSeedWhenInheritedCwdIsOutsideTheParentKey() throws {
        let (store, _) = makeStore()
        let parent = try activePane(store, tab: 0)
        store.setProjectKey("/repo/root", for: parent)
        store.setLastKnownCwd("/elsewhere/scratch", for: parent) // cd'd out; host re-push not landed yet

        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let child = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNil(
            store.projectKey(for: child),
            "an uncovered inherited cwd seeds nothing — the host resolves the child's key",
        )
        XCTAssertEqual(
            store.paneProjectKey(child), "/elsewhere/scratch",
            "the child falls back to its cwd (the same section its OWN resolve would start from)",
        )
    }

    /// A parent still on the cwd FALLBACK (no host push yet) seeds nothing — the child's identical
    /// cwd fallback already sections it beside the parent, and a guessed key could be wrong.
    func testSplitFromCwdFallbackParentSeedsNothing() throws {
        let (store, _) = makeStore()
        let parent = try activePane(store, tab: 0)
        XCTAssertNil(store.projectKey(for: parent), "precondition: no host key")

        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let child = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNil(store.projectKey(for: child), "nothing to inherit")
        XCTAssertEqual(
            store.paneProjectKey(child), "/Users/me/alpha",
            "the child's own cwd fallback matches the parent's section anyway",
        )
    }
}
