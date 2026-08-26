import CSlopDeskFFI
import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel

/// One subscribed connection's view of the workspace document.
///
/// The LADDER — what this subscriber may be sent next, against which base, and which retained
/// states are still worth keeping — is `rust/slopdesk-workspace`'s `sync_ladder`, reached through
/// the `sync_ladder` door. What is HERE is what cannot cross: the channel, the send `Task`, the
/// depth-1 pending slot, and the document BYTES, which are filed under the slot the ladder mints
/// for each state it retains.
///
/// **The send queue is depth-1 and COALESCING, and it is never `enqueueControl`.**
/// `MuxChannelSession.enqueueControl` sheds NEW messages past `maxControlOutQueued = 1024`; a shed
/// snapshot would leave a client pinned at `stateNum 0` with no retry trigger anywhere — a silent,
/// permanent blank workspace. Here a pending update is DISCARDED AND RECOMPUTED, never queued, so
/// host memory is O(clients × state) no matter how slow a client is. A sleeping iPhone is free.
///
/// **Every diff is computed from the ACKED base, never the last SENT base** (docs/45 §5.5, mosh
/// SSP). Because a diff assigns rather than mutates, `apply(d, apply(d, s)) == apply(d, s)` holds by
/// construction — duplicates and reorders are no-ops with no extra machinery — and a client four
/// hours offline costs exactly one diff, bounded by the SIZE of the tree rather than the DURATION of
/// its absence. There is no retransmit path on either side, and none is needed: this rides the mux
/// CONTROL sub-channel, which is TCP and unwindowed, so delivery is reliable and in-order. A link
/// that dies takes the channel with it and the client resubscribes.
///
/// **One lock, and the ladder is under it.** ``lock`` already guarded the inbox, the presence record
/// and the roster projection; the ladder half was single-threaded by convention rather than by a
/// lock, reachable only from the one send task. Both are now under `lock`, which is a leaf — nothing
/// nests beneath it — and no door call spans an `await`, which is exactly why the far side splits
/// its decision into `plan` and `commit`.
final class WorkspaceChannelSession: @unchecked Sendable {
    /// Identity of this SUBSCRIBER — one per workspace channel, minted by the host.
    let id: UUID

    /// The client's own identity from `subscribe`. Presence is keyed by this, not by ``id``: two
    /// windows of one app are two connections and two identities, exactly as intended.
    private(set) var clientInstanceID: UUID
    private(set) var clientKind: UInt8
    private(set) var label: String

    private let channel: any MessageChannel
    private let onLog: (@Sendable (String) -> Void)?

    // MARK: State — all of it guarded by `lock`

    private let lock = NSLock()
    /// The far side, which owns the epoch, the acked base, the retention window and the presence
    /// clock. Serialized by ``lock``; no call on it can suspend.
    private let ladder: OpaquePointer?
    /// The document bytes the ladder retains, keyed by the slot it minted for each. Every call that
    /// releases slots deletes exactly those entries — a slot never released is a leaked document.
    private var retainedStates: [UInt32: HostWorkspaceState] = [:]
    private var pendingState: (epoch: UUID, stateNum: Int64, state: HostWorkspaceState)?
    private var pendingRoster: WorkspacePresenceRoster?
    private var pendingSubscribe: WorkspaceSubscribe?
    private var pendingResults: [WorkspaceIntentResult] = []
    private var closed = false
    /// `start()` and `close()` can be called from different threads.
    private var sendTask: Task<Void, Never>?

    /// How many sent-but-unacked states the far side retains, for the one test that has to NAME it.
    static let retainedSentStates = Int(slopdesk_workspace_sync_constant(0))
    /// How many slots a releasing call may hand back: the window plus the base. Lending this many
    /// is what lets the far side write without ever retrying.
    private static let maxReleased = Int(slopdesk_workspace_sync_constant(1))
    /// The slot that names no payload at all — the empty document.
    private static let noSlot = UInt32(truncatingIfNeeded: slopdesk_workspace_sync_constant(2))

