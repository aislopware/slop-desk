import Foundation
import Network
import RworkProtocol

/// Client side of the Rwork transport: opens the CONTROL + DATA TCP connections,
/// performs the `hello`/`helloAck` handshake, associates the two physical
/// connections to one logical session, and exposes thin inbound/outbound APIs.
///
/// It is intentionally **thin**: WF-4 (`RworkClient`) wires keystrokes to
/// ``sendInput(_:)`` and renders the ``inbound`` stream; no terminal/PTY logic lives
/// here. Reconnect *policy* (backoff, lifecycle) belongs to WF-4 — this type provides
/// the resume-correct handshake hook (``connect(host:port:resume:lastReceivedSeq:)``)
/// so a reconnect is just another `connect` carrying the prior `sessionID` +
/// `lastReceivedSeq`.
///
/// All mutable state lives inside this `actor`. No `@unchecked Sendable`.
public actor ClientTransport {
    /// Inbound host→client events the client cares about: `output`/`exit`/`title`/`bell`.
    /// (`output` carries the seq the client must track for ack + reconnect.) The
    /// `helloAck` handshake reply is consumed internally and is **not** yielded here.
    public typealias Inbound = AsyncThrowingStream<WireMessage, Error>

    /// The authoritative session id learned from `helloAck`. `nil` until connected.
    public private(set) var sessionID: UUID?
    /// The seq the host replayed from in the most recent `helloAck`.
    public private(set) var resumeFromSeq: Int64 = 0
    /// Whether the host treated the most recent connect as a returning client.
    public private(set) var returningClient = false

    private var connection: RworkConnection?
    private var dataChannel: NWMessageChannel?
    private var controlChannel: NWMessageChannel?

    private let inboundStream: Inbound
    private let inboundContinuation: Inbound.Continuation

    /// Forwarding tasks that pump each channel's inbound stream into the merged
    /// ``inbound``. Held so they can be cancelled on ``close()``.
    private var forwarders: [Task<Void, Never>] = []

    /// One-shot waiter for the `helloAck`, resumed by the control forwarder when the
    /// reply arrives. Cleared once resumed.
    private var helloAckWaiter: CheckedContinuation<WireMessage, Error>?
    /// Set true once the helloAck has been delivered to the waiter (so later control
    /// messages are forwarded, not intercepted).
    private var helloAckDelivered = false

    public init() {
        var continuation: Inbound.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    /// Merged inbound stream of host→client messages (data: `output`/`exit`;
    /// control: `title`/`bell`). The caller tracks `output.seq` and acks.
    public nonisolated var inbound: Inbound { inboundStream }

    // MARK: Connect / handshake

    /// Connects to `host:port` and performs the full handshake.
    ///
    /// - Parameters:
    ///   - resume: an existing session id to resume, or ``WireMessage/newSessionID``
    ///     for a fresh session.
    ///   - lastReceivedSeq: the highest contiguous output seq already received (0 for a
    ///     new session). The host replays `output` with `seq > lastReceivedSeq`.
    ///   - handshakeTimeout: bounded wait for readiness + `helloAck`.
    ///
    /// On success the merged ``inbound`` stream begins yielding; resumed-tail `output`
    /// arrives first (the host replays before resuming live streaming).
    public func connect(
        host: String,
        port: UInt16,
        resume: UUID = WireMessage.newSessionID,
        lastReceivedSeq: Int64 = 0,
        handshakeTimeout: Duration = .seconds(10)
    ) async throws {
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let endpointHost = NWEndpoint.Host(host)

        // The whole readiness + handshake sequence is bounded by `handshakeTimeout`.
        // Network.framework parks a connection to an unreachable/refused endpoint in
        // `.waiting` indefinitely (waitForConnectivity), so wrapping ONLY `awaitHelloAck`
        // would still let `startAndWaitReady` wedge forever. Racing the entire sequence
        // against a single sleep gives the documented bounded guarantee. On any failure
        // (timeout or error) we tear down the control channel/connection we opened so we
        // never leak an open NWConnection or a parked `helloAckWaiter`.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: handshakeTimeout)
                    throw RworkTransportError.timedOut("handshake")
                }
                group.addTask { [weak self] in
                    guard let self else { throw RworkTransportError.invalidState("client deinit") }
                    try await self.performConnect(
                        endpointHost: endpointHost,
                        endpointPort: endpointPort,
                        resume: resume,
                        lastReceivedSeq: lastReceivedSeq
                    )
                }
                // Wait for the first child to finish. If the handshake child wins it
                // returns Void (success); if the timeout child wins it throws.
                try await group.next()
                group.cancelAll()
            }
        } catch {
            // Handshake failed/timed out: resume any parked waiter, then tear down the
            // control channel + connection we opened (the data channel is only created
            // after a successful handshake, so it is handled by `performConnect`'s own
            // failure path / left untouched here).
            failHelloAckIfWaiting(error)
            await teardownAfterFailedHandshake()
            throw error
        }
    }

    /// The actual readiness + handshake steps, run as a child of the bounded task group
    /// in ``connect(host:port:resume:lastReceivedSeq:handshakeTimeout:)`` so a stuck
    /// readiness or a missing `helloAck` cannot wedge the caller past the timeout.
    private func performConnect(
        endpointHost: NWEndpoint.Host,
        endpointPort: NWEndpoint.Port,
        resume: UUID,
        lastReceivedSeq: Int64
    ) async throws {
        // 1. CONTROL connection: open, send control preamble.
        let controlConn = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
        try await controlConn.startAndWaitReady(on: DispatchQueue(label: "rwork.client.control"))
        try await controlConn.sendRaw(ChannelAssociation.controlPreamble())

        let control = NWMessageChannel(connection: controlConn, channel: .control)
        await control.start()
        // Retain the control channel immediately so a timeout/cancel teardown (or
        // close() during the in-flight handshake) can close it.
        self.controlChannel = control

        // 2. Arm the SINGLE control forwarder BEFORE sending hello so we cannot miss the
        //    reply. It intercepts the first `helloAck` (resumes `helloAckWaiter`) and
        //    forwards every other control message into the merged inbound. The control
        //    inbound stream is therefore consumed exactly once (no double-iterator).
        helloAckDelivered = false
        startControlForwarding(from: control)

        // 3. Send hello and await helloAck.
        try await control.send(.hello(
            protocolVersion: Rwork.protocolVersion,
            sessionID: resume,
            lastReceivedSeq: lastReceivedSeq
        ))
        let ack = try await suspendForHelloAck()
        guard case let .helloAck(authoritativeID, resumeSeq, returning) = ack else {
            throw RworkTransportError.handshakeFailed("expected helloAck, got \(ack)")
        }
        self.sessionID = authoritativeID
        self.resumeFromSeq = resumeSeq
        self.returningClient = returning

        // 4. DATA connection: open, send data preamble tagged with the authoritative id.
        let dataConn = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
        try await dataConn.startAndWaitReady(on: DispatchQueue(label: "rwork.client.data"))
        try await dataConn.sendRaw(ChannelAssociation.dataPreamble(sessionID: authoritativeID))

        let data = NWMessageChannel(connection: dataConn, channel: .data)
        await data.start()
        try await data.waitUntilReady()

        self.dataChannel = data
        self.connection = RworkConnection(data: data, control: control)

        // 5. Forward the DATA channel into the merged stream (CONTROL already forwarding).
        startDataForwarding(from: data)
    }

    /// Tears down a half-open handshake: cancel forwarders and close the control
    /// channel/connection we opened. Leaves the inbound stream open (the caller is
    /// retrying `connect`, not closing the transport).
    private func teardownAfterFailedHandshake() async {
        for task in forwarders { task.cancel() }
        forwarders.removeAll()
        await controlChannel?.close()
        await dataChannel?.close()
        controlChannel = nil
        dataChannel = nil
        connection = nil
    }

    /// The actor-isolated suspension point the helloAck waiter parks on.
    ///
    /// Wrapped in `withTaskCancellationHandler` so that if the surrounding child task is
    /// cancelled (handshake timeout, or `connect`'s task group tearing down) the stored
    /// `helloAckWaiter` is resumed with a cancellation error rather than leaked
    /// (`SWIFT TASK CONTINUATION MISUSE`). `failHelloAckIfWaiting` is idempotent (nil
    /// guard), so the normal delivery path racing the cancel is safe.
    private func suspendForHelloAck() async throws -> WireMessage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // If cancellation already fired before we parked, resume immediately
                // instead of storing a continuation that nothing would ever resume.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    helloAckWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.failHelloAckIfWaiting(CancellationError()) }
        }
    }

    /// The single consumer of the control channel. Intercepts the first `helloAck`;
    /// forwards everything else.
    private func startControlForwarding(from channel: NWMessageChannel) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in channel.inbound {
                    await self.handleControlInbound(message)
                }
                // A clean finish (FIN) BEFORE the helloAck arrived is itself a handshake
                // failure — fail any still-parked waiter so `connect` does not hang.
                await self.failHelloAckIfWaiting(RworkTransportError.handshakeFailed("control stream ended before helloAck"))
                await self.finishInbound(error: nil)
            } catch {
                await self.failHelloAckIfWaiting(error)
                await self.finishInbound(error: error)
            }
        }
        forwarders.append(task)
    }

    private func handleControlInbound(_ message: WireMessage) {
        if !helloAckDelivered, case .helloAck = message {
            helloAckDelivered = true
            let waiter = helloAckWaiter
            helloAckWaiter = nil
            waiter?.resume(returning: message)
            return // do not forward the handshake reply itself
        }
        inboundContinuation.yield(message)
    }

    private func failHelloAckIfWaiting(_ error: Error) {
        guard let waiter = helloAckWaiter else { return }
        helloAckWaiter = nil
        waiter.resume(throwing: error)
    }

    private func finishInbound(error: Error?) {
        if let error {
            inboundContinuation.finish(throwing: error)
        } else {
            inboundContinuation.finish()
        }
    }

    private func startDataForwarding(from channel: NWMessageChannel) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in channel.inbound {
                    await self.yieldInbound(message)
                }
                // Symmetric with the control forwarder: a CLEAN finish (FIN / a channel
                // cancelled during the reconnect race) must ALSO terminate the merged
                // inbound. NWMessageChannel.finish() carries no error on a clean cancel, so
                // without this the data forwarder's loop would end silently and the merged
                // `inbound` would stay open forever — RworkClient.handleStreamEnded would
                // never run, no `.disconnected` would surface, and ReconnectManager would
                // never fire (the client would silently stall with no output/recovery).
                await self.finishInbound(error: nil)
            } catch {
                await self.finishInbound(error: error)
            }
        }
        forwarders.append(task)
    }

    /// Actor-isolated yield into the merged inbound (so the data forwarder hops onto the
    /// actor for both yield and finish, keeping ordering well-defined).
    private func yieldInbound(_ message: WireMessage) {
        inboundContinuation.yield(message)
    }

    // MARK: Outbound (client → host)

    /// Sends raw keystroke/paste bytes as `input` on the **data** channel.
    public func sendInput(_ bytes: Data) async throws {
        try await requireData().send(.input(bytes))
    }

    /// Sends a `resize` on the **control** channel.
    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) async throws {
        try await requireControl().send(.resize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight))
    }

    /// Sends an `ack` (highest contiguous output seq durably received) on the
    /// **control** channel so the host can release replay-buffer entries.
    public func sendAck(seq: Int64) async throws {
        try await requireControl().send(.ack(seq: seq))
    }

    /// Sends a clean `bye` on the **control** channel.
    public func sendBye() async throws {
        try await requireControl().send(.bye)
    }

    /// Tears down both channels and finishes the inbound stream.
    public func close() {
        // If close() races an in-flight handshake, resume the parked waiter so the
        // suspended `connect` unwinds instead of leaking its continuation.
        failHelloAckIfWaiting(RworkTransportError.invalidState("transport closed during handshake"))
        for task in forwarders { task.cancel() }
        forwarders.removeAll()
        let data = dataChannel
        let control = controlChannel
        Task {
            await data?.close()
            await control?.close()
        }
        inboundContinuation.finish()
        connection = nil
        dataChannel = nil
        controlChannel = nil
    }

    private func requireData() throws -> NWMessageChannel {
        guard let dataChannel else { throw RworkTransportError.invalidState("not connected (data)") }
        return dataChannel
    }

    private func requireControl() throws -> NWMessageChannel {
        guard let controlChannel else { throw RworkTransportError.invalidState("not connected (control)") }
        return controlChannel
    }
}
