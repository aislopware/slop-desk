import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel

/// One subscribed connection's view of the workspace document.
///
/// Owns the three things that are PER-SUBSCRIBER and nothing that is global: the state that
/// subscriber last ACKED, the depth-1 pending slot, and the single send task that drains it.
///
/// **The send queue is depth-1 and COALESCING, and it is never `enqueueControl`.**
/// `MuxChannelSession.enqueueControl` sheds NEW messages past `maxControlOutQueued = 1024`; a shed
/// snapshot would leave a client pinned at `stateNum 0` with no retry trigger anywhere — a silent,
/// permanent blank workspace. Here a pending update is DISCARDED AND RECOMPUTED, never queued, so
/// host memory is O(clients × state) no matter how slow a client is. A sleeping iPhone is free.
///
/// **Every diff is computed from the ACKED base, never the last SENT base** (docs/45 §5.5, mosh SSP).
/// Because a diff assigns rather than mutates, `apply(d, apply(d, s)) == apply(d, s)` holds by
/// construction — duplicates and reorders are no-ops with no extra machinery — and a client four
/// hours offline costs exactly one diff, bounded by the SIZE of the tree rather than the DURATION of
/// its absence. There is no retransmit path on either side, and none is needed: this rides the mux
/// CONTROL sub-channel, which is TCP and unwindowed, so delivery is reliable and in-order. A link
/// that dies takes the channel with it and the client resubscribes.
///
/// One send is outstanding at a time. While an ack is pending, further updates coalesce into the
/// pending slot and ship as ONE diff when it lands — which is also what keeps every diff's declared
/// `baseStateNum` equal to what the client actually holds.
final class WorkspaceChannelSession: @unchecked Sendable {
    /// Identity of this SUBSCRIBER — one per workspace channel, minted by the host.
    let id: UUID

    /// The client's own identity from `subscribe`. Presence is keyed by this, not by ``id``: two
    /// windows of one app are two connections and two identities, exactly as intended.
    private(set) var clientInstanceID: UUID
    private(set) var clientKind: UInt8
    private(set) var label: String
    private(set) var contributesSize: Bool
    private(set) var followsFocus: Bool

    private let channel: any MessageChannel
    private let onLog: (@Sendable (String) -> Void)?

    // MARK: Inbox — coalesced, guarded by `lock`

    private let lock = NSLock()
    private var pendingState: (epoch: UUID, stateNum: Int64, state: HostWorkspaceState)?
    private var pendingRoster: WorkspacePresenceRoster?
    private var pendingAck: Int64?
    private var pendingSubscribe: WorkspaceSubscribe?
    private var pendingResults: [WorkspaceIntentResult] = []
    /// The client's last accepted presence update — its view and viewport offer.
    private var presence: WorkspacePresenceUpdate?
    private var closed = false

    // MARK: Send-task-owned bookkeeping

    //
    // Touched ONLY inside `drain()`, which the one send task runs serially. That is why none of it
    // needs a lock: single-threaded ownership beats a mutex you have to reason about.

    private var assumedAcked = HostWorkspaceState()
    private var ackedStateNum: Int64 = 0
    private var sentEpoch: UUID?
    private var needsSnapshot = true
    /// Sent-but-unacked states, oldest first. At most ``retainedSentStates`` — a subscriber whose
    /// acked `stateNum` falls outside the window gets a fresh snapshot rather than a diff it could
    /// not base. The document is tens of KB, so the window is cheap and the fallback is correct.
    private var sentStates: [(stateNum: Int64, state: HostWorkspaceState)] = []
    /// The `stateNum` of the frame in flight, `nil` when the client is caught up.
    private var outstanding: Int64?

    static let retainedSentStates = 4

    private let wake: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    /// Guarded by ``lock`` — `start()` and `close()` can be called from different threads.
    private var sendTask: Task<Void, Never>?

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
        contributesSize = subscribe.contributesSize
        followsFocus = subscribe.followsFocus
        // `.bufferingNewest(1)` is the coalescing at the STREAM layer: a hundred wakes while the
        // task is mid-send collapse to one, and the pending slot supplies the freshest value when
        // it gets there.
        (wake, wakeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        applySubscribeFields(subscribe)
    }

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
        // Highest wins — an out-of-order or duplicated ack can only ever move the base forward.
        pendingAck = Swift.max(pendingAck ?? Int64.min, stateNum)
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
        if let presence, update.presenceClock <= presence.presenceClock { return false }
        presence = update
        return true
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

    /// This subscriber as the host describes it to everyone else. `viewing*` and the viewport come
    /// from the last presence update; Phase 4 ships the identity half and leaves the rest at zero.
    func rosterRecord() -> WorkspaceRosterClient {
        lock.lock()
        defer { lock.unlock() }
        var flags: UInt8 = 0
        // The presence update's own flag wins over the subscribe's: the client's willingness to
        // contribute to the size fold is a live property of its window, not of its connection.
        if presence?.contributesSize ?? contributesSize { flags |= WorkspaceSubscribe.flagContributesSize }
        if followsFocus { flags |= WorkspaceSubscribe.flagFollowsFocus }
        return WorkspaceRosterClient(
            clientInstanceID: clientInstanceID,
            clientKind: clientKind,
            flags: flags,
            viewingTabID: presence?.viewingTabID ?? WireMessage.newSessionID,
            viewingPaneID: presence?.viewingPaneID ?? WireMessage.newSessionID,
            cols: presence?.cols ?? 0,
            rows: presence?.rows ?? 0,
            label: label,
        )
    }

    // MARK: Drain