    private let wake: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    init(
        id: UUID = UUID(),
        channel: any MessageChannel,
        subscribe: WorkspaceSubscribe,
        onLog: (@Sendable (String) -> Void)? = nil,
    ) {
        self.id = id
        self.channel = channel
        self.onLog = onLog
        clientInstanceID = subscribe.clientInstanceID
        clientKind = subscribe.clientKind
        label = subscribe.label
        ladder = slopdesk_workspace_sync_new(subscribe.flags)
        // `.bufferingNewest(1)` is the coalescing at the STREAM layer: a hundred wakes while the
        // task is mid-send collapse to one, and the pending slot supplies the freshest value when
        // it gets there.
        (wake, wakeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit { slopdesk_workspace_sync_free(ladder) }

    /// Starts the single send task. Separate from `init` so the document can register the subscriber
    /// before the first frame can possibly ship.
    func start() {
        lock.lock()
        guard sendTask == nil, !closed else {
            lock.unlock()
            return
        }
        sendTask = Task { [weak self] in
            guard let self else { return }
            for await _ in wake {
                await drain()
            }
        }
        lock.unlock()
    }

    /// Stops the send task and drops every pending frame. Idempotent.
    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        pendingState = nil
        pendingRoster = nil
        pendingResults = []
        retainedStates = [:]
        let task = sendTask
        sendTask = nil
        lock.unlock()
        // Finishing the stream ends the `for await` loop; the cancel is belt-and-braces for a task
        // parked mid-send on a link that will never drain.
        wakeContinuation.finish()
        task?.cancel()
    }

    // MARK: Inputs (called from the document actor — synchronous, never blocking on a send)

    /// Offers the freshest document. Depth-1: an unsent prior offer is DISCARDED, not queued.
    func deliver(epoch: UUID, stateNum: Int64, state: HostWorkspaceState) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pendingState = (epoch, stateNum, state)
        lock.unlock()
        wakeContinuation.yield()
    }

