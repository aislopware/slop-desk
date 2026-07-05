import Foundation

// MARK: - SessionTemplateEngine (pure expand ↔ capture)

/// The PURE expansion of a ``SessionTemplate`` into a live ``Session`` (one tab carrying the template's
/// split tree, with fresh ``PaneID``s + seeded ``PaneSpec``s) plus the per-pane launch bytes, and the
/// inverse capture of a live ``Session``'s active-tab geometry back into a template. No store, no
/// transport, no view — so the whole expand/capture round-trip is unit-tested headless.
public enum SessionTemplateEngine {
    // MARK: Expand: template → session

    /// Builds a fresh ``Session`` named `name` from `template`: the template's ``TemplateNode`` layout
    /// becomes a single tab's ``SplitNode`` tree (every `.pane` mints a fresh ``PaneID`` + seeds a
    /// ``PaneSpec`` carrying the pane's kind/title; every `.split` mints a fresh ``SplitNodeID`` with
    /// EQUAL `.flex(1)` weights). The first leaf in DFS order is the active pane. Returns the session and
    /// an ORDERED list of `(PaneID, TemplatePane)` so the caller can send each pane's launch bytes once
    /// its PTY is live. The result holds the **specs == leafIDs invariant** (`specs.count == leafCount`).
    public static func makeSession(
        from template: SessionTemplate,
        name: String,
    ) -> (Session, [(PaneID, TemplatePane)]) {
        var specs: [PaneID: PaneSpec] = [:]
        var launches: [(PaneID, TemplatePane)] = []
        let root = build(template.layout, specs: &specs, launches: &launches)
        let activePane = root.allPaneIDs().first
        let tab = Tab(root: root, activePane: activePane)
        let session = Session(name: name, tabs: [tab], activeTabIndex: 0, specs: specs)
        return (session, launches)
    }

    /// Recursively materializes a ``TemplateNode`` into a ``SplitNode``, seeding `specs` (PaneID → spec)
    /// and appending each `.pane` to `launches` in DFS order. A `.split` maps each child to a
    /// `WeightedChild(weight: .flex(1), …)` — equal shares (a template encodes structure, not exact
    /// divider positions). The decode already capped depth ≤ ``SplitNode/maxDepth``, so the produced tree
    /// respects the tree's own depth bound.
    private static func build(
        _ node: TemplateNode,
        specs: inout [PaneID: PaneSpec],
        launches: inout [(PaneID, TemplatePane)],
    ) -> SplitNode {
        switch node {
        case let .pane(pane):
            let id = PaneID()
            specs[id] = PaneSpec(kind: pane.kind, title: pane.title, lastKnownCwd: pane.cwd)
            launches.append((id, pane))
            return .leaf(id)
        case let .split(axis, children):
            let weighted = children.map { child in
                WeightedChild(weight: .flex(1), node: build(child, specs: &specs, launches: &launches))
            }
            return .split(id: SplitNodeID(), axis: axis, children: weighted)
        }
    }

    // MARK: Capture: session → template

    /// Captures the active tab of `session` into a fresh user template named `name` with `symbol`. Walks
    /// the tab's ``SplitNode`` tree into a ``TemplateNode`` (`.leaf` → `.pane` carrying the spec's
    /// kind/title; `cwd`/`command` are `nil` — they live in the PTY, not the tree, so they cannot be
    /// recovered from a running session). `isBuiltIn` is `false`. A session with no active tab captures a
    /// single default terminal pane (never an empty layout).
    public static func captureTemplate(
        from session: Session,
        name: String,
        symbol: String,
    ) -> SessionTemplate {
        let layout: TemplateNode =
            if let tab = session.activeTab {
                capture(tab.root, specs: session.specs)
            } else {
                .pane(TemplatePane(title: "Terminal"))
            }
        return SessionTemplate(name: name, symbol: symbol, isBuiltIn: false, layout: layout)
    }

    /// Recursively walks a ``SplitNode`` into a ``TemplateNode`` against the session's `specs` side table:
    /// a `.leaf` becomes a `.pane` carrying that leaf's spec kind/title (a missing spec falls back to a
    /// default terminal pane — validate-then-repair); a `.split` recurses, preserving axis + child order.
    private static func capture(_ node: SplitNode, specs: [PaneID: PaneSpec]) -> TemplateNode {
        switch node {
        case let .leaf(id):
            let spec = specs[id] ?? PaneSpec(kind: .terminal, title: "Terminal")
            return .pane(TemplatePane(kind: spec.kind, title: spec.title))
        case let .split(_, axis, children):
            return .split(axis: axis, children: children.map { capture($0.node, specs: specs) })
        }
    }

    // MARK: Launch bytes

    /// The bytes to type into a freshly-spawned template pane once its PTY is live: a `cd <cwd>\n` (only
    /// for a non-empty cwd) followed by `<command>\n` (only for a non-empty command), or `nil` when BOTH
    /// are empty/nil (a true no-op — never a bare newline). REUSES ``LaunchPresetEngine/keystrokes(command:cwd:)``
    /// verbatim, so a template pane behaves IDENTICALLY to a launch preset: the cwd is emitted as a SAFE
    /// literal `cd` (never through `SendKeysParser`, so a `<Enter>`/quote in a path can't inject a command
    /// — see the engine's SECURITY note), while the command resolves `SendKeysParser` tokens.
    public static func launchBytes(cwd: String?, command: String?) -> [UInt8]? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Both empty ⇒ no-op (don't send a bare newline into the shell).
        if trimmedCwd?.isEmpty ?? true, trimmedCommand.isEmpty {
            return nil
        }
        let bytes = LaunchPresetEngine.keystrokes(command: command ?? "", cwd: cwd)
        return bytes.isEmpty ? nil : bytes
    }
}
