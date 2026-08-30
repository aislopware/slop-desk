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

/// One channel of the per-host shared mux, as the WORKSPACE DOCUMENT's transport.
///
/// `docs/63` stages G.3 and G.5. G.3 moved every decision out — which lane a verb rides, how a paste
/// is split at the flow-control cap, that the merged inbound ends on the FIRST sub-channel to end —
/// into `rust/slopdesk-clientnet/src/transport.rs`, leaving the calling convention. G.5 then took
/// the PANE session away: a pane rides `SlopDeskClient`'s `slopdesk_pane_driver_*` handle now, which
/// owns its own transport in Rust, so the eight send verbs, the resume identity and the consumption
/// credit that only a pane ever used went with it. What is left is class 1's whole need: open,
/// collect the verdict, send arbitrary CONTROL, read the merged inbound, close.
///
/// ### The channel IS the session
/// The mux `channelOpen` carries the session id directly, so there is no separate hello/helloAck
/// handshake on the shared link. The workspace document mints a fresh one per open and presents no
/// resume position: there is no PTY behind it to reattach to, so the host's `resumeFromSeq` verdict
/// says only whether class 1 was ACCEPTED, which is what ``awaitAccepted(within:)`` answers.
///
/// ### Why the callbacks land in a class rather than on this actor
/// The Rust forwarders call on threads this actor does not own and cannot hop from, so the context
/// they carry is a plain `final class` — ``Inbox`` above — holding the stream continuation. That is
/// the whole reason `inbound` was already `nonisolated`: a continuation is safe to yield to from
/// anywhere, so the message reaches the consumer with no actor hop and no queue in between.
public actor MuxClientTransport {
    private let registry: ConnectionRegistry
    /// What this transport's channel is FOR — the ``SlopDeskProtocol/MuxChannelClass`` byte riding
    /// its `channelOpen`. Fixed for the transport's life: the class decides how the HOST routes the
    /// open, so a channel that changed class across a reconnect would become a different thing.
    private let channelClass: UInt8

    private let inboundStream: AsyncThrowingStream<WireMessage, Error>
    private let inbox: Inbox
    /// The open channel, or `nil` before ``open(host:port:resume:lastReceivedSeq:)``.
    ///
    /// Set once and never cleared, because ARC is the only clock that can safely free it. Dropping
    /// ``Held`` frees the Rust channel, and ``awaitAccepted(within:)`` copies the raw pointer out and
    /// then parks OFF the actor for the whole handshake window — an actor is re-entrant across that
    /// suspension, so a method that cleared this would free the channel under a waiter still holding
    /// its pointer. That is the shape `docs/63` records for the video flow, and the answer is the
    /// same: the last release of the transport is the close, and nothing else is.
    private var held: Held?

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
        let retained = Unmanaged.passRetained(inbox)
        let opened = await Self.open(
            pool: registry.handle,
            host: host,
            port: port,
            channelClass: channelClass,
            sessionID: id,
            lastReceivedSeq: lastReceivedSeq,
            context: retained.toOpaque(),
        )
        guard let opened else {
            // Rust promises neither callback has run or ever will on a failed open, so the context
            // is released here rather than left for a `close()` that has no handle to drive.
            retained.release()
            throw SlopDeskTransportError.notConnected("mux: could not open a channel on \(host):\(port)")
        }
        held = Held(pointer: opened, context: retained, pool: registry)
        inbox.setChannelID(slopdesk_mux_transport_channel_id(opened))
    }

    /// Waits for the host's verdict on the open.
    ///
    /// `false` covers refused, dead and timed-out alike, because
    /// `slopdesk_mux_transport_await_open_ack` does. The one distinction that matters to class 1 —
    /// a host that will not serve the workspace channel at all, versus a dial that failed — is the
    /// caller's, which records the first as `.refused` and retries only the second.
    public func awaitAccepted(within: Duration) async -> Bool {
        guard let channel = held?.pointer else { return false }
        var verdict: Int64 = 0
        return await Self.awaitAck(channel, timeout: within, resumeFromSeq: &verdict)
    }

    /// One arbitrary message on the CONTROL lane — the workspace document's whole outbound.
    ///
    /// Verb-agnostic, and the only send left: the seven typed ones this file used to carry differed
    /// from each other only in the value they built, and every one of them was a PANE's. It refuses
    /// an `.input`, which rides DATA and belongs to `slopdesk_pane_driver_send_input`.
    public func sendControl(_ message: WireMessage) throws {
        try send(message, "control message")
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
        context: UnsafeMutableRawPointer,
    ) async -> OpaquePointer? {
        // The continuation yields a ``RustHandle`` rather than the pointer: it crosses from the
        // dialling queue back to this actor, which is exactly the transfer that type exists to name.
        await withCheckedContinuation { (resumption: CheckedContinuation<RustHandle, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let hostBytes = Array(host.utf8)
                var session = sessionID.uuid
                let opened = withUnsafeBytes(of: &session) { raw in
                    hostBytes.withUnsafeBufferPointer { name in
                        slopdesk_mux_transport_open(
                            pool.raw,
                            name.baseAddress,
                            name.count,
                            port,
                            channelClass,
                            raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            lastReceivedSeq,
                            // The workspace document has no cwd hint: absent and empty are different
                            // requests on the wire, so it is the null pointer rather than "".
                            nil,
                            0,
                            context,
                            onInbound,
                            onEnded,
                        )
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
