import Foundation

// MARK: - RecipeRestorePlan (the store's ordered create/split blueprint)

/// The resolved blueprint a recipe-open produces: the tabs to recreate (each a reconstructed split tree +
/// per-leaf resolved cwd / commands) plus, for a commands-only recipe, the commands to inject into the
/// already-focused pane. Pure value; the store (`WorkspaceStore+Recipes`) mounts the trees and feeds the
/// command lists to the ``RecipeReplayMachine``.
public struct RecipeRestorePlan: Equatable, Sendable {
    /// What the recipe restores: a single tab, a whole window, or commands-only.
    public var scope: RecipeScope
    /// The tabs to recreate (empty for a commands-only recipe).
    public var tabs: [RecipeRestoreTab]
    /// Commands to inject into the currently-focused pane — populated ONLY for ``RecipeScope/commands``
    /// (which creates no tabs / panes); empty for `tab` / `window`.
    public var commands: [String]

    public init(scope: RecipeScope, tabs: [RecipeRestoreTab] = [], commands: [String] = []) {
        self.scope = scope
        self.tabs = tabs
        self.commands = commands
    }
}

/// One reconstructed tab in a ``RecipeRestorePlan``: a display title, a freshly-minted split ``tree`` (leaf
/// ids minted on restore — a recipe carries no pane identity), and the per-leaf restore detail.
public struct RecipeRestoreTab: Equatable, Sendable {
    public var title: String
    /// The reconstructed tiled tree with FRESH leaf ids, split axes and relative sizes preserved.
    public var tree: SplitNode
    /// Per-leaf restore detail, keyed by the reconstructed leaf id in ``tree``.
    public var panes: [PaneID: RecipeRestorePane]

    public init(title: String, tree: SplitNode, panes: [PaneID: RecipeRestorePane]) {
        self.title = title
        self.tree = tree
        self.panes = panes
    }
}

/// The restore detail for one reconstructed pane: its RESOLVED working directory (portable templates
/// expanded) and the commands to replay (empty for a Layout-Only recipe).
public struct RecipeRestorePane: Equatable, Sendable {
    /// The resolved absolute working directory (``PortablePaths`` templates already expanded). `nil` =
    /// inherit the default.
    public var cwd: String?
    /// Commands to replay sequentially on open. Empty for Layout-Only.
    public var commands: [String]

    public init(cwd: String? = nil, commands: [String] = []) {
        self.cwd = cwd
        self.commands = commands
    }
}

// MARK: - RecipeBuilder (tree Session ⇄ Recipe)

/// The pure bidirectional bridge between the live tiled tree (``Session`` / ``Tab`` / ``SplitNode``) and a
/// portable ``Recipe``.
///
/// - ``snapshot(session:scope:name:recentCommands:portable:home:currentFolder:)`` DFS-flattens the split
///   tree into ordered ``RecipePane``s — each non-first pane carries the `split` direction + `size`
///   fraction derived from its ``WeightedChild/weight``, and the `cwd` comes from ``PaneSpec/lastKnownCwd``
///   (portabilized via ``PortablePaths`` when opted in). Include-Commands fills each pane's `commands` from
///   the per-pane recent-block list; Layout-Only leaves them empty.
/// - ``restorePlan(_:home:currentFolder:recipeLocation:)`` is the inverse: it resolves cwd templates and
///   reconstructs each tab's split tree by replaying the recorded relative splits (reusing
///   ``SplitNode/splitting(_:axis:inserting:before:)`` — the SAME tree-rewrite the store uses — so the
///   round-trip is faithful for the right/down-spine trees the otty save workflow produces).
///
/// **Exported recipes OMIT scrollback, machine-local keybindings, and agent sessions** — structurally, by
/// construction: ``RecipePane`` carries only `cwd` / `commands` / `split` / `size`, so none of those
/// per-pane runtime fields can leak into a recipe.
///
/// **Float math** follows the house idiom (CLAUDE.md §2): weight fractions use separate `*`/`/`/`+` (never
/// `addingProduct`/`fma`) and NaN-faithful ordered `Double.maximum`/`Double.minimum` (never a bare `<`/`>`
/// ternary). Wire posture: 100% client-side — nothing here touches the wire / golden corpus.
public enum RecipeBuilder {
    // MARK: Snapshot (Session → Recipe)