    /// Everything the inbox held at one instant. A value, so the lock is released before any `await`
    /// — `NSLock` is unavailable from an async context, and holding one across a suspension is the
    /// mistake that unavailability exists to prevent.
    private struct Inbox {
        var subscribe: WorkspaceSubscribe?
        var ack: Int64?
        var roster: WorkspacePresenceRoster?
        var results: [WorkspaceIntentResult] = []
        var target: (epoch: UUID, stateNum: Int64, state: HostWorkspaceState)?
        var closed = false
    }

    private func takeInbox() -> Inbox {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return Inbox(closed: true) }
        var inbox = Inbox()
        inbox.subscribe = pendingSubscribe
        pendingSubscribe = nil
        inbox.ack = pendingAck
        pendingAck = nil
        inbox.roster = pendingRoster
        pendingRoster = nil
        inbox.results = pendingResults
        pendingResults = []
        // The document offer is PEEKED, not taken: an offer we turn out not to be allowed to send
        // yet must stay pending so it coalesces with whatever arrives next, rather than being
        // dropped on the floor with no retry anywhere.
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
            if let ack = inbox.ack { applyAck(ack) }

            // Presence and intent results are epoch-independent — the client's apply rules never
            // check the epoch for kinds 2 and 3 — so before any snapshot has shipped they ride the
            // all-zero sentinel rather than a fabricated UUID.
            let looseEpoch = sentEpoch ?? WireMessage.newSessionID
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
            if let target = inbox.target, outstanding == nil {
                claimPendingState()
                didSend = true
                guard await sendDocument(target) else { return }
            }
            if !didSend { return }
        }
    }

    private func storeSubscribeFields(_ request: WorkspaceSubscribe) {
        lock.lock()
        applySubscribeFields(request)
        lock.unlock()
    }

    private func applySubscribeFields(_ request: WorkspaceSubscribe) {
        clientInstanceID = request.clientInstanceID
        clientKind = request.clientKind
        label = request.label
        contributesSize = request.contributesSize
        followsFocus = request.followsFocus
    }

    private func applyResubscribe(_ request: WorkspaceSubscribe) {
        storeSubscribeFields(request)
        // A resync abandons whatever was in flight: the client has told us exactly where it is, and
        // that supersedes any guess based on a frame it may or may not have applied.
        outstanding = nil
        // Can we base a diff on what the client claims to hold? Only if the epoch matches AND we
        // still retain that exact state. Otherwise: snapshot. Reconnect, a missed frame and a
        // four-hour absence all land here, on one code path.
        if request.knownEpoch == sentEpoch, request.knownStateNum != 0,
           let retained = sentStates.first(where: { $0.stateNum == request.knownStateNum })
        {
            assumedAcked = retained.state
            ackedStateNum = retained.stateNum
            needsSnapshot = false
        } else {
            assumedAcked = HostWorkspaceState()
            ackedStateNum = 0
            needsSnapshot = true
        }
        sentStates.removeAll()
    }

    private func applyAck(_ stateNum: Int64) {
        guard let retained = sentStates.first(where: { $0.stateNum == stateNum }) else {
            // An ack for a state we no longer retain (or never sent). Do NOT guess a base — a diff
            // against the wrong base applies cleanly and corrupts silently, which is the whole
            // reason the epoch exists. Fall back to a snapshot, which is self-contained.
            if stateNum != ackedStateNum { needsSnapshot = true }
            outstanding = nil
            return
        }
        assumedAcked = retained.state
        ackedStateNum = stateNum
        sentStates.removeAll { $0.stateNum <= stateNum }
        if outstanding == stateNum { outstanding = nil }
    }

    private func sendDocument(_ target: (epoch: UUID, stateNum: Int64, state: HostWorkspaceState)) async -> Bool {
        // A new epoch means a different document with an unrelated `stateNum` sequence. Reset FIRST
        // so no stale delta can ever be accepted, then snapshot — which is self-contained and
        // therefore epoch-independent, so a post-restart client converges in ONE frame after it.
        if let sentEpoch, sentEpoch != target.epoch {
            guard await send(.reset, epoch: target.epoch, base: 0, new: 0, payload: Data()) else { return false }
            assumedAcked = HostWorkspaceState()
            ackedStateNum = 0
            sentStates.removeAll()
            needsSnapshot = true
        }
        sentEpoch = target.epoch

        let payload: Data
        let kind: WorkspaceEventKind
        let base: Int64
        if needsSnapshot || ackedStateNum == 0 {
            kind = .snapshot
            base = 0
            payload = WorkspaceStateCodec.encodeSnapshot(target.state)
        } else {
            let diff = target.state.diff(from: assumedAcked)
            // Nothing changed since the acked base — say nothing. An empty diff still costs a frame
            // and an ack, and an idle host must be silent.
            if diff.isEmpty { return true }
            kind = .diff
            base = ackedStateNum
            payload = WorkspaceStateCodec.encodeDiff(diff)
        }
        guard await send(kind, epoch: target.epoch, base: base, new: target.stateNum, payload: payload)
        else { return false }
        needsSnapshot = false
        outstanding = target.stateNum
        // Retain the state we just sent so its ack can become the next diff's base. Oldest first,
        // capped: past the window an ack falls back to a snapshot, which is always correct.
        sentStates.removeAll { $0.stateNum == target.stateNum }
        sentStates.append((target.stateNum, target.state))
        if sentStates.count > Self
            .retainedSentStates { sentStates.removeFirst(sentStates.count - Self.retainedSentStates) }
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

    // MARK: Test seams

    var ackedStateNumForTesting: Int64 { ackedStateNum }
    var outstandingForTesting: Int64? { outstanding }
    var needsSnapshotForTesting: Bool { needsSnapshot }
}
