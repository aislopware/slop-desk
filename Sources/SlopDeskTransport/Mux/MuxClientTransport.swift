import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

/// Where the two callbacks land. Retained by the Rust handle for its whole life.
///
/// A `final class` and not the actor, because `context` must be a raw pointer valid on any
/// thread until `slopdesk_mux_transport_free` returns, and an actor reference is neither. Every
/// field is either immutable or a continuation, which is `Sendable` and safe to yield to from
/// any thread — so nothing here needs a lock.
private final class Inbox: @unchecked Sendable {
    let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
    /// The reason the HOST gave for closing this channel, written once by the ended callback.
    /// `nil` while live, and `nil` afterwards for an end that was not a peer close — a link
    /// that died says nothing about the channel, which is the distinction the reconnect
    /// campaign reads.
    let closeReason = CloseReasonBox()
    /// The id this end allocated, written once by `open` and read from anywhere.
    ///
    /// It lives HERE rather than on the actor because `WorkspaceChannelClient.Handle` is built
    /// synchronously on the main actor and needs it — and it is immutable in every sense that
    /// matters, being written before the transport is handed to anybody.
    private let idLock = NSLock()
    private var id: UInt32 = 0

    var channelID: UInt32 {
        idLock.lock()
        defer { idLock.unlock() }
        return id
    }

    func setChannelID(_ value: UInt32) {
        idLock.lock()
        defer { idLock.unlock() }
        id = value
    }

    init(_ continuation: AsyncThrowingStream<WireMessage, Error>.Continuation) {
        self.continuation = continuation
    }
}

/// Owns the Rust channel for exactly as long as anything holds this object.
///
/// A separate class and not two fields on the actor, because the workspace document's handle keeps
/// the transport alive past the scope that opened it, and an actor cannot free a C handle from
/// `deinit`. Here ARC IS the lifetime: the last release frees the channel and then the callback
/// context, in that order and never the other, because `slopdesk_mux_transport_free` joins both
/// forwarder threads and only afterwards is nothing running that could touch the context.
///
/// ### Why it holds the pool
/// `slopdesk_mux_pool_free` documents that every transport opened on the pool must already be freed
/// — it closes and JOINS each connection's receive loops, which is the quiescence a leak test needs.
/// The actor holds both this object and the registry, and ARC releases an object's fields in NO
/// specified order, so without this reference a deallocating transport could free the pool first.
/// One strong reference makes the obligation structural: the pool outlives every channel on it
/// because a channel is what holds it up.
private final class Held: @unchecked Sendable {
    let pointer: OpaquePointer
    private let context: Unmanaged<Inbox>
    private let pool: ConnectionRegistry

    init(pointer: OpaquePointer, context: Unmanaged<Inbox>, pool: ConnectionRegistry) {
        self.pointer = pointer
        self.context = context
        self.pool = pool
    }

    deinit {
        slopdesk_mux_transport_free(pointer)
        context.release()
    }
}

/// One `MuxCloseReason?`, written by a Rust thread and read by the actor.
///
/// `NSLock` rather than an atomic because the value is read once per channel, at the end, and a
/// lock is the spelling that does not need a `Sendable` escape hatch of its own.
private final class CloseReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MuxCloseReason?

    var reason: MuxCloseReason? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ reason: MuxCloseReason?) {
        lock.lock()
        defer { lock.unlock() }
        value = reason
    }
}

