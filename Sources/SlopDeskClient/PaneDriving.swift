import CSlopDeskFFI
import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import Synchronization

/// What one pane's session driver can be asked to do, and nothing about how it does it.
///
/// `docs/63` stage G.5. There is exactly ONE shipping conformer — ``LivePaneDriver``, the handle over
/// `slopdesk_pane_driver_*` — and the protocol exists for the reason `ClientTransporting` stopped
/// existing: a suite needs to drive ``SlopDeskClient`` without a host, and the thing it should stand
/// in for is the EVENT SOURCE rather than a transport under a Swift session. Every decision this
/// campaign is about — the dedup, the ack cadence, the resume verdict, the retry ladder, the
/// generations — lives in `rust/slopdesk-clientdriver` behind this, so a conformer written in a test
/// target cannot be a second implementation of any of it. It can only say what arrived.
///
/// ### Every method here BLOCKS
/// Deliberately: the driver is one supervisor thread and a mailbox, so "connect" means "post it and
/// wait for the answer". ``SlopDeskClient`` is what hops off the caller's thread, and it hops the
/// three calls that can park — ``connect(host:port:handshakeTimeout:)``,
/// ``resume(handshakeTimeout:)`` and ``sendInput(_:)``, the last because the DATA lane's credit
/// window is the backpressure. The readouts take a lock and return.
public protocol PaneDriving: Sendable {
    /// Installs the two sinks, once, before anything else is asked.
    ///
    /// `events` may be called from any thread and `wake` from another AT THE SAME TIME — the
    /// lifecycle comes from the supervisor and the messages from a forwarder, and the lock that
    /// would serialise them would sit on the inbound byte path.
    func attach(
        events: @escaping @Sendable (SlopDeskClient.Event) -> Void,
        wake: @escaping @Sendable () -> Void,
    )

    /// The cwd a FRESH host shell starts in, re-sent on every open. A reattach ignores it.
    func setInitialCwd(_ cwd: String?)

    func connect(host: String, port: UInt16, handshakeTimeout: Duration) throws -> PaneDialOutcome
    func resume(handshakeTimeout: Duration) throws -> PaneDialOutcome
    func pause()
    func close()

    func sendInput(_ bytes: Data) throws
    func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16) throws
    func sendControl(_ message: WireMessage) throws
    func flushAck()

    /// Takes the whole pending output backlog in order, crediting its wire bytes back to the host.
    func takeOutput() -> [Data]

    var sessionID: UUID? { get }
    var highestContiguousSeq: Int64 { get }
    var resumeOutcome: SlopDeskClient.SessionResumeOutcome { get }
    var smoothedRTTMS: Double? { get }
    var isPaused: Bool { get }
    var isClosed: Bool { get }
    var isExited: Bool { get }
    var hostCloseReason: MuxCloseReason? { get }
}

/// What a dial that did not throw turned out to be.
///
/// Two cases rather than `Void`, because "a close or a pause landed while we were dialling" is not a
/// failure and must not be thrown: ``ConnectionViewModel`` reads a RETURN as "somebody else is
/// handling this pane" and a THROW as "the host is unreachable", and flipping a superseded dial to
/// the second whitewashes a torn-down pane to `.connected`.
public enum PaneDialOutcome: Sendable, Equatable {
    /// The handshake completed and the session is live.
    case connected
    /// A close or a pause superseded the dial. Stop; do not retry, do not report a failure.
    case superseded
}

/// Where ``LivePaneDriver``'s callbacks land, retained by the Rust handle for its whole life.
///
/// Top-level rather than nested, because the three `@convention(c)` callbacks below are free
/// functions — a C function pointer captures nothing — and they must name the type they reconstitute
/// from the context pointer.
///
/// The sinks are installed once, before the driver can dial, and read from the callback threads
/// afterwards; the lock covers that one publication rather than a hot path.
private final class PaneSinks: Sendable {
    private struct Sinks {
        var events: (@Sendable (SlopDeskClient.Event) -> Void)?
        var wake: (@Sendable () -> Void)?
    }

    private let sinks = Mutex(Sinks())

    func install(
        events: @escaping @Sendable (SlopDeskClient.Event) -> Void,
        wake: @escaping @Sendable () -> Void,
    ) {
        sinks.withLock { $0 = Sinks(events: events, wake: wake) }
    }

