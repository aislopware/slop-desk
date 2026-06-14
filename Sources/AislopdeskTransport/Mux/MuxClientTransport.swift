import AislopdeskProtocol
import Foundation

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

    @preconcurrency
    public init(
        acquire: @escaping @Sendable (String, UInt16, UUID, Int64) async throws -> MuxAcquisition,
        release: @escaping @Sendable (String, UInt16, UInt32) async -> Void,
    ) {
        self.acquire = acquire
        self.release = release
        var continuation: AsyncThrowingStream<WireMessage, Error>.Continuation?
        inboundStream = AsyncThrowingStream { continuation = $0 }
        guard let continuation else {
            preconditionFailure("AsyncThrowingStream runs its builder synchronously; continuation is always set")
        }
        inboundContinuation = continuation
    }

    public nonisolated var inbound: AsyncThrowingStream<WireMessage, Error> { inboundStream }

    public func connect(
        host: String,
        port: UInt16,
        resume: UUID,
        lastReceivedSeq: Int64,
        handshakeTimeout _: Duration,
    ) async throws {
        let id = resume == WireMessage.newSessionID ? UUID() : resume
        let acquisition = try await acquire(host, port, id, lastReceivedSeq)
        sessionID = id
        resumeFromSeq = lastReceivedSeq
        returningClient = (resume != WireMessage.newSessionID)
        dataChannel = acquisition.data
        controlChannel = acquisition.control
        channelID = acquisition.channelID
        connectedHost = host
        connectedPort = port
        startForwarding(data: acquisition.data, control: acquisition.control)
    }

    public func sendInput(_ bytes: Data) async throws {
        let channel = try requireData()
        // Split large inputs (paste) into bounded `.input` frames: one giant frame would
        // (a) reach the host PTY only after the WHOLE paste reassembled (no progressive
        // echo, Ctrl-C queued behind the transfer), (b) kill the channel past the 16 MiB
        // FrameDecoder cap, and (c) deadlock the credit-at-consumption window for any
        // frame ≥ window (the receiver consumes only COMPLETE frames). Order across the
        // split frames is preserved by the per-channel send gate + this single sequential
        // loop; a byte stream carries no frame semantics, so the split is invisible at the
        // PTY (bracketed-paste markers ride the bytes themselves).
        let cap = MuxFlowControl.maxDataMessagePayloadBytes
        if bytes.count <= cap {
            try await channel.send(.input(bytes))
            return
        }
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = bytes.index(offset, offsetBy: cap, limitedBy: bytes.endIndex) ?? bytes.endIndex
            try await channel.send(.input(Data(bytes[offset..<end])))
            offset = end
        }
    }

    /// Reports that the client's REAL consumer (the render drain) consumed `wireBytes` of
    /// data-class inbound (`output`/`exit`) — forwarded to the DATA sub-channel's
    /// credit-at-consumption sink. Control-class messages are unwindowed; the caller
    /// (`AislopdeskClient`) only reports data-class.
    public func noteOutputConsumed(wireBytes: Int) async {
        guard wireBytes > 0 else { return }
        await dataChannel?.noteConsumed(wireBytes)
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

    public func sendPing(timestampMS: UInt64) async throws {
        try await requireControl().send(.ping(timestampMS: timestampMS))
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
                for try await message in data.inbound { await yieldInbound(message) }
                await finishInbound(error: nil)
            } catch { await finishInbound(error: error) }
        })
        forwarders.append(Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in control.inbound { await yieldInbound(message) }
                await finishInbound(error: nil)
            } catch { await finishInbound(error: error) }
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