    /// Build a ``Recipe`` from the live `session`.
    ///
    /// - `scope`: `tab` = the focused tab only; `window` = every tab; `commands` = the focused pane's
    ///   recent commands only (no layout).
    /// - `name`: the recipe's display name (from the save sheet).
    /// - `recentCommands`: per-pane recent shell commands (oldest-first), keyed by ``PaneID``. Passing the
    ///   map = Include-Commands; passing `[:]` (the default) = Layout-Only (every pane's `commands` empty).
    /// - `portable`: when `true`, each pane's `cwd` is portabilized against `home` / `currentFolder` (the
    ///   recipe file location is not yet known at save, so `recipe_location` is not a save-time base).
    public static func snapshot(
        session: Session,
        scope: RecipeScope,
        name: String,
        recentCommands: [PaneID: [String]] = [:],
        portable: Bool = false,
        home: String = "",
        currentFolder: String = "",
    ) -> Recipe {
        switch scope {
        case .commands:
            // Commands-only: no layout. Capture the FOCUSED pane's recent commands.
            let focused = session.activeTab?.activePane
            let commands = focused.flatMap { recentCommands[$0] } ?? []
            let window = RecipeWindow(tabs: [RecipeTab(panes: [RecipePane(commands: commands)])])
            return Recipe(name: name, scope: .commands, window: window)
        case .tab:
            let tabs = (session.activeTab.map { [$0] } ?? []).map {
                snapshotTab(
                    $0,
                    specs: session.specs,
                    recentCommands: recentCommands,
                    portable: portable,
                    home: home,
                    currentFolder: currentFolder,
                )
            }
            return Recipe(name: name, scope: .tab, window: RecipeWindow(tabs: tabs))
        case .window:
            let tabs = session.tabs.map {
                snapshotTab(
                    $0,
                    specs: session.specs,
                    recentCommands: recentCommands,
                    portable: portable,
                    home: home,
                    currentFolder: currentFolder,
                )
            }
            return Recipe(name: name, scope: .window, window: RecipeWindow(tabs: tabs))
        }
    }

    /// DFS-flatten one tab's split tree into ordered ``RecipePane``s (the first pane has no `split`/`size`;
    /// each subsequent pane records the direction + fraction by which it splits the PREVIOUS pane).
    private static func snapshotTab(
        _ tab: Tab,
        specs: [PaneID: PaneSpec],
        recentCommands: [PaneID: [String]],
        portable: Bool,
        home: String,
        currentFolder: String,
    ) -> RecipeTab {
        let panes = flatten(
            tab.root, incomingSplit: nil, incomingSize: nil,
            specs: specs, recentCommands: recentCommands,
            portable: portable, home: home, currentFolder: currentFolder,
        )
        return RecipeTab(title: tab.title, panes: panes)
    }