    /// Both readers COPY the sink out and call it unlocked: a sink runs arbitrary embedder code
    /// and must not be able to re-enter the publication it was read from.
    func emit(_ event: SlopDeskClient.Event) {
        sinks.withLock { $0.events }?(event)
    }

    func woke() {
        sinks.withLock { $0.wake }?()
    }
}

/// The shipping ``PaneDriving``: one `slopdesk_pane_driver_*` handle and the three callbacks.
///
/// A `final class` and not the actor, because the callback `context` must be a raw pointer valid on
/// any thread until `slopdesk_pane_driver_free` RETURNS, and an actor reference is neither — the
/// same reason ``MuxClientTransport``'s inbox is one. Here ARC is the lifetime: the last release
/// frees the driver, which stops the supervisor and joins every forwarder, and only then releases
/// the context. Freeing in the other order would release a context a running callback still holds.
public final class LivePaneDriver: PaneDriving {
    /// Owns the Rust driver for exactly as long as anything holds this object.
    ///
    /// A separate class for ``MuxClientTransport``'s reason: ARC releases an object's fields in NO
    /// specified order, and the pool must outlive every driver opened on it, so one strong reference
    /// from here makes that obligation structural rather than hoped-for.
    private final class Held: @unchecked Sendable {
        let pointer: OpaquePointer
        private let context: Unmanaged<PaneSinks>
        private let pool: ConnectionRegistry

        init(pointer: OpaquePointer, context: Unmanaged<PaneSinks>, pool: ConnectionRegistry) {
            self.pointer = pointer
            self.context = context
            self.pool = pool
        }

        deinit {
            slopdesk_pane_driver_free(pointer)
            context.release()
        }
    }

    private let sinks = PaneSinks()
    private let held: Held?

    /// Builds a driver on the app's shared pool.
    ///
    /// `nil` handle only if the supervisor thread could not start, which nothing observed has done;
    /// every door then answers its absent-handle reading and the face reports a closed session
    /// rather than pretending to dial.
    public init(
        registry: ConnectionRegistry,
        channelClass: UInt8 = MuxChannelClass.pane.rawValue,
        ackInterval: Duration,
        pingInterval: Duration,
        backoff: SlopDeskClient.Backoff?,
        resumeSeed: SlopDeskClient.ResumeSeed?,
    ) {
        var config = SlopDeskPaneConfig()
        config.channel_class = channelClass
        config.ack_interval_ms = ackInterval.milliseconds
        config.ping_interval_ms = pingInterval.milliseconds
        config.reconnects = backoff != nil
        if let backoff {
            config.retry_initial_ns = backoff.initialNanoseconds
            config.retry_maximum_ns = backoff.maximumNanoseconds
            config.retry_multiplier = backoff.multiplier
        }
        config.has_resume_seed = resumeSeed != nil
        if let resumeSeed {
            config.resume_last_seq = resumeSeed.lastSeq
            var identity = resumeSeed.sessionID.uuid
            withUnsafeMutableBytes(of: &config.resume_session_id) { destination in
                withUnsafeBytes(of: &identity) { source in destination.copyBytes(from: source) }
            }
        }
        let retained = Unmanaged.passRetained(sinks)
        let opened = slopdesk_pane_driver_new(
            registry.rawPool,
            &config,
            retained.toOpaque(),
            onMessage,
            onEvent,
            onWake,
        )
        if let opened {
            held = Held(pointer: opened, context: retained, pool: registry)
        } else {
            // Rust promises no callback has run or ever will, so the context is released here.
            retained.release()
            held = nil
        }
    }

    @preconcurrency
    public func attach(
        events: @escaping @Sendable (SlopDeskClient.Event) -> Void,
        wake: @escaping @Sendable () -> Void,
    ) {
        sinks.install(events: events, wake: wake)
    }

    public func setInitialCwd(_ cwd: String?) {
        let bytes = Array((cwd ?? "").utf8)
        bytes.withUnsafeBufferPointer { span in
            slopdesk_pane_driver_set_initial_cwd(
                held?.pointer,
                cwd == nil ? nil : span.baseAddress,
                cwd == nil ? 0 : span.count,
            )
        }
    }

