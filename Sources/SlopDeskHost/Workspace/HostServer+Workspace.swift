import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel

// The workspace-document channel (`channelClass == 1`, docs/45 §5.1) — accept, serve, reconcile,
// and apply what clients ask for.
//
// The traffic is asymmetric on purpose. The host publishes a whole document and diffs against what
// each subscriber acked; a client sends only INTENTS — never state — so there is exactly one place
// the topology changes and no merge function anywhere.
extension HostServer {
    // MARK: - Bootstrap

    /// Gives the document the workspace this host starts with, and wires it to disk.
    ///
    /// Runs from `start()`, before the listener can accept anything — a subscriber that arrived first
    /// would be snapshotted an empty document and then immediately re-snapshotted, which is harmless
    /// but makes the very first frame a lie.
    ///
    /// With no store (Application Support unresolvable), the host still serves a workspace: it mints
    /// a fresh default each start. Degraded, not broken — and `pristine` stays true, so a client can
    /// still upload the layout it has.
    func installWorkspaceDocument() async {
        guard let document = workspaceDocument else { return }
        guard let store = workspaceStore else {
            var minted = HostWorkspaceState()
            minted.write(topology: WorkspaceTopology(
                tree: .defaultWorkspace(),
                hostDisplayName: HostWorkspaceStore.hostDisplayName(),
            ))
            await document.install(state: minted, pristine: true)
            return
        }
        // Asked BEFORE the load, which mints a default when there is nothing to restore and so can
        // no longer tell the two apart afterwards.
        let hadWorkspace = await store.hasStoredWorkspace
        let restored = await store.load()
        await document.install(state: restored, pristine: !hadWorkspace) { [weak store] state in
            guard let store else { return }
            Task { await store.scheduleSave(state) }
        }
    }

    // MARK: - Accept

