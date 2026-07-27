import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel

/// The host's single copy of the workspace, and the SINGLE SERIALIZATION POINT for every write to it.
///
/// The bug this exists to end is not a persistence bug. The host already derives every per-pane fact
/// with a stateful parser — it just publishes each one as an EDGE (types 21/23/26/27/32/33/34/36) and
/// keeps no current value anywhere a client can ask for. A client that was not listening at the
/// instant of the edge loses the fact permanently and has no way to request it. Retaining the facts
/// as one versioned value, and letting any client ask for it at any time, is the whole design.
///
/// **Every mutation runs on this actor**, so `stateNum` is monotone by construction and there is no
/// merge function anywhere: the last write to a `(kind, objectID, field)` cell wins by ARRIVAL here.
/// That is Figma's model, and the reason a CRDT is not warranted — the precedent is Zed, which uses
/// CRDTs for text buffers and host-authoritative RPC for the worktree tree. This is the worktree tree.
///
/// **The `epoch` is minted per hostd start and is not optional.** Without it a restarted daemon counts
/// `stateNum` back up from zero and a returning client sitting one behind accepts a delta computed
/// against a completely different document — divergence that is permanent, silent, and has no
/// detector. The epoch is also the no-migration directive expressed on the wire: a foreign epoch
/// means reset-then-snapshot, which is the same code path as a missed frame and as a four-hour
/// reconnect.
public actor HostWorkspaceDocument {
    /// Identity of THIS document instance. A new one on every host start, and on any non-recoverable
    /// rebuild.
    public let epoch: UUID

    /// Monotone, and bumped ONLY when the state actually changed. Every bump costs every subscriber a
    /// frame, so a no-op recapture must never move it — an idle host has to be silent.
    ///
    /// Starts at **1**, never 0. Zero is the "I know nothing" sentinel a client sends in `subscribe`
    /// and the base every snapshot declares; if the host could also legitimately BE at 0, a client
    /// that had genuinely received and acked the empty opening document would be indistinguishable
    /// from one that had never connected — and the host would keep re-snapshotting it forever.
    public private(set) var stateNum: Int64 = 1

    private var state: HostWorkspaceState
    private var subscribers: [UUID: WorkspaceChannelSession] = [:]
    private let onLog: (@Sendable (String) -> Void)?

    /// Called with the whole document whenever its TOPOLOGY half changed — the persistence sink.
    ///
    /// Only the topology half, because liveness does not survive a restart and offering it would
    /// rewrite the same filtered bytes on every reconciler tick for a host nobody is even using.
    private var onTopologyChange: (@Sendable (HostWorkspaceState) -> Void)?

    /// Where the roster's pane half comes from: the resolved grid and the attachments for every pane
    /// the SERVER owns.
    ///
    /// A source rather than a stored value because it is derived from live sessions, and a copy kept
    /// here would be one more thing that can go stale. `nil` (no server wired in) publishes no panes,
    /// which is the honest answer for a document nobody has given an inventory to.
    private var paneRoster: (@Sendable () -> [WorkspaceRosterPane])?

    /// Whether this document is still exactly what the host minted for a first run.
    ///
    /// Read by one thing only: `adoptWorkspace`, the legacy bootstrap. A client may upload its local
    /// tree to a host that has never had one, and to no other kind of host — which makes this the
    /// difference between importing somebody's layout and destroying it.
    public private(set) var isPristine = true

    @preconcurrency
    public init(
        epoch: UUID = UUID(),
        state: HostWorkspaceState = HostWorkspaceState(),
        onLog: (@Sendable (String) -> Void)? = nil,
    ) {
        self.epoch = epoch
        self.state = state
        self.onLog = onLog
    }

    /// Installs the workspace this host starts with — restored from disk, or freshly minted.
    ///
    /// `pristine` says which. A restored document has a workspace somebody built and must refuse an
    /// upload; a minted one is the only kind that may accept one.
    ///
    /// No version bump: this runs before any subscriber exists, and a bump would only make the first
    /// snapshot claim to be the second.
    @preconcurrency
    public func install(
        state restored: HostWorkspaceState,
        pristine: Bool,
        onTopologyChange sink: (@Sendable (HostWorkspaceState) -> Void)? = nil,
    ) {
        state = restored
        isPristine = pristine
        onTopologyChange = sink
    }

    /// The topology half as a value, or `nil` before one is installed.
    public var topology: WorkspaceTopology? { state.topology }

    /// The document as a value. Read-only; the only way to change it is through this actor.
    public var snapshot: HostWorkspaceState { state }

    public var subscriberCount: Int { subscribers.count }

    // MARK: - Mutation

    /// Applies an arbitrary edit and broadcasts iff it changed anything.
    ///
    /// The change test is on the VALUE, not on whether the closure ran: `HostWorkspaceState` is
    /// `Equatable` precisely so a caller cannot accidentally version a no-op.
    @discardableResult
    public func mutate(_ body: (inout HostWorkspaceState) -> Void) -> Bool {
        var next = state
        body(&next)
        guard next != state else { return false }
        state = next
        bump()
        return true
    }

    /// Replaces one pane's liveness fields, leaving its topology fields untouched.
    @discardableResult
    public func merge(paneLiveness record: PaneLiveness) -> Bool {
        mutate { $0.merge(paneLiveness: record) }
    }

    /// Replaces the liveness half of EVERY pane in one version bump.
    ///
    /// The reconciler's entry point: it captures every live pane and hands the whole set over, so a
    /// tick that observed three changed panes costs one `stateNum`, not three. Panes present in the
    /// document but absent from `records` are left alone — reaping is ``reconcile(captured:)``, a
    /// separate decision with a separate failure mode.
    @discardableResult
    public func merge(paneLiveness records: [PaneLiveness]) -> Bool {
        mutate { next in
            for record in records { next.merge(paneLiveness: record) }
        }
    }

    /// One reconciler pass: fold in what was captured, and decide what the rest of the panes are.
    ///
    /// The decision the naive "reap what was not captured" rule gets wrong once topology lives here.
    /// A pane the host restored from disk has no process — that is the whole point of a restart — but
    /// it is still a REAL pane in a REAL tab, and deleting it would erase the user's layout every
    /// time hostd restarted. So:
    ///
    /// - captured → its liveness is whatever the capture says;
    /// - in the topology but not captured → `liveness = 2`, rendered STALE rather than fake-live, and
    ///   keeping the two fields that describe a PLACE rather than a process;
    /// - neither → reaped, because nothing owns it. That is a pane whose channel closed and whose tab
    ///   entry is gone, which is the case the old rule was actually for.
    @discardableResult
    public func reconcile(captured records: [PaneLiveness]) -> Bool {
        mutate { next in
            for record in records { next.merge(paneLiveness: record) }
            let alive = Set(records.map(\.paneID))
            let topologyPanes = Set(
                next.entries.keys
                    .filter {
                        $0.kind == WorkspaceObjectKind.pane.rawValue
                            && PaneLiveness.topologyFields().contains($0.field)
                    }
                    .map(\.objectID),
            )
            let known = Set(
                next.entries.keys
                    .filter { $0.kind == WorkspaceObjectKind.pane.rawValue }
                    .map(\.objectID),
            )
            for paneID in known.subtracting(alive) {
                guard topologyPanes.contains(paneID) else {
                    next.removeObject(kind: WorkspaceObjectKind.pane.rawValue, objectID: paneID)
                    continue
                }
                next.markPaneDead(paneID)
            }
        }
    }

    /// Marks one pane as having no process — `DetachedSessionStore`'s eviction hook.
    ///
    /// Without it the document goes semantically stale with no signal: the store kills a session
    /// behind the document's back, and every client keeps rendering a live row for a shell that was
    /// reaped on a TTL.
    @discardableResult
    public func markPaneDead(_ paneID: UUID) -> Bool {
        mutate { $0.markPaneDead(paneID) }
    }

    // MARK: - Intents

    /// Applies one client's requested topology change.
    ///
    /// The decision itself is `WorkspaceIntentApplier` — pure, and the same function the client runs
    /// for its optimistic overlay. What happens HERE is the part that cannot be pure: the actor
    /// serializes it, so `stateNum` is monotone by construction and two clients racing the same cell
    /// resolve by arrival order rather than by a merge function nobody can reason about.
    public func apply(intent op: UInt8, args: Data) -> WorkspaceIntentStatus {
        guard let current = state.topology else {
            // No workspace to change. A client that got this far has a document; one that has not
            // will be snapshotted the moment there is one.
            return .rejectedNotFound
        }
        let outcome = WorkspaceIntentApplier.apply(
            op: op, args: args, to: current, documentIsPristine: isPristine,
            projectKey: { [state] in state.projectKey(forPane: $0) },
        )
        guard let next = outcome.topology else { return Self.status(for: outcome) }
        // The bootstrap is the one op that may not run twice, so ANY accepted intent ends pristine —
        // including one that changed nothing. A client that renamed a tab to its own name has still
        // taken ownership of this workspace.
        isPristine = false
        mutate { $0.write(topology: next) }
        onTopologyChange?(state)
        return .applied
    }

    private static func status(for outcome: WorkspaceIntentOutcome) -> WorkspaceIntentStatus {
        switch outcome {
        case .applied: .applied
        case .rejectedStale: .rejectedStale
        case .rejectedInvalid: .rejectedInvalid
        case .rejectedNotFound: .rejectedNotFound
        case .unknownOp: .unknownOp
        }
    }

    /// Deletes a pane OBJECT — every field, topology included.
    @discardableResult
    public func removePane(_ paneID: UUID) -> Bool {
        mutate { $0.removeObject(kind: WorkspaceObjectKind.pane.rawValue, objectID: paneID) }
    }

    /// Reaps every pane object the host no longer knows about.
    ///
    /// A pane that vanished without a close — a child that exited, a detached session the store
    /// evicted — otherwise lingers in the document forever, and every client keeps rendering a row
    /// for a process that does not exist.
    @discardableResult
    public func removePanes(keeping live: Set<UUID>) -> Bool {
        let stale = Set(
            state.entries.keys
                .filter { $0.kind == WorkspaceObjectKind.pane.rawValue }
                .map(\.objectID),
        ).subtracting(live)
        guard !stale.isEmpty else { return false }
        return mutate { next in
            for paneID in stale { next.removeObject(kind: WorkspaceObjectKind.pane.rawValue, objectID: paneID) }
        }
    }

    /// Publishes a project's git summary — the type-35 body verbatim.
    ///
    /// Keyed by PROJECT, not by pane: the summary is a property of the repository, and a pane-keyed
    /// copy would be N copies of one fact that can disagree. Without this a never-seen-this-host
    /// client renders no git line at all until the first FSEvents edge happens to fire.
    @discardableResult
    public func setProject(id: UUID, key: String, gitSummary: Data?) -> Bool {
        mutate { next in
            next.set(
                WorkspaceKey(.project, id, WorkspaceProjectField.key),
                WorkspaceStateCodec.encodeString(key),
            )
            next[WorkspaceKey(.project, id, WorkspaceProjectField.gitSummary)] = gitSummary
        }
    }

    private func bump() {
        stateNum &+= 1
        broadcast()
    }

    private func broadcast() {
        for session in subscribers.values {
            session.deliver(epoch: epoch, stateNum: stateNum, state: state)
        }
    }

    // MARK: - Subscribers

    /// Registers a subscriber and immediately offers it the current document.
    ///
    /// The offer is unconditional: a subscriber that has never seen this host needs a snapshot, and
    /// one that HAS gets an empty diff it never sends. Deciding here would duplicate the reasoning
    /// that already lives, correctly, in the session.
    func addSubscriber(_ session: WorkspaceChannelSession) {
        subscribers[session.id] = session
        session.start()
        session.deliver(epoch: epoch, stateNum: stateNum, state: state)
        broadcastRoster()
    }

    public func removeSubscriber(id: UUID) {
        guard let session = subscribers.removeValue(forKey: id) else { return }
        session.close()
        // The null broadcast when the last one leaves is deliberate: a roster that simply stops
        // arriving is indistinguishable from a stalled host, and every remaining client would keep
        // rendering a viewer who is gone.
        broadcastRoster()
    }

    public func handle(ack stateNum: Int64, from subscriberID: UUID) {
        subscribers[subscriberID]?.note(ack: stateNum)
    }

    /// A repeat `subscribe` IS the resync verb.
    public func handle(resubscribe request: WorkspaceSubscribe, from subscriberID: UUID) {
        guard let session = subscribers[subscriberID] else { return }
        session.note(resubscribe: request)
        session.deliver(epoch: epoch, stateNum: stateNum, state: state)
        broadcastRoster()
    }

    /// Rebuilds the roster and fans it to everyone.
    ///
    /// Presence never touches `stateNum`: a kind-2 frame that advanced it would make the host retire,
    /// via `assumedAcked`, a diff it never sent — permanent silent divergence on the very first
    /// rename. Presence is derived, TTL-expired and never persisted, so it is broadcast whole.
    public func broadcastRoster() {
        let roster = WorkspacePresenceRoster(
            clients: subscribers.values
                .map { $0.rosterRecord() }
                .sorted { $0.clientInstanceID.uuidString < $1.clientInstanceID.uuidString },
            // The RESOLVED grid and its contributors, so a client that is not driving the size can
            // render a labelled letterbox — "120×40 · sized by MacBook Pro" — instead of guessing.
            panes: paneRoster?() ?? [],
        )
        for session in subscribers.values { session.deliver(roster: roster) }
    }

    /// Wires the pane inventory the roster publishes. Separate from ``install(state:pristine:onTopologyChange:)``
    /// because it comes from the SERVER's session maps rather than from disk.
    @preconcurrency
    public func setPaneRoster(_ source: (@Sendable () -> [WorkspaceRosterPane])?) {
        paneRoster = source
    }

    /// Tears every subscriber down — daemon shutdown.
    public func shutdown() {
        for session in subscribers.values { session.close() }
        subscribers.removeAll()
    }
}
