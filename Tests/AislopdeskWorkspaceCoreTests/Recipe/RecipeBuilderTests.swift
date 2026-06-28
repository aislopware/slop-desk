import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-4 of E16: the tree ``Session`` ⇄ ``Recipe`` bridge (``RecipeBuilder``). `snapshot` DFS-flattens a
/// split tree to ordered ``RecipePane``s (split direction + size fraction from ``WeightedChild/weight``, cwd
/// from ``PaneSpec/lastKnownCwd``, portabilized when opted in); `restorePlan` resolves cwd templates and
/// reconstructs the per-tab tree, preserving split axis + relative size. Scope filtering, Layout-Only vs
/// Include-Commands, and the omit-runtime-fields export guarantee are all pinned. Fully headless — no view,
/// no NSWindow, no disk.
final class RecipeBuilderTests: XCTestCase {
    // MARK: - canonical shape (compare a tree IGNORING leaf ids + absolute weights, by relative fraction)

    private indirect enum Shape: Equatable {
        case leaf
        case split(SplitAxis, [ShapeChild])
    }

    private struct ShapeChild: Equatable {
        let fractionPct: Int
        let node: Shape
    }

    /// Canonicalise a tree to its SHAPE: axis nesting + ordered children, each child labelled by its
    /// rounded percentage of its split (so `flex(1),flex(1)` and `flex(0.5),flex(0.5)` compare EQUAL) and
    /// all leaf identity erased. Proves "same tree shape (split axis + size preserved)" without depending on
    /// the freshly-minted restore ids or absolute weight scale.
    private func canonical(_ node: SplitNode) -> Shape {
        switch node {
        case .leaf:
            return .leaf
        case let .split(_, axis, children):
            var total = 0.0
            for child in children { total += magnitude(child.weight) }
            let safe = Double.maximum(total, 0.000_001)
            let kids = children.map {
                ShapeChild(
                    fractionPct: Int((magnitude($0.weight) / safe * 100).rounded()),
                    node: canonical($0.node),
                )
            }
            return .split(axis, kids)
        }
    }

    private func magnitude(_ weight: SplitWeight) -> Double {
        switch weight {
        case let .flex(value): value
        case let .fixed(value): value
        }
    }

    // MARK: - fixtures

    private func terminalSpec(cwd: String?) -> PaneSpec {
        PaneSpec(kind: .terminal, title: "", lastKnownCwd: cwd)
    }

    /// A 2-tab session: tab "API" = a horizontal split of two `/work/api` panes; tab "Web" = a single
    /// `/work/web` pane. Returns the session plus the leaf ids so tests can pin per-pane data + tree shape.
    private func twoTabSession() -> (session: Session, apiRoot: SplitNode, web: PaneID, api: (PaneID, PaneID)) {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let apiRoot = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let apiTab = Tab(title: "API", root: apiRoot, activePane: a)
        let webTab = Tab(title: "Web", root: .leaf(c), activePane: c)
        let specs: [PaneID: PaneSpec] = [
            a: terminalSpec(cwd: "/work/api"),
            b: terminalSpec(cwd: "/work/api"),
            c: terminalSpec(cwd: "/work/web"),
        ]
        let session = Session(name: "Local", tabs: [apiTab, webTab], activeTabIndex: 0, specs: specs)
        return (session, apiRoot, c, (a, b))
    }

    private func recentCommands(_ fixture: (session: Session, apiRoot: SplitNode, web: PaneID, api: (PaneID, PaneID)))
        -> [PaneID: [String]]
    {
        [
            fixture.api.0: ["tail -F log/prod.log"],
            fixture.api.1: ["make deploy"],
            fixture.web: ["npm run preview"],
        ]
    }

    /// The exact recipe from `spec/customization__custom-commands.md` (the same value
    /// `RecipeTOMLCodecTests.specRecipe` pins) — `snapshot` must reproduce it byte-for-byte as a value.
    private func specRecipe() -> Recipe {
        Recipe(
            name: "deploy-prod-debug",
            version: 1,
            scope: .window,
            window: RecipeWindow(tabs: [
                RecipeTab(title: "API", panes: [
                    RecipePane(cwd: "{{current_folder}}/api", commands: ["tail -F log/prod.log"]),
                    RecipePane(
                        cwd: "{{current_folder}}/api",
                        commands: ["make deploy"],
                        split: .right,
                        size: 0.5,
                    ),
                ]),
                RecipeTab(title: "Web", panes: [
                    RecipePane(cwd: "{{current_folder}}/web", commands: ["npm run preview"]),
                ]),
            ]),
        )
    }

