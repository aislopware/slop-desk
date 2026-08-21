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
    /// renders nothing, which is exactly what a client whose host refuses `channelClass 1` looks
    /// like.
    var canMutate: Bool { workspaceChannel?.isLive == true && mirroredTopology != nil }

    /// Asks the document for one change. `true` when it was staged and sent.
    ///
    /// A refusal is LOUD behind `SLOPDESK_WORKSPACE_DEBUG`, because the alternative is what it costs:
    /// a mutator that compiles, runs, changes nothing and logs nothing is indistinguishable from a UI
    /// that ignored the gesture, and there is no string to grep for.
    @discardableResult
    func stage(_ op: WorkspaceIntentOp, _ args: Data, intentID: UUID = UUID()) -> Bool {
        guard let workspaceChannel else {
            logIntentRefusal(op, "no workspace channel")
            onLayoutChangeUnavailable?()
            return false
        }
        let focusBefore = stagedFocusProbe()
        guard workspaceChannel.send(intent: op, args: args, intentID: intentID) else {
            let live = workspaceChannel.isLive
            let reachable = live && mirroredTopology != nil
            logIntentRefusal(op, live ? (reachable ? "refused locally" : "no topology") : "channel not live")
            // A refusal ON THE MERITS is the document doing its job (a re-tile of a lone leaf, a
            // reopen with an empty ring) and says nothing about reachability. Only the states where
            // NOTHING can land are worth telling the user about.
            if !reachable { onLayoutChangeUnavailable?() }
            return false
        }
        adoptStagedFocus(after: focusBefore)
        return true
    }

    /// The three focus facts an unfollowing device compares across one staged intent: where HOST TRUTH
    /// is looking, and which pane is active in the tab THIS DEVICE is looking at.
    ///
    /// Both halves are needed because the appliers move two different things. `spawnTab` /
    /// `reopenClosedTab` / `newSession` change the active tab; `splitPane` / `closePane` / `reattachPane`
    /// leave the active tab alone and focus a leaf inside whichever tab they touched — which, on an
    /// unfollowing device, is the device's tab and not the host's.
    private struct StagedFocusProbe {
        var hostTab: TabID?
        var hostPane: PaneID?
        /// The active pane of ``WorkspaceStore/deviceFocus``'s tab, or `nil` when that tab is not (or
        /// no longer) in the document.
        var ownTabPane: PaneID?
    }

    /// `nil` for a device that holds no overlay — a following one, or one that has not navigated. The
    /// projection already shows host truth there, so there is nothing to correct and no reason to pay
    /// for resolving the mirror twice per gesture.
    private func stagedFocusProbe() -> StagedFocusProbe? {
        guard let focus = deviceFocus, let tree = mirroredTopology?.tree else { return nil }
        let hostTab = tree.activeSession?.activeTab
        let ownTab = tree.sessions.compactMap { session in
            session.tabs.first { $0.id == focus.tab }
        }.first
        return StagedFocusProbe(
            hostTab: hostTab?.id, hostPane: hostTab?.activePane, ownTabPane: ownTab?.activePane,
        )
    }

    /// Moves an unfollowing device's own focus onto whatever the intent it just staged focused.
    ///
    /// The overlay is what lets a phone read one tab while the Studio works in another, and it has to
    /// survive every change that is not this device's doing. A change that IS its doing is the
    /// opposite case: the appliers land a new tab, a split's new leaf and a reopened tab FOCUSED, and
    /// an overlay still naming the old one undoes exactly that — ⌘T grows a rail row this device never
    /// switches to, and the pane the user just split keeps the keystrokes.
    ///
    /// Gated on focus having actually MOVED, so a divider drag, a rename or a badge write leaves the
    /// device looking exactly where it was. A device whose own tab went away with the change drops the
    /// overlay entirely rather than keeping a dead ``TabID`` — ⇧⌘T restores a tab under its ORIGINAL
    /// id, so a stale overlay would silently come back to life with it.
    private func adoptStagedFocus(after before: StagedFocusProbe?) {
        guard let before, let focus = deviceFocus, let topology = mirroredTopology,
              let after = stagedFocusProbe() else { return }
        if after.hostTab != before.hostTab || after.hostPane != before.hostPane {
            guard let tab = after.hostTab else { return }
            setDeviceFocus(DeviceFocus(tab: tab, pane: after.hostPane))
        } else if let pane = after.ownTabPane, pane != before.ownTabPane {
            setDeviceFocus(DeviceFocus(tab: focus.tab, pane: pane))
        } else if after.ownTabPane == nil,
                  !topology.tree.sessions.contains(where: { $0.tabs.contains { $0.id == focus.tab } })
        {
            setDeviceFocus(nil)
        }
    }

    /// Stages a close and raises the undo affordance iff a tab actually landed on the DOCUMENT's
    /// reopen ring.
    ///
    /// The ring is host-owned, so "did a tab go onto it" is a question about the document rather than
    /// something the client can decide from the shape it is closing: a pane that was one of several
    /// leaves takes no tab with it, and the applier is the thing that knows.
    ///
    /// Asked of the ring's NEWEST RECORD rather than its length. The applier trims to
    /// ``WorkspaceTopology/closedTabRingCap`` after appending, and the ring is persisted host-side and
    /// shared across clients — so a count reaches the cap and then never grows again, and every close
    /// from that moment on would lose its ⇧⌘T cue for good.
    @discardableResult
    func stageClose(_ op: WorkspaceIntentOp, _ args: Data) -> Bool {
        let before = mirroredTopology?.closedTabs.last?.tab.id
        guard stage(op, args) else { return false }
        let after = mirroredTopology?.closedTabs.last?.tab.id
        if let after, after != before { onTabCloseRecorded?() }
        return true
    }

    /// Uploads `topology` as this workspace's starting shape (op 0).
    ///
    /// Accepted only by a PRISTINE document — a host that already has a workspace answers
    /// `rejectedStale` and keeps it, because that tree is the only copy of a layout somebody built.
    ///
    /// A TOPOLOGY rather than a tree, because the tree is not the whole layout. `spawnCwd` says where
    /// each pane's shell is asked to start, and on a cold launch this client is the only thing that
    /// remembers it — the panes have no live shell to ask. Rebuilding the proposal from the tree alone
    /// defaults that map to `[:]`, so an ACCEPTED adopt would republish every pane with its project
    /// directory stripped and the next launch would start all of them in hostd's own cwd.
    ///
    /// `intentID` is the identity the optimistic patch stands under, so the launch dial hold can ask
    /// whether THIS proposal is still outstanding. It is the one op whose answer the client cannot
    /// predict, and therefore the one whose panes must not open a PTY until it lands.
    @discardableResult
    func stageAdopt(_ topology: WorkspaceTopology, intentID: UUID = UUID()) -> Bool {
        var state = HostWorkspaceState()
        state.write(topology: topology)
        return stage(.adoptWorkspace, WorkspaceStateCodec.encodeSnapshot(state), intentID: intentID)
    }

    /// Offers the layout THIS CLIENT restored at launch to a host that has never had one.
    ///
    /// Without it the upgrade path loses the workspace: the client restores its tabs and splits from
    /// `workspace.json`, the host's first run publishes its own single-pane default, and the
    /// projection simply becomes that — the user's layout discarded rather than uploaded, even though
    /// `documentIsPristine` means the host would have taken it.
    ///
    /// Fired once per launch, from ``attachWorkspaceChannel(_:)`` and the channel's own state changes.
    /// Gated on the mirror holding a REAL host document (an epoch other than
    /// ``WorkspaceStore/seedEpoch``): the seed IS this tree, so offering it back to an in-process
    /// document that already adopted it would spend the host's one pristine chance on a no-op.
    ///
    /// Staged OPTIMISTICALLY, exactly as the automation bootstrap's own op 0 is, and that is what
    /// keeps the restored panes alive. ``WorkspaceStore/reconcileTreeFromDocument()`` holds while this
    /// offer is outstanding, so the registry still holds the sessions the window dialled at launch;
    /// putting this tree straight back on top of host truth makes the reconcile that releases the hold
    /// a no-op. Proposing it silently instead leaves the host's first-run default as the thing to
    /// project for one turn — every restored terminal torn down and rebuilt a round trip later, and a
    /// shell spawned for the host's default pane and abandoned.
    ///
    /// A refusal reads the same as it always did: `rejectedStale` snaps the patch away, host truth
    /// stands, and only then do the restored panes go.
    ///
    /// The panes stay UNDIALLED across the whole round trip (``panesMayDial``). The optimistic patch
    /// puts the restored layout back on screen the instant the offer goes out, and that layout is a
    /// PREDICTION until the verdict lands — so opening a PTY for one of its panes is exactly the act
    /// that cannot be taken back: the host spawns a fresh shell for any session id it does not know,
    /// and a refusal then replaces every one of those panes with host truth.
    func runArmedLaunchAdoptIfPossible() {
        guard let topology = pendingLaunchAdopt, armedBootstrapEnvironment == nil, canMutate,
              workspaceMirror.knownEpoch != Self.seedEpoch else { return }
        pendingLaunchAdopt = nil
        // Claimed BEFORE the stage, and that ordering is load-bearing. Staging ANNOUNCES itself on the
        // mirror, and the mirror's change hook re-runs the dial gate — so an id recorded afterwards
        // would leave the gate reading "no offer outstanding" for exactly the turn in which the offer
        // became a prediction, and every restored pane would dial inside it. `beginPending` runs
        // before that announcement, so the id claimed here is already answerable when it fires.
        let intentID = UUID()
        launchAdoptIntentID = intentID
        if !stageAdopt(topology, intentID: intentID) { launchAdoptIntentID = nil }
        // That line released the hold, so the reconcile it was holding has to happen. Staging normally
        // performs it — every mirror write announces itself — but whether a given intent reaches the
        // mirror is the channel's business, and a proposal it refuses would otherwise leave the registry
        // holding panes the document does not have: leaves with no live session behind them. Asked for
        // here instead, where the hold is known to be over. The pass is idempotent.
        reconcileTreeFromDocument()
        // An offer that never went out (`nil` above) has no verdict to wait for, and one the loopback
        // seam answered on this very line is already decided — both open the dial gate right here.
        refreshPaneDialGate()
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

    /// `SLOPDESK_WORKSPACE_DEBUG` — `== "1"`, default-OFF, resolved once by ``DebugTrace``: the
    /// mutators run on every gesture and a per-call environment lookup is a syscall in a hot path.
    internal func logIntentRefusal(_ op: WorkspaceIntentOp, _ why: String) {
        DebugTrace.workspace.write("workspace intent \(op) dropped: \(why)")
    }
}