    /// Presence is a FULL REPLACE and never diffed, so it coalesces the same way.
    func deliver(roster: WorkspacePresenceRoster) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pendingRoster = roster
        lock.unlock()
        wakeContinuation.yield()
    }

    func deliver(result: WorkspaceIntentResult) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        // Results are NOT coalesced: each one answers a distinct client-minted intentID, and a
        // dropped one leaves that client's optimistic patch waiting for a timeout that need not
        // happen. The list is bounded by in-flight intents, which the client itself bounds.
        pendingResults.append(result)
        lock.unlock()
        wakeContinuation.yield()
    }

    func note(ack stateNum: Int64) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        slopdesk_workspace_sync_note_ack(ladder, stateNum)
        lock.unlock()
        wakeContinuation.yield()
    }

    /// Records the client's view. Presence is per-CONNECTION and dies with the link, so the
    /// connection itself is the TTL — a timer could only ever fire after the subscriber was already
    /// gone.
    ///
    /// - Returns: `false` when the update is IGNORED because its clock is not newer. Newest wins
    ///   with no merge: a client reconnecting with a stale clock must not resurrect a view it has
    ///   since left.
    func note(presence update: WorkspacePresenceUpdate) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        let record = SlopDeskWorkspacePresence(
            presence_clock: update.presenceClock,
            viewing_tab_id: Self.flat(update.viewingTabID),
            viewing_pane_id: Self.flat(update.viewingPaneID),
            cols: update.cols,
            rows: update.rows,
            flags: update.flags,
        )
        return withUnsafePointer(to: record) { slopdesk_workspace_sync_note_presence(ladder, $0) }
    }

    /// A repeat `subscribe` IS the resync verb — there is deliberately no separate "resend".
    func note(resubscribe request: WorkspaceSubscribe) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pendingSubscribe = request
        lock.unlock()
        wakeContinuation.yield()
    }

    // MARK: Presence projection

    /// This subscriber as the host describes it to everyone else. The view, the viewport and the
    /// folded flags are the far side's; the identity half is this side's, because a `UUID` and a
    /// `String` are what a roster record is FOR.
    func rosterRecord() -> WorkspaceRosterClient {
        lock.lock()
        defer { lock.unlock() }
        var view = SlopDeskWorkspacePresence()
        slopdesk_workspace_sync_roster(ladder, &view)
        return WorkspaceRosterClient(
            clientInstanceID: clientInstanceID,
            clientKind: clientKind,
            flags: view.flags,
            viewingTabID: Self.uuid(view.viewing_tab_id),
            viewingPaneID: Self.uuid(view.viewing_pane_id),
            cols: view.cols,
            rows: view.rows,
            label: label,
        )
    }

    // MARK: Drain

    /// Everything the inbox held at one instant. A value, so the lock is released before any `await`
    /// — `NSLock` is unavailable from an async context, and holding one across a suspension is the
    /// mistake that unavailability exists to prevent.
    private struct Inbox {
        var subscribe: WorkspaceSubscribe?
        var roster: WorkspacePresenceRoster?
        var results: [WorkspaceIntentResult] = []
        var target: (epoch: UUID, stateNum: Int64, state: HostWorkspaceState)?
        var closed = false
    }

    /// What the far side asked for, with the base it named already looked up.
    private struct DocumentPlan {
        var resetFirst = false
        var snapshot = true
        var baseStateNum: Int64 = 0
        var base = HostWorkspaceState()
    }

    private func takeInbox() -> Inbox {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return Inbox(closed: true) }
        var inbox = Inbox()
        inbox.subscribe = pendingSubscribe
        pendingSubscribe = nil
        inbox.roster = pendingRoster
        pendingRoster = nil
        inbox.results = pendingResults
        pendingResults = []
        // The document offer is PEEKED, not taken: an offer the ladder turns out to HOLD must stay
        // pending so it coalesces with whatever arrives next, rather than being dropped on the floor
        // with no retry anywhere. The ack is not peeked at all — it lives on the far side, where the
        // highest one wins until the ladder is asked to apply it.
        inbox.target = pendingState
        return inbox
    }

    private func claimPendingState() {
        lock.lock()
        pendingState = nil
        lock.unlock()
    }

    private func drain() async {
        // Loop rather than return after one frame: a `deliver` that arrives WHILE we are awaiting a
        // send has already consumed its single buffered wake, so without this the freshest state
        // would sit in the pending slot until the next unrelated event.
        while true {
            let inbox = takeInbox()
            if inbox.closed { return }

            // Causal order: a resubscribe resets the base, an ack advances it, and only then does a
            // frame get built against it.
            if let subscribe = inbox.subscribe { applyResubscribe(subscribe) }
            applyPendingAck()

            // Presence and intent results are epoch-independent — the client's apply rules never
            // check the epoch for kinds 2 and 3 — so before any snapshot has shipped they ride the
            // all-zero sentinel rather than a fabricated UUID.
            let looseEpoch = currentLooseEpoch()
            var didSend = false
            for result in inbox.results {
                didSend = true
                guard await send(.intentResult, epoch: looseEpoch, base: 0, new: 0, payload: result.encode())
                else { return }
            }
            if let roster = inbox.roster {
                didSend = true
                guard await send(.presence, epoch: looseEpoch, base: 0, new: 0, payload: roster.encode())
                else { return }
            }
            if let target = inbox.target, let plan = planDocument(epoch: target.epoch) {
                claimPendingState()
                didSend = true
                guard await sendDocument(target, plan) else { return }
            }
            if !didSend { return }
        }
    }

    // MARK: The far side, one call per decision

    private func applyResubscribe(_ request: WorkspaceSubscribe) {
        lock.lock()
        clientInstanceID = request.clientInstanceID
        clientKind = request.clientKind
        label = request.label
        var freed = [UInt32](repeating: 0, count: Self.maxReleased)
        let count = slopdesk_workspace_sync_resubscribe(
            ladder, Self.flat(request.knownEpoch), request.knownStateNum, request.flags, &freed,
        )
        release(freed, count)
        lock.unlock()
    }

    private func applyPendingAck() {
        lock.lock()
        var freed = [UInt32](repeating: 0, count: Self.maxReleased)
        let count = slopdesk_workspace_sync_apply_ack(ladder, &freed)
        release(freed, count)
        lock.unlock()
    }

    private func currentLooseEpoch() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        var flat = SlopDeskWsUuid()
        slopdesk_workspace_sync_loose_epoch(ladder, &flat)
        return Self.uuid(flat)
    }

    /// - Returns: `nil` when the far side HOLDS — a frame is in flight, nothing was changed, and the
    ///   offer stays pending.
    private func planDocument(epoch: UUID) -> DocumentPlan? {
        lock.lock()
        defer { lock.unlock() }
        var record = SlopDeskWorkspaceSyncPlan()
        var freed = [UInt32](repeating: 0, count: Self.maxReleased)
        slopdesk_workspace_sync_plan(ladder, Self.flat(epoch), &record, &freed)
        guard record.send else { return nil }
        release(freed, record.released_count)
        var plan = DocumentPlan(
            resetFirst: record.reset_first,
            snapshot: record.snapshot,
            baseStateNum: record.base_state_num,
        )
        if !plan.snapshot {
            // A diff against a base the client does not hold applies CLEANLY and corrupts silently,
            // which is the whole reason the epoch exists. The far side never names a slot it has not
            // kept, so this cannot fire — and if it ever did, saying everything is the safe answer.
            if let retained = retainedStates[record.base_slot] {
                plan.base = retained
            } else {
                plan.snapshot = true
                plan.baseStateNum = 0
            }
        }
        return plan
    }

    private func commit(stateNum: Int64, state: HostWorkspaceState) {
        lock.lock()
        var freed = [UInt32](repeating: 0, count: Self.maxReleased)
        var count: UInt32 = 0
        let slot = slopdesk_workspace_sync_commit(ladder, stateNum, &freed, &count)
        release(freed, count)
        if slot != Self.noSlot { retainedStates[slot] = state }
        lock.unlock()
    }

    /// Drops the payloads the far side just stopped needing. Callers hold ``lock``.
    private func release(_ freed: [UInt32], _ count: UInt32) {
        for index in 0 ..< Int(count) where index < freed.count {
            retainedStates.removeValue(forKey: freed[index])
        }
    }

    // MARK: Send

    private func sendDocument(
        _ target: (epoch: UUID, stateNum: Int64, state: HostWorkspaceState),
        _ plan: DocumentPlan,
    ) async -> Bool {
        // A new epoch means a different document with an unrelated `stateNum` sequence. Reset FIRST
        // so no stale delta can ever be accepted, then snapshot — which is self-contained and
        // therefore epoch-independent, so a post-restart client converges in ONE frame after it.
        if plan.resetFirst {
            guard await send(.reset, epoch: target.epoch, base: 0, new: 0, payload: Data()) else { return false }
        }

        let payload: Data
        let kind: WorkspaceEventKind
        let base: Int64
        if plan.snapshot {
            kind = .snapshot
            base = 0
            payload = WorkspaceStateCodec.encodeSnapshot(target.state)
        } else {
            let diff = target.state.diff(from: plan.base)
            // Nothing changed since the acked base — say nothing. An empty diff still costs a frame
            // and an ack, and an idle host must be silent. Not committing is what leaves the ladder
            // exactly where it was.
            if diff.isEmpty { return true }
            kind = .diff
            base = plan.baseStateNum
            payload = WorkspaceStateCodec.encodeDiff(diff)
        }
        guard await send(kind, epoch: target.epoch, base: base, new: target.stateNum, payload: payload)
        else { return false }
        commit(stateNum: target.stateNum, state: target.state)
        return true
    }

    /// - Returns: `false` when the channel is gone — the caller stops draining. A dead link is not
    ///   an error to recover from here: the mux tears the channel down and the client resubscribes.
    private func send(
        _ kind: WorkspaceEventKind,
        epoch: UUID,
        base: Int64,
        new: Int64,
        payload: Data,
    ) async -> Bool {
        do {
            try await channel.send(.workspaceEvent(
                kind: kind.rawValue,
                epoch: epoch,
                baseStateNum: base,
                newStateNum: new,
                payload: payload,
            ))
            return true
        } catch {
            onLog?("workspace channel \(id): send failed (\(error)) — subscriber dropped")
            close()
            return false
        }
    }

    // MARK: Marshalling

    private static func flat(_ uuid: UUID) -> SlopDeskWsUuid { SlopDeskWsUuid(bytes: uuid.uuid) }
    private static func uuid(_ flat: SlopDeskWsUuid) -> UUID { UUID(uuid: flat.bytes) }

    // MARK: Test seams

    var outstandingForTesting: Int64? {
        lock.lock()
        defer { lock.unlock() }
        var stateNum: Int64 = 0
        return slopdesk_workspace_sync_outstanding(ladder, &stateNum) ? stateNum : nil
    }

    /// How many document payloads this side is still holding for the far side.
    ///
    /// The one failure this port could introduce that no wire assertion would catch: a slot the
    /// ladder released but this side never deleted is a whole workspace document leaked per frame,
    /// per subscriber, forever.
    var retainedStateCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedStates.count
    }
}
