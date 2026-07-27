import Foundation
import SlopDeskWorkspaceModel

// MARK: - WorkspaceStore × intents (the one road out of the store into the document)

/// Every layout change the store makes leaves through here (docs/45 §7.2).
///
/// The store renders ``WorkspaceStore/tree``, which is a PROJECTION of the workspace document — so a
/// mutator that assigned to it would be assigning to a computed property with nowhere to put the
/// value. What it does instead is ask: it stages an intent, the channel runs the host's own
/// ``WorkspaceIntentApplier`` to produce an optimistic patch, and the layout on screen moves in the
/// same frame the user asked for it.
///
/// The mutators keep their old shapes. `newTab(kind:)` still resolves the inherited cwd, still mints
/// the new ``PaneID`` (DECISIONS, Multi-client Phase 5 ruling 1 — a host-minted id would make every
/// split wait a round trip), still reconciles. What changed is the middle line.
public extension WorkspaceStore {
    /// Whether an intent can reach a document at all.
    ///
    /// `false` for a store with no channel (headless, a unit test that asked for none), for one whose
    /// channel is not yet `.live`, and for one whose host has not published a topology. In those
    /// states every mutator below is a silent no-op — and with no topology ``WorkspaceStore/tree``
    /// renders nothing, which is exactly what a default-ON client against a default-OFF host looks
    /// like.
    var canMutate: Bool { workspaceChannel?.isLive == true && workspaceMirror.topology != nil }

    /// Asks the document for one change. `true` when it was staged and sent.
    ///
    /// A refusal is LOUD behind `SLOPDESK_WORKSPACE_DEBUG`, because the alternative is what it costs:
    /// a mutator that compiles, runs, changes nothing and logs nothing is indistinguishable from a UI
    /// that ignored the gesture, and there is no string to grep for.
    @discardableResult
    func stage(_ op: WorkspaceIntentOp, _ args: Data) -> Bool {
        guard let workspaceChannel else {
            logIntentRefusal(op, "no workspace channel")
            return false
        }
        guard workspaceChannel.send(intent: op, args: args) else {
            logIntentRefusal(op, workspaceMirror.topology == nil ? "no topology" : "refused locally")
            return false
        }
        return true
    }

    /// Stages a close and raises the undo affordance iff the DOCUMENT's reopen ring actually grew.
    ///
    /// The ring is host-owned, so "did a tab go onto it" is a question about the document rather than
    /// something the client can decide from the shape it is closing: a pane that was one of several
    /// leaves takes no tab with it, and the applier is the thing that knows.
    @discardableResult
    func stageClose(_ op: WorkspaceIntentOp, _ args: Data) -> Bool {
        let before = workspaceMirror.topology?.closedTabs.count ?? 0
        guard stage(op, args) else { return false }
        if (workspaceMirror.topology?.closedTabs.count ?? 0) > before { onTabCloseRecorded?() }
        return true
    }