    public func connect(host: String, port: UInt16, handshakeTimeout: Duration) throws -> PaneDialOutcome {
        let bytes = Array(host.utf8)
        return try Self.dialled { reason, cap, written in
            bytes.withUnsafeBufferPointer { span in
                slopdesk_pane_driver_connect(
                    held?.pointer,
                    span.baseAddress,
                    span.count,
                    port,
                    handshakeTimeout.milliseconds,
                    reason,
                    cap,
                    written,
                )
            }
        }
    }

    public func resume(handshakeTimeout: Duration) throws -> PaneDialOutcome {
        try Self.dialled { reason, cap, written in
            slopdesk_pane_driver_resume(held?.pointer, handshakeTimeout.milliseconds, reason, cap, written)
        }
    }

    public func pause() { slopdesk_pane_driver_pause(held?.pointer) }

    public func close() { slopdesk_pane_driver_close(held?.pointer) }

    public func sendInput(_ bytes: Data) throws {
        let verdict = bytes.withUnsafeBytes { span in
            slopdesk_pane_driver_send_input(
                held?.pointer,
                span.baseAddress?.assumingMemoryBound(to: UInt8.self),
                span.count,
            )
        }
        try Self.sent(verdict, "input")
    }

    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16) throws {
        try Self.sent(
            slopdesk_pane_driver_send_resize(held?.pointer, cols, rows, pxWidth, pxHeight),
            "resize",
        )
    }

    public func sendControl(_ message: WireMessage) throws {
        let verdict = message.withFlattened { flat, arena, arenaLength, blob, blobLength in
            slopdesk_pane_driver_send_control(
                held?.pointer,
                flat,
                arena?.assumingMemoryBound(to: UInt8.self),
                arenaLength,
                blob?.assumingMemoryBound(to: UInt8.self),
                blobLength,
            )
        }
        try Self.sent(verdict, "control message")
    }

    public func flushAck() { slopdesk_pane_driver_flush_ack(held?.pointer) }

    public func takeOutput() -> [Data] {
        // The batch is built by the chunk callback, which the door calls synchronously, once per
        // payload, before it returns — so a plain box on the stack is the whole marshalling and the
        // ONE copy the boundary is shaped around happens here and nowhere else.
        final class Batch { var chunks: [Data] = [] }
        let batch = Batch()
        let context = Unmanaged.passUnretained(batch).toOpaque()
        _ = slopdesk_pane_driver_take_output(held?.pointer, context) { context, bytes, length in
            guard let context else { return }
            let batch = Unmanaged<Batch>.fromOpaque(context).takeUnretainedValue()
            // The LENGTH decides, never the pointer: an empty chunk is a dangling non-null on the
            // Rust side, which is the door's stated convention.
            batch.chunks.append(length > 0 ? bytes.map { Data(bytes: $0, count: length) } ?? Data() : Data())
        }
        return batch.chunks
    }

    public var sessionID: UUID? {
        var raw = [UInt8](repeating: 0, count: 16)
        let learned = raw.withUnsafeMutableBufferPointer { out in
            slopdesk_pane_driver_session_id(held?.pointer, out.baseAddress)
        }
        guard learned else { return nil }
        return raw.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    public var highestContiguousSeq: Int64 { slopdesk_pane_driver_highest_contiguous_seq(held?.pointer) }

    public var resumeOutcome: SlopDeskClient.SessionResumeOutcome {
        SlopDeskClient.SessionResumeOutcome(code: slopdesk_pane_driver_resume_outcome(held?.pointer))
    }

    public var smoothedRTTMS: Double? {
        var reading = 0.0
        guard slopdesk_pane_driver_smoothed_rtt_ms(held?.pointer, &reading) else { return nil }
        return reading
    }

    public var isPaused: Bool { slopdesk_pane_driver_is_paused(held?.pointer) }

    public var isClosed: Bool { slopdesk_pane_driver_is_closed(held?.pointer) }

    public var isExited: Bool { slopdesk_pane_driver_is_exited(held?.pointer) }

    public var hostCloseReason: MuxCloseReason? {
        var raw: UInt8 = 0
        guard slopdesk_pane_driver_host_close_reason(held?.pointer, &raw) else { return nil }
        // An unrecognised byte from a newer host reads as `.retired`, the conservative answer: it
        // withholds the automatic re-dial rather than inventing one.
        return MuxCloseReason(rawValue: raw) ?? .retired
    }

    // MARK: - Verdicts

    /// How much of a refusal sentence the door may spill. Every one it words today is well under
    /// this; the door truncates on a char boundary rather than asking for a length, so a longer one
    /// arrives clipped rather than lost.
    private static let reasonCapacity = 256

    /// Runs one dial door and turns its `SLOPDESK_PANE_CONNECT_*` code into the outcome or the throw.
    private static func dialled(_ door: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> Int32) throws
        -> PaneDialOutcome
    {
        var reason = [UInt8](repeating: 0, count: reasonCapacity)
        var written = 0
        let verdict = reason.withUnsafeMutableBufferPointer { out in
            door(out.baseAddress, out.count, &written)
        }
        let said = String(decoding: reason.prefix(max(0, min(written, reasonCapacity))), as: UTF8.self)
        switch verdict {
        case SLOPDESK_PANE_CONNECT_OK: return .connected
        case SLOPDESK_PANE_CONNECT_SUPERSEDED: return .superseded
        // Terminal for this driver: a state that refuses, no endpoint to resume to, a handle that is
        // going away, or the caller's own reentrancy. None becomes reachable by trying again.
        case SLOPDESK_PANE_CONNECT_REFUSED,
             SLOPDESK_PANE_CONNECT_NO_ENDPOINT,
             SLOPDESK_PANE_CONNECT_GONE,
             SLOPDESK_PANE_CONNECT_REENTRANT:
            throw ClientError.invalidState(said.isEmpty ? "the session refused the dial" : said)
        default:
            throw ClientError.notConnected(said.isEmpty ? "the host could not be reached" : said)
        }
    }

    /// Turns a `SLOPDESK_PANE_SEND_*` verdict into the error the client's ladder already reads.
    private static func sent(_ verdict: Int32, _ what: String) throws {
        switch verdict {
        case SLOPDESK_PANE_SEND_OK: return
        case SLOPDESK_PANE_SEND_CLOSED: throw ClientError.invalidState("\(what) on a closed session")
        case SLOPDESK_PANE_SEND_LINK: throw ClientError.notConnected("\(what) failed, the link is gone")
        default: throw ClientError.invalidState("\(what) was refused by the session")
        }
    }
}

