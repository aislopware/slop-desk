import Foundation
import Network
import RworkProtocol

/// Host side of the Rwork transport: an `NWListener` that accepts the dual
/// (CONTROL + DATA) TCP connections, performs the server-authoritative handshake,
/// associates the two physical connections to one logical session, replays the
/// missing tail to a returning client, and surfaces ready ``HostSessionTransport``s.
///
/// ## Handshake (server decides RETURNING_CLIENT — ET `Connection.cpp`)
/// 1. A new connection arrives; the listener reads the 1-byte association preamble.
/// 2. **CONTROL** (`0x01`): read `hello(version, sessionID, lastReceivedSeq)`.
///    - all-zero / unknown `sessionID` → mint a **NEW** session, reply
///      `helloAck(freshID, resumeFromSeq: 0, returningClient: false)`.
///    - known non-zero `sessionID` → **RETURNING_CLIENT**: reply
///      `helloAck(sessionID, resumeFromSeq: lastReceivedSeq, returningClient: true)`,
///      mark the session online, and replay `output` with `seq > lastReceivedSeq` on
///      the new data channel (done once the data channel associates).
/// 3. **DATA** (`0x02` + 16-byte sessionID): look up the pending/known session and
///    associate this connection as its data channel. Once both channels are present,
///    the session is rebound (and the tail replayed for a returning client) and the
///    session is yielded on ``sessions`` (for a NEW session only — a resume reuses the
///    existing object).
///
/// All mutable state (the session map, pending control handshakes) lives inside this
/// `actor`. No `@unchecked Sendable`.
public actor HostTransport {
    /// Sessions the host is currently serving, keyed by id (for RETURNING_CLIENT).
    private var sessions: [UUID: HostSessionTransport] = [:]

    /// Pending handshakes whose CONTROL channel arrived but DATA has not yet.
    private struct PendingControl {
        let control: NWMessageChannel
        let lastReceivedSeq: Int64
        let returningClient: Bool
        /// Monotonic timestamp (``ContinuousClock``) at which the control handshake
        /// completed and this entry was created. The reaper expires it once
        /// `now - createdAt > pendingDataTimeout`.
        let createdAt: ContinuousClock.Instant
    }
    private var pending: [UUID: PendingControl] = [:]

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rwork.host.listener")

    /// Bounded wait for the whole accept→handshake sequence on a single connection,
    /// symmetric with the client's `handshakeTimeout`. Without it, a connection that
    /// stalls mid-handshake (never sends its preamble / hello) parks a detached
    /// `handshake()` Task and its `NWConnection` forever.
    let handshakeTimeout: Duration

    /// How long a half-open handshake (CONTROL completed, DATA never associated) may
    /// linger before the reaper closes its control channel and drops the pending entry.
    /// Guards the iOS-background / NetBird-flap case where the DATA connection never
    /// arrives after `helloAck`. Injectable (tiny values) so tests drive it without
    /// wall-clock sleeps; default 15s.
    let pendingDataTimeout: Duration

    /// Clock used for pending-entry expiry. Injectable so a test can stamp + drive the
    /// reaper deterministically; production uses the real ``ContinuousClock``.
    private let clock: ContinuousClock

    /// Whether the `RWORK_TCP_MUX` gate is ON. When OFF (default) a mux preamble (`0x03`/`0x04`)
    /// falls through to the unknown-tag error exactly as before this feature existed — so the OFF
    /// path is byte-identical and a mux client cannot accidentally talk to an un-gated host. Both
    /// ends MUST agree on the flag (spec constraint #2). Resolved once at init.
    let muxEnabled: Bool

    // New sessions are published here for the owner (WF-3) to attach a PTY to.
    private let sessionStream: AsyncStream<HostSessionTransport>
    private let sessionContinuation: AsyncStream<HostSessionTransport>.Continuation

    // Accepted SHARED mux connections (CONTROL+DATA paired) published here for the mux relay owner.
    private let muxConnectionStream: AsyncStream<MuxNWConnection>
    private let muxConnectionContinuation: AsyncStream<MuxNWConnection>.Continuation

    /// Half-paired mux connections: a mux CONTROL (or DATA) socket arrived and is awaiting its
    /// partner with the same connectionID. Keyed by the preamble connectionID.
    private struct PendingMuxLink {
        let control: (any MuxByteLink)?
        let data: (any MuxByteLink)?
        /// When the FIRST of the pair arrived — the reaper expires a half-pair past
        /// ``pendingDataTimeout`` so a partner that never shows (crash / NAT drop / hostile
        /// CONTROL-only flood) cannot leak NWConnections unbounded.
        let createdAt: ContinuousClock.Instant
    }
    private var pendingMux: [UUID: PendingMuxLink] = [:]

    /// Background task that periodically expires stale pending handshakes (started by
    /// ``start(port:)``, cancelled by ``stop()``). The deterministic test path calls
    /// ``reapExpiredPending(now:)`` directly instead of relying on this timer.
    private var reaperTask: Task<Void, Never>?

    /// - Parameters:
    ///   - handshakeTimeout: bound on the per-connection accept→handshake sequence
    ///     (default 10s, matching the client).
    ///   - pendingDataTimeout: bound on a CONTROL-only (half-open) handshake waiting for
    ///     its DATA channel (default 15s).
    public init(
        handshakeTimeout: Duration = .seconds(10),
        pendingDataTimeout: Duration = .seconds(15),
        muxEnabled: Bool = HostTransport.muxEnabledFromEnvironment()
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.pendingDataTimeout = pendingDataTimeout
        self.muxEnabled = muxEnabled
        self.clock = ContinuousClock()
        var continuation: AsyncStream<HostSessionTransport>.Continuation!
        self.sessionStream = AsyncStream { continuation = $0 }
        self.sessionContinuation = continuation
        var muxC: AsyncStream<MuxNWConnection>.Continuation!
        self.muxConnectionStream = AsyncStream { muxC = $0 }
        self.muxConnectionContinuation = muxC
    }

    /// The `RWORK_TCP_MUX` gate value from `env` (same parsing as the client
    /// ``ConnectionRegistry/muxEnabledFromEnvironment(_:)``). Default OFF.
    public static func muxEnabledFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = env["RWORK_TCP_MUX"]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    /// Newly-accepted SHARED mux connections (CONTROL+DATA paired into one ``MuxNWConnection``,
    /// role `.host`, receive loops started). The mux relay owner (the host daemon, gated on the
    /// same flag) consumes these, installs a per-channel-open handler, and spawns a PTY per channel.
    /// Only ever yields when ``muxEnabled`` is ON.
    public nonisolated var muxConnections_: AsyncStream<MuxNWConnection> { muxConnectionStream }

    /// Newly-accepted (NEW) sessions, each already associated (DATA + CONTROL) and
    /// ready to relay. A RETURNING_CLIENT reconnect rebinds the existing session
    /// object in place and is **not** re-yielded here.
    public nonisolated var sessions_: AsyncStream<HostSessionTransport> { sessionStream }

    /// The port the listener actually bound to. `nil` until ``start(port:)`` resolves.
    public private(set) var boundPort: UInt16?

    /// Starts listening on `port` (use `0` for an OS-assigned ephemeral port; read the
    /// result from ``boundPort``). Suspends until the listener is `.ready`.
    public func start(port: UInt16) async throws {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: TransportParameters.makeTCP(), on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.acceptConnection(connection) }
        }

        // Resolve the OS-assigned port through the continuation so it is set on the
        // actor synchronously *before* start() returns — no separate Task race.
        let resolvedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = ReadyBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let portValue = listener.port?.rawValue ?? port
                    box.tryResume { continuation.resume(returning: portValue) }
                case let .failed(error):
                    box.tryResume {
                        continuation.resume(throwing: RworkTransportError.listenerFailed(String(describing: error)))
                    }
                case .cancelled:
                    // A cancel during startup (e.g. stop() raced start()) is terminal —
                    // resume the continuation so start() does not hang on a dead listener.
                    box.tryResume {
                        continuation.resume(throwing: RworkTransportError.listenerFailed("cancelled during start"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        boundPort = resolvedPort

        // Start the background reaper that periodically expires half-open handshakes
        // (CONTROL completed, DATA never associated). It ticks at a fraction of the
        // timeout so an abandoned pending entry never lingers much past the bound. Tests
        // inject a tiny `pendingDataTimeout` and/or drive `reapExpiredPending(now:)`
        // directly, so they never wait on this wall-clock timer.
        startReaper()
    }

    /// Stops the listener and the reaper. Existing sessions keep their channels until
    /// closed.
    public func stop() {
        reaperTask?.cancel()
        reaperTask = nil
        listener?.cancel()
        listener = nil
        sessionContinuation.finish()
        muxConnectionContinuation.finish()
    }

    /// Launches the periodic reaper loop. Idempotent (a prior task is cancelled first).
    private func startReaper() {
        reaperTask?.cancel()
        // Tick at a quarter of the timeout (clamped to a small floor) so expiry latency
        // is bounded without busy-spinning.
        let tick = max(pendingDataTimeout / 4, .milliseconds(50))
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: tick)
                } catch {
                    return // cancelled
                }
                guard let self else { return }
                await self.reapExpiredPending(now: self.clockNow())
            }
        }
    }

    /// The current monotonic instant from the (production) clock. Isolated read so the
    /// reaper task can stamp `now` for ``reapExpiredPending(now:)``.
    private func clockNow() -> ContinuousClock.Instant { clock.now }

    /// Drops a session from the map and tears down its channels + forwarder tasks.
    ///
    /// Used by the owner (WF-3 `HostServer`) when a NEW session was already bound and
    /// published but its shell failed to spawn — without this the orphaned
    /// `HostSessionTransport` would linger in the map with live forwarders and an open
    /// data + control connection behind no shell (a connection/actor leak). No-op if the
    /// id is unknown.
    public func dropSession(_ id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.close()
    }

    // MARK: Half-open pending reaper

    /// Expires every pending (CONTROL-only) handshake whose DATA channel has not
    /// associated within ``pendingDataTimeout`` as measured from its `createdAt`. For
    /// each expired entry: remove it from `pending` and close its control channel so the
    /// leaked `NWMessageChannel` + connection are released.
    ///
    /// Driven by the background reaper task in production; called directly by tests with
    /// a synthesized `now` so the behaviour is verified WITHOUT any wall-clock sleep.
    /// `internal` (not `public`) — it is a test/seam hook, not part of the daemon API.
    func reapExpiredPending(now: ContinuousClock.Instant) {
        for (id, entry) in pending.filter({ now - $0.value.createdAt > pendingDataTimeout }) {
            pending[id] = nil
            // Close on a detached actor-hop: `close()` cancels the NWConnection, which is
            // fine to fire-and-forget here (the entry is already removed, so no double
            // close, and a returning-client reuse can no longer race it).
            Task { await entry.control.close() }
        }
        // Same half-open hazard for shared-mux sockets: a CONTROL (or DATA) mux socket whose
        // partner never arrives would leak its NWConnection forever (a hostile peer could open
        // many CONTROL-only mux sockets with distinct connectionIDs as a DoS). Expire stale
        // half-paired mux links past the same deadline, closing whichever side is parked.
        for (id, entry) in pendingMux.filter({ now - $0.value.createdAt > pendingDataTimeout }) {
            pendingMux[id] = nil
            if let control = entry.control { Task { await control.close() } }
            if let data = entry.data { Task { await data.close() } }
        }
    }

    /// Test seam: the number of half-open handshakes currently awaiting their DATA
    /// channel. Lets a test assert the pending map empties after a reap.
    func pendingCount() -> Int { pending.count }

    /// Test seam: whether a specific id is still pending (DATA not yet associated).
    func isPending(_ id: UUID) -> Bool { pending[id] != nil }

    /// Test seam: a monotonic instant guaranteed to be past every current pending
    /// entry's expiry deadline. A test passes this to ``reapExpiredPending(now:)`` to
    /// force expiry deterministically — no wall-clock sleep, no guessing `createdAt`.
    func instantPastAllPendingDeadlines() -> ContinuousClock.Instant {
        // Every pending entry was created at <= clock.now; advancing well past the
        // timeout from *now* therefore exceeds `createdAt + pendingDataTimeout` for all.
        clock.now.advanced(by: pendingDataTimeout + pendingDataTimeout)
    }

    /// Test seam: the current monotonic instant from the actor's clock — a value strictly
    /// AT-OR-AFTER every current pending entry's `createdAt`. A test passes this to
    /// ``reapExpiredPending(now:)`` to assert a young entry is NOT reaped before its
    /// deadline.
    func instantNowForTest() -> ContinuousClock.Instant { clock.now }

    // MARK: Accept + handshake

    private func acceptConnection(_ connection: NWConnection) {
        // Each new connection is handshaked independently; failures are isolated. The
        // whole sequence is bounded by `handshakeTimeout` (symmetric with the client):
        // a connection that opens but stalls before/within the handshake (never sends a
        // preamble or hello) must not park this Task + its NWConnection forever. We race
        // the handshake against a single sleep; whichever finishes first wins, and on a
        // timeout (or any error) we cancel the connection so nothing leaks.
        Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.handshake(connection)
                    }
                    group.addTask {
                        try await Task.sleep(for: self.handshakeTimeout)
                        throw RworkTransportError.timedOut("host handshake")
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private func handshake(_ connection: NWConnection) async throws {
        let connQueue = DispatchQueue(label: "rwork.host.conn")
        try await connection.startAndWaitReady(on: connQueue)

        // Read the 1-byte discriminator.
        let tagByte = try await connection.receiveExactly(1)
        let tag = tagByte.first

        switch tag {
        case ChannelAssociation.controlTag:
            try await handshakeControl(connection)
        case ChannelAssociation.dataTag:
            // DATA preamble also carries the 16-byte sessionID.
            let idBytes = try await connection.receiveExactly(ChannelAssociation.sessionIDByteCount)
            guard let sessionID = UUID(dataBytesForAssociation: idBytes) else {
                throw RworkTransportError.handshakeFailed("data preamble: bad sessionID")
            }
            try await associateData(connection, sessionID: sessionID)
        case ChannelAssociation.muxControlTag where muxEnabled:
            // Shared-mux CONTROL socket: read the pairing connectionID, then pair with its DATA peer.
            let idBytes = try await connection.receiveExactly(ChannelAssociation.sessionIDByteCount)
            guard let connectionID = UUID(dataBytesForAssociation: idBytes) else {
                throw RworkTransportError.handshakeFailed("mux control preamble: bad connectionID")
            }
            associateMux(connection, connectionID: connectionID, isControl: true)
        case ChannelAssociation.muxDataTag where muxEnabled:
            let idBytes = try await connection.receiveExactly(ChannelAssociation.sessionIDByteCount)
            guard let connectionID = UUID(dataBytesForAssociation: idBytes) else {
                throw RworkTransportError.handshakeFailed("mux data preamble: bad connectionID")
            }
            associateMux(connection, connectionID: connectionID, isControl: false)
        default:
            // A mux tag with the gate OFF lands here too (the `where muxEnabled` cases do not match)
            // — byte-identical to the pre-mux host, which never knew these tags.
            throw RworkTransportError.handshakeFailed("unknown association tag \(String(describing: tag))")
        }
    }

    /// Pairs the two physical mux sockets (CONTROL + DATA) that share `connectionID` into ONE
    /// shared ``MuxNWConnection`` (role `.host`), starts its receive loops, and yields it on
    /// ``muxConnections_`` for the gated mux relay owner. The first socket to arrive parks in
    /// `pendingMux`; the second completes the pair. Gate-only path — never reached when OFF.
    private func associateMux(_ connection: NWConnection, connectionID: UUID, isControl: Bool) {
        let link = NWMuxByteLink(connection: connection, label: isControl ? "host.control" : "host.data")
        let existing = pendingMux[connectionID]
        let control = isControl ? link : existing?.control
        let data = isControl ? existing?.data : link
        if let control, let data {
            pendingMux[connectionID] = nil
            // Carry the wire `connectionID` onto the shared connection so the mux relay owner can
            // namespace its per-channel sessions by (connectionID, channelID) — see
            // `HostServer.muxSessions` / `MuxSessionKey`. Two distinct clients each allocate
            // channelID 1 for their first pane, so a channelID-only key cross-resolved sessions.
            // S2 sub-gate: the host reads `RWORK_TCP_MUX_FLOW` ONCE here (alongside the
            // `RWORK_TCP_MUX` gate the handshake already enforced to reach this mux path). BOTH ends
            // must agree; OFF → infinite window (byte-identical to S1).
            let mux = MuxNWConnection(
                role: .host,
                controlLink: control,
                dataLink: data,
                connectionID: connectionID,
                flowControl: MuxFlowControl.flowEnabledFromEnvironment()
            )
            Task {
                await mux.start()
                muxConnectionContinuation.yield(mux)
            }
        } else {
            pendingMux[connectionID] = PendingMuxLink(control: control, data: data, createdAt: clock.now)
        }
    }

    private func handshakeControl(_ connection: NWConnection) async throws {
        let control = NWMessageChannel(connection: connection, channel: .control)
        await control.start()

        // Await the client's hello (the first inbound control message). We read exactly
        // one message and break; the session's forwarder (started in
        // `HostSessionTransport.rebind`) becomes the channel's *next* and only
        // consumer. `AsyncThrowingStream` shares one buffer across sequential
        // iterators, so any `resize`/`ack`/`bye` that arrives after `hello` is buffered
        // and delivered to that forwarder — nothing is dropped in the handoff.
        var helloMessage: WireMessage?
        for try await message in control.inbound {
            helloMessage = message
            break
        }
        guard case let .hello(version, requestedID, lastReceivedSeq)? = helloMessage else {
            throw RworkTransportError.handshakeFailed("expected hello, got \(String(describing: helloMessage))")
        }
        guard version == Rwork.protocolVersion else {
            throw RworkTransportError.handshakeFailed("protocol version \(version) != \(Rwork.protocolVersion)")
        }

        // SERVER decides NEW vs RETURNING_CLIENT.
        let isReturning = requestedID != WireMessage.newSessionID && sessions[requestedID] != nil
        let authoritativeID = isReturning ? requestedID : UUID()
        let resumeFromSeq: Int64 = isReturning ? lastReceivedSeq : 0

        // Reply helloAck on the control channel.
        try await control.send(.helloAck(
            sessionID: authoritativeID,
            resumeFromSeq: resumeFromSeq,
            returningClient: isReturning
        ))

        pending[authoritativeID] = PendingControl(
            control: control,
            lastReceivedSeq: lastReceivedSeq,
            returningClient: isReturning,
            createdAt: clock.now
        )
    }

    private func associateData(_ connection: NWConnection, sessionID: UUID) async throws {
        guard let pendingControl = pending[sessionID] else {
            throw RworkTransportError.handshakeFailed("data for unknown/incomplete session \(sessionID)")
        }
        pending[sessionID] = nil

        let data = NWMessageChannel(connection: connection, channel: .data)
        await data.start()
        try await data.waitUntilReady()

        if pendingControl.returningClient, let existing = sessions[sessionID] {
            // RETURNING_CLIENT: atomically rebind the fresh channels and replay the
            // missing tail (then flush live output) in strictly ascending seq order.
            try await existing.resume(
                data: data,
                control: pendingControl.control,
                after: pendingControl.lastReceivedSeq
            )
            // Not re-yielded: the relay is already attached to `existing`.
        } else {
            // NEW session: create, bind, publish for the relay to attach a PTY.
            let session = HostSessionTransport(sessionID: sessionID)
            sessions[sessionID] = session
            await session.bind(data: data, control: pendingControl.control)
            sessionContinuation.yield(session)
        }
    }
}

/// Resume an existing session id, so a reconnect's data preamble can be associated.
/// Exposed for tests/owners that need to know which ids are live.
public extension HostTransport {
    /// Whether a session with `id` is currently tracked (for diagnostics/tests).
    func hasSession(_ id: UUID) -> Bool { sessions[id] != nil }
}

/// A tiny thread-safe latch so a listener/connection state handler resumes a
/// continuation exactly once.
final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func tryResume(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}

extension UUID {
    /// Builds a UUID from exactly 16 raw association bytes (canonical order).
    init?(dataBytesForAssociation data: Data) {
        guard data.count == 16 else { return nil }
        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { dest in
            _ = data.copyBytes(to: dest)
        }
        self.init(uuid: raw)
    }
}