    /// The recursive flatten. The FIRST child of a split inherits the incoming split/size (the edge that
    /// attached this whole subtree); every SUBSEQUENT child records THIS split's trailing direction
    /// (`.right` for `.horizontal`, `.down` for `.vertical`) and its own fraction of the split.
    private static func flatten(
        _ node: SplitNode,
        incomingSplit: RecipeSplit?,
        incomingSize: Double?,
        specs: [PaneID: PaneSpec],
        recentCommands: [PaneID: [String]],
        portable: Bool,
        home: String,
        currentFolder: String,
    ) -> [RecipePane] {
        switch node {
        case let .leaf(id):
            let spec = specs[id]
            let rawCwd = nonEmpty(spec?.lastKnownCwd)
            let cwd = rawCwd.map { portable
                ? PortablePaths.portabilize($0, home: home, currentFolder: currentFolder, recipeLocation: "")
                : $0
            }
            return [RecipePane(
                cwd: cwd,
                commands: recentCommands[id] ?? [],
                split: incomingSplit,
                size: incomingSize,
            )]
        case let .split(_, axis, children):
            var out: [RecipePane] = []
            for (index, child) in children.enumerated() {
                if index == 0 {
                    out += flatten(
                        child.node, incomingSplit: incomingSplit, incomingSize: incomingSize,
                        specs: specs, recentCommands: recentCommands,
                        portable: portable, home: home, currentFolder: currentFolder,
                    )
                } else {
                    let direction: RecipeSplit = axis == .horizontal ? .right : .down
                    let childFraction = fraction(of: child.weight, among: children)
                    out += flatten(
                        child.node, incomingSplit: direction, incomingSize: childFraction,
                        specs: specs, recentCommands: recentCommands,
                        portable: portable, home: home, currentFolder: currentFolder,
                    )
                }
            }
            return out
        }
    }

    // MARK: Restore plan (Recipe → ordered create/split blueprint)

    /// Resolve `recipe` into a ``RecipeRestorePlan`` the store replays: per-tab reconstructed trees (for
    /// `tab` / `window`) or the focused-pane command list (for `commands`). Pane cwds have their portable
    /// templates re-expanded against `home` / `currentFolder` / `recipeLocation`.
    public static func restorePlan(
        _ recipe: Recipe,
        home: String = "",
        currentFolder: String = "",
        recipeLocation: String = "",
    ) -> RecipeRestorePlan {
        switch recipe.scope {
        case .commands:
            let commands = recipe.window.tabs.first?.panes.first?.commands ?? []
            return RecipeRestorePlan(scope: .commands, tabs: [], commands: commands)
        case .tab,
             .window:
            let tabs = recipe.window.tabs.map {
                restoreTab($0, home: home, currentFolder: currentFolder, recipeLocation: recipeLocation)
            }
            return RecipeRestorePlan(scope: recipe.scope, tabs: tabs)
        }
    }

    /// Reconstruct one tab: mint fresh leaf ids, replay the recorded relative splits to rebuild the
    /// topology, then re-apply the recorded `size` fractions to the tree's weights, and resolve each pane's
    /// cwd template.
    private static func restoreTab(
        _ recipeTab: RecipeTab,
        home: String,
        currentFolder: String,
        recipeLocation: String,
    ) -> RecipeRestoreTab {
        let panes = recipeTab.panes
        guard !panes.isEmpty else {
            // A degenerate tab with no panes restores as a single fresh leaf (a tab is never empty).
            let id = PaneID()
            return RecipeRestoreTab(title: recipeTab.title, tree: .leaf(id), panes: [id: RecipeRestorePane()])
        }

        let ids = panes.map { _ in PaneID() }

        // 1. Topology: start at the first leaf, then split the PREVIOUS pane per the recorded direction.
        var tree = SplitNode.leaf(ids[0])
        for index in 1..<panes.count {
            let (axis, before) = axisAndSide(of: panes[index].split ?? .right)
            if let split = tree.splitting(ids[index - 1], axis: axis, inserting: ids[index], before: before) {
                tree = split
            } else if let fallback = tree.splitting(ids[0], axis: axis, inserting: ids[index], before: before) {
                // The previous pane was unexpectedly absent (hostile/odd file) — attach to the first leaf
                // instead of dropping the pane.
                tree = fallback
            }
        }

        // 2. Weights: re-apply each pane's recorded fraction (a subtree's fraction = the size recorded on
        // its first DFS leaf; the first child of every split takes the remainder).
        var sizeByLeaf: [PaneID: Double] = [:]
        for index in panes.indices where panes[index].size != nil {
            sizeByLeaf[ids[index]] = panes[index].size
        }
        tree = applyWeights(tree, sizeByLeaf: sizeByLeaf)

        // 3. Resolve cwd templates + carry commands.
        var detail: [PaneID: RecipeRestorePane] = [:]
        for (index, id) in ids.enumerated() {
            let pane = panes[index]
            let cwd = pane.cwd.map {
                PortablePaths.resolve($0, home: home, currentFolder: currentFolder, recipeLocation: recipeLocation)
            }
            detail[id] = RecipeRestorePane(cwd: cwd, commands: pane.commands)
        }
        return RecipeRestoreTab(title: recipeTab.title, tree: tree, panes: detail)
    }