    // MARK: - snapshot reproduces the documented spec recipe

    func testSnapshotWindowWithPortableCwdAndCommandsMatchesSpecRecipe() {
        let fixture = twoTabSession()
        let recipe = RecipeBuilder.snapshot(
            session: fixture.session,
            scope: .window,
            name: "deploy-prod-debug",
            recentCommands: recentCommands(fixture),
            portable: true,
            home: "/Users/me",
            currentFolder: "/work",
        )
        XCTAssertEqual(recipe, specRecipe(), "a 2-tab/2-pane window snapshots to the spec recipe value")
    }

    // MARK: - restorePlan reproduces the same tree shape + resolved cwds

    func testRestorePlanReproducesTreeShapeAndResolvesCwds() {
        let fixture = twoTabSession()
        let recipe = RecipeBuilder.snapshot(
            session: fixture.session, scope: .window, name: "x",
            recentCommands: recentCommands(fixture), portable: true,
            home: "/Users/me", currentFolder: "/work",
        )
        let plan = RecipeBuilder.restorePlan(
            recipe,
            home: "/Users/me",
            currentFolder: "/work",
            recipeLocation: "/recipes",
        )

        XCTAssertEqual(plan.scope, .window)
        XCTAssertEqual(plan.tabs.count, 2)
        XCTAssertEqual(plan.tabs.map(\.title), ["API", "Web"])

        // Tree SHAPE (axis + split sizes) round-trips for both tabs.
        XCTAssertEqual(canonical(plan.tabs[0].tree), canonical(fixture.apiRoot), "API split shape preserved")
        XCTAssertEqual(canonical(plan.tabs[1].tree), canonical(.leaf(fixture.web)), "Web single-pane shape preserved")

        // cwd templates re-expand against the OPEN-time current_folder.
        let apiCwds = plan.tabs[0].tree.allPaneIDs().compactMap { plan.tabs[0].panes[$0].flatMap(\.cwd) }
        XCTAssertEqual(apiCwds, ["/work/api", "/work/api"])
        let webCwds = plan.tabs[1].tree.allPaneIDs().compactMap { plan.tabs[1].panes[$0].flatMap(\.cwd) }
        XCTAssertEqual(webCwds, ["/work/web"])

        // Commands survive in DFS-leaf order.
        let apiCmds = plan.tabs[0].tree.allPaneIDs().compactMap { plan.tabs[0].panes[$0]?.commands }
        XCTAssertEqual(apiCmds, [["tail -F log/prod.log"], ["make deploy"]])
    }

    // MARK: - scope filtering

    func testScopeTabKeepsOnlyTheFocusedTab() {
        let fixture = twoTabSession() // activeTabIndex 0 → "API"
        let recipe = RecipeBuilder.snapshot(session: fixture.session, scope: .tab, name: "x")
        XCTAssertEqual(recipe.scope, .tab)
        XCTAssertEqual(recipe.window.tabs.count, 1, "scope tab drops the other tabs")
        XCTAssertEqual(recipe.window.tabs.first?.title, "API")
    }

    func testScopeWindowKeepsEveryTab() {
        let fixture = twoTabSession()
        let recipe = RecipeBuilder.snapshot(session: fixture.session, scope: .window, name: "x")
        XCTAssertEqual(recipe.window.tabs.count, 2)
    }

    // MARK: - Layout-Only vs Include-Commands

    func testLayoutOnlyLeavesCommandsEmptyIncludeCommandsFillsThem() {
        let fixture = twoTabSession()

        // Layout-Only: no recentCommands passed → every pane's commands empty.
        let layout = RecipeBuilder.snapshot(session: fixture.session, scope: .window, name: "x")
        let layoutCommands = layout.window.tabs.flatMap(\.panes).flatMap(\.commands)
        XCTAssertTrue(layoutCommands.isEmpty, "Layout-Only leaves every pane's commands empty")

        // Include-Commands: the recent-block map fills each pane.
        let withCommands = RecipeBuilder.snapshot(
            session: fixture.session, scope: .window, name: "x", recentCommands: recentCommands(fixture),
        )
        XCTAssertEqual(withCommands.window.tabs.first?.panes.first?.commands, ["tail -F log/prod.log"])
        XCTAssertEqual(withCommands.window.tabs.first?.panes.last?.commands, ["make deploy"])
    }

    // MARK: - export omits scrollback / keybindings / agent sessions