    /// Uploads `tree` as this workspace's starting shape (op 0).
    ///
    /// Accepted only by a PRISTINE document — a host that already has a workspace answers
    /// `rejectedStale` and keeps it, because that tree is the only copy of a layout somebody built.
    func stageAdopt(_ tree: TreeWorkspace) {
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: tree))
        stage(.adoptWorkspace, WorkspaceStateCodec.encodeSnapshot(state))
    }

    /// Runs an armed automation bootstrap now that there is a document to run it against. Fired from
    /// ``attachWorkspaceChannel(_:)`` and from the channel's own state changes; a no-op otherwise.
    func runArmedBootstrapIfPossible() {
        guard let env = armedBootstrapEnvironment, canMutate else { return }
        bootstrapFromEnvironment(env)
    }

    /// Stages the shape `next` gave the tab that holds `pane` (op 24).
    ///
    /// A re-tile is "this tab now has this shape", so what travels is the whole `layoutStructure` —
    /// the same grammar the document publishes, which is why the client can round-trip the layout it
    /// is looking at straight back as an intent. `false` when the tab is gone or the shape did not
    /// move, so a no-op re-tile costs nothing.
    @discardableResult
    func stageTabLayout(containing pane: PaneID, of next: TreeWorkspace) -> Bool {
        guard let (sIdx, tIdx) = WorkspaceTreeOps.locate(pane, in: next) else { return false }
        let tab = next.sessions[sIdx].tabs[tIdx]
        return stage(.setTabLayout, WorkspaceIntentArgs.encode(
            tab: tab.id, layout: WorkspaceTopology.layout(of: tab.root),
        ))
    }

    // MARK: - Argument helpers

    /// The leading child's resolved FLEX weight at `index` of `split`, or `nil` when that seam is
    /// absent or fixed-width. What the divider ops read back after the pure op has clamped.
    static func leadingWeight(splitID: SplitNodeID, index: Int, in tree: TreeWorkspace) -> Double? {
        for session in tree.sessions {
            for tab in session.tabs {
                if let weight = leadingWeight(splitID: splitID, index: index, in: tab.root) { return weight }
            }
        }
        return nil
    }

    private static func leadingWeight(splitID: SplitNodeID, index: Int, in node: SplitNode) -> Double? {
        guard case let .split(id, _, children) = node else { return nil }
        if id == splitID, children.indices.contains(index), case let .flex(weight) = children[index].weight {
            return weight
        }
        for child in children {
            if let found = leadingWeight(splitID: splitID, index: index, in: child.node) { return found }
        }
        return nil
    }

    /// The pane a directional MOVE exchanged `active` with: the one leaf whose position in the tab
    /// changed places with it. `nil` when the op found no neighbour and returned the tree untouched.
    static func swapPartner(of active: PaneID, before: TreeWorkspace, after: TreeWorkspace) -> PaneID? {
        guard let (sIdx, tIdx) = WorkspaceTreeOps.locate(active, in: before),
              let (nsIdx, ntIdx) = WorkspaceTreeOps.locate(active, in: after),
              before.sessions[sIdx].tabs[tIdx].id == after.sessions[nsIdx].tabs[ntIdx].id
        else { return nil }
        let oldOrder = before.sessions[sIdx].tabs[tIdx].allPaneIDs()
        let newOrder = after.sessions[nsIdx].tabs[ntIdx].allPaneIDs()
        guard let from = oldOrder.firstIndex(of: active), let to = newOrder.firstIndex(of: active),
              from != to, newOrder.indices.contains(from)
        else { return nil }
        // A swap exchanges exactly two positions, so whoever now stands where `active` stood IS the
        // partner. Anything else means the op did something other than a swap and is refused.
        let partner = newOrder[from]
        guard partner != active, oldOrder.count == newOrder.count, oldOrder[to] == partner else { return nil }
        return partner
    }

    /// The one `splitNode/weight` a structural resize changed, or `nil` when nothing moved.
    static func changedDividerWeight(
        before: TreeWorkspace, after: TreeWorkspace,
    ) -> (split: SplitNodeID, index: Int, weight: Double)? {
        var old: [SplitNodeID: [Double?]] = [:]
        for session in before.sessions { for tab in session.tabs { collectWeights(tab.root, into: &old) } }
        var new: [SplitNodeID: [Double?]] = [:]
        for session in after.sessions { for tab in session.tabs { collectWeights(tab.root, into: &new) } }
        for (id, weights) in new {
            guard let previous = old[id], previous.count == weights.count else { continue }
            for index in weights.indices where previous[index] != weights[index] {
                guard let weight = weights[index] else { continue }
                return (id, index, weight)
            }
        }
        return nil
    }

    private static func collectWeights(_ node: SplitNode, into out: inout [SplitNodeID: [Double?]]) {
        guard case let .split(id, _, children) = node else { return }
        out[id] = children.map { child in
            guard case let .flex(weight) = child.weight else { return nil }
            return weight
        }
        for child in children { collectWeights(child.node, into: &out) }
    }

    /// The pane every "do this to the focused thing" intent names.
    var activeTreePane: PaneID? { tree.activeSession?.activeTab?.activePane }

    /// The tab every tab-scoped intent names.
    var activeTreeTab: TabID? { tree.activeSession?.activeTab?.id }

    internal func logIntentRefusal(_ op: WorkspaceIntentOp, _ why: String) {
        guard Self.isWorkspaceDebugEnabled else { return }
        FileHandle.standardError.write(Data("workspace intent \(op) dropped: \(why)\n".utf8))
    }

    /// `SLOPDESK_WORKSPACE_DEBUG` — `== "1"`, default-OFF. Resolved once: the mutators run on every
    /// gesture and a per-call environment lookup is a syscall in a hot path.
    internal static let isWorkspaceDebugEnabled =
        ProcessInfo.processInfo.environment["SLOPDESK_WORKSPACE_DEBUG"] == "1"
}
