import XCTest
@testable import AislopdeskWorkspaceCore

/// E9 / WI-7 (ES-E9-5, B2): pins the `Details: *` jump commands — the `.selectDetailsTab(_:)` action +
/// its three `chord: nil` `.view` registry bindings (Info / Git / Files; the old Outline tab is merged
/// into Info's Commands section) — that switch the right-hand Details panel to a specific
/// tab. The action is VIEW-owned (the live app installs a `selectDetailsTab` closure that writes
/// `DetailsPanelState.selected` + reveals the panel), so the contract under test is: routing
/// `.selectDetailsTab(tab)` through the single-source-of-truth ``WorkspaceBindingRegistry/route(_:to:)``
/// FORWARDS `tab` to the supplied closure (per tab), and a `nil` closure (the headless / test default) is a
/// graceful no-op — never a trap, never a tree mutation.
///
/// Mirrors the `route(_:to:)` harness of ``TreeCommandRoutingTests`` (a `.tree`-live store over the
/// `FakePaneSession` seam, no SwiftUI view). The closure-forwarding is the real seam a chord / menu / palette
/// row drives; the view-side `selected = tab` + reveal is wired in `WorkspaceRootView` (GUI-verified).
@MainActor
final class DetailsTabRoutingTests: XCTestCase {
    private func makeTreeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    // MARK: - Routing: the closure fires with the right tab (per tab) + nil is a no-op

    /// `.selectDetailsTab(tab)` forwards EACH of the three tabs to the supplied `selectDetailsTab` closure
    /// EXACTLY (no off-by-one / wrong-tab mapping), and never mutates the tree. FAILS on the un-fixed code
    /// (no `.selectDetailsTab` action / routing case to fire the closure).
    func testSelectDetailsTabForwardsEachTabToTheClosure() {
        for tab in DetailsPanelTab.allCases {
            let store = makeTreeStore()
            let before = store.tree
            var captured: [DetailsPanelTab] = []
            WorkspaceBindingRegistry.route(.selectDetailsTab(tab), to: store, selectDetailsTab: { captured.append($0) })
            XCTAssertEqual(captured, [tab], "selectDetailsTab(\(tab)) forwards exactly \(tab) once")
            XCTAssertEqual(store.tree, before, "a Details-tab jump is a view affordance — the tree is unchanged")
        }
    }

    /// `.selectDetailsTab(_:)` WITHOUT a `selectDetailsTab` closure (the headless / test default) is a
    /// graceful no-op — never a trap, never a tree mutation. Pins the nil-closure path stays inert (so the
    /// three commands are never DEAD chords, just inert until the view installs the closure).
    func testSelectDetailsTabWithoutClosureIsAGracefulNoOp() {
        let store = makeTreeStore()
        let before = store.tree
        for tab in DetailsPanelTab.allCases {
            WorkspaceBindingRegistry.route(.selectDetailsTab(tab), to: store) // no closure ⇒ no-op
        }
        XCTAssertEqual(store.tree, before, "selectDetailsTab with no closure leaves the tree unchanged (no trap)")
    }

    /// The CANVAS fallback path (retained-but-dead model) also FORWARDS the selected tab via the closure —
    /// the Details panel is tree-shell chrome, but the canvas route must not drop the command. Pins the
    /// `routeCanvas` case exists (a missing case would compile-fail the exhaustive switch, but this proves it
    /// FORWARDS, not just compiles).
    func testSelectDetailsTabRoutesOnCanvasPath() {
        // The default `liveModel` is `.canvas` (the retained-but-dead path) — build it the way the canvas
        // routing suite does, so `route(...)` dispatches through `routeCanvas`.
        let store = WorkspaceStore(
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
        var captured: DetailsPanelTab?
        WorkspaceBindingRegistry.route(.selectDetailsTab(.git), to: store, selectDetailsTab: { captured = $0 })
        XCTAssertEqual(captured, .git, "the canvas path also forwards the selected tab to the closure")
    }

    // MARK: - Registry: the three bindings exist, are `.view`, and are chord-less

    /// Each of the three `Details: *` commands has a registered binding with the documented id, the `.view`
    /// category, and NO default chord (`chord: nil` — unbound, palette/menu-only). FAILS on the un-fixed code
    /// (the bindings don't exist) and on a category / chord regression. Revert-to-confirm-fail: removing any
    /// of the three registry rows drops its `binding(for:)` to nil here.
    func testDetailsBindingsExistAreViewAndChordless() {
        let expected: [(id: String, tab: DetailsPanelTab)] = [
            ("view.detailsInfo", .info),
            ("view.detailsGit", .git),
            ("view.detailsFiles", .files),
        ]
        for (id, tab) in expected {
            let binding = WorkspaceBindingRegistry.binding(for: .selectDetailsTab(tab))
            XCTAssertNotNil(binding, "a binding exists for Details: \(tab)")
            XCTAssertEqual(binding?.id, id, "the \(tab) Details binding has id \(id)")
            XCTAssertEqual(binding?.category, .view, "the \(tab) Details binding is in the View category")
            XCTAssertNil(binding?.chord, "the \(tab) Details binding is unbound by default (chord: nil)")
        }
    }

    /// The three commands surface in the cheat-sheet / palette display set (the View group of
    /// `groupedForDisplay`) — so they are discoverable + bindable even though they carry no default chord.
    /// The retired `view.detailsOutline` must NOT resurface (its tab merged into Info's Commands section).
    func testDetailsBindingsSurfaceInTheViewDisplayGroup() {
        let view = WorkspaceBindingRegistry.groupedForDisplay.first { $0.category == .view }
        let ids = Set(view?.bindings.map(\.id) ?? [])
        XCTAssertTrue(
            ids.isSuperset(of: ["view.detailsInfo", "view.detailsGit", "view.detailsFiles"]),
            "the three Details: * jump commands surface in the View display group (palette / cheat sheet)",
        )
        XCTAssertFalse(ids.contains("view.detailsOutline"), "the merged-away Outline jump command is gone")
    }

    /// `.selectDetailsTab(_:)` is a window-scope panel switch — it must NOT require an active pane (so the
    /// palette / menu never grey it out on an empty shell), matching `.toggleDetailsPanel`.
    func testSelectDetailsTabDoesNotRequireAnActivePane() {
        for tab in DetailsPanelTab.allCases {
            XCTAssertFalse(
                WorkspaceAction.selectDetailsTab(tab).requiresActivePane,
                "a Details-tab jump is window-scope — needs no active pane",
            )
        }
    }
}
