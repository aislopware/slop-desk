import Foundation
import SlopDeskProtocol

/// A ``ClientTransporting`` backed by one logical channel on a SHARED ``MuxNWConnection`` — the
/// per-pane terminal transport vended to ``SlopDeskClient/SlopDeskClient``.
///
/// This is the "channel facade": from `SlopDeskClient`'s point of view it presents the
/// ``ClientTransporting`` protocol surface, so nothing upstream — `SlopDeskClient`,
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
/// reconnect); the host's `channelOpenAck` answers with the authoritative `resumeFromSeq`
/// verdict (docs/20 §8.3.1), which `connect` awaits before adopting the channel.
///
/// All mutable state lives inside this `actor`. The shared connection is acquired/released through
/// the (`@MainActor`) ``ConnectionRegistry``, hopped to from `connect`/`close`.
public actor MuxClientTransport: ClientTransporting, InitialCwdConfigurableTransport {
    /// Acquires the shared connection for the endpoint (refcount++), returning it + the channel
    /// pair. Injected so `connect` need not know the registry's `@MainActor` isolation directly.
    private let acquire: @Sendable (
        _ host: String,
        _ port: UInt16,
        _ sessionID: UUID,
        _ lastReceivedSeq: Int64,
        _ channelClass: UInt8,
        _ initialCwd: String?,
    )
        async throws -> MuxAcquisition
    /// Releases this transport's channel from the shared connection (refcount--, tear down on 0).
    private let release: @Sendable (_ host: String, _ port: UInt16, _ channelID: UInt32) async -> Void

    /// What this transport's channel is FOR — the ``SlopDeskProtocol/MuxChannelClass`` byte that
    /// rides every `channelOpen` it makes. `0` (a pane) for every shipped call site; `2` opens a
    /// READ-ONLY view of a pane another client holds (docs/45 §8.4), which the host answers with a
    /// subscriber whose `input` it drops.
    ///
    /// Fixed for the transport's life: the class decides how the HOST routes the open, so a channel
    /// that changed class across a reconnect would silently become a different kind of thing.
    private let channelClass: UInt8

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

    /// Compatibility overload: neither a cwd hint nor a class. Opens a PANE.
    @preconcurrency
    public init(
        acquire: @escaping @Sendable (String, UInt16, UUID, Int64) async throws -> MuxAcquisition,
        release: @escaping @Sendable (String, UInt16, UInt32) async -> Void,
    ) {
        self.init(
            acquire: { host, port, sessionID, lastReceivedSeq, _, _ in
                try await acquire(host, port, sessionID, lastReceivedSeq)
            },
            release: release,
        )
    }

    /// Compatibility overload: a cwd hint, no class. Opens a PANE.
    @preconcurrency
    public init(
        acquire: @escaping @Sendable (String, UInt16, UUID, Int64, String?) async throws -> MuxAcquisition,
        release: @escaping @Sendable (String, UInt16, UInt32) async -> Void,
    ) {
        self.init(
            acquire: { host, port, sessionID, lastReceivedSeq, _, initialCwd in
                try await acquire(host, port, sessionID, lastReceivedSeq, initialCwd)
            },
            release: release,
        )
    }

    /// Designated init. `channelClass` defaults to ``SlopDeskProtocol/MuxChannelClass/pane`` so an
    /// existing call site that omits it opens exactly what it always opened.
    @preconcurrency
    public init(
        channelClass: UInt8 = MuxChannelClass.pane.rawValue,
        acquire: @escaping @Sendable (String, UInt16, UUID, Int64, UInt8, String?) async throws -> MuxAcquisition,
        release: @escaping @Sendable (String, UInt16, UInt32) async -> Void,
    ) {
        self.channelClass = channelClass
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

    /// Whether the HOST retired this channel with a `channelClose`, rather than the shared link
    /// dying under it. Either sub-channel carrying the mark is enough: `closeChannel` sends the
    /// frame on BOTH links, and whichever arrives first is the one that ends the merged stream.
    public var hostClosedChannel: Bool {
        get async {
            if let dataChannel, await dataChannel.closedByPeer { return true }
            if let controlChannel, await controlChannel.closedByPeer { return true }
            return false
        }
    }

    private var initialCwd: String?

    // Actor-isolated (not `async`): the cross-actor hop supplies the async-ness the
    // `InitialCwdConfigurableTransport` requirement asks for, so callers still `await` it.
    public func setInitialCwd(_ cwd: String?) {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        initialCwd = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public func connect(
        host: String,
        port: UInt16,
        resume: UUID,
        lastReceivedSeq: Int64,
        handshakeTimeout: Duration,
    ) async throws {
        let id = resume == WireMessage.newSessionID ? UUID() : resume
        // Send the cwd hint on EVERY (re)connect. The host ignores it on a reattach (PATH A — the live
        // shell's cwd is preserved) and honors it only on a fresh respawn (PATH B/C), where the pane's
        // project dir is exactly what we want (else the new shell lands in the daemon's `$HOME` and the
        // cwd-derived title collapses to "Terminal"). See `SlopDeskClient.connect`.
        let cwdHint = initialCwd
        let acquisition = try await acquire(host, port, id, lastReceivedSeq, channelClass, cwdHint)
        // The `channelOpenAck` carries the HOST-AUTHORITATIVE `resumeFromSeq` (docs/20 §8.2):
        // 0 = fresh shell (PATH B/C — the client must reset its seq marks), > 0 = the SAME
        // live session reattached (PATH A — the marks are already correct and the replay
        // starts after this seq). The host acks BEFORE the replay on the same DATA link, so
        // this wait costs one verdict round-trip, not the replay. A refusal tears the
        // acquisition down and throws (`ReconnectManager` retries); a timeout (dead host
        // mid-open) does the same. Test doubles without an ack path keep the old behavior.
        if let awaitAck = acquisition.awaitOpenAck {
            let verdict = await Self.race(awaitAck, timeout: handshakeTimeout)
            guard let verdict, verdict.accepted else {
                await release(host, port, acquisition.channelID)
                throw SlopDeskTransportError.notConnected(
                    verdict == nil ? "mux: channelOpenAck timeout" : "mux: channel refused by host",
                )
            }
            resumeFromSeq = verdict.resumeFromSeq
        } else {
            resumeFromSeq = 0
        }
        sessionID = id
        returningClient = (resume != WireMessage.newSessionID)
        dataChannel = acquisition.data
        controlChannel = acquisition.control
        channelID = acquisition.channelID
        connectedHost = host
        connectedPort = port
        startForwarding(data: acquisition.data, control: acquisition.control)
    }

    /// Races `operation` against `timeout`. The loser is cancelled — `awaitOpenAck` resumes a
    /// cancelled waiter immediately, so no continuation is stranded.
    private static func race(
        _ operation: @escaping @Sendable () async -> (accepted: Bool, resumeFromSeq: Int64),
        timeout: Duration,
    ) async -> (accepted: Bool, resumeFromSeq: Int64)? {
        await withTaskGroup(of: (accepted: Bool, resumeFromSeq: Int64)?.self) { group in
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
    /// (`SlopDeskClient`) only reports data-class.
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

    public func sendRequestBlockOutput(index: UInt32) async throws {
        try await requireControl().send(.requestBlockOutput(index: index))
    }

    public func sendMetadataRequest(requestID: UInt32, verb: UInt8, payload: Data) async throws {
        try await requireControl().send(.metadataRequest(requestID: requestID, verb: verb, payload: payload))
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
        guard let dataChannel else { throw SlopDeskTransportError.invalidState("mux: not connected (data)") }
        return dataChannel
    }

    private func requireControl() throws -> MuxSubChannel {
        guard let controlChannel else { throw SlopDeskTransportError.invalidState("mux: not connected (control)") }
        return controlChannel
    }
}

/// The result of acquiring a channel on a shared ``MuxNWConnection``: the channel id + its data
/// and control sub-channels. A value type so it crosses the `@MainActor` registry → actor boundary.
public struct MuxAcquisition: Sendable {
    public let channelID: UInt32
    public let data: MuxSubChannel
    public let control: MuxSubChannel
    /// Awaits the host's `channelOpenAck` verdict for this channel (accepted + the
    /// host-authoritative `resumeFromSeq`). `nil` (test doubles that never ack) makes
    /// `connect` skip the wait and behave as before (`resumeFromSeq = 0`).
    public let awaitOpenAck: (@Sendable () async -> (accepted: Bool, resumeFromSeq: Int64))?

    @preconcurrency
    public init(
        channelID: UInt32,
        data: MuxSubChannel,
        control: MuxSubChannel,
        awaitOpenAck: (@Sendable () async -> (accepted: Bool, resumeFromSeq: Int64))? = nil,
    ) {
        self.channelID = channelID
        self.data = data
        self.control = control
        self.awaitOpenAck = awaitOpenAck
    }
}