/// A ``ClientTransporting`` over one channel of the per-host shared mux — the handle side of
/// `rust/slopdesk-clientnet`'s `ChannelTransport`.
///
/// `docs/63` stage G.3. What used to be here decided three things and this file states none of them,
/// because all three moved: which lane a verb rides (`input` on DATA, everything else on CONTROL),
/// how a paste is split at the flow-control cap, and that the merged inbound ends on the FIRST
/// sub-channel to end. They are `rust/slopdesk-clientnet/src/transport.rs`'s module docs now, one
/// paragraph each, with a loopback test apiece. What is left here is the calling convention.
///
/// ### The channel IS the session
/// The mux `channelOpen` carries the resume `sessionID` + `lastReceivedSeq` directly, so there is no
/// separate hello/helloAck handshake on the shared link. The presented `sessionID` is authoritative;
/// the host's `channelOpenAck` answers with the authoritative `resumeFromSeq` verdict (docs/20
/// §8.3.1), which ``connect(host:port:resume:lastReceivedSeq:handshakeTimeout:)`` awaits.
///
/// ### Why the callbacks land in a class rather than on this actor
/// The Rust forwarders call on threads this actor does not own and cannot hop from, so the context
/// they carry is a plain `final class` — ``Inbox`` above — holding the stream continuation. That is
/// the whole reason `inbound` was already `nonisolated`: a continuation is safe to yield to from
/// anywhere, so the message reaches the consumer with no actor hop and no queue in between.
public actor MuxClientTransport: ClientTransporting, InitialCwdConfigurableTransport {
    private let registry: ConnectionRegistry
    /// What this transport's channel is FOR — the ``SlopDeskProtocol/MuxChannelClass`` byte riding
    /// its `channelOpen`. Fixed for the transport's life: the class decides how the HOST routes the
    /// open, so a channel that changed class across a reconnect would become a different thing.
    private let channelClass: UInt8

    public private(set) var sessionID: UUID?
    public private(set) var resumeFromSeq: Int64 = 0
    public private(set) var returningClient = false

    private let inboundStream: AsyncThrowingStream<WireMessage, Error>
    private let inbox: Inbox
    /// The open channel, or `nil` before ``open(host:port:resume:lastReceivedSeq:)`` and after
    /// ``close()``. Dropping it IS the close.
    private var held: Held?
    private var initialCwd: String?

    public init(registry: ConnectionRegistry, channelClass: UInt8 = MuxChannelClass.pane.rawValue) {
        self.registry = registry
        self.channelClass = channelClass
        var continuation: AsyncThrowingStream<WireMessage, Error>.Continuation?
        inboundStream = AsyncThrowingStream { continuation = $0 }
        guard let continuation else {
            preconditionFailure("AsyncThrowingStream runs its builder synchronously; continuation is always set")
        }
        inbox = Inbox(continuation)
    }

    public nonisolated var inbound: AsyncThrowingStream<WireMessage, Error> { inboundStream }

    /// The channel id this end allocated, or `0` before ``open(host:port:resume:lastReceivedSeq:)``.
    ///
    /// `nonisolated` because `WorkspaceChannelClient.Handle` is built synchronously the moment the
    /// open returns, and hopping the actor to read a value that is already final would make that
    /// construction `async` for nothing.
    public nonisolated var openedChannelID: UInt32 { inbox.channelID }

    /// Why the HOST closed this channel, or `nil` if the link died under it instead.
    ///
    /// Written by the ended callback, which fires exactly once and covers both lanes — so the
    /// "either sub-channel carrying the mark is enough" reasoning this used to spell out is a
    /// property of the Rust merge now rather than a lookup here.
    public var hostCloseReason: MuxCloseReason? { inbox.closeReason.reason }

    // Actor-isolated (not `async`): the cross-actor hop supplies the async-ness the
    // `InitialCwdConfigurableTransport` requirement asks for, so callers still `await` it.
    public func setInitialCwd(_ cwd: String?) {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        initialCwd = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Opens the channel and starts delivering its inbound, WITHOUT awaiting the host's verdict.
    ///
    /// Split from ``connect(host:port:resume:lastReceivedSeq:handshakeTimeout:)`` because the two
    /// callers want the verdict on different terms. A PANE cannot use a channel whose resume
    /// position it does not know, so it waits inside `connect` and treats every non-answer alike.
    /// The workspace document CAN — it carries no resume position — and it needs the one
    /// distinction `connect` collapses: a host that REFUSES class 1 is a definite answer nothing
    /// retries (`ChannelRunState.refused`), while a dial that failed is retried forever.
    ///
    /// - Throws: ``SlopDeskTransportError/notConnected(_:)`` if the channel could not be opened.
    public func open(host: String, port: UInt16, resume: UUID, lastReceivedSeq: Int64) async throws {
        let id = resume == WireMessage.newSessionID ? UUID() : resume
        // The cwd hint rides EVERY (re)connect. The host ignores it on a reattach (PATH A — the live
        // shell's cwd is preserved) and honours it only on a fresh respawn (PATH B/C), where the
        // pane's project dir is exactly what we want: otherwise the new shell lands in the daemon's
        // `$HOME` and the cwd-derived title collapses to "Terminal".
        let retained = Unmanaged.passRetained(inbox)
        let opened = await Self.open(
            pool: registry.handle,
            host: host,
            port: port,
            channelClass: channelClass,
            sessionID: id,
            lastReceivedSeq: lastReceivedSeq,
            initialCwd: initialCwd,
            context: retained.toOpaque(),
        )
        guard let opened else {
            // Rust promises neither callback has run or ever will on a failed open, so the context
            // is released here rather than left for a `close()` that has no handle to drive.
            retained.release()
            throw SlopDeskTransportError.notConnected("mux: could not open a channel on \(host):\(port)")
        }
        held = Held(pointer: opened, context: retained, pool: registry)
        sessionID = id
        returningClient = (resume != WireMessage.newSessionID)
        inbox.setChannelID(slopdesk_mux_transport_channel_id(opened))
    }

    /// Waits for the host's verdict on the open, recording the authoritative ``resumeFromSeq``.
    ///
    /// The `channelOpenAck` carries the HOST-AUTHORITATIVE `resumeFromSeq` (docs/20 §8.2): 0 = a
    /// fresh shell (PATH B/C — the client must reset its seq marks), > 0 = the SAME live session
    /// reattached (PATH A — the marks are already correct and the replay starts after this seq).
    /// The host acks BEFORE the replay on the same DATA link, so this wait costs one verdict
    /// round-trip, not the replay.
    ///
    /// `false` covers refused, dead and timed-out alike, because
    /// `slopdesk_mux_transport_await_open_ack` does — a pane that cannot be told where to resume
    /// from cannot resume, so the three are one answer to every caller that has a resume position.
    public func awaitAccepted(within: Duration) async -> Bool {
        guard let channel = held?.pointer else { return false }
        var verdict: Int64 = 0
        let accepted = await Self.awaitAck(channel, timeout: within, resumeFromSeq: &verdict)
        if accepted { resumeFromSeq = verdict }
        return accepted
    }

    public func connect(
        host: String,
        port: UInt16,
        resume: UUID,
        lastReceivedSeq: Int64,
        handshakeTimeout: Duration,
    ) async throws {
        try await open(host: host, port: port, resume: resume, lastReceivedSeq: lastReceivedSeq)
        guard await awaitAccepted(within: handshakeTimeout) else {
            // `ReconnectManager` retries either way, which is why the two read the same here.
            await close()
            throw SlopDeskTransportError.notConnected("mux: channel refused by host or the ack timed out")
        }
    }

    public func sendInput(_ bytes: Data) throws {
        let channel = try require()
        // The SPLIT is Rust's: `slopdesk_mux_transport_send_input` chunks at the flow-control cap,
        // for three separate failure reasons stated in that crate's module docs. This is one call.
        let verdict = bytes.withUnsafeBytes { span in
            slopdesk_mux_transport_send_input(
                channel,
                span.baseAddress?.assumingMemoryBound(to: UInt8.self),
                span.count,
            )
        }
        try Self.check(verdict, "input")
    }

    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) throws {
        try send(.resize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight), "resize")
    }

    public func sendAck(seq: Int64) throws {
        try send(.ack(seq: seq), "ack")
    }

    public func sendBye() throws {
        try send(.bye, "bye")
    }

    public func sendPing(timestampMS: UInt64) throws {
        try send(.ping(timestampMS: timestampMS), "ping")
    }

    public func sendRequestBlockOutput(index: UInt32) throws {
        try send(.requestBlockOutput(index: index), "requestBlockOutput")
    }

    public func sendMetadataRequest(requestID: UInt32, verb: UInt8, payload: Data) throws {
        try send(.metadataRequest(requestID: requestID, verb: verb, payload: payload), "metadataRequest")
    }

    /// One arbitrary message on the CONTROL lane — the workspace document's whole outbound.
    ///
    /// Verb-agnostic because the door is: the seven `send*` methods above differ only in the value
    /// they build, and a workspace request is one more of them. It refuses an `.input`, which rides
    /// DATA and has ``sendInput(_:)``.
    public func sendControl(_ message: WireMessage) throws {
        try send(message, "control message")
    }

    /// Reports that the client's REAL consumer (the render drain) consumed `wireBytes` of
    /// data-class inbound. Control-class messages are unwindowed and are not reported.
    public func noteOutputConsumed(wireBytes: Int) {
        guard wireBytes > 0, let channel = held?.pointer else { return }
        slopdesk_mux_transport_note_consumed(channel, wireBytes)
    }

    /// Releases the channel and finishes the inbound stream.
    ///
    /// Idempotent. Dropping ``Held`` frees the Rust channel, which closes it, releases its pool
    /// entry and JOINS both forwarders — so when this returns no Rust thread is holding the
    /// callback context. A transport that is never closed frees at deallocation instead, by the
    /// same `deinit`, which is what keeps the workspace document's handle from leaking a channel
    /// on a path that has no explicit close.
    public func close() {
        held = nil
        inbox.continuation.finish()
    }

    // MARK: - Internals

    /// One CONTROL message, flattened onto the record the door takes.
    private func send(_ message: WireMessage, _ what: String) throws {
        let channel = try require()
        let verdict = message.withFlattened { flat, arena, arenaLength, blob, blobLength in
            slopdesk_mux_transport_send(
                channel,
                flat,
                arena?.assumingMemoryBound(to: UInt8.self),
                arenaLength,
                blob?.assumingMemoryBound(to: UInt8.self),
                blobLength,
            )
        }
        try Self.check(verdict, what)
    }

    private func require() throws -> OpaquePointer {
        guard let channel = held?.pointer else {
            throw SlopDeskTransportError.invalidState("mux: not connected")
        }
        return channel
    }

    /// Turns a `SLOPDESK_MUX_SEND_*` verdict into the error the client's ladder already reads.
    private static func check(_ verdict: Int32, _ what: String) throws {
        switch verdict {
        case SLOPDESK_MUX_SEND_OK: return
        case SLOPDESK_MUX_SEND_CLOSED: throw SlopDeskTransportError.notConnected("mux: \(what) on a closed channel")
        case SLOPDESK_MUX_SEND_LINK: throw SlopDeskTransportError.notConnected("mux: \(what) failed, the link is gone")
        default: throw SlopDeskTransportError.invalidState("mux: \(what) was refused by the transport")
        }
    }

    /// The open itself, off the actor: it dials, which can take the whole connect timeout, and an
    /// actor that awaited it inline would block every other call on this transport meanwhile.
    private static func open(
        pool: RustHandle,
        host: String,
        port: UInt16,
        channelClass: UInt8,
        sessionID: UUID,
        lastReceivedSeq: Int64,
        initialCwd: String?,
        context: UnsafeMutableRawPointer,
    ) async -> OpaquePointer? {
        // The continuation yields a ``RustHandle`` rather than the pointer: it crosses from the
        // dialling queue back to this actor, which is exactly the transfer that type exists to name.
        await withCheckedContinuation { (resumption: CheckedContinuation<RustHandle, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let hostBytes = Array(host.utf8)
                let cwdBytes = Array((initialCwd ?? "").utf8)
                var session = sessionID.uuid
                let opened = withUnsafeBytes(of: &session) { raw in
                    hostBytes.withUnsafeBufferPointer { name in
                        cwdBytes.withUnsafeBufferPointer { cwd in
                            slopdesk_mux_transport_open(
                                pool.raw,
                                name.baseAddress,
                                name.count,
                                port,
                                channelClass,
                                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                lastReceivedSeq,
                                // Absent and empty are different requests on the wire, so an unset
                                // hint is the null pointer rather than a zero-length string.
                                initialCwd == nil ? nil : cwd.baseAddress,
                                initialCwd == nil ? 0 : cwd.count,
                                context,
                                onInbound,
                                onEnded,
                            )
                        }
                    }
                }
                resumption.resume(returning: RustHandle(opened))
            }
        }
        .raw
    }

    /// The ack wait, off the actor for the same reason the open is: it parks for up to the
    /// handshake timeout.
    private static func awaitAck(
        _ handle: OpaquePointer,
        timeout: Duration,
        resumeFromSeq: inout Int64,
    ) async -> Bool {
        let ms = timeout.milliseconds
        var seq: Int64 = 0
        let accepted = await withCheckedContinuation { resumption in
            DispatchQueue.global(qos: .userInitiated).async {
                var local: Int64 = 0
                let verdict = slopdesk_mux_transport_await_open_ack(handle, ms, &local)
                seq = local
                resumption.resume(returning: verdict)
            }
        }
        resumeFromSeq = seq
        return accepted
    }
}

