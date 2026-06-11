import Foundation
import AislopdeskProtocol

/// A ``ClientTransporting`` backed by one logical channel on a SHARED ``MuxNWConnection`` — the
/// per-pane terminal transport vended to ``AislopdeskClient/AislopdeskClient``.
///
/// This is the "channel facade": from `AislopdeskClient`'s point of view it presents the
/// ``ClientTransporting`` protocol surface, so nothing upstream — `AislopdeskClient`,
/// `ConnectionViewModel`, `LivePaneSession`, `reconcile` — knows about the mux layer. `connect()`
/// acquires the shared connection for `(host,port)` from the ``ConnectionRegistry`` and opens ONE
/// channel on it; `sendInput` rides the channel's DATA sub-channel, `sendResize`/`sendAck`/`sendBye`
/// ride its CONTROL sub-channel, and `inbound` merges both — a data/control split over two physical
/// sockets shared by every pane on the host.
///
/// ### Session identity
/// The mux `channelOpen` carries the resume `sessionID` + `lastReceivedSeq` directly, so the
/// channel IS the session — there is no separate hello/helloAck handshake on the shared link. The
/// presented `sessionID` is authoritative (a fresh UUID for a new pane, the preserved id on
/// reconnect); per-channel returning-client replay over mux is a later stage.
///
/// All mutable state lives inside this `actor`. The shared connection is acquired/released through
/// the (`@MainActor`) ``ConnectionRegistry``, hopped to from `connect`/`close`.
public actor MuxClientTransport: ClientTransporting {
    /// Acquires the shared connection for the endpoint (refcount++), returning it + the channel
    /// pair. Injected so `connect` need not know the registry's `@MainActor` isolation directly.
    private let acquire: @Sendable (_ host: String, _ port: UInt16, _ sessionID: UUID, _ lastReceivedSeq: Int64)
        async throws -> MuxAcquisition
    /// Releases this transport's channel from the shared connection (refcount--, tear down on 0).
    private let release: @Sendable (_ host: String, _ port: UInt16, _ channelID: UInt32) async -> Void

    public private(set) var sessionID: UUID?
    public private(set) var resumeFromSeq: Int64 = 0
    public private(set) var returningClient = false

    private let inboundStream: AsyncThrowingStream<WireMessage, Error>
    private let inboundContinuation: AsyncThrowingStream<WireMessage, Error>.Continuation

    private var dataChannel: MuxSubChannel?
    private var controlChannel: MuxSubChannel?
    private var channelID: UInt32?
    private var connectedHost: String?
    private var connectedPort: UInt16?
    private var forwarders: [Task<Void, Never>] = []

    public init(
        acquire: @escaping @Sendable (String, UInt16, UUID, Int64) async throws -> MuxAcquisition,
        release: @escaping @Sendable (String, UInt16, UInt32) async -> Void
    ) {
        self.acquire = acquire
        self.release = release
        var continuation: AsyncThrowingStream<WireMessage, Error>.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    public nonisolated var inbound: AsyncThrowingStream<WireMessage, Error> { inboundStream }

    public func connect(
        host: String,
        port: UInt16,
        resume: UUID,
        lastReceivedSeq: Int64,
        handshakeTimeout: Duration
    ) async throws {
        let id = resume == WireMessage.newSessionID ? UUID() : resume
        let acquisition = try await acquire(host, port, id, lastReceivedSeq)
        self.sessionID = id
        self.resumeFromSeq = lastReceivedSeq
        self.returningClient = (resume != WireMessage.newSessionID)
        self.dataChannel = acquisition.data
        self.controlChannel = acquisition.control
        self.channelID = acquisition.channelID
        self.connectedHost = host
        self.connectedPort = port
        startForwarding(data: acquisition.data, control: acquisition.control)
    }

    public func sendInput(_ bytes: Data) async throws {
        try await requireData().send(.input(bytes))
    }

    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) async throws {
        try await requireControl().send(.resize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight))
    }

    public func sendAck(seq: Int64) async throws {
        try await requireControl().send(.ack(seq: seq))
    }

    public func sendBye() async throws {
        try await requireControl().send(.bye)
    }

    public func close() async {
        for task in forwarders { task.cancel() }
        forwarders.removeAll()
        inboundContinuation.finish()
        if let host = connectedHost, let port = connectedPort, let id = channelID {
            await release(host, port, id)
        }
        dataChannel = nil
        controlChannel = nil
        channelID = nil
        connectedHost = nil
        connectedPort = nil
    }

    // MARK: - Internals

    /// Merges both sub-channels' inbound into the single `inbound` stream — the mux equivalent of
    /// `ClientTransport`'s data+control forwarders. The first forwarder to end finishes the merged
    /// stream (the channel/shared link is gone), so the consumer's stream-ended path runs.
    private func startForwarding(data: MuxSubChannel, control: MuxSubChannel) {
        forwarders.append(Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in data.inbound { await self.yieldInbound(message) }
                await self.finishInbound(error: nil)
            } catch { await self.finishInbound(error: error) }
        })
        forwarders.append(Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in control.inbound { await self.yieldInbound(message) }
                await self.finishInbound(error: nil)
            } catch { await self.finishInbound(error: error) }
        })
    }

    private func yieldInbound(_ message: WireMessage) {
        inboundContinuation.yield(message)
    }

    private func finishInbound(error: Error?) {
        if let error { inboundContinuation.finish(throwing: error) } else { inboundContinuation.finish() }
    }

    private func requireData() throws -> MuxSubChannel {
        guard let dataChannel else { throw AislopdeskTransportError.invalidState("mux: not connected (data)") }
        return dataChannel
    }

    private func requireControl() throws -> MuxSubChannel {
        guard let controlChannel else { throw AislopdeskTransportError.invalidState("mux: not connected (control)") }
        return controlChannel
    }
}

/// The result of acquiring a channel on a shared ``MuxNWConnection``: the channel id + its data
/// and control sub-channels. A value type so it crosses the `@MainActor` registry → actor boundary.
public struct MuxAcquisition: Sendable {
    public let channelID: UInt32
    public let data: MuxSubChannel
    public let control: MuxSubChannel
    public init(channelID: UInt32, data: MuxSubChannel, control: MuxSubChannel) {
        self.channelID = channelID
        self.data = data
        self.control = control
    }
}
