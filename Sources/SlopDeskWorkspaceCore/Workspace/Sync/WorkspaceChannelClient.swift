import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel

/// The client end of the workspace-document channel (`channelClass == 1`, docs/45 §5.1).
///
/// Owns one ``HostWorkspaceMirror`` and the loop that feeds it: open → **await the ack** →
/// subscribe → apply → ack. Everything the UI reads comes off the mirror; everything the host needs
/// to know goes out as a type-17 request. There is no other traffic on this channel.
///
/// The transport is INJECTED rather than reached for, so the whole loop is provable over an
/// in-memory channel pair with no socket, no `HostServer` and no registry.
@preconcurrency
@MainActor
public final class WorkspaceChannelClient {
    /// An opened workspace channel, narrowed to what this client actually uses.
    ///
    /// Only the CONTROL sub-channel appears, because only CONTROL carries workspace traffic: the
    /// document is small, latency-sensitive control state, and CONTROL is unwindowed — so a
    /// workspace frame can never stall behind a PTY output flood waiting on flow-control credit.
    /// The DATA sub-channel the mux opens alongside stays idle, and naming it here would invite a
    /// future caller to use it.
    public struct Handle: Sendable {
        public let channelID: UInt32
        public let control: any MessageChannel
        /// The host's `channelOpenAck` verdict. `nil` for a transport that never acks.
        public let awaitAccepted: (@Sendable () async -> Bool)?

        @preconcurrency
        public init(
            channelID: UInt32,
            control: any MessageChannel,
            awaitAccepted: (@Sendable () async -> Bool)? = nil,
        ) {
            self.channelID = channelID
            self.control = control
            self.awaitAccepted = awaitAccepted
        }

        /// Adapts a mux acquisition. Production's only construction path.
        public init(_ acquisition: MuxAcquisition) {
            var accepted: (@Sendable () async -> Bool)?
            if let awaitOpenAck = acquisition.awaitOpenAck {
                accepted = { await awaitOpenAck().accepted }
            }
            self.init(
                channelID: acquisition.channelID,
                control: acquisition.control,
                awaitAccepted: accepted,
            )
        }
    }

    /// Opens a `channelClass 1` channel.
    public typealias Open = @Sendable () async throws -> Handle
    /// Releases the channel by id.
    public typealias Close = @Sendable (UInt32) async -> Void

    public enum State: Equatable, Sendable {
        case idle
        case opening
        /// Subscribed and applying frames. The associated value is the last acked `stateNum`.
        case live(Int64)
        /// The host does not serve this channel — a subscriber for this connection already exists, or
        /// the peer does not route the class at all. A definite answer, so the client stops rather
        /// than retrying.
        case refused
        /// The channel died. The connection layer restarts us; nothing retries in here.
        case closed
    }

    /// What this device calls itself in the presence roster — what OTHER clients see when a pane is
    /// held elsewhere. `hostName` rather than a UIKit device name so this stays headless and
    /// identical on both platforms; the codec clamps it to 64 UTF-8 bytes.
    public static func localDeviceLabel() -> String {
        let name = ProcessInfo.processInfo.hostName
        // Trim the mDNS suffix: "mac-studio.local" reads as a machine, "mac-studio" reads as a place.
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }

    /// The SHARED mirror. Host frames land here and the store's per-pane control sinks write its
    /// fast path — one instance, so host truth erases an overlay entry the UI would actually read.
    public let box: WorkspaceMirrorBox
    public private(set) var state: State = .idle

    /// Whether this client answers out of an in-process document rather than a host.
    ///
    /// Read by the pane dial hold: a loopback's document IS the mirror the store seeded, so there is
    /// no host verdict on the way and nothing to hold for.
    public var servesLocalDocument: Bool { localDocument != nil }

    /// Whether this client can carry an intent right now. `false` while opening, after a refusal and
    /// after a close — the states in which ``send(intent:args:now:)`` drops on the floor.
    public var isLive: Bool {
        guard case .live = state else { return false }
        return true
    }

    /// Fired on the main actor when the CHANNEL's own state changes. Document changes are announced
    /// by the box, not here.
    public var onStateChange: (@MainActor () -> Void)?

    /// This client's identity in the presence roster. One per app instance — two windows of one app
    /// are two connections and two identities, exactly as intended.
    public let clientInstanceID: UUID
    private let clientKind: WorkspaceClientKind
    private let label: String