    /// Re-weight every split from the recorded per-leaf sizes: the first child takes the remainder, each
    /// subsequent child takes the size recorded on its first DFS leaf (defaulting to an even share). Pure;
    /// all arithmetic is separate `*`/`/`/`+` with NaN-faithful ordered ``Double/maximum`` flooring.
    private static func applyWeights(_ node: SplitNode, sizeByLeaf: [PaneID: Double]) -> SplitNode {
        switch node {
        case .leaf:
            return node
        case let .split(id, axis, children):
            let rebuiltNodes = children.map { applyWeights($0.node, sizeByLeaf: sizeByLeaf) }
            let count = rebuiltNodes.count
            // A `.split` always has ≥ 2 children (tree invariant); guard anyway so a hand-built degenerate
            // node never traps on the `fractions[0]` write below.
            guard count > 0 else { return node }
            let even = 1.0 / Double(count)
            var fractions = [Double](repeating: even, count: count)
            var sumOthers = 0.0
            for index in 1..<count {
                let recorded = rebuiltNodes[index].firstLeafID.flatMap { sizeByLeaf[$0] }
                let childFraction = RecipePane.clampSize(recorded ?? even)
                fractions[index] = childFraction
                sumOthers += childFraction
            }
            // The first child takes whatever remains, floored at the per-pane minimum (NaN-faithful).
            fractions[0] = Double.maximum(SplitWeight.minWeight, 1.0 - sumOthers)
            let weighted = zip(fractions, rebuiltNodes).map { share, child in
                WeightedChild(weight: SplitWeight.flex(share).repaired(), node: child)
            }
            return .split(id: id, axis: axis, children: weighted)
        }
    }

    // MARK: Helpers

    /// The fraction of its split that `weight` represents (its magnitude over the sibling total). The total
    /// is floored at ``SplitWeight/minWeight`` (ordered max) so the division is never by zero / NaN, and the
    /// result is clamped to `0…1`.
    static func fraction(of weight: SplitWeight, among children: [WeightedChild]) -> Double {
        var total = 0.0
        for child in children { total += magnitude(child.weight) }
        let safeTotal = Double.maximum(total, SplitWeight.minWeight)
        return RecipePane.clampSize(magnitude(weight) / safeTotal)
    }

    /// A weight's finite, non-negative magnitude (after ``SplitWeight/repaired()`` removes NaN/inf/sub-floor
    /// values) — the `.flex` share or the `.fixed` extent.
    private static func magnitude(_ weight: SplitWeight) -> Double {
        switch weight.repaired() {
        case let .flex(value): value
        case let .fixed(value): value
        }
    }

    /// Map a recorded ``RecipeSplit`` direction to the tree ``SplitAxis`` + the leading/trailing insert side
    /// (`before == true` = the leading side). `right`/`left` form columns (`.horizontal`); `down`/`up` form
    /// rows (`.vertical`).
    private static func axisAndSide(of split: RecipeSplit) -> (axis: SplitAxis, before: Bool) {
        switch split {
        case .right: (.horizontal, false)
        case .left: (.horizontal, true)
        case .down: (.vertical, false)
        case .up: (.vertical, true)
        }
    }

    /// `s` trimmed; `nil` when empty/whitespace-only (so a blank `lastKnownCwd` becomes "inherit the
    /// default", not an empty cwd string).
    private static func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