// MARK: - The two callbacks

// Free functions rather than closures, because a `@convention(c)` pointer captures nothing. The
// context is the retained `Inbox`, valid until `slopdesk_mux_transport_free` returns.

private func onInbound(
    context: UnsafeMutableRawPointer?,
    record: UnsafePointer<SlopDeskWireMessage>?,
    arena: UnsafePointer<UInt8>?,
    arenaLength: Int,
    blob: UnsafePointer<UInt8>?,
    blobLength: Int,
) {
    guard let context, let record else { return }
    let inbox = Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue()
    // The run is copied HERE and exactly once, which is the copy the whole boundary is shaped
    // around: it is the only field big enough to matter, and the consumer outlives this call.
    // The LENGTH decides, never the pointer: an empty run is a dangling non-null on the Rust side,
    // which is the door's stated convention. `blob` is then only unwrapped, not tested.
    let run = blobLength > 0 ? blob.map { Data(bytes: $0, count: blobLength) } ?? Data() : Data()
    let text = UnsafeRawBufferPointer(start: arena, count: arenaLength)
    guard let message = WireMessage.lent(record.pointee, arena: text, run: run) else { return }
    inbox.continuation.yield(message)
}

private func onEnded(
    context: UnsafeMutableRawPointer?,
    kind: UInt32,
    closeReason: UInt8,
    detail: UnsafePointer<UInt8>?,
    detailLength: Int,
) {
    guard let context else { return }
    let inbox = Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue()
    if kind == SLOPDESK_MUX_END_PEER {
        // An unrecognised byte from a newer host reads as `.retired`, the conservative answer:
        // it withholds the automatic re-dial rather than inventing one.
        inbox.closeReason.set(MuxCloseReason(rawValue: closeReason) ?? .retired)
    }
    switch kind {
    case SLOPDESK_MUX_END_DECODE:
        // As above: the LENGTH decides. `detail` is a dangling non-null for every other kind.
        var why = "the channel's inner framing faulted"
        if detailLength > 0, let detail {
            // A lossy decode is right here and a failable one is not: this is a DIAGNOSTIC that has
            // already lost its channel, so a byte the host mis-encoded must still reach the log as a
            // replacement character rather than turning the reason into `nil`. `ArenaText` reads the
            // arena the same way for the same reason.
            // swiftlint:disable:next optional_data_string_conversion
            why = String(decoding: UnsafeBufferPointer(start: detail, count: detailLength), as: UTF8.self)
        }
        inbox.continuation.finish(throwing: SlopDeskTransportError.invalidState("mux: \(why)"))
    case SLOPDESK_MUX_END_LINK_DOWN:
        inbox.continuation.finish(throwing: SlopDeskTransportError.notConnected("mux: the link died"))
    default:
        // A local close and a peer close both END the stream rather than failing it: the reason a
        // peer gave is advice about recovery, read through `hostCloseReason`, and a consumer that
        // saw a thrown error there would retry a channel the host deliberately closed.
        inbox.continuation.finish()
    }
}

/// One open channel's CONTROL lane, as the ``MessageChannel`` the workspace client injects.
///
/// The whole adapter, because `MuxClientTransport` already IS a send/receive pair — this only says
/// WHICH of its two sends the protocol requirement means. `inbound` is the transport's merged
/// stream unchanged: a class-1 channel's DATA lane is idle by construction (`docs/45` §5.1), so the
/// merge carries CONTROL traffic and nothing else.
public struct MuxControlChannel: MessageChannel {
    private let transport: MuxClientTransport

    public init(_ transport: MuxClientTransport) {
        self.transport = transport
    }

    public var inbound: AsyncThrowingStream<WireMessage, Error> { transport.inbound }

    public func send(_ message: WireMessage) async throws {
        try await transport.sendControl(message)
    }
}