    private let open: Open
    private let close: Close
    private let onLog: (@Sendable (String) -> Void)?

    /// The in-process document this client serves its own intents from, or `nil` for a channel that
    /// talks to a host.
    ///
    /// Set only by ``loopback(document:clientInstanceID:clientKind:label:)``. Production builds its
    /// channel through `WorkspaceStore.liveWorkspaceChannel`, which never sets it, so every branch on
    /// it below is inert in the shipped app.
    private var localDocument: LoopbackWorkspaceDocument?

    private var channelID: UInt32?
    private var control: (any MessageChannel)?
    private var runTask: Task<Void, Never>?
    /// Bumped by every `start`/`stop`. A run whose generation is stale publishes nothing — that is
    /// what lets `stop()` have the last word without the state itself becoming a lock.
    private var runGeneration = 0
    /// Monotonic, per-connection. The host keeps the NEWEST and ignores anything older, so a
    /// reconnecting client must never restart this below what it has already sent.
    private var presenceClock: Int64 = 0
    private var lastPresence: WorkspacePresenceUpdate?
    /// Presence updates waiting to go out, oldest first, and the single task that drains them.
    ///
    /// One task rather than one per update, because a detached task per call publishes in SCHEDULING
    /// order, not issue order: two updates minted in the same turn can reach the host with their
    /// clocks reversed, and the host keeps the newest clock — so the view it shows everyone else is
    /// the one the user already left, permanently.
    private var presenceQueue: [WorkspacePresenceUpdate] = []
    private var presenceDrain: Task<Void, Never>?
    /// Intents waiting to go out, oldest first, and the single task that drains them.
    ///
    /// One task for exactly the reason ``presenceQueue`` has one, and here it costs more than a stale
    /// viewport. The optimistic patch staged for each intent is the HOST's own applier run locally, in
    /// STAGE order, so a request that overtakes its predecessor makes the projection a prediction of a
    /// sequence the host never runs. Every multi-intent gesture rides on it — a mint followed by
    /// `renamePane`, the `swapPanes` pair — and `adoptWorkspace` loses outright: only a PRISTINE
    /// document accepts one, so any intent that passes it spends the host's single chance and the
    /// layout this client is already showing comes back `rejectedStale`.
    private var intentQueue: [WorkspaceIntent] = []
    private var intentDrain: Task<Void, Never>?

    @preconcurrency
    public init(
        box: WorkspaceMirrorBox,
        clientInstanceID: UUID = UUID(),
        clientKind: WorkspaceClientKind,
        label: String,
        open: @escaping Open,
        close: @escaping Close,
        onLog: (@Sendable (String) -> Void)? = nil,
    ) {
        self.box = box
        self.clientInstanceID = clientInstanceID
        self.clientKind = clientKind
        self.label = label
        self.open = open
        self.close = close
        self.onLog = onLog
    }

    // MARK: - Lifecycle

    /// Builds a client whose document is `document` rather than a host on the far end of a socket.
    ///
    /// It is `.live` from the moment it is built, so a SYNCHRONOUS caller can send an intent and read
    /// the result on its next line — the property the async run loop cannot offer, and the reason a
    /// store whose layout comes from the document is otherwise untestable outside `async` code.
    ///
    /// `open`/`close` are unreachable: ``start()`` and ``stop()`` are inert for a loopback, because
    /// this client has nothing to open and because `stop()`'s `box.reset()` would erase the very
    /// `entries` the document is authoritative over.
    public static func loopback(
        document: LoopbackWorkspaceDocument,
        clientInstanceID: UUID = UUID(),
        clientKind: WorkspaceClientKind = .thisPlatform,
        label: String = localDeviceLabel(),
    ) -> WorkspaceChannelClient {
        let client = WorkspaceChannelClient(
            box: document.box,
            clientInstanceID: clientInstanceID,
            clientKind: clientKind,
            label: label,
            open: { throw CancellationError() },
            close: { _ in },
        )
        client.localDocument = document
        client.publish(.live(document.stateNum))
        return client
    }

    /// Opens and subscribes. Idempotent while a run is in flight, and a no-op once the host has
    /// REFUSED — a refusal is a fact about this host, not a transient failure.
    public func start() {
        // A loopback client is already live against a document that is already installed.
        guard localDocument == nil else { return }
        guard runTask == nil, state != .refused else { return }
        runGeneration &+= 1
        let generation = runGeneration
        publish(.opening)
        runTask = Task { [weak self] in await self?.run(generation: generation) }
    }

