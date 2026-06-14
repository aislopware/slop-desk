import AislopdeskProtocol
import Foundation
import Network

/// Host side of the Aislopdesk transport: an `NWListener` that accepts the shared-mux (CONTROL + DATA)
/// TCP socket pairs, pairs the two physical connections by their preamble `connectionID` into one
/// ``MuxNWConnection``, and surfaces them on ``muxConnections`` for the mux relay owner.
///
/// ## Handshake (shared-mux pairing)
/// 1. A new connection arrives; the listener reads the 1-byte association preamble.
/// 2. **MUX CONTROL** (`0x03`) / **MUX DATA** (`0x04`): each carries a 16-byte `connectionID`. The
///    first socket to arrive parks in `pendingMux`; the second with the same id completes the pair.
///    Once both are present they are wrapped into one ``MuxNWConnection`` (role `.host`), the
///    receive loops are started, and it is yielded on ``muxConnections``.
///
/// Each pane on a shared connection is a logical channel (SSH-style), opened via `channelOpen`; the
/// per-channel PTY relay (``AislopdeskHost/MuxChannelSession``) is owned by the relay owner, not here.
///
/// All mutable state (the pending half-pair map) lives inside this `actor`. No `@unchecked Sendable`.
public actor HostTransport {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "aislopdesk.host.listener")

    /// Bounded wait for the whole accept→handshake sequence on a single connection,
    /// symmetric with the client's `handshakeTimeout`. Without it, a connection that
    /// stalls mid-handshake (never sends its preamble) parks a detached `handshake()`
    /// Task and its `NWConnection` forever.
    let handshakeTimeout: Duration

    /// How long a half-paired mux link (one of the CONTROL/DATA pair arrived, the other never did)
    /// may linger before the reaper closes it and drops the pending entry. Guards the
    /// iOS-background / NetBird-flap case where the partner socket never arrives. Injectable (tiny
    /// values) so tests drive it without wall-clock sleeps; default 15s.
    let pendingDataTimeout: Duration

    /// Clock used for pending-entry expiry. Injectable so a test can stamp + drive the
    /// reaper deterministically; production uses the real ``ContinuousClock``.
    private let clock: ContinuousClock

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

    /// Set by ``stop()`` (R9 #5). After stop, an in-flight handshake that completes a mux pair must NOT
    /// be yielded (the stream is finished → the mux + its 2 sockets would leak, unseen by
    /// `HostServer.drainMuxConnections`), and a newly-arrived first link must NOT be parked in
    /// `pendingMux` (already drained). `associateMux` closes such links immediately instead.
    private var stopped = false

    /// Background task that periodically expires stale pending half-pairs (started by
    /// ``start(port:)``, cancelled by ``stop()``). The deterministic test path calls
    /// ``reapExpiredPending(now:)`` directly instead of relying on this timer.
    private var reaperTask: Task<Void, Never>?

    /// - Parameters:
    ///   - handshakeTimeout: bound on the per-connection accept→handshake sequence
    ///     (default 10s, matching the client).
    ///   - pendingDataTimeout: bound on a half-paired mux link waiting for its partner (default 15s).
    public init(
        handshakeTimeout: Duration = .seconds(10),
        pendingDataTimeout: Duration = .seconds(15),
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.pendingDataTimeout = pendingDataTimeout
        clock = ContinuousClock()
        let (muxStream, muxCont) = AsyncStream.makeStream(of: MuxNWConnection.self)
        muxConnectionStream = muxStream
        muxConnectionContinuation = muxCont
    }

    /// Newly-accepted SHARED mux connections (CONTROL+DATA paired into one ``MuxNWConnection``,
    /// role `.host`, receive loops started). The mux relay owner (the host daemon) consumes these,
    /// installs a per-channel-open handler, and spawns a PTY per channel.
    public nonisolated var muxConnections: AsyncStream<MuxNWConnection> { muxConnectionStream }

    /// The port the listener actually bound to. `nil` until ``start(port:)`` resolves.
    public private(set) var boundPort: UInt16?

    /// Starts listening on `port` (use `0` for an OS-assigned ephemeral port; read the
    /// result from ``boundPort``). Suspends until the listener is `.ready`.
    ///
    /// - Parameters:
    ///   - readinessTimeout: a bound on reaching `.ready` (R15 #3). `NWListener` can park in
    ///     `.waiting` (no network at login, DHCP not yet up) and never resolve; without a bound the
    ///     `withCheckedThrowingContinuation` below would suspend `start()` forever, wedging the host
    ///     (the menu-bar app's Start spinner never clears, every escape control disabled). On expiry
    ///     `start()` throws ``AislopdeskTransportError/timedOut(_:)`` so the caller can recover. 10s is far
    ///     beyond a real local bind (milliseconds), so it never false-positives the healthy path.
    ///   - onListenerFailed: surfaced when the listener fails AFTER it became ready (R15 #2) — a
    ///     post-bind interface drop / socket error. The continuation resolves on the FIRST
    ///     ready/failed, so a LATER failure otherwise vanishes and a long-lived host keeps showing
    ///     "running" while silently accepting nothing. Additive + defaulted nil: the headless daemon
    ///     is unaffected. A deliberate `stop()` (`.cancelled`) is NOT a failure and never fires it.
    @preconcurrency
    public func start(
        port: UInt16,
        readinessTimeout: Duration = .seconds(10),
        onListenerFailed: (@Sendable (AislopdeskTransportError) -> Void)? = nil,
    ) async throws {
        // NOTE (R10 self-audit): do NOT reset `stopped` here. A `HostTransport` is SINGLE-USE — `stop()`
        // permanently `finish()`es `muxConnectionContinuation`, so even a fresh listener after stop would
        // yield accepted muxes into a dead stream (the relay owner never sees them → leak). Resetting
        // `stopped` would falsely advertise restart support and ACCEPT-then-leak instead of refusing.
        // Production restarts by building a FRESH `HostTransport` per Start (`HostServer.init`), so the
        // single-use invariant holds; a reused instance stays `stopped` and `associateMux` refuses
        // (fail-safe: closes the connection rather than orphaning it).
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
            // R15 #3: bound the wait for `.ready`. A listener stuck in `.waiting` (no network at login,
            // DHCP not up) would otherwise never resume this continuation. The timer resume-throws; it
            // is cancelled the instant a terminal state (ready/failed/cancelled) resolves the box.
            let timeoutTask = Task {
                try? await Task.sleep(for: readinessTimeout)
                guard !Task.isCancelled else { return }
                box.tryResume {
                    continuation.resume(throwing: AislopdeskTransportError.timedOut("listener readiness"))
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutTask.cancel()
                    let portValue = listener.port?.rawValue ?? port
                    box.tryResume { continuation.resume(returning: portValue) }
                case let .failed(error):
                    timeoutTask.cancel()
                    let err = AislopdeskTransportError.listenerFailed(String(describing: error))
                    if box.hasResumed {
                        // R15 #2: the continuation already resolved on `.ready` — this is a POST-bind
                        // failure (interface drop / socket error). Surface it as a health signal so a
                        // long-lived host can re-classify "running" → "failed" instead of silently
                        // accepting nothing. (Resuming again here would be a no-op via the box anyway.)
                        onListenerFailed?(err)
                    } else {
                        box.tryResume { continuation.resume(throwing: err) }
                    }
                case .cancelled:
                    // A cancel during startup (e.g. stop() raced start()) is terminal — resume the
                    // continuation so start() does not hang on a dead listener. A POST-ready `.cancelled`
                    // is the DELIBERATE stop() path (`listener.cancel()`) → the box no-ops the resume and
                    // we do NOT fire onListenerFailed (it is not a failure).
                    timeoutTask.cancel()
                    box.tryResume {
                        continuation.resume(throwing: AislopdeskTransportError.listenerFailed("cancelled during start"))
                    }
                case let .waiting(error):
                    // `.waiting` is normally the framework's RETRYABLE "no usable network path yet" state
                    // (DHCP not up, Wi-Fi joining); it auto-recovers to `.ready` once a path appears, so we
                    // keep waiting — the readiness timeout bounds a genuinely stuck transient. The ONE
                    // exception is a bind conflict: on some OS versions an already-in-use port surfaces as a
                    // STUCK `.waiting(.posix(.EADDRINUSE))` that never reaches `.failed` and never
                    // auto-recovers (another process owns the port). For that single errno, resolve NOW as a
                    // port-in-use failure instead of burning the full readiness timeout and then
                    // mis-reporting a generic "timed out". On the common macOS path the `.waiting` flash
                    // carries ENETDOWN (not EADDRINUSE) and the real `.failed(EADDRINUSE)` lands right after,
                    // so this branch no-ops there and `.failed` handles it. (Pure decision in
                    // `AislopdeskTransportError.waitingErrnoIsFatalBindConflict`, unit-tested.)
                    if case let .posix(code) = error,
                       AislopdeskTransportError.waitingErrnoIsFatalBindConflict(code.rawValue)
                    {
                        timeoutTask.cancel()
                        let err = AislopdeskTransportError.listenerFailed(String(describing: error))
                        if box.hasResumed {
                            onListenerFailed?(err) // post-ready stuck-waiting bind conflict (rare): health signal
                        } else {
                            box.tryResume { continuation.resume(throwing: err) }
                        }
                    }
                // Any other waiting errno: keep waiting; the readiness timeout bounds it.
                default:
                    break // .setup (and any future state): keep waiting; the readiness timeout bounds it
                }
            }
            listener.start(queue: queue)
        }
        boundPort = resolvedPort

        // Start the background reaper that periodically expires stale half-paired mux links. It
        // ticks at a fraction of the timeout so an abandoned pending entry never lingers much past
        // the bound. Tests inject a tiny `pendingDataTimeout` and/or drive `reapExpiredPending(now:)`
        // directly, so they never wait on this wall-clock timer.
        startReaper()
    }

    /// Stops the listener and the reaper. Existing connections keep their channels until closed.
    public func stop() {
        stopped = true
        reaperTask?.cancel()
        reaperTask = nil
        listener?.cancel()
        listener = nil
        // R9 #5: drain + close every half-paired link parked in pendingMux. Otherwise a client whose
        // CONTROL socket arrived but whose DATA never did (a Start→Stop before DATA, or a NetBird flap)
        // abandons a live NWConnection on every cycle → fd exhaustion on the long-lived menu-bar host
        // (the pre-pairing analogue of the R5 rank-3 accepted-connection leak).
        for (id, entry) in pendingMux {
            pendingMux[id] = nil
            if let control = entry.control { Task { await control.close() } }
            if let data = entry.data { Task { await data.close() } }
        }
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
                await reapExpiredPending(now: clockNow())
            }
        }
    }

    /// The current monotonic instant from the (production) clock. Isolated read so the
    /// reaper task can stamp `now` for ``reapExpiredPending(now:)``.
    private func clockNow() -> ContinuousClock.Instant { clock.now }

    // MARK: Half-paired mux reaper

    /// Expires every half-paired mux link whose partner has not arrived within ``pendingDataTimeout``
    /// as measured from its `createdAt`, closing whichever side is parked so the leaked NWConnection
    /// is released. A hostile peer could open many CONTROL-only mux sockets with distinct
    /// connectionIDs as a DoS; this bounds the leak.
    ///
    /// Driven by the background reaper task in production; called directly by tests with
    /// a synthesized `now` so the behaviour is verified WITHOUT any wall-clock sleep.
    /// `internal` (not `public`) — it is a test/seam hook, not part of the daemon API.
    func reapExpiredPending(now: ContinuousClock.Instant) {
        for (id, entry) in pendingMux.filter({ now - $0.value.createdAt > pendingDataTimeout }) {
            pendingMux[id] = nil
            if let control = entry.control { Task { await control.close() } }
            if let data = entry.data { Task { await data.close() } }
        }
    }

    /// Test seam: the number of half-paired mux links currently awaiting their partner.
    func pendingCount() -> Int { pendingMux.count }

    /// Test seam: whether a specific connectionID is still half-paired (partner not yet arrived).
    func isPending(_ id: UUID) -> Bool { pendingMux[id] != nil }

    /// Test seam: a monotonic instant guaranteed to be past every current pending entry's expiry
    /// deadline. A test passes this to ``reapExpiredPending(now:)`` to force expiry deterministically.
    func instantPastAllPendingDeadlines() -> ContinuousClock.Instant {
        clock.now.advanced(by: pendingDataTimeout + pendingDataTimeout)
    }

    /// Test seam: the current monotonic instant from the actor's clock — at-or-after every current
    /// pending entry's `createdAt`. A test passes this to assert a young entry is NOT reaped early.
    func instantNowForTest() -> ContinuousClock.Instant { clock.now }

    // MARK: Accept + handshake

    private func acceptConnection(_ connection: NWConnection) {
        // Each new connection is handshaked independently; failures are isolated. The
        // whole sequence is bounded by `handshakeTimeout` (symmetric with the client):
        // a connection that opens but stalls before/within the handshake (never sends a
        // preamble) must not park this Task + its NWConnection forever. We race the
        // handshake against a single sleep; whichever finishes first wins, and on a
        // timeout (or any error) we cancel the connection so nothing leaks.
        Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.handshake(connection)
                    }
                    group.addTask {
                        try await Task.sleep(for: self.handshakeTimeout)
                        throw AislopdeskTransportError.timedOut("host handshake")
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
        let connQueue = DispatchQueue(label: "aislopdesk.host.conn")
        try await connection.startAndWaitReady(on: connQueue)

        // Read the 1-byte discriminator.
        let tagByte = try await connection.receiveExactly(1)
        let tag = tagByte.first

        switch tag {
        case ChannelAssociation.muxControlTag:
            // Shared-mux CONTROL socket: read the pairing connectionID, then pair with its DATA peer.
            let idBytes = try await connection.receiveExactly(ChannelAssociation.sessionIDByteCount)
            guard let connectionID = UUID(dataBytesForAssociation: idBytes) else {
                throw AislopdeskTransportError.handshakeFailed("mux control preamble: bad connectionID")
            }
            associateMux(connection, connectionID: connectionID, isControl: true)
        case ChannelAssociation.muxDataTag:
            let idBytes = try await connection.receiveExactly(ChannelAssociation.sessionIDByteCount)
            guard let connectionID = UUID(dataBytesForAssociation: idBytes) else {
                throw AislopdeskTransportError.handshakeFailed("mux data preamble: bad connectionID")
            }
            associateMux(connection, connectionID: connectionID, isControl: false)
        default:
            throw AislopdeskTransportError.handshakeFailed("unknown association tag \(String(describing: tag))")
        }
    }

    /// Pairs the two physical mux sockets (CONTROL + DATA) that share `connectionID` into ONE
    /// shared ``MuxNWConnection`` (role `.host`), starts its receive loops, and yields it on
    /// ``muxConnections`` for the mux relay owner. The first socket to arrive parks in `pendingMux`;
    /// the second completes the pair.
    private func associateMux(_ connection: NWConnection, connectionID: UUID, isControl: Bool) {
        let link = NWMuxByteLink(connection: connection, label: isControl ? "host.control" : "host.data")
        // R9 #5: after stop(), do NOT pair (yielding to the finished stream leaks the mux's 2 sockets)
        // or park (pendingMux is drained). Close this just-arrived link + any half-pair immediately.
        guard !stopped else {
            Task { await link.close() }
            if let existing = pendingMux.removeValue(forKey: connectionID) {
                if let control = existing.control { Task { await control.close() } }
                if let data = existing.data { Task { await data.close() } }
            }
            return
        }
        let existing = pendingMux[connectionID]
        let control = isControl ? link : existing?.control
        let data = isControl ? existing?.data : link
        if let control, let data {
            pendingMux[connectionID] = nil
            // Carry the wire `connectionID` onto the shared connection so the mux relay owner can
            // namespace its per-channel sessions by (connectionID, channelID) — see
            // `HostServer.muxSessions` / `MuxSessionKey`. Two distinct clients each allocate
            // channelID 1 for their first pane, so a channelID-only key cross-resolved sessions.
            let mux = MuxNWConnection(
                role: .host,
                controlLink: control,
                dataLink: data,
                connectionID: connectionID,
            )
            Task {
                await mux.start()
                // R11 (completes R9 #5): the `guard !stopped` above only rejects a link that ARRIVES
                // after stop(). A pair that PASSED the guard still spawns this Task, and stop() can run
                // during the `await mux.start()` suspension — finishing the stream. A yield into a
                // finished AsyncStream is silently dropped (`.terminated`), orphaning this fully-started
                // mux and its TWO live sockets (never seen by `HostServer.drainMuxConnections`, never
                // closed → fd leak per Start→Stop race). Detect the terminated stream and close the mux.
                if case .terminated = muxConnectionContinuation.yield(mux) {
                    await mux.close()
                }
            }
        } else {
            // A same-side duplicate preamble (e.g. two CONTROL sockets for one connectionID before the
            // DATA peer arrives) must NOT silently overwrite the parked half-pair: the previously-parked
            // NWMuxByteLink owns a live NWConnection/fd that the reaper only ever sees via the CURRENT map
            // entry, so the displaced link would leak its fd — and a peer re-sending the same side
            // repeatedly leaks one per duplicate AND restamps createdAt, pushing the reaper deadline out.
            // The pure, unit-tested ``MuxPairing`` decides whether this re-park displaces a same-side
            // half; if so close it, and preserve the original createdAt so the reaper deadline cannot be
            // deferred (R12 #2). On the genuine first arrival (existing == nil) nothing is displaced and
            // createdAt falls through to now.
            let decision = MuxPairing.decide(
                existingHasControl: existing?.control != nil,
                existingHasData: existing?.data != nil,
                isControl: isControl,
            )
            if decision.closesDisplacedSameSide, let replaced = isControl ? existing?.control : existing?.data {
                Task { await replaced.close() }
            }
            pendingMux[connectionID] = PendingMuxLink(
                control: control, data: data, createdAt: existing?.createdAt ?? clock.now,
            )
        }
    }
}

