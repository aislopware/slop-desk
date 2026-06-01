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
    }
    private var pending: [UUID: PendingControl] = [:]

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rwork.host.listener")

    // New sessions are published here for the owner (WF-3) to attach a PTY to.
    private let sessionStream: AsyncStream<HostSessionTransport>
    private let sessionContinuation: AsyncStream<HostSessionTransport>.Continuation

    public init() {
        var continuation: AsyncStream<HostSessionTransport>.Continuation!
        self.sessionStream = AsyncStream { continuation = $0 }
        self.sessionContinuation = continuation
    }

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
    }

    /// Stops the listener. Existing sessions keep their channels until closed.
    public func stop() {
        listener?.cancel()
        listener = nil
        sessionContinuation.finish()
    }

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

    // MARK: Accept + handshake

    private func acceptConnection(_ connection: NWConnection) {
        // Each new connection is handshaked independently; failures are isolated.
        Task {
            do {
                try await self.handshake(connection)
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
        default:
            throw RworkTransportError.handshakeFailed("unknown association tag \(String(describing: tag))")
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
            returningClient: isReturning
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