    /// Tears the channel down and forgets host truth.
    ///
    /// The mirror is reset because `entries` is only meaningful with respect to a live subscription:
    /// keeping it would let a reconnect apply a diff against a document the host may have replaced.
    /// The next subscribe declares `stateNum 0` and gets a snapshot, which is one frame.
    ///
    /// A mirror no host has spoken into is the exception, and it is the one a COLD LAUNCH is in — see
    /// the reset itself.
    public func stop() {
        // A loopback client has no subscription to tear down, and `box.reset()` would delete the
        // document it is authoritative over. The store re-opens its channel on every connection
        // establish, so this holds structurally rather than by nobody calling it.
        guard localDocument == nil else { return }
        runGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        let id = channelID
        channelID = nil
        control = nil
        // Forgetting host truth is what the reset is FOR, and a mirror no host has spoken into holds
        // none: every entry in it is the seed the store restored from disk. Resetting there empties
        // ``WorkspaceStore/tree``, which is a pure PROJECTION of this box — so the layout the user
        // restored leaves the screen the instant the connection comes up, and a host that then never
        // answers (a class it does not know, a wedged daemon, a link that dies mid-subscribe) leaves
        // the window blank with no error on it. The restored layout is the right thing to look at
        // until a host names a different one; ``WorkspaceStore/panesMayDial`` is what keeps those
        // unconfirmed ids from opening a PTY, so showing them costs nothing.
        //
        // Once a frame HAS landed the reset stands, for the reason in this method's doc.
        if box.holdsHostDocument { box.reset() }
        // Whatever is still queued is an OFFLINE intent, and those are dropped rather than replayed
        // (docs/45 §7.2). The patch each was standing in for is either gone with the reset above or
        // bounded by the mirror's own pending sweep, so a write that went out after this would ask a
        // host for a change nothing on screen is predicting for much longer. The drain task is left
        // to notice the empty queue on its next pass, for the same
        // reason ``clearPresence()`` leaves its own: clearing the SLOT is what would let a
        // stopped-then-reused client start a SECOND drain, and two drains sharing one queue reorder
        // precisely what the single one exists to keep in order.
        intentQueue.removeAll()
        clearPresence()
        // A deliberate teardown clears a refusal too: the next `start()` may be against a DIFFERENT
        // host, or the same one restarted, and a refusal is a fact about one connection.
        publish(.closed)
        // Claiming `channelID` above is what makes this the SINGLE release: the run task's exit path
        // releases only the channel it still owns, so a stop that races the loop unwinding cannot
        // close the same id twice — and a second close would tear down a shared connection a
        // reconnect had already rebuilt under the same pool key.
        if let id {
            let close = close
            Task { await close(id) }
        }
    }

    private func run(generation: Int) async {
        let opened: Handle
        do {
            opened = try await open()
        } catch {
            onLog?("workspace channel: open failed (\(error))")
            finish(.closed, generation: generation)
            return
        }

        // Claim the channel BEFORE the ack await, so a `stop()` arriving mid-handshake still knows
        // there is something to release. `control` stays nil until the ack lands, which is what
        // makes the ordering rule below unbreakable rather than merely observed: `send` has nothing
        // to write through.
        channelID = opened.channelID

        // **Await the ack BEFORE the first request** (docs/45 §11.3, DECISIONS Phase-4 ruling 7).
        // `channelOpen` is announced on the DATA link while every request rides CONTROL, so a
        // subscribe sent immediately can beat the host's registration of the control sub-channel and
        // be dropped — leaving this client waiting for a snapshot that will never come. The failure
        // presents as a hang, not an error, which is exactly why it must be structural.
        //
        // BOUNDED, for the same reason the pane path bounds it: a host that takes the channel and
        // then says nothing would otherwise strand this loop for the life of the process, in a state
        // no other clock reaches. Nothing reopens a subscription stuck at `.opening`, so the window
        // would keep drawing per-pane facts off the control-push sinks with its LAYOUT frozen at the
        // last fold and nothing on screen to say why.
        if let awaitAccepted = opened.awaitAccepted {
            guard let accepted = await Self.race(awaitAccepted, timeout: handshakeTimeout) else {
                onLog?("workspace channel: no open ack within the handshake window — closing")
                await releaseIfOwned(opened.channelID)
                // `.closed`, never `.refused`: a refusal is the host stating it does not serve the
                // class, and it stops this client for good. Silence states nothing.
                finish(.closed, generation: generation)
                return
            }
            guard accepted else {
                onLog?("workspace channel: host refused — falling back to the control-push sinks")
                await releaseIfOwned(opened.channelID)
                finish(.refused, generation: generation)
                return
            }
        }
        guard !Task.isCancelled else {
            await releaseIfOwned(opened.channelID)
            finish(.closed, generation: generation)
            return
        }

        control = opened.control
        await sendSubscribe()

        do {
            for try await message in opened.control.inbound {
                guard case let .workspaceEvent(kind, epoch, base, new, payload) = message else { continue }
                await handle(kind: kind, epoch: epoch, base: base, new: new, payload: payload)
            }
        } catch {
            onLog?("workspace channel: receive ended (\(error))")
        }
        // Clean close OR error — either way this subscription is over. The connection layer decides
        // whether to start a new one; retrying in here would fight it.
        control = nil
        await releaseIfOwned(opened.channelID)
        finish(.closed, generation: generation)
    }