    /// Handles a `channelOpen` whose class is ``MuxChannelClass/workspace``.
    ///
    /// Only the CONTROL sub-channel is used; the DATA sub-channel `openChannel` also creates stays
    /// idle. That asymmetry is deliberate — the document is small, latency-sensitive control traffic,
    /// and CONTROL is unwindowed, so a workspace frame can never be stalled behind a PTY output flood
    /// waiting on flow-control credit.
    func openWorkspaceChannel(_ open: MuxChannelOpen, on connection: MuxNWConnection, connectionID: UUID) {
        guard let document = workspaceDocument else {
            // Flag off. Refuse rather than accept-and-say-nothing: a client that knows about the
            // channel needs to learn immediately that this host does not serve it, so it can fall
            // back to the edge sinks instead of waiting forever for a snapshot.
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        guard workspaceChannel(for: connectionID) == nil else {
            // Two subscribers behind one link would each keep their own acked base for the same
            // viewer, and the roster would show one device twice.
            onLog?("workspace channel \(open.channelID) (conn \(connectionID)): refused — already open")
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        Task { await connection.sendOpenAck(open.channelID, accepted: true) }
        startWorkspaceReceiveLoop(open: open, connectionID: connectionID, document: document)
        onLog?("workspace channel \(open.channelID) (conn \(connectionID)) accepted")
    }

    /// Drains type-17 requests off the control sub-channel until the link dies.
    ///
    /// A malformed body is DROPPED and the loop continues. Tearing the channel down on one bad frame
    /// would hand a peer a trivial way to blank every other client's workspace, and these bytes carry
    /// no authentication of any kind — security is the WireGuard mesh, not this layer.
    private func startWorkspaceReceiveLoop(
        open: MuxChannelOpen,
        connectionID: UUID,
        document: HostWorkspaceDocument,
    ) {
        let control = open.control
        Task { [weak self] in
            do {
                for try await message in control.inbound {
                    guard case let .workspaceRequest(_, verb, payload) = message else { continue }
                    guard let self else { return }
                    await handleWorkspaceRequest(
                        verb: verb,
                        payload: payload,
                        control: control,
                        connectionID: connectionID,
                        document: document,
                    )
                }
            } catch {
                self?.onLog?("workspace channel (conn \(connectionID)): receive ended (\(error))")
            }
            // Clean close OR error: either way the subscriber is gone.
            self?.dropWorkspaceSubscriber(connectionID: connectionID)
        }
    }

    private func handleWorkspaceRequest(
        verb: UInt8,
        payload: Data,
        control: any MessageChannel,
        connectionID: UUID,
        document: HostWorkspaceDocument,
    ) async {
        switch WorkspaceRequestVerb(rawValue: verb) {
        case .subscribe:
            guard let request = try? WorkspaceSubscribe.decode(payload) else {
                onLog?("workspace channel (conn \(connectionID)): malformed subscribe dropped")
                return
            }
            await applyWorkspaceSubscribe(request, control: control, connectionID: connectionID, document: document)

        case .ack:
            // `[i64 BE stateNum]`, and nothing else — a body of any other length is a framing bug,
            // not a value to salvage.
            guard payload.count == 8, let stateNum = WorkspaceStateCodec.decodeI64(payload) else { return }
            guard let session = workspaceChannel(for: connectionID) else { return }
            await document.handle(ack: stateNum, from: session.id)

        case .presence:
            guard let update = try? WorkspacePresenceUpdate.decode(payload) else { return }
            guard let session = workspaceChannel(for: connectionID) else { return }
            // An older clock is IGNORED, never merged: a client reconnecting with a stale clock must
            // not resurrect a view it has since left.
            guard session.note(presence: update) else { return }
            await document.broadcastRoster()

        case .intent:
            // A malformed envelope is dropped in silence — there is no `intentID` to answer to. Every
            // DECODABLE intent gets a definite answer, including a refusal, so a client's optimistic
            // patch is rolled back at once instead of waiting out a timeout.
            guard let intent = try? WorkspaceIntent.decode(payload) else { return }
            guard let session = workspaceChannel(for: connectionID) else { return }
            let status = await document.apply(intent: intent.op, args: intent.args)
            session.deliver(result: WorkspaceIntentResult(intentID: intent.intentID, status: status))
            if status == .applied {
                // The topology moved, so the pane inventory may have too — a close reaps, a spawn
                // wants its liveness published before the client's optimistic patch retires.
                await reconcileWorkspaceDocument()
            }

        case nil:
            onLog?("workspace channel (conn \(connectionID)): unknown verb \(verb) dropped")
        }
    }

    private func applyWorkspaceSubscribe(
        _ request: WorkspaceSubscribe,
        control: any MessageChannel,
        connectionID: UUID,
        document: HostWorkspaceDocument,
    ) async {
        let log = onLog
        let created = registerWorkspaceChannel(connectionID: connectionID) {
            WorkspaceChannelSession(channel: control, subscribe: request, onLog: log)
        }
        if let created {
            await document.addSubscriber(created)
            // First subscribe: publish what is true RIGHT NOW rather than waiting up to a tick for
            // the reconciler. A client that has just connected is precisely the one with nothing.
            await reconcileWorkspaceDocument()
        } else if let existing = workspaceChannel(for: connectionID) {
            // A repeat subscribe IS the resync verb.
            await document.handle(resubscribe: request, from: existing.id)
        }
    }

    private func dropWorkspaceSubscriber(connectionID: UUID) {
        guard let session = unregisterWorkspaceChannel(connectionID: connectionID),
              let document = workspaceDocument else { return }
        Task { await document.removeSubscriber(id: session.id) }
    }

    // MARK: - Reconcile

    /// Nudges a reconcile from an event site, without awaiting it.
    ///
    /// Depth-1: a kick arriving while a pass runs sets a flag rather than stacking another pass. The
    /// pass itself is idempotent and an unchanged capture produces no version bump, so a redundant
    /// kick costs a few lock acquisitions and nothing on the wire.
    func kickWorkspaceReconcile() {
        guard workspaceDocEnabled, !workspaceReconcileIsRunning() else { return }
        Task { [weak self] in await self?.reconcileWorkspaceDocument() }
    }

    /// Re-captures every pane the host knows about and folds the result into the document.
    ///
    /// Deliberately a full sweep rather than a per-fact push. The facts arrive from at least five
    /// independent producers (the sniffer's read-loop thread, the foreground poll task, the hook
    /// socket, the blocks segmenter, the project-key resolver), and wiring each one separately is
    /// how a fact goes missing — which is the bug this document exists to end. A sweep is correct
    /// by construction and, because `merge` reports whether anything changed and `stateNum` only
    /// moves when it did, an idle host stays completely silent.
    func reconcileWorkspaceDocument() async {
        guard let document = workspaceDocument else { return }
        // No audience, no work: a wall of detached agents must not keep capturing for nobody.
        guard await document.subscriberCount > 0 else { return }

        guard beginWorkspaceReconcile() else { return }
        defer { finishWorkspaceReconcile() }

        // One pass decides all three cases: captured panes get their liveness, panes the topology
        // still names but nothing captured go STALE rather than being deleted (that is every pane on
        // a host that just restarted), and panes nothing owns at all are reaped.
        await document.reconcile(captured: captureWorkspacePanes())
    }

    private func finishWorkspaceReconcile() {
        guard endWorkspaceReconcile() else { return }
        Task { [weak self] in await self?.reconcileWorkspaceDocument() }
    }

    /// One capture of every pane, from all three inventories.
    ///
    /// The three are disjoint by construction — `detachMuxSession` removes from `muxSessions` before
    /// inserting into the store, and `claim` removes before the reattach re-registers — the same
    /// argument `listPanesForControl()` relies on.
    private func captureWorkspacePanes() -> [PaneLiveness] {
        let (attached, unattached) = paneSessionsForWorkspace()
        var records: [PaneLiveness] = []
        records.reserveCapacity(attached.count + unattached.count)
        for session in attached {
            records.append(.capture(from: session, liveness: session.isChildExited() ? .dead : .attached))
        }
        // A ctl-spawned or detached pane is a real PTY with NO client — `detached` in exactly the
        // sense the client renders: live, running, nobody watching. Calling it `attached` would
        // claim a viewer that does not exist.
        for session in unattached {
            records.append(.capture(from: session, liveness: session.isChildExited() ? .dead : .detached))
        }
        return records
    }

    // MARK: - Test seams

    func reconcileWorkspaceDocumentForTesting() async {
        await reconcileWorkspaceDocument()
    }

    func installWorkspaceDocumentForTesting() async {
        await installWorkspaceDocument()
    }
}