    func testExportOmitsRuntimeFields() {
        // A pane spec carrying per-pane RUNTIME state that must NEVER export into a portable recipe.
        let pane = PaneID()
        let richSpec = PaneSpec(
            kind: .terminal,
            title: "secret-title",
            resumeSessionID: UUID(),
            resumeLastReceivedSeq: 42,
            lastKnownCwd: "/work",
            lastKnownTitle: "ssh prod-bastion",
        )
        let session = Session(
            name: "Local",
            tabs: [Tab(root: .leaf(pane), activePane: pane)],
            specs: [pane: richSpec],
        )
        let recipe = RecipeBuilder.snapshot(session: session, scope: .window, name: "x")

        let recipePane = recipe.window.tabs.first?.panes.first
        XCTAssertEqual(recipePane?.cwd, "/work", "only the cwd is carried")
        XCTAssertEqual(recipePane?.commands, [], "Layout-Only → no commands")

        // The serialised file must carry none of the omitted runtime data.
        let toml = RecipeTOMLCodec.emit(recipe)
        for forbidden in ["scrollback", "keybinding", "agent", "resumeSession", "lastKnownTitle", "ssh prod-bastion"] {
            XCTAssertFalse(toml.contains(forbidden), "a recipe must not export \(forbidden)")
        }
    }

    // MARK: - nested round-trip (DFS + relative-split beyond two panes)

    func testNestedRightDownSpineRoundTrips() {
        // horizontal[ P0 , vertical[ P1, P2 ] ] — a right-then-down spine, the class the otty save produces.
        let p0 = PaneID(), p1 = PaneID(), p2 = PaneID()
        let vert = SplitNode.split(id: SplitNodeID(), axis: .vertical, children: [
            .init(weight: .flex(1), node: .leaf(p1)),
            .init(weight: .flex(1), node: .leaf(p2)),
        ])
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(p0)),
            .init(weight: .flex(1), node: vert),
        ])
        let session = Session(
            name: "Local",
            tabs: [Tab(title: "n", root: root, activePane: p0)],
            specs: [p0: terminalSpec(cwd: nil), p1: terminalSpec(cwd: nil), p2: terminalSpec(cwd: nil)],
        )

        let recipe = RecipeBuilder.snapshot(session: session, scope: .window, name: "n")
        let panes = recipe.window.tabs.first?.panes ?? []
        XCTAssertEqual(panes.count, 3)
        XCTAssertNil(panes[0].split, "the first pane has no split")
        XCTAssertEqual(panes[1].split, .right, "the vertical subtree attaches to the RIGHT of P0")
        XCTAssertEqual(panes[2].split, .down, "P2 stacks BELOW P1")

        let plan = RecipeBuilder.restorePlan(recipe)
        XCTAssertEqual(canonical(plan.tabs[0].tree), canonical(root), "nested shape reproduced from the flat pane list")
    }

    // MARK: - asymmetric size is actually carried (not always 0.5)

    func testAsymmetricSplitSizeRoundTrips() {
        let x = PaneID(), y = PaneID()
        // y has 3× the weight → 0.75 of the split.
        let asym = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(x)),
            .init(weight: .flex(3), node: .leaf(y)),
        ])
        let session = Session(
            name: "Local",
            tabs: [Tab(root: asym, activePane: x)],
            specs: [x: terminalSpec(cwd: nil), y: terminalSpec(cwd: nil)],
        )
        let recipe = RecipeBuilder.snapshot(session: session, scope: .window, name: "a")
        XCTAssertEqual(recipe.window.tabs.first?.panes[1].size ?? 0, 0.75, accuracy: 1e-9, "size = the weight fraction")

        let plan = RecipeBuilder.restorePlan(recipe)
        XCTAssertEqual(canonical(plan.tabs[0].tree), canonical(asym), "the 25/75 split is reproduced on restore")
    }

    // MARK: - scope commands (no layout; focused-pane commands only)

    func testScopeCommandsCapturesFocusedPaneCommandsAndCreatesNoTabs() {
        let fixture = twoTabSession() // focused pane = api.0
        let recipe = RecipeBuilder.snapshot(
            session: fixture.session, scope: .commands, name: "c", recentCommands: recentCommands(fixture),
        )
        XCTAssertEqual(recipe.scope, .commands)
        XCTAssertEqual(recipe.window.tabs.first?.panes.first?.commands, ["tail -F log/prod.log"])

        let plan = RecipeBuilder.restorePlan(recipe)
        XCTAssertEqual(plan.scope, .commands)
        XCTAssertTrue(plan.tabs.isEmpty, "a commands-only recipe creates no tabs")
        XCTAssertEqual(plan.commands, ["tail -F log/prod.log"], "the focused-pane commands inject into the live pane")
    }
}