/// The pure pairing decision for a just-arrived mux half-link, given the currently-parked half (if
/// any) and which side arrived. Extracted so the duplicate-same-side fd-leak guard (R12 #2) is
/// unit-testable without a real `NWConnection`: the two physical mux sockets (CONTROL + DATA) sharing
/// one connectionID pair into one ``MuxNWConnection``; the first to arrive parks, the second completes
/// the pair. A SECOND socket for a side that is ALREADY parked (two CONTROLs, or two DATAs, before the
/// opposite peer shows) must NOT silently overwrite the parked half — the displaced link owns a live
/// fd the reaper only sees via the current map entry, so it must be closed.
enum MuxPairing {
    struct Decision: Equatable {
        /// Both sides are now present — build the shared connection.
        var paired: Bool
        /// A re-park is displacing an already-parked SAME-SIDE half that must be `close()`d.
        var closesDisplacedSameSide: Bool
    }

    static func decide(existingHasControl: Bool, existingHasData: Bool, isControl: Bool) -> Decision {
        let controlPresent = isControl ? true : existingHasControl
        let dataPresent = isControl ? existingHasData : true
        if controlPresent, dataPresent {
            return Decision(paired: true, closesDisplacedSameSide: false)
        }
        // Re-park: the half on the arriving side displaces whatever was already parked on that side.
        let displacedPresent = isControl ? existingHasControl : existingHasData
        return Decision(paired: false, closesDisplacedSameSide: displacedPresent)
    }
}

/// A tiny thread-safe latch so a listener/connection state handler resumes a
/// continuation exactly once.
final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func tryResume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }

    /// Whether the continuation has already been resumed. The listener handler reads this to tell a
    /// POST-ready `.failed` (start() already returned → surface a health signal) from a pre-ready one
    /// (resume start() throwing).
    var hasResumed: Bool { lock.lock()
        defer { lock.unlock() }
        return resumed
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
