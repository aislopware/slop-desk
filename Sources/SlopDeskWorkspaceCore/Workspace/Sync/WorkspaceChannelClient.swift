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
        /// The host does not serve this channel — the flag is off there, or a subscriber for this
        /// connection already exists. A definite answer, so the client stops rather than retrying.
        case refused
        /// The channel died. The connection layer restarts us; nothing retries in here.
        case closed
    }

    /// `SLOPDESK_WORKSPACE_DOC` — `== "1"`, default-OFF during bake-in. With it off the client never
    /// opens the channel and the per-pane control sinks drive the UI exactly as they do today.
    public static var isEnabledByDefault: Bool {
        ProcessInfo.processInfo.environment["SLOPDESK_WORKSPACE_DOC"] == "1"
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

    /// Opens and subscribes. Idempotent while a run is in flight, and a no-op once the host has
    /// REFUSED — a refusal is a fact about this host, not a transient failure.
    public func start() {
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
    public func stop() {
        runGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        let id = channelID
        channelID = nil
        control = nil
        box.reset()
        lastPresence = nil
        // A deliberate teardown clears a refusal too: the next `start()` may be against a DIFFERENT
        // host, or the same one with the flag now on, and a refusal is a fact about one connection.
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
        if let awaitAccepted = opened.awaitAccepted {
            guard await awaitAccepted() else {
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
        await send(verb: .subscribe, payload: request.encode())
        // A resubscribe resets the host's per-subscriber presence expectations along with its base,
        // so re-assert what this client is looking at rather than waiting for the next UI change.
        if let lastPresence { await sendPresence(lastPresence) }
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
        Task { [weak self] in await self?.sendPresence(update) }
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
    /// - Returns: `false` when this client can already tell the intent is invalid against the
    ///   document it holds. Nothing is staged and nothing is sent: a request whose answer is already
    ///   known is a round trip and a rollback for no reason.
    @discardableResult
    public func send(
        intent op: WorkspaceIntentOp,
        args: Data,
        now: TimeInterval = Date().timeIntervalSince1970,
    ) -> Bool {
        guard case .live = state else { return false }
        guard let intent = box.stageIntent(op: op, args: args, issuedAt: now) else { return false }
        Task { [weak self] in await self?.send(verb: .intent, payload: intent.encode()) }
        return true
    }

    private func send(verb: WorkspaceRequestVerb, payload: Data) async {
        guard let control else { return }
        do {
            // `requestSeq` is reserved: the host answers requests by CONTENT (an ack carries the
            // stateNum, an intent result carries the intentID), so nothing correlates on it.
            try await control.send(.workspaceRequest(requestSeq: 0, verb: verb.rawValue, payload: payload))
        } catch {
            onLog?("workspace channel: send(\(verb)) failed (\(error))")
        }
    }

    // MARK: - Test seams

    var isRunningForTesting: Bool { runTask != nil }
    var presenceClockForTesting: Int64 { presenceClock }
}