// MARK: - The three callbacks

// Free functions rather than closures, because a `@convention(c)` pointer captures nothing. The
// context is the retained `Sinks`, valid until `slopdesk_pane_driver_free` returns.

private func onMessage(
    context: UnsafeMutableRawPointer?,
    record: UnsafePointer<SlopDeskWireMessage>?,
    arena: UnsafePointer<UInt8>?,
    arenaLength: Int,
    blob: UnsafePointer<UInt8>?,
    blobLength: Int,
) {
    guard let context, let record else { return }
    let sinks = Unmanaged<PaneSinks>.fromOpaque(context).takeUnretainedValue()
    // The run is copied HERE and exactly once. The LENGTH decides, never the pointer: an empty run
    // is a dangling non-null on the Rust side, which is the door's stated convention.
    let run = blobLength > 0 ? blob.map { Data(bytes: $0, count: blobLength) } ?? Data() : Data()
    let text = UnsafeRawBufferPointer(start: arena, count: arenaLength)
    guard let message = WireMessage.lent(record.pointee, arena: text, run: run),
          let event = SlopDeskClient.Event(message)
    else { return }
    sinks.emit(event)
}

private func onEvent(
    context: UnsafeMutableRawPointer?,
    event: UnsafePointer<SlopDeskPaneEvent>?,
    text: UnsafePointer<UInt8>?,
    textLength: Int,
) {
    guard let context, let event else { return }
    let sinks = Unmanaged<PaneSinks>.fromOpaque(context).takeUnretainedValue()
    // As above: the LENGTH decides. A lossy decode is right for a diagnostic — a byte the host
    // mis-encoded must still reach the log as a replacement character rather than vanishing.
    var said = ""
    if textLength > 0, let text {
        said = String(decoding: UnsafeBufferPointer(start: text, count: textLength), as: UTF8.self)
    }
    guard let folded = SlopDeskClient.Event(event.pointee, text: said) else { return }
    sinks.emit(folded)
}

private func onWake(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PaneSinks>.fromOpaque(context).takeUnretainedValue().woke()
}