    /// Releases `id` only while this client still owns it. A `stop()` that already claimed the
    /// channel wins, and the loser does nothing.
    private func releaseIfOwned(_ id: UInt32) async {
        guard channelID == id else { return }
        channelID = nil
        control = nil
        await close(id)
    }

    /// Races `operation` against `timeout`, answering `nil` when the timeout wins.
    ///
    /// The loser is cancelled. The production awaiter (`MuxNWConnection.awaitOpenAck`) resumes a
    /// cancelled waiter immediately, so no continuation is stranded and the group closes.
    private static func race(
        _ operation: @escaping @Sendable () async -> Bool,
        timeout: Duration,
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            guard let first = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return first
        }
    }

    private func finish(_ next: State, generation: Int) {
        // A superseded run says nothing: `stop()` (or a later `start()`) already published the state
        // it wanted, and letting a dying loop overwrite it is how a live channel reports itself dead.
        guard generation == runGeneration else { return }
        runTask = nil
        publish(next)
    }

    private func publish(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChange?()
    }

    // MARK: - Apply

    private func handle(kind: UInt8, epoch: UUID, base: Int64, new: Int64, payload: Data) async {
        // Sweep patches the host never answered before folding the frame in. A patch older than
        // `pendingTimeout` describes an intent whose verdict is not coming, and it takes precedence
        // over `entries` on every read — so leaving it in place would make this very frame invisible
        // for the keys it touches.
        box.expirePending(now: now())
        let outcome = box.apply(
            kind: kind,
            epoch: epoch,
            baseStateNum: base,
            newStateNum: new,
            payload: payload,
        )
        switch outcome {
        case let .applied(stateNum):
            publish(.live(stateNum))
            await send(verb: .ack, payload: WorkspaceStateCodec.encodeI64(stateNum))

        case .needsResubscribe:
            // A repeat `subscribe` IS the resync verb — there is deliberately no separate "resend".
            // The mirror already refused the frame, so what goes out describes where we actually are.
            onLog?("workspace channel: re-subscribing from stateNum \(box.knownStateNum)")
            await sendSubscribe()

        case .reset:
            publish(.live(0))

        case .presence:
            break

        case .intentResult:
            // The mirror has already folded the verdict in — a refusal snapped its patch away, an
            // acceptance armed it to retire on the next document frame. What is left is the repaint,
            // which the box does not fire for a result because most results change nothing on screen.
            box.notePendingChanged()

        case .ignored,
             .dropped:
            break
        }
    }

    // MARK: - Requests

    private func sendSubscribe() async {
        let request = WorkspaceSubscribe(
            clientInstanceID: clientInstanceID,
            clientKind: clientKind.rawValue,
            knownEpoch: box.knownEpoch,
            knownStateNum: box.knownStateNum,
            // No flags in Phase 4. `contributesSize` belongs to Phase 6's size fold and
            // `followsFocus` to Phase 5's host-truth focus; setting either now would put this client
            // in a roster column that does not yet mean anything.
            flags: 0,
            label: label,
        )
        // Captured BEFORE the write: `updatePresence` can run while the subscribe is in flight, and
        // re-asserting the value read AFTERWARDS would put a frame the ordered drain is already
        // carrying on the wire a second time — or, worse, put an OLDER one behind a newer, which is
        // precisely the reversal the single drain exists to prevent.
        let reassert = lastPresence
        await send(verb: .subscribe, payload: request.encode())
        // A resubscribe resets the host's per-subscriber presence expectations along with its base,
        // so re-assert what this client is looking at rather than waiting for the next UI change.
        // Skipped when something newer has since been queued: that frame IS the re-assert.
        guard let reassert, presenceQueue.isEmpty, lastPresence?.presenceClock == reassert.presenceClock
        else { return }
        await sendPresence(reassert)
    }

    /// Tells the host what this client is looking at. Phase 4 ships the identity half of presence;
    /// the viewport is carried but not yet folded into a PTY size.
    ///
    /// Dirty-guarded, because the caller is the reconcile funnel — which also fires for a spec edit,
    /// a badge tick and a rename. Only a changed VIEW is news; without the guard the channel would
    /// spend a frame per reconcile on a workspace nobody is navigating, and the monotone clock would
    /// run away for no reason. The resubscribe re-assert bypasses this: it repeats `lastPresence`
    /// verbatim rather than minting a new one.
    public func updatePresence(viewingTabID: UUID, viewingPaneID: UUID, cols: UInt16, rows: UInt16) {
        if let lastPresence, lastPresence.viewingTabID == viewingTabID,
           lastPresence.viewingPaneID == viewingPaneID, lastPresence.cols == cols,
           lastPresence.rows == rows
        {
            return
        }
        presenceClock += 1
        let update = WorkspacePresenceUpdate(
            presenceClock: presenceClock,
            viewingTabID: viewingTabID,
            viewingPaneID: viewingPaneID,
            cols: cols,
            rows: rows,
            flags: 0,
        )
        lastPresence = update
        presenceQueue.append(update)
        // Already draining: the loop below picks this up on its next pass, in the order it was queued.
        guard presenceDrain == nil else { return }
        presenceDrain = Task { [weak self] in
            while let next = self?.takeQueuedPresence() {
                await self?.sendPresence(next)
            }
            // No `await` between the empty check and this, so on the main actor the two are one step
            // and an `updatePresence` arriving in between cannot find a drain that is neither running
            // nor restartable.
            self?.presenceDrain = nil
        }
    }

    private func takeQueuedPresence() -> WorkspacePresenceUpdate? {
        presenceQueue.isEmpty ? nil : presenceQueue.removeFirst()
    }

    /// Forgets what this client last said it was looking at, and abandons anything still queued.
    ///
    /// The drain task is left to notice the empty queue on its next pass rather than being cancelled
    /// and its slot cleared. Clearing the slot is what would let a stopped-then-reused client start a
    /// SECOND drain, and two drains sharing one queue reorder precisely what the single one exists to
    /// keep in order.
    private func clearPresence() {
        lastPresence = nil
        presenceQueue.removeAll()
    }

    private func sendPresence(_ update: WorkspacePresenceUpdate) async {
        await send(verb: .presence, payload: update.encode())
    }

    /// Asks the host to change the layout, showing the change immediately.
    ///
    /// The optimistic patch is staged BEFORE anything goes out, and it is computed by running the
    /// host's own applier — so the split is on screen in the same frame the user asked for it, and
    /// what appears is what the host is about to publish.
    ///
    /// EVERY intent takes this path, `adoptWorkspace` included — the one whose answer the client
    /// genuinely cannot predict, since `documentIsPristine` is a fact about the HOST's own file that
    /// no cell carries. It is staged anyway, and that is deliberate: the layout on offer is the one
    /// the window is already showing, so the patch keeps the projection where the panes are and the
    /// reconcile it triggers is a no-op. Proposing it silently instead would leave the host's
    /// first-run default as the thing to project for a round trip — and, now that the projection
    /// drives the registry, that tears down every restored pane's shell and dials a throwaway for the
    /// host's own. A refusal costs one snap-back of a layout nobody had moved to.
    ///
    /// `intentID` is the identity the optimistic patch is staged under, so a caller that has to know
    /// when ITS request was decided can ask ``WorkspaceMirrorBox/isPending(_:)`` afterwards. Minted
    /// here by default; the launch adopt supplies its own, because it is the one op whose verdict the
    /// client genuinely cannot predict.
    ///
    /// - Returns: `false` when this client can already tell the intent is invalid against the
    ///   document it holds. Nothing is staged and nothing is sent: a request whose answer is already
    ///   known is a round trip and a rollback for no reason.
    @discardableResult
    public func send(
        intent op: WorkspaceIntentOp,
        args: Data,
        intentID: UUID = UUID(),
        now: TimeInterval = Date().timeIntervalSince1970,
    ) -> Bool {
        guard case .live = state else { return false }
        guard let intent = box.stageIntent(intentID, op: op, args: args, issuedAt: now) else { return false }
        // A loopback client IS the far end: it answers here, before this call returns, so the patch
        // staged one line above is already retired by the document frame the answer carries.
        if let localDocument {
            localDocument.serve(intent)
            return true
        }
        enqueue(intent: intent)
        return true
    }

    /// Queues one intent behind everything already waiting, starting the drain if it is idle.
    private func enqueue(intent: WorkspaceIntent) {
        intentQueue.append(intent)
        // Already draining: the loop below picks this up on its next pass, in the order it was queued.
        guard intentDrain == nil else { return }
        intentDrain = Task { [weak self] in
            while let next = self?.takeQueuedIntent() {
                await self?.deliver(intent: next)
            }
            // No `await` between the empty check and this, so on the main actor the two are one step
            // and a `send(intent:)` arriving in between cannot find a drain that is neither running
            // nor restartable.
            self?.intentDrain = nil
        }
    }

    private func takeQueuedIntent() -> WorkspaceIntent? {
        intentQueue.isEmpty ? nil : intentQueue.removeFirst()
    }

    /// Puts one intent on the wire and arms its backstop.
    ///
    /// The WRITE is awaited here, and that is the whole ordering guarantee: the next intent's request
    /// is not framed until this one has been. The backstop sweep is NOT awaited — it fires a whole
    /// `pendingTimeout` later, and holding the queue for it would delay every following gesture by
    /// that long.
    private func deliver(intent: WorkspaceIntent) async {
        // A failed write means the host was never asked, so no `intentResult` will ever retire this
        // patch and no timeout should have to: snap it away now. Otherwise the split the user
        // requested would stay on screen — on this client only — across every subsequent host frame,
        // which is the frozen disagreement the pending layer exists to prevent.
        guard await send(verb: .intent, payload: intent.encode()) else {
            box.dropPending(intent.intentID)
            return
        }
        // The host WAS asked. Arm the backstop for the case with no other signal — a host that
        // accepted and died before answering, on a channel quiet enough that no later frame arrives
        // to sweep it.
        guard let delay = pendingSweepDelay else { return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            box.expirePending(now: now())
        }
    }

    @discardableResult
    private func send(verb: WorkspaceRequestVerb, payload: Data) async -> Bool {
        guard let control else { return false }
        do {
            // `requestSeq` is reserved: the host answers requests by CONTENT (an ack carries the
            // stateNum, an intent result carries the intentID), so nothing correlates on it.
            try await control.send(.workspaceRequest(requestSeq: 0, verb: verb.rawValue, payload: payload))
            return true
        } catch {
            onLog?("workspace channel: send(\(verb)) failed (\(error))")
            return false
        }
    }

    // MARK: - Test seams

    /// The clock the pending sweep reads. Injectable so a test can prove the expiry without sleeping.
    var now: @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }

    /// How long after an intent goes out the self-driving backstop sweep fires. One `pendingTimeout`
    /// in production, so the check is already past the deadline when it runs. `nil` disables it,
    /// which is what isolates the FRAME-driven sweep in a test — the two would otherwise race and
    /// whichever won would look like the one under test.
    var pendingSweepDelay: Duration? = .seconds(HostWorkspaceMirror.pendingTimeout)

    /// How long the open waits for the host's `channelOpenAck` before treating the silence as a dead
    /// handshake. The pane path's own bound, to the second (`SlopDeskClient.connect`).
    var handshakeTimeout: Duration = .seconds(10)

    var isRunningForTesting: Bool { runTask != nil }

    /// The in-process document, for the handful of states no intent can reach — a tree with zero
    /// sessions, or one carrying a `.desktop` leaf the public surface refuses to build.
    var localDocumentForTesting: LoopbackWorkspaceDocument? { localDocument }
    var presenceClockForTesting: Int64 { presenceClock }
}
